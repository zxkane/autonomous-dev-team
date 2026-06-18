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
# and a stubbed comment fetcher, so CI runs it on bare ubuntu.
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
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
