# E2E Verification Configuration Template

## Overview

E2E (End-to-End) verification is an optional but powerful component of the autonomous review pipeline. When enabled, the review agent uses Chrome DevTools MCP to navigate a deployed preview of the PR, execute test cases against a live environment, and capture screenshots as evidence.

This document explains how to configure E2E verification for your project.

## Configuration Variables

All E2E configuration is set in `scripts/autonomous.conf`:

```bash
# === E2E Verification (optional) ===
E2E_ENABLED="true"
E2E_PREVIEW_URL_PATTERN="https://pr-{N}.preview.example.com"
E2E_TEST_USER_EMAIL="test@example.com"
E2E_TEST_USER_PASSWORD="SecureTestPass1#"
E2E_SCREENSHOT_UPLOAD="true"
```

### Variable Reference

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `E2E_ENABLED` | Enable E2E verification during review | `false` | No |
| `E2E_PREVIEW_URL_PATTERN` | URL template for PR preview environments | — | If E2E enabled |
| `E2E_TEST_USER_EMAIL` | Email for test user login | — | If E2E enabled |
| `E2E_TEST_USER_PASSWORD` | Password for test user login | — | If E2E enabled |
| `E2E_SCREENSHOT_UPLOAD` | Upload screenshots to GitHub as evidence | `false` | No |

## Preview URL Pattern

The `E2E_PREVIEW_URL_PATTERN` variable uses `{N}` as a placeholder for the PR number. The review script replaces `{N}` with the actual PR number before passing it to the review agent.

### Examples

| CI/CD Platform | Pattern | Result for PR #42 |
|----------------|---------|-------------------|
| Vercel | `https://pr-{N}.preview.example.com` | `https://pr-42.preview.example.com` |
| Netlify | `https://deploy-preview-{N}--mysite.netlify.app` | `https://deploy-preview-42--mysite.netlify.app` |
| AWS Amplify | `https://pr-{N}.d123456.amplifyapp.com` | `https://pr-42.d123456.amplifyapp.com` |
| Custom | `https://{N}.staging.example.com` | `https://42.staging.example.com` |

### Dynamic URL Extraction

If your preview URL is posted as a PR comment by your CI/CD pipeline (rather than following a predictable pattern), the review script also tries to extract the URL from PR comments. It searches for comments containing "Preview" and extracts the first HTTPS URL.

To use this approach:
1. Set `E2E_PREVIEW_URL_PATTERN` to an empty string or a fallback pattern
2. Ensure your deploy workflow posts a comment with the preview URL

## Test User Setup

The E2E verification requires a test user account on the preview environment. This user must be pre-created and have stable credentials.

### Requirements

- The test user must exist in the preview environment's authentication system
- Credentials must remain constant across PR deployments
- The test user should have sufficient permissions to exercise all test cases

### Example: Cognito User Pool

If your project uses AWS Cognito, create the test user after each PR preview deployment:

```bash
# Get the User Pool ID for the PR environment
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 50 --region us-east-1 \
  --query "UserPools[?contains(Name, 'pr-<PR_NUMBER>')].Id | [0]" --output text)

# Create test user
aws cognito-idp admin-create-user \
  --user-pool-id $USER_POOL_ID --region us-east-1 \
  --username "test@example.com" \
  --user-attributes Name=email,Value="test@example.com" Name=email_verified,Value=true \
  --message-action SUPPRESS 2>/dev/null || true

# Set permanent password
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID --region us-east-1 \
  --username "test@example.com" \
  --password "SecureTestPass1#" --permanent
```

Consider adding this to your CI/CD pipeline so the test user is automatically created when the preview deploys.

### Example: Other Auth Providers

For other authentication systems, adapt the user creation to your provider:
- **Auth0**: Use the Management API to create a test user
- **Firebase Auth**: Use the Admin SDK
- **Custom auth**: Seed the database directly

## Test Case Organization

Test case documents guide the review agent on what to verify during E2E testing.

### Directory Structure

```
docs/
  test-cases/
    auth.md               # Authentication test cases
    plan-generation.md     # Plan generation feature tests
    navigation.md          # Navigation and routing tests
    ...
```

### Naming Conventions

- File name matches the feature area: `docs/test-cases/<feature>.md`
- Test IDs follow the pattern: `TC-<FEATURE>-<NNN>` (e.g., `TC-AUTH-001`)
- Happy path cases use: `TC-HP-<NNN>` (e.g., `TC-HP-001`)

### Test Case Document Template

Use `docs/templates/test-case-template.md` as a starting point. Each test case should include:

```markdown
### TC-FEAT-001: Scenario Name
- **Description**: What is being tested
- **Preconditions**: Setup required
- **Test Steps**:
  1. Navigate to /page
  2. Click "Button"
  3. Verify result
- **Expected Result**: What should happen
- **Priority**: P0/P1/P2
```

### How the Review Agent Selects Test Cases

1. The agent reads the PR diff to identify changed areas
2. It scans `docs/test-cases/` for matching test case documents
3. It selects the most relevant cases covering the changed functionality
4. At minimum, one happy path case is executed per review

If no test case documents exist, the agent falls back to a basic smoke test:
- Navigate to the application root URL
- Verify the page loads without errors
- Check browser console for JavaScript errors

## Screenshot Upload Setup

When `E2E_SCREENSHOT_UPLOAD=true`, the review agent uploads screenshots to GitHub after each `take_screenshot` call.

### How It Works

1. The agent captures a screenshot via Chrome DevTools MCP
2. It runs `scripts/upload-screenshot.sh <path> <pr-number> <test-case-id>`
3. The script commits the PNG to a `screenshots` branch in the repository
4. The script returns a GitHub blob URL viewable by repo members
5. The agent includes the URL as a clickable link in the E2E report

### Prerequisites

- The `scripts/upload-screenshot.sh` script must be executable
- The GitHub token must have Contents (Write) permission
- The repository must allow pushes to the `screenshots` branch

### Private Repository Note

For private repositories, inline images (`![img](url)`) do not render because `raw.githubusercontent.com` requires authentication. The upload script returns `/blob/` URLs instead, which render natively in GitHub's web UI for authenticated users.

## Chrome DevTools MCP Requirements

E2E verification requires Chrome DevTools MCP to be available in the agent's environment.

### Required MCP Tools

| Tool | Purpose |
|------|---------|
| `new_page` | Open a fresh browser tab |
| `navigate_page` | Navigate to a URL |
| `wait_for` | Wait for an element to appear |
| `click` | Click an element |
| `fill` | Fill an input field |
| `type_text` | Type text (for inputs requiring keystroke events) |
| `take_screenshot` | Capture the current page as a PNG |
| `list_console_messages` | Check for JavaScript errors |

### Setup

Ensure Chrome DevTools MCP is configured in the agent's MCP settings. The specific setup depends on your agent and MCP server configuration.

## Full Configuration Example

```bash
# scripts/autonomous.conf

# === Project Identity ===
PROJECT_ID="my-app"
REPO="myorg/my-app"
REPO_OWNER="myorg"
REPO_NAME="my-app"
PROJECT_DIR="/home/user/my-app"

# === Agent Configuration ===
AGENT_CMD="claude"
AGENT_DEV_MODEL=""
AGENT_REVIEW_MODEL="sonnet"

# === GitHub Authentication ===
GH_AUTH_MODE="app"
DEV_AGENT_APP_ID="111111"
DEV_AGENT_APP_PEM="/home/user/my-app/.github-apps/dev-agent.pem"
REVIEW_AGENT_APP_ID="222222"
REVIEW_AGENT_APP_PEM="/home/user/my-app/.github-apps/review-agent.pem"
DISPATCHER_APP_ID="333333"
DISPATCHER_APP_PEM="/home/user/my-app/.github-apps/dispatcher.pem"

# === Concurrency ===
MAX_CONCURRENT=3

# === E2E Verification ===
E2E_ENABLED="true"
E2E_PREVIEW_URL_PATTERN="https://pr-{N}.preview.my-app.com"
E2E_TEST_USER_EMAIL="e2e-test@my-app.com"
E2E_TEST_USER_PASSWORD="E2eTestPass1#"
E2E_SCREENSHOT_UPLOAD="true"
```
