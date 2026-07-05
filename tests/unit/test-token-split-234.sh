#!/bin/bash
# test-token-split-234.sh — Unit tests for INV-79 (issue #234).
#
# Two-token split + agent env scrubbing. Asserts:
#   - get_gh_app_token / get_gh_app_scoped_token build the access-token request
#     body with a scoped `permissions` object + single-repo `repositories` array.
#   - gh-token-refresh-daemon.sh forwards the optional 6th permissions arg.
#   - setup_agent_token mints the scoped token (app mode) / no-ops + WARNs (PAT).
#   - build_agent_env_argv emits the scrub prefix (scoped) / empty (no scope).
#   - the scrub KEEPS PATH intact (the agent's bare gh shim must stay resolvable)
#     while still unsetting GH_TOKEN_FILE / PAT vars (#234 review [P1]).
#   - _run_with_timeout runs a stub agent under the scrub prefix → env dump shows
#     scoped GH_TOKEN + NO full-write credential (the verify-by-construction gate).
#   - drain_agent_pr_create brokers `gh pr create` only when scoping is armed.
#
# Run: bash tests/unit/test-token-split-234.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

TMPROOT=$(mktemp -d)
# [Lane-GC PR-1] Kill any stub daemon (or its watchdog) still running out of
# TMPROOT before removing it — a backstop for the per-test cleanup_github_auth
# calls below, in case a test is interrupted (SIGTERM/SIGKILL on this harness
# itself) before its own kill+wait runs.
trap 'pkill -f "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-TOKEN-SPLIT-001: _build_access_token_body embeds scoped permissions + single repo ==="
# ---------------------------------------------------------------------------
body=$(bash -c "source '$SCRIPTS/gh-app-token.sh'; _build_access_token_body 'myrepo' '{\"contents\":\"write\",\"issues\":\"write\",\"pull_requests\":\"read\"}'")
if printf '%s' "$body" | grep -qF '"repositories":["myrepo"]' \
   && printf '%s' "$body" | grep -qF '"pull_requests":"read"' \
   && printf '%s' "$body" | grep -qF '"contents":"write"' \
   && printf '%s' "$body" | grep -qF '"issues":"write"'; then
  assert_pass "scoped body has repositories + the exact permissions object: $body"
else
  assert_fail "scoped body missing repo/permissions: $body"
fi

# Full-grant body (no permissions arg) is the pre-INV-79 shape (no permissions key).
body_full=$(bash -c "source '$SCRIPTS/gh-app-token.sh'; _build_access_token_body 'myrepo' ''")
if [[ "$body_full" == '{"repositories":["myrepo"]}' ]]; then
  assert_pass "full-grant body unchanged (no permissions key): $body_full"
else
  assert_fail "full-grant body changed shape: $body_full"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-003: malformed permissions object is rejected (fail-closed) ==="
# ---------------------------------------------------------------------------
# A value outside {read,write,admin} must be rejected.
if bash -c "source '$SCRIPTS/gh-app-token.sh'; _build_access_token_body 'r' '{\"contents\":\"superuser\"}'" >/dev/null 2>&1; then
  assert_fail "invalid permission value 'superuser' was NOT rejected"
else
  assert_pass "invalid permission value rejected (returns non-zero)"
fi
# An injection attempt (non-object) must be rejected.
if bash -c "source '$SCRIPTS/gh-app-token.sh'; _build_access_token_body 'r' '\"}],\"x\":1'" >/dev/null 2>&1; then
  assert_fail "non-object permissions was NOT rejected"
else
  assert_pass "non-object/injection permissions rejected"
fi
# get_gh_app_scoped_token requires the permissions arg.
if bash -c "source '$SCRIPTS/gh-app-token.sh'; get_gh_app_scoped_token a b c d ''" >/dev/null 2>&1; then
  assert_fail "get_gh_app_scoped_token accepted an empty permissions arg"
else
  assert_pass "get_gh_app_scoped_token requires a non-empty permissions arg"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-002: gh-token-refresh-daemon.sh forwards the 6th permissions arg to the mint ==="
# ---------------------------------------------------------------------------
# Sandbox: copy the daemon + a STUB gh-app-token.sh whose get_gh_app_token echoes
# its 5th arg (permissions) into a sentinel file, then exits so the daemon writes
# the "token" and we can inspect what permissions were passed.
DSB="$TMPROOT/daemon-sb"; mkdir -p "$DSB"
cp "$SCRIPTS/gh-token-refresh-daemon.sh" "$DSB/"
PERMS_SEEN="$DSB/perms-seen.txt"
cat > "$DSB/gh-app-token.sh" <<STUB
#!/bin/bash
get_gh_app_token() {
  # \$5 is the permissions arg ([INV-79]).
  printf '%s' "\${5:-<none>}" > "$PERMS_SEEN"
  echo "stub-token-value"
}
STUB
# Run the daemon with a huge refresh interval so it writes the initial token and
# then sleeps; kill it right after the token file appears.
TOKFILE="$DSB/agent-token"
GH_TOKEN_REFRESH_INTERVAL=99999 bash "$DSB/gh-token-refresh-daemon.sh" \
  "$TOKFILE" "12345" "/nonexistent.pem" "owner" "repo" \
  '{"contents":"write","issues":"write","pull_requests":"read"}' >/dev/null 2>&1 &
DPID=$!
# Poll for the token file (initial write), bounded.
for _ in $(seq 1 20); do [[ -s "$TOKFILE" ]] && break; sleep 0.2; done
kill "$DPID" 2>/dev/null || true
wait "$DPID" 2>/dev/null || true
seen=$(cat "$PERMS_SEEN" 2>/dev/null || echo "")
if [[ "$seen" == '{"contents":"write","issues":"write","pull_requests":"read"}' ]]; then
  assert_pass "daemon forwarded the permissions JSON to the mint: $seen"
else
  assert_fail "daemon did NOT forward the permissions JSON (saw: '$seen')"
fi

# ---------------------------------------------------------------------------
# Shared lib-auth sandbox builder (mirrors test-lib-auth-gh-symlink.sh).
# ---------------------------------------------------------------------------
# [#296 B3, #308] copy_chp_seam <dir> — materialize the CHP seam (lib-code-host.sh
# + the github provider) alongside a copied lib-auth.sh so its self-source (readlink
# -f → this dir) DEFINES chp_pr_list. The migrated drain_agent_pr_create /
# drain_agent_bot_triggers PR-existence reads route through chp_pr_list; without the
# seam the call fails-soft to "0"/empty (undefined verb + `|| echo 0`/`|| true`) — a
# SILENT behavior change a crash-expecting test would miss (AC5). With the seam,
# chp_pr_list → chp_github_pr_list → `gh pr list`, which the recording stub on PATH
# observes. Every inline lib-auth.sh sandbox in this file calls this.
copy_chp_seam() {
  local d="$1"
  cp "$SCRIPTS/lib-code-host.sh" "$d/lib-code-host.sh"
  mkdir -p "$d/providers"
  cp "$SCRIPTS/providers/chp-github.sh" "$d/providers/chp-github.sh"
  cp "$SCRIPTS/providers/chp-github.caps" "$d/providers/chp-github.caps" 2>/dev/null || true
}

new_auth_sandbox() {
  local d; d=$(mktemp -d "$TMPROOT/auth-XXXXXX")
  cp "$SCRIPTS/lib-auth.sh" "$d/lib-auth.sh"
  cp "$SCRIPTS/gh-with-token-refresh.sh" "$d/gh-with-token-refresh.sh"
  chmod +x "$d/gh-with-token-refresh.sh"
  copy_chp_seam "$d"
  cat > "$d/lib-config.sh" <<'CFG'
#!/bin/bash
load_autonomous_conf() { return 0; }
CFG
  # Stub gh-app-token.sh: get_gh_app_token echoes a deterministic scoped token.
  cat > "$d/gh-app-token.sh" <<'GAT'
#!/bin/bash
get_gh_app_token() { echo "SCOPED-TOKEN-abc123"; }
get_gh_app_scoped_token() { echo "SCOPED-TOKEN-abc123"; }
GAT
  # Stub daemon: write the (stub) token immediately, then idle behind a PPID
  # watchdog (Lane-GC PR-1) instead of `sleep 99999` — a group-killed test run
  # (the harness's own subshell dying under SIGTERM/SIGKILL) previously orphaned
  # this sleep for up to 99999s; the watchdog self-expires within 5s of the
  # parent dying.
  cat > "$d/gh-token-refresh-daemon.sh" <<'DAEMON'
#!/bin/bash
echo "SCOPED-TOKEN-abc123" > "$1"
while kill -0 "$PPID" 2>/dev/null; do sleep 5; done
DAEMON
  echo "$d"
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-020/021: PAT mode — setup_agent_token no-ops + WARNs once ==="
# ---------------------------------------------------------------------------
SBP=$(new_auth_sandbox)
out_pat=$(GH_TOKEN="dummy" bash -c "
  source '$SBP/lib-auth.sh'
  GH_AUTH_MODE='token'
  setup_agent_token 2>&1
  setup_agent_token 2>&1   # second call must NOT re-WARN
  echo \"AGENT_FILE=[\${AGENT_GH_TOKEN_FILE:-}]\"
  echo \"AGENT_DAEMON=[\${AGENT_TOKEN_DAEMON_PID:-}]\"
")
warn_count=$(printf '%s\n' "$out_pat" | grep -c "enforcement degraded to convention in PAT mode" || true)
if [[ "$warn_count" -eq 1 ]]; then
  assert_pass "PAT mode WARNs exactly once across two setup_agent_token calls"
else
  assert_fail "PAT WARN count != 1 (got $warn_count)"
fi
if printf '%s\n' "$out_pat" | grep -q 'AGENT_FILE=\[\]' && printf '%s\n' "$out_pat" | grep -q 'AGENT_DAEMON=\[\]'; then
  assert_pass "PAT mode: no scoped token file, no daemon (byte-identical degradation)"
else
  assert_fail "PAT mode armed a scoped token/daemon (should be no-op): $out_pat"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-022/033: PAT mode — build_agent_env_argv emits an EMPTY prefix ==="
# ---------------------------------------------------------------------------
len_pat=$(GH_TOKEN="dummy" bash -c "
  source '$SBP/lib-auth.sh'
  GH_AUTH_MODE='token'
  setup_agent_token >/dev/null 2>&1
  declare -a pfx=()
  build_agent_env_argv pfx
  echo \${#pfx[@]}
")
if [[ "$len_pat" == "0" ]]; then
  assert_pass "PAT mode: build_agent_env_argv prefix length 0 (no scrub)"
else
  assert_fail "PAT mode prefix length != 0 (got $len_pat)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-010/011/030/031/032: app mode — scoped token + scrub prefix ==="
# ---------------------------------------------------------------------------
SBA=$(new_auth_sandbox)
# Run setup_github_auth (app) then setup_agent_token, then dump the env prefix and
# state. We export GH_USER_PAT so the scrub's `-u GH_USER_PAT` is observable.
mapfile -t out_app < <(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  GH_USER_PAT="fullpat" REPO_OWNER="owner" REPO_NAME="repo" bash -c "
  source '$SBA/lib-auth.sh'
  GH_AUTH_MODE='app'
  setup_github_auth '12345' '/nonexistent.pem' >/dev/null 2>&1
  setup_agent_token '12345' '/nonexistent.pem' >/dev/null 2>&1
  echo \"AGENT_FILE=\${AGENT_GH_TOKEN_FILE:-}\"
  echo \"AGENT_FILE_UNDER_WRAPPER=\$([[ \"\${AGENT_GH_TOKEN_FILE:-}\" == \"\${GH_WRAPPER_DIR:-XX}\"/* ]] && echo yes || echo no)\"
  declare -a pfx=()
  build_agent_env_argv pfx
  echo \"PFXLEN=\${#pfx[@]}\"
  printf 'PFX=%s\n' \"\${pfx[*]}\"
  cleanup_github_auth >/dev/null 2>&1
")
agent_file=""; under=""; pfxlen=""; pfx=""
for kv in "${out_app[@]}"; do
  case "$kv" in
    AGENT_FILE=*) agent_file="${kv#AGENT_FILE=}" ;;
    AGENT_FILE_UNDER_WRAPPER=*) under="${kv#AGENT_FILE_UNDER_WRAPPER=}" ;;
    PFXLEN=*) pfxlen="${kv#PFXLEN=}" ;;
    PFX=*) pfx="${kv#PFX=}" ;;
  esac
done
[[ -n "$agent_file" ]] && assert_pass "app mode: AGENT_GH_TOKEN_FILE is set ($agent_file)" \
                       || assert_fail "app mode: AGENT_GH_TOKEN_FILE empty"
[[ "$under" == "yes" ]] && assert_pass "scoped token file lives under the per-run GH_WRAPPER_DIR" \
                        || assert_fail "scoped token file NOT under GH_WRAPPER_DIR"
[[ "$pfxlen" -gt 0 ]] && assert_pass "app mode: build_agent_env_argv emits a non-empty scrub prefix (len=$pfxlen)" \
                      || assert_fail "app mode scrub prefix empty"
if printf '%s' "$pfx" | grep -qF 'GH_TOKEN=SCOPED-TOKEN-abc123'; then
  assert_pass "scrub prefix sets GH_TOKEN to the SCOPED token (snapshot fallback)"
else
  assert_fail "scrub prefix missing scoped GH_TOKEN: $pfx"
fi
# #234 review [P1]: GH_TOKEN_FILE must be POINTED AT the scoped file (refresh-aware),
# NOT unset — else the agent's gh goes stale after the 1h App-token TTL. The value
# must equal AGENT_GH_TOKEN_FILE (the scoped file, under GH_WRAPPER_DIR).
if printf '%s' "$pfx" | grep -qF "GH_TOKEN_FILE=${agent_file}" \
   && ! printf '%s' "$pfx" | grep -qF -- '-u GH_TOKEN_FILE'; then
  assert_pass "scrub prefix points GH_TOKEN_FILE at the scoped file (refresh-aware), does NOT unset it"
else
  assert_fail "scrub prefix does not point GH_TOKEN_FILE at the scoped file (stale-token [P1] regression): $pfx"
fi
if printf '%s' "$pfx" | grep -qF -- '-u GITHUB_PERSONAL_ACCESS_TOKEN'; then
  assert_pass "scrub prefix unsets GITHUB_PERSONAL_ACCESS_TOKEN (the App-token alias)"
else
  assert_fail "scrub prefix missing -u GITHUB_PERSONAL_ACCESS_TOKEN: $pfx"
fi
# #234 review [P1] (f97959a3): GH_USER_PAT MUST be unset — a scoped agent retaining
# it could `export GH_TOKEN=$GH_USER_PAT` and regain approve/merge. Bot triggers are
# brokered through the wrapper instead (drain_agent_bot_triggers).
if printf '%s' "$pfx" | grep -qF -- '-u GH_USER_PAT'; then
  assert_pass "scrub prefix unsets GH_USER_PAT (agent can't regain the PAT's approve/merge; bot triggers brokered)"
else
  assert_fail "scrub prefix does NOT unset GH_USER_PAT — a scoped agent could regain approve/merge ([P1] regression): $pfx"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-032: scrub PATH= swaps the WRAPPER shim dir for the AGENT-own shim dir (#234 AC#1) ==="
# ---------------------------------------------------------------------------
# The prefix MUST carry a PATH= element that (a) does NOT contain the wrapper's
# GH_WRAPPER_DIR (AC#1 — no wrapper shim), (b) prepends the AGENT's own shim dir
# (so bare `gh` still resolves), preserving the other PATH segments.
mapfile -t out32 < <(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR -u GH_TOKEN_FILE -u GH_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_USER_PAT \
  PATH="/usr/bin:/bin" bash -c "
  source '$SBA/lib-auth.sh'
  wdir=\$(mktemp -d /tmp/agent-auth-XXXXXX); export GH_WRAPPER_DIR=\"\$wdir\"; export PATH=\"\$wdir:\$PATH\"
  AGENT_GH_TOKEN_FILE=\"\$wdir/agent-token\"; echo 'tok' > \"\$AGENT_GH_TOKEN_FILE\"
  AGENT_GH_SHIM_DIR=\$(mktemp -d /tmp/agent-shim-XXXXXX)
  declare -a p=(); build_agent_env_argv p
  echo \"WDIR=\$wdir\"; echo \"SHIM=\$AGENT_GH_SHIM_DIR\"
  printf 'PATHEL=%s\n' \"\$(printf '%s\n' \"\${p[@]}\" | grep '^PATH=')\"
  rm -rf \"\$wdir\" \"\$AGENT_GH_SHIM_DIR\"
")
w32=""; s32=""; pathel32=""
for kv in "${out32[@]}"; do
  case "$kv" in
    WDIR=*) w32="${kv#WDIR=}" ;;
    SHIM=*) s32="${kv#SHIM=}" ;;
    PATHEL=*) pathel32="${kv#PATHEL=}" ;;
  esac
done
if [[ -n "$pathel32" ]] && ! printf '%s' "$pathel32" | grep -qF "$w32"; then
  assert_pass "scrub PATH= excludes the wrapper's GH_WRAPPER_DIR ($w32) — AC#1 no-wrapper-shim"
else
  assert_fail "scrub PATH= still contains the wrapper dir ($w32): $pathel32"
fi
if printf '%s' "$pathel32" | grep -qF "PATH=${s32}:"; then
  assert_pass "scrub PATH= PREPENDS the agent-own shim dir ($s32) — bare gh resolves"
else
  assert_fail "scrub PATH= does not prepend the agent-own shim dir ($s32): $pathel32"
fi
# Source-level lockdown: build_agent_env_argv MUST emit a PATH= element (the swap),
# and _strip_path_entry MUST exist (used for the swap).
if grep -q '_strip_path_entry' "$SCRIPTS/lib-auth.sh"; then
  assert_pass "source: _strip_path_entry present (used to strip the wrapper dir)"
else
  assert_fail "source: _strip_path_entry missing — the PATH swap cannot strip the wrapper dir"
fi
if awk '/^build_agent_env_argv\(\)/,/^}/' "$SCRIPTS/lib-auth.sh" | grep -q 'PATH=\${AGENT_GH_SHIM_DIR}'; then
  assert_pass "source: build_agent_env_argv emits the agent-shim PATH= swap"
else
  assert_fail "source: build_agent_env_argv does not emit the agent-shim PATH= swap"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-040: scrub completeness via _run_with_timeout (env-dump gate) ==="
# ---------------------------------------------------------------------------
# Source lib-auth (for build_agent_env_argv) + lib-agent (for _run_with_timeout),
# arm a scoped token by hand (write a token file + point AGENT_GH_TOKEN_FILE at
# it + set GH_WRAPPER_DIR onto PATH), then run a stub "agent" (env) under
# _run_with_timeout and assert the dump.
ENVDUMP="$TMPROOT/envdump.txt"
WDIR_SENTINEL="$TMPROOT/wdir-used.txt"
SHIM_SENTINEL="$TMPROOT/shim-used.txt"
# Scrub the live-wrapper env contamination (AUTONOMOUS_CONF_DIR / inherited PATH
# GH_WRAPPER_DIR / credential vars) so the dump reflects only what THIS test sets
# — mirrors the CI-equivalent clean env (see feedback_unit_test_env_contamination).
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR -u GH_TOKEN_FILE -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_USER_PAT \
  PATH="/usr/bin:/bin" \
  bash -c "
  GH_USER_PAT='fullpat' GH_TOKEN_FILE='/tmp/full-token-file' GITHUB_PERSONAL_ACCESS_TOKEN='fulltoken'
  source '$SBA/lib-config.sh' 2>/dev/null || true
  source '$SBA/lib-auth.sh'
  AGENT_CMD=env
  AGENT_TIMEOUT=10
  AGENT_PERMISSION_MODE=auto
  declare -a AGENT_LAUNCHER_ARGV=()
  source '$SCRIPTS/lib-agent.sh' >/dev/null 2>&1 || true
  # Arm a scoped token by hand.
  wdir=\$(mktemp -d /tmp/agent-auth-XXXXXX)
  printf '%s' \"\$wdir\" > '$WDIR_SENTINEL'
  export PATH=\"\$wdir:\$PATH\"
  export GH_WRAPPER_DIR=\"\$wdir\"
  export GH_TOKEN_FILE='/tmp/full-token-file'
  export GITHUB_PERSONAL_ACCESS_TOKEN='fulltoken'
  export GH_USER_PAT='fullpat'
  AGENT_GH_TOKEN_FILE=\"\$wdir/agent-token\"
  echo 'SCOPED-TOKEN-zzz' > \"\$AGENT_GH_TOKEN_FILE\"
  # Create the AGENT's OWN shim dir (mirror setup_agent_token's tail) so the PATH
  # rewrite swaps the wrapper dir for the agent-shim dir.
  AGENT_GH_SHIM_DIR=\$(mktemp -d /tmp/agent-shim-XXXXXX)
  printf '%s' \"\$AGENT_GH_SHIM_DIR\" > '$SHIM_SENTINEL'
  # Run the stub agent (env) under the timeout wrapper; capture its env dump.
  _run_with_timeout env > '$ENVDUMP' 2>/dev/null
  rm -rf \"\$wdir\" \"\$AGENT_GH_SHIM_DIR\"
" >/dev/null 2>&1
WDIR_USED=$(cat "$WDIR_SENTINEL" 2>/dev/null || echo "/tmp/agent-auth-NONE")
SHIM_USED=$(cat "$SHIM_SENTINEL" 2>/dev/null || echo "/tmp/agent-shim-NONE")
gh_token_line=$(grep -E '^GH_TOKEN=' "$ENVDUMP" 2>/dev/null || true)
if [[ "$gh_token_line" == "GH_TOKEN=SCOPED-TOKEN-zzz" ]]; then
  assert_pass "agent env GH_TOKEN is the SCOPED token"
else
  assert_fail "agent env GH_TOKEN not scoped (got: '$gh_token_line')"
fi
# #234 review [P1]: GH_TOKEN_FILE must point at the SCOPED file (refresh-aware),
# NOT the wrapper's full-write file (/tmp/full-token-file) and NOT be unset.
gh_token_file_line=$(grep -E '^GH_TOKEN_FILE=' "$ENVDUMP" 2>/dev/null || true)
if [[ "$gh_token_file_line" == "GH_TOKEN_FILE=${WDIR_USED}/agent-token" ]]; then
  assert_pass "agent env GH_TOKEN_FILE points at the SCOPED file (refresh-aware): $gh_token_file_line"
elif [[ "$gh_token_file_line" == "GH_TOKEN_FILE=/tmp/full-token-file" ]]; then
  assert_fail "agent env GH_TOKEN_FILE still points at the WRAPPER's full-write file — credential leak!"
else
  assert_fail "agent env GH_TOKEN_FILE is wrong (not the scoped file): '$gh_token_file_line'"
fi
if ! grep -qE '^GITHUB_PERSONAL_ACCESS_TOKEN=' "$ENVDUMP" 2>/dev/null; then
  assert_pass "agent env has NO GITHUB_PERSONAL_ACCESS_TOKEN (scrubbed)"
else
  assert_fail "agent env still carries GITHUB_PERSONAL_ACCESS_TOKEN — scrub incomplete"
fi
# #234 review [P1] (f97959a3): GH_USER_PAT is SCRUBBED — a scoped agent retaining it
# could regain approve/merge. The harness exported GH_USER_PAT=fullpat; it must be
# gone from the agent dump. Bot triggers are brokered through the wrapper instead.
if ! grep -qE '^GH_USER_PAT=' "$ENVDUMP" 2>/dev/null; then
  assert_pass "agent env has NO GH_USER_PAT (scrubbed — agent can't regain the PAT's approve/merge)"
else
  assert_fail "agent env still carries GH_USER_PAT — a scoped agent could regain approve/merge ([P1] regression)"
fi
# #234 review [P1] (AC #1 — "no wrapper gh shim"): the agent PATH must NOT carry the
# WRAPPER's GH_WRAPPER_DIR; it must carry the AGENT's OWN shim dir instead, so bare
# `gh` still resolves WITHOUT the wrapper shim being exposed.
path_line=$(grep -E '^PATH=' "$ENVDUMP" 2>/dev/null || true)
if ! printf '%s' "$path_line" | grep -qF "$WDIR_USED"; then
  assert_pass "agent PATH does NOT carry the wrapper's GH_WRAPPER_DIR ($WDIR_USED) — AC#1 no-wrapper-shim met"
else
  assert_fail "agent PATH still carries the WRAPPER shim dir ($WDIR_USED) — AC#1 violated: $path_line"
fi
if printf '%s' "$path_line" | grep -qF "$SHIM_USED"; then
  assert_pass "agent PATH carries the AGENT's OWN shim dir ($SHIM_USED) — bare gh stays resolvable"
else
  assert_fail "agent PATH lost the agent-own shim dir ($SHIM_USED) — bare gh would break on REAL_GH hosts: $path_line"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-041: no scoped token → _run_with_timeout does NOT scrub ==="
# ---------------------------------------------------------------------------
# lib-auth.sh resets GH_TOKEN_FILE at source time, so we cannot assert on an
# INHERITED full-write var surviving. Instead assert the real no-regression
# contract: with no scoped token, build_agent_env_argv emits NO `env` prefix, so
# the agent runs with whatever env the WRAPPER set — proven by exporting a
# sentinel (FULL_CREDENTIAL_SENTINEL) that must appear UNCHANGED in the dump
# (a scrub prefix would not touch it, but its presence confirms no `env -u`
# rewrite of the agent's env occurred and GH_TOKEN was NOT overridden).
ENVDUMP2="$TMPROOT/envdump2.txt"
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="/usr/bin:/bin" bash -c "
  source '$SBA/lib-auth.sh'
  AGENT_CMD=env; AGENT_TIMEOUT=10; AGENT_PERMISSION_MODE=auto
  declare -a AGENT_LAUNCHER_ARGV=()
  source '$SCRIPTS/lib-agent.sh' >/dev/null 2>&1 || true
  # No scoped token armed (AGENT_GH_TOKEN_FILE stays empty).
  export FULL_CREDENTIAL_SENTINEL='wrapper-full-token'
  export GH_TOKEN='wrapper-full-token'
  declare -a p=(); build_agent_env_argv p; echo \"PFXLEN=\${#p[@]}\" > '$TMPROOT/noscope-pfxlen.txt'
  _run_with_timeout env > '$ENVDUMP2' 2>/dev/null
" >/dev/null 2>&1
noscope_pfxlen=$(sed -n 's/^PFXLEN=//p' "$TMPROOT/noscope-pfxlen.txt" 2>/dev/null || echo "?")
if [[ "$noscope_pfxlen" == "0" ]] \
   && grep -qE '^FULL_CREDENTIAL_SENTINEL=wrapper-full-token' "$ENVDUMP2" 2>/dev/null \
   && grep -qE '^GH_TOKEN=wrapper-full-token' "$ENVDUMP2" 2>/dev/null; then
  assert_pass "no-scope: empty prefix + agent inherits the wrapper's GH_TOKEN unchanged (no scrub, no regression)"
else
  assert_fail "no-scope: scrub fired or GH_TOKEN overridden without a scoped token (pfxlen=$noscope_pfxlen, regression!)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-090: scrub runs the LAUNCHER under the scrubbed env (env prefix BEFORE launcher) ==="
# ---------------------------------------------------------------------------
# #234 review [P1] #1: the env-scrub `env …` prefix MUST come BEFORE
# AGENT_LAUNCHER_ARGV. A launcher is an argv prefix that EXECs the real CLI with
# its trailing args (`cc "$@"`), so a scrub placed AFTER the launcher is handed
# to the launcher as positional `$@` and forwarded to the CLI as LITERAL args —
# `env` never runs and the scrub no-ops. We model the launcher with a real stub
# script that EXECs "$@", set it as AGENT_LAUNCHER_ARGV, run a stub "agent" (env)
# through _run_with_timeout with a scoped token armed, and assert the dumped env
# is SCRUBBED (scoped GH_TOKEN, no full-write creds). If the prefix were after
# the launcher, the launcher would receive `env -u … env` as args, exec the inner
# `env` (the agent) WITHOUT applying the scrub, and the dump would still carry the
# full-write credential — the exact regression this pins.
ENVDUMP3="$TMPROOT/envdump3.txt"
LAUNCHSB="$TMPROOT/launcher-stub"; mkdir -p "$LAUNCHSB"
# Model the REAL launcher contract: `cc` ends in `$CLAUDE_CMD "$@"` — it execs a
# FIXED command (here: the agent stub `dump-env`) with the trailing argv APPENDED,
# it does NOT `exec "$@"`. This is what makes the ordering bug observable: with the
# BUGGY order (`cc env -u … GH_TOKEN=… dump-env`), the launcher receives
# `env -u … GH_TOKEN=… dump-env` as `$@` and runs `dump-env env -u … GH_TOKEN=… dump-env`
# → the agent (dump-env) runs WITHOUT the scrub applied (env is a literal arg, not
# the command). With the FIXED order (`env -u … GH_TOKEN=… cc dump-env`), `env`
# runs `cc`, which execs `dump-env` under the scrubbed environment. The agent stub
# `dump-env` writes its OWN environment so we can assert the scrub took effect.
cat > "$LAUNCHSB/dump-env" <<DUMP
#!/bin/bash
env > '$ENVDUMP3'
DUMP
chmod +x "$LAUNCHSB/dump-env"
cat > "$LAUNCHSB/cc-stub" <<LAUNCH
#!/bin/bash
# Fixed command + appended args — the real \`cc\`/\`claude "\$@"\` shape.
exec '$LAUNCHSB/dump-env' "\$@"
LAUNCH
chmod +x "$LAUNCHSB/cc-stub"
: > "$ENVDUMP3"
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR -u GH_TOKEN_FILE -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_USER_PAT \
  PATH="/usr/bin:/bin" \
  bash -c "
  source '$SBA/lib-auth.sh'
  # AGENT_CMD is a no-op placeholder here — the launcher execs the fixed dump-env,
  # ignoring its trailing args; we only care WHICH env dump-env runs under.
  AGENT_CMD=true; AGENT_TIMEOUT=10; AGENT_PERMISSION_MODE=auto
  source '$SCRIPTS/lib-agent.sh' >/dev/null 2>&1 || true
  # Set AGENT_LAUNCHER_ARGV AFTER sourcing — lib-agent.sh resets it at source time
  # (it derives the per-side arrays from AGENT_LAUNCHER), and the wrappers rebind
  # AGENT_LAUNCHER_ARGV post-source. We mirror that rebind here.
  declare -a AGENT_LAUNCHER_ARGV=('$LAUNCHSB/cc-stub')
  wdir=\$(mktemp -d /tmp/agent-auth-XXXXXX)
  export PATH=\"\$wdir:\$PATH\"
  export GH_WRAPPER_DIR=\"\$wdir\"
  export GH_TOKEN_FILE='/tmp/full-token-file'
  export GITHUB_PERSONAL_ACCESS_TOKEN='fulltoken'
  AGENT_GH_TOKEN_FILE=\"\$wdir/agent-token\"
  echo 'SCOPED-TOKEN-launcher' > \"\$AGENT_GH_TOKEN_FILE\"
  _run_with_timeout true >/dev/null 2>&1
  rm -rf \"\$wdir\"
" >/dev/null 2>&1
# Scrub APPLIED iff: GH_TOKEN=scoped AND no full-write leaks — i.e.
# GITHUB_PERSONAL_ACCESS_TOKEN absent AND GH_TOKEN_FILE is NOT the wrapper's
# full-write file (/tmp/full-token-file). GH_TOKEN_FILE IS now set (to the scoped
# file, refresh-aware), so we assert its VALUE is not the full-write path rather
# than its absence. If the env prefix were passed to the launcher as args (the
# [P1] #1 regression), GH_TOKEN would be empty and the full-write GH_TOKEN_FILE
# would survive — both caught here.
if grep -qE '^GH_TOKEN=SCOPED-TOKEN-launcher' "$ENVDUMP3" 2>/dev/null \
   && ! grep -qE '^GH_TOKEN_FILE=/tmp/full-token-file' "$ENVDUMP3" 2>/dev/null \
   && ! grep -qE '^GITHUB_PERSONAL_ACCESS_TOKEN=' "$ENVDUMP3" 2>/dev/null; then
  assert_pass "launcher present: scrub APPLIED (scoped GH_TOKEN, no full-write creds) — env prefix runs the launcher, not passed through"
else
  assert_fail "launcher present: scrub NOT applied (env prefix passed to launcher as args — the #234 [P1] #1 regression). Dump GH_TOKEN=$(grep -E '^GH_TOKEN=' "$ENVDUMP3" 2>/dev/null), GH_TOKEN_FILE=$(grep -E '^GH_TOKEN_FILE=' "$ENVDUMP3" 2>/dev/null)"
fi
# Source-level lockdown: the env prefix MUST precede AGENT_LAUNCHER_ARGV in the
# cmd assembly (guards against a future reorder reintroducing the bug).
if grep -qE '_agent_env_prefix\[@\]\}".*\$\{AGENT_LAUNCHER_ARGV\[@\]\}' "$SCRIPTS/lib-agent.sh"; then
  assert_pass "source: _agent_env_prefix is assembled BEFORE AGENT_LAUNCHER_ARGV in _run_with_timeout"
else
  assert_fail "source: env-scrub prefix is NOT before the launcher in the cmd+= assembly (regression risk)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-091: open-PR fast path routes through the broker when scoping is armed ==="
# ---------------------------------------------------------------------------
# #234 review [P1] #2: emit_open_pr_fast_path_block must NOT tell the agent to run
# `gh pr create` directly when the scoped token is armed (pull_requests:read →
# 403); it must route through the AGENT_PR_CREATE_FILE broker. We source
# autonomous-dev.sh's function in isolation is impractical (it has a heavy top),
# so assert at the SOURCE level: the scoped branch emits the broker file
# instruction and NOT a bare `gh pr create`, and the unscoped branch keeps
# `gh pr create`.
DEV_SH="$SCRIPTS/autonomous-dev.sh"
# The scoped open_pr_step branch references AGENT_PR_CREATE_FILE and is gated on
# AGENT_GH_TOKEN_FILE.
if grep -q 'if \[\[ -n "\${AGENT_GH_TOKEN_FILE:-}" \]\]; then' "$DEV_SH" \
   && awk '/emit_open_pr_fast_path_block\(\)/,/^}/' "$DEV_SH" | grep -q 'AGENT_PR_CREATE_FILE'; then
  assert_pass "fast path: scoped branch routes open-PR through AGENT_PR_CREATE_FILE broker"
else
  assert_fail "fast path: scoped branch does NOT route through the broker (still bare gh pr create — [P1] #2)"
fi
# The unscoped branch still instructs a direct `gh pr create` (PAT / no-scope).
# #421: the literal text now renders via provider_prompt_fragment
# dev.pr_create_direct_step (github: "run `gh pr create` with a generated"),
# golden-pinned byte-identical by test-provider-prompts-github-golden.sh — the
# SOURCE line calls the fragment key, not the literal string.
if awk '/emit_open_pr_fast_path_block\(\)/,/^}/' "$DEV_SH" | grep -q 'provider_prompt_fragment dev\.pr_create_direct_step'; then
  assert_pass "fast path: unscoped branch keeps direct gh pr create (via provider_prompt_fragment, PAT/no-scope unchanged)"
else
  assert_fail "fast path: unscoped branch lost its direct gh pr create"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-094: PR_CREATE_BROKER_BLOCK interpolates \${ISSUE_NUMBER} (NOT a single-quoted heredoc) (#234 [P1]) ==="
# ---------------------------------------------------------------------------
# #234 review [P1]: the broker block was built with a SINGLE-QUOTED heredoc
# (`cat <<'BROKER_BLOCK'`), so the agent received the LITERAL `Closes #${ISSUE_NUMBER}`
# — GitHub won't link/auto-close and the wrapper's PR-by-#N lookup fails. The block
# MUST use an interpolating heredoc so ${ISSUE_NUMBER} expands, while keeping the
# runtime `$(printenv AGENT_PR_CREATE_FILE)` literal.
# (a) Source-level lockdown: the PR_CREATE_BROKER_BLOCK heredoc delimiter must NOT
#     be single-quoted.
if grep -qE "PR_CREATE_BROKER_BLOCK=.*cat <<'BROKER_BLOCK'" "$DEV_SH"; then
  assert_fail "PR_CREATE_BROKER_BLOCK uses a single-quoted heredoc — \${ISSUE_NUMBER} stays literal ([P1] regression)"
else
  assert_pass "source: PR_CREATE_BROKER_BLOCK does not use a single-quoted heredoc"
fi
# (b) Behavioral: extract the block's heredoc body from the source and render it
#     with ISSUE_NUMBER=234, asserting `Closes #234` (interpolated) AND the literal
#     `$(printenv AGENT_PR_CREATE_FILE)` (NOT expanded by us) both appear.
#     The PR-body close keyword now flows through ${CLOSE_KEYWORD} ([INV-87]/[M4],
#     #282 — rendered by chp_close_keyword; `chp_close_keyword 234` → `Closes #234`
#     for the GitHub default), so the wrapper computes CLOSE_KEYWORD before building
#     the block. Render with both set to mirror the wrapper's runtime environment.
broker_body=$(awk '/PR_CREATE_BROKER_BLOCK="\$\(cat <<BROKER_BLOCK/{f=1; next} f&&/^BROKER_BLOCK$/{exit} f{print}' "$DEV_SH")
if [[ -n "$broker_body" ]]; then
  rendered=$(ISSUE_NUMBER=234 CLOSE_KEYWORD='Closes #234' bash -c "cat <<BROKER_BLOCK
${broker_body}
BROKER_BLOCK
" 2>/dev/null)
  if printf '%s' "$rendered" | grep -qF 'Closes #234' \
     && ! printf '%s' "$rendered" | grep -qF 'Closes #${ISSUE_NUMBER}'; then
    assert_pass "rendered broker block interpolates Closes #234 (not the literal \${ISSUE_NUMBER})"
  else
    assert_fail "rendered broker block did NOT interpolate the issue number: $(printf '%s' "$rendered" | grep -i closes)"
  fi
  if printf '%s' "$rendered" | grep -qF '$(printenv AGENT_PR_CREATE_FILE)'; then
    assert_pass "rendered broker block keeps \$(printenv AGENT_PR_CREATE_FILE) literal (agent runs it at runtime)"
  else
    assert_fail "rendered broker block lost the literal \$(printenv AGENT_PR_CREATE_FILE)"
  fi
else
  assert_fail "could not extract the PR_CREATE_BROKER_BLOCK heredoc body from $DEV_SH (interpolating-heredoc form expected)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-092: bare gh resolves the AGENT-OWN shim → real gh with the SCOPED token; wrapper shim NOT used (#234 [P1] / AC#1) ==="
# ---------------------------------------------------------------------------
# The functional proof: with the scrub applied, the agent runs under the PATH=
# build_agent_env_argv emits (wrapper dir stripped, agent-own shim dir prepended).
# A BARE `gh` must resolve the AGENT-OWN shim (gh-with-token-refresh.sh) and exec
# real gh under the SCOPED token, reading the scoped file. We model the #92 REAL_GH
# host: a fake "real gh" prints the token + the file the shim read it from, REAL_GH
# points at it, the system bins provide bash/env, and the agent's effective PATH is
# WHATEVER build_agent_env_argv put in the PATH= element (we extract + use it). The
# wrapper shim dir must be absent from that PATH.
GHFAKE="$TMPROOT/ghfake"; mkdir -p "$GHFAKE"
cat > "$GHFAKE/fake-gh" <<'FG'
#!/bin/bash
echo "REALGH token=${GH_TOKEN:-<none>} file=${GH_TOKEN_FILE:-<unset>}"
FG
chmod +x "$GHFAKE/fake-gh"
WDIR92_SENT="$TMPROOT/wdir92.txt"
mapfile -t out92 < <(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR -u GH_TOKEN_FILE -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_USER_PAT \
  PATH="/usr/bin:/bin" bash -c "
  source '$SBA/lib-auth.sh'
  wdir=\$(mktemp -d /tmp/agent-auth-XXXXXX)
  printf '%s' \"\$wdir\" > '$WDIR92_SENT'
  export GH_WRAPPER_DIR=\"\$wdir\"; export PATH=\"\$wdir:\$PATH\"
  ln -sf '$SCRIPTS/gh-with-token-refresh.sh' \"\$wdir/gh\"
  export GH_TOKEN_FILE='/tmp/full-token-file'   # wrapper-side full-write file
  AGENT_GH_TOKEN_FILE=\"\$wdir/agent-token\"; echo 'SCOPED-92' > \"\$AGENT_GH_TOKEN_FILE\"
  # Create the AGENT-own shim (mirror setup_agent_token) so build_agent_env_argv
  # emits the PATH swap; install the shim symlink so bare gh resolves through it.
  AGENT_GH_SHIM_DIR=\$(mktemp -d /tmp/agent-shim-XXXXXX)
  ln -sf '$SCRIPTS/gh-with-token-refresh.sh' \"\$AGENT_GH_SHIM_DIR/gh\"
  echo \"SHIM92=\$AGENT_GH_SHIM_DIR\"
  declare -a p=(); build_agent_env_argv p
  # Use the PATH that build_agent_env_argv put in the prefix (the real agent PATH) —
  # but ensure the fake-gh dir is NOT on it (so the shim's REAL_GH path is exercised).
  # The prefix's env sets PATH; run a bare gh under it with REAL_GH pointing at fake-gh.
  REAL_GH='$GHFAKE/fake-gh' \"\${p[@]}\" gh whoami 2>&1
  rm -rf \"\$wdir\" \"\$AGENT_GH_SHIM_DIR\"
")
WDIR92=$(cat "$WDIR92_SENT" 2>/dev/null || echo "/tmp/none")
shim92=$(printf '%s\n' "${out92[@]}" | sed -n 's/^SHIM92=//p')
out92_str="${out92[*]}"
if printf '%s' "$out92_str" | grep -qF 'REALGH token=SCOPED-92' \
   && printf '%s' "$out92_str" | grep -qF "file=${WDIR92}/agent-token" \
   && ! printf '%s' "$out92_str" | grep -qF 'file=/tmp/full-token-file'; then
  assert_pass "bare gh (via the agent-own shim, shim92=$shim92) → real gh with the SCOPED token, reading the SCOPED file (not the wrapper's full-write file)"
else
  assert_fail "bare gh under the scrub did NOT reach real gh with the scoped token/file: $out92_str"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-093: agent's gh is REFRESH-AWARE — a daemon refresh of the scoped file is picked up (#234 [P1]) ==="
# ---------------------------------------------------------------------------
# The core of this [P1]: the agent's gh must re-read the scoped file each call so a
# scoped-daemon refresh (past the 1h App-token TTL) is honored — NOT a one-time
# GH_TOKEN snapshot. Invoke the bare gh TWICE under the same scrub prefix, rewriting
# the scoped file between calls (simulating the daemon), and assert call 2 sees the
# refreshed token.
mapfile -t out93 < <(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR -u GH_TOKEN_FILE -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_USER_PAT \
  PATH="/usr/bin:/bin" bash -c "
  source '$SBA/lib-auth.sh'
  wdir=\$(mktemp -d /tmp/agent-auth-XXXXXX)
  export GH_WRAPPER_DIR=\"\$wdir\"; export PATH=\"\$wdir:\$PATH\"
  ln -sf '$SCRIPTS/gh-with-token-refresh.sh' \"\$wdir/gh\"
  AGENT_GH_TOKEN_FILE=\"\$wdir/agent-token\"; echo 'tok-INITIAL' > \"\$AGENT_GH_TOKEN_FILE\"
  AGENT_GH_SHIM_DIR=\$(mktemp -d /tmp/agent-shim-XXXXXX)
  ln -sf '$SCRIPTS/gh-with-token-refresh.sh' \"\$AGENT_GH_SHIM_DIR/gh\"
  declare -a p=(); build_agent_env_argv p
  # Run under the PATH= the prefix emits (agent-own shim swapped in for the wrapper).
  REAL_GH='$GHFAKE/fake-gh' \"\${p[@]}\" gh a 2>&1
  echo 'tok-REFRESHED' > \"\$AGENT_GH_TOKEN_FILE\"   # simulate the scoped daemon refresh
  REAL_GH='$GHFAKE/fake-gh' \"\${p[@]}\" gh b 2>&1
  rm -rf \"\$wdir\" \"\$AGENT_GH_SHIM_DIR\"
")
out93_str="${out93[*]}"
if printf '%s' "$out93_str" | grep -qF 'token=tok-INITIAL' \
   && printf '%s' "$out93_str" | grep -qF 'token=tok-REFRESHED'; then
  assert_pass "agent gh is refresh-aware: call 1 saw tok-INITIAL, call 2 saw the refreshed tok-REFRESHED"
else
  assert_fail "agent gh did NOT pick up the refreshed scoped token (stale-snapshot [P1] regression): $out93_str"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-095: GH_USER_PAT is scrubbed from the agent; bot triggers are BROKERED through the wrapper (#234 [P1] f97959a3) ==="
# ---------------------------------------------------------------------------
# #234 review [P1] (f97959a3): preserving GH_USER_PAT let a scoped agent
# `export GH_TOKEN=$GH_USER_PAT` and regain approve/merge. So GH_USER_PAT is now
# SCRUBBED, and the agent's bot-trigger comments are BROKERED — the agent writes
# trigger phrases to AGENT_BOT_TRIGGER_FILE and the wrapper posts them via
# gh-as-user.sh (which has GH_USER_PAT only in the wrapper shell). We prove both
# HERMETICALLY (no real gh / gh-as-user.sh exec — stub them).
# (a) the agent subtree does NOT see GH_USER_PAT under the scrub:
out95=$(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR -u GH_TOKEN -u GH_TOKEN_FILE -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_USER_PAT \
  PATH="/usr/bin:/bin" bash -c "
  source '$SBA/lib-auth.sh'
  wdir=\$(mktemp -d /tmp/agent-auth-XXXXXX); export GH_WRAPPER_DIR=\"\$wdir\"; export PATH=\"\$wdir:\$PATH\"
  export GH_USER_PAT='USER-PAT-realuser'
  AGENT_GH_TOKEN_FILE=\"\$wdir/agent-token\"; echo 'SCOPED-tok' > \"\$AGENT_GH_TOKEN_FILE\"
  AGENT_GH_SHIM_DIR=\$(mktemp -d /tmp/agent-shim-XXXXXX)
  declare -a p=(); build_agent_env_argv p
  \"\${p[@]}\" bash -c 'echo \"SEEN pat=\${GH_USER_PAT:-<unset>} ppat=\${GITHUB_PERSONAL_ACCESS_TOKEN:-<unset>}\"'
  rm -rf \"\$wdir\" \"\$AGENT_GH_SHIM_DIR\"
")
if printf '%s' "$out95" | grep -qF 'SEEN pat=<unset> ppat=<unset>'; then
  assert_pass "agent subtree has NO GH_USER_PAT (scrubbed — can't regain approve/merge) nor the App-token alias"
else
  assert_fail "agent subtree still sees GH_USER_PAT / App-token alias under the scrub ([P1] regression): $out95"
fi
# (b) drain_agent_bot_triggers posts each trigger phrase via gh-as-user.sh (the
#     wrapper holds GH_USER_PAT). Stub gh (pr list → PR 42) + a stub gh-as-user.sh
#     that records its posts. No real gh / network.
SBA95="$TMPROOT/bt-sandbox"; mkdir -p "$SBA95"
cp "$SCRIPTS/lib-auth.sh" "$SBA95/"
copy_chp_seam "$SBA95"   # [#296 B3, #308] chp_pr_list for the PR-number read
printf '#!/bin/bash\nload_autonomous_conf(){ return 0; }\n' > "$SBA95/lib-config.sh"
printf '#!/bin/bash\nget_gh_app_token(){ echo X; }\nget_gh_app_scoped_token(){ echo X; }\n' > "$SBA95/gh-app-token.sh"
BT_POSTS="$TMPROOT/bt-posts.log"; : > "$BT_POSTS"
cat > "$SBA95/gh-as-user.sh" <<GAU
#!/bin/bash
printf 'GAU %s\n' "\$*" >> '$BT_POSTS'
GAU
chmod +x "$SBA95/gh-as-user.sh"
GHSB95="$TMPROOT/bt-gh"; mkdir -p "$GHSB95"
cat > "$GHSB95/gh" <<'GH'
#!/bin/bash
# W1c1 (#397): the chp_pr_list leaf now emits `gh api graphql …` (cursor
# page walk, §3.5). Return the GraphQL envelope with one PR node
# body-mentioning #234 → the caller-side selector resolves pr_number=42.
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"number":42,"body":"Closes #234"}]}}}}'
  exit 0
fi
exit 0
GH
chmod +x "$GHSB95/gh"
BTF95="$TMPROOT/bt-file"; printf '/q review\n# comment\n\n/codex review\n' > "$BTF95"
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHSB95:/usr/bin:/bin" bash -c "
  source '$SBA95/lib-auth.sh'
  AGENT_GH_TOKEN_FILE='/some/scoped/token'   # scoping armed
  AGENT_BOT_TRIGGER_FILE='$BTF95'
  # Pass an allow-list covering both phrases (the file's content) so the broker
  # posts them; the literal mirrors bot_trigger_allowlist 'q codex'.
  drain_agent_bot_triggers 234 owner/repo \$'/q review\n/codex review'
" >/dev/null 2>&1
posts=$(grep -c '^GAU' "$BT_POSTS" 2>/dev/null || echo 0)
# The skipped `# comment` line would appear as a `--body # comment` post if not
# skipped; assert that exact body never posted (NOT a bare 'comment' substring,
# which the `pr comment` subcommand contains).
if [[ "$posts" -eq 2 ]] \
   && grep -qF -- '--body /q review' "$BT_POSTS" && grep -qF -- '--body /codex review' "$BT_POSTS" \
   && ! grep -qF -- '--body # comment' "$BT_POSTS"; then
  assert_pass "drain_agent_bot_triggers posted the 2 trigger phrases via gh-as-user.sh (blank + #comment lines skipped)"
else
  assert_fail "bot-trigger broker did not post exactly the 2 phrases (posts=$posts): $(cat "$BT_POSTS" 2>/dev/null)"
fi
# (c) scoping OFF → broker no-ops.
: > "$BT_POSTS"
PATH="$GHSB95:$PATH" bash -c "
  source '$SBA95/lib-auth.sh'
  AGENT_GH_TOKEN_FILE=''   # scoping OFF
  AGENT_BOT_TRIGGER_FILE='$BTF95'
  drain_agent_bot_triggers 234 owner/repo
" >/dev/null 2>&1
if [[ ! -s "$BT_POSTS" ]]; then
  assert_pass "scoping off: drain_agent_bot_triggers is a no-op (no spurious bot triggers)"
else
  assert_fail "scoping off: broker posted triggers it shouldn't have: $(cat "$BT_POSTS" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-096: the REVIEW path also brokers bot triggers under the scrub (#234 [P1] 8e87de14) ==="
# ---------------------------------------------------------------------------
# #234 review [P1]: the dev path brokered bot triggers but the review path still
# told scoped review agents to run gh-as-user.sh directly (which can't auth with
# GH_USER_PAT scrubbed). render_bot_review_section must broker in scoped mode, and
# autonomous-review.sh must export AGENT_BOT_TRIGGER_FILE + drain it post-run.
LIB_BOTS="$SCRIPTS/lib-review-bots.sh"
REVIEW_SH="$SCRIPTS/autonomous-review.sh"
# (a) scoped mode: render_bot_review_section emits the broker instruction, NOT a
#     direct gh-as-user.sh trigger.
scoped_sec=$(AGENT_GH_TOKEN_FILE=/tmp/x bash -c "source '$LIB_BOTS'; render_bot_review_section 'q' 42 owner/repo" 2>/dev/null)
if printf '%s' "$scoped_sec" | grep -qF 'AGENT_BOT_TRIGGER_FILE' \
   && printf '%s' "$scoped_sec" | grep -qiF 'Do NOT run' \
   && ! printf '%s' "$scoped_sec" | grep -qF 'gh-as-user.sh pr comment'; then
  assert_pass "review scoped mode: render_bot_review_section brokers the trigger (writes AGENT_BOT_TRIGGER_FILE, no direct gh-as-user.sh)"
else
  assert_fail "review scoped mode: render_bot_review_section did NOT broker the trigger ([P1] regression)"
fi
# (b) unscoped mode: keeps the direct gh-as-user.sh trigger (PAT/no-scope unchanged).
unscoped_sec=$(env -u AGENT_GH_TOKEN_FILE bash -c "source '$LIB_BOTS'; render_bot_review_section 'q' 42 owner/repo" 2>/dev/null)
if printf '%s' "$unscoped_sec" | grep -qF 'gh-as-user.sh pr comment 42 --body "/q review"'; then
  assert_pass "review unscoped mode: render_bot_review_section keeps direct gh-as-user.sh (PAT/no-scope unchanged)"
else
  assert_fail "review unscoped mode: lost the direct gh-as-user.sh trigger"
fi
# (c) source-level: autonomous-review.sh exports AGENT_BOT_TRIGGER_FILE AND drains it.
if grep -qF 'export AGENT_BOT_TRIGGER_FILE' "$REVIEW_SH" \
   && grep -qF 'drain_agent_bot_triggers "$ISSUE_NUMBER" "$REPO"' "$REVIEW_SH"; then
  assert_pass "source: autonomous-review.sh exports AGENT_BOT_TRIGGER_FILE and drains it (drain_agent_bot_triggers)"
else
  assert_fail "source: autonomous-review.sh does not export/drain the bot-trigger broker file"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-097: broker allow-list restricts to EXACT configured triggers + wrapper hard-gates a missing bot review (#234 [P1] 37450359) ==="
# ---------------------------------------------------------------------------
LIB_BOTS="$SCRIPTS/lib-review-bots.sh"
# (a) bot_trigger_allowlist echoes the exact configured trigger phrases.
allow97=$(bash -c "source '$LIB_BOTS'; bot_trigger_allowlist 'q codex'" 2>/dev/null)
if printf '%s' "$allow97" | grep -qxF '/q review' && printf '%s' "$allow97" | grep -qxF '/codex review'; then
  assert_pass "bot_trigger_allowlist echoes the exact configured trigger phrases (/q review, /codex review)"
else
  assert_fail "bot_trigger_allowlist wrong: $allow97"
fi
# (b) drain_agent_bot_triggers REJECTS a non-trigger line and posts ONLY the
#     allow-listed phrases (the #234 [P1] #2 — no arbitrary user-attributed comments).
DRAIN_SBA="$TMPROOT/drain-allow"; mkdir -p "$DRAIN_SBA"
cp "$SCRIPTS/lib-auth.sh" "$DRAIN_SBA/"; cp "$LIB_BOTS" "$DRAIN_SBA/"
copy_chp_seam "$DRAIN_SBA"   # [#296 B3, #308] chp_pr_list for the PR-number read
printf '#!/bin/bash\nload_autonomous_conf(){ return 0; }\n' > "$DRAIN_SBA/lib-config.sh"
printf '#!/bin/bash\nget_gh_app_token(){ echo X; }\nget_gh_app_scoped_token(){ echo X; }\n' > "$DRAIN_SBA/gh-app-token.sh"
DRAIN_POSTS="$TMPROOT/drain-posts.log"; : > "$DRAIN_POSTS"
printf '#!/bin/bash\nprintf "POST %%s\\n" "$*" >> "%s"\n' "$DRAIN_POSTS" > "$DRAIN_SBA/gh-as-user.sh"; chmod +x "$DRAIN_SBA/gh-as-user.sh"
DRAIN_GH="$TMPROOT/drain-gh"; mkdir -p "$DRAIN_GH"
# W1c1 (#397): chp_pr_list normalizes gh's raw output; emit a canned array.
# W1c1 (#397): chp_pr_list uses `gh api graphql` cursor page walk; return
# the GraphQL envelope with one PR body-mentioning #234.
cat > "$DRAIN_GH/gh" <<'DRAIN_GH_STUB'
#!/bin/bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"number":42,"body":"Closes #234"}]}}}}'
  exit 0
fi
exit 0
DRAIN_GH_STUB
chmod +x "$DRAIN_GH/gh"
DRAIN_BTF="$TMPROOT/drain-bt"; printf '/q review\n/evil arbitrary comment\n/codex review\n' > "$DRAIN_BTF"
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$DRAIN_GH:/usr/bin:/bin" bash -c "
  source '$DRAIN_SBA/lib-code-host.sh'; source '$DRAIN_SBA/lib-auth.sh'; source '$DRAIN_SBA/lib-review-bots.sh'
  AGENT_GH_TOKEN_FILE='/scoped'; AGENT_BOT_TRIGGER_FILE='$DRAIN_BTF'
  allow=\$(bot_trigger_allowlist 'q codex')
  drain_agent_bot_triggers 234 owner/repo \"\$allow\"
" >/dev/null 2>&1
if grep -qF -- '--body /q review' "$DRAIN_POSTS" && grep -qF -- '--body /codex review' "$DRAIN_POSTS" \
   && ! grep -qF -- '--body /evil arbitrary comment' "$DRAIN_POSTS"; then
  assert_pass "drain allow-list: posts ONLY the configured triggers, REJECTS the arbitrary line"
else
  assert_fail "drain allow-list leaked a non-trigger line or dropped an allowed one: $(cat "$DRAIN_POSTS" 2>/dev/null)"
fi
# (c) empty allow-list → fail-closed (nothing posted even for a real-looking trigger).
: > "$DRAIN_POSTS"
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$DRAIN_GH:/usr/bin:/bin" bash -c "
  source '$DRAIN_SBA/lib-auth.sh'
  AGENT_GH_TOKEN_FILE='/scoped'; AGENT_BOT_TRIGGER_FILE='$DRAIN_BTF'
  drain_agent_bot_triggers 234 owner/repo ''
" >/dev/null 2>&1
if [[ ! -s "$DRAIN_POSTS" ]]; then
  assert_pass "drain empty allow-list: fail-closed (nothing posted)"
else
  assert_fail "drain empty allow-list posted something it shouldn't have: $(cat "$DRAIN_POSTS" 2>/dev/null)"
fi
# (d) missing_bot_reviews wiring through chp_count_reviews_by_login ([INV-94], #324).
#     The per-bot review count now routes through the CHP verb (the leaf encapsulates
#     the --paginate sum; the -eq 0 MISSING decision stays caller-side). These cases
#     materialize the CHP seam (copy_chp_seam) alongside lib-review-bots.sh so the
#     verb path is genuinely exercised; the leaf-absent cases drop the seam and run
#     under explicit `set -euo pipefail` to prove the fail-safe + no-abort.
MBR_SBA="$TMPROOT/mbr-sba"; mkdir -p "$MBR_SBA"
cp "$LIB_BOTS" "$MBR_SBA/lib-review-bots.sh"
copy_chp_seam "$MBR_SBA"   # [#324] lib-code-host.sh + chp-github.sh → defines chp_count_reviews_by_login
# Recording gh stub: `api …/reviews --jq '…|length'` honored against a fixture via
# real jq (single page); anything else is a no-op success.
MBR_GH="$TMPROOT/mbr-gh"; mkdir -p "$MBR_GH"
cat > "$MBR_GH/gh" <<'MBRGH'
#!/bin/bash
if [[ "${1:-}" != "api" ]]; then exit 0; fi
jqf=""; prev=""
for a in "$@"; do [[ "$prev" == "--jq" ]] && jqf="$a"; prev="$a"; done
printf '%s' "${MBR_REVIEWS:-[]}" | jq "$jqf"
MBRGH
chmod +x "$MBR_GH/gh"

# (d.1 / TC-CRBL-021) NO review by the bot → bot listed MISSING (the existing :841 TC).
MBR=$(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$MBR_GH:/usr/bin:/bin" \
  MBR_REVIEWS='[]' bash -c "
  source '$MBR_SBA/lib-code-host.sh'
  source '$MBR_SBA/lib-review-bots.sh'
  missing_bot_reviews 'q' 42 owner/repo
" 2>/dev/null | tr '\n' ' ')
if printf '%s' "$MBR" | grep -qw 'q'; then
  assert_pass "missing_bot_reviews (seam loaded): lists a configured bot with no review (hard-gate signal)"
else
  assert_fail "missing_bot_reviews did not list the missing bot: '$MBR'"
fi

# (d.2 / TC-CRBL-020) a PRESENT review by the bot login → bot NOT listed (verb returns >0).
MBR2=$(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$MBR_GH:/usr/bin:/bin" \
  MBR_REVIEWS='[{"user":{"login":"amazon-q-developer[bot]"}}]' bash -c "
  source '$MBR_SBA/lib-code-host.sh'
  source '$MBR_SBA/lib-review-bots.sh'
  missing_bot_reviews 'q' 42 owner/repo
" 2>/dev/null | tr '\n' ' ')
if ! printf '%s' "$MBR2" | grep -qw 'q'; then
  assert_pass "missing_bot_reviews (seam loaded): a present review → bot NOT listed (verb counts it PRESENT)"
else
  assert_fail "missing_bot_reviews listed a bot that DID review: '$MBR2'"
fi

# (d.3 / TC-CRBL-022) leaf/shim ABSENT, unset CODE_HOST, under explicit `set -euo
#     pipefail`: the bare dual guard skips → count=0 → bot MISSING, NO abort. (The
#     bash -c harness lacks set -e, so the case enables it explicitly — else a
#     `set -e` abort would slip past.) Only lib-review-bots.sh is sourced (NO seam),
#     and CODE_HOST is unset; the short-circuit && means the bare ${CODE_HOST} in the
#     2nd guard is never reached (the 1st `declare -F chp_count_reviews_by_login` is
#     already false). We capture BOTH the output and the exit status.
MBR3_OUT="$TMPROOT/mbr3.out"
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR -u CODE_HOST PATH="$MBR_GH:/usr/bin:/bin" bash -c "
  set -euo pipefail
  source '$MBR_SBA/lib-review-bots.sh'
  missing_bot_reviews 'q' 42 owner/repo
" >"$MBR3_OUT" 2>/dev/null
MBR3_RC=$?
if [[ "$MBR3_RC" -eq 0 ]] && grep -qw 'q' "$MBR3_OUT"; then
  assert_pass "missing_bot_reviews leaf-absent + unset CODE_HOST under set -euo pipefail → bot MISSING, NO abort"
else
  assert_fail "leaf-absent/unset-CODE_HOST aborted or dropped the bot (rc=$MBR3_RC, out='$(cat "$MBR3_OUT")') — INV-79 fail-safe broken"
fi

# (d.4 / TC-CRBL-023) leaf ABSENT but CODE_HOST SET to a provider with no such leaf,
#     under set -euo pipefail: source lib-code-host.sh (so the shim + CODE_HOST exist)
#     pointed at a fixture providers dir whose chp-noleaf.sh defines NO
#     count_reviews_by_login leaf → the 2nd guard (bare chp_noleaf_…) is false →
#     count=0 → bot MISSING, NO abort.
NOLEAF_DIR="$TMPROOT/noleaf-providers"; mkdir -p "$NOLEAF_DIR"
cat > "$NOLEAF_DIR/chp-noleaf.sh" <<'NOLEAF'
#!/bin/bash
# A provider that deliberately omits chp_noleaf_count_reviews_by_login.
chp_noleaf_pr_view() { :; }
NOLEAF
MBR4_OUT="$TMPROOT/mbr4.out"
env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$MBR_GH:/usr/bin:/bin" \
  CODE_HOST=noleaf AUTONOMOUS_PROVIDERS_DIR="$NOLEAF_DIR" bash -c "
  set -euo pipefail
  source '$MBR_SBA/lib-code-host.sh'
  source '$MBR_SBA/lib-review-bots.sh'
  missing_bot_reviews 'q' 42 owner/repo
" >"$MBR4_OUT" 2>/dev/null
MBR4_RC=$?
if [[ "$MBR4_RC" -eq 0 ]] && grep -qw 'q' "$MBR4_OUT"; then
  assert_pass "missing_bot_reviews CODE_HOST=noleaf (leaf absent) under set -euo pipefail → bot MISSING, NO abort"
else
  assert_fail "CODE_HOST=noleaf leaf-absent aborted or dropped the bot (rc=$MBR4_RC, out='$(cat "$MBR4_OUT")')"
fi

# (d.5 / TC-CRBL-024) guard expr-equality: the caller's 2nd leaf-guard MUST use the
#     BARE chp_${CODE_HOST}_count_reviews_by_login IDENTICAL to the shim's dispatch
#     (a `:-github` guard vs the bare shim diverges on unset CODE_HOST → abort).
LIB_CHP_SRC="$SCRIPTS/lib-code-host.sh"
if grep -qE 'declare -F "chp_\$\{CODE_HOST\}_count_reviews_by_login"' "$LIB_BOTS" \
   && grep -qE 'chp_count_reviews_by_login\(\)[[:space:]]*\{[[:space:]]*chp_\$\{CODE_HOST\}_count_reviews_by_login' "$LIB_CHP_SRC"; then
  assert_pass "guard expr == shim dispatch: caller guards the BARE chp_\${CODE_HOST}_count_reviews_by_login (no :-github divergence)"
else
  assert_fail "guard expr diverges from the shim's bare chp_\${CODE_HOST}_ dispatch (latent unset-CODE_HOST abort)"
fi
# (e) source-level: autonomous-review.sh hard-gates a missing bot review in the PASS
#     branch (calls missing_bot_reviews and re-queues to pending-review) + passes the
#     allow-list to the drain; autonomous-dev.sh passes the allow-list too.
if grep -qF 'missing_bot_reviews "$REVIEW_BOTS_VALIDATED" "$PR_NUMBER" "$REPO"' "$REVIEW_SH" \
   && grep -qF 'drain_agent_bot_triggers "$ISSUE_NUMBER" "$REPO" "$_bot_allowlist"' "$REVIEW_SH" \
   && grep -qF 'drain_agent_bot_triggers "$ISSUE_NUMBER" "$REPO" "$_bot_allowlist"' "$DEV_SH"; then
  assert_pass "source: review wrapper hard-gates a missing bot review + both wrappers pass the trigger allow-list to the drain"
else
  assert_fail "source: missing the wrapper hard-gate or the allow-list arg on a drain call"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-060: scoped permissions are pull_requests:read (cannot approve/merge) ==="
# ---------------------------------------------------------------------------
# The default scoped permissions string the lib ships must request pull_requests
# at READ (not write) — the containment lever. Source-level + value assertion.
perms_default=$(bash -c "source '$SBA/lib-config.sh' 2>/dev/null; source '$SBA/lib-auth.sh'; echo \"\$AGENT_TOKEN_PERMISSIONS\"")
if printf '%s' "$perms_default" | grep -qF '"pull_requests":"read"' \
   && ! printf '%s' "$perms_default" | grep -qF '"pull_requests":"write"'; then
  assert_pass "default scoped permissions request pull_requests:read (approve/merge blocked at the token)"
else
  assert_fail "default scoped permissions do NOT pin pull_requests:read: $perms_default"
fi
if printf '%s' "$perms_default" | grep -qF '"contents":"write"'; then
  assert_pass "default scoped permissions keep contents:write (dev push works)"
else
  assert_fail "default scoped permissions missing contents:write (dev push impossible): $perms_default"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-070: drain_agent_pr_create brokers only when scoping armed ==="
# ---------------------------------------------------------------------------
# Stub `gh` on PATH: `gh pr list` → empty (no existing PR) AND record the argv
# ([#296 B3, #308] the existence read now routes through chp_pr_list → the verb
# emits `gh pr list --repo <REPO> …`; we assert the stub OBSERVED it through the
# verb, not just that the broker ran — reachability ≠ exercised, AC5/AC4);
# `gh pr create` → record args. The head-resolution fallback no longer calls
# `gh repo view` (#316, Option A: it now trusts `origin` directly via
# `git ls-remote --heads origin`, mirroring [INV-45] at autonomous-dev.sh:397) —
# the stub still LOGS any `repo view` call so TC-316-01 can assert it NEVER fires.
GHSB="$TMPROOT/gh-stub"; mkdir -p "$GHSB"
PR_CREATE_LOG="$GHSB/pr-create.log"
PR_LIST_LOG="$GHSB/pr-list.log"
REPO_VIEW_LOG="$GHSB/repo-view.log"
cat > "$GHSB/gh" <<GHSTUB
#!/bin/bash
# W1c1 (#397): chp_pr_list now emits \`gh api graphql\` cursor page walk.
# Log the argv (so the assert below can grep for owner/repo bind + states
# filter + body selection) and return the empty-PR envelope so the caller-
# side jq counts 0 (no existing PR → broker fires chp_create_pr).
if [[ "\$1" == "api" && "\$2" == "graphql" ]]; then
  echo "LISTED \$*" >> "$PR_LIST_LOG"
  printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}'
  exit 0
fi
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then echo "REPO-VIEW \$*" >> "$REPO_VIEW_LOG"; echo "https://github.com/owner/repo.git"; exit 0; fi
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then echo "CREATED \$*" >> "$PR_CREATE_LOG"; exit 0; fi
exit 0
GHSTUB
chmod +x "$GHSB/gh"

# The broker file carries an explicit `branch:` line-1 (the #234 [P1] fix: the
# wrapper passes --head so the wrapper's base-branch cwd doesn't break create).
PRFILE="$TMPROOT/agent-pr-create"
printf 'branch: feat/issue-234-foo\nfeat: my title\nBody line.\nCloses #234\n' > "$PRFILE"

# (a) scoping armed + explicit branch → broker fires with --head <branch> + title.
# REPO is the GLOBAL the verb prepends; set it so the observed-argv assert below
# checks `--repo owner/repo` (the broker's $repo arg equals $REPO at runtime, AC7).
rm -f "$PR_CREATE_LOG" "$PR_LIST_LOG"
PATH="$GHSB:$PATH" REPO="owner/repo" bash -c "
  source '$SBA/lib-auth.sh'
  AGENT_GH_TOKEN_FILE='/some/scoped/token'
  AGENT_PR_CREATE_FILE='$PRFILE'
  drain_agent_pr_create 234 owner/repo
" >/dev/null 2>&1
if [[ -s "$PR_CREATE_LOG" ]] \
   && grep -qF 'feat: my title' "$PR_CREATE_LOG" \
   && grep -qF -- '--head feat/issue-234-foo' "$PR_CREATE_LOG"; then
  assert_pass "scoping armed: drain_agent_pr_create ran gh pr create --head <branch> with the title"
else
  assert_fail "scoping armed: broker did NOT create with --head (log: $(cat "$PR_CREATE_LOG" 2>/dev/null))"
fi
# [#296 B3, #308, W1c1 #397] AC5/AC4: the PR-existence read was OBSERVED
# through chp_pr_list. Under W1c1 the leaf emits `gh api graphql` with cursor
# pagination (§3.5); the argv carries `-F owner=owner`, `-F repo=repo`, a
# `pullRequests(first:100, states:[OPEN]…)` query, and — because the caller
# passed FIELDS-CSV=body — the query selects the `body` field. With the CHP
# seam copied into the sandbox (new_auth_sandbox), an UNDEFINED-verb
# fail-soft can no longer pass this for the wrong reason: the stub must have
# actually recorded the graphql call.
if [[ -s "$PR_LIST_LOG" ]] \
   && grep -qF -- 'api graphql' "$PR_LIST_LOG" \
   && grep -qF -- 'owner=owner' "$PR_LIST_LOG" \
   && grep -qF -- 'repo=repo' "$PR_LIST_LOG" \
   && grep -qF -- 'pullRequests(first: 100' "$PR_LIST_LOG" \
   && grep -qF -- 'states: [OPEN]' "$PR_LIST_LOG" \
   && grep -qE -- '[[:space:]]body[[:space:]]' "$PR_LIST_LOG"; then
  assert_pass "scoping armed: existence read OBSERVED through chp_pr_list (gh api graphql owner/repo bind + states:[OPEN] + body selection)"
else
  assert_fail "existence read NOT observed through chp_pr_list (verb undefined → silent fail-soft?) (log: $(cat "$PR_LIST_LOG" 2>/dev/null))"
fi

# (b) scoping OFF (AGENT_GH_TOKEN_FILE empty) → broker NO-OPs (agent created directly).
rm -f "$PR_CREATE_LOG"
PATH="$GHSB:$PATH" bash -c "
  source '$SBA/lib-auth.sh'
  AGENT_GH_TOKEN_FILE=''
  AGENT_PR_CREATE_FILE='$PRFILE'
  drain_agent_pr_create 234 owner/repo
" >/dev/null 2>&1
if [[ ! -s "$PR_CREATE_LOG" ]]; then
  assert_pass "scoping off: drain_agent_pr_create is a no-op (no spurious gh pr create)"
else
  assert_fail "scoping off: broker created a PR it shouldn't have (log: $(cat "$PR_CREATE_LOG" 2>/dev/null))"
fi

# (c) no `branch:` line AND no derivable branch → broker SKIPS (no doomed
# same-branch create). The ls-remote fallback returns nothing (stub git via PATH
# is absent → ls-remote fails → empty), so the broker must NOT call gh pr create.
rm -f "$PR_CREATE_LOG"
PRFILE_NOBRANCH="$TMPROOT/agent-pr-create-nobranch"
printf 'feat: titled but no branch\nBody.\n' > "$PRFILE_NOBRANCH"
# Stub `git` so ls-remote returns empty (no matching branch on origin).
GITSB="$TMPROOT/git-stub"; mkdir -p "$GITSB"
printf '#!/bin/bash\nexit 0\n' > "$GITSB/git"; chmod +x "$GITSB/git"
PATH="$GITSB:$GHSB:$PATH" bash -c "
  source '$SBA/lib-auth.sh'
  AGENT_GH_TOKEN_FILE='/some/scoped/token'
  AGENT_PR_CREATE_FILE='$PRFILE_NOBRANCH'
  drain_agent_pr_create 234 owner/repo
" >/dev/null 2>&1
if [[ ! -s "$PR_CREATE_LOG" ]]; then
  assert_pass "no branch derivable: broker SKIPS gh pr create (no doomed same-branch PR)"
else
  assert_fail "no branch derivable: broker created a PR anyway (log: $(cat "$PR_CREATE_LOG" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-316-01: head resolution uses \`git ls-remote --heads origin\`, never \`gh repo view\` ==="
# ---------------------------------------------------------------------------
# #316 (Option A): no explicit `branch:` line → the broker derives the head from
# `origin` directly via `git ls-remote --heads origin "*issue-N*"`, NOT by first
# resolving a clone URL with `gh repo view`. Stub `git` so `ls-remote --heads
# origin` returns a fixture ref AND logs its argv; assert the stub OBSERVED it and
# the `gh` stub NEVER recorded a `repo view`; the resolved branch flows into
# `gh pr create --head <fixture>`.
GITSB1="$TMPROOT/git-stub-316-01"; mkdir -p "$GITSB1"
GIT_LSREMOTE_LOG="$GITSB1/ls-remote.log"
cat > "$GITSB1/git" <<GITSTUB
#!/bin/bash
if [[ "\$1" == "ls-remote" ]]; then
  echo "LS-REMOTE \$*" >> "$GIT_LSREMOTE_LOG"
  # Emit a fixture <sha>\trefs/heads/<branch> line for the *issue-N* glob.
  printf '%s\trefs/heads/feat/issue-316-foo\n' "0123456789abcdef0123456789abcdef01234567"
  exit 0
fi
exit 0
GITSTUB
chmod +x "$GITSB1/git"

PRFILE_316="$TMPROOT/agent-pr-create-316-01"
printf 'feat: titled, no branch line\nBody.\nCloses #316\n' > "$PRFILE_316"
rm -f "$PR_CREATE_LOG" "$REPO_VIEW_LOG" "$GIT_LSREMOTE_LOG"
PATH="$GITSB1:$GHSB:$PATH" REPO="owner/repo" bash -c "
  source '$SBA/lib-auth.sh'
  AGENT_GH_TOKEN_FILE='/some/scoped/token'
  AGENT_PR_CREATE_FILE='$PRFILE_316'
  drain_agent_pr_create 316 owner/repo
" >/dev/null 2>&1
# (1) ls-remote OBSERVED with `--heads origin "*issue-316*"`.
if [[ -s "$GIT_LSREMOTE_LOG" ]] \
   && grep -qF -- 'LS-REMOTE ls-remote --heads origin *issue-316*' "$GIT_LSREMOTE_LOG"; then
  assert_pass "TC-316-01: head resolved via OBSERVED git ls-remote --heads origin *issue-316*"
else
  assert_fail "TC-316-01: git ls-remote --heads origin NOT observed (log: $(cat "$GIT_LSREMOTE_LOG" 2>/dev/null))"
fi
# (2) `gh repo view` NEVER invoked (the survivor is gone).
if [[ ! -s "$REPO_VIEW_LOG" ]]; then
  assert_pass "TC-316-01: gh repo view NEVER invoked (Option A removed the clone-URL read)"
else
  assert_fail "TC-316-01: gh repo view WAS invoked (log: $(cat "$REPO_VIEW_LOG" 2>/dev/null))"
fi
# (3) resolved branch == fixture; gh pr create got --head <fixture>.
if [[ -s "$PR_CREATE_LOG" ]] \
   && grep -qF -- '--head feat/issue-316-foo' "$PR_CREATE_LOG"; then
  assert_pass "TC-316-01: resolved branch feeds gh pr create --head feat/issue-316-foo"
else
  assert_fail "TC-316-01: gh pr create did NOT get --head <fixture> (log: $(cat "$PR_CREATE_LOG" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-316-02/03/04: no-branch WARN — origin URL surfaced, credentials redacted, set -e safe ==="
# ---------------------------------------------------------------------------
# Driver: stub `git` so `ls-remote --heads origin` is EMPTY (no pushed branch) and
# `git remote get-url origin` returns a configurable URL (or fails). The broker
# must WARN+skip identically (no gh pr create) and the WARN now carries the origin
# URL — with any credential userinfo REDACTED, and the `git remote get-url` capture
# `set -e`-safe.
drain_warn_stderr() {
  # $1 = git stub body for `git remote get-url origin` (echoed verbatim into the stub)
  local geturl_body="$1"
  local sb="$TMPROOT/git-stub-warn-$RANDOM"; mkdir -p "$sb"
  cat > "$sb/git" <<GITWARN
#!/bin/bash
if [[ "\$1" == "ls-remote" ]]; then exit 0; fi   # no matching branch on origin
if [[ "\$1" == "remote" && "\$2" == "get-url" ]]; then ${geturl_body}; fi
exit 0
GITWARN
  chmod +x "$sb/git"
  rm -f "$PR_CREATE_LOG"
  PATH="$sb:$GHSB:$PATH" REPO="owner/repo" bash -c "
    set -e
    source '$SBA/lib-auth.sh'
    AGENT_GH_TOKEN_FILE='/some/scoped/token'
    AGENT_PR_CREATE_FILE='$PRFILE_NOBRANCH'
    drain_agent_pr_create 316 owner/repo
  " 2>&1
}

# TC-316-02: plain origin URL → WARN+skip; WARN carries the origin URL.
WARN_OUT=$(drain_warn_stderr 'echo "https://github.com/owner/repo.git"')
if [[ ! -s "$PR_CREATE_LOG" ]] \
   && grep -qF 'no head branch' <<<"$WARN_OUT" \
   && grep -qF 'origin=https://github.com/owner/repo.git' <<<"$WARN_OUT"; then
  assert_pass "TC-316-02: no-branch path WARN+skips and carries the origin URL"
else
  assert_fail "TC-316-02: WARN missing origin URL or broker created a PR (out: $WARN_OUT)"
fi

# TC-316-03: credential-bearing origin → token REDACTED, never logged.
WARN_OUT=$(drain_warn_stderr 'echo "https://x-access-token:SECRET@github.com/owner/repo.git"')
if grep -qF 'origin=https://<redacted>@github.com/owner/repo.git' <<<"$WARN_OUT" \
   && ! grep -qF 'SECRET' <<<"$WARN_OUT"; then
  assert_pass "TC-316-03: credential-bearing origin redacted to <redacted>@; token never logged"
else
  assert_fail "TC-316-03: token leaked or not redacted (out: $WARN_OUT)"
fi

# TC-316-04: `git remote get-url origin` FAILS (non-zero) under set -e → must NOT abort.
WARN_OUT=$(drain_warn_stderr 'exit 3')
if [[ ! -s "$PR_CREATE_LOG" ]] \
   && grep -qF 'no head branch' <<<"$WARN_OUT"; then
  assert_pass "TC-316-04: failing git remote get-url is set -e-safe (WARN+skip still fires)"
else
  assert_fail "TC-316-04: function aborted on failing git remote get-url (out: $WARN_OUT)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-072: _post_brokered_e2e_report posts file body / no-ops on empty ==="
# ---------------------------------------------------------------------------
# Provide a stub `log` + `gh` and source lib-review-e2e.sh's helper in isolation.
RSB="$TMPROOT/review-sb"; mkdir -p "$RSB"
E2E_POST_LOG="$RSB/e2e-post.log"
cat > "$RSB/gh" <<GHSTUB2
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "comment" ]]; then echo "POSTED \$*" >> "$E2E_POST_LOG"; exit 0; fi
exit 0
GHSTUB2
chmod +x "$RSB/gh"
REPORTFILE="$RSB/e2e-report.md"
printf '## E2E Verification Report\nAll green.\n' > "$REPORTFILE"
# (a) non-empty report → posted.
rm -f "$E2E_POST_LOG"
PATH="$RSB:$PATH" bash -c "
  log() { :; }
  PR_NUMBER=99; REPO=owner/repo; E2E_REPORT_FILE='$REPORTFILE'
  # [#342] Source the CHP seam FIRST, mirroring production order (autonomous-review.sh
  # sources lib-code-host.sh BEFORE lib-review-e2e.sh). Today's _post_brokered_e2e_report
  # posts via a raw \`gh pr comment\`, so the seam is inert here — but when that post
  # migrates behind a CHP verb (e.g. #329's chp_pr_comment), the verb resolves through
  # this seam to the PATH \`gh\` stub instead of dying command-not-found inside this
  # bash -c sandbox (the TC-TOKEN-SPLIT-072 shape the seam-source meta-check prevents).
  source '$SCRIPTS/lib-code-host.sh' 2>/dev/null || true
  # Pull just the helper out of lib-review-e2e.sh (avoid sourcing the whole file's
  # top-level deps) by sourcing the file with stubs already defined.
  source '$SCRIPTS/lib-review-e2e.sh' 2>/dev/null || true
  _post_brokered_e2e_report
" >/dev/null 2>&1
if [[ -s "$E2E_POST_LOG" ]] && grep -qF 'POSTED' "$E2E_POST_LOG"; then
  assert_pass "non-empty E2E report → wrapper brokered a PR comment"
else
  assert_fail "non-empty E2E report was NOT brokered (log: $(cat "$E2E_POST_LOG" 2>/dev/null))"
fi
# (b) missing report file → no post.
rm -f "$E2E_POST_LOG"
PATH="$RSB:$PATH" bash -c "
  log() { :; }
  PR_NUMBER=99; REPO=owner/repo; E2E_REPORT_FILE='$RSB/does-not-exist.md'
  # [#342] CHP seam first (see the note on the (a) sandbox above) — same TC-TOKEN-SPLIT-072
  # anti-recurrence: keep the seam resolvable in THIS bash -c context before the lib source.
  source '$SCRIPTS/lib-code-host.sh' 2>/dev/null || true
  source '$SCRIPTS/lib-review-e2e.sh' 2>/dev/null || true
  _post_brokered_e2e_report
" >/dev/null 2>&1
if [[ ! -s "$E2E_POST_LOG" ]]; then
  assert_pass "missing E2E report file → no spurious broker post"
else
  assert_fail "missing E2E report file still posted (log: $(cat "$E2E_POST_LOG" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-012: cleanup_github_auth clears scoped-token state ==="
# ---------------------------------------------------------------------------
SBC=$(new_auth_sandbox)
out_clean=$(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  REPO_OWNER="owner" REPO_NAME="repo" bash -c "
  source '$SBC/lib-auth.sh'
  GH_AUTH_MODE='app'
  setup_github_auth '12345' '/nonexistent.pem' >/dev/null 2>&1
  setup_agent_token '12345' '/nonexistent.pem' >/dev/null 2>&1
  cleanup_github_auth >/dev/null 2>&1
  echo \"AGENT_FILE=[\${AGENT_GH_TOKEN_FILE:-}]\"
  echo \"AGENT_DAEMON=[\${AGENT_TOKEN_DAEMON_PID:-}]\"
")
if printf '%s\n' "$out_clean" | grep -q 'AGENT_FILE=\[\]' \
   && printf '%s\n' "$out_clean" | grep -q 'AGENT_DAEMON=\[\]'; then
  assert_pass "cleanup cleared AGENT_GH_TOKEN_FILE + AGENT_TOKEN_DAEMON_PID (reused-shell idempotency)"
else
  assert_fail "cleanup left stale scoped-token state: $out_clean"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-FBDISP-*: [INV-91] (#346) fail-loud disposition for the leaf-absent raw-gh fallbacks ==="
# ---------------------------------------------------------------------------
# drain_agent_pr_create / drain_agent_bot_triggers retain their raw `gh pr create`
# / `gh-as-user.sh` fallback ONLY under `CODE_HOST == github` (spec-sanctioned
# github-gated residue). A non-GitHub backend that omits the create_pr / trigger_bot
# leaf must NOT silently make a GitHub call — it fails LOUD and does nothing.
# The two named fake providers are selected through the PUBLIC seam
# (CODE_HOST=<name> + AUTONOMOUS_PROVIDERS_DIR=<fixture dir>):
#   - provider-fbdisp-noleaf/chp-fbdispnoleaf.sh: NO create_pr/trigger_bot leaf
#     (defines only pr_list so the broker reads resolve), review_bots=1.
#   - provider-fbdisp-leaf/chp-fbdispleaf.sh: create_pr/trigger_bot leaves DEFINED
#     (record argv to CHP_FBDISP_LEAF_LOG), review_bots=1.
# CHP_FBDISP_PR_BODY controls the fixture's canned PR body so ONE fixture serves
# both broker reads: default body does NOT mention #<issue> (pr-create existence
# COUNT → 0 → proceed to create); set it to mention #<issue> for the bot-trigger
# PR-NUMBER read.
FBDISP_NOLEAF="$SCRIPT_DIR/fixtures/provider-fbdisp-noleaf"
FBDISP_LEAF="$SCRIPT_DIR/fixtures/provider-fbdisp-leaf"
# GitHub-named fixture that defines chp_github_pr_list but OMITS chp_github_trigger_bot
# — drives TC-FBDISP-004 (the raw `else` under CODE_HOST=github with the leaf absent).
FBDISP_GH_NOTRIGGER="$SCRIPT_DIR/fixtures/provider-fbdisp-gh-notrigger"

# new_auth_sandbox already copies lib-code-host.sh + providers/chp-github.{sh,caps};
# add a gh-as-user.sh stub (for the bot-trigger broker's resolution) so the sandbox
# serves both brokers.
fbdisp_sandbox() {
  local d; d=$(new_auth_sandbox)
  # gh-as-user.sh stub records posts; overwritten per-test to point at the log.
  echo "$d"
}

if [[ -d "$FBDISP_NOLEAF" && -d "$FBDISP_LEAF" && -d "$FBDISP_GH_NOTRIGGER" ]]; then
  # -------------------------------------------------------------------------
  # TC-FBDISP-001: github topology → drain_agent_pr_create emits byte-identical
  # `gh pr create --repo … --head … --title … --body …` argv (golden trace). AC1.
  # Uses the DEFAULT github seam (new_auth_sandbox copies chp-github, whose
  # create_pr leaf IS defined) so the VERB path (chp_create_pr → chp_github_create_pr
  # → `gh pr create --repo "$REPO" "$@"`) is taken — that verb forwards to the SAME
  # `gh pr create` argv the raw github fallback would emit, so the observed argv is
  # byte-identical either way. The raw `elif [[ CODE_HOST==github ]]` fallback branch
  # itself (reachable only when chp_has_leaf create_pr is false, e.g. lib-code-host
  # not sourced) gets its OWN execution trace in TC-FBDISP-003.
  SBG1=$(fbdisp_sandbox)
  GHG1="$TMPROOT/fbdisp-gh1"; mkdir -p "$GHG1"; PRC1="$GHG1/pr-create.log"
  cat > "$GHG1/gh" <<GHSTUB
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then printf ""; exit 0; fi
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then echo "CREATED \$*" >> "$PRC1"; exit 0; fi
exit 0
GHSTUB
  chmod +x "$GHG1/gh"
  PRF1="$TMPROOT/fbdisp-prf1"; printf 'branch: feat/issue-346-foo\nfeat: my title\nBody.\nCloses #346\n' > "$PRF1"
  env -u CODE_HOST -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHG1:/usr/bin:/bin" REPO="owner/repo" bash -c "
    source '$SBG1/lib-auth.sh'
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_PR_CREATE_FILE='$PRF1'
    drain_agent_pr_create 346 owner/repo
  " >/dev/null 2>&1
  if grep -qF -- 'CREATED pr create --repo owner/repo --head feat/issue-346-foo --title feat: my title --body' "$PRC1"; then
    assert_pass "TC-FBDISP-001 github topology: drain_agent_pr_create raw fallback argv byte-identical (gh pr create --repo … --head … --title … --body …)"
  else
    assert_fail "TC-FBDISP-001 github fallback argv changed: $(cat "$PRC1" 2>/dev/null)"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-002: github topology → drain_agent_bot_triggers emits byte-identical
  # `gh-as-user.sh pr comment … --body <phrase>` posts. AC1. As in TC-FBDISP-001,
  # the github seam's trigger_bot leaf IS defined, so the VERB path forwards to the
  # same gh-as-user.sh argv; the raw `else` fallback (reachable only when the leaf
  # is absent under CODE_HOST==github) gets its own trace in TC-FBDISP-004.
  SBG2=$(fbdisp_sandbox)
  GAU2="$TMPROOT/fbdisp-gau2.log"; : > "$GAU2"
  printf '#!/bin/bash\nprintf "GAU %%s\\n" "$*" >> "%s"\n' "$GAU2" > "$SBG2/gh-as-user.sh"; chmod +x "$SBG2/gh-as-user.sh"
  GHG2="$TMPROOT/fbdisp-gh2"; mkdir -p "$GHG2"
  cat > "$GHG2/gh" <<'GHSTUB'
#!/bin/bash
# W1c1 (#397): chp_pr_list now emits `gh api graphql` cursor page walk.
# Return the GraphQL envelope with one PR body-mentioning #346 → the caller-
# side selector resolves pr_number=4242.
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"number":4242,"body":"Closes #346"}]}}}}'
  exit 0
fi
exit 0
GHSTUB
  chmod +x "$GHG2/gh"
  BTF2="$TMPROOT/fbdisp-bt2"; printf '/q review\n/codex review\n' > "$BTF2"
  env -u CODE_HOST -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHG2:/usr/bin:/bin" REPO="owner/repo" \
    AUTONOMOUS_CONF_DIR="$SBG2" bash -c "
    source '$SBG2/lib-auth.sh'
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_BOT_TRIGGER_FILE='$BTF2'
    drain_agent_bot_triggers 346 owner/repo \$'/q review\n/codex review'
  " >/dev/null 2>&1
  if grep -qF -- 'GAU pr comment 4242 --repo owner/repo --body /q review' "$GAU2" \
     && grep -qF -- 'GAU pr comment 4242 --repo owner/repo --body /codex review' "$GAU2"; then
    assert_pass "TC-FBDISP-002 github topology: drain_agent_bot_triggers raw gh-as-user.sh fallback argv byte-identical"
  else
    assert_fail "TC-FBDISP-002 github fallback argv changed: $(cat "$GAU2" 2>/dev/null)"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-003: the RAW `elif [[ CODE_HOST==github ]]` fallback branch itself
  # fires byte-identically when chp_has_leaf is UNDEFINED (the lib-code-host-not-
  # sourced / leaf-undefined degraded case #346's ${CODE_HOST:-github} default
  # protects). Sandbox OMITS lib-code-host.sh + providers/ so lib-auth.sh's
  # self-source is skipped → chp_has_leaf undefined, CODE_HOST unset → the raw
  # elif branch is the one exercised (NOT the verb path of TC-FBDISP-001). AC1.
  SBRAW="$TMPROOT/fbdisp-raw-sb"; mkdir -p "$SBRAW"
  cp "$SCRIPTS/lib-auth.sh" "$SBRAW/"   # NO lib-code-host.sh / providers/ → chp_has_leaf undefined
  printf '#!/bin/bash\nload_autonomous_conf(){ return 0; }\n' > "$SBRAW/lib-config.sh"
  printf '#!/bin/bash\nget_gh_app_token(){ echo X; }\nget_gh_app_scoped_token(){ echo X; }\n' > "$SBRAW/gh-app-token.sh"
  GHRAW="$TMPROOT/fbdisp-raw-gh"; mkdir -p "$GHRAW"; PRCRAW="$GHRAW/pr-create.log"
  cat > "$GHRAW/gh" <<GHSTUB
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then printf ""; exit 0; fi
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then echo "CREATED \$*" >> "$PRCRAW"; exit 0; fi
exit 0
GHSTUB
  chmod +x "$GHRAW/gh"
  PRFRAW="$TMPROOT/fbdisp-raw-prf"; printf 'branch: feat/issue-346-foo\nfeat: my title\nBody.\n' > "$PRFRAW"
  out_raw=$(env -u CODE_HOST -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHRAW:/usr/bin:/bin" REPO="owner/repo" bash -c "
    source '$SBRAW/lib-auth.sh'
    declare -F chp_has_leaf >/dev/null 2>&1 && echo 'SEAM_PRESENT' || echo 'SEAM_ABSENT'
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_PR_CREATE_FILE='$PRFRAW'
    drain_agent_pr_create 346 owner/repo
  " 2>&1)
  if printf '%s' "$out_raw" | grep -qF 'SEAM_ABSENT' \
     && grep -qF -- 'CREATED pr create --repo owner/repo --head feat/issue-346-foo --title feat: my title --body' "$PRCRAW"; then
    assert_pass "TC-FBDISP-003 chp_has_leaf undefined + CODE_HOST unset: the github-gated raw elif fallback fires byte-identically (lib-load-failure degraded path)"
  else
    assert_fail "TC-FBDISP-003 raw elif branch not exercised byte-identically (out=$out_raw; log=$(cat "$PRCRAW" 2>/dev/null))"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-004: the RAW `else` gh-as-user.sh fallback in drain_agent_bot_triggers
  # fires byte-identically when the trigger_bot leaf is ABSENT under CODE_HOST=github.
  # Unlike -003 (pr-create), the bot-trigger broker's PR-NUMBER read routes through
  # chp_pr_list, so a fully-seam-absent sandbox would fail that read first ("no open
  # PR found") and never reach the posting loop. So this uses a GitHub-named fixture
  # (provider-fbdisp-gh-notrigger) that DEFINES chp_github_pr_list but OMITS
  # chp_github_trigger_bot, selected via CODE_HOST=github + AUTONOMOUS_PROVIDERS_DIR:
  # the PR read resolves, `chp_has_leaf trigger_bot` is FALSE, `${CODE_HOST:-github}
  # == github` is TRUE → the raw `else` branch is the one exercised. AC1.
  SBGN=$(fbdisp_sandbox)   # copies lib-code-host.sh so chp_has_leaf/chp_pr_list resolve
  GAUGN="$TMPROOT/fbdisp-gn-gau.log"; : > "$GAUGN"
  printf '#!/bin/bash\nprintf "GAU %%s\\n" "$*" >> "%s"\n' "$GAUGN" > "$SBGN/gh-as-user.sh"; chmod +x "$SBGN/gh-as-user.sh"
  GHGN="$TMPROOT/fbdisp-gn-gh"; mkdir -p "$GHGN"
  cat > "$GHGN/gh" <<'GHSTUB'
#!/bin/bash
# W1c1 (#397): chp_pr_list now emits `gh api graphql` cursor page walk.
# Return the GraphQL envelope with one PR body-mentioning #346 → the caller-
# side selector resolves pr_number=4242.
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"number":4242,"body":"Closes #346"}]}}}}'
  exit 0
fi
exit 0
GHSTUB
  chmod +x "$GHGN/gh"
  BTFGN="$TMPROOT/fbdisp-gn-bt"; printf '/q review\n' > "$BTFGN"
  out_gn=$(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHGN:/usr/bin:/bin" REPO="owner/repo" \
    AUTONOMOUS_CONF_DIR="$SBGN" CODE_HOST=github AUTONOMOUS_PROVIDERS_DIR="$FBDISP_GH_NOTRIGGER" bash -c "
    source '$SBGN/lib-auth.sh'
    declare -F chp_has_leaf >/dev/null 2>&1 && { chp_has_leaf trigger_bot && echo 'LEAF_PRESENT' || echo 'LEAF_ABSENT'; }
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_BOT_TRIGGER_FILE='$BTFGN'
    drain_agent_bot_triggers 346 owner/repo '/q review'
  " 2>&1)
  if printf '%s' "$out_gn" | grep -qF 'LEAF_ABSENT' \
     && grep -qF -- 'GAU pr comment 4242 --repo owner/repo --body /q review' "$GAUGN"; then
    assert_pass "TC-FBDISP-004 trigger_bot leaf absent under CODE_HOST=github: the github-gated raw gh-as-user.sh fallback fires byte-identically"
  else
    assert_fail "TC-FBDISP-004 raw else branch not exercised byte-identically (out=$out_gn; log=$(cat "$GAUGN" 2>/dev/null))"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-010: non-github + create_pr leaf ABSENT → loud error, NO raw gh
  # (tripwire). AC2.
  SBN1=$(fbdisp_sandbox)
  TRIP1="$TMPROOT/fbdisp-trip1.log"; : > "$TRIP1"
  GHN1="$TMPROOT/fbdisp-ghn1"; mkdir -p "$GHN1"
  printf '#!/bin/bash\nprintf "GH_TRIPWIRE %%s\\n" "$*" >> "%s"\nexit 0\n' "$TRIP1" > "$GHN1/gh"; chmod +x "$GHN1/gh"
  PRFN1="$TMPROOT/fbdisp-prfn1"; printf 'branch: feat/issue-346-foo\nfeat: title\nBody.\n' > "$PRFN1"
  out_n1=$(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHN1:/usr/bin:/bin" REPO="owner/repo" \
    CODE_HOST=fbdispnoleaf AUTONOMOUS_PROVIDERS_DIR="$FBDISP_NOLEAF" bash -c "
    source '$SBN1/lib-auth.sh'
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_PR_CREATE_FILE='$PRFN1'
    drain_agent_pr_create 346 owner/repo
  " 2>&1)
  if [[ ! -s "$TRIP1" ]] && printf '%s' "$out_n1" | grep -qF 'refusing to open a GitHub PR on a non-GitHub backend'; then
    assert_pass "TC-FBDISP-010 non-github + leaf-absent: drain_agent_pr_create fails LOUD, NO raw gh pr create executed"
  else
    assert_fail "TC-FBDISP-010 non-github pr-create leaked a gh call or missed the loud error (trip=$(cat "$TRIP1" 2>/dev/null); out=$out_n1)"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-011: non-github + trigger_bot leaf ABSENT (review_bots=1 so the
  # earlier review_bots short-circuit does NOT fire) → loud error, NO raw
  # gh-as-user.sh (tripwire). AC2.
  SBN2=$(fbdisp_sandbox)
  GAUTRIP="$TMPROOT/fbdisp-gautrip.log"; : > "$GAUTRIP"
  printf '#!/bin/bash\nprintf "GAU_TRIPWIRE %%s\\n" "$*" >> "%s"\n' "$GAUTRIP" > "$SBN2/gh-as-user.sh"; chmod +x "$SBN2/gh-as-user.sh"
  GHN2="$TMPROOT/fbdisp-ghn2"; mkdir -p "$GHN2"
  printf '#!/bin/bash\nprintf "GH_TRIPWIRE %%s\\n" "$*" >> "%s"\nexit 0\n' "$GAUTRIP" > "$GHN2/gh"; chmod +x "$GHN2/gh"
  BTFN2="$TMPROOT/fbdisp-btn2"; printf '/q review\n/codex review\n' > "$BTFN2"
  out_n2=$(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHN2:/usr/bin:/bin" REPO="owner/repo" \
    AUTONOMOUS_CONF_DIR="$SBN2" CHP_FBDISP_PR_BODY="closes #346" \
    CODE_HOST=fbdispnoleaf AUTONOMOUS_PROVIDERS_DIR="$FBDISP_NOLEAF" bash -c "
    source '$SBN2/lib-auth.sh'
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_BOT_TRIGGER_FILE='$BTFN2'
    drain_agent_bot_triggers 346 owner/repo \$'/q review\n/codex review'
  " 2>&1)
  if [[ ! -s "$GAUTRIP" ]] && printf '%s' "$out_n2" | grep -qF 'refusing to post a GitHub-user comment on a non-GitHub backend'; then
    assert_pass "TC-FBDISP-011 non-github + leaf-absent: drain_agent_bot_triggers fails LOUD, NO raw gh-as-user.sh executed"
  else
    assert_fail "TC-FBDISP-011 non-github bot-trigger leaked a post or missed the loud error (trip=$(cat "$GAUTRIP" 2>/dev/null); out=$out_n2)"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-012 (#346 review [P1]): non-github + trigger_bot leaf ABSENT +
  # gh-as-user.sh ALSO ABSENT from the project dir → the fail-loud [INV-91] guard
  # must still fire, not the older WARN/skip "project has no gh-as-user.sh" path.
  # Reproduces the exact review repro (CODE_HOST=fbdispnoleaf, no gh-as-user.sh):
  # before the fix, the gh-as-user.sh existence check ran FIRST and short-circuited
  # with a WARN, so the ERROR message never fired even though nothing was posted.
  SBN3=$(fbdisp_sandbox); rm -f "$SBN3/gh-as-user.sh"
  GHN3="$TMPROOT/fbdisp-ghn3"; mkdir -p "$GHN3"
  TRIPN3="$TMPROOT/fbdisp-tripn3.log"; : > "$TRIPN3"
  printf '#!/bin/bash\nprintf "GH_TRIPWIRE %%s\\n" "$*" >> "%s"\nexit 0\n' "$TRIPN3" > "$GHN3/gh"; chmod +x "$GHN3/gh"
  BTFN3="$TMPROOT/fbdisp-btn3"; printf '/q review\n' > "$BTFN3"
  out_n3=$(env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHN3:/usr/bin:/bin" REPO="owner/repo" \
    AUTONOMOUS_CONF_DIR="$SBN3" CHP_FBDISP_PR_BODY="closes #346" \
    CODE_HOST=fbdispnoleaf AUTONOMOUS_PROVIDERS_DIR="$FBDISP_NOLEAF" bash -c "
    source '$SBN3/lib-auth.sh'
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_BOT_TRIGGER_FILE='$BTFN3'
    drain_agent_bot_triggers 346 owner/repo '/q review'
  " 2>&1)
  if [[ ! -s "$TRIPN3" ]] && printf '%s' "$out_n3" | grep -qF 'refusing to post a GitHub-user comment on a non-GitHub backend' \
     && ! printf '%s' "$out_n3" | grep -qF 'project has no gh-as-user.sh'; then
    assert_pass "TC-FBDISP-012 non-github + leaf-absent + gh-as-user.sh ALSO absent: fail-loud [INV-91] guard still fires (not the old WARN/skip)"
  else
    assert_fail "TC-FBDISP-012 hit the old WARN/skip instead of the fail-loud guard (out=$out_n3)"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-020: non-github + create_pr leaf PRESENT → the VERB path is taken
  # (no raw gh). AC2 verb-present.
  SBL1=$(fbdisp_sandbox)
  LEAFLOG1="$TMPROOT/fbdisp-leaf1.log"; : > "$LEAFLOG1"
  TRIPL1="$TMPROOT/fbdisp-tripl1.log"; : > "$TRIPL1"
  GHL1="$TMPROOT/fbdisp-ghl1"; mkdir -p "$GHL1"
  printf '#!/bin/bash\nprintf "GH_RAW %%s\\n" "$*" >> "%s"\nexit 0\n' "$TRIPL1" > "$GHL1/gh"; chmod +x "$GHL1/gh"
  PRFL1="$TMPROOT/fbdisp-prfl1"; printf 'branch: feat/issue-346-foo\nfeat: title\nBody.\n' > "$PRFL1"
  env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHL1:/usr/bin:/bin" REPO="owner/repo" \
    CHP_FBDISP_LEAF_LOG="$LEAFLOG1" CODE_HOST=fbdispleaf AUTONOMOUS_PROVIDERS_DIR="$FBDISP_LEAF" bash -c "
    source '$SBL1/lib-auth.sh'
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_PR_CREATE_FILE='$PRFL1'
    drain_agent_pr_create 346 owner/repo
  " >/dev/null 2>&1
  # W1e (#400): abstract positional contract — the broker passes <head> <title>
  # <body> POSITIONALLY; the non-GitHub leaf records them in the fixture's
  # VERB_CREATE_PR shape (no `--head/--title/--body` flags, which the seam no
  # longer carries; they now live inside the GitHub-only leaf).
  if grep -qF 'VERB_CREATE_PR feat/issue-346-foo feat: title Body.' "$LEAFLOG1" && [[ ! -s "$TRIPL1" ]]; then
    assert_pass "TC-FBDISP-020 non-github + leaf-present: drain_agent_pr_create routes through chp_create_pr (positional <head> <title> <body>, W1e #400)"
  else
    assert_fail "TC-FBDISP-020 verb path not taken (leaf=$(cat "$LEAFLOG1" 2>/dev/null); raw=$(cat "$TRIPL1" 2>/dev/null))"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-021: non-github + trigger_bot leaf PRESENT → the VERB path is taken
  # (no raw gh-as-user.sh). AC2 verb-present.
  SBL2=$(fbdisp_sandbox)
  LEAFLOG2="$TMPROOT/fbdisp-leaf2.log"; : > "$LEAFLOG2"
  GAUL2="$TMPROOT/fbdisp-gaul2.log"; : > "$GAUL2"
  printf '#!/bin/bash\nprintf "GAU_RAW %%s\\n" "$*" >> "%s"\n' "$GAUL2" > "$SBL2/gh-as-user.sh"; chmod +x "$SBL2/gh-as-user.sh"
  GHL2="$TMPROOT/fbdisp-ghl2"; mkdir -p "$GHL2"; printf '#!/bin/bash\nexit 0\n' > "$GHL2/gh"; chmod +x "$GHL2/gh"
  BTFL2="$TMPROOT/fbdisp-btl2"; printf '/q review\n' > "$BTFL2"
  env -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR PATH="$GHL2:/usr/bin:/bin" REPO="owner/repo" \
    AUTONOMOUS_CONF_DIR="$SBL2" CHP_FBDISP_PR_BODY="closes #346" CHP_FBDISP_LEAF_LOG="$LEAFLOG2" \
    CODE_HOST=fbdispleaf AUTONOMOUS_PROVIDERS_DIR="$FBDISP_LEAF" bash -c "
    source '$SBL2/lib-auth.sh'
    AGENT_GH_TOKEN_FILE='/scoped'; AGENT_BOT_TRIGGER_FILE='$BTFL2'
    drain_agent_bot_triggers 346 owner/repo '/q review'
  " >/dev/null 2>&1
  if grep -qF 'VERB_TRIGGER_BOT 4242 /q review' "$LEAFLOG2" && [[ ! -s "$GAUL2" ]]; then
    assert_pass "TC-FBDISP-021 non-github + leaf-present: drain_agent_bot_triggers routes through chp_trigger_bot (no raw gh-as-user.sh)"
  else
    assert_fail "TC-FBDISP-021 verb path not taken (leaf=$(cat "$LEAFLOG2" 2>/dev/null); raw=$(cat "$GAUL2" 2>/dev/null))"
  fi

  # -------------------------------------------------------------------------
  # TC-FBDISP-041: source-shape — both drains gate their raw fallback on
  # `${CODE_HOST:-github}` == "github", and the raw `gh pr create` line is
  # byte-identical to the baselined content. AC3.
  LIB_AUTH_SRC="$SCRIPTS/lib-auth.sh"
  if grep -qF 'elif [[ "${CODE_HOST:-github}" == "github" ]]; then' "$LIB_AUTH_SRC" \
     && grep -qF 'refusing to open a GitHub PR on a non-GitHub backend' "$LIB_AUTH_SRC" \
     && grep -qF 'refusing to post a GitHub-user comment on a non-GitHub backend' "$LIB_AUTH_SRC" \
     && grep -qF '_pr_create_ok() { gh pr create --repo "$repo" --head "$branch" --title "$title" --body "$body" >/dev/null 2>&1; }' "$LIB_AUTH_SRC"; then
    assert_pass "TC-FBDISP-041 source: both drains gate the raw fallback on CODE_HOST==github; raw gh pr create line byte-identical"
  else
    assert_fail "TC-FBDISP-041 source: missing the CODE_HOST==github guard, a loud-error line, or the byte-identical raw gh pr create"
  fi
else
  echo -e "  ${RED}FAIL${NC}: TC-FBDISP fixtures missing ($FBDISP_NOLEAF / $FBDISP_LEAF)"; FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
