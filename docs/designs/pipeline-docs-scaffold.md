# Pipeline docs scaffold + workflow-first CI gate

Closes nothing on its own — sets up the structure for future bug-fix and feature PRs to follow a "update flow doc, then change code" discipline.

## Problem

Recent dispatcher / dev / review bug fixes (#41, #44, #50, #53, #54, #55, #56, #57, plus open #58–#62) share a common pattern: each fix had to re-derive the full state machine from `SKILL.md` + scattered `### Step 5b` comments + wrapper trap code, and several fixes only patched the symptom on one branch of the state machine without updating the others.

There is no single authoritative document that describes:

- The label state machine for an `autonomous` issue
- The dispatcher's per-tick algorithm
- The dev-agent / review-agent wrapper lifecycle (trap, cleanup, retries)
- The five handoff points between the three agents (and their invariants)

Result: regression-prone fixes, hard onboarding, and a 438-line dispatcher SKILL.md where >50% of the body is bash code blocks the agent re-types verbatim.

## Goal

Set up structure for a flow-first contribution discipline — without changing any pipeline code yet. Two follow-up PRs (PR-2 fills in the docs, PR-3 slims the dispatcher SKILL.md by extracting bash to scripts) build on this scaffold.

## What this PR ships

1. **`docs/pipeline/` skeleton** — README index + 6 stub files (state-machine, dispatcher-flow, dev-agent-flow, review-agent-flow, handoffs, invariants). Stubs only; PR-2 fills them.

2. **`CONTRIBUTING.md`** — explicit "update pipeline docs before / alongside scripts" rule. Defines:
   - Trigger paths (which paths in a PR force the rule)
   - Exemptions (typo / formatting only)
   - Escape hatch (`pipeline-docs:none` PR label for explicit no-flow-change PRs, e.g. CI tweaks)

3. **`.github/workflows/pipeline-docs-gate.yml`** — CI hard gate. Fails the PR check if it touches any of:
   - `skills/autonomous-dispatcher/scripts/`
   - `skills/autonomous-dev/scripts/` (if/when added)
   - `skills/autonomous-review/scripts/` (if/when added)
   - `skills/autonomous-common/hooks/`
   - `skills/autonomous-common/scripts/`
   - `skills/autonomous-{dispatcher,dev,review,common}/SKILL.md`

   …without also touching `docs/pipeline/` OR carrying the `pipeline-docs:none` label.

4. **`.github/pull_request_template.md`** — adds a checkbox surfacing the rule to PR authors.

## Non-goals

- Filling in the actual pipeline docs (PR-2)
- Refactoring SKILL.md or scripts (PR-3+)
- Changing any current pipeline behavior

## Design decisions

### Why a separate `docs/pipeline/` directory and not extending `docs/autonomous-pipeline.md`?

The existing `autonomous-pipeline.md` is an overview / quick-start. The new docs are normative state-machine references that will grow as bugs surface invariants. Separate dir keeps overview vs. spec-grade docs distinct, and lets the CI gate watch a focused path glob.

The existing `docs/autonomous-pipeline.md` stays — PR-2 will add a "see `docs/pipeline/` for the authoritative state machine" pointer at its top.

### Why a hard CI gate and not a soft hook?

The user picked **hard** (CI block) over soft (PR template only) and medium (pre-push warning) explicitly. Rationale: the bug stream this is meant to prevent has shipped via PRs whose authors clearly *did* understand the state machine they were touching but had no incentive to write it down. A blocking gate forces the writeup.

### Escape hatch design

`pipeline-docs:none` label, applied by PR author. Rationale:

- Some PRs legitimately don't touch flow (e.g. typo in a comment, dependency bumps, CI-only changes that happen to be under a watched path).
- Keeping the override visible (a label, not a magic commit-message tag) makes the bypass auditable in PR list views.
- A reviewer who sees the label has explicit context to ask "are you sure?".

Alternative considered: skip-via-commit-message (e.g. `[skip pipeline-docs]`). Rejected — invisible in the PR card, and the workflow would still need to parse commits.

### Why include SKILL.md in the watched paths?

The whole point of PR-3 is to move logic *out of* SKILL.md into scripts. But until then, SKILL.md still contains the state machine. Touching it without updating `docs/pipeline/` is exactly the failure mode this gate prevents.

Once PR-3 lands and SKILL.md is thin prose only, the gate can drop SKILL.md from the watched glob — but that's a future tweak.

### Watched paths — rationale for each

| Path | Why watched |
|---|---|
| `skills/autonomous-dispatcher/scripts/*.sh` | All the wrapper / dispatch / lib-* scripts. Any change here is a state-machine change. |
| `skills/autonomous-common/hooks/*.sh` | Workflow-enforcement hooks. Changes affect dev-agent flow. |
| `skills/autonomous-common/scripts/*.sh` | mark-issue-checkbox / reply-to-comments / resolve-threads — all participate in the dev-agent's PR lifecycle. |
| `skills/autonomous-{dispatcher,dev,review,common}/SKILL.md` | Until PR-3, SKILL.md *is* the state machine. |

Not watched (intentionally):

- `skills/create-issue/` — issue-authoring helper, not part of the dispatch loop.
- `skills/autonomous-*/references/` — long-form prose only, no behavior.
- `docs/` (anywhere) — these are the docs themselves.
- `.github/`, `*.example`, `package.json`, etc.

## Validation plan

- `markdownlint` on the new files (project doesn't use it today, so just visual check).
- Open this PR and confirm the `pipeline-docs-gate` job *passes* (this PR adds docs and modifies no scripts → no gate trigger needed; but if the gate runs at all it should be green).
- Open a quick test PR with a no-op edit to `skills/autonomous-dispatcher/scripts/setup-labels.sh` and no docs change → confirm the gate fails. Then add the `pipeline-docs:none` label → confirm it passes. (Done in a throwaway branch, not landed.)

## Risk

Low. No code change, no behavior change. Only risk is a too-strict gate that annoys future authors — mitigated by the `pipeline-docs:none` label.
