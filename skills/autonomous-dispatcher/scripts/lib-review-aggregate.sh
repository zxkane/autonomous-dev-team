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

# _aggregate_has_substantive_fail <outcome...>
#
# Issue #449 codex review round 4 [P1] #1/#2: `_aggregate_review_verdicts`
# folds an INV-48 `timed-out` veto into the SAME `fail` aggregate as a
# genuine per-agent `fail` (a real, severity-scored blocking finding) —
# correct for the merge-gate decision itself (a hung reviewer still blocks
# the merge), but WRONG for any caller asking "did a review agent actually
# SCORE a blocking finding this round". R1's `review-round-counter` and
# INV-127's round-cap both need exactly that narrower distinction: a
# `timed-out` agent posted no findings text, so it carries no severity to
# score and is no evidence the severity ratchet's own P0/P1 floor is STILL
# failing — a round where EVERY deciding fail is a bare timeout veto (no
# agent actually reviewed the diff) must not advance either counter, or a
# handful of transient hangs could inflate REVIEW_ROUND (prematurely
# loosening the severity floor) or the INV-127 cap (eventually stalling a PR
# that no review agent ever actually found a live P0/P1 in).
#
# Echoes "true" iff at least one outcome is the literal token `fail` (a
# per-agent verdict that survived the severity filter carrying an actual
# blocking finding); "false" otherwise (all `timed-out`/`unavailable`/`pass`,
# or the input is empty). Pure; rc 0 always.
_aggregate_has_substantive_fail() {
  local outcome
  for outcome in "$@"; do
    if [[ "$outcome" == "fail" ]]; then
      printf 'true\n'
      return 0
    fi
  done
  printf 'false\n'
  return 0
}

# _aggregate_has_p0p1_fail <verdict> <severity> [<verdict> <severity> ...]
#
# Issue #449 codex review round 7 [P1]: `_aggregate_has_substantive_fail`
# only confirms a REAL (non-timeout) fail survived the severity filter — it
# says nothing about WHICH severity survived. INV-127's own fingerprint
# ("the ratchet's own P0/P1 floor is STILL failing") requires the ratchet's
# TERMINAL floor (round 5+: only P0/P1 — plus "none"/unrecognized, which
# fail-safe always blocks — never P2/P3) to be genuinely failing, not merely
# "a fail survived at THIS round's possibly-low floor". A P2 finding blocks
# at rounds 1-4 and would therefore survive as `fail` whenever
# R1's head-scoped `review-round-counter` happens to be low — which it
# always is right after a new HEAD, precisely INV-127's own motivating
# scenario (a new head every round). Without this narrower check, a PR that
# keeps surfacing ONLY P2 findings across a run of new heads would still
# advance the head-AGNOSTIC INV-127 counter and eventually trip it despite
# no P0/P1 ever existing.
#
# Takes alternating (verdict, severity) pairs — one per fan-out agent, in the
# SAME order AGENT_VERDICTS/AGENT_HIGHEST_SEVERITY are populated in
# autonomous-review.sh — rather than two separate arrays, so this stays a
# plain positional-arg pure function like its `_aggregate_has_substantive_fail`
# sibling (no nameref indirection needed for a one-shot aggregate check).
#
# Echoes "true" iff at least one pair has verdict=="fail" AND severity is NOT
# P2/P3 (i.e. would still block under the ratchet's terminal round-5+ floor:
# P0, P1, "none", or any other unrecognized token — duplicates
# lib-review-severity.sh::shouldBlockFinding's own round>=5 case arms rather
# than sourcing it, so this pure aggregate helper stays dependency-free and
# unit-testable in isolation, mirroring the rest of this file). "false"
# otherwise (no fail at all, or every surviving fail's severity is P2/P3). A
# trailing unpaired verdict (caller bug) is dropped, not crashed on. Pure;
# rc 0 always.
_aggregate_has_p0p1_fail() {
  local verdict severity
  while [[ $# -ge 2 ]]; do
    verdict="$1" severity="$2"
    shift 2
    if [[ "$verdict" == "fail" ]]; then
      case "$severity" in
        P2|P3) ;;
        *)
          printf 'true\n'
          return 0
          ;;
      esac
    fi
  done
  printf 'false\n'
  return 0
}
