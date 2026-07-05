# Design — P3-5: GitLab config plumbing + docs + CI gitlab-axis wiring (#420)

Phase-3 slice 5 under tracking issue #414 (W-E config half). Docs-and-plumbing
only: no provider leaf, no wrapper control-flow change.

## Problem

P3-1..P3-4 (#416/#417/#418/#419) landed the full GitLab provider pair and the
conformance gitlab axis, but an operator onboarding a GitLab project still has
no conf template (`autonomous.conf.example` documents only GitHub keys) and no
setup guide (nothing analogous to `docs/github-app-setup.md`). The gitlab axis
also needed an issue-named CI gate, and parent #414's AC1..AC5 needed a single
evidence sweep posted.

## Design

Four additive surfaces, one issue-closing act:

1. **`autonomous.conf.example` GitLab block** — `ISSUE_PROVIDER`/`CODE_HOST`
   (default github when unset — byte-identical default), `GITLAB_HOST`
   (gitlab.com default; self-hosted CE/EE first-class), `GITLAB_TOKEN`
   (PAT / project / group token — all `PRIVATE-TOKEN` header, scope `api`),
   `GITLAB_PROJECT` (URL-encoded path per spec §3.4), `GITLAB_TRANSPORT_HOOK`
   (one neutral sentence pointing at the provider-spec §transport contract;
   operator-owned local file trust model). All commented-out; the example must
   keep sourcing cleanly.
2. **`docs/gitlab-setup.md`** — the operator guide: token-vs-GitHub-App posture
   (degraded [INV-79] two-token → convention), token creation + scopes,
   self-hosted host config, conf keys, transport-hook pointer (contract lives
   in provider-spec §transport — this doc never restates it), and the
   git-remote-auth-is-operator-owned boundary (SSH/credential helper — the API
   hook does not cover the git channel).
3. **CI gitlab-axis gate** — `TC-PCONF-070` in
   `tests/unit/test-provider-conformance-runner.sh`: the #420-named summary
   gate (rc 0, `fail=0`, `pending=0`) on the same captured gitlab/gitlab run
   TC-RGH-060 (#419) drives — complementary (per-verb detail vs issue-named
   summary), one runner invocation, shipped to CI via the existing unit-test
   glob (no workflow YAML edit). `tests/provider-conformance/README.md` gains
   the operator how-to invocation.
4. **Spec + pipeline-doc touches** — §3.4 RESERVED→CONSUMED framing flip;
   provider-neutral topology notes in `dispatcher-flow.md`/`handoffs.md` where
   gh commands are named as the conceptual leaf (prose only, no invariant or
   state-machine change).
5. **#414 AC evidence sweep (R6/AC6)** — the `## Phase-3 AC evidence sweep`
   comment on #414 citing AC1..AC5 surfaces + evidence; posted at review time
   (every load-bearing artifact was already on main via PR #422..#425), URL
   recorded in `docs/test-cases/p3-5-ac-sweep-draft.md` and the PR body.

## Alternatives considered

- **Editing `.github/workflows/ci.yml`** for the gitlab axis — rejected: the
  unit-test glob already ships any `tests/unit/test-*.sh` case; a workflow edit
  enlarges the blast radius for zero gain (#420 Out of Scope pins this).
- **Restating the transport-hook contract in gitlab-setup.md** — rejected: the
  contract is normative in provider-spec §transport; duplicating it creates a
  drift pair (Pipeline Documentation Authority).
- **Waiting for post-merge to post the AC sweep** — superseded at review round
  1: all evidence artifacts were already merged, so the sweep is verifiable
  pre-merge; posted with the green main-CI link at merge-of-#419.

## Test strategy

`docs/test-cases/p3-5-config-docs.md` (TC-P35-NNN): conf-example key greps +
source check under `env -u PROJECT_DIR`, gitlab-setup.md section-structure
greps, TC-PCONF-070 tally assertion, README axis line, spec §3.4 framing +
spec-drift green, pipeline-doc note greps, enterprise-term leak scan (zero
hits).
