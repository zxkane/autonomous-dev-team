# Test Cases — TC-STAMPREAD-NNN: INV-46 stamp-path comment reads migration (#345)

Covers the migration of `lib-review-e2e.sh::_stamp_browser_evidence_marker`'s
id-lookup + body-fetch reads from two raw `gh api` calls to ONE shipped
`itp_list_comments` verb call (shape-equivalent, no new verb).

Test file: `tests/unit/test-autonomous-review-sequential-e2e.sh` (TC-SE2E-STAMP
section, extended in place — the function under test already lived there since
#182/#182-codex-review).
Run: `env -u PROJECT_DIR bash tests/unit/test-autonomous-review-sequential-e2e.sh`

## AC1 — newest-report selection (incl. same-second tie-break)

| ID | Scenario | Fixture | Expected |
|----|----------|---------|----------|
| TC-STAMPREAD-001 | a real report comment present | 1 in-window, BOT_LOGIN-authored report | stamp returns 0, PATCH fires |
| TC-STAMPREAD-002 (CORE REGRESSION) | no report comment at all | `[]` | stamp returns 1 (fail closed), no PATCH |
| TC-STAMPREAD-003 | already-stamped report (idempotent) | 1 report body already carrying the SHA marker | stamp returns 0, NO PATCH |
| TC-STAMPREAD-004 (tie-break, R3) | two candidate reports at the SAME `createdAt` second, different ids | id=10 v1, id=11 v2, same second | the HIGHER id (v2, later-inserted) is selected and stamped |

## AC2 — `WRAPPER_START_TS` boundary (`>=` inclusive)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-STAMPREAD-005 | a report `createdAt` EXACTLY equal to `WRAPPER_START_TS` | included (inclusive `>=`), stamp returns 0 |
| TC-STAMPREAD-006 | a report `createdAt` ONE SECOND BEFORE `WRAPPER_START_TS`, no other candidate | excluded, stamp returns 1 (fail closed) |

## AC3 — author predicate parity (vs the old `.user.login`-based `_author_jq`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-STAMPREAD-007 | `BOT_LOGIN` set, report authored by a DIFFERENT login | excluded (author predicate re-expressed over normalized `.author`), stamp returns 1 |
| TC-SE2E-STAMP-01 (existing) | `BOT_LOGIN` set, report authored by `BOT_LOGIN` | included, stamp returns 0 |

## AC4 — fail-closed on no-match / empty body; idempotent skip

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SE2E-STAMP-02 (existing) | `itp_list_comments` emits `[]` | stamp returns 1, no PATCH attempted |
| TC-SE2E-STAMP-03 (existing) | selected element's body already carries the SHA marker | stamp returns 0, no redundant PATCH |

## AC5 — source-shape (raw reads gone, verb form present, baseline shrinks by exactly 2)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SE2E-STAMP-07 (existing) | helper still routes the in-place EDIT through `itp_edit_comment` (unchanged from #283) | `itp_edit_comment ` present in lib |
| N/A (manual + CI) | raw `gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments" --paginate` and `gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${_comment_id}"` are GONE from `_stamp_browser_evidence_marker` | absent from `lib-review-e2e.sh` |
| N/A (manual + CI) | `cutover-baseline.json` no longer carries the two `lib-review-e2e.sh` `_comment_id=$(gh api …`/`_body=$(gh api …` entries | baseline shrinks by exactly 2 signatures (`--generate-baseline`); `check-provider-cutover.sh --require-trusted-ref` PASSES |
| N/A (cross-file regression) | `tests/unit/test-broker-dedup-read-migration.sh`'s TC-333-SRC-04/05b negative-scope assertions (which asserted these two reads STAY raw, out of #333's scope) | inverted to assert the reads are GONE — updated in the same PR |

## AC6 — full unit suite + spec-drift green

| ID | Scenario | Expected |
|----|----------|----------|
| N/A (CI) | `tests/unit/*.sh` loop | all pass |
| N/A (CI) | `check-spec-drift.sh` | PASS (no drift introduced) |
| N/A (CI) | `check-provider-cutover.sh --require-trusted-ref` | PASS (baseline only shrinks) |
