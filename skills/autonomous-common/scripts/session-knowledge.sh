#!/usr/bin/env bash
# Shared agent/hook entry point; Python uses only the standard library.
set -euo pipefail
KNOWLEDGE_SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
exec python3 "$KNOWLEDGE_SCRIPT_DIR/session-knowledge.py" "$@"
