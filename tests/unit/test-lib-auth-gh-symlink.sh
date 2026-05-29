#!/bin/bash
# test-lib-auth-gh-symlink.sh — Unit test for INV-32 (issue #142).
#
# Asserts that lib-auth.sh creates the `gh` symlink in BOTH auth modes
# (app and token), so the agent-facing rule
#   bash scripts/gh issue comment …
# in skills/autonomous-dev/SKILL.md Step 12 and
# skills/autonomous-dev/references/autonomous-mode.md works regardless of
# GH_AUTH_MODE.
#
# Background: prior to issue #142, the symlink was created only inside the
# app-mode branch, so token-mode operators had no `gh` file to invoke. The
# wrapper script (gh-with-token-refresh.sh) is itself mode-agnostic — it
# only reads from GH_TOKEN_FILE when set. In token mode it falls through
# to exec the real gh inheriting the host's env (which IS the intended
# identity in token mode). So lifting the symlink out of the app branch
# is safe and unifies the rule.
#
# Run: bash tests/unit/test-lib-auth-gh-symlink.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_pass() {
  echo -e "  ${GREEN}PASS${NC}: $1"
  PASS=$((PASS + 1))
}

assert_fail() {
  echo -e "  ${RED}FAIL${NC}: $1"
  FAIL=$((FAIL + 1))
}

LIB_AUTH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-auth.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/gh-with-token-refresh.sh"

# ---------------------------------------------------------------------------
echo "=== TC-AUTH-SYM-001: token-mode setup creates the gh symlink ==="
# ---------------------------------------------------------------------------
# Run setup_github_auth in a subshell with GH_AUTH_MODE=token. We don't
# stub the PEM/app-id args because the token branch ignores them.
# We sandbox _LIB_AUTH_DIR by copying the real lib + wrapper into a tmpdir
# so the test never mutates production scripts.
TMP1=$(mktemp -d)
trap 'rm -rf "$TMP1" "${TMP2:-}"' EXIT
cp "$LIB_AUTH" "$TMP1/lib-auth.sh"
cp "$WRAPPER" "$TMP1/gh-with-token-refresh.sh"
chmod +x "$TMP1/gh-with-token-refresh.sh"
# lib-config.sh is sourced by lib-auth.sh; provide a minimal stub.
cat > "$TMP1/lib-config.sh" <<'STUB'
#!/bin/bash
load_autonomous_conf() { return 0; }
STUB

# Run setup_github_auth in token mode. Suppress the "WARNING: No GH_TOKEN…"
# message — we set GH_TOKEN to bypass it. Echo the per-run GH_WRAPPER_DIR (the
# only stdout line) so we can clean it up afterward and not leak /tmp dirs.
WDIR1=$(GH_TOKEN="dummy-token-for-test" \
  bash -c "
    source '$TMP1/lib-auth.sh'
    GH_AUTH_MODE='token'
    setup_github_auth >/dev/null 2>&1
    echo \"\${GH_WRAPPER_DIR:-}\"
  ")
[[ "$WDIR1" == /tmp/agent-auth-* ]] && rm -rf "$WDIR1"

if [[ -L "$TMP1/gh" ]]; then
  target=$(readlink "$TMP1/gh")
  if [[ "$target" == *"gh-with-token-refresh.sh" ]]; then
    assert_pass "token-mode: gh symlink exists and points at gh-with-token-refresh.sh"
  else
    assert_fail "token-mode: gh symlink target is wrong: $target"
  fi
else
  assert_fail "token-mode: gh symlink NOT created in _LIB_AUTH_DIR"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AUTH-SYM-002: symlink creation is NOT inside the GH_AUTH_MODE=app branch ==="
# ---------------------------------------------------------------------------
# Source-level lockdown: a future contributor must not move the symlink
# creation back inside the `if [[ "$GH_AUTH_MODE" == "app" ]]` branch.
#
# Strategy: find the line range of the app-mode branch
# (`if [[ "$GH_AUTH_MODE" == "app" ]]; then` to its matching `else`),
# then assert the symlink line is OUTSIDE that range.

sym_line=$(grep -n 'ln -sf .*gh-with-token-refresh.sh.*"\${_LIB_AUTH_DIR}/gh"' "$LIB_AUTH" | head -1 | cut -d: -f1)
app_branch_start=$(grep -n 'if \[\[ "\$GH_AUTH_MODE" == "app" \]\]' "$LIB_AUTH" | head -1 | cut -d: -f1)

if [[ -z "$sym_line" ]]; then
  assert_fail "could not locate the gh symlink-creation line in lib-auth.sh"
elif [[ -z "$app_branch_start" ]]; then
  assert_fail "could not locate the GH_AUTH_MODE=app branch in lib-auth.sh"
else
  # Find the `else` (or `fi` if there's no else) at the same indentation
  # as the matching `if`. The if at app_branch_start is indented with two
  # spaces (function-body indent). Look for `^  else` or `^  fi` after it.
  app_branch_end=$(awk -v start="$app_branch_start" '
    NR > start && /^  else$/ { print NR; exit }
    NR > start && /^  fi$/   { print NR; exit }
  ' "$LIB_AUTH")

  if [[ -z "$app_branch_end" ]]; then
    assert_fail "could not locate end of GH_AUTH_MODE=app branch (looked for ^  else or ^  fi)"
  elif (( sym_line > app_branch_start && sym_line < app_branch_end )); then
    assert_fail "symlink creation is INSIDE GH_AUTH_MODE=app branch (lines $app_branch_start..$app_branch_end), found at line $sym_line"
  else
    assert_pass "symlink creation is OUTSIDE GH_AUTH_MODE=app branch (line $sym_line, branch ends at $app_branch_end)"
  fi
fi

# A reusable harness: run setup_github_auth (token mode) against a fresh
# sandbox copy of lib-auth.sh and emit a few facts (GH_WRAPPER_DIR, PATH head,
# and whether the per-run gh exists) on stdout for the caller to parse.
#   $1 = sandbox dir (must already hold lib-auth.sh + wrapper + lib-config stub)
# Prints (one per line): GH_WRAPPER_DIR=<dir>, PATH_HEAD=<first PATH entry>,
# WRAPPER_GH=<path or empty>.
run_setup_emit() {
  local sandbox="$1"
  GH_TOKEN="dummy-token-for-test" \
    bash -c "
      source '$sandbox/lib-auth.sh'
      GH_AUTH_MODE='token'
      setup_github_auth >/dev/null 2>&1
      echo \"GH_WRAPPER_DIR=\${GH_WRAPPER_DIR:-}\"
      echo \"PATH_HEAD=\${PATH%%:*}\"
      if [[ -L \"\${GH_WRAPPER_DIR:-}/gh\" ]]; then
        echo \"WRAPPER_GH=\${GH_WRAPPER_DIR}/gh\"
      else
        echo \"WRAPPER_GH=\"
      fi
    "
}

new_sandbox() {
  local d
  d=$(mktemp -d)
  cp "$LIB_AUTH" "$d/lib-auth.sh"
  cp "$WRAPPER" "$d/gh-with-token-refresh.sh"
  chmod +x "$d/gh-with-token-refresh.sh"
  cat > "$d/lib-config.sh" <<'STUB'
#!/bin/bash
load_autonomous_conf() { return 0; }
STUB
  echo "$d"
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AUTH-SYM-003: setup exports a per-run GH_WRAPPER_DIR under /tmp and prepends it to PATH ==="
# ---------------------------------------------------------------------------
# The wrapper's OWN bare `gh` calls resolve through PATH; issue #163 moves that
# PATH entry into a per-run /tmp dir so a concurrent run's cleanup can't delete
# the gh this run resolves.
SB3=$(new_sandbox)
mapfile -t out3 < <(run_setup_emit "$SB3")
wdir3=""; phead3=""; wgh3=""
for kv in "${out3[@]}"; do
  case "$kv" in
    GH_WRAPPER_DIR=*) wdir3="${kv#GH_WRAPPER_DIR=}" ;;
    PATH_HEAD=*)      phead3="${kv#PATH_HEAD=}" ;;
    WRAPPER_GH=*)     wgh3="${kv#WRAPPER_GH=}" ;;
  esac
done

if [[ "$wdir3" == /tmp/agent-auth-* ]]; then
  assert_pass "GH_WRAPPER_DIR is a per-run /tmp/agent-auth-* dir: $wdir3"
else
  assert_fail "GH_WRAPPER_DIR is not a per-run /tmp/agent-auth-* dir: '$wdir3'"
fi
if [[ -n "$wgh3" && "$(readlink "$wgh3" 2>/dev/null)" == *gh-with-token-refresh.sh ]]; then
  assert_pass "per-run \${GH_WRAPPER_DIR}/gh symlink exists and targets the wrapper"
else
  assert_fail "per-run \${GH_WRAPPER_DIR}/gh symlink missing or wrong target: '$wgh3'"
fi
if [[ -n "$wdir3" && "$phead3" == "$wdir3" ]]; then
  assert_pass "PATH is prepended with GH_WRAPPER_DIR (head=$phead3)"
else
  assert_fail "PATH head is not GH_WRAPPER_DIR (head='$phead3', wrapper_dir='$wdir3')"
fi
rm -rf "$SB3" "$wdir3"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AUTH-SYM-004: two concurrent setups get DISTINCT GH_WRAPPER_DIR paths ==="
# ---------------------------------------------------------------------------
SB4a=$(new_sandbox); SB4b=$(new_sandbox)
wdir4a=$(run_setup_emit "$SB4a" | sed -n 's/^GH_WRAPPER_DIR=//p')
wdir4b=$(run_setup_emit "$SB4b" | sed -n 's/^GH_WRAPPER_DIR=//p')
if [[ -n "$wdir4a" && -n "$wdir4b" && "$wdir4a" != "$wdir4b" ]]; then
  assert_pass "two runs got distinct GH_WRAPPER_DIRs ($wdir4a != $wdir4b)"
else
  assert_fail "two runs SHARE a GH_WRAPPER_DIR (a='$wdir4a' b='$wdir4b')"
fi
rm -rf "$SB4a" "$SB4b" "$wdir4a" "$wdir4b"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AUTH-SYM-005: cleanup removes the per-run wrapper dir ==="
# ---------------------------------------------------------------------------
# setup then cleanup in the SAME shell, then assert the /tmp wrapper dir and
# its gh symlink are gone.
SB5=$(new_sandbox)
res5=$(GH_TOKEN="dummy-token-for-test" bash -c "
  source '$SB5/lib-auth.sh'
  GH_AUTH_MODE='token'
  setup_github_auth >/dev/null 2>&1
  wd=\"\${GH_WRAPPER_DIR:-}\"
  cleanup_github_auth >/dev/null 2>&1
  if [[ -n \"\$wd\" && ! -e \"\$wd\" ]]; then echo DIR_GONE; else echo \"DIR_PRESENT:\$wd\"; fi
")
if [[ "$res5" == DIR_GONE ]]; then
  assert_pass "cleanup removed the per-run GH_WRAPPER_DIR"
else
  assert_fail "cleanup did NOT remove the per-run GH_WRAPPER_DIR ($res5)"
fi
rm -rf "$SB5"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AUTH-SYM-006: cleanup does NOT touch \${_LIB_AUTH_DIR}/gh (the agent-facing symlink) ==="
# ---------------------------------------------------------------------------
# Plant a sentinel scripts/gh in the sandbox, run setup+cleanup, and assert the
# sentinel still exists afterward — a per-run cleanup must never delete the
# shared, project-level artifact that `bash scripts/gh` (INV-32) depends on.
SB6=$(new_sandbox)
res6=$(GH_TOKEN="dummy-token-for-test" bash -c "
  source '$SB6/lib-auth.sh'
  GH_AUTH_MODE='token'
  setup_github_auth >/dev/null 2>&1
  # After setup, \${_LIB_AUTH_DIR}/gh (= $SB6/gh) should exist (INV-32).
  cleanup_github_auth >/dev/null 2>&1
  if [[ -L '$SB6/gh' ]]; then echo SCRIPTS_GH_PRESENT; else echo SCRIPTS_GH_GONE; fi
")
if [[ "$res6" == SCRIPTS_GH_PRESENT ]]; then
  assert_pass "cleanup left \${_LIB_AUTH_DIR}/gh intact"
else
  assert_fail "cleanup deleted \${_LIB_AUTH_DIR}/gh — concurrency footgun reintroduced ($res6)"
fi
rm -rf "$SB6"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AUTH-SYM-007: source-level lockdown — no rm -f of \${_LIB_AUTH_DIR}/gh anywhere ==="
# ---------------------------------------------------------------------------
# Regression pin: the deletion of the shared scripts/gh artifact (the #163 root
# cause) must not be reintroduced.
if grep -qE 'rm -f .*_LIB_AUTH_DIR.*/gh' "$LIB_AUTH"; then
  assert_fail "found a 'rm -f \${_LIB_AUTH_DIR}/gh' in lib-auth.sh — #163 footgun reintroduced"
else
  assert_pass "no 'rm -f \${_LIB_AUTH_DIR}/gh' in lib-auth.sh"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AUTH-SYM-008: setup still creates \${_LIB_AUTH_DIR}/gh (INV-32) and is idempotent ==="
# ---------------------------------------------------------------------------
# Run setup twice in the same shell; the second call must not error and the
# agent-facing symlink must still target the wrapper.
SB8=$(new_sandbox)
# stdout is two lines: <status> then <GH_WRAPPER_DIR> (idempotent setup reuses
# the same per-run dir across both calls, so there's just one to clean).
mapfile -t out8 < <(GH_TOKEN="dummy-token-for-test" bash -c "
  source '$SB8/lib-auth.sh'
  GH_AUTH_MODE='token'
  setup_github_auth >/dev/null 2>&1 || { echo SETUP1_FAIL; echo; exit 0; }
  setup_github_auth >/dev/null 2>&1 || { echo SETUP2_FAIL; echo; exit 0; }
  if [[ -L '$SB8/gh' && \"\$(readlink '$SB8/gh')\" == *gh-with-token-refresh.sh ]]; then
    echo OK
  else
    echo NO_SYMLINK
  fi
  echo \"\${GH_WRAPPER_DIR:-}\"
")
res8="${out8[0]:-}"
wdir8="${out8[1]:-}"
if [[ "$res8" == OK ]]; then
  assert_pass "setup creates the agent-facing \${_LIB_AUTH_DIR}/gh idempotently across two calls"
else
  assert_fail "agent-facing \${_LIB_AUTH_DIR}/gh missing/wrong after two setups ($res8)"
fi
[[ "$wdir8" == /tmp/agent-auth-* ]] && rm -rf "$wdir8"
rm -rf "$SB8"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
