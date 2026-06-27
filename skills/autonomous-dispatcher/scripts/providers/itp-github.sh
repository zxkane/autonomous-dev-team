#!/bin/bash
# providers/itp-github.sh — GitHub Issue-Tracker Provider (ITP) reference impl.
#
# EMPTY SCAFFOLD (#280). This file establishes the provider-prefix convention
# only — it defines ZERO verb bodies in this PR. The leaf migration (moving each
# `gh` issue-tracker leaf out of lib-dispatch.sh / the wrappers and behind an
# `itp_github_<verb>` function) is the downstream itp-reads / itp-writes /
# itp-deps-begin-tick issues, per the verb↔current-function mapping appendix in
# docs/pipeline/provider-spec.md.
#
# CONVENTION (so the downstream migrations slot in mechanically):
#   - Each ITP verb's GitHub leaf is a function named  itp_github_<verb>.
#   - lib-issue-provider.sh's `itp_<verb>` shim forwards "$@" to it when
#     ISSUE_PROVIDER=github (the default). It is NOT defined here yet, so
#     `declare -F itp_github_<verb>` returns non-zero until its migration lands.
#   - The GitHub `.caps` manifest beside this file (itp-github.caps) declares
#     exactly today's GitHub behavior — the no-behavior-change anchor ([INV-88]).
#
# PRECONDITION: sourced by lib-issue-provider.sh from the REAL skill tree
# (readlink -f of that lib's BASH_SOURCE). Sourcing this scaffold is a no-op.
#
# 13 ITP verbs to migrate here (spec §3.1):
#   itp_github_list_by_state       itp_github_count_by_state
#   itp_github_list_forbidden_combos
#   itp_github_transition_state    itp_github_read_task
#   itp_github_post_comment        itp_github_edit_comment
#   itp_github_list_comments       itp_github_resolve_dep
#   itp_github_mark_checkbox       itp_github_provision_states
#   itp_github_begin_tick
# (itp_caps reads the .caps manifest in the dispatcher, not a function here.)

# No verb bodies yet — leaf migration is downstream.
:
