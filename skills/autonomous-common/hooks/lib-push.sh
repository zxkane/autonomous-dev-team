#!/bin/bash
# lib-push.sh — pure parsing helpers for git-push hook scripts.
#
# Used by:
#   - block-push-to-main.sh (Claude PreToolUse hook, Layer 1 trunk protection)
#   - install-git-pre-push.sh's emitted hook (Layer 2 git-side hook)
#
# Does not source other lib files. Self-contained pure functions; safe to
# invoke from any context including a freshly-spawned hook process.
#
# This file is sourced, not executed. No `set -e` (caller controls exit
# semantics).

# ---------------------------------------------------------------------------
# parse_push_target_refspec <command>
#
# Given a git-push command line, echoes the destination ref-name(s) the push
# would write to, one per line. Returns 0 if at least one destination was
# identified, 1 if the command is not a push or could not be parsed.
#
# Handles:
#   git push                                → <current_branch>
#   git push origin                         → <current_branch>
#   git push origin feat/foo                → feat/foo
#   git push -u origin feat/foo             → feat/foo
#   git push origin feat/foo:bar            → bar
#   git push origin HEAD:refs/heads/main    → refs/heads/main
#   git push origin :main                   → :main (delete; caller decides)
#   git push origin tag v1                  → refs/tags/v1
#   git push --all origin                   → __ALL__
#   git push --mirror origin                → __MIRROR__
#   git push --tags origin                  → __TAGS__
#
# Bulk markers (__ALL__, __MIRROR__) are returned uppercase-bracketed so
# callers can branch without ambiguity vs. a real ref named "all".
#
# Caller is expected to have already verified `is_git_command "push" ...`.
parse_push_target_refspec() {
  local command="$1"
  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  # Tokenize. Strip leading `cd ... &&` etc. by trimming up to the `git` token.
  # Match is_git_command's quote-stripping minimally — quotes around a refspec
  # are valid (e.g. "git push origin 'feat:bar'") but rare; treat them as
  # literal here.
  local -a tokens
  read -ra tokens <<<"$command"

  # Find the `git` token
  local i=0 n=${#tokens[@]}
  while (( i < n )) && [[ "${tokens[i]}" != "git" ]]; do
    i=$((i+1))
  done
  if (( i >= n )); then return 1; fi
  i=$((i+1))

  # Skip git global flags (same logic as is_git_command's flag-skip).
  while (( i < n )); do
    case "${tokens[i]}" in
      -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
        i=$(( i + 2 > n ? n : i + 2 ))
        ;;
      --*=*|--*)
        i=$((i+1))
        ;;
      *)
        break
        ;;
    esac
  done

  # Expect `push`
  if (( i >= n )); then return 1; fi
  if [[ "${tokens[i]}" != "push" ]]; then return 1; fi
  i=$((i+1))

  # Walk push args. Track state.
  local found_remote=0
  local -a refspecs=()
  local saw_all=0 saw_mirror=0 saw_tags_flag=0 saw_delete=0
  while (( i < n )); do
    local tok="${tokens[i]}"
    case "$tok" in
      --all|--all=*)        saw_all=1 ;;
      --mirror|--mirror=*)  saw_mirror=1 ;;
      --tags|--tags=*)      saw_tags_flag=1 ;;
      --delete|-d)          saw_delete=1 ;;
      # Skip flags that take a value
      --repo|-o|--push-option|--receive-pack|--exec|--signed)
        i=$(( i + 2 > n ? n : i + 2 )); continue ;;
      # Combined --flag=value or --flag forms — consume as 1 token
      -*) ;;
      # Positional: first one is the remote, rest are refspecs (or
      # `tag <name>` pair).
      *)
        if (( found_remote == 0 )); then
          found_remote=1
        elif [[ "$tok" == "tag" ]] && (( i + 1 < n )); then
          refspecs+=("refs/tags/${tokens[i+1]}")
          i=$((i+1))
        else
          refspecs+=("$tok")
        fi
        ;;
    esac
    i=$((i+1))
  done

  # --all / --mirror / --tags shortcut
  if (( saw_all == 1 )); then echo "__ALL__"; return 0; fi
  if (( saw_mirror == 1 )); then echo "__MIRROR__"; return 0; fi
  if (( saw_tags_flag == 1 )) && (( ${#refspecs[@]} == 0 )); then
    echo "__TAGS__"; return 0
  fi

  # No explicit refspec: implicit destination is the *current branch*'s
  # configured upstream (matrix or default). For our purposes, treat that as
  # the current branch name — `git push` with default config pushes
  # HEAD → <upstream of HEAD>, where upstream typically matches the current
  # branch name on origin.
  if (( ${#refspecs[@]} == 0 )); then
    if [[ -n "$current_branch" && "$current_branch" != "HEAD" ]]; then
      echo "$current_branch"
      return 0
    fi
    return 1
  fi

  # Walk refspecs. Each can be:
  #   src:dst   → echo dst
  #   :dst      → echo :dst (delete)
  #   ref       → echo ref (src=dst)
  for r in "${refspecs[@]}"; do
    if [[ "$r" == *:* ]]; then
      local dst="${r#*:}"
      local src="${r%%:*}"
      if [[ -z "$src" ]]; then
        # Delete form: prefix with `:` so caller can detect.
        echo ":${dst}"
      else
        echo "$dst"
      fi
    else
      echo "$r"
    fi
  done
}

# ---------------------------------------------------------------------------
# is_trunk_ref <ref> [<trunk_name>]
#
# Returns 0 if <ref> targets the trunk branch, 1 otherwise. <trunk_name>
# defaults to "main" if omitted; pass an explicit name (e.g. "master") to
# match repos with a different trunk.
#
# Recognized forms (all return 0):
#   main
#   refs/heads/main
#   refs/heads/main^         (rev-spec suffix; rare but valid in push)
#
# A leading `:` (delete-push) is stripped before matching, so
#   :main, :refs/heads/main  also return 0
#
# The bulk markers __ALL__ / __MIRROR__ return 0 (they target trunk among
# others). __TAGS__ returns 1 (tags-only push, doesn't write the trunk
# branch ref).
is_trunk_ref() {
  local ref="$1"
  local trunk="${2:-main}"

  case "$ref" in
    __ALL__|__MIRROR__) return 0 ;;
    __TAGS__) return 1 ;;
  esac

  # Strip leading `:` (delete form).
  ref="${ref#:}"

  # Bare trunk
  [[ "$ref" == "$trunk" ]] && return 0

  # Fully-qualified
  [[ "$ref" == "refs/heads/$trunk" ]] && return 0

  # Allow rev-spec suffix on either form (e.g. main^, refs/heads/main~3)
  [[ "$ref" == "$trunk"[\^~]* ]] && return 0
  [[ "$ref" == "refs/heads/$trunk"[\^~]* ]] && return 0

  return 1
}
