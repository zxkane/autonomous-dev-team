# Design Canvas — Skill Quality Polish (PR-10)

**Branch**: `feat/skill-polish`
**Closes**: nothing (no specific issue — quality cleanup driven by skill-reviewer findings).
**Pipeline-docs touched**: none — skills only.

---

## Why

Ran the `skill-reviewer` agent against all 5 skills. Pattern: descriptions across the board are imprecise (don't trigger on the actual user phrasings users send), and there are several packaging-fragility issues that will break for users who install via `npx skills add` (which copies only the skill dir, not the project's `docs/` or hooks symlinks).

Below is the per-skill plan. Behavior changes are limited to **what the skill does on cold load** (description triggers + reference paths). No actual workflow logic changes.

## Per-skill changes

### 1. `autonomous-common`

**Findings:**
- Description targets the wrong audience (says "loaded automatically as background context", but skill-discovery doesn't auto-load sibling skills).
- Frontmatter has a fake field `user-invocable: false` (not a real schema field).
- Hook-and-script tables duplicate `hooks/README.md`.

**Fixes:**
- Rewrite description to trigger on real user-facing tasks: "hooks failing", "what does check-pr-review.sh do", "after `npx skills add`, push hook not running", configuring the symlink workaround.
- Drop `user-invocable: false`.
- Replace the two tables with a one-line "see hooks/README.md" pointer.

### 2. `autonomous-dev`

**Findings:**
- 480 lines — borderline too long. Three sections are how-to detail belonging in `references/`.
- Description doesn't trigger on "implement a GitHub issue end-to-end" / "autonomous mode" — half the skill's purpose.
- "NON-NEGOTIABLE RULES" callout uses second-person imperative; convention is infinitive.

**Fixes:**
- Extract "Pencil MCP Workflow" + template (lines 164-184) → `references/design-canvas.md`.
- Extract Step 10 "Reviewer Bot Findings" tables (lines 391-425) → already exists in `references/review-threads.md`; replace with pointer.
- Extract "Cross-Platform Notes" + "Tool Name Mapping" → `references/cross-platform.md`.
- Add to description: explicit "implement a GitHub issue", "autonomous mode", "unattended" triggers.
- Rewrite the bold callout in infinitive form.
- Target ~300 lines.

### 3. `autonomous-dispatcher`

**Findings:**
- Description omits the multi-project / SSM / `EXECUTION_BACKEND` triggers introduced by PR-7/8/9.
- Body links use `../../docs/pipeline/` paths that don't survive `npx skills add`.
- Frontmatter `metadata` block is a non-standard OpenClaw-only field — most agents ignore.

**Fixes:**
- Description gains: "multi-project dispatcher", "remote-aws-ssm", "EXECUTION_BACKEND", "dispatcher.conf", "dispatch to a remote dev box".
- Replace `../../docs/pipeline/` links with absolute GitHub URLs (`https://github.com/zxkane/autonomous-dev-team/blob/main/docs/pipeline/...`).
- Move the OpenClaw `metadata` block into a body-level "Prerequisites" section; drop from frontmatter.

### 4. `autonomous-review`

**Findings:**
- Description doesn't tie to the dispatcher trigger (`pending-review` label).
- Body opening "You are reviewing a PR..." is second-person; convention is imperative/declarative.
- Missing "When to Use / When Not to Use" — competes with autonomous-dev's PR-review step.
- The `gh-as-user.sh`-required rule for bot-reviewer triggers is buried in a blockquote.

**Fixes:**
- Description adds: "PR labeled for autonomous review", "decide to approve or send back for fixes".
- Rewrite body opening in imperative form.
- Add a "When to Use" 4-line section right after the title.
- Promote `gh-as-user.sh` rule to its own subsection.

### 5. `create-issue`

**Findings (low-impact only — skill is in good shape):**
- Description's trigger list is bloated with overlapping phrasing and "create a task" is ambiguous.
- "Step 2.5" breaks the linear 1-4 numbering.

**Fixes:**
- Tighten trigger list to 4-5 distinct phrasings; remove "create a task".
- Renumber "Step 2.5" to "Step 3" and shift the rest down.

## Packaging fragility audit (cross-cutting)

These issues hit any user who installs via `npx skills add` (skills.sh model: only the skill dir is copied, NOT `docs/`, `hooks/`, or repo-root symlinks):

| Skill | Fragile reference | Fix |
|---|---|---|
| autonomous-dispatcher | `../../docs/pipeline/...` (5+ links) | Absolute GitHub URLs |
| autonomous-dev | `references/...` (already in skill dir — OK) | unchanged |
| autonomous-review | `references/...` (already in skill dir — OK) | unchanged |
| autonomous-common | `hooks/README.md` (in skill dir — OK) | unchanged |

The hook-config blocks in `autonomous-dev` and `autonomous-review` frontmatter use `$CLAUDE_PROJECT_DIR/hooks/...`. After `npx skills add`, hooks live at `$CLAUDE_PROJECT_DIR/.claude/skills/autonomous-common/hooks/...`. The autonomous-common SKILL.md already documents the symlink workaround for this — keep that documentation but make it more prominent (move into the description triggers so it shows up when a user reports "hooks not running").

## What's explicitly NOT changing

- Workflow logic in any skill (the steps themselves stay the same).
- `references/*.md` content (pulling content INTO references is fine; rewriting existing references is out of scope).
- Hook scripts in `skills/autonomous-common/hooks/` — no behavior changes.
- Project-level `docs/pipeline/` — already accurate, just unreachable post-install for autonomous-dispatcher.

## Risk

Low. Description rewrites change skill triggering — an agent might match different user phrasings than before. Mitigation: keep all old triggers + add new ones (don't remove). The structural extraction in autonomous-dev preserves all content (just moves it).

## Tests

No code logic changes → no new unit tests. The existing 24 test files must continue to pass (they don't reference SKILL.md content). Verify all green before push.
