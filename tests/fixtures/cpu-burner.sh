#!/bin/bash
# Source from a Linux test; call cpu_burner_cleanup from its EXIT trap.
# Registry entries belong to this shell only, never a command substitution.
CPU_BURNER_WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cpu-burner.py"
declare -A _CPU_BURNER_RECORDS=()

cpu_burner_start() {
  local cwd="$1" state_root="$2" seconds="${3:-45}"
  local ready child monitor=false record='' pid parent pgid sid ticks extra i
  CPU_BURNER_PID=''
  [[ -d "$cwd" ]] || return 1
  python3 "$CPU_BURNER_WORKER" check || return 1
  ready=$(mktemp "$state_root/cpu-burner.XXXXXX") || return 1
  # With job control disabled the exec'd Python child can setsid without a
  # forking launcher. Restore the caller's monitor setting immediately.
  [[ $- != *m* ]] || monitor=true
  set +m
  (cd "$cwd" && exec python3 "$CPU_BURNER_WORKER" run "$ready" "$seconds") </dev/null >/dev/null &
  child=$!
  "$monitor" && set -m
  for ((i=0; i<100; i++)); do
    if [[ -s "$ready" ]]; then
      IFS= read -r record < "$ready" || true
      break
    fi
    kill -0 "$child" 2>/dev/null || break
    sleep 0.02
  done
  rm -f "$ready" "$ready.tmp"
  read -r pid parent pgid sid ticks extra <<< "$record"
  if [[ "$pid" == "$child" && "$parent" == "$BASHPID" &&
        "$pgid" == "$child" && "$sid" == "$child" &&
        "$ticks" =~ ^[0-9]+$ && -z "$extra" ]]; then
    _CPU_BURNER_RECORDS[$child]="$record"
    # Public result consumed by the sourcing test.
    # shellcheck disable=SC2034
    CPU_BURNER_PID=$child
    return 0
  fi
  # No guessed identity and no unsafe kill on readiness failure. The worker's
  # own timer bounds this wait even if it failed after starting the CPU loop.
  wait "$child" 2>/dev/null || true
  echo "CPU fixture failed to publish a verified child identity" >&2
  return 1
}

cpu_burner_alive() {
  local pid="${1:-}" record
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  record="${_CPU_BURNER_RECORDS[$pid]:-}"
  [[ -n "$record" ]] || return 1
  # shellcheck disable=SC2086
  python3 "$CPU_BURNER_WORKER" alive $record
}

cpu_burner_stop() {
  local pid="${1:-}" record parent rc=0
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  record="${_CPU_BURNER_RECORDS[$pid]:-}"
  [[ -n "$record" ]] || return 1
  read -r _ parent _ <<< "$record"
  [[ "$parent" == "$BASHPID" ]] || return 1
  # Deliberate splitting of a previously verified numeric record only.
  # shellcheck disable=SC2086
  python3 "$CPU_BURNER_WORKER" stop $record || rc=$?
  [[ "$rc" == 0 || "$rc" == 2 ]] || return "$rc"
  wait "$pid" 2>/dev/null || true
  unset '_CPU_BURNER_RECORDS[$pid]'
}

cpu_burner_cleanup() {
  local pid rc=0
  for pid in "${!_CPU_BURNER_RECORDS[@]}"; do
    cpu_burner_stop "$pid" || rc=1
  done
  return "$rc"
}
