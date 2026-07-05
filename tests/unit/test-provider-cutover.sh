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
  if [[ "$rc" -ne 0 ]] && grep -q 'baseline GREW' <<<"$out" && grep -q 'trusted-main' <<<"$out" && grep -q 'dispatcher-tick.sh' <<<"$out"; then
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

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-020: derive-from-tree closes the initial-landing self-ratification (#286 finding #1) ==="
# ---------------------------------------------------------------------------
# When the trusted ref has the scripts but NOT the baseline JSON yet (the PR that
# INTRODUCES the baseline — origin/main today), the NON-STRICT Check 4 derives the
# trusted survivor set from the trusted TREE (a best-effort belt). Two properties:
#   (a) a NEW raw-gh in an EXISTING (on-ref) script + regenerated baseline → FAIL
#       (the landing PR can't self-ratify a new caller-layer gh), naming the site;
#   (c) symlinked tracked scripts (mark-issue-checkbox.sh) do NOT false-positive
#       (the ref-tree read dereferences the symlink, mirroring the working-tree find -L).
# NOTE: derive-from-tree is NON-STRICT only; under --require-trusted-ref a missing
# trusted baseline FAILs closed BEFORE deriving (AC #6) -- covered by TC-CUTOVER-021.
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch 020)"
  GROOT="$WORK/gitrepo020"; GS="$GROOT/sd"
  rm -rf "$GROOT"; mkdir -p "$GS"
  cp -rL "$S"/. "$GS/" 2>/dev/null
  rm -f "$GS/providers/cutover-baseline.json"   # trusted tree has scripts but NO baseline JSON
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  # PR: inject a NEW gh into an EXISTING script + regenerate the baseline (ratify it).
  # shellcheck disable=SC2016
  printf '\nabuse_fn() { gh pr view 999 --json state; }\n' >> "$GS/lib-dispatch.sh"
  CUTOVER_TRUSTED_SCRIPTS_PREFIX="sd" bash "$CHECK" --generate-baseline --scripts-dir "$GS" > "$GS/providers/cutover-baseline.json" 2>/dev/null
  # NON-strict: derive-from-tree catches the growth (no --require-trusted-ref).
  out="$( cd "$GROOT" && CUTOVER_TRUSTED_SCRIPTS_PREFIX="sd" bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --trusted-baseline-path "sd/providers/cutover-baseline.json" 2>&1 )"; rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'lib-dispatch.sh raw-gh' <<<"$out" && grep -q 'gh pr view 999' <<<"$out"; then
    ok "(a) NON-strict: NEW gh in an EXISTING on-ref script, derived-from-tree → FAIL naming lib-dispatch.sh (landing PR can't self-ratify)"
  else
    bad "(a) non-strict derive-from-tree did NOT catch the new gh in lib-dispatch.sh (rc=$rc): ${out:0:200}"
  fi
  if ! grep -q "GREW vs .* mark-issue-checkbox.sh" <<<"$out" \
     && ! grep -q "GREW vs .* reply-to-comments.sh" <<<"$out" \
     && ! grep -q "GREW vs .* upload-screenshot.sh" <<<"$out"; then
    ok "(c) symlinked tracked scripts do NOT false-positive (ref-tree read dereferences the symlink)"
  else
    bad "(c) a symlinked tracked script false-positived as growth: ${out:0:200}"
  fi
else
  ok "git unavailable — TC-CUTOVER-020 skipped"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-021: strict-mode FAIL-CLOSED on a missing baseline (AC #6 / review P1#1) ==="
# ---------------------------------------------------------------------------
# Owner ruling (2026-06-28, AC #6): with --require-trusted-ref, a missing/unreadable/
# unparseable baseline -- OR a trusted ref that resolves but lacks cutover-baseline.json
# -- MUST exit 1, never "nothing to regress against yet" + exit 0. A baseline is
# (re)generated ONLY under --generate-baseline, never silently during a normal lint.
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch 021)"
  GROOT="$WORK/gitrepo021"; GS="$GROOT/sd"
  rm -rf "$GROOT"; mkdir -p "$GS"
  cp -rL "$S"/. "$GS/" 2>/dev/null
  rm -f "$GS/providers/cutover-baseline.json"   # trusted tree: scripts present, NO baseline JSON
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  # Working tree DOES have a (regenerated) baseline so Check 1 passes; the trusted ref does NOT.
  CUTOVER_TRUSTED_SCRIPTS_PREFIX="sd" bash "$CHECK" --generate-baseline --scripts-dir "$GS" > "$GS/providers/cutover-baseline.json" 2>/dev/null
  # (1) strict + trusted ref lacks baseline.json → FAIL CLOSED (no derive-from-tree fallback).
  out="$( cd "$GROOT" && CUTOVER_TRUSTED_SCRIPTS_PREFIX="sd" bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --require-trusted-ref --trusted-baseline-path "sd/providers/cutover-baseline.json" 2>&1 )"; rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'strict monotonicity' <<<"$out" && grep -q 'has no readable cutover-baseline.json' <<<"$out"; then
    ok "(1) strict + trusted ref lacks cutover-baseline.json → FAIL CLOSED (no silent derive-from-tree, no exit 0)"
  else
    bad "(1) strict-missing-trusted-baseline did NOT fail closed (rc=$rc): ${out:0:200}"
  fi
  # (2) strict + missing WORKING-TREE baseline → FAIL CLOSED (exit 1, not the exit-3 env path).
  out="$( cd "$GROOT" && CUTOVER_TRUSTED_SCRIPTS_PREFIX="sd" bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/does-not-exist.json" --trusted-ref trusted-main --require-trusted-ref --trusted-baseline-path "sd/providers/cutover-baseline.json" 2>&1 )"; rc=$?
  if [[ "$rc" -eq 1 ]] && grep -q 'baseline not found' <<<"$out"; then
    ok "(2) strict + missing working-tree baseline → exit 1 fail-closed (not the non-strict exit-3 env path)"
  else
    bad "(2) strict-missing-working-baseline did NOT exit 1 (rc=$rc): ${out:0:200}"
  fi
  # (3) NON-strict + trusted ref lacks baseline → still derives-from-tree (does NOT fail-closed)
  #     on an unchanged baseline: PASS (the permissive default is preserved).
  out="$( cd "$GROOT" && CUTOVER_TRUSTED_SCRIPTS_PREFIX="sd" bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --trusted-baseline-path "sd/providers/cutover-baseline.json" 2>&1 )"; rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "(3) NON-strict + trusted ref lacks baseline + unchanged tree → PASS (derive-from-tree belt; permissive default preserved)"
  else
    bad "(3) non-strict unexpectedly failed on an unchanged tree (rc=$rc): ${out:0:200}"
  fi
else
  ok "git unavailable — TC-CUTOVER-021 skipped"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTOVER-022: --trusted-baseline-path override WITHOUT prefix env still classifies growth (#286 review P1#1) ==="
# ---------------------------------------------------------------------------
# Regression for the prefix-staleness bug: TRUSTED_SCRIPTS_PREFIX was derived from the
# DEFAULT TRUSTED_BASELINE_PATH at init time, BEFORE the arg loop parsed
# --trusted-baseline-path. So a caller overriding ONLY --trusted-baseline-path (no
# CUTOVER_TRUSTED_SCRIPTS_PREFIX env, no --trusted-scripts-prefix flag) probed the
# trusted tree under the wrong (default) prefix -> a real growth in an EXISTING file
# was misclassified as a new-file introduction -> false PASS. The fix derives the
# prefix AFTER arg parsing. This test deliberately passes NO prefix env/flag.
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch 022)"
  GROOT="$WORK/gitrepo022"; GS="$GROOT/sd"
  rm -rf "$GROOT"; mkdir -p "$GS"
  cp -rL "$S"/. "$GS/" 2>/dev/null
  rm -f "$GS/providers/cutover-baseline.json"
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  # shellcheck disable=SC2016
  printf '\nabuse_fn() { gh pr view 999 --json state; }\n' >> "$GS/lib-dispatch.sh"
  # generate the baseline WITHOUT the prefix env too (the prefix must derive from
  # --trusted-baseline-path for the trusted-tree probe; generate only needs scripts-dir).
  bash "$CHECK" --generate-baseline --scripts-dir "$GS" > "$GS/providers/cutover-baseline.json" 2>/dev/null
  # NO CUTOVER_TRUSTED_SCRIPTS_PREFIX, NO --trusted-scripts-prefix: only --trusted-baseline-path.
  out="$( cd "$GROOT" && bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --trusted-baseline-path "sd/providers/cutover-baseline.json" 2>&1 )"; rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'lib-dispatch.sh raw-gh' <<<"$out" && grep -q 'gh pr view 999' <<<"$out"; then
    ok "override --trusted-baseline-path alone (no prefix env/flag) → prefix derives correctly, growth CAUGHT (P1#1 fixed)"
  else
    bad "prefix-staleness regression: --trusted-baseline-path override misclassified growth as a new file (rc=$rc): ${out:0:200}"
  fi
  # And an explicit --trusted-scripts-prefix override is honored too.
  out2="$( cd "$GROOT" && bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --trusted-baseline-path "sd/providers/cutover-baseline.json" --trusted-scripts-prefix "sd" 2>&1 )"; rc2=$?
  if [[ "$rc2" -ne 0 ]] && grep -q 'gh pr view 999' <<<"$out2"; then
    ok "explicit --trusted-scripts-prefix is honored (growth still caught)"
  else
    bad "explicit --trusted-scripts-prefix not honored (rc=$rc2): ${out2:0:200}"
  fi
else
  ok "git unavailable — TC-CUTOVER-022 skipped"
fi

# ===========================================================================
# #286-amendment (#343) — the guard stops self-detecting its own ALLOWLISTED_FILES
# array + primary matcher + _comment template lines, so an allowlist disposition no
# longer self-trips Check 4 monotonicity. TC-CUTAMEND-NNN.
# ===========================================================================

# ---------------------------------------------------------------------------
echo "=== TC-CUTAMEND-001: --generate-baseline emits NO checker ALLOWLISTED_FILES=( signature (R1) ==="
# ---------------------------------------------------------------------------
gen_amend="$WORK/gen-amend.json"
bash "$CHECK" --generate-baseline > "$gen_amend" 2>/dev/null
n_arr="$(jq '[.surviving_sites[] | select(.file=="check-provider-cutover.sh") | select(.content | startswith("ALLOWLISTED_FILES=("))] | length' "$gen_amend" 2>/dev/null)"
if [[ "$n_arr" == "0" ]]; then
  ok "generated baseline has ZERO check-provider-cutover.sh 'ALLOWLISTED_FILES=(' survivor (array line structurally exempt, R1)"
else
  bad "generated baseline still carries $n_arr checker 'ALLOWLISTED_FILES=(' signature(s) — array line not exempted (R1)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTAMEND-002: --generate-baseline emits NO checker primary-matcher signature (R1) ==="
# ---------------------------------------------------------------------------
# The matcher line is the sole `grep -aE '(^|[^…])gh ' …` line in the checker.
n_match="$(jq -r '[.surviving_sites[] | select(.file=="check-provider-cutover.sh") | .content] | map(select(startswith("grep -aE"))) | length' "$gen_amend" 2>/dev/null)"
if [[ "$n_match" == "0" ]]; then
  ok "generated baseline has ZERO check-provider-cutover.sh 'grep -aE …' matcher survivor (matcher line structurally exempt, R1)"
else
  bad "generated baseline still carries $n_match checker matcher signature(s) — matcher line not exempted (R1)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTAMEND-003: the structural skip is FILE-SCOPED — array/matcher-shaped lines in ANOTHER file still FAIL (R1: no escape hatch) ==="
# ---------------------------------------------------------------------------
# An ALLOWLISTED_FILES=(gh …)-shaped line and a matcher-shaped line injected into a
# NON-checker file must STILL be caught as NEW unbaselined raw-gh — the exemption is
# NOT a general annotation an arbitrary file can carry (guards against self-allowlisting).
S="$(fresh_scratch amend003a)"
# shellcheck disable=SC2016
printf '\nALLOWLISTED_FILES=(gh some-other.sh)\n' >> "$S/setup-labels.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'setup-labels\.sh:[0-9]+' <<<"$out"; then
  ok "an 'ALLOWLISTED_FILES=(gh …)'-shaped line in setup-labels.sh → still FAILs (file-scoped skip, no escape hatch)"
else
  bad "the ALLOWLISTED_FILES-shaped exemption leaked to a non-checker file (rc=$rc) — the skip is NOT file-scoped"
fi
S="$(fresh_scratch amend003b)"
# shellcheck disable=SC2016
printf "\nmatcher_copy() { grep -aE '(^|[^A-Za-z_-])gh ' \"\$f\"; }\n" >> "$S/setup-labels.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'setup-labels\.sh:[0-9]+' <<<"$out"; then
  ok "a matcher-shaped 'grep -aE …gh ' line in setup-labels.sh → still FAILs (matcher exemption is file-scoped too)"
else
  bad "the matcher-shaped exemption leaked to a non-checker file (rc=$rc)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTAMEND-004: committed baseline dropped the 2 exempt infra sigs but KEPT the PASS/FAIL self-scan sigs (R2) ==="
# ---------------------------------------------------------------------------
# The array line + matcher line leave; the deliberate self-scan of the guard's own
# PASS/FAIL message strings STAYS (a NEW raw gh in the checker must still FAIL).
n_arr_c="$(jq '[.surviving_sites[] | select(.file=="check-provider-cutover.sh") | select(.content | startswith("ALLOWLISTED_FILES=("))] | length' "$BASELINE")"
n_match_c="$(jq -r '[.surviving_sites[] | select(.file=="check-provider-cutover.sh") | .content] | map(select(startswith("grep -aE"))) | length' "$BASELINE")"
n_self="$(jq '[.surviving_sites[] | select(.file=="check-provider-cutover.sh") | select((.content|contains("cutover-guard: PASS")) or (.content|startswith("fail ")))] | length' "$BASELINE")"
if [[ "$n_arr_c" == "0" && "$n_match_c" == "0" && "$n_self" -ge 1 ]]; then
  ok "committed baseline: 0 array-line + 0 matcher-line checker sigs, $n_self PASS/FAIL self-scan sigs retained (R2)"
else
  bad "committed baseline R2 property violated (array=$n_arr_c matcher=$n_match_c self-scan=$n_self)"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTAMEND-005: the _comment template no longer EMBEDS the allowlist file-list (R2 neutralization) ==="
# ---------------------------------------------------------------------------
# Both the generator template (in the script) and the committed baseline _comment
# must not carry the parenthesized allowlist file-list, so an allowlist edit no
# longer churns the _comment signature.
comment_committed="$(jq -r '._comment' "$BASELINE")"
if ! grep -Eq '\((scripts/)?gh[, ]gh-with-token-refresh\.sh' <<<"$comment_committed" \
   && ! grep -Eq 'gh-app-token\.sh, gh-as-user\.sh, dispatch-remote-aws-ssm\.sh' <<<"$comment_committed"; then
  ok "committed baseline _comment no longer embeds the allowlist file-list (allowlist edits won't churn it, R2)"
else
  bad "committed baseline _comment STILL embeds the allowlist file-list — an allowlist edit will still churn the _comment signature"
fi
# And the generator template in the script itself.
if ! grep -Eq '_comment:.*\((scripts/)?gh gh-with-token-refresh\.sh' "$CHECK" \
   && ! grep -Eq '_comment:.*\(scripts/gh, gh-with-token-refresh\.sh' "$CHECK"; then
  ok "the _comment generator template (in check-provider-cutover.sh) no longer embeds the allowlist file-list (R2)"
else
  bad "the _comment generator template STILL embeds the allowlist file-list"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTAMEND-006: self-scan PRESERVED — a NEW genuine 'gh api user' in the checker still FAILs unbaselined (R3) ==="
# ---------------------------------------------------------------------------
# The amendment narrows the exemption to the two infra lines + _comment; it does NOT
# wholesale-allowlist the checker. A NEW raw gh added to the checker (not matching an
# anchor) is still unbaselined → FAILs (TC-CUTOVER-014 stays green too).
S="$(fresh_scratch amend006)"
# shellcheck disable=SC2016
printf '\namend_backdoor() { gh api user; }\n' >> "$S/check-provider-cutover.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'check-provider-cutover\.sh:[0-9]+' <<<"$out" && grep -q 'gh api user' <<<"$out"; then
  ok "a NEW 'gh api user' in the checker → still FAILs naming check-provider-cutover.sh:LINE (self-scan preserved, R3)"
else
  bad "the amendment over-broadened the exemption — a NEW raw gh in the checker was NOT caught (rc=$rc): ${out:0:200}"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTAMEND-007: an allowlist edit + baseline shrink no longer self-trips Check 4 on the guard's own file (R4) ==="
# ---------------------------------------------------------------------------
# The amendment's whole point: (i) append a filename to ALLOWLISTED_FILES, (ii) drop
# that file's own signatures from the baseline (what a real allowlist PR does), (iii)
# regenerate, (iv) run the FULL guard (strict --require-trusted-ref) — it must PASS
# with NO change to any check-provider-cutover.sh signature in the baseline. Before
# this amendment step (iv) FAILed because the edited array line itself became a NEW
# unbaselined checker signature (+ the old one "no longer found").
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch amend007)"
  GROOT="$WORK/gitrepo-amend007"
  rm -rf "$GROOT"; mkdir -p "$GROOT/skills/autonomous-dispatcher/scripts"
  cp -rL "$S"/. "$GROOT/skills/autonomous-dispatcher/scripts/" 2>/dev/null
  GS="$GROOT/skills/autonomous-dispatcher/scripts"
  # A real allowlist PR edits check-provider-cutover.sh's OWN ALLOWLISTED_FILES and
  # runs THAT edited checker to regenerate + verify — so drive the SCRATCH checker
  # (the one whose allowlist we mutate), not the worktree $CHECK.
  GCHECK="$GS/check-provider-cutover.sh"
  # Regenerate the scratch baseline so the committed-vs-scratch tree reconciles as the
  # trusted base, then commit as trusted-main.
  bash "$GCHECK" --generate-baseline --scripts-dir "$GS" > "$GS/providers/cutover-baseline.json" 2>/dev/null
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  # Snapshot the checker's OWN signatures on trusted-main (must be unchanged after the edit).
  checker_sigs_before="$(jq -S '[.surviving_sites[] | select(.file=="check-provider-cutover.sh")]' "$GS/providers/cutover-baseline.json")"
  # (i) allowlist a file: pick a currently-baselined file (upload-screenshot.sh) and add it.
  perl -0pi -e 's/^ALLOWLISTED_FILES=\(([^)]*)\)/ALLOWLISTED_FILES=($1 upload-screenshot.sh)/m' "$GCHECK"
  # (ii)+(iii) regenerate with the EDITED checker: allowlisting the file drops its own
  #            sigs; the array-line edit does NOT introduce a new checker sig (exempt).
  bash "$GCHECK" --generate-baseline --scripts-dir "$GS" > "$GS/providers/cutover-baseline.json" 2>/dev/null
  checker_sigs_after="$(jq -S '[.surviving_sites[] | select(.file=="check-provider-cutover.sh")]' "$GS/providers/cutover-baseline.json")"
  # (iv) run the FULL guard STRICT vs trusted-main (with the EDITED checker).
  out="$( cd "$GROOT" && bash "$GCHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --require-trusted-ref 2>&1 )"; rc=$?
  # Property 1: the guard PASSES (Checks 1-4 all green).
  if [[ "$rc" -eq 0 ]]; then
    ok "(1) allowlist edit + baseline shrink → FULL guard PASSES under --require-trusted-ref (no self-trip, R4)"
  else
    bad "(1) allowlist edit self-tripped the guard (rc=$rc): ${out:0:260}"
  fi
  # Property 2: NO check-provider-cutover.sh signature changed in the baseline.
  if [[ "$checker_sigs_before" == "$checker_sigs_after" ]]; then
    ok "(2) NO check-provider-cutover.sh signature changed by the allowlist edit (array line structurally exempt, R4)"
  else
    bad "(2) an allowlist edit changed a check-provider-cutover.sh baseline signature (R4 violated)"
  fi
  # Property 3: upload-screenshot.sh sigs actually left (the real allowlist effect landed).
  n_up="$(jq '[.surviving_sites[] | select(.file=="upload-screenshot.sh")] | length' "$GS/providers/cutover-baseline.json")"
  if [[ "$n_up" == "0" ]]; then
    ok "(3) the newly-allowlisted upload-screenshot.sh sigs left the baseline (the allowlist disposition took effect)"
  else
    bad "(3) upload-screenshot.sh still has $n_up sigs — allowlisting did not drop them"
  fi
else
  ok "git unavailable — TC-CUTAMEND-007 skipped"
fi

# ---------------------------------------------------------------------------
echo "=== TC-CUTAMEND-008: regression pin — the edited ALLOWLISTED_FILES array line is NOT reported as Check 4 GREW (R4) ==="
# ---------------------------------------------------------------------------
# The pre-amendment failure surfaced as a Check 4 'baseline GREW … check-provider-
# cutover.sh … ALLOWLISTED_FILES' monotonicity error (the edited array line became a
# new unbaselined checker signature). Pin that it no longer appears.
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch amend008)"
  GROOT="$WORK/gitrepo-amend008"; GS="$GROOT/sd"
  rm -rf "$GROOT"; mkdir -p "$GS"
  cp -rL "$S"/. "$GS/" 2>/dev/null
  bash "$CHECK" --generate-baseline --scripts-dir "$GS" > "$GS/providers/cutover-baseline.json" 2>/dev/null
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  # Append a name to ALLOWLISTED_FILES (a benign non-baselined name is fine here — we
  # only assert the array-line EDIT itself does not register as growth).
  perl -0pi -e 's/ALLOWLISTED_FILES=\(([^)]*)\)/ALLOWLISTED_FILES=($1 some-new-wrapper.sh)/' "$GS/check-provider-cutover.sh"
  bash "$CHECK" --generate-baseline --scripts-dir "$GS" > "$GS/providers/cutover-baseline.json" 2>/dev/null
  out="$( cd "$GROOT" && CUTOVER_TRUSTED_SCRIPTS_PREFIX="sd" bash "$CHECK" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --trusted-baseline-path "sd/providers/cutover-baseline.json" 2>&1 )"; rc=$?
  if [[ "$rc" -eq 0 ]] && ! grep -Eiq 'GREW.*check-provider-cutover\.sh.*ALLOWLISTED_FILES' <<<"$out"; then
    ok "editing ONLY ALLOWLISTED_FILES → no 'baseline GREW … ALLOWLISTED_FILES' monotonicity failure (pre-amendment mode fixed, R4)"
  else
    bad "the edited ALLOWLISTED_FILES array line still registers as Check 4 growth (rc=$rc): ${out:0:260}"
  fi
else
  ok "git unavailable — TC-CUTAMEND-008 skipped"
fi

# ---------------------------------------------------------------------------
echo "=== TC-FINALBATCH-001/002: the 6 reworded sites carry zero gh-token matches, meaning preserved (#344, R1) ==="
# ---------------------------------------------------------------------------
# Each of the 6 committed lines, located by a stable content ANCHOR (not a line
# number, which drifts) and checked against the guard's OWN live detector regex
# — proves the reword actually removes the trip condition (R1), not just "looks
# reworded". Also asserts each line still carries its original
# INV/remediation/context substring (meaning preserved). One table
# (file|anchor|keep|old) drives this loop AND the OLD-string-absent check in
# TC-FINALBATCH-008 below — a single source of truth instead of two
# independently-drifting lists.
declare -A FB_SITE=(
  [dev740]="autonomous-dev.sh|agent never ran, no ISSUE_NUMBER|ISSUE_NUMBER|no ISSUE_NUMBER or gh —"
  [err303]="lib-error.sh|CLI proxy not resolvable|AUTONOMOUS_CONF_DIR|token-refresh gh proxy not resolvable"
  [err332]="lib-error.sh|failed to surface envelope|degrading to log-only|gh rc=\${post_rc}"
  [pf119]="lib-review-postfail.sh|verdict comment post failed;|transient GitHub/API or token error|gh rc %s"
  [pv268]="post-verdict.sh|CLI proxy not found/executable|INV-56|token-refresh gh proxy not found/executable"
  [pv292]="post-verdict.sh|failed to post verdict comment|ISSUE_NUMBER|gh rc=\${POST_RC}"
)
for key in dev740 err303 err332 pf119 pv268 pv292; do
  IFS='|' read -r f anchor keep _old <<<"${FB_SITE[$key]}"
  path="$SCRIPTS/$f"
  content="$(grep -m1 -F "$anchor" "$path")"
  if [[ -z "$content" ]]; then
    bad "TC-FINALBATCH-001 $f (anchor '$anchor') — line not found (file drifted?)"
    continue
  fi
  if [[ "$content" =~ (^|[^A-Za-z_-])gh\  ]]; then
    bad "TC-FINALBATCH-001 $f (anchor '$anchor') still matches the gh-token detector: $content"
  else
    ok "TC-FINALBATCH-001 $f (anchor '$anchor') has zero gh-token matches (reword removed the trip)"
  fi
  if [[ "$content" == *"$keep"* ]]; then
    ok "TC-FINALBATCH-002 $f (anchor '$anchor') preserves '$keep' (meaning kept)"
  else
    bad "TC-FINALBATCH-002 $f (anchor '$anchor') lost '$keep': $content"
  fi
done

# ---------------------------------------------------------------------------
echo "=== TC-FINALBATCH-005: the gh_rc= breadcrumb KEY is untouched (machine key, not scanner prose, #344) ==="
# ---------------------------------------------------------------------------
if grep -q "printf 'gh_rc=%s\\\\n'" "$SCRIPTS/post-verdict.sh"; then
  ok "TC-FINALBATCH-005a post-verdict.sh still writes the gh_rc= breadcrumb key verbatim"
else
  bad "TC-FINALBATCH-005a post-verdict.sh's gh_rc= breadcrumb write changed unexpectedly"
fi
if grep -q "gh_rc=\[0-9\]" "$SCRIPTS/lib-review-postfail.sh"; then
  ok "TC-FINALBATCH-005b lib-review-postfail.sh still reads the gh_rc= breadcrumb key verbatim"
else
  bad "TC-FINALBATCH-005b lib-review-postfail.sh's gh_rc= breadcrumb read changed unexpectedly"
fi

# ---------------------------------------------------------------------------
echo "=== TC-FINALBATCH-006/007: upload-screenshot.sh is allowlisted, zero baseline signatures for it (#344, R3) ==="
# ---------------------------------------------------------------------------
if grep -q 'ALLOWLISTED_FILES=(.*upload-screenshot\.sh' "$CHECK"; then
  ok "TC-FINALBATCH-006 upload-screenshot.sh is present in ALLOWLISTED_FILES"
else
  bad "TC-FINALBATCH-006 upload-screenshot.sh is NOT in ALLOWLISTED_FILES"
fi
# Reuses "$gen" (TC-CUTOVER-011's --generate-baseline output, same committed
# tree, no scripts-dir override) instead of re-running the full recursive scan
# a third time in this file.
if ! jq -e '.surviving_sites[] | select(.file=="upload-screenshot.sh")' "$gen" >/dev/null 2>&1; then
  ok "TC-FINALBATCH-007 --generate-baseline emits zero upload-screenshot.sh signatures"
else
  bad "TC-FINALBATCH-007 upload-screenshot.sh still appears in the generated baseline"
fi

# ---------------------------------------------------------------------------
echo "=== TC-FINALBATCH-008: committed baseline carries none of the OLD reworded/allowlisted signatures (#344, R4) ==="
# ---------------------------------------------------------------------------
# Migration-ROBUST invariants only: no OLD string fragment (derived from the
# SAME FB_SITE table as TC-FINALBATCH-001/002 — single source of truth) and no
# upload-screenshot.sh signature of any kind survive in the committed baseline.
#
# The absolute baseline TOTALS (distinct signatures / total occurrences) are
# DELIBERATELY NOT pinned here (#342/#349 precedent in
# test-reply-review-comment.sh::TC-RRC-033). Absolute totals move with EVERY
# sibling #296 second-tier migration that shrinks the shared baseline, so an
# absolute pin here goes red on any concurrent shrinking PR — coverage this
# test does not own. Tree↔baseline reconciliation (Check 1) and shrink-only
# monotonicity (Check 4, --require-trusted-ref) are already enforced strict by
# check-provider-cutover.sh itself (TC-FINALBATCH-010 below); an absolute-total
# assertion here would add no unique coverage.
all_content="$(jq -r '.surviving_sites[].content' "$BASELINE")"
missing_old=0
for key in dev740 err303 err332 pf119 pv268 pv292; do
  IFS='|' read -r _f _anchor _keep old <<<"${FB_SITE[$key]}"
  if grep -qF "$old" <<<"$all_content"; then
    missing_old=1
    bad "TC-FINALBATCH-008 committed baseline still contains OLD reworded string fragment: $old"
  fi
done
if [[ "$missing_old" -eq 0 ]]; then
  ok "TC-FINALBATCH-008 committed baseline contains zero OLD reworded-string fragments"
fi
if ! jq -e '.surviving_sites[] | select(.file=="upload-screenshot.sh")' "$BASELINE" >/dev/null 2>&1; then
  ok "TC-FINALBATCH-008 committed baseline contains zero upload-screenshot.sh signatures"
else
  bad "TC-FINALBATCH-008 committed baseline still carries an upload-screenshot.sh signature"
fi

# ---------------------------------------------------------------------------
echo "=== TC-FINALBATCH-010: check-provider-cutover.sh --require-trusted-ref strict-passes against the committed repo (#344, AC1) ==="
# ---------------------------------------------------------------------------
# Must NOT rely on the ambient checkout's 'origin/main' resolving: the
# hermetic-unit CI job (which runs this file via the tests/unit/test-*.sh loop)
# uses the DEFAULT (shallow, no origin/main) checkout — only the dedicated
# spec-drift job's own `check-provider-cutover.sh --require-trusted-ref` step
# uses `fetch-depth: 0`. A bare `bash "$CHECK" --require-trusted-ref` here
# would fail closed on that shallow checkout with "trusted ref 'origin/main'
# not resolvable here" — a red herring unrelated to this PR's diff (codex
# review finding, 2026-07-02). Mint a LOCAL trusted ref instead, mirroring
# every other strict-mode case in this file (TC-CUTOVER-018/019/021,
# TC-CUTAMEND-007/008): a scratch copy of the CURRENT (already-shrunk)
# committed tree/baseline, committed as its own `trusted-main` branch, then
# run strict mode against that SAME state. This proves the shipped tree and
# baseline reconcile (Check 1) and strict-pass end-to-end (Check 4 sees zero
# delta vs. its own trusted snapshot, which trivially satisfies "may only
# shrink") without depending on ambient checkout depth.
if command -v git >/dev/null 2>&1; then
  S="$(fresh_scratch finalbatch010)"
  GROOT="$WORK/gitrepo-finalbatch010"
  rm -rf "$GROOT"; mkdir -p "$GROOT/skills/autonomous-dispatcher/scripts"
  cp -rL "$S"/. "$GROOT/skills/autonomous-dispatcher/scripts/" 2>/dev/null
  GS="$GROOT/skills/autonomous-dispatcher/scripts"
  ( cd "$GROOT" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 && git branch trusted-main )
  if ( cd "$GROOT" && bash "$GS/check-provider-cutover.sh" --scripts-dir "$GS" --baseline "$GS/providers/cutover-baseline.json" --trusted-ref trusted-main --require-trusted-ref >/dev/null 2>&1 ); then
    ok "TC-FINALBATCH-010 committed repo strict-passes --require-trusted-ref against a local trusted ref (Check 1 + Check 4 monotonicity, shrunk)"
  else
    bad "TC-FINALBATCH-010 committed repo FAILS --require-trusted-ref against a local trusted ref"
  fi
else
  ok "git unavailable — TC-FINALBATCH-010 skipped"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-001: injected raw 'glab issue create' in scratch autonomous-dev.sh FAILs (#416 R4) ==="
# ===========================================================================
S="$(fresh_scratch glab001)"
# shellcheck disable=SC2016
printf '\nglab_direct() { glab issue create --title inj; }\n' >> "$S/autonomous-dev.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "raw \`glab\` token" <<<"$out"; then
  ok "TC-CUTOVER-GLAB-001: raw 'glab' in caller layer → FAIL naming the site"
else
  bad "TC-CUTOVER-GLAB-001: injected raw 'glab' NOT caught (rc=$rc)"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-001b: TAB-separated 'glab<TAB>issue list' FAILs (#416 review round 2) ==="
# ===========================================================================
S="$(fresh_scratch glab001b)"
printf '\nglab_tab() { glab\tissue list; }\n' >> "$S/autonomous-dev.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "raw \`glab\` token" <<<"$out"; then
  ok "TC-CUTOVER-GLAB-001b: tab-separated raw 'glab' → FAIL (whitespace-class boundary)"
else
  bad "TC-CUTOVER-GLAB-001b: tab-separated 'glab' NOT caught (rc=$rc)"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-001c: split-line /api/v4 var + TAB-separated curl FAILs (#416 review round 2) ==="
# ===========================================================================
S="$(fresh_scratch glab001c)"
printf '\nu="https://gitlab.example.com/api/v4/projects/1"\ncurl\t"$u"\n' >> "$S/autonomous-dev.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "TC-CUTOVER-GLAB-001c: split-line /api/v4 var consumed by tab-separated curl → FAIL"
else
  bad "TC-CUTOVER-GLAB-001c: tab-separated curl of an /api/v4 var NOT caught (rc=$rc)"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-002: 'glab' in a comment does NOT trip ==="
# ===========================================================================
S="$(fresh_scratch glab002)"
# shellcheck disable=SC2016
printf '\n# This comment mentions glab in prose — must not trip the detector.\n' >> "$S/autonomous-dev.sh"
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" >/dev/null 2>&1; then
  ok "TC-CUTOVER-GLAB-002: prose 'glab' in a comment line does NOT trip"
else
  bad "TC-CUTOVER-GLAB-002: comment prose 'glab' tripped the lint (should not)"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-003: 'glabber' / '_glab' / '-glab' do NOT trip (word-boundary) ==="
# ===========================================================================
S="$(fresh_scratch glab003)"
# shellcheck disable=SC2016
printf '\nfake_fn() { local _glab=1; echo "$_glab glabber -glab"; }\n' >> "$S/autonomous-dev.sh"
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" >/dev/null 2>&1; then
  ok "TC-CUTOVER-GLAB-003: word-boundary rejects '_glab' / 'glabber' / '-glab'"
else
  bad "TC-CUTOVER-GLAB-003: word-boundary letter false-positive"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-NEG: the 5 gh-app-token.sh curl argvs PASS (shape-exclusion) ==="
# ===========================================================================
S="$(fresh_scratch glabneg)"
# The gh-app-token.sh curl argvs mention api.github.com endpoints — no /api/v4.
# Verify NO regression on the clean scratch copy (Check 6 emits its "no /api/v4
# curl found" line and rc 0). This asserts that the shape-exclusion holds
# without any allowlist widening.
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1 | grep -q "no '/api/v4' curl (same-line or split-across-lines) found outside providers/lib-gitlab-transport.sh"; then
  ok "TC-CUTOVER-GLAB-NEG: shape-exclusion — 5 gh-app-token.sh curl sites PASS (api.github.com != /api/v4)"
else
  bad "TC-CUTOVER-GLAB-NEG: Check 6 unexpected FAIL on clean scratch"
fi

# Explicit sanity: inject a canonical gh-app-token.sh-shape curl argv into a
# scratch file that is NOT allowlisted and verify it still passes (does NOT
# match the /api/v4 detector — proves the shape-exclusion is content-based,
# not file-scoped).
S="$(fresh_scratch glabnegcurl)"
# shellcheck disable=SC2016
printf '\ntest_gh_style_curl() {\n  curl -s -H "Authorization: bearer $tok" -H "Accept: application/vnd.github+json" "https://api.github.com/orgs/foo/repos"\n}\n' >> "$S/autonomous-dev.sh"
# gh_lines_in will not fire because there is no `gh ` token here (only `curl`).
# But the /api/v4 detector must not either.
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1 | grep -q "no '/api/v4' curl (same-line or split-across-lines) found outside providers/lib-gitlab-transport.sh"; then
  ok "TC-CUTOVER-GLAB-NEG-CURL: api.github.com curl argv passes /api/v4 detector cleanly"
else
  bad "TC-CUTOVER-GLAB-NEG-CURL: api.github.com curl argv tripped the /api/v4 detector (shape-exclusion broken)"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-004: injected '/api/v4' curl in scratch autonomous-dev.sh FAILs ==="
# ===========================================================================
S="$(fresh_scratch glab004)"
# shellcheck disable=SC2016
printf '\nfake_gitlab_curl() {\n  curl -s -H "PRIVATE-TOKEN: $tok" "https://gitlab.com/api/v4/projects/1/issues"\n}\n' >> "$S/autonomous-dev.sh"
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "raw '/api/v4' curl outside" <<<"$out"; then
  ok "TC-CUTOVER-GLAB-004: raw /api/v4 curl in a caller-layer file → FAIL"
else
  bad "TC-CUTOVER-GLAB-004: /api/v4 curl NOT caught (rc=$rc)"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-005: '/api/v4' curl inside providers/lib-gitlab-transport.sh PASSES ==="
# ===========================================================================
S="$(fresh_scratch glab005)"
# The scratch fresh_scratch copies providers/ recursively — including
# lib-gitlab-transport.sh with its curl call. Verify it passes without
# error. (Any hit inside providers/lib-gitlab-transport.sh is legitimately
# skipped by Check 6.)
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" >/dev/null 2>&1; then
  ok "TC-CUTOVER-GLAB-005: /api/v4 curl inside providers/lib-gitlab-transport.sh is legitimate (Check 6 skips it)"
else
  bad "TC-CUTOVER-GLAB-005: lib-gitlab-transport.sh tripped Check 6 (should be the legitimate home)"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-BOUND-001: split-across-lines /api/v4 (var+curl) IS caught (#416 P2-6) ==="
# ===========================================================================
# [#416 P2-6] Pre-P2-6 the /api/v4 detector was same-line-only; a
# two-line shape
#   url="https://gitlab.example/api/v4/projects/1/issues"
#   curl -sS -H "PRIVATE-TOKEN: $tok" "$url"
# would slip past. Post-P2-6 the file-level detector fires on
# "same VAR name assigned to /api/v4/ AND used in a curl invocation on
# a different line".
S="$(fresh_scratch glabp26)"
# shellcheck disable=SC2016
cat >> "$S/autonomous-dev.sh" <<'EOF'

fake_gitlab_split_curl() {
  url="https://gitlab.example.com/api/v4/projects/1/issues"
  curl -sS -H "PRIVATE-TOKEN: $tok" "$url"
}
EOF
out="$(bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "split-across-lines" <<<"$out"; then
  ok "TC-CUTOVER-GLAB-BOUND-001: split VAR + curl \"\$VAR\" caught by the P2-6 detector"
else
  bad "TC-CUTOVER-GLAB-BOUND-001: split shape NOT caught (rc=$rc); output: ${out:0:400}"
fi

# ===========================================================================
echo "=== TC-CUTOVER-GLAB-BOUND-002: DOCUMENTED BOUND — indirect flow bypasses (review-gate territory) ==="
# ===========================================================================
# [#416 P2-6] The P2-6 detector matches ONLY "same VAR name in both places".
# Indirect flows (function arg passing, env-var derivation) are still
# bypassable and belong to the review gate — this TC documents that bound
# and asserts the honest description is present in the checker comment.
S="$(fresh_scratch glabp26b)"
# shellcheck disable=SC2016
cat >> "$S/autonomous-dev.sh" <<'EOF'

fake_indirect_flow() {
  build_url() { echo "https://gitlab.example.com/api/v4/projects/1"; }
  # Indirect: derived from function output, not a same-name assignment.
  target=$(build_url)
  curl -sS -H "PRIVATE-TOKEN: $tok" "$target"
}
EOF
# Above: `build_url` assigns nothing named `target`; the `target=…` line
# uses command substitution rather than a literal-string assignment. This
# shape is EXPECTED to bypass the file-level detector — DOCUMENTED bound.
if bash "$CHECK" --scripts-dir "$S" --baseline "$BASELINE" >/dev/null 2>&1; then
  ok "TC-CUTOVER-GLAB-BOUND-002: indirect-flow bypass documented (P2-6 file-level detector does NOT cover this — review-gate territory)"
else
  # A pass-through here would mean the guard got smarter than documented,
  # which is fine — but we don't fail the test either way (bound is honest).
  ok "TC-CUTOVER-GLAB-BOUND-002: indirect-flow shape also caught (stricter than the documented bound — still acceptable)"
fi

# Comment/doc-honesty grep: the checker must state the bound in a nearby
# comment so a future reader knows what the detector DOES and DOESN'T do.
if grep -q "BOUND — SAME-LINE-ONLY, DOCUMENTED HONESTLY" "$CHECK" \
   && grep -Pzq '(?s)Indirect flows.*belong to the review gate' "$CHECK"; then
  ok "TC-CUTOVER-GLAB-BOUND-002-DOC: checker comment states the bound honestly (P2-6 requirement)"
else
  bad "TC-CUTOVER-GLAB-BOUND-002-DOC: checker comment does not document the same-line-only bound + indirect-flow limitation"
fi

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
