#!/bin/bash
# test-autonomous-review-structured-ac.sh — issue #183 / INV-47.
#
# The command-mode E2E evidence parser MAY emit an OPTIONAL structured
# AC-coverage artifact (JSON: { "<criterion>": "pass"|"fail" }) inside an
# `ac-coverage:begin … ac-coverage:end` HTML-comment fence in its evidence
# stdout. The wrapper's command lane extracts + validates it (jq, fail-SAFE),
# writes it to a sidecar (E2E_AC_COVERAGE_FILE), and the review fan-out prefers
# the structured map over LLM-parsing the free-form evidence comment. Absent /
# malformed artifact → the wrapper falls back to the #182 free-form double-check
# (fail-safe, not fail-open).
#
# Three-pronged (the wrapper is too heavy to run end-to-end), mirroring the #182
# sequential-E2E suite:
#   1. pure-logic harness for _extract_ac_coverage_artifact (sourced from
#      lib-review-e2e.sh in isolation);
#   2. lane harness asserting _run_command_e2e_lane writes the validated sidecar
#      (fresh + reuse + malformed + no-fence + stale-truncation paths);
#   3. source-of-truth greps against autonomous-review.sh / lib-review-e2e.sh +
#      doc-presence checks.
#
# Run: bash tests/unit/test-autonomous-review-structured-ac.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
E2E_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-e2e.sh"
REF="$PROJECT_ROOT/skills/autonomous-review/references/e2e-command-mode.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"; echo "      actual=  [$actual]"; FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-AC-EXT: _extract_ac_coverage_artifact validation (pure) ==="
# ---------------------------------------------------------------------------
[[ -f "$E2E_LIB" ]] || { echo -e "  ${RED}FAIL${NC}: $E2E_LIB not found"; FAIL=$((FAIL + 1)); }
if [[ -f "$E2E_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-e2e.sh
  source "$E2E_LIB"
  log() { :; }   # silence the lib's log()

  # TC-AC-EXT-01: valid fence with a single pass criterion → compact JSON.
  _txt='## E2E Evidence
| crit | result |
<!-- ac-coverage:begin
{ "raw.json has >= 3 clusters": "pass" }
ac-coverage:end -->
<!-- e2e-evidence: complete sha="deadbeef" -->'
  out=$(_extract_ac_coverage_artifact "$_txt")
  assert_eq "TC-AC-EXT-01 valid fence (pass) → compact JSON" \
    '{"raw.json has >= 3 clusters":"pass"}' "$out"

  # TC-AC-EXT-02: no fence (a #182 parser) → empty (back-compat).
  out=$(_extract_ac_coverage_artifact '## E2E Evidence
no fence here
<!-- e2e-evidence: complete sha="deadbeef" -->')
  assert_eq "TC-AC-EXT-02 no fence → empty (back-compat)" "" "$out"

  # TC-AC-EXT-03: fence present but body is invalid JSON → empty (fail-safe).
  out=$(_extract_ac_coverage_artifact '<!-- ac-coverage:begin
{ this is not json ]
ac-coverage:end -->')
  assert_eq "TC-AC-EXT-03 invalid JSON → empty (fail-safe)" "" "$out"

  # TC-AC-EXT-04: value not in {pass,fail} → empty (value-domain enforced).
  out=$(_extract_ac_coverage_artifact '<!-- ac-coverage:begin
{ "a": "skip" }
ac-coverage:end -->')
  assert_eq "TC-AC-EXT-04 bad value domain → empty (fail-safe)" "" "$out"

  # TC-AC-EXT-05: JSON is an array, not an object → empty (object shape enforced).
  out=$(_extract_ac_coverage_artifact '<!-- ac-coverage:begin
[ "pass", "fail" ]
ac-coverage:end -->')
  assert_eq "TC-AC-EXT-05 array not object → empty (fail-safe)" "" "$out"

  # TC-AC-EXT-06: multiple criteria incl. a fail → retained.
  out=$(_extract_ac_coverage_artifact '<!-- ac-coverage:begin
{ "a": "pass", "b": "fail" }
ac-coverage:end -->')
  assert_eq "TC-AC-EXT-06 multi-criteria with fail → retained compact JSON" \
    '{"a":"pass","b":"fail"}' "$out"

  # TC-AC-EXT-07: empty fence body → empty (fail-safe).
  out=$(_extract_ac_coverage_artifact '<!-- ac-coverage:begin
ac-coverage:end -->')
  assert_eq "TC-AC-EXT-07 empty fence body → empty (fail-safe)" "" "$out"

  # TC-AC-EXT-08: TWO fences (contract violation) → canonicalize to the FIRST
  # object, never a multi-object stream.
  out=$(_extract_ac_coverage_artifact '<!-- ac-coverage:begin
{ "first": "pass" }
ac-coverage:end -->
later
<!-- ac-coverage:begin
{ "second": "fail" }
ac-coverage:end -->')
  assert_eq "TC-AC-EXT-08 two fences → first object only (single-object contract)" \
    '{"first":"pass"}' "$out"
fi

# ---------------------------------------------------------------------------
echo "=== TC-AC-LANE: _run_command_e2e_lane writes the validated sidecar ==="
# ---------------------------------------------------------------------------
if [[ -f "$E2E_LIB" ]]; then
  # Harness: clean env + stubbed gh/_fetch_sha_evidence. The lane reads
  # E2E_COMMAND_*_RENDERED + PR_NUMBER/REPO/PR_HEAD_SHA and writes
  # E2E_AC_COVERAGE_FILE. We echo the sidecar's content so the assertions can
  # check it. ACFILE lives under a per-run temp dir.
  _lane_ac_harness() {
    local setup="$1"
    env -i PATH="$PATH" bash -c "
      set -uo pipefail
      source '$E2E_LIB'
      log() { :; }
      TMPD=\$(mktemp -d)
      export PR_NUMBER=42 REPO=owner/repo PR_HEAD_SHA=deadbeefcafe
      export E2E_AC_COVERAGE_FILE=\"\$TMPD/ac.json\"
      gh() { :; }                      # swallow gh pr comment
      $setup
      RCFILE=\"\$TMPD/lane.rc\"
      _run_command_e2e_lane \"\$RCFILE\"
      echo \"RC=\$(cat \"\$RCFILE\" 2>/dev/null || echo MISSING)\"
      if [[ -f \"\$E2E_AC_COVERAGE_FILE\" ]]; then
        echo \"ACFILE_EXISTS=yes\"
        echo \"ACFILE=\$(cat \"\$E2E_AC_COVERAGE_FILE\")\"
      else
        echo \"ACFILE_EXISTS=no\"
      fi
    "
  }

  # TC-AC-LANE-01: fresh run, parser stdout includes a valid fence → sidecar has JSON.
  out=$(_lane_ac_harness '
    _fetch_sha_evidence() { return 0; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED=""
    export E2E_COMMAND_RENDERED="exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="printf %s \"## E2E Evidence
<!-- ac-coverage:begin
{ \\\"a\\\": \\\"pass\\\" }
ac-coverage:end -->
<!-- e2e-evidence: complete sha=\\\"deadbeefcafe\\\" -->\""
  ')
  assert_eq "TC-AC-LANE-01 fresh+valid fence → lane .rc=0" \
    "RC=0" "$(printf '%s\n' "$out" | grep '^RC=')"
  assert_eq "TC-AC-LANE-01b fresh+valid fence → sidecar has compact JSON" \
    'ACFILE={"a":"pass"}' "$(printf '%s\n' "$out" | grep '^ACFILE=')"

  # TC-AC-LANE-02: fresh run, NO fence (#182 parser) → sidecar exists + EMPTY.
  out=$(_lane_ac_harness '
    _fetch_sha_evidence() { return 0; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED=""
    export E2E_COMMAND_RENDERED="exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="printf %s \"## E2E Evidence
no fence
<!-- e2e-evidence: complete sha=\\\"deadbeefcafe\\\" -->\""
  ')
  assert_eq "TC-AC-LANE-02 no fence → lane .rc=0 (free-form path)" \
    "RC=0" "$(printf '%s\n' "$out" | grep '^RC=')"
  assert_eq "TC-AC-LANE-02b no fence → sidecar EMPTY" \
    'ACFILE=' "$(printf '%s\n' "$out" | grep '^ACFILE=')"

  # TC-AC-LANE-03: fresh run, malformed fence → sidecar EMPTY (fail-safe), .rc=0.
  out=$(_lane_ac_harness '
    _fetch_sha_evidence() { return 0; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED=""
    export E2E_COMMAND_RENDERED="exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="printf %s \"## E2E Evidence
<!-- ac-coverage:begin
{ not valid json
ac-coverage:end -->
<!-- e2e-evidence: complete sha=\\\"deadbeefcafe\\\" -->\""
  ')
  assert_eq "TC-AC-LANE-03 malformed fence → lane .rc=0 (fail-safe, not fail-open)" \
    "RC=0" "$(printf '%s\n' "$out" | grep '^RC=')"
  assert_eq "TC-AC-LANE-03b malformed fence → sidecar EMPTY (fall back to free-form)" \
    'ACFILE=' "$(printf '%s\n' "$out" | grep '^ACFILE=')"

  # TC-AC-LANE-04: reuse path — SHA-matching comment already carries a valid fence.
  out=$(_lane_ac_harness '
    _fetch_sha_evidence() { printf "## E2E Evidence
<!-- ac-coverage:begin
{ \"reused\": \"pass\" }
ac-coverage:end -->
<!-- e2e-evidence: complete sha=\"deadbeefcafe\" -->\n"; }
    export E2E_COMMAND_PRE_HOOKS_RENDERED="echo SHOULD_NOT_RUN"
    export E2E_COMMAND_RENDERED="echo SHOULD_NOT_RUN"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="echo SHOULD_NOT_RUN"
  ')
  assert_eq "TC-AC-LANE-04 reuse path → lane .rc=0" \
    "RC=0" "$(printf '%s\n' "$out" | grep '^RC=')"
  assert_eq "TC-AC-LANE-04b reuse path → sidecar extracted from reused comment" \
    'ACFILE={"reused":"pass"}' "$(printf '%s\n' "$out" | grep '^ACFILE=')"

  # TC-AC-LANE-05: a STALE sidecar exists; this round emits NO fence → truncated.
  out=$(_lane_ac_harness '
    _fetch_sha_evidence() { return 0; }
    printf %s "{\"stale\":\"fail\"}" > "$E2E_AC_COVERAGE_FILE"   # prior round leftover
    export E2E_COMMAND_PRE_HOOKS_RENDERED=""
    export E2E_COMMAND_RENDERED="exit 0"
    export E2E_COMMAND_EVIDENCE_PARSER_RENDERED="printf %s \"## E2E Evidence
no fence this round
<!-- e2e-evidence: complete sha=\\\"deadbeefcafe\\\" -->\""
  ')
  assert_eq "TC-AC-LANE-05 stale sidecar + no fence this round → TRUNCATED (no leak)" \
    'ACFILE=' "$(printf '%s\n' "$out" | grep '^ACFILE=')"
fi

# ---------------------------------------------------------------------------
echo "=== TC-AC-SRC: source-of-truth greps (wrapper + lib + prompt) ==="
# ---------------------------------------------------------------------------
[[ -f "$WRAPPER" ]] || { echo -e "  ${RED}FAIL${NC}: $WRAPPER not found"; FAIL=$((FAIL + 1)); }
if [[ -f "$WRAPPER" && -f "$E2E_LIB" ]]; then
  # TC-AC-SRC-01: wrapper exports E2E_AC_COVERAGE_FILE for command mode.
  assert_grep "TC-AC-SRC-01 wrapper exports E2E_AC_COVERAGE_FILE" \
    'export E2E_AC_COVERAGE_FILE' "$WRAPPER"

  # TC-AC-SRC-02: build_review_prompt prefers the structured map when present.
  PROMPT_FN=$(awk '/^build_review_prompt\(\) \{/,/^\}/' "$WRAPPER")
  if printf '%s' "$PROMPT_FN" | grep -qiE 'ac-coverage|structured AC|AC.coverage map|E2E_AC_COVERAGE_FILE'; then
    echo -e "  ${GREEN}PASS${NC}: TC-AC-SRC-02 build_review_prompt references the structured AC map"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-AC-SRC-02 build_review_prompt has no structured AC map branch"
    FAIL=$((FAIL + 1))
  fi

  # TC-AC-SRC-03: the free-form '## E2E Evidence' block is still reachable (back-compat).
  if printf '%s' "$PROMPT_FN" | grep -qE 'E2E Evidence|posted evidence|e2e-evidence: complete'; then
    echo -e "  ${GREEN}PASS${NC}: TC-AC-SRC-03 free-form evidence block still present (back-compat fallback)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-AC-SRC-03 free-form evidence block missing"
    FAIL=$((FAIL + 1))
  fi

  # TC-AC-SRC-04: extraction helper is defined in the lib and is command-mode only.
  assert_grep "TC-AC-SRC-04 _extract_ac_coverage_artifact defined in lib" \
    '_extract_ac_coverage_artifact\(\)' "$E2E_LIB"
  # The helper must NOT be wired into the browser lane functions
  # (build_browser_e2e_prompt / _stamp_browser_evidence_marker).
  BROWSER_FNS=$(awk '/^build_browser_e2e_prompt\(\) \{/,/^\}/; /^_stamp_browser_evidence_marker\(\) \{/,/^\}/' "$E2E_LIB")
  if printf '%s' "$BROWSER_FNS" | grep -qE '_extract_ac_coverage_artifact'; then
    echo -e "  ${RED}FAIL${NC}: TC-AC-SRC-04b browser lane calls _extract_ac_coverage_artifact (must be command-mode only)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: TC-AC-SRC-04b structured AC extraction is command-mode only (not in browser lane)"
    PASS=$((PASS + 1))
  fi

  # TC-AC-SRC-05: bash -n parses wrapper + lib clean.
  if bash -n "$WRAPPER" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-AC-SRC-05 bash -n wrapper clean"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-AC-SRC-05 bash -n wrapper FAILED"; FAIL=$((FAIL + 1))
  fi
  if bash -n "$E2E_LIB" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-AC-SRC-05b bash -n lib clean"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-AC-SRC-05b bash -n lib FAILED"; FAIL=$((FAIL + 1))
  fi
fi

# ---------------------------------------------------------------------------
echo "=== TC-AC-DOC: doc presence (INV-47 + ref + flow) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-AC-DOC-01 e2e-command-mode.md documents the optional structured artifact" \
  'ac-coverage|structured AC-coverage' "$REF"
assert_grep "TC-AC-DOC-02 INV-47 entry in invariants.md" \
  'INV-47' "$INVARIANTS"
assert_grep "TC-AC-DOC-03 review-agent-flow.md mentions the structured AC artifact" \
  'INV-47|structured AC|ac-coverage' "$FLOW"

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
[[ "$FAIL" -eq 0 ]] || exit 1
