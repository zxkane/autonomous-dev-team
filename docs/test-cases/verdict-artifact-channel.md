# Test Cases: Verdict Artifact Channel (issue #233, INV-78)

ID format: `TC-VERDICT-ARTIFACT-NNN`.

Backend note: the artifact classifier uses the same dual python3-jsonschema /
jq-fallback strategy as `test-adapter-spec-schemas.sh`, so these cases run on
bare CI.

## Unit — artifact classification (`_classify_verdict_artifact`)

| ID | Scenario | Expected |
|---|---|---|
| TC-VERDICT-ARTIFACT-001 | Valid PASS artifact (golden.pass) | state `valid`; verdict `pass` |
| TC-VERDICT-ARTIFACT-002 | Valid FAIL artifact (golden.fail) | state `valid`; verdict `fail` |
| TC-VERDICT-ARTIFACT-003 | Absent file (path does not exist) | state `absent` |
| TC-VERDICT-ARTIFACT-004 | Malformed: no `schema_version` (negative fixture) | state `malformed` |
| TC-VERDICT-ARTIFACT-005 | Malformed: FAIL with empty `blockingFindings` (negative fixture) | state `malformed` |
| TC-VERDICT-ARTIFACT-006 | Malformed: blocking findings but verdict PASS (negative fixture) | state `malformed` |
| TC-VERDICT-ARTIFACT-007 | Malformed: non-JSON garbage bytes | state `malformed` |
| TC-VERDICT-ARTIFACT-008 | Malformed: empty file (0 bytes) | state `malformed` |
| TC-VERDICT-ARTIFACT-009 | `_verdict_from_artifact_json` maps PASS→pass, FAIL→fail | correct token |
| TC-VERDICT-ARTIFACT-010 | `_artifact_schema_error` echoes a non-empty one-line reason for a malformed file | non-empty |

## Unit — path provisioning (`_verdict_artifact_path`)

| ID | Scenario | Expected |
|---|---|---|
| TC-VERDICT-ARTIFACT-011 | Path honors `XDG_STATE_HOME` when set | `$XDG_STATE_HOME/autonomous-<p>/runs/<rid>/verdict-<agent>.json` |
| TC-VERDICT-ARTIFACT-012 | Path falls back to `$HOME/.local/state` when XDG unset | `$HOME/.local/state/autonomous-<p>/runs/<rid>/verdict-<agent>.json` |
| TC-VERDICT-ARTIFACT-013 | Provisioner + reader agree on the path (no divergence) | identical string |

## Unit — atomic-rename / duplicate / late-write (Clause VA5)

| ID | Scenario | Expected |
|---|---|---|
| TC-VERDICT-ARTIFACT-014 | Only `<path>.tmp` exists (rename not yet done) → no final file | state `absent` (torn read impossible) |
| TC-VERDICT-ARTIFACT-015 | Read once; a later write replaces the file with a different verdict | first read's snapshot wins; late write ignored + logged |
| TC-VERDICT-ARTIFACT-016 | Duplicate write of the SAME verdict after read | ignored (no second classification), logged |

## Unit — aggregation precedence (artifact > comment)

| ID | Scenario | Expected |
|---|---|---|
| TC-VERDICT-ARTIFACT-017 | Agent has a valid artifact AND a conflicting comment | artifact wins; `verdict-source=artifact`; conflict logged |
| TC-VERDICT-ARTIFACT-018 | Agent has NO artifact but a posted comment | comment fallback; `verdict-source=comment-fallback` logged |
| TC-VERDICT-ARTIFACT-019 | Agent has a malformed artifact | treated as absent for vote (Clause V1); NOT silent PASS; envelope emitted |
| TC-VERDICT-ARTIFACT-020 | All agents have valid artifacts → poll loop seeded resolved | loop breaks round 1; ZERO `gh … --json comments` calls |

## Unit — fan-out matrices (single + multi agent)

| ID | Scenario | Aggregate |
|---|---|---|
| TC-VERDICT-ARTIFACT-021 | single-agent valid PASS artifact | pass |
| TC-VERDICT-ARTIFACT-022 | single-agent valid FAIL artifact | fail |
| TC-VERDICT-ARTIFACT-023 | single-agent malformed artifact, no comment | all-unavailable (absent semantics) |
| TC-VERDICT-ARTIFACT-024 | multi: valid PASS + valid PASS | pass |
| TC-VERDICT-ARTIFACT-025 | multi: valid PASS + valid FAIL | fail |
| TC-VERDICT-ARTIFACT-026 | multi: valid PASS + absent-with-comment-PASS (fallback) | pass |
| TC-VERDICT-ARTIFACT-027 | multi: valid PASS + malformed (drop) | pass (1 deciding) |
| TC-VERDICT-ARTIFACT-028 | multi: malformed + absent-no-comment | all-unavailable |

## Unit — regression pins (preserved semantics)

| ID | Scenario | Expected |
|---|---|---|
| TC-VERDICT-ARTIFACT-029 | rc124 + no artifact ⇒ deciding FAIL (timeout-veto preserved) | `_classify_noverdict_agent 124` → timed-out |
| TC-VERDICT-ARTIFACT-030 | INV-41 per-agent model resolution path unchanged by artifact wiring | model still resolves per-agent |
| TC-VERDICT-ARTIFACT-031 | comment-fallback parity: no-artifact agent reaches same final state as today | identical aggregate to pre-#233 |

## Render-format pins (machine consumers)

| ID | Consumer | Pin |
|---|---|---|
| TC-VERDICT-ARTIFACT-032 | dispatcher INV-03/06/07 | wrapper still emits `<!-- review-verdict: passed -->` / `failed-substantive` / `failed-non-substantive cause=…` (emit_verdict_trailer unchanged) |
| TC-VERDICT-ARTIFACT-033 | dev-resume parser | wrapper-rendered FAIL aggregate comment still starts `Review findings:` |
| TC-VERDICT-ARTIFACT-034 | post-verdict.sh | the agent verdict comment trailer (`Review Session:`/`Review Agent:`) is byte-for-byte unchanged |
| TC-VERDICT-ARTIFACT-035 | prompt | build_review_prompt injects the artifact path + atomic-write (tmp+rename) instruction |

## Unit — review-finding hardening ([P1]s on PR #262)

| ID | Scenario | Expected |
|---|---|---|
| TC-VERDICT-ARTIFACT-038 | True read-once ([P1]#1): classifier reads the artifact path exactly ONCE; validates the in-memory snapshot, not a re-read of `$_path` | single read; rename-after-read cannot flip the verdict |
| TC-VERDICT-ARTIFACT-039 | Identity binding ([P1]#2): `_classify_verdict_artifact <path> <run-id> <agent>` → matching identity valid; mismatched runId/agent → malformed; no expected identity → check skipped (back-compat); error names the mismatch | foreign-identity artifact rejected, never votes |
| TC-VERDICT-ARTIFACT-040 | jq fallback full schema ([P1]#3): rejects blockingFindings-empty-object, nonBlockingFindings-as-string, finding-missing-title, additional-property, negative line; still accepts valid goldens | full-shape enforcement in the packaged-install default |

## E2E — conformance + stub-fleet

| ID | Scenario | Expected |
|---|---|---|
| TC-VERDICT-ARTIFACT-036 | Conformance manifest: per-CLI fixture asserts `verdict.state` from an artifact file (incl. codex malformed) | matches expected state |
| TC-VERDICT-ARTIFACT-037 | Stub-fleet: 4 stub agents (valid / malformed / absent-with-comment / foreign-identity) | aggregate, per-agent sources, two loud envelopes (malformed + foreign-identity), zero-comment-poll all asserted |
