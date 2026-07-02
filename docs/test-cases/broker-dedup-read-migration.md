# Test Cases — INV-79 E2E-broker dedup read migration (#333)

Covers the migration of `lib-review-e2e.sh::_post_brokered_e2e_report`'s dedup
window-count read from raw `gh api …/comments` to the shipped `itp_list_comments` verb.

Test file: `tests/unit/test-broker-dedup-read-migration.sh`
Run: `env -u PROJECT_DIR bash tests/unit/test-broker-dedup-read-migration.sh`

Two complementary strategies (mirrors #332):
1. **Selector parity** — extract the live `jq -r '<EXPR>'` count selector from
   `lib-review-e2e.sh` and run it against synthetic NORMALIZED [INV-90] array fixtures;
   prove the migrated selector reproduces the raw-`gh-api` count for every golden case.
2. **Broker behavior** — source `_post_brokered_e2e_report` in isolation with stubbed
   `itp_list_comments` / `log` / `itp_*` / `gh`, and assert SKIP-vs-PROCEED end-to-end.
3. **Source-shape** — the raw `gh api` `:571` read is gone, the `itp_list_comments | jq`
   form is present, `| tail -n1` kept, `.createdAt` used, baseline −1, cutover green,
   and the `:486`/`:498` INV-46 reads STILL present + raw (negative scope assertion).

## AC1 — migrated selector reproduces the raw-gh-api dedup count (selector parity)

| ID | Scenario | Fixture | Expected count |
|----|----------|---------|----------------|
| TC-BRK-001 | one in-window `## E2E Verification Report` comment | 1 in-window report | `1` |
| TC-BRK-002 | only a before-window report (createdAt < `WRAPPER_START_TS`) | 1 out-of-window report | `0` |
| TC-BRK-003 | in-window comment NOT containing the marker | 1 in-window non-report | `0` |
| TC-BRK-004 | empty array `[]` | no comments | `0` |
| TC-BRK-005 | two in-window reports + one out-of-window report + chatter | mixed | `2` |
| TC-BRK-006 | report body CONTAINS marker mid-body (not at start) — `contains` still matches (substring semantics, NOT `startswith`) | 1 in-window report w/ marker mid-body | `1` |

## AC2 — no regex introduced; `.created_at`→`.createdAt`; `tail -n1` kept (parity)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-BRK-PARITY-001 | live selector uses `contains(` and `>=`, NEVER `test(` | selector is `contains`/`>=`, no `test()` |
| TC-BRK-PARITY-002 | live selector references `.createdAt` (normalized), NOT `.created_at` | `.createdAt` present, `.created_at` absent in migrated read |
| TC-BRK-PARITY-003 | a body carrying non-ASCII + a `test()`-style metachar (`\b(?i)`) is still counted by literal `contains` (no Oniguruma fold) | count `1` |
| TC-BRK-TS-001 | **timestamp lexical-format equivalence** — using the REAL `gh issue view` createdAt format, a boundary comment exactly at `WRAPPER_START_TS` (in-window, `>=` is inclusive) and one one-second-before (out-of-window) classify identically under `.createdAt` as the raw `.created_at` would | in-window→counted, before-window→not counted |

## AC3 — source-shape: raw `:571` gone, verb form present, baseline −1 (source-shape)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-BRK-SRC-001 | raw `_existing=$(gh api …/issues/${PR_NUMBER}/comments` `:571` read removed | absent from `lib-review-e2e.sh` |
| TC-BRK-SRC-002 | migrated `_existing=$(itp_list_comments "$PR_NUMBER"` form present exactly once | count `1` |
| TC-BRK-SRC-003 | `cutover-baseline.json` no longer carries the `:571` `_existing=$(gh api …` entry; `check-provider-cutover.sh` ([INV-91]) PASSES | baseline −1 (exactly-one shrink), guard green |
| TC-BRK-SRC-004 | **negative scope** — `:486` (`_comment_id=$(gh api …/comments`) and `:498` (`_body=$(gh api …/issues/comments/`) INV-46 reads STILL present + raw | both present |

## AC4 — INV-79 broker dedup behavior unchanged (broker behavior, end-to-end)

`_post_brokered_e2e_report` sourced in isolation; `itp_list_comments` / `log` /
`gh` (pr comment) stubbed. Assert whether the brokered post fires.

| ID | Scenario | Stub return | Expected |
|----|----------|-------------|----------|
| TC-BRK-BEH-001 | in-window report exists → dedup SKIP | verb emits array w/ 1 in-window report | broker SKIPS (no `gh pr comment`), logs INV-79 skip |
| TC-BRK-BEH-002 | only before-window report → proceed | verb emits 1 out-of-window report | broker POSTS (`gh pr comment` fired) |
| TC-BRK-BEH-003 | in-window comment without marker → proceed | verb emits 1 in-window non-report | broker POSTS |
| TC-BRK-BEH-004 | verb returns `[]` (empty array) → proceed | verb emits `[]` | broker POSTS |
| TC-BRK-BEH-005 | **verb failure** — `itp_list_comments` exits NON-ZERO with EMPTY stdout → guard fails → proceed (best-effort, the actual failure mode, P2) | verb `return 1` + no stdout | broker POSTS |
| TC-BRK-BEH-006 | `WRAPPER_START_TS` unset → dedup block skipped entirely → proceed | (verb not consulted) | broker POSTS |

## AC5 — full existing unit suite green under `env -u PROJECT_DIR`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-BRK-SUITE | `for t in tests/unit/test-*.sh; do env -u PROJECT_DIR bash "$t"; done` | all green (no regression) |
| TC-BRK-SYNTAX | `bash -n lib-review-e2e.sh` | no syntax errors |

## E2E

No new E2E. The browser-E2E review lane exercises `_post_brokered_e2e_report` in
production; this is an internal best-effort dedup read.
