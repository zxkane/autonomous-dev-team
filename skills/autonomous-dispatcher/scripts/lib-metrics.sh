#!/bin/bash
# lib-metrics.sh — INV-67 observe-only metrics emitter for the autonomous
# pipeline (issue #228).
#
# This is the redesign's measurement substrate: the stop-rule, the obsolescence
# checkpoint, and the per-CLI value-accounting all read from the JSONL event log
# this lib appends to. It is SOURCED into the dev/review wrappers and the
# dispatcher; it is NOT executed standalone (no `set -e` at top — that would
# leak into the caller's shell).
#
# Contract (INV-67): emission is **observe-only — silent-to-pipeline,
# loud-to-report**. Every `metrics_emit` call swallows all internal errors and
# returns 0, so a metrics write failure (unwritable dir, missing jq, full disk)
# can NEVER change a wrapper/dispatcher exit code, label transition, or verdict.
# Call sites still append `|| true` as belt-and-suspenders, but the guarantee
# lives here: this function does not propagate failure.
#
# JSON is built EXCLUSIVELY with `jq -nc` (never hand-rolled echo) so values
# containing quotes / newlines / `$()` / `;` are stored literally and the line
# stays valid JSON. Records are appended with `>>` (O_APPEND) — atomic for the
# small single-line records we write, so no lock is needed (one writer per
# wrapper run).
#
# Public API:
#   metrics_dir                       — echoes the per-project metrics dir path
#   metrics_emit <event> [k=v ...]    — append one JSON event line (best-effort)
#   metrics_prune [days] [file]       — drop lines older than N days (default 90)
#
# Schema: every line carries a `schema_version` (currently 1) so later redesign
# phases can extend the schema without breaking the aggregator.

# Source lib-config.sh for pid_dir_for_project when the caller hasn't already
# (the wrappers source lib-agent.sh which sources lib-config.sh, so in-wrapper
# this is a no-op; the standalone report tool relies on this).
if ! declare -F pid_dir_for_project >/dev/null 2>&1; then
  _LIB_METRICS_SELF="${BASH_SOURCE[0]:-$0}"
  _LIB_METRICS_REAL_DIR="$(cd "$(dirname "$(readlink -f "$_LIB_METRICS_SELF")")" && pwd)"
  # shellcheck source=lib-config.sh
  source "${_LIB_METRICS_REAL_DIR}/lib-config.sh" 2>/dev/null || true
fi

# The schema version stamped on every emitted event. Bump only when a field's
# meaning changes incompatibly; additive fields do not require a bump (the
# aggregator ignores unknown fields).
METRICS_SCHEMA_VERSION="${METRICS_SCHEMA_VERSION:-1}"

# Default retention window for metrics_prune, in days.
METRICS_RETENTION_DAYS="${METRICS_RETENTION_DAYS:-90}"

# metrics_dir [project_id]
#
# Echoes the directory that holds metrics.jsonl for the project, resolving in
# priority order:
#   1. ${AUTONOMOUS_METRICS_DIR}                  — test/override hook
#   2. ${XDG_STATE_HOME}/autonomous-<project>     — issue #228's stated convention
#   3. pid_dir_for_project()                       — co-locate with issue-N.pid
#      (XDG_RUNTIME_DIR → ${HOME}/.local/state fallback), the dominant
#      SSM-spawned-shell case where XDG_STATE_HOME is unset.
#
# Returns 0 and echoes the path on success; returns 1 (echoes nothing) if no
# path can be resolved (e.g. PROJECT_ID unset and no override). Creates the dir
# (mode 0700) when it has to fall through to XDG_STATE_HOME; the
# pid_dir_for_project path already mkdir/chmods itself.
# shellcheck disable=SC2120  # callable with or without an explicit project arg
metrics_dir() {
  local project_id="${1:-${PROJECT_ID:-}}"
  local dir

  if [[ -n "${AUTONOMOUS_METRICS_DIR:-}" ]]; then
    dir="${AUTONOMOUS_METRICS_DIR}"
  elif [[ -n "${XDG_STATE_HOME:-}" && -n "$project_id" ]]; then
    dir="${XDG_STATE_HOME}/autonomous-${project_id}"
  elif declare -F pid_dir_for_project >/dev/null 2>&1 && [[ -n "$project_id" ]]; then
    # pid_dir_for_project reads PROJECT_ID from the env; honor an explicit arg.
    PROJECT_ID="$project_id" dir="$(pid_dir_for_project 2>/dev/null)" || return 1
    [[ -n "$dir" ]] || return 1
    printf '%s\n' "$dir"
    return 0
  else
    return 1
  fi

  # AUTONOMOUS_METRICS_DIR / XDG_STATE_HOME branches: ensure the dir exists.
  # Refuse a symlinked path (CWE-59 defense in depth, mirrors pid_dir_for_project).
  if [[ -L "$dir" ]]; then
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

# metrics_emit <event-type> [key=value ...]
#
# Append a single JSON event line to <metrics_dir>/metrics.jsonl. Best-effort:
# ALWAYS returns 0, swallows every internal error (INV-67). Values are passed to
# jq via --arg (string) so any character is safe; keys named `issue`,
# `retry_count`, `rc`, `duration_s`, `input_tokens`, `output_tokens`,
# `total_tokens` that look like integers are coerced to JSON numbers.
#
# The envelope fields schema_version / ts / event / project are filled
# automatically (event = arg 1, project = PROJECT_ID). Everything else —
# including `issue` — comes from explicit `key=value` args; callers pass
# `issue=${ISSUE_NUMBER}` so the report can join on it (it is NOT auto-filled).
metrics_emit() {
  local event="${1:-}"
  [[ -n "$event" ]] || return 0
  shift

  # jq is mandatory for safe construction; absence is a silent no-op (INV-67).
  command -v jq >/dev/null 2>&1 || return 0

  local dir file
  dir="$(metrics_dir 2>/dev/null)" || return 0
  [[ -n "$dir" ]] || return 0
  file="${dir}/metrics.jsonl"

  # Numeric keys are coerced to JSON numbers; everything else stays a string.
  # Space-padded so a substring test matches whole tokens only.
  local num_keys=" issue retry_count rc duration_s input_tokens output_tokens total_tokens "

  # Build the jq --arg / --argjson argument list and the object body.
  local -a jq_args=(-nc
    --argjson sv "$METRICS_SCHEMA_VERSION"
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    --arg ev "$event"
    --arg proj "${PROJECT_ID:-}")
  # $sv/$ts/$ev/$proj are jq variables (not shell) — single quotes are correct.
  # shellcheck disable=SC2016
  local body='{schema_version:$sv, ts:$ts, event:$ev, project:$proj}'

  local pair key val jqkey
  local i=0
  for pair in "$@"; do
    # Split on the FIRST '=' only, so values may contain '='.
    key="${pair%%=*}"
    val="${pair#*=}"
    # Skip malformed pairs (no '=' or empty key) silently.
    [[ "$pair" == *"="* && -n "$key" ]] || continue
    jqkey="k${i}"; i=$((i + 1))

    if [[ "$num_keys" == *" $key "* && "$val" =~ ^-?[0-9]+$ ]]; then
      jq_args+=(--argjson "$jqkey" "$val")
    else
      jq_args+=(--arg "$jqkey" "$val")
    fi
    # Quote the key name so dotted/hyphenated keys stay literal.
    body+=" + {\"${key}\": \$${jqkey}}"
  done

  # Construct the line; on ANY jq failure, emit nothing (don't append a partial).
  local line
  line="$(jq "${jq_args[@]}" "$body" 2>/dev/null)" || return 0
  [[ -n "$line" ]] || return 0

  # O_APPEND single-line write. Failure (unwritable dir) is swallowed.
  printf '%s\n' "$line" >> "$file" 2>/dev/null || return 0
  return 0
}

# metrics_map_drop_reason <agent-verdict-state> [cli-reason-token]
#
# Map a review fan-out agent's terminal state + optional per-CLI reason token
# onto the INV-67 failure-class taxonomy. Pure function (echoes the class).
#
#   verdict state `timed-out`               → agent-unavailable:transient
#   verdict state `unavailable` + token:
#     quota-exhausted                        → agent-unavailable:quota
#     auth-failed                            → agent-unavailable:auth
#     config-error                           → agent-unavailable:config
#     stream-error / (empty) / anything else → agent-unavailable:transient
#
# Always returns 0.
metrics_map_drop_reason() {
  local state="${1:-}" token="${2:-}"
  case "$state" in
    timed-out) printf 'agent-unavailable:transient\n'; return 0 ;;
  esac
  case "$token" in
    quota-exhausted) printf 'agent-unavailable:quota\n' ;;
    auth-failed)     printf 'agent-unavailable:auth\n' ;;
    config-error)    printf 'agent-unavailable:config\n' ;;
    *)               printf 'agent-unavailable:transient\n' ;;
  esac
  return 0
}

# metrics_parse_tokens <log-file>
#
# Best-effort extraction of token usage from an agent log, supporting the two
# formats the pipeline's CLIs emit:
#   - claude `--output-format json`: a JSON object (possibly among other lines)
#     with a top-level `usage` block carrying input_tokens / output_tokens.
#   - codex: a plain line `tokens used: <N>` (total only).
#
# Echoes `input=<i> output=<o> total=<t>` for any field it could determine
# (omitting fields it couldn't), suitable for splicing into a metrics_emit
# token_usage call. Echoes nothing when the log has no recognizable usage.
# ALWAYS returns 0 (observe-only).
metrics_parse_tokens() {
  local log="${1:-}"
  [[ -n "$log" && -r "$log" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local input="" output="" total=""

  # claude JSON: scan each line for a parseable object with a .usage block.
  # The log may interleave non-JSON; `-R` + try/catch tolerates that.
  local usage
  usage="$(jq -R -r '
        (try fromjson catch null) as $o
        | select($o != null and ($o.usage != null))
        | "\($o.usage.input_tokens // "")\t\($o.usage.output_tokens // "")"
      ' "$log" 2>/dev/null | tail -1)"
  if [[ -n "$usage" ]]; then
    input="${usage%%$'\t'*}"
    output="${usage##*$'\t'}"
    if [[ "$input" =~ ^[0-9]+$ && "$output" =~ ^[0-9]+$ ]]; then
      total=$((input + output))
    fi
  fi

  # codex fallback: `tokens used: N` (case-insensitive). Only if we have no
  # claude-style total yet.
  if [[ -z "$total" ]]; then
    local cx
    cx="$(grep -ioE 'tokens used:[[:space:]]*[0-9]+' "$log" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"
    [[ "$cx" =~ ^[0-9]+$ ]] && total="$cx"
  fi

  local out=""
  [[ "$input" =~ ^[0-9]+$ ]]  && out+="input=${input} "
  [[ "$output" =~ ^[0-9]+$ ]] && out+="output=${output} "
  [[ "$total" =~ ^[0-9]+$ ]]  && out+="total=${total}"
  out="${out% }"
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# metrics_prune [days] [file]
#
# Remove lines whose `ts` is older than <days> (default METRICS_RETENTION_DAYS)
# from the metrics file (default <metrics_dir>/metrics.jsonl). Lines that cannot
# be dated (malformed JSON, missing ts) are DROPPED — they can't be retained on
# an age basis and keeping un-parseable cruft defeats the point. Atomic: writes
# a temp file then renames. Best-effort: returns 0 on a missing/empty file or
# any failure, leaving the original untouched on error.
metrics_prune() {
  local days="${1:-$METRICS_RETENTION_DAYS}"
  local file="${2:-}"

  if [[ -z "$file" ]]; then
    local dir
    dir="$(metrics_dir 2>/dev/null)" || return 0
    [[ -n "$dir" ]] || return 0
    file="${dir}/metrics.jsonl"
  fi
  [[ -s "$file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # Cutoff as a Unix epoch; anything with ts < cutoff is dropped.
  local cutoff
  cutoff="$(date -u -d "${days} days ago" +%s 2>/dev/null)" || return 0
  [[ -n "$cutoff" ]] || return 0

  local tmp
  tmp="$(mktemp "${file}.prune.XXXXXX" 2>/dev/null)" || return 0

  # jq reads each line raw (`-R`); -r echoes the surviving line verbatim (NOT
  # re-encoded as a JSON string). Non-parseable lines and lines whose ts is
  # older than cutoff are dropped. `fromdateiso8601` converts the ts to epoch.
  if jq -R -r '
        . as $raw
        | (try (fromjson) catch null) as $o
        | select($o != null)
        | select(($o.ts // "") != "")
        | ((try ($o.ts | fromdateiso8601) catch null)) as $epoch
        | select($epoch != null and $epoch >= '"$cutoff"')
        | $raw
      ' "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}
