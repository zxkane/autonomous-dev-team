# Test cases — `chp_reply_review_comment` (issue #327)

Tests live in `tests/unit/test-reply-review-comment.sh`. Run the full suite under
`env -u PROJECT_DIR`.

## Golden-trace (AC1) — byte-identical leaf argv

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-RRC-001` | `chp_github_reply_review_comment 5 2734892022 "Fixed in abc"` with `REPO=o/r` and a `gh` stub recording argv | argv (NUL-delimited) is exactly `api repos/o/r/pulls/5/comments -X POST -f body=Fixed in abc -F in_reply_to=2734892022 --jq {id: .id, url: .html_url}` |
| `TC-RRC-002` | leaf emits the `repos/$REPO/pulls/$PR/comments` endpoint with the caller-supplied `$REPO` slug | endpoint path = `repos/o/r/pulls/5/comments` (byte-identical to today's `repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments`) |
| `TC-RRC-003` | the `--jq '{id: .id, url: .html_url}'` projection is a fixed literal | argv carries the exact selector `{id: .id, url: .html_url}` verbatim |
| `TC-RRC-004` | body with spaces/special chars passed through `-f body=` | the body arg survives verbatim as one argv token |

## Dispatch routing

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-RRC-010` | source `lib-code-host.sh`, stub `chp_github_reply_review_comment`, call `chp_reply_review_comment 7 99 BODY` | the shim forwards `"$@"` to `chp_github_reply_review_comment 7 99 BODY` |

## Self-source isolation (AC2)

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-RRC-020` | run the REAL `reply-to-comments.sh` via a SYMLINK in a temp sandbox (no pre-sourced seam), `gh` stub on PATH; happy path | exit 0; the POST routes through the verb → emits the byte-identical `api repos/o/r/pulls/5/comments -X POST …` shape |
| `TC-RRC-021` | same sandbox, the verb is UNDEFINED (provider lib removed beside the symlink AND unreachable) — leaf-absent | script FAILs LOUD (names the unavailable verb), non-zero exit, NO raw `gh` POST executed (no silent GitHub fallback) |
| `TC-RRC-022` | sandbox happy path: the migrated `reply-to-comments.sh` self-sources the seam via `readlink -f` (the symlink dir holds no lib) and `chp_reply_review_comment` resolves | verb defined; POST observed |

## Source-shape (AC3)

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-RRC-030` | grep `reply-to-comments.sh` for raw `gh api …pulls/…/comments` | count == 0 |
| `TC-RRC-031` | `reply-to-comments.sh` calls `chp_reply_review_comment` | present |
| `TC-RRC-032` | `lib-code-host.sh` defines the `chp_reply_review_comment` shim; `providers/chp-github.sh` defines `chp_github_reply_review_comment` | both present |
| `TC-RRC-033a` | `cutover-baseline.json` no longer carries any `reply-to-comments.sh` POST signature | migration-robust: zero `reply-to-comments.sh` survivors |
| ~~`TC-RRC-033b`~~ | ~~cutover baseline total occurrences == \<absolute\>~~ | **REMOVED (#342)** — absolute totals move with every sibling #296 migration that shrinks the baseline, sending unrelated in-flight PRs red. No unique coverage: tree↔baseline reconciliation is Check 1 of `check-provider-cutover.sh` and shrink-only monotonicity is Check 4 (`--require-trusted-ref`), both strict in the CI `spec-drift` job. |
| ~~`TC-RRC-033c`~~ | ~~cutover baseline distinct signatures == \<absolute\>~~ | **REMOVED (#342)** — same rationale as 033b. Absolute baseline totals MUST NOT be pinned in per-migration tests. |

## Spec / invariant (AC4)

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-RRC-040` | the new `## INV-NN:` heading carries a `_Triage (issue #236): [machine-checked: tests/unit/test-reply-review-comment.sh]_` marker within 2 lines | `check-spec-drift.sh` green |
| `TC-RRC-041` | provider-spec.md §3.2 row migrated (the deferred `reply-to-comments.sh` row reflects the new verb) | spec row present |

## AC5

Full existing unit suite green under `env -u PROJECT_DIR` (no regression to the
sibling baseline-pin / source-shape tests).
