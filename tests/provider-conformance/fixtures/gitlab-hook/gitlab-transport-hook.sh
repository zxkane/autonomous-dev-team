#!/bin/bash
# tests/provider-conformance/fixtures/gitlab-hook/gitlab-transport-hook.sh —
# fixture transport hook for the `--chp gitlab` conformance axis (#418 AC1).
#
# Redefines `_gl_http` (the ONLY public override point per the #416 W-A frozen
# contract) with a path-pattern dispatcher that serves recorded GitLab REST v4
# payloads from the sibling gitlab-hook/ directory. Zero network I/O.
#
# The runner's per-verb assertions (`_run_findpr_assert`, `_run_prlist_assert`,
# `_run_pr_view_assert`, `_run_list_inline_comments_assert`,
# `_run_shape_assert(chp_review_threads)`, `_run_token_assert(chp_ci_status)`,
# `_run_token_assert(chp_mergeable)`) share ONE gh-fixture-path env var
# (`_PCF_GH_PAYLOAD`) as their per-call cue. Under `--chp gitlab` the runner
# still sets that env var, we don't need `gh` — we intercept the seam BELOW
# `_gl_api` here. We READ `_PCF_GH_PAYLOAD`'s basename to decide which
# gitlab-shape fixture to serve when the same URL is queried across different
# scenarios (e.g. the base `/merge_requests/42` endpoint is called by
# `chp_ci_status`, `chp_mergeable`, AND `chp_pr_view` — each expects a
# different `.head_pipeline.status` or `.detailed_merge_status` value).
#
# The `_PCF_GH_MODE=fail` env var (used by the runner's fail-CLOSED assertions)
# triggers an HTTP-500 response so the leaf's rc≠0 fail-CLOSED branch is
# exercised through the real `_gl_api` HTTP-status classification path.
#
# This hook is invoked ONLY under `run-provider-conformance.sh
# --chp gitlab --transport-hook <this-file>`; the github/github axis never
# reaches it (lib-code-host.sh sources chp-github.sh, whose leaves call `gh`
# not `_gl_api`).

# Sibling fixture directory — resolve via BASH_SOURCE so a relative
# --transport-hook path works from any cwd.
_CHP_GL_HOOK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"

# _hook_headers <headers_out_file> <status> [x-next-page]
# Emit a minimal headers response the transport lib can parse (matches the
# line-oriented format `_gl_api_extract_status` / `_gl_api_extract_header`
# expect: `HTTP/1.1 <status>` first, then optional `Header: Value` lines).
_hook_headers() {
  local out="$1" status="$2" next_page="${3:-}"
  {
    printf 'HTTP/1.1 %s OK\r\n' "$status"
    [[ -n "$next_page" ]] && printf 'x-next-page: %s\r\n' "$next_page"
    printf '\r\n'
  } > "$out"
}

# _hook_serve <headers_out_file> <fixture_basename>
# Serve a fixture body from gitlab-hook/ with a 200 response.
_hook_serve() {
  local out="$1" fixture="$2"
  _hook_headers "$out" "200"
  cat "$_CHP_GL_HOOK_DIR/$fixture"
}

# _hook_fail_500 <headers_out_file>
# Serve an HTTP 500 (empty body). The transport's non-2xx branch classifies
# this as a fail-CLOSED error; the leaf sees `_gl_api` rc≠0.
_hook_fail_500() {
  local out="$1"
  _hook_headers "$out" "500"
  printf 'internal server error\n'
}

# _hook_looks_malformed <file>
# rc 0 iff FILE's content is not parseable JSON (the runner's malformed-input
# probe writes garbage like `{ this is not json` to a per-verb file and sets
# `_PCF_GH_PAYLOAD` to that path). Empty file → also treated as malformed
# (the runner's malformed probes always write non-empty garbage; empty means
# the file just doesn't exist yet in some race, which is also degenerate).
_hook_looks_malformed() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  [[ -s "$f" ]] || return 0
  ! jq -e . >/dev/null 2>&1 < "$f"
}

# _hook_looks_empty_pr_list <file>
# rc 0 iff FILE's content is a github-shape empty-list envelope
# (`{"data":{"repository":{"pullRequests":{...,"nodes":[]}}}}`) OR a bare `[]`
# array. The runner's `_run_prlist_assert` empty-match test writes the former
# to `.pr-list-empty.json`; we translate that to an empty GitLab list.
_hook_looks_empty_pr_list() {
  local f="$1"
  [[ -f "$f" && -s "$f" ]] || return 1
  jq -e '
    (type == "array" and length == 0) or
    (type == "object" and .data.repository.pullRequests.nodes == [])
  ' >/dev/null 2>&1 < "$f"
}

# _hook_looks_bare_object <file>
# rc 0 iff FILE's content is one of the runner's non-array-page probe shapes:
# a bare `{}` (empty object) OR an error-envelope `{"message":"..."}` — the
# runner's `_run_list_inline_comments_assert` writes these to `.nonarr-*.json`
# / `.errobj-*.json` and expects the leaf's `type == "array"` gate to reject.
# Careful NOT to match a legitimate github fixture (`pr-view-valid.json` etc.)
# which is a top-level object with many keys — those go through the normal
# per-path dispatch below.
_hook_looks_bare_object() {
  local f="$1"
  [[ -f "$f" && -s "$f" ]] || return 1
  jq -e '
    type == "object" and (
      (length == 0) or
      (length == 1 and has("message"))
    )
  ' >/dev/null 2>&1 < "$f"
}

# _gl_http <method> <path> <headers_out> [body-json]
# Path-based dispatcher. The transport's next-page reconstruction re-sends
# the same base path with a `page=<n>` query — for THIS hook every fixture is
# single-page (the pagination walker sees no `x-next-page` header and exits
# after one call).
_gl_http() {
  local method="$1" path="$2" headers_out="$3"

  # Fail-CLOSED probe: the runner's `_PCF_GH_MODE=fail` scenarios expect the
  # leaf to surface rc≠0 EMPTY stdout. Return HTTP 500 so `_gl_api` classifies
  # it as an error (non-2xx, non-tolerated) and returns rc 1.
  if [[ "${_PCF_GH_MODE:-ok}" == "fail" ]]; then
    _hook_fail_500 "$headers_out"
    return 0
  fi

  # Strip query string for pattern matching (the transport keeps it on the URL,
  # but our dispatch is path-oriented).
  local bare_path="${path%%\?*}"

  # Which fixture to serve for the BASE `/merge_requests/42` endpoint depends
  # on the caller context, cued by `_PCF_GH_PAYLOAD`'s basename (a github-side
  # fixture name the runner sets per assertion). This is the only place the
  # per-assertion cue matters.
  local cue=""
  if [[ -n "${_PCF_GH_PAYLOAD:-}" ]]; then
    cue="$(basename "$_PCF_GH_PAYLOAD")"
  fi

  # Malformed-input probe: serve the payload file's content VERBATIM so the
  # leaf's own JSON-shape gate fires and returns rc≠0 EMPTY stdout. The runner
  # writes `{ this is not json` (and similar) to per-verb `.malformed-*.json`
  # files; my hook forwards them straight through the transport so my leaf's
  # `jq -e 'type == "array"'` (list/inline verbs) or `'type == "object"'`
  # (view/token verbs) gate catches the garbage — matches the "graceful
  # degradation" contract the runner asserts.
  if [[ -n "${_PCF_GH_PAYLOAD:-}" ]] && _hook_looks_malformed "$_PCF_GH_PAYLOAD"; then
    _hook_headers "$headers_out" "200"
    cat "$_PCF_GH_PAYLOAD"
    return 0
  fi

  # Empty-list probe (pr_list `[]` match): translate the runner's empty-GraphQL
  # envelope into an empty GitLab REST list so my leaf's `.[] | select(...)`
  # post-filter produces `[]` (the R5 empty-match convention). Only meaningful
  # for the `/merge_requests` endpoint — other endpoints don't have an
  # empty-list assertion.
  if [[ "$bare_path" == */merge_requests ]] && [[ -n "${_PCF_GH_PAYLOAD:-}" ]] \
     && _hook_looks_empty_pr_list "$_PCF_GH_PAYLOAD"; then
    _hook_headers "$headers_out" "200"
    printf '[]'
    return 0
  fi

  # Non-array bare object probe: the runner's `_run_list_inline_comments_assert`
  # writes `{}` and `{"message":"Not Found"}` and expects the leaf to reject.
  # Forward verbatim so `_gl_api`'s "not an array → single-page verbatim" branch
  # (lib-gitlab-transport.sh:480) returns the object on stdout and my leaf's
  # `type == "array"` gate rejects it. GraphQL-shape objects (github pr-view
  # fixture etc.) are EXEMPT from this branch — they take the normal
  # per-path dispatch below.
  if [[ -n "${_PCF_GH_PAYLOAD:-}" ]] && _hook_looks_bare_object "$_PCF_GH_PAYLOAD" \
     && ! _hook_looks_empty_pr_list "$_PCF_GH_PAYLOAD"; then
    _hook_headers "$headers_out" "200"
    cat "$_PCF_GH_PAYLOAD"
    return 0
  fi

  case "$bare_path" in
    */issues/42/closed_by)
      _hook_serve "$headers_out" "issues-42-closed-by.json" ;;
    */merge_requests/7/closes_issues)
      _hook_serve "$headers_out" "mr-7-closes.json" ;;
    */merge_requests/8/closes_issues)
      _hook_serve "$headers_out" "mr-8-closes.json" ;;
    */merge_requests/42/closes_issues)
      _hook_serve "$headers_out" "mr-42-closes.json" ;;
    */merge_requests/42/notes)
      _hook_serve "$headers_out" "mr-42-notes.json" ;;
    */merge_requests/42/approvals)
      _hook_serve "$headers_out" "mr-42-approvals.json" ;;
    */merge_requests/42/discussions)
      # Two chp verbs hit /discussions:
      #   - chp_list_inline_comments (via _run_list_inline_comments_assert)
      #   - chp_review_threads       (via _run_shape_assert)
      # `_run_list_inline_comments_assert` sets _PCF_GH_PAYLOAD=inline-comments-valid.json;
      # `_run_shape_assert(chp_review_threads)` sets _PCF_GH_PAYLOAD=review-threads-valid.json.
      case "$cue" in
        inline-comments-valid.json) _hook_serve "$headers_out" "mr-42-discussions-inline.json" ;;
        review-threads-valid.json)  _hook_serve "$headers_out" "mr-42-discussions-threads.json" ;;
        *)                          _hook_serve "$headers_out" "mr-42-discussions-threads.json" ;;
      esac ;;
    */merge_requests)
      # `?state=opened&order_by=created_at&sort=desc` — chp_pr_list.
      _hook_serve "$headers_out" "mr-list-opened.json" ;;
    */merge_requests/42)
      # chp_ci_status runs three times with distinct cues (all-success / mixed-
      # failure / empty), chp_mergeable runs with `mergeable-token.json`, and
      # chp_pr_view runs with `pr-view-valid.json`. Choose the fixture that,
      # after leaf normalization, produces the token / shape the runner asserts.
      case "$cue" in
        ci-status-all-success.json)  _hook_serve "$headers_out" "mr-ci-success.json" ;;
        ci-status-mixed-failure.json) _hook_serve "$headers_out" "mr-ci-failed.json" ;;
        ci-status-empty.json)        _hook_serve "$headers_out" "mr-ci-none.json" ;;
        ci-status-object-payload.json)
          # This runner assertion expects the leaf to reject a non-array/non-
          # object payload — serve a rc-200 JSON-array payload so the leaf's
          # `type == "object"` gate fires. `_gl_api` returns rc 0 with the
          # body; `chp_gitlab_ci_status`'s payload-type gate then rejects.
          _hook_headers "$headers_out" "200"
          printf '[]' ;;
        mergeable-token.json)        _hook_serve "$headers_out" "mr-mergeable.json" ;;
        pr-view-valid.json)          _hook_serve "$headers_out" "mr-pr-view.json" ;;
        *)                           _hook_serve "$headers_out" "mr-pr-view.json" ;;
      esac ;;
    *)
      # Unhandled path — return HTTP 404 (the transport's non-2xx branch fails
      # rc≠0, so a leaf that queries an unknown endpoint under this hook fails
      # cleanly instead of hanging or returning garbage).
      _hook_headers "$headers_out" "404"
      printf 'not found: %s\n' "$path" ;;
  esac
  return 0
}
