#!/bin/bash
# lib-review-aggregate.sh — INV-40 unanimous-PASS aggregation for the
# multi-agent review wrapper (issue #166).
#
# When autonomous-review.sh runs more than one verdict-reaching review agent
# (AGENT_REVIEW_AGENTS, e.g. "agy kiro") against the same PR, it collects one
# verdict per agent and must collapse them into a single approve-vs-pushback
# decision. The rule (locked in #166) is **unanimous PASS**:
#
#   - aggregated verdict is PASS iff there is at least one DECIDING agent AND
#     every deciding agent PASSED;
#   - any single deciding FAIL → aggregated FAIL;
#   - an agent that is UNAVAILABLE (CLI launch failure OR no verdict comment
#     within the poll window) is dropped from the vote — but a FAIL it *did*
#     post still counts as a deciding FAIL;
#   - an agent that was TIMED-OUT (killed BY its own wall-clock cap — rc 124/137
#     — with no posted verdict) is a deciding FAIL: it VETOES the merge rather
#     than being silently dropped (INV-48 amendment to INV-40, #185). A naive 1h
#     review cap (AGENT_REVIEW_TIMEOUT) could otherwise turn a slow-but-legit
#     review — e.g. a >1h CI queue the agent was told to `gh pr checks --watch`
#     — into a silent pass-through; a loud FAIL routes it back to dev instead.
#   - if ALL agents are unavailable → "all-unavailable", which the wrapper
#     maps to today's single-agent crash fallback verbatim. (A timed-out agent
#     is DECIDING, so a round with only timed-out + unavailable agents is `fail`,
#     not `all-unavailable`.)
#
# The logic is extracted here so it can be unit-tested in isolation (mirrors
# lib-review-verdict.sh), without spawning the full review wrapper.

# _classify_noverdict_agent <rc>
#
# Maps a review fan-out agent that posted NO classifiable verdict comment within
# the poll window onto its terminal aggregation state, based on its CLI launch
# exit code (AGENT_LAUNCH_RC). This is the rc→state split INV-48 adds to INV-40's
# previously-uniform "no verdict → unavailable" sweep:
#
#   124 (coreutils `timeout` TERM-expiry) → timed-out   (deciding FAIL / veto)
#   137 (128+SIGKILL, the --kill-after escalation) → timed-out
#   any other rc (0 clean-but-silent, 1 launch failure, …) → unavailable (dropped)
#
# Echoes the state on stdout. A verdict the agent DID post still wins over the rc
# (the INV-40 precedence) — this classifier is only consulted at window-expiry
# for an agent with no verdict, so it never overrides a posted PASS/FAIL.
_classify_noverdict_agent() {
  local rc="${1:-}"
  case "$rc" in
    124|137) printf 'timed-out\n' ;;
    *)       printf 'unavailable\n' ;;
  esac
}

# _aggregate_review_verdicts <outcome...>
#
# Each positional arg is one agent's outcome, one of:
#   pass | fail | unavailable | timed-out
#
# Echoes the aggregate decision on stdout:
#   pass            — at least one deciding agent and all deciding agents passed
#   fail            — at least one deciding agent failed (incl. a timed-out veto)
#   all-unavailable — zero deciding agents (every agent was unavailable, or no
#                     agents were supplied at all)
#
# Returns 0 always; the decision is on stdout. Unknown tokens are treated
# conservatively as a deciding FAIL (defensive: an unexpected outcome string
# should never silently approve a merge).
_aggregate_review_verdicts() {
  local outcome
  local deciding=0
  local any_fail=0

  for outcome in "$@"; do
    case "$outcome" in
      pass)
        deciding=$((deciding + 1))
        ;;
      fail)
        deciding=$((deciding + 1))
        any_fail=1
        ;;
      timed-out)
        # Killed by its own wall-clock cap (rc 124/137) with no verdict — a
        # deciding FAIL that VETOES the merge (INV-48). Explicit (not folded
        # into the defensive `*)` below) so the veto is a documented decision,
        # not an accident of the catch-all.
        deciding=$((deciding + 1))
        any_fail=1
        ;;
      unavailable)
        # Dropped from the vote — not a deciding agent.
        ;;
      *)
        # Unknown token: never let it pass silently. Count as a deciding FAIL.
        deciding=$((deciding + 1))
        any_fail=1
        ;;
    esac
  done

  if [[ "$deciding" -eq 0 ]]; then
    printf 'all-unavailable\n'
  elif [[ "$any_fail" -eq 1 ]]; then
    printf 'fail\n'
  else
    printf 'pass\n'
  fi
}
