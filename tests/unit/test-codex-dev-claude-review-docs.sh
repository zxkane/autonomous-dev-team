#!/bin/bash
# Static workflow guidance regressions for issue #486.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

require_text() {
  local desc="$1" file="$2" pattern="$3"
  if tr '\n' ' ' < "$file" | grep -qiE "$pattern"; then
    ok "$desc"
  else
    bad "$desc"
  fi
}

DEV_SKILL="$PROJECT_ROOT/skills/autonomous-dev/SKILL.md"
DEV_CROSS="$PROJECT_ROOT/skills/autonomous-dev/references/cross-platform.md"
REVIEW_SKILL="$PROJECT_ROOT/skills/autonomous-review/SKILL.md"
AGENT_DOC="$PROJECT_ROOT/docs/agent-clis.md"
HOOK_DOC="$PROJECT_ROOT/docs/cross-agent-hooks.md"
SIMPLIFIER_HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/check-code-simplifier.sh"
PR_REVIEW_HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/check-pr-review.sh"
CONF="$PROJECT_ROOT/scripts/autonomous.conf.example"
VENDORED_CONF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous.conf.example"

echo "=== TC-CDCR-030: Codex-native dev quality passes ==="
require_text "dev skill names Codex native subagents" "$DEV_SKILL" \
  'Codex.*(native )?subagent|subagent.*Codex'
require_text "dev skill names dedicated codex review" "$DEV_SKILL" \
  'codex review --(uncommitted|base)'
require_text "cross-platform map lists Codex hooks as full" "$DEV_CROSS" \
  'Codex CLI[[:space:]]*\|[[:space:]]*Full'
require_text "simplification hook feedback offers Codex-native review" "$SIMPLIFIER_HOOK" \
  'Codex.*(subagent|codex review --uncommitted)'
require_text "pre-push hook feedback offers Codex-native review" "$PR_REVIEW_HOOK" \
  'Codex.*(subagent|codex review --base)'

echo "=== TC-CDCR-031/032: final-review ownership and mechanism separation ==="
require_text "internal subagents are advisory" "$REVIEW_SKILL" \
  'internal.*subagents?.*advisory|subagents?.*advisory'
require_text "main review session owns decision gate" "$REVIEW_SKILL" \
  'main review session.*Findings.*Decision Gate|assigned main.*Decision Gate'
require_text "main review session alone calls post-verdict" "$REVIEW_SKILL" \
  'main review session.*post-verdict\.sh|only.*main.*post-verdict\.sh'
require_text "operator docs distinguish all three review mechanisms" "$AGENT_DOC" \
  'REVIEW_BOTS.*AGENT_REVIEW_AGENTS.*internal subagents|internal subagents.*AGENT_REVIEW_AGENTS.*REVIEW_BOTS'

echo "=== TC-CDCR-033: canonical mixed topology guidance ==="
require_text "agent docs name Codex-dev Claude-review topology" "$AGENT_DOC" \
  'AGENT_DEV_CMD="?codex"?.*AGENT_REVIEW_CMD="?claude"?'
require_text "config example names Codex-dev Claude-review topology" "$CONF" \
  'AGENT_DEV_CMD="?codex"?.*AGENT_REVIEW_CMD="?claude"?'
require_text "hook docs use canonical features.hooks" "$HOOK_DOC" \
  'features\][[:space:]]*hooks[[:space:]]*=[[:space:]]*true'
require_text "hook docs describe project trust" "$HOOK_DOC" \
  'project.*trust|trust.*project'
require_text "hook docs state the tomllib prerequisite" "$HOOK_DOC" \
  'Python 3\.11.*tomllib|tomllib.*Python 3\.11'
require_text "hook docs name operation-aware normalization" "$HOOK_DOC" \
  'parse_edit_file_operations.*operation.*path'
if cmp -s "$CONF" "$VENDORED_CONF"; then
  ok "root and vendored config examples remain identical"
else
  bad "root and vendored config examples remain identical"
fi

echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
