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

# 7 CHP read verbs implemented here (spec §3.2):
#   chp_gitlab_ci_status            chp_gitlab_mergeable
#   chp_gitlab_pr_view              chp_gitlab_pr_list
#   chp_gitlab_find_pr_for_issue    chp_gitlab_list_inline_comments
#   chp_gitlab_review_threads
# The write verbs + `chp_close_keyword`/`chp_trigger_bot`/`chp_request_changes`/
# `chp_reply_review_comment`/`chp_count_reviews_by_login`/`chp_commit_file`
# land in P3-4 (serialized-behind-this — same file, avoids the conflict
# cluster).

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
