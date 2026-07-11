#!/bin/bash
# run-error-envelope-e2e.sh — E2E for the operator error envelope (issue #231,
# INV-72). TC-ERR-ENVELOPE-040.
#
# WHAT IT DOES
# ------------
# Simulates a wrapper aborting on a deliberately-broken config and asserts the
# end-to-end surfacing contract through the REAL token-refresh `gh` proxy
# resolution path lib-error.sh uses (${AUTONOMOUS_CONF_DIR}/gh):
#
#   1. A config-class abort (here: an invalid E2E_MODE-style failure, surfaced
#      with a known issue number) posts an ISSUE COMMENT whose body carries the
#      stable `code` AND the `remediation` AND the machine-readable
#      `<!-- adt-error-envelope: {json} -->` marker.
#   2. The embedded marker JSON validates against
#      docs/pipeline/schemas/error-envelope.schema.json.
#   3. The post does NOT mutate the issue's label state — error_surface only
#      ever runs `gh issue comment`, never `gh issue edit --add-label` /
#      `--remove-label`. The stub proxy records EVERY `gh` invocation; we assert
#      no label-editing subcommand was called.
#
# This is the #231 E2E artifact: it runs the real lib-error.sh against a stub
# `gh` proxy (no network, no credentials), so CI runs it on bare ubuntu.
#
# Also covers TC-BINPATH-E2E (#458): preflight_agent_binary's user-level
# install-dir probe, driven the same way — real lib-agent.sh + lib-error.sh
# against a stub `gh` proxy, with PATH stripped of a stub HOME/.local/bin.
#
# Run: bash tests/e2e/run-error-envelope-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_ERROR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-error.sh"
LIB_AGENT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
SCHEMA="$PROJECT_ROOT/docs/pipeline/schemas/error-envelope.schema.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0
ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
note() { echo -e "  ${YELLOW}NOTE${NC}: $1"; }

[[ -f "$LIB_ERROR" ]] || { echo -e "${RED}FATAL${NC}: lib-error.sh missing"; exit 1; }

echo "=== TC-ERR-ENVELOPE-040: broken-conf abort surfaces a comment, label state unchanged ==="

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/scripts"
CALLS="$SANDBOX/gh-calls.log"; : > "$CALLS"

# Stub token-refresh `gh` proxy: record EVERY invocation (one arg per line,
# blank-line separated), echo a fake comment URL, succeed. This stands in for
# the real ${AUTONOMOUS_CONF_DIR}/gh → gh-with-token-refresh.sh symlink.
cat > "$SANDBOX/scripts/gh" <<EOF
#!/bin/bash
{ echo "GH-INVOCATION"; printf '%s\n' "\$@"; echo "---"; } >> "$CALLS"
echo "https://github.com/zxkane/autonomous-dev-team/issues/231#issuecomment-9999"
exit 0
EOF
chmod +x "$SANDBOX/scripts/gh"

# Drive the surfacing exactly as the wrapper call sites do: a config-class abort
# on a known issue number. We run it in a clean subshell under `set -euo
# pipefail` (the wrapper's mode) to prove error_surface never aborts the caller.
ISSUE=231
SURFACE_ERR="$SANDBOX/surface.err"
(
  set -euo pipefail
  export AUTONOMOUS_CONF_DIR="$SANDBOX/scripts"
  export REPO="zxkane/autonomous-dev-team"
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # Representative broken-conf abort (an invalid E2E_MODE), surfaced on the issue.
  error_surface "$ISSUE" ADT_CFG_E2E_MODE_INVALID \
    "E2E_MODE has an unrecognized value" \
    "E2E_MODE='foo' is not one of none / browser / command" \
    "Set E2E_MODE to none, browser, or command in scripts/autonomous.conf, then re-dispatch" \
    "docs/pipeline/errors.md#configuration-class-class-config"
) 2>"$SURFACE_ERR"
SURFACE_RC=$?

[[ "$SURFACE_RC" -eq 0 ]] && ok "error_surface returned 0 (best-effort, did not abort the set -e caller)" \
  || bad "error_surface returned $SURFACE_RC (must be 0)"

CALLBODY=$(cat "$CALLS")

# 1. A comment was posted.
if grep -q "issue" "$CALLS" && grep -q "comment" "$CALLS"; then
  ok "gh issue comment was invoked"
else
  bad "no gh issue comment invocation recorded"
fi

# 1a. The comment body carries the code + remediation + marker.
if [[ "$CALLBODY" == *"ADT_CFG_E2E_MODE_INVALID"* ]]; then ok "comment carries the stable code"; else bad "comment missing the code"; fi
if [[ "$CALLBODY" == *"Set E2E_MODE to none, browser, or command"* ]]; then ok "comment carries the remediation"; else bad "comment missing the remediation"; fi
if [[ "$CALLBODY" == *"adt-error-envelope:"* ]]; then ok "comment carries the machine-readable marker"; else bad "comment missing the marker"; fi

# 2. The embedded marker JSON validates against the schema.
MARKER_JSON=$(printf '%s\n' "$CALLBODY" | sed -n 's/.*<!-- adt-error-envelope: \(.*\) -->.*/\1/p' | head -1)
if [[ -n "$MARKER_JSON" ]]; then
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1 && [[ -f "$SCHEMA" ]]; then
    _inst="$SANDBOX/inst.json"; printf '%s' "$MARKER_JSON" > "$_inst"
    if python3 - "$SCHEMA" "$_inst" <<'PY'
import json, sys
from jsonschema import Draft7Validator
sys.exit(1 if list(Draft7Validator(json.load(open(sys.argv[1]))).iter_errors(json.load(open(sys.argv[2])))) else 0)
PY
    then ok "marker JSON validates against error-envelope.schema.json (python3 jsonschema)"
    else bad "marker JSON REJECTED by schema"; fi
  else
    note "python3 jsonschema unavailable — jq structural check"
    if printf '%s' "$MARKER_JSON" | jq -e '.schema_version==1 and (.code|test("^[A-Z][A-Z0-9_]*$")) and (.remediation|length>0) and .surface=="issue-comment"' >/dev/null 2>&1; then
      ok "marker JSON structurally valid (jq)"
    else bad "marker JSON structurally invalid (jq)"; fi
  fi
else
  bad "could not extract marker JSON from the posted comment"
fi

# 3. Label state unchanged: no label-editing subcommand was invoked.
if grep -qE -- '--add-label|--remove-label' "$CALLS"; then
  bad "a label-editing gh subcommand was invoked (error_surface must NOT mutate labels)"
else
  ok "no label mutation — issue label state unchanged by the surfacing post"
fi
# Stronger: the ONLY gh subcommand seen is `issue comment` (not `issue edit`).
if grep -qE '^edit$' "$CALLS"; then
  bad "gh issue edit was invoked (label mutation risk)"
else
  ok "no gh issue edit invoked"
fi

# ===========================================================================
echo ""
echo "=== TC-ERR-ENVELOPE-042 (INV-81, #235): a startup-failure envelope carries the run-id footer when a run dir is provisioned ==="
# The wrappers now provision the run dir + RUN_ID BEFORE the config/auth/E2E/PID
# error_surface calls, so a startup-failure envelope links to the durable run dir.
# Drive error_surface with lib-run-artifacts sourced + a real run dir minted, and
# assert the posted body gains the `run-id: … · artifacts: …` footer.
LIB_RUN_ARTIFACTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-run-artifacts.sh"
CALLS2="$SANDBOX/gh-calls-2.log"; : > "$CALLS2"
# Own scripts dir so this case never disturbs the original gh stub above.
mkdir -p "$SANDBOX/scripts2"
cat > "$SANDBOX/scripts2/gh" <<EOF
#!/bin/bash
{ echo "GH-INVOCATION"; printf '%s\n' "\$@"; echo "---"; } >> "$CALLS2"
echo "https://github.com/zxkane/autonomous-dev-team/issues/231#issuecomment-10000"
exit 0
EOF
chmod +x "$SANDBOX/scripts2/gh"
RUN_STATE_BASE="$SANDBOX/state/autonomous-errenv-proj"
(
  set -euo pipefail
  export AUTONOMOUS_CONF_DIR="$SANDBOX/scripts2"
  export REPO="zxkane/autonomous-dev-team"
  export PROJECT_ID="errenv-proj"
  export AUTONOMOUS_RUN_DIR_BASE="$RUN_STATE_BASE"
  # shellcheck disable=SC1090
  source "$LIB_RUN_ARTIFACTS"
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # Provision the run dir + RUN_ID exactly as the wrappers now do at startup,
  # BEFORE surfacing — this is the ordering the [P1] fix enforces.
  run_artifacts_init review 231 || true
  error_surface 231 ADT_CFG_E2E_MODE_INVALID \
    "E2E_MODE has an unrecognized value" \
    "E2E_MODE='foo' is not one of none / browser / command" \
    "Set E2E_MODE to none, browser, or command in scripts/autonomous.conf, then re-dispatch" \
    "docs/pipeline/errors.md#configuration-class-class-config"
) 2>/dev/null
CALLBODY2=$(cat "$CALLS2")
if [[ "$CALLBODY2" == *"ADT_CFG_E2E_MODE_INVALID"* ]]; then ok "042 envelope still carries the code (footer is additive)"; else bad "042 envelope lost the code"; fi
if [[ "$CALLBODY2" == *"run-id: errenv-proj-231-review-"* ]]; then ok "042 envelope carries the run-id footer"; else bad "042 envelope MISSING the run-id footer"; fi
if [[ "$CALLBODY2" == *"artifacts: ${RUN_STATE_BASE}/runs/errenv-proj-231-review-"* ]]; then ok "042 envelope footer points at the durable run dir"; else bad "042 envelope footer missing the artifacts dir"; fi
if [[ "$CALLBODY2" == *"adt-error-envelope:"* ]]; then ok "042 envelope marker JSON still present (footer appended at END, marker intact)"; else bad "042 envelope marker lost"; fi

# ===========================================================================
echo ""
echo "=== TC-ERR-ENVELOPE-041: review-wrapper startup validations target the issue (P1-1 pin) ==="
# Regression pin for the P1-1 finding: the review wrapper's startup validations
# run BEFORE the authoritative arg-parse loop. Pre-fix they called
# `error_surface -` (dispatcher-alert / log-only), so a broken E2E_MODE /
# missing parser / invalid timeout / bad REVIEW_BOTS never posted to the issue.
# The fix adds an early non-destructive `error_peek_issue_arg "$@"` scan that
# populates ISSUE_NUMBER, and switches every validation to
# `error_surface "$ISSUE_NUMBER" …`. A full-wrapper run is too heavy/fragile for
# a deterministic E2E (token-mode setup_github_auth probes the host), so we
# statically assert the wired behavior instead — the dynamic surfacing path
# itself is covered by TC-040 + the unit suite.
REVIEW_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
DISPATCH_TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

# 1. The early issue-peek runs before any validation in BOTH wrappers.
for w in "$REVIEW_WRAPPER" "$DEV_WRAPPER"; do
  peek_line=$(grep -n 'ISSUE_NUMBER="$(error_peek_issue_arg "$@")"' "$w" | head -1 | cut -d: -f1)
  # Match an actual error_surface CALL (followed by an arg), not a comment that
  # merely mentions the function name.
  first_surface=$(grep -nE '^[[:space:]]*error_surface +("\$ISSUE_NUMBER"|-) ' "$w" | head -1 | cut -d: -f1)
  if [[ -n "$peek_line" && -n "$first_surface" && "$peek_line" -lt "$first_surface" ]]; then
    ok "041 $(basename "$w"): early issue-peek (line $peek_line) precedes first error_surface (line $first_surface)"
  else
    bad "041 $(basename "$w"): issue-peek must precede the first error_surface (peek=$peek_line surface=$first_surface)"
  fi
done

# 2. NO review/dev wrapper startup validation still uses the `-` dispatcher-alert
#    sentinel — they must all target "$ISSUE_NUMBER" now (P1-1).
if grep -qE 'error_surface +- ' "$REVIEW_WRAPPER" "$DEV_WRAPPER"; then
  bad "041 a wrapper validation still uses 'error_surface -' (dispatcher-alert) instead of \$ISSUE_NUMBER"
else
  ok "041 no wrapper validation uses the '-' dispatcher-alert sentinel (all target \$ISSUE_NUMBER)"
fi

# 3. P1-2: dispatcher preflights the required keys BEFORE sourcing lib-dispatch.sh
#    (which has top-level \${VAR:?} guards that would raw-abort otherwise).
preflight_line=$(grep -n 'for _req in REPO REPO_OWNER PROJECT_ID PROJECT_DIR' "$DISPATCH_TICK" | head -1 | cut -d: -f1)
source_line=$(grep -n 'source "\${LIB_DIR}/lib-dispatch.sh"' "$DISPATCH_TICK" | head -1 | cut -d: -f1)
if [[ -n "$preflight_line" && -n "$source_line" && "$preflight_line" -lt "$source_line" ]]; then
  ok "041 dispatcher preflights required keys (line $preflight_line) before sourcing lib-dispatch.sh (line $source_line)"
else
  bad "041 dispatcher required-key preflight must precede the lib-dispatch.sh source (preflight=$preflight_line source=$source_line)"
fi

# 4. P1-3: lib-agent.sh launcher guards surface (error_surface), not log-only.
LIB_AGENT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
if grep -qE 'error_envelope ADT_CFG_LAUNCHER_(PARSE|CLI_MISMATCH)' "$LIB_AGENT"; then
  bad "041 a launcher guard still renders via error_envelope (log-only) instead of error_surface (P1-3)"
else
  ok "041 launcher guards use error_surface (GitHub-visible), not error_envelope-to-stderr"
fi

echo ""
echo "=== TC-BINPATH-E2E (#458): PATH stripped of ~/.local/bin, stub binary placed there ==="
# Simulates the exact motivating scenario: a cron/SSM-spawned non-login shell
# whose PATH lacks ~/.local/bin, where the agent CLI is nonetheless installed.
# Drives preflight_agent_binary directly (the real lib-agent.sh function, not a
# parallel invocation path) against a stub HOME + stripped PATH + the real
# lib-error.sh gh-proxy resolution, and asserts the posted comment carries the
# PATH-specific remediation and the found path — not the generic install text.
[[ -f "$LIB_AGENT" ]] || { echo -e "${RED}FATAL${NC}: lib-agent.sh missing"; exit 1; }

BINPATH_SANDBOX=$(mktemp -d)
mkdir -p "$BINPATH_SANDBOX/scripts" "$BINPATH_SANDBOX/home/.local/bin" "$BINPATH_SANDBOX/cu"
BINPATH_CALLS="$BINPATH_SANDBOX/gh-calls.log"; : > "$BINPATH_CALLS"

cat > "$BINPATH_SANDBOX/scripts/gh" <<EOF
#!/bin/bash
{ echo "GH-INVOCATION"; printf '%s\n' "\$@"; echo "---"; } >> "$BINPATH_CALLS"
echo "https://github.com/zxkane/autonomous-dev-team/issues/458#issuecomment-9999"
exit 0
EOF
chmod +x "$BINPATH_SANDBOX/scripts/gh"

# Hermetic coreutils dir — PATH is ONLY this + nothing else, so the stub binary
# under ~/.local/bin is invisible to `command -v` (the non-login-shell gap) but
# still discoverable by the #458 probe, which reads $HOME directly.
for _u in bash sh env jq sed grep cat date dirname basename readlink \
          mkdir rm chmod ln mktemp timeout cut tr head tail wc sort uniq awk tee cp mv compgen; do
  _p=$(command -v "$_u" 2>/dev/null) && ln -sf "$_p" "$BINPATH_SANDBOX/cu/$_u"
done

printf '#!/bin/bash\nexit 0\n' > "$BINPATH_SANDBOX/home/.local/bin/agy"
chmod +x "$BINPATH_SANDBOX/home/.local/bin/agy"

(
  set -uo pipefail
  export AUTONOMOUS_CONF_DIR="$BINPATH_SANDBOX/scripts" REPO="zxkane/autonomous-dev-team" ISSUE_NUMBER=458
  export AGENT_CMD=agy
  export HOME="$BINPATH_SANDBOX/home"
  export PATH="$BINPATH_SANDBOX/cu"
  # shellcheck disable=SC1090
  source "$LIB_ERROR"
  # shellcheck disable=SC1090
  source "$LIB_AGENT"
  AGENT_CMD=agy
  preflight_agent_binary
) 2>/dev/null
BINPATH_RC=$?

[[ "$BINPATH_RC" -eq 1 ]] && ok "preflight_agent_binary returns 1 (binary found but not on PATH)" \
  || bad "preflight_agent_binary returned $BINPATH_RC (expected 1)"

BINPATH_BODY=$(cat "$BINPATH_CALLS")
if [[ "$BINPATH_BODY" == *"$BINPATH_SANDBOX/home/.local/bin/agy"* ]]; then
  ok "comment names the found path under ~/.local/bin"
else
  bad "comment missing the found ~/.local/bin path"
fi
if [[ "$BINPATH_BODY" == *"Extend PATH"* ]]; then
  ok "comment carries the PATH-specific remediation"
else
  bad "comment missing the PATH-specific remediation"
fi
if [[ "$BINPATH_BODY" == *"Install 'agy' on the execution host"* ]]; then
  bad "comment wrongly used the generic install remediation"
else
  ok "comment does NOT use the generic install remediation"
fi

rm -rf "$BINPATH_SANDBOX"

echo ""
echo "=== TC-TIMEOUTGUARD-060/061 (#451, INV-126): PATH stubbed to hide timeout/gtimeout -> wrapper source fails closed ==="
# Simulates the motivating scenario: a fresh macOS host (or a remote-aws-ssm
# execution host, simulated by this stripped PATH regardless of what the
# LOCAL/dispatcher host's own PATH looks like) with neither coreutils
# `timeout` nor `gtimeout` on PATH. lib-agent.sh's fail-closed default (#451
# / INV-126) must refuse the source itself and post a real
# ADT_CFG_TIMEOUT_TOOL_MISSING envelope through the real lib-error.sh
# gh-proxy resolution path — no agent launch is possible because sourcing
# lib-agent.sh itself aborts.
LIB_AGENT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
[[ -f "$LIB_AGENT" ]] || { echo -e "${RED}FATAL${NC}: lib-agent.sh missing"; exit 1; }

TG_SANDBOX=$(mktemp -d)
mkdir -p "$TG_SANDBOX/scripts" "$TG_SANDBOX/cu-notimeout"
TG_CALLS="$TG_SANDBOX/gh-calls.log"; : > "$TG_CALLS"

cat > "$TG_SANDBOX/scripts/gh" <<EOF
#!/bin/bash
{ echo "GH-INVOCATION"; printf '%s\n' "\$@"; echo "---"; } >> "$TG_CALLS"
echo "https://github.com/zxkane/autonomous-dev-team/issues/451#issuecomment-9999"
exit 0
EOF
chmod +x "$TG_SANDBOX/scripts/gh"

# Hermetic coreutils dir WITHOUT timeout/gtimeout — stands in for the
# execution host that sources lib-agent.sh (TC-TIMEOUTGUARD-060), and,
# reused verbatim, for a simulated remote-aws-ssm execution host
# (TC-TIMEOUTGUARD-061) regardless of what this test RUNNER's own ambient
# PATH contains (it has a real 'timeout', proving local presence never
# leaks into the sourcing site's decision).
for _u in bash sh env jq sed grep cat date dirname basename readlink \
          mkdir rm chmod ln mktemp cut tr head tail wc sort uniq awk tee cp mv setsid sleep; do
  _p=$(command -v "$_u" 2>/dev/null) && ln -sf "$_p" "$TG_SANDBOX/cu-notimeout/$_u"
done

TG_OUT=$(
  ( set -uo pipefail
    export AUTONOMOUS_CONF_DIR="$TG_SANDBOX/scripts" REPO="zxkane/autonomous-dev-team"
    export REPO_OWNER=zxkane REPO_NAME=autonomous-dev-team PROJECT_ID=t PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
    export PATH="$TG_SANDBOX/cu-notimeout"
    # shellcheck disable=SC1090
    source "$LIB_ERROR"
    # shellcheck disable=SC1090
    source "$LIB_AGENT" --issue 451
    echo "RC=$?"
  ) 2>&1
)
TG_RC=$(sed -n 's/.*RC=\([0-9]*\).*/\1/p' <<<"$TG_OUT" | tail -1)

[[ "${TG_RC:-99}" -eq 1 ]] && ok "TIMEOUTGUARD-060 lib-agent.sh source refuses to complete (fail-closed) when neither binary is on PATH" \
  || bad "TIMEOUTGUARD-060 expected source rc=1, got ${TG_RC:-<none>}"

TG_BODY=$(cat "$TG_CALLS")
if [[ "$TG_BODY" == *"ADT_CFG_TIMEOUT_TOOL_MISSING"* ]]; then
  ok "TIMEOUTGUARD-060 a real issue-comment-shaped envelope naming ADT_CFG_TIMEOUT_TOOL_MISSING was posted"
else
  bad "TIMEOUTGUARD-060 no ADT_CFG_TIMEOUT_TOOL_MISSING envelope posted"
fi
[[ "$TG_BODY" == *"adt-error-envelope:"* ]] && ok "TIMEOUTGUARD-060 envelope carries the machine-readable marker" || bad "TIMEOUTGUARD-060 envelope missing the marker"

# TC-TIMEOUTGUARD-061: this test runner's own host genuinely has 'timeout' —
# confirms the fail-closed result above is NOT an artifact of a host that
# happens to lack it everywhere, i.e. the check that matters is the one at
# the sourcing site (simulated remote), not the caller's ambient PATH.
if command -v timeout >/dev/null 2>&1; then
  ok "TIMEOUTGUARD-061 test-runner host has 'timeout' in its own ambient PATH, yet the simulated remote sourcing site still failed closed — local presence is not sufficient"
else
  echo -e "  ${YELLOW}NOTE${NC}: TIMEOUTGUARD-061 runner host lacks 'timeout' too — the contrast is less sharp here but the fail-closed result still holds"
fi

rm -rf "$TG_SANDBOX"

echo ""
echo "============================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "============================================"
[[ "$FAIL" -eq 0 ]]
