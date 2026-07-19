#!/bin/bash
# Synchronous execution-host token projection for remote-aws-ssm (INV-141).

set -uo pipefail

MODE=projection
ISSUE_NUM="${1:-}"
OWNER=""
INVOCATION=""
case "$ISSUE_NUM" in
  --recovery-read|--recovery-clear)
    MODE="${ISSUE_NUM#--recovery-}"
    ISSUE_NUM="${2:-}"
    OWNER="${3:-}"
    INVOCATION="${4:-}"
    ;;
  --turn-recovery-complete)
    MODE=turn-recovery-complete
    ISSUE_NUM="${2:-}"
    OWNER="${3:-}"
    ;;
esac
if ! [[ "$ISSUE_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: issue number must be a positive integer" >&2
  exit 1
fi
if [[ "$MODE" != "projection" ]]; then
  if [[ "$OWNER" != "dev-wrapper" && "$OWNER" != "review-wrapper" ]]; then
    echo "ERROR: recovery owner must be dev-wrapper or review-wrapper" >&2
    exit 1
  fi
  if [[ "$MODE" == "clear" && ! "$INVOCATION" =~ ^inv-v1-[0-9a-f]{24}$ ]]; then
    echo "ERROR: invalid recovery invocation id" >&2
    exit 1
  fi
fi

: "${SSM_INSTANCE_ID:?SSM_INSTANCE_ID required for remote token projection}"
: "${SSM_REMOTE_PROJECT_DIR:?SSM_REMOTE_PROJECT_DIR required for remote token projection}"
: "${SSM_REMOTE_PROJECT_ID:?SSM_REMOTE_PROJECT_ID required for remote token projection}"

SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="${SELF%/*}"
# shellcheck source=lib-ssm.sh
source "${SCRIPT_DIR}/lib-ssm.sh"

if ! [[ "$SSM_REMOTE_PROJECT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERROR: unsafe SSM_REMOTE_PROJECT_ID" >&2
  exit 1
fi
if [[ "$SSM_REMOTE_PROJECT_DIR" != /* ]] || _has_shell_metachar "$SSM_REMOTE_PROJECT_DIR"; then
  echo "ERROR: unsafe SSM_REMOTE_PROJECT_DIR" >&2
  exit 1
fi

SSM_REGION="${SSM_REGION:-ap-southeast-1}"
SSM_REMOTE_USER="${SSM_REMOTE_USER:-ubuntu}"
SSM_REMOTE_SHELL="${SSM_REMOTE_SHELL:-bash}"
SSM_REMOTE_PROFILE="${SSM_REMOTE_PROFILE:-}"

[[ "$SSM_REMOTE_USER" =~ ^[A-Za-z0-9_-]+$ ]] || exit 1
[[ "$SSM_REMOTE_SHELL" =~ ^(bash|zsh|sh)$ ]] || exit 1
if [[ -n "$SSM_REMOTE_PROFILE" ]] \
    && { [[ "$SSM_REMOTE_PROFILE" != /* ]] || _has_shell_metachar "$SSM_REMOTE_PROFILE"; }; then
  echo "ERROR: unsafe SSM_REMOTE_PROFILE" >&2
  exit 1
fi

profile_prefix=""
[[ -z "$SSM_REMOTE_PROFILE" ]] || profile_prefix="source ${SSM_REMOTE_PROFILE}; "

case "$MODE" in
  projection)
    REMOTE_ACTION="token_issue_projection \"${ISSUE_NUM}\""
    ;;
  read)
    REMOTE_ACTION="_token_budget_recovery_pointer_read_local \"${ISSUE_NUM}\" \"${OWNER}\""
    ;;
  clear)
    REMOTE_ACTION="_token_budget_recovery_pointer_clear_local \"${ISSUE_NUM}\" \"${OWNER}\" \"${INVOCATION}\""
    ;;
  turn-recovery-complete)
    REMOTE_ACTION="_turn_control_recovery_complete_local \"${ISSUE_NUM}\" \"${OWNER}\""
    ;;
  *)
    exit 1
    ;;
esac

INNER_CMD=$(cat <<EOF
${profile_prefix}set -u
export PROJECT_ID="${SSM_REMOTE_PROJECT_ID}"
export TOKEN_BUDGET_FORCE_LOCAL=1
source "${SSM_REMOTE_PROJECT_DIR}/scripts/lib-accounting.sh"
source "${SSM_REMOTE_PROJECT_DIR}/scripts/lib-token-budget.sh"
source "${SSM_REMOTE_PROJECT_DIR}/scripts/lib-turn-limit.sh"
${REMOTE_ACTION}
EOF
)

FULL_CMD="$(_ssm_build_full_cmd "$SSM_REMOTE_USER" "$SSM_REMOTE_SHELL" "$INNER_CMD")" || exit 2
remote_stdout="$(_ssm_run_remote_command "$SSM_INSTANCE_ID" "$SSM_REGION" "$FULL_CMD")"
rc=$?
[[ "$rc" -eq 0 ]] || exit 2
printf '%s\n' "$remote_stdout"
