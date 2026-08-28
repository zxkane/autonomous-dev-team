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
# Given shell command text, echoes every destination ref-name written by each
# literal `git push`, one per line. Returns 0 when all matched pushes were
# parsed, 1 when no push was found, and 2 when a push was found but one of its
# destinations could not be determined.
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
# Emit shell command segments without evaluating them. Unquoted newlines and
# control operators terminate a segment; comments are discarded. Quotes stay
# in the text so the bounded token parser can reject non-literal operands.
_push_command_segments() {
  local command="$1"
  local state="unquoted" segment="" character next
  local word_start=1 i length=${#command}

  for ((i = 0; i < length; i++)); do
    character="${command:i:1}"
    next=""
    (( i + 1 < length )) && next="${command:i+1:1}"

    case "$state" in
      single)
        segment+="$character"
        [[ "$character" == "'" ]] && state="unquoted"
        ;;
      double)
        segment+="$character"
        if [[ "$character" == "\\" && -n "$next" ]]; then
          segment+="$next"
          ((i++))
        elif [[ "$character" == '"' ]]; then
          state="unquoted"
        fi
        ;;
      unquoted)
        case "$character" in
          "'")
            segment+="$character"
            state="single"
            word_start=0
            ;;
          '"')
            segment+="$character"
            state="double"
            word_start=0
            ;;
          \\)
            segment+="$character"
            if [[ -n "$next" ]]; then
              segment+="$next"
              ((i++))
            fi
            word_start=0
            ;;
          '#')
            if (( word_start == 1 )); then
              while (( i + 1 < length )) &&
                [[ "${command:i+1:1}" != $'\n' ]]; do
                ((i++))
              done
            else
              segment+="$character"
              word_start=0
            fi
            ;;
          $'\n'|$'\r'|';'|'|'|'&')
            printf '%s\n' "$segment"
            segment=""
            word_start=1
            if { [[ "$character" == '|' || "$character" == '&' ]]; } &&
              [[ "$next" == "$character" ]]; then
              ((i++))
            fi
            ;;
          ' '|$'\t')
            segment+="$character"
            word_start=1
            ;;
          *)
            segment+="$character"
            word_start=0
            ;;
        esac
        ;;
    esac
  done
  printf '%s\n' "$segment"
}

_push_decode_literal_token() {
  local token="$1"
  local first="${token:0:1}"
  local last="${token: -1}"

  if [[ ${#token} -ge 2 ]] &&
    { [[ "$first" == "'" && "$last" == "'" ]] ||
      [[ "$first" == '"' && "$last" == '"' ]]; }; then
    token="${token:1:${#token}-2}"
  elif [[ "$token" == *["'"]* ]]; then
    return 1
  fi
  [[ "$token" != *['$`\\']* ]] || return 1
  _PUSH_LITERAL_TOKEN="$token"
}

_push_find_git_command_start() {
  local token i=0

  for token in "$@"; do
    if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      ((i++))
      continue
    fi
    [[ "$token" == "git" ]] || return 1
    _PUSH_GIT_INDEX="$i"
    return 0
  done
  return 1
}

_push_decode_unquoted_literal_token() {
  [[ "$1" != *\"* && "$1" != *\'* ]] || return 1
  _push_decode_literal_token "$1"
}

_push_token_is_single_shell_word() {
  local token="$1"
  local first="${token:0:1}"
  local last="${token: -1}"

  if _push_decode_literal_token "$token"; then
    return 0
  fi
  [[ ${#token} -ge 2 ]] &&
    { [[ "$first" == "'" && "$last" == "'" ]] ||
      [[ "$first" == '"' && "$last" == '"' ]]; }
}

parse_push_target_refspec() {
  local command="$1"
  local current_branch segment tok decoded r src dst
  local i j n found_remote saw_all saw_mirror saw_tags_flag
  local matched=0 unknown=0
  local -a tokens refspecs
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  while IFS= read -r segment; do
    read -ra tokens <<<"$segment"
    n=${#tokens[@]}
    if _push_find_git_command_start "${tokens[@]}"; then
      i="$_PUSH_GIT_INDEX"
      j=$((i + 1))
      while (( j < n )); do
        case "${tokens[j]}" in
          -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
            (( j + 1 < n )) || { unknown=1; break; }
            j=$((j + 2))
            ;;
          --*=*|--*|-*) ((j++)) ;;
          *) break ;;
        esac
      done
      (( j < n )) && [[ "${tokens[j]}" == "push" ]] || continue
      matched=1
      ((j++))
      found_remote=0
      saw_all=0
      saw_mirror=0
      saw_tags_flag=0
      refspecs=()

      while (( j < n )); do
        tok="${tokens[j]}"
        case "$tok" in
          --all|--all=*) saw_all=1 ;;
          --mirror|--mirror=*) saw_mirror=1 ;;
          --tags|--tags=*) saw_tags_flag=1 ;;
          --delete|-d) ;;
          --repo|-o|--push-option|--receive-pack|--exec)
            (( j + 1 < n )) || { unknown=1; break; }
            j=$((j + 2))
            continue
            ;;
          -*)
            ;;
          *)
            if (( found_remote == 0 )); then
              found_remote=1
              if ! _push_token_is_single_shell_word "$tok"; then
                unknown=1
              fi
              ((j++))
              continue
            fi
            if ! _push_decode_literal_token "$tok"; then
              unknown=1
              ((j++))
              continue
            fi
            decoded="$_PUSH_LITERAL_TOKEN"
            if [[ "$decoded" == "tag" ]] && (( j + 1 < n )); then
              if _push_decode_literal_token "${tokens[j+1]}"; then
                refspecs+=("refs/tags/${_PUSH_LITERAL_TOKEN}")
              else
                unknown=1
              fi
              ((j++))
            else
              refspecs+=("$decoded")
            fi
            ;;
        esac
        ((j++))
      done

      if (( saw_all == 1 )); then
        printf '%s\n' "__ALL__"
      elif (( saw_mirror == 1 )); then
        printf '%s\n' "__MIRROR__"
      elif (( saw_tags_flag == 1 && ${#refspecs[@]} == 0 )); then
        printf '%s\n' "__TAGS__"
      elif (( ${#refspecs[@]} == 0 )); then
        if [[ -n "$current_branch" && "$current_branch" != "HEAD" ]]; then
          printf '%s\n' "$current_branch"
        else
          unknown=1
        fi
      else
        for r in "${refspecs[@]}"; do
          if [[ "$r" == *:* ]]; then
            dst="${r#*:}"
            src="${r%%:*}"
            [[ -z "$src" ]] && printf ':%s\n' "$dst" || printf '%s\n' "$dst"
          else
            printf '%s\n' "$r"
          fi
        done
      fi
    fi
  done < <(_push_command_segments "$command")

  (( matched == 1 )) || return 1
  (( unknown == 0 )) || return 2
  return 0
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
# Echoes the effective repository operand of a git-push command — a `--repo`
# value, or the first positional remote name / literal URL that overrides it —
# and returns 0. Echoes nothing and returns 0 when the push has no repository
# operand (bare `git push`, which targets the current branch's configured
# remote — a resolvable destination, not an unknown).
#
# Returns 1 for anything this helper cannot confidently read, so callers can
# treat "1" as UNKNOWN and fail closed:
#   - no `git push` invocation on the line
#   - MORE THAN ONE `git push` on the line (`git push a x && git push b y`) —
#     a single answer cannot describe two destinations, and the trunk-ref
#     parser reads refspecs from the whole line, so answering for only the
#     first push would let the second one through unexamined
#   - a quoted or expansion-bearing operand — `read -ra` does not process
#     quotes, so the token still carries them and would canonicalize to a
#     destination that is confidently wrong rather than merely unresolved
#
# Trunk protection compares push DESTINATIONS ([INV-148]), so it must ask which
# remote the push writes to, not assume `origin`. Flag/value skipping mirrors
# parse_push_target_refspec's walk so both helpers agree on what counts as a
# positional.
parse_push_remote_operand() {
  local command="$1"
  local segment operand="" decoded
  local n i j pushes=0 found=0
  local -a tokens

  while IFS= read -r segment; do
    read -ra tokens <<<"$segment"
    n=${#tokens[@]}
    if _push_find_git_command_start "${tokens[@]}"; then
      i="$_PUSH_GIT_INDEX"
      j=$((i + 1))
      while (( j < n )); do
        case "${tokens[j]}" in
          -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
            (( j + 1 < n )) || return 1
            j=$((j + 2))
            ;;
          --*=*|--*|-*) ((j++)) ;;
          *) break ;;
        esac
      done
      (( j < n )) && [[ "${tokens[j]}" == "push" ]] || continue
      ((pushes++))
      (( pushes <= 1 )) || return 1
      ((j++))
      while (( j < n )); do
        case "${tokens[j]}" in
          --repo)
            (( j + 1 < n )) || return 1
            _push_decode_unquoted_literal_token "${tokens[j+1]}" || return 1
            operand="$_PUSH_LITERAL_TOKEN"
            found=1
            j=$((j + 2))
            continue
            ;;
          --repo=*)
            _push_decode_unquoted_literal_token "${tokens[j]#*=}" || return 1
            operand="$_PUSH_LITERAL_TOKEN"
            found=1
            ((j++))
            continue
            ;;
          -o|--push-option|--receive-pack|--exec)
            (( j + 1 < n )) || return 1
            j=$((j + 2))
            continue
            ;;
          -*) ;;
          *)
            _push_decode_unquoted_literal_token "${tokens[j]}" || return 1
            decoded="$_PUSH_LITERAL_TOKEN"
            operand="$decoded"
            found=1
            break
            ;;
        esac
        ((j++))
      done
    fi
  done < <(_push_command_segments "$command")

  (( pushes == 1 )) || return 1

  if (( found == 1 )); then
    printf '%s\n' "$operand"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# canonical_remote_url <url>
#
# Echoes a comparable form of a git remote URL and returns 0; returns 1 (empty
# output) when nothing comparable remains, so a caller can distinguish
# "canonicalized" from "cannot canonicalize" and fail closed.
#
# Normalized away: scheme, userinfo, port, SSH shorthand's `host:path` colon,
# repeated/leading/trailing slashes in the path, a trailing `.git`, and case.
# Host and path are normalized SEPARATELY, so a `@`, `:`, or `//` inside the
# path can never be mistaken for host syntax.
#
# Purpose is EQUALITY of two URLs naming the same repository, not validation.
# `.wiki` is deliberately never stripped, so `<project>.git` and
# `<project>.wiki.git` stay distinct — that is what makes a wiki's push
# destination recognizably different from its parent project's ([INV-148]).
canonical_remote_url() {
  local url="$1"
  [[ -n "$url" ]] || return 1

  # Strip scheme (https://, git://, ssh://, file://, ...).
  url="${url#*://}"

  # Split host segment from path ONCE, then normalize each independently. Doing
  # this by hand (rather than repeated whole-string edits) is what keeps a `@`,
  # `:`, or `//` inside the PATH from being mistaken for host syntax.
  local host_segment="${url%%/*}" path=""
  [[ "$url" == */* ]] && path="${url#*/}"

  # SSH shorthand `git@host:owner/repo` — the `:` separates host from path, so
  # everything after it belongs to the path. A purely numeric tail is a port,
  # not a path, and is handled by the port strip below.
  # Userinfo (`git@`, `user:token@`) FIRST — it may itself contain a `:`, which
  # must not be mistaken for the SSH host:path separator or a port.
  host_segment="${host_segment##*@}"

  # An IPv6 literal's colons live inside brackets and are not this separator.
  if [[ "$host_segment" == *:* && "$host_segment" != *]* ]]; then
    local after_colon="${host_segment#*:}"
    if [[ "$after_colon" != +([0-9]) ]]; then
      # `host:/path` and `host:path` address the same repository — the slash
      # normalization below removes the difference.
      path="${after_colon}/${path}"
      host_segment="${host_segment%%:*}"
    fi
  fi

  # Port (`host:2222`) — host segment only. An IPv6 literal keeps its brackets,
  # so its inner colons are never confused with a port separator.
  if [[ "$host_segment" == *]:+([0-9]) || ( "$host_segment" != *]* && "$host_segment" == *:+([0-9]) ) ]]; then
    host_segment="${host_segment%:*}"
  fi

  # A trailing dot on a hostname is DNS-equivalent (`github.com.` resolves to
  # `github.com`), so it must not make two spellings compare unequal.
  while [[ "$host_segment" == *. ]]; do host_segment="${host_segment%.}"; done

  # Collapse repeated slashes and strip leading/trailing ones: `//a//b/` and
  # `a/b` address the same repository.
  while [[ "$path" == *//* ]]; do path="${path//\/\//\/}"; done
  while [[ "$path" == /* ]]; do path="${path#/}"; done
  while [[ "$path" == */ ]]; do path="${path%/}"; done

  # Resolve `.` / `..` segments — `a/../a/b` and `a/b` name the same repository
  # on the server. Pure string work; no filesystem is consulted. A `..` that
  # would escape the root is dropped rather than retained, so no traversal
  # remains in the comparison key.
  if [[ "$path" == *.* ]]; then
    local -a _segs=() _out=()
    IFS='/' read -ra _segs <<<"$path"
    local _s
    for _s in "${_segs[@]}"; do
      case "$_s" in
        .|"") ;;
        ..) [[ ${#_out[@]} -gt 0 ]] && unset '_out[-1]' ;;
        *) _out+=("$_s") ;;
      esac
    done
    path=""
    for _s in ${_out[@]+"${_out[@]}"}; do path="${path:+$path/}$_s"; done
  fi

  # Lowercase BEFORE stripping `.git` so `.GIT` is removed too. `.wiki` is never
  # touched — that is what keeps a wiki a distinct destination ([INV-148]).
  url="${host_segment,,}${path:+/${path,,}}"
  url="${url%.git}"
  while [[ "$url" == */ ]]; do url="${url%/}"; done

  [[ -n "$url" ]] || return 1
  printf '%s\n' "$url"
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
#   3. no operand → `branch.<b>.pushRemote`, else `remote.pushDefault`, else
#      `branch.<b>.remote`, else `origin` — git's documented push precedence,
#      which is NOT the same as its fetch precedence
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
      return
    fi
    remote_name="$operand"
  else
    local branch
    branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
    if [[ -n "$branch" ]]; then
      remote_name=$(git -C "$repo_dir" config --get "branch.${branch}.pushRemote" 2>/dev/null) || remote_name=""
    fi
    if [[ -z "$remote_name" ]]; then
      remote_name=$(git -C "$repo_dir" config --get remote.pushDefault 2>/dev/null) || remote_name=""
    fi
    if [[ -z "$remote_name" && -n "$branch" ]]; then
      remote_name=$(git -C "$repo_dir" config --get "branch.${branch}.remote" 2>/dev/null) || remote_name=""
    fi
    [[ -n "$remote_name" ]] || remote_name="origin"
  fi

  # A local path configured as a remote is still a distinct destination; it is
  # normalized like any other URL so comparison stays defined.
  url=$(git -C "$repo_dir" remote get-url --push "$remote_name" 2>/dev/null) || return 1
  [[ -n "$url" ]] || return 1

  canonical_remote_url "$url"
}

# ---------------------------------------------------------------------------
# anchor_owns_destination <anchor-dir> <canonical-destination>
#
# Returns 0 when <canonical-destination> matches ANY remote configured in
# <anchor-dir> (fetch or push URL). Returns 1 ONLY when the anchor was read
# successfully and owns no such remote. Returns 2 when the anchor cannot be
# read at all — not a git repo, no remotes, unreadable `.git` (cross-user
# permissions, a `safe.directory` refusal) — which is UNKNOWN, not "not mine".
# Callers MUST treat 2 as unknown and fail closed: a guard whose protected set
# is unknown must protect everything, or an unreadable anchor becomes a blanket
# opt-out ([INV-148]).
#
# The anchor's *bare-push* destination alone is not a safe definition of "this
# project": `remote.pushDefault` or `branch.<b>.pushRemote` in the project
# checkout would silently redefine which trunk is protected and switch the guard
# off. Checking every remote the project knows about means ordinary local config
# cannot shrink the protected set.
anchor_owns_destination() {
  local anchor_dir="$1" destination="$2"
  local name url canon remotes seen=0

  [[ -n "$anchor_dir" && -n "$destination" ]] || return 2

  remotes=$(git -C "$anchor_dir" remote 2>/dev/null) || return 2

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    for url in \
      "$(git -C "$anchor_dir" remote get-url --push "$name" 2>/dev/null)" \
      "$(git -C "$anchor_dir" remote get-url "$name" 2>/dev/null)"; do
      [[ -n "$url" ]] || continue
      canon=$(canonical_remote_url "$url") || continue
      seen=1
      [[ "$canon" != "$destination" ]] || return 0
    done
  done <<<"$remotes"

  # Zero readable remote URLs means the protected set is undetermined.
  (( seen == 1 )) || return 2
  return 1
}
