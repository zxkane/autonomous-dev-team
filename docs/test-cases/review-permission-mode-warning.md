# Test Cases - Review Permission-Mode Warning

## Predicate

| ID | Scenario | Expected |
|---|---|---|
| TC-CONF-PERMMODE-001 | Resolved fleet contains `claude`, mode is `auto`, and both reporting knobs are disabled | `warn` |
| TC-CONF-PERMMODE-002 | Resolved fleet contains `claude`, mode is `plan`, and both reporting knobs are disabled | `warn` |
| TC-CONF-PERMMODE-003 | Resolved fleet contains `claude`, mode is `plan`, and both reporting knobs are enabled | `warn` |
| TC-CONF-PERMMODE-004 | Claude `auto` lane has operator `--allowedTools` extra args but both reporting knobs are disabled | `warn`; extra args are not an escape hatch |
| TC-CONF-PERMMODE-005 | Claude `default` lane has injection enabled and fallback disabled | `warn`; injection is auto-only |
| TC-CONF-PERMMODE-006 | Resolved fleet contains `claude` and mode is `bypassPermissions` | no warning |
| TC-CONF-PERMMODE-007 | Resolved fleet has no Claude member and mode is `auto` | no warning |
| TC-CONF-PERMMODE-008 | Claude uses a non-`plan` mode with final-text fallback enabled | no warning |
| TC-CONF-PERMMODE-009 | Claude uses `auto` with permission injection enabled | no warning |

## Suppression And Fingerprints

| ID | Scenario | Expected |
|---|---|---|
| TC-CONF-PERMMODE-010 | `CONF_PERMMODE_WARN=false` under an otherwise unsafe configuration | No predicate-side effect, log warning, comment read, or comment post |
| TC-CONF-PERMMODE-011 | The same unsafe fingerprint is evaluated twice | Warning remains visible in the wrapper log; exactly one issue comment is posted |
| TC-CONF-PERMMODE-012 | Two different unsafe fingerprints are evaluated | Two issue comments are posted with different markers |
| TC-CONF-PERMMODE-013 | Fingerprint inputs are repeated byte-for-byte | Fingerprint is stable |
| TC-CONF-PERMMODE-014 | Mode, fleet, or reporting knob state changes | Fingerprint changes |
| TC-CONF-PERMMODE-020 | A human comment contains the exact fingerprint marker | It does not suppress the wrapper warning comment |
| TC-CONF-PERMMODE-021 | Comment-provider output is malformed | Deduplication fails closed and posts no potentially duplicate comment |

## Hermetic Wrapper Fixtures

| ID | Scenario | Expected |
|---|---|---|
| TC-CONF-PERMMODE-015 | A sourced fixture resolves `AGENT_REVIEW_CMD=claude` while raw `AGENT_CMD` is non-Claude, with unsafe knobs | The real wrapper startup block logs and posts one warning |
| TC-CONF-PERMMODE-016 | A sourced fixture resolves a non-Claude review fleet under `auto` | No warning log or issue comment |
| TC-CONF-PERMMODE-017 | A sourced fixture enables final-text fallback for a non-`plan` Claude lane | No warning log or issue comment |
| TC-CONF-PERMMODE-018 | A sourced unsafe fixture includes operator `--allowedTools` extra args | The real wrapper startup block still logs and posts the warning |
| TC-CONF-PERMMODE-019 | A sourced unsafe fixture sets `CONF_PERMMODE_WARN=false` | The real wrapper startup block emits nothing and performs no comment I/O |
| TC-CONF-PERMMODE-022 | The warning fixture posts through the wrapper | The comment includes the standard run footer and marker reads require self-author resolution |
| TC-CONF-PERMMODE-023 | Wrapper source placement is inspected | Provider I/O begins after the cleanup trap is installed |
