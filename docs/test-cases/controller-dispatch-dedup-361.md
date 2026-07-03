# Test cases — controller-side per-(issue,mode) dispatch dedup (issue #361 / 302b / INV-108*)

> *INV number note: the invariant shipped in this PR's `invariants.md` edit; if a rebase
> collision renumbers it, this doc follows the invariant heading, first-merged-keeps-the-number.

Fixture-driven, mirroring the existing `test-dispatcher-tick-router.sh` verbatim-extraction
harness and the `test-mark-stalled-liveness.sh` function-override technique. Run under
`env -u PROJECT_DIR` for CI parity.

- `tests/unit/test-controller-dispatch-dedup-361.sh` — `acquire_dispatch_marker` /
  `release_dispatch_marker` / `dispatch_marker_confirm_launched` /
  `_dispatch_marker_release_pending` (`lib-dispatch.sh`) + the five guarded dispatch sites
  (`dispatcher-tick.sh` Steps 2/3/4 ×4, `handle_completed_session_routing` Branch C) +
  `post_dispatch_token`'s `run=` field.

| Test ID | Scenario | Expected |
|---|---|---|
| TC-DEDUP-361-001/002 | 10 REAL concurrent processes race one `(issue, mode)` acquire (actual `mkdir` syscall, not in-process bash state) | Exactly ONE winner (rc 0); nine lose cleanly (rc 1) |
| TC-DEDUP-361-003/004 | Sequential same-process re-acquire of the same `(issue, mode)` | 003: first acquire wins (rc 0); 004: immediate second fails cleanly (rc 1, held) |
| TC-DEDUP-361-005 | Different `mode` for the same issue | Independent marker — both acquire |
| TC-DEDUP-361-006/007 | Live marker vs backdated (age > TTL) marker | Live blocks (rc 1); expired is reclaimed (rc 0) via atomic `mv`+`mkdir` |
| TC-DEDUP-361-008 | `DISPATCH_MARKER_TTL_SECONDS` unset | Defaults to `DISPATCH_GRACE_PERIOD_SECONDS` ([INV-18]) |
| TC-DEDUP-361-009 | `pid_dir_for_project` unavailable (fail-open class 1) | rc 0 + WARN — marker infra failure never blocks dispatch (INV-103 backstop) |
| TC-DEDUP-361-009b | Same, but under ACTIVE `set -e` in a NON-condition context (round-7 [P1]) | The shell SURVIVES to observe rc 0 — the bare-assignment rc leak would abort the whole tick (mutation-verified: reverting `|| base_dir=""` flips this to FAIL) |
| TC-DEDUP-361-010 | Marker path is a pre-existing symlink (fail-open class 2) | rc 0 — refused, never used |
| TC-DEDUP-361-010b/c | Marker `mkdir` fails non-EEXIST (EACCES via read-only base dir; fail-open class 3, round-6 [P1]) | rc 0 + the `dispatch-marker creation failed` WARN (010c's grep cross-guards 010b); loud SKIP where perms are not enforced (root) |
| TC-DEDUP-361-010d | Plain-FILE obstruction at the marker path (boundary control) | Path EXISTS → mtime/held path (rc 1 while fresh), NOT the creation-failure fail-open |
| TC-DEDUP-361-035/035b/035c | Stale-reclaim rename failure (round-12 [P1]): read-only parent (non-race) vs concurrent-winner rename race (fresh marker at path) | 035: non-race infra failure fails OPEN (rc 0) + 035c WARN emitted; 035b control: rename race with a FRESH recreated marker stays held (rc 1) |
| TC-DEDUP-361-037/037b/037c | TTL bounds-clamp (round-13 [P1] + local [P2]) | 037: `DISPATCH_GRACE_PERIOD_SECONDS=0` does not cascade to a 0s marker TTL (second overlapping acquire still held); 037b: explicit `DISPATCH_MARKER_TTL_SECONDS=0` clamps to default; 037c: huge TTL (2^31-1) clamps — backdated marker still reclaimable (no permanent lock) |
| TC-DEDUP-361-036/036b | Unstattable vs vanished marker (round-12 local review) | 036: present-but-unstattable (stat broken) fails OPEN (rc 0); 036b control: vanished-during-stat (true TOCTOU) stays a one-tick hold (rc 1) |
| TC-DEDUP-361-011..013 | `post_dispatch_token` `run=` field (R2) | Present after `mode=`; `DISPATCHER_RUN_ID` override honored verbatim; stable across calls in one process |
| TC-DEDUP-361-013b | Run-id cache across a REAL 1.2s gap | Same id — pins the set-global (not echo/subshell) shape; a `$(…)` call site would re-mint every call |
| TC-DEDUP-361-014..016 | Legacy token WITHOUT `run=` + new token WITH it | Both parse via `latest_dispatch_token_age_seconds` and `is_within_grace_period` (backward compat) |
| TC-DEDUP-361-017/018 | Source-of-truth greps | Every `dispatcher-tick.sh` dispatch site AND Branch C carry the `acquire_dispatch_marker` guard text |
| TC-DEDUP-361-019..023 | Guard blocks extracted VERBATIM from `dispatcher-tick.sh`, executed against the REAL acquire with a pre-planted held marker | The shipped `continue` fires (dispatch suppressed) on all four sites; TC-023 control proves a fresh acquire passes the same block (mutation-tested by inverting a guard's `!`) |
| TC-DEDUP-361-024..029 | Release-on-failure unit surface (round-4 [P1]) | Acquire populates the pending list; release removes marker AND pending entry; confirm drops pending WITHOUT touching the marker; the EXIT-trap sweep reaps unconfirmed but spares confirmed; a released marker re-acquires immediately (no ~10 min false stall) |
| TC-DEDUP-361-025b/c | Ownership gate on release (round-9 [P1]) | 025b: a NOT-owned release (pair absent from pending — this tick's acquire fail-opened) leaves a foreign live marker UNTOUCHED (mutation-verified: removing the gate flips it to FAIL); 025c control: an OWNED release still removes the marker |
| TC-DEDUP-361-030 | PTL log-truncate-failure branch extracted VERBATIM, `_reset_session_log` stubbed to fail | `release_dispatch_marker` runs (mutation-verified by removing the call) |
| TC-DEDUP-361-031/031b | Acquire/confirm call-count parity in `dispatcher-tick.sh` AND `lib-dispatch.sh` (round-5 [P1]) | Counts match — a future site cannot add an acquire without a confirm |
| TC-DEDUP-361-038 | Held-marker skips protect the winner from Step 5 (round-14 [P1]) | All 4 dispatcher-tick guard blocks append `JUST_DISPATCHED` before `continue` (source-of-truth count match; mutation-verified) |
| TC-DEDUP-361-039/039b | `may_stall_now` marker deferral (round-14 local review) | 039: a FRESH marker (any mode) defers stalling (rc 1) even when the PID probe says DEAD (cold-start window); 039b control: an EXPIRED marker restores stall eligibility (never wedges) |
| TC-DEDUP-361-032 | `dispatcher-tick.sh` trap installation | `trap … _dispatch_marker_release_pending … EXIT` present after sourcing `lib-dispatch.sh` |
| TC-DEDUP-361-033 | Branch C's failure block extracted VERBATIM (sibling of TC-030, round-5 [P1]) | Branch C's `release_dispatch_marker` runs (mutation-verified) |
| TC-DEDUP-361-034 | Branch C via the DELEGATED entry (`if handle_pending_dev_pr_exists` — bash suppresses errexit inside a function called in an `if`), `dispatch` stubbed to FAIL (round-9 [P1]) | The explicit `if ! label_swap \|\| ! post_dispatch_token \|\| ! dispatch` guard releases the marker and bails BEFORE `confirm_launched`; no phantom per-HEAD attempt marker posted (mutation-verified: reverting to the unguarded sequence flips it to FAIL) |
