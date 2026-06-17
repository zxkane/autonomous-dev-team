#!/bin/bash
# test-token-split-234.sh — Unit tests for INV-77 (issue #234).
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
trap 'rm -rf "$TMPROOT"' EXIT

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

# Full-grant body (no permissions arg) is the pre-INV-77 shape (no permissions key).
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
  # \$5 is the permissions arg ([INV-77]).
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
new_auth_sandbox() {
  local d; d=$(mktemp -d "$TMPROOT/auth-XXXXXX")
  cp "$SCRIPTS/lib-auth.sh" "$d/lib-auth.sh"
  cp "$SCRIPTS/gh-with-token-refresh.sh" "$d/gh-with-token-refresh.sh"
  chmod +x "$d/gh-with-token-refresh.sh"
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
  # Stub daemon: write the (stub) token immediately, then sleep forever.
  cat > "$d/gh-token-refresh-daemon.sh" <<'DAEMON'
#!/bin/bash
echo "SCOPED-TOKEN-abc123" > "$1"
sleep 99999
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
if printf '%s' "$pfx" | grep -qF -- '-u GITHUB_PERSONAL_ACCESS_TOKEN' \
   && printf '%s' "$pfx" | grep -qF -- '-u GH_USER_PAT'; then
  assert_pass "scrub prefix unsets GITHUB_PERSONAL_ACCESS_TOKEN / GH_USER_PAT"
else
  assert_fail "scrub prefix missing a PAT-var unset: $pfx"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-032: scrub prefix does NOT rewrite PATH (#234 review [P1] — keep the gh shim resolvable) ==="
# ---------------------------------------------------------------------------
# The scrub must leave PATH intact so the agent's bare `gh` keeps resolving the
# per-run gh-with-token-refresh.sh shim. A `PATH=` element in the prefix would
# strip the shim dir and break bare `gh` on REAL_GH/non-interactive-PATH hosts.
if ! printf '%s\n' "$pfx" | grep -qE '(^| )PATH='; then
  assert_pass "scrub prefix carries NO PATH= override (PATH left intact, shim stays resolvable)"
else
  assert_fail "scrub prefix rewrites PATH (the #234 [P1] regression — would strip the gh shim): $pfx"
fi
# Source-level lockdown: the dead _strip_path_entry helper must be gone, and
# build_agent_env_argv must not emit a PATH= element.
if ! grep -q '_strip_path_entry' "$SCRIPTS/lib-auth.sh"; then
  assert_pass "source: _strip_path_entry removed (no longer used)"
else
  assert_fail "source: _strip_path_entry still present in lib-auth.sh (dead code / PATH-strip risk)"
fi
if ! awk '/^build_agent_env_argv\(\)/,/^}/' "$SCRIPTS/lib-auth.sh" | grep -q 'PATH='; then
  assert_pass "source: build_agent_env_argv emits no PATH= element"
else
  assert_fail "source: build_agent_env_argv still emits a PATH= element (#234 [P1] regression)"
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
  # Run the stub agent (env) under the timeout wrapper; capture its env dump.
  _run_with_timeout env > '$ENVDUMP' 2>/dev/null
  rm -rf \"\$wdir\"
" >/dev/null 2>&1
WDIR_USED=$(cat "$WDIR_SENTINEL" 2>/dev/null || echo "/tmp/agent-auth-NONE")
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
if ! grep -qE '^GH_USER_PAT=' "$ENVDUMP" 2>/dev/null; then
  assert_pass "agent env has NO GH_USER_PAT (scrubbed)"
else
  assert_fail "agent env still carries GH_USER_PAT — scrub incomplete"
fi
# #234 review [P1]: PATH is now KEPT INTACT — the agent's bare `gh` must keep
# resolving the GH_WRAPPER_DIR shim. Assert the shim dir is STILL on the agent PATH.
path_line=$(grep -E '^PATH=' "$ENVDUMP" 2>/dev/null || true)
if printf '%s' "$path_line" | grep -qF "$WDIR_USED"; then
  assert_pass "agent PATH KEEPS the GH_WRAPPER_DIR shim dir ($WDIR_USED) — bare gh stays resolvable"
else
  assert_fail "agent PATH lost the GH_WRAPPER_DIR shim ($WDIR_USED) — bare gh would break on REAL_GH hosts ([P1] regression): $path_line"
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
if awk '/emit_open_pr_fast_path_block\(\)/,/^}/' "$DEV_SH" | grep -q 'run .*gh pr create'; then
  assert_pass "fast path: unscoped branch keeps direct gh pr create (PAT/no-scope unchanged)"
else
  assert_fail "fast path: unscoped branch lost its direct gh pr create"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-TOKEN-SPLIT-092: under the scrub, the agent's BARE gh resolves the shim → real gh with the SCOPED token (#234 [P1]) ==="
# ---------------------------------------------------------------------------
# The functional proof of the PATH-keep fix: with the scrub applied (GH_TOKEN=scoped,
# GH_TOKEN_FILE pointed at the SCOPED file) and the GH_WRAPPER_DIR shim on PATH, a
# BARE `gh` invocation from the agent must resolve the gh-with-token-refresh.sh shim
# and exec the real gh under the SCOPED token. We model the #92 REAL_GH host: a fake
# "real gh" prints the token it sees + which file the shim read it from, REAL_GH
# points at it, and PATH has the shim dir + only system bins (no real gh dir), so the
# shim is the ONLY resolvable `gh`. Run the bare `gh` under the EXACT env prefix
# build_agent_env_argv produces.
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
  export GH_WRAPPER_DIR=\"\$wdir\"
  ln -sf '$SCRIPTS/gh-with-token-refresh.sh' \"\$wdir/gh\"
  export GH_TOKEN_FILE='/tmp/full-token-file'   # wrapper-side full-write file
  AGENT_GH_TOKEN_FILE=\"\$wdir/agent-token\"; echo 'SCOPED-92' > \"\$AGENT_GH_TOKEN_FILE\"
  declare -a p=(); build_agent_env_argv p
  # Build the agent PATH the way the wrapper does (shim dir prepended), and run a
  # bare \`gh\` under the scrub prefix + REAL_GH (the #92 host). The scrub keeps PATH
  # from the CALLER env, so we set the agent PATH explicitly to shim-dir + system.
  REAL_GH='$GHFAKE/fake-gh' PATH=\"\$wdir:/usr/bin:/bin\" \"\${p[@]}\" gh whoami 2>&1
  rm -rf \"\$wdir\"
")
WDIR92=$(cat "$WDIR92_SENT" 2>/dev/null || echo "/tmp/none")
out92_str="${out92[*]}"
if printf '%s' "$out92_str" | grep -qF 'REALGH token=SCOPED-92' \
   && printf '%s' "$out92_str" | grep -qF "file=${WDIR92}/agent-token" \
   && ! printf '%s' "$out92_str" | grep -qF 'file=/tmp/full-token-file'; then
  assert_pass "bare gh under the scrub → real gh with the SCOPED token, reading the SCOPED file (not the wrapper's full-write file)"
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
  export GH_WRAPPER_DIR=\"\$wdir\"
  ln -sf '$SCRIPTS/gh-with-token-refresh.sh' \"\$wdir/gh\"
  AGENT_GH_TOKEN_FILE=\"\$wdir/agent-token\"; echo 'tok-INITIAL' > \"\$AGENT_GH_TOKEN_FILE\"
  declare -a p=(); build_agent_env_argv p
  REAL_GH='$GHFAKE/fake-gh' PATH=\"\$wdir:/usr/bin:/bin\" \"\${p[@]}\" gh a 2>&1
  echo 'tok-REFRESHED' > \"\$AGENT_GH_TOKEN_FILE\"   # simulate the scoped daemon refresh
  REAL_GH='$GHFAKE/fake-gh' PATH=\"\$wdir:/usr/bin:/bin\" \"\${p[@]}\" gh b 2>&1
  rm -rf \"\$wdir\"
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
# Stub `gh` on PATH: `gh pr list` → 0 (no existing PR); `gh pr create` → record
# args; `gh repo view` → a repo URL (drain uses it for the ls-remote fallback).
GHSB="$TMPROOT/gh-stub"; mkdir -p "$GHSB"
PR_CREATE_LOG="$GHSB/pr-create.log"
cat > "$GHSB/gh" <<GHSTUB
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then echo 0; exit 0; fi
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then echo "https://github.com/owner/repo.git"; exit 0; fi
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then echo "CREATED \$*" >> "$PR_CREATE_LOG"; exit 0; fi
exit 0
GHSTUB
chmod +x "$GHSB/gh"

# The broker file carries an explicit `branch:` line-1 (the #234 [P1] fix: the
# wrapper passes --head so the wrapper's base-branch cwd doesn't break create).
PRFILE="$TMPROOT/agent-pr-create"
printf 'branch: feat/issue-234-foo\nfeat: my title\nBody line.\nCloses #234\n' > "$PRFILE"

# (a) scoping armed + explicit branch → broker fires with --head <branch> + title.
rm -f "$PR_CREATE_LOG"
PATH="$GHSB:$PATH" bash -c "
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
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
