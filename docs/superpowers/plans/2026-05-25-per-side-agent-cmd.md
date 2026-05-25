# Per-Side `AGENT_CMD` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `AGENT_DEV_CMD` and `AGENT_REVIEW_CMD` operator knobs to `lib-agent.sh` so dev and review wrappers can run on different agent CLIs in the same project (e.g. claude for dev, agy for review).

**Architecture:** Two new environment variables initialized in `lib-agent.sh` after the existing `AGENT_CMD` line, defaulting to `${AGENT_CMD:-claude}` so existing deployments are byte-for-byte unchanged. Each wrapper sets `AGENT_CMD` to its side's value immediately after sourcing `lib-agent.sh`. The existing `AGENT_LAUNCHER` claude-only guard generalizes to check both per-side vars (strictly more permissive — never rejects a previously-passing config).

**Tech Stack:** Bash 5.x. No new runtime dependencies.

**Spec:** [`docs/pipeline/per-side-agent-cmd.md`](../../pipeline/per-side-agent-cmd.md) (committed in this branch).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `skills/autonomous-dispatcher/scripts/lib-agent.sh` | Modify | Add `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` init lines; rewrite `AGENT_LAUNCHER` guard to check both sides. |
| `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` | Modify | Add one-line `AGENT_CMD="$AGENT_DEV_CMD"` immediately after `source ${SCRIPT_DIR}/lib-agent.sh`, before any other source. |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | Modify | Add one-line `AGENT_CMD="$AGENT_REVIEW_CMD"` in the same position. |
| `skills/autonomous-dispatcher/scripts/autonomous.conf.example` | Modify | Add `# AGENT_DEV_CMD / AGENT_REVIEW_CMD` operator-facing comment block. |
| `tests/unit/test-lib-agent-per-side-cmd.sh` | Create | 11 test cases (PSC-S1..S11) — 8 behavioral, 2 structural, 1 launcher-edge. |
| `docs/pipeline/invariants.md` | Modify | Append `## INV-37: per-side AGENT_CMD precedence`. |

The spec doc and pipeline README index are already committed in this branch; no further docs changes.

---

## Pre-flight: Confirm Worktree

This project's hooks block direct commits on `main` (CLAUDE.md "All code changes must be developed in a Git Worktree"). The active worktree for this work is `worktree-feat+per-side-agent-cmd` at `/data/git/autonomous-dev-team/.claude/worktrees/feat+per-side-agent-cmd`. All `git commit` / `git push` steps below assume the executor is in that worktree.

If you are not already in the worktree, see `superpowers:using-git-worktrees`.

---

## Task 1: Add `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` init + rewrite `AGENT_LAUNCHER` guard

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/lib-agent.sh` (line ~63 for the new init, lines 101–109 for the guard rewrite)
- Test: `tests/unit/test-lib-agent-per-side-cmd.sh` (new file)

**Goal of this task:** Add the two new env vars and the rewritten launcher guard, both with full unit-test coverage. After this task, `run_agent` / `resume_agent` still see the same `$AGENT_CMD` they always did (because the wrapper override line lands in Task 2/3) — but lib-agent.sh now exposes the per-side resolution that wrappers will key on.

- [ ] **Step 1.1: Read lib-agent.sh lines 58-110 to confirm current state**

Run:
```bash
sed -n '58,110p' skills/autonomous-dispatcher/scripts/lib-agent.sh
```

Expected: see the existing `AGENT_CMD="${AGENT_CMD:-claude}"` at line 60, the `AGENT_LAUNCHER="${AGENT_LAUNCHER:-}"` at line 75, and the guard `if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 && "$AGENT_CMD" != "claude" ]]; then ...` at lines 106-109.

- [ ] **Step 1.2: Create the test file with scaffolding**

Create `tests/unit/test-lib-agent-per-side-cmd.sh`:

```bash
#!/bin/bash
# test-lib-agent-per-side-cmd.sh — Unit tests for AGENT_DEV_CMD /
# AGENT_REVIEW_CMD per-side overrides (INV-37).
#
# Verifies:
#   - Defaults: both per-side vars resolve to ${AGENT_CMD:-claude}
#   - Single-side override: only the overridden side changes
#   - Both-side override: each side runs its declared CLI
#   - Empty-string handling: :- treats explicit empty as unset
#   - AGENT_LAUNCHER guard: requires BOTH sides to be claude when set
#   - Wrapper structural placement: AGENT_CMD override lands immediately
#     after source lib-agent.sh in both autonomous-{dev,review}.sh
#
# Run: bash tests/unit/test-lib-agent-per-side-cmd.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
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

# resolve_pair <agent_cmd> <agent_dev_cmd> <agent_review_cmd>
# Sources lib-agent.sh in a sandbox with the given env, prints
# "DEV=<dev_cmd> REVIEW=<review_cmd>" on stdout. Strips ANY [lib-agent]
# warnings/errors so callers can grep cleanly.
resolve_pair() {
  local _ac="$1" _adc="$2" _arc="$3"
  AGENT_CMD="$_ac" \
  AGENT_DEV_CMD="$_adc" \
  AGENT_REVIEW_CMD="$_arc" \
  AGENT_LAUNCHER="" \
  bash -c '
    unset AUTONOMOUS_CONF
    source "'"$LIB"'" 2>/dev/null
    printf "DEV=%s REVIEW=%s\n" "$AGENT_DEV_CMD" "$AGENT_REVIEW_CMD"
  '
}

# launcher_guard <agent_dev_cmd> <agent_review_cmd>
# Sources lib-agent.sh with AGENT_LAUNCHER=cc and the given per-side
# values. Captures stderr; emits exit code on stdout last line.
launcher_guard() {
  local _adc="$1" _arc="$2"
  AGENT_CMD="claude" \
  AGENT_DEV_CMD="$_adc" \
  AGENT_REVIEW_CMD="$_arc" \
  AGENT_LAUNCHER="cc" \
  bash -c '
    unset AUTONOMOUS_CONF
    source "'"$LIB"'"
    echo "RC=$?"
  ' 2>&1
}

echo "=== test-lib-agent-per-side-cmd.sh — AGENT_DEV_CMD / AGENT_REVIEW_CMD (INV-37) ==="

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 1.3: Make executable + run scaffold**

Run:
```bash
chmod +x tests/unit/test-lib-agent-per-side-cmd.sh
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: scaffold prints the title line and exits 0 (`PASS: 0 FAIL: 0`). Helpers `resolve_pair` / `launcher_guard` are defined but not exercised yet.

- [ ] **Step 1.4: Add PSC-S1 + PSC-S2 + PSC-S3 (default + single-side override)**

Append to `tests/unit/test-lib-agent-per-side-cmd.sh` *before* the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S1: default — neither override set → both equal AGENT_CMD ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "claude" "" "")
assert_eq "default with AGENT_CMD=claude" "DEV=claude REVIEW=claude" "$out"

out=$(resolve_pair "codex" "" "")
assert_eq "default with AGENT_CMD=codex" "DEV=codex REVIEW=codex" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S2: only AGENT_REVIEW_CMD set → dev=AGENT_CMD, review=override ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "claude" "" "agy")
assert_eq "AGENT_CMD=claude AGENT_REVIEW_CMD=agy" "DEV=claude REVIEW=agy" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S3: only AGENT_DEV_CMD set → dev=override, review=AGENT_CMD ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "claude" "codex" "")
assert_eq "AGENT_CMD=claude AGENT_DEV_CMD=codex" "DEV=codex REVIEW=claude" "$out"
```

- [ ] **Step 1.5: Run — verify PSC-S1/S2/S3 FAIL (vars don't exist yet)**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: 4 failures. The `printf` in `resolve_pair` prints `DEV= REVIEW=` because the vars are unset. (lib-agent doesn't error on the unset; it just doesn't define them.)

- [ ] **Step 1.6: Add the per-side init lines to lib-agent.sh**

In `skills/autonomous-dispatcher/scripts/lib-agent.sh`, find the existing line `AGENT_CMD="${AGENT_CMD:-claude}"` (line 60). Insert the following two lines immediately after it (preserving the existing `AGENT_DEV_MODEL` line below):

```bash
# Per-side AGENT_CMD overrides (INV-37). Default to AGENT_CMD so existing
# deployments are unchanged. autonomous-dev.sh and autonomous-review.sh
# each set AGENT_CMD="$AGENT_{DEV,REVIEW}_CMD" right after sourcing this
# file, so the run_agent / resume_agent case statements dispatch to the
# right CLI for each side. See docs/pipeline/per-side-agent-cmd.md.
AGENT_DEV_CMD="${AGENT_DEV_CMD:-$AGENT_CMD}"
AGENT_REVIEW_CMD="${AGENT_REVIEW_CMD:-$AGENT_CMD}"
```

After insertion the block reads:

```bash
AGENT_CMD="${AGENT_CMD:-claude}"
# Per-side AGENT_CMD overrides (INV-37). ...
AGENT_DEV_CMD="${AGENT_DEV_CMD:-$AGENT_CMD}"
AGENT_REVIEW_CMD="${AGENT_REVIEW_CMD:-$AGENT_CMD}"
AGENT_DEV_MODEL="${AGENT_DEV_MODEL:-}"
...
```

- [ ] **Step 1.7: Run — verify PSC-S1/S2/S3 PASS**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: `PASS: 4 FAIL: 0`.

- [ ] **Step 1.8: Add PSC-S4 + PSC-S5 (both set + empty-string handling)**

Append before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S4: both set → each side runs its declared CLI ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "claude" "codex" "agy")
assert_eq "AGENT_CMD=claude DEV=codex REVIEW=agy" "DEV=codex REVIEW=agy" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S5: explicit empty string falls back to AGENT_CMD ==="
# ---------------------------------------------------------------------------
out=$(resolve_pair "kiro" "" "")
assert_eq "AGENT_DEV_CMD='' AGENT_REVIEW_CMD='' AGENT_CMD=kiro" "DEV=kiro REVIEW=kiro" "$out"
```

- [ ] **Step 1.9: Run — verify PSC-S4/S5 PASS**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: `PASS: 6 FAIL: 0`.

- [ ] **Step 1.10: Rewrite the AGENT_LAUNCHER guard**

In `skills/autonomous-dispatcher/scripts/lib-agent.sh`, find the existing guard at lines 101-109:

```bash
# AGENT_LAUNCHER is only supported with AGENT_CMD=claude today. The
# canonical launcher (a `cc` shell function ending in `$CLAUDE_CMD "$@"`)
# is hardcoded to invoke claude, so pointing it at codex/kiro/opencode
# would produce `claude codex ...` and fail. Refuse the combination
# rather than crashing 5 seconds into the next dispatch.
if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 && "$AGENT_CMD" != "claude" ]]; then
  echo "[lib-agent] ERROR: AGENT_LAUNCHER is only supported with AGENT_CMD=claude (got AGENT_CMD=${AGENT_CMD}). Either unset AGENT_LAUNCHER or write a launcher tailored to your CLI." >&2
  return 1 2>/dev/null || exit 1
fi
```

Replace with:

```bash
# AGENT_LAUNCHER is only supported when both per-side CLIs are claude
# (INV-37). The canonical launcher (a `cc` shell function ending in
# `$CLAUDE_CMD "$@"`) is hardcoded to invoke claude, so pointing it at
# codex/kiro/opencode/agy would produce `claude codex ...` and fail.
# Refuse the combination rather than crashing 5 seconds into the next
# dispatch. The check reads AGENT_DEV_CMD / AGENT_REVIEW_CMD directly
# (not via AGENT_CMD) because the wrapper-level override fires AFTER
# this guard — see docs/pipeline/per-side-agent-cmd.md §Resolution order.
if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
  if [[ "$AGENT_DEV_CMD" != "claude" || "$AGENT_REVIEW_CMD" != "claude" ]]; then
    echo "[lib-agent] ERROR: AGENT_LAUNCHER is only supported when both AGENT_DEV_CMD and AGENT_REVIEW_CMD are claude (got AGENT_DEV_CMD=${AGENT_DEV_CMD}, AGENT_REVIEW_CMD=${AGENT_REVIEW_CMD}). Either unset AGENT_LAUNCHER or write a launcher tailored to your CLI." >&2
    return 1 2>/dev/null || exit 1
  fi
fi
```

- [ ] **Step 1.11: Add PSC-S6 + PSC-S7 + PSC-S8 + PSC-S11 (launcher guard cases)**

Append before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S6: AGENT_LAUNCHER + both sides claude → source succeeds ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "claude" "claude")
assert_contains "RC=0 (no guard rejection)" "RC=0" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S7: AGENT_LAUNCHER + dev=claude review=agy → guard fails ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "claude" "agy")
assert_contains "guard error mentions AGENT_REVIEW_CMD=agy" "AGENT_REVIEW_CMD=agy" "$out"
assert_contains "guard error names both vars" "AGENT_DEV_CMD" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S8: AGENT_LAUNCHER + dev=codex review=claude → guard fails ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "codex" "claude")
assert_contains "guard error mentions AGENT_DEV_CMD=codex" "AGENT_DEV_CMD=codex" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S11: AGENT_LAUNCHER + both sides non-claude → guard fails ==="
# ---------------------------------------------------------------------------
out=$(launcher_guard "codex" "agy")
assert_contains "guard error mentions both non-claude values" "AGENT_DEV_CMD=codex" "$out"
assert_contains "guard error mentions review side too" "AGENT_REVIEW_CMD=agy" "$out"
```

- [ ] **Step 1.12: Run — verify all 11 assertions PASS**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: `PASS: 11 FAIL: 0` (S1: 2 + S2: 1 + S3: 1 + S4: 1 + S5: 1 + S6: 1 + S7: 2 + S8: 1 + S11: 2 = 12; some overlap is fine — what matters is `FAIL: 0`).

- [ ] **Step 1.13: Run shellcheck**

Run:
```bash
shellcheck -S error skills/autonomous-dispatcher/scripts/lib-agent.sh tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: exit 0, clean.

- [ ] **Step 1.14: Run lib-agent regression suite (no peer test should regress)**

Run:
```bash
for t in tests/unit/test-lib-agent-*.sh; do
  bash "$t" >/dev/null 2>&1 && echo "PASS: $(basename $t)" || echo "FAIL: $(basename $t)"
done
```

Expected: every line `PASS:`. The new vars default to `$AGENT_CMD`, so claude/codex/gemini/kiro/opencode/agy tests must see byte-for-byte identical behavior.

- [ ] **Step 1.15: Commit Task 1**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/lib-agent.sh tests/unit/test-lib-agent-per-side-cmd.sh
git commit -m "feat(lib-agent): add AGENT_DEV_CMD / AGENT_REVIEW_CMD overrides (INV-37)

Adds per-side AGENT_CMD overrides to lib-agent.sh. Default to AGENT_CMD
so existing deployments are byte-for-byte unchanged.

The AGENT_LAUNCHER guard is rewritten to read AGENT_DEV_CMD /
AGENT_REVIEW_CMD directly. The new check is strictly more permissive
than the old one — it rejects the same set of bad configs (any
non-claude side with launcher set) plus correctly accepts the new
'both sides claude' default case via the per-side path.

Tests: PSC-S1..S8 + S11 (defaults, single-side override, both-side,
empty-string fallback, launcher guard 4 ways). PSC-S9/S10 (wrapper
structural placement) land in Tasks 2 and 3.

Existing test-lib-agent-*.sh suites all pass — zero regressions."
```

---

## Task 2: Add `AGENT_CMD="$AGENT_DEV_CMD"` override to `autonomous-dev.sh`

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` (insert one line after line 22, immediately after `source "${SCRIPT_DIR}/lib-agent.sh"`)
- Test: `tests/unit/test-lib-agent-per-side-cmd.sh` (append PSC-S9)

- [ ] **Step 2.1: Add PSC-S9 test (structural)**

Append to `tests/unit/test-lib-agent-per-side-cmd.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S9: autonomous-dev.sh structural placement ==="
# ---------------------------------------------------------------------------
# Match: source "${SCRIPT_DIR}/lib-agent.sh" followed (with at most ONE
# blank line) by AGENT_CMD="$AGENT_DEV_CMD".
# Use awk so we don't depend on `grep -A` quirks across platforms.
hit=$(awk '
  /source "\$\{SCRIPT_DIR\}\/lib-agent\.sh"/ {
    found_source = NR
    next
  }
  found_source && NR <= found_source + 2 {
    if ($0 ~ /^AGENT_CMD="\$AGENT_DEV_CMD"/) {
      print "MATCH"
      exit
    }
  }
' "$DEV_WRAPPER")

assert_eq "autonomous-dev.sh: AGENT_CMD=\$AGENT_DEV_CMD lands ≤2 lines after source lib-agent.sh" \
  "MATCH" "$hit"
```

- [ ] **Step 2.2: Run — verify PSC-S9 FAILS (override line not present yet)**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: 1 new failure (PSC-S9). Other assertions remain green.

- [ ] **Step 2.3: Read current `autonomous-dev.sh` lines 21-25**

Run:
```bash
sed -n '21,25p' skills/autonomous-dispatcher/scripts/autonomous-dev.sh
```

Expected:
```
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${SCRIPT_DIR}/lib-agent.sh"
source "${SCRIPT_DIR}/lib-auth.sh"

# Validate required config (loaded by lib-agent.sh from autonomous.conf)
```

- [ ] **Step 2.4: Insert the override line**

Use the Edit tool to change:

```
source "${SCRIPT_DIR}/lib-agent.sh"
source "${SCRIPT_DIR}/lib-auth.sh"
```

to:

```
source "${SCRIPT_DIR}/lib-agent.sh"
# Per-side AGENT_CMD override (INV-37). Empty-string fallback already
# applied inside lib-agent.sh; this just rebinds AGENT_CMD so the case
# statements in run_agent / resume_agent dispatch to the dev-side CLI.
AGENT_CMD="$AGENT_DEV_CMD"
source "${SCRIPT_DIR}/lib-auth.sh"
```

- [ ] **Step 2.5: Run — verify PSC-S9 PASSES**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
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
git add skills/autonomous-dispatcher/scripts/autonomous-dev.sh tests/unit/test-lib-agent-per-side-cmd.sh
git commit -m "feat(autonomous-dev): apply AGENT_DEV_CMD override after lib-agent source

Adds AGENT_CMD=\$AGENT_DEV_CMD immediately after source lib-agent.sh so
the case statements in run_agent / resume_agent dispatch to the
dev-side CLI when the operator has set per-side overrides. Default
behavior (no overrides) is unchanged because AGENT_DEV_CMD defaults
to \$AGENT_CMD inside lib-agent.sh.

Test: PSC-S9 asserts the line lands within 2 lines of the source
statement so a future refactor can't accidentally move it past code
that consumes \$AGENT_CMD (earliest consumer is line 177)."
```

---

## Task 3: Add `AGENT_CMD="$AGENT_REVIEW_CMD"` override to `autonomous-review.sh`

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/autonomous-review.sh` (insert one line after line 22)
- Test: `tests/unit/test-lib-agent-per-side-cmd.sh` (append PSC-S10)

- [ ] **Step 3.1: Add PSC-S10 test (structural)**

Append before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== PSC-S10: autonomous-review.sh structural placement ==="
# ---------------------------------------------------------------------------
hit=$(awk '
  /source "\$\{SCRIPT_DIR\}\/lib-agent\.sh"/ {
    found_source = NR
    next
  }
  found_source && NR <= found_source + 2 {
    if ($0 ~ /^AGENT_CMD="\$AGENT_REVIEW_CMD"/) {
      print "MATCH"
      exit
    }
  }
' "$REVIEW_WRAPPER")

assert_eq "autonomous-review.sh: AGENT_CMD=\$AGENT_REVIEW_CMD lands ≤2 lines after source lib-agent.sh" \
  "MATCH" "$hit"
```

- [ ] **Step 3.2: Run — verify PSC-S10 FAILS**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: 1 new failure (PSC-S10).

- [ ] **Step 3.3: Read current `autonomous-review.sh` lines 21-30**

Run:
```bash
sed -n '21,30p' skills/autonomous-dispatcher/scripts/autonomous-review.sh
```

Expected:
```
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${SCRIPT_DIR}/lib-agent.sh"
source "${SCRIPT_DIR}/lib-auth.sh"
# shellcheck source=lib-review-bots.sh
source "${SCRIPT_DIR}/lib-review-bots.sh"
# shellcheck source=lib-review-verdict.sh
source "${SCRIPT_DIR}/lib-review-verdict.sh"

# Validate required config (loaded by lib-agent.sh from autonomous.conf)
```

- [ ] **Step 3.4: Insert the override line**

Use the Edit tool to change:

```
source "${SCRIPT_DIR}/lib-agent.sh"
source "${SCRIPT_DIR}/lib-auth.sh"
```

to:

```
source "${SCRIPT_DIR}/lib-agent.sh"
# Per-side AGENT_CMD override (INV-37). See autonomous-dev.sh for the
# matching dev-side override. Together they let one project run dev
# and review on different agent CLIs (e.g. claude for dev, agy for
# review). Default (no operator override) is byte-for-byte unchanged.
AGENT_CMD="$AGENT_REVIEW_CMD"
source "${SCRIPT_DIR}/lib-auth.sh"
```

- [ ] **Step 3.5: Run — verify PSC-S10 PASSES + everything else still green**

Run:
```bash
bash tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: `FAIL: 0`.

- [ ] **Step 3.6: shellcheck**

Run:
```bash
shellcheck -S error skills/autonomous-dispatcher/scripts/autonomous-review.sh
```

Expected: exit 0.

- [ ] **Step 3.7: Commit Task 3**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/autonomous-review.sh tests/unit/test-lib-agent-per-side-cmd.sh
git commit -m "feat(autonomous-review): apply AGENT_REVIEW_CMD override after lib-agent source

Mirrors the dev-side change. AGENT_CMD=\$AGENT_REVIEW_CMD lands
immediately after source lib-agent.sh so the run_agent dispatch and
the 'Reviewed HEAD: ... agent X' trailer (line ~636) report the
review-side CLI correctly.

Test: PSC-S10 asserts placement structurally."
```

---

## Task 4: Document `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` in `autonomous.conf.example`

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/autonomous.conf.example` (insert ~15 lines after the `AGENT_PERMISSION_MODE="auto"` line at ~line 150, before the per-CLI blocks)

- [ ] **Step 4.1: Locate the insertion point**

Run:
```bash
grep -nE '^AGENT_PERMISSION_MODE=|^# --- claude block' skills/autonomous-dispatcher/scripts/autonomous.conf.example
```

Expected:
```
150:AGENT_PERMISSION_MODE="auto"
217:# --- claude block ---
```

The new comment block goes between these two markers. The existing content at lines 151-216 includes `AGENT_TIMEOUT`, `AGENT_LAUNCHER` docs, and `AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`. The new block belongs **after** the EXTRA_ARGS lines and **before** the `# --- claude block ---`.

- [ ] **Step 4.2: Find the exact insertion anchor**

Run:
```bash
grep -nE '^AGENT_REVIEW_EXTRA_ARGS=|^# --- claude block' skills/autonomous-dispatcher/scripts/autonomous.conf.example
```

Expected:
```
215:AGENT_REVIEW_EXTRA_ARGS=""
217:# --- claude block ---
```

The new block goes on line 216 (the blank line currently between them).

- [ ] **Step 4.3: Insert the operator-facing comment block**

Use the Edit tool. Change:

```
AGENT_DEV_EXTRA_ARGS=""
AGENT_REVIEW_EXTRA_ARGS=""

# --- claude block ---
```

to:

```
AGENT_DEV_EXTRA_ARGS=""
AGENT_REVIEW_EXTRA_ARGS=""

# AGENT_DEV_CMD / AGENT_REVIEW_CMD: per-side override of AGENT_CMD.
# Default to AGENT_CMD when unset/empty, so existing single-CLI
# deployments are unaffected. Set them when you want dev and review
# to run on different CLIs — for example, claude for the heavy dev
# work and agy for the cheaper review pass:
#
#   AGENT_CMD="claude"           # also used by anything not split
#   AGENT_REVIEW_CMD="agy"       # only review goes to agy
#   AGENT_DEV_MODEL="opus[1m]"
#   AGENT_REVIEW_MODEL=""        # ignored by agy (warns), see agy block
#
# AGENT_LAUNCHER (claude-only) is rejected when either side resolves
# to a non-claude CLI. Either unset the launcher or keep both sides
# on claude. See [INV-37] in docs/pipeline/invariants.md.
# AGENT_DEV_CMD=""
# AGENT_REVIEW_CMD=""

# --- claude block ---
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
git commit -m "docs(conf): document AGENT_DEV_CMD / AGENT_REVIEW_CMD in autonomous.conf.example

Adds a 15-line operator-facing comment block between the EXTRA_ARGS
declarations and the per-CLI blocks. Includes a worked example for
the 'claude for dev, agy for review' deployment pattern (the
motivating use case) and the AGENT_LAUNCHER constraint reminder."
```

---

## Task 5: Add INV-37 to `docs/pipeline/invariants.md`

**Files:**
- Modify: `docs/pipeline/invariants.md` (append before the `## Adding a new invariant` section at line 981)

- [ ] **Step 5.1: Locate the insertion point**

Run:
```bash
grep -n "^## Adding a new invariant" docs/pipeline/invariants.md
```

Expected: a single line number (currently 981, may shift slightly).

- [ ] **Step 5.2: Insert the INV-37 block**

Use the Edit tool. Find the lines:

```
- [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element) — agy's `-p` (no value) reads from stdin, same channel contract as claude/gemini.

## Adding a new invariant
```

Replace with:

```
- [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element) — agy's `-p` (no value) reads from stdin, same channel contract as claude/gemini.

## INV-37: per-side AGENT_CMD precedence

**Rule**: `lib-agent.sh` exposes `AGENT_DEV_CMD` and `AGENT_REVIEW_CMD` as side-specific overrides of `AGENT_CMD`. Both default to `${AGENT_CMD:-claude}` so existing deployments are byte-for-byte unchanged. `autonomous-dev.sh` sets `AGENT_CMD="$AGENT_DEV_CMD"` exactly once, immediately after sourcing `lib-agent.sh` and before any other `source`. `autonomous-review.sh` sets `AGENT_CMD="$AGENT_REVIEW_CMD"` in the same position. After the override, the `case "$AGENT_CMD"` statements in `run_agent` / `resume_agent` dispatch to the right CLI per-side without any signature change.

**Why**: lets one project run dev and review on different CLIs (typical pattern: claude for dev, agy or another cheaper / specialized CLI for review). Without this, `AGENT_CMD` is a single value shared by both wrappers and operators must choose one CLI for the whole project. The model knobs (`AGENT_DEV_MODEL` / `AGENT_REVIEW_MODEL`) and per-side flags (`AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`) already split — INV-37 closes the conspicuous gap on the CLI knob.

**Constraint**: `AGENT_LAUNCHER` (claude-only at this writing) is rejected at `lib-agent.sh` source time when **either** `AGENT_DEV_CMD` or `AGENT_REVIEW_CMD` resolves to a non-claude CLI. The launcher would otherwise be applied to a CLI it wasn't written for. The guard reads `AGENT_DEV_CMD` and `AGENT_REVIEW_CMD` directly (not `$AGENT_CMD`) so it fires correctly regardless of which wrapper does the subsequent override.

**Producer**: `lib-agent.sh` init block (the two `${VAR:-$AGENT_CMD}` assignments after `AGENT_CMD="${AGENT_CMD:-claude}"`).

**Consumer**: `autonomous-dev.sh` and `autonomous-review.sh` entry blocks set the active `AGENT_CMD` before any `run_agent` / `resume_agent` call.

**Test**: `tests/unit/test-lib-agent-per-side-cmd.sh` PSC-S1 (defaults), PSC-S2/S3 (single-side override), PSC-S4 (both set), PSC-S5 (empty-string fallback), PSC-S6 (launcher + both claude → pass), PSC-S7/S8/S11 (launcher + any non-claude side → fail with both var values in the error), PSC-S9/S10 (wrapper structural placement).

**Cross-references**:
- [`docs/pipeline/per-side-agent-cmd.md`](per-side-agent-cmd.md) — full spec.
- [INV-31](#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) — the new vars are operator-tunable and live in `autonomous.conf`, following INV-31's contract.
- [`docs/pipeline/agy-cli-support.md`](agy-cli-support.md) — agy is the most likely review-side CLI today and the motivating example.

## Adding a new invariant
```

- [ ] **Step 5.3: Verify the link from per-side-agent-cmd.md resolves**

Run:
```bash
grep -n "inv-37-per-side-agent_cmd-precedence" docs/pipeline/invariants.md
```

Expected: returns the auto-generated GFM anchor for the new heading. If it returns 0 hits, the heading text and the anchor in the spec don't match — fix the spec or the heading.

- [ ] **Step 5.4: Commit Task 5**

Run:
```bash
git add docs/pipeline/invariants.md
git commit -m "docs(pipeline): record INV-37 per-side AGENT_CMD precedence

INV-37 documents the AGENT_DEV_CMD / AGENT_REVIEW_CMD precedence rule
that lets one project run dev and review on different agent CLIs.
Defaults preserve back-compat. AGENT_LAUNCHER guard tightens to require
both sides claude.

Anchored to docs/pipeline/per-side-agent-cmd.md (which already exists
on this branch with cross-reference [INV-37] resolved by this commit)."
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

Expected: `ALL UNIT TESTS PASS`. The new vars default to `$AGENT_CMD` so every existing test sees identical behavior.

- [ ] **Step 6.2: shellcheck the modified scripts**

Run:
```bash
shellcheck -S error \
  skills/autonomous-dispatcher/scripts/lib-agent.sh \
  skills/autonomous-dispatcher/scripts/autonomous-dev.sh \
  skills/autonomous-dispatcher/scripts/autonomous-review.sh \
  tests/unit/test-lib-agent-per-side-cmd.sh
```

Expected: exit 0.

- [ ] **Step 6.3: Mark pr-review state per the project hook**

The project's `check-pr-review.sh` hook blocks `git push` until `pr-review` state is marked for the current HEAD. After running `/pr-review-toolkit:review-pr` and addressing any Critical/High findings, mark:

```bash
hooks/state-manager.sh mark pr-review
```

(If you commit again after marking, re-run the review and re-mark. The mark is bound to the HEAD SHA.)

- [ ] **Step 6.4: Rebase onto main and push**

Run:
```bash
git fetch origin main
git rebase origin/main
git push origin "HEAD:refs/heads/feat/per-side-agent-cmd" -u
```

Expected: push succeeds. The `block-push-to-main` hook only blocks pushes targeting `main` itself; pushing a feature branch is fine.

- [ ] **Step 6.5: Open a PR**

Run:
```bash
gh pr create --title "feat: add AGENT_DEV_CMD / AGENT_REVIEW_CMD per-side overrides (INV-37)" --head feat/per-side-agent-cmd --body "$(cat <<'EOF'
## Summary

Adds two operator knobs in `lib-agent.sh` that let dev and review wrappers run on different agent CLIs in the same project:

- `AGENT_DEV_CMD` — defaults to `${AGENT_CMD:-claude}`
- `AGENT_REVIEW_CMD` — defaults to `${AGENT_CMD:-claude}`

Each wrapper sets `AGENT_CMD` to its side's value immediately after sourcing `lib-agent.sh`. The `AGENT_LAUNCHER` guard generalizes to reject any non-claude side (strictly more permissive than the old single-side check — never rejects a config that previously passed).

The motivating use case: `podcast-curation` wants `AGENT_CMD="claude"` for heavy dev and `AGENT_REVIEW_CMD="agy"` for cheaper review.

## What's in the PR

- `skills/autonomous-dispatcher/scripts/lib-agent.sh` — 2-line init + guard rewrite
- `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` — 1-line override after `source lib-agent.sh`
- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` — 1-line override (symmetric)
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` — operator-facing comment block with worked example
- `tests/unit/test-lib-agent-per-side-cmd.sh` — 11 test cases (PSC-S1..S11): defaults, single-side override, both-side, empty-string, launcher guard ×4, wrapper structural placement
- `docs/pipeline/per-side-agent-cmd.md` — spec
- `docs/pipeline/invariants.md` — INV-37
- `docs/pipeline/README.md` — index entry

## Backwards compatibility

Existing deployments don't set the new vars. Defaults make both equal to `$AGENT_CMD`, so behavior is byte-for-byte identical pre/post.

## Spec & invariant

- [`docs/pipeline/per-side-agent-cmd.md`](https://github.com/zxkane/autonomous-dev-team/blob/feat/per-side-agent-cmd/docs/pipeline/per-side-agent-cmd.md)
- INV-37: per-side AGENT_CMD precedence

## Pipeline-docs gate

Touches `lib-agent.sh` (watched path), so `docs/pipeline/` must also change. Satisfied:
- [x] `docs/pipeline/per-side-agent-cmd.md` (already on branch from prior commit)
- [x] `docs/pipeline/invariants.md` (INV-37)
- [x] `docs/pipeline/README.md` (already on branch from prior commit)

## Test plan

- [x] `bash tests/unit/test-lib-agent-per-side-cmd.sh` — 11/11 PASS
- [x] All existing `tests/unit/test-lib-agent-*.sh` regression tests PASS (defaults preserve byte-identical behavior)
- [x] shellcheck `-S error` clean on lib-agent.sh + both wrappers + new test
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
| §Resolution order — `${VAR:-$AGENT_CMD}` defaults | Task 1 (lib-agent init) |
| §Resolution order — wrapper-level override | Tasks 2+3 |
| §Resolution order — guard-timing clarification | (doc-only; spec already updated) |
| §Backwards compatibility | Task 1 (defaults), Task 1.14 (regression run) |
| §AGENT_LAUNCHER interaction — generalized guard | Task 1.10 (guard rewrite) |
| §What is NOT covered | (deferrals; no code) |
| §Operator-facing config | Task 4 |
| §Failure modes table | Tested in Task 1 (PSC-S1..S8 + S11) and Tasks 2+3 (PSC-S9/S10) |
| §Test coverage table — PSC-S1..S11 | Tasks 1+2+3 |
| §Implementation order — 6 steps | Tasks 1-5 (Task 6 is push/PR) |

**Placeholder scan:** No "TBD"/"TODO"/"similar to"/etc. Every code block is complete.

**Type / signature consistency:**
- `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` referenced consistently across Tasks 1-5 (lib-agent init, wrapper overrides, conf example, INV-37)
- `${VAR:-$AGENT_CMD}` form consistent across the two new vars
- Guard error message format pinned (mentions both `AGENT_DEV_CMD=...` and `AGENT_REVIEW_CMD=...`)
- Tests reference the same var names as the implementation

**Missing requirements:** None. PSC-S1..S11 all map to spec test rows. INV-37 cross-references match the spec's cross-references.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-25-per-side-agent-cmd.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
