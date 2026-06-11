#!/bin/bash
# test-lib-review-agy.sh — Unit tests for the agy quota/auth drop-reason detector
# (INV-58, issue #205).
#
# When the `agy` (Antigravity CLI) member of a review fan-out hits the consumer
# quota wall (HTTP 429 RESOURCE_EXHAUSTED, "Individual quota reached") or an auth
# failure ("not logged into Antigravity"), agy exits rc 0 with empty stdout and
# posts no verdict — so the wrapper drops it as an opaque `unavailable` (INV-40),
# indistinguishable from a CLI launch failure or a genuine no-verdict miss. The
# 429 is buried only in agy's own `--log-file`. This lib scrapes that log and
# classifies the drop so the wrapper can surface a distinct, actionable reason
# (with the "Resets in <dur>" window) in the log + the dropped-agent comment.
#
# Tests:
#   - _classify_agy_drop_reason: quota/auth detection from the agy log file
#   - _agy_drop_reason_phrase: human-facing rendering of a reason token
#   - source-of-truth: wrapper sources the lib, captures the agy log path,
#     calls the classifier on an unavailable agy agent, interpolates the reason,
#     and renders per-agent (not shared) model labels.
#
# Run: bash tests/unit/test-lib-review-agy.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-agy.sh"
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should NOT contain='$needle'"
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

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-agy.sh
source "$LIB"

TMPLOG=$(mktemp)
trap 'rm -f "$TMPLOG"' EXIT

# Canned log fragments --------------------------------------------------------
QUOTA_WITH_RESET='I Antigravity 2.0 CLI (print mode)
E agent executor error: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Contact your administrator to enable overages. Resets in 33h48m45s.
I print mode terminated'

QUOTA_NO_RESET='I Antigravity 2.0 CLI (print mode)
E agent executor error: RESOURCE_EXHAUSTED (code 429): Individual quota reached.
I print mode terminated'

QUOTA_BARE_PHRASE='I Antigravity 2.0 CLI (print mode)
E Individual quota reached. Try again later.
I print mode terminated'

AUTH_NOT_LOGGED_IN='I Antigravity 2.0 CLI (print mode)
E You are not logged into Antigravity.
I print mode terminated'

AUTH_OAUTH='I Antigravity 2.0 CLI (print mode)
E Failed to get OAuth token: oauth: cannot fetch token: 401 Unauthorized.
I print mode terminated'

# The live repro shape: BOTH the quota 429 AND the OAuth/not-logged-in line.
QUOTA_AND_AUTH='I Antigravity 2.0 CLI (print mode)
E agent executor error: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 12h05m.
E Failed to get OAuth token: ... You are not logged into Antigravity.
I print mode terminated'

NORMAL_LOG='I Antigravity 2.0 CLI (print mode)
I Print mode: conversation=11111111-2222-3333-4444-555555555555
I Starting review turn
I print mode terminated'

RESET_MINUTES='I Antigravity 2.0 CLI (print mode)
E RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 45m10s.
I print mode terminated'

# ---------------------------------------------------------------------------
echo "=== TC-AGYQ-DET: _classify_agy_drop_reason ==="
# ---------------------------------------------------------------------------

# TC-AGYQ-DET-01 — 429 + Resets window → quota-exhausted with the window appended
printf '%s\n' "$QUOTA_WITH_RESET" > "$TMPLOG"
assert_eq "TC-AGYQ-DET-01 429 + Resets in 33h48m45s → quota-exhausted:Resets in 33h48m45s" \
  "quota-exhausted:Resets in 33h48m45s" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-02 — 429 but no Resets line → bare quota-exhausted
printf '%s\n' "$QUOTA_NO_RESET" > "$TMPLOG"
assert_eq "TC-AGYQ-DET-02 429 no reset line → quota-exhausted" \
  "quota-exhausted" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-03 — "Individual quota reached" without RESOURCE_EXHAUSTED → quota-exhausted
printf '%s\n' "$QUOTA_BARE_PHRASE" > "$TMPLOG"
assert_eq "TC-AGYQ-DET-03 bare 'Individual quota reached' → quota-exhausted" \
  "quota-exhausted" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-04 — not-logged-in only → auth-failed
printf '%s\n' "$AUTH_NOT_LOGGED_IN" > "$TMPLOG"
assert_eq "TC-AGYQ-DET-04 not logged into Antigravity → auth-failed" \
  "auth-failed" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-05 — OAuth token failure only → auth-failed
printf '%s\n' "$AUTH_OAUTH" > "$TMPLOG"
assert_eq "TC-AGYQ-DET-05 Failed to get OAuth token → auth-failed" \
  "auth-failed" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-06 — BOTH quota AND auth lines → quota takes precedence
printf '%s\n' "$QUOTA_AND_AUTH" > "$TMPLOG"
assert_eq "TC-AGYQ-DET-06 quota+auth → quota precedence (with window)" \
  "quota-exhausted:Resets in 12h05m" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-07 — a normal log with neither signal → empty
printf '%s\n' "$NORMAL_LOG" > "$TMPLOG"
assert_eq "TC-AGYQ-DET-07 normal log → empty (caller keeps bare unavailable)" \
  "" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-08 — empty file → empty, no crash
: > "$TMPLOG"
assert_eq "TC-AGYQ-DET-08 empty log → empty" "" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-09 — missing path → empty, no crash
assert_eq "TC-AGYQ-DET-09 missing log → empty" "" "$(_classify_agy_drop_reason "/nonexistent/path/$$")"
# also empty-arg
assert_eq "TC-AGYQ-DET-09b empty arg → empty" "" "$(_classify_agy_drop_reason "")"

# TC-AGYQ-DET-10 — minutes/seconds reset shape
printf '%s\n' "$RESET_MINUTES" > "$TMPLOG"
assert_eq "TC-AGYQ-DET-10 Resets in 45m10s shape" \
  "quota-exhausted:Resets in 45m10s" "$(_classify_agy_drop_reason "$TMPLOG")"

# TC-AGYQ-DET-11 — committed fixture (sanitized real agy quota log). The fixture
# uses a `.fixture` extension (NOT `.log`) so the repo's blanket `*.log`
# .gitignore rule does not silently keep it untracked → CI green on a clean
# checkout (the sibling codex fixtures use `.jsonl`/`.txt` for the same reason).
assert_eq "TC-AGYQ-DET-11 committed quota fixture → quota-exhausted with window" \
  "quota-exhausted:Resets in 33h48m45s" "$(_classify_agy_drop_reason "$FIXTURES/agy-quota-exhausted.fixture")"

# TC-AGYQ-DET-12 — runs cleanly under set -euo pipefail (no abort)
det12=$(
  set -euo pipefail
  source "$LIB"
  printf '%s\n' "$QUOTA_WITH_RESET" > "$TMPLOG"
  out=$(_classify_agy_drop_reason "$TMPLOG")
  echo "rc=$?|$out"
)
assert_eq "TC-AGYQ-DET-12 no crash under set -euo pipefail" \
  "rc=0|quota-exhausted:Resets in 33h48m45s" "$det12"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGYQ-PHR: _agy_drop_reason_phrase ==="
# ---------------------------------------------------------------------------

phr01=$(_agy_drop_reason_phrase "quota-exhausted:Resets in 33h48m45s")
assert_contains "TC-AGYQ-PHR-01a phrase names quota"  "quota" "$phr01"
assert_contains "TC-AGYQ-PHR-01b phrase carries the reset window" "33h48m45s" "$phr01"

phr02=$(_agy_drop_reason_phrase "quota-exhausted")
assert_contains "TC-AGYQ-PHR-02a phrase names quota (no window)" "quota" "$phr02"
assert_not_contains "TC-AGYQ-PHR-02b no spurious 'resets in' when no window" "resets in" "$phr02"

phr03=$(_agy_drop_reason_phrase "auth-failed")
assert_contains "TC-AGYQ-PHR-03 phrase names auth" "auth" "$phr03"

assert_eq "TC-AGYQ-PHR-04 empty token → empty phrase" "" "$(_agy_drop_reason_phrase "")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGYQ-SRC: wrapper wiring (source-of-truth) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-AGYQ-SRC-01 wrapper sources lib-review-agy.sh" \
  'source "\$\{LIB_DIR\}/lib-review-agy.sh"' "$WRAPPER"
assert_grep "TC-AGYQ-SRC-02 wrapper captures the per-agent agy log path (_agy_log_file)" \
  '_agy_log_file' "$WRAPPER"
assert_grep "TC-AGYQ-SRC-03 wrapper calls _classify_agy_drop_reason" \
  '_classify_agy_drop_reason' "$WRAPPER"
assert_grep "TC-AGYQ-SRC-04 dropped-agent comment interpolates the agy reason phrase" \
  '_agy_drop_reason_phrase|_dropped_reasons' "$WRAPPER"
assert_grep "TC-AGYQ-SRC-05 CI shellcheck includes lib-review-agy.sh" \
  'lib-review-agy.sh' "$CI"

# TC-AGYQ-SRC-06 — bash -n parses both files
if bash -n "$LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGYQ-SRC-06a lib-review-agy.sh parses (bash -n)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGYQ-SRC-06a lib-review-agy.sh fails bash -n"; FAIL=$((FAIL + 1))
fi
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGYQ-SRC-06b autonomous-review.sh parses (bash -n)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGYQ-SRC-06b autonomous-review.sh fails bash -n"; FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGYQ-MODEL: per-agent model label (source-of-truth) ==="
# ---------------------------------------------------------------------------
# The fan-out line must NOT print ONLY the shared default. It should render
# per-agent resolved models via _resolve_review_agent_model.
assert_grep "TC-AGYQ-MODEL-01 fan-out model label derives from _resolve_review_agent_model" \
  '_review_fanout_model_label|_resolve_review_agent_model' "$WRAPPER"

# TC-AGYQ-MODEL-02 — a label helper exists and reflects the per-agent override.
# Source the resolve lib + the label helper and exercise it directly if present.
# issue #220: the label now routes through _resolve_review_agent_model_label,
# which mirrors INV-50 by validating an agy id against `agy models`. Stub
# _agy_known_model so the test is deterministic (no `agy models` shell-out) and
# treats the valid per-agent override `Gemini 3.5 Flash (High)` as a KNOWN agy id
# (rc 0) — so it is shown verbatim, not collapsed to the agy default.
RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve.sh"
if declare -f _review_fanout_model_label >/dev/null 2>&1 || grep -q '_review_fanout_model_label' "$WRAPPER" "$RESOLVE_LIB" 2>/dev/null; then
  model02=$(
    set -uo pipefail
    source "$RESOLVE_LIB"
    # Deterministic stub: only the configured agy id is "known".
    _agy_known_model() { [[ "$1" == "Gemini 3.5 Flash (High)" ]] && return 0 || return 1; }
    # The label helper lives in lib-review-resolve.sh (testable in isolation).
    if declare -f _review_fanout_model_label >/dev/null 2>&1; then
      AGENT_REVIEW_MODEL="sonnet" AGENT_REVIEW_MODEL_AGY="Gemini 3.5 Flash (High)" \
        _review_fanout_model_label agy codex
    fi
  )
  assert_contains "TC-AGYQ-MODEL-02a label shows agy per-agent resolved model" \
    "Gemini 3.5 Flash (High)" "$model02"
  assert_contains "TC-AGYQ-MODEL-02b label still shows codex's shared sonnet" \
    "sonnet" "$model02"
else
  echo -e "  ${RED}FAIL${NC}: TC-AGYQ-MODEL-02 _review_fanout_model_label not found"; FAIL=$((FAIL + 2))
fi

# TC-AGYQ-MODEL-03 — the Reviewed-HEAD trailer renders a RESOLVED model, not the
# bare shared ${AGENT_REVIEW_MODEL}. Assert the trailer line consults the
# resolved per-agent model (a representative agent's resolution).
assert_grep "TC-AGYQ-MODEL-03 Reviewed-HEAD trailer model is the resolved per-agent value" \
  'Reviewed HEAD.*model .*_REVIEW_HEAD_MODEL|_REVIEW_HEAD_MODEL=.*_resolve_review_agent_model' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGYQ-LOOP: drop-reason augmentation loop (behavioral) ==="
# ---------------------------------------------------------------------------
# Exercise the SAME composition the wrapper runs — for each `unavailable` agent,
# scrape the agy log and build `_dropped_reasons` from the phrase — and assert the
# resulting reason string is distinct for a quota drop vs. a generic drop. This is
# the issue's mandatory regression: it FAILS before the fix (the pre-#205 loop
# produces no reason → a quota agy reads identically to a launch failure).
#
# build_dropped_reasons <agent>:<verdict>:<logfixture> ...
#   Mirrors the wrapper's per-agent loop body verbatim against the real libs.
build_dropped_reasons() {
  local spec agent verdict logf reasons=""
  for spec in "$@"; do
    agent="${spec%%:*}"; spec="${spec#*:}"
    verdict="${spec%%:*}"; logf="${spec#*:}"
    [[ "$verdict" == "unavailable" ]] || continue
    if [[ "$agent" == "agy" ]]; then
      local tok; tok=$(_classify_agy_drop_reason "$logf")
      [[ -n "$tok" ]] && reasons+="${agent}: $(_agy_drop_reason_phrase "$tok"); "
    fi
  done
  printf '%s' "${reasons%; }"
}

# TC-AGYQ-LOOP-01 — agy dropped on a QUOTA log → reason carries quota + window.
quota_reasons=$(build_dropped_reasons "agy:unavailable:$FIXTURES/agy-quota-exhausted.fixture" "codex:fail:")
assert_contains "TC-AGYQ-LOOP-01a quota loop reason names agy + quota" "agy: quota-exhausted" "$quota_reasons"
assert_contains "TC-AGYQ-LOOP-01b quota loop reason carries the reset window" "33h48m45s" "$quota_reasons"

# TC-AGYQ-LOOP-02 — agy dropped on a GENERIC/no-signal log → no reason (bare
# `unavailable` wording preserved). This is the pre-fix-equivalent path: an
# opaque drop.
: > "$TMPLOG"; printf '%s\n' "$NORMAL_LOG" > "$TMPLOG"
generic_reasons=$(build_dropped_reasons "agy:unavailable:$TMPLOG")
assert_eq "TC-AGYQ-LOOP-02 generic agy drop → empty reason (bare unavailable)" "" "$generic_reasons"

# TC-AGYQ-LOOP-03 — the two are DISTINGUISHABLE (the core regression): a quota
# drop and a generic/launch-failure drop must not produce the same string.
if [[ -n "$quota_reasons" && "$quota_reasons" != "$generic_reasons" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGYQ-LOOP-03 quota drop distinguishable from opaque drop in the loop"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGYQ-LOOP-03 quota vs opaque not distinguished (quota='$quota_reasons')"; FAIL=$((FAIL + 1))
fi

# TC-AGYQ-LOOP-04 — a NON-agy unavailable agent contributes NO reason lookup
# (codex unavailable here is left to its own INV-51/53 handling).
codex_reasons=$(build_dropped_reasons "codex:unavailable:")
assert_eq "TC-AGYQ-LOOP-04 non-agy unavailable agent adds no agy reason" "" "$codex_reasons"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGYQ-REG: regression ==="
# ---------------------------------------------------------------------------
# TC-AGYQ-REG-01 — a quota agy drop must NOT read as the identical opaque
# `unavailable` a launch failure produces: the classifier yields a DISTINCT
# token for the quota log and EMPTY for a generic log.
printf '%s\n' "$QUOTA_WITH_RESET" > "$TMPLOG"
quota_tok=$(_classify_agy_drop_reason "$TMPLOG")
printf '%s\n' "$NORMAL_LOG" > "$TMPLOG"
generic_tok=$(_classify_agy_drop_reason "$TMPLOG")
if [[ "$quota_tok" != "$generic_tok" && -n "$quota_tok" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AGYQ-REG-01 quota drop classified distinctly from a generic/no-verdict drop"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AGYQ-REG-01 quota drop not distinguished (quota='$quota_tok' generic='$generic_tok')"; FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
