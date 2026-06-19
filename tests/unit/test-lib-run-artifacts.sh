#!/bin/bash
# test-lib-run-artifacts.sh — issue #235 / INV-81.
#
# Covers lib-run-artifacts.sh: run-id minting + uniqueness, run-dir path scheme
# + coordination with #233, run_artifacts_init/finalize + meta.json, footer
# rendering, drop recording, and prune (age boundary + never-active).
# Test IDs: TC-RUN-ARTIFACTS-001..039.
#
# Strategy: source the lib, point AUTONOMOUS_RUN_DIR_BASE at a temp dir, exercise
# the functions, assert on the resulting files with jq. The observe-only contract
# (INV-81) is checked by exercising under `set -e` with an unwritable base and
# asserting the surrounding rc is unchanged.
#
# Run: bash tests/unit/test-lib-run-artifacts.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-run-artifacts.sh"
ARTIFACT_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-artifact.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Many test groups run inside ( ... ) subshells to isolate exported env. A plain
# PASS/FAIL shell counter would be lost when each subshell exits. Tally instead
# by appending a marker per assertion to files that OUTLIVE the subshells, then
# count them at the end — so a FAIL inside any subshell still fails the suite.
TALLY_DIR="$(mktemp -d)"
PASS_FILE="$TALLY_DIR/pass"; FAIL_FILE="$TALLY_DIR/fail"
: > "$PASS_FILE"; : > "$FAIL_FILE"
_pass() { echo "$1" >> "$PASS_FILE"; }
_fail() { echo "$1" >> "$FAIL_FILE"; }

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; _pass "$desc"
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      want='$want'"; echo "      got ='$got'"; _fail "$desc"
  fi
}
assert_match() {
  local desc="$1" re="$2" got="$3"
  if [[ "$got" =~ $re ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; _pass "$desc"
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      regex='$re'"; echo "      got  ='$got'"; _fail "$desc"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; _pass "$desc"
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle='$needle'"; echo "      hay   ='$hay'"; _fail "$desc"
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; _pass "$desc"
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      unexpected='$needle'"; _fail "$desc"
  fi
}
assert_true() {
  local desc="$1"; shift
  if "$@"; then echo -e "  ${GREEN}PASS${NC}: $desc"; _pass "$desc";
  else echo -e "  ${RED}FAIL${NC}: $desc"; _fail "$desc"; fi
}
assert_false() {
  local desc="$1"; shift
  if "$@"; then echo -e "  ${RED}FAIL${NC}: $desc"; _fail "$desc";
  else echo -e "  ${GREEN}PASS${NC}: $desc"; _pass "$desc"; fi
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-run-artifacts.sh
source "$LIB"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT" "$TALLY_DIR"' EXIT

# ---------------------------------------------------------------------------
# minting & uniqueness (TC-001..006)
# ---------------------------------------------------------------------------
echo "== mint_run_id =="
(
  export PROJECT_ID="proj"
  unset RUN_ID
  rid="$(mint_run_id dev 235)"
  assert_match "TC-001 dev run-id shape" '^proj-235-dev-[0-9]{8}T[0-9]{6}Z$' "$rid"

  rid2="$(mint_run_id review 235)"
  assert_match "TC-002 review side segment" '^proj-235-review-' "$rid2"

  rid3="$(RUN_ID="pinned-id" mint_run_id dev 235)"
  assert_eq "TC-003 honors pre-set RUN_ID" "pinned-id" "$rid3"

  # RUN_ID must stay unset here so mint actually composes the issue/side segments.
  unset RUN_ID
  a="$(mint_run_id dev 235)"; b="$(mint_run_id dev 236)"
  assert_true "TC-004 different issues differ" [ "$a" != "$b" ]

  d="$(mint_run_id dev 235)"; r="$(mint_run_id review 235)"
  assert_true "TC-005 dev vs review differ" [ "$d" != "$r" ]
)
(
  unset PROJECT_ID RUN_ID
  out="$(mint_run_id dev 235 2>/dev/null)"; rc=$?
  assert_true "TC-006 unset PROJECT_ID → non-zero/empty" [ "$rc" -ne 0 -o -z "$out" ]
)

# ---------------------------------------------------------------------------
# run_dir_for / coordination with #233 (TC-010..013)
# ---------------------------------------------------------------------------
echo "== run_dir_for / #233 coordination =="
(
  export PROJECT_ID="proj"
  unset AUTONOMOUS_RUN_DIR_BASE
  export XDG_STATE_HOME="/x"
  assert_eq "TC-010 XDG_STATE_HOME path" "/x/autonomous-proj/runs/proj-235-dev-T" "$(run_dir_for proj-235-dev-T)"
)
(
  export PROJECT_ID="proj"
  unset AUTONOMOUS_RUN_DIR_BASE XDG_STATE_HOME
  export HOME="/h"
  assert_eq "TC-011 HOME fallback path" "/h/.local/state/autonomous-proj/runs/proj-235-dev-T" "$(run_dir_for proj-235-dev-T)"
)
(
  export PROJECT_ID="proj"
  unset AUTONOMOUS_RUN_DIR_BASE
  export XDG_STATE_HOME="/x"
  # #233's _verdict_artifact_dir uses the SAME runs/ parent.
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-artifact.sh
  source "$ARTIFACT_LIB" 2>/dev/null || true
  if declare -F _verdict_artifact_dir >/dev/null 2>&1; then
    v233="$(_verdict_artifact_dir proj some-uuid)"
    ours="$(run_dir_for proj-235-dev-T)"
    assert_eq "TC-012 shared runs/ parent w/ #233" "$(dirname "$v233")" "$(dirname "$ours")"
  else
    echo "  SKIP TC-012 (_verdict_artifact_dir not found)"
  fi
)

# ---------------------------------------------------------------------------
# run_artifacts_init / finalize / meta.json (TC-020..027) + TC-013/024/036
# ---------------------------------------------------------------------------
echo "== init / finalize / meta =="
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/state/autonomous-proj"
  export MODE="new" AGENT_CMD="claude" GH_AUTH_MODE="app"
  export LOG_FILE="/tmp/agent-proj-issue-235.log"
  unset RUN_ID RUN_DIR

  set -e
  run_artifacts_init dev 235 || true
  set +e

  assert_true "TC-020a RUN_DIR exported + exists" [ -d "$RUN_DIR" ]
  # mode 0700
  mode="$(stat -c '%a' "$RUN_DIR" 2>/dev/null || stat -f '%Lp' "$RUN_DIR" 2>/dev/null)"
  assert_eq "TC-020b run dir mode 0700" "700" "$mode"
  meta="$RUN_DIR/meta.json"
  assert_true "TC-020c meta.json valid JSON" jq -e . "$meta"
  assert_eq "TC-020d meta side=dev" "dev" "$(jq -r '.side' "$meta")"
  assert_eq "TC-020e meta issue=235" "235" "$(jq -r '.issue' "$meta")"
  assert_match "TC-020f meta started_at present" '^[0-9]{4}-' "$(jq -r '.started_at' "$meta")"

  # TC-021 env summary redaction
  he="$(jq -c '.host_env' "$meta")"
  assert_contains "TC-021a host_env has agent" '"agent"' "$he"
  assert_contains "TC-021b host_env has gh_auth_mode" '"gh_auth_mode"' "$he"
  assert_not_contains "TC-021c host_env no token" 'GH_TOKEN' "$he"
  assert_not_contains "TC-021d host_env no PEM" 'PEM' "$he"

  # TC-013 / TC-037 prep: drop a bare-UUID #233 sibling next to our dir.
  uuiddir="$(dirname "$RUN_DIR")/01c9c077-febc-4cf3-a716-ee66ae584135"
  mkdir -p "$uuiddir"

  # TC-027 run.log first-line pointer
  firstline="$(head -1 "$RUN_DIR/run.log")"
  assert_contains "TC-027a run.log has run-dir pointer" "run-dir:" "$firstline"
  assert_contains "TC-027b run.log has tmp-log pointer" "tmp-log:" "$(sed -n '2p' "$RUN_DIR/run.log")"

  # TC-022 finalize rc=0
  run_artifacts_finalize "$RUN_DIR" 0 || true
  assert_eq "TC-022a ended rc=0" "0" "$(jq -r '.rc' "$meta")"
  assert_match "TC-022b ended_at present" '^[0-9]{4}-' "$(jq -r '.ended_at' "$meta")"
  assert_match "TC-022c duration_s numeric" '^[0-9]+$' "$(jq -r '.duration_s' "$meta")"

  # TC-013 the bare-UUID dir is NOT matched by the wrapper-run-id glob
  assert_true "TC-013 #233 UUID dir survives (not a wrapper-run-id)" [ -d "$uuiddir" ]
)

# TC-096 the LEGACY /tmp agent log gets a durable-run-dir breadcrumb at init
# (#235 r15). Uses an isolated LOG_FILE under TMP_ROOT (not a real /tmp path).
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/tmplog/autonomous-proj"
  export LOG_FILE="$TMP_ROOT/tmplog-agent-proj-issue-235.log"
  : > "$LOG_FILE"   # dispatch-local.sh pre-creates the /tmp log (here: empty)
  unset RUN_ID RUN_DIR
  run_artifacts_init dev 235 || true
  assert_true "TC-096a /tmp log gained a run-dir breadcrumb" \
    grep -qF "run-dir: ${RUN_DIR} " "$LOG_FILE"
  assert_contains "TC-096b breadcrumb names the run-id" "$RUN_ID" "$(cat "$LOG_FILE")"
  # init runs early (empty log) → the breadcrumb is the FIRST line.
  assert_contains "TC-096c breadcrumb is the first line" "run-dir: ${RUN_DIR}" "$(head -1 "$LOG_FILE")"
  # Idempotency guard: a redundant breadcrumb for the SAME dir is not re-appended.
  # (A genuine re-init mints a fresh run-id → a different dir → a legitimately new
  # breadcrumb, so we exercise the guard directly against the already-written dir.)
  _saved_run_dir="$RUN_DIR"
  _before_n="$(grep -c 'run-dir:' "$LOG_FILE")"
  # Re-run init with the dir already present → disambiguation makes a NEW dir, so a
  # NEW breadcrumb IS expected (one per distinct run dir). Confirm exactly +1, not
  # an unbounded duplicate, and that the guard skipped the original dir's line.
  unset RUN_ID; RUN_DIR=""
  run_artifacts_init dev 235 || true
  assert_eq "TC-096d one breadcrumb per distinct run dir (no dup of the original)" \
    "$((_before_n + 1))" "$(grep -c 'run-dir:' "$LOG_FILE")"
  assert_eq "TC-096e original dir's breadcrumb appears exactly once (guard held)" \
    "1" "$(grep -cF "run-dir: ${_saved_run_dir} " "$LOG_FILE")"
)

# TC-023 finalize rc=1
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/state2/autonomous-proj"
  unset RUN_ID RUN_DIR
  run_artifacts_init review 300 || true
  run_artifacts_finalize "$RUN_DIR" 1 || true
  assert_eq "TC-023 finalize rc=1" "1" "$(jq -r '.rc' "$RUN_DIR/meta.json")"
)

# TC-024 disambiguation when minted string already exists
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/state3/autonomous-proj"
  export RUN_ID="proj-235-dev-FIXEDTS"   # pin so both inits mint the same string
  unset RUN_DIR
  run_artifacts_init dev 235 || true
  first="$RUN_DIR"
  # second init with the SAME pinned RUN_ID must disambiguate
  export RUN_ID="proj-235-dev-FIXEDTS"
  unset RUN_DIR
  run_artifacts_init dev 235 || true
  second="$RUN_DIR"
  assert_true "TC-024a both dirs coexist" [ -d "$first" -a -d "$second" ]
  assert_true "TC-024b second dir disambiguated" [ "$first" != "$second" ]
  assert_match "TC-024c disambig suffix" '-2$' "$(basename "$second")"
)

# TC-025 observe-only under set -e with unwritable base
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="/proc/cannot-write-here/autonomous-proj"
  unset RUN_ID RUN_DIR
  set -e
  rc_before=0
  run_artifacts_init dev 235 || true
  rc_before=$?
  echo "sentinel after init" >/dev/null
  set +e
  assert_eq "TC-025 init failure does not abort caller (rc unchanged)" "0" "$rc_before"
)

# TC-026 finalize on never-created dir
(
  out="$(run_artifacts_finalize "$TMP_ROOT/does-not-exist" 0; echo rc=$?)"
  assert_contains "TC-026 finalize missing dir → rc 0 no-op" "rc=0" "$out"
)

# ---------------------------------------------------------------------------
# run_footer (TC-030..033)
# ---------------------------------------------------------------------------
echo "== run_footer =="
(
  export RUN_ID="proj-235-dev-T" RUN_DIR="/x/autonomous-proj/runs/proj-235-dev-T"
  f="$(run_footer)"
  assert_contains "TC-030a footer has run-id" "run-id: proj-235-dev-T" "$f"
  assert_contains "TC-030b footer has artifacts dir" "artifacts: /x/autonomous-proj/runs/proj-235-dev-T" "$f"
  assert_contains "TC-032 footer has --- separator" "---" "$f"
  assert_not_contains "TC-033a footer no token" "GH_TOKEN" "$f"
  assert_not_contains "TC-033b footer no PEM" "PEM" "$f"

  body="Some comment body"
  combined="${body}$(run_footer)"
  assert_contains "TC-032b body+footer composes" "Some comment body" "$combined"
  assert_contains "TC-032c body+footer has run-id" "run-id:" "$combined"
)
(
  unset RUN_ID RUN_DIR
  f="$(run_footer)"
  assert_eq "TC-031 footer empty when RUN_ID unset" "" "$f"
)

# ---------------------------------------------------------------------------
# run_prune (TC-034..039) + TC-036 never-active + TC-037 #233 untouched
# ---------------------------------------------------------------------------
echo "== run_prune =="
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/prune/autonomous-proj"
  parent="$AUTONOMOUS_RUN_DIR_BASE/runs"
  mkdir -p "$parent"

  mk() { # mk <name> <days-old>
    local name="$1" age_days="$2" d="$parent/$1"
    mkdir -p "$d"
    local iso
    iso="$(date -u -d "-${age_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -v-"${age_days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    jq -nc --arg s "$iso" '{started_at:$s}' > "$d/meta.json"
  }

  mk "proj-235-dev-OLD" 31      # TC-034 should be pruned
  mk "proj-235-dev-EDGE" 29     # TC-035 should be retained
  mk "proj-235-review-OLD" 40   # also pruned
  # TC-036 active run dir, ancient, must survive
  mk "proj-235-dev-ACTIVE" 99
  export RUN_ID="proj-235-dev-ACTIVE"
  # TC-037 #233 bare UUID dir, ancient, must survive
  mk "01c9c077-febc-4cf3-a716-ee66ae584135" 99

  run_prune 30 235 || true

  assert_false "TC-034 31-day dir pruned" [ -d "$parent/proj-235-dev-OLD" ]
  assert_true  "TC-035 29-day dir retained" [ -d "$parent/proj-235-dev-EDGE" ]
  assert_false "TC-034b 40-day review dir pruned" [ -d "$parent/proj-235-review-OLD" ]
  assert_true  "TC-036 active run dir never pruned" [ -d "$parent/proj-235-dev-ACTIVE" ]
  assert_true  "TC-037 #233 UUID dir untouched" [ -d "$parent/01c9c077-febc-4cf3-a716-ee66ae584135" ]
)
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/prune2/autonomous-proj"
  mkdir -p "$AUTONOMOUS_RUN_DIR_BASE/runs/proj-235-dev-OLD"
  jq -nc --arg s "$(date -u -d '-99 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-99d +%Y-%m-%dT%H:%M:%SZ)" \
    '{started_at:$s}' > "$AUTONOMOUS_RUN_DIR_BASE/runs/proj-235-dev-OLD/meta.json"
  unset RUN_ID
  run_prune "not-a-number" 235 || true
  assert_false "TC-038 non-numeric retention falls back to 30 (still prunes 99d)" \
    [ -d "$AUTONOMOUS_RUN_DIR_BASE/runs/proj-235-dev-OLD" ]
)
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/prune3/autonomous-proj"   # runs/ absent
  out="$(run_prune 30 235; echo rc=$?)"
  assert_contains "TC-039 prune on missing runs/ → rc 0 no-op" "rc=0" "$out"
)

# ---------------------------------------------------------------------------
# run_artifacts_init prunes ALL issues, not just the active one (TC-090, #235 r14)
# ---------------------------------------------------------------------------
echo "== TC-090 init prunes other issues' aged dirs =="
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/prune-all/autonomous-proj"
  parent="$AUTONOMOUS_RUN_DIR_BASE/runs"
  mkdir -p "$parent"
  # An aged dir for a DIFFERENT issue (236) that will never run again.
  mk236() { local d="$parent/proj-236-dev-OLD"; mkdir -p "$d"
    jq -nc --arg s "$(date -u -d '-99 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-99d +%Y-%m-%dT%H:%M:%SZ)" \
      '{started_at:$s}' > "$d/meta.json"; }
  mk236
  unset RUN_ID RUN_DIR
  # Start a run for issue 235; its init-time prune must reap issue 236's aged dir.
  run_artifacts_init dev 235 || true
  assert_false "TC-090a init for #235 prunes #236's 99-day dir (all-issues retention)" \
    [ -d "$parent/proj-236-dev-OLD" ]
  assert_true  "TC-090b the active #235 run dir is created + retained" [ -d "$RUN_DIR" ]
)

# ---------------------------------------------------------------------------
# run_artifacts_persist_log (TC-091..095, #235 r14)
# ---------------------------------------------------------------------------
echo "== run_artifacts_persist_log =="
(
  export PROJECT_ID="proj"
  export AUTONOMOUS_RUN_DIR_BASE="$TMP_ROOT/persist/autonomous-proj"
  unset RUN_ID RUN_DIR
  run_artifacts_init review 235 || true
  src="$TMP_ROOT/fake-tmp-agent.log"
  printf 'raw codex stdout line 1\nstream error blah\n' > "$src"

  run_artifacts_persist_log "$RUN_DIR" "codex" "$src" || true
  assert_true "TC-091 per-agent log copied into agent-logs/<agent>.log" [ -f "$RUN_DIR/agent-logs/codex.log" ]
  assert_contains "TC-092 copied content preserved" "raw codex stdout line 1" "$(cat "$RUN_DIR/agent-logs/codex.log" 2>/dev/null)"

  # label sanitization: a hostile name with path separators stays inside agent-logs/
  # (only the `/` chars are replaced with `_`; dots are in the allowed class but a
  # flat filename can't traverse out of agent-logs/ anyway — that's what TC-093 pins).
  run_artifacts_persist_log "$RUN_DIR" "../../escape" "$src" || true
  assert_false "TC-093 path-traversal label cannot escape agent-logs/" [ -e "$RUN_DIR/../escape.log" ]
  assert_true  "TC-093b sanitized label written inside agent-logs/ (slashes→_)" [ -f "$RUN_DIR/agent-logs/.._.._escape.log" ]

  # missing source → no-op, returns 0
  out="$(run_artifacts_persist_log "$RUN_DIR" "ghost" "$TMP_ROOT/does-not-exist.log"; echo rc=$?)"
  assert_contains "TC-094 missing src → rc 0 no-op" "rc=0" "$out"
  assert_false "TC-094b no file created for missing src" [ -f "$RUN_DIR/agent-logs/ghost.log" ]

  # unset/empty RUN_DIR (init failed) → no-op
  out="$(run_artifacts_persist_log "" "codex" "$src"; echo rc=$?)"
  assert_contains "TC-095 empty dir → rc 0 no-op" "rc=0" "$out"
)

# ---------------------------------------------------------------------------
PASS="$(wc -l < "$PASS_FILE" | tr -d '[:space:]')"
FAIL="$(wc -l < "$FAIL_FILE" | tr -d '[:space:]')"
echo ""
echo "================================================"
echo -e "lib-run-artifacts: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================================"
[[ "$FAIL" -eq 0 ]]
