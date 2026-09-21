#!/bin/bash
# Regression coverage for the shared dev/review blocking policy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/skills/autonomous-dispatcher/scripts/lib-review-severity.sh"
source "$ROOT/skills/autonomous-dispatcher/scripts/lib-review-artifact.sh"
source "$ROOT/skills/autonomous-dispatcher/scripts/lib-review-classify.sh"
source "$ROOT/skills/autonomous-dispatcher/scripts/adapters/codex.sh"

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s (expected %s, got %s)\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}
blocks() { shouldBlockFinding "$1" "$2" && echo yes || echo no; }

unset REVIEW_BLOCKING_SEVERITY
for round in 1 2 3 4 5 20; do
  for severity in P0 P1 none invalid ''; do
    assert_eq yes "$(blocks "$round" "$severity")" "default $severity round $round"
  done
  for severity in P2 P3; do
    assert_eq no "$(blocks "$round" "$severity")" "default $severity round $round"
  done
done
for threshold in P1 P2 P3; do
  export REVIEW_BLOCKING_SEVERITY="$threshold"
  for round in 1 5 20; do
    for rank in 0 1 2 3; do
      expected=no
      if (( rank <= ${threshold#P} )); then expected=yes; fi
      assert_eq "$expected" "$(blocks "$round" "P$rank")" "$threshold P$rank round $round"
    done
  done
done

REVIEW_BLOCKING_SEVERITY=adaptive
assert_eq yes "$(blocks 1 P3)" 'adaptive first round'
assert_eq no "$(blocks 3 P3)" 'adaptive third round'
assert_eq yes "$(blocks 4 P2)" 'adaptive fourth round'
assert_eq no "$(blocks 5 P2)" 'adaptive fifth round'
assert_eq yes "$(blocks malformed P3)" 'adaptive malformed round'
assert_eq false "$(_review_cap_has_blocking_fail fail P2)" 'adaptive cap terminal floor'
REVIEW_BLOCKING_SEVERITY=P2
assert_eq true "$(_review_cap_has_blocking_fail fail P2)" 'fixed P2 cannot loop without cap'
assert_eq false "$(_review_cap_has_blocking_fail pass P2 timed-out none)" 'cap requires real blocking verdict'
REVIEW_BLOCKING_SEVERITY=P3
assert_eq true "$(_review_cap_has_blocking_fail fail P3)" 'fixed P3 cannot loop without cap'
REVIEW_BLOCKING_SEVERITY=invalid
assert_eq yes "$(blocks 20 P3 2>/dev/null)" 'invalid config is strict'

unset REVIEW_BLOCKING_SEVERITY
assert_eq pass "$(_review_apply_severity_filter fail '1. [P2] narrow gap' 1)" 'default text verdict'
assert_eq fail "$(_review_apply_severity_filter fail $'1. [P3] test gap\n2. untagged finding' 1)" 'untagged finding still blocks'
assert_eq timed-out "$(_review_apply_severity_filter timed-out '[P3] gap' 1)" 'timeout not demoted'
artifact='{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"test gap","severity":"P3"}],"runId":"r","agent":"a"}'
body="$(_verdict_body_from_artifact_json "$artifact")"
assert_eq pass "$(_review_apply_severity_filter fail "$body" 1)" 'artifact path shares threshold'
filtered="$(_review_apply_artifact_policy "$artifact" 1)"
assert_eq PASS "$(jq -r .verdict <<<"$filtered")" 'artifact normalized verdict'
assert_eq 0 "$(jq '.blockingFindings | length' <<<"$filtered")" 'artifact clears advisory blockers'
assert_eq P3 "$(jq -r '.nonBlockingFindings[0].severity' <<<"$filtered")" 'artifact retains advisory severity'
mixed='{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"maintainer fix","severity":"P1","actionable_by_dev_agent":false,"requires_human":true},{"title":"optional cleanup","severity":"P3","actionable_by_dev_agent":true}],"runId":"r","agent":"a"}'
filtered="$(_review_apply_artifact_policy "$mixed" 1)"
assert_eq FAIL "$(jq -r .verdict <<<"$filtered")" 'mixed artifact still fails'
assert_eq false "$(review_classify_artifact_dev_actionable "$filtered")" 'advisory cannot cause dev redispatch'
mixed_failed_ac="$(jq '.evidence.acCoverage = {"AC-2":"fail"}' <<<"$mixed")"
mixed_filtered="$(_review_apply_artifact_policy "$mixed_failed_ac" 1)"
assert_eq FAIL "$(jq -r .verdict <<<"$mixed_filtered")" 'mixed failed evidence still blocks'
assert_eq false "$(review_classify_artifact_dev_actionable "$mixed_filtered")" 'failed evidence does not retain unrelated dev advisories'
body="$(_verdict_body_from_artifact_json "$filtered")"
[[ "$body" == *'Non-blocking advisories:'* && "$body" == *'optional cleanup'* ]]
assert_eq P1 "$(_review_extract_highest_severity "$body")" 'mixed rendered severity'
untagged='{"verdict":"FAIL","blockingFindings":[{"title":"unclassified"},{"title":"cleanup","severity":"P3"}]}'
assert_eq FAIL "$(_review_apply_artifact_policy "$untagged" 1 | jq -r .verdict)" 'untagged artifact remains blocking'
failed_ac='{"verdict":"FAIL","blockingFindings":[{"title":"missing requirement","severity":"P2"}],"evidence":{"acCoverage":{"AC-2":"fail"}}}'
assert_eq FAIL "$(_review_apply_artifact_policy "$failed_ac" 1 | jq -r .verdict)" 'mandatory AC failure vetoes demotion'
failed_e2e='{"verdict":"PASS","evidence":{"e2eReport":{"gate":"fail"}}}'
assert_eq FAIL "$(_review_apply_artifact_policy "$failed_e2e" 1 | jq -r .verdict)" 'typed E2E failure vetoes PASS'
untagged='{"verdict":"FAIL","blockingFindings":[{"title":"Quoted [P3] must not supply missing severity"}]}'
filtered="$(_review_apply_artifact_policy "$untagged" 1)"
assert_eq none "$(_review_artifact_highest_severity "$filtered")" 'artifact prose is not severity metadata'
assert_eq P1 "$(_review_artifact_highest_severity "$failed_ac")" 'mandatory verification counts toward cap'

# Execute the production pre-aggregation loop: typed artifact verdicts must
# never be rescored from quoted tags in their human-facing rendering.
WRAPPER="$ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
for artifact in "$untagged" "$failed_ac"; do
  filtered="$(_review_apply_artifact_policy "$artifact" 1)"
  AGENT_NAMES=(reviewer)
  AGENT_VERDICT_SOURCES=(artifact)
  AGENT_VERDICTS=(fail)
  AGENT_ARTIFACT_SEVERITIES=("$(_review_artifact_highest_severity "$filtered")")
  AGENT_VERDICT_BODIES=("$(_verdict_body_from_artifact_json "$filtered")")
  AGENT_CODEX_LOGS=('')
  REVIEW_ROUND=1
  log() { :; }
  # shellcheck source=/dev/null
  source <(awk '/^_any_severity_demotion=false/ {active=1} /^# Aggregate under/ {active=0} active' "$WRAPPER")
  assert_eq fail "${AGENT_VERDICTS[0]}" 'wrapper preserves typed blocking verdict'
  assert_eq "${AGENT_ARTIFACT_SEVERITIES[0]}" "${AGENT_HIGHEST_SEVERITY[0]}" 'wrapper preserves typed severity'
done

fixture="$ROOT/tests/unit/fixtures/codex-review-stdout-turns-p2-only.txt"
tail_text="$(_codex_review_strip_prompt_echo "$fixture")"
region="$(_codex_review_full_response_region "$fixture")"
assert_eq pass "$(_review_apply_severity_filter_corroborated fail "$tail_text" "$region" 1)" 'codex default first round'
assert_eq fail "$(_review_apply_severity_filter_corroborated fail '[P3] gap' '[P1] blocker' 1)" 'codex hidden P1'
REVIEW_BLOCKING_SEVERITY=P2
assert_eq fail "$(_review_apply_severity_filter_corroborated fail '[P3] gap' '[P2] blocker' 20)" 'codex hidden configured P2'
assert_eq P2 "$(_review_highest_severity_corroborated '[P3] gap' '[P2] blocker' 20)" 'codex reports blocking P2'

unset REVIEW_BLOCKING_SEVERITY
prompt="$(_review_severity_prompt_block 1)"
[[ "$prompt" == *'Only P0 and P1 block'* ]]
[[ "$prompt" == *'nonBlockingFindings'* ]]
dev_prompt="$(_dev_delivery_policy_prompt_block 1)"
[[ "$dev_prompt" == *'P1'* && "$dev_prompt" == *'before pushing'* ]]
[[ "$dev_prompt" == *'non-blocking'* && "$dev_prompt" == *'same HEAD'* ]]
echo 'PASS: shared blocking policy, artifacts, codex corroboration, and prompts'
