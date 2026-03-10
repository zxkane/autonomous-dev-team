# GitHub App Setup Guide

## Why GitHub Apps Instead of Personal Access Tokens?

The autonomous pipeline uses up to three separate bot identities (dev agent, review agent, dispatcher). GitHub Apps provide:

| Benefit | PAT | GitHub App |
|---------|-----|------------|
| Separate bot identities | No — all actions show as the PAT owner | Yes — each App has its own bot account |
| Fine-grained permissions | Repo-level only | Per-permission granularity |
| Token expiration | Long-lived (risky) | 1-hour tokens (auto-refreshed) |
| Rate limits | Shared with user | Separate per App |
| Audit trail | All actions attributed to one user | Each bot clearly identified |

With GitHub Apps, PR comments from the dev agent show as `my-dev-bot[bot]`, review approvals show as `my-review-bot[bot]`, and dispatcher actions show as `my-dispatcher-bot[bot]`. This makes the pipeline's actions transparent and auditable.

## Creating GitHub Apps

You need to create **three** GitHub Apps — one for each pipeline role. This ensures clean separation of concerns and audit trails.

### App 1: Dev Agent

1. Go to **Settings > Developer settings > GitHub Apps > New GitHub App**
2. Fill in:
   - **GitHub App name**: `<project>-dev-agent` (e.g., `myproject-coding-agent`)
   - **Homepage URL**: Your repository URL
   - **Webhook**: Uncheck "Active" (not needed)
3. Set permissions:

   | Permission | Access | Purpose |
   |------------|--------|---------|
   | **Issues** | Read & Write | Read issue body, post comments, update labels |
   | **Pull requests** | Read & Write | Create PRs, post comments, update descriptions |
   | **Contents** | Read & Write | Push code to feature branches |

4. Under "Where can this GitHub App be installed?", select **Only on this account**
5. Click **Create GitHub App**
6. Note the **App ID** displayed on the settings page

### App 2: Review Agent

1. Create another GitHub App: `<project>-review-agent` (e.g., `myproject-test-agent`)
2. Set the same permissions as the dev agent, plus:

   | Permission | Access | Purpose |
   |------------|--------|---------|
   | **Issues** | Read & Write | Read issue body, post review verdict, update labels |
   | **Pull requests** | Read & Write | Submit PR reviews (APPROVE/REQUEST_CHANGES) |
   | **Contents** | Read & Write | Push rebased branches, upload screenshots |

3. Click **Create GitHub App** and note the **App ID**

### App 3: Dispatcher

1. Create a third GitHub App: `<project>-dispatcher` (e.g., `myproject-dispatcher`)
2. Set permissions:

   | Permission | Access | Purpose |
   |------------|--------|---------|
   | **Issues** | Read & Write | List issues, update labels, post dispatch comments |
   | **Pull requests** | Read | Read PR status for review dispatching |

3. Click **Create GitHub App** and note the **App ID**

## Installing Apps on Your Repository

For each of the three Apps:

1. Go to the App's settings page
2. Click **Install App** in the left sidebar
3. Select your account/organization
4. Choose **Only select repositories** and select your target repository
5. Click **Install**

## Downloading Private Key PEM Files

For each App:

1. Go to the App's settings page
2. Scroll to **Private keys**
3. Click **Generate a private key**
4. A `.pem` file will be downloaded automatically
5. Store it securely on the machine running the pipeline

Recommended storage location:
```
/path/to/project/
  .github-apps/          # gitignored directory
    dev-agent.pem
    review-agent.pem
    dispatcher.pem
```

Add `.github-apps/` to `.gitignore`:
```bash
echo ".github-apps/" >> .gitignore
```

## Configuring autonomous.conf

Edit `scripts/autonomous.conf` with the App IDs and PEM paths:

```bash
# === GitHub Authentication ===
GH_AUTH_MODE="app"

# Dev Agent
DEV_AGENT_APP_ID="123456"
DEV_AGENT_APP_PEM="/path/to/project/.github-apps/dev-agent.pem"

# Review Agent
REVIEW_AGENT_APP_ID="789012"
REVIEW_AGENT_APP_PEM="/path/to/project/.github-apps/review-agent.pem"

# Dispatcher
DISPATCHER_APP_ID="345678"
DISPATCHER_APP_PEM="/path/to/project/.github-apps/dispatcher.pem"
```

## Token Refresh Daemon

GitHub App installation tokens expire after 1 hour. The pipeline includes a background token refresh daemon that automatically generates new tokens before expiration.

### How It Works

1. When `GH_AUTH_MODE=app`, `lib-auth.sh` starts `gh-token-refresh-daemon.sh` in the background
2. The daemon writes the current token to a file: `/tmp/cc-${PROJECT_ID}-gh-token-<pid>.txt`
3. The `gh-with-token-refresh.sh` wrapper reads the latest token from this file before each `gh` command
4. The daemon refreshes the token every 45 minutes (before the 60-minute expiry)
5. On cleanup (script exit), the daemon is killed and the token file is removed

### Token Flow

```
┌──────────────┐     writes token     ┌─────────────────┐
│ Token Refresh │ ──────────────────► │  Token File      │
│ Daemon        │  (every 45 min)     │  /tmp/cc-*.txt   │
└──────────────┘                      └────────┬────────┘
                                               │ reads
                                      ┌────────▼────────┐
                                      │  gh wrapper      │
                                      │  (gh-with-       │
                                      │   token-refresh) │
                                      └────────┬────────┘
                                               │ calls
                                      ┌────────▼────────┐
                                      │  GitHub API      │
                                      └─────────────────┘
```

### Manual Token Generation

For debugging or one-off operations:

```bash
source scripts/gh-app-token.sh
GH_TOKEN=$(get_gh_app_token "$APP_ID" "$APP_PEM" "$REPO_OWNER" "$REPO_NAME")
export GH_TOKEN
gh issue list --repo owner/repo
```

## Troubleshooting

### "FATAL: Failed to generate GitHub App token"

**Cause**: The JWT generation or installation token exchange failed.

**Check**:
1. Verify the PEM file exists and is readable:
   ```bash
   ls -la /path/to/.github-apps/dev-agent.pem
   ```
2. Verify the App ID is correct (check GitHub App settings page)
3. Verify the App is installed on the target repository
4. Ensure `openssl` is available (used for JWT signing):
   ```bash
   which openssl
   ```

### "Token daemon failed to write initial token"

**Cause**: The background daemon started but couldn't generate the first token.

**Check**:
1. Check if `/tmp/` is writable
2. Check daemon logs for errors
3. Verify network connectivity to GitHub API
4. Try manual token generation (see above)

### "gh: command requires authentication"

**Cause**: The `gh` wrapper is not reading the token file correctly.

**Check**:
1. Verify `GH_TOKEN_FILE` is set: `echo $GH_TOKEN_FILE`
2. Verify the token file exists and is non-empty: `cat $GH_TOKEN_FILE`
3. Verify the `gh-with-token-refresh.sh` symlink is set up correctly:
   ```bash
   ls -la scripts/gh  # should point to gh-with-token-refresh.sh
   ```

### Actions show as wrong user

**Cause**: Using the wrong App token or falling back to a personal token.

**Check**:
1. Verify `GH_AUTH_MODE=app` in `autonomous.conf`
2. Verify the correct App ID/PEM pair is used for each role
3. Check that `GH_TOKEN` is not set to a PAT (which would override the App token)

### App installation token has wrong permissions

**Cause**: The App permissions were changed after installation.

**Fix**: Go to your App's installation settings and verify permissions match those listed above. If you changed App permissions, you may need to re-accept the new permissions on the installation page.

## Using Token Mode (Simpler Alternative)

If you don't need separate bot identities, you can use a single Personal Access Token:

```bash
# In autonomous.conf
GH_AUTH_MODE="token"

# Then set GH_TOKEN before running the pipeline
export GH_TOKEN="ghp_xxxxxxxxxxxx"
```

Required PAT scopes: `repo` (full repository access).

This is simpler to set up but all pipeline actions will appear as your personal account.
