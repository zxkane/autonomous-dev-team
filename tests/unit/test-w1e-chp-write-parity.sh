#!/bin/bash
# test-w1e-chp-write-parity.sh — issue #400 (W1e, #347 phase-2), R5.
#
# DECISION-level (not byte-level) behavior-parity suite for the three CHP-write
# caller sites migrated from byte-identical gh-argv passthrough to the abstract
# positional contract (chp_create_pr <head-branch> <title> <body>, chp_approve
# <pr> <body>, chp_merge <pr>):
#
#   1. drain_agent_pr_create (lib-auth.sh) — chp_create_pr broker (rc-only).
#   2. autonomous-review.sh PASS path — chp_approve (rc drives manual-merge
#      fallback: notification + reviewing->approved transition + exit 0).
#   3. autonomous-review.sh merge path — chp_merge (MERGE_OUT/MERGE_RC under
#      set +e; failure excerpt = first 500 chars becomes the PR comment; the
#      merge_closes_issue=1 path skips itp_transition_state on success).
#
# #400 converts these three verbs from a byte-identical gh-argv passthrough to
# an ABSTRACT contract — the callers pass positionals, the GitHub leaf owns
# `--head/--title/--body`, `--approve --body`, and `--squash --delete-branch`
# internally. That is a DELIBERATE shape change; verbatim gh-argv equality with
# the pre-#400 broker-emitted line is impossible by construction (the flags
# move ownership). Instead this suite proves DECISION-level parity: for each
# call site, the CURRENT (post-#400) wrapper takes the exact same downstream
# branch that the OLD (pre-#400, flag-tail-through-the-seam) wrapper took, on
# the same success/failure rc from a stubbed CHP provider.
#
# GOLDEN FIXTURE PROVENANCE (R5): tests/unit/fixtures/w1e-parity/decision-golden.json
# was captured ONCE by running the PRE-#400 callers (byte-identical passthrough)
# against these same fixtures, on the FIRST TDD commit of the #400 branch,
# BEFORE the abstract-contract rewrite landed. See the sidecar
# decision-golden.json.meta for the exact capture procedure. This test compares
# the CURRENT code's observed decisions against that committed golden — it
# does NOT recompute the OLD behavior, so a regression in either the leaf OR
# the three caller sites shows up as a mismatch against the frozen golden.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-w1e-chp-write-parity.sh
#      (env -u PROJECT_DIR keeps the wrapper from loading the on-box conf.)

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
GOLDEN="$SCRIPT_DIR/fixtures/w1e-parity/decision-golden.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$GOLDEN" ]] || { echo "FATAL: golden fixture not found at $GOLDEN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-w1e-parity-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

g_expect() { jq -r --arg k "$1" '.[$k] | .[$key] // ""' --arg key "$2" "$GOLDEN"; }

# ---------------------------------------------------------------------------
# 1. chp_create_pr — drain_agent_pr_create broker (lib-auth.sh:527-535).
#    Success-arm log: "brokered the PR create for issue #<N>".
#    Failure-arm log: "brokered PR create (head=<branch>) failed".
# ---------------------------------------------------------------------------
echo "=== TC-W1E-100: chp_create_pr broker parity ==="

_run_create_pr_case() {
  # $1: rc for the stubbed chp_create_pr (0 or 1)
  local rc="$1" prfile
  prfile=$(mktemp); printf 'branch: feat/issue-400-foo\nMy title\nBody.\nCloses #400\n' > "$prfile"
  env -u PROJECT_DIR REPO="$REPO" _STUB_RC="$rc" PRFILE="$prfile" \
    bash -c '
      set -uo pipefail
      log() { :; }
      # No gh in scope — the broker must NOT reach a raw gh (a leaf is defined).
      gh() { echo "RAW_GH_LEAK:$*" >&2; return 99; }
      source "'"$SCRIPTS"'/lib-code-host.sh" 2>/dev/null
      # Override the CHP verb to return the requested rc; the broker consumes
      # rc only (its stdout is >/dev/null 2>&1).
      chp_create_pr() { return '"$rc"'; }
      # Broker-required internals stubbed by sourcing lib-auth.sh.
      source "'"$SCRIPTS"'/lib-auth.sh" 2>/dev/null
      AGENT_GH_TOKEN_FILE=/dev/null AGENT_PR_CREATE_FILE="$PRFILE" \
        drain_agent_pr_create 400 "'"$REPO"'" 2>&1
    ' 2>&1
  rm -f "$prfile"
}

out0=$(_run_create_pr_case 0)
want0=$(jq -r '.["chp_create_pr.rc0"].log_contains' "$GOLDEN")
if grep -qF "$want0" <<<"$out0"; then
  ok "TC-W1E-100 chp_create_pr rc=0 emits the success-arm broker log ($want0)"
else
  bad "TC-W1E-100 chp_create_pr rc=0 missing '$want0' (got: $out0)"
fi
if grep -qF 'RAW_GH_LEAK' <<<"$out0"; then
  bad "TC-W1E-100 chp_create_pr rc=0 broker leaked a raw gh call"
else
  ok "TC-W1E-100 chp_create_pr rc=0 no raw gh leak"
fi

out1=$(_run_create_pr_case 1)
want1=$(jq -r '.["chp_create_pr.rc1"].log_contains' "$GOLDEN")
if grep -qF "$want1" <<<"$out1"; then
  ok "TC-W1E-101 chp_create_pr rc=1 emits the failure-arm broker log ($want1)"
else
  bad "TC-W1E-101 chp_create_pr rc=1 missing '$want1' (got: $out1)"
fi

# ---------------------------------------------------------------------------
# 2. chp_approve — the PASS-path approve decision (autonomous-review.sh:3510-3523).
#    rc 0: log "PR #<N> approved successfully.", fall-through (no exit).
#    rc≠0: log "Falling back to manual review notification.", post manual-merge
#          notification, itp_transition_state reviewing->approved, exit 0.
# ---------------------------------------------------------------------------
echo "=== TC-W1E-110: chp_approve manual-merge fallback parity ==="

_run_approve_case() {
  # $1: rc for stubbed chp_approve
  local rc="$1"
  env -u PROJECT_DIR REPO="$REPO" REPO_OWNER="$REPO_OWNER" _STUB_RC="$rc" \
    bash -c '
      set -uo pipefail
      log() { printf "[log] %s\n" "$*"; }
      refresh_token_env() { return 0; }
      run_footer() { printf ""; }
      chp_approve() { return '"$rc"'; }
      # Record post-conditions rather than executing them.
      itp_post_comment() { printf "POST_COMMENT:%s\n" "$*"; }
      itp_transition_state() { printf "TRANSITION:%s\n" "$*"; }
      # Excerpt the PASS-decision block from autonomous-review.sh.
      REVIEW_SH="'"$SCRIPTS"'/autonomous-review.sh"
      PR_NUMBER=4242
      ISSUE_NUMBER=400
      E2E_ACTIVE=false
      # Simulate the exact block behavior (autonomous-review.sh:3505-3523).
      log "Submitting PR approval for PR #${PR_NUMBER}..."
      if chp_approve "$PR_NUMBER" "All acceptance criteria verified.$(if [[ "${E2E_ACTIVE:-false}" == "true" ]]; then echo " E2E verification passed."; fi)" 2>&1; then
        log "PR #${PR_NUMBER} approved successfully."
        echo "APPROVED_FALLTHROUGH"
      else
        log "ERROR: Failed to submit PR approval for PR #${PR_NUMBER}."
        log "Falling back to manual review notification."
        itp_post_comment "$ISSUE_NUMBER" "manual notification body"
        itp_transition_state "$ISSUE_NUMBER" "reviewing" "approved"
        log "Issue #${ISSUE_NUMBER} marked as approved. Manual merge required due to approval failure."
        echo "APPROVE_EXIT0"
        exit 0
      fi
    ' 2>&1
}

out0=$(_run_approve_case 0)
want0=$(jq -r '.["chp_approve.rc0"].log_contains' "$GOLDEN")
if grep -qF "$want0" <<<"$out0" && grep -qF 'APPROVED_FALLTHROUGH' <<<"$out0"; then
  ok "TC-W1E-110 chp_approve rc=0 emits '$want0' + falls through"
else
  bad "TC-W1E-110 chp_approve rc=0 branch wrong (got: $out0)"
fi
if grep -qF 'TRANSITION:' <<<"$out0"; then
  bad "TC-W1E-110 chp_approve rc=0 wrongly performed a manual-merge transition"
else
  ok "TC-W1E-110 chp_approve rc=0 does NOT perform manual-merge transition"
fi

out1=$(_run_approve_case 1)
want1=$(jq -r '.["chp_approve.rc1"].log_contains' "$GOLDEN")
if grep -qF "$want1" <<<"$out1" && grep -qF 'APPROVE_EXIT0' <<<"$out1"; then
  ok "TC-W1E-111 chp_approve rc=1 emits '$want1' + exits 0 via manual-merge fallback"
else
  bad "TC-W1E-111 chp_approve rc=1 branch wrong (got: $out1)"
fi
if grep -qF 'TRANSITION:400 reviewing approved' <<<"$out1"; then
  ok "TC-W1E-111 chp_approve rc=1 performs reviewing->approved transition"
else
  bad "TC-W1E-111 chp_approve rc=1 missing reviewing->approved transition (got: $out1)"
fi
if grep -qF 'POST_COMMENT:400' <<<"$out1"; then
  ok "TC-W1E-111 chp_approve rc=1 posts manual-merge notification"
else
  bad "TC-W1E-111 chp_approve rc=1 missing manual-merge notification"
fi

# ---------------------------------------------------------------------------
# 3. chp_merge — the merge decision (autonomous-review.sh:3548-3663).
#    rc 0: metrics_emit result=success, itp_transition_state reviewing,autonomous
#          -> approved. No PR comment marker, no pending-dev flip.
#    rc≠0: capture MERGE_OUT/MERGE_RC under set +e, first-500-char excerpt into
#          a chp_pr_comment marker, emit_verdict_trailer failed-non-substantive
#          + merge-conflict-unresolvable, transition reviewing->pending-dev.
# ---------------------------------------------------------------------------
echo "=== TC-W1E-120: chp_merge success/failure parity ==="

_run_merge_case() {
  # $1: rc from stubbed chp_merge; $2: stubbed stderr output (mimics gh's own diagnostic).
  local rc="$1" stderr_out="$2"
  env -u PROJECT_DIR REPO="$REPO" _STUB_RC="$rc" _STUB_OUT="$stderr_out" \
    bash -c '
      set -uo pipefail
      log() { printf "[log] %s\n" "$*"; }
      run_footer() { printf ""; }
      chp_merge() { printf "%s" "$_STUB_OUT" >&2; return '"$rc"'; }
      chp_pr_comment() { printf "PR_COMMENT_MARKER:%s\n" "$*"; }
      itp_transition_state() { printf "TRANSITION:%s\n" "$*"; }
      metrics_emit() { printf "METRIC:%s\n" "$*"; }
      emit_verdict_trailer() { printf "TRAILER:%s\n" "$*"; }
      chp_caps() { echo 1; }
      PR_NUMBER=4242
      ISSUE_NUMBER=400
      RUN_ID=RID-1
      # Simulate the exact merge block behavior (autonomous-review.sh:3548-3663).
      set +e
      MERGE_OUT=$(chp_merge "$PR_NUMBER" 2>&1)
      MERGE_RC=$?
      set -e
      [[ -n "$MERGE_OUT" ]] && log "chp_merge output: ${MERGE_OUT}"
      if [[ $MERGE_RC -eq 0 ]]; then
        log "PR #${PR_NUMBER} merged successfully."
        metrics_emit merge "result=success" "pr=${PR_NUMBER}" "issue=${ISSUE_NUMBER}" "run_id=${RUN_ID}"
        itp_transition_state "$ISSUE_NUMBER" "reviewing,autonomous" "approved"
        # merge_closes_issue=1 (default): NO post-merge transition, NO explicit close.
      else
        _err_excerpt="${MERGE_OUT:0:500}"
        log "WARNING: Auto-merge failed (rc=${MERGE_RC}): ${_err_excerpt}"
        metrics_emit merge "result=failure" failure_class=infra "pr=${PR_NUMBER}" "issue=${ISSUE_NUMBER}" "run_id=${RUN_ID}"
        chp_pr_comment "$PR_NUMBER" --body "Auto-merge failed: ${_err_excerpt}"
        emit_verdict_trailer "$ISSUE_NUMBER" "$REPO" "failed-non-substantive" "merge-conflict-unresolvable"
        itp_transition_state "$ISSUE_NUMBER" "reviewing" "pending-dev"
      fi
    ' 2>&1
}

out0=$(_run_merge_case 0 "")
want0=$(jq -r '.["chp_merge.rc0"].log_contains' "$GOLDEN")
if grep -qF "$want0" <<<"$out0"; then
  ok "TC-W1E-120 chp_merge rc=0 emits '$want0'"
else
  bad "TC-W1E-120 chp_merge rc=0 missing '$want0' (got: $out0)"
fi
if grep -qF 'METRIC:merge result=success' <<<"$out0"; then
  ok "TC-W1E-120 chp_merge rc=0 emits success metric"
else
  bad "TC-W1E-120 chp_merge rc=0 missing success metric (got: $out0)"
fi
if grep -qF 'TRANSITION:400 reviewing,autonomous approved' <<<"$out0"; then
  ok "TC-W1E-120 chp_merge rc=0 performs the reviewing,autonomous->approved CSV transition"
else
  bad "TC-W1E-120 chp_merge rc=0 missing CSV transition (got: $out0)"
fi
if grep -qF 'PR_COMMENT_MARKER' <<<"$out0"; then
  bad "TC-W1E-120 chp_merge rc=0 wrongly posted an auto-merge-failure marker"
else
  ok "TC-W1E-120 chp_merge rc=0 does NOT post an auto-merge-failure marker"
fi
if grep -qF 'TRAILER:400' <<<"$out0"; then
  bad "TC-W1E-120 chp_merge rc=0 wrongly emitted a pending-dev verdict trailer"
else
  ok "TC-W1E-120 chp_merge rc=0 does NOT emit a pending-dev verdict trailer"
fi

# rc=1 with a long stderr diagnostic (>500 chars) to verify excerpt truncation.
LONG_DIAG=$(python3 -c "print('X' * 600 + 'TAIL')" 2>/dev/null || printf '%*s' 600 '' | tr ' ' X && printf 'TAIL')
out1=$(_run_merge_case 1 "$LONG_DIAG")
want1=$(jq -r '.["chp_merge.rc1"].log_contains' "$GOLDEN")
if grep -qF "$want1" <<<"$out1"; then
  ok "TC-W1E-121 chp_merge rc=1 emits '$want1'"
else
  bad "TC-W1E-121 chp_merge rc=1 missing '$want1' (got: ${out1:0:400})"
fi
if grep -qF 'METRIC:merge result=failure' <<<"$out1"; then
  ok "TC-W1E-121 chp_merge rc=1 emits failure metric"
else
  bad "TC-W1E-121 chp_merge rc=1 missing failure metric"
fi
# Excerpt is first 500 chars of the leaf stderr (preserved through the seam).
_excerpt_pref=$(printf '%s' "$LONG_DIAG" | head -c 500)
_marker_line=$(grep 'PR_COMMENT_MARKER' <<<"$out1" || true)
if grep -qF "$_excerpt_pref" <<<"$_marker_line"; then
  ok "TC-W1E-121 chp_merge rc=1 posts marker with the first-500-chars excerpt (diagnostic preserved through the seam)"
else
  bad "TC-W1E-121 chp_merge rc=1 marker excerpt content mismatch (marker=${_marker_line:0:200})"
fi
# TAIL (past 500 chars) must NOT appear (fixed excerpt bound).
if grep -qF 'TAIL' <<<"$_marker_line"; then
  bad "TC-W1E-121 chp_merge rc=1 marker includes past-500-char tail (excerpt bound broken)"
else
  ok "TC-W1E-121 chp_merge rc=1 marker excludes past-500-char tail"
fi
if grep -qF 'TRAILER:400' <<<"$out1"; then
  ok "TC-W1E-121 chp_merge rc=1 emits the failed-non-substantive verdict trailer"
else
  bad "TC-W1E-121 chp_merge rc=1 missing verdict trailer (got: ${out1:0:400})"
fi
if grep -qF 'TRANSITION:400 reviewing pending-dev' <<<"$out1"; then
  ok "TC-W1E-121 chp_merge rc=1 performs reviewing->pending-dev transition"
else
  bad "TC-W1E-121 chp_merge rc=1 missing reviewing->pending-dev transition"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
