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
# lib is absent the verb stays undefined and the loop below FAILs LOUD ([INV-91])
# rather than fall back to a raw gh-label leaf — a hardcoded GitHub call would
# silently provision GitHub labels for a non-GitHub backend (provider not loaded).
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
# only the per-label view-or-create leaf moves behind itp_provision_states.
#
# The DOCUMENTED branch point is the `label_colors` CAPABILITY (spec §4.1), NOT
# `declare -F itp_provision_states` — after lib-issue-provider.sh is sourced the
# `itp_provision_states` SHIM is always defined (it forwards to
# itp_${ISSUE_PROVIDER}_provision_states), so a `declare -F` check never falls back
# and a backend without the leaf would crash with
# `itp_<p>_provision_states: command not found`. We branch on the cap instead:
#   - label_colors=1 (GitHub) → itp_provision_states emits the byte-identical
#     `gh label view`/`gh label create --color <hex> --description <d>` (hex passed).
#   - label_colors=0 → the documented color-omitted provisioning path, DEFINED but
#     NOT LIVE this PR (no non-GitHub provision leaf exists yet) — fail LOUD-but-clean
#     (no missing-leaf crash) so the no-behavior-change scope holds and the gap is
#     visible, not silent.
# When the provider lib is unavailable the itp_provision_states SHIM is undefined; we
# FAIL LOUD ([INV-91]) rather than fall back to a raw gh-label leaf — a hardcoded
# GitHub call would silently provision GitHub labels even when the project is
# configured for a non-GitHub backend (provider not loaded), the silent-wrong-backend
# bug the cutover guard exists to prevent.
_LC_CAP=""
if declare -F itp_caps >/dev/null 2>&1; then
  _LC_CAP="$(itp_caps label_colors 2>/dev/null || true)"
fi
if [[ "$_LC_CAP" == "0" ]]; then
  echo "Error: provider '${ISSUE_PROVIDER:-?}' has label_colors=0 — color-omitted state provisioning is defined but not implemented this PR (this PR migrates the GitHub --color label-create leaf only). Skipping label provisioning for ${REPO}." >&2
  exit 1
fi

if ! declare -F itp_provision_states >/dev/null 2>&1; then
  echo "Error: itp_provision_states not available (provider lib not loaded; ISSUE_PROVIDER=${ISSUE_PROVIDER:-?}). Cannot provision labels for ${REPO}." >&2
  exit 1
fi

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color description <<< "$entry"
  itp_provision_states "$name" "$color" "$description"
done

echo "Done."
