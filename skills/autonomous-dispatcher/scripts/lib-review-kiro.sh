#!/bin/bash
# lib-review-kiro.sh — kiro (Kiro CLI) auth/login-failure drop-reason detector
# (INV-61, issue #215).
#
# WHY this exists
# ---------------
# When the `kiro` member of a multi-agent review fan-out has an EXPIRED stored
# OAuth/login token on the execution host, the Kiro CLI tries to open a browser
# for device-flow re-auth. In the headless (SSM-spawned) shell that is impossible,
# so kiro exits at LAUNCH with no verdict comment, and the wrapper's post-window
# sweep resolves it as a bare `unavailable` ([INV-40](docs/pipeline/invariants.md)).
# That is indistinguishable from a CLI launch misconfig or a genuine no-verdict
# miss — and on an `agy kiro` AND-gate (or any kiro-bearing fleet) it silently
# degrades the fleet with no operator-visible cause.
#
# The auth/login signal IS present in kiro's GENERIC per-agent log
# (`/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUMBER}-kiro.log` — the same
# `$_agent_log` the kiro invocation writes to, NOT a separate `--log-file` like
# agy). The observed lines are:
#
#   ▰▱▱ Opening browser... | Press (^) + C to cancel
#   Failed to open browser for authentication.
#   Please try again with: kiro-cli login --use-device-flow
#   error: Failed to open URL
#
# This lib scrapes that log AFTER the agent exits and classifies the drop so the
# wrapper can surface a distinct, actionable reason (naming the operator remedy
# `kiro-cli login --use-device-flow`) in the WARN log line + the posted
# "dropped (unavailable) agent(s)" issue comment.
#
# LAYER (load-bearing, mirrors lib-review-agy.sh / lib-review-codex.sh)
# --------------------------------------------------------------------
# This is a CLI-specific REVIEW-side lib, NOT generic plumbing. Like the agy quota
# detector (INV-58) and the codex stream-error detector (INV-59), it reads the
# CLI's OWN per-agent log file and never queries GitHub. It does NOT change the
# [INV-40] vote: an auth-failed kiro is STILL dropped from the unanimous-PASS
# aggregation exactly as `unavailable` is today — the classification is
# **observability only** (an expired token is an operational/infra condition, not
# a code rejection; promoting it to a deciding FAIL would block every merge
# whenever kiro's token expires on the host, which is worse than degrading to the
# surviving fleet members). The wrapper attaches the reason to the human-visible
# breadcrumb path only.
#
# SCOPE: only the review wrapper's drop-reason augmentation calls this, and only
# for a fan-out member whose CLI is `kiro`. grep-based, single pass; no jq (the
# signal lives in plain CLI stdout/stderr text, not a JSON stream).

# _classify_kiro_drop_reason <log_file>
#
# Scrape a kiro per-agent log for an auth/login failure signal. Echoes ONE token
# on stdout (rc 0 ALWAYS — fail-safe under `set -euo pipefail`, mirrors
# _classify_agy_drop_reason / _classify_codex_drop_reason):
#
#   auth-failed
#       — the log shows the browser/device-flow login signal: ANY of the fixed
#         substrings `Failed to open browser for authentication`,
#         `kiro-cli login`, `--use-device-flow`, or `Failed to open URL`.
#   "" (empty)
#       — no auth signal (the caller keeps the bare `unavailable`). A clean
#         no-verdict kiro turn yields empty — NO over-claim (a no-verdict miss is
#         NOT an auth failure).
#
# Fail-safe: a missing / empty / unreadable / empty-arg log echoes empty and
# returns 0 — the review wrapper runs under `set -euo pipefail`, so this must
# never abort. The matches are fixed-substring (grep -F) so a metachar in the log
# can never break the scan.
_classify_kiro_drop_reason() {
  local log_file="${1:-}"
  [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]] || return 0

  # Auth/login signal — any one of the documented fixed substrings is sufficient.
  # `grep -q -F -e … -e …` is a clean presence check across all alternatives that
  # never aborts under `set -e`: grep rc 1 (no match) is expected and consumed by
  # the `if`. -F means the literals (incl. the `--use-device-flow` leading dashes
  # via -e, which is NOT mistaken for an option) match verbatim.
  if grep -q -F \
       -e 'Failed to open browser for authentication' \
       -e 'kiro-cli login' \
       -e '--use-device-flow' \
       -e 'Failed to open URL' \
       "$log_file" 2>/dev/null; then
    printf 'auth-failed\n'
    return 0
  fi

  return 0
}

# _kiro_drop_reason_phrase <reason-token>
#
# Render a reason token from _classify_kiro_drop_reason into a single human-facing
# clause for the WARN log line and the posted dropped-agent comment. Echoes empty
# for an empty/unknown token (the caller then keeps the bare `unavailable`
# wording). rc 0 always.
#
#   auth-failed
#       → "auth-failed (browser/device-flow login required on the execution host: kiro-cli login --use-device-flow)"
_kiro_drop_reason_phrase() {
  local token="${1:-}"
  case "$token" in
    auth-failed)
      printf 'auth-failed (browser/device-flow login required on the execution host: kiro-cli login --use-device-flow)\n'
      ;;
    *)
      # Empty or unknown token → empty phrase.
      ;;
  esac
  return 0
}
