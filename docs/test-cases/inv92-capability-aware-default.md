# Test Cases: INV-134 capability-aware default for `REVIEW_PROTECTED_PATHS` (#488)

Covers wiring the existing `agent_token_has_workflow_scope()` probe
(`lib-review-classify.sh`, previously dead code) into the built-in DEFAULT
derivation for `REVIEW_PROTECTED_PATHS`, the matching prompt-rule wiring, and
the classification-time stall diagnostics. See `docs/pipeline/invariants.md`
INV-134 and INV-92. Driven by `tests/unit/test-review-classify.sh` (D1/D2/D4
lib-level), `tests/unit/test-autonomous-review-prompt.sh` (D2 prompt-wiring
regression pin), and `tests/unit/test-handle-completed-session-routing.sh` /
`tests/unit/test-issue-466-crashed-session-recovery.sh` (D4 dispatcher-side
marker surfacing).

## D1 — capability-aware DEFAULT derivation (`review_path_is_protected` / `_review_protected_paths_default_list`)

`REVIEW_PROTECTED_PATHS` UNSET in every row below (an explicit value — including
`""` — is covered separately in the "Explicit value never rewritten" table).

| ID | `GH_AUTH_MODE` | `AGENT_TOKEN_PERMISSIONS` | Default list | `.github/workflows/ci.yml` | `CODEOWNERS` |
|---|---|---|---|---|---|
| TC-INV134-D1-01 | `app` | `{"workflows":"write"}` present | `CODEOWNERS .github/CODEOWNERS` | NOT protected | protected |
| TC-INV134-D1-02 | `app` | default (no `workflows` key) | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected | protected |
| TC-INV134-D1-03 | `token` | `{"workflows":"write"}` present | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (mode gate) | protected |
| TC-INV134-D1-04 | `app` | empty string | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (fail-closed) | protected |
| TC-INV134-D1-05 | `app` | malformed JSON | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (fail-closed) | protected |
| TC-INV134-D1-06 | `app` | unset | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (fail-closed) | protected |
| TC-INV134-D1-07 | unset (GitLab / no concept) | `{"workflows":"write"}` present | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (mode gate) | protected |
| TC-INV134-D1-08 | `app`, `jq` unavailable (`command -v jq` false) | `{"workflows":"write"}` present | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (fail-closed) | protected |

CODEOWNERS / `.github/CODEOWNERS` are protected in EVERY row — the capability
check only ever touches `.github/workflows/**` membership.

### Explicit value never rewritten (either direction)

| ID | `REVIEW_PROTECTED_PATHS` | `GH_AUTH_MODE` + scope | Effective list |
|---|---|---|---|
| TC-INV134-D1-09 | `""` (explicit empty) | `app` + scope present | `""` (still nothing protected — NOT re-populated with CODEOWNERS) |
| TC-INV134-D1-10 | `""` (explicit empty) | `app`, scope absent | `""` (unchanged) |
| TC-INV134-D1-11 | `"infra/**"` | `app` + scope present | `infra/**` verbatim (workflows NOT re-added) |
| TC-INV134-D1-12 | `".github/workflows/** infra/**"` | `app` + scope present | unchanged verbatim — an operator who EXPLICITLY lists `.github/workflows/**` keeps it protected even when the capability check would otherwise omit it from the default |

### No capability probe invoked on an explicit value (side-effect check)

| ID | Assertion |
|---|---|
| TC-INV134-D1-13 | With `REVIEW_PROTECTED_PATHS` explicitly set (any value, including `""`), `agent_token_has_workflow_scope` is never called — the `${VAR-$(...)}` command-substitution default only evaluates on the unset branch. Verified by a probe wrapper that records call count. |

## D2 — prompt/derivation consistency (`review_protected_paths_prompt_rule`)

| ID | Config | Prompt rule assertion |
|---|---|---|
| TC-INV134-D2-01 | App + scope present, `REVIEW_PROTECTED_PATHS` unset | Prompt's protected-path glob list does NOT contain `.github/workflows/**` (matches D1-01's effective list) |
| TC-INV134-D2-02 | App, scope absent, unset | Prompt's glob list DOES contain `.github/workflows/**` (matches D1-02) |
| TC-INV134-D2-03 | App + scope present | Prompt's `requires_privileged_token` guidance states the token's `workflows` scope is `true` for this configuration (never the old hardcoded "it does by default") |
| TC-INV134-D2-04 | App, scope absent | Prompt's `requires_privileged_token` guidance states the token's `workflows` scope is `false` |
| TC-INV134-D2-05 | Token mode, scope var present (mode gate) | Prompt's glob list still contains `.github/workflows/**` (mirrors D1-03) and the token-scope note reads `false` |

## D3 — anti-forge preservation (regression, unchanged behavior)

| ID | Scenario | Effective `actionable_by_dev_agent` |
|---|---|---|
| TC-INV134-D3-01 | App + scope present (workflows NOT in default protected list) — agent asserts `actionable_by_dev_agent:true` on a `.github/workflows/ci.yml` finding | `true` (not a protected path anymore under this config — no override needed, and none forged) |
| TC-INV134-D3-02 | App, scope absent (workflows IS in default protected list) — agent asserts `actionable_by_dev_agent:true` on the same finding | `false` (wrapper override still fires — the anti-forge invariant is untouched) |
| TC-INV134-D3-03 | Any config — agent asserts `actionable_by_dev_agent:false` on a NON-protected path | `false` (never promoted to `true`, in every capability outcome) |
| TC-INV134-D3-04 | App + scope present — CODEOWNERS finding, agent asserts `true` | `false` (CODEOWNERS is protected in every config; override still fires) |

## D4 — stall-notice diagnostics

### Wrapper-side: `review_classify_artifact_matched_patterns` (lib-review-classify.sh)

| ID | Blocking findings | Matched patterns (sorted, unique) |
|---|---|---|
| TC-INV134-D4-01 | `.github/workflows/ci.yml`, `CODEOWNERS`, `src/foo.ts` | `.github/workflows/**`, `CODEOWNERS` |
| TC-INV134-D4-02 | `src/foo.ts` only (no protected match) | empty |
| TC-INV134-D4-03 | non-JSON input | empty (fail-empty) |
| TC-INV134-D4-04 | two findings both matching `.github/workflows/**` | single entry (deduped) |

### Wrapper-side: findings comment + marker (autonomous-review.sh)

| ID | Scenario | Assertion |
|---|---|---|
| TC-INV134-D4-05 | Aggregate `dev-actionable=false`, matched patterns non-empty | A comment is posted containing "Matched protected-path pattern(s):" naming each pattern, the `REVIEW_PROTECTED_PATHS` conf-lever sentence, and a trailing `<!-- inv92-matched-patterns: <space-separated patterns> -->` marker line |
| TC-INV134-D4-06 | Aggregate `dev-actionable=true` (mixed) | No matched-patterns comment posted (only genuinely non-actionable aggregates trigger it) |
| TC-INV134-D4-07 | Aggregate `dev-actionable=false`, but no FAILing agent recorded a matched pattern (agent self-reported `false` on a non-protected path) | No matched-patterns comment posted — nothing to name |

### Dispatcher-side: stall comment surfaces the marker when present, generic fallback otherwise

| ID | Scenario | Assertion |
|---|---|---|
| TC-INV134-D4-08 | Branch B′ (`handle_completed_session_routing`) fires, `inv92-matched-patterns:` marker present on the issue | The escalation notice includes "Matched `REVIEW_PROTECTED_PATHS` pattern(s):" + the pattern list from the marker |
| TC-INV134-D4-09 | Branch B′ fires, no marker present | The escalation notice is byte-identical to the pre-#488 generic wording (no new sentence, no failure) |
| TC-INV134-D4-10 | `_same_head_verdict_aware_recovery`'s dev-actionable=false branch fires, marker present | Same pattern-surfacing sentence appears in that notice too |
| TC-INV134-D4-11 | `_inv92_matched_patterns` helper: `itp_list_comments` transport failure | Returns empty (fail-empty; caller falls back to generic wording, never crashes) |

## D5 — docs (verified structurally, not by these unit tests)

- `docs/pipeline/invariants.md` has an `INV-134` entry; the `INV-92` entry
  cross-references it.
- `docs/pipeline/review-agent-flow.md`'s classification section describes the
  capability-aware default + the D4 marker.
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` documents
  `REVIEW_PROTECTED_PATHS` + `AGENT_TOKEN_PERMISSIONS` interaction (adding
  `"workflows":"write"` in App mode is the sanctioned unlock; PAT/GitLab keep
  the explicit-override workaround).
