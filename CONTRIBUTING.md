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

4. **Avoid `<br/>` inside `sequenceDiagram` message text and minimize `<br/>` count in flowchart `[]` node labels.** This is a *runtime layout error*, not a parse error: the d3-curve label-placement pass throws *"Could not find a suitable point for the given distance"* and the diagram renders as an empty box on github.com. The failure is non-deterministic across feature branches vs. main (different cache/build of GitHub's mermaid renderer), so it's possible for a PR review to show all blocks rendering fine and then break after merge — that exact regression is what surfaced this rule ([PR #66](https://github.com/zxkane/autonomous-dev-team/pull/66) post-merge). Prefer single-line message and node labels; if a label feels too long, restate the detail in the prose immediately after the diagram.

Side notes: `≥`, `≠`, `⇒` (Unicode comparison/arrow chars) render fine. Parens around words are fine (`[Step 1<br/>concurrency cap?]`). The Unicode minus `−` in node labels is fine but `+` and `=` adjacent to identifiers can confuse the parser — write the words `add`/`remove` if in doubt.

#### Validation procedure (mandatory for any PR that adds or edits a mermaid block)

1. Push your branch to GitHub.
2. Compute the head SHA: `gh pr view <N> --json headRefOid -q .headRefOid` (or use the commit SHA if PR isn't open yet).
3. For each `*.md` you touched that contains a mermaid block, open `https://github.com/<owner>/<repo>/blob/<sha>/<path>.md` in a browser.
4. Confirm each mermaid block renders as a diagram (not a red "Parse error on line N" box). The rendered block has buttons "Open dialog" and "Copy mermaid code" beneath it.
5. If using Claude Code with the chrome-devtools MCP installed, `mcp__chrome-devtools__new_page` + `wait_for(["Parse error", "<a heading after the block>"])` automates this — see [PR #66](https://github.com/zxkane/autonomous-dev-team/pull/66) discussion for the playbook.

If a block fails, fix it locally, push again, re-verify. Do NOT merge a PR with a broken mermaid block visible on github.com.

**After merge, re-verify on `main`.** GitHub's mermaid renderer (`viewscreen.githubusercontent.com`) caches per ref, and feature-branch and main caches can hit different mermaid builds. A block that renders fine on the PR head can break on main (rule 4 above is the symptom this exposes). Open `https://github.com/<owner>/<repo>/blob/main/<path>.md` once the merge lands.

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

## What CI runs on your PR

CI is split into two tiers ([`ci.yml`](.github/workflows/ci.yml),
[INV-77](docs/pipeline/invariants.md#inv-77-ci-is-two-tiers--hermetic-always-on--credential-free-live-agent-smoke-is-self-hosted-label-gated-and-advisory)):

### Tier 1 — hermetic (always on, no credentials)

Every PR and push runs the `hermetic-*` jobs on GitHub-hosted `ubuntu-latest`
with **zero credentials**:

- `hermetic-unit` — all `tests/unit/*.sh`, the adapter
  [conformance suite](tests/conformance/README.md), and the stub-mode self-tests
  of the smoke / metrics / error-envelope harnesses.
- `hermetic-shellcheck` — ShellCheck over the dispatcher scripts + `actionlint`
  over the workflows.

Because the hermetic tier needs no secrets, **a fork PR or external contribution
gets a fully green, fully meaningful CI** — you do not need any agent CLI auth to
pass CI. These are the checks that gate merge (branch-protection required).

### Tier 2 — live agent-smoke (self-hosted, maintainer-gated, advisory)

The `live-smoke` job runs the [#222 live agent-CLI smoke matrix](docs/pipeline/agent-smoke.md)
against **real** CLIs (claude/codex/kiro/agy) on the self-hosted runner. It runs
**only** when:

- a **maintainer applies the `run-live-smoke` label** to the PR (label
  application requires write access — that IS the authorization), **or**
- the change is pushed to `main`.

A fork PR cannot trigger the live tier on its own (no label = not scheduled),
because a self-hosted runner must never execute untrusted PR code unconditionally.
The live tier is **advisory (non-required)** — a quota-walled CLI reports
`UNAVAILABLE` without failing the job, and the live result never blocks merge. Its
SMOKE evidence is posted to the run's job summary.

**As an external contributor you never need to do anything for the live tier** —
a maintainer will label your PR if a live run is warranted.

> **Maintainer one-time setup:** the live matrix config must live **outside** the
> repo checkout (because `actions/checkout` runs `git clean -ffdx` and would delete
> a checkout-internal `tests/e2e/e2e.conf`).
>
> > ⚠️ **Seed it only from a TRUSTED template — never from this PR's checkout.** On
> > a labeled fork PR the checked-out `tests/e2e/e2e.conf.example` is attacker head
> > content, and `run-agent-smoke.sh` `eval`s each entry's `env-setup` on the
> > self-hosted runner — so copying the *checkout* copy can persist arbitrary shell
> > on the runner. Always fetch the template from `main` (`?ref=main`) or a local
> > trusted clone, **review it**, then seed.
>
> Provide it via one of, in precedence order:
>
> 1. **`SMOKE_MATRIX` repo variable (recommended)** — set it to the matrix
>    *content*; the `live-smoke` job materializes it to a temp file at job time, so
>    it works on the **autoscaling self-hosted pool** (a per-box file does not
>    survive pool churn). Maintainer-only; must not carry secrets (Bedrock entries
>    use the runner instance role). Seed from the template on `main`, review, set:
>    ```bash
>    gh api repos/<owner>/<repo>/contents/tests/e2e/e2e.conf.example?ref=main \
>      --jq '.content' | base64 -d > /tmp/smoke-matrix.tmpl   # review + edit, then:
>    gh variable set SMOKE_MATRIX --repo <owner>/<repo> --body-file /tmp/smoke-matrix.tmpl
>    ```
> 2. **`RUNNER_SMOKE_CONF` repo variable** — a PATH to a runner-local matrix file.
> 3. **A per-box file** for a pinned, long-lived runner, seeded from `main` (not the
>    checkout): `gh api repos/<owner>/<repo>/contents/tests/e2e/e2e.conf.example?ref=main --jq '.content' | base64 -d > "$HOME/.config/autonomous-dev-team/e2e.conf"` then review + edit.
>
> The `live-smoke` job preflights this and fails with a provisioning pointer
> (naming all three sources) if none resolve. An **always-on `live-smoke-status`
> job** also writes a non-failing summary on every PR so an unlabeled PR clearly
> shows the live tier was intentionally skipped pending a maintainer label.

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
