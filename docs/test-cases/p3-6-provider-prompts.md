# Test Cases — Provider-aware agent-prompt fragments (#421, #414 W-F)

Splits the 33 raw-`gh` sites in `providers/cutover-baseline.json` into (a) 20
parameterizable agent-prompt heredoc-prose sites (9 `autonomous-dev.sh`, 10
`autonomous-review.sh`, 1 `lib-review-bots.sh`) and (b) 13 executable
github-gated residue sites that STAY baselined (5 `lib-auth.sh`, 3
`check-provider-cutover.sh`, 1 `autonomous-dev.sh` `command -v gh` probe, 4
`autonomous-review.sh` — the `gh api user` bot-login fallback block + its 2
WARN diagnostics + the INV-33 sanctioned `gh issue close … --reason completed`
interim close). New `lib-provider-prompts.sh` exposes
`provider_prompt_fragment <key> [args...]`, keyed on `CODE_HOST`/
`ISSUE_PROVIDER`, rendering from `providers/prompts-github.sh` /
`providers/prompts-gitlab.sh`.

Test runners: `bash tests/unit/test-provider-prompts-github-golden.sh`,
`bash tests/unit/test-provider-prompts-gitlab-render.sh` (both auto-discovered
by the CI `unit` job's `tests/unit/test-*.sh` glob). Run the FULL suite under
`env -u PROJECT_DIR` for CI parity.

## Helper contract (R1, AC1)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-001 | Every one of the 20 `FRAGMENT_AXIS` keys renders against `providers/prompts-github.sh` with a fixed args seed | byte-identical to the checked-in golden `tests/unit/fixtures/provider-prompts-github/golden.txt` (TC-P36-001 in the github-golden runner) |
| TC-P36-002 | `provider_prompt_fragment nonexistent.key` | fails LOUD: rc≠0, stderr `unknown fragment key` |
| TC-P36-003 | `provider_prompt_fragment <valid-key>` with `CODE_HOST=nonexistent_provider` | fails LOUD: rc≠0, stderr `unknown provider` |
| TC-P36-004 | `provider_prompt_fragment review.check_mergeable` called with the wrong arg count (1 instead of the declared 2) | fails LOUD: rc≠0, stderr `expects 2 arg(s), got 1` |
| TC-P36-005 | Every `FRAGMENT_AXIS` key resolves to a non-empty entry in BOTH `_PP_GITHUB_FRAGMENT`/`_PP_GITHUB_ARGC` (github-golden runner) and `_PP_GITLAB_FRAGMENT`/`_PP_GITLAB_ARGC` (gitlab-render runner) | present in both (no orphaned key in one provider file) |

## GitHub rendering byte-identical (R3, AC2)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-001 | (see above) full github fragment set, fixed seed, diffed against golden | `diff -u` empty; on failure the runner prints the FULL delta |

## GitLab API-neutral rendering (R5, AC3)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-010 | Render every key against `providers/prompts-gitlab.sh` (fixed seed); grep the RE2-safe consuming-boundary regex `(^|[^A-Za-z_-])gh ` (same regex `check-provider-cutover.sh`'s `gh_lines_in` uses) | zero matches |
| TC-P36-011 | Same rendered text; grep `(^|[^A-Za-z_-])glab[[:space:]]` | count ≤ K, default K=0 (override via `PP_GITLAB_MAX_GLAB_TOKENS` only for a deliberate, documented, review-approved exception) |
| TC-P36-012 | Every `FRAGMENT_AXIS` key has both a gitlab fragment and an argc entry | present |
| TC-P36-013 | Per-key argc declared in `_PP_GITHUB_ARGC` vs `_PP_GITLAB_ARGC` | IDENTICAL — a call site fixes ONE positional-arg list regardless of which provider renders it; a gitlab template that needs fewer positionals consumes the rest via `%.0s` |
| TC-P36-014 | Unknown key fails loud with `CODE_HOST=gitlab` too | rc≠0, stderr `unknown fragment key` |

## Per-wrapper site-removal (R2/R4, AC4)

The (a) prose is GONE from the wrapper files (replaced by
`$(provider_prompt_fragment …)` calls); the (b) executable lines SURVIVE
byte-identical. Source-shape assertions (grep the migrated/baselined line
form, fixed-string, against the wrapper files under
`skills/autonomous-dispatcher/scripts/`).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-020 | `autonomous-dev.sh` non-comment raw-`gh` line count (the RE2-safe `(^|[^A-Za-z_-])gh ` scan, matching `check-provider-cutover.sh`'s detector) | exactly 1 — the `command -v gh &>/dev/null` presence probe (executable, (b), unchanged) |
| TC-P36-021 | `autonomous-review.sh` non-comment raw-`gh` line count | exactly 4 — the `gh api user` bot-login fallback assignment, its 2 WARN diagnostics, and the INV-33 `gh issue close … --reason completed` interim close (all executable, (b), unchanged) |
| TC-P36-022 | `lib-review-bots.sh` non-comment raw-`gh` line count | 0 — the sole (a) site (`COUNT=$(gh api …)`, 3 occurrences pre-migration) is fully replaced by `provider_prompt_fragment bots.review_count_check` / `bots.review_count_check_bare` calls |
| TC-P36-023 | `autonomous-dev.sh` / `autonomous-review.sh` / `lib-review-bots.sh` each source `lib-provider-prompts.sh` BEFORE `lib-review-bots.sh` is sourced (dev/review wrappers) or is available at call time (lib-review-bots.sh, sourced by the wrappers) | present, correct order |
| TC-P36-024 | Every `provider_prompt_fragment` call site in the three files passes the arg count its key declares | matches `_PP_GITHUB_ARGC`/`_PP_GITLAB_ARGC` (cross-checked by TC-P36-004/013's runtime behavior, not a static count here) |

## Baseline shrink (R4, AC4)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-030 | `providers/cutover-baseline.json` surviving-site count | 33 → 13 (shrink of exactly 20, the R2-classified (a) set) |
| TC-P36-031 | Per-file breakdown of the 13 surviving (b) sites | `lib-auth.sh`=5, `check-provider-cutover.sh`=3, `autonomous-dev.sh`=1, `autonomous-review.sh`=4 |
| TC-P36-032 | `check-provider-cutover.sh` (Check 1: tree-wide reconciliation) against the regenerated baseline | PASS — every survivor accounted for |
| TC-P36-033 | `check-provider-cutover.sh` (Check 4: monotonicity vs `origin/main`) | PASS (or graceful skip off-git) — baseline only SHRANK, never grew |
| TC-P36-034 | A synthetic NEW raw-`gh` line injected into a wrapper file (not baselined, not under `providers/`) | Check 1 FAILs LOUD naming the exact file:line (the guard still trips on regression — this migration does not weaken it) |

## GitLab host-API token class unaffected (Check 5/6 regression guard)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-040 | `check-provider-cutover.sh` Check 5 (no raw `glab` outside `providers/`) against the new `providers/prompts-gitlab.sh` | PASS — the file lives under `providers/`, categorically excluded from Check 5's scan |
| TC-P36-041 | `check-provider-cutover.sh` Check 6 (no `/api/v4` curl outside `providers/lib-gitlab-transport.sh`) against `providers/prompts-gitlab.sh`'s example curl lines (agent-facing PROSE inside printf templates, never executed) | PASS — `providers/prompts-gitlab.sh` added to Check 6's exclusion list alongside `providers/lib-gitlab-transport.sh` (a string literal an agent may choose to run is not the executable bypass Check 6 targets) |

## Full guard green (AC4)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-050 | `bash check-provider-cutover.sh` against the full migrated tree (Checks 1–6) | `cutover-guard: PASS` |

## Docs (R6, AC5)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-060 | `docs/pipeline/provider-spec.md` has a `§prompts` anchor documenting the helper, the key list, the API-neutral default, and a pointer to the golden test | present |
| TC-P36-061 | `docs/pipeline/dev-agent-flow.md` notes that the agent-facing prompt is fragment-rendered | present |
| TC-P36-062 | `docs/pipeline/review-agent-flow.md` notes that the agent-facing prompt is fragment-rendered | present |
| TC-P36-063 | No new `INV-NN` heading added; if review insists on one, the change is appended to `INV-91`'s migration log instead | no new heading; INV-91 migration-log entry present |

## Out-of-scope residue named (R7, AC6)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-P36-070 | `hooks/block-push-to-main.sh`'s `` `gh pr create` `` guidance string + skill markdown mentions of `gh` | named as known residue in the PR body with a follow-up issue link — NOT touched by this PR (out of the checker's tree) |
