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
mkdir -p "$TMPROOT/scripts" "$TMPROOT/bin" "$TMPROOT/cu" "$TMPROOT/home-none"
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
# `RC=<n>` last; the gh-calls log is shared via $GH_CALLS. HOME is pinned to an
# empty dir ($TMPROOT/home-none, #458) — otherwise the #458 user-install-dir
# probe would read the REAL $HOME's ~/.local/bin/etc and could resolve the
# host's actual agent CLI, defeating this test's "missing binary" premise.
preflight() {
  local agent_cmd="$1" issue="$2"; shift 2
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" ISSUE_NUMBER="$issue"
    export AGENT_CMD="$agent_cmd"
    export HOME="$TMPROOT/home-none"
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

# ---------------------------------------------------------------------------
echo "=== TC-BINPF-CODEX: codex REVIEW lane preflights its binary too (#231 review P1) ==="
# Regression for the finding that the codex review lane (_run_codex_review)
# launches `codex review …` directly via _run_with_timeout, bypassing the
# run_agent/resume_agent preflight. Static + behavioral.
LIB_REVIEW_CODEX="$SCRIPTS_DIR/lib-review-codex.sh"
# [INV-75] #232: _run_codex_review moved into adapters/codex.sh (lib-review-codex.sh
# is now a thin shim that sources it). Static check greps the adapter; behavioral
# check below still sources lib-review-codex.sh (the shim → adapter), unchanged.
CODEX_ADAPTER="$SCRIPTS_DIR/adapters/codex.sh"
# Static: _run_codex_review calls preflight_agent_binary and returns its rc.
if grep -qE 'preflight_agent_binary \|\| return' "$CODEX_ADAPTER"; then
  ok "CODEX _run_codex_review wires 'preflight_agent_binary || return'"
else
  bad "CODEX _run_codex_review does NOT wire the preflight (P1 regression)"
fi
# Behavioral: with AGENT_CMD=codex and NO codex on the hermetic PATH,
# _run_codex_review must surface ADT_CFG_AGENT_BINARY_MISSING on the issue and
# return non-zero BEFORE launching codex. We source lib-error + lib-agent +
# lib-review-codex (the review wrapper's source set) and call _run_codex_review
# directly; the preflight short-circuits at the top, so no real codex launch.
: > "$GH_CALLS"
codex_out=$(
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" ISSUE_NUMBER=231
    export AGENT_CMD=codex
    export HOME="$TMPROOT/home-none"   # #458: keep the probe off the real $HOME
    export PATH="$TMPROOT/bin:$TMPROOT/cu"   # no `codex` here
    # shellcheck disable=SC1090
    source "$LIB_ERROR"; source "$LIB_AGENT" 2>/dev/null; source "$LIB_REVIEW_CODEX" 2>/dev/null
    AGENT_CMD=codex
    _run_codex_review "review prompt" "sonnet" "$TMPROOT/codex-stdout.txt" ""
    echo "RC=$?"
  ) 2>/dev/null
)
codex_rc=$(rc_of "$codex_out")
assert_rc "CODEX _run_codex_review returns non-zero on missing codex binary" 1 "${codex_rc:-99}"
if grep -q 'ADT_CFG_AGENT_BINARY_MISSING' "$GH_CALLS"; then ok "CODEX envelope posted on the issue from the review lane"; else bad "CODEX no envelope posted from the review lane (P1 regression)"; fi
[[ "$(cat "$GH_CALLS")" == *"codex"* ]] && ok "CODEX envelope names the missing 'codex' binary" || bad "CODEX envelope omits binary name"
# Sanity: codex was never actually launched (no stdout capture written).
[[ ! -s "$TMPROOT/codex-stdout.txt" ]] && ok "CODEX no codex launch (aborted at preflight)" || bad "CODEX codex appears to have launched despite missing binary"

# ---------------------------------------------------------------------------
# TC-BINPATH-NNN (#458): probe user-level install dirs before declaring the
# binary genuinely missing.
# ---------------------------------------------------------------------------
# preflight_userhome <agent_cmd> <issue> <fake_home> — like preflight() above
# but with a controlled $HOME (for the ~/.local/bin etc. probe dirs) and a
# PATH that deliberately excludes every dir under it, so only the real
# `command -v` PATH lookup or the probe (which reads $HOME directly, not
# PATH) can find a binary.
preflight_userhome() {
  local agent_cmd="$1" issue="$2" fake_home="$3"
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" ISSUE_NUMBER="$issue"
    export AGENT_CMD="$agent_cmd"
    export HOME="$fake_home"
    export PATH="$TMPROOT/cu"   # no $TMPROOT/bin — only coreutils, never the probe dirs
    # shellcheck disable=SC1090
    source "$LIB_ERROR"
    # shellcheck disable=SC1090
    source "$LIB_AGENT"
    AGENT_CMD="$agent_cmd"
    preflight_agent_binary
    echo "RC=$?"
  )
}

echo ""
echo "=== TC-BINPATH-001: binary absent everywhere -> install remediation + PATH included ==="
: > "$GH_CALLS"
FAKEHOME="$TMPROOT/home-empty"
mkdir -p "$FAKEHOME/.local/bin" "$FAKEHOME/bin" "$FAKEHOME/.npm-global/bin"
out=$(preflight_userhome claude 331 "$FAKEHOME")
assert_rc "BINPATH-001 preflight returns 1 (genuinely absent)" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"Install 'claude'"* ]] && ok "BINPATH-001 keeps install-focused remediation" || bad "BINPATH-001 remediation changed unexpectedly"
[[ "$GHBODY" == *"effective PATH="* ]] && ok "BINPATH-001 cause includes the effective \$PATH" || bad "BINPATH-001 cause missing \$PATH for diagnosis"

echo ""
echo "=== TC-BINPATH-002: binary present in \$HOME/.local/bin but not on PATH ==="
: > "$GH_CALLS"
FAKEHOME="$TMPROOT/home-localbin"
mkdir -p "$FAKEHOME/.local/bin"
printf '#!/bin/bash\nexit 0\n' > "$FAKEHOME/.local/bin/claude"; chmod +x "$FAKEHOME/.local/bin/claude"
out=$(preflight_userhome claude 332 "$FAKEHOME")
assert_rc "BINPATH-002 preflight returns 1 (found but not on PATH)" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"$FAKEHOME/.local/bin/claude"* ]] && ok "BINPATH-002 cause names the found path" || bad "BINPATH-002 cause missing the found path"
[[ "$GHBODY" == *"not on the wrapper's PATH"* || "$GHBODY" == *"non-login shell"* ]] && ok "BINPATH-002 cause names the non-login-shell PATH gap" || bad "BINPATH-002 cause missing the PATH-gap explanation"
[[ "$GHBODY" == *"Extend PATH"* ]] && ok "BINPATH-002 remediation is PATH-specific" || bad "BINPATH-002 remediation not PATH-specific"
[[ "$GHBODY" != *"Install 'claude' on the execution host"* ]] && ok "BINPATH-002 does NOT use the generic install remediation" || bad "BINPATH-002 wrongly used the generic install remediation"

echo ""
echo "=== TC-BINPATH-003: binary present in an nvm shim dir but not on PATH ==="
: > "$GH_CALLS"
FAKEHOME="$TMPROOT/home-nvm"
mkdir -p "$FAKEHOME/.nvm/versions/node/v24.0.0/bin"
printf '#!/bin/bash\nexit 0\n' > "$FAKEHOME/.nvm/versions/node/v24.0.0/bin/codex"; chmod +x "$FAKEHOME/.nvm/versions/node/v24.0.0/bin/codex"
out=$(preflight_userhome codex 333 "$FAKEHOME")
assert_rc "BINPATH-003 preflight returns 1 (found via nvm glob, not on PATH)" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"$FAKEHOME/.nvm/versions/node/v24.0.0/bin/codex"* ]] && ok "BINPATH-003 cause names the nvm-found path" || bad "BINPATH-003 cause missing the nvm-found path"
[[ "$GHBODY" == *"Extend PATH"* ]] && ok "BINPATH-003 remediation is PATH-specific" || bad "BINPATH-003 remediation not PATH-specific"

echo ""
echo "=== TC-BINPATH-004: binary on PATH -> preflight passes, no envelope (regression pin) ==="
: > "$GH_CALLS"
make_stub_bin claude
out=$(preflight claude 334)
assert_rc "BINPATH-004 preflight returns 0 when binary on PATH" 0 "$(rc_of "$out")"
if grep -q 'ADT_CFG_AGENT_BINARY_MISSING' "$GH_CALLS"; then bad "BINPATH-004 envelope wrongly posted"; else ok "BINPATH-004 no envelope when binary on PATH"; fi
rm -f "$TMPROOT/bin/claude"

echo ""
echo "=== TC-BINPATH-005: launcher configured -> preflight skipped regardless of probe dirs (regression pin) ==="
: > "$GH_CALLS"
FAKEHOME="$TMPROOT/home-launcher"
mkdir -p "$FAKEHOME/.local/bin"
printf '#!/bin/bash\nexit 0\n' > "$FAKEHOME/.local/bin/claude"; chmod +x "$FAKEHOME/.local/bin/claude"
out=$(
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" ISSUE_NUMBER=335
    export AGENT_CMD=claude HOME="$FAKEHOME"
    export PATH="$TMPROOT/cu"
    # shellcheck disable=SC1090
    source "$LIB_ERROR"; source "$LIB_AGENT"
    AGENT_CMD=claude
    AGENT_LAUNCHER_ARGV=("cc-launcher" "--role" "dev")
    preflight_agent_binary
    echo "RC=$?"
  )
)
assert_rc "BINPATH-005 preflight returns 0 with a launcher configured" 0 "$(rc_of "$out")"
if grep -q 'ADT_CFG_AGENT_BINARY_MISSING' "$GH_CALLS"; then bad "BINPATH-005 envelope wrongly posted with launcher"; else ok "BINPATH-005 no envelope with launcher (preflight skipped, probe dirs irrelevant)"; fi

echo ""
echo "=== TC-BINPATH-006: binary present only in \$HOME/bin but not on PATH ==="
: > "$GH_CALLS"
FAKEHOME="$TMPROOT/home-bin"
mkdir -p "$FAKEHOME/bin"
printf '#!/bin/bash\nexit 0\n' > "$FAKEHOME/bin/claude"; chmod +x "$FAKEHOME/bin/claude"
out=$(preflight_userhome claude 336 "$FAKEHOME")
assert_rc "BINPATH-006 preflight returns 1 (found in ~/bin, not on PATH)" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"$FAKEHOME/bin/claude"* ]] && ok "BINPATH-006 cause names the ~/bin path" || bad "BINPATH-006 cause missing the ~/bin path"
[[ "$GHBODY" == *"Extend PATH"* ]] && ok "BINPATH-006 remediation is PATH-specific" || bad "BINPATH-006 remediation not PATH-specific"

echo ""
echo "=== TC-BINPATH-007: binary present only in \$HOME/.npm-global/bin but not on PATH ==="
: > "$GH_CALLS"
FAKEHOME="$TMPROOT/home-npmglobal"
mkdir -p "$FAKEHOME/.npm-global/bin"
printf '#!/bin/bash\nexit 0\n' > "$FAKEHOME/.npm-global/bin/claude"; chmod +x "$FAKEHOME/.npm-global/bin/claude"
out=$(preflight_userhome claude 337 "$FAKEHOME")
assert_rc "BINPATH-007 preflight returns 1 (found in ~/.npm-global/bin, not on PATH)" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"$FAKEHOME/.npm-global/bin/claude"* ]] && ok "BINPATH-007 cause names the ~/.npm-global/bin path" || bad "BINPATH-007 cause missing the ~/.npm-global/bin path"
[[ "$GHBODY" == *"Extend PATH"* ]] && ok "BINPATH-007 remediation is PATH-specific" || bad "BINPATH-007 remediation not PATH-specific"

echo ""
echo "=== TC-BINPATH-008: multiple nvm node-version dirs -> first glob match wins (pinned, per issue spec) ==="
: > "$GH_CALLS"
FAKEHOME="$TMPROOT/home-nvm-multi"
mkdir -p "$FAKEHOME/.nvm/versions/node/v18.20.4/bin" "$FAKEHOME/.nvm/versions/node/v22.3.0/bin"
# v18 sorts before v22 lexically; leave it non-executable so the pin proves
# "first GLOB match wins" (the issue's stated semantics) rather than "first
# EXECUTABLE match wins" — a later version having a working copy does not
# make the probe skip past an earlier, broken one.
printf '#!/bin/bash\nexit 0\n' > "$FAKEHOME/.nvm/versions/node/v18.20.4/bin/codex"   # not chmod +x
printf '#!/bin/bash\nexit 0\n' > "$FAKEHOME/.nvm/versions/node/v22.3.0/bin/codex"; chmod +x "$FAKEHOME/.nvm/versions/node/v22.3.0/bin/codex"
out=$(preflight_userhome codex 338 "$FAKEHOME")
assert_rc "BINPATH-008 preflight returns 1 (first glob match is v18, non-executable -> genuinely-missing branch)" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"Install 'codex'"* ]] && ok "BINPATH-008 falls to install-focused remediation (v18 match rejected, v22 never probed)" || bad "BINPATH-008 unexpected remediation branch"

echo ""
echo "=== TC-BINPATH-009: \$HOME unset -> genuinely-missing branch, no crash (regression pin) ==="
: > "$GH_CALLS"
out=$(
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r" ISSUE_NUMBER=339
    export AGENT_CMD=claude
    export PATH="$TMPROOT/cu"
    unset HOME
    # shellcheck disable=SC1090
    source "$LIB_ERROR"; source "$LIB_AGENT"
    AGENT_CMD=claude
    preflight_agent_binary
    echo "RC=$?"
  )
)
assert_rc "BINPATH-009 preflight returns 1 cleanly with HOME unset (no crash)" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"Install 'claude'"* ]] && ok "BINPATH-009 falls to install-focused remediation with HOME unset" || bad "BINPATH-009 unexpected remediation with HOME unset"
[[ "$GHBODY" == *"HOME is unset/empty"* ]] && ok "BINPATH-009 cause accurately says HOME is unset (not the generic probe-dir claim)" || bad "BINPATH-009 cause should not claim probe dirs were checked when HOME is unset"
[[ "$GHBODY" != *"also checked ~/.local/bin"* ]] && ok "BINPATH-009 cause does NOT claim probe dirs were checked" || bad "BINPATH-009 wrongly claims probe dirs were checked despite HOME being unset"

echo ""
echo "=== TC-BINPATH-010: a directory named like the binary is not treated as found ==="
: > "$GH_CALLS"
FAKEHOME="$TMPROOT/home-dirname"
mkdir -p "$FAKEHOME/.local/bin/claude"   # a directory, not a file, named "claude"
out=$(preflight_userhome claude 340 "$FAKEHOME")
assert_rc "BINPATH-010 preflight returns 1 (same-named directory is not a launchable binary)" 1 "$(rc_of "$out")"
GHBODY=$(cat "$GH_CALLS")
[[ "$GHBODY" == *"Install 'claude'"* ]] && ok "BINPATH-010 falls to install-focused remediation (directory rejected by -f)" || bad "BINPATH-010 wrongly treated a directory as the found binary"

echo ""
echo "============================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "============================================"
[[ "$FAIL" -eq 0 ]]
