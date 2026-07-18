#!/bin/bash
# lib-accounting.sh — INV-139 crash-consistent token-accounting store
# (issue #505, parent #450).
#
# This is the AUTHORITATIVE resource-accounting store the token-budget
# admission gate (#506) and terminal-control helpers (#515) read. It is a
# deliberately SEPARATE library and storage directory from lib-metrics.sh:
# metrics_emit's swallow-all, best-effort, 90-day-pruned JSONL log stays
# exactly as-is (INV-70) — it is not durable enough to gate anything on.
# Production ingest and projection are centralized in lib-token-budget.sh.
# Metrics remains an independent observe-only mirror.
#
# Storage model (D2): one atomic JSON document per invocation, no cursors.
#   <accounting_dir>/<issue>/<invocation_id>.json   — one per invocation
#   <accounting_dir>/<issue>/.lock                   — mandatory per-issue flock
#   <accounting_dir>/<issue>/projection.json         — rebuildable cache
#   <accounting_dir>/<issue>/acks.jsonl              — append-only ack audit log
# `accounting_dir` resolves to `<state_dir>/accounting`, a SIBLING of
# `metrics.jsonl` under the same `<state_dir>/autonomous-<project>/` root — so
# metrics_prune (which only ever touches `<metrics_dir>/metrics.jsonl`) can
# never reach it.
#
# Locking is MANDATORY here, unlike lib-metrics.sh's best-effort flock: every
# mutating call and every query acquires an exclusive flock on
# `<issue>/.lock` and FAILS LOUDLY (rc 1) if flock is unavailable or the wait
# times out. The strict-idempotent-commit contract (D5) depends on it.
#
# Public API (D8 — pinned, exact signatures):
#   accounting_invocation_id RUN_ID SIDE MEMBER_ID ATTEMPT
#   accounting_start        ISSUE INVOCATION_ID SIDE RUN_ID MEMBER_ID ATTEMPT
#   accounting_commit_usage ISSUE INVOCATION_ID TOTAL [INPUT|-] [OUTPUT|-]
#   accounting_commit_unknown ISSUE INVOCATION_ID REASON
#   accounting_reconcile    ISSUE
#   accounting_ack_unknown  ISSUE INVOCATION_ID...
#   accounting_admission_query ISSUE
#
# Lifecycle (D4): started -> usage-committed | usage-unknown (terminal).
# `usage-unknown` is sticky ONLY via an explicit accounting_commit_unknown or
# a reconcile-proven death — never inferred from an issue closing.
# `unavailable` (lock/storage failure) and `corrupt` (malformed on-disk JSON)
# are QUERY OUTCOMES, never record states — they mutate nothing.
#
# Reconciliation proof-of-death (D6) reads the EXISTING INV-135 lease
# sidecars (`issue-<N>.run-id` / `issue-<N>.progress.json`'s `pid` field)
# directly — this lib duplicates lib-config.sh::pid_dir_for_project's
# resolution (`_accounting_pid_dir`) rather than depending on lib-config.sh
# being sourced first, mirroring lib-metrics.sh's own self-contained
# rationale. The INV-135 lease exists ONLY on the dev side (the review
# wrapper never exports AGENT_PROGRESS_FILE), so reconcile only ever
# evaluates `side=dev` records; `side=review` records have no evidence
# source in this issue's scope and simply stay `incomplete` (the safe
# default) until a future owner-aware review-side signal lands (#515).
#
# This file is SOURCED, never executed (no top-level `set -e` — that would
# leak into the caller's shell). Idempotent re-source is safe: every
# definition below is a plain function/variable-default redefinition.
# shellcheck shell=bash

ACCOUNTING_SCHEMA_VERSION="${ACCOUNTING_SCHEMA_VERSION:-1}"
ACCOUNTING_LOCK_WAIT_SECONDS="${ACCOUNTING_LOCK_WAIT_SECONDS:-5}"
ACCOUNTING_MAX_EXACT_TOKENS=9007199254740991

_accounting_valid_issue() {
  [[ "${1-}" =~ ^[1-9][0-9]*$ ]]
}

_accounting_valid_invocation_id() {
  [[ "${1-}" =~ ^inv-v1-[0-9a-f]{24}$ ]]
}

_accounting_valid_token_count() {
  local value="${1-}" max="$ACCOUNTING_MAX_EXACT_TOKENS"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  if (( ${#value} < ${#max} )); then
    return 0 # accounting-branch: B059
  fi
  (( ${#value} == ${#max} )) || return 1
  (( 10#$value <= max ))
}

_accounting_path_is_nonregular() {
  local path="${1-}"
  [[ -L "$path" ]] || { [[ -e "$path" ]] && [[ ! -f "$path" ]]; }
}

# accounting_dir [project_id] — echoes <state_dir>/accounting (a SIBLING of
# lib-metrics.sh's metrics dir; see header). Resolution priority mirrors
# metrics_dir exactly (durable — never defers to the volatile
# XDG_RUNTIME_DIR pid_dir_for_project prefers):
#   1. ${AUTONOMOUS_ACCOUNTING_DIR}                        — test/override hook
#   2. ${XDG_STATE_HOME}/autonomous-<project>/accounting   — when XDG_STATE_HOME is set
#   3. ${HOME}/.local/state/autonomous-<project>/accounting — durable fallback
# Creates the dir (mode 0700) and refuses a pre-existing symlink (CWE-59).
# shellcheck disable=SC2120
accounting_dir() {
  local project_id="${1:-${PROJECT_ID:-}}"
  local dir

  if [[ -n "${AUTONOMOUS_ACCOUNTING_DIR:-}" ]]; then
    dir="${AUTONOMOUS_ACCOUNTING_DIR}" # accounting-branch: B001
  elif [[ -z "$project_id" ]]; then
    return 1
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    dir="${XDG_STATE_HOME}/autonomous-${project_id}/accounting" # accounting-branch: B002
  elif [[ -n "${HOME:-}" ]]; then
    dir="${HOME}/.local/state/autonomous-${project_id}/accounting"
  else
    return 1
  fi

  if [[ -L "$dir" ]]; then
    return 1 # accounting-branch: B003
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  # A chmod failure (e.g. a foreign-owned pre-existing dir) leaves the dir at
  # whatever mode mkdir/umask gave it — never fatal, mirrors metrics_dir.
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

# _accounting_issue_dir <issue> — echoes <accounting_dir>/<issue>; creates it
# (mode 0700); refuses a pre-existing symlink.
_accounting_issue_dir() {
  local issue="$1" base dir
  [[ -n "$issue" ]] || return 1
  base="$(accounting_dir)" || return 1
  dir="${base}/${issue}"
  if [[ -L "$dir" ]]; then
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  # Same best-effort posture as accounting_dir above: a chmod failure here
  # never blocks callers from using the (looser-mode) directory.
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

# _accounting_pid_dir — mirrors lib-config.sh::pid_dir_for_project's
# resolution (AUTONOMOUS_PID_DIR -> XDG_RUNTIME_DIR -> HOME/.local/state) so
# this lib has no hard dependency on lib-config.sh being sourced first (same
# self-contained rationale as lib-metrics.sh::metrics_dir). Read-only: never
# creates the dir — a missing dir just means no INV-135 lease evidence
# exists, which is a valid (if unusual) condition, not an error to surface.
_accounting_pid_dir() {
  local project_id="${PROJECT_ID:-}"
  [[ -n "$project_id" ]] || return 1
  local dir
  if [[ -n "${AUTONOMOUS_PID_DIR:-}" ]]; then
    dir="${AUTONOMOUS_PID_DIR}"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR}" ]]; then
    dir="${XDG_RUNTIME_DIR}/autonomous-${project_id}"
  elif [[ -n "${HOME:-}" ]]; then
    dir="${HOME}/.local/state/autonomous-${project_id}"
  else
    return 1
  fi
  [[ -d "$dir" ]] || return 1
  printf '%s\n' "$dir"
}

# _accounting_sha256 <input> — echoes the lowercase hex sha256 digest of
# <input> (via stdin to the hasher, never argv — avoids leaking the input via
# `ps`). Mirrors lib-lane.sh::_wrapper_fingerprint's hasher-detection.
_accounting_sha256() {
  local input="$1" hasher
  if command -v sha256sum >/dev/null 2>&1; then
    hasher="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    hasher="shasum -a 256"
  else
    return 1
  fi
  printf '%s' "$input" | $hasher 2>/dev/null | awk '{print $1}'
}

# _accounting_lock <issue> <out_fd_nameref> — acquire an exclusive flock on
# <issue>/.lock. MANDATORY (unlike lib-metrics.sh's best-effort posture):
# returns 1 loudly — never degrades to unlocked — if flock is missing, the
# lock path is not a plain regular file (symlink/FIFO/device — CWE-59), or
# the wait times out. D5's strict-commit contract requires serialized access.
_accounting_lock() {
  local issue="$1"
  local -n _out_fd="$2"
  _out_fd=""
  local dir lock_file
  dir="$(_accounting_issue_dir "$issue")" || { echo "_accounting_lock: cannot resolve issue directory" >&2; return 1; }
  lock_file="${dir}/.lock"
  if _accounting_path_is_nonregular "$lock_file"; then
    echo "_accounting_lock: refusing non-regular lock path: $lock_file" >&2
    return 1
  fi
  command -v flock >/dev/null 2>&1 || { echo "_accounting_lock: flock is required" >&2; return 1; }
  local fd
  # No `2>/dev/null` here (unlike lib-agent.sh's best-effort
  # _agent_progress_lock_acquire): `exec {fd}>>...` has no command word, so
  # ANY redirect on it — including a stderr one — is applied to the CURRENT
  # SHELL PERMANENTLY, not scoped to this statement. Suppressing stderr here
  # would silently mute every diagnostic this function (and its mutating
  # callers) print for the rest of the process — the opposite of this lib's
  # "loud on failure" contract (D5). A failed open surfaces bash's own
  # diagnostic plus ours below; redundant, never silent.
  exec {fd}>>"$lock_file" || { echo "_accounting_lock: cannot open lock file: $lock_file" >&2; return 1; }
  if ! flock -w "$ACCOUNTING_LOCK_WAIT_SECONDS" "$fd" 2>/dev/null; then
    exec {fd}>&-
    echo "_accounting_lock: timed out waiting for the lock on issue ${issue}" >&2
    return 1 # accounting-branch: B005
  fi
  _out_fd="$fd" # accounting-branch: B004
  return 0
}

# _accounting_unlock <fd_nameref> — release a lock acquired by
# _accounting_lock. Safe to call even if locking never succeeded (no-op).
_accounting_unlock() {
  local -n _fd="$1"
  [[ -n "$_fd" ]] && exec {_fd}>&-
  _fd=""
}

# _accounting_carry_fields <existing_json> <created_at_nameref> <run_id_nameref>
#   <side_nameref> <member_id_nameref> <attempt_nameref>
#
# One jq pass to inherit a record's immutable envelope fields (shared by
# accounting_commit_usage and accounting_commit_unknown when they rewrite a
# non-terminal `started` record to terminal) — avoids five separate `jq -r`
# subprocess spawns per caller.
_accounting_carry_fields() {
  local existing="$1"
  local -n _created_at="$2" _run_id="$3" _side="$4" _member_id="$5" _attempt="$6"
  local tsv
  tsv="$(jq -r '[.created_at // "", .run_id // "", .side // "", .member_id // "", (.attempt // 0)] | @tsv' <<<"$existing")"
  IFS=$'\t' read -r _created_at _run_id _side _member_id _attempt <<<"$tsv"
}

_accounting_sync_file() {
  local file="$1"
  command -v sync >/dev/null 2>&1 || {
    echo "_accounting_sync_file: sync is required" >&2
    return 1
  }
  sync -d "$file" 2>/dev/null || {
    echo "_accounting_sync_file: cannot sync file data: $file" >&2
    return 1
  }
}

_accounting_sync_dir() {
  local dir="$1"
  command -v sync >/dev/null 2>&1 || {
    echo "_accounting_sync_dir: sync is required" >&2
    return 1
  }
  sync -f "$dir" 2>/dev/null || {
    echo "_accounting_sync_dir: cannot sync directory filesystem: $dir" >&2
    return 1
  }
}

_accounting_confirm_durable() {
  local file="$1" dir="$2"
  if ! _accounting_sync_file "$file" || ! _accounting_sync_dir "$dir"; then
    echo "_accounting_confirm_durable: cannot confirm durable record: $file" >&2
    return 1 # accounting-branch: B063
  fi
  return 0 # accounting-branch: B064
}

_accounting_now() {
  local now
  if ! now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || [[ -z "$now" ]]; then
    echo "_accounting_now: cannot acquire UTC timestamp" >&2
    return 1 # accounting-branch: B061
  fi
  printf '%s\n' "$now" # accounting-branch: B062
}

# _accounting_write_atomic <dir> <target_file> <content> — tmp file in the
# SAME directory + `mv -fT` (the INV-135 idiom), mode 0600. Refuses to replace
# any pre-existing target that is not a regular file.
_accounting_write_atomic() {
  local dir="$1" target="$2" content="$3" tmp
  if _accounting_path_is_nonregular "$target"; then
    echo "_accounting_write_atomic: refusing non-regular target: $target" >&2
    return 1 # accounting-branch: B007
  fi
  tmp="$(mktemp "${dir}/.acct.XXXXXX" 2>/dev/null)" || {
    echo "_accounting_write_atomic: cannot create temporary file in $dir" >&2
    return 1
  }
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    # Best-effort perms (mirrors lib-agent.sh's lease writers): a chmod
    # failure still leaves a valid (if looser-mode) file, never blocks the write.
    chmod 600 "$tmp" 2>/dev/null || true
    if ! _accounting_sync_file "$tmp"; then
      rm -f "$tmp" 2>/dev/null
      echo "_accounting_write_atomic: cannot sync temporary file in $dir" >&2
      return 1 # accounting-branch: B008
    fi
    if ! mv -fT "$tmp" "$target" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      echo "_accounting_write_atomic: cannot replace target: $target" >&2
      return 1 # accounting-branch: B009
    fi
    if ! _accounting_sync_dir "$dir"; then
      echo "_accounting_write_atomic: cannot sync parent directory: $dir" >&2
      return 1 # accounting-branch: B010
    fi
  else
    rm -f "$tmp" 2>/dev/null
    echo "_accounting_write_atomic: cannot write temporary file in $dir" >&2
    return 1
  fi
  return 0 # accounting-branch: B006
}

# _accounting_read_valid_record <record_file> <issue>
#
# Reads and validates the authoritative envelope before any record contributes
# to a query or terminal rewrite. Returns 2 for a storage read failure and 1
# for malformed/conflicting history so admission queries can preserve D4's
# unavailable-vs-corrupt distinction.
_accounting_read_valid_record() {
  local file="$1" issue="$2"
  [[ -f "$file" && ! -L "$file" ]] || return 1

  local raw record filename_id="${file##*/}"
  filename_id="${filename_id%.json}"
  if ! raw="$(cat "$file" 2>/dev/null)"; then
    return 2 # accounting-branch: B012
  fi
  if ! record="$(jq -ce \
    --argjson sv "$ACCOUNTING_SCHEMA_VERSION" \
    --argjson max_tokens "$ACCOUNTING_MAX_EXACT_TOKENS" \
    --argjson expected_issue "$issue" \
    --arg expected_id "$filename_id" '
      def token_count: type == "number" and . >= 0 and . <= $max_tokens and floor == .;
      def posint: type == "number" and . >= 1 and floor == .;
      if (type == "object"
      and .schema_version == $sv
      and .issue == $expected_issue
      and .invocation_id == $expected_id
      and ($expected_id | test("^inv-v1-[0-9a-f]{24}$"))
      and (.side == "dev" or .side == "review")
      and ((.run_id | type) == "string" and (.run_id | length) > 0)
      and ((.member_id | type) == "string" and (.member_id | length) > 0)
      and (if .side == "dev" then .member_id == "dev" else true end)
      and (.attempt | posint)
      and ((.state | type) == "string")
      and ((.created_at | type) == "string" and (.created_at | length) > 0)
      and ((.updated_at | type) == "string" and (.updated_at | length) > 0)
      and (
        if .state == "started" then
          true
        elif .state == "usage-committed" then
          (.total_tokens | token_count)
          and ((has("input_tokens") | not) or (.input_tokens | token_count))
          and ((has("output_tokens") | not) or (.output_tokens | token_count))
        elif .state == "usage-unknown" then
          ((.reason | type) == "string" and (.reason | length) > 0)
        else
          false
        end
      )
      ) then . else empty end
    ' <<<"$raw" 2>/dev/null)"; then
    return 1 # accounting-branch: B013
  fi

  local run_id side member_id attempt expected_id
  IFS=$'\t' read -r run_id side member_id attempt <<<"$(jq -r \
    '[.run_id, .side, .member_id, .attempt] | @tsv' <<<"$record")"
  if ! expected_id="$(accounting_invocation_id "$run_id" "$side" "$member_id" "$attempt" 2>/dev/null)" ||
    [[ "$expected_id" != "$filename_id" ]]; then
    return 1 # accounting-branch: B014
  fi
  printf '%s\n' "$record" # accounting-branch: B011
}

# accounting_invocation_id RUN_ID SIDE MEMBER_ID ATTEMPT (D3)
#
# Pure (no store I/O): echoes `inv-v1-<first-24-hex-of-sha256>` of the
# canonical JSON tuple {run_id, side, member_id, attempt}. Same tuple ->
# same id; any field differing -> a different id (sha256 collision
# resistance, not enumeration) — including two same-named review fan-out
# members distinguished only by their `_agent_session_id` member UUID, and a
# dev retry's incremented attempt.
accounting_invocation_id() {
  if (( $# != 4 )); then
    echo "accounting_invocation_id: expected RUN_ID SIDE MEMBER_ID ATTEMPT" >&2
    return 1 # accounting-branch: B015
  fi
  local run_id="${1-}" side="${2-}" member_id="${3-}" attempt="${4-}"
  command -v jq >/dev/null 2>&1 || { echo "accounting_invocation_id: jq is required" >&2; return 1; }
  [[ -n "$run_id" ]] || { echo "accounting_invocation_id: run_id is required" >&2; return 1; }
  [[ "$side" == "dev" || "$side" == "review" ]] || { echo "accounting_invocation_id: side must be dev or review" >&2; return 1; } # accounting-branch: B016
  [[ -n "$member_id" ]] || { echo "accounting_invocation_id: member_id is required" >&2; return 1; }
  if [[ "$side" == "dev" && "$member_id" != "dev" ]]; then
    echo "accounting_invocation_id: dev-side member_id must be literal dev" >&2
    return 1
  fi
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || { echo "accounting_invocation_id: attempt must be a positive integer (D3: a positive ordinal)" >&2; return 1; }

  local canonical digest
  canonical="$(jq -nc \
    --arg run_id "$run_id" --arg side "$side" --arg member_id "$member_id" --argjson attempt "$attempt" \
    '{run_id:$run_id, side:$side, member_id:$member_id, attempt:$attempt}')" || return 1

  digest="$(_accounting_sha256 "$canonical")" || { echo "accounting_invocation_id: no sha256 tool available" >&2; return 1; }
  [[ -n "$digest" ]] || return 1

  printf 'inv-v1-%s\n' "${digest:0:24}" # accounting-branch: B017
}

# accounting_start ISSUE INVOCATION_ID SIDE RUN_ID MEMBER_ID ATTEMPT (D8)
#
# Writes an initial `started` record. Idempotent: if a record for
# INVOCATION_ID already exists (in ANY state), this is a no-op success —
# never regresses a terminal record back to `started`.
accounting_start() {
  if (( $# != 6 )); then
    echo "accounting_start: expected ISSUE INVOCATION_ID SIDE RUN_ID MEMBER_ID ATTEMPT" >&2
    return 1 # accounting-branch: B018
  fi
  local issue="${1-}" invocation_id="${2-}" side="${3-}" run_id="${4-}" member_id="${5-}" attempt="${6-}"
  _accounting_valid_issue "$issue" || { echo "accounting_start: issue must be a positive integer" >&2; return 1; }
  _accounting_valid_invocation_id "$invocation_id" || { echo "accounting_start: invalid invocation_id" >&2; return 1; } # accounting-branch: B019
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || { echo "accounting_start: attempt must be a positive integer (D3: a positive ordinal)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_start: jq is required" >&2; return 1; }
  local expected_id
  if ! expected_id="$(accounting_invocation_id "$run_id" "$side" "$member_id" "$attempt")" ||
    [[ "$expected_id" != "$invocation_id" ]]; then
    echo "accounting_start: invocation_id does not match the canonical identity tuple" >&2
    return 1 # accounting-branch: B020
  fi

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_start: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  local file="${dir}/${invocation_id}.json"
  if [[ -e "$file" || -L "$file" ]]; then
    if _accounting_path_is_nonregular "$file"; then
      echo "accounting_start: refusing non-regular record target: $file" >&2
      _accounting_unlock _lock_fd
      return 1 # accounting-branch: B021
    fi
    local existing
    if ! existing="$(_accounting_read_valid_record "$file" "$issue")"; then
      echo "accounting_start: existing record for ${invocation_id} is corrupt" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    if ! _accounting_confirm_durable "$file" "$dir"; then
      echo "accounting_start: failed to confirm durable record for ${invocation_id}" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    _accounting_unlock _lock_fd
    return 0 # accounting-branch: B022
  fi

  local now record
  if ! now="$(_accounting_now)"; then
    _accounting_unlock _lock_fd
    return 1
  fi
  record="$(jq -nc \
    --argjson sv "$ACCOUNTING_SCHEMA_VERSION" --arg id "$invocation_id" --argjson issue "$issue" \
    --arg side "$side" --arg run_id "$run_id" --arg member_id "$member_id" --argjson attempt "$attempt" \
    --arg state "started" --arg created_at "$now" --arg updated_at "$now" \
    '{schema_version:$sv, invocation_id:$id, issue:$issue, side:$side, run_id:$run_id, member_id:$member_id,
      attempt:$attempt, state:$state, created_at:$created_at, updated_at:$updated_at}')"
  if [[ -z "$record" ]]; then
    _accounting_unlock _lock_fd
    return 1
  fi

  local rc=0
  if ! _accounting_write_atomic "$dir" "$file" "$record"; then
    echo "accounting_start: failed to persist ${invocation_id}" >&2
    rc=1
  else
    : # accounting-branch: B023
  fi
  _accounting_unlock _lock_fd
  return $rc
}

# accounting_commit_usage ISSUE INVOCATION_ID TOTAL [INPUT|-] [OUTPUT|-] (D5, D8)
#
# Strict idempotent commit. A valid started record is required. Existing
# terminal usage-committed record, IDENTICAL payload -> rc 0,
# no write. Existing terminal record, CONFLICTING payload -> rc 1, no
# mutation, loud stderr. Already usage-unknown -> rc 1 (terminal states
# never overwrite each other). Any write or sync failure -> rc 1; a replay
# re-syncs an already-installed identical terminal record before succeeding.
accounting_commit_usage() {
  if (( $# < 3 || $# > 5 )); then
    echo "accounting_commit_usage: expected ISSUE INVOCATION_ID TOTAL [INPUT|-] [OUTPUT|-]" >&2
    return 1 # accounting-branch: B024
  fi
  local issue="${1-}" invocation_id="${2-}" total="${3-}" input="${4:--}" output="${5:--}"
  _accounting_valid_issue "$issue" || { echo "accounting_commit_usage: issue must be a positive integer" >&2; return 1; }
  _accounting_valid_invocation_id "$invocation_id" || { echo "accounting_commit_usage: invalid invocation_id" >&2; return 1; }
  _accounting_valid_token_count "$total" ||
    { echo "accounting_commit_usage: total must be a canonical non-negative integer no greater than ${ACCOUNTING_MAX_EXACT_TOKENS}" >&2; return 1; } # accounting-branch: B025
  [[ "$input" == "-" ]] || _accounting_valid_token_count "$input" ||
    { echo "accounting_commit_usage: input must be - or a canonical non-negative integer no greater than ${ACCOUNTING_MAX_EXACT_TOKENS}" >&2; return 1; }
  [[ "$output" == "-" ]] || _accounting_valid_token_count "$output" ||
    { echo "accounting_commit_usage: output must be - or a canonical non-negative integer no greater than ${ACCOUNTING_MAX_EXACT_TOKENS}" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_commit_usage: jq is required" >&2; return 1; }

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_commit_usage: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  local file="${dir}/${invocation_id}.json"
  if _accounting_path_is_nonregular "$file"; then
    echo "accounting_commit_usage: refusing non-regular record target: $file" >&2
    _accounting_unlock _lock_fd
    return 1 # accounting-branch: B026
  fi
  if [[ ! -f "$file" ]]; then
    echo "accounting_commit_usage: no started record for ${invocation_id}" >&2
    _accounting_unlock _lock_fd
    return 1 # accounting-branch: B027
  fi

  local created_at="" run_id="" side="" member_id="" attempt="0"
  local existing existing_state
  if ! existing="$(_accounting_read_valid_record "$file" "$issue")"; then
    echo "accounting_commit_usage: existing record for ${invocation_id} is corrupt" >&2
    _accounting_unlock _lock_fd
    return 1 # accounting-branch: B028
  fi
  existing_state="$(jq -r '.state' <<<"$existing")"
  if [[ "$existing_state" == "usage-committed" ]]; then
    if ! _accounting_confirm_durable "$file" "$dir"; then
      echo "accounting_commit_usage: failed to confirm durable terminal record for ${invocation_id}" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    local ex_total ex_input ex_output
    IFS=$'\t' read -r ex_total ex_input ex_output <<<"$(jq -r \
      '[.total_tokens, (if has("input_tokens") then .input_tokens else "-" end),
        (if has("output_tokens") then .output_tokens else "-" end)] | @tsv' <<<"$existing")"
    if [[ "$ex_total" == "$total" && "$ex_input" == "$input" && "$ex_output" == "$output" ]]; then
      _accounting_unlock _lock_fd
      return 0 # accounting-branch: B029
    fi
    echo "accounting_commit_usage: conflicting duplicate commit for ${invocation_id} (existing total=${ex_total}, requested=${total})" >&2
    _accounting_unlock _lock_fd
    return 1 # accounting-branch: B030
  elif [[ "$existing_state" == "usage-unknown" ]]; then
    if ! _accounting_confirm_durable "$file" "$dir"; then
      echo "accounting_commit_usage: failed to confirm durable terminal record for ${invocation_id}" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    echo "accounting_commit_usage: ${invocation_id} is already terminal usage-unknown" >&2
    _accounting_unlock _lock_fd
    return 1 # accounting-branch: B031
  elif [[ "$existing_state" != "started" ]]; then
    echo "accounting_commit_usage: invalid prior state for ${invocation_id}: ${existing_state}" >&2
    _accounting_unlock _lock_fd
    return 1
  fi
  _accounting_carry_fields "$existing" created_at run_id side member_id attempt

  local now
  if ! now="$(_accounting_now)"; then
    _accounting_unlock _lock_fd
    return 1
  fi
  [[ -n "$created_at" ]] || created_at="$now"
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0

  local -a jq_args=(-nc
    --argjson sv "$ACCOUNTING_SCHEMA_VERSION" --arg id "$invocation_id" --argjson issue "$issue"
    --arg side "$side" --arg run_id "$run_id" --arg member_id "$member_id" --argjson attempt "$attempt"
    --arg state "usage-committed" --arg created_at "$created_at" --arg updated_at "$now" --argjson total "$total")
  local body='{schema_version:$sv, invocation_id:$id, issue:$issue, side:$side, run_id:$run_id, member_id:$member_id,
    attempt:$attempt, state:$state, created_at:$created_at, updated_at:$updated_at, total_tokens:$total}'
  if [[ "$input" != "-" ]]; then
    jq_args+=(--argjson input "$input")
    body+=' + {input_tokens:$input}'
  fi
  if [[ "$output" != "-" ]]; then
    jq_args+=(--argjson output "$output")
    body+=' + {output_tokens:$output}'
  fi

  local record
  record="$(jq "${jq_args[@]}" "$body")"
  if [[ -z "$record" ]]; then
    _accounting_unlock _lock_fd
    return 1
  fi

  local rc=0
  if ! _accounting_write_atomic "$dir" "$file" "$record"; then
    echo "accounting_commit_usage: failed to persist ${invocation_id}" >&2
    rc=1
  else
    : # accounting-branch: B032
  fi
  _accounting_unlock _lock_fd
  return $rc
}

# accounting_commit_unknown ISSUE INVOCATION_ID REASON (D4, D8)
#
# Writes a sticky terminal usage-unknown record. An identical usage-unknown
# replay confirms durability and succeeds without rewriting; a conflicting
# terminal payload is rejected. Terminal states never overwrite each other.
accounting_commit_unknown() {
  if (( $# != 3 )); then
    echo "accounting_commit_unknown: expected ISSUE INVOCATION_ID REASON" >&2
    return 1
  fi
  local issue="${1-}" invocation_id="${2-}" reason="${3-}"
  _accounting_valid_issue "$issue" || { echo "accounting_commit_unknown: issue must be a positive integer" >&2; return 1; }
  _accounting_valid_invocation_id "$invocation_id" || { echo "accounting_commit_unknown: invalid invocation_id" >&2; return 1; }
  [[ -n "$reason" ]] || { echo "accounting_commit_unknown: reason is required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_commit_unknown: jq is required" >&2; return 1; }

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_commit_unknown: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  local file="${dir}/${invocation_id}.json"
  if _accounting_path_is_nonregular "$file"; then
    echo "accounting_commit_unknown: refusing non-regular record target: $file" >&2
    _accounting_unlock _lock_fd
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    echo "accounting_commit_unknown: no started record for ${invocation_id}" >&2
    _accounting_unlock _lock_fd
    return 1 # accounting-branch: B034
  fi

  local now created_at="" run_id="" side="" member_id="" attempt="0"

  local existing existing_state
  if ! existing="$(_accounting_read_valid_record "$file" "$issue")"; then
    echo "accounting_commit_unknown: existing record for ${invocation_id} is corrupt" >&2
    _accounting_unlock _lock_fd
    return 1
  fi
  existing_state="$(jq -r '.state' <<<"$existing")"
  if [[ "$existing_state" == "usage-unknown" ]]; then
    if ! _accounting_confirm_durable "$file" "$dir"; then
      echo "accounting_commit_unknown: failed to confirm durable replay for ${invocation_id}" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    if jq -e --arg reason "$reason" '.reason == $reason' <<<"$existing" >/dev/null; then
      _accounting_unlock _lock_fd
      return 0 # accounting-branch: B065
    fi
    echo "accounting_commit_unknown: conflicting duplicate for ${invocation_id}" >&2
    _accounting_unlock _lock_fd
    return 1 # accounting-branch: B035
  elif [[ "$existing_state" == "usage-committed" ]]; then
    if ! _accounting_confirm_durable "$file" "$dir"; then
      echo "accounting_commit_unknown: failed to confirm durable terminal record for ${invocation_id}" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    echo "accounting_commit_unknown: ${invocation_id} is already terminal (${existing_state})" >&2
    _accounting_unlock _lock_fd
    return 1
  elif [[ "$existing_state" != "started" ]]; then
    echo "accounting_commit_unknown: invalid prior state for ${invocation_id}: ${existing_state}" >&2
    _accounting_unlock _lock_fd
    return 1
  fi
  _accounting_carry_fields "$existing" created_at run_id side member_id attempt
  if ! now="$(_accounting_now)"; then
    _accounting_unlock _lock_fd
    return 1
  fi
  [[ -n "$created_at" ]] || created_at="$now"
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0

  local record
  record="$(jq -nc \
    --argjson sv "$ACCOUNTING_SCHEMA_VERSION" --arg id "$invocation_id" --argjson issue "$issue" \
    --arg side "$side" --arg run_id "$run_id" --arg member_id "$member_id" --argjson attempt "$attempt" \
    --arg state "usage-unknown" --arg created_at "$created_at" --arg updated_at "$now" --arg reason "$reason" \
    '{schema_version:$sv, invocation_id:$id, issue:$issue, side:$side, run_id:$run_id, member_id:$member_id,
      attempt:$attempt, state:$state, created_at:$created_at, updated_at:$updated_at, reason:$reason}')"
  if [[ -z "$record" ]]; then
    _accounting_unlock _lock_fd
    return 1
  fi

  local rc=0
  if ! _accounting_write_atomic "$dir" "$file" "$record"; then
    echo "accounting_commit_unknown: failed to persist ${invocation_id}" >&2
    rc=1
  else
    : # accounting-branch: B036
  fi
  _accounting_unlock _lock_fd
  return $rc
}

# accounting_reconcile ISSUE (D6, D8)
#
# Promotes dead-owner `started` records to terminal usage-unknown. Evidence
# is the EXISTING INV-135 lease for this issue (the run-id sidecar +
# progress.json's `pid`) — never issue-closed state. Only `side=dev` records
# are evaluated: the INV-135 lease exists only on the dev side, so a
# `side=review` `started` record has no evidence source here and is left
# untouched (stays `incomplete`) — never conflated with proof-of-death.
# Never rewrites an already-terminal record (re-arm never deletes known
# totals).
accounting_reconcile() {
  if (( $# != 1 )); then
    echo "accounting_reconcile: expected ISSUE" >&2
    return 1
  fi
  local issue="${1-}"
  _accounting_valid_issue "$issue" || { echo "accounting_reconcile: issue must be a positive integer" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_reconcile: jq is required" >&2; return 1; }

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_reconcile: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  # have_run_id / have_pid distinguish "no evidence was found" from "evidence
  # was found and it says X" — collapsing the two would let a merely-missing
  # sidecar (e.g. INV-135's own documented transient window between a fresh
  # init writing the run-id file and its later progress.json write, or its
  # compare-then-unlink cleanup race) masquerade as proof of death and
  # terminally mislabel a live invocation's usage as unknown.
  local pdir current_run_id="" current_pid="" current_alive=0
  local have_run_id=0 have_pid=0
  if pdir="$(_accounting_pid_dir 2>/dev/null)"; then
    local run_file="${pdir}/issue-${issue}.run-id"
    local progress_file="${pdir}/issue-${issue}.progress.json"
    if [[ -f "$run_file" && ! -L "$run_file" ]]; then
      if current_run_id="$(cat "$run_file" 2>/dev/null)" &&
        [[ -n "$current_run_id" && "$current_run_id" != *$'\n'* ]]; then
        have_run_id=1
      else
        current_run_id=""
      fi
    fi
    if [[ -f "$progress_file" && ! -L "$progress_file" ]]; then
      local progress_fields progress_run_id
      if progress_fields="$(jq -er '
          select(
            type == "object"
            and .schema_version == 1
            and ((.run_id | type) == "string" and (.run_id | length) > 0)
            and ((.pid | type) == "number" and .pid >= 1 and (.pid | floor) == .pid)
            and ((.updated_at_epoch | type) == "number" and .updated_at_epoch >= 0 and
              (.updated_at_epoch | floor) == .updated_at_epoch)
          )
          | [.run_id, .pid] | @tsv
        ' "$progress_file" 2>/dev/null)"; then
        IFS=$'\t' read -r progress_run_id current_pid <<<"$progress_fields"
        if [[ "$have_run_id" -eq 1 && "$progress_run_id" == "$current_run_id" ]]; then
          have_pid=1
        else
          current_pid="" # accounting-branch: B038
        fi
      fi
    fi
  fi
  if [[ "$have_pid" -eq 1 ]] && kill -0 "$current_pid" 2>/dev/null; then
    current_alive=1 # accounting-branch: B039
  fi

  local f rc=0
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "projection.json" ]] && continue

    local rec read_rc
    if rec="$(_accounting_read_valid_record "$f" "$issue")"; then
      :
    else
      read_rc=$?
      if [[ "$read_rc" -eq 2 ]]; then
        echo "accounting_reconcile: cannot read record ${f##*/}" >&2
        rc=1
      fi
      continue
    fi

    local state
    state="$(jq -r '.state // ""' <<<"$rec")"
    if [[ "$state" != "started" ]]; then
      : # accounting-branch: B043
      if ! _accounting_confirm_durable "$f" "$dir"; then
        echo "accounting_reconcile: failed to confirm durable terminal record ${f##*/}" >&2
        rc=1 # accounting-branch: B066
      else
        : # accounting-branch: B067
      fi
      continue
    fi

    local side
    side="$(jq -r '.side // ""' <<<"$rec")"
    if [[ "$side" != "dev" ]]; then
      : # accounting-branch: B042
      continue
    fi

    # dead=1 only on POSITIVE evidence — a superseded run-id (evidence
    # exists and names a different run) or a resolvable-but-dead pid
    # (evidence exists and kill -0 fails). Missing evidence (have_run_id=0
    # or, when the run-id matches, have_pid=0) is "unproven", not "dead" —
    # it leaves the record `started` (query status incomplete), matching
    # D6/INV-139's "an issue being closed is NOT proof" posture: absence of
    # a signal is exactly as inconclusive as a signal that says nothing.
    local rec_run_id dead=0
    rec_run_id="$(jq -r '.run_id // ""' <<<"$rec")"
    if [[ "$have_run_id" -eq 1 && "$rec_run_id" != "$current_run_id" ]]; then
      dead=1 # accounting-branch: B041
    elif [[ "$have_run_id" -eq 1 && "$rec_run_id" == "$current_run_id" && "$have_pid" -eq 1 && "$current_alive" -eq 0 ]]; then
      dead=1 # accounting-branch: B040
    fi
    if [[ "$dead" -ne 1 ]]; then
      : # accounting-branch: B037
      continue
    fi

    local now updated
    if ! now="$(_accounting_now)"; then
      rc=1
      continue
    fi
    if ! updated="$(jq -c --arg state "usage-unknown" --arg updated_at "$now" --arg reason "proof-of-death:reconcile" \
      '.state = $state | .updated_at = $updated_at | .reason = $reason' <<<"$rec")"; then
      echo "accounting_reconcile: failed to build terminal record for ${f##*/}" >&2
      rc=1
      continue
    fi
    if ! _accounting_write_atomic "$dir" "$f" "$updated"; then
      echo "accounting_reconcile: failed to persist terminal record for ${f##*/}" >&2
      rc=1 # accounting-branch: B044
    else
      : # accounting-branch: B045
    fi
  done

  _accounting_unlock _lock_fd
  return $rc
}

# accounting_ack_unknown ISSUE INVOCATION_ID... (D6, D8)
#
# Explicit, audited operator verb: appends one ack record per invocation id
# to <issue>/acks.jsonl. NEVER deletes or rewrites the underlying
# usage-unknown record. rc 1 (with per-id stderr) if any id is missing or
# not currently usage-unknown; other ids in the same call still get acked.
accounting_ack_unknown() {
  if (( $# < 2 )); then
    echo "accounting_ack_unknown: expected ISSUE INVOCATION_ID..." >&2
    return 1
  fi
  local issue="${1-}"
  shift
  _accounting_valid_issue "$issue" || { echo "accounting_ack_unknown: issue must be a positive integer" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_ack_unknown: jq is required" >&2; return 1; }

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_ack_unknown: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  local acks_file="${dir}/acks.jsonl"
  if _accounting_path_is_nonregular "$acks_file"; then
    echo "accounting_ack_unknown: refusing non-regular acks file: $acks_file" >&2
    _accounting_unlock _lock_fd
    return 1
  fi

  local id rc=0
  for id in "$@"; do
    if ! _accounting_valid_invocation_id "$id"; then
      echo "accounting_ack_unknown: invalid invocation_id: ${id}" >&2
      rc=1
      continue
    fi
    local file="${dir}/${id}.json"
    if [[ ! -f "$file" ]]; then
      echo "accounting_ack_unknown: no record for ${id}" >&2
      rc=1 # accounting-branch: B047
      continue
    fi
    local record state
    if ! record="$(_accounting_read_valid_record "$file" "$issue")"; then
      echo "accounting_ack_unknown: record for ${id} is corrupt or unavailable" >&2
      rc=1
      continue
    fi
    state="$(jq -r '.state' <<<"$record")"
    if [[ "$state" != "usage-unknown" ]]; then
      echo "accounting_ack_unknown: ${id} is not in usage-unknown state (state=${state:-corrupt})" >&2
      rc=1 # accounting-branch: B048
      continue
    fi
    local now line
    if ! now="$(_accounting_now)"; then
      rc=1
      continue
    fi
    line="$(jq -nc \
      --argjson sv "$ACCOUNTING_SCHEMA_VERSION" --arg id "$id" --argjson issue "$issue" --arg ts "$now" \
      '{schema_version:$sv, invocation_id:$id, issue:$issue, ts:$ts, event:"ack-unknown"}')"
    if [[ -z "$line" ]] || ! printf '%s\n' "$line" >> "$acks_file" 2>/dev/null; then
      echo "accounting_ack_unknown: failed to append audit record for ${id}" >&2
      rc=1
    elif ! _accounting_sync_file "$acks_file" || ! _accounting_sync_dir "$dir"; then
      echo "accounting_ack_unknown: failed to sync audit record for ${id}" >&2
      rc=1
    else
      : # accounting-branch: B046
    fi
  done

  _accounting_unlock _lock_fd
  return $rc
}

# accounting_admission_query ISSUE (D2, D4, D8)
#
# Locked full scan of <issue>/*.json (excluding projection.json). Echoes one
# JSON object: {status, total_tokens, source_digest, open_invocations,
# unknown_invocations}. `status` priority: unavailable (lock/store failure,
# returned WITHOUT a scan) > corrupt (a malformed record was found) >
# usage-unknown (>=1 sticky unknown) > incomplete (>=1 open, none unknown) >
# complete. corrupt/usage-unknown/incomplete/complete are all successful
# QUERY OUTCOMES (rc 0) — only `unavailable` is a mechanism failure (rc 1).
# Rebuilds projection.json when missing, digest-stale, or unparseable;
# never trusts the cached total over a fresh scan.
_accounting_unavailable_json() {
  printf '%s\n' '{"status":"unavailable","total_tokens":0,"source_digest":"","open_invocations":[],"unknown_invocations":[]}'
}

accounting_admission_query() {
  if (( $# != 1 )); then
    echo "accounting_admission_query: expected ISSUE" >&2
    return 1
  fi
  local issue="${1-}"
  _accounting_valid_issue "$issue" || { echo "accounting_admission_query: issue must be a positive integer" >&2; return 1; }
  if ! command -v jq >/dev/null 2>&1; then
    # jq is confirmed absent above — the payload is hand-spelled (the one
    # exception to the file's jq -nc-only contract) since jq cannot be
    # invoked to build it.
    echo "accounting_admission_query: jq is required" >&2
    _accounting_unavailable_json
    return 1
  fi

  local dir
  if ! dir="$(_accounting_issue_dir "$issue" 2>/dev/null)"; then
    echo "accounting_admission_query: accounting store is unavailable for issue ${issue}" >&2
    _accounting_unavailable_json
    return 1
  fi

  local _lock_fd
  if ! _accounting_lock "$issue" _lock_fd 2>/dev/null; then
    echo "accounting_admission_query: accounting lock is unavailable for issue ${issue}" >&2
    _accounting_unavailable_json
    return 1 # accounting-branch: B049
  fi

  local total=0 any_corrupt=0 open_count=0 unknown_count=0
  local open_json="[]" unknown_json="[]" scan_json="[]"
  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" || -L "$f" ]] || continue
    [[ "$(basename "$f")" == "projection.json" ]] && continue

    local rec id state read_rc
    if rec="$(_accounting_read_valid_record "$f" "$issue")"; then
      :
    else
      read_rc=$?
      if [[ "$read_rc" -eq 2 ]]; then
        echo "accounting_admission_query: cannot read invocation record ${f##*/}" >&2
        _accounting_unlock _lock_fd
        _accounting_unavailable_json
        return 1 # accounting-branch: B050
      fi
      any_corrupt=1 # accounting-branch: B051
      continue
    fi
    IFS=$'\t' read -r id state <<<"$(jq -r '[(.invocation_id // ""), (.state // "")] | @tsv' <<<"$rec")"

    local tk=0
    case "$state" in
      usage-committed)
        : # accounting-branch: B069
        tk="$(jq -r '.total_tokens' <<<"$rec")"
        if (( tk > ACCOUNTING_MAX_EXACT_TOKENS - total )); then
          any_corrupt=1 # accounting-branch: B068
          continue
        fi
        total=$((total + tk))
        ;;
      started)
        : # accounting-branch: B070
        open_json="$(jq -c --arg id "$id" '. + [$id]' <<<"$open_json")"
        open_count=$((open_count + 1))
        ;;
      usage-unknown)
        : # accounting-branch: B071
        unknown_json="$(jq -c --arg id "$id" '. + [$id]' <<<"$unknown_json")"
        unknown_count=$((unknown_count + 1))
        ;;
      *)
        : # accounting-branch: B072
        any_corrupt=1
        continue
        ;;
    esac

    scan_json="$(jq -c --arg id "$id" --arg state "$state" --argjson tk "$tk" \
      '. + [{id:$id, state:$state, total_tokens:$tk}]' <<<"$scan_json")"
  done

  local sorted digest ids_sorted
  sorted="$(jq -c 'sort_by(.id)' <<<"$scan_json")"
  ids_sorted="$(jq -c '[.[].id] | sort' <<<"$scan_json")"
  if ! digest="$(_accounting_sha256 "$sorted")" || [[ -z "$digest" ]]; then
    echo "accounting_admission_query: cannot compute source digest for issue ${issue}" >&2
    _accounting_unlock _lock_fd
    _accounting_unavailable_json
    return 1
  fi

  local status
  if [[ "$any_corrupt" -eq 1 ]]; then
    status="corrupt" # accounting-branch: B052
  elif [[ "$unknown_count" -gt 0 ]]; then
    status="usage-unknown" # accounting-branch: B053
  elif [[ "$open_count" -gt 0 ]]; then
    status="incomplete" # accounting-branch: B054
  else
    status="complete" # accounting-branch: B055
  fi

  # Rebuild the projection cache when missing, corrupt, or digest-stale.
  local proj_file="${dir}/projection.json" need_rebuild=1
  if [[ -f "$proj_file" && ! -L "$proj_file" ]]; then
    local projection_raw
    if ! projection_raw="$(cat "$proj_file" 2>/dev/null)"; then
      echo "accounting_admission_query: cannot read projection for issue ${issue}" >&2
      _accounting_unlock _lock_fd
      _accounting_unavailable_json
      return 1
    fi
    if jq -e \
      --argjson sv "$ACCOUNTING_SCHEMA_VERSION" \
      --argjson total "$total" \
      --argjson ids "$ids_sorted" \
      --arg digest "$digest" '
        type == "object"
        and .schema_version == $sv
        and .total_tokens == $total
        and .source_invocation_ids == $ids
        and .digest == $digest
      ' <<<"$projection_raw" >/dev/null 2>&1; then
      need_rebuild=0 # accounting-branch: B056
    fi
  fi
  if [[ "$need_rebuild" -eq 1 ]]; then
    local projection # accounting-branch: B057
    projection="$(jq -nc \
      --argjson sv "$ACCOUNTING_SCHEMA_VERSION" --argjson total "$total" \
      --argjson ids "$ids_sorted" --arg digest "$digest" \
      '{schema_version:$sv, total_tokens:$total, source_invocation_ids:$ids, digest:$digest}')"
    if [[ -z "$projection" ]] || ! _accounting_write_atomic "$dir" "$proj_file" "$projection"; then
      echo "accounting_admission_query: failed to rebuild projection for issue ${issue}" >&2
      _accounting_unlock _lock_fd
      _accounting_unavailable_json
      return 1 # accounting-branch: B058
    fi
  fi

  local result
  result="$(jq -nc \
    --arg status "$status" --argjson total "$total" --arg digest "$digest" \
    --argjson open "$open_json" --argjson unknown "$unknown_json" \
    '{status:$status, total_tokens:$total, source_digest:$digest, open_invocations:$open, unknown_invocations:$unknown}')"
  printf '%s\n' "$result"

  _accounting_unlock _lock_fd
  return 0
}
