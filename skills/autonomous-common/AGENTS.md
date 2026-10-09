# Common infrastructure

Hook installers translate `scripts/claude-settings.template.json`. Update that
template and the dev/review skill frontmatter together when adding an event.

Session knowledge receipts are shared by linked worktrees through the common Git
directory. Order corrections per fact, not per session receipt: reassessment with
no new facts must preserve earlier facts without promoting them over newer ones.
The primary checkout's `AGENTS.local.md` is shared across tasks, so its complete
read/modify/write operation requires a repository lock in addition to task locks.

Knowledge commits contain only allowed documentation. Validate their complete
diff and push the validated SHA; a branch name can move after validation. Keep
private reference lists in ignored local policy files, never in skill source.
See [recording rules](references/session-knowledge.md) and
[maintained lessons](../../docs/lessons-learned/session-knowledge.md).
