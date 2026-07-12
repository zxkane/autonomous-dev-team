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
# Idempotent-notice exclusion list ([R1]).
#
# A single grep-able pattern list, mirrored next to the marker grammars it
# excludes. Every one of these is a KNOWN idempotent-notice/marker grammar
# already posted by an existing breaker/self-heal path — counting any of them
# as "progress" would reset the watchdog's clock on a park's own first notice,
# and the park would never be detected (the exact failure mode this lib exists
# to close). The watchdog's OWN marker (`dispatcher-liveness-watchdog:`) is
# included so its own per-tick bookkeeping comment never counts as progress
# against itself. `reason=liveness-no-progress`/`reason=liveness-timeout`
# (the tier-1/tier-2 human-readable reports) are ALSO included: [operator
# guidance, round 6] the marker is now ALWAYS posted as its own bare comment
# (never embedded as the report's first line — see `_liveness_evaluate_issue`)
# so the tier-1/tier-2 REPORT is a second, textually-distinct comment that no
# longer contains the `dispatcher-liveness-watchdog:` substring itself. Without
# this addition the report's own posting would register as "a genuinely new
# comment" against `non_idempotent_count`, changing the fingerprint on the very
# next tick and resetting the counter — the SAME self-referential-pollution bug
# D3 already fixed for the marker, now reintroduced by the report text once the
# two were split apart.
# [codex review, PR #472, round 8 BLOCKING #2] This alternation is a
# substring test (`test($pat)`), NOT an anchored one — a HUMAN comment
# merely DISCUSSING or QUOTING a token in prose (e.g. "I saw
# reason=liveness-timeout mentioned somewhere") satisfied the bare
# alternation exactly as well as the genuine wrapped marker/report text
# does, wrongly EXCLUDING that prose comment from the count and masking real
# progress. Every genuine producer wraps its token in EXACTLY one of two
# ways — a backtick-fenced code span (`` `token` ``, e.g. this file's own
# `` `reason=liveness-timeout` `` report line) or the literal opening of an
# HTML comment (`<!-- token`, e.g. `dispatcher-token:`/this watchdog's own
# `dispatcher-liveness-watchdog:` marker) — never bare in running prose. The
# `` (?:\`|<!--[ \t]*) `` prefix requires one of those two wrappers
# immediately before the token; every existing call site already wraps this
# way, so no genuine marker/report is rejected, only bare-prose mentions.
# Oniguruma-safe (jq's `test`/`scan` engine, not `gh --jq`'s RE2) — the
# wrapper is matched literally in front of the token, not via look-behind,
# so the RE2 "no variable-width look-behind" constraint never applies here.
# The wrapper group and every inner alternative group are NON-capturing
# (`(?:...)`) so `_liveness_marker_digest`'s `scan()` extraction (which reads
# the LAST capture group) is never confused by a nested group — see
# `no-progress-substantive(?:-attempt)?:`'s own inner group below.
_LIVENESS_IDEMPOTENT_PATTERN='(?:`|<!--[ \t]*)(stale-verdict:|INV-12-completed:|INV-12-no-pr-fresh-dev:|INV-35-fresh-dev:|no-progress-substantive(?:-attempt)?:|non-actionable-finding:|self-heal-lost-session:|self-heal-non-substantive:|crashed-session-retry:|crashed-session-non-actionable:|dispatcher-convergence-breaker:|dispatcher-gate-fail-breaker:|dispatcher-token:|INV-25-hygiene:|dispatcher-liveness-watchdog:|reason=liveness-no-progress|reason=liveness-timeout)'

# Marker-digest pattern ([R1]/[D3]) — the SAME grammar list, MINUS
# `dispatcher-liveness-watchdog:` itself. The digest's whole purpose is "a
# NEW marker appearing = progress" for OTHER breakers/self-heal paths; the
# watchdog's own marker is posted deterministically on every evaluated tick
# once tier 1 fires (or unconditionally, on the bare-marker `none` path), so
# including it here would flip the digest exactly once (empty -> present)
# and then hold it constant forever — a one-time false "progress" signal on
# tick 2 that then permanently pollutes the fingerprint with a component
# that carries no information (it is always present from then on). Excluded
# from the digest for the same reason it is excluded from the count.
# Wrapped in the SAME `` (?:\`|<!--[ \t]*) `` anchor as
# `_LIVENESS_IDEMPOTENT_PATTERN`, for the identical reason (round 8): without
# it, a human comment merely quoting/discussing a grammar prefix in prose —
# e.g. "quoting the marker: dispatcher-convergence-breaker: issue=1
# head=abc" — would falsely register that grammar as PRESENT in the digest,
# a false "progress" signal usable to reset the watchdog's clock on demand.
_LIVENESS_DIGEST_PATTERN='(?:`|<!--[ \t]*)(stale-verdict:|INV-12-completed:|INV-12-no-pr-fresh-dev:|INV-35-fresh-dev:|no-progress-substantive(?:-attempt)?:|non-actionable-finding:|self-heal-lost-session:|self-heal-non-substantive:|crashed-session-retry:|crashed-session-non-actionable:|dispatcher-convergence-breaker:|dispatcher-gate-fail-breaker:|dispatcher-token:|INV-25-hygiene:)'

# _LIVENESS_TIER2_HEADING — the tier-2 trip report's exact opening line
# ([codex review, PR #472, round 7 BLOCKING]). Single-sourced here so
# `_liveness_evaluate_issue`'s TIER2REPORT heredoc (lib-dispatch.sh) and
# `_liveness_prior_marker`'s cutoff detection below can never drift apart —
# a producer/detector text mismatch would silently reopen the cutoff bug this
# constant exists to close. `_liveness_prior_marker` matches it via
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
# whose body does NOT match any known idempotent-notice/marker grammar
# (_LIVENESS_IDEMPOTENT_PATTERN). Pure — comments_json is already fetched by
# the caller. Relies on the itp_list_comments contract (INV-90) that `body`
# is always a string, never JSON null — a null would error `test()` under
# `2>/dev/null` and collapse the count to 0 (bias to MISS, not a crash).
_liveness_non_idempotent_count() {
  local comments_json="${1:-[]}"
  jq -r --arg pat "$_LIVENESS_IDEMPOTENT_PATTERN" \
    '[.[] | select(.body | test($pat) | not)] | length' \
    <<<"$comments_json" 2>/dev/null || echo 0
}

# _liveness_marker_digest <comments_json>
#
# Echoes a stable digest of which known marker grammars are PRESENT
# (authorKind-gated when possible, mirrors INV-105/INV-122's own
# marker-authenticity filter) — a sorted, comma-joined list of matched
# grammar prefixes. A NEW grammar appearing changes the digest (progress),
# even when that same grammar is excluded from the non-idempotent comment
# count above. Uses _LIVENESS_DIGEST_PATTERN (NOT the count pattern) —
# deliberately excludes the watchdog's own marker, see that pattern's
# docstring.
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
  # `.[-1]` (equivalent to `.[0]` today, but robust against a future
  # capture-group addition) — `$pat`'s wrapper (`(?:` `|<!--[ \t]*)`) and
  # every inner alternative's own group (e.g. `no-progress-substantive
  # (?:-attempt)?:`) are deliberately ALL non-capturing, so the token
  # alternation is the ONLY capturing group `scan()` yields per match today —
  # `.[0]` and `.[-1]` currently return byte-identical results. `.[-1]`
  # is used anyway because it is the position-INDEPENDENT choice: the token
  # (what the digest actually wants to join on) is always the LAST capture
  # regardless of how many non-capturing groups precede it, so a future edit
  # that adds a genuine capturing group in front of the token (accidentally
  # or otherwise) fails safe here instead of silently swapping in the wrong
  # substring the way `.[0]` would.
  jq -r --arg pat "$_LIVENESS_DIGEST_PATTERN" --arg strict "$_strict" '
    [.[] | select(($strict == "0") or ((.authorKind // "human") != "human")) | select(.body | test($pat)) | .body
     | [scan("(?:^|[^A-Za-z0-9_-])(?:" + $pat + ")")[-1]]]
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
