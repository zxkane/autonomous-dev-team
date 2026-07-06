#!/bin/bash
# test-issue-filter.sh — Unit tests for lib-issue-filter.sh (#436,
# docs/designs/issue-filter.md, docs/test-cases/issue-filter.md).
#
# Covers issue_filter_compile (the recursive-descent parser + tokenizer),
# issue_filter_apply (empty/non-empty paths, assignees-stripping, lazy
# compile, fail-closed on compile error), issue_filter_validate (dry-run
# eval, reserved-label gate, assignee capability gate), issue_filter_fields,
# and injection safety (AC-B3).
#
# Run: bash tests/unit/test-issue-filter.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$SCRIPTS/lib-issue-filter.sh"
FAKE_PROVIDER="$SCRIPT_DIR/fixtures/provider-degraded"

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
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_ok() {
  local desc="$1"; shift
  if "$@" >/tmp/ift-out.$$ 2>/tmp/ift-err.$$; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (rc=$?, stderr: $(cat /tmp/ift-err.$$))"
    FAIL=$((FAIL + 1))
  fi
  rm -f /tmp/ift-out.$$ /tmp/ift-err.$$
}

assert_fail_contains() {
  local desc="$1" needle="$2"; shift 2
  local out err rc
  err=$("$@" 2>&1 1>/dev/null)
  rc=$?
  if [[ "$rc" -ne 0 && "$err" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      rc=$rc, needle='$needle'"
    echo "      stderr='${err:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should not contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-issue-filter.sh
source "$LIB"
set +e

# ---------------------------------------------------------------------------
echo "=== TC-IFILT-001..016: compiler — atom forms, precedence, parens, quoting ==="
# ---------------------------------------------------------------------------

issue_filter_compile "label:foo"
assert_eq "TC-IFILT-001 label:foo compiles" "0" "$?"
assert_contains "TC-IFILT-001 jq references .labels" ".labels" "$ISSUE_FILTER_JQ"

issue_filter_compile "assignee:alice"
assert_eq "TC-IFILT-002 assignee:alice compiles" "0" "$?"
assert_contains "TC-IFILT-002 jq references .assignees" ".assignees" "$ISSUE_FILTER_JQ"

issue_filter_compile "assignee:none"
assert_eq "TC-IFILT-003 assignee:none compiles" "0" "$?"
assert_contains "TC-IFILT-003 compiles to emptiness check" "length == 0" "$ISSUE_FILTER_JQ"
assert_eq "TC-IFILT-003 no --arg needed for reserved none" "0" "${#ISSUE_FILTER_ARGS[@]}"

issue_filter_compile 'assignee:"none"'
assert_eq 'TC-IFILT-004 assignee:"none" (quoted) compiles' "0" "$?"
assert_contains "TC-IFILT-004 compiles to membership atom, NOT emptiness" "index(\$a1)" "$ISSUE_FILTER_JQ"
assert_not_contains "TC-IFILT-004 does NOT compile to emptiness check" "length == 0" "$ISSUE_FILTER_JQ"

issue_filter_compile 'label:"name with spaces"'
assert_eq "TC-IFILT-005 quoted value with spaces compiles" "0" "$?"
assert_eq "TC-IFILT-005 arg value preserves the space" "--arg a1 name with spaces" "${ISSUE_FILTER_ARGS[*]}"

issue_filter_compile "label:a and label:b"
assert_eq "TC-IFILT-006 label:a and label:b compiles" "0" "$?"
out=$(jq -n --arg a1 a --arg a2 b '{labels:["a","b"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-006 both-present matches" "true" "$out"
out=$(jq -n --arg a1 a --arg a2 b '{labels:["a"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-006 only-one-present does not match" "false" "$out"

issue_filter_compile "label:a or label:b"
assert_eq "TC-IFILT-007 label:a or label:b compiles" "0" "$?"
out=$(jq -n --arg a1 a --arg a2 b '{labels:["b"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-007 second-only matches (or)" "true" "$out"

issue_filter_compile "not label:a"
assert_eq "TC-IFILT-008 not label:a compiles" "0" "$?"
out=$(jq -n --arg a1 a '{labels:["a"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-008 present->false" "false" "$out"
out=$(jq -n --arg a1 a '{labels:["z"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-008 absent->true" "true" "$out"

# TC-IFILT-009: `or` lower precedence than `and` — "a or b and c" == "a or (b and c)"
issue_filter_compile "label:a or label:b and label:c"
assert_eq "TC-IFILT-009 precedence compiles" "0" "$?"
out=$(jq -n --arg a1 a --arg a2 b --arg a3 c '{labels:["b"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-009 only b present (not a, not c) -> false (b alone insufficient under and)" "false" "$out"
out=$(jq -n --arg a1 a --arg a2 b --arg a3 c '{labels:["b","c"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-009 b and c present -> true" "true" "$out"
out=$(jq -n --arg a1 a --arg a2 b --arg a3 c '{labels:["a"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-009 a alone -> true (or short-circuits)" "true" "$out"

# TC-IFILT-010: `not` higher precedence than `and` — "not a and b" == "(not a) and b"
issue_filter_compile "not label:a and label:b"
assert_eq "TC-IFILT-010 precedence compiles" "0" "$?"
out=$(jq -n --arg a1 a --arg a2 b '{labels:["b"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-010 no a, has b -> true" "true" "$out"
out=$(jq -n --arg a1 a --arg a2 b '{labels:["a","b"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-010 has a, has b -> false (not-a fails)" "false" "$out"

issue_filter_compile "(label:a or label:b) and not label:c"
assert_eq "TC-IFILT-011 parens group correctly" "0" "$?"
out=$(jq -n --arg a1 a --arg a2 b --arg a3 c '{labels:["a"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-011 a present, no c -> true" "true" "$out"
out=$(jq -n --arg a1 a --arg a2 b --arg a3 c '{labels:["a","c"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-011 a present, c present -> false" "false" "$out"

issue_filter_compile "(label:a or label:b)and label:c"
assert_eq "TC-IFILT-012 adjacent-paren tokenization compiles" "0" "$?"
out=$(jq -n --arg a1 a --arg a2 b --arg a3 c '{labels:["b","c"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-012 b and c -> true" "true" "$out"

issue_filter_compile "((label:a))"
assert_eq "TC-IFILT-013 nested redundant parens compile" "0" "$?"

issue_filter_compile "   "
assert_eq "TC-IFILT-014 whitespace-only treated as unset (rc 0)" "0" "$?"
assert_eq "TC-IFILT-014 whitespace-only -> empty ISSUE_FILTER_JQ" "" "$ISSUE_FILTER_JQ"

issue_filter_compile "assignee:bob"
out=$(jq -n --arg a1 bob '{assignees:["alice","bob"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-015 multi-assignee membership matches" "true" "$out"

issue_filter_compile 'label:a and (label:b or label:c) and not label:wip and (assignee:alice or assignee:none)'
assert_eq "TC-IFILT-016 full design-doc example compiles" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-020..030: compiler error paths ==="
# ---------------------------------------------------------------------------

assert_fail_contains "TC-IFILT-020 unknown atom key" "bogus:foo" issue_filter_compile "bogus:foo"
assert_fail_contains "TC-IFILT-021 unbalanced (missing close)" "" issue_filter_compile "(label:a"
assert_fail_contains "TC-IFILT-022 unbalanced (stray close)" ")" issue_filter_compile "label:a)"
assert_fail_contains "TC-IFILT-023 dangling and (trailing)" "and" issue_filter_compile "label:a and"
assert_fail_contains "TC-IFILT-024 bare leading operator" "and" issue_filter_compile "and label:a"
assert_fail_contains "TC-IFILT-025 empty sub-expression" "()" issue_filter_compile "()"
assert_fail_contains "TC-IFILT-026 empty atom value unquoted" "label:" issue_filter_compile "label:"
assert_fail_contains "TC-IFILT-027 empty atom value quoted" 'label:""' issue_filter_compile 'label:""'
assert_fail_contains "TC-IFILT-028 trailing tokens" "label:b" issue_filter_compile "label:a label:b"
assert_fail_contains "TC-IFILT-029 unterminated quote" "unterminated" issue_filter_compile 'label:"unterminated'
assert_fail_contains "TC-IFILT-030 bare token" "label" issue_filter_compile "label"
assert_fail_contains "TC-IFILT-031 trailing chars after quoted value" 'label:"team"a' issue_filter_compile 'label:"team"a'
assert_fail_contains "TC-IFILT-032 trailing chars after quoted assignee value" 'assignee:"bob"x' issue_filter_compile 'assignee:"bob"x'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-040..048: reserved-label rejection (issue_filter_validate) ==="
# ---------------------------------------------------------------------------

itp_caps() { [[ "$1" == "assignees" ]] && echo 1 || echo 0; }

for reserved in in-progress reviewing pending-review pending-dev stalled approved autonomous; do
  assert_fail_contains "TC-IFILT-04x reserved label '$reserved' rejected" "$reserved" issue_filter_validate "label:${reserved}"
done

assert_fail_contains "TC-IFILT-047 reserved label buried in larger expr" "in-progress" \
  issue_filter_validate "label:in-progress and label:team-a"

assert_ok "TC-IFILT-048 non-reserved label passes this gate" issue_filter_validate "label:team-a"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-050..052: assignee capability gate ==="
# ---------------------------------------------------------------------------

itp_caps() { [[ "$1" == "assignees" ]] && echo 1; }
assert_ok "TC-IFILT-050 assignee atom + caps=1 passes" issue_filter_validate "assignee:alice"

itp_caps() { [[ "$1" == "assignees" ]] && echo 0; }
assert_fail_contains "TC-IFILT-051 assignee atom + caps=0 rejected" "assignees" issue_filter_validate "assignee:alice"

assert_ok "TC-IFILT-052 label-only filter skips the gate even with caps=0" issue_filter_validate "label:team-a"

itp_caps() { [[ "$1" == "assignees" ]] && echo 1 || echo 0; }

assert_ok "TC-IFILT: unset filter always passes validate" issue_filter_validate ""
assert_ok "TC-IFILT: whitespace-only filter always passes validate" issue_filter_validate "   "

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-060..063: injection safety (AC-B3) ==="
# ---------------------------------------------------------------------------

issue_filter_compile 'label:") or true"'
assert_eq "TC-IFILT-060 metachar label value compiles" "0" "$?"
assert_not_contains "TC-IFILT-063 jq program text carries no atom value" ") or true" "$ISSUE_FILTER_JQ"
out=$(jq -n --arg a1 ') or true' '{labels:[") or true"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-060 matches ONLY the exact literal" "true" "$out"
out=$(jq -n --arg a1 ') or true' '{labels:["something else"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-060 does not match an unrelated label" "false" "$out"

issue_filter_compile 'label:"$(whoami)"'
assert_eq 'TC-IFILT-061 $(...) label value compiles' "0" "$?"
out=$(jq -n --arg a1 '$(whoami)' '{labels:["$(whoami)"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-061 matches only the literal string, no evaluation" "true" "$out"

issue_filter_compile 'label:"`id`"'
assert_eq "TC-IFILT-062 backtick label value compiles" "0" "$?"
out=$(jq -n --arg a1 '`id`' '{labels:["`id`"]} | '"$ISSUE_FILTER_JQ" 2>&1)
assert_eq "TC-IFILT-062 matches only the literal backtick string" "true" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-070..076: issue_filter_apply ==="
# ---------------------------------------------------------------------------

unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
out=$(echo '[{"number":1,"labels":["a"],"assignees":["bob"]}]' | issue_filter_apply)
assert_eq "TC-IFILT-070 empty filter strips assignees" "$(jq -c '[{"number":1,"labels":["a"]}]')" "$(jq -c "$out")"

out=$(echo '[{"number":1,"labels":["a"]}]' | issue_filter_apply)
assert_eq "TC-IFILT-071 empty filter, no assignees key -> unchanged" "$(jq -c '[{"number":1,"labels":["a"]}]')" "$(jq -c "$out")"

unset ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
ISSUE_FILTER="label:a"
# Any `$(...)` form runs issue_filter_apply in a subshell, so the lazy-compile
# side effect on ISSUE_FILTER_JQ is never visible to the parent shell by
# construction. Redirect to a tmpfile instead, calling issue_filter_apply
# directly in THIS shell.
issue_filter_apply < <(echo '[{"number":1,"labels":["a"],"assignees":[]}]') > /tmp/ift-072-out.$$
assert_eq "TC-IFILT-072 lazy-compiles on first use" "1" "$(jq 'length' /tmp/ift-072-out.$$)"
assert_eq "TC-IFILT-072 side effect: ISSUE_FILTER_JQ now set" "0" "$([[ -n "$ISSUE_FILTER_JQ" ]]; echo $?)"
rm -f /tmp/ift-072-out.$$

out2=$(echo '[{"number":2,"labels":["a"],"assignees":[]}]' | issue_filter_apply)
assert_eq "TC-IFILT-073 second call reuses compiled globals (same result shape)" "1" "$(jq 'length' <<<"$out2")"

unset ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
ISSUE_FILTER="bogus:x"
echo '[]' | issue_filter_apply >/dev/null 2>/tmp/ift-apply-err.$$
assert_eq "TC-IFILT-074 malformed filter -> issue_filter_apply itself fails closed" "1" "$?"
rm -f /tmp/ift-apply-err.$$

unset ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
ISSUE_FILTER="label:a"
out=$(echo '[{"number":1,"labels":["a"],"assignees":["x"]},{"number":2,"labels":["b"],"assignees":["y"]}]' | issue_filter_apply)
assert_not_contains "TC-IFILT-075 matched rows never carry assignees" "assignees" "$(jq -c "$out")"
assert_eq "TC-IFILT-075 filters to the matching row only" "1" "$(jq 'length' <<<"$out")"

out=$(echo '[{"number":1,"labels":["z"],"assignees":[]}]' | issue_filter_apply)
assert_eq "TC-IFILT-076 zero matches -> []" "0" "$(jq 'length' <<<"$out")"

unset ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
ISSUE_FILTER="   "
out=$(echo '[{"number":1,"labels":["z"],"assignees":["x"]}]' | issue_filter_apply)
assert_eq "TC-IFILT-077 whitespace-only filter: unset-identity, no select" "1" "$(jq 'length' <<<"$out")"
assert_not_contains "TC-IFILT-077 whitespace-only filter: still strips assignees" "assignees" "$(jq -c "$out")"

unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

# ---------------------------------------------------------------------------
echo ""
echo "=== issue_filter_fields ==="
# ---------------------------------------------------------------------------

unset ISSUE_FILTER
assert_eq "empty filter: fields unchanged" "number,labels" "$(issue_filter_fields "number,labels")"
ISSUE_FILTER="label:x"
assert_eq "non-empty filter: fields gain ,assignees" "number,labels,assignees" "$(issue_filter_fields "number,labels")"
assert_eq "non-empty filter, empty base: assignees alone" "assignees" "$(issue_filter_fields "")"
unset ISSUE_FILTER

ISSUE_FILTER="   "
assert_eq "whitespace-only filter: fields unchanged (treated as unset)" "number,labels" "$(issue_filter_fields "number,labels")"
unset ISSUE_FILTER

# ---------------------------------------------------------------------------
echo ""
echo "=== Capability gate via the REAL degraded fake provider (assignees=0) ==="
# ---------------------------------------------------------------------------

if [[ -d "$FAKE_PROVIDER" ]]; then
  fake_out=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
    bash -c '
      source "'"$SCRIPTS"'/lib-issue-provider.sh"
      source "'"$LIB"'"
      issue_filter_validate "assignee:alice"
      echo "RC=$?"
    ' 2>&1
  )
  assert_contains "degraded provider (assignees=0): assignee filter rejected" "RC=1" "$fake_out"
  assert_contains "degraded provider (assignees=0): error names capability" "assignees" "$fake_out"

  fake_out2=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
    bash -c '
      source "'"$SCRIPTS"'/lib-issue-provider.sh"
      source "'"$LIB"'"
      issue_filter_validate "label:team-a"
      echo "RC=$?"
    ' 2>&1
  )
  assert_contains "degraded provider (assignees=0): label-only filter still passes" "RC=0" "$fake_out2"
else
  echo -e "  ${RED}FAIL${NC}: degraded fake provider fixture missing at $FAKE_PROVIDER"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
