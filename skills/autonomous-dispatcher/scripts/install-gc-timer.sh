#!/bin/bash
# install-gc-timer.sh — Lane-GC series PR-4: idempotent per-host timer
# installer for adt-gc.sh (design: docs/designs/lane-containment-gc.md
# §4-C5/§9 PR-4; docs/designs/lane-gc-p4-adt-gc.md; [INV-117]).
#
# One timer per HOST, not per project — adt-gc.sh itself scans every
# project's registry under ${ADT_STATE_ROOT}/autonomous-*/lanes/ in one
# invocation, so installing this more than once per host is pointless
# (and installing it once per project would spawn N redundant GC runs
# racing on the same singleton lock).
#
# Linux: edits the current user's crontab, adding a `*/10 * * * *` entry
#   that runs adt-gc.sh, guarded by a fixed marker COMMENT line so re-runs
#   REPLACE the existing entry instead of stacking duplicates. Cron is used
#   (not a systemd --user timer) because it works without `loginctl
#   enable-linger` (design §7 platform matrix: "works without linger").
# macOS: installs a launchd user agent plist
#   (~/Library/LaunchAgents/com.adt.lane-gc.plist, StartInterval=600) and
#   `launchctl bootstrap`s it into the gui/<uid> domain. cron is
#   deliberately avoided on macOS — running scripts from cron trips TCC
#   permission prompts there (design §7).
#
# Usage:
#   install-gc-timer.sh [--uninstall] [-h|--help]
#
# Exit codes: 0 success (incl. already-installed, unchanged); 1 error.

set -uo pipefail

_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
ADT_GC_SH="${LIB_DIR}/adt-gc.sh"

GC_MARKER="# adt-gc-timer (autonomous-dev-team Lane-GC series, do not edit — managed by install-gc-timer.sh)"
LAUNCHD_LABEL="com.adt.lane-gc"
LAUNCHD_PLIST="${HOME:-}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

# _gct_uname — overridable seam for tests, mirrors lib-lane.sh::_lane_uname
# so a unit test can force the macOS branch on Linux CI without a runner.
_gct_uname() {
  echo "${_LANE_UNAME_OVERRIDE:-$(uname -s 2>/dev/null || echo Linux)}"
}

UNINSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=true ;;
    -h|--help)
      echo "Usage: install-gc-timer.sh [--uninstall]" >&2
      exit 0
      ;;
    *) echo "install-gc-timer.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ ! -f "$ADT_GC_SH" ]]; then
  echo "install-gc-timer.sh: adt-gc.sh not found at ${ADT_GC_SH} — cannot install a timer pointing at a missing script" >&2
  exit 1
fi

# [Lane-GC PR-4 review round-2, P2-4] Reject any path that would land
# unescaped inside the cron entry / plist and either break the schedule or
# be silently mis-parsed. `%` is cron's command/stdin-continuation separator
# — an unquoted `%` in a path SILENTLY TRUNCATES the command at that point
# (cron treats everything after the FIRST unescaped `%` as stdin for the
# job, not part of argv), which for `bash ${ADT_GC_SH} ...` means either a
# corrupted invocation or the wrong script running unattended every 10
# minutes. A literal newline would either terminate the crontab line
# early (splitting one entry into two, one of which cron may reject or
# silently ignore) or break `cat > "$LAUNCHD_PLIST"` on the macOS side.
# Fail LOUD naming the offending path rather than installing a broken timer.
_gct_reject_unsafe_path() {
  local path="$1" label="$2"
  if [[ "$path" == *"%"* || "$path" == *$'\n'* ]]; then
    echo "install-gc-timer.sh: ${label} contains '%' or a newline — refusing to install a timer with an unsafe path: ${path}" >&2
    exit 1
  fi
}
_gct_reject_unsafe_path "$ADT_GC_SH" "adt-gc.sh path"

_gct_install_linux() {
  local logfile="${ADT_STATE_ROOT:-$HOME/.local/state}/adt-gc-cron.log"
  _gct_reject_unsafe_path "$logfile" "GC log path (ADT_STATE_ROOT)"
  # [P2-4] Quote both paths inside the cron command — a path containing
  # whitespace (unusual but possible under an operator-chosen
  # ADT_STATE_ROOT) would otherwise be word-split by the shell cron execs
  # the entry with, silently changing argv.
  local entry="*/10 * * * * bash '${ADT_GC_SH}' >> '${logfile}' 2>&1 ${GC_MARKER}"
  local existing new
  existing="$(crontab -l 2>/dev/null || true)"

  # [Lane-GC PR-4 review round-2, P2-3] Exact-line matching, not
  # substring-containment: `grep -vF "$GC_MARKER"` (the pre-fix behavior)
  # dropped EVERY line that merely CONTAINS the marker text anywhere —
  # including an unrelated operator comment that happens to mention the
  # marker string mid-line (e.g. documentation, a decoy, or a copy-pasted
  # snippet) — silently destroying crontab content this tool never
  # installed and has no business touching. The managed entry always ends
  # with the marker (it's appended as the LAST token of `$entry` above,
  # verbatim, every time this script writes it), so "is this OUR line"
  # is correctly decided by an EXACT SUFFIX match, not containment.
  # Bash substring suffix (`${line: -N}`) is used instead of `awk`/`sed`
  # regex to avoid re-deriving marker-escaping rules for two more tools —
  # the marker contains parens and an em-dash that would need escaping in
  # both awk's and sed's own regex dialects.
  _gct_is_managed_line() {
    local line="$1"
    [[ "${#line}" -ge "${#GC_MARKER}" ]] || return 1
    [[ "${line: -${#GC_MARKER}}" == "$GC_MARKER" ]]
  }
  _gct_filter_managed() {
    local input="$1" line out=""
    while IFS= read -r line; do
      _gct_is_managed_line "$line" && continue
      out+="${line}"$'\n'
    done <<<"$input"
    printf '%s' "${out%$'\n'}"
  }

  if [[ "$UNINSTALL" == true ]]; then
    if [[ -z "$existing" ]]; then
      echo "install-gc-timer.sh: no crontab present — nothing to uninstall"
      return 0
    fi
    new="$(_gct_filter_managed "$existing")"
    printf '%s\n' "$new" | crontab -
    echo "install-gc-timer.sh: removed GC cron entry"
    return 0
  fi

  if [[ -n "$existing" ]]; then
    # Idempotent replace: drop the old managed line (exact-suffix match
    # only — never touches an operator line that merely mentions the
    # marker text), then re-add the current one — so a re-run after
    # adt-gc.sh moves on disk (a `npx skills update -g` refresh) repoints
    # the entry instead of leaving a stale duplicate.
    new="$(_gct_filter_managed "$existing")"
    if [[ -n "$new" ]]; then
      new="$(printf '%s\n%s\n' "$new" "$entry")"
    else
      new="$entry"
    fi
  else
    new="$entry"
  fi
  printf '%s\n' "$new" | crontab -
  echo "install-gc-timer.sh: installed/updated GC cron entry (every 10 min): ${ADT_GC_SH}"
}

_gct_install_macos() {
  mkdir -p "$(dirname "$LAUNCHD_PLIST")" 2>/dev/null || true

  if [[ "$UNINSTALL" == true ]]; then
    launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST" 2>/dev/null || true
    echo "install-gc-timer.sh: removed launchd GC agent"
    return 0
  fi

  local logfile="${ADT_STATE_ROOT:-$HOME/.local/state}/adt-gc-launchd.log"
  _gct_reject_unsafe_path "$logfile" "GC log path (ADT_STATE_ROOT)"
  local bash_bin
  bash_bin="$(command -v bash)"

  cat > "$LAUNCHD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bash_bin}</string>
    <string>${ADT_GC_SH}</string>
  </array>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>StandardOutPath</key>
  <string>${logfile}</string>
  <key>StandardErrorPath</key>
  <string>${logfile}</string>
</dict>
</plist>
PLIST

  # bootout-then-bootstrap makes re-run idempotent (a plain re-bootstrap
  # over an already-loaded label is a no-op-with-warning on some macOS
  # versions; bootout first guarantees the fresh plist actually takes).
  launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null; then
    echo "install-gc-timer.sh: installed/updated launchd GC agent (every 600s): ${ADT_GC_SH}"
  else
    echo "install-gc-timer.sh: WARN — launchctl bootstrap failed; plist written to ${LAUNCHD_PLIST} but not loaded" >&2
    return 1
  fi
}

case "$(_gct_uname)" in
  Darwin) _gct_install_macos ;;
  *)      _gct_install_linux ;;
esac
