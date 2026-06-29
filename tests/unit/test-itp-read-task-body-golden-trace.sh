#!/bin/bash
# test-itp-read-task-body-golden-trace.sh — GOLDEN-TRACE for the #296 B2 migration
# (#306): the `check_deps_resolved` issue-BODY read moves behind the already-shipped
# `itp_read_task` verb ([INV-87], provider-spec.md §3.1). Zero behavior change — the
# verb shim chain forwards to the EXACT same `gh` argv.
#
# This pins the BYTE-IDENTICAL `gh issue view … --json body` argv (and `-q '.body'`
# projection) the dependency-resolution path emits AFTER the leaf moved behind
# itp_read_task / itp_github_read_task — the no-behavior-change proof for B2.
#
# DISTINCT from test-itp-resolve-dep-golden-trace.sh, which pins the `--json state`
# dep-LOOKUP argv. This file pins the `--json body` task-READ argv specifically
# (#306 testing requirement: "Assert the body read specifically").
#
# IDs: TC-B2-GT-NNN.
#
# Run: bash tests/unit/test-itp-read-task-body-golden-trace.sh

set -uo pipefail

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$SCRIPTS/lib-dispatch.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq()       { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected='$e'"; echo "      actual=  '$a'"; fi; }
assert_contains()     { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      needle='$n'"; echo "      haystack='${h:0:400}'"; fi; }
assert_not_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      should NOT contain: '$n'"; fi; }

export REPO=example-org/repo-A
export REPO_OWNER=example-org
export PROJECT_ID=b2-golden-trace
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ---------------------------------------------------------------------------
# A gh BINARY mock on PATH that RECORDS the exact argv (one line per call) to
# $_ARGV_LOG. For `--json body` it returns a `## Dependencies` body whose ONLY dep
# is a same-repo `#N` ref; for `--json state` it returns CLOSED so the dep resolves
# (the body read fires regardless). Recording the argv from a standalone PATH stub
# (not a shell function) means the recorded line is EXACTLY the argv
# itp_github_read_task emits — no shell-function arg munging.
# ---------------------------------------------------------------------------
_ARGV_LOG=$(mktemp)
GH_DIR=$(mktemp -d)
trap 'rm -f "$_ARGV_LOG"; rm -rf "$GH_DIR"' EXIT
cat > "$GH_DIR/gh" <<EOF
#!/bin/bash
ARGV_LOG='$_ARGV_LOG'
EOF
cat >> "$GH_DIR/gh" <<'EOF'
printf '%s\n' "$*" >> "$ARGV_LOG"
mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) mode="$2"; shift 2 ;;
    -q|--jq) shift 2 ;;
    *) shift ;;
  esac
done
case "$mode" in
  body)  printf '## Dependencies\n- #42\n' ;;
  state) printf 'CLOSED' ;;
esac
EOF
chmod +x "$GH_DIR/gh"

_run() {
  local snippet="$1"; shift
  env PATH="$GH_DIR:$PATH" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" \
      MAX_RETRIES=3 MAX_CONCURRENT=5 \
      "$@" \
  bash -c "
    set -uo pipefail
    source '$LIB' 2>/dev/null
    set +e
    $snippet
  "
}

# ---------------------------------------------------------------------------
echo "=== TC-B2-GT-001: GOLDEN-TRACE — the dep-resolution BODY read argv is byte-identical ==="
# ---------------------------------------------------------------------------
# check_deps_resolved 7 reads the issue body via itp_read_task; the FIRST recorded
# gh argv MUST be EXACTLY the pre-#306 raw literal:
#   issue view 7 --repo example-org/repo-A --json body -q .body
: > "$_ARGV_LOG"
_run 'check_deps_resolved 7 >/dev/null 2>&1' >/dev/null 2>&1
body_argv=$(head -n1 "$_ARGV_LOG")
assert_eq "body read argv is byte-identical to the pre-#306 raw \`gh issue view … --json body\` leaf" \
  "issue view 7 --repo example-org/repo-A --json body -q .body" "$body_argv"
assert_contains "the emitted body read names --json body (not state)" "--json body" "$body_argv"
assert_contains "the emitted body read carries -q .body projection" "-q .body" "$body_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-B2-GT-002: ROUTING — itp_read_task → itp_github_read_task → gh issue view --json body ==="
# ---------------------------------------------------------------------------
# Under ISSUE_PROVIDER=github (default) the verb shim forwards "$@" to the github
# leaf. Stub the leaf AFTER sourcing (the shim forwards at call time) and assert the
# sentinel routing carries the issue + field + trailing -q args verbatim.
routed=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    source "'"$LIB"'" 2>/dev/null
    itp_github_read_task() { echo "RT-ROUTED:[$1][$2][$3][$4]"; }
    itp_read_task 7 body -q .body
  '
)
assert_contains "itp_read_task routes to itp_github_read_task (issue+field+\`-q .body\` forwarded)" \
  "RT-ROUTED:[7][body][-q][.body]" "$routed"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-B2-GT-003: SOURCE-PIN — check_deps_resolved uses itp_read_task, no raw gh body read ==="
# ---------------------------------------------------------------------------
# The migrated call is present and the raw `gh issue view … --json body -q '.body'`
# is gone from lib-dispatch.sh's dependency-resolution path.
lib_src=$(cat "$LIB")
assert_contains "lib-dispatch.sh check_deps_resolved reads the body via itp_read_task" \
  'itp_read_task "$issue_num" body -q '"'"'.body'"'"'' "$lib_src"
assert_not_contains "no raw \`gh issue view … --json body -q '.body'\` survives in lib-dispatch.sh" \
  'gh issue view "$issue_num" --repo "$REPO" --json body -q '"'"'.body'"'"'' "$lib_src"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
