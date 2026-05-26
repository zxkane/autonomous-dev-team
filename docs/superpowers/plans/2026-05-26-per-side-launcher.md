# Per-Side `AGENT_LAUNCHER` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `AGENT_DEV_LAUNCHER` and `AGENT_REVIEW_LAUNCHER` operator knobs so dev and review wrappers can each have their own launcher prefix. Default to `AGENT_LAUNCHER` so existing deployments are byte-for-byte unchanged. Splits the single `[INV-37]` launcher guard into two per-side guards.

**Architecture:** lib-agent.sh init block gains two new variables defaulting to `${AGENT_LAUNCHER:-}` plus per-side argv tokenization mirroring the existing `AGENT_LAUNCHER` `eval` pattern. The single "both sides claude" guard from `[INV-37]` is replaced by two independent per-side guards. Each wrapper rebinds the existing `AGENT_LAUNCHER_ARGV` (the array `_run_with_timeout` already reads) to its side's array immediately after sourcing lib-agent.sh, paired with the existing `AGENT_CMD="$AGENT_DEV_CMD"` rebind. `run_agent` / `resume_agent` are unchanged — they continue reading `AGENT_LAUNCHER_ARGV[@]`.

**Tech Stack:** Bash 5.x, coreutils. No new runtime dependencies.

**Spec:** [`docs/pipeline/per-side-launcher.md`](../../pipeline/per-side-launcher.md) (committed in this branch).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `skills/autonomous-dispatcher/scripts/lib-agent.sh` | Modify | Add `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER` init + per-side argv tokenization. Replace single `[INV-37]` guard with two per-side guards. |
| `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` | Modify | Add `AGENT_LAUNCHER_ARGV=("${AGENT_DEV_LAUNCHER_ARGV[@]}")` immediately after the existing `AGENT_CMD="$AGENT_DEV_CMD"` line. |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | Modify | Symmetric: rebind to `AGENT_REVIEW_LAUNCHER_ARGV[@]`. |
| `skills/autonomous-dispatcher/scripts/autonomous.conf.example` | Modify | Add `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER` operator-facing comment block above the per-CLI blocks. |
| `tests/unit/test-lib-agent-per-side-launcher.sh` | Create | 10 test cases (PSL-S1..S10): defaults, fallback, per-side override, both set, per-side guard pass/fail, wrapper structural placement. |
| `tests/unit/test-lib-agent-per-side-cmd.sh` | Modify | Update PSC-S7/S8/S11 assertion needles from `AGENT_LAUNCHER` to `AGENT_REVIEW_LAUNCHER` / `AGENT_DEV_LAUNCHER` to match new per-side error messages. |
| `docs/pipeline/invariants.md` | Modify | Append `## INV-38: per-side AGENT_LAUNCHER precedence`. |

The spec doc and pipeline README index are already committed in this branch (commit `7212f39`); no further docs changes needed there.

---

## Pre-flight: Confirm Worktree

Active worktree for this work is `worktree-feat+per-side-launcher` at `/data/git/autonomous-dev-team/.claude/worktrees/feat+per-side-launcher`. All commits below assume the executor is in that worktree.

If you're not in the worktree, see `superpowers:using-git-worktrees`.

---

## Task 1: Add `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER` init + tokenization + per-side guards

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/lib-agent.sh` (insert after the existing `AGENT_LAUNCHER` block ~line 106; replace the single guard at lines 108-115)
- Test: `tests/unit/test-lib-agent-per-side-launcher.sh` (new file)

**Goal of this task:** Get the new init lines + per-side guards in lib-agent.sh, plus the behavioral test for them. After this task, `AGENT_LAUNCHER_ARGV` is still set the same way as before (for back-compat with `_run_with_timeout`), but two new per-side argv arrays are also available for the wrappers to rebind to in Tasks 2/3.

- [ ] **Step 1.1: Read lib-agent.sh lines 73-115 to confirm current state**

Run:
```bash
sed -n '73,115p' skills/autonomous-dispatcher/scripts/lib-agent.sh
```

Expected: see the existing `AGENT_LAUNCHER="${AGENT_LAUNCHER:-}"` at line ~82, the existing `eval` block tokenizing `AGENT_LAUNCHER_ARGV` at lines ~84-105, and the existing `[INV-37]` guard at lines ~108-115 with the form `if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then if [[ "$AGENT_DEV_CMD" != "claude" || "$AGENT_REVIEW_CMD" != "claude" ]]; then ... fi fi`.

- [ ] **Step 1.2: Create the test file with scaffolding**

Create `tests/unit/test-lib-agent-per-side-launcher.sh`:

```bash
#!/bin/bash
# test-lib-agent-per-side-launcher.sh — Unit tests for AGENT_DEV_LAUNCHER /
# AGENT_REVIEW_LAUNCHER per-side overrides (INV-38).
#
# Verifies:
#   - Defaults: both per-side ARGVs default to AGENT_LAUNCHER_ARGV
#   - Single-side override: only the overridden side changes
#   - Both-side override: each side runs its declared launcher
#   - Empty-string handling: :- treats explicit empty as unset
#   - Per-side guard: each side's launcher is gated on THAT side's CLI
#   - Wrapper structural placement: rebind lands within ≤5 / ≤6 lines
#     of `source lib-agent.sh` in autonomous-{dev,review}.sh
#
# Run: bash tests/unit/test-lib-agent-per-side-launcher.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
# DEV_WRAPPER / REVIEW_WRAPPER are used by PSL-S9 / PSL-S10 structural greps.
# shellcheck disable=SC2034
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
# shellcheck disable=SC2034
REVIEW_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

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

# resolve_argvs <agent_launcher> <agent_dev_launcher> <agent_review_launcher>
# Sources lib-agent.sh in a sandbox with the given env, prints the joined
# tokens of each ARGV array on a single line: "DEV=<...> REVIEW=<...>".
# Both per-side CMDs are forced to "claude" so the per-side guard does
# not fire (this helper is for resolution-order tests only; guard tests
# use launcher_guard).
resolve_argvs() {
  local _al="$1" _adl="$2" _arl="$3"
  AGENT_LAUNCHER="$_al" \
  AGENT_DEV_LAUNCHER="$_adl" \
  AGENT_REVIEW_LAUNCHER="$_arl" \
  AGENT_CMD="claude" \
  AGENT_DEV_CMD="claude" \
  AGENT_REVIEW_CMD="claude" \
  bash -c '
    unset AUTONOMOUS_CONF
    source "'"$LIB"'" 2>/dev/null
    printf "DEV=%s REVIEW=%s\n" \
      "${AGENT_DEV_LAUNCHER_ARGV[*]:-}" \
      "${AGENT_REVIEW_LAUNCHER_ARGV[*]:-}"
  '
}

# launcher_guard <agent_launcher> <agent_dev_launcher> <agent_review_launcher> \
#                <agent_dev_cmd> <agent_review_cmd>
# Sources lib-agent.sh and emits "RC=<n>" plus stderr. Used by PSL-S6..S8.
launcher_guard() {
  local _al="$1" _adl="$2" _arl="$3" _adc="$4" _arc="$5"
  AGENT_LAUNCHER="$_al" \
  AGENT_DEV_LAUNCHER="$_adl" \
  AGENT_REVIEW_LAUNCHER="$_arl" \
  AGENT_CMD="claude" \
  AGENT_DEV_CMD="$_adc" \
  AGENT_REVIEW_CMD="$_arc" \
  bash -c '
    unset AUTONOMOUS_CONF
    source "'"$LIB"'"
    echo "RC=$?"
  ' 2>&1
}

echo "=== test-lib-agent-per-side-launcher.sh — AGENT_DEV/REVIEW_LAUNCHER (INV-38) ==="

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 1.3: Make executable + run scaffold**

Run:
```bash
chmod +x tests/unit/test-lib-agent-per-side-launcher.sh
bash tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: scaffold prints title and exits 0 (`PASS: 0 FAIL: 0`). Helpers `resolve_argvs` / `launcher_guard` defined but not exercised yet.

- [ ] **Step 1.4: Add PSL-S1 + PSL-S2 + PSL-S3 + PSL-S4 + PSL-S5 (resolution order)**

Append to `tests/unit/test-lib-agent-per-side-launcher.sh` *before* the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S1: default — neither override + AGENT_LAUNCHER unset → both empty ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "" "" "")
assert_eq "all unset → both ARGVs empty" "DEV= REVIEW=" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S2: back-compat — AGENT_LAUNCHER set, no per-side → both default to it ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "cc" "" "")
assert_eq "AGENT_LAUNCHER='cc' → DEV+REVIEW both 'cc'" "DEV=cc REVIEW=cc" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S3: only AGENT_DEV_LAUNCHER → DEV=override, REVIEW=AGENT_LAUNCHER (empty) ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "" "cc" "")
assert_eq "AGENT_DEV_LAUNCHER='cc' alone → DEV=cc, REVIEW empty" \
  "DEV=cc REVIEW=" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S4: only AGENT_REVIEW_LAUNCHER → REVIEW=override, DEV empty ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "" "" "wrap")
assert_eq "AGENT_REVIEW_LAUNCHER='wrap' alone → DEV empty, REVIEW=wrap" \
  "DEV= REVIEW=wrap" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S5: both set, different values → each side gets its declared launcher ==="
# ---------------------------------------------------------------------------
out=$(resolve_argvs "default-launcher" "cc" "wrap")
assert_eq "DEV=cc, REVIEW=wrap, AGENT_LAUNCHER ignored on both sides" \
  "DEV=cc REVIEW=wrap" "$out"
```

- [ ] **Step 1.5: Run — verify PSL-S1..S5 FAIL (vars don't exist yet)**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: 5 failures. The `printf "DEV=%s REVIEW=%s"` with `${AGENT_DEV_LAUNCHER_ARGV[*]:-}` prints `DEV= REVIEW=` because the arrays don't exist yet, so PSL-S2..S5 fail with mismatched expected. PSL-S1 happens to PASS coincidentally (both expected and actual are empty).

- [ ] **Step 1.6: Add per-side init + tokenization to lib-agent.sh**

Find the existing `AGENT_LAUNCHER` `eval` block (the `if [[ -n "$AGENT_LAUNCHER" ]]; then ... fi` block ending around line 106). Insert the following block immediately after that closing `fi` (still BEFORE the existing `[INV-37]` guard that starts at "# AGENT_LAUNCHER is only supported when both per-side CLIs are claude"):

```bash
# Per-side AGENT_LAUNCHER overrides (INV-38). Default to AGENT_LAUNCHER
# so existing single-launcher deployments are byte-for-byte unchanged.
# autonomous-dev.sh and autonomous-review.sh each rebind
# AGENT_LAUNCHER_ARGV to their side's array right after sourcing this
# file, so run_agent / resume_agent continue reading AGENT_LAUNCHER_ARGV
# without signature changes. See docs/pipeline/per-side-launcher.md.
AGENT_DEV_LAUNCHER="${AGENT_DEV_LAUNCHER:-$AGENT_LAUNCHER}"
AGENT_REVIEW_LAUNCHER="${AGENT_REVIEW_LAUNCHER:-$AGENT_LAUNCHER}"
declare -a AGENT_DEV_LAUNCHER_ARGV=()
declare -a AGENT_REVIEW_LAUNCHER_ARGV=()

# Tokenize AGENT_DEV_LAUNCHER (mirrors the AGENT_LAUNCHER eval block above).
if [[ -n "$AGENT_DEV_LAUNCHER" ]]; then
  _orig_dev_launcher="$AGENT_DEV_LAUNCHER"
  if ! eval "AGENT_DEV_LAUNCHER_ARGV=($AGENT_DEV_LAUNCHER)" 2>/dev/null; then
    AGENT_DEV_LAUNCHER=""
    AGENT_DEV_LAUNCHER_ARGV=()
    echo "[lib-agent] ERROR: AGENT_DEV_LAUNCHER failed to parse as a shell argv list. Value: ${_orig_dev_launcher}" >&2
    unset _orig_dev_launcher
    return 1 2>/dev/null || exit 1
  fi
  if [[ ${#AGENT_DEV_LAUNCHER_ARGV[@]} -eq 0 ]]; then
    echo "[lib-agent] WARN: AGENT_DEV_LAUNCHER non-empty but tokenized to zero argv elements. Treating as unset. Value: ${_orig_dev_launcher}" >&2
  fi
  unset _orig_dev_launcher
fi

# Tokenize AGENT_REVIEW_LAUNCHER (same shape as AGENT_DEV_LAUNCHER above).
if [[ -n "$AGENT_REVIEW_LAUNCHER" ]]; then
  _orig_review_launcher="$AGENT_REVIEW_LAUNCHER"
  if ! eval "AGENT_REVIEW_LAUNCHER_ARGV=($AGENT_REVIEW_LAUNCHER)" 2>/dev/null; then
    AGENT_REVIEW_LAUNCHER=""
    AGENT_REVIEW_LAUNCHER_ARGV=()
    echo "[lib-agent] ERROR: AGENT_REVIEW_LAUNCHER failed to parse as a shell argv list. Value: ${_orig_review_launcher}" >&2
    unset _orig_review_launcher
    return 1 2>/dev/null || exit 1
  fi
  if [[ ${#AGENT_REVIEW_LAUNCHER_ARGV[@]} -eq 0 ]]; then
    echo "[lib-agent] WARN: AGENT_REVIEW_LAUNCHER non-empty but tokenized to zero argv elements. Treating as unset. Value: ${_orig_review_launcher}" >&2
  fi
  unset _orig_review_launcher
fi

```

(Note the trailing blank line — preserved before the existing guard block.)

- [ ] **Step 1.7: Run — verify PSL-S1..S5 PASS**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: `PASS: 5 FAIL: 0`. The per-side ARGVs are now defined and resolution order matches.

- [ ] **Step 1.8: Replace the single `[INV-37]` guard with two per-side guards**

Find the existing guard block (the one that starts with the comment `# AGENT_LAUNCHER is only supported when both per-side CLIs are claude` and ends with a closing `fi`). Replace the ENTIRE block with:

```bash
# AGENT_LAUNCHER is gated per-side (INV-38). Each side's launcher is
# checked against THAT side's AGENT_CMD: AGENT_DEV_LAUNCHER non-empty
# requires AGENT_DEV_CMD=claude; AGENT_REVIEW_LAUNCHER non-empty
# requires AGENT_REVIEW_CMD=claude. Side that has no launcher is
# unconstrained. The canonical launcher (a `cc` shell function ending
# in `$CLAUDE_CMD "$@"`) is hardcoded to invoke claude, so pointing it
# at codex/kiro/opencode/agy would produce `claude codex ...` and fail.
# Refuse the combination rather than crashing 5 seconds into the next
# dispatch. The check reads AGENT_DEV_CMD / AGENT_REVIEW_CMD directly
# (not via AGENT_CMD) because the wrapper-level override fires AFTER
# this guard — see docs/pipeline/per-side-launcher.md §Resolution order.
if [[ ${#AGENT_DEV_LAUNCHER_ARGV[@]} -gt 0 && "$AGENT_DEV_CMD" != "claude" ]]; then
  echo "[lib-agent] ERROR: AGENT_DEV_LAUNCHER is only supported with AGENT_DEV_CMD=claude (got AGENT_DEV_CMD=${AGENT_DEV_CMD}). Either unset AGENT_DEV_LAUNCHER (or AGENT_LAUNCHER if it's the source of the dev-side default) or write a launcher tailored to your CLI." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ${#AGENT_REVIEW_LAUNCHER_ARGV[@]} -gt 0 && "$AGENT_REVIEW_CMD" != "claude" ]]; then
  echo "[lib-agent] ERROR: AGENT_REVIEW_LAUNCHER is only supported with AGENT_REVIEW_CMD=claude (got AGENT_REVIEW_CMD=${AGENT_REVIEW_CMD}). Either unset AGENT_REVIEW_LAUNCHER (or AGENT_LAUNCHER if it's the source of the review-side default) or write a launcher tailored to your CLI." >&2
  return 1 2>/dev/null || exit 1
fi
```

- [ ] **Step 1.9: Add PSL-S6 + PSL-S7 + PSL-S8 (per-side guard cases)**

Append to `tests/unit/test-lib-agent-per-side-launcher.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S6: AGENT_DEV_LAUNCHER + AGENT_DEV_CMD=claude → guard pass ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "" "cc" "" "claude" "claude")
assert_contains "RC=0 (no guard rejection)" "RC=0" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S7: AGENT_DEV_LAUNCHER + AGENT_DEV_CMD=kiro → guard fails per-side ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "" "cc" "" "kiro" "claude")
assert_contains "guard error names AGENT_DEV_LAUNCHER" "AGENT_DEV_LAUNCHER" "$out"
assert_contains "guard error names AGENT_DEV_CMD=kiro" "AGENT_DEV_CMD=kiro" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S8: AGENT_REVIEW_LAUNCHER + AGENT_REVIEW_CMD=agy → guard fails per-side ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "" "" "wrap" "claude" "agy")
assert_contains "guard error names AGENT_REVIEW_LAUNCHER" "AGENT_REVIEW_LAUNCHER" "$out"
assert_contains "guard error names AGENT_REVIEW_CMD=agy" "AGENT_REVIEW_CMD=agy" "$out"
```

- [ ] **Step 1.10: Run — verify PSL-S6/S7/S8 PASS**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: `PASS: 10 FAIL: 0` (5 from S1..S5 + 1 from S6 + 2 from S7 + 2 from S8).

- [ ] **Step 1.11: Update PSC-S7 / PSC-S8 / PSC-S11 in test-lib-agent-per-side-cmd.sh**

The PR #156 launcher-guard tests fire on the same logical condition but the new error messages mention the per-side launcher name. Open `tests/unit/test-lib-agent-per-side-cmd.sh` and update three assertions.

Find PSC-S7 (assertion needle `AGENT_REVIEW_CMD=agy`):

```bash
out=$(launcher_guard "claude" "agy")
assert_contains "guard error mentions AGENT_REVIEW_CMD=agy" "AGENT_REVIEW_CMD=agy" "$out"
assert_contains "guard error names both vars" "AGENT_DEV_CMD" "$out"
```

Replace with:

```bash
out=$(launcher_guard "claude" "agy")
assert_contains "guard error mentions AGENT_REVIEW_CMD=agy" "AGENT_REVIEW_CMD=agy" "$out"
assert_contains "guard error mentions AGENT_REVIEW_LAUNCHER (per-side, INV-38)" "AGENT_REVIEW_LAUNCHER" "$out"
```

Find PSC-S8 (assertion `AGENT_DEV_CMD=codex`):

```bash
out=$(launcher_guard "codex" "claude")
assert_contains "guard error mentions AGENT_DEV_CMD=codex" "AGENT_DEV_CMD=codex" "$out"
```

Replace with:

```bash
out=$(launcher_guard "codex" "claude")
assert_contains "guard error mentions AGENT_DEV_CMD=codex" "AGENT_DEV_CMD=codex" "$out"
assert_contains "guard error mentions AGENT_DEV_LAUNCHER (per-side, INV-38)" "AGENT_DEV_LAUNCHER" "$out"
```

Find PSC-S11 (both sides non-claude):

```bash
out=$(launcher_guard "codex" "agy")
assert_contains "guard error mentions both non-claude values" "AGENT_DEV_CMD=codex" "$out"
assert_contains "guard error mentions review side too" "AGENT_REVIEW_CMD=agy" "$out"
```

Replace with:

```bash
out=$(launcher_guard "codex" "agy")
# Post-INV-38: per-side guards fire independently. The dev-side guard
# fires first and aborts source; we only see the dev-side error.
# AGENT_REVIEW_LAUNCHER's guard never gets to run because of `return 1`.
assert_contains "guard error mentions AGENT_DEV_CMD=codex (dev-side fires first)" \
  "AGENT_DEV_CMD=codex" "$out"
assert_contains "guard error names AGENT_DEV_LAUNCHER (per-side, INV-38)" \
  "AGENT_DEV_LAUNCHER" "$out"
```

- [ ] **Step 1.12: Run PSC tests — verify they still pass post-update**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: `FAIL: 0`. The PSC tests' per-side-CMD assertions are unchanged; only the launcher-guard ones got updated needles.

- [ ] **Step 1.13: shellcheck**

Run:
```bash
shellcheck -S error skills/autonomous-dispatcher/scripts/lib-agent.sh tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: exit 0, clean.

- [ ] **Step 1.14: Run all lib-agent tests (regression sweep)**

Run:
```bash
for t in tests/unit/test-lib-agent-*.sh; do
  bash "$t" >/dev/null 2>&1 && echo "PASS: $(basename $t)" || echo "FAIL: $(basename $t)"
done
```

Expected: every line PASS. The new vars default to `AGENT_LAUNCHER` so all peer test-lib-agent-* tests see byte-identical behavior.

- [ ] **Step 1.15: Commit Task 1**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/lib-agent.sh \
  tests/unit/test-lib-agent-per-side-launcher.sh \
  tests/unit/test-lib-agent-per-side-cmd.sh
git commit -m "feat(lib-agent): add AGENT_DEV_LAUNCHER / AGENT_REVIEW_LAUNCHER (INV-38)

Adds per-side AGENT_LAUNCHER overrides. Both default to AGENT_LAUNCHER
so existing deployments are byte-for-byte unchanged. The single
'both sides claude' guard from INV-37 is replaced by two independent
per-side guards: each side's launcher is gated on THAT side's
AGENT_CMD. Strictly more permissive than the INV-37 form.

Tokenization mirrors the existing AGENT_LAUNCHER eval block (same
trust model, same WARN-on-empty-tokenize, same ERROR-on-parse-failure).

Tests:
  - new test-lib-agent-per-side-launcher.sh — PSL-S1..S8 (resolution
    + per-side guard pass/fail).
  - update test-lib-agent-per-side-cmd.sh PSC-S7/S8/S11 needles to
    match the new per-side error messages.

PSL-S9/S10 (wrapper structural placement) land in Tasks 2 and 3.
INV-38 entry lands in Task 5."
```

---

## Task 2: Add `AGENT_LAUNCHER_ARGV` rebind to `autonomous-dev.sh` + PSL-S9

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` (insert one line after the existing `AGENT_CMD="$AGENT_DEV_CMD"` from PR #156 at line ~26)
- Test: `tests/unit/test-lib-agent-per-side-launcher.sh` (append PSL-S9)

- [ ] **Step 2.1: Add PSL-S9 test (structural)**

Append to `tests/unit/test-lib-agent-per-side-launcher.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S9: autonomous-dev.sh structural placement ==="
# ---------------------------------------------------------------------------
# Match: source "${SCRIPT_DIR}/lib-agent.sh" followed (within 5 lines —
# allows the existing 3-line WHY comment + AGENT_CMD rebind from PR #156
# + the new AGENT_LAUNCHER_ARGV rebind) by
# AGENT_LAUNCHER_ARGV=("${AGENT_DEV_LAUNCHER_ARGV[@]}").
hit=$(awk '
  /source "\$\{SCRIPT_DIR\}\/lib-agent\.sh"/ {
    found_source = NR
    next
  }
  found_source && NR <= found_source + 5 {
    if ($0 ~ /^AGENT_LAUNCHER_ARGV=\("\$\{AGENT_DEV_LAUNCHER_ARGV\[@\]\}"\)/) {
      print "MATCH"
      exit
    }
  }
' "$DEV_WRAPPER")

assert_eq "autonomous-dev.sh: AGENT_LAUNCHER_ARGV=(\${AGENT_DEV_LAUNCHER_ARGV[@]}) within 5 lines of source lib-agent.sh" \
  "MATCH" "$hit"
```

- [ ] **Step 2.2: Run — verify PSL-S9 FAILS**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: 1 new failure (PSL-S9). Other 10 still pass.

- [ ] **Step 2.3: Read current autonomous-dev.sh lines 21-28**

Run:
```bash
sed -n '21,28p' skills/autonomous-dispatcher/scripts/autonomous-dev.sh
```

Expected:
```
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${SCRIPT_DIR}/lib-agent.sh"
# Per-side AGENT_CMD override (INV-37). Empty-string fallback already
# applied inside lib-agent.sh; this just rebinds AGENT_CMD so the case
# statements in run_agent / resume_agent dispatch to the dev-side CLI.
AGENT_CMD="$AGENT_DEV_CMD"
source "${SCRIPT_DIR}/lib-auth.sh"
```

- [ ] **Step 2.4: Insert the AGENT_LAUNCHER_ARGV rebind**

Use the Edit tool. Change:

```
AGENT_CMD="$AGENT_DEV_CMD"
source "${SCRIPT_DIR}/lib-auth.sh"
```

to:

```
AGENT_CMD="$AGENT_DEV_CMD"
# Per-side AGENT_LAUNCHER override (INV-38). Rebinds the active
# AGENT_LAUNCHER_ARGV that _run_with_timeout reads to the dev-side
# array. Default fallback (operator hasn't set AGENT_DEV_LAUNCHER) is
# byte-identical to AGENT_LAUNCHER thanks to the :- in lib-agent.sh.
AGENT_LAUNCHER_ARGV=("${AGENT_DEV_LAUNCHER_ARGV[@]}")
source "${SCRIPT_DIR}/lib-auth.sh"
```

- [ ] **Step 2.5: Run — verify PSL-S9 PASSES + everything else still green**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: `FAIL: 0`.

- [ ] **Step 2.6: shellcheck**

Run:
```bash
shellcheck -S error skills/autonomous-dispatcher/scripts/autonomous-dev.sh
```

Expected: exit 0.

- [ ] **Step 2.7: Commit Task 2**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/autonomous-dev.sh tests/unit/test-lib-agent-per-side-launcher.sh
git commit -m "feat(autonomous-dev): rebind AGENT_LAUNCHER_ARGV to dev-side after lib-agent source

Adds AGENT_LAUNCHER_ARGV=(\"\${AGENT_DEV_LAUNCHER_ARGV[@]}\") immediately
after the existing AGENT_CMD=\$AGENT_DEV_CMD line so _run_with_timeout
picks up the dev-side launcher when the operator has set per-side
overrides.

Default behavior unchanged because AGENT_DEV_LAUNCHER defaults to
AGENT_LAUNCHER inside lib-agent.sh.

Test: PSL-S9 asserts the rebind line lands within 5 lines of source
lib-agent.sh (3-line WHY + AGENT_CMD rebind + new LAUNCHER rebind)."
```

---

## Task 3: Add `AGENT_LAUNCHER_ARGV` rebind to `autonomous-review.sh` + PSL-S10

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/autonomous-review.sh` (insert one line after the existing `AGENT_CMD="$AGENT_REVIEW_CMD"` line)
- Test: `tests/unit/test-lib-agent-per-side-launcher.sh` (append PSL-S10)

- [ ] **Step 3.1: Add PSL-S10 test (structural)**

Append to `tests/unit/test-lib-agent-per-side-launcher.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSL-S10: autonomous-review.sh structural placement ==="
# ---------------------------------------------------------------------------
# Match: within 6 lines of source — 4-line WHY comment + AGENT_CMD
# rebind + new AGENT_LAUNCHER_ARGV rebind.
hit=$(awk '
  /source "\$\{SCRIPT_DIR\}\/lib-agent\.sh"/ {
    found_source = NR
    next
  }
  found_source && NR <= found_source + 6 {
    if ($0 ~ /^AGENT_LAUNCHER_ARGV=\("\$\{AGENT_REVIEW_LAUNCHER_ARGV\[@\]\}"\)/) {
      print "MATCH"
      exit
    }
  }
' "$REVIEW_WRAPPER")

assert_eq "autonomous-review.sh: AGENT_LAUNCHER_ARGV=(\${AGENT_REVIEW_LAUNCHER_ARGV[@]}) within 6 lines of source lib-agent.sh" \
  "MATCH" "$hit"
```

- [ ] **Step 3.2: Run — verify PSL-S10 FAILS**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: 1 new failure (PSL-S10).

- [ ] **Step 3.3: Read current autonomous-review.sh lines 21-32**

Run:
```bash
sed -n '21,32p' skills/autonomous-dispatcher/scripts/autonomous-review.sh
```

Expected:
```
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${SCRIPT_DIR}/lib-agent.sh"
# Per-side AGENT_CMD override (INV-37). See autonomous-dev.sh for the
# matching dev-side override. Together they let one project run dev
# and review on different agent CLIs (e.g. claude for dev, agy for
# review). Default (no operator override) is byte-for-byte unchanged.
AGENT_CMD="$AGENT_REVIEW_CMD"
source "${SCRIPT_DIR}/lib-auth.sh"
# shellcheck source=lib-review-bots.sh
source "${SCRIPT_DIR}/lib-review-bots.sh"
# shellcheck source=lib-review-verdict.sh
source "${SCRIPT_DIR}/lib-review-verdict.sh"
```

- [ ] **Step 3.4: Insert the AGENT_LAUNCHER_ARGV rebind**

Use the Edit tool. Change:

```
AGENT_CMD="$AGENT_REVIEW_CMD"
source "${SCRIPT_DIR}/lib-auth.sh"
```

to:

```
AGENT_CMD="$AGENT_REVIEW_CMD"
# Per-side AGENT_LAUNCHER override (INV-38). Mirrors the dev-side
# rebind in autonomous-dev.sh. Default (operator hasn't set
# AGENT_REVIEW_LAUNCHER) is byte-identical to AGENT_LAUNCHER.
AGENT_LAUNCHER_ARGV=("${AGENT_REVIEW_LAUNCHER_ARGV[@]}")
source "${SCRIPT_DIR}/lib-auth.sh"
```

- [ ] **Step 3.5: Run — verify PSL-S10 PASSES**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: `FAIL: 0` (12 assertions total).

- [ ] **Step 3.6: shellcheck**

Run:
```bash
shellcheck -S error skills/autonomous-dispatcher/scripts/autonomous-review.sh
```

Expected: exit 0.

- [ ] **Step 3.7: Commit Task 3**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/autonomous-review.sh tests/unit/test-lib-agent-per-side-launcher.sh
git commit -m "feat(autonomous-review): rebind AGENT_LAUNCHER_ARGV to review-side after lib-agent source

Mirrors the dev-side change. Adds AGENT_LAUNCHER_ARGV=(\"\${AGENT_REVIEW_LAUNCHER_ARGV[@]}\")
immediately after the existing AGENT_CMD=\$AGENT_REVIEW_CMD line so
_run_with_timeout picks up the review-side launcher when the operator
has set per-side overrides.

Test: PSL-S10 asserts the rebind line lands within 6 lines of source
lib-agent.sh (4-line WHY + AGENT_CMD rebind + new LAUNCHER rebind)."
```

---

## Task 4: Document `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER` in `autonomous.conf.example`

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/autonomous.conf.example` (insert ~25 lines after the existing AGENT_LAUNCHER block, before the AGENT_DEV_EXTRA_ARGS line)

- [ ] **Step 4.1: Locate the insertion point**

Run:
```bash
grep -nE "^AGENT_LAUNCHER=|^AGENT_DEV_EXTRA_ARGS=" skills/autonomous-dispatcher/scripts/autonomous.conf.example
```

Expected: two lines like `^AGENT_LAUNCHER="..."` (or commented `^# AGENT_LAUNCHER=`) and `^AGENT_DEV_EXTRA_ARGS=""`. The new comment block goes between them.

- [ ] **Step 4.2: Find the exact insertion anchor**

Run:
```bash
grep -nE "^AGENT_DEV_EXTRA_ARGS=" skills/autonomous-dispatcher/scripts/autonomous.conf.example
```

Expected: a single line, likely `AGENT_DEV_EXTRA_ARGS=""` near line 214. The new block goes immediately ABOVE this line.

- [ ] **Step 4.3: Insert the operator-facing comment block**

Use the Edit tool. Change:

```
AGENT_DEV_EXTRA_ARGS=""
AGENT_REVIEW_EXTRA_ARGS=""
```

to:

```
# AGENT_DEV_LAUNCHER / AGENT_REVIEW_LAUNCHER: per-side override of
# AGENT_LAUNCHER (INV-38). Default to AGENT_LAUNCHER when unset/empty
# so existing single-launcher deployments are unaffected. Set them
# when dev and review run on different CLIs and need different
# launcher treatment — for example, claude for dev with a Bedrock-
# bridge launcher (cc), kiro for review with no launcher:
#
#   AGENT_CMD="claude"
#   AGENT_DEV_LAUNCHER='bash -c '\''source ~/.bash_aliases && cc "$@"'\'' --'
#   AGENT_REVIEW_CMD="kiro"
#   AGENT_DEV_EXTRA_ARGS="--trust-all-tools"   # see kiro block
#
# Per-side guard (INV-38): each side's launcher is gated against
# THAT side's AGENT_CMD. AGENT_DEV_LAUNCHER non-empty requires
# AGENT_DEV_CMD=claude; AGENT_REVIEW_LAUNCHER non-empty requires
# AGENT_REVIEW_CMD=claude. Side that has no launcher is unconstrained.
# AGENT_DEV_LAUNCHER=""
# AGENT_REVIEW_LAUNCHER=""

AGENT_DEV_EXTRA_ARGS=""
AGENT_REVIEW_EXTRA_ARGS=""
```

- [ ] **Step 4.4: Verify the conf still parses as bash**

Run:
```bash
bash -n skills/autonomous-dispatcher/scripts/autonomous.conf.example
```

Expected: exit 0 (no output).

- [ ] **Step 4.5: Commit Task 4**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/autonomous.conf.example
git commit -m "docs(conf): document AGENT_DEV_LAUNCHER / AGENT_REVIEW_LAUNCHER (INV-38)

Adds an operator-facing comment block above the EXTRA_ARGS defaults.
Includes a worked example for the 'claude-dev with cc bridge / kiro-
review without launcher' deployment pattern (the motivating use case)
and the per-side guard reminder."
```

---

## Task 5: Add INV-38 to `docs/pipeline/invariants.md`

**Files:**
- Modify: `docs/pipeline/invariants.md` (append after INV-37, before the `## Adding a new invariant` section)

- [ ] **Step 5.1: Locate the insertion point**

Run:
```bash
grep -nE "^## INV-37|^## Adding a new invariant" docs/pipeline/invariants.md
```

Expected: two line numbers. INV-37 starts at ~981; "Adding a new invariant" starts somewhere after.

- [ ] **Step 5.2: Insert the INV-38 block**

Use the Edit tool. Find the lines (the closing of INV-37's Cross-references block, immediately before `## Adding a new invariant`):

```
- [`docs/pipeline/agy-cli-support.md`](agy-cli-support.md) — agy is the most likely review-side CLI today and the motivating example.

## Adding a new invariant
```

Replace with:

```
- [`docs/pipeline/agy-cli-support.md`](agy-cli-support.md) — agy is the most likely review-side CLI today and the motivating example.
- [INV-38](#inv-38-per-side-agent_launcher-precedence) — per-side `AGENT_LAUNCHER` (the launcher-side analogue, replaces this invariant's single guard with two per-side guards).

## INV-38: per-side AGENT_LAUNCHER precedence

**Rule**: `lib-agent.sh` exposes `AGENT_DEV_LAUNCHER` and `AGENT_REVIEW_LAUNCHER` as side-specific overrides of `AGENT_LAUNCHER`. Both default to `${AGENT_LAUNCHER:-}` so existing deployments are byte-for-byte unchanged. Each side's tokenized argv array is gated independently: `AGENT_DEV_LAUNCHER` non-empty requires `AGENT_DEV_CMD=claude`; `AGENT_REVIEW_LAUNCHER` non-empty requires `AGENT_REVIEW_CMD=claude`. The two guards replace the single `[INV-37]` guard. Each wrapper rebinds the existing `AGENT_LAUNCHER_ARGV` (the array `_run_with_timeout` reads) to its side's array immediately after sourcing `lib-agent.sh` — paired with the existing `AGENT_CMD` rebind from `[INV-37]`. After both rebinds, `run_agent` / `resume_agent` continue reading `AGENT_LAUNCHER_ARGV[@]` without signature changes.

**Why**: Pairs with `[INV-37]` (per-side `AGENT_CMD`). Without per-side launchers, a project that wants to run dev on claude with a Bedrock-bridge launcher (e.g. `cc`) AND review on a non-claude CLI (e.g. kiro) is blocked by `[INV-37]`'s "both sides claude" guard. The `cc` bridge is claude-specific (sets `ANTHROPIC_DEFAULT_*`, `AWS_PROFILE`, `CLAUDE_CODE_USE_BEDROCK=1`) and would harm a non-claude CLI even if applied. Per-side launchers let each side use the launcher that fits its CLI. Strictly more permissive than the `[INV-37]` form: every operator config that passed before still passes; the freed configurations are exactly those where one side has a launcher and the other side runs a non-claude CLI without one.

**Producer**: `lib-agent.sh` init block — the two `${VAR:-$AGENT_LAUNCHER}` assignments + per-side `eval` tokenization mirroring the existing `AGENT_LAUNCHER` block.

**Consumer**: `autonomous-dev.sh` and `autonomous-review.sh` entry blocks rebind `AGENT_LAUNCHER_ARGV` to `AGENT_{DEV,REVIEW}_LAUNCHER_ARGV` immediately after sourcing `lib-agent.sh`. Downstream `_run_with_timeout` reads the rebound `AGENT_LAUNCHER_ARGV[@]` unchanged.

**Test**: `tests/unit/test-lib-agent-per-side-launcher.sh` PSL-S1 (defaults), PSL-S2 (back-compat AGENT_LAUNCHER fallback), PSL-S3/S4 (single-side override), PSL-S5 (both set), PSL-S6 (per-side guard pass), PSL-S7/S8 (per-side guard fails with side-specific error message), PSL-S9/S10 (wrapper structural placement). PSC-S7/S8/S11 in `test-lib-agent-per-side-cmd.sh` updated to match the new per-side error messages.

**Cross-references**:
- [`docs/pipeline/per-side-launcher.md`](per-side-launcher.md) — full spec.
- [INV-37](#inv-37-per-side-agent_cmd-precedence) — per-side `AGENT_CMD`. INV-38 builds on it: the launcher guard now keys on per-side CLIs.
- [INV-31](#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) — operator-tunable flags live in `autonomous.conf`. The new vars follow that contract.
- [INV-13](#inv-13-wall-clock-cap-on-agent-invocations) — wall-clock cap. Unaffected: each side's launcher still runs inside `_run_with_timeout` exactly as before.

## Adding a new invariant
```

- [ ] **Step 5.3: Verify the link from per-side-launcher.md resolves**

Run:
```bash
grep -n "inv-38-per-side-agent_launcher-precedence" docs/pipeline/invariants.md
```

Expected: returns the auto-generated GFM anchor for the new heading. If 0 hits, the heading text and the anchor in the spec don't match — fix one.

- [ ] **Step 5.4: Commit Task 5**

Run:
```bash
git add docs/pipeline/invariants.md
git commit -m "docs(pipeline): record INV-38 per-side AGENT_LAUNCHER precedence

INV-38 documents the AGENT_DEV_LAUNCHER / AGENT_REVIEW_LAUNCHER
precedence rule that pairs with INV-37 to allow mixed-CLI deployments
where only one side has a launcher.

Anchored to docs/pipeline/per-side-launcher.md (already on this branch
with cross-reference [INV-38] resolved by this commit). INV-37
cross-references list updated to include INV-38."
```

---

## Task 6: Final regression + push + open PR

- [ ] **Step 6.1: Run the full unit-test suite**

Run:
```bash
failed=0
for t in tests/unit/test-*.sh; do
  if ! bash "$t" >/dev/null 2>&1; then
    echo "FAILED: $t"
    failed=1
  fi
done
[[ $failed -eq 0 ]] && echo "ALL UNIT TESTS PASS" || echo "REGRESSIONS PRESENT"
```

Expected: `ALL UNIT TESTS PASS`. If `test-pid-guard.sh` or `test-kill-before-spawn.sh` flake (known timing-sensitive — see PRs #155/#156 final-regression history), retry once. Real failures need investigation.

- [ ] **Step 6.2: shellcheck the modified scripts**

Run:
```bash
shellcheck -S error \
  skills/autonomous-dispatcher/scripts/lib-agent.sh \
  skills/autonomous-dispatcher/scripts/autonomous-dev.sh \
  skills/autonomous-dispatcher/scripts/autonomous-review.sh \
  tests/unit/test-lib-agent-per-side-launcher.sh
```

Expected: exit 0.

- [ ] **Step 6.3: Run pr-review-toolkit and address findings**

Invoke `/pr-review-toolkit:review-pr` against the diff. Address any Critical/High findings before push. The project hook `check-pr-review.sh` blocks push until pr-review state is marked.

After review and any fixes, mark:
```bash
hooks/state-manager.sh mark pr-review
```

- [ ] **Step 6.4: Rebase onto main and push**

Run:
```bash
git fetch origin main
git rebase origin/main
git push origin "HEAD:refs/heads/feat/per-side-launcher" -u
```

Expected: push succeeds. The `block-push-to-main` hook only blocks pushes targeting `main` itself; pushing a feature branch is fine.

- [ ] **Step 6.5: Open a PR**

Run:
```bash
gh pr create --title "feat: add AGENT_DEV_LAUNCHER / AGENT_REVIEW_LAUNCHER per-side overrides (INV-38)" --head feat/per-side-launcher --body "$(cat <<'EOF'
## Summary

Adds two operator knobs in `lib-agent.sh` that let dev and review wrappers each have their own launcher prefix. Both default to `${AGENT_LAUNCHER:-}` so existing deployments are byte-for-byte unchanged.

The `[INV-37]` "both sides claude" guard is replaced by two per-side guards: `AGENT_DEV_LAUNCHER` is gated on `AGENT_DEV_CMD`, `AGENT_REVIEW_LAUNCHER` on `AGENT_REVIEW_CMD`. Strictly more permissive — every operator config that passed before still passes.

The motivating use case: a project that wants `AGENT_CMD="claude"` + `AGENT_DEV_LAUNCHER='cc...'` (Bedrock bridge for dev) + `AGENT_REVIEW_CMD="kiro"` (no launcher needed for review). Pre-INV-38: blocked by [INV-37]. Post-INV-38: works.

## What's in the PR

- `skills/autonomous-dispatcher/scripts/lib-agent.sh` — init + tokenization for `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER`; replace single guard with two per-side guards
- `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` — 1-line `AGENT_LAUNCHER_ARGV` rebind after `AGENT_CMD` rebind
- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` — symmetric rebind for review side
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` — operator-facing comment block with worked example
- `tests/unit/test-lib-agent-per-side-launcher.sh` — 12 assertions (PSL-S1..S10): defaults, fallback, per-side override, per-side guard pass/fail, structural placement
- `tests/unit/test-lib-agent-per-side-cmd.sh` — PSC-S7/S8/S11 assertion needles updated to match new per-side error messages
- `docs/pipeline/per-side-launcher.md` — spec
- `docs/pipeline/invariants.md` — INV-38
- `docs/pipeline/README.md` — index entry
- `docs/superpowers/plans/2026-05-26-per-side-launcher.md` — implementation plan

## Backwards compatibility

Existing deployments don't set the new vars. Defaults make both per-side ARGVs equal to the existing `AGENT_LAUNCHER_ARGV`. The wrapper rebinds copy into the same variable. Result: byte-for-byte identical pre/post.

## Spec & invariant

- [`docs/pipeline/per-side-launcher.md`](https://github.com/zxkane/autonomous-dev-team/blob/feat/per-side-launcher/docs/pipeline/per-side-launcher.md)
- INV-38: per-side AGENT_LAUNCHER precedence

## Pipeline-docs gate

Touches `lib-agent.sh` (watched path), so `docs/pipeline/` must also change. Satisfied:
- [x] `docs/pipeline/per-side-launcher.md`
- [x] `docs/pipeline/invariants.md` (INV-38)
- [x] `docs/pipeline/README.md`

## Test plan

- [x] `bash tests/unit/test-lib-agent-per-side-launcher.sh` — PASS
- [x] `bash tests/unit/test-lib-agent-per-side-cmd.sh` — PASS (PSC-S7/S8/S11 needles updated)
- [x] All existing `tests/unit/test-lib-agent-*.sh` regression tests PASS
- [x] `shellcheck -S error` clean on lib-agent.sh + both wrappers + new test
- [x] `bash -n autonomous.conf.example` syntax OK
- [ ] CI: `unit-tests` + `shellcheck` + `pipeline-docs-gate` green
EOF
)"
```

Expected: PR URL printed.

---

## Self-Review (run after all tasks complete)

**Spec coverage:**

| Spec section | Implemented in |
|---|---|
| §Why | (motivation; no code) |
| §Resolution order — `${VAR:-$AGENT_LAUNCHER}` defaults | Task 1 (lib-agent init) |
| §Resolution order — wrapper-level rebind | Tasks 2+3 |
| §Backwards compatibility | Task 1 (defaults), Task 1.14 (regression sweep), Task 6.1 |
| §Guard semantics — split into two per-side guards | Task 1.8 (guard rewrite) |
| §What is NOT covered | (deferrals; no code) |
| §Operator-facing config | Task 4 |
| §Failure modes table | Tested in Task 1 (PSL-S1..S8); §"WARN on empty" / §"ERROR on parse" mirror the existing AGENT_LAUNCHER paths via copy-paste of the eval block |
| §Test coverage table — PSL-S1..S10 | Tasks 1+2+3 |
| §Existing-test impact — PSC-S7/S8/S11 needle update | Task 1.11 |
| §Implementation order — 7 steps | Tasks 1-5 (Task 6 is push/PR) |

**Placeholder scan:** No "TBD"/"TODO"/"similar to"/etc. Every code block is complete.

**Type / signature consistency:**
- `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER` referenced consistently across Tasks 1-5
- `AGENT_DEV_LAUNCHER_ARGV` / `AGENT_REVIEW_LAUNCHER_ARGV` (the tokenized arrays) referenced consistently — defined in Task 1, consumed in Tasks 2+3 and tested in PSL-S1..S5
- Guard error message format pinned (mentions `AGENT_DEV_LAUNCHER`+`AGENT_DEV_CMD=...` for dev side, mirror for review side)
- `AGENT_LAUNCHER_ARGV` (the active array) is rebound to the side-specific array — _run_with_timeout's read site is unchanged
- Tests reference the same var names as the implementation
- PSC-S7/S8/S11 needle updates in Task 1.11 use the same per-side names the guard rewrite emits

**Missing requirements:** None. PSL-S1..S10 + PSC-S7/S8/S11 updates all map to spec.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-26-per-side-launcher.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks
**2. Inline Execution** — batch execution with checkpoints

Which approach?
