#!/bin/bash
# test-step0-hygiene.sh — Regression for issue #115 Bug B (INV-25).
#
# Step 0 of dispatcher-tick.sh detects and self-heals "approved + transitional"
# and "stalled + transitional" label residues. This test exercises:
#
#   - _has_terminal_label() predicate (lib-dispatch.sh)
#   - hygiene_strip_residual_labels() per-issue strip logic
#   - hygiene_post_audit_comment() idempotency-marker gating
#   - dispatcher-tick.sh structural placement of Step 0 (static grep)
#
# Stub strategy mirrors test-lib-dispatch.sh: override `gh` in the shell and
# inspect captured args.
#
# Run: bash tests/unit/test-step0-hygiene.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-step0
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# `gh` stub. Captures every call into _GH_CALLS array and returns canned
# output based on args. Tests reset _GH_CALLS, set _MOCK_COMMENTS_JSON or
# _MOCK_ISSUE_LIST, then call the helper and inspect _GH_CALLS.
_GH_CALLS=()
_MOCK_COMMENTS_JSON=""
_MOCK_ISSUE_LIST=""
gh() {
  _GH_CALLS+=("$*")
  # Detect verb shape and serve the matching fixture.
  case "$1" in
    issue)
      case "$2" in
        list)
          # Apply -q if present, else dump fixture.
          local q=""
          local i=3
          while [[ $i -le $# ]]; do
            if [[ "${!i}" == "-q" ]]; then
              local j=$((i + 1))
              q="${!j}"
              break
            fi
            i=$((i + 1))
          done
          if [[ -n "$q" ]]; then
            jq "$q" <<<"${_MOCK_ISSUE_LIST:-[]}"
          else
            printf '%s' "${_MOCK_ISSUE_LIST:-[]}"
          fi
          ;;
        view)
          # Tests use _MOCK_COMMENTS_JSON as the direct integer return
          # value of the marker-count query (0 = no marker, 1+ = present).
          # That mirrors `gh issue view ... --json comments -q '[...] | length'`
          # which always returns an integer — bypassing jq keeps the stub
          # simple.
          if [[ -n "${_MOCK_COMMENTS_JSON:-}" ]]; then
            printf '%s' "$_MOCK_COMMENTS_JSON"
          fi
          ;;
        edit|comment)
          # Side-effect verbs — no stdout.
          ;;
      esac
      ;;
  esac
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: '$expected'"
    echo "      actual:   '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if grep -qE "$pattern" <<<"$haystack"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    echo "      haystack: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if ! grep -qE "$pattern" <<<"$haystack"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern '$pattern' should NOT match)"
    echo "      haystack: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

mklabels_json() {
  # mklabels_json foo bar -> [{"name":"foo"},{"name":"bar"}]
  local out="["
  local first=1
  for n in "$@"; do
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="{\"name\":\"$n\"}"
  done
  out+="]"
  printf '%s' "$out"
}

# ===================================================================
# _has_terminal_label
# ===================================================================
echo "=== TC-HAS-TERM: _has_terminal_label ==="

labels=$(mklabels_json autonomous approved)
_has_terminal_label "$labels"; rc=$?
assert_eq "TC-HAS-TERM-001 approved → 0" "0" "$rc"

labels=$(mklabels_json autonomous stalled)
_has_terminal_label "$labels"; rc=$?
assert_eq "TC-HAS-TERM-002 stalled → 0" "0" "$rc"

labels=$(mklabels_json autonomous in-progress)
_has_terminal_label "$labels"; rc=$?
assert_eq "TC-HAS-TERM-003 in-progress → 1" "1" "$rc"

labels=$(mklabels_json autonomous)
_has_terminal_label "$labels"; rc=$?
assert_eq "TC-HAS-TERM-004 autonomous-only → 1" "1" "$rc"

labels=$(mklabels_json autonomous approved stalled)
_has_terminal_label "$labels"; rc=$?
assert_eq "TC-HAS-TERM-005 both terminals → 0" "0" "$rc"

# ===================================================================
# hygiene_strip_residual_labels
# ===================================================================
echo
echo "=== TC-HYG: hygiene_strip_residual_labels ==="

# TC-HYG-001
_GH_CALLS=()
labels=$(mklabels_json autonomous approved pending-review)
hygiene_strip_residual_labels 100 "$labels" >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
assert_match "TC-HYG-001 strips pending-review under approved" "remove-label pending-review" "$edit_calls"

# TC-HYG-002 — both terminals + one transitional
_GH_CALLS=()
labels=$(mklabels_json autonomous approved in-progress stalled)
hygiene_strip_residual_labels 102 "$labels" >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
assert_match "TC-HYG-002 strips in-progress (terminal+terminal+1 transitional)" "remove-label in-progress" "$edit_calls"
assert_no_match "TC-HYG-002 keeps approved (not stripped)" "remove-label approved" "$edit_calls"
assert_no_match "TC-HYG-002 keeps stalled (not stripped)" "remove-label stalled" "$edit_calls"

# TC-HYG-003 — all 4 transitionals at once
_GH_CALLS=()
labels=$(mklabels_json autonomous approved in-progress reviewing pending-dev pending-review)
hygiene_strip_residual_labels 103 "$labels" >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
for tlabel in in-progress reviewing pending-dev pending-review; do
  assert_match "TC-HYG-003 strips $tlabel" "remove-label $tlabel" "$edit_calls"
done
# Single edit call (not 4) — bundled in one gh issue edit
edit_count=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -cE '^issue edit' || true)
assert_eq "TC-HYG-003 single bundled edit call" "1" "$edit_count"

# TC-HYG-004 — stalled side
_GH_CALLS=()
labels=$(mklabels_json autonomous stalled pending-dev)
hygiene_strip_residual_labels 104 "$labels" >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
assert_match "TC-HYG-004 strips pending-dev under stalled" "remove-label pending-dev" "$edit_calls"

# TC-HYG-005 — clean approved, no-op
_GH_CALLS=()
labels=$(mklabels_json autonomous approved)
hygiene_strip_residual_labels 105 "$labels" >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
assert_eq "TC-HYG-005 clean approved → no edit call" "" "$edit_calls"

# TC-HYG-006 — not a terminal residue at all
_GH_CALLS=()
labels=$(mklabels_json autonomous in-progress)
hygiene_strip_residual_labels 106 "$labels" >/dev/null
edit_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue edit' || true)
assert_eq "TC-HYG-006 plain in-progress → no edit call" "" "$edit_calls"

# ===================================================================
# hygiene_post_audit_comment idempotency
# ===================================================================
echo
echo "=== TC-COMMENT: hygiene_post_audit_comment idempotency ==="

# TC-COMMENT-001 — no marker present, must post
_GH_CALLS=()
_MOCK_COMMENTS_JSON='0'
hygiene_post_audit_comment 200 "approved" "in-progress reviewing" >/dev/null
comment_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -cE '^issue comment' || true)
assert_eq "TC-COMMENT-001 no marker → 1 comment posted" "1" "$comment_calls"

# TC-COMMENT-002 — marker present, must skip
_GH_CALLS=()
_MOCK_COMMENTS_JSON='1'
hygiene_post_audit_comment 201 "approved" "in-progress reviewing" >/dev/null
comment_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -cE '^issue comment' || true)
assert_eq "TC-COMMENT-002 marker present → 0 comments" "0" "$comment_calls"

# TC-COMMENT-003 — different-residue marker won't match
# (helper computes its own marker from the residue list; the mock returns 0
# for "this specific marker not found" semantics — same as the real
# `[.comments[] | select(contains("X"))] | length` query.)
_GH_CALLS=()
_MOCK_COMMENTS_JSON='0'
hygiene_post_audit_comment 202 "approved" "pending-dev" >/dev/null
comment_calls=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -cE '^issue comment' || true)
assert_eq "TC-COMMENT-003 different residue → fresh post" "1" "$comment_calls"

# TC-COMMENT-004 — narrower-residue probe must NOT substring-collide with
# a wider-residue marker already on the issue. Verified by inspecting the
# marker the helper writes into the comment body (which is what the
# probe also matches against). The marker MUST end with a delimiter
# (semicolon) that bounds the set so `contains("...:in-progress;")`
# does NOT match `...:in-progress,reviewing;`.
#
# We assert the body shape directly (the helper builds it and passes
# it to `gh issue comment --body`), bypassing the existing-marker
# branch which is already covered by TC-COMMENT-002.
_GH_CALLS=()
_MOCK_COMMENTS_JSON='0'
hygiene_post_audit_comment 203 "approved" "in-progress reviewing" >/dev/null
emitted_body=$(printf '%s\n' "${_GH_CALLS[@]}" | grep -E '^issue comment' || true)
# Body should contain the wide marker with terminator
assert_match "TC-COMMENT-004 wide marker carries terminator" 'INV-25-hygiene:in-progress,reviewing;' "$emitted_body"
# And critically must NOT contain a substring that the narrower probe
# `INV-25-hygiene:in-progress;` would equality-match (the narrower
# probe MUST mismatch this body, even though it substring-matches
# without the terminator).
assert_no_match "TC-COMMENT-004 narrower probe with terminator does NOT match wide body" 'INV-25-hygiene:in-progress;' "$emitted_body"

# ===================================================================
# Step 0 structural placement
# ===================================================================
echo
echo "=== TC-STEP0-INT: dispatcher-tick.sh structural integration ==="

# TC-STEP0-INT-001 — Step 0 marker exists in tick file
if grep -qE '^# Step 0:' "$TICK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-STEP0-INT-001 Step 0 invocation in tick"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-STEP0-INT-001 Step 0 marker missing"
  FAIL=$((FAIL + 1))
fi

# TC-STEP0-INT-002 — Step 0 appears before Step 1 concurrency gate
step0_line=$(grep -nE '^# Step 0:' "$TICK" | head -1 | cut -d: -f1)
step1_line=$(grep -nE '^# Step 1:' "$TICK" | head -1 | cut -d: -f1)
if [[ -n "$step0_line" && -n "$step1_line" && "$step0_line" -lt "$step1_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-STEP0-INT-002 Step 0 (line $step0_line) < Step 1 (line $step1_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-STEP0-INT-002 Step 0 ordering wrong (s0=$step0_line s1=$step1_line)"
  FAIL=$((FAIL + 1))
fi

# TC-STEP0-INT-003 — Step 0 must NOT be skipped by the concurrency gate.
# Verify by checking the concurrency `exit 0` block sits AFTER Step 0.
exit_line=$(grep -nE 'Concurrency limit reached.*Aborting tick' "$TICK" | head -1 | cut -d: -f1)
if [[ -n "$step0_line" && -n "$exit_line" && "$step0_line" -lt "$exit_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-STEP0-INT-003 Step 0 runs before concurrency exit"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-STEP0-INT-003 Step 0 may be gated by concurrency (s0=$step0_line exit=$exit_line)"
  FAIL=$((FAIL + 1))
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
