# Test Cases - pre-fan-out mergeability conflict routing (issue #540)

## Files Under Test

| File | Role |
|---|---|
| `skills/autonomous-dispatcher/scripts/lib-review-disposition.sh` | Strict disposition renderer/parser and newest routing evidence |
| `skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh` | Snapshot, polling, preflight, and canonical conflict routes |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | Preflight ordering and retained post-fan-out INV-44 gate |
| `skills/autonomous-dispatcher/scripts/lib-dispatch.sh` | Existing-PR disposition delegation |
| `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` | Mandatory rebase prompt and safe push/abort policy |

## Disposition Contract

| ID | Scenario | Expected |
|---|---|---|
| TC-E2E-REBASE-001 | Render conflict disposition for full lowercase head | Exact canonical whole-body marker |
| TC-E2E-REBASE-002 | Render mergeable-unknown disposition | Exact canonical marker with allow-listed result |
| TC-E2E-REBASE-003 | Uppercase full head | Normalized to lowercase |
| TC-E2E-REBASE-004 | Abbreviated/non-hex head or invalid result | Rejected |
| TC-E2E-REBASE-005 | Exact strict-self marker for current issue | Parsed |
| TC-E2E-REBASE-006 | Human-authored, quoted, malformed, trailing-text, or wrong-issue marker | Ignored |
| TC-E2E-REBASE-007 | Newest evidence is `Reviewed HEAD:` | Legacy reviewed head/result retained |
| TC-E2E-REBASE-008 | Newer disposition follows reviewed-head evidence | Disposition wins by `(createdAt,id)` |
| TC-E2E-REBASE-009 | Disposition belongs to an older head | Does not match the current head |

## Preflight Decision Matrix

| ID | Scenario | Expected |
|---|---|---|
| TC-E2E-REBASE-010 | Stable `MERGEABLE` | Continue; no disposition/write/transition |
| TC-E2E-REBASE-011 | Stable `CONFLICTING` | Canonical conflict route; zero E2E/fan-out |
| TC-E2E-REBASE-012 | Persistent `UNKNOWN` | `mergeable-unknown` disposition/trailer; pending-dev; no PR conflict marker |
| TC-E2E-REBASE-013 | Persistent empty result | Same as persistent `UNKNOWN` |
| TC-E2E-REBASE-014 | PR closes/merges during poll | INV-54 remove-only cleanup; no disposition/conflict/pending-dev |
| TC-E2E-REBASE-015 | Head changes during poll | `head-changed` non-substantive retry to pending-review; no stale disposition |
| TC-E2E-REBASE-016 | Initial/final provider snapshot read fails | Non-substantive pending-review retry; no disposition |
| TC-E2E-REBASE-017 | UNKNOWN settles to MERGEABLE within retry budget | Continue after bounded polling |
| TC-E2E-REBASE-018 | Source ordering | Snapshot/preflight precedes command and browser E2E entry points |
| TC-E2E-REBASE-019 | Clean preflight then base advances | Post-fan-out INV-44 remains and takes canonical conflict route |

## Durable Writes And Idempotency

| ID | Scenario | Expected |
|---|---|---|
| TC-E2E-REBASE-020 | Conflict disposition write fails | No pending-dev; pending-review retry |
| TC-E2E-REBASE-021 | PR rebase-marker write fails | No pending-dev; pending-review retry |
| TC-E2E-REBASE-022 | Substantive verdict-trailer write fails | No pending-dev; pending-review retry |
| TC-E2E-REBASE-023 | Required writes succeed | Required-write order precedes pending-dev |
| TC-E2E-REBASE-024 | Retry after partial writes | Missing write retried; existing semantic markers not duplicated |
| TC-E2E-REBASE-025 | Final pending-dev transition fails | Routing evidence remains durable and `RESULT_PARSED` is not prematurely set |
| TC-E2E-REBASE-026 | Preflight and post-fan-out conflict | Same finding, PR marker, trailer, request-changes, and transition semantics |
| TC-E2E-REBASE-040 | Blocking conflict-finding write fails | No pending-dev; later run retries the missing finding |
| TC-E2E-REBASE-041 | Post-fan-out Reviewed HEAD write fails | No pending-dev until strict-self INV-04 evidence is durable |
| TC-E2E-REBASE-042 | Quoted PR marker contains the canonical HTML marker | Quoted history does not suppress the canonical `Auto-merge failed:` write |
| TC-E2E-REBASE-043 | Real review wrapper sees a stable conflict | Zero E2E/fan-out; all required writes precede pending-dev |
| TC-E2E-REBASE-044 | Real dev-new wrapper receives the conflict route | Mandatory rebase block precedes implementation work and requires abort/force-with-lease semantics |
| TC-E2E-REBASE-045 | Real successful rebase and next review | Force-with-lease advances remote HEAD; new HEAD runs E2E exactly once |
| TC-E2E-REBASE-046 | Real unsafe rebase conflict | Conflicting files are reported, rebase aborts, HEAD is preserved, and old HEAD runs no E2E |
| TC-E2E-REBASE-047 | Invalid mergeability retry delay configuration | Polling falls back to a valid delay and does not terminate a `set -e` caller |
| TC-E2E-REBASE-048 | Same HEAD conflicts again after a completed dev attempt | The unique disposition is reused, a fresh verdict is emitted after the attempt boundary, and INV-85 receives the post-session substantive verdict |
| TC-E2E-REBASE-049 | Dev wrapper cannot read current conflict context | Prompt fails closed with mandatory context recovery before implementation work |
| TC-E2E-REBASE-050 | HEAD changes during post-fan-out mergeability polling | No stale conflict evidence is emitted; review requeues for the new HEAD |
| TC-E2E-REBASE-051 | Force-push sequence A -> B -> A | Current-head filtering reuses the unique A disposition and a fresh A verdict lands after B evidence |
| TC-E2E-REBASE-052 | INV-33 auto-merge fails after approval | Producer appends the separate generic marker bound to issue and full reviewed HEAD; dev accepts it as current-HEAD rebase evidence; a marker-write failure requeues review before dev dispatch |
| TC-E2E-REBASE-053 | Generic marker is stale, quoted, abbreviated, or for another issue | Dev ignores the lookalike; marker-free legacy INV-33 comments remain backward compatible |
| TC-E2E-REBASE-054 | Strict routing-evidence read fails while ordinary issue reads remain available | No first-review transition, dev dispatch, or INV-85 attempt marker; distinct operational defer remains visible to INV-128 and reaches its bounded `stalled` route |
| TC-E2E-REBASE-055 | Post-fan-out HEAD sequence A -> B -> A | Current-head filtering reuses the unique Reviewed-HEAD A anchor and requires a fresh verdict after B before pending-dev |
| TC-E2E-REBASE-056 | GitHub PR has more than 100 discussion comments and recovery marker is comment 101 | Paginated `chp_pr_view comments` returns the complete normalized list and preserves marker 101 |
| TC-E2E-REBASE-057 | PR recovery marker is quoted, malformed, case-varied, or followed by a terminal newline | Only an exact current-issue/current-HEAD final line is canonical; lookalikes cannot use legacy fallback |
| TC-E2E-REBASE-058 | HEAD changes after same-HEAD evidence matches but before no-session/unconfirmed-session recovery acts | Both recovery shapes requeue `pending-review`; neither dispatches dev nor records a stale-HEAD attempt |
| TC-E2E-REBASE-059 | Required writes succeed but the final conflict/UNKNOWN `pending-dev` transition fails once | Cleanup retries only the state movement; the already-durable required verdict remains single |
| TC-E2E-REBASE-060 | Routing history is A disposition/verdict, then B disposition with the same verdict class, then A becomes current again | B's full-HEAD-bound verdict cannot satisfy A's freshness check; one fresh `head=A` required trailer is emitted and shared classification preserves its verdict/cause |
| TC-E2E-REBASE-061 | A -> B -> A routing history also contains strict-self provider rows with null or missing timestamps | Malformed rows are excluded from the shared ordered timeline and cannot shift the freshness boundary to reuse A's stale verdict |
| TC-E2E-REBASE-062 | A bare verdict trailer repeats `head`, `cause`, or `dev-actionable` | The structurally authenticated grammar rejects duplicate optional keys, including contradictory full-HEAD bindings |
| TC-E2E-REBASE-063 | A preflight helper exits `failed-non-substantive` | The verdict is followed immediately by INV-129 `round=0`, then the state transition |
| TC-E2E-REBASE-064 | Dev conflict-context provider reads fail repeatedly | Every guarded prompt requires one strict issue/full-HEAD whole-body marker and forbids surrounding prose or duplicates |
| TC-E2E-REBASE-065 | The real guarded dev wrapper posts its marker and cleanup session report | The marker is idempotent, but the session report changes INV-128's generic fingerprint, proving a direct bound is required |
| TC-E2E-REBASE-066 | A completed current attempt posts the strict marker for the unchanged reviewed HEAD; its required conflict verdict predates the dev session | The real post-session classifier returns `none`, but the strict current-HEAD `conflict-rebase` disposition preserves the direct `stalled` route with no further `dev-new` |
| TC-E2E-REBASE-067 | The matching marker predates the latest trusted dev dispatch token, or no trusted token exists | The out-of-attempt marker cannot stall the new attempt; ordinary bounded routing continues |
| TC-E2E-REBASE-068 | An unconfirmed Codex session posts the current-attempt marker for the unchanged reviewed HEAD | Dispatcher transitions directly to `stalled` without a crash-recovery `dev-new` |
| TC-E2E-REBASE-069 | A dispatch token and its later failure marker share one provider timestamp second | The normalized monotone comment ID breaks the tie and the marker remains current-attempt evidence |
| TC-E2E-REBASE-070 | Dev conflict-context reads fail while `PROJECT_DIR` points at a different base checkout HEAD | The guarded prompt binds the failure marker to strict issue routing evidence for the reviewed PR HEAD; the agent never derives it from bare `git rev-parse HEAD` in `PROJECT_DIR` |
| TC-E2E-REBASE-071 | Provider context and strict issue routing evidence both lack a full HEAD | The guarded prompt requires an issue-bound PR worktree, scopes `rev-parse` to that validated worktree, posts its full HEAD in the canonical marker, and never posts the base checkout HEAD |

## Dispatcher And Wrapper Convergence

| ID | Scenario | Expected |
|---|---|---|
| TC-E2E-REBASE-027 | Same-head conflict-rebase disposition | Existing substantive router dispatches one bounded `dev-new`; no first-review shortcut |
| TC-E2E-REBASE-028 | Same-head mergeable-unknown disposition | Existing non-substantive router requeues review and reaches its retry cap |
| TC-E2E-REBASE-029 | Stale disposition with newer current head | First review of new head |
| TC-E2E-REBASE-030 | Spoofed/malformed disposition | Ignored; first-review behavior unchanged |
| TC-E2E-REBASE-031 | Existing Reviewed HEAD flow | INV-04 behavior unchanged |
| TC-E2E-REBASE-032 | Conflict lifecycle | pending-review -> reviewing -> preflight -> pending-dev -> dev-new |
| TC-E2E-REBASE-033 | Successful rebase | Prompt requires `--force-with-lease`; head changes; one E2E run on new head |
| TC-E2E-REBASE-034 | Unsafe rebase | Prompt requires abort/report; unchanged head reaches existing bounded stalled route with zero E2E |

## Provider And Regression Coverage

| ID | Scenario | Expected |
|---|---|---|
| TC-E2E-REBASE-035 | GitHub normalized fixture matrix | Expected provider-neutral decision trace |
| TC-E2E-REBASE-036 | GitLab normalized fixture matrix | Trace equals GitHub trace |
| TC-E2E-REBASE-037 | Caller-layer provider scan | No new raw `gh`/`glab` call |
| TC-E2E-REBASE-038 | INV-44/INV-46/INV-98/INV-122 regressions | Existing focused suites remain green |
| TC-E2E-REBASE-039 | Syntax, ShellCheck, spec drift | All repository gates pass |

## Acceptance-Criteria Mapping

| Acceptance criterion | Test IDs |
|---|---|
| Stable conflict skips E2E/fan-out and ends pending-dev | 011, 018, 023, 032, 043 |
| Same-head conflict disposition reaches one bounded dev action | 027, 032, 034, 044, 048, 058 |
| Strict current-issue/full-head/machine marker contract | 001-009, 029-031, 052-053, 055-057 |
| Required writes prevent orphan pending-dev and retry idempotently | 020-025, 040-042, 059 |
| Successful/unsafe rebase convergence | 033-034, 045-046 |
| UNKNOWN/empty/head-change bounded non-substantive routing | 012-016, 028, 047, 050, 063 |
| Persistent dev context-read failure remains bounded | 049, 064-069 |
| GitHub/GitLab equivalent provider decisions | 035-037 |
| Existing gates and repository checks remain green | 019, 038-039 |
