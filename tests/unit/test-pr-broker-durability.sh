#!/bin/bash
# test-pr-broker-durability.sh — Unit tests for issue #519: durable PR-broker
# request handoff (D1), loud scoped-run diagnostics (D2), and the strict
# single-branch recovery fallback (D3) in drain_agent_pr_create.
#
# Test cases: docs/test-cases/pr-broker-durability.md (TC-PRBROKER-NNN)
# Run: bash tests/unit/test-pr-broker-durability.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

TMPROOT=$(mktemp -d)
trap 'pkill -f "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# Sandbox: lib-auth.sh + CHP seam + stub siblings (test-token-split-234 shape)
# ---------------------------------------------------------------------------
copy_chp_seam() {
  local d="$1"
  cp "$SCRIPTS/lib-code-host.sh" "$d/lib-code-host.sh"
  mkdir -p "$d/providers"
  cp "$SCRIPTS/providers/chp-github.sh" "$d/providers/chp-github.sh"
  cp "$SCRIPTS/providers/chp-github.caps" "$d/providers/chp-github.caps" 2>/dev/null || true
}

new_auth_sandbox() {
  local d; d=$(mktemp -d "$TMPROOT/auth-XXXXXX")
  cp "$SCRIPTS/lib-auth.sh" "$d/lib-auth.sh"
  cp "$SCRIPTS/gh-with-token-refresh.sh" "$d/gh-with-token-refresh.sh"
  chmod +x "$d/gh-with-token-refresh.sh"
  copy_chp_seam "$d"
  cat > "$d/lib-config.sh" <<'CFG'
#!/bin/bash
load_autonomous_conf() { return 0; }
CFG
  cat > "$d/gh-app-token.sh" <<'GAT'
#!/bin/bash
get_gh_app_token() { echo "SCOPED-TOKEN-abc123"; }
get_gh_app_scoped_token() { echo "SCOPED-TOKEN-abc123"; }
GAT
  echo "$d"
}

SBA=$(new_auth_sandbox)

# gh stub: pr-list via `gh api graphql` (records argv; behavior driven by env
# GH_STUB_LIST_MODE: empty|fail|one-pr), `gh pr create` records argv.
GHSB="$TMPROOT/gh-stub"; mkdir -p "$GHSB"
PR_CREATE_LOG="$GHSB/pr-create.log"
PR_LIST_LOG="$GHSB/pr-list.log"
cat > "$GHSB/gh" <<GHSTUB
#!/bin/bash
if [[ "\$1" == "api" && "\$2" == "graphql" ]]; then
  echo "LISTED \$*" >> "$PR_LIST_LOG"
  case "\${GH_STUB_LIST_MODE:-empty}" in
    fail) exit 1 ;;
    one-pr)
      printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"body":"Closes #519"}]}}}}'
      exit 0 ;;
    *)
      printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}'
      exit 0 ;;
  esac
fi
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then
  if [[ "\${GH_STUB_CREATE_MODE:-ok}" == "fail" ]]; then exit 1; fi
  echo "CREATED \$*" >> "$PR_CREATE_LOG"; exit 0
fi
exit 0
GHSTUB
chmod +x "$GHSB/gh"

# ---------------------------------------------------------------------------
# Git fixture: bare origin + work clone. Branch layout is parameterized per
# test via make_fixture <issue> <shape>[,<shape>…] where shape ∈
#   ahead        → feat/issue-<N>-a, one commit ahead of main
#   ahead-b      → feat/issue-<N>-b, one commit ahead of main (second candidate)
#   equal        → feat/issue-<N>-eq, equal to main head
#   diverged     → feat/issue-<N>-div, forked below main head + own commit
#   decoy        → feat/issue-<N>3-decoy (boundary collision: issue 51 vs 513)
# Echoes the work-clone path (cwd for the drain call).
make_fixture() {
  local issue="$1" shapes="$2"
  local fx; fx=$(mktemp -d "$TMPROOT/git-XXXXXX")
  local bare="$fx/origin.git" work="$fx/work"
  git init -q --bare "$bare"
  git init -q "$work"
  (
    cd "$work" || exit 1
    git config user.email t@example.com; git config user.name t
    git remote add origin "$bare"
    echo base1 > f.txt; git add f.txt; git commit -qm c1
    echo base2 >> f.txt; git add f.txt; git commit -qm c2
    git branch -M main
    git push -q origin main
    local IFS=','
    for shape in $shapes; do
      case "$shape" in
        ahead)
          git checkout -qb "feat/issue-${issue}-a" main
          echo a >> f.txt; git add f.txt; git commit -qm ahead
          git push -q origin "feat/issue-${issue}-a" ;;
        ahead-b)
          git checkout -qb "feat/issue-${issue}-b" main
          echo b >> f.txt; git add f.txt; git commit -qm aheadb
          git push -q origin "feat/issue-${issue}-b" ;;
        equal)
          git checkout -qb "feat/issue-${issue}-eq" main
          git push -q origin "feat/issue-${issue}-eq" ;;
        diverged)
          git checkout -qb "feat/issue-${issue}-div" main~1
          echo d > g.txt; git add g.txt; git commit -qm div
          git push -q origin "feat/issue-${issue}-div" ;;
        decoy)
          git checkout -qb "feat/issue-${issue}3-decoy" main
          echo dec >> f.txt; git add f.txt; git commit -qm decoy
          git push -q origin "feat/issue-${issue}3-decoy" ;;
      esac
      git checkout -q main
    done
  )
  echo "$work"
}

# run_drain <cwd> <issue> [title] — run drain_agent_pr_create in the sandbox
# with the gh stub; env knobs come through as-is (AGENT_PR_CREATE_FILE,
# GH_STUB_LIST_MODE, GH_STUB_CREATE_MODE, SCOPED). Captures stderr to
# $DRAIN_ERR.
DRAIN_ERR="$TMPROOT/drain-stderr.log"
run_drain() {
  local cwd="$1" issue="$2" title="${3-}"
  rm -f "$PR_CREATE_LOG" "$PR_LIST_LOG" "$DRAIN_ERR"
  (
    cd "$cwd" || exit 1
    PATH="$GHSB:$PATH" REPO="owner/repo" BASE_BRANCH="${BASE_BRANCH_OVERRIDE:-main}" \
    GH_STUB_LIST_MODE="${GH_STUB_LIST_MODE:-empty}" \
    GH_STUB_CREATE_MODE="${GH_STUB_CREATE_MODE:-ok}" \
    bash -c "
      source '$SBA/lib-auth.sh'
      AGENT_GH_TOKEN_FILE='${SCOPED-/some/scoped/token}'
      AGENT_PR_CREATE_FILE='${AGENT_PR_CREATE_FILE-}'
      drain_agent_pr_create '$issue' owner/repo ${title:+'$title'}
    " 2>"$DRAIN_ERR"
  )
}

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-001/002: provisioning helper — durable location + 0600 ==="
# ===========================================================================
# D1 pins provisioning into a lib-auth.sh function the wrapper calls, so it is
# unit-testable: provision_agent_pr_create_file <issue> sets+exports
# AGENT_PR_CREATE_FILE (RUN_DIR/agent-pr-create when RUN_DIR is usable, else
# the mktemp fallback), pre-created empty, mode 0600.
RUND=$(mktemp -d "$TMPROOT/run-XXXXXX")
out=$(bash -c "
  source '$SBA/lib-auth.sh'
  RUN_DIR='$RUND' provision_agent_pr_create_file 519
  echo \"\$AGENT_PR_CREATE_FILE\"
" 2>/dev/null)
if [[ "$out" == "$RUND/agent-pr-create" ]]; then
  assert_pass "TC-001 RUN_DIR set → AGENT_PR_CREATE_FILE=\${RUN_DIR}/agent-pr-create"
else
  assert_fail "TC-001 expected \$RUN_DIR/agent-pr-create, got '$out'"
fi
if [[ -f "$RUND/agent-pr-create" && "$(stat -c %a "$RUND/agent-pr-create" 2>/dev/null)" == "600" ]]; then
  assert_pass "TC-001 file pre-created empty with mode 0600"
else
  assert_fail "TC-001 file missing or wrong mode: $(stat -c %a "$RUND/agent-pr-create" 2>/dev/null || echo absent)"
fi

out=$(bash -c "
  source '$SBA/lib-auth.sh'
  RUN_DIR='' provision_agent_pr_create_file 519
  echo \"\$AGENT_PR_CREATE_FILE\"
" 2>/dev/null)
if [[ "$out" == /tmp/agent-pr-create-519-* && -f "$out" ]]; then
  mode=$(stat -c %a "$out" 2>/dev/null)
  if [[ "$mode" == "600" ]]; then
    assert_pass "TC-002 no RUN_DIR → mktemp fallback, mode 0600 ($out)"
  else
    assert_fail "TC-002 fallback mode expected 600, got '$mode'"
  fi
  rm -f "$out"
else
  assert_fail "TC-002 expected /tmp/agent-pr-create-519-* fallback, got '$out'"
fi

# Wrapper actually uses the helper (content pin, test-cleanup-pr-check style).
DEV_CONTENT=$(cat "$SCRIPTS/autonomous-dev.sh")
if [[ "$DEV_CONTENT" == *"provision_agent_pr_create_file"* ]] \
   && [[ "$DEV_CONTENT" != *'AGENT_PR_CREATE_FILE="${GH_WRAPPER_DIR}/agent-pr-create"'* ]]; then
  assert_pass "TC-001 wrapper provisions via helper, not GH_WRAPPER_DIR"
else
  assert_fail "TC-001 wrapper still provisions AGENT_PR_CREATE_FILE inside GH_WRAPPER_DIR"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-003/004: request survives GH_WRAPPER_DIR deletion; drain retains it ==="
# ===========================================================================
WORK=$(make_fixture 519 ahead)
RUND2=$(mktemp -d "$TMPROOT/run2-XXXXXX")
REQ="$RUND2/agent-pr-create"
FAKE_WRAP=$(mktemp -d "$TMPROOT/agent-auth-XXXXXX")
printf 'branch: feat/issue-519-a\nfix: my title\nBody.\nCloses #519\n' > "$REQ"
chmod 600 "$REQ"
rm -rf "$FAKE_WRAP"   # the mid-cleanup vanish — must not affect the request
AGENT_PR_CREATE_FILE="$REQ" run_drain "$WORK" 519
if [[ -s "$PR_CREATE_LOG" ]] && grep -qF -- '--head feat/issue-519-a' "$PR_CREATE_LOG" \
   && [[ $(grep -c CREATED "$PR_CREATE_LOG") -eq 1 ]]; then
  assert_pass "TC-003 vanished GH_WRAPPER_DIR: durable request still consumed, exactly one create"
else
  assert_fail "TC-003 create log: $(cat "$PR_CREATE_LOG" 2>/dev/null || echo empty)"
fi
if [[ -f "$REQ" ]]; then
  assert_pass "TC-004 drain does not delete the request artifact"
else
  assert_fail "TC-004 request file was deleted by the drain"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-010: unscoped run stays silent ==="
# ===========================================================================
SCOPED="" AGENT_PR_CREATE_FILE="" run_drain "$WORK" 519
if [[ ! -s "$DRAIN_ERR" && ! -s "$PR_CREATE_LOG" ]]; then
  assert_pass "TC-010 unscoped: no WARN, no create"
else
  assert_fail "TC-010 unscoped produced output: $(cat "$DRAIN_ERR" 2>/dev/null)"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-011: existing PR + missing request → silent ==="
# ===========================================================================
GH_STUB_LIST_MODE=one-pr AGENT_PR_CREATE_FILE="$TMPROOT/nonexistent-req" run_drain "$WORK" 519
if [[ ! -s "$PR_CREATE_LOG" ]] && ! grep -qi 'WARN' "$DRAIN_ERR" 2>/dev/null; then
  assert_pass "TC-011 existing PR: silent return, no create, no WARN"
else
  assert_fail "TC-011 got WARN or create: $(cat "$DRAIN_ERR" 2>/dev/null)"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-012/013/014/015: diagnostic field grammar ==="
# ===========================================================================
# Unset variable. Zero candidates fixture so recovery WARNs too but the
# missing-request WARN grammar is what we pin.
WORK_NOBRANCH=$(make_fixture 888 equal)   # no ahead candidate for issue 555
AGENT_PR_CREATE_FILE="" run_drain "$WORK_NOBRANCH" 555
if grep -qF 'path=<unset> exists=no size=unknown' "$DRAIN_ERR"; then
  assert_pass "TC-012 unset var → path=<unset> exists=no size=unknown"
else
  assert_fail "TC-012 grammar missing: $(cat "$DRAIN_ERR" 2>/dev/null)"
fi

AGENT_PR_CREATE_FILE="$TMPROOT/absent-req" run_drain "$WORK_NOBRANCH" 555
if grep -qF "path=$TMPROOT/absent-req exists=no size=unknown" "$DRAIN_ERR"; then
  assert_pass "TC-013 absent file → path=<path> exists=no size=unknown"
else
  assert_fail "TC-013 grammar missing: $(cat "$DRAIN_ERR" 2>/dev/null)"
fi

EMPTYREQ="$TMPROOT/empty-req"; : > "$EMPTYREQ"
AGENT_PR_CREATE_FILE="$EMPTYREQ" run_drain "$WORK_NOBRANCH" 555
if grep -qF "path=$EMPTYREQ exists=yes size=0" "$DRAIN_ERR"; then
  assert_pass "TC-014 empty file → path=<path> exists=yes size=0"
else
  assert_fail "TC-014 grammar missing: $(cat "$DRAIN_ERR" 2>/dev/null)"
fi

SECRETREQ="$TMPROOT/secret-req"
printf 'branch: feat/issue-519-a\nTITLE-SECRET-MARKER\nBODY-SECRET-MARKER\n' > "$SECRETREQ"
AGENT_PR_CREATE_FILE="$SECRETREQ" run_drain "$WORK" 519
if ! grep -q 'TITLE-SECRET-MARKER\|BODY-SECRET-MARKER\|SCOPED-TOKEN' "$DRAIN_ERR" 2>/dev/null; then
  assert_pass "TC-015 diagnostics never leak request content or credentials"
else
  assert_fail "TC-015 leaked content: $(cat "$DRAIN_ERR" 2>/dev/null)"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-020: unique ahead branch → one recovery create ==="
# ===========================================================================
WORK20=$(make_fixture 700 ahead)
AGENT_PR_CREATE_FILE="" run_drain "$WORK20" 700 "feat: issue seven hundred"
if [[ -s "$PR_CREATE_LOG" ]] \
   && [[ $(grep -c CREATED "$PR_CREATE_LOG") -eq 1 ]] \
   && grep -qF -- '--head feat/issue-700-a' "$PR_CREATE_LOG" \
   && grep -qF 'feat: issue seven hundred' "$PR_CREATE_LOG" \
   && grep -qF 'Closes #700' "$PR_CREATE_LOG"; then
  assert_pass "TC-020 recovery created exactly one PR with head/title/Closes"
else
  assert_fail "TC-020 create log: $(cat "$PR_CREATE_LOG" 2>/dev/null || echo empty)"
fi
# Fixed recovery note: no numeric '#' besides Closes #700.
created_line=$(grep CREATED "$PR_CREATE_LOG" 2>/dev/null || true)
stripped="${created_line//Closes #700/}"
if [[ -n "$created_line" ]] && ! grep -qE '#[0-9]' <<<"$stripped"; then
  assert_pass "TC-020 recovery note carries no other numeric # reference"
else
  assert_fail "TC-020 stray #N in body: $created_line"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-021: two candidates → no create, WARN with count ==="
# ===========================================================================
WORK21=$(make_fixture 701 ahead,ahead-b)
AGENT_PR_CREATE_FILE="" run_drain "$WORK21" 701 "t"
if [[ ! -s "$PR_CREATE_LOG" ]] && grep -q 'candidate' "$DRAIN_ERR" && grep -q '2' "$DRAIN_ERR"; then
  assert_pass "TC-021 ambiguous candidates: no create, WARN lists count"
else
  assert_fail "TC-021 log=$(cat "$PR_CREATE_LOG" 2>/dev/null) err=$(cat "$DRAIN_ERR" 2>/dev/null)"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-022: issue-number boundary (51 vs 513) ==="
# ===========================================================================
WORK22=$(make_fixture 51 decoy)   # pushes feat/issue-513-decoy only
AGENT_PR_CREATE_FILE="" run_drain "$WORK22" 51 "t"
if [[ ! -s "$PR_CREATE_LOG" ]]; then
  assert_pass "TC-022 boundary filter rejects issue-513 branch for issue 51"
else
  assert_fail "TC-022 created from decoy branch: $(cat "$PR_CREATE_LOG")"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-023/024: diverged / equal candidates rejected ==="
# ===========================================================================
WORK23=$(make_fixture 702 diverged)
AGENT_PR_CREATE_FILE="" run_drain "$WORK23" 702 "t"
if [[ ! -s "$PR_CREATE_LOG" ]]; then
  assert_pass "TC-023 diverged branch: ancestry required, no create"
else
  assert_fail "TC-023 created from diverged branch: $(cat "$PR_CREATE_LOG")"
fi

WORK24=$(make_fixture 703 equal)
AGENT_PR_CREATE_FILE="" run_drain "$WORK24" 703 "t"
if [[ ! -s "$PR_CREATE_LOG" ]]; then
  assert_pass "TC-024 equal-to-base branch: zero ahead, no create"
else
  assert_fail "TC-024 created from equal branch: $(cat "$PR_CREATE_LOG")"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-025/026: UNKNOWN pr_list — recovery aborts, normal path fail-soft ==="
# ===========================================================================
GH_STUB_LIST_MODE=fail AGENT_PR_CREATE_FILE="" run_drain "$WORK20" 700 "t"
if [[ ! -s "$PR_CREATE_LOG" ]] && grep -qi 'WARN' "$DRAIN_ERR"; then
  assert_pass "TC-025 UNKNOWN pr_list + missing request: no recovery create, WARN"
else
  assert_fail "TC-025 log=$(cat "$PR_CREATE_LOG" 2>/dev/null) err=$(cat "$DRAIN_ERR" 2>/dev/null)"
fi

VALIDREQ="$TMPROOT/valid-req-700"
printf 'branch: feat/issue-700-a\nfix: t\nCloses #700\n' > "$VALIDREQ"
GH_STUB_LIST_MODE=fail AGENT_PR_CREATE_FILE="$VALIDREQ" run_drain "$WORK20" 700
if [[ -s "$PR_CREATE_LOG" ]]; then
  assert_pass "TC-026 UNKNOWN pr_list + VALID request: normal fail-soft create preserved"
else
  assert_fail "TC-026 normal path regressed under UNKNOWN pr_list"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-027/028: malformed request / failed create → no recovery ==="
# ===========================================================================
MALFORMED="$TMPROOT/malformed-req"
printf 'branch: feat/issue-700-a\n' > "$MALFORMED"   # branch line, no title
AGENT_PR_CREATE_FILE="$MALFORMED" run_drain "$WORK20" 700 "t"
if [[ ! -s "$PR_CREATE_LOG" ]] && grep -q 'empty title' "$DRAIN_ERR"; then
  assert_pass "TC-027 malformed non-empty request: WARN, no recovery create"
else
  assert_fail "TC-027 log=$(cat "$PR_CREATE_LOG" 2>/dev/null) err=$(cat "$DRAIN_ERR" 2>/dev/null)"
fi

printf 'branch: feat/issue-700-a\nfix: t\nCloses #700\n' > "$VALIDREQ"
GH_STUB_CREATE_MODE=fail AGENT_PR_CREATE_FILE="$VALIDREQ" run_drain "$WORK20" 700 "t"
if [[ ! -s "$PR_CREATE_LOG" ]] && grep -q 'failed' "$DRAIN_ERR"; then
  assert_pass "TC-028 failed normal create: no recovery second create"
else
  assert_fail "TC-028 recovery fired after create attempt: $(cat "$PR_CREATE_LOG" 2>/dev/null)"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-029: non-main BASE_BRANCH honored ==="
# ===========================================================================
# Rebuild a fixture whose base is 'develop': candidate ahead of develop.
FX29=$(mktemp -d "$TMPROOT/git29-XXXXXX")
git init -q --bare "$FX29/origin.git"
git init -q "$FX29/work"
(
  cd "$FX29/work" || exit 1
  git config user.email t@example.com; git config user.name t
  git remote add origin "$FX29/origin.git"
  echo x > f; git add f; git commit -qm c1
  git branch -M develop
  git push -q origin develop
  git checkout -qb feat/issue-704-a
  echo y >> f; git add f; git commit -qm ahead
  git push -q origin feat/issue-704-a
)
BASE_BRANCH_OVERRIDE=develop AGENT_PR_CREATE_FILE="" run_drain "$FX29/work" 704 "t"
if [[ -s "$PR_CREATE_LOG" ]] && [[ $(grep -c CREATED "$PR_CREATE_LOG") -eq 1 ]]; then
  assert_pass "TC-029 recovery validates against configured BASE_BRANCH=develop"
else
  assert_fail "TC-029 no create with non-main base: $(cat "$DRAIN_ERR" 2>/dev/null)"
fi

# ===========================================================================
echo ""
echo "=== TC-PRBROKER-030: missing title arg → deterministic fallback, one create ==="
# ===========================================================================
AGENT_PR_CREATE_FILE="" run_drain "$WORK20" 700
if [[ -s "$PR_CREATE_LOG" ]] && [[ $(grep -c CREATED "$PR_CREATE_LOG") -eq 1 ]] \
   && grep -qF 'Closes #700' "$PR_CREATE_LOG"; then
  assert_pass "TC-030 no title arg: deterministic fallback title, exactly one create"
else
  assert_fail "TC-030 log: $(cat "$PR_CREATE_LOG" 2>/dev/null || echo empty)"
fi

# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
