#!/bin/bash
# lib-review-diffcap.sh — INV-124 PR-diff-size (over-reach) soft signal
# (issue #452).
#
# Anthropic's Loop Engineering guidance calls out two failure modes to watch
# for when running loops: stall (agent stuck) and over-reach (agent doing too
# much). This pipeline's stall detection is thorough (grace window,
# near-success cross-checks, PID heartbeat) but had no signal for the
# opposite failure — a dev agent expanding a small issue into a sweeping
# multi-file change that still passes every mechanical gate.
#
# This lib is a PURE decision surface (mirrors lib-review-classify.sh /
# lib-review-mergeable.sh): threshold comparison + the prompt-note renderer.
# It does NO I/O itself — the provider-seam read (`chp_pr_diffstat`) and the
# `metrics_emit` call are wrapper-side (autonomous-review.sh), which is the
# only place with `chp_*`/`metrics_emit` in scope and the only place that
# knows "once per review round, not once per fan-out member."
#
# SOFT SIGNAL, NEVER A GATE: nothing in this file is read by any
# verdict-aggregation code path, `_classify_*_gate` function, or the
# PASS/FAIL/merge decision. See INV-124 (docs/pipeline/invariants.md).

# _diff_cap_normalize <raw-value>
#
# Normalizes a PR_DIFF_SOFT_CAP_FILES / PR_DIFF_SOFT_CAP_LINES config value to
# either a positive integer (echoed) or empty (rc 0 either way — "disabled" is
# not an error). Empty/unset, `0`, negative, non-numeric, or whitespace all
# normalize to empty — silent degrade per the issue's design, never a startup
# error. This is a per-key independent probe: the caller normalizes each
# threshold key separately.
_diff_cap_normalize() {
  local raw="${1:-}"
  # Trim surrounding whitespace so " 40 " normalizes like "40".
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [[ "$raw" =~ ^[0-9]+$ ]] && [[ "$raw" -gt 0 ]] && printf '%s' "$raw"
  return 0
}

# review_diff_soft_cap_dimensions_needed <files-cap> <lines-cap>
#
# Echoes the comma-separated DIMENSIONS-CSV the wrapper should request from
# `chp_pr_diffstat` — "files", "lines", "files,lines", or empty when BOTH caps
# are unset (the caller then skips the provider-seam read entirely: zero
# behavior change, no metrics event). Each arg is a value already normalized
# by `_diff_cap_normalize` (non-empty ⇒ that dimension is configured).
review_diff_soft_cap_dimensions_needed() {
  local files_cap="${1:-}" lines_cap="${2:-}"
  local out=""
  [[ -n "$files_cap" ]] && out="files"
  [[ -n "$lines_cap" ]] && out="${out:+${out},}lines"
  printf '%s' "$out"
}

# review_diff_over_reach <changed-files> <changed-lines> <files-cap> <lines-cap>
#
# Pure threshold comparison. Each of the four args is either a non-negative
# integer or empty (empty changed-files/changed-lines means "the provider-seam
# read did not return this dimension — treat as unreadable"; empty
# files-cap/lines-cap means "that dimension is not configured").
#
#   over_reach = (files-cap set AND changed-files >  files-cap)
#             OR (lines-cap set AND changed-lines >  lines-cap)
#
# Strict `>` (never `>=` — exactly-at-cap does NOT trigger). An unreadable
# stat (empty changed-files/changed-lines) NEVER contributes `true` for that
# dimension, regardless of whether its cap is set — fail-open, never
# fabricates a warning from an unreadable stat. Echoes `true` or `false`;
# always rc 0.
review_diff_over_reach() {
  local changed_files="${1:-}" changed_lines="${2:-}" files_cap="${3:-}" lines_cap="${4:-}"
  local over_reach=false
  if [[ -n "$files_cap" && -n "$changed_files" ]] && [[ "$changed_files" -gt "$files_cap" ]]; then
    over_reach=true
  fi
  if [[ -n "$lines_cap" && -n "$changed_lines" ]] && [[ "$changed_lines" -gt "$lines_cap" ]]; then
    over_reach=true
  fi
  printf '%s' "$over_reach"
}

# review_diff_soft_cap_prompt_note <over-reach> <changed-files> <changed-lines> <files-cap> <lines-cap>
#
# Mirrors lib-review-classify.sh::review_protected_paths_prompt_rule — an
# echo-only pure function producing a markdown snippet, interpolated into
# build_review_prompt()'s heredoc via `$(...)`. Empty output when
# <over-reach> is not the literal string "true" (so both-caps-unset and
# under-cap PRs render byte-identical to pre-change — no stray blank
# section). Names the measured stat(s) and the exceeded dimension(s); states
# explicitly that this is advisory, not a verdict.
review_diff_soft_cap_prompt_note() {
  local over_reach="${1:-}" changed_files="${2:-}" changed_lines="${3:-}" files_cap="${4:-}" lines_cap="${5:-}"
  [[ "$over_reach" == "true" ]] || return 0

  local files_exceeded=false lines_exceeded=false
  if [[ -n "$files_cap" && -n "$changed_files" ]] && [[ "$changed_files" -gt "$files_cap" ]]; then
    files_exceeded=true
  fi
  if [[ -n "$lines_cap" && -n "$changed_lines" ]] && [[ "$changed_lines" -gt "$lines_cap" ]]; then
    lines_exceeded=true
  fi

  cat <<NOTE

## Diff-size advisory (over-reach signal, informational — NOT a verdict)

This PR's diff is large relative to the configured soft cap(s):
$(if [[ "$files_exceeded" == "true" ]]; then printf -- '- Changed files: %s (cap: %s)\n' "$changed_files" "$files_cap"; fi)$(if [[ "$lines_exceeded" == "true" ]]; then printf -- '- Changed lines: %s (cap: %s)\n' "$changed_lines" "$lines_cap"; fi)
This is advisory only — a heuristic proxy for "did this PR grow beyond what
the issue described." It is NOT a verdict and does not by itself block a
PASS: a legitimately large PR (migration, refactor) can and should still
PASS when its content otherwise satisfies the checklist and acceptance
criteria. Use it to weight your review attention toward whether the PR's
actual scope matches the issue's requirements.
NOTE
}
