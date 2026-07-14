#!/bin/bash
# Shared Claude/Codex edit payload normalization tests for issue #486.
# shellcheck disable=SC1090,SC2015

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_LIB="$PROJECT_ROOT/skills/autonomous-common/hooks/lib.sh"
CHECK_TEST_PLAN="$PROJECT_ROOT/skills/autonomous-common/hooks/check-test-plan.sh"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-codex-hooks.sh"
source "$HOOK_LIB"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$desc"
  else
    bad "$desc (expected=$(printf %q "$expected"), actual=$(printf %q "$actual"))"
  fi
}

echo "=== TC-CDCR-020/021: Claude Write/Edit ==="
write_payload='{"tool_name":"Write","tool_input":{"file_path":"src/new.ts"}}'
out=$(parse_edit_file_operations "$write_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "Write emits an add operation" \
  $'add\tsrc/new.ts' "$out" \
  || bad "Write emits an add operation (rc=$rc)"
out=$(parse_edit_file_paths "$write_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "Write emits file_path" "src/new.ts" "$out" \
  || bad "Write emits file_path (rc=$rc)"

edit_payload='{"tool_name":"Edit","tool_input":{"file_path":"src/path with spaces.ts"}}'
out=$(parse_edit_file_operations "$edit_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "Edit emits an edit operation" \
  $'edit\tsrc/path with spaces.ts' "$out" \
  || bad "Edit emits an edit operation (rc=$rc)"
out=$(parse_edit_file_paths "$edit_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "Edit preserves spaces" "src/path with spaces.ts" "$out" \
  || bad "Edit preserves spaces (rc=$rc)"

echo "=== TC-CDCR-021A: translated write/edit tool names remain supported ==="
for tool_name in write_file WriteFile; do
  translated_payload=$(jq -nc --arg tool "$tool_name" \
    '{tool_name:$tool,tool_input:{file_path:"src/translated.ts"}}')
  out=$(parse_edit_file_operations "$translated_payload" 2>/dev/null); rc=$?
  [[ "$rc" -eq 0 ]] && assert_eq "$tool_name emits an add candidate" \
    $'add\tsrc/translated.ts' "$out" \
    || bad "$tool_name emits an add candidate (rc=$rc)"
done
for tool_name in replace StrReplaceFile; do
  translated_payload=$(jq -nc --arg tool "$tool_name" \
    '{tool_name:$tool,tool_input:{file_path:"src/translated.ts"}}')
  out=$(parse_edit_file_operations "$translated_payload" 2>/dev/null); rc=$?
  [[ "$rc" -eq 0 ]] && assert_eq "$tool_name emits an edit operation" \
    $'edit\tsrc/translated.ts' "$out" \
    || bad "$tool_name emits an edit operation (rc=$rc)"
done
kiro_create_payload='{"tool_name":"fs_write","tool_input":{"command":"create","path":"src/kiro-new.ts"}}'
out=$(parse_edit_file_operations "$kiro_create_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "Kiro create uses path and emits an add candidate" \
  $'add\tsrc/kiro-new.ts' "$out" \
  || bad "Kiro create uses path and emits an add candidate (rc=$rc)"
for kiro_command in str_replace insert append; do
  kiro_edit_payload=$(jq -nc --arg command "$kiro_command" \
    '{tool_name:"fs_write",tool_input:{command:$command,path:"src/kiro-old.ts"}}')
  out=$(parse_edit_file_operations "$kiro_edit_payload" 2>/dev/null); rc=$?
  [[ "$rc" -eq 0 ]] && assert_eq "Kiro $kiro_command emits an edit operation" \
    $'edit\tsrc/kiro-old.ts' "$out" \
    || bad "Kiro $kiro_command emits an edit operation (rc=$rc)"
done
windsurf_payload='{"agent_action_name":"pre_write_code","tool_info":{"file_path":"src/windsurf.ts"}}'
out=$(parse_edit_file_operations "$windsurf_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "native Windsurf payload emits an add candidate" \
  $'add\tsrc/windsurf.ts' "$out" \
  || bad "native Windsurf payload emits an add candidate (rc=$rc)"

echo "=== TC-CDCR-022: Codex structured multi-file apply_patch ==="
codex_payload=$(jq -n --arg command '*** Begin Patch
*** Add File: docs/first.md
+documentation
*** Add File: src/new file.ts
+export const value = 1;
*** Update File: src/old name.ts
*** Move to: src/new name.ts
@@
-old
+new
*** Delete File: src/delete me.ts
*** End Patch' \
  '{tool_name:"apply_patch",tool_input:{command:$command}}')
expected=$'docs/first.md\nsrc/new file.ts\nsrc/old name.ts\nsrc/new name.ts\nsrc/delete me.ts'
out=$(parse_edit_file_paths "$codex_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "all patch paths are emitted in order" "$expected" "$out" \
  || bad "all patch paths are emitted in order (rc=$rc)"
expected_operations=$'add\tdocs/first.md\nadd\tsrc/new file.ts\nedit\tsrc/old name.ts\nmove\tsrc/new name.ts\ndelete\tsrc/delete me.ts'
out=$(parse_edit_file_operations "$codex_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "patch operations retain their semantics" \
  "$expected_operations" "$out" \
  || bad "patch operations retain their semantics (rc=$rc)"

echo "=== TC-CDCR-024/025: malformed recognized edits and unknown tools ==="
malformed='{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"}}'
if parse_edit_file_paths "$malformed" >/dev/null 2>&1; then
  bad "malformed apply_patch fails loudly"
else
  ok "malformed apply_patch fails loudly"
fi
missing_boundary='{"tool_name":"apply_patch","tool_input":{"command":"*** Add File: src/new.ts\n+value"}}'
if parse_edit_file_operations "$missing_boundary" >/dev/null 2>&1; then
  bad "apply_patch without begin/end markers fails loudly"
else
  ok "apply_patch without begin/end markers fails loudly"
fi
for malformed_tool_name in \
  '{"tool_input":{"command":"*** Begin Patch\n*** Add File: src/new.ts\n+value\n*** End Patch"}}' \
  '{"tool_name":null,"tool_input":{"command":"*** Begin Patch\n*** Add File: src/new.ts\n+value\n*** End Patch"}}' \
  '{"tool_name":42,"tool_input":{"command":"*** Begin Patch\n*** Add File: src/new.ts\n+value\n*** End Patch"}}'; do
  if parse_edit_file_operations "$malformed_tool_name" >/dev/null 2>&1; then
    bad "missing/non-string tool_name must fail"
  else
    ok "missing/non-string tool_name fails"
  fi
done
for malformed_path in '42' 'true' '[]' '{}'; do
  malformed_file_payload=$(jq -nc --argjson path "$malformed_path" \
    '{tool_name:"Write",tool_input:{file_path:$path}}')
  if parse_edit_file_operations "$malformed_file_payload" >/dev/null 2>&1; then
    bad "non-string file_path must fail ($malformed_path)"
  else
    ok "non-string file_path fails ($malformed_path)"
  fi
done
for malformed_kiro_payload in \
  '{"tool_name":"fs_write","tool_input":{"command":"create","path":42}}' \
  '{"tool_name":"fs_write","tool_input":{"command":42,"path":"src/new.ts"}}' \
  '{"tool_name":"fs_write","tool_input":{"command":"unknown","path":"src/new.ts"}}'; do
  if parse_edit_file_operations "$malformed_kiro_payload" >/dev/null 2>&1; then
    bad "malformed Kiro fs_write payload must fail"
  else
    ok "malformed Kiro fs_write payload fails"
  fi
done
unknown='{"tool_name":"Read","tool_input":{"file_path":"src/not-an-edit.ts"}}'
out=$(parse_edit_file_paths "$unknown" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "Read with file_path is still a no-op" "" "$out" \
  || bad "unknown tool is a no-op (rc=$rc)"

misleading_payload=$(jq -c '.tool_input.file_path = "src/wrong.ts"' <<<"$codex_payload")
out=$(parse_edit_file_paths "$misleading_payload" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && assert_eq "apply_patch ignores misleading file_path" \
  "$expected" "$out" \
  || bad "apply_patch ignores misleading file_path (rc=$rc)"

echo "=== TC-CDCR-023: check-test-plan evaluates creation operations ==="
repo="$TMPDIR/policy-repo"
mkdir -p "$repo/docs" "$repo/src"
git -C "$repo" init --quiet --initial-branch=main
policy_out=$(cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$CHECK_TEST_PLAN" \
  <<<"$codex_payload" 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$policy_out" == *"Reminder: Test Plan First"* ]]; then
  ok "later new src file triggers policy after a docs path"
else
  bad "later new src file triggers policy after a docs path (rc=$rc)"
fi
policy_out=$(cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$CHECK_TEST_PLAN" \
  <<<"$write_payload" 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$policy_out" == *"Reminder: Test Plan First"* ]]; then
  ok "equivalent Claude Write triggers the same policy"
else
  bad "equivalent Claude Write triggers the same policy (rc=$rc)"
fi
policy_out=$(cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$CHECK_TEST_PLAN" \
  <<<"$edit_payload" 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$policy_out" != *"Reminder: Test Plan First"* ]]; then
  ok "Claude Edit does not masquerade as file creation"
else
  bad "Claude Edit does not masquerade as file creation (rc=$rc)"
fi

policy_out=$(cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$CHECK_TEST_PLAN" \
  <<<"$kiro_create_payload" 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$policy_out" == *"Reminder: Test Plan First"* ]]; then
  ok "native Kiro create still triggers file-creation policy"
else
  bad "native Kiro create still triggers file-creation policy (rc=$rc)"
fi
policy_out=$(cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$CHECK_TEST_PLAN" \
  <<<"$windsurf_payload" 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$policy_out" == *"Reminder: Test Plan First"* ]]; then
  ok "native Windsurf write still triggers file-creation policy"
else
  bad "native Windsurf write still triggers file-creation policy (rc=$rc)"
fi

malformed_file_payload='{"tool_name":"Write","tool_input":{"file_path":42}}'
(cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$CHECK_TEST_PLAN" \
  <<<"$malformed_file_payload" >/dev/null 2>&1)
rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "malformed file path makes the hook exit exactly 2"
else
  bad "malformed file path makes the hook exit exactly 2 (rc=$rc)"
fi

pure_move_payload=$(jq -n --arg command '*** Begin Patch
*** Update File: src/original.ts
*** Move to: src/renamed.ts
@@
-old
+new
*** End Patch' \
  '{tool_name:"apply_patch",tool_input:{command:$command}}')
policy_out=$(cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$CHECK_TEST_PLAN" \
  <<<"$pure_move_payload" 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$policy_out" != *"Reminder: Test Plan First"* ]]; then
  ok "pure move does not trigger a new-file reminder"
else
  bad "pure move does not trigger a new-file reminder (rc=$rc)"
fi

(cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$CHECK_TEST_PLAN" \
  <<<"$missing_boundary" >/dev/null 2>&1)
rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "malformed direct hook invocation exits exactly 2"
else
  bad "malformed direct hook invocation exits exactly 2 (rc=$rc)"
fi

echo "=== TC-CDCR-026: generated command executes without CLAUDE_PROJECT_DIR ==="
repo="$TMPDIR/generated repo"
mkdir -p "$repo/nested/dir"
git -C "$repo" init --quiet --initial-branch=main
ln -s "$PROJECT_ROOT/skills/autonomous-common/hooks" "$repo/hooks"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
hook_command=$(jq -r '
  .hooks.PreToolUse[]
  | select(.matcher == "^apply_patch$")
  | .hooks[]
  | select(.command | contains("check-test-plan.sh"))
  | .command
' "$repo/.codex/hooks.json")
generated_out=$(cd "$repo/nested/dir" && unset CLAUDE_PROJECT_DIR && \
  eval "$hook_command" <<<"$codex_payload" 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$generated_out" == *"Reminder: Test Plan First"* ]]; then
  ok "generated hook resolves worktree root and applies policy"
else
  bad "generated hook resolves worktree root and applies policy (rc=$rc, command=$hook_command)"
fi
(cd "$repo/nested/dir" && unset CLAUDE_PROJECT_DIR && \
  eval "$hook_command" <<<"$missing_boundary" >/dev/null 2>&1)
rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "malformed generated hook invocation exits exactly 2"
else
  bad "malformed generated hook invocation exits exactly 2 (rc=$rc)"
fi

echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
