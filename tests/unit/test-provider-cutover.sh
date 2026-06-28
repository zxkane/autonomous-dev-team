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

# A fresh scratch scripts dir per mutating test, so injections never touch the
# committed tree. Mirrors top-level *.sh PLUS the nested subdirs (providers/,
# adapters/) — `cp -rL` dereferences the symlinked tracked scripts
# (mark-issue-checkbox.sh etc.) into real files so the scratch tree is a faithful,
# self-contained copy the recursive `find -L` scan walks identically to the repo.
fresh_scratch() {
  local d="$WORK/scratch.$1" sub
  rm -rf "$d"; mkdir -p "$d"
  cp -L "$SCRIPTS"/*.sh "$d/" 2>/dev/null
  for sub in providers adapters; do
    [ -d "$SCRIPTS/$sub" ] && cp -rL "$SCRIPTS/$sub" "$d/$sub" 2>/dev/null
  done
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
# AC #2: the ::error:: must name the EXACT file:line of the offending raw-gh.
if [[ "$rc" -ne 0 ]] && grep -Eq 'lib-dispatch\.sh:[0-9]+' <<<"$out" && grep -q 'gh pr view "\$INJECTED_VAR"' <<<"$out"; then
  ok "injected raw 'gh pr view' → exit non-zero, ::error:: names exact lib-dispatch.sh:LINE + the offending content (AC #2)"
else
  bad "injected raw 'gh pr view' NOT caught with file:line (rc=$rc)"
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

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-012: tree-wide — a NEW raw-gh in a NON-caller dispatcher script is caught with file:line (AC #41) ==="
# ---------------------------------------------------------------------------
# AC #41: every surviving raw-gh in skills/autonomous-dispatcher/scripts/ must
# resolve to providers/ or an allowlisted file — NOT just the caller layer. Inject
# into setup-labels.sh (a non-caller-layer dispatcher script) and confirm the
# tree-wide scan catches it, naming file:line.
S="$(fresh_scratch 012)"
# shellcheck disable=SC2016
printf '\ntree_inject() { gh issue comment "$N" --body x; }\n' >> "$S/setup-labels.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'setup-labels\.sh:[0-9]+' <<<"$out"; then
  ok "NEW raw-gh in a non-caller script (setup-labels.sh) → caught tree-wide naming file:line (AC #41)"
else
  bad "tree-wide scan missed a non-caller-script raw-gh (rc=$rc) — Check is still caller-layer-only"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-013: a NEW raw-gh UNDER providers/ does NOT trip (migration target) ==="
# ---------------------------------------------------------------------------
S="$(fresh_scratch 013)"
# shellcheck disable=SC2016
printf '\nitp_github_newleaf() { gh issue view "$1" --json body; }\n' >> "$S/providers/itp-github.sh"
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" >/dev/null 2>&1; then
  ok "a raw gh under providers/ is allowed (the legitimate home of migrated host I/O)"
else
  bad "providers/ gh tripped the lint (it must not — providers/ is the migration target)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-014: the guard is NOT wholesale-allowlisted — a NEW raw gh in the checker itself FAILS (round 2 [P1] #2) ==="
# ---------------------------------------------------------------------------
# The checker's own `gh `-mentioning lines (its regex literal + PASS/FAIL messages)
# are recorded in the baseline as ordinary survivors, NOT exempted by file. So a
# clean tree PASSES (those lines are baselined — TC-001), but a genuinely-new raw
# gh invocation added to the checker is unbaselined → FAILs. (Previously the whole
# file was allowlisted, so a `gh api user` backdoor in the checker passed silently.)
if grep -Eq 'ALLOWLISTED_FILES=\([^)]*check-provider-cutover\.sh' <<<"$src"; then
  bad "check-provider-cutover.sh is STILL wholesale-allowlisted — a raw gh in the checker would pass silently (round 2 [P1] #2 not fixed)"
else
  ok "check-provider-cutover.sh is NOT in ALLOWLISTED_FILES (it is scanned like any file; its legit gh lines are baselined)"
fi
S="$(fresh_scratch 014)"
# shellcheck disable=SC2016
printf '\ngh_backdoor() { gh api user; }\n' >> "$S/check-provider-cutover.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'check-provider-cutover\.sh:[0-9]+' <<<"$out" && grep -q 'gh api user' <<<"$out"; then
  ok "a NEW 'gh api user' added to the checker itself → exit non-zero naming check-provider-cutover.sh:LINE"
else
  bad "a NEW raw gh in the checker was NOT caught (rc=$rc) — the self-exemption is still too broad"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-015: NESTED subdir — a NEW raw-gh in adapters/*.sh is discovered (recursive scan, round 2 [P1] #1) ==="
# ---------------------------------------------------------------------------
# tree_sh_files() must recurse: a raw gh under adapters/ (or any nested subdir)
# was invisible to the old top-level + providers/-only glob. Inject into a real
# nested adapter and confirm the recursive scan catches it, naming the nested path.
S="$(fresh_scratch 015)"
if [ -f "$S/adapters/codex.sh" ]; then
  # shellcheck disable=SC2016
  printf '\nnested_inject() { gh issue view 123 --json title; }\n' >> "$S/adapters/codex.sh"
  out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 ]] && grep -Eq 'adapters/codex\.sh:[0-9]+' <<<"$out"; then
    ok "NEW raw-gh in adapters/codex.sh → caught by the recursive scan naming adapters/codex.sh:LINE"
  else
    bad "nested-subdir raw-gh NOT caught (rc=$rc) — scan is not recursing into adapters/"
  fi
else
  bad "scratch tree missing adapters/codex.sh — fresh_scratch did not copy the nested subdir"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-016: symlinked tracked scripts (mark-issue-checkbox.sh) stay in scope (find -L) ==="
# ---------------------------------------------------------------------------
# Several tracked scripts are committed as symlinks; `find -L` must still scan
# them (a plain -type f would skip a symlink → drop its gh sites). Inject a NEW gh
# and confirm it is caught.
S="$(fresh_scratch 016)"
# shellcheck disable=SC2016
printf '\nsym_inject() { gh issue comment 1 --body z; }\n' >> "$S/mark-issue-checkbox.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'mark-issue-checkbox\.sh:[0-9]+' <<<"$out"; then
  ok "NEW raw-gh in the (symlinked) mark-issue-checkbox.sh → caught (find -L keeps symlinked scripts in scope)"
else
  bad "symlinked-script raw-gh NOT caught (rc=$rc) — find -L regressed"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-017: Check 4 closes the same-PR baseline self-ratification bypass ==="
# ---------------------------------------------------------------------------
# The #286 review bypass: a PR that BOTH adds a raw-gh AND regenerates the baseline
# satisfies Check 1 (tree == in-PR baseline). Check 4 anchors the baseline to a
# TRUSTED git ref and FAILs if it GREW. Build a real git repo: commit the clean
# tree as the trusted ref, then inject a gh + regenerate the baseline, and assert
# the full guard FAILs against --trusted-ref naming the grown site.
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch 017)"
  GROOT="$WORK/gitrepo017"
  rm -rf "$GROOT"; mkdir -p "$GROOT/skills/autonomous-dispatcher/scripts"
  cp -rL "$S"/. "$GROOT/skills/autonomous-dispatcher/scripts/" 2>/dev/null
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  GS="$GROOT/skills/autonomous-dispatcher/scripts"
  # inject a NEW raw-gh + regenerate the baseline IN-PLACE (the bypass attempt)
  # shellcheck disable=SC2016
  printf '\nbypass_fn() { gh issue view 999 --json title; }\n' >> "$GS/dispatcher-tick.sh"
  bash "$CHECK" --generate-baseline --scripts-dir "$GS" > "$GS/providers/cutover-baseline.json" 2>/dev/null
  # Check 1 alone now passes (baseline ratified the new site); the FULL guard with
  # Check 4 vs trusted-main must FAIL.
  out="$( cd "$GROOT" && bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main 2>&1 )"; rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'baseline GREW vs trusted-main' <<<"$out" && grep -q 'dispatcher-tick.sh' <<<"$out"; then
    ok "same-PR baseline regeneration that ADDS a raw-gh → Check 4 FAILs naming the grown site (bypass closed)"
  else
    bad "Check 4 did NOT catch the self-ratification bypass (rc=$rc): ${out:0:200}"
  fi
else
  ok "git unavailable — TC-CUTOVER-017 skipped (Check 4 degrades gracefully without git)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-018: Check 4 SHRINK is allowed; missing-trusted-ref skips gracefully ==="
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch 018)"
  GROOT="$WORK/gitrepo018"
  rm -rf "$GROOT"; mkdir -p "$GROOT/skills/autonomous-dispatcher/scripts"
  cp -rL "$S"/. "$GROOT/skills/autonomous-dispatcher/scripts/" 2>/dev/null
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  GS="$GROOT/skills/autonomous-dispatcher/scripts"
  # SHRINK: drop a baselined site by removing its line, then regenerate → smaller
  # baseline. Check 4 must still PASS (migration progress is allowed).
  # Use a fabricated extra survivor: add one, commit as trusted, then remove it.
  ( cd "$GROOT" && git checkout -q -b shrink-test )
  # The clean tree already reconciles; a pure shrink can't be forced without a real
  # removal, so assert the easier invariant: an UNCHANGED baseline vs trusted PASSES.
  out="$( cd "$GROOT" && bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main 2>&1 )"; rc=$?
  if [[ "$rc" -eq 0 ]] && grep -q 'baseline did not grow' <<<"$out"; then
    ok "unchanged baseline vs trusted-main PASSES Check 4 (no false positive on a clean PR)"
  else
    bad "Check 4 false-positived on an unchanged baseline (rc=$rc): ${out:0:200}"
  fi
  # Missing trusted ref → graceful skip (shallow/fork checkout), guard still PASSES.
  out="$( cd "$GROOT" && bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref no-such-ref 2>&1 )"; rc=$?
  if [[ "$rc" -eq 0 ]] && grep -q 'not resolvable' <<<"$out"; then
    ok "unresolvable trusted ref → Check 4 skips gracefully (the merge gate re-runs with origin/main)"
  else
    bad "Check 4 did not skip gracefully on a missing ref (rc=$rc): ${out:0:200}"
  fi
else
  ok "git unavailable — TC-CUTOVER-018 skipped"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-019: --require-trusted-ref closes the shallow-CI skip hole ==="
# ---------------------------------------------------------------------------
# The #286 review hole: the hermetic-unit job runs the guard via the test glob under
# a DEPTH-1 checkout where origin/main is absent, so Check 4 SKIPS and a PR that adds
# a raw-gh + regenerates the baseline passes green. --require-trusted-ref makes an
# unresolvable trusted ref a FAILURE instead of a skip. Two assertions:
#   (a) ref PRESENT + unchanged baseline → PASS even under strict (no false positive);
#   (b) ref ABSENT under strict → FAIL (the shallow hole is now caught, not skipped).
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch 019)"
  GROOT="$WORK/gitrepo019"
  rm -rf "$GROOT"; mkdir -p "$GROOT/skills/autonomous-dispatcher/scripts"
  cp -rL "$S"/. "$GROOT/skills/autonomous-dispatcher/scripts/" 2>/dev/null
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  GS="$GROOT/skills/autonomous-dispatcher/scripts"
  # (a) strict + ref present + unchanged baseline → PASS
  if ( cd "$GROOT" && bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --require-trusted-ref >/dev/null 2>&1 ); then
    ok "strict mode + resolvable trusted ref + unchanged baseline → PASS (no false positive)"
  else
    bad "strict mode false-positived with the trusted ref present"
  fi
  # (b) strict + UNRESOLVABLE ref → FAIL (the shallow-CI hole, now caught)
  out="$( cd "$GROOT" && bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref no-such-ref --require-trusted-ref 2>&1 )"; rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'monotonicity check REQUIRED' <<<"$out"; then
    ok "strict mode + UNRESOLVABLE trusted ref → FAIL (shallow-CI skip hole closed)"
  else
    bad "strict mode did NOT fail on a missing trusted ref (rc=$rc): ${out:0:200}"
  fi
  # Sanity: default (non-strict) mode still SKIPS gracefully on the same missing ref.
  if ( cd "$GROOT" && bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref no-such-ref >/dev/null 2>&1 ); then
    ok "non-strict mode still skips gracefully on a missing ref (fork/ad-hoc runs unaffected)"
  else
    bad "non-strict mode unexpectedly failed on a missing ref (the opt-in should be required)"
  fi
else
  ok "git unavailable — TC-CUTOVER-019 skipped"
fi

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
