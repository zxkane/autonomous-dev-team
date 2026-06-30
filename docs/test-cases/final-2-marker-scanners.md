# Test cases — #321 final-2 comment-scanner migration behind `itp_list_comments`

ID format: `TC-FINAL2-NNN`. Driven by `tests/unit/test-final2-marker-scanners.sh`
(plus the retargeted `tests/unit/test-verdict-artifact.sh::TC-OBS-271-12`).

Run the FULL suite with `env -u PROJECT_DIR` for CI parity (an exported `PROJECT_DIR`
makes lib tests load the live `autonomous.conf`).

## S2 golden parity — `_fetch_agent_verdict_body`

The tests drive the **REAL** `_fetch_agent_verdict_body` (sourced from `lib-review-poll.sh`)
and stub `itp_list_comments` to emit the [INV-90] normalized array
`[{id, author, authorKind, body, createdAt}]`. They assert on the SELECTED BODY (or empty).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-FINAL2-001 | (a) matching verdict, newest-wins — two PASSED comments, later `createdAt` | the later body is returned |
| TC-FINAL2-002 | (b) wrong-agent excluded — comment is `Review Agent: other` | EMPTY |
| TC-FINAL2-003 | (c) before-window excluded — `createdAt` < `WRAPPER_START_TS` | EMPTY |
| TC-FINAL2-004 | (d) wrong-author excluded — `BOT_LOGIN` set, comment `author` ≠ `BOT_LOGIN` | EMPTY |
| TC-FINAL2-005 | (e) BOT_LOGIN-empty session-id fallback — `BOT_LOGIN=""`, comment body carries `Review Session: <sid>` | matching body returned; a comment with a DIFFERENT `<sid>` is excluded |
| TC-FINAL2-006 | (f) Unicode-fold counterexample — body `Review PAſSED` (U+017F long-s) | NOT selected (RE2 parity); a sibling body `review passed` (lowercase ASCII) IS selected |
| TC-FINAL2-007 | (g) no-match returns EMPTY — zero matching comments | EMPTY (zero bytes, NOT the literal string `null`) — the `// empty` guard |
| TC-FINAL2-008 | (h) same-second `.id` tiebreak — two matching verdicts, same `createdAt`, different `.id` + different verdict class | the higher-`.id` (newest) body wins deterministically |
| TC-FINAL2-009 | (i) C-locale fold — a `Review FAILED` verdict still matches when the helper runs under `LC_ALL=tr_TR.UTF-8` (Turkish dotless-`ı` regression guard on the `I` in FAILED) | matching body returned |
| TC-FINAL2-010 | (j) empty `_VERDICT_RE` fail-CLOSED — `_VERDICT_RE` unset + an auth+agent-matching NON-verdict comment | EMPTY (the `[[ -z "$_vre_lc" ]] && return 0` guard; without it `test("")` matches everything → fail-OPEN) |

## S1 idempotency — `dispatcher-tick.sh` INV-12 PTL scanner

The tests stub `itp_list_comments` + `itp_post_comment` and drive the migrated marker-count
guard logic (extracted shape) to assert the post is gated correctly.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-FINAL2-020 | array ALREADY contains the `notice_marker` (count ≥ 1) | `itp_post_comment` NOT called |
| TC-FINAL2-021 | array WITHOUT the marker (count 0) | `itp_post_comment` called once |
| TC-FINAL2-022 | fetch error / empty (`itp_list_comments` returns nothing) | `itp_post_comment` NOT called (fail-closed) |

## TC-OBS-271-12 retarget (`tests/unit/test-verdict-artifact.sh`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-OBS-271-12 | observe-loop comment branch resolves a comment-only slot via the REAL `_fetch_agent_verdict_body`, with the stub re-pointed from the `gh` BINARY to `itp_list_comments` (emitting the normalized array). Asserts on the SELECTED BODY (not just the gate) — a gate-only assertion over one happy-path fixture is vacuous-green; here we assert the real selector returns the matching verdict body, with a one-line comment delegating the full selector-discrimination matrix to the TC-FINAL2 golden-parity tests. | the matching verdict body is selected → `_all_first_verdicts_resolved` true |

## Source-shape regression guards (anti-drift)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-FINAL2-030 | `grep -c 'gh issue view .*--json comments' lib-review-poll.sh` | `== 0` |
| TC-FINAL2-031 | `grep -c 'gh issue view .*--json comments' dispatcher-tick.sh` | drops by exactly 1 vs `origin/main` (the timeline `gh api` survivor stays) → `== 0` (the comments-scanner was the only one; timeline uses `gh api`) |
| TC-FINAL2-032 | `grep -c 'itp_list_comments' lib-review-poll.sh` | `>= 1` (the migrated form present) |
| TC-FINAL2-033 | `grep -c 'itp_list_comments' dispatcher-tick.sh` | `>= 1` (the migrated S1 form present, in addition to any pre-existing dedup-read uses) |
| TC-FINAL2-034 | the lazy self-source guard token `declare -F itp_list_comments` present in `lib-review-poll.sh` | found |
| TC-FINAL2-035 | the four S2 fix tokens present in `_fetch_agent_verdict_body`'s block: `LC_ALL=C`, `ascii_downcase`, `// empty`, `[[ -z "$_vre_lc" ]] && return 0` | all four found |
| TC-FINAL2-036 | the stable-sort tiebreak `sort_by(.createdAt // "", .id // 0)` present | found |

## Cutover-baseline delta (mechanical)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-FINAL2-040 | the two migrated wire-form strings — `if gh issue view "$issue_num" --repo "$REPO" --json comments \` and `gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \` — are ABSENT from `cutover-baseline.json` | both absent |
| TC-FINAL2-041 | total survivor occurrence count == prior (`origin/main`) − 2 | exact delta −2 (catches an accidental regeneration dropping an UNRELATED survivor on the same branch — a visual diff misses this) |
| TC-FINAL2-042 | the `dispatcher-tick.sh` timeline `gh api …/timeline` baseline entry STILL present | present (out of scope, separate `itp_label_event_ts` item) |

## AC mapping

- **AC1** ⇐ TC-FINAL2-001..010 (the golden-parity matrix)
- **AC2** ⇐ TC-FINAL2-007, 010 (S2 fail-closed) + TC-FINAL2-022 (S1 fail-closed)
- **AC3** ⇐ TC-FINAL2-030..036 (source-shape pins)
- **AC4** ⇐ TC-FINAL2-040..042 (baseline delta, mechanical) + `check-provider-cutover.sh` (INV-91)
- **AC5** ⇐ full existing unit suite green under `env -u PROJECT_DIR`
- **AC6** ⇐ pipeline-doc updates (review-agent-flow, dispatcher-flow, invariants INV-90 stable-sort
  MUST, provider-spec §3.3) + `check-spec-drift.sh`

## E2E

Covered by the existing review-wrapper E2E lane (verdict detection exercises
`_fetch_agent_verdict_body`). No new E2E flow; the unit golden-parity matrix is the primary
behavior-equivalence evidence. S1/S2 are internal helpers with no UI surface.
