# Test cases — issue #331: `itp_transition_state` CSV multi-remove + 4 label-flip migration

Mandatory TDD; full suite under `env -u PROJECT_DIR`. New unit file:
`tests/unit/test-itp-transition-variadic.sh` (`TC-ITV-NNN`). Spec-gate / cutover assertions also
extend the existing `tests/unit/test-spec-drift.sh` and `tests/unit/test-provider-cutover.sh`
real-repo passes (they reconcile the live tree — migrating + re-anchoring keeps them green).

## Leaf golden-trace (CSV semantics)

| ID | Scenario | Expected argv |
|---|---|---|
| TC-ITV-001 | **Backward-compat single-label** `itp_github_transition_state 42 reviewing approved` | `issue edit 42 --repo $REPO --remove-label reviewing --add-label approved` (byte-identical to today) |
| TC-ITV-002 | **CSV multi-remove + single add** `… 42 "in-progress,pending-dev" "pending-review"` | two `--remove-label` (in-progress, pending-dev) + one `--add-label pending-review`, in order |
| TC-ITV-003 | **CSV multi-remove, empty add** `… 42 "reviewing,autonomous" ""` | two `--remove-label`, NO `--add-label` (empty-side omitted) |
| TC-ITV-004 | **Empty members dropped** `… 42 "in-progress,,pending-dev" ""` | two `--remove-label` (empty member between the commas dropped) |
| TC-ITV-005 | **Empty REMOVE, CSV add** `… 42 "" "a,b"` | NO `--remove-label`, two `--add-label` (a, b) |
| TC-ITV-006 | **Empty both** `… 42 "" ""` | bare `issue edit 42 --repo $REPO` (no flags) — unchanged |
| TC-ITV-007 | **Comma-as-separator precondition** `… 42 "x,y" ""` splits into two members `x` `y` (pins the documented "comma = member separator" contract; a label that itself contained a comma WOULD split — the documented unsupported case) | two `--remove-label x` `--remove-label y` |

## Shim routing / backward-compat at the public verb

| ID | Scenario | Expected |
|---|---|---|
| TC-ITV-010 | `itp_transition_state` (shim) with single-label routes to `itp_github_transition_state` byte-identically | `--remove-label reviewing --add-label approved` |
| TC-ITV-011 | 17 existing 3-positional single-label callers unaffected — spot-check the `label_swap` delegation path (`itp_transition_state "$n" "pending-dev" "pending-review"`) | single remove + single add |

## Per-site migration (source-shape + fail-safe framing preservation) — [P1]

| ID | Scenario | Assertion |
|---|---|---|
| TC-ITV-020 | **A1 dev:835** migrated | `autonomous-dev.sh` block has `itp_transition_state "$ISSUE_NUMBER" "in-progress,pending-dev" "pending-review"` AND the `\|\| log "WARNING: Failed to update issue labels"` framing survives on the same logical call |
| TC-ITV-021 | **A2 review:3466** migrated | `autonomous-review.sh` has `itp_transition_state "$ISSUE_NUMBER" "reviewing,autonomous" "approved"` AND `2>/dev/null \|\| true` framing survives |
| TC-ITV-022 | **A3 hygiene_strip** migrated | `lib-dispatch.sh::hygiene_strip_residual_labels` builds the CSV from `$stripped` (e.g. `tr ' ' ','`) and calls `itp_transition_state … ""` (no add); the `_has_terminal_label` prefilter + `[[ -z "$stripped" ]]` early-return + `echo "$stripped"` return all preserved |
| TC-ITV-023 | **B review:3552** migrated | `autonomous-review.sh` has `if ! _edit_err=$(itp_transition_state "$ISSUE_NUMBER" "reviewing" "pending-dev" 2>&1 >/dev/null); then` — the stderr-capture framing preserved |

## hygiene_strip behavioral (atomic, early-return) — [P3]

| ID | Scenario | Assertion |
|---|---|---|
| TC-ITV-030 (≡ extends TC-HYG-006) | already-clean issue (no transitional labels) | `hygiene_strip_residual_labels` early-returns; **ZERO** `itp_transition_state` calls (no no-op `gh issue edit` with zero `--remove-label`) |
| TC-ITV-031 | terminal+transitional issue with N residual labels | exactly one `itp_transition_state` call whose REMOVE CSV is the sorted/space→comma `$stripped` set; echoes `$stripped` unchanged |
| TC-ITV-032 | non-terminal issue (defensive `_has_terminal_label` miss) | early-return, ZERO verb calls (TC-HYG-006 defensive path) |

## Spec-gate C.3 re-anchor (AC3) — [P1, RED-without-the-reanchor]

| ID | Scenario | Assertion |
|---|---|---|
| TC-ITV-040 | after migration + re-anchored `spec-codesite-map.json`, `check-spec-drift.sh` passes Check C.3 against the real tree | rc=0, no `code-site for …` errors |
| TC-ITV-041 | **RED-without-reanchor** — the 3 re-anchored `code_sites` entries (`dev-trap-success-pr`, `review-pass-merged`, `review-no-pr`) point at the migrated anchors, NOT the raw `gh issue edit` literals | assert each entry's `anchor` is the migrated literal AND is NOT one of `--add-label "pending-review"` / `--remove-label "autonomous"` / `--remove-label "reviewing"` (test FAILS if the map still lists the raw literals) |

## Source-shape / baseline (AC4)

| ID | Scenario | Assertion |
|---|---|---|
| TC-ITV-050 | zero raw `gh issue edit` at the 4 migrated sites | `grep -c 'gh issue edit'` at dev:835 / review:3466 / review:3552 / lib-dispatch hygiene == 0 (the migrated forms route through the verb) |
| TC-ITV-051 | baseline shrank by 4 | the 4 specific `(file, content)` signatures are absent (asserted directly, robust to the absolute count drifting under concurrent #296 PRs); `check-provider-cutover.sh` (INV-91) green |

## INV + triage marker (AC5 / common)

| ID | Scenario | Assertion |
|---|---|---|
| TC-ITV-060 | new INV heading carries the `_Triage (issue #236):` marker within 2 lines | `test-spec-drift.sh::TC-SPEC-GATE-040/041` stays green (no untagged INV heading) |

## E2E
No new E2E — label transitions are internal; the dispatcher/review label-flip paths exercise the
migrated verb in production. (Issue: "No new E2E.")
