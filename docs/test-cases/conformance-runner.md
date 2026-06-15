# Test Cases — Standalone Conformance Runner (issue #230)

ID format: `TC-CONFORMANCE-NNN`. Implemented by
`tests/unit/test-conformance-runner.sh` (unit, hermetic) and the runner itself
against the promoted fixture set (`tests/conformance/run-conformance.sh`, the
E2E artifact / CI job).

## Pure-helper unit tests (`lib-conformance.sh`)

| ID | Scenario | Expected |
|---|---|---|
| TC-CONFORMANCE-001 | `_conf_field` extracts a top-level manifest field (`adapter`, `mode`). | echoes the value; missing field → empty, rc 0 |
| TC-CONFORMANCE-002 | `_conf_expect_field` extracts an `expect.*` axis (`providerClass`, `vote`, `retryable`). | echoes the value verbatim |
| TC-CONFORMANCE-003 | `_conf_axis_diff` of two identical four-axis tuples. | empty diff (PASS) |
| TC-CONFORMANCE-004 | `_conf_axis_diff` where one axis differs. | `vote: expected=pass actual=drop` style diff naming ONLY the differing axis |
| TC-CONFORMANCE-005 | `_conf_axis_diff` where multiple axes differ. | one clause per differing axis, all present |
| TC-CONFORMANCE-006 | `_conf_project` maps a `quota-exhausted` scraper token → `quota/absent/drop/false`. | exact four-axis tuple |
| TC-CONFORMANCE-007 | `_conf_project` maps `stream-error` → `transient/absent/drop/true` (retryable true). | exact tuple incl. `retryable=true` |
| TC-CONFORMANCE-008 | `_conf_project` maps `config-error:-s` → `config/absent/drop/false`. | exact tuple |
| TC-CONFORMANCE-009 | `_conf_project` of a PASS (nonce-ok) review state → `none/valid/pass/false`. | exact tuple |
| TC-CONFORMANCE-010 | `_conf_project` of a review no-verdict + rc 124 (timedOut) → `none/absent/timeout-veto/false`. | exact tuple |
| TC-CONFORMANCE-011 | `_conf_project` of a review no-verdict + rc 0 (not timed out) → `none/absent/drop/false`. | exact tuple |
| TC-CONFORMANCE-012 | `_conf_project` of a dev-new mode → `vote=not-applicable` regardless of other axes. | `not-applicable` |

## Runner integration tests (hermetic, stub-CLI)

| ID | Scenario | Expected |
|---|---|---|
| TC-CONFORMANCE-020 | Runner happy path: a valid agy-quota fixture asserts `quota/absent/drop/false`. | `CONFORMANCE agy/review/agy-quota-exhausted PASS`, runner rc 0 |
| TC-CONFORMANCE-021 | `--adapter codex` filters to only codex fixtures. | only `codex/*` lines printed; non-codex skipped |
| TC-CONFORMANCE-022 | `--mode review` filters to only review-mode fixtures. | only `*/review/*` lines |
| TC-CONFORMANCE-023 | Expect-mismatch (a fixture whose `expect.vote` is deliberately wrong) → FAIL with axis diff. | `CONFORMANCE … FAIL vote: expected=… actual=…`, runner rc≠0 |
| TC-CONFORMANCE-024 | Malformed manifest (missing required `expect`) rejected loudly. | `CONFORMANCE … FAIL schema-invalid …`, runner rc≠0; NEVER silently skipped |
| TC-CONFORMANCE-025 | Bad `stdinSha256` (not 64-hex) → schema reject (loud). Plus (025e..k) the **jq fallback** (jsonschema shadowed) rejects a manifest missing a schema-required NESTED field/type exactly as python jsonschema would: missing `input.promptBytes`/`input.model`, non-string `input.env` value, negative `promptBytes`, unknown nested key, non-string argv element, bad `files.<k>.role`; (025l/m) the fallback still ACCEPTS the full valid set. Pins the fail-closed nested-strictness (PR #244 [P1] #1). | FAIL schema-invalid for every malformed variant; valid set still PASS |
| TC-CONFORMANCE-026 | Hermeticity: a fixture whose stub binary cannot be materialized fails loud, never reaches a real CLI. | `FAIL stub-missing`/`stub-error`, runner rc≠0 |
| TC-CONFORMANCE-027 | INV-34 stdin channel: the stub records the bytes it reads on stdin; the runner drives the real dispatch path and asserts `sha256(stdin)` == `command.stdinSha256` (the digest is **load-bearing** — the prompt is fed with a deterministic nonce so the hash is reproducible; codex review carries the prompt as an argv positional → empty-string hash). | stub fed nothing for a stdin-fed adapter → `FAIL stdin-not-fed`; wrong bytes → `FAIL stdin-sha-mismatch`; loud, never silently skipped |
| TC-CONFORMANCE-028 | No real CLI on PATH during classification (PATH is the stub sandbox only). | assert `command -v claude` resolves to the stub dir, not a system binary |
| TC-CONFORMANCE-029 | Empty fixture dir / no matching filter → loud (nothing to assert is a misconfig, not a pass). | runner rc≠0 with a clear message |
| TC-CONFORMANCE-035 | ENV hermeticity (PR #244 [P1], codex reviews `dc696d40` + `fff5f671`): an inherited operator env does NOT contaminate the run — `AGENT_*_EXTRA_ARGS` / `AGENT_LAUNCHER` (035a-e), a poisoned `AUTONOMOUS_CONF_DIR` / `PROJECT_DIR` conf supplied WITHOUT `env -u PROJECT_DIR` (035f-k, conf-discovery self-defense), and `KIRO_AGENT_NAME=other` (→ kiro `--agent` argv) / `AGENT_TIMEOUT=bogus` (→ launch never runs → stdin-not-fed) (035l-o). All proven to FAIL pre-fix; source-of-truth assertions grep the actual scrub/reset lines. | each leak still all-PASS / exit 0; 035l/m FAIL pre-fix |
| TC-CONFORMANCE-036 | Codex drop-reason is rc-gated (PR #244 [P1], codex review `fff5f671`): the runner passes the fixture's launch rc into `_classify_codex_drop_reason`, which gates `config-error` on rc == 2. A transient codex fixture (rc 1) whose capture merely QUOTES a clap line classifies `stream-error`/transient, NOT `config`. 036a source-of-truth (`"$rc"` threaded); 036b the promoted `codex-quoted-clap-nonconfig` fixture PASSes; 036c/d the WITHOUT-rc→`config-error` / WITH-rc-1→`stream-error` gate proof. | fixture PASS (transient); classifier WITHOUT rc → `config-error:-s`, WITH rc 1 → `stream-error` |

## Promoted-fixture coverage (the E2E / CI tier)

| ID | Scenario | Expected |
|---|---|---|
| TC-CONFORMANCE-040 | The full promoted fixture set runs green on a fresh clone with no credentials. | every fixture PASS, runner rc 0 |
| TC-CONFORMANCE-041 | Both halves of each load-bearing rc mapping are pinned as PROMOTED fixtures the full run exercises (PR #244 [P1] #2): `claude-timeout-veto.json` (rc 124 ⇒ timeout-veto, 041a-c), `claude-timeout-veto-sigkill.json` (rc 137 ⇒ timeout-veto, 041d-f), `claude-rc0-noverdict-drop.json` (rc 0 + no provider + no verdict ⇒ drop, stdout carries no `<NONCE>`, 041g-i). A regression in EITHER mapping FAILs the run. | all three fixtures present, projected vote pins the mapping, all PASS the full run |
| TC-CONFORMANCE-042 | ≥2 manifests per fan-out CLI (claude, codex, kiro, agy). | fixture count per adapter ≥2 |
| TC-CONFORMANCE-043 | Deliberately flipping one `expect` field in a temp copy produces a loud, readable FAIL. | FAIL with a one-line axis diff |
| TC-CONFORMANCE-044 | agy auth-only log (401 / not-logged-in, NO quota marker) classifies `auth/absent/drop/false`, distinct from the quota fixture whose log carries both 429 and 401 yet classifies `quota` (quota precedence). Pins the auth-vs-quota boundary. | `CONFORMANCE agy/review/agy-auth-failed PASS`; auth-only log asserted free of any quota marker |
| TC-CONFORMANCE-045 | Combined-stream fidelity: a codex stream-error recorded on **stdout** with empty stderr classifies `transient/absent/drop/true` — the runner recovers the provider token off the same combined stdout+stderr view `_smoke_classify` uses, not stderr only. Pins INV-73's "drives TODAY's classifier, not a narrower copy". | `CONFORMANCE codex/review/codex-stream-error-stdout PASS`; fixture asserted to carry the ladder on stdout |

## Wiring / regression

| ID | Scenario | Expected |
|---|---|---|
| TC-CONFORMANCE-050 | `run-conformance.sh` + `lib-conformance.sh` pass `bash -n` and ShellCheck `-S error`. | clean |
| TC-CONFORMANCE-051 | CI `unit-tests` job invokes `run-conformance.sh` as an always-on step. | grep the workflow for the conformance invocation |
| TC-CONFORMANCE-052 | The classification path the runner drives is the REAL `_smoke_classify` + per-CLI scrapers (no re-implemented copy). | runner sources `lib-agent-smoke.sh`; asserted by grep |
| TC-CONFORMANCE-053 | `invariants.md` gains INV-73 in the same PR; `README.md`/adapter-spec cross-link the runner. | grep |
