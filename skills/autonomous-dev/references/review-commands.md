# Review Commands Reference

Complete reference for GitHub CLI and GraphQL commands used in the PR review workflow.

## gh CLI Commands

### Get PR Review Comments

List all review comments on a PR:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq '.[] | {id: .id, path: .path, body: .body[:100], created_at: .created_at}'
```

Filter by date (comments after a specific time):

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq '[.[] | select(.created_at > "2024-01-01T00:00:00Z")] | .[] | {id: .id, body: .body[:100]}'
```

Get comments from a specific review:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/reviews/{review_id}/comments \
  --jq '.[] | {id: .id, path: .path, body: .body[:150]}'
```

### Reply to Review Comment

Reply directly to a specific comment (creates a thread reply):

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  -X POST \
  -f body="Addressed in commit abc123 - <description of fix>" \
  -F in_reply_to=<comment_id>
```

**Important**: Use `-F in_reply_to=<id>` to reply in the thread. Without this, it creates a new comment instead of a thread reply.

### Get PR Reviews

List all reviews on a PR:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/reviews \
  --jq '.[] | {id: .id, state: .state, user: .user.login, submitted_at: .submitted_at}'
```

Get the most recent Amazon Q Developer review:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/reviews \
  --jq '[.[] | select(.user.login == "amazon-q-developer[bot]")] | .[-1] | {id: .id, submitted_at: .submitted_at}'
```

Get the most recent Codex review:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/reviews \
  --jq '[.[] | select(.user.login == "codex[bot]")] | .[-1] | {id: .id, submitted_at: .submitted_at}'
```

### Trigger Bot Reviews

Add a comment to trigger bot rescans:

```bash
# Amazon Q Developer
gh pr comment {pr} --body "/q review"

# Codex
gh pr comment {pr} --body "/codex review"
```

### Monitor PR Checks

Watch all checks until completion:

```bash
gh pr checks {pr} --watch --interval 30
```

Quick status check:

```bash
gh pr checks {pr}
```

### Get PR Status

```bash
gh pr view {pr} --json state,reviewDecision,statusCheckRollup \
  --jq '{state: .state, reviewDecision: .reviewDecision}'
```

## GraphQL Commands

### Get Review Thread Status

Query to get all review threads with their resolution status:

```bash
gh api graphql -f query='
query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr}) {
      reviewThreads(first: 50) {
        totalCount
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes {
              body
            }
          }
        }
      }
    }
  }
}'
```

### Get Only Unresolved Threads

Filter to show only unresolved threads:

```bash
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
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {id: .id, comment: .comments.nodes[0].body[:80]}'
```

### Get Thread Count Summary

```bash
gh api graphql -f query='
query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr}) {
      reviewThreads(first: 50) {
        totalCount
        nodes {
          isResolved
        }
      }
    }
  }
}' --jq '{
  total: .data.repository.pullRequest.reviewThreads.totalCount,
  resolved: [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == true)] | length,
  unresolved: [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length
}'
```

### Resolve Review Thread

Mutation to resolve a single thread:

```bash
gh api graphql -f query='
mutation {
  resolveReviewThread(input: {threadId: "<thread_id>"}) {
    thread {
      isResolved
    }
  }
}'
```

### Batch Resolve All Unresolved Threads

Combined query and mutation loop:

```bash
gh api graphql -f query='
query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr}) {
      reviewThreads(first: 50) {
        nodes {
          id
          isResolved
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id' | while read thread_id; do
  echo "Resolving: $thread_id"
  gh api graphql -f query="
mutation {
  resolveReviewThread(input: {threadId: \"$thread_id\"}) {
    thread { isResolved }
  }
}" --jq '.data.resolveReviewThread.thread.isResolved'
done
```

## Common Workflows

### Complete Review Response Flow

1. **Get new comments**:
```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq 'sort_by(.created_at) | .[-10:] | .[] | {id: .id, body: .body[:100]}'
```

2. **Reply to each comment**:
```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  -X POST \
  -f body="Addressed in commit abc123 - Fixed the issue" \
  -F in_reply_to=<comment_id>
```

3. **Resolve all threads**:
```bash
# Use the batch resolve script or loop above
```

4. **Trigger new review** (use appropriate bot command):
```bash
# Amazon Q
gh pr comment {pr} --body "/q review"

# Codex
gh pr comment {pr} --body "/codex review"
```

5. **Wait and check for new comments**:
```bash
sleep 90
# Check Amazon Q
gh api repos/{owner}/{repo}/pulls/{pr}/reviews \
  --jq '[.[] | select(.user.login == "amazon-q-developer[bot]")] | .[-1]'

# Check Codex
gh api repos/{owner}/{repo}/pulls/{pr}/reviews \
  --jq '[.[] | select(.user.login == "codex[bot]")] | .[-1]'
```

6. **Iterate until no new positive findings** - If new findings appear, repeat from step 1

### Check if All Threads Resolved

```bash
unresolved=$(gh api graphql -f query='...' --jq '... | select(.isResolved == false) | .id' | wc -l)
if [ "$unresolved" -eq 0 ]; then
  echo "All threads resolved!"
else
  echo "$unresolved threads still unresolved"
fi
```

## Error Handling

### Thread Not Found

If `resolveReviewThread` returns "Could not resolve to a node":
- Verify the thread ID is correct
- Check that the PR is still open
- Ensure you have write access to the repository

### Rate Limiting

If you hit GitHub API rate limits:
- Add delays between requests: `sleep 1`
- Use pagination for large result sets
- Check rate limit status: `gh api rate_limit`

### Authentication Issues

Ensure `gh` is authenticated:
```bash
gh auth status
gh auth login  # if needed
```
