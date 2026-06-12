# Design Canvas — Adapter Spec v1 (issue #229)

> Status: autonomous design (no interactive approval gate). Docs-only PR — no
> wrapper / `lib-agent.sh` behavior change.

## Problem

Per-CLI handling is scattered across `case "$AGENT_CMD"` branches in
`lib-agent.sh` and special-cased in the `lib-review-*.sh` family. The contracts
that hold the pipeline together — what a review verdict comment must contain,
how a timed-out reviewer vetoes a merge, how a silently-quota-walled `agy`
becomes an `unavailable` drop — exist only as folklore plus `INV-NN` prose
scattered across `docs/pipeline/invariants.md`. A new CLI vendor (or the next
refactor) has nothing **normative** to build against.

This issue writes the keystone artifact the redesign's later phases (adapter
extraction, verdict-as-data, conformance suite) all implement: a versioned,
RFC-2119 spec + machine-checkable JSON Schemas.

## Deliverables

| Path | What |
|---|---|
| `docs/pipeline/adapter-spec.md` | The normative spec (`spec_version: 1`), MUST/MUST NOT clauses |
| `docs/pipeline/schemas/adapter-result.schema.json` | The four-axis `AdapterResult` |
| `docs/pipeline/schemas/verdict-artifact.schema.json` | The verdict artifact contract |
| `docs/pipeline/schemas/fixture-manifest.schema.json` | Conformance fixture manifest |
| `docs/pipeline/schemas/error-envelope.schema.json` | Operator-facing error envelope |
| `docs/pipeline/schemas/examples/*.json` | ≥2 golden + negative examples per schema |
| `docs/test-cases/adapter-spec.md` | TC-ADAPTER-SPEC-NNN |
| `tests/unit/test-adapter-spec-schemas.sh` | Schema validation suite |
| `docs/pipeline/invariants.md` (INV-66) | "adapter conformance is spec-defined" |

## Key design decisions

### 1. Mode axis is structural, not cosmetic

The interface is `invoke(mode, prompt, model, session, timeout, env) →
AdapterResult` where `mode ∈ { dev-new, dev-resume, review, e2e-browser }`. The
spec MUST NOT pretend one uniform `invoke` covers all modes — they differ
**structurally** in today's code:

- `codex` **dev** = `codex exec --json` + a thread-id sidecar that `dev-resume`
  reads (`codex exec resume <thread_id>`).
- `codex` **review** = `codex review "<prompt>"` from a PR-branch worktree, **no
  resume**, with a fail-closed `no-worktree` sentinel (rc 70) when prep fails
  (INV-62).
- `kiro` has no session at all — `dev-resume` collapses to a fresh
  conversation.

So the spec states **per-mode requirements** as separate MUST clauses.

### 2. Four-axis AdapterResult (flat enum is NON-conformant)

A flat failure enum loses information the pipeline already depends on. The
result is four orthogonal axes:

- `process` — `{ rc, signal, timedOut }`
- `provider` — `{ class ∈ none|quota|auth|config|transient, evidence, resetHint? }`
- `verdict` — `{ state ∈ valid|absent|malformed, payloadRef? }`
- `voteEligibility` — `{ state ∈ pass|fail|drop|timeout-veto|not-applicable }`

Two load-bearing worked examples, grounded in INV-40 / INV-48:

- rc `124`/`137` + no verdict ⇒ `voteEligibility = timeout-veto` (deciding FAIL).
- rc `0` + no verdict ⇒ `voteEligibility = drop` (`unavailable`).

### 3. Verdict artifact folds in INV-49 + E2E report as typed sub-objects

Rather than the parallel ad-hoc fences that exist today (the `Review Session:` /
`Review Agent:` comment trailer, the `ac-coverage:begin…end` HTML fence, the
free-form E2E evidence comment), the schema models one artifact with typed
`evidence.acCoverage` (INV-49 shape: `{ "<criterion>": "pass"|"fail" }`) and
`evidence.e2eReport` sub-objects. Atomic-write contract: tmp + rename; readers
ignore post-land writes.

### 4. Error envelope REQUIRES operator surfacing for config-class

`{ code, problem, cause, remediation, doc }`. The spec REQUIRES config-class
failures (`provider.class = config`, e.g. kiro `auth-failed`, codex
`no-worktree`) to surface on the GitHub issue or as a dispatcher alert — never
log-only. This matches the existing drop-reason surfacing (INV-58 / INV-61) and
makes it normative.

## Test strategy (docs-PR shape)

Tests are **schema validation**, not runtime behavior. The suite
(`test-adapter-spec-schemas.sh`) validates each schema's golden examples accept
and each documented violation rejects. It MUST run in plain CI: prefer
`python3 -m jsonschema` (Draft-07) when available, **fall back to `jq`
structural assertions** (required keys + enum membership) otherwise — `ci.yml`
runs on bare `ubuntu-latest` so the suite cannot hard-depend on the
`jsonschema` module being installed.

Negative cases mandated by the issue:
- flat failure enum (missing axes) → rejected by `adapter-result`.
- verdict artifact without `schema_version` → rejected.
- error envelope missing `remediation` → rejected.

## Out of scope

- Any behavior change in wrappers / `lib-agent.sh` (spec only).
- The standalone conformance runner (a follow-up issue consumes the manifest
  schema).
