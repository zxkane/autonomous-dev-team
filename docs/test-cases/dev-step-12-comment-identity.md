# Test Cases: Dev Step 12 — Comment Identity in App Mode

Issue: #142 — `fix(autonomous-dev): step-12 summary comment posts as host gh user instead of bot in app mode`

## Background

The autonomous-dev wrapper sets up a `${_LIB_AUTH_DIR}` PATH-prepend symlink so
that any `gh` invocation routes through `gh-with-token-refresh.sh`. The wrapper
itself hits the symlink (so its trailer comments are correctly attributed to
the App-installed bot identity in `GH_AUTH_MODE=app`).

The agent process inherits the same PATH but its embedded Bash tool does not
reliably honor it for `gh` resolution — bare `gh issue comment …` resolves to
`/usr/bin/gh`, which uses the host operator's `gh auth login` session and
posts the Step-12 summary under the host user's identity, not the bot.

The fix is documentation-only: agent-facing skill docs and the autonomous-mode
reference must instruct the agent to use the explicit project-vendored wrapper
path (`bash scripts/gh issue comment …`) for status/summary comments. A
doc-lint guard prevents regression.

## Scope

- Behavioral assertions about runtime identity attribution (TC-COMMENT-001 …
  TC-COMMENT-003) describe the **expected outcome** when an agent follows the
  updated docs. They are **manual verification** — no bash unit test stubs
  the GitHub API end-to-end.
- The doc-lint guard (TC-COMMENT-004) is a **unit test** living in
  `tests/unit/test-dev-skill-bash-scripts-gh.sh`.

## Test Cases

### TC-COMMENT-001 — Step 12 summary in app mode → bot identity

**Mode**: `GH_AUTH_MODE=app`, `AGENT_CMD=claude` (or any agent CLI)

**Setup**: throwaway issue in a test repo with the autonomous label and the
required `## Dependencies` / `## Testing Requirements` sections so the
dispatcher will pick it up.

**Steps**:
1. Run `bash scripts/autonomous-dev.sh --issue <N> --mode new` against the
   throwaway issue.
2. Let the wrapper run end-to-end through Step 12 (the agent's
   "session complete" summary post).
3. Inspect the issue comments with
   `gh api repos/<owner>/<repo>/issues/<N>/comments --jq '.[] | {user: .user.login, body: .body[:80]}'`.

**Expected**:
- The wrapper-emitted "Agent Session Report (Dev)" trailer comment is
  attributed to the App's bot identity (e.g., `<bot-name>[bot]`).
- The agent-emitted Step-12 summary comment is **also** attributed to the
  App's bot identity (NOT the host operator's `gh auth login` user).
- Both comments share the same `user.login` value.

**Verification**: manual. Recorded in the PR description that fixes #142
(see "Manual app-mode verification" line in the Acceptance Criteria).

---

### TC-COMMENT-002 — Step 12 summary in token mode → host user identity

**Mode**: `GH_AUTH_MODE=token`, agent CLI of choice.

**Setup**: same throwaway issue, but operator has switched the project's
`autonomous.conf` to `GH_AUTH_MODE=token` and `gh auth status` shows the host
user logged in.

**Steps**:
1. Run `bash scripts/autonomous-dev.sh --issue <N> --mode new`.
2. Let it run through Step 12.
3. Inspect issue comments as in TC-COMMENT-001.

**Expected**:
- The wrapper trailer is attributed to the host operator's `gh auth login`
  user (or the `GH_TOKEN` owner).
- The agent's Step-12 summary is **also** attributed to the same host user.
- This is **intentional** — token mode deliberately uses the host's session.

**Regression guard**: confirms the fix did not over-correct and accidentally
force bot identity in token mode.

---

### TC-COMMENT-003 — Review-bot trigger remains user-attributed in app mode

**Mode**: `GH_AUTH_MODE=app`, `REVIEW_BOTS="q"` (or `codex` / `claude`).

**Setup**: same as TC-COMMENT-001, but the project's autonomous.conf declares
at least one built-in review bot.

**Steps**:
1. Run the dev wrapper through PR creation and Step 10 (Address Reviewer Bot
   Findings).
2. The agent will issue a review trigger comment. Inspect the comment's
   `user.login` on the PR.

**Expected**:
- The `/q review` (or equivalent) comment is attributed to the **host user**
  (via `bash scripts/gh-as-user.sh pr comment …`), NOT the App bot.
- This is **intentional** — Q / Codex / Claude bots reject triggers from
  GitHub App accounts, so user attribution is required for the trigger to
  fire.

**Regression guard**: confirms the new documentation rule
("status/summary → `bash scripts/gh`, review-bot triggers →
`bash scripts/gh-as-user.sh`") did not collapse both paths into one.

---

### TC-COMMENT-004 — Doc-lint: no bare `gh issue comment` in agent-facing docs

**Type**: bash unit test in `tests/unit/test-dev-skill-bash-scripts-gh.sh`.

**Scope of files checked**:
- `skills/autonomous-dev/SKILL.md`
- All files under `skills/autonomous-dev/references/*.md`

**Rule**: every `gh issue comment` token in these files must be preceded by
`scripts/` on the same line (i.e., must read as `bash scripts/gh issue comment`
or `scripts/gh issue comment`). Bare `gh issue comment` (no `scripts/` prefix
on the same line) fails the test.

**Why bare-`gh-issue-comment` and not bare-`gh-pr-comment` too**: review-bot
triggers (`gh pr comment` paired with `/q review` / `/codex review` /
`@claude review`) intentionally route through `gh-as-user.sh`, not the
default wrapper. The autonomous-mode reference and review-commands reference
explicitly call out `bash scripts/gh-as-user.sh pr comment …` for those
flows, and the docs must continue to allow that pattern. A future scope
expansion could add a similar guard for `gh pr comment` once the docs are
audited for false positives, but it is **out of scope** for #142.

**Pass condition**: `grep -nE '(^|[^/])gh issue comment'` returns no matches
across the scoped files (i.e., zero hits where `gh issue comment` is preceded
by anything other than a `/`, which is how `scripts/gh` would appear).

**Fail condition**: any hit indicates a regression where future edits
re-introduced a bare-`gh issue comment` example in agent-facing docs.

---

### TC-AUTH-SYM-001/002 — `scripts/gh` symlink exists in both auth modes (INV-32)

**Type**: bash unit test in `tests/unit/test-lib-auth-gh-symlink.sh`.

**Context**: in addition to the doc edits, this PR makes a small enabling
change to `lib-auth.sh::setup_github_auth` — lifting the `gh` symlink
creation out of the app-mode branch. Without that change, the
doc-prescribed `bash scripts/gh issue comment …` would fail with
"No such file or directory" in token mode, because the symlink was only
created inside the app-mode branch. The wrapper script
(`gh-with-token-refresh.sh`) is itself mode-agnostic — it consults
`GH_TOKEN_FILE` only when set (app mode) and otherwise exec's the real
`gh` inheriting the host's auth env (which is the intended identity in
token mode). See [INV-32](../pipeline/invariants.md) for the invariant.

**TC-AUTH-SYM-001** — runtime: drives `setup_github_auth` in a sandboxed
copy of `lib-auth.sh` with `GH_AUTH_MODE=token` and asserts that
`${_LIB_AUTH_DIR}/gh` symlink exists and points at
`gh-with-token-refresh.sh`.

**TC-AUTH-SYM-002** — source-level regression guard: parses `lib-auth.sh`,
locates the `if [[ "$GH_AUTH_MODE" == "app" ]]` branch and the
symlink-creation line, asserts the latter is OUTSIDE the former. Catches
any future contributor "tidying up" the function by moving the symlink
back inside the app branch.

---

## Acceptance Criteria Mapping

| Issue acceptance criterion | Covered by |
|---|---|
| All `gh issue comment` invocations in agent-facing skill docs use `bash scripts/gh issue comment …` | TC-COMMENT-004 (automated) |
| `autonomous-mode.md` documents the rule distinguishing `bash scripts/gh` (status/summary) from `bash scripts/gh-as-user.sh` (review-bot triggers) | Manual review of the PR diff; reinforced by TC-COMMENT-003 (regression guard) |
| Doc-lint test fails on any future bare-`gh issue comment` regression | TC-COMMENT-004 (automated) |
| Test-cases doc exists with the four scenarios | THIS DOC |
| Manual app-mode verification on a throwaway issue: wrapper trailer = bot, agent summary = bot | TC-COMMENT-001 (manual, recorded in PR description) |
| (Implicit, surfaced during implementation) — `bash scripts/gh` works in token mode too, not just app mode | TC-AUTH-SYM-001/002 (automated) + INV-32 |
