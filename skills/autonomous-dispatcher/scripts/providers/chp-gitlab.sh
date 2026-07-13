#!/bin/bash
# providers/chp-gitlab.sh — GitLab Code-Host Provider (CHP) READ leaves (#418, P3-3).
#
# Third slice of phase-3 (#414). Implements the SEVEN CHP READ verbs behind
# lib-code-host.sh's `chp_<verb>` shim when CODE_HOST=gitlab. Every leaf is a
# function named `chp_gitlab_<verb>` mirroring the `chp_github_<verb>`
# convention (#280). No `_gl_http` reference anywhere — leaves route HTTP
# exclusively through the PUBLIC `_gl_api` function (#416 W-A frozen contract).
# The wrapper never sees `curl` or `glab` — that is the "single choke-point"
# discipline (#414 pillar 2) enforced by check-provider-cutover.sh's [INV-91]
# extension.
#
# PRECONDITION: sourced by lib-code-host.sh from the REAL skill tree. Config
# is `GITLAB_HOST` / `GITLAB_TOKEN` / `GITLAB_PROJECT` (§3.4). `GITLAB_PROJECT`
# is stored ALREADY URL-encoded per §3.4 (`group%2Fsubgroup%2Fproject`) and
# used verbatim in every path.
#
# TRANSPORT CONTRACT (frozen in #416 W-A, restated for local reference):
#   `_gl_api [--method M] [--paginate] [--body JSON] [--tolerate-status CSV] \
#            [--status-out FILE] [--max-items N] <path>` — the PUBLIC function.
#   Owns pagination (`--paginate` walks `x-next-page` internally, merging into
#   ONE JSON array via `jq -s add`), 429 backoff, fail-CLOSED (rc≠0 with NO
#   partial output on cap-hit or mid-walk failure), and populates `GL_API_STATUS`
#   in the CALLING shell on every return. Leaves that care about the status
#   channel MUST invoke `_gl_api ... > "$tmpfile"` (redirect, not `$(…)`
#   capture) so `GL_API_STATUS` survives command substitution.
#
# `_gl_urlencode <string>` is the shared jq-based URL encoder (`@uri`) —
# leaves use it for dynamic project refs, label names, file paths only; the
# static `GITLAB_PROJECT` is already encoded.
#
# TRANSPORT-LIB SELF-SOURCE: `_gl_api` and `_gl_urlencode` live in
# `lib-gitlab-transport.sh` (a sibling file in `providers/`, #416). We source it
# from this leaf so a caller that sources ONLY `lib-code-host.sh` (which sources
# `chp-gitlab.sh` per CODE_HOST=gitlab) gets the transport contract without a
# separate wire-up. GUARDED on `declare -F _gl_api`: if `_gl_api` is already
# defined (unit test with a test-local stub, or an operator's out-of-tree hook
# already installed pre-source) we DO NOT re-source — a re-source would overwrite
# the stub/override. Resolve the sibling via `readlink -f` of this file's own
# BASH_SOURCE so a symlinked skill-tree resolves the real file (matches the
# lib-code-host.sh idiom line 39). Sourcing failure is FATAL under `set -e` —
# a missing transport lib on a gitlab-active axis is a config bug, not a soft
# degradation.
if ! declare -F _gl_api >/dev/null 2>&1; then
  _CHP_GITLAB_SELF="${BASH_SOURCE[0]:-$0}"
  _CHP_GITLAB_DIR="$(cd "$(dirname "$(readlink -f "$_CHP_GITLAB_SELF")")" && pwd)"
  # shellcheck source=/dev/null
  [[ -f "${_CHP_GITLAB_DIR}/lib-gitlab-transport.sh" ]] && \
    source "${_CHP_GITLAB_DIR}/lib-gitlab-transport.sh"
fi

# Unit tests define a test-local `_gl_api` stub BEFORE sourcing this file, so
# every assertion in test-chp-gitlab-{reads,writes}.sh is leaf-contract-vs-spec
# (bucket tables, projection, sort, fail-closed) with ZERO live GitLab I/O.
# The self-source above is short-circuited by the `declare -F _gl_api` guard
# when the stub is pre-installed.
#
# CHP verbs implemented here (spec §3.2), split by phase-3 slice:
#
#   READS (P3-3, #418):
#     chp_gitlab_ci_status            chp_gitlab_mergeable
#     chp_gitlab_pr_view              chp_gitlab_pr_list
#     chp_gitlab_find_pr_for_issue    chp_gitlab_list_inline_comments
#     chp_gitlab_review_threads
#
#   WRITES + remaining verbs (P3-4, #419):
#     chp_gitlab_create_pr            chp_gitlab_approve
#     chp_gitlab_merge                chp_gitlab_pr_comment
#     chp_gitlab_reply_review_comment chp_gitlab_resolve_thread
#     chp_gitlab_close_keyword        chp_gitlab_commit_file
#     chp_gitlab_trigger_bot          chp_gitlab_count_reviews_by_login
#     chp_gitlab_file_url
#
#   PR-diff-soft-cap read (#452):
#     chp_gitlab_pr_diffstat — the first leaf in this file to issue a GraphQL
#     call (`_gl_graphql`, lib-gitlab-transport.sh), for the `lines` dimension
#     only; `files` reads the base MR view's `.changes_count` at zero extra
#     cost (same REST-only `_gl_api` path every other leaf here uses).
#
# `chp_gitlab_request_changes` is DELIBERATELY ABSENT (cap
# `rest_request_changes=0`, §5.1; the caller's cap=0 branch posts the
# request-changes marker via `itp_post_comment`).

# _chp_gitlab_require_project — fail-loud rc≠0 when GITLAB_PROJECT is unset or
# empty. Called from every leaf's entry. Under `set -u` (the way production
# callers and the conformance runner both run) a bare `${GITLAB_PROJECT:-}`
# splice would abort with an obscure "unbound variable" — this guard surfaces
# a clear diagnostic instead (matches the auth-lib WARN-latch pattern in
# spirit, though this is fail-loud not latched-once since a leaf that gets
# called with GITLAB_PROJECT unset is a real config bug, not a transient).
_chp_gitlab_require_project() {
  if [[ -z "${GITLAB_PROJECT:-}" ]]; then
    echo "ERROR: chp_gitlab_${1:-<verb>}: GITLAB_PROJECT env var required (unset or empty). Set GITLAB_PROJECT=<url-encoded project path> in autonomous.conf — see §3.4 / docs/gitlab-token-setup.md." >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Shared vocabulary constants (guarded `readonly` so a transitive re-source
# of lib-code-host.sh does not abort under `set -e` with `readonly variable`
# — mirrors chp-github.sh's guarded `readonly` idiom).
# ---------------------------------------------------------------------------
declare -p _CHP_GITLAB_PR_FIELDS_SUPPORTED >/dev/null 2>&1 || \
  readonly _CHP_GITLAB_PR_FIELDS_SUPPORTED="number,state,title,body,createdAt,updatedAt,mergedAt,headRefName,headRefOid,reviewDecision,mergeable,closingIssueNumbers,comments,reviews"

# `chp_pr_list` / `chp_find_pr_for_issue` reject `comments` (same W1c1 support
# matrix as GitHub — the list-walk cannot fold ISSUE-level comments without
# crossing the ITP/CHP seam; issue-level comments live behind
# `itp_list_comments` and PR inline comments live behind
# `chp_list_inline_comments`). `reviews` IS supported (via per-MR /approvals
# synthesis, fetched only when requested).
declare -p _CHP_GITLAB_PR_LIST_FIELDS_UNSUPPORTED >/dev/null 2>&1 || \
  readonly _CHP_GITLAB_PR_LIST_FIELDS_UNSUPPORTED="comments"

# ---------------------------------------------------------------------------
# _chp_gitlab_pr_state_map <normalized-state> — map open|closed|merged|all
# to GitLab's native list-endpoint `state` query value. STATE mapping (§3.2
# DISJOINT enum vs GitLab's list semantics):
#   open   -> opened
#   closed -> closed  (GitLab natively excludes merged from state=closed;
#                      leaf-side post-filter guarantees disjointness regardless)
#   merged -> merged
#   all    -> all
# NOTE the R5 list-side consequence of the `locked→CLOSED` view mapping (see
# _chp_gitlab_pr_state_normalize below): GitLab's `state=closed` list filter
# EXCLUDES `locked` MRs — a locked MR is INVISIBLE to
# `chp_gitlab_pr_list closed`. Accepted, documented asymmetry since locked is
# a transient lock-during-merge state (spec §5.1, R4).
# ---------------------------------------------------------------------------
_chp_gitlab_pr_state_map() {
  case "$1" in
    open)   printf 'opened' ;;
    closed) printf 'closed' ;;
    merged) printf 'merged' ;;
    all)    printf 'all' ;;
    *)      return 1 ;;
  esac
}

# _chp_gitlab_pr_state_normalize <gitlab-state> — GitLab-native `.state` ->
# §3.2.1 normalized enum. `opened->OPEN, closed->CLOSED, merged->MERGED,
# locked->CLOSED` (no caller distinguishes locked from CLOSED — a locked MR
# is a transient lock-during-merge state); any other future state -> `""`
# (data-source honesty).
_chp_gitlab_pr_state_normalize() {
  case "$1" in
    opened) printf 'OPEN' ;;
    closed) printf 'CLOSED' ;;
    merged) printf 'MERGED' ;;
    locked) printf 'CLOSED' ;;
    *)      printf '' ;;
  esac
}

# _chp_gitlab_pr_list_page_cap — read-and-clamp CHP_GITLAB_PR_LIST_PAGE_CAP.
# Default 20 pages. Cap-hit before pagination exhaustion is fail-CLOSED
# (§3.5, mirrors CHP_GITHUB_PR_LIST_PAGE_CAP semantics).
_chp_gitlab_pr_list_page_cap() {
  local cap="${CHP_GITLAB_PR_LIST_PAGE_CAP:-20}"
  [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) || cap=20
  printf '%s' "$cap"
}

# _chp_gitlab_review_threads_page_cap — CHP_GITLAB_REVIEW_THREADS_PAGE_CAP.
# Default 50 pages.
_chp_gitlab_review_threads_page_cap() {
  local cap="${CHP_GITLAB_REVIEW_THREADS_PAGE_CAP:-50}"
  [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) || cap=50
  printf '%s' "$cap"
}

# _chp_gitlab_parse_pr_fields <fields-csv> [forced-extra-fields...] — parse
# CSV, dedupe, validate against the full §3.2.1 vocabulary. Rejects unknown
# fields and any field named in _CHP_GITLAB_PR_LIST_FIELDS_UNSUPPORTED (when
# `unsupported_flag` argument is "list"; empty flag means the caller supports
# the full vocabulary, e.g. chp_gitlab_pr_view). Sets _CHP_GL_PARSED_FIELDS.
#
# Usage: _chp_gitlab_parse_pr_fields "<csv>" "<flag: view|list>" [forced...]
_chp_gitlab_parse_pr_fields() {
  local fields="$1" flag="$2"; shift 2
  _CHP_GL_PARSED_FIELDS=""
  local seen="," f
  local IFS_SAVE=$IFS; IFS=','
  # shellcheck disable=SC2206
  local -a _caller=(${fields})
  IFS="$IFS_SAVE"
  local -a _all=("${_caller[@]}" "$@")
  for f in "${_all[@]}"; do
    # trim surrounding whitespace (a caller CSV "a, b" must not smuggle " b")
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    [ -n "$f" ] || continue
    # Vocabulary gate: reject anything outside §3.2.1 (14 members). Loudly.
    case ",${_CHP_GITLAB_PR_FIELDS_SUPPORTED}," in
      *",$f,"*) : ;;
      *)
        echo "ERROR: chp_gitlab pr_view/pr_list/find_pr_for_issue: field '$f' is not in the §3.2.1 vocabulary ($_CHP_GITLAB_PR_FIELDS_SUPPORTED). GitLab-native names (e.g. 'iid', 'description', 'notes', 'source_branch') MUST use the vocabulary name so a non-GitLab caller can consume the same shape." >&2
        return 2 ;;
    esac
    # Per-verb support gate (list-side rejects `comments`; view-side accepts all).
    if [ "$flag" = "list" ]; then
      case ",${_CHP_GITLAB_PR_LIST_FIELDS_UNSUPPORTED}," in
        *",$f,"*)
          echo "ERROR: chp_gitlab pr_list/find_pr_for_issue: field '$f' is not delivered by these verbs (issue-comments live on the ITP seam — use itp_list_comments; PR inline comments — use chp_list_inline_comments)" >&2
          return 2 ;;
      esac
    fi
    case "$seen" in
      *",$f,"*) : ;;
      *) seen="$seen$f,"; _CHP_GL_PARSED_FIELDS="${_CHP_GL_PARSED_FIELDS:+$_CHP_GL_PARSED_FIELDS,}$f" ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# chp_gitlab_ci_status PR — normalized CI-status token (#418 R2).
#
# Spec cell: §3.2 (green|pending|failed|none), §5.1 GitLab CHP reads row.
# Endpoint: GET /projects/${GITLAB_PROJECT:-}/merge_requests/<pr> — reads
# `.head_pipeline.status`.
# Fail contract: `_gl_api` rc≠0, missing `head_pipeline` key, or non-object
# payload → leaf rc≠0 with EMPTY stdout (payload-type gate; the caller's
# `ci_is_green` treats rc≠0 as not-green).
#
# NORMATIVE BUCKET TABLE (verbatim from #418 R2 and spec §5.1):
#   null (no pipeline)                                    -> none
#   success                                               -> green
#   failed                                                -> failed
#   canceled                                              -> failed
#     (terminal not-green; parity with GitHub CANCELLED → failed)
#   skipped                                               -> pending
#     (mirrors GitHub SKIPPED → pending; NOTE skipped IS terminal on GitLab —
#     a deliberately-skipped-pipeline project would never read green;
#     accepted for parity, revisit only if a real deployment hits it)
#   manual, created, waiting_for_resource, preparing,
#   pending, running, scheduled                           -> pending
#   any unrecognized future status                        -> pending
#     (conservative not-green not-terminal; matches the GitHub leaf's
#      decision order — a future GitLab release adding a token defaults to
#      pending and the wrapper is honest about not knowing).
# ---------------------------------------------------------------------------
chp_gitlab_ci_status() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || {
    echo "ERROR: chp_gitlab_ci_status requires PR (1st arg, non-empty numeric): got '${pr}'" >&2
    return 2
  }
  _chp_gitlab_require_project ci_status || return 1
  local raw
  raw="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  # Payload-type gate. `type == "object"` guards `[]`, bare strings, bare
  # numbers, and null; a well-formed MR view passes.
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || return 1
  # `head_pipeline` key MUST exist (may be null for no-pipeline). A missing
  # key is a data-shape failure — reject rather than silently answer "none".
  jq -e 'has("head_pipeline")' >/dev/null 2>&1 <<<"$raw" || return 1
  local status
  status="$(jq -r '.head_pipeline.status // ""' <<<"$raw" 2>/dev/null)" || return 1
  # Empty status = null head_pipeline (no CI configured on this MR) → none.
  # `jq -r 'null // ""'` produces "", so we treat empty as null.
  # Bucket per the R2 table (verbatim in the header above).
  local head_pipe
  head_pipe="$(jq -r '.head_pipeline // "null"' <<<"$raw" 2>/dev/null)" || return 1
  if [ "$head_pipe" = "null" ]; then
    printf 'none'
    return 0
  fi
  case "$status" in
    success)              printf 'green' ;;
    failed)               printf 'failed' ;;
    canceled)             printf 'failed' ;;
    skipped)              printf 'pending' ;;
    manual|created|waiting_for_resource|preparing|pending|running|scheduled)
                          printf 'pending' ;;
    "")                   printf 'none' ;;  # defensive: null status with non-null head_pipeline
    *)                    printf 'pending' ;;  # unrecognized future token
  esac
}

# ---------------------------------------------------------------------------
# chp_gitlab_mergeable PR — normalized mergeable token (#418 R3).
#
# Spec cell: §3.2 (MERGEABLE|CONFLICTING|UNKNOWN), §5.1 GitLab CHP reads row.
# Endpoint: GET /projects/${GITLAB_PROJECT:-}/merge_requests/<pr> — reads
# `.detailed_merge_status` (GitLab ≥15.6; `merge_status` is deprecated and
# NOT read).
# Fail contract: MR fetch rc≠0 → leaf rc≠0 EMPTY stdout.
#
# NORMATIVE BUCKET TABLE (verbatim from #418 R3 and spec §5.1):
#   mergeable                                           -> MERGEABLE
#   conflict, need_rebase, commits_status, broken_status -> CONFLICTING
#     (structural inability to merge — matches _classify_mergeable_gate's
#      CONFLICTING semantics)
#   checking, unchecked, preparing, approvals_syncing   -> UNKNOWN
#     (server still computing — the gate's UNKNOWN-retry loop is the honest
#      path)
#   not_open                                            -> UNKNOWN
#     (the caller's _pr_open_gate is the correct decider; this leaf stays
#      out of state-gating it doesn't own)
#   ci_must_pass, ci_still_running, not_approved,
#   requested_changes, merge_request_blocked,
#   discussions_not_resolved, draft_status,
#   status_checks_must_pass, jira_association_missing,
#   merge_time, security_policy_violations,
#   security_policy_pipeline_check, locked_paths,
#   locked_lfs_files, title_regex                       -> UNKNOWN
#     (POLICY blocks orthogonal to structural mergeability; the wrapper owns
#      approve/merge and consults chp_ci_status / chp_review_threads /
#      the verdict trailer separately — surfacing these as CONFLICTING would
#      double-count the gate).
#   any unrecognized future token                       -> UNKNOWN
# ---------------------------------------------------------------------------
chp_gitlab_mergeable() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || {
    echo "ERROR: chp_gitlab_mergeable requires PR (1st arg, non-empty numeric): got '${pr}'" >&2
    return 2
  }
  _chp_gitlab_require_project mergeable || return 1
  local raw
  raw="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || return 1
  local dms
  dms="$(jq -r '.detailed_merge_status // ""' <<<"$raw" 2>/dev/null)" || return 1
  case "$dms" in
    mergeable)
      printf 'MERGEABLE' ;;
    conflict|need_rebase|commits_status|broken_status)
      printf 'CONFLICTING' ;;
    "")
      # Missing/unset — treat as UNKNOWN (a rc-0 MR view without a
      # detailed_merge_status field is server-still-computing on some GitLab
      # versions; the UNKNOWN-retry loop is the honest path).
      printf 'UNKNOWN' ;;
    *)
      # All POLICY-block tokens + checking/unchecked/preparing/approvals_syncing/
      # not_open + any unrecognized future token → UNKNOWN.
      printf 'UNKNOWN' ;;
  esac
}

# ---------------------------------------------------------------------------
# chp_gitlab_pr_view PR FIELDS_CSV — MR read leaf, NORMALIZED shape (#418 R4).
#
# Spec cell: §3.2.1 vocabulary (14 members); §5.1 GitLab CHP reads row.
# Endpoint: GET /projects/${GITLAB_PROJECT:-}/merge_requests/<pr>. When the
# caller requests one of these fields the leaf makes an ADDITIONAL fetch
# (fetch-cost gate — no extra HTTP when the field is NOT requested):
#   closingIssueNumbers -> /merge_requests/<pr>/closes_issues
#   comments            -> /merge_requests/<pr>/notes?sort=asc&order_by=created_at (paginated)
#   reviews             -> /merge_requests/<pr>/approvals
#
# Mapping (verbatim from #418 R4):
#   number ← .iid                (NOT .id — iid is the project-scoped #N)
#   state  ← .state              (opened→OPEN, closed→CLOSED, merged→MERGED,
#                                 locked→CLOSED, other→"")
#   title  ← .title
#   body   ← .description        (null → "" — the #148 hazard fix)
#   createdAt / updatedAt / mergedAt ← .created_at / .updated_at / .merged_at
#   headRefName ← .source_branch
#   headRefOid  ← .sha
#   reviewDecision → ""          (GitLab has NO single-token review decision;
#                                 the data-source-honesty rule forbids
#                                 synthesizing one)
#   mergeable   ← R3's normalized token (from .detailed_merge_status)
#   closingIssueNumbers ← [/closes_issues[].iid]  (int array; REQUESTED-only)
#   comments    ← [/notes with .system==false]    (normalized, ascending)
#   reviews     ← [/approvals.approved_by synthesized]  (state:"APPROVED")
#
# Fail contract: capture-then-check fail-CLOSED. rc≠0 with NO stdout on any
# of: MR fetch rc≠0 / rc-0 empty stdout / non-object payload / requested
# sub-resource fetch rc≠0 (data-source honesty — a `[]`-on-failure would be
# a lie).
# ---------------------------------------------------------------------------
chp_gitlab_pr_view() {
  local pr="${1:-}" fields_csv="${2:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || {
    echo "ERROR: chp_gitlab_pr_view requires PR (1st arg, non-empty numeric): got '${pr}'" >&2
    return 2
  }
  [ -n "$fields_csv" ] || {
    echo "ERROR: chp_gitlab_pr_view requires FIELDS_CSV (2nd arg) [§3.2.1]" >&2
    return 2
  }
  # Vocabulary gate BEFORE any HTTP dispatch — a caller must never smuggle a
  # GitLab-native name (`iid`, `description`, `notes`, `source_branch`)
  # through the seam.
  local _CHP_GL_PARSED_FIELDS
  _chp_gitlab_parse_pr_fields "$fields_csv" "view" || return $?
  _chp_gitlab_require_project pr_view || return 1

  # Base MR view — always fetched.
  local raw
  raw="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || return 1

  # Fetch-cost gates — sub-resource calls happen ONLY when the corresponding
  # vocabulary field is in the parsed set.
  local closes_json="null" notes_json="null" approvals_json="null"
  case ",${_CHP_GL_PARSED_FIELDS}," in
    *",closingIssueNumbers,"*)
      closes_json="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}/closes_issues" 2>/dev/null)" || return 1
      # Empty-200 → [] (an MR that closes zero issues is legitimate); a
      # transport/API failure was already caught above. Guard against a
      # rc-0-empty-stdout edge (a transient failure gh silently swallows).
      [ -n "$closes_json" ] || return 1
      jq -e 'type == "array"' >/dev/null 2>&1 <<<"$closes_json" || return 1
      ;;
  esac
  case ",${_CHP_GL_PARSED_FIELDS}," in
    *",comments,"*)
      notes_json="$(_gl_api --paginate "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}/notes?sort=asc&order_by=created_at" 2>/dev/null)" || return 1
      [ -n "$notes_json" ] || return 1
      jq -e 'type == "array"' >/dev/null 2>&1 <<<"$notes_json" || return 1
      ;;
  esac
  case ",${_CHP_GL_PARSED_FIELDS}," in
    *",reviews,"*)
      approvals_json="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}/approvals" 2>/dev/null)" || return 1
      [ -n "$approvals_json" ] || return 1
      jq -e 'type == "object"' >/dev/null 2>&1 <<<"$approvals_json" || return 1
      ;;
  esac

  # PROJECTION-ONLY: emit exactly the caller-requested fields — no fabrication.
  jq -n \
    --argjson mr "$raw" \
    --argjson closes    "$closes_json" \
    --argjson notes     "$notes_json" \
    --argjson approvals "$approvals_json" \
    --arg    fields    "$_CHP_GL_PARSED_FIELDS" \
    '
    ($mr) as $m
    | ($closes)    as $ci
    | ($notes)     as $nt
    | ($approvals) as $ap
    | ($fields | split(",")) as $req
    | reduce $req[] as $f ({};
        if   $f == "number"          then . + {number:      ($m.iid // null)}
        elif $f == "state"           then
          ($m.state // "" | ascii_downcase) as $st
          | (
              if   $st == "opened" then "OPEN"
              elif $st == "closed" then "CLOSED"
              elif $st == "merged" then "MERGED"
              elif $st == "locked" then "CLOSED"
              else "" end
            ) as $sn
          | . + {state: $sn}
        elif $f == "title"           then . + {title:       ($m.title // "")}
        elif $f == "body"            then . + {body:        ($m.description // "")}
        elif $f == "createdAt"       then . + {createdAt:   ($m.created_at // null)}
        elif $f == "updatedAt"       then . + {updatedAt:   ($m.updated_at // null)}
        elif $f == "mergedAt"        then . + {mergedAt:    ($m.merged_at // null)}
        elif $f == "headRefName"     then . + {headRefName: ($m.source_branch // "")}
        elif $f == "headRefOid"      then . + {headRefOid:  ($m.sha // "")}
        elif $f == "reviewDecision"  then . + {reviewDecision: ""}
        elif $f == "mergeable"       then
          ($m.detailed_merge_status // "" | ascii_downcase) as $dms
          | (
              if   $dms == "mergeable" then "MERGEABLE"
              elif ($dms == "conflict" or $dms == "need_rebase"
                    or $dms == "commits_status" or $dms == "broken_status") then "CONFLICTING"
              else "UNKNOWN" end
            ) as $mg
          | . + {mergeable: $mg}
        elif $f == "closingIssueNumbers" then
          . + {closingIssueNumbers: ([ ($ci // [])[]? | (.iid // empty) ])}
        elif $f == "comments"        then
          . + {comments:
                ([ ($nt // [])[]?
                   | select((.system // false) == false)
                   | { id: (.id // null),
                       author: ((.author.username) // null),
                       body: (.body // ""),
                       createdAt: (.created_at // null) } ]
                 | sort_by(.createdAt // "", .id // 0))}
        elif $f == "reviews"         then
          # Synthesize APPROVED reviews from the /approvals endpoint. The
          # submittedAt uses the top-level .approved_at (v17.x recorded probe;
          # the only per-approver timestamp the endpoint exposes today).
          (($ap // {}) | .approved_at // null) as $submitted
          | . + {reviews:
                  ([ (($ap // {}) | .approved_by // [])[]?
                     | { author: ((.user.username) // null),
                         state: "APPROVED",
                         submittedAt: $submitted } ]
                   | sort_by(.submittedAt // ""))}
        else . end)
    ' 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# chp_gitlab_pr_list STATE FIELDS-CSV — normalized MR-list read leaf (#418 R5).
#
# Spec cell: §3.2 chp_pr_list row; §5.1 GitLab CHP reads.
# Endpoint: GET /projects/${GITLAB_PROJECT:-}/merge_requests?state=<mapped>
#           &order_by=created_at&sort=desc — page-walked via `_gl_api
#           --paginate`.
# State mapping (§3.2 DISJOINT — a leaf-side post-filter guarantees
# disjointness regardless of GitLab's server-side semantics):
#   open   -> opened
#   closed -> closed  (GitLab excludes merged natively; leaf post-filters
#                      anyway)
#   merged -> merged
#   all    -> all
# The R5 list-side asymmetry (locked MRs are invisible to `state=closed`) is
# spec-documented in §5.1 and the header of chp_gitlab_pr_view above.
# Fail contract: complete-set (§3.5) fail-CLOSED — `_gl_api --paginate` rc≠0
# or CHP_GITLAB_PR_LIST_PAGE_CAP hit → rc≠0 EMPTY stdout, no partial output.
# REJECT `comments` in fields (rc≠0 loud — same W1c1 support matrix).
# `reviews` supported via per-MR /approvals synthesis (only when requested —
# fetch-cost gate applies).
# ---------------------------------------------------------------------------
chp_gitlab_pr_list() {
  local state="${1:-}" fields="${2:-}"
  [ -n "$state" ]  || { echo "ERROR: chp_gitlab_pr_list requires STATE (1st arg)" >&2; return 2; }
  [ -n "$fields" ] || { echo "ERROR: chp_gitlab_pr_list requires FIELDS-CSV (2nd arg)" >&2; return 2; }
  local state_lc gitlab_state
  state_lc="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
  gitlab_state="$(_chp_gitlab_pr_state_map "$state_lc")" || {
    echo "ERROR: chp_gitlab_pr_list STATE must be one of open|closed|merged|all (got '$state')" >&2
    return 2
  }
  # Parse + reject `comments` (list-side unsupported); `reviews` OK.
  local _CHP_GL_PARSED_FIELDS
  _chp_gitlab_parse_pr_fields "$fields" "list" || return $?
  _chp_gitlab_require_project pr_list || return 1

  # Page-walk via the frozen #416 transport contract. `_gl_api --paginate`
  # owns the walk, the 429 backoff, and the merge-into-one-array — fail-CLOSED
  # per §3.5. The leaf-scoped `GL_TRANSPORT_PAGE_CAP=<n>` env var narrows the
  # transport's own page cap for THIS call, so a caller cap-hit is loud rc≠0
  # with EMPTY stdout (NEVER a partial `--max-items`-bounded rc-0 array — the
  # earlier `--max-items` approach was an ITEM bound with rc-0 partial-by-design
  # semantics, not the fail-CLOSED cap the R5 spec pins). #416 R1 pins
  # `GL_TRANSPORT_PAGE_CAP` as the fail-CLOSED knob.
  local page_cap; page_cap="$(_chp_gitlab_pr_list_page_cap)"
  local raw_list
  raw_list="$(GL_TRANSPORT_PAGE_CAP="$page_cap" _gl_api --paginate \
    "/projects/${GITLAB_PROJECT:-}/merge_requests?state=${gitlab_state}&order_by=created_at&sort=desc" \
    2>/dev/null)" || return 1
  [ -n "$raw_list" ] || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw_list" || return 1

  # Post-filter for DISJOINTNESS — GitLab's state=closed natively excludes
  # merged, but we filter anyway so a future GitLab version cannot break
  # the §3.2 disjoint enum. For `all` we skip the filter.
  local filtered
  if [ "$state_lc" = "all" ]; then
    filtered="$raw_list"
  else
    filtered="$(jq -c --arg s "$gitlab_state" 'map(select((.state // "") == $s))' <<<"$raw_list" 2>/dev/null)" || return 1
  fi

  # Per-candidate sub-resource fetches (fetch-cost gates). The GitHub
  # reference leaf (`chp_github_pr_list`) delivers `closingIssueNumbers` via
  # its GraphQL sub-selection `closingIssuesReferences(first:100){nodes{number}}`
  # — a caller that requests the field gets REAL numbers, never a fabricated
  # `[]`. GitLab has no equivalent list-embedded field, so we mirror the
  # semantic by fetching `/merge_requests/N/closes_issues` per candidate ONLY
  # when the field is requested (a bounded per-MR extra call; `pr_list` callers
  # requesting closingIssueNumbers are rare — the linkage-resolution primary is
  # `chp_find_pr_for_issue`, which already does the per-MR walk). Same for
  # `reviews` via `/approvals`. One combined loop so an N-MR list makes ≤2N
  # extra requests total. Fail-CLOSED on any REQUESTED-field sub-resource
  # fetch failure (data-source honesty — a `[]`-on-failure would be a lie the
  # caller cannot distinguish from a real empty closing/approvals set).
  local need_reviews=0 need_closes=0
  case ",${_CHP_GL_PARSED_FIELDS}," in *",reviews,"*)             need_reviews=1 ;; esac
  case ",${_CHP_GL_PARSED_FIELDS}," in *",closingIssueNumbers,"*) need_closes=1  ;; esac
  local candidates_with_reviews="$filtered"
  if [ "$need_reviews" = "1" ] || [ "$need_closes" = "1" ]; then
    local n i iid record
    n="$(jq 'length' <<<"$filtered" 2>/dev/null)" || return 1
    local -a with_side=()
    for ((i=0; i<n; i++)); do
      iid="$(jq -r ".[${i}].iid // empty" <<<"$filtered" 2>/dev/null)" || return 1
      [ -n "$iid" ] || return 1
      record="$(jq -c ".[${i}]" <<<"$filtered" 2>/dev/null)" || return 1
      if [ "$need_closes" = "1" ]; then
        local ci_json
        ci_json="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${iid}/closes_issues" 2>/dev/null)" || return 1
        [ -n "$ci_json" ] || return 1
        jq -e 'type == "array"' >/dev/null 2>&1 <<<"$ci_json" || return 1
        record="$(jq -c --argjson ci "$ci_json" '. + {_gl_closes: $ci}' <<<"$record" 2>/dev/null)" || return 1
      fi
      if [ "$need_reviews" = "1" ]; then
        local ap
        ap="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${iid}/approvals" 2>/dev/null)" || return 1
        [ -n "$ap" ] || return 1
        jq -e 'type == "object"' >/dev/null 2>&1 <<<"$ap" || return 1
        record="$(jq -c --argjson ap "$ap" '. + {_gl_approvals: $ap}' <<<"$record" 2>/dev/null)" || return 1
      fi
      with_side+=("$record")
    done
    if [ "$n" = "0" ]; then
      candidates_with_reviews='[]'
    else
      candidates_with_reviews="$(printf '%s\n' "${with_side[@]}" | jq -s -c '.')" || return 1
    fi
  fi

  # PROJECT to the caller's FIELDS-CSV. Projection-only — no fabrication.
  jq -c --arg fields "$_CHP_GL_PARSED_FIELDS" '
    [ .[]
      | . as $m
      | ($fields | split(",")) as $req
      | reduce $req[] as $f ({};
          if   $f == "number"          then . + {number:      ($m.iid // null)}
          elif $f == "state"           then
            ($m.state // "" | ascii_downcase) as $st
            | (
                if   $st == "opened" then "OPEN"
                elif $st == "closed" then "CLOSED"
                elif $st == "merged" then "MERGED"
                elif $st == "locked" then "CLOSED"
                else "" end
              ) as $sn
            | . + {state: $sn}
          elif $f == "title"           then . + {title:       ($m.title // "")}
          elif $f == "body"            then . + {body:        ($m.description // "")}
          elif $f == "createdAt"       then . + {createdAt:   ($m.created_at // null)}
          elif $f == "updatedAt"       then . + {updatedAt:   ($m.updated_at // null)}
          elif $f == "mergedAt"        then . + {mergedAt:    ($m.merged_at // null)}
          elif $f == "headRefName"     then . + {headRefName: ($m.source_branch // "")}
          elif $f == "headRefOid"      then . + {headRefOid:  ($m.sha // "")}
          elif $f == "reviewDecision"  then . + {reviewDecision: ""}
          elif $f == "mergeable"       then
            ($m.detailed_merge_status // "" | ascii_downcase) as $dms
            | (
                if   $dms == "mergeable" then "MERGEABLE"
                elif ($dms == "conflict" or $dms == "need_rebase"
                      or $dms == "commits_status" or $dms == "broken_status") then "CONFLICTING"
                else "UNKNOWN" end
              ) as $mg
            | . + {mergeable: $mg}
          elif $f == "closingIssueNumbers" then
            # Populated from the per-MR /closes_issues sidecar spliced by the
            # bash loop above (fetched ONLY when this field is requested —
            # fetch-cost gate mirrors the GitHub list-embedded
            # closingIssuesReferences sub-selection). Empty-200 → []; a
            # transport/API failure on the sub-resource already failed the
            # leaf rc≠0 with EMPTY stdout above (data-source honesty).
            . + {closingIssueNumbers: ([ ($m._gl_closes // [])[]? | (.iid // empty) ])}
          elif $f == "reviews"         then
            (($m._gl_approvals // {}) | .approved_at // null) as $submitted
            | . + {reviews:
                    ([ (($m._gl_approvals // {}) | .approved_by // [])[]?
                       | { author: ((.user.username) // null),
                           state: "APPROVED",
                           submittedAt: $submitted } ]
                     | sort_by(.submittedAt // ""))}
          else . end) ]
  ' <<<"$candidates_with_reviews" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# chp_gitlab_find_pr_for_issue ISSUE FIELDS-CSV — normalized candidate MR
# fetch (#418 R6).
#
# Spec cell: §3.2 chp_find_pr_for_issue; §5.1 GitLab CHP reads.
# Endpoint: GET /projects/${GITLAB_PROJECT:-}/issues/<issue>/closed_by — the
# CLOSE-LINKAGE source (NOT /related_merge_requests, which lists MENTIONING
# MRs and would bind a non-closing MR causing the wrapper to mutate the wrong
# MR — spec §3.2 [M1] contract). Per-candidate `closingIssueNumbers` is then
# confirmed via /merge_requests/<iid>/closes_issues.
# Post-filter `.state == "opened"` in-leaf (matches the caller's
# `pushed-no-PR` classification contract).
# Fail contract: complete-set (§3.5) fail-CLOSED. Rejects `comments` in the
# field set (rc 2 loud — same W1c1 support matrix as chp_pr_list).
# ---------------------------------------------------------------------------
chp_gitlab_find_pr_for_issue() {
  local issue="${1:-}" fields="${2:-}"
  [[ "$issue" =~ ^[0-9]+$ ]] || {
    echo "ERROR: chp_gitlab_find_pr_for_issue requires ISSUE (1st arg, non-empty numeric): got '${issue}'" >&2
    return 2
  }
  [ -n "$fields" ] || {
    echo "ERROR: chp_gitlab_find_pr_for_issue requires FIELDS-CSV (2nd arg)" >&2
    return 2
  }
  # Parse + reject `comments`; force-union the W1c1 resolution keys.
  local _CHP_GL_PARSED_FIELDS
  _chp_gitlab_parse_pr_fields "$fields" "list" number closingIssueNumbers headRefName || return $?
  _chp_gitlab_require_project find_pr_for_issue || return 1

  # Fetch the close-linked candidate MRs. `_gl_api --paginate` — an issue
  # with >20 close-linked MRs is exceptional but not impossible; if the
  # transport hits the page cap, that is fail-CLOSED per §3.5.
  local candidates
  candidates="$(_gl_api --paginate \
    "/projects/${GITLAB_PROJECT:-}/issues/${issue}/closed_by" \
    2>/dev/null)" || return 1
  [ -n "$candidates" ] || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$candidates" || return 1

  # Post-filter to opened MRs. Empty candidate set → [].
  local filtered
  filtered="$(jq -c '[ .[] | select((.state // "") == "opened") ]' <<<"$candidates" 2>/dev/null)" || return 1

  # Per-MR /closes_issues confirmation — data-source honesty on the [INV-86]
  # resolution key: we NEVER fabricate `closingIssueNumbers` for a candidate
  # (even when the caller could infer it from the issue arg — the seam
  # contract is that the LEAF walks the linkage).
  local n i iid ci_json
  n="$(jq 'length' <<<"$filtered" 2>/dev/null)" || return 1
  local candidates_with_ci="$filtered"
  local need_reviews=0
  case ",${_CHP_GL_PARSED_FIELDS}," in
    *",reviews,"*) need_reviews=1 ;;
  esac
  if [ "$n" != "0" ]; then
    local -a with_ci=()
    for ((i=0; i<n; i++)); do
      iid="$(jq -r ".[${i}].iid // empty" <<<"$filtered" 2>/dev/null)" || return 1
      [ -n "$iid" ] || return 1
      ci_json="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${iid}/closes_issues" 2>/dev/null)" || return 1
      [ -n "$ci_json" ] || return 1
      jq -e 'type == "array"' >/dev/null 2>&1 <<<"$ci_json" || return 1
      local record="$(jq -c --argjson ci "$ci_json" ".[${i}] + {_gl_closes: \$ci}" <<<"$filtered" 2>/dev/null)" || return 1
      if [ "$need_reviews" = "1" ]; then
        local ap
        ap="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${iid}/approvals" 2>/dev/null)" || return 1
        [ -n "$ap" ] || return 1
        jq -e 'type == "object"' >/dev/null 2>&1 <<<"$ap" || return 1
        record="$(jq -c --argjson ap "$ap" '. + {_gl_approvals: $ap}' <<<"$record" 2>/dev/null)" || return 1
      fi
      with_ci+=("$record")
    done
    candidates_with_ci="$(printf '%s\n' "${with_ci[@]}" | jq -s -c '.')" || return 1
  fi

  # Project each candidate to FIELDS-CSV ∪ resolution keys.
  jq -c --arg fields "$_CHP_GL_PARSED_FIELDS" '
    [ .[]
      | . as $m
      | ($fields | split(",")) as $req
      | reduce $req[] as $f ({};
          if   $f == "number"          then . + {number:      ($m.iid // null)}
          elif $f == "state"           then
            ($m.state // "" | ascii_downcase) as $st
            | (
                if   $st == "opened" then "OPEN"
                elif $st == "closed" then "CLOSED"
                elif $st == "merged" then "MERGED"
                elif $st == "locked" then "CLOSED"
                else "" end
              ) as $sn
            | . + {state: $sn}
          elif $f == "title"           then . + {title:       ($m.title // "")}
          elif $f == "body"            then . + {body:        ($m.description // "")}
          elif $f == "createdAt"       then . + {createdAt:   ($m.created_at // null)}
          elif $f == "updatedAt"       then . + {updatedAt:   ($m.updated_at // null)}
          elif $f == "mergedAt"        then . + {mergedAt:    ($m.merged_at // null)}
          elif $f == "headRefName"     then . + {headRefName: ($m.source_branch // "")}
          elif $f == "headRefOid"      then . + {headRefOid:  ($m.sha // "")}
          elif $f == "reviewDecision"  then . + {reviewDecision: ""}
          elif $f == "mergeable"       then
            ($m.detailed_merge_status // "" | ascii_downcase) as $dms
            | (
                if   $dms == "mergeable" then "MERGEABLE"
                elif ($dms == "conflict" or $dms == "need_rebase"
                      or $dms == "commits_status" or $dms == "broken_status") then "CONFLICTING"
                else "UNKNOWN" end
              ) as $mg
            | . + {mergeable: $mg}
          elif $f == "closingIssueNumbers" then
            . + {closingIssueNumbers: ([ ($m._gl_closes // [])[]? | (.iid // empty) ])}
          elif $f == "reviews"         then
            (($m._gl_approvals // {}) | .approved_at // null) as $submitted
            | . + {reviews:
                    ([ (($m._gl_approvals // {}) | .approved_by // [])[]?
                       | { author: ((.user.username) // null),
                           state: "APPROVED",
                           submittedAt: $submitted } ]
                     | sort_by(.submittedAt // ""))}
          else . end) ]
  ' <<<"$candidates_with_ci" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# chp_gitlab_list_inline_comments PR — PR inline (file-anchored) review-comment
# read leaf, NORMALIZED + COMPLETE (#418 R7).
#
# Spec cell: §3.2 chp_list_inline_comments row; §5.1 GitLab CHP reads.
# Endpoint: GET /projects/${GITLAB_PROJECT:-}/merge_requests/<pr>/discussions —
# page-walked via `_gl_api --paginate`.
# Element mapping (matches chp_list_inline_comments' CHP-owned flat shape):
#   id ← note.id
#   path ← note.position.new_path // note.position.old_path // null
#   line ← note.position.new_line // note.position.old_line // null
#   author ← note.author.username
#   body ← note.body           (null → "")
#   createdAt ← note.created_at
# Filters (in-leaf):
#   - notes with `.position == null` are non-inline (general MR notes;
#     inline-only per the W1c2 contract).
#   - `.system == true` notes are non-user audit-trail entries (would poison
#     [INV-90] marker scans).
# Fail contract: rc≠0 EMPTY stdout on any page fetch failure; empty
# → `[]` rc 0.
# ---------------------------------------------------------------------------
chp_gitlab_list_inline_comments() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || {
    echo "ERROR: chp_gitlab_list_inline_comments requires PR (1st arg, non-empty numeric): got '${pr}'" >&2
    return 2
  }
  _chp_gitlab_require_project list_inline_comments || return 1
  local raw
  raw="$(_gl_api --paginate \
    "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}/discussions" \
    2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || return 1

  jq -c '
    [ .[]? | (.notes // [])[]?
      | select((.position // null) != null)
      | select((.system // false) == false)
      | { id:        (.id // null),
          path:      ((.position.new_path) // (.position.old_path) // null),
          line:      ((.position.new_line) // (.position.old_line) // null),
          author:    ((.author.username)   // null),
          body:      (.body // ""),
          createdAt: (.created_at // null) } ]
    | sort_by(.createdAt // "", .id // 0)
  ' <<<"$raw" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# chp_gitlab_review_threads PR — COMPLETE review-thread set, M8 shape (#418 R8).
#
# Spec cell: §3.2 [M8]; §3.5 COMPLETE; §5.1 GitLab CHP reads.
# Endpoint: GET /projects/${GITLAB_PROJECT:-}/merge_requests/<pr>/discussions —
# page-walked via `_gl_api --paginate`. GitLab returns all notes per
# discussion in ONE response, so ONE pagination level suffices (simpler than
# the GitHub W1f two-level walk — pinned in §5.1).
#
# M8 shape (byte-compatible with resolve-threads.sh's consumer selector
# `.[]|select(.resolved==false).thread_id`):
#   [{thread_id, resolved, comments:[{id, path, line, author, body, createdAt}]}]
#
# thread_id encoding: the COMPOUND string "<mr-iid>:<discussion.id>" —
# GitLab's discussion-resolve endpoint needs the MR iid in the URL path AND
# the discussion id, but the phase-2 `chp_resolve_thread <thread-id>` verb
# takes ONE opaque positional. The GitHub thread_id is an opaque GraphQL
# node id the caller never parses; a compound string preserves the seam
# shape. P3-4's chp_gitlab_resolve_thread decodes it. Pinned in §3.2 M8.
#
# resolvable-only filter: a discussion is resolved iff its first note is
# `resolvable == true AND resolved == true`. The leaf FILTERS to resolvable
# discussions only (non-resolvable general notes must NOT reach
# resolve-threads.sh's mutation loop — a mutation on a non-resolvable
# discussion would 400 at the GitLab API).
#
# system-note filter applies to `comments[]` (matches R7).
#
# Fail contract: bounded walk via CHP_GITLAB_REVIEW_THREADS_PAGE_CAP
# (default 50); cap-hit or mid-walk failure → rc≠0 EMPTY stdout (the
# mandatory failure fixture — mirrors #401's fail-CLOSED for the GitHub
# leaf).
# ---------------------------------------------------------------------------
chp_gitlab_review_threads() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || {
    echo "ERROR: chp_gitlab_review_threads requires PR (1st arg, non-empty numeric): got '${pr}'" >&2
    return 2
  }
  _chp_gitlab_require_project review_threads || return 1
  local page_cap; page_cap="$(_chp_gitlab_review_threads_page_cap)"
  # Forward the per-verb cap to the transport as its own PAGE-CAP env var
  # (#416 R1: `GL_TRANSPORT_PAGE_CAP` scoped per call). This is the
  # fail-CLOSED cap-hit knob — cap-hit → rc≠0 with EMPTY stdout, matching
  # the R8 mandatory-failure fixture semantics. `--max-items` is deliberately
  # NOT used here: it is an ITEM bound with rc-0 partial-by-design return,
  # which would violate §3.5's fail-CLOSED-on-cap-hit MUST.
  local raw
  raw="$(GL_TRANSPORT_PAGE_CAP="$page_cap" _gl_api --paginate \
    "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}/discussions" \
    2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || return 1

  jq -c --arg pr "$pr" '
    [ .[]?
      | . as $disc
      | (($disc.notes // []) | .[0]) as $first
      | select(($first.resolvable // false) == true)
      | { thread_id: ($pr + ":" + ($disc.id // "" | tostring)),
          resolved: (($first.resolved // false) == true),
          comments: ([ ($disc.notes // [])[]?
                       | select((.system // false) == false)
                       | { id:        (.id // null),
                           path:      ((.position.new_path) // (.position.old_path) // null),
                           line:      ((.position.new_line) // (.position.old_line) // null),
                           author:    ((.author.username)   // null),
                           body:      (.body // ""),
                           createdAt: (.created_at // null) } ]) }
    ]
  ' <<<"$raw" 2>/dev/null || return 1
}

# ===========================================================================
# P3-4 WRITE LEAVES (#419) — chp_gitlab_{create_pr, approve, merge, pr_comment,
# reply_review_comment, resolve_thread, close_keyword, commit_file, trigger_bot,
# count_reviews_by_login} + chp_gitlab_file_url.
#
# EVERY leaf routes HTTP exclusively through _gl_api (frozen #416 contract);
# NO leaf touches _gl_http. Dynamic path/query components go through
# _gl_urlencode; the static GITLAB_PROJECT config is stored ALREADY URL-encoded
# per §3.4 and used verbatim.
# ===========================================================================

# _chp_gitlab_project_raw — decode GITLAB_PROJECT (or a REPO positional
# override) to the RAW slash-bearing project path. Used by chp_gitlab_file_url
# and chp_gitlab_reply_review_comment for browser-facing URL synthesis —
# browser URLs use the RAW path, NOT the URL-encoded API id (§5.1).
_chp_gitlab_project_raw() {
  local encoded="${1:-${GITLAB_PROJECT:-}}"
  # `jq -rn '$s | @uri | ...` decodes: split on `%`, hex-decode the byte pairs.
  # Simpler: use printf's URL-decode via a jq pipeline.
  jq -rn --arg s "$encoded" '
    $s
    | split("%")
    | reduce .[1:][] as $p (.[0];
        if ($p | length) >= 2 then
          . + ([( $p[0:2] | ascii_downcase )] | map(
              if . == "20" then " "
              elif . == "2f" then "/"
              elif . == "2e" then "."
              elif . == "2d" then "-"
              elif . == "5f" then "_"
              elif . == "25" then "%"
              elif . == "3a" then ":"
              elif . == "40" then "@"
              else "%" + . end
            ) | .[0]) + ($p[2:] // "")
        else . + "%" + $p end)
  '
}

# ---------------------------------------------------------------------------
# chp_gitlab_create_pr HEAD_BRANCH TITLE BODY  (#419 R2)
#
# POST /projects/${GITLAB_PROJECT}/merge_requests with body
# `{source_branch, target_branch:<target>, title, description,
#   squash:true, remove_source_branch:true}` (CONTRACT-FIXED per W1e).
#
# `<target>` resolution (issue #478, [INV-131]): when `BASE_BRANCH` is set
# (the wrapper resolves+exports it once at startup — see
# lib-config.sh::resolve_base_branch), it is used DIRECTLY as the explicit
# target — no project probe, matching R5's "pass the flag unconditionally,
# explicit-deterministic beats relying on the host's repo-default-branch
# setting" posture. With `BASE_BRANCH` unset (today's universal case), this
# leaf is BYTE-IDENTICAL to pre-#478: it still resolves the project's
# `default_branch` via ONE `GET /projects/${GITLAB_PROJECT}` per invocation
# (no cache — stale-cache hazard). GitLab default-branch auto-DETECTION
# itself is unchanged/out of scope for #478 — only the override path is new.
#
# Positional validation mirrors the GitHub leaf: HEAD_BRANCH and TITLE non-empty
# (rc 2 loud, NO HTTP); BODY MAY be empty (the broker's title-only create is
# legitimate — the #400 caller-trace lesson).
#
# Fail-CLOSED: rc≠0 on the project probe failure OR the POST failure. Success:
# stdout MAY echo the created MR web_url (callers don't depend on it — mirrors
# the GitHub leaf's `gh pr create` URL echo which callers discard).
# ---------------------------------------------------------------------------
chp_gitlab_create_pr() {
  local head_branch="${1:-}" title="${2:-}" body="${3:-}"
  [ -n "$head_branch" ] || { echo "ERROR: chp_gitlab_create_pr requires HEAD_BRANCH (1st arg, non-empty)" >&2; return 2; }
  [ -n "$title" ]       || { echo "ERROR: chp_gitlab_create_pr requires TITLE (2nd arg, non-empty)" >&2; return 2; }
  # BODY may be empty by design — do NOT gate.

  # Resolve target branch. #478: an explicit BASE_BRANCH skips the project
  # probe entirely (explicit-deterministic). Otherwise, resolve the
  # project's default branch per invocation (pre-#478 behavior, unchanged).
  local default_branch
  if [ -n "${BASE_BRANCH:-}" ]; then
    default_branch="$BASE_BRANCH"
  else
    local project_raw
    project_raw="$(_gl_api "/projects/${GITLAB_PROJECT}" 2>/dev/null)" || return 1
    [ -n "$project_raw" ] || return 1
    default_branch="$(jq -r '.default_branch // ""' <<<"$project_raw" 2>/dev/null)"
    [ -n "$default_branch" ] || return 1
  fi

  # Build MR-create body via jq (injection-safe: title/body/branch names go
  # through jq --arg, never spliced into a string).
  local mr_body
  mr_body="$(jq -cn \
    --arg src    "$head_branch" \
    --arg dst    "$default_branch" \
    --arg title  "$title" \
    --arg body   "$body" \
    '{source_branch: $src, target_branch: $dst, title: $title, description: $body, squash: true, remove_source_branch: true}')" || return 1

  local create_response
  create_response="$(_gl_api --method POST --body "$mr_body" \
    "/projects/${GITLAB_PROJECT}/merge_requests" 2>/dev/null)" || return 1
  [ -n "$create_response" ] || return 1
  # Echo the created MR's web_url (opaque to callers; matches GitHub leaf's
  # URL echo). Callers don't depend on stdout.
  jq -r '.web_url // ""' <<<"$create_response" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# chp_gitlab_approve PR BODY  (#419 R3)
#
# TWO calls, ordering LOAD-BEARING:
#   1. POST /projects/…/merge_requests/:iid/approve — the load-bearing action;
#      feeds chp_gitlab_count_reviews_by_login.
#   2. POST /projects/…/merge_requests/:iid/notes with `{body}` — diagnostic
#      only.
#
# Failure posture:
#   - approve OK + note FAIL → rc 0 with WARN on stderr (the wrapper's PASS path
#     tolerates note-only failure).
#   - approve FAIL → rc≠0, note NOT attempted (a failed approve with a comment
#     stub is dishonest; the wrapper's manual-review fallback is the correct
#     terminal).
#
# PR ^[0-9]+$ (rc 2 loud NO HTTP); BODY non-empty (rc 2 loud NO HTTP).
# ---------------------------------------------------------------------------
chp_gitlab_approve() {
  local pr="${1:-}" body="${2:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_gitlab_approve requires PR (1st arg, non-empty numeric): got '${pr}'" >&2; return 2; }
  [ -n "$body" ]           || { echo "ERROR: chp_gitlab_approve requires BODY (2nd arg, non-empty)" >&2; return 2; }

  # Call 1: /approve — LOAD-BEARING (approve-FAIL → rc≠0, note NOT attempted).
  _gl_api --method POST \
    "/projects/${GITLAB_PROJECT}/merge_requests/${pr}/approve" >/dev/null 2>&1 || return 1

  # Call 2: /notes — DIAGNOSTIC. Approve-OK + note-FAIL → rc 0 with WARN on
  # stderr (wrapper PASS tolerates note-only failure — parity with GitHub's
  # `gh pr review --approve --body` where the note is part of the same call and
  # a body-only failure is not observable; here it is, so we warn but keep
  # rc 0).
  local note_body
  note_body="$(jq -cn --arg b "$body" '{body: $b}')" || return 1
  if ! _gl_api --method POST --body "$note_body" \
       "/projects/${GITLAB_PROJECT}/merge_requests/${pr}/notes" >/dev/null 2>&1; then
    echo "WARN: chp_gitlab_approve: approve OK but note POST failed (non-fatal — PR is approved)." >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# chp_gitlab_merge PR  (#419 R4)
#
# PUT /projects/…/merge_requests/:iid/merge with body
# `{squash:true, should_remove_source_branch:true}`. GitLab's not-mergeable
# error responses (405 / 409 / 422 per the MR-merge API doc) surface AS-IS
# through _gl_api's fail-closed rc≠0 path — the response `.message` is what
# the caller's first-500-chars excerpt posts (#145 parity).
#
# PR ^[0-9]+$ (rc 2 loud, NO HTTP — highest blast radius). Success rc 0 with
# response body preserved on stdout; failure rc≠0 with _gl_api's stderr
# excerpt preserved.
#
# [M4]/[INV-33]: GitLab auto-closes `Closes #N` issues on merge-to-default
# (`merge_closes_issue=1` per caps §5.1). The caller-side cap check is
# UNCHANGED.
# ---------------------------------------------------------------------------
chp_gitlab_merge() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_gitlab_merge requires PR (1st arg, non-empty numeric): got '${pr}'" >&2; return 2; }

  local merge_body='{"squash":true,"should_remove_source_branch":true}'
  _gl_api --method PUT --body "$merge_body" \
    "/projects/${GITLAB_PROJECT}/merge_requests/${pr}/merge"
}

# ---------------------------------------------------------------------------
# chp_gitlab_pr_comment PR --body <string>  (#419 R5)
#
# AUDITED shape — all 7 GitHub call sites (lib-review-e2e.sh:351/387/394/409/620
# + autonomous-review.sh:3604/3813) pass `--body <string>`; no --body-file / no
# --edit-last. The GitLab leaf parses exactly that shape and POSTs `{body}` to
# /projects/…/merge_requests/:iid/notes. The GitHub leaf stays byte-identical
# (unchanged this PR).
#
# PR ^[0-9]+$ (rc 2 loud); missing/malformed --body → rc 2 loud NO HTTP.
# ---------------------------------------------------------------------------
chp_gitlab_pr_comment() {
  local pr="${1:-}"; shift
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_gitlab_pr_comment requires PR (1st arg, non-empty numeric): got '${pr}'" >&2; return 2; }

  # Parse the audited `--body <string>` shape. Any other arg pattern fails
  # loud — the audit result is pinned; a future --body-file/--edit-last caller
  # would need a leaf update.
  local body="" have_body=0
  while (( $# > 0 )); do
    case "$1" in
      --body) [[ $# -ge 2 ]] || { echo "ERROR: chp_gitlab_pr_comment: --body requires a value" >&2; return 2; }
              body="$2"; have_body=1; shift 2 ;;
      --body=*) body="${1#*=}"; have_body=1; shift ;;
      *) echo "ERROR: chp_gitlab_pr_comment: unsupported arg '$1' — audit pins --body <string> as the ONLY shape (extend the audit + leaf if a new caller needs another flag)" >&2; return 2 ;;
    esac
  done
  [ "$have_body" = "1" ] || { echo "ERROR: chp_gitlab_pr_comment requires --body <string>" >&2; return 2; }

  local note_body
  note_body="$(jq -cn --arg b "$body" '{body: $b}')" || return 1
  _gl_api --method POST --body "$note_body" \
    "/projects/${GITLAB_PROJECT}/merge_requests/${pr}/notes"
}

# ---------------------------------------------------------------------------
# chp_gitlab_reply_review_comment PR COMMENT_ID BODY  (#419 R6, [INV-96])
#
# GitLab replies attach to a DISCUSSION, not a bare note id. The leaf resolves
# COMMENT_ID → its discussion id by page-walking `GET /projects/…/
# merge_requests/:iid/discussions` (via _gl_api --paginate) and finding the
# discussion whose `.notes[]` contains `.id == COMMENT_ID`, then POSTs to
# /projects/…/discussions/:discussion_id/notes with `{body}`.
#
# One full walk per reply — unavoidable given GitLab's model (documented cost
# boundary; the sole caller reply-to-comments.sh already loops per-comment).
#
# Echo `{id, url}` parity with GitHub. GitLab's created-note response has `.id`
# but no `html_url` — SYNTHESIZE
#   url = "https://${GITLAB_HOST}/<decoded-project-path>/-/merge_requests/${pr}#note_${id}"
# using the RAW (percent-DECODED) slash-bearing project path (browser URLs use
# the raw path, NOT the URL-encoded `GITLAB_PROJECT` API id — a URL-encoded
# browser link is a 404 in the UI).
#
# Missing comment-id in the walk → rc≠0; mid-walk failure → rc≠0.
# ---------------------------------------------------------------------------
chp_gitlab_reply_review_comment() {
  local pr="${1:-}" comment_id="${2:-}" body="${3:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_gitlab_reply_review_comment requires PR (1st arg, non-empty numeric): got '${pr}'" >&2; return 2; }
  [ -n "$comment_id" ]     || { echo "ERROR: chp_gitlab_reply_review_comment requires COMMENT_ID (2nd arg, non-empty)" >&2; return 2; }
  [ -n "$body" ]           || { echo "ERROR: chp_gitlab_reply_review_comment requires BODY (3rd arg, non-empty)" >&2; return 2; }

  # Walk discussions to find the owning discussion id. `_gl_api --paginate`
  # walks ALL pages; mid-walk failure → rc≠0 EMPTY stdout (frozen #416).
  local discussions
  discussions="$(_gl_api --paginate \
    "/projects/${GITLAB_PROJECT}/merge_requests/${pr}/discussions" \
    2>/dev/null)" || return 1
  [ -n "$discussions" ] || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$discussions" || return 1

  local discussion_id
  discussion_id="$(jq -r --argjson cid "$comment_id" '
    [ .[] | select( (.notes // []) | any(.id == $cid) ) ][0] | .id // empty
  ' <<<"$discussions" 2>/dev/null)"
  [ -n "$discussion_id" ] || {
    echo "ERROR: chp_gitlab_reply_review_comment: comment id ${comment_id} not found in any discussion on MR ${pr}" >&2
    return 1
  }

  # POST the reply.
  local reply_body
  reply_body="$(jq -cn --arg b "$body" '{body: $b}')" || return 1
  local reply_response
  reply_response="$(_gl_api --method POST --body "$reply_body" \
    "/projects/${GITLAB_PROJECT}/merge_requests/${pr}/discussions/${discussion_id}/notes" \
    2>/dev/null)" || return 1
  [ -n "$reply_response" ] || return 1
  local note_id
  note_id="$(jq -r '.id // ""' <<<"$reply_response" 2>/dev/null)"
  [ -n "$note_id" ] || return 1

  # Synthesize the browser URL using the RAW project path (percent-decoded).
  local project_raw
  project_raw="$(_chp_gitlab_project_raw)" || return 1
  local url="https://${GITLAB_HOST}/${project_raw}/-/merge_requests/${pr}#note_${note_id}"
  jq -cn --argjson id "$note_id" --arg url "$url" '{id: $id, url: $url}'
}

# ---------------------------------------------------------------------------
# chp_gitlab_resolve_thread THREAD_ID  (#419 R7)
#
# Decodes the P3-3 compound `<mr-iid>:<discussion-id>` (pinned in §3.2 [M8]).
# Malformed (no colon / non-numeric iid / empty discussion) → rc 2 loud NO HTTP.
# PUT /projects/…/merge_requests/:iid/discussions/:discussion_id body
# `{resolved:true}`. Echo the response `.resolved` bool verbatim (parity with
# GitHub GraphQL isResolved).
#
# The single-positional `chp_resolve_thread <thread-id>` seam contract is
# PRESERVED — no resolve-threads.sh change (it passes thread_id verbatim).
# ---------------------------------------------------------------------------
chp_gitlab_resolve_thread() {
  local thread_id="${1:-}"
  [ -n "$thread_id" ] || { echo "ERROR: chp_gitlab_resolve_thread requires THREAD_ID (1st arg, non-empty)" >&2; return 2; }
  # Decode <mr-iid>:<discussion-id>. `${x%%:*}`/`${x#*:}` doesn't distinguish
  # a missing colon from an empty tail — check for the colon literal explicitly.
  case "$thread_id" in
    *:*) : ;;
    *) echo "ERROR: chp_gitlab_resolve_thread: malformed THREAD_ID (expected '<mr-iid>:<discussion-id>', got '${thread_id}')" >&2; return 2 ;;
  esac
  local pr="${thread_id%%:*}" disc="${thread_id#*:}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_gitlab_resolve_thread: THREAD_ID iid must be numeric (got '${pr}')" >&2; return 2; }
  [ -n "$disc" ] || { echo "ERROR: chp_gitlab_resolve_thread: THREAD_ID discussion-id must be non-empty (got '${thread_id}')" >&2; return 2; }

  local resp
  resp="$(_gl_api --method PUT --body '{"resolved":true}' \
    "/projects/${GITLAB_PROJECT}/merge_requests/${pr}/discussions/${disc}" \
    2>/dev/null)" || return 1
  [ -n "$resp" ] || return 1
  jq -r '.resolved // false' <<<"$resp" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# chp_gitlab_close_keyword ISSUE  (#419 R9)
#
# Render `Closes #<iid>` — GitLab parses the same keyword; auto-close on merge
# to the default branch per `merge_closes_issue=1` (caps §5.1). Caller-side
# `_render_close_keyword` branch logic UNCHANGED.
# ---------------------------------------------------------------------------
chp_gitlab_close_keyword() {
  local issue="$1"
  printf 'Closes #%s' "$issue"
}

# ---------------------------------------------------------------------------
# chp_gitlab_commit_file REPO BRANCH FILE_PATH CONTENT_BASE64 MESSAGE  (#419 R10, [INV-99])
#
# Files API single-call collapse of the GitHub 8-call git-Data-API dance:
# `POST /projects/:id/repository/files/:urlencoded-path` with
# `{branch, encoding:"base64", content, commit_message}`.
#
# Provider-specific bootstrap the leaf owns (parity with the GitHub leaf's
# orphan-branch block):
#   1. Preflight branch existence: `_gl_api --tolerate-status 404
#      …/repository/branches/${branch_urlenc}` invoked with REDIRECT-TO-TEMPFILE
#      (NOT $(…) capture) so GL_API_STATUS survives — the frozen #416 CONTRACT
#      NOTE. 404 → probe project's default_branch, then POST
#      …/repository/branches?branch=…&ref=…; 200 → skip bootstrap.
#   2. Preflight file existence the same way: 200 → PUT update, 404 → POST
#      create.
#   3. Post-commit SHA lookup via GET …/repository/commits?ref_name=…&per_page=1
#      → `.[0].id` (cheaper than propagating a new success-token convention;
#      upload-screenshot.sh uses the SHA only for logging).
#
# EVERY dynamic path/query component (file path, branch, ref) goes through
# _gl_urlencode (slash-bearing branches like `feat/x` MUST be encoded per URL
# path segment).
#
# `<repo>` is an explicit $1 (the #324 dropped-arg lesson) mapped to the project
# path — honor a positional differing from ambient GITLAB_PROJECT.
#
# Large-body handling: temp-file + the INV-99 SELF-DISARMING RETURN trap
# `trap '…; trap - RETURN' RETURN` — verbatim discipline from the GitHub leaf.
# The #330 lesson: a bare RETURN trap persists into the shim's own return with
# the leaf's `local`s out of scope → `unbound variable` under `set -u`.
#
# Fail-CLOSED on any of the up-to-five calls.
# ---------------------------------------------------------------------------
chp_gitlab_commit_file() {
  local repo="$1" branch="$2" file_path="$3" content_base64="$4" message="$5"

  # [#419 P1-2] Encode the repo positional when it contains a raw `/`. The
  # caller may pass EITHER a pre-encoded slug (`group%2Fproject` — mirrors
  # the ambient GITLAB_PROJECT convention, §3.4) OR a RAW path
  # (`group/project` — the natural shape upload-screenshot.sh threads from
  # autonomous.conf's REPO). Detect: a `/` in the value means raw → encode.
  # A `%` in the value is treated as already-encoded pass-through (encoding
  # `%2F` would double-encode to `%252F`, which GitLab 404s on). This means
  # the ONE edge case a caller passing literal `%` in a project path lands
  # on the pass-through branch — GitLab project paths cannot contain `%` in
  # practice (path components are `[a-zA-Z0-9_.-]`), so the heuristic is
  # safe. Pinned by TC-P34-069 / test-chp-gitlab-writes.sh.
  local repo_enc="$repo"
  case "$repo" in
    *%*) : ;;                                     # pre-encoded → pass-through
    */*)  repo_enc="$(_gl_urlencode "$repo")" || return 1 ;;
    *)   : ;;                                     # single-segment (no slash) → verbatim
  esac

  local branch_enc path_enc
  branch_enc="$(_gl_urlencode "$branch")" || return 1
  path_enc="$(_gl_urlencode "$file_path")" || return 1

  # Step 1: branch existence preflight — redirect-to-tempfile so GL_API_STATUS
  # survives (frozen #416 CONTRACT NOTE).
  local status_tmp json_tmpfile
  status_tmp="$(mktemp)"
  json_tmpfile="$(mktemp)"
  # Self-disarming function-scoped RETURN trap (INV-99 discipline): clean these
  # temps at THIS invocation's return path, then immediately clear the trap so
  # it does NOT persist to fire again on the shim's own return (the bare-RETURN
  # hazard reproduced on-box, #330).
  trap 'rm -f "$status_tmp" "$json_tmpfile"; trap - RETURN' RETURN

  local branch_probe_status branch_exists=0
  _gl_api --tolerate-status 404 --status-out "$status_tmp" \
    "/projects/${repo_enc}/repository/branches/${branch_enc}" >/dev/null 2>&1 || {
      echo "ERROR: chp_gitlab_commit_file: branch existence preflight failed" >&2
      return 1
    }
  branch_probe_status="$(cat "$status_tmp" 2>/dev/null)"
  if [ "$branch_probe_status" = "200" ]; then
    branch_exists=1
  elif [ "$branch_probe_status" = "404" ]; then
    branch_exists=0
  else
    echo "ERROR: chp_gitlab_commit_file: unexpected branch preflight status '${branch_probe_status}'" >&2
    return 1
  fi

  # Step 1b: bootstrap the branch if absent (orphan-branch parity with GitHub).
  if [ "$branch_exists" = "0" ]; then
    local project_raw default_branch default_branch_enc
    project_raw="$(_gl_api "/projects/${repo_enc}" 2>/dev/null)" || return 1
    [ -n "$project_raw" ] || return 1
    default_branch="$(jq -r '.default_branch // ""' <<<"$project_raw" 2>/dev/null)"
    [ -n "$default_branch" ] || return 1
    default_branch_enc="$(_gl_urlencode "$default_branch")" || return 1
    _gl_api --method POST \
      "/projects/${repo_enc}/repository/branches?branch=${branch_enc}&ref=${default_branch_enc}" \
      >/dev/null 2>&1 || return 1
  fi

  # Step 2: file existence preflight — same redirect-to-tempfile pattern.
  local file_probe_status file_verb="POST"
  _gl_api --tolerate-status 404 --status-out "$status_tmp" \
    "/projects/${repo_enc}/repository/files/${path_enc}?ref=${branch_enc}" \
    >/dev/null 2>&1 || {
      echo "ERROR: chp_gitlab_commit_file: file existence preflight failed" >&2
      return 1
    }
  file_probe_status="$(cat "$status_tmp" 2>/dev/null)"
  if [ "$file_probe_status" = "200" ]; then
    file_verb="PUT"
  elif [ "$file_probe_status" = "404" ]; then
    file_verb="POST"
  else
    echo "ERROR: chp_gitlab_commit_file: unexpected file preflight status '${file_probe_status}'" >&2
    return 1
  fi

  # Step 3: build the JSON payload into a TEMP FILE and pass it via the P3-4
  # `--body-file` channel (#419 P1-3) — the base64 body for screenshots can
  # exceed ARG_MAX (`E2BIG` at ~270KB on typical Linux boxes, reproduced
  # on-box), so we NEVER read it back into a shell variable. Additionally we
  # stage the base64 content on disk FIRST and let jq slurp it with
  # `--rawfile` (also file-mediated, no argv splice) — the pre-P1-3 code
  # used `--arg content "$content_base64"` which itself blew the argv on
  # large payloads. Two file hops (content → jq stdin, then json → curl)
  # keep the whole path ARG_MAX-safe. `_gl_http` streams `--data-binary
  # @<path>` to curl directly.
  local content_tmpfile
  content_tmpfile="$(mktemp)"
  printf '%s' "$content_base64" > "$content_tmpfile" || {
    rm -f "$content_tmpfile"
    return 1
  }
  jq -cn \
    --arg branch     "$branch" \
    --rawfile content "$content_tmpfile" \
    --arg msg        "$message" \
    '{branch: $branch, encoding: "base64", content: $content, commit_message: $msg}' \
    > "$json_tmpfile" 2>/dev/null
  local jq_rc=$?
  rm -f "$content_tmpfile"
  [ "$jq_rc" -eq 0 ] || return 1

  _gl_api --method "$file_verb" --body-file "$json_tmpfile" \
    "/projects/${repo_enc}/repository/files/${path_enc}" \
    >/dev/null 2>&1 || return 1

  # Step 4: fetch the commit SHA (post-commit lookup — GitLab's Files API
  # create/update response carries `file_path` + `branch` but NO commit SHA).
  local commits_json commit_sha
  commits_json="$(_gl_api \
    "/projects/${repo_enc}/repository/commits?ref_name=${branch_enc}&per_page=1" \
    2>/dev/null)" || return 1
  [ -n "$commits_json" ] || return 1
  commit_sha="$(jq -r '.[0].id // ""' <<<"$commits_json" 2>/dev/null)"
  [ -n "$commit_sha" ] || return 1
  printf '%s\n' "$commit_sha"
}

# ---------------------------------------------------------------------------
# chp_gitlab_trigger_bot PR TRIGGER  (#419 R12)
#
# `review_bots=0` (caps §5.1) — the caller's `parse_review_bots` short-circuits
# at cap=0 BEFORE the leaf. The leaf is a safety net: rc 0 with no HTTP.
# ---------------------------------------------------------------------------
chp_gitlab_trigger_bot() {
  # Deliberate no-op — see the header. Do NOT emit stderr; the caller does not
  # invoke this leaf when review_bots=0, and if reached (misconfig), rc 0 is
  # safer than a WARN spam.
  return 0
}

# ---------------------------------------------------------------------------
# chp_gitlab_count_reviews_by_login REPO PR LOGIN  (#419 R13, [INV-94])
#
# Count from `GET /projects/:repo/merge_requests/:pr/approvals` →
# `.approved_by[]` where `.user.username == LOGIN`. Data-source honesty
# (§5.1): GitLab has no review objects; approvals are the closest semantic.
# `/approvals` is single-page bounded (no --paginate needed).
#
# LOGIN JSON-encoded into the jq program (injection-safe — mirrors GitHub leaf).
# ANY failure → `echo 0; return 0` (parity — the caller's `^[0-9]+$` gate +
# `-eq 0` MISSING decision expects 0-on-failure, NEVER rc≠0).
# ---------------------------------------------------------------------------
chp_gitlab_count_reviews_by_login() {
  local repo="$1" pr="$2" login="$3" login_json count
  # [#419 review r3] Encode a raw slash-bearing repo positional — the caller
  # (missing_bot_reviews, lib-review-bots.sh) threads autonomous.conf's RAW
  # `group/project` REPO, not the pre-encoded GITLAB_PROJECT. Same detect
  # heuristic as chp_gitlab_commit_file (`%` → pre-encoded pass-through;
  # `/` → encode; single-segment → verbatim). Without this the
  # /projects/group/project/... path 404s and the fail-safe `echo 0` makes
  # every configured review bot read MISSING forever.
  local repo_enc="$repo"
  case "$repo" in
    *%*) : ;;
    */*) repo_enc="$(_gl_urlencode "$repo")" || { echo 0; return 0; } ;;
    *)   : ;;
  esac
  # Injection-safe: --arg puts LOGIN into a jq variable, then @json emits its
  # JSON-encoded string literal spliceable into a select() expression.
  login_json="$(jq -rn --arg loginarg "$login" '$loginarg | @json' 2>/dev/null)" || { echo 0; return 0; }
  local approvals
  approvals="$(_gl_api "/projects/${repo_enc}/merge_requests/${pr}/approvals" 2>/dev/null)" || { echo 0; return 0; }
  [ -n "$approvals" ] || { echo 0; return 0; }
  count="$(jq -r --argjson _dummy 0 \
    "[.approved_by[]? | select(.user.username == ${login_json})] | length" \
    <<<"$approvals" 2>/dev/null)" || { echo 0; return 0; }
  # Guard against any non-numeric jq output (e.g. `null` if the payload
  # shape is off) — collapse to 0.
  [[ "$count" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
  printf '%s\n' "$count"
}

# ---------------------------------------------------------------------------
# chp_gitlab_file_url REPO BRANCH FILE_PATH  (#419 R11)
#
# Render the browser blob URL. Pure string render, NO HTTP (parallels
# chp_close_keyword's render pattern).
#   https://${GITLAB_HOST}/<decoded-project-path>/-/blob/${BRANCH}/${FILE_PATH}
#
# Browser URLs use the RAW slash-bearing project path (NOT the URL-encoded
# GITLAB_PROJECT API id — a URL-encoded browser link is a UI 404). The leaf
# percent-DECODES GITLAB_PROJECT (or REPO if the caller passes a non-empty
# override — mirrors chp_gitlab_commit_file's explicit-repo convention).
#
# Sibling of chp_github_file_url — same signature, different host + path shape.
# The shim `chp_file_url` in lib-code-host.sh forwards "$@".
# ---------------------------------------------------------------------------
chp_gitlab_file_url() {
  local repo="${1:-}" branch="$2" file_path="$3"
  # Empty REPO → fall back to ambient GITLAB_PROJECT (the standard-repo case;
  # upload-screenshot.sh threads its own $REPO which is the encoded slug).
  local project_encoded
  if [ -n "$repo" ]; then
    project_encoded="$repo"
  else
    project_encoded="${GITLAB_PROJECT:-}"
  fi
  local project_raw
  project_raw="$(_chp_gitlab_project_raw "$project_encoded")" || return 1
  printf 'https://%s/%s/-/blob/%s/%s' "$GITLAB_HOST" "$project_raw" "$branch" "$file_path"
}

# ---------------------------------------------------------------------------
# chp_gitlab_pr_diffstat PR DIMENSIONS-CSV  (#452)
#
# `files` ← the base MR view's `.changes_count` (string; populated
# asynchronously, capped and rendered as the literal `"1000+"` above 1000 —
# parsed down to the integer `1000` here). Zero extra API cost: the base MR
# view is a single `_gl_api` GET regardless of which dimension(s) are
# requested.
#
# `lines` ← a SEPARATE GraphQL `diffStatsSummary { additions deletions }`
# call (`_gl_graphql`, lib-gitlab-transport.sh) — issued ONLY when `lines` is
# actually in DIMENSIONS-CSV (pay-only-if-requested; a `files`-only request
# never reaches the GraphQL leaf at all). `changed_lines` is
# `additions + deletions`.
#
# Independent failure domains (data-source honesty, mirrors
# chp_gitlab_pr_view's fetch-cost-gated sub-resources): a GraphQL failure
# (auth/network/schema error) does NOT suppress a `files` result already read
# successfully from the base MR view — the leaf omits ONLY the `changed_lines`
# key on that failure, still returning `{changed_files: N}` at rc 0 when
# `files` was also requested. The base MR view read failing is a HARD failure
# for the whole call (rc≠0, no partial output) — `files` cannot be answered
# without it, and if `lines` was also requested there is no MR to fetch the
# GraphQL side against either.
# ---------------------------------------------------------------------------
chp_gitlab_pr_diffstat() {
  local pr="${1:-}" dims="${2:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || {
    echo "ERROR: chp_gitlab_pr_diffstat requires PR (1st arg, non-empty numeric): got '${pr}'" >&2
    return 2
  }
  [ -n "$dims" ] || {
    echo "ERROR: chp_gitlab_pr_diffstat requires DIMENSIONS-CSV (2nd arg, non-empty subset of files,lines)" >&2
    return 2
  }
  local want_files=0 want_lines=0
  case ",${dims}," in *",files,"*) want_files=1 ;; esac
  case ",${dims}," in *",lines,"*) want_lines=1 ;; esac
  if [[ "$want_files" -eq 0 && "$want_lines" -eq 0 ]]; then
    echo "ERROR: chp_gitlab_pr_diffstat: DIMENSIONS-CSV '${dims}' contains no recognized dimension (files|lines)" >&2
    return 2
  fi
  _chp_gitlab_require_project pr_diffstat || return 1

  # Base MR view — always fetched (both dimensions need the MR to exist; the
  # `files` dimension reads `.changes_count` directly from it).
  local raw
  raw="$(_gl_api "/projects/${GITLAB_PROJECT:-}/merge_requests/${pr}" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || return 1

  local out='{}'
  if [[ "$want_files" -eq 1 ]]; then
    local changes_count files_n
    changes_count="$(jq -r '.changes_count // ""' <<<"$raw" 2>/dev/null)"
    if [[ -n "$changes_count" ]]; then
      # The capped-string case: "1000+" → integer 1000.
      if [[ "$changes_count" == "1000+" ]]; then
        files_n=1000
      elif [[ "$changes_count" =~ ^[0-9]+$ ]]; then
        files_n="$changes_count"
      fi
      [[ -n "${files_n:-}" ]] && out="$(jq -c --argjson n "$files_n" '. + {changed_files: $n}' <<<"$out")"
    fi
  fi

  if [[ "$want_lines" -eq 1 ]]; then
    local project_raw gql_data additions deletions
    project_raw="$(_chp_gitlab_project_raw)" 2>/dev/null || project_raw=""
    if [[ -n "$project_raw" ]]; then
      local query='query($fullPath: ID!, $iid: String!) { project(fullPath: $fullPath) { mergeRequest(iid: $iid) { diffStatsSummary { additions deletions } } } }'
      local vars
      vars="$(jq -cn --arg fp "$project_raw" --arg iid "$pr" '{fullPath: $fp, iid: $iid}' 2>/dev/null)"
      if [[ -n "$vars" ]]; then
        gql_data="$(_gl_graphql "$query" "$vars" 2>/dev/null)" || gql_data=""
      fi
    fi
    if [[ -n "${gql_data:-}" ]] && jq -e '.project.mergeRequest.diffStatsSummary != null' >/dev/null 2>&1 <<<"$gql_data"; then
      additions="$(jq -r '.project.mergeRequest.diffStatsSummary.additions // 0' <<<"$gql_data" 2>/dev/null)"
      deletions="$(jq -r '.project.mergeRequest.diffStatsSummary.deletions // 0' <<<"$gql_data" 2>/dev/null)"
      if [[ "$additions" =~ ^[0-9]+$ && "$deletions" =~ ^[0-9]+$ ]]; then
        out="$(jq -c --argjson n "$((additions + deletions))" '. + {changed_lines: $n}' <<<"$out")"
      fi
    fi
    # GraphQL failure (auth/network/schema/empty project path) → `changed_lines`
    # simply stays absent from `out`; a `files` result already assembled above
    # is UNAFFECTED (data-source honesty — independent failure domains).
  fi

  printf '%s' "$out"
}
