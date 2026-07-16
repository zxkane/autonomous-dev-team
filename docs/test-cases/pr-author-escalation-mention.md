# Test Cases — PR-author escalation mention (issue #495)

Resolve a responsible HUMAN per PR (author with mandatory bot-detection +
`HUMAN_ESCALATION_LOGIN` fallback) instead of blasting `@${REPO_OWNER}` on
every PR-scoped escalation comment. Adds `author` to the pr_view-only §3.2.1
vocabulary on both providers (parity-pinned: `chp_pr_list` /
`chp_find_pr_for_issue` keep rejecting it on both hosts).

Test runner: `bash tests/unit/test-pr-author-escalation-mention.sh` (auto-
discovered by `tests/run-unit-tests.sh`'s `test-*.sh` glob). GitHub/GitLab
provider vocabulary parity is additionally pinned by
`tests/provider-conformance/run-provider-conformance.sh`.

## `author` field — pr_view-only vocabulary (R1)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PAEM-001 | `chp_pr_view <pr> author` (GitHub, stub returns `{"author":{"login":"alice"}}`) | `{"author":"alice"}`, rc 0 |
| TC-PAEM-002 | `chp_pr_view <pr> author` (GitHub, stub returns `{"author":null}`) | `{"author":null}`, rc 0 (key present, null value) |
| TC-PAEM-003 | `chp_pr_list open author` (GitHub) | rc 2, loud stderr naming `author` |
| TC-PAEM-004 | `chp_find_pr_for_issue <n> author` (GitHub) | rc 2, loud stderr naming `author` |
| TC-PAEM-005 | `chp_pr_view <pr> author` (GitLab, stub MR view returns `{"iid":42,"author":{"username":"bob"},"state":"opened"}`) | `{"author":"bob"}`, rc 0 |
| TC-PAEM-006 | `chp_pr_list open author` (GitLab) | rc 2, loud stderr naming `author` |
| TC-PAEM-007 | `chp_gitlab_find_pr_for_issue <n> author` (GitLab) | rc 2, loud stderr naming `author` |
| TC-PAEM-008 | `chp_pr_view <pr> bogusField` (both providers) — unknown field still rejected, no gate regression | rc 2, loud stderr, no HTTP/gh call |
| TC-PAEM-009 | `chp_pr_view <pr> author,number` (both providers) | both keys present, `author` correctly flattened from the login/username object |

## Resolver `resolve_pr_author_mention` — bot-detection + fallback chain (R2)

`lib-review-resolve-author.sh`. Always rc 0; exactly one `@<token>` on
stdout; diagnostics only on stderr.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PAEM-010 | `chp_pr_view` returns a human author (`alice`) | `@alice`, rc 0 |
| TC-PAEM-011 | Author matches `^app/` (e.g. `app/my-dev-bot`) | fallback token, rc 0 |
| TC-PAEM-012 | Author matches `\[bot\]$` (e.g. `my-claw[bot]`) | fallback token, rc 0 |
| TC-PAEM-013 | Author matches the GitLab service-account pattern `^(project\|group)_[0-9]+_bot(_[a-z0-9]+)?$` | fallback token, rc 0 |
| TC-PAEM-014 | Author exactly equals `$BOT_LOGIN` (non-empty, arbitrary display name) | fallback token, rc 0 |
| TC-PAEM-014b–d | Author exactly equals `$DEV_BOT_LOGIN` (the dispatcher-side counterpart to `BOT_LOGIN`, review finding #1); `DEV_BOT_LOGIN` set but author differs (human still wins); `DEV_BOT_LOGIN` unset — a plain-login bot author is NOT caught (documented gap) | `.014b` fallback token; `.014c` `@<human-login>`; `.014d` `@<plain-bot-login>` (unmitigated without the conf var) |
| TC-PAEM-015 | A human login containing the substring "bot" (e.g. `abbot`, `robert`) is NOT misclassified | `@abbot` / `@robert` (real author, NOT the fallback) |
| TC-PAEM-016 | Author is `null` | fallback token, rc 0 |
| TC-PAEM-017 | Author is empty string | fallback token, rc 0 |
| TC-PAEM-018 | `chp_pr_view` fails (non-zero rc) | fallback token, rc 0 |
| TC-PAEM-019 | `chp_pr_view` returns malformed (non-JSON-object) output | fallback token, rc 0 |
| TC-PAEM-020 | PR arg is non-numeric (e.g. `abc`) | fallback token, rc 0, NO `chp_pr_view` call |
| TC-PAEM-021 | PR arg is empty | fallback token, rc 0, NO `chp_pr_view` call |
| TC-PAEM-022 | `HUMAN_ESCALATION_LOGIN` set + bot author | `@$HUMAN_ESCALATION_LOGIN` (NOT `@$REPO_OWNER`) |
| TC-PAEM-023 | `HUMAN_ESCALATION_LOGIN` unset + bot author | `@$REPO_OWNER` |
| TC-PAEM-024 | `HUMAN_ESCALATION_LOGIN` set + human author | `@<human-login>` (human author still wins over the escalation login) |
| TC-PAEM-025 | Every row above (010–023) emits EXACTLY ONE `@`-prefixed token, no extra whitespace/newlines | single-token stdout contract holds under every row |
| TC-PAEM-026 | The function is called under `set -euo pipefail` (a caller sourcing this lib with strict mode active) — every fallback path | function itself never aborts the caller; rc always 0 |

## Call-site conversion (R3)

Source-shape assertions (grep the migrated line, fixed-string) against
`lib-dispatch.sh` and `autonomous-review.sh`.

### Converted sites (PR-scoped stall/escalation → `resolve_pr_author_mention`)

| ID | Site | Expected |
|----|------|----------|
| TC-PAEM-030 | `lib-dispatch.sh` INV-92 PR-metadata-403 stall report | calls `resolve_pr_author_mention "$_np_pr_number"`, NOT a bare `@${REPO_OWNER}` |
| TC-PAEM-031 | `lib-dispatch.sh` INV-85 no-progress stall report | calls `resolve_pr_author_mention "$_np_pr_number"` |
| TC-PAEM-032 | `lib-dispatch.sh` INV-92 non-actionable stall report | calls `resolve_pr_author_mention "$_np_pr_number"` |
| TC-PAEM-033 | `lib-dispatch.sh` INV-105 convergence-breaker report | calls `resolve_pr_author_mention "$_np_pr_number"` |
| TC-PAEM-034 | `lib-dispatch.sh` `_same_head_verdict_aware_recovery`'s three FAIL branches (INV-92 non-actionable, non-substantive budget-spent, self-heal/crash budget-spent) | all three call `resolve_pr_author_mention "$pr_num"` (the helper's new 5th positional) |
| TC-PAEM-035 | `autonomous-review.sh` INV-127 round-cap report | calls `resolve_pr_author_mention "$PR_NUMBER"` |
| TC-PAEM-036 | `autonomous-review.sh` [#453] same-HEAD E2E-gate breaker report | calls `resolve_pr_author_mention "$PR_NUMBER"` |
| TC-PAEM-037 | End-to-end: INV-85 no-progress path, bot-authored PR | comment body contains the fallback token, NOT the bot's login |
| TC-PAEM-038 | End-to-end: INV-85 no-progress path, human-authored PR | comment body contains `@<human-login>` |
| TC-PAEM-RT-001–003 | Integration (review finding #3, `test-handle-completed-session-routing.sh`): `handle_completed_session_routing` driven end-to-end through the REAL (unmocked) `resolve_pr_author_mention` on the INV-85 Branch B (no-progress) path — human author; bot author with `HUMAN_ESCALATION_LOGIN` unset; bot author with `HUMAN_ESCALATION_LOGIN` set | `.001` comment mentions `@alice`, never `@$REPO_OWNER`; `.002` comment mentions `@$REPO_OWNER`, never the bot login; `.003` comment mentions `@$HUMAN_ESCALATION_LOGIN`, never `@$REPO_OWNER` |

### Maintainer-target sites (unchanged target — never the PR author)

| ID | Site | Expected |
|----|------|----------|
| TC-PAEM-040 | `autonomous-review.sh` approval-failed fallback notice | mentions `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}` — NEVER calls `resolve_pr_author_mention` (a PR author cannot approve their own PR) |
| TC-PAEM-041 | `autonomous-review.sh` no-auto-close "please review and merge" notice | mentions `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}` — NEVER calls `resolve_pr_author_mention` |

### Operator-target sites (no PR guaranteed — variable substitution only)

| ID | Site | Expected |
|----|------|----------|
| TC-PAEM-050 | `lib-dispatch.sh` MAX_RETRIES stall notice | mentions `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}`; does **NOT** call `resolve_pr_author_mention` (can fire with zero PRs) |
| TC-PAEM-051 | `lib-dispatch.sh` non-substantive flip-cap notice | mentions `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}`, no resolver call |
| TC-PAEM-052 | `lib-dispatch.sh` API-rejection warning (no-progress marker post failure) | mentions `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}`, no resolver call |
| TC-PAEM-053 | `lib-dispatch.sh` liveness bookkeeping-marker warning | mentions `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}`, no resolver call |
| TC-PAEM-054 | `lib-dispatch.sh` liveness tier-1 notice | mentions `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}`, no resolver call |
| TC-PAEM-055 | `lib-dispatch.sh` class-level park backstop notice | mentions `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}`, no resolver call |

### Never-touch (prompt text, not comments)

| ID | Site | Expected |
|----|------|----------|
| TC-PAEM-060 | `autonomous-review.sh` `build_review_prompt`'s Step 0.5 requirement-drift instruction (inside the prompt heredoc) | byte-unchanged: `@${REPO_OWNER}` literal, untouched by this issue |

### No occurrences in `dispatcher-tick.sh`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PAEM-070 | `grep -c '@\${REPO_OWNER}' dispatcher-tick.sh` | 0 (confirmed zero sites in this file per the issue's enumeration) |

## Multi-project inline-block propagation (review finding #2)

`tests/unit/test-multi-tick-inline-projects.sh`. An inline (`remote-aws-ssm`)
`dispatcher.conf` project runs `dispatcher-tick.sh` in a subshell that only
sees vars `dispatcher-multi-tick.sh::tick_inline_project` explicitly exports —
unlike a local path-entry project, which sources its `autonomous.conf`
directly and sees everything.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PAEM-130 | Inline block declares `HUMAN_ESCALATION_LOGIN`/`DEV_BOT_LOGIN` | both exported into the `dispatcher-tick.sh` subshell env |
| TC-PAEM-131 | Inline block omits both keys | both stay unset in the subshell (byte-identical default — falls back to `REPO_OWNER`, no `DEV_BOT_LOGIN` classification) |

## Conformance (parity pin)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PAEM-080 | `run-provider-conformance.sh` `chp_pr_view` case exercises `author` alongside the existing 14-member fixture | passes; `author` present when requested |
| TC-PAEM-081 | `run-provider-conformance.sh` `chp_pr_list` / `chp_find_pr_for_issue` cases assert `author` is REJECTED on both providers | rc 2 on both GitHub and GitLab axes |
| TC-PAEM-082 | `coverage.conf` `chp_pr_view=asserted` unchanged | still `asserted` |

## E2E

Not applicable — comment-body targeting only, no new user-facing surface to
drive end-to-end.
