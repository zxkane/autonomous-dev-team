#!/bin/bash
# tests/provider-conformance/fixtures/gitlab-hook/gitlab-transport-hook.sh —
# fixture transport hook for the `--itp gitlab` / `--chp gitlab` conformance
# axis. Redefines `_gl_http` (the ONLY public override point per the #416 W-A
# frozen contract) with a payload-first, path-fallback dispatcher and full
# argv recording. Zero network I/O.
#
# ENV VARS the hook honors (all set by the runner's per-invocation _invoke):
#   _PCF_GL_PAYLOAD       — a file whose content is served verbatim as the
#                           200-OK response body. Overrides the per-path
#                           default fixture. Used by _run_gl_shape_assert /
#                           _run_gl_count_assert / _run_gl_object_shape_assert.
#   _PCF_GL_STATUS        — HTTP status code to return (default 200). When
#                           set to `500` (or any non-2xx), body is a stock
#                           "internal error" text and the transport's non-2xx
#                           branch triggers rc≠0 fail-CLOSED. Used by every
#                           _run_gl_*_assert helper's fail-path leg.
#   _PCF_GL_ARGV_FILE     — a file the hook APPENDS one line per invocation to
#                           in the exact shape:
#                             method=<M> path=<P> body=<B or ->
#                           `body` is `-` when no body was passed; otherwise
#                           the body-JSON string (single-line — the hook
#                           strips its own newlines). Used by
#                           _run_gl_write_assert for method/path/body needle
#                           checks.
#   _PCF_GH_MODE=fail     — legacy fail-CLOSED probe (pre-#419 P3-3 shape).
#                           Same effect as _PCF_GL_STATUS=500. Kept for
#                           back-compat.
#
# Per-verb env vars (READ verbs only, cued by fixture basename to disambiguate
# a shared MR-view path — see the `case "$cue"` block below):
#   _PCF_GH_PAYLOAD       — a github-side fixture path the runner sets per
#                           read-assertion. We READ its basename to pick the
#                           right gitlab-side sidecar (e.g. ci-status-* → the
#                           correct head_pipeline.status fixture).
#
# The hook is invoked ONLY under `run-provider-conformance.sh --itp gitlab`
# or `--chp gitlab` with `--transport-hook <this-file>`. The github/github
# axis never reaches it (lib-code-host.sh sources chp-github.sh, whose leaves
# call `gh` not `_gl_api`).
#
# Malformed-input probe: when `_PCF_GH_PAYLOAD` points at a file that isn't
# parseable JSON, we serve it verbatim as a 200 so the leaf's own JSON-shape
# gate fires and returns rc≠0 EMPTY stdout — matches the "graceful
# degradation" contract the runner asserts.

# Sibling fixture directory — resolve via BASH_SOURCE so a relative
# --transport-hook path works from any cwd.
_CHP_GL_HOOK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
_PAYLOADS_DIR="$(cd "$_CHP_GL_HOOK_DIR/../payloads" && pwd)"

# _hook_headers <headers_out_file> <status> [x-next-page]
# Emit a minimal headers response the transport lib can parse.
_hook_headers() {
  local out="$1" status="$2" next_page="${3:-}"
  {
    printf 'HTTP/1.1 %s OK\r\n' "$status"
    [[ -n "$next_page" ]] && printf 'x-next-page: %s\r\n' "$next_page"
    printf '\r\n'
  } > "$out"
}

# _hook_record <method> <path> [body-json] [body-file]
# Append one line to _PCF_GL_ARGV_FILE. `body` inline OR body_file path
# (5th positional to _gl_http, #419 P1-3). Both are recorded so the runner
# can assert (a) actual body content via `body=…` substring, AND (b) whether
# the body arrived via file — `body_file=<path>` present (never `-`) proves
# the payload did NOT hit curl argv.
_hook_record() {
  local method="$1" path="$2" body="${3:-}" body_file="${4:-}"
  [[ -n "${_PCF_GL_ARGV_FILE:-}" ]] || return 0
  local body_line body_file_line
  if [[ -n "$body_file" ]]; then
    # [#419 P1-3] --body-file channel: inline the file's content into the
    # recorded `body=` field (so the runner's substring needle matches on
    # actual JSON — e.g. `"branch":"screenshots"` — regardless of channel).
    # `body_file=<path>` presence proves file-mode was used.
    if [[ -f "$body_file" ]]; then
      body_line="$(tr -d '\n\r' < "$body_file")"
    else
      body_line="<missing-body-file>"
    fi
    body_file_line="$body_file"
  elif [[ -n "$body" ]]; then
    body_line="$(printf '%s' "$body" | tr -d '\n\r')"
    body_file_line="-"
  else
    body_line="-"
    body_file_line="-"
  fi
  # Strip the leading `/` from the path so recorded value matches the runner's
  # needle shape (`path=projects/…`, no leading slash — the runner's
  # _run_gl_write_assert needles are written that way).
  local rec_path="${path#/}"
  printf 'method=%s path=%s body=%s body_file=%s\n' \
    "$method" "$rec_path" "$body_line" "$body_file_line" \
    >> "$_PCF_GL_ARGV_FILE"
}

# _hook_serve <headers_out_file> <fixture_basename> [status]
# Serve a fixture body from gitlab-hook/ or payloads/ (checks hook-dir first,
# then payloads-dir).
_hook_serve() {
  local out="$1" fixture="$2" status="${3:-200}"
  _hook_headers "$out" "$status"
  if [[ -f "$_CHP_GL_HOOK_DIR/$fixture" ]]; then
    cat "$_CHP_GL_HOOK_DIR/$fixture"
  elif [[ -f "$_PAYLOADS_DIR/$fixture" ]]; then
    cat "$_PAYLOADS_DIR/$fixture"
  else
    # Unknown fixture — emit an empty body under the requested status. The
    # transport's non-2xx branch classifies this as fail; 2xx-with-empty
    # returns rc-0 EMPTY stdout (leaf's JSON-shape gate then rejects).
    printf ''
  fi
}

# _hook_fail_500 <headers_out_file>
_hook_fail_500() {
  local out="$1"
  _hook_headers "$out" "500"
  printf 'internal server error\n'
}

# _hook_looks_malformed <file>
# rc 0 iff FILE's content is not parseable JSON. Empty file counts as
# malformed (degenerate probe).
_hook_looks_malformed() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  [[ -s "$f" ]] || return 0
  ! jq -e . >/dev/null 2>&1 < "$f"
}

# _hook_looks_empty_pr_list <file>
_hook_looks_empty_pr_list() {
  local f="$1"
  [[ -f "$f" && -s "$f" ]] || return 1
  jq -e '
    (type == "array" and length == 0) or
    (type == "object" and .data.repository.pullRequests.nodes == [])
  ' >/dev/null 2>&1 < "$f"
}

# _hook_looks_bare_object <file>
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

# _gl_http <method> <path> <headers_out> [body-json] [body-file]
# Argv-recording, payload-first, path-fallback dispatcher. The 5th positional
# (body_file, #419 P1-3) is the P3-4-added body-file channel: when set,
# curl's `--data-binary @<path>` streams the file. We record it verbatim for
# the runner's body-file argv assertion.
_gl_http() {
  local method="$1" path="$2" headers_out="$3" body_json="${4:-}" body_file="${5:-}"

  # Strip query string for pattern matching; keep the full path for recording.
  local bare_path="${path%%\?*}"

  # ALWAYS record every invocation (the runner's write-assert reads argv
  # AFTER the invocation; a leaf that fails positional validation returns
  # rc 2 without calling _gl_http, and the argv file stays empty in that
  # case — which the runner reports as a leaf-not-calling-hook FAIL).
  _hook_record "$method" "$path" "$body_json" "$body_file"

  # Explicit status override: _PCF_GL_STATUS forces this response's status
  # regardless of route. Used by the _run_gl_*_assert helpers' fail-path leg.
  local override_status="${_PCF_GL_STATUS:-}"

  # Fail-CLOSED probe: legacy _PCF_GH_MODE=fail (pre-#419 shape) → HTTP 500.
  if [[ "${_PCF_GH_MODE:-ok}" == "fail" ]]; then
    _hook_fail_500 "$headers_out"
    return 0
  fi
  if [[ -n "$override_status" ]] && [[ "$override_status" -lt 200 || "$override_status" -ge 300 ]]; then
    _hook_headers "$headers_out" "$override_status"
    printf 'error: forced status %s\n' "$override_status"
    return 0
  fi

  # Payload override: _PCF_GL_PAYLOAD content served verbatim. Malformed
  # payloads pass through unchanged (leaf's own JSON gate rejects). Empty-list
  # / bare-object probes match specific runner assertion shapes.
  if [[ -n "${_PCF_GL_PAYLOAD:-}" && -f "${_PCF_GL_PAYLOAD}" ]]; then
    _hook_headers "$headers_out" "${override_status:-200}"
    cat "$_PCF_GL_PAYLOAD"
    return 0
  fi

  # Legacy _PCF_GH_PAYLOAD cue (used by the pre-existing READ-verb helpers
  # to disambiguate a shared MR-view path).
  local cue=""
  if [[ -n "${_PCF_GH_PAYLOAD:-}" ]]; then
    cue="$(basename "$_PCF_GH_PAYLOAD")"
    if _hook_looks_malformed "$_PCF_GH_PAYLOAD"; then
      _hook_headers "$headers_out" "200"
      cat "$_PCF_GH_PAYLOAD"
      return 0
    fi
    if [[ "$bare_path" == */merge_requests ]] && _hook_looks_empty_pr_list "$_PCF_GH_PAYLOAD"; then
      _hook_headers "$headers_out" "200"
      printf '[]'
      return 0
    fi
    if _hook_looks_bare_object "$_PCF_GH_PAYLOAD" \
       && ! _hook_looks_empty_pr_list "$_PCF_GH_PAYLOAD"; then
      _hook_headers "$headers_out" "200"
      cat "$_PCF_GH_PAYLOAD"
      return 0
    fi
  fi

  # -------- Path-driven dispatch (READ + WRITE endpoints) --------
  case "$method $bare_path" in
    # ===== ITP endpoints (GitLab Issues API) =====
    "GET "*/issues/42)
      _hook_serve "$headers_out" "gitlab-issue-view.json" ;;
    "GET "*/issues)
      _hook_serve "$headers_out" "gitlab-issues-list.json" ;;
    "GET "*/issues/*/notes*)
      _hook_serve "$headers_out" "gitlab-notes-list.json" ;;
    "GET "*/issues/*/resource_label_events*)
      # itp_label_event_ts fail-soft path — empty array is a valid "no
      # matching event" answer that the leaf collapses to empty stdout.
      _hook_headers "$headers_out" "200"
      printf '[]' ;;
    "POST "*/issues/*/notes)
      # itp_post_comment / itp_edit_comment (POST-side).
      _hook_headers "$headers_out" "201"
      printf '{"id":1001,"body":""}' ;;
    "PUT "*/issues/*/notes/*)
      # itp_edit_comment (PUT-side).
      _hook_headers "$headers_out" "200"
      printf '{"id":1001,"body":""}' ;;
    "PUT "*/issues/*)
      # itp_transition_state / itp_mark_checkbox → PUT /issues/:iid.
      _hook_headers "$headers_out" "200"
      printf '{"iid":42,"state":"opened"}' ;;
    "GET "*/labels/*)
      # itp_provision_states existence probe → 200 (skip create).
      _hook_headers "$headers_out" "200"
      printf '{"name":"autonomous","color":"#0E8A16"}' ;;
    "POST "*/labels)
      # itp_provision_states create.
      _hook_headers "$headers_out" "201"
      printf '{"name":"autonomous","color":"#0E8A16"}' ;;

    # ===== CHP endpoints (GitLab Merge Requests API) =====
    "GET "*/projects/group%2Fproject)
      # chp_gitlab_create_pr default-branch probe / chp_gitlab_commit_file
      # bootstrap. Also chp_gitlab_reply_review_comment's ambient GITLAB_PROJECT
      # decode goes through _chp_gitlab_project_raw (no HTTP).
      _hook_headers "$headers_out" "200"
      printf '{"default_branch":"main","path_with_namespace":"group/project"}' ;;
    "GET "*/issues/42/closed_by)
      _hook_serve "$headers_out" "issues-42-closed-by.json" ;;
    "GET "*/merge_requests/7/closes_issues)
      _hook_serve "$headers_out" "mr-7-closes.json" ;;
    "GET "*/merge_requests/8/closes_issues)
      _hook_serve "$headers_out" "mr-8-closes.json" ;;
    "GET "*/merge_requests/42/closes_issues)
      _hook_serve "$headers_out" "mr-42-closes.json" ;;
    "GET "*/merge_requests/42/notes)
      _hook_serve "$headers_out" "mr-42-notes.json" ;;
    "GET "*/merge_requests/42/approvals)
      _hook_serve "$headers_out" "mr-42-approvals.json" ;;
    "GET "*/merge_requests/42/discussions)
      case "$cue" in
        inline-comments-valid.json) _hook_serve "$headers_out" "mr-42-discussions-inline.json" ;;
        review-threads-valid.json)  _hook_serve "$headers_out" "mr-42-discussions-threads.json" ;;
        *)                          _hook_serve "$headers_out" "mr-42-discussions-threads.json" ;;
      esac ;;
    "GET "*/merge_requests)
      _hook_serve "$headers_out" "mr-list-opened.json" ;;
    "GET "*/merge_requests/42)
      case "$cue" in
        ci-status-all-success.json)   _hook_serve "$headers_out" "mr-ci-success.json" ;;
        ci-status-mixed-failure.json) _hook_serve "$headers_out" "mr-ci-failed.json" ;;
        ci-status-empty.json)         _hook_serve "$headers_out" "mr-ci-none.json" ;;
        ci-status-object-payload.json)
          _hook_headers "$headers_out" "200"
          printf '[]' ;;
        mergeable-token.json)         _hook_serve "$headers_out" "mr-mergeable.json" ;;
        pr-view-valid.json)           _hook_serve "$headers_out" "mr-pr-view.json" ;;
        *)                            _hook_serve "$headers_out" "mr-pr-view.json" ;;
      esac ;;

    # ===== CHP WRITE endpoints (P3-4, #419) =====
    "POST "*/merge_requests)
      # chp_gitlab_create_pr POST /merge_requests.
      _hook_serve "$headers_out" "gitlab-chp-write-create-pr-response.json" ;;
    "POST "*/merge_requests/*/approve)
      # chp_gitlab_approve — call 1 (load-bearing).
      _hook_serve "$headers_out" "gitlab-chp-write-approve-approve-ok.json" "201" ;;
    "PUT "*/merge_requests/*/merge)
      # chp_gitlab_merge PUT /merge.
      _hook_serve "$headers_out" "gitlab-chp-write-merge-response.json" ;;
    "POST "*/merge_requests/*/notes)
      # chp_gitlab_pr_comment / chp_gitlab_approve call 2 (note).
      _hook_serve "$headers_out" "gitlab-chp-write-pr-comment-response.json" "201" ;;
    "POST "*/merge_requests/*/discussions/*/notes)
      # chp_gitlab_reply_review_comment POST reply.
      _hook_serve "$headers_out" "gitlab-chp-write-reply-note-response.json" "201" ;;
    "PUT "*/merge_requests/*/discussions/*)
      # chp_gitlab_resolve_thread PUT /discussions/:id.
      _hook_serve "$headers_out" "gitlab-chp-write-resolve-thread-response.json" ;;

    # ===== chp_gitlab_commit_file endpoints =====
    "GET "*/repository/branches/*)
      # Branch existence preflight — 200 = branch exists (leaf skips bootstrap).
      _hook_serve "$headers_out" "gitlab-chp-write-commit-file-branch-exists.json" ;;
    "POST "*/repository/branches*)
      # Orphan branch create (only reached when branch preflight was 404, which
      # this hook never returns, but wire it up for defense-in-depth).
      _hook_serve "$headers_out" "gitlab-chp-write-commit-file-branch-create.json" "201" ;;
    "GET "*/repository/files/*)
      # File existence preflight — 200 = file exists (leaf takes PUT branch).
      _hook_serve "$headers_out" "gitlab-chp-write-commit-file-file-exists.json" ;;
    "POST "*/repository/files/*|"PUT "*/repository/files/*)
      # chp_gitlab_commit_file POST create or PUT update.
      _hook_serve "$headers_out" "gitlab-chp-write-commit-file-create-response.json" "201" ;;
    "GET "*/repository/commits*)
      # Post-commit SHA lookup.
      _hook_serve "$headers_out" "gitlab-chp-write-commit-file-commits.json" ;;

    # ===== Fallback =====
    *)
      # Unhandled — HTTP 404 so leaves fail cleanly instead of hanging.
      _hook_headers "$headers_out" "404"
      printf 'not found: %s %s\n' "$method" "$path" ;;
  esac
  return 0
}
