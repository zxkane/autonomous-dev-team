#!/bin/bash
# test-lib-agent-binary-preflight.sh — issue #231 / INV-72.
#
# The "missing binary / node-resolution" config-class path: lib-agent.sh
# preflights the resolved agent CLI binary BEFORE run_agent/resume_agent launch
# it, so a missing binary surfaces an ADT_CFG_AGENT_BINARY_MISSING envelope
# (via error_surface) instead of failing through _run_with_timeout as an opaque
# rc 127 / generic session failure.
#
# Strategy: exercise the UNIT — `preflight_agent_binary` and its helper
# `_agent_launch_binary` — directly, with a stub `gh` token-refresh proxy at
# ${AUTONOMOUS_CONF_DIR}/gh that records issue-comment posts. Driving the full
# run_agent launch pipeline (setsid + timeout + background wait) is intentionally
# avoided — it would block on the stub CLI's stdin and is not what this finding
# is about. A static assertion separately pins that run_agent/resume_agent call
# the preflight and short-circuit on its non-zero return.
#
# Run: bash tests/unit/test-lib-agent-binary-preflight.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_AGENT="$SCRIPTS_DIR/lib-agent.sh"
LIB_ERROR="$SCRIPTS_DIR/lib-error.sh"
ERRORS_DOC="$PROJECT_ROOT/docs/pipeline/errors.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_rc() { local d="$1" want="$2" got="$3"; [[ "$got" -eq "$want" ]] && ok "$d (rc=$got)" || bad "$d — want rc=$want got=$got"; }

# ---------------------------------------------------------------------------
echo "=== TC-BINPF-STATIC: preflight is wired + documented ==="
# Both run_agent and resume_agent must call preflight before the case dispatch
# AND short-circuit (return) on its non-zero rc.
pf_calls=$(grep -cE '^[[:space:]]*preflight_agent_binary \|\| return' "$LIB_AGENT" || true)
[[ "$pf_calls" -eq 2 ]] && ok "preflight wired + short-circuits in run_agent AND resume_agent (2 sites)" \
  || bad "expected 2 'preflight_agent_binary || return' sites, found ${pf_calls:-0}"
grep -q 'ADT_CFG_AGENT_BINARY_MISSING' "$LIB_AGENT" && ok "lib-agent.sh emits ADT_CFG_AGENT_BINARY_MISSING" \
  || bad "lib-agent.sh does not emit ADT_CFG_AGENT_BINARY_MISSING"
grep -q 'ADT_CFG_AGENT_BINARY_MISSING' "$ERRORS_DOC" && ok "ADT_CFG_AGENT_BINARY_MISSING documented in errors.md" \
  || bad "ADT_CFG_AGENT_BINARY_MISSING missing from errors.md (drift)"

# ---------------------------------------------------------------------------
# Behavioral sandbox — exercise preflight_agent_binary / _agent_launch_binary.
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/scripts" "$TMPROOT/bin" "$TMPROOT/cu"
GH_CALLS="$TMPROOT/gh-calls.log"

# Hermetic coreutils dir ($TMPROOT/cu): the preflight subshell runs with a
# PATH of ONLY "$TMPROOT/bin:$TMPROOT/cu" so the binary-presence check is driven
# exclusively by the stub bins we install under $TMPROOT/bin — never by a real
# agent CLI that happens to live in the host's /usr/bin or /bin. (On hosts that
# ship a real `kiro-cli` / `claude` / `codex`, a PATH that included the system
# dirs would let TC-BINPF-003's "kiro-cli absent" case resolve the host binary
# and falsely pass.) We symlink in just the utilities the libs touch at
# source-time + on the preflight path.
for _u in bash sh env jq sed grep cat date dirname basename readlink \
          mkdir rm chmod ln mktemp timeout cut tr head tail wc sort uniq awk tee cp mv; do
  _p=$(command -v "$_u" 2>/dev/null) && ln -sf "$_p" "$TMPROOT/cu/$_u"
done

# Stub token-refresh `gh` proxy: record issue-comment posts.
cat > "$TMPROOT/scripts/gh" <<EOF
#!/bin/bash
{ echo "GH:"; printf '%s\n' "\$@"; echo "---"; } >> "$GH_CALLS"
echo "https://github.com/o/r/issues/231#issuecomment-1"
exit 0
EOF
chmod +x "$TMPROOT/scripts/gh"

make_stub_bin() { printf '#!/bin/bash\nexit 0\n' > "$TMPROOT/bin/$1"; chmod +x "$TMPROOT/bin/$1"; }

# preflight <agent_cmd> <issue> [launcher_argv...] — run preflight_agent_binary
# in a clean subshell with a controlled PATH (only $TMPROOT/bin + coreutils),
# the stub gh proxy, and the given AGENT_CMD / ISSUE_NUMBER / launcher. Echoes
# `RC=<n>` last; the gh-calls log is shared via $GH_CALLS.
preflight() {
  local agent_cmd="$1" issue="$2"; shift 2
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" ISSUE_NUMBER="$issue"
    export AGENT_CMD="$agent_cmd"
    export PATH="$TMPROOT/bin:$TMPROOT/cu"
    # shellcheck disable=SC1090
    source "$LIB_ERROR"
    # shellcheck disable=SC1090
    source "$LIB_AGENT"
    AGENT_CMD="$agent_cmd"
    if [[ $# -gt 0 ]]; then AGENT_LAUNCHER_ARGV=("$@"); fi
    preflight_agent_binary
    echo "RC=$?"
  )
}
rc_of() { sed -n 's/.*RC=\([0-9]*\).*/\1/p' <<<"$1"; }

# ---------------------------------------------------------------------------
echo "=== TC-BINPF-001: missing claude binary → envelope surfaced, rc 1 ==="
: > "$GH_CALLS"
out=$(preflight claude 231)            # no stub `claude` on PATH
assert_rc "001 preflight returns 1 on missing binary" 1 "$(rc_of "$out")"
if grep -q 'ADT_CFG_AGENT_BINARY_MISSING' "$GH_CALLS"; then ok "001 envelope posted on the issue"; else bad "001 no envelope posted"; fi
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"claude"* ]] && ok "001 envelope names the missing binary 'claude'" || bad "001 envelope omits binary name"
[[ "$GHBODY" == *"Install"* ]] && ok "001 envelope carries remediation" || bad "001 envelope missing remediation"
[[ "$GHBODY" == *'"surface":"issue-comment"'* ]] && ok "001 marker surface=issue-comment" || bad "001 marker surface wrong"

# ---------------------------------------------------------------------------
echo "=== TC-BINPF-002: present claude binary → rc 0, no envelope ==="
: > "$GH_CALLS"
make_stub_bin claude
out=$(preflight claude 232)
assert_rc "002 preflight returns 0 when binary present" 0 "$(rc_of "$out")"
if grep -q 'ADT_CFG_AGENT_BINARY_MISSING' "$GH_CALLS"; then bad "002 envelope wrongly posted"; else ok "002 no envelope when binary present"; fi
rm -f "$TMPROOT/bin/claude"

# ---------------------------------------------------------------------------
echo "=== TC-BINPF-003: kiro resolves 'kiro-cli' (not 'kiro') ==="
: > "$GH_CALLS"
make_stub_bin kiro                     # a `kiro` exists, but launch binary is kiro-cli
out=$(preflight kiro 233)
assert_rc "003 preflight returns 1 when kiro-cli absent (even with 'kiro' present)" 1 "$(rc_of "$out")"
[[ "$(cat "$GH_CALLS")" == *"kiro-cli"* ]] && ok "003 envelope names 'kiro-cli'" || bad "003 envelope should name kiro-cli"
rm -f "$TMPROOT/bin/kiro"
: > "$GH_CALLS"
make_stub_bin kiro-cli
out=$(preflight kiro 234)
assert_rc "003 preflight returns 0 when kiro-cli present" 0 "$(rc_of "$out")"
rm -f "$TMPROOT/bin/kiro-cli"

# ---------------------------------------------------------------------------
echo "=== TC-BINPF-004: launcher configured → preflight skipped (rc 0, no envelope) ==="
: > "$GH_CALLS"
# No `claude` on PATH, but a launcher is set → preflight stands down.
out=$(preflight claude 235 "cc-launcher" "--role" "dev")
assert_rc "004 preflight returns 0 with a launcher configured" 0 "$(rc_of "$out")"
if grep -q 'ADT_CFG_AGENT_BINARY_MISSING' "$GH_CALLS"; then bad "004 envelope wrongly posted with launcher"; else ok "004 no envelope with launcher (preflight skipped)"; fi

# ---------------------------------------------------------------------------
echo "=== TC-BINPF-005: empty ISSUE_NUMBER → dispatcher-alert (no gh post), rc 1 ==="
: > "$GH_CALLS"
out=$(preflight codex "")              # missing codex binary, no issue
assert_rc "005 preflight returns 1 (missing binary, no issue)" 1 "$(rc_of "$out")"
if grep -q 'GH:' "$GH_CALLS"; then bad "005 gh post made (should be dispatcher-alert log-only)"; else ok "005 no gh post (dispatcher-alert, no issue)"; fi

# ---------------------------------------------------------------------------
echo "=== TC-BINPF-006: _agent_launch_binary mapping ==="
map_of() {
  ( export AGENT_CMD="$1"; declare -a AGENT_LAUNCHER_ARGV=("${@:2}")
    # shellcheck disable=SC1090
    source "$LIB_ERROR" 2>/dev/null
    # shellcheck disable=SC1090
    source "$LIB_AGENT" 2>/dev/null
    AGENT_CMD="$1"
    # shellcheck disable=SC2034  # consumed by _agent_launch_binary (sourced from lib-agent.sh)
    [[ $# -gt 1 ]] && AGENT_LAUNCHER_ARGV=("${@:2}") || AGENT_LAUNCHER_ARGV=()
    _agent_launch_binary )
}
[[ "$(map_of claude)" == "claude" ]] && ok "006 claude → claude" || bad "006 claude mapping"
[[ "$(map_of codex)" == "codex" ]] && ok "006 codex → codex" || bad "006 codex mapping"
[[ "$(map_of kiro)" == "kiro-cli" ]] && ok "006 kiro → kiro-cli" || bad "006 kiro mapping"
[[ "$(map_of agy)" == "agy" ]] && ok "006 agy → agy" || bad "006 agy mapping"
[[ -z "$(map_of claude cc-launcher --role dev)" ]] && ok "006 launcher set → empty (skip)" || bad "006 launcher should map to empty"

echo ""
echo "============================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "============================================"
[[ "$FAIL" -eq 0 ]]
