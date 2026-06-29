# Test cases — #296 B3+B4 (#308): CHP-read migration (`chp_pr_list`/`chp_pr_view`)

Proves the three byte-identical raw-`gh` read migrations are zero-behavior-change.
Surfaces: CI `unit` + `Spec Drift` + `Require-pipeline-docs`.

## The three migrated sites

| ID | Site | Verb |
|---|---|---|
| S1 | `lib-auth.sh` `drain_agent_pr_create` PR-existence read | `chp_pr_list` |
| S2 | `lib-auth.sh` `drain_agent_bot_triggers` PR-number read | `chp_pr_list` |
| S3 | `lib-review-e2e.sh` `_fetch_sha_evidence` SHA-evidence read | `chp_pr_view` |

## New test file: `tests/unit/test-issue-308-b3b4-chp-reads.sh`

### Golden trace — argument-boundary-preserving (AC2)

A recording `gh` stub writes argv **NUL-delimited** (one arg per record, NOT
space-joined), so a word-split or re-escaped selector FAILS the assertion.

| ID | Drives | Asserts |
|---|---|---|
| TC-308-GT-S1 | `drain_agent_pr_create` (scoping armed, no PR yet) | observed argv == `pr␞list␞--repo␞$REPO␞--state␞open␞--json␞body␞-q␞<verbatim existence selector>` (argc + each arg + verbatim selector) |
| TC-308-GT-S2 | `drain_agent_bot_triggers` (scoping armed, allowlist) | observed argv == `pr␞list␞--repo␞$REPO␞--state␞open␞--json␞number,body␞-q␞<verbatim number selector>` |
| TC-308-GT-S3 | `_fetch_sha_evidence` (no match) | observed argv == `pr␞view␞$PR_NUMBER␞--repo␞$REPO␞--json␞comments␞--jq␞<verbatim sha-match selector>` |
| TC-308-GT-SELECTOR | each site's selector | the captured selector arg is a SINGLE argv element (boundary preserved); a space-joined capture would have split it |

### Seam-reachability + observed-call (AC4)

Each migrated path's test sources the **real** `lib-code-host.sh` (so the
`chp_*` shim + `chp_github_*` leaf are live) and asserts the gh-stub OBSERVED the
`gh pr list`/`gh pr view` argv through the verb — proving the path was exercised,
not just reachable.

| ID | Asserts |
|---|---|
| TC-308-SEAM-S1 | with `lib-code-host.sh` sourced, `drain_agent_pr_create` routes its existence read through `chp_pr_list` → stub sees `gh pr list` |
| TC-308-SEAM-S3 | with `lib-code-host.sh` sourced, `_fetch_sha_evidence` routes through `chp_pr_view` → stub sees `gh pr view` |
| TC-308-FAILSOFT | **rationale guard**: with the verb UNDEFINED, the site fails-soft (`existing=0` / empty) and does NOT crash — so reachability-only is the wrong-reason pass the seam test rules out |

### Behavior-equivalence (AC, Testing Requirements)

| ID | Asserts |
|---|---|
| TC-308-EQ-EXISTS-FOUND | PR-found ⇒ `drain_agent_pr_create` returns early (no `gh pr create`) — same as pre-migration |
| TC-308-EQ-EXISTS-NONE | no PR ⇒ broker proceeds to create — same as pre-migration |
| TC-308-EQ-PRNUM | `drain_agent_bot_triggers` resolves the same PR number from the same selector |
| TC-308-EQ-EVIDENCE | `_fetch_sha_evidence` echoes the same SHA-matching body / empty as pre-migration |

### Source guards

| ID | Asserts |
|---|---|
| TC-308-SRC-AUTH | `lib-auth.sh` carries ZERO executable `gh pr list` (the two reads now `chp_pr_list`) |
| TC-308-SRC-E2E | `lib-review-e2e.sh` carries ZERO executable `gh pr view` (the read now `chp_pr_view`) |
| TC-308-SRC-NO-SELFSOURCE | `lib-review-e2e.sh` does NOT add a `lib-code-host.sh` self-source (production source graph unchanged) |

### AC7 — call-expression byte-identity premise

| ID | Asserts |
|---|---|
| TC-308-AC7-DEV-CREATE | `autonomous-dev.sh` calls `drain_agent_pr_create "$ISSUE_NUMBER" "$REPO"` |
| TC-308-AC7-DEV-BOT | `autonomous-dev.sh` calls `drain_agent_bot_triggers "$ISSUE_NUMBER" "$REPO" …` |
| TC-308-AC7-REVIEW-BOT | `autonomous-review.sh` calls `drain_agent_bot_triggers "$ISSUE_NUMBER" "$REPO" …` |

### AC6 — INV-91 Migration-log bullet (also pinned in `test-spec-drift.sh` as a `TC-SPEC-GATE`)

| ID | Asserts |
|---|---|
| TC-308-AC6-BULLET | `docs/pipeline/invariants.md` contains the exact `- #296 B3+B4 (#308): …` bullet |

## Updated existing fixtures (AC5)

| File | TC | Change |
|---|---|---|
| `tests/unit/test-token-split-234.sh` | TC-TOKEN-SPLIT-070 | `new_auth_sandbox` now copies `lib-code-host.sh` + `providers/` so the self-source defines `chp_pr_list`; the `gh` stub records `gh pr list` argv; new assert the existence read was OBSERVED through the verb |
| `tests/unit/test-autonomous-review-sequential-e2e.sh` | TC-SE2E-FETCH | the `_fetch_harness` sources `lib-code-host.sh` so `chp_pr_view` is live; new assert the stub OBSERVED `gh pr view` through the verb |

`tests/unit/test-e2e-mode-command.sh` is NOT touched (its selector assertions
stay byte-identically green — that path is not migrated by this PR).

## AC3 — baseline shrink

`scripts/providers/cutover-baseline.json` regenerated via
`bash check-provider-cutover.sh --generate-baseline`; diff is exactly the 3 lines
(2× `lib-auth.sh` `gh pr list`, 1× `lib-review-e2e.sh` `gh pr view`) removed —
79 → 76 surviving sigs. The named out-of-scope survivors remain.
