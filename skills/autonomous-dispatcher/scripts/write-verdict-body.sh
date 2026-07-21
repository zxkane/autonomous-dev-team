#!/bin/bash
# Atomically write the current review member's verdict comment body from stdin.

set -euo pipefail
umask 077

target="${VERDICT_BODY_FILE:-}"
if [[ -z "$target" || "$target" != /* ]]; then
  echo "Error: VERDICT_BODY_FILE must be an absolute path." >&2
  exit 2
fi

parent="$(dirname "$target")"
if [[ ! -d "$parent" ]]; then
  echo "Error: verdict body directory does not exist: $parent" >&2
  exit 2
fi

tmp="$(mktemp "${target}.tmp.XXXXXX")" || {
  echo "Error: could not create verdict body temp file." >&2
  exit 1
}
# A failed best-effort cleanup must not replace the writer's original exit code.
trap 'rm -f -- "$tmp" 2>/dev/null || true' EXIT

if ! cat > "$tmp"; then
  echo "Error: could not write verdict body temp file." >&2
  exit 1
fi
mv -f -- "$tmp" "$target"
trap - EXIT
