#!/bin/bash
# test-lib-review-kiro.sh — Unit tests for the kiro auth/login-failure drop-reason
# classifier (INV-61, issue #215).
#
# When a `kiro` review fan-out member is dropped `unavailable` because its stored
# OAuth/login token on the execution host expired — the CLI tries to open a
# browser for device-flow re-auth, impossible in the headless SSM-spawned shell,
# and exits at launch with no verdict — the wrapper reported a bare, opaque
# `unavailable` with no reason. This lib is the third CLI-specific review-side
# drop-reason classifier (the sibling of agy's INV-58 quota detector and codex's
# INV-59 stream-error detector): it scrapes kiro's generic per-agent log for the
# auth/login signal and names a SPECIFIC reason. Observability only — the INV-40
# vote is unchanged.
#
# Tests:
#   - _classify_kiro_drop_reason: detects the auth/login signal (echoes
#     `auth-failed`), empty otherwise, fail-safe rc 0 always
#   - _kiro_drop_reason_phrase: renders the token into a human clause
#   - the drop-reason assembly loop (behavioral, against the real libs)
#   - wrapper wiring (source-of-truth greps)
#
# Run: bash tests/unit/test-lib-review-kiro.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-kiro.sh"
AGY_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-agy.sh"
CODEX_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-codex.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
CI="$PROJECT_ROOT/.github/workflows/ci.yml"
FIXTURES="$SCRIPT_DIR/fixtures"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

[[ -f "$LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $LIB not found — implementation step required first"
  echo "  PASS: $PASS"
  echo "  FAIL: $((FAIL + 1))"
  exit 1
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-kiro.sh
source "$LIB"

# A real-shape kiro auth-failure log (the four signal lines from the issue),
# wrapped in a little leading/trailing noise to prove the scan is substring-based.
AUTH_FAIL_LOG='Loading Kiro CLI...
Starting review session...
Authenticating...
▰▱▱ Opening browser... | Press (^) + C to cancel
Failed to open browser for authentication.
Please try again with: kiro-cli login --use-device-flow
error: Failed to open URL'

# A clean no-verdict kiro turn: kiro launched, ran, but produced no verdict (a
# code-side miss, NOT an auth failure). MUST classify empty (no over-claim).
CLEAN_NOVERDICT_LOG='Loading Kiro CLI...
Starting review session...
Reading the PR diff...
Ran git diff and gh pr view.
Turn complete; no findings posted.'

# ---------------------------------------------------------------------------
echo "=== TC-KIRO-DROP-CLS: _classify_kiro_drop_reason ==="
# ---------------------------------------------------------------------------
KLOG=$(mktemp)
trap 'rm -f "$KLOG"' EXIT

# TC-KIRO-DROP-CLS-01 — full auth-failure signal → auth-failed
printf '%s\n' "$AUTH_FAIL_LOG" > "$KLOG"
assert_eq "TC-KIRO-DROP-CLS-01 auth-failure log → auth-failed" \
  "auth-failed" "$(_classify_kiro_drop_reason "$KLOG")"

# TC-KIRO-DROP-CLS-02 — clean no-verdict turn → empty (no over-claim)
printf '%s\n' "$CLEAN_NOVERDICT_LOG" > "$KLOG"
assert_eq "TC-KIRO-DROP-CLS-02 clean no-verdict turn → empty (caller keeps bare unavailable)" \
  "" "$(_classify_kiro_drop_reason "$KLOG")"

# TC-KIRO-DROP-CLS-03 — empty / missing / empty-arg → empty, no crash
: > "$KLOG"
assert_eq "TC-KIRO-DROP-CLS-03a empty log → empty" "" "$(_classify_kiro_drop_reason "$KLOG")"
assert_eq "TC-KIRO-DROP-CLS-03b missing log → empty" "" "$(_classify_kiro_drop_reason "/nonexistent/path/$$")"
assert_eq "TC-KIRO-DROP-CLS-03c empty arg → empty" "" "$(_classify_kiro_drop_reason "")"

# TC-KIRO-DROP-CLS-04 — each individual signal substring alone classifies auth-failed.
# Any ONE of the documented signals is sufficient.
printf 'error: Failed to open URL\n' > "$KLOG"
assert_eq "TC-KIRO-DROP-CLS-04a 'Failed to open URL' alone → auth-failed" \
  "auth-failed" "$(_classify_kiro_drop_reason "$KLOG")"
printf 'Please try again with: kiro-cli login --use-device-flow\n' > "$KLOG"
assert_eq "TC-KIRO-DROP-CLS-04b '--use-device-flow' alone → auth-failed" \
  "auth-failed" "$(_classify_kiro_drop_reason "$KLOG")"
printf 'Failed to open browser for authentication.\n' > "$KLOG"
assert_eq "TC-KIRO-DROP-CLS-04c 'Failed to open browser for authentication' alone → auth-failed" \
  "auth-failed" "$(_classify_kiro_drop_reason "$KLOG")"

# TC-KIRO-DROP-CLS-05 — committed fixture (sanitized real auth-failure log)
assert_eq "TC-KIRO-DROP-CLS-05 committed auth-failed fixture → auth-failed" \
  "auth-failed" "$(_classify_kiro_drop_reason "$FIXTURES/kiro-auth-failed.fixture")"

# TC-KIRO-DROP-CLS-06 — command-substitution call under set -euo pipefail (no abort)
cls06=$(
  set -euo pipefail
  source "$LIB"
  printf '%s\n' "$AUTH_FAIL_LOG" > "$KLOG"
  out=$(_classify_kiro_drop_reason "$KLOG")
  echo "rc=$?|$out"
)
assert_eq "TC-KIRO-DROP-CLS-06 no crash under set -euo pipefail (command-subst)" \
  "rc=0|auth-failed" "$cls06"

# TC-KIRO-DROP-CLS-07 — fail-safe for a BARE call (not in a command substitution)
# under `set -euo pipefail`. Mirrors the codex CLS-08 dual-call guard: a bare call
# applies errexit to the function body directly (command substitution suppresses
# it), so a grep-no-match rc 1 inside the body must NOT abort before the
# load-bearing `return 0`. Exercised on BOTH a signal log (matches) and a
# signal-free log (the grep returns rc 1) so the no-match path is covered.
cls07a=$(
  set -euo pipefail
  source "$LIB"
  printf '%s\n' "$AUTH_FAIL_LOG" > "$KLOG"
  _classify_kiro_drop_reason "$KLOG"   # BARE call — errexit applies to the body
  echo "REACHED_RETURN_0"              # only prints if the function did not abort
)
assert_eq "TC-KIRO-DROP-CLS-07a bare call, signal log → no errexit abort" \
  $'auth-failed\nREACHED_RETURN_0' "$cls07a"
cls07b=$(
  set -euo pipefail
  source "$LIB"
  printf '%s\n' "$CLEAN_NOVERDICT_LOG" > "$KLOG"
  _classify_kiro_drop_reason "$KLOG"   # BARE call, signal-free → grep rc 1 path
  echo "REACHED_RETURN_0"
)
assert_eq "TC-KIRO-DROP-CLS-07b bare call, signal-free log → no errexit abort, empty + reaches return 0" \
  "REACHED_RETURN_0" "$cls07b"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-DROP-PHR: _kiro_drop_reason_phrase ==="
# ---------------------------------------------------------------------------
kphr01=$(_kiro_drop_reason_phrase "auth-failed")
assert_contains "TC-KIRO-DROP-PHR-01a phrase names auth-failed" "auth-failed" "$kphr01"
assert_contains "TC-KIRO-DROP-PHR-01b phrase names the remedy command" "kiro-cli login --use-device-flow" "$kphr01"

assert_eq "TC-KIRO-DROP-PHR-02 empty token → empty phrase" "" "$(_kiro_drop_reason_phrase "")"
assert_eq "TC-KIRO-DROP-PHR-03 unknown token → empty phrase" "" "$(_kiro_drop_reason_phrase "something-else")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-DROP-LOOP: drop-reason augmentation loop (behavioral) ==="
# ---------------------------------------------------------------------------
# Mirror the wrapper's per-agent _dropped_reasons loop body verbatim against the
# real libs (agy + codex + kiro). FAILS before the fix (no kiro branch → a
# kiro auth-failure reads identically to a launch failure; a fan-out dropping BOTH
# agy and kiro lists a reason only for agy). Sources lib-review-agy.sh +
# lib-review-codex.sh so the multi-dropped case exercises all three libs.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-agy.sh
source "$AGY_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-codex.sh
source "$CODEX_LIB"

# build_dropped_reasons <agent>:<verdict>:<logfixture> ...
#   Mirrors the wrapper's per-agent loop body verbatim against the real libs:
#   for an `unavailable` agy → agy classifier; codex → codex classifier;
#   kiro → kiro classifier. Echoes the assembled `_dropped_reasons` (trailing
#   `; ` trimmed).
build_dropped_reasons() {
  local spec agent verdict logf reasons="" tok
  for spec in "$@"; do
    agent="${spec%%:*}"; spec="${spec#*:}"
    verdict="${spec%%:*}"; logf="${spec#*:}"
    [[ "$verdict" == "unavailable" ]] || continue
    if [[ "$agent" == "agy" ]]; then
      tok=$(_classify_agy_drop_reason "$logf")
      [[ -n "$tok" ]] && reasons+="${agent}: $(_agy_drop_reason_phrase "$tok"); "
    elif [[ "$agent" == "codex" ]]; then
      tok=$(_classify_codex_drop_reason "$logf")
      [[ -n "$tok" ]] && reasons+="${agent}: $(_codex_drop_reason_phrase "$tok"); "
    elif [[ "$agent" == "kiro" ]]; then
      tok=$(_classify_kiro_drop_reason "$logf")
      [[ -n "$tok" ]] && reasons+="${agent}: $(_kiro_drop_reason_phrase "$tok"); "
    fi
  done
  printf '%s' "${reasons%; }"
}

# TC-KIRO-DROP-LOOP-01 — kiro dropped on an auth-failure log → reason names kiro + auth-failed
loop01=$(build_dropped_reasons "kiro:unavailable:$FIXTURES/kiro-auth-failed.fixture")
assert_contains "TC-KIRO-DROP-LOOP-01 auth-failure loop reason names kiro + auth-failed" \
  "kiro: auth-failed" "$loop01"

# TC-KIRO-DROP-LOOP-02 — kiro dropped on a generic/no-signal log → empty reason
printf '%s\n' "$CLEAN_NOVERDICT_LOG" > "$KLOG"
loop02=$(build_dropped_reasons "kiro:unavailable:$KLOG")
assert_eq "TC-KIRO-DROP-LOOP-02 generic kiro drop → empty reason (bare unavailable)" "" "$loop02"

# TC-KIRO-DROP-LOOP-03 — BOTH agy (quota) AND kiro (auth) dropped in the SAME
# fan-out → reasons list a DISTINCT clause for each (the AC #2 regression guard on
# the assembly loop only handling agy/codex).
loop03=$(build_dropped_reasons \
  "agy:unavailable:$FIXTURES/agy-quota-exhausted.fixture" \
  "kiro:unavailable:$FIXTURES/kiro-auth-failed.fixture")
assert_contains "TC-KIRO-DROP-LOOP-03a both-dropped lists the agy quota reason" "agy: quota-exhausted" "$loop03"
assert_contains "TC-KIRO-DROP-LOOP-03b both-dropped lists the kiro auth-failed reason" "kiro: auth-failed" "$loop03"

# TC-KIRO-DROP-LOOP-04 — a non-kiro/non-agy/non-codex unavailable agent adds no reason
loop04=$(build_dropped_reasons "claude:unavailable:$FIXTURES/kiro-auth-failed.fixture")
assert_eq "TC-KIRO-DROP-LOOP-04 non-agy/non-codex/non-kiro unavailable agent adds no reason" "" "$loop04"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-DROP-SRC: wrapper wiring (source-of-truth) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-KIRO-DROP-SRC-01 wrapper sources lib-review-kiro.sh" \
  'source "\$\{SCRIPT_DIR\}/lib-review-kiro.sh"' "$WRAPPER"
assert_grep "TC-KIRO-DROP-SRC-02 wrapper captures the per-agent kiro log path (AGENT_KIRO_LOGS)" \
  'AGENT_KIRO_LOGS' "$WRAPPER"
assert_grep "TC-KIRO-DROP-SRC-03 wrapper calls _classify_kiro_drop_reason" \
  '_classify_kiro_drop_reason' "$WRAPPER"
assert_grep "TC-KIRO-DROP-SRC-04 dropped-agent reason assembly interpolates the kiro reason phrase" \
  '_kiro_drop_reason_phrase' "$WRAPPER"
# TC-KIRO-DROP-SRC-05 — bash -n parses both files
if bash -n "$LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-KIRO-DROP-SRC-05a lib-review-kiro.sh parses (bash -n)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-KIRO-DROP-SRC-05a lib-review-kiro.sh fails bash -n"; FAIL=$((FAIL + 1))
fi
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-KIRO-DROP-SRC-05b autonomous-review.sh parses (bash -n)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-KIRO-DROP-SRC-05b autonomous-review.sh fails bash -n"; FAIL=$((FAIL + 1))
fi
# TC-KIRO-DROP-SRC-06 — CI shellcheck job lists the new lib.
assert_grep "TC-KIRO-DROP-SRC-06 CI shellcheck includes lib-review-kiro.sh" \
  'lib-review-kiro.sh' "$CI"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-DROP-REG: regression ==="
# ---------------------------------------------------------------------------
# TC-KIRO-DROP-REG-01 — an auth-failure kiro drop classifies DISTINCTLY from a
# generic/no-verdict drop (the core regression: pre-fix both produce no reason).
printf '%s\n' "$AUTH_FAIL_LOG" > "$KLOG"
reg_auth=$(_classify_kiro_drop_reason "$KLOG")
printf '%s\n' "$CLEAN_NOVERDICT_LOG" > "$KLOG"
reg_generic=$(_classify_kiro_drop_reason "$KLOG")
if [[ "$reg_auth" != "$reg_generic" && -n "$reg_auth" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-KIRO-DROP-REG-01 auth-failure drop classified distinctly from a no-verdict drop"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-KIRO-DROP-REG-01 not distinguished (auth='$reg_auth' generic='$reg_generic')"; FAIL=$((FAIL + 1))
fi

# TC-KIRO-DROP-REG-02 — a clean no-verdict turn is NOT misreported as auth-failed
# (no over-claim).
assert_eq "TC-KIRO-DROP-REG-02 clean no-verdict turn not misreported as auth-failed" \
  "" "$reg_generic"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
