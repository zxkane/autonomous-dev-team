#!/bin/bash
# Shared PostToolUse exit-code normalization tests for issue #532.
# shellcheck disable=SC1090

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_LIB="$PROJECT_ROOT/skills/autonomous-common/hooks/lib.sh"
ACTION_HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/post-git-action-clear.sh"
PUSH_HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/post-git-push.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "$HOOK_LIB"

ok() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

bad() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

assert_parse() {
  local desc="$1"
  local expected="$2"
  local payload="$3"
  local actual rc

  : > "$TMPDIR/parse.stderr"
  actual=$(parse_exit_code "$payload" 2>"$TMPDIR/parse.stderr")
  rc=$?
  if [[ "$rc" -eq 0 && "$actual" == "$expected" && ! -s "$TMPDIR/parse.stderr" ]]; then
    ok "$desc"
  else
    bad "$desc (expected=$expected, actual=${actual:-<empty>}, rc=$rc)"
  fi
}

run_hook() {
  local repo="$1"
  local hook="$2"
  local payload="$3"
  shift 3

  (
    cd "$repo" &&
      printf '%s' "$payload" | bash "$hook" "$@"
  )
}

object_camel='{"tool_response":{"exitCode":0}}'
object_snake='{"tool_response":{"exit_code":7}}'
codex_success='{"tool_response":"Chunk ID: test\nProcess exited with code 0\nFinal output:\nok"}'
codex_failure='{"tool_response":"Chunk ID: test\nProcess exited with code 7\nFinal output:\n"}'
codex_unknown='{"tool_response":"Chunk ID: test\nFinal output:\nno status"}'
codex_embedded='{"tool_response":"prefix Process exited with code 0 suffix"}'
invalid_json=$'{"tool_response":"line one\nline two"}'

echo "=== TC-CDCR-028: object response compatibility ==="
assert_parse "camel-case object exit code remains supported" "0" "$object_camel"
assert_parse "snake-case object exit code remains supported" "7" "$object_snake"

echo "=== TC-CDCR-029: Codex string response normalization ==="
assert_parse "Codex success trailer returns zero" "0" "$codex_success"
assert_parse "Codex failure trailer preserves the non-zero code" "7" "$codex_failure"

echo "=== TC-CDCR-029A: unexpected and malformed responses fail closed ==="
assert_parse "string without an exit trailer fails closed" "1" "$codex_unknown"
assert_parse "embedded exit phrase is not treated as a trailer" "1" "$codex_embedded"
assert_parse "numeric response fails closed" "1" '{"tool_response":42}'
assert_parse "array response fails closed" "1" '{"tool_response":[]}'
assert_parse "null response fails closed" "1" '{"tool_response":null}'
assert_parse "invalid JSON fails closed without leaking a jq error" "1" "$invalid_json"

set_e_output=$(
  HOOK_LIB="$HOOK_LIB" PAYLOAD="$invalid_json" bash -c '
    set -e
    source "$HOOK_LIB"
    exit_code=$(parse_exit_code "$PAYLOAD")
    [[ "$exit_code" == "1" ]]
    printf "reached"
  ' 2>"$TMPDIR/set-e.stderr"
)
set_e_rc=$?
if [[ "$set_e_rc" -eq 0 && "$set_e_output" == "reached" &&
      ! -s "$TMPDIR/set-e.stderr" ]]; then
  ok "invalid JSON does not abort a set -e consumer"
else
  bad "invalid JSON aborted a set -e consumer (rc=$set_e_rc)"
fi

echo "=== TC-CDCR-029B: jq remains mandatory ==="
mkdir "$TMPDIR/no-jq"
missing_jq=$(PATH="$TMPDIR/no-jq" parse_exit_code "$object_camel")
missing_jq_rc=$?
if [[ "$missing_jq" == "1" && "$missing_jq_rc" -ne 0 ]]; then
  ok "missing jq returns one and a non-zero function status"
else
  bad "missing jq contract changed (output=${missing_jq:-<empty>}, rc=$missing_jq_rc)"
fi

echo "=== TC-CDCR-029C: PostToolUse consumers ==="
repo="$TMPDIR/repo"
mkdir -p "$repo/.agents/state"
git -C "$repo" init --quiet --initial-branch=main

non_git_payload='{"tool_input":{"command":"echo ok"},"tool_response":"Chunk ID: test\nProcess exited with code 0\nFinal output:\nok"}'
for hook in "$ACTION_HOOK" "$PUSH_HOOK"; do
  : > "$TMPDIR/hook.stderr"
  hook_output=$(run_hook "$repo" "$hook" "$non_git_payload" 2>"$TMPDIR/hook.stderr")
  hook_rc=$?
  if [[ "$hook_rc" -eq 0 && -z "$hook_output" && ! -s "$TMPDIR/hook.stderr" ]]; then
    ok "$(basename "$hook") treats a successful non-git command as a quiet no-op"
  else
    bad "$(basename "$hook") successful non-git no-op (rc=$hook_rc)"
  fi
done

state_file="$repo/.agents/state/code-simplifier.json"
printf '{}\n' > "$state_file"
commit_success='{"tool_input":{"command":"git commit -m test"},"tool_response":"Chunk ID: test\nProcess exited with code 0\nFinal output:\n"}'
run_hook "$repo" "$ACTION_HOOK" "$commit_success" commit code-simplifier \
  >"$TMPDIR/commit-success.out" 2>"$TMPDIR/commit-success.err"
commit_rc=$?
if [[ "$commit_rc" -eq 0 && ! -e "$state_file" ]]; then
  ok "successful Codex commit response clears workflow state"
else
  bad "successful Codex commit response clears workflow state (rc=$commit_rc)"
fi

printf '{}\n' > "$state_file"
commit_failure='{"tool_input":{"command":"git commit -m test"},"tool_response":"Chunk ID: test\nProcess exited with code 7\nFinal output:\n"}'
run_hook "$repo" "$ACTION_HOOK" "$commit_failure" commit code-simplifier \
  >"$TMPDIR/commit-failure.out" 2>"$TMPDIR/commit-failure.err"
commit_rc=$?
if [[ "$commit_rc" -eq 0 && -e "$state_file" ]]; then
  ok "failed Codex commit response does not clear workflow state"
else
  bad "failed Codex commit response preserves workflow state (rc=$commit_rc)"
fi

push_success='{"tool_input":{"command":"git push origin HEAD"},"tool_response":"Chunk ID: test\nProcess exited with code 0\nFinal output:\n"}'
push_output=$(run_hook "$repo" "$PUSH_HOOK" "$push_success" 2>"$TMPDIR/push-success.err")
push_rc=$?
if [[ "$push_rc" -eq 0 && "$push_output" == *"Post-Push Verification Required"* ]]; then
  ok "successful Codex push response emits the verification reminder"
else
  bad "successful Codex push response emits the verification reminder (rc=$push_rc)"
fi

push_failure='{"tool_input":{"command":"git push origin HEAD"},"tool_response":"Chunk ID: test\nProcess exited with code 7\nFinal output:\n"}'
push_output=$(run_hook "$repo" "$PUSH_HOOK" "$push_failure" 2>"$TMPDIR/push-failure.err")
push_rc=$?
if [[ "$push_rc" -eq 0 && -z "$push_output" ]]; then
  ok "failed Codex push response does not emit the verification reminder"
else
  bad "failed Codex push response skips the verification reminder (rc=$push_rc)"
fi

echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
