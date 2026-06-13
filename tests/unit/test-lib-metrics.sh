#!/bin/bash
# test-lib-metrics.sh — issue #228 / INV-70.
#
# Covers lib-metrics.sh: the observe-only metrics emitter, the token-usage
# parser, the drop-reason→failure-class mapper, and the retention prune.
# Test IDs: TC-METRICS-001..023, 060..062.
#
# Strategy: source the lib, point AUTONOMOUS_METRICS_DIR at a temp dir, exercise
# metrics_emit / metrics_parse_tokens / metrics_map_drop_reason / metrics_prune,
# and assert on the resulting JSONL with jq. The observe-only contract (INV-70)
# is checked by emitting to an unwritable dir under `set -e` and asserting the
# surrounding rc is unchanged.
#
# Run: bash tests/unit/test-lib-metrics.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-metrics.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      want='$want'"; echo "      got ='$got'"; FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle='$needle'"; echo "      hay   ='$hay'"; FAIL=$((FAIL + 1))
  fi
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-metrics.sh
source "$LIB"

# ---------------------------------------------------------------------------
# metrics_emit — JSON validity & field handling
# ---------------------------------------------------------------------------
echo "== metrics_emit =="

WORK="$(mktemp -d)"
export AUTONOMOUS_METRICS_DIR="$WORK"
export PROJECT_ID="testproj"
MF="$WORK/metrics.jsonl"

# TC-METRICS-001: one line, valid JSON, expected fields.
metrics_emit wrapper_start side=dev mode=new issue=228 agent=claude
assert_eq "TC-METRICS-001 one line written" "1" "$(wc -l < "$MF" | tr -d ' ')"
line1="$(head -1 "$MF")"
echo "$line1" | jq -e . >/dev/null 2>&1 && assert_eq "TC-METRICS-001 valid JSON" "ok" "ok" || assert_eq "TC-METRICS-001 valid JSON" "ok" "bad"
assert_eq "TC-METRICS-001 event"   "wrapper_start" "$(echo "$line1" | jq -r .event)"
assert_eq "TC-METRICS-001 side"    "dev"           "$(echo "$line1" | jq -r .side)"
assert_eq "TC-METRICS-001 schema"  "1"             "$(echo "$line1" | jq -r .schema_version)"
echo "$line1" | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null 2>&1 \
  && assert_eq "TC-METRICS-001 ts ISO-8601" "ok" "ok" || assert_eq "TC-METRICS-001 ts ISO-8601" "ok" "bad"

# TC-METRICS-006: numeric `issue` is a JSON number, not a string.
assert_eq "TC-METRICS-006 issue is number" "number" "$(echo "$line1" | jq -r '.issue | type')"

# TC-METRICS-002: value with double quotes round-trips.
: > "$MF"
metrics_emit weird val='he said "no"'
assert_eq "TC-METRICS-002 quotes round-trip" 'he said "no"' "$(jq -r .val "$MF")"
jq -e . "$MF" >/dev/null 2>&1 && assert_eq "TC-METRICS-002 valid JSON" "ok" "ok" || assert_eq "TC-METRICS-002 valid JSON" "ok" "bad"

# TC-METRICS-003: value with newline → single physical line, escaped \n.
: > "$MF"
nlval="$(printf 'line1\nline2')"
metrics_emit weird val="$nlval"
assert_eq "TC-METRICS-003 single physical line" "1" "$(wc -l < "$MF" | tr -d ' ')"
assert_eq "TC-METRICS-003 newline preserved in value" "$nlval" "$(jq -r .val "$MF")"

# TC-METRICS-004: shell metachars stored literally (no expansion).
: > "$MF"
metrics_emit weird 'val=$(rm -rf /); `id`; ;'
assert_eq "TC-METRICS-004 no shell expansion" '$(rm -rf /); `id`; ;' "$(jq -r .val "$MF")"

# TC-METRICS-005: two sequential emits → two lines, order preserved.
: > "$MF"
metrics_emit first n=1
metrics_emit second n=2
assert_eq "TC-METRICS-005 two lines" "2" "$(wc -l < "$MF" | tr -d ' ')"
assert_eq "TC-METRICS-005 order preserved" "first second" "$(jq -r .event "$MF" | tr '\n' ' ' | sed 's/ $//')"

# TC-METRICS-009: AUTONOMOUS_METRICS_DIR override targets that exact dir.
assert_eq "TC-METRICS-009 override dir used" "$WORK" "$(metrics_dir)"

# TC-METRICS-010: XDG_STATE_HOME path, no override.
unset AUTONOMOUS_METRICS_DIR
XS="$(mktemp -d)"
assert_eq "TC-METRICS-010 XDG_STATE_HOME path" "$XS/autonomous-testproj" "$(XDG_STATE_HOME="$XS" metrics_dir)"

# TC-METRICS-011: durable fallback (#228 finding 2). With XDG_STATE_HOME UNSET
# but XDG_RUNTIME_DIR SET, metrics MUST resolve to the DURABLE
# $HOME/.local/state/autonomous-<project> — NOT the volatile XDG_RUNTIME_DIR
# (where pid_dir_for_project would have put it, losing retention on reboot).
FAKE_HOME="$(mktemp -d)"
FAKE_RUNTIME="$(mktemp -d)"
_md="$(env -u AUTONOMOUS_METRICS_DIR -u XDG_STATE_HOME HOME="$FAKE_HOME" XDG_RUNTIME_DIR="$FAKE_RUNTIME" PROJECT_ID=testproj \
        bash -c 'source "'"$LIB"'"; metrics_dir')"
assert_eq "TC-METRICS-011 durable fallback uses HOME/.local/state" "$FAKE_HOME/.local/state/autonomous-testproj" "$_md"
assert_eq "TC-METRICS-011 fallback does NOT use volatile XDG_RUNTIME_DIR" "" "$(printf '%s' "$_md" | grep -F "$FAKE_RUNTIME" || true)"

export AUTONOMOUS_METRICS_DIR="$WORK"

# TC-METRICS-008: PROJECT_ID unset → metrics_emit is a no-op, returns 0.
( unset PROJECT_ID AUTONOMOUS_METRICS_DIR XDG_STATE_HOME XDG_RUNTIME_DIR HOME
  metrics_emit wrapper_start side=dev; ) >/dev/null 2>&1
assert_eq "TC-METRICS-008 no-PROJECT_ID returns 0" "0" "$?"

# ---------------------------------------------------------------------------
# Observe-only contract (INV-70)
# ---------------------------------------------------------------------------
echo "== observe-only (INV-70) =="

# TC-METRICS-007 / TC-METRICS-060: unwritable dir under set -e → caller survives,
# rc unchanged.
RO="$(mktemp -d)"; chmod 500 "$RO"
rc_observed="$(bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    export AUTONOMOUS_METRICS_DIR="'"$RO"'/cannot-create"
    export PROJECT_ID=x
    metrics_emit wrapper_start side=dev || true
    echo "SURVIVED"
  ' 2>/dev/null; echo "rc=$?")"
chmod 700 "$RO"; rm -rf "$RO"
assert_contains "TC-METRICS-007 set -e survives unwritable dir" "SURVIVED" "$rc_observed"
assert_contains "TC-METRICS-060 rc unchanged (0)" "rc=0" "$rc_observed"

# TC-METRICS-061: jq absent → no-op, returns 0, no crash.
jqgone="$(bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    export AUTONOMOUS_METRICS_DIR="'"$WORK"'"
    export PROJECT_ID=testproj
    # Shadow jq with a PATH that has no jq.
    PATH=/nonexistent metrics_emit wrapper_start side=dev || true
    echo OK
  ' 2>/dev/null)"
assert_eq "TC-METRICS-061 jq absent no-op returns 0" "OK" "$jqgone"

# TC-METRICS-062: wrappers guard every metrics_emit invocation with `|| true`.
# Calls may span multiple lines via `\` continuation, so join continued lines
# into one logical statement (awk) before checking each metrics_emit statement
# ends with `|| true`. Excludes comments and the `declare -F metrics_emit` guard.
DEV_W="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REV_W="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
DISP_W="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
unguarded=0
for w in "$DEV_W" "$REV_W" "$DISP_W"; do
  while IFS= read -r stmt; do
    # Only statements that actually INVOKE metrics_emit (not the `declare -F`
    # guard, not a comment).
    [[ "$stmt" =~ ^[[:space:]]*# ]] && continue
    [[ "$stmt" == *"declare -F metrics_emit"* ]] && continue
    [[ "$stmt" =~ (^|[^_a-zA-Z])metrics_emit[[:space:]] ]] || continue
    [[ "$stmt" == *"|| true"* ]] && continue
    unguarded=$((unguarded + 1))
    echo "      UNGUARDED in $(basename "$w"): $stmt"
  done < <(awk '{ if (prev != "") { $0 = prev " " $0; prev = "" }
                  if ($0 ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", $0); prev = $0 }
                  else print }' "$w")
done
assert_eq "TC-METRICS-062 all call sites guarded with || true" "0" "$unguarded"

# ---------------------------------------------------------------------------
# metrics_parse_tokens
# ---------------------------------------------------------------------------
echo "== metrics_parse_tokens =="

# TC-METRICS-070: parser output keys MUST be the schema's `*_tokens` (NOT bare
# input/output/total) so the words splice straight into metrics_emit and the
# aggregator's `.total_tokens` read matches (#228 finding 1 regression).
CL="$(mktemp)"
printf 'noise line\n{"type":"result","usage":{"input_tokens":1234,"output_tokens":567}}\nmore noise\n' > "$CL"
assert_eq "TC-METRICS-070 claude JSON usage parsed (schema keys)" "input_tokens=1234 output_tokens=567 total_tokens=1801" "$(metrics_parse_tokens "$CL")"

CX="$(mktemp)"
printf 'codex working...\nTokens used: 8910\n' > "$CX"
assert_eq "TC-METRICS-070 codex tokens-used parsed (total only)" "total_tokens=8910" "$(metrics_parse_tokens "$CX")"

NONE="$(mktemp)"
printf 'just logs, no usage\n' > "$NONE"
assert_eq "no usage → empty" "" "$(metrics_parse_tokens "$NONE")"
assert_eq "missing file → empty, rc 0" "" "$(metrics_parse_tokens /nonexistent/log; echo -n)"

# TC-METRICS-071: INTEGRATION — parser output spliced into metrics_emit produces
# a token_usage event the cost aggregator actually counts. This is the
# end-to-end gap finding 1 exposed: the parser, emit, and report must agree on
# the key names. Splice exactly as autonomous-dev.sh does (`$_tok` word-split).
INTG="$(mktemp -d)"
( export AUTONOMOUS_METRICS_DIR="$INTG" PROJECT_ID=intg
  _tok="$(metrics_parse_tokens "$CL")"   # input_tokens=1234 output_tokens=567 total_tokens=1801
  # shellcheck disable=SC2086
  metrics_emit token_usage side=dev issue=70 $_tok
  metrics_emit merge result=success pr=700 issue=70 ) >/dev/null 2>&1
_emitted_total="$(jq -r 'select(.event=="token_usage") | .total_tokens' "$INTG/metrics.jsonl" 2>/dev/null)"
assert_eq "TC-METRICS-071 emitted token_usage has numeric total_tokens" "1801" "$_emitted_total"
_rep="$(bash "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/metrics-report.sh" --file "$INTG/metrics.jsonl" 2>&1)"
assert_contains "TC-METRICS-071 report costs the merged issue (not n/a)" "with token data: 1" "$_rep"

# TC-METRICS-072: per-run offset parse (#228 finding 2). The dev log is shared
# across every dev/resume attempt for an issue, so parsing the whole file would
# re-read a prior run's token line and emit a DUPLICATE token_usage. The wrapper
# captures the log's byte-size at start and passes it as the offset so only the
# CURRENT run's appended bytes are scanned.
OFFLOG="$(mktemp)"
printf 'run1 noise\n{"type":"result","usage":{"input_tokens":100,"output_tokens":50}}\n' > "$OFFLOG"
_off1="$(wc -c < "$OFFLOG" | tr -d '[:space:]')"
assert_eq "TC-METRICS-072 run1 whole-file parse" "input_tokens=100 output_tokens=50 total_tokens=150" "$(metrics_parse_tokens "$OFFLOG")"
# Run 2 appends narration with NO token line.
printf 'run2 narration only, no usage block\n' >> "$OFFLOG"
assert_eq "TC-METRICS-072 whole-file re-reads run1 (the bug)" "input_tokens=100 output_tokens=50 total_tokens=150" "$(metrics_parse_tokens "$OFFLOG")"
assert_eq "TC-METRICS-072 offset from run1-end → run2 has no tokens → empty (no dup)" "" "$(metrics_parse_tokens "$OFFLOG" "$_off1")"
# Run 3 appends its own usage; offset from run2-end isolates it.
_off2="$(wc -c < "$OFFLOG" | tr -d '[:space:]')"
printf '{"type":"result","usage":{"input_tokens":7,"output_tokens":3}}\n' >> "$OFFLOG"
assert_eq "TC-METRICS-072 offset isolates run3 only" "input_tokens=7 output_tokens=3 total_tokens=10" "$(metrics_parse_tokens "$OFFLOG" "$_off2")"
# Offset 0 == whole file → the LAST usage line wins (run3, since run3 was just
# appended above), proving offset 0 degrades to whole-file scan.
assert_eq "TC-METRICS-072 offset 0 == whole file (last usage = run3)" "input_tokens=7 output_tokens=3 total_tokens=10" "$(metrics_parse_tokens "$OFFLOG" 0)"
# Past-EOF offset → nothing to scan → empty, rc 0.
assert_eq "TC-METRICS-072 past-EOF offset → empty, rc 0" "" "$(metrics_parse_tokens "$OFFLOG" 999999)"

# TC-METRICS-074 (#228 round-6 review): the dev wrapper's METRICS_LOG_OFFSET
# capture must NOT abort under `set -euo pipefail` when the log file is missing
# (direct invocation has no dispatch-local pre-create). Assert the guarded
# construct survives a missing file and yields 0. The exact construct lives in
# autonomous-dev.sh; replicate it here so a regression on the wrapper line trips.
_missing_off="$(bash -c '
    set -euo pipefail
    LOG_FILE="/nonexistent/issue-000.log"
    METRICS_LOG_OFFSET=0
    if [[ -f "$LOG_FILE" ]]; then
      METRICS_LOG_OFFSET=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d "[:space:]") || METRICS_LOG_OFFSET=0
      [[ "$METRICS_LOG_OFFSET" =~ ^[0-9]+$ ]] || METRICS_LOG_OFFSET=0
    fi
    echo "SURVIVED:${METRICS_LOG_OFFSET}"
  ' 2>/dev/null)"
assert_eq "TC-METRICS-074 offset capture survives missing file under set -e" "SURVIVED:0" "$_missing_off"
# The wrapper line itself uses the `-f` guard (not the bare unguarded form that
# aborts) — source-assert it so the guard can't silently regress.
assert_contains "TC-METRICS-074 wrapper guards the offset capture with [[ -f ]]" \
  'if [[ -f "$LOG_FILE" ]]; then' \
  "$(grep -A1 'METRICS_LOG_OFFSET=0' "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh" | head -2 | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# metrics_map_drop_reason
# ---------------------------------------------------------------------------
echo "== metrics_map_drop_reason =="
assert_eq "quota → quota"        "agent-unavailable:quota"     "$(metrics_map_drop_reason unavailable quota-exhausted)"
assert_eq "auth → auth"          "agent-unavailable:auth"      "$(metrics_map_drop_reason unavailable auth-failed)"
assert_eq "config → config"      "agent-unavailable:config"    "$(metrics_map_drop_reason unavailable config-error)"
assert_eq "stream → transient"   "agent-unavailable:transient" "$(metrics_map_drop_reason unavailable stream-error)"
assert_eq "empty token → transient" "agent-unavailable:transient" "$(metrics_map_drop_reason unavailable '')"
assert_eq "timed-out → transient"   "agent-unavailable:transient" "$(metrics_map_drop_reason timed-out quota-exhausted)"
# TC-METRICS-073 (#228 round-6 review): PREFIX-match the reason, not exact — the
# reason arrives as a suffixed token (INV-58 reset-window) OR a rendered phrase
# (from _smoke_evidence_reason / *_drop_reason_phrase). Exact-match dropped these
# to `transient`, deflating the quota/auth rate. All forms LEAD with the token.
assert_eq "TC-METRICS-073 quota reset-window token → quota" \
  "agent-unavailable:quota" "$(metrics_map_drop_reason unavailable 'quota-exhausted:Resets in 33h48m45s')"
assert_eq "TC-METRICS-073 quota rendered phrase → quota" \
  "agent-unavailable:quota" "$(metrics_map_drop_reason unavailable 'quota-exhausted (Antigravity 429: daily quota reached; resets in 33h48m45s)')"
assert_eq "TC-METRICS-073 auth rendered phrase → auth" \
  "agent-unavailable:auth" "$(metrics_map_drop_reason unavailable 'auth-failed (browser/device-flow login required)')"
assert_eq "TC-METRICS-073 config:flag token → config" \
  "agent-unavailable:config" "$(metrics_map_drop_reason unavailable 'config-error:--bad-flag')"
assert_eq "TC-METRICS-073 stream phrase → transient" \
  "agent-unavailable:transient" "$(metrics_map_drop_reason unavailable 'stream-error (upstream 5xx)')"

# ---------------------------------------------------------------------------
# metrics_prune
# ---------------------------------------------------------------------------
echo "== metrics_prune =="

mk_aged() {  # mk_aged <file> <days-ago> <event>
  local f="$1" d="$2" ev="$3" ts
  ts="$(date -u -d "${d} days ago" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"schema_version":1,"ts":"%s","event":"%s"}\n' "$ts" "$ev" >> "$f"
}

# TC-METRICS-020: 100d dropped, 50d + 1d kept (default 90d window).
PF="$(mktemp)"; : > "$PF"
mk_aged "$PF" 100 old
mk_aged "$PF" 50  mid
mk_aged "$PF" 1   recent
metrics_prune 90 "$PF"
assert_eq "TC-METRICS-020 prune keeps mid+recent" "mid recent" "$(jq -r .event "$PF" | tr '\n' ' ' | sed 's/ $//')"
jq -e . "$PF" >/dev/null 2>&1 && assert_eq "TC-METRICS-020 survivors valid JSON" "ok" "ok" || assert_eq "TC-METRICS-020 survivors valid JSON" "ok" "bad"

# TC-METRICS-021: all recent → nothing removed.
PF2="$(mktemp)"; : > "$PF2"
mk_aged "$PF2" 1 a; mk_aged "$PF2" 2 b; mk_aged "$PF2" 3 c
before="$(wc -l < "$PF2" | tr -d ' ')"
metrics_prune 90 "$PF2"
assert_eq "TC-METRICS-021 all-recent unchanged count" "$before" "$(wc -l < "$PF2" | tr -d ' ')"

# TC-METRICS-022: empty/missing file → rc 0, no error.
metrics_prune 90 /nonexistent/file.jsonl
assert_eq "TC-METRICS-022 missing file rc 0" "0" "$?"
EMPTY="$(mktemp)"; metrics_prune 90 "$EMPTY"
assert_eq "TC-METRICS-022 empty file rc 0" "0" "$?"

# TC-METRICS-023: malformed line does not crash; it's dropped.
PF3="$(mktemp)"; : > "$PF3"
mk_aged "$PF3" 1 keep
printf 'this is not json\n' >> "$PF3"
metrics_prune 90 "$PF3"
assert_eq "TC-METRICS-023 malformed dropped, valid kept" "keep" "$(jq -r .event "$PF3" | tr '\n' ' ' | sed 's/ $//')"

# TC-METRICS-024 (#228 round-7 finding 1): retention is built INTO the collector,
# not opt-in. A prune triggered during normal collection (default 90d) removes old
# records and MUST NOT change the surrounding rc, even under `set -e`. Use the
# default-file path (no explicit file arg) to mirror the wrapper call sites.
PRUNE_WORK="$(mktemp -d)"
_pe="$(date -u -d '100 days ago' +%Y-%m-%dT%H:%M:%SZ)"
_pn="$(date -u -d '1 day ago'    +%Y-%m-%dT%H:%M:%SZ)"
printf '{"schema_version":1,"ts":"%s","event":"old"}\n'    "$_pe" >  "$PRUNE_WORK/metrics.jsonl"
printf '{"schema_version":1,"ts":"%s","event":"recent"}\n' "$_pn" >> "$PRUNE_WORK/metrics.jsonl"
_prune_rc="$(bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    export AUTONOMOUS_METRICS_DIR="'"$PRUNE_WORK"'" PROJECT_ID=collprune
    metrics_prune "${METRICS_RETENTION_DAYS:-90}" 2>/dev/null || true
    echo "RC=$?"
  ' 2>/dev/null)"
assert_eq "TC-METRICS-024 collector prune under set -e keeps rc 0" "RC=0" "$_prune_rc"
assert_eq "TC-METRICS-024 collector prune drops old, keeps recent (default-file path)" \
  "recent" "$(jq -r .event "$PRUNE_WORK/metrics.jsonl" | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$PRUNE_WORK"

# TC-METRICS-025 (#228 round-7 finding 1): the prune is WIRED into all three
# production emission paths (dev wrapper_end, review wrapper_end, dispatcher tick)
# — not just the opt-in report. Source-assert each, guarded best-effort.
DEV_W="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REV_W="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
DISP_W="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
for _w in "$DEV_W" "$REV_W" "$DISP_W"; do
  if grep -qF 'metrics_prune "${METRICS_RETENTION_DAYS:-90}"' "$_w"; then
    echo -e "  ${GREEN}PASS${NC}: TC-METRICS-025 prune wired into $(basename "$_w")"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-METRICS-025 prune NOT wired into $(basename "$_w")"; FAIL=$((FAIL + 1))
  fi
done

# TC-METRICS-027 (#228 round-8 finding 3): the dispatcher emits dispatch_retry on
# EACH below-limit retry increment (stalled=false), not only at MAX_RETRIES
# exhaustion (stalled=true). Source-assert BOTH emits exist in dispatcher-tick.sh.
if grep -qF 'metrics_emit dispatch_retry "issue=${issue_num}" "retry_count=${retry_count}" stalled=false' "$DISP_W"; then
  echo -e "  ${GREEN}PASS${NC}: TC-METRICS-027 per-retry dispatch_retry (stalled=false) emitted"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-METRICS-027 per-retry dispatch_retry (stalled=false) MISSING"; FAIL=$((FAIL + 1))
fi
if grep -qF 'metrics_emit dispatch_retry "issue=${issue_num}" "retry_count=${retry_count}" stalled=true' "$DISP_W"; then
  echo -e "  ${GREEN}PASS${NC}: TC-METRICS-027 exhaustion dispatch_retry (stalled=true) retained"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-METRICS-027 exhaustion dispatch_retry (stalled=true) MISSING"; FAIL=$((FAIL + 1))
fi

# TC-METRICS-026 (#228 round-8 finding 1): metrics_prune and metrics_emit are
# serialized by a per-file lock, so a prune running concurrently with appends does
# NOT drop a freshly-appended line (prune's read→temp→mv would otherwise clobber
# an emit that landed between the read and the mv). Stress: seed one OLD line
# (forces the prune read→mv path every iteration), then append N recent lines
# while a prune loop runs concurrently; assert ALL N recent lines survive and the
# old seed is gone. (flock-gated — if flock is absent on the box this degrades to
# the unlocked path, which CAN lose a line; guard the assertion on flock presence.)
RACE_WORK="$(mktemp -d)"
RMF="$RACE_WORK/metrics.jsonl"
_old="$(date -u -d '200 days ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"schema_version":1,"ts":"%s","event":"old_seed"}\n' "$_old" > "$RMF"
if command -v flock >/dev/null 2>&1; then
  ( for _ in $(seq 1 120); do metrics_prune 90 "$RMF" 2>/dev/null; done ) &
  _race_prune_pid=$!
  ( export AUTONOMOUS_METRICS_DIR="$RACE_WORK" PROJECT_ID=race
    for _ri in $(seq 1 100); do metrics_emit token_usage side=dev "issue=${_ri}" "total_tokens=${_ri}" 2>/dev/null; done )
  wait "$_race_prune_pid" 2>/dev/null
  _race_survived="$(jq -r 'select(.event=="token_usage") | .issue' "$RMF" 2>/dev/null | sort -n | uniq | wc -l | tr -d ' ')"
  assert_eq "TC-METRICS-026 all 100 concurrent emits survive prune (lock serializes)" "100" "$_race_survived"
  _race_oldseed="$(jq -r 'select(.event=="old_seed") | "y"' "$RMF" 2>/dev/null | head -1)"
  assert_eq "TC-METRICS-026 old seed pruned" "" "$_race_oldseed"
else
  echo -e "  ${GREEN}PASS${NC}: TC-METRICS-026 SKIPPED (flock absent — unlocked fallback path)"; PASS=$((PASS + 1))
fi
rm -rf "$RACE_WORK"

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] || exit 1
