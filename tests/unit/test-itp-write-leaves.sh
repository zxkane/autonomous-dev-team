#!/bin/bash
# test-itp-write-leaves.sh — #283: ITP WRITE-leaf migration.
#
# Proves the WRITE half of the ITP contract (provider-spec.md §3.1, the verb↔
# current-function mapping appendix, [INV-87]/[INV-88]/[INV-89]) is a
# zero-behavior-change GitHub refactor:
#
#   1. Golden-trace argv — itp_github_transition_state / post_comment /
#      edit_comment / mark_checkbox / provision_states emit BYTE-IDENTICAL `gh`
#      argv (incl. the transition empty-REMOVE/empty-ADD flag-omission cases, and
#      the post_dispatch_token INV-18 + _dep_block_comment INV-39 marker BODIES
#      verbatim).
#   2. Dispatch routing — each itp_<verb> dispatches to itp_github_<verb>.
#   3. .caps parse — edit_comment=1 / body_checkbox=1 / label_colors=1 /
#      marker_channel=html (the values the write-side branches consume).
#   4. Capability-branch via the named degraded fake provider (edit_comment=0 →
#      fresh marker; body_checkbox=0 / label_colors=0 fallbacks).
#   5. marker_channel regression — post_comment does NOT strip <!-- ... -->.
#   6. Cutover pin + function-mock shim audit (§7.3 m3): grep gh issue comment==0,
#      label_swap delegates, INV-25 subtraction stays caller-side, no rename.
#
# Run: bash tests/unit/test-itp-write-leaves.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
COMMON_SCRIPTS="$PROJECT_ROOT/skills/autonomous-common/scripts"
LIB="$SCRIPTS/lib-dispatch.sh"
ITP_LIB="$SCRIPTS/lib-issue-provider.sh"
PROVIDERS="$SCRIPTS/providers"
E2E_LIB="$SCRIPTS/lib-review-e2e.sh"
FAKE_PROVIDER="$SCRIPT_DIR/fixtures/provider-degraded"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: |$needle|"; echo "      hay:    |$hay|"
    FAIL=$((FAIL + 1))
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      unexpected needle: |$needle|"
    FAIL=$((FAIL + 1))
  fi
}

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export REPO_NAME=autonomous-dev-team
export PROJECT_ID=test-itp-write-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ===========================================================================
# 1. GOLDEN-TRACE — record the exact `gh` argv each WRITE leaf emits, assert it
#    byte-identical to the pre-refactor call (the no-behavior-change proof).
# ===========================================================================
# A recording `gh` stub: writes full argv (one arg per line) to $_GH_ARGV_FILE.
# For `gh label view` it returns rc per $_GH_LABEL_VIEW_RC so the provision
# view-or-create branch can be exercised both ways.
_GH_ARGV_FILE="$(mktemp)"
_GH_LABEL_VIEW_RC=1
gh() {
  printf '%s\n' "$@" > "$_GH_ARGV_FILE"
  if [[ "${1:-}" == "label" && "${2:-}" == "view" ]]; then
    return "$_GH_LABEL_VIEW_RC"
  fi
  return 0
}
export -f gh
export _GH_ARGV_FILE _GH_LABEL_VIEW_RC

# Source the provider leaves directly (default github).
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-issue-provider.sh
source "$ITP_LIB"
set +e

recorded_argv() { paste -sd' ' "$_GH_ARGV_FILE"; }

echo "=== GOLDEN-TRACE: itp_github_transition_state (label_swap leaf) ==="
itp_github_transition_state 42 pending-dev pending-review >/dev/null
assert_eq "TC-GT-TRANS-BOTH remove+add argv" \
  "issue edit 42 --repo $REPO --remove-label pending-dev --add-label pending-review" "$(recorded_argv)"

itp_github_transition_state 42 "" in-progress >/dev/null
assert_eq "TC-GT-TRANS-EMPTYREMOVE omits --remove-label" \
  "issue edit 42 --repo $REPO --add-label in-progress" "$(recorded_argv)"

itp_github_transition_state 42 reviewing "" >/dev/null
assert_eq "TC-GT-TRANS-EMPTYADD omits --add-label" \
  "issue edit 42 --repo $REPO --remove-label reviewing" "$(recorded_argv)"

itp_github_transition_state 42 "" "" >/dev/null
assert_eq "TC-GT-TRANS-EMPTYBOTH bare edit (no flags)" \
  "issue edit 42 --repo $REPO" "$(recorded_argv)"

echo "=== GOLDEN-TRACE: itp_github_post_comment ==="
itp_github_post_comment 42 "hello world" >/dev/null
assert_eq "TC-GT-POST plain body argv" \
  "issue comment 42 --repo $REPO --body hello world" "$(recorded_argv)"

# INV-18 dispatcher-token marker BODY preserved verbatim (multi-line: marker + human).
_inv18_body="<!-- dispatcher-token: 44f1f44b752b at 2026-06-27T09:05:46Z mode=dev-new -->
Dispatching autonomous development..."
itp_github_post_comment 42 "$_inv18_body" >/dev/null
# argv recording joins on spaces; assert the HTML marker token is present unaltered.
assert_contains "TC-GT-POST-INV18 dispatcher-token marker passed to --body verbatim" \
  "<!-- dispatcher-token: 44f1f44b752b at 2026-06-27T09:05:46Z mode=dev-new -->" "$(recorded_argv)"

# INV-39 dep-block marker BODY preserved verbatim.
itp_github_post_comment 42 "Dependency \`o/r#5\` could not be resolved. <!-- dep-block:o/r#5 -->" >/dev/null
assert_contains "TC-GT-POST-INV39 dep-block marker passed to --body verbatim" \
  "<!-- dep-block:o/r#5 -->" "$(recorded_argv)"

echo "=== GOLDEN-TRACE: itp_github_edit_comment (INV-46 PATCH leaf) ==="
itp_github_edit_comment 42 999888 "new body text" >/dev/null
assert_eq "TC-GT-EDIT PATCH argv (issue/PR comments endpoint, REST numeric id)" \
  "api -X PATCH repos/$REPO_OWNER/$REPO_NAME/issues/comments/999888 -f body=new body text" "$(recorded_argv)"

echo "=== GOLDEN-TRACE: itp_github_mark_checkbox (mark-issue-checkbox PATCH leaf) ==="
itp_github_mark_checkbox 42 "the new issue body" >/dev/null
assert_eq "TC-GT-CHECKBOX PATCH body argv" \
  "api repos/$REPO/issues/42 --method PATCH --field body=the new issue body --silent" "$(recorded_argv)"

echo "=== GOLDEN-TRACE: itp_github_provision_states (setup-labels leaf) ==="
# label_colors=1 / not-exists → create with --color hex --description.
_GH_LABEL_VIEW_RC=1
out=$(itp_github_provision_states autonomous 0E8A16 "Issue should be processed by autonomous pipeline")
assert_eq "TC-GT-PROVISION-CREATE create argv with --color hex --description" \
  "label create autonomous --repo $REPO --color 0E8A16 --description Issue should be processed by autonomous pipeline" "$(recorded_argv)"
assert_contains "TC-GT-PROVISION-CREATE prints [created]" "[created] 'autonomous'" "$out"
# exists → skip, no create (last recorded argv is the `label view`).
_GH_LABEL_VIEW_RC=0
out=$(itp_github_provision_states autonomous 0E8A16 "desc")
assert_eq "TC-GT-PROVISION-SKIP view-only argv (no create emitted)" \
  "label view autonomous --repo $REPO" "$(recorded_argv)"
assert_contains "TC-GT-PROVISION-SKIP prints [skip]" "[skip] 'autonomous'" "$out"
_GH_LABEL_VIEW_RC=1

# ===========================================================================
# 2. DISPATCH ROUTING — itp_<verb> → itp_github_<verb> under default github.
# ===========================================================================
echo "=== DISPATCH ROUTING: itp_<verb> → itp_github_<verb> ==="
routed=$(
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github bash -c '
    set -uo pipefail
    export REPO='"$REPO"' REPO_OWNER='"$REPO_OWNER"' REPO_NAME='"$REPO_NAME"'
    source "'"$ITP_LIB"'"
    itp_github_transition_state() { echo "ROUTED:transition_state:$*"; }
    itp_github_post_comment()     { echo "ROUTED:post_comment:$*"; }
    itp_github_edit_comment()     { echo "ROUTED:edit_comment:$*"; }
    itp_github_mark_checkbox()    { echo "ROUTED:mark_checkbox:$*"; }
    itp_github_provision_states() { echo "ROUTED:provision_states:$*"; }
    itp_transition_state 7 a b
    itp_post_comment 7 body
    itp_edit_comment 7 99 newbody
    itp_mark_checkbox 7 NEWBODY
    itp_provision_states nm clr ds
  '
)
assert_contains "TC-RT-TRANS itp_transition_state → itp_github_transition_state" "ROUTED:transition_state:7 a b" "$routed"
assert_contains "TC-RT-POST itp_post_comment → itp_github_post_comment" "ROUTED:post_comment:7 body" "$routed"
assert_contains "TC-RT-EDIT itp_edit_comment → itp_github_edit_comment" "ROUTED:edit_comment:7 99 newbody" "$routed"
assert_contains "TC-RT-CHECKBOX itp_mark_checkbox → itp_github_mark_checkbox" "ROUTED:mark_checkbox:7 NEWBODY" "$routed"
assert_contains "TC-RT-PROVISION itp_provision_states → itp_github_provision_states" "ROUTED:provision_states:nm clr ds" "$routed"

# ===========================================================================
# 3. .caps PARSE — the values the WRITE-side branches consume (§4.3, [INV-88]).
# ===========================================================================
echo "=== .caps PARSE: itp-github.caps write-side capabilities ==="
caps_out=$(
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github bash -c '
    source "'"$ITP_LIB"'"
    echo "EDIT=$(itp_caps edit_comment)"
    echo "CHECKBOX=$(itp_caps body_checkbox)"
    echo "COLORS=$(itp_caps label_colors)"
    echo "CHANNEL=$(itp_caps marker_channel)"
  '
)
assert_contains "TC-CAPS-EDIT edit_comment=1" "EDIT=1" "$caps_out"
assert_contains "TC-CAPS-CHECKBOX body_checkbox=1" "CHECKBOX=1" "$caps_out"
assert_contains "TC-CAPS-COLORS label_colors=1" "COLORS=1" "$caps_out"
assert_contains "TC-CAPS-CHANNEL marker_channel=html" "CHANNEL=html" "$caps_out"

# ===========================================================================
# 4. CAPABILITY-BRANCH via the named degraded fake provider (§7.4).
#    edit_comment=0 → fresh marker; body_checkbox=0 / label_colors=0 fallbacks.
# ===========================================================================
echo "=== CAPABILITY-BRANCH: degraded fake provider caps=0 (public seam) ==="
if [[ -d "$FAKE_PROVIDER" ]]; then
  fake=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
    bash -c '
      source "'"$ITP_LIB"'"
      echo "EDIT=$(itp_caps edit_comment)"
      echo "CHECKBOX=$(itp_caps body_checkbox)"
      echo "COLORS=$(itp_caps label_colors)"
      echo "CHANNEL=$(itp_caps marker_channel)"
    '
  )
  assert_contains "TC-CAP-EDIT0 degraded: edit_comment=0 (INV-46 fresh-marker fallback branch)" "EDIT=0" "$fake"
  assert_contains "TC-CAP-CHECKBOX0 degraded: body_checkbox=0 (native-subtask remap branch)" "CHECKBOX=0" "$fake"
  assert_contains "TC-CAP-COLORS0 degraded: label_colors=0 (color-omitted create branch)" "COLORS=0" "$fake"
  assert_contains "TC-CAP-CHANNEL-TEXT degraded: marker_channel=text (non-html channel)" "CHANNEL=text" "$fake"

  # INV-46 [P1] regression — drive the REAL _stamp_browser_evidence_marker with
  # edit_comment=0 and assert the fresh comment carries the FULL E2E report body
  # PLUS the SHA marker, NOT a marker-only post. A marker-only fallback would let
  # _fetch_sha_evidence (which returns the `last` SHA-marked comment's full body)
  # satisfy the dual-signal gate with no report/screenshots/AC — the
  # marker-only-fabrication hole [INV-46] closes. The gh READ leaves (comment-id +
  # body fetch) are stubbed; itp_post_comment captures what the fallback posts.
  # NOTE: _stamp_browser_evidence_marker calls the write verb with `>/dev/null
  # 2>&1`, so the stub must capture into a FILE (stdout is swallowed). $_CAP_FILE
  # records every verb call + its args.
  _CAP_FILE="$(mktemp)"
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
      PR_NUMBER=42 REPO_OWNER=o REPO_NAME=r PR_HEAD_SHA=deadbeef \
      WRAPPER_START_TS=2026-01-01T00:00:00Z REPO=o/r BOT_LOGIN= _CAP_FILE="$_CAP_FILE" \
  bash -c '
    set -uo pipefail
    log() { :; }
    # Stub the gh READ leaves used by _stamp_browser_evidence_marker:
    #  1) read comment body (…/issues/comments/99) → the full E2E report (checked
    #     FIRST since its path also ends in "comments")
    #  2) list comments (…/PR/comments) → emit the numeric report-comment id (99)
    gh() {
      if [[ "$1" == "api" && "$2" == *"/issues/comments/99" ]]; then
        printf "%s" "## E2E Verification Report - AC-1: PASS - screenshot.png"; return 0; fi
      if [[ "$1" == "api" && "$2" == *"/comments" ]]; then echo "99"; return 0; fi
      return 0
    }
    # Source the lib FIRST so the REAL seam (incl. itp_caps reading the degraded
    # .caps → edit_comment=0) loads; THEN override the two write verbs with stubs
    # that record into $_CAP_FILE (the call args survive the verb call'\''s
    # >/dev/null 2>&1 redirect, which would swallow stdout/stderr).
    source "'"$E2E_LIB"'"
    itp_post_comment() { printf "POSTED_BODY<<%s>>\n" "$2" >> "$_CAP_FILE"; }
    itp_edit_comment() { printf "PATCH_TAKEN\n" >> "$_CAP_FILE"; }
    _stamp_browser_evidence_marker
  '
  edit0_post="$(cat "$_CAP_FILE")"; : > "$_CAP_FILE"
  assert_contains "TC-CAP-EDIT0-REPORT edit_comment=0 fresh post carries the FULL report body" \
    "## E2E Verification Report" "$edit0_post"
  assert_contains "TC-CAP-EDIT0-REPORT edit_comment=0 fresh post carries the AC evidence" \
    "AC-1: PASS" "$edit0_post"
  assert_contains "TC-CAP-EDIT0-REPORT edit_comment=0 fresh post carries the SHA marker" \
    'e2e-evidence: complete sha="deadbeef"' "$edit0_post"
  assert_not_contains "TC-CAP-EDIT0-REPORT edit_comment=0 does NOT take the PATCH path" "PATCH_TAKEN" "$edit0_post"

  # edit_comment=1 (github) → PATCH path is taken, with the full report+marker body.
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github \
      PR_NUMBER=42 REPO_OWNER=o REPO_NAME=r PR_HEAD_SHA=deadbeef \
      WRAPPER_START_TS=2026-01-01T00:00:00Z REPO=o/r BOT_LOGIN= _CAP_FILE="$_CAP_FILE" \
  bash -c '
    set -uo pipefail
    log() { :; }
    gh() {
      if [[ "$1" == "api" && "$2" == *"/issues/comments/99" ]]; then
        printf "%s" "## E2E Verification Report - AC-1: PASS"; return 0; fi
      if [[ "$1" == "api" && "$2" == *"/comments" ]]; then echo "99"; return 0; fi
      return 0
    }
    source "'"$E2E_LIB"'"
    itp_post_comment() { printf "FRESH_POST_TAKEN\n" >> "$_CAP_FILE"; }
    itp_edit_comment() { printf "PATCH_TAKEN id=%s body<<%s>>\n" "$2" "$3" >> "$_CAP_FILE"; }
    _stamp_browser_evidence_marker
  '
  edit1_post="$(cat "$_CAP_FILE")"; rm -f "$_CAP_FILE"
  assert_contains "TC-CAP-EDIT1-BRANCH edit_comment=1 (github) takes the PATCH path on comment 99" "PATCH_TAKEN id=99" "$edit1_post"
  assert_contains "TC-CAP-EDIT1-BRANCH edit_comment=1 PATCH body carries report+marker" "## E2E Verification Report" "$edit1_post"
  assert_not_contains "TC-CAP-EDIT1-BRANCH edit_comment=1 does NOT post a fresh comment" "FRESH_POST_TAKEN" "$edit1_post"
else
  echo -e "  ${RED}FAIL${NC}: degraded fake provider fixture missing at $FAKE_PROVIDER (expected from #280)"
  FAIL=$((FAIL+1))
fi

# ===========================================================================
# 5. marker_channel REGRESSION — itp_github_post_comment does NOT strip the
#    <!-- ... --> HTML marker (the dispatcher-marker survival INV-18/INV-39
#    depend on; the github/html channel round-trips it verbatim).
# ===========================================================================
echo "=== marker_channel REGRESSION: html channel preserves <!-- ... --> ==="
itp_github_post_comment 42 "<!-- dispatcher-token: abc -->visible" >/dev/null
chan_argv="$(recorded_argv)"
assert_contains "TC-MARKER-HTML html-comment marker not stripped/sanitized" "<!-- dispatcher-token: abc -->visible" "$chan_argv"

# ===========================================================================
# 6. CUTOVER PIN + FUNCTION-MOCK SHIM AUDIT (§7.3 m3) over the real files.
# ===========================================================================
echo "=== CUTOVER PIN + FUNCTION-MOCK SHIM AUDIT ==="
comment_count=$(grep -c 'gh issue comment' "$LIB")
assert_eq "TC-CUTOVER-COMMENT0 no raw 'gh issue comment' in lib-dispatch.sh" "0" "$comment_count"

# [INV-89] Repo-wide ITP-issue-comment cutover: every machine-marker issue comment
# — dispatcher AND agent AND wrapper — routes through itp_post_comment, so a
# non-GitHub / marker_channel=text provider cannot bypass the seam for ANY issue
# comment. Pins ZERO raw `gh issue comment` across all five ITP-issue-comment files.
# (`gh pr comment` / review-thread replies are CHP, NOT counted — owned by
# chp-pr-lifecycle.) NOTE: the cutover LINT (a CI guard that fails on raw-gh) is the
# separate cutover-guard-lint deliverable; this is the migration-completeness pin.
for _f in "$LIB" \
          "$SCRIPTS/autonomous-dev.sh" \
          "$SCRIPTS/autonomous-review.sh" \
          "$SCRIPTS/dispatcher-tick.sh" \
          "$SCRIPTS/lib-review-verdict.sh"; do
  # A REAL call is `gh issue comment "<var>` (the issue-id arg). Exclude `#` comment
  # lines (prose mentions) and the prompt-embedded backtick references.
  _c=$(grep -vE '^[[:space:]]*#' "$_f" | grep -cE '(^|[^`-])gh issue comment "')
  assert_eq "TC-CUTOVER-COMMENT0-WIDE no raw 'gh issue comment' in $(basename "$_f")" "0" "$_c"
done

# label_swap() body delegates to itp_transition_state (no raw gh issue edit in it).
label_swap_body=$(awk '/^label_swap\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "$LIB")
assert_contains "TC-CUTOVER-SWAP label_swap delegates to itp_transition_state" "itp_transition_state" "$label_swap_body"
assert_not_contains "TC-CUTOVER-SWAP label_swap holds no raw gh issue edit" "gh issue edit" "$label_swap_body"

# INV-25 terminal-state jq subtraction stays caller-side (NOT in itp_transition_state).
itp_calls=$(grep -c 'itp_post_comment' "$LIB")
[ "$itp_calls" -ge 18 ] && echo -e "  ${GREEN}PASS${NC}: TC-CUTOVER-POST ≥18 itp_post_comment call sites ($itp_calls)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-CUTOVER-POST expected ≥18 itp_post_comment calls, got $itp_calls"; FAIL=$((FAIL+1)); }

# The [INV-25] subtraction literal stays in the caller (list_pending_review/dev),
# NOT folded into the transition verb.
trans_body=$(awk '/^itp_github_transition_state\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "$PROVIDERS/itp-github.sh")
assert_not_contains "TC-CALLERSIDE-INV25 transition verb does NOT carry the terminal-state jq subtraction" 'approved' "$trans_body"
inv25_caller=$(grep -c 'select.*approved\|"approved"' "$LIB")
[ "$inv25_caller" -ge 1 ] && echo -e "  ${GREEN}PASS${NC}: TC-CALLERSIDE-INV25 INV-25 terminal-state subtraction stays in lib-dispatch.sh caller ($inv25_caller sites)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-CALLERSIDE-INV25 INV-25 caller-side subtraction missing"; FAIL=$((FAIL+1)); }

# No rename: the migrated functions keep their EXACT names so existing
# function-level mocks (label_swap, post_dispatch_token, _dep_block_comment) bind.
export REPO REPO_OWNER REPO_NAME PROJECT_ID MAX_RETRIES MAX_CONCURRENT
audit_ok=1
audit=$(bash -c '
  source "'"$LIB"'" 2>/dev/null
  for fn in label_swap post_dispatch_token _dep_block_comment \
            mark_stalled handle_completed_session_routing hygiene_post_audit_comment; do
    declare -F "$fn" >/dev/null 2>&1 || echo "MISSING:$fn"
  done
')
[ -z "$audit" ] || { echo "   $audit"; audit_ok=0; }
assert_eq "TC-AUDIT-NORENAME migrated functions keep their names (shim=same name)" "1" "$audit_ok"

# mark-issue-checkbox.sh + setup-labels.sh delegate to the verbs.
assert_contains "TC-CHECKBOX-DELEGATE mark-issue-checkbox.sh calls itp_mark_checkbox" \
  "itp_mark_checkbox" "$(cat "$COMMON_SCRIPTS/mark-issue-checkbox.sh")"
assert_contains "TC-PROVISION-DELEGATE setup-labels.sh calls itp_provision_states" \
  "itp_provision_states" "$(cat "$SCRIPTS/setup-labels.sh")"
assert_contains "TC-E2E-DELEGATE lib-review-e2e.sh calls itp_edit_comment" \
  "itp_edit_comment" "$(cat "$E2E_LIB")"

rm -f "$_GH_ARGV_FILE"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
