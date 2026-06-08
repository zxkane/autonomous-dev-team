#!/bin/bash
# lib-review-agy.sh — agy (Antigravity CLI) quota/auth drop-reason detector
# (INV-58, issue #205).
#
# WHY this exists
# ---------------
# When the `agy` member of a multi-agent review fan-out hits the Antigravity
# consumer **quota wall** (HTTP 429 `RESOURCE_EXHAUSTED`, "Individual quota
# reached") or an **auth failure** ("not logged into Antigravity" / failed OAuth
# token), agy exits with rc 0 and EMPTY stdout/stderr, posts no verdict comment,
# and the wrapper's post-window sweep resolves it as a bare `unavailable`
# ([INV-40](docs/pipeline/invariants.md)). That is indistinguishable from a CLI
# launch failure or a genuine no-verdict miss — and on an `agy codex` AND-gate it
# silently degrades the fleet to codex-only with no operator-visible cause.
#
# The 429 / auth signal IS present, but only in agy's OWN `--log-file`
# (`pid_dir_for_project()/agy-log-<session_id>.log`, written by the `agy` branch
# of `lib-agent.sh::run_agent`), never on the stream the wrapper reads. This lib
# scrapes that log AFTER the agent exits and classifies the drop so the wrapper
# can surface a distinct, actionable reason (with the "Resets in <dur>" recovery
# window) in the WARN log line + the posted "dropped agent(s)" issue comment.
#
# LAYER (load-bearing, mirrors lib-review-codex.sh)
# -------------------------------------------------
# This is a CLI-specific REVIEW-side lib, NOT generic plumbing. Like the codex
# resume controller, it reads the CLI's OWN log file and never queries GitHub.
# It does NOT change the [INV-40] vote: a quota/auth agy is STILL dropped from the
# unanimous-PASS aggregation exactly as `unavailable` is today — the
# classification is **observability only** (a quota wall is an infra condition,
# not a code rejection; promoting it to a deciding FAIL would block every merge
# whenever agy's daily quota is spent, which is worse than degrading to the
# surviving fleet members). The wrapper attaches the reason to the human-visible
# breadcrumb path only.
#
# SCOPE: only the review wrapper's drop-reason augmentation calls this, and only
# for a fan-out member whose CLI is `agy`. grep-based, single pass; no jq (agy
# emits no JSON stream — mirrors lib-agent.sh::_agy_capture_conversation).

# _classify_agy_drop_reason <log_file>
#
# Scrape an agy `--log-file` for a quota or auth failure signal. Echoes ONE token
# on stdout (rc 0 always):
#
#   quota-exhausted[:Resets in <dur>]
#       — the log shows a 429 / "Individual quota reached" signal. The
#         ":Resets in <dur>" suffix is appended ONLY when agy printed a
#         "Resets in …" recovery window (the operator's "roughly when it
#         recovers"). Quota takes PRECEDENCE over auth: agy logs the failed
#         OAuth/not-logged-in line as a SIDE EFFECT of the same call that hit the
#         quota wall (both appear in the live repro), so a log with both is
#         fundamentally a quota drop.
#   auth-failed
#       — an auth/login signal ("not logged into Antigravity" / "Failed to get
#         OAuth token") with NO quota signal.
#   "" (empty)
#       — neither signal present (the caller keeps the bare `unavailable`).
#
# Fail-safe: a missing / empty / unreadable / empty-arg log echoes empty and
# returns 0 — the review wrapper runs under `set -euo pipefail`, so this must
# never abort. The matches are fixed-substring (grep -F) so a metachar in the log
# can never break the scan.
_classify_agy_drop_reason() {
  local log_file="${1:-}"
  [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]] || return 0

  # Quota signal — either the canonical 429 marker or the human phrase. Both are
  # fixed substrings; -q -F is a clean presence check that never aborts under
  # set -e (grep rc 1 = no match is expected and consumed by the `if`).
  if grep -qF 'RESOURCE_EXHAUSTED' "$log_file" 2>/dev/null \
     || grep -qF 'Individual quota reached' "$log_file" 2>/dev/null; then
    # Extract the recovery window when agy printed one. The duration is a run of
    # <number><unit> segments (h/m/s), e.g. 33h48m45s, 45m10s, 30s, 12h05m. The
    # ERE is anchored on the "Resets in " literal so unrelated digits never match.
    local reset
    reset=$(grep -oE 'Resets in [0-9]+[hms]([0-9]+[hms])*' "$log_file" 2>/dev/null | head -1)
    if [[ -n "$reset" ]]; then
      printf 'quota-exhausted:%s\n' "$reset"
    else
      printf 'quota-exhausted\n'
    fi
    return 0
  fi

  # Auth signal (only reached when there is NO quota signal).
  if grep -qF 'not logged into Antigravity' "$log_file" 2>/dev/null \
     || grep -qF 'Failed to get OAuth token' "$log_file" 2>/dev/null; then
    printf 'auth-failed\n'
    return 0
  fi

  return 0
}

# _agy_drop_reason_phrase <reason-token>
#
# Render a reason token from _classify_agy_drop_reason into a single human-facing
# clause for the WARN log line and the posted dropped-agent comment. Echoes empty
# for an empty/unknown token (the caller then keeps the bare `unavailable`
# wording). rc 0 always.
#
#   quota-exhausted:Resets in 33h48m45s
#       → "quota-exhausted (Antigravity 429: daily quota reached; resets in 33h48m45s)"
#   quota-exhausted
#       → "quota-exhausted (Antigravity 429: daily quota reached)"
#   auth-failed
#       → "auth-failed (agy not logged into Antigravity / OAuth token unavailable)"
_agy_drop_reason_phrase() {
  local token="${1:-}"
  case "$token" in
    quota-exhausted:*)
      # Strip the leading "quota-exhausted:" to recover the "Resets in <dur>" text.
      local window="${token#quota-exhausted:}"
      # Lowercase the leading "Resets" so the parenthetical reads as prose.
      printf 'quota-exhausted (Antigravity 429: daily quota reached; %s)\n' \
        "$(printf '%s' "$window" | sed 's/^Resets in /resets in /')"
      ;;
    quota-exhausted)
      printf 'quota-exhausted (Antigravity 429: daily quota reached)\n'
      ;;
    auth-failed)
      printf 'auth-failed (agy not logged into Antigravity / OAuth token unavailable)\n'
      ;;
    *)
      # Empty or unknown token → empty phrase.
      ;;
  esac
  return 0
}
