#!/bin/bash
# run-pr-linkage-e2e.sh — E2E for authoritative PR↔issue linkage (issue #277,
# INV-86). TC-XWIRE-E2E-001.
#
# WHAT IT DOES
# ------------
# Simulates the real cross-wiring scenario that drove #277: two autonomous
# issues in flight concurrently, each with its own open PR, where PR-B's body
# cross-references issue A (a good-practice "related to #A" line). It drives the
# REAL resolution + linkage-guard libs against a stub `gh` (no network, no
# credentials — runs on bare ubuntu like the other hermetic E2Es):
#
#   skills/autonomous-dispatcher/scripts/lib-pr-linkage.sh
#     ::resolve_pr_for_issue   (the discovery the review wrapper + dispatcher use)
#     ::verify_pr_closes_issue (the hard linkage guard before any PR mutation)
#
# Asserts:
#   1. Issue A binds to PR-A (closes A), NOT PR-B (mentions #A) — even though
#      PR-B is FIRST in the `gh pr list` order so a buggy `.[0]` body match
#      would pick it.
#   2. Issue B binds to PR-B (closes B) — symmetric.
#   3. The linkage guard ACCEPTS each issue's own PR and REJECTS the foreign PR
#      (so the wrapper would refuse to submit REQUEST_CHANGES / approve / merge /
#      flip a label against a PR not linked to the issue under review).
#   4. Close-keyword-less partial-fix PRs resolve by `issue-<N>` branch name, not
#      by a bare `.[0]` body mention.
#
# Run: bash tests/e2e/run-pr-linkage-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-pr-linkage.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$LIB" ]] || { echo -e "${RED}FATAL${NC}: lib-pr-linkage.sh missing"; exit 1; }

export REPO="zxkane/autonomous-dev-team"

# ---- stub gh -------------------------------------------------------------
# Replays the fixture PR array through the captured `-q` jq expression and
# records every invocation to $GH_CALLS so we can assert NO mutation verb is
# ever issued against a PR during discovery / guarding.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
export GH_CALLS="$TMP/gh-calls.log"; : > "$GH_CALLS"
export PR_FIXTURE="$TMP/prs.json"

cat > "$BIN/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
q=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -q) q="${args[$((i+1))]:-}" ;;
  esac
done
[[ -f "$PR_FIXTURE" ]] || { echo ""; exit 0; }
if [[ -n "$q" ]]; then jq -c "$q" "$PR_FIXTURE" 2>/dev/null || echo ""; else cat "$PR_FIXTURE"; fi
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-pr-linkage.sh
source "$LIB"

num() { local out="$1"; [[ -z "$out" ]] && { echo ""; return; }; jq -r '.number // empty' <<<"$out" 2>/dev/null; }

# ===========================================================================
echo "== TC-XWIRE-E2E-001: two concurrent PRs, PR-B cross-references issue A =="
# ===========================================================================
# issue A = 273 → PR-A = 510 (closes 273); issue B = 274 → PR-B = 511 (closes
# 274) AND PR-B's body mentions #273. PR-B is FIRST in the list so a `.[0]` body
# match would mis-select it for issue 273.
cat > "$PR_FIXTURE" <<'JSON'
[
  {"number":511,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[{"number":274}],"body":"Fixes #274\n\nRelated context:\n- #273 — authoring-time prevention of the same class"},
  {"number":510,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[{"number":273}],"body":"Closes #273"}
]
JSON

a_pr="$(num "$(resolve_pr_for_issue 273 number 2>/dev/null)")"
b_pr="$(num "$(resolve_pr_for_issue 274 number 2>/dev/null)")"
[[ "$a_pr" == "510" ]] && ok "issue 273 binds PR-A (510, close-linked), not PR-B (511, mentions #273)" \
                       || bad "issue 273 bound '$a_pr' (expected 510)"
[[ "$b_pr" == "511" ]] && ok "issue 274 binds PR-B (511, close-linked)" \
                       || bad "issue 274 bound '$b_pr' (expected 511)"

# Linkage guard: each issue's own PR accepted, the foreign PR rejected.
verify_pr_closes_issue 510 273 2>/dev/null && ok "guard accepts PR-A for issue 273" || bad "guard rejected PR-A for issue 273"
verify_pr_closes_issue 511 274 2>/dev/null && ok "guard accepts PR-B for issue 274" || bad "guard rejected PR-B for issue 274"
verify_pr_closes_issue 511 273 2>/dev/null && bad "guard WRONGLY accepted foreign PR-B for issue 273" || ok "guard rejects foreign PR-B for issue 273 (no mutation against it)"
verify_pr_closes_issue 510 274 2>/dev/null && bad "guard WRONGLY accepted foreign PR-A for issue 274" || ok "guard rejects foreign PR-A for issue 274"

# No mutation verb was ever issued during discovery / guarding — discovery is
# read-only (the wrapper only mutates AFTER the guard accepts its own PR).
calls="$(cat "$GH_CALLS")"
for verb in "pr review" "pr merge" "issue edit" "issue comment"; do
  if grep -q "$verb" <<<"$calls"; then bad "discovery/guard issued a mutation verb: $verb"; else ok "no '$verb' issued during discovery/guard"; fi
done

# ===========================================================================
echo "== TC-XWIRE-E2E-002: close-keyword-less partial-fix PRs → branch-name bind =="
# ===========================================================================
# Neither PR carries close linkage (partial-fix PRs omit Closes #N). PR-B's body
# mentions #273; only PR-A's `issue-273` branch should bind issue 273.
cat > "$PR_FIXTURE" <<'JSON'
[
  {"number":611,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[],"body":"partial fix\n- #273 — related"},
  {"number":610,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[],"body":"partial fix for 273"}
]
JSON
a_pr="$(num "$(resolve_pr_for_issue 273 number 2>/dev/null)")"
[[ "$a_pr" == "610" ]] && ok "issue 273 binds PR-A (610) by issue-273 branch, never .[0] body mention" \
                       || bad "issue 273 bound '$a_pr' (expected 610)"
verify_pr_closes_issue 610 273 2>/dev/null && ok "guard accepts branch-matched PR-A for issue 273" || bad "guard rejected branch-matched PR-A"
verify_pr_closes_issue 611 273 2>/dev/null && bad "guard WRONGLY accepted PR-B (issue-274 branch) for issue 273" || ok "guard rejects PR-B (wrong branch) for issue 273"

# ---------------------------------------------------------------------------
echo ""
echo "PR-LINKAGE-E2E-SUMMARY pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
