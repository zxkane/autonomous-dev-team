# Review Thread Management

## Critical Rules

- **Reply DIRECTLY to each comment thread** -- NOT a single general PR comment
- **Resolve each conversation after replying**
- **Wrong approach**: `gh pr comment {pr} --body "Fixed all issues"` (does not close threads)

## Reply to Review Comments

```bash
# Get comment IDs
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq '.[] | {id: .id, path: .path, body: .body[:50]}'

# Reply to specific comment
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  -X POST \
  -f body="Addressed in commit abc123 - <description of fix>" \
  -F in_reply_to=<comment_id>
```

## Resolve Review Threads

```bash
# Get unresolved thread IDs
gh api graphql -f query='
query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr}) {
      reviewThreads(first: 50) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes { body }
          }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id'

# Resolve a thread
gh api graphql -f query='
mutation {
  resolveReviewThread(input: {threadId: "<thread_id>"}) {
    thread { isResolved }
  }
}'
```

## Batch Resolve All Threads

```bash
scripts/resolve-threads.sh {owner} {repo} {pr_number}
```

## Common Response Patterns

### For Valid Issues

```
Addressed in commit {hash} - {description of fix}
```

### For False Positives

```
This is by design because {explanation}. The {feature} requires {justification}.
```

### For Documentation Concerns

```
The referenced file {filename} exists in the repository at {path}. This is a reference document, not executable code.
```

## Quick Reference

| Task | Command |
|------|---------|
| Create worktree | `git worktree add .worktrees/<branch> -b <branch>` |
| List worktrees | `git worktree list` |
| Remove worktree | `git worktree remove .worktrees/<branch>` |
| Prune worktrees | `git worktree prune` |
| Create design | Pencil MCP tools (if available) |
| Create PR | `gh pr create --title "..." --body "..."` |
| Watch checks | `gh pr checks {pr} --watch` |
| Get comments | `gh api repos/{o}/{r}/pulls/{pr}/comments` |
| Reply to comment | `gh api ... -X POST -F in_reply_to=<id>` |
| Resolve thread | GraphQL `resolveReviewThread` mutation |
| Trigger Q review | `gh pr comment {pr} --body "/q review"` |
| Trigger Codex review | `gh pr comment {pr} --body "/codex review"` |
| Reply to comment (script) | `scripts/reply-to-comments.sh {owner} {repo} {pr} {comment_id} "{message}"` |
| Resolve all threads (script) | `scripts/resolve-threads.sh {owner} {repo} {pr}` |
| Mark hook state | `hooks/state-manager.sh mark <action>` |
| List hook states | `hooks/state-manager.sh list` |
