# Test Cases: Two-Tier CI Lanes (issue #238)

ID format: `TC-CI-TIERS-NNN`

These are **workflow-lint + gate-logic assertions** over `.github/workflows/ci.yml` and
`setup-labels.sh`. The PR is workflow-shaped, so the unit test parses the YAML structurally
(Python + pyyaml; actionlint installed in CI does the deeper syntax lint) and asserts the
gate truth table rather than executing a live matrix.

## Gate truth table (the contract under test)

| ID | Trigger | hermetic jobs | live-smoke job |
|---|---|---|---|
| TC-CI-TIERS-001 | Fork PR, **no** label | scheduled | NOT scheduled |
| TC-CI-TIERS-002 | Fork PR, maintainer applies `run-live-smoke` | scheduled | scheduled (self-hosted) |
| TC-CI-TIERS-003 | Push to `main` | scheduled | scheduled (self-hosted) |
| TC-CI-TIERS-004 | Same-repo PR, **no** label | scheduled | NOT scheduled |

The `if:` condition encodes 001–004; the structure test asserts the condition text matches
the disjunction `(pull_request && label.name == 'run-live-smoke') || (push && ref == main)`.

## Structural assertions (test-ci-two-tier-lanes.sh)

| ID | Assertion |
|---|---|
| TC-CI-TIERS-010 | `ci.yml` parses as valid YAML. |
| TC-CI-TIERS-011 | At least one job name starts with `hermetic`; every such job has `runs-on: ubuntu-latest`. |
| TC-CI-TIERS-012 | No `hermetic-*` job references any credential token (`secrets.`, `AWS_ACCESS`, `AWS_SECRET`, `BEDROCK`, `ANTHROPIC_API_KEY`, `GH_APP_PRIVATE_KEY`). Hermetic tier is credential-free. |
| TC-CI-TIERS-013 | A `live-smoke` job exists. |
| TC-CI-TIERS-014 | `live-smoke.if` contains the label gate `github.event.label.name == 'run-live-smoke'`. |
| TC-CI-TIERS-015 | `live-smoke.if` contains the push-to-main gate (`github.event_name == 'push'` AND `refs/heads/main`). |
| TC-CI-TIERS-016 | The `on:` block does NOT contain `pull_request_target` (foot-gun: would run untrusted head with base secrets). |
| TC-CI-TIERS-017 | The `on.pull_request.types` list contains `labeled` (so the `labeled` event is delivered). |
| TC-CI-TIERS-018 | `live-smoke` runs `tests/e2e/run-agent-smoke.sh`. |
| TC-CI-TIERS-019 | `live-smoke` does NOT pin `runs-on: ubuntu-latest` (it targets the self-hosted pool). |
| TC-CI-TIERS-020 | `live-smoke` writes the SMOKE evidence to `$GITHUB_STEP_SUMMARY` (job summary upload). |
| TC-CI-TIERS-021 | `live-smoke` resolves the matrix config OUTSIDE the checkout — references the `RUNNER_SMOKE_CONF` override and a `$HOME`-based default (so `git clean -ffdx` from `actions/checkout` can't delete it). PR #256 [P1]. |
| TC-CI-TIERS-022 | `live-smoke` exports the resolved `SMOKE_CONF` path to `$GITHUB_ENV` so `run-agent-smoke.sh` reads the out-of-checkout matrix. |
| TC-CI-TIERS-023 | `live-smoke` preflights the matrix readability (`[[ ! -r "$SMOKE_CONF" ]]`) and fails loud with `::error::` + a provisioning pointer instead of the opaque harness `FATAL: matrix not found/readable`. |

## setup-labels assertions

| ID | Assertion |
|---|---|
| TC-CI-TIERS-030 | `setup-labels.sh` `LABELS` array defines an entry whose name is `run-live-smoke` with a color and a description. |

## E2E (documented in PR body, not a script)

| ID | Assertion |
|---|---|
| TC-CI-TIERS-040 | One labeled dry run on this repo: applying `run-live-smoke` to the PR triggers the `live-smoke` job on the self-hosted runner; the SMOKE summary artifact is present in the run. UNAVAILABLE (quota) entries do not fail the job. |

## Negative / security cases

| ID | Assertion |
|---|---|
| TC-CI-TIERS-050 | An unlabeled fork PR does NOT schedule `live-smoke` (covered by 014/015 — the `if` has no unconditional branch). |
| TC-CI-TIERS-051 | No `pull_request_target` anywhere (016). |
