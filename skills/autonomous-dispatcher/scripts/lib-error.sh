#!/bin/bash
# lib-error.sh — operator error envelope helper (issue #231, INV-72).
#
# Renders + surfaces the operator-facing error envelope defined by the adapter
# spec (#229 / INV-66, docs/pipeline/schemas/error-envelope.schema.json):
#
#   { "schema_version": 1, "class": "config", "code": "ADT_CFG_MISSING_KEY",
#     "problem": "…", "cause": "…", "remediation": "…", "doc": "…",
#     "surface": "issue-comment" }
#
# WHY: today's fail-loud is LOG-ONLY in every config-class startup abort path.
# A wrapper that aborts at startup (bad conf, missing app creds, token-mint
# failure, invalid E2E_MODE, launcher/CLI mismatch) leaves the issue stuck in
# `reviewing`/`in-progress` with ZERO GitHub-visible signal — the operator
# discovers it hours later by log spelunking. The crux is trap timing: these
# validations abort BEFORE `trap cleanup EXIT` is installed, so the wrappers'
# existing crash-recovery comment path never runs for them. lib-error.sh gives
# those paths a deterministic "surface this on the issue (or as a dispatcher
# alert), never log-only" primitive (Clause E2 / INV-72).
#
# Two functions:
#   error_envelope <code> <problem> <cause> <remediation> [doc] [class]
#       Renders the single canonical envelope text (human block + an embedded
#       machine-readable `<!-- adt-error-envelope: {json} -->` marker the
#       dispatcher Step-5 stale handler can detect). Used for BOTH log lines and
#       comment bodies. Returns 1 (and emits nothing) on a malformed code
#       (Clause E3) or empty remediation (Clause E1).
#   error_surface <issue|-> <code> <problem> <cause> <remediation> [doc] [class]
#       Renders AND posts the envelope as an issue comment via the token-refresh
#       `gh` proxy (the identity-correct path post-verdict.sh uses). BEST-EFFORT:
#       if the post fails (or the proxy is missing, or no issue is known), it
#       degrades to log-only (envelope to stderr) and returns 0 anyway —
#       surfacing failure MUST NOT change the caller's exit code. A
#       `class=transient` envelope is never posted (it is log-only by contract);
#       an empty/`-` issue number routes to a dispatcher-alert log line (the
#       tick-global dispatcher aborts have no issue to comment on).
#
# Sourcing: source via LIB_DIR (INV-65 two-dir resolution). lib-error.sh needs
# NO project-side symlink and sources no sibling. To post, it resolves the
# token-refresh `gh` proxy at ${AUTONOMOUS_CONF_DIR}/gh (the project-side
# scripts/ dir lib-auth.sh anchors), exactly as post-verdict.sh resolves it.

# Guard against double-source (the wrappers source many libs).
if [[ -n "${_LIB_ERROR_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_LIB_ERROR_SOURCED=1

# [INV-72] lib-error.sh's OWN dir in the skill tree (NOT the project-side
# AUTONOMOUS_CONF_DIR). Used to locate the co-located `gh-with-token-refresh.sh`
# as a fallback when the project-side `${AUTONOMOUS_CONF_DIR}/gh` proxy symlink
# does not exist yet — i.e. for config validations that abort BEFORE
# setup_github_auth has materialized that symlink (a fresh install, or a
# source-time launcher guard). gh-with-token-refresh.sh is mode-agnostic
# (token mode → exec real gh with host auth; app mode → reads GH_TOKEN_FILE when
# set), so invoking it directly preserves the same identity guarantee (INV-56)
# the symlink provides — it just doesn't depend on the symlink being installed.
_LIB_ERROR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# _error_log <msg...> — internal log line. Prefixed so it's grep-able in the
# per-issue agent log / dispatcher run log.
_error_log() {
  echo "[lib-error] $*" >&2
}

# _error_envelope_json <code> <problem> <cause> <remediation> <doc> <class> <surface>
# Builds the schema-conformant JSON with jq -nc (special chars in any field —
# backticks, quotes, $(), newlines — are safe; jq does the escaping, no shell
# re-evaluation). Echoes the compact JSON on stdout. `doc` is omitted from the
# object when empty (the schema marks it optional).
_error_envelope_json() {
  local code="$1" problem="$2" cause="$3" remediation="$4" doc="$5" class="$6" surface="$7"
  if [[ -n "$doc" ]]; then
    jq -nc \
      --arg code "$code" --arg problem "$problem" --arg cause "$cause" \
      --arg remediation "$remediation" --arg doc "$doc" \
      --arg class "$class" --arg surface "$surface" \
      '{schema_version: 1, class: $class, code: $code, problem: $problem,
        cause: $cause, remediation: $remediation, doc: $doc, surface: $surface}'
  else
    jq -nc \
      --arg code "$code" --arg problem "$problem" --arg cause "$cause" \
      --arg remediation "$remediation" \
      --arg class "$class" --arg surface "$surface" \
      '{schema_version: 1, class: $class, code: $code, problem: $problem,
        cause: $cause, remediation: $remediation, surface: $surface}'
  fi
}

# _error_surface_for_class <class> — the spec-mandated surface for a class when
# the caller does not pin one. Clause E2: operator-actionable classes
# (config/auth/quota) surface on the issue; only transient is log-only.
_error_surface_for_class() {
  case "$1" in
    transient) echo "log-only" ;;
    *)         echo "issue-comment" ;;
  esac
}

# error_peek_issue_arg "$@" — NON-DESTRUCTIVE early scan of the wrapper's argv
# for `--issue <N>`. Echoes the issue number when present AND a positive integer,
# else echoes `-` (the dispatcher-alert sentinel). [INV-72] Both wrappers run
# their config validations BEFORE the authoritative arg-parse loop; this lets a
# validation surface its envelope on the *issue* (not just a dispatcher-alert)
# when the wrapper was launched for one. It does NOT consume or validate args
# beyond the issue number — the real arg-parse loop downstream stays the single
# source of truth for usage errors / --validate-config-only / unknown options.
error_peek_issue_arg() {
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--issue" ]]; then
      if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
        echo "$2"
      else
        echo "-"
      fi
      return 0
    fi
    shift
  done
  echo "-"
}

# error_envelope <code> <problem> <cause> <remediation> [doc] [class] [surface]
#
# Renders the canonical envelope (human block + embedded marker) on stdout.
# Returns 1 without emitting anything when:
#   - <code> is not a stable UPPER_SNAKE identifier (Clause E3), or
#   - <remediation> is empty (Clause E1).
# `class` defaults to "config" (the common envelope case). `surface` defaults to
# the class-derived value (_error_surface_for_class), but a caller that already
# knows the true surface MAY pin it via the optional 7th arg — error_surface
# passes `dispatcher-alert` when there is no issue context so the embedded marker
# JSON's `surface` matches reality (INV-72 / the schema), rather than the
# class-default `issue-comment`. An invalid override is ignored (falls back to
# the class-derived surface). A config/auth/quota class with a `log-only`
# override is rejected (Clause E2 — operator-actionable classes never log-only).
error_envelope() {
  local code="${1:-}" problem="${2:-}" cause="${3:-}" remediation="${4:-}"
  local doc="${5:-}" class="${6:-config}" surface_override="${7:-}"

  # Clause E3 — stable UPPER_SNAKE code.
  if ! [[ "$code" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    _error_log "error_envelope: refusing non-conformant code '${code}' (must be UPPER_SNAKE, Clause E3)"
    return 1
  fi
  # Clause E1 — remediation REQUIRED.
  if [[ -z "$remediation" ]]; then
    _error_log "error_envelope: refusing envelope ${code} with empty remediation (Clause E1)"
    return 1
  fi
  case "$class" in
    config|auth|quota|transient) ;;
    *)
      _error_log "error_envelope: unknown class '${class}' for ${code}; defaulting to config"
      class="config" ;;
  esac

  local surface; surface="$(_error_surface_for_class "$class")"
  # Honor a valid surface override, but never let it violate Clause E2 (an
  # operator-actionable class surfaced log-only is non-conformant — the schema
  # rejects it, so we ignore such an override and keep the class default).
  case "$surface_override" in
    issue-comment|dispatcher-alert)
      surface="$surface_override" ;;
    log-only)
      if [[ "$class" == "transient" ]]; then
        surface="log-only"
      else
        _error_log "error_envelope: ignoring log-only surface override for operator-actionable class '${class}' (Clause E2)"
      fi ;;
    "") ;;  # no override
    *)
      _error_log "error_envelope: ignoring invalid surface override '${surface_override}' for ${code}" ;;
  esac
  local json; json="$(_error_envelope_json "$code" "$problem" "$cause" "$remediation" "$doc" "$class" "$surface")"

  # Class-accurate header. config/auth/quota are operator-actionable; transient
  # is informational (it is never posted — surface=log-only).
  local header
  case "$class" in
    auth)      header="**Authentication error (operator action required)**" ;;
    quota)     header="**Quota exhausted (operator action required)**" ;;
    transient) header="**Transient failure (auto-retried)**" ;;
    *)         header="**Configuration error (operator action required)**" ;;
  esac

  # Human-readable block + machine-readable marker. The marker is an HTML
  # comment so it does not visually clutter the GitHub issue UI, and the
  # dispatcher Step-5 stale handler greps for `adt-error-envelope:` to detect a
  # surfaced envelope and link it instead of the generic "crashed" message.
  #
  # NOTE: every bullet format string begins with a literal `-`, which the bash
  # `printf` BUILTIN parses as an option flag ("printf: - : invalid option")
  # before reaching the format. `--` terminates option parsing so the dash is
  # taken literally. Without it the entire human block silently vanishes on the
  # execution host (bash builtin printf) — only the header + hidden marker post,
  # defeating the whole operator-visible signal this lib exists to provide.
  printf '%s\n\n' "$header"
  # shellcheck disable=SC2016  # backticks are literal markdown, %s is a printf placeholder
  printf -- '- **Code:** `%s`\n' "$code"
  printf -- '- **Class:** %s\n' "$class"
  printf -- '- **Problem:** %s\n' "$problem"
  printf -- '- **Cause:** %s\n' "$cause"
  printf -- '- **Remediation:** %s\n' "$remediation"
  if [[ -n "$doc" ]]; then
    printf -- '- **Doc:** %s\n' "$doc"
  fi
  printf '\n<!-- adt-error-envelope: %s -->\n' "$json"
  return 0
}

# error_surface <issue|-> <code> <problem> <cause> <remediation> [doc] [class]
#
# Renders the envelope and surfaces it. Always returns 0 (best-effort —
# surfacing failure MUST NOT change the caller's exit code). Behavior:
#   - class=transient            → log-only (no post); envelope to stderr.
#   - issue empty or "-"         → dispatcher-alert; envelope to stderr (the
#                                  tick-global dispatcher aborts have no issue).
#   - otherwise                  → post as an issue comment via the token-refresh
#                                  `gh` proxy (project-side symlink, else the
#                                  co-located gh-with-token-refresh.sh fallback);
#                                  on ANY failure (unresolvable proxy, non-zero
#                                  post) degrade to log-only.
# In EVERY case the full rendered envelope is also written to the wrapper log
# (stderr) — including the success path — so "the same envelope to the log AND
# the issue" (#231) holds regardless of whether the post landed.
# The target repo is REPO / GITHUB_REPO, falling back to ${REPO_OWNER}/${REPO_NAME}
# (so a missing-REPO envelope, surfaced before `cd "$PROJECT_DIR"`, still posts).
# The EFFECTIVE surface is decided BEFORE rendering and pinned into the marker
# JSON, so a dispatcher-alert envelope's embedded `surface` reads
# `dispatcher-alert` (not the class-default `issue-comment`) — matching INV-72
# and the schema examples.
# A malformed envelope (bad code / empty remediation) is logged and the function
# returns 0 without posting (the abort still happens at the call site).
error_surface() {
  local issue="${1:-}" code="${2:-}" problem="${3:-}" cause="${4:-}"
  local remediation="${5:-}" doc="${6:-}" class="${7:-config}"

  # Decide the EFFECTIVE surface up front so the rendered marker JSON matches
  # where the envelope actually goes (INV-72 / the schema). A transient class is
  # always log-only; no issue context → dispatcher-alert; otherwise issue-comment.
  # This must precede rendering — otherwise the marker would carry the
  # class-default `issue-comment` even for a dispatcher-alert (the P2 bug).
  local effective_surface
  if [[ "$class" == "transient" ]]; then
    effective_surface="log-only"
  elif [[ -z "$issue" || "$issue" == "-" ]]; then
    effective_surface="dispatcher-alert"
  else
    effective_surface="issue-comment"
  fi

  local rendered
  if ! rendered="$(error_envelope "$code" "$problem" "$cause" "$remediation" "$doc" "$class" "$effective_surface")"; then
    # error_envelope already logged the conformance failure. Surface the raw
    # facts so the operator still sees something, then return 0.
    _error_log "error_surface: ${code:-<no-code>}: ${problem:-<no-problem>} | ${cause:-<no-cause>}"
    return 0
  fi

  # class=transient is log-only by contract (Clause E2). Never post it.
  if [[ "$class" == "transient" ]]; then
    _error_log "transient envelope (log-only): ${code}: ${problem}"
    return 0
  fi

  # No issue context → dispatcher-alert. Emit to the log; the OpenClaw
  # dispatcher agent reads its run log. (We do NOT invent a separate channel —
  # out of scope per #231.) The marker now correctly reads surface=dispatcher-alert.
  if [[ -z "$issue" || "$issue" == "-" ]]; then
    _error_log "dispatcher-alert envelope ${code}:"
    printf '%s\n' "$rendered" >&2
    return 0
  fi

  # Resolve the token-refresh `gh` proxy. Preference order:
  #   1. The project-side `${AUTONOMOUS_CONF_DIR}/gh` symlink (the path
  #      post-verdict.sh uses) — present once setup_github_auth / an
  #      install-project-hooks run has materialized it.
  #   2. FALLBACK: the co-located gh-with-token-refresh.sh in lib-error.sh's own
  #      skill-tree dir. This is what the symlink points AT, and it is
  #      mode-agnostic + identity-correct (INV-56), so invoking it directly lets
  #      a config validation that aborts BEFORE setup_github_auth (a fresh
  #      install in token mode; a source-time launcher guard) still POST the
  #      envelope instead of degrading to log-only.
  # Either way we never fall back to bare PATH `gh` (it would mis-attribute the
  # comment to the host operator, INV-56).
  # Resolve the target repo. Prefer REPO / GITHUB_REPO, but fall back to
  # ${REPO_OWNER}/${REPO_NAME} — the surfaced error may BE `ADT_CFG_MISSING_KEY`
  # for REPO itself (with REPO_OWNER + REPO_NAME present), and the wrappers call
  # error_surface before `cd "$PROJECT_DIR"`, so a `gh --repo ""` would fail to
  # infer the repo outside a git checkout and the comment would never post.
  local gh_proxy="" repo="${REPO:-${GITHUB_REPO:-}}"
  if [[ -z "$repo" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
    repo="${REPO_OWNER}/${REPO_NAME}"
  fi
  if [[ -n "${AUTONOMOUS_CONF_DIR:-}" && -x "${AUTONOMOUS_CONF_DIR}/gh" ]]; then
    gh_proxy="${AUTONOMOUS_CONF_DIR}/gh"
  elif [[ -x "${_LIB_ERROR_DIR}/gh-with-token-refresh.sh" ]]; then
    gh_proxy="${_LIB_ERROR_DIR}/gh-with-token-refresh.sh"
  fi
  if [[ -z "$gh_proxy" ]]; then
    _error_log "token-refresh gh proxy not resolvable (AUTONOMOUS_CONF_DIR='${AUTONOMOUS_CONF_DIR:-}', skill-tree fallback '${_LIB_ERROR_DIR}/gh-with-token-refresh.sh' missing); degrading envelope ${code} to log-only:"
    printf '%s\n' "$rendered" >&2
    return 0
  fi

  # Run the post with errexit disabled so a non-zero `gh` never aborts the
  # caller (which runs under `set -euo pipefail`); restore the caller's exact
  # errexit state afterward rather than blindly re-enabling it.
  local post_out post_rc errexit_was_set=0
  [[ "$-" == *e* ]] && errexit_was_set=1
  set +e
  post_out="$("$gh_proxy" issue comment "$issue" --repo "$repo" --body "$rendered" 2>&1)"
  post_rc=$?
  [[ "$errexit_was_set" -eq 1 ]] && set -e

  if [[ "$post_rc" -ne 0 ]]; then
    _error_log "failed to surface envelope ${code} on issue #${issue} (gh rc=${post_rc}); degrading to log-only:"
    _error_log "$post_out"
    printf '%s\n' "$rendered" >&2
    return 0
  fi

  # [INV-72] The contract is "the SAME envelope to the wrapper log AND the issue"
  # (#231 / design). Emit the full rendered envelope to the log on the SUCCESS
  # path too — not just the short confirmation line — so the local run log always
  # carries the problem/cause/remediation/marker regardless of whether the post
  # landed (the failure/degradation paths above already print `rendered`).
  _error_log "surfaced envelope ${code} on issue #${issue}: ${post_out}"
  printf '%s\n' "$rendered" >&2
  return 0
}
