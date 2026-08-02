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

# ---------------------------------------------------------------------------
# parse_push_remote_operand <command>
#
# Echoes the first positional operand of a git-push command — the remote name
# or a literal URL — and returns 0. Returns 1 (empty output) when the push has
# no positional operand (bare `git push`, which targets the current branch's
# configured remote).
#
# Trunk protection compares push DESTINATIONS ([INV-148]), so it must ask
# which remote the push writes to, not assume `origin`. Flag/value skipping
# mirrors parse_push_target_refspec's walk so both helpers agree on what
# counts as a positional.
parse_push_remote_operand() {
  local command="$1"
  local -a tokens
  read -ra tokens <<<"$command"

  local i=0 n=${#tokens[@]}
  while (( i < n )) && [[ "${tokens[i]}" != "git" ]]; do
    i=$((i+1))
  done
  (( i < n )) || return 1
  i=$((i+1))

  while (( i < n )); do
    case "${tokens[i]}" in
      -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
        i=$(( i + 2 > n ? n : i + 2 ))
        ;;
      --*=*|--*) i=$((i+1)) ;;
      *) break ;;
    esac
  done

  (( i < n )) || return 1
  [[ "${tokens[i]}" == "push" ]] || return 1
  i=$((i+1))

  while (( i < n )); do
    case "${tokens[i]}" in
      --repo|-o|--push-option|--receive-pack|--exec|--signed)
        i=$(( i + 2 > n ? n : i + 2 )); continue ;;
      -*) ;;
      *) printf '%s\n' "${tokens[i]}"; return 0 ;;
    esac
    i=$((i+1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# canonical_remote_url <url>
#
# Echoes a comparable form of a git remote URL: scheme/credentials/port
# stripped, SSH shorthand (`git@host:owner/repo`) folded to `host/owner/repo`,
# a trailing `.git` and any trailing slashes removed, and the result
# lowercased. Always returns 0 (an unrecognized shape passes through with the
# same normalization applied, so comparison stays defined).
#
# Purpose is EQUALITY of two URLs naming the same repository, not validation.
# The normalization is deliberately conservative: it only removes syntax that
# provably cannot change which repository is addressed. It never rewrites the
# path, so `<project>.git` and `<project>.wiki.git` stay distinct — that is
# what makes a wiki's push destination recognizably different from its parent
# project's ([INV-148]).
canonical_remote_url() {
  local url="$1"
  [[ -n "$url" ]] || return 0

  # Strip scheme (https://, git://, ssh://, file://, ...).
  url="${url#*://}"

  # SSH shorthand `git@host:owner/repo` → `host/owner/repo`. Only the FIRST `:`
  # is rewritten, and only when it is not a port — a numeric segment is left for
  # the port strip below. Testing the host segment alone is sufficient: a `:`
  # anywhere later is inside the path, which is never rewritten.
  local host_segment="${url%%/*}"
  if [[ "$host_segment" == *:* && "${host_segment#*:}" != +([0-9]) ]]; then
    url="${url/:/\/}"
  fi

  # Strip userinfo (`git@`, `user:token@`) from the host segment.
  url="${url#*@}"

  # Strip a port on the host segment (`host:2222/owner/repo`).
  host_segment="${url%%/*}"
  if [[ "$host_segment" == *:+([0-9]) ]]; then
    local rest=""
    [[ "$url" == */* ]] && rest="/${url#*/}"
    url="${host_segment%%:*}${rest}"
  fi

  # Trailing slashes, then a single trailing `.git`.
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  url="${url%.git}"
  while [[ "$url" == */ ]]; do url="${url%/}"; done

  printf '%s\n' "${url,,}"
}

# ---------------------------------------------------------------------------
# push_destination_url <repo-dir> <remote-operand>
#
# Echoes the canonical push-destination URL for a push issued from <repo-dir>
# with <remote-operand> (a remote name, a literal URL, or empty for bare
# `git push`), and returns 0. Returns 1 (empty output) when the destination
# cannot be determined — callers MUST treat that as "unknown" and fail closed.
#
# Resolution order mirrors git's own:
#   1. an operand that looks like a URL is the destination verbatim
#   2. a named remote resolves via `git remote get-url --push` (which honors
#      `remote.<name>.pushurl`)
#   3. no operand → the current branch's `remote.<branch>.remote`, else
#      `remote.pushDefault`, else `origin`
#
# Only read-only `git -C` probes are used; no command text is ever executed.
push_destination_url() {
  local repo_dir="$1" operand="${2:-}"
  local remote_name="" url=""

  [[ -n "$repo_dir" ]] || return 1

  if [[ -n "$operand" ]]; then
    # A literal URL (scheme form, or SSH shorthand `host:path`) is used as-is.
    if [[ "$operand" == *://* || "$operand" == *@*:* ]]; then
      canonical_remote_url "$operand"
      return 0
    fi
    remote_name="$operand"
  else
    local branch
    branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
    if [[ -n "$branch" ]]; then
      remote_name=$(git -C "$repo_dir" config --get "branch.${branch}.remote" 2>/dev/null) || remote_name=""
    fi
    if [[ -z "$remote_name" ]]; then
      remote_name=$(git -C "$repo_dir" config --get remote.pushDefault 2>/dev/null) || remote_name=""
    fi
    [[ -n "$remote_name" ]] || remote_name="origin"
  fi

  # A local path configured as a remote is still a distinct destination; it is
  # normalized like any other URL so comparison stays defined.
  url=$(git -C "$repo_dir" remote get-url --push "$remote_name" 2>/dev/null) || return 1
  [[ -n "$url" ]] || return 1

  canonical_remote_url "$url"
}
