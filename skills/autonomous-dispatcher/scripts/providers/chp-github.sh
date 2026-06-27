#!/bin/bash
# providers/chp-github.sh — GitHub Code-Host Provider (CHP) reference impl.
#
# EMPTY SCAFFOLD (#280). This file establishes the provider-prefix convention
# only — it defines ZERO verb bodies in this PR. The leaf migration (moving each
# `gh pr` / review-thread leaf out of the wrappers / lib-dispatch.sh /
# lib-review-*.sh and behind a `chp_github_<verb>` function) is the downstream
# chp-pr-lifecycle issue, per the verb↔current-function mapping appendix in
# docs/pipeline/provider-spec.md.
#
# CONVENTION (so the downstream migration slots in mechanically):
#   - Each CHP verb's GitHub leaf is a function named  chp_github_<verb>.
#   - lib-code-host.sh's `chp_<verb>` shim forwards "$@" to it when
#     CODE_HOST=github (the default). It is NOT defined here yet, so
#     `declare -F chp_github_<verb>` returns non-zero until its migration lands.
#   - The GitHub `.caps` manifest beside this file (chp-github.caps) declares
#     exactly today's GitHub behavior — the no-behavior-change anchor ([INV-88]).
#
# PRECONDITION: sourced by lib-code-host.sh from the REAL skill tree
# (readlink -f of that lib's BASH_SOURCE). Sourcing this scaffold is a no-op.
#
# 12 CHP verbs to migrate here (spec §3.2):
#   chp_github_find_pr_for_issue   chp_github_ci_status
#   chp_github_mergeable           chp_github_create_pr
#   chp_github_approve             chp_github_request_changes
#   chp_github_merge               chp_github_review_threads
#   chp_github_resolve_thread      chp_github_trigger_bot
#   chp_github_close_keyword
# (chp_caps reads the .caps manifest in the dispatcher, not a function here.)

# No verb bodies yet — leaf migration is downstream.
:
