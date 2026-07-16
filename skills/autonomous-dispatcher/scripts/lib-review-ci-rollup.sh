#!/bin/bash
# lib-review-ci-rollup.sh — INV-134 reviewed-HEAD CI-rollup hard gate
# (issue #489).
#
# The review wrapper's pre-approve gate chain never reads the CI check
# rollup: INV-46 (E2E hard gate) fetches ONLY the dedicated E2E job's
# evidence, and INV-44 (mergeable hard gate) is a merge-conflict gate
# (`mergeable` field), not a CI-status gate. So a PR whose fan-out agents
# passed and whose mergeable gate is clean can still reach `approved` while
# a configured GitHub Actions check on the reviewed HEAD is red. This
# module is the pure decision half of the new gate that closes that hole,
# split the same way lib-review-mergeable.sh splits INV-44: the
# `chp_ci_rollup` I/O + retry/wait loop stays in the wrapper; the
# token → action mapping lives here so it is unit-testable without a live PR.

# _classify_ci_rollup_gate <token>
#
# Maps a `chp_ci_rollup` token (`green|pending|failed|none`, or empty on a
# leaf rc≠0 transport/parse failure) to one of three gate actions:
#
#   proceed              — `green` or `none`. A repo with zero checks must
#                          not block approval (issue #489 D3); `chp_ci_status`
#                          contrast: THAT leaf's SKIPPED→pending mapping is
#                          deliberately NOT reused here (chp_ci_rollup's own
#                          SKIPPED/NEUTRAL-is-non-blocking token derivation
#                          already folds an all-skipped set into `green`).
#   block-substantive    — `failed`. A red check on the reviewed HEAD is a
#                          real, dev-actionable finding — the wrapper posts a
#                          finding naming every entry in `failed_checks` and
#                          routes to pending-dev. Never approve.
#   block-nonsubstantive — `pending`, empty (the leaf's rc≠0 sentinel), or any
#                          unrecognized token. The wrapper's bounded-wait
#                          mechanics (SHA-scoped marker + CI_ROLLUP_WAIT_MAX)
#                          decide the specific routing (pending-review below
#                          the cap, pending-dev at the cap) — this classifier
#                          only decides "not clear to approve yet."
#
# Conservative by construction: the ONLY inputs that proceed are `green` and
# `none`. Every other value (including a `failed`-vs-`pending` policy
# decision, which per issue #489 D3 explicitly must NOT be conflated) blocks.
# Returns 0 always; the decision is on stdout.
_classify_ci_rollup_gate() {
  local token="${1:-}"

  case "$token" in
    green|none)
      printf 'proceed\n'
      ;;
    failed)
      printf 'block-substantive\n'
      ;;
    *)
      # pending, empty (leaf transport/parse failure), or any unrecognized
      # future token → never proceed.
      printf 'block-nonsubstantive\n'
      ;;
  esac
}

# _ci_rollup_wait_max — read CI_ROLLUP_WAIT_MAX with the same
# regex-then-fallback shape as lib-review-e2e.sh's _gate_breaker_threshold
# (INV-122: GATE_FAIL_STALL_THRESHOLD), plus an explicit floor of 1 and a
# logged WARNING on any fallback. Note: BOT_REVIEW_WAIT_MAX itself (read
# inline in autonomous-review.sh) has NO such validation — only
# _gate_breaker_threshold's actual regex-then-fallback-with-WARNING shape is
# the real precedent this helper mirrors.
_ci_rollup_wait_max() {
  local raw="${CI_ROLLUP_WAIT_MAX:-3}"
  local val="$raw"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; then
    # Always stderr, NEVER via log() — every call site captures this
    # function's stdout via `$(...)` for the numeric result (mirrors
    # _gate_breaker_threshold's own rationale verbatim).
    echo "WARNING: CI_ROLLUP_WAIT_MAX='${raw}' invalid (must be an integer >=1) — falling back to default 3" >&2
    val=3
  fi
  printf '%s\n' "$val"
}

# _ci_rollup_wait_marker <issue> <head> — construct the SHA-bound wait
# marker text (issue #489 D3). A new head resets the count by construction
# (markers are SHA-bound) — mirrors the INV-79 bot-review-wait marker shape
# exactly, just with this gate's own comment key.
_ci_rollup_wait_marker() {
  # `${2:-unknown}` substitutes the placeholder for BOTH an unset and an
  # empty second arg (`:-`, not `-`), so an explicit "" head still renders
  # `head=unknown` — mirrors the sibling INV-79 marker's inline
  # `${PR_HEAD_SHA:-unknown}` (no separate empty-string guard needed).
  local issue="$1" head="${2:-unknown}"
  printf '<!-- ci-rollup-wait: issue=%s head=%s -->' "$issue" "$head"
}
