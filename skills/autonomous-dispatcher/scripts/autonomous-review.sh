#!/bin/bash
# autonomous-review.sh — Wrapper for autonomous review agent tasks.
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

# [INV-14] Use BASH_SOURCE[0] (NOT readlink -f) so a project-side symlink
# at <project>/scripts/autonomous-review.sh resolves SCRIPT_DIR to the
# project's scripts/. lib-agent.sh's load_autonomous_conf then finds
# autonomous.conf via tier-2 (same dir).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${SCRIPT_DIR}/lib-agent.sh"
source "${SCRIPT_DIR}/lib-auth.sh"
# shellcheck source=lib-review-bots.sh
source "${SCRIPT_DIR}/lib-review-bots.sh"

# Validate required config (loaded by lib-agent.sh from autonomous.conf)
: "${PROJECT_ID:?Set PROJECT_ID in autonomous.conf}"
: "${REPO:?Set REPO in autonomous.conf}"
: "${REPO_OWNER:?Set REPO_OWNER in autonomous.conf}"
: "${REPO_NAME:?Set REPO_NAME in autonomous.conf}"
: "${PROJECT_DIR:?Set PROJECT_DIR in autonomous.conf}"

# Validate REVIEW_BOTS at startup so a typo (e.g. REVIEW_BOTS="q codx")
# fails fast with a clear error instead of silently dropping the bot.
# Empty REVIEW_BOTS is allowed — the bot-review section is omitted from
# the prompt entirely and the review agent proceeds without bot
# enforcement.
REVIEW_BOTS_VALIDATED=$(parse_review_bots "${REVIEW_BOTS:-}") || exit 1

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

# Bot identity for downstream telemetry / cost attribution.
# Picked up by AGENT_LAUNCHER (e.g. user's `cc` shell function) when set;
# harmless extra env when AGENT_LAUNCHER is empty.
export CC_USER="${CC_USER:-autonomous-review-bot}"
export CC_ROLE_KIND="${CC_ROLE_KIND:-review}"

LOG_FILE="/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUMBER}.log"
# PID file lives in the per-user PID dir (closes #72). pid_dir_for_project
# is in lib-config.sh, sourced transitively via lib-agent.sh.
PID_DIR=$(pid_dir_for_project) || { echo "ERROR: cannot resolve PID dir" >&2; exit 1; }
PID_FILE="${PID_DIR}/review-${ISSUE_NUMBER}.pid"

# Create log file with restrictive permissions (sensitive agent output)
# Note: log file is created by nohup redirect in dispatch-local.sh.
# Do NOT truncate it here (install -m 600 /dev/null would destroy nohup output).

# Forward dispatcher TERM to the agent's process group (#109).
# Without this, the timeout/agent subtree gets reparented to PID 1 when
# the wrapper exits and the next tick can't reach it through PID_FILE.
# install_agent_sigterm_trap (lib-agent.sh) sets RECEIVED_SIGTERM=1 and
# group-kills via _AGENT_RUN_PID. Review doesn't read RECEIVED_SIGTERM
# anywhere (no INV-15 equivalent here), but the contract is shared with
# autonomous-dev.sh so the trap is identical.
install_agent_sigterm_trap

# PID guard: prevent duplicate instances for the same issue.
# acquire_pid_guard writes $$ as a placeholder; _run_with_timeout
# rewrites the file with the agent's session-leader PID (== PGID).
acquire_pid_guard "$PID_FILE" "autonomous-review" "$ISSUE_NUMBER"
export AGENT_PID_FILE="$PID_FILE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[autonomous-review] $(date -u +%H:%M:%S) $*"; }

# Track whether normal result parsing completed (set at end of script)
RESULT_PARSED=false

cleanup() {
  local exit_code=$?

  # Cleanup PID file always
  rm -f "$PID_FILE" 2>/dev/null || true

  # If result was already parsed by the main script, labels are handled there
  if [[ "$RESULT_PARSED" == "true" ]]; then
    cleanup_github_auth
    return
  fi

  # Crash path: review agent died before parsing results — transition labels
  if [[ $exit_code -ne 0 ]]; then
    log "Review process crashed (exit $exit_code). Updating issue labels..."

    # Refresh token for cleanup (app mode)
    if [[ "$GH_AUTH_MODE" == "app" ]]; then
      if command -v get_gh_app_token &>/dev/null; then
        GH_TOKEN=$(get_gh_app_token "${REVIEW_AGENT_APP_ID}" "${REVIEW_AGENT_APP_PEM}" "$REPO_OWNER" "$REPO_NAME") || {
          log "WARNING: Failed to refresh GitHub App token for cleanup"
        }
        export GH_TOKEN
        export GITHUB_PERSONAL_ACCESS_TOKEN="$GH_TOKEN"
      fi
    fi

    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review process crashed (exit code: ${exit_code}). Moving back to development for retry." 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" \
      --add-label "pending-dev" 2>/dev/null || true

    log "Issue #${ISSUE_NUMBER} moved to pending-dev due to crash."
  fi

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
if [[ "${E2E_SCREENSHOT_UPLOAD:-false}" == "true" && -x "${PROJECT_DIR}/skills/autonomous-review/scripts/upload-screenshot.sh" ]]; then
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
PR_HEAD_SHA=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid -q '.headRefOid' 2>/dev/null || true)
log "PR branch: ${PR_BRANCH:-UNKNOWN} (HEAD: ${PR_HEAD_SHA:0:7})"

SESSION_ID=$(uuidgen)

# Verdict-detection bindings: actor + time window + body-trailer
# presence. Replaces the prior session-id-only binding (which depended
# on the agent echoing the wrapper's UUID verbatim).
#
# WRAPPER_START_TS — ISO-8601 UTC captured BEFORE run_agent. Verdict
# comments older than this are stale (prior tick) and ignored.
WRAPPER_START_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# BOT_LOGIN — the bot identity this wrapper authenticates as. We need
# the diagnostic on failure (token expired, GH App perms reduced, rate
# limit, etc.) so the operator can debug, but we deliberately limit
# what we log: a 200-char head of stderr only, no full body. `gh api`
# stderr is a JSON error body which is generally safe to log, but
# truncation is defense-in-depth against a future gh release that
# might surface request-context headers.
_bot_login_raw=$(gh api user --jq '.login' 2>&1) && BOT_LOGIN="$_bot_login_raw" || {
  log "WARNING: gh api user failed; verdict detector falling back to session-id binding. stderr (truncated): ${_bot_login_raw:0:200}"
  BOT_LOGIN=""
}
# A literal "null" string can come back from `--jq '.login'` if /user
# returns null (rare App-token misconfig). Treat as failure.
if [[ "$BOT_LOGIN" == "null" || -z "$BOT_LOGIN" ]]; then
  [[ "$BOT_LOGIN" == "null" ]] && log "WARNING: gh api user returned null login; falling back to session-id binding"
  BOT_LOGIN=""
fi
if [[ -n "$BOT_LOGIN" ]]; then
  log "Verdict will bind to actor=${BOT_LOGIN}, createdAt >= ${WRAPPER_START_TS}, body must contain 'Review Session'"
fi

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
4. If rebase fails (conflicts) — FAIL the review with "[BLOCKING] Merge conflict with main".
   Include the list of conflicting files and step-by-step instructions for the dev agent:
   \`git fetch origin main\`, \`git rebase origin/main\`, resolve conflicts, \`git rebase --continue\`,
   \`git push --force-with-lease origin ${PR_BRANCH}\`. Then exit.
5. If "UNKNOWN" — wait 10s and retry up to 3 times

## Step 0.5: Requirement Drift Detection — MANDATORY PRE-REVIEW

**Before reading the PR diff**, read ALL comments on issue #${ISSUE_NUMBER} to detect requirement changes posted after implementation:

\`\`\`bash
gh issue view ${ISSUE_NUMBER} --repo ${REPO} --json comments \\
  -q '.comments[] | "\\(.author.login) [\\(.createdAt)]: \\(.body[0:500])"'
\`\`\`

Look for:
- Scope changes ("remove", "no longer", "drop", "don't support", "instead of")
- New requirements added after the original issue
- Corrections or clarifications from the repo owner (@${REPO_OWNER})
- Explicit instructions to the dev agent that may not yet be reflected in the PR code

**If any requirement change is found that the PR code does NOT reflect, this is a [BLOCKING] Requirement drift finding.** Quote the comment and list the specific code that needs updating.

## Review Checklist
Verify ALL of the following were completed:

1. [ ] Design canvas created (docs/designs/ or docs/plans/)
2. [ ] Git worktree used (branch name starts with feat/, fix/, etc.)
3. [ ] Test cases documented (docs/test-cases/)
4. [ ] Unit tests written and passing
5. [ ] E2E tests written/updated if UI changes
6. [ ] CI checks all passing
$(if [[ "${AGENT_CMD:-claude}" != "kiro" ]]; then cat <<'CHECKLIST_EXTRA'
7. [ ] code-simplifier review passed
8. [ ] PR review agent review passed
9. [ ] Reviewer bot findings addressed
10. [ ] PR description follows template
CHECKLIST_EXTRA
else cat <<'CHECKLIST_KIRO'
7. [ ] Reviewer bot findings addressed
8. [ ] PR description follows template
CHECKLIST_KIRO
fi)

## Acceptance Criteria Verification — MANDATORY
Read the issue body for an \`## Acceptance Criteria\` section. For EACH criterion:
1. Verify whether the PR implementation satisfies it (check code, tests, build output)
2. If verified, mark the checkbox as complete using the mark-issue-checkbox script:
   \`\`\`bash
   bash scripts/mark-issue-checkbox.sh ${REPO_OWNER} ${REPO_NAME} ${ISSUE_NUMBER} "the exact checkbox text"
   \`\`\`
3. If NOT verified, leave unchecked and include it in your review findings

## Review Process
1. Read the issue body to understand requirements
2. Read ALL issue comments to detect requirement changes (Step 0.5 above)
3. Read the PR diff to verify implementation
4. Verify acceptance criteria (see above)
5. Check that CI checks are passing: gh pr checks ${PR_NUMBER}
6. Verify test coverage and quality
7. Check for security issues, code quality, and best practices
8. Trigger and verify configured review bots (see below)$(if [[ -z "$REVIEW_BOTS_VALIDATED" ]]; then printf '\n   (REVIEW_BOTS is empty — bot-review enforcement is disabled for this project.)'; fi)

$(render_bot_review_section "$REVIEW_BOTS_VALIDATED" "$PR_NUMBER" "$REPO")

$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then cat <<E2E_BLOCK
## E2E Verification via Chrome DevTools MCP — MANDATORY

**This section is NON-NEGOTIABLE. You MUST perform E2E verification using Chrome DevTools MCP.**

Preview URL: ${PREVIEW_URL:-NOT_FOUND}
Test user email: available via \\\$E2E_TEST_USER_EMAIL environment variable
Test user password: available via \\\$E2E_TEST_USER_PASSWORD environment variable
Screenshot upload available: ${SCREENSHOT_UPLOAD_AVAILABLE}

NOTE: E2E credentials are passed as environment variables for security.
Read them at runtime: \\\$(printenv E2E_TEST_USER_EMAIL) and \\\$(printenv E2E_TEST_USER_PASSWORD)

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
|-------|--------|--------|--------|
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

### Configured Review Bots ($(if [[ -n "$REVIEW_BOTS_VALIDATED" ]]; then echo "$REVIEW_BOTS_VALIDATED"; else echo "none configured"; fi))
| Bot | Triggered | Review received | All threads resolved |
|-----|-----------|-----------------|----------------------|
$(if [[ -n "$REVIEW_BOTS_VALIDATED" ]]; then
  for _bot in $REVIEW_BOTS_VALIDATED; do
    echo "| ${_bot} | PASS/FAIL | PASS/FAIL | PASS/FAIL |"
  done
else
  echo "| (none) | n/a | n/a | n/a |"
fi)
\`\`\`
E2E_BLOCK
fi)

## Decision
After thorough review:

**CRITICAL — verdict phrasing**: the wrapper script polls for your
verdict comment by matching specific keywords. If your comment doesn't
contain one of the recognized phrasings, the wrapper falls through to
the FAILED branch and the dispatcher will eventually mark the issue
\`stalled\` after \`MAX_RETRIES\` (closes #95). Use the EXACT prefix
shown below — alternative phrasings like "APPROVED FOR MERGE" or "LGTM"
also work, but stick to the canonical form when possible.

- If ALL checklist items pass AND code quality is good$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo " AND all E2E tests pass"; fi) AND no requirement drift detected:
  Post a comment on issue #${ISSUE_NUMBER} starting with the exact text
  **\`Review PASSED\`** on the FIRST LINE, like:

  > Review PASSED - All checklist items verified, code quality good.$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo " E2E verification completed."; fi) No requirement drift.
  > Review Session: \`${SESSION_ID}\`

  Then exit.

- If ANY item fails$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo " OR any E2E test fails OR preview URL is unavailable"; fi) OR requirement drift is detected:
  Post a comment on issue #${ISSUE_NUMBER} starting with the exact text
  **\`Review findings:\`** on the FIRST LINE, followed by a numbered list
  of each failing item with specific remediation instructions.$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo "
  Include E2E failure details with screenshot evidence."; fi)
  End the comment with: \`Review Session: \\\`${SESSION_ID}\\\`\`
  Then exit.

IMPORTANT: Work autonomously. Be thorough but fair. Focus on correctness and compliance.
$(if [[ "${E2E_ENABLED:-false}" == "true" ]]; then echo "E2E verification is MANDATORY — do NOT skip it, do NOT treat it as optional."; fi)
EOF
)"

# ---------------------------------------------------------------------------
# Run review agent
# ---------------------------------------------------------------------------
SESSION_NAME="review-pr-${PR_NUMBER}-issue-${ISSUE_NUMBER}"
log "Starting review session: ${SESSION_ID} (name: ${SESSION_NAME}, model: ${AGENT_REVIEW_MODEL:-sonnet})"

# Export E2E credentials as env vars (not in prompt) for agent to read at runtime
if [[ "${E2E_ENABLED:-false}" == "true" ]]; then
  export E2E_TEST_USER_EMAIL="${E2E_TEST_USER_EMAIL:-}"
  export E2E_TEST_USER_PASSWORD="${E2E_TEST_USER_PASSWORD:-}"
fi

set +e
run_agent "$SESSION_ID" "$PROMPT" "${AGENT_REVIEW_MODEL:-sonnet}" "$SESSION_NAME" 2>&1
AGENT_EXIT=$?
set -e

log "Review agent exited with code: $AGENT_EXIT"

# ---------------------------------------------------------------------------
# Parse result and update issue/PR state
# ---------------------------------------------------------------------------
log "Parsing review result from issue comments..."

# Poll for the agent's review comment.
#
# Pattern (closes #95): the verdict-keyword regex accepts canonical
# phrasings ("Review PASSED" / "Review findings:") plus common drift
# variants (APPROVED FOR MERGE, Review APPROVED, LGTM, Review FAILED,
# Review REJECTED, Changes requested). The pass-vs-fail decision is
# made below by the classification grep — this polling step only
# narrows down to "this looks like a verdict comment".
#
# Authenticity binding: see the predicate construction below for the
# three-layer rationale (actor + time window + body trailer).
#
# Why we no longer bind to the wrapper's specific session UUID: the
# agent occasionally rewrites the Review Session UUID in its comment
# body, so a strict body-text match would miss valid verdicts and the
# wrapper would fall through to the no-verdict-found FAILED branch.
# Actor and time window are observed by the wrapper itself and cannot
# be rewritten by the agent.
#
# Fallback: if `gh api user` returned empty at startup (BOT_LOGIN unset),
# keep the body-text match against the wrapper's session_id so a
# transient auth/API blip at the top of the wrapper doesn't strip all
# spoof protection.
#
# Retry up to 6 times (30s total) to avoid race conditions.
LATEST_COMMENT=""
_VERDICT_RE='Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS|Review findings:|Review FAILED|Review REJECTED|Changes requested'
# Build the authenticity predicate once. Three layers, all required:
#
#   (a) actor (BOT_LOGIN) — when known, gates on the bot identity. In
#       GH_AUTH_MODE=app this is the review-app's distinct login, so a
#       concurrent dev wrapper can't spoof. In GH_AUTH_MODE=token dev
#       and review share an identity, so this layer alone is insufficient.
#
#   (b) time window (WRAPPER_START_TS) — gates on createdAt, isolating
#       the current review run from stale comments left by a prior tick.
#
#   (c) "Review Session" body trailer — a literal substring the review
#       agent's prompt instructs it to emit. Does NOT bind to the
#       wrapper's specific UUID (the prior brittleness this PR removes),
#       only to the trailer's presence. This excludes the dev agent's status
#       comments that happen to contain "Review findings" / "LGTM"
#       inside a quoted prior verdict — those won't have the trailer.
#
# Fallback (BOT_LOGIN empty): drop (a), keep (b) and (c). The session-id
# is included in (c)'s match for additional narrowing when actor is
# unavailable.
if [[ -n "$BOT_LOGIN" ]]; then
  _AUTH_PREDICATE="(.author.login == \"${BOT_LOGIN}\") and (.createdAt >= \"${WRAPPER_START_TS}\") and (.body | test(\"Review Session\"))"
else
  _AUTH_PREDICATE="(.createdAt >= \"${WRAPPER_START_TS}\") and (.body | test(\"Review Session.*${SESSION_ID}\"))"
fi
_VERDICT_JQ="[.comments[] | select(${_AUTH_PREDICATE} and (.body | test(\"${_VERDICT_RE}\"; \"i\")))] | last | .body"
for _poll_attempt in $(seq 1 6); do
  sleep 5
  LATEST_COMMENT=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \
    -q "$_VERDICT_JQ" 2>/dev/null || true)
  if [[ -n "$LATEST_COMMENT" ]]; then
    break
  fi
  log "Waiting for review comment to appear (attempt ${_poll_attempt}/6)..."
done

# Post a "Reviewed HEAD" trailer comment so the dispatcher can detect whether
# new commits have landed since the last review. The dispatcher uses this to
# decide between routing a dead-with-PR transition to pending-review (new code
# to review) vs. pending-dev (no new code, retry dev).
# Only emitted when the agent produced a verdict comment — a missing verdict
# already routes to pending-dev via the FAILED branch below.
if [[ -n "$LATEST_COMMENT" && -n "$PR_HEAD_SHA" ]]; then
  # Capture stderr so token/permission/rate-limit failures are diagnosable.
  # If this post fails persistently the dispatcher cannot detect SHA-match,
  # so the WARNING is the only operator-visible breadcrumb (see SKILL.md
  # Step 5 empty-trailer fallthrough).
  _trailer_err=$(gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "Reviewed HEAD: \`${PR_HEAD_SHA}\` (issue #${ISSUE_NUMBER}, session \`${SESSION_ID}\`)" \
    2>&1 >/dev/null) \
    || log "WARNING: Failed to post Reviewed HEAD trailer (non-fatal): ${_trailer_err}"
fi

# Classify the verdict (closes #95). Conservative ambiguity rule:
# if BOTH a pass-pattern and a fail-pattern appear in the body, treat
# the comment as FAIL — the agent flagged at least one issue.
# Drop the `head -1` constraint that the previous code used: some agents
# put a heading on line 1 and the verdict on line 2. The session-id
# binding above provides authenticity; line position doesn't add safety.
if echo "$LATEST_COMMENT" | grep -qiE 'Review (FAILED|REJECTED)|Review findings:|Changes requested'; then
  PASSED_VERDICT=false
elif echo "$LATEST_COMMENT" | grep -qiE 'Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS'; then
  PASSED_VERDICT=true
else
  PASSED_VERDICT=false
fi

if [[ "$PASSED_VERDICT" == "true" ]]; then
  log "Review PASSED for PR #${PR_NUMBER}."

  # ---------------------------------------------------------------------------
  # Guard: verify PR is still open before approving/merging.
  # A concurrent review (e.g. manual `/q review` + dispatcher) may have already
  # approved and merged the PR while this review was running.
  # ---------------------------------------------------------------------------
  PR_STATE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
  if [[ "$PR_STATE" != "OPEN" ]]; then
    log "PR #${PR_NUMBER} is no longer open (state: ${PR_STATE}). Skipping approve/merge — another review likely completed first."
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "reviewing" 2>/dev/null || true
    RESULT_PARSED=true
    exit 0
  fi

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

  # If agent crashed without posting a comment, add a fallback
  if [[ $AGENT_EXIT -ne 0 ]] && [[ -z "$LATEST_COMMENT" ]]; then
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "Review process encountered an error (agent exit code: ${AGENT_EXIT}). Moving back to development for investigation." 2>/dev/null || true
  fi

  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "reviewing" \
    --add-label "pending-dev" 2>/dev/null || true

  log "Issue #${ISSUE_NUMBER} moved to pending-dev."
fi

RESULT_PARSED=true
log "Review complete."
exit 0
