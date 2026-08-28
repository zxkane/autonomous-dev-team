#!/bin/bash
# Regression coverage for issue #547: non-executable shell regions must not
# be treated as git invocations.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-common/hooks/lib.sh"
HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/block-commit-outside-worktree.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/issue-547-non-executable.XXXXXX")"
REPO_A="$TMPROOT/repo-a"

trap 'rm -rf "$TMPROOT"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# shellcheck source=/dev/null
source "$LIB"

record_pass() {
  echo -e "  ${GREEN}PASS${NC}: $1"
  PASS=$((PASS + 1))
}

record_fail() {
  echo -e "  ${RED}FAIL${NC}: $1"
  FAIL=$((FAIL + 1))
}

assert_detector_no_match() {
  local id="$1"
  local command="$2"

  if ! is_git_command commit "$command"; then
    record_pass "$id"
  else
    record_fail "$id (is_git_command incorrectly detected commit)"
  fi
}

assert_detector_match() {
  local id="$1"
  local command="$2"

  if is_git_command commit "$command"; then
    record_pass "$id"
  else
    record_fail "$id (is_git_command missed a real commit)"
  fi
}

assert_resolver_no_match() {
  local id="$1"
  local command="$2"
  local output rc

  output=$(resolve_git_command_cwd commit "$command" "$REPO_A" 2>/dev/null)
  rc=$?
  if [[ "$rc" -eq 1 && -z "$output" ]]; then
    record_pass "$id"
  else
    record_fail "$id (expected resolver rc=1/output='', got rc=$rc/output='$output')"
  fi
}

assert_resolver_uncertain_match() {
  local id="$1"
  local command="$2"
  local output rc

  output=$(resolve_git_command_cwd commit "$command" "$REPO_A" 2>/dev/null)
  rc=$?
  if [[ "$rc" -eq 2 && -z "$output" ]]; then
    record_pass "$id"
  else
    record_fail "$id (expected resolver rc=2/output='', got rc=$rc/output='$output')"
  fi
}

run_hook() {
  local command="$1"
  local payload

  payload=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}')
  HOOK_OUTPUT=$(
    cd "$REPO_A" &&
      printf '%s' "$payload" | bash "$HOOK" 2>&1
  )
  HOOK_RC=$?
}

assert_hook_rc() {
  local id="$1"
  local expected="$2"
  local command="$3"

  run_hook "$command"
  if [[ "$HOOK_RC" -eq "$expected" ]]; then
    record_pass "$id (hook rc=$HOOK_RC)"
  else
    record_fail "$id (expected hook rc=$expected, got $HOOK_RC: $HOOK_OUTPUT)"
  fi
}

assert_large_heredoc_bounded() {
  local id="$1"
  local rc

  # shellcheck disable=SC2016
  if timeout 2 bash -c '
    source "$1"
    payload=$(
      printf "cat <<EOF\n"
      head -c 1000000 /dev/zero | tr "\0" x
      printf "\nEOF\n"
    )
    ! is_git_command commit "$payload"
  ' _ "$LIB"; then
    record_pass "$id"
  else
    rc=$?
    record_fail "$id (expected completion within 2s, got rc=$rc)"
  fi
}

assert_large_ambiguous_hook_bounded() {
  local id="$1"
  local function_count="${2:-250}"
  local command=$'python3 - <<PY\n'
  local payload output rc i

  for ((i = 0; i < function_count; i++)); do
    command+="def f$i(x):"$'\n'
    command+="    return g(x)+$i"$'\n'
  done
  command+=$'PY\ngit commit -m real'
  payload=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}')

  output=$(
    cd "$REPO_A" &&
      printf '%s' "$payload" | timeout 5 bash "$HOOK" 2>&1
  )
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    record_pass "$id (hook rc=$rc within 5s)"
  else
    record_fail "$id (expected hook rc=2 within 5s, got rc=$rc: $output)"
  fi
}

assert_preprocessor_failure_detector() {
  local id="$1"

  if (
    # shellcheck disable=SC2329
    awk() { return 127; }
    is_git_command commit "$REAL_COMMIT"
  ); then
    record_pass "$id"
  else
    record_fail "$id (detector did not retain the original command)"
  fi
}

assert_preprocessor_failure_resolver() {
  local id="$1"
  local output rc

  output=$(
    (
      # shellcheck disable=SC2329
      awk() { return 127; }
      resolve_git_command_cwd commit "$REAL_COMMIT" "$REPO_A"
    )
  )
  rc=$?
  if [[ "$rc" -eq 0 && "$output" == "$CANON_A" ]]; then
    record_pass "$id"
  else
    record_fail "$id (expected rc=0/output='$CANON_A', got rc=$rc/output='$output')"
  fi
}

mkdir -p "$REPO_A"
git init -q -b main "$REPO_A"
git -C "$REPO_A" config user.email "test@example.com"
git -C "$REPO_A" config user.name "Hook Test"
printf 'initial\n' > "$REPO_A/initial.txt"
git -C "$REPO_A" add initial.txt
git -C "$REPO_A" commit -qm "initial"
CANON_A="$(cd "$REPO_A" && pwd -P)"

HEREDOC_COMMIT=$'cat > /tmp/p.md <<\'EOF\'\ngit commit -m msg\nEOF'
HEREDOC_CHAIN=$'cat > /tmp/p.md <<-EOF\n\tgit add . && git commit -m x\n\tEOF'
COMMENT_ONLY='ls -l  # git commit -m x'
QUOTED_MENTION='echo "run: git commit -m x"'
REAL_COMMIT='git commit -m x'
COMMENT_THEN_COMMIT=$'# git commit -m documentation-only\ngit commit -m x'
QUOTED_HASH_THEN_COMMIT='echo "# not a comment" && git commit -m x'
HEREDOC_THEN_COMMIT=$'cat > /tmp/p.md <<\'EOF\'\ndocument only\nEOF\ngit commit -m x'
DOUBLE_QUOTED_HEREDOC=$'cat > /tmp/p.md <<"EOF"\ngit commit -m body\nEOF'
HERE_STRING_THEN_COMMIT=$'cat <<<EOF\ngit commit -m real'
ESCAPED_HASH_THEN_COMMIT='echo \# && git commit -m real'
MIDWORD_HASH_THEN_COMMIT='echo value#suffix && git commit -m real'
QUOTED_OPENER_THEN_COMMIT=$'echo "<<EOF"\ngit commit -m real'
MULTILINE_QUOTE_THEN_COMMIT=$'echo "line\n# still quoted" && git commit -m real'
TRAILING_REDIRECT_HEREDOC=$'cat <<EOF >/tmp/p.md\ngit commit -m body\nEOF'
ESCAPED_DELIMITER_HEREDOC=$'cat <<\\EOF\ngit commit -m body\nEOF'
MULTIPLE_HEREDOCS=$'cat <<FIRST <<SECOND\ngit commit -m first-body\nFIRST\ngit commit -m second-body\nSECOND'
# shellcheck disable=SC2016
COMMAND_SUB_HASH_THEN_COMMIT='echo $(printf x)#suffix; git commit -m real'
ARITHMETIC_SHIFT_THEN_COMMIT=$'(( 1 <<EOF\n))\ngit commit -m real\nEOF'
HEREDOC_LINE_THEN_COMMIT=$'cat <<EOF >/dev/null; git commit -m real\nbody\nEOF'
PIPELINE_HEREDOC=$'cat <<EOF | bash\ngit commit -m real\nEOF'
UNQUOTED_HEREDOC_SUBSTITUTION=$'cat <<EOF >/dev/null\n$(git commit -m real)\nEOF'
ESCAPED_HEREDOC_SUBSTITUTION=$'cat <<EOF >/dev/null\n\\$(git commit -m prose)\nEOF'
# shellcheck disable=SC2016
DOUBLE_QUOTED_SUBSTITUTION='echo "$(git commit -m real)"'
# shellcheck disable=SC2016
DOUBLE_QUOTED_BACKTICK='echo "`git commit -m real`"'
SHELL_CONSUMER_HEREDOC=$'bash <<\'EOF\'\ngit commit -m real\nEOF'
SHADOWED_CAT_HEREDOC=$'function cat { bash; }\ncat <<\'EOF\'\ngit commit -m real\nEOF'
CONTINUED_CAT_FUNCTION_HEREDOC=$'function \\\ncat { bash; }\ncat <<\'EOF\'\ngit commit -m real\nEOF'
# shellcheck disable=SC2016
BENIGN_QUOTED_SUBSTITUTION='echo "generated $(date); example: git commit -m docs"'
EVAL_CAT_HEREDOC=$'eval \'cat() { bash; }\'\ncat <<\'EOF\'\ngit commit -m real\nEOF'
# shellcheck disable=SC2016
SHELL_C_SUBSTITUTION='echo "$(bash -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
EVAL_SUBSTITUTION='echo "$(eval '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
BENIGN_ECHO_SUBSTITUTION='echo "$(echo '\''git commit -m prose'\'')"'
# shellcheck disable=SC2016
PAREN_SUBSTITUTION='echo "$(printf '\''(%s)'\'' x; git commit -m real)"'
# shellcheck disable=SC2016
SHELL_C_GROUP_SUBSTITUTION='echo "$(bash -c '\''(git commit -m real)'\'')"'
# shellcheck disable=SC2016
SHELL_C_OPTION_SUBSTITUTION='echo "$(bash -O extglob -c '\''git commit -m real'\'')"'
COMMENT_PAREN_SUBSTITUTION=$'echo "$(printf x # )\ngit commit -m real\n)"'
# shellcheck disable=SC2016
GROUPED_SUBSTITUTION='echo "$( (git commit -m real) )"'
# shellcheck disable=SC2016
SHELL_PLUS_O_SUBSTITUTION='echo "$(bash +O extglob -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
ENV_UNSET_SUBSTITUTION='echo "$(env -u X bash -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
COMMAND_P_SUBSTITUTION='echo "$(command -p bash -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
SUBSTITUTION_EOF_COMMENT='echo "$(date)" # git commit -m prose'
# shellcheck disable=SC2016
DYNAMIC_SHELL_SUBSTITUTION='echo "$($SHELL -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
EXEC_SHELL_SUBSTITUTION='echo "$(exec bash -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
IF_SHELL_SUBSTITUTION='echo "$(if true; then bash -c '\''git commit -m real'\''; fi)"'
# shellcheck disable=SC2016
ESCAPED_SHELL_SUBSTITUTION='echo "$(\bash -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
NEGATED_SHELL_SUBSTITUTION='echo "$(! bash -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
IF_CONDITION_SUBSTITUTION='echo "$(if bash -c '\''git commit -m real'\''; then :; fi)"'
# shellcheck disable=SC2016
TIME_SHELL_SUBSTITUTION='echo "$(time bash -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
REDIRECTED_SHELL_SUBSTITUTION='echo "$(>/dev/null bash -c '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
BASH_STDIN_SUBSTITUTION='echo "$(bash <<< '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
BASH_S_STDIN_SUBSTITUTION='echo "$(bash -s <<< '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
BENIGN_PRINTF_SUBSTITUTION='echo "$(printf '\''%s'\'' '\''git commit -m prose'\'')"'
# shellcheck disable=SC2016
SHADOWED_ECHO_SUBSTITUTION='echo(){ eval "$*"; }; : "$(echo '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
SHADOWED_PRINTF_SUBSTITUTION='printf(){ eval "$1"; }; : "$(printf '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
PATH_ECHO_SUBSTITUTION='echo "$(/tmp/echo '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
PATH_PRINTF_SUBSTITUTION='echo "$(/tmp/printf '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
PRINTF_V_SUBSTITUTION='echo "$(printf -v '\''x[$(git commit -m real; echo 0)]'\'' %s value)"'
# shellcheck disable=SC2016
EVAL_OUTPUT_SUBSTITUTION='eval "$(echo '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
BASH_C_OUTPUT_SUBSTITUTION='bash -c "$(echo '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
BASH_PROCESS_OUTPUT_SUBSTITUTION='bash <(echo '\''git commit -m real'\'')'
# shellcheck disable=SC2016
PIPE_OUTPUT_SUBSTITUTION='echo "$(echo '\''git commit -m real'\'')" | bash'
# shellcheck disable=SC2016
PREFIX_REDIRECT_OUTPUT_SUBSTITUTION='echo > >(bash) "$(echo '\''git commit -m real'\'')"'
# shellcheck disable=SC2016
ARRAY_SUBSCRIPT_OUTPUT_SUBSTITUTION='echo "${arr[$(echo '\''x[$(git commit -m real; echo 0)]'\'')]}"'
# shellcheck disable=SC2016
BENIGN_DYNAMIC_SCRIPT_SUBSTITUTION='echo "$(bash "$f")"'
# shellcheck disable=SC2016
BENIGN_DYNAMIC_SHELL_CODE='n="$(sh -c "ls $dir")"'
# shellcheck disable=SC2016
BENIGN_ENV_DYNAMIC_VALUE='v="$(env FOO="$BAR" bash -c ls)"'
# shellcheck disable=SC2016
BENIGN_EXEC_DYNAMIC_SCRIPT='echo "$(exec bash "$f")"'
# shellcheck disable=SC2016
BENIGN_COMMAND_DYNAMIC_SCRIPT='echo "$(command bash "$f")"'
# shellcheck disable=SC2016
BENIGN_DYNAMIC_EVAL='echo "$(eval "$generated")"'

echo ""
echo "=== TC-IGC-547-001..141: non-executable git mentions ==="
echo ""

assert_detector_no_match \
  "TC-IGC-547-001 heredoc body is not executable command text" \
  "$HEREDOC_COMMIT"
assert_detector_no_match \
  "TC-IGC-547-002 indented heredoc body is not executable command text" \
  "$HEREDOC_CHAIN"
assert_detector_no_match \
  "TC-IGC-547-003 shell comment is not executable command text" \
  "$COMMENT_ONLY"
assert_detector_no_match \
  "TC-IGC-547-004 quoted mention remains ignored" \
  "$QUOTED_MENTION"

assert_resolver_no_match \
  "TC-IGC-547-005 resolver ignores heredoc body" \
  "$HEREDOC_COMMIT"
assert_resolver_no_match \
  "TC-IGC-547-006 resolver ignores shell comment" \
  "$COMMENT_ONLY"

assert_hook_rc \
  "TC-IGC-547-007 hook allows heredoc file generation" 0 \
  "$HEREDOC_COMMIT"
assert_hook_rc \
  "TC-IGC-547-008 hook allows indented heredoc file generation" 0 \
  "$HEREDOC_CHAIN"
assert_hook_rc \
  "TC-IGC-547-009 hook allows comment-only mention" 0 \
  "$COMMENT_ONLY"

assert_detector_match \
  "TC-IGC-547-010 genuine commit remains detected" \
  "$REAL_COMMIT"
assert_detector_match \
  "TC-IGC-547-011 real commit after a comment remains detected" \
  "$COMMENT_THEN_COMMIT"
assert_hook_rc \
  "TC-IGC-547-012 genuine commit from main workspace remains blocked" 2 \
  "$REAL_COMMIT"
assert_detector_match \
  "TC-IGC-547-013 hash inside quotes does not hide a later commit" \
  "$QUOTED_HASH_THEN_COMMIT"
assert_detector_match \
  "TC-IGC-547-014 commit after heredoc terminator remains detected" \
  "$HEREDOC_THEN_COMMIT"
assert_hook_rc \
  "TC-IGC-547-015 hash inside quotes does not bypass the hook" 2 \
  "$QUOTED_HASH_THEN_COMMIT"
assert_hook_rc \
  "TC-IGC-547-016 commit after heredoc terminator remains blocked" 2 \
  "$HEREDOC_THEN_COMMIT"
assert_detector_no_match \
  "TC-IGC-547-017 double-quoted heredoc body is not executable" \
  "$DOUBLE_QUOTED_HEREDOC"
assert_hook_rc \
  "TC-IGC-547-018 hook allows double-quoted heredoc file generation" 0 \
  "$DOUBLE_QUOTED_HEREDOC"
assert_detector_match \
  "TC-IGC-547-019 here-string does not hide a later commit" \
  "$HERE_STRING_THEN_COMMIT"
assert_hook_rc \
  "TC-IGC-547-020 here-string does not bypass the hook" 2 \
  "$HERE_STRING_THEN_COMMIT"
assert_detector_match \
  "TC-IGC-547-021 escaped hash does not begin a comment" \
  "$ESCAPED_HASH_THEN_COMMIT"
assert_detector_match \
  "TC-IGC-547-022 mid-word hash does not begin a comment" \
  "$MIDWORD_HASH_THEN_COMMIT"
assert_detector_match \
  "TC-IGC-547-023 quoted heredoc opener does not hide a later commit" \
  "$QUOTED_OPENER_THEN_COMMIT"
assert_detector_match \
  "TC-IGC-547-024 multiline quoted hash does not hide a later commit" \
  "$MULTILINE_QUOTE_THEN_COMMIT"
assert_large_heredoc_bounded \
  "TC-IGC-547-025 one-megabyte heredoc completes within hook budget"
assert_preprocessor_failure_detector \
  "TC-IGC-547-026 detector fails closed when preprocessing is unavailable"
assert_preprocessor_failure_resolver \
  "TC-IGC-547-027 resolver fails closed when preprocessing is unavailable"
assert_detector_no_match \
  "TC-IGC-547-028 heredoc delimiter may precede a trailing redirect" \
  "$TRAILING_REDIRECT_HEREDOC"
assert_hook_rc \
  "TC-IGC-547-029 hook allows heredoc with a trailing redirect" 0 \
  "$TRAILING_REDIRECT_HEREDOC"
assert_detector_no_match \
  "TC-IGC-547-030 escaped heredoc delimiter is recognized" \
  "$ESCAPED_DELIMITER_HEREDOC"
assert_detector_no_match \
  "TC-IGC-547-031 multiple heredoc bodies are non-executable" \
  "$MULTIPLE_HEREDOCS"
assert_hook_rc \
  "TC-IGC-547-032 hook allows multiple heredoc bodies" 0 \
  "$MULTIPLE_HEREDOCS"
assert_detector_match \
  "TC-IGC-547-033 command substitution suffix does not hide a real commit" \
  "$COMMAND_SUB_HASH_THEN_COMMIT"
assert_hook_rc \
  "TC-IGC-547-034 command substitution suffix remains fail-closed" 2 \
  "$COMMAND_SUB_HASH_THEN_COMMIT"
assert_detector_match \
  "TC-IGC-547-035 arithmetic shift is not treated as a heredoc" \
  "$ARITHMETIC_SHIFT_THEN_COMMIT"
assert_hook_rc \
  "TC-IGC-547-036 arithmetic syntax remains fail-closed" 2 \
  "$ARITHMETIC_SHIFT_THEN_COMMIT"
assert_detector_match \
  "TC-IGC-547-037 real commit on heredoc declaration line remains visible" \
  "$HEREDOC_LINE_THEN_COMMIT"
assert_detector_match \
  "TC-IGC-547-038 pipeline consumer may execute heredoc body" \
  "$PIPELINE_HEREDOC"
assert_hook_rc \
  "TC-IGC-547-039 pipeline heredoc remains fail-closed" 2 \
  "$PIPELINE_HEREDOC"
assert_detector_match \
  "TC-IGC-547-040 unquoted heredoc command substitution remains visible" \
  "$UNQUOTED_HEREDOC_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-041 unquoted heredoc substitution remains fail-closed" 2 \
  "$UNQUOTED_HEREDOC_SUBSTITUTION"
assert_detector_no_match \
  "TC-IGC-547-042 escaped heredoc substitution is literal data" \
  "$ESCAPED_HEREDOC_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-043 hook allows escaped heredoc substitution prose" 0 \
  "$ESCAPED_HEREDOC_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-044 double-quoted command substitution remains visible" \
  "$DOUBLE_QUOTED_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-045 double-quoted command substitution remains fail-closed" 2 \
  "$DOUBLE_QUOTED_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-046 double-quoted backtick substitution remains visible" \
  "$DOUBLE_QUOTED_BACKTICK"
assert_hook_rc \
  "TC-IGC-547-047 double-quoted backtick substitution remains fail-closed" 2 \
  "$DOUBLE_QUOTED_BACKTICK"
assert_detector_match \
  "TC-IGC-547-048 shell interpreter may execute quoted heredoc body" \
  "$SHELL_CONSUMER_HEREDOC"
assert_hook_rc \
  "TC-IGC-547-049 shell-consumer heredoc remains fail-closed" 2 \
  "$SHELL_CONSUMER_HEREDOC"
assert_detector_match \
  "TC-IGC-547-050 in-command cat function keeps heredoc body visible" \
  "$SHADOWED_CAT_HEREDOC"
assert_hook_rc \
  "TC-IGC-547-051 in-command cat function remains fail-closed" 2 \
  "$SHADOWED_CAT_HEREDOC"
if (
  # shellcheck disable=SC2329
  cat() { bash; }
  is_git_command commit "$HEREDOC_COMMIT"
); then
  record_pass "TC-IGC-547-052 environment cat function keeps heredoc body visible"
else
  record_fail "TC-IGC-547-052 environment cat function hid a real commit"
fi
assert_detector_match \
  "TC-IGC-547-053 continued cat function keeps heredoc body visible" \
  "$CONTINUED_CAT_FUNCTION_HEREDOC"
assert_hook_rc \
  "TC-IGC-547-054 continued cat function remains fail-closed" 2 \
  "$CONTINUED_CAT_FUNCTION_HEREDOC"
assert_detector_no_match \
  "TC-IGC-547-055 benign quoted substitution keeps git prose hidden" \
  "$BENIGN_QUOTED_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-056 hook allows benign quoted substitution prose" 0 \
  "$BENIGN_QUOTED_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-057 eval-defined cat keeps heredoc body visible" \
  "$EVAL_CAT_HEREDOC"
assert_hook_rc \
  "TC-IGC-547-058 eval-defined cat remains fail-closed" 2 \
  "$EVAL_CAT_HEREDOC"
assert_detector_match \
  "TC-IGC-547-059 shell -c substitution remains visible" \
  "$SHELL_C_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-060 shell -c substitution remains fail-closed" 2 \
  "$SHELL_C_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-061 eval substitution remains visible" \
  "$EVAL_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-062 eval substitution remains fail-closed" 2 \
  "$EVAL_SUBSTITUTION"
assert_detector_no_match \
  "TC-IGC-547-063 benign echo substitution keeps git prose hidden" \
  "$BENIGN_ECHO_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-064 hook allows benign echo substitution prose" 0 \
  "$BENIGN_ECHO_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-065 ordinary substitution parentheses keep commit visible" \
  "$PAREN_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-066 ordinary substitution parentheses remain fail-closed" 2 \
  "$PAREN_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-067 grouped shell -c commit remains visible" \
  "$SHELL_C_GROUP_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-068 grouped shell -c commit remains fail-closed" 2 \
  "$SHELL_C_GROUP_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-069 shell option argument does not hide -c code" \
  "$SHELL_C_OPTION_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-070 shell option argument remains fail-closed" 2 \
  "$SHELL_C_OPTION_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-071 comment parenthesis does not truncate substitution" \
  "$COMMENT_PAREN_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-072 comment parenthesis remains fail-closed" 2 \
  "$COMMENT_PAREN_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-073 grouped substitution commit remains visible" \
  "$GROUPED_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-074 grouped substitution commit remains fail-closed" 2 \
  "$GROUPED_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-075 shell +O argument does not hide -c code" \
  "$SHELL_PLUS_O_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-076 shell +O argument remains fail-closed" 2 \
  "$SHELL_PLUS_O_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-077 env option argument does not hide shell code" \
  "$ENV_UNSET_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-078 env option argument remains fail-closed" 2 \
  "$ENV_UNSET_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-079 command option does not hide shell code" \
  "$COMMAND_P_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-080 command option remains fail-closed" 2 \
  "$COMMAND_P_SUBSTITUTION"
assert_detector_no_match \
  "TC-IGC-547-081 EOF comment after substitution stays hidden" \
  "$SUBSTITUTION_EOF_COMMENT"
assert_hook_rc \
  "TC-IGC-547-082 hook allows EOF comment after substitution" 0 \
  "$SUBSTITUTION_EOF_COMMENT"
assert_detector_match \
  "TC-IGC-547-083 dynamic shell executor remains visible" \
  "$DYNAMIC_SHELL_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-084 dynamic shell executor remains fail-closed" 2 \
  "$DYNAMIC_SHELL_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-085 exec shell wrapper remains visible" \
  "$EXEC_SHELL_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-086 exec shell wrapper remains fail-closed" 2 \
  "$EXEC_SHELL_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-087 conditional shell execution remains visible" \
  "$IF_SHELL_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-088 conditional shell execution remains fail-closed" 2 \
  "$IF_SHELL_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-089 escaped shell command remains visible" \
  "$ESCAPED_SHELL_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-090 escaped shell command remains fail-closed" 2 \
  "$ESCAPED_SHELL_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-091 negated shell execution remains visible" \
  "$NEGATED_SHELL_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-092 negated shell execution remains fail-closed" 2 \
  "$NEGATED_SHELL_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-093 if condition shell execution remains visible" \
  "$IF_CONDITION_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-094 if condition shell execution remains fail-closed" 2 \
  "$IF_CONDITION_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-095 time-prefixed shell execution remains visible" \
  "$TIME_SHELL_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-096 time-prefixed shell execution remains fail-closed" 2 \
  "$TIME_SHELL_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-097 redirected shell execution remains visible" \
  "$REDIRECTED_SHELL_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-098 redirected shell execution remains fail-closed" 2 \
  "$REDIRECTED_SHELL_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-099 bash stdin code remains visible" \
  "$BASH_STDIN_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-100 bash stdin code remains fail-closed" 2 \
  "$BASH_STDIN_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-101 bash -s stdin code remains visible" \
  "$BASH_S_STDIN_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-102 bash -s stdin code remains fail-closed" 2 \
  "$BASH_S_STDIN_SUBSTITUTION"
assert_detector_no_match \
  "TC-IGC-547-103 simple printf keeps git prose as data" \
  "$BENIGN_PRINTF_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-104 hook allows simple printf git prose" 0 \
  "$BENIGN_PRINTF_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-105 shadowed echo remains executable" \
  "$SHADOWED_ECHO_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-106 shadowed echo remains fail-closed" 2 \
  "$SHADOWED_ECHO_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-107 shadowed printf remains executable" \
  "$SHADOWED_PRINTF_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-108 shadowed printf remains fail-closed" 2 \
  "$SHADOWED_PRINTF_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-109 path echo is not trusted as a builtin" \
  "$PATH_ECHO_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-110 path echo remains fail-closed" 2 \
  "$PATH_ECHO_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-111 path printf is not trusted as a builtin" \
  "$PATH_PRINTF_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-112 path printf remains fail-closed" 2 \
  "$PATH_PRINTF_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-113 printf -v array subscript remains executable" \
  "$PRINTF_V_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-114 printf -v array subscript remains fail-closed" 2 \
  "$PRINTF_V_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-115 eval consumer keeps generated commit visible" \
  "$EVAL_OUTPUT_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-116 eval consumer remains fail-closed" 2 \
  "$EVAL_OUTPUT_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-117 bash -c consumer keeps generated commit visible" \
  "$BASH_C_OUTPUT_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-118 bash -c consumer remains fail-closed" 2 \
  "$BASH_C_OUTPUT_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-119 process-substitution consumer keeps commit visible" \
  "$BASH_PROCESS_OUTPUT_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-120 process-substitution consumer remains fail-closed" 2 \
  "$BASH_PROCESS_OUTPUT_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-121 pipeline consumer keeps generated commit visible" \
  "$PIPE_OUTPUT_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-122 pipeline consumer remains fail-closed" 2 \
  "$PIPE_OUTPUT_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-123 prefix redirect consumer keeps commit visible" \
  "$PREFIX_REDIRECT_OUTPUT_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-124 prefix redirect consumer remains fail-closed" 2 \
  "$PREFIX_REDIRECT_OUTPUT_SUBSTITUTION"
assert_detector_match \
  "TC-IGC-547-125 array subscript consumer keeps commit visible" \
  "$ARRAY_SUBSCRIPT_OUTPUT_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-126 array subscript consumer remains fail-closed" 2 \
  "$ARRAY_SUBSCRIPT_OUTPUT_SUBSTITUTION"
assert_detector_no_match \
  "TC-IGC-547-127 dynamic script path without git text stays allowed" \
  "$BENIGN_DYNAMIC_SCRIPT_SUBSTITUTION"
assert_hook_rc \
  "TC-IGC-547-128 hook allows dynamic script path without git text" 0 \
  "$BENIGN_DYNAMIC_SCRIPT_SUBSTITUTION"
assert_detector_no_match \
  "TC-IGC-547-129 dynamic shell code without git text stays allowed" \
  "$BENIGN_DYNAMIC_SHELL_CODE"
assert_hook_rc \
  "TC-IGC-547-130 hook allows dynamic shell code without git text" 0 \
  "$BENIGN_DYNAMIC_SHELL_CODE"
assert_detector_no_match \
  "TC-IGC-547-131 dynamic env value without git text stays allowed" \
  "$BENIGN_ENV_DYNAMIC_VALUE"
assert_hook_rc \
  "TC-IGC-547-132 hook allows dynamic env value without git text" 0 \
  "$BENIGN_ENV_DYNAMIC_VALUE"
assert_detector_no_match \
  "TC-IGC-547-133 exec dynamic script without git text stays allowed" \
  "$BENIGN_EXEC_DYNAMIC_SCRIPT"
assert_hook_rc \
  "TC-IGC-547-134 hook allows exec dynamic script without git text" 0 \
  "$BENIGN_EXEC_DYNAMIC_SCRIPT"
assert_detector_no_match \
  "TC-IGC-547-135 command dynamic script without git text stays allowed" \
  "$BENIGN_COMMAND_DYNAMIC_SCRIPT"
assert_hook_rc \
  "TC-IGC-547-136 hook allows command dynamic script without git text" 0 \
  "$BENIGN_COMMAND_DYNAMIC_SCRIPT"
assert_detector_no_match \
  "TC-IGC-547-137 dynamic eval without git text stays allowed" \
  "$BENIGN_DYNAMIC_EVAL"
assert_hook_rc \
  "TC-IGC-547-138 hook allows dynamic eval without git text" 0 \
  "$BENIGN_DYNAMIC_EVAL"
assert_large_ambiguous_hook_bounded \
  "TC-IGC-547-139 large ambiguous command is blocked within hook budget"
assert_resolver_uncertain_match \
  "TC-IGC-547-140 resolver keeps commit after masked heredoc visible" \
  "$HEREDOC_THEN_COMMIT"
assert_large_ambiguous_hook_bounded \
  "TC-IGC-547-141 twenty-kilobyte command is blocked within hook budget" 625

echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

[[ "$FAIL" -eq 0 ]]
