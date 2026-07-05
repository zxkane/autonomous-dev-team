#!/bin/bash
# tests/provider-conformance/fixtures/gitlab/hook.sh — GITLAB_TRANSPORT_HOOK
# fixture for run-provider-conformance.sh (#417 W-B, phase-3).
#
# Overrides `_gl_http` per the #416 transport contract: given
#   _gl_http <method> <path-or-url> <headers_out_file> [body-json]
# emit a canned response BODY on stdout and write the HTTP status +
# `x-next-page` (empty for single-page fixtures) headers to
# <headers_out_file>. Returns rc 0 iff the request "reached" our fixture
# (transport succeeded); the HTTP status classification (200 vs 4xx vs 5xx)
# is entirely inside <headers_out_file> per the contract — `_gl_api` reads
# it and applies --tolerate-status semantics.
#
# The hook is sourced ONCE per per-verb subshell by lib-gitlab-transport.sh
# via `source "$GITLAB_TRANSPORT_HOOK"`. `_gl_api` stays lib-owned so the
# pagination walk / 429 backoff / fail-closed discipline is preserved
# (spec [INV-113]).
#
# Fixture selection is PATH-driven — this hook has no state, so per-verb
# fixtures live either
#   (a) at a fixed path under $PAYLOADS (`gitlab-<name>.json`), keyed on
#       a substring match against the request path, or
#   (b) injected via _PCF_GL_PAYLOAD (per-invocation override, honored
#       ABOVE the path-driven default). The runner's write-verb arm sets
#       _PCF_GL_PAYLOAD so a single verb can control both the body served
#       AND the recorded argv.
#
# The recorded call log lives at $_PCF_GL_ARGV_FILE (one CALL/ARG block per
# invocation, blank-line separated) — the runner greps it for shape checks
# on write verbs (POST/PUT method, request-body content, path substring).
#
# Env inputs from the runner:
#   PAYLOADS          — absolute path to tests/provider-conformance/fixtures/payloads
#   _PCF_GL_ARGV_FILE — path to append CALL/ARG log to (per verb assertion)
#   _PCF_GL_PAYLOAD   — optional per-verb payload override (single file)
#   _PCF_GL_STATUS    — optional per-verb HTTP status override (default 200)

_gl_http() {
  local method="$1" path_or_url="$2" headers_out_file="$3" body_json="${4:-}"
  # Precedence: an explicit _PCF_GL_STATUS override from the caller wins over
  # any path-driven default (the /labels/… probe path defaults to 200 for
  # the [skip] branch; a caller simulating HTTP 500 needs its override to
  # survive the case arm below).
  local path body status_override="${_PCF_GL_STATUS:-}" status="${_PCF_GL_STATUS:-200}" payload_file=""

  # Strip the /api/v4/ prefix (absolute URLs are handled by the transport
  # lib's pagination walker; strip host+prefix to normalize the match key).
  path="${path_or_url#http*/api/v4/}"
  path="${path#/}"

  # Record the invocation for the runner's argv checks.
  if [[ -n "${_PCF_GL_ARGV_FILE:-}" ]]; then
    {
      printf 'CALL method=%s path=%s\n' "$method" "$path"
      if [[ -n "$body_json" ]]; then
        # Keep the body on ONE line (jq -c-shaped by the leaves already).
        printf 'BODY:%s\n' "$body_json"
      fi
      printf '\n'
    } >> "$_PCF_GL_ARGV_FILE"
  fi

  # Per-verb payload override wins.
  if [[ -n "${_PCF_GL_PAYLOAD:-}" && -f "${_PCF_GL_PAYLOAD}" ]]; then
    payload_file="$_PCF_GL_PAYLOAD"
  else
    # Path-driven default. Matches the substring most specific for each
    # verb's endpoint — kept simple; a real conformance run only exercises
    # ONE verb per subshell so a single canned payload per path is enough.
    case "$path" in
      *"/notes/"*|*"/notes"*)                          payload_file="${PAYLOADS}/gitlab-notes-list.json" ;;
      *"/resource_label_events"*)                      payload_file="${PAYLOADS}/gitlab-resource-label-events.json" ;;
      *"/labels/"*)                                    payload_file="${PAYLOADS}/gitlab-labels-view.json"; status=200 ;;
      *"/labels"*)                                     payload_file="${PAYLOADS}/gitlab-labels-create.json"; status=201 ;;
      *"/issues/"*)                                    payload_file="${PAYLOADS}/gitlab-issue-view.json" ;;
      *"/issues"*)                                     payload_file="${PAYLOADS}/gitlab-issues-list.json" ;;
      *)                                               payload_file="" ;;
    esac
    # Restore the caller's explicit override (the case arm above may have
    # bumped status to 200/201 based on the path — an override must win).
    [[ -n "$status_override" ]] && status="$status_override"
  fi

  # Emit HTTP status line + minimal headers. No x-next-page means the
  # pagination walk stops after this response — sufficient for hermetic
  # single-page fixtures.
  {
    printf 'HTTP/1.1 %s STUB\r\n' "$status"
    printf 'content-type: application/json\r\n'
    printf 'x-total-pages: 1\r\n'
    printf '\r\n'
  } > "$headers_out_file"

  # Emit body.
  if [[ -n "$payload_file" && -f "$payload_file" ]]; then
    cat "$payload_file"
  else
    # Path we don't recognize — emit empty JSON so `_gl_api`'s pagination
    # merge doesn't choke on non-JSON, and let the leaf handle it via its
    # own fail-CLOSED gate (jq type-check).
    printf '{}'
  fi
  return 0
}
