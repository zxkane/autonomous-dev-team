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

| ID | `CODE_HOST` | `GH_AUTH_MODE` | `AGENT_TOKEN_PERMISSIONS` | Default list | `.github/workflows/ci.yml` | `CODEOWNERS` |
|---|---|---|---|---|---|---|
| TC-INV134-D1-01 | unset | `app` | `{"workflows":"write"}` present | `CODEOWNERS .github/CODEOWNERS` | NOT protected | protected |
| TC-INV134-D1-02 | unset | `app` | default (no `workflows` key) | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected | protected |
| TC-INV134-D1-03 | unset | `token` | `{"workflows":"write"}` present | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (mode gate) | protected |
| TC-INV134-D1-04 | unset | `app` | empty string | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (fail-closed) | protected |
| TC-INV134-D1-05 | unset | `app` | malformed JSON | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (fail-closed) | protected |
| TC-INV134-D1-06 | unset | `app` | unset | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (fail-closed) | protected |
| TC-INV134-D1-07 | unset | unset (GitLab / no concept) | `{"workflows":"write"}` present | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (mode gate) | protected |
| TC-INV134-D1-08 | unset | `app`, `jq` unavailable (`command -v jq` false) | `{"workflows":"write"}` present | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (fail-closed) | protected |
| TC-INV134-D1-14 | `gitlab` | `app` (leftover conf) | `{"workflows":"write"}` present | `.github/workflows/** CODEOWNERS .github/CODEOWNERS` | protected (host gate — GitLab mints no scoped GitHub token) | protected |
| TC-INV134-D1-15 | `github` (explicit) | `app` | `{"workflows":"write"}` present | `CODEOWNERS .github/CODEOWNERS` | NOT protected (explicit-github behaves like unset) | protected |
| TC-INV134-D1-16 | unset | `app` | `{"workflows":"write"}` present | `CODEOWNERS .github/CODEOWNERS` | NOT protected (unset defaults to github, no regression) | protected |

CODEOWNERS / `.github/CODEOWNERS` are protected in EVERY row — the capability
check only ever touches `.github/workflows/**` membership. The `CODE_HOST`
gate (D1-14..16) was added after PR #498 round-1 codex review [P2] finding #1:
a pure GitLab run retaining a leftover `GH_AUTH_MODE=app` + `workflows`-scoped
`AGENT_TOKEN_PERMISSIONS` conf fragment must NOT relax the default, since
GitLab mints no scoped GitHub token those vars could describe.

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
| TC-INV134-D2-06 | `CODE_HOST=gitlab` + App-mode leftover conf (scope var present) | Prompt's glob list still contains `.github/workflows/**` (mirrors D1-14, the host gate) and the token-scope note reads `false` |

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
| TC-INV134-D4-05b [D1+D4 end-to-end] | App + scope present (workflows unlocked), mixed artifact touching `.github/workflows/ci.yml` + `CODEOWNERS` + `src/foo.ts` | Matched patterns report `CODEOWNERS` ONLY — proves the diagnostics function delegates to the SAME capability-aware `REVIEW_PROTECTED_PATHS`, not an independently hardcoded default |

### Wrapper-side: findings comment + marker (autonomous-review.sh)

| ID | Scenario | Assertion |
|---|---|---|
| TC-INV134-D4-05 | Aggregate `dev-actionable=false`, matched patterns non-empty | A comment is posted containing "Matched protected-path pattern(s):" naming each pattern, the `REVIEW_PROTECTED_PATHS` conf-lever sentence, and a trailing `<!-- inv92-matched-patterns: <space-separated patterns> -->` marker line |
| TC-INV134-D4-06 | Aggregate `dev-actionable=true`, NO matched patterns recorded | No matched-patterns comment posted (nothing to name) |
| TC-INV134-D4-07 | Aggregate `dev-actionable=false`, but no FAILing agent recorded a matched pattern (agent self-reported `false` on a non-protected path) | No matched-patterns comment posted — nothing to name |
| TC-INV134-D4-14 [mixed-failure regression, PR #498 round-1 codex review [P2] finding #2] | Aggregate `dev-actionable=true` (a MIXED FAIL: one protected-path finding + one ordinary actionable finding), but a matched pattern WAS recorded | A comment IS still posted, naming the pattern + carrying the marker; the lead sentence does NOT claim the whole FAIL is unactionable, and instead notes the dev agent is still re-dispatched for the remaining actionable finding(s) |

The matched-pattern collection is computed UNCONDITIONALLY (never gated on
the aggregate `dev-actionable` bit) — only whether the resulting
`_AGG_MATCHED_PATTERNS` is non-empty controls whether the comment posts. The
comment's lead sentence still branches on the aggregate for correct wording.

### Dispatcher-side: stall comment surfaces the marker when present, generic fallback otherwise

| ID | Scenario | Assertion |
|---|---|---|
| TC-INV134-D4-08 | Branch B′ (`handle_completed_session_routing`) fires, `inv92-matched-patterns:` marker present on the issue | The escalation notice includes "Matched `REVIEW_PROTECTED_PATHS` pattern(s):" + the pattern list from the marker |
| TC-INV134-D4-09 | Branch B′ fires, no marker present | The escalation notice is byte-identical to the pre-#488 generic wording (no new sentence, no failure) |
| TC-INV134-D4-10 | `_same_head_verdict_aware_recovery`'s dev-actionable=false branch fires, marker present | Same pattern-surfacing sentence appears in that notice too |
| TC-INV134-D4-11 | `_inv92_matched_patterns` helper: `itp_list_comments` transport failure | Returns empty (fail-empty; caller falls back to generic wording, never crashes) |
| TC-INV134-D4-12 [set -e regression] | `handle_completed_session_routing` Branch B′, called as a bare top-level statement (mirrors `dispatcher-tick.sh:693`) under REAL `set -euo pipefail`, with the idempotency check succeeding but the `_inv92_matched_patterns`-internal `itp_list_comments` call transiently failing | `mark_stalled` is still reached and the caller returns normally — does NOT abort under `set -e`/`pipefail` (regression: `_inv92_matched_patterns`'s pipe needs `\|\| true`, or a transient transport blip aborts the entire dispatcher tick, silently skipping every other in-flight issue for that cycle) |
| TC-INV134-D4-13 [set -e regression, defense-in-depth] | Same failure injection, but through `_same_head_verdict_aware_recovery` via `handle_pending_dev_pr_exists` under the SAME `if handle_pending_dev_pr_exists ...; then` context `dispatcher-tick.sh:583` uses | `mark_stalled` still reached; this call site is currently shielded by bash's errexit-suppression-inside-an-if-condition rule regardless of the fix, but the pin locks in the fix as defense-in-depth (a future refactor to a bare-statement call would make this call site load-bearing too) |

## D5 — docs (verified structurally, not by these unit tests)

- `docs/pipeline/invariants.md` has an `INV-134` entry; the `INV-92` entry
  cross-references it.
- `docs/pipeline/review-agent-flow.md`'s classification section describes the
  capability-aware default + the D4 marker.
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` documents
  `REVIEW_PROTECTED_PATHS` + `AGENT_TOKEN_PERMISSIONS` interaction (adding
  `"workflows":"write"` in App mode is the sanctioned unlock; PAT/GitLab keep
  the explicit-override workaround).
