# Session knowledge writeback

Use the installed common skill's `scripts/session-knowledge.sh` as `<helper>`.
The wrapper supplies literal task/session identifiers; interactive `begin`
records them in the active worktree. Inspect candidates locally:

```bash
bash <helper> pending --task issue-<N>
```

## Stop requests another assessment

The session has no assessment for its current source HEAD/branch. Stop may run
from the launcher checkout while development happened in another linked worktree.
Use the source worktree named by the diagnostic; changes in an unrelated primary
checkout do not invalidate that source's assessment. After the final code changes,
record verified candidates with `assess --input <private-json-file>` or
use `assess --none 'reason no new update is needed'`. The latter preserves facts
already checkpointed in the task; explicitly discard an incorrect candidate.
No lesson, file change or minimum count is required.

## A legacy replacement is stale or ambiguous

The exact `replace` paragraph is absent or occurs more than once in the fetched
base. Inspect the current document and implementation, then correct the candidate
or discard it. The helper does not guess which paragraph to overwrite and does
not partially commit the other candidates. A managed section is updated by its
path/key instead of requiring the original legacy paragraph again.

## A privacy check rejects the update

Use generic phrasing for a private/cross-repository reference and placeholders
for environment identifiers. Move machine-specific details to the local array.
Credential assignments must use `env:VARIABLE`, `file:<location>` or a clear
placeholder; short values are credentials too. Private names/domains can be
configured in the ignored, mode-600 policy described in the
[recording reference](../../skills/autonomous-common/references/session-knowledge.md#public-reference-policy).

## Writeback remains pending after merge

The original merge is independent of knowledge publication. Confirm the PR is
actually merged; closed-unmerged or queued states do not publish documentation.
A queued/asynchronous merge needs this retry entry after it reaches MERGED; the
callback does not launch an additional merge watcher.
Retry through the project entry after fixing the reported cause:

```bash
bash scripts/distill-knowledge.sh --issue <N> --pr <merged-pr>
```

A failed push/PR creation retains the committed documentation branch. Retry
reuses that commit and an existing matching PR. Provider create stdout is optional;
the callback re-reads the normalized PR identity/head before recording completion.
An unavailable PR-list read
cannot safely prove a PR is absent, so it remains pending. If a branch/worktree
contains unexpected edits, inspect and preserve them before retrying; the helper
does not reset them or force-push. Changing the merge target also requires a new
verified assessment rather than reusing a receipt for another base.
