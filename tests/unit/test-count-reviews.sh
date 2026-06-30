#!/bin/bash
# test-count-reviews.sh — Unit tests for chp_count_reviews_by_login (#324, [INV-94]).
#
# The CHP verb chp_count_reviews_by_login REPO PR LOGIN returns the integer count
# of reviews on PR (in REPO) by LOGIN, across ALL pages, or 0 on ANY failure. It
# encapsulates the `--paginate` + `awk '{s+=$1}'` GitHub-transport sum that used to
# live inline in lib-review-bots.sh::missing_bot_reviews; the `^[0-9]+$` validation
# + the `-eq 0` MISSING decision STAY caller-side ([INV-79] hard-gate). The leaf is
# fail-SAFE: any gh failure (non-zero exit incl. partial pagination, encode error)
# → 0 → the caller counts the bot MISSING → blocks the PASS, never fail-open.
#
# This file covers:
#   - the leaf golden matrix (a)-(i) + the [bot]-suffix normal case (stub the gh BINARY);
#   - the source-shape pins (real leaf GONE from lib-review-bots.sh, 3 prose lines STAY,
#     no comment self-trips the count, shim+leaf present);
#   - the baseline-delta pin (the migrated leaf wire-string absent; total
#     reconciled to whatever main's shared baseline is at rebase time, since
#     sibling #296 second-tier PRs independently shrink it; the COUNT=3 prose
#     entry unchanged).
#
# Run: bash tests/unit/test-count-reviews.sh   (CI parity: env -u PROJECT_DIR)

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_CHP="$SCRIPTS/lib-code-host.sh"
LIB_BOTS="$SCRIPTS/lib-review-bots.sh"
CHP_GITHUB="$SCRIPTS/providers/chp-github.sh"
BASELINE="$SCRIPTS/providers/cutover-baseline.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# A recording gh stub. It:
#   - appends its full argv to $STUB_ARGV (one invocation, one line);
#   - on `api …/reviews` honors the caller's `--jq` selector against a fixture
#     reviews array ($STUB_REVIEWS_JSON), emitting one `length` per page so the
#     leaf's `--paginate | awk '{s+=$1}'` accumulator is genuinely exercised;
#   - $STUB_PAGES (default 1) splits the fixture into N pages — each page emits the
#     length of its slice; the sum over pages equals the total selected count;
#   - $STUB_EXIT (default 0) is the final exit code;
#   - $STUB_PARTIAL=1 emits page-1's length THEN exits non-zero (partial-pagination
#     fail-open repro for case (h)).
# Implemented with real `jq` so the login selector (and its injection-safety) is
# exercised exactly as production would run it.
# ---------------------------------------------------------------------------
make_gh_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'STUB'
#!/bin/bash
# Record argv.
printf '%s\n' "$*" >> "$STUB_ARGV"
# Only emulate `api …/reviews`; anything else is a no-op success.
if [[ "${1:-}" != "api" ]]; then exit 0; fi
# Locate the --jq value (the selector) — the arg after the last --jq token.
jqfilter=""
url=""
prev=""
for a in "$@"; do
  case "$prev" in
    --jq) jqfilter="$a" ;;
  esac
  case "$a" in
    repos/*/reviews) url="$a" ;;
  esac
  prev="$a"
done
pages="${STUB_PAGES:-1}"
reviews="${STUB_REVIEWS_JSON:-[]}"
# Split the fixture array into $pages contiguous slices; emit each slice's
# selected length (so paginate+awk sums to the total selected count).
total=$(printf '%s' "$reviews" | jq 'length')
i=0
emitted=0
while [ "$i" -lt "$pages" ]; do
  # slice [start, end)
  start=$(( i * total / pages ))
  end=$(( (i + 1) * total / pages ))
  slice=$(printf '%s' "$reviews" | jq -c ".[${start}:${end}]")
  # Apply the caller's selector to this page; emit its length.
  printf '%s' "$slice" | jq "$jqfilter"
  emitted=$(( emitted + 1 ))
  if [[ "${STUB_PARTIAL:-0}" == "1" && "$emitted" -eq 1 ]]; then
    exit 1   # page-1 length emitted, then error (partial pagination)
  fi
  i=$(( i + 1 ))
done
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$dir/gh"
}

# run_leaf <repo> <pr> <login> — invoke the verb under a clean PATH with the stub
# gh first, the CHP seam sourced. Echoes the leaf's stdout (the count).
GH_DIR="$TMPROOT/gh-bin"; make_gh_stub "$GH_DIR"
run_leaf() {
  local repo="$1" pr="$2" login="$3"
  env -u PROJECT_DIR -u AUTONOMOUS_CONF_DIR \
      PATH="$GH_DIR:/usr/bin:/bin" \
      STUB_ARGV="$STUB_ARGV" STUB_REVIEWS_JSON="$STUB_REVIEWS_JSON" \
      STUB_PAGES="${STUB_PAGES:-1}" STUB_EXIT="${STUB_EXIT:-0}" STUB_PARTIAL="${STUB_PARTIAL:-0}" \
      bash -c "source '$LIB_CHP'; chp_count_reviews_by_login \"\$1\" \"\$2\" \"\$3\"" \
      _ "$repo" "$pr" "$login" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "=== TC-CRBL-001 (a): one review by LOGIN, single page → 1 ==="
# ---------------------------------------------------------------------------
STUB_ARGV="$TMPROOT/argv-001"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[{"user":{"login":"codex[bot]"}}]'
STUB_PAGES=1 STUB_EXIT=0 STUB_PARTIAL=0
out=$(run_leaf owner/repo 42 'codex[bot]')
if [[ "$out" == "1" ]]; then
  assert_pass "(a) single review by LOGIN → 1"
else
  assert_fail "(a) expected 1, got '$out'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-002 (b): multi-page sum + --paginate RECEIVED → 3 ==="
# ---------------------------------------------------------------------------
# Three matching reviews split across 2 pages → the awk accumulator must sum the
# per-page lengths to 3. A naive single-echo stub would pass for the wrong reason;
# we also assert the leaf passed --paginate (so dropping the flag fails the test).
STUB_ARGV="$TMPROOT/argv-002"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[{"user":{"login":"codex[bot]"}},{"user":{"login":"codex[bot]"}},{"user":{"login":"codex[bot]"}}]'
STUB_PAGES=2 STUB_EXIT=0 STUB_PARTIAL=0
out=$(run_leaf owner/repo 42 'codex[bot]')
paginate_seen=0
grep -q -- '--paginate' "$STUB_ARGV" && paginate_seen=1
if [[ "$out" == "3" && "$paginate_seen" == "1" ]]; then
  assert_pass "(b) multi-page sum → 3 AND --paginate received (awk accumulator exercised)"
else
  assert_fail "(b) expected 3 + --paginate; got count='$out' paginate_seen=$paginate_seen (argv: $(cat "$STUB_ARGV"))"
fi
STUB_PAGES=1   # reset

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-003 (c): reviews by a DIFFERENT login → 0 ==="
# ---------------------------------------------------------------------------
STUB_ARGV="$TMPROOT/argv-003"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[{"user":{"login":"some-human"}},{"user":{"login":"amazon-q-developer[bot]"}}]'
out=$(run_leaf owner/repo 42 'codex[bot]')
if [[ "$out" == "0" ]]; then
  assert_pass "(c) reviews exist but by other logins → 0"
else
  assert_fail "(c) expected 0, got '$out'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-004 (d): no reviews → 0 ==="
# ---------------------------------------------------------------------------
STUB_ARGV="$TMPROOT/argv-004"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[]'
out=$(run_leaf owner/repo 42 'codex[bot]')
if [[ "$out" == "0" ]]; then
  assert_pass "(d) no reviews at all → 0"
else
  assert_fail "(d) expected 0, got '$out'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-005 (e): gh non-zero (empty stdout) → 0 (fail-SAFE) ==="
# ---------------------------------------------------------------------------
STUB_ARGV="$TMPROOT/argv-005"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[]'
STUB_EXIT=1
out=$(run_leaf owner/repo 42 'codex[bot]')
if [[ "$out" == "0" ]]; then
  assert_pass "(e) gh exits non-zero with empty stdout → 0 (fail-safe)"
else
  assert_fail "(e) expected 0, got '$out'"
fi
STUB_EXIT=0   # reset

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-006 (f): injection-safe LOGIN → 0, no jq syntax error ==="
# ---------------------------------------------------------------------------
STUB_ARGV="$TMPROOT/argv-006"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[{"user":{"login":"codex[bot]"}}]'
inj='x" or true or "y'
err=$(env -u PROJECT_DIR -u AUTONOMOUS_CONF_DIR \
      PATH="$GH_DIR:/usr/bin:/bin" \
      STUB_ARGV="$STUB_ARGV" STUB_REVIEWS_JSON="$STUB_REVIEWS_JSON" STUB_PAGES=1 STUB_EXIT=0 STUB_PARTIAL=0 \
      bash -c "source '$LIB_CHP'; chp_count_reviews_by_login \"\$1\" \"\$2\" \"\$3\"" \
      _ owner/repo 42 "$inj" 2>&1 >/dev/null)
out=$(run_leaf owner/repo 42 "$inj")
if [[ "$out" == "0" ]]; then
  assert_pass "(f) injection login → 0 (NOT a phantom count; selector not widened)"
else
  assert_fail "(f) injection login should yield 0, got '$out'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-007 (f'): quote-bearing login → no jq syntax error ==="
# ---------------------------------------------------------------------------
if ! printf '%s' "$err" | grep -qiE 'jq: error|syntax error|compile error'; then
  assert_pass "(f') quote-bearing login produced no jq syntax/compile error"
else
  assert_fail "(f') jq error leaked for a quote-bearing login: $err"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-008 (g): source-of-truth — leaf keeps --paginate + the awk sum ==="
# ---------------------------------------------------------------------------
# Inspect ONLY the chp_github_count_reviews_by_login function body.
leaf_body=$(awk '/^chp_github_count_reviews_by_login\(\)/{f=1} f{print} f&&/^}/{exit}' "$CHP_GITHUB")
if printf '%s' "$leaf_body" | grep -q -- '--paginate' \
   && printf '%s' "$leaf_body" | grep -qE 'awk .*s\+=\$1'; then
  assert_pass "(g) leaf keeps --paginate AND the awk '{s+=\$1}' sum"
else
  assert_fail "(g) leaf missing --paginate or the awk sum:
$leaf_body"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-009 (h): gh stdout THEN non-zero (partial pagination) → 0 ==="
# ---------------------------------------------------------------------------
# The capture-check-sum closes the latent fail-open: piping gh|awk swallowed the
# exit, summing page-1's count → false PRESENT. The leaf returns 0 here.
STUB_ARGV="$TMPROOT/argv-009"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[{"user":{"login":"codex[bot]"}},{"user":{"login":"codex[bot]"}}]'
STUB_PAGES=2 STUB_PARTIAL=1
out=$(run_leaf owner/repo 42 'codex[bot]')
if [[ "$out" == "0" ]]; then
  assert_pass "(h) gh writes page-1 stdout then exits non-zero → 0 (capture-check-sum fail-safe)"
else
  assert_fail "(h) partial-pagination expected 0 (fail-safe), got '$out' — fail-OPEN regression"
fi
STUB_PAGES=1 STUB_PARTIAL=0   # reset

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-010 (i): REPO threaded from ARG, not global \$REPO ==="
# ---------------------------------------------------------------------------
# Set a DIFFERENT global $REPO; the recorded URL must use the PASSED arg.
STUB_ARGV="$TMPROOT/argv-010"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[{"user":{"login":"codex[bot]"}}]'
env -u PROJECT_DIR -u AUTONOMOUS_CONF_DIR \
    PATH="$GH_DIR:/usr/bin:/bin" \
    STUB_ARGV="$STUB_ARGV" STUB_REVIEWS_JSON="$STUB_REVIEWS_JSON" STUB_PAGES=1 STUB_EXIT=0 STUB_PARTIAL=0 \
    REPO="WRONG/global-repo" \
    bash -c "export REPO='WRONG/global-repo'; source '$LIB_CHP'; chp_count_reviews_by_login \"\$1\" \"\$2\" \"\$3\"" \
    _ RIGHT/arg-repo 77 'codex[bot]' >/dev/null 2>&1
if grep -q 'repos/RIGHT/arg-repo/pulls/77/reviews' "$STUB_ARGV" \
   && ! grep -q 'WRONG/global-repo' "$STUB_ARGV"; then
  assert_pass "(i) the leaf queries repos/<ARG>/… from its first param (ignores global \$REPO)"
else
  assert_fail "(i) URL used the wrong repo (argv: $(cat "$STUB_ARGV"))"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-011: normal [bot]-suffixed login is count-equivalent (encodes cleanly) ==="
# ---------------------------------------------------------------------------
STUB_ARGV="$TMPROOT/argv-011"; : > "$STUB_ARGV"
STUB_REVIEWS_JSON='[{"user":{"login":"github-actions[bot]"}}]'
out=$(run_leaf owner/repo 42 'github-actions[bot]')
if [[ "$out" == "1" ]]; then
  assert_pass "github-actions[bot] encodes to \"github-actions[bot]\" → count 1 (count-equivalent)"
else
  assert_fail "expected 1 for a [bot]-suffixed login, got '$out'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-030: PRIMARY source-shape — the 3 surviving gh-reviews lines are the PROSE/heredoc ones ==="
# ---------------------------------------------------------------------------
# Match the prose context (the heredoc `COUNT=\$(gh api …/reviews` line — the `\$`
# is a literal backslash-dollar because the prompt block is inside a `cat <<EOF`),
# NOT a bare grep -c that a code comment would trip. Today there are exactly 3 such
# heredoc lines (the scoped + unscoped prompt blocks at :231/:273/:284).
prose_count=$(grep -cE 'COUNT=\\\$\(gh api repos/' "$LIB_BOTS")
if [[ "$prose_count" -eq 3 ]]; then
  assert_pass "lib-review-bots.sh keeps exactly the 3 prose heredoc gh-reviews lines (COUNT=\$(gh api …)"
else
  assert_fail "expected 3 prose heredoc gh-reviews lines, found $prose_count"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-031: the real leaf (count=\$(gh api … --paginate) is GONE from lib-review-bots.sh ==="
# ---------------------------------------------------------------------------
if ! grep -qE 'count=\$\(gh api .*--paginate' "$LIB_BOTS"; then
  assert_pass "the inline count=\$(gh api … --paginate leaf is removed from lib-review-bots.sh"
else
  assert_fail "the inline raw-gh leaf is still present in lib-review-bots.sh"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-032: migrated caller + new leaf do NOT self-trip with a literal 'gh api …/reviews' comment ==="
# ---------------------------------------------------------------------------
# The cutover guard (#316 footgun) scans comment lines too if they carry a raw `gh `
# token in a non-comment position; the migrated caller/leaf must phrase comments as
# `gh` or "the reviews endpoint", NOT a literal `gh api …/reviews`. We assert the
# new caller's region in lib-review-bots.sh AND the leaf's comments carry no literal
# `gh api repos/…/reviews` substring.
caller_region=$(awk '/^missing_bot_reviews\(\)/{f=1} f{print} f&&/^}/{exit}' "$LIB_BOTS")
leaf_block=$(awk '/chp_github_count_reviews_by_login/{found=1} found{print} found&&/^}/{c++; if(c>=1) exit}' "$CHP_GITHUB")
# Comment lines only (leading whitespace + #) carrying a literal `gh api …/reviews`.
caller_bad=$(printf '%s\n' "$caller_region" | grep -E '^[[:space:]]*#' | grep -cE 'gh api repos/.*reviews' || true)
leaf_bad=$(printf '%s\n' "$leaf_block" | grep -E '^[[:space:]]*#' | grep -cE 'gh api repos/.*reviews' || true)
if [[ "$caller_bad" -eq 0 && "$leaf_bad" -eq 0 ]]; then
  assert_pass "no comment in the migrated caller / new leaf carries a literal 'gh api …/reviews' (#316 footgun avoided)"
else
  assert_fail "a comment self-trips the count: caller_bad=$caller_bad leaf_bad=$leaf_bad"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-033: new shim + leaf present in the seam files ==="
# ---------------------------------------------------------------------------
if grep -qE '^chp_count_reviews_by_login\(\)' "$LIB_CHP" \
   && grep -qE '^chp_github_count_reviews_by_login\(\)' "$CHP_GITHUB"; then
  assert_pass "chp_count_reviews_by_login shim + chp_github_count_reviews_by_login leaf present"
else
  assert_fail "missing the new shim and/or leaf in the seam files"
fi
# The shim dispatches via the bare chp_${CODE_HOST}_ prefix (identical to the caller guard).
if grep -qE 'chp_count_reviews_by_login\(\)[[:space:]]*\{[[:space:]]*chp_\$\{CODE_HOST\}_count_reviews_by_login' "$LIB_CHP"; then
  assert_pass "the shim forwards to chp_\${CODE_HOST}_count_reviews_by_login \"\$@\" (bare-expr dispatch)"
else
  assert_fail "the shim does not use the bare chp_\${CODE_HOST}_ dispatch form"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CRBL-034: baseline-delta — leaf entry removed, total reconciled to current main, COUNT=3 prose entry intact ==="
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  assert_fail "jq required for the baseline-delta pin"
else
  # The migrated leaf's wire-string (trimmed content key) MUST be absent.
  leaf_entries=$(jq '[.surviving_sites[] | select(.file=="lib-review-bots.sh" and (.content | test("count=\\$\\(gh api")))] | length' "$BASELINE")
  total=$(jq '.surviving_sites | length' "$BASELINE")
  # The 3-prose entry (count:3) must remain unchanged.
  prose_entry=$(jq '[.surviving_sites[] | select(.file=="lib-review-bots.sh" and .count==3 and (.content | test("COUNT=")))] | length' "$BASELINE")
  # Absolute total is 59 as of this rebase (multiple sibling #296 second-tier PRs
  # merged to main ahead of this one, each independently shrinking the shared
  # baseline). This PR's own contribution is the leaf_entries=0 / prose_entry=1
  # pins above; the absolute total just reconciles to whatever main's baseline is
  # at merge time. check-provider-cutover.sh's monotonicity check (Check 4) is the
  # authoritative guard that the baseline never GROWS — this pin is a point-in-time
  # sanity check, expected to need updating again if main advances before merge.
  if [[ "$leaf_entries" -eq 0 && "$total" -eq 59 && "$prose_entry" -eq 1 ]]; then
    assert_pass "baseline: leaf entry gone, total=59 (reconciled to current main), the COUNT=3 prose entry intact"
  else
    assert_fail "baseline-delta wrong: leaf_entries=$leaf_entries total=$total (want 59) prose_entry=$prose_entry (want 1)"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  count-reviews: $PASS passed, $FAIL failed"
echo "============================================================"
[[ "$FAIL" -eq 0 ]]
