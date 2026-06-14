# Test Cases: Operator Error Envelope (issue #231)

ID format: `TC-ERR-ENVELOPE-NNN`.

Implements the error-envelope contract from the adapter spec (#229 / INV-66):
config-class failures MUST surface on the issue (or as a dispatcher alert),
never log-only (new **INV-72**).

Tests live in:
- `tests/unit/test-lib-error-envelope.sh` — `lib-error.sh` rendering + surfacing
  + schema-conformance + registry-drift guard.

## Unit — envelope rendering (`error_envelope`)

| ID | Scenario | Expected |
|---|---|---|
| TC-ERR-ENVELOPE-001 | `error_envelope CODE problem cause remediation` (no doc, no class) | Output contains the human block (problem / cause / remediation) AND an `<!-- adt-error-envelope: {json} -->` marker. JSON has `schema_version:1`, `code:"CODE"`, `class:"config"` (default), `surface:"issue-comment"` (default for config). |
| TC-ERR-ENVELOPE-002 | special chars in cause/remediation (backticks, double quotes, `$(cmd)`, newline) | Embedded JSON is well-formed (`jq -e .` passes); the special chars round-trip verbatim in the decoded JSON values. No shell evaluation of `$(...)`. |
| TC-ERR-ENVELOPE-003 | `class=transient` | Embedded JSON `class:"transient"`, `surface:"log-only"`. |
| TC-ERR-ENVELOPE-004 | explicit `doc` arg | Embedded JSON has `doc` field with the given value. |
| TC-ERR-ENVELOPE-005 | embedded JSON validates against `error-envelope.schema.json` | python3 jsonschema (or jq structural fallback) accepts the rendered envelope for config/auth/quota/transient classes. |
| TC-ERR-ENVELOPE-006 | invalid `code` (lowercase / spaces) is rejected by the helper | `error_envelope` returns non-zero (Clause E3 — stable UPPER_SNAKE code); no marker emitted. |
| TC-ERR-ENVELOPE-007 | empty `remediation` is rejected by the helper | `error_envelope` returns non-zero (Clause E1 — remediation REQUIRED). |

## Unit — surfacing (`error_surface`)

| ID | Scenario | Expected |
|---|---|---|
| TC-ERR-ENVELOPE-009b | `error_envelope` 7th-arg surface override (P2 mechanism) | A valid `issue-comment`/`dispatcher-alert` override pins the marker `surface`; a `log-only` override on an operator-actionable class is rejected (Clause E2 → class default); an invalid override is ignored. |
| TC-ERR-ENVELOPE-010 | `error_surface <issue> …` with a working stubbed `gh` proxy | The stubbed `gh issue comment <issue> --repo … --body …` is invoked once; the body contains the `code` + `remediation` + the marker; the marker `surface` is `issue-comment` (P2). The full envelope is ALSO written to the wrapper log/stderr on the success path (P1-1 — same envelope to log AND issue). `error_surface` returns 0. |
| TC-ERR-ENVELOPE-010b | missing `REPO` but `REPO_OWNER`/`REPO_NAME` present (the `ADT_CFG_MISSING_KEY`-for-`REPO` case) | `error_surface` falls back to `${REPO_OWNER}/${REPO_NAME}` for `gh --repo` (NOT an empty `--repo`), so the comment still posts before `cd "$PROJECT_DIR"` (P1-2). |
| TC-ERR-ENVELOPE-011 | comment-post FAILS (stub `gh` exits non-zero) | `error_surface` still returns 0 (best-effort); the full envelope is logged to stderr (degrade to log-only). The caller's rc is unaffected. |
| TC-ERR-ENVELOPE-012 | no project-side symlink (fresh install) → **fallback** to the co-located `gh-with-token-refresh.sh` | The envelope STILL POSTS via the skill-tree fallback (P1 fix), returns 0, does NOT degrade to log-only. Never uses bare PATH `gh`. |
| TC-ERR-ENVELOPE-012b | proxy TRULY unresolvable (no symlink AND no skill-tree fallback) | `error_surface` degrades to log-only (envelope on stderr), returns 0; logs that the proxy is not resolvable. |
| TC-ERR-ENVELOPE-013 | empty issue number (`-` or "") → dispatcher-alert | No `gh` post attempted; the envelope is logged with a `dispatcher-alert` marker, and the marker `surface` reads `dispatcher-alert` (NOT `issue-comment`) (P2). Returns 0. |
| TC-ERR-ENVELOPE-014 | `class=transient` via `error_surface` | Regression pin: NO `gh` post; the envelope goes to the log only (`surface:"log-only"`). Returns 0. |

## Unit — code registry drift guard

| ID | Scenario | Expected |
|---|---|---|
| TC-ERR-ENVELOPE-020 | every `ADT_*` / known code emitted by a wrapper/lib caller of `error_surface`/`error_envelope` exists as a row in `docs/pipeline/errors.md` | grep-assert: scan the rewired scripts for `error_surface`/`error_envelope` call-site codes; each appears in `errors.md`. Fails loudly on drift (a new code added without a registry row). |
| TC-ERR-ENVELOPE-021 | `docs/pipeline/errors.md` exists and every documented code is UPPER_SNAKE | Registry well-formed; codes match `^[A-Z][A-Z0-9_]*$`. |
| TC-ERR-ENVELOPE-022 | `docs/pipeline/invariants.md` defines INV-72 cross-linking the schema + errors.md | grep-assert `^## INV-72:`. |

## Unit — wrapper rewire (config-class abort paths emit + surface)

Strategy: extract the relevant validation block / call the helper in a harness
with a stubbed `gh` proxy and a broken-conf input; assert the envelope marker
is produced and the comment is posted.

| ID | Scenario | Expected |
|---|---|---|
| TC-ERR-ENVELOPE-030 | dev wrapper: invalid `E2E`/conf path surfaces (representative) | Covered structurally by the helper tests + the E2E stub run. The per-path rewire is exercised via `error_surface`/`error_envelope` unit coverage (the call sites are thin wrappers around the helper). |
| TC-ERR-ENVELOPE-031 | transient-class agent-exit retry posts NO envelope (regression pin) | No `error_surface` call on the agent-failure retry path; behavior unchanged. |

## Unit — agent CLI binary preflight (`lib-agent.sh`)

Strategy: exercise `preflight_agent_binary` / `_agent_launch_binary` directly in
a clean subshell with a controlled `PATH` (only a temp `bin/` + coreutils) and a
stub token-refresh `gh` proxy that records issue-comment posts. The full
`run_agent` launch pipeline (setsid + timeout + background wait) is intentionally
NOT driven — a static assertion pins that both `run_agent` and `resume_agent`
call the preflight and short-circuit on its non-zero return.

Test file: `tests/unit/test-lib-agent-binary-preflight.sh`.

| ID | Scenario | Expected |
|---|---|---|
| TC-BINPF-STATIC | preflight is wired + documented | `preflight_agent_binary \|\| return` appears in BOTH `run_agent` and `resume_agent` (2 sites); `lib-agent.sh` emits `ADT_CFG_AGENT_BINARY_MISSING`; the code is documented in `errors.md`. |
| TC-BINPF-001 | missing `claude` binary (none on `PATH`) | preflight returns 1; envelope posted on the issue naming the missing binary `claude`, carrying remediation, marker `surface=issue-comment`. |
| TC-BINPF-002 | `claude` binary present | preflight returns 0; no envelope posted. |
| TC-BINPF-003 | `AGENT_CMD=kiro` resolves `kiro-cli` (not `kiro`) | with only `kiro` present → returns 1, envelope names `kiro-cli`; with `kiro-cli` present → returns 0. |
| TC-BINPF-004 | a launcher is configured (`AGENT_LAUNCHER_ARGV` non-empty) | preflight stands down: returns 0, no envelope, even with no `claude` on `PATH` (launcher owns binary resolution). |
| TC-BINPF-005 | missing binary + empty `ISSUE_NUMBER` | returns 1; NO `gh` post (dispatcher-alert, log-only). |
| TC-BINPF-006 | `_agent_launch_binary` mapping | `claude→claude`, `codex→codex`, `kiro→kiro-cli`, `agy→agy`; launcher set → empty (skip). |

## E2E

| ID | Scenario | Expected |
|---|---|---|
| TC-ERR-ENVELOPE-040 | stub-wrapper run with a deliberately broken conf (e.g. invalid `E2E_MODE`) → issue comment appears with code + remediation; issue label state unchanged by the post | `tests/e2e/` stub run: the wrapper aborts at startup, posts the envelope via the stubbed `gh`, the captured comment body carries the `code` and `remediation`, and no `label` mutation is recorded by the post. |

## Coverage note

The bulk of behavior lives in `lib-error.sh` (`error_envelope` + `error_surface`),
which is fully unit-tested above (rendering, special-char safety, surfacing,
post-failure degradation, transient regression pin, schema conformance). The
per-call-site rewires are thin (`error_surface … || true; exit 1`), so coverage
of the helper plus the drift guard plus the E2E stub run gives the >80% target
for the new logic.
