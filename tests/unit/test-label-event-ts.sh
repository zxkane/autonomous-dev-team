#!/bin/bash
# test-label-event-ts.sh — issue #323 (#296 second-tier).
#
# Mint `itp_label_event_ts` and migrate the LAST raw-`gh` survivor in
# dispatcher-tick.sh — the best-effort, observe-only TTHW timeline read — behind it.
# Closes dispatcher-tick.sh as a raw-`gh` caller (cutover baseline 67 → 66 sigs).
#
# This suite is the behavior-equivalence proof:
#   1. LEAF GOLDEN — drive the REAL itp_github_label_event_ts with the `gh` BINARY
#      stubbed to a timeline fixture (golden matrix (a)-(g) + malformed + argv-eq);
#   2. ROUTING — the shim forwards to the github leaf (bare expr, 13-shim shape);
#   3. CALLER WIRING — drive the migrated dispatcher-tick.sh snippet (emit WITH /
#      WITHOUT labeled_at; fail-soft);
#   4. LEAF-ABSENT / GUARD — the bare-expression guard short-circuits and the
#      unset/empty-ISSUE_PROVIDER guard/shim-divergence repro must NOT abort;
#   5. SOURCE-SHAPE — shim + leaf present, the migrated call replaces the raw gh,
#      and the guard expression equals the shim's bare dispatch expression.
#
# Hermetic: jq + coreutils + a `gh` BINARY stub. No credentials.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-label-event-ts.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
PROVIDER_LIB="$SCRIPTS/lib-issue-provider.sh"
ITP_GITHUB="$SCRIPTS/providers/itp-github.sh"
TICK="$SCRIPTS/dispatcher-tick.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq()           { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected=[$e]"; echo "      actual=  [$a]"; fi; }
assert_contains()     { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      needle=[$n]"; echo "      haystack=[${h:0:400}]"; fi; }
assert_not_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      should NOT contain: [$n]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

export REPO="example-org/repo-A"

# ===========================================================================
# A `gh` BINARY stub on PATH that:
#   - RECORDS the exact argv (one line per call) to $_ARGV_LOG;
#   - for `gh api …/timeline` returns the timeline fixture in $_TL_FIXTURE
#     (after applying the requested `--jq`, exactly as real `gh api --jq` would);
#   - obeys $_GH_RC to simulate a non-zero exit (case (e)).
# Recording from a standalone PATH stub (not a shell function) means the recorded
# `--jq` line is EXACTLY the program itp_github_label_event_ts emits.
# ===========================================================================
_ARGV_LOG=$(mktemp)
_TL_FIXTURE=$(mktemp)
GH_DIR=$(mktemp -d)
trap 'rm -f "$_ARGV_LOG" "$_TL_FIXTURE"; rm -rf "$GH_DIR"' EXIT

cat > "$GH_DIR/gh" <<EOF
#!/bin/bash
ARGV_LOG='$_ARGV_LOG'
TL_FIXTURE='$_TL_FIXTURE'
EOF
cat >> "$GH_DIR/gh" <<'EOF'
printf '%s\n' "$*" >> "$ARGV_LOG"
[[ -n "${_GH_RC:-}" && "${_GH_RC}" != "0" ]] && exit "${_GH_RC}"
# Find the --jq program (itp_github_label_event_ts emits `gh api PATH --jq PROG`).
jq_prog=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jq_prog="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$jq_prog" ]]; then
  jq -r "$jq_prog" "$TL_FIXTURE"
else
  cat "$TL_FIXTURE"
fi
EOF
chmod +x "$GH_DIR/gh"

# Run a snippet with the leaf in scope and the gh stub on PATH.
# $1 = LABEL fixture content (written to $_TL_FIXTURE before sourcing); $2 = snippet.
leaf_run() {
  local fixture="$1" snippet="$2" rc="${3:-0}"
  printf '%s' "$fixture" > "$_TL_FIXTURE"
  : > "$_ARGV_LOG"
  env PATH="$GH_DIR:$PATH" REPO="$REPO" _GH_RC="$rc" \
  bash -c "
    set -uo pipefail
    ISSUE_PROVIDER=github
    source '$PROVIDER_LIB' 2>/dev/null
    set +e
    $snippet
  "
}

# A timeline fixture: a 'autonomous' labeled event, an unrelated comment, a 'bug'
# labeled event, then a SECOND 'autonomous' labeled event (so (a)/(b) are distinct).
TL_MULTI='[
  {"event":"labeled","label":{"name":"autonomous"},"created_at":"2026-06-01T00:00:00Z"},
  {"event":"commented","created_at":"2026-06-01T00:30:00Z"},
  {"event":"labeled","label":{"name":"bug"},"created_at":"2026-06-01T01:00:00Z"},
  {"event":"labeled","label":{"name":"autonomous"},"created_at":"2026-06-01T02:00:00Z"}
]'
TL_BUG_ONLY='[ {"event":"labeled","label":{"name":"bug"},"created_at":"2026-06-01T01:00:00Z"} ]'
TL_NONE='[ {"event":"commented","created_at":"2026-06-01T00:30:00Z"} ]'

# ===========================================================================
echo "=== Leaf golden — itp_github_label_event_ts (gh BINARY stubbed) ==="
# ===========================================================================

# (a) one labeled event for LABEL → its created_at. (The multi fixture has 2
# autonomous events; (b) covers the 2-event FIRST semantics — here we assert the
# returned value is the FIRST, which doubles as (a)'s "the labeled created_at".)
out="$(leaf_run "$TL_MULTI" 'itp_github_label_event_ts 7 autonomous')"
assert_eq "TC-LABELTS-001/002 (a)+(b) labeled events → the FIRST created_at" \
  "2026-06-01T00:00:00Z" "$out"

# (c) labeled events only for a DIFFERENT label → empty.
out="$(leaf_run "$TL_BUG_ONLY" 'itp_github_label_event_ts 7 autonomous')"
assert_eq "TC-LABELTS-003 (c) only a different-label event → empty" "" "$out"

# (d) no labeled event at all → empty.
out="$(leaf_run "$TL_NONE" 'itp_github_label_event_ts 7 autonomous')"
assert_eq "TC-LABELTS-004 (d) no labeled event → empty" "" "$out"

# (e) gh non-zero exit → empty (fail-soft via `2>/dev/null || true`).
out="$(leaf_run "$TL_MULTI" 'itp_github_label_event_ts 7 autonomous' 7)"
assert_eq "TC-LABELTS-005 (e) gh non-zero → empty (fail-soft)" "" "$out"

# (f) injection — selector NOT widened. Hostile LABEL against a timeline that has
# ONLY a bug event: a RAW interpolation would widen the selector and return the bug
# created_at; the JSON-encoded leaf returns EMPTY (the literal never matches).
HOSTILE='autonomous" or .label.name == "bug'
out="$(leaf_run "$TL_BUG_ONLY" "itp_github_label_event_ts 7 '$HOSTILE'")"
assert_eq "TC-LABELTS-006 (f) injection label → empty (selector NOT widened to bug)" "" "$out"

# (f) quote-bearing valid label → no jq syntax error (clean empty), stderr clean.
err="$(leaf_run "$TL_BUG_ONLY" 'itp_github_label_event_ts 7 '\''release"v2'\''' 2>&1 1>/dev/null)"
out="$(leaf_run "$TL_BUG_ONLY" 'itp_github_label_event_ts 7 '\''release"v2'\''' 2>/dev/null)"
assert_eq "TC-LABELTS-007 (f) quote-bearing valid label → empty (no match)" "" "$out"
assert_not_contains "TC-LABELTS-007 (f) quote-bearing valid label → NO jq syntax error" \
  "syntax error" "$err"

# (g) source uses --arg lbl (NOT --arg label — jq-1.6 reserves `label`).
src_leaf="$(cat "$ITP_GITHUB")"
assert_contains "TC-LABELTS-008 (g) leaf encodes via --arg lbl" '--arg lbl ' "$src_leaf"
# The leaf MUST NOT bind via `--arg label` (jq keyword). (Match the flag form so a
# prose mention of the word 'label' elsewhere does not false-positive.)
assert_not_contains "TC-LABELTS-008 (g) leaf does NOT use the reserved --arg label" \
  '--arg label ' "$src_leaf"

# argv-equivalence for LABEL=autonomous: the recorded `gh api …/timeline --jq …`
# program equals today's inline selector, against repos/$REPO/issues/<n>/timeline.
leaf_run "$TL_MULTI" 'itp_github_label_event_ts 7 autonomous' >/dev/null
recorded="$(cat "$_ARGV_LOG")"
EXPECTED_ARGV='api repos/example-org/repo-A/issues/7/timeline --jq map(select(.event == "labeled" and .label.name == "autonomous")) | (.[0].created_at // empty)'
assert_eq "TC-LABELTS-009 argv-equivalence: gh api …/timeline --jq == today's inline selector (LABEL=autonomous)" \
  "$EXPECTED_ARGV" "$recorded"

# malformed/non-array gh response → map() errors → swallowed → empty.
out="$(leaf_run '{}' 'itp_github_label_event_ts 7 autonomous')"
assert_eq "TC-LABELTS-010 malformed (non-array) gh response → empty (map() error swallowed, identical to today)" \
  "" "$out"

# ===========================================================================
echo ""
echo "=== Routing — shim → leaf ==="
# ===========================================================================
routed="$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" \
  bash -c '
    source "'"$PROVIDER_LIB"'" 2>/dev/null
    itp_github_label_event_ts() { echo "TS-ROUTED:[$1][$2]"; }
    itp_label_event_ts 7 autonomous
  '
)"
assert_contains "TC-LABELTS-020 itp_label_event_ts routes to itp_github_label_event_ts (issue+label forwarded)" \
  "TS-ROUTED:[7][autonomous]" "$routed"

# Shim source-shape: the bare itp_${ISSUE_PROVIDER}_label_event_ts "$@" form,
# matching all 13 existing shims (no :-github default).
src_provider="$(cat "$PROVIDER_LIB")"
assert_contains "TC-LABELTS-021 shim is the bare itp_\${ISSUE_PROVIDER}_label_event_ts \"\$@\" form" \
  'itp_label_event_ts()       { itp_${ISSUE_PROVIDER}_label_event_ts "$@"; }' "$src_provider"

# ===========================================================================
echo ""
echo "=== Caller wiring — the migrated dispatcher-tick.sh snippet ==="
# ===========================================================================
# Drive the EXACT migrated emit block (too heavy to run the full tick). The block:
#   - guards on `declare -F "itp_${ISSUE_PROVIDER}_label_event_ts"` (BARE expr);
#   - emits issue_labeled WITH labeled_at when the verb returns a ts, WITHOUT when
#     empty;
#   - never aborts the tick.
# We capture metrics_emit's argv via a stub.
caller_block() {
  cat <<'BLK'
_labeled_at=""
if declare -F "itp_${ISSUE_PROVIDER}_label_event_ts" >/dev/null 2>&1; then
  _labeled_at="$(itp_label_event_ts "$issue_num" "autonomous")"
fi
if [[ -n "${_labeled_at:-}" ]]; then
  metrics_emit issue_labeled "issue=${issue_num}" "labeled_at=${_labeled_at}" || true
else
  metrics_emit issue_labeled "issue=${issue_num}" || true
fi
unset _labeled_at
BLK
}

# labeled_at PRESENT → emit WITH labeled_at.
emit="$(
  env REPO="$REPO" \
  bash -c '
    set -euo pipefail
    ISSUE_PROVIDER=github
    issue_num=7
    metrics_emit() { printf "EMIT:%s\n" "$*"; }
    itp_github_label_event_ts() { :; }   # presence makes the guard pass
    itp_label_event_ts() { echo "2026-06-01T00:00:00Z"; }
    '"$(caller_block)"'
  '
)"
assert_eq "TC-LABELTS-031 labeled_at present → emit WITH labeled_at" \
  "EMIT:issue_labeled issue=7 labeled_at=2026-06-01T00:00:00Z" "$emit"

# labeled_at EMPTY → emit WITHOUT labeled_at.
emit="$(
  env REPO="$REPO" \
  bash -c '
    set -euo pipefail
    ISSUE_PROVIDER=github
    issue_num=7
    metrics_emit() { printf "EMIT:%s\n" "$*"; }
    itp_github_label_event_ts() { :; }
    itp_label_event_ts() { echo ""; }     # empty → fall back to ts
    '"$(caller_block)"'
  '
)"
assert_eq "TC-LABELTS-032 labeled_at empty → emit WITHOUT labeled_at (aggregator falls back to ts)" \
  "EMIT:issue_labeled issue=7" "$emit"

# ===========================================================================
echo ""
echo "=== Leaf-absent / guard (best-effort, never aborts the tick) ==="
# ===========================================================================
# (i) leaf UNDEFINED → the declare -F guard short-circuits; itp_label_event_ts is
#     NOT invoked; emit happens WITHOUT labeled_at; rc 0.
emit="$(
  env REPO="$REPO" \
  bash -c '
    set -euo pipefail
    ISSUE_PROVIDER=github
    issue_num=7
    metrics_emit() { printf "EMIT:%s\n" "$*"; }
    # leaf itp_github_label_event_ts is UNDEFINED on purpose.
    itp_label_event_ts() { echo "SHOULD-NOT-BE-CALLED"; }
    '"$(caller_block)"'
  '
)"; rc=$?
assert_eq "TC-LABELTS-033 (i) leaf-absent guard short-circuits → emit WITHOUT labeled_at, verb NOT invoked" \
  "EMIT:issue_labeled issue=7" "$emit"
assert_eq "TC-LABELTS-033 (i) leaf-absent path exits 0 (no abort)" "0" "$rc"

# (ii) guard/shim expression-equality repro: ISSUE_PROVIDER set-EMPTY + the REAL
#      shim (bare itp_${ISSUE_PROVIDER}_…). A `:-github` guard would PASS (checks
#      itp_github_…, defined) then the bare shim calls itp__… (undefined) → set -e
#      abort rc 127. The BARE guard (identical to the shim) FAILS → skip → no abort,
#      labeled_at empty, tick continues.
out="$(
  env REPO="$REPO" \
  bash -c '
    set -euo pipefail
    ISSUE_PROVIDER=""                       # set-empty (survives set -u)
    issue_num=7
    metrics_emit() { printf "EMIT:%s\n" "$*"; }
    itp_github_label_event_ts() { echo "GH-TS"; }            # github leaf defined
    itp_label_event_ts() { itp_${ISSUE_PROVIDER}_label_event_ts "$@"; }  # REAL bare shim
    '"$(caller_block)"'
    echo "TICK-CONTINUED"
  ' 2>&1
)"; rc=$?
assert_contains "TC-LABELTS-034 (ii) empty-ISSUE_PROVIDER + bare guard → tick CONTINUES (no command-not-found abort)" \
  "TICK-CONTINUED" "$out"
assert_contains "TC-LABELTS-034 (ii) empty-ISSUE_PROVIDER → emit WITHOUT labeled_at" \
  "EMIT:issue_labeled issue=7" "$out"
assert_not_contains "TC-LABELTS-034 (ii) empty-ISSUE_PROVIDER → no undefined-leaf invocation" \
  "command not found" "$out"
assert_eq "TC-LABELTS-034 (ii) empty-ISSUE_PROVIDER path exits 0 (the guard/shim-divergence is closed)" \
  "0" "$rc"

# Negative control: the BUGGY :-github guard against the same bare shim DOES abort,
# proving the divergence is real and the bare-guard choice is load-bearing.
buggy_rc=0
env REPO="$REPO" \
bash -c '
  set -euo pipefail
  ISSUE_PROVIDER=""
  issue_num=7
  metrics_emit() { :; }
  itp_github_label_event_ts() { echo "GH-TS"; }
  itp_label_event_ts() { itp_${ISSUE_PROVIDER}_label_event_ts "$@"; }
  if declare -F "itp_${ISSUE_PROVIDER:-github}_label_event_ts" >/dev/null 2>&1; then
    _x="$(itp_label_event_ts "$issue_num" "autonomous")"   # calls itp__… → abort
  fi
' >/dev/null 2>&1 || buggy_rc=$?
assert_eq "TC-LABELTS-034 NEGATIVE control: the :-github guard against a bare shim DOES abort (rc≠0) — divergence is real" \
  "1" "$([[ "$buggy_rc" -ne 0 ]] && echo 1 || echo 0)"

# ===========================================================================
echo ""
echo "=== Source-shape regression guards ==="
# ===========================================================================
tick_src="$(cat "$TICK")"

# The migrated site calls the verb, not raw gh api …/timeline.
assert_contains "TC-LABELTS-030 dispatcher-tick.sh calls itp_label_event_ts \"\$issue_num\" \"autonomous\"" \
  'itp_label_event_ts "$issue_num" "autonomous"' "$tick_src"

# No executable raw gh api …/timeline survives (strip leading-whitespace comments
# first, the same classifier the cutover guard uses).
n_tl="$(grep -aE '(^|[^A-Za-z_-])gh ' "$TICK" \
  | awk '{s=$0;sub(/^[[:space:]]+/,"",s); if(substr(s,1,1)=="#")next; print s}' \
  | grep -c 'gh api .*timeline' || true)"
assert_eq "TC-LABELTS-030 dispatcher-tick.sh has ZERO executable raw 'gh api …/timeline'" "0" "$n_tl"

# The guard expression in dispatcher-tick.sh equals the shim's bare dispatch expr.
assert_contains "TC-LABELTS-035 caller guard uses the BARE itp_\${ISSUE_PROVIDER}_label_event_ts (identical to the shim)" \
  'declare -F "itp_${ISSUE_PROVIDER}_label_event_ts"' "$tick_src"
# and NOT a :-github guard for this verb (the R2 divergence).
assert_not_contains "TC-LABELTS-035 caller guard does NOT use a :-github default for label_event_ts (R2 divergence closed)" \
  'itp_${ISSUE_PROVIDER:-github}_label_event_ts' "$tick_src"

# New shim + leaf present in the seam files.
assert_contains "TC-LABELTS-041 shim itp_label_event_ts present in lib-issue-provider.sh" \
  'itp_label_event_ts()' "$src_provider"
assert_contains "TC-LABELTS-041 leaf itp_github_label_event_ts present in providers/itp-github.sh" \
  'itp_github_label_event_ts()' "$src_leaf"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
