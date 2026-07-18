#!/bin/bash
# test-lib-accounting.sh — issue #505 / INV-139.
#
# Covers lib-accounting.sh: identity construction (D3), strict idempotent
# commit (D5), lifecycle states (D4), locked full-scan query + rebuildable
# projection cache (D2), reconciliation proof-of-death (D6), and the
# metrics isolation + production-ingress choke-point guards.
# Test IDs: TC-RESOURCEACCOUNT-001..080.
#
# Isolation (tests/unit/README.md): every path this test touches is under a
# fresh mktemp -d ($WORK), namespaced per invocation — safe to run
# concurrently with any sibling test.
#
# Run: bash tests/unit/test-lib-accounting.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-accounting.sh"

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
assert_ne() {
  local desc="$1" a="$2" b="$3"
  if [[ "$a" != "$b" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      both='$a'"; FAIL=$((FAIL + 1))
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
assert_absent() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      unexpected path='$path'"; FAIL=$((FAIL + 1))
  fi
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-accounting.sh
source "$LIB"

# ---------------------------------------------------------------------------
# Identity (D3) — TC-RESOURCEACCOUNT-001..006
# ---------------------------------------------------------------------------
echo "== accounting_invocation_id =="

ID1="$(accounting_invocation_id R1 dev dev 1)"
ID1B="$(accounting_invocation_id R1 dev dev 1)"
assert_eq "TC-RESOURCEACCOUNT-001 same tuple -> same id" "$ID1" "$ID1B"
assert_contains "TC-RESOURCEACCOUNT-001 id has inv-v1- prefix" "inv-v1-" "$ID1"

ID2="$(accounting_invocation_id R2 dev dev 1)"
assert_ne "TC-RESOURCEACCOUNT-002 differing run_id -> different id" "$ID1" "$ID2"

ID3="$(accounting_invocation_id R1 review dev 1)"
assert_ne "TC-RESOURCEACCOUNT-003 differing side -> different id" "$ID1" "$ID3"

ID4A="$(accounting_invocation_id R1 review UUID-A 1)"
ID4B="$(accounting_invocation_id R1 review UUID-B 1)"
assert_ne "TC-RESOURCEACCOUNT-004 same-named members, different UUIDs -> different id" "$ID4A" "$ID4B"

ID5="$(accounting_invocation_id R1 dev dev 2)"
assert_ne "TC-RESOURCEACCOUNT-005 incremented attempt -> different id" "$ID1" "$ID5"

RO_DIR="$(mktemp -d)"
chmod 500 "$RO_DIR"
ID6="$(AUTONOMOUS_ACCOUNTING_DIR="$RO_DIR/nope" accounting_invocation_id R1 dev dev 1 2>/dev/null)"
assert_eq "TC-RESOURCEACCOUNT-006 construction is pure (no store I/O)" "$ID1" "$ID6"
chmod 700 "$RO_DIR"; rm -rf "$RO_DIR"

accounting_invocation_id R1 invalid dev 1 >/dev/null 2>&1
assert_ne "TC-RESOURCEACCOUNT-007 invalid identity side is rejected" "0" "$?"
accounting_invocation_id R1 dev not-dev 1 >/dev/null 2>&1
assert_ne "TC-RESOURCEACCOUNT-007 dev identity requires literal member_id=dev" "0" "$?"
accounting_invocation_id R1 dev dev 0 >/dev/null 2>&1
assert_ne "TC-RESOURCEACCOUNT-007 non-positive identity attempt is rejected" "0" "$?"

# ---------------------------------------------------------------------------
# Strict idempotent commit (D5) — TC-RESOURCEACCOUNT-010..015
# ---------------------------------------------------------------------------
echo "== accounting_commit_usage =="

WORK="$(mktemp -d)"
export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
export PROJECT_ID="acctproj"
ISSUE=100

X="$(accounting_invocation_id RUN1 dev dev 1)"
accounting_start "$ISSUE" "$X" dev RUN1 dev 1 >/dev/null
accounting_commit_usage "$ISSUE" "$X" 100 60 40
assert_eq "TC-RESOURCEACCOUNT-010 first commit succeeds" "0" "$?"
REC_FILE="${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE}/${X}.json"
assert_eq "TC-RESOURCEACCOUNT-010 record is terminal usage-committed" "usage-committed" "$(jq -r .state "$REC_FILE")"
assert_eq "TC-RESOURCEACCOUNT-010 total_tokens=100" "100" "$(jq -r .total_tokens "$REC_FILE")"

NO_WRITE_MARKER="$WORK/identical-replay-called-writer"
(
  source "$LIB"
  _accounting_write_atomic() {
    : > "$NO_WRITE_MARKER"
    return 97
  }
  accounting_commit_usage "$ISSUE" "$X" 100 60 40
)
assert_eq "TC-RESOURCEACCOUNT-011 identical-duplicate commit succeeds" "0" "$?"
assert_absent "TC-RESOURCEACCOUNT-011 identical-duplicate never calls the atomic writer" "$NO_WRITE_MARKER"

accounting_commit_usage "$ISSUE" "$X" 200 - - 2>"$WORK/conflict-err.txt"
assert_ne "TC-RESOURCEACCOUNT-012 conflicting-duplicate commit rejected" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-012 conflicting-duplicate performs no mutation" "100" "$(jq -r .total_tokens "$REC_FILE")"
assert_contains "TC-RESOURCEACCOUNT-012 loud stderr on conflict" "conflicting duplicate" "$(cat "$WORK/conflict-err.txt")"
rm -f "$WORK/conflict-err.txt"

(
  export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
  export PROJECT_ID="acctproj"
  source "$LIB"
  accounting_commit_usage "$ISSUE" "$X" 100 60 40
)
assert_eq "TC-RESOURCEACCOUNT-013 idempotency survives a simulated restart" "0" "$?"

WRITE_FAIL="$(accounting_invocation_id RUN1 dev dev 99)"
accounting_start "$ISSUE" "$WRITE_FAIL" dev RUN1 dev 99 >/dev/null
(
  source "$LIB"
  _accounting_write_atomic() {
    return 97
  }
  accounting_commit_usage "$ISSUE" "$WRITE_FAIL" 5 2>"$WORK/write-fail-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-014 write failure is loud (rc!=0)" "0" "$?"
assert_contains "TC-RESOURCEACCOUNT-014 write failure reaches stderr" "accounting_commit_usage" "$(cat "$WORK/write-fail-err.txt")"
assert_eq "TC-RESOURCEACCOUNT-014 failed commit leaves started record unchanged" "started" \
  "$(jq -r .state "${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE}/${WRITE_FAIL}.json")"

Y="$(accounting_invocation_id RUN1 dev dev 2)"
accounting_start "$ISSUE" "$Y" dev RUN1 dev 2 >/dev/null
accounting_commit_unknown "$ISSUE" "$Y" "dead-pid"
assert_eq "TC-RESOURCEACCOUNT-015 commit_unknown succeeds" "0" "$?"
YREC="${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE}/${Y}.json"
assert_eq "TC-RESOURCEACCOUNT-015 record is terminal usage-unknown" "usage-unknown" "$(jq -r .state "$YREC")"
assert_eq "TC-RESOURCEACCOUNT-015 reason recorded" "dead-pid" "$(jq -r .reason "$YREC")"

ISSUE_NONREG=101
NONREG_COMMIT="$(accounting_invocation_id RUN1 dev dev 3)"
NONREG_DIR="$(_accounting_issue_dir "$ISSUE_NONREG")/${NONREG_COMMIT}.json"
mkdir "$NONREG_DIR"
accounting_commit_usage "$ISSUE_NONREG" "$NONREG_COMMIT" 5 2>"$WORK/nonregular-commit-err.txt"
assert_ne "TC-RESOURCEACCOUNT-016 commit rejects a directory record target" "0" "$?"
assert_contains "TC-RESOURCEACCOUNT-016 rejection is loud" "non-regular" "$(cat "$WORK/nonregular-commit-err.txt")"
assert_eq "TC-RESOURCEACCOUNT-016 target remains an empty directory" "0" \
  "$(find "$NONREG_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

ISSUE_NONREG_START=102
NONREG_START="$(accounting_invocation_id RUN1 dev dev 4)"
NONREG_START_DIR="$(_accounting_issue_dir "$ISSUE_NONREG_START")/${NONREG_START}.json"
mkdir "$NONREG_START_DIR"
accounting_start "$ISSUE_NONREG_START" "$NONREG_START" dev RUN1 dev 4 2>"$WORK/nonregular-start-err.txt"
assert_ne "TC-RESOURCEACCOUNT-017 start rejects a directory record target" "0" "$?"
assert_contains "TC-RESOURCEACCOUNT-017 start rejection is loud" "non-regular" "$(cat "$WORK/nonregular-start-err.txt")"
assert_eq "TC-RESOURCEACCOUNT-017 target directory remains untouched" "0" \
  "$(find "$NONREG_START_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

ESCAPE_TARGET="${AUTONOMOUS_ACCOUNTING_DIR}/escaped.json"
accounting_start "$ISSUE" "../escaped" dev RUN1 dev 1 2>"$WORK/path-traversal-err.txt"
assert_ne "TC-RESOURCEACCOUNT-008 path-like invocation id is rejected" "0" "$?"
assert_absent "TC-RESOURCEACCOUNT-008 path traversal writes no sibling file" "$ESCAPE_TARGET"

MISMATCH_ID="$(accounting_invocation_id RUN-TUPLE-A dev dev 1)"
accounting_start 103 "$MISMATCH_ID" dev RUN-TUPLE-B dev 1 2>"$WORK/tuple-mismatch-start-err.txt"
assert_ne "TC-RESOURCEACCOUNT-008 start rejects id/tuple mismatch" "0" "$?"
assert_absent "TC-RESOURCEACCOUNT-008 tuple mismatch creates no record" \
  "${AUTONOMOUS_ACCOUNTING_DIR}/103/${MISMATCH_ID}.json"

for api_call in \
  "accounting_invocation_id" \
  "accounting_start" \
  "accounting_commit_usage" \
  "accounting_commit_unknown" \
  "accounting_reconcile" \
  "accounting_ack_unknown" \
  "accounting_admission_query"; do
  API_OUT="$( (set -u; "$api_call") 2>&1)"
  API_RC=$?
  assert_ne "TC-RESOURCEACCOUNT-009 ${api_call} missing args returns nonzero under set -u" "0" "$API_RC"
  assert_contains "TC-RESOURCEACCOUNT-009 ${api_call} missing args is loud" "$api_call" "$API_OUT"
done

MISSING_STARTED="$(accounting_invocation_id RUN-MISSING dev dev 1)"
accounting_commit_usage 104 "$MISSING_STARTED" 1 2>"$WORK/missing-started-usage-err.txt"
assert_ne "TC-RESOURCEACCOUNT-018 usage commit requires started record" "0" "$?"
accounting_commit_unknown 104 "$MISSING_STARTED" "missing" 2>"$WORK/missing-started-unknown-err.txt"
assert_ne "TC-RESOURCEACCOUNT-018 unknown commit requires started record" "0" "$?"
assert_absent "TC-RESOURCEACCOUNT-018 missing start creates no terminal record" \
  "${AUTONOMOUS_ACCOUNTING_DIR}/104/${MISSING_STARTED}.json"

accounting_commit_usage "$ISSUE" "$X" 100 060 40 2>"$WORK/noncanonical-token-err.txt"
assert_ne "TC-RESOURCEACCOUNT-019 leading-zero token count is rejected" "0" "$?"
assert_contains "TC-RESOURCEACCOUNT-019 invalid numeric spelling is diagnosed before conflict" \
  "non-negative integer" "$(cat "$WORK/noncanonical-token-err.txt")"
assert_eq "TC-RESOURCEACCOUNT-019 invalid replay leaves total unchanged" "100" "$(jq -r .total_tokens "$REC_FILE")"

accounting_commit_usage "$ISSUE" "$X" 100000000000000000000 2>"$WORK/oversized-token-err.txt"
assert_ne "TC-RESOURCEACCOUNT-019 oversized token count is rejected" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-019 oversized replay leaves total unchanged" "100" "$(jq -r .total_tokens "$REC_FILE")"

ISSUE_SYNC_FAIL=105
SYNC_FAIL_ID="$(accounting_invocation_id RUNSYNC dev dev 1)"
accounting_start "$ISSUE_SYNC_FAIL" "$SYNC_FAIL_ID" dev RUNSYNC dev 1 >/dev/null
(
  source "$LIB"
  _accounting_sync_file() {
    return 97
  }
  accounting_commit_usage "$ISSUE_SYNC_FAIL" "$SYNC_FAIL_ID" 9 2>"$WORK/sync-fail-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-028 sync failure is propagated" "0" "$?"
assert_contains "TC-RESOURCEACCOUNT-028 sync failure is loud" "sync" "$(cat "$WORK/sync-fail-err.txt")"
assert_eq "TC-RESOURCEACCOUNT-028 sync failure leaves started record unchanged" "started" \
  "$(jq -r .state "${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE_SYNC_FAIL}/${SYNC_FAIL_ID}.json")"

ISSUE_DIR_SYNC=106
DIR_SYNC_USAGE="$(accounting_invocation_id RUNDIRSYNC dev dev 1)"
accounting_start "$ISSUE_DIR_SYNC" "$DIR_SYNC_USAGE" dev RUNDIRSYNC dev 1 >/dev/null
(
  source "$LIB"
  _accounting_sync_dir() {
    return 97
  }
  accounting_commit_usage "$ISSUE_DIR_SYNC" "$DIR_SYNC_USAGE" 11 2>"$WORK/dir-sync-usage-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-028 post-rename usage directory-sync failure is propagated" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-028 post-rename usage record is installed" "usage-committed" \
  "$(jq -r .state "${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE_DIR_SYNC}/${DIR_SYNC_USAGE}.json")"
accounting_commit_usage "$ISSUE_DIR_SYNC" "$DIR_SYNC_USAGE" 11
assert_eq "TC-RESOURCEACCOUNT-028 identical usage retry confirms durability" "0" "$?"

DIR_SYNC_UNKNOWN="$(accounting_invocation_id RUNDIRSYNC dev dev 2)"
accounting_start "$ISSUE_DIR_SYNC" "$DIR_SYNC_UNKNOWN" dev RUNDIRSYNC dev 2 >/dev/null
UNKNOWN_REASON=$'crash\n'
(
  source "$LIB"
  _accounting_sync_dir() {
    return 97
  }
  accounting_commit_unknown "$ISSUE_DIR_SYNC" "$DIR_SYNC_UNKNOWN" "$UNKNOWN_REASON" 2>"$WORK/dir-sync-unknown-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-028 post-rename unknown directory-sync failure is propagated" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-028 post-rename unknown record is installed" "usage-unknown" \
  "$(jq -r .state "${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE_DIR_SYNC}/${DIR_SYNC_UNKNOWN}.json")"
accounting_commit_unknown "$ISSUE_DIR_SYNC" "$DIR_SYNC_UNKNOWN" "$UNKNOWN_REASON"
assert_eq "TC-RESOURCEACCOUNT-028 identical unknown retry preserves trailing-newline reason" "0" "$?"
accounting_commit_unknown "$ISSUE_DIR_SYNC" "$DIR_SYNC_UNKNOWN" "different" 2>"$WORK/unknown-conflict-err.txt"
assert_ne "TC-RESOURCEACCOUNT-028 conflicting unknown replay is rejected after durability confirmation" "0" "$?"

ISSUE_OVERFLOW=107
OVERFLOW_A="$(accounting_invocation_id RUNOVERFLOW dev dev 1)"
OVERFLOW_B="$(accounting_invocation_id RUNOVERFLOW dev dev 2)"
accounting_start "$ISSUE_OVERFLOW" "$OVERFLOW_A" dev RUNOVERFLOW dev 1 >/dev/null
accounting_commit_usage "$ISSUE_OVERFLOW" "$OVERFLOW_A" 9007199254740991 >/dev/null
accounting_start "$ISSUE_OVERFLOW" "$OVERFLOW_B" dev RUNOVERFLOW dev 2 >/dev/null
accounting_commit_usage "$ISSUE_OVERFLOW" "$OVERFLOW_B" 1 >/dev/null
Q_OVERFLOW="$(accounting_admission_query "$ISSUE_OVERFLOW")"
assert_eq "TC-RESOURCEACCOUNT-019 aggregate overflow is reported as corrupt" "corrupt" \
  "$(jq -r .status <<<"$Q_OVERFLOW")"

ISSUE_CLOCK_START=108
CLOCK_START_ID="$(accounting_invocation_id RUNCLOCK dev dev 1)"
(
  source "$LIB"
  date() {
    return 97
  }
  accounting_start "$ISSUE_CLOCK_START" "$CLOCK_START_ID" dev RUNCLOCK dev 1 2>"$WORK/clock-start-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-049 start propagates clock failure" "0" "$?"
assert_absent "TC-RESOURCEACCOUNT-049 clock failure creates no started record" \
  "${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE_CLOCK_START}/${CLOCK_START_ID}.json"
assert_contains "TC-RESOURCEACCOUNT-049 clock failure is loud" "timestamp" "$(cat "$WORK/clock-start-err.txt")"

ISSUE_CLOCK_COMMIT=109
CLOCK_USAGE_ID="$(accounting_invocation_id RUNCLOCKCOMMIT dev dev 1)"
CLOCK_UNKNOWN_ID="$(accounting_invocation_id RUNCLOCKCOMMIT dev dev 2)"
accounting_start "$ISSUE_CLOCK_COMMIT" "$CLOCK_USAGE_ID" dev RUNCLOCKCOMMIT dev 1 >/dev/null
accounting_start "$ISSUE_CLOCK_COMMIT" "$CLOCK_UNKNOWN_ID" dev RUNCLOCKCOMMIT dev 2 >/dev/null
(
  source "$LIB"
  _accounting_now() {
    echo "_accounting_now: injected timestamp failure" >&2
    return 97
  }
  accounting_commit_usage "$ISSUE_CLOCK_COMMIT" "$CLOCK_USAGE_ID" 1 2>"$WORK/clock-usage-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-049 usage commit propagates clock failure" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-049 failed usage timestamp leaves started record" "started" \
  "$(jq -r .state "${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE_CLOCK_COMMIT}/${CLOCK_USAGE_ID}.json")"
(
  source "$LIB"
  _accounting_now() {
    echo "_accounting_now: injected timestamp failure" >&2
    return 97
  }
  accounting_commit_unknown "$ISSUE_CLOCK_COMMIT" "$CLOCK_UNKNOWN_ID" "clock" 2>"$WORK/clock-unknown-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-049 unknown commit propagates clock failure" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-049 failed unknown timestamp leaves started record" "started" \
  "$(jq -r .state "${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE_CLOCK_COMMIT}/${CLOCK_UNKNOWN_ID}.json")"

RACE_DIR="$WORK/rename-race"
mkdir -p "$RACE_DIR"
RACE_TARGET="$RACE_DIR/target.json"
(
  source "$LIB"
  mv() {
    local target="${@: -1}"
    mkdir -p "$target"
    command mv "$@"
  }
  _accounting_write_atomic "$RACE_DIR" "$RACE_TARGET" '{"race":true}' 2>"$WORK/rename-race-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-029 directory-target rename race is rejected" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-029 raced directory contains no consumed temp file" "0" \
  "$(find "$RACE_TARGET" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# Lifecycle (D4) — TC-RESOURCEACCOUNT-020..023
# ---------------------------------------------------------------------------
echo "== lifecycle =="

ISSUE2=200
Z="$(accounting_invocation_id RUN2 dev dev 1)"
accounting_start "$ISSUE2" "$Z" dev RUN2 dev 1 >/dev/null
Q="$(accounting_admission_query "$ISSUE2")"
assert_eq "TC-RESOURCEACCOUNT-020 live started record queries incomplete" "incomplete" "$(jq -r .status <<<"$Q")"
assert_contains "TC-RESOURCEACCOUNT-020 open_invocations contains Z" "$Z" "$(jq -c .open_invocations <<<"$Q")"
assert_eq "TC-RESOURCEACCOUNT-020 unknown_invocations empty" "[]" "$(jq -c .unknown_invocations <<<"$Q")"

A="$(accounting_invocation_id RUN2 dev dev 2)"
B="$(accounting_invocation_id RUN2 dev dev 3)"
accounting_start "$ISSUE2" "$A" dev RUN2 dev 2 >/dev/null
accounting_start "$ISSUE2" "$B" dev RUN2 dev 3 >/dev/null
accounting_commit_unknown "$ISSUE2" "$B" "manual-test" >/dev/null
Q2="$(accounting_admission_query "$ISSUE2")"
assert_contains "TC-RESOURCEACCOUNT-021 A stays open (incomplete)" "$A" "$(jq -c .open_invocations <<<"$Q2")"
assert_contains "TC-RESOURCEACCOUNT-021 B is sticky usage-unknown" "$B" "$(jq -c .unknown_invocations <<<"$Q2")"
Q3="$(accounting_admission_query "$ISSUE2")"
assert_eq "TC-RESOURCEACCOUNT-021 re-query without mutation leaves A open" "$(jq -c .open_invocations <<<"$Q2")" "$(jq -c .open_invocations <<<"$Q3")"

ISSUE_UNAVAIL=201
(
  export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
  export PROJECT_ID="acctproj"
  source "$LIB"
  ACCOUNTING_LOCK_WAIT_SECONDS=0
  DIR="$(_accounting_issue_dir "$ISSUE_UNAVAIL")"
  exec 8>>"${DIR}/.lock"
  flock 8
  QU="$(accounting_admission_query "$ISSUE_UNAVAIL" 2>/dev/null)"
  RC=$?
  echo "$QU" > "$WORK/unavail-out.txt"
  echo "$RC" > "$WORK/unavail-rc.txt"
)
assert_eq "TC-RESOURCEACCOUNT-022 lock contention yields unavailable" "unavailable" "$(jq -r .status < "$WORK/unavail-out.txt")"
assert_ne "TC-RESOURCEACCOUNT-022 unavailable query returns rc!=0" "0" "$(cat "$WORK/unavail-rc.txt")"
rm -f "$WORK/unavail-out.txt" "$WORK/unavail-rc.txt"

ISSUE3=202
C="$(accounting_invocation_id RUN3 dev dev 1)"
accounting_start "$ISSUE3" "$C" dev RUN3 dev 1 >/dev/null
accounting_commit_usage "$ISSUE3" "$C" 30 >/dev/null
CDIR="$(_accounting_issue_dir "$ISSUE3")"
printf 'not valid json{{{' > "${CDIR}/bogus-corrupt.json"
Q4="$(accounting_admission_query "$ISSUE3")"
assert_eq "TC-RESOURCEACCOUNT-023 malformed record yields corrupt status" "corrupt" "$(jq -r .status <<<"$Q4")"
assert_eq "TC-RESOURCEACCOUNT-023 corrupt file left untouched" "not valid json{{{" "$(cat "${CDIR}/bogus-corrupt.json")"
assert_eq "TC-RESOURCEACCOUNT-023 valid record still counted" "30" "$(jq -r .total_tokens <<<"$Q4")"

ISSUE_ENVELOPE=203
ENV_VALID="$(accounting_invocation_id RUNENV dev dev 1)"
accounting_start "$ISSUE_ENVELOPE" "$ENV_VALID" dev RUNENV dev 1 >/dev/null
accounting_commit_usage "$ISSUE_ENVELOPE" "$ENV_VALID" 40 >/dev/null
ENV_DIR="$(_accounting_issue_dir "$ISSUE_ENVELOPE")"
ENV_FILE="${ENV_DIR}/${ENV_VALID}.json"
ENV_ORIGINAL="$(cat "$ENV_FILE")"

jq '.schema_version = 999' <<<"$ENV_ORIGINAL" > "$ENV_FILE"
Q_ENV_SCHEMA="$(accounting_admission_query "$ISSUE_ENVELOPE")"
assert_eq "TC-RESOURCEACCOUNT-024a schema mismatch yields corrupt" "corrupt" "$(jq -r .status <<<"$Q_ENV_SCHEMA")"
assert_eq "TC-RESOURCEACCOUNT-024a schema mismatch contributes no tokens" "0" "$(jq -r .total_tokens <<<"$Q_ENV_SCHEMA")"

jq '.issue = 999999' <<<"$ENV_ORIGINAL" > "$ENV_FILE"
Q_ENV_ISSUE="$(accounting_admission_query "$ISSUE_ENVELOPE")"
assert_eq "TC-RESOURCEACCOUNT-024b issue mismatch yields corrupt" "corrupt" "$(jq -r .status <<<"$Q_ENV_ISSUE")"

jq '.invocation_id = "inv-v1-000000000000000000000000"' <<<"$ENV_ORIGINAL" > "$ENV_FILE"
Q_ENV_ID="$(accounting_admission_query "$ISSUE_ENVELOPE")"
assert_eq "TC-RESOURCEACCOUNT-024c filename/id mismatch yields corrupt" "corrupt" "$(jq -r .status <<<"$Q_ENV_ID")"

jq 'del(.total_tokens)' <<<"$ENV_ORIGINAL" > "$ENV_FILE"
Q_ENV_STATE="$(accounting_admission_query "$ISSUE_ENVELOPE")"
assert_eq "TC-RESOURCEACCOUNT-024d missing committed total yields corrupt" "corrupt" "$(jq -r .status <<<"$Q_ENV_STATE")"
assert_eq "TC-RESOURCEACCOUNT-024 invalid envelope is never rewritten" \
  "$(jq -cS 'del(.total_tokens)' <<<"$ENV_ORIGINAL")" "$(jq -cS . "$ENV_FILE")"

ISSUE_PROJ_FAIL=204
PROJ_FAIL_ID="$(accounting_invocation_id RUNPROJFAIL dev dev 1)"
accounting_start "$ISSUE_PROJ_FAIL" "$PROJ_FAIL_ID" dev RUNPROJFAIL dev 1 >/dev/null
accounting_commit_usage "$ISSUE_PROJ_FAIL" "$PROJ_FAIL_ID" 12 >/dev/null
PROJ_FAIL_DIR="$(_accounting_issue_dir "$ISSUE_PROJ_FAIL")"
ln -s "$WORK/projection-escape.json" "${PROJ_FAIL_DIR}/projection.json"
Q_PROJ_FAIL="$(accounting_admission_query "$ISSUE_PROJ_FAIL" 2>"$WORK/projection-fail-err.txt")"
Q_PROJ_FAIL_RC=$?
assert_ne "TC-RESOURCEACCOUNT-025 projection write failure returns rc!=0" "0" "$Q_PROJ_FAIL_RC"
assert_eq "TC-RESOURCEACCOUNT-025 projection write failure yields unavailable" "unavailable" \
  "$(jq -r .status <<<"$Q_PROJ_FAIL")"
assert_contains "TC-RESOURCEACCOUNT-025 projection write failure is loud" "accounting_admission_query" \
  "$(cat "$WORK/projection-fail-err.txt")"
assert_absent "TC-RESOURCEACCOUNT-025 projection symlink target is not written" "$WORK/projection-escape.json"
assert_eq "TC-RESOURCEACCOUNT-025 invocation history remains committed" "usage-committed" \
  "$(jq -r .state "${PROJ_FAIL_DIR}/${PROJ_FAIL_ID}.json")"

ISSUE_READ_FAIL=205
READ_FAIL_ID="$(accounting_invocation_id RUNREADFAIL dev dev 1)"
accounting_start "$ISSUE_READ_FAIL" "$READ_FAIL_ID" dev RUNREADFAIL dev 1 >/dev/null
(
  source "$LIB"
  cat() {
    if [[ "${1-}" == "${AUTONOMOUS_ACCOUNTING_DIR}/${ISSUE_READ_FAIL}/${READ_FAIL_ID}.json" ]]; then
      return 1
    fi
    command cat "$@"
  }
  Q_READ_FAIL="$(accounting_admission_query "$ISSUE_READ_FAIL" 2>"$WORK/read-fail-err.txt")"
  printf '%s\n' "$?" > "$WORK/read-fail-rc.txt"
  printf '%s\n' "$Q_READ_FAIL" > "$WORK/read-fail-out.txt"
)
assert_ne "TC-RESOURCEACCOUNT-026 record read failure returns rc!=0" "0" "$(cat "$WORK/read-fail-rc.txt")"
assert_eq "TC-RESOURCEACCOUNT-026 record read failure yields unavailable" "unavailable" \
  "$(jq -r .status "$WORK/read-fail-out.txt")"

ISSUE_TUPLE_CORRUPT=206
TUPLE_CORRUPT_ID="$(accounting_invocation_id RUNTUPLE dev dev 1)"
accounting_start "$ISSUE_TUPLE_CORRUPT" "$TUPLE_CORRUPT_ID" dev RUNTUPLE dev 1 >/dev/null
TUPLE_CORRUPT_FILE="$(_accounting_issue_dir "$ISSUE_TUPLE_CORRUPT")/${TUPLE_CORRUPT_ID}.json"
jq '.run_id = "OTHER-RUN"' "$TUPLE_CORRUPT_FILE" > "$WORK/tuple-corrupt.tmp"
mv "$WORK/tuple-corrupt.tmp" "$TUPLE_CORRUPT_FILE"
Q_TUPLE_CORRUPT="$(accounting_admission_query "$ISSUE_TUPLE_CORRUPT")"
assert_eq "TC-RESOURCEACCOUNT-027 canonical tuple mismatch yields corrupt" "corrupt" \
  "$(jq -r .status <<<"$Q_TUPLE_CORRUPT")"

# ---------------------------------------------------------------------------
# Query / projection (D2) — TC-RESOURCEACCOUNT-030..036
# ---------------------------------------------------------------------------
echo "== query / projection =="

ISSUE4=300
Q5="$(accounting_admission_query "$ISSUE4")"
assert_eq "TC-RESOURCEACCOUNT-030 zero invocations -> total 0" "0" "$(jq -r .total_tokens <<<"$Q5")"
assert_eq "TC-RESOURCEACCOUNT-030 zero invocations -> complete" "complete" "$(jq -r .status <<<"$Q5")"

ISSUE5=301
D1="$(accounting_invocation_id RUN5 dev dev 1)"
accounting_start "$ISSUE5" "$D1" dev RUN5 dev 1 >/dev/null
accounting_commit_usage "$ISSUE5" "$D1" 50 >/dev/null
Q6="$(accounting_admission_query "$ISSUE5")"
assert_eq "TC-RESOURCEACCOUNT-031 one invocation -> total 50" "50" "$(jq -r .total_tokens <<<"$Q6")"

ISSUE6=302
D2A="$(accounting_invocation_id RUN6 dev dev 1)"
D2B="$(accounting_invocation_id RUN6 dev dev 2)"
D2C="$(accounting_invocation_id RUN6 dev dev 3)"
D2OPEN="$(accounting_invocation_id RUN6 dev dev 4)"
D2UNK="$(accounting_invocation_id RUN6 dev dev 5)"
for pair in "$D2A:30:1" "$D2B:20:2" "$D2C:10:3"; do
  id="${pair%%:*}"
  rest="${pair#*:}"
  tok="${rest%%:*}"
  attempt="${pair##*:}"
  accounting_start "$ISSUE6" "$id" dev RUN6 dev "$attempt" >/dev/null
  accounting_commit_usage "$ISSUE6" "$id" "$tok" >/dev/null
done
accounting_start "$ISSUE6" "$D2OPEN" dev RUN6 dev 4 >/dev/null
accounting_start "$ISSUE6" "$D2UNK" dev RUN6 dev 5 >/dev/null
accounting_commit_unknown "$ISSUE6" "$D2UNK" "test" >/dev/null
Q7="$(accounting_admission_query "$ISSUE6")"
assert_eq "TC-RESOURCEACCOUNT-032 mixed states total counts only committed usage" "60" "$(jq -r .total_tokens <<<"$Q7")"
assert_eq "TC-RESOURCEACCOUNT-032 one open invocation" "1" "$(jq -r '.open_invocations | length' <<<"$Q7")"
assert_eq "TC-RESOURCEACCOUNT-032 one unknown invocation" "1" "$(jq -r '.unknown_invocations | length' <<<"$Q7")"

ISSUE7=303
E1="$(accounting_invocation_id RUN7 dev dev 1)"
accounting_start "$ISSUE7" "$E1" dev RUN7 dev 1 >/dev/null
accounting_commit_usage "$ISSUE7" "$E1" 15 >/dev/null
PROJ="$(_accounting_issue_dir "$ISSUE7")/projection.json"
assert_eq "TC-RESOURCEACCOUNT-033 no projection exists before first query" "absent" "$([[ -f "$PROJ" ]] && echo present || echo absent)"
accounting_admission_query "$ISSUE7" >/dev/null
assert_eq "TC-RESOURCEACCOUNT-033 projection rebuilt after query" "present" "$([[ -f "$PROJ" ]] && echo present || echo absent)"
assert_eq "TC-RESOURCEACCOUNT-033 projection total matches" "15" "$(jq -r .total_tokens "$PROJ")"

STALE_DIGEST_BEFORE="$(jq -r .digest "$PROJ")"
E2="$(accounting_invocation_id RUN7 dev dev 2)"
accounting_start "$ISSUE7" "$E2" dev RUN7 dev 2 >/dev/null
accounting_commit_usage "$ISSUE7" "$E2" 5 >/dev/null
Q8="$(accounting_admission_query "$ISSUE7")"
assert_eq "TC-RESOURCEACCOUNT-034 stale projection rebuilt to current total" "20" "$(jq -r .total_tokens <<<"$Q8")"
assert_ne "TC-RESOURCEACCOUNT-034 digest changed after rebuild" "$STALE_DIGEST_BEFORE" "$(jq -r .digest "$PROJ")"

printf 'not json at all' > "$PROJ"
Q9="$(accounting_admission_query "$ISSUE7")"
assert_eq "TC-RESOURCEACCOUNT-035 corrupt projection discarded, correct total returned" "20" "$(jq -r .total_tokens <<<"$Q9")"

TOTAL_BEFORE_DELETE="$(jq -r .total_tokens "$PROJ")"
DIGEST_BEFORE_DELETE="$(jq -r .digest "$PROJ")"
rm -f "$PROJ"
Q10="$(accounting_admission_query "$ISSUE7")"
assert_eq "TC-RESOURCEACCOUNT-036 rebuilt total matches pre-delete total" "$TOTAL_BEFORE_DELETE" "$(jq -r .total_tokens <<<"$Q10")"
assert_eq "TC-RESOURCEACCOUNT-036 rebuilt digest matches pre-delete digest" "$DIGEST_BEFORE_DELETE" "$(jq -r .source_digest <<<"$Q10")"

PROJECTION_WRITE_MARKER="$WORK/current-projection-called-writer"
(
  source "$LIB"
  _accounting_write_atomic() {
    : > "$PROJECTION_WRITE_MARKER"
    return 97
  }
  accounting_admission_query "$ISSUE7" >/dev/null
)
assert_eq "TC-RESOURCEACCOUNT-037 current projection query succeeds" "0" "$?"
assert_absent "TC-RESOURCEACCOUNT-037 current projection never calls the atomic writer" "$PROJECTION_WRITE_MARKER"

CURRENT_DIGEST="$(jq -r .digest "$PROJ")"
printf '{"digest":"%s"}\n' "$CURRENT_DIGEST" > "$PROJ"
accounting_admission_query "$ISSUE7" >/dev/null
assert_eq "TC-RESOURCEACCOUNT-038 projection schema rebuilt" "$ACCOUNTING_SCHEMA_VERSION" \
  "$(jq -r .schema_version "$PROJ")"
assert_eq "TC-RESOURCEACCOUNT-038 projection total rebuilt" "20" "$(jq -r .total_tokens "$PROJ")"
assert_eq "TC-RESOURCEACCOUNT-038 projection source ids rebuilt" "2" \
  "$(jq -r '.source_invocation_ids | length' "$PROJ")"

# ---------------------------------------------------------------------------
# Reconciliation (D6) — TC-RESOURCEACCOUNT-040..045
# ---------------------------------------------------------------------------
echo "== reconciliation =="

PID_WORK="$(mktemp -d)"
export AUTONOMOUS_PID_DIR="$PID_WORK"
ISSUE8=400

# A dead PID: spawn and wait for a genuinely-exited child.
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null

F1="$(accounting_invocation_id RUNDEAD dev dev 1)"
accounting_start "$ISSUE8" "$F1" dev RUNDEAD dev 1 >/dev/null
printf 'RUNDEAD\n' > "${PID_WORK}/issue-${ISSUE8}.run-id"
jq -nc --argjson pid "$DEAD_PID" '{schema_version:1,run_id:"RUNDEAD",pid:$pid,updated_at_epoch:0}' > "${PID_WORK}/issue-${ISSUE8}.progress.json"
accounting_reconcile "$ISSUE8"
QF1="$(jq -r .state "$(_accounting_issue_dir "$ISSUE8")/${F1}.json")"
assert_eq "TC-RESOURCEACCOUNT-040 dead-PID evidence promotes to usage-unknown" "usage-unknown" "$QF1"

ISSUE9=401
F2="$(accounting_invocation_id RUNOLD dev dev 1)"
accounting_start "$ISSUE9" "$F2" dev RUNOLD dev 1 >/dev/null
printf 'RUNNEW\n' > "${PID_WORK}/issue-${ISSUE9}.run-id"
jq -nc '{schema_version:1,run_id:"RUNNEW",pid:999999,updated_at_epoch:0}' > "${PID_WORK}/issue-${ISSUE9}.progress.json"
accounting_reconcile "$ISSUE9"
QF2="$(jq -r .state "$(_accounting_issue_dir "$ISSUE9")/${F2}.json")"
assert_eq "TC-RESOURCEACCOUNT-041 superseded run-id promotes to usage-unknown" "usage-unknown" "$QF2"

ISSUE10=402
F3="$(accounting_invocation_id RUNLIVE dev dev 1)"
accounting_start "$ISSUE10" "$F3" dev RUNLIVE dev 1 >/dev/null
printf 'RUNLIVE\n' > "${PID_WORK}/issue-${ISSUE10}.run-id"
jq -nc --argjson pid "$$" '{schema_version:1,run_id:"RUNLIVE",pid:$pid,updated_at_epoch:0}' > "${PID_WORK}/issue-${ISSUE10}.progress.json"
accounting_reconcile "$ISSUE10"
QF3="$(jq -r .state "$(_accounting_issue_dir "$ISSUE10")/${F3}.json")"
assert_eq "TC-RESOURCEACCOUNT-042 live lease keeps started (incomplete)" "started" "$QF3"

ISSUE10B=4021
F3B="$(accounting_invocation_id RUNNOEV dev dev 1)"
accounting_start "$ISSUE10B" "$F3B" dev RUNNOEV dev 1 >/dev/null
# No run-id sidecar and no progress.json at all — absence of evidence, not
# proof of death (INV-135's own transient no-lease-yet window).
accounting_reconcile "$ISSUE10B"
QF3B="$(jq -r .state "$(_accounting_issue_dir "$ISSUE10B")/${F3B}.json")"
assert_eq "TC-RESOURCEACCOUNT-042b missing evidence (no sidecars) keeps started, not usage-unknown" "started" "$QF3B"

ISSUE10C=4022
F3C="$(accounting_invocation_id RUNNOPID dev dev 1)"
accounting_start "$ISSUE10C" "$F3C" dev RUNNOPID dev 1 >/dev/null
printf 'RUNNOPID\n' > "${PID_WORK}/issue-${ISSUE10C}.run-id"
# Run-id sidecar matches but progress.json is absent — run-id evidence alone
# says nothing about liveness; must not be treated as a dead pid.
rm -f "${PID_WORK}/issue-${ISSUE10C}.progress.json"
accounting_reconcile "$ISSUE10C"
QF3C="$(jq -r .state "$(_accounting_issue_dir "$ISSUE10C")/${F3C}.json")"
assert_eq "TC-RESOURCEACCOUNT-042c matching run-id, missing pid evidence keeps started" "started" "$QF3C"

ISSUE11=403
F4="$(accounting_invocation_id RUNCLOSE dev dev 1)"
accounting_start "$ISSUE11" "$F4" dev RUNCLOSE dev 1 >/dev/null
F4_FILE="$(_accounting_issue_dir "$ISSUE11")/${F4}.json"
BEFORE_CLOSE="$(cat "$F4_FILE")"
# Simulate "issue closed" — no call into accounting_reconcile at all.
AFTER_CLOSE="$(cat "$F4_FILE")"
assert_eq "TC-RESOURCEACCOUNT-043 closing the issue alone mutates nothing" "$BEFORE_CLOSE" "$AFTER_CLOSE"

ISSUE12=404
F5="$(accounting_invocation_id RUNACK dev dev 1)"
accounting_start "$ISSUE12" "$F5" dev RUNACK dev 1 >/dev/null
accounting_commit_unknown "$ISSUE12" "$F5" "test-reason" >/dev/null
accounting_ack_unknown "$ISSUE12" "$F5"
assert_eq "TC-RESOURCEACCOUNT-044 ack_unknown succeeds" "0" "$?"
ACKS_FILE="$(_accounting_issue_dir "$ISSUE12")/acks.jsonl"
assert_eq "TC-RESOURCEACCOUNT-044 ack record written" "1" "$(wc -l < "$ACKS_FILE" | tr -d ' ')"
F5REC="$(_accounting_issue_dir "$ISSUE12")/${F5}.json"
assert_eq "TC-RESOURCEACCOUNT-044 original usage-unknown record still exists" "usage-unknown" "$(jq -r .state "$F5REC")"

ISSUE12B=4041
F5B="$(accounting_invocation_id RUNACKCLOCK dev dev 1)"
accounting_start "$ISSUE12B" "$F5B" dev RUNACKCLOCK dev 1 >/dev/null
accounting_commit_unknown "$ISSUE12B" "$F5B" "test-reason" >/dev/null
(
  source "$LIB"
  _accounting_now() {
    echo "_accounting_now: injected timestamp failure" >&2
    return 97
  }
  accounting_ack_unknown "$ISSUE12B" "$F5B" 2>"$WORK/clock-ack-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-049 ack propagates clock failure" "0" "$?"
assert_absent "TC-RESOURCEACCOUNT-049 failed ack timestamp writes no audit file" \
  "$(_accounting_issue_dir "$ISSUE12B")/acks.jsonl"

ISSUE13=405
G1="$(accounting_invocation_id RUNRE dev dev 1)"
G2="$(accounting_invocation_id RUNRE dev dev 2)"
accounting_start "$ISSUE13" "$G1" dev RUNRE dev 1 >/dev/null
accounting_commit_usage "$ISSUE13" "$G1" 25 >/dev/null
accounting_start "$ISSUE13" "$G2" dev RUNRE dev 2 >/dev/null
accounting_commit_unknown "$ISSUE13" "$G2" "test" >/dev/null
G1_BEFORE="$(cat "$(_accounting_issue_dir "$ISSUE13")/${G1}.json")"
G2_BEFORE="$(cat "$(_accounting_issue_dir "$ISSUE13")/${G2}.json")"
accounting_reconcile "$ISSUE13"
accounting_reconcile "$ISSUE13"
G1_AFTER="$(cat "$(_accounting_issue_dir "$ISSUE13")/${G1}.json")"
G2_AFTER="$(cat "$(_accounting_issue_dir "$ISSUE13")/${G2}.json")"
assert_eq "TC-RESOURCEACCOUNT-045 committed record unchanged after re-arm" "$G1_BEFORE" "$G1_AFTER"
assert_eq "TC-RESOURCEACCOUNT-045 already-unknown record unchanged after re-arm" "$G2_BEFORE" "$G2_AFTER"

ISSUE14=406
G3="$(accounting_invocation_id RUNWRITEFAIL dev dev 1)"
accounting_start "$ISSUE14" "$G3" dev RUNWRITEFAIL dev 1 >/dev/null
printf 'RUNSUPERSEDED\n' > "${PID_WORK}/issue-${ISSUE14}.run-id"
G3_FILE="$(_accounting_issue_dir "$ISSUE14")/${G3}.json"
(
  source "$LIB"
  _accounting_write_atomic() {
    return 97
  }
  accounting_reconcile "$ISSUE14" 2>"$WORK/reconcile-write-fail-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-046 reconcile propagates failed transition write" "0" "$?"
assert_contains "TC-RESOURCEACCOUNT-046 reconcile write failure is loud" "accounting_reconcile" \
  "$(cat "$WORK/reconcile-write-fail-err.txt")"
assert_eq "TC-RESOURCEACCOUNT-046 failed transition leaves record started" "started" "$(jq -r .state "$G3_FILE")"

ISSUE15=407
G4="$(accounting_invocation_id RUNLEASE dev dev 1)"
accounting_start "$ISSUE15" "$G4" dev RUNLEASE dev 1 >/dev/null
printf 'RUNLEASE\n' > "${PID_WORK}/issue-${ISSUE15}.run-id"
jq -nc --argjson pid "$DEAD_PID" \
  '{schema_version:1,run_id:"STALE-RUN",pid:$pid,updated_at_epoch:0}' \
  > "${PID_WORK}/issue-${ISSUE15}.progress.json"
accounting_reconcile "$ISSUE15"
assert_eq "TC-RESOURCEACCOUNT-047 mismatched progress run-id is not PID proof" "started" \
  "$(jq -r .state "$(_accounting_issue_dir "$ISSUE15")/${G4}.json")"

ISSUE16=408
G5="$(accounting_invocation_id RUNBADLEASE dev dev 1)"
accounting_start "$ISSUE16" "$G5" dev RUNBADLEASE dev 1 >/dev/null
printf 'RUNBADLEASE\n' > "${PID_WORK}/issue-${ISSUE16}.run-id"
printf '{"schema_version":999,"run_id":"RUNBADLEASE","pid":"not-a-pid"}\n' \
  > "${PID_WORK}/issue-${ISSUE16}.progress.json"
accounting_reconcile "$ISSUE16"
assert_eq "TC-RESOURCEACCOUNT-048 malformed progress evidence is ignored" "started" \
  "$(jq -r .state "$(_accounting_issue_dir "$ISSUE16")/${G5}.json")"

ISSUE17=409
G6="$(accounting_invocation_id RUNBADRUNID dev dev 1)"
accounting_start "$ISSUE17" "$G6" dev RUNBADRUNID dev 1 >/dev/null
printf 'RUNBADRUNID\nEXTRA\n' > "${PID_WORK}/issue-${ISSUE17}.run-id"
jq -nc --argjson pid "$DEAD_PID" \
  '{schema_version:1,run_id:"RUNBADRUNID",pid:$pid,updated_at_epoch:0}' \
  > "${PID_WORK}/issue-${ISSUE17}.progress.json"
accounting_reconcile "$ISSUE17"
assert_eq "TC-RESOURCEACCOUNT-048 malformed run-id evidence is ignored" "started" \
  "$(jq -r .state "$(_accounting_issue_dir "$ISSUE17")/${G6}.json")"

ISSUE18=410
G7="$(accounting_invocation_id RUNSYMLINKLEASE dev dev 1)"
accounting_start "$ISSUE18" "$G7" dev RUNSYMLINKLEASE dev 1 >/dev/null
printf 'RUNSYMLINKLEASE\n' > "$WORK/run-id-target"
ln -s "$WORK/run-id-target" "${PID_WORK}/issue-${ISSUE18}.run-id"
jq -nc --argjson pid "$DEAD_PID" \
  '{schema_version:1,run_id:"RUNSYMLINKLEASE",pid:$pid,updated_at_epoch:0}' \
  > "${PID_WORK}/issue-${ISSUE18}.progress.json"
accounting_reconcile "$ISSUE18"
assert_eq "TC-RESOURCEACCOUNT-048 symlinked run-id evidence is ignored" "started" \
  "$(jq -r .state "$(_accounting_issue_dir "$ISSUE18")/${G7}.json")"

ISSUE19=411
G8="$(accounting_invocation_id RUNSYMLINKPROGRESS dev dev 1)"
accounting_start "$ISSUE19" "$G8" dev RUNSYMLINKPROGRESS dev 1 >/dev/null
printf 'RUNSYMLINKPROGRESS\n' > "${PID_WORK}/issue-${ISSUE19}.run-id"
jq -nc --argjson pid "$DEAD_PID" \
  '{schema_version:1,run_id:"RUNSYMLINKPROGRESS",pid:$pid,updated_at_epoch:0}' \
  > "$WORK/progress-target"
ln -s "$WORK/progress-target" "${PID_WORK}/issue-${ISSUE19}.progress.json"
accounting_reconcile "$ISSUE19"
assert_eq "TC-RESOURCEACCOUNT-048 symlinked progress evidence is ignored" "started" \
  "$(jq -r .state "$(_accounting_issue_dir "$ISSUE19")/${G8}.json")"

ISSUE20=412
G9="$(accounting_invocation_id RUNRECONCILESYNC dev dev 1)"
accounting_start "$ISSUE20" "$G9" dev RUNRECONCILESYNC dev 1 >/dev/null
printf 'RUNSUPERSEDED\n' > "${PID_WORK}/issue-${ISSUE20}.run-id"
(
  source "$LIB"
  _accounting_sync_dir() {
    return 97
  }
  accounting_reconcile "$ISSUE20" 2>"$WORK/reconcile-dir-sync-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-028 reconcile post-rename sync failure is propagated" "0" "$?"
RECONCILE_SYNC_MARKER="$WORK/reconcile-terminal-resynced"
(
  source "$LIB"
  _accounting_sync_dir() {
    : > "$RECONCILE_SYNC_MARKER"
    return 0
  }
  accounting_reconcile "$ISSUE20"
)
assert_eq "TC-RESOURCEACCOUNT-028 reconcile retry succeeds" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-028 reconcile retry re-syncs terminal record" "present" \
  "$([[ -f "$RECONCILE_SYNC_MARKER" ]] && echo present || echo absent)"

ISSUE21=413
G10="$(accounting_invocation_id RUNRECONCILECLOCK dev dev 1)"
accounting_start "$ISSUE21" "$G10" dev RUNRECONCILECLOCK dev 1 >/dev/null
printf 'RUNSUPERSEDED\n' > "${PID_WORK}/issue-${ISSUE21}.run-id"
(
  source "$LIB"
  _accounting_now() {
    echo "_accounting_now: injected timestamp failure" >&2
    return 97
  }
  accounting_reconcile "$ISSUE21" 2>"$WORK/clock-reconcile-err.txt"
)
assert_ne "TC-RESOURCEACCOUNT-049 reconcile propagates clock failure" "0" "$?"
assert_eq "TC-RESOURCEACCOUNT-049 failed reconcile timestamp leaves started record" "started" \
  "$(jq -r .state "$(_accounting_issue_dir "$ISSUE21")/${G10}.json")"

rm -rf "$PID_WORK"
unset AUTONOMOUS_PID_DIR

# ---------------------------------------------------------------------------
# Metrics isolation guard — TC-RESOURCEACCOUNT-060..061
# ---------------------------------------------------------------------------
echo "== metrics isolation =="

METRICS_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-metrics.sh"
ISO_WORK="$(mktemp -d)"
(
  export AUTONOMOUS_METRICS_DIR="$ISO_WORK"
  export AUTONOMOUS_ACCOUNTING_DIR="$ISO_WORK/accounting"
  export PROJECT_ID="isoproj"
  # shellcheck source=/dev/null
  source "$METRICS_LIB"
  source "$LIB"
  # A deliberately OLD ts (200 days) so metrics_prune 90 genuinely rewrites
  # metrics.jsonl below — a "now" ts would survive any retention window,
  # making the prune call a no-op and the checksum comparison vacuous.
  OLD_TS="$(date -u -d '200 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$OLD_TS" '{schema_version:1,ts:$ts,event:"token_usage",side:"dev",issue:999,total_tokens:1}' \
    >> "${ISO_WORK}/metrics.jsonl"
  H1="$(accounting_invocation_id RUNISO dev dev 1)"
  accounting_start 999 "$H1" dev RUNISO dev 1 >/dev/null
  accounting_commit_usage 999 "$H1" 42 >/dev/null
)
METRICS_BEFORE_CHECKSUM="$(sha256sum "${ISO_WORK}/metrics.jsonl" | awk '{print $1}')"
BEFORE_ACCT_CHECKSUM="$(find "$ISO_WORK/accounting" -type f -exec sha256sum {} \; 2>/dev/null | sort)"
(
  export AUTONOMOUS_METRICS_DIR="$ISO_WORK"
  source "$METRICS_LIB"
  metrics_prune 90
)
METRICS_AFTER_CHECKSUM="$(sha256sum "${ISO_WORK}/metrics.jsonl" | awk '{print $1}')"
AFTER_ACCT_CHECKSUM="$(find "$ISO_WORK/accounting" -type f -exec sha256sum {} \; 2>/dev/null | sort)"
assert_ne "TC-RESOURCEACCOUNT-060 sanity: metrics_prune actually rewrote metrics.jsonl (not a vacuous no-op)" "$METRICS_BEFORE_CHECKSUM" "$METRICS_AFTER_CHECKSUM"
assert_eq "TC-RESOURCEACCOUNT-060 metrics_prune leaves accounting/ byte-unchanged" "$BEFORE_ACCT_CHECKSUM" "$AFTER_ACCT_CHECKSUM"
assert_eq "TC-RESOURCEACCOUNT-060 accounting dir is a sibling of metrics.jsonl, not a descendant of it" "sibling" \
  "$([[ "$ISO_WORK/accounting" == "$ISO_WORK/metrics.jsonl/"* ]] && echo "descendant" || echo "sibling")"
rm -rf "$ISO_WORK"

# ---------------------------------------------------------------------------
# Production call-site choke point — TC-RESOURCEACCOUNT-070
# ---------------------------------------------------------------------------
echo "== production accounting choke point =="

PROD_HITS="$(
  while IFS= read -r candidate; do
    if awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*(if[[:space:]]+![[:space:]]+)?accounting_(invocation_id|start|commit_usage|commit_unknown|reconcile|ack_unknown|admission_query)([[:space:]]|$)/ { found = 1 }
      /\$\([[:space:]]*accounting_(invocation_id|start|commit_usage|commit_unknown|reconcile|ack_unknown|admission_query)([[:space:]]|$)/ { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$candidate"; then
      printf '%s\n' "$candidate"
    fi
  done < <(
    find "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts" -type f -name '*.sh' \
      ! -name 'lib-accounting.sh' -print | sort
  )
)"
assert_eq "TC-RESOURCEACCOUNT-070 lib-token-budget is the sole production accounting consumer" \
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-token-budget.sh" "$PROD_HITS"

# ---------------------------------------------------------------------------
# Deterministic branch inventory — TC-RESOURCEACCOUNT-080
# ---------------------------------------------------------------------------
echo "== branch coverage inventory =="

BRANCH_INVENTORY="$SCRIPT_DIR/fixtures/lib-accounting-branch-inventory.tsv"
INVENTORY_TOTAL=0
INVENTORY_COVERED=0
INVENTORY_BAD=0
declare -A INVENTORY_IDS=()
if [[ "${ACCOUNTING_COVERAGE_CHILD:-0}" != "1" ]]; then
  COVERAGE_TRACE="$(mktemp)"
  COVERAGE_OUT="$(mktemp)"
  exec {COVERAGE_FD}>"$COVERAGE_TRACE"
  ACCOUNTING_COVERAGE_CHILD=1 BASH_XTRACEFD="$COVERAGE_FD" \
    PS4='+${BASH_SOURCE}:${LINENO}:' bash -x "$0" >"$COVERAGE_OUT" 2>&1
  COVERAGE_RC=$?
  exec {COVERAGE_FD}>&-
  if [[ "$COVERAGE_RC" -ne 0 ]]; then
    echo "  traced coverage child failed (rc=$COVERAGE_RC)" >&2
    tail -40 "$COVERAGE_OUT" >&2
    INVENTORY_BAD=$((INVENTORY_BAD + 1))
  fi

  while IFS='|' read -r branch_id status test_id description; do
    [[ -n "$branch_id" && "${branch_id:0:1}" != "#" ]] || continue
    INVENTORY_TOTAL=$((INVENTORY_TOTAL + 1))
    if [[ -n "${INVENTORY_IDS[$branch_id]:-}" ]]; then
      echo "  duplicate branch inventory id: $branch_id" >&2
      INVENTORY_BAD=$((INVENTORY_BAD + 1))
    fi
    INVENTORY_IDS[$branch_id]=1

    SOURCE_HITS="$(grep -nF "accounting-branch: $branch_id" "$LIB")"
    SOURCE_HIT_COUNT="$(wc -l <<<"$SOURCE_HITS" | tr -d ' ')"
    if [[ "$SOURCE_HIT_COUNT" != "1" ]]; then
      echo "  branch $branch_id has $SOURCE_HIT_COUNT source markers (expected 1): $description" >&2
      INVENTORY_BAD=$((INVENTORY_BAD + 1))
      continue
    fi
    SOURCE_LINE="${SOURCE_HITS%%:*}"
    BRANCH_EXECUTED=0
    grep -Fq "${LIB}:${SOURCE_LINE}:" "$COVERAGE_TRACE" && BRANCH_EXECUTED=1

    case "$status" in
      covered)
        INVENTORY_COVERED=$((INVENTORY_COVERED + 1))
        if [[ "$test_id" == "-" ]] || ! grep -RqsF --include='*.sh' "$test_id" \
          "$PROJECT_ROOT/tests/unit" "$PROJECT_ROOT/tests/e2e"; then
          echo "  covered branch $branch_id references missing test id '$test_id': $description" >&2
          INVENTORY_BAD=$((INVENTORY_BAD + 1))
        fi
        if [[ "$BRANCH_EXECUTED" -ne 1 ]]; then
          echo "  covered branch $branch_id did not execute at ${LIB}:${SOURCE_LINE}: $description" >&2
          INVENTORY_BAD=$((INVENTORY_BAD + 1))
        fi
        ;;
      uncovered)
        if [[ "$test_id" != "-" ]]; then
          echo "  uncovered branch $branch_id must use test id '-': $description" >&2
          INVENTORY_BAD=$((INVENTORY_BAD + 1))
        fi
        if [[ "$BRANCH_EXECUTED" -eq 1 ]]; then
          echo "  uncovered branch $branch_id executed; promote it and bind its test: $description" >&2
          INVENTORY_BAD=$((INVENTORY_BAD + 1))
        fi
        ;;
      *)
        echo "  invalid branch inventory status '$status' for $branch_id" >&2
        INVENTORY_BAD=$((INVENTORY_BAD + 1))
        ;;
    esac
  done < "$BRANCH_INVENTORY"

  SOURCE_MARKER_IDS="$(grep -oE 'accounting-branch: B[0-9]+' "$LIB" | awk '{print $2}' | sort -u)"
  SOURCE_MARKER_TOTAL="$(wc -l <<<"$SOURCE_MARKER_IDS" | tr -d ' ')"
  while IFS= read -r source_id; do
    [[ -n "$source_id" ]] || continue
    if [[ -z "${INVENTORY_IDS[$source_id]:-}" ]]; then
      echo "  source marker $source_id is missing from the branch inventory" >&2
      INVENTORY_BAD=$((INVENTORY_BAD + 1))
    fi
  done <<<"$SOURCE_MARKER_IDS"

  INVENTORY_PERCENT="$(awk -v covered="$INVENTORY_COVERED" -v total="$INVENTORY_TOTAL" \
    'BEGIN { printf "%.1f", covered * 100 / total }')"
  assert_eq "TC-RESOURCEACCOUNT-080 source-anchored trace inventory has no errors" "0" "$INVENTORY_BAD"
  assert_eq "TC-RESOURCEACCOUNT-080 branch inventory accounts for every source marker" \
    "$SOURCE_MARKER_TOTAL" "$INVENTORY_TOTAL"
  if [[ "$INVENTORY_COVERED" -gt $((INVENTORY_TOTAL * 80 / 100)) ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-RESOURCEACCOUNT-080 semantic branch outcomes ${INVENTORY_COVERED}/${INVENTORY_TOTAL} (${INVENTORY_PERCENT}%) > 80%"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-RESOURCEACCOUNT-080 semantic branch outcomes ${INVENTORY_COVERED}/${INVENTORY_TOTAL} (${INVENTORY_PERCENT}%) is not > 80%"
    FAIL=$((FAIL + 1))
  fi

  # Derive the denominator independently from every shell decision site in
  # the library. This closes the self-selected-marker gap: adding an unmarked
  # if/elif/loop/short-circuit guard automatically grows the denominator.
  # Multiline single-quoted jq programs are skipped because their `if` tokens
  # are jq control flow, not shell branches.
  BRANCH_SITE_LINES="$(mktemp)"
  awk '
    BEGIN { in_single_quote = 0 }
    {
      raw = $0
      lead = raw
      sub(/^[[:space:]]*/, "", lead)
      if (!in_single_quote && lead ~ /^#/) next
      if (!in_single_quote) sub(/[[:space:]]+#.*/, "", raw)

      quoted = raw
      quote_count = gsub(/\047/, "", quoted)
      if (in_single_quote) {
        if (quote_count % 2 == 1) in_single_quote = 0
        next
      }

      code = raw
      sub(/\047.*/, "", code)
      trimmed = code
      sub(/^[[:space:]]*/, "", trimmed)
      if (trimmed ~ /^(if|elif|for|while)[[:space:]]/ ||
          (trimmed !~ /^(if|elif)[[:space:]]/ &&
           trimmed ~ /[[:space:]](\|\||&&)[[:space:]]/)) {
        print NR
      }
      if (quote_count % 2 == 1) in_single_quote = 1
    }
  ' "$LIB" > "$BRANCH_SITE_LINES"

  BRANCH_SITE_TOTAL="$(wc -l < "$BRANCH_SITE_LINES" | tr -d ' ')"
  BRANCH_SITE_COVERED=0
  while IFS= read -r site_line; do
    [[ -n "$site_line" ]] || continue
    if grep -Fq "${LIB}:${site_line}:" "$COVERAGE_TRACE"; then
      BRANCH_SITE_COVERED=$((BRANCH_SITE_COVERED + 1))
    fi
  done < "$BRANCH_SITE_LINES"
  BRANCH_SITE_PERCENT="$(awk -v covered="$BRANCH_SITE_COVERED" -v total="$BRANCH_SITE_TOTAL" \
    'BEGIN { printf "%.1f", covered * 100 / total }')"
  if [[ "$BRANCH_SITE_COVERED" -gt $((BRANCH_SITE_TOTAL * 80 / 100)) ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-RESOURCEACCOUNT-080 source-derived branch sites ${BRANCH_SITE_COVERED}/${BRANCH_SITE_TOTAL} (${BRANCH_SITE_PERCENT}%) > 80%"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-RESOURCEACCOUNT-080 source-derived branch sites ${BRANCH_SITE_COVERED}/${BRANCH_SITE_TOTAL} (${BRANCH_SITE_PERCENT}%) is not > 80%"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$BRANCH_SITE_LINES" "$COVERAGE_TRACE" "$COVERAGE_OUT"
fi

rm -rf "$WORK"

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] || exit 1
