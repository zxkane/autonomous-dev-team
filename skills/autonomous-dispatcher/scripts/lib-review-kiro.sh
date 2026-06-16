#!/bin/bash
# lib-review-kiro.sh — COMPAT SHIM ([INV-75], #232).
#
# The kiro auth/login-failure drop-reason detector (INV-61) moved INTO
# adapters/kiro.sh, where all per-CLI kiro behavior now lives (argv, binary
# alias, drop-reason). This shim sources that adapter so the source-by-path
# contract is preserved with no caller changes (lib-agent-smoke.sh sources this
# file by path for the drop-reason fns; the CI shellcheck list names this path).
#
# The adapter is normally already sourced by lib-agent.sh; re-sourcing here is an
# idempotent function redefinition.
#
# [INV-14] BASH_SOURCE-relative source (per-project symlink → vendored adapters/).
_LIB_REVIEW_KIRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=adapters/kiro.sh
source "${_LIB_REVIEW_KIRO_DIR}/adapters/kiro.sh"
