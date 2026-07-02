#!/bin/bash
# test-spec-drift.sh — issue #236, executable-spec gate (TC-SPEC-GATE-NNN).
#
# Exercises the spec artifacts and the drift checker WITHOUT touching any live
# dispatch path:
#   - transitions.json + observation-snapshot.json schema validation (golden +
#     negatives), backend-detect (python jsonschema preferred, jq fallback) —
#     mirrors tests/unit/test-adapter-spec-schemas.sh (#229/#230).
#   - generator idempotence + bidirectional drift injection.
#   - guard/action mapping: removing a mapping → red naming the token; a stale
#     predicate → red naming it.
#   - label-write completeness: a new undeclared label write → red naming it.
#   - invariant triage: every INV heading carries exactly one valid triage tag.
#
# All mutating cases operate on SCRATCH copies under a mktemp dir; the committed
# repo files are never modified. Runs on bare ubuntu-latest (jq + coreutils),
# no credentials.
#
# Run: bash tests/unit/test-spec-drift.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
DOCS="$PROJECT_ROOT/docs/pipeline"
SCHEMA_DIR="$DOCS/schemas"
EXAMPLE_DIR="$SCHEMA_DIR/examples"
GEN="$SCRIPTS/gen-state-machine.sh"
CHECK="$SCRIPTS/check-spec-drift.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
note() { echo -e "  ${YELLOW}NOTE${NC}: $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then HAVE_PY=1; fi
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

# ---------------------------------------------------------------------------
# Schema validation backend (python preferred, jq structural fallback).
# ---------------------------------------------------------------------------
validate_py() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from jsonschema import Draft7Validator
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
sys.exit(1 if list(Draft7Validator(schema).iter_errors(inst)) else 0)
PY
}

# ===========================================================================
echo "=== TC-SPEC-GATE-001: schemas present + valid Draft-07 ==="
for s in transitions observation-snapshot; do
  f="$SCHEMA_DIR/$s.schema.json"
  if [[ -f "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then ok "schema well-formed: $s.schema.json"; else bad "schema missing/malformed: $s.schema.json"; fi
done
if [[ "$HAVE_PY" -eq 1 ]]; then
  for s in transitions observation-snapshot; do
    if python3 - "$SCHEMA_DIR/$s.schema.json" <<'PY' >/dev/null 2>&1
import json, sys
from jsonschema import Draft7Validator
Draft7Validator.check_schema(json.load(open(sys.argv[1])))
PY
    then ok "valid Draft-07 schema: $s"; else bad "invalid Draft-07 schema: $s"; fi
  done
else
  note "python3 jsonschema unavailable — structural jq checks only for schema validity"
fi

# ===========================================================================
echo "=== TC-SPEC-GATE-002/003/004: transitions.json + golden accept + negative reject ==="
if jq -e . "$DOCS/transitions.json" >/dev/null 2>&1; then ok "transitions.json well-formed"; else bad "transitions.json malformed"; fi
if [[ "$HAVE_PY" -eq 1 ]]; then
  if validate_py "$SCHEMA_DIR/transitions.schema.json" "$DOCS/transitions.json"; then ok "transitions.json validates against schema"; else bad "transitions.json REJECTED by its schema"; fi
  for f in "$EXAMPLE_DIR"/transitions.golden.*.json; do
    if validate_py "$SCHEMA_DIR/transitions.schema.json" "$f"; then ok "golden accepts: $(basename "$f")"; else bad "golden REJECTED: $(basename "$f")"; fi
  done
  for f in "$EXAMPLE_DIR"/transitions.negative.*.json; do
    if validate_py "$SCHEMA_DIR/transitions.schema.json" "$f"; then bad "negative ACCEPTED: $(basename "$f")"; else ok "negative rejected: $(basename "$f")"; fi
  done
else
  # jq structural fallback: golden has schema_version+transitions; negatives miss a required bit.
  for f in "$EXAMPLE_DIR"/transitions.golden.*.json; do
    if jq -e 'has("schema_version") and has("transitions") and (.transitions[0] | has("mermaid"))' "$f" >/dev/null 2>&1; then ok "golden structurally valid: $(basename "$f")"; else bad "golden missing required keys: $(basename "$f")"; fi
  done
  # no-schema-version negative
  if jq -e 'has("schema_version") | not' "$EXAMPLE_DIR/transitions.negative.no-schema-version.json" >/dev/null 2>&1; then ok "no-schema-version negative lacks schema_version"; else bad "no-schema-version negative unexpectedly has schema_version"; fi
  # missing-mermaid negative
  if jq -e '.transitions[0] | (has("mermaid") | not)' "$EXAMPLE_DIR/transitions.negative.missing-mermaid.json" >/dev/null 2>&1; then ok "missing-mermaid negative lacks mermaid"; else bad "missing-mermaid negative unexpectedly has mermaid"; fi
fi

# ===========================================================================
echo "=== TC-SPEC-GATE-005/006: observation-snapshot golden accept + negative reject ==="
if [[ "$HAVE_PY" -eq 1 ]]; then
  for f in "$EXAMPLE_DIR"/observation-snapshot.golden.*.json; do
    if validate_py "$SCHEMA_DIR/observation-snapshot.schema.json" "$f"; then ok "snapshot golden accepts: $(basename "$f")"; else bad "snapshot golden REJECTED: $(basename "$f")"; fi
  done
  for f in "$EXAMPLE_DIR"/observation-snapshot.negative.*.json; do
    if validate_py "$SCHEMA_DIR/observation-snapshot.schema.json" "$f"; then bad "snapshot negative ACCEPTED: $(basename "$f")"; else ok "snapshot negative rejected: $(basename "$f")"; fi
  done
else
  # jq fallback: bad-liveness-state has an out-of-enum liveness.state; missing-liveness lacks liveness.
  if jq -e '(.liveness.state | IN("alive","dead","indeterminate") | not)' "$EXAMPLE_DIR/observation-snapshot.negative.bad-liveness-state.json" >/dev/null 2>&1; then ok "bad-liveness-state negative has out-of-enum state"; else bad "bad-liveness-state negative state unexpectedly in enum"; fi
  if jq -e 'has("liveness") | not' "$EXAMPLE_DIR/observation-snapshot.negative.missing-liveness.json" >/dev/null 2>&1; then ok "missing-liveness negative lacks liveness"; else bad "missing-liveness negative unexpectedly has liveness"; fi
fi

# ===========================================================================
echo "=== TC-SPEC-GATE-011: gen --check passes against the committed doc ==="
if bash "$GEN" --check >/dev/null 2>&1; then ok "committed state-machine.md is in sync with transitions.json"; else bad "committed state-machine.md is OUT OF SYNC (run scripts/gen-state-machine.sh)"; fi

echo "=== TC-SPEC-GATE-015: marker region present exactly once ==="
nb=$(grep -c 'BEGIN GENERATED: state-machine' "$DOCS/state-machine.md")
ne=$(grep -c 'END GENERATED: state-machine' "$DOCS/state-machine.md")
if [[ "$nb" -eq 1 && "$ne" -eq 1 ]]; then ok "exactly one BEGIN + one END marker"; else bad "marker count begin=$nb end=$ne (expected 1/1)"; fi

echo "=== TC-SPEC-GATE-010: generator idempotence ==="
cp "$DOCS/state-machine.md" "$WORK/sm.md"
bash "$GEN" --transitions "$DOCS/transitions.json" --doc "$WORK/sm.md" >/dev/null 2>&1
cp "$WORK/sm.md" "$WORK/sm.1.md"
bash "$GEN" --transitions "$DOCS/transitions.json" --doc "$WORK/sm.md" >/dev/null 2>&1
if diff -q "$WORK/sm.1.md" "$WORK/sm.md" >/dev/null 2>&1; then ok "generator is idempotent (2nd run = no-op)"; else bad "generator NOT idempotent"; fi

echo "=== TC-SPEC-GATE-014: generator preserves content outside the markers ==="
# The committed doc, re-generated, must keep its first + last lines (outside markers).
head -1 "$DOCS/state-machine.md" > "$WORK/head.expect"
head -1 "$WORK/sm.md" > "$WORK/head.got"
tail -1 "$DOCS/state-machine.md" > "$WORK/tail.expect"
tail -1 "$WORK/sm.md" > "$WORK/tail.got"
if diff -q "$WORK/head.expect" "$WORK/head.got" >/dev/null && diff -q "$WORK/tail.expect" "$WORK/tail.got" >/dev/null; then
  ok "content outside markers preserved (first + last line unchanged)"
else bad "generator altered content outside the markers"; fi

echo "=== TC-SPEC-GATE-012: DRIFT A — edit a mermaid edge in the table → red ==="
jq '(.transitions[] | select(.id=="dispatch-new").mermaid) = "autonomous --> in_progress: TAMPERED"' \
  "$DOCS/transitions.json" > "$WORK/t-drift.json"
if bash "$GEN" --check --transitions "$WORK/t-drift.json" --doc "$DOCS/state-machine.md" >/dev/null 2>&1; then
  bad "DRIFT A not detected (table edit should fail --check)"
else ok "DRIFT A detected (table edit → --check red)"; fi

echo "=== TC-SPEC-GATE-013: DRIFT B — hand-edit inside the marker region → red ==="
cp "$DOCS/state-machine.md" "$WORK/sm-drift.md"
sed -i 's|autonomous --> in_progress: Dispatcher Step 2 scan-new (deps resolved)|autonomous --> in_progress: HAND EDITED|' "$WORK/sm-drift.md"
if bash "$GEN" --check --transitions "$DOCS/transitions.json" --doc "$WORK/sm-drift.md" >/dev/null 2>&1; then
  bad "DRIFT B not detected (in-marker hand-edit should fail --check)"
else ok "DRIFT B detected (in-marker hand-edit → --check red)"; fi

# ===========================================================================
# Build a scratch scripts dir + doc set for the checker drift cases.
SCRATCH="$WORK/scripts"
mkdir -p "$SCRATCH"
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null

echo "=== TC-SPEC-GATE-020..030: full checker PASS against the real repo ==="
if bash "$CHECK" >/dev/null 2>&1; then ok "check-spec-drift.sh PASSES against the committed repo (all 3 checks)"; else bad "check-spec-drift.sh FAILS against the committed repo"; fi

echo "=== TC-SPEC-GATE-031: DRIFT — undeclared label write → red naming it ==="
# Append a literal label_swap line to the scratch script; $issue_num is meant to
# stay literal (it's bash source text we inject, not a value to expand here).
# shellcheck disable=SC2016
printf '\nlabel_swap "$issue_num" "" "frobnicate"\n' >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "frobnicate" <<<"$out"; then ok "undeclared label write → red naming 'frobnicate'"; else bad "undeclared label write not caught (rc=$rc)"; fi
# restore
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"

echo "=== TC-SPEC-GATE-023: DRIFT — remove a guard from the map → red naming the token ==="
jq 'del(.guards["deps-resolved"])' "$DOCS/spec-guard-map.json" > "$WORK/gm-del.json"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$WORK/gm-del.json" \
  --doc "$DOCS/state-machine.md" --scripts-dir "$SCRIPTS" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "deps-resolved" <<<"$out"; then ok "unmapped guard → red naming 'deps-resolved'"; else bad "unmapped guard not caught (rc=$rc)"; fi

echo "=== TC-SPEC-GATE-024: DRIFT — mapped predicate no longer greps → red naming it ==="
jq '.guards["deps-resolved"] = {"kind":"predicate","file":"lib-dispatch.sh","pattern":"this_string_does_not_exist_anywhere_zzz"}' \
  "$DOCS/spec-guard-map.json" > "$WORK/gm-stale.json"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$WORK/gm-stale.json" \
  --doc "$DOCS/state-machine.md" --scripts-dir "$SCRIPTS" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "this_string_does_not_exist_anywhere_zzz" <<<"$out"; then ok "stale predicate → red naming the predicate"; else bad "stale predicate not caught (rc=$rc)"; fi

echo "=== TC-SPEC-GATE-025: DRIFT — mapped function not defined → red naming it ==="
jq '.guards["deps-resolved"] = {"kind":"function","file":"lib-dispatch.sh","name":"no_such_function_zzz"}' \
  "$DOCS/spec-guard-map.json" > "$WORK/gm-fn.json"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$WORK/gm-fn.json" \
  --doc "$DOCS/state-machine.md" --scripts-dir "$SCRIPTS" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "no_such_function_zzz" <<<"$out"; then ok "missing function → red naming the function"; else bad "missing function not caught (rc=$rc)"; fi

echo "=== TC-SPEC-GATE-035: NEW write site reusing EXISTING labels but no transition → red (write-SITE coverage, not vocabulary) ==="
# The [P1] the reviewer reproduced: a brand-new label_swap whose labels both
# already exist in transitions.json must STILL fail, because the (remove -> add)
# MOVEMENT it performs is not declared by any transition. `approved -> stalled`
# uses two declared labels but no transition declares that movement.
# shellcheck disable=SC2016
printf '\nlabel_swap "$issue_num" "approved" "stalled"\n' >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'approved.*stalled|undeclared (label )?movement' <<<"$out"; then
  ok "new write site reusing existing labels (approved→stalled) → red (movement coverage)"
else
  bad "new write site with existing labels NOT caught (rc=$rc) — Check C is still vocabulary-only [P1]"
fi
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"  # restore

echo "=== TC-SPEC-GATE-036: every code movement signature is declared by a transition (real repo) ==="
# The committed code's label movements must ALL map to a declared transition.
out="$(bash "$CHECK" 2>&1)"
if grep -q "all .* label-write movements map to declared transitions" <<<"$out"; then
  ok "every committed write-site movement maps to a declared transition"
else
  bad "movement-coverage sub-check did not confirm full coverage on the real repo"
fi

echo "=== TC-SPEC-GATE-037: DELETE a transition row whose movement is shared → red (C.3 code-site coverage) ==="
# THE reviewer-reproduced [P1]: deleting dispatch-pending-dev-pr-exists leaves its
# pending-dev→pending-review movement still declared by dispatch-review-aware-reroute-review,
# so the C.2 movement check stays green — but the row's spec-codesite-map.json
# entry is now ORPHANED, which C.3's reverse check must catch. Movement-set
# membership is NOT enough; write-SITE coverage is. Regenerate the doc so Check A
# stays green and the failure is unambiguously C.3.
jq 'del(.transitions[] | select(.id=="dispatch-pending-dev-pr-exists"))' "$DOCS/transitions.json" > "$WORK/t-del-row.json"
cp "$DOCS/state-machine.md" "$WORK/sm-del-row.md"
bash "$GEN" --transitions "$WORK/t-del-row.json" --doc "$WORK/sm-del-row.md" >/dev/null 2>&1
out="$(bash "$CHECK" --transitions "$WORK/t-del-row.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$WORK/sm-del-row.md" --scripts-dir "$SCRIPTS" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "dispatch-pending-dev-pr-exists" <<<"$out"; then
  ok "deleted transition row (shared movement) → red naming the orphaned code-site entry (C.3)"
else
  bad "deleted-row with shared movement NOT caught (rc=$rc) — Check C is still movement-set-only [P1]"
fi

echo "=== TC-SPEC-GATE-038: stale code-site anchor (write site renamed/removed) → red naming it ==="
jq '.code_sites["dispatch-pending-dev-pr-exists"].anchor = "this_code_site_was_renamed_zzz()"' \
  "$DOCS/spec-codesite-map.json" > "$WORK/cm-stale.json"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$WORK/cm-stale.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRIPTS" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "this_code_site_was_renamed_zzz" <<<"$out"; then ok "stale code-site anchor → red naming it (C.3 forward)"; else bad "stale code-site anchor not caught (rc=$rc)"; fi

echo "=== TC-SPEC-GATE-039: real repo confirms full bidirectional code-site coverage ==="
out="$(bash "$CHECK" 2>&1)"
if grep -q "all .* code-bearing transitions map to a resolvable code site" <<<"$out"; then
  ok "every code-bearing transition maps to a resolvable code site (C.3)"
else
  bad "code-site-coverage sub-check did not confirm full coverage on the real repo"
fi

echo "=== TC-SPEC-GATE-042: NEW write site with an EXISTING (shared) movement → red (C.4 discovered-site reconciliation) ==="
# THE reviewer-reproduced [P1]: appending `label_swap "$n" "pending-dev" "pending-review"`
# adds a write site whose movement is ALREADY declared (dispatch-pending-dev-pr-exists
# + dispatch-review-aware-reroute-review). C.2 passes (movement declared) and C.3
# passes (all transitions still resolve) — only C.4's per-(file,movement) count
# reconciliation catches the unaccounted site. This is the exact AC: "a PR adding a
# new label write without a transitions.json entry fails CI".
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\nlabel_swap "$issue_num" "pending-dev" "pending-review"\n' >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'C\.4:.*pending-dev\|pending-review' <<<"$out"; then
  ok "new write site with a shared/existing movement → red (C.4 discovered-site reconciliation)"
else
  bad "new shared-movement write site NOT caught (rc=$rc) — the AC is still unmet [P1]"
fi
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"  # restore

echo "=== TC-SPEC-GATE-043: extra site in an ALREADY-counted (file,movement) group → red naming the count delta ==="
# autonomous-review.sh reviewing|pending-dev declares 8; add a 9th → discovered 9 ≠ 8.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
printf '\ngh issue edit "$n" --repo "$R" --remove-label "reviewing" --add-label "pending-dev"\n' >> "$SCRATCH/autonomous-review.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'C\.4:.*reviewing\|pending-dev.*9.*8|C\.4:.*reviewing\|pending-dev.*site' <<<"$out"; then
  ok "extra site in a counted group (8→9) → red naming the count delta (C.4)"
else
  bad "extra site in a counted group NOT caught (rc=$rc)"
fi
cp "$SCRIPTS/autonomous-review.sh" "$SCRATCH/autonomous-review.sh"  # restore

echo "=== TC-SPEC-GATE-044: real repo confirms full discovered-site reconciliation ==="
out="$(bash "$CHECK" 2>&1)"
if grep -q "all discovered label-write sites reconcile with the sites\[\] manifest" <<<"$out"; then
  ok "every discovered write site reconciles with the sites[] manifest (C.4)"
else
  bad "discovered-site reconciliation did not confirm full coverage on the real repo"
fi

echo "=== TC-SPEC-GATE-045: a NON-allowlisted variable-valued label write → red (P1.1) ==="
# THE first reviewer-reproduced [P1]: a variable --add-label "$var" outside the
# allowlist must FAIL, not surface a green NOTE — it can inject an undeclared
# label the literal-site checks never see.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\ngh issue edit "$issue_num" --add-label "$new_label"\n' >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'variable label write at dispatcher-tick\.sh.*NOT allowlisted' <<<"$out"; then
  ok "non-allowlisted variable label write → red (P1.1, no longer a green NOTE)"
else
  bad "non-allowlisted variable label write NOT caught (rc=$rc) — P1.1 still unmet"
fi
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"  # restore

echo "=== TC-SPEC-GATE-046: relocate a write within the same file (same movement) → red (C.5 anchor adjacency) ==="
# THE second reviewer-reproduced [P1]: delete the label_swap "pending-dev"
# "pending-review" inside handle_pending_dev_pr_exists() and re-insert the SAME
# call elsewhere in lib-dispatch.sh. C.4's (file,movement) count stays 2 and the
# C.3 anchor still greps — only C.5's anchor-adjacency catches that the write left
# its declared site.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
python3 - "$SCRATCH/lib-dispatch.sh" <<'PY'
import sys
p=sys.argv[1]; lines=open(p).read().split('\n')
target='label_swap "$issue_num" "pending-dev" "pending-review"'
# The anchored site lives near 'transitioning to pending-review instead of'; find
# THAT call (the one whose preceding lines contain the anchor) and remove it,
# then re-insert an identical call far away (end of file, same file + movement).
anchor_idx=next((i for i,l in enumerate(lines) if 'transitioning to pending-review instead of' in l), None)
removed=False
if anchor_idx is not None:
    for j in range(anchor_idx, min(anchor_idx+6, len(lines))):
        if lines[j].strip()==target:
            del lines[j]; removed=True; break
lines.append('relocated_swap() { '+target+'; }')
open(p,'w').write('\n'.join(lines))
print("relocated:",removed)
PY
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'C\.5:.*transitioning to pending-review instead of.*NO .pending-dev\|pending-review. label write within' <<<"$out"; then
  ok "same-file/same-movement relocation → red (C.5 anchor adjacency)"
else
  bad "same-file/same-movement relocation NOT caught (rc=$rc) — C.4 count alone is insufficient [P1]"
fi
cp "$SCRIPTS/lib-dispatch.sh" "$SCRATCH/lib-dispatch.sh"  # restore

echo "=== TC-SPEC-GATE-047: real repo confirms full per-site anchor adjacency ==="
out="$(bash "$CHECK" 2>&1)"
if grep -q "manifest sites are uniquely anchored and adjacent to their write" <<<"$out"; then
  ok "every manifest site is uniquely anchored + write-adjacent (C.5)"
else
  bad "per-site anchor adjacency did not confirm full coverage on the real repo"
fi

echo "=== TC-SPEC-GATE-048: a TOP-LEVEL (no enclosing fn) variable write → red, attributed <top-level> (P1.1 glob/reset fix) ==="
# A variable write at file top level (after the last function closes) must NOT be
# allowlisted — the awk's brace-depth reset attributes it to "" and the exact-match
# (not glob) allowlist rejects empty. Guards the pr-review glob-`*`/no-reset bypass.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\ngh issue edit "$n" --add-label "$evil"\n' >> "$SCRATCH/lib-dispatch.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'variable label write at lib-dispatch\.sh.*<top-level>.*NOT allowlisted' <<<"$out"; then
  ok "top-level variable write → red, attributed <top-level> (no glob/no-reset bypass)"
else
  bad "top-level variable write NOT caught/mis-attributed (rc=$rc) — P1.1 allowlist bypass"
fi
cp "$SCRIPTS/lib-dispatch.sh" "$SCRATCH/lib-dispatch.sh"  # restore

echo "=== TC-SPEC-GATE-049: a PREFIX-named function ('label') with a variable write → red (exact-match, not glob) ==="
# `label` is a prefix of the allowlist anchor `label_swap() {`; the OLD glob
# `case "$a" in "$fn"*` wrongly allowlisted it. Exact-match must reject.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\nlabel() {\n  gh issue edit "$n" --add-label "$evil"\n}\n' >> "$SCRATCH/lib-dispatch.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'variable label write at lib-dispatch\.sh.*fn label\).*NOT allowlisted' <<<"$out"; then
  ok "prefix-named function (label vs label_swap) → red (exact-match allowlist, not glob)"
else
  bad "prefix-named function variable write NOT caught (rc=$rc) — glob over-match bypass"
fi
cp "$SCRIPTS/lib-dispatch.sh" "$SCRATCH/lib-dispatch.sh"  # restore

echo "=== TC-SPEC-GATE-050: an EQUALS-form variable write (--add-label=\$x) → red (P1.1 hardening) ==="
# The whitespace-only regex missed `--add-label="$x"` (and bare `--add-label=$x`):
# neither the variable detector nor the literal scanner saw it, so an undeclared
# label could be injected invisibly. The widened `[[:space:]=]+` regex must catch
# the equals form too. Outside any allowlisted function → FAIL.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\nequals_form_write() {\n  gh issue edit "$n" --add-label="$evil"\n}\n' >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'variable label write at dispatcher-tick\.sh.*fn equals_form_write\).*NOT allowlisted' <<<"$out"; then
  ok "equals-form variable write (--add-label=\$x) → red (P1.1 regex hardening)"
else
  bad "equals-form variable write NOT caught (rc=$rc) — regex still whitespace-only"
fi
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"  # restore

echo "=== TC-SPEC-GATE-052: a LITERAL equals-form write (--add-label=\"frobnicate\") → red (C.1/C.2 literal scanner) ==="
# TC-050 hardened the VARIABLE-write detector for the `=` form, but the LITERAL
# scanners (C.1 vocabulary / C.2 movement / C.5) still matched only the whitespace
# form, so a literal `--add-label="frobnicate"` with an undeclared label bypassed
# the gate entirely (it is not a $-write, so the variable ban never fires; and the
# whitespace-only literal regex never saw it). Reviewer's exact reproduction. The
# widened `[ \t=]+` separator in all three literal scanners must now catch it →
# C.1 names the undeclared label.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
printf '\nliteral_equals_write() {\n  gh issue edit "$n" --add-label="frobnicate"\n}\n' >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq "label 'frobnicate' is WRITTEN at dispatcher-tick\.sh.*NOT declared" <<<"$out"; then
  ok "literal equals-form write (--add-label=\"frobnicate\") → red naming 'frobnicate' (C.1 literal scanner)"
else
  bad "literal equals-form write NOT caught (rc=$rc) — literal scanners still whitespace-only [P1]"
fi
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"  # restore

echo "=== TC-SPEC-GATE-053: a CONTINUATION-SPLIT variable write → red (P1.1 logical-line join) ==="
# The variable-write ban scanned PHYSICAL lines only, so a write split across
# backslash continuations — `gh issue edit "$n" \` ⏎ `--add-label \` ⏎ `"$evil"` —
# matched no single line and bypassed the ban (reviewer [P1]). The detector now
# joins continuations into a logical line before the regex. Outside any allowlisted
# function → FAIL, attributed to the START line's function.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\ncontinuation_var_write() {\n  gh issue edit "$n" \\\n    --add-label \\\n    "$evil"\n}\n' >> "$SCRATCH/lib-dispatch.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'variable label write at lib-dispatch\.sh.*fn continuation_var_write\).*NOT allowlisted' <<<"$out"; then
  ok "continuation-split variable write → red (P1.1 logical-line join)"
else
  bad "continuation-split variable write NOT caught (rc=$rc) — detector still physical-line-only [P1]"
fi
cp "$SCRIPTS/lib-dispatch.sh" "$SCRATCH/lib-dispatch.sh"  # restore

echo "=== TC-SPEC-GATE-055: a comment ending in '\\' must NOT swallow a following var write → red ==="
# Closing-the-loop on TC-053: a comment line ending in a backslash does NOT continue
# in real bash (the '\' is comment text), but a naive logical-line join would let
# `# ...\` ⏎ <real var write> merge into a buffer that fails the leading-'#' test and
# silently swallow the genuine write (a bypass the join itself could introduce). A
# comment physical line must neither start nor extend the write buffer → the real
# write on the next line is still detected and FAILs.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\ncomment_cont_bypass() {\n  # comment ending in backslash \\\n  gh issue edit "$n" --add-label "$evil"\n}\n' >> "$SCRATCH/lib-dispatch.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'variable label write at lib-dispatch\.sh.*fn comment_cont_bypass\).*NOT allowlisted' <<<"$out"; then
  ok "comment ending in backslash does not swallow the following var write → red"
else
  bad "comment-continuation swallowed the following var write (rc=$rc) — join bypass"
fi
cp "$SCRIPTS/lib-dispatch.sh" "$SCRATCH/lib-dispatch.sh"  # restore

echo "=== TC-SPEC-GATE-054: a SINGLE-QUOTED literal write (--add-label 'frobnicate') → red (C.1/C.2 literal scanner) ==="
# The literal scanners (collect_writes / collect_movements / write_lines_for_file)
# matched only DOUBLE-quoted label args, so `--add-label 'frobnicate'` bypassed
# C.1/C.2/C.5 entirely (reviewer [P1]). The `["'\'']` quote class must now scan the
# single-quoted form too → C.1 names the undeclared label.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf "\nsinglequote_write() {\n  gh issue edit \"\$n\" --add-label 'frobnicate'\n}\n" >> "$SCRATCH/lib-dispatch.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq "label 'frobnicate' is WRITTEN at lib-dispatch\.sh.*NOT declared" <<<"$out"; then
  ok "single-quoted literal write (--add-label 'frobnicate') → red naming 'frobnicate' (C.1 literal scanner)"
else
  bad "single-quoted literal write NOT caught (rc=$rc) — literal scanners still double-quote-only [P1]"
fi
cp "$SCRIPTS/lib-dispatch.sh" "$SCRATCH/lib-dispatch.sh"  # restore

echo "=== TC-SPEC-GATE-056: a DIGIT-bearing literal label write (--add-label \"v2-blocked\") → red (C.1 literal scanner, char class includes 0-9) ==="
# The label char class was [a-z][a-z-]* (lowercase + hyphen only), so a literal
# label containing a DIGIT (e.g. "v2-blocked") was silently skipped by ALL literal
# scanners and is not a $-write (variable ban never fires) → it bypassed spec-drift
# entirely (review Low note). The class is now [a-z][a-z0-9-]*, matching
# transitions.schema.json's add-label/remove-label pattern → C.1 names it.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
printf '\ndigitlabel_write() {\n  gh issue edit "$n" --add-label "v2-blocked"\n}\n' >> "$SCRATCH/lib-dispatch.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq "label 'v2-blocked' is WRITTEN at lib-dispatch\.sh.*NOT declared" <<<"$out"; then
  ok "digit-bearing literal write (--add-label \"v2-blocked\") → red naming 'v2-blocked' (C.1 char class includes 0-9)"
else
  bad "digit-bearing literal write NOT caught (rc=$rc) — label char class still excludes digits"
fi
cp "$SCRIPTS/lib-dispatch.sh" "$SCRATCH/lib-dispatch.sh"  # restore

echo "=== TC-SPEC-GATE-057: an UNQUOTED literal label write (--add-label frobnicate) → red (C.1 literal scanner, bare-word form) ==="
# The literal scanners (collect_writes / collect_movements / write_lines_for_file)
# required a QUOTE around the label arg, so a BARE shell word `--add-label
# frobnicate` bypassed C.1/C.2/C.5 entirely and is not a $-write (variable ban
# never fires) → it kept CI green for a new undeclared label (reviewer [BLOCKING]).
# The form-2 regex now accepts a quoted-OR-bare alternative; a bare label is
# stripped of no quotes and named by C.1. (A variable write `--add-label $x` still
# can NOT match this bare class — it starts with `$` — so it remains the P1.1 ban's
# job, NOT a literal, verified by TC-SPEC-GATE-045.)
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
printf '\nunquoted_write() {\n  gh issue edit "$n" --add-label frobnicate\n}\n' >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq "label 'frobnicate' is WRITTEN at dispatcher-tick\.sh.*NOT declared" <<<"$out"; then
  ok "unquoted literal write (--add-label frobnicate) → red naming 'frobnicate' (C.1 bare-word scanner)"
else
  bad "unquoted literal write NOT caught (rc=$rc) — literal scanners still quote-only [BLOCKING]"
fi
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"  # restore

echo "=== TC-SPEC-GATE-033: continuation-line label write is scanned (M2) ==="
# A gh issue edit whose --add-label literal is on the NEXT physical line must
# still be seen by the scanner (logical-line join). Use an undeclared label so a
# miss would PASS (false negative) and a correct scan FAILs naming it.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
{
  printf '\ngh issue edit "$n" --repo "$REPO" \\\n'
  printf '  --add-label \\\n'
  printf '  "splitlabel"\n'
} >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "splitlabel" <<<"$out"; then ok "continuation-line write scanned → red naming 'splitlabel'"; else bad "continuation-line write NOT scanned (rc=$rc) — M2 regression"; fi
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"  # restore

echo "=== TC-SPEC-GATE-034: NO variable label write survives in the pipeline files (real repo passes P1.1) ==="
# #283: label_swap() delegated its variable label write to itp_transition_state
# (the [INV-87] ITP verb), whose leaf lives in providers/itp-github.sh, OUTSIDE the
# four scanned PIPELINE_FILES. #331 ([INV-97]): hygiene_strip_residual_labels() did
# the SAME — its `--remove-label "$t"` loop is gone; it now builds a CSV ($remove_csv)
# from its hard-coded transitional-label set and delegates to
# `itp_transition_state "$issue_num" "$remove_csv" ""` (the CSV-extended leaf). So
# NO `--add/--remove-label "$var"` write remains in any PIPELINE_FILE: check_variable_writes
# emits NEITHER an allowlist INFO nor a P1.1 FAIL, and the real repo PASSES C-overall.
# (variable_write_allowlist.sites is now empty — the orphaned entry was dropped.)
out="$(bash "$CHECK" 2>&1)"
if grep -qE "::error::.*variable label write" <<<"$out"; then
  bad "a variable label write FAILed P1.1 on the real repo (post-#331 there should be NONE): $(grep -E '::error::.*variable label write' <<<"$out" | head -1)"
elif grep -q "allowlisted variable label write" <<<"$out"; then
  bad "the real repo still reports a variable label write (post-#331 the hygiene loop should delegate to itp_transition_state → none remain): $(grep 'allowlisted variable label write' <<<"$out" | head -1)"
else
  ok "no variable label write remains in the pipeline files; label_swap (#283) + hygiene_strip (#331) both delegate to itp_transition_state — P1.1 silent, C-overall passes"
fi

echo "=== TC-SPEC-GATE-016: reversed markers fail the generator loud (L1) ==="
# A doc whose END marker precedes BEGIN must be rejected, not silently mis-spliced.
cp "$DOCS/state-machine.md" "$WORK/sm-rev.md"
python3 - "$WORK/sm-rev.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read().split("\n")
b=[i for i,l in enumerate(t) if "BEGIN GENERATED: state-machine" in l][0]
e=[i for i,l in enumerate(t) if "END GENERATED: state-machine" in l][0]
t[b],t[e]=t[e],t[b]  # swap the two marker lines → END now precedes BEGIN
open(p,"w").write("\n".join(t))
PY
if bash "$GEN" --transitions "$DOCS/transitions.json" --doc "$WORK/sm-rev.md" >/dev/null 2>&1; then
  bad "reversed markers NOT rejected by the generator (L1 regression)"
else ok "reversed markers rejected loud (generator exit non-zero)"; fi

echo "=== TC-SPEC-GATE-032: all 8 pipeline labels declared in transitions.json ==="
declared="$(jq -r '
  (.label_vocabulary // []) + ([.states[].label]) +
  ([.transitions[].actions[] | select(startswith("add-label:") or startswith("remove-label:")) | sub("^(add|remove)-label:";"")])
  | unique | .[]' "$DOCS/transitions.json")"
missing=""
for lbl in autonomous in-progress pending-review reviewing pending-dev approved no-auto-close stalled; do
  grep -Fxq "$lbl" <<<"$declared" || missing="$missing $lbl"
done
if [[ -z "$missing" ]]; then ok "all 8 pipeline labels declared"; else bad "labels NOT declared:$missing"; fi

# ===========================================================================
echo "=== TC-SPEC-GATE-040/041: every INV heading carries exactly one valid triage tag ==="
INV="$DOCS/invariants.md"
n_head=$(grep -cE '^## INV-[0-9]+:' "$INV")
n_tag=$(grep -cE '^_Triage \(issue #236\): \[' "$INV")
if [[ "$n_head" -eq "$n_tag" && "$n_head" -gt 0 ]]; then ok "every INV heading tagged ($n_head headings = $n_tag tags)"; else bad "tag/heading mismatch: $n_head headings vs $n_tag tags"; fi
# Each tag is one of the three allowed forms.
bad_tags=$(grep -E '^_Triage \(issue #236\):' "$INV" \
  | grep -vcE '\[(machine-checked: [^]]+|design-rationale|superseded)\]_' || true)
if [[ "$bad_tags" -eq 0 ]]; then ok "all triage tags are one of {machine-checked,design-rationale,superseded}"; else bad "$bad_tags triage tag(s) have an unrecognized form"; fi
# Adjacency: each tag sits within 2 lines of an INV heading.
adj=$(awk '/^## INV-[0-9]+:/{h=NR} /^_Triage \(issue #236\):/{if(h && NR-h<=2) c++; h=0} END{print c+0}' "$INV")
if [[ "$adj" -eq "$n_head" ]]; then ok "every tag is adjacent to its heading"; else bad "only $adj/$n_head tags are heading-adjacent"; fi

# ===========================================================================
echo "=== TC-SPEC-GATE-058: #296 B2 doc-retraction is enforced by check-spec-drift.sh Check D (runs in the spec-drift CI job) ==="
# After #296 B2 (#306) migrated check_deps_resolved's issue-BODY read behind
# itp_read_task, the normative claim that this read "remains a raw caller-side `gh`
# call; itp_read_task is its eventual home" became FALSE. The pipeline-docs-gate
# only checks that SOME docs/pipeline/*.md changed — it cannot catch stale content
# — so per CLAUDE.md "docs are authoritative" the retraction is enforced by
# check-spec-drift.sh's Check D, which runs in the SAME `spec-drift` CI job named in
# the #306 owner comment (NOT only the hermetic-unit test glob — the #306 review
# [BLOCKING] finding). This case drives that checker the same way the other
# TC-SPEC-GATE cases do: clean tree → green; injected stale phrase → red naming the
# file:line.
SPEC="$DOCS/provider-spec.md"

# (a) the committed provider-spec.md is already retracted → the phrase is ABSENT.
if [[ -z "$(grep -nF 'remains a raw caller-side' "$SPEC" || true)" ]]; then
  ok "committed provider-spec.md no longer asserts the body read 'remains a raw caller-side' gh call (#306/B2 migrated)"
else
  bad "stale 'remains a raw caller-side' assertion survives in committed provider-spec.md (#306/B2 retraction missing)"
fi

# (b) check-spec-drift.sh PASSES against the clean committed provider-spec.md (Check D green).
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" \
  --provider-spec "$SPEC" --scripts-dir "$SCRIPTS" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'retraction holds' <<<"$out"; then
  ok "check-spec-drift.sh Check D is GREEN on the retracted provider-spec.md (spec-drift CI job passes)"
else
  bad "check-spec-drift.sh did not pass Check D on the clean provider-spec.md (rc=$rc)"
fi

# (c) re-inject the stale phrase into a SCRATCH provider-spec → Check D must go RED
#     naming the file:line (this is the deterministic gate; a reviewer call is NOT
#     relied upon). Driving $CHECK proves the spec-drift JOB catches it, not just a
#     local grep in the hermetic-unit job.
spec_scratch="$WORK/provider-spec-stale.md"
cp "$SPEC" "$spec_scratch"
printf '\n| x | y | z | the body read remains a raw caller-side `gh` call |\n' >> "$spec_scratch"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" \
  --provider-spec "$spec_scratch" --scripts-dir "$SCRIPTS" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq "Check D: stale 'remains a raw caller-side' assertion survives in provider-spec\.md:[0-9]+" <<<"$out"; then
  ok "injected stale assertion → check-spec-drift.sh Check D RED naming provider-spec.md:LINE (spec-drift CI job enforces the retraction)"
else
  bad "injected stale assertion NOT caught by check-spec-drift.sh Check D (rc=$rc) — the spec-drift job would not enforce the retraction [BLOCKING]"
fi

# ===========================================================================
echo "=== TC-SPEC-GATE-308: INV-91 Migration-log carries the exact #296 B3+B4 (#308) bullet ==="
# [#296 B3+B4, #308] AC6 — the migration that pulled the lib-auth PR-existence
# reads + lib-review-e2e SHA-evidence read behind chp_pr_list/chp_pr_view records
# its byte-identical, baseline-shrink-by-3 entry in INV-91's Migration log. Pinned
# here (Spec Drift surface) so doc-and-code stay coupled per CONTRIBUTING Rule 1.
AC6_308='- #296 B3+B4 (#308): lib-auth PR-existence reads (2× chp_pr_list, lib-auth.sh), lib-review-e2e SHA-evidence read (1× chp_pr_view, lib-review-e2e.sh) — byte-identical; baseline shrank by 3 sigs.'
if grep -qF -- "$AC6_308" "$INV"; then ok "INV-91 Migration-log has the exact #296 B3+B4 (#308) bullet"; else bad "INV-91 Migration-log missing/changed the #296 B3+B4 (#308) bullet"; fi

# ===========================================================================
echo "=== TC-SPEC-GATE-311: INV-91 Migration-log carries the exact #296 B8 (#311) bullet ==="
# [#296 B8, #311] AC9 — the migration that collapsed the 16 clean live-wrapper
# label flips (13 autonomous-review.sh + 3 autonomous-dev.sh) behind
# itp_transition_state records its byte-identical, baseline-count-shrink entry in
# INV-91's Migration log. Unlike B1/B5+B7 (whole signatures vanished) this batch
# only drops occurrence COUNTS — the multi-remove survivors keep the bare-edit
# content key at count 1 (signatures stay 73→73), so the wording is "occurrences".
# Pinned here (Spec Drift surface) so doc-and-code stay coupled per CONTRIBUTING Rule 1.
AC9_311='- #296 B8 (#311): live-wrapper label flips (16 sites: 13 autonomous-review.sh, 3 autonomous-dev.sh) → itp_transition_state — byte-identical; baseline counts shrank by 16 occurrences (review-bare 14→1, dev-bare 4→1), no signature removed; ZERO manifest edit (Form-3 coverage-neutral, #313).'
if grep -qF -- "$AC9_311" "$INV"; then ok "INV-91 Migration-log has the exact #296 B8 (#311) bullet"; else bad "INV-91 Migration-log missing/changed the #296 B8 (#311) bullet"; fi

# ===========================================================================
echo "=== TC-SPEC-GATE-328: INV-91 Migration-log carries the exact #296 second-tier (#328) bullet ==="
# [#296 second-tier, #328] AC4 — the migration that pulled the dev-resume PR
# inline-review-comment read behind the NEW verb chp_list_inline_comments records
# its byte-identical, baseline-shrink-by-1 entry in INV-91's Migration log. Pinned
# here (Spec Drift surface) so doc-and-code stay coupled per CONTRIBUTING Rule 1.
# Match the bullet's stable leading clause (the full bullet is long; the leading
# clause uniquely identifies it without pinning every prose word).
AC4_328='- #296 second-tier (#328): the dev-resume PR inline-review-comment read (`PR_REVIEW_COMMENTS`, autonomous-dev.sh) migrated from raw `gh api repos/$REPO/pulls/$PR_NUM/comments --jq` to the NEW verb `chp_list_inline_comments` — byte-identical (the `--jq` formatter stays caller-side, #281); baseline shrank by 1 sig.'
if grep -qF -- "$AC4_328" "$INV"; then ok "INV-91 Migration-log has the exact #296 second-tier (#328) bullet"; else bad "INV-91 Migration-log missing/changed the #296 second-tier (#328) bullet"; fi

# ===========================================================================
echo "=== TC-SPEC-GATE-329: INV-91 Migration-log carries the #296 second-tier (#329) chp_pr_comment bullet ==="
# [#329, AC5] the migration that pulled the 7 PR-comment writes behind the new
# general write primitive chp_pr_comment ([INV-102], renumbered from INV-95, then
# INV-101, on successive rebases) records its baseline-shrink entry (5 sigs / 7
# occurrences, relative to
# whatever main's baseline is at rebase time — no absolute before/after pin, since
# sibling #296 migrations independently shrink the same shared manifest) in
# INV-91's Migration log. Pinned here (Spec Drift surface) so doc-and-code stay
# coupled per CONTRIBUTING Rule 1. Keyed on stable substrings (not the full prose
# paragraph) so a later wording tweak does not falsely red — but it MUST name
# #329, chp_pr_comment, and the 5-sig/7-occurrence shrink.
if grep -qE '^- #296 second-tier \(#329\):' "$INV" \
   && grep -q 'chp_pr_comment' "$INV" \
   && grep -qF 'shrinks by 5 sigs / 7 occurrences' "$INV"; then
  ok "INV-91 Migration-log has the #296 second-tier (#329) chp_pr_comment bullet (named verb + 5-sig/7-occ shrink)"
else
  bad "INV-91 Migration-log missing/changed the #296 second-tier (#329) chp_pr_comment bullet"
fi

# ===========================================================================
# Form 3 — the scanner recognizes a DIRECT itp_transition_state call as a
# positional label-write site (spec-gate-itp prerequisite for #296/B8 / #311).
# Keeps spec-gate coverage as gh issue edit → itp_transition_state migrates.
# ===========================================================================

echo "=== TC-SPEC-GATE-059: a NEW itp_transition_state literal call with a shared movement → red (C.4 Form-3 discovery) ==="
# Appending `itp_transition_state "$n" "reviewing" "pending-dev"` adds a write site
# whose movement is ALREADY declared. Before Form 3 the scanner was BLIND to it and
# CI stayed green (silent coverage loss). With Form 3, C.4 discovers it (count up by
# one for that (file,movement)) → unaccounted site fails. This is the core proof
# that itp_transition_state is now a first-class scanned label-write site.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\nitp_transition_state "$n" "reviewing" "pending-dev"\n' >> "$SCRATCH/autonomous-review.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'C\.4:.*reviewing\|pending-dev' <<<"$out"; then
  ok "new itp_transition_state literal call → red (C.4 Form-3 discovery)"
else
  bad "Form-3 itp_transition_state call NOT discovered (rc=$rc) — scanner still blind to the verb"
fi
cp "$SCRIPTS/autonomous-review.sh" "$SCRATCH/autonomous-review.sh"  # restore

echo "=== TC-SPEC-GATE-060: a VARIABLE-arg itp_transition_state call emits NO movement and trips NO P1.1 ==="
# `itp_transition_state "$n" "$rm" "$add"` (the label_swap delegation form) carries
# no static labels and no --add/--remove-label flag. Form 3 must SKIP its variable
# operands (no movement → no C.4 count change) AND it must NOT trip the P1.1
# variable-write ban (no flag). A miss either way would FAIL the otherwise-green
# real repo, so a green run with this line appended proves both guards hold.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\nvariable_itp_call() {\n  itp_transition_state "$n" "$rm" "$add"\n}\n' >> "$SCRATCH/dispatcher-tick.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "variable-arg itp_transition_state → no movement, no P1.1 trip (skip-variable guard holds)"
else
  bad "variable-arg itp_transition_state wrongly flagged (rc=$rc) — skip-variable guard or P1.1 over-fired: $(grep -E 'C\.4|P1.1|variable' <<<"$out" | head -2)"
fi
cp "$SCRIPTS/dispatcher-tick.sh" "$SCRATCH/dispatcher-tick.sh"  # restore

echo "=== TC-SPEC-GATE-061: itp_transition_state token #1 (issue) ignored, #2/#3 literals read ==="
# `itp_transition_state "$ISSUE_NUMBER" "reviewing" "pending-review"`: token #1 is a
# $-var (skipped), #2=reviewing #3=pending-review. The discovered movement must be
# reviewing|pending-review (NOT mis-reading the issue arg as a label). Use the
# already-declared reviewing|pending-review movement; the extra site makes its
# count exceed the manifest → C.4 names exactly reviewing|pending-review.
cp "$SCRIPTS"/*.sh "$SCRATCH/" 2>/dev/null
# shellcheck disable=SC2016
printf '\nitp_transition_state "$ISSUE_NUMBER" "reviewing" "pending-review"\n' >> "$SCRATCH/autonomous-review.sh"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$DOCS/spec-codesite-map.json" --doc "$DOCS/state-machine.md" --scripts-dir "$SCRATCH" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'C\.4:.*reviewing\|pending-review' <<<"$out"; then
  ok "token #1 issue-arg ignored; #2/#3 read as reviewing|pending-review (C.4)"
else
  bad "Form-3 positional parse wrong (rc=$rc) — issue arg mis-read or movement wrong"
fi
cp "$SCRIPTS/autonomous-review.sh" "$SCRATCH/autonomous-review.sh"  # restore

echo "=== TC-SPEC-GATE-062: real repo reconciles WITH the existing itp_transition_state site (review.sh:3518) ==="
# The merge_closes_issue=0 fallback at autonomous-review.sh:3518 is a real, shipped
# itp_transition_state "$ISSUE_NUMBER" "reviewing" "approved" call. Form 3 now sees
# it, and the sites[] manifest declares it (anchor 'merge_closes_issue=0 —
# transitioning issue'). The real repo must reconcile (C.4 reviewing|approved
# discovers 3 == declares 3) and PASS — the load-bearing coverage proof.
out="$(bash "$CHECK" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "all discovered label-write sites reconcile with the sites\[\] manifest" <<<"$out"; then
  ok "real repo reconciles with the itp_transition_state site (review.sh:3518) declared (C.4)"
else
  bad "real repo did NOT reconcile with the itp_transition_state site (rc=$rc) — manifest entry for 3518 missing/wrong"
fi

echo "=== TC-SPEC-GATE-063: removing the review.sh:3518 manifest entry → red (the entry is load-bearing) ==="
# Negative proof: strip the new sites[] entry for the 3518 itp_transition_state call
# from a scratch manifest → Form 3 still discovers 3 reviewing|approved sites but the
# manifest now declares 2 → C.4 FAILs. Confirms Form 3 genuinely sees 3518 (not a
# no-op) and the manifest entry is required, not decorative.
SCRATCH_MAP="$WORK/codesite-map-no3518.json"
jq 'del(.sites[] | select(.file=="autonomous-review.sh" and .movement=="reviewing|approved" and .anchor=="merge_closes_issue=0 — transitioning issue"))' \
  "$DOCS/spec-codesite-map.json" > "$SCRATCH_MAP"
out="$(bash "$CHECK" --transitions "$DOCS/transitions.json" --guard-map "$DOCS/spec-guard-map.json" \
  --codesite-map "$SCRATCH_MAP" --doc "$DOCS/state-machine.md" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -Eq 'C\.4:.*reviewing\|approved' <<<"$out"; then
  ok "removing the 3518 manifest entry → red (Form 3 sees 3518; entry is load-bearing)"
else
  bad "removing the 3518 entry did NOT fail (rc=$rc) — Form 3 may not actually discover 3518"
fi

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
