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
# [#342] The CHP seam. lib-review-e2e.sh calls chp_pr_view (in _fetch_sha_evidence)
# but self-sources ONLY the ITP seam, so any context that sources it must supply
# the CHP seam itself. The _stamp_browser_evidence_marker path exercised below
# does not call chp_pr_view, so the seam is inert here — but sourcing it BEFORE
# the lib (mirroring autonomous-review.sh's lib-code-host→lib-review-e2e order)
# keeps this harness compliant with the seam-source meta-check (test-seam-source-meta.sh)
# and forward-safe if a future migration routes the stamp path through a CHP verb.
CHP_LIB="$SCRIPTS/lib-code-host.sh"
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
# A recording `gh` stub: writes full argv (one arg per line) to $_GH_ARGV_FILE
# AND appends a one-line record to $_GH_CALL_LOG (so callers can assert over
# MULTIPLE invocations, not just the last). For the provision REST existence
# probe (`gh api repos/<repo>/labels/<name> --silent`) it returns rc per
# $_GH_LABEL_PROBE_RC so the probe-or-create branch can be exercised both ways.
# [#362] `gh label` has NO `view` subcommand on real gh (only
# clone/create/delete/edit/list) — the double does NOT implement it either; any
# `label view` call is rejected loudly (mirroring real gh's "unknown command"
# error), so a regression back to the pre-fix `gh label view` check trips
# TC-PROVISION-NO-LABEL-VIEW below instead of silently recording success.
_GH_ARGV_FILE="$(mktemp)"
_GH_CALL_LOG="$(mktemp)"
_GH_LABEL_PROBE_RC=1
gh() {
  printf '%s\n' "$@" > "$_GH_ARGV_FILE"
  printf '%s\n' "$*" >> "$_GH_CALL_LOG"
  if [[ "${1:-}" == "label" && "${2:-}" == "view" ]]; then
    echo 'unknown command "view" for "gh label"' >&2
    return 1
  fi
  if [[ "${1:-}" == "api" && "${2:-}" == repos/*/labels/* && "${3:-}" == "--silent" ]]; then
    return "$_GH_LABEL_PROBE_RC"
  fi
  return 0
}
export -f gh
export _GH_ARGV_FILE _GH_CALL_LOG _GH_LABEL_PROBE_RC

# Source the provider leaves directly (default github).
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-issue-provider.sh
source "$ITP_LIB"
set +e

recorded_argv() { paste -sd' ' "$_GH_ARGV_FILE"; }
reset_call_log() { : > "$_GH_CALL_LOG"; }
call_log() { cat "$_GH_CALL_LOG"; }

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

echo "=== GOLDEN-TRACE: itp_github_provision_states (setup-labels leaf, [#362] REST probe) ==="
# label_colors=1 / probe rc=1 (missing) → create with --color hex --description.
# The create-branch argv stays byte-identical to the pre-#362 loop body.
_GH_LABEL_PROBE_RC=1
reset_call_log
out=$(itp_github_provision_states autonomous 0E8A16 "Issue should be processed by autonomous pipeline")
assert_eq "TC-GT-PROVISION-CREATE create argv with --color hex --description" \
  "label create autonomous --repo $REPO --color 0E8A16 --description Issue should be processed by autonomous pipeline" "$(recorded_argv)"
assert_contains "TC-GT-PROVISION-CREATE prints [created]" "[created] 'autonomous'" "$out"
assert_contains "TC-GT-PROVISION-CREATE probes via gh api repos/*/labels/* --silent" \
  "api repos/$REPO/labels/autonomous --silent" "$(call_log)"
assert_not_contains "TC-GT-PROVISION-CREATE never calls gh label view" "label view" "$(call_log)"

# probe rc=0 (exists) → skip, no create (last recorded argv is the REST probe).
_GH_LABEL_PROBE_RC=0
reset_call_log
out=$(itp_github_provision_states autonomous 0E8A16 "desc")
assert_eq "TC-GT-PROVISION-SKIP REST-probe-only argv (no create emitted)" \
  "api repos/$REPO/labels/autonomous --silent" "$(recorded_argv)"
assert_contains "TC-GT-PROVISION-SKIP prints [skip]" "[skip] 'autonomous'" "$out"
assert_not_contains "TC-GT-PROVISION-SKIP does NOT call gh label create" "label create" "$(call_log)"
assert_not_contains "TC-GT-PROVISION-SKIP never calls gh label view" "label view" "$(call_log)"
_GH_LABEL_PROBE_RC=1

echo "=== TC-PROVISION-NO-LABEL-VIEW: the double rejects 'gh label view' like real gh ==="
# Sanity-check the double itself models real gh (clone/create/delete/edit/list +
# api only, no view): a direct `gh label view` call must fail non-zero. This is
# the fixture-side proof that the golden-trace above would have FAILed against
# the pre-#362 implementation (which called `gh label view` and got a non-zero
# rc, hitting the create branch unconditionally) rather than silently passing.
if gh label view autonomous --repo "$REPO" &>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-PROVISION-NO-LABEL-VIEW expected 'gh label view' to fail (real gh has no such subcommand)"
  FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-PROVISION-NO-LABEL-VIEW 'gh label view' fails loudly, matching real gh"
  PASS=$((PASS+1))
fi

echo "=== TC-PROVISION-ALL-SKIP: full-loop shape, all 9 labels pre-existing (AC3) ==="
# Drive the loop body itself (not setup-labels.sh's subprocess — the loop shape
# is identical to what setup-labels.sh runs) with the probe returning rc=0 for
# every one of the 9 pipeline labels: exit 0, nine [skip] lines, zero creates.
_GH_LABEL_PROBE_RC=0
reset_call_log
_LABELS_ALL9=(
  "autonomous|0E8A16|d1" "in-progress|FBCA04|d2" "pending-review|1D76DB|d3"
  "reviewing|5319E7|d4" "pending-dev|E99695|d5" "approved|0E8A16|d6"
  "no-auto-close|d4c5f9|d7" "stalled|B60205|d8" "run-live-smoke|006B75|d9"
)
_all9_out=""
_all9_rc=0
for _entry in "${_LABELS_ALL9[@]}"; do
  IFS='|' read -r _n _c _d <<< "$_entry"
  _line=$(itp_github_provision_states "$_n" "$_c" "$_d") || _all9_rc=$?
  _all9_out+="$_line"$'\n'
done
_skip_count=$(grep -c '^  \[skip\]' <<< "$_all9_out")
assert_eq "TC-PROVISION-ALL-SKIP nine [skip] lines" "9" "$_skip_count"
assert_eq "TC-PROVISION-ALL-SKIP loop completes without error (rc=0 per call)" "0" "$_all9_rc"
assert_not_contains "TC-PROVISION-ALL-SKIP zero gh label create calls" "label create" "$(call_log)"
_GH_LABEL_PROBE_RC=1

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
  # marker-only-fabrication hole [INV-46] closes. [#345] The id-lookup + body-fetch
  # now route through ONE itp_list_comments call (normalized [INV-90] array) instead
  # of two raw gh reads — stub itp_list_comments to emit the fixture array;
  # itp_post_comment captures what the fallback posts.
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
    # [#342] Source the CHP seam FIRST (chp_pr_view lives here), mirroring the
    # review wrapper order; inert for the stamp path but keeps this bash -c
    # context seam-source-meta compliant.
    source "'"$CHP_LIB"'"
    # Source the lib FIRST so the REAL seam (incl. itp_caps reading the degraded
    # .caps → edit_comment=0) loads; THEN override itp_list_comments + the two
    # write verbs with stubs that record into $_CAP_FILE (the call args survive
    # the verb call'\''s >/dev/null 2>&1 redirect, which would swallow
    # stdout/stderr). Overriding AFTER the source is load-bearing: sourcing the
    # lib re-sources lib-issue-provider.sh (its self-source guard, since
    # itp_edit_comment is not yet defined in a fresh bash -c), which would
    # clobber an itp_list_comments stub defined BEFORE the source.
    source "'"$E2E_LIB"'"
    # [#345] Stub the itp_list_comments READ used by _stamp_browser_evidence_marker:
    # a normalized [INV-90] array with the numeric report-comment id (99) + body.
    itp_list_comments() {
      printf "%s" "[{\"id\":99,\"author\":\"bot\",\"authorKind\":\"self\",\"body\":\"## E2E Verification Report - AC-1: PASS - screenshot.png\",\"createdAt\":\"2026-01-01T00:00:01Z\"}]"
    }
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
  # [#345] itp_list_comments stubbed (see the edit_comment=0 block above).
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github \
      PR_NUMBER=42 REPO_OWNER=o REPO_NAME=r PR_HEAD_SHA=deadbeef \
      WRAPPER_START_TS=2026-01-01T00:00:00Z REPO=o/r BOT_LOGIN= _CAP_FILE="$_CAP_FILE" \
  bash -c '
    set -uo pipefail
    log() { :; }
    source "'"$CHP_LIB"'"   # [#342] CHP seam first (see the (a) sandbox note above)
    source "'"$E2E_LIB"'"
    # [#345] itp_list_comments stubbed AFTER the source (see the edit_comment=0
    # block above for why order matters).
    itp_list_comments() {
      printf "%s" "[{\"id\":99,\"author\":\"bot\",\"authorKind\":\"self\",\"body\":\"## E2E Verification Report - AC-1: PASS\",\"createdAt\":\"2026-01-01T00:00:01Z\"}]"
    }
    itp_post_comment() { printf "FRESH_POST_TAKEN\n" >> "$_CAP_FILE"; }
    itp_edit_comment() { printf "PATCH_TAKEN id=%s body<<%s>>\n" "$2" "$3" >> "$_CAP_FILE"; }
    _stamp_browser_evidence_marker
  '
  edit1_post="$(cat "$_CAP_FILE")"; rm -f "$_CAP_FILE"
  assert_contains "TC-CAP-EDIT1-BRANCH edit_comment=1 (github) takes the PATCH path on comment 99" "PATCH_TAKEN id=99" "$edit1_post"
  assert_contains "TC-CAP-EDIT1-BRANCH edit_comment=1 PATCH body carries report+marker" "## E2E Verification Report" "$edit1_post"
  assert_not_contains "TC-CAP-EDIT1-BRANCH edit_comment=1 does NOT post a fresh comment" "FRESH_POST_TAKEN" "$edit1_post"

  # body_checkbox=0 branch (review [P1] r4): the DOCUMENTED fallback must key on the
  # CAPABILITY, not `declare -F itp_mark_checkbox` (the shim is always defined after
  # sourcing the seam). With ISSUE_PROVIDER=degraded the script must NOT crash with
  # `itp_degraded_mark_checkbox: command not found` — it takes the native-subtask
  # remap path (defined-not-implemented → clean LOUD error, no missing-leaf crash).
  # Drive the REAL mark-issue-checkbox.sh; stub the gh body-read; capture stderr.
  _CB_STUB="$(mktemp -d)"
  # The body READ is now `gh issue view <N> --repo <REPO> --json body -q '.body'`
  # (#296: itp_read_task → itp_degraded_read_task → this shape) — NOT the old
  # `gh api … --jq .body`. Recognize the new read shape and return the body; a
  # PATCH must still trip GH_PATCH_CALLED.
  cat > "$_CB_STUB/gh" <<'GHEOF'
#!/bin/bash
if [[ "$1" == "issue" && "$2" == "view" ]]; then printf '## Requirements\n- [ ] Do the thing\n'; exit 0; fi
echo "GH_PATCH_CALLED $*" >&2; exit 0
GHEOF
  chmod +x "$_CB_STUB/gh"
  # `unset -f gh` first: the golden-trace section above `export -f gh`s a recording
  # shell function that a child bash inherits and which would shadow this PATH stub
  # binary (returning an empty body → the "has no body" early-exit, masking the
  # body_checkbox branch under test).
  cb_degraded=$(
    env -u PROJECT_DIR ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
        REPO=o/r PATH="$_CB_STUB:$PATH" \
    bash -c 'unset -f gh; bash "$1" "$2" "$3"' _ "$COMMON_SCRIPTS/mark-issue-checkbox.sh" 1 "Do the thing" 2>&1
  )
  assert_contains "TC-CAP-CHECKBOX0-BRANCH body_checkbox=0 takes the documented native-subtask fallback" "body_checkbox=0" "$cb_degraded"
  assert_not_contains "TC-CAP-CHECKBOX0-BRANCH body_checkbox=0 does NOT crash on a missing provider leaf" "command not found" "$cb_degraded"
  assert_not_contains "TC-CAP-CHECKBOX0-BRANCH body_checkbox=0 does NOT PATCH via gh" "GH_PATCH_CALLED" "$cb_degraded"
  rm -rf "$_CB_STUB"

  # label_colors=0 branch (review [P1] r4): same shim-vs-cap fix in setup-labels.sh.
  # ISSUE_PROVIDER=degraded must NOT crash with `itp_degraded_provision_states:
  # command not found` — it takes the documented color-omitted path (defined-not-live
  # → clean LOUD error, no gh label call, no missing-leaf crash).
  _LC_STUB="$(mktemp -d)"
  cat > "$_LC_STUB/gh" <<'GHEOF'
#!/bin/bash
echo "GH_LABEL_CALLED $*" >&2; exit 0
GHEOF
  chmod +x "$_LC_STUB/gh"
  # `unset -f gh` first (same inherited-function shadow as the checkbox case above).
  lc_degraded=$(
    env -u PROJECT_DIR ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
        PATH="$_LC_STUB:$PATH" \
    bash -c 'unset -f gh; bash "$1" "$2"' _ "$SCRIPTS/setup-labels.sh" o/r 2>&1
  )
  assert_contains "TC-CAP-COLORS0-BRANCH label_colors=0 takes the documented color-omitted fallback" "label_colors=0" "$lc_degraded"
  assert_not_contains "TC-CAP-COLORS0-BRANCH label_colors=0 does NOT crash on a missing provider leaf" "command not found" "$lc_degraded"
  assert_not_contains "TC-CAP-COLORS0-BRANCH label_colors=0 does NOT call gh label" "GH_LABEL_CALLED" "$lc_degraded"
  rm -rf "$_LC_STUB"
else
  echo -e "  ${RED}FAIL${NC}: degraded fake provider fixture missing at $FAKE_PROVIDER (expected from #280)"
  FAIL=$((FAIL+1))
fi

# ===========================================================================
# 4b. PROVIDER-LIB-ABSENT FAIL-LOUD (#303 B1, [INV-91]). When the provider lib
#     CANNOT be resolved at all (no skill tree beside the script), the
#     itp_mark_checkbox / itp_provision_states SHIMS stay UNDEFINED. The old code
#     silently fell back to a HARDCODED `gh` call (a non-GitHub backend would then
#     execute GitHub commands); B1 DELETED that fallback. Each script MUST now FAIL
#     LOUD (non-zero exit + a "provider lib not loaded" error naming the verb) and
#     MUST NOT invoke `gh`. We force the shim-undefined state by running a COPY of
#     each script ALONE in an isolated temp dir, so its readlink-f lib lookup finds
#     no sibling lib-issue-provider.sh. A tripwire `gh` on PATH fails the assertion
#     if it is ever called.
# ===========================================================================
echo "=== PROVIDER-LIB-ABSENT FAIL-LOUD (#303 B1): shim undefined → fail loud, no gh ==="

# Tripwire `gh`: any invocation prints a sentinel + exits non-zero (so a fallthrough
# to a raw gh both shows up in the captured output AND would change the rc).
_TRIPWIRE_DIR="$(mktemp -d)"
cat > "$_TRIPWIRE_DIR/gh" <<'GHEOF'
#!/bin/bash
echo "TRIPWIRE_GH_CALLED $*" >&2
exit 0
GHEOF
chmod +x "$_TRIPWIRE_DIR/gh"

# (1) mark-issue-checkbox.sh — copy ALONE (no provider lib beside it). itp_read_task
#     / itp_mark_checkbox / itp_caps stay UNDEFINED. Since #296 the body READ routes
#     through itp_read_task BEFORE the PATCH-cap branch, so the EARLIER fail-loud
#     (read-side) fires first: the script must fail loud naming "itp_read_task not
#     available", exit non-zero, and never invoke gh (no read, no PATCH). The
#     tripwire gh below is keyed on the NEW read shape (gh issue view … --json body)
#     AND a PATCH; neither should ever be reached.
_MIC_ISO="$(mktemp -d)"
cp "$COMMON_SCRIPTS/mark-issue-checkbox.sh" "$_MIC_ISO/mark-issue-checkbox.sh"
# A read-stub gh that returns a body with the target checkbox, but trips on a PATCH.
# (Recognizes the migrated `gh issue view … --json body` read shape; with the verb
# undefined the script fails BEFORE any gh call, so neither arm should fire.)
cat > "$_MIC_ISO/gh" <<'GHEOF'
#!/bin/bash
for a in "$@"; do [ "$a" = "PATCH" ] && { echo "TRIPWIRE_GH_PATCH_CALLED $*" >&2; exit 0; }; done
if [[ "$1" == "issue" && "$2" == "view" ]]; then printf '## Requirements\n- [ ] Do the thing\n'; exit 0; fi
echo "TRIPWIRE_GH_CALLED $*" >&2; exit 0
GHEOF
chmod +x "$_MIC_ISO/gh"
mic_absent=$(
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u AUTONOMOUS_PROVIDERS_DIR \
      -u ISSUE_PROVIDER REPO=o/r PATH="$_MIC_ISO:$PATH" \
  bash -c 'unset -f gh; bash "$1" "$2" "$3"' _ "$_MIC_ISO/mark-issue-checkbox.sh" 1 "Do the thing" 2>&1
); mic_rc=$?
# AC2c re-baseline: provider lib absent → the body READ verb (itp_read_task) is
# undefined, so the script fails loud in the EARLIER fetch handler — NOT at the
# itp_mark_checkbox PATCH-cap branch, NOT a `command not found`.
assert_contains "TC-B1-CHECKBOX-ABSENT fails loud naming itp_read_task when provider lib absent (earlier read-side fail)" \
  "itp_read_task not available" "$mic_absent"
assert_not_contains "TC-B1-CHECKBOX-ABSENT does NOT die on a missing-verb command-not-found" \
  "command not found" "$mic_absent"
assert_not_contains "TC-B1-CHECKBOX-ABSENT does NOT read via gh (no silent GitHub fallback)" \
  "TRIPWIRE_GH_CALLED" "$mic_absent"
[ "$mic_rc" -ne 0 ] && echo -e "  ${GREEN}PASS${NC}: TC-B1-CHECKBOX-ABSENT non-zero exit (rc=$mic_rc)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-B1-CHECKBOX-ABSENT expected non-zero exit, got rc=$mic_rc"; FAIL=$((FAIL+1)); }
assert_not_contains "TC-B1-CHECKBOX-ABSENT does NOT PATCH via gh (no silent GitHub fallback)" \
  "TRIPWIRE_GH_PATCH_CALLED" "$mic_absent"
rm -rf "$_MIC_ISO"

# (2) setup-labels.sh — copy ALONE (no provider lib beside it). itp_provision_states
#     / itp_caps stay UNDEFINED → must fail loud with "itp_provision_states not
#     available" and never call `gh label`.
_SL_ISO="$(mktemp -d)"
cp "$SCRIPTS/setup-labels.sh" "$_SL_ISO/setup-labels.sh"
sl_absent=$(
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u AUTONOMOUS_PROVIDERS_DIR \
      -u ISSUE_PROVIDER PATH="$_TRIPWIRE_DIR:$PATH" \
  bash -c 'unset -f gh; bash "$1" "$2"' _ "$_SL_ISO/setup-labels.sh" o/r 2>&1
); sl_rc=$?
assert_contains "TC-B1-PROVISION-ABSENT fails loud naming itp_provision_states when provider lib absent" \
  "itp_provision_states not available" "$sl_absent"
[ "$sl_rc" -ne 0 ] && echo -e "  ${GREEN}PASS${NC}: TC-B1-PROVISION-ABSENT non-zero exit (rc=$sl_rc)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-B1-PROVISION-ABSENT expected non-zero exit, got rc=$sl_rc"; FAIL=$((FAIL+1)); }
assert_not_contains "TC-B1-PROVISION-ABSENT does NOT call gh label (no silent GitHub fallback)" \
  "TRIPWIRE_GH_CALLED" "$sl_absent"
rm -rf "$_SL_ISO"

# (3) HAPPY PATH still routes through the verb when the shim IS defined (github).
#     mark-issue-checkbox.sh resolves the real provider lib from its skill-tree
#     location; the recording gh stub (section 1) is restored so the PATCH leaf
#     fires through itp_github_mark_checkbox. Asserts the deletion did not break the
#     verb-routed write.
_HP_FILE="$(mktemp)"
hp_out=$(
  env -u PROJECT_DIR -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github REPO=o/r \
      _HP_FILE="$_HP_FILE" \
  bash -c '
    set -uo pipefail
    # Read arm matches the migrated body-read shape (gh issue view … --json body,
    # #296); every other call (the PATCH) is recorded as an HP_GH line so the
    # verb-routed write can be asserted.
    gh() {
      if [[ "$1" == "issue" && "$2" == "view" ]]; then printf "## Requirements\n- [ ] Do the thing\n"; return 0; fi
      printf "HP_GH %s\n" "$*" >> "$_HP_FILE"; return 0
    }
    export -f gh
    bash "$1" "$2" "$3"
  ' _ "$COMMON_SCRIPTS/mark-issue-checkbox.sh" 1 "Do the thing" 2>&1
); hp_rc=$?
hp_gh="$(cat "$_HP_FILE")"; rm -f "$_HP_FILE"
[ "$hp_rc" -eq 0 ] && echo -e "  ${GREEN}PASS${NC}: TC-B1-CHECKBOX-HAPPY shim defined → exit 0 (verb-routed write)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-B1-CHECKBOX-HAPPY expected exit 0, got rc=$hp_rc (out: ${hp_out:0:200})"; FAIL=$((FAIL+1)); }
assert_contains "TC-B1-CHECKBOX-HAPPY happy path PATCHes via the github verb leaf" \
  "HP_GH api repos/o/r/issues/1 --method PATCH" "$hp_gh"

rm -rf "$_TRIPWIRE_DIR"

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
# comment. Pins ZERO raw `gh issue comment` across all SIX ITP-issue-comment files.
# (`gh pr comment` / review-thread replies are CHP, NOT counted — owned by
# chp-pr-lifecycle.) NOTE: the cutover LINT (a CI guard that fails on raw-gh) is the
# separate cutover-guard-lint deliverable; this is the migration-completeness pin.
# post-verdict.sh's fallback legitimately uses the `"$GH"` proxy variable, NOT a raw
# `gh issue comment "` token, so it too pins to 0 here (its routing through
# itp_post_comment is asserted by TC-POSTVERDICT-* above).
for _f in "$LIB" \
          "$SCRIPTS/autonomous-dev.sh" \
          "$SCRIPTS/autonomous-review.sh" \
          "$SCRIPTS/dispatcher-tick.sh" \
          "$SCRIPTS/lib-review-verdict.sh" \
          "$SCRIPTS/post-verdict.sh"; do
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

# post-verdict.sh: the INV-78 fallback verdict comment is a machine marker and must
# route through itp_post_comment (review [P1] r5), NOT a bare `$GH issue comment`.
_pv_src="$(cat "$SCRIPTS/post-verdict.sh")"
assert_contains "TC-POSTVERDICT-DELEGATE post-verdict.sh routes the verdict through itp_post_comment" \
  "itp_post_comment" "$_pv_src"

echo "=== POST-VERDICT INV-78 fallback routes via itp_post_comment + preserves INV-56 proxy ==="
# Drive the REAL post-verdict.sh with the seam available. A sandbox holds the proxy
# `gh` at $SB/gh (records argv+body) AND a copy of lib-issue-provider.sh + the github
# provider so the script's readlink-f seam-source resolves and itp_post_comment is
# defined. The post must (a) reach the proxy gh (INV-56 identity) with (b) byte-
# identical `issue comment <n> --repo <repo> --body <composed>` argv carrying the
# verdict trailer (INV-40/INV-20), routed through the verb (INV-89).
_PVSB="$(mktemp -d)"
cp "$SCRIPTS/post-verdict.sh" "$_PVSB/post-verdict.sh"
cp "$SCRIPTS/lib-issue-provider.sh" "$_PVSB/lib-issue-provider.sh"
mkdir -p "$_PVSB/providers"
cp "$PROVIDERS/itp-github.sh" "$PROVIDERS/itp-github.caps" "$_PVSB/providers/"
[[ -f "$SCRIPTS/lib-config.sh" ]] && cp "$SCRIPTS/lib-config.sh" "$_PVSB/lib-config.sh"
printf 'REPO="o/r"\n' > "$_PVSB/autonomous.conf"
cat > "$_PVSB/gh" <<'PVGH'
#!/bin/bash
printf '%s\n' "$@" > "$PVSB_ARGV"
_b=""; _prev=""
for _a in "$@"; do [[ "$_prev" == "--body" ]] && _b="$_a"; _prev="$_a"; done
printf '%s' "$_b" > "$PVSB_BODY"
echo "https://github.com/o/r/issues/202#issuecomment-1"
PVGH
chmod +x "$_PVSB/gh"
printf 'PASS body line' > "$_PVSB/body.md"
pv_out=$(
  env -u PROJECT_DIR PVSB_ARGV="$_PVSB/argv.txt" PVSB_BODY="$_PVSB/body.txt" \
  bash -c 'unset -f gh; bash "$1" 202 pass "$2" codex sid-AAAA sonnet' _ \
    "$_PVSB/post-verdict.sh" "$_PVSB/body.md" 2>&1
)
pv_argv="$(cat "$_PVSB/argv.txt" 2>/dev/null | paste -sd' ')"
pv_body="$(cat "$_PVSB/body.txt" 2>/dev/null)"
assert_contains "TC-POSTVERDICT-PROXY post reaches the INV-56 proxy gh with issue-comment argv" \
  "issue comment 202 --repo o/r --body" "$pv_argv"
assert_contains "TC-POSTVERDICT-BODY composed body carries the Review Session trailer (INV-20)" \
  "Review Session: \`sid-AAAA\`" "$pv_body"
assert_contains "TC-POSTVERDICT-BODY composed body carries the Review Agent trailer (INV-40/INV-60)" \
  "Review Agent: codex (model: sonnet)" "$pv_body"
assert_contains "TC-POSTVERDICT-URL helper echoes the comment URL on success" \
  "issuecomment-1" "$pv_out"
rm -rf "$_PVSB"

rm -f "$_GH_ARGV_FILE" "$_GH_CALL_LOG"

# ===========================================================================
# 7. BEHAVIOR-EQUIVALENCE (#296 mark-checkbox body-read migration). Run the REAL
#    mark-issue-checkbox.sh as a SUBPROCESS with a binary `gh` stub on PATH (NOT by
#    calling itp_read_task directly) so the test exercises seam-sourcing + the
#    `|| { … }` handler + the retry path end-to-end. The migration is shape-
#    equivalent: the old `gh api repos/$REPO/issues/$N --jq .body` read became
#    `itp_read_task <N> body -q .body` → `gh issue view <N> --repo <REPO> --json
#    body -q .body`. The returned body STRING is identical, so the SAME body is
#    marked and the SAME error handling fires.
#
#    Sandbox trick (conf isolation + seam resolution): the script is invoked via a
#    SYMLINK in a temp dir. `$0`/SCRIPT_DIR is the symlink dir (so the conf-lookup
#    finds NO autonomous.conf → the env REPO=o/r survives, no contamination from an
#    operator-local conf), while `readlink -f "$BASH_SOURCE"` resolves to the REAL
#    skill-tree file so the provider seam still sources and itp_read_task is defined.
# ===========================================================================
echo "=== BEHAVIOR-EQUIVALENCE: mark-issue-checkbox.sh body-read via itp_read_task (#296) ==="
_BE_SANDBOX="$(mktemp -d)"
ln -s "$COMMON_SCRIPTS/mark-issue-checkbox.sh" "$_BE_SANDBOX/mark-issue-checkbox.sh"

# (a) HAPPY + same body + (b) the READ uses the migrated `gh issue view --json body`
#     shape (NOT `gh api … --jq`). The binary gh stub records its READ argv and the
#     PATCHed body; assert the PATCH carries the marked body and the READ shape.
_BE_READ_ARGV="$(mktemp)"; _BE_PATCH_BODY="$(mktemp)"
cat > "$_BE_SANDBOX/gh" <<GHEOF
#!/bin/bash
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
  printf '%s\n' "\$@" > "$_BE_READ_ARGV"
  printf '## Requirements\n- [ ] Do the thing\n'
  exit 0
fi
# PATCH write: capture the --field body=… value.
_prev=""
for _a in "\$@"; do
  case "\$_prev" in --field) printf '%s' "\${_a#body=}" > "$_BE_PATCH_BODY" ;; esac
  _prev="\$_a"
done
exit 0
GHEOF
chmod +x "$_BE_SANDBOX/gh"
be_happy=$(
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u AUTONOMOUS_PROVIDERS_DIR \
      ISSUE_PROVIDER=github REPO=o/r PATH="$_BE_SANDBOX:$PATH" \
  bash -c 'unset -f gh; bash "$1" "$2" "$3"' _ "$_BE_SANDBOX/mark-issue-checkbox.sh" 1 "Do the thing" 2>&1
); be_happy_rc=$?
be_read_argv="$(paste -sd' ' "$_BE_READ_ARGV")"
be_patch_body="$(cat "$_BE_PATCH_BODY")"
[ "$be_happy_rc" -eq 0 ] && echo -e "  ${GREEN}PASS${NC}: TC-MCB-EQUIV-HAPPY script exits 0" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-MCB-EQUIV-HAPPY expected exit 0, got rc=$be_happy_rc (out: ${be_happy:0:200})"; FAIL=$((FAIL+1)); }
assert_contains "TC-MCB-EQUIV-HAPPY the same body is marked (- [x] Do the thing in the PATCHed body)" \
  "- [x] Do the thing" "$be_patch_body"
assert_eq "TC-MCB-EQUIV-READSHAPE read uses the migrated gh issue view --json body shape" \
  "issue view 1 --repo o/r --json body -q .body" "$be_read_argv"

# (c) ERROR — the body READ fails (gh issue view exits non-zero); the `|| { … }`
#     handler must fire identically (Error: Failed to fetch …), non-zero exit, no PATCH.
_BE_ERR_PATCH="$(mktemp)"
cat > "$_BE_SANDBOX/gh" <<GHEOF
#!/bin/bash
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then echo "gh: read failed" >&2; exit 1; fi
echo "BE_ERR_PATCH_CALLED \$*" >> "$_BE_ERR_PATCH"
exit 0
GHEOF
chmod +x "$_BE_SANDBOX/gh"
be_err=$(
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u AUTONOMOUS_PROVIDERS_DIR \
      ISSUE_PROVIDER=github REPO=o/r PATH="$_BE_SANDBOX:$PATH" \
  bash -c 'unset -f gh; bash "$1" "$2" "$3"' _ "$_BE_SANDBOX/mark-issue-checkbox.sh" 1 "Do the thing" 2>&1
); be_err_rc=$?
assert_contains "TC-MCB-EQUIV-ERROR the || { … } handler fires on a read error" \
  "Error: Failed to fetch issue #1" "$be_err"
[ "$be_err_rc" -ne 0 ] && echo -e "  ${GREEN}PASS${NC}: TC-MCB-EQUIV-ERROR non-zero exit on read error (rc=$be_err_rc)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-MCB-EQUIV-ERROR expected non-zero exit, got rc=$be_err_rc"; FAIL=$((FAIL+1)); }
assert_not_contains "TC-MCB-EQUIV-ERROR no PATCH after a read failure" \
  "BE_ERR_PATCH_CALLED" "$(cat "$_BE_ERR_PATCH")"

# (d) REPO-FALLBACK — self-repo, no autonomous.conf, REPO/GITHUB_REPO unset → REPO
#     resolves to the placeholder owner/repo; the read against it fails so the
#     script exits non-zero (the same exit-1-when-REPO-unresolvable behavior as
#     before the migration — the swap of the read primitive did NOT alter it). The
#     stub records the read's --repo arg so we can prove REPO actually fell back to
#     the placeholder (not merely that the read failed).
_BE_REPO_ARG="$(mktemp)"
cat > "$_BE_SANDBOX/gh" <<GHEOF
#!/bin/bash
# A placeholder-repo read fails (as a real gh would 404 on owner/repo). Record the
# --repo value so the test asserts REPO resolution fell back to owner/repo.
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
  _prev=""; for _a in "\$@"; do [[ "\$_prev" == "--repo" ]] && printf '%s' "\$_a" > "$_BE_REPO_ARG"; _prev="\$_a"; done
  echo "gh: Could not resolve to a Repository" >&2; exit 1
fi
exit 0
GHEOF
chmod +x "$_BE_SANDBOX/gh"
be_repo=$(
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u AUTONOMOUS_PROVIDERS_DIR \
      -u REPO -u GITHUB_REPO ISSUE_PROVIDER=github PATH="$_BE_SANDBOX:$PATH" \
  bash -c 'unset -f gh; bash "$1" "$2" "$3"' _ "$_BE_SANDBOX/mark-issue-checkbox.sh" 1 "Do the thing" 2>&1
); be_repo_rc=$?
[ "$be_repo_rc" -ne 0 ] && echo -e "  ${GREEN}PASS${NC}: TC-MCB-REPO-FALLBACK exits non-zero when REPO is unresolvable (preserved)" && PASS=$((PASS+1)) \
  || { echo -e "  ${RED}FAIL${NC}: TC-MCB-REPO-FALLBACK expected non-zero exit, got rc=$be_repo_rc (out: ${be_repo:0:200})"; FAIL=$((FAIL+1)); }
assert_eq "TC-MCB-REPO-FALLBACK REPO resolved to the placeholder owner/repo (fallback path intact, not conf-overridden)" \
  "owner/repo" "$(cat "$_BE_REPO_ARG")"

rm -f "$_BE_READ_ARGV" "$_BE_PATCH_BODY" "$_BE_ERR_PATCH" "$_BE_REPO_ARG"
rm -rf "$_BE_SANDBOX"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
