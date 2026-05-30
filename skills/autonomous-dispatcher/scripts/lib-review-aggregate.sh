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
#   - if ALL agents are unavailable → "all-unavailable", which the wrapper
#     maps to today's single-agent crash fallback verbatim.
#
# The logic is extracted here so it can be unit-tested in isolation (mirrors
# lib-review-verdict.sh), without spawning the full review wrapper.

# _aggregate_review_verdicts <outcome...>
#
# Each positional arg is one agent's outcome, one of:
#   pass | fail | unavailable
#
# Echoes the aggregate decision on stdout:
#   pass            — at least one deciding agent and all deciding agents passed
#   fail            — at least one deciding agent failed
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
