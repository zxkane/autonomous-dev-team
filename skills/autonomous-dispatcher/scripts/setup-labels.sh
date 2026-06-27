#!/bin/bash
# setup-labels.sh — Create all GitHub labels required by the autonomous pipeline.
# Skips labels that already exist. Safe to run multiple times.
#
# Usage:
#   bash scripts/setup-labels.sh [owner/repo]
#
# If no repo argument is provided, reads REPO from autonomous.conf.

set -euo pipefail

# [INV-14] Use BASH_SOURCE[0] (NOT readlink -f) so a project-side symlink
# at <project>/scripts/setup-labels.sh resolves SCRIPT_DIR to the
# project's scripts/, where autonomous.conf lives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Load config for REPO default
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi

REPO="${1:-${REPO:?Usage: setup-labels.sh [owner/repo] or set REPO in autonomous.conf}}"

# [INV-87] Issue-Tracker Provider dispatch. The state-primitive provisioning leaf
# routes through itp_provision_states (→ itp_${ISSUE_PROVIDER}_provision_states).
# lib-issue-provider.sh is a sibling in the REAL skill tree; resolve it via
# readlink -f of THIS script (the [INV-14]/[INV-65] idiom) — NOT SCRIPT_DIR, which
# is intentionally the project-side symlink dir for conf-lookup. Guarded: if the
# lib is absent the verb stays undefined and the loop below falls back to the
# inline gh-label leaf (keeps the script self-contained when run standalone).
if ! declare -F itp_provision_states >/dev/null 2>&1; then
  _sl_real_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd 2>/dev/null)" || _sl_real_dir=""
  if [[ -n "$_sl_real_dir" && -r "${_sl_real_dir}/lib-issue-provider.sh" ]]; then
    # shellcheck source=lib-issue-provider.sh
    source "${_sl_real_dir}/lib-issue-provider.sh"
  fi
  unset _sl_real_dir
fi

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
  "run-live-smoke|006B75|Maintainer gate — run the live agent-smoke CI tier on the self-hosted runner (issue #238, INV-77)"
)

echo "Setting up labels for ${REPO}..."

# [INV-87] The 9-label name|color|description definition table stays caller-side;
# only the per-label view-or-create leaf moves behind itp_provision_states. On
# GitHub (`label_colors=1`) the byte-identical
# `gh label view`/`gh label create --color <hex> --description <d>` runs and the
# `--color` hex is emitted; a `label_colors=0` backend omits color (defined; not
# live this PR). Fallback to the inline gh-label leaf if the provider lib is
# unavailable (keeps the script self-contained).
for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color description <<< "$entry"

  if declare -F itp_provision_states >/dev/null 2>&1; then
    itp_provision_states "$name" "$color" "$description"
  elif gh label view "$name" --repo "$REPO" &>/dev/null; then
    echo "  [skip] '$name' already exists"
  else
    gh label create "$name" --repo "$REPO" \
      --color "$color" \
      --description "$description"
    echo "  [created] '$name'"
  fi
done

echo "Done."
