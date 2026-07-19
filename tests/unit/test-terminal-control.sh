#!/bin/bash
# test-terminal-control.sh - issue #515 / INV-140.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-terminal-control.sh"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REVIEW_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
DISPATCH_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
GITHUB_PROVIDER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/itp-github.sh"
GITLAB_PROVIDER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/itp-gitlab.sh"
TRANSITIONS="$PROJECT_ROOT/docs/pipeline/transitions.json"
CODESITE_MAP="$PROJECT_ROOT/docs/pipeline/spec-codesite-map.json"
GUARD_MAP="$PROJECT_ROOT/docs/pipeline/spec-guard-map.json"
SPEC_CHECKER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/check-spec-drift.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc"
    printf '      expected=[%s]\n      actual=  [%s]\n' "$expected" "$actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc"
    printf '      missing=[%s]\n' "$needle"
  fi
}

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  assert_eq "$desc" "$expected" "$actual"
}

if [[ ! -r "$LIB" ]]; then
  fail "setup: lib-terminal-control.sh exists"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COMMENTS="$WORK/comments.json"
LABELS="$WORK/labels.json"
CALLS="$WORK/calls.log"
SEQ="$WORK/seq"
ERR="$WORK/err"

reset_store() {
  printf '[]\n' > "$COMMENTS"
  printf '["autonomous","in-progress"]\n' > "$LABELS"
  : > "$CALLS"
  printf '0\n' > "$SEQ"
  rm -f "$WORK/fail-list" "$WORK/fail-read" "$WORK/fail-transition"
  unset FAIL_POST_KIND INJECT_CLEAR_BEFORE_CONSUME INJECT_GENERATION_AFTER_STALL
}

append_comment() {
  local body="$1" kind="${2:-self}" author="${3:-pipeline-bot}"
  local seq ts tmp
  seq="$(cat "$SEQ")"
  printf '%s\n' "$((seq + 1))" > "$SEQ"
  printf -v ts '2026-07-18T04:%02d:%02dZ' "$((seq / 60))" "$((seq % 60))"
  tmp="$WORK/comments.tmp"
  jq -c --argjson id "$((1000 + seq))" --arg author "$author" \
    --arg kind "$kind" --arg body "$body" --arg ts "$ts" \
    '. + [{id:$id,author:$author,authorKind:$kind,body:$body,createdAt:$ts}]' \
    "$COMMENTS" > "$tmp" && mv "$tmp" "$COMMENTS"
}

itp_list_comments() {
  [[ ! -e "$WORK/fail-list" ]] || return 71
  cat "$COMMENTS"
}

itp_post_comment() {
  local issue="${1:-}" body="${2:-}"
  case "${FAIL_POST_KIND:-}" in
    write) [[ "$body" == *"resource-terminal-intent-v1:"* ]] && return 72 ;;
    consume) [[ "$body" == *"resource-terminal-intent-consume-v1:"* ]] && return 72 ;;
    clear) [[ "$body" == *"resource-terminal-intent-clear-v1:"* ]] && return 72 ;;
  esac
  if [[ "${INJECT_CLEAR_BEFORE_CONSUME:-0}" == "1" \
        && "$body" == *"resource-terminal-intent-consume-v1:"* ]]; then
    append_comment '<!-- resource-terminal-intent-clear-v1: issue=515 intent=clear-race invocation=inv-v1-clear-race reason=operator-rearm -->'
    INJECT_CLEAR_BEFORE_CONSUME=0
  fi
  printf 'post|%s|%s\n' "$issue" "$body" >> "$CALLS"
  append_comment "$body"
}

itp_read_task() {
  local issue="${1:-}" fields="${2:-}"
  printf 'read|%s|%s\n' "$issue" "$fields" >> "$CALLS"
  [[ ! -e "$WORK/fail-read" ]] || return 73
  jq -c '{labels:.}' "$LABELS"
}

itp_transition_state() {
  local issue="${1:-}" remove="${2:-}" add="${3:-}"
  printf 'transition|%s|%s|%s\n' "$issue" "$remove" "$add" >> "$CALLS"
  [[ ! -e "$WORK/fail-transition" ]] || return 74
  local tmp="$WORK/labels.tmp"
  jq -c --arg remove "$remove" --arg add "$add" '
    ($remove | split(",") | map(select(length > 0))) as $remove_set
    | map(select(. as $label | ($remove_set | index($label) | not)))
    | if $add == "" or index($add) != null then . else . + [$add] end
  ' "$LABELS" > "$tmp" && mv "$tmp" "$LABELS"
  if [[ "${INJECT_GENERATION_AFTER_STALL:-0}" == "1" && "$add" == "stalled" ]]; then
    append_comment '<!-- resource-terminal-intent-v1: issue=515 intent=cleanup-race invocation=inv-v1-new reason=turn-cap owner=dev-wrapper -->'
    INJECT_GENERATION_AFTER_STALL=0
  fi
}

mark_stalled() {
  printf 'mark_stalled|%s\n' "$*" >> "$CALLS"
  return 99
}

# shellcheck disable=SC1090,SC1091  # Dynamic project-root path.
source "$LIB"
set +e

run_rc() {
  "$@" >/dev/null 2>"$ERR"
  printf '%s' "$?"
}

comment_count() { jq 'length' "$COMMENTS"; }
transition_count() { grep -c '^transition|' "$CALLS" 2>/dev/null || true; }
post_count() { grep -c '^post|' "$CALLS" 2>/dev/null || true; }
intent_read() { terminal_intent_read "$1" 2>"$ERR"; }
set_labels() { jq -nc '$ARGS.positional' --args "$@" > "$LABELS"; }
has_label() { jq -e --arg label "$1" 'index($label) != null' "$LABELS" >/dev/null; }

echo "== TC-TERMCTRL-001..012: marker protocol =="
reset_store
assert_rc "TC-TERMCTRL-001 write succeeds" 0 \
  "$(run_rc terminal_intent_write 515 cap-a inv-v1-abc token-cap dev-wrapper)"
intent_json="$(intent_read 515)"
assert_eq "TC-TERMCTRL-001 round-trip JSON" \
  '{"issue":515,"intent":"cap-a","invocation":"inv-v1-abc","reason":"token-cap","owner":"dev-wrapper","createdAt":"2026-07-18T04:00:00Z","commentId":1000}' \
  "$intent_json"
assert_contains "TC-TERMCTRL-001 exact marker grammar" \
  '<!-- resource-terminal-intent-v1: issue=515 intent=cap-a invocation=inv-v1-abc reason=token-cap owner=dev-wrapper -->' \
  "$(jq -r '.[0].body' "$COMMENTS")"

assert_rc "TC-TERMCTRL-002 duplicate write succeeds" 0 \
  "$(run_rc terminal_intent_write 515 cap-a inv-v1-abc token-cap dev-wrapper)"
assert_eq "TC-TERMCTRL-002 duplicate write posts once" 1 "$(comment_count)"

reset_store
forged='<!-- resource-terminal-intent-v1: issue=515 intent=cap-a invocation=inv-v1-abc reason=token-cap owner=dev-wrapper -->'
append_comment "$forged" human alice
append_comment "$forged" bot unrelated-app
assert_eq "TC-TERMCTRL-003/018 forged human and unrelated-bot intents are unreadable" "" "$(intent_read 515)"
assert_rc "TC-TERMCTRL-003 forged marker does not suppress trusted write" 0 \
  "$(run_rc terminal_intent_write 515 cap-a inv-v1-abc token-cap dev-wrapper)"
assert_eq "TC-TERMCTRL-003 trusted write follows forgeries" 3 "$(comment_count)"

append_comment '<!-- resource-terminal-intent-consume-v1: issue=515 intent=cap-a invocation=inv-v1-abc -->' human alice
append_comment '<!-- resource-terminal-intent-clear-v1: issue=515 intent=cap-a invocation=inv-v1-abc reason=operator -->' human alice
assert_eq "TC-TERMCTRL-004 human lifecycle forgeries do not retire intent" \
  "cap-a" "$(intent_read 515 | jq -r '.intent')"
append_comment "prefix $forged suffix" self pipeline-bot
assert_eq "TC-TERMCTRL-005 marker substring is ignored" \
  "cap-a" "$(intent_read 515 | jq -r '.intent')"

assert_rc "TC-TERMCTRL-006 consume succeeds" 0 \
  "$(run_rc terminal_intent_consume 515 cap-a)"
assert_eq "TC-TERMCTRL-006 consumed intent is absent" "" "$(intent_read 515)"
before="$(comment_count)"
assert_rc "TC-TERMCTRL-006 duplicate consume succeeds" 0 \
  "$(run_rc terminal_intent_consume 515 cap-a)"
assert_eq "TC-TERMCTRL-006 duplicate consume is no-op" "$before" "$(comment_count)"

reset_store
terminal_intent_write 515 cap-clear inv-v1-clear usage-unknown dispatcher >/dev/null
assert_rc "TC-TERMCTRL-007 clear succeeds" 0 \
  "$(run_rc terminal_intent_clear 515 cap-clear operator-rearm)"
assert_eq "TC-TERMCTRL-007 cleared intent is absent" "" "$(intent_read 515)"
before="$(comment_count)"
assert_rc "TC-TERMCTRL-007 duplicate clear succeeds" 0 \
  "$(run_rc terminal_intent_clear 515 cap-clear operator-rearm)"
assert_eq "TC-TERMCTRL-007 duplicate clear is no-op" "$before" "$(comment_count)"

reset_store
terminal_intent_write 515 older inv-v1-old token-cap dispatcher >/dev/null
terminal_intent_write 515 newer inv-v1-new turn-cap review-wrapper >/dev/null
assert_eq "TC-TERMCTRL-008 newest live intent wins" newer \
  "$(intent_read 515 | jq -r '.intent')"
terminal_intent_consume 515 newer >/dev/null
assert_eq "TC-TERMCTRL-009 consumed newest falls back to older" older \
  "$(intent_read 515 | jq -r '.intent')"

before="$(comment_count)"
assert_rc "TC-TERMCTRL-010 invalid issue rejected" 1 \
  "$(run_rc terminal_intent_write nope id inv token-cap dispatcher)"
assert_rc "TC-TERMCTRL-010 invalid reason rejected" 1 \
  "$(run_rc terminal_intent_write 515 id inv other dispatcher)"
assert_rc "TC-TERMCTRL-010 invalid owner rejected" 1 \
  "$(run_rc terminal_intent_write 515 id inv token-cap human)"
assert_rc "TC-TERMCTRL-010 unsafe id rejected" 1 \
  "$(run_rc terminal_intent_write 515 'bad id' inv token-cap dispatcher)"
assert_rc "TC-TERMCTRL-010 unsafe invocation rejected" 1 \
  "$(run_rc terminal_intent_write 515 id 'bad invocation' token-cap dispatcher)"
assert_rc "TC-TERMCTRL-010 missing args are set-u safe" 1 \
  "$(run_rc terminal_intent_write 515)"
assert_eq "TC-TERMCTRL-010 invalid input posts nothing" "$before" "$(comment_count)"

touch "$WORK/fail-list"
assert_rc "TC-TERMCTRL-011 list failure is loud" 1 \
  "$(run_rc terminal_intent_read 515)"
rm -f "$WORK/fail-list"
printf '{}\n' > "$COMMENTS"
assert_rc "TC-TERMCTRL-011 malformed comment envelope is loud" 1 \
  "$(run_rc terminal_intent_read 515)"
printf '["malformed-row"]\n' > "$COMMENTS"
: > "$CALLS"
assert_rc "TC-TERMCTRL-011 malformed comment row blocks writes" 1 \
  "$(run_rc terminal_intent_write 515 id inv token-cap dispatcher)"
assert_eq "TC-TERMCTRL-011 malformed comment row posts nothing" 0 "$(post_count)"
reset_store
assert_rc "TC-TERMCTRL-012 consume unknown intent fails" 1 \
  "$(run_rc terminal_intent_consume 515 absent)"
assert_rc "TC-TERMCTRL-012 clear unknown intent fails" 1 \
  "$(run_rc terminal_intent_clear 515 absent operator)"
assert_eq "TC-TERMCTRL-012 unknown lifecycle posts nothing" 0 "$(comment_count)"

assert_rc "TC-TERMCTRL-015 read arity is set-u safe" 1 \
  "$(run_rc terminal_intent_read)"
assert_rc "TC-TERMCTRL-015 read rejects invalid issue" 1 \
  "$(run_rc terminal_intent_read nope)"
assert_rc "TC-TERMCTRL-015 consume arity is set-u safe" 1 \
  "$(run_rc terminal_intent_consume)"
assert_rc "TC-TERMCTRL-015 consume rejects invalid issue" 1 \
  "$(run_rc terminal_intent_consume nope id)"
assert_rc "TC-TERMCTRL-015 consume rejects invalid intent" 1 \
  "$(run_rc terminal_intent_consume 515 'bad intent')"
assert_rc "TC-TERMCTRL-015 clear arity is set-u safe" 1 \
  "$(run_rc terminal_intent_clear)"
assert_rc "TC-TERMCTRL-015 clear rejects invalid issue" 1 \
  "$(run_rc terminal_intent_clear nope id operator)"
assert_rc "TC-TERMCTRL-015 clear rejects invalid intent" 1 \
  "$(run_rc terminal_intent_clear 515 'bad intent' operator)"
assert_rc "TC-TERMCTRL-015 clear rejects invalid reason" 1 \
  "$(run_rc terminal_intent_clear 515 id 'bad reason')"

reset_store
terminal_intent_write 515 reused inv-v1-old token-cap dispatcher >/dev/null
terminal_intent_consume 515 reused >/dev/null
assert_rc "TC-TERMCTRL-013 consumed intent id accepts a new invocation" 0 \
  "$(run_rc terminal_intent_write 515 reused inv-v1-new turn-cap dev-wrapper)"
assert_eq "TC-TERMCTRL-013 new invocation is live" inv-v1-new \
  "$(intent_read 515 | jq -r '.invocation')"
assert_rc "TC-TERMCTRL-013 new invocation consumes independently" 0 \
  "$(run_rc terminal_intent_consume 515 reused)"
assert_eq "TC-TERMCTRL-013 both generations are consumed" "" "$(intent_read 515)"

reset_store
terminal_intent_write 515 rearmed inv-v1-old usage-unknown dispatcher >/dev/null
terminal_intent_clear 515 rearmed operator-rearm >/dev/null
assert_rc "TC-TERMCTRL-014 cleared intent id accepts a new invocation" 0 \
  "$(run_rc terminal_intent_write 515 rearmed inv-v1-new token-cap review-wrapper)"
assert_eq "TC-TERMCTRL-014 new invocation is live" inv-v1-new \
  "$(intent_read 515 | jq -r '.invocation')"
assert_rc "TC-TERMCTRL-014 new invocation clears independently" 0 \
  "$(run_rc terminal_intent_clear 515 rearmed operator-rearm)"
assert_eq "TC-TERMCTRL-014 both generations are cleared" "" "$(intent_read 515)"

reset_store
terminal_intent_write 515 clear-wins inv-v1-clear-wins token-cap dispatcher >/dev/null
terminal_intent_clear 515 clear-wins operator-rearm >/dev/null
before="$(comment_count)"
assert_rc "TC-TERMCTRL-016 stale consume after clear is a no-op" 0 \
  "$(run_rc terminal_intent_consume 515 clear-wins)"
assert_eq "TC-TERMCTRL-016 clear suppresses stale consume post" "$before" "$(comment_count)"
append_comment '<!-- resource-terminal-intent-consume-v1: issue=515 intent=clear-wins invocation=inv-v1-clear-wins -->'
before="$(comment_count)"
assert_rc "TC-TERMCTRL-016 clear replay after stale consume succeeds" 0 \
  "$(run_rc terminal_intent_clear 515 clear-wins operator-rearm)"
assert_eq "TC-TERMCTRL-016 clear replay stays idempotent after stale consume" \
  "$before" "$(comment_count)"
events="$(_terminal_control_events "$(cat "$COMMENTS")")"
assert_rc "TC-TERMCTRL-016 stale consume cannot override clear" 0 \
  "$(run_rc _terminal_control_intent_is_cleared \
    "$events" 515 clear-wins inv-v1-clear-wins)"

reset_store
terminal_intent_write 515 clear-race inv-v1-clear-race token-cap dispatcher >/dev/null
INJECT_CLEAR_BEFORE_CONSUME=1
assert_rc "TC-TERMCTRL-016 clear inside consume read/post window succeeds" 0 \
  "$(run_rc terminal_intent_consume 515 clear-race)"
events="$(_terminal_control_events "$(cat "$COMMENTS")")"
assert_rc "TC-TERMCTRL-016 in-window clear is intent-authoritative" 0 \
  "$(run_rc _terminal_control_intent_is_cleared \
    "$events" 515 clear-race inv-v1-clear-race)"

reset_store
terminal_intent_write 515 delayed inv-v1-delayed token-cap dispatcher >/dev/null
delayed_marker="$(jq -r '.[0].body' "$COMMENTS")"
terminal_intent_consume 515 delayed >/dev/null
append_comment "$delayed_marker"
assert_eq "TC-TERMCTRL-019 delayed duplicate cannot resurrect consumed intent" "" \
  "$(intent_read 515)"
before="$(comment_count)"
assert_rc "TC-TERMCTRL-019 delayed duplicate replay remains idempotent" 0 \
  "$(run_rc terminal_intent_write 515 delayed inv-v1-delayed token-cap dispatcher)"
assert_eq "TC-TERMCTRL-019 replay posts nothing" "$before" "$(comment_count)"

reset_store
append_comment '<!-- resource-terminal-intent-v1: issue=515 intent=conflict invocation=inv-a reason=token-cap owner=dispatcher -->'
append_comment '<!-- resource-terminal-intent-v1: issue=515 intent=conflict invocation=inv-b reason=turn-cap owner=dev-wrapper -->'
assert_eq "TC-TERMCTRL-019 concurrent newest generation wins" inv-b \
  "$(intent_read 515 | jq -r '.invocation')"
assert_rc "TC-TERMCTRL-019 newest concurrent generation consumes" 0 \
  "$(run_rc terminal_intent_consume 515 conflict)"
assert_eq "TC-TERMCTRL-019 older generation remains live" inv-a \
  "$(intent_read 515 | jq -r '.invocation')"
assert_rc "TC-TERMCTRL-019 older concurrent generation clears" 0 \
  "$(run_rc terminal_intent_clear 515 conflict operator-rearm)"
assert_eq "TC-TERMCTRL-019 concurrent generations converge terminal" "" \
  "$(intent_read 515)"

reset_store
append_comment '<!-- resource-terminal-intent-consume-v1: issue=515 intent=future invocation=inv-future -->'
terminal_intent_write 515 future inv-future token-cap dispatcher >/dev/null
assert_eq "TC-TERMCTRL-019 lifecycle before its write is ineligible" inv-future \
  "$(intent_read 515 | jq -r '.invocation')"

echo ""
echo "== TC-TERMCTRL-017/018: provider self-author resolution =="
github_pat_comments="$(
  (
    gh() {
      if [[ "${1:-} ${2:-}" == "api user" ]]; then
        printf '%s\n' "pipeline-user"
      elif [[ "${1:-} ${2:-}" == "api --paginate" ]]; then
        printf '%s\n' '[[{"id":1,"user":{"login":"pipeline-user","type":"User"},"body":"own","created_at":"2026-07-18T04:00:00Z"},{"id":2,"user":{"login":"unrelated-app[bot]","type":"Bot"},"body":"other","created_at":"2026-07-18T04:00:01Z"},{"id":3,"user":{"login":"pipeline-user[bot]","type":"Bot"},"body":"slug collision","created_at":"2026-07-18T04:00:02Z"}]]'
      else
        return 1
      fi
    }
    BOT_LOGIN="" GH_AUTH_MODE=token ITP_REQUIRE_SELF_AUTHOR=1 REPO=zxkane/autonomous-dev-team
    export BOT_LOGIN GH_AUTH_MODE ITP_REQUIRE_SELF_AUTHOR REPO
    # shellcheck disable=SC1090
    source "$GITHUB_PROVIDER"
    itp_github_list_comments 515
  )
)"
assert_eq "TC-TERMCTRL-017 GitHub PAT actor resolves as self" self \
  "$(jq -r '.[] | select(.author == "pipeline-user") | .authorKind' <<<"$github_pat_comments")"
assert_eq "TC-TERMCTRL-018 unrelated GitHub App remains bot" bot \
  "$(jq -r '.[] | select(.author == "unrelated-app[bot]") | .authorKind' <<<"$github_pat_comments")"
assert_eq "TC-TERMCTRL-018 PAT/App slug collision remains untrusted" bot \
  "$(jq -r '.[] | select(.author == "pipeline-user[bot]") | .authorKind' <<<"$github_pat_comments")"

github_app_comments="$(
  (
    _generate_jwt() {
      printf 'jwt-%s\n' "$1"
    }
    curl() {
      printf '%s\n' "$*" >> "$WORK/github-app-curl-calls"
      case "$*" in
        *jwt-101*) printf '%s\n' '{"slug":"pipeline-dev"}' ;;
        *jwt-102*) printf '%s\n' '{"slug":"pipeline-review"}' ;;
        *) return 1 ;;
      esac
    }
    gh() {
      printf '%s\n' "$*" >> "$WORK/github-app-api-calls"
      if [[ "${1:-} ${2:-}" == "api --paginate" ]]; then
        printf '%s\n' '[[{"id":1,"user":{"login":"pipeline-dev[bot]","type":"Bot"},"body":"dev","created_at":"2026-07-18T04:00:00Z"},{"id":2,"user":{"login":"pipeline-review[bot]","type":"Bot"},"body":"review","created_at":"2026-07-18T04:00:01Z"},{"id":3,"user":{"login":"dependabot[bot]","type":"Bot"},"body":"other","created_at":"2026-07-18T04:00:02Z"},{"id":4,"user":{"login":"operator","type":"User"},"body":"human","created_at":"2026-07-18T04:00:03Z"},{"id":5,"user":{"login":"pipeline-dev","type":"User"},"body":"slug collision","created_at":"2026-07-18T04:00:04Z"}]]'
      else
        return 1
      fi
    }
    BOT_LOGIN="" GH_AUTH_MODE=app ITP_REQUIRE_SELF_AUTHOR=1 REPO=zxkane/autonomous-dev-team \
      DEV_AGENT_APP_ID=101 DEV_AGENT_APP_PEM='/tmp/dev|key.pem' \
      REVIEW_AGENT_APP_ID=102 REVIEW_AGENT_APP_PEM=/tmp/review.pem \
      DISPATCHER_APP_ID="" DISPATCHER_APP_PEM=""
    export BOT_LOGIN GH_AUTH_MODE ITP_REQUIRE_SELF_AUTHOR REPO \
      DEV_AGENT_APP_ID DEV_AGENT_APP_PEM REVIEW_AGENT_APP_ID REVIEW_AGENT_APP_PEM \
      DISPATCHER_APP_ID DISPATCHER_APP_PEM
    # shellcheck disable=SC1090
    source "$GITHUB_PROVIDER"
    itp_github_list_comments 515
  )
)"
assert_eq "TC-TERMCTRL-017 GitHub App dev actor is trusted" self \
  "$(jq -r '.[] | select(.author == "pipeline-dev[bot]") | .authorKind' <<<"$github_app_comments")"
assert_eq "TC-TERMCTRL-017 GitHub App cross-role actor is trusted" self \
  "$(jq -r '.[] | select(.author == "pipeline-review[bot]") | .authorKind' <<<"$github_app_comments")"
assert_eq "TC-TERMCTRL-018 unrelated GitHub App remains untrusted" bot \
  "$(jq -r '.[] | select(.author == "dependabot[bot]") | .authorKind' <<<"$github_app_comments")"
assert_eq "TC-TERMCTRL-018 GitHub App human remains untrusted" human \
  "$(jq -r '.[] | select(.author == "operator") | .authorKind' <<<"$github_app_comments")"
assert_eq "TC-TERMCTRL-018 human matching an App slug remains untrusted" human \
  "$(jq -r '.[] | select(.author == "pipeline-dev") | .authorKind' <<<"$github_app_comments")"
assert_eq "TC-TERMCTRL-017 GitHub App comment read uses no token identity endpoint" \
  "api --paginate --slurp repos/zxkane/autonomous-dev-team/issues/515/comments" \
  "$(cat "$WORK/github-app-api-calls")"
assert_eq "TC-TERMCTRL-017 configured GitHub Apps resolve exactly" 2 \
  "$(grep -c 'https://api.github.com/app' "$WORK/github-app-curl-calls")"

gitlab_pat_comments="$(
  (
    _gl_api() {
      if [[ "${*: -1}" == "/user" ]]; then
        printf '%s\n' '{"username":"pipeline-user"}'
      else
        printf '%s\n' '[{"id":1,"system":false,"author":{"username":"pipeline-user"},"body":"own","created_at":"2026-07-18T04:00:00Z"},{"id":2,"system":false,"author":{"username":"pipeline-review"},"body":"review","created_at":"2026-07-18T04:00:01Z"},{"id":3,"system":false,"author":{"username":"project_2_bot"},"body":"other","created_at":"2026-07-18T04:00:02Z"}]'
      fi
    }
    BOT_LOGIN="" GITLAB_PROJECT=group%2Frepo ITP_REQUIRE_SELF_AUTHOR=1 \
      TERMINAL_CONTROL_TRUSTED_AUTHORS=pipeline-review
    export BOT_LOGIN GITLAB_PROJECT ITP_REQUIRE_SELF_AUTHOR TERMINAL_CONTROL_TRUSTED_AUTHORS
    # shellcheck disable=SC1090
    source "$GITLAB_PROVIDER"
    itp_gitlab_list_comments 515
  )
)"
assert_eq "TC-TERMCTRL-017 GitLab PAT actor resolves as self" self \
  "$(jq -r '.[] | select(.author == "pipeline-user") | .authorKind' <<<"$gitlab_pat_comments")"
assert_eq "TC-TERMCTRL-017 configured GitLab cross-role actor resolves as self" self \
  "$(jq -r '.[] | select(.author == "pipeline-review") | .authorKind' <<<"$gitlab_pat_comments")"
assert_eq "TC-TERMCTRL-018 unrelated GitLab access-token bot remains bot" bot \
  "$(jq -r '.[] | select(.author == "project_2_bot") | .authorKind' <<<"$gitlab_pat_comments")"

echo ""
echo "== TC-TERMCTRL-020..030: owner-aware transitions =="
reset_store
set_labels autonomous pending-dev
assert_rc "TC-TERMCTRL-020 pending-dev stalls" 0 \
  "$(run_rc stall_from_pending 515 pending-dev cap-a)"
assert_contains "TC-TERMCTRL-020 atomic transition argv" \
  'transition|515|pending-dev|stalled' "$(cat "$CALLS")"
if has_label autonomous; then
  pass "TC-TERMCTRL-029 autonomous preserved"
else
  fail "TC-TERMCTRL-029 autonomous preserved"
fi
if has_label stalled; then
  pass "TC-TERMCTRL-020 stalled present"
else
  fail "TC-TERMCTRL-020 stalled present"
fi

reset_store
set_labels autonomous pending-review
assert_rc "TC-TERMCTRL-021 pending-review stalls" 0 \
  "$(run_rc stall_from_pending 515 pending-review cap-a)"
assert_eq "TC-TERMCTRL-021 one transition" 1 "$(transition_count)"

reset_store
set_labels autonomous in-progress
assert_rc "TC-TERMCTRL-022 in-progress stalls" 0 \
  "$(run_rc stall_from_active 515 in-progress cap-a)"
reset_store
set_labels autonomous reviewing
assert_rc "TC-TERMCTRL-023 reviewing stalls" 0 \
  "$(run_rc stall_from_active 515 reviewing cap-a)"

reset_store
set_labels autonomous stalled
assert_rc "TC-TERMCTRL-024 already stalled is success" 0 \
  "$(run_rc stall_from_active 515 reviewing cap-a)"
assert_eq "TC-TERMCTRL-024 already stalled has no mutation" 0 "$(transition_count)"

reset_store
set_labels autonomous pending-review
assert_rc "TC-TERMCTRL-025 wrong owner fails" 1 \
  "$(run_rc stall_from_pending 515 pending-dev cap-a)"
assert_eq "TC-TERMCTRL-025 wrong owner has no mutation" 0 "$(transition_count)"
before="$(grep -c '^read|' "$CALLS" 2>/dev/null || true)"
assert_rc "TC-TERMCTRL-026 invalid pending state fails" 1 \
  "$(run_rc stall_from_pending 515 reviewing cap-a)"
assert_rc "TC-TERMCTRL-026 invalid active state fails" 1 \
  "$(run_rc stall_from_active 515 pending-dev cap-a)"
assert_eq "TC-TERMCTRL-026 invalid state does not read labels" "$before" \
  "$(grep -c '^read|' "$CALLS" 2>/dev/null || true)"
assert_rc "TC-TERMCTRL-026 pending arity is set-u safe" 1 \
  "$(run_rc stall_from_pending)"
assert_rc "TC-TERMCTRL-026 pending invalid issue fails" 1 \
  "$(run_rc stall_from_pending nope pending-dev cap-a)"
assert_rc "TC-TERMCTRL-026 pending invalid intent fails" 1 \
  "$(run_rc stall_from_pending 515 pending-dev 'bad intent')"
assert_rc "TC-TERMCTRL-026 active arity is set-u safe" 1 \
  "$(run_rc stall_from_active)"
assert_rc "TC-TERMCTRL-026 active invalid issue fails" 1 \
  "$(run_rc stall_from_active nope in-progress cap-a)"
assert_rc "TC-TERMCTRL-026 active invalid intent fails" 1 \
  "$(run_rc stall_from_active 515 in-progress 'bad intent')"

reset_store
touch "$WORK/fail-read"
assert_rc "TC-TERMCTRL-027 label read failure is loud" 1 \
  "$(run_rc stall_from_active 515 in-progress cap-a)"
assert_eq "TC-TERMCTRL-027 read failure has no mutation" 0 "$(transition_count)"
rm -f "$WORK/fail-read"
printf '{"bad":true}\n' > "$LABELS"
assert_rc "TC-TERMCTRL-027 malformed labels are loud" 1 \
  "$(run_rc stall_from_active 515 in-progress cap-a)"

reset_store
touch "$WORK/fail-transition"
assert_rc "TC-TERMCTRL-028 transition failure propagates" 1 \
  "$(run_rc stall_from_active 515 in-progress cap-a)"
assert_eq "TC-TERMCTRL-028 attempted exactly one transition" 1 "$(transition_count)"
assert_eq "TC-TERMCTRL-030 mark_stalled never invoked" 0 \
  "$(grep -c '^mark_stalled|' "$CALLS" 2>/dev/null || true)"

echo ""
echo "== TC-TERMCTRL-040..050: cleanup override =="
reset_store
terminal_intent_write 515 dev-cap inv-v1-dev token-cap dev-wrapper >/dev/null
: > "$CALLS"
assert_rc "TC-TERMCTRL-040 dev intent cleanup succeeds" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress,pending-dev pending-review)"
assert_contains "TC-TERMCTRL-040 routes active owner to stalled" \
  'transition|515|in-progress|stalled' "$(cat "$CALLS")"
assert_contains "TC-TERMCTRL-040 consumes after transition" \
  'resource-terminal-intent-consume-v1: issue=515 intent=dev-cap invocation=inv-v1-dev' \
  "$(cat "$CALLS")"
assert_eq "TC-TERMCTRL-040 read empty after consume" "" "$(intent_read 515)"

reset_store
set_labels autonomous reviewing
terminal_intent_write 515 review-cap inv-v1-review turn-cap review-wrapper >/dev/null
: > "$CALLS"
assert_rc "TC-TERMCTRL-041 review intent cleanup succeeds" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 reviewing reviewing pending-dev)"
assert_contains "TC-TERMCTRL-041 review routes to stalled" \
  'transition|515|reviewing|stalled' "$(cat "$CALLS")"

reset_store
assert_rc "TC-TERMCTRL-042 no-intent PR route succeeds" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress,pending-dev pending-review)"
assert_contains "TC-TERMCTRL-042 original pending-review argv unchanged" \
  'transition|515|in-progress,pending-dev|pending-review' "$(cat "$CALLS")"
assert_eq "TC-TERMCTRL-042 marker-free route adds no label read" 0 \
  "$(grep -c '^read|' "$CALLS" 2>/dev/null || true)"

reset_store
assert_rc "TC-TERMCTRL-043 no-intent retry route succeeds" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_contains "TC-TERMCTRL-043 original pending-dev argv unchanged" \
  'transition|515|in-progress|pending-dev' "$(cat "$CALLS")"

reset_store
set_labels autonomous reviewing
assert_rc "TC-TERMCTRL-044 review no-intent route succeeds" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 reviewing reviewing pending-dev)"
assert_contains "TC-TERMCTRL-044 review pending-dev argv unchanged" \
  'transition|515|reviewing|pending-dev' "$(cat "$CALLS")"

reset_store
terminal_intent_write 515 consumed inv-v1-c token-cap dev-wrapper >/dev/null
terminal_intent_consume 515 consumed >/dev/null
: > "$CALLS"
assert_rc "TC-TERMCTRL-045 consumed intent takes normal route" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_contains "TC-TERMCTRL-045 normal route after consume" \
  'transition|515|in-progress|pending-dev' "$(cat "$CALLS")"

reset_store
terminal_intent_write 515 cleared inv-v1-c token-cap dispatcher >/dev/null
terminal_intent_clear 515 cleared operator >/dev/null
: > "$CALLS"
assert_rc "TC-TERMCTRL-046 cleared intent takes normal route" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_contains "TC-TERMCTRL-046 normal route after clear" \
  'transition|515|in-progress|pending-dev' "$(cat "$CALLS")"

reset_store
touch "$WORK/fail-list"
assert_rc "TC-TERMCTRL-047 unreadable authority fails closed" 1 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-047 no pending mutation" 0 "$(transition_count)"

reset_store
set_labels autonomous reviewing
terminal_intent_write 515 raced inv-v1-r token-cap dev-wrapper >/dev/null
: > "$CALLS"
assert_rc "TC-TERMCTRL-048 wrong active owner fails" 1 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-048 race has no mutation" 0 "$(transition_count)"
assert_eq "TC-TERMCTRL-048 race leaves intent live" raced \
  "$(intent_read 515 | jq -r '.intent')"

reset_store
terminal_intent_write 515 replay inv-v1-r token-cap dev-wrapper >/dev/null
: > "$CALLS"
FAIL_POST_KIND=consume
assert_rc "TC-TERMCTRL-049 consume failure propagates" 1 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-049 transition landed once" 1 "$(transition_count)"
assert_eq "TC-TERMCTRL-049 intent remains live" replay \
  "$(intent_read 515 | jq -r '.intent')"
unset FAIL_POST_KIND
assert_rc "TC-TERMCTRL-049 re-entry consumes from stalled" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-049 re-entry makes no second transition" 1 "$(transition_count)"
assert_eq "TC-TERMCTRL-049 replay converges consumed" "" "$(intent_read 515)"

reset_store
terminal_intent_write 515 retry inv-v1-t token-cap dev-wrapper >/dev/null
: > "$CALLS"
touch "$WORK/fail-transition"
assert_rc "TC-TERMCTRL-050 transition failure propagates" 1 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-050 consume not posted" 0 "$(post_count)"
rm -f "$WORK/fail-transition"
assert_eq "TC-TERMCTRL-050 failed transition leaves intent live" retry \
  "$(intent_read 515 | jq -r '.intent')"

reset_store
assert_rc "TC-TERMCTRL-051 cleanup arity is set-u safe" 1 \
  "$(run_rc terminal_intent_cleanup_transition)"
assert_rc "TC-TERMCTRL-051 cleanup target domain is enforced" 1 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress stalled)"
touch "$WORK/fail-transition"
assert_rc "TC-TERMCTRL-051 normal-route transition failure propagates" 1 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-051 failed normal route has one attempted mutation" 1 "$(transition_count)"

reset_store
terminal_intent_write 515 replay-done inv-v1-done token-cap dev-wrapper >/dev/null
: > "$CALLS"
assert_rc "TC-TERMCTRL-052 first cleanup stalls and consumes" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_rc "TC-TERMCTRL-052 repeated cleanup is idempotent" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-052 repeated cleanup makes one total transition" 1 "$(transition_count)"
assert_eq "TC-TERMCTRL-052 consumed stalled intent stays unreadable" "" "$(intent_read 515)"
if has_label stalled && ! has_label pending-dev && ! has_label pending-review; then
  pass "TC-TERMCTRL-052 consumed terminal decision cannot resurrect pending"
else
  fail "TC-TERMCTRL-052 consumed terminal decision cannot resurrect pending"
fi

reset_store
terminal_intent_write 515 cleanup-race inv-v1-old token-cap dev-wrapper >/dev/null
: > "$CALLS"
INJECT_GENERATION_AFTER_STALL=1
assert_rc "TC-TERMCTRL-053 cleanup generation race succeeds" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_contains "TC-TERMCTRL-053 cleanup consumes the generation it read" \
  'resource-terminal-intent-consume-v1: issue=515 intent=cleanup-race invocation=inv-v1-old' \
  "$(cat "$CALLS")"
assert_eq "TC-TERMCTRL-053 newer generation is not consumed by stale cleanup" inv-v1-new \
  "$(intent_read 515 | jq -r '.invocation')"

reset_store
terminal_intent_write 515 clear-race inv-v1-clear-race token-cap dev-wrapper >/dev/null
: > "$CALLS"
INJECT_CLEAR_BEFORE_CONSUME=1
assert_rc "TC-TERMCTRL-054 clear during stall-then-consume cleanup succeeds" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-054 clear lands before the racing stale consume" \
  "clear,consume" \
  "$(jq -r '
      [.[].body
       | if startswith("<!-- resource-terminal-intent-clear-v1: issue=515 intent=clear-race ")
         then "clear"
         elif startswith("<!-- resource-terminal-intent-consume-v1: issue=515 intent=clear-race ")
         then "consume"
         else empty
         end]
      | join(",")
    ' "$COMMENTS")"
events="$(_terminal_control_events "$(cat "$COMMENTS")")"
assert_rc "TC-TERMCTRL-054 clear remains authoritative over stale consume" 0 \
  "$(run_rc _terminal_control_intent_is_cleared \
    "$events" 515 clear-race inv-v1-clear-race)"
assert_rc "TC-TERMCTRL-054 cleared stalled cleanup re-entry succeeds" 0 \
  "$(run_rc terminal_intent_cleanup_transition 515 in-progress in-progress pending-dev)"
assert_eq "TC-TERMCTRL-054 re-entry makes no pending transition" 1 "$(transition_count)"
assert_eq "TC-TERMCTRL-054 clear race converges to autonomous stalled" \
  '["autonomous","stalled"]' "$(jq -c . "$LABELS")"

echo ""
echo "== TC-TERMCTRL-070..073: source and coverage pins =="
dev_cleanup="$(awk '/^cleanup\(\)/,/^trap cleanup EXIT/' "$DEV_WRAPPER")"
review_cleanup="$(awk '/^cleanup\(\)/,/^trap cleanup EXIT/' "$REVIEW_WRAPPER")"
# shellcheck disable=SC2016  # Source pins intentionally contain literal shell variables.
dev_pr_guard='terminal_intent_cleanup_transition "$ISSUE_NUMBER" "in-progress" "in-progress,pending-dev" "pending-review"'
# shellcheck disable=SC2016
dev_retry_guard='terminal_intent_cleanup_transition "$ISSUE_NUMBER" "in-progress" "in-progress" "pending-dev"'
# shellcheck disable=SC2016
review_retry_guard='terminal_intent_cleanup_transition "$ISSUE_NUMBER" "reviewing" "reviewing" "pending-dev"'
assert_eq "TC-TERMCTRL-070 dev cleanup has no unguarded pending transition" 0 \
  "$(grep -Ec 'itp_transition_state .*pending-(dev|review)' <<<"$dev_cleanup" || true)"
assert_eq "TC-TERMCTRL-070 review cleanup has no unguarded pending transition" 0 \
  "$(grep -Ec 'itp_transition_state .*pending-(dev|review)' <<<"$review_cleanup" || true)"
assert_eq "TC-TERMCTRL-070 dev cleanup has five guarded routes" 5 \
  "$(grep -c 'terminal_intent_cleanup_transition' <<<"$dev_cleanup" || true)"
assert_eq "TC-TERMCTRL-070 review cleanup has one guarded route" 1 \
  "$(grep -c 'terminal_intent_cleanup_transition' <<<"$review_cleanup" || true)"
assert_eq "TC-TERMCTRL-070 dev PR route keeps exact owner/remove/target argv" 1 \
  "$(grep -Fc "$dev_pr_guard" <<<"$dev_cleanup" || true)"
assert_eq "TC-TERMCTRL-070 dev retry routes keep exact owner/remove/target argv" 3 \
  "$(grep -Fc "$dev_retry_guard" <<<"$dev_cleanup" || true)"
assert_eq "TC-TERMCTRL-070 review route keeps exact owner/remove/target argv" 1 \
  "$(grep -Fc "$review_retry_guard" <<<"$review_cleanup" || true)"

mark_body_sha="$(awk '/^mark_stalled\(\)/,/^}/' "$DISPATCH_LIB" | sha256sum | awk '{print $1}')"
assert_eq "TC-TERMCTRL-071 mark_stalled body byte pin" \
  "1f3d2ee9cbb9be5ee94f29ce8e2ddbf802937ea36b5f892c8901a5d56c39b4b6" "$mark_body_sha"
call_site_sha="$(
  {
    grep -E '^[[:space:]]*mark_stalled([[:space:]]|$)' "$DISPATCH_LIB"
    grep -E '^[[:space:]]*mark_stalled([[:space:]]|$)' "$TICK"
  } | sha256sum | awk '{print $1}'
)"
assert_eq "TC-TERMCTRL-071 mark_stalled call-site byte pin" \
  "7995afd1c6891a9f7e67442f571886b7bdf13690092153a76e7cb733ac12d378" "$call_site_sha"

raw_calls="$(grep -En '(^|[;&|[:space:]])(gh|glab)([[:space:]]|$)|https?://|graphql' "$LIB" || true)"
assert_eq "TC-TERMCTRL-072 no raw provider calls" "" "$raw_calls"

terminal_transition_ids="$(
  jq -r '
    [.transitions[]
     | select(.id | startswith("resource-terminal-intent-stall-"))
     | .id] | sort | join(",")
  ' "$TRANSITIONS"
)"
assert_eq "TC-TERMCTRL-074 all owner-aware movements are declared" \
  "resource-terminal-intent-stall-in-progress,resource-terminal-intent-stall-pending-dev,resource-terminal-intent-stall-pending-review,resource-terminal-intent-stall-reviewing" \
  "$terminal_transition_ids"
assert_eq "TC-TERMCTRL-074 every terminal-control transition is code-site mapped" 4 \
  "$(jq '[.code_sites | to_entries[] | select(.key | startswith("resource-terminal-intent-stall-"))] | length' "$CODESITE_MAP")"
assert_eq "TC-TERMCTRL-074 every terminal-control transition uses its local stalled guard" 4 \
  "$(jq '[.transitions[]
          | select(.id | startswith("resource-terminal-intent-stall-"))
          | select(.guards | index("terminal-control-not-already-stalled"))] | length' "$TRANSITIONS")"
assert_eq "TC-TERMCTRL-074 local stalled guard maps to terminal control" \
  "lib-terminal-control.sh|index(\"stalled\") != null" \
  "$(jq -r '.guards."terminal-control-not-already-stalled" | [.file,.pattern] | join("|")' "$GUARD_MAP")"
assert_contains "TC-TERMCTRL-074 spec drift scans terminal-control writes" \
  "lib-terminal-control.sh" "$(grep '^PIPELINE_FILES=' "$SPEC_CHECKER")"

if [[ "${TERMINAL_CONTROL_COVERAGE_CHILD:-0}" != "1" ]]; then
  trace="$WORK/coverage.trace"
  child_out="$WORK/coverage.out"
  exec {trace_fd}>"$trace"
  TERMINAL_CONTROL_COVERAGE_CHILD=1 BASH_XTRACEFD="$trace_fd" \
    PS4='+${BASH_SOURCE}:${LINENO}:' bash -x "$0" >"$child_out" 2>&1
  child_rc=$?
  exec {trace_fd}>&-
  assert_rc "TC-TERMCTRL-073 traced test child succeeds" 0 "$child_rc"

  inventory="$SCRIPT_DIR/fixtures/lib-terminal-control-branch-inventory.tsv"
  inventory_total=0
  inventory_covered=0
  inventory_bad=0
  declare -A inventory_ids=()
  while IFS='|' read -r branch_id branch_status test_id description; do
    [[ -n "$branch_id" && "${branch_id:0:1}" != "#" ]] || continue
    inventory_total=$((inventory_total + 1))
    if [[ -n "${inventory_ids[$branch_id]:-}" ]]; then
      printf '      duplicate branch inventory id: %s\n' "$branch_id"
      inventory_bad=$((inventory_bad + 1))
    fi
    inventory_ids[$branch_id]=1

    source_hits="$(grep -nF "terminal-control-branch: $branch_id" "$LIB" || true)"
    source_hit_count="$(grep -cF "terminal-control-branch: $branch_id" "$LIB" || true)"
    if [[ "$source_hit_count" != "1" ]]; then
      printf '      branch %s has %s source markers: %s\n' \
        "$branch_id" "$source_hit_count" "$description"
      inventory_bad=$((inventory_bad + 1))
      continue
    fi
    source_line="${source_hits%%:*}"
    branch_executed=0
    grep -Fq "${LIB}:${source_line}:" "$trace" && branch_executed=1

    case "$branch_status" in
      covered)
        inventory_covered=$((inventory_covered + 1))
        if [[ "$test_id" == "-" ]] || ! grep -RqsF --include='*.sh' "$test_id" \
          "$PROJECT_ROOT/tests/unit" "$PROJECT_ROOT/tests/e2e"; then
          printf '      covered branch %s references missing test id %s: %s\n' \
            "$branch_id" "$test_id" "$description"
          inventory_bad=$((inventory_bad + 1))
        fi
        if [[ "$branch_executed" -ne 1 ]]; then
          printf '      covered branch %s did not execute: %s\n' "$branch_id" "$description"
          inventory_bad=$((inventory_bad + 1))
        fi
        ;;
      uncovered)
        if [[ "$test_id" != "-" ]]; then
          printf '      uncovered branch %s must use test id -: %s\n' "$branch_id" "$description"
          inventory_bad=$((inventory_bad + 1))
        fi
        if [[ "$branch_executed" -eq 1 ]]; then
          printf '      uncovered branch %s executed and must be promoted: %s\n' \
            "$branch_id" "$description"
          inventory_bad=$((inventory_bad + 1))
        fi
        ;;
      *)
        printf '      invalid branch status %s for %s\n' "$branch_status" "$branch_id"
        inventory_bad=$((inventory_bad + 1))
        ;;
    esac
  done < "$inventory"

  source_marker_ids="$(grep -oE 'terminal-control-branch: B[0-9]+' "$LIB" | awk '{print $2}' | sort -u)"
  source_marker_total="$(wc -l <<<"$source_marker_ids" | tr -d ' ')"
  while IFS= read -r source_id; do
    [[ -n "$source_id" ]] || continue
    if [[ -z "${inventory_ids[$source_id]:-}" ]]; then
      printf '      source marker %s is missing from the branch inventory\n' "$source_id"
      inventory_bad=$((inventory_bad + 1))
    fi
  done <<<"$source_marker_ids"

  assert_eq "TC-TERMCTRL-073 source-anchored branch inventory has no errors" \
    0 "$inventory_bad"
  assert_eq "TC-TERMCTRL-073 inventory accounts for every source marker" \
    "$source_marker_total" "$inventory_total"
  if [[ "$inventory_total" -gt 0 && "$inventory_covered" -gt $((inventory_total * 80 / 100)) ]]; then
    pass "TC-TERMCTRL-073 semantic branch coverage ${inventory_covered}/${inventory_total} is >80%"
  else
    fail "TC-TERMCTRL-073 semantic branch coverage ${inventory_covered}/${inventory_total} is not >80%"
  fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
