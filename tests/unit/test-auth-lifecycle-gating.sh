#!/bin/bash
# test-auth-lifecycle-gating.sh — issue #416 R2.
#
# Drives lib-auth.sh's setup_github_auth / setup_agent_token and
# dispatcher-tick.sh's app-mode credential FATAL under three topologies:
#   - github/github (byte-identical to pre-change main)
#   - gitlab/gitlab (full no-op)
#   - mixed github/gitlab and gitlab/github (gh lifecycle still runs)
#
# TC IDs per docs/test-cases/w-a-gitlab-transport.md (TC-AUTH-001..010).
#
# Run: env -u PROJECT_DIR bash tests/unit/test-auth-lifecycle-gating.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_AUTH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-auth.sh"
DISPATCHER_TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected='$e' actual='$a'"; fi; }
assert_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      needle='$n'"; echo "      haystack='${h:0:400}'"; fi; }
assert_not_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      should NOT contain: '$n'"; fi; }

[[ -f "$LIB_AUTH" ]] || { echo "FATAL: $LIB_AUTH not found"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Create a fake project-side dir with the gh-with-token-refresh.sh stub
# executable — setup_github_auth will symlink it during the github lane.
FAKE_PROJECT_DIR="$WORK/fake-project"
mkdir -p "$FAKE_PROJECT_DIR"
cat > "$FAKE_PROJECT_DIR/gh-with-token-refresh.sh" <<'STUB'
#!/bin/bash
# stub gh wrapper — never actually invoked in these tests.
exit 0
STUB
chmod +x "$FAKE_PROJECT_DIR/gh-with-token-refresh.sh"
# Provide a minimal autonomous.conf so lib-auth.sh's load_autonomous_conf
# doesn't misbehave. lib-auth.sh uses AUTONOMOUS_CONF_DIR to locate its
# project-side dir.
cat > "$FAKE_PROJECT_DIR/autonomous.conf" <<EOF
REPO="test/repo"
REPO_OWNER="test"
REPO_NAME="repo"
EOF
chmod 600 "$FAKE_PROJECT_DIR/autonomous.conf"

# _drive_setup_github_auth <ISSUE_PROVIDER> <CODE_HOST> [GH_AUTH_MODE]
#   Source lib-auth.sh in a fresh subshell with the given seam vars and PAT
#   mode; call setup_github_auth; print module-level state + snapshot.
#
# Output shape (parsable):
#   TOKEN_DAEMON_PID=<val>
#   GH_WRAPPER_DIR=<val>
#   GH_LINK_EXISTS=<0|1>   (whether <fake-project>/gh symlink exists)
_drive_setup_github_auth() {
  local ip="$1" ch="$2" mode="${3:-token}"
  # Materialize the driver script to a file so we sidestep multi-level quoting.
  local driver="$WORK/drive-setup-gh.sh"
  cat > "$driver" <<DRV
source "$LIB_AUTH"
# Stub the daemon spawner (app-mode uses it; PAT-mode never reaches it).
_spawn_token_daemon() { echo "stub daemon spawned" >&2; }
setup_github_auth 2>&1
echo "TOKEN_DAEMON_PID=\${TOKEN_DAEMON_PID:-}"
echo "GH_WRAPPER_DIR=\${GH_WRAPPER_DIR:-}"
if [[ -L "$FAKE_PROJECT_DIR/gh" ]]; then
  echo "GH_LINK_EXISTS=1"
else
  echo "GH_LINK_EXISTS=0"
fi
DRV
  env -u PROJECT_DIR PATH="$PATH" \
      ISSUE_PROVIDER="$ip" CODE_HOST="$ch" GH_AUTH_MODE="$mode" \
      AUTONOMOUS_CONF_DIR="$FAKE_PROJECT_DIR" \
      REPO_OWNER="test" REPO_NAME="repo" \
      bash "$driver"
  # Clean up the fake project-side gh symlink between drives.
  rm -f "$FAKE_PROJECT_DIR/gh" 2>/dev/null || true
}

# _drive_setup_agent_token <ISSUE_PROVIDER> <CODE_HOST> [GH_AUTH_MODE] [GITLAB_TOKEN]
#   Source lib-auth.sh, call setup_agent_token, and print the stderr output
#   + module-level WARN latches. Deterministic — no scoped-token mint in PAT
#   or gitlab-only mode.
_drive_setup_agent_token() {
  local ip="$1" ch="$2" mode="${3:-token}" gltok="${4:-}"
  env -u PROJECT_DIR PATH="$PATH" \
      ISSUE_PROVIDER="$ip" CODE_HOST="$ch" GH_AUTH_MODE="$mode" \
      AUTONOMOUS_CONF_DIR="$FAKE_PROJECT_DIR" \
      REPO_OWNER="test" REPO_NAME="repo" \
      GITLAB_TOKEN="$gltok" \
      bash -c "
        source '$LIB_AUTH' 2>&1
        setup_agent_token 2>&1
        # Second invocation to test latch (only the GitLab PAT WARN should
        # not repeat; latched).
        setup_agent_token 2>&1
      "
}

# ===========================================================================
echo "=== TC-AUTH-001: github/github default (PAT mode) — gh lifecycle byte-identical ==="
# ===========================================================================
out=$(_drive_setup_github_auth github github token 2>&1)
gh_wrapper=$(grep -oE 'GH_WRAPPER_DIR=[^ ]*' <<<"$out" | head -n1 | cut -d= -f2)
gh_link=$(grep -oE 'GH_LINK_EXISTS=[01]' <<<"$out" | head -n1 | cut -d= -f2)
# PAT mode DOES install the gh wrapper symlink if gh-with-token-refresh.sh is
# executable. Assert both: wrapper dir created + link installed.
if [[ -n "$gh_wrapper" ]]; then
  ok "TC-AUTH-001: github/github PAT mode created GH_WRAPPER_DIR ($gh_wrapper)"
else
  bad "TC-AUTH-001: github/github PAT mode did NOT create GH_WRAPPER_DIR"
fi
assert_eq "TC-AUTH-001: github/github PAT mode installed \${_LIB_AUTH_DIR}/gh symlink (GH_LINK_EXISTS=1)" "1" "$gh_link"

# ===========================================================================
echo "=== TC-AUTH-002: gitlab/gitlab — full no-op ==="
# ===========================================================================
out=$(_drive_setup_github_auth gitlab gitlab token 2>&1)
gh_wrapper=$(grep -oE 'GH_WRAPPER_DIR=[^ ]*' <<<"$out" | head -n1 | cut -d= -f2)
gh_link=$(grep -oE 'GH_LINK_EXISTS=[01]' <<<"$out" | head -n1 | cut -d= -f2)
assert_eq "TC-AUTH-002: gitlab/gitlab did NOT create GH_WRAPPER_DIR (empty)" "" "$gh_wrapper"
assert_eq "TC-AUTH-002: gitlab/gitlab did NOT install \${_LIB_AUTH_DIR}/gh symlink" "0" "$gh_link"
# No GH_TOKEN-related warn — PAT-mode WARN suppressed on non-github lane.
assert_not_contains "TC-AUTH-002: no GH_TOKEN-related WARN on gitlab/gitlab" "GH_TOKEN" "$out"

# ===========================================================================
echo "=== TC-AUTH-003: github ITP / gitlab CHP — gh lifecycle STILL runs ==="
# ===========================================================================
out=$(_drive_setup_github_auth github gitlab token 2>&1)
gh_wrapper=$(grep -oE 'GH_WRAPPER_DIR=[^ ]*' <<<"$out" | head -n1 | cut -d= -f2)
gh_link=$(grep -oE 'GH_LINK_EXISTS=[01]' <<<"$out" | head -n1 | cut -d= -f2)
if [[ -n "$gh_wrapper" ]]; then
  ok "TC-AUTH-003: github/gitlab (mixed) created GH_WRAPPER_DIR — github ITP needs it"
else
  bad "TC-AUTH-003: github/gitlab created no GH_WRAPPER_DIR (SHOULD)"
fi
assert_eq "TC-AUTH-003: github/gitlab installed \${_LIB_AUTH_DIR}/gh symlink" "1" "$gh_link"

# ===========================================================================
echo "=== TC-AUTH-004: gitlab ITP / github CHP — gh lifecycle STILL runs ==="
# ===========================================================================
out=$(_drive_setup_github_auth gitlab github token 2>&1)
gh_wrapper=$(grep -oE 'GH_WRAPPER_DIR=[^ ]*' <<<"$out" | head -n1 | cut -d= -f2)
gh_link=$(grep -oE 'GH_LINK_EXISTS=[01]' <<<"$out" | head -n1 | cut -d= -f2)
if [[ -n "$gh_wrapper" ]]; then
  ok "TC-AUTH-004: gitlab/github (mixed) created GH_WRAPPER_DIR — github CHP needs it"
else
  bad "TC-AUTH-004: gitlab/github created no GH_WRAPPER_DIR (SHOULD)"
fi
assert_eq "TC-AUTH-004: gitlab/github installed \${_LIB_AUTH_DIR}/gh symlink" "1" "$gh_link"

# ===========================================================================
echo "=== TC-AUTH-005: gitlab/gitlab + setup_agent_token (PAT mode) — no PAT WARN ==="
# ===========================================================================
out=$(_drive_setup_agent_token gitlab gitlab token 2>&1)
# The GitHub PAT WARN must NOT fire on a gitlab/gitlab lane.
assert_not_contains "TC-AUTH-005: no GH PAT WARN on gitlab/gitlab lane" "GH_AUTH_MODE=token — a PAT cannot be down-scoped" "$out"

# ===========================================================================
echo "=== TC-AUTH-006: github/github + setup_agent_token (PAT mode) — WARN once ==="
# ===========================================================================
out=$(_drive_setup_agent_token github github token 2>&1)
pat_warn_count=$(grep -c "GH_AUTH_MODE=token — a PAT cannot be down-scoped" <<<"$out")
assert_eq "TC-AUTH-006: github/github PAT WARN emitted ONCE (latched across 2 calls)" "1" "$pat_warn_count"

# ===========================================================================
echo "=== TC-AUTH-007: gitlab/gitlab + GITLAB_TOKEN set + PAT mode — GitLab PAT WARN once ==="
# ===========================================================================
out=$(_drive_setup_agent_token gitlab gitlab token "my-gitlab-token" 2>&1)
gl_warn_count=$(grep -c "GITLAB_TOKEN is present in the wrapper env" <<<"$out")
assert_eq "TC-AUTH-007: GitLab PAT WARN emitted ONCE (latched across 2 calls)" "1" "$gl_warn_count"
assert_contains "TC-AUTH-007: WARN mentions INV-79 posture" "INV-79" "$out"

# ===========================================================================
echo "=== TC-AUTH-008..010: REAL dispatcher-tick.sh app-mode FATAL segment (P1-2 review-response) ==="
# ===========================================================================
# [P1-2] Drive the REAL segment sourced from dispatcher-tick.sh — not a copy
# of the gate expression, so a future edit to the seam predicate is
# regression-tested against the FILE, not a fixture. We extract the segment
# from `if [[ "${GH_AUTH_MODE:-token}" == "app" ]] && github_seam_active` up
# to (but not including) the `get_gh_app_token` mint call via awk anchor,
# and eval it inside a subshell that has sourced lib-auth.sh (which supplies
# the shared `github_seam_active` predicate) + a stubbed `error_surface`.
DISP_TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
[[ -f "$DISP_TICK" ]] || { echo "FATAL: dispatcher-tick.sh not found at $DISP_TICK"; exit 2; }

DISP_SEGMENT=$(awk '
  /^if \[\[ "\$\{GH_AUTH_MODE:-token\}" == "app" \]\] && github_seam_active; then$/ { grab=1 }
  # Exit BEFORE printing the token-mint line so the extracted segment ends
  # cleanly at the `source gh-app-token.sh` step (well past the FATAL block
  # under test) — including the `_dispatcher_token=$(get_gh_app_token \`
  # line would leave an unbalanced `$(` since we stop mid-expression.
  /^  _dispatcher_token=/ { exit }
  grab { print }
' "$DISP_TICK")
# Append a synthetic `fi` to close the outer `if` (the extracted segment
# stops mid-body, so bash would otherwise die on `unexpected EOF while
# looking for matching fi`). The extracted segment's own inner `if [[ -z
# ... ]]; then ... fi` closes cleanly before the exit; only the OUTER
# `if [[ GH_AUTH_MODE ... ]] && github_seam_active; then` needs closing.
DISP_SEGMENT+=$'\nfi'
if [[ -z "$DISP_SEGMENT" ]]; then
  bad "TC-AUTH-008..010: could not extract dispatcher-tick app-mode segment (awk anchor missing? file drift?)"
fi

_drive_real_dispatcher_gate() {
  local ip="$1" ch="$2"
  local driver="$WORK/drive-real-dispatcher.sh"
  cat > "$driver" <<DRV
# Stub error_surface (dispatcher-tick calls it before its own exit 1).
error_surface() { echo "[stub error_surface] \$@" >&2; }
source "$LIB_AUTH"
$DISP_SEGMENT
# If we got here without exit 1, the gate skipped or App creds were fine.
echo "no-fatal-reached"
exit 0
DRV
  env -u PROJECT_DIR PATH="$PATH" \
      ISSUE_PROVIDER="$ip" CODE_HOST="$ch" GH_AUTH_MODE="app" \
      AUTONOMOUS_CONF_DIR="$FAKE_PROJECT_DIR" \
      REPO="test/repo" REPO_OWNER="test" REPO_NAME="repo" \
      DISPATCHER_APP_ID="" DISPATCHER_APP_PEM="" \
      LIB_DIR="$(dirname "$LIB_AUTH")" \
      bash "$driver"
}

# TC-AUTH-008: gitlab/gitlab app-mode against the REAL segment — NO FATAL.
out=$(_drive_real_dispatcher_gate gitlab gitlab 2>&1); rc=$?
assert_eq "TC-AUTH-008: gitlab/gitlab REAL dispatcher-tick segment → rc 0 (no FATAL)" "0" "$rc"
assert_contains "TC-AUTH-008: reaches past the gate (no-fatal-reached)" "no-fatal-reached" "$out"

# TC-AUTH-009: github/gitlab (mixed) app-mode → REAL segment FATAL.
out=$(_drive_real_dispatcher_gate github gitlab 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "TC-AUTH-009: github/gitlab mixed → REAL dispatcher-tick FATAL (rc 1)"
else
  bad "TC-AUTH-009: github/gitlab did NOT FATAL (rc $rc)"
fi
assert_contains "TC-AUTH-009: FATAL message mentions DISPATCHER_APP_ID" "DISPATCHER_APP_ID" "$out"

# TC-AUTH-010: default unset → github/github via defaults → REAL segment FATAL.
_driver_default="$WORK/drive-real-dispatcher-default.sh"
cat > "$_driver_default" <<DRV
error_surface() { echo "[stub error_surface] \$@" >&2; }
source "$LIB_AUTH"
$DISP_SEGMENT
echo "no-fatal-reached"
exit 0
DRV
out=$(env -u PROJECT_DIR -u ISSUE_PROVIDER -u CODE_HOST PATH="$PATH" \
      GH_AUTH_MODE="app" AUTONOMOUS_CONF_DIR="$FAKE_PROJECT_DIR" \
      REPO="test/repo" REPO_OWNER="test" REPO_NAME="repo" \
      DISPATCHER_APP_ID="" DISPATCHER_APP_PEM="" \
      LIB_DIR="$(dirname "$LIB_AUTH")" \
      bash "$_driver_default" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "TC-AUTH-010: default unset → github/github → REAL segment FATAL (byte-identical to pre-#416)"
else
  bad "TC-AUTH-010: default unset did NOT FATAL against the REAL segment — regression!"
fi
assert_contains "TC-AUTH-010: FATAL message present" "FATAL" "$out"

# ===========================================================================
echo "=== TC-AUTH-011..014: REAL wrapper startup segments (autonomous-{dev,review}.sh) — P1-2 ==="
# ===========================================================================
# [P1-2] Codex found the pre-fix code checked `GH_AUTH_MODE=app + require App
# creds` at autonomous-dev.sh:~170 and autonomous-review.sh:~389 BEFORE the
# gated setup_github_auth ran — so gitlab/gitlab still FATALed at the
# wrapper level. Post-fix, both wrappers wrap the whole auth block in
# `if github_seam_active; then …; fi`. Drive the REAL blocks (extracted
# from the FILEs, not copied) under both topologies.
DEV_SH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REVIEW_SH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

_extract_wrapper_auth_block() {
  local sh="$1"
  # Grab from `if github_seam_active; then` to the OUTER `fi` (the one
  # ending the whole gated block).
  awk '
    /^if github_seam_active; then$/ { grab=1; depth=1; print; next }
    grab {
      print
      # Track nesting so we stop at the OUTER fi. Only lines that are a
      # bare `if …; then` or bare `fi` shift depth.
      if ($0 ~ /^[[:space:]]*if [^;]*; then$|^[[:space:]]*if [[]/) depth++
      if ($0 ~ /^[[:space:]]*fi$/) { depth--; if (depth==0) exit }
    }
  ' "$sh"
}

DEV_BLOCK=$(_extract_wrapper_auth_block "$DEV_SH")
REVIEW_BLOCK=$(_extract_wrapper_auth_block "$REVIEW_SH")
[[ -n "$DEV_BLOCK" ]]    || bad "TC-AUTH-011: could not extract auth block from autonomous-dev.sh"
[[ -n "$REVIEW_BLOCK" ]] || bad "TC-AUTH-013: could not extract auth block from autonomous-review.sh"

_drive_wrapper_block() {
  local block="$1" ip="$2" ch="$3" mode="${4:-app}"
  local driver="$WORK/drive-wrapper.sh"
  cat > "$driver" <<DRV
# Stubs for wrapper-scope symbols the extracted block references.
error_surface() { echo "[stub error_surface] \$@" >&2; }
ISSUE_NUMBER=42
source "$LIB_AUTH"
$block
echo "no-fatal-reached"
exit 0
DRV
  env -u PROJECT_DIR PATH="$PATH" \
      ISSUE_PROVIDER="$ip" CODE_HOST="$ch" GH_AUTH_MODE="$mode" \
      AUTONOMOUS_CONF_DIR="$FAKE_PROJECT_DIR" \
      REPO="test/repo" REPO_OWNER="test" REPO_NAME="repo" \
      DEV_AGENT_APP_ID="" DEV_AGENT_APP_PEM="" \
      REVIEW_AGENT_APP_ID="" REVIEW_AGENT_APP_PEM="" \
      bash "$driver"
}

# TC-AUTH-011: autonomous-dev.sh REAL block, gitlab/gitlab app-mode → NO FATAL.
out=$(_drive_wrapper_block "$DEV_BLOCK" gitlab gitlab app 2>&1); rc=$?
assert_eq "TC-AUTH-011: autonomous-dev.sh REAL block on gitlab/gitlab app-mode → rc 0" "0" "$rc"
assert_contains "TC-AUTH-011: dev-wrapper block reaches past the gate" "no-fatal-reached" "$out"
assert_not_contains "TC-AUTH-011: no DEV_AGENT_APP_ID FATAL on gitlab/gitlab" "requires DEV_AGENT_APP_ID" "$out"

# TC-AUTH-012: autonomous-dev.sh REAL block, github/gitlab mixed app-mode → FATAL.
out=$(_drive_wrapper_block "$DEV_BLOCK" github gitlab app 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "TC-AUTH-012: autonomous-dev.sh github/gitlab mixed → real block FATAL (rc 1)"
else
  bad "TC-AUTH-012: github/gitlab mixed did NOT FATAL (rc $rc)"
fi
assert_contains "TC-AUTH-012: FATAL message names DEV_AGENT_APP_ID" "DEV_AGENT_APP_ID" "$out"

# TC-AUTH-013: autonomous-review.sh REAL block, gitlab/gitlab app-mode → NO FATAL.
out=$(_drive_wrapper_block "$REVIEW_BLOCK" gitlab gitlab app 2>&1); rc=$?
assert_eq "TC-AUTH-013: autonomous-review.sh REAL block on gitlab/gitlab app-mode → rc 0" "0" "$rc"
assert_contains "TC-AUTH-013: review-wrapper block reaches past the gate" "no-fatal-reached" "$out"
assert_not_contains "TC-AUTH-013: no REVIEW_AGENT_APP_ID FATAL on gitlab/gitlab" "requires REVIEW_AGENT_APP_ID" "$out"

# TC-AUTH-014: autonomous-review.sh REAL block, github/gitlab mixed app-mode → FATAL.
out=$(_drive_wrapper_block "$REVIEW_BLOCK" github gitlab app 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "TC-AUTH-014: autonomous-review.sh github/gitlab mixed → real block FATAL"
else
  bad "TC-AUTH-014: review github/gitlab mixed did NOT FATAL"
fi
assert_contains "TC-AUTH-014: FATAL message names REVIEW_AGENT_APP_ID" "REVIEW_AGENT_APP_ID" "$out"

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
