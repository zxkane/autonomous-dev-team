#!/bin/bash
# dispatcher-tick.sh — single entry point for one autonomous-dispatcher tick.
#
# Replaces the 224 lines of bash that used to live in
# `skills/autonomous-dispatcher/SKILL.md` with a single script the dispatcher
# agent calls once per cron cycle. Pure refactor (PR-3) — behavior identical
# to the prior SKILL.md tick.
#
# Usage: bash dispatcher-tick.sh
#   Reads autonomous.conf via lib-dispatch.sh (sourced).
#   Maintains JUST_DISPATCHED tick-local across Steps 2/3/4 → Step 5.
#
# See docs/pipeline/dispatcher-flow.md for the spec.

set -euo pipefail

# [INV-65] Two-dir resolution. SCRIPT_DIR (the conf dir) is the dirname of the
# UNRESOLVED ${BASH_SOURCE[0]:-$0} so a project-side symlink keeps it pointed at
# the project's scripts/ where autonomous.conf lives [INV-14]; it also resolves
# the project-side STABLE ENTRY scripts dispatch() invokes (dispatch-local.sh,
# dispatch-remote-aws-ssm.sh). LIB_DIR is the REAL path (readlink -f) used for
# sourcing sibling lib-*.sh (lib-config / lib-dispatch / lib-review-bots) and
# gh-app-token.sh from the skill tree — no per-project lib symlink needed (#227).
_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"

# Self-heal exec bits on the directly-invoked sibling scripts (closes #97).
# Some installs strip +x — git mode 100644 propagated through the skills CLI
# in earlier versions, and consumer-side tooling under restrictive umasks
# can also drop it. If +x is missing, dispatch-local.sh's
# `nohup .../autonomous-{dev,review}.sh` fails with `Permission denied`
# before the agent even starts, the dispatcher misclassifies it as a crash,
# and after MAX_RETRIES the issue stalls.
#
# Scoped narrowly to the two scripts dispatch-local.sh actually invokes —
# sourced-only siblings (lib-*.sh) are deliberately left alone. Best-effort
# (`|| true`) so a chmod failure on a read-only mount never aborts a tick.
for _need_exec in autonomous-dev.sh autonomous-review.sh; do
  if [[ -f "$SCRIPT_DIR/$_need_exec" && ! -x "$SCRIPT_DIR/$_need_exec" ]]; then
    chmod +x "$SCRIPT_DIR/$_need_exec" 2>/dev/null || true
  fi
done
unset _need_exec

# Load config via the shared helper (closes #58 for the dispatcher path).
# Must run before sourcing lib-dispatch.sh — lib-dispatch.sh enforces
# REPO/REPO_OWNER/PROJECT_ID via `: "${VAR:?...}"`.
# shellcheck source=lib-config.sh
source "${LIB_DIR}/lib-config.sh"
# [INV-72] Operator error envelope: tick-global config aborts surface as a
# dispatcher-alert (no per-issue context). Self-contained (only needs jq).
# shellcheck source=lib-error.sh
source "${LIB_DIR}/lib-error.sh"
# conf lookup stays on the UNRESOLVED SCRIPT_DIR (project's scripts/) — INV-14.
load_autonomous_conf "${SCRIPT_DIR}" || true

# [INV-72] Preflight ALL required keys BEFORE sourcing lib-dispatch.sh — that
# library has top-level `: "${REPO:?}"` / `${REPO_OWNER:?}` / `${PROJECT_ID:?}`
# guards that would raw-abort the tick (a bare bash error, NOT the documented
# envelope) the instant it is sourced with a missing key. Surfacing here (a
# dispatcher-alert — a tick has no per-issue context) and aborting first means a
# missing key produces the ADT_CFG_MISSING_KEY envelope, not an opaque
# `: REPO: parameter null or not set`. PROJECT_DIR is checked too (lib-dispatch
# does not guard it, but the tick needs it for dispatch()).
for _req in REPO REPO_OWNER PROJECT_ID PROJECT_DIR; do
  if [[ -z "${!_req:-}" ]]; then
    error_surface - ADT_CFG_MISSING_KEY \
      "Required autonomous.conf key '${_req}' is unset (dispatcher tick)" \
      "${_req} is empty/unset in the project's scripts/autonomous.conf" \
      "Set ${_req} in scripts/autonomous.conf (see autonomous.conf.example), then the next tick proceeds" \
      "docs/pipeline/errors.md#configuration-class-class-config"
    echo "[dispatcher-tick] FATAL: ${_req} must be set in autonomous.conf" >&2
    exit 1
  fi
done
unset _req

# shellcheck source=lib-dispatch.sh
source "${LIB_DIR}/lib-dispatch.sh"

# [INV-128] Step 6 liveness watchdog's pure fingerprint/counter/threshold
# helpers. Sourced unconditionally (cheap, no I/O at source time) so
# _liveness_watchdog_enabled is always resolvable, even when the watchdog
# itself is disabled.
# shellcheck source=lib-liveness.sh
source "${LIB_DIR}/lib-liveness.sh"

# [INV-108] (#361 review [P1]): release any controller-side dispatch marker
# that was acquired but never confirmed launched, no matter how this tick
# process ends. `acquire_dispatch_marker` runs before label edits, notice
# comments, log resets, token posting, and `dispatch()` itself — every one of
# those is a BARE command below, so under this script's own `set -euo
# pipefail` a transient failure in ANY of them aborts the whole tick
# immediately, well before a normal `continue`/`return` could release the
# marker by hand. Without this trap the freshly-created marker would then
# survive on disk for the full TTL, and the very next tick — which would
# otherwise retry the issue right away — reads a fresh, unexpired marker and
# skips it as "held by a concurrent tick", turning one transient hiccup into
# a ~10 minute false stall. `_dispatch_marker_release_pending` is idempotent
# and never propagates a non-zero status, so it cannot itself clobber the
# script's real exit code (verified: bash preserves the pre-trap `$?` through
# an EXIT trap unless the trap body explicitly returns/exits non-zero).
trap _dispatch_marker_release_pending EXIT

# [INV-70] Observe-only metrics emitter. Guarded so a load failure never aborts
# the tick. Provides metrics_emit.
# shellcheck source=lib-metrics.sh
source "${LIB_DIR}/lib-metrics.sh" 2>/dev/null || true

# [#416 R2] lib-auth.sh — provides the shared `github_seam_active` /
# `gitlab_seam_active` predicates the app-mode credential FATAL below gates
# on. lib-auth.sh's top-level runs `load_autonomous_conf` (fail-safe `|| true`)
# and defines its own functions; sourcing here is idempotent w.r.t. any later
# per-project source in tick_inline_project.
# shellcheck source=lib-auth.sh
source "${LIB_DIR}/lib-auth.sh"

# [INV-72] PROJECT_DIR (+ REPO/REPO_OWNER/PROJECT_ID) are already validated by
# the required-key preflight ABOVE (before sourcing lib-dispatch.sh), which
# surfaces ADT_CFG_MISSING_KEY instead of a raw `: "${VAR:?}"` abort — so no
# post-source `: "${PROJECT_DIR:?}"` guard is needed here.

log() { echo "[dispatcher-tick] $(date -u +%H:%M:%S) $*"; }

# Validate EXECUTION_BACKEND ONCE upfront, before any label transitions.
# H1 (PR-9 review): if dispatch() returned 1 from inside a step body, the
# step had already swapped the issue's label to in-progress and posted a
# comment — leaving a stuck issue + burning retries every tick. Catching
# the typo here aborts the tick before any side effect.
case "${EXECUTION_BACKEND:-local}" in
  local|remote-aws-ssm) ;;
  *)
    error_surface - ADT_CFG_EXECUTION_BACKEND_INVALID \
      "EXECUTION_BACKEND has an unrecognized value (dispatcher tick)" \
      "EXECUTION_BACKEND='${EXECUTION_BACKEND}' is not 'local' or 'remote-aws-ssm'" \
      "Set EXECUTION_BACKEND to local or remote-aws-ssm in dispatcher.conf/autonomous.conf, then the next tick proceeds" \
      "docs/pipeline/errors.md#configuration-class-class-config"
    echo "[dispatcher-tick] FATAL: unknown EXECUTION_BACKEND='${EXECUTION_BACKEND}'. Allowed: local, remote-aws-ssm." >&2
    exit 1
    ;;
esac

# Validate the GitHub CLI version upfront, same slot and reasoning as
# EXECUTION_BACKEND above: the GitHub-provider ITP/CHP leaves (providers/
# itp-github.sh, providers/chp-github.sh — gh_version_ok / GH_MIN_VERSION /
# GH_INSTALLED_VERSION live in the shared providers/lib-github-transport.sh,
# transitively sourced via lib-dispatch.sh above) depend on the '--slurp'
# pagination flag, and an older CLI fails that call silently deep inside
# Step 3/4 instead of here, aborting the tick opaquely well past any label
# transition. Gated on `github_seam_active` — a gitlab/gitlab topology never
# calls the GitHub CLI and must not be blocked by its version (or absence).
if github_seam_active && ! gh_version_ok "$GH_MIN_VERSION"; then
  error_surface - ADT_CFG_GH_VERSION_TOO_OLD \
    "The GitHub CLI on PATH is missing or older than the minimum required version (dispatcher tick)" \
    "The installed CLI reported '${GH_INSTALLED_VERSION}'; the GitHub provider requires the CLI to be >= ${GH_MIN_VERSION} for the '--slurp' pagination flag (added in GitHub CLI v2.48.0)" \
    "Upgrade the GitHub CLI to >= ${GH_MIN_VERSION} on the execution host, then the next tick proceeds" \
    "docs/pipeline/errors.md#configuration-class-class-config"
  echo "[dispatcher-tick] FATAL: the GitHub CLI is missing or older than the minimum required version ${GH_MIN_VERSION} (got '${GH_INSTALLED_VERSION}'). The '--slurp' pagination flag requires version >= 2.48.0. Upgrade before the next tick." >&2
  exit 1
fi

# Validate REVIEW_BOTS upfront for the same reason: a typo (e.g.
# REVIEW_BOTS="q codx") would let the tick swap labels to `reviewing` and
# spawn the review wrapper, which then exits 1 at startup — burning a
# retry slot every tick until the issue hits MAX_RETRIES. Catching the
# typo here aborts the entire tick before any side-effect, with no retry
# counted. Empty REVIEW_BOTS is allowed (bot enforcement disabled).
# shellcheck source=lib-review-bots.sh
source "${LIB_DIR}/lib-review-bots.sh"
if ! parse_review_bots "${REVIEW_BOTS:-}" >/dev/null; then
  error_surface - ADT_CFG_REVIEW_BOTS_INVALID \
    "REVIEW_BOTS contains an unrecognized bot short-name (dispatcher tick)" \
    "A REVIEW_BOTS token is not a known bot short-name (q / codex / claude / a configured custom bot)" \
    "Fix REVIEW_BOTS in scripts/autonomous.conf to a space-separated list of known bot short-names (or empty), then the next tick proceeds" \
    "docs/pipeline/errors.md#configuration-class-class-config"
  echo "[dispatcher-tick] FATAL: REVIEW_BOTS validation failed (see error above). Fix autonomous.conf before the next tick." >&2
  exit 1
fi

# [#436, ISSUE_FILTER, design §4.3] Validate ISSUE_FILTER + ISSUE_SCAN_LIMIT
# upfront, same slot and same reasoning as EXECUTION_BACKEND/REVIEW_BOTS
# above: a poisoned filter must never dispatch anything and must never fall
# back to unfiltered scanning (an unfiltered fallback would silently violate
# the multi-dispatcher disjointness contract, [INV-121]). issue_filter_validate
# (lib-issue-filter.sh, sourced transitively via lib-dispatch.sh above) runs
# the compile + dry-run-eval, the reserved-label gate, and the assignee
# capability gate (itp_caps, already resolvable — lib-issue-provider.sh is
# sourced by lib-dispatch.sh before this point).
if ! _ift_err=$(issue_filter_validate "${ISSUE_FILTER:-}" 2>&1); then
  error_surface - ADT_CFG_ISSUE_FILTER_INVALID \
    "ISSUE_FILTER failed validation (dispatcher tick)" \
    "${_ift_err:-issue_filter_validate rejected the configured ISSUE_FILTER}" \
    "Fix ISSUE_FILTER in scripts/autonomous.conf (or the project's dispatcher.conf block) per the grammar documented in autonomous.conf.example, then the next tick proceeds" \
    "docs/pipeline/errors.md#configuration-class-class-config"
  echo "[dispatcher-tick] FATAL: ISSUE_FILTER validation failed: ${_ift_err:-see error above}. Fix autonomous.conf before the next tick." >&2
  unset _ift_err
  exit 1
fi
unset _ift_err

case "${ISSUE_SCAN_LIMIT:-100}" in
  ''|*[!0-9]*)
    _ift_bad_limit=1 ;;
  0)
    _ift_bad_limit=1 ;;
  *)
    _ift_bad_limit=0 ;;
esac
if [[ "$_ift_bad_limit" -eq 1 ]]; then
  error_surface - ADT_CFG_ISSUE_SCAN_LIMIT_INVALID \
    "ISSUE_SCAN_LIMIT has an invalid value (dispatcher tick)" \
    "ISSUE_SCAN_LIMIT='${ISSUE_SCAN_LIMIT:-}' is not a positive integer" \
    "Set ISSUE_SCAN_LIMIT to a positive integer (or unset it for the default 100) in scripts/autonomous.conf, then the next tick proceeds" \
    "docs/pipeline/errors.md#configuration-class-class-config"
  echo "[dispatcher-tick] FATAL: ISSUE_SCAN_LIMIT='${ISSUE_SCAN_LIMIT:-}' is not a positive integer. Fix autonomous.conf before the next tick." >&2
  unset _ift_bad_limit
  exit 1
fi
unset _ift_bad_limit

# Generate a GitHub App installation token for the dispatcher when
# GH_AUTH_MODE=app (closes #91). Pre-fix, the dispatcher's `gh` calls fell
# back to the user's `gh auth login` token, so issue comments + label
# changes appeared as the user instead of the bot identity.
#
# A single token covers the whole tick (valid 1h, scope: this repo only).
# We don't run gh-token-refresh-daemon here — that's for long-lived agent
# wrappers; the tick completes in <1 min.
#
# Fail-fast on misconfig (missing id/pem, token API failure, empty result):
# silently falling back to user auth is precisely the bug being closed.
# [#416 R2] Gate the whole GitHub App-mode credential path on the shared
# `github_seam_active` helper (lib-auth.sh) — either ISSUE_PROVIDER=github or
# CODE_HOST=github (the two arms are independent per §auth [M9]). A
# `gitlab`/`gitlab` topology needs neither GitHub App identity — the FATAL,
# the token mint, and the subsequent `gh` wrapper install are all skipped. A
# mixed `github`/`gitlab` or `gitlab`/`github` topology STILL needs it (the
# active github seam's leaves call `gh`). Under the default (both unset →
# github/github via the `${…:-github}` defaults inside `github_seam_active`)
# the gate is transparent — byte-identical to pre-#416 behavior.
#
if [[ "${GH_AUTH_MODE:-token}" == "app" ]] && github_seam_active; then
  if [[ -z "${DISPATCHER_APP_ID:-}" || -z "${DISPATCHER_APP_PEM:-}" ]]; then
    error_surface - ADT_AUTH_APP_CREDS_MISSING \
      "GH_AUTH_MODE=app but the dispatcher's App credentials are unset (dispatcher tick)" \
      "DISPATCHER_APP_ID and/or DISPATCHER_APP_PEM is empty in dispatcher.conf/autonomous.conf" \
      "Set DISPATCHER_APP_ID and DISPATCHER_APP_PEM (see docs/github-app-setup.md), then the next tick proceeds" \
      "docs/pipeline/errors.md#authentication-class-class-auth" auth
    echo "[dispatcher-tick] FATAL: GH_AUTH_MODE=app requires DISPATCHER_APP_ID and DISPATCHER_APP_PEM (one or both are empty)." >&2
    exit 1
  fi
  # Auto-derive REPO_NAME from REPO when an older path-entry autonomous.conf
  # forgot to set it. Inline projects already do this in tick_inline_project;
  # mirror it here so set -u doesn't trip on `"$REPO_NAME"` below.
  : "${REPO_NAME:=${REPO##*/}}"
  # shellcheck source=gh-app-token.sh
  source "${LIB_DIR}/gh-app-token.sh"
  _dispatcher_token=$(get_gh_app_token \
    "$DISPATCHER_APP_ID" "$DISPATCHER_APP_PEM" \
    "$REPO_OWNER" "$REPO_NAME") || {
    error_surface - ADT_AUTH_TOKEN_MINT_FAILED \
      "The dispatcher's GitHub App installation token could not be minted (dispatcher tick)" \
      "get_gh_app_token failed for ${REPO_OWNER}/${REPO_NAME}" \
      "Verify DISPATCHER_APP_ID, the installation id, and DISPATCHER_APP_PEM on the dispatcher host and that the App has the required repo permissions, then the next tick proceeds" \
      "docs/pipeline/errors.md#authentication-class-class-auth" auth
    echo "[dispatcher-tick] FATAL: failed to generate GitHub App token for ${REPO_OWNER}/${REPO_NAME}." >&2
    exit 1
  }
  if [[ -z "$_dispatcher_token" ]]; then
    error_surface - ADT_AUTH_TOKEN_MINT_FAILED \
      "The dispatcher's GitHub App token came back empty (dispatcher tick)" \
      "gh-app-token returned an empty token for ${REPO_OWNER}/${REPO_NAME}" \
      "Verify DISPATCHER_APP_ID, the installation id, and DISPATCHER_APP_PEM on the dispatcher host and that the App has the required repo permissions, then the next tick proceeds" \
      "docs/pipeline/errors.md#authentication-class-class-auth" auth
    echo "[dispatcher-tick] FATAL: gh-app-token returned an empty token for ${REPO_OWNER}/${REPO_NAME}." >&2
    exit 1
  fi
  export GH_TOKEN="$_dispatcher_token"
  unset _dispatcher_token
fi

# dispatch — route a wrapper-spawn request to the configured backend (#62 axis 2).
# Backends today: "local" (default — same-box dispatch-local.sh) and
# "remote-aws-ssm" (sends an `aws ssm send-command` to a remote dev box).
# Other backends (k8s, gha-runner) can be added with one case arm here.
# The unknown-backend case is unreachable because we validate above; the
# `*)` arm is a defensive assertion in case allowed-list values get out of
# sync between the upfront check and the runtime dispatch.
#
# Args: <type> <issue_num> [session_id]   — passed through verbatim.
dispatch() {
  case "${EXECUTION_BACKEND:-local}" in
    local)
      bash "$PROJECT_DIR/scripts/dispatch-local.sh" "$@"
      ;;
    remote-aws-ssm)
      # [INV-65] Invoke the remote driver via LIB_DIR (the real skill tree),
      # NOT the project-side SCRIPT_DIR. dispatch-remote-aws-ssm.sh sources its
      # sibling lib-ssm.sh from its OWN unresolved dir (${BASH_SOURCE[0]%/*},
      # readlink-free for TC-EB-008's scrubbed PATH); invoking it project-side
      # would set that dir to <project>/scripts/, where the installer no longer
      # symlinks lib-ssm.sh — reintroducing the missing-lib crash. Running it
      # from LIB_DIR keeps its BASH_SOURCE in the skill tree, where lib-ssm.sh
      # is a real adjacent file. (dispatch-local.sh stays project-side: it
      # sources its own libs from its own LIB_DIR, so the path is moot there.)
      bash "$LIB_DIR/dispatch-remote-aws-ssm.sh" "$@"
      ;;
    *)
      # Should never reach here because of the upfront check, but be loud
      # if invariants drift.
      echo "[dispatcher-tick] BUG: dispatch() reached unknown EXECUTION_BACKEND='${EXECUTION_BACKEND}' at runtime" >&2
      exit 1
      ;;
  esac
}

# Tick-local state. JUST_DISPATCHED holds issue numbers dispatched in
# Steps 2/3/4 of this tick, so Step 5 can skip them ([INV-09]).
JUST_DISPATCHED=()

# [INV-83] Tick boundary for the cross-repo dependency lookup-token cache, via
# the itp_begin_tick lifecycle hook (#284, spec §3.6). The cache is TICK-scoped
# (AC #2): Step 2's check_deps_resolved reuses a single per-`owner/repo` minted
# token across ALL new issues in this tick, so two issues depending on the same
# external repo mint only ONCE. The cache + the reset are provider-internal now
# (GitHub ITP maps itp_begin_tick → its own _DEP_TOKEN_CACHE reset); calling the
# verb once here (before Step 2 scan-new) starts each tick clean while preserving
# the within-tick dedup — a per-issue reset would defeat it (#269 review [P1]).
#
# Guard on the PROVIDER LEAF (`itp_${ISSUE_PROVIDER}_begin_tick`), NOT the shim:
# lib-issue-provider.sh ALWAYS defines the `itp_begin_tick` shim, but begin_tick
# is an OPTIONAL lifecycle hook — a provider with no per-tick state (no token
# cache) legitimately does not implement the leaf. Guarding on the shim would
# always pass and then call an undefined `itp_${ISSUE_PROVIDER}_begin_tick`,
# aborting the tick under `set -e` with `command not found` (e.g. the degraded
# fixture provider, or any not-yet-migrated gitlab/asana backend). Guarding on the
# leaf restores the pre-#284 no-op-when-absent semantics the old
# `declare -F _reset_dep_token_cache` guard had (the GitHub default DOES define
# the leaf, so the real dispatcher still resets the cache every tick). ISSUE_PROVIDER
# is set by lib-issue-provider.sh (`${ISSUE_PROVIDER:-github}`); the `:-github`
# here keeps the guard `set -u`-safe if the seam was somehow not sourced.
if declare -F "itp_${ISSUE_PROVIDER:-github}_begin_tick" >/dev/null 2>&1; then
  itp_begin_tick
fi

# ---------------------------------------------------------------------------
# Step 0: label hygiene pass ([INV-25], issue #115 Bug B)
# ---------------------------------------------------------------------------
# Heal "approved + transitional" and "stalled + transitional" residues
# before any selector reads labels. Without this, an issue in a sticky
# terminal state but still carrying e.g. `pending-review` would be
# re-picked by a future selector that forgets to subtract the terminal
# (Bug A was one such selector — fixed in PR #116; Bug B closes the
# class). Step 0 runs UNCONDITIONALLY: even when concurrency is
# saturated we still want stale residue cleared so Step 5 doesn't
# misclassify on the next tick. Pure label edits — no agent dispatch,
# no retry counting.
log "Step 0: scanning for terminal-label residue..."
run_hygiene_pass

# ---------------------------------------------------------------------------
# Step 1: Concurrency gate
# ---------------------------------------------------------------------------
ACTIVE=$(count_active)
if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
  log "Concurrency limit reached ($ACTIVE/$MAX_CONCURRENT). Aborting tick."
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2: scan-new
# ---------------------------------------------------------------------------
log "Step 2: scanning for new autonomous issues..."
new_issues=$(list_new_issues)
new_count=$(jq 'length' <<<"$new_issues")
log "  found $new_count new issue(s)"

for i in $(seq 0 $((new_count - 1))); do
  ACTIVE=$(count_active)
  if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
    log "  concurrency reached during scan-new ($ACTIVE/$MAX_CONCURRENT) — stopping"
    break
  fi

  issue_num=$(jq -r ".[$i].number" <<<"$new_issues")

  if ! check_deps_resolved "$issue_num"; then
    log "  issue #${issue_num} has unresolved dependencies — skipping silently"
    continue
  fi

  # [INV-108] (302b, #361 R1): acquire the controller-side per-(issue,mode)
  # dispatch marker BEFORE any side effect (label edit / token / dispatch) for
  # this issue. A losing acquire means a concurrent tick already owns this
  # dispatch — skip cleanly, no error, no label edit, no dispatch() call.
  if ! acquire_dispatch_marker "$issue_num" "dev-new"; then
    log "  issue #${issue_num} dev-new dispatch marker held by a concurrent tick — skipping ([INV-108])"
    # Held marker ⇒ a concurrent tick OWNS this issue mid-dispatch. Protect it
    # from THIS tick's Step 5 stale detection too (#361 round-14 [P1]): the
    # winner may have label-swapped but not yet posted its token/PID — without
    # this, Step 5 could classify the winner as crashed and flip the issue
    # back, letting a next tick double-dispatch in a DIFFERENT mode.
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  log "  dispatching dev-new for issue #${issue_num}"
  label_swap "$issue_num" "" "in-progress"
  # [INV-70] Metrics: the issue is first picked up for autonomous work — the
  # TTHW "labeled" endpoint. Emitted only on the first (dev-new) dispatch, not
  # on resumes/re-dispatches, so the aggregator's earliest-per-issue reduction
  # is anchored here. Best-effort, observe-only.
  #
  # The event `ts` is THIS dispatch instant, which can lag the real `autonomous`
  # label time by ticks (concurrency cap, unresolved deps). For accurate TTHW we
  # also fetch the actual `autonomous`-label timeline timestamp and emit it as
  # `labeled_at`; the aggregator prefers it over `ts`, so labeled→PR/merge counts
  # the queue wait (#228 review finding 4). The timeline read routes through the
  # `itp_label_event_ts` ITP verb ([INV-93], GitHub leaf `itp_github_label_event_ts`,
  # #323) — the GitHub-internal timeline jq lives under providers/. It is best-effort
  # / observe-only: on any failure (or a provider with no leaf) `labeled_at` is
  # omitted and the aggregator falls back to `ts`. The call is guarded on the BARE
  # provider-leaf expression `itp_${ISSUE_PROVIDER}_label_event_ts` — IDENTICAL to
  # the always-present shim's BARE dispatch (lib-issue-provider.sh), so a provider
  # that has not implemented the leaf is skipped rather than calling an undefined
  # `itp_${ISSUE_PROVIDER}_label_event_ts` under `set -e`. A `:-github` guard here
  # would DIVERGE from the bare shim when `ISSUE_PROVIDER` were empty (guard passes
  # on `itp_github_…`, shim aborts on `itp__…`); the bare guard matches the shim's
  # bare dispatch so the two never disagree (#323 review R2). (Unlike the
  # `itp_begin_tick` guard above, which carries a `:-github` for `set -u` safety,
  # this one is deliberately bare for guard/shim equality — safe because
  # lib-issue-provider.sh, sourced via lib-dispatch.sh well before Step 2, always
  # sets `ISSUE_PROVIDER="${ISSUE_PROVIDER:-github}"`, so it is never unset here.)
  # It never blocks dispatch.
  if declare -F metrics_emit >/dev/null 2>&1; then
    _labeled_at=""
    if declare -F "itp_${ISSUE_PROVIDER}_label_event_ts" >/dev/null 2>&1; then
      _labeled_at="$(itp_label_event_ts "$issue_num" "autonomous")"
    fi
    if [[ -n "${_labeled_at:-}" ]]; then
      metrics_emit issue_labeled "issue=${issue_num}" "labeled_at=${_labeled_at}" || true
    else
      metrics_emit issue_labeled "issue=${issue_num}" || true
    fi
    unset _labeled_at
  fi
  # Bug 1+2 (#99): write a dispatcher-controlled marker that records the
  # dispatch timestamp ([INV-17]). Step 5 uses this to honor a cold-start
  # grace window before classifying the wrapper as crashed.
  post_dispatch_token "$issue_num" "dev-new"
  # [Lane-GC PR-6 / INV-119] rc=75 (EX_TEMPFAIL) is the back-pressure gate's
  # DEFER sentinel, not a crash — capture the rc explicitly (never a bare
  # `dispatch ... || …` here, which would also swallow a genuine non-75
  # failure into the SAME branch) so it routes to `handle_dispatch_deferred`,
  # which REVERTS the `label_swap "" → in-progress` above (args reversed:
  # `in-progress → ""`) so the issue reappears in Step 2's own selector next
  # tick instead of being misclassified as crashed by Step 5.
  #
  # [review P1-2] A non-75, non-zero rc is NOT a defer and must NOT fall
  # through to `dispatch_marker_confirm_launched` below — pre-P6, this
  # call site was a bare top-level `dispatch dev-new "$issue_num"` with no
  # rc capture at all, so under this script's own `set -euo pipefail` any
  # non-zero return aborted the ENTIRE TICK immediately (never reaching
  # Step 5, never confirming any marker). Capturing the rc via `|| _rc=$?`
  # suppresses that abort for every rc, not just 75 — so a genuine
  # dispatch failure must be explicitly re-raised via `exit` to restore
  # the exact pre-P6 behavior for that case.
  _dispatch_rc=0
  dispatch dev-new "$issue_num" || _dispatch_rc=$?
  if is_dispatch_deferred_rc "$_dispatch_rc"; then
    handle_dispatch_deferred "$issue_num" "dev-new" "in-progress" ""
    continue
  elif [ "$_dispatch_rc" -ne 0 ]; then
    exit "$_dispatch_rc"
  fi
  # [INV-108] (#361 review [P1]): dispatch() returned — a wrapper is
  # confirmed launched. Confirm so the EXIT-trap release above leaves this
  # marker alone; it lives out its normal TTL.
  dispatch_marker_confirm_launched "$issue_num" "dev-new"
  JUST_DISPATCHED+=("$issue_num")
done

# ---------------------------------------------------------------------------
# Step 3: scan-pending-review
# ---------------------------------------------------------------------------
log "Step 3: scanning for issues pending review..."
pending_review=$(list_pending_review)
pr_count=$(jq 'length' <<<"$pending_review")
log "  found $pr_count pending-review issue(s)"

for i in $(seq 0 $((pr_count - 1))); do
  ACTIVE=$(count_active)
  if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
    log "  concurrency reached during scan-pending-review ($ACTIVE/$MAX_CONCURRENT) — stopping"
    break
  fi

  issue_num=$(jq -r ".[$i].number" <<<"$pending_review")

  # [INV-108] (302b, #361 R1) — see the Step 2 comment above.
  if ! acquire_dispatch_marker "$issue_num" "review"; then
    log "  issue #${issue_num} review dispatch marker held by a concurrent tick — skipping ([INV-108])"
    # Step-5 protection for the concurrent winner — see the Step 2 comment.
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  log "  dispatching review for issue #${issue_num}"
  label_swap "$issue_num" "pending-review" "reviewing"
  post_dispatch_token "$issue_num" "review"
  # [Lane-GC PR-6 / INV-119] — see the Step 2 rc=75 comment above. Revert
  # args are the `label_swap` call above, reversed. [review P1-2] non-75
  # non-zero rc re-raises via exit — see the Step 2 comment above.
  _dispatch_rc=0
  dispatch review "$issue_num" || _dispatch_rc=$?
  if is_dispatch_deferred_rc "$_dispatch_rc"; then
    handle_dispatch_deferred "$issue_num" "review" "reviewing" "pending-review"
    continue
  elif [ "$_dispatch_rc" -ne 0 ]; then
    exit "$_dispatch_rc"
  fi
  # [INV-108] (#361 review [P1]) — see the Step 2 confirm comment above.
  dispatch_marker_confirm_launched "$issue_num" "review"
  JUST_DISPATCHED+=("$issue_num")
done

# ---------------------------------------------------------------------------
# Step 4: scan-pending-dev (resume)
# ---------------------------------------------------------------------------
log "Step 4: scanning for issues pending dev resume..."
pending_dev=$(list_pending_dev)
pd_count=$(jq 'length' <<<"$pending_dev")
log "  found $pd_count pending-dev issue(s)"

for i in $(seq 0 $((pd_count - 1))); do
  ACTIVE=$(count_active)
  if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
    log "  concurrency reached during scan-pending-dev ($ACTIVE/$MAX_CONCURRENT) — stopping"
    break
  fi

  issue_num=$(jq -r ".[$i].number" <<<"$pending_dev")

  retry_count=$(count_retries "$issue_num")
  if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
    log "  issue #${issue_num} retry exhausted ($retry_count/$MAX_RETRIES) — marking stalled"
    # [INV-70] Metrics: retry exhausted → stalled. Best-effort, observe-only.
    if declare -F metrics_emit >/dev/null 2>&1; then
      metrics_emit dispatch_retry "issue=${issue_num}" "retry_count=${retry_count}" stalled=true || true
    fi
    # `--at-cap` ([INV-30] exception, issue #263): retry budget is exhausted
    # here, so a persistently-indeterminate remote-SSM liveness verdict must
    # resolve to DEAD (stop deferring) rather than biasing ALIVE forever. This
    # is the ONLY at-cap mark_stalled call site — the review-retry-cap caller
    # in handle_completed_session_routing() deliberately omits the flag.
    mark_stalled --at-cap "$issue_num"
    continue
  fi

  # [INV-70] Metrics: a below-limit retry increment. Emitted ONCE here, after the
  # exhaustion gate and before ANY of the downstream pending-dev re-dispatch
  # branches (PR-exists handoff, PTL fresh dev-new, completed-session routing,
  # normal dev-resume), so every retry attempt — not just the final stall — lands
  # in the event trail with `stalled=false` (#228 review: retry history was only
  # recorded at exhaustion). The `stalled=true` event above stays for the
  # exhaustion case. Best-effort, observe-only.
  if declare -F metrics_emit >/dev/null 2>&1; then
    metrics_emit dispatch_retry "issue=${issue_num}" "retry_count=${retry_count}" stalled=false || true
  fi

  # Bug 3 (#99): if a PR already exists for this issue, the agent already
  # finished development — any subsequent crash (e.g. cleanup-time exit
  # non-zero after gh pr create) routed us to pending-dev, but re-developing
  # would just re-do work. Hand off to review instead.
  #
  # #106: when the PR's HEAD already matches the most recent
  # `Reviewed HEAD:` trailer, the prior verdict was FAILED and the dev
  # agent hasn't pushed new commits yet. Re-routing to pending-review
  # would loop the same review against the same code every tick. The
  # helper keeps such issues in pending-dev with an idempotent
  # stale-verdict notice; only NEW commits or first-review issues flip.
  if handle_pending_dev_pr_exists "$issue_num"; then
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  session_id=$(extract_dev_session_id "$issue_num")

  # [INV-12] Skip resume if the prior session reached a terminal state
  # that resume cannot recover from. Two cases:
  #   end_turn|completed → operator handoff (closes #59).
  #   *|prompt_too_long  → auto-recover via fresh session (no auto-compact
  #                        in claude -p; the only fix is a new session_id).
  # See lib-dispatch.sh:is_session_completed for the full rationale.
  #
  # Idempotency: post the operator notice at most once per session-id.
  # Without this, every 5-min tick posts the same comment (~288/day) for
  # the COMPLETED case (pending-dev → pending-dev). For the PTL case we
  # flip the label so the comment fires at most once anyway.
  _session_terminal_reason=""
  _session_end_iso=""
  if [ -n "$session_id" ] && is_session_completed "$issue_num" _session_terminal_reason _session_end_iso; then
    if [ "$_session_terminal_reason" = "prompt_too_long" ]; then
      # [INV-108] (302b, #361 R1): acquire BEFORE any side effect of this
      # branch (notice post, log truncate, dispatch) — all of it leads to a
      # dev-new dispatch for this issue, so a concurrent tick already owning
      # it must short-circuit the whole branch, not just the final dispatch().
      if ! acquire_dispatch_marker "$issue_num" "dev-new"; then
        log "  issue #${issue_num} dev-new dispatch marker held by a concurrent tick — skipping PTL recovery ([INV-108])"
        # Step-5 protection for the concurrent winner — see the Step 2 comment.
        JUST_DISPATCHED+=("$issue_num")
        continue
      fi
      log "  issue #${issue_num} session ${session_id} hit prompt_too_long — clearing for fresh dispatch"
      notice_marker="INV-12-prompt-too-long:${session_id}"
      # [INV-91]/[INV-90] (#321): the idempotency-dedup READ routes through
      # itp_list_comments (the normalized array `.[]`; the verb unwraps gh's
      # `{comments:[…]}` envelope), NOT a raw `gh issue view --json comments -q`.
      # `contains()` is a LITERAL substring test — engine-agnostic, no
      # RE2/Oniguruma divergence. Fail-closed: an empty/error fetch leaves the
      # count empty (≠ "0"), so the notice is NOT re-posted (the marker is the
      # dedup key; the next tick re-checks) — same posture as the old
      # `grep -q '^0$'` (no `^0$` line on a fetch error → guard false → no post).
      _ptl_notice_count="$(itp_list_comments "$issue_num" 2>/dev/null \
          | jq -r "[.[].body | select(contains(\"${notice_marker}\"))] | length" 2>/dev/null)"
      if [ "${_ptl_notice_count:-}" = "0" ]; then
        itp_post_comment "$issue_num" \
          "Session \`${session_id}\` exhausted the model context window (terminal_reason=prompt_too_long). \`claude -p\` does not auto-compact, so resume would crash again. Forcing a fresh dev session on the next tick. (\`${notice_marker}\`)"
      fi
      # Truncate the log so the next tick sees an empty/missing log and
      # doesn't re-trigger this is_session_completed branch. The dev-new
      # dispatch below mints a new session_id and writes fresh result lines.
      #
      # If truncation fails (perm drift across deploys, ENOSPC), DO NOT
      # dispatch — otherwise the next tick would re-read the same stale
      # PTL log, the idempotency marker would suppress a fresh notice
      # (it's keyed on the old session_id), and we'd silently dispatch
      # dev-new every tick forever. Stay in pending-dev so the operator
      # sees the issue accumulating retries via mark_stalled instead.
      #
      # [INV-101] (#356): routes through `_reset_session_log` (lib-dispatch.sh)
      # — backend-aware, so under EXECUTION_BACKEND=remote-aws-ssm the reset
      # happens on the execution host via SSM (the same host
      # `is_session_completed`'s remote probe read the stale line from),
      # never a controller-local path. The error text below reflects
      # whichever path was actually touched (or attempted).
      if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]; then
        _ptl_log="/tmp/agent-${SSM_REMOTE_PROJECT_ID:-?}-issue-${issue_num}.log"
        _ptl_log_location="${_ptl_log} on the execution host (SSM_INSTANCE_ID=${SSM_INSTANCE_ID:-?})"
      else
        _ptl_log="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
        _ptl_log_location="${_ptl_log}"
      fi
      if ! _reset_session_log "$issue_num"; then
        log "  ERROR: failed to truncate ${_ptl_log_location} (perm/disk/SSM?). Skipping PTL dev-new dispatch to avoid re-detection loop."
        itp_post_comment "$issue_num" \
          "Could not reset prompt-too-long log at \`${_ptl_log_location}\` for fresh dispatch (permission, disk, or SSM transport error). Operator: please clear the log file and retry. Skipping dispatch to prevent a silent retry loop." 2>/dev/null || true
        # [INV-108] (#361 review [P1]): no wrapper will launch this tick for
        # this (issue, mode) — release NOW rather than let it sit for the
        # full TTL. MAX_RETRIES still bounds the retry budget; this only
        # controls how soon the NEXT tick is allowed to try again.
        release_dispatch_marker "$issue_num" "dev-new"
        continue
      fi
      log "  dispatching dev-new for issue #${issue_num} (fresh after prompt_too_long)"
      label_swap "$issue_num" "pending-dev" "in-progress"
      post_dispatch_token "$issue_num" "dev-new"
      # [Lane-GC PR-6 / INV-119] — see the Step 2 rc=75 comment above.
      # [review P1-2] non-75 non-zero rc re-raises via exit — see the Step 2
      # comment above.
      _dispatch_rc=0
      dispatch dev-new "$issue_num" || _dispatch_rc=$?
      if is_dispatch_deferred_rc "$_dispatch_rc"; then
        handle_dispatch_deferred "$issue_num" "dev-new" "in-progress" "pending-dev"
        continue
      elif [ "$_dispatch_rc" -ne 0 ]; then
        exit "$_dispatch_rc"
      fi
      # [INV-108] (#361 review [P1]) — see the Step 2 confirm comment above.
      dispatch_marker_confirm_launched "$issue_num" "dev-new"
      JUST_DISPATCHED+=("$issue_num")
      continue
    fi

    # end_turn|completed — INV-35 review-aware routing (carve-out from
    # INV-12). The handler classifies the most recent post-completion
    # review verdict and either:
    #   - emits the original INV-12-completed operator-handoff marker, OR
    #   - flips back to pending-review (non-substantive review failure), OR
    #   - mints a fresh dev-new session via PTL pattern (substantive failure).
    # See docs/pipeline/dispatcher-flow.md § Step 4b.5.1 and INV-35.
    handle_completed_session_routing "$issue_num" "$session_id" "$_session_end_iso"
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  # [INV-108] (302b, #361 R1) — see the Step 2 comment above.
  if ! acquire_dispatch_marker "$issue_num" "dev-resume"; then
    log "  issue #${issue_num} dev-resume dispatch marker held by a concurrent tick — skipping ([INV-108])"
    # Step-5 protection for the concurrent winner — see the Step 2 comment.
    JUST_DISPATCHED+=("$issue_num")
    continue
  fi

  log "  dispatching dev-resume for issue #${issue_num} (session: ${session_id:-<none>})"
  label_swap "$issue_num" "pending-dev" "in-progress"
  post_dispatch_token "$issue_num" "dev-resume"
  # [Lane-GC PR-6 / INV-119] — see the Step 2 rc=75 comment above.
  # [review P1-2] non-75 non-zero rc re-raises via exit — see the Step 2
  # comment above.
  _dispatch_rc=0
  dispatch dev-resume "$issue_num" "$session_id" || _dispatch_rc=$?
  if is_dispatch_deferred_rc "$_dispatch_rc"; then
    handle_dispatch_deferred "$issue_num" "dev-resume" "in-progress" "pending-dev"
    continue
  elif [ "$_dispatch_rc" -ne 0 ]; then
    exit "$_dispatch_rc"
  fi
  # [INV-108] (#361 review [P1]) — see the Step 2 confirm comment above.
  dispatch_marker_confirm_launched "$issue_num" "dev-resume"
  JUST_DISPATCHED+=("$issue_num")
done

# ---------------------------------------------------------------------------
# Step 5: stale detection
# ---------------------------------------------------------------------------
log "Step 5: stale detection..."

# Export JUST_DISPATCHED so was_just_dispatched() in lib-dispatch.sh can read.
# [#456] `unset` before the scalar assignment: bash's `existing_array_name=
# "scalar"` only overwrites index 0 of an existing array, leaving indices
# >= 1 untouched, which left the printed array form (and the "Tick complete"
# log line) with duplicated trailing entries (e.g. "84 85" -> "84 85 85").
JUST_DISPATCHED_STR="${JUST_DISPATCHED[*]:-}"
unset JUST_DISPATCHED
export JUST_DISPATCHED="$JUST_DISPATCHED_STR"

candidates=$(list_stale_candidates)
cand_count=$(jq 'length' <<<"$candidates")
log "  $cand_count active issue(s) to evaluate"

for i in $(seq 0 $((cand_count - 1))); do
  issue_num=$(jq -r ".[$i].number" <<<"$candidates")
  # [W1a, #371] list_stale_candidates now returns the NORMALIZED itp_list_by_state
  # shape — `labels` is already an array of NAME strings, not `{name}` objects.
  labels=$(jq -r ".[$i].labels[]" <<<"$candidates")

  # Skip freshly dispatched ([INV-09]).
  if was_just_dispatched "$issue_num"; then
    log "  issue #${issue_num} just dispatched this tick — skipping"
    continue
  fi

  # Bug 1 (#99) [INV-17]: skip stale detection during the cold-start grace
  # window. JUST_DISPATCHED only protects the current tick; a wrapper that
  # hasn't yet written its PID file (session spawn + model first call can
  # take 1–3 min) must not be classified as crashed on the very next tick.
  # Defaults to 10 min via DISPATCH_GRACE_PERIOD_SECONDS=600.
  if is_within_grace_period "$issue_num"; then
    log "  issue #${issue_num} within dispatch grace period — skipping (#99 Bug 1)"
    continue
  fi

  # Determine which active label and corresponding PID file kind.
  if grep -q "^in-progress$" <<<"$labels"; then
    kind="issue"
  elif grep -q "^reviewing$" <<<"$labels"; then
    kind="review"
  else
    # Should not happen given list_stale_candidates filter, but defensive.
    continue
  fi

  if pid_alive "$kind" "$issue_num"; then
    # ALIVE branch — only Step 5a applies (and only for in-progress; review
    # wrappers are bounded by their own polling, no SIGTERM logic).
    if [ "$kind" != "issue" ]; then
      continue
    fi

    pid=$(get_pid "$kind" "$issue_num")

    # Step 5a: ALIVE + PR ready for review.
    pr_info=$(fetch_pr_for_issue "$issue_num" "number,body,updatedAt")
    if [ -z "$pr_info" ]; then
      # No PR — agent still developing, leave alone.
      continue
    fi

    pr_num=$(jq -r '.number // empty' <<<"$pr_info")
    pr_updated_at=$(jq -r '.updatedAt // empty' <<<"$pr_info")

    # Validate jq outputs (schema drift / partial JSON guard).
    if ! [[ "$pr_num" =~ ^[0-9]+$ ]] || [ -z "$pr_updated_at" ]; then
      echo "WARN: malformed PR info for issue ${issue_num} (PR_NUM='$pr_num', PR_UPDATED_AT='$pr_updated_at'); leaving as-is" >&2
      continue
    fi

    if ! ci_is_green "$pr_num"; then
      # CI not green — agent still working.
      continue
    fi

    idle_seconds=$(pr_idle_seconds "$pr_updated_at")
    if [ -z "$idle_seconds" ]; then
      echo "WARN: cannot parse PR.updatedAt='${pr_updated_at}' for issue ${issue_num}; leaving as-is" >&2
      continue
    fi

    # [INV-10] strict > 300s. Necessary but — since [INV-137] — no longer
    # sufficient on its own: PR.updatedAt does not move while the agent
    # edits/tests/builds locally between pushes ([INV-137]).
    if [ "$idle_seconds" -le 300 ]; then
      # Recent activity — agent may be cleaning up. Leave alone.
      continue
    fi

    # [INV-137] Initial agent-progress-lease snapshot. FRESH and UNKNOWN
    # both mean "do not SIGTERM" — UNKNOWN is fail-safe by construction
    # (never falls back to the idle gate alone). Only STALE proceeds.
    _dps_backend="${EXECUTION_BACKEND:-local}"
    if [ "$_dps_backend" = "remote-aws-ssm" ]; then
      snapshot=$(_remote_dev_progress_snapshot_query "$issue_num")
    else
      snapshot=$(dev_progress_snapshot "$issue_num")
    fi
    snap_state=$(jq -r '.state // "UNKNOWN"' <<<"$snapshot" 2>/dev/null) || snap_state="UNKNOWN"

    if [ "$snap_state" != "STALE" ]; then
      if [ "$snap_state" = "UNKNOWN" ]; then
        snap_reason=$(jq -r '.reason // "unknown"' <<<"$snapshot" 2>/dev/null) || snap_reason="unknown"
        echo "WARN: issue ${issue_num} agent-progress snapshot is UNKNOWN (reason=${snap_reason}) — leaving as-is [INV-137]" >&2
      fi
      # FRESH (or UNKNOWN) — agent is actively working (or we cannot prove
      # otherwise). Leave alone.
      continue
    fi

    snap_pid=$(jq -r '.pid // empty' <<<"$snapshot" 2>/dev/null)
    snap_run_id=$(jq -r '.run_id // empty' <<<"$snapshot" 2>/dev/null)
    snap_age=$(jq -r '.age // empty' <<<"$snapshot" 2>/dev/null)
    if [ -z "$snap_pid" ] || [ -z "$snap_run_id" ] || [ -z "$snap_age" ]; then
      echo "WARN: issue ${issue_num} STALE snapshot missing pid/run_id/age fields — leaving as-is [INV-137]" >&2
      continue
    fi

    # Final pre-kill recheck ([INV-137]): re-verify liveness AND re-run the
    # snapshot, requiring STALE with the SAME pid/run_id observed above.
    # Any mismatch/FRESH/UNKNOWN aborts — no comment, no transition.
    if [ "$_dps_backend" = "remote-aws-ssm" ]; then
      # Remote: dispatcher-side `$pid` (from `get_pid`) is ALWAYS empty
      # under this backend (the PID file lives on the wrapper box) — a
      # local `kill -0 "$pid"` here would always report gone and can never
      # be used as a preliminary liveness check. Instead, ONE additional
      # SSM round-trip performs the pid-file-equality recheck, the
      # snapshot re-validation, AND the kill atomically ON THE WRAPPER
      # HOST — no gap between the final recheck and the signal for a race
      # to land in.
      cas_result=$(_remote_dev_progress_compare_and_signal "$issue_num" "$snap_pid" "$snap_run_id")
      case "$cas_result" in
        SIGNALED)
          kill_note="Sent SIGTERM to PID ${snap_pid}"
          ;;
        *)
          echo "INFO: issue ${issue_num} remote compare-and-signal aborted (${cas_result}); deferring to next cycle [INV-137]" >&2
          continue
          ;;
      esac
    else
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "INFO: wrapper PID ${pid} for issue ${issue_num} exited between checks; deferring to next cycle" >&2
        continue
      fi
      recheck_pid=$(get_pid "$kind" "$issue_num")
      if [ "$recheck_pid" != "$snap_pid" ]; then
        echo "INFO: issue ${issue_num} PID changed between checks (was ${snap_pid}, now ${recheck_pid}); deferring to next cycle [INV-137]" >&2
        continue
      fi
      recheck_snapshot=$(dev_progress_snapshot "$issue_num")
      recheck_state=$(jq -r '.state // "UNKNOWN"' <<<"$recheck_snapshot" 2>/dev/null) || recheck_state="UNKNOWN"
      recheck_run_id=$(jq -r '.run_id // empty' <<<"$recheck_snapshot" 2>/dev/null)
      if [ "$recheck_state" != "STALE" ] || [ "$recheck_run_id" != "$snap_run_id" ]; then
        echo "INFO: issue ${issue_num} progress snapshot changed on final recheck (state=${recheck_state}); deferring to next cycle [INV-137]" >&2
        continue
      fi

      # Fire SIGTERM and transition to pending-review. Signal snap_pid (not
      # the outer $pid) — recheck_pid == snap_pid was just proven above, so
      # this makes "what we validated is what we signal" explicit rather
      # than relying on the two happening to hold the same value.
      if kill "$snap_pid" 2>/dev/null; then
        kill_note="Sent SIGTERM to PID ${snap_pid}"
      else
        echo "INFO: issue ${issue_num} PID ${snap_pid} already gone at signal time; deferring to next cycle [INV-137]" >&2
        continue
      fi
    fi

    itp_post_comment "$issue_num" \
      "Dev process still alive but PR #${pr_num} is ready (all CI checks passed, PR inactive ${idle_seconds}s, no agent progress for ${snap_age}s). ${kill_note}. Moving to pending-review."
    label_swap "$issue_num" "in-progress" "pending-review"

  else
    # DEAD branch — Step 5b.
    #
    # [Lane-GC PR-6 / INV-119] DEFERRED fast-return — BEFORE the no-PR /
    # near-success checks below. `pid_alive` returned 1 (not-alive) above,
    # but a DEFERRED verdict means the wrapper host's own back-pressure
    # gate DEFINITELY refused to spawn (a known state), never a crash — the
    # dev/review no-PR crash branches below would otherwise post a false
    # "Task appears to have crashed" comment and flip the label, exactly
    # the misattribution this PR closes for the remote-aws-ssm backend.
    # This side channel (`PID_ALIVE_LAST_VERDICT`) is set ONLY by the
    # remote-backend short-circuit inside `pid_alive` — under the local
    # backend it is always empty here; the SAME rc=75 is normally caught
    # synchronously by `handle_dispatch_deferred` at the `dispatch()` call
    # site itself, and — as of [#444] — additionally reverted at the
    # SOURCE by the gate itself (`dispatch-local.sh::_gate_revert_label`)
    # and, as a last-resort defense-in-depth net for a local-backend defer
    # that bypassed BOTH of those, by the local-backend defer-marker check
    # immediately below ([#444, B1 edit 1]). No comment, no label flip, no
    # retry decrement — just log and move to the next candidate.
    if [ "$PID_ALIVE_LAST_VERDICT" = "DEFERRED" ]; then
      # [#444, B1 edit 2] Age bound on the remote fast-return — consistency
      # with the local-backend expiry handling below. Currently unreachable
      # in production for ages >= the threshold: the remote probe itself
      # (liveness-check-remote-aws-ssm.sh) stops reporting DEFERRED past
      # DEFER_MAX_AGE, so PID_ALIVE_LAST_VERDICT never carries an
      # already-expired age here. This is deliberate, documented
      # belt-and-suspenders against a future probe change — the label-
      # active-on-purpose window this DEFERRED fast-return relies on is now
      # bounded, matching the local-backend behavior instead of leaving a
      # theoretical unbounded active-label window if that probe's own
      # ceiling were ever relaxed.
      _defer_max_age="$(_defer_marker_max_age)"
      if [[ "${PID_ALIVE_LAST_DEFERRED_AGE:-}" =~ ^[0-9]+$ ]] && [ "$PID_ALIVE_LAST_DEFERRED_AGE" -ge "$_defer_max_age" ]; then
        log "  issue #${issue_num} (${kind}) dispatch DEFERRED verdict has EXPIRED (age=${PID_ALIVE_LAST_DEFERRED_AGE}s >= ${_defer_max_age}s) — reverting label (not a crash), no comment, no retry decrement ([#444, B1])"
        # [review P1, #444] _revert_defer_strand's own rc is checked (not
        # swallowed) — a failed revert (code host still unreachable) still
        # `continue`s (this stays a defer, never a crash, regardless), but
        # the failure is logged so it's operator-visible and so it's clear
        # the label may STILL be stranded; the SAME EXPIRED verdict simply
        # recomputes and retries on the very next tick since nothing here
        # persists a "handled" signal for the remote path to consume.
        if ! _revert_defer_strand "$issue_num" "$kind"; then
          log "  issue #${issue_num} (${kind}) EXPIRED remote DEFERRED revert FAILED — label may still be stranded; will retry next tick ([#444, B1, review P1])"
        fi
      else
        log "  issue #${issue_num} (${kind}) dispatch DEFERRED by the wrapper host's back-pressure gate (age=${PID_ALIVE_LAST_DEFERRED_AGE:-?}s) — not a crash, no label change, no retry decrement ([Lane-GC PR-6 / INV-119])"
      fi
      continue
    fi

    # [#444, B1 edit 1] Local-backend defer-marker check. The remote
    # short-circuit above (PID_ALIVE_LAST_VERDICT) is the ONLY place a
    # remote-backend defer is ever surfaced to pid_alive's side channel —
    # under EXECUTION_BACKEND=local that side channel is never set (the
    # SAME rc=75 is instead caught synchronously by handle_dispatch_deferred
    # at the dispatch() call site, or — when that catch is bypassed, e.g. the
    # dispatching session ended before observing rc=75 — left stranded with
    # no verdict at all). This is dispatcher-tick.sh's only chance to notice
    # a stranded local-backend defer: the dispatcher and wrapper host are
    # the SAME machine under the local backend, so the marker
    # dispatch-local.sh wrote is directly readable here.
    if [ "${EXECUTION_BACKEND:-local}" = "local" ]; then
      _defer_verdict=$(_local_defer_marker_verdict "$kind" "$issue_num")
      case "$_defer_verdict" in
        FRESH)
          log "  issue #${issue_num} (${kind}) has a FRESH local defer marker — not a crash, no label change, no retry decrement ([#444, B1])"
          continue
          ;;
        EXPIRED)
          log "  issue #${issue_num} (${kind}) has an EXPIRED local defer marker — reverting label (not a crash), no comment, no retry decrement ([#444, B1])"
          # [review P1, #444] Only consume (remove) the defer marker AFTER a
          # CONFIRMED label revert. If the code host is still unreachable
          # (the same condition that stranded the label in the first place
          # may still hold), removing the marker here would delete the one
          # signal a LATER tick uses to know this is a defer, not a crash —
          # once connectivity returns, that later tick would fall straight
          # into the normal crash-declare branch for what was always a
          # defer. Leaving the (still-EXPIRED) marker in place means this
          # SAME branch simply re-attempts the revert next tick instead.
          if _revert_defer_strand "$issue_num" "$kind"; then
            rm -f "$(_local_defer_marker_path "$kind" "$issue_num")" 2>/dev/null || true
          else
            log "  issue #${issue_num} (${kind}) EXPIRED local defer revert FAILED — marker kept for a retry next tick, label may still be stranded ([#444, B1, review P1])"
          fi
          continue
          ;;
      esac
    fi

    if [ "$kind" = "issue" ]; then
      # DEAD + in-progress: branch on whether a PR exists, and if it does,
      # branch again on whether its HEAD has new commits since the last
      # review trailer ([INV-04], [INV-07]).
      pr_info=$(fetch_pr_for_issue "$issue_num" "number,body,headRefOid")

      if [ -z "$pr_info" ]; then
        # No PR. Before declaring crashed, cross-check in-flight signals
        # — the dev-side analog of #111's review_near_success (INV-24).
        # dev_near_success returns 0 when ANY of these is true within
        # DEV_NEAR_SUCCESS_WINDOW_SECONDS:
        #   - most recent "Agent Session Report (Dev) ... Exit code: 0"
        #     within window (agent finished cleanly; PR not yet linked)
        #   - most recent "Dev Session ID:" comment within window
        #     (startup confirmed; pid_alive miss is a probe race)
        #   - defensive `kill -0 <pid>` re-check now succeeds
        # When any signal fires, leave `in-progress` alone and defer
        # — the next tick will re-evaluate after either the wrapper
        # exits naturally or the signals all expire ([INV-27]).
        if dev_near_success "$issue_num"; then
          echo "INFO: issue ${issue_num} dev wrapper pid_alive miss but in-flight signal positive; deferring crash declaration ([INV-27])" >&2
          continue
        fi
        # [INV-70] Metrics: dispatcher declared a dev wrapper DEAD with no PR.
        # Class false-stall (the near-success cross-check above already cleared,
        # so this is a real crash declaration, not a probe race). Best-effort.
        if declare -F metrics_emit >/dev/null 2>&1; then
          metrics_emit dispatch_stale "issue=${issue_num}" kind=in-progress failure_class=false-stall || true
        fi
        # [INV-72] If the dev wrapper surfaced a config-class error envelope,
        # link it instead of the opaque generic crash text so a config crash is
        # not misreported as a transient one. Still move to pending-dev — the
        # operator fixes the conf, then the retry succeeds.
        _env_summary=$(recent_error_envelope "$issue_num" || true)
        if [ -n "$_env_summary" ]; then
          itp_post_comment "$issue_num" \
            "Dev wrapper aborted on a configuration error (no PR found): ${_env_summary}. See the surfaced error envelope above. Moving to pending-dev — fix the configuration before the retry."
        else
          itp_post_comment "$issue_num" \
            "Task appears to have crashed (no PR found). Moving to pending-dev for retry."
        fi
        unset _env_summary
        label_swap "$issue_num" "in-progress" "pending-dev"
        continue
      fi

      current_head=$(jq -r '.headRefOid // empty' <<<"$pr_info")
      last_head=$(last_reviewed_head "$issue_num")

      if [ -n "$last_head" ] && [ -n "$current_head" ] && [ "$current_head" = "$last_head" ]; then
        # No new commits since last review — retry dev so it can act on
        # existing review feedback. ([INV-06] keyword guard: avoid
        # "crashed" / "process not found" so Step 4a doesn't count this.)
        itp_post_comment "$issue_num" \
          "Dev process exited (no new commits since last review at \`${last_head}\`). Moving to pending-dev for retry."
        label_swap "$issue_num" "in-progress" "pending-dev"
      else
        # PR has new commits OR no prior trailer — let review assess
        # ([INV-07] empty-trailer fallthrough).
        itp_post_comment "$issue_num" \
          "Dev process exited (PR found). Moving to pending-review for assessment."
        label_swap "$issue_num" "in-progress" "pending-review"
      fi
    else
      # DEAD + reviewing: review wrapper appears to have crashed.
      #
      # #111 Part A: cross-check PR-state signals before declaring
      # crashed. Long-running review wrappers (15-30 min E2E + multi-bot
      # rounds) routinely hit transient pid_alive races, and the
      # near-success window covers the wrapper's post-verdict / merge
      # tail. review_near_success returns 0 when ANY of these are true
      # within REVIEW_NEAR_SUCCESS_WINDOW_SECONDS:
      #   - PR.mergedAt within window
      #   - most recent APPROVED review within window
      #   - "Review PASSED|findings" comment within window
      #   - defensive `kill -0 <pid>` re-check now succeeds (race)
      # When any signal fires, leave `reviewing` alone and defer to next
      # tick — the wrapper either already finished or is mid-merge.
      if review_near_success "$issue_num"; then
        echo "INFO: issue ${issue_num} review wrapper pid_alive miss but PR-state signal positive; deferring crash declaration (#111 INV-24)" >&2
        continue
      fi
      # [INV-70] Metrics: dispatcher declared a review wrapper DEAD. Class
      # false-stall (the review_near_success cross-check above already cleared).
      if declare -F metrics_emit >/dev/null 2>&1; then
        metrics_emit dispatch_stale "issue=${issue_num}" kind=reviewing failure_class=false-stall || true
      fi
      # [INV-72] Link a surfaced config-class error envelope instead of the
      # opaque generic crash text. The review wrapper aborts at startup before
      # its EXIT trap is installed, so a config crash would otherwise read as a
      # transient one.
      _env_summary=$(recent_error_envelope "$issue_num" || true)
      if [ -n "$_env_summary" ]; then
        itp_post_comment "$issue_num" \
          "Review wrapper aborted on a configuration error: ${_env_summary}. See the surfaced error envelope above. Moving to pending-dev — fix the configuration before the retry."
      else
        itp_post_comment "$issue_num" \
          "Review process appears to have crashed. Moving to pending-dev for retry."
      fi
      unset _env_summary
      label_swap "$issue_num" "reviewing" "pending-dev"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Step 6: liveness watchdog ([INV-128])
# ---------------------------------------------------------------------------
# Generic class-level backstop for the "permanent silent park" bug class
# (INV-105/111/122/123/125 were all per-entry point-fixes). Runs AFTER Step 5
# so was_just_dispatched (JUST_DISPATCHED, exported as a scalar above) also
# protects any issue Steps 2-4 dispatched THIS tick. Scoped to `pending-dev`
# and `pending-review` only this iteration ([R2]) — `in-progress`/`reviewing`
# are already covered by Step 5b's DEAD-process scans.
log "Step 6: liveness watchdog..."
run_liveness_watchdog

# [INV-70] Retention built into the collector: prune the metrics log once per
# tick (default 90d). The dispatcher runs on a cron cadence, so this is the
# steady drumbeat that bounds the log even for a project whose wrappers rarely
# run. Best-effort — metrics_prune always returns 0, so a prune failure can
# never affect the tick. (#228 review: prune was opt-in via the report only.)
if declare -F metrics_prune >/dev/null 2>&1; then
  metrics_prune "${METRICS_RETENTION_DAYS:-90}" 2>/dev/null || true
fi

log "Tick complete. Dispatched: ${JUST_DISPATCHED[*]:-<none>}"
