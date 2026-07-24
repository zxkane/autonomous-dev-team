#!/bin/bash
# Regression coverage for issues #534 and #537 command-context resolution.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/block-commit-outside-worktree.sh"
LIB="$PROJECT_ROOT/skills/autonomous-common/hooks/lib.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/block-commit-context.XXXXXX")"
TEST_HOME="$TMPROOT/home"
REPO_A="$TMPROOT/repo-a"
REPO_A_LINKED="$TMPROOT/repo-a-linked"
REPO_B="$TEST_HOME/unrelated-repo"
REPO_B_LINKED="$TMPROOT/repo-b-linked"
REPO_B_ALIAS="$TMPROOT/repo B alias"
REPO_BACKSLASH="$TEST_HOME/repo\\q"
REPO_QUOTE="$TEST_HOME/repo\"q"
LOGICAL_LINK="$REPO_A/link-to-b-subdir"
DASH_REPO="$REPO_A/-"
NON_GIT="$TMPROOT/not-a-repo"
MISSING="$TMPROOT/missing-repo"

trap 'rm -rf "$TMPROOT"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# shellcheck source=/dev/null
source "$LIB"

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Hook Test"
  printf 'initial\n' > "$repo/initial.txt"
  git -C "$repo" add initial.txt
  git -C "$repo" commit -qm "initial"
}

mkdir -p "$TEST_HOME" "$NON_GIT"
init_repo "$REPO_A"
init_repo "$REPO_B"
init_repo "$REPO_BACKSLASH"
init_repo "$REPO_QUOTE"
init_repo "$DASH_REPO"
mkdir -p "$REPO_B/subdir"
git -C "$REPO_A" worktree add -q -b linked-a "$REPO_A_LINKED"
git -C "$REPO_B" worktree add -q -b linked-b "$REPO_B_LINKED"
ln -s "$REPO_B" "$REPO_B_ALIAS"
ln -s "$REPO_B/subdir" "$LOGICAL_LINK"

CANON_A="$(cd "$REPO_A" && pwd -P)"
CANON_B="$(cd "$REPO_B" && pwd -P)"
CANON_BACKSLASH="$(cd "$REPO_BACKSLASH" && pwd -P)"
CANON_QUOTE="$(cd "$REPO_QUOTE" && pwd -P)"
REPO_BACKSLASH_ESCAPED="${REPO_BACKSLASH//\\/\\\\}"
REPO_QUOTE_ESCAPED="${REPO_QUOTE//\"/\\\"}"

record_pass() {
  echo -e "  ${GREEN}PASS${NC}: $1"
  PASS=$((PASS + 1))
}

record_fail() {
  echo -e "  ${RED}FAIL${NC}: $1"
  FAIL=$((FAIL + 1))
}

run_hook() {
  local cwd="$1"
  local command="$2"
  local payload

  payload=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}')
  HOOK_OUTPUT=$(
    cd "$cwd" &&
      printf '%s' "$payload" | HOME="$TEST_HOME" bash "$HOOK" 2>&1
  )
  HOOK_RC=$?
}

assert_hook_rc() {
  local id="$1"
  local expected="$2"
  local cwd="$3"
  local command="$4"

  run_hook "$cwd" "$command"
  if [[ "$HOOK_RC" -eq "$expected" ]]; then
    record_pass "$id (hook rc=$HOOK_RC)"
  else
    record_fail "$id (expected hook rc=$expected, got $HOOK_RC: $HOOK_OUTPUT)"
  fi
}

run_resolver() {
  local operation="$1"
  local command="$2"
  local base_dir="$3"

  RESOLVE_OUTPUT=$(
    HOME="$TEST_HOME" resolve_git_command_cwd "$operation" "$command" "$base_dir" 2>/dev/null
  )
  RESOLVE_RC=$?
}

assert_resolver() {
  local id="$1"
  local expected_rc="$2"
  local expected_output="$3"
  local operation="$4"
  local command="$5"
  local base_dir="$6"

  run_resolver "$operation" "$command" "$base_dir"
  if [[ "$RESOLVE_RC" -eq "$expected_rc" && "$RESOLVE_OUTPUT" == "$expected_output" ]]; then
    record_pass "$id (resolver rc=$RESOLVE_RC, output='$RESOLVE_OUTPUT')"
  else
    record_fail "$id (expected rc=$expected_rc/output='$expected_output', got rc=$RESOLVE_RC/output='$RESOLVE_OUTPUT')"
  fi
}

echo ""
echo "=== TC-BCOW-001..015: block-commit command context ==="
echo ""

assert_hook_rc \
  "TC-BCOW-001 exact unrelated-repo reproduction" 0 "$REPO_A" \
  'cd ~/unrelated-repo && git add some/file && git commit -m "unrelated change"'

assert_hook_rc \
  "TC-BCOW-002 bare commit from repo A main" 2 "$REPO_A" \
  'git commit -m "main change"'

assert_hook_rc \
  "TC-BCOW-003 explicit cd to repo A main" 2 "$REPO_A" \
  "cd $REPO_A && git commit -m main"

assert_hook_rc \
  "TC-BCOW-004 cd to repo A linked worktree" 0 "$REPO_A" \
  "cd $REPO_A_LINKED && git commit -m linked"

assert_hook_rc \
  "TC-BCOW-005 cd to repo B main" 0 "$REPO_A" \
  "cd $REPO_B && git commit -m unrelated"

assert_hook_rc \
  "TC-BCOW-006 cd to repo B linked worktree" 0 "$REPO_A" \
  "cd $REPO_B_LINKED && git commit -m unrelated-linked"

assert_hook_rc \
  "TC-BCOW-007a relative path resolves from hook cwd" 0 "$REPO_A" \
  'cd ../home/unrelated-repo && git commit -m relative'
assert_resolver \
  "TC-BCOW-007b single-quoted literal path canonicalizes" 0 "$CANON_B" commit \
  "cd '$REPO_B_ALIAS' && git commit -m single" "$REPO_A"
assert_resolver \
  "TC-BCOW-007c double-quoted literal path canonicalizes" 0 "$CANON_B" commit \
  "cd \"$REPO_B_ALIAS\" && git commit -m double" "$REPO_A"
assert_resolver \
  "TC-BCOW-007d tilde path expands only from HOME" 0 "$CANON_B" commit \
  'cd ~/unrelated-repo && git commit -m tilde' "$REPO_A"
assert_resolver \
  "TC-BCOW-007e bare command uses canonical base dir" 0 "$CANON_A" commit \
  'git commit -m bare' "$REPO_A/."
assert_resolver \
  "TC-BCOW-007f cd resolves symlink dot-dot logically" 0 "$CANON_A" commit \
  'cd link-to-b-subdir/.. && git commit -m logical-cd' "$REPO_A"
assert_hook_rc \
  "TC-BCOW-007g logical cd remains in repo A main" 2 "$REPO_A" \
  'cd link-to-b-subdir/.. && git commit -m logical-cd'
assert_resolver \
  "TC-BCOW-007h double-quoted literal backslash is preserved" 0 "$CANON_BACKSLASH" commit \
  "cd \"$REPO_BACKSLASH\" && git commit -m backslash" "$REPO_A"
assert_hook_rc \
  "TC-BCOW-007i double-quoted backslash path targets unrelated repo" 0 "$REPO_A" \
  "cd \"$REPO_BACKSLASH\" && git commit -m backslash"
assert_resolver \
  "TC-BCOW-007j double-quoted escaped backslash is decoded" 0 "$CANON_BACKSLASH" commit \
  "cd \"$REPO_BACKSLASH_ESCAPED\" && git commit -m escaped-backslash" "$REPO_A"
assert_hook_rc \
  "TC-BCOW-007k escaped-backslash path targets unrelated repo" 0 "$REPO_A" \
  "cd \"$REPO_BACKSLASH_ESCAPED\" && git commit -m escaped-backslash"
assert_resolver \
  "TC-BCOW-007l double-quoted escaped quote is decoded" 0 "$CANON_QUOTE" commit \
  "cd \"$REPO_QUOTE_ESCAPED\" && git commit -m escaped-quote" "$REPO_A"
assert_hook_rc \
  "TC-BCOW-007m escaped-quote path targets unrelated repo" 0 "$REPO_A" \
  "cd \"$REPO_QUOTE_ESCAPED\" && git commit -m escaped-quote"

assert_hook_rc \
  "TC-BCOW-008a quoted absolute git -C targets repo B" 0 "$REPO_A" \
  "git -C \"$REPO_B\" commit -m unrelated"
assert_resolver \
  "TC-BCOW-008b relative git -C resolves from base dir" 0 "$CANON_B" commit \
  'git -C ../home/unrelated-repo commit -m relative-c' "$REPO_A"
assert_resolver \
  "TC-BCOW-008c git -C resolves symlink dot-dot physically" 0 "$CANON_B" commit \
  'git -C link-to-b-subdir/.. commit -m physical-c' "$REPO_A"
assert_hook_rc \
  "TC-BCOW-008d physical git -C targets repo B" 0 "$REPO_A" \
  'git -C link-to-b-subdir/.. commit -m physical-c'

assert_hook_rc \
  "TC-BCOW-009a missing target fails closed" 2 "$REPO_A" \
  "cd $MISSING && git commit -m missing"
assert_hook_rc \
  "TC-BCOW-009b non-git target fails closed" 2 "$REPO_A" \
  "cd $NON_GIT && git commit -m non-git"

assert_unsupported() {
  local suffix="$1"
  local description="$2"
  local command="$3"

  assert_resolver "TC-BCOW-010${suffix} helper: $description" 2 "" commit \
    "$command" "$REPO_A"
  assert_hook_rc "TC-BCOW-010${suffix} $description" 2 "$REPO_A" "$command"
}

COMMAND_SENTINEL="$TMPROOT/command-substitution-executed"
BACKTICK_SENTINEL="$TMPROOT/backtick-executed"
PROCESS_SENTINEL="$TMPROOT/process-substitution-executed"

# shellcheck disable=SC2016
assert_unsupported "a" "variable expansion" \
  'cd "$TARGET_REPO" && git commit -m variable'
assert_unsupported "b" "command substitution" \
  "cd \"\$(touch '$COMMAND_SENTINEL')\" && git commit -m substitution"
assert_unsupported "c" "backtick substitution" \
  "cd \`touch '$BACKTICK_SENTINEL'\` && git commit -m backtick"
assert_unsupported "d" "process substitution" \
  "cd <(touch '$PROCESS_SENTINEL') && git commit -m process"
# shellcheck disable=SC2016
assert_unsupported "e" "arithmetic expansion" \
  'cd "$((1 + 1))" && git commit -m arithmetic'
assert_unsupported "f" "brace expansion" \
  'cd {one,two} && git commit -m brace'
assert_unsupported "g" "repeated cd" \
  "cd $REPO_B && cd $REPO_B && git commit -m repeated"
assert_unsupported "h" "cd mixed with git -C" \
  "cd $REPO_B && git -C $REPO_B commit -m mixed"
assert_unsupported "i" "intermediate non-git-add command" \
  "cd $REPO_B && printf x && git commit -m intermediate"
assert_unsupported "j" "malformed quote" \
  "cd \"$REPO_B && git commit -m malformed"
assert_unsupported "k" "multiple commit invocations" \
  'git commit -m first && git commit -m second'
assert_unsupported "l" "multiple -C options" \
  "git -C $REPO_B -C $REPO_B commit -m multiple-c"
assert_unsupported "m" "attached -C path" \
  "git -C$REPO_B commit -m attached-c"
assert_unsupported "n" "other git global option" \
  'git -c core.hooksPath=/tmp commit -m global-option'
assert_unsupported "o" "subshell" \
  "(cd $REPO_B && git commit -m subshell)"
assert_unsupported "p" "pipeline" \
  'printf x | git commit -m pipeline'
assert_unsupported "q" "background command" \
  'git commit -m background &'
assert_unsupported "r" "semicolon control flow" \
  'printf x; git commit -m semicolon'
assert_unsupported "s" "or control flow" \
  'false || git commit -m or-flow'
assert_unsupported "t" "env wrapper" \
  'env git commit -m env-wrapper'
assert_unsupported "u" "sudo wrapper" \
  'sudo git commit -m sudo-wrapper'
assert_unsupported "v" "special cd dash operand" \
  'cd - && git commit -m oldpwd'
# shellcheck disable=SC2016
assert_unsupported "w" "variable expansion inside operation word" \
  'git co${UNSET}mmit -m expanded-operation'
assert_unsupported "x" "escape syntax inside git word" \
  'g\it commit -m escaped-git'
assert_unsupported "y" "ANSI-C quote syntax inside git word" \
  "$'git' commit -m ansi-c-git"
assert_unsupported "z1" "generic short git global option" \
  'git -p commit --dry-run'
assert_unsupported "z2" "generic uppercase git global option" \
  'git -P commit --dry-run'
assert_unsupported "z3" "ANSI-C hex escapes inside git word" \
  "$'\\x67\\x69\\x74' commit --dry-run"
assert_unsupported "z4" "ANSI-C fragment inside git word" \
  "g$'i't commit --dry-run"
assert_unsupported "z5" "ANSI-C fragment inside operation word" \
  "git c$'o'mmit --dry-run"
assert_unsupported "z6" "ANSI-C octal escapes inside git word" \
  "$'\\147\\151\\164' commit --dry-run"
assert_unsupported "z7" "ANSI-C Unicode fragment inside operation word" \
  "git c$'\\u006f'mmit --dry-run"
assert_unsupported "z8" "ANSI-C segment-local NUL truncation inside git word" \
  "$'gi\\x00ignored't commit --dry-run"
assert_unsupported "z9" "ANSI-C segment-local NUL truncation inside operation word" \
  "git $'commi\\x00ignored't --dry-run"
assert_unsupported "z10" "ANSI-C modulo-octal escapes inside git word" \
  "$'\\547\\551\\564' commit --dry-run"
assert_unsupported "z11" "ANSI-C modulo-octal NUL inside git word" \
  "$'git\\400ignored' commit --dry-run"
assert_unsupported "z12" "ANSI-C control NUL inside git word" \
  "$'git\\c@ignored' commit --dry-run"
assert_unsupported "z13" "ANSI-C invalid Unicode escape inside git word" \
  "$'g\\U80000067it' commit --dry-run"

for sentinel_case in \
  "TC-BCOW-010z14 command substitution:$COMMAND_SENTINEL" \
  "TC-BCOW-010z15 backtick substitution:$BACKTICK_SENTINEL" \
  "TC-BCOW-010z16 process substitution:$PROCESS_SENTINEL"; do
  sentinel_id="${sentinel_case%%:*}"
  sentinel_path="${sentinel_case#*:}"
  if [[ ! -e "$sentinel_path" ]]; then
    record_pass "$sentinel_id sentinel was not executed"
  else
    record_fail "$sentinel_id sentinel unexpectedly exists at $sentinel_path"
  fi
done

assert_hook_rc \
  "TC-BCOW-011 bare commit from repo A linked-worktree cwd" 0 "$REPO_A_LINKED" \
  'git commit -m "linked change"'

assert_hook_rc \
  "TC-BCOW-012 blanket amend exemption" 0 "$REPO_A" \
  'git commit --amend --no-edit'

assert_resolver \
  "TC-BCOW-013a supported helper contract" 0 "$CANON_A" commit \
  'git commit -m helper' "$REPO_A"
assert_resolver \
  "TC-BCOW-013b no matching invocation" 1 "" commit \
  'git status --short' "$REPO_A"
# shellcheck disable=SC2016
assert_resolver \
  "TC-BCOW-013c unsupported matching invocation" 2 "" commit \
  'cd "$TARGET_REPO" && git commit -m helper' "$REPO_A"
assert_resolver \
  "TC-BCOW-013d unresolvable matching invocation" 2 "" commit \
  "cd $MISSING && git commit -m helper" "$REPO_A"
assert_resolver \
  "TC-BCOW-013e deterministic ANSI-C non-git command is not a match" 1 "" commit \
  "$'echo' commit -m not-git" "$REPO_A"
assert_hook_rc \
  "TC-BCOW-013f ANSI-C non-git command remains allowed" 0 "$REPO_A" \
  "$'echo' commit -m not-git"
assert_resolver \
  "TC-BCOW-013g NUL affects only its ANSI-C segment" 1 "" commit \
  "git$'\\x00'ignored commit -m not-git" "$REPO_A"
assert_hook_rc \
  "TC-BCOW-013h NUL segment followed by non-git suffix remains allowed" 0 "$REPO_A" \
  "git$'\\x00'ignored commit -m not-git"

assert_no_commit() {
  local suffix="$1"
  local description="$2"
  local command="$3"

  assert_resolver "TC-BCOW-014${suffix} helper: $description" 1 "" commit \
    "$command" "$REPO_A"
  assert_hook_rc "TC-BCOW-014${suffix} $description" 0 "$REPO_A" "$command"
}

# shellcheck disable=SC2016
assert_no_commit "a" "looped variable git -C log" \
  'for p in x; do git -C "$p" log; done'
# shellcheck disable=SC2016
assert_no_commit "b" "bare variable git -C log with pathspec" \
  'git -C "$p" log -- somefile'
# shellcheck disable=SC2016
assert_no_commit "c" "bare variable git -C diff" \
  'git -C "$var" diff'
# shellcheck disable=SC2016
assert_no_commit "d" "looped variable git -C diff" \
  'for var in x; do git -C "$var" diff; done'
# shellcheck disable=SC2016
assert_no_commit "e" "variable git config option" \
  'git -c "$config" status'
# shellcheck disable=SC2016
assert_no_commit "f" "variable git-dir option" \
  'git --git-dir "$git_dir" log'
# shellcheck disable=SC2016
assert_no_commit "g" "variable work-tree option" \
  'git --work-tree "$work_tree" diff'
# shellcheck disable=SC2016
assert_no_commit "h" "variable namespace option" \
  'git --namespace "$namespace" status'
# shellcheck disable=SC2016
assert_no_commit "i" "variable super-prefix option" \
  'git --super-prefix "$prefix" log'
# shellcheck disable=SC2016
assert_no_commit "j" "attached variable git-dir option" \
  'git --git-dir="$git_dir" log'
# shellcheck disable=SC2016
assert_no_commit "k" "attached variable work-tree option" \
  'git --work-tree="$work_tree" diff'
# shellcheck disable=SC2016
assert_no_commit "l" "attached variable namespace option" \
  'git --namespace="$namespace" status'
# shellcheck disable=SC2016
assert_no_commit "m" "attached variable super-prefix option" \
  'git --super-prefix="$prefix" log'

# shellcheck disable=SC2016
assert_resolver \
  "TC-BCOW-014n helper: hidden operation after variable git -C" 2 "" commit \
  'git -C "$p" $(echo commit) -m hidden' "$REPO_A"
# shellcheck disable=SC2016
assert_hook_rc \
  "TC-BCOW-014n hidden operation after variable git -C" 2 "$REPO_A" \
  'git -C "$p" $(echo commit) -m hidden'

assert_no_commit "o" "literal git -C log remains allowed" \
  'git -C /tmp log'
assert_no_commit "p" "looped git log remains allowed" \
  'for p in x; do git log; done'

assert_resolver \
  "TC-BCOW-015a helper: bare commit remains supported" 0 "$CANON_A" commit \
  'git commit -m x' "$REPO_A"
assert_hook_rc \
  "TC-BCOW-015a bare commit remains blocked" 2 "$REPO_A" \
  'git commit -m x'
assert_resolver \
  "TC-BCOW-015b helper: looped commit remains unsupported" 2 "" commit \
  'for f in a b; do git commit -m x; done' "$REPO_A"
assert_hook_rc \
  "TC-BCOW-015b looped commit remains blocked" 2 "$REPO_A" \
  'for f in a b; do git commit -m x; done'
assert_resolver \
  "TC-BCOW-015c helper: chained commit remains unsupported" 2 "" commit \
  'git log; git commit -m sneaky' "$REPO_A"
assert_hook_rc \
  "TC-BCOW-015c chained commit remains blocked" 2 "$REPO_A" \
  'git log; git commit -m sneaky'
# shellcheck disable=SC2016
assert_resolver \
  "TC-BCOW-015d helper: hidden operation remains unsupported" 2 "" commit \
  'git $(echo commit) -m x' "$REPO_A"
# shellcheck disable=SC2016
assert_hook_rc \
  "TC-BCOW-015d hidden operation remains blocked" 2 "$REPO_A" \
  'git $(echo commit) -m x'
assert_resolver \
  "TC-BCOW-015e helper: linked-worktree commit context" 0 "$REPO_A_LINKED" commit \
  'git commit -m linked' "$REPO_A_LINKED"
assert_hook_rc \
  "TC-BCOW-015e linked-worktree commit remains allowed" 0 "$REPO_A_LINKED" \
  'git commit -m linked'
assert_resolver \
  "TC-BCOW-015f helper: escaped long global flag remains fail-closed" 2 "" commit \
  'git --git\-dir .git commit -m x' "$REPO_A"
assert_hook_rc \
  "TC-BCOW-015f escaped long global flag remains blocked" 2 "$REPO_A" \
  'git --git\-dir .git commit -m x'
assert_resolver \
  "TC-BCOW-015g helper: escaped short global flag remains fail-closed" 2 "" commit \
  'git -\C . commit -m x' "$REPO_A"
assert_hook_rc \
  "TC-BCOW-015g escaped short global flag remains blocked" 2 "$REPO_A" \
  'git -\C . commit -m x'
# shellcheck disable=SC2016
assert_resolver \
  "TC-BCOW-015h helper: unquoted git -C operand remains fail-closed" 2 "" commit \
  'p=". commit"; git -C $p -m x' "$REPO_A"
# shellcheck disable=SC2016
assert_hook_rc \
  "TC-BCOW-015h unquoted git -C operand remains blocked" 2 "$REPO_A" \
  'p=". commit"; git -C $p -m x'
# shellcheck disable=SC2016
assert_resolver \
  "TC-BCOW-015i helper: unquoted attached global operand remains fail-closed" 2 "" commit \
  'git_dir=".git commit"; git --git-dir=$git_dir -m x' "$REPO_A"
# shellcheck disable=SC2016
assert_hook_rc \
  "TC-BCOW-015i unquoted attached global operand remains blocked" 2 "$REPO_A" \
  'git_dir=".git commit"; git --git-dir=$git_dir -m x'
# shellcheck disable=SC2016
assert_resolver \
  "TC-BCOW-015j helper: command-substitution flag operand remains fail-closed" 2 "" commit \
  'git -C $(printf ". commit") -m x' "$REPO_A"
# shellcheck disable=SC2016
assert_hook_rc \
  "TC-BCOW-015j command-substitution flag operand remains blocked" 2 "$REPO_A" \
  'git -C $(printf ". commit") -m x'

echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

[[ "$FAIL" -eq 0 ]]
