#!/bin/bash
# PreToolUse hook - blocks git push directly to main branch
# All changes must go through PR workflow.
#
# Closes #64: previous regex-only approach had a false positive
# (feature push from a trunk-checked-out clone got blocked) and a
# false negative (`HEAD:refs/heads/main` slipped through). Now uses
# the lib-push.sh parser to identify the actual destination ref(s).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=lib-push.sh
source "$SCRIPT_DIR/lib-push.sh"

input=$(read_hook_stdin)
command=$(parse_command "$input")

# Trunk protection guards THIS project's REMOTE trunk, so the question it must
# ask is "where does this push land?" — not "which local checkout issued it"
# ([INV-148]). A push whose destination is a different repository is not this
# guard's business: a sibling checkout, a vendored dependency, or a project's
# separate `<project>.wiki.git`. A wiki has no PR flow and `main` is its only
# branch, so blocking it made wiki updates impossible rather than routing them
# through review.
#
# Local git-common-dir is NOT usable as that judgement. It is only a proxy for
# the destination, and a false one: a second independent clone of THIS project
# has a different common-dir but pushes to this project's own trunk, so a
# common-dir comparison would allow exactly the push this guard exists to stop.
#
# Comparing canonical push-destination URLs closes that hole and needs NO
# wiki-specific rule: a wiki lives at `<project>.wiki.git`, which canonicalizes
# to a different URL than `<project>.git`, so it is allowed by the same
# comparison that blocks the second clone. That relationship is structural on
# both GitHub and GitLab, so no configuration derives it.
#
# Fails closed on every uncertainty: unless BOTH destinations resolve AND
# differ, the push falls through to the trunk check below. An unparsable
# command, an unresolvable remote, or a missing anchor is therefore still
# checked — never waved through.
#
# The project anchor is an EXPORTED value, not `pwd` ([INV-131] pattern): the
# hook cwd is the pushing repository, so anchoring on it would make a bare
# `git push` from inside the wiki compare the wiki against itself and block it.
# Hooks stay zero-dependency shell — they read only what the wrapper exported.
anchor_dir="${AUTONOMOUS_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
if [[ -z "$anchor_dir" || ! -d "$anchor_dir" ]]; then
  anchor_dir="$(pwd -P)"
fi

# Which repository issues the push. Only resolver rc=0 yields a usable target;
# either non-zero result still receives the push parser's narrow executable-data
# check below. Quoted text piped into a shell can be executable even when the
# cwd resolver sees no direct invocation.
push_dir=""
if push_dir=$(resolve_git_command_cwd "push" "$command" "$(pwd -P)"); then
  resolve_rc=0
else
  resolve_rc=$?
  push_dir=""
fi

# Most resolver no-matches are ordinary git-free commands. Only pay for the
# structured second opinion when a cheap conservative scan still sees literal
# push-shaped text that quoting or a data command may have hidden.
if (( resolve_rc == 1 )) &&
  ! _conservative_shell_text_contains_git_operation "push" "$command" &&
  ! _push_shell_text_may_contain_executable_push_data "$command"; then
  exit 0
fi

# Apply the resolver's non-executable-region policy to destination parsing too.
# On uncertain syntax, retain the original text so parsing stays fail-closed.
push_command="$command"
if stripped_push_command=$(_strip_shell_non_executable_regions "$command"); then
  push_command="$stripped_push_command"
fi

# Tokenize once in the parent shell. Both parser command substitutions inherit
# this immutable snapshot, avoiding repeated character scans on large commands.
_push_prepare_command_tokens "$push_command"

# Parse destination refs before repository scoping. rc=1 positively means no
# executable push exists; rc=2 remains unknown and therefore fail-closed after
# scope evaluation. This second opinion is also what distinguishes quoted data
# piped to a shell from inert documentation text when the resolver returns 1.
parsed_refs=""
if parsed_refs=$(parse_push_target_refspec "$push_command"); then
  parse_rc=0
else
  parse_rc=$?
fi
if (( parse_rc == 1 )); then
  exit 0
fi

# Both destinations must be PROVEN before the push may be waved through. Each
# of these can report "unknown", and any unknown leaves the trunk check armed.
target_url=""
if [[ -n "$push_dir" ]] && remote_operand=$(parse_push_remote_operand "$push_command"); then
  target_url=$(push_destination_url "$push_dir" "$remote_operand") || target_url=""
fi

# Out of scope only when the destination is known AND the anchor is READABLE and
# owns no such remote. `anchor_owns_destination` returns 2 for an unreadable or
# remote-less anchor — distinct from its 1 ("read fine, not mine") — because a
# guard whose protected set is unknown must protect everything, or an unreadable
# anchor would become a blanket opt-out.
if [[ -n "$target_url" ]]; then
  anchor_owns_rc=0
  anchor_owns_destination "$anchor_dir" "$target_url" || anchor_owns_rc=$?
  if (( anchor_owns_rc == 1 )); then
    exit 0
  fi
fi

# Same destination (or an unresolvable one) — the trunk check below applies.
# PUSH_ALLOWED_REMOTE_URLS is the explicit, auditable opt-out for the residual
# case the URL comparison cannot infer: a destination that IS this project's
# own trunk but which an operator has decided may be pushed directly (see
# autonomous.conf.example). It is deliberately an allowlist of specific
# destinations, never a boolean "disable trunk protection" switch.
if [[ -n "${PUSH_ALLOWED_REMOTE_URLS:-}" && -n "$target_url" ]]; then
  # `set -f` for the word-split: an entry holding a glob metachar must stay a
  # literal URL, never expand against the hook's cwd.
  set -f
  # shellcheck disable=SC2206 # deliberate word-split of a space-separated list
  _allowed_list=($PUSH_ALLOWED_REMOTE_URLS)
  set +f
  for _allowed in "${_allowed_list[@]}"; do
    _allowed_canon=$(canonical_remote_url "$_allowed")
    if [[ -n "$_allowed_canon" && "$target_url" == "$_allowed_canon" ]]; then
      exit 0
    fi
  done
fi

# Trunk branch name (issue #478, [INV-131]): BASE_BRANCH (the wrapper
# resolves+exports it once at startup) → TRUNK_BRANCH (this hook's pre-#478
# override, still honored standalone e.g. for a manually-run hook outside the
# wrapper) → "main" default. Byte-identical to today when neither is set.
trunk="${BASE_BRANCH:-${TRUNK_BRANCH:-main}}"

# Parse the destination ref(s) the push would write to. Block if any of
# them target the trunk (covers --all/--mirror via __ALL__/__MIRROR__).
should_block=0
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  if is_trunk_ref "$ref" "$trunk"; then
    should_block=1
    break
  fi
done <<<"$parsed_refs"

# Parser rc=2 means an executable push was found but its destination was
# unreadable. rc=1 was handled above as a proven data-only resolver match.
if (( parse_rc == 2 )); then
  should_block=1
fi

if (( should_block == 1 )); then
  cat >&2 <<EOF
## BLOCKED - Direct Push to \`${trunk}\`

Pushing directly to \`${trunk}\` is **not allowed**. All changes must go through a Pull Request.

### Required Workflow:
1. Create a worktree: \`git worktree add .worktrees/feat/<name> -b feat/<name>\`
2. Enter the worktree: \`cd .worktrees/feat/<name>\`
3. Install dependencies and make your changes
4. Commit inside the worktree
5. Push to the feature branch: \`git push -u origin feat/<name>\`
6. Open a pull/merge request via your platform CLI or the wrapper — e.g. \`gh pr create\` on GitHub, \`glab mr create\` on GitLab, or the pipeline's provider seam (\`chp_create_pr\`).

### See CLAUDE.md for the full development workflow.
EOF
  exit 2
fi

exit 0
