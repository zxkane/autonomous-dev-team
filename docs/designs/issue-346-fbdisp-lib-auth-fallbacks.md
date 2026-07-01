# Design: fail-loud disposition for lib-auth leaf-absent raw-`gh` fallbacks (#346)

## Problem

Two auth-side brokers in `lib-auth.sh` still carry the pre-#303/B1 "silent raw-`gh`
capability fallback" shape — when the CHP leaf is absent they fall through to a
**hardcoded GitHub** call regardless of the configured backend:

1. `drain_agent_pr_create` (`:507-511`): `chp_has_leaf create_pr` → `chp_create_pr`,
   **else** → raw `gh pr create --repo "$repo" …`. The else-branch is unconditioned
   on backend, so a future `CODE_HOST=gitlab` provider without a `create_pr` leaf
   would silently open a **GitHub** PR.
2. `drain_agent_bot_triggers` (`:618-622`): same shape for `trigger_bot` → raw
   `bash "$gh_as_user" pr comment …`.

This is the exact failure INV-91 forbids and that #296 B1 (#303) deleted from
`setup-labels.sh` / `mark-issue-checkbox.sh`, and that #327 pinned no-silent-fallback
for `chp_reply_review_comment` (TC-RRC-021). Neither drain site is in #296's Deferred
section, so they would survive as landmines for the first non-GitHub provider.

A third site — `autonomous-review.sh:~3512` `gh issue close` interim close — is
**already** github-gated (`elif [[ "${ISSUE_PROVIDER:-github}" == "github" ]]`, #282
round 7) AND pinned by `test-chp-pr-lifecycle.sh` TC-CHP-CAP-MCI0-NONGH. It needs no
code change; its disposition is documentation-only.

## Decision

Keep the raw call **only** under an explicit `CODE_HOST == github` guard; on a
non-GitHub backend with the leaf absent, fail LOUD (operator-visible error, no
`gh`/`gh-as-user` executed). This is the #303/B1 + #327 no-silent-fallback pattern
applied conservatively: it does **not** migrate the fallback into a new verb, it
only conditions the existing fallback on backend identity.

### Control flow (R1 — `drain_agent_pr_create`)

```
if chp_has_leaf create_pr:            _pr_create_ok() { chp_create_pr … }        # provider-neutral
elif CODE_HOST == github:             _pr_create_ok() { gh pr create --repo … }  # SAME baselined line, verbatim
else:                                 loud ERROR (no PR create); return 0        # non-github + leaf-absent
```

### Control flow (R2 — `drain_agent_bot_triggers`)

Same shape around the per-line post. Because the branch decision is
backend-identity (not per-line), the `CODE_HOST != github` fail-loud gate is
checked **once**, before the per-line posting loop begins — on a non-GitHub backend
with no `trigger_bot` leaf, the broker emits one loud error and posts nothing.

### Guard defaulting (`set -euo pipefail` safety)

The wrappers run `set -euo pipefail`. `CODE_HOST` is set by `lib-code-host.sh`
(`CODE_HOST="${CODE_HOST:-github}"`), which `lib-auth.sh` self-sources — but only
when `chp_create_pr` is undefined AND the lib is readable. So the guard MUST use
`${CODE_HOST:-github}` (the #327 precedent): an unset `CODE_HOST` defaults to
`github`, i.e. today's exact behavior — the raw path is retained. Zero behavior
change on the github/github topology.

## Why the raw line stays byte-identical (R5 / INV-91 baseline)

The cutover baseline (`providers/cutover-baseline.json`) is keyed by
`(file, whitespace-trimmed line content)` COUNT, not line number. The raw
`gh pr create` fallback is baselined as
`_pr_create_ok() { gh pr create --repo "$repo" --head "$branch" --title "$title" --body "$body" >/dev/null 2>&1; }`
(count 1). By keeping that line **verbatim** and only wrapping it in a surrounding
`elif … else …`, its trimmed content — hence its baseline signature — is unchanged.
No baseline regeneration is required; the retained github-gated raw call stays
baselined as **spec-sanctioned residue** (it now has an explicit `CODE_HOST == github`
guard). The `drain_agent_bot_triggers` fallback is `bash "$gh_as_user" pr comment …`,
which carries no raw `gh ` token (the `gh-as-user.sh` transport wrapper is
allowlisted), so it is not in the baseline and R2 does not touch it either.

## Non-goals

- No new CHP verb (out of scope).
- No change to R3's code (already github-gated + pinned).
- No change to the agent-prompt heredoc prose or auth/identity residue.
- No GitLab/Asana provider implementation.
