#!/bin/bash
# lib-review-smoke.sh — INV-64 pre-fan-out agent-smoke gate for the multi-agent
# review wrapper (issue #224).
#
# WHY this exists
# ---------------
# Today a misconfigured/broken AGENT_REVIEW_AGENTS fan-out member burns a full
# review run (the INV-46 E2E lane + N parallel review agents + the verdict-poll
# window) before surfacing as an opaque `unavailable` drop (INV-40). The wrapper
# cannot distinguish "operator broke the config" (a wrong model id / expired auth
# / region drift — must be FIXED, must not silently shrink the vote) from "quota
# wall" (environmental, fine to drop). Phase A.5 runs a cheap one-token smoke per
# member BEFORE the fan-out and applies three-state semantics so the two are
# separated before any expensive review run starts:
#
#   PASS        (rc 0)  → member proceeds to the fan-out.
#   UNAVAILABLE (rc 2)  → member dropped pre-fan-out via the existing INV-40
#                         `unavailable` machinery (drop reason `smoke: <reason>`);
#                         remaining members vote normally; ALL unavailable → the
#                         existing all-unavailable fallback path, unchanged.
#   FAIL        (rc 1)  → ABORT the whole review loudly: no fan-out, no verdict,
#                         issue stays `reviewing`; post a comment naming the
#                         failed agent(s) + the SMOKE evidence; wrapper exits
#                         non-zero. (A config error is operator-side, not a PR
#                         defect — flipping to pending-dev would send dev chasing
#                         a non-existent PR problem; staying `reviewing` matches
#                         the wrapper-startup-crash semantics and self-heals on
#                         the next tick once the operator fixes the config.)
#
# The probe itself is lib-agent-smoke.sh::smoke_agent (INV-63, #222) — run through
# the production run_agent chain, classified by the same per-CLI drop-reason
# scrapers the fan-out's INV-58/61/62 drops use. This lib carries only the
# REVIEW-SIDE decision logic so it is unit-testable in isolation (mirrors
# lib-review-aggregate.sh / lib-review-e2e.sh / lib-review-poll.sh); the wrapper
# keeps the parallel-subshell orchestration (it owns REVIEW_AGENTS_LIST, the
# per-agent resolvers, and the fan-out sidecar dir).
#
# Three-state ↔ four-axis (#229 adapter spec): PASS/UNAVAILABLE/FAIL is a
# projection of the adapter provider axis (`quota|auth → UNAVAILABLE`,
# `config → FAIL`). The classification lives in smoke_agent / its per-CLI
# scrapers, so when #232 moves per-CLI logic into adapters Phase A.5 keeps calling
# the same smoke_agent entry point and absorbs the refactor with zero behavior
# change.

# ---------------------------------------------------------------------------
# Source dependencies via the [INV-14] symlink-vendor pattern: ${BASH_SOURCE[0]}
# (NOT readlink -f) so the per-project scripts/ symlink resolves to the project's
# vendored copy. lib-agent-smoke.sh defines smoke_agent and transitively sources
# lib-agent.sh + the three drop-reason libs. Guard against double-source (the
# wrapper sources lib-agent.sh first) by checking for smoke_agent.
# ---------------------------------------------------------------------------
_LIB_REVIEW_SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if ! declare -F smoke_agent >/dev/null 2>&1; then
  # shellcheck source=lib-agent-smoke.sh
  source "${_LIB_REVIEW_SMOKE_DIR}/lib-agent-smoke.sh"
fi

# Default per-member smoke wall-clock cap (seconds). Overridden by the wrapper's
# REVIEW_SMOKE_TIMEOUT_SECONDS conf knob (default 120). A smoke is a one-token
# round-trip, so 120s is generous headroom for cold-start auth + first-token.
REVIEW_SMOKE_DEFAULT_TIMEOUT_SECONDS="${REVIEW_SMOKE_DEFAULT_TIMEOUT_SECONDS:-120}"

# _smoke_evidence_reason <evidence-line>
#
# Extract the `reason=<...>` tail from a single `SMOKE <agent> <STATE> <elapsed>s
# reason=<...>` evidence line (the format smoke_agent emits). Echoes the reason
# text (everything after the FIRST `reason=`) on stdout, or empty when the line
# carries no `reason=` tail. Used to build the `smoke: <reason>` drop reason for
# an UNAVAILABLE member and the per-agent clause in the FAIL-abort comment.
#
# Fail-safe: never aborts under `set -euo pipefail`; an input with no `reason=`
# (or empty input) yields empty (no over-claim — the caller then falls back to a
# bare `smoke: unavailable`/`smoke: failed`). If a multi-line capture is passed,
# only the LAST `SMOKE …` line's reason is returned (the evidence line may be
# followed by trailing CLI noise).
_smoke_evidence_reason() {
  local capture="${1:-}"
  [[ -n "$capture" ]] || { printf ''; return 0; }
  # Pick the last `SMOKE …` line so trailing noise after the evidence line is
  # ignored. grep returning no match (rc 1 under pipefail) must not abort — guard.
  local line
  line=$(printf '%s\n' "$capture" | grep -E '^SMOKE ' | tail -n1 || true)
  [[ -n "$line" ]] || line="$capture"
  # No `reason=` substring → empty.
  case "$line" in
    *reason=*) printf '%s' "${line#*reason=}" ;;
    *)         printf '' ;;
  esac
  return 0
}

# _classify_smoke_state <agent> <model> <timeout> <rc-file> <evidence-file>
#
# Run ONE member's smoke (smoke_agent) and record its outcome to sidecars so the
# wrapper's parallel loop is a thin fan-out (a backgrounded subshell cannot mutate
# the parent's arrays). Writes:
#   <rc-file>        — one of `pass` | `unavailable` | `fail`
#   <evidence-file>  — smoke_agent's `SMOKE …` evidence line (verbatim)
#
# smoke_agent's three-state rc (0 PASS / 2 UNAVAILABLE / 1 FAIL) is mapped to the
# state token. ALWAYS returns 0 (the state is on the sidecar, never in $?) so a
# non-zero smoke_agent can't abort a backgrounded subshell that inherited `set -e`
# before the sidecar is written — the sidecar is the load-bearing channel, exactly
# like the fan-out's per-agent rc sidecar.
#
# A missing/empty model falls back to `sonnet` (the same default the fan-out's
# run_agent arg applies); a non-positive/garbage timeout falls back to the lib
# default (smoke_agent itself re-validates via _is_positive_timeout_value, so this
# is belt-and-suspenders).
_classify_smoke_state() {
  local agent="${1:-}" model="${2:-}" timeout="${3:-}" rc_file="${4:-}" evidence_file="${5:-}"
  model="${model:-sonnet}"
  if ! _is_positive_timeout_value "$timeout" 2>/dev/null; then
    timeout="$REVIEW_SMOKE_DEFAULT_TIMEOUT_SECONDS"
  fi

  local evidence rc state
  evidence=$(smoke_agent "$agent" "$model" "$timeout") && rc=0 || rc=$?
  case "$rc" in
    0) state="pass" ;;
    2) state="unavailable" ;;
    *) state="fail" ;;
  esac

  if [[ -n "$rc_file" ]]; then
    printf '%s\n' "$state" > "$rc_file" 2>/dev/null || true
  fi
  if [[ -n "$evidence_file" ]]; then
    printf '%s\n' "$evidence" > "$evidence_file" 2>/dev/null || true
  fi
  return 0
}

# _classify_smoke_gate <state...>
#
# The pure Phase A.5 gate decision. Each positional arg is one member's smoke
# state (`pass` | `unavailable` | `fail`). Echoes the gate verdict on stdout:
#
#   fail            — ANY member FAILed (operator-side config breakage → abort).
#   all-unavailable — no FAIL, and EVERY member is UNAVAILABLE (the surviving
#                     fan-out set is empty → drive the existing INV-40
#                     all-unavailable fallback; this also covers a single-agent
#                     project whose one member is UNAVAILABLE).
#   pass            — no FAIL and at least one member PASSed (fan out the
#                     survivors; any UNAVAILABLE members are dropped by the caller).
#
# Precedence (load-bearing): FAIL > all-UNAVAILABLE > pass. A single FAIL anywhere
# forces `fail` regardless of the other members — a config error must never be
# disguised as a shrunken vote. Only when there is NO fail and every member is
# unavailable does it become `all-unavailable`.
#
# Returns 0 always; the decision is on stdout. An UNKNOWN state token is treated
# conservatively as a FAIL (defensive: an unexpected state must never silently
# pass the gate). An empty arg list → `pass` (no members to gate; the wrapper's
# REVIEW_AGENTS_LIST is never empty, so this is purely defensive).
_classify_smoke_gate() {
  local state
  local any_fail=0
  local any_pass=0
  local count=0

  for state in "$@"; do
    count=$((count + 1))
    case "$state" in
      pass)        any_pass=1 ;;
      unavailable) : ;;  # dropped — neither a pass nor a fail
      fail)        any_fail=1 ;;
      *)           any_fail=1 ;;  # unknown → conservative FAIL
    esac
  done

  if [[ "$any_fail" -eq 1 ]]; then
    printf 'fail\n'
  elif [[ "$count" -eq 0 || "$any_pass" -eq 1 ]]; then
    printf 'pass\n'
  else
    # No fail, no pass, at least one member → every member was unavailable.
    printf 'all-unavailable\n'
  fi
}
