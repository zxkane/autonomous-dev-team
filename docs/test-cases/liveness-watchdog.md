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
| TC-LIVENESS-006 | A new `` `stale-verdict:<head>` ``-style idempotent notice is posted, backtick-wrapped as every genuine producer renders it | fingerprint's comment-count component is UNCHANGED (excluded) |
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

`_liveness_prior_marker` ([codex review, PR #472, BLOCKING #2]; cutoff signal REDESIGNED [round 8], see Group L) is the cutoff-then-scan pure helper that fixes a self-referential read. Fixtures model the real producer shape (marker at T-epsilon, trip report at T): the marker is posted STRICTLY BEFORE the report as a separate comment (round 6), and — as of round 8 — the cutoff is computed directly from the LATEST marker whose OWN `tripped` field equals `1`, not from any text pattern on the report. Without a cutoff at the latest genuine trip, an operator resuming a stalled issue with an otherwise-unchanged fingerprint would have the very next evaluation read that old trip's marker back and immediately re-trip tier 2 again.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-046 | A constructed fixture: a `tripped=1` marker (`count=18 tier1=1`) immediately followed by a trip report at the next timestamp; no comment exists after it | `_liveness_prior_marker` returns `""` — the `tripped=1` marker is excluded (it precedes the cutoff, and the cutoff comparison is strict `>`) |
| TC-LIVENESS-047 | A `tripped=1` marker at T1, then a genuinely later bare `tripped=0` marker at T2 > T1 | `_liveness_prior_marker` returns the T2 marker; feeding it into `_liveness_next_count` continues a fresh post-resume series, not a re-trip off T1's count |
| TC-LIVENESS-048 | No `tripped=1` marker has ever been posted | cutoff is the epoch; the existing marker still qualifies (unchanged behavior for the common, no-trip-yet case) |
| TC-LIVENESS-049 | End-to-end through `_liveness_evaluate_issue`: a `tripped=1` marker already fired, then a re-arm tick runs against the SAME fingerprint (as if `stalled` were removed with nothing else changed) | does NOT immediately re-transition to `stalled`; the fresh marker restarts at `count=1 tier1=0 tripped=0` |
| TC-LIVENESS-050 | A SECOND trip-resume cycle: trip #1 (`tripped=1` marker + report), a post-resume `tripped=0` marker, trip #2 (`tripped=1` marker + report) | cutoff tracks the LATEST `tripped=1` marker (#2), not the first — no qualifying prior marker after the second trip, regression pin against a `max`→`min`/`first` mutation |

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

## Group K — round-7/8 regression: forged cutoff-text mentions (TC-LIVENESS-045k, TC-LIVENESS-059)

[codex review, PR #472, rounds 7-8] Until round 7, `_liveness_prior_marker`'s cutoff detection was an UNANCHORED `contains("Liveness watchdog tripped")` substring test — any comment merely MENTIONING that bare phrase anywhere in its body falsely registered as a trip. Round 7 tightened this to `startswith($heading)`; round 8 found `startswith()` was STILL forgeable (a comment merely OPENING with the exact heading, with no real marker at all, satisfied it too) and eliminated the free-text cutoff signal entirely — see Group L. These test cases now pin BOTH historical forgery shapes against the round-8 fix, proving neither can register as a cutoff regardless of the (now-decorative) heading text.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-059 | (unit, pure helper) A genuine earlier marker, then (a) a human comment that mentions the trip heading mid-sentence, and (b) a human comment that OPENS with the exact heading text but contains no real marker at all | `_liveness_prior_marker` still returns the genuine earlier marker — neither forgery shape acts as a cutoff, since the cutoff no longer reads free text at all (round 8) |
| TC-LIVENESS-045k | (E2E, through `_liveness_evaluate_issue`) A fresh in-progress episode built up to `count=10`, then a forged mid-comment mention (idempotent-pattern-excluded via a backtick-wrapped `` `reason=liveness-timeout` ``, [round 8], so it doesn't itself change the fingerprint) | the count continues incrementing across the forged comment (10 → 11), not reset to 1 |

## Group L — round 8: tripped-field cutoff redesign, wrapper-anchored idempotent patterns, PR-lookup transport-failure exemption, threshold-warning relogging

[codex review, PR #472, round 8, 4 BLOCKING findings] A single review round surfaced four independent gaps, all fixed together:

| ID | Finding | Fix | Covered by |
|----|---------|-----|------------|
| round 8 #1 | The cutoff (`_liveness_prior_marker`) still keyed on a separately-typed heading-text pattern (`startswith($heading)`), forgeable by any comment that simply opens with the exact heading | `tripped=<0\|1>` added as a FIELD on the marker's own already-authenticated, whole-body-anchored grammar; the cutoff now keys on that field instead of any free text | TC-LIVENESS-046..050, 059 (Groups H/K, rewritten) |
| round 8 #2 | `_LIVENESS_IDEMPOTENT_PATTERN`/`_LIVENESS_DIGEST_PATTERN` were bare alternations (substring tests) — a human comment merely discussing/quoting a token in prose matched identically to a genuine wrapped marker/report | Both patterns require a leading wrapper anchor (a backtick code span or an HTML-comment opening) immediately before the token; every genuine producer already wraps this way | TC-LIVENESS-006 (Group A, updated), TC-LIVENESS-060..062 |
| round 8 #3 | `fetch_pr_for_issue` transport failure was collapsed into "no PR" (`current_head=""`), silently resetting the counter on a transient API blip | The call site checks the rc BEFORE reading the head; a nonzero rc defers the entire tick (fail-toward-defer, mirrors the `itp_list_comments` preflight) | TC-LIVENESS-063..064 |
| round 8 #4 | `run_liveness_watchdog` redirected both threshold readers' stderr straight to `/dev/null`, so R5's required invalid-config warning never reached the dispatcher's own log | Each reader's stderr is captured via `mktemp` (mirroring `ci_is_green`'s capture-then-relog pattern) and re-emitted through `log()` | manually verified (WARNING lines observed in `log()` output for an injected invalid config); no dedicated TC-LIVENESS ID — this is a logging-only change with no decision-function behavior to pin beyond Group D's existing fallback coverage |

**[round 9, independent self-review gap]** The `tripped` field introduced by round 8 #1 has TWO forgery directions, not one: a forged HIGH count still TRIGGERS an early tier action (bounded by the pre-existing count cap, TC-LIVENESS-056..058), but a forged `tripped=1` marker can also SUPPRESS an in-progress series by moving the cutoff forward past a genuine, still-relevant marker — a direction round 8's own tests never pinned. TC-LIVENESS-065/066 close that gap: in the default `GH_AUTH_MODE=token` topology a forged human `tripped=1` marker DOES suppress a genuine bot in-progress marker (the same documented, accepted residual class INV-105's round-14 finding already carries — token mode has no actor signal to add); in `GH_AUTH_MODE=app` the SAME forgery is rejected by the `authorKind` gate and the genuine marker still qualifies.

## Group M — round 9: count's authorKind gate + write-failure retry/notice (TC-LIVENESS-067..074)

[codex review, PR #472, round 9, 2 BLOCKING findings]

| ID | Finding | Fix | Covered by |
|----|---------|-----|------------|
| round 9 #1 | `_liveness_non_idempotent_count` had NO `authorKind` gate at all, unlike `_liveness_marker_digest`/`_liveness_prior_marker` (both app-mode-only gated) — in `GH_AUTH_MODE=app`, a human comment wrapping a known token correctly (e.g. `` `reason=liveness-timeout` ``) was masked as idempotent, undercounting genuine progress | Reclassify (not exclude) an untrusted match: a comment counts as progress if its body doesn't match the pattern, OR it matches but was posted by a human AND `GH_AUTH_MODE=app` — the mirror-image polarity of the digest's own gate (see D18) | TC-LIVENESS-067..069 |
| round 9 #2 | Every `itp_post_comment` call for the watchdog's own marker/report was swallowed with `\|\| true` — a lost MARKER write (which carries the counter/tier1-latch/`tripped` state, R4) silently resets the series to `count=1` next tick, or (for a lost `tripped=1` write) reopens the round-3/6/7/8 resume-re-trip bug | `_liveness_post_marker`/`_liveness_post_report` (`lib-dispatch.sh`) retry once; the marker helper additionally posts a loud `@REPO_OWNER` notice and returns 1 on persistent failure so the `tier1` branch can skip a now-pointless dependent report post | TC-LIVENESS-070..074 |

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-067 | `GH_AUTH_MODE=app`, a human's backtick-wrapped token comment alongside a genuinely new human comment | BOTH count as progress (count=2) — the untrusted match is reclassified as counted, not masked |
| TC-LIVENESS-068 | `GH_AUTH_MODE=app`, the SAME wrapped token from a bot/App identity alongside a genuinely new human comment | only the genuine comment counts (count=1) — a TRUSTED match is still trusted and excluded |
| TC-LIVENESS-069 | `GH_AUTH_MODE=token`, a human's wrapped-token comment alongside a genuinely new human comment | only the genuine comment counts (count=1) — token-mode behavior is byte-for-byte unchanged (the gate is a no-op there) |
| TC-LIVENESS-070 | `_liveness_post_marker`, first `itp_post_comment` attempt succeeds | exactly one call, no WARNING logged, returns 0 |
| TC-LIVENESS-071 | `_liveness_post_marker`, first attempt fails, retry succeeds | exactly two calls (both the marker body), no operator notice, returns 0 |
| TC-LIVENESS-072 | `_liveness_post_marker`, BOTH attempts fail | three `itp_post_comment` calls total (2 marker + 1 loud `@REPO_OWNER` notice), a WARNING is logged, returns 1 |
| TC-LIVENESS-073 | `_liveness_post_report`, BOTH attempts fail | exactly two calls (no third loud-notice call — reports don't escalate as loudly as markers), a WARNING is logged, returns 1 |
| TC-LIVENESS-074 | End-to-end through `_liveness_evaluate_issue`: the tick-6 tier-1 marker write persistently fails | the marker write is attempted twice (initial + retry); the dependent tier-1 report is never posted (short-circuited via `_liveness_post_marker ... \|\| return 0`) |

**[round 9 follow-up self-review]** D19's helpers can return 1, and a BARE call to either (no `&&`/`\|\|`/`if`) trips `set -e` (both `lib-dispatch.sh` and `dispatcher-tick.sh` run under `set -euo pipefail`) — aborting not just the current issue's evaluation but the ENTIRE dispatcher tick. This is caught by spawning a REAL `bash -euo pipefail` subshell, since the surrounding test harness sources everything under `set +e` (line 60) and cannot detect this class of regression at all.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-075 | `none` branch, real `set -e` subshell, persistent marker-write failure | `_liveness_evaluate_issue` returns normally (reaches `echo "REACHED_END"` after the call) rather than aborting |
| TC-LIVENESS-076 | `tier2` branch, real `set -e` subshell, persistent marker-write failure (report also fails, since `itp_post_comment` always fails in this probe) | same — reaches the end normally |
| TC-LIVENESS-077 | `tier1` branch, real `set -e` subshell, marker write SUCCEEDS but the report write persistently fails (a prior marker is seeded so the evaluation actually reaches `tier1`, not `none`) | reaches the end normally — isolates the tier1-report `\|\| true` guard specifically |
| TC-LIVENESS-078 | `tier2` branch, same shape as 077 but with a seeded count landing on the stall threshold | reaches the end normally — isolates the tier2-report `\|\| true` guard specifically |

## Group N — round 10: closed-span wrapper anchor (TC-LIVENESS-079..083)

[codex review, PR #472, round 10, 1 BLOCKING finding]

| ID | Finding | Fix | Covered by |
|----|---------|-----|------------|
| round 10 | Round 8's wrapper anchor required only the OPENING delimiter of a backtick/HTML-comment span immediately before the token, with no check that the span ever CLOSED — a human comment that opens a wrapper but never closes it (e.g. an unclosed backtick before a token mentioned in running prose) still satisfied the pattern identically to a genuine, well-formed marker/report line, reopening the SAME masking-real-progress / falsely-registers-in-digest bug via an unclosed span instead of a bare mention | Both `_LIVENESS_IDEMPOTENT_PATTERN`/`_LIVENESS_DIGEST_PATTERN` now require BOTH delimiters of the SAME span — `` `(TOKEN)[^`\n]*` `` for the backtick form, `` <!--[ \t]*(TOKEN)[^\n]*--> `` for the HTML-comment form (one capturing group per alternative, since Oniguruma has no branch-reset group syntax) — matching the exact producer shape (a closed, single-line span) rather than a mere look-alike opening. `_liveness_marker_digest`'s extraction updated from `.[-1]` to filtering the null out of each match's own result and taking the remaining value | TC-LIVENESS-079..083 |

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LIVENESS-079 | An UNCLOSED backtick span (079a) or an UNCLOSED HTML-comment opening (079b), each a human comment | does NOT reduce the non-idempotent count (still counts as genuine progress) |
| TC-LIVENESS-080 | The SAME two unclosed shapes, fed through `_liveness_marker_digest` | does NOT register the grammar as present in the digest |
| TC-LIVENESS-081 | A backtick span whose "closing" backtick is on the line AFTER an embedded newline (not a valid single-line Markdown code span) | still rejected — behaves the same as an unclosed span, not as a closed one |
| TC-LIVENESS-082 | A genuinely CLOSED backtick span (082a) and a genuinely closed single-line HTML-comment marker (082b) — the real producer shape, unchanged from round 8 | behaves exactly as before round 10: excluded from the count / registers in the digest |
| TC-LIVENESS-083 | Two comments, each carrying a DIFFERENT genuinely-closed grammar (`dispatcher-token:` and `dispatcher-convergence-breaker:`) | the digest extraction correctly joins both distinct tokens — the two-independent-capturing-groups rework didn't break multi-match extraction |
