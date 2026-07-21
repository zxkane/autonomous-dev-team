#!/bin/bash
# test-review-permmode-warning.sh - issue #527 review startup warning.
#
# Run: bash tests/unit/test-review-permmode-warning.sh

set -uo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$ROOT/skills/autonomous-dispatcher/scripts"
LIB="$DISP/lib-review-permmode.sh"
RESOLVE_LIB="$DISP/lib-review-resolve.sh"
WRAPPER="$DISP/autonomous-review.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-permmode-warning.XXXXXX")"
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

assert_ne() {
  local desc="$1" left="$2" right="$3"
  if [[ "$left" != "$right" ]]; then
    pass "$desc"
  else
    fail "$desc (both=[$left])"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing=[$needle])"
  fi
}

assert_file_empty() {
  local desc="$1" file="$2"
  if [[ ! -s "$file" ]]; then
    pass "$desc"
  else
    fail "$desc (unexpected content in $file)"
  fi
}

echo "=== Pure warning predicate ==="
if [[ -r "$LIB" ]]; then
  # shellcheck source=/dev/null
  source "$LIB"
  pass "TC-CONF-PERMMODE-000 helper library exists"
else
  fail "TC-CONF-PERMMODE-000 helper library exists"
fi

if declare -F _review_permmode_warning_decision >/dev/null 2>&1; then
  assert_eq "TC-CONF-PERMMODE-001 Claude auto without escape hatches warns" \
    "warn" "$(_review_permmode_warning_decision auto "" false false claude)"
  assert_eq "TC-CONF-PERMMODE-002 Claude plan without knobs warns" \
    "warn" "$(_review_permmode_warning_decision plan "" false false claude)"
  assert_eq "TC-CONF-PERMMODE-003 Claude plan with both knobs still warns" \
    "warn" "$(_review_permmode_warning_decision plan "" true true claude)"
  assert_eq "TC-CONF-PERMMODE-004 operator allowedTools do not suppress" \
    "warn" "$(_review_permmode_warning_decision auto \
      "--allowedTools Write 'Bash(bash scripts/post-verdict.sh:*)'" \
      false false claude)"
  assert_eq "TC-CONF-PERMMODE-005 default plus injection still warns" \
    "warn" "$(_review_permmode_warning_decision default "" true false claude)"
  assert_eq "TC-CONF-PERMMODE-006 bypassPermissions does not warn" \
    "ok" "$(_review_permmode_warning_decision bypassPermissions "" false false claude)"
  assert_eq "TC-CONF-PERMMODE-007 non-Claude fleet does not warn" \
    "ok" "$(_review_permmode_warning_decision auto "" false false codex kiro)"
  assert_eq "TC-CONF-PERMMODE-008 fallback suppresses outside plan" \
    "ok" "$(_review_permmode_warning_decision default "" false true claude)"
  assert_eq "TC-CONF-PERMMODE-009 auto injection suppresses" \
    "ok" "$(_review_permmode_warning_decision auto "" true false claude)"
  assert_eq "TC-CONF-PERMMODE-009b mixed fleet recognizes Claude" \
    "warn" "$(_review_permmode_warning_decision auto "" false false codex claude)"
else
  fail "TC-CONF-PERMMODE-001..009 warning predicate is defined"
fi

echo ""
echo "=== Fingerprint and marker helpers ==="
if declare -F _review_permmode_warning_fingerprint >/dev/null 2>&1 \
    && declare -F _review_permmode_warning_marker >/dev/null 2>&1 \
    && declare -F _review_permmode_warning_seen >/dev/null 2>&1; then
  fp_auto="$(_review_permmode_warning_fingerprint auto false false claude)"
  fp_auto_again="$(_review_permmode_warning_fingerprint auto false false claude)"
  fp_mode="$(_review_permmode_warning_fingerprint default false false claude)"
  fp_fleet="$(_review_permmode_warning_fingerprint auto false false codex claude)"
  fp_knob="$(_review_permmode_warning_fingerprint auto true false claude)"
  assert_eq "TC-CONF-PERMMODE-013 fingerprint is stable" "$fp_auto" "$fp_auto_again"
  assert_ne "TC-CONF-PERMMODE-014 mode changes fingerprint" "$fp_auto" "$fp_mode"
  assert_ne "TC-CONF-PERMMODE-014 fleet changes fingerprint" "$fp_auto" "$fp_fleet"
  assert_ne "TC-CONF-PERMMODE-014 knob changes fingerprint" "$fp_auto" "$fp_knob"
  marker="$(_review_permmode_warning_marker "$fp_auto")"
  assert_contains "TC-CONF-PERMMODE-011 marker carries fingerprint" \
    "$marker" "fingerprint=${fp_auto}"
  comments=$(jq -cn --arg body "warning text"$'\n'"$marker" \
    '[{id: 1, author: "bot", authorKind: "self", body: $body, createdAt: "2026-07-21T00:00:00Z"}]')
  if _review_permmode_warning_seen "$comments" "$fp_auto"; then
    pass "TC-CONF-PERMMODE-011 matching marker is detected"
  else
    fail "TC-CONF-PERMMODE-011 matching marker is detected"
  fi
  if _review_permmode_warning_seen "$comments" "$fp_mode"; then
    fail "TC-CONF-PERMMODE-012 different fingerprint is not deduplicated"
  else
    pass "TC-CONF-PERMMODE-012 different fingerprint is not deduplicated"
  fi
  forged_comments=$(jq -cn --arg body "$marker" \
    '[{id: 2, author: "operator", authorKind: "human", body: $body, createdAt: "2026-07-21T00:00:01Z"}]')
  if _review_permmode_warning_seen "$forged_comments" "$fp_auto"; then
    fail "TC-CONF-PERMMODE-011 human marker cannot suppress warning"
  else
    assert_eq "TC-CONF-PERMMODE-011 human marker cannot suppress warning" "1" "$?"
  fi
  _review_permmode_warning_seen '{"not":"comments"}' "$fp_auto"
  assert_eq "TC-CONF-PERMMODE-011 malformed comments return scan failure" "2" "$?"
else
  fail "TC-CONF-PERMMODE-011..014 fingerprint helpers are defined"
fi

STARTUP_BLOCK="$(awk '
  /^# BEGIN REVIEW PERMISSION-MODE WARNING$/ { capture=1; next }
  /^# END REVIEW PERMISSION-MODE WARNING$/ { capture=0; exit }
  capture { print }
' "$WRAPPER")"

echo ""
echo "=== Wrapper placement and hermetic conf-load fixtures ==="
if [[ -n "$STARTUP_BLOCK" ]]; then
  pass "TC-CONF-PERMMODE-015 real wrapper startup block is extractable"
else
  fail "TC-CONF-PERMMODE-015 real wrapper startup block is extractable"
fi

block_start=$(grep -n '^# BEGIN REVIEW PERMISSION-MODE WARNING$' "$WRAPPER" \
  | head -1 | cut -d: -f1)
fleet_start=$(grep -n '^declare -a REVIEW_AGENTS_LIST$' "$WRAPPER" \
  | head -1 | cut -d: -f1)
trap_start=$(grep -n '^trap cleanup EXIT$' "$WRAPPER" \
  | head -1 | cut -d: -f1)
if [[ -n "$block_start" && -n "$fleet_start" && "$block_start" -gt "$fleet_start" ]]; then
  pass "TC-CONF-PERMMODE-015 warning runs after resolved fleet construction"
else
  fail "TC-CONF-PERMMODE-015 warning runs after resolved fleet construction"
fi
if [[ -n "$block_start" && -n "$trap_start" && "$block_start" -gt "$trap_start" ]]; then
  pass "TC-CONF-PERMMODE-015 warning runs after cleanup trap installation"
else
  fail "TC-CONF-PERMMODE-015 warning runs after cleanup trap installation"
fi
assert_contains "TC-CONF-PERMMODE-015 startup block uses resolved Claude extra args" \
  "$STARTUP_BLOCK" '_resolve_review_agent_extra_args "claude"'
assert_contains "TC-CONF-PERMMODE-015 startup block uses REVIEW_AGENTS_LIST" \
  "$STARTUP_BLOCK" '"${REVIEW_AGENTS_LIST[@]}"'

_write_conf() {
  local file="$1" review_cmd="$2" fleet="$3" mode="$4"
  local injection="$5" fallback="$6" suppression="$7" extra_args="$8"
  cat > "$file" <<CONF
AGENT_CMD="kiro"
AGENT_REVIEW_CMD="$review_cmd"
AGENT_REVIEW_AGENTS="$fleet"
AGENT_PERMISSION_MODE="$mode"
AGENT_REVIEW_EXTRA_ARGS=""
AGENT_REVIEW_EXTRA_ARGS_CLAUDE="$extra_args"
REVIEW_CLAUDE_PERMISSION_INJECTION="$injection"
REVIEW_FINAL_TEXT_VERDICT_FALLBACK="$fallback"
CONF_PERMMODE_WARN="$suppression"
CONF
}

_drive_fixture() {
  local conf="$1" sequence="${2:-once}"
  local case_dir
  case_dir="$(mktemp -d "$TMP/fixture.XXXXXX")"
  local driver="$case_dir/driver.sh"
  local block_file="$case_dir/startup-block.sh"
  printf '%s\n' "$STARTUP_BLOCK" > "$block_file"
  cat > "$driver" <<DRIVER
set -uo pipefail
source "$RESOLVE_LIB"
source "$LIB"
source "$conf"

AGENT_CMD="\$AGENT_REVIEW_CMD"
declare -a REVIEW_AGENTS_LIST
# shellcheck disable=SC2206
REVIEW_AGENTS_LIST=(\${AGENT_REVIEW_AGENTS:-})
if [[ \${#REVIEW_AGENTS_LIST[@]} -eq 0 ]]; then
  REVIEW_AGENTS_LIST=("\$AGENT_CMD")
fi

ISSUE_NUMBER=527
LOG_OUT="$case_dir/wrapper.log"
POST_OUT="$case_dir/posts.log"
COMMENTS="$case_dir/comments.json"
READ_COUNT="$case_dir/read-count"
READ_REQUIRE="$case_dir/read-require"
: > "\$LOG_OUT"
: > "\$POST_OUT"
printf '[]\n' > "\$COMMENTS"
printf '0\n' > "\$READ_COUNT"
: > "\$READ_REQUIRE"

log() { printf '%s\n' "\$*" >> "\$LOG_OUT"; }
run_footer() { printf '\n---\nrun-id: test-run · artifacts: /tmp/test-run\n'; }
itp_list_comments() {
  local count
  printf '%s\n' "\${ITP_REQUIRE_SELF_AUTHOR:-}" >> "\$READ_REQUIRE"
  count=\$(<"\$READ_COUNT")
  printf '%s\n' "\$((count + 1))" > "\$READ_COUNT"
  cat "\$COMMENTS"
}
itp_post_comment() {
  local issue="\$1" body="\$2" next
  printf '%s\n' "\$body" >> "\$POST_OUT"
  next="\$COMMENTS.next"
  jq --arg body "\$body" --arg issue "\$issue" \
    '. + [{id: (length + 1), author: "wrapper", authorKind: "self", body: \$body, createdAt: "2026-07-21T00:00:00Z"}]' \
    "\$COMMENTS" > "\$next"
  mv "\$next" "\$COMMENTS"
}

if [[ "$sequence" == "malformed" ]]; then
  printf '{"not":"comments"}\n' > "\$COMMENTS"
fi
source "$block_file"
if [[ "$sequence" == "same" ]]; then
  source "$block_file"
elif [[ "$sequence" == "different" ]]; then
  AGENT_PERMISSION_MODE="default"
  REVIEW_CLAUDE_PERMISSION_INJECTION="true"
  REVIEW_FINAL_TEXT_VERDICT_FALLBACK="false"
  source "$block_file"
fi
DRIVER
  bash "$driver"
  printf '%s\n' "$case_dir"
}

if [[ -n "$STARTUP_BLOCK" && -r "$LIB" ]]; then
  WARN_CONF="$TMP/warn.conf"
  _write_conf "$WARN_CONF" claude "" auto false false true \
    "--allowedTools Write 'Bash(bash scripts/post-verdict.sh:*)'"
  warn_dir="$(_drive_fixture "$WARN_CONF" once)"
  assert_contains "TC-CONF-PERMMODE-015 warn fixture logs failure mode" \
    "$(<"$warn_dir/wrapper.log")" "no wrapper-provided unattended verdict-reporting path"
  assert_contains "TC-CONF-PERMMODE-015 warn fixture names #524" \
    "$(<"$warn_dir/wrapper.log")" "#524"
  assert_contains "TC-CONF-PERMMODE-015 warn fixture posts fingerprint marker" \
    "$(<"$warn_dir/posts.log")" "<!-- review-permmode-warning:"
  assert_contains "TC-CONF-PERMMODE-015 warning comment has run footer" \
    "$(<"$warn_dir/posts.log")" "run-id: test-run"
  assert_eq "TC-CONF-PERMMODE-011 comment reads require self identity" \
    "1" "$(<"$warn_dir/read-require")"

  same_dir="$(_drive_fixture "$WARN_CONF" same)"
  same_posts=$(grep -c '<!-- review-permmode-warning:' "$same_dir/posts.log" || true)
  assert_eq "TC-CONF-PERMMODE-011 same unsafe fingerprint posts once" "1" "$same_posts"

  different_dir="$(_drive_fixture "$WARN_CONF" different)"
  different_posts=$(grep -c '<!-- review-permmode-warning:' "$different_dir/posts.log" || true)
  different_markers=$(grep '<!-- review-permmode-warning:' "$different_dir/posts.log" \
    | sort -u | wc -l | tr -d ' ')
  assert_eq "TC-CONF-PERMMODE-012 two unsafe fingerprints post twice" "2" "$different_posts"
  assert_eq "TC-CONF-PERMMODE-012 unsafe fingerprints have distinct markers" \
    "2" "$different_markers"

  malformed_dir="$(_drive_fixture "$WARN_CONF" malformed)"
  assert_file_empty "TC-CONF-PERMMODE-011 malformed comment data fails closed" \
    "$malformed_dir/posts.log"

  SAFE_CONF="$TMP/safe.conf"
  _write_conf "$SAFE_CONF" codex "" auto false false true ""
  safe_dir="$(_drive_fixture "$SAFE_CONF" once)"
  assert_file_empty "TC-CONF-PERMMODE-016 non-Claude fixture has no log warning" \
    "$safe_dir/wrapper.log"
  assert_file_empty "TC-CONF-PERMMODE-016 non-Claude fixture has no comment" \
    "$safe_dir/posts.log"

  FALLBACK_CONF="$TMP/fallback.conf"
  _write_conf "$FALLBACK_CONF" claude "" default false true true ""
  fallback_dir="$(_drive_fixture "$FALLBACK_CONF" once)"
  assert_file_empty "TC-CONF-PERMMODE-017 fallback fixture has no log warning" \
    "$fallback_dir/wrapper.log"
  assert_file_empty "TC-CONF-PERMMODE-017 fallback fixture has no comment" \
    "$fallback_dir/posts.log"

  assert_contains "TC-CONF-PERMMODE-018 allowedTools fixture still warns" \
    "$(<"$warn_dir/wrapper.log")" "no wrapper-provided unattended verdict-reporting path"

  SUPPRESS_CONF="$TMP/suppressed.conf"
  _write_conf "$SUPPRESS_CONF" claude "" auto false false false "--allowedTools Write"
  suppressed_dir="$(_drive_fixture "$SUPPRESS_CONF" once)"
  assert_file_empty "TC-CONF-PERMMODE-010 suppression removes log warning" \
    "$suppressed_dir/wrapper.log"
  assert_file_empty "TC-CONF-PERMMODE-010 suppression removes issue comment" \
    "$suppressed_dir/posts.log"
  assert_eq "TC-CONF-PERMMODE-010 suppression skips comment reads" \
    "0" "$(<"$suppressed_dir/read-count")"
else
  fail "TC-CONF-PERMMODE-010..019 fixture prerequisites are present"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
