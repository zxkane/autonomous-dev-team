#!/bin/bash
# lib-accounting.sh — INV-139 crash-consistent token-accounting store
# (issue #505, parent #450).
#
# This is the AUTHORITATIVE resource-accounting store the future admission
# gate (#506) and terminal-control helpers (#515) will read. It is a
# deliberately SEPARATE library and storage directory from lib-metrics.sh:
# metrics_emit's swallow-all, best-effort, 90-day-pruned JSONL log stays
# exactly as-is (INV-70) — it is not durable enough to gate anything on.
# This lib is INERT in production: nothing sources or calls it outside its
# own tests as of this issue (grep-pinned — see test-lib-accounting.sh).
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
    dir="${AUTONOMOUS_ACCOUNTING_DIR}"
  elif [[ -z "$project_id" ]]; then
    return 1
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    dir="${XDG_STATE_HOME}/autonomous-${project_id}/accounting"
  elif [[ -n "${HOME:-}" ]]; then
    dir="${HOME}/.local/state/autonomous-${project_id}/accounting"
  else
    return 1
  fi

  if [[ -L "$dir" ]]; then
    return 1
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
  if [[ -L "$lock_file" ]] || { [[ -e "$lock_file" ]] && [[ ! -f "$lock_file" ]]; }; then
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
    return 1
  fi
  _out_fd="$fd"
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

# _accounting_write_atomic <dir> <target_file> <content> — tmp file in the
# SAME directory + `mv -f` (the INV-135 idiom), mode 0600. Refuses to write
# through a pre-existing symlinked target.
_accounting_write_atomic() {
  local dir="$1" target="$2" content="$3" tmp
  [[ -L "$target" ]] && { echo "_accounting_write_atomic: refusing symlinked target: $target" >&2; return 1; }
  tmp="$(mktemp "${dir}/.acct.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    # Best-effort perms (mirrors lib-agent.sh's lease writers): a chmod
    # failure still leaves a valid (if looser-mode) file, never blocks the write.
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  else
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  return 0
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
  local run_id="$1" side="$2" member_id="$3" attempt="$4"
  command -v jq >/dev/null 2>&1 || { echo "accounting_invocation_id: jq is required" >&2; return 1; }
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || { echo "accounting_invocation_id: attempt must be a positive integer (D3: a positive ordinal)" >&2; return 1; }

  local canonical digest
  canonical="$(jq -nc \
    --arg run_id "$run_id" --arg side "$side" --arg member_id "$member_id" --argjson attempt "$attempt" \
    '{run_id:$run_id, side:$side, member_id:$member_id, attempt:$attempt}')" || return 1

  digest="$(_accounting_sha256 "$canonical")" || { echo "accounting_invocation_id: no sha256 tool available" >&2; return 1; }
  [[ -n "$digest" ]] || return 1

  printf 'inv-v1-%s\n' "${digest:0:24}"
}

# accounting_start ISSUE INVOCATION_ID SIDE RUN_ID MEMBER_ID ATTEMPT (D8)
#
# Writes an initial `started` record. Idempotent: if a record for
# INVOCATION_ID already exists (in ANY state), this is a no-op success —
# never regresses a terminal record back to `started`.
accounting_start() {
  local issue="$1" invocation_id="$2" side="$3" run_id="$4" member_id="$5" attempt="$6"
  [[ -n "$issue" && -n "$invocation_id" ]] || { echo "accounting_start: issue and invocation_id are required" >&2; return 1; }
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || { echo "accounting_start: attempt must be a positive integer (D3: a positive ordinal)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_start: jq is required" >&2; return 1; }

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_start: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  local file="${dir}/${invocation_id}.json"
  if [[ -e "$file" ]]; then
    _accounting_unlock _lock_fd
    return 0
  fi

  local now record
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

  _accounting_write_atomic "$dir" "$file" "$record"
  local rc=$?
  _accounting_unlock _lock_fd
  return $rc
}

# accounting_commit_usage ISSUE INVOCATION_ID TOTAL [INPUT|-] [OUTPUT|-] (D5, D8)
#
# Strict idempotent commit. No existing record -> write usage-committed.
# Existing terminal usage-committed record, IDENTICAL payload -> rc 0,
# no write. Existing terminal record, CONFLICTING payload -> rc 1, no
# mutation, loud stderr. Already usage-unknown -> rc 1 (terminal states
# never overwrite each other). Any write failure -> rc 1 (no swallow — the
# rename is the durability boundary).
accounting_commit_usage() {
  local issue="$1" invocation_id="$2" total="$3" input="${4:--}" output="${5:--}"
  [[ -n "$issue" && -n "$invocation_id" ]] || { echo "accounting_commit_usage: issue and invocation_id are required" >&2; return 1; }
  [[ "$total" =~ ^[0-9]+$ ]] || { echo "accounting_commit_usage: total must be a non-negative integer" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_commit_usage: jq is required" >&2; return 1; }

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_commit_usage: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  local file="${dir}/${invocation_id}.json"
  local created_at="" run_id="" side="" member_id="" attempt="0"
  if [[ -f "$file" ]]; then
    local existing existing_state
    if ! existing="$(jq -e . "$file" 2>/dev/null)"; then
      echo "accounting_commit_usage: existing record for ${invocation_id} is corrupt" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    existing_state="$(jq -r '.state // ""' <<<"$existing")"
    if [[ "$existing_state" == "usage-committed" ]]; then
      local ex_total ex_input ex_output
      IFS=$'\t' read -r ex_total ex_input ex_output <<<"$(jq -r \
        '[(.total_tokens // ""), (if has("input_tokens") then .input_tokens else "-" end),
          (if has("output_tokens") then .output_tokens else "-" end)] | @tsv' <<<"$existing")"
      if [[ "$ex_total" == "$total" && "$ex_input" == "$input" && "$ex_output" == "$output" ]]; then
        _accounting_unlock _lock_fd
        return 0
      fi
      echo "accounting_commit_usage: conflicting duplicate commit for ${invocation_id} (existing total=${ex_total}, requested=${total})" >&2
      _accounting_unlock _lock_fd
      return 1
    elif [[ "$existing_state" == "usage-unknown" ]]; then
      echo "accounting_commit_usage: ${invocation_id} is already terminal usage-unknown" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    _accounting_carry_fields "$existing" created_at run_id side member_id attempt
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -n "$created_at" ]] || created_at="$now"
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0

  local -a jq_args=(-nc
    --argjson sv "$ACCOUNTING_SCHEMA_VERSION" --arg id "$invocation_id" --argjson issue "$issue"
    --arg side "$side" --arg run_id "$run_id" --arg member_id "$member_id" --argjson attempt "$attempt"
    --arg state "usage-committed" --arg created_at "$created_at" --arg updated_at "$now" --argjson total "$total")
  local body='{schema_version:$sv, invocation_id:$id, issue:$issue, side:$side, run_id:$run_id, member_id:$member_id,
    attempt:$attempt, state:$state, created_at:$created_at, updated_at:$updated_at, total_tokens:$total}'
  if [[ "$input" != "-" ]]; then
    if [[ ! "$input" =~ ^[0-9]+$ ]]; then
      echo "accounting_commit_usage: input must be a non-negative integer or -" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    jq_args+=(--argjson input "$input")
    body+=' + {input_tokens:$input}'
  fi
  if [[ "$output" != "-" ]]; then
    if [[ ! "$output" =~ ^[0-9]+$ ]]; then
      echo "accounting_commit_usage: output must be a non-negative integer or -" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    jq_args+=(--argjson output "$output")
    body+=' + {output_tokens:$output}'
  fi

  local record
  record="$(jq "${jq_args[@]}" "$body")"
  if [[ -z "$record" ]]; then
    _accounting_unlock _lock_fd
    return 1
  fi

  _accounting_write_atomic "$dir" "$file" "$record"
  local rc=$?
  _accounting_unlock _lock_fd
  return $rc
}

# accounting_commit_unknown ISSUE INVOCATION_ID REASON (D4, D8)
#
# Writes a sticky terminal usage-unknown record. Rejects (rc 1) if the
# invocation is already terminal (either state) — terminal states never
# overwrite each other.
accounting_commit_unknown() {
  local issue="$1" invocation_id="$2" reason="$3"
  [[ -n "$issue" && -n "$invocation_id" ]] || { echo "accounting_commit_unknown: issue and invocation_id are required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_commit_unknown: jq is required" >&2; return 1; }

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_commit_unknown: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  local file="${dir}/${invocation_id}.json"
  local now created_at="" run_id="" side="" member_id="" attempt="0"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -f "$file" ]]; then
    local existing existing_state
    if ! existing="$(jq -e . "$file" 2>/dev/null)"; then
      echo "accounting_commit_unknown: existing record for ${invocation_id} is corrupt" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    existing_state="$(jq -r '.state // ""' <<<"$existing")"
    if [[ "$existing_state" == "usage-committed" || "$existing_state" == "usage-unknown" ]]; then
      echo "accounting_commit_unknown: ${invocation_id} is already terminal (${existing_state})" >&2
      _accounting_unlock _lock_fd
      return 1
    fi
    _accounting_carry_fields "$existing" created_at run_id side member_id attempt
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

  _accounting_write_atomic "$dir" "$file" "$record"
  local rc=$?
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
  local issue="$1"
  [[ -n "$issue" ]] || { echo "accounting_reconcile: issue is required" >&2; return 1; }
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
    if [[ -f "${pdir}/issue-${issue}.run-id" ]]; then
      current_run_id="$(<"${pdir}/issue-${issue}.run-id")"
      current_run_id="${current_run_id%%$'\n'*}"
      [[ -n "$current_run_id" ]] && have_run_id=1
    fi
    if [[ -f "${pdir}/issue-${issue}.progress.json" ]]; then
      current_pid="$(jq -r '.pid // empty' "${pdir}/issue-${issue}.progress.json" 2>/dev/null)"
      [[ -n "$current_pid" ]] && have_pid=1
    fi
  fi
  if [[ "$have_pid" -eq 1 ]] && kill -0 "$current_pid" 2>/dev/null; then
    current_alive=1
  fi

  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "projection.json" ]] && continue

    local rec
    rec="$(jq -e . "$f" 2>/dev/null)" || continue  # corrupt — never mutate

    local state
    state="$(jq -r '.state // ""' <<<"$rec")"
    [[ "$state" == "started" ]] || continue

    local side
    side="$(jq -r '.side // ""' <<<"$rec")"
    [[ "$side" == "dev" ]] || continue

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
      dead=1
    elif [[ "$have_run_id" -eq 1 && "$rec_run_id" == "$current_run_id" && "$have_pid" -eq 1 && "$current_alive" -eq 0 ]]; then
      dead=1
    fi
    [[ "$dead" -eq 1 ]] || continue

    local now updated
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    updated="$(jq -c --arg state "usage-unknown" --arg updated_at "$now" --arg reason "proof-of-death:reconcile" \
      '.state = $state | .updated_at = $updated_at | .reason = $reason' <<<"$rec")" || continue
    _accounting_write_atomic "$dir" "$f" "$updated"
  done

  _accounting_unlock _lock_fd
  return 0
}

# accounting_ack_unknown ISSUE INVOCATION_ID... (D6, D8)
#
# Explicit, audited operator verb: appends one ack record per invocation id
# to <issue>/acks.jsonl. NEVER deletes or rewrites the underlying
# usage-unknown record. rc 1 (with per-id stderr) if any id is missing or
# not currently usage-unknown; other ids in the same call still get acked.
accounting_ack_unknown() {
  local issue="$1"
  shift
  [[ -n "$issue" && $# -ge 1 ]] || { echo "accounting_ack_unknown: issue and at least one invocation_id are required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "accounting_ack_unknown: jq is required" >&2; return 1; }

  local dir
  dir="$(_accounting_issue_dir "$issue")" || { echo "accounting_ack_unknown: cannot resolve issue directory" >&2; return 1; }

  local _lock_fd
  _accounting_lock "$issue" _lock_fd || return 1

  local acks_file="${dir}/acks.jsonl"
  if [[ -L "$acks_file" ]]; then
    echo "accounting_ack_unknown: refusing symlinked acks file: $acks_file" >&2
    _accounting_unlock _lock_fd
    return 1
  fi

  local id rc=0
  for id in "$@"; do
    local file="${dir}/${id}.json"
    if [[ ! -f "$file" ]]; then
      echo "accounting_ack_unknown: no record for ${id}" >&2
      rc=1
      continue
    fi
    local state
    state="$(jq -r '.state // ""' "$file" 2>/dev/null)"
    if [[ "$state" != "usage-unknown" ]]; then
      echo "accounting_ack_unknown: ${id} is not in usage-unknown state (state=${state:-corrupt})" >&2
      rc=1
      continue
    fi
    local now line
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line="$(jq -nc \
      --argjson sv "$ACCOUNTING_SCHEMA_VERSION" --arg id "$id" --argjson issue "$issue" --arg ts "$now" \
      '{schema_version:$sv, invocation_id:$id, issue:$issue, ts:$ts, event:"ack-unknown"}')"
    if [[ -z "$line" ]] || ! printf '%s\n' "$line" >> "$acks_file" 2>/dev/null; then
      rc=1
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
  local issue="$1"
  [[ -n "$issue" ]] || { echo "accounting_admission_query: issue is required" >&2; return 1; }
  if ! command -v jq >/dev/null 2>&1; then
    # jq is confirmed absent above — the payload is hand-spelled (the one
    # exception to the file's jq -nc-only contract) since jq cannot be
    # invoked to build it.
    _accounting_unavailable_json
    return 1
  fi

  local dir
  if ! dir="$(_accounting_issue_dir "$issue" 2>/dev/null)"; then
    _accounting_unavailable_json
    return 1
  fi

  local _lock_fd
  if ! _accounting_lock "$issue" _lock_fd 2>/dev/null; then
    _accounting_unavailable_json
    return 1
  fi

  local total=0 any_corrupt=0 open_count=0 unknown_count=0
  local open_json="[]" unknown_json="[]" scan_json="[]"
  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "projection.json" ]] && continue

    local rec id state
    if ! rec="$(jq -e . "$f" 2>/dev/null)"; then
      any_corrupt=1
      continue
    fi
    IFS=$'\t' read -r id state <<<"$(jq -r '[(.invocation_id // ""), (.state // "")] | @tsv' <<<"$rec")"

    local tk=0
    case "$state" in
      usage-committed)
        tk="$(jq -r '.total_tokens // 0' <<<"$rec")"
        if [[ ! "$tk" =~ ^[0-9]+$ ]]; then
          any_corrupt=1
          continue
        fi
        total=$((total + tk))
        ;;
      started)
        open_json="$(jq -c --arg id "$id" '. + [$id]' <<<"$open_json")"
        open_count=$((open_count + 1))
        ;;
      usage-unknown)
        unknown_json="$(jq -c --arg id "$id" '. + [$id]' <<<"$unknown_json")"
        unknown_count=$((unknown_count + 1))
        ;;
      *)
        any_corrupt=1
        continue
        ;;
    esac

    scan_json="$(jq -c --arg id "$id" --arg state "$state" --argjson tk "$tk" \
      '. + [{id:$id, state:$state, total_tokens:$tk}]' <<<"$scan_json")"
  done

  local sorted digest
  sorted="$(jq -c 'sort_by(.id)' <<<"$scan_json")"
  digest="$(_accounting_sha256 "$sorted")" || digest=""

  local status
  if [[ "$any_corrupt" -eq 1 ]]; then
    status="corrupt"
  elif [[ "$unknown_count" -gt 0 ]]; then
    status="usage-unknown"
  elif [[ "$open_count" -gt 0 ]]; then
    status="incomplete"
  else
    status="complete"
  fi

  # Rebuild the projection cache when missing, corrupt, or digest-stale.
  local proj_file="${dir}/projection.json" need_rebuild=1
  if [[ -f "$proj_file" && ! -L "$proj_file" ]]; then
    local existing_digest
    existing_digest="$(jq -r '.digest // ""' "$proj_file" 2>/dev/null)"
    [[ -n "$existing_digest" && "$existing_digest" == "$digest" ]] && need_rebuild=0
  fi
  if [[ "$need_rebuild" -eq 1 && -n "$digest" ]]; then
    local ids_sorted projection
    ids_sorted="$(jq -c '[.[].id] | sort' <<<"$scan_json")"
    projection="$(jq -nc \
      --argjson sv "$ACCOUNTING_SCHEMA_VERSION" --argjson total "$total" \
      --argjson ids "$ids_sorted" --arg digest "$digest" \
      '{schema_version:$sv, total_tokens:$total, source_invocation_ids:$ids, digest:$digest}')"
    [[ -n "$projection" ]] && _accounting_write_atomic "$dir" "$proj_file" "$projection"
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
