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

# _gh_transport_binary — echo the `gh` binary to invoke, honoring the same
# `REAL_GH` escape hatch gh-with-token-refresh.sh resolves (#92): an
# executable `REAL_GH` is used directly (installs outside the minimal
# non-interactive PATH — cron/systemd/SSM — that never sourced rc files);
# otherwise fall back to the bare `gh` name so a normal PATH lookup applies.
# This precheck runs standalone, BEFORE dispatcher-tick.sh's auth/wrapper
# setup installs the token-refresh proxy, so it must resolve independently
# rather than assume the proxy is already on PATH.
_gh_transport_binary() {
  if [[ -n "${REAL_GH:-}" && -x "$REAL_GH" ]]; then
    printf '%s\n' "$REAL_GH"
  else
    printf 'gh\n'
  fi
}

# _gh_version_ge MIN INSTALLED — 0 if INSTALLED (an "X.Y.Z" string) is >=
# MIN, 1 otherwise. Numeric per-component comparison (major, then minor,
# then patch) — portable across GNU/BSD/macOS/uutils, unlike `sort -V`
# (not part of POSIX/BSD sort; a host without GNU coreutils would silently
# misreport every version as "too old" when the -V flag itself errors).
_gh_version_ge() {
  local min="$1" installed="$2"
  local -a min_parts installed_parts
  IFS='.' read -r -a min_parts <<<"$min"
  IFS='.' read -r -a installed_parts <<<"$installed"
  local i
  for i in 0 1 2; do
    local m="${min_parts[$i]:-0}" v="${installed_parts[$i]:-0}"
    (( v > m )) && return 0
    (( v < m )) && return 1
  done
  return 0
}

# gh_version_ok MIN_VERSION — 0 if the resolved gh binary's `--version` is >=
# MIN_VERSION, 1 otherwise (including "gh not on PATH" / unparseable output).
# Sets GH_INSTALLED_VERSION as a side effect (single `gh --version`
# invocation for the whole preflight).
gh_version_ok() {
  local min_version="$1" bin installed
  bin="$(_gh_transport_binary)"
  installed="$("$bin" --version 2>/dev/null | head -1)"
  GH_INSTALLED_VERSION="${installed:-<not found>}"
  installed="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$installed" | head -1)"
  [[ -n "$installed" ]] || return 1
  _gh_version_ge "$min_version" "$installed"
}
