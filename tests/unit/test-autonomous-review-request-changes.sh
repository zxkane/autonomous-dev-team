#!/bin/bash
# test-autonomous-review-request-changes.sh — issue #193 / INV-52.
#
# The review WRAPPER owns the GitHub-native PR review action: `--approve` on a
# PASS and `--request-changes` on a SUBSTANTIVE FAIL, so the PR's
# `reviewDecision` reflects the blocking verdict (CHANGES_REQUESTED) for humans,
# branch protection, the dispatcher, and the dev-resume agent. The review AGENT
# posts verdict comments ONLY and must never run `gh pr review`/`gh pr merge`.
#
# Three-pronged (the wrapper is too heavy to run end-to-end):
#   1. executable harness for submit_request_changes (sourced from
#      lib-review-request-changes.sh in isolation, with stubbed gh + log);
#   2. source-of-truth greps against autonomous-review.sh: the helper is wired
#      onto the substantive FAIL routes, best-effort, mutually exclusive with the
#      PASS approve, and NOT wired onto the non-substantive routes;
#   3. agent-side framing greps over SKILL.md / decision-gate.md + doc-presence
#      checks (INV-52 exists and is referenced).
#
# Run: bash tests/unit/test-autonomous-review-request-changes.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
RC_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-request-changes.sh"
SKILL="$PROJECT_ROOT/skills/autonomous-review/SKILL.md"
DECISION_GATE="$PROJECT_ROOT/skills/autonomous-review/references/decision-gate.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"; echo "      actual=  [$actual]"; FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (matched: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

# Strip bash comments before matching so a #-prefixed mention doesn't match.
strip_comments() {
  local src="$1" tmp
  tmp=$(mktemp)
  sed -E 's/[[:space:]]+#[^"]*$//' "$src" | grep -v '^[[:space:]]*#' > "$tmp"
  echo "$tmp"
}

# ===========================================================================
echo "=== Group 1: submit_request_changes helper (executable, stubbed gh) ==="
# ===========================================================================
[[ -f "$RC_LIB" ]] || { echo -e "  ${RED}FAIL${NC}: $RC_LIB not found"; FAIL=$((FAIL + 1)); }
if [[ -f "$RC_LIB" ]]; then
  # Run each scenario in a clean subshell so stubs/state don't leak.

  # TC-RC-FN-01: helper calls `gh pr review --request-changes` (NOT --approve).
  out=$(
    # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-request-changes.sh
    source "$RC_LIB"
    log() { :; }
    REPO="owner/repo"
    gh() { echo "GH-ARGS: $*"; return 0; }
    submit_request_changes 42 "Review findings: blocking" 2>/dev/null
  )
  if grep -q 'pr review 42 --repo owner/repo --request-changes' <<<"$out" \
     && ! grep -q -- '--approve' <<<"$out"; then
    echo -e "  ${GREEN}PASS${NC}: TC-RC-FN-01 calls gh pr review --request-changes (not --approve)"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-RC-FN-01 (got: $out)"; FAIL=$((FAIL + 1))
  fi

  # TC-RC-FN-02: helper passes the PR number and a --body.
  if grep -q 'pr review 42 ' <<<"$out" && grep -q -- '--body' <<<"$out"; then
    echo -e "  ${GREEN}PASS${NC}: TC-RC-FN-02 passes PR number and --body"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-RC-FN-02 (got: $out)"; FAIL=$((FAIL + 1))
  fi

  # TC-RC-FN-03: gh exits non-zero (simulated 403) → helper returns 0 (non-fatal).
  rc=0
  (
    source "$RC_LIB"
    _warned=0
    log() { case "$*" in *WARNING*Failed*REQUEST_CHANGES*) _warned=1;; esac; }
    REPO="owner/repo"
    gh() { return 1; }   # simulate 403
    submit_request_changes 7 "body" >/dev/null 2>&1
  ) || rc=$?
  assert_eq "TC-RC-FN-03 helper returns 0 even when gh fails (non-fatal under set -e)" "0" "$rc"

  # TC-RC-FN-03b: the non-zero gh path emits a warning (not a silent swallow).
  warn_out=$(
    source "$RC_LIB"
    log() { echo "LOG: $*"; }
    REPO="owner/repo"
    gh() { return 1; }
    submit_request_changes 7 "body" 2>/dev/null
  )
  assert_grep "TC-RC-FN-03b non-zero gh path warns (not silent)" \
    'WARNING.*Failed to submit REQUEST_CHANGES' <(printf '%s\n' "$warn_out")

  # TC-RC-FN-04: helper succeeds → returns 0.
  rc=0
  (
    source "$RC_LIB"
    log() { :; }
    REPO="owner/repo"
    gh() { return 0; }
    submit_request_changes 9 "body" >/dev/null 2>&1
  ) || rc=$?
  assert_eq "TC-RC-FN-04 helper returns 0 on success" "0" "$rc"

  # TC-RC-FN-05: helper runs cleanly under `set -e` (a non-fatal gh failure
  # inside an `if` does not trip errexit). Regression for the strand-the-issue
  # footgun the issue calls out.
  rc=0
  (
    set -e
    source "$RC_LIB"
    log() { :; }
    REPO="owner/repo"
    gh() { return 1; }
    submit_request_changes 11 "body" >/dev/null 2>&1
    echo "reached-after-helper"
  ) | grep -q 'reached-after-helper' || rc=$?
  assert_eq "TC-RC-FN-05 execution continues past helper under set -e on gh failure" "0" "$rc"
fi

# ===========================================================================
echo ""
echo "=== Group 2: wrapper wiring (source-of-truth greps) ==="
# ===========================================================================
WRAPPER_CODE=$(strip_comments "$WRAPPER")
trap 'rm -f "$WRAPPER_CODE"' EXIT

# TC-RC-SRC-00: the wrapper sources the new lib.
assert_grep "TC-RC-SRC-00 wrapper sources lib-review-request-changes.sh" \
  'source .*lib-review-request-changes\.sh' "$WRAPPER_CODE"

# TC-RC-SRC-01: helper is defined in the lib.
assert_grep "TC-RC-SRC-01 submit_request_changes defined in lib" \
  '^submit_request_changes\(\)' "$RC_LIB"

# TC-RC-SRC-02: the wrapper invokes the helper on every substantive FAIL route —
# the three are: agent-posted findings FAIL, the CONFLICTING mergeable block, and
# the E2E hard-gate failure ([INV-46], a dev-actionable blocking FAIL produced
# before the review fan-out — #197 codex finding). Count INVOCATIONS only — the
# call form is `submit_request_changes "<pr>"`; a `|| log "... submit_request_changes
# returned ..."` mention is NOT a call.
_calls=$(grep -cE 'submit_request_changes "' "$WRAPPER_CODE" || true)
if [[ "$_calls" -ge 3 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-02 wrapper calls submit_request_changes on ≥3 substantive FAIL routes (found $_calls)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-02 expected ≥3 helper calls, found $_calls"; FAIL=$((FAIL + 1))
fi

# TC-RC-SRC-06: every helper invocation statement is best-effort — its 3-line
# window (call line + body line + trailing operator) contains a `|| log`/`|| true`
# guard. The helper always returns 0 by design (Group 1), but defense-in-depth
# pins the discipline so a future refactor can't strand the issue under `set -e`.
_call_lines=$(grep -nE 'submit_request_changes "' "$WRAPPER_CODE" | cut -d: -f1)
_guarded_ok=1
for _ln in $_call_lines; do
  if ! sed -n "${_ln},$((_ln + 3))p" "$WRAPPER_CODE" | grep -qE '\|\| (log|true)'; then
    _guarded_ok=0
    echo "      un-guarded invocation near line $_ln"
  fi
done
if [[ "$_guarded_ok" -eq 1 && -n "$_call_lines" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-06 every submit_request_changes invocation is best-effort (|| log / || true)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-06 an invocation lacks a best-effort guard"; FAIL=$((FAIL + 1))
fi

# TC-RC-SRC-07: PASS branch still submits --approve (regression pin — the fix
# must NOT remove the existing approve).
assert_grep "TC-RC-SRC-07 PASS path still submits gh pr review --approve" \
  'gh +pr +review .*--approve' "$WRAPPER_CODE"

# TC-RC-SRC-08: PASS and REQUEST_CHANGES are mutually exclusive — no single
# logical statement submits both. (Pin: --approve and submit_request_changes
# never appear on the same line.)
_both=$(grep -E 'submit_request_changes "' "$WRAPPER_CODE" | grep -E -- '--approve' || true)
if [[ -z "$_both" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-08 no line submits both --approve and REQUEST_CHANGES"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-08 a line mixes approve + request-changes:"; echo "$_both"; FAIL=$((FAIL + 1))
fi

# TC-RC-SRC-04: the NON-substantive routes must NOT submit REQUEST_CHANGES —
# they are transient re-queues / transport failures, not dev-actionable code
# defects. Pin the helper call count at EXACTLY 3 (the three substantive routes:
# agent-findings FAIL, CONFLICTING mergeable block, E2E hard-gate fail). A 4th
# call would mean a non-substantive route (mergeable-UNKNOWN, E2E-evidence-missing,
# or the agent-crash-no-verdict path) wrongly wired it in.
if [[ "$_calls" -eq 3 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-04 helper called on EXACTLY the 3 substantive routes (non-substantive routes excluded)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-04 expected exactly 3 helper calls (non-substantive routes must NOT request changes), found $_calls"; FAIL=$((FAIL + 1))
fi

# TC-RC-SRC-04b: the E2E hard-gate FAIL route (the `failed-substantive` +
# `E2E verification failed` branch, INV-46) submits REQUEST_CHANGES, while the
# E2E `block-nonsubstantive` (evidence-missing re-queue) route does NOT. Verify
# by checking the 25-line window after each `[BLOCKING] E2E verification failed`
# / `e2e-evidence-missing` marker contains / lacks a helper invocation.
_e2e_fail_ln=$(grep -nE '\[BLOCKING\] E2E verification failed' "$WRAPPER_CODE" | head -1 | cut -d: -f1)
_e2e_block_ln=$(grep -nE 'e2e-evidence-missing' "$WRAPPER_CODE" | head -1 | cut -d: -f1)
if [[ -n "$_e2e_fail_ln" ]] && sed -n "${_e2e_fail_ln},$((_e2e_fail_ln + 25))p" "$WRAPPER_CODE" | grep -qE 'submit_request_changes "'; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-04b E2E hard-gate FAIL route requests changes"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-04b E2E hard-gate FAIL route does NOT request changes (should)"; FAIL=$((FAIL + 1))
fi
if [[ -n "$_e2e_block_ln" ]] && ! sed -n "$((_e2e_block_ln - 12)),$((_e2e_block_ln + 12))p" "$WRAPPER_CODE" | grep -qE 'submit_request_changes "'; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-04c E2E evidence-missing (non-substantive) route does NOT request changes"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-04c E2E evidence-missing route wrongly requests changes (should NOT)"; FAIL=$((FAIL + 1))
fi

# TC-RC-SRC-09: each helper invocation's body (its 3-line window) references the
# findings/blocking context, so the PR review links/summarizes the issue
# findings comment rather than submitting an empty REQUEST_CHANGES.
_body_ok=1
for _ln in $_call_lines; do
  if ! sed -n "${_ln},$((_ln + 3))p" "$WRAPPER_CODE" | grep -qE '([Ff]inding|[Bb]locking|CONFLICTING|reviewDecision|CHANGES_REQUESTED|#\$\{ISSUE_NUMBER\})'; then
    _body_ok=0
    echo "      invocation near line $_ln has no findings/blocking body"
  fi
done
if [[ "$_body_ok" -eq 1 && -n "$_call_lines" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-09 each helper invocation body references findings/blocking context"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-09 an invocation body lacks findings/blocking context"; FAIL=$((FAIL + 1))
fi

# TC-RC-SRC-10: wrapper passes bash -n.
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-10 wrapper passes bash -n"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-10 wrapper has syntax errors"; FAIL=$((FAIL + 1))
fi

# TC-RC-SRC-11: the new lib passes bash -n.
if bash -n "$RC_LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-RC-SRC-11 lib passes bash -n"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RC-SRC-11 lib has syntax errors"; FAIL=$((FAIL + 1))
fi

# ===========================================================================
echo ""
echo "=== Group 3: agent-side framing (SKILL.md / decision-gate.md) ==="
# ===========================================================================

# TC-RC-DOC-02: SKILL.md states the agent must NOT run gh pr review / gh pr merge.
assert_grep "TC-RC-DOC-02 SKILL.md prohibits the agent running gh pr review/merge" \
  '(never|MUST NOT|must never|do NOT).*gh pr (review|merge)' "$SKILL"

# TC-RC-DOC-02b: SKILL.md states the WRAPPER owns the GitHub-native action with
# the explicit INV-52 phrasing (not just any pre-existing "wrapper" mention).
assert_grep "TC-RC-DOC-02b SKILL.md says the wrapper owns the GitHub-native review/merge action" \
  '[Ww]rapper (owns|submits).*(GitHub-native|--approve|--request-changes|approve.*merge)' "$SKILL"

# TC-RC-DOC-01: the bare "approve + merge" license framing for the AGENT is gone
# from the decision-summary line (it must be re-scoped to the wrapper). The
# specific buggy phrasing the incident cites — "PASS** (approve + merge)" — must
# not survive (markdown bold splits PASS and the paren, so match loosely).
assert_not_grep "TC-RC-DOC-01 SKILL.md no longer frames the agent verdict as 'PASS (approve + merge)'" \
  'PASS\*{0,2} \(approve \+ merge\)' "$SKILL"

# TC-RC-DOC-03: decision-gate.md action-pairing — the agent's PASS action is
# posting the comment, NOT submitting an APPROVE review. The buggy
# "Submit APPROVE review on PR" instruction to the agent must be re-scoped.
assert_not_grep "TC-RC-DOC-03 decision-gate.md no longer instructs the AGENT to 'Submit APPROVE review on PR'" \
  'Submit APPROVE review on PR' "$DECISION_GATE"

# TC-RC-DOC-03b: decision-gate.md explicitly says the wrapper owns the native
# action (INV-52 phrasing, not a pre-existing INV-44 "wrapper-enforced" mention).
assert_grep "TC-RC-DOC-03b decision-gate.md says the wrapper submits the GitHub review/merge (INV-52)" \
  '[Ww]rapper (owns|submits).*(--approve|--request-changes|approve.*merge|GitHub-native)' "$DECISION_GATE"

# TC-RC-DOC-04: INV-52 exists and is referenced from the flow doc.
assert_grep "TC-RC-DOC-04a INV-52 entry exists in invariants.md" \
  '^## INV-52:' "$INVARIANTS"
assert_grep "TC-RC-DOC-04b review-agent-flow.md references INV-52" \
  'INV-52' "$FLOW"

# TC-RC-DOC-05: invariants.md INV-52 mentions REQUEST_CHANGES / reviewDecision.
assert_grep "TC-RC-DOC-05 INV-52 describes REQUEST_CHANGES / reviewDecision" \
  '(REQUEST_CHANGES|request-changes|reviewDecision|CHANGES_REQUESTED)' "$INVARIANTS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
