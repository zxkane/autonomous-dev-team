#!/bin/bash
# test-provider-cutover.sh — issue #286, [INV-91] cutover-guard unit tests
# (TC-CUTOVER-NNN).
#
# Drives check-provider-cutover.sh against SCRATCH copies via the --scripts-dir
# / --baseline path-override flags (mirrors test-spec-drift.sh's scratch-copy
# drift-injection pattern). The committed repo files are never modified. Runs on
# bare ubuntu-latest (jq + coreutils), no credentials.
#
# Run: bash tests/unit/test-provider-cutover.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
CHECK="$SCRIPTS/check-provider-cutover.sh"
BASELINE="$SCRIPTS/providers/cutover-baseline.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fresh scratch scripts dir (real *.sh + providers/) per mutating test, so
# injections never touch the committed tree.
fresh_scratch() {
  local d="$WORK/scratch.$1"
  rm -rf "$d"; mkdir -p "$d"
  cp "$SCRIPTS"/*.sh "$d/" 2>/dev/null
  [ -d "$SCRIPTS/providers" ] && cp -r "$SCRIPTS/providers" "$d/providers"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-001: clean tree (baseline == HEAD survivors) PASSES ==="
# ---------------------------------------------------------------------------
if bash "$CHECK" >/dev/null 2>&1; then
  ok "check-provider-cutover.sh exits 0 against the committed repo (load-bearing: the migration surface is unchanged)"
else
  bad "check-provider-cutover.sh FAILS against the committed repo (baseline drifted from HEAD?)"
fi

# A scratch copy with the real baseline also passes.
S="$(fresh_scratch 001)"
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" >/dev/null 2>&1; then
  ok "clean scratch copy PASSES via --scripts-dir/--baseline"
else
  bad "clean scratch copy unexpectedly FAILS"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-002: injected NEW 'gh pr view' in scratch lib-dispatch.sh FAILS naming the site ==="
# ---------------------------------------------------------------------------
S="$(fresh_scratch 002)"
# shellcheck disable=SC2016
printf '\ninjected_fn() { gh pr view "$INJECTED_VAR" --json state; }\n' >> "$S/lib-dispatch.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'lib-dispatch.sh' <<<"$out" && grep -q 'gh pr view "\$INJECTED_VAR"' <<<"$out"; then
  ok "injected raw 'gh pr view' → exit non-zero, ::error:: names lib-dispatch.sh + the offending content"
else
  bad "injected raw 'gh pr view' NOT caught (rc=$rc)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-003: an allowlisted gh site (gh-app-token.sh / gh-with-token-refresh.sh) does NOT trip ==="
# ---------------------------------------------------------------------------
S="$(fresh_scratch 003)"
# shellcheck disable=SC2016
printf '\nextra_allow_fn() { gh api user --jq .login; }\n' >> "$S/gh-app-token.sh"
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" >/dev/null 2>&1; then
  ok "a raw gh inside an allowlisted file (gh-app-token.sh) does NOT trip the lint"
else
  bad "allowlisted-file gh tripped the lint (it must not — allowlisted files legitimately hold gh)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-004: consuming-boundary catch — a gh a naive \\bgh / look-behind would mishandle ==="
# ---------------------------------------------------------------------------
# (a) A genuine NEW caller-layer 'gh ' that is NOT word-anchored the naive way:
#     placed right after a '(' so a look-behind-based pattern is brittle; the
#     consuming boundary (^|[^A-Za-z_-]) catches it.
S="$(fresh_scratch 004a)"
# shellcheck disable=SC2016
printf '\nfn() { x=$(gh issue view 7 --json body); echo "$x"; }\n' >> "$S/autonomous-dev.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'gh issue view 7' <<<"$out"; then
  ok "consuming-boundary catches '\$(gh issue view …' (a gh after '(' — a non-look-behind boundary still matches)"
else
  bad "consuming-boundary missed '\$(gh issue view …' (rc=$rc) — regression vs project_gh_jq_re2_no_lookbehind"
fi
# (b) tokens ending in 'gh' (e.g. 'logh', 'agh_x') must NOT be misread as a gh call.
S="$(fresh_scratch 004b)"
# shellcheck disable=SC2016
printf '\nfn2() { local agh_x=1; logh "$agh_x"; }\n' >> "$S/lib-dispatch.sh"
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" >/dev/null 2>&1; then
  ok "boundary excludes 'agh_'/'logh' (not preceded by start/non-[A-Za-z_-]) — no false positive"
else
  bad "boundary false-positived on 'agh_'/'logh' (the consuming class is wrong)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-005: a DUPLICATE of an already-baselined line FAILS (count bump) ==="
# ---------------------------------------------------------------------------
S="$(fresh_scratch 005)"
# Append a 2nd identical copy of an already-baselined autonomous-dev.sh line.
# shellcheck disable=SC2016
printf '\n  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \\\n    --add-label "dup"\n' >> "$S/autonomous-dev.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qi 'gh issue edit' <<<"$out"; then
  ok "a duplicate of a baselined line → exit non-zero (discovered count > baseline)"
else
  bad "duplicate of a baselined line NOT caught (rc=$rc) — count reconciliation broken"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-006: a stale baseline entry (file no longer exists) FAILS loud ==="
# ---------------------------------------------------------------------------
S="$(fresh_scratch 006)"
stale_base="$WORK/baseline-stale.json"
jq '.surviving_sites += [{"file":"no-such-file.sh","content":"gh issue view 1","count":1}]' "$BASELINE" > "$stale_base"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$stale_base" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'no-such-file.sh' <<<"$out"; then
  ok "stale baseline entry (missing file) → exit non-zero naming the stale file"
else
  bad "stale baseline entry NOT caught (rc=$rc)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-007: a missing provider leaf file FAILS naming it ==="
# ---------------------------------------------------------------------------
S="$(fresh_scratch 007)"
rm -f "$S/providers/itp-github.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'itp-github.sh is MISSING' <<<"$out"; then
  ok "missing providers/itp-github.sh → exit non-zero naming it"
else
  bad "missing provider file NOT caught (rc=$rc)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-008: a REMOVED baselined site FAILS (forces baseline shrink as migration lands) ==="
# ---------------------------------------------------------------------------
S="$(fresh_scratch 008)"
# Delete the 'gh issue close' baselined line from the scratch review wrapper.
grep -v 'gh issue close "\$ISSUE_NUMBER" --repo "\$REPO" --reason completed' \
  "$SCRIPTS/autonomous-review.sh" > "$S/autonomous-review.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -qi 'no longer finds' <<<"$out"; then
  ok "removed baselined site → exit non-zero (baseline must shrink — a migration landed)"
else
  bad "removed baselined site NOT caught (rc=$rc) — reverse reconciliation broken"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-009: script contract — INV-91 header, set -uo pipefail, jq-only ==="
# ---------------------------------------------------------------------------
src="$(cat "$CHECK")"
if grep -q 'INV-91' <<<"$src"; then ok "header cites INV-91"; else bad "header does NOT cite INV-91"; fi
if grep -q 'set -uo pipefail' <<<"$src"; then ok "uses set -uo pipefail"; else bad "missing set -uo pipefail"; fi
# RE2-safe consuming boundary present, no look-behind/ahead.
if grep -Fq '(^|[^A-Za-z_-])gh ' <<<"$src"; then ok "uses the RE2-safe consuming boundary (^|[^A-Za-z_-])gh "; else bad "consuming boundary not found"; fi
if grep -Eq '\(\?<|\(\?=' <<<"$src"; then bad "uses a look-behind/look-ahead (forbidden — project_gh_jq_re2_no_lookbehind)"; else ok "no look-behind/look-ahead (RE2-safe)"; fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-010: usage contract — --help exits 0, unknown flag exits 2 ==="
# ---------------------------------------------------------------------------
bash "$CHECK" --help >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then ok "--help exits 0"; else bad "--help exit $rc (expected 0)"; fi
bash "$CHECK" --no-such-flag >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then ok "unknown flag exits 2 (usage)"; else bad "unknown flag exit $rc (expected 2)"; fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-011: --generate-baseline emits valid JSON that the checker then accepts ==="
# ---------------------------------------------------------------------------
gen="$WORK/gen-baseline.json"
if bash "$CHECK" --generate-baseline > "$gen" 2>/dev/null && jq -e . "$gen" >/dev/null 2>&1; then
  ok "--generate-baseline emits valid JSON"
  if bash "$CHECK" --baseline "$gen" >/dev/null 2>&1; then
    ok "the freshly-generated baseline reconciles (generator ⇄ checker are consistent by construction)"
  else
    bad "freshly-generated baseline does NOT reconcile (generator/checker disagree)"
  fi
else
  bad "--generate-baseline did not emit valid JSON"
fi

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
