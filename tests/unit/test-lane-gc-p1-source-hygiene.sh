#!/bin/bash
# test-lane-gc-p1-source-hygiene.sh — Unit tests for issue #377 (Lane-GC series
# PR-1, design docs/designs/lane-containment-gc.md §4-C8).
#
# Covers:
#   - gh-token-refresh-daemon.sh: 60s-chunked PPID-checked sleep + TERM/INT trap
#     reaping the in-flight sleep child (RC5); GH token values scrubbed from the
#     daemon's spawned env (both setup_github_auth and setup_agent_token sites).
#   - tests/unit/test-token-split-234.sh stub daemon fixture: PPID watchdog
#     replacing `sleep 99999` (grep-pin — behavior itself is covered by that
#     file's own app-mode tests).
#   - skills/autonomous-common/hooks/lib.sh: read_hook_stdin timeout wrap (RC6),
#     applied across all 12 hooks that previously read stdin via `input=$(cat)`.
#
# Run: bash tests/unit/test-lane-gc-p1-source-hygiene.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
HOOKS="$PROJECT_ROOT/skills/autonomous-common/hooks"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

TMPROOT=$(mktemp -d)
trap 'pkill -f "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# Poll for a file to become non-empty (bounded to ~4s at the default 20×0.2s).
# Usage: wait_for_file <path> [attempts]
wait_for_file() {
  local f="$1" n="${2:-20}"
  for _ in $(seq 1 "$n"); do [[ -s "$f" ]] && break; sleep 0.2; done
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-040: design doc committed byte-identical to the prework branch ==="
# ---------------------------------------------------------------------------
DESIGN_DOC="$PROJECT_ROOT/docs/designs/lane-containment-gc.md"
if [[ -f "$DESIGN_DOC" ]]; then
  if git -C "$PROJECT_ROOT" show docs/lane-gc-design-prework:docs/designs/lane-containment-gc.md 2>/dev/null \
      | diff -q - "$DESIGN_DOC" >/dev/null 2>&1; then
    assert_pass "docs/designs/lane-containment-gc.md is byte-identical to the prework branch copy"
  else
    assert_fail "docs/designs/lane-containment-gc.md diverges from the prework branch copy"
  fi
else
  assert_fail "docs/designs/lane-containment-gc.md missing"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-001/002/004/005: token daemon chunked sleep + TERM trap ==="
# ---------------------------------------------------------------------------
DSB="$TMPROOT/daemon-sb"; mkdir -p "$DSB"
cp "$SCRIPTS/gh-token-refresh-daemon.sh" "$DSB/"
cat > "$DSB/gh-app-token.sh" <<'STUB'
#!/bin/bash
get_gh_app_token() { echo "stub-token-value"; }
STUB

# TC-LGC1-002: TERM sent mid-sleep reaps the in-flight sleep child immediately.
TOKFILE="$DSB/token-term"
GH_TOKEN_REFRESH_INTERVAL=120 bash "$DSB/gh-token-refresh-daemon.sh" \
  "$TOKFILE" "app" "pem" "owner" "repo" >/dev/null 2>&1 &
DPID=$!
wait_for_file "$TOKFILE"
sleep 0.3
SLEEP_CHILD=$(pgrep -P "$DPID" | head -1)
if [[ -z "$SLEEP_CHILD" ]]; then
  assert_fail "TC-LGC1-002: could not find the daemon's in-flight sleep child"
else
  kill -TERM "$DPID" 2>/dev/null
  sleep 1
  if ! kill -0 "$DPID" 2>/dev/null && ! kill -0 "$SLEEP_CHILD" 2>/dev/null; then
    assert_pass "TC-LGC1-002: TERM reaps both the daemon and its in-flight sleep child immediately"
  else
    assert_fail "TC-LGC1-002: daemon or sleep child survived TERM (daemon_alive=$(kill -0 "$DPID" 2>/dev/null && echo yes || echo no), sleep_alive=$(kill -0 "$SLEEP_CHILD" 2>/dev/null && echo yes || echo no))"
  fi
fi
wait "$DPID" 2>/dev/null || true

# TC-LGC1-001: SIGKILL the daemon; the orphaned sleep child self-expires within
# <= 60s (never the full REFRESH_INTERVAL). We assert the chunk size directly
# rather than sleeping 60s in CI: the child's argv must be `sleep <= 60`.
TOKFILE2="$DSB/token-kill"
GH_TOKEN_REFRESH_INTERVAL=180 bash "$DSB/gh-token-refresh-daemon.sh" \
  "$TOKFILE2" "app" "pem" "owner" "repo" >/dev/null 2>&1 &
DPID2=$!
wait_for_file "$TOKFILE2"
sleep 0.3
SLEEP_CHILD2=$(pgrep -P "$DPID2" | head -1)
CHILD_CMD=$(ps -o args= -p "$SLEEP_CHILD2" 2>/dev/null || echo "")
kill -9 "$DPID2" 2>/dev/null
wait "$DPID2" 2>/dev/null || true
if [[ "$CHILD_CMD" =~ ^sleep\ ([0-9]+) ]]; then
  chunk="${BASH_REMATCH[1]}"
  if [[ "$chunk" -le 60 ]]; then
    assert_pass "TC-LGC1-001: SIGKILLed daemon's in-flight sleep child is chunked to <= 60s (saw 'sleep $chunk', REFRESH_INTERVAL=180)"
  else
    assert_fail "TC-LGC1-001: sleep child chunk exceeds 60s (saw 'sleep $chunk')"
  fi
else
  assert_fail "TC-LGC1-001: could not observe the daemon's sleep child argv (saw: '$CHILD_CMD')"
fi
kill -9 "$SLEEP_CHILD2" 2>/dev/null || true

# TC-LGC1-004: a REFRESH_INTERVAL at/above the 60s floor (pre-existing
# clamp at daemon.sh:57-60 raises anything < 60 to 60, so use 75s — above the
# floor but below the 120s two-chunk boundary) produces a single chunk equal
# to the interval itself, not a needlessly split 60+15.
TOKFILE3="$DSB/token-short"
GH_TOKEN_REFRESH_INTERVAL=75 bash "$DSB/gh-token-refresh-daemon.sh" \
  "$TOKFILE3" "app" "pem" "owner" "repo" >/dev/null 2>&1 &
DPID3=$!
wait_for_file "$TOKFILE3"
sleep 0.3
CHILD3_CMD=$(ps -o args= -p "$(pgrep -P "$DPID3" | head -1)" 2>/dev/null || echo "")
kill -9 "$DPID3" 2>/dev/null
wait "$DPID3" 2>/dev/null || true
pkill -9 -P "$DPID3" 2>/dev/null || true
if [[ "$CHILD3_CMD" == "sleep 60" ]]; then
  assert_pass "TC-LGC1-004: REFRESH_INTERVAL=75 produces a 'sleep 60' first chunk (60s cap, 15s remainder queued next)"
else
  assert_fail "TC-LGC1-004: expected 'sleep 60', saw '$CHILD3_CMD'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-003: daemon exits when its real parent dies mid-sleep ==="
# ---------------------------------------------------------------------------
TOKFILE4="$DSB/token-orphan"
bash -c "
  GH_TOKEN_REFRESH_INTERVAL=90 bash '$DSB/gh-token-refresh-daemon.sh' \
    '$TOKFILE4' app pem owner repo >/dev/null 2>&1 &
  echo \$! > '$DSB/orphan-daemon.pid'
  # exit immediately without waiting — the daemon's PPID becomes unreachable
" &
PARENT_SHELL=$!
wait "$PARENT_SHELL" 2>/dev/null
DPID4=$(cat "$DSB/orphan-daemon.pid" 2>/dev/null || echo "")
wait_for_file "$TOKFILE4"
if [[ -n "$DPID4" ]]; then
  # Give the daemon up to ~65s to notice via its chunked PPID check. Since the
  # parent shell already exited, the check should fire on the FIRST chunk
  # boundary the daemon reaches after the parent's death, well under 65s. We
  # poll rather than sleeping the worst case.
  found_dead=0
  for _ in $(seq 1 65); do
    kill -0 "$DPID4" 2>/dev/null || { found_dead=1; break; }
    sleep 1
  done
  if [[ "$found_dead" -eq 1 ]]; then
    assert_pass "TC-LGC1-003: daemon exits after detecting its dead parent (within 65s poll)"
  else
    assert_fail "TC-LGC1-003: daemon still alive 65s after its parent exited"
    kill -9 "$DPID4" 2>/dev/null || true
  fi
else
  assert_fail "TC-LGC1-003: could not capture the orphaned daemon's PID"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-010/011: token daemon env scrub (no GH token values reach the daemon) ==="
# ---------------------------------------------------------------------------
LASB="$TMPROOT/lib-auth-sb"; mkdir -p "$LASB"
cp "$SCRIPTS/lib-auth.sh" "$LASB/lib-auth.sh"
cp "$SCRIPTS/gh-with-token-refresh.sh" "$LASB/gh-with-token-refresh.sh" 2>/dev/null || true
mkdir -p "$LASB/providers"
cp "$SCRIPTS/lib-code-host.sh" "$LASB/lib-code-host.sh" 2>/dev/null || true
cp "$SCRIPTS/providers/chp-github.sh" "$LASB/providers/chp-github.sh" 2>/dev/null || true
cp "$SCRIPTS/providers/chp-github.caps" "$LASB/providers/chp-github.caps" 2>/dev/null || true
cat > "$LASB/lib-config.sh" <<'CFG'
#!/bin/bash
load_autonomous_conf() { return 0; }
CFG
cat > "$LASB/gh-app-token.sh" <<'GAT'
#!/bin/bash
get_gh_app_token() { echo "SCOPED-TOKEN-abc123"; }
get_gh_app_scoped_token() { echo "SCOPED-TOKEN-abc123"; }
GAT
# Daemon stub: dump its OWN environ to a sentinel file (proves what the daemon
# actually inherited), then write the token and idle briefly.
cat > "$LASB/gh-token-refresh-daemon.sh" <<'DAEMON'
#!/bin/bash
tr '\0' '\n' < /proc/self/environ > "${1}.environ-dump" 2>/dev/null || env > "${1}.environ-dump"
echo "SCOPED-TOKEN-abc123" > "$1"
sleep 3
DAEMON

# GH_WRAPPER_DIR is a fresh /tmp/agent-auth-XXXXXX dir minted by
# _ensure_gh_wrapper_dir (not under $LASB) and cleanup_github_auth rm -rf's it
# — echo its path out and copy the dumps into $LASB BEFORE cleanup runs.
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  GH_USER_PAT="fullpat-value" REPO_OWNER="owner" REPO_NAME="repo" \
  GH_TOKEN="wrapper-token-value" GITHUB_PERSONAL_ACCESS_TOKEN="wrapper-token-value" \
  GITHUB_TOKEN="wrapper-token-value" \
  bash -c "
  source '$LASB/lib-auth.sh'
  GH_AUTH_MODE='app'
  setup_github_auth '12345' '/nonexistent.pem' >/dev/null 2>&1
  setup_agent_token '12345' '/nonexistent.pem' >/dev/null 2>&1
  sleep 1
  cp \"\$GH_WRAPPER_DIR/token.environ-dump\" '$LASB/token.environ-dump' 2>/dev/null
  cp \"\$GH_WRAPPER_DIR/agent-token.environ-dump\" '$LASB/agent-token.environ-dump' 2>/dev/null
  cp \"\$GH_TOKEN_FILE\" '$LASB/token.written' 2>/dev/null
  cleanup_github_auth >/dev/null 2>&1
"
WRAPPER_DUMP="$LASB/token.environ-dump"
AGENT_DUMP="$LASB/agent-token.environ-dump"
[[ -f "$WRAPPER_DUMP" ]] || WRAPPER_DUMP=""
[[ -f "$AGENT_DUMP" ]] || AGENT_DUMP=""

if [[ -n "$WRAPPER_DUMP" ]]; then
  if grep -qE '^(GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN|GH_USER_PAT)=' "$WRAPPER_DUMP"; then
    assert_fail "TC-LGC1-010: wrapper-token daemon environ still carries a GH token value"
  else
    assert_pass "TC-LGC1-010: wrapper-token daemon environ has NO GH_TOKEN/GITHUB_TOKEN/GITHUB_PERSONAL_ACCESS_TOKEN/GH_USER_PAT values"
  fi
else
  assert_fail "TC-LGC1-010: could not capture the wrapper-token daemon's environ dump"
fi

if [[ -n "$AGENT_DUMP" ]]; then
  if grep -qE '^(GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN|GH_USER_PAT)=' "$AGENT_DUMP"; then
    assert_fail "TC-LGC1-011: agent-scoped-token daemon environ still carries a GH token value"
  else
    assert_pass "TC-LGC1-011: agent-scoped-token daemon environ has NO GH_TOKEN/GITHUB_TOKEN/GITHUB_PERSONAL_ACCESS_TOKEN/GH_USER_PAT values"
  fi
else
  assert_fail "TC-LGC1-011: could not capture the agent-token daemon's environ dump"
fi

# TC-LGC1-012: the scrub doesn't break the mint — token files still land.
if [[ -s "$LASB/token.written" ]]; then
  assert_pass "TC-LGC1-012: wrapper token file still written despite the env scrub"
else
  assert_fail "TC-LGC1-012: wrapper token file missing/empty after the env scrub"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-020/023: fixture stub daemon leaves no orphan process ==="
# ---------------------------------------------------------------------------
SBROOT="$TMPROOT/fixture-sb"; mkdir -p "$SBROOT"
cat > "$SBROOT/gh-token-refresh-daemon.sh" <<'DAEMON'
#!/bin/bash
echo "SCOPED-TOKEN-abc123" > "$1"
while kill -0 "$PPID" 2>/dev/null; do sleep 5; done
DAEMON
bash "$SBROOT/gh-token-refresh-daemon.sh" "$SBROOT/tok" &
STUBPID=$!
wait_for_file "$SBROOT/tok"
kill "$STUBPID" 2>/dev/null
wait "$STUBPID" 2>/dev/null
sleep 0.5
if pgrep -f "$SBROOT" >/dev/null 2>&1; then
  assert_fail "TC-LGC1-020: stub daemon left a surviving process under $SBROOT"
  pkill -9 -f "$SBROOT" 2>/dev/null
else
  assert_pass "TC-LGC1-020: kill+wait on the stub daemon leaves zero survivors (pgrep -f finds nothing)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-021: fixture stub watchdog self-exits when parent dies without an explicit kill ==="
# ---------------------------------------------------------------------------
SBROOT2="$TMPROOT/fixture-sb2"; mkdir -p "$SBROOT2"
cp "$SBROOT/gh-token-refresh-daemon.sh" "$SBROOT2/"
bash -c "
  bash '$SBROOT2/gh-token-refresh-daemon.sh' '$SBROOT2/tok' &
  echo \$! > '$SBROOT2/stub.pid'
" &
wait
wait_for_file "$SBROOT2/tok"
STUBPID2=$(cat "$SBROOT2/stub.pid" 2>/dev/null || echo "")
found_dead=0
for _ in $(seq 1 10); do
  kill -0 "$STUBPID2" 2>/dev/null || { found_dead=1; break; }
  sleep 1
done
if [[ "$found_dead" -eq 1 ]]; then
  assert_pass "TC-LGC1-021: stub watchdog self-exits within 10s of its real parent dying (no explicit kill needed)"
else
  assert_fail "TC-LGC1-021: stub watchdog survived 10s after its parent exited"
  kill -9 "$STUBPID2" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-022: harness-level EXIT trap sweeps any leaked daemon under TMPROOT ==="
# ---------------------------------------------------------------------------
# Run a NESTED bash subprocess that mimics test-token-split-234.sh's own
# TMPROOT + trap structure, deliberately spawning a daemon it does NOT
# explicitly kill, to prove the trap alone reaps it.
NESTED_OUT=$(bash -c '
  TMPROOT2=$(mktemp -d)
  trap "pkill -f \"\$TMPROOT2\" 2>/dev/null; rm -rf \"\$TMPROOT2\"" EXIT
  cat > "$TMPROOT2/gh-token-refresh-daemon.sh" <<EOF
#!/bin/bash
echo tok > "\$1"
while kill -0 "\$PPID" 2>/dev/null; do sleep 5; done
EOF
  bash "$TMPROOT2/gh-token-refresh-daemon.sh" "$TMPROOT2/tok" &
  for _ in $(seq 1 20); do [[ -s "$TMPROOT2/tok" ]] && break; sleep 0.2; done
  echo "$TMPROOT2"
')
sleep 0.5
if pgrep -f "$NESTED_OUT" >/dev/null 2>&1; then
  assert_fail "TC-LGC1-022: harness EXIT trap left a surviving daemon under $NESTED_OUT"
  pkill -9 -f "$NESTED_OUT" 2>/dev/null
else
  assert_pass "TC-LGC1-022: harness-level EXIT trap alone (no explicit per-test kill) reaps the daemon on exit"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-030/031/032/033: read_hook_stdin timeout wrap ==="
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$HOOKS/lib.sh"

# TC-LGC1-030: EOF'd stdin returns immediately, empty.
out030=$(printf '' | read_hook_stdin)
if [[ -z "$out030" ]]; then
  assert_pass "TC-LGC1-030: EOF'd stdin returns immediately with empty output"
else
  assert_fail "TC-LGC1-030: expected empty output, got '$out030'"
fi

# TC-LGC1-031: normal payload passes through unchanged.
out031=$(printf '{"tool_input":{"command":"git push"}}' | read_hook_stdin)
if [[ "$out031" == '{"tool_input":{"command":"git push"}}' ]]; then
  assert_pass "TC-LGC1-031: normal JSON payload passes through byte-identical"
else
  assert_fail "TC-LGC1-031: payload mismatch (got '$out031')"
fi

# TC-LGC1-032: open-but-silent stdin (never EOFs, no data) is bounded by the
# timeout — this is the load-241 shape (a non-blocking descriptor that never
# produces EOF). We use a FIFO whose write end we hold open without writing.
FIFO="$TMPROOT/stdin-fifo"
mkfifo "$FIFO"
( sleep 15 > "$FIFO" ) &
FIFO_HOLDER=$!
START_TS=$SECONDS
out032=$(read_hook_stdin < "$FIFO")
ELAPSED=$((SECONDS - START_TS))
kill "$FIFO_HOLDER" 2>/dev/null; wait "$FIFO_HOLDER" 2>/dev/null || true
if [[ "$ELAPSED" -le 7 && -z "$out032" ]]; then
  assert_pass "TC-LGC1-032: open-but-silent stdin returns within the timeout bound (${ELAPSED}s <= 7s), not hung"
else
  assert_fail "TC-LGC1-032: read_hook_stdin took ${ELAPSED}s (expected <= 7s) or returned non-empty ('$out032')"
fi

# TC-LGC1-033: the bound is a bash builtin (`read -t`), not the external
# `timeout` binary — no feature-detection, no degraded fallback that could
# reintroduce the CPU-spin bug on a host without `timeout`. Prove the guard
# holds even with `timeout` absent from PATH (bash itself must stay
# resolvable, so PATH is rewritten INSIDE the subshell, not the outer one).
FAKEBIN="$TMPROOT/fakebin"; mkdir -p "$FAKEBIN"
ln -sf "$(command -v cat)" "$FAKEBIN/cat"
out033=$(bash -c "PATH='$FAKEBIN'; source '$HOOKS/lib.sh'; printf '{\"a\":1}' | read_hook_stdin")
if [[ "$out033" == '{"a":1}' ]]; then
  assert_pass "TC-LGC1-033: read_hook_stdin works with 'timeout' entirely absent from PATH (no feature-detection needed)"
else
  assert_fail "TC-LGC1-033: read_hook_stdin broken without 'timeout' on PATH (out='$out033')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC1-034/035: grep-pin — all 12 hooks migrated, lib.sh sourced first ==="
# ---------------------------------------------------------------------------
declare -a HOOK_FILES=(
  check-pr-review.sh block-push-to-main.sh warn-skip-verification.sh
  check-unit-tests.sh check-design-canvas.sh check-code-simplifier.sh
  block-commit-outside-worktree.sh post-git-action-clear.sh check-shellcheck.sh
  post-git-push.sh check-test-plan.sh check-rebase-before-push.sh
)

stale_cat=0
missing_wrapper=0
for f in "${HOOK_FILES[@]}"; do
  path="$HOOKS/$f"
  [[ -f "$path" ]] || { missing_wrapper=$((missing_wrapper + 1)); continue; }
  grep -qE '^input=\$\(cat\)$' "$path" && stale_cat=$((stale_cat + 1))
  grep -qE '^input=\$\(read_hook_stdin\)$' "$path" || missing_wrapper=$((missing_wrapper + 1))
done
if [[ "$stale_cat" -eq 0 ]]; then
  assert_pass "TC-LGC1-034: 0 remaining bare 'input=\$(cat)' occurrences across the 12 hooks"
else
  assert_fail "TC-LGC1-034: $stale_cat hook(s) still use bare 'input=\$(cat)'"
fi
if [[ "$missing_wrapper" -eq 0 ]]; then
  assert_pass "TC-LGC1-034: all 12 hooks call 'input=\$(read_hook_stdin)'"
else
  assert_fail "TC-LGC1-034: $missing_wrapper hook(s) missing the read_hook_stdin call"
fi

order_ok=1
for f in "${HOOK_FILES[@]}"; do
  path="$HOOKS/$f"
  [[ -f "$path" ]] || continue
  src_line=$(grep -n 'source.*lib\.sh' "$path" | head -1 | cut -d: -f1)
  call_line=$(grep -n 'read_hook_stdin' "$path" | head -1 | cut -d: -f1)
  if [[ -z "$src_line" || -z "$call_line" || "$src_line" -ge "$call_line" ]]; then
    order_ok=0
    echo "    ordering issue in $f (source=$src_line, call=$call_line)"
  fi
done
if [[ "$order_ok" -eq 1 ]]; then
  assert_pass "TC-LGC1-035: all 12 hooks source lib.sh before calling read_hook_stdin"
else
  assert_fail "TC-LGC1-035: at least one hook calls read_hook_stdin before sourcing lib.sh"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
# ---------------------------------------------------------------------------
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
