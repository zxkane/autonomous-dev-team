#!/bin/bash
# test-lib-agent-smoke.sh — Unit tests for the three-state agent smoke
# (INV-63, issue #222): lib-agent-smoke.sh (smoke_agent / _smoke_classify /
# _smoke_nonce) + the matrix harness tests/e2e/run-agent-smoke.sh.
#
# The smoke goes through the REAL run_agent (lib-agent.sh) — we stub the agent
# CLI binaries on PATH (the stub-CLI pattern, consistent with the other
# tests/unit/test-*.sh) so the launch → classify chain is exercised without real
# credentials. Classification reuses the committed drop-reason fixtures
# (agy-quota-exhausted, kiro-auth-failed, codex stream-error).
#
# Run: bash tests/unit/test-lib-agent-smoke.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh"
HARNESS="$PROJECT_ROOT/tests/e2e/run-agent-smoke.sh"
CONF_EXAMPLE="$PROJECT_ROOT/tests/e2e/e2e.conf.example"
CI="$PROJECT_ROOT/.github/workflows/ci.yml"
GITIGNORE="$PROJECT_ROOT/.gitignore"
DOC_SMOKE="$PROJECT_ROOT/docs/pipeline/agent-smoke.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
PIPELINE_DOC="$PROJECT_ROOT/docs/autonomous-pipeline.md"
FIXTURES="$SCRIPT_DIR/fixtures"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# lib-config.sh needs these before lib-agent.sh sources it. Use a temp HOME so
# pid_dir_for_project() (the agy sidecar path) writes under a private dir we
# control and clean up.
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/smoke-test-home-XXXXXX")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export REPO_NAME=autonomous-dev-team
export PROJECT_ID=test-agent-smoke
export PROJECT_DIR="$PROJECT_ROOT"
export GH_AUTH_MODE=token
export HOME="$TEST_HOME"
unset XDG_RUNTIME_DIR 2>/dev/null || true

# Stub CLIs live here; prepended to PATH per-test as needed.
STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/smoke-test-stub-XXXXXX")
ORIG_PATH="$PATH"

cleanup() { rm -rf "$TEST_HOME" "$STUB_DIR" 2>/dev/null || true; }
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected_rc=$expected actual_rc=$actual)"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:400}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern, file: $file)"; FAIL=$((FAIL + 1))
  fi
}

# Assert a marker file's presence (the launcher-probe ran) or absence (it was
# neutralized). $1=desc, $2=present|absent, $3=marker path. The marker — not the
# verdict — is the authoritative signal that a launcher actually ran (TC-036).
assert_marker() {
  local desc="$1" want="$2" marker="$3" ok=""
  case "$want" in
    present) [[ -e "$marker" ]] && ok=1 ;;
    absent)  [[ -e "$marker" ]] || ok=1 ;;
  esac
  if [[ -n "$ok" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (marker $want check failed: $marker)"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $LIB not found — implementation step required first"
  echo "  PASS: $PASS"; echo "  FAIL: $((FAIL + 1))"; exit 1
}

# Make a stub CLI binary. $1=name, $2=body (bash, after the shebang).
make_stub() {
  local name="$1" body="$2"
  printf '#!/bin/bash\n%s\n' "$body" > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh
source "$LIB"

# ---------------------------------------------------------------------------
echo "=== TC-AGENT-SMOKE-NONCE: _smoke_nonce uniqueness ==="
# ---------------------------------------------------------------------------
# TC-AGENT-SMOKE-009 — nonce is unique per call, shape SMOKE-<16hex>
n1=$(_smoke_nonce); n2=$(_smoke_nonce); n3=$(_smoke_nonce)
if [[ "$n1" =~ ^SMOKE-[0-9a-f]{16}$ ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-009a nonce shape SMOKE-<16hex>"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-009a bad nonce shape: $n1"; FAIL=$((FAIL + 1))
fi
if [[ "$n1" != "$n2" && "$n2" != "$n3" && "$n1" != "$n3" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-009b three calls → three distinct nonces"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-009b nonce collision ($n1/$n2/$n3)"; FAIL=$((FAIL + 1))
fi
# Tight-loop uniqueness (the $RANDOM-reseed footgun): 200 nonces, all distinct.
loop_nonces=$(for _ in $(seq 1 200); do _smoke_nonce; done | sort -u | wc -l)
assert_eq "TC-AGENT-SMOKE-009c 200 tight-loop nonces all distinct" "200" "$loop_nonces"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGENT-SMOKE-038: _smoke_session_id is a VALID UUID (#222 [P1]) ==="
# ---------------------------------------------------------------------------
# The claude CLI rejects --session-id unless it is a valid UUID; smoke_agent must
# generate a UUID-shaped session id or every real claude entry fails at launch.
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
s1=$(_smoke_session_id); s2=$(_smoke_session_id); s3=$(_smoke_session_id)
if [[ "$s1" =~ $UUID_RE ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-038a session id is a canonical 8-4-4-4-12 lowercase-hex UUID"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-038a bad session-id shape: $s1"; FAIL=$((FAIL + 1))
fi
if [[ "$s1" != "$s2" && "$s2" != "$s3" && "$s1" != "$s3" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-038b three calls → three distinct UUIDs"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-038b session-id collision ($s1/$s2/$s3)"; FAIL=$((FAIL + 1))
fi
# 200 tight-loop session ids: all distinct AND all valid UUIDs.
loop_uuids=$(for _ in $(seq 1 200); do _smoke_session_id; done)
loop_uuid_uniq=$(printf '%s\n' "$loop_uuids" | sort -u | wc -l)
assert_eq "TC-AGENT-SMOKE-038c 200 tight-loop session ids all distinct" "200" "$loop_uuid_uniq"
loop_uuid_valid=$(printf '%s\n' "$loop_uuids" | grep -cE "$UUID_RE")
assert_eq "TC-AGENT-SMOKE-038d all 200 session ids are valid UUIDs" "200" "$loop_uuid_valid"
# Fallback branch (no /proc uuid, no uuidgen, no urandom): force the last-resort
# path by shadowing the sources and confirm it STILL yields a valid UUID — claude
# would otherwise reject a malformed last-resort id.
fallback_uuid=$(
  set -uo pipefail
  source "$LIB" 2>/dev/null
  # Shadow uuidgen + od so only the PID/RANDOM fallback can run; the /proc read is
  # bypassed by pointing cat at a nonexistent path via a wrapper function.
  cat() { command cat /nonexistent/smoke-no-uuid 2>/dev/null; }
  uuidgen() { return 1; }
  od() { return 1; }
  _smoke_session_id
)
if [[ "$fallback_uuid" =~ $UUID_RE ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-038e last-resort fallback still yields a valid UUID"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-038e fallback produced a non-UUID: $fallback_uuid"; FAIL=$((FAIL + 1))
fi
# TC-AGENT-SMOKE-038h — force the `uuidgen` branch (shadow only the /proc read so
# the ladder falls through to uuidgen). The prod box uses /proc, so uuidgen is
# otherwise only covered transitively; assert it yields a valid UUID.
if command -v uuidgen >/dev/null 2>&1; then
  uuidgen_uuid=$(
    set -uo pipefail
    source "$LIB" 2>/dev/null
    cat() { command cat /nonexistent/smoke-no-uuid 2>/dev/null; }   # bypass /proc branch
    _smoke_session_id
  )
  if [[ "$uuidgen_uuid" =~ $UUID_RE ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-038h uuidgen branch yields a valid UUID"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-038h uuidgen branch produced a non-UUID: $uuidgen_uuid"; FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-038h SKIP (no uuidgen on this box)"; PASS=$((PASS + 1))
fi
# TC-AGENT-SMOKE-038i — force the /dev/urandom v4-construct branch (shadow /proc +
# uuidgen so the ladder falls through to the od construct, but NOT od). Assert it
# yields a valid UUID with the v4 version nibble and a 10xx variant nibble.
if [[ -r /dev/urandom ]]; then
  od_uuids=$(
    set -uo pipefail
    source "$LIB" 2>/dev/null
    cat() { command cat /nonexistent/smoke-no-uuid 2>/dev/null; }   # bypass /proc
    uuidgen() { return 1; }                                          # bypass uuidgen
    for _ in $(seq 1 50); do _smoke_session_id; done                 # od construct
  )
  od_valid=$(printf '%s\n' "$od_uuids" | grep -cE "$UUID_RE")
  assert_eq "TC-AGENT-SMOKE-038i 50 urandom-construct UUIDs all valid (v4 nibble + 10xx variant)" "50" "$od_valid"
  od_uniq=$(printf '%s\n' "$od_uuids" | sort -u | wc -l)
  assert_eq "TC-AGENT-SMOKE-038j 50 urandom-construct UUIDs all distinct" "50" "$od_uniq"
else
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-038i SKIP (no /dev/urandom)"; PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-038j SKIP (no /dev/urandom)"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGENT-SMOKE-CLS: _smoke_classify three-state rc mapping (pure) ==="
# ---------------------------------------------------------------------------
SMOKE_TIMEOUT_USED=120
STDOUT=$(mktemp); AGYLOG=$(mktemp)
NONCE="SMOKE-abcdef0123456789"

# TC-AGENT-SMOKE-001 — exact nonce echo (on stdout) → PASS
printf 'some preamble\n%s\ntrailing\n' "$NONCE" > "$STDOUT"
assert_eq "TC-AGENT-SMOKE-001 exact nonce echo → PASS" \
  "PASS|nonce-ok" "$(_smoke_classify claude 0 "$STDOUT" "$NONCE" "")"

# TC-AGENT-SMOKE-039 — the #222 [P1] stream-separation: the nonce PASS check reads
# ONLY stdout. A broken CLI/wrapper that echoes the prompt (which CONTAINS the
# nonce) onto STDERR and exits non-zero must NOT be PASS — no model response.
SMOKE_STDERR=$(mktemp)
: > "$STDOUT"                              # stdout empty (no model response)
printf 'echoing the prompt to stderr: %s\n' "$NONCE" > "$SMOKE_STDERR"  # nonce only on stderr
out=$(_smoke_classify claude 3 "$STDOUT" "$NONCE" "" "$SMOKE_STDERR")
assert_eq "TC-AGENT-SMOKE-039a nonce on STDERR only (stdout empty) → NOT PASS (FAIL)" \
  "FAIL" "${out%%|*}"
assert_contains "TC-AGENT-SMOKE-039b reason is no-response (nonce absent from stdout)" \
  "no-response" "$out"
# Positive control: same nonce ON STDOUT → PASS (proves the check still works,
# it's the stream that matters, not the content).
printf '%s\n' "$NONCE" > "$STDOUT"
assert_eq "TC-AGENT-SMOKE-039c same nonce on STDOUT → PASS (stream is what matters)" \
  "PASS|nonce-ok" "$(_smoke_classify claude 0 "$STDOUT" "$NONCE" "" "$SMOKE_STDERR")"
rm -f "$SMOKE_STDERR"

# TC-AGENT-SMOKE-045 — the #222 [P1] r2 successful-exit gate: the nonce on STDOUT
# but a NON-ZERO run_agent exit must NOT be PASS. A broken CLI/wrapper can echo the
# stdin prompt (which contains the nonce) to STDOUT and THEN fail (launch/config
# error after the echo); a healthy model round-trip exits 0.
printf 'preamble (the prompt echoed): %s\n' "$NONCE" > "$STDOUT"   # nonce on stdout
out=$(_smoke_classify claude 3 "$STDOUT" "$NONCE" "")              # but rc 3 (failed)
assert_eq "TC-AGENT-SMOKE-045a nonce on stdout + non-zero exit → NOT PASS (FAIL)" \
  "FAIL" "${out%%|*}"
assert_contains "TC-AGENT-SMOKE-045b reason is no-response (failed run, nonce not trusted)" \
  "no-response" "$out"
# Positive control: identical stdout but rc 0 → PASS (it's the exit code that gates).
assert_eq "TC-AGENT-SMOKE-045c identical stdout with rc 0 → PASS (exit code gates)" \
  "PASS|nonce-ok" "$(_smoke_classify claude 0 "$STDOUT" "$NONCE" "")"

# TC-AGENT-SMOKE-047 — the #222 operator-review [BLOCKING] kiro-tty-decoration:
# kiro `--no-interactive` stdout wraps the token in ANSI decoration AND injects a
# BEL (0x07) INSIDE the echoed token (`SMOKE-^G<hex>`), so a raw grep never matches
# a verified-healthy kiro → false `no-response` FAIL. _smoke_classify must sanitize
# (strip C0 control bytes + ANSI CSI) before the nonce check and classify PASS.
KIRO_TTY_NONCE="SMOKE-a1b2c3d4e5f60718"   # matches the committed fixture's token
if [[ -f "$FIXTURES/kiro-tty-decoration.fixture" ]]; then
  # Sanity: the raw fixture does NOT contain the bare nonce (the BEL/ANSI defeat a
  # naive grep) — proves the test exercises the sanitization, not a trivial match.
  if grep -qF "$KIRO_TTY_NONCE" "$FIXTURES/kiro-tty-decoration.fixture" 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-047a fixture must NOT contain the bare nonce (BEL/ANSI expected)"; FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-047a fixture's token is TTY-decorated (raw grep misses it)"; PASS=$((PASS + 1))
  fi
  # The helper recovers the match after sanitization.
  if _smoke_stdout_has_nonce "$FIXTURES/kiro-tty-decoration.fixture" "$KIRO_TTY_NONCE"; then
    echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-047b _smoke_stdout_has_nonce recovers the BEL/ANSI-wrapped nonce"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-047b helper failed to recover the decorated nonce"; FAIL=$((FAIL + 1))
  fi
  # End-to-end classify: kiro, rc 0, decorated stdout → PASS (the false-FAIL fix).
  assert_eq "TC-AGENT-SMOKE-047c kiro decorated stdout + rc 0 → PASS (not a false no-response FAIL)" \
    "PASS|nonce-ok" "$(_smoke_classify kiro 0 "$FIXTURES/kiro-tty-decoration.fixture" "$KIRO_TTY_NONCE" "")"
  # Direction-stays-closed: the SAME decorated stdout but a NON-ZERO exit must still
  # NOT PASS (the rc==0 gate composes with the sanitize — no widened false-PASS).
  out=$(_smoke_classify kiro 3 "$FIXTURES/kiro-tty-decoration.fixture" "$KIRO_TTY_NONCE" "")
  assert_eq "TC-AGENT-SMOKE-047d decorated nonce + non-zero exit → still NOT PASS (rc gate composes)" \
    "FAIL" "${out%%|*}"
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-047 kiro-tty-decoration.fixture missing"; FAIL=$((FAIL + 1))
fi

# TC-AGENT-SMOKE-048 — the #222 operator-review follow-up: the sanitize helper must
# be SIGPIPE-immune under `set -o pipefail`. The nonce EARLY in a LARGE (>64 KB)
# stdout would, with a trailing `grep -q` pipe, make grep early-exit + close stdin →
# upstream `tr`/`sed` die SIGPIPE → pipeline rc 141 → a false `no-response` FAIL on
# stdout that DOES contain the nonce. The capture-then-glob form is immune. Run the
# whole check under `set -uo pipefail` (the wrappers' mode) so a regression to the
# pipe form fails here. ~128 KB of trailing output.
sigpipe_check=$(
  set -uo pipefail
  source "$LIB" 2>/dev/null
  bign="SMOKE-0f1e2d3c4b5a6987"
  bigf=$(mktemp)
  { printf '%s\n' "$bign"; head -c 131072 /dev/zero | tr '\0' 'x'; } > "$bigf"
  hrc=0; _smoke_stdout_has_nonce "$bigf" "$bign" || hrc=$?
  cls=$(_smoke_classify claude 0 "$bigf" "$bign" "")
  rm -f "$bigf"
  printf 'helper_rc=%s|%s' "$hrc" "$cls"
)
assert_eq "TC-AGENT-SMOKE-048a sanitize helper SIGPIPE-immune: nonce early in >64KB stdout → rc 0" \
  "helper_rc=0|PASS|nonce-ok" "$sigpipe_check"

# TC-AGENT-SMOKE-002 — truncated/garbled nonce echo → NOT PASS (exact match only)
printf 'SMOKE-abcdef012345\n' > "$STDOUT"   # truncated
out=$(_smoke_classify claude 0 "$STDOUT" "$NONCE" "")
assert_eq "TC-AGENT-SMOKE-002 truncated nonce → FAIL (no partial credit)" \
  "FAIL" "${out%%|*}"

# TC-AGENT-SMOKE-003 — agy quota fixture in the --log-file → UNAVAILABLE
: > "$STDOUT"
cp "$FIXTURES/agy-quota-exhausted.fixture" "$AGYLOG"
out=$(_smoke_classify agy 0 "$STDOUT" "$NONCE" "$AGYLOG")
assert_eq "TC-AGENT-SMOKE-003a agy quota log → UNAVAILABLE" "UNAVAILABLE" "${out%%|*}"
assert_contains "TC-AGENT-SMOKE-003b reason names quota-exhausted" "quota-exhausted" "$out"

# TC-AGENT-SMOKE-004 — kiro auth fixture in stdout → FAIL
cp "$FIXTURES/kiro-auth-failed.fixture" "$STDOUT"
out=$(_smoke_classify kiro 1 "$STDOUT" "$NONCE" "")
assert_eq "TC-AGENT-SMOKE-004a kiro auth log → FAIL" "FAIL" "${out%%|*}"
assert_contains "TC-AGENT-SMOKE-004b reason names auth-failed" "auth-failed" "$out"

# TC-AGENT-SMOKE-005 — codex stream-error fixture → UNAVAILABLE
cp "$FIXTURES/codex-review-stdout-stream-error.txt" "$STDOUT"
out=$(_smoke_classify codex 1 "$STDOUT" "$NONCE" "")
assert_eq "TC-AGENT-SMOKE-005a codex stream-error → UNAVAILABLE" "UNAVAILABLE" "${out%%|*}"
assert_contains "TC-AGENT-SMOKE-005b reason names stream-error" "stream-error" "$out"

# TC-AGENT-SMOKE-005c — codex config-error fixture (INV-62 #225 deterministic clap
# argv rejection) → FAIL with the SPECIFIC reason, not a generic no-response. A
# config error is operator-side breakage (the gate's purpose), and naming the
# rejected flag is the observability win the per-CLI scraper exists for.
if [[ -f "$FIXTURES/codex-review-stdout-config-error.txt" ]]; then
  cp "$FIXTURES/codex-review-stdout-config-error.txt" "$STDOUT"
  out=$(_smoke_classify codex 2 "$STDOUT" "$NONCE" "")
  assert_eq "TC-AGENT-SMOKE-005c codex config-error → FAIL" "FAIL" "${out%%|*}"
  assert_contains "TC-AGENT-SMOKE-005d reason names config-error (not generic no-response)" "config-error" "$out"
else
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-005c SKIP (no codex config-error fixture)"; PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-005d SKIP (no codex config-error fixture)"; PASS=$((PASS + 1))
fi

# TC-AGENT-SMOKE-006 — non-zero rc, no nonce, no signal → FAIL no-response
printf 'just some unrelated chatter, no token\n' > "$STDOUT"
out=$(_smoke_classify claude 3 "$STDOUT" "$NONCE" "")
assert_eq "TC-AGENT-SMOKE-006a no nonce/no signal → FAIL" "FAIL" "${out%%|*}"
assert_contains "TC-AGENT-SMOKE-006b reason=no-response" "no-response" "$out"

# TC-AGENT-SMOKE-007 — timeout rc (124/137), no nonce, no signal → FAIL timeout
: > "$STDOUT"
out124=$(_smoke_classify claude 124 "$STDOUT" "$NONCE" "")
assert_eq "TC-AGENT-SMOKE-007a rc 124 → FAIL" "FAIL" "${out124%%|*}"
assert_contains "TC-AGENT-SMOKE-007b reason=timeout" "timeout" "$out124"
out137=$(_smoke_classify claude 137 "$STDOUT" "$NONCE" "")
assert_eq "TC-AGENT-SMOKE-007c rc 137 → FAIL timeout" "FAIL" "${out137%%|*}"

# TC-AGENT-SMOKE-008 — agy timed out (rc 124) BUT quota signal in log → UNAVAILABLE
#   (environmental signal wins over the bare timeout)
: > "$STDOUT"
cp "$FIXTURES/agy-quota-exhausted.fixture" "$AGYLOG"
out=$(_smoke_classify agy 124 "$STDOUT" "$NONCE" "$AGYLOG")
assert_eq "TC-AGENT-SMOKE-008 agy timeout+quota-in-log → UNAVAILABLE (env wins)" \
  "UNAVAILABLE" "${out%%|*}"

# Negative: a CLEAN no-verdict agy log (no signal) at timeout → FAIL (timeout)
printf 'I Antigravity 2.0 CLI (print mode)\nI Starting review turn\n' > "$AGYLOG"
out=$(_smoke_classify agy 124 "$STDOUT" "$NONCE" "$AGYLOG")
assert_eq "TC-AGENT-SMOKE-008b agy timeout, clean log → FAIL timeout" "FAIL" "${out%%|*}"

rm -f "$STDOUT" "$AGYLOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGENT-SMOKE-010: set -euo pipefail discipline ==="
# ---------------------------------------------------------------------------
# Command-substitution call.
cls_cs=$(
  set -euo pipefail
  source "$LIB"
  s=$(mktemp); : > "$s"
  out=$(_smoke_classify claude 3 "$s" "SMOKE-0000000000000000" "")
  rm -f "$s"
  echo "rc=$?|${out%%|*}"
)
assert_eq "TC-AGENT-SMOKE-010a no abort under set -e (command-subst)" "rc=0|FAIL" "$cls_cs"
# Bare call (errexit applies to the body directly).
cls_bare=$(
  set -euo pipefail
  source "$LIB"
  s=$(mktemp); : > "$s"
  _smoke_classify claude 3 "$s" "SMOKE-0000000000000000" "" >/dev/null  # BARE
  echo "REACHED"
  rm -f "$s"
)
assert_eq "TC-AGENT-SMOKE-010b bare call reaches return 0 (no errexit abort)" "REACHED" "$cls_bare"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGENT-SMOKE-SMOKEFN: smoke_agent end-to-end via real run_agent ==="
# ---------------------------------------------------------------------------
# A stub `claude` that echoes the SMOKE-<hex> token it reads on stdin. claude's
# run_agent branch invokes `env -u CLAUDECODE claude <flags> -p --output-format
# json` with the prompt on stdin → grep the nonce out and print it.
make_stub claude 'in=$(cat); printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"; exit 0'
# A stub `codex` that exits non-zero with no token (FAIL). codex branch invokes
# `codex exec --json - ` (prompt on stdin via `-`).
make_stub codex 'cat >/dev/null; echo "boom" >&2; exit 4'

# TC-AGENT-SMOKE-SMOKEFN-PASS — real run_agent path, nonce echoed → rc 0
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent claude sonnet 5); rc=$?
assert_rc "TC-AGENT-SMOKE-012a smoke_agent claude (nonce echo) → rc 0" 0 "$rc"
assert_grep_str() { [[ "$2" =~ $1 ]]; }
if [[ "$out" =~ ^SMOKE\ claude\ PASS\ [0-9]+s\ reason=nonce-ok$ ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-011a evidence line shape (PASS)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-011a evidence line: [$out]"; FAIL=$((FAIL + 1))
fi

# TC-AGENT-SMOKE-SMOKEFN-FAIL — codex stub exits non-zero, no token → rc 1
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent codex gpt 5); rc=$?
assert_rc "TC-AGENT-SMOKE-006c smoke_agent codex (no token) → rc 1 FAIL" 1 "$rc"
assert_contains "TC-AGENT-SMOKE-011b evidence line is a FAIL" "SMOKE codex FAIL" "$out"

# TC-AGENT-SMOKE-039d — the #222 [P1] end-to-end: a broken CLI that echoes the
# prompt (which CONTAINS the nonce) onto STDERR and exits non-zero, with EMPTY
# stdout, must be FAIL — not a false PASS from stderr leaking into the nonce
# check. The claude branch feeds the prompt on stdin; this stub copies stdin
# (the prompt, nonce included) to stderr and exits 3 with nothing on stdout.
make_stub claude 'cat >&2; exit 3'
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent claude sonnet 5); rc=$?
assert_rc "TC-AGENT-SMOKE-039d prompt echoed to STDERR + non-zero exit → rc 1 FAIL (no false PASS)" 1 "$rc"
assert_contains "TC-AGENT-SMOKE-039e evidence line is a FAIL (not PASS)" "SMOKE claude FAIL" "$out"

# TC-AGENT-SMOKE-045d — the #222 [P1] r2 end-to-end: a broken CLI that echoes the
# prompt (nonce included) to STDOUT and THEN exits non-zero must be FAIL — the
# rc-0 PASS gate rejects the nonce from a failed run. This is the stdout sibling
# of TC-039d (which covered the stderr case). The stub copies stdin to STDOUT
# (so the nonce IS present on stdout) then exits 3.
make_stub claude 'cat; exit 3'
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent claude sonnet 5); rc=$?
assert_rc "TC-AGENT-SMOKE-045d nonce on STDOUT + non-zero exit → rc 1 FAIL (no false PASS)" 1 "$rc"
assert_contains "TC-AGENT-SMOKE-045e evidence line is a FAIL (not PASS)" "SMOKE claude FAIL" "$out"
# Restore the plain PASS claude stub for any later cases.
make_stub claude 'in=$(cat); printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"; exit 0'

# TC-AGENT-SMOKE-SMOKEFN-AGY — stub agy writes the quota fixture to --log-file,
# exits empty → rc 2 UNAVAILABLE (the #205 shape, through the REAL run_agent agy
# branch which sets up --log-file and the sidecar capture).
make_stub agy '
cat >/dev/null
logf=""
while [[ $# -gt 0 ]]; do case "$1" in --log-file) logf="$2"; shift 2 ;; *) shift ;; esac; done
[[ -n "$logf" ]] && cp "'"$FIXTURES"'/agy-quota-exhausted.fixture" "$logf"
# agy `models` enumeration (INV-50) — empty model so no --model is forwarded.
exit 0'
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent agy "" 5); rc=$?
assert_rc "TC-AGENT-SMOKE-003c smoke_agent agy (quota log) → rc 2 UNAVAILABLE" 2 "$rc"
assert_contains "TC-AGENT-SMOKE-003d evidence is UNAVAILABLE + quota reason" "SMOKE agy UNAVAILABLE" "$out"

# TC-AGENT-SMOKE-007d — a hanging stub past the smoke timeout → rc 1 FAIL timeout.
make_stub slowcli 'cat >/dev/null; sleep 30; exit 0'
start=$(date +%s)
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent slowcli "" 1); rc=$?
end=$(date +%s); el=$((end - start))
assert_rc "TC-AGENT-SMOKE-007d hanging CLI past 1s timeout → rc 1 FAIL" 1 "$rc"
assert_contains "TC-AGENT-SMOKE-007e evidence reason=timeout" "reason=timeout" "$out"
if [[ "$el" -le 5 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-007f timeout fired within budget (${el}s)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-007f timeout did not fire (${el}s)"; FAIL=$((FAIL + 1))
fi

# TC-AGENT-SMOKE-046 — the #222 [P2] suffixed-timeout normalization: a SUFFIXED
# timeout arg (e.g. `5s`) must NOT become `5ss` (which makes coreutils `timeout`
# fail immediately and false-FAIL a healthy CLI). The plain PASS claude stub
# echoes the nonce; with the fix, `smoke_agent claude sonnet 5s` runs cleanly and
# PASSes. Without the normalization, AGENT_TIMEOUT="5ss" → timeout errors → rc≠0
# → the rc-0 PASS gate rejects it → FAIL.
make_stub claude 'in=$(cat); printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"; exit 0'
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent claude sonnet 5s); rc=$?
assert_rc "TC-AGENT-SMOKE-046a suffixed timeout '5s' → rc 0 PASS (no 5ss)" 0 "$rc"
assert_contains "TC-AGENT-SMOKE-046b evidence is PASS (suffixed timeout did not break timeout(1))" \
  "SMOKE claude PASS" "$out"
# A bare-seconds timeout still works (the append-`s`-only-for-bare-digits branch).
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent claude sonnet 5); rc=$?
assert_rc "TC-AGENT-SMOKE-046c bare timeout '5' → rc 0 PASS (s appended → 5s)" 0 "$rc"
# A timeout in another unit (e.g. minutes) is passed through verbatim.
out=$(PATH="$STUB_DIR:$ORIG_PATH" smoke_agent claude sonnet 2m); rc=$?
assert_rc "TC-AGENT-SMOKE-046d unit timeout '2m' → rc 0 PASS (passed through verbatim)" 0 "$rc"

# TC-AGENT-SMOKE-bad-args — empty agent-cmd → rc 1, evidence line still printed.
out=$(smoke_agent "" "" 2>/dev/null); rc=$?
assert_rc "TC-AGENT-SMOKE-013a empty agent-cmd → rc 1" 1 "$rc"
assert_contains "TC-AGENT-SMOKE-013b bad-args evidence line printed" "FAIL" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGENT-SMOKE-HARNESS: matrix parser + aggregation (stub mode) ==="
# ---------------------------------------------------------------------------
[[ -f "$HARNESS" ]] || {
  echo -e "  ${RED}FAIL${NC}: $HARNESS not found"; FAIL=$((FAIL + 1));
}

# TC-AGENT-SMOKE-040..043 — the bundled stub-mode self-test (the E2E artifact):
# full harness, every branch, no real CLIs.
stub_out=$(SMOKE_STUB=1 bash "$HARNESS" 2>/dev/null); stub_rc=$?
assert_rc "TC-AGENT-SMOKE-041 stub matrix has a FAIL → overall rc 1" 1 "$stub_rc"
assert_contains "TC-AGENT-SMOKE-040a stub PASS line present"  "SMOKE claude PASS"        "$stub_out"
assert_contains "TC-AGENT-SMOKE-041b stub FAIL line present"  "SMOKE codex FAIL"         "$stub_out"
assert_contains "TC-AGENT-SMOKE-042 stub UNAVAILABLE present" "SMOKE agy UNAVAILABLE"    "$stub_out"
assert_contains "TC-AGENT-SMOKE-043 stub SKIP present"        "SKIP"                     "$stub_out"
assert_contains "TC-AGENT-SMOKE-029 SMOKE-SUMMARY tallies"    "SMOKE-SUMMARY pass=1 fail=1 unavailable=1 skip=1" "$stub_out"

# Helper: run the harness against an arbitrary inline matrix in stub mode so we
# can exercise the parser + aggregation deterministically. The stub PATH (set by
# the harness's own SMOKE_STUB) provides claude(PASS)/codex(FAIL)/agy(UNAVAIL).
# run_matrix <matrix-text> — write the text to a real temp file (NOT process
# substitution: the harness re-reads SMOKE_CONF, and a /dev/fd path is consumed
# after the first open), run the harness in stub mode against it, echo its stdout
# and carry its rc out via the return code. Capture the rc with `$?` immediately
# after the call (even inside `out=$(run_matrix ...)`, the `$?` right after the
# assignment is run_matrix's return code).
run_matrix() {
  local conf rc
  conf=$(mktemp)
  printf '%s\n' "$1" > "$conf"
  SMOKE_STUB=1 SMOKE_CONF="$conf" bash "$HARNESS" 2>/dev/null
  rc=$?
  rm -f "$conf"
  return $rc
}

# TC-AGENT-SMOKE-021 — malformed entry (too few fields) → loud reject, rc 1.
run_matrix $'good|claude|sonnet|true\nbroken-entry-no-pipes' >/dev/null 2>&1
assert_rc "TC-AGENT-SMOKE-021a malformed entry → rc 1" 1 "$?"

# TC-AGENT-SMOKE-022 — empty matrix (only comments/blanks) → rc 1.
run_matrix $'# only a comment\n' >/dev/null 2>&1
assert_rc "TC-AGENT-SMOKE-022 empty matrix → rc 1" 1 "$?"

# TC-AGENT-SMOKE-025 — all PASS → rc 0.
run_matrix $'a|claude|sonnet|true\nb|claude|sonnet|true' >/dev/null 2>&1
assert_rc "TC-AGENT-SMOKE-025 all PASS → rc 0" 0 "$?"

# TC-AGENT-SMOKE-026 — UNAVAILABLE-only → rc 0 (non-blocking).
run_matrix $'u|agy||true' >/dev/null 2>&1
assert_rc "TC-AGENT-SMOKE-026 UNAVAILABLE-only → rc 0" 0 "$?"

# TC-AGENT-SMOKE-024 — one FAIL among PASS → rc 1.
run_matrix $'a|claude|sonnet|true\nf|codex|gpt|true' >/dev/null 2>&1
assert_rc "TC-AGENT-SMOKE-024 one FAIL among PASS → rc 1" 1 "$?"

# TC-AGENT-SMOKE-027 — require:VAR unset → SKIP, non-blocking (rc 0).
skip_out=$(run_matrix $'s|claude|sonnet|require:SMOKE_TEST_ABSENT_KEY; true'); skip_rc=$?
assert_rc "TC-AGENT-SMOKE-027a require unset → entry SKIP, run rc 0" 0 "$skip_rc"
assert_contains "TC-AGENT-SMOKE-027b SKIP line names the missing var" "missing-required-env:SMOKE_TEST_ABSENT_KEY" "$skip_out"
assert_contains "TC-AGENT-SMOKE-027c summary counts the skip" "skip=1" "$skip_out"

# TC-AGENT-SMOKE-028 — require:VAR present → entry runs (PASS), rc 0. require:
# must be the LEADING token; HOME is always set, so the entry is NOT skipped.
present_out=$(run_matrix $'p|claude|sonnet|require:HOME; true'); present_rc=$?
assert_rc "TC-AGENT-SMOKE-028a require present (HOME) → entry runs, rc 0" 0 "$present_rc"
assert_contains "TC-AGENT-SMOKE-028b present entry PASSes (not skipped)" "SMOKE claude PASS" "$present_out"

# TC-AGENT-SMOKE-031 — entries run in PARALLEL (wall-clock ≈ slowest). Three
# entries each running a 2s-sleeping stub; total must be well under 6s (the sum).
make_stub slow2 'cat >/dev/null; sleep 2; printf "%s\n" "$(cat)" >/dev/null; exit 3'
# Use a matrix of three slow FAIL entries; measure wall-clock.
par_conf=$(mktemp)
printf 'x1|slow2||true\nx2|slow2||true\nx3|slow2||true\n' > "$par_conf"
pstart=$(date +%s)
PATH="$STUB_DIR:$ORIG_PATH" SMOKE_CONF="$par_conf" bash "$HARNESS" >/dev/null 2>&1
pend=$(date +%s); ptotal=$((pend - pstart))
rm -f "$par_conf"
if [[ "$ptotal" -lt 6 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-031 3×2s entries in parallel finished in ${ptotal}s (< 6s sum)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-031 parallel run took ${ptotal}s (expected < 6s)"; FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGENT-SMOKE-ENVORDER: env-setup overrides survive the conf load (#222 [P1]) ==="
# ---------------------------------------------------------------------------
# THE REGRESSION: the harness sources lib-agent-smoke.sh (which re-sources the
# project autonomous.conf via lib-agent.sh, restoring conf-assigned globals like
# BEDROCK_AWS_REGION) and the per-entry env-setup. If env-setup ran BEFORE the
# source, the conf would clobber the entry's override (the codex Bedrock region
# pin / custom-endpoint Bedrock blanking would be ineffective on configured
# boxes). The fix sources the lib FIRST, then evals env-setup (last writer wins),
# then re-tokenizes the launcher.
#
# We simulate a configured box by pointing the lib at a temp autonomous.conf
# (AUTONOMOUS_CONF env override, honored by lib-config.sh::load_autonomous_conf)
# that pins BEDROCK_AWS_REGION to the WRONG region. The entry's env-setup pins
# the RIGHT region. A stub CLI echoes BOTH the nonce (so the run PASSes) and its
# view of $BEDROCK_AWS_REGION into a marker file; the test asserts the stub saw
# the env-setup value, not the conf value.

# A temp conf that sets the polluted region + the required lib-config vars so the
# load does not fail.
ENVORDER_CONF=$(mktemp)
cat > "$ENVORDER_CONF" <<CONF
REPO="zxkane/autonomous-dev-team"
REPO_OWNER="zxkane"
REPO_NAME="autonomous-dev-team"
PROJECT_ID="test-agent-smoke"
GH_AUTH_MODE="token"
BEDROCK_AWS_REGION="us-west-2"
CLAUDE_CODE_USE_BEDROCK="1"
CONF

# A stub `claude` that echoes the nonce (→ PASS) AND records its view of
# BEDROCK_AWS_REGION to $SMOKE_REGION_MARKER (passed via the entry env-setup).
make_stub claude '
in=$(cat)
printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"
[[ -n "${SMOKE_REGION_MARKER:-}" ]] && printf "%s\n" "${BEDROCK_AWS_REGION:-UNSET}" > "$SMOKE_REGION_MARKER"
exit 0'

REGION_MARKER=$(mktemp); : > "$REGION_MARKER"
# The entry: env-setup pins the CORRECT region (us-east-2) AND exports the marker
# path so the stub can record what it actually saw. require: nothing.
envorder_conf=$(mktemp)
printf 'r|claude|sonnet|export BEDROCK_AWS_REGION=us-east-2; export SMOKE_REGION_MARKER=%s\n' "$REGION_MARKER" > "$envorder_conf"
PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$ENVORDER_CONF" SMOKE_CONF="$envorder_conf" \
  bash "$HARNESS" >/dev/null 2>&1
seen_region=$(cat "$REGION_MARKER" 2>/dev/null)
assert_eq "TC-AGENT-SMOKE-032 env-setup BEDROCK_AWS_REGION override beats the conf value (the #222 [P1] regression)" \
  "us-east-2" "$seen_region"

# TC-AGENT-SMOKE-033 — the custom-endpoint blanking shape: conf sets
# CLAUDE_CODE_USE_BEDROCK=1; env-setup unsets it; the stub must see it UNSET.
make_stub claude '
in=$(cat)
printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"
[[ -n "${SMOKE_REGION_MARKER:-}" ]] && printf "%s\n" "${CLAUDE_CODE_USE_BEDROCK:-UNSET}" > "$SMOKE_REGION_MARKER"
exit 0'
: > "$REGION_MARKER"
printf 'r|claude|sonnet|unset CLAUDE_CODE_USE_BEDROCK; export SMOKE_REGION_MARKER=%s\n' "$REGION_MARKER" > "$envorder_conf"
PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$ENVORDER_CONF" SMOKE_CONF="$envorder_conf" \
  bash "$HARNESS" >/dev/null 2>&1
seen_bedrock=$(cat "$REGION_MARKER" 2>/dev/null)
assert_eq "TC-AGENT-SMOKE-033 env-setup unset of a conf-set var survives the conf load (custom-endpoint blanking)" \
  "UNSET" "$seen_bedrock"

# TC-AGENT-SMOKE-034 — smoke_retokenize_launcher honors an AGENT_LAUNCHER set in
# env-setup. Pure-function test (the earlier review's launcher-honored concern).
# Run each case in a FRESH `bash -c` process (not a $(...) subshell, which would
# inherit the test's already-sourced lib state + a pre-populated
# AGENT_LAUNCHER_ARGV and make the assertion depend on prior-test residue).
launcher_test=$(REPO="$REPO" REPO_OWNER="$REPO_OWNER" REPO_NAME="$REPO_NAME" \
  PROJECT_ID="$PROJECT_ID" GH_AUTH_MODE=token HOME="$TEST_HOME" \
  bash -c '
    set -uo pipefail
    source "'"$LIB"'" 2>/dev/null
    AGENT_LAUNCHER="my-launcher --flag"
    smoke_retokenize_launcher
    printf "%s|%s|%s" "${#AGENT_LAUNCHER_ARGV[@]}" "${AGENT_LAUNCHER_ARGV[0]:-}" "${AGENT_LAUNCHER_ARGV[1]:-}"
  ')
assert_eq "TC-AGENT-SMOKE-034a env-setup AGENT_LAUNCHER is re-tokenized into AGENT_LAUNCHER_ARGV" \
  "2|my-launcher|--flag" "$launcher_test"
# Malformed launcher → empty argv, no abort.
launcher_bad=$(REPO="$REPO" REPO_OWNER="$REPO_OWNER" REPO_NAME="$REPO_NAME" \
  PROJECT_ID="$PROJECT_ID" GH_AUTH_MODE=token HOME="$TEST_HOME" \
  bash -c '
    set -uo pipefail
    source "'"$LIB"'" 2>/dev/null
    AGENT_LAUNCHER="unbalanced \"quote"
    smoke_retokenize_launcher 2>/dev/null
    echo "rc=$?|n=${#AGENT_LAUNCHER_ARGV[@]}"
  ')
assert_eq "TC-AGENT-SMOKE-034b malformed AGENT_LAUNCHER → empty argv, rc 0 (no abort)" \
  "rc=0|n=0" "$launcher_bad"

# ---------------------------------------------------------------------------
# TC-AGENT-SMOKE-036 — inherited shared AGENT_LAUNCHER is NEUTRALIZED for a
# non-claude entry (the #222 [P1] review fix). The launcher is a claude-only
# contract; prepending the conf's shared claude launcher to a codex/kiro/agy
# command is a FALSE FAIL. We simulate a configured box via a conf that sets
# AGENT_LAUNCHER to a stub wrapper that records when it runs (then execs "$@").
# ---------------------------------------------------------------------------
# The launcher stub: touches a marker, then invokes `claude` with the flags it
# received — mirroring the canonical `cc` launcher, which ends in
# `$CLAUDE_CMD "$@"` (run_agent's launcher path passes ONLY flags as "$@", not the
# binary name, expecting the launcher to invoke claude itself). For the
# non-claude false-FAIL test (036a/b) this stub is what would WRONGLY wrap a
# codex command; the neutralization prevents that, so the probe never runs there.
make_stub launcher-probe 'printf RAN > "$SMOKE_LAUNCHER_MARKER"; exec claude "$@"'
LAUNCH_CONF=$(mktemp)
cat > "$LAUNCH_CONF" <<CONF
REPO="zxkane/autonomous-dev-team"
REPO_OWNER="zxkane"
REPO_NAME="autonomous-dev-team"
PROJECT_ID="test-agent-smoke"
GH_AUTH_MODE="token"
AGENT_LAUNCHER="$STUB_DIR/launcher-probe"
CONF
LAUNCH_MARKER=$(mktemp); rm -f "$LAUNCH_MARKER"   # absent = launcher did NOT run
launch_conf=$(mktemp)

# A codex stub that echoes the nonce (→ PASS) reading the prompt from stdin (the
# codex branch invokes `codex exec --json -`, stdin prompt). If the claude
# launcher were (wrongly) prepended, argv would be `launcher-probe codex exec …`
# — the marker would be written and the launcher-probe `exec "$@"` would still
# reach codex, so the run could still PASS; the AUTHORITATIVE signal is the
# marker, not the verdict. We assert BOTH: PASS verdict AND no marker.
make_stub codex 'in=$(cat); printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"; exit 0'

# Non-claude (codex) entry, shared launcher inherited from conf, env-setup exports
# the marker path so the launcher-probe can record if it ran.
printf 'c|codex|gpt|export SMOKE_LAUNCHER_MARKER=%s\n' "$LAUNCH_MARKER" > "$launch_conf"
launch_out=$(PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$LAUNCH_CONF" SMOKE_CONF="$launch_conf" \
  bash "$HARNESS" 2>/dev/null)
assert_contains "TC-AGENT-SMOKE-036a non-claude entry with inherited claude launcher → PASS (not a false FAIL)" \
  "SMOKE codex PASS" "$launch_out"
assert_marker "TC-AGENT-SMOKE-036b inherited launcher was NEUTRALIZED for the codex entry (probe did not run)" \
  absent "$LAUNCH_MARKER"

# TC-AGENT-SMOKE-036c — a CLAUDE entry KEEPS the inherited launcher (the launcher
# is claude-only, so for claude it must still apply). The claude branch invokes
# the launcher argv directly (no `env -u` prefix), so launcher-probe runs then
# execs `claude …`; the stub claude echoes the nonce → PASS, and the marker IS
# written.
rm -f "$LAUNCH_MARKER"
printf 'k|claude|sonnet|export SMOKE_LAUNCHER_MARKER=%s\n' "$LAUNCH_MARKER" > "$launch_conf"
launch_claude_out=$(PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$LAUNCH_CONF" SMOKE_CONF="$launch_conf" \
  bash "$HARNESS" 2>/dev/null)
assert_contains "TC-AGENT-SMOKE-036c claude entry with inherited launcher → PASS" \
  "SMOKE claude PASS" "$launch_claude_out"
assert_marker "TC-AGENT-SMOKE-036d inherited launcher PRESERVED for the claude entry (probe ran)" \
  present "$LAUNCH_MARKER"

# TC-AGENT-SMOKE-036e — a non-claude entry whose ENV-SETUP opts INTO a launcher
# keeps it (the neutralization clears only the INHERITED shared launcher, before
# env-setup; an env-setup launcher set AFTER survives). Here env-setup points
# AGENT_LAUNCHER at the probe for a codex entry → the probe MUST run.
rm -f "$LAUNCH_MARKER"
printf 'c|codex|gpt|export SMOKE_LAUNCHER_MARKER=%s; export AGENT_LAUNCHER=%s/launcher-probe\n' \
  "$LAUNCH_MARKER" "$STUB_DIR" > "$launch_conf"
# No conf launcher this time (AUTONOMOUS_CONF without AGENT_LAUNCHER) so the ONLY
# launcher source is the entry env-setup.
launch_optin_conf=$(mktemp)
cat > "$launch_optin_conf" <<CONF
REPO="zxkane/autonomous-dev-team"
REPO_OWNER="zxkane"
REPO_NAME="autonomous-dev-team"
PROJECT_ID="test-agent-smoke"
GH_AUTH_MODE="token"
CONF
PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$launch_optin_conf" SMOKE_CONF="$launch_conf" \
  bash "$HARNESS" >/dev/null 2>&1
assert_marker "TC-AGENT-SMOKE-036e non-claude entry can still opt INTO a launcher via env-setup (probe ran)" \
  present "$LAUNCH_MARKER"

# TC-AGENT-SMOKE-044 — a CUSTOM-ENDPOINT claude entry (agent_cmd=claude, env-setup
# sets ANTHROPIC_BASE_URL) NEUTRALIZES the inherited shared Bedrock launcher even
# though it is a claude entry (#222 [P1] review fix). The non-claude clear (036)
# does NOT fire for claude; without the custom-endpoint clear the inherited `cc`
# launcher survives and would reintroduce Bedrock / fail before the custom
# endpoint runs — a false FAIL. The plain PASS claude stub echoes the nonce, so
# the AUTHORITATIVE signal is the launcher-probe MARKER (must be absent).
make_stub claude 'in=$(cat); printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"; exit 0'
rm -f "$LAUNCH_MARKER"
# Conf with a shared launcher (the probe). The entry is claude + custom endpoint.
printf 'm|claude|MiniMax-M2|export SMOKE_LAUNCHER_MARKER=%s; export ANTHROPIC_BASE_URL=https://api.example.test/anthropic\n' \
  "$LAUNCH_MARKER" > "$launch_conf"
ce_out=$(PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$LAUNCH_CONF" SMOKE_CONF="$launch_conf" \
  bash "$HARNESS" 2>/dev/null)
assert_contains "TC-AGENT-SMOKE-044a custom-endpoint claude entry → PASS (not a false FAIL)" \
  "SMOKE claude PASS" "$ce_out"
assert_marker "TC-AGENT-SMOKE-044b inherited launcher NEUTRALIZED for the custom-endpoint claude entry (probe did not run)" \
  absent "$LAUNCH_MARKER"

# TC-AGENT-SMOKE-044c — a custom-endpoint entry that EXPLICITLY sets its own
# launcher in env-setup keeps it (the clear fires only when env-setup did NOT set
# a launcher — value unchanged from the pre-env-setup snapshot). Here env-setup
# sets ANTHROPIC_BASE_URL AND its own launcher → the probe MUST run.
rm -f "$LAUNCH_MARKER"
printf 'm|claude|MiniMax-M2|export SMOKE_LAUNCHER_MARKER=%s; export ANTHROPIC_BASE_URL=https://api.example.test/anthropic; export AGENT_LAUNCHER=%s/launcher-probe\n' \
  "$LAUNCH_MARKER" "$STUB_DIR" > "$launch_conf"
# Use a conf WITHOUT a shared launcher so the ONLY launcher source is env-setup.
PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$launch_optin_conf" SMOKE_CONF="$launch_conf" \
  bash "$HARNESS" >/dev/null 2>&1
assert_marker "TC-AGENT-SMOKE-044c custom-endpoint entry can still opt INTO its own launcher via env-setup (probe ran)" \
  present "$LAUNCH_MARKER"

rm -f "$LAUNCH_CONF" "$LAUNCH_MARKER" "$launch_conf" "$launch_optin_conf"

# ---------------------------------------------------------------------------
# TC-AGENT-SMOKE-037 — an inherited AGENT_DEV_EXTRA_ARGS is NEUTRALIZED per entry
# (the #222 [P1] review fix). run_agent appends AGENT_DEV_EXTRA_ARGS to EVERY CLI
# branch; the operator's autonomous.conf tunes it for ONE CLI (e.g. kiro's
# `--trust-all-tools`). A codex/claude/agy entry inheriting that flag would FALSE
# FAIL. We simulate a configured box via a conf that sets
# AGENT_DEV_EXTRA_ARGS="--trust-all-tools", and a stub codex that FAILS if it sees
# that flag in its argv (else echoes the nonce → PASS). With the fix the flag is
# cleared → codex never sees it → PASS; without the fix codex sees it → FAIL.
# ---------------------------------------------------------------------------
EXTRA_CONF=$(mktemp)
cat > "$EXTRA_CONF" <<CONF
REPO="zxkane/autonomous-dev-team"
REPO_OWNER="zxkane"
REPO_NAME="autonomous-dev-team"
PROJECT_ID="test-agent-smoke"
GH_AUTH_MODE="token"
AGENT_DEV_EXTRA_ARGS="--trust-all-tools"
CONF
# Stub codex: if any arg is the inherited kiro flag, fail (the false-FAIL the fix
# prevents); otherwise read stdin and echo the nonce → PASS. The codex branch
# invokes `codex exec --json <extra-args> -`, so the flag (if present) lands in argv.
make_stub codex '
for a in "$@"; do [[ "$a" == "--trust-all-tools" ]] && { echo "codex: unknown flag --trust-all-tools" >&2; exit 2; }; done
in=$(cat); printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"; exit 0'
extra_conf=$(mktemp)

# TC-037a — codex entry, inherited kiro extra-args from conf → PASS (flag cleared).
printf 'c|codex|gpt|true\n' > "$extra_conf"
extra_out=$(PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$EXTRA_CONF" SMOKE_CONF="$extra_conf" \
  bash "$HARNESS" 2>/dev/null)
assert_contains "TC-AGENT-SMOKE-037a codex entry with inherited kiro --trust-all-tools → PASS (flag neutralized, not a false FAIL)" \
  "SMOKE codex PASS" "$extra_out"

# TC-037c — a codex entry whose env-setup OPTS INTO a codex-valid extra-arg keeps
# it. Stub codex echoes the nonce only when it receives `--smoke-optin`; the fix
# clears the inherited kiro flag but env-setup's opt-in runs after and survives.
make_stub codex '
seen=""; for a in "$@"; do [[ "$a" == "--trust-all-tools" ]] && { echo "got kiro flag" >&2; exit 2; }; [[ "$a" == "--smoke-optin" ]] && seen=1; done
[[ -n "$seen" ]] || { echo "codex: missing opt-in flag" >&2; exit 5; }
in=$(cat); printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"; exit 0'
printf 'c|codex|gpt|export AGENT_DEV_EXTRA_ARGS=--smoke-optin\n' > "$extra_conf"
extra_optin_out=$(PATH="$STUB_DIR:$ORIG_PATH" AUTONOMOUS_CONF="$EXTRA_CONF" SMOKE_CONF="$extra_conf" \
  bash "$HARNESS" 2>/dev/null)
assert_contains "TC-AGENT-SMOKE-037c codex entry can still opt INTO its own extra-args via env-setup → PASS" \
  "SMOKE codex PASS" "$extra_optin_out"

# Restore the plain codex FAIL stub used by earlier sections.
make_stub codex 'cat >/dev/null; echo "boom" >&2; exit 4'
rm -f "$EXTRA_CONF" "$extra_conf"

rm -f "$ENVORDER_CONF" "$REGION_MARKER" "$envorder_conf"
# Restore the plain PASS stub for any later use.
make_stub claude 'in=$(cat); printf "%s\n" "$(printf "%s" "$in" | grep -oE "SMOKE-[0-9a-f]{16}" | head -1)"; exit 0'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGENT-SMOKE-SRC: source-of-truth / wiring ==="
# ---------------------------------------------------------------------------
# TC-AGENT-SMOKE-050 — bash -n on lib + harness.
if bash -n "$LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-050a lib parses (bash -n)"; PASS=$((PASS + 1))
else echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-050a lib fails bash -n"; FAIL=$((FAIL + 1)); fi
if bash -n "$HARNESS" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-050b harness parses (bash -n)"; PASS=$((PASS + 1))
else echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-050b harness fails bash -n"; FAIL=$((FAIL + 1)); fi

# TC-AGENT-SMOKE-047e — source-of-truth (#222 operator review): the PASS branch
# routes the nonce check through the TTY-sanitizing _smoke_stdout_has_nonce (not a
# raw grep on the stdout file), and the helper strips the BEL/C0 + ANSI CSI.
assert_grep "TC-AGENT-SMOKE-047e PASS branch uses _smoke_stdout_has_nonce (sanitized)" \
  'rc" == "0" \]\] && _smoke_stdout_has_nonce' "$LIB"
assert_grep "TC-AGENT-SMOKE-047f helper strips C0 control bytes incl. the BEL" \
  'tr -d .\\000-\\010\\013-\\037\\177' "$LIB"
assert_grep "TC-AGENT-SMOKE-047g helper strips ANSI CSI sequences" \
  '1b\\\[\[0-9;\]\*\[a-zA-Z\]' "$LIB"

# TC-AGENT-SMOKE-012 — lib goes through run_agent (not a parallel invocation),
# and sets AGENT_CMD/AGENT_TIMEOUT.
assert_grep "TC-AGENT-SMOKE-012c lib calls run_agent" 'run_agent "\$session_id"' "$LIB"
assert_grep "TC-AGENT-SMOKE-012d lib sets AGENT_CMD" 'export AGENT_CMD=' "$LIB"
assert_grep "TC-AGENT-SMOKE-012e lib sets AGENT_TIMEOUT override" 'export AGENT_TIMEOUT=' "$LIB"
# TC-AGENT-SMOKE-038f — smoke_agent builds session_id via _smoke_session_id (a
# valid UUID), NOT the old `smoke-<agent>-…` non-UUID string claude rejects.
assert_grep "TC-AGENT-SMOKE-038f smoke_agent uses _smoke_session_id (UUID) for session_id" \
  'session_id=\$\(_smoke_session_id\)' "$LIB"
assert_grep "TC-AGENT-SMOKE-038g lib does not build a non-UUID smoke-<agent> session id" \
  '/proc/sys/kernel/random/uuid' "$LIB"
# TC-AGENT-SMOKE-039f/g — the #222 [P1] stream separation: smoke_agent captures
# stderr to a SEPARATE file (NOT `2>&1` into stdout), and the nonce PASS check
# greps only the stdout file.
assert_grep "TC-AGENT-SMOKE-039f smoke_agent captures stderr separately (2>\$stderr_file, not 2>&1)" \
  '2>"\$stderr_file"' "$LIB"
# No `>"$stdout_file" 2>&1` merge anywhere in the lib (the regressed form), in any
# spacing. The agent subshell must redirect stdout and stderr to SEPARATE files.
if grep -qE '>"\$stdout_file"[[:space:]]+2>&1' "$LIB"; then
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-039g lib still merges stderr into stdout (2>&1) — stream separation regressed"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-039g lib no longer merges the agent subshell's stderr into the nonce-check stdout file"; PASS=$((PASS + 1))
fi

# TC-AGENT-SMOKE-035 — the #222 [P1] ordering: the harness sources the lib BEFORE
# it evals the entry env-setup, and re-tokenizes the launcher after. Source-of-
# truth (the behavioral proof is TC-032/033/034).
assert_grep "TC-AGENT-SMOKE-035a harness exposes smoke_retokenize_launcher in the lib" \
  'smoke_retokenize_launcher\(\)' "$LIB"
assert_grep "TC-AGENT-SMOKE-035b harness calls smoke_retokenize_launcher after env-setup" \
  'smoke_retokenize_launcher' "$HARNESS"
# The lib `source` line must appear BEFORE the env-setup `eval "$rest"` line in
# _run_entry (the ordering that makes env-setup the last writer).
src_line=$(grep -n 'source "\$LIB_SMOKE"' "$HARNESS" | head -1 | cut -d: -f1)
eval_line=$(grep -n 'eval "\$rest"' "$HARNESS" | head -1 | cut -d: -f1)
if [[ -n "$src_line" && -n "$eval_line" && "$src_line" -lt "$eval_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-035c lib sourced (line $src_line) before env-setup eval (line $eval_line)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-035c lib source must precede env-setup eval (src=$src_line eval=$eval_line)"; FAIL=$((FAIL + 1))
fi

# TC-AGENT-SMOKE-035d — the #222 [P1] launcher-neutralize: the harness clears an
# inherited AGENT_LAUNCHER for a non-claude entry, AFTER the lib source and
# BEFORE the env-setup eval (so env-setup can still opt back in).
assert_grep "TC-AGENT-SMOKE-035d harness clears inherited AGENT_LAUNCHER for non-claude entries" \
  'agent" != "claude" && -n "\$\{AGENT_LAUNCHER' "$HARNESS"
neut_line=$(grep -n 'agent" != "claude" && -n "\${AGENT_LAUNCHER' "$HARNESS" | head -1 | cut -d: -f1)
if [[ -n "$src_line" && -n "$neut_line" && -n "$eval_line" && "$src_line" -lt "$neut_line" && "$neut_line" -lt "$eval_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-035e launcher-neutralize sits AFTER lib source ($src_line) and BEFORE env-setup eval ($eval_line): line $neut_line"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-035e launcher-neutralize must be between source ($src_line) and eval ($eval_line); got $neut_line"; FAIL=$((FAIL + 1))
fi

# TC-AGENT-SMOKE-035f — the #222 [P1] extra-args-neutralize: the harness clears
# the inherited AGENT_DEV_EXTRA_ARGS for EVERY entry, AFTER the lib source and
# BEFORE the env-setup eval.
assert_grep "TC-AGENT-SMOKE-035f harness clears inherited AGENT_DEV_EXTRA_ARGS per entry" \
  '^[[:space:]]*AGENT_DEV_EXTRA_ARGS=""' "$HARNESS"
extra_neut_line=$(grep -n '^[[:space:]]*AGENT_DEV_EXTRA_ARGS=""' "$HARNESS" | head -1 | cut -d: -f1)
if [[ -n "$src_line" && -n "$extra_neut_line" && -n "$eval_line" && "$src_line" -lt "$extra_neut_line" && "$extra_neut_line" -lt "$eval_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-035g extra-args-neutralize sits AFTER lib source ($src_line) and BEFORE env-setup eval ($eval_line): line $extra_neut_line"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-035g extra-args-neutralize must be between source ($src_line) and eval ($eval_line); got $extra_neut_line"; FAIL=$((FAIL + 1))
fi
# TC-AGENT-SMOKE-044d — the #222 [P1] custom-endpoint launcher clear: the harness
# clears an inherited launcher for a custom-endpoint entry (keyed on
# ANTHROPIC_BASE_URL), AFTER env-setup eval and BEFORE the launcher re-tokenize.
assert_grep "TC-AGENT-SMOKE-044d harness neutralizes inherited launcher for a custom-endpoint entry" \
  'if \[\[ -n "\$\{ANTHROPIC_BASE_URL:-\}"' "$HARNESS"
# Match the actual CONDITION line (the `if [[ -n "${ANTHROPIC_BASE_URL:-}" ...`),
# not the ORDER-MATTERS comment block that also mentions ANTHROPIC_BASE_URL.
ce_line=$(grep -nE 'if \[\[ -n "\$\{ANTHROPIC_BASE_URL:-\}"' "$HARNESS" | head -1 | cut -d: -f1)
retok_line=$(grep -n 'smoke_retokenize_launcher$' "$HARNESS" | head -1 | cut -d: -f1)
if [[ -n "$eval_line" && -n "$ce_line" && -n "$retok_line" && "$eval_line" -lt "$ce_line" && "$ce_line" -lt "$retok_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-044e custom-endpoint clear sits AFTER env-setup eval ($eval_line) and BEFORE re-tokenize ($retok_line): line $ce_line"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-044e custom-endpoint clear must be between env-setup eval ($eval_line) and re-tokenize ($retok_line); got $ce_line"; FAIL=$((FAIL + 1))
fi

# TC-AGENT-SMOKE-051 — lib sources lib-agent.sh + the three drop-reason libs.
assert_grep "TC-AGENT-SMOKE-051a sources lib-agent.sh"       'lib-agent\.sh'       "$LIB"
assert_grep "TC-AGENT-SMOKE-051b sources lib-review-agy.sh"  'lib-review-agy\.sh'  "$LIB"
assert_grep "TC-AGENT-SMOKE-051c sources lib-review-kiro.sh" 'lib-review-kiro\.sh' "$LIB"
assert_grep "TC-AGENT-SMOKE-051d sources lib-review-codex.sh" 'lib-review-codex\.sh' "$LIB"
assert_grep "TC-AGENT-SMOKE-051e uses BASH_SOURCE-relative dir (INV-14)" 'BASH_SOURCE' "$LIB"

# TC-AGENT-SMOKE-052 — CI shellcheck lists the new files.
assert_grep "TC-AGENT-SMOKE-052a CI shellcheck lists lib-agent-smoke.sh" 'lib-agent-smoke\.sh' "$CI"
assert_grep "TC-AGENT-SMOKE-052b CI shellcheck lists run-agent-smoke.sh" 'run-agent-smoke\.sh' "$CI"
# TC-AGENT-SMOKE-053 — CI runs the stub-mode self-test.
assert_grep "TC-AGENT-SMOKE-053 CI runs SMOKE_STUB self-test" 'SMOKE_STUB' "$CI"

# TC-AGENT-SMOKE-054 — .gitignore covers tests/e2e/e2e.conf.
assert_grep "TC-AGENT-SMOKE-054 .gitignore covers tests/e2e/e2e.conf" 'tests/e2e/e2e\.conf' "$GITIGNORE"

# TC-AGENT-SMOKE-055 — example matrix covers the 5 required CLI shapes + no keys.
assert_grep "TC-AGENT-SMOKE-055a example: claude bedrock"        'claude-bedrock'  "$CONF_EXAMPLE"
assert_grep "TC-AGENT-SMOKE-055b example: codex bedrock"         'codex-bedrock'   "$CONF_EXAMPLE"
assert_grep "TC-AGENT-SMOKE-055c example: kiro"                  'kiro-default'    "$CONF_EXAMPLE"
assert_grep "TC-AGENT-SMOKE-055c2 example: kiro entry sets KIRO_AGENT_NAME (#222 finding 3)" \
  'KIRO_AGENT_NAME=default' "$CONF_EXAMPLE"
assert_grep "TC-AGENT-SMOKE-055d example: agy"                   'agy-default'     "$CONF_EXAMPLE"
assert_grep "TC-AGENT-SMOKE-055e example: claude custom endpoint" 'claude-minimax' "$CONF_EXAMPLE"
assert_grep "TC-AGENT-SMOKE-055f example pins codex Bedrock region (#180)" 'BEDROCK_AWS_REGION=us-east-2' "$CONF_EXAMPLE"
assert_grep "TC-AGENT-SMOKE-055g example uses require: for the custom-endpoint key" 'require:ANTHROPIC_API_KEY' "$CONF_EXAMPLE"
# No obvious secret material committed (sk-..., long base64 keys, AWS keys).
if grep -qE '(sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN )' "$CONF_EXAMPLE" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-AGENT-SMOKE-055h example matrix appears to contain a secret"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-AGENT-SMOKE-055h example matrix has no obvious secret material"; PASS=$((PASS + 1))
fi

# TC-AGENT-SMOKE-056 — docs.
assert_grep "TC-AGENT-SMOKE-056a docs/pipeline/agent-smoke.md exists with the three-state contract" 'three-state' "$DOC_SMOKE"
assert_grep "TC-AGENT-SMOKE-056b INV-63 entry in invariants.md" 'INV-63' "$INVARIANTS"
assert_grep "TC-AGENT-SMOKE-056c autonomous-pipeline.md references the smoke" 'agent-smoke' "$PIPELINE_DOC"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
