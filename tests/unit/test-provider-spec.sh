#!/bin/bash
# test-provider-spec.sh — issue #279 / INV-87..INV-90 (issue reserved INV-86..89;
# rebased +1 after PR #278 took INV-86 — see TC-PROVIDER-SPEC-012).
#
# Validates the NORMATIVE provider-spec (docs/pipeline/provider-spec.md) and its
# coupled doc edits (invariants.md INV-87..INV-90, state-machine.md abstract-state
# note). This is a DOCS-PR shaped test, modeled on
# tests/unit/test-adapter-spec-schemas.sh (#229 / INV-66 precedent): it asserts the
# SPEC artifacts are internally consistent (every ITP/CHP verb, every capability
# key, the normalized comment-shape literal, the four new INV headings + their
# triage tags, the abstract-state note) — NOT any runtime wrapper/lib behavior. No
# wrapper / lib-dispatch.sh / lib-review-*.sh code is exercised.
#
# Per issue #279 Out-of-Scope: there are deliberately NO golden-trace,
# capability-branch (fake-provider), dispatch-routing, or .caps-parse runtime tests
# here — those gate the code-bearing sibling issues (dispatch-skeleton-caps-reader,
# itp/chp migrations). This PR ships only the doc-consistency test.
#
# Runs credential-free on bare ubuntu-latest with only grep + awk (no jq, no python,
# no network). Auto-discovered by ci.yml's hermetic-unit `for test in
# tests/unit/test-*.sh` loop — no CI workflow edit needed.
#
# Run: bash tests/unit/test-provider-spec.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPEC="$PROJECT_ROOT/docs/pipeline/provider-spec.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
STATE_MACHINE="$PROJECT_ROOT/docs/pipeline/state-machine.md"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
ITP_LIB="$SCRIPTS_DIR/lib-issue-provider.sh"
CHP_LIB="$SCRIPTS_DIR/lib-code-host.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

# assert_grep <desc> <pattern> <file> — fixed-string by default (-F) so verb names
# and the comment-shape literal match verbatim without regex escaping surprises.
assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then ok "$desc"; else bad "$desc (missing: $pattern)"; fi
}
# assert_grep_re <desc> <ere> <file> — extended-regex variant for anchored patterns.
assert_grep_re() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then ok "$desc"; else bad "$desc (missing /$pattern/)"; fi
}

# spec_verbs <section-start-re> <section-end-re> <prefix> <spec-file> — DERIVE the
# verb set from the spec's §3.1/§3.2 tables rather than a hand-maintained literal
# array (#367 R2: a hardcoded list silently stops covering the shipped surface the
# next time a verb is added). Walks each `| `<prefix>_<verb>` ...` cell between the
# two section headings and extracts every `<prefix>_[a-zA-Z_]+` token, sorted+uniqued
# (one verb row, chp_review_threads/chp_resolve_thread, names two verbs in one cell).
spec_verbs() {
  local start_re="$1" end_re="$2" prefix="$3" file="$4"
  awk -v start="$start_re" -v end="$end_re" -v pfx="$prefix" '
    $0 ~ start { f = 1; next }
    $0 ~ end   { f = 0 }
    f && /^\|/ {
      n = split($0, parts, "|")
      col = parts[2]
      pat = "`" pfx "_[a-zA-Z_]+"
      while (match(col, pat)) {
        print substr(col, RSTART + 1, RLENGTH - 1)
        col = substr(col, RSTART + RLENGTH)
      }
    }
  ' "$file" | sort -u
}

# shipped_shims <lib-file> <prefix> — DERIVE the verb set from the ACTUAL shipped
# dispatch shims (`^<prefix>_[a-zA-Z_]+\(\)` at column 0), the other half of the
# derive-from-spec cross-check (#367 R2): a new shim minted WITHOUT a matching spec
# row must fail this file's TC-PROVIDER-SPEC-016/017 comparison, and a new spec row
# minted WITHOUT a shipped shim must fail it too. `chp_has_leaf` is EXCLUDED — it is
# documented in provider-spec.md §3.2 as a caller-side guard helper, not a verb (see
# "What this section owns").
shipped_shims() {
  local file="$1" prefix="$2"
  grep -oE "^${prefix}_[a-zA-Z_]+\\(\\)" "$file" 2>/dev/null \
    | sed -E 's/\(\)$//' | grep -v "^${prefix}_has_leaf$" | sort -u
}

# The ITP verbs (spec §3.1) and CHP verbs (spec §3.2), DERIVED from the spec's own
# tables — not a hardcoded count. (itp_label_event_ts is the #323 second-tier
# observe-only TTHW verb; chp_review_threads/chp_resolve_thread share one table row.)
mapfile -t ITP_VERBS < <(spec_verbs '^### 3\.1' '^### 3\.2' itp "$SPEC")
mapfile -t CHP_VERBS < <(spec_verbs '^### 3\.2' '^### 3\.3' chp "$SPEC")
# The ACTUAL shipped shims, DERIVED from the real lib-*.sh dispatch files — the
# ground truth TC-PROVIDER-SPEC-016/017 reconcile the spec-derived sets against.
mapfile -t ITP_SHIMS < <(shipped_shims "$ITP_LIB" itp)
mapfile -t CHP_SHIMS < <(shipped_shims "$CHP_LIB" chp)
# The 10 ITP + 4 CHP capability keys (spec §4; `assignees` added #435).
ITP_CAPS=(
  server_side_state_and server_side_state_negation distinct_bot_author
  read_after_write_state cross_ref_shorthand body_checkbox edit_comment
  label_colors marker_channel assignees
)
CHP_CAPS=(
  native_issue_pr_link rest_request_changes review_bots merge_closes_issue
)
# Real function names the verb↔current-function mapping appendix MUST cite (spec §7.1).
MAPPING_FNS=(
  count_active list_new_issues list_pending_review list_pending_dev list_stale_candidates
  list_hygiene_residue label_swap resolve_dep_state check_deps_resolved mark_stalled
  handle_completed_session_routing fetch_pr_for_issue ci_is_green
)

echo "=== TC-PROVIDER-SPEC-001: provider-spec.md present ==="
if [[ -f "$SPEC" ]]; then ok "provider-spec.md present"; else bad "provider-spec.md MISSING"; fi

echo "=== TC-PROVIDER-SPEC-002: NORMATIVE + RFC-2119 keyword paragraph ==="
assert_grep "declares status NORMATIVE" "NORMATIVE" "$SPEC"
assert_grep "carries the RFC 2119 keyword reference" "RFC 2119" "$SPEC"
assert_grep "MUST NOT redefine clause (later issues implement)" "MUST NOT redefine" "$SPEC"

echo "=== TC-PROVIDER-SPEC-003: both config keys with defaults ==="
assert_grep "documents ISSUE_PROVIDER" "ISSUE_PROVIDER" "$SPEC"
assert_grep "documents CODE_HOST" "CODE_HOST" "$SPEC"

echo "=== TC-PROVIDER-SPEC-004: all spec-derived ITP verbs verbatim (${#ITP_VERBS[@]} found in §3.1) ==="
for v in "${ITP_VERBS[@]}"; do assert_grep "ITP verb $v" "$v" "$SPEC"; done

echo "=== TC-PROVIDER-SPEC-005: all spec-derived CHP verbs verbatim (${#CHP_VERBS[@]} found in §3.2) ==="
for v in "${CHP_VERBS[@]}"; do assert_grep "CHP verb $v" "$v" "$SPEC"; done

echo "=== TC-PROVIDER-SPEC-016: spec §3.1 ITP verb set == shipped lib-issue-provider.sh shim set (derive-from-spec, R2) ==="
# The core reconciliation this issue (#367) exists for: a shim minted WITHOUT a
# spec row, or a spec row minted WITHOUT a shipped shim, must turn this RED — not
# a hand-maintained count that silently stops covering the shipped surface.
itp_spec_joined=$(printf '%s\n' "${ITP_VERBS[@]}")
itp_shim_joined=$(printf '%s\n' "${ITP_SHIMS[@]}")
if [[ "$itp_spec_joined" == "$itp_shim_joined" ]]; then
  ok "spec §3.1 ITP verb set (${#ITP_VERBS[@]}) == shipped lib-issue-provider.sh shims (${#ITP_SHIMS[@]})"
else
  bad "spec §3.1 ITP verb set != shipped shims"
  comm -3 <(printf '%s\n' "${ITP_VERBS[@]}") <(printf '%s\n' "${ITP_SHIMS[@]}") | sed 's/^/      diff: /'
fi

echo "=== TC-PROVIDER-SPEC-017: spec §3.2 CHP verb set == shipped lib-code-host.sh shim set (derive-from-spec, R2) ==="
chp_spec_joined=$(printf '%s\n' "${CHP_VERBS[@]}")
chp_shim_joined=$(printf '%s\n' "${CHP_SHIMS[@]}")
if [[ "$chp_spec_joined" == "$chp_shim_joined" ]]; then
  ok "spec §3.2 CHP verb set (${#CHP_VERBS[@]}) == shipped lib-code-host.sh shims (${#CHP_SHIMS[@]})"
else
  bad "spec §3.2 CHP verb set != shipped shims"
  comm -3 <(printf '%s\n' "${CHP_VERBS[@]}") <(printf '%s\n' "${CHP_SHIMS[@]}") | sed 's/^/      diff: /'
fi

echo "=== TC-PROVIDER-SPEC-018: NEGATIVE proof — a shim added to a SCRATCH COPY without a spec row turns TC-017 RED ==="
# Mirrors the guard's scratch-copy pattern (test-provider-cutover.sh::fresh_scratch /
# test-spec-drift.sh) — never mutates the committed tree. Appends a fake shim to a
# scratch copy of lib-code-host.sh, then re-runs the SAME derive-from-spec
# reconciliation against the scratch copy + the real (unmodified) spec, asserting it
# fails naming the unlisted shim — the automated demonstration AC1 requires.
NEG_WORK=$(mktemp -d)
scratch_chp_lib="$NEG_WORK/lib-code-host.sh"
cp "$CHP_LIB" "$scratch_chp_lib"
printf '\nchp_frobnicate_unlisted() { chp_${CODE_HOST}_frobnicate_unlisted "$@"; }\n' >> "$scratch_chp_lib"
mapfile -t chp_scratch_shims < <(shipped_shims "$scratch_chp_lib" chp)
scratch_joined=$(printf '%s\n' "${chp_scratch_shims[@]}")
if [[ "$scratch_joined" != "$chp_spec_joined" ]] && grep -qx "chp_frobnicate_unlisted" <<<"$scratch_joined"; then
  ok "scratch shim WITHOUT a spec row (chp_frobnicate_unlisted) makes the derive-from-spec reconciliation RED — the negative proof AC1 requires"
else
  bad "scratch shim injection did not turn the reconciliation red — the derive-from-spec assertion is not catching an unlisted shim"
fi
rm -rf "$NEG_WORK"

echo "=== TC-PROVIDER-SPEC-006: all 14 capability keys ==="
for c in "${ITP_CAPS[@]}"; do assert_grep "ITP cap $c" "$c" "$SPEC"; done
for c in "${CHP_CAPS[@]}"; do assert_grep "CHP cap $c" "$c" "$SPEC"; done

echo "=== TC-PROVIDER-SPEC-007: normalized comment-shape literal ==="
assert_grep "comment-shape literal [{id, author, body, createdAt}]" "[{id, author, body, createdAt}]" "$SPEC"
assert_grep "authorKind enum named" "authorKind" "$SPEC"

echo "=== TC-PROVIDER-SPEC-008: GitHub caps pin today's behavior ==="
assert_grep "server_side_state_negation=0 pinned" "server_side_state_negation=0" "$SPEC"
assert_grep "native_issue_pr_link=0 pinned" "native_issue_pr_link=0" "$SPEC"
assert_grep "marker_channel=html pinned" "marker_channel=html" "$SPEC"

echo "=== TC-PROVIDER-SPEC-009: verb↔function mapping appendix cites real names ==="
for fn in "${MAPPING_FNS[@]}"; do assert_grep "mapping cites $fn" "$fn" "$SPEC"; done
assert_grep "tags entangled multi-op orchestrators" "entangled" "$SPEC"
assert_grep "tags separable-leaf functions" "separable-leaf" "$SPEC"

echo "=== TC-PROVIDER-SPEC-010: INV-77 verdict-reconciliation section ==="
assert_grep "reconciles INV-77 verdict channel" "INV-77" "$SPEC"

echo "=== TC-PROVIDER-SPEC-011: §auth per-seam ownership boundary ==="
assert_grep "auth pins INV-83 ITP-side" "INV-83" "$SPEC"
assert_grep "auth pins INV-79 CHP-side" "INV-79" "$SPEC"

# The four provider invariants. Issue #279 reserved INV-86..INV-89 ("the next free
# numbers above INV-85"), but PR #278 (issue #277, PR↔issue linkage) merged first and
# claimed INV-86, so this PR rebased its four onto the next-free band INV-87..INV-90 —
# the standard INV-collision-via-rebase renumber. The issue's intent ("the four new
# provider invariants, each machine-checked") is preserved; only the numbers shifted.
PROVIDER_INVS=(87 88 89 90)

echo "=== TC-PROVIDER-SPEC-012: invariants.md provider INV headings (INV-87..INV-90) ==="
for n in "${PROVIDER_INVS[@]}"; do
  assert_grep_re "invariants.md has ^## INV-$n:" "^## INV-$n:" "$INVARIANTS"
done

echo "=== TC-PROVIDER-SPEC-013: each new INV carries an adjacent machine-checked triage tag ==="
# Each provider INV MUST have a `_Triage (issue #236): [machine-checked:
# tests/unit/test-provider-spec.sh]_` line within 2 lines of its heading (the same
# adjacency rule test-spec-drift.sh TC-SPEC-GATE-040/041 enforces). awk records the
# line of each target heading, then checks the next-or-second line is the tag.
for n in "${PROVIDER_INVS[@]}"; do
  if awk -v inv="^## INV-$n:" '
        $0 ~ inv { h = NR; next }
        h && NR - h <= 2 && /^_Triage \(issue #236\): \[machine-checked: tests\/unit\/test-provider-spec\.sh\]_/ { found = 1 }
        h && NR - h > 2 { h = 0 }
        END { exit (found ? 0 : 1) }
      ' "$INVARIANTS"; then
    ok "INV-$n carries an adjacent machine-checked triage tag pointing at this test"
  else
    bad "INV-$n missing an adjacent _Triage (issue #236): [machine-checked: tests/unit/test-provider-spec.sh]_ tag"
  fi
done

echo "=== TC-PROVIDER-SPEC-014: state-machine.md abstract-state-per-backend note ==="
assert_grep "states are abstract / rendered per-backend" "abstract" "$STATE_MACHINE"
assert_grep "single-select custom field rendering named" "single-select" "$STATE_MACHINE"

echo "=== TC-PROVIDER-SPEC-015: companion design + test-case docs present ==="
# The autonomous-dev review checklist requires a design canvas under docs/designs/
# (or docs/plans/) and a test-case doc under docs/test-cases/ for the feature.
if [[ -f "$PROJECT_ROOT/docs/designs/provider-spec.md" ]]; then
  ok "design canvas present: docs/designs/provider-spec.md"
else
  bad "design canvas MISSING: docs/designs/provider-spec.md"
fi
if [[ -f "$PROJECT_ROOT/docs/test-cases/provider-spec.md" ]]; then
  ok "test-case doc present: docs/test-cases/provider-spec.md"
else
  bad "test-case doc MISSING: docs/test-cases/provider-spec.md"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
