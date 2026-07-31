#!/bin/bash
# Hermetic wrapper and real-git integration for issue #540.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
HEAD_OLD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc"
  else
    bad "$desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" file="$3"
  if grep -Fq -- "$needle" "$file"; then
    ok "$desc"
  else
    bad "$desc"
    echo "      missing=[$needle]"
  fi
}

TMP=$(mktemp -d)
trap 'pkill -9 -f "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

WRAPPER_ROOT="$TMP/wrappers"
WRAPPER_SCRIPTS="$WRAPPER_ROOT/scripts"
PROVIDERS="$WRAPPER_ROOT/providers"
STATE="$WRAPPER_ROOT/provider-state"
BIN="$WRAPPER_ROOT/bin"
mkdir -p "$WRAPPER_SCRIPTS" "$PROVIDERS" "$STATE" "$BIN" \
  "$WRAPPER_ROOT/pids" "$WRAPPER_ROOT/lanes" "$WRAPPER_ROOT/runs" \
  "$WRAPPER_ROOT/accounting"
cp -a "$SCRIPTS/." "$WRAPPER_SCRIPTS/"
cp "$SCRIPTS/providers/chp-github.caps" "$PROVIDERS/chp-github.caps"
cp "$SCRIPTS/providers/itp-github.caps" "$PROVIDERS/itp-github.caps"

printf '%s\n' "$HEAD_OLD" >"$STATE/head"
printf '%s\n' CONFLICTING >"$STATE/mergeable"
printf '%s\n' reviewing >"$STATE/label"
: >"$STATE/comments.jsonl"
: >"$STATE/pr-comments.jsonl"
: >"$STATE/events"
: >"$STATE/transitions"
: >"$STATE/e2e-count"
: >"$STATE/agent-count"
: >"$STATE/dev-prompt"
: >"$STATE/git-actions"
: >"$STATE/human-needed"

cat >"$PROVIDERS/chp-github.sh" <<'EOF'
#!/bin/bash

_fixture_pr() {
  local head
  head=$(cat "$PREFLIGHT_FIXTURE_STATE/head")
  jq -cn --arg head "$head" '{
    number:42,
    state:"OPEN",
    title:"fixture",
    body:"Closes #540",
    createdAt:"2026-07-30T00:00:00Z",
    updatedAt:"2026-07-30T00:00:00Z",
    mergedAt:null,
    headRefName:"fix/issue-540-fixture",
    headRefOid:$head,
    reviewDecision:"",
    mergeable:"UNKNOWN",
    closingIssueNumbers:[540],
    comments:[],
    reviews:[]
  }'
}

chp_github_find_pr_for_issue() {
  [[ ! -e "$PREFLIGHT_FIXTURE_STATE/fail-find-pr" ]] || return 1
  jq -cn --argjson pr "$(_fixture_pr)" '[$pr]'
}
chp_github_pr_list() { jq -cn --argjson pr "$(_fixture_pr)" '[$pr]'; }

chp_github_pr_view() {
  local fields="${2:-}" head
  head=$(cat "$PREFLIGHT_FIXTURE_STATE/head")
  case "$fields" in
    state,headRefOid,headRefName)
      jq -cn --arg head "$head" \
        '{state:"OPEN",headRefOid:$head,headRefName:"fix/issue-540-fixture"}'
      ;;
    comments)
      [[ ! -e "$PREFLIGHT_FIXTURE_STATE/fail-pr-comments" ]] || return 1
      if [[ -s "$PREFLIGHT_FIXTURE_STATE/pr-comments.jsonl" ]]; then
        jq -s '{comments:.}' "$PREFLIGHT_FIXTURE_STATE/pr-comments.jsonl"
      else
        printf '%s\n' '{"comments":[]}'
      fi
      ;;
    reviews) printf '%s\n' '{"reviews":[]}' ;;
    state) printf '%s\n' '{"state":"OPEN"}' ;;
    headRefOid) jq -cn --arg head "$head" '{headRefOid:$head}' ;;
    headRefName) printf '%s\n' '{"headRefName":"fix/issue-540-fixture"}' ;;
    *) _fixture_pr ;;
  esac
}

chp_github_mergeable() { cat "$PREFLIGHT_FIXTURE_STATE/mergeable"; }
chp_github_list_inline_comments() { printf '%s\n' '[]'; }
chp_github_pr_diffstat() { printf '%s\n' '{}'; }
chp_github_ci_status() { printf '%s\n' green; }
chp_github_ci_rollup() {
  local head
  head=$(cat "$PREFLIGHT_FIXTURE_STATE/head")
  jq -cn --arg head "$head" '{state:"SUCCESS",head:$head}'
}
chp_github_close_keyword() { printf '%s\n' Closes; }

chp_github_pr_comment() {
  local body=""
  shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body" ]]; then body="$2"; break; fi
    shift
  done
  printf 'pr-marker\n' >>"$PREFLIGHT_FIXTURE_STATE/events"
  [[ ! -e "$PREFLIGHT_FIXTURE_STATE/fail-pr-marker" ]] || return 1
  jq -cn --arg body "$body" \
    '{id:1,author:"review-app[bot]",body:$body,createdAt:"2026-07-30T00:00:03Z"}' \
    >>"$PREFLIGHT_FIXTURE_STATE/pr-comments.jsonl"
}

chp_github_request_changes() {
  printf 'request-changes\n' >>"$PREFLIGHT_FIXTURE_STATE/events"
}
chp_github_approve() { printf 'approve\n' >>"$PREFLIGHT_FIXTURE_STATE/events"; }
chp_github_merge() { printf 'merge\n' >>"$PREFLIGHT_FIXTURE_STATE/events"; }
chp_github_trigger_bot() { return 0; }
EOF

cat >"$PROVIDERS/itp-github.sh" <<'EOF'
#!/bin/bash

itp_github_list_comments() {
  if [[ -s "$PREFLIGHT_FIXTURE_STATE/comments.jsonl" ]]; then
    jq -s '.' "$PREFLIGHT_FIXTURE_STATE/comments.jsonl"
  else
    printf '%s\n' '[]'
  fi
}

itp_github_post_comment() {
  local body="$2" id kind="issue-comment"
  id=$(( $(wc -l <"$PREFLIGHT_FIXTURE_STATE/comments.jsonl") + 1 ))
  case "$body" in
    "<!-- review-disposition:"*) kind="disposition" ;;
    "Reviewed HEAD:"*) kind="reviewed-head" ;;
    "Review findings:"*) kind="finding" ;;
    "<!-- review-verdict:"*) kind="verdict" ;;
  esac
  printf '%s\n' "$kind" >>"$PREFLIGHT_FIXTURE_STATE/events"
  [[ ! -e "$PREFLIGHT_FIXTURE_STATE/fail-$kind" ]] || return 1
  jq -cn --argjson id "$id" --arg body "$body" \
    --arg ts "2026-07-30T00:00:$(printf '%02d' "$id")Z" \
    '{id:$id,author:"review-app[bot]",authorKind:"self",body:$body,createdAt:$ts}' \
    >>"$PREFLIGHT_FIXTURE_STATE/comments.jsonl"
}

itp_github_read_task() {
  local label
  label=$(cat "$PREFLIGHT_FIXTURE_STATE/label")
  jq -cn --arg label "$label" '{
    title:"fixture issue",
    body:"## Requirements\n- [ ] fixture",
    state:"OPEN",
    labels:[$label],
    comments:[],
    author:"fixture-owner"
  }'
}

itp_github_transition_state() {
  if [[ -e "$PREFLIGHT_FIXTURE_STATE/fail-transition-once" ]]; then
    rm -f "$PREFLIGHT_FIXTURE_STATE/fail-transition-once"
    printf 'transition-failed:%s>%s\n' "$2" "$3" \
      >>"$PREFLIGHT_FIXTURE_STATE/events"
    return 1
  fi
  printf '%s|%s|%s\n' "$1" "$2" "$3" \
    >>"$PREFLIGHT_FIXTURE_STATE/transitions"
  printf 'transition:%s>%s\n' "$2" "$3" >>"$PREFLIGHT_FIXTURE_STATE/events"
  [[ -z "$3" ]] || printf '%s\n' "$3" >"$PREFLIGHT_FIXTURE_STATE/label"
}

itp_github_mark_checkbox() { return 0; }
itp_github_edit_comment() { return 0; }
itp_github_provision_states() { return 0; }
itp_github_begin_tick() { return 0; }
itp_github_label_event_ts() { return 0; }
EOF

cat >"$BIN/gh" <<'EOF'
#!/bin/bash
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "api user") printf '%s\n' '{"login":"fixture-user"}'; exit 0 ;;
esac
exit 0
EOF

cat >"$BIN/claude" <<'EOF'
#!/bin/bash
printf 'agent\n' >>"$PREFLIGHT_FIXTURE_STATE/agent-count"
cat >"$PREFLIGHT_FIXTURE_STATE/dev-prompt"
case "${PREFLIGHT_DEV_SCENARIO:-}" in
  success)
    printf '%s\n' "fetch origin main" >>"$PREFLIGHT_FIXTURE_STATE/git-actions"
    git -C "$PREFLIGHT_DEV_WORKTREE" fetch -q origin main || exit 1
    printf '%s\n' "rebase origin/main" >>"$PREFLIGHT_FIXTURE_STATE/git-actions"
    git -C "$PREFLIGHT_DEV_WORKTREE" rebase origin/main >/dev/null || exit 1
    printf '%s\n' "push --force-with-lease origin fix/issue-540-fixture" \
      >>"$PREFLIGHT_FIXTURE_STATE/git-actions"
    git -C "$PREFLIGHT_DEV_WORKTREE" push -q --force-with-lease \
      origin fix/issue-540-fixture || exit 1
    git -C "$PREFLIGHT_DEV_WORKTREE" rev-parse HEAD \
      >"$PREFLIGHT_FIXTURE_STATE/head"
    ;;
  unsafe)
    printf '%s\n' "fetch origin main" >>"$PREFLIGHT_FIXTURE_STATE/git-actions"
    git -C "$PREFLIGHT_DEV_WORKTREE" fetch -q origin main || exit 1
    printf '%s\n' "rebase origin/main" >>"$PREFLIGHT_FIXTURE_STATE/git-actions"
    if git -C "$PREFLIGHT_DEV_WORKTREE" rebase origin/main >/dev/null 2>&1; then
      exit 1
    fi
    git -C "$PREFLIGHT_DEV_WORKTREE" diff --name-only --diff-filter=U \
      >"$PREFLIGHT_FIXTURE_STATE/human-needed"
    printf '%s\n' "rebase --abort" >>"$PREFLIGHT_FIXTURE_STATE/git-actions"
    git -C "$PREFLIGHT_DEV_WORKTREE" rebase --abort || exit 1
    ;;
esac
exit 0
EOF

chmod +x "$PROVIDERS/chp-github.sh" "$PROVIDERS/itp-github.sh" \
  "$BIN/gh" "$BIN/claude"

cat >"$WRAPPER_SCRIPTS/autonomous.conf" <<EOF
PROJECT_ID="issue-540-wrapper-$$"
REPO="example/autonomous-dev-team"
REPO_OWNER="example"
REPO_NAME="autonomous-dev-team"
PROJECT_DIR="$PROJECT_ROOT"
AGENT_CMD="claude"
AGENT_DEV_CMD="claude"
AGENT_REVIEW_CMD="claude"
AGENT_REVIEW_AGENTS="claude"
AGENT_DEV_MODEL=""
AGENT_REVIEW_MODEL=""
AGENT_TIMEOUT="20"
AGENT_REVIEW_TIMEOUT="20"
GH_AUTH_MODE="token"
REVIEW_BOTS=""
REVIEW_SMOKE_ENABLED="false"
CONF_PERMMODE_WARN="false"
E2E_MODE="command"
E2E_COMMAND="printf 'run\\n' >> '$STATE/e2e-count'; exit 1"
E2E_COMMAND_EVIDENCE_PARSER="printf unused"
E2E_COMMAND_TIMEOUT_SECONDS="10"
MERGEABLE_RETRIES="2"
MERGEABLE_RETRY_DELAY_SECONDS="0"
HEARTBEAT_INTERVAL_SECONDS="0"
AUTONOMOUS_PROVIDERS_DIR="$PROVIDERS"
AUTONOMOUS_RUN_DIR_BASE="$WRAPPER_ROOT/runs"
AUTONOMOUS_ACCOUNTING_DIR="$WRAPPER_ROOT/accounting"
AUTONOMOUS_PID_DIR="$WRAPPER_ROOT/pids"
ADT_STATE_ROOT="$WRAPPER_ROOT/lanes"
PREFLIGHT_FIXTURE_STATE="$STATE"
EOF

run_review_wrapper() {
  timeout 30 env \
    PATH="$BIN:$PATH" \
    GH_TOKEN="fixture-token" \
    PREFLIGHT_FIXTURE_STATE="$STATE" \
    AUTONOMOUS_CONF="$WRAPPER_SCRIPTS/autonomous.conf" \
    bash "$WRAPPER_SCRIPTS/autonomous-review.sh" --issue 540 \
    >"$STATE/review.out" 2>&1
}

echo "=== TC-E2E-REBASE-043: real review wrapper conflict preflight ==="
run_review_wrapper
assert_eq "TC-E2E-REBASE-043 wrapper handles stable conflict" "0" "$?"
assert_eq "TC-E2E-REBASE-043 conflicting HEAD runs zero E2E commands" \
  "0" "$(wc -l <"$STATE/e2e-count" | tr -d ' ')"
assert_eq "TC-E2E-REBASE-043 conflicting HEAD launches zero review agents" \
  "0" "$(wc -l <"$STATE/agent-count" | tr -d ' ')"
assert_eq "TC-E2E-REBASE-043 wrapper ends reviewing -> pending-dev" \
  "540|reviewing|pending-dev" "$(tail -n1 "$STATE/transitions")"
assert_contains "TC-E2E-REBASE-043 disposition persisted" \
  "<!-- review-disposition: issue=540 head=$HEAD_OLD phase=pre-fanout result=conflict-rebase -->" \
  "$STATE/comments.jsonl"
assert_contains "TC-E2E-REBASE-043 finding names base branch" \
  "[BLOCKING] Merge conflict with main" "$STATE/comments.jsonl"
assert_contains "TC-E2E-REBASE-043 PR marker is canonical" \
  "Auto-merge failed:" "$STATE/pr-comments.jsonl"
assert_contains "TC-E2E-REBASE-043 substantive verdict persisted" \
  "<!-- review-verdict: failed-substantive head=${HEAD_OLD} -->" \
  "$STATE/comments.jsonl"

required_trace=$(grep -E '^(finding|disposition|pr-marker|verdict|transition:reviewing>pending-dev)$' \
  "$STATE/events" | paste -sd, -)
assert_eq "TC-E2E-REBASE-043 all durable writes precede pending-dev" \
  "finding,disposition,pr-marker,verdict,transition:reviewing>pending-dev" \
  "$required_trace"

cp "$STATE/comments.jsonl" "$STATE/comments.success"
cp "$STATE/pr-comments.jsonl" "$STATE/pr-comments.success"

echo
echo "=== TC-E2E-REBASE-020..024/040: real wrapper required-write recovery ==="
for fault in finding disposition pr-marker verdict; do
  : >"$STATE/comments.jsonl"
  : >"$STATE/pr-comments.jsonl"
  : >"$STATE/events"
  : >"$STATE/transitions"
  : >"$STATE/e2e-count"
  : >"$STATE/agent-count"
  printf '%s\n' "$HEAD_OLD" >"$STATE/head"
  printf '%s\n' CONFLICTING >"$STATE/mergeable"
  printf '%s\n' reviewing >"$STATE/label"
  touch "$STATE/fail-$fault"

  run_review_wrapper
  assert_eq "TC-E2E-REBASE-020..022/040 $fault failure is handled" "0" "$?"
  assert_eq "TC-E2E-REBASE-020..022/040 $fault failure requeues pending-review" \
    "540|reviewing|pending-review" "$(tail -n1 "$STATE/transitions")"
  assert_eq "TC-E2E-REBASE-020..022/040 $fault failure creates no pending-dev transition" \
    "0" "$(grep -c 'reviewing|pending-dev' "$STATE/transitions" || true)"

  rm -f "$STATE/fail-$fault"
  printf '%s\n' reviewing >"$STATE/label"
  run_review_wrapper
  assert_eq "TC-E2E-REBASE-024 $fault retry succeeds" "0" "$?"
  assert_eq "TC-E2E-REBASE-024 $fault retry reaches pending-dev" \
    "540|reviewing|pending-dev" "$(tail -n1 "$STATE/transitions")"
  assert_eq "TC-E2E-REBASE-024 $fault retry keeps one conflict disposition" \
    "1" "$(grep -c 'review-disposition: issue=540 head=' "$STATE/comments.jsonl" || true)"
  assert_eq "TC-E2E-REBASE-024 $fault retry keeps one canonical PR marker" \
    "1" "$(grep -c 'auto-merge-conflict: issue=540 head=' "$STATE/pr-comments.jsonl" || true)"
done

echo
echo "=== TC-E2E-REBASE-059: transition retry preserves required-write idempotency ==="
for mergeability in CONFLICTING UNKNOWN; do
  : >"$STATE/comments.jsonl"
  : >"$STATE/pr-comments.jsonl"
  : >"$STATE/events"
  : >"$STATE/transitions"
  : >"$STATE/e2e-count"
  : >"$STATE/agent-count"
  printf '%s\n' "$HEAD_OLD" >"$STATE/head"
  printf '%s\n' "$mergeability" >"$STATE/mergeable"
  printf '%s\n' reviewing >"$STATE/label"
  touch "$STATE/fail-transition-once"

  run_review_wrapper
  assert_eq "TC-E2E-REBASE-059 $mergeability route surfaces the initial transition failure" \
    "1" "$?"
  assert_eq "TC-E2E-REBASE-059 $mergeability cleanup retries pending-dev once" \
    "540|reviewing|pending-dev" "$(cat "$STATE/transitions")"
  assert_eq "TC-E2E-REBASE-059 $mergeability cleanup does not duplicate the required verdict" \
    "1" "$(grep -c '<!-- review-verdict:' "$STATE/comments.jsonl" || true)"
done

# Restore the original successful conflict route for the dev-wrapper prompt.
cp "$STATE/comments.success" "$STATE/comments.jsonl"
cp "$STATE/pr-comments.success" "$STATE/pr-comments.jsonl"
printf '%s\n' "$HEAD_OLD" >"$STATE/head"
printf '%s\n' CONFLICTING >"$STATE/mergeable"

echo
echo "=== TC-E2E-REBASE-044: real dev-new wrapper receives mandatory rebase prompt ==="
printf '%s\n' pending-dev >"$STATE/label"
timeout 30 env \
  PATH="$BIN:$PATH" \
  GH_TOKEN="fixture-token" \
  PREFLIGHT_FIXTURE_STATE="$STATE" \
  AUTONOMOUS_CONF="$WRAPPER_SCRIPTS/autonomous.conf" \
  bash "$WRAPPER_SCRIPTS/autonomous-dev.sh" \
    --issue 540 --mode new \
    >"$STATE/dev.out" 2>&1
assert_eq "TC-E2E-REBASE-044 dev-new wrapper exits cleanly" "0" "$?"
assert_contains "TC-E2E-REBASE-044 prompt makes rebase the first step" \
  "Pre-implementation: rebase onto main" "$STATE/dev-prompt"
assert_contains "TC-E2E-REBASE-044 prompt requires force-with-lease" \
  "git push --force-with-lease" "$STATE/dev-prompt"
assert_contains "TC-E2E-REBASE-044 prompt requires abort on unsafe conflict" \
  "git rebase --abort" "$STATE/dev-prompt"
rebase_line=$(grep -n 'Pre-implementation: rebase onto main' "$STATE/dev-prompt" | head -1 | cut -d: -f1)
instructions_line=$(grep -n '^## Instructions' "$STATE/dev-prompt" | head -1 | cut -d: -f1)
if [[ "$rebase_line" =~ ^[0-9]+$ && "$instructions_line" =~ ^[0-9]+$ \
      && "$rebase_line" -lt "$instructions_line" ]]; then
  ok "TC-E2E-REBASE-044 rebase block precedes dev-new work"
else
  bad "TC-E2E-REBASE-044 rebase block precedes dev-new work"
fi

echo
echo "=== TC-E2E-REBASE-049: dev context reads fail closed ==="
: >"$STATE/dev-prompt"
touch "$STATE/fail-pr-comments"
timeout 30 env \
  PATH="$BIN:$PATH" \
  GH_TOKEN="fixture-token" \
  PREFLIGHT_FIXTURE_STATE="$STATE" \
  AUTONOMOUS_CONF="$WRAPPER_SCRIPTS/autonomous.conf" \
  bash "$WRAPPER_SCRIPTS/autonomous-dev.sh" \
    --issue 540 --mode new \
    >"$STATE/dev-read-failure.out" 2>&1
assert_eq "TC-E2E-REBASE-049 comment-read failure still launches guarded prompt" "0" "$?"
assert_contains "TC-E2E-REBASE-049 comment-read failure emits mandatory context recovery" \
  "Conflict routing context could not be verified" "$STATE/dev-prompt"
assert_contains "TC-E2E-REBASE-049 guarded prompt forbids ordinary implementation first" \
  "Do not begin implementation or review-finding work" "$STATE/dev-prompt"
rm -f "$STATE/fail-pr-comments"

: >"$STATE/dev-prompt"
touch "$STATE/fail-find-pr"
timeout 30 env \
  PATH="$BIN:$PATH" \
  GH_TOKEN="fixture-token" \
  PREFLIGHT_FIXTURE_STATE="$STATE" \
  AUTONOMOUS_CONF="$WRAPPER_SCRIPTS/autonomous.conf" \
  bash "$WRAPPER_SCRIPTS/autonomous-dev.sh" \
    --issue 540 --mode new \
    >"$STATE/dev-resolution-failure.out" 2>&1
assert_eq "TC-E2E-REBASE-049 PR-resolution failure still launches guarded prompt" "0" "$?"
assert_contains "TC-E2E-REBASE-049 PR-resolution failure emits mandatory context recovery" \
  "Conflict routing context could not be verified" "$STATE/dev-prompt"
rm -f "$STATE/fail-find-pr"

echo
echo "=== TC-E2E-REBASE-045: real dev wrapper performs successful rebase ==="
REMOTE_OK="$TMP/remote-ok.git"
SEED_OK="$TMP/seed-ok"
FEATURE_OK="$TMP/feature-ok"
git init --bare -q "$REMOTE_OK"
git init -q -b main "$SEED_OK"
git -C "$SEED_OK" config user.name fixture
git -C "$SEED_OK" config user.email fixture@example.com
printf '%s\n' base >"$SEED_OK/base.txt"
git -C "$SEED_OK" add base.txt
git -C "$SEED_OK" commit -qm base
git -C "$SEED_OK" remote add origin "$REMOTE_OK"
git -C "$SEED_OK" push -q -u origin main
git clone -q --branch main "$REMOTE_OK" "$FEATURE_OK"
git -C "$FEATURE_OK" config user.name fixture
git -C "$FEATURE_OK" config user.email fixture@example.com
git -C "$FEATURE_OK" checkout -qb fix/issue-540-fixture
printf '%s\n' feature >"$FEATURE_OK/feature.txt"
git -C "$FEATURE_OK" add feature.txt
git -C "$FEATURE_OK" commit -qm feature
git -C "$FEATURE_OK" push -q -u origin fix/issue-540-fixture
old_git_head=$(git -C "$FEATURE_OK" rev-parse HEAD)
printf '%s\n' advanced >"$SEED_OK/advanced.txt"
git -C "$SEED_OK" add advanced.txt
git -C "$SEED_OK" commit -qm advance-main
git -C "$SEED_OK" push -q origin main

: >"$STATE/pr-comments.jsonl"
: >"$STATE/git-actions"
success_marker="<!-- auto-merge-conflict: issue=540 head=${old_git_head} result=conflict-rebase -->"
jq -cn --arg body "Auto-merge failed: wrapper rebase fixture"$'\n'"${success_marker}" \
  '{id:1,author:"review-app[bot]",body:$body,createdAt:"2026-07-30T00:10:00Z"}' \
  >>"$STATE/pr-comments.jsonl"
printf '%s\n' "$old_git_head" >"$STATE/head"
printf '%s\n' pending-dev >"$STATE/label"
timeout 30 env \
  PATH="$BIN:$PATH" \
  GH_TOKEN="fixture-token" \
  PREFLIGHT_FIXTURE_STATE="$STATE" \
  PREFLIGHT_DEV_SCENARIO="success" \
  PREFLIGHT_DEV_WORKTREE="$FEATURE_OK" \
  AUTONOMOUS_CONF="$WRAPPER_SCRIPTS/autonomous.conf" \
  bash "$WRAPPER_SCRIPTS/autonomous-dev.sh" \
    --issue 540 --mode new \
    >"$STATE/dev-success.out" 2>&1
assert_eq "TC-E2E-REBASE-045 dev wrapper executes successful rebase agent" "0" "$?"
new_git_head=$(git -C "$FEATURE_OK" rev-parse HEAD)
remote_git_head=$(git --git-dir="$REMOTE_OK" rev-parse refs/heads/fix/issue-540-fixture)
if [[ "$new_git_head" != "$old_git_head" ]]; then
  ok "TC-E2E-REBASE-045 wrapper-driven rebase advances the feature HEAD"
else
  bad "TC-E2E-REBASE-045 wrapper-driven rebase advances the feature HEAD"
fi
assert_eq "TC-E2E-REBASE-045 force-with-lease updates the remote HEAD" \
  "$new_git_head" "$remote_git_head"
assert_contains "TC-E2E-REBASE-045 agent executes force-with-lease policy" \
  "push --force-with-lease origin fix/issue-540-fixture" "$STATE/git-actions"
assert_eq "TC-E2E-REBASE-045 provider observes wrapper-updated HEAD" \
  "$new_git_head" "$(<"$STATE/head")"

: >"$STATE/e2e-count"
printf '%s\n' MERGEABLE >"$STATE/mergeable"
printf '%s\n' reviewing >"$STATE/label"
agent_invocations_before_new_head=$(wc -l <"$STATE/agent-count" | tr -d ' ')
run_review_wrapper
assert_eq "TC-E2E-REBASE-045 clean rebased HEAD reaches the E2E lane" "0" "$?"
assert_eq "TC-E2E-REBASE-045 new HEAD runs E2E exactly once" \
  "1" "$(wc -l <"$STATE/e2e-count" | tr -d ' ')"
assert_eq "TC-E2E-REBASE-045 failed E2E still launches no review fan-out" \
  "$agent_invocations_before_new_head" \
  "$(wc -l <"$STATE/agent-count" | tr -d ' ')"
assert_contains "TC-E2E-REBASE-045 old disposition remains bound to old HEAD" \
  "head=$HEAD_OLD" "$STATE/comments.jsonl"

echo
echo "=== TC-E2E-REBASE-046: real dev wrapper aborts unsafe rebase ==="
REMOTE_BAD="$TMP/remote-bad.git"
SEED_BAD="$TMP/seed-bad"
FEATURE_BAD="$TMP/feature-bad"
git init --bare -q "$REMOTE_BAD"
git init -q -b main "$SEED_BAD"
git -C "$SEED_BAD" config user.name fixture
git -C "$SEED_BAD" config user.email fixture@example.com
printf '%s\n' original >"$SEED_BAD/shared.txt"
git -C "$SEED_BAD" add shared.txt
git -C "$SEED_BAD" commit -qm base
git -C "$SEED_BAD" remote add origin "$REMOTE_BAD"
git -C "$SEED_BAD" push -q -u origin main
git clone -q --branch main "$REMOTE_BAD" "$FEATURE_BAD"
git -C "$FEATURE_BAD" config user.name fixture
git -C "$FEATURE_BAD" config user.email fixture@example.com
git -C "$FEATURE_BAD" checkout -qb fix/issue-540-conflict
printf '%s\n' feature-change >"$FEATURE_BAD/shared.txt"
git -C "$FEATURE_BAD" commit -qam feature-conflict
git -C "$FEATURE_BAD" push -q -u origin fix/issue-540-conflict
unsafe_head=$(git -C "$FEATURE_BAD" rev-parse HEAD)
printf '%s\n' base-change >"$SEED_BAD/shared.txt"
git -C "$SEED_BAD" commit -qam base-conflict
git -C "$SEED_BAD" push -q origin main

: >"$STATE/pr-comments.jsonl"
: >"$STATE/git-actions"
: >"$STATE/human-needed"
unsafe_marker="<!-- auto-merge-conflict: issue=540 head=${unsafe_head} result=conflict-rebase -->"
jq -cn --arg body "Auto-merge failed: unsafe wrapper fixture"$'\n'"${unsafe_marker}" \
  '{id:1,author:"review-app[bot]",body:$body,createdAt:"2026-07-30T00:20:00Z"}' \
  >>"$STATE/pr-comments.jsonl"
printf '%s\n' "$unsafe_head" >"$STATE/head"
printf '%s\n' pending-dev >"$STATE/label"
timeout 30 env \
  PATH="$BIN:$PATH" \
  GH_TOKEN="fixture-token" \
  PREFLIGHT_FIXTURE_STATE="$STATE" \
  PREFLIGHT_DEV_SCENARIO="unsafe" \
  PREFLIGHT_DEV_WORKTREE="$FEATURE_BAD" \
  AUTONOMOUS_CONF="$WRAPPER_SCRIPTS/autonomous.conf" \
  bash "$WRAPPER_SCRIPTS/autonomous-dev.sh" \
    --issue 540 --mode new \
    >"$STATE/dev-unsafe.out" 2>&1
assert_eq "TC-E2E-REBASE-046 dev wrapper handles unsafe rebase report" "0" "$?"
assert_eq "TC-E2E-REBASE-046 conflicting file is reported" \
  "shared.txt" "$(<"$STATE/human-needed")"
assert_contains "TC-E2E-REBASE-046 agent aborts unresolved rebase" \
  "rebase --abort" "$STATE/git-actions"
assert_eq "TC-E2E-REBASE-046 abort preserves the unchanged HEAD" \
  "$unsafe_head" "$(git -C "$FEATURE_BAD" rev-parse HEAD)"
assert_eq "TC-E2E-REBASE-046 remote HEAD was not force-updated" \
  "$unsafe_head" \
  "$(git --git-dir="$REMOTE_BAD" rev-parse refs/heads/fix/issue-540-conflict)"
assert_eq "TC-E2E-REBASE-046 no extra E2E ran for unresolved conflict" \
  "1" "$(wc -l <"$STATE/e2e-count" | tr -d ' ')"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
