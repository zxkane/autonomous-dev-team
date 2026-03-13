# E2E Verification Procedure

> **This section applies only when E2E verification is configured.** The review wrapper script (`autonomous-review.sh`) will indicate whether E2E is enabled and provide the necessary configuration in the prompt.

## Prerequisites

The review script (`autonomous-review.sh`) extracts and provides:
- **Preview URL**: Preview URL extracted from PR comments or provided by the review wrapper
- **Test user email**: from `{E2E_TEST_USER_EMAIL}` env var
- **Test user password**: from `{E2E_TEST_USER_PASSWORD}` env var
- **Screenshot upload script**: `scripts/upload-screenshot.sh` for uploading screenshots to GitHub

## Step-by-Step Procedure

### 1. Verify Preview URL
- Check that the preview URL was provided in the prompt
- If `NOT_FOUND`, immediately fail the review with: "E2E verification failed: PR preview URL not found"

### 2. Open Browser and Navigate
```
Use Chrome DevTools MCP tools:
1. new_page -> open a fresh browser page
2. navigate_page -> go to the preview URL
3. wait_for -> confirm page loads (wait for a known element)
4. take_screenshot -> capture landing page
5. Upload screenshot immediately:
   bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "landing-page"
```

### 3. Login with Test User
```
1. Click sign-in / login button
2. fill -> enter email in the email field
3. fill -> enter password in the password field
4. Click submit / sign-in button
5. wait_for -> confirm redirect to authenticated page (e.g., dashboard)
6. take_screenshot -> capture authenticated state
7. Upload screenshot immediately:
   bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "auth-login"
```

### 4. Execute Happy Path Test Cases
- Based on the selection logic above, execute the chosen happy path cases
- **CRITICAL**: After EVERY `take_screenshot`, you MUST immediately run the upload command:
  ```bash
  SCREENSHOT_URL=$(bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "<TC-ID>")
  ```
  Store the returned URL for use in the E2E report table.
- For each case:
  1. Follow the detailed steps in the case definition
  2. Use Chrome DevTools MCP tools (navigate_page, click, fill, wait_for, type_text, etc.)
  3. `take_screenshot` at key verification points
  4. **Immediately** upload each screenshot: `bash scripts/upload-screenshot.sh "<path>" "<PR>" "<TC-ID>"`
  5. Record PASS or FAIL with the uploaded screenshot URL as a clickable link `[TC-ID](url)`

### 5. Execute Feature Test Cases
- Read `docs/test-cases/<feature>.md` for the feature under review
- For each test case:
  1. Follow the test steps using Chrome DevTools MCP tools
  2. Verify expected outcomes by inspecting visible page content
  3. `take_screenshot` at each key verification point
  4. **Immediately** upload: `bash scripts/upload-screenshot.sh "<path>" "<PR>" "<TC-ID>"`
  5. Record PASS or FAIL with a clickable link `[TC-ID](url)`

### 6. Regression Checks
- **Auth**: Verify login/logout works
- **Navigation**: Click through main sidebar links, verify pages load
- **Console errors**: Use `list_console_messages` to check for JS errors

### 7. Post E2E Report
Post a structured comment on the **PR** (not the issue) with this format:

```markdown
## E2E Verification Report

### Summary
| Total | Passed | Failed | Skipped |
|-------|--------|--------|---------|
| N     | X      | Y      | Z       |

### Happy Path Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-HP-001 | Generate 1-week plan | PASS | [TC-HP-001](<upload-script-returned-url>) |

### Feature Test Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-XXX-001 | Description | PASS | [TC-XXX-001](<upload-script-returned-url>) |

### Regression Tests
| Test | Status |
|------|--------|
| Auth login/logout | PASS |
| Navigation | PASS |
| Console errors | PASS |
```

## Happy Path Test Cases

Happy path test cases are project-specific. The review agent selects cases based on:

1. Read `docs/test-cases/` directory for available test case documents
2. Analyze the PR diff to determine which areas changed
3. Select the most relevant test cases covering changed functionality
4. Execute at least one happy path test case per review

If no test case documents exist, execute a basic smoke test:
- Navigate to the application root URL
- Verify the page loads without errors
- Check browser console for JavaScript errors

## Screenshot Publishing

When using Chrome DevTools MCP to take screenshots during E2E verification, **upload them to GitHub and link them in PR comments**.

> **Private repo limitation**: Inline images (`![img](url)`) do not render for private repos because `raw.githubusercontent.com` requires authentication that GitHub's markdown renderer does not inject. Instead, use **clickable links** to `/blob/` URLs — GitHub's web UI renders PNG files natively for authenticated users with repo access.

### Upload Workflow

After each `take_screenshot`, run the upload helper script to get a GitHub blob URL:

```bash
# Usage: scripts/upload-screenshot.sh <png-path> <pr-number> <test-case-id>
# Returns: GitHub blob URL viewable by repo members

URL=$(scripts/upload-screenshot.sh /tmp/screenshot.png 42 TC-HP-001)
# -> https://github.com/{REPO}/blob/screenshots/pr-42/TC-HP-001.png
```

Execute in your terminal to upload from within the review session:

```bash
SCREENSHOT_URL=$(bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "<TC-ID>")
```

### Link Format

Use clickable links (NOT inline images) in the E2E report table:

```markdown
| TC-HP-001 | Generate 1-week plan | PASS | [TC-HP-001](<uploaded-url>) |
```

### Fallback Behavior

If the upload script fails (e.g., network issue, permission error):
1. The script outputs `UPLOAD_FAILED` as the URL
2. In the E2E report, describe the visual state observed instead of linking a screenshot:
   ```
   | TC-HP-001 | Generate 1-week plan | PASS | Screenshot upload failed. Verified: plan shows 7 days, each with video thumbnails, title "Python Basics" |
   ```
3. Continue with the review — screenshot upload failure should NOT block the review itself

### CI Screenshots

The CI workflow automatically captures screenshots in E2E tests and uploads them as artifacts:
- `e2e-screenshots-pr-<N>` artifact (5-day retention)
- The PR comment from CI includes a download link for the full artifact
