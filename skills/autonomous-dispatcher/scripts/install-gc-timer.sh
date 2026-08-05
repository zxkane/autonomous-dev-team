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
  if [[ -n "${_LANE_UNAME_OVERRIDE:-}" ]]; then
    printf '%s\n' "$_LANE_UNAME_OVERRIDE"
    return 0
  fi
  local os
  os="$(uname -s 2>/dev/null)" || os="Unknown"
  [[ -n "$os" ]] || os="Unknown"
  printf '%s\n' "$os"
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
  # `'` is rejected alongside `%`/newline (review round-3 [P2]): the cron
  # entry single-quotes both paths, and a single quote INSIDE a
  # single-quoted shell string terminates the quoting — a path like
  # /tmp/x'root would split the cron command mid-token and let the
  # remainder parse as fresh shell words (token injection), exactly what
  # the quoting exists to prevent. Escaping ('\'' splicing) was rejected
  # in favor of rejection-with-a-loud-error: no legitimate ADT_STATE_ROOT
  # or skill-tree path contains a quote, so the added complexity would
  # only ever serve a misconfiguration.
  if [[ "$path" == *"%"* || "$path" == *"'"* || "$path" == *$'\n'* ]]; then
    echo "install-gc-timer.sh: ${label} contains '%', a single quote, or a newline — refusing to install a timer with an unsafe path: ${path}" >&2
    exit 1
  fi
}
_gct_reject_unsafe_path "$ADT_GC_SH" "adt-gc.sh path"
# Reuse an existing host pointer when ADT_STATE_ROOT is omitted. Otherwise a
# routine installer re-run would silently repoint a custom-root installation
# and orphan its registry, logs, and rollback file under the old root.
# shellcheck source=lib-state-root.sh
source "${LIB_DIR}/lib-state-root.sh"
GCT_STATE_ROOT="$(adt_resolve_state_root)"
GCT_DEFAULT_STATE_ROOT="$HOME/.local/state"
GCT_ROOT_POINTER="$GCT_DEFAULT_STATE_ROOT/adt-state-root"
if [[ "$GCT_STATE_ROOT" != /* ]]; then
  echo "install-gc-timer.sh: ADT_STATE_ROOT must be absolute: ${GCT_STATE_ROOT}" >&2
  exit 1
fi

_gct_reject_unsafe_xml_value() {
  local value="$1" label="$2"
  if [[ "$value" == *"&"* || "$value" == *"<"* || "$value" == *">"* ]]; then
    echo "install-gc-timer.sh: ${label} contains '&', '<', or '>' — refusing to write an invalid launchd plist value: ${value}" >&2
    exit 1
  fi
}

_gct_persist_state_root() {
  local tmp
  if ! mkdir -p "$GCT_DEFAULT_STATE_ROOT" 2>/dev/null; then
    echo "install-gc-timer.sh: cannot create host state-root pointer directory: ${GCT_DEFAULT_STATE_ROOT}" >&2
    return 1
  fi
  tmp="$(mktemp "${GCT_ROOT_POINTER}.tmp.XXXXXX" 2>/dev/null)" || {
    echo "install-gc-timer.sh: cannot create host state-root pointer temp file: ${GCT_ROOT_POINTER}" >&2
    return 1
  }
  if ! printf '%s\n' "$GCT_STATE_ROOT" > "$tmp" || ! chmod 600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$GCT_ROOT_POINTER"; then
    rm -f "$tmp" 2>/dev/null || true  # Primary persist failure is reported below; temp cleanup is best-effort.
    echo "install-gc-timer.sh: cannot persist host state-root pointer: ${GCT_ROOT_POINTER}" >&2
    return 1
  fi
}

_gct_restore_linux_crontab() {
  local had_existing="$1" existing="$2"
  if [[ "$had_existing" == true ]]; then
    printf '%s\n' "$existing" | crontab -
  else
    crontab -r >/dev/null 2>&1
  fi
}

_gct_restore_macos_install() {
  local had_plist="$1" plist_backup="$2"
  local restored=true
  launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true  # An absent/failed new job must not block restoring the prior install.
  if [[ "$had_plist" == true ]]; then
    if ! mv -f "$plist_backup" "$LAUNCHD_PLIST"; then
      restored=false
    elif ! launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null; then
      restored=false
    fi
  else
    rm -f "$LAUNCHD_PLIST" "$plist_backup" 2>/dev/null || restored=false
  fi
  [[ "$restored" == true ]]
}

_gct_install_linux() {
  local logfile="${GCT_STATE_ROOT}/adt-gc-cron.log"
  _gct_reject_unsafe_path "$GCT_STATE_ROOT" "ADT_STATE_ROOT"
  _gct_reject_unsafe_path "$logfile" "GC log path (ADT_STATE_ROOT)"
  # [P2-4] Quote both paths inside the cron command — a path containing
  # whitespace (unusual but possible under an operator-chosen
  # ADT_STATE_ROOT) would otherwise be word-split by the shell cron execs
  # the entry with, silently changing argv.
  local entry="*/10 * * * * ADT_STATE_ROOT='${GCT_STATE_ROOT}' bash '${ADT_GC_SH}' >> '${logfile}' 2>&1 ${GC_MARKER}"
  local existing="" new had_existing=false
  if existing="$(crontab -l 2>/dev/null)"; then
    had_existing=true
  fi

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
    if ! printf '%s\n' "$new" | crontab -; then
      echo "install-gc-timer.sh: cannot update crontab while uninstalling GC timer" >&2
      return 1
    fi
    echo "install-gc-timer.sh: removed GC cron entry"
    return 0
  fi

  if ! mkdir -p "$GCT_STATE_ROOT" 2>/dev/null; then
    echo "install-gc-timer.sh: cannot create ADT_STATE_ROOT: ${GCT_STATE_ROOT}" >&2
    return 1
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
  if ! printf '%s\n' "$new" | crontab -; then
    echo "install-gc-timer.sh: cannot install/update GC cron entry" >&2
    return 1
  fi
  if ! _gct_persist_state_root; then
    if ! _gct_restore_linux_crontab "$had_existing" "$existing"; then
      echo "install-gc-timer.sh: ERROR: root-pointer persistence failed and prior crontab could not be restored" >&2
    fi
    return 1
  fi
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

  local logfile="${GCT_STATE_ROOT}/adt-gc-launchd.log"
  _gct_reject_unsafe_path "$GCT_STATE_ROOT" "ADT_STATE_ROOT"
  _gct_reject_unsafe_path "$logfile" "GC log path (ADT_STATE_ROOT)"
  local bash_bin
  bash_bin="$(command -v bash)"
  _gct_reject_unsafe_xml_value "$GCT_STATE_ROOT" "ADT_STATE_ROOT"
  _gct_reject_unsafe_xml_value "$logfile" "GC log path (ADT_STATE_ROOT)"
  _gct_reject_unsafe_xml_value "$bash_bin" "bash path"
  _gct_reject_unsafe_xml_value "$ADT_GC_SH" "adt-gc.sh path"
  if ! mkdir -p "$GCT_STATE_ROOT" 2>/dev/null; then
    echo "install-gc-timer.sh: cannot create ADT_STATE_ROOT: ${GCT_STATE_ROOT}" >&2
    return 1
  fi
  local plist_tmp plist_backup="" had_plist=false
  plist_tmp="$(mktemp "${LAUNCHD_PLIST}.tmp.XXXXXX" 2>/dev/null)" || {
    echo "install-gc-timer.sh: cannot create temporary launchd plist" >&2
    return 1
  }
  if ! cat > "$plist_tmp" <<PLIST
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
  <key>EnvironmentVariables</key>
  <dict>
    <key>ADT_STATE_ROOT</key>
    <string>${GCT_STATE_ROOT}</string>
  </dict>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>StandardOutPath</key>
  <string>${logfile}</string>
  <key>StandardErrorPath</key>
  <string>${logfile}</string>
</dict>
</plist>
PLIST
  then
    rm -f "$plist_tmp" 2>/dev/null || true  # The write failure below is primary; scratch cleanup is best-effort.
    echo "install-gc-timer.sh: cannot write temporary launchd plist" >&2
    return 1
  fi

  if [[ -e "$LAUNCHD_PLIST" || -L "$LAUNCHD_PLIST" ]]; then
    if [[ ! -f "$LAUNCHD_PLIST" || -L "$LAUNCHD_PLIST" ]]; then
      rm -f "$plist_tmp" 2>/dev/null || true  # Refusal is reported below; scratch cleanup cannot make it safer.
      echo "install-gc-timer.sh: existing launchd plist is not a regular file: ${LAUNCHD_PLIST}" >&2
      return 1
    fi
    plist_backup="$(mktemp "${LAUNCHD_PLIST}.backup.XXXXXX" 2>/dev/null)" || {
      rm -f "$plist_tmp" 2>/dev/null || true  # The backup creation failure below is primary.
      echo "install-gc-timer.sh: cannot back up existing launchd plist" >&2
      return 1
    }
    if ! cp -p "$LAUNCHD_PLIST" "$plist_backup"; then
      rm -f "$plist_tmp" "$plist_backup" 2>/dev/null || true  # The backup copy failure below is primary.
      echo "install-gc-timer.sh: cannot back up existing launchd plist" >&2
      return 1
    fi
    had_plist=true
  fi
  if ! mv -f "$plist_tmp" "$LAUNCHD_PLIST"; then
    rm -f "$plist_tmp" "$plist_backup" 2>/dev/null || true  # The plist publication failure below is primary.
    echo "install-gc-timer.sh: cannot install launchd plist: ${LAUNCHD_PLIST}" >&2
    return 1
  fi

  # bootout-then-bootstrap makes re-run idempotent (a plain re-bootstrap
  # over an already-loaded label is a no-op-with-warning on some macOS
  # versions; bootout first guarantees the fresh plist actually takes).
  launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null; then
    if ! _gct_persist_state_root; then
      if ! _gct_restore_macos_install "$had_plist" "$plist_backup"; then
        echo "install-gc-timer.sh: ERROR: root-pointer persistence failed and prior launchd installation could not be fully restored" >&2
      fi
      return 1
    fi
    rm -f "$plist_backup" 2>/dev/null || true  # Installation already committed; stale backup cleanup is best-effort.
    echo "install-gc-timer.sh: installed/updated launchd GC agent (every 600s): ${ADT_GC_SH}"
  else
    if ! _gct_restore_macos_install "$had_plist" "$plist_backup"; then
      echo "install-gc-timer.sh: ERROR: launchctl bootstrap failed and prior launchd installation could not be fully restored" >&2
    else
      echo "install-gc-timer.sh: WARN: launchctl bootstrap failed; prior launchd installation restored" >&2
    fi
    return 1
  fi
}

case "$(_gct_uname)" in
  Darwin) _gct_install_macos ;;
  Linux)  _gct_install_linux ;;
  *)
    echo "install-gc-timer.sh: unsupported or unknown platform" >&2
    exit 1
    ;;
esac
