# Design: W1b abstract itp_read_task field contract (#396, #347 phase-2)

## Problem

`providers/itp-github.sh`'s `itp_github_read_task` leaf is a literal
`gh issue view "$issue" --repo "$REPO" --json "$field" "$@"` pass-through —
the six callers (`check_deps_resolved`, two `autonomous-dev.sh` issue-body
fetches, the `autonomous-review.sh` no-auto-close gate, `status.sh`,
`mark-issue-checkbox.sh`) push a `--json <field-list>` and (in three cases)
a forwarded `-q '<jq program>'` through the seam. A second provider (GitLab,
Asana) implementing `provider-spec.md` §3.1's cell literally would break
every caller — the cells document `title`/`body`/`state` but reality also
passes `labels`/`comments`, and `labels` is consumed as raw `{name}` objects
while the sibling W1a verbs already normalize labels to name strings. This
mirrors the exact gap [W1a] (#371) closed for `itp_list_by_state`/
`itp_count_by_state`/`itp_list_forbidden_combos`.

## Decision

Convert `itp_read_task` to an abstract contract: the caller passes
`ISSUE FIELDS_CSV` (⊆ `title,body,state,labels,comments`); the leaf owns
100% of the `gh` I/O AND the normalization jq. No `gh` flags, no jq programs
cross the seam.

```
itp_read_task <issue> <fields-csv>
  → { title, body, state, labels:[name,...], comments:[{id,author,authorKind,body,createdAt},...] }
    normalized, projected to EXACTLY <fields-csv>
    title/body: strings (absent body -> "")
    state: passed through verbatim (GitHub's OPEN/CLOSED tokens are already
      provider-neutral — status.sh's `_next_action` gate ships byte-unchanged)
    labels: array of NAME strings (not {name} objects)
    comments: the [INV-90] normalized array
    task not found / read failure -> rc≠0, no partial output (fail-closed)
```

This is a **deliberate shape change** — the byte-identical-argv constraint
`itp_read_task` satisfied since #281/#296/#306/#310/#315 is lifted for this
verb, per the issue and mirroring [W1a]. Callers drop their forwarded `-q`
selector in favor of a caller-side `| jq` projection over the normalized
object.

## Why an OBJECT, not an array

Unlike the W1a trio (which enumerate a set of issues), `itp_read_task` reads
ONE task. The natural abstract return is a single JSON object with exactly
the requested fields — no `[]`-on-empty convention applies (a task either
exists and is read, or the read fails-closed).

## Proof strategy

Byte-identical golden-trace is impossible by construction here — the shape
changed. Instead, mirroring [W1a]:

1. **Decision-level parity** (R5): for each of the six callers, run the
   CURRENT code and compare its downstream DECISION (same `## Dependencies`
   extraction / same checkbox rewrite / same no-auto-close boolean / same
   `_next_action` terminal-vs-open branch / same title-body TEXT for the two
   prompt-fetch sites) against a golden captured from the OLD (pre-#396,
   byte-identical-passthrough) code on the first TDD commit.
   `tests/unit/test-w1b-read-task-parity.sh`.
2. **Leaf-level seam-trace** (AC2): stub `itp_github_read_task` to RECORD the
   argv each of the six real callers sends, and assert it is exactly
   `<issue> <fields-csv>` — no gh-flag-shaped or jq-program-shaped element.
   `tests/unit/test-w1b-read-task-contracts.sh`.
3. **Provider-conformance** (R6): `itp_read_task` moves from
   `CONTRACT-PENDING` / `pending` to `asserted` in the W2 runner
   (`tests/provider-conformance/`), with a new object-shape assertion helper
   (`_run_object_shape_assert`) distinct from the array-returning verbs'.

## Retired coverage

The pre-#396 golden-trace suites pinned byte-identical argv for
`itp_read_task` specifically: `test-itp-read-task-b5b7.sh` (the
autonomous-dev.sh/autonomous-review.sh live-wrapper sites) and
`test-itp-read-task-body-golden-trace.sh` (the `check_deps_resolved` site).
Both are retired — their coverage is superseded by the parity + leaf-contract
suites above. `test-itp-read-leaves.sh`'s `itp_read_task`-specific
golden-trace cases are removed; its `itp_list_comments` + dispatch/caps/
capability-branch coverage (a different, unmigrated-by-this-issue concern)
is unchanged.

## Non-goals

- W1(c)-(f): CHP PR reads, `chp_ci_status`/`chp_mergeable`, CHP write
  flag-tails, `chp_review_threads` pagination — separate slices, filed as
  siblings serialized behind this issue.
- Writing any non-GitHub leaf (phase-3).
- Prompt-heredoc provider-awareness (phase-3).
- The `resolve_dep`-keyed leaf-absent guard asymmetry in
  `check_deps_resolved` (pre-existing, documented, out of scope).
