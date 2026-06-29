#!/bin/bash
# test-review-classify.sh — INV-92 / issue #298.
#
# Unit tests for the per-finding actionability classification:
#   1. lib-review-classify.sh — review_path_is_protected,
#      agent_token_has_workflow_scope, review_classify_artifact_dev_actionable.
#   2. lib-review-artifact.sh jq validator — accepts the five INV-92 finding
#      fields with valid types, rejects a bad enum / non-boolean, still accepts a
#      legacy {title}-only finding. PINNED to the jq path (the packaged-skill
#      default; the schema file lives outside the skill tree).
#
# Run: bash tests/unit/test-review-classify.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISP="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
CLASSIFY_LIB="$DISP/lib-review-classify.sh"
ART_LIB="$DISP/lib-review-artifact.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

# assert_rc — run a command, assert its exit code.
assert_rc() {
  local desc="$1" expected_rc="$2"; shift 2
  "$@"
  local rc=$?
  if [[ "$rc" == "$expected_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$rc, expected $expected_rc)"
    FAIL=$((FAIL + 1))
  fi
}

[[ -f "$CLASSIFY_LIB" ]] || { echo "ERROR: $CLASSIFY_LIB not found" >&2; exit 1; }
[[ -f "$ART_LIB" ]] || { echo "ERROR: $ART_LIB not found" >&2; exit 1; }

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-classify.sh
source "$CLASSIFY_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-artifact.sh
source "$ART_LIB"
set +e

# ---------------------------------------------------------------------------
echo "=== review_path_is_protected (default REVIEW_PROTECTED_PATHS) ==="
# ---------------------------------------------------------------------------
# Default list is the one the lib's `:=` set when sourced (no override here).
assert_rc "workflows file .github/workflows/ci.yml → protected (rc 0)" 0 \
  review_path_is_protected ".github/workflows/ci.yml"
assert_rc "nested workflows .github/workflows/sub/deploy.yml → protected (rc 0)" 0 \
  review_path_is_protected ".github/workflows/sub/deploy.yml"
assert_rc "root CODEOWNERS → protected (rc 0)" 0 \
  review_path_is_protected "CODEOWNERS"
assert_rc ".github/CODEOWNERS → protected (rc 0)" 0 \
  review_path_is_protected ".github/CODEOWNERS"
assert_rc "ordinary src/foo.ts → NOT protected (rc 1)" 1 \
  review_path_is_protected "src/foo.ts"
assert_rc "empty path → NOT protected (rc 1)" 1 \
  review_path_is_protected ""
assert_rc "a path merely mentioning workflows → NOT protected (rc 1)" 1 \
  review_path_is_protected "docs/workflows-guide.md"

# Sourcing must not have left extglob altered for the caller. Probe state.
shopt -q extglob; _eg_after=$?
assert_eq "review_path_is_protected restores caller extglob state (expect default off)" "1" "$_eg_after"

# Operator override is honored (the lib's `:=` does not clobber a set value).
echo "--- override REVIEW_PROTECTED_PATHS ---"
( export REVIEW_PROTECTED_PATHS="infra/** Makefile"
  source "$CLASSIFY_LIB"
  review_path_is_protected "infra/prod/main.tf" && echo "ovr-infra:0" || echo "ovr-infra:1"
  review_path_is_protected "Makefile"          && echo "ovr-make:0"  || echo "ovr-make:1"
  review_path_is_protected ".github/workflows/ci.yml" && echo "ovr-wf:0" || echo "ovr-wf:1"
) > /tmp/ovr-$$.out 2>&1
assert_eq "override: infra/prod/main.tf protected"        "ovr-infra:0" "$(grep -o 'ovr-infra:[01]' /tmp/ovr-$$.out)"
assert_eq "override: Makefile protected"                  "ovr-make:0"  "$(grep -o 'ovr-make:[01]'  /tmp/ovr-$$.out)"
assert_eq "override drops default workflows (not in list)" "ovr-wf:1"   "$(grep -o 'ovr-wf:[01]'    /tmp/ovr-$$.out)"
rm -f /tmp/ovr-$$.out

# ---------------------------------------------------------------------------
echo ""
echo "=== agent_token_has_workflow_scope ==="
# ---------------------------------------------------------------------------
AGENT_TOKEN_PERMISSIONS='{"contents":"write","issues":"write","pull_requests":"read"}'
assert_rc "default perms (no workflows) → rc 1 (lacks scope)" 1 \
  agent_token_has_workflow_scope
AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
assert_rc "perms with workflows → rc 0 (has scope)" 0 \
  agent_token_has_workflow_scope
AGENT_TOKEN_PERMISSIONS=''
assert_rc "empty perms var → rc 1 (fail-open: lacks scope)" 1 \
  agent_token_has_workflow_scope
AGENT_TOKEN_PERMISSIONS='not json {'
assert_rc "invalid JSON perms → rc 1 (fail-open)" 1 \
  agent_token_has_workflow_scope
unset AGENT_TOKEN_PERMISSIONS
assert_rc "unset perms var → rc 1 (fail-open)" 1 \
  agent_token_has_workflow_scope

# ---------------------------------------------------------------------------
echo ""
echo "=== review_classify_artifact_dev_actionable (aggregate derivation) ==="
# ---------------------------------------------------------------------------
# A blocking finding marked non-actionable, the only one → aggregate false.
J_ALL_NONACT='{"verdict":"FAIL","blockingFindings":[{"title":"edit ci.yml","actionable_by_dev_agent":false}]}'
assert_eq "single non-actionable blocking finding → false" "false" \
  "$(review_classify_artifact_dev_actionable "$J_ALL_NONACT")"

# Mixed: one actionable + one not → aggregate true (a dev-resume can still progress).
J_MIXED='{"verdict":"FAIL","blockingFindings":[{"title":"edit ci.yml","actionable_by_dev_agent":false},{"title":"fix bug","actionable_by_dev_agent":true}]}'
assert_eq "mixed (one actionable) → true" "true" \
  "$(review_classify_artifact_dev_actionable "$J_MIXED")"

# A normal blocking finding with the field ABSENT → effective true (legacy default).
J_LEGACY='{"verdict":"FAIL","blockingFindings":[{"title":"fix bug"}]}'
assert_eq "blocking finding, field absent → true (legacy default)" "true" \
  "$(review_classify_artifact_dev_actionable "$J_LEGACY")"

# Explicit actionable true → true.
J_ACT='{"verdict":"FAIL","blockingFindings":[{"title":"fix bug","actionable_by_dev_agent":true}]}'
assert_eq "explicit actionable true → true" "true" \
  "$(review_classify_artifact_dev_actionable "$J_ACT")"

# No blocking findings (PASS or empty) → true (fail-open, never diverts).
J_PASS='{"verdict":"PASS","blockingFindings":[]}'
assert_eq "no blocking findings → true (fail-open)" "true" \
  "$(review_classify_artifact_dev_actionable "$J_PASS")"

# Malformed / non-JSON input → true (fail-open, never invent non-actionable).
assert_eq "non-JSON input → true (fail-open)" "true" \
  "$(review_classify_artifact_dev_actionable "not json at all")"

# Two non-actionable, zero actionable → false.
J_TWO_NONACT='{"verdict":"FAIL","blockingFindings":[{"title":"ci.yml","actionable_by_dev_agent":false},{"title":"CODEOWNERS","actionable_by_dev_agent":false}]}'
assert_eq "all blocking non-actionable → false" "false" \
  "$(review_classify_artifact_dev_actionable "$J_TWO_NONACT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== jq validator accepts the 5 INV-92 fields / rejects bad ones (JQ PATH) ==="
# ---------------------------------------------------------------------------
# Force the jq structural backend: _validate_verdict_artifact_jq is the
# packaged-skill default (schema file lives outside the skill tree). We call it
# DIRECTLY so the test pins the jq path regardless of python availability.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mk() { printf '%s' "$2" > "$TMP/$1.json"; }
jq_valid() { _validate_verdict_artifact_jq "$TMP/$1.json" && echo valid || echo malformed; }

# All five fields, valid types/enum → valid.
mk five-fields '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"x","actionable_by_dev_agent":false,"requires_human":true,"requires_privileged_token":true,"blocking_for_merge":true,"recommended_next_owner":"maintainer"}],"runId":"r","agent":"a"}'
assert_eq "jq accepts a finding with all 5 INV-92 fields (valid types/enum)" "valid" "$(jq_valid five-fields)"

# recommended_next_owner each valid enum value.
for owner in dev_agent human maintainer; do
  mk "owner-$owner" "{\"schema_version\":1,\"verdict\":\"FAIL\",\"blockingFindings\":[{\"title\":\"x\",\"recommended_next_owner\":\"$owner\"}],\"runId\":\"r\",\"agent\":\"a\"}"
  assert_eq "jq accepts recommended_next_owner=$owner" "valid" "$(jq_valid "owner-$owner")"
done

# Bad enum value → malformed.
mk owner-banana '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"x","recommended_next_owner":"banana"}],"runId":"r","agent":"a"}'
assert_eq "jq REJECTS recommended_next_owner=\"banana\" → malformed" "malformed" "$(jq_valid owner-banana)"

# Non-boolean actionable_by_dev_agent → malformed.
mk act-string '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"x","actionable_by_dev_agent":"yes"}],"runId":"r","agent":"a"}'
assert_eq "jq REJECTS actionable_by_dev_agent:\"yes\" (non-boolean) → malformed" "malformed" "$(jq_valid act-string)"

# Non-boolean requires_human → malformed.
mk rh-number '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"x","requires_human":1}],"runId":"r","agent":"a"}'
assert_eq "jq REJECTS requires_human:1 (non-boolean) → malformed" "malformed" "$(jq_valid rh-number)"

# Legacy {title}-only finding still accepted (zero-regression).
mk legacy-title '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"just a title"}],"runId":"r","agent":"a"}'
assert_eq "jq still accepts a legacy {title}-only finding" "valid" "$(jq_valid legacy-title)"

# A still-unknown extra key is still rejected (additionalProperties:false intact).
mk extra-key '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"x","frobnicate":true}],"runId":"r","agent":"a"}'
assert_eq "jq still REJECTS an unknown finding key (additionalProperties:false intact)" "malformed" "$(jq_valid extra-key)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
