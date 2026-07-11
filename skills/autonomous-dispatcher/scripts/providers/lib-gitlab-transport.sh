#!/bin/bash
# lib-gitlab-transport.sh — GitLab transport contract (issue #416, phase-3 #414
# W-A). Two-layer FROZEN contract:
#
#   _gl_http <method> <path-or-url> <headers_out_file> [body-json] [body-file]
#       SINGLE-REQUEST primitive AND out-of-tree hook point. Default impl uses
#       curl only (no glab — a CLI carries its own auth/config state, blurring
#       the standard-auth-only boundary per #414 pillar 2). Sends
#       `PRIVATE-TOKEN: ${GITLAB_TOKEN}` against `https://${GITLAB_HOST}/api/v4/<path>`;
#       a <path> that begins with `http` is used VERBATIM (used by _gl_api's
#       pagination walker to pass an absolute next-page URL). Response body
#       -> stdout for ALL HTTP statuses (including 4xx/5xx — _gl_api needs
#       the body for tolerated statuses and error excerpts). HTTP status +
#       response headers (at minimum x-next-page, x-total-pages, retry-after)
#       -> <headers_out_file> in a stable line-oriented format. rc 0 iff
#       TRANSPORT succeeded (curl exit 0); HTTP status classification is
#       _gl_api's job. No retries here; no pagination here.
#
#       Body-file channel (P3-4 additive extension, #419 P1-3): when the 5th
#       positional is a non-empty file path, curl posts its content via
#       `--data-binary @<path>` — the body NEVER lands on curl argv, so
#       arbitrarily large payloads (base64 screenshots, multi-MB commits) do
#       not risk ARG_MAX. When BOTH body-json and body-file are set the FILE
#       wins (json is ignored; the leaf should pick one — the file path
#       already reflects the intended body). Backward-compatible: pre-P3-4
#       hooks that only read $1..$4 IGNORE the extra positional and continue
#       to serve zero-body responses correctly.
#
#   _gl_api [--method M] [--paginate] [--body JSON] [--body-file PATH]
#           [--tolerate-status CSV] [--max-items N] [--status-out FILE] <path>
#       The PUBLIC function every GitLab leaf calls. `--body-file` (P3-4
#       additive extension, #419 P1-3) threads a file path down to `_gl_http`
#       so large bodies stay off argv. Mutually exclusive with `--body` (last
#       one wins in the arg parser); the leaf whose body may exceed ARG_MAX
#       (chp_gitlab_commit_file, spec §5.1.2 R10) MUST use `--body-file`.
#       Owns pagination walk
#       (--paginate loops x-next-page until exhausted, merges pages into ONE
#       JSON array via `jq -s add`, page cap GL_TRANSPORT_PAGE_CAP default 50
#       -> cap-hit or ANY mid-walk failure = rc != 0 with NO partial output —
#       the §3.5/#401 fail-closed discipline verbatim); 429/Retry-After
#       bounded backoff (default 3 retries per request, cap 60s per sleep);
#       fail-loud error surfacing (HTTP status + response body excerpt).
#
#     Next-page reconstruction — GitLab's x-next-page is a page NUMBER (not
#     a URL); _gl_api reconstructs the next request by setting/replacing the
#     `page=<n>` query param on the ORIGINAL path (documented; _gl_http's
#     verbatim-absolute-URL affordance stays but is not the pagination
#     mechanism).
#
#     HTTP-status channel (load-bearing for leaf preflights; SUBSHELL-SAFE
#     by design):
#       - `_gl_api` sets GL_API_STATUS (final HTTP status) in the CALLING
#         shell on EVERY return, and
#       - `--tolerate-status 404,409` makes the named statuses return rc 0
#         with the body on stdout and GL_API_STATUS observable.
#
#     CONTRACT NOTE — command substitution loses shell variables. A leaf
#     that needs status discrimination MUST invoke `_gl_api ... > "$tmpfile"`
#     directly in the CURRENT shell (redirect, NOT `$( ... )` capture) so
#     the GL_API_STATUS assignment survives; `_gl_api` ADDITIONALLY mirrors
#     the status into a caller-suppliable `--status-out <file>` for
#     harnesses that must capture stdout.
#
#     Bounded reads: `--max-items N` stops the pagination walk once N
#     items are merged (so a LIMIT-bounded list verb cannot spuriously hit
#     the page cap on a large project).
#
#   _gl_urlencode <string>
#       jq `@uri` encoder. Leaves (dynamic project refs, label names, file
#       paths) share ONE encoder; the STATIC GITLAB_PROJECT config value is
#       stored ALREADY-URL-ENCODED per §3.4 (`group%2Fsubgroup%2Fproject`)
#       and used verbatim. LEAVES NEVER call curl or _gl_http directly —
#       the [INV-91] cutover guard enforces this.
#
#   _gl_graphql <query> [variables-json] (#452, first GitLab GraphQL call
#       site): dispatcher + default impl for a single-shot POST to
#       `https://${GITLAB_HOST}/api/graphql`. Default auth is
#       `Authorization: Bearer ${GITLAB_TOKEN}` (GraphQL does NOT accept the
#       REST PRIVATE-TOKEN header `_gl_http` sends — a SEPARATE primitive, not
#       a `_gl_http`/`_gl_api` call). NO pagination, NO 429 retry (unlike
#       `_gl_api`) — the sole caller is a single object-shaped read behind a
#       fail-open soft signal. Fail-CLOSED on token-unset / transport failure
#       / non-2xx / empty body / a populated `errors` array / null `data`; on
#       success echoes the inner `.data` object.
#
#       **OPTIONAL second hook point, `_gl_graphql_hook`** (#452 amendment,
#       [INV-124]): before running its default Bearer-token impl,
#       `_gl_graphql` ensures the transport preflight has run (sourcing
#       `GITLAB_TRANSPORT_HOOK` if armed — idempotent/latched, safe to call
#       from here regardless of whether `_gl_api` has already run in this
#       process) and then checks whether the hook defined a function named
#       `_gl_graphql_hook <query> <variables-json>`. If so, `_gl_graphql`
#       delegates to it and returns its rc/stdout verbatim — letting a
#       hook-only / token-less GitLab installation (`GITLAB_TRANSPORT_HOOK`
#       armed, no `GITLAB_TOKEN`) answer the `lines` dimension through its
#       own auth path instead of always degrading it to unreadable. This is
#       an ADDITIVE, OPTIONAL point, distinct from the mandatory `_gl_http`
#       override — a hook that defines `_gl_http` only (the pre-#452
#       contract) keeps working unchanged, and `_gl_graphql` simply falls
#       through to its default Bearer-token impl (still requires
#       `GITLAB_TOKEN` in that case; the `lines` dimension degrades to
#       unreadable exactly as before #452's amendment when the hook does not
#       opt in AND no token is configured).
#
# Override hooks (GITLAB_TRANSPORT_HOOK):
#   If GITLAB_TRANSPORT_HOOK (conf-declared path) is set, the transport lib
#   sources it at library-init BEFORE any leaf runs (and, defensively, again
#   on first `_gl_graphql` call if that happens to run before any `_gl_api`
#   call — the source is idempotent/latched either way). The hook MUST
#   redefine `_gl_http` (same signature/contract) — `_gl_api` stays lib-owned
#   so pagination + backoff + fail-closed cannot be lost by a variant. The
#   hook MAY ADDITIONALLY define `_gl_graphql_hook <query> <variables-json>`
#   (optional, #452 amendment) to answer the GraphQL endpoint through the
#   same custom auth/transport; if it does not, `_gl_graphql`'s default
#   Bearer-token impl stays in force.
#
#   Trust model: operator-owned local code, same privileges as
#   autonomous.conf — explicitly NOT a sandbox (#414 pillar 3). The hook MAY
#   define private helper functions (that is operator-owned code); only the
#   PUBLIC override points (`_gl_http` mandatory, `_gl_graphql_hook`
#   optional) are validated/dispatched by name.
#
# Preflight fail-loud (latched once per process — mirrors _AGENT_TOKEN_PAT_WARNED
# at lib-auth.sh:93):
#   - GITLAB_TOKEN unset when no hook is armed -> rc != 0 with recovery guidance;
#   - GITLAB_TRANSPORT_HOOK set but path unreadable -> rc != 0 naming the path;
#   - after sourcing the hook, `_gl_http` must exist and be callable or
#     preflight fails rc != 0. (`_gl_graphql_hook` is NOT preflight-validated
#     — its absence is a valid, expected state, unlike `_gl_http` which the
#     hook MUST cover; `_gl_graphql` probes for it lazily at call time.)
#
# GITLAB_HOST default: `gitlab.com`. Overridable per-project.
#
# See docs/pipeline/provider-spec.md §transport and INV-116.

# Guard against double-sourcing (idempotent — only defines functions +
# module-scope state).
if [[ "${_LIB_GITLAB_TRANSPORT_SOURCED:-0}" -eq 1 ]]; then
  return 0 2>/dev/null || exit 0
fi
_LIB_GITLAB_TRANSPORT_SOURCED=1

# Module-level state. GITLAB_HOST defaults to `gitlab.com` (self-hosted
# instances override via autonomous.conf).
: "${GITLAB_HOST:=gitlab.com}"
: "${GL_TRANSPORT_PAGE_CAP:=50}"
: "${GL_TRANSPORT_MAX_RETRIES:=3}"
: "${GL_TRANSPORT_RETRY_CAP_SECONDS:=60}"

# One-time preflight-passed latch. Preflight runs on FIRST `_gl_api` call
# per process; subsequent calls skip revalidation for cost.
_GL_PREFLIGHT_LATCHED=""

# Publicly exposed status channel — set by _gl_api on EVERY return so a leaf
# doing `_gl_api ... > $tmp` can `[[ $GL_API_STATUS == 404 ]]` afterward.
# Reset per call (never stale from a prior call — the caller reads it
# UNCONDITIONALLY, so leaking a prior status would be a real bug).
GL_API_STATUS=""

# _gl_preflight_check — validate GITLAB_TOKEN / GITLAB_TRANSPORT_HOOK once
# per process. Returns 0 on pass (latched), non-zero + stderr diagnostic on
# fail. Called by _gl_api on every invocation; short-circuits after the
# first pass.
_gl_preflight_check() {
  [[ -n "$_GL_PREFLIGHT_LATCHED" ]] && return 0

  local hook="${GITLAB_TRANSPORT_HOOK:-}"

  if [[ -n "$hook" ]]; then
    if [[ ! -r "$hook" ]]; then
      echo "ERROR: [INV-116] GITLAB_TRANSPORT_HOOK='${hook}' is not readable — cannot source the transport override. Set GITLAB_TRANSPORT_HOOK to a readable file that redefines _gl_http, or unset it to use the default curl transport." >&2
      return 1
    fi
    # [#416 P1-4] Snapshot _gl_http's BODY BEFORE sourcing the hook, so we
    # can prove the hook actually overrode it after. `declare -F _gl_http`
    # alone only checks EXISTENCE — but the default is already defined at
    # this point, so a no-op hook (empty file, syntax error suppressed by
    # a rogue `|| true`, or a file that just re-exports env vars) would
    # pass a mere existence check and masquerade as the default transport.
    # Codex round-1 [P1-4]: capture body pre-source, require CHANGE post.
    local _pre_body _post_body
    _pre_body=$(declare -f _gl_http 2>/dev/null || true)
    # Source in the current shell so a redefined _gl_http survives.
    # shellcheck disable=SC1090
    source "$hook" || {
      echo "ERROR: [INV-116] sourcing GITLAB_TRANSPORT_HOOK='${hook}' failed (non-zero rc from the hook file itself)." >&2
      return 1
    }
    # Post-source: _gl_http must exist and be callable. The hook MAY define
    # private helper functions alongside (operator-trust model, per #414
    # pillar 3); only the public override point is validated.
    if ! declare -F _gl_http >/dev/null 2>&1; then
      echo "ERROR: [INV-116] GITLAB_TRANSPORT_HOOK='${hook}' did not define _gl_http (the only public override point). Redefine _gl_http with signature: _gl_http <method> <path-or-url> <headers_out_file> [body-json]." >&2
      return 1
    fi
    _post_body=$(declare -f _gl_http 2>/dev/null || true)
    # [#416 P1-4] Loud rejection of a no-op hook: if the body did not
    # change post-source, the hook is armed but does nothing — either a
    # typo, a suppressed error, or an operator misconfiguration. Fail
    # LOUD naming the hook path so the operator can fix it rather than
    # silently running against the default transport under a hook-armed
    # config that says "we're on the enterprise gateway".
    if [[ "$_pre_body" == "$_post_body" ]]; then
      echo "ERROR: [INV-116] GITLAB_TRANSPORT_HOOK='${hook}' is armed but did NOT redefine _gl_http (body identical pre- and post-source). A no-op hook is a misconfiguration — either the hook file has a syntax error suppressed by a stray '|| true', or it never assigns the function. Redefine _gl_http in the hook, or unset GITLAB_TRANSPORT_HOOK to use the default curl transport." >&2
      return 1
    fi
  else
    # No hook: default curl transport is in force. GITLAB_TOKEN is required.
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
      echo "ERROR: [INV-116] GITLAB_TOKEN is unset and no GITLAB_TRANSPORT_HOOK is armed — the default curl transport requires a PAT. Set GITLAB_TOKEN=<token> (see docs/gitlab-token-setup.md), or set GITLAB_TRANSPORT_HOOK=<path> to a custom transport." >&2
      return 1
    fi
  fi

  _GL_PREFLIGHT_LATCHED=1
  echo "[INV-116] gitlab-transport preflight OK (hook=${hook:-<none>}, host=${GITLAB_HOST})" >&2
  return 0
}

# _gl_urlencode <string> — jq @uri encoder. Used by leaves for dynamic path
# segments (label names, dynamic project refs, file paths). The STATIC
# GITLAB_PROJECT config value is stored ALREADY-URL-ENCODED per §3.4 and
# used verbatim (never re-encoded here).
_gl_urlencode() {
  jq -rn --arg s "$1" '$s | @uri'
}

# _gl_http <method> <path-or-url> <headers_out_file> [body-json]
#   Default (curl-only) implementation. Overridable via GITLAB_TRANSPORT_HOOK.
#   See the header comment for the full contract.
#
#   rc 0 iff curl transport succeeded (request sent + response received —
#   curl exit 0). HTTP status classification is EXCLUSIVELY _gl_api's job.
_gl_http() {
  local method="$1" path_or_url="$2" headers_out_file="$3" body_json="${4:-}" body_file="${5:-}"
  local url

  if [[ "$path_or_url" == http* ]]; then
    url="$path_or_url"
  else
    # Trim any leading slash so we don't produce double-slash after /api/v4/.
    url="https://${GITLAB_HOST}/api/v4/${path_or_url#/}"
  fi

  # curl argv:
  #   -sS       — silent + show errors (we handle rc; body is on stdout).
  #   -X <M>    — HTTP method.
  #   -H ...    — PRIVATE-TOKEN auth header (GitLab convention).
  #   -D <f>    — dump response headers (incl. HTTP status line) to file.
  #   --data-binary <body>       — body-json inline (for small payloads).
  #   --data-binary @<path>      — body-file (P3-4 additive, #419 P1-3):
  #     curl streams the file content off the argv, so ARG_MAX cannot be hit
  #     regardless of body size. When BOTH body-json and body-file are set,
  #     the FILE wins (documented in the lib header).
  #
  # We MUST NOT pass `-f/--fail` — that would make curl exit non-zero on
  # HTTP >=400 and suppress the body, but the contract requires:
  #   (a) rc 0 iff TRANSPORT succeeded (independent of HTTP status);
  #   (b) body on stdout for ALL statuses (so _gl_api can tolerate 404/409
  #       and surface error excerpts on 5xx).
  local -a curl_argv=(
    curl -sS
    -X "$method"
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}"
    -D "$headers_out_file"
  )

  if [[ -n "$body_file" ]]; then
    curl_argv+=(
      -H "Content-Type: application/json"
      --data-binary "@${body_file}"
    )
  elif [[ -n "$body_json" ]]; then
    curl_argv+=(
      -H "Content-Type: application/json"
      --data-binary "$body_json"
    )
  fi

  curl_argv+=("$url")

  "${curl_argv[@]}"
}

# _gl_api_extract_status <headers_out_file>
#   Extract the HTTP status code (integer) from the LAST response-line block
#   in a curl `-D` headers file. Curl may write multiple status blocks for a
#   redirect chain, so we take the LAST `HTTP/...` line. Empty file / no
#   status line -> empty output (caller treats as transport failure).
_gl_api_extract_status() {
  local headers_file="$1"
  [[ -s "$headers_file" ]] || return 0
  awk '
    /^HTTP\// { status = $2 }
    END { if (status != "") print status }
  ' "$headers_file"
}

# _gl_api_extract_header <headers_out_file> <header_name>
#   Extract the LAST (post-redirect) value of a named header from a curl
#   `-D` headers file. Case-insensitive header name match; leading/trailing
#   whitespace trimmed from the value.
_gl_api_extract_header() {
  local headers_file="$1" name="$2"
  [[ -s "$headers_file" ]] || return 0
  # Lowercase for match; the header field name is case-insensitive per RFC.
  local lname; lname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  awk -v name="$lname" '
    tolower($1) == name":" {
      # Drop the field-name (first whitespace-run), then trim.
      sub(/^[^ \t]*[ \t]+/, "", $0)
      sub(/[ \t\r\n]+$/, "", $0)
      value = $0
    }
    END { if (value != "") print value }
  ' "$headers_file"
}

# _gl_graphql <query> [variables-json] — GitLab GraphQL endpoint primitive
# (#452, the first GitLab leaf that needs GraphQL; `chp-gitlab.sh` had none
# before this — REST-only via `_gl_api`).
#
# GitLab's GraphQL endpoint (`https://${GITLAB_HOST}/api/graphql`) does NOT
# accept the REST `PRIVATE-TOKEN` header `_gl_http` sends — it authenticates
# via `Authorization: Bearer <token>` (or a `private_token=`/`access_token=`
# query param; GitLab's docs list no PRIVATE-TOKEN-header form for GraphQL).
# So the default impl below is a SEPARATE minimal primitive, not a call
# through `_gl_http`/`_gl_api` (whose frozen #416 contract is REST-path +
# PRIVATE-TOKEN shaped).
#
# <query> is a GraphQL query STRING; <variables-json> is an optional JSON
# object of GraphQL variables (defaults to `{}`). Single-shot, NO pagination,
# NO 429 retry/backoff (unlike `_gl_api`) — the sole caller
# (`chp_gitlab_pr_diffstat`'s `diffStatsSummary` lookup) is a single
# object-shaped read behind a fail-open soft-signal feature (#452
# PR-diff-soft-cap), so a hard one-shot failure is an acceptable, honestly
# fail-CLOSED outcome rather than added retry complexity.
#
# Fail-CLOSED: rc≠0 with NO stdout on: GITLAB_TOKEN unset (and no
# `_gl_graphql_hook` override — see below), transport failure, non-2xx HTTP
# status, empty response body, a populated GraphQL `errors` array, or a
# null/absent top-level `data`. On success echoes the INNER `.data` object
# (NOT the `{data: ...}` envelope) so callers project straight into it. This
# guarantee is UNIFORM across both the default impl and the optional
# `_gl_graphql_hook` override below — the hook's raw stdout is validated
# (non-null JSON object) before being returned, and a nonzero hook rc never
# lets partial hook stdout leak to the caller.
_gl_graphql() {
  local query="$1" variables="${2:-}"
  [[ -n "$variables" ]] || variables='{}'

  # Ensure GITLAB_TRANSPORT_HOOK (if armed) has been sourced before probing
  # for the optional `_gl_graphql_hook` override — `_gl_preflight_check` is
  # idempotent/latched, so this is a no-op if `_gl_api` already ran in this
  # process, and safe to call here even if this is the very first transport
  # call the process makes.
  _gl_preflight_check || return 1

  # Optional second hook point (#452 amendment, [INV-124]): a
  # GITLAB_TRANSPORT_HOOK that defines `_gl_graphql_hook <query>
  # <variables-json>` answers the GraphQL endpoint through its own
  # auth/transport (e.g. a hook-only / token-less GitLab installation that
  # cannot use the default Bearer-token impl below). Absence is a valid,
  # expected state — the pre-#452 hook contract (redefine `_gl_http` only)
  # keeps working unchanged and simply falls through to the default impl.
  # The hook's stdout is CAPTURED (not streamed straight to the caller) so a
  # nonzero rc can never leak partial output, and its shape is validated
  # (non-null JSON object — the same currency `_gl_graphql` itself returns
  # on success) before being handed back; a hook that returns rc 0 with
  # garbage/null output fails closed here rather than propagating malformed
  # data to the caller (round-2 review finding).
  if declare -F _gl_graphql_hook >/dev/null 2>&1; then
    local hook_out hook_rc
    hook_out="$(_gl_graphql_hook "$query" "$variables")"
    hook_rc=$?
    [[ $hook_rc -eq 0 ]] || return "$hook_rc"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$hook_out" || return 1
    printf '%s' "$hook_out"
    return 0
  fi

  if [[ -z "${GITLAB_TOKEN:-}" ]]; then
    echo "ERROR: [INV-116] GITLAB_TOKEN is unset — the GitLab GraphQL endpoint requires a Bearer-capable personal/project access token (it does not accept the REST PRIVATE-TOKEN header _gl_http uses), and GITLAB_TRANSPORT_HOOK (if armed) did not define _gl_graphql_hook to cover it. Set GITLAB_TOKEN=<token>, or define _gl_graphql_hook in the hook (see docs/gitlab-token-setup.md)." >&2
    return 1
  fi
  local body
  body=$(jq -cn --arg q "$query" --argjson vars "$variables" '{query: $q, variables: $vars}' 2>/dev/null) || return 1
  local hdr_file resp_file
  hdr_file=$(mktemp)
  resp_file=$(mktemp)
  # Self-disarming function-scoped RETURN trap (the #330/[INV-99] discipline —
  # cleans these temps at THIS invocation's return, then clears itself so it
  # does not persist into a caller's own later return).
  trap 'rm -f "$hdr_file" "$resp_file"; trap - RETURN' RETURN
  curl -sS -X POST \
    -H "Authorization: Bearer ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -D "$hdr_file" \
    --data-binary "$body" \
    "https://${GITLAB_HOST}/api/graphql" > "$resp_file" 2>/dev/null || return 1
  local status
  status=$(_gl_api_extract_status "$hdr_file")
  [[ -n "$status" ]] && [[ "$status" -ge 200 && "$status" -lt 300 ]] || return 1
  [[ -s "$resp_file" ]] || return 1
  jq -e 'type == "object" and ((.errors // []) | length) == 0 and (.data != null)' >/dev/null 2>&1 < "$resp_file" || return 1
  jq -c '.data' < "$resp_file"
}

# _gl_api_reconstruct_next_url <path-or-url> <next-page-number>
#   Rebuild the request path with `page=<n>` set/replaced. Handles all
#   three input shapes:
#     - a bare path (`projects/42/issues`) -> `projects/42/issues?page=<n>`
#     - a path with query-string but no page (`...?per_page=100`) ->
#       `...?per_page=100&page=<n>`
#     - a path with query-string that already has page= -> replaced
#   Absolute URLs are handled identically (query-string logic doesn't care
#   about the scheme prefix).
_gl_api_reconstruct_next_url() {
  local original="$1" page_num="$2" base rest
  if [[ "$original" == *"?"* ]]; then
    base="${original%%\?*}"
    rest="${original#*\?}"
    # Strip any existing page= param (idempotent replace).
    rest=$(printf '%s' "$rest" | sed -E 's/(^|&)page=[^&]*(&|$)/\1\2/; s/&$//; s/^&//')
    if [[ -n "$rest" ]]; then
      printf '%s?%s&page=%s\n' "$base" "$rest" "$page_num"
    else
      printf '%s?page=%s\n' "$base" "$page_num"
    fi
  else
    printf '%s?page=%s\n' "$original" "$page_num"
  fi
}

# _gl_api — the PUBLIC function every GitLab leaf calls.
#
# Owns pagination walk, 429/Retry-After bounded backoff, HTTP-status channel,
# --tolerate-status, --max-items. Falls-closed on any transport / cap-hit /
# mid-walk failure. See header for full contract.
_gl_api() {
  local method="GET"
  local paginate=0
  local body_json=""
  local body_file=""
  local tolerate_status_csv=""
  local max_items=""
  local status_out_file=""
  local path=""

  while (( $# > 0 )); do
    case "$1" in
      --method)          method="$2"; shift 2 ;;
      --method=*)        method="${1#*=}"; shift ;;
      --paginate)        paginate=1; shift ;;
      --body)            body_json="$2"; shift 2 ;;
      --body=*)          body_json="${1#*=}"; shift ;;
      --body-file)       body_file="$2"; shift 2 ;;
      --body-file=*)     body_file="${1#*=}"; shift ;;
      --tolerate-status) tolerate_status_csv="$2"; shift 2 ;;
      --tolerate-status=*) tolerate_status_csv="${1#*=}"; shift ;;
      --max-items)       max_items="$2"; shift 2 ;;
      --max-items=*)     max_items="${1#*=}"; shift ;;
      --status-out)      status_out_file="$2"; shift 2 ;;
      --status-out=*)    status_out_file="${1#*=}"; shift ;;
      --)                shift; path="$1"; break ;;
      -*)                echo "ERROR: _gl_api: unknown flag '$1'" >&2; return 2 ;;
      *)                 path="$1"; shift; break ;;
    esac
  done

  # [#419 P1-3] Body-file channel — mutually exclusive with --body (file
  # wins). Validate the file exists BEFORE any HTTP dispatch so a caller
  # typo fails loud rather than curl streaming an empty file (which some
  # curl versions treat as an empty body silently).
  if [[ -n "$body_file" ]]; then
    if [[ ! -f "$body_file" ]]; then
      echo "ERROR: _gl_api: --body-file '$body_file' not found or not a regular file" >&2
      return 2
    fi
  fi

  if [[ -z "$path" ]]; then
    echo "ERROR: _gl_api: missing <path> argument" >&2
    return 2
  fi

  # Preflight — validates GITLAB_TOKEN / GITLAB_TRANSPORT_HOOK once per
  # process. rc != 0 leaves GL_API_STATUS empty.
  GL_API_STATUS=""
  [[ -n "$status_out_file" ]] && : > "$status_out_file"
  _gl_preflight_check || return 1

  # Parse tolerate list once (comma-separated integers).
  local -a tolerate=()
  if [[ -n "$tolerate_status_csv" ]]; then
    local IFS=','
    read -ra tolerate <<< "$tolerate_status_csv"
  fi

  # [#419 P1-3] Response-body scratch file is named `resp_body_file` to
  # disambiguate from the user's `--body-file` request-body input (both were
  # `body_file` pre-P1-3; the rename is mechanical).
  local hdr_file resp_body_file
  hdr_file=$(mktemp)
  resp_body_file=$(mktemp)
  local rc=0

  # _cleanup — remove per-call scratch files. Idempotent.
  _cleanup() { rm -f "$hdr_file" "$resp_body_file" 2>/dev/null || true; }

  # _record_status — echo the extracted status into GL_API_STATUS and the
  # --status-out file (if any). Called after every _gl_http invocation.
  _record_status() {
    GL_API_STATUS=$(_gl_api_extract_status "$hdr_file")
    if [[ -n "$status_out_file" ]]; then
      printf '%s' "${GL_API_STATUS:-}" > "$status_out_file"
    fi
  }

  # _is_toleratable — rc 0 iff GL_API_STATUS is in the tolerate list.
  _is_toleratable() {
    local s
    for s in "${tolerate[@]}"; do
      [[ "$s" == "$GL_API_STATUS" ]] && return 0
    done
    return 1
  }

  # _do_request_with_backoff <path> — call _gl_http; if the response is a
  # 429, honor Retry-After (capped at GL_TRANSPORT_RETRY_CAP_SECONDS) and
  # retry up to GL_TRANSPORT_MAX_RETRIES times. Returns:
  #   rc 0 — transport succeeded AND (final status not-429 OR retries
  #          exhausted with 429 still). Body on stdout (in `body_file`),
  #          status in GL_API_STATUS.
  #   rc 1 — transport failure (curl rc != 0).
  #   rc 2 — 429 exhausted (retries used, still 429).
  _do_request_with_backoff() {
    local target="$1"
    local attempt=0 http_rc
    while :; do
      : > "$hdr_file"
      # [#416 P1-3] `set -e`-SAFE _gl_http call: a bare
      #   `_gl_http … > "$body_file"; http_rc=$?`
      # would abort the CALLING shell under `set -euo pipefail` on a
      # transport failure BEFORE http_rc/`_record_status`/`--status-out`
      # mirroring ran. The `cmd || rc=$?` construct classifies the call
      # as tested (bash's `set -e` skips exit on tested commands) AND
      # preserves the ACTUAL non-zero rc (`if ! cmd; then rc=$?` is a
      # trap — `!` inverts, so `$?` under `then` is 0, not cmd's rc).
      # Codex round-1 [P1-3].
      http_rc=0
      _gl_http "$method" "$target" "$hdr_file" "$body_json" "$body_file" > "$resp_body_file" || http_rc=$?
      if [[ "$http_rc" -ne 0 ]]; then
        return 1
      fi
      _record_status
      if [[ "$GL_API_STATUS" != "429" ]]; then
        return 0
      fi
      # 429 — bounded retry loop.
      if [[ "$attempt" -ge "$GL_TRANSPORT_MAX_RETRIES" ]]; then
        return 2
      fi
      local retry_after
      retry_after=$(_gl_api_extract_header "$hdr_file" "Retry-After")
      # Retry-After can be seconds (integer) or a HTTP-date; default to 1s
      # on unparseable input.
      if ! [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        retry_after=1
      fi
      # Cap per-sleep at GL_TRANSPORT_RETRY_CAP_SECONDS.
      if [[ "$retry_after" -gt "$GL_TRANSPORT_RETRY_CAP_SECONDS" ]]; then
        retry_after="$GL_TRANSPORT_RETRY_CAP_SECONDS"
      fi
      sleep "$retry_after"
      attempt=$((attempt + 1))
    done
  }

  # Non-paginate path: one request, honor tolerate-status.
  if [[ "$paginate" -eq 0 ]]; then
    # [#416 P1-3] `set -e`-SAFE: `cmd || rc=$?` (see above rationale — the
    # `if !` pattern DROPS the actual rc because `!` inverts to 0, so
    # under `then` `$?` is always 0).
    rc=0
    _do_request_with_backoff "$path" || rc=$?
    if [[ "$rc" -eq 1 ]]; then
      echo "ERROR: [INV-116] _gl_api transport failure on '${path}' (curl exit non-zero)." >&2
      _cleanup; return 1
    fi
    if [[ "$rc" -eq 2 ]]; then
      echo "ERROR: [INV-116] _gl_api 429 backoff exhausted on '${path}' after ${GL_TRANSPORT_MAX_RETRIES} retries." >&2
      _cleanup; return 1
    fi
    # HTTP status classification.
    if [[ "$GL_API_STATUS" -ge 200 && "$GL_API_STATUS" -lt 300 ]]; then
      cat "$resp_body_file"
      _cleanup; return 0
    fi
    if _is_toleratable; then
      cat "$resp_body_file"
      _cleanup; return 0
    fi
    local body_excerpt; body_excerpt=$(head -c 200 "$resp_body_file" 2>/dev/null)
    echo "ERROR: [INV-116] _gl_api HTTP ${GL_API_STATUS} on '${path}' (body excerpt: ${body_excerpt})" >&2
    _cleanup; return 1
  fi

  # Paginate path: loop x-next-page until exhausted / cap-hit / mid-walk fail.
  # Merge pages via `jq -s add`. Fail-CLOSED: any error yields rc != 0 with
  # NO partial output.
  local merged_file; merged_file=$(mktemp)
  local pages_read=0
  local total_items=0
  local next_url="$path"
  local page_num=1
  local walk_rc=0

  while :; do
    # [#416 P1-3] `set -e`-SAFE (paginate loop) — same fix as above.
    local req_rc=0
    _do_request_with_backoff "$next_url" || req_rc=$?
    if [[ "$req_rc" -ne 0 ]]; then
      if [[ "$req_rc" -eq 1 ]]; then
        echo "ERROR: [INV-116] _gl_api transport failure mid-walk on '${next_url}'." >&2
      else
        echo "ERROR: [INV-116] _gl_api 429 backoff exhausted mid-walk on '${next_url}'." >&2
      fi
      walk_rc=1
      break
    fi
    if [[ "$GL_API_STATUS" -lt 200 || "$GL_API_STATUS" -ge 300 ]]; then
      if _is_toleratable && [[ "$pages_read" -eq 0 ]]; then
        # Tolerated status on the first page — return the body as-is (no
        # pagination merge; pagination on a tolerated non-2xx makes no sense).
        cat "$resp_body_file"
        rm -f "$merged_file"
        _cleanup; return 0
      fi
      local body_excerpt; body_excerpt=$(head -c 200 "$resp_body_file" 2>/dev/null)
      echo "ERROR: [INV-116] _gl_api mid-walk HTTP ${GL_API_STATUS} on '${next_url}' (body excerpt: ${body_excerpt})" >&2
      walk_rc=1
      break
    fi

    # Append this page to merged output. If the body is not a valid JSON
    # array, treat the first-page as a single-page response (return
    # verbatim) — pagination on a non-array body is a no-op degradation.
    if [[ "$pages_read" -eq 0 ]]; then
      if ! jq -e 'type == "array"' >/dev/null 2>&1 < "$resp_body_file"; then
        cat "$resp_body_file"
        rm -f "$merged_file"
        _cleanup; return 0
      fi
    fi
    cat "$resp_body_file" >> "$merged_file.raw"
    pages_read=$((pages_read + 1))

    if [[ -n "$max_items" ]]; then
      local page_len; page_len=$(jq 'length' < "$resp_body_file" 2>/dev/null || echo 0)
      total_items=$((total_items + page_len))
      if [[ "$total_items" -ge "$max_items" ]]; then
        break
      fi
    fi

    local next_page; next_page=$(_gl_api_extract_header "$hdr_file" "x-next-page")
    if [[ -z "$next_page" || "$next_page" == "0" ]]; then
      break
    fi
    if [[ "$pages_read" -ge "$GL_TRANSPORT_PAGE_CAP" ]]; then
      echo "ERROR: [INV-116] _gl_api paginate walk hit cap GL_TRANSPORT_PAGE_CAP=${GL_TRANSPORT_PAGE_CAP} (next-page=${next_page}) — fail-CLOSED, no partial output." >&2
      walk_rc=1
      break
    fi
    page_num="$next_page"
    next_url=$(_gl_api_reconstruct_next_url "$path" "$page_num")
  done

  if [[ "$walk_rc" -ne 0 ]]; then
    rm -f "$merged_file" "$merged_file.raw"
    _cleanup; return 1
  fi

  # Merge: jq -s add over the concatenated raw pages. Each page is one
  # complete JSON array; -s slurps them into a jq stream, then `add`
  # concatenates the arrays.
  if [[ -s "$merged_file.raw" ]]; then
    if [[ -n "$max_items" ]]; then
      # Slice to the requested max after merge.
      jq -s "add | .[:${max_items}]" < "$merged_file.raw" > "$merged_file" 2>/dev/null || walk_rc=1
    else
      jq -s 'add' < "$merged_file.raw" > "$merged_file" 2>/dev/null || walk_rc=1
    fi
  else
    printf '[]' > "$merged_file"
  fi

  if [[ "$walk_rc" -ne 0 ]]; then
    echo "ERROR: [INV-116] _gl_api paginate merge failed (invalid JSON in a page body)." >&2
    rm -f "$merged_file" "$merged_file.raw"
    _cleanup; return 1
  fi

  cat "$merged_file"
  rm -f "$merged_file" "$merged_file.raw"
  _cleanup; return 0
}
