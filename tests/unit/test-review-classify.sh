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

# Operator override is honored (the lib's `${VAR-default}` does not clobber a set value).
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
echo "=== REVIEW_PROTECTED_PATHS override plumbing (issue #301) ==="
# ---------------------------------------------------------------------------
# Defect 2: the lib's default-assignment must distinguish UNSET (apply default)
# from EXPLICIT-EMPTY (no protected paths). It now uses `${VAR-default}` (no colon),
# so `REVIEW_PROTECTED_PATHS=""` means "nothing protected" — the conf doc's promised
# "set to \"\" to disable protection" — while an unset var still defaults (fail-safe).

# TC-301-01 (regression / fail-safe): unset ⇒ the default list applies. Run in a
# subshell with the var fully unset, then re-source the lib so its assignment fires.
( unset REVIEW_PROTECTED_PATHS
  source "$CLASSIFY_LIB"
  review_path_is_protected ".github/workflows/ci.yml" && echo "uns-wf:0" || echo "uns-wf:1"
  review_path_is_protected "CODEOWNERS"               && echo "uns-co:0" || echo "uns-co:1"
  review_path_is_protected "src/foo.ts"               && echo "uns-src:0" || echo "uns-src:1"
) > /tmp/uns-$$.out 2>&1
assert_eq "unset ⇒ default list protects .github/workflows/ci.yml" "uns-wf:0" "$(grep -o 'uns-wf:[01]'  /tmp/uns-$$.out)"
assert_eq "unset ⇒ default list protects CODEOWNERS"               "uns-co:0" "$(grep -o 'uns-co:[01]'  /tmp/uns-$$.out)"
assert_eq "unset ⇒ ordinary src/foo.ts not protected"             "uns-src:1" "$(grep -o 'uns-src:[01]' /tmp/uns-$$.out)"
rm -f /tmp/uns-$$.out

# TC-301-02: explicit empty ⇒ NOTHING protected (incl. the former defaults).
( export REVIEW_PROTECTED_PATHS=""
  source "$CLASSIFY_LIB"
  review_path_is_protected ".github/workflows/ci.yml" && echo "emp-wf:0" || echo "emp-wf:1"
  review_path_is_protected "CODEOWNERS"               && echo "emp-co:0" || echo "emp-co:1"
  review_path_is_protected "src/foo.ts"               && echo "emp-src:0" || echo "emp-src:1"
) > /tmp/emp-$$.out 2>&1
assert_eq "explicit empty ⇒ .github/workflows/ci.yml NOT protected" "emp-wf:1"  "$(grep -o 'emp-wf:[01]'  /tmp/emp-$$.out)"
assert_eq "explicit empty ⇒ CODEOWNERS NOT protected"               "emp-co:1"  "$(grep -o 'emp-co:[01]'  /tmp/emp-$$.out)"
assert_eq "explicit empty ⇒ src/foo.ts NOT protected"               "emp-src:1" "$(grep -o 'emp-src:[01]' /tmp/emp-$$.out)"
rm -f /tmp/emp-$$.out

# TC-301-03: explicit empty ⇒ a protected-path finding is dev-actionable again
# (no path is protected, so the legacy "absent ⇒ true" default applies).
( export REVIEW_PROTECTED_PATHS=""
  source "$CLASSIFY_LIB"
  review_classify_artifact_dev_actionable \
    '{"verdict":"FAIL","blockingFindings":[{"title":"edit ci.yml","file":".github/workflows/ci.yml"}]}'
) > /tmp/empagg-$$.out 2>&1
assert_eq "explicit empty ⇒ aggregate on a .github/workflows finding → true (nothing protected)" \
  "true" "$(cat /tmp/empagg-$$.out)"
rm -f /tmp/empagg-$$.out

# TC-301-04: custom override ⇒ only the override matches; the default workflows path
# is no longer protected.
( export REVIEW_PROTECTED_PATHS="custom/**"
  source "$CLASSIFY_LIB"
  review_path_is_protected "custom/foo"               && echo "cus-c:0" || echo "cus-c:1"
  review_path_is_protected ".github/workflows/ci.yml" && echo "cus-wf:0" || echo "cus-wf:1"
) > /tmp/cus-$$.out 2>&1
assert_eq "custom override protects custom/foo"                    "cus-c:0"  "$(grep -o 'cus-c:[01]'  /tmp/cus-$$.out)"
assert_eq "custom override drops default .github/workflows/ci.yml" "cus-wf:1" "$(grep -o 'cus-wf:[01]' /tmp/cus-$$.out)"
rm -f /tmp/cus-$$.out

# ---------------------------------------------------------------------------
echo ""
echo "=== review_protected_paths_prompt_rule (prompt built from \$REVIEW_PROTECTED_PATHS, issue #301) ==="
# ---------------------------------------------------------------------------
# Defect 1: the review-agent classification PROMPT must be generated from the SAME
# $REVIEW_PROTECTED_PATHS the lib matcher reads — not a hardcoded literal. The wrapper
# interpolates `$(review_protected_paths_prompt_rule)` into build_review_prompt.

# TC-301-05: a custom override is reflected verbatim in the prompt; the rule no longer
# hardcodes the default `.github/workflows/`/`CODEOWNERS` literal as the protected set.
PR_CUSTOM="$( REVIEW_PROTECTED_PATHS="custom/**" bash -c 'source "$1"; review_protected_paths_prompt_rule' _ "$CLASSIFY_LIB" )"
case "$PR_CUSTOM" in
  *"custom/**"*) echo "  PASS: prompt rule advertises the custom override verbatim"; PASS=$((PASS+1));;
  *) echo "  FAIL: prompt rule missing custom/** override"; echo "      got: $PR_CUSTOM"; FAIL=$((FAIL+1));;
esac
case "$PR_CUSTOM" in
  *".github/workflows/**"*|*"CODEOWNERS"*)
    echo "  FAIL: prompt rule still hardcodes the default protected literal under a custom override"; FAIL=$((FAIL+1));;
  *) echo "  PASS: prompt rule does not hardcode the default list under a custom override"; PASS=$((PASS+1));;
esac

# TC-301-06: explicit empty ⇒ the prompt advertises NO protected paths.
PR_EMPTY="$( REVIEW_PROTECTED_PATHS="" bash -c 'source "$1"; review_protected_paths_prompt_rule' _ "$CLASSIFY_LIB" )"
case "$PR_EMPTY" in
  *"NO protected paths"*)
    echo "  PASS: empty list ⇒ prompt advertises NO protected paths"; PASS=$((PASS+1));;
  *) echo "  FAIL: empty list ⇒ prompt should advertise NO protected paths"; echo "      got: $PR_EMPTY"; FAIL=$((FAIL+1));;
esac
# And it must NOT name a protected glob (no PROTECTED-PATH instruction at all).
case "$PR_EMPTY" in
  *"PROTECTED-PATH pattern"*)
    echo "  FAIL: empty list ⇒ prompt should NOT emit a protected-path matching rule"; FAIL=$((FAIL+1));;
  *) echo "  PASS: empty list ⇒ prompt emits no protected-path matching rule"; PASS=$((PASS+1));;
esac

# TC-301-07 (regression): unset ⇒ the prompt advertises the DEFAULT list (the same
# var the lib uses, via its `${VAR-default}` assignment).
PR_DEFAULT="$( unset REVIEW_PROTECTED_PATHS; bash -c 'source "$1"; review_protected_paths_prompt_rule' _ "$CLASSIFY_LIB" )"
case "$PR_DEFAULT" in
  *".github/workflows/**"*) echo "  PASS: unset ⇒ prompt advertises default .github/workflows/**"; PASS=$((PASS+1));;
  *) echo "  FAIL: unset ⇒ prompt missing default .github/workflows/**"; echo "      got: $PR_DEFAULT"; FAIL=$((FAIL+1));;
esac
case "$PR_DEFAULT" in
  *"CODEOWNERS"*) echo "  PASS: unset ⇒ prompt advertises default CODEOWNERS"; PASS=$((PASS+1));;
  *) echo "  FAIL: unset ⇒ prompt missing default CODEOWNERS"; echo "      got: $PR_DEFAULT"; FAIL=$((FAIL+1));;
esac

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
echo "=== authoritative protected-path override (INV-92: the wrapper re-validates, never trusts the field) ==="
# ---------------------------------------------------------------------------
# These pin the PR #300 review [P1]: the aggregate MUST consult
# review_path_is_protected over each finding's `file`, NOT only the agent-supplied
# `actionable_by_dev_agent` flag. A finding on a protected path is non-actionable
# even when the agent OMITS the flag or (mistakenly/maliciously) sets it true — so a
# protected-path finding can never forge dev-actionable=true and re-enter the loop.

# Protected path (.github/workflows/**), field ABSENT → effective false (the
# wrapper derives it from the path; the legacy "absent ⇒ true" default does NOT
# apply to a protected path). Sole blocking finding → aggregate false.
J_PROT_ABSENT='{"verdict":"FAIL","blockingFindings":[{"title":"edit ci.yml","file":".github/workflows/ci.yml"}]}'
assert_eq "protected path, field absent → false (wrapper-derived, not legacy true)" "false" \
  "$(review_classify_artifact_dev_actionable "$J_PROT_ABSENT")"

# Protected path with the agent ASSERTING actionable_by_dev_agent=true → the wrapper
# OVERRIDES it to false. This is the exact forge the [P1] is about.
J_PROT_FORGED='{"verdict":"FAIL","blockingFindings":[{"title":"edit ci.yml","file":".github/workflows/ci.yml","actionable_by_dev_agent":true}]}'
assert_eq "protected path, agent claims actionable=true → overridden to false" "false" \
  "$(review_classify_artifact_dev_actionable "$J_PROT_FORGED")"

# Nested workflow path, field absent → false (the ** glob matches sub-dirs).
J_PROT_NESTED='{"verdict":"FAIL","blockingFindings":[{"title":"deploy wf","file":".github/workflows/sub/deploy.yml"}]}'
assert_eq "nested protected path, field absent → false" "false" \
  "$(review_classify_artifact_dev_actionable "$J_PROT_NESTED")"

# CODEOWNERS (a protected literal), agent claims actionable=true → overridden false.
J_PROT_CODEOWNERS='{"verdict":"FAIL","blockingFindings":[{"title":"owners","file":"CODEOWNERS","actionable_by_dev_agent":true}]}'
assert_eq "CODEOWNERS, agent claims actionable=true → overridden to false" "false" \
  "$(review_classify_artifact_dev_actionable "$J_PROT_CODEOWNERS")"

# Mixed: one protected (forged true) + one genuinely actionable code finding →
# aggregate true (the dev agent CAN still make progress on the code finding).
J_PROT_MIXED='{"verdict":"FAIL","blockingFindings":[{"title":"edit ci.yml","file":".github/workflows/ci.yml","actionable_by_dev_agent":true},{"title":"fix bug","file":"src/foo.ts"}]}'
assert_eq "mixed protected(forged true) + actionable code → true" "true" \
  "$(review_classify_artifact_dev_actionable "$J_PROT_MIXED")"

# Ordinary code path with the agent (wrongly) claiming non-actionable → stays false
# (the wrapper does NOT promote a non-protected finding to actionable; the agent's
# explicit `false` is still honored — the override only flips protected→false, never
# the reverse).
J_CODE_FALSE='{"verdict":"FAIL","blockingFindings":[{"title":"fix bug","file":"src/foo.ts","actionable_by_dev_agent":false}]}'
assert_eq "ordinary path, agent says non-actionable → stays false (override never promotes)" "false" \
  "$(review_classify_artifact_dev_actionable "$J_CODE_FALSE")"

# Ordinary code path, field absent → true (legacy default preserved for non-protected).
J_CODE_ABSENT='{"verdict":"FAIL","blockingFindings":[{"title":"fix bug","file":"src/foo.ts"}]}'
assert_eq "ordinary path, field absent → true (legacy default preserved)" "true" \
  "$(review_classify_artifact_dev_actionable "$J_CODE_ABSENT")"

# A path merely MENTIONING workflows (docs) is NOT protected → field absent ⇒ true.
J_NEARMISS='{"verdict":"FAIL","blockingFindings":[{"title":"doc","file":"docs/workflows-guide.md"}]}'
assert_eq "near-miss path (docs/workflows-guide.md) not protected → true" "true" \
  "$(review_classify_artifact_dev_actionable "$J_NEARMISS")"

# Operator override of REVIEW_PROTECTED_PATHS is honored by the aggregate too: a
# finding on a path the operator added is non-actionable even with the field absent.
( export REVIEW_PROTECTED_PATHS="infra/**"
  source "$CLASSIFY_LIB"
  review_classify_artifact_dev_actionable \
    '{"verdict":"FAIL","blockingFindings":[{"title":"tf","file":"infra/prod/main.tf"}]}'
) > /tmp/aggovr-$$.out 2>&1
assert_eq "aggregate honors REVIEW_PROTECTED_PATHS override (infra/** → false)" "false" \
  "$(cat /tmp/aggovr-$$.out)"
rm -f /tmp/aggovr-$$.out

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
echo "=== INV-135 (#488) D1: capability-aware DEFAULT derivation ==="
# ---------------------------------------------------------------------------
# unset REVIEW_PROTECTED_PATHS in every case below. Re-source in a subshell per
# case so the top-of-file default assignment re-evaluates against the case's env.

# TC-INV134-D1-01: App mode + workflows scope present ⇒ default OMITS workflows.
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
  review_path_is_protected ".github/workflows/ci.yml" && echo "wf:0" || echo "wf:1"
  review_path_is_protected "CODEOWNERS" && echo "co:0" || echo "co:1"
) > /tmp/d1-01-$$.out 2>&1
assert_eq "TC-INV134-D1-01 default list omits workflows" "list=[CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-01-$$.out)"
assert_eq "TC-INV134-D1-01 workflows finding NOT protected" "wf:1" "$(grep -o 'wf:[01]' /tmp/d1-01-$$.out)"
assert_eq "TC-INV134-D1-01 CODEOWNERS still protected" "co:0" "$(grep -o 'co:[01]' /tmp/d1-01-$$.out)"
rm -f /tmp/d1-01-$$.out

# TC-INV134-D1-02: App mode, scope absent (default perms) ⇒ conservative default.
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","issues":"write","pull_requests":"read"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-02-$$.out 2>&1
assert_eq "TC-INV134-D1-02 scope absent ⇒ conservative default" \
  "list=[.github/workflows/** CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-02-$$.out)"
rm -f /tmp/d1-02-$$.out

# TC-INV134-D1-03: Token mode + workflows key present in the var (mode gate) ⇒
# conservative default retained (capability is not knowable outside App mode).
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=token
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-03-$$.out 2>&1
assert_eq "TC-INV134-D1-03 token mode ⇒ conservative default (mode gate)" \
  "list=[.github/workflows/** CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-03-$$.out)"
rm -f /tmp/d1-03-$$.out

# TC-INV134-D1-04: App mode, AGENT_TOKEN_PERMISSIONS empty ⇒ fail-closed.
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS=''
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-04-$$.out 2>&1
assert_eq "TC-INV134-D1-04 empty perms ⇒ fail-closed default" \
  "list=[.github/workflows/** CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-04-$$.out)"
rm -f /tmp/d1-04-$$.out

# TC-INV134-D1-05: App mode, malformed JSON ⇒ fail-closed.
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='not json {'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-05-$$.out 2>&1
assert_eq "TC-INV134-D1-05 malformed perms ⇒ fail-closed default" \
  "list=[.github/workflows/** CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-05-$$.out)"
rm -f /tmp/d1-05-$$.out

# TC-INV134-D1-06: App mode, AGENT_TOKEN_PERMISSIONS unset ⇒ fail-closed.
( unset REVIEW_PROTECTED_PATHS AGENT_TOKEN_PERMISSIONS
  export GH_AUTH_MODE=app
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-06-$$.out 2>&1
assert_eq "TC-INV134-D1-06 unset perms ⇒ fail-closed default" \
  "list=[.github/workflows/** CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-06-$$.out)"
rm -f /tmp/d1-06-$$.out

# TC-INV134-D1-07: GH_AUTH_MODE unset (GitLab / no App concept) + workflows key
# present ⇒ conservative default (mode gate — GitLab has no App equivalent).
( unset REVIEW_PROTECTED_PATHS GH_AUTH_MODE
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-07-$$.out 2>&1
assert_eq "TC-INV134-D1-07 GH_AUTH_MODE unset ⇒ conservative default" \
  "list=[.github/workflows/** CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-07-$$.out)"
rm -f /tmp/d1-07-$$.out

# TC-INV134-D1-08: App mode + workflows scope present in the var, but `jq` is
# UNAVAILABLE (command -v jq fails) ⇒ fail-closed default (agent_token_has_
# workflow_scope's own `command -v jq` guard, exercised via the D1 default
# derivation rather than only directly against agent_token_has_workflow_scope
# in isolation, as the earlier "agent_token_has_workflow_scope" test section
# above already does).
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  command() { [ "$1" = "-v" ] && [ "$2" = "jq" ] && return 1; builtin command "$@"; }
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-08-$$.out 2>&1
assert_eq "TC-INV134-D1-08 jq unavailable ⇒ fail-closed default" \
  "list=[.github/workflows/** CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-08-$$.out)"
rm -f /tmp/d1-08-$$.out

# TC-INV134-D1-14 (codex review round-1 finding #1): a pure GitLab run
# (CODE_HOST=gitlab) that RETAINS GH_AUTH_MODE=app and "workflows":"write" in
# AGENT_TOKEN_PERMISSIONS (a leftover/copy-pasted GitHub-App conf fragment)
# must still keep the conservative default — GitLab mints no scoped GitHub
# App token at all, so GH_AUTH_MODE/AGENT_TOKEN_PERMISSIONS prove nothing about
# what the review agent can actually push there.
( unset REVIEW_PROTECTED_PATHS
  export CODE_HOST=gitlab
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-14-$$.out 2>&1
assert_eq "TC-INV134-D1-14 CODE_HOST=gitlab + App-mode leftover conf ⇒ conservative default (host gate)" \
  "list=[.github/workflows/** CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-14-$$.out)"
rm -f /tmp/d1-14-$$.out

# TC-INV134-D1-15: CODE_HOST explicitly "github" + App mode + scope present ⇒
# still omits workflows (the explicit-github form behaves identically to the
# unset/default form D1-01 already covers).
( unset REVIEW_PROTECTED_PATHS
  export CODE_HOST=github
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-15-$$.out 2>&1
assert_eq "TC-INV134-D1-15 CODE_HOST=github explicit + App mode + scope ⇒ omits workflows" \
  "list=[CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-15-$$.out)"
rm -f /tmp/d1-15-$$.out

# TC-INV134-D1-16: CODE_HOST unset (defaults to github, mirroring
# lib-code-host.sh's own ${CODE_HOST:-github} convention) + App mode + scope
# present ⇒ still omits workflows (host gate does not regress the pre-fix
# unset-CODE_HOST GitHub installs that D1-01 exercises without setting CODE_HOST).
( unset REVIEW_PROTECTED_PATHS CODE_HOST
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-16-$$.out 2>&1
assert_eq "TC-INV134-D1-16 CODE_HOST unset ⇒ defaults to github, omits workflows" \
  "list=[CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d1-16-$$.out)"
rm -f /tmp/d1-16-$$.out

echo "--- explicit REVIEW_PROTECTED_PATHS never rewritten (either direction) ---"

# TC-INV134-D1-09: explicit empty + App mode + scope present ⇒ still "" (not
# re-populated with CODEOWNERS just because workflows would be omitted).
( export REVIEW_PROTECTED_PATHS=""
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-09-$$.out 2>&1
assert_eq "TC-INV134-D1-09 explicit empty preserved under capability-unlocked config" \
  "list=[]" "$(grep '^list=' /tmp/d1-09-$$.out)"
rm -f /tmp/d1-09-$$.out

# TC-INV134-D1-10: explicit empty + scope absent ⇒ still "".
( export REVIEW_PROTECTED_PATHS=""
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-10-$$.out 2>&1
assert_eq "TC-INV134-D1-10 explicit empty preserved under scope-absent config" \
  "list=[]" "$(grep '^list=' /tmp/d1-10-$$.out)"
rm -f /tmp/d1-10-$$.out

# TC-INV134-D1-11: explicit custom list + App mode + scope present ⇒ preserved
# verbatim (workflows is not re-added just because the operator's list omits it).
( export REVIEW_PROTECTED_PATHS="infra/**"
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
) > /tmp/d1-11-$$.out 2>&1
assert_eq "TC-INV134-D1-11 explicit custom list preserved verbatim" \
  "list=[infra/**]" "$(grep '^list=' /tmp/d1-11-$$.out)"
rm -f /tmp/d1-11-$$.out

# TC-INV134-D1-12: explicit list EXPLICITLY includes .github/workflows/** + App
# mode + scope present ⇒ still preserved verbatim (the capability check never
# strips an explicitly-listed workflow pattern).
( export REVIEW_PROTECTED_PATHS=".github/workflows/** infra/**"
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
  review_path_is_protected ".github/workflows/ci.yml" && echo "wf:0" || echo "wf:1"
) > /tmp/d1-12-$$.out 2>&1
assert_eq "TC-INV134-D1-12 explicit workflows pattern preserved verbatim" \
  "list=[.github/workflows/** infra/**]" "$(grep '^list=' /tmp/d1-12-$$.out)"
assert_eq "TC-INV134-D1-12 explicit workflows pattern still protected" \
  "wf:0" "$(grep -o 'wf:[01]' /tmp/d1-12-$$.out)"
rm -f /tmp/d1-12-$$.out

# TC-INV134-D1-13: an explicit value (including "") never invokes the
# capability probe at all — `${VAR-$(...)}` short-circuits the command
# substitution. Prove it by shadowing agent_token_has_workflow_scope with a
# call-counting stub AFTER sourcing the lib (so the real default assignment at
# source-time already ran), then re-run the default assignment line manually
# with the explicit var set — the stub must see zero calls.
( export REVIEW_PROTECTED_PATHS=""
  source "$CLASSIFY_LIB"
  _CALLS=0
  agent_token_has_workflow_scope() { _CALLS=$((_CALLS + 1)); return 0; }
  export GH_AUTH_MODE=app
  # Re-run the exact default-assignment expression the lib uses at source time.
  REVIEW_PROTECTED_PATHS="${REVIEW_PROTECTED_PATHS-$(_review_protected_paths_default_list)}"
  echo "calls=${_CALLS}"
) > /tmp/d1-13-$$.out 2>&1
assert_eq "TC-INV134-D1-13 explicit value short-circuits the capability probe" \
  "calls=0" "$(grep '^calls=' /tmp/d1-13-$$.out)"
rm -f /tmp/d1-13-$$.out

# ---------------------------------------------------------------------------
echo ""
echo "=== INV-135 (#488) D2: prompt/derivation consistency ==="
# ---------------------------------------------------------------------------

# TC-INV134-D2-01/03: App + scope present ⇒ prompt glob list omits workflows,
# and the requires_privileged_token note states scope=true for this config.
PR_D2_01="$( unset REVIEW_PROTECTED_PATHS
  GH_AUTH_MODE=app AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}' \
  bash -c 'source "$1"; review_protected_paths_prompt_rule' _ "$CLASSIFY_LIB" )"
case "$PR_D2_01" in
  *".github/workflows/**"*) echo "  FAIL: TC-INV134-D2-01 prompt glob list should OMIT workflows under capability-unlocked config"; FAIL=$((FAIL+1));;
  *) echo "  PASS: TC-INV134-D2-01 prompt glob list omits workflows under capability-unlocked config"; PASS=$((PASS+1));;
esac
case "$PR_D2_01" in
  *'`workflows` scope is'*'`true`'*) echo "  PASS: TC-INV134-D2-03 prompt states workflows scope=true for this config"; PASS=$((PASS+1));;
  *) echo "  FAIL: TC-INV134-D2-03 prompt should state workflows scope=true"; echo "      got: $PR_D2_01"; FAIL=$((FAIL+1));;
esac
case "$PR_D2_01" in
  *"it does by default"*) echo "  FAIL: TC-INV134-D2-03b prompt still hardcodes the retired \"it does by default\" claim"; FAIL=$((FAIL+1));;
  *) echo "  PASS: TC-INV134-D2-03b prompt no longer hardcodes \"it does by default\""; PASS=$((PASS+1));;
esac

# TC-INV134-D2-02/04: App, scope absent ⇒ prompt glob list KEEPS workflows, and
# the note states scope=false.
PR_D2_02="$( unset REVIEW_PROTECTED_PATHS
  GH_AUTH_MODE=app AGENT_TOKEN_PERMISSIONS='{"contents":"write"}' \
  bash -c 'source "$1"; review_protected_paths_prompt_rule' _ "$CLASSIFY_LIB" )"
case "$PR_D2_02" in
  *".github/workflows/**"*) echo "  PASS: TC-INV134-D2-02 prompt glob list keeps workflows when scope absent"; PASS=$((PASS+1));;
  *) echo "  FAIL: TC-INV134-D2-02 prompt glob list should keep workflows"; echo "      got: $PR_D2_02"; FAIL=$((FAIL+1));;
esac
case "$PR_D2_02" in
  *'`workflows` scope is'*'`false`'*) echo "  PASS: TC-INV134-D2-04 prompt states workflows scope=false for this config"; PASS=$((PASS+1));;
  *) echo "  FAIL: TC-INV134-D2-04 prompt should state workflows scope=false"; echo "      got: $PR_D2_02"; FAIL=$((FAIL+1));;
esac

# TC-INV134-D2-05: token mode + workflows key present (mode gate) ⇒ prompt
# glob list still keeps workflows (mirrors D1-03) and note reads scope=false.
PR_D2_05="$( unset REVIEW_PROTECTED_PATHS
  GH_AUTH_MODE=token AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}' \
  bash -c 'source "$1"; review_protected_paths_prompt_rule' _ "$CLASSIFY_LIB" )"
case "$PR_D2_05" in
  *".github/workflows/**"*) echo "  PASS: TC-INV134-D2-05 token mode ⇒ prompt glob list keeps workflows (mode gate)"; PASS=$((PASS+1));;
  *) echo "  FAIL: TC-INV134-D2-05 token mode should keep workflows in the glob list"; echo "      got: $PR_D2_05"; FAIL=$((FAIL+1));;
esac
case "$PR_D2_05" in
  *'`workflows` scope is'*'`false`'*) echo "  PASS: TC-INV134-D2-05b token mode ⇒ note reads scope=false"; PASS=$((PASS+1));;
  *) echo "  FAIL: TC-INV134-D2-05b token mode note should read scope=false"; echo "      got: $PR_D2_05"; FAIL=$((FAIL+1));;
esac

# TC-INV134-D2-06 (codex review round-1 finding #1, D2 companion): CODE_HOST=
# gitlab + App-mode leftover conf ⇒ prompt glob list still keeps workflows and
# the note reads scope=false — the prompt must never advertise a capability
# the host gate doesn't actually grant.
PR_D2_06="$( unset REVIEW_PROTECTED_PATHS
  CODE_HOST=gitlab GH_AUTH_MODE=app AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}' \
  bash -c 'source "$1"; review_protected_paths_prompt_rule' _ "$CLASSIFY_LIB" )"
case "$PR_D2_06" in
  *".github/workflows/**"*) echo "  PASS: TC-INV134-D2-06 CODE_HOST=gitlab ⇒ prompt glob list keeps workflows (host gate)"; PASS=$((PASS+1));;
  *) echo "  FAIL: TC-INV134-D2-06 CODE_HOST=gitlab should keep workflows in the glob list"; echo "      got: $PR_D2_06"; FAIL=$((FAIL+1));;
esac
case "$PR_D2_06" in
  *'`workflows` scope is'*'`false`'*) echo "  PASS: TC-INV134-D2-06b CODE_HOST=gitlab ⇒ note reads scope=false"; PASS=$((PASS+1));;
  *) echo "  FAIL: TC-INV134-D2-06b CODE_HOST=gitlab note should read scope=false"; echo "      got: $PR_D2_06"; FAIL=$((FAIL+1));;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== INV-135 (#488) D3: anti-forge preservation across capability outcomes ==="
# ---------------------------------------------------------------------------

# TC-INV134-D3-01: App + scope present ⇒ workflows is NOT in the default
# protected list, so a `.github/workflows/ci.yml` finding asserting
# actionable=true is genuinely actionable (nothing to override).
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  review_classify_artifact_dev_actionable \
    '{"verdict":"FAIL","blockingFindings":[{"title":"wf","file":".github/workflows/ci.yml","actionable_by_dev_agent":true}]}'
) > /tmp/d3-01-$$.out 2>&1
assert_eq "TC-INV134-D3-01 capability-unlocked workflows finding stays actionable" \
  "true" "$(cat /tmp/d3-01-$$.out)"
rm -f /tmp/d3-01-$$.out

# TC-INV134-D3-02: App, scope absent ⇒ workflows IS in the default protected
# list, so the SAME forged actionable=true is still overridden to false.
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write"}'
  source "$CLASSIFY_LIB"
  review_classify_artifact_dev_actionable \
    '{"verdict":"FAIL","blockingFindings":[{"title":"wf","file":".github/workflows/ci.yml","actionable_by_dev_agent":true}]}'
) > /tmp/d3-02-$$.out 2>&1
assert_eq "TC-INV134-D3-02 scope-absent forged workflows finding still overridden false" \
  "false" "$(cat /tmp/d3-02-$$.out)"
rm -f /tmp/d3-02-$$.out

# TC-INV134-D3-03: any config, agent-asserted false on a non-protected path is
# never promoted to true (regression, already covered above but re-pinned
# under the capability-unlocked config specifically).
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  review_classify_artifact_dev_actionable \
    '{"verdict":"FAIL","blockingFindings":[{"title":"code","file":"src/foo.ts","actionable_by_dev_agent":false}]}'
) > /tmp/d3-03-$$.out 2>&1
assert_eq "TC-INV134-D3-03 agent-asserted false on non-protected path never promoted" \
  "false" "$(cat /tmp/d3-03-$$.out)"
rm -f /tmp/d3-03-$$.out

# TC-INV134-D3-04: App + scope present ⇒ CODEOWNERS finding forged true is
# STILL overridden false (CODEOWNERS protected in every config).
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  review_classify_artifact_dev_actionable \
    '{"verdict":"FAIL","blockingFindings":[{"title":"owners","file":"CODEOWNERS","actionable_by_dev_agent":true}]}'
) > /tmp/d3-04-$$.out 2>&1
assert_eq "TC-INV134-D3-04 CODEOWNERS forged true still overridden false" \
  "false" "$(cat /tmp/d3-04-$$.out)"
rm -f /tmp/d3-04-$$.out

# ---------------------------------------------------------------------------
echo ""
echo "=== INV-135 (#488) D4: review_classify_artifact_matched_patterns ==="
# ---------------------------------------------------------------------------
( unset REVIEW_PROTECTED_PATHS AGENT_TOKEN_PERMISSIONS GH_AUTH_MODE
  source "$CLASSIFY_LIB"

  # TC-INV134-D4-01: multiple findings, mixed protected/non-protected ⇒ sorted
  # unique matched patterns.
  J_MULTI='{"verdict":"FAIL","blockingFindings":[{"title":"a","file":".github/workflows/ci.yml"},{"title":"b","file":"CODEOWNERS"},{"title":"c","file":"src/foo.ts"}]}'
  echo "d4-01=[$(review_classify_artifact_matched_patterns "$J_MULTI" | tr '\n' ',')]"

  # TC-INV134-D4-02: no protected match ⇒ empty.
  J_NONE='{"verdict":"FAIL","blockingFindings":[{"title":"c","file":"src/foo.ts"}]}'
  echo "d4-02=[$(review_classify_artifact_matched_patterns "$J_NONE" | tr '\n' ',')]"

  # TC-INV134-D4-03: non-JSON input ⇒ empty (fail-empty).
  echo "d4-03=[$(review_classify_artifact_matched_patterns "not json at all" | tr '\n' ',')]"

  # TC-INV134-D4-04: two findings both matching the SAME pattern ⇒ deduped
  # single entry.
  J_DUP='{"verdict":"FAIL","blockingFindings":[{"title":"a","file":".github/workflows/ci.yml"},{"title":"b","file":".github/workflows/deploy.yml"}]}'
  echo "d4-04=[$(review_classify_artifact_matched_patterns "$J_DUP" | tr '\n' ',')]"
) > /tmp/d4-$$.out 2>&1
assert_eq "TC-INV134-D4-01 multi-finding sorted unique matched patterns" \
  "d4-01=[.github/workflows/**,CODEOWNERS,]" "$(grep '^d4-01=' /tmp/d4-$$.out)"
assert_eq "TC-INV134-D4-02 no protected match ⇒ empty" \
  "d4-02=[]" "$(grep '^d4-02=' /tmp/d4-$$.out)"
assert_eq "TC-INV134-D4-03 non-JSON input ⇒ empty (fail-empty)" \
  "d4-03=[]" "$(grep '^d4-03=' /tmp/d4-$$.out)"
assert_eq "TC-INV134-D4-04 duplicate matches deduped to one entry" \
  "d4-04=[.github/workflows/**,]" "$(grep '^d4-04=' /tmp/d4-$$.out)"
rm -f /tmp/d4-$$.out

# TC-INV134-D4-05b [D1+D4 end-to-end]: under an App+scope-present config
# (D1 unlocks workflows, so it is NOT in the effective REVIEW_PROTECTED_PATHS),
# a mixed artifact whose findings touch BOTH a workflow file and CODEOWNERS
# must report ONLY CODEOWNERS as matched — proving
# review_classify_artifact_matched_patterns delegates to the SAME
# capability-aware $REVIEW_PROTECTED_PATHS value D1 computes, rather than
# hardcoding the full default pattern set independently (a regression here
# would let the capability-aware default leak only into
# review_path_is_protected/dev_actionable while this diagnostics function
# kept reporting workflows as "matched" under an unlocked config — a
# confusing, wrong stall notice naming a pattern that isn't even protected).
( unset REVIEW_PROTECTED_PATHS
  export GH_AUTH_MODE=app
  export AGENT_TOKEN_PERMISSIONS='{"contents":"write","workflows":"write"}'
  source "$CLASSIFY_LIB"
  echo "list=[$REVIEW_PROTECTED_PATHS]"
  J_MIXED='{"verdict":"FAIL","blockingFindings":[{"title":"wf","file":".github/workflows/ci.yml"},{"title":"owners","file":"CODEOWNERS"},{"title":"code","file":"src/foo.ts"}]}'
  echo "matched=[$(review_classify_artifact_matched_patterns "$J_MIXED" | tr '\n' ',')]"
) > /tmp/d4-05b-$$.out 2>&1
assert_eq "TC-INV134-D4-05b capability-unlocked default omits workflows" \
  "list=[CODEOWNERS .github/CODEOWNERS]" "$(grep '^list=' /tmp/d4-05b-$$.out)"
assert_eq "TC-INV134-D4-05b matched patterns report ONLY CODEOWNERS (workflows correctly excluded)" \
  "matched=[CODEOWNERS,]" "$(grep '^matched=' /tmp/d4-05b-$$.out)"
rm -f /tmp/d4-05b-$$.out

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
