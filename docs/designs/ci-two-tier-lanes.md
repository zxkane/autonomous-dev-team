# Design Canvas: Two-Tier CI Lanes (issue #238)

## Problem

`ci.yml` today is a single `unit-tests` job on `ubuntu-latest` that already runs the
hermetic suites (unit tests + agent-smoke stub self-test + metrics + error-envelope +
adapter conformance) plus a separate `shellcheck` job. The live agent-smoke matrix
(`tests/e2e/run-agent-smoke.sh` with real CLIs, #222) is **not** wired into CI at all,
because it needs authenticated CLIs (claude/codex/kiro/agy via IAM/quota) that only the
self-hosted box has.

If the live matrix landed as an unconditional job:

1. Every fork PR goes permanently red (auth-less GitHub-hosted runners) → trains
   contributors to ignore CI.
2. Public-repo security forbids exposing the self-hosted runner to untrusted PR code
   unconditionally (self-hosted + untrusted code = host compromise). This is the binding
   constraint from the operator's global CI guidance.

## Goal

Restructure CI into two explicit tiers:

- **Tier 1 — hermetic** (unit + shellcheck + conformance + the stub self-tests): runs on
  every PR/push on `ubuntu-latest` with **zero credentials**. Required for merge.
- **Tier 2 — live** (#222 agent-smoke matrix with real CLIs): runs **only** on the
  self-hosted runner and **only** when a maintainer applies the `run-live-smoke` label
  (`pull_request` `labeled` event) **OR** on push to `main`. Advisory (non-required).
  The matrix config is resolved from **outside** the checkout, self-provisioning via
  the `SMOKE_MATRIX` repo variable (content → temp file) so it works on the
  ephemeral autoscaling pool, with `RUNNER_SMOKE_CONF` (path) and a per-box default
  as fallbacks — see [INV-77](../pipeline/invariants.md#inv-77-ci-is-two-tiers--hermetic-always-on--credential-free-live-agent-smoke-is-self-hosted-label-gated-and-advisory) sub-point 4.

## Gate truth table (the spec the structure test asserts)

| Trigger | hermetic | live-smoke |
|---|---|---|
| Fork PR, **no** label | ✅ scheduled (green, no creds) | ❌ not scheduled |
| Fork PR, maintainer applies `run-live-smoke` | ✅ | ✅ (self-hosted) |
| Same-repo PR, no label | ✅ | ❌ |
| Push to `main` | ✅ | ✅ (self-hosted) |

Key security property: a **fork** PR cannot trigger live-smoke on its own. The label is
applied by a maintainer with write access — applying it IS the authorization act. The
`labeled` event fires in the context of the **base** repo, but the workflow still checks
out the PR head, so the threat-model note (self-hosted + untrusted head code) must be
documented inline. We do **not** use `pull_request_target` (it would run with base-repo
secrets/token against untrusted head code — the classic foot-gun); we use plain
`pull_request` with the `labeled` type.

## Design decisions

### 1. Job structure in `ci.yml`

Rename the existing single job set to make the tier explicit:

- `hermetic-unit` (was `unit-tests`) — `ubuntu-latest`, the existing 6 steps unchanged.
- `hermetic-shellcheck` (was `shellcheck`) — `ubuntu-latest`, unchanged + lint the new
  workflow-structure test if one is added as a script.
- `live-smoke` — **new**. `if:` gate (see below), `runs-on` the self-hosted pool label
  via the operator's `RUNNER_LABEL` ternary pattern, runs `run-agent-smoke.sh`, uploads
  the SMOKE evidence lines as a job summary.

The `hermetic` name prefix is the contract the truth-table test keys on (any job whose
name starts with `hermetic` MUST be `ubuntu-latest` and carry no credential refs).

### 2. The `live-smoke` `if:` condition

```yaml
if: >-
  (github.event_name == 'pull_request' && github.event.label.name == 'run-live-smoke')
  || (github.event_name == 'push' && github.ref == 'refs/heads/main')
```

- On `pull_request` the workflow must declare `types: [..., labeled]` so the `labeled`
  event delivers `github.event.label.name`. We keep the default types and add `labeled`.
- `github.event.label.name` is only populated on a `labeled` event, so the PR branch of
  the `if` naturally only fires when a label was just applied — exactly "maintainer
  applies the label".

### 3. `runs-on` for live-smoke

Follow the operator's self-hosted-pool convention (lazy `&&`/`||` ternary so an unset
`RUNNER_LABEL` var falls back without an eager `fromJSON` crash):

```yaml
runs-on: ${{ vars.RUNNER_LABEL && fromJSON(vars.RUNNER_LABEL) || 'self-hosted' }}
```

Default to bare `'self-hosted'` (not `ubuntu-latest`) when the var is unset, because the
job's entire purpose is the self-hosted box; a GitHub-hosted fallback would have no CLIs.

### 4. rc contract / job summary

`run-agent-smoke.sh` exits 1 on any FAIL; UNAVAILABLE/SKIP are non-blocking (#222). The
job runs it directly (no `|| true`) so a real FAIL fails the live-smoke job — but because
live-smoke is advisory (non-required), a quota-walled agy yielding UNAVAILABLE does not
fail the job (rc 0), and even a FAIL never blocks merge of a fork PR's hermetic checks.

The SMOKE evidence lines go to **stdout**; we tee them into `$GITHUB_STEP_SUMMARY` as a
fenced block so the matrix result is visible in the run summary without digging into logs.

### 5. Label bootstrap

Add `run-live-smoke|color|description` to `setup-labels.sh`'s `LABELS` array so the gate
label exists on day one. Color: a CI-ish blue/teal distinct from the existing set.

### 6. Tests (TDD)

A new `tests/unit/test-ci-two-tier-lanes.sh` parses `.github/workflows/ci.yml` with
Python+pyyaml (actionlint is not installed locally; CI installs it for the deeper lint —
but the structural truth-table assertions are done with pyyaml so they run anywhere) and
asserts:

- `hermetic-*` jobs run on `ubuntu-latest` and have **no** credential references
  (no `secrets.`, no `AWS_`, no `BEDROCK`, no `ANTHROPIC_API_KEY`, etc.).
- `live-smoke` job's `if:` matches the truth table (label gate OR push-to-main) and
  references neither `pull_request_target` (the `on:` block must not contain it) nor an
  unconditional schedule.
- The `pull_request` trigger declares the `labeled` type.
- `live-smoke` invokes `tests/e2e/run-agent-smoke.sh`.
- `setup-labels.sh` defines `run-live-smoke`.

Plus a CI step that runs `actionlint` over the workflows (installed in CI) for the
`pull_request_target` foot-gun / syntax lint — belt and suspenders.

### 7. Docs

- `CONTRIBUTING.md`: a "What CI runs on your PR" section explaining the two tiers and
  that maintainers may apply `run-live-smoke` for the live tier.
- `tests/conformance/README.md`: cross-link to the CONTRIBUTING tiers section (the
  conformance suite IS the hermetic tier anchor).
- `docs/pipeline/invariants.md`: new **INV-77** — two-tier CI contract (hermetic always-on
  + credential-free; live-smoke label-gated + self-hosted + advisory). pipeline-docs-gate
  requires a `docs/pipeline/` touch because `setup-labels.sh` is a watched script.
- Branch-protection note in the PR body: mark the two `hermetic-*` jobs required;
  `live-smoke` stays non-required.

## Out of scope (per issue)

- Changing the #222 harness itself.
- Multi-arch runner matrix; scheduled nightly smoke.
