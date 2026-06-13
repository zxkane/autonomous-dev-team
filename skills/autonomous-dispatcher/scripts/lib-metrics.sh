#!/bin/bash
# lib-metrics.sh — INV-70 observe-only metrics emitter for the autonomous
# pipeline (issue #228).
#
# This is the redesign's measurement substrate: the stop-rule, the obsolescence
# checkpoint, and the per-CLI value-accounting all read from the JSONL event log
# this lib appends to. It is SOURCED into the dev/review wrappers and the
# dispatcher; it is NOT executed standalone (no `set -e` at top — that would
# leak into the caller's shell).
#
# Contract (INV-70): emission is **observe-only — silent-to-pipeline,
# loud-to-report**. Every `metrics_emit` call swallows all internal errors and
# returns 0, so a metrics write failure (unwritable dir, missing jq, full disk)
# can NEVER change a wrapper/dispatcher exit code, label transition, or verdict.
# Call sites still append `|| true` as belt-and-suspenders, but the guarantee
# lives here: this function does not propagate failure.
#
# JSON is built EXCLUSIVELY with `jq -nc` (never hand-rolled echo) so values
# containing quotes / newlines / `$()` / `;` are stored literally and the line
# stays valid JSON. Records are appended with `>>` (O_APPEND) — atomic for the
# small single-line records we write. A best-effort per-file `flock`
# (`<metrics.jsonl>.lock`) additionally serializes metrics_emit's append against
# metrics_prune's read→rewrite→mv so a concurrent emit can't be dropped by a
# prune in flight (#228 review); flock-absent falls back to an unlocked append.
#
# Public API:
#   metrics_dir                       — echoes the per-project metrics dir path
#   metrics_emit <event> [k=v ...]    — append one JSON event line (best-effort)
#   metrics_prune [days] [file]       — drop lines older than N days (default 90)
#
# Schema: every line carries a `schema_version` (currently 1) so later redesign
# phases can extend the schema without breaking the aggregator.
#
# This lib is fully self-contained: metrics_dir resolves the storage path from
# ${XDG_STATE_HOME:-$HOME/.local/state} directly (no lib-config / pid_dir
# dependency), so the standalone metrics-report.sh can source ONLY this file.

# The schema version stamped on every emitted event. Bump only when a field's
# meaning changes incompatibly; additive fields do not require a bump (the
# aggregator ignores unknown fields).
METRICS_SCHEMA_VERSION="${METRICS_SCHEMA_VERSION:-1}"

# Default retention window for metrics_prune, in days.
METRICS_RETENTION_DAYS="${METRICS_RETENTION_DAYS:-90}"

# metrics_dir [project_id]
#
# Echoes the directory that holds metrics.jsonl for the project, resolving in
# priority order — the issue's `${XDG_STATE_HOME:-$HOME/.local/state}` contract:
#   1. ${AUTONOMOUS_METRICS_DIR}                   — test/override hook
#   2. ${XDG_STATE_HOME}/autonomous-<project>      — when XDG_STATE_HOME is set
#   3. ${HOME}/.local/state/autonomous-<project>   — DURABLE fallback
#
# NOTE the fallback resolves DIRECTLY to ${HOME}/.local/state and deliberately
# does NOT defer to pid_dir_for_project: that helper prefers ${XDG_RUNTIME_DIR}
# (a tmpfs under /run/user/<uid> wiped on logout/reboot), which would silently
# put the metrics log — whose whole point is durable retention + later reporting
# — in a volatile directory. On the production SSM box XDG_RUNTIME_DIR IS set,
# so the old pid_dir deferral lost metrics across reboots (#228 review finding 2).
# Metrics need durability over co-location; PID files need the opposite, so they
# correctly resolve differently.
#
# Returns 0 and echoes the path on success; returns 1 (echoes nothing) if no
# path can be resolved (PROJECT_ID unset and no override, or HOME unset). Creates
# the dir (mode 0700) and refuses a pre-existing symlink (CWE-59 defense, mirrors
# pid_dir_for_project).
# shellcheck disable=SC2120  # callable with or without an explicit project arg
metrics_dir() {
  local project_id="${1:-${PROJECT_ID:-}}"
  local dir

  if [[ -n "${AUTONOMOUS_METRICS_DIR:-}" ]]; then
    dir="${AUTONOMOUS_METRICS_DIR}"
  elif [[ -z "$project_id" ]]; then
    return 1
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    dir="${XDG_STATE_HOME}/autonomous-${project_id}"
  elif [[ -n "${HOME:-}" ]]; then
    dir="${HOME}/.local/state/autonomous-${project_id}"
  else
    return 1
  fi

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
# ALWAYS returns 0, swallows every internal error (INV-70). Values are passed to
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

  # jq is mandatory for safe construction; absence is a silent no-op (INV-70).
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

  # O_APPEND single-line write, serialized against metrics_prune via a shared
  # per-file lock (#228 review: prune's read→temp→mv could otherwise drop a line
  # appended concurrently). The lock is BEST-EFFORT — if flock is unavailable the
  # append still happens (only the prune-vs-append window is unprotected, and
  # prune is itself best-effort). The write failure (unwritable dir) is swallowed
  # (INV-70 observe-only).
  _metrics_locked_append "$file" "$line" || return 0
  return 0
}

# _metrics_locked_append <metrics-file> <line>
#
# Append "<line>\n" to <metrics-file> while holding an exclusive flock on
# `<metrics-file>.lock`, so it serializes against metrics_prune's read+rewrite
# (#228 review). BEST-EFFORT: if flock is absent the append runs unlocked (the
# pre-review behavior — never worse). The append + flock both happen inside one
# subshell so the lock covers the actual write and is released on subshell exit.
# ALWAYS returns 0 on a swallowed write failure; callers also `|| return 0`.
_metrics_locked_append() {
  local file="$1" line="$2"
  if command -v flock >/dev/null 2>&1; then
    ( exec 9>"${file}.lock" 2>/dev/null || exit 0
      # `flock -w` bounds the wait so a stuck holder can never hang a wrapper.
      flock -w 5 9 2>/dev/null || true
      printf '%s\n' "$line" >> "$file" 2>/dev/null || true ) 2>/dev/null
    return 0
  fi
  printf '%s\n' "$line" >> "$file" 2>/dev/null || true
  return 0
}

# _metrics_prune_locked <metrics-file> <prune-fn...>
#
# Run the prune read+rewrite (<prune-fn...>) while holding the same per-file lock
# as _metrics_locked_append, so a concurrent emit cannot append between prune's
# read and its `mv` (which would drop the appended line). BEST-EFFORT: unlocked
# fallback when flock is absent. Returns 0 on the locked path (the subshell's rc
# is intentionally not propagated — the lone caller, metrics_prune, returns 0
# regardless, and the prune-fn itself always returns 0); the unlocked fallback
# returns the prune-fn's rc directly.
_metrics_prune_locked() {
  local file="$1"; shift
  if command -v flock >/dev/null 2>&1; then
    ( exec 9>"${file}.lock" 2>/dev/null || exit 0
      flock -w 5 9 2>/dev/null || true
      "$@" )
    return 0
  fi
  "$@"
}

# metrics_map_drop_reason <agent-verdict-state> [cli-reason-token]
#
# Map a review fan-out agent's terminal state + optional per-CLI reason token
# onto the INV-70 failure-class taxonomy. Pure function (echoes the class).
#
#   verdict state `timed-out`               → agent-unavailable:transient
#   verdict state `unavailable` + reason:
#     quota-exhausted*                       → agent-unavailable:quota
#     auth-failed*                           → agent-unavailable:auth
#     config-error*                          → agent-unavailable:config
#     stream-error / (empty) / anything else → agent-unavailable:transient
#
# PREFIX-matched, NOT exact: the reason can arrive as the bare token
# (`quota-exhausted`), a suffixed token (`quota-exhausted:Resets in 2h`, the
# INV-58 reset-window form), OR a rendered phrase (`quota-exhausted (Antigravity
# 429: …)` from _smoke_evidence_reason / the *_drop_reason_phrase helpers). All
# of these LEAD with the canonical token, so anchoring the match to the start
# (`quota-exhausted*`) classifies every form correctly — an exact `case` dropped
# the suffixed/phrase forms to `transient`, deflating the quota/auth rate
# (#228 round-6 review: smoke-drop phrase + the latent post-fan-out reset-window
# token). Always returns 0.
metrics_map_drop_reason() {
  local state="${1:-}" token="${2:-}"
  case "$state" in
    timed-out) printf 'agent-unavailable:transient\n'; return 0 ;;
  esac
  case "$token" in
    quota-exhausted*) printf 'agent-unavailable:quota\n' ;;
    auth-failed*)     printf 'agent-unavailable:auth\n' ;;
    config-error*)    printf 'agent-unavailable:config\n' ;;
    *)                printf 'agent-unavailable:transient\n' ;;
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
# Echoes `input_tokens=<i> output_tokens=<o> total_tokens=<t>` for any field it
# could determine (omitting fields it couldn't), suitable for splicing DIRECTLY
# into a metrics_emit token_usage call — the key names MUST match the schema the
# aggregator reads (`*_tokens`) or the cost-per-merged-PR join silently drops
# every run (#228 review finding 1). Echoes nothing when the log has no
# recognizable usage. ALWAYS returns 0 (observe-only).
#
# Optional arg 2 <byte-offset>: scan ONLY the bytes appended after this offset.
# The dev wrapper shares one append-only log across every dev/resume attempt for
# an issue (dispatch-local.sh), so without an offset a later run with no token
# line would re-read the PRIOR run's record and emit a duplicate token_usage
# (#228 review finding 2). The wrapper captures the log's byte-size at start and
# passes it here so only the CURRENT run's appended output is parsed. Omitted /
# 0 / past-EOF → scan the whole file (correct for a first run / fresh log).
metrics_parse_tokens() {
  local log="${1:-}"
  local offset="${2:-0}"
  [[ -n "$log" && -r "$log" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0

  # Slice the post-offset tail into a temp when an offset is given; otherwise scan
  # the file directly. `tail -c +N` is 1-indexed, so +$((offset+1)) starts just
  # after the offset-th byte. A best-effort temp; on any failure fall back to the
  # whole file (never worse than the pre-offset behavior).
  local scan="$log" _tmp=""
  if [[ "$offset" -gt 0 ]]; then
    _tmp="$(mktemp 2>/dev/null)" || _tmp=""
    if [[ -n "$_tmp" ]] && tail -c "+$((offset + 1))" "$log" > "$_tmp" 2>/dev/null; then
      scan="$_tmp"
    fi
  fi

  local input="" output="" total=""

  # claude JSON: scan each line for a parseable object with a .usage block.
  # The log may interleave non-JSON; `-R` + try/catch tolerates that.
  local usage
  usage="$(jq -R -r '
        (try fromjson catch null) as $o
        | select($o != null and ($o.usage != null))
        | "\($o.usage.input_tokens // "")\t\($o.usage.output_tokens // "")"
      ' "$scan" 2>/dev/null | tail -1)"
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
    cx="$(grep -ioE 'tokens used:[[:space:]]*[0-9]+' "$scan" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"
    [[ "$cx" =~ ^[0-9]+$ ]] && total="$cx"
  fi
  [[ -n "$_tmp" ]] && rm -f "$_tmp" 2>/dev/null

  # Key names MUST be the schema's `*_tokens` (NOT bare input/output/total) so the
  # words splice straight into metrics_emit and the aggregator's `.total_tokens`
  # read matches — see the function header (#228 finding 1).
  local out=""
  [[ "$input" =~ ^[0-9]+$ ]]  && out+="input_tokens=${input} "
  [[ "$output" =~ ^[0-9]+$ ]] && out+="output_tokens=${output} "
  [[ "$total" =~ ^[0-9]+$ ]]  && out+="total_tokens=${total}"
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

  # Run the read+rewrite under the shared per-file lock so a concurrent
  # metrics_emit append can't land between the read and the `mv` and be dropped
  # (#228 review). _metrics_prune_lines does the actual work; _metrics_prune_locked
  # holds the lock around it (best-effort — unlocked fallback when flock absent).
  _metrics_prune_locked "$file" _metrics_prune_lines "$file" "$cutoff"
  return 0
}

# _metrics_prune_lines <file> <cutoff-epoch>
#
# The prune read+rewrite, factored out so _metrics_prune_locked can wrap it under
# the lock. jq reads each line raw (`-R`); -r echoes the surviving line verbatim
# (NOT re-encoded as a JSON string). Non-parseable lines and lines whose ts is
# older than cutoff are dropped. `fromdateiso8601` converts the ts to epoch.
# Atomic temp-then-rename. Best-effort: leaves the original untouched on error.
_metrics_prune_lines() {
  local file="$1" cutoff="$2" tmp
  tmp="$(mktemp "${file}.prune.XXXXXX" 2>/dev/null)" || return 0
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
