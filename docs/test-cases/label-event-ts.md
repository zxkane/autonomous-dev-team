# Test Cases — `itp_label_event_ts` (#323)

IDs: `TC-LABELTS-NNN`. Covers the leaf-golden matrix, caller wiring, the
leaf-absent / guard path, and the injection-safety cases.

> Run: `env -u PROJECT_DIR bash tests/unit/test-label-event-ts.sh`
> (caller-wiring + source-shape are in the same file; the #321 coupling flip is
> in `tests/unit/test-final2-marker-scanners.sh`.)

## Leaf golden — `itp_github_label_event_ts ISSUE LABEL` (stub the `gh` BINARY)

A `gh` BINARY stub on `PATH` returns a fixed timeline fixture (and records the
exact `--jq` program). The leaf is sourced from `providers/itp-github.sh`.

| ID | Scenario | Input | Expected |
|----|----------|-------|----------|
| TC-LABELTS-001 | (a) one labeled event for LABEL | timeline with 1 `labeled`/`autonomous` event | its `created_at` |
| TC-LABELTS-002 | (b) multiple labeled events for LABEL | 2 `labeled`/`autonomous` events | the FIRST (`.[0].created_at`) |
| TC-LABELTS-003 | (c) labeled events for a DIFFERENT label | only `labeled`/`bug` | empty |
| TC-LABELTS-004 | (d) no labeled event at all | timeline with no `labeled` | empty |
| TC-LABELTS-005 | (e) `gh` non-zero exit | stub exits 1 | empty (fail-soft, `\|\| true`) |
| TC-LABELTS-006 | (f) injection — selector NOT widened | LABEL=`autonomous" or .label.name == "bug`, timeline has ONLY a `bug` event | empty (NOT the bug `created_at`) |
| TC-LABELTS-007 | (f) injection — quote-bearing valid label, no jq syntax error | LABEL=`release"v2` | empty, and stderr has NO `jq: error: syntax error` |
| TC-LABELTS-008 | (g) source uses `--arg lbl` (NOT `--arg label`) | grep `providers/itp-github.sh` | `--arg lbl` present, `--arg label` absent (jq-1.6 reserves `label`) |
| TC-LABELTS-009 | argv-equivalence for `LABEL=autonomous` | recorded `--jq` program | equals today's inline selector `map(select(.event == "labeled" and .label.name == "autonomous")) \| (.[0].created_at // empty)`, against `repos/${REPO}/issues/<n>/timeline` |
| TC-LABELTS-010 | malformed/non-array gh response | stub echoes `{}` | empty (`map()` errors → swallowed by `2>/dev/null` → `\|\| true`) |

## Routing — shim → leaf

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LABELTS-020 | `itp_label_event_ts` routes to `itp_github_label_event_ts` under default `ISSUE_PROVIDER` | issue + label forwarded verbatim |
| TC-LABELTS-021 | shim source-shape is the bare `itp_${ISSUE_PROVIDER}_label_event_ts "$@"` (matches the 13 existing shims) | present in `lib-issue-provider.sh` |

## Caller wiring + leaf-absent / guard

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LABELTS-030 | migrated site calls `itp_label_event_ts "$issue_num" "autonomous"` (NOT raw `gh api`) | source pin in `dispatcher-tick.sh` |
| TC-LABELTS-031 | `labeled_at` present → `metrics_emit issue_labeled issue=N labeled_at=<ts>` | the snippet emits WITH `labeled_at` |
| TC-LABELTS-032 | `labeled_at` empty → `metrics_emit issue_labeled issue=N` (no `labeled_at`) | the snippet emits WITHOUT `labeled_at` |
| TC-LABELTS-033 | (i) leaf undefined → `declare -F` guard short-circuits, `itp_label_event_ts` NOT invoked | guard skips the verb |
| TC-LABELTS-034 | (ii) guard uses the BARE `itp_${ISSUE_PROVIDER}_label_event_ts`, IDENTICAL to the shim — **unset-`ISSUE_PROVIDER`** must NOT abort the tick; emits `issue_labeled` without `labeled_at` and continues | no `set -e` abort; rc 0 |
| TC-LABELTS-035 | the guard expression in `dispatcher-tick.sh` is byte-equal to the shim's bare dispatch expression | source pin: both are `itp_${ISSUE_PROVIDER}_label_event_ts` |

## Source-shape regression guards (+ #321 coupling, in test-final2-marker-scanners.sh)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LABELTS-040 | zero raw-`gh` survivors in `dispatcher-tick.sh` via the INV-91 `check-provider-cutover.sh` path | `dispatcher-tick.sh` has no entry in the cutover baseline; the committed repo reconciles (TC-CUTOVER-001) |
| TC-LABELTS-041 | new shim + leaf present in the seam files | `itp_label_event_ts` in `lib-issue-provider.sh`; `itp_github_label_event_ts` in `providers/itp-github.sh` |
| TC-LABELTS-042 | `cutover-baseline.json` dropped exactly the timeline entry (signatures −1) | the `gh api …/timeline` content is ABSENT from `surviving_sites` |
| TC-FINAL2-042 (flipped) | the timeline `gh api` survivor is now GONE (was "stays" in #321) — co-required with: (i) `gh api .*timeline` ABSENT from `dispatcher-tick.sh`; (ii) `itp_label_event_ts "$issue_num" "autonomous"` PRESENT; (iii) the specific timeline wire-string removed from the baseline | in `test-final2-marker-scanners.sh` |
| (stale-coupling fix) | `TC-FINAL2-041` (#321's "shrank by 2 vs origin/main") is no longer valid post-merge — replaced with the robust absence/presence pins (the established #308/#310 idiom) | in `test-final2-marker-scanners.sh` |

## E2E

No new E2E flow — internal observe-only helper, no UI. The leaf-golden +
caller-wiring units are the behavior-equivalence evidence; existing
review/dispatch E2E covers integration.
