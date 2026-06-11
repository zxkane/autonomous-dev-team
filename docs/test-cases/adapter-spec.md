# Test Cases — Adapter Spec v1 (issue #229)

Docs-PR shape: tests are **schema validation**, not runtime behavior. The suite
`tests/unit/test-adapter-spec-schemas.sh` validates the four JSON Schemas under
`docs/pipeline/schemas/` against their committed golden + negative examples
under `docs/pipeline/schemas/examples/`. It prefers `python3 -m jsonschema`
(Draft-07, full semantics) and falls back to `jq` structural assertions
(required keys + enum membership) so it runs in plain CI either way.

E2E: **N/A (spec-only)** — CI runs the schema validation suite, nothing else.

## Conventions

Example fixtures follow `<schema-prefix>.{golden|negative}.<label>.json`:
- `golden` → MUST validate against `<schema-prefix>.schema.json`.
- `negative` → MUST be rejected.

## Test Cases

| ID | Scenario | Expected |
|---|---|---|
| TC-ADAPTER-SPEC-001 | All four `*.schema.json` files present | present |
| TC-ADAPTER-SPEC-002 | `adapter-spec.md` declares `spec_version: 1` | present |
| TC-ADAPTER-SPEC-003 | `invariants.md` has `INV-63` | present |
| TC-ADAPTER-SPEC-004 | Every example is well-formed JSON | parses |
| TC-ADAPTER-SPEC-005 | Each schema has ≥2 golden examples | count ≥ 2 |
| TC-ADAPTER-SPEC-006 | Each schema is a valid Draft-07 schema (py backend) | meta-valid |
| TC-ADAPTER-SPEC-007 | Every `*.golden.*` example validates | accepted |
| TC-ADAPTER-SPEC-008 | Every `*.negative.*` example is rejected | rejected |

### Per-schema golden examples (each MUST validate)

| Schema | Golden examples |
|---|---|
| `adapter-result` | `golden.pass` (rc 0 + verdict valid → vote pass), `golden.timeout-veto` (rc 124 + verdict absent → timeout-veto), `golden.quota-drop` (rc 0 + quota + verdict absent → drop) |
| `verdict-artifact` | `golden.pass` (PASS + AC-coverage map + E2E report), `golden.fail` (FAIL + blocking finding) |
| `fixture-manifest` | `golden.codex-review` (codex review mode), `golden.agy-quota` (agy quota drop) |
| `error-envelope` | `golden.kiro-auth` (issue-comment surface), `golden.codex-no-worktree` (dispatcher-alert surface), `golden.transient-log-only` (the only log-only case — `class: transient`) |

### Per-schema negative examples (each MUST be rejected)

| Schema | Negative example | Documented violation |
|---|---|---|
| `adapter-result` | `negative.flat-enum` | **flat failure enum, missing the four axes** (issue-mandated) |
| `adapter-result` | `negative.bad-provider-class` | `provider.class` not in enum (and evidence missing) |
| `adapter-result` | `negative.provider-evidence-missing` | `provider.class != none` without `evidence` |
| `verdict-artifact` | `negative.no-schema-version` | **missing `schema_version`** (issue-mandated) |
| `verdict-artifact` | `negative.blocking-but-pass` | non-empty `blockingFindings` with `verdict: PASS` |
| `verdict-artifact` | `negative.bad-ac-value` | AC-coverage value not `pass`/`fail` |
| `fixture-manifest` | `negative.missing-expect` | missing `expect` block |
| `fixture-manifest` | `negative.bad-stdin-hash` | `stdinSha256` not a 64-hex string |
| `error-envelope` | `negative.no-remediation` | **missing `remediation`** (issue-mandated) |
| `error-envelope` | `negative.bad-code` | `code` not `UPPER_SNAKE` |
| `error-envelope` | `negative.config-log-only` | config-class envelope with `surface: log-only` — Clause E2 conditional (review finding) |

## Acceptance criteria coverage

- A reader can answer, from the spec alone, "what must my new CLI's adapter
  return when the provider 429s mid-run?" — see adapter-spec.md § Provider axis
  + the `golden.quota-drop` worked example. ✔ (verified by spec presence +
  golden validation)
- "what file does the wrapper read for my verdict and what schema must it
  satisfy?" — see adapter-spec.md § Verdict artifact + `verdict-artifact.schema.json`. ✔
- All four schemas ship with passing golden/negative validation in CI. ✔
  (TC-ADAPTER-SPEC-007/008)
- Existing pipeline docs cross-linked; no wrapper code changed. ✔ (INV-63 +
  autonomous-pipeline.md + pipeline/README.md links; diff is docs/tests only)
