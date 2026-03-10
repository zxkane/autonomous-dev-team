#!/bin/bash
# autonomous-review.sh — Wrapper for CC autonomous review tasks.
#
# Reviews a PR linked to an issue, then either merges (pass) or sends back (fail).
# Uses a lighter model by default to avoid quota contention with dev tasks.
# Called by dispatcher via SSM or manually.
#
# Usage:
#   scripts/autonomous-review.sh --issue <number>
#
# Exit codes:
#   0 — Review completed (pass or fail)
#   1 — Review process error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib-agent.sh"
source "${SCRIPT_DIR}/lib-auth.sh"

# Validate required config (loaded by lib-agent.sh from autonomous.conf)
: "${PROJECT_ID:?Set PROJECT_ID in autonomous.conf}"
: "${REPO:?Set REPO in autonomous.conf}"
: "${REPO_OWNER:?Set REPO_OWNER in autonomous.conf}"
: "${REPO_NAME:?Set REPO_NAME in autonomous.conf}"
: "${PROJECT_DIR:?Set PROJECT_DIR in autonomous.conf}"

# ---------------------------------------------------------------------------
# GitHub authentication
# ---------------------------------------------------------------------------
if [[ "$GH_AUTH_MODE" == "app" ]]; then
  if [[ -z "${REVIEW_AGENT_APP_ID:-}" || -z "${REVIEW_AGENT_APP_PEM:-}" ]]; then
    echo "Error: GH_AUTH_MODE=app requires REVIEW_AGENT_APP_ID and REVIEW_AGENT_APP_PEM" >&2
    exit 1
  fi
  setup_github_auth "${REVIEW_AGENT_APP_ID}" "${REVIEW_AGENT_APP_PEM}"
else
  setup_github_auth
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ISSUE_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      [[ $# -ge 2 ]] || { echo "Error: --issue requires argument" >&2; exit 1; }
      ISSUE_NUMBER="$2"; shift 2 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ISSUE_NUMBER" ]]; then
  echo "Usage: $0 --issue <number>" >&2
  exit 1
fi

# Validate ISSUE_NUMBER is a positive integer (prevents injection in jq regex/file paths)
if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: --issue must be a positive integer, got '$ISSUE_NUMBER'" >&2
  exit 1
fi

# Ensure we're in the project directory (needed when called directly, not just via SSM)
cd "$PROJECT_DIR" || { echo "Error: cannot cd to $PROJECT_DIR" >&2; exit 1; }

LOG_FILE="/tmp/cc-${PROJECT_ID}-review-${ISSUE_NUMBER}.log"
PID_FILE="/tmp/cc-${PROJECT_ID}-review-${ISSUE_NUMBER}.pid"

# Write PID for stale detection
echo $$ > "$PID_FILE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[autonomous-review] $(date -u +%H:%M:%S) $*"; }

cleanup() {
  rm -f "$PID_FILE" 2>/dev/null || true
  cleanup_github_auth
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Find PR linked to this issue
# ---------------------------------------------------------------------------
log "Finding PR for issue #${ISSUE_NUMBER}..."

# Method 1: Search PRs that reference the issue
PR_NUMBER=$(gh pr list --repo "$REPO" --state open --json number,body \
  -q "[.[] | select(.body | test(\"#${ISSUE_NUMBER}[^0-9]\") or test(\"#${ISSUE_NUMBER}$\"))] | .[0].number // empty" 2>/dev/null || true)

# Method 2: Extract PR number from issue comments
if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("(?:PR|pull)[/ #]*(?P<pr>[0-9]+)"; "g") | .pr] | last // empty' 2>/dev/null || true)
fi

# Method 3: Search PRs mentioning the issue number
if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER=$(gh pr list --repo "$REPO" --state open --search "issue ${ISSUE_NUMBER}" --json number \
    -q '.[0].number // empty' 2>/dev/null || true)
fi

if [[ -z "$PR_NUMBER" ]]; then
  log "ERROR: No PR found for issue #${ISSUE_NUMBER}"
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "Review failed: no PR found linked to this issue. Please ensure the PR description contains 'Closes #${ISSUE_NUMBER}'." 2>/dev/null || true
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "reviewing" \
    --add-label "pending-dev" 2>/dev/null || true
  exit 1
fi

log "Found PR #${PR_NUMBER} for issue #${ISSUE_NUMBER}"

# ---------------------------------------------------------------------------
# Extract PR preview URL (conditional on E2E config)
# ---------------------------------------------------------------------------
PREVIEW_URL=""

if [[ "${E2E_ENABLED:-false}" == "true" && -n "${E2E_PREVIEW_URL_PATTERN:-}" ]]; then
  log "Extracting preview URL for PR #${PR_NUMBER}..."

  # Build expected URL from config, replacing {N} with PR number
  PREVIEW_URL="${E2E_PREVIEW_URL_PATTERN//\{N\}/$PR_NUMBER}"

  # Also try to extract from PR comments (may contain a more specific URL)
  COMMENT_URL=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json comments \
    -q '[.comments[].body | select(contains("Preview"))] | last' 2>/dev/null \
    | grep -oP 'https://[^\s"]+' | head -1 || true)
  PREVIEW_URL="${COMMENT_URL:-$PREVIEW_URL}"

  if [[ -n "$PREVIEW_URL" ]]; then
    log "Found preview URL: ${PREVIEW_URL}"
  else
    log "WARNING: No preview URL found"
  fi
else
  log "E2E verification disabled or no preview URL pattern configured."
fi

# ---------------------------------------------------------------------------
# Screenshot upload availability
# ---------------------------------------------------------------------------
if [[ "${E2E_SCREENSHOT_UPLOAD:-false}" == "true" && -x "${SCRIPT_DIR}/upload-screenshot.sh" ]]; then
  SCREENSHOT_UPLOAD_AVAILABLE="true"
  log "Screenshot upload script available"
else
  SCREENSHOT_UPLOAD_AVAILABLE="false"
  if [[ "${E2E_ENABLED:-false}" == "true" ]]; then
    log "WARNING: Screenshot upload not available (set E2E_SCREENSHOT_UPLOAD=true and ensure upload-screenshot.sh is executable)"
  fi
fi

# ---------------------------------------------------------------------------
# Build review prompt
# ---------------------------------------------------------------------------
PR_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName -q '.headRefName' 2>/dev/null || true)
log "PR branch: ${PR_BRANCH:-UNKNOWN}"

PROMPT="$(cat <<EOF
You are reviewing PR #${PR_NUMBER} for issue #${ISSUE_NUMBER} in the ${REPO} project.
PR branch: ${PR_BRANCH:-UNKNOWN}

## Step 0: Merge Conflict Resolution — MANDATORY PRE-REVIEW

Before doing anything else, check the PR mergeable status and rebase if needed.

Quick reference:
1. Check: \`gh pr view ${PR_NUMBER} --repo ${REPO} --json mergeable -q '.mergeable'\`
2. If "MERGEABLE" — proceed to the review checklist below
3. If "CONFLICTING" — rebase the PR branch onto main:
   \`\`\`bash
   git fetch origin main ${PR_BRANCH}
   git worktree add /tmp/rebase-pr-${PR_NUMBER} ${PR_BRANCH}
   cd /tmp/rebase-pr-${PR_NUMBER}
   git rebase origin/main
   # If rebase succeeds:
   git push --force-with-lease origin ${PR_BRANCH}
   cd -
   git worktree remove /tmp/rebase-pr-${PR_NUMBER}
   # Wait for CI to restart
   sleep 10
   gh pr checks ${PR_NUMBER} --watch --interval 30
   \`\`\`
4. If rebase fails (conflicts) — FAIL the review with "[BLOCKING] Merge conflict with main" and exit
5. If "UNKNOWN" — wait 10s and retry up to 3 times

## Review Checklist
Verify ALL of the following were completed:

1. [ ] Design canvas created (docs/designs/ or docs/plans/)
2. [ ] Git worktree used (branch name starts with feat/, fix/, etc.)
3. [ ] Test cases documented (docs/test-cases/)
4. [ ] Unit tests written and passing
5. [ ] E2E tests written/updated if UI changes
6. [ ] code-simplifier was run
7. [ ] pr-review agent was run
8. [ ] CI checks all passing
9. [ ] Reviewer bot findings addressed
10. [ ] PR description follows template

## Review Process
1. Read the issue body to understand requirements
2. Read the PR diff to verify implementation
3. Check that CI checks are passing: gh pr checks ${PR_NUMBER}
4. Verify test coverage and quality
5. Check for security issues, code quality, and best practices
6. Trigger and verify Amazon Q Developer review (see below)

## Amazon Q Developer Review — MANDATORY

Amazon Q ignores /q review comments from bot accounts. You MUST use \`scripts/gh-as-user.sh\` to trigger Q review as a real user.

### Steps:
1. Check if Q review already exists:
   \`\`\`bash
   Q_COUNT=\$(gh api repos/${REPO}/pulls/${PR_NUMBER}/reviews --jq '[.[] | select(.user.login == "amazon-q-developer[bot]")] | length')
   \`\`\`
2. If Q_COUNT is 0, trigger Q review (must use user auth, not bot token):
   \`\`\`bash
   bash scripts/gh-as-user.sh pr comment ${PR_NUMBER} --body "/q review"
   \`\`\`
3. Poll for Q review to appear (every 30s, timeout 3 min):
   \`\`\`bash
   for i in {1..6}; do
     sleep 30
     Q_COUNT=\$(gh api repos/${REPO}/pulls/${PR_NUMBER}/reviews --jq '[.[] | select(.user.login == "amazon-q-developer[bot]")] | length')
     if [[ "\$Q_COUNT" -gt 0 ]]; then break; fi
   done
   \`\`\`
4. Read Q review inline comments and check for unresolved threads
5. Report Q review status in the E2E verification report table

$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then cat <<E2E_BLOCK
## E2E Verification via Chrome DevTools MCP — MANDATORY

**This section is NON-NEGOTIABLE. You MUST perform E2E verification using Chrome DevTools MCP.**

Preview URL: ${PREVIEW_URL:-NOT_FOUND}
Test user email: ${E2E_TEST_USER_EMAIL:-}
Test user password: ${E2E_TEST_USER_PASSWORD:-}
Screenshot upload available: ${SCREENSHOT_UPLOAD_AVAILABLE}

### Step 1: Verify preview URL availability
- If the preview URL above is "NOT_FOUND" or empty, the review MUST FAIL immediately.
  Post "Review findings:" with: "E2E verification failed: PR preview URL not found. Deploy-preview job must post a comment with the preview URL before review can proceed."

### Step 2: Navigate to preview URL
- Use Chrome DevTools MCP \`new_page\` to open a new browser page
- Use \`navigate_page\` to go to the preview URL
- Use \`wait_for\` to confirm the page loads successfully
- Use \`take_screenshot\` to capture the landing page as evidence

### Step 3: Login with test user
- Navigate to the login page or click the sign-in button
- Use \`fill\` to enter the test user email and password
- Submit the login form
- Use \`wait_for\` to confirm successful authentication (e.g., dashboard loads)
- Use \`take_screenshot\` to capture the authenticated state

### Screenshot upload — MANDATORY after every take_screenshot
**Every time you use \`take_screenshot\`, you MUST immediately upload it using the Bash tool:**

\`\`\`bash
SCREENSHOT_URL=\$(bash scripts/upload-screenshot.sh "<screenshot-file-path>" ${PR_NUMBER} "<TC-ID>")
echo "Uploaded: \$SCREENSHOT_URL"
\`\`\`

- If the upload succeeds, \`SCREENSHOT_URL\` will be a GitHub blob URL viewable by repo members
- Use this URL as a clickable link in the E2E report: \`[TC-ID](\$SCREENSHOT_URL)\`
- If the upload returns "UPLOAD_FAILED", describe the visual state in text instead
- Do NOT skip the upload step — screenshots must be linked in PR comments

### Step 4: Select and execute happy path test cases
- Analyze the PR diff to select relevant happy path cases
- Execute at least ONE happy path case using Chrome DevTools MCP
- For each happy path case:
  a. Follow the test steps
  b. Use \`take_screenshot\` at key verification points
  c. **Immediately** upload each screenshot: \`bash scripts/upload-screenshot.sh "<path>" ${PR_NUMBER} "<TC-ID>"\`
  d. Record PASS or FAIL with clickable link evidence

### Step 5: Execute feature-specific test cases
- Read the test case document from \`docs/test-cases/\` for the feature being reviewed
- Skip any scenarios already covered by happy path cases (no duplication)
- For each test case:
  a. Follow the test steps using Chrome DevTools MCP tools
  b. Verify expected outcomes by inspecting page content
  c. Use \`take_screenshot\` then **immediately** upload: \`bash scripts/upload-screenshot.sh "<path>" ${PR_NUMBER} "<TC-ID>"\`
  d. Record PASS or FAIL with clickable link evidence

### Step 6: Regression checks
- Verify basic auth flow works (login/logout)
- Verify main navigation works (sidebar links, page transitions)
- Verify no console errors using \`list_console_messages\`

### Step 7: Post E2E results as PR comment
Post a structured comment on PR #${PR_NUMBER} (NOT the issue) with this format:

\`\`\`markdown
## E2E Verification Report

### Summary
| Total | Passed | Failed | Skipped |
|-------|--------|--------|---------|
| N     | X      | Y      | Z       |

### Happy Path Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-HP-001 | ... | PASS/FAIL | [TC-HP-001](url) or description |

### Feature Test Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-XXX-001 | Description | PASS/FAIL | [TC-XXX-001](url) or description |

### Regression Tests
| Test | Status |
|------|--------|
| Auth login/logout | PASS/FAIL |
| Navigation | PASS/FAIL |
| Console errors | PASS/FAIL |

### Amazon Q Developer Review
| Check | Status |
|-------|--------|
| Q review triggered | PASS/FAIL |
| Q review received | PASS/FAIL |
| All Q threads resolved | PASS/FAIL |
\`\`\`
E2E_BLOCK
fi)

## Decision
After thorough review:

- If ALL checklist items pass AND code quality is good$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo " AND all E2E tests pass"; fi):
  Post a comment on issue #${ISSUE_NUMBER} with:
  "Review PASSED - All checklist items verified, code quality good.$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo " E2E verification completed."; fi)"
  Then exit.

- If ANY item fails$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo " OR any E2E test fails OR preview URL is unavailable"; fi):
  Post a comment on issue #${ISSUE_NUMBER} with:
  "Review findings:"
  followed by a numbered list of each failing item with specific remediation instructions.$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo "
  Include E2E failure details with screenshot evidence."; fi)
  Then exit.

IMPORTANT: Work autonomously. Be thorough but fair. Focus on correctness and compliance.
$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo "E2E verification is MANDATORY — do NOT skip it, do NOT treat it as optional."; fi)
EOF
)"

# ---------------------------------------------------------------------------
# Run CC review
# ---------------------------------------------------------------------------
SESSION_ID=$(uuidgen)
log "Starting review session: ${SESSION_ID} (model: ${AGENT_REVIEW_MODEL:-sonnet})"

set +e
run_agent "$SESSION_ID" "$PROMPT" "${AGENT_REVIEW_MODEL:-sonnet}" 2>&1 | tee "$LOG_FILE"
CC_EXIT=${PIPESTATUS[0]}
set -e

log "Review CC exited with code: $CC_EXIT"

# ---------------------------------------------------------------------------
# Parse result and update issue/PR state
# ---------------------------------------------------------------------------
log "Parsing review result from issue comments..."

# Poll for the agent's review comment (contains "Review PASSED" or "Review findings:")
# Retry up to 6 times (30s total) to avoid race conditions with concurrent comments
LATEST_COMMENT=""
for _poll_attempt in $(seq 1 6); do
  sleep 5
  # Find the most recent comment that matches the review output format
  LATEST_COMMENT=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | test("Review PASSED|Review findings:"; "i"))] | last | .body' 2>/dev/null || true)
  if [[ -n "$LATEST_COMMENT" ]]; then
    break
  fi
  log "Waiting for review comment to appear (attempt ${_poll_attempt}/6)..."
done

if echo "$LATEST_COMMENT" | grep -qi "Review PASSED"; then
  log "Review PASSED for PR #${PR_NUMBER}."

  # Formal PR approval from review agent
  if ! refresh_token_env; then
    log "ERROR: Token refresh failed — token daemon may have crashed. Attempting approval with current token..."
  fi
  log "Submitting PR approval for PR #${PR_NUMBER}..."
  if gh pr review "$PR_NUMBER" --repo "$REPO" --approve \
    --body "All acceptance criteria verified.$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo " E2E verification passed."; fi)" 2>&1; then
    log "PR #${PR_NUMBER} approved successfully."
  else
    log "ERROR: Failed to submit PR approval for PR #${PR_NUMBER}."
    log "Falling back to manual review notification."
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review PASSED but formal PR approval failed (permission issue?). @${REPO_OWNER} please approve and merge PR #${PR_NUMBER} manually." 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" \
      --add-label "approved" 2>/dev/null || true
    log "Issue #${ISSUE_NUMBER} marked as approved. Manual merge required due to approval failure."
    exit 0
  fi

  # Check if issue has the 'no-auto-close' label
  HAS_NO_AUTO_CLOSE=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels \
    -q '[.labels[].name] | any(. == "no-auto-close")' 2>/dev/null || echo "false")

  if [[ "$HAS_NO_AUTO_CLOSE" == "true" ]]; then
    log "Issue has 'no-auto-close' label — skipping auto-merge."

    # Notify project owner to merge manually
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review PASSED — this issue has the 'no-auto-close' label. @${REPO_OWNER} please review and merge PR #${PR_NUMBER} when ready." 2>/dev/null || true

    # Update labels: remove reviewing, add approved (keep no-auto-close and autonomous)
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" \
      --add-label "approved" 2>/dev/null || true

    log "Issue #${ISSUE_NUMBER} marked as approved. Awaiting manual merge."
  else
    log "Merging PR #${PR_NUMBER}..."

    # Merge PR (squash)
    if gh pr merge "$PR_NUMBER" --repo "$REPO" --squash --delete-branch 2>&1; then
      log "PR #${PR_NUMBER} merged successfully."
    else
      log "WARNING: Auto-merge failed. PR may need manual merge."
      gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
        --body "Review passed but auto-merge failed. Please merge PR #${PR_NUMBER} manually." 2>/dev/null || true
    fi

    # Close issue and update labels
    gh issue close "$ISSUE_NUMBER" --repo "$REPO" --reason completed 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" --remove-label "autonomous" \
      --add-label "approved" 2>/dev/null || true

    log "Issue #${ISSUE_NUMBER} closed as completed."
  fi
else
  log "Review FAILED or inconclusive. Sending back to dev."

  # If CC crashed without posting a comment, add a fallback
  if [[ $CC_EXIT -ne 0 ]] && [[ -z "$LATEST_COMMENT" ]]; then
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review process encountered an error (CC exit code: ${CC_EXIT}). Moving back to development for investigation." 2>/dev/null || true
  fi

  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "reviewing" \
    --add-label "pending-dev" 2>/dev/null || true

  log "Issue #${ISSUE_NUMBER} moved to pending-dev."
fi

log "Review complete."
exit 0
