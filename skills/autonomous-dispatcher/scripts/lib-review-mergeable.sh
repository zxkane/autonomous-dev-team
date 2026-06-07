#!/bin/bash
# lib-review-mergeable.sh — INV-44 wrapper-enforced mergeable hard gate
# (issue #176).
#
# A PR that is CONFLICTING with its base branch can still receive a PASS verdict
# from the review agent — the mergeable check lives only in the agent's Step-0
# prompt, which the agent is trusted (but not forced) to run. This helper is the
# pure decision half of a wrapper-level gate that re-checks `mergeable` AFTER the
# per-agent verdicts are aggregated and BEFORE the wrapper acts on a PASS, so a
# CONFLICTING PR can never reach `approved` regardless of whether the agent ran
# Step 0.
#
# The split mirrors lib-review-aggregate.sh: the `gh pr view --json mergeable`
# query + UNKNOWN-retry loop stays in the wrapper (it does I/O); the
# mergeable-string → action mapping lives here so it can be unit-tested in
# isolation without a live PR.

# _classify_mergeable_gate <mergeable>
#
# Maps a GitHub PR `mergeable` field value to one of three gate actions:
#
#   proceed              — the PR is mergeable; the wrapper's existing PASS
#                          branch (approve + merge) runs unchanged.
#   block-substantive    — the PR CONFLICTs with base; a real, dev-actionable
#                          finding. The wrapper posts a [BLOCKING] merge-conflict
#                          finding + an `Auto-merge failed:` marker (reusing the
#                          dev-resume rebase hook) and routes to pending-dev.
#   block-nonsubstantive — mergeable is UNKNOWN (GitHub still computing), empty
#                          (the `gh` query failed), or any unrecognized token.
#                          The wrapper re-queues (routes to pending-dev with a
#                          non-substantive trailer) rather than auto-approving.
#
# Conservative by construction: the ONLY input that yields `proceed` is a
# case-insensitive `MERGEABLE`. Every other value blocks — this is what closes
# the stale-UNKNOWN pass-through (a status GitHub hasn't resolved can never be
# silently treated as mergeable). Returns 0 always; the decision is on stdout.
_classify_mergeable_gate() {
  # Uppercase for a case-insensitive compare against GitHub's documented enum
  # values (MERGEABLE / CONFLICTING / UNKNOWN).
  local mergeable="${1:-}"
  local upper="${mergeable^^}"

  case "$upper" in
    MERGEABLE)
      printf 'proceed\n'
      ;;
    CONFLICTING)
      printf 'block-substantive\n'
      ;;
    *)
      # UNKNOWN, empty, or anything unexpected → never proceed.
      printf 'block-nonsubstantive\n'
      ;;
  esac
}

# _pr_open_gate <state> (INV-54, issue #196)
#
# Maps a GitHub PR `state` field value to a gate decision used at the TOP of the
# `PASSED_VERDICT == true` chain — BEFORE the mergeable hard gate and the PASS
# approve/merge branch:
#
#   proceed — the PR is OPEN; run the mergeable gate + PASS branch as before.
#   skip    — the PR is no longer open (merged/closed out-of-band, or its state
#             could not be determined). The wrapper cleans `-reviewing` and exits
#             WITHOUT adding `pending-dev`, so an already-merged/closed issue is
#             never flipped back into the dev queue.
#
# This is the exact inverse of the existing PASS-branch guard's `!= OPEN` test,
# hoisted so it covers ALL three PASS-chain exits (block-substantive,
# block-nonsubstantive, PASS) with a single check. Before this gate, the
# open-check lived only in the PASS branch, so a PR merged out-of-band that then
# took an INV-44 block branch flipped its closed issue to `pending-dev` (the
# #191 self-merge incident; carved out of #193).
#
# Conservative by construction: the ONLY input that yields `proceed` is a
# case-insensitive `OPEN`. UNKNOWN (the wrapper's failed-`gh`-query sentinel),
# empty, CLOSED, MERGED, and any unexpected token all → `skip`, matching the
# PASS-branch guard which treated a failed query as non-OPEN. Returns 0 always;
# the decision is on stdout.
_pr_open_gate() {
  local state="${1:-}"
  if [[ "${state^^}" == "OPEN" ]]; then
    printf 'proceed\n'
  else
    printf 'skip\n'
  fi
}
