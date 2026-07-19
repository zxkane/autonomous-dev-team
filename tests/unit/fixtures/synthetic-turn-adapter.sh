#!/bin/bash
# Test-only enforceable adapter for issue #507. Never sourced by production.

set -uo pipefail

: "${TURN_LIMIT_LIB:?TURN_LIMIT_LIB is required}"
: "${SYNTHETIC_ADMISSION_LOG:?SYNTHETIC_ADMISSION_LOG is required}"

# shellcheck source=/dev/null
source "$TURN_LIMIT_LIB"

request=1
while admit_next_request; do
  printf 'request=%s\n' "$request" >> "$SYNTHETIC_ADMISSION_LOG"
  record=$(printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"turn %s"}]}}' "$request")
  printf '%s\n' "$record"
  if ! observe_completed_turn "$record"; then
    printf 'synthetic-turn-adapter: completed-turn observation could not be persisted\n' >&2
    exit 1
  fi
  request=$((request + 1))
done

if [[ "${SYNTHETIC_SPAWN_DESCENDANT:-false}" == "true" ]]; then
  (
    trap '' TERM
    while :; do
      date +%s >> "${SYNTHETIC_DESCENDANT_LOG:?}"
      sleep 0.1
    done
  ) &
fi

if [[ "${SYNTHETIC_IGNORE_TERM:-false}" == "true" ]]; then
  trap '' TERM
fi

if [[ "${SYNTHETIC_WAIT_AFTER_DENY:-false}" == "true" ]]; then
  while :; do sleep 1; done
fi

exit 0
