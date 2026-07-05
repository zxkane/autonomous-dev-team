# GitLab Setup Guide

Operator-facing guide for onboarding a project whose issue tracker AND/OR
code host is GitLab (`ISSUE_PROVIDER=gitlab` / `CODE_HOST=gitlab`). The two
seams are independent — a project MAY use GitLab for issues and GitHub for
code, or vice versa, or both.

The autonomous pipeline reaches GitLab through the frozen P3-1 transport
contract (`skills/autonomous-dispatcher/scripts/providers/lib-gitlab-transport.sh`).
Every leaf verb (`itp_gitlab_*` and `chp_gitlab_*`) routes HTTP through the
lib's `_gl_api` public function — one choke-point, one pagination walker,
one 429/`Retry-After` backoff loop, one fail-CLOSED discipline.

## Why GitLab tokens vs GitHub Apps

GitLab has **no GitHub-App equivalent**. The pipeline's three GitHub bot
identities (dev, review, dispatcher — see `docs/github-app-setup.md`) map
onto GitLab as follows:

| Property | GitHub App mode | GitLab token mode |
|----------|-----------------|-------------------|
| Separate bot identities | Three separate Apps, three bot accounts | One token = one identity (the token's owner or the project/group) |
| Token expiration | 1-hour installation tokens (auto-refreshed) | Long-lived PAT / project access token / group access token (operator-managed rotation) |
| Fine-grained permissions | Per-permission granularity | Scope-based (`api` covers the seam's needs) |
| Scoped agent-token containment ([INV-79]) | **Enforced** — the wrapper mints a separate `pull_requests: read` token for the agent subprocess, so `gh pr review --approve` / `gh pr merge` fail 403 from the agent | **Degraded to convention** — no lower-privilege token to mint; the same PAT is used everywhere. The wrapper's approve/merge gates ([INV-44] / [INV-52]) and the `_AGENT_GITLAB_TOKEN_PAT_WARNED` latch (`skills/autonomous-dispatcher/scripts/lib-auth.sh`) are the sole containment (see `docs/pipeline/provider-spec.md` §5.1). |
| Audit trail | Each bot clearly identified in the timeline | Actions attributed to the token's owner |

If your organization needs distinct bot identities for dev/review/dispatcher
on a GitLab lane, provision three separate GitLab users (or three project
access tokens on the project) and put each token in the appropriate config
key on a per-role split.

## Creating a token

GitLab supports three interchangeable token classes for this pipeline. All
three use the `PRIVATE-TOKEN` HTTP header the P3-1 transport sends and all
three consume the same `api` scope. Pick the class that matches your
deployment shape:

| Class | Where you create it | When to use |
|-------|---------------------|-------------|
| **Personal access token (PAT)** | User Settings → Access tokens | A single-operator project where the pipeline runs under one human's identity. Simplest — matches the `GH_AUTH_MODE=token` shape on the GitHub side. |
| **Project access token** | Project Settings → Access tokens | The pipeline is owned by a project, not a person. The token dies with the project; rotation is a project-admin action. Recommended default for organizational projects. |
| **Group access token** | Group Settings → Access tokens | The pipeline works across sibling projects in one group (e.g. cross-project dependencies via `## Dependencies` refs). |

### Required scope

`api` — that single scope covers every verb the pipeline calls
(issue read/write, MR read/write, notes, discussions, approvals, labels,
files/branches for `chp_gitlab_commit_file`). No narrower scope suffices
for the write leaves.

### Optional stricter scopes

For a **read-only** deployment (dispatcher-side liveness checks, evidence
gathering) `read_api` is sufficient. The dev/review wrappers require `api`.

## Self-hosted host configuration

`GITLAB_HOST` defaults to `gitlab.com`. Any self-hosted CE/EE instance
whose API speaks standard PAT auth against `/api/v4` is a first-class
target — set `GITLAB_HOST` to the bare host (no scheme, no path). The P3-1
transport constructs every request URL as
`https://${GITLAB_HOST}/api/v4/<path>`.

**Custom CA / mTLS / self-signed certificates.** The pipeline treats the
network channel as operator-owned; it does not expose an in-tree
`GITLAB_CA_BUNDLE` knob. If your `curl` needs a custom certificate bundle,
custom CA, mTLS client certificate, cookie jar, or proxy configuration,
set that up via the operator-owned **transport hook** (see below) which
redefines `_gl_http` with whatever curl args your deployment needs. The
transport hook is the seam's one extension point (#414 pillar 3); it lands
your customization behind the same fail-loud preflight
([INV-116]) as the default transport.

## Configuring autonomous.conf

Uncomment and populate the GitLab block near the bottom of
`scripts/autonomous.conf` (the example ships with everything commented out
so a github-only conf is byte-identical to pre-#420):

```bash
# === GitLab provider (ISSUE_PROVIDER=gitlab / CODE_HOST=gitlab) ===

ISSUE_PROVIDER="gitlab"      # or leave unset if only CODE_HOST is gitlab
CODE_HOST="gitlab"           # or leave unset if only ISSUE_PROVIDER is gitlab

GITLAB_HOST="gitlab.com"                     # or your self-hosted host
GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"    # PAT / project / group token
GITLAB_PROJECT="group%2Fsubgroup%2Fproject"  # URL-encoded path

# Optional; leave unset for the default curl transport.
# GITLAB_TRANSPORT_HOOK="/path/to/operator-owned/hook.sh"
```

The keys — matching the block in
`skills/autonomous-dispatcher/scripts/autonomous.conf.example`:

| Key | Meaning | Notes |
|-----|---------|-------|
| `ISSUE_PROVIDER` | Which ITP seam to route to. | `github` (default) / `gitlab` / `asana` (reserved). |
| `CODE_HOST` | Which CHP seam to route to. | `github` (default) / `gitlab`. |
| `GITLAB_HOST` | API host (no scheme). | Defaults to `gitlab.com`. |
| `GITLAB_TOKEN` | The PAT / project / group access token. | Scope: `api`. Sent as `PRIVATE-TOKEN` on every request. |
| `GITLAB_PROJECT` | The project's URL-encoded `namespace/name` (or `group/subgroup/name`). | Stored **already** URL-encoded (spec §3.4). Used **verbatim** by the leaves — never re-encoded. Example: `group%2Fsubgroup%2Fproject`. Dynamic path segments (label names, file paths) go through `_gl_urlencode` separately. |
| `GITLAB_TRANSPORT_HOOK` | Optional path to a custom transport hook. | See next section. |

Store `GITLAB_TOKEN` outside version control. The standard shape
(matching the github side) is a `.env.gitlab` file in the project root,
gitignored, sourced by `autonomous.conf`:

```bash
# scripts/autonomous.conf
if [[ -r .env.gitlab ]]; then
  # shellcheck disable=SC1091
  source .env.gitlab
fi
```

## Transport hook (custom-gateway deployments)

The `_gl_http` primitive (P3-1 W-A, `providers/lib-gitlab-transport.sh`)
is the ONE public override point for the GitLab seam. Point
`GITLAB_TRANSPORT_HOOK` at an operator-owned shell file that redefines
`_gl_http` per the frozen contract in `docs/pipeline/provider-spec.md`
§transport ([§3.5.1](pipeline/provider-spec.md#351-gitlab-transport-contract-transport--the-two-layer-choke-point)),
and every leaf inherits your customization — proxies, mTLS, custom auth
headers, whatever your deployment needs. `_gl_api` (the pagination walker,
`429`/`Retry-After` backoff, fail-CLOSED discipline) stays lib-owned so a
variant transport cannot silently regress those guarantees.

**Trust model.** The hook is **operator-owned local code**, sourced by
the transport lib at library-init BEFORE any leaf runs. It has the same
privileges as `autonomous.conf` itself — explicitly NOT a sandbox
(#414 pillar 3). Don't point `GITLAB_TRANSPORT_HOOK` at a file you don't
own; the transport lib reads it once per process and executes whatever it
finds.

**Preflight.** The lib fail-loudly rejects a misconfigured hook
([INV-116]): a set `GITLAB_TRANSPORT_HOOK` pointing at an unreadable path,
or a hook that doesn't redefine `_gl_http`, or a hook whose `_gl_http`
body is byte-identical to the default (a no-op hook masquerading as a
custom transport) all fail loud at the first `_gl_api` call.

## Git-remote authentication is operator-owned

The transport hook covers the **API** channel (issues, merge requests,
approvals, discussions, file API — everything the ITP/CHP leaves call).
It does **NOT** cover the **git** channel — the `git push` / `git fetch`
the dev agent runs against the code host's git remote. That channel is
outside the seam by design (#414 pillar 3's second extension point).

Wire up git-remote auth via the standard, operator-owned mechanisms:

- **SSH remotes** — add the pipeline user's SSH key to the GitLab
  user/project/group that owns the token above, and let git resolve
  `git@${GITLAB_HOST}:group/subgroup/project.git` through your SSH config.
- **HTTPS remotes** — configure a git **credential helper**
  (`git config --global credential.helper …`) that returns the
  `GITLAB_TOKEN` for `${GITLAB_HOST}`. The pipeline never writes to your
  `.git-credentials` file itself.

The dev agent's `git push` uses the remote you configured; the pipeline
does not intercept it, wrap it, or override it.

## Verifying the setup

1. Populate the GitLab keys in `scripts/autonomous.conf` as above.
2. Confirm the conf still sources cleanly:
   ```bash
   env -u PROJECT_DIR bash -c 'source scripts/autonomous.conf && \
     printf "provider=%s host=%s project=%s\n" \
       "$ISSUE_PROVIDER" "$GITLAB_HOST" "$GITLAB_PROJECT"'
   ```
3. Run the conformance suite against the gitlab axis end-to-end (hermetic,
   no live network I/O — the fixture transport hook serves canned
   payloads):
   ```bash
   env -u PROJECT_DIR bash tests/provider-conformance/run-provider-conformance.sh \
     --itp gitlab --chp gitlab \
     --transport-hook tests/provider-conformance/fixtures/gitlab-hook/gitlab-transport-hook.sh
   ```
   Expect `CONFORMANCE-SUMMARY total=34 pass=32 fail=0 skip=2 pending=0`
   on a fully-landed P3-1..P3-4 tree. The two SKIPs are
   `chp_request_changes` (`rest_request_changes=0` — GitLab has no REST
   verb for requesting changes) and `chp_trigger_bot` (`review_bots=0`
   — the gitlab lane's initial review-bot posture).
4. Live GitLab smoke — operator-provisioned standard GitLab project, one
   `autonomous` issue, one dev/review cycle — is the post-merge gate per
   parent #414 AC5.

## See also

- `docs/pipeline/provider-spec.md` §3.4 (config namespace),
  §3.5.1 (transport contract), §5.1 (GitLab per-backend feasibility).
- `docs/pipeline/invariants.md` [INV-79] (agent-token containment),
  [INV-116] (GitLab transport preflight).
- `docs/github-app-setup.md` — the GitHub-side counterpart of this guide;
  read alongside for the shared vocabulary (wrapper vs agent, two-token
  posture, verdict actor detection).
