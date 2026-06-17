#!/bin/bash
# lib-review-agy.sh — COMPAT SHIM ([INV-75], #232).
#
# The agy quota/auth drop-reason detector (INV-58) moved INTO adapters/agy.sh,
# where all per-CLI agy behavior now lives (argv, model validation, session
# capture, drop-reason). This shim sources that adapter so the source-by-path
# contract is preserved with no caller changes (lib-agent-smoke.sh sources this
# file by path for the drop-reason fns; the CI shellcheck list names this path).
#
# The adapter is normally already sourced by lib-agent.sh; re-sourcing here is an
# idempotent function redefinition.
#
# [INV-14]/[INV-65] Resolve adapters/ from this shim's REAL location (readlink -f
# of its own BASH_SOURCE), exactly like lib-agent.sh — so a direct per-lib symlink
# to this shim (no sibling adapters/) still finds adapters/agy.sh in the skill tree.
_LIB_REVIEW_AGY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
# shellcheck source=adapters/agy.sh
source "${_LIB_REVIEW_AGY_DIR}/adapters/agy.sh"
