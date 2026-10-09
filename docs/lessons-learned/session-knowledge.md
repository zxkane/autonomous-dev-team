# Keeping session knowledge useful

Capture verified facts while the working session still has the relevant context.
The common Git directory preserves those small candidates across linked
worktrees and retries. Full transcript exports are a poor integration boundary:
[Codex's hook documentation](https://learn.chatgpt.com/docs/hooks) explicitly says
the transcript format is not stable. Commit useful guidance and diagnoses after
a confirmed merge, and allow an explicit no-update assessment.

Order updates per fact. Rewriting one session's receipt with a later no-update
must neither clear its earlier candidates nor promote unchanged facts over a
newer review correction. Stable path/key pairs, incremental updates and per-fact
sequences preserve both independent discoveries and deliberate corrections.
Private verification metadata alone should not produce another documentation PR.

Bind assessment checks to the source worktree, not the Stop event's cwd. Wrappers
can launch an agent from the primary checkout while it works in a linked worktree.
Record that source and branch, check repository ownership, and invalidate the
receipt when its source revision or branch changes. Key parallel receipts by
member UUID rather than CLI name so two members using one CLI remain independent.

Choose locks by the resource being changed. Separate task locks protect task
receipts, but they cannot protect the one local guidance file shared by every
task. Hold a repository lock around its entire read/modify/write operation;
an atomic rename alone still permits lost updates. Verify this with concurrent
writers for different tasks.

Publish the validated commit SHA. Branch names are mutable: a concurrent commit
between validation and push can otherwise publish unrelated files. Validate a
retry's branch/worktree ownership and preserve unexpected edits. Recreate a
removed owned worktree from its unchanged committed branch rather than making
another commit.

Documentation branches must avoid issue-linkage tokens. A branch containing
`issue-N` can satisfy the existing partial-fix PR fallback even without a closing
keyword, allowing a later issue run to select and merge the documentation PR.
Use a stable task hash and verify the actual PR resolver rejects that branch.
Treat provider creation as an exit-status contract: an optional URL on stdout is
not a durable publication identity. Re-read the matching PR and validated head.

Path checks must remain effective during the write. Open parent directories
without following symlinks and replace through their descriptors; rechecking a
pathname alone still permits a directory swap between check and use.

Keep identifiable private references in a local policy. A public skill should
not hardcode private repository names to detect them. Scan both candidates and
complete resulting files, require explicit credential references/placeholders,
and permit exact redaction of a legacy private identifier without rendering it.
Scanners supplement the agent's obligation to verify and sanitize facts; the
documentation PR remains subject to ordinary review.

These contracts are exercised by
[`test-session-knowledge.sh`](../../tests/unit/test-session-knowledge.sh) and
[`test-session-knowledge-merge.sh`](../../tests/unit/test-session-knowledge-merge.sh)
using temporary linked worktrees, concurrent writers and a bare Git remote.
