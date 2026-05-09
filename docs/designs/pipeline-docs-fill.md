# Fill in pipeline docs (PR-2)

Closes nothing on its own — fills the 6 stubs created in PR-1 (#63) so they describe the *current* pipeline behavior. PR-3 onward can then use these docs as the contract to refactor against.

## Scope

Strictly docs-only. Zero changes to:

- `skills/**/*.sh` or `skills/**/SKILL.md`
- `.github/workflows/`
- Any other code or config

What gets edited:

- `docs/pipeline/state-machine.md` — full state-machine reference
- `docs/pipeline/dispatcher-flow.md` — per-tick dispatcher steps
- `docs/pipeline/dev-agent-flow.md` — dev wrapper lifecycle
- `docs/pipeline/review-agent-flow.md` — review wrapper lifecycle
- `docs/pipeline/handoffs.md` — 5 handoff points + invariants
- `docs/pipeline/invariants.md` — INV-01..INV-15 (INV-15 added in fix commit after code review surfaced the SIGTERM race contradiction)
- `docs/pipeline/README.md` — flip status column from "Stub" to "Done"
- `docs/autonomous-pipeline.md` — add a pointer to `docs/pipeline/`
- `CONTRIBUTING.md` — add a "Editing or adding mermaid diagrams" sub-section under Rule 1, documenting the 3 syntax landmines (semicolons, literal `\n` in stateDiagram, double quotes in flowchart node labels) and the github.com-visual-check validation procedure. **Added in-flight after this PR's first push surfaced 5 of 7 mermaid blocks failing to render** — keeping the lesson where future contributors will see it.

## Source of truth

The current pipeline behavior is the union of:

- `skills/autonomous-dispatcher/SKILL.md` (the prompt the dispatcher agent reads + executes)
- `skills/autonomous-dispatcher/scripts/dispatch-local.sh` (kill-stale-wrapper logic)
- `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` (dev wrapper)
- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` (review wrapper)
- `skills/autonomous-dispatcher/scripts/lib-agent.sh` (run/resume agent + acquire_pid_guard)
- `skills/autonomous-dispatcher/scripts/lib-auth.sh` (token lifecycle)
- `skills/autonomous-dev/SKILL.md` (dev-agent skill the wrapper invokes)
- `skills/autonomous-review/SKILL.md` (review-agent skill the wrapper invokes)

Plus the bug-fix design docs under `docs/designs/` and the closed-issue history (#41..#57).

## Approach

1. Read everything above end-to-end.
2. Extract one canonical reference of: every label, every transition, every actor, every comment phrase, every invariant (a worksheet — not committed).
3. Fill the 6 stubs from that worksheet.
4. Each invariant cites the bug it exists to prevent.
5. Each flow doc cross-references the relevant invariants by ID, not by restating them.
6. Mermaid diagrams where they add clarity (state-machine, dispatcher tick, dev/review lifecycles, handoffs).

## Non-goals

- Inventing new behavior. If the existing code is wrong, that's a PR-3 / PR-4 / PR-5 problem — write down what *is*, not what *should be*. (Three invariants — INV-12, INV-13, INV-14 — describe behavior the code does NOT yet guarantee, but the open issues #58, #59, #60 already track those gaps; the doc clearly marks those as "scheduled for PR-N".)
- Slimming the SKILL.md. That's PR-3.
- Fixing typos in old design docs.

## Validation

- Mermaid syntax check (paste each block into mermaid live editor, or use `mermaid-cli` if available).
- All cross-document links resolve (relative-link sweep).
- Spot-check: pick one open bug (#61 MERGED-not-CLOSED) and verify the corresponding flow doc + invariant entry would let a future contributor understand the bug without reading the code.
- Run `pr-review-toolkit:code-reviewer` for self-consistency between docs.

## Risk

Very low. Docs-only. The only failure mode is "docs say something the code doesn't do" — mitigated by deriving every claim directly from the code path, citing the file/line where the behavior lives.
