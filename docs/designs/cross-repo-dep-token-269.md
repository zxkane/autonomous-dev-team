# Design: cross-repo dependency lookup uses a per-dep-repo scoped App token (#269)

## Problem

`check_deps_resolved` in `lib-dispatch.sh` silently blocks dispatch for any
issue whose `## Dependencies` section references a cross-repo `owner/repo#N`,
because the GitHub App token in scope when the lookup runs is scoped to the
**dispatching** repo only.

The token comes from `dispatcher-tick.sh`'s app-mode block:

```bash
_dispatcher_token=$(get_gh_app_token "$REPO_OWNER" "$REPO_NAME")   # no permissions arg
export GH_TOKEN="$_dispatcher_token"
```

`_build_access_token_body` therefore produces `{"repositories":["repo-A"]}` —
a token GitHub will not honor for `repo-B`. The cross-repo arm of
`check_deps_resolved` runs `gh issue view N --repo owner/repo-B --json state`,
GitHub returns 404 / `Could not resolve to a Repository`, `$state` is empty,
and the fail-safe `return 1` ([INV-39]) silently skips the issue every tick.

The bug is **the token used for the cross-repo lookup**, not the parsing
([INV-39] `owner/repo#N` extraction is correct).

## Decision (LOCKED — Option A: per-dep-repo scoped read token)

Mint a **per-distinct-dep-repo** installation token scoped to that target repo
with read-only permissions, cached by `owner/repo` within the tick. Chosen over
an installation-wide token because it has the smaller blast radius and can
target the dependency repo's own installation.

**Hard requirement (documented):** the App MUST be installed on each dependency
repo (and, if the App uses "selected repositories", that repo must be selected).
No token shape avoids this — if the App can't see `repo-B`, the dependency is
genuinely unresolvable and the fail-safe block is correct.

## Implementation

### T1 — structural extraction in `gh-app-token.sh` (commit 1)

Extract `_app_install_token(app_id, pem, owner, repo, body)`:
JWT gen → `GET /repos/owner/repo/installation` → `POST .../access_tokens -d body`.
`get_gh_app_token` becomes a thin wrapper that builds the body via
`_build_access_token_body` and calls `_app_install_token`.
`get_gh_app_scoped_token` is unchanged (it already delegates to
`get_gh_app_token`). **Behavior byte-identical** — `test-token-split-234.sh`
(TC-TOKEN-SPLIT-001/002/003) and `test-dispatcher-tick-app-auth.sh` stay green
before any behavioral change (Beck: never structural + behavioral in one commit).
The per-repo mint reuses the existing `get_gh_app_scoped_token` — no new mint
code.

### T2 — `resolve_dep_state(owner_repo, num)` in `lib-dispatch.sh` (commit 2)

- On first sight of an `owner/repo` in app mode, mint via
  `get_gh_app_scoped_token "$DISPATCHER_APP_ID" "$DISPATCHER_APP_PEM" \
  "${owner_repo%/*}" "${owner_repo#*/}" "$DEP_LOOKUP_PERMISSIONS"` and cache it in
  a `declare -A _DEP_TOKEN_CACHE` keyed by `owner/repo` (dedupes N deps in the
  same repo to one mint). `DEP_LOOKUP_PERMISSIONS` defaults to
  `{"issues":"read"}` (see T8 — `metadata` is implicit and 422s if requested).
- Run the lookup as
  `state=$(GH_TOKEN="${_DEP_TOKEN_CACHE[$owner_repo]:-$GH_TOKEN}" \
  gh issue view "$num" --repo "$owner_repo" --json state -q .state 2>/dev/null || true)`.
- The `${...:-$GH_TOKEN}` fallback keeps PAT mode at today's behavior — the PAT
  already spans repos; no mint happens.
- The same-repo `#N` arm is **unchanged** (ambient `GH_TOKEN`).
- A per-repo mint failure (App not installed, transport error) is cached as the
  ambient token (or empty under the fallback) so the lookup degrades to the
  fail-safe block; it never `exit`s. A failed mint is cached negatively so we do
  not re-mint a doomed token for every ref in that repo.
- **Cache scope = the tick, not one issue (#269 review [P1] correction).** AC #2
  requires caching by `owner/repo` *within the tick*. `_DEP_TOKEN_CACHE` is
  module-scope and the tick is one process that sources `lib-dispatch.sh` once,
  so the cache persists across every `check_deps_resolved` call in the tick —
  two issues depending on the same external repo reuse ONE mint.
  `check_deps_resolved` therefore does **not** self-reset; clearing happens only
  at the tick boundary (T4). An early draft reset per-call (per-issue), which
  defeated the cross-issue dedup — corrected here.
- **`resolve_dep_state` uses an out-var, not stdout.** The mint mutates the
  module-scope cache, and that write must happen in the caller's shell so the
  cache survives across refs (and across issues). A `state=$(resolve_dep_state)`
  capture would subshell the body and lose the cache write — so the resolved
  state is returned via `printf -v "$out_var"`.

### T3 — sharpened WARNING (`lib-dispatch.sh`)

When a cross-repo lookup returns empty state, the WARNING names the
scope/installation cause first:
`cross-repo lookup failed for <repo>#<num> (issue <N>) — the App may not be
installed on <repo> (or the issue is private/deleted); blocking.`
Single fail-safe `return 1` retained.

### T4 — thread the App creds (`dispatcher-tick.sh`)

`DISPATCHER_APP_ID` / `DISPATCHER_APP_PEM` are already exported in the app-mode
block. `resolve_dep_state` reads them directly (they are env, not args). The
mint is gated on `GH_AUTH_MODE=app` AND both creds being present; otherwise the
ambient-token fallback applies (PAT mode and any partial-config safety). A
per-ref mint failure degrades to the fail-safe block — **never `exit 1`** (so
same-repo issues still dispatch). In PAT mode the cache is never populated, so
no stale dep-lookup token is honored.

`dispatcher-tick.sh` also owns the **tick boundary** for the cache: it calls
`_reset_dep_token_cache` once (right after the tick-local `JUST_DISPATCHED=()`
init, before Step 2) so each tick starts clean while the within-tick cross-issue
dedup is preserved. The call is `declare -F`-guarded so a future lib refactor
that drops the helper can't abort the tick. The multi-project tick
(`dispatcher-multi-tick.sh`) runs each project in its own subshell, so a fresh
subshell already isolates per-project; the boundary reset covers the
reused-shell case.

### T5 — block visibility (once-per-issue comment)

When the cross-repo dependency stays unresolvable, surface it as a
**once-per-issue-per-ref** comment (dedup guard: scan existing comments for a
hidden marker `<!-- dep-block:<repo>#<num> -->`) posted via the dispatcher
token, so a persistent block is not invisible behind a stderr WARN. The comment
is best-effort (`|| true`) and never changes the fail-safe rc.

### T6 — CI wiring without a workflow edit

The hermetic E2E driver `tests/e2e/run-cross-repo-dep-e2e.sh` is pulled into CI
by a thin unit-suite wrapper `tests/unit/test-cross-repo-dep-e2e-wrapper.sh` that
execs it and asserts the `CROSS-REPO-DEP-E2E-SUMMARY`. CI's `Run all unit tests`
step already iterates `tests/unit/test-*.sh`, so this needs **no
`.github/workflows/` change** — important because the autonomous dev wrapper's
scoped GitHub App token lacks the `workflows` permission ([INV-79]) and a PR
branch pushed with it is rejected if it edits `ci.yml`.

### T7 — docs (same PR, pipeline-doc authority)

New **INV-83** in `docs/pipeline/invariants.md` (cross-repo dep lookup uses a
per-dep-repo scoped read token; App must be installed on the dep repo). Update
`observation-snapshot.md` + `dispatcher-flow.md` cross-refs for [INV-39]. App
installation migration note.

### T8 — pre-merge API verification

One real mint against `api.github.com` confirming the permissions object
returns 200 + a token that reads issue state. `metadata` is implicit for GitHub
Apps and is rejected (422) when requested, so the default is `{"issues":"read"}`.
Result cited in a code comment.

## Why not the alternatives

- **Installation-wide token (no `repositories` array):** larger blast radius;
  also can't target the dep repo's own installation when the App has separate
  installations. Rejected per the locked decision.
- **Fix at the agent-token site (`lib-auth.sh`):** wrong call site —
  `check_deps_resolved` runs in `dispatcher-tick.sh`, not in the dev/review
  wrapper.

## State machine impact

None. This is a token-scoping fix inside Step 2's dependency gate. No new label
transitions, no change to the transitions.json spec ([INV-80]).
