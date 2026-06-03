#!/bin/bash
# test-autonomous-dev-pushed-no-pr-resume.sh — verify autonomous-dev.sh's
# cheap-resume fast path (issue #178, INV-45).
#
# When a prior dev session pushed its head branch to origin (with commits
# ahead of base) but was interrupted before `gh pr create` completed, the
# wrapper must detect that state and steer the agent STRAIGHT to the
# open-PR step instead of re-running the full design/test/implement work.
#
# Two layers under test:
#   1. needs_open_pr_only() — the detection helper. Extracted from the
#      wrapper via awk and exercised with stubbed `git` and `gh`.
#   2. Prompt wiring — the `## Open-PR-only fast path` block is conditionally
#      injected into the resume / resume-fallback / new prompts. Pinned by
#      source-of-truth greps (same approach as test-autonomous-dev-rebase-marker.sh).
#
# Run: bash tests/unit/test-autonomous-dev-pushed-no-pr-resume.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_rc() {
  local label="$1" rc="$2" expected="$3"
  if [ "$rc" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $label (rc=$rc, expected $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (should NOT match: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Extract needs_open_pr_only() from autonomous-dev.sh. Function spans from
# `^needs_open_pr_only() {` to the next standalone `^}` at column 0.
HELPER_FN=$(awk '/^needs_open_pr_only\(\) \{/,/^\}/' "$WRAPPER")
if [[ -z "$HELPER_FN" ]]; then
  echo -e "${RED}FAIL${NC}: could not extract needs_open_pr_only() from $WRAPPER"
  exit 1
fi

# --- Stub harness -----------------------------------------------------------
# The helper queries origin via `git ls-remote` (branch discovery + ahead
# check) and `gh pr list` (PR presence). We stub both on PATH and drive each
# scenario via env that the stubs read.
#
# Stub semantics:
#   GH_PR_COUNT       → what `gh pr list ... | length` prints (PR presence).
#   GIT_LSREMOTE_OUT  → lines `gh ls-remote` prints for the branch glob
#                       (`<sha>\trefs/heads/<branch>`). Empty = no branch.
#   GIT_LSREMOTE_FAIL → if "1", `git ls-remote` exits non-zero (transient err).
#   GIT_BASE_SHA      → SHA `git ls-remote origin <base>` reports.
#   GIT_AHEAD_COUNT   → what `git rev-list --count` reports (commits ahead).
STUB_DIR="$TMPROOT/bin"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
# Only `gh pr list ...` is exercised by the helper.
case "$*" in
  *"pr list"*) echo "${GH_PR_COUNT:-0}" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/gh"

cat > "$STUB_DIR/git" <<'EOF'
#!/bin/bash
if [[ "$1" == "ls-remote" ]]; then
  [[ "${GIT_LSREMOTE_FAIL:-0}" == "1" ]] && exit 2
  # `git ls-remote origin <base>` → single base SHA line.
  # `git ls-remote origin 'refs/heads/*issue-N*'` → candidate branch lines.
  for a in "$@"; do
    case "$a" in
      refs/heads/main|refs/heads/master|main|master)
        echo -e "${GIT_BASE_SHA:-baseaaaa}\trefs/heads/main"; exit 0 ;;
    esac
  done
  printf '%b' "${GIT_LSREMOTE_OUT:-}"
  exit 0
elif [[ "$1" == "rev-list" ]]; then
  echo "${GIT_AHEAD_COUNT:-0}"
  exit 0
fi
exit 0
EOF
chmod +x "$STUB_DIR/git"

run_helper() {
  local issue="$1"; shift
  # Remaining args are KEY=VALUE scenario env. Pass them through `env` so
  # they land in the child's environment (not as a command prefix).
  env \
    PATH="$STUB_DIR:$PATH" \
    REPO="acme/widget" \
    DEFAULT_BRANCH="main" \
    "$@" \
    bash -c "
      set +e
      log() { :; }
      $HELPER_FN
      needs_open_pr_only '$issue'
    "
}

# ---------------------------------------------------------------------------
echo "=== TC-CR-001: feat/issue-178-foo pushed, ahead, no PR → fast path ==="
# ---------------------------------------------------------------------------
run_helper 178 \
  GH_PR_COUNT=0 \
  GIT_LSREMOTE_OUT='deadbeef\trefs/heads/feat/issue-178-foo\n' \
  GIT_BASE_SHA=baseaaaa \
  GIT_AHEAD_COUNT=3
assert_rc "feat/issue-178-foo with commits ahead, no PR → 0 (fast path)" "$?" "0"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CR-002: fix/issue-178 pushed, ahead, no PR → fast path ==="
# ---------------------------------------------------------------------------
run_helper 178 \
  GH_PR_COUNT=0 \
  GIT_LSREMOTE_OUT='cafebabe\trefs/heads/fix/issue-178\n' \
  GIT_BASE_SHA=baseaaaa \
  GIT_AHEAD_COUNT=1
assert_rc "fix/issue-178 with commits ahead, no PR → 0 (fast path)" "$?" "0"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CR-003: non-default suffix branch detected via glob → fast path ==="
# ---------------------------------------------------------------------------
run_helper 178 \
  GH_PR_COUNT=0 \
  GIT_LSREMOTE_OUT='abc12345\trefs/heads/feat/issue-178-some-long-descriptive-name\n' \
  GIT_BASE_SHA=baseaaaa \
  GIT_AHEAD_COUNT=2
assert_rc "agent-chosen suffix branch detected via glob → 0" "$?" "0"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CR-004: no pushed branch (genuine crash), no PR → normal re-dev ==="
# ---------------------------------------------------------------------------
run_helper 178 \
  GH_PR_COUNT=0 \
  GIT_LSREMOTE_OUT='' \
  GIT_BASE_SHA=baseaaaa \
  GIT_AHEAD_COUNT=0
assert_rc "no pushed branch → 1 (normal full re-dev)" "$?" "1"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CR-005: pushed branch but ZERO commits ahead → normal re-dev ==="
# ---------------------------------------------------------------------------
run_helper 178 \
  GH_PR_COUNT=0 \
  GIT_LSREMOTE_OUT='baseaaaa\trefs/heads/feat/issue-178-empty\n' \
  GIT_BASE_SHA=baseaaaa \
  GIT_AHEAD_COUNT=0
assert_rc "zero-ahead branch (== base SHA) → 1 (not finished work)" "$?" "1"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CR-006: open PR already exists → normal handoff path (helper returns 1) ==="
# ---------------------------------------------------------------------------
run_helper 178 \
  GH_PR_COUNT=1 \
  GIT_LSREMOTE_OUT='deadbeef\trefs/heads/feat/issue-178-foo\n' \
  GIT_BASE_SHA=baseaaaa \
  GIT_AHEAD_COUNT=3
assert_rc "open PR exists → 1 (PR-exists handoff owns this, no fast path)" "$?" "1"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CR-007: git ls-remote transient failure → fail-closed ==="
# ---------------------------------------------------------------------------
run_helper 178 \
  GH_PR_COUNT=0 \
  GIT_LSREMOTE_FAIL=1
assert_rc "ls-remote failure → 1 (fail-closed, no false fast path)" "$?" "1"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CR-008: ahead branch via different SHA when ahead-count unavailable ==="
# ---------------------------------------------------------------------------
# Remote-only objects: rev-list can't count (returns 0/empty), but the
# branch head SHA differs from base SHA → treated as ahead.
run_helper 178 \
  GH_PR_COUNT=0 \
  GIT_LSREMOTE_OUT='ffff0000\trefs/heads/fix/issue-178\n' \
  GIT_BASE_SHA=baseaaaa \
  GIT_AHEAD_COUNT=0
assert_rc "different head SHA vs base (rev-list 0) → 0 (ahead fallback)" "$?" "0"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CR-015: a longer-number branch (issue-1789) must NOT satisfy issue 178 ==="
# ---------------------------------------------------------------------------
# The `*issue-178*` glob also matches `feat/issue-1789-x`. The per-ref regex
# guard (issue-<N> followed by non-digit or end) must reject it so issue 178
# isn't falsely treated as "pushed" by an unrelated issue 1789 branch.
run_helper 178 \
  GH_PR_COUNT=0 \
  GIT_LSREMOTE_OUT='99990000\trefs/heads/feat/issue-1789-unrelated\n' \
  GIT_BASE_SHA=baseaaaa \
  GIT_AHEAD_COUNT=5
assert_rc "issue-1789 branch does NOT satisfy issue 178 → 1" "$?" "1"

echo ""
echo "=== Source-of-truth grep assertions (prompt wiring) ==="
# ---------------------------------------------------------------------------

# TC-CR-009 / TC-CR-012: helper exists and globs both feat/ and fix/ branches.
assert_grep "TC-CR-012: detection globs the agent-chosen issue branch (ls-remote glob)" \
  "ls-remote .*issue-\\\$\{ISSUE_NUMBER\}|ls-remote .*refs/heads/\*issue" "$WRAPPER"
assert_grep "TC-CR-009: needs_open_pr_only helper is defined" \
  '^needs_open_pr_only\(\) \{' "$WRAPPER"
assert_grep "TC-CR-009: helper is called to gate the fast path" \
  'needs_open_pr_only ' "$WRAPPER"

# TC-CR-011 prep: extract ONLY the fast-path heredoc body (between
# `cat <<FASTPATH` and the closing `FASTPATH`), so neither the helper
# comments (which mention crash keywords by name while documenting the
# [INV-06] contract) nor the cleanup trap leak into the keyword assertions.
FASTPATH_BLOCK=$(awk '/cat <<FASTPATH$/{p=1;next} /^FASTPATH$/{p=0} p' "$WRAPPER")
echo "$FASTPATH_BLOCK" > "$TMPROOT/fastpath-block.txt"

# TC-CR-010: the injected block tells the agent to skip the expensive steps
# and go straight to the open-PR step. Assert against the extracted block.
assert_grep "TC-CR-010: fast-path block names the open-PR-only fast path" \
  'Open-PR-only fast path' "$TMPROOT/fastpath-block.txt"
assert_grep "TC-CR-010: fast-path block instructs skipping design/test/implement" \
  '[Ss][Kk][Ii][Pp].*(design|test|implement)' "$TMPROOT/fastpath-block.txt"
assert_grep "TC-CR-010: fast-path block points at gh pr create / open-PR step" \
  'gh pr create' "$TMPROOT/fastpath-block.txt"
assert_no_grep "TC-CR-011: fast-path block has no 'Task appears to have crashed'" \
  'Task appears to have crashed' "$TMPROOT/fastpath-block.txt"
assert_no_grep "TC-CR-011: fast-path block has no 'process not found'" \
  'process not found' "$TMPROOT/fastpath-block.txt"

# TC-CR-014: the fast-path block is wired into the resume-fallback (new
# session) and MODE=new builders too — i.e. the block helper output is
# referenced in more than one prompt. We assert the block marker appears
# at least twice across the three prompt builders.
block_refs=$(grep -cE 'OPEN_PR_FAST_PATH|Open-PR-only fast path' "$WRAPPER")
if [ "$block_refs" -ge 2 ]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CR-014: fast-path block referenced in ≥2 prompt builders (count=$block_refs)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CR-014: fast-path block referenced <2 times (count=$block_refs)"
  FAIL=$((FAIL + 1))
fi

# TC-CR-013: wrapper still passes bash -n.
echo ""
echo "=== TC-CR-013: wrapper passes bash -n ==="
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper has syntax errors"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="
[ "$FAIL" -eq 0 ]
