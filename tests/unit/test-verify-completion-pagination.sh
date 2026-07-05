#!/bin/bash
# test-verify-completion-pagination.sh — #412 fail-closed truncation guard for
# the verify-completion.sh Stop hook.
#
# The hook's two GraphQL reads use `reviewThreads(first: 100)`. Pre-#412 they
# had no awareness of further pages, so a PR with >100 review threads could
# silently under-count unresolved threads and stop blocking (false
# completion-unblock). The fix requests `pageInfo { hasNextPage }` and FAILS
# CLOSED: hasNextPage:true ⇒ the hook cannot prove completeness ⇒ keep
# blocking with a distinct truncation message (never a fabricated count).
#
# Hermetic: `gh` and `git` are PATH-front stubs; the REAL hook runs end-to-end
# (stdin fed, exit code + stderr asserted). Fixtures satisfy the hook's
# preconditions — non-main branch, PR found, CI completed/success — so control
# flow reaches the unresolved-thread check. TC IDs: TC-VCP-001..007
# (docs/test-cases/verify-completion-pagination-guard.md).
#
# Run: env -u PROJECT_DIR bash tests/unit/test-verify-completion-pagination.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/verify-completion.sh"
FIXTURES="$SCRIPT_DIR/fixtures/verify-completion"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { PASS=$((PASS+1)); echo -e "${GREEN}PASS${NC}: $1"; }
fail() { FAIL=$((FAIL+1)); echo -e "${RED}FAIL${NC}: $1"; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
STUB_BIN="$TMPDIR_TEST/bin"
FAKE_PROJECT="$TMPDIR_TEST/project"
mkdir -p "$STUB_BIN" "$FAKE_PROJECT"

# --- git stub: the hook only calls `git branch --show-current`. The
# state-manager path resolves the project root via CLAUDE_PROJECT_DIR (set
# below), so no other git behavior is needed.
cat > "$STUB_BIN/git" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "branch" ]]; then
  echo "fix/feature-branch"
  exit 0
fi
exit 0
EOF
chmod +x "$STUB_BIN/git"

# --- gh stub: dispatch on subcommand. GraphQL responses come from the fixture
# named in _MOCK_GRAPHQL_FIXTURE; _MOCK_GRAPHQL_FAIL=1 simulates a failed read
# (the hook's `|| echo '{"data":null}'` fallback then applies).
cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
case "${1:-}" in
  pr)
    case "${2:-}" in
      view)   echo "42" ;;
      checks) echo "[]" ;;   # no e2e job → hook exits 0 after review gate
    esac
    ;;
  run)
    echo '[{"status":"completed","conclusion":"success"}]'
    ;;
  repo)
    echo "zxkane/testrepo"
    ;;
  api)
    if [[ "${_MOCK_GRAPHQL_FAIL:-0}" == "1" ]]; then
      exit 1
    fi
    cat "$_MOCK_GRAPHQL_FIXTURE"
    ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/gh"

# run_hook <fixture-file|-> [fail]
# Runs the real hook with stubbed PATH; captures rc + stderr.
HOOK_RC=0
HOOK_STDERR=""
run_hook() {
  local fixture="$1" failmode="${2:-0}"
  local errfile="$TMPDIR_TEST/stderr"
  set +e
  echo '{}' | env PATH="$STUB_BIN:$PATH" \
    CLAUDE_PROJECT_DIR="$FAKE_PROJECT" \
    _MOCK_GRAPHQL_FIXTURE="$fixture" \
    _MOCK_GRAPHQL_FAIL="$failmode" \
    bash "$HOOK" >/dev/null 2>"$errfile"
  HOOK_RC=$?
  set -e
  HOOK_STDERR="$(cat "$errfile")"
}

set -e

# ---------------------------------------------------------------------------
# TC-VCP-001: hasNextPage:true + page-1 all resolved → BLOCK with truncation
# message (the regression this issue exists for: pre-fix this exits 0).
# ---------------------------------------------------------------------------
run_hook "$FIXTURES/threads-truncated-all-resolved.json"
if [[ "$HOOK_RC" -eq 2 ]]; then
  pass "TC-VCP-001: truncated+all-resolved page blocks (rc=2)"
else
  fail "TC-VCP-001: expected rc=2, got rc=$HOOK_RC (silent false-unblock)"
fi
if echo "$HOOK_STDERR" | grep -qi "more than 100 review threads" \
   && echo "$HOOK_STDERR" | grep -qi "cannot verify"; then
  pass "TC-VCP-001b: truncation message present"
else
  fail "TC-VCP-001b: truncation message missing; stderr: $(echo "$HOOK_STDERR" | head -3)"
fi
if echo "$HOOK_STDERR" | grep -q "unresolved review thread(s)"; then
  fail "TC-VCP-001c: must not claim a numeric unresolved count it cannot know"
else
  pass "TC-VCP-001c: no fabricated numeric count in truncation message"
fi

# ---------------------------------------------------------------------------
# TC-VCP-002: hasNextPage:true + page-1 has unresolved → still the truncation
# block (sentinel wins before counting; count would be a lie anyway).
# ---------------------------------------------------------------------------
run_hook "$FIXTURES/threads-truncated-unresolved.json"
if [[ "$HOOK_RC" -eq 2 ]] && echo "$HOOK_STDERR" | grep -qi "more than 100 review threads"; then
  pass "TC-VCP-002: truncated+unresolved blocks with truncation message"
else
  fail "TC-VCP-002: expected rc=2 + truncation message, got rc=$HOOK_RC"
fi

# ---------------------------------------------------------------------------
# TC-VCP-003: hasNextPage:false, 0 unresolved (resolved + outdated only) →
# no block, exits 0 — current behavior byte-preserved.
# ---------------------------------------------------------------------------
run_hook "$FIXTURES/threads-single-page-resolved.json"
if [[ "$HOOK_RC" -eq 0 ]]; then
  pass "TC-VCP-003: single page all-resolved does not block (rc=0)"
else
  fail "TC-VCP-003: expected rc=0, got rc=$HOOK_RC; stderr: $(echo "$HOOK_STDERR" | head -3)"
fi

# ---------------------------------------------------------------------------
# TC-VCP-004: hasNextPage:false, 2 unresolved → existing numeric block message.
# ---------------------------------------------------------------------------
run_hook "$FIXTURES/threads-single-page-unresolved.json"
if [[ "$HOOK_RC" -eq 2 ]] && echo "$HOOK_STDERR" | grep -q "2 unresolved review thread(s)"; then
  pass "TC-VCP-004: single page unresolved keeps existing count message"
else
  fail "TC-VCP-004: expected rc=2 + '2 unresolved review thread(s)', got rc=$HOOK_RC"
fi

# ---------------------------------------------------------------------------
# TC-VCP-005: GraphQL read fails → today's fail-open (rc=0). Changing that
# posture is explicitly out of scope for #412.
# ---------------------------------------------------------------------------
run_hook "-" 1
if [[ "$HOOK_RC" -eq 0 ]]; then
  pass "TC-VCP-005: GraphQL failure keeps fail-open rc=0 (unchanged posture)"
else
  fail "TC-VCP-005: expected rc=0 on query failure, got rc=$HOOK_RC"
fi

# ---------------------------------------------------------------------------
# TC-VCP-006: response without pageInfo (old shape) → treated as single page.
# ---------------------------------------------------------------------------
run_hook "$FIXTURES/threads-no-pageinfo-unresolved.json"
if [[ "$HOOK_RC" -eq 2 ]] && echo "$HOOK_STDERR" | grep -q "2 unresolved review thread(s)"; then
  pass "TC-VCP-006a: pageInfo-less unresolved response → numeric block"
else
  fail "TC-VCP-006a: expected rc=2 + numeric message, got rc=$HOOK_RC"
fi
run_hook "$FIXTURES/threads-no-pageinfo-resolved.json"
if [[ "$HOOK_RC" -eq 0 ]]; then
  pass "TC-VCP-006b: pageInfo-less resolved response → no block"
else
  fail "TC-VCP-006b: expected rc=0, got rc=$HOOK_RC"
fi

# ---------------------------------------------------------------------------
# TC-VCP-007: source-shape — BOTH GraphQL queries in the hook carry
# pageInfo { hasNextPage } (R1 covers the details query too).
# ---------------------------------------------------------------------------
query_count=$(grep -c "reviewThreads(first: 100)" "$HOOK" || true)
pageinfo_count=$(grep -c "pageInfo { hasNextPage }" "$HOOK" || true)
if [[ "$query_count" -ge 2 && "$pageinfo_count" -eq "$query_count" ]]; then
  pass "TC-VCP-007: all $query_count reviewThreads queries request pageInfo { hasNextPage }"
else
  fail "TC-VCP-007: $pageinfo_count/$query_count queries carry pageInfo { hasNextPage }"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
