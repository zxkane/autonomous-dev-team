# Contributing

Thanks for working on `autonomous-dev-team`. Two rules drive how we ship changes here.

## Rule 1: Flow first, code second

This project's job is to coordinate three autonomous agents (dispatcher, dev, review) through a shared GitHub-issue label state machine. Bugs in this kind of system come from the seams between components, not from any one component in isolation. Every bug we have shipped a fix for in the dispatcher / wrappers traced back to a state-machine corner that was implicit in code but undocumented.

To stop that pattern: **any change to pipeline behavior MUST update [`docs/pipeline/`](docs/pipeline/) before — or in the same PR as — the code change.**

### What "pipeline behavior" means

A change is a pipeline-behavior change if it touches any of:

- `skills/autonomous-dispatcher/scripts/**/*.sh` (recursive — any depth)
- `skills/autonomous-dev/scripts/**/*.sh` (recursive)
- `skills/autonomous-review/scripts/**/*.sh` (recursive)
- `skills/autonomous-common/hooks/**/*.sh` (recursive)
- `skills/autonomous-common/scripts/**/*.sh` (recursive)
- `skills/autonomous-{dispatcher,dev,review,common}/SKILL.md`

(The `**` glob notation is for human readability — the CI gate uses an equivalent ERE regex with `.*` which matches across directory separators, so subdirectories of `scripts/` and `hooks/` are correctly covered.)

If your PR diff touches any of those paths, it MUST also touch one or more files under `docs/pipeline/`. CI enforces this — see [`.github/workflows/pipeline-docs-gate.yml`](.github/workflows/pipeline-docs-gate.yml).

### What to write in `docs/pipeline/`

Pick the right file:

| If your change is about… | Update… |
|---|---|
| A label transition or a new state | `state-machine.md` |
| A dispatcher cron-tick step | `dispatcher-flow.md` |
| The dev wrapper lifecycle, prompt, or trap | `dev-agent-flow.md` |
| The review wrapper lifecycle, decision gate, or trailer | `review-agent-flow.md` |
| A handoff between two actors (e.g. dev → review) | `handoffs.md` |
| A new cross-cutting rule discovered while debugging | `invariants.md` (add a new `INV-NN`) |

If your change spans more than one of the above, update each.

### Discovered a new invariant? Write it down.

Most pipeline bugs surface a previously-implicit invariant. After fixing the bug, add the rule to [`docs/pipeline/invariants.md`](docs/pipeline/invariants.md) under a new `INV-NN` ID, with:

- One-sentence rule
- The bug that motivated it (link the issue / PR)
- Producer (which actor must uphold it) and consumer (which actor relies on it)
- Where it's tested (or "TODO: add test")

### Editing or adding mermaid diagrams

`docs/pipeline/` uses mermaid for state machines, sequence diagrams, and flowcharts. **A mermaid block that fails to parse renders as a giant red error box on github.com — this looks worse than no diagram at all.** GitHub renders mermaid client-side via mermaid 10.x; the only reliable validation is to push to a branch and look at the rendered file on github.com. `bash -n`, fence-pair counting, and prose review will all pass on broken diagrams.

#### Three syntax landmines to avoid

These caused 5 of 7 mermaid blocks to fail in the first commit of PR-2 ([#66](https://github.com/zxkane/autonomous-dev-team/pull/66)):

1. **No `;` inside `stateDiagram-v2` edge labels or `sequenceDiagram` message text.** Mermaid treats `;` as a statement separator, so `agent runs; eventually exits` parses as two messages and the second one has no arrow. Use `,` or `-` or rephrase.

2. **In `stateDiagram-v2` edge labels, literal `\n` is the two characters `\n`, not a line break.** It does NOT render as a newline. Either use `<br/>` (which works in flowchart but is hit-or-miss in stateDiagram) or just remove the line break and write a one-line label. `flowchart` blocks tolerate `<br/>` reliably; prefer that there.

3. **No double quotes `"..."` inside flowchart `[]` node labels.** The inner `"` confuses the parser. Use single quotes `'...'`, or rephrase to avoid the quote entirely. Example: `[comment "exited 0 but no PR"]` → `[comment 'exited 0 but no PR']`.

Side notes: `≥`, `≠`, `⇒` (Unicode comparison/arrow chars) render fine. Parens around words are fine (`[Step 1<br/>concurrency cap?]`). The Unicode minus `−` in node labels is fine but `+` and `=` adjacent to identifiers can confuse the parser — write the words `add`/`remove` if in doubt.

#### Validation procedure (mandatory for any PR that adds or edits a mermaid block)

1. Push your branch to GitHub.
2. Compute the head SHA: `gh pr view <N> --json headRefOid -q .headRefOid` (or use the commit SHA if PR isn't open yet).
3. For each `*.md` you touched that contains a mermaid block, open `https://github.com/<owner>/<repo>/blob/<sha>/<path>.md` in a browser.
4. Confirm each mermaid block renders as a diagram (not a red "Parse error on line N" box). The rendered block has buttons "Open dialog" and "Copy mermaid code" beneath it.
5. If using Claude Code with the chrome-devtools MCP installed, `mcp__chrome-devtools__new_page` + `wait_for(["Parse error", "<a heading after the block>"])` automates this — see [PR #66](https://github.com/zxkane/autonomous-dev-team/pull/66) discussion for the playbook.

If a block fails, fix it locally, push again, re-verify. Do NOT merge a PR with a broken mermaid block visible on github.com.

### Escape hatch: `pipeline-docs:none` label

Some PRs legitimately don't change pipeline behavior even though they touch a watched path:

- Typo / formatting fix in a comment
- Dependency bump
- CI workflow tweak that happens to live under a watched path
- Pure refactor with no observable behavior change (rare — usually still a `state-machine.md` line)

For those, apply the `pipeline-docs:none` label to the PR. The CI gate will skip the docs-required check. The label is auditable in PR list views, so a reviewer can ask "are you sure?".

If `pipeline-docs:none` doesn't yet exist in the repo, a maintainer can create it once with:

```bash
gh label create pipeline-docs:none \
  --description "Explicitly attests this PR has no pipeline behavior change" \
  --color d4c5f9
```

### Worked example

Fixing the "MERGED PRs treated as open dependencies" bug (#61):

1. **First**: edit [`docs/pipeline/dispatcher-flow.md`](docs/pipeline/dispatcher-flow.md) Step 2 to clarify dep-check accepts both `CLOSED` and `MERGED`.
2. Add a new invariant `INV-11: Dependency state includes MERGED` to [`docs/pipeline/invariants.md`](docs/pipeline/invariants.md).
3. **Then**: change the script to match the documented behavior.
4. Open the PR. CI gate sees both `skills/.../scripts/*.sh` and `docs/pipeline/*.md` in the diff → passes.

If you change the script first and the docs after, that's fine too — they just have to land in the same PR. CI checks the PR diff, not the per-commit ordering.

## Rule 2: Use the `autonomous-dev` workflow on yourself

This repo's TDD + worktree + review-bot discipline is documented in [`CLAUDE.md`](CLAUDE.md) and the [`autonomous-dev`](skills/autonomous-dev/SKILL.md) skill. Use them when contributing here. The hooks in `.claude/settings.json` will block:

- Commits outside `.worktrees/`
- Pushes directly to `main`
- Pushes when behind `origin/main`

Don't bypass with `--no-verify`. If a hook fires, fix the underlying issue.

## PR checklist

Before opening a PR, confirm:

- [ ] Worktree under `.worktrees/<branch>/` (not the main checkout)
- [ ] Design canvas at `docs/designs/<feature>.md` (for non-trivial changes)
- [ ] Pipeline docs synced (Rule 1) OR `pipeline-docs:none` label applied
- [ ] Local tests pass (`bash -n` on changed shell scripts at minimum; shellcheck if installed)
- [ ] If the PR adds or edits any mermaid block, every block was visually verified on github.com (see "Editing or adding mermaid diagrams" above)
- [ ] `Closes #N` in the PR body if it fixes an open issue
- [ ] Conventional-commit-style PR title (`fix(dispatcher): ...`, `docs(pipeline): ...`, etc.)

Reviewers will check Rule 1 first. Save yourself the round-trip.
