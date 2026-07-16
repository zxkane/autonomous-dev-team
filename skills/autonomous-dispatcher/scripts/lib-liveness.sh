#!/bin/bash
# lib-liveness.sh — INV-128 (issue #467): generic liveness watchdog.
#
# Five "permanent silent park" incidents shipped point-fixes in six months
# (INV-105, INV-111, INV-122, INV-123, INV-125): the label is legal and
# stable, but the decision layer falls into an absorbing loop that posts one
# idempotent notice and then no-ops every tick — no retry, no `stalled`, no
# operator mention. Each fix so far is per-entry; the entry set is open
# (new stop reasons, new CLI adapters, future marker fall-throughs), so
# enumeration can never finish. This lib holds the PURE decision surface for
# a class-level backstop: any non-terminal issue whose *observable state
# fingerprint* stays unchanged for LIVENESS_NOTICE_TICKS ticks gets a
# one-time operator-visible escalation, and after LIVENESS_STALL_TICKS
# further unchanged ticks is unconditionally transitioned to `stalled`.
#
# Mirrors the existing breaker pattern (INV-105's convergence breaker,
# INV-122's same-HEAD E2E-gate breaker): pure fingerprint/counter/threshold
# helpers here, wrapped I/O (`itp_list_comments`, `label_swap`,
# `itp_post_comment`) at the call site in `dispatcher-tick.sh` Step 6. See
# docs/pipeline/invariants.md#inv-127 and
# docs/designs/issue-467-liveness-watchdog.md for the full design.

# ---------------------------------------------------------------------------
# Whole-body canonical producer grammars (issue #473).
#
# Every prior round (6 through 10, PR #472) converted ONE read-site at a time
# from a substring/prefix test to an anchored wrapper-span test, but never to
# a full-body match — each grammar only asserted that a KNOWN TOKEN appeared
# inside a closed backtick/HTML-comment span SOMEWHERE in the comment. That
# left two residual gaps this issue closes:
#
#   1. `_liveness_non_idempotent_count`: a human comment that merely QUOTES a
#      wrapped token (e.g. "please see `reason=liveness-timeout` for
#      context") satisfies the round-10 closed-span anchor exactly as well as
#      the genuine producer's report, so it was wrongly excluded from the
#      progress count — masking real human intervention.
#   2. `_liveness_marker_digest`: a comment whose FIRST LINE looks like a
#      canonical marker (e.g. a well-formed `<!-- dispatcher-token: ... -->`)
#      but whose remainder is arbitrary prose still matched, because the
#      per-token pattern never anchored past the wrapper's own close.
#
# The fix: `_LIVENESS_GRAMMARS_JSON` holds ONE whole-body regex PER PRODUCER
# (not per token), each built directly from that producer's actual
# `itp_post_comment` call site (lib-dispatch.sh / lib-review-e2e.sh /
# autonomous-review.sh) — every fixed word, punctuation mark, and Markdown
# marker byte-matched, with ONLY the producer's own interpolated variables
# (`${session_id}`, `${current_head}`, `${_cb_rounds}`, etc.) generalized to
# the narrowest character class that variable's value can take (e.g.
# `[^`\n]+` for an opaque SHA/session-id, `[0-9]+` for a tick count). A
# comment counts as this grammar ONLY when its ENTIRE body — start to end —
# matches one of these regexes; a canonical-looking prefix (first line, or
# any leading span) with a noncanonical remainder matches NONE of them, by
# construction (every entry is anchored `^...$` and — for the multi-line
# report producers — spans the FULL body via `[\s\S]*?` for the one
# genuinely free-text evidence line each report embeds, never merely a
# prefix). This replaces BOTH `_LIVENESS_IDEMPOTENT_PATTERN` and
# `_LIVENESS_DIGEST_PATTERN` (the per-token alternations every prior round
# extended) with a single per-producer source of truth: `digest: true` marks
# the 15 entries eligible for the marker-digest read (every entry except the
# watchdog's own marker and the two liveness reports themselves — same
# exclusion `_LIVENESS_DIGEST_PATTERN` encoded, see `_liveness_marker_digest`
# below for why those three are digest-ineligible); ALL 18 entries are
# eligible for the idempotent-count read.
#
# `reason=liveness-timeout`'s entry starts with the placeholder
# `@@TIER2_HEADING@@`, substituted (immediately after the heredoc, once the
# `_LIVENESS_TIER2_HEADING` constant defined just above is in scope) with the
# SAME constant the TIER2REPORT heredoc (lib-dispatch.sh) renders from — a
# plain bash parameter-expansion string replace (`${var//lit/repl}`), not a
# second hand-typed copy of the heading, so producer and detector can never
# drift apart (the same single-sourcing rationale that constant's own
# docstring documents, just extended to this new whole-body read). The
# quoted heredoc delimiter (`<<'…'`) suppresses ALL expansion so the regex
# bodies' own `$`/backtick bytes stay literal; the placeholder + post-hoc
# `${//}` substitution is how the one intended interpolation is threaded
# through without also expanding those.
#
# Accepted token-mode residual (UNCHANGED in kind from every prior round —
# [INV-105]'s round-14 precedent): a human who posts a byte-for-byte copy of
# a genuine producer's ENTIRE comment body still satisfies the matching
# grammar and is indistinguishable from the real thing in `GH_AUTH_MODE=token`
# — there is no actor signal to add there, and this issue's Out-of-Scope
# section explicitly defers any authentication stronger than the whole-body
# anchor to a future change. This is a strict narrowing relative to every
# prior round (fewer false positives: quoting/prefix-forging no longer
# registers), never a widening — every genuine, well-formed producer body
# that passed the round-10 closed-span anchor still passes this whole-body
# anchor unchanged.

# _LIVENESS_TIER2_HEADING — the tier-2 trip report's exact opening line
# ([codex review, PR #472, round 7 BLOCKING]). Single-sourced here so
# `_liveness_evaluate_issue`'s TIER2REPORT heredoc (lib-dispatch.sh),
# `reason=liveness-timeout`'s grammar entry below, and
# `_liveness_prior_marker`'s cutoff detection can never drift apart —
# a producer/detector text mismatch would silently reopen the cutoff bug this
# constant exists to close. Defined ABOVE the grammar heredoc so the
# `@@TIER2_HEADING@@` substitution can run inline right after it (see the
# grammars docstring above). `_liveness_prior_marker` matches it via
# `startswith()` (whole-body-PREFIX anchored, mirroring the marker's own
# whole-body anchor), NOT `contains()`: the round-7 finding was that
# `contains("Liveness watchdog tripped")` let ANY comment merely mentioning
# that phrase — anywhere in its body, e.g. a collaborator quoting or
# discussing the phrase in prose — falsely become the cutoff, excluding the
# genuine earlier marker and resetting a frozen issue's series back to
# count=1, indefinitely dodging tier 2. Anchoring to "the report's own exact
# opening line" closes that gap the same way the marker's whole-body anchor
# already closes the marker-forgery gap.
_LIVENESS_TIER2_HEADING='## ⛔ Liveness watchdog tripped — halting a silently-parked issue'

_LIVENESS_GRAMMARS_JSON=$(cat <<'_LIVENESS_GRAMMARS_JSON_EOF'
[
  {
    "name": "stale-verdict:",
    "re": "^PR (#[0-9]+|\\(number unknown\\)) HEAD `[^`\\n]+` already reviewed with FAILED verdict; awaiting new commits before re-review\\. A dev wrapper appears to still be running for this issue, or a concurrent dispatcher tick is mid-dispatch — this is a transient wait, not a permanent park \\(`stale-verdict:[^`\\n]+`\\)\\.$",
    "digest": true
  },
  {
    "name": "INV-12-completed:",
    "re": "^Session `[^`\\n]+` already ended \\(stop_reason=end_turn, terminal_reason=completed\\) and no post-session review verdict was found\\. Resume would hang on idle SSE — skipping\\. If review findings exist, unpark by flipping to `in-progress` \\+ posting a dispatcher-token comment \\+ running `dispatch-local\\.sh dev-resume <issue>` \\(a fresh session re-reads the issue and findings; do NOT flip to `pending-review` — the stale-verdict guard rejects an already-reviewed HEAD\\)\\. Close the issue if the work is done\\. \\(`INV-12-completed:[^`\\n]+`\\)$|^Session `[^`\\n]+` completed; verdict classifier returned unexpected value\\. Operator handoff\\. \\(`INV-12-completed:[^`\\n]+`\\)$",
    "digest": true
  },
  {
    "name": "INV-12-no-pr-fresh-dev:",
    "re": "^Session `[^`\\n]+` ended cleanly \\(stop_reason=end_turn, terminal_reason=completed\\) but no PR was ever created, so no review could run\\. Minting a fresh dev session \\(bounded by `MAX_RETRIES`\\)\\. \\(`INV-12-no-pr-fresh-dev:[^`\\n]+`\\)$",
    "digest": true
  },
  {
    "name": "INV-35-fresh-dev:",
    "re": "^Review failed substantively on completed session `[^`\\n]+`\\. A completed session cannot be resumed; minting a fresh dev session via the INV-12 PTL recovery pattern\\. \\(`INV-35-fresh-dev:[^`\\n]+`\\)$",
    "digest": true
  },
  {
    "name": "no-progress-substantive:",
    "re": "^Substantive review failure on completed session `[^`\\n]+` is \\*\\*not resolvable by the autonomous dev agent\\*\\*: its scoped token hit `Resource not accessible by integration` on a PR-metadata edit, or the finding requires a maintainer / post-merge action\\. Marking stalled — no further `dev-new` will be dispatched\\. @[a-zA-Z0-9_-]+ please apply the PR-body / metadata change manually, or split the post-merge criterion into a follow-up\\. \\(`no-progress-substantive:[^`\\n]*`\\)$|^Substantive review failure on completed session `[^`\\n]+`, but PR HEAD `[^`\\n]*` is unchanged since the last review and a prior fresh dev session already ran against it without producing a new commit\\. The finding appears un-actionable by the dev agent\\. Marking stalled — no further `dev-new` will be dispatched\\. @[a-zA-Z0-9_-]+ please investigate\\. \\(`no-progress-substantive:[^`\\n]*`\\)$",
    "digest": true
  },
  {
    "name": "no-progress-substantive-attempt:",
    "re": "^<!-- no-progress-substantive-attempt:[^\\n]* session=[^\\n]* -->$",
    "digest": true
  },
  {
    "name": "non-actionable-finding:",
    "re": "^Substantive review failure on completed session `[^`\\n]+` is \\*\\*not resolvable by the autonomous dev agent\\*\\*: the review classified every blocking finding as requiring a human or a privileged token the agent's scoped token lacks \\(e\\.g\\. a `\\.github/workflows` edit needs the `workflows` scope, or a CODEOWNERS / maintainer-owned change — \\[INV-92\\]\\)\\.( Matched `REVIEW_PROTECTED_PATHS` pattern\\(s\\): [^\\n]*\\.)? Marking stalled — no `dev-new` will be dispatched \\(`reason=non_actionable_finding`\\)\\. @[a-zA-Z0-9_-]+ please apply the change manually, grant the required scope, or split the criterion into a maintainer follow-up\\. \\(`non-actionable-finding:[^`\\n]*`\\)$",
    "digest": true
  },
  {
    "name": "self-heal-lost-session:",
    "re": "^PR (#[0-9]+|\\(number unknown\\)) HEAD `[^`\\n]+` was reviewed with a FAILED verdict, and no `Dev Session ID:` could be resolved for the prior dev session \\(its session-report comment was likely lost — e\\.g\\. a mid-cleanup auth-teardown race\\), and no dev wrapper is currently running\\. Dispatching a fresh dev session rather than parking indefinitely\\. \\(`self-heal-lost-session:[^`\\n]*`\\)$",
    "digest": true
  },
  {
    "name": "self-heal-non-substantive:",
    "re": "^PR (#[0-9]+|\\(number unknown\\)) HEAD `[^`\\n]+` was reviewed with a non-substantive FAILED verdict \\(cause=`[a-zA-Z0-9_-]+`\\), and (no `Dev Session ID:` could be resolved for the prior dev session \\(its session-report comment was likely lost — e\\.g\\. a mid-cleanup auth-teardown race\\)|a `Dev Session ID:` was resolved for the prior dev session, but its completion could not be confirmed \\(a non-terminal stop reason such as `api_error`, a non-claude dev CLI, or an unreadable session log\\))\\. Re-routing to review rather than dispatching a fresh dev session\\. \\(`self-heal-non-substantive:[^`\\n]*`\\)$|^PR (#[0-9]+|\\(number unknown\\)) HEAD `[^`\\n]+` already consumed its one bounded non-substantive re-review for this HEAD \\(`self-heal-non-substantive:[^`\\n]*`\\) with no progress\\. Marking stalled rather than parking indefinitely\\. @[a-zA-Z0-9_-]+ please investigate\\.$",
    "digest": true
  },
  {
    "name": "crashed-session-retry:",
    "re": "^PR (#[0-9]+|\\(number unknown\\)) HEAD `[^`\\n]+` was reviewed with a FAILED verdict, and a `Dev Session ID:` was resolved for the prior dev session, but its completion could not be confirmed \\(a non-terminal stop reason such as `api_error`, a non-claude dev CLI, or an unreadable session log\\), and no dev wrapper is currently running\\. Dispatching a fresh dev session rather than parking indefinitely\\. \\(`crashed-session-retry:[^`\\n]*`\\)$",
    "digest": true
  },
  {
    "name": "crashed-session-non-actionable:",
    "re": "^PR (#[0-9]+|\\(number unknown\\)) HEAD `[^`\\n]+` was reviewed with a FAILED verdict that classified every blocking finding as \\*\\*not resolvable by the autonomous dev agent\\*\\* \\(requires a human or a privileged token the agent's scoped token lacks, \\[INV-92\\]\\), and a `Dev Session ID:` was resolved for the prior dev session, but its completion could not be confirmed \\(a non-terminal stop reason such as `api_error`, a non-claude dev CLI, or an unreadable session log\\)\\.( Matched `REVIEW_PROTECTED_PATHS` pattern\\(s\\): [^\\n]*\\.)? Marking stalled — no `dev-new` will be dispatched\\. @[a-zA-Z0-9_-]+ please apply the change manually\\. \\(`crashed-session-non-actionable:[^`\\n]*`\\)$",
    "digest": true
  },
  {
    "name": "dispatcher-convergence-breaker:",
    "re": "^<!-- dispatcher-convergence-breaker: issue=[0-9]+ head=[^ \\n]+ trailer=[0-9a-f]+ session=[^ \\n]+ -->\\n## ⛔ Convergence circuit-breaker tripped — halting a non-converging dev↔review loop \\(`reason=non-convergence`, \\[INV-105\\]\\)\\n\\nThe autonomous dev↔review loop is \\*\\*not converging\\*\\*: the review keeps failing\\nsubstantively on PR \\*\\*#[0-9?]+\\*\\* while the PR head SHA stays \\*\\*frozen\\*\\*\\n— the dev agent completed \\*\\*[0-9]+\\*\\* dev-resume rounds against\\n`[^`\\n]*` \\(≥ threshold [0-9]+\\) and produced \\*\\*zero new\\ncommits\\*\\* each time\\. This is the #286 deadlock shape: a `failed-substantive`\\nverdict the dev agent cannot satisfy \\(typically a self-contradictory / malformed\\nacceptance criterion, or a fix the agent's scoped token can't apply\\)\\.\\n\\n\\*\\*Dispatcher actions taken\\*\\* \\(this loop is now HALTED — no more `dev-resume`\\):\\n- Transitioned the issue to `stalled` \\(autonomy halted; `pending-dev` removed; `autonomous` is retained\\) — REMOVING the `stalled` label is the operator's explicit opt-in to resume \\(re-enters via Step 2; retry counter resets, INV-05\\)\\.\\n- Posted this one-time report\\.\\n\\n\\*\\*Evidence\\*\\*\\n- PR: #[0-9<>none?]+\\n- Frozen PR head: `[^`\\n]*`\\n- Repeated substantive review verdict \\(`cause=[^`\\n]*`, `dev-actionable=[a-z]+`\\):\\n(  > [\\s\\S]*?|  > \\(verdict body unavailable — see the latest review comment above\\))\\n- Repeated-failure count on this frozen head: \\*\\*[0-9]+\\*\\*\\n- Counted completed dev-resume rounds \\(timestamps\\): [\\s\\S]*?\\n\\n\\*\\*Human action needed\\*\\* — pick one, then resume:\\n- \\[ \\] Rewrite the invalid / self-contradictory acceptance criterion in the issue body, OR\\n- \\[ \\] Grant the permission / scope the dev agent lacked \\(if the fix needs a privileged token or a protected-path edit\\), OR\\n- \\[ \\] Close the issue, or split the un-satisfiable part into a maintainer follow-up\\.\\n\\n\\*\\*To resume: fix per the checklist above, then REMOVE the `stalled` label \\(the `autonomous` label is retained; removal re-arms the pipeline and resets the retry counter, INV-05\\)\\.\\*\\*\\n@[a-zA-Z0-9_-]+$",
    "digest": true
  },
  {
    "name": "dispatcher-gate-fail-breaker:",
    "re": "^<!-- dispatcher-gate-fail-breaker: issue=[0-9]+ head=[^ \\n]+ rc=[^ \\n]+ count=[0-9]+ -->\\n## ⛔ Same-HEAD E2E-gate circuit-breaker tripped — halting repeated re-dispatch \\(`reason=same-head-gate-failure`, \\[#453\\]\\)\\n\\nThe E2E hard gate \\(INV-46\\) has failed \\*\\*[0-9]+\\*\\* times in a row\\nagainst the SAME PR head `[^`\\n]*` with the SAME lane exit code\\n`[^`\\n]*` \\(>= threshold [0-9]+\\)\\. Re-dispatching review\\nagainst this unchanged head would only repeat the identical failure —\\nnothing the dev agent can fix without a new commit\\.\\n\\n\\*\\*Dispatcher actions taken\\*\\* \\(this loop is now HALTED\\):\\n- Transitioned the issue to `stalled` \\(autonomy halted; `autonomous` is\\n  retained\\) — REMOVING the `stalled` label is the operator's explicit\\n  opt-in to resume\\.\\n- Posted this one-time report\\.\\n\\n\\*\\*Best-effort classification\\*\\*\\n[\\s\\S]*?\\n\\n\\*\\*Evidence\\*\\*\\n- PR: #[0-9<>none?]+\\n- Frozen PR head: `[^`\\n]*`\\n- E2E lane exit code: `[^`\\n]*` \\(evidence_present=[0-9]+\\)\\n- Repeated-failure count on this frozen \\(head, rc\\) pair: \\*\\*[0-9]+\\*\\*\\n\\n\\*\\*Human action needed\\*\\* — pick one, then push a new commit to resume:\\n- \\[ \\] Fix the external/environment prerequisite the E2E gate depends on\\n      \\(e\\.g\\. deploy the missing IAM grant\\), OR\\n- \\[ \\] Fix a genuine code defect the E2E gate is correctly catching, OR\\n- \\[ \\] Close the issue if the feature is no longer wanted\\.\\n\\n\\*\\*To resume: fix per the checklist above, then push a new commit and REMOVE\\nthe `stalled` label \\(the `autonomous` label is retained; removal re-arms\\nthe pipeline\\)\\.\\*\\*\\n@[a-zA-Z0-9_-]+$",
    "digest": true
  },
  {
    "name": "dispatcher-token:",
    "re": "^<!-- dispatcher-token: [a-zA-Z0-9_-]+ at [0-9TZ:-]+ mode=[a-z-]+( run=[^ \\n]+)? -->\\n(Dispatching autonomous development\\.\\.\\.|Resuming autonomous development\\.\\.\\.|Dispatching autonomous review\\.\\.\\.|Dispatching [a-z-]+\\.\\.\\.)$",
    "digest": true
  },
  {
    "name": "INV-25-hygiene:",
    "re": "^Label hygiene: stripped (`[a-z0-9-]+`(, `[a-z0-9-]+`)*) from `[a-z0-9-]+` issue \\(INV-25\\)\\. <!-- INV-25-hygiene:[a-z0-9,-]*; -->$",
    "digest": true
  },
  {
    "name": "dispatcher-liveness-watchdog:",
    "re": "^<!-- dispatcher-liveness-watchdog: issue=[0-9]+ fingerprint=[0-9a-f]+ count=[0-9]+ tier1=[01] tripped=[01] -->[[:space:]]*$",
    "digest": false
  },
  {
    "name": "reason=liveness-no-progress",
    "re": "^No observable progress for \\*\\*[0-9]+\\*\\* ticks on issue #[0-9]+ \\(`reason=liveness-no-progress`, \\[INV-128\\]\\):\\n- Label: `[^`\\n]*`\\n- PR head: `[^`\\n]*`\\n- Non-idempotent comment count: [0-9]+\\n- Marker digest: `[^`\\n]*`\\n\\n@[a-zA-Z0-9_-]+ this issue may need attention\\. If this is a legitimate slow wait, any observable change \\(a comment, a label edit, or a push\\) resets the clock\\. Without one, this issue transitions to `stalled` after \\*\\*[0-9]+\\*\\* total unchanged ticks\\.$",
    "digest": false
  },
  {
    "name": "reason=liveness-timeout",
    "re": "^@@TIER2_HEADING@@ \\(`reason=liveness-timeout`, \\[INV-128\\]\\)\\n\\nThis issue's observable state \\(label \\+ PR head \\+ non-idempotent comments \\+ marker set\\) has not changed for \\*\\*[0-9]+\\*\\* consecutive dispatcher ticks — well past the \\*\\*[0-9]+\\*\\*-tick stall threshold\\.\\n\\n\\*\\*Evidence\\*\\*\\n- Last-known fingerprint: `[^`\\n]*`\\n- Label at time of trip: `[^`\\n]*`\\n- PR head: `[^`\\n]*`\\n- Non-idempotent comment count: [0-9]+\\n- Marker digest \\(known grammars present\\): `[^`\\n]*`\\n- Tick counts: count=[0-9]+, notice_threshold=[0-9]+, stall_threshold=[0-9]+\\n- Newest session report / verdict pointer: [\\s\\S]*?\\n\\n\\*\\*Dispatcher actions taken\\*\\* \\(autonomy halted for this issue\\):\\n- Transitioned to `stalled` \\(`autonomous` is retained — removing `stalled` re-arms via Step 2 and resets the retry counter, \\[INV-05\\]\\)\\.\\n- Posted this one-time report\\.\\n\\n@[a-zA-Z0-9_-]+ please investigate — this is the class-level backstop \\(a specific breaker for this park shape may not exist yet\\)\\. To resume: fix per the evidence above, then remove the `stalled` label\\.$",
    "digest": false
  }
]
_LIVENESS_GRAMMARS_JSON_EOF
)
# Substitute the one intended interpolation now that both the heredoc and
# `_LIVENESS_TIER2_HEADING` are in scope. Single-sourcing it here (not at each
# call site) means `_liveness_non_idempotent_count` and `_liveness_marker_digest`
# read the exact same already-substituted grammar list.
_LIVENESS_GRAMMARS_JSON="${_LIVENESS_GRAMMARS_JSON//@@TIER2_HEADING@@/$_LIVENESS_TIER2_HEADING}"

# _liveness_notice_ticks — read LIVENESS_NOTICE_TICKS with the same
# regex-then-fallback-with-warning shape as `_gate_breaker_threshold`
# (lib-review-e2e.sh), floor >=2 (R5). Warning goes to stderr ONLY, never via
# log() — every call site captures this function's stdout via `$(...)` for
# the numeric result (mirrors the codex [P2] fix on #453).
_liveness_notice_ticks() {
  local raw="${LIVENESS_NOTICE_TICKS:-6}"
  local val="$raw"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 2 ]]; then
    echo "WARNING: LIVENESS_NOTICE_TICKS='${raw}' invalid (must be an integer >=2) — falling back to default 6" >&2
    val=6
  fi
  printf '%s\n' "$val"
}

# _liveness_stall_ticks <notice_ticks> — read LIVENESS_STALL_TICKS with the
# same shape, plus the relative constraint `stall > notice` (R5). A
# configured pair that fails the relative constraint is a config error, not
# a near-miss to nudge: [codex review, PR #472, BLOCKING] unconditionally
# clamping to `notice + 1` would silently turn e.g. a `6/6` typo into an
# aggressive 7-tick stall threshold instead of the documented/default 18 —
# a misconfiguration turning into a false-stall path for legitimate slow
# waits. Fall back to the default 18 — UNLESS the caller's (independently
# validated, uncapped) notice_ticks is itself >= 18, in which case the
# default no longer satisfies `stall > notice` either, and the fallback
# must escalate to `notice + 1` to preserve the invariant this function
# guarantees to every caller. Defaults (6/18) never hit either branch.
_liveness_stall_ticks() {
  local notice="${1:?_liveness_stall_ticks requires notice_ticks}"
  local raw="${LIVENESS_STALL_TICKS:-18}"
  local val="$raw"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 2 ]]; then
    echo "WARNING: LIVENESS_STALL_TICKS='${raw}' invalid (must be an integer >=2) — falling back to default 18" >&2
    val=18
  fi
  if [[ "$val" -le "$notice" ]]; then
    local fallback=18
    [[ "$fallback" -le "$notice" ]] && fallback=$((notice + 1))
    echo "WARNING: LIVENESS_STALL_TICKS='${raw}' must be > LIVENESS_NOTICE_TICKS=${notice} — falling back to ${fallback}" >&2
    val=$fallback
  fi
  printf '%s\n' "$val"
}

# _liveness_watchdog_enabled — LIVENESS_WATCHDOG_ENABLED (default true).
# Returns 0 (enabled) unless explicitly set to "false".
_liveness_watchdog_enabled() {
  [[ "${LIVENESS_WATCHDOG_ENABLED:-true}" != "false" ]]
}

# ---------------------------------------------------------------------------
# _liveness_strict_author_flag — [operator guidance, round 6] the SINGLE
# source of truth for "should the marker read-back additionally require
# authorKind != human". Two independent tensions collide at this call site
# (both raised by codex review on PR #472):
#
#   (a) round 2 [BLOCKING]: an unconditional `authorKind != "human"` gate
#       rejects the dispatcher's OWN genuine marker under the permanent
#       `GH_AUTH_MODE=token` topology, because `BOT_LOGIN` is never resolved
#       in the dispatcher's own process (only inside autonomous-review.sh's
#       separate process) — the marker normalizes to `authorKind=human` and
#       an unconditional gate makes the watchdog permanently inert.
#   (b) round 5 [BLOCKING]: with NO authorKind gate at all, any collaborator
#       can post a bare forged marker and force an immediate tier-2 trip.
#
# These cannot BOTH be satisfied by tightening/loosening one unconditional
# gate — the operator (see PR #472 review-round-6 guidance) directed: do NOT
# re-tighten unconditionally; instead mirror the established two-part
# resolution already used at four other call sites in this codebase
# (`classify_recent_review_verdict`'s [#389]/[#393] fix, mirrored again here):
#   1. Structural authentication (the whole-body anchor, see
#      `_liveness_prior_marker`) carries authenticity in the COMMON
#      `GH_AUTH_MODE=token` case — this is the part that must NOT regress to
#      an authorKind-only design.
#   2. In `GH_AUTH_MODE=app` SPECIFICALLY, additionally require
#      `authorKind != "human"` — the genuine wrapper posts under a GitHub App
#      identity there (`…[bot]` login ⇒ authorKind=bot via REST's
#      `user.type == "Bot"`, [#393]), so this shrinks the forgery surface
#      from "anyone who can comment" to "bot/App actors on the repo" WITHOUT
#      touching the token-mode path the round-2 fix depends on.
#
# The token-mode residual (a human posting a byte-for-byte copy of the bare
# marker as their ENTIRE comment) remains a documented, accepted exposure —
# the SAME class every other structural-only anchor in this codebase carries
# (INV-105's round-14 finding) — because GH_AUTH_MODE=token has no actor
# signal to layer on top. [round 8] This residual now has TWO directions,
# not one: a forged high-count marker still TRIGGERS an early tier action
# (bounded by the count cap, `_liveness_next_count`'s 3rd arg), and — new
# since `tripped` replaced the heading-text cutoff — a forged `tripped=1`
# marker can also SUPPRESS an in-progress series by moving the cutoff
# forward and resetting it to `count=1`. The count cap bounds ONLY the
# trigger direction; the suppression direction is self-limiting instead (the
# genuine watchdog re-posts its own marker on the very next tick and resumes
# counting, so indefinite suppression requires the forger to keep posting a
# fresh audit-visible forgery roughly every `stall_ticks`, not a one-time
# action) rather than being capped. Echoes "1" (apply the authorKind filter)
# or "0".
_liveness_strict_author_flag() {
  if [[ "${GH_AUTH_MODE:-token}" == "app" ]]; then
    echo 1
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# _liveness_non_idempotent_count <comments_json>
#
# Echoes the count of comments in the normalized itp_list_comments array
# whose body does NOT match any known idempotent-notice/marker grammar in
# `_LIVENESS_GRAMMARS_JSON` (issue #473: WHOLE-BODY match — a comment that
# merely quotes, opens, or prefixes a producer's canonical text is never a
# match; see that variable's docstring for the full grammar set). Pure —
# comments_json is already fetched by the caller. Relies on the
# itp_list_comments contract (INV-90) that `body` is always a string, never
# JSON null — a null would error `test()` under `2>/dev/null` and collapse
# the count to 0 (bias to MISS, not a crash).
#
# [codex review, PR #472, round 9 BLOCKING #1] [operator guidance] Prior to
# the whole-body conversion, this function had NO authorKind gate at all: a
# human comment that merely wraps a known token in a backtick span or an
# HTML-comment opening (e.g. `` `reason=liveness-timeout` `` in prose, or a
# quoted `<!-- dispatcher-token: ... -->`) satisfied the round-8 wrapper
# anchor exactly as well as a genuine producer's comment, so it was (wrongly)
# treated as an IDEMPOTENT notice and excluded from the count — masking real
# progress ("fail to reset the clock", per the round-9 finding). [issue #473]
# The whole-body grammar conversion independently closes the SAME class of
# gap for every remaining producer (a quoted/prefixed token no longer matches
# ANY grammar, full stop), but the authorKind gate below is UNCHANGED from
# round 9 — it still matters for the residual token-mode-equivalent case in
# `GH_AUTH_MODE=app`: a human who posts a byte-for-byte copy of a genuine
# producer's ENTIRE body (the accepted whole-body residual, see
# `_LIVENESS_GRAMMARS_JSON`'s docstring) is still an untrusted match, and this
# gate still reclassifies it as progress in app mode. The fix gates the
# PATTERN MATCH's trustworthiness, not the comment's membership in the count:
# a comment counts as non-idempotent (genuine progress) if EITHER its body
# doesn't match any known grammar, OR it matches but — in `GH_AUTH_MODE=app`
# only, via `_liveness_strict_author_flag` — was posted by an untrusted
# (`authorKind == "human"`) author, so the "this is a genuine idempotent
# notice" claim itself is not trusted and the comment is counted as real
# progress instead. This is DELIBERATELY the mirror image of
# `_liveness_marker_digest`'s own gate (which excludes an untrusted match
# from registering PRESENCE) — here an untrusted match must NOT be excluded
# from the comment universe entirely (that would just silently drop the
# comment, undercounting genuine human traffic that happens to quote a
# token), it must be RECLASSIFIED as counted. In `GH_AUTH_MODE=token`
# (`strict=="0"`), the added disjunct is always false, so behavior is
# UNCHANGED from pre-round-9: the pattern match alone decides, and the
# documented token-mode residual (a human's byte-for-byte-copy comment is
# treated as idempotent, same as a genuine one) is unaffected — token mode
# has no actor signal to add (INV-105's round-14 precedent). Pinned by
# TC-LIVENESS-067..069 and TC-LIVENESS-084 (issue #473 quoted-token pin).
_liveness_non_idempotent_count() {
  local comments_json="${1:-[]}"
  local _strict
  _strict=$(_liveness_strict_author_flag)
  jq -r --argjson grammars "$_LIVENESS_GRAMMARS_JSON" --arg strict "$_strict" '
    [.[] | . as $c | select(
       (any($grammars[]; .re as $re | ($c.body | test($re))) | not)
       or (($strict == "1") and (($c.authorKind // "human") == "human"))
     )] | length
  ' <<<"$comments_json" 2>/dev/null || echo 0
}

# _liveness_marker_digest <comments_json>
#
# Echoes a stable digest of which known marker grammars are PRESENT
# (authorKind-gated when possible, mirrors INV-105/INV-122's own
# marker-authenticity filter) — a sorted, comma-joined list of matched
# grammar NAMES. A NEW grammar appearing changes the digest (progress), even
# when that same grammar is excluded from the non-idempotent comment count
# above. Filters `_LIVENESS_GRAMMARS_JSON` to `digest == true` entries only
# (NOT the count's full set) — deliberately excludes the watchdog's own
# marker (`dispatcher-liveness-watchdog:`) and the two liveness reports
# themselves (`reason=liveness-no-progress`/`reason=liveness-timeout`): see
# `_LIVENESS_GRAMMARS_JSON`'s docstring for why those three are
# digest-ineligible (a self-referential-pollution bug D3 already fixed once
# for the marker specifically — including the watchdog's own output in "a
# NEW marker appearing = progress" would flip the digest exactly once and
# then hold it constant forever, a one-time false progress signal that
# permanently pollutes the fingerprint with a component carrying no further
# information).
#
# [issue #473] WHOLE-BODY match — a comment whose FIRST LINE looks like a
# canonical marker (e.g. a well-formed `<!-- dispatcher-token: ... -->`) but
# whose remainder is noncanonical prose no longer registers ANY grammar as
# present: `test($g.re)` requires the ENTIRE body to match one of the
# per-producer whole-body regexes, not merely a leading span. Extraction is
# now trivial (`select(...) | $g.name`) — no `scan()`/capture-group juggling
# is needed because whole-body match already tells us WHICH producer matched
# (the grammar list is keyed one-entry-per-producer, not one-entry-per-token
# with shared alternation branches the way the pre-#473 patterns were).
#
# [codex review, PR #472, BLOCKING sibling fix; round 6 generalized] Every
# listed grammar (`dispatcher-convergence-breaker:`, `dispatcher-token:`,
# `INV-25-hygiene:`, etc.) is posted by the DISPATCHER's own process
# (dispatcher-tick.sh / lib-dispatch.sh), which — like the watchdog's own
# marker read-back this mirrors — NEVER resolves `BOT_LOGIN`. An
# unconditional `authorKind != "human"` gate would therefore reject EVERY
# one of these genuine markers under `GH_AUTH_MODE=token` (the dispatcher's
# comments there normalize to `authorKind=human`), collapsing the digest to
# "" on every tick regardless of which markers are actually present — dead
# on the "a NEW marker appearing = progress" signal in the common topology.
# Uses `_liveness_strict_author_flag` — the SAME app-mode-only gate
# `_liveness_prior_marker` applies — rather than a `BOT_LOGIN`-presence
# check: `BOT_LOGIN` is NEVER set in the dispatcher's own process regardless
# of `GH_AUTH_MODE`, but `authorKind` itself is independently REST-derived
# from `user.type == "Bot"` ([#393]), so it correctly reports "bot" for the
# GitHub App identity the dispatcher posts under in app mode even without
# `BOT_LOGIN` ever being resolved.
_liveness_marker_digest() {
  local comments_json="${1:-[]}"
  local _strict
  _strict=$(_liveness_strict_author_flag)
  jq -r --argjson grammars "$_LIVENESS_GRAMMARS_JSON" --arg strict "$_strict" '
    ($grammars | map(select(.digest))) as $digest_grammars
    | [.[] | select(($strict == "0") or ((.authorKind // "human") != "human")) | . as $c
       | [$digest_grammars[] | . as $g | select($c.body | test($g.re)) | $g.name]]
    | flatten | unique | sort | join(",")
  ' <<<"$comments_json" 2>/dev/null || echo ""
}

# _liveness_canonical <label> <head> <count> <digest>
#
# Pipe-delimited canonical string — the single source of truth for the
# fingerprint hash, mirroring convergence_canonical's shape.
_liveness_canonical() {
  printf '%s|%s|%s|%s' "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

# _liveness_fingerprint <label> <head> <count> <digest>
#
# Echoes a stable hash of the canonical string. Prefers sha1sum (12-char
# prefix); falls back to cksum so the helper never aborts under `set -e`
# when sha1sum is absent (mirrors convergence_trailer_hash).
_liveness_fingerprint() {
  local _canon
  _canon="$(_liveness_canonical "${1:-}" "${2:-}" "${3:-}" "${4:-}")"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$_canon" | sha1sum | cut -c1-12
  else
    printf '%s' "$_canon" | cksum | tr -d ' ' | cut -c1-12
  fi
}

# ---------------------------------------------------------------------------
# _liveness_marker <issue> <fingerprint> <count> <tier1> [tripped] —
# construct the marker text ([R4]). `tripped` (default 0) records whether
# THIS marker was posted as part of a tier-2 transition ([codex review, PR
# #472, round 8 BLOCKING #1] — see `_liveness_prior_marker`'s docstring for
# why this field replaces the old separate-heading-text cutoff).
_liveness_marker() {
  local issue="$1" fingerprint="$2" count="$3" tier1="$4" tripped="${5:-0}"
  printf '<!-- dispatcher-liveness-watchdog: issue=%s fingerprint=%s count=%s tier1=%s tripped=%s -->' \
    "$issue" "$fingerprint" "$count" "$tier1" "$tripped"
}

# _liveness_parse_marker <marker_text> <fingerprint> <field> — echo the
# named field from marker_text IFF it matches the given fingerprint; else
# echo 0. `field` MUST be exactly one of `count`|`tier1`|`tripped` — no other
# value is handled (the `case` below has no default arm; every one of the
# three call sites in this file passes a literal). Pure substring/regex
# extraction — a malformed, absent, or non-matching marker all collapse to 0
# (bias to MISS).
_liveness_parse_marker() {
  local marker_text="$1" fingerprint="$2" field="$3"
  local pattern="dispatcher-liveness-watchdog: issue=[0-9]+ fingerprint=${fingerprint} count=([0-9]+) tier1=([01]) tripped=([01])"
  if [[ "$marker_text" =~ $pattern ]]; then
    case "$field" in
      count)   printf '%s\n' "${BASH_REMATCH[1]}" ;;
      tier1)   printf '%s\n' "${BASH_REMATCH[2]}" ;;
      tripped) printf '%s\n' "${BASH_REMATCH[3]}" ;;
    esac
  else
    printf '0\n'
  fi
}

# _liveness_prior_marker <comments_json> <strict_author> — the CUTOFF-then-
# scan prior-marker read ([codex review, PR #472, BLOCKING] fix #2, then
# round 8's structural rework of the cutoff itself). Mirrors
# `_review_cap_prior_marker`'s cutoff convention (lib-review-cap.sh, itself
# mirroring [INV-05]'s "Marking as stalled" cutoff): a tier-2 transition
# posts a marker with `tripped=1` (R4 requires posting on EVERY evaluated
# tick, including the trip tick itself). Without a cutoff, an operator who
# fixes whatever caused the park and re-arms the issue (removes `stalled`,
# restoring `pending-dev`/`pending-review`) with an otherwise-UNCHANGED
# fingerprint would have the very next evaluation read that OLD trip
# marker back — high count, tier1=1 — and immediately re-trip tier 2 again,
# instead of starting a fresh liveness episode.
#
# cutoff = the latest qualifying `tripped=1` marker's createdAt; the epoch if
# no trip has ever fired. Markers AT OR BEFORE the cutoff are excluded
# (strict `>`, mirrors `_review_cap_prior_marker`'s own strict inequality) —
# this excludes the trip marker itself (its createdAt EQUALS the cutoff)
# while still admitting a genuinely later post-resume marker.
#
# [codex review, PR #472, round 8 BLOCKING #1] Rounds 6/7 anchored the cutoff
# to a SEPARATE, hand-typed heading string (`_LIVENESS_TIER2_HEADING`),
# tightened from `contains()` to `startswith()` after round 7 found the
# substring form let ANY comment merely mentioning the phrase register as a
# trip. Round 8 found `startswith()` was STILL forgeable in the default
# GH_AUTH_MODE=token topology: `_LIVENESS_TIER2_HEADING` is prose text, not
# part of the marker's own already-authenticated grammar, so an unauthenti-
# cated collaborator comment that simply OPENS with that exact heading line
# (trivial to copy) satisfied `startswith()` just as well as the genuine
# report — moving the cutoff forward, excluding the real earlier marker, and
# resetting a still-frozen series to count=1 indefinitely. Each round's fix
# patched the SAME underlying design flaw (a second, independently-typed
# text pattern carries no authentication of its own) without addressing it:
# the cutoff detector and the marker's own whole-body structural anchor were
# two different mechanisms that had to be kept in sync, and round 6->7->8
# is the history of them drifting apart three times. The structural fix is
# to stop using free-text prose as the cutoff signal ENTIRELY: `tripped` is
# now a FIELD on the marker itself, so cutoff detection reuses the EXACT
# SAME whole-body anchor (`$anchor` below) and the EXACT SAME authenticity
# filter (`$strict`) as the prior-marker scan it feeds — there is no second
# pattern left to drift out of sync with. `_LIVENESS_TIER2_HEADING` remains
# as the report's display heading (operator-facing prose, still rendered by
# the TIER2REPORT heredoc) but is no longer read by any detector — a human
# copying that heading text now does nothing, because the cutoff no longer
# looks at prose at all.
#
# [operator guidance, round 6] `anchor` is a WHOLE-BODY anchor
# (`^...-->[[:space:]]*$`, mirroring `classify_recent_review_verdict`'s own
# `_anchored_trailer_re` and INV-105's round-14 verdict anchor): a genuine
# marker's ENTIRE body is the marker, so a forgery with ANY extra content —
# leading prose, trailing content, or a marker embedded inside a larger
# comment — fails the anchor.
#
# `strict_author` selects the authorKind filter via `_liveness_strict_author_flag`
# — app-mode-only (round 6; NOT the token-mode-reintroducing unconditional
# gate round 5's finding warned against). The cutoff computation and the
# final scan are derived from the SAME filtered+anchored `$rows` so they can
# never disagree on which comments are eligible or authentic.
_liveness_prior_marker() {
  local comments_json="${1:-[]}" strict="${2:-0}"
  # [issue #473 audit] `$anchor` is ALREADY a whole-body match (`^...[[:space:]]*$`
  # — the watchdog's own marker's entire body, tolerating only trailing
  # whitespace, per [round 6]'s docstring above); the `test`/`capture` calls
  # below are not a residual substring/prefix site this issue needs to convert.
  local anchor='^<!-- dispatcher-liveness-watchdog: issue=[0-9]+ fingerprint=[0-9a-f]+ count=[0-9]+ tier1=[01] tripped=(?<tripped>[01]) -->[[:space:]]*$'
  jq -r --arg strict "$strict" --arg anchor "$anchor" '
    ( [ .[] | select(($strict == "0") or ((.authorKind // "human") != "human")) | select(.body | type == "string")
        | select(.body | test($anchor)) ] ) as $rows
    | ( [ $rows[] | select((.body | capture($anchor)).tripped == "1") | .createdAt ]
        + ["1970-01-01T00:00:00Z"] | max ) as $cutoff
    | ( [ $rows[] | select(.createdAt > $cutoff) ] | sort_by(.createdAt) | last | .body // "" )
  ' <<<"$comments_json" 2>/dev/null || printf ''
}

# _liveness_next_count <marker_text> <fingerprint> [stall_ticks] —
# stored_count+1 when marker_text matches fingerprint exactly, else 1 (fresh
# series under a new fingerprint — full reset, R1/R4).
#
# [operator guidance, round 6, defense-in-depth] Optional 3rd arg caps the
# result at `stall_ticks`. This is a bound on BLAST RADIUS, not an additional
# authentication layer — the anchor (`_liveness_prior_marker`) is what
# authenticates; the token-mode residual it still accepts (a human posting a
# byte-for-byte bare marker as their entire comment) can already force a
# tier-2 trip on ANY tick simply by choosing a count `>= stall_ticks - 1`, cap
# or no cap. What the cap actually bounds: (a) a forged absurd count (e.g.
# `count=999999999`) no longer propagates verbatim into the tier-2 report's
# operator-facing tick-count text — the report always shows a sane,
# threshold-bounded number; (b) `_liveness_tier_action`/the emitted marker
# never observe a count arbitrarily far past `stall_ticks`, keeping the
# decision function's practical input range bounded to what the two
# configured thresholds actually describe. Omit (or pass empty) to skip
# capping — the fixture-level pure-helper tests below exercise the uncapped
# increment directly; the one production call site
# (`_liveness_evaluate_issue`) always supplies `stall_ticks`.
_liveness_next_count() {
  local marker_text="$1" fingerprint="$2" stall_ticks="${3:-}" stored next
  stored=$(_liveness_parse_marker "$marker_text" "$fingerprint" count)
  next=$((stored + 1))
  if [[ -n "$stall_ticks" ]] && [[ "$stall_ticks" =~ ^[0-9]+$ ]] && [[ "$next" -gt "$stall_ticks" ]]; then
    next="$stall_ticks"
  fi
  printf '%s\n' "$next"
}

# _liveness_next_tier1 <marker_text> <fingerprint> — stored tier1 latch when
# marker_text matches fingerprint exactly, else 0 (fresh series — a new
# episode gets a fresh tier-1 warning even on a head that previously tripped
# tier 1 before recovering).
_liveness_next_tier1() {
  local marker_text="$1" fingerprint="$2"
  _liveness_parse_marker "$marker_text" "$fingerprint" tier1
}

# _liveness_tier_action <count> <tier1> <notice_ticks> <stall_ticks>
#
# Pure decision function. Echoes one of: none | tier1 | tier2.
#   count >= stall               -> tier2 (unconditional once the count
#                                    threshold is met — R3 does not gate tier
#                                    2 on tier 1 having fired)
#   count >= notice AND tier1==0 -> tier1 (must not re-fire while the
#                                    fingerprint stays unchanged, R3)
#   else                          -> none
_liveness_tier_action() {
  local count="$1" tier1="$2" notice="$3" stall="$4"
  if [[ "$count" -ge "$stall" ]]; then
    echo tier2
  elif [[ "$count" -ge "$notice" ]] && [[ "$tier1" == "0" ]]; then
    echo tier1
  else
    echo none
  fi
}

# ---------------------------------------------------------------------------
# _liveness_wrapper_alive <kind> <issue_num> — the "wrapper alive" exemption
# ([R2]/[D4]). Reuses the existing backend-aware liveness primitives
# (`_dispatch_marker_recent`, `pid_alive`) — never a new liveness check.
# `kind` is `issue` for a pending-dev candidate, `review` for a
# pending-review candidate (the SAME two primitives `may_stall_now`
# composes, parameterized by which wrapper kind is relevant to the label
# actually being evaluated). Returns 0 (alive/in-flight) or 1 (not alive).
_liveness_wrapper_alive() {
  local kind="$1" issue_num="$2"
  if _dispatch_marker_recent "$issue_num"; then
    return 0
  fi
  pid_alive "$kind" "$issue_num"
}

# _liveness_newest_pointer <comments_json>
#
# Echoes "<createdAt>: <first 200 chars of body>" for the newest comment
# matching a known session-report/verdict grammar, or empty when none match.
# Feeds the tier-2 report's "pointers to the newest session report / verdict
# / markers" requirement (R3) — the marker_digest component already covers
# "markers"; this covers "session report / verdict".
#
# [issue #473 audit] The unanchored `test(...)` below is a DELIBERATE, JUSTIFIED
# substring match, not an unconverted classification site — this function
# does NOT gate any progress/fingerprint/authenticity decision the way
# `_liveness_non_idempotent_count`/`_liveness_marker_digest`/
# `_liveness_prior_marker` do. It is purely a best-effort DISPLAY pointer in
# the tier-2 operator-facing report ("Newest session report / verdict
# pointer: ..."), sourced from arbitrary agent/review-wrapper free text
# (`autonomous-dev.sh`'s session-report body, `emit_verdict_trailer`'s
# comment) that has NO single canonical whole-body shape to anchor against —
# unlike every OTHER grammar in `_LIVENESS_GRAMMARS_JSON`, these are
# large human-authored reports with only a KEYWORD in common, not a fixed
# template. A false-positive match here degrades the tier-2 report's
# "here's a pointer to look at" hint to point at the wrong comment — never a
# missed park, a forged trip, or an incorrect counter/fingerprint value (the
# three properties INV-128 actually guarantees). Narrowing this to a
# whole-body match is out of scope for issue #473 (which is limited to the
# two count/digest classification reads) and would require inventing a new
# structural anchor for arbitrary agent prose, not converting an existing one.
_liveness_newest_pointer() {
  local comments_json="${1:-[]}"
  jq -r '
    [.[] | select(.body | test("Agent Session Report|Dev Session ID:|Review Session|Review findings:|Review PASSED"))]
    | sort_by(.createdAt) | last
    | if . == null then "" else "\(.createdAt): \(.body[0:200])" end
  ' <<<"$comments_json" 2>/dev/null || echo ""
}

# The orchestration (_liveness_evaluate_issue / run_liveness_watchdog) lives in
# lib-dispatch.sh, NOT here — its one label_swap call site must sit inside a
# file check-spec-drift.sh's Check C actually scans (PIPELINE_FILES:
# autonomous-dev.sh / autonomous-review.sh / dispatcher-tick.sh /
# lib-dispatch.sh). A write site in a fifth, unscanned lib would be invisible
# to the spec-drift gate. This file stays pure helpers only, exactly like
# lib-review-diffcap.sh / lib-review-classify.sh.
