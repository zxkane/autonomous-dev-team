# Test Cases — `chp_count_reviews_by_login` (#324)

Test IDs: `TC-CRBL-NNN`. Surfaces:
- **Leaf golden matrix** — `tests/unit/test-count-reviews.sh` (stub the `gh` BINARY).
- **`missing_bot_reviews` wiring + leaf-absent/guard** — extends `tests/unit/test-token-split-234.sh`.
- **Source-shape / baseline-delta** — `tests/unit/test-count-reviews.sh`.

The full unit suite is run under `env -u PROJECT_DIR` for CI parity (the fail-safe behavior is
load-bearing and gates a PASS verdict).

## Leaf golden matrix — `chp_github_count_reviews_by_login REPO PR LOGIN`

| ID | Scenario | Expected |
|---|---|---|
| `TC-CRBL-001` | (a) one review by LOGIN, single page (`gh` stub → `1`) | `1` |
| `TC-CRBL-002` | (b) **multi-page [anti-vacuous-green]** — stub emits MULTIPLE lines (`printf '1\n2\n'`) to exercise the `awk` accumulator; stub also records its argv and the test asserts `--paginate` was RECEIVED | sums to `3` AND `--paginate` observed in argv |
| `TC-CRBL-003` | (c) reviews exist but by a DIFFERENT login (stub jq selector → `0`) | `0` |
| `TC-CRBL-004` | (d) no reviews at all (`gh` stub → `0`) | `0` |
| `TC-CRBL-005` | (e) `gh` exits non-zero with EMPTY stdout | `0` (fail-SAFE) |
| `TC-CRBL-006` | (f) **injection-safety** — login `x" or true or "y` | `0` (NOT a phantom count); no jq syntax error |
| `TC-CRBL-007` | (f') quote-bearing login does not abort / error | `0`, clean (no jq parse error on stderr) |
| `TC-CRBL-008` | (g) **source-of-truth** — the leaf keeps `--paginate` AND the `awk` sum | grep both present in `providers/chp-github.sh` |
| `TC-CRBL-009` | (h) **gh writes stdout THEN exits non-zero** (`printf '1\n'; exit 1`) — partial-pagination | leaf returns **`0`** (capture-check-sum closes the fail-open) |
| `TC-CRBL-010` | (i) **REPO threaded from arg** — a DIFFERENT global `$REPO` is set; the recorded URL must use the PASSED arg, not the global | recorded URL = `repos/<arg-repo>/pulls/<pr>/reviews` |
| `TC-CRBL-011` | normal `[bot]`-suffixed login (`github-actions[bot]`) encodes to `"github-actions[bot]"` and counts a matching review | `1` (count-equivalent to today's leaf) |

## `missing_bot_reviews` wiring + leaf-absent/guard (in `test-token-split-234.sh`)

| ID | Scenario | Expected |
|---|---|---|
| `TC-CRBL-020` | present-review case (CHP seam loaded; stub gh → a review by the bot login) → bot NOT listed | bot absent from output |
| `TC-CRBL-021` | no-review case (the existing `:841` TC, seam loaded; stub gh → 0) → bot listed MISSING | bot present in output |
| `TC-CRBL-022` | **leaf-absent under `set -euo pipefail`, (i) unset `CODE_HOST`** — bare guard skips → `count=0` → bot MISSING, NO abort | bot listed; subshell exit 0 (no `set -e` abort) |
| `TC-CRBL-023` | **leaf-absent under `set -euo pipefail`, (ii) `CODE_HOST` set to a provider sourced without this leaf** — same MISSING, NO abort | bot listed; subshell exit 0 |
| `TC-CRBL-024` | **guard expr-equality** — the caller's leaf-guard uses the BARE `chp_${CODE_HOST}_count_reviews_by_login` identical to the shim's dispatch (a `:-github` guard vs bare-shim diverges on unset `CODE_HOST` → abort) | source grep: caller guard == shim dispatch expr |

> The token-split stub harness runs `bash -c` WITHOUT `set -e`, so the leaf-absent cases MUST enable
> explicit `set -euo pipefail` in their subshell. If any path aborts the wrapper instead of returning
> the MISSING list, the whole [INV-79] reasoning collapses.

## Source-shape + baseline-delta (in `test-count-reviews.sh`)

| ID | Scenario | Expected |
|---|---|---|
| `TC-CRBL-030` | **primary assertion** — the 3 surviving `gh api …/reviews` lines in `lib-review-bots.sh` are the PROSE/heredoc ones (match the `COUNT=$(gh api` heredoc context), NOT a bare `grep -c` | exactly the 3 prose lines remain |
| `TC-CRBL-031` | the real leaf (`count=$(gh api … --paginate` caller form) is GONE from `lib-review-bots.sh` | absent |
| `TC-CRBL-032` | the migrated caller + new leaf REDACT any literal `gh api …/reviews` in their comments (use `` `gh` `` or "the reviews endpoint") so an explanatory comment doesn't self-trip the count (#316 footgun) | no literal `gh api …/reviews` in new comment lines |
| `TC-CRBL-033` | new shim `chp_count_reviews_by_login` present in `lib-code-host.sh`; new leaf `chp_github_count_reviews_by_login` present in `providers/chp-github.sh` | both present |
| `TC-CRBL-034` | **baseline-delta pin** — the migrated leaf wire-string ABSENT from `cutover-baseline.json`; the `COUNT=3` prose entry unchanged. The absolute total is deliberately NOT pinned here (#349/#342 precedent — it moves with every sibling #296 migration; `check-provider-cutover.sh` Check 1/Check 4 already guard it robustly) | leaf entry gone; prose entry intact |

## Acceptance Criteria mapping

- **AC1** → `TC-CRBL-001..011` (leaf golden, incl. multi-page sum, gh-stdout-then-fail→0, REPO-from-arg).
- **AC2** → `TC-CRBL-020/021` (wiring preserves MISSING + fail-safe).
- **AC3** → `TC-CRBL-022/023/024` (leaf/shim-absent + unset-`CODE_HOST` → MISSING, never aborts; guard expr == shim dispatch).
- **AC4** → `TC-CRBL-006/007` (injection-safe).
- **AC5** → `TC-CRBL-030..033` (source-shape — real leaf gone, 3 prose stay, no comment self-trip, shim/leaf present).
- **AC6** → `TC-CRBL-034` + `check-provider-cutover.sh` (INV-91): baseline shrinks by 1 (this PR's leaf), pinned mechanically (migration-robust, not an absolute total).
- **AC7** → provider-spec.md §3.2 row + INV-94 + review doc; `check-spec-drift.sh` passes.
- **AC8** → full unit suite green under `env -u PROJECT_DIR`.

## E2E

No new E2E flow (internal helper). The leaf-golden + wiring units are the behavior-equivalence evidence;
existing review-wrapper E2E covers integration.
