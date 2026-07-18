#!/bin/bash
# Hermetic crash/restart E2E for issue #515.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export TC_E2E_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-terminal-control.sh"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

[[ -r "$TC_E2E_LIB" ]] || { echo "missing $TC_E2E_LIB" >&2; exit 1; }
[[ -r "$DEV_WRAPPER" ]] || { echo "missing $DEV_WRAPPER" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TC_E2E_COMMENTS="$WORK/comments.json"
export TC_E2E_LABELS="$WORK/labels.json"
export TC_E2E_SEQ="$WORK/seq"
printf '[]\n' > "$TC_E2E_COMMENTS"
printf '["autonomous","in-progress"]\n' > "$TC_E2E_LABELS"
printf '0\n' > "$TC_E2E_SEQ"
awk '/^cleanup\(\) \{/,/^\}/' "$DEV_WRAPPER" > "$WORK/dev-cleanup.sh"
mkdir "$WORK/bin"
ln -s "$(command -v true)" "$WORK/bin/gh"

tc_e2e_append_comment() {
  local body="$1" seq tmp
  seq="$(cat "$TC_E2E_SEQ")"
  printf '%s\n' "$((seq + 1))" > "$TC_E2E_SEQ"
  tmp="${TC_E2E_COMMENTS}.tmp"
  jq -c --argjson id "$((9000 + seq))" --arg body "$body" \
    --arg ts "2026-07-18T05:00:0${seq}Z" \
    '. + [{id:$id,author:"pipeline-bot",authorKind:"self",body:$body,createdAt:$ts}]' \
    "$TC_E2E_COMMENTS" > "$tmp"
  mv "$tmp" "$TC_E2E_COMMENTS"
}

itp_list_comments() { cat "$TC_E2E_COMMENTS"; }
itp_post_comment() { tc_e2e_append_comment "$2"; }
itp_read_task() { jq -c '{labels:.}' "$TC_E2E_LABELS"; }
itp_transition_state() {
  local remove="$2" add="$3" tmp="${TC_E2E_LABELS}.tmp"
  jq -c --arg remove "$remove" --arg add "$add" '
    ($remove | split(",")) as $r
    | map(select(. as $label | ($r | index($label) | not)))
    | if index($add) == null then . + [$add] else . end
  ' "$TC_E2E_LABELS" > "$tmp"
  mv "$tmp" "$TC_E2E_LABELS"
}
export -f tc_e2e_append_comment itp_list_comments itp_post_comment
export -f itp_read_task itp_transition_state

# Process 1 persists the decision, then exits before any label transition.
bash -euo pipefail -c '
  source "$TC_E2E_LIB"
  terminal_intent_write 515 cap-crash inv-v1-crash usage-unknown dev-wrapper
'
jq -e 'index("in-progress") != null and index("stalled") == null' "$TC_E2E_LABELS" >/dev/null

# Process 2 runs the real dev-wrapper cleanup function in a fresh process.
# shellcheck disable=SC2016  # Variables intentionally expand in the child.
env -u ADT_GUARD_FD -u ADT_LANE_DIR -u ADT_LANE_ID -u ADT_STATE_ROOT \
    -u RUN_DIR -u RUN_ID -u AGENT_PROGRESS_FILE -u AGENT_PROGRESS_RUNID_FILE \
    -u AGENT_PID_FILE -u AGENT_PR_CREATE_FILE -u AGENT_BOT_TRIGGER_FILE \
PATH="$WORK/bin:/usr/bin:/bin" \
AGENT_RAN=false \
ISSUE_NUMBER=515 \
REPO=zxkane/autonomous-dev-team \
PID_FILE="$WORK/agent.pid" \
SESSION_ID=tc-e2e-session \
LOG_FILE="$WORK/agent.log" \
GH_AUTH_MODE=token \
RECEIVED_SIGTERM=0 \
bash -uo pipefail -c '
  source "$TC_E2E_LIB"
  source "'"$WORK"'/dev-cleanup.sh"
  log() { :; }
  cleanup_github_auth() { :; }
  date() { printf "2026-07-18T05:00:01Z\n"; }
  (exit 1)
  cleanup
'

jq -e '
  sort == ["autonomous","stalled"]
  and index("pending-dev") == null
  and index("pending-review") == null
' "$TC_E2E_LABELS" >/dev/null

live="$(
  bash -euo pipefail -c '
    source "$TC_E2E_LIB"
    terminal_intent_read 515
  '
)"
[[ -z "$live" ]]
jq -e '[.[] | select(.body == "<!-- resource-terminal-intent-consume-v1: issue=515 intent=cap-crash invocation=inv-v1-crash -->")] | length == 1' \
  "$TC_E2E_COMMENTS" >/dev/null

# Process 3 proves an idempotent replay cannot resurrect a pending label after
# both the transition and consume marker are durable.
bash -euo pipefail -c '
  source "$TC_E2E_LIB"
  terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev
'
jq -e '
  sort == ["autonomous","stalled"]
  and index("pending-dev") == null
  and index("pending-review") == null
' "$TC_E2E_LABELS" >/dev/null

echo "PASS: TC-TERMCTRL-060/061/090 wrapper crash restart converges and stays consumed + stalled"
