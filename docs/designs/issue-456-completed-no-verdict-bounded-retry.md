# Design: bound the `verdict=none` completed-session park with retry-then-stall (issue #456)

## Problem

`handle_completed_session_routing()` (`lib-dispatch.sh`, [INV-35](../pipeline/invariants.md#inv-35-review-aware-resume-routing-for-completed-sessions)) routes a `pending-dev` issue whose prior dev session reached a terminal `completed` state (`stop_reason=end_turn`). It classifies the most recent post-session review verdict and branches:

| verdict | action | bound |
|---|---|---|
| `passed` | no-op (race window) | n/a — Step 0 reconciles |
| `failed-substantive` | escalation ladder (see below), else fresh `dev-new` | `MAX_RETRIES` ([INV-05](../pipeline/invariants.md#inv-05-retry-counter-cutoff-rule)) for the dev-new leg; the ladder itself escalates to `mark_stalled` independently of `MAX_RETRIES` |
| `failed-non-substantive` | flip to `pending-review` | `REVIEW_RETRY_LIMIT`, then `mark_stalled` |
| **`none`** | post `INV-12-completed:<sid>` operator-handoff comment | **none — permanent silent park** |

The `failed-substantive` row is not a single action — it is a **four-stage escalation ladder** (`lib-dispatch.sh:1672-2040`) that only falls through to a fresh `dev-new` (Branch C) after three earlier stages find no reason to stop:

- **Branch A** ([INV-85], bot-unfixable): same-HEAD + the dev agent reported a PR-metadata 403 it structurally cannot resolve → `mark_stalled`, zero `dev-new`.
- **Branch B** ([INV-85], no-progress): same-HEAD + a prior `dev-new` already ran against this exact HEAD and produced no new commit → `mark_stalled`, zero further `dev-new`.
- **Branch B′** ([INV-92], non-actionable): every blocking finding was classified `dev-actionable=false` → `mark_stalled` proactively, before ever burning a dev-new attempt.
- **Branch B″** ([INV-105], convergence breaker): N rounds of dev-resume against a frozen HEAD with zero new commits → `mark_stalled` with a structured non-convergence report.
- **Branch C**: only once none of A/B/B′/B″ fire — fresh `dev-new`, bounded by `MAX_RETRIES` via the existing retry-comment count.

Every stage of this ladder exists because a flat `MAX_RETRIES` counter alone was previously proven insufficient for `failed-substantive` — see the ladder's own commit history (INV-85 closes #274, INV-92 closes #298, INV-105 closes #297): each was added after `MAX_RETRIES` alone let a doomed retry loop churn until the counter tripped, wasting cycles the ladder now short-circuits.

`none` means "no review verdict comment exists newer than the session's end-of-turn" — in practice this is what happens when the dev agent ends its turn cleanly but **never opens a PR** (so no review ever ran; see the corrected Q1 below for the precise classifier semantics). The wrapper itself labels this "for retry" (`autonomous-dev.sh`'s "Agent exited successfully but no PR was created. Moving to pending-dev for retry." comment, mirrored in `state-machine.md`'s transition table), but Step 4's completed-session gate then refuses to act on it ever again — it is the only branch of the four with **zero** bound of any kind, not even the weak flat-counter bound `failed-substantive`'s Branch C alone would give it.

**Live reproduction (issue #456, this repo, 2026-07-10)**: a `dev-new` dispatch ran ~19 minutes, made real code changes in a worktree (fix + passing tests + doc update), but ended its turn without committing/pushing/opening a PR. The wrapper correctly flipped `in-progress → pending-dev`. The next tick classified `verdict=none` (no PR ⇒ no review), posted the one-time `INV-12-completed:<sid>` notice, and has left the issue silently parked in `pending-dev` since — no `stalled` label, no further comment, no automatic recovery. Discovered only because a human happened to check the issue.

## Why this matters

`pending-dev` is an *active* dispatcher state — every other issue in it is either being worked on or bounded toward `stalled`. An issue that reaches `none` and never gets a PR sits in `pending-dev` indefinitely with zero operator-visible signal beyond a comment that (by design) never repeats. There is no `stalled` label to page an operator, no metric, nothing — the only way to notice is manual GitHub polling. This defeats the purpose of the autonomous pipeline for exactly the failure mode most likely to occur without human awareness: an agent that quietly stops short of finishing.

## Decisions

| # | Question | Decision | Rationale |
|---|---|---|---|
| Q1 | Is `verdict=none` ever a case that genuinely needs a human, not a retry? | **Yes, but only when a PR exists — and the reason is narrower than it first looks.** `classify_recent_review_verdict` (`lib-dispatch.sh:1105-1237`) returns `none` when, within the actor+timestamp window, **no qualifying comment is found at all** (`newest_body` empty → `return 0` at line ~1187) — this is the classifier's *sole* `none`-return path. Separately, when a qualifying comment IS found but lacks a trailer, the classifier's **legacy fallback** (`trailer_line` empty → `printf -v verdict failed-substantive`, line ~1198) returns `failed-substantive`, not `none`. Note this fallback only fires when a qualifying comment exists in the first place — in the dispatcher's normal (non-`BOT_LOGIN`) topology the actor predicate requires the comment body itself to match the anchored trailer regex (`lib-dispatch.sh:1172-1180`), so a PR-exists comment that isn't from a recognized reviewing actor, or was never posted at all, still yields `none` via the "no qualifying comment" path — not via some second `none`-returning branch. The precise statement is: **every `none` is "no qualifying comment found"**; a PR can exist and still land here (crashed review wrapper, actor-predicate mismatch, review never ran) exactly as easily as "no PR was ever created" can. The load-bearing distinction this design needs is therefore not about classifier internals at all, but simply **"did a PR ever get created."** When a PR exists, something already should have gone through the review pipeline — a human should look, exactly as INV-12's original operator-handoff intent says. When no PR exists, the dev agent simply hasn't produced anything for review to look at yet, which is a plain, bounded dev-retry situation identical in shape to `failed-substantive`. |
| Q2 | Reuse `MAX_RETRIES` or add a new counter? | **Reuse `MAX_RETRIES` / `count_retries`.** This is a dev-side failure to produce a PR — mechanically the same class of thing `failed-substantive`'s Branch C already retries under `MAX_RETRIES`. A separate counter (like `REVIEW_RETRY_LIMIT`) exists only where the retry is NOT the dev agent's fault (flaky bot/CI) — that justification doesn't apply here. |
| Q3 | Does the new branch need an escalation ladder analogous to `failed-substantive`'s A/B/B′/B″? | **No — and this needs to be argued precisely, not with a single blanket reason.** The ladder's stages don't all share one precondition: Branches A, B, and B″ key off a **stable HEAD to compare against** (same-HEAD + prior-attempt-marker, or a frozen-HEAD round count) — they exist to detect "the dev agent keeps trying and produces the same (non-)result against the same code state," which only becomes observable once a PR/commit exists to compare. Branch B′ is different: it doesn't compare HEADs at all — it fires purely on a `dev-actionable=false` trailer flag from the classifier. Branch B′ can't apply pre-PR for a more upstream reason: **no PR means no review ever ran, which means no verdict trailer was ever posted, which means there is no `dev-actionable` flag to test in the first place** — the precondition is "a review verdict trailer exists," not "a HEAD exists." So the correct statement is: Branches A/B/B″ are inapplicable because there is no HEAD to compare; Branch B′ is inapplicable because there is no review trailer to classify. Both preconditions are structurally absent before a PR exists, for their own distinct reasons. Given that, a flat `MAX_RETRIES` counter is not a *weaker* protection than the ladder for this case — it is the **only protection that is meaningful**, because none of the ladder's signals (stuck-on-the-same-artifact, or a classified non-actionable finding) can exist without an artifact or a verdict to classify. This is a bound-by-volume answer, not a convergence answer: it cannot distinguish "the same underlying bug repeating" from "three different bugs, each requiring a fresh attempt" the way Branch B″'s frozen-head+trailer matching does for the PR-exists case. That is an accepted, explicit tradeoff, not an oversight — unlike `failed-substantive`'s pre-ladder state, a no-PR retry that keeps failing is not silently invisible: every attempt posts its own "Agent exited successfully but no PR was created" comment (counted, per the fix below) AND its own `INV-12-no-pr-fresh-dev:<sid>` marker, so an operator watching the issue sees N distinct, timestamped attempts before `MAX_RETRIES` trips (small by default, e.g. 3), not a single ambiguous stall. |
| Q4 | How does a fresh `dev-new` differ from the `failed-substantive` Branch C (`INV-35-fresh-dev`) dispatch? | **Distinct marker text only — the dispatch mechanics are a byte-for-byte mirror of Branch C** (see Fix section below). Use `INV-12-no-pr-fresh-dev:<sid>` (not `INV-35-fresh-dev:<sid>` — no review failed, reusing that language would misrepresent the cause in the audit trail). No per-HEAD attempt marker (there is no HEAD) — `MAX_RETRIES` is the sole backstop, per Q3. |
| Q5 | Does this need its own idempotency/dispatch bookkeeping? | **No new primitives — but the ORDER and error-handling must match Branch C exactly, not a simplified paraphrase of it.** See the Fix section: acquire-marker-before-any-side-effect, errexit-safe label/token guard, explicit dispatch-rc handling (75/nonzero/0), and fail-closed log truncation are all load-bearing, not optional simplifications, because this router is reachable from an `if` condition (INV-98 delegation) where bash suppresses `errexit`. |

### Rejected alternatives

- **B. Leave `none` unbounded, but add a `stalled`-after-N-ticks timer keyed on issue age.** Rejected: conflates two different signals (retry attempts vs wall-clock age) and doesn't distinguish "dev agent keeps trying and failing to open a PR" from "dev agent tried once, a human should look." `MAX_RETRIES` is already the pipeline's existing vocabulary for "how many dev attempts before we give up" — introducing a second, time-based cutoff for exactly one branch adds a new operator-facing concept for no benefit.
- **C. Treat ALL `none` verdicts (PR-exists case included) the same as no-PR.** Rejected per Q1 — a PR-exists `none` means a review should have run and didn't (crash, actor mismatch, etc.); blindly dispatching `dev-new` against a PR nothing has reviewed yet would skip review entirely, not retry development. The PR-exists branch keeps today's fail-closed operator handoff.

## Existing adjacent/overlapping path this design must NOT duplicate

`handle_pending_dev_pr_exists()` (`lib-dispatch.sh:3411` onward) already contains an **independent self-heal branch** ([INV-111], `lib-dispatch.sh:~3557-3596`) that also dispatches a bounded `dev-new` when `classify_recent_review_verdict` returns `none` (its `case ... *)` catch-all explicitly comments "failed-substantive ... or 'none' ... fail OPEN"). That branch's precondition is **PR exists + same HEAD as last review + no resolvable dev session id + no live wrapper** — i.e. "a PR exists, was reviewed, but we lost track of the session that should resume it." This is disjoint from the branch this design adds (**no PR exists at all**), so there is no double-dispatch risk (`acquire_dispatch_marker`/[INV-108] would catch a race even if the preconditions overlapped, but they structurally don't: one requires a PR, the other requires its absence). The two branches use different markers (`self-heal-lost-session:<head>` vs. this design's `INV-12-no-pr-fresh-dev:<sid>`) precisely because they are answering different questions ("can't find the session for this reviewed PR" vs. "no PR was ever produced") — implementers must not merge or confuse them.

## Overlap with INV-45 (`needs_open_pr_only`)

`autonomous-dev.sh:502` (`needs_open_pr_only`, closes #178) already exists for the adjacent case "a dev session pushed a branch but never got to `gh pr create`" — it's checked on every dev dispatch and, when true, injects a fast-path prompt telling the agent to skip straight to `gh pr create` instead of re-doing the whole task. This design's failure mode is broader: the #456 reproduction shows a session that never pushed anything at all (not "pushed but forgot to open a PR"). The two mechanisms are complementary, not competing: INV-45 is a wrapper-side prompt optimization that fires on the *next* dispatch regardless of how that dispatch was triggered; this design is the dispatcher-side bound that decides *whether* a next dispatch happens at all. A `dev-new` dispatched by this design's new branch still benefits from INV-45's fast path if the failed attempt happened to leave a pushed branch behind. No changes to INV-45 are needed; this design's dev-new dispatch is just another caller that inherits it for free.

## Fix: no-PR sub-branch of `verdict=none`, bounded by `MAX_RETRIES`

Inside `handle_completed_session_routing()`'s `none)` case:

1. Check whether a PR exists for the issue (`fetch_pr_for_issue "$issue_num" "number"` — cheap, matches the existing `handle_pending_dev_pr_exists` call shape at `lib-dispatch.sh:3414`). `fetch_pr_for_issue` delegates to `resolve_pr_for_issue`, which returns a **nonzero exit** on a transport/read failure, distinct from empty output on a genuine "no PR." **A nonzero exit must be treated the same as "PR exists" (fail closed to the operator handoff), never as "no PR"** — collapsing a transient read failure into the no-PR branch would risk dispatching a fresh `dev-new` against an issue that actually has a PR the lookup just failed to see.
2. **PR exists** (or the lookup failed transiently) → unchanged. Post `INV-12-completed:<sid>` exactly as today — a review should have run against this PR and something prevented it (crash, actor-predicate mismatch, etc.); fail closed to the operator, as INV-12 originally intended.
3. **No PR exists** → mirror `failed-substantive`'s Branch C (`lib-dispatch.sh:1988-2060`) **exactly**, substituting only the marker text and dropping the per-HEAD attempt-marker write (Q3/Q4 — there is no HEAD):
   a. `acquire_dispatch_marker "$issue_num" "dev-new"` ([INV-108]) — **first, before any other side effect.** A losing acquire returns cleanly with no side effects; next tick retries.
   b. Post `INV-12-no-pr-fresh-dev:<sid>` (idempotent, same one-shot-per-session-id pattern as `INV-35-fresh-dev:<sid>`) — **after** the acquire, not before.
   c. `_reset_session_log "$issue_num"` — **mandatory, fail-closed, not optional.** If this session's dev-new gets deferred (rc=75) or its wrapper dies before writing a fresh result line, the OLD session's stale `{"type":"result", ..., "terminal_reason":"completed"}` line remains in `/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log`. The next tick's `is_session_completed` would re-detect `completed` against that stale line, `classify_recent_review_verdict` would again return `none` (still no PR), and this branch would fire again — but the wrapper never actually ran, so no fresh "no PR" WARNING comment gets posted and the retry silently escapes the counting fix below. This is the exact one-level-down unbounded loop this design exists to close. On truncate failure: post an operator-actionable comment, `release_dispatch_marker`, `return 0` — do not dispatch (mirrors Branch C's own truncate-failure handling verbatim).
   d. **Errexit-safe guard** around the label/token pre-spawn steps — this router is reachable via `if handle_pending_dev_pr_exists ...` ([INV-98] delegation), and bash suppresses `errexit` inside a function called from an `if` condition. Guard explicitly:
      ```
      if ! label_swap "$issue_num" "pending-dev" "in-progress" ||
         ! post_dispatch_token "$issue_num" "dev-new"; then
        release_dispatch_marker "$issue_num" "dev-new"
        return 0
      fi
      ```
   e. Capture the dispatch return code explicitly and branch on it — `is_dispatch_deferred_rc` (rc=75, [INV-119] back-pressure) reverts via `handle_dispatch_deferred` (which itself reverts the label swap); any other nonzero releases the marker and returns; only rc=0 proceeds:
      ```
      local _dispatch_rc=0
      dispatch dev-new "$issue_num" || _dispatch_rc=$?
      if is_dispatch_deferred_rc "$_dispatch_rc"; then
        handle_dispatch_deferred "$issue_num" "dev-new" "in-progress" "pending-dev"
        return 0
      elif [ "$_dispatch_rc" -ne 0 ]; then
        release_dispatch_marker "$issue_num" "dev-new"
        return 0
      fi
      ```
   f. `dispatch_marker_confirm_launched "$issue_num" "dev-new"` — only after a confirmed rc=0 launch.
   g. **No per-HEAD attempt marker** (per Q3/Q4 — there is no HEAD to key one on). `MAX_RETRIES` alone is the backstop, made real by the counting fix below.
4. Caller (`dispatcher-tick.sh` Step 4 / the [INV-98] same-HEAD delegation in `handle_pending_dev_pr_exists`) is unaffected — it already treats `handle_completed_session_routing`'s return as terminal for this tick (`continue` / `return 0`).

Steps 1-3 above are not sequential — they are the branches of a single `if fetch_pr_for_issue ...; then <existing INV-12-completed body, unchanged>; else <new dev-new body>; fi` wrapped around the `none)` case's current contents. Step 2 is the **existing code, unmodified**, moved inside the `if` arm; step 3 is entirely new code in the `else` arm. An implementer should read this as "wrap, don't append."

### The counting gap (must ship in the same PR)

`count_retries()` (`lib-dispatch.sh:~614`) sums `count_agent_failures` and `count_dispatcher_crashes`. `count_agent_failures` (`lib-dispatch.sh:667-693`) matches **only** comments containing the literal string `"Agent Session Report (Dev)"`, with exit-code exclusions (0/143/137) applied on top.

The wrapper's "Agent exited successfully but no PR was created. Moving to pending-dev for retry." text (`autonomous-dev.sh:~1097`) is **NOT part of the Session Report comment** — it is a second, independent plain-text WARNING comment, posted separately (both fire unconditionally from the same `cleanup()` trap: the Session Report always posts per [INV-03]; the "no PR was created" WARNING posts additionally, only on the exit-0-no-PR path). Because `count_agent_failures`'s regex requires the literal "Agent Session Report (Dev)" substring, it never matches the WARNING comment at all — **not because of the exit-code exclusion, but because the WARNING comment is a different piece of text entirely.** The net effect the original design draft described is still correct (today, an issue that keeps ending its turn without a PR consumes zero retry budget), but the mechanism is: this event has no matching regex anywhere in `count_retries`, full stop — it isn't being excluded by an exit-code check, it was simply never counted by anything.

Fix: add a new, independent sub-count — e.g. `count_no_pr_attempts()` — that matches the WARNING comment's literal text ("Agent exited successfully but no PR was created") newer than the same `last_stalled_at` cutoff `count_agent_failures`/`count_dispatcher_crashes` already compute, and sum it into `count_retries` alongside the existing two terms. This must be a **new, separate function/regex**, not an edit to `count_agent_failures`'s existing pattern — the two comments are different text on different lines and conflating them in one regex would be fragile and misleading to a future reader.

`count_retries()` currently gates `count_dispatcher_crashes` behind `_agent_started_since_stall` (cold-start false-positive suppression per [INV-18]) but always includes `count_agent_failures` unconditionally. The new `count_no_pr_attempts` should be summed **unconditionally, alongside `count_agent_failures`, not behind the `_agent_started_since_stall` gate** — the WARNING comment only ever posts on the `AGENT_RAN=true` path (the startup-failure branch exits before reaching it), so a no-PR attempt always implies the agent genuinely started; gating it defensively behind `_agent_started_since_stall` would be harmless but redundant, and omitting it from the sum entirely would reopen the counting gap this fix exists to close.

**`mark_stalled`'s operator-facing breakdown must also be updated** (`lib-dispatch.sh:~857`, the "Marking as stalled" comment text — exact current wording: `"(${MAX_RETRIES} failed attempts: ${agent_failures} agent failures + ${counted_dispatcher_crashes} dispatcher-detected crashes; ${false_positives} dispatcher false positives suppressed per #99)"`). Adding a new counted signal without updating this string would make the posted arithmetic silently wrong (the displayed breakdown would not sum to the actual `count_retries` value that triggered the stall). Add the new count as an additional named term in that string.

**Cutoff/reset semantics ([INV-05](../pipeline/invariants.md#inv-05-retry-counter-cutoff-rule)) are unaffected**: the new sub-count uses the exact same `last_stalled_at` cutoff the existing two terms already use, so the retry counter still resets when the issue is unstalled (label removed), consistent with every other counted signal. Session-id churn (each fresh `dev-new` mints a new session id) does not hide a loop: `count_retries` is cutoff-based, not session-scoped, so N attempts across N different session ids within one non-stalled cycle still sum correctly — this only holds, however, if the log-truncate step (3.c above) is honored; a skipped truncate is exactly the gap that would let an attempt escape counting.

## Reachability / regression matrix

| Dev session state | Verdict | PR exists? | Action | Consumes `MAX_RETRIES`? |
|---|---|---|---|---|
| `completed` | `none` | no | fresh `dev-new`, Branch-C-mirror (new: `INV-12-no-pr-fresh-dev:<sid>`) | **yes (new)** |
| `completed` | `none` | no, retry count ≥ `MAX_RETRIES` | `mark_stalled` (existing Step 4 exhaustion gate — unchanged, now reachable for this branch) | n/a |
| `completed` | `none` | yes | `INV-12-completed:<sid>` operator handoff (unchanged) | no |
| `completed` (via [INV-98] same-HEAD delegation), PR exists + same HEAD, no resolvable session id, no live wrapper | `none` or `failed-substantive` | yes | pre-existing [INV-111] self-heal `dev-new` (`self-heal-lost-session:<head>`, unchanged, disjoint precondition — see "Existing adjacent path" above) | yes (unchanged) |
| `completed` | `passed` | — | no-op (unchanged) | no |
| `completed` | `failed-substantive` | — | escalation ladder A/B/B′/B″, else fresh `dev-new` Branch C (INV-35, unchanged) | yes for Branch C only (unchanged) |
| `completed` | `failed-non-substantive` | — | flip to `pending-review` (INV-35, unchanged) | no (unchanged, `REVIEW_RETRY_LIMIT`) |

The `MAX_RETRIES` exhaustion check runs unconditionally at the top of `dispatcher-tick.sh` Step 4 (`count_retries` / `count_retries -ge MAX_RETRIES` → `mark_stalled --at-cap`), **before** `handle_pending_dev_pr_exists` / `handle_completed_session_routing` are ever reached. With `MAX_RETRIES=3` and counting fixed: the **first** no-PR completion (from the original, non-`none`-branch dispatch) posts the WARNING comment and counts as attempt 1 before this branch ever runs; this branch's own dispatches are attempts 2 and 3; the tick after attempt 3's WARNING comment lands, Step 4's pre-flight gate sees `count_retries == 3 >= MAX_RETRIES` and stalls **before** entering the branch again. So the observable sequence for `MAX_RETRIES=3` is **2 branch-dispatched `dev-new` attempts, then stall** — not 3; any test/implementation must pin this exact arithmetic, not assume the branch itself dispatches all `MAX_RETRIES` attempts.

## Guards preserved

- **INV-12** (resume only against unfinished sessions): unchanged. This design does not touch the `is_session_completed` gate or the resume-suppression logic — it only changes what happens *after* a session is confirmed `completed` with `verdict=none`.
- **INV-05** (retry counter cutoff/reset): the new count term shares the existing cutoff; reset-on-unstall behavior is identical.
- **INV-85 / INV-92 / INV-105** (the `failed-substantive` escalation ladder): not applicable to the new branch — Branches A/B/B″ (INV-85, INV-105) require a stable HEAD to compare against, and Branch B′ (INV-92) requires a review verdict trailer to classify; both preconditions are structurally absent without a PR (Q3). Not weakened elsewhere; the ladder's own guards are untouched.
- **INV-98** (Step 4a.5 same-HEAD delegation): unaffected in the success case — that delegation only fires when a PR already exists, which is exactly the `none`+PR-exists case this design leaves untouched. Its own [INV-111] self-heal sub-branch (see "Existing adjacent path" above) is independent and disjoint from this design's new branch.
- **INV-108** (dispatch marker atomicity): the new dev-new dispatch uses the identical acquire-before-side-effects / errexit-safe-guard / explicit-rc-branch / confirm-after-launch sequence as Branch C, not a simplified paraphrase of it.
- **INV-13** (wall-clock cap): unaffected — each dispatched attempt is still wrapped by the existing `run_agent` timeout.
- **INV-45** (`needs_open_pr_only`): unaffected, complementary — see "Overlap with INV-45" above.

## Provider-cutover (INV-91)

No raw `gh`. The new branch calls only existing `itp_*`/`chp_*`-routed helpers (`fetch_pr_for_issue`, `itp_post_comment`, `label_swap` → `itp_transition_state`, `acquire_dispatch_marker`, `dispatch`, `post_dispatch_token`, `_reset_session_log`) — all already migrated. The new `count_no_pr_attempts` reads via `itp_list_comments`, the existing choke-point.

## Docs to update in the same PR

- [`docs/pipeline/invariants.md`](../pipeline/invariants.md) — new **INV-123**: "the completed-session `verdict=none` route is bounded — a no-PR completed session retries via `dev-new` under `MAX_RETRIES` (Branch-C-mirror, no escalation ladder — see Q3 rationale), and a PR-exists `none` (no qualifying review comment found) still fails closed to the INV-12 operator handoff." Cross-reference from INV-12's carve-out note (which currently only mentions the INV-35 carve-out), from INV-35's routing table, and from INV-111's self-heal branch (to make the disjointness explicit for future readers).
- [`docs/pipeline/dispatcher-flow.md`](../pipeline/dispatcher-flow.md) — Step 4b.5.1 table gains the `none` + no-PR row; the existing `none` row is re-scoped to "no qualifying review comment found" (dropping the retired "PR-exists-but-unclassifiable" framing per the corrected Q1).
- [`docs/pipeline/state-machine.md`](../pipeline/state-machine.md) — new `pending-dev → in-progress` transition row (dispatcher, no-PR completed-session retry).

## Testing strategy

- Unit tests for the `none`+no-PR branch: dispatches `dev-new` with `INV-12-no-pr-fresh-dev:<sid>` marker, mirroring Branch C's acquire-order and errexit-guard behavior (mock a losing marker acquire, a label-swap failure, an rc=75 defer, and an rc=0 success — assert each takes the same branch Branch C's own tests already pin); idempotent on repeat ticks with the same session id; `none`+PR-exists is unchanged (regression pin); the [INV-111] self-heal branch's disjoint precondition is unaffected (regression pin).
- Unit tests for the new `count_no_pr_attempts`: the WARNING comment text increments the count; the co-posted Session-Report exit-0 comment does not double-count it; cutoff-reset behavior after `mark_stalled` unchanged; `mark_stalled`'s comment text includes the new term.
- Integration/golden-trace: replay the #456 sequence with `MAX_RETRIES=3` — assert exactly 2 branch-dispatched `dev-new` attempts (the 3rd count comes from the original pre-branch dispatch) followed by `mark_stalled` at the Step 4 pre-flight gate, never a 3rd branch dispatch, never a silent no-op tick. Separately: assert that a deferred (rc=75) or wrapper-crashed no-PR retry does NOT escape counting (verifies the mandatory log-truncate step).
