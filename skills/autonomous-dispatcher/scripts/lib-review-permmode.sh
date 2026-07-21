#!/bin/bash
# lib-review-permmode.sh - Pure review permission-mode warning helpers.

# _review_permmode_warning_decision <mode> <resolved-claude-extra-args>
#                                     <injection> <fallback> <fleet...>
#
# Echoes warn only when the resolved fleet contains Claude and the wrapper has
# no unattended verdict-reporting path. Resolved Claude extra args are accepted
# to make the complete decision input explicit, but deliberately ignored:
# static --allowedTools/settings/launcher grants cannot prove access to the
# complete sequence across both per-run directories and post-verdict.sh.
_review_permmode_warning_decision() {
  local mode="${1:-}" claude_extra_args="${2:-}"
  local injection="${3:-false}" fallback="${4:-false}" agent
  local has_claude=false
  : "$claude_extra_args"

  for agent in "${@:5}"; do
    if [[ "$agent" == "claude" ]]; then
      has_claude=true
      break
    fi
  done

  if [[ "$has_claude" != "true" || "$mode" == "bypassPermissions" ]]; then
    printf 'ok\n'
  elif [[ "$mode" == "plan" ]]; then
    printf 'warn\n'
  elif [[ "$fallback" == "true" ]]; then
    printf 'ok\n'
  elif [[ "$mode" == "auto" && "$injection" == "true" ]]; then
    printf 'ok\n'
  else
    printf 'warn\n'
  fi
}

# _review_permmode_warning_canonical <mode> <injection> <fallback> <fleet...>
#
# The ordered resolved fleet is intentional: the fingerprint represents the
# wrapper's effective configuration, not a set reconstructed from raw config.
_review_permmode_warning_canonical() {
  local mode="${1:-}" injection="${2:-}" fallback="${3:-}" agent
  printf 'mode=%s\ninjection=%s\nfallback=%s\nfleet=' \
    "$mode" "$injection" "$fallback"
  for agent in "${@:4}"; do
    printf '%s,' "$agent"
  done
  printf '\n'
}

# _review_permmode_warning_fingerprint <mode> <injection> <fallback> <fleet...>
#
# Emits a stable 16-character configuration hash. sha256sum is preferred;
# shasum covers macOS; cksum is the final portability fallback.
_review_permmode_warning_fingerprint() {
  if command -v sha256sum >/dev/null 2>&1; then
    _review_permmode_warning_canonical "$@" \
      | sha256sum | awk '{ print substr($1, 1, 16) }'
  elif command -v shasum >/dev/null 2>&1; then
    _review_permmode_warning_canonical "$@" \
      | shasum -a 256 | awk '{ print substr($1, 1, 16) }'
  else
    _review_permmode_warning_canonical "$@" \
      | cksum | awk '{ printf "%016x\n", $1 }'
  fi
}

_review_permmode_warning_marker() {
  printf '<!-- review-permmode-warning: fingerprint=%s -->' "$1"
}

# _review_permmode_warning_seen <normalized-comments-json> <fingerprint>
#
# Returns success when any normalized issue comment contains the exact marker.
# The marker is posted only for unsafe evaluations. Consequently, an
# unsafe -> safe -> same-unsafe sequence is indistinguishable from a repeated
# unsafe run and remains deduplicated; safe runs deliberately post no marker.
_review_permmode_warning_seen() {
  local comments_json="$1" marker
  marker="$(_review_permmode_warning_marker "$2")"
  jq -e '
    type == "array"
    and all(.[];
      type == "object"
      and (.authorKind | type == "string")
      and ((.body | type) == "string" or .body == null)
    )
  ' <<<"$comments_json" >/dev/null 2>&1 || return 2
  jq -e --arg marker "$marker" '
    any(
      .[]
      | select(.authorKind == "self")
      | select(.body | type == "string");
      .body | contains($marker)
    )
  ' <<<"$comments_json" >/dev/null 2>&1
}
