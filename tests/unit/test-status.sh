#!/bin/bash
# test-status.sh — issue #235 / INV-81.
#
# Covers scripts/status.sh: the read-only operator inspector. Asserts the four
# canonical states (idle / in-progress+live / stalled+dead / approved-awaiting-
# merge), run-id + drop rendering, the read-only contract, and PREDICATE PARITY
# (status.sh must SOURCE lib-dispatch.sh and call its predicates, not duplicate
# them). Test IDs: TC-RUN-ARTIFACTS-040..051.
#
# Strategy: run status.sh as a subprocess with a stub `gh` on PATH (a real file,
# since status.sh re-resolves gh itself), a stub PID dir (AUTONOMOUS_PID_DIR) and
# run dir base (AUTONOMOUS_RUN_DIR_BASE). The stub gh reads a fixture file named
# by $GH_FIXTURE to answer issue/PR queries. Liveness is driven by writing a real
# PID file with our own $$ (alive) or a guaranteed-dead PID (not alive).
#
# Run: bash tests/unit/test-status.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATUS_SH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/status.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; [[ -n "${2:-}" ]] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_contains() { local d="$1" n="$2" h="$3"; [[ "$h" == *"$n"* ]] && ok "$d" || bad "$d" "expected to contain: $n"; }
assert_not_contains() { local d="$1" n="$2" h="$3"; [[ "$h" != *"$n"* ]] && ok "$d" || bad "$d" "unexpected: $n"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
PID_DIR="$TMP/piddir"; mkdir -p "$PID_DIR"
RUN_BASE="$TMP/state/autonomous-test-proj"; mkdir -p "$RUN_BASE/runs"
# A REAL empty conf to isolate status.sh's config load. `/dev/null` is NOT a
# regular file, so load_autonomous_conf's `[[ -f ]]` tier-1 check MISSES it and
# falls through to the `$PROJECT_DIR/scripts/autonomous.conf` tier — which loads
# the live conf when PROJECT_DIR is exported (e.g. in the review environment),
# breaking isolation (#235 review [P1]). A real empty file passes `-f`, so tier-1
# wins; `run_status` ALSO unsets PROJECT_DIR as belt-and-suspenders.
EMPTY_CONF="$TMP/empty-autonomous.conf"; : > "$EMPTY_CONF"

# ---- stub gh -------------------------------------------------------------
# Answers the specific queries status.sh issues:
#   gh issue view N --json state,labels,title   → $GH_FIXTURE issue object
#   gh pr list ... (fetch_pr_for_issue)          → $GH_FIXTURE pr array (or empty)
#   anything else                                → empty
# It also records every invocation to $GH_CALLS so the read-only test can assert
# no mutation verbs were used. The fixture is a JSON file: {issue:{}, pr:[]}.
cat > "$BIN/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
fixture="${GH_FIXTURE:-}"
# Parse out a -q expression if present (legacy pre-W1c1 pr-list path).
q=""; want=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    api)   [[ "${args[$((i+1))]:-}" == "graphql" ]] && want="graphql" ;;
    issue) [[ "${args[$((i+1))]:-}" == "view" ]] && want="issue" ;;
    pr)    [[ "${args[$((i+1))]:-}" == "list" ]] && want="pr"
           [[ "${args[$((i+1))]:-}" == "view" ]] && want="prview" ;;
    -q)    q="${args[$((i+1))]:-}" ;;
  esac
done
[[ -f "$fixture" ]] || { echo ""; exit 0; }
case "$want" in
  issue)  jq -c '.issue // {}' "$fixture" ;;
  graphql)
    # W1c1 (#397): chp_github_find_pr_for_issue now uses `gh api graphql`'s
    # cursor page-walker. Reshape the fixture's flat `.pr` array into the
    # GraphQL `.data.repository.pullRequests.{pageInfo,nodes}` envelope, with
    # each PR's `closingIssuesReferences` moved under `.nodes` so the leaf's
    # projection jq `(.closingIssuesReferences.nodes // [])[]?.number`
    # resolves. Single-page (hasNextPage:false) — the fixture fits in one
    # page.
    jq -c '.pr // []
      | map(. + {closingIssuesReferences: {nodes: (.closingIssuesReferences // [])}})
      | {data:{repository:{pullRequests:{
          pageInfo:{endCursor:null,hasNextPage:false},
          nodes: .
        }}}}' "$fixture" ;;
  pr)
    # Legacy pre-W1c1 pr-list path (kept for pre-existing pr-view fixtures
    # that still stub at this level; W1c1 leaves route through `api graphql`).
    if [[ -n "$q" ]]; then jq -c '.pr // []' "$fixture" | jq -c "$q" 2>/dev/null || echo ""
    else jq -c '.pr // []' "$fixture"; fi ;;
  *) echo "" ;;
esac
GH
chmod +x "$BIN/gh"

# write_fixture <file> <labels-space-sep> <state> <pr-json-or-empty>
write_fixture() {
  local f="$1" labels="$2" state="${3:-OPEN}" pr="${4:-[]}"
  local labelarr; labelarr="$(jq -cn --arg s "$labels" '$s | split(" ") | map(select(length>0)) | map({name:.})')"
  jq -cn --argjson labels "$labelarr" --arg state "$state" --argjson pr "$pr" \
    '{issue:{state:$state, title:"test issue", labels:$labels}, pr:$pr}' > "$f"
}

run_status() {  # run_status <issue> [extra args...]
  local issue="$1"; shift || true
  # `env -u PROJECT_DIR` removes the live-conf fallback tier entirely; EMPTY_CONF
  # (a real regular file) satisfies load_autonomous_conf's tier-1 `-f` check so
  # the test never sources a project's autonomous.conf (#235 review [P1]).
  env -u PROJECT_DIR \
  PATH="$BIN:$PATH" \
  REPO="zxkane/autonomous-dev-team" REPO_OWNER="zxkane" PROJECT_ID="test-proj" \
  MAX_RETRIES=3 MAX_CONCURRENT=5 \
  AUTONOMOUS_PID_DIR="$PID_DIR" AUTONOMOUS_RUN_DIR_BASE="$RUN_BASE" \
  AUTONOMOUS_CONF="$EMPTY_CONF" \
    bash "$STATUS_SH" "$issue" "$@" 2>&1
}

DEAD_PID=999999   # not a running process

# ---------------------------------------------------------------------------
# TC-040 idle issue (pending-dev, no live PID)
# ---------------------------------------------------------------------------
echo "== TC-040 idle =="
export GH_FIXTURE="$TMP/fx-idle.json"
write_fixture "$GH_FIXTURE" "autonomous pending-dev" "OPEN" "[]"
rm -f "$PID_DIR"/issue-40.pid "$PID_DIR"/review-40.pid
out="$(run_status 40)"
assert_contains "TC-040a labels shown" "pending-dev" "$out"
assert_contains "TC-040b lease none/dead" "alive=no" "$out"
assert_contains "TC-040c next action = dev-resume/dispatch" "Step 4" "$out"

# ---------------------------------------------------------------------------
# TC-041 in-progress with live lease
# ---------------------------------------------------------------------------
echo "== TC-041 in-progress + live lease =="
export GH_FIXTURE="$TMP/fx-inprog.json"
write_fixture "$GH_FIXTURE" "autonomous in-progress" "OPEN" "[]"
echo "$$" > "$PID_DIR/issue-41.pid"   # our own PID — guaranteed alive
out="$(run_status 41)"
assert_contains "TC-041a lease alive=yes" "alive=yes" "$out"
assert_contains "TC-041b next action mentions ALIVE/leave alone" "ALIVE" "$out"
rm -f "$PID_DIR/issue-41.pid"

# ---------------------------------------------------------------------------
# TC-042 stalled with dead PID (in-progress, dead, no near-success)
# ---------------------------------------------------------------------------
echo "== TC-042 in-progress + dead PID =="
export GH_FIXTURE="$TMP/fx-dead.json"
write_fixture "$GH_FIXTURE" "autonomous in-progress" "OPEN" "[]"
echo "$DEAD_PID" > "$PID_DIR/issue-42.pid"
# Make the pid file old so the mtime/heartbeat tiers also miss → pid_alive false.
touch -d "-1 hour" "$PID_DIR/issue-42.pid" 2>/dev/null || true
out="$(run_status 42)"
assert_contains "TC-042a lease dead" "alive=no" "$out"
assert_contains "TC-042b next action = dev crash declaration" "crash" "$out"
assert_contains "TC-042c next action → pending-dev" "pending-dev" "$out"
rm -f "$PID_DIR/issue-42.pid"

# ---------------------------------------------------------------------------
# TC-043 approved-awaiting-merge (PR approved + no-auto-close)
# ---------------------------------------------------------------------------
echo "== TC-043 approved + no-auto-close =="
export GH_FIXTURE="$TMP/fx-approved.json"
# PR must CLOSE #43 — fetch_pr_for_issue binds by GitHub's parsed close linkage
# (`closingIssuesReferences`), not a `#N` body mention (#277 / INV-86).
write_fixture "$GH_FIXTURE" "autonomous approved no-auto-close" "OPEN" \
  '[{"number":777,"reviewDecision":"APPROVED","mergeable":"MERGEABLE","state":"OPEN","body":"Closes #43","closingIssuesReferences":[{"number":43}],"headRefName":"fix/issue-43"}]'
out="$(run_status 43)"
assert_contains "TC-043a PR + reviewDecision shown" "reviewDecision=APPROVED" "$out"
assert_contains "TC-043b no-auto-close surfaced" "no-auto-close" "$out"
assert_contains "TC-043c next action = operator merges manually" "operator merges manually" "$out"

# ---------------------------------------------------------------------------
# TC-044 last 3 run-ids + outcomes; TC-045 last drop reasons; TC-047 no runs
# ---------------------------------------------------------------------------
echo "== TC-044/045 run dirs + drops =="
export GH_FIXTURE="$TMP/fx-runs.json"
write_fixture "$GH_FIXTURE" "autonomous pending-review" "OPEN" "[]"
mk_run() {  # mk_run <run-id> <started_at> <rc-or-empty> <ended_at-or-empty>
  local d="$RUN_BASE/runs/$1"; mkdir -p "$d"
  jq -cn --arg s "$2" --arg rc "$3" --arg e "$4" \
    '{started_at:$s} + (if $rc!="" then {rc:($rc|tonumber)} else {} end) + (if $e!="" then {ended_at:$e} else {} end)' \
    > "$d/meta.json"
}
mk_run "test-proj-50-dev-20260601T000000Z" "2026-06-01T00:00:00Z" "1" "2026-06-01T00:05:00Z"
mk_run "test-proj-50-dev-20260602T000000Z" "2026-06-02T00:00:00Z" "0" "2026-06-02T00:05:00Z"
mk_run "test-proj-50-review-20260603T000000Z" "2026-06-03T00:00:00Z" "0" "2026-06-03T00:05:00Z"
# review drops
echo '{"agent":"codex","reason":"agent-unavailable:quota","ts":"2026-06-03T00:04:00Z"}' \
  > "$RUN_BASE/runs/test-proj-50-review-20260603T000000Z/drops.jsonl"
out="$(run_status 50)"
assert_contains "TC-044a newest run-id shown" "test-proj-50-review-20260603T000000Z" "$out"
assert_contains "TC-044b success outcome rendered" "rc=0 (success)" "$out"
assert_contains "TC-044c failure outcome rendered" "rc=1 (failure)" "$out"
assert_contains "TC-045 drop reason rendered" "codex: agent-unavailable:quota" "$out"

echo "== TC-047 no runs =="
export GH_FIXTURE="$TMP/fx-norun.json"
write_fixture "$GH_FIXTURE" "autonomous pending-dev" "OPEN" "[]"
out="$(run_status 51)"
assert_contains "TC-047 no runs recorded line" "no runs recorded" "$out"

# ---------------------------------------------------------------------------
# TC-052 mixed meta/mtime ordering in _recent_runs (#235 owner [P1] r17):
# a NEWER run WITHOUT meta.json (mtime-only) must sort AHEAD of an OLDER ISO-backed
# run. A lexical sort would rank the ISO string (`2026-…`) above the epoch (`17…`).
# ---------------------------------------------------------------------------
echo "== TC-052 _recent_runs mixed meta/mtime ordering =="
export GH_FIXTURE="$TMP/fx-mixed.json"
write_fixture "$GH_FIXTURE" "autonomous pending-review" "OPEN" "[]"
# OLDER run, ISO-backed via meta.json (started_at ~2024).
_old="$RUN_BASE/runs/test-proj-52-dev-20240101T000000Z"; mkdir -p "$_old"
jq -cn '{started_at:"2024-01-01T00:00:00Z", rc:0, ended_at:"2024-01-01T00:05:00Z"}' > "$_old/meta.json"
touch -d "2024-01-01T00:00:00Z" "$_old" 2>/dev/null || true
# NEWER run, NO meta.json → mtime fallback only; set mtime to NOW so it is newest.
_new="$RUN_BASE/runs/test-proj-52-review-20260619T090000Z"; mkdir -p "$_new"
# (no meta.json on purpose) — mtime defaults to creation = now, strictly > 2024.
out="$(run_status 52)"
# The newest (mtime-only) run must appear on the FIRST run-id line; pull the run-ids
# block and check the first listed run-id is the mtime-only one.
_runline="$(printf '%s\n' "$out" | grep -A4 'last run-ids' | grep -m1 'test-proj-52-')"
assert_contains "TC-052a newest mtime-only run sorts first (not behind older ISO run)" \
  "test-proj-52-review-20260619T090000Z" "$_runline"

# ---------------------------------------------------------------------------
# TC-053 newest-review-without-drops vs older-with-drops (#235 owner [P1] r17):
# the "last drop reasons" must reflect the NEWEST review run; if that run has no
# drops.jsonl, show nothing — never an older review's stale drops.
# ---------------------------------------------------------------------------
echo "== TC-053 _latest_review_drops newest-without-drops =="
export GH_FIXTURE="$TMP/fx-drops.json"
write_fixture "$GH_FIXTURE" "autonomous pending-review" "OPEN" "[]"
# OLDER review WITH drops.
_oldrev="$RUN_BASE/runs/test-proj-53-review-20260601T000000Z"; mkdir -p "$_oldrev"
jq -cn '{started_at:"2026-06-01T00:00:00Z", rc:0, ended_at:"2026-06-01T00:05:00Z"}' > "$_oldrev/meta.json"
echo '{"agent":"agy","reason":"agent-unavailable:quota","ts":"2026-06-01T00:04:00Z"}' > "$_oldrev/drops.jsonl"
# NEWER review WITHOUT drops (clean run — every agent passed).
_newrev="$RUN_BASE/runs/test-proj-53-review-20260618T000000Z"; mkdir -p "$_newrev"
jq -cn '{started_at:"2026-06-18T00:00:00Z", rc:0, ended_at:"2026-06-18T00:05:00Z"}' > "$_newrev/meta.json"
out="$(run_status 53)"
assert_not_contains "TC-053a newest review has no drops → older stale drops NOT shown" \
  "agy: agent-unavailable:quota" "$out"
assert_contains "TC-053b drops section reports none recorded for the clean newest review" \
  "none recorded" "$out"
# Conversely, when the newest review DOES have drops, they ARE shown.
echo '{"agent":"codex","reason":"agent-unavailable:auth","ts":"2026-06-18T00:04:00Z"}' > "$_newrev/drops.jsonl"
out="$(run_status 53)"
assert_contains "TC-053c newest review's own drops are shown" "codex: agent-unavailable:auth" "$out"
assert_not_contains "TC-053d older review's drops still not shown" "agy: agent-unavailable:quota" "$out"

# ---------------------------------------------------------------------------
# TC-054 same-second collision tie-break (#235 review [P1] r19): two review runs
# minted within the SAME UTC second share one started_at/epoch; the LATER mint is
# disambiguated as `<run-id>-<n>`. status.sh must surface the LATER run, NOT
# whichever the glob yielded first (the older run). A strict `-gt`/`-k1,1nr` alone
# keeps the older dir → stale drops + mis-ordered run list. Both helpers must break
# the equal-epoch tie in favor of the HIGHER (later) disambiguation suffix.
# ---------------------------------------------------------------------------
echo "== TC-054 same-second review collision tie-break =="
export GH_FIXTURE="$TMP/fx-tie.json"
write_fixture "$GH_FIXTURE" "autonomous pending-review" "OPEN" "[]"
# BASE review (older), same second, WITH drops — must NOT be surfaced as latest.
_tie_base="$RUN_BASE/runs/test-proj-54-review-20260619T120000Z"; mkdir -p "$_tie_base"
jq -cn '{started_at:"2026-06-19T12:00:00Z", rc:0, ended_at:"2026-06-19T12:00:30Z"}' > "$_tie_base/meta.json"
echo '{"agent":"agy","reason":"older-same-second-drop","ts":"2026-06-19T12:00:20Z"}' > "$_tie_base/drops.jsonl"
# LATER review (`-2` disambiguation), SAME started_at second, with its OWN drops.
_tie_late="$RUN_BASE/runs/test-proj-54-review-20260619T120000Z-2"; mkdir -p "$_tie_late"
jq -cn '{started_at:"2026-06-19T12:00:00Z", rc:1, ended_at:"2026-06-19T12:00:45Z"}' > "$_tie_late/meta.json"
echo '{"agent":"codex","reason":"later-same-second-drop","ts":"2026-06-19T12:00:40Z"}' > "$_tie_late/drops.jsonl"
out="$(run_status 54)"
assert_contains "TC-054a later same-second run's drops are shown" \
  "codex: later-same-second-drop" "$out"
assert_not_contains "TC-054b older same-second run's drops are NOT shown" \
  "agy: older-same-second-drop" "$out"
# _recent_runs lists the later (`-2`) dir ahead of the base dir on the equal-epoch tie.
_tie_runs="$(printf '%s\n' "$out" | grep -A4 'last run-ids' | grep -m1 'test-proj-54-')"
assert_contains "TC-054c later (\`-2\`) run-id sorts first on the same-second tie" \
  "test-proj-54-review-20260619T120000Z-2" "$_tie_runs"

# ---------------------------------------------------------------------------
# TC-054 DOUBLE-DIGIT (#235 review [P2] r19): once a same-second collision reaches
# double digits, the disambiguation suffix MUST be compared NUMERICALLY, not as a
# string. The pair `…Z-10` vs `…Z-11` is chosen deliberately so it discriminates
# the numeric key from BOTH stringly alternatives the prior review flagged:
#   • `_latest_review_drops`: a reverse-LEXICAL run-id compare (`[[ name > … ]]`)
#     ranks `…Z-11` over `…Z-10` only because '1'>'0' at the last char — but on
#     `…Z-9` vs `…Z-10` it would mis-pick `-9`; the numeric `[[ suffix -gt … ]]` is
#     unambiguous. (TC-054a/b already pin the original [P1] strict-`-gt` regression.)
#   • `_recent_runs`: GNU `sort`'s old whole-line `-k1,1nr` fallback compares the
#     equal-epoch lines char-by-char ASCENDING after the epoch, so `…-10…` sorts
#     BEFORE `…-11…` → it would put `-10` first (WRONG). Only the numeric `-k2,2nr`
#     secondary key puts the LATER `-11` first. `-10` vs `-11` is exactly where the
#     whole-line fallback and the numeric key DIVERGE, so this genuinely pins it.
# ---------------------------------------------------------------------------
echo "== TC-054 double-digit suffix (…Z-10 vs …Z-11) =="
export GH_FIXTURE="$TMP/fx-tie11.json"
write_fixture "$GH_FIXTURE" "autonomous pending-review" "OPEN" "[]"
# `…Z-10` (the EARLIER mint) WITH drops — must NOT be surfaced as latest.
_t10="$RUN_BASE/runs/test-proj-55-review-20260619T120000Z-10"; mkdir -p "$_t10"
jq -cn '{started_at:"2026-06-19T12:00:00Z", rc:0, ended_at:"2026-06-19T12:00:30Z"}' > "$_t10/meta.json"
echo '{"agent":"agy","reason":"tenth-mint-drop","ts":"2026-06-19T12:00:20Z"}' > "$_t10/drops.jsonl"
# `…Z-11` (the LATER mint) WITH its own drops — must be latest.
_t11="$RUN_BASE/runs/test-proj-55-review-20260619T120000Z-11"; mkdir -p "$_t11"
jq -cn '{started_at:"2026-06-19T12:00:00Z", rc:1, ended_at:"2026-06-19T12:00:45Z"}' > "$_t11/meta.json"
echo '{"agent":"codex","reason":"eleventh-mint-drop","ts":"2026-06-19T12:00:40Z"}' > "$_t11/drops.jsonl"
out="$(run_status 55)"
assert_contains "TC-054d double-digit: later (-11) run's drops shown, not (-10)'s" \
  "codex: eleventh-mint-drop" "$out"
assert_not_contains "TC-054e double-digit: earlier (-10) run's drops NOT shown" \
  "agy: tenth-mint-drop" "$out"
_tie11_runs="$(printf '%s\n' "$out" | grep -A4 'last run-ids' | grep -m1 'test-proj-55-')"
assert_contains "TC-054f double-digit: (-11) sorts first (numeric suffix vs whole-line fallback)" \
  "test-proj-55-review-20260619T120000Z-11" "$_tie11_runs"

# ---------------------------------------------------------------------------
# TC-046 retry count parity — value must equal count_retries (here 0, no comments)
# ---------------------------------------------------------------------------
echo "== TC-046 retry count surfaced =="
assert_contains "TC-046 retry count line present" "retry count:" "$(run_status 51)"

# ---------------------------------------------------------------------------
# TC-048 --project override
# ---------------------------------------------------------------------------
echo "== TC-048 --project override =="
export GH_FIXTURE="$TMP/fx-proj.json"
write_fixture "$GH_FIXTURE" "autonomous pending-dev" "OPEN" "[]"
out="$(run_status 52 --project other-proj)"
assert_contains "TC-048 project override reflected" "project: other-proj" "$out"

# ---------------------------------------------------------------------------
# TC-049 invalid/missing issue arg
# ---------------------------------------------------------------------------
echo "== TC-049 bad arg =="
out="$(env -u PROJECT_DIR PATH="$BIN:$PATH" REPO=x/y REPO_OWNER=x PROJECT_ID=test-proj \
  AUTONOMOUS_CONF="$EMPTY_CONF" bash "$STATUS_SH" notanumber 2>&1; echo "rc=$?")"
assert_contains "TC-049a usage error" "Usage:" "$out"
assert_contains "TC-049b non-zero exit" "rc=2" "$out"

# ---------------------------------------------------------------------------
# TC-050 read-only contract — NO mutation verbs ever issued
# ---------------------------------------------------------------------------
echo "== TC-050 read-only contract =="
export GH_FIXTURE="$TMP/fx-ro.json"
export GH_CALLS="$TMP/gh-calls.log"
: > "$GH_CALLS"
write_fixture "$GH_FIXTURE" "autonomous in-progress" "OPEN" \
  '[{"number":1,"reviewDecision":"APPROVED","mergeable":"MERGEABLE","state":"OPEN","body":"Closes #60","closingIssuesReferences":[{"number":60}],"headRefName":"fix/issue-60"}]'
echo "$$" > "$PID_DIR/issue-60.pid"
run_status 60 >/dev/null
rm -f "$PID_DIR/issue-60.pid"
calls="$(cat "$GH_CALLS")"
assert_not_contains "TC-050a no 'gh issue edit'" "issue edit" "$calls"
assert_not_contains "TC-050b no 'gh pr merge'" "pr merge" "$calls"
assert_not_contains "TC-050c no 'gh issue comment'" "issue comment" "$calls"
assert_not_contains "TC-050d no 'gh pr comment'" "pr comment" "$calls"
assert_not_contains "TC-050e no 'gh pr review'" "pr review" "$calls"
unset GH_CALLS

# Source-level read-only assertion: status.sh must contain NO mutation calls.
src="$(cat "$STATUS_SH")"
assert_not_contains "TC-050f source has no 'gh issue edit'" "gh issue edit" "$src"
assert_not_contains "TC-050g source has no 'gh pr merge'" "gh pr merge" "$src"
assert_not_contains "TC-050h source has no 'gh issue comment'" "gh issue comment" "$src"

# ---------------------------------------------------------------------------
# TC-051 predicate parity — sources lib-dispatch.sh AND calls its predicates
# ---------------------------------------------------------------------------
echo "== TC-051 predicate parity (grep-assert) =="
assert_contains "TC-051a sources lib-dispatch.sh" "lib-dispatch.sh" "$src"
assert_contains "TC-051b calls pid_alive" "pid_alive " "$src"
assert_contains "TC-051c calls count_retries" "count_retries " "$src"
assert_contains "TC-051d calls fetch_pr_for_issue" "fetch_pr_for_issue " "$src"
assert_contains "TC-051e calls dev_near_success" "dev_near_success " "$src"
assert_contains "TC-051f calls review_near_success" "review_near_success " "$src"

echo ""
echo "================================================"
echo -e "status.sh: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================================"
[[ "$FAIL" -eq 0 ]]
