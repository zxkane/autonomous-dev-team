#!/bin/bash
# setup-labels.sh — Create all GitHub labels required by the autonomous pipeline.
# Skips labels that already exist. Safe to run multiple times.
#
# Usage:
#   bash scripts/setup-labels.sh [owner/repo]
#
# If no repo argument is provided, reads REPO from autonomous.conf.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Load config for REPO default
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi

REPO="${1:-${REPO:?Usage: setup-labels.sh [owner/repo] or set REPO in autonomous.conf}}"

# Label definitions: name|color|description
LABELS=(
  "autonomous|0E8A16|Issue should be processed by autonomous pipeline"
  "in-progress|FBCA04|Agent is actively developing"
  "pending-review|1D76DB|Development complete, awaiting review"
  "reviewing|5319E7|Agent is actively reviewing"
  "pending-dev|E99695|Review failed, needs more development"
  "approved|0E8A16|Review passed, PR merged or awaiting manual merge"
  "no-auto-close|d4c5f9|Skip auto-merge after review passes, requires manual approval"
  "stalled|B60205|Issue exceeded max retry attempts, requires manual investigation"
)

echo "Setting up labels for ${REPO}..."

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color description <<< "$entry"

  if gh label view "$name" --repo "$REPO" &>/dev/null; then
    echo "  [skip] '$name' already exists"
  else
    gh label create "$name" --repo "$REPO" \
      --color "$color" \
      --description "$description"
    echo "  [created] '$name'"
  fi
done

echo "Done."
