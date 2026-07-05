# Test Cases — P3-5: GitLab config plumbing + docs + CI axis wiring (#420)

**Scope.** The documentation-and-plumbing half of parent #414 W-E:

- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` — GitLab config
  block.
- `docs/gitlab-setup.md` — operator-facing token/host guide.
- `tests/unit/test-provider-conformance-runner.sh` — TC-PCONF-070 wiring the
  `--itp gitlab --chp gitlab` axis to CI via the existing unit-test glob.
- `tests/provider-conformance/README.md` — how-to-run block.
- `docs/pipeline/provider-spec.md` §3.4 — RESERVED→CONSUMED prose flip.
- `docs/pipeline/dispatcher-flow.md` + `docs/pipeline/handoffs.md` —
  provider-neutral topology notes at the sites the pseudocode names
  `gh issue edit` / `gh pr list` / `gh pr checks` etc.

**Harness.** No new test binary. Every assertion below is either (a)
grep/awk/`bash -n` against a text artifact, (b) exercised by
`test-provider-conformance-runner.sh` under `env -u PROJECT_DIR bash …`, or
(c) exercised by the pre-existing `test-provider-spec-drift.sh` /
private-repo scan.

**No leaf, no provider file, no CI YAML edit, no control-flow change** —
the whole P3-5 slice is passive documentation of what P3-1..P3-4 already
consumes, plus the one runner-test row that gates the axis via CI's existing
unit-test glob.

---

## R1 — `autonomous.conf.example` GitLab block

The example file grows a `# === GitLab provider (ISSUE_PROVIDER=gitlab / CODE_HOST=gitlab) ===`
section, all keys commented-out (github stays the byte-identical default when
the new keys are unset).

| ID | Assertion | Verifier |
|----|-----------|----------|
| TC-P35-001 | Block header `# === GitLab provider` is present exactly once. | `grep -c '^# === GitLab provider' skills/autonomous-dispatcher/scripts/autonomous.conf.example` = `1`. |
| TC-P35-002 | `ISSUE_PROVIDER=""` line present, commented out. | `grep -qE '^# ISSUE_PROVIDER="".*supported values' skills/autonomous-dispatcher/scripts/autonomous.conf.example`. |
| TC-P35-003 | `CODE_HOST=""` line present, commented out. | `grep -qE '^# CODE_HOST=""' skills/autonomous-dispatcher/scripts/autonomous.conf.example`. |
| TC-P35-004 | `GITLAB_HOST=""` present with `gitlab.com` default cited + minimum-supported version cited. | `grep -qE '^# GITLAB_HOST=""' skills/autonomous-dispatcher/scripts/autonomous.conf.example` AND the block references `gitlab.com` AND `v17.x` (per the P3-1..P3-4 fixture pins). |
| TC-P35-005 | `GITLAB_TOKEN=""` present with scope guidance (`api`) + link to `docs/gitlab-setup.md`. | `grep -qE '^# GITLAB_TOKEN=""' skills/autonomous-dispatcher/scripts/autonomous.conf.example` AND the block references `docs/gitlab-setup.md`. |
| TC-P35-006 | `GITLAB_PROJECT=""` present with URL-encoded example (`group%2Fsubgroup%2Fproject`) + §3.4 anchor. | `grep -qE '^# GITLAB_PROJECT=""' skills/autonomous-dispatcher/scripts/autonomous.conf.example` AND the block references `group%2F`. |
| TC-P35-007 | `GITLAB_TRANSPORT_HOOK=""` present with ONE neutral sentence + `provider-spec.md` §transport pointer + trust-model line. | `grep -qE '^# GITLAB_TRANSPORT_HOOK=""' skills/autonomous-dispatcher/scripts/autonomous.conf.example` AND the block references `provider-spec.md`. |
| TC-P35-008 | The example file still parses under `bash -n`. | `bash -n skills/autonomous-dispatcher/scripts/autonomous.conf.example` rc 0. |
| TC-P35-009 | Sourcing the example under `env -u PROJECT_DIR bash -c 'source …'` leaves the shell clean (no unbound-var abort, no non-zero rc). | The `env -u PROJECT_DIR bash -c 'source skills/autonomous-dispatcher/scripts/autonomous.conf.example'` invocation rc 0. |
| TC-P35-010 | ISSUE_PROVIDER / CODE_HOST stay EMPTY defaults (github stays the byte-identical default). | After sourcing, `${ISSUE_PROVIDER:-}` and `${CODE_HOST:-}` are empty strings (not `github` — the empty default is what preserves byte-identity with pre-#420 conf files). |

---

## R2 — `docs/gitlab-setup.md`

Sections mirror `docs/github-app-setup.md`'s voice/shape. **Zero
enterprise-internal references** — the file lands in a public tree.

| ID | Assertion | Verifier |
|----|-----------|----------|
| TC-P35-020 | File exists at `docs/gitlab-setup.md`. | `test -f docs/gitlab-setup.md`. |
| TC-P35-021 | "Why GitLab tokens vs GitHub Apps" section present + cites the [INV-79] degraded posture + `provider-spec.md` §5.1. | `grep -q 'Why GitLab tokens' docs/gitlab-setup.md` AND the section references `INV-79` AND `§5.1`. |
| TC-P35-022 | "Creating a token" section covers PAT vs project vs group token + scope `api`. | `grep -qE 'PAT.*project.*group\|Creating a token' docs/gitlab-setup.md` AND the section references `api`. |
| TC-P35-023 | "Self-hosted host configuration" section names `GITLAB_HOST` → `/api/v4` + operator-owned CA/SSL disclaimer (redirects to transport hook). | `grep -q '/api/v4' docs/gitlab-setup.md` AND the section names the transport hook. |
| TC-P35-024 | "Configuring autonomous.conf" section names every R1 key by name. | For KEY in `GITLAB_HOST GITLAB_TOKEN GITLAB_PROJECT GITLAB_TRANSPORT_HOOK ISSUE_PROVIDER CODE_HOST`, `grep -q "$KEY" docs/gitlab-setup.md`. |
| TC-P35-025 | "Transport hook (custom-gateway deployments)" section points at `provider-spec.md` §transport + names the operator-owned local-file trust model. | `grep -q 'Transport hook' docs/gitlab-setup.md` AND the section references `provider-spec.md`. |
| TC-P35-026 | "Git-remote authentication is operator-owned" section is present + notes API hook does NOT cover the git channel. | `grep -q 'Git-remote authentication' docs/gitlab-setup.md`. |
| TC-P35-027 | **Public-repo hygiene** — file contains zero enterprise-internal terms. | The standard private-ref grep pattern (per project CLAUDE.md — SSO-gateway hostnames, forked-CLI usernames, corporate-auth CLI names) matched against `docs/gitlab-setup.md` = zero hits. |

---

## R3 — gitlab-axis conformance test wiring

**Post-#419 topology (revised at rebase).** The `--itp gitlab --chp gitlab`
axis is exercised end-to-end by **TC-RGH-060** in
`tests/unit/test-provider-conformance-runner.sh` — landed by #419 (P3-4)
as parent #414 AC1's landing gate. TC-RGH-060 arms the merged fixture
transport hook (`tests/provider-conformance/fixtures/gitlab-hook/gitlab-transport-hook.sh`,
which #419 extended to serve BOTH ITP and CHP endpoints under one file, so
no composite hook is needed) and asserts `CONFORMANCE-SUMMARY
total=34 pass=32 fail=0 skip=2 pending=0` — the two SKIPs are
`chp_request_changes` (`rest_request_changes=0`) and `chp_trigger_bot`
(`review_bots=0`).

Given #419 landed the coverage this PR was originally scoped for
(dependency-forward), P3-5 does not add a duplicate runner case. Instead,
the R3 surface here is the **operator-facing how-to** — the
`tests/provider-conformance/README.md` gets a "Full GitLab axis" invocation
line pointing at the same hook TC-RGH-060 arms, so an operator picking up
the suite can reproduce the axis outside CI.

| ID | Assertion | Verifier |
|----|-----------|----------|
| TC-P35-030 | The fixture transport hook exists and is bash-parseable. | `test -f tests/provider-conformance/fixtures/gitlab-hook/gitlab-transport-hook.sh` AND `bash -n <file>` rc 0. |
| TC-P35-031 | `TC-PCONF-070` (the #420 R3-named gate) asserts the gitlab/gitlab axis outcome — rc 0, `fail=0`, `pending=0` — on the same captured run TC-RGH-060 (#419) drives; the two are complementary (per-verb detail vs issue-named summary gate), one runner invocation. | `grep -q 'TC-PCONF-070' tests/unit/test-provider-conformance-runner.sh` AND the case asserts rc 0 + `fail=0`/`pending=0` on the gitlab/gitlab summary. |
| TC-P35-032 | `tests/provider-conformance/README.md` "How to run" block names the gitlab-axis invocation, arming the same hook TC-RGH-060 arms — reproducibility from an operator shell without editing tests. | `grep -qE 'run-provider-conformance\.sh --itp gitlab --chp gitlab' tests/provider-conformance/README.md` AND the block references `fixtures/gitlab-hook/gitlab-transport-hook.sh`. |
| TC-P35-033 | The runner test file's top-level `main` passes end-to-end under `env -u PROJECT_DIR bash tests/unit/test-provider-conformance-runner.sh`. | Final `Results: N passed, 0 failed`; exit 0. |

---

## R4 — provider-spec.md §3.4 CONSUMED framing

| ID | Assertion | Verifier |
|----|-----------|----------|
| TC-P35-040 | §3.4 no longer describes the GitLab keys as "RESERVED"; the framing flips to CONSUMED language, pointing at the R1 conf block as the operator surface. | `grep -A5 '### 3.4' docs/pipeline/provider-spec.md` contains "CONSUMED" or "consumed" AND references `autonomous.conf.example` OR `docs/gitlab-setup.md`. |
| TC-P35-041 | The §transport anchor is not accidentally renamed by this edit. | `grep -q '#351-gitlab-transport-contract' docs/pipeline/provider-spec.md` (or the equivalent stable anchor) still resolves. |
| TC-P35-042 | `tests/unit/test-provider-spec-drift.sh` (or its equivalent) stays green — no unmigrated verb tokens or dangling `CONTRACT-PENDING` markers introduced. | `env -u PROJECT_DIR bash tests/unit/test-provider-spec-drift.sh` rc 0. |

---

## R5 — pipeline-doc provider-neutral topology notes

Prose only. Every note is one sentence pointing at
`provider-spec.md` §3.4 or §3.2's provider-neutral verb, at the exact site
the pseudocode names `gh issue edit` / `gh pr list` / `gh pr checks` /
`gh api graphql` as the conceptual leaf.

| ID | Assertion | Verifier |
|----|-----------|----------|
| TC-P35-050 | `dispatcher-flow.md` at least once notes "provider-neutral verb; GitHub leaf shown for reference" (or equivalent phrasing) near a `gh issue edit` / `gh pr list` mention. | `grep -qE 'provider-neutral verb.*GitHub leaf shown\|see provider-spec' docs/pipeline/dispatcher-flow.md`. |
| TC-P35-051 | `handoffs.md` carries the same single-line note near an H1/H2/H4/H5 pseudocode section. | `grep -qE 'provider-neutral verb.*GitHub leaf shown\|see provider-spec' docs/pipeline/handoffs.md`. |
| TC-P35-052 | No invariant / state-machine block changed by this PR — only prose text was added. | `git diff origin/main -- docs/pipeline/invariants.md docs/pipeline/state-machine.md` shows zero changes on this branch. |

---

## R6-prep — #414 AC evidence sweep DRAFT

The operator posts the final comment on #414 after merge — this PR ships
the DRAFT text at `docs/test-cases/p3-5-ac-sweep-draft.md` with AC1..AC5
lines named and CI-link placeholders.

| ID | Assertion | Verifier |
|----|-----------|----------|
| TC-P35-060 | Draft file `docs/test-cases/p3-5-ac-sweep-draft.md` exists. | `test -f docs/test-cases/p3-5-ac-sweep-draft.md`. |
| TC-P35-061 | Draft names AC1..AC5 by number with the concrete surface (TC-PCONF-070 for AC1, github-parity for AC2, P3-1 fixture-transport for AC3, guard job + gh-app-token for AC4, caps evidence tables for AC5). | For MATCH in `AC1 AC2 AC3 AC4 AC5`, `grep -q "$MATCH" docs/test-cases/p3-5-ac-sweep-draft.md`. |
| TC-P35-062 | Draft contains no live private-repo permalinks or enterprise-internal references. | The standard private-ref grep pattern (per project CLAUDE.md) matched against `docs/test-cases/p3-5-ac-sweep-draft.md` = zero hits. |

---

## Non-goals (out of scope for this PR)

- Live GitLab smoke — post-merge operator gate (`operator-provisioned
  standard GitLab project — self-hosted equally valid` per #414's out-of-scope).
- `.github/workflows/ci.yml` edits — the unit-test glob covers the new axis.
- Asana config keys — reserved by §3.4 but out of scope per #420.
- The cutover-guard extension half of W-E — rode P3-1.
- The §transport contract text — frozen by P3-1; this PR points at it only.
