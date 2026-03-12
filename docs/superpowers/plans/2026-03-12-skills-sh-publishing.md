# Skills.sh Publishing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the repo so skills are discoverable via `npx skills add zxkane/autonomous-dev-team` — move skills to `skills/`, hooks to `hooks/`, merge github-workflow + autonomous-dev, update all paths, create cross-platform documentation.

**Architecture:** File moves via `git mv` to preserve history, symlink `.claude/skills → ../skills` for Claude Code backward compatibility, cross-platform SKILL.md with conditional IDE-specific sections, `resolve_state_dir()` in lib.sh for multi-IDE state directory support.

**Tech Stack:** Bash (hooks/scripts), Markdown (skills), Git (file moves, symlink), skills.sh CLI (validation)

**Spec:** `docs/superpowers/specs/2026-03-12-skills-sh-publishing-design.md`

---

## Chunk 0: Pre-Implementation Validation

### Task 0: Verify skills.sh discovery convention

**Files:** None (read-only validation)

Before starting any file moves, confirm that the `skills/<name>/SKILL.md` convention is discovered by the skills.sh CLI.

- [ ] **Step 1: Create a temp test structure and verify discovery**

```bash
mkdir -p /tmp/skills-test/skills/test-skill
echo -e "---\nname: test-skill\ndescription: test\n---\n# Test" > /tmp/skills-test/skills/test-skill/SKILL.md
cd /tmp/skills-test && npx skills add . -l
# Expected: lists "test-skill"
```

If `npx skills` is not available or fails, install it first:
```bash
npm install -g skills
```

- [ ] **Step 2: Clean up**

```bash
rm -rf /tmp/skills-test
cd /data/git/autonomous-dev-team
```

If discovery fails, STOP — investigate the skills.sh CLI discovery mechanism before proceeding.

---

## Chunk 1: File Moves (Phase 1)

Move hooks, skill references, dispatcher, and utility scripts to their new locations using `git mv` to preserve history. No content changes in this chunk — only moves.

### Task 1: Move hook scripts from `.claude/hooks/` to `hooks/`

**Files:**
- Move: `.claude/hooks/*.sh` → `hooks/*.sh` (14 files)

- [ ] **Step 1: Create `hooks/` directory and move all hook scripts**

```bash
mkdir -p hooks
git mv .claude/hooks/lib.sh hooks/lib.sh
git mv .claude/hooks/state-manager.sh hooks/state-manager.sh
git mv .claude/hooks/block-push-to-main.sh hooks/block-push-to-main.sh
git mv .claude/hooks/block-commit-outside-worktree.sh hooks/block-commit-outside-worktree.sh
git mv .claude/hooks/check-design-canvas.sh hooks/check-design-canvas.sh
git mv .claude/hooks/check-code-simplifier.sh hooks/check-code-simplifier.sh
git mv .claude/hooks/check-pr-review.sh hooks/check-pr-review.sh
git mv .claude/hooks/check-test-plan.sh hooks/check-test-plan.sh
git mv .claude/hooks/check-unit-tests.sh hooks/check-unit-tests.sh
git mv .claude/hooks/post-git-action-clear.sh hooks/post-git-action-clear.sh
git mv .claude/hooks/post-git-push.sh hooks/post-git-push.sh
git mv .claude/hooks/post-file-edit-reminder.sh hooks/post-file-edit-reminder.sh
git mv .claude/hooks/verify-completion.sh hooks/verify-completion.sh
git mv .claude/hooks/warn-skip-verification.sh hooks/warn-skip-verification.sh
```

- [ ] **Step 2: Verify all 14 files moved**

```bash
ls hooks/*.sh | wc -l
# Expected: 14
ls .claude/hooks/*.sh 2>/dev/null | wc -l
# Expected: 0 (directory should be empty or removed)
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: move hook scripts from .claude/hooks/ to hooks/"
```

### Task 2: Move skill references and utility scripts

**Files:**
- Move: `.claude/skills/github-workflow/references/` → `skills/autonomous-dev/references/`
- Move: `.claude/skills/github-workflow/scripts/resolve-threads.sh` → `scripts/resolve-threads.sh`
- Move: `.claude/skills/github-workflow/scripts/reply-to-comments.sh` → `scripts/reply-to-comments.sh`

- [ ] **Step 1: Create target directories and move files**

```bash
mkdir -p skills/autonomous-dev/references
git mv .claude/skills/github-workflow/references/commit-conventions.md skills/autonomous-dev/references/commit-conventions.md
git mv .claude/skills/github-workflow/references/review-commands.md skills/autonomous-dev/references/review-commands.md
git mv .claude/skills/github-workflow/scripts/resolve-threads.sh scripts/resolve-threads.sh
git mv .claude/skills/github-workflow/scripts/reply-to-comments.sh scripts/reply-to-comments.sh
```

- [ ] **Step 2: Verify moves**

```bash
ls skills/autonomous-dev/references/
# Expected: commit-conventions.md  review-commands.md
ls scripts/resolve-threads.sh scripts/reply-to-comments.sh
# Expected: both exist
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: move skill references and utility scripts to new locations"
```

### Task 3: Move dispatcher from openclaw/ to skills/ and scripts/

**Files:**
- Move: `openclaw/skills/autonomous-dispatcher/SKILL.md` → `skills/autonomous-dispatcher/SKILL.md`
- Move: `openclaw/skills/autonomous-dispatcher/dispatch-local.sh` → `scripts/dispatch-local.sh`
- Remove: `openclaw/` directory

- [ ] **Step 1: Move dispatcher files**

```bash
mkdir -p skills/autonomous-dispatcher
git mv openclaw/skills/autonomous-dispatcher/SKILL.md skills/autonomous-dispatcher/SKILL.md
git mv openclaw/skills/autonomous-dispatcher/dispatch-local.sh scripts/dispatch-local.sh
```

- [ ] **Step 2: Remove empty openclaw/ directory**

```bash
rm -rf openclaw
git add -A
```

- [ ] **Step 3: Verify**

```bash
ls skills/autonomous-dispatcher/SKILL.md
# Expected: exists
ls scripts/dispatch-local.sh
# Expected: exists
ls openclaw 2>/dev/null
# Expected: "No such file or directory"
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: move dispatcher skill to skills/ and dispatch-local.sh to scripts/"
```

---

## Chunk 2: Rewrite Skill Content (Phase 2)

Create the merged cross-platform `autonomous-dev` SKILL.md, rewrite `autonomous-review` SKILL.md, update dispatcher SKILL.md paths, then replace `.claude/skills/` with a symlink.

### Task 4: Create merged `skills/autonomous-dev/SKILL.md`

**Files:**
- Create: `skills/autonomous-dev/SKILL.md`
- Reference (read only): `.claude/skills/github-workflow/SKILL.md`, `.claude/skills/autonomous-dev/SKILL.md`

This is the largest task — merging github-workflow (495 lines) + autonomous-dev (209 lines) into a single cross-platform skill. The merged file follows the structure from spec Section 4.1.

- [ ] **Step 1: Read both source skills to understand full content**

Read `.claude/skills/github-workflow/SKILL.md` and `.claude/skills/autonomous-dev/SKILL.md`.

- [ ] **Step 2: Write merged `skills/autonomous-dev/SKILL.md`**

Create the file with this structure (see spec Section 4.1 for content outline, Section 4.2 for cross-platform language rules):

```yaml
---
name: autonomous-dev
description: >
  TDD development workflow with git worktree isolation. Covers design canvas,
  test-first development, code review, CI verification, and E2E testing.
  Supports interactive and fully autonomous modes for GitHub issue implementation.
---
```

Content sections (in order):
1. **Mode Detection** — interactive vs autonomous (from spec Section 4.1)
2. **Cross-Platform Notes** — hooks support table (from spec Section 4.3), tool name mapping
3. **Workflow Steps 1-13** — adapted from github-workflow SKILL.md, using cross-platform language:
   - Replace `Bash` tool → "Execute shell command" / "Run in your terminal"
   - Replace `Read` tool → "Read file"
   - Replace `Write`/`Edit` tool → "Create/edit file"
   - Replace `Agent` tool → "Use a subagent if available, otherwise follow the steps manually"
   - Replace `Skill` tool → "Load the skill" / "Follow the workflow"
   - Replace `.claude/hooks/state-manager.sh` → `hooks/state-manager.sh`
   - Replace `.claude/skills/github-workflow/scripts/resolve-threads.sh` → `scripts/resolve-threads.sh`
   - Replace `.claude/skills/github-workflow/scripts/reply-to-comments.sh` → `scripts/reply-to-comments.sh`
4. **Autonomous Mode Specifics** — from autonomous-dev SKILL.md:
   - Decision Making Guidelines
   - Resume Awareness
   - Marking Requirements Progress
   - Pre-existing Changes
   - Bot Review Integration
   - Error Recovery
5. **References** — `references/commit-conventions.md`, `references/review-commands.md`

Key cross-platform patterns to use throughout:
```markdown
### Workflow Enforcement (Optional Hooks)

If your IDE/CLI supports hooks (Claude Code, Kiro CLI), install them
from `hooks/` for hard enforcement. See `hooks/README.md` for setup.
Without hooks, follow each step manually — the discipline is the same.
```

```markdown
### Step 6: Code Review (Pre-Commit)

Run a code simplification review on the changed files. If your IDE
supports subagents (Claude Code, Kiro), dispatch a code-simplifier
agent. Otherwise, review the diff manually for unnecessary complexity,
code duplication, and unclear naming.

After review, mark complete:
```bash
hooks/state-manager.sh mark code-simplifier
```
```

- [ ] **Step 3: Verify the file is well-formed**

```bash
head -5 skills/autonomous-dev/SKILL.md
# Expected: YAML frontmatter with name: autonomous-dev
wc -l skills/autonomous-dev/SKILL.md
# Expected: roughly 400-600 lines (concise but complete)
```

- [ ] **Step 4: Commit**

```bash
git add skills/autonomous-dev/SKILL.md
git commit -m "feat: create merged cross-platform autonomous-dev skill"
```

### Task 5: Rewrite `skills/autonomous-review/SKILL.md`

**Files:**
- Create: `skills/autonomous-review/SKILL.md`
- Reference (read only): `.claude/skills/autonomous-review/SKILL.md`

- [ ] **Step 1: Read current autonomous-review SKILL.md**

Read `.claude/skills/autonomous-review/SKILL.md`.

- [ ] **Step 2: Write cross-platform `skills/autonomous-review/SKILL.md`**

```yaml
---
name: autonomous-review
description: >
  Autonomous PR code review with checklist verification, merge conflict
  resolution, E2E testing via browser automation, and auto-merge.
  Triggered by the autonomous review wrapper script.
---
```

Apply the same cross-platform language transformations as Task 4:
- Replace Claude-specific tool names with generic language
- Replace `.claude/hooks/state-manager.sh` → `hooks/state-manager.sh`
- Replace `.claude/skills/github-workflow/scripts/resolve-threads.sh` → `scripts/resolve-threads.sh`
- Add hooks support conditional section
- Keep all existing review logic intact (checklist, E2E, screenshot workflow, findings gate)

- [ ] **Step 3: Verify**

```bash
head -5 skills/autonomous-review/SKILL.md
# Expected: YAML frontmatter with name: autonomous-review
```

- [ ] **Step 4: Commit**

```bash
git add skills/autonomous-review/SKILL.md
git commit -m "feat: create cross-platform autonomous-review skill"
```

### Task 6: Update `skills/autonomous-dispatcher/SKILL.md` paths

**Files:**
- Modify: `skills/autonomous-dispatcher/SKILL.md`

- [ ] **Step 1: Read current dispatcher SKILL.md**

Read `skills/autonomous-dispatcher/SKILL.md` (already moved in Task 3).

- [ ] **Step 2: Update all `$SKILL_DIR/dispatch-local.sh` references**

Replace all occurrences of `$SKILL_DIR/dispatch-local.sh` with `$PROJECT_DIR/scripts/dispatch-local.sh` in the SKILL.md. There are 7 occurrences (6 usage lines + 1 comment on line 58 describing the script location).

Also update the "Local Dispatch Helper Script" section to explain the new location:
```markdown
**CRITICAL:** All task dispatches MUST use the helper script
`scripts/dispatch-local.sh` in the project root's `scripts/` directory.
```

- [ ] **Step 3: Verify no remaining `$SKILL_DIR/dispatch-local.sh` references**

```bash
grep -c 'SKILL_DIR.*dispatch-local' skills/autonomous-dispatcher/SKILL.md
# Expected: 0
grep -c 'PROJECT_DIR.*dispatch-local' skills/autonomous-dispatcher/SKILL.md
# Expected: 7 (6 usage lines + 1 comment)
```

- [ ] **Step 4: Commit**

```bash
git add skills/autonomous-dispatcher/SKILL.md
git commit -m "refactor: update dispatcher skill paths to scripts/dispatch-local.sh"
```

### Task 7: Replace `.claude/skills/` directory with symlink

**Files:**
- Remove: `.claude/skills/github-workflow/`, `.claude/skills/autonomous-dev/`, `.claude/skills/autonomous-review/`
- Create: `.claude/skills` → `../skills` (symlink)

**CRITICAL**: The directory MUST be removed BEFORE the symlink is created.

- [ ] **Step 1: Remove old `.claude/skills/` directory**

```bash
git rm -rf .claude/skills/
```

- [ ] **Step 2: Create symlink**

```bash
ln -sf ../skills .claude/skills
git add .claude/skills
```

- [ ] **Step 3: Verify symlink works**

```bash
ls -la .claude/skills
# Expected: .claude/skills -> ../skills
ls .claude/skills/autonomous-dev/SKILL.md
# Expected: file exists (via symlink)
ls .claude/skills/autonomous-review/SKILL.md
# Expected: file exists
ls .claude/skills/autonomous-dispatcher/SKILL.md
# Expected: file exists
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: replace .claude/skills/ directory with symlink to skills/"
```

---

## Chunk 3: Update Infrastructure (Phase 3)

Update hook scripts' internal paths, state-manager, settings.json, dispatch-local.sh, and autonomous-dev.sh.

### Task 8: Update `hooks/lib.sh` — add `resolve_state_dir()`

**Files:**
- Modify: `hooks/lib.sh` (append new function at end, after line 79)

- [ ] **Step 1: Add `resolve_state_dir()` function to `hooks/lib.sh`**

Append at the end of `hooks/lib.sh` (after line 79, the end of `get_project_root()`):

```bash
# Resolve state directory (works across IDEs)
# Prefers IDE-specific state dir if it exists, falls back to .agents/state/
resolve_state_dir() {
  local project_root
  project_root=$(resolve_project_root)
  if [[ -d "$project_root/.claude/state" ]]; then
    echo "$project_root/.claude/state"
  elif [[ -d "$project_root/.kiro/state" ]]; then
    echo "$project_root/.kiro/state"
  else
    mkdir -p "$project_root/.agents/state"
    echo "$project_root/.agents/state"
  fi
}
```

- [ ] **Step 2: Verify function exists**

```bash
grep -c 'resolve_state_dir' hooks/lib.sh
# Expected: at least 1
```

- [ ] **Step 3: Commit**

```bash
git add hooks/lib.sh
git commit -m "feat: add resolve_state_dir() to hooks/lib.sh for cross-IDE support"
```

### Task 9: Update `hooks/state-manager.sh` — use `resolve_state_dir()`

**Files:**
- Modify: `hooks/state-manager.sh:8`

- [ ] **Step 1: Update STATE_DIR to use `resolve_state_dir()`**

Change line 8 from:
```bash
STATE_DIR="$(resolve_project_root)/.claude/state"
```
To:
```bash
STATE_DIR="$(resolve_state_dir)"
```

- [ ] **Step 2: Verify**

```bash
grep 'STATE_DIR' hooks/state-manager.sh
# Expected: STATE_DIR="$(resolve_state_dir)"
```

- [ ] **Step 3: Commit**

```bash
git add hooks/state-manager.sh
git commit -m "refactor: use resolve_state_dir() in state-manager for cross-IDE support"
```

### Task 10: Update hook scripts — fix source paths and user-facing messages

**Files:**
- Modify: All 12 non-lib hook scripts in `hooks/` (all except `lib.sh` and `state-manager.sh`)

These scripts use `source "$SCRIPT_DIR/lib.sh"` which still works since `SCRIPT_DIR` is computed from `BASH_SOURCE`. However, 7 scripts have hardcoded `.claude/hooks/state-manager.sh` in user-facing error messages that must change to `hooks/state-manager.sh`.

- [ ] **Step 1: Update user-facing messages in all 7 affected hook scripts**

Replace `.claude/hooks/state-manager.sh` with `hooks/state-manager.sh` in these files:
- `hooks/check-code-simplifier.sh` (line 52)
- `hooks/check-pr-review.sh` (line 50)
- `hooks/check-unit-tests.sh` (line 52)
- `hooks/check-design-canvas.sh` (line 76)
- `hooks/check-test-plan.sh` (line 60)
- `hooks/verify-completion.sh` (line 159)
- `hooks/post-git-push.sh` (line 25, inside JSON string)

For each file, find `.claude/hooks/state-manager.sh` and replace with `hooks/state-manager.sh`.

- [ ] **Step 2: Verify no remaining old paths**

```bash
grep -r '\.claude/hooks/' hooks/
# Expected: no output (all paths updated)
```

- [ ] **Step 3: Commit**

```bash
git add hooks/
git commit -m "refactor: update hook scripts to use hooks/ paths instead of .claude/hooks/"
```

### Task 11: Update `.claude/settings.json` — change hook paths

**Files:**
- Modify: `.claude/settings.json`

- [ ] **Step 1: Replace all `.claude/hooks/` with `hooks/` in settings.json**

Replace every occurrence of `.claude/hooks/` with `hooks/` in `.claude/settings.json`. There are 16 total hook command references that need updating (13 unique hook scripts + 3 `post-git-action-clear.sh` entries with different arguments).

The `"command"` values change from:
```json
".claude/hooks/block-push-to-main.sh"
```
To:
```json
"hooks/block-push-to-main.sh"
```

Do this for ALL hook entries. The 3 `post-git-action-clear.sh` entries:
```json
"hooks/post-git-action-clear.sh commit code-simplifier"
"hooks/post-git-action-clear.sh commit design-canvas"
"hooks/post-git-action-clear.sh push pr-review"
```

And `verify-completion.sh`:
```json
"hooks/verify-completion.sh"
```

- [ ] **Step 2: Verify no remaining `.claude/hooks/` references**

```bash
grep -c '\.claude/hooks/' .claude/settings.json
# Expected: 0
grep -c '"hooks/' .claude/settings.json
# Expected: 16 (all hook paths updated)
```

- [ ] **Step 3: Commit**

```bash
git add .claude/settings.json
git commit -m "refactor: update settings.json hook paths from .claude/hooks/ to hooks/"
```

### Task 12: Update `scripts/dispatch-local.sh` — fix REPO_ROOT

**Files:**
- Modify: `scripts/dispatch-local.sh:32`

- [ ] **Step 1: Fix REPO_ROOT path calculation**

Change line 32 from:
```bash
REPO_ROOT="${SCRIPT_DIR}/../.."
```
To:
```bash
REPO_ROOT="${SCRIPT_DIR}/.."
```

(Now in `scripts/`, one level up reaches repo root instead of two.)

- [ ] **Step 2: Verify**

```bash
grep 'REPO_ROOT=' scripts/dispatch-local.sh
# Expected: REPO_ROOT="${SCRIPT_DIR}/.."
```

- [ ] **Step 3: Commit**

```bash
git add scripts/dispatch-local.sh
git commit -m "fix: update dispatch-local.sh REPO_ROOT for new scripts/ location"
```

### Task 13: Update `scripts/autonomous-dev.sh` and `scripts/autonomous.conf.example`

**Files:**
- Modify: `scripts/autonomous-dev.sh` (3 occurrences of `/github-workflow`)
- Modify: `scripts/autonomous.conf.example:35`

- [ ] **Step 1: Update DEV_SKILL_CMD default in `autonomous-dev.sh`**

Replace all occurrences of `/github-workflow` with `/autonomous-dev` in `scripts/autonomous-dev.sh`. There are 3 occurrences in the prompt templates (lines 194, 232, 280):
```bash
${DEV_SKILL_CMD:-/autonomous-dev}
```

- [ ] **Step 2: Update `scripts/autonomous.conf.example`**

Change line 35 from:
```bash
DEV_SKILL_CMD="/github-workflow"
```
To:
```bash
DEV_SKILL_CMD="/autonomous-dev"
```

- [ ] **Step 3: Verify**

```bash
grep -c 'github-workflow' scripts/autonomous-dev.sh
# Expected: 0
grep 'DEV_SKILL_CMD' scripts/autonomous.conf.example
# Expected: DEV_SKILL_CMD="/autonomous-dev"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/autonomous-dev.sh scripts/autonomous.conf.example
git commit -m "refactor: update DEV_SKILL_CMD from /github-workflow to /autonomous-dev"
```

---

## Chunk 4: Documentation (Phase 4)

Create new docs (hooks/README.md, AGENTS.md) and update existing docs (CLAUDE.md, README.md, autonomous-pipeline.md).

### Task 14: Create `hooks/README.md`

**Files:**
- Create: `hooks/README.md`

- [ ] **Step 1: Write hooks/README.md**

Content should cover (per spec Section 4.4):
1. **Claude Code setup** — JSON snippet showing `.claude/settings.json` hook config with `hooks/` paths
2. **Required Claude Code plugins** — `code-simplifier@claude-plugins-official`, `pr-review-toolkit@claude-plugins-official`
3. **Kiro CLI setup** — placeholder instructions for Kiro hook configuration
4. **Other IDEs** — note that IDEs without hook support use skill instructions only
5. **Hook reference table** — list all 14 hooks with purpose and trigger type

Use the actual `.claude/settings.json` content (with updated `hooks/` paths) as the Claude Code example.

- [ ] **Step 2: Commit**

```bash
git add hooks/README.md
git commit -m "docs: add hooks/README.md with per-IDE setup instructions"
```

### Task 15: Create `AGENTS.md`

**Files:**
- Create: `AGENTS.md`

- [ ] **Step 1: Write AGENTS.md**

Content per spec Section 4.6:
```markdown
# Autonomous Dev Team

## Available Skills

Install via: `npx skills add zxkane/autonomous-dev-team`

### autonomous-dev
TDD development workflow with git worktree isolation, design canvas,
test-first development, code review, and CI verification. Supports
interactive and autonomous modes.

### autonomous-review
PR code review with checklist verification, merge conflict resolution,
E2E testing via browser automation, and auto-merge.

### autonomous-dispatcher
GitHub issue scanner that dispatches dev and review agents on a cron
schedule. Manages the autonomous pipeline lifecycle via labels.

## Workflow Summary

1. Design → 2. Worktree → 3. Tests → 4. Implement → 5. Verify →
6. Review → 7. PR → 8. CI → 9. E2E → 10. Merge

## Scripts

Supporting scripts in `scripts/` provide agent CLI abstraction,
GitHub authentication, and pipeline utilities.

## Hooks

Optional workflow enforcement hooks in `hooks/`. See `hooks/README.md`
for IDE-specific setup.
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: add AGENTS.md for cross-platform skill discovery"
```

### Task 16: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Read current CLAUDE.md**

Read `CLAUDE.md` to identify all path references that need updating.

- [ ] **Step 2: Update all path references**

Apply these replacements throughout CLAUDE.md:
- `.claude/hooks/state-manager.sh` → `hooks/state-manager.sh` (6 occurrences)
- `.claude/hooks/` → `hooks/` in all other hook path references
- `.claude/skills/github-workflow/` → `skills/autonomous-dev/` (skill directory)
- `.claude/skills/autonomous-dev/` → `skills/autonomous-dev/` (merged)
- `.claude/skills/autonomous-review/` → `skills/autonomous-review/`
- `openclaw/skills/autonomous-dispatcher/` → `skills/autonomous-dispatcher/`
- `.claude/skills/github-workflow/scripts/reply-to-comments.sh` → `scripts/reply-to-comments.sh`
- `.claude/skills/github-workflow/scripts/resolve-threads.sh` → `scripts/resolve-threads.sh`
- `openclaw/skills/autonomous-dispatcher/dispatch-local.sh` → `scripts/dispatch-local.sh`

Keep Claude Code-specific tool syntax (`Bash`, `Agent`, `Write`, `Edit`, etc.) — only update file paths.

Update the Project Structure section to match the new repo layout from spec Section 3.2.

Update the Skills Reference section to reflect the merged skill name.

- [ ] **Step 3: Verify no stale paths remain**

```bash
grep -c '\.claude/hooks/' CLAUDE.md
# Expected: 0
grep -c '\.claude/skills/' CLAUDE.md
# Expected: 0 (or only in the symlink description)
grep -c 'openclaw/' CLAUDE.md
# Expected: 0
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md paths for new skills/hooks structure"
```

### Task 17: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read current README.md**

Read `README.md`.

- [ ] **Step 2: Add skills.sh installation section**

Add after the introductory paragraph (before "## How It Works"):
```markdown
## Install as Skills

Install these skills into any supported coding agent:

```bash
npx skills add zxkane/autonomous-dev-team
```

Supports 40+ agents including Claude Code, Cursor, Windsurf, Gemini CLI,
Kiro CLI, and more. See [skills.sh](https://skills.sh) for the full ecosystem.
```

- [ ] **Step 3: Update all path references**

Same pattern as Task 16:
- `.claude/hooks/state-manager.sh` → `hooks/state-manager.sh` (9 occurrences)
- `.claude/hooks/` → `hooks/` for all hook references
- `.claude/skills/github-workflow/` → `skills/autonomous-dev/`
- `.claude/skills/autonomous-dev/` → `skills/autonomous-dev/`
- `.claude/skills/autonomous-review/` → `skills/autonomous-review/`
- `openclaw/skills/autonomous-dispatcher/` → `skills/autonomous-dispatcher/`
- `openclaw/skills/autonomous-dispatcher/dispatch-local.sh` → `scripts/dispatch-local.sh`

Update the Project Structure section to match spec Section 3.2 layout.

- [ ] **Step 4: Verify no stale paths remain**

```bash
grep -c '\.claude/hooks/' README.md
# Expected: 0
grep -c '\.claude/skills/' README.md
# Expected: 0 (or only symlink description)
grep -c 'openclaw/' README.md
# Expected: 0
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: update README.md with skills.sh installation and new paths"
```

### Task 18: Update `docs/autonomous-pipeline.md`

**Files:**
- Modify: `docs/autonomous-pipeline.md`

- [ ] **Step 1: Read and update path references**

Read `docs/autonomous-pipeline.md` and update:
- `.claude/skills/autonomous-dev/SKILL.md` → `skills/autonomous-dev/SKILL.md`
- `.claude/skills/autonomous-review/SKILL.md` → `skills/autonomous-review/SKILL.md`
- `openclaw/skills/autonomous-dispatcher/SKILL.md` → `skills/autonomous-dispatcher/SKILL.md`
- `openclaw/skills/autonomous-dispatcher/dispatch-local.sh` → `scripts/dispatch-local.sh`
- Any OpenClaw cron command paths referencing `openclaw/`

- [ ] **Step 2: Verify**

```bash
grep -c 'openclaw/' docs/autonomous-pipeline.md
# Expected: 0
grep -c '\.claude/skills/' docs/autonomous-pipeline.md
# Expected: 0
```

- [ ] **Step 3: Commit**

```bash
git add docs/autonomous-pipeline.md
git commit -m "docs: update autonomous-pipeline.md paths for new structure"
```

### Task 19: Update `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add new entries to .gitignore**

Append to `.gitignore` (note: `.claude/state/` already exists at line 56):
```
# Claude Code local files
CLAUDE.local.md
*.local.*
.local.json

# Agent state directories (Kiro, generic)
.kiro/state/
.agents/state/
```

- [ ] **Step 2: Verify no duplicate `.claude/state/` entry**

```bash
grep -c '\.claude/state' .gitignore
# Expected: 1 (the existing one only)
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: add cross-IDE state directories and local files to .gitignore"
```

---

## Chunk 5: Validation (Phase 5)

Verify everything works: skills.sh discovery, symlink, hooks, state-manager, dispatch-local.

### Task 20: Validate skills.sh discovery

**Files:** None (read-only validation)

- [ ] **Step 1: List skills from repo root**

```bash
npx skills add . -l
```

Expected: Lists 3 skills: `autonomous-dev`, `autonomous-review`, `autonomous-dispatcher`

If `npx skills` is not installed or fails, use manual verification:
```bash
for skill_dir in skills/*/; do
  if [[ -f "${skill_dir}SKILL.md" ]]; then
    name=$(grep '^name:' "${skill_dir}SKILL.md" | head -1 | sed 's/name: *//')
    echo "Found skill: $name at $skill_dir"
  fi
done
# Expected: 3 skills found
```

- [ ] **Step 2: Verify SKILL.md frontmatter format**

```bash
for skill_dir in skills/*/; do
  echo "=== ${skill_dir}SKILL.md ==="
  head -5 "${skill_dir}SKILL.md"
  echo ""
done
# Expected: Each has --- / name: / description: / --- frontmatter
```

### Task 21: Validate symlink and Claude Code discovery

- [ ] **Step 1: Verify symlink exists and resolves**

```bash
ls -la .claude/skills
# Expected: .claude/skills -> ../skills

ls .claude/skills/autonomous-dev/SKILL.md .claude/skills/autonomous-review/SKILL.md .claude/skills/autonomous-dispatcher/SKILL.md
# Expected: all 3 files exist (via symlink)
```

- [ ] **Step 2: Verify git tracks the symlink**

```bash
git ls-files .claude/skills
# Expected: .claude/skills (as symlink entry)
```

### Task 22: Validate hooks work from new location

- [ ] **Step 1: Verify hook scripts are executable**

```bash
ls -la hooks/*.sh | awk '{print $1, $NF}'
# Expected: all have -rwxr-xr-x permissions
```

If not executable:
```bash
chmod +x hooks/*.sh
```

- [ ] **Step 2: Verify state-manager works**

```bash
hooks/state-manager.sh list
# Expected: "No states recorded" or current states

hooks/state-manager.sh mark test-validation
hooks/state-manager.sh check test-validation && echo "PASS" || echo "FAIL"
# Expected: PASS

hooks/state-manager.sh clear test-validation
# Expected: "Cleared state for 'test-validation'"
```

- [ ] **Step 3: Verify settings.json references valid hook paths**

```bash
# Extract all hook command paths from settings.json and verify each exists
python3 -c "
import json
with open('.claude/settings.json') as f:
    data = json.load(f)
for event_type, matchers in data.get('hooks', {}).items():
    for matcher in matchers:
        for hook in matcher.get('hooks', []):
            cmd = hook.get('command', '').split()[0]
            if cmd:
                import os
                exists = os.path.isfile(cmd)
                print(f'{'OK' if exists else 'MISSING'}: {cmd}')
"
# Expected: all "OK", no "MISSING"
```

### Task 23: Validate dispatch-local.sh

- [ ] **Step 1: Verify REPO_ROOT resolves correctly**

```bash
cd scripts && bash -c 'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; echo "${SCRIPT_DIR}/.."' dispatch-local.sh
# Expected: prints the repo root path (e.g., /data/git/autonomous-dev-team)
```

### Task 24: Test skills.sh installation for specific IDEs

**Files:** None (read-only validation)

- [ ] **Step 1: Test installation targeting Claude Code**

```bash
npx skills add . -a claude-code --copy -y
# Expected: installs skills to .claude/skills/ (or symlinks them)
```

- [ ] **Step 2: Test installation targeting Cursor**

```bash
npx skills add . -a cursor --copy -y
# Expected: installs skills to .agents/skills/ or .cursor/skills/
```

- [ ] **Step 3: Clean up test installations**

Remove any test-installed skill files created during validation.

### Task 25: Final commit and summary

- [ ] **Step 1: Check for any uncommitted changes**

```bash
git status
# Expected: clean working tree, or only validation-related temp files
```

- [ ] **Step 2: Verify full git log of migration**

```bash
git log --oneline HEAD~15..HEAD
# Expected: ~12-15 commits covering all tasks
```

---

## Task Dependencies

```
Task 0 (pre-validation)       ─── Chunk 0 (must pass before anything)
                                │
Task 1 (move hooks)           ─┐
Task 2 (move references)       ├── Chunk 1 (independent, can parallel)
Task 3 (move dispatcher)      ─┘
                                │
Task 4 (merge dev skill)      ─┐
Task 5 (rewrite review)        ├── Chunk 2 (4,5,6 can parallel; 7 depends on all)
Task 6 (update dispatcher)     │
Task 7 (symlink)              ─┘ (depends on 4,5,6 + requires old .claude/skills removed)
                                │
Task 8 (lib.sh)               ─┐
Task 9 (state-manager)         │ (depends on 8)
Task 10 (hook messages)         ├── Chunk 3
Task 11 (settings.json)        │
Task 12 (dispatch-local)       │
Task 13 (autonomous-dev.sh)   ─┘
                                │
Task 14-19                     ─── Chunk 4 (all can parallel)
                                │
Task 20-25                     ─── Chunk 5 (sequential validation)
```
