#!/bin/bash
# test-review-verdict-path.sh - issue #526 unattended Claude verdict paths.

set -uo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$ROOT/skills/autonomous-dispatcher/scripts"
CLAUDE_LIB="$DISP/lib-review-claude.sh"
ARTIFACT_LIB="$DISP/lib-review-artifact.sh"
WRAPPER="$DISP/autonomous-review.sh"
ADAPTER="$DISP/adapters/claude.sh"
CONF="$DISP/autonomous.conf.example"
FLOW="$ROOT/docs/pipeline/review-agent-flow.md"
HANDOFFS="$ROOT/docs/pipeline/handoffs.md"
INVARIANTS="$ROOT/docs/pipeline/invariants.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-verdict-path-unit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected=[$expected] actual=[$actual])"
  fi
}

assert_rc() {
  local desc="$1" expected="$2"
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$desc" "$expected" "$rc"
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing [$needle])"
  fi
}

assert_file_contains() {
  local desc="$1" file="$2" needle="$3"
  if [[ -f "$file" ]] && grep -Fq -- "$needle" "$file"; then
    pass "$desc"
  else
    fail "$desc (missing [$needle] in $file)"
  fi
}

echo "=== Claude review helper library ==="
if [[ -r "$CLAUDE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$CLAUDE_LIB"
  pass "TC-REVIEW-VERDICT-PATH-001 helper library exists"
else
  fail "TC-REVIEW-VERDICT-PATH-001 helper library exists"
fi

if declare -F _claude_review_permission_extra_args >/dev/null 2>&1; then
  artifact_path="$TMP/artifact dir/verdict-claude.json"
  body_dir="$TMP/body dir"
  mkdir -p "$(dirname "$artifact_path")" "$body_dir"

  REVIEW_CLAUDE_PERMISSION_INJECTION=true
  operator_args="--settings '$TMP/operator settings.json' --allowedTools Read"
  PROD_LOG="$TMP/production-seam.log"
  log() { printf '%s\n' "$*" >> "$PROD_LOG"; }
  dev_args="$operator_args"
  review_args="$operator_args"
  _claude_review_apply_permission_injection \
    claude auto "$artifact_path" "$body_dir" dev_args review_args
  # The production extra-arg parser uses trusted eval tokenization. Reproduce
  # that seam so this test observes the exact argv delivered to the adapter.
  eval "argv=($dev_args)"
  expected=(
    --settings "$TMP/operator settings.json" --allowedTools Read
    --add-dir "$(dirname "$artifact_path")"
    --add-dir "$body_dir"
    --allowedTools
    "Bash(bash scripts/write-verdict-artifact.sh:*)"
    "Bash(bash scripts/write-verdict-body.sh:*)"
    "Bash(bash scripts/post-verdict.sh:*)"
  )
  assert_eq "TC-REVIEW-VERDICT-PATH-001 auto exact argv" \
    "$(printf '%s\n' "${expected[@]}")" "$(printf '%s\n' "${argv[@]}")"
  assert_eq "TC-REVIEW-VERDICT-PATH-005 operator args precede injection" \
    "--settings|$TMP/operator settings.json|--allowedTools|Read|--add-dir" \
    "$(IFS='|'; printf '%s' "${argv[*]:0:5}")"
  assert_eq "TC-REVIEW-VERDICT-PATH-005 both adapter aliases receive identical injection" \
    "$dev_args" "$review_args"

  bypass_dev="$operator_args"
  bypass_review="$operator_args"
  _claude_review_apply_permission_injection \
    claude bypassPermissions "$artifact_path" "$body_dir" bypass_dev bypass_review
  assert_eq "TC-REVIEW-VERDICT-PATH-002 bypassPermissions skips injection" \
    "$operator_args" "$bypass_dev"

  plan_dev="$operator_args"
  plan_review="$operator_args"
  _claude_review_apply_permission_injection \
    claude plan "$artifact_path" "$body_dir" plan_dev plan_review
  assert_eq "TC-REVIEW-VERDICT-PATH-003 plan skips injection" \
    "$operator_args" "$plan_dev"
  assert_file_contains "TC-REVIEW-VERDICT-PATH-003 production seam logs plan warning" \
    "$PROD_LOG" "permission mode 'plan' is unsupported"

  other_dev="$operator_args"
  other_review="$operator_args"
  _claude_review_apply_permission_injection \
    codex auto "$artifact_path" "$body_dir" other_dev other_review
  assert_eq "TC-REVIEW-VERDICT-PATH-004 non-Claude skips injection" \
    "$operator_args" "$other_dev"

  REVIEW_CLAUDE_PERMISSION_INJECTION=false
  disabled_dev="$operator_args"
  disabled_review="$operator_args"
  _claude_review_apply_permission_injection \
    claude auto "$artifact_path" "$body_dir" disabled_dev disabled_review
  assert_eq "TC-REVIEW-VERDICT-PATH-006 knob false skips injection" \
    "$operator_args" "$disabled_dev"
  REVIEW_CLAUDE_PERMISSION_INJECTION=true

  # The shared lane provisioner deliberately returns /tmp as a sentinel when
  # mktemp fails. Claude permission assembly must never turn that into an
  # --add-dir /tmp grant.
  # shellcheck source=/dev/null
  source "$ARTIFACT_LIB"
  mktemp() { return 1; }
  failed_body_dir="$(_verdict_body_lane_dir proj claude 526)"
  unset -f mktemp
  assert_eq "TC-REVIEW-VERDICT-PATH-042 failed lane allocation returns sentinel" \
    "/tmp" "$failed_body_dir"
  assert_eq "TC-REVIEW-VERDICT-PATH-042 temporary root is never granted" "" \
    "$(_claude_review_permission_extra_args claude auto "$artifact_path" "$failed_body_dir")"
  assert_eq "TC-REVIEW-VERDICT-PATH-042 missing artifact directory is never granted" "" \
    "$(_claude_review_permission_extra_args claude auto "$TMP/missing/verdict.json" "$body_dir")"
else
  fail "TC-REVIEW-VERDICT-PATH-001 permission helper is defined"
fi

if declare -F _claude_review_plan_warning >/dev/null 2>&1; then
  warning="$(_claude_review_plan_warning claude plan)"
  assert_contains "TC-REVIEW-VERDICT-PATH-003 plan warning is loud" "$warning" "WARNING"
  assert_contains "TC-REVIEW-VERDICT-PATH-003 plan warning names unsupported lane" "$warning" "unsupported"
  assert_eq "TC-REVIEW-VERDICT-PATH-003 non-plan has no warning" "" \
    "$(_claude_review_plan_warning claude auto)"
else
  fail "TC-REVIEW-VERDICT-PATH-003 plan-warning helper is defined"
fi

echo ""
echo "=== Dev-side argv isolation ==="
if [[ -r "$ADAPTER" ]]; then
  (
    _parse_extra_args() {
      local var_name="$1"
      local -n _out_array="$2"
      local raw="${!var_name:-}"
      _out_array=()
      [[ -z "$raw" ]] || eval "_out_array=($raw)"
    }
    _run_with_timeout() { printf '%s\n' "$@"; }
    _agent_progress_recorder() { cat; }
    _agent_pipeline_result() { return 0; }
    source "$ADAPTER"
    AGENT_CMD=claude
    AGENT_PERMISSION_MODE=auto
    AGENT_DEV_EXTRA_ARGS="--settings '$TMP/dev settings.json'"
    AGENT_REVIEW_EXTRA_ARGS=""
    AGENT_LAUNCHER_ARGV=()
    adapter_invoke_claude dev-new 11111111-1111-4111-8111-111111111111 \
      "prompt" sonnet dev-session
  ) > "$TMP/dev-argv"
  expected_dev=$(cat <<EOF
env
-u
CLAUDECODE
claude
--session-id
11111111-1111-4111-8111-111111111111
--name
dev-session
--permission-mode
auto
--model
sonnet
--settings
$TMP/dev settings.json
-p
--output-format
stream-json
--verbose
EOF
)
  assert_eq "TC-REVIEW-VERDICT-PATH-007 dev argv remains byte-identical" \
    "$expected_dev" "$(cat "$TMP/dev-argv")"
else
  fail "TC-REVIEW-VERDICT-PATH-007 Claude adapter exists"
fi

echo ""
echo "=== Atomic verdict writers ==="
artifact="$TMP/writers/artifact/verdict.json"
body="$TMP/writers/body/verdict.md"
mkdir -p "$(dirname "$artifact")" "$(dirname "$body")"
artifact_json='{"schema_version":1,"verdict":"PASS","blockingFindings":[],"runId":"sid","agent":"claude"}'
if printf '%s\n' "$artifact_json" | VERDICT_ARTIFACT_PATH="$artifact" \
    bash "$DISP/write-verdict-artifact.sh" 2>"$TMP/artifact.err"; then
  assert_eq "TC-REVIEW-VERDICT-PATH-008 artifact helper preserves JSON" \
    "$artifact_json" "$(cat "$artifact")"
  tmp_count=$(find "$(dirname "$artifact")" -maxdepth 1 -name 'verdict.json.tmp.*' | wc -l | tr -d ' ')
  assert_eq "TC-REVIEW-VERDICT-PATH-008 artifact helper leaves no temp file" "0" "$tmp_count"
else
  fail "TC-REVIEW-VERDICT-PATH-008 artifact helper succeeds"
fi
assert_rc "TC-REVIEW-VERDICT-PATH-009 artifact helper rejects unset target" 2 \
  env -u VERDICT_ARTIFACT_PATH bash "$DISP/write-verdict-artifact.sh"

body_text=$'First line\nSecond `line` with $shell text'
if printf '%s' "$body_text" | VERDICT_BODY_FILE="$body" \
    bash "$DISP/write-verdict-body.sh" 2>"$TMP/body.err"; then
  assert_eq "TC-REVIEW-VERDICT-PATH-010 body helper preserves multiline text" \
    "$body_text" "$(cat "$body")"
else
  fail "TC-REVIEW-VERDICT-PATH-010 body helper succeeds"
fi
assert_rc "TC-REVIEW-VERDICT-PATH-011 body helper rejects unset target" 2 \
  env -u VERDICT_BODY_FILE bash "$DISP/write-verdict-body.sh"

echo ""
echo "=== Final-result recognition ==="
if declare -F _claude_final_text_verdict >/dev/null 2>&1; then
  assert_eq "TC-REVIEW-VERDICT-PATH-013 anchored pass" "pass" \
    "$(_claude_final_text_verdict 'Review PASSED - complete')"
  assert_eq "TC-REVIEW-VERDICT-PATH-014 anchored fail" "fail" \
    "$(_claude_final_text_verdict $'Review findings:\\n1. [P1] defect')"
  assert_eq "TC-REVIEW-VERDICT-PATH-015 ambiguous prose" "none" \
    "$(_claude_final_text_verdict 'The review appears complete.')"
  assert_eq "TC-REVIEW-VERDICT-PATH-016 quoted verdict" "none" \
    "$(_claude_final_text_verdict 'The expected phrase is \"Review PASSED\".')"
  assert_eq "TC-REVIEW-VERDICT-PATH-021 later-line verdict" "none" \
    "$(_claude_final_text_verdict $'Summary first\\nReview PASSED')"
else
  fail "TC-REVIEW-VERDICT-PATH-013 final-text recognizer is defined"
fi

if declare -F _claude_final_result_text >/dev/null 2>&1; then
  cat > "$TMP/error.jsonl" <<'EOF'
{"type":"result","is_error":true,"result":"Review PASSED"}
EOF
  assert_eq "TC-REVIEW-VERDICT-PATH-017 is_error true" "" \
    "$(_claude_final_result_text "$TMP/error.jsonl")"

  cat > "$TMP/non-string.jsonl" <<'EOF'
{"type":"result","result":{"verdict":"Review PASSED"}}
EOF
  assert_eq "TC-REVIEW-VERDICT-PATH-018 non-string result" "" \
    "$(_claude_final_result_text "$TMP/non-string.jsonl")"
  printf '%s\n' '{"type":"result","is_error":false}' > "$TMP/missing-result.jsonl"
  assert_eq "TC-REVIEW-VERDICT-PATH-018 missing result" "" \
    "$(_claude_final_result_text "$TMP/missing-result.jsonl")"

  printf '%s\n' 'not json' '{"type":"assistant","message":"Review PASSED"}' > "$TMP/bad.jsonl"
  assert_eq "TC-REVIEW-VERDICT-PATH-019 unparseable JSONL" "" \
    "$(_claude_final_result_text "$TMP/bad.jsonl")"

  cat > "$TMP/multiple.jsonl" <<'EOF'
{"type":"result","result":"Review PASSED - old"}
{"type":"result","is_error":true,"result":"Review findings:\nignored error"}
not-json
{"type":"result","result":"Review findings:\n1. [P1] final"}
{"type":"result","result":42}
EOF
  assert_eq "TC-REVIEW-VERDICT-PATH-020 last valid result wins" \
    $'Review findings:\n1. [P1] final' \
    "$(_claude_final_result_text "$TMP/multiple.jsonl")"
else
  fail "TC-REVIEW-VERDICT-PATH-017 final-result extractor is defined"
fi

# Pin the legacy classifier's intentionally different fail-first behavior.
# shellcheck source=/dev/null
source "$DISP/lib-review-poll.sh"
assert_eq "TC-REVIEW-VERDICT-PATH-022 legacy arbitrary prose remains fail" "fail" \
  "$(_classify_verdict_body 'The review appears complete.')"

echo ""
echo "=== Session binding and fallback gates ==="
if declare -F _claude_review_log_path >/dev/null 2>&1; then
  old_log="$TMP/agent-proj-review-526-claude.log"
  printf '%s\n' '{"type":"result","result":"Review PASSED - stale"}' > "$old_log"
  current_log="$(_claude_review_log_path "$TMP" proj 526 claude sid-current)"
  assert_eq "TC-REVIEW-VERDICT-PATH-023 Claude log is session-suffixed" \
    "$TMP/agent-proj-review-526-claude-sid-current.log" "$current_log"
  assert_eq "TC-REVIEW-VERDICT-PATH-023 stale reusable log is not current capture" "" \
    "$(_claude_final_result_text "$current_log")"
  assert_eq "TC-REVIEW-VERDICT-PATH-004 non-Claude log stays reusable" \
    "$TMP/agent-proj-review-526-kiro.log" \
    "$(_claude_review_log_path "$TMP" proj 526 kiro sid-current)"
else
  fail "TC-REVIEW-VERDICT-PATH-023 session-bound log helper is defined"
fi

if declare -F _claude_final_text_fallback_eligible >/dev/null 2>&1; then
  REVIEW_FINAL_TEXT_VERDICT_FALLBACK=true
  assert_rc "TC-REVIEW-VERDICT-PATH-024 rc0 Claude is eligible" 0 \
    _claude_final_text_fallback_eligible claude 0 ""
  assert_rc "TC-REVIEW-VERDICT-PATH-026 rc124 is refused" 1 \
    _claude_final_text_fallback_eligible claude 124 ""
  assert_rc "TC-REVIEW-VERDICT-PATH-027 rc137 is refused" 1 \
    _claude_final_text_fallback_eligible claude 137 ""
  assert_rc "TC-REVIEW-VERDICT-PATH-028 other nonzero rc is refused" 1 \
    _claude_final_text_fallback_eligible claude 1 ""
  assert_rc "TC-REVIEW-VERDICT-PATH-029 malformed artifact is refused" 1 \
    _claude_final_text_fallback_eligible claude 0 artifact-malformed
  assert_rc "TC-REVIEW-VERDICT-PATH-030 valid artifact verdict has precedence" 1 \
    _claude_final_text_fallback_eligible claude 0 artifact pass "Review PASSED"
  assert_rc "TC-REVIEW-VERDICT-PATH-031 comment verdict has precedence" 1 \
    _claude_final_text_fallback_eligible claude 0 "" fail "Review findings:"
  assert_rc "TC-REVIEW-VERDICT-PATH-034 non-Claude is refused" 1 \
    _claude_final_text_fallback_eligible kiro 0 ""
  REVIEW_FINAL_TEXT_VERDICT_FALLBACK=false
  assert_rc "TC-REVIEW-VERDICT-PATH-032 fallback knob false" 1 \
    _claude_final_text_fallback_eligible claude 0 ""
  REVIEW_FINAL_TEXT_VERDICT_FALLBACK=true
else
  fail "TC-REVIEW-VERDICT-PATH-024 fallback eligibility helper is defined"
fi

echo ""
echo "=== Production final-text fallback seam ==="
if declare -F _claude_apply_final_text_fallback >/dev/null 2>&1; then
  PROD_FALLBACK_DIR="$TMP/production-fallback"
  mkdir -p "$PROD_FALLBACK_DIR"
  cat > "$PROD_FALLBACK_DIR/post-verdict.sh" <<'STUB_POST'
#!/bin/bash
set -euo pipefail
[[ "${STUB_POST_FAIL:-false}" != "true" ]] || exit 1
body="$(cat "$3")"
case "$2" in
  pass) [[ "$body" == Review\ PASSED* ]] || body="Review PASSED - ${body}" ;;
  fail) [[ "$body" == Review\ findings:* ]] || body="Review findings:
${body}" ;;
  *) exit 2 ;;
esac
printf '%s\n' "$body" > "$STUB_POST_CAPTURE"
STUB_POST
  chmod +x "$PROD_FALLBACK_DIR/post-verdict.sh"

  SCRIPT_DIR="$PROD_FALLBACK_DIR"
  ISSUE_NUMBER=526
  STUB_POST_CAPTURE="$PROD_FALLBACK_DIR/posted-body"
  export STUB_POST_CAPTURE
  _append_run_footer_to_file() { :; }
  _resolve_review_agent_model() { printf 'sonnet\n'; }
  _fetch_agent_verdict_body() {
    [[ -s "$STUB_POST_CAPTURE" ]] && cat "$STUB_POST_CAPTURE"
  }

  printf '%s\n' \
    '{"type":"result","is_error":false,"result":"Review PASSED - production seam"}' \
    > "$PROD_FALLBACK_DIR/pass.jsonl"
  AGENT_NAMES=(claude)
  AGENT_SESSION_IDS=(sid-production)
  AGENT_CONTROLLER_LOGS=("$PROD_FALLBACK_DIR/pass.jsonl")
  AGENT_VERDICTS=("")
  AGENT_VERDICT_BODIES=("")
  AGENT_VERDICT_SOURCES=("")
  declare -A AGENT_LAUNCH_RC=([sid-production]=0)
  STUB_POST_FAIL=false
  export STUB_POST_FAIL
  _claude_apply_final_text_fallback 0
  assert_eq "TC-REVIEW-VERDICT-PATH-024 production fallback resolves pass" \
    "pass" "${AGENT_VERDICTS[0]}"
  assert_eq "TC-REVIEW-VERDICT-PATH-024 production fallback records source" \
    "claude-finaltext-fallback" "${AGENT_VERDICT_SOURCES[0]}"

  printf '%s\n' \
    '{"type":"result","is_error":false,"result":"Review PASSED - post fails"}' \
    > "$PROD_FALLBACK_DIR/post-fail.jsonl"
  rm -f "$STUB_POST_CAPTURE"
  AGENT_CONTROLLER_LOGS=("$PROD_FALLBACK_DIR/post-fail.jsonl")
  AGENT_VERDICTS=("")
  AGENT_VERDICT_BODIES=("")
  AGENT_VERDICT_SOURCES=("")
  STUB_POST_FAIL=true
  export STUB_POST_FAIL
  _claude_apply_final_text_fallback 0
  assert_eq "TC-REVIEW-VERDICT-PATH-033 failed production post leaves verdict unresolved" \
    "" "${AGENT_VERDICTS[0]}"
  assert_eq "TC-REVIEW-VERDICT-PATH-033 failed production post claims no source" \
    "" "${AGENT_VERDICT_SOURCES[0]}"
else
  fail "TC-REVIEW-VERDICT-PATH-024 production fallback seam is defined"
fi

echo ""
echo "=== Wrapper and prompt wiring ==="
wrapper_text="$(cat "$WRAPPER")"
claude_lib_text="$(cat "$CLAUDE_LIB")"
assert_contains "TC-REVIEW-VERDICT-PATH-001 wrapper sources Claude review lib" \
  "$wrapper_text" 'source "${LIB_DIR}/lib-review-claude.sh"'
assert_contains "TC-REVIEW-VERDICT-PATH-003 wrapper logs plan warning" \
  "$claude_lib_text" '_claude_review_plan_warning'
assert_contains "TC-REVIEW-VERDICT-PATH-005 injection follows resolved operator args" \
  "$wrapper_text" '_claude_review_apply_permission_injection'
assert_contains "TC-REVIEW-VERDICT-PATH-012 prompt uses artifact writer" \
  "$wrapper_text" 'bash scripts/write-verdict-artifact.sh'
assert_contains "TC-REVIEW-VERDICT-PATH-012 artifact heredoc is literal" \
  "$wrapper_text" "bash scripts/write-verdict-artifact.sh <<'VERDICT_JSON'"
assert_contains "TC-REVIEW-VERDICT-PATH-012 prompt uses body writer" \
  "$wrapper_text" 'bash scripts/write-verdict-body.sh'
assert_contains "TC-REVIEW-VERDICT-PATH-024 wrapper records fallback source" \
  "$claude_lib_text" 'AGENT_VERDICT_SOURCES[$i]="claude-finaltext-fallback"'
assert_contains "TC-REVIEW-VERDICT-PATH-029 wrapper names malformed fallback refusal" \
  "$claude_lib_text" 'malformed verdict artifact'
assert_contains "TC-REVIEW-VERDICT-PATH-033 wrapper posts fallback through helper" \
  "$claude_lib_text" 'post-verdict.sh'
assert_contains "TC-REVIEW-VERDICT-PATH-031 refetched comment is reclassified" \
  "$claude_lib_text" 'AGENT_VERDICTS[$i]="$(_classify_verdict_body "$refetched")"'
assert_contains "TC-REVIEW-VERDICT-PATH-024 wrapper invokes production fallback seam" \
  "$wrapper_text" '_claude_apply_final_text_fallback "$_i"'
if grep -Fq 'cat > "${_verdict_artifact_path}.tmp.$$"' "$WRAPPER"; then
  fail "TC-REVIEW-VERDICT-PATH-012 prompt no longer directly redirects artifact"
else
  pass "TC-REVIEW-VERDICT-PATH-012 prompt no longer directly redirects artifact"
fi

for helper in write-verdict-artifact.sh write-verdict-body.sh; do
  assert_file_contains "helper $helper uses private umask" "$DISP/$helper" "umask 077"
  assert_file_contains "helper $helper uses same-directory mktemp" "$DISP/$helper" "mktemp"
  assert_file_contains "helper $helper publishes with mv" "$DISP/$helper" "mv -f --"
done

echo ""
echo "=== Configuration and documentation ==="
assert_file_contains "permission injection defaults true" "$CONF" \
  'REVIEW_CLAUDE_PERMISSION_INJECTION="true"'
assert_file_contains "final-text fallback defaults true" "$CONF" \
  'REVIEW_FINAL_TEXT_VERDICT_FALLBACK="true"'
assert_file_contains "mode matrix documents auto" "$CONF" "auto"
assert_file_contains "mode matrix documents bypassPermissions" "$CONF" "bypassPermissions"
assert_file_contains "mode matrix documents plan" "$CONF" "plan"
assert_file_contains "mode matrix excludes default alias" "$CONF" \
  '`default` is NOT a supported alias'
assert_file_contains "mode matrix records verified Claude version" "$CONF" \
  "Claude Code 2.1.216"
assert_file_contains "flow documents final-result fallback" "$FLOW" \
  "Claude final-result fallback (INV-143)"
assert_file_contains "handoff documents ordered channels" "$HANDOFFS" \
  "artifact, authenticated"
assert_file_contains "new invariant is documented" "$INVARIANTS" \
  "## INV-143:"
echo ""
echo "=== Source-derived helper branch coverage ==="
COVERAGE_TRACE="$TMP/helper-coverage.trace"
(
  set -x
  source "$CLAUDE_LIB"
  artifact_path="$TMP/coverage/artifact/verdict.json"
  body_dir="$TMP/coverage/body"
  mkdir -p "$(dirname "$artifact_path")" "$body_dir"
  REVIEW_CLAUDE_PERMISSION_INJECTION=false
  _claude_review_permission_extra_args claude auto "$artifact_path" "$body_dir"
  REVIEW_CLAUDE_PERMISSION_INJECTION=true
  _claude_review_permission_extra_args kiro auto "$artifact_path" "$body_dir"
  _claude_review_permission_extra_args claude plan "$artifact_path" "$body_dir"
  _claude_review_permission_extra_args claude auto "" "$body_dir"
  _claude_review_permission_extra_args claude auto "$artifact_path" "$body_dir"
  _claude_review_plan_warning claude plan
  _claude_review_plan_warning claude auto
  _claude_review_log_path "$TMP" proj 526 claude sid
  _claude_review_log_path "$TMP" proj 526 kiro sid
  _claude_final_result_text "$TMP/missing-coverage-log"
  printf '%s\n' '{"type":"result","result":"Review PASSED"}' > "$TMP/coverage.jsonl"
  _claude_final_result_text "$TMP/coverage.jsonl"
  _claude_final_text_verdict "Review PASSED"
  _claude_final_text_verdict "Review findings:"
  _claude_final_text_verdict "ambiguous"
  REVIEW_FINAL_TEXT_VERDICT_FALLBACK=false
  _claude_final_text_fallback_eligible claude 0 "" || true
  REVIEW_FINAL_TEXT_VERDICT_FALLBACK=true
  _claude_final_text_fallback_eligible kiro 0 "" || true
  _claude_final_text_fallback_eligible claude 124 "" || true
  _claude_final_text_fallback_eligible claude 0 artifact-malformed || true
  _claude_final_text_fallback_eligible claude 0 artifact pass "Review PASSED" || true
  _claude_final_text_fallback_eligible claude 0 ""
) >/dev/null 2>"$COVERAGE_TRACE"
mapfile -t coverage_sites < <(grep -oE 'review-verdict-path-branch: RVP[0-9]+' "$CLAUDE_LIB" | sort -u)
coverage_total="${#coverage_sites[@]}"
coverage_covered=0
for site in "${coverage_sites[@]}"; do
  grep -Fq "$site" "$COVERAGE_TRACE" && coverage_covered=$((coverage_covered + 1))
done
if [[ "$coverage_total" -gt 0 && "$coverage_covered" -gt $((coverage_total * 80 / 100)) ]]; then
  pass "new helper decision coverage $coverage_covered/$coverage_total is >80%"
else
  fail "new helper decision coverage $coverage_covered/$coverage_total is not >80%"
fi

echo ""
echo "=== Summary ==="
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
