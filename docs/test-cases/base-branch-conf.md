# Configurable base branch via `BASE_BRANCH` — test cases

Test-case IDs: `TC-BASEBR-NNN`. Issue #478 — promote the base branch every
dev/review wrapper prompt, hook decision, and provider argv targets from a
hardcoded `main` literal to a resolved, validated, exported `BASE_BRANCH` conf
value. See `invariants.md` `INV-131` and `dispatcher-flow.md`'s "Conf schema:
`BASE_BRANCH`" section.

## Scope

- `lib-config.sh::resolve_base_branch` — the resolution-chain + validation
  pure helper.
- `autonomous-dev.sh` / `autonomous-review.sh` startup: resolve-once,
  export-once, conditional startup log line.
- Prompt rendering: the dev wrapper's two rebase-instruction blocks, the
  review wrapper's merge-conflict-resolution block and the INV-44
  mergeable-gate finding/comment/notification texts.
- `chp_github_create_pr` / `chp_gitlab_create_pr` — the `--base`/target-branch
  argv addition.
- Hooks: `check-rebase-before-push.sh`, `verify-completion.sh`,
  `block-push-to-main.sh`.
- Non-interference: with `BASE_BRANCH` unset, every rendered prompt / hook
  decision / provider argv (net of the deliberate `--base main` addition) is
  byte-identical to pre-#478.

## Unit test cases

### TC-BASEBR-001 — `BASE_BRANCH` set → wins over `DEFAULT_BRANCH`
`BASE_BRANCH=develop DEFAULT_BRANCH=release` → `resolve_base_branch` echoes
`develop`, no stderr output (the deprecation warning is scoped to when
`DEFAULT_BRANCH` is actually consulted, i.e. `BASE_BRANCH` is unset).

### TC-BASEBR-002 — only `DEFAULT_BRANCH` set → used, with deprecation notice
`DEFAULT_BRANCH=release` (BASE_BRANCH unset) → echoes `release`; stderr
contains `WARNING: DEFAULT_BRANCH is deprecated`.

### TC-BASEBR-003 — neither set → `"main"`, no stderr
Both unset → echoes `main`; stderr is empty (byte-identical-default
guarantee — no log noise on the universal default deployment shape).

### TC-BASEBR-004 — validation: value with a space → warning + fallback to `main`
`BASE_BRANCH="feat branch"` → echoes `main`; stderr contains a `WARNING`
naming the invalid value and the `main` fallback.

### TC-BASEBR-005 — validation: value with a quote → warning + fallback
`BASE_BRANCH='dev"branch'` → echoes `main`; stderr WARNING present.

### TC-BASEBR-006 — validation: value with a leading `-` → warning + fallback
`BASE_BRANCH="-x"` → echoes `main`; stderr WARNING present. `resolve_base_branch`
applies an explicit `[[ "$raw" != -* ]]` guard alongside the
`^[A-Za-z0-9._/-]+$` charset check — `-` is a legal MID-branch-name character
(e.g. `feat-x`), but a LEADING `-` is rejected defensively because it risks
being parsed as a flag by a downstream `git`/`gh` invocation.

### TC-BASEBR-007 — validation: a normal value with `/` (e.g. `release/v2`) is valid
`BASE_BRANCH="release/v2"` → echoes `release/v2` verbatim, no warning — `/`
is in the allowed charset (branch names commonly use it).

### TC-BASEBR-008 — an invalid `DEFAULT_BRANCH` value ALSO gets the deprecation notice
`DEFAULT_BRANCH="bad branch"` (BASE_BRANCH unset) → echoes `main`; stderr
contains BOTH the deprecation warning AND the invalid-value warning — the
operator needs both signals.

### TC-BASEBR-009 — dev wrapper prompt rendering, `BASE_BRANCH` unset → byte-identical to the pre-#478 golden fixture
Render the dev wrapper's two rebase-instruction blocks (the resume-prompt
block and the resume-fallback-prompt block) with `BASE_BRANCH=main` (the
resolved default) and diff against the pre-#478 fixture text — zero
differences.

### TC-BASEBR-010 — dev wrapper prompt rendering, `BASE_BRANCH=develop` → `git rebase origin/develop`, zero `origin/main`
Same two blocks rendered with `BASE_BRANCH=develop`: both contain
`git fetch origin develop` / `git rebase origin/develop` and the prose
`rebase onto develop`; `grep -c origin/main` on the rendered blocks is 0.

### TC-BASEBR-011 — review wrapper merge-conflict-resolution block, `BASE_BRANCH=develop` → zero `origin/main`
The `## Step 0: Merge Conflict Resolution` block renders
`git fetch origin develop`, `git rebase origin/develop`, and the
`[BLOCKING] Merge conflict with develop` prose; zero `origin/main`
occurrences.

### TC-BASEBR-012 — review wrapper INV-44 mergeable-gate texts, `BASE_BRANCH=develop`
The `block-substantive` finding comment, the `Auto-merge failed:` PR marker,
and the `submit_request_changes` body all reference `develop` (not `main`)
in both the prose and the `git fetch`/`git rebase` command lines.

### TC-BASEBR-013 — `needs_open_pr_only` reads `BASE_BRANCH` (with a `:-main` direct-invocation fallback)
With `BASE_BRANCH=develop` exported, `needs_open_pr_only`'s ahead-check
resolves `origin/develop` (not `origin/main`) as the comparison base.
Unexported (direct extraction / legacy invocation) falls back to `main`.

### TC-BASEBR-014 — `chp_github_create_pr` argv includes `--base develop` under override
`BASE_BRANCH=develop` → the emitted `gh pr create` argv ends with
`--base develop`.

### TC-BASEBR-015 — `chp_github_create_pr` argv includes `--base main` by default
`BASE_BRANCH` unset → the emitted argv is byte-identical to the pre-#478 argv
PLUS an appended `--base main` pair, and nothing else changes (same
`--repo`/`--head`/`--title`/`--body` ordering and values).

### TC-BASEBR-016 — `chp_gitlab_create_pr` skips the project probe when `BASE_BRANCH` is set
`BASE_BRANCH=develop` → exactly ONE `_gl_api` call (the POST create) — the
`GET /projects/:id` default-branch probe is skipped — and the POST body
carries `"target_branch":"develop"`.

### TC-BASEBR-017 — `chp_gitlab_create_pr` probes the project default branch when `BASE_BRANCH` is unset (regression pin)
`BASE_BRANCH` unset → TWO `_gl_api` calls (probe then POST), POST body
carries `"target_branch":"main"` (or whatever the project's fixture
`default_branch` is) — unchanged pre-#478 behavior.

### TC-BASEBR-018 — `check-rebase-before-push.sh` computes behind-count against `origin/develop` when `BASE_BRANCH=develop`
Temp-repo fixture (mirrors `test-block-push-regex.sh`'s `setup_repo`
pattern): create `develop` as the fixture's trunk with N commits ahead on
`origin/develop`, checkout a feature branch behind it, run the hook with
`BASE_BRANCH=develop bash check-rebase-before-push.sh <<<'{"tool_input":
{"command":"git push"}}'` → exit 2, message names `develop`/`origin/develop`.

### TC-BASEBR-019 — `check-rebase-before-push.sh` unchanged when `BASE_BRANCH` unset (regression pin)
Same fixture shape, trunk named `main`, `BASE_BRANCH` unset → identical
exit code and message shape to the pre-#478 hook (still names `main`).

### TC-BASEBR-020 — `check-rebase-before-push.sh` skips its own base-branch check when already on the resolved base branch
`current_branch == "$BASE_BRANCH"` (e.g. checked out on `develop` with
`BASE_BRANCH=develop`) → hook exits 0 immediately (mirrors the `main`
self-skip, generalized).

### TC-BASEBR-021 — `verify-completion.sh` skips verification on the resolved base branch
`BASE_BRANCH=develop`, current branch `develop` → hook exits 0 (no jq/gh
calls attempted). Current branch `master` (legacy fallback, independent of
`BASE_BRANCH`) also exits 0.

### TC-BASEBR-022 — `block-push-to-main.sh` blocks a push to the resolved `BASE_BRANCH`, not just `main`
`BASE_BRANCH=develop`, push destination `refs/heads/develop` → exit 2
(blocked). A push to `refs/heads/main` under the SAME `BASE_BRANCH=develop`
env is ALLOWED (rc 0) — the trunk being protected is the resolved value, not
a hardcoded `main`.

### TC-BASEBR-023 — `block-push-to-main.sh` precedence: `BASE_BRANCH` wins over `TRUNK_BRANCH`
Both `BASE_BRANCH=develop` and `TRUNK_BRANCH=master` set → the protected
trunk is `develop` (BASE_BRANCH takes precedence in the chain
`${BASE_BRANCH:-${TRUNK_BRANCH:-main}}`).

### TC-BASEBR-024 — `block-push-to-main.sh` unchanged when only `TRUNK_BRANCH` is set (regression pin)
`TRUNK_BRANCH=master`, `BASE_BRANCH` unset → identical behavior to the
pre-#478 hook (protects `master`) — TC-BP-10 in `test-block-push-regex.sh`
stays green unmodified.

### TC-BASEBR-025 — wiring pins: both wrappers resolve+export `BASE_BRANCH` immediately after the required-config validation loop
Source-of-truth grep: `BASE_BRANCH="$(resolve_base_branch)"` and
`export BASE_BRANCH` both appear in `autonomous-dev.sh` and
`autonomous-review.sh`, positioned after the `for _req in PROJECT_ID REPO
REPO_OWNER REPO_NAME PROJECT_DIR` loop and before the first prompt-builder
call site.

### TC-BASEBR-026 — wiring pins: no hardcoded `origin/main` / `onto main` remains in either wrapper's prompt/command text
`grep -nE "origin/main|onto main" autonomous-dev.sh autonomous-review.sh`
returns only comment/history lines (e.g. code-comment mentions of the
dispatcher's own `main`-checkout convention), never a live prompt or
command-line interpolation site.

### TC-BASEBR-027 — `bash -n` passes on every modified script
Both wrappers, `lib-config.sh`, both provider leaves, and all three hooks
pass `bash -n` after the `BASE_BRANCH` changes.

## E2E test cases

Not required beyond the existing wrapper E2E lane, which runs against `main`
and must pass unmodified — that IS the byte-identical-default regression
surface (see Acceptance Criteria in issue #478). Live verification against a
real non-main repository is tracked as post-merge operational work (Out of
Scope in issue #478).
