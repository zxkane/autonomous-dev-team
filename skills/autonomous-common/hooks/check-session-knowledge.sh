#!/usr/bin/env bash
# Stop backstop: assess an explicitly activated session; no forced distillation.
set -euo pipefail
KNOWLEDGE_HOOK_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib.sh
source "$KNOWLEDGE_HOOK_DIR/lib.sh"
input="$(read_hook_stdin)"
[[ -n "$input" ]] || input='{}'
# Clients can omit cwd; retain the active current worktree on absent/unparseable metadata.
knowledge_cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null || true)"
knowledge_cwd="${knowledge_cwd:-$PWD}"
if ! git -C "$knowledge_cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
  exit 0
fi
exec bash "$KNOWLEDGE_HOOK_DIR/../scripts/session-knowledge.sh" --repo "$knowledge_cwd" check
