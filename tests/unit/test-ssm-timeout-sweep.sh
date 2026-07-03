#!/bin/bash
# test-ssm-timeout-sweep.sh — grep-sweep regression for issue #369.
#
# AWS ssm send-command's --timeout-seconds has a hard API minimum of 30;
# any lower value is rejected transport-side with ParamValidation on EVERY
# call, not flakily. #369 found this in lib-ssm.sh's SSM_COMMAND_TIMEOUT_SECONDS
# default (was 10, on BOTH the unset-env default AND the non-numeric-guard
# fallback). This test sweeps every SSM transport script for any OTHER
# hardcoded or defaulted --timeout-seconds value below 30, per the issue's
# explicit testing requirement ("search the whole SSM transport path").
#
# Scope (Out of Scope in #369): a USER-SUPPLIED env override below 30 (e.g.
# an operator exporting SSM_COMMAND_TIMEOUT_SECONDS=20) is intentionally
# left alone — only the internal DEFAULT is in scope. This sweep therefore
# checks default/fallback VALUES, not env-override call sites.
#
# Run: bash tests/unit/test-ssm-timeout-sweep.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

# The four SSM transport files named explicitly in issue #369.
TRANSPORT_FILES=(
  "$SCRIPTS/lib-ssm.sh"
  "$SCRIPTS/liveness-check-remote-aws-ssm.sh"
  "$SCRIPTS/session-log-probe-remote-aws-ssm.sh"
  "$SCRIPTS/dispatch-remote-aws-ssm.sh"
)

# lib-ssm.sh's shared minimum constant (post-review DRY fix): both
# cmd_timeout defaulting sites reference this instead of repeating the
# literal 30. A defaulted value that IS this variable is compliant iff the
# constant itself is proven >= 30 by TC-SWEEP-005; any other variable
# reference is unverifiable by a grep sweep and must surface, never pass
# silently.
MIN_CONST_NAME='_SSM_MIN_COMMAND_TIMEOUT_SECONDS'

# classify_default TC_ID LABEL VALUE MATCH_LINE — shared classifier for
# TC-SWEEP-002/003: a bare integer < 30 is an offender, >= 30 is fine, a
# reference to lib-ssm.sh's shared constant ($NAME or ${NAME}) is fine
# (deferred to TC-SWEEP-005), anything else is an unverifiable non-literal
# default and surfaces as an offender rather than being silently skipped.
classify_default() {
  local tc="$1" label="$2" val="$3" fname="$4" lineno="$5" match="$6"
  local bare_name="${val#\"}"; bare_name="${bare_name%\"}"
  bare_name="${bare_name#\$}"
  bare_name="${bare_name#\{}"
  bare_name="${bare_name%\}}"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    if [[ "$val" -lt 30 ]]; then
      bad "$tc ${fname##*/}:$lineno $label below 30 (found $val): $match"
      return 1
    fi
    return 0
  fi
  if [[ "$bare_name" == "$MIN_CONST_NAME" ]]; then
    return 0  # deferred to TC-SWEEP-005's source-of-truth check
  fi
  bad "$tc ${fname##*/}:$lineno $label is an unverifiable non-literal default: $match"
  return 1
}

# ---------------------------------------------------------------------------
echo "=== TC-SWEEP-001: all four SSM transport files exist ==="
# ---------------------------------------------------------------------------
_missing=0
for f in "${TRANSPORT_FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    bad "TC-SWEEP-001 transport file missing: $f"
    _missing=1
  fi
done
[[ "$_missing" -eq 0 ]] && ok "TC-SWEEP-001 all four SSM transport files present"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SWEEP-002: no \${SSM_COMMAND_TIMEOUT_SECONDS:-X} default below 30 ==="
# ---------------------------------------------------------------------------
# Matches the shell parameter-expansion default form used at lib-ssm.sh.
_offenders=0
for f in "${TRANSPORT_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS=: read -r lineno match; do
    [[ -z "$lineno" ]] && continue
    val="${match#*SSM_COMMAND_TIMEOUT_SECONDS:-}"
    val="${val%%\}*}"
    classify_default "TC-SWEEP-002" "SSM_COMMAND_TIMEOUT_SECONDS default" \
      "$val" "$f" "$lineno" "$match" || _offenders=$((_offenders + 1))
  done < <(grep -nE '\$\{SSM_COMMAND_TIMEOUT_SECONDS:-[^}]+\}' "$f")
done
[[ "$_offenders" -eq 0 ]] && ok "TC-SWEEP-002 no SSM_COMMAND_TIMEOUT_SECONDS parameter-expansion default below 30"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SWEEP-003: no cmd_timeout non-numeric-guard fallback below 30 ==="
# ---------------------------------------------------------------------------
# Matches the second-line-of-defense fallback form used at lib-ssm.sh
# ([[ "$cmd_timeout" =~ ^[0-9]+$ ]] || cmd_timeout=X). A garbage env value
# must still fall back to >= 30, not just the happy unset-env path. Scoped
# to cmd_timeout specifically (the --timeout-seconds API value) — the
# sibling poll_timeout fallback is REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS,
# a dispatcher-side wall-clock polling cap unrelated to AWS's API minimum,
# and is deliberately out of scope for this sweep.
_offenders=0
for f in "${TRANSPORT_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS=: read -r lineno match; do
    [[ -z "$lineno" ]] && continue
    val="${match##*cmd_timeout=}"
    val="${val%\"}"
    classify_default "TC-SWEEP-003" "cmd_timeout non-numeric-guard fallback" \
      "$val" "$f" "$lineno" "$match" || _offenders=$((_offenders + 1))
  done < <(grep -nE '\|\|[[:space:]]*cmd_timeout="?[^[:space:]"]+"?' "$f")
done
[[ "$_offenders" -eq 0 ]] && ok "TC-SWEEP-003 no non-numeric-guard timeout fallback assignment below 30"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SWEEP-004: no hardcoded --timeout-seconds literal below 30 in argv ==="
# ---------------------------------------------------------------------------
# A script could hardcode --timeout-seconds N directly in an aws ssm
# send-command invocation (bypassing any env var entirely). None of the
# four files do this today (dispatch-remote-aws-ssm.sh's own send-command
# call passes no --timeout-seconds flag at all, relying on the AWS default
# of 600s) — this pins that absence and would catch a future hardcoded
# low value.
_offenders=0
for f in "${TRANSPORT_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS=: read -r lineno match; do
    [[ -z "$lineno" ]] && continue
    n=$(printf '%s' "$match" | grep -oE '[0-9]+' | tail -1)
    if [[ -n "$n" ]] && [[ "$n" -lt 30 ]]; then
      bad "TC-SWEEP-004 ${f##*/}:$lineno hardcoded --timeout-seconds literal below 30: $match"
      _offenders=$((_offenders + 1))
    fi
  done < <(grep -nE -- '--timeout-seconds[[:space:]]+"?[0-9]+"?' "$f")
done
[[ "$_offenders" -eq 0 ]] && ok "TC-SWEEP-004 no hardcoded --timeout-seconds literal below 30"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SWEEP-005: lib-ssm.sh source-of-truth — shared minimum constant is >= 30 ==="
# ---------------------------------------------------------------------------
# Load-bearing pin (mirrors TC-RPA-010's style): grep-assert the constant
# both cmd_timeout defaulting sites reference (#369 review DRY fix) so a
# reflexive cleanup PR can't silently regress it below 30.
_lib="$SCRIPTS/lib-ssm.sh"
if grep -qE '^_SSM_MIN_COMMAND_TIMEOUT_SECONDS=3[0-9]$' "$_lib" \
   && ! grep -qE '^_SSM_MIN_COMMAND_TIMEOUT_SECONDS=([12][0-9]|[0-9])$' "$_lib"; then
  ok "TC-SWEEP-005a lib-ssm.sh's _SSM_MIN_COMMAND_TIMEOUT_SECONDS constant is >= 30"
else
  bad "TC-SWEEP-005a lib-ssm.sh's _SSM_MIN_COMMAND_TIMEOUT_SECONDS constant is NOT >= 30"
fi
# The constant must be a PLAIN assignment, not a `:=`-style default-if-unset
# expansion — a `:=` form lets an inherited/exported env var below 30 win
# over the constant, silently recreating #369's rejection (2026-07-03 codex
# review finding). A plain assignment always resets it on every source.
if ! grep -qE '_SSM_MIN_COMMAND_TIMEOUT_SECONDS:=' "$_lib"; then
  ok "TC-SWEEP-005c _SSM_MIN_COMMAND_TIMEOUT_SECONDS is not env-overridable via :="
else
  bad "TC-SWEEP-005c _SSM_MIN_COMMAND_TIMEOUT_SECONDS uses an overridable := default"
fi
# Both defaulting sites must actually consume the constant (not silently
# fall back to a re-introduced private literal).
if grep -qF 'SSM_COMMAND_TIMEOUT_SECONDS:-$_SSM_MIN_COMMAND_TIMEOUT_SECONDS' "$_lib" \
   && grep -qF 'cmd_timeout="$_SSM_MIN_COMMAND_TIMEOUT_SECONDS"' "$_lib"; then
  ok "TC-SWEEP-005b both cmd_timeout defaulting sites reference the shared constant"
else
  bad "TC-SWEEP-005b a cmd_timeout defaulting site no longer references the shared constant"
fi

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] || exit 1
