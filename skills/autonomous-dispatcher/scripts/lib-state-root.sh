#!/bin/bash
# Shared ADT_STATE_ROOT resolver for local and remote lane-registry consumers.

adt_resolve_state_root() {
  local explicit_root="${ADT_STATE_ROOT:-}"
  if [ -n "$explicit_root" ]; then
    printf '%s\n' "$explicit_root"
    return 0
  fi

  local default_root="${HOME}/.local/state"
  local pointer="${default_root}/adt-state-root"
  if [ ! -e "$pointer" ] && [ ! -L "$pointer" ]; then
    printf '%s\n' "$default_root"
    return 0
  fi

  local line first="" count=0
  if [ ! -L "$pointer" ] && [ -f "$pointer" ] && [ -r "$pointer" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      count=$((count + 1))
      [ "$count" -eq 1 ] && first="$line"
    done < "$pointer"
    if [ "$count" -eq 1 ]; then
      case "$first" in
        /*)
          printf '%s\n' "$first"
          return 0
          ;;
      esac
    fi
  fi

  printf '[adt-state-root] WARN: invalid host state-root pointer %s; falling back to %s\n' \
    "$pointer" "$default_root" >&2
  printf '%s\n' "$default_root"
}
