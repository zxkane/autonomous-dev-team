#!/bin/bash
# lib-review-codex.sh — COMPAT SHIM ([INV-75], #232).
#
# The codex review lane (INV-62) + its drop-reason scrapers (INV-59) + the
# prompt-echo malformed guard (INV-73) moved INTO adapters/codex.sh, where all
# per-CLI behavior now lives. This shim sources that adapter so the historical
# source-by-path contract is preserved with no caller changes:
#   - tests/conformance/run-conformance.sh sources this file by path for the
#     codex review lane;
#   - lib-agent-smoke.sh sources this file by path for the drop-reason fns;
#   - the CI shellcheck list names this path.
#
# The adapter is normally already sourced by lib-agent.sh (which run_agent's
# dispatch needs); re-sourcing here is an idempotent function redefinition.
#
# [INV-14]/[INV-65] Resolve adapters/ from this shim's REAL location (readlink
# -f of its own BASH_SOURCE), exactly like lib-agent.sh. A direct per-lib
# symlink to this shim (a legacy install) puts the symlink's dir — the caller's
# adapter-less scripts/ — in BASH_SOURCE; resolving the symlink first lands on
# the skill tree where adapters/codex.sh actually lives, keeping source-by-path
# working with or without a sibling adapters/ symlink.
_LIB_REVIEW_CODEX_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
# shellcheck source=adapters/codex.sh
source "${_LIB_REVIEW_CODEX_DIR}/adapters/codex.sh"
