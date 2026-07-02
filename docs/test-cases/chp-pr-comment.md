# Test Cases — `chp_pr_comment` (#329, #296 second-tier)

Mint a general CHP write primitive `chp_pr_comment PR [extra gh args…]` — the
PR-comment sibling of the shipped read primitives `chp_pr_view` / `chp_pr_list` —
and migrate all **7** raw PR-comment write sites (`autonomous-review.sh:3342,3538`
+ `lib-review-e2e.sh:344,380,387,402,580`) behind it. The leaf is a pure
BYTE-IDENTICAL passthrough that adds NO redirects of its own; every caller's
redirect/capture/gating framing stays caller-side.

Test runner: `bash tests/unit/test-chp-pr-comment.sh` (auto-discovered by the CI
`unit` job's `tests/unit/test-*.sh` glob). Run the FULL suite under
`env -u PROJECT_DIR` for CI parity.

## Golden leaf argv (AC1)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CPC-001 | `chp_pr_comment 42 --body B` with the REAL seam sourced (`CODE_HOST=github`) and a recording `gh` stub | stub observes `gh pr comment 42 --repo $REPO --body B` — argc 6, boundaries preserved (NUL-delimited capture) |
| TC-CPC-002 | The captured argv contains NO stray redirect tokens (`2>`, `>`, `2>&1`) | leaf adds none; every `2>`/`>` stays in the caller's source line, never in the leaf's argv |

## Per-site framing preserved (AC2)

Each of the 7 migrated call sites keeps its EXACT redirect/capture/gating form.
Source-shape assertions (grep the migrated line form, fixed-string).

| ID | Site | Migrated form (framing verbatim) |
|----|------|----------------------------------|
| TC-CPC-010 | `autonomous-review.sh:3342` | `chp_pr_comment "$PR_NUMBER" \` … `--body "Auto-merge failed: PR is CONFLICTING …" 2>/dev/null \|\| true` |
| TC-CPC-011 | `autonomous-review.sh:3538` | `if ! _comment_err=$(chp_pr_comment "$PR_NUMBER" \` … `2>&1 >/dev/null); then` (capture form) |
| TC-CPC-012 | `lib-review-e2e.sh:344` | `chp_pr_comment "$PR_NUMBER" \` … `2>/dev/null \|\| true` (pre-hook failure report) |
| TC-CPC-013 | `lib-review-e2e.sh:380` | `chp_pr_comment "$PR_NUMBER" --body "$evidence" 2>/dev/null \|\| rc=$?` (the ONLY gating site) |
| TC-CPC-014 | `lib-review-e2e.sh:387` | `chp_pr_comment "$PR_NUMBER" \` … `2>/dev/null \|\| true` (evidence-missing report) |
| TC-CPC-015 | `lib-review-e2e.sh:402` | `chp_pr_comment "$PR_NUMBER" \` … `2>/dev/null \|\| true` (hard-failure report) |
| TC-CPC-016 | `lib-review-e2e.sh:580` | `if chp_pr_comment "$PR_NUMBER" --body "$body" >/dev/null 2>&1; then` (INV-79 broker) |

## Self-guarding shim (AC3)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CPC-020 | `chp_pr_comment` invoked with the enabled provider defining NO `chp_${CODE_HOST}_pr_comment` leaf (degraded fixture) | WARN to stderr + `return 1`; NO `set -e` abort; matches the `chp_pr_view` / `chp_pr_list` self-guarding shape |
| TC-CPC-021 | A `\|\| true` caller site degrades on the leaf-absent `return 1` | the `2>/dev/null \|\| true` framing swallows the non-zero — wrapper fails-soft (no comment posted), no crash |

## Source-shape (AC4)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CPC-030 | Executable (non-comment) raw `gh pr comment` in `autonomous-review.sh` | 0 |
| TC-CPC-031 | Executable (non-comment) raw `gh pr comment` in `lib-review-e2e.sh` | 0 |
| TC-CPC-032 | New leaf `chp_github_pr_comment` present in `providers/chp-github.sh`; new shim `chp_pr_comment` present in `lib-code-host.sh` | both present |
| TC-CPC-033 | `chp_pr_comment` invocation count at the 7 migrated sites (2 in review, 5 in e2e) | review ×2, e2e ×5 |
| TC-CPC-034 | `cutover-baseline.json` no longer carries the 5 `gh pr comment` entries | absent (baseline 73 → 66, −7 occurrences) |
| TC-CPC-035 | `check-provider-cutover.sh` (INV-91) against the migrated tree | PASS |

## Docs (AC5)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CPC-040 | provider-spec.md prose: "two general read primitives" → updated to cover THREE (incl. `chp_pr_comment` as a self-guarding general primitive) | no stale "two general read primitives" claim |
| TC-CPC-041 | provider-spec.md mapping-appendix has a `chp_pr_comment` extraction row | present |
| TC-CPC-042 | invariants.md `chp_pr_comment` INV heading (INV-102, renumbered from INV-95, then INV-101, on successive rebases — main independently claimed INV-95 for #328, then INV-101 for #356/#363) + `_Triage (issue #236):` marker within 2 lines + Migration-log bullet | present (TC-SPEC-GATE-040/041 stay green) |

## E2E

No new E2E — internal write primitive. Existing review/E2E-report paths exercise it.
