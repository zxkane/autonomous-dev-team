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
# against itself.
_LIVENESS_IDEMPOTENT_PATTERN='stale-verdict:|INV-12-completed:|INV-12-no-pr-fresh-dev:|INV-35-fresh-dev:|no-progress-substantive(-attempt)?:|non-actionable-finding:|self-heal-lost-session:|self-heal-non-substantive:|crashed-session-retry:|crashed-session-non-actionable:|dispatcher-convergence-breaker:|dispatcher-gate-fail-breaker:|dispatcher-token:|INV-25-hygiene:|dispatcher-liveness-watchdog:'

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
_LIVENESS_DIGEST_PATTERN='stale-verdict:|INV-12-completed:|INV-12-no-pr-fresh-dev:|INV-35-fresh-dev:|no-progress-substantive(-attempt)?:|non-actionable-finding:|self-heal-lost-session:|self-heal-non-substantive:|crashed-session-retry:|crashed-session-non-actionable:|dispatcher-convergence-breaker:|dispatcher-gate-fail-breaker:|dispatcher-token:|INV-25-hygiene:'

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
# [codex review, PR #472, BLOCKING sibling fix] Every listed grammar
# (`dispatcher-convergence-breaker:`, `dispatcher-token:`,
# `INV-25-hygiene:`, etc.) is posted by the DISPATCHER's own process
# (dispatcher-tick.sh / lib-dispatch.sh), which — like the watchdog's own
# marker read-back this mirrors — NEVER resolves `BOT_LOGIN`. An
# unconditional `authorKind != "human"` gate would therefore reject EVERY
# one of these genuine markers under `GH_AUTH_MODE=token` (the dispatcher's
# comments there normalize to `authorKind=human`), collapsing the digest to
# "" on every tick regardless of which markers are actually present — dead
# on the "a NEW marker appearing = progress" signal in the common topology.
# Same fix as `_liveness_evaluate_issue`'s prior-marker readback: apply the
# authorKind filter only when `BOT_LOGIN` is actually set (the rare/never
# case at this call site today), else rely on the pattern match alone.
_liveness_marker_digest() {
  local comments_json="${1:-[]}"
  local _strict=0
  [ -n "${BOT_LOGIN:-}" ] && _strict=1
  jq -r --arg pat "$_LIVENESS_DIGEST_PATTERN" --arg strict "$_strict" '
    [.[] | select(($strict == "0") or ((.authorKind // "human") != "human")) | select(.body | test($pat)) | .body
     | [scan("(?:^|[^A-Za-z0-9_-])((?:" + $pat + "))")[0]]]
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
# _liveness_marker <issue> <fingerprint> <count> <tier1> — construct the
# marker text ([R4]).
_liveness_marker() {
  local issue="$1" fingerprint="$2" count="$3" tier1="$4"
  printf '<!-- dispatcher-liveness-watchdog: issue=%s fingerprint=%s count=%s tier1=%s -->' \
    "$issue" "$fingerprint" "$count" "$tier1"
}

# _liveness_parse_marker <marker_text> <fingerprint> <field> — echo the
# named field (count|tier1) from marker_text IFF it matches the given
# fingerprint; else echo 0. Pure substring/regex extraction — a malformed,
# absent, or non-matching marker all collapse to 0 (bias to MISS).
_liveness_parse_marker() {
  local marker_text="$1" fingerprint="$2" field="$3"
  local pattern="dispatcher-liveness-watchdog: issue=[0-9]+ fingerprint=${fingerprint} count=([0-9]+) tier1=([01])"
  if [[ "$marker_text" =~ $pattern ]]; then
    if [[ "$field" == "count" ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    else
      printf '%s\n' "${BASH_REMATCH[2]}"
    fi
  else
    printf '0\n'
  fi
}

# _liveness_prior_marker <comments_json> <strict_author> — the CUTOFF-then-
# scan prior-marker read ([codex review, PR #472, BLOCKING] fix #2). Mirrors
# `_review_cap_prior_marker`'s cutoff convention (lib-review-cap.sh, itself
# mirroring [INV-05]'s "Marking as stalled" cutoff): the tier-2 TIER2REPORT
# heredoc EMBEDS its own `dispatcher-liveness-watchdog:` marker (R4 requires
# posting on EVERY evaluated tick, including the trip tick itself). Without a
# cutoff, an operator who fixes whatever caused the park and re-arms the
# issue (removes `stalled`, restoring `pending-dev`/`pending-review`) with an
# otherwise-UNCHANGED fingerprint would have the very next evaluation read
# that OLD trip report's marker back — high count, tier1=1 — and immediately
# re-trip tier 2 again, instead of starting a fresh liveness episode.
#
# cutoff = the latest qualifying comment whose body contains the tier-2 trip
# heading ("Liveness watchdog tripped"); the epoch if no trip has ever fired.
# Markers AT OR BEFORE the cutoff are excluded (strict `>`, mirrors
# `_review_cap_prior_marker`'s own strict inequality) — this excludes the trip
# report's own embedded marker (its createdAt EQUALS the cutoff) while still
# admitting a genuinely later post-resume marker.
#
# `strict_author` uses the SAME BOT_LOGIN-gated authenticity filter as the
# marker-fence scan itself (NOT an unconditional `authorKind != "human"`,
# which would reject the genuine trip report in the common
# `GH_AUTH_MODE=token` topology and leave the cutoff permanently at the
# epoch — reopening the exact BOT_LOGIN-empty bug the marker-fence
# authenticity fix already closed). Both the cutoff computation and the
# final scan are derived from the SAME filtered `$rows` so they never
# disagree on which comments are eligible.
_liveness_prior_marker() {
  local comments_json="${1:-[]}" strict="${2:-0}"
  local anchor='^<!-- dispatcher-liveness-watchdog: issue=[0-9]+ fingerprint=[0-9a-f]+ count=[0-9]+ tier1=[01] -->($|\n)'
  jq -r --arg strict "$strict" --arg anchor "$anchor" '
    ( [ .[] | select(($strict == "0") or ((.authorKind // "human") != "human")) | select(.body | type == "string") ] ) as $rows
    | ( [ $rows[] | select(.body | contains("Liveness watchdog tripped")) | .createdAt ]
        + ["1970-01-01T00:00:00Z"] | max ) as $cutoff
    | ( [ $rows[] | select(.body | test($anchor)) | select(.createdAt > $cutoff) ]
        | sort_by(.createdAt) | last | .body // "" )
  ' <<<"$comments_json" 2>/dev/null || printf ''
}

# _liveness_next_count <marker_text> <fingerprint> — stored_count+1 when
# marker_text matches fingerprint exactly, else 1 (fresh series under a new
# fingerprint — full reset, R1/R4).
_liveness_next_count() {
  local marker_text="$1" fingerprint="$2" stored
  stored=$(_liveness_parse_marker "$marker_text" "$fingerprint" count)
  printf '%s\n' "$((stored + 1))"
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
