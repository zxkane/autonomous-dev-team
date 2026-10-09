# Session knowledge after merge

Status: Implementing

Dev retries and parallel reviews can discover durable facts that disappear when
their worktrees or sessions end. Retain small, verified candidates across those
sessions, then apply useful documentation changes after the code host confirms
the original PR is merged. An assessment may explicitly find nothing to retain.

## Flow and ownership

1. The dev/review wrapper begins a task-scoped assessment and provides the shared
   helper in its prompt. Interactive skill users begin one in their worktree.
2. Before handoff or posting a review verdict, the agent records verified updates
   or a reason for no updates. A Stop hook checks the assessment. Candidates live
   privately under the common Git directory, shared by linked worktrees.
3. Reviewers inspect pending candidates and correct or discard obsolete claims.
   Stable keys select the latest assessment of a fact across successive runs.
4. After a confirmed merge, the wrapper applies candidates in a fresh documentation
   worktree. It preserves existing prose, replaces keyed sections, and supports
   exact replacement of an incorrect existing paragraph. A stale or ambiguous
   replacement leaves the writeback pending instead of guessing.
5. Only a nonempty documentation diff creates a conventional commit and a separate
   PR through the existing code-host seams. This PR has no autonomous task label
   or issue-closing keyword. No trunk push or additional model invocation occurs.

The agent performs semantic selection while the experience is still in context.
The post-merge operation is deterministic; it does not reread or publish session
transcripts. Stop checks enforce assessment, not a minimum number of lessons.
Publication failure does not undo the feature merge or alter its issue state.
Receipts and commits survive retries; publication reuses an existing branch/PR.

## Placement

| Information | Destination | Selection rule |
|---|---|---|
| Current module facts, commands, constraints | Nearest applicable `AGENTS.md` | Brief guidance that changes future decisions; correct stale facts |
| Reproducible failure, cause, diagnosis, fix | `docs/troubleshooting/<topic>.md` | Useful beyond the current incident |
| Decisions and rationale, rejected approaches, test/verification pitfalls, tool or dependency constraints | `docs/lessons-learned/<topic>.md` | Verified, durable, actionable and absent from existing docs |
| Machine paths, profiles, environment workarounds, credential locations | Root `AGENTS.local.md` | Gitignored and mode 600; credentials are references only |
| Progress, raw logs/transcripts, speculation, duplicate advice, temporary failures | No tracked writeback | Keep existing run artifacts where appropriate |

Tracked candidates and resulting files are scanned for recognizable credentials
and environment identifiers. This is a backstop: the recording agent must still
remove private repository references and use placeholders in public artifacts.
Local credential values stay in their existing environment variables or private
files, not in the learning ledger or generated Markdown.

## Existing mechanisms to reuse or borrow

| Mechanism | Useful behavior | Adaptation |
|---|---|---|
| Existing common hooks and installers | Shared Stop event, bounded stdin, worktree-aware paths | Add one common hook to the canonical template and skill frontmatter |
| Existing code-host seams | Provider-neutral merged-state read and PR creation | Reuse for GitHub/GitLab; keep merge ownership in the review wrapper |
| [gstack `learn`](https://github.com/garrytan/gstack/blob/main/learn/SKILL.md) | Stable keys, latest-entry deduplication, stale/contradictory fact checks, Markdown export | Borrow selection and revision rules without Bun, telemetry or a user-global store |
| gstack `context-save` | Saves continuation state across sessions | Keep task checkpoints private; publish only durable facts |
| [Codex scoped instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md) | Root-to-directory instruction discovery and overrides | Put durable guidance close to its code; explicitly read the ignored local file when needed |
| [Codex hooks](https://learn.chatgpt.com/docs/hooks) | Stop validation, session metadata, transcript path | Use the installed Stop contract; the official docs warn transcript format is not a stable hook interface |

This extends `autonomous-common`, `autonomous-dev`, and `autonomous-review`
instead of introducing another required skill or an external memory dependency.

## Verification

Use real temporary Git repositories and linked worktrees to verify cross-session
retention, scoped placement, correction/removal, clean no-op behavior, local-file
privacy, secret/path rejection, isolated commits, failed-merge exclusion and
idempotent publication. All fixtures are credential-free.
