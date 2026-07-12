# Test Cases — generic liveness watchdog (issue #467)

Pins the pure fingerprint/counter/tier-decision helpers added to a new
`lib-liveness.sh`, plus the Step 6 wiring in `dispatcher-tick.sh` and an E2E
stub-dispatcher replay of the `api_error` park shape with the specific breaker
disabled.

## Files under test

| File | Role |
|------|------|
| `skills/autonomous-dispatcher/scripts/lib-liveness.sh` (NEW) | Pure helpers: `_liveness_fingerprint`, `_liveness_next_count` (accepts an optional `stall_ticks` cap, round 6), `_liveness_next_tier1`, `_liveness_tier_action`, `_liveness_notice_ticks`, `_liveness_stall_ticks`, `_liveness_wrapper_alive`, `_liveness_marker`, `_liveness_parse_marker`, `_liveness_prior_marker` (whole-body anchor, round 6), `_liveness_strict_author_flag` (NEW, round 6 — app-mode-only authorKind gate) |
| `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` | New Step 6, after Step 5 |
| `tests/unit/test-liveness-watchdog.sh` (NEW) | Pure-logic + wiring regression suite |
| `tests/e2e/run-liveness-watchdog-e2e.sh` (NEW) | Stub-dispatcher replay |

## Group A — fingerprint (TC-LIVENESS-001..008)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-001 | Same (label, head, comment-count, marker-digest) across two evaluations | identical fingerprint |
| TC-LIVENESS-002 | Label changes, all else equal | different fingerprint |
| TC-LIVENESS-003 | PR head SHA changes, all else equal | different fingerprint |
| TC-LIVENESS-004 | Non-idempotent comment count changes, all else equal | different fingerprint |
| TC-LIVENESS-005 | Marker digest changes (a new marker grammar appears), all else equal | different fingerprint |
| TC-LIVENESS-006 | A new `stale-verdict:<head>`-style idempotent notice is posted | fingerprint's comment-count component is UNCHANGED (excluded) |
| TC-LIVENESS-007 | A genuinely new (non-idempotent) comment is posted | fingerprint's comment-count component changes |
| TC-LIVENESS-008 | The watchdog's own tier-1 comment is posted | excluded from the count component (self-exclusion, D3) |

## Group B — counter / tier1 latch round-trip (TC-LIVENESS-009..015)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-009 | No prior marker → count=1, tier1=0 | `_liveness_next_count`/`_liveness_next_tier1` on empty marker text |
| TC-LIVENESS-010 | Prior marker same fingerprint, count=N → next count = N+1 | increments |
| TC-LIVENESS-011 | Prior marker DIFFERENT fingerprint → resets to count=1, tier1=0 | full reset, regardless of prior count/tier1 |
| TC-LIVENESS-012 | Prior marker same fingerprint, tier1=1 → next tier1 stays 1 | latch persists until fingerprint changes |
| TC-LIVENESS-013 | Malformed / corrupted marker text → parses as count=0, tier1=0 (never crashes) | bias to MISS |
| TC-LIVENESS-014 | Marker round-trip: construct then parse recovers identical fields | `_liveness_marker` / `_liveness_parse_marker` |
| TC-LIVENESS-015 | Fingerprint change at tick 10 (mid-sequence) → full reset, no tier-2 ever reached on the old series | regression pin for the "full reset, no tier-2" AC |

## Group C — tier action selection (pure) (TC-LIVENESS-016..022)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-016 | count < notice | `none` |
| TC-LIVENESS-017 | count == notice, tier1=0 | `tier1` |
| TC-LIVENESS-018 | count == notice, tier1=1 (already fired) | `none` (must not re-fire) |
| TC-LIVENESS-019 | notice < count < stall, tier1=1 | `none` |
| TC-LIVENESS-020 | count == stall | `tier2` |
| TC-LIVENESS-021 | count > stall (a tick was somehow missed) | `tier2` (still fires, not skipped) |
| TC-LIVENESS-022 | count == stall but tier1=0 (tier 1 was somehow never reached, e.g. threshold misconfig at runtime) | `tier2` (tier 2 is unconditional once the count threshold is met — R3 does not gate tier 2 on tier 1 having fired) |

## Group D — threshold config validation (TC-LIVENESS-023..030)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-023 | `LIVENESS_NOTICE_TICKS` unset | defaults to 6 |
| TC-LIVENESS-024 | `LIVENESS_STALL_TICKS` unset | defaults to 18 |
| TC-LIVENESS-025 | `LIVENESS_NOTICE_TICKS` non-numeric | falls back to 6, warning on stderr |
| TC-LIVENESS-026 | `LIVENESS_NOTICE_TICKS=1` (below floor `>=2`) | falls back to 6, warning on stderr |
| TC-LIVENESS-027 | `LIVENESS_STALL_TICKS` <= `LIVENESS_NOTICE_TICKS` (e.g. both=6, or stall=3/notice=10) | [codex review, PR #472, BLOCKING] `LIVENESS_STALL_TICKS` falls back to the documented default 18 — NOT an unconditional `notice+1` clamp — warning on stderr. Exception: if the (validly-configured) notice is itself `>= 18`, the default 18 would also fail `stall > notice`, so the fallback escalates to `notice+1` only in that case. |
| TC-LIVENESS-028 | Both valid and `stall > notice` | honored verbatim, no warning |
| TC-LIVENESS-029 | Warning text goes to stderr only, never corrupts the captured numeric value (mirrors `_gate_breaker_threshold`'s codex [P2] fix) | `$(... 2>/dev/null)` is a clean integer |
| TC-LIVENESS-030 | `LIVENESS_WATCHDOG_ENABLED=false` | Step 6 evaluates zero issues (no fingerprinting, no marker reads/writes) |

## Group E — exemptions (TC-LIVENESS-031..037)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-031 | Issue carries `approved` or `stalled` | not returned by `list_pending_dev`/`list_pending_review` — skipped entirely, no evaluation |
| TC-LIVENESS-032 | Issue is in `JUST_DISPATCHED` this tick | skipped, no fingerprint computed |
| TC-LIVENESS-033 | Issue is within the INV-18 dispatch grace period | skipped |
| TC-LIVENESS-034 | `pending-dev` issue with a live dev wrapper (`pid_alive issue`) | skipped (not counted as no-op) |
| TC-LIVENESS-035 | `pending-review` issue with a live review wrapper (`pid_alive review`) | skipped |
| TC-LIVENESS-036 | A fresh (unconsumed) dispatch marker for this issue | skipped (`_dispatch_marker_recent`) |
| TC-LIVENESS-037 | `itp_list_comments` fails transiently | skipped this tick (fail-toward-defer, never misread as "no comments") |

## Group F — two-tier sequence (TC-LIVENESS-038..044)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-038 | 6 consecutive no-op ticks (default `LIVENESS_NOTICE_TICKS`) | tier-1 comment posted exactly once, `@REPO_OWNER` mentioned, no label change; (c/d, round 6) the report is a comment DISTINCT from a separately-posted bare `tier1=1` marker |
| TC-LIVENESS-039 | Tick 7 with fingerprint still unchanged (tier1 already fired) | no second tier-1 comment |
| TC-LIVENESS-040 | 18 consecutive no-op ticks (default `LIVENESS_STALL_TICKS`) | `stalled` transition + exactly one `reason=liveness-timeout` report; (e/f/g, round 6) the report is a comment DISTINCT from a separately-posted bare marker, posted in marker-then-report order |
| TC-LIVENESS-041 | Fingerprint changes at tick 10 | count/tier1 reset; tick 10 evaluates as count=1; tier-2 never reached on the interrupted series |
| TC-LIVENESS-042 | Tier-2 report includes the last-known fingerprint components, tick counts, and pointers to the newest session report / verdict / markers | pinned string content |
| TC-LIVENESS-043 | Already-`stalled` race: a specific breaker (e.g. INV-105) stalls the issue between the candidate list fetch and this evaluation | watchdog re-checks labels immediately before the transition and does NOT re-transition or post a competing report |
| TC-LIVENESS-044 | (a/b) Human comment quoting/discussing the marker (not a byte-for-byte copy as the entire body) at a high count | rejected by the structural anchor — genuine count unaffected, restarts at 1 |
| TC-LIVENESS-044 | (c/d) `BOT_LOGIN` unset (the real `GH_AUTH_MODE=token` topology) + a GENUINE marker that normalizes to `authorKind=human` | still authenticated via the structural anchor — count increments normally, watchdog is NOT permanently inert |

## Group G — E2E stub-dispatcher replay (TC-LIVENESS-045)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-045 | Replay the `api_error` park shape (`pending-dev`, resolvable sid, dead wrapper, frozen fingerprint) with the INV-125 crashed-session recovery path's one-shot budget already spent (so the specific breaker cannot fire again) — run the stub dispatcher tick-by-tick | tier-1 comment appears at tick `LIVENESS_NOTICE_TICKS`; `stalled` + one report appears at tick `LIVENESS_STALL_TICKS`; each exactly once |
| TC-LIVENESS-045h | Operator resume: after the tier-2 report fires, remove `stalled` (restoring `pending-dev`) with the fingerprint's other components unchanged, then run one more tick | does NOT immediately re-transition to `stalled`; the watchdog marker restarts at `count=1 tier1=0` — a fresh episode, not a re-trip off the old trip report's embedded marker |

## Group H — prior-marker cutoff / resume-after-un-stall (TC-LIVENESS-046..050)

`_liveness_prior_marker` ([codex review, PR #472, BLOCKING #2]) is the cutoff-then-scan pure helper that fixes a self-referential read. Fixtures model the real producer shape (marker at T-epsilon, trip report — whose body starts with the real `_LIVENESS_TIER2_HEADING`, [round 7] — at T): the marker is posted STRICTLY BEFORE the report as a separate comment (round 6), and the cutoff is computed by matching `startswith($heading)` against that same single-sourced constant ([round 7] — see Group K for the regression this closed). Without a cutoff at the latest genuine trip report, an operator resuming a stalled issue with an otherwise-unchanged fingerprint would have the very next evaluation read that old trip's marker back and immediately re-trip tier 2 again.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-046 | A constructed fixture: a marker (`count=18 tier1=1`) immediately followed by a trip report (body starting with the real heading) at the next timestamp; no comment exists after it | `_liveness_prior_marker` returns `""` — the marker is excluded (it precedes the cutoff, and the cutoff comparison is strict `>`) |
| TC-LIVENESS-047 | A trip report at T1, then a genuinely later bare marker at T2 > T1 | `_liveness_prior_marker` returns the T2 marker; feeding it into `_liveness_next_count` continues a fresh post-resume series, not a re-trip off T1's count |
| TC-LIVENESS-048 | No trip report has ever been posted | cutoff is the epoch; the existing marker still qualifies (unchanged behavior for the common, no-trip-yet case) |
| TC-LIVENESS-049 | End-to-end through `_liveness_evaluate_issue`: a trip report already fired, then a re-arm tick runs against the SAME fingerprint (as if `stalled` were removed with nothing else changed) | does NOT immediately re-transition to `stalled`; the fresh marker restarts at `count=1 tier1=0` |
| TC-LIVENESS-050 | A SECOND trip-resume cycle: trip #1 (marker+report), a post-resume marker, trip #2 (marker+report) | cutoff tracks the LATEST trip (#2), not the first — no qualifying prior marker after the second trip, regression pin against a `max`→`min`/`first` mutation |

## Group I — round-6 hardening: whole-body anchor, app-mode authorKind gate, count cap (TC-LIVENESS-051..058)

[operator guidance, PR #472 round 6] Rounds 2 and 5 pulled the marker's authenticity gate in opposite directions (round 2: an unconditional `authorKind != "human"` gate makes the watchdog permanently inert in the default `GH_AUTH_MODE=token` topology; round 5: no `authorKind` gate lets any human forge a bare marker and force an immediate trip). Resolved by mirroring `classify_recent_review_verdict`'s established two-part pattern: a whole-body structural anchor in every mode, plus `authorKind != "human"` layered on top ONLY in `GH_AUTH_MODE=app`. This also required splitting the marker out into its own comment (never embedded as the report's first line) so the anchor could tighten from "marker line, then optionally more prose" to "the entire body is the marker" without rejecting genuine traffic. A count cap adds defense-in-depth against the token-mode residual's blast radius.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-051 | A comment shaped like the PRE-round-6 embed (marker line + trailing report prose, no trip heading) | rejected by the whole-body anchor (regression pin against `[[:space:]]*$` reverting to `($\|\n)`) |
| TC-LIVENESS-052 | The bare marker plus only a trailing newline (GitHub's typical comment-body normalization) | still accepted — the anchor tolerates trailing whitespace, not trailing content |
| TC-LIVENESS-053 | `GH_AUTH_MODE=app` + a forged bare marker authored by a human | rejected by the `authorKind` gate |
| TC-LIVENESS-054 | `GH_AUTH_MODE=app` + the SAME bare marker authored by a bot/App identity | accepted |
| TC-LIVENESS-055 | `_liveness_strict_author_flag` across `GH_AUTH_MODE` ∈ {unset, token, app} | flag=0, 0, 1 respectively |
| TC-LIVENESS-056 | A stored marker claims an absurd count (e.g. 999999) on a matching fingerprint, with `stall_ticks` supplied | the accepted count is capped at `stall_ticks`, not the forged value |
| TC-LIVENESS-057 | (a) same forged marker WITHOUT a `stall_ticks` arg; (b) a count that lands below `stall_ticks` after +1 | (a) uncapped increment (back-compat); (b) untouched by the cap — it is a ceiling, not a rewrite |
| TC-LIVENESS-058 | End-to-end through `_liveness_evaluate_issue`: a forged marker at an absurd count, but on a fingerprint that does NOT match the current one | resets to `count=1` regardless of the forged count — proves the cap is defense-in-depth, not a substitute for the fingerprint-match gate |

## Group J — E2E regression: marker/report split holds through a full replay (TC-LIVENESS-045i/j)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-045i | The tier-2 trip report, after the full 25-tick stub-dispatcher replay | its body does not start with the marker prefix (split into two comments, round 6) |
| TC-LIVENESS-045j | Whole-body-anchored bare marker comments across the full replay | at least two exist (one from tier 1, one from tier 2) |

## Group K — round-7 regression: forged mid-comment cutoff mention (TC-LIVENESS-045k, TC-LIVENESS-059)

[codex review, PR #472, round 7 BLOCKING] Until round 7, `_liveness_prior_marker`'s cutoff detection was an UNANCHORED `contains("Liveness watchdog tripped")` substring test. Any comment merely MENTIONING that bare phrase anywhere in its body — not as a report's own opening line, e.g. a human collaborator discussing a past trip in prose — falsely registered as a trip and became the cutoff, excluding the genuine earlier marker and permanently resetting a still-frozen issue's series to `count=1` on every subsequent tick, letting a real park dodge tier 2 indefinitely. Fixed by anchoring the cutoff match to `startswith($heading)` against the new single-sourced `_LIVENESS_TIER2_HEADING` constant.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-059 | (unit, pure helper) A genuine earlier marker, then a human comment that mentions the trip heading mid-sentence (not as its own opening line) | `_liveness_prior_marker` still returns the genuine earlier marker — the mid-comment mention does NOT act as a forged cutoff |
| TC-LIVENESS-045k | (E2E, through `_liveness_evaluate_issue`) A fresh in-progress episode built up to `count=10`, then the SAME forged mid-comment mention (also idempotent-pattern-excluded via `reason=liveness-timeout` so it doesn't itself change the fingerprint) | the count continues incrementing across the forged comment (10 → 11), not reset to 1 |
