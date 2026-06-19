#!/bin/bash
# lib-run-artifacts.sh — durable per-run artifact directory + run-id threading.
# Issue #235 / [INV-81].
#
# Gives every wrapper run a stable run-id and a durable directory that survives
# a /tmp wipe (reboot), so a GitHub comment's footer is a one-hop link to the
# raw evidence of the run that produced it. Replaces the 2am "spelunk three
# evaporating /tmp/agent-*.log files" story with "follow the footer → open one
# dir → run status.sh".
#
# OBSERVE-ONLY CONTRACT (mirrors lib-metrics.sh / INV-70): every public function
# is best-effort. A failure (unwritable dir, missing jq, missing PROJECT_ID)
# is a silent no-op that NEVER changes the wrapper's rc or its label
# transitions. Callers invoke these with `|| true` and never branch on rc.
#
# Public API:
#   mint_run_id <side> <issue>           — echo <project>-<issue>-<side>-<ts>
#   run_dir_for <run-id>                 — echo the per-run dir path
#   run_artifacts_init <side> <issue>    — mkdir 0700, write meta start marker,
#                                          seed run.log, prune; export RUN_ID/RUN_DIR
#   run_artifacts_finalize <dir> <rc>    — write end marker + rc + duration
#   run_artifacts_record_drop <dir> <agent> <reason>  — append a drop line
#   run_artifacts_persist_log <dir> <label> <src-log> — copy a /tmp per-agent log
#                                          into <dir>/agent-logs/<label>.log
#   run_footer                           — echo the run-id + artifacts footer block
#   run_prune [days] [issue]             — drop run dirs older than N days
#                                          (no issue ⇒ all issues for the project)
#
# Path scheme (coordinates with #233 / INV-78 — same `runs/` parent, distinct
# run-id namespace):
#   ${XDG_STATE_HOME:-$HOME/.local/state}/autonomous-<project>/runs/<run-id>/
# where <run-id> = <project>-<issue>-<dev|review>-<ts>. #233's per-AGENT verdict
# dirs are bare RFC-4122 UUIDs and live as SIBLINGS under the same runs/ parent;
# the wrapper-run-id glob never matches them, so the two namespaces don't collide.

# Schema version for meta.json — bumped only on incompatible field changes.
RUN_ARTIFACTS_SCHEMA_VERSION="${RUN_ARTIFACTS_SCHEMA_VERSION:-1}"

# _run_state_base — echo the durable state base dir for this project.
# Mirrors lib-metrics.sh::metrics_dir (XDG_STATE_HOME, NOT the volatile
# XDG_RUNTIME_DIR — run artifacts must survive a reboot, AC: durability).
# Echoes nothing + rc 1 when PROJECT_ID/HOME are both unresolvable.
_run_state_base() {
  local project_id="${1:-${PROJECT_ID:-}}"
  [[ -n "$project_id" ]] || return 1
  if [[ -n "${AUTONOMOUS_RUN_DIR_BASE:-}" ]]; then
    # Test/override hook — the explicit base already includes autonomous-<proj>.
    printf '%s\n' "${AUTONOMOUS_RUN_DIR_BASE}"
    return 0
  fi
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/autonomous-%s\n' "${XDG_STATE_HOME}" "$project_id"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s/.local/state/autonomous-%s\n' "${HOME}" "$project_id"
  else
    return 1
  fi
}

# _runs_parent — echo `<state-base>/runs` (the parent shared with #233).
_runs_parent() {
  local base
  base="$(_run_state_base "${1:-}")" || return 1
  printf '%s/runs\n' "$base"
}

# mint_run_id <side> <issue> — echo the run-id string.
# Honors a pre-set RUN_ID in the environment (lets the dispatcher / a test pin a
# deterministic value). side is normalized to dev|review; anything else is used
# verbatim (caller's responsibility). ts is UTC second resolution.
mint_run_id() {
  if [[ -n "${RUN_ID:-}" ]]; then
    printf '%s\n' "${RUN_ID}"
    return 0
  fi
  local side="$1" issue="$2"
  local project_id="${PROJECT_ID:-}"
  [[ -n "$project_id" && -n "$side" && -n "$issue" ]] || return 1
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)" || return 1
  printf '%s-%s-%s-%s\n' "$project_id" "$issue" "$side" "$ts"
}

# run_dir_for <run-id> [project] — echo the absolute per-run dir path.
run_dir_for() {
  local run_id="$1"
  [[ -n "$run_id" ]] || return 1
  local parent
  parent="$(_runs_parent "${2:-}")" || return 1
  printf '%s/%s\n' "$parent" "$run_id"
}

# _run_env_summary — echo a redacted one-object JSON of run env context.
# NEVER includes tokens / PEM / app ids — only operationally useful, non-secret
# fields. Best-effort: emits `{}` on jq absence.
_run_env_summary() {
  command -v jq >/dev/null 2>&1 || { printf '{}\n'; return 0; }
  jq -nc \
    --arg agent "${AGENT_CMD:-claude}" \
    --arg mode "${MODE:-}" \
    --arg gh_auth_mode "${GH_AUTH_MODE:-}" \
    --arg execution_backend "${EXECUTION_BACKEND:-local}" \
    --arg host "${HOSTNAME:-$(hostname 2>/dev/null || echo '')}" \
    '{agent:$agent, mode:$mode, gh_auth_mode:$gh_auth_mode, execution_backend:$execution_backend, host:$host}' \
    2>/dev/null || printf '{}\n'
}

# _write_run_meta <dir> — (re)write meta.json from the current RUN_* / context.
# Reads optional _RUN_ENDED_AT / _RUN_RC / _RUN_DURATION_S for the finalize pass.
_write_run_meta() {
  local dir="$1"
  command -v jq >/dev/null 2>&1 || return 1
  local env_summary
  env_summary="$(_run_env_summary)"
  local tmp="${dir}/meta.json.tmp.$$"
  # --argjson for the env summary (already valid JSON) and the numeric end
  # fields; everything else is a string --arg (injection-safe).
  if jq -nc \
      --argjson sv "$RUN_ARTIFACTS_SCHEMA_VERSION" \
      --arg run_id "${RUN_ID:-}" \
      --arg project "${PROJECT_ID:-}" \
      --arg issue "${_RUN_ISSUE:-}" \
      --arg side "${_RUN_SIDE:-}" \
      --arg started_at "${_RUN_STARTED_AT:-}" \
      --arg ended_at "${_RUN_ENDED_AT:-}" \
      --arg rc "${_RUN_RC:-}" \
      --arg duration_s "${_RUN_DURATION_S:-}" \
      --arg log_pointer "${LOG_FILE:-}" \
      --arg run_log "${dir}/run.log" \
      --argjson host_env "$env_summary" \
      '{schema_version:$sv, run_id:$run_id, project:$project, issue:$issue,
        side:$side, started_at:$started_at, log_pointer:$log_pointer,
        run_log:$run_log, host_env:$host_env}
       + (if $ended_at   != "" then {ended_at:$ended_at}                 else {} end)
       + (if $rc          != "" then {rc:($rc|tonumber? // $rc)}          else {} end)
       + (if $duration_s  != "" then {duration_s:($duration_s|tonumber? // $duration_s)} else {} end)' \
      > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "${dir}/meta.json" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# run_artifacts_init <side> <issue> — provision the run dir + start marker.
# Exports RUN_ID and RUN_DIR for sourced libs/adapters + the wrapper.
# Best-effort: any failure leaves RUN_DIR empty and returns non-zero, but the
# caller invokes with `|| true` so the wrapper proceeds either way.
run_artifacts_init() {
  local side="$1" issue="$2"
  local run_id dir
  run_id="$(mint_run_id "$side" "$issue")" || return 1
  RUN_ID="$run_id"
  dir="$(run_dir_for "$run_id")" || return 1

  # Disambiguate if the minted string already names an existing dir (same side
  # of the same issue dispatched twice within one UTC second). Guarantees a
  # unique directory even when mint_run_id collides. (TC-024)
  if [[ -e "$dir" ]]; then
    local n=2
    while [[ -e "${dir}-${n}" ]] && [[ "$n" -lt 100 ]]; do n=$((n + 1)); done
    run_id="${run_id}-${n}"
    RUN_ID="$run_id"
    dir="$(run_dir_for "$run_id")" || return 1
  fi

  # CWE-59: refuse a pre-existing symlink target (parent is 0700 so this should
  # never trigger, but cheap defense in depth — mirrors pid_dir_for_project).
  if [[ -L "$dir" ]]; then
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true

  RUN_DIR="$dir"
  export RUN_ID RUN_DIR
  _RUN_SIDE="$side"
  _RUN_ISSUE="$issue"
  _RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  # Unset the end-marker fields so a re-init never carries a stale rc.
  unset _RUN_ENDED_AT _RUN_RC _RUN_DURATION_S
  _RUN_START_EPOCH="$(date +%s 2>/dev/null || echo 0)"

  _write_run_meta "$dir" || true

  # Seed run.log with a first-line pointer so an operator who opens THIS file (or
  # the /tmp tail) is told the durable dir and the legacy /tmp log path. (TC-027)
  {
    printf 'run-dir: %s\n' "$dir"
    printf 'tmp-log: %s\n' "${LOG_FILE:-<none>}"
    printf 'run-id: %s · side: %s · issue: %s · started: %s\n' \
      "$run_id" "$side" "$issue" "${_RUN_STARTED_AT:-?}"
  } >> "${dir}/run.log" 2>/dev/null || true

  # Retention is built into init (best-effort, once per wrapper start) — mirrors
  # metrics_prune. Prune ALL issues' aged run dirs, NOT just this issue's: a run
  # for issue N must also reap 30+ day artifacts left by issues that never run
  # again, or the durable runs/ store grows unbounded (#235 review [P1]). The
  # active run-id is excluded by exact name inside run_prune, so it's never pruned.
  run_prune "${RUN_RETENTION_DAYS:-30}" || true
  return 0
}

# run_artifacts_finalize <dir> <rc> — write the end marker. Best-effort no-op if
# the dir was never created.
run_artifacts_finalize() {
  local dir="$1" rc="$2"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  _RUN_ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  _RUN_RC="$rc"
  local now
  now="$(date +%s 2>/dev/null || echo 0)"
  if [[ "${_RUN_START_EPOCH:-0}" -gt 0 && "$now" -ge "${_RUN_START_EPOCH:-0}" ]] 2>/dev/null; then
    _RUN_DURATION_S=$(( now - _RUN_START_EPOCH ))
  fi
  _write_run_meta "$dir" || true
  return 0
}

# run_artifacts_record_drop <dir> <agent> <reason> — append one drop line to
# drops.jsonl in the run dir (review side). Best-effort.
run_artifacts_record_drop() {
  local dir="$1" agent="$2" reason="$3"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local line
  line="$(jq -nc \
    --arg agent "$agent" --arg reason "$reason" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
    '{agent:$agent, reason:$reason, ts:$ts}' 2>/dev/null)" || return 0
  [[ -n "$line" ]] || return 0
  printf '%s\n' "$line" >> "${dir}/drops.jsonl" 2>/dev/null || true
  return 0
}

# run_artifacts_persist_log <dir> <label> <src-log> — copy a raw per-agent log
# (e.g. a review fan-out member's generic log, the codex stdout capture) from its
# volatile /tmp path into the DURABLE run dir under `agent-logs/<label>.log`, so
# the footer-linked run dir still holds the per-agent evidence (dropped agents,
# codex fallback verdicts, stream/auth failures) after a /tmp wipe or reboot
# (#235 review [P1]). Best-effort + observe-only: a missing src / unwritable dir /
# empty label is a silent no-op that never changes the wrapper's rc or labels.
# <label> is sanitized to [A-Za-z0-9._-] so a hostile agent name can't escape the
# agent-logs/ subdir (path-traversal defense).
run_artifacts_persist_log() {
  local dir="$1" label="$2" src="$3"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  [[ -n "$label" && -n "$src" && -f "$src" ]] || return 0
  # Strip any path separators / unexpected chars from the label.
  label="${label//[^A-Za-z0-9._-]/_}"
  [[ -n "$label" ]] || return 0
  local logdir="${dir}/agent-logs"
  mkdir -p "$logdir" 2>/dev/null || return 0
  [[ -L "$logdir" ]] && return 0   # CWE-59: never write through a symlinked dir
  cp -f "$src" "${logdir}/${label}.log" 2>/dev/null || true
  return 0
}

# run_footer — echo the comment footer block (a trailing `---` separator + the
# run-id + artifacts pointer). Echoes NOTHING when RUN_ID is unset, so a comment
# is never broken by a footer failure (observe-only). Never includes secrets.
run_footer() {
  [[ -n "${RUN_ID:-}" ]] || return 0
  printf '\n---\nrun-id: %s · artifacts: %s\n' "${RUN_ID}" "${RUN_DIR:-<none>}"
}

# run_prune [days] [issue] — remove wrapper-run-id dirs older than `days`
# (default 30). Only dirs matching the wrapper-run-id glob are candidates, so
# #233's bare-UUID per-agent dirs are never touched. The ACTIVE run-id (current
# $RUN_ID) is always excluded. Best-effort; always returns 0.
run_prune() {
  local days="${1:-30}" issue="${2:-}"
  [[ "$days" =~ ^[0-9]+$ ]] || days=30
  local parent
  parent="$(_runs_parent)" 2>/dev/null || return 0
  [[ -n "$parent" && -d "$parent" ]] || return 0

  local now cutoff
  now="$(date +%s 2>/dev/null || echo 0)"
  [[ "$now" -gt 0 ]] || return 0
  cutoff=$(( now - days * 86400 ))

  # Candidate glob: wrapper-run-id dirs only. When an issue is given, scope to
  # that issue's dev+review dirs; else all wrapper-run-id dirs for the project.
  local project_id="${PROJECT_ID:-}"
  local -a candidates=()
  local d
  if [[ -n "$issue" ]]; then
    for d in "$parent/${project_id}-${issue}-dev-"* "$parent/${project_id}-${issue}-review-"*; do
      [[ -d "$d" ]] && candidates+=("$d")
    done
  else
    for d in "$parent/${project_id}-"*-dev-* "$parent/${project_id}-"*-review-*; do
      [[ -d "$d" ]] && candidates+=("$d")
    done
  fi

  for d in "${candidates[@]}"; do
    # Never prune the active run dir (exact name match on RUN_ID). (TC-036)
    [[ -n "${RUN_ID:-}" && "$(basename "$d")" == "${RUN_ID}" ]] && continue
    [[ -L "$d" ]] && continue   # CWE-59: never follow/rm a symlinked candidate

    # Prefer meta.json.started_at; fall back to dir mtime.
    local started_epoch="" started_iso
    if [[ -f "$d/meta.json" ]] && command -v jq >/dev/null 2>&1; then
      started_iso="$(jq -r '.started_at // empty' "$d/meta.json" 2>/dev/null)" || started_iso=""
      if [[ -n "$started_iso" ]]; then
        started_epoch="$(date -u -d "$started_iso" +%s 2>/dev/null || echo '')"
      fi
    fi
    if [[ -z "$started_epoch" ]]; then
      started_epoch="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo '')"
    fi
    [[ "$started_epoch" =~ ^[0-9]+$ ]] || continue

    # Strictly older than the cutoff is pruned (age boundary: exactly-N-days is
    # retained). (TC-034/035)
    if [[ "$started_epoch" -lt "$cutoff" ]]; then
      rm -rf "$d" 2>/dev/null || true
    fi
  done
  return 0
}
