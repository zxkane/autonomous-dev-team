#!/bin/bash
# lib-github-transport.sh — GitHub CLI capability check, shared by
# itp-github.sh and chp-github.sh (mirrors the lib-gitlab-transport.sh
# self-source pattern, #416).
#
# Both GitHub provider leaves (itp-github.sh's list-comments leaf,
# chp-github.sh's incidental-read leaves) shell out to `gh api --paginate
# --slurp`. `--slurp` was added in GitHub CLI v2.48.0 (2024-04-17) — on an
# older `gh`, the call prints "unknown flag: --slurp" to stderr and the
# pipeline returns empty, which fails much later and opaquely (e.g. a `-ge`
# integer comparison over an empty retry count trips `set -euo pipefail` and
# aborts the dispatcher tick mid-run).
#
# Double-source guard (idempotent — only defines a function + module-scope
# state), mirroring lib-gitlab-transport.sh's `_LIB_GITLAB_TRANSPORT_SOURCED`
# sentinel. The self-source blocks in itp-github.sh / chp-github.sh additionally
# gate on `declare -F gh_version_ok` so a unit test's test-local stub (or the
# sibling leaf's earlier source) is never clobbered.
if [[ "${_LIB_GITHUB_TRANSPORT_SOURCED:-0}" -eq 1 ]]; then
  return 0 2>/dev/null || exit 0
fi
_LIB_GITHUB_TRANSPORT_SOURCED=1

GH_MIN_VERSION="2.48.0"

# GH_INSTALLED_VERSION — populated by gh_version_ok(); the raw first line of
# `gh --version` (or "<not found>"), for callers that want it in a FATAL
# message without invoking `gh --version` a second time.
GH_INSTALLED_VERSION=""

# gh_version_ok MIN_VERSION — 0 if `gh --version`'s parsed version is >=
# MIN_VERSION, 1 otherwise (including "gh not on PATH" / unparseable output).
# Uses `sort -V` (numeric-aware version sort, GNU/uutils/BSD-portable) rather
# than a bespoke field-by-field comparator. Sets GH_INSTALLED_VERSION as a
# side effect (single `gh --version` invocation for the whole preflight).
gh_version_ok() {
  local min_version="$1" installed first
  installed="$(gh --version 2>/dev/null | head -1)"
  GH_INSTALLED_VERSION="${installed:-<not found>}"
  installed="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$installed" | head -1)"
  [[ -n "$installed" ]] || return 1
  first="$(printf '%s\n%s\n' "$min_version" "$installed" | sort -V | head -1)"
  [[ "$first" == "$min_version" ]]
}
