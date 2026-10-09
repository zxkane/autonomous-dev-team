#!/usr/bin/env bash
# Confirm an actual merge, then retry optional knowledge commit/publication.
set -euo pipefail
_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(dirname "$(readlink -f "$_SELF")")"
export AUTONOMOUS_CONF_DIR="$SCRIPT_DIR"
source "$LIB_DIR/lib-agent.sh"
source "$LIB_DIR/lib-auth.sh"
source "$LIB_DIR/lib-code-host.sh"
source "$LIB_DIR/lib-session-knowledge.sh"
ISSUE_NUMBER=""; PR_NUMBER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE_NUMBER="${2:-}"; shift 2 ;;
    --pr) PR_NUMBER="${2:-}"; shift 2 ;;
    *) echo 'Usage: distill-knowledge.sh --issue <issue> --pr <merged-pr>' >&2; exit 2 ;;
  esac
done
[[ "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ && "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
  echo 'Usage: distill-knowledge.sh --issue <issue> --pr <merged-pr>' >&2
  exit 2
}
BASE_BRANCH="$(resolve_base_branch)"
export BASE_BRANCH AUTONOMOUS_PROJECT_DIR="$PROJECT_DIR"
cd "$PROJECT_DIR"
if github_seam_active; then
  setup_github_auth "${REVIEW_AGENT_APP_ID:-}" "${REVIEW_AGENT_APP_PEM:-}"
  trap cleanup_github_auth EXIT
fi
if ! postmerge_session_knowledge "$ISSUE_NUMBER" "$PR_NUMBER"; then
  echo '[session-knowledge] Writeback remains pending. Inspect/correct candidates and retry this command.' >&2
  exit 1
fi
