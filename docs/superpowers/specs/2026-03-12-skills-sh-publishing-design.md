# Design Spec: Publish Autonomous Dev Team Skills to skills.sh

**Date**: 2026-03-12
**Status**: Draft
**Author**: AI-assisted

---

## 1. Goal

Restructure the `autonomous-dev-team` repository so that its skills are discoverable and installable via the [skills.sh](https://skills.sh) ecosystem (`npx skills add zxkane/autonomous-dev-team`). Users can install these skills into any supported coding agent IDE/CLI (Claude Code, Cursor, Windsurf, Gemini CLI, Kiro CLI, etc.) and use them for TDD-driven development, autonomous PR review, and fully automated issue-to-merge pipelines.

**skills.sh discovery convention**: The skills CLI searches `skills/<name>/SKILL.md` directories at the repo root as a standard discovery path (see [vercel-labs/skills source](https://github.com/vercel-labs/skills)). This is confirmed by the CLI's `src/constants.ts` which defines `SKILLS_SUBDIR = "skills"` as a discovery location.

---

## 2. Current State

### Skills (3 separate, Claude Code-specific)

| Skill | Location | Purpose |
|-------|----------|---------|
| `github-workflow` | `.claude/skills/github-workflow/` | 13-step interactive TDD workflow |
| `autonomous-dev` | `.claude/skills/autonomous-dev/` | Autonomous dev mode (wraps github-workflow) |
| `autonomous-review` | `.claude/skills/autonomous-review/` | Autonomous PR review + E2E verification |

Additionally:
- `openclaw/skills/autonomous-dispatcher/` — pipeline dispatcher (not under `.claude/skills/`)

### Supporting infrastructure

| Category | Files |
|----------|-------|
| Hooks (14 scripts) | `.claude/hooks/*.sh` — enforce TDD workflow steps |
| Skill utility scripts | `.claude/skills/github-workflow/scripts/resolve-threads.sh`, `reply-to-comments.sh` |
| Wrapper scripts | `scripts/autonomous-dev.sh`, `scripts/autonomous-review.sh` |
| Auth scripts | `scripts/lib-auth.sh`, `scripts/gh-app-token.sh`, `scripts/gh-token-refresh-daemon.sh`, `scripts/gh-with-token-refresh.sh`, `scripts/gh-as-user.sh` |
| Agent abstraction | `scripts/lib-agent.sh` |
| Utilities | `scripts/mark-issue-checkbox.sh`, `scripts/upload-screenshot.sh` |
| Dispatch | `openclaw/skills/autonomous-dispatcher/dispatch-local.sh` |
| State manager | `.claude/hooks/state-manager.sh` |
| Config template | `scripts/autonomous.conf.example` (`DEV_SKILL_CMD="/github-workflow"`) |

### Problems

1. **Not discoverable by skills.sh CLI** — skills are in `.claude/skills/`, not in the standard `skills/` root directory
2. **Claude Code-specific language** — SKILL.md files reference Claude-specific tool names (`Bash`, `Write`, `Edit`), hooks format, and MCP tools
3. **Fragmented skills** — `github-workflow` and `autonomous-dev` overlap significantly (autonomous-dev is a thin wrapper over github-workflow)
4. **Hooks are coupled to `.claude/`** — hook scripts live in `.claude/hooks/` and `settings.json` references them with `.claude/hooks/` paths
5. **No AGENTS.md** — no cross-platform agent instructions file at repo root
6. **Dispatcher in separate tree** — `openclaw/skills/` is not a standard skills.sh discovery path

---

## 3. Target State

### 3.1 Skill Inventory (3 skills)

| Skill | Name | Description |
|-------|------|-------------|
| **autonomous-dev** | `autonomous-dev` | Unified TDD development workflow — merges `github-workflow` + `autonomous-dev`. Supports both interactive mode (ask user for approval at gates) and autonomous mode (make decisions independently, report to GitHub issue) |
| **autonomous-review** | `autonomous-review` | PR code review, checklist verification, merge conflict resolution, E2E testing, auto-merge |
| **autonomous-dispatcher** | `autonomous-dispatcher` | GitHub issue scanner + task dispatcher for the autonomous pipeline |

### 3.2 Repo Directory Structure (Target)

```
autonomous-dev-team/
├── skills/                                  # skills.sh discovery root
│   ├── autonomous-dev/
│   │   ├── SKILL.md                         # Merged skill (interactive + autonomous)
│   │   └── references/
│   │       ├── commit-conventions.md        # Branch naming & commit standards
│   │       └── review-commands.md           # GitHub CLI & GraphQL commands
│   ├── autonomous-review/
│   │   └── SKILL.md                         # Cross-platform review skill
│   └── autonomous-dispatcher/
│       └── SKILL.md                         # Cross-platform dispatcher skill
│
├── hooks/                                   # IDE-agnostic hook scripts
│   ├── README.md                            # Per-IDE setup instructions
│   ├── lib.sh
│   ├── state-manager.sh
│   ├── block-push-to-main.sh
│   ├── block-commit-outside-worktree.sh
│   ├── check-design-canvas.sh
│   ├── check-code-simplifier.sh
│   ├── check-pr-review.sh
│   ├── check-test-plan.sh
│   ├── check-unit-tests.sh
│   ├── post-git-action-clear.sh
│   ├── post-git-push.sh
│   ├── post-file-edit-reminder.sh
│   ├── verify-completion.sh
│   └── warn-skip-verification.sh
│
├── scripts/                                 # Pipeline scripts (unchanged location)
│   ├── autonomous.conf.example
│   ├── autonomous-dev.sh
│   ├── autonomous-review.sh
│   ├── dispatch-local.sh                    # Moved from openclaw/
│   ├── resolve-threads.sh                   # Moved from .claude/skills/github-workflow/scripts/
│   ├── reply-to-comments.sh                 # Moved from .claude/skills/github-workflow/scripts/
│   ├── lib-agent.sh
│   ├── lib-auth.sh
│   ├── gh-app-token.sh
│   ├── gh-token-refresh-daemon.sh
│   ├── gh-with-token-refresh.sh
│   ├── gh-as-user.sh
│   ├── mark-issue-checkbox.sh
│   └── upload-screenshot.sh
│
├── .claude/                                 # Claude Code-specific (this repo's own config)
│   ├── settings.json                        # Hooks pointing to hooks/ (updated paths)
│   └── skills -> ../skills                  # Symlink so Claude Code discovers skills
│
├── AGENTS.md                                # Cross-platform agent instructions
├── CLAUDE.md                                # Claude Code-specific project instructions (updated)
├── README.md                                # Updated with skills.sh installation
├── .gitignore                               # Updated
│
├── docs/
│   ├── autonomous-pipeline.md
│   ├── github-app-setup.md
│   └── ...
└── openclaw/                                # REMOVED — dispatcher moved to skills/
```

### 3.3 Installation Experience

```bash
# Install all 3 skills
npx skills add zxkane/autonomous-dev-team

# Install only the dev workflow skill
npx skills add zxkane/autonomous-dev-team -s autonomous-dev

# Install globally (user-level)
npx skills add zxkane/autonomous-dev-team -g

# Target a specific IDE
npx skills add zxkane/autonomous-dev-team -a cursor
npx skills add zxkane/autonomous-dev-team -a claude-code
npx skills add zxkane/autonomous-dev-team -a kiro
```

---

## 4. Design Details

### 4.1 Merging `github-workflow` + `autonomous-dev`

The merged `autonomous-dev/SKILL.md` has two modes, determined by context:

```markdown
## Mode Detection

This skill operates in two modes:

**Interactive mode** (default): When you are working with a human user in an
IDE/CLI session. Ask for approval at design gates. Present options for decisions.

**Autonomous mode**: When triggered by the `autonomous-dev.sh` wrapper script
or when the prompt contains "Work autonomously" / issue context with
`#<issue-number>`. Make decisions independently. Report progress to the
GitHub issue.
```

**Merged content structure:**

```
SKILL.md
├── Frontmatter (name, description)
├── Mode Detection
├── Cross-Platform Notes (hooks, tools)
├── Workflow Steps 1-13 (from github-workflow, made IDE-agnostic)
│   ├── Step 1: Design Canvas
│   ├── Step 2: Create Git Worktree (mandatory)
│   ├── Step 3: Test Cases (TDD)
│   ├── Step 4: Implementation
│   ├── Step 5: Local Verification
│   ├── Step 6: Code Review (pre-commit)
│   ├── Step 7: Commit and Create PR
│   ├── Step 8: PR Review Agent
│   ├── Step 9: Wait for CI
│   ├── Step 10: Address Reviewer Findings
│   ├── Step 11: Iterate Until No Findings
│   ├── Step 12: E2E Tests
│   └── Step 13: Cleanup Worktree
├── Autonomous Mode Specifics
│   ├── Decision Making Guidelines
│   ├── Resume Awareness
│   ├── Marking Requirements Progress
│   ├── Pre-existing Changes
│   ├── Bot Review Integration
│   └── Error Recovery
└── References
    ├── commit-conventions.md
    └── review-commands.md
```

### 4.2 Cross-Platform Skill Language

All SKILL.md files will use IDE-agnostic language with conditional sections for IDE-specific features.

**Tool name mapping:**

| Current (Claude Code) | Cross-platform language |
|------------------------|------------------------|
| `Bash` tool | "Run in your terminal" / "Execute shell command" |
| `Read` tool | "Read file" |
| `Write` / `Edit` tool | "Create/edit file" |
| `Agent` tool (subagent) | "Use a subagent if available, otherwise follow the steps manually" |
| `Skill` tool | "Load the skill" / "Follow the workflow" |

**Example transformation:**

Before (Claude Code-specific):
```markdown
Run code-simplifier agent:
Use Task tool with subagent_type: code-simplifier:code-simplifier
```

After (cross-platform):
```markdown
Run a code simplification review on the changed files. If your IDE supports
subagents (Claude Code, Kiro), dispatch a code-simplifier agent. Otherwise,
review the diff manually for:
- Unnecessary complexity
- Code duplication
- Unclear naming
```

**CLAUDE.md retains Claude Code-specific syntax** — since `CLAUDE.md` is specifically for Claude Code users, it keeps tool names like `Bash`, `Write`, `Agent`, etc. Only file paths are updated to match the new structure. Cross-platform language goes in `SKILL.md` files and `AGENTS.md`.

### 4.3 Conditional Hooks Support

Each SKILL.md includes a "Workflow Enforcement" section:

```markdown
## Workflow Enforcement (Optional Hooks)

This workflow can be enforced via IDE hooks for hard guardrails. Hooks
block disallowed actions (e.g., committing outside a worktree, pushing
without review).

### Supported IDEs

| IDE/CLI | Hook Support | Setup |
|---------|-------------|-------|
| Claude Code | Full (PreToolUse, PostToolUse, Stop) | See hooks/README.md |
| Kiro CLI | Full (similar hook system) | See hooks/README.md |
| Cursor | No hooks — follow steps manually | Skill instructions only |
| Windsurf | No hooks — follow steps manually | Skill instructions only |
| Gemini CLI | No hooks — follow steps manually | GEMINI.md instructions |

### Without Hooks

If your IDE does not support hooks, the workflow discipline is the same —
you MUST follow each step in order. The difference is enforcement:
- **With hooks**: The IDE blocks you if you skip a step
- **Without hooks**: You are responsible for following the steps

### Hook Installation

Hook scripts are in the `hooks/` directory at the repo root. See
`hooks/README.md` for IDE-specific installation instructions.
```

### 4.4 hooks/README.md

A new file documenting how to set up hooks for each supported IDE. Also documents required plugins for full functionality.

```markdown
# Workflow Enforcement Hooks

## Claude Code

Add to `.claude/settings.json`:
[JSON config example with hooks/ paths]

### Required Plugins

For full workflow support, enable these Claude Code plugins:
- `code-simplifier@claude-plugins-official` — Code simplification review (Step 6)
- `pr-review-toolkit@claude-plugins-official` — PR review agent (Step 8)

## Kiro CLI

Add to `.kiro/settings.json` or equivalent:
[Kiro-specific config]

## Other IDEs

IDEs without hook support rely on skill instructions for workflow
discipline. No additional setup needed.
```

### 4.5 Hook Script Path Updates

All hook scripts move from `.claude/hooks/` to `hooks/`. Updates required:

| Script | Change |
|--------|--------|
| `lib.sh` | No change needed (uses `BASH_SOURCE` for path resolution) |
| `state-manager.sh` | `STATE_DIR` uses new `resolve_state_dir()` from `lib.sh` |
| All `check-*.sh` | Update `source` paths AND user-facing error messages that reference `hooks/state-manager.sh` |
| `.claude/settings.json` | Paths change from `.claude/hooks/xxx.sh` to `hooks/xxx.sh` |

**Specific user-facing message updates** — these scripts embed `.claude/hooks/state-manager.sh` in their `cat >&2` output blocks and must be updated to `hooks/state-manager.sh`:
- `check-code-simplifier.sh` — `.claude/hooks/state-manager.sh mark code-simplifier`
- `check-pr-review.sh` — `.claude/hooks/state-manager.sh mark pr-review`
- `check-unit-tests.sh` — `.claude/hooks/state-manager.sh mark unit-tests`
- `check-design-canvas.sh` — `.claude/hooks/state-manager.sh mark design-canvas`
- `check-test-plan.sh` — `.claude/hooks/state-manager.sh mark test-plan`
- `verify-completion.sh` — `.claude/hooks/state-manager.sh mark e2e-tests`
- `post-git-push.sh` — `.claude/hooks/state-manager.sh mark e2e-tests` (in JSON additionalContext)

**State directory detection logic added to `lib.sh`:**

```bash
resolve_state_dir() {
  local project_root
  project_root=$(resolve_project_root)
  # Prefer IDE-specific state dir if it exists
  if [[ -d "$project_root/.claude/state" ]]; then
    echo "$project_root/.claude/state"
  elif [[ -d "$project_root/.kiro/state" ]]; then
    echo "$project_root/.kiro/state"
  else
    # Default fallback — use .agents/state for IDE-neutral default
    mkdir -p "$project_root/.agents/state"
    echo "$project_root/.agents/state"
  fi
}
```

> Note: The fallback creates `.agents/state/` (not `.claude/state/`) to avoid implying Claude Code to non-Claude users. `.agents/state/` is in `.gitignore`.

### 4.6 AGENTS.md (New File)

The skills.sh CLI reads `AGENTS.md` at repo root for cross-platform agent instructions. This file provides a condensed overview that all agents can understand:

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

### 4.7 .claude/skills Symlink

For backward compatibility with Claude Code's skill discovery (which looks in `.claude/skills/`), create a symlink:

```bash
# .claude/skills -> ../skills
ln -sf ../skills .claude/skills
```

This ensures:
- skills.sh CLI finds skills at `skills/` (standard location)
- Claude Code finds skills at `.claude/skills/` (its native path)
- No duplication of files

**Important**: The existing `.claude/skills/` directory must be fully removed **before** creating the symlink. You cannot create a symlink at a path where a directory already exists. See Phase 2 step 10 in the migration plan.

**Git tracking**: Git tracks symlinks natively. The symlink will be committed to the repository and work on Linux/macOS. On Windows, Git may check out the symlink as a text file containing the target path — this is acceptable since Claude Code on Windows can fall back to reading `skills/` directly.

### 4.8 OpenClaw Dispatcher Migration

`openclaw/skills/autonomous-dispatcher/` moves to `skills/autonomous-dispatcher/`:

- `SKILL.md` moves to `skills/autonomous-dispatcher/SKILL.md`
- `dispatch-local.sh` moves to `scripts/dispatch-local.sh` (alongside other scripts)
- `openclaw/` directory is removed

**Path reference updates in dispatcher SKILL.md**: All `$SKILL_DIR/dispatch-local.sh` references change to `$PROJECT_DIR/scripts/dispatch-local.sh`. The dispatcher SKILL.md currently uses `$SKILL_DIR` (the directory containing SKILL.md) to locate `dispatch-local.sh` co-located with it. After migration, these two files are in different directories, so the SKILL.md must use `$PROJECT_DIR/scripts/dispatch-local.sh` instead. Example:

Before:
```bash
bash "$SKILL_DIR/dispatch-local.sh" dev-new ISSUE_NUM
```

After:
```bash
bash "$PROJECT_DIR/scripts/dispatch-local.sh" dev-new ISSUE_NUM
```

The dispatcher skill's `metadata` field (OpenClaw-specific `requires`) remains in the frontmatter — skills.sh CLI ignores unknown metadata fields, and OpenClaw can still use it.

### 4.9 Skill Frontmatter Updates

Each SKILL.md frontmatter follows the skills.sh specification:

```yaml
---
name: autonomous-dev
description: >
  TDD development workflow with git worktree isolation. Covers design canvas,
  test-first development, code review, CI verification, and E2E testing.
  Supports interactive and fully autonomous modes for GitHub issue implementation.
---
```

Requirements:
- `name`: lowercase, hyphens only
- `description`: clear, covers trigger phrases for skill discovery

### 4.10 README.md Updates

Add a skills.sh installation section near the top:

```markdown
## Install as Skills

Install these skills into any supported coding agent:

\`\`\`bash
npx skills add zxkane/autonomous-dev-team
\`\`\`

Supports 40+ agents including Claude Code, Cursor, Windsurf, Gemini CLI,
Kiro CLI, and more.
```

Update the project structure section to reflect the new layout.

### 4.11 .gitignore Updates

Add these new entries (note: `.claude/state/` already exists in current `.gitignore`):
```
# Claude Code local files
CLAUDE.local.md
*.local.*
.local.json

# Agent state directories (Kiro, generic)
.kiro/state/
.agents/state/
```

### 4.12 autonomous.conf.example Update

Update the `DEV_SKILL_CMD` default from the deprecated skill name:

Before:
```bash
DEV_SKILL_CMD="/github-workflow"
```

After:
```bash
DEV_SKILL_CMD="/autonomous-dev"
```

The `autonomous-dev.sh` wrapper uses `${DEV_SKILL_CMD:-/autonomous-dev}` in its prompt — the default also changes from `/github-workflow` to `/autonomous-dev`.

---

## 5. Migration Plan

### Pre-implementation validation

Before starting migration, verify that skills.sh CLI discovers the expected structure:
```bash
# Create a minimal test structure
mkdir -p /tmp/skills-test/skills/test-skill
echo -e "---\nname: test-skill\ndescription: test\n---\n# Test" > /tmp/skills-test/skills/test-skill/SKILL.md
cd /tmp/skills-test && npx skills add . -l
# Should list "test-skill"
rm -rf /tmp/skills-test
```

If this fails, investigate the skills.sh discovery mechanism before proceeding.

### Phase 1: Move files

1. Move `.claude/hooks/*.sh` → `hooks/*.sh`
2. Move `.claude/skills/github-workflow/references/` → `skills/autonomous-dev/references/`
3. Move `.claude/skills/github-workflow/scripts/resolve-threads.sh` → `scripts/resolve-threads.sh`
4. Move `.claude/skills/github-workflow/scripts/reply-to-comments.sh` → `scripts/reply-to-comments.sh`
5. Move `openclaw/skills/autonomous-dispatcher/SKILL.md` → `skills/autonomous-dispatcher/SKILL.md`
6. Move `openclaw/skills/autonomous-dispatcher/dispatch-local.sh` → `scripts/dispatch-local.sh`
7. Remove `openclaw/` directory

### Phase 2: Rewrite skill content

8. Create merged `skills/autonomous-dev/SKILL.md` (github-workflow + autonomous-dev, cross-platform language)
9. Rewrite `skills/autonomous-review/SKILL.md` with cross-platform language
10. Update `skills/autonomous-dispatcher/SKILL.md` with updated script paths (`$PROJECT_DIR/scripts/dispatch-local.sh`)
11. Remove old `.claude/skills/` directory entirely (github-workflow/, autonomous-dev/, autonomous-review/)
12. Create symlink `.claude/skills` → `../skills`

> **Ordering constraint**: Step 11 (remove directory) MUST happen before step 12 (create symlink). A symlink cannot be created at a path where a directory exists.

### Phase 3: Update infrastructure

13. Update all hook scripts:
    - Fix `source` paths from `.claude/hooks/lib.sh` to `hooks/lib.sh`
    - Fix user-facing error messages that display `hooks/state-manager.sh` paths (see Section 4.5 for full list)
14. Update `state-manager.sh`:
    - Change `STATE_DIR` to use `resolve_state_dir()` from `lib.sh`
    - Add `resolve_state_dir()` function to `lib.sh`
15. Update `.claude/settings.json` — change all hook paths from `.claude/hooks/` to `hooks/`
16. Update `scripts/dispatch-local.sh`:
    - Fix `REPO_ROOT` path calculation from `"${SCRIPT_DIR}/../.."` to `"${SCRIPT_DIR}/.."`
17. Update `scripts/autonomous-dev.sh` — change default `DEV_SKILL_CMD` from `/github-workflow` to `/autonomous-dev`
18. Update `scripts/autonomous.conf.example` — change `DEV_SKILL_CMD="/github-workflow"` to `DEV_SKILL_CMD="/autonomous-dev"`

### Phase 4: Documentation

19. Create `hooks/README.md` with per-IDE setup instructions and required plugins
20. Create `AGENTS.md` at repo root
21. Update `CLAUDE.md`:
    - Update all `hooks/state-manager.sh` path references (6 occurrences of `.claude/hooks/state-manager.sh`)
    - Update skill path references
    - Update project structure section
    - Keep Claude Code-specific tool syntax (`Bash`, `Agent`, etc.)
    - Reference skills at `skills/` (via `.claude/skills` symlink)
22. Update `README.md`:
    - Add skills.sh installation section near top
    - Update project structure to reflect new layout
    - Update all `hooks/state-manager.sh` path references (9 occurrences of `.claude/hooks/state-manager.sh`)
    - Update hook reference table paths
    - Update skill path references
23. Update `docs/autonomous-pipeline.md` — reflect new paths for skills, hooks, and dispatcher

### Phase 5: Validation

24. Verify `npx skills add . -l` lists all 3 skills from repo root
25. Verify Claude Code discovers skills via `.claude/skills` symlink
26. Verify hooks work from new `hooks/` location
27. Verify `state-manager.sh` works with new state directory detection
28. Verify `dispatch-local.sh` works from new location in `scripts/`
29. Test installation: `npx skills add /path/to/repo -a claude-code`
30. Test installation: `npx skills add /path/to/repo -a cursor`

### Rollback Strategy

All changes are made in a feature branch (via worktree). If validation fails at Phase 5:
1. `git revert` the migration commit(s)
2. The original structure is fully preserved since migration uses `git mv` and the original `.claude/skills/` content is in git history
3. Investigate the failure and adjust the approach before reattempting

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Symlink `.claude/skills → ../skills` breaks on Windows | Claude Code on Windows can't find skills | Git checks out symlink as text file; Claude Code can fall back to reading `skills/` directly. Document in README |
| Hook path changes break existing users | Workflow enforcement stops working | Update `.claude/settings.json` in the same commit; clear instructions in migration section of README |
| skills.sh CLI doesn't discover skills in `skills/` subdirectories | Skills not installable | Pre-implementation validation step verifies discovery. The CLI searches `skills/<name>/SKILL.md` by default |
| Cross-platform SKILL.md is too generic | Loses Claude Code-specific power (hooks, subagents) | Use conditional sections: "If your IDE supports X, do Y. Otherwise, do Z." CLAUDE.md retains Claude-specific syntax |
| OpenClaw users expect `openclaw/skills/` path | Dispatcher skill not found by OpenClaw | Update OpenClaw cron command path to `skills/autonomous-dispatcher/SKILL.md` |
| Large merged SKILL.md overwhelms context | Agent performance degrades with huge skill file | Keep skill concise — use references/ for supplementary docs, link to repo docs for details |
| `$SKILL_DIR/dispatch-local.sh` pattern breaks in dispatcher | Dispatch commands fail | Explicitly change to `$PROJECT_DIR/scripts/dispatch-local.sh` in SKILL.md |

---

## 7. Success Criteria

1. `npx skills add zxkane/autonomous-dev-team` successfully installs all 3 skills
2. Skills appear on the [skills.sh leaderboard](https://skills.sh) after first installations
3. Claude Code users can use skills via `.claude/skills` symlink with full hook enforcement
4. Cursor/Windsurf users get the skill instructions (without hook enforcement)
5. Kiro CLI users get skills with hook enforcement (where Kiro supports hooks)
6. Existing autonomous pipeline (`autonomous-dev.sh`, `autonomous-review.sh`, dispatcher) continues to work with new paths
7. All hook scripts function correctly from new `hooks/` location

---

## 8. Out of Scope

- Rewriting hook scripts in a non-bash language
- Creating a standalone npm package for the skills
- Building a skills.sh marketplace web page for this repo
- Adding new skills beyond the 3 defined above
- Modifying the autonomous pipeline logic (only paths change)
- Supporting IDEs that cannot read markdown skill files
