#!/bin/bash
# run-verdict-artifact-fleet-e2e.sh — E2E for the verdict-artifact channel
# (issue #233, INV-78). TC-VERDICT-ARTIFACT-037.
#
# WHAT IT DOES
# ------------
# Drives a 3-stub review fleet through the REAL verdict-artifact resolution +
# comment-fallback + INV-40 aggregation libs — end to end, hermetically (no
# network, no agent CLIs). The three stubs cover the issue's mandated matrix:
#
#   agent-A: writes a VALID PASS artifact   → resolved from the artifact
#   agent-B: writes a MALFORMED artifact    → loud envelope + treated absent (drop)
#   agent-C: writes NO artifact but posts a PASS comment → comment-fallback
#
# Asserted end to end:
#   1. the AGGREGATE verdict (A pass + B drop + C pass → pass);
#   2. the per-agent verdict SOURCES (drop reasons): artifact / artifact-malformed
#      / comment-fallback;
#   3. the malformed agent triggered exactly one loud error envelope naming it;
#   4. the comment fallback was consulted ONLY for the no-artifact agent (the
#      valid-artifact agent did ZERO comment polls — the AC).
#
# This is the #233 E2E artifact: it sources the production libs
# (lib-review-artifact.sh / lib-review-poll.sh / lib-review-aggregate.sh) and
# reproduces the wrapper's resolution control flow against staged artifact files
# and a stubbed comment fetcher, so CI runs it on bare ubuntu. The issue #526
# extension invokes lib-review-claude.sh's exact production fan-out mutation and
# post-poll fallback functions; those two branches are not reproduced in the
# fixture.
#
# Run: bash tests/e2e/run-verdict-artifact-fleet-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISP="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
EXAMPLES="$PROJECT_ROOT/docs/pipeline/schemas/examples"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

for f in lib-review-artifact.sh lib-review-aggregate.sh lib-review-poll.sh; do
  [[ -f "$DISP/$f" ]] || { echo -e "${RED}FATAL${NC}: $f missing"; exit 1; }
done

export VERDICT_ARTIFACT_SCHEMA="$PROJECT_ROOT/docs/pipeline/schemas/verdict-artifact.schema.json"
# shellcheck source=/dev/null
source "$DISP/lib-review-artifact.sh"
# shellcheck source=/dev/null
source "$DISP/lib-review-aggregate.sh"
# shellcheck source=/dev/null
source "$DISP/lib-review-poll.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== TC-VERDICT-ARTIFACT-037: 4-stub fleet (valid / malformed / absent-with-comment / foreign-identity) ==="

# --- fleet state (mirrors the wrapper globals) -----------------------------
#   A: valid PASS artifact with MATCHING identity        → resolved from artifact
#   B: malformed artifact                                → loud envelope + drop
#   C: NO artifact, posts a PASS comment                 → comment-fallback
#   D: schema-valid artifact but FOREIGN runId/agent      → rejected (malformed)
#      ([P1] #2, #233 review — a copied/foreign artifact must NOT vote)
AGENT_NAMES=(agent-A agent-B agent-C agent-D)
AGENT_SESSION_IDS=(sid-A sid-B sid-C sid-D)
AGENT_ARTIFACT_PATHS=()
declare -A AGENT_LAUNCH_RC=()
COMMENT_FETCH_COUNT=0
ENVELOPE_COUNT=0
ENVELOPE_TEXT=""

# A valid PASS artifact whose runId/agent MATCH the slot the wrapper assigned.
mk_valid_pass() { # <path> <runId> <agent>
  printf '{"schema_version":1,"verdict":"PASS","blockingFindings":[],"runId":"%s","agent":"%s"}\n' "$2" "$3" > "$1"
}

for i in 0 1 2 3; do
  rid="${AGENT_SESSION_IDS[$i]}"
  p="$(XDG_STATE_HOME="$SANDBOX/state" _verdict_artifact_path proj "$rid" "${AGENT_NAMES[$i]}")"
  mkdir -p "$(dirname "$p")"
  AGENT_ARTIFACT_PATHS+=("$p")
  AGENT_LAUNCH_RC["$rid"]=0
done
mk_valid_pass "${AGENT_ARTIFACT_PATHS[0]}" "sid-A" "agent-A"            # A valid PASS, matching identity
cp "$EXAMPLES/verdict-artifact.negative.no-schema-version.json" "${AGENT_ARTIFACT_PATHS[1]}"  # B malformed
# C: no artifact file — only a posted comment (set in the stub below).
mk_valid_pass "${AGENT_ARTIFACT_PATHS[3]}" "FOREIGN-session" "other-agent"  # D schema-valid, FOREIGN identity

# Stub the comment fetcher (the fallback channel) + the loud-envelope surfacer.
# The fetcher runs inside the poll loop's `$(…)` command substitution (a
# subshell), so a shell-variable counter would not propagate — record each fetch
# to a FILE and count its lines afterward.
COMMENT_FETCH_LOG="$SANDBOX/comment-fetches.log"; : > "$COMMENT_FETCH_LOG"
declare -A STUB_COMMENT=( ["agent-C"]="Review PASSED - looks good
Review Agent: agent-C" )
_fetch_agent_verdict_body() {
  printf '%s\n' "$1" >> "$COMMENT_FETCH_LOG"
  printf '%s' "${STUB_COMMENT[$1]:-}"
}
log() { :; }
error_surface() {
  ENVELOPE_COUNT=$((ENVELOPE_COUNT + 1))
  ENVELOPE_TEXT+="${3:-} "   # $3 = the problem string (names the agent)
  return 0
}

# --- resolution control flow (mirrors autonomous-review.sh, INV-78) --------
AGENT_VERDICTS=("" "" "" "")
AGENT_VERDICT_BODIES=("" "" "" "")
AGENT_VERDICT_SOURCES=("" "" "" "")

# Artifact-first pass — passes the per-agent EXPECTED identity (session id + agent
# name), exactly as autonomous-review.sh does, so a foreign-identity artifact (D)
# is rejected as malformed rather than casting a vote.
for i in "${!AGENT_NAMES[@]}"; do
  out=$(_classify_verdict_artifact "${AGENT_ARTIFACT_PATHS[$i]}" "${AGENT_SESSION_IDS[$i]}" "${AGENT_NAMES[$i]}")
  st="${out%%$'\n'*}"
  case "$st" in
    valid)
      v=$(_verdict_from_artifact_json "${out#*$'\n'}")
      AGENT_VERDICTS[$i]="$v"; AGENT_VERDICT_SOURCES[$i]="artifact" ;;
    malformed)
      AGENT_VERDICT_SOURCES[$i]="artifact-malformed"
      error_surface "0" "VERDICT_ARTIFACT_MALFORMED" \
        "Review agent '${AGENT_NAMES[$i]}' produced a malformed verdict artifact" ;;
  esac
done

# Comment fallback (skips resolved + malformed agents — production loop behavior).
_VERDICT_POLL_ATTEMPTS=1; _VERDICT_POLL_INTERVAL_SECONDS=0
_run_verdict_poll_loop
for i in "${!AGENT_NAMES[@]}"; do
  [[ -n "${AGENT_VERDICTS[$i]}" && -z "${AGENT_VERDICT_SOURCES[$i]}" ]] && AGENT_VERDICT_SOURCES[$i]="comment-fallback"
done

# Terminal sweep + aggregate.
for i in "${!AGENT_NAMES[@]}"; do
  [[ -n "${AGENT_VERDICTS[$i]}" ]] && continue
  AGENT_VERDICTS[$i]=$(_classify_noverdict_agent "${AGENT_LAUNCH_RC[${AGENT_SESSION_IDS[$i]}]:-1}")
done
AGG=$(_aggregate_review_verdicts "${AGENT_VERDICTS[@]}")

# --- assertions ------------------------------------------------------------
# A pass + B drop + C pass + D drop → 2 deciding PASS → pass.
[[ "$AGG" == "pass" ]] && ok "aggregate verdict = pass (A pass + B drop + C pass + D drop)" \
  || bad "aggregate verdict expected=pass actual=$AGG"

[[ "${AGENT_VERDICT_SOURCES[0]}" == "artifact" ]] && ok "agent-A source = artifact (matching identity)" \
  || bad "agent-A source expected=artifact actual=${AGENT_VERDICT_SOURCES[0]}"
[[ "${AGENT_VERDICT_SOURCES[1]}" == "artifact-malformed" ]] && ok "agent-B source = artifact-malformed" \
  || bad "agent-B source expected=artifact-malformed actual=${AGENT_VERDICT_SOURCES[1]}"
[[ "${AGENT_VERDICT_SOURCES[2]}" == "comment-fallback" ]] && ok "agent-C source = comment-fallback" \
  || bad "agent-C source expected=comment-fallback actual=${AGENT_VERDICT_SOURCES[2]}"
# [P1] #2: agent-D's artifact is schema-VALID but its runId/agent are foreign →
# rejected as artifact-malformed (NOT a silent vote for this slot).
[[ "${AGENT_VERDICT_SOURCES[3]}" == "artifact-malformed" ]] && ok "agent-D (foreign identity) rejected as artifact-malformed (NOT a vote) [P1]#2" \
  || bad "agent-D source expected=artifact-malformed actual=${AGENT_VERDICT_SOURCES[3]}"
[[ "${AGENT_VERDICTS[3]}" == "unavailable" ]] && ok "agent-D (foreign identity) dropped from the vote (unavailable)" \
  || bad "agent-D expected=unavailable actual=${AGENT_VERDICTS[3]}"

[[ "${AGENT_VERDICTS[1]}" == "unavailable" ]] && ok "agent-B (malformed) dropped from the vote (unavailable, Clause V1)" \
  || bad "agent-B expected=unavailable actual=${AGENT_VERDICTS[1]}"

# Two loud envelopes: the malformed artifact (B) AND the foreign-identity one (D).
[[ "$ENVELOPE_COUNT" -eq 2 ]] && ok "two loud error envelopes emitted (malformed B + foreign-identity D)" \
  || bad "envelope count expected=2 actual=$ENVELOPE_COUNT"
[[ "$ENVELOPE_TEXT" == *"agent-B"* && "$ENVELOPE_TEXT" == *"agent-D"* ]] && ok "envelopes name both the malformed (agent-B) and foreign-identity (agent-D) agents" \
  || bad "envelopes did not name both agent-B and agent-D: [$ENVELOPE_TEXT]"

# Only agent-C (no artifact) reached the comment fallback. A=valid → skipped;
# B,D=malformed → skipped (Clause V1). So exactly ONE agent (agent-C) was polled.
COMMENT_FETCH_COUNT=$(wc -l < "$COMMENT_FETCH_LOG" | tr -d ' ')
[[ "$COMMENT_FETCH_COUNT" -eq 1 ]] && ok "comment fallback consulted for exactly 1 agent (the no-artifact agent)" \
  || bad "comment fetch count expected=1 actual=$COMMENT_FETCH_COUNT (valid+malformed agents must skip the poll)"
if grep -q '^agent-C$' "$COMMENT_FETCH_LOG" && ! grep -qE '^agent-(A|B|D)$' "$COMMENT_FETCH_LOG"; then
  ok "the polled agent was agent-C only (valid A + malformed B + foreign-identity D never comment-polled)"
else
  bad "wrong agent polled: $(tr '\n' ' ' < "$COMMENT_FETCH_LOG")"
fi

echo ""
echo "=== TC-REVIEW-VERDICT-PATH-035..036: permission-honoring Claude stub ==="

CLAUDE_LIB="$DISP/lib-review-claude.sh"
if [[ -r "$CLAUDE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$CLAUDE_LIB"
else
  bad "Claude review helper library exists"
fi

STUB_PROJECT="$SANDBOX/stub-project"
STUB_BIN="$SANDBOX/bin/claude"
mkdir -p "$STUB_PROJECT/scripts" "$(dirname "$STUB_BIN")"
ln -s "$DISP/write-verdict-artifact.sh" "$STUB_PROJECT/scripts/write-verdict-artifact.sh"
ln -s "$DISP/write-verdict-body.sh" "$STUB_PROJECT/scripts/write-verdict-body.sh"
cat > "$STUB_PROJECT/scripts/post-verdict.sh" <<'STUB_POST'
#!/bin/bash
set -euo pipefail
[[ "${STUB_POST_FAIL:-false}" != "true" ]] || exit 1
body="$(cat "$3")"
case "$2" in
  pass)
    [[ "$body" == Review\ PASSED* ]] || body="Review PASSED - ${body}"
    ;;
  fail)
    [[ "$body" == Review\ findings:* ]] || body="Review findings:
${body}"
    ;;
  *)
    exit 2
    ;;
esac
printf '%s\n' "$body" > "$STUB_POST_CAPTURE"
printf '%s\n' "$*" > "$STUB_POST_ARGS"
STUB_POST
chmod +x "$STUB_PROJECT/scripts/post-verdict.sh"

cat > "$STUB_BIN" <<'STUB_CLAUDE'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" > "$STUB_ARGV_CAPTURE"
if [[ "${STUB_EXPECT_INJECTION:-false}" == "true" ]]; then
  grep -Fxq -- '--add-dir' "$STUB_ARGV_CAPTURE"
  grep -Fxq -- "$(dirname "$VERDICT_ARTIFACT_PATH")" "$STUB_ARGV_CAPTURE"
  grep -Fxq -- "$(dirname "$VERDICT_BODY_FILE")" "$STUB_ARGV_CAPTURE"
  grep -Fxq -- 'Bash(bash scripts/write-verdict-artifact.sh:*)' "$STUB_ARGV_CAPTURE"
  grep -Fxq -- 'Bash(bash scripts/write-verdict-body.sh:*)' "$STUB_ARGV_CAPTURE"
  grep -Fxq -- 'Bash(bash scripts/post-verdict.sh:*)' "$STUB_ARGV_CAPTURE"

  cd "$STUB_PROJECT"
  printf '%s' 'All checklist items verified.' | bash scripts/write-verdict-body.sh
  printf '%s\n' \
    '{"schema_version":1,"verdict":"PASS","blockingFindings":[],"runId":"stub-sid","agent":"claude"}' \
    | bash scripts/write-verdict-artifact.sh
  bash scripts/post-verdict.sh 526 pass "$VERDICT_BODY_FILE" claude stub-sid sonnet
fi
jq -nc --arg result "${STUB_FINAL_RESULT:-Review PASSED - stub complete}" \
  '{type:"result",is_error:false,result:$result}'
exit "${STUB_EXIT_RC:-0}"
STUB_CLAUDE
chmod +x "$STUB_BIN"

run_permission_stub() {
  local mode="$1" expect="$2"
  local case_dir="$SANDBOX/stub-$mode"
  mkdir -p "$case_dir/artifact" "$case_dir/body"
  export VERDICT_ARTIFACT_PATH="$case_dir/artifact/verdict-claude.json"
  export VERDICT_BODY_FILE="$case_dir/body/verdict.md"
  export STUB_ARGV_CAPTURE="$case_dir/argv"
  export STUB_POST_CAPTURE="$case_dir/posted-body"
  export STUB_POST_ARGS="$case_dir/posted-args"
  export STUB_EXPECT_INJECTION="$expect"
  export STUB_FINAL_RESULT="Review PASSED - stub complete"
  export STUB_EXIT_RC=0
  export STUB_POST_FAIL=false
  export STUB_PROJECT
  REVIEW_CLAUDE_PERMISSION_INJECTION=true
  local dev_args="--operator-flag before-injection"
  local review_args="$dev_args"
  _claude_review_apply_permission_injection \
    claude "$mode" "$VERDICT_ARTIFACT_PATH" \
    "$(dirname "$VERDICT_BODY_FILE")" dev_args review_args
  local -a stub_argv=()
  eval "stub_argv=($dev_args)"
  "$STUB_BIN" "${stub_argv[@]}" > "$case_dir/stream.jsonl"
}

if declare -F _claude_review_apply_permission_injection >/dev/null 2>&1 \
    && run_permission_stub auto true; then
  [[ -s "$SANDBOX/stub-auto/posted-body" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-035 auto stub executed body write + post-verdict" \
    || bad "TC-REVIEW-VERDICT-PATH-035 body/post sequence did not execute"
  [[ -s "$SANDBOX/stub-auto/artifact/verdict-claude.json" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-035 auto stub atomically wrote the artifact" \
    || bad "TC-REVIEW-VERDICT-PATH-035 artifact sequence did not execute"
  auto_artifact=$(_classify_verdict_artifact \
    "$SANDBOX/stub-auto/artifact/verdict-claude.json" stub-sid claude)
  [[ "${auto_artifact%%$'\n'*}" == "valid" \
      && "$(_classify_verdict_body "$(cat "$SANDBOX/stub-auto/posted-body")")" == "pass" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-035 full sequence produced valid artifact and post-verdict channels" \
    || bad "TC-REVIEW-VERDICT-PATH-035 full sequence did not produce valid verdict channels"
  if _claude_final_text_fallback_eligible claude 0 "" pass \
      "$(cat "$SANDBOX/stub-auto/posted-body")"; then
    bad "TC-REVIEW-VERDICT-PATH-035 resolved report unexpectedly remained fallback-eligible"
  else
    ok "TC-REVIEW-VERDICT-PATH-035 full reporting sequence needs no final-text fallback"
  fi
else
  bad "TC-REVIEW-VERDICT-PATH-035 auto stub accepted and executed injected grants"
fi

if declare -F _claude_review_apply_permission_injection >/dev/null 2>&1 \
    && run_permission_stub bypassPermissions false; then
  if ! grep -Fq -- '--add-dir' "$SANDBOX/stub-bypassPermissions/argv" \
      && ! grep -Fq -- '--allowedTools' "$SANDBOX/stub-bypassPermissions/argv"; then
    ok "TC-REVIEW-VERDICT-PATH-036 bypassPermissions stub received no injection"
  else
    bad "TC-REVIEW-VERDICT-PATH-036 bypassPermissions unexpectedly received injection"
  fi
else
  bad "TC-REVIEW-VERDICT-PATH-036 bypassPermissions stub completed"
fi

echo ""
echo "=== TC-REVIEW-VERDICT-PATH-033,037..041: final-text fallback fleet ==="

run_finaltext_stub() {
  local case_name="$1" result="$2" requested_rc="$3"
  local case_dir="$SANDBOX/fallback-$case_name"
  mkdir -p "$case_dir/artifact" "$case_dir/body"
  export VERDICT_ARTIFACT_PATH="$case_dir/artifact/verdict-claude.json"
  export VERDICT_BODY_FILE="$case_dir/body/verdict.md"
  export STUB_ARGV_CAPTURE="$case_dir/argv"
  export STUB_POST_CAPTURE="$case_dir/posted-body"
  export STUB_POST_ARGS="$case_dir/posted-args"
  export STUB_EXPECT_INJECTION=false
  export STUB_FINAL_RESULT="$result"
  export STUB_EXIT_RC="$requested_rc"
  export STUB_POST_FAIL=false
  local actual_rc=0
  "$STUB_BIN" --permission-mode auto --output-format stream-json \
    > "$case_dir/stream.jsonl" || actual_rc=$?
  printf '%s\n' "$actual_rc"
}

fallback_stub_resolve() {
  local case_name="$1" agent="$2" rc="$3" source="$4" log_file="$5"
  local post_fail="${6:-false}"
  local case_dir="$SANDBOX/fallback-$case_name"
  export STUB_POST_CAPTURE="$case_dir/posted-body"
  export STUB_POST_ARGS="$case_dir/posted-args"
  export STUB_POST_FAIL="$post_fail"
  SCRIPT_DIR="$STUB_PROJECT/scripts"
  ISSUE_NUMBER=526
  AGENT_NAMES=("$agent")
  AGENT_SESSION_IDS=(stub-sid)
  AGENT_CONTROLLER_LOGS=("$log_file")
  AGENT_VERDICTS=("")
  AGENT_VERDICT_BODIES=("")
  AGENT_VERDICT_SOURCES=("$source")
  AGENT_LAUNCH_RC=([stub-sid]="$rc")
  log() { :; }
  _append_run_footer_to_file() { :; }
  _resolve_review_agent_model() { printf 'sonnet\n'; }
  _fetch_agent_verdict_body() {
    [[ -s "$STUB_POST_CAPTURE" ]] && cat "$STUB_POST_CAPTURE"
  }

  _claude_apply_final_text_fallback 0
  FALLBACK_VERDICT="${AGENT_VERDICTS[0]:-}"
  FALLBACK_SOURCE="${AGENT_VERDICT_SOURCES[0]:-}"
  if [[ -z "$FALLBACK_VERDICT" ]]; then
    FALLBACK_VERDICT="$(_classify_noverdict_agent "$rc")"
  fi
}

if declare -F _claude_apply_final_text_fallback >/dev/null 2>&1; then
  REVIEW_FINAL_TEXT_VERDICT_FALLBACK=true
  pass_rc=$(run_finaltext_stub pass "Review PASSED - complete" 0)
  fallback_stub_resolve pass claude "$pass_rc" "" "$SANDBOX/fallback-pass/stream.jsonl"
  [[ "$FALLBACK_VERDICT:$FALLBACK_SOURCE" == "pass:claude-finaltext-fallback" ]] \
      && [[ "$(_classify_verdict_body "$(cat "$SANDBOX/fallback-pass/posted-body")")" == "pass" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-037 rc0 stub PASS posts and resolves via final text" \
    || bad "TC-REVIEW-VERDICT-PATH-037 got $FALLBACK_VERDICT:$FALLBACK_SOURCE"

  fail_rc=$(run_finaltext_stub fail $'Review findings:\n1. [P1] defect' 0)
  fallback_stub_resolve fail claude "$fail_rc" "" "$SANDBOX/fallback-fail/stream.jsonl"
  [[ "$FALLBACK_VERDICT:$FALLBACK_SOURCE" == "fail:claude-finaltext-fallback" ]] \
      && [[ "$(_classify_verdict_body "$(cat "$SANDBOX/fallback-fail/posted-body")")" == "fail" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-038 rc0 stub FAIL posts and resolves via final text" \
    || bad "TC-REVIEW-VERDICT-PATH-038 got $FALLBACK_VERDICT:$FALLBACK_SOURCE"

  none_rc=$(run_finaltext_stub none "The review is complete." 0)
  fallback_stub_resolve none claude "$none_rc" "" "$SANDBOX/fallback-none/stream.jsonl"
  [[ "$FALLBACK_VERDICT" == "unavailable" \
      && ! -e "$SANDBOX/fallback-none/posted-body" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-039 ambiguous final text stays unavailable" \
    || bad "TC-REVIEW-VERDICT-PATH-039 got $FALLBACK_VERDICT"

  timeout_rc=$(run_finaltext_stub timeout "Review PASSED - partial" 124)
  fallback_stub_resolve timeout claude "$timeout_rc" "" \
    "$SANDBOX/fallback-timeout/stream.jsonl"
  [[ "$timeout_rc" == "124" && "$FALLBACK_VERDICT" == "timed-out" \
      && ! -e "$SANDBOX/fallback-timeout/posted-body" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-040 rc124 anchored text stays timed-out" \
    || bad "TC-REVIEW-VERDICT-PATH-040 got $FALLBACK_VERDICT"

  malformed_rc=$(run_finaltext_stub malformed "Review PASSED - ignored" 0)
  fallback_stub_resolve malformed claude "$malformed_rc" artifact-malformed \
    "$SANDBOX/fallback-malformed/stream.jsonl"
  [[ "$FALLBACK_VERDICT:$FALLBACK_SOURCE" == "unavailable:artifact-malformed" \
      && ! -e "$SANDBOX/fallback-malformed/posted-body" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-041 malformed artifact refuses final-text rescue" \
    || bad "TC-REVIEW-VERDICT-PATH-041 got $FALLBACK_VERDICT:$FALLBACK_SOURCE"

  post_fail_rc=$(run_finaltext_stub post-fail "Review PASSED - cannot post" 0)
  fallback_stub_resolve post-fail claude "$post_fail_rc" "" \
    "$SANDBOX/fallback-post-fail/stream.jsonl" true
  [[ "$FALLBACK_VERDICT:$FALLBACK_SOURCE" == "unavailable:" \
      && ! -e "$SANDBOX/fallback-post-fail/posted-body" ]] \
    && ok "TC-REVIEW-VERDICT-PATH-033 failed wrapper post leaves member unavailable" \
    || bad "TC-REVIEW-VERDICT-PATH-033 got $FALLBACK_VERDICT:$FALLBACK_SOURCE"
else
  bad "Claude production final-text fallback seam is defined"
fi

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
