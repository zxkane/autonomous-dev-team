#!/bin/bash
# lib-auth.sh — GitHub authentication abstraction.
# Supports two modes:
#   - "token" (default): uses GH_TOKEN env var or gh auth login
#   - "app": uses GitHub App tokens with background refresh daemon
# Source this file in autonomous-dev.sh and autonomous-review.sh.

# Load project config via the shared helper (closes #58).
# [INV-65] Two-dir resolution. _LIB_AUTH_DIR is the PROJECT-SIDE dir. It is
# load-bearing for THREE things that MUST stay project-side:
#   (1) load_autonomous_conf [INV-14],
#   (2) the shared project-level `${_LIB_AUTH_DIR}/gh` wrapper symlink the
#       *agent* invokes via `bash scripts/gh` (resolving it to the skill tree
#       would put `gh` where the agent can't find it), and
#   (3) spawning the project-side gh-token-refresh-daemon.sh / pointing the
#       `gh` wrapper at the project-side gh-with-token-refresh.sh (both are
#       entry points the installer symlinks into <project>/scripts/).
# Once an entry sources us via its LIB_DIR (the skill tree), ${BASH_SOURCE[0]}
# here IS the skill-tree path — so we take the project-side dir from the entry's
# exported AUTONOMOUS_CONF_DIR, falling back to our own unresolved BASH_SOURCE
# dir for direct/legacy sourcing. _LIB_AUTH_REAL_DIR is the REAL path (readlink
# -f) used ONLY to source siblings (lib-config.sh, gh-app-token.sh) from the
# skill tree so the project needs no per-lib symlink for them (#227).
_LIB_AUTH_SELF="${BASH_SOURCE[0]:-$0}"
_LIB_AUTH_OWN_DIR="$(cd "$(dirname "$_LIB_AUTH_SELF")" && pwd)"
_LIB_AUTH_DIR="${AUTONOMOUS_CONF_DIR:-$_LIB_AUTH_OWN_DIR}"
_LIB_AUTH_REAL_DIR="$(cd "$(dirname "$(readlink -f "$_LIB_AUTH_SELF")")" && pwd)"
# `pwd` (no -P needed for this) always yields an absolute path. Assert it: the
# `gh` wrapper symlink is created in a /tmp dir with ${_LIB_AUTH_DIR}/... as its
# target, so a relative _LIB_AUTH_DIR would produce a symlink that resolves
# relative to /tmp (broken). Fail loud rather than ship a dangling wrapper.
if [[ "$_LIB_AUTH_DIR" != /* ]]; then
  echo "FATAL: lib-auth.sh expected an absolute _LIB_AUTH_DIR, got '${_LIB_AUTH_DIR}'" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=lib-config.sh
source "${_LIB_AUTH_REAL_DIR}/lib-config.sh"
load_autonomous_conf "${_LIB_AUTH_DIR}" || true

# [INV-87] (#282) Code-Host Provider dispatch. The PR-create broker
# (drain_agent_pr_create) and bot-trigger broker (drain_agent_bot_triggers) below
# route their innermost `gh pr create` / real-user bot-trigger-post leaves through
# the `chp_create_pr` / `chp_trigger_bot` verbs (`chp_<verb>` →
# `chp_${CODE_HOST}_<verb>`). LEAF-ONLY swap: the [INV-79] token scoping, the
# AGENT_*_FILE parsing, head resolution, and the bot-trigger allow-list gate all
# stay here unchanged — only the bottom `gh`/`gh-as-user.sh` primitive moves
# behind the verb (the same leaf, byte-identical argv). Sourced from the REAL
# skill tree via readlink -f (`_LIB_AUTH_REAL_DIR`); guarded + idempotent (the
# shims guard their own redefinition).
if ! declare -F chp_create_pr >/dev/null 2>&1 \
   && [ -r "${_LIB_AUTH_REAL_DIR}/lib-code-host.sh" ]; then
  # shellcheck source=lib-code-host.sh
  source "${_LIB_AUTH_REAL_DIR}/lib-code-host.sh"
fi

GH_AUTH_MODE="${GH_AUTH_MODE:-token}"
TOKEN_DAEMON_PID=""
GH_TOKEN_FILE=""
# [INV-32] Per-run /tmp directory holding the `gh` wrapper symlink that this
# run prepends to PATH (for the wrapper's OWN bare `gh` calls). Distinct from
# the shared, project-level `${_LIB_AUTH_DIR}/gh` that the *agent* invokes via
# `bash scripts/gh`. Isolating PATH per-run means a concurrent run's cleanup
# can never delete the `gh` this run resolves (issue #163).
GH_WRAPPER_DIR=""

# [INV-79] Two-token split. The wrapper keeps GH_TOKEN_FILE (full-write); the
# AGENT process gets a SECOND, narrower installation token written here by
# setup_agent_token (app mode only). Empty in PAT mode / app-mode-mint-failure —
# build_agent_env_argv then emits NO scrub prefix (agent inherits the unchanged
# wrapper env, the documented degraded behavior). AGENT_TOKEN_DAEMON_PID tracks
# the second refresh daemon so cleanup_github_auth reaps it alongside the
# wrapper's daemon.
AGENT_GH_TOKEN_FILE=""
AGENT_TOKEN_DAEMON_PID=""
# [INV-79] The AGENT's OWN per-run `gh` shim dir (mode 700), distinct from the
# wrapper's GH_WRAPPER_DIR. It holds a `gh` → gh-with-token-refresh.sh symlink that
# the agent's BARE `gh` resolves through. build_agent_env_argv rewrites the agent
# PATH to STRIP the wrapper's GH_WRAPPER_DIR (issue #234 AC #1: "env dump shows …
# no wrapper gh shim") and PREPEND this agent-owned dir instead — so bare `gh`
# stays resolvable on REAL_GH/non-interactive-PATH hosts (#92) WITHOUT exposing the
# wrapper's shim dir to the agent subtree. Empty when no scoped token is armed.
AGENT_GH_SHIM_DIR=""
# The scoped permissions set the agent token is minted with. contents:write is
# REQUIRED (push branches — a read-only token is factually impossible for dev,
# #234). pull_requests:read is the containment lever: `gh pr review --approve`
# and `gh pr merge` BOTH require pull_requests:write, so the agent token gets a
# deterministic 403 on either — the wrapper (full-write) is the sole approve/
# merge path (INV-44/52). issues:write covers progress comments, checkbox ticks,
# and the E2E report fallback. Operator-overridable but documented as the default.
AGENT_TOKEN_PERMISSIONS="${AGENT_TOKEN_PERMISSIONS:-{\"contents\":\"write\",\"issues\":\"write\",\"pull_requests\":\"read\"}}"
# One-time PAT-mode WARN latch (INV-79): the degraded-enforcement warning is
# logged at most once per process, even across repeated setup_agent_token calls.
_AGENT_TOKEN_PAT_WARNED=""
# [#416 R2] One-time GITLAB_TOKEN PAT-posture WARN latch — parallel to the
# existing GitHub PAT-mode WARN. GitLab has no GitHub-App equivalent (§5.1,
# provider-spec.md:633-651), so agents inherit the wrapper's GITLAB_TOKEN and
# INV-79 containment degrades to convention on the gitlab seam(s).
_AGENT_GITLAB_TOKEN_PAT_WARNED=""

# [#416 R2] github_seam_active — rc 0 iff EITHER seam (ITP or CHP) uses the
# github provider. When BOTH vars are unset the shell defaults them to
# `github`, so the gate is transparent to the pre-change tree.
# Read from ISSUE_PROVIDER / CODE_HOST via ${:-github} defaults; the caller
# layer already threads these vars through every dispatcher/wrapper site.
#
# CONSUMERS (post-P1-2, all four gated by this ONE predicate — no duplicated
# expression anywhere):
#   1. setup_github_auth (below) — the `gh` wrapper install + refresh-daemon
#      spawn + token poll lifecycle.
#   2. setup_agent_token (below) — the scoped agent-token mint / PAT WARN.
#   3. dispatcher-tick.sh — the app-mode DISPATCHER_APP_ID/PEM FATAL.
#   4. autonomous-dev.sh / autonomous-review.sh — the wrapper-level
#      DEV_AGENT_APP_ID / REVIEW_AGENT_APP_ID FATAL, which runs BEFORE
#      setup_github_auth (so the seam gate has to sit at the wrapper's
#      startup site too, not only inside lib-auth.sh — that's what codex
#      round-1 [P1-2] flagged).
#
# On a `gitlab`/`gitlab` topology (both vars set to `gitlab`), the whole
# GitHub auth lifecycle is a clean no-op: no token daemon spawn, no `gh`
# wrapper symlink, no FATAL at any of the four sites. On a mixed
# `github`/`gitlab` or `gitlab`/`github` topology, at least one seam is
# github so the gate opens at every consumer identically.
github_seam_active() {
  local ip="${ISSUE_PROVIDER:-github}" ch="${CODE_HOST:-github}"
  [[ "$ip" == "github" || "$ch" == "github" ]]
}

# Back-compat alias for the pre-P1-2 name (`_github_seam_active`) — kept so
# a stale sibling worktree sourcing this lib still resolves the predicate.
# New call sites use the public name.
_github_seam_active() { github_seam_active; }

# [#416 R2] gitlab_seam_active — rc 0 iff EITHER seam (ITP or CHP) uses the
# gitlab provider. Distinct from github_seam_active (an OR of EQUAL-`github`)
# — a mixed `github`/`gitlab` topology has BOTH `github_seam_active` and
# `gitlab_seam_active` returning true simultaneously. Used by setup_agent_token
# to gate the GitLab PAT-posture WARN.
gitlab_seam_active() {
  local ip="${ISSUE_PROVIDER:-github}" ch="${CODE_HOST:-github}"
  [[ "$ip" == "gitlab" || "$ch" == "gitlab" ]]
}

# Create the per-run GH_WRAPPER_DIR (mode 700) if not already set. Idempotent:
# both auth modes call this, and a second call is a no-op once the dir exists.
_ensure_gh_wrapper_dir() {
  if [[ -z "$GH_WRAPPER_DIR" ]]; then
    GH_WRAPPER_DIR=$(mktemp -d "/tmp/agent-auth-XXXXXX")
    chmod 700 "$GH_WRAPPER_DIR"
  fi
}

# [Lane-GC PR-1] Background-spawn gh-token-refresh-daemon.sh with GH token
# VALUES scrubbed from its env (it only needs GH_TOKEN_FILE paths, passed as
# argv below) — shared by both the wrapper-token and agent-scoped-token spawn
# sites so the scrub prefix has one point of truth. GITHUB_TOKEN is included
# alongside the other three because gh-as-user.sh already treats it as a
# scrub-worthy gh-CLI-recognized token var. Echoes $! via the caller's own
# `$!` (backgrounds in the caller's shell via `&`, same as a bare `bash …&`).
_spawn_token_daemon() {
  # [Lane-GC PR-5 / INV-118] FD hygiene: this is a long-lived background
  # daemon (survives for the whole wrapper run) — close its inherited copy
  # of the guardian write-fd first, else the daemon becomes a permanent
  # second write-holder of the fifo and the guardian never sees EOF even
  # after the wrapper's own copy closes in cleanup(). Wrapped in a subshell
  # (not an inline redirect on `env …`) for the same "ambiguous redirect on
  # an unset brace-fd var" reason documented at the _run_with_timeout spawn
  # site in lib-agent.sh; the trailing `exec` replaces the subshell with
  # `env` (which itself execs bash, which execs the daemon script) so `$!`
  # still resolves to the daemon's real PID, unchanged from the pre-fix
  # bare `env … &` shape.
  (
    [[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-
    exec env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_USER_PAT \
      bash "${_LIB_AUTH_DIR}/gh-token-refresh-daemon.sh" "$@"
  ) &
}

# Setup GitHub authentication based on GH_AUTH_MODE.
# For "app" mode, caller must pass app_id and app_pem.
# Args: $1=app_id (for app mode), $2=app_pem (for app mode)
#
# [#416 R2] Gated on `_github_seam_active` — either seam (ITP or CHP) using
# github triggers the whole lifecycle (`gh` wrapper install + token daemon
# spawn + poll). A `gitlab`/`gitlab` topology returns 0 as a NO-OP (no daemon
# spawn, no wrapper install, no WARN). Under the default (`github`/`github`,
# via `${…:-github}`) this is BYTE-IDENTICAL to pre-#416 behavior.
setup_github_auth() {
  local app_id="${1:-}"
  local app_pem="${2:-}"

  # [#416 R2] Non-github lane — clean no-op. The `gh` wrapper + refresh daemon
  # exist to serve github leaves; a topology with neither seam on github never
  # emits a `gh` call (the [INV-91] caller layer routes through the verb seam).
  if ! github_seam_active; then
    return 0
  fi

  if [[ "$GH_AUTH_MODE" == "app" ]]; then
    if [[ -z "$app_id" || -z "$app_pem" ]]; then
      echo "ERROR: GH_AUTH_MODE=app requires app_id and app_pem arguments" >&2
      return 1
    fi

    # [INV-65] sibling lib sourced from the REAL skill tree (no project symlink
    # needed); the `gh` wrapper symlinks below stay on the project-side
    # _LIB_AUTH_DIR (the agent invokes them via `bash scripts/gh`).
    source "${_LIB_AUTH_REAL_DIR}/gh-app-token.sh"

    # Use a private directory for token files (not predictable /tmp paths).
    # This same per-run dir doubles as GH_WRAPPER_DIR below (the `gh` wrapper
    # symlink lives alongside the token file and is cleaned up with it).
    _ensure_gh_wrapper_dir
    GH_TOKEN_FILE="${GH_WRAPPER_DIR}/token"

    _spawn_token_daemon "$GH_TOKEN_FILE" "$app_id" "$app_pem" "$REPO_OWNER" "$REPO_NAME"
    TOKEN_DAEMON_PID=$!

    # Poll for token file (token generation involves multiple API calls and
    # can take >1s depending on network latency)
    local _wait_max=10
    local _waited=0
    while [[ $_waited -lt $_wait_max ]] && [[ ! -s "$GH_TOKEN_FILE" ]]; do
      sleep 1
      _waited=$((_waited + 1))
    done

    if [[ ! -s "$GH_TOKEN_FILE" ]]; then
      echo "FATAL: Token daemon failed to write initial token after ${_wait_max}s" >&2
      kill "$TOKEN_DAEMON_PID" 2>/dev/null || true
      return 1
    fi

    refresh_token_env
    export GH_TOKEN_FILE
  else
    if [[ -z "${GH_TOKEN:-}" ]]; then
      if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
        echo "WARNING: No GH_TOKEN set and gh auth not configured." >&2
        echo "Run 'export GH_TOKEN=<token>' or 'gh auth login'." >&2
      fi
    fi
  fi

  # [INV-32] Install the `gh` wrapper for BOTH consumers, on two distinct
  # paths (issue #163):
  #
  #   1. The wrapper's OWN bare `gh` calls (autonomous-dev.sh / -review.sh)
  #      resolve through PATH. We point PATH at a per-run /tmp dir
  #      (GH_WRAPPER_DIR) so a concurrent run's cleanup can never delete the
  #      `gh` this run resolves. token mode has no daemon and so didn't yet
  #      create the dir — create it here.
  #
  #   2. The *agent* invokes `bash scripts/gh issue comment …` (a relative
  #      path from PROJECT_DIR, NOT a PATH lookup), so it needs the physical
  #      file ${_LIB_AUTH_DIR}/gh to exist. That is a stable, shared,
  #      project-level artifact: created idempotently AND atomically (temp
  #      symlink + `mv -f`, see below — a bare `ln -sf` would briefly unlink
  #      it under a concurrent reader) and NEVER deleted by a per-run cleanup.
  #      Removing it per-run was the #163 root cause.
  #
  # The wrapper itself (gh-with-token-refresh.sh) is mode-agnostic — it reads
  # GH_TOKEN_FILE only when set (app mode); in token mode it exec's the real
  # gh inheriting the host's auth env (the intended identity). Both modes thus
  # get a working `gh` on PATH and a working `scripts/gh` for the agent. See
  # issues #142 (uniform rule) and #163 (per-run isolation).
  if [[ -x "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" ]]; then
    _ensure_gh_wrapper_dir
    export PATH="${GH_WRAPPER_DIR}:${PATH}"
    # Per-run dir is private to this run — a bare `ln -sf` is fine.
    ln -sf "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" "${GH_WRAPPER_DIR}/gh" 2>/dev/null || true
    # Shared, project-level ${_LIB_AUTH_DIR}/gh: created ATOMICALLY. A bare
    # `ln -sf` unlinks the existing symlink before recreating it, leaving a
    # brief window where a concurrent run's `bash scripts/gh …` sees no file
    # ("No such file or directory"). Build the symlink under a unique temp name
    # in the same dir, then `mv -f` it into place — rename(2) is atomic, so the
    # path is never momentarily absent for concurrent readers.
    local _gh_tmp="${_LIB_AUTH_DIR}/.gh.$$.$RANDOM"
    if ln -s "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" "$_gh_tmp" 2>/dev/null; then
      mv -f "$_gh_tmp" "${_LIB_AUTH_DIR}/gh" 2>/dev/null || rm -f "$_gh_tmp" 2>/dev/null || true
    fi
  fi
}

# Read latest token from file (for app mode).
refresh_token_env() {
  if [[ -n "$GH_TOKEN_FILE" && -s "$GH_TOKEN_FILE" ]]; then
    local token
    token=$(cat "$GH_TOKEN_FILE" 2>/dev/null) || return 1
    export GH_TOKEN="$token"
    export GITHUB_PERSONAL_ACCESS_TOKEN="$token"
  fi
}

# [INV-79] setup_agent_token — mint the SECOND, scoped installation token for the
# agent subprocess and keep it fresh. MUST be called by the wrapper AFTER
# setup_github_auth (it reuses GH_WRAPPER_DIR, created there).
#
# App mode: mints a token down-scoped to AGENT_TOKEN_PERMISSIONS into a separate
# private file (AGENT_GH_TOKEN_FILE, mode 600, inside the per-run GH_WRAPPER_DIR
# mode-700 dir) and starts a second gh-token-refresh-daemon.sh keyed on the same
# permissions so long runs don't expire (INV-31 class). build_agent_env_argv then
# injects this token into the agent subtree while scrubbing the full-write
# credential.
#
# PAT mode: a PAT cannot be down-scoped at mint, so there is no second token.
# Logs ONE WARN (enforcement degraded to convention) and returns 0 — the agent
# keeps the shared PAT (byte-identical to pre-INV-79 behavior).
#
# Args (app mode): $1=app_id, $2=app_pem. Ignored in PAT mode.
# Returns 0 even on a scoped-mint failure (availability over the defense-in-depth
# bonus): a WARN is logged and AGENT_GH_TOKEN_FILE stays empty → no scrub → the
# agent falls back to the full-write env rather than losing GitHub access mid-run.
setup_agent_token() {
  local app_id="${1:-}"
  local app_pem="${2:-}"

  # [#416 R2] Emit the GitLab PAT-posture WARN once per process when a gitlab
  # seam is active AND GITLAB_TOKEN is in the wrapper env. GitLab has no
  # GitHub-App equivalent (§5.1), so agents inherit the wrapper's GITLAB_TOKEN;
  # INV-79 containment degrades to convention on gitlab, mirroring the PAT-mode
  # posture the GitHub PAT WARN below documents. Emitted BEFORE the github gate
  # so a `gitlab`/`gitlab` topology still surfaces it.
  if [[ -z "$_AGENT_GITLAB_TOKEN_PAT_WARNED" ]] \
     && gitlab_seam_active \
     && [[ -n "${GITLAB_TOKEN:-}" ]]; then
    echo "WARN: [INV-79]/[#416 R2] GITLAB_TOKEN is present in the wrapper env — GitLab has no GitHub-App equivalent (§5.1), so a scoped agent mint is impossible; agents inherit the wrapper's GITLAB_TOKEN and INV-79 containment degrades to convention on the gitlab seam (parallel to the GH_AUTH_MODE=token PAT posture)." >&2
    _AGENT_GITLAB_TOKEN_PAT_WARNED=1
  fi

  # [#416 R2] Non-github lane — no scoped github token to mint, no PAT WARN to
  # emit. Return 0 as a NO-OP; the gitlab WARN above (if applicable) is the
  # gitlab-side equivalent.
  if ! github_seam_active; then
    return 0
  fi

  if [[ "$GH_AUTH_MODE" != "app" ]]; then
    if [[ -z "$_AGENT_TOKEN_PAT_WARNED" ]]; then
      echo "WARN: [INV-79] GH_AUTH_MODE=token — a PAT cannot be down-scoped, so agent credential enforcement degraded to convention in PAT mode (agents share the wrapper's token; the PreToolUse hook layer + wrapper gates remain the only approve/merge containment)." >&2
      _AGENT_TOKEN_PAT_WARNED=1
    fi
    return 0
  fi

  if [[ -z "$app_id" || -z "$app_pem" ]]; then
    echo "WARN: [INV-79] setup_agent_token called in app mode without app_id/app_pem — skipping scoped token; the agent will inherit the full-write credential (no env scrub this run)." >&2
    return 0
  fi

  # gh-app-token.sh is sourced by setup_github_auth's app branch; source again
  # defensively (idempotent — only defines functions) in case a caller invokes
  # setup_agent_token without the full setup having sourced it.
  if ! declare -F get_gh_app_scoped_token >/dev/null 2>&1; then
    # shellcheck source=gh-app-token.sh
    source "${_LIB_AUTH_REAL_DIR}/gh-app-token.sh"
  fi

  _ensure_gh_wrapper_dir
  AGENT_GH_TOKEN_FILE="${GH_WRAPPER_DIR}/agent-token"

  _spawn_token_daemon "$AGENT_GH_TOKEN_FILE" "$app_id" "$app_pem" "$REPO_OWNER" "$REPO_NAME" \
    "$AGENT_TOKEN_PERMISSIONS"
  AGENT_TOKEN_DAEMON_PID=$!

  # Poll for the scoped token file (same budget as the full-token poll).
  local _wait_max=10 _waited=0
  while [[ $_waited -lt $_wait_max ]] && [[ ! -s "$AGENT_GH_TOKEN_FILE" ]]; do
    sleep 1
    _waited=$((_waited + 1))
  done

  if [[ ! -s "$AGENT_GH_TOKEN_FILE" ]]; then
    echo "WARN: [INV-79] scoped agent-token daemon failed to write an initial token after ${_wait_max}s — the agent will inherit the full-write credential (no env scrub this run)." >&2
    kill "$AGENT_TOKEN_DAEMON_PID" 2>/dev/null || true
    wait "$AGENT_TOKEN_DAEMON_PID" 2>/dev/null || true
    AGENT_TOKEN_DAEMON_PID=""
    AGENT_GH_TOKEN_FILE=""
    return 0
  fi

  # [INV-79] Create the AGENT's OWN `gh` shim dir (mode 700) holding a `gh` symlink
  # to the same gh-with-token-refresh.sh the wrapper uses. build_agent_env_argv
  # swaps this in for the wrapper's GH_WRAPPER_DIR on the agent PATH, so the agent's
  # bare `gh` resolves WITHOUT the wrapper shim dir being exposed (issue #234 AC #1).
  # Best-effort: a mkdir/symlink failure leaves AGENT_GH_SHIM_DIR empty, and
  # build_agent_env_argv then keeps the wrapper dir on PATH (availability over the
  # AC nicety — bare `gh` must still resolve) and logs the degraded state.
  AGENT_GH_SHIM_DIR=$(mktemp -d "/tmp/agent-shim-XXXXXX" 2>/dev/null) || AGENT_GH_SHIM_DIR=""
  if [[ -n "$AGENT_GH_SHIM_DIR" ]]; then
    chmod 700 "$AGENT_GH_SHIM_DIR" 2>/dev/null || true
    if [[ -x "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" ]] \
       && ln -sf "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" "${AGENT_GH_SHIM_DIR}/gh" 2>/dev/null; then
      :
    else
      echo "WARN: [INV-79] could not create the agent-owned gh shim — falling back to the wrapper shim dir on the agent PATH (bare gh still resolves; AC#1 no-wrapper-shim not met this run)." >&2
      rm -rf "$AGENT_GH_SHIM_DIR" 2>/dev/null || true
      AGENT_GH_SHIM_DIR=""
    fi
  fi
  return 0
}

# [INV-79] build_agent_env_argv — emit, into the array named by $1, the `env`
# argv-prefix that scopes the agent subtree's GitHub credential. Prepended by
# lib-agent.sh::_run_with_timeout to every agent invocation (CLI-agnostic, so it
# applies uniformly across all adapters). The prefix:
#   - points GH_TOKEN_FILE at the SCOPED token file (AGENT_GH_TOKEN_FILE), NOT the
#     wrapper's full-write file — so the agent's `gh` is REFRESH-AWARE: the shim
#     re-reads the scoped file on every call and the scoped refresh daemon keeps it
#     fresh past the 1h App-token TTL (#234 review [P1] — a one-time GH_TOKEN
#     snapshot went stale on long runs and started failing pushes/comments/ticks).
#   - sets GH_TOKEN=<scoped snapshot> as a FALLBACK for any direct `gh` resolution
#     that bypasses the refresh shim (the shim, when GH_TOKEN_FILE is set, re-reads
#     the file and overrides this snapshot — so the file always wins when fresh).
#   - unsets GITHUB_PERSONAL_ACCESS_TOKEN (the App-token alias) AND GH_USER_PAT (the
#     host-user PAT — a scoped agent retaining it could `export GH_TOKEN=$GH_USER_PAT`
#     and regain approve/merge, defeating the contract; #234 review [P1] f97959a3).
#     The agent's only legitimate use of GH_USER_PAT — bot-trigger comments — is now
#     BROKERED through the wrapper (AGENT_BOT_TRIGGER_FILE + drain_agent_bot_triggers).
#
# PATH is REWRITTEN, not left unchanged: the wrapper's per-run GH_WRAPPER_DIR shim
# entry is STRIPPED (issue #234 AC #1: the agent env dump must show "no wrapper gh
# shim"), and the AGENT's OWN shim dir (AGENT_GH_SHIM_DIR) is PREPENDED in its place.
# The agent's BARE `gh` (review prompt's `gh issue view`/`gh pr checks`, vendored
# helpers like mark-issue-checkbox.sh) thus still resolves a `gh` on
# `REAL_GH`/non-interactive-PATH hosts (#92) — it resolves the AGENT-owned shim, NOT
# the wrapper's shim dir. The agent shim is the same gh-with-token-refresh.sh; with
# GH_TOKEN_FILE pointed at the SCOPED file it reads the fresh scoped token each call,
# so bare `gh` authenticates with the SCOPED token (`gh pr review --approve` /
# `gh pr merge` still 403) AND stays fresh on long runs. (`bash scripts/gh` — a
# relative path, not a PATH lookup — resolves the shared project shim independently.)
#
# Degraded shim fallback: if AGENT_GH_SHIM_DIR could not be created (mkdir/symlink
# failure in setup_agent_token), PATH is left intact (the wrapper dir stays) so bare
# `gh` still resolves — availability over the AC nicety; setup_agent_token logged it.
#
# SECURITY: GH_TOKEN_FILE is set to the SCOPED file only; the wrapper's full-write
# token file (a DIFFERENT path, held in the wrapper shell's GH_TOKEN_FILE) is never
# exposed to the agent subtree.
#
# Emits an EMPTY array (length 0 → no behavior change) when no scoped token is
# armed: PAT mode, app-mode-mint-failure, or AGENT_GH_TOKEN_FILE unreadable. The
# caller MUST treat an empty array as "run the agent with the unchanged env".
build_agent_env_argv() {
  local -n _env_out="$1"
  _env_out=()

  # No scoped token → no scrub (PAT mode / mint failure). The agent inherits the
  # wrapper env unchanged, the documented degraded behavior.
  [[ -n "$AGENT_GH_TOKEN_FILE" && -s "$AGENT_GH_TOKEN_FILE" ]] || return 0

  local scoped
  scoped=$(cat "$AGENT_GH_TOKEN_FILE" 2>/dev/null) || return 0
  [[ -n "$scoped" ]] || return 0

  # [INV-79] GH_USER_PAT is SCRUBBED from the agent subtree. It is a host-user PAT
  # (typically `repo`-scoped) — a scoped agent that retained it could
  # `export GH_TOKEN="$GH_USER_PAT"` (or invoke gh-as-user.sh) and regain
  # approve/merge, defeating #234's core contract that the agent gets ONLY the
  # scoped token and the wrapper is the SOLE approve/merge path (#234 review [P1],
  # session f97959a3). The agent's only legitimate use of GH_USER_PAT is posting
  # bot-trigger comments (`/q review` etc.); those are now BROKERED — the agent
  # writes trigger requests to AGENT_BOT_TRIGGER_FILE and the WRAPPER posts them via
  # gh-as-user.sh post-run (drain_agent_bot_triggers), keeping the PAT in the
  # wrapper shell only. GITHUB_PERSONAL_ACCESS_TOKEN (the App-token alias) is also
  # unset; the App token is scoped via GH_TOKEN_FILE / GH_TOKEN below.
  _env_out=(
    env
    -u GITHUB_PERSONAL_ACCESS_TOKEN
    -u GH_USER_PAT
    "GH_TOKEN_FILE=${AGENT_GH_TOKEN_FILE}"
    "GH_TOKEN=${scoped}"
  )

  # [INV-79] Rewrite PATH: strip the wrapper's GH_WRAPPER_DIR (AC #1 — no wrapper
  # shim in the agent env) and prepend the AGENT-owned shim dir so bare `gh` still
  # resolves. Only when the agent shim was created; otherwise leave PATH intact
  # (degraded fallback — bare `gh` must still resolve).
  if [[ -n "$AGENT_GH_SHIM_DIR" ]]; then
    local _agent_path
    _agent_path=$(_strip_path_entry "$PATH" "$GH_WRAPPER_DIR")
    _env_out+=( "PATH=${AGENT_GH_SHIM_DIR}:${_agent_path}" )
  fi
}

# _strip_path_entry <path> <entry> — echo <path> with any exact-match <entry>
# colon-segment removed, order + remaining segments preserved. Empty <entry>
# returns <path> unchanged. Pure string op (no PATH lookups). Used by
# build_agent_env_argv to remove the wrapper's GH_WRAPPER_DIR from the agent PATH.
_strip_path_entry() {
  local path="$1" entry="$2"
  [[ -n "$entry" ]] || { printf '%s' "$path"; return 0; }
  local out="" seg
  local IFS=':'
  for seg in $path; do
    [[ "$seg" == "$entry" ]] && continue
    if [[ -z "$out" ]]; then out="$seg"; else out="${out}:${seg}"; fi
  done
  printf '%s' "$out"
}

# [INV-111] (#402 review round-1 [P1]) rearm_gh_resolution — re-arm `gh`
# resolution against a vanished per-run auth shim dir (GH_WRAPPER_DIR). Call
# this immediately before EACH load-bearing `gh`-touching write in a cleanup
# sequence, not once at cleanup entry: the #402 incident proved the shim dir
# can vanish AT ANY POINT mid-cleanup (alive at a token-daemon refresh, gone
# nine minutes later) — an entry-time-only probe can pass and never re-arm
# for a later write in the SAME shell.
#
# Two independent, idempotent steps, safe to call unconditionally on every
# write:
#   1. `hash -d gh` unconditionally. Bash's command hash caches a resolved
#      binary's path and is NOT invalidated when that path's file disappears
#      (PATH is only re-searched when there is no cached location, never
#      when a cached one stops existing). Dropping the hash is cheap and
#      harmless even when the shim is alive — the very next `gh` call just
#      re-resolves via a fresh PATH search and re-hashes the SAME shim path.
#      `|| true` is load-bearing under `set -euo pipefail`: `hash -d`'s rc on
#      an unhashed name is version-dependent.
#   2. Strip the dead GH_WRAPPER_DIR PATH entry — but ONLY when it is
#      actually dead (`[[ ! -x "${GH_WRAPPER_DIR}/gh" ]]`). Unlike the hash
#      drop, this step is conditional: stripping a STILL-ALIVE shim entry
#      would silently downgrade every subsequent `gh` call from the
#      auto-refreshing shim to a static `GH_TOKEN` snapshot, losing the
#      shim's whole reason to exist. Skipped entirely when GH_WRAPPER_DIR was
#      never set (no scoping / no shim armed this run).
#
# Command-substitution subshells inherit the parent shell's hash table, so a
# parent-shell call also covers `$(...)`-invoked `gh` calls and sourced
# provider functions.
rearm_gh_resolution() {
  # Quoted 'gh' argument (not a bare token): the [INV-91] cutover guard
  # (check-provider-cutover.sh) scans for raw `gh ` call sites (token +
  # trailing space) tree-wide, and an unquoted `hash -d gh` would false-
  # positive as an unbaselined raw-gh site. Quoting is byte-identical to bash.
  hash -d 'gh' 2>/dev/null || true
  if [[ -n "${GH_WRAPPER_DIR:-}" ]] && [[ ! -x "${GH_WRAPPER_DIR}/gh" ]]; then
    echo "WARN: [INV-111] GH_WRAPPER_DIR (${GH_WRAPPER_DIR}) is gone — dropped the stale 'gh' command hash and PATH entry so this write falls back to the system 'gh'." >&2
    PATH="$(_strip_path_entry "$PATH" "$GH_WRAPPER_DIR")"
    export PATH
  fi
}

# [INV-79]/#519 provision_agent_pr_create_file <issue> — provision the broker
# request file at its DURABLE location and export AGENT_PR_CREATE_FILE.
#
# The file must NOT live inside GH_WRAPPER_DIR: that per-run auth dir is
# documented (INV-111/#402) to vanish mid-cleanup from an external deleter,
# and a vanished request file made the drain below silently skip a valid,
# fully-verified PR request — three clean runs then burned the no-PR retry
# budget to `stalled` (#519). The INV-81 RUN_DIR survives the run (pruned
# only by RUN_RETENTION_DAYS), so the request rides there; the private
# mktemp fallback covers a wrapper without run artifacts. Pre-created empty
# with mode 0600 so the mode never depends on the agent's umask; the drain
# never deletes it (post-hoc diagnosis of this bug class depends on the
# artifact surviving the run).
provision_agent_pr_create_file() {
  local issue="$1"
  if [[ -n "${RUN_DIR:-}" && -d "${RUN_DIR}" && -w "${RUN_DIR}" ]]; then
    AGENT_PR_CREATE_FILE="${RUN_DIR}/agent-pr-create"
  else
    # Split declare+assign so the mktemp exit status isn't masked (SC2155). A
    # mktemp failure is benign — the drain's guard treats a missing file as a
    # missing request.
    AGENT_PR_CREATE_FILE="$(mktemp "/tmp/agent-pr-create-${issue}-XXXXXX" 2>/dev/null)" \
      || AGENT_PR_CREATE_FILE=""
  fi
  if [[ -n "$AGENT_PR_CREATE_FILE" ]]; then
    # Both fail SAFE toward "no request": an unwritable path leaves the file
    # absent/empty, which the drain's `-s` guard reads as a missing request
    # (WARN + recovery) — never a wrapper-startup crash.
    : > "$AGENT_PR_CREATE_FILE" 2>/dev/null || true
    chmod 600 "$AGENT_PR_CREATE_FILE" 2>/dev/null || true
  fi
  export AGENT_PR_CREATE_FILE
}

# [INV-79]/#519 _pr_broker_create_leaf <issue> <repo> <branch> <title> <body> —
# the shared create leaf used by the normal brokered path AND the #519
# recovery fallback (so the two cannot drift). Owns the whole leaf selection:
#
#   [INV-87] (#282, W1e-abstracted #400) the `gh pr create` leaf sits behind
#   chp_create_pr — the verb takes THREE POSITIONALS `<head-branch> <title>
#   <body>` (#347/#400); the GitHub leaf owns the `--head/--title/--body` flags
#   internally, emitting argv IDENTICAL to the pre-#400 broker-composed line.
#   The guard is `chp_has_leaf`, NOT `declare -F chp_create_pr` — the shim is
#   always defined once lib-code-host is sourced, so the latter would dispatch
#   to an undefined leaf and abort under set -e on a backend without it (#282
#   review round 4 [P1]).
#
#   [INV-91] (#346) fail-loud when the leaf is absent: the raw `gh pr create`
#   fallback is retained ONLY under an explicit `CODE_HOST == github` guard
#   (spec-sanctioned github-gated residue). A non-GitHub backend that omits the
#   `create_pr` leaf must NOT silently open a GitHub PR — it fails LOUD (#303/B1
#   + #327 no-silent-fallback) and creates no PR. `${CODE_HOST:-github}` (#327
#   precedent): an unset CODE_HOST — lib-code-host.sh not sourced because
#   chp_create_pr was already defined, or unreadable — defaults to `github`,
#   today's exact behavior. The raw `gh pr create` line stays BYTE-IDENTICAL
#   (cutover-baseline pinned; the baseline may only shrink) — hence the
#   _pr_create_ok indirection shape.
#
# rc 0 = created; rc 1 = create attempt failed; rc 2 = no usable leaf
# (already logged loudly).
_pr_broker_create_leaf() {
  local issue_number="$1" repo="$2" branch="$3" title="$4" body="$5"
  if declare -F chp_has_leaf >/dev/null 2>&1 && chp_has_leaf create_pr; then
    _pr_create_ok() { chp_create_pr "$branch" "$title" "$body" >/dev/null 2>&1; }
  elif [[ "${CODE_HOST:-github}" == "github" ]]; then
    _pr_create_ok() { gh pr create --repo "$repo" --head "$branch" --title "$title" --body "$body" >/dev/null 2>&1; }
  else
    echo "ERROR: [INV-79]/[INV-91] brokered PR create for issue #${issue_number} (head=${branch}): CODE_HOST='${CODE_HOST:-github}' has no chp_create_pr leaf — refusing to open a GitHub PR on a non-GitHub backend. NO PR created; the success path's no-PR retry will re-queue the issue to pending-dev." >&2
    unset -f _pr_create_ok 2>/dev/null || true  # fails harmless: fn may be undefined on this arm; leftover defs are per-call overwritten
    return 2
  fi
  local _rc=0
  _pr_create_ok || _rc=1
  unset -f _pr_create_ok
  return "$_rc"
}

# [INV-79]/#519 _pr_broker_recover <issue> <repo> <title> <pr_list_ok> —
# single-branch recovery fallback for a LOST broker request. Runs only from
# drain_agent_pr_create's missing/empty-request branch. Deliberately STRICTER
# than the normal path (recovery auto-opens a PR nobody reviewed the request
# for):
#   - pr_list_ok != 1 (the existence read was UNKNOWN) → never create;
#     "never duplicate" outranks the normal path's fail-soft existing=0.
#   - candidate refs must pass the numeric boundary `issue-<N>([^0-9]|$)`
#     (the raw glob would let issue-12 claim an issue-123 branch; same
#     boundary needs_open_pr_only applies).
#   - EXACTLY one candidate, and it must be STRICTLY AHEAD of the resolved
#     [INV-131] base branch: ancestry REQUIRED (merge-base --is-ancestor) +
#     rev-list count > 0. No SHA-inequality fallback — a diverged branch
#     needs a human.
# The recovery body carries `Closes #<N>` and a FIXED note with no other
# numeric `#` reference (body #N-mention selectors treat any match as PR
# existence). Always returns 0 (fail-safe, like the drain itself).
_pr_broker_recover() {
  local issue_number="$1" repo="$2" issue_title="$3" pr_list_ok="$4"

  if [[ "$pr_list_ok" != "1" ]]; then
    echo "WARN: [INV-79]/#519 recovery skipped for issue #${issue_number}: the PR-existence read was UNKNOWN (chp_pr_list failed/unparseable) — never-duplicate outranks recovery. The no-PR retry re-queues to pending-dev." >&2
    return 0
  fi

  # Resolve the [INV-131] base branch — exported by the wrapper; fall back to
  # resolve_base_branch when sourced standalone. No branch resolvable → skip.
  local base="${BASE_BRANCH:-}"
  if [[ -z "$base" ]] && declare -F resolve_base_branch >/dev/null 2>&1; then
    base="$(resolve_base_branch 2>/dev/null)" || base=""
  fi
  if [[ -z "$base" ]]; then
    echo "WARN: [INV-79]/#519 recovery skipped for issue #${issue_number}: no resolvable base branch (BASE_BRANCH unset and resolve_base_branch unavailable)." >&2
    return 0
  fi

  # Enumerate boundary-valid pushed candidates as "<sha> <branch>" pairs.
  local -a cand_shas=() cand_branches=()
  local _ls_line _sha _ref
  while IFS= read -r _ls_line; do
    [[ -n "$_ls_line" ]] || continue
    _sha="${_ls_line%%$'\t'*}"
    _ref="${_ls_line##*$'\t'}"
    _ref="${_ref#refs/heads/}"
    # Numeric boundary (see the header) — bash-native ERE, no fork per candidate.
    [[ "$_ref" =~ issue-${issue_number}([^0-9]|$) ]] || continue
    cand_shas+=("$_sha")
    cand_branches+=("$_ref")
  # `|| true`: an ls-remote failure fails SAFE to zero candidates → the
  # count-≠-1 WARN below skips recovery (never a create from unknown state).
  done < <(git ls-remote --heads origin "*issue-${issue_number}*" 2>/dev/null || true)

  local count="${#cand_branches[@]}"
  if [[ "$count" -ne 1 ]]; then
    echo "WARN: [INV-79]/#519 recovery skipped for issue #${issue_number}: ${count} boundary-valid candidate branch(es) on origin — recovery requires exactly one and never selects among ambiguous branches. The no-PR retry re-queues to pending-dev." >&2
    return 0
  fi
  local branch="${cand_branches[0]}" cand_sha="${cand_shas[0]}"

  # Strictly-ahead check against the CURRENT remote base (a local origin/<base>
  # ref may be stale, and fetching a head does not refresh it): resolve the
  # remote base SHA, fetch both refs' objects, then require ancestry + a
  # non-zero ahead count.
  local base_sha
  base_sha=$(git ls-remote origin "refs/heads/${base}" 2>/dev/null \
    | head -n1 | cut -f1) || base_sha=""
  if [[ -z "$base_sha" ]]; then
    echo "WARN: [INV-79]/#519 recovery skipped for issue #${issue_number}: cannot resolve remote base branch '${base}' on origin." >&2
    return 0
  fi
  # `|| true`: a fetch failure fails SAFE — the ancestry check below then
  # cannot prove ahead-ness and recovery is skipped (never a blind create).
  git fetch -q origin "refs/heads/${branch}" "refs/heads/${base}" 2>/dev/null || true
  local ahead=0
  if git merge-base --is-ancestor "$base_sha" "$cand_sha" 2>/dev/null; then
    ahead=$(git rev-list --count "${base_sha}..${cand_sha}" 2>/dev/null) || ahead=0
  fi
  [[ "$ahead" =~ ^[0-9]+$ ]] || ahead=0
  if [[ "$ahead" -eq 0 ]]; then
    echo "WARN: [INV-79]/#519 recovery skipped for issue #${issue_number}: candidate '${branch}' is not strictly ahead of base '${base}' (diverged, equal, or unreadable) — a non-fast-forward candidate needs a human. The no-PR retry re-queues to pending-dev." >&2
    return 0
  fi

  # Deterministic fallback title when the wrapper couldn't supply one. No `#`
  # anywhere outside the body's Closes line.
  local title="$issue_title"
  [[ -n "$title" ]] || title="fix: recovered PR for issue ${issue_number} (broker request lost)"
  local body="Closes #${issue_number}

> Recovery PR opened by the dev wrapper's PR-create broker: the agent's
> brokered request file was lost after a verified push, and exactly one
> pushed issue branch is strictly ahead of the base branch. See the INV-79
> broker-durability amendment in the pipeline invariants doc."

  local _rc=0
  _pr_broker_create_leaf "$issue_number" "$repo" "$branch" "$title" "$body" || _rc=$?
  if [[ "$_rc" -eq 0 ]]; then
    echo "[INV-79]/#519 recovery: wrapper opened the PR for issue #${issue_number} from the unique pushed branch '${branch}' (${ahead} commit(s) ahead of ${base}; the brokered request file was lost)." >&2
  elif [[ "$_rc" -eq 1 ]]; then
    echo "WARN: [INV-79]/#519 recovery PR create (head=${branch}) failed — the no-PR retry re-queues to pending-dev." >&2
  fi
  return 0
}

# [INV-79] drain_agent_pr_create — the narrow PR-CREATE broker. `gh pr create`
# requires pull_requests:write, which the scoped agent token (pull_requests:read)
# does NOT have — but the agent must still be able to open its PR. So when the
# scoped token is armed, the dev prompt tells the agent to WRITE the PR head
# branch + title + body to AGENT_PR_CREATE_FILE instead of running `gh pr create`,
# and the WRAPPER (full-write) opens the PR here. This brokers EXACTLY one
# operation (pr create), distinct from the out-of-scope "allow-list shim for
# arbitrary agent writes".
#
# File format (the agent writes it):
#   line 1: `branch: <head-branch>`   (REQUIRED — the agent's pushed feature
#                                       branch; see "head resolution" below)
#   line 2: <PR title>
#   line 3+: <PR body>                (include "Closes #<issue>")
#
# Head resolution (the #234 review [P1] fix): the wrapper runs from PROJECT_DIR,
# whose checkout stays on the BASE branch (main) — the agent's commits live on a
# feature branch pushed to origin from a separate worktree. A bare `gh pr create`
# (no --head) would infer head=main and fail ("no commits between main and main").
# So we MUST pass an explicit --head: the agent's `branch:` line when present,
# else derive the pushed `*issue-<N>*` branch from origin (the same glob the
# [INV-45] open-PR fast path uses). If neither yields a branch, we skip with a
# WARN rather than create a doomed same-branch PR.
#
# Fail-safe + idempotent: a no-op unless ALL hold — scoped token armed
# (AGENT_GH_TOKEN_FILE set), AGENT_PR_CREATE_FILE set + non-empty, and NO PR yet
# exists for this issue (the agent may have created it directly in an
# app-mode-without-scoping / PAT run, or a prior tick did). Returns 0 always; a
# `gh pr create` failure is logged (the success path's no-PR retry still applies).
#
# Args: $1=issue_number, $2=repo, $3=issue title (optional — the wrapper's
# already-fetched normalized title, used only by the #519 recovery fallback's
# synthesized PR; the drain never fetches it itself).
# Reads AGENT_GH_TOKEN_FILE / AGENT_PR_CREATE_FILE.
drain_agent_pr_create() {
  local issue_number="$1" repo="$2" issue_title="${3-}"
  # Only relevant when scoping is active (app mode + scoped mint succeeded).
  # This unscoped return stays SILENT on purpose (#519 D2): scoping off means
  # the broker was never in play — the agent ran `gh pr create` itself. The
  # guard is shared by the normal and SIGTERM cleanup paths, and a vanished
  # auth DIR leaves this VARIABLE non-empty, so the loud diagnostics below
  # stay reachable in the INV-111-style incident.
  [[ -n "$AGENT_GH_TOKEN_FILE" ]] || return 0

  # Existence check FIRST (#519 D2 reordering): an existing PR makes a
  # missing request harmless, so it must return silently BEFORE the
  # missing-request diagnostics. Same body-#N selector the wrapper's
  # PR_EXISTS uses.
  # [INV-87]/[INV-91] (W1c1, #397) the body-mention existence read routes
  # through the ABSTRACT `chp_pr_list STATE FIELDS-CSV` contract (spec §3.2 /
  # provider-spec §3.5 COMPLETE-set); body is normalized to a string so the
  # `.body != null` guard is redundant (the #148-class fix). Fail-soft
  # (`|| existing=0`) — a transient read error routes conservative for the
  # NORMAL request path (assume no existing PR ⇒ let the broker attempt
  # create; a same-branch `gh pr create` against an already-open PR errors
  # LOUDLY, still no double-open). The #519 recovery path is the opposite:
  # it requires a SUCCESSFUL zero-match read (`_pr_list_ok`) — recovery
  # synthesizes a PR nobody staged a request for, so "never duplicate"
  # outranks fail-soft there.
  local existing _pr_list _pr_list_ok=0
  if _pr_list=$(chp_pr_list open "body" 2>/dev/null) && [[ -n "$_pr_list" ]]; then
    if existing=$(jq -r "[.[] | select((.body | test(\"#${issue_number}[^0-9]\")) or (.body | test(\"#${issue_number}\$\")))] | length" <<<"$_pr_list" 2>/dev/null); then
      _pr_list_ok=1
    else
      existing=0
    fi
  else
    existing=0
  fi
  [[ "$existing" =~ ^[0-9]+$ ]] || { existing=0; _pr_list_ok=0; }
  if [[ "$existing" -gt 0 ]]; then
    return 0
  fi

  # #519 D2: a scoped run reaching this point with NO usable request is the
  # silent-loss incident shape — say so loudly (path/existence/size only;
  # never request content, never credentials), then attempt the D3 recovery.
  if [[ -z "${AGENT_PR_CREATE_FILE:-}" || ! -s "${AGENT_PR_CREATE_FILE:-}" ]]; then
    local _diag
    if [[ -z "${AGENT_PR_CREATE_FILE:-}" ]]; then
      _diag="path=<unset> exists=no size=unknown"
    elif [[ ! -e "${AGENT_PR_CREATE_FILE}" ]]; then
      _diag="path=${AGENT_PR_CREATE_FILE} exists=no size=unknown"
    else
      _diag="path=${AGENT_PR_CREATE_FILE} exists=yes size=0"
    fi
    echo "WARN: [INV-79]/#519 scoped run reached the PR broker with no usable request (${_diag}) and no PR exists for issue #${issue_number} — the agent's brokered request was never written or was lost. Attempting single-branch recovery." >&2
    _pr_broker_recover "$issue_number" "$repo" "$issue_title" "$_pr_list_ok"
    return 0
  fi

  # Parse the broker file. An optional leading `branch: <name>` line carries the
  # explicit head; when present it is consumed and the title/body follow.
  local first branch title body
  first=$(head -n1 "${AGENT_PR_CREATE_FILE}" 2>/dev/null || true)
  if [[ "$first" =~ ^branch:[[:space:]]*(.+)$ ]]; then
    branch="${BASH_REMATCH[1]}"
    # Trim trailing whitespace from the captured branch.
    branch="${branch%"${branch##*[![:space:]]}"}"
    title=$(sed -n '2p' "${AGENT_PR_CREATE_FILE}" 2>/dev/null || true)
    body=$(tail -n +3 "${AGENT_PR_CREATE_FILE}" 2>/dev/null || true)
  else
    branch=""
    title="$first"
    body=$(tail -n +2 "${AGENT_PR_CREATE_FILE}" 2>/dev/null || true)
  fi
  [[ -n "$title" ]] || { echo "WARN: [INV-79] AGENT_PR_CREATE_FILE present but empty title — skipping brokered PR create." >&2; return 0; }

  # No explicit branch → derive the pushed feature branch from `origin` (the same
  # `*issue-<N>*` glob + the same `origin` remote name [INV-45] trusts directly at
  # autonomous-dev.sh:397). `git ls-remote` is git-transport plumbing, not code-host
  # REST/CLI I/O, so [INV-91]'s provider seam does not own it and no verb is minted
  # (#316). The prior repo-view-resolved clone URL (and its hand-built HTTPS
  # fallback) are deleted: `origin` reliably resolves to `$repo` here because the
  # wrapper runs in PROJECT_DIR — the same checkout whose `origin` [INV-45]'s 397
  # trusts unconditionally (a PROJECT_DIR whose `origin` ≠ target repo is an invalid
  # deployment state that would already break that discovery). Take the first match;
  # strip the refs/heads/ prefix. Empty when no such branch was pushed.
  if [[ -z "$branch" ]]; then
    branch=$(git ls-remote --heads origin "*issue-${issue_number}*" 2>/dev/null \
      | head -n1 | sed -E 's#^[0-9a-f]+[[:space:]]+refs/heads/##' || true)
  fi
  if [[ -z "$branch" ]]; then
    # Surface the resolved `origin` URL so a MISCONFIGURED origin (≠ target repo) is
    # distinguishable from a genuine "no pushed branch" (#316 observability hedge).
    # MUST be `set -e`-safe (`|| true`) and MUST NOT leak credentials — a
    # token-bearing HTTPS origin (`https://x-access-token:<token>@github.com/…`) is
    # redacted at the userinfo before it reaches the log.
    local origin_for_log
    origin_for_log=$(git remote get-url origin 2>/dev/null || true)
    origin_for_log="${origin_for_log/#https:\/\/*@/https://<redacted>@}"
    echo "WARN: [INV-79] brokered PR create: no head branch (no \`branch:\` line and no pushed *issue-${issue_number}* branch on origin=${origin_for_log:-<unknown>}) — skipping; the no-PR retry re-queues to pending-dev." >&2
    return 0
  fi

  # Explicit head: the wrapper's cwd (PROJECT_DIR) is on the base branch, so a
  # bare create would infer the wrong head (#234 [P1]). ALL of the INV-79 broker
  # logic above (token scoping, file parse, head resolution, the no-PR-yet
  # idempotency guard) is unchanged; `$REPO` is the wrapper's required env (the
  # broker's `$repo` arg always equals it). The [INV-87]/[INV-91] leaf selection
  # (chp_create_pr / github-gated raw-gh / fail-loud) lives in the shared
  # _pr_broker_create_leaf so this normal path and the #519 recovery fallback
  # cannot drift. #519 D3: a failed normal create does NOT trigger recovery (no
  # second create after a create attempt).
  local _create_rc=0
  _pr_broker_create_leaf "$issue_number" "$repo" "$branch" "$title" "$body" || _create_rc=$?
  if [[ "$_create_rc" -eq 0 ]]; then
    echo "[INV-79] wrapper brokered the PR create for issue #${issue_number} (head=${branch}, agent wrote ${AGENT_PR_CREATE_FILE})." >&2
  elif [[ "$_create_rc" -eq 1 ]]; then
    echo "WARN: [INV-79] brokered PR create (head=${branch}) failed — the success path's no-PR retry will re-queue the issue to pending-dev." >&2
  fi
  return 0
}

# [INV-79] drain_agent_bot_triggers — the bot-trigger broker. The built-in review
# bots (`/q review`, `/codex review`, `@claude review`) reject GitHub-App-attributed
# comments, so the trigger must be posted by a REAL user via gh-as-user.sh (which
# reads GH_USER_PAT). But GH_USER_PAT is SCRUBBED from the agent subtree (#234 review
# [P1] f97959a3 — a scoped agent retaining it could regain approve/merge), so the
# agent can no longer post the trigger itself. Instead the agent WRITES the trigger
# phrase(s) to AGENT_BOT_TRIGGER_FILE and the WRAPPER (which has GH_USER_PAT in its
# own shell) posts them here, post-run, via gh-as-user.sh — keeping the PAT in the
# wrapper only. Narrow broker: exactly bot-trigger PR comments, distinct from the
# out-of-scope "allow-list shim for arbitrary agent writes".
#
# File format (the agent writes it): one trigger phrase per line, e.g.
#   /q review
#   /codex review
# Blank lines and `#`-comment lines are ignored. Each phrase is posted as a PR
# comment on the issue's PR. The wrapper resolves the PR number itself (same
# body-#N selector as PR_EXISTS) — the agent does not need to know it.
#
# ALLOW-LIST (#234 review [P1]): the broker is a "review-bot trigger ONLY" exception,
# not an arbitrary-comment channel. The caller passes $3 = the EXACT allowed trigger
# phrases (newline-separated — from lib-review-bots.sh::bot_trigger_allowlist). A
# line is posted ONLY if it EXACTLY matches an allowed phrase; any other line is
# REJECTED with a WARN and never reaches gh-as-user.sh. An empty/absent allow-list
# means "no triggers permitted" → nothing is posted (fail-closed): a scoped agent
# cannot make the wrapper emit a user-attributed comment of its choosing.
#
# Fail-safe + idempotent: a no-op unless the scoped token is armed
# (AGENT_GH_TOKEN_FILE set — so this only brokers in the scrubbed-agent case) AND
# AGENT_BOT_TRIGGER_FILE is set + non-empty AND a PR exists. Returns 0 always; a
# failed post is logged, not fatal. gh-as-user.sh resolves via _LIB_AUTH_DIR (the
# project-side scripts dir), the same place the agent's `bash scripts/gh-as-user.sh`
# would have found it.
#
# Args: $1=issue_number, $2=repo, $3=allowlist (newline-separated exact phrases).
# Reads AGENT_GH_TOKEN_FILE / AGENT_BOT_TRIGGER_FILE.
drain_agent_bot_triggers() {
  local issue_number="$1" repo="$2" allowlist="${3:-}"
  [[ -n "$AGENT_GH_TOKEN_FILE" ]] || return 0
  [[ -n "${AGENT_BOT_TRIGGER_FILE:-}" && -s "${AGENT_BOT_TRIGGER_FILE}" ]] || return 0

  # [INV-87]/§4.2 review_bots capability gate (#282 review [P1]): slash-command
  # review-bot triggers are only meaningful when the code host has a custom-slash
  # registry. On a `review_bots=0` backend (e.g. GitLab; the degraded fake fixture)
  # chp_trigger_bot is a no-op, so posting the triggers would be pointless and the
  # caller would then wait for bot reviews that can never arrive. Short-circuit the
  # whole broker here. GitHub (review_bots=1) takes the unchanged path. The cap
  # reader degrades to "1" (today's GitHub behavior) when chp_caps is unavailable,
  # so a lib-load failure leaves the legacy path intact.
  if declare -F chp_caps >/dev/null 2>&1 && [[ "$(chp_caps review_bots 2>/dev/null || echo 1)" != "1" ]]; then
    echo "[INV-87] code host review_bots=0 — skipping bot-trigger broker (no slash-command registry)." >&2
    return 0
  fi

  # Resolve the PR number for this issue (same body-#N selector as PR_EXISTS).
  # [INV-87]/[INV-91] (W1c1, #397) routes through the ABSTRACT chp_pr_list
  # contract. Body is normalized to a string so the `.body != null` guard is
  # redundant (the #148-class fix); the #N-boundary regex stays here.
  # Fail-soft (`|| true`) — a transient read error just skips the bot-trigger
  # broker for this run (the wrapper posts a WARN below).
  local pr_number _pr_list
  _pr_list=$(chp_pr_list open "number,body" 2>/dev/null || true)
  if [[ -n "$_pr_list" ]]; then
    pr_number=$(jq -r "[.[] | select((.body | test(\"#${issue_number}[^0-9]\")) or (.body | test(\"#${issue_number}\$\")))] | (.[0].number // empty)" <<<"$_pr_list" 2>/dev/null || true)
  else
    pr_number=""
  fi
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "WARN: [INV-79] agent requested bot triggers but no open PR found for issue #${issue_number} — skipping." >&2
    return 0
  fi

  # [INV-91] (#346) fail-loud disposition for the leaf-absent case. The per-line
  # raw `gh-as-user.sh` fallback below is retained ONLY under `CODE_HOST == github`
  # (spec-sanctioned github-gated residue): a non-GitHub backend that omits the
  # `trigger_bot` leaf must NOT silently post a GitHub-user comment. The backend
  # decision is identity-based, not per-line, so it is gated ONCE here — before the
  # gh-as-user.sh existence check below AND before the posting loop (#346 review
  # [P1]: it must run BEFORE that existence check, or a non-GitHub project that
  # simply has no gh-as-user.sh file hits the old WARN/skip path instead of this
  # ERROR) — so a non-GitHub + leaf-absent broker emits one loud error and posts
  # nothing, regardless of whether gh-as-user.sh happens to be present on disk.
  # `${CODE_HOST:-github}` (the #327 precedent): an unset CODE_HOST defaults to
  # `github`, i.e. today's exact behavior — the raw path is retained on the
  # github/github topology with zero behavior change. (A `review_bots=0` backend
  # already short-circuited above; this gate covers a `review_bots=1` non-GitHub
  # backend whose provider omits the trigger_bot leaf.)
  if { ! declare -F chp_has_leaf >/dev/null 2>&1 || ! chp_has_leaf trigger_bot; } \
     && [[ "${CODE_HOST:-github}" != "github" ]]; then
    echo "ERROR: [INV-79]/[INV-91] agent requested bot triggers on PR #${pr_number} but CODE_HOST='${CODE_HOST:-github}' has no chp_trigger_bot leaf — refusing to post a GitHub-user comment on a non-GitHub backend. NO bot triggers posted." >&2
    return 0
  fi

  local gh_as_user="${_LIB_AUTH_DIR}/gh-as-user.sh"
  if [[ ! -f "$gh_as_user" ]]; then
    echo "WARN: [INV-79] agent requested bot triggers but ${gh_as_user} is absent — skipping (project has no gh-as-user.sh)." >&2
    return 0
  fi

  local line posted=0 allowed
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim leading/trailing whitespace; skip blanks and #-comments.
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    # ALLOW-LIST gate: post ONLY an EXACT configured trigger phrase. A non-matching
    # line is a misuse attempt (or a typo) — reject it, never forward to the host.
    allowed=0
    local _phrase
    while IFS= read -r _phrase; do
      [[ -n "$_phrase" && "$line" == "$_phrase" ]] && { allowed=1; break; }
    done <<< "$allowlist"
    if [[ "$allowed" -ne 1 ]]; then
      echo "WARN: [INV-79] rejected brokered bot-trigger line not in the configured allow-list (REVIEW_BOTS triggers only): '${line}'" >&2
      continue
    fi
    # [INV-87] (#282) the real-user bot-trigger post moves behind chp_trigger_bot.
    # The verb resolves gh-as-user.sh via the SAME project-side dir (_LIB_AUTH_DIR /
    # AUTONOMOUS_CONF_DIR) the broker resolved above, so the emitted
    # `gh-as-user.sh pr comment $pr --repo $REPO --body $line` is byte-identical.
    # The allow-list gate, PR resolution, and posted/failed tally all stay here.
    # Falls back to the raw `bash "$gh_as_user" …` call if the provider LEAF is
    # unavailable (guard on chp_has_leaf, NOT `declare -F chp_trigger_bot` — the
    # shim is always defined once lib-code-host is sourced; #282 review round 4 [P1]).
    # [INV-91] (#346) the else-branch raw call is now reachable ONLY on
    # `CODE_HOST == github` — a non-GitHub + leaf-absent broker already returned
    # loud above, so this is spec-sanctioned github-gated residue, not a silent
    # cross-backend fallback.
    if declare -F chp_has_leaf >/dev/null 2>&1 && chp_has_leaf trigger_bot; then
      _bot_post_ok() { chp_trigger_bot "$pr_number" "$line" >/dev/null 2>&1; }
    else
      _bot_post_ok() { bash "$gh_as_user" pr comment "$pr_number" --repo "$repo" --body "$line" >/dev/null 2>&1; }
    fi
    if _bot_post_ok; then
      posted=$((posted + 1))
    else
      echo "WARN: [INV-79] brokered bot-trigger post failed for PR #${pr_number} body='${line}' (gh-as-user.sh — GH_USER_PAT / host auth may be unset)." >&2
    fi
  done < "${AGENT_BOT_TRIGGER_FILE}"
  unset -f _bot_post_ok 2>/dev/null || true

  [[ "$posted" -gt 0 ]] && echo "[INV-79] wrapper brokered ${posted} bot-trigger comment(s) onto PR #${pr_number} via gh-as-user.sh (agent wrote ${AGENT_BOT_TRIGGER_FILE})." >&2
  return 0
}

# Cleanup auth resources. Call in trap handler.
cleanup_github_auth() {
  if [[ -n "$TOKEN_DAEMON_PID" ]]; then
    kill "$TOKEN_DAEMON_PID" 2>/dev/null || true
    wait "$TOKEN_DAEMON_PID" 2>/dev/null || true
  fi
  # [INV-79] Reap the scoped agent-token daemon too. Its token file lives inside
  # GH_WRAPPER_DIR and is removed with the dir below.
  if [[ -n "$AGENT_TOKEN_DAEMON_PID" ]]; then
    kill "$AGENT_TOKEN_DAEMON_PID" 2>/dev/null || true
    wait "$AGENT_TOKEN_DAEMON_PID" 2>/dev/null || true
  fi
  # Remove the per-run wrapper dir (holds both the token file and this run's
  # `gh` symlink). Guarded on the /tmp/agent-auth-* shape so we never rm -rf
  # an unexpected path. [INV-32] We deliberately do NOT touch
  # ${_LIB_AUTH_DIR}/gh — it is a shared, project-level artifact the agent's
  # `bash scripts/gh` and any concurrent run depend on. Removing it per-run
  # was the #163 concurrency footgun.
  rm -f "$GH_TOKEN_FILE" 2>/dev/null || true
  rm -f "$AGENT_GH_TOKEN_FILE" 2>/dev/null || true
  if [[ "$GH_WRAPPER_DIR" == /tmp/agent-auth-* ]]; then
    rm -rf "$GH_WRAPPER_DIR" 2>/dev/null || true
  fi
  # [INV-79] Remove the agent's OWN per-run shim dir (holds only the `gh` symlink).
  # Guarded on the /tmp/agent-shim-* shape so we never rm -rf an unexpected path.
  if [[ "$AGENT_GH_SHIM_DIR" == /tmp/agent-shim-* ]]; then
    rm -rf "$AGENT_GH_SHIM_DIR" 2>/dev/null || true
  fi
  # Reset the module-level state we just tore down. Without this, a second
  # setup_github_auth in the SAME shell (persistent test runners, consecutive
  # tasks) would see GH_WRAPPER_DIR still set, _ensure_gh_wrapper_dir would skip
  # the mktemp, and GH_TOKEN_FILE / the per-run `gh` symlink would point into the
  # directory we just rm -rf'd. Clearing here makes setup→cleanup→setup idempotent.
  GH_WRAPPER_DIR=""
  GH_TOKEN_FILE=""
  TOKEN_DAEMON_PID=""
  # [INV-79] Clear the scoped-token state too (same reused-shell idempotency).
  AGENT_GH_TOKEN_FILE=""
  AGENT_TOKEN_DAEMON_PID=""
  AGENT_GH_SHIM_DIR=""
}

# Export GH_USER_PAT if available (for gh-as-user.sh bot workaround).
if [[ -n "${GH_USER_PAT:-}" ]]; then
  export GH_USER_PAT
fi

# Export REAL_GH if set in autonomous.conf so gh-with-token-refresh.sh sees
# it across the PATH-injection boundary (closes #92). The wrapper child
# only reads its env, not the parent's shell vars.
if [[ -n "${REAL_GH:-}" ]]; then
  export REAL_GH
fi
