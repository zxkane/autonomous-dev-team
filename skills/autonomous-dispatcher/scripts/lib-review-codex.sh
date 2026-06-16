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
# [INV-14] BASH_SOURCE-relative source so the per-project scripts/ symlink
# resolves to the project's vendored adapters/ rather than the skill dir.
_LIB_REVIEW_CODEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=adapters/codex.sh
source "${_LIB_REVIEW_CODEX_DIR}/adapters/codex.sh"
