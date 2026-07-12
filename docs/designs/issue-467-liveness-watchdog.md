# Design: generic liveness watchdog — two-tier no-op-tick escalation (issue #467)

## Problem

Five "permanent silent park" incidents have shipped point-fixes in six months (INV-105,
INV-111, INV-122, INV-123, INV-125): an issue's label is legal and stable (usually
`pending-dev`), but the dispatch decision layer falls into an absorbing loop that posts one
idempotent notice and then no-ops every tick — no retry, no `stalled`, no operator mention.
Each fix so far is a per-entry patch keyed on a specific park shape. The entry set is open
(new provider stop reasons, new CLI adapters, future marker fall-throughs), so enumeration
can never finish. This issue adds a class-level backstop: any non-terminal issue whose
*observable state fingerprint* stays unchanged for N ticks gets an operator-visible
escalation, and after M further unchanged ticks (M > N) is unconditionally transitioned to
`stalled`.

## Decisions

| # | Question | Decision |
|---|---|---|
| D1 | What counts as "no progress"? | A fingerprint over 4 observable components: active label, PR head SHA (or empty), a count of comments MINUS known-idempotent-notice matches, and a digest of which known marker grammars are present. Unchanged fingerprint across a tick = no-op tick. |
| D2 | How is the counter persisted across tick processes? | A single HTML-comment marker (`<!-- dispatcher-liveness-watchdog: issue=<N> fingerprint=<hash> count=<n> tier1=<0\|1> tripped=<0\|1> -->` — the `tripped` field added round 8, see D14), posted/updated every evaluated tick — mirrors INV-122's "computed and posted on EVERY round, not only on a trip" requirement. **[operator guidance, PR #472 round 6]** The posted comment is ALWAYS the BARE marker with no other text, on EVERY path — `none`, `tier1`, AND `tier2` alike (the pre-round-6 design embedded the marker as the first line of the tier1/tier2 report; round 6 splits them into two separate `itp_post_comment` calls, marker first) — mirroring the codebase's existing `emit_verdict_trailer` pattern (a separate bare comment whose body is JUST the trailer line, INV-105's round-13 fix) unconditionally rather than only below tier 1. Read back via a WHOLE-BODY structurally-anchored scan (round 6, see D10), gated by `authorKind != "human"` ONLY in `GH_AUTH_MODE=app` (round 6, see D11). |
| D3 | Does the watchdog's own bookkeeping comment count as progress? | No — its marker grammar (`dispatcher-liveness-watchdog:`) is added to the SAME idempotent-exclusion list the tier-1 comment needs (R1). Without this the watchdog would defeat itself: its own per-tick post would look like "a new comment" and the fingerprint's comment-count component would grow every tick, so two consecutive ticks would never look equal. |
| D4 | Which liveness predicate for the "wrapper alive" exemption? | Reuse, never reinvent: `_dispatch_marker_recent` (fresh-dispatch-marker check) + `pid_alive <kind> <issue>`, where `<kind>` is `issue` for a `pending-dev` candidate and `review` for a `pending-review` candidate — the SAME two primitives `may_stall_now` already composes, just parameterized by which wrapper kind is relevant to the label actually being evaluated (a pending-dev issue's live-wrapper question is about the DEV pid file, not the review one). |
| D5 | Threshold validation shape? | Mirror `_gate_breaker_threshold`'s regex-then-fallback-with-warning (stderr-only, never through `log()`, so the numeric capture isn't corrupted). `LIVENESS_STALL_TICKS` additionally validates `> LIVENESS_NOTICE_TICKS` (itself validated `>= 2` first); if the relative constraint fails even after each falls back to its own default, `LIVENESS_STALL_TICKS` falls back to its own default 18 (see D9 — an earlier revision clamped to `notice+1` instead, which is wrong). |
| D6 | Scope this iteration? | `pending-dev` and `pending-review` only (R2). `in-progress`/`reviewing` are already covered by Step 5b's DEAD-process scans; unifying the two mechanisms risks double-escalation and is deferred. |
| D7 | Already-stalled race? | Re-check `itp_read_task` labels for `stalled` immediately before the tier-2 transition (mirrors INV-122's `_gf_already_stalled` check) — a specific breaker may have won the race between candidate-list fetch and this evaluation. |
| D8 | [codex review, PR #472, BLOCKING #2] Resume-after-un-stall re-trip? | At the time this was fixed, the tier-2 report EMBEDDED its own marker (D2/R4 requires posting on every evaluated tick, including the trip tick), and D2's original "read back the LAST matching marker" had no cutoff — so the tick right after an operator removed `stalled` with the fingerprint otherwise unchanged would read that trip report's own high-count marker back and immediately re-trip. Fixed with `_liveness_prior_marker`: a cutoff-then-scan (mirrors `_review_cap_prior_marker`, itself mirroring INV-05's "Marking as stalled" cutoff) that excludes any marker at or before the latest "Liveness watchdog tripped" report (strict `>`). **[round 6 update]** D2 subsequently stopped embedding the marker at all — the marker is now ALWAYS a comment distinct from, and posted STRICTLY BEFORE, the report (never the reverse). The cutoff-then-scan mechanism here is UNCHANGED, but the reason the exclusion holds shifted: pre-round-6 it relied on the trip report's OWN embedded marker sharing the report's exact `createdAt` (equality at the cutoff); post-round-6 it relies on POST ORDER — the marker's `createdAt` is now strictly earlier than the report's, so it is excluded by the cutoff's strict `>` for the same structural reason, without depending on same-second timestamp coincidence. See D10/D11 for the anchor and authorKind changes this same round made alongside it. |
| D9 | [codex review, PR #472, BLOCKING #3] Invalid `stall <= notice` pair — clamp or fall back to default? | Fall back to the documented default (18), not an unconditional `notice+1` clamp. The requirements and `autonomous.conf.example` both say an inverted/invalid pair falls back to defaults; clamping to `notice+1` instead silently turns a config typo (e.g. `LIVENESS_NOTICE_TICKS=6 LIVENESS_STALL_TICKS=6`) into an aggressive 7-tick stall threshold — a misconfiguration becoming a false-stall path for otherwise-legitimate slow waits, exactly the failure mode two-tier escalation exists to avoid. One exception: a validly-configured `LIVENESS_NOTICE_TICKS >= 18` means the default 18 itself would fail `stall > notice`, so the fallback escalates to `notice+1` only in that case, preserving the invariant for every caller. |
| D10 | [operator guidance, PR #472 round 6] The whole-body anchor tightens beyond the round-5 forgery gap — does it also reject the OLD embedded-marker shape? | Yes, and that is now load-bearing rather than incidental. Switching the marker to `[[:space:]]*$` (whole-body, round 6) instead of `($\|\n)` (marker-then-optional-more, pre-round-6) means a comment shaped like the pre-round-6 tier1/tier2 embed (marker line, then report prose) is now REJECTED by the anchor outright — not merely "still correctly excluded by the cutoff" as before. This is safe specifically BECAUSE D2 (round 6) stopped ever producing that shape: a genuine marker's entire body is now always JUST the marker, so tightening the anchor to match introduces no false negative against genuine traffic, only against forgeries and (as a side effect) the retired pre-round-6 embed shape. |
| D11 | [operator guidance, PR #472 round 6] Round 2 (BLOCKING: unconditional `authorKind != "human"` makes the watchdog inert in token mode) and round 5 (BLOCKING: no `authorKind` gate lets a human forge a trip) pull in opposite directions — how are both satisfied? | They cannot both be satisfied by ONE unconditional gate; tightening/loosening a single `authorKind != "human"` check just re-opens whichever round's bug the other round's fix required. Resolved by mirroring the SAME two-part pattern already established at `classify_recent_review_verdict` ([#389]/[#393]): (1) the whole-body structural anchor (D10) carries authenticity in EVERY mode — this is what round 2 depends on continuing to work; (2) `authorKind != "human"` is layered on top ONLY when `GH_AUTH_MODE=app` (`_liveness_strict_author_flag`) — this is what closes round 5's gap, but ONLY in app mode, where the genuine wrapper's REST-derived `authorKind` (`user.type == "Bot"`, independent of whether `BOT_LOGIN` itself ever resolves) reliably distinguishes it from a human forger. The token-mode residual round 5 flagged (a human posting a byte-for-byte bare marker) remains open in token mode specifically BECAUSE token mode has no actor signal to add — this is the SAME class of accepted exposure INV-105's round-14 finding already documents elsewhere in this codebase, not a new gap. Its blast radius is bounded separately by D12's count cap. |
| D12 | [operator guidance, PR #472 round 6, defense-in-depth] Given D11 leaves a token-mode forgery residual open, is there anything cheap that bounds its damage? | Cap the count `_liveness_next_count` accepts at `LIVENESS_STALL_TICKS`. This is NOT a second authentication layer (a forger who can already construct a fingerprint-matching bare marker simply picks `count = stall_ticks - 1` and the cap does nothing to stop the next genuine no-op tick from tripping tier 2) — it bounds how far an absurd forged value (`count=999999999`) can propagate into the tier-action decision and the operator-facing report text, rather than surfacing verbatim as a meaningless, alarming number. Applied ONLY after the fingerprint-match gate — a mismatched fingerprint still resets to `count=1` regardless of any forged value, capped or not. |
| D13 | [codex review, PR #472, round 7 BLOCKING] D8's cutoff-then-scan correctly EXCLUDES a marker at-or-before the cutoff — but how is the cutoff itself detected, and is THAT detection forgeable? | Until round 7, the cutoff was `contains("Liveness watchdog tripped")` — an UNANCHORED substring test. Any comment merely MENTIONING that bare phrase anywhere in its body (e.g. a human collaborator quoting or discussing a past trip in prose, with zero report structure) satisfied it and became the cutoff, excluding the genuine earlier marker and permanently resetting a still-frozen issue's series to `count=1` — letting a real park dodge tier 2 forever, the exact bug class this issue exists to close. Fixed by anchoring the cutoff match to `startswith($heading)` against a new single-sourced constant, `_LIVENESS_TIER2_HEADING` (`lib-liveness.sh`) — the comment's body must OPEN with the report's exact heading line, mirroring the posture D10's marker anchor already takes. The TIER2REPORT heredoc (`lib-dispatch.sh`) renders from this SAME constant rather than a second hand-typed copy, so producer and detector can never drift apart again — which is exactly how this gap opened: D10 tightened the MARKER's own anchor to whole-body in round 6, but the CUTOFF detector's match stayed an unanchored substring test on a separately-typed heading string. |
| D14 | [codex review, PR #472, round 8 BLOCKING #1] D13's `startswith($heading)` anchor closed round 7's `contains()` gap — but is a hand-typed heading-text pattern EVER safe as a cutoff signal, no matter how tightly it's anchored? | No. Round 8 found `startswith()` was STILL forgeable in the default `GH_AUTH_MODE=token` topology: an unauthenticated comment that simply OPENS with the exact heading line (trivial to copy) satisfies the anchor identically to the genuine report, moving the cutoff forward and reintroducing the SAME "real park dodges tier 2 forever" bug D13 fixed one instance of. The pattern across rounds 3→6→7→8 is that a SEPARATE, independently-typed text pattern carries no authentication of its own regardless of how it's anchored — round 6→7's own gap (marker anchor tightened to whole-body while the cutoff detector stayed on a less-anchored, separately-typed string) is direct evidence the two mechanisms drift apart because they ARE two mechanisms. The structural fix: add a `tripped=<0\|1>` FIELD to the marker itself (`_liveness_marker`'s 5th arg, default 0; set to 1 only on the tier-2 marker), so the cutoff computation reuses the EXACT SAME whole-body anchor and EXACT SAME `authorKind` filter as the prior-marker scan it feeds — there is no second pattern left to drift out of sync with or forge independently of the marker's own authentication. `_LIVENESS_TIER2_HEADING` remains as the report's operator-facing display heading only; no detector reads it as of this round. |
| D15 | [codex review, PR #472, round 8 BLOCKING #2] Are `_LIVENESS_IDEMPOTENT_PATTERN`/`_LIVENESS_DIGEST_PATTERN` themselves forgeable? | Yes, pre-round-8: both are bare alternations matched via `test($pat)` (a substring test), so a human comment merely DISCUSSING or QUOTING a token in prose (e.g. "I saw reason=liveness-timeout mentioned somewhere", or "quoting the marker: dispatcher-convergence-breaker: issue=1 head=abc") satisfied the pattern identically to a genuine wrapped marker/report — corrupting the count in one direction (wrongly excluding the genuinely-new prose comment) and the digest in the other (wrongly reporting a grammar as present). Every genuine producer in this codebase wraps its token in exactly one of two ways — a backtick-fenced code span or the literal opening of an HTML comment — never bare in prose. Fixed by requiring one of those two wrappers immediately before the token (`` (?:`\|<!--[ \t]*) ``, non-capturing so it composes cleanly with the digest's own extraction group). No genuine producer is affected; only bare-prose mentions are now excluded. |
| D16 | [codex review, PR #472, round 8 BLOCKING #3] Does a `fetch_pr_for_issue` transport failure ever get misread as "no PR"? | Yes, pre-round-8: the call site used `pr_info=$(fetch_pr_for_issue ...) \|\| pr_info=""`, collapsing "the lookup transiently failed" (nonzero rc) and "this issue genuinely has no PR" (rc=0, empty result) into the same `current_head=""`. On an issue that DOES have a PR, a transient `gh` API blip would silently reset the counter on the very tick meant to detect a park, masking it. Fixed by checking the rc BEFORE reading the head: a nonzero rc defers the entire tick (mirrors the `itp_list_comments` preflight's existing fail-toward-defer posture) rather than proceeding with a fabricated empty head. `resolve_pr_for_issue`/`chp_find_pr_for_issue` are already fail-closed on transport error, so this is a call-site fix, not a leaf-contract change. |
| D17 | [codex review, PR #472, round 8 BLOCKING #4] Do the threshold readers' invalid-config warnings ever reach the dispatcher's own log? | No, pre-round-8: `run_liveness_watchdog` piped both readers' stderr straight to `/dev/null`. The fallback still applied correctly (a misconfigured value still falls back to its documented default), but SILENTLY — R5 requires the warning, and a real misconfiguration was undiagnosable from the dispatcher's own log output. Fixed by capturing each reader's stderr via a `mktemp` file (mirroring `ci_is_green`'s existing capture-then-relog pattern, Step 5a) and re-emitting any non-empty warning through `log()`. |
| D18 | [codex review, PR #472, round 9 BLOCKING #1] `_liveness_marker_digest`/`_liveness_prior_marker` both gate on `_liveness_strict_author_flag` — should `_liveness_non_idempotent_count` too? | Yes, but the gate must work in the OPPOSITE direction from the digest's. Pre-round-9, `_liveness_non_idempotent_count` had NO authorKind gate at all: in `GH_AUTH_MODE=app`, a human comment that merely wrapped a known token correctly (e.g. `` `reason=liveness-timeout` ``) satisfied the round-8 wrapper anchor and was masked as an idempotent notice, undercounting genuine human progress. The digest's gate EXCLUDES an untrusted match from registering grammar PRESENCE (a false "a breaker fired" signal); the count's gate must instead RECLASSIFY an untrusted match as counted progress (an untrusted "this is idempotent" claim must not silently drop the comment from consideration — it should count as real progress, the opposite polarity). Implemented as `select((.body | test($pat) | not) or (($strict == "1") and ((.authorKind // "human") == "human")))` — in `GH_AUTH_MODE=token` (`strict=="0"`) the added disjunct is always false, so token-mode behavior (and its documented residual) is byte-for-byte unchanged. |
| D19 | [codex review, PR #472, round 9 BLOCKING #2] Should a marker/report `itp_post_comment` failure keep being swallowed with `\|\| true`? | No, not for the MARKER — it IS the counter/tier1-latch/`tripped`-field persistence mechanism (R4), so a silently lost write means the next tick reads back nothing, resets `count=1` under an unchanged fingerprint, and the series can never advance — a self-inflicted instance of the exact bug class this watchdog exists to close. Losing a `tripped=1` marker specifically also reopens the round-3/6/7/8 resume-re-trip bug via a lost write rather than a design gap. Fixed with two new call-site wrappers in `lib-dispatch.sh`: `_liveness_post_marker` retries once, and on persistent failure additionally posts a loud best-effort `@REPO_OWNER` notice and returns 1 so the `tier1` branch can skip its dependent report post (posting the escalation prose while the counter never actually advanced would just repeat every tick). `_liveness_post_report` retries once but does not escalate as loudly — a lost report costs only operator-facing text, since state is carried entirely by the (independently retried) marker posted first. The `tier2` branch does NOT gate its report on the marker's success, since `label_swap` already committed the irreversible `stalled` transition before either post — the report is posted best-effort regardless. |
| D20 | [codex review, PR #472, round 9 follow-up self-review] D19's helpers can now return 1 — does every call site handle that safely under this file's `set -euo pipefail`? | Not in the first cut: a BARE call to a function that can return 1 trips `set -e` and aborts the calling function (and, propagating up, the entire dispatcher tick) — exactly the failure mode `\|\| true` previously prevented, just reintroduced one level deeper. The `none` branch's marker post, the `tier1` branch's report post, and the `tier2` branch's marker AND report posts were all initially left as bare calls (only the `tier1` marker's intentional `\|\| return 0` was safe, since that IS a `set -e`-exempt context). Fixed by appending `\|\| true` to all four of those call sites — the helper's retry still runs, but a persistent failure degrades to "this tick's audit trail is incomplete" instead of aborting the tick. Caught by a fresh self-review pass BEFORE this round was pushed; pinned by TC-LIVENESS-075..078, which spawn a real `bash -euo pipefail` subshell — the pre-existing test harness sources everything under `set +e` and cannot detect this class of bug at all. |

## Fingerprint

```
_liveness_canonical(label, head, non_idempotent_count, marker_digest) = "label|head|count|digest"
_liveness_fingerprint(...) = sha1sum(canonical) | cut -c1-12   (cksum fallback, mirrors convergence_trailer_hash)
```

`non_idempotent_count` = total comments MINUS comments matching any of a fixed grep-able
pattern list (`_LIVENESS_IDEMPOTENT_MARKERS`) covering `stale-verdict:`, `INV-12-completed:`,
`INV-12-no-pr-fresh-dev:`, `INV-35-fresh-dev:`, `no-progress-substantive(-attempt)?:`,
`non-actionable-finding:`, `self-heal-lost-session:`, `self-heal-non-substantive:`,
`crashed-session-retry:`, `dispatcher-convergence-breaker:`, `dispatcher-gate-fail-breaker:`,
`dispatcher-liveness-watchdog:` (this watchdog's own marker, D3), and — **[round 6]** since
the tier1/tier2 reports are now separate comments from the marker (D2) —
`reason=liveness-no-progress`/`reason=liveness-timeout` (the report text itself, so its own
posting never registers as progress against itself, the same self-pollution class D3 fixes
for the marker). `marker_digest` scans the SAME pattern list MINUS the watchdog's own marker
grammar and joins the sorted subset actually present (`authorKind`-gated via
`_liveness_strict_author_flag`, D11 — app-mode-only) — a NEW grammar appearing changes the
digest even though it may already be excluded from the count (e.g. a FIRST
`self-heal-lost-session:` marker is progress; the SAME one persisting next tick is not).
**[round 8, D15]** Both pattern lists require a leading wrapper anchor
(`` (?:`|<!--[ \t]*) ``) immediately before every token — a backtick code span or an
HTML-comment opening, the two shapes every genuine producer already uses. Without it,
a bare-prose mention of any token (a human discussing or quoting it, no wrapper at all)
matched identically to the genuine wrapped form.

## Counter + tier action (pure)

```
_liveness_next_count(stored_marker, fingerprint, stall_ticks?) = min(stored.count+1, stall_ticks) if stored.fingerprint==fingerprint else 1
                                                                  (stall_ticks omitted -> uncapped, D12)
_liveness_next_tier1(stored_marker, fingerprint)  = stored.tier1   if stored.fingerprint==fingerprint else 0
_liveness_tier_action(count, tier1, notice, stall):
  count >= stall                    -> "tier2"
  count >= notice AND tier1 == 0    -> "tier1"
  else                               -> "none"
```

A fingerprint change resets both count and the tier1 latch — a fresh episode gets a fresh
tier-1 warning even on a HEAD/label that previously tripped tier 1 before recovering.

## Exemptions (R2), evaluated in order, cheapest first

1. `was_just_dispatched` (JUST_DISPATCHED, already exported by the time Step 6 runs).
2. `is_within_grace_period` (INV-18 dispatch-marker TTL).
3. `_liveness_wrapper_alive` (D4).
4. `itp_list_comments` transient failure → skip this tick (fail-toward-defer, mirrors
   INV-125's Part-2 preflight fix — an empty/failed read must never be misread as "no
   comments exist").
5. **[round 8, D16]** `fetch_pr_for_issue` transport failure → skip this tick, the SAME
   fail-toward-defer posture as #4. Distinct from "genuinely no PR bound to this issue"
   (rc=0, empty result) — that case still yields an empty head component normally.

`list_pending_dev()`/`list_pending_review()` (re-fetched fresh at Step 6, AFTER Steps 2-5 may
have dispatched some of these issues away) already exclude `approved`/`stalled` — the
terminal-label exemption is structural, not a separate runtime check.

## Side effects — comments per evaluated issue per tick

[operator guidance, PR #472 round 6] The marker is now ALWAYS its own separate comment,
posted BEFORE any human-readable report — never embedded as the report's first line. `none`
still posts exactly one comment (the bare marker); `tier1`/`tier2` each post exactly TWO
(the bare marker, then the report) — never a single comment combining both.

| Action | Label transition | Comment(s), in post order |
|---|---|---|
| `none` | none | (1) bare marker only (D2/D3) |
| `tier1` | none | (1) bare marker (`tier1=1`), THEN (2) human-readable escalation + `@REPO_OWNER` |
| `tier2` | `pending-{dev,review} -> stalled` (transition FIRST, mirrors INV-105's TOCTOU fix) | (1) bare marker, THEN (2) structured `reason=liveness-timeout` report |

## Guards preserved

No changes to any existing breaker's threshold, fingerprint, or marker (INV-105/111/122/123/125
untouched). All I/O through existing `itp_*`/`chp_*` verbs (INV-91). No new liveness predicate
(D4 composes two existing ones). `in-progress`/`reviewing` are out of scope (D6).

## New invariant

Claims **INV-128** (drafted as INV-127 at design time; renumbered on rebase after origin/main's
concurrently-merged #470 independently claimed INV-127 first — see the invariants.md entry's
numbering note for the full history).
