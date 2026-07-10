# Acceptance-Criteria Verification Surfaces

How to write acceptance criteria (ACs) that the autonomous dev/review loop can
actually close — by separating ACs that are verifiable **before merge** from
those that genuinely are not, and naming exactly where each one is checked.

> **Why this matters (loop prevention).** A blocking AC that the dev/review
> agents cannot satisfy pre-merge — no PR-stage verification path, or it requires
> a permission/action the bot lacks (e.g. editing the PR body, rotating a prod
> artifact) — is a **known driver of non-terminating dev↔review loops**. The dev
> agent reports each round "this is inherently post-merge", the reviewer keeps the
> issue blocked, and the dispatcher re-dispatches dev→review on an unchanged HEAD
> until a maintainer intervenes. This is a *contributing cause* of such loops, not
> a guarantee they hang — but it is the cheapest one to prevent, and the place to
> prevent it is **at issue-creation time**, by pointing the AC at the right
> verification surface.

---

## 1. Classification rubric: is each AC *pre-merge verifiable*?

For **every** acceptance criterion, classify it:

### Pre-merge verifiable — PREFER THIS

The evidence that the criterion is met can be obtained **before the PR merges**,
from a surface the dev/review agents can reach:

- a **CI job** on the PR (unit/integration/lint/build),
- a **PR-preview URL** (deploy-preview / ephemeral environment),
- a **staging command** runnable against a pre-merge build,
- a **local repro** the agent can run in the worktree.

For a pre-merge-verifiable AC you MUST **name the surface and the expected
evidence**, not just assert the outcome. Write *where* it is checked and *what
proves it*:

- ❌ "The importer handles malformed rows." (no surface)
- ✅ "`npm run test:unit` covers malformed-row handling; expected evidence: the
  new `TC-IMPORT-007` case green in the CI `unit` job."
- ✅ "Verified on the PR-preview URL (Vercel deploy-preview): uploading
  `fixtures/bad.csv` shows the row-level error toast. Expected evidence:
  screenshot attached to the PR / preview E2E `import-errors.spec.ts` green."

### Not pre-merge verifiable

The criterion **cannot** produce its evidence until after merge, because it needs:

- a **deploy** to a real/prod environment (post-merge artifact, prod replay),
- **real users / live traffic**,
- a **time soak** (bake period, rollout window, multi-day metric),
- an **external approval** (human approver, compliance sign-off),
- **prod telemetry** (dashboards/metrics only emitted in production),
- **credentials the bot lacks** (prod secrets, rotation keys).

> "post-merge / prod-only" is the **headline example** of this category, not the
> whole of it. Credential-, approval-, telemetry-, and time-gated criteria are
> equally not-pre-merge-verifiable even when nothing about them says "after merge".

---

## 2. Before inventing a post-merge replay — reuse an existing pre-merge surface

Most criteria framed as "verify by replaying through the deployed pipeline" are
**actually pre-merge verifiable** — the project already has a PR-preview or
staging path that exercises the **same code path** with the **same input**, and
the AC simply didn't reference it.

Before writing a post-merge replay, check whether such a path exists:

1. Does CI / the PR-preview already build the changed artifact and run it?
2. Is there an E2E or integration lane that hits the same code path with the same
   (or fixture-equivalent) input?
3. Can the criterion be expressed against that existing surface instead?

If yes → reframe the AC to **name that existing surface** (CI job name, preview
URL source, staging command) and the expected evidence. Do **not** invent a manual
post-merge replay for something an existing pre-merge lane already covers.

---

## 3. If a criterion really is not pre-merge verifiable — split it out

A genuinely post-merge / prod-only criterion MUST NOT remain a **blocking** AC on
a PR-verifiable issue. Split it into a separate follow-up issue, kept
**non-blocking** on the primary issue's close.

Procedure (order matters — loop-prevention critical):

1. **Create the post-merge follow-up issue FIRST**, so its `#N` exists before you
   reference it. Title it e.g. `Post-deploy verify: <criterion>`.
2. **Do NOT add the `autonomous` label to the follow-up.** An autonomous follow-up
   just relocates the non-terminating loop — the dev agent still cannot satisfy a
   post-merge criterion pre-merge. The follow-up is a human/ops verification task.
3. **Reference the follow-up from the primary issue under `## Out of Scope`** (or
   in prose). **Do NOT list it under `## Dependencies`.** Any open `#N` in the
   primary issue's `## Dependencies` is a **hard blocker** (the dispatcher silently
   skips the issue until that ref closes) — listing the follow-up there would
   re-create a stuck issue, the exact opposite of a non-blocking split.

So: follow-up created first → no `autonomous` label → referenced under Out of
Scope, never under Dependencies. The primary issue keeps only the pre-merge ACs
and stays closeable by the loop.

### `no-auto-close` is NOT a workaround for this

The `no-auto-close` label stops the **merge** (the wrapper posts the approval and
marks the PR approved, then leaves the merge to a human). It does **not** relax the
review gate: a blocking not-pre-merge AC still **fails the review gate**, so the PR
never reaches the approved state in the first place, and the loop is unchanged.
`no-auto-close` is for "AI develops + reviews but a human merges", not for parking
an unsatisfiable AC. **Split the AC instead.**

---

## 4. Worked examples

### Example 1 — post-merge replay reframed to the PR-preview E2E path

A bugfix to the ingestion parser. The change is fully verifiable pre-merge: the
project already has a PR-preview E2E lane that builds the change's artifact and
exercises the exact same parser against the same fixture input.

**Mistaken (blocking, not pre-merge verifiable):**

```markdown
## Acceptance Criteria
- [ ] Verified by a post-merge replay of yesterday's batch through the deployed pipeline.
```

The dev agent cannot rebuild + rotate a prod artifact and cannot replay prod
batches pre-merge → reports "inherently post-merge" every round → loop.

**Corrected (pre-merge verifiable, names the surface + evidence):**

```markdown
## Acceptance Criteria
- [ ] The parser handles the malformed-row case from the bug. Surface: existing
      PR-preview E2E lane `ingest-replay.spec.ts` (CI job `e2e-preview`) feeds
      `fixtures/batch-2024-bad.ndjson` — the same code path and input as the prod
      batch. Expected evidence: `e2e-preview` green + the new row-error assertion
      passing on the PR-preview URL.
```

Same code path, same input, but checked on the pre-merge surface that already
exists — the loop can close it.

### Example 2 — a genuine post-merge AC split into a non-blocking, non-autonomous follow-up

A feature adds a new metric emitter. One criterion truly needs production: a
dashboard panel only populates from prod telemetry after deploy.

**Do not leave this as a blocking AC** on the autonomous feature issue. Instead:

1. Create the follow-up first — issue titled `Post-deploy verify: new latency
   panel populates from prod telemetry` — and **omit the `autonomous` label**
   (it's a human/ops check after the next deploy).
2. In the primary feature issue:

```markdown
## Acceptance Criteria
- [ ] Emitter writes the `request.latency` EMF metric. Surface: unit test
      `TC-METRIC-003` asserts the EMF JSON shape (CI `unit` job). Expected
      evidence: test green.

## Out of Scope
- Post-deploy confirmation that the CloudWatch latency panel populates from prod
  telemetry — tracked in the follow-up `Post-deploy verify: …` issue (NON-blocking,
  not in `## Dependencies`).
```

The primary issue keeps only pre-merge-verifiable ACs and closes through the
autonomous loop; the prod-only check lives in a non-autonomous follow-up that a
human resolves after deploy.

---

## 5. A pre-merge-verifiable AC can still stall — if the surface is agent-unwritable

Section 1's rubric asks "can the evidence be obtained before merge?" That is
necessary but not sufficient. A second, independent question matters just as
much: **can the dev agent's scoped token actually write to that surface?**

Per the two-token split (#234), the autonomous pipeline splits write access:

- **Agent-writable** (the dev agent's scoped token can write here): a **PR
  comment**, an **issue comment**, a **committed file** (code, docs, test
  output committed to the branch).
- **Maintainer-or-wrapper only** (the scoped token cannot write here): the
  **PR body**, **PR title**, **labels**, **milestone** — PR/issue *metadata*.
  Editing these returns `Resource not accessible by integration` for the
  scoped token; only the full-write wrapper token or a human maintainer can
  edit them.

An AC that names a maintainer-or-wrapper-only surface is **pre-merge
verifiable in principle** — the evidence could exist before merge — but is
**guaranteed to stall** in practice: the dev agent produces the evidence
wherever it *can* write, the review agent (correctly) checks the literal
surface named in the AC, finds it empty, and marks the issue
`dev-actionable=false`. Every component behaves correctly; the defect is the
AC's choice of surface.

**The fix is almost always a one-word rewrite**, not a redesign — a PR
comment carries the same evidentiary value as a PR-body paragraph:

- ❌ "Curl transcript showing the PUT→GET round-trip **in PR body**."
- ✅ "Curl transcript showing the PUT→GET round-trip **as a PR comment**."

When drafting or reviewing an AC, check both axes:

1. **Pre-merge verifiable?** (§1) — if not, split per §3.
2. **Agent-writable surface?** (this section) — if the named surface is
   PR body/title/labels/milestone, reword to a PR comment, issue comment, or
   committed file instead. This is an advisory rewrite, not a hard block —
   see `SKILL.md` Step 4's agent-unwritable-surface self-scan.

---

## See also

- `references/issue-templates.md` — both templates carry an always-present
  pre-merge-classification note in their `## Acceptance Criteria` section.
- `SKILL.md` Step 1 (per-AC classification prompt), Writing Guidelines
  ("AC verification surface" bullet), and Step 4 (advisory self-scan for
  post-merge phrasing, and the agent-unwritable-surface self-scan, both on
  AC checkbox lines).
