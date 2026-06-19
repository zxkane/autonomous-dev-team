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
# Parse out a -q expression if present (fetch_pr_for_issue uses -q).
q=""; want=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    issue) [[ "${args[$((i+1))]:-}" == "view" ]] && want="issue" ;;
    pr)    [[ "${args[$((i+1))]:-}" == "list" ]] && want="pr"
           [[ "${args[$((i+1))]:-}" == "view" ]] && want="prview" ;;
    -q)    q="${args[$((i+1))]:-}" ;;
  esac
done
[[ -f "$fixture" ]] || { echo ""; exit 0; }
case "$want" in
  issue)  jq -c '.issue // {}' "$fixture" ;;
  pr)
    # fetch_pr_for_issue: gh pr list --json ... -q '[...] | .[0] // empty'
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
# PR body must reference #43 — fetch_pr_for_issue filters on `.body` matching
# `#<issue>` (the same predicate the dispatcher uses; #148 null-guard).
write_fixture "$GH_FIXTURE" "autonomous approved no-auto-close" "OPEN" \
  '[{"number":777,"reviewDecision":"APPROVED","mergeable":"MERGEABLE","state":"OPEN","body":"Closes #43"}]'
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
  '[{"number":1,"reviewDecision":"APPROVED","mergeable":"MERGEABLE","state":"OPEN","body":"Closes #60"}]'
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
