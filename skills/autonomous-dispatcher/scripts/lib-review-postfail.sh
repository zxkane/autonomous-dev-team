#!/bin/bash
# lib-review-postfail.sh — CLI-agnostic post-failed verdict drop-reason detector
# (INV-69, issue #247).
#
# WHY this exists
# ---------------
# Every review CLI posts its verdict through the SAME deterministic helper
# `post-verdict.sh` ([INV-56](docs/pipeline/invariants.md)). When that helper's
# underlying `gh issue comment` returns non-zero, it correctly exits 1 — but the
# helper runs INSIDE the agent's own session, so its non-zero exit is observed by
# the agent, never by the wrapper. The wrapper's no-verdict resolution keys only
# on the CLI launch rc and on comment-absence, so a verdict whose post failed at
# `gh` time collapses into the same opaque `unavailable` ([INV-40]) drop as an
# agent that never reviewed at all — the wrapper cannot tell "reviewed but the
# post failed" from "never reached a verdict".
#
# This is the explicitly-deferred follow-up from #202 ("Out of scope"): give that
# non-zero exit a channel the wrapper reads. On a failed post, `post-verdict.sh`
# writes a BREADCRUMB at a deterministic, session-keyed path under
# `pid_dir_for_project()` (`verdict-postfail-<session_id>`); this lib reads that
# breadcrumb AFTER verdict resolution and classifies the drop so the wrapper can
# surface a distinct, actionable `post-failed` reason in the WARN log line + the
# posted "dropped agent(s)" issue comment.
#
# LAYER (load-bearing, mirrors lib-review-agy.sh)
# -----------------------------------------------
# A REVIEW-side lib, NOT generic plumbing. Unlike the per-CLI agy/codex/kiro
# detectors it is CLI-AGNOSTIC: it keys on a SESSION ID, not on a per-CLI log,
# because the post step is shared by all CLIs. It does NOT change the [INV-40]
# vote: a post-failed agent is STILL dropped from the unanimous-PASS aggregation
# exactly as `unavailable` (it posted no classifiable verdict comment, so it
# cannot be a deciding vote) — the classification is OBSERVABILITY ONLY. The
# wrapper evaluates this detector FIRST, before the per-CLI scrapers: a confirmed
# post failure is the most specific cause; with no breadcrumb the agent falls
# through to the existing agy/codex/kiro branches unchanged.
#
# SCOPE: only the review wrapper's drop-reason augmentation calls this. grep-based,
# single pass; no jq (the breadcrumb is plain `key=value` lines).

# _postfail_breadcrumb_path <session_id>
#
# Echo the deterministic breadcrumb path for a session id, under
# `pid_dir_for_project()`. Echoes empty (rc 0) when the session id is empty or
# the pid dir cannot resolve — so a caller can treat "no path" as "no breadcrumb"
# without aborting under `set -euo pipefail`. `pid_dir_for_project` comes from
# lib-config.sh, which the wrapper (and post-verdict.sh) already source.
_postfail_breadcrumb_path() {
  local session_id="${1:-}"
  [[ -n "$session_id" ]] || return 0
  local pid_dir
  pid_dir=$(pid_dir_for_project 2>/dev/null) || return 0
  [[ -n "$pid_dir" ]] || return 0
  printf '%s/verdict-postfail-%s\n' "$pid_dir" "$session_id"
}

# _classify_postfail_drop_reason <session_id>
#
# Check for a post-failed breadcrumb for the given session id and classify it.
# Echoes ONE token on stdout (rc 0 always):
#
#   post-failed:gh-rc <n>
#       — a breadcrumb exists AND records the `gh` rc the post failed with.
#   post-failed
#       — a breadcrumb exists but records no parseable `gh_rc`.
#   "" (empty)
#       — no breadcrumb (the caller keeps the bare `unavailable` and falls
#         through to the per-CLI scrapers).
#
# Fail-safe: an empty session id, an unresolvable pid dir, or a missing /
# unreadable / non-regular breadcrumb echoes empty and returns 0 — the review
# wrapper runs under `set -euo pipefail`, so this must never abort (a non-zero
# `$(…)` in the wrapper's `_dropped_reasons` append would crash mid-loop and
# strand the issue in `reviewing`).
_classify_postfail_drop_reason() {
  local session_id="${1:-}"
  [[ -n "$session_id" ]] || return 0

  local bc
  bc=$(_postfail_breadcrumb_path "$session_id") || return 0
  [[ -n "$bc" && -f "$bc" && -r "$bc" ]] || return 0

  # Pull the recorded gh rc when present. A `gh_rc=<digits>` line is the only
  # rc source; anything else yields the bare token. When the breadcrumb has NO
  # `gh_rc` line the `grep` exits 1, and under `set -o pipefail` the whole
  # pipeline exits 1 too — which under `set -e` would abort THIS assignment.
  # The `if` below tests `$rc_val`, NOT the pipeline rc, so it canNOT rescue a
  # failed assignment (the failure happens at the assignment, before the `if`).
  # The trailing `|| true` consumes the rc INSIDE the command substitution so
  # the assignment always succeeds and the bare-`post-failed` path (a breadcrumb
  # with no parseable rc — the documented partial-breadcrumb case) is reached
  # instead of aborting the `set -euo pipefail` review wrapper. (#247 finding.)
  local rc_val
  rc_val=$(grep -oE '^gh_rc=[0-9]+' "$bc" 2>/dev/null | head -1 | cut -d= -f2 || true)
  if [[ -n "$rc_val" ]]; then
    printf 'post-failed:gh-rc %s\n' "$rc_val"
  else
    printf 'post-failed\n'
  fi
  return 0
}

# _postfail_drop_reason_phrase <reason-token>
#
# Render a reason token from _classify_postfail_drop_reason into a single
# human-facing clause for the WARN log line and the posted dropped-agent comment.
# Echoes empty for an empty/unknown token (the caller then keeps the bare
# `unavailable` wording). rc 0 always.
#
#   post-failed:gh-rc 1
#       → "post-failed (verdict comment post failed; cli rc 1 — transient GitHub/API or token error)"
#   post-failed
#       → "post-failed (verdict comment post failed — transient GitHub/API or token error)"
_postfail_drop_reason_phrase() {
  local token="${1:-}"
  case "$token" in
    post-failed:gh-rc\ *)
      # Strip the leading "post-failed:gh-rc " to recover the rc number.
      local rc="${token#post-failed:gh-rc }"
      printf 'post-failed (verdict comment post failed; cli rc %s — transient GitHub/API or token error)\n' "$rc"
      ;;
    post-failed)
      printf 'post-failed (verdict comment post failed — transient GitHub/API or token error)\n'
      ;;
    *)
      # Empty or unknown token → empty phrase (no over-claim).
      ;;
  esac
  return 0
}
