#!/bin/bash
# test-adapter-spec-schemas.sh — issue #229 / INV-66.
#
# Validates the adapter-spec v1 JSON Schemas (docs/pipeline/schemas/*.json) and
# their committed example fixtures (docs/pipeline/schemas/examples/*.json). This
# is a DOCS-PR shaped test: it checks the SPEC artifacts are internally
# consistent (every golden example accepts, every documented violation rejects),
# NOT any runtime wrapper behavior — no wrapper / lib-agent.sh code is exercised.
#
# Two validation backends, picked at runtime so the suite runs in plain CI
# either way (ci.yml runs on bare ubuntu-latest):
#   1. PREFERRED — `python3 -m jsonschema` (Draft-07): full schema semantics,
#      including the `if/then` conditionals (provider.evidence required when
#      class != none; verdict=FAIL forced by a non-empty blockingFindings).
#   2. FALLBACK — `jq` structural assertions: required top-level keys present,
#      enum membership, and the three issue-mandated negative cases. Weaker than
#      full schema validation (jq does not evaluate JSON Schema conditionals) but
#      sufficient to catch the structural regressions, and runnable with no pip
#      install.
#
# The example naming convention drives the suite:
#   <schema-prefix>.golden.<label>.json    MUST validate
#   <schema-prefix>.negative.<label>.json  MUST be rejected
# where <schema-prefix> ∈ {adapter-result, verdict-artifact, fixture-manifest,
# error-envelope} maps to <prefix>.schema.json.
#
# Run: bash tests/unit/test-adapter-spec-schemas.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMA_DIR="$PROJECT_ROOT/docs/pipeline/schemas"
EXAMPLE_DIR="$SCHEMA_DIR/examples"
SPEC="$PROJECT_ROOT/docs/pipeline/adapter-spec.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
note() { echo -e "  ${YELLOW}NOTE${NC}: $1"; }

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then ok "$desc"; else bad "$desc (pattern: $pattern)"; fi
}

# assert_enum <json-file> "<jq-path> <allowed-token>..."
# Asserts the value at <jq-path> is one of the allowed tokens, using jq's own
# `inside`-style membership test. A missing/null value is skipped (only
# required keys are checked elsewhere). jq-only — no extra binary dependency.
assert_enum() {
  local file="$1" entry="$2"
  local path="${entry%% *}" allowed="${entry#* }"
  local val; val="$(jq -r "$path // empty" "$file" 2>/dev/null)"
  [[ -z "$val" ]] && return 0
  # Build a JSON array of allowed tokens and ask jq whether $val is a member.
  # Intentional word-split of $allowed into one token per line (SC2086).
  # shellcheck disable=SC2086
  if printf '%s\n' $allowed | jq -R . | jq -es --arg v "$val" 'index($v) != null' >/dev/null 2>&1; then
    ok "$(basename "$file") $path=$val in enum"
  else
    bad "$(basename "$file") $path=$val NOT in enum [$allowed]"
  fi
}

# ---------------------------------------------------------------------------
# Backend detection.
# ---------------------------------------------------------------------------
HAVE_PY_JSONSCHEMA=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
  HAVE_PY_JSONSCHEMA=1
fi
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; fi

SCHEMAS=(adapter-result verdict-artifact fixture-manifest error-envelope)

# ---------------------------------------------------------------------------
echo "=== TC-ADAPTER-SPEC-PRE: artifacts present + well-formed ==="

for s in "${SCHEMAS[@]}"; do
  f="$SCHEMA_DIR/$s.schema.json"
  if [[ -f "$f" ]]; then ok "schema present: $s.schema.json"; else bad "schema MISSING: $s.schema.json"; fi
done

if [[ -f "$SPEC" ]]; then ok "adapter-spec.md present"; else bad "adapter-spec.md MISSING"; fi
assert_grep "adapter-spec.md declares spec_version: 1" 'spec_version[`:]* *1' "$SPEC"
assert_grep "invariants.md has INV-66 (adapter conformance is spec-defined)" '^## INV-66:' "$INVARIANTS"

# Every example is well-formed JSON (jq or python).
if [[ "$HAVE_JQ" -eq 1 ]]; then
  for f in "$EXAMPLE_DIR"/*.json; do
    if jq -e . "$f" >/dev/null 2>&1; then ok "well-formed JSON: $(basename "$f")"; else bad "MALFORMED JSON: $(basename "$f")"; fi
  done
elif [[ "$HAVE_PY_JSONSCHEMA" -eq 1 ]]; then
  for f in "$EXAMPLE_DIR"/*.json; do
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1; then
      ok "well-formed JSON: $(basename "$f")"
    else bad "MALFORMED JSON: $(basename "$f")"; fi
  done
fi

# Each schema MUST have >= 2 golden examples (issue requirement).
echo "=== TC-ADAPTER-SPEC-COUNT: >=2 golden examples per schema ==="
for s in "${SCHEMAS[@]}"; do
  n=$(find "$EXAMPLE_DIR" -name "$s.golden.*.json" | wc -l | tr -d ' ')
  if [[ "$n" -ge 2 ]]; then ok "$s has $n golden examples (>=2)"; else bad "$s has only $n golden examples (<2)"; fi
done

# ---------------------------------------------------------------------------
# schema-prefix from an example filename: strip dir, take the field before the
# FIRST dot. "adapter-result.golden.pass.json" -> "adapter-result".
schema_prefix() { local b; b="$(basename "$1")"; echo "${b%%.*}"; }

# ---------------------------------------------------------------------------
# PREFERRED backend: python3 jsonschema (Draft-07), full semantics.
# ---------------------------------------------------------------------------
validate_py() {
  # $1 schema file, $2 instance file. rc 0 = valid, 1 = rejected, 2 = error.
  python3 - "$1" "$2" <<'PY'
import json, sys
from jsonschema import Draft7Validator
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
errs = list(Draft7Validator(schema).iter_errors(inst))
sys.exit(1 if errs else 0)
PY
}

run_py_suite() {
  echo "=== TC-ADAPTER-SPEC-PY: full Draft-07 validation (python3 jsonschema) ==="
  # Meta-validate the schemas themselves.
  for s in "${SCHEMAS[@]}"; do
    if python3 - "$SCHEMA_DIR/$s.schema.json" <<'PY' >/dev/null 2>&1
import json, sys
from jsonschema import Draft7Validator
Draft7Validator.check_schema(json.load(open(sys.argv[1])))
PY
    then ok "schema is valid Draft-07: $s"; else bad "schema is INVALID Draft-07: $s"; fi
  done

  for f in "$EXAMPLE_DIR"/*.json; do
    local name prefix schema
    name="$(basename "$f")"; prefix="$(schema_prefix "$f")"
    schema="$SCHEMA_DIR/$prefix.schema.json"
    if [[ ! -f "$schema" ]]; then bad "no schema for example $name"; continue; fi
    validate_py "$schema" "$f"; local rc=$?
    if [[ "$name" == *.golden.* ]]; then
      [[ "$rc" -eq 0 ]] && ok "golden accepts: $name" || bad "golden REJECTED: $name"
    elif [[ "$name" == *.negative.* ]]; then
      [[ "$rc" -eq 1 ]] && ok "negative rejected: $name" || bad "negative ACCEPTED (should reject): $name"
    fi
  done
}

# ---------------------------------------------------------------------------
# FALLBACK backend: jq structural assertions (no JSON Schema conditionals).
# Checks required top-level keys + enum membership read out of the schema, plus
# the three issue-mandated negative cases by name.
# ---------------------------------------------------------------------------
jq_required() { jq -r '.required[]?' "$1" 2>/dev/null; }

# A flat list of "<dotted-path> <space-separated-enum>" the fallback enforces.
# These mirror the load-bearing enums in the spec; jq cannot read nested
# `if/then`, so we assert the structural ones directly.
ENUM_adapter_result=(
  ".adapter claude codex kiro agy gemini opencode"
  ".mode dev-new dev-resume review e2e-browser"
  ".provider.class none quota auth config transient"
  ".verdict.state valid absent malformed"
  ".voteEligibility.state pass fail drop timeout-veto not-applicable"
)
ENUM_verdict_artifact=(
  ".verdict PASS FAIL"
)

run_jq_suite() {
  echo "=== TC-ADAPTER-SPEC-JQ: structural validation (jq fallback) ==="
  note "python3 jsonschema unavailable — using jq structural fallback (required-keys + enum)."

  # Golden examples: every top-level required key present.
  for f in "$EXAMPLE_DIR"/*.golden.*.json; do
    local name prefix schema missing=""
    name="$(basename "$f")"; prefix="$(schema_prefix "$f")"
    schema="$SCHEMA_DIR/$prefix.schema.json"
    # Symmetric with the python path: a golden whose prefix has no matching
    # schema is a real error, not a vacuous pass.
    if [[ ! -f "$schema" ]]; then bad "no schema for example $name"; continue; fi
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      if ! jq -e --arg k "$key" 'has($k)' "$f" >/dev/null 2>&1; then missing="$missing $key"; fi
    done < <(jq_required "$schema")
    if [[ -z "$missing" ]]; then ok "golden has all required top-level keys: $name"
    else bad "golden missing required keys ($missing): $name"; fi
  done

  # Golden adapter-result + verdict-artifact: enum membership. Membership is
  # tested with jq itself (the value at <path> must be one of the allowed
  # tokens), so the fallback depends only on jq — no `grep -w` word-matching,
  # which is brittle (substring/regex hazards) and was an extra binary dep.
  local entry
  for f in "$EXAMPLE_DIR"/adapter-result.golden.*.json; do
    for entry in "${ENUM_adapter_result[@]}"; do assert_enum "$f" "$entry"; done
  done
  for f in "$EXAMPLE_DIR"/verdict-artifact.golden.*.json; do
    for entry in "${ENUM_verdict_artifact[@]}"; do assert_enum "$f" "$entry"; done
  done

  # The three issue-mandated negative cases, asserted structurally.
  # 1. flat failure enum (missing axes) rejected.
  local f1="$EXAMPLE_DIR/adapter-result.negative.flat-enum.json"
  if jq -e 'has("process") and has("provider") and has("verdict") and has("voteEligibility")' "$f1" >/dev/null 2>&1; then
    bad "flat-enum negative unexpectedly has all four axes"
  else ok "flat-enum negative is missing >=1 axis (correctly non-conformant)"; fi

  # 2. verdict artifact without schema_version rejected.
  local f2="$EXAMPLE_DIR/verdict-artifact.negative.no-schema-version.json"
  if jq -e 'has("schema_version")' "$f2" >/dev/null 2>&1; then
    bad "no-schema-version negative unexpectedly has schema_version"
  else ok "verdict-artifact negative is missing schema_version (correctly non-conformant)"; fi

  # 3. error envelope missing remediation rejected.
  local f3="$EXAMPLE_DIR/error-envelope.negative.no-remediation.json"
  if jq -e 'has("remediation")' "$f3" >/dev/null 2>&1; then
    bad "no-remediation negative unexpectedly has remediation"
  else ok "error-envelope negative is missing remediation (correctly non-conformant)"; fi

  # 4. error envelope: a config-class envelope surfaced log-only is forbidden
  #    (Clause E2; #229 review finding). jq can structurally confirm the
  #    forbidden combination is present in the negative fixture (the full
  #    conditional is enforced by the python Draft-07 path).
  local f4="$EXAMPLE_DIR/error-envelope.negative.config-log-only.json"
  if jq -e '((.class // "config") | IN("config","auth","quota")) and (.surface == "log-only")' "$f4" >/dev/null 2>&1; then
    ok "config-log-only negative carries the forbidden class+log-only combo (correctly non-conformant)"
  else
    bad "config-log-only negative does not carry the forbidden config+log-only combo"
  fi

  # 5. adapter-result: a timed-out (rc 124/137) no-verdict result MUST be
  #    timeout-veto, not drop (Clause P1 + INV-48; #229 review finding). jq
  #    confirms the forbidden combo is present (full conditional → python path).
  local f5="$EXAMPLE_DIR/adapter-result.negative.timeout-not-veto.json"
  if jq -e '(.process.rc | IN(124,137)) and (.verdict.state | IN("absent","malformed")) and ((.process.timedOut != true) or (.voteEligibility.state != "timeout-veto"))' "$f5" >/dev/null 2>&1; then
    ok "timeout-not-veto negative carries the forbidden rc124/137+no-verdict+non-veto combo (correctly non-conformant)"
  else
    bad "timeout-not-veto negative does not carry the forbidden timeout+non-veto combo"
  fi

  # 6. adapter-result: a verdict.state=valid MUST carry a non-empty payloadRef
  #    (#229 review finding). jq confirms the negative is valid-without-payloadRef.
  local f6="$EXAMPLE_DIR/adapter-result.negative.valid-no-payloadref.json"
  if jq -e '(.verdict.state == "valid") and ((.verdict.payloadRef == null) or (.verdict.payloadRef == ""))' "$f6" >/dev/null 2>&1; then
    ok "valid-no-payloadref negative is verdict=valid with empty/null payloadRef (correctly non-conformant)"
  else
    bad "valid-no-payloadref negative does not carry the forbidden valid+empty-payloadRef combo"
  fi

  # 7. adapter-result: a review-mode, non-timeout (timedOut=false) no-verdict
  #    result MUST be drop, not pass/fail/not-applicable (Clause 4.4 + INV-40;
  #    #229 review finding). jq confirms the forbidden combo is present.
  local f7="$EXAMPLE_DIR/adapter-result.negative.noverdict-not-drop.json"
  if jq -e '(.mode == "review") and (.process.timedOut == false) and (.verdict.state | IN("absent","malformed")) and (.voteEligibility.state != "drop")' "$f7" >/dev/null 2>&1; then
    ok "noverdict-not-drop negative carries the forbidden review+no-verdict+non-drop combo (correctly non-conformant)"
  else
    bad "noverdict-not-drop negative does not carry the forbidden review+no-verdict+non-drop combo"
  fi

  # 8. verdict-artifact: verdict=FAIL MUST carry >=1 blocking finding (#229
  #    review finding). jq confirms the negative is FAIL with empty/absent blocking.
  local f8="$EXAMPLE_DIR/verdict-artifact.negative.fail-no-blocking.json"
  if jq -e '(.verdict == "FAIL") and (((.blockingFindings // []) | length) == 0)' "$f8" >/dev/null 2>&1; then
    ok "fail-no-blocking negative is FAIL with empty/absent blockingFindings (correctly non-conformant)"
  else
    bad "fail-no-blocking negative does not carry the forbidden FAIL+no-blocking combo"
  fi

  # 9. adapter-result: provider.evidence MUST be non-empty when class!=none
  #    (Clause PR1; #229 review finding). jq confirms the negative is a non-none
  #    class with an empty evidence string.
  local f9="$EXAMPLE_DIR/adapter-result.negative.empty-evidence.json"
  if jq -e '(.provider.class != "none") and (.provider.evidence == "")' "$f9" >/dev/null 2>&1; then
    ok "empty-evidence negative is non-none class with empty evidence (correctly non-conformant)"
  else
    bad "empty-evidence negative does not carry the forbidden non-none+empty-evidence combo"
  fi

  # 10. adapter-result: a non-review mode MUST vote not-applicable (§4.4; #229
  #     review finding). jq confirms the negative is dev/e2e with a deciding vote.
  local f10="$EXAMPLE_DIR/adapter-result.negative.devmode-votes.json"
  if jq -e '(.mode | IN("dev-new","dev-resume","e2e-browser")) and (.voteEligibility.state != "not-applicable")' "$f10" >/dev/null 2>&1; then
    ok "devmode-votes negative is a non-review mode with a deciding vote (correctly non-conformant)"
  else
    bad "devmode-votes negative does not carry the forbidden non-review+voting combo"
  fi

  # 11. adapter-result: a review result with a valid verdict MUST be pass|fail,
  #     not drop/timeout-veto/not-applicable (§4.4; #229 review finding). jq
  #     confirms the negative is review+valid with a non-pass/fail vote.
  local f11="$EXAMPLE_DIR/adapter-result.negative.valid-verdict-drop.json"
  if jq -e '(.mode == "review") and (.verdict.state == "valid") and (.voteEligibility.state | (IN("pass","fail") | not))' "$f11" >/dev/null 2>&1; then
    ok "valid-verdict-drop negative is review+valid with a non-pass/fail vote (correctly non-conformant)"
  else
    bad "valid-verdict-drop negative does not carry the forbidden review+valid+non-deciding combo"
  fi

  # 12. adapter-result: a review no-verdict result with timedOut=true MUST be
  #     timeout-veto regardless of rc (§4.4; #229 review finding — the conditional
  #     keys off timedOut, not rc). jq confirms the negative is review+timedOut+
  #     no-verdict with a non-veto vote.
  local f12="$EXAMPLE_DIR/adapter-result.negative.timeout-vote-wrong.json"
  if jq -e '(.mode == "review") and (.process.timedOut == true) and (.verdict.state | IN("absent","malformed")) and (.voteEligibility.state != "timeout-veto")' "$f12" >/dev/null 2>&1; then
    ok "timeout-vote-wrong negative is review+timedOut+no-verdict with a non-veto vote (correctly non-conformant)"
  else
    bad "timeout-vote-wrong negative does not carry the forbidden review+timedOut+non-veto combo"
  fi

  # 13. adapter-result: Clause P1 consistency — timedOut=true requires rc in
  #     {124,137} (#229 review finding). jq confirms the negative is timedOut=true
  #     with a non-124/137 rc.
  local f13="$EXAMPLE_DIR/adapter-result.negative.timedout-rc-inconsistent.json"
  if jq -e '(.process.timedOut == true) and ((.process.rc | IN(124,137)) | not)' "$f13" >/dev/null 2>&1; then
    ok "timedout-rc-inconsistent negative is timedOut=true with a non-124/137 rc (correctly non-conformant)"
  else
    bad "timedout-rc-inconsistent negative does not carry the forbidden timedOut+inconsistent-rc combo"
  fi
}

# ---------------------------------------------------------------------------
if [[ "$HAVE_PY_JSONSCHEMA" -eq 1 ]]; then
  run_py_suite
elif [[ "$HAVE_JQ" -eq 1 ]]; then
  run_jq_suite
else
  bad "neither python3 jsonschema NOR jq available — cannot validate schemas"
fi

# ---------------------------------------------------------------------------
# TC-ADAPTER-SPEC-NEG: the three issue-mandated negatives are validated by
# whichever backend ran above. This block re-asserts they EXIST as files so the
# requirement is pinned independent of the backend.
echo "=== TC-ADAPTER-SPEC-NEG: issue-mandated negative fixtures present ==="
for nf in \
  "adapter-result.negative.flat-enum.json" \
  "verdict-artifact.negative.no-schema-version.json" \
  "error-envelope.negative.no-remediation.json"; do
  if [[ -f "$EXAMPLE_DIR/$nf" ]]; then ok "negative fixture present: $nf"; else bad "negative fixture MISSING: $nf"; fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
