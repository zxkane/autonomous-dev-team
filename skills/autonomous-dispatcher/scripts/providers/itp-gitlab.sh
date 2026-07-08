#!/bin/bash
# providers/itp-gitlab.sh — GitLab Issue-Tracker Provider (ITP) reference impl.
#
# 14 ITP verbs (spec §3.1) mapped to standard GitLab REST v4 Issues API,
# consuming the FROZEN P3-1 transport contract (#416):
#
#   _gl_api [--method M] [--paginate] [--body JSON] [--tolerate-status CSV]
#           [--max-items N] [--status-out FILE] <path>
#     — public transport function. Owns pagination merge, 429/Retry-After
#       backoff, fail-CLOSED discipline. Sets GL_API_STATUS in the calling
#       shell on every return. `--tolerate-status CSV` makes named statuses
#       return rc 0 with body on stdout and GL_API_STATUS observable. Leaves
#       MUST invoke via redirect (not $() capture) to see GL_API_STATUS.
#   _gl_urlencode <string>
#     — jq @uri encoder for dynamic refs (cross-project paths, label names).
#       Note: `GITLAB_PROJECT` is stored ALREADY URL-encoded per §3.4 and
#       used verbatim (leaves do NOT re-encode it).
#
# Every leaf routes through `_gl_api`. Leaves NEVER call curl or _gl_http
# directly ([INV-113] transport choke-point, [INV-91] caller-layer discipline).
# JSON request bodies are composed with `jq -c -n --arg …` — never string-
# interpolated user text (marker HTML, labels, bodies all pass through the
# jq arg channel).
#
# PRECONDITION: sourced by lib-issue-provider.sh from the REAL skill tree
# (readlink -f of that lib's BASH_SOURCE). `$REPO`, `$BOT_LOGIN`, and the
# GitLab config keys `GITLAB_PROJECT` / `GITLAB_HOST` / `GITLAB_TOKEN`
# (spec §3.4) are in scope from the caller's environment. Under standalone
# unit tests, the tests define local `_gl_api` / `_gl_urlencode` stubs BEFORE
# sourcing this file so the leaves invoke the stubs.
#
# 14 ITP verbs (matches itp-github.sh's set):
#   itp_gitlab_list_by_state       itp_gitlab_count_by_state        [W1a]
#   itp_gitlab_list_forbidden_combos                                [W1a]
#   itp_gitlab_read_task           itp_gitlab_list_comments         [READ]
#   itp_gitlab_transition_state    itp_gitlab_post_comment          [itp-writes]
#   itp_gitlab_edit_comment        itp_gitlab_mark_checkbox         [itp-writes]
#   itp_gitlab_provision_states                                     [itp-writes]
#   itp_gitlab_resolve_dep         itp_gitlab_begin_tick            [DEP]
#   itp_gitlab_label_event_ts                                       [OBSERVE]
# (itp_caps reads the .caps manifest in the dispatcher, not a function here.)
#
# Transport lib self-source. `lib-issue-provider.sh` sources ONLY
# `itp-<PROVIDER>.sh` (spec §6 / lib-issue-provider.sh:65); the transport lib
# is a SIBLING file in `providers/`, so the leaf self-sources it here. Guarded
# on `_gl_api` presence so a unit test that pre-defines local `_gl_api` /
# `_gl_urlencode` stubs (test-itp-gitlab.sh) keeps its stubs — a re-source
# that redefined the transport functions would blow the test-local
# hermeticity away. Under production the guard is trivially false (nothing
# has defined `_gl_api` yet) so the real transport lib loads. Uses the
# `readlink -f` idiom the rest of the codebase relies on so a project-side
# symlink into the skill tree resolves correctly ([INV-14]/[INV-65], spec §6).
if ! declare -F _gl_api >/dev/null 2>&1; then
  _ITP_GITLAB_SELF="${BASH_SOURCE[0]:-$0}"
  _ITP_GITLAB_REAL_DIR="$(cd "$(dirname "$(readlink -f "$_ITP_GITLAB_SELF")")" && pwd 2>/dev/null)" || _ITP_GITLAB_REAL_DIR=""
  if [[ -n "$_ITP_GITLAB_REAL_DIR" && -r "${_ITP_GITLAB_REAL_DIR}/lib-gitlab-transport.sh" ]]; then
    # shellcheck source=lib-gitlab-transport.sh
    source "${_ITP_GITLAB_REAL_DIR}/lib-gitlab-transport.sh"
  fi
  unset _ITP_GITLAB_SELF _ITP_GITLAB_REAL_DIR
fi

# ---------------------------------------------------------------------------
# Internal helpers. Provider-scoped names (`_itp_gitlab_*`) mirror the GitHub
# side's `_itp_github_*` so a future refactor that adds more helpers here
# can't accidentally shadow the GitHub reference impl.
# ---------------------------------------------------------------------------

# _itp_gitlab_normalize_state <gitlab-state> — map GitLab `opened|closed` to
# provider-neutral UPPERCASE `OPEN|CLOSED` (spec §3.1 [W1b], #396). Any other
# input passes through empty (matches the itp_read_task "empty on missing"
# convention). Kept internal so a future spec change (e.g. adding a MERGED
# state for GitLab MRs, which this file does NOT own — MRs are CHP's problem)
# doesn't force a caller change.
_itp_gitlab_normalize_state() {
  case "$1" in
    opened) printf 'OPEN' ;;
    closed) printf 'CLOSED' ;;
    *)      printf '' ;;
  esac
}

# _itp_gitlab_project_fields <fields-csv> — reads the full normalized array
# on stdin and projects down to EXACTLY the requested fields (spec R1).
# Identical semantics to `_itp_github_project_fields`.
_itp_gitlab_project_fields() {
  local fields_csv="$1" fields_json
  fields_json=$(printf '%s' "$fields_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  jq --argjson fields "$fields_json" 'map(. as $o | ($fields | map({(.): $o[.]}) | add // {}))'
}

# _itp_gitlab_project_fields_object <fields-csv> — the single-object variant
# (mirrors _itp_github_project_fields at the object level for read_task).
_itp_gitlab_project_fields_object() {
  local fields_csv="$1" fields_json
  fields_json=$(printf '%s' "$fields_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  jq --argjson fields "$fields_json" '. as $o | ($fields | map({(.): $o[.]}) | add // {})'
}

# _itp_gitlab_map_state_arg <spec-state> — map spec's `open|closed|all` to
# GitLab's `opened|closed|all` (spec §5.1). Empty or unknown → pass through
# so a caller sees a fail-CLOSED response from the API rather than silent
# state remap.
_itp_gitlab_map_state_arg() {
  case "$1" in
    open) printf 'opened' ;;
    closed) printf 'closed' ;;
    all)   printf 'all' ;;
    *)     printf '%s' "$1" ;;
  esac
}

# _itp_gitlab_enumerate <state> <labels-and-csv> <limit> — internal:
# server-side state+label-AND enumeration returning the RAW GitLab issue
# array (not yet normalized). Shared by list_by_state / count_by_state /
# list_forbidden_combos. Uses `--paginate --max-items <limit>` so a
# LIMIT-bounded call cannot spuriously hit the page cap on a large project.
# Fail-CLOSED: `_gl_api` rc≠0 propagates unchanged; `set -e` under production
# aborts the pipe (capture-then-check applied one level up).
_itp_gitlab_enumerate() {
  local state="$1" labels_csv="$2" limit="$3"
  local gl_state qs
  gl_state=$(_itp_gitlab_map_state_arg "$state")
  qs="state=${gl_state}"
  # `per_page` is capped at 100 by the GitLab API. Passing --max-items lets
  # the transport stop the walk once LIMIT items have arrived (spec §3.1's
  # "applied server-side to the AND-labels-filtered candidate set").
  if [[ -n "$labels_csv" ]]; then
    qs="${qs}&labels=${labels_csv}"
  fi
  qs="${qs}&per_page=100"
  _gl_api --paginate --max-items "$limit" "/projects/${GITLAB_PROJECT}/issues?${qs}"
}

# _itp_gitlab_normalize_issue_row <bot-login> — internal jq stanza applied to
# a RAW GitLab issue array; emits the provider-neutral normalized array with
# fields {number,title,labels,assignees,comments}. `comments` STARTS as an
# empty array — the caller (list_by_state) fetches per-issue comments in a
# second pass only when FIELDS_CSV asks for them (mirrors #396-r2 discipline:
# no bulk state-read comment fetch, matches _itp_github_state_read's
# GraphQL-embedded array on the GitHub side, adjusted for GitLab which has no
# bulk-comments equivalent). Sort ascending by number.
# [#435, ISSUE_FILTER PR-A] `assignees` normalizes the REST response's
# `assignees` array (already present on the standard `/issues` payload — no
# extra API call) to an array of USERNAME strings, mirroring `labels`.
_itp_gitlab_normalize_issue_row() {
  jq '
    [ .[] | {
        number: (.iid // 0),
        title:  (.title // ""),
        labels: (.labels // []),
        assignees: [ (.assignees // [])[].username ],
        comments: []
      }
    ] | sort_by(.number)
  '
}

# ---------------------------------------------------------------------------
# W1a abstract state-read contracts (spec §3.1, #371 precedent).
# ---------------------------------------------------------------------------

# itp_gitlab_list_by_state <state> <labels-and-csv> <limit> <fields-csv>
#
# Spec §3.1 [W1a]. Server-side enumeration; normalize to
# {number,title,labels,comments}; project down to FIELDS_CSV.
# `iid` (project-scoped) → `number` (int) — GitLab's global `id` is NOT the
# reference key we want; the human/PR-linkage `#N` shorthand is over `iid`,
# so the leaf pins `iid` at the seam.
# Sort ascending by number. Empty → `[]`. Fail-CLOSED capture-then-check.
itp_gitlab_list_by_state() {
  local state="$1" labels_csv="$2" limit="$3" fields_csv="$4"
  local raw normalized issue comments_needed=0
  case ",${fields_csv}," in *,comments,*) comments_needed=1 ;; esac
  raw=$(_itp_gitlab_enumerate "$state" "$labels_csv" "$limit") || return 1
  [[ -n "$raw" ]] || return 1
  normalized=$(printf '%s' "$raw" | _itp_gitlab_normalize_issue_row) || return 1
  if [[ "$comments_needed" -eq 1 ]]; then
    # Same-tick per-issue comment fetch (mirrors #396-r2 on the GitHub side).
    # Fail-CLOSED: any leaf failure aborts the whole call.
    local iids c_json merged='[]'
    iids=$(printf '%s' "$normalized" | jq -r '.[].number')
    while IFS= read -r iid; do
      [[ -z "$iid" ]] && continue
      c_json=$(itp_gitlab_list_comments "$iid") || return 1
      merged=$(printf '%s' "$merged" | jq --argjson c "$c_json" --argjson n "$iid" '. + [{number:$n, comments:$c}]') || return 1
    done <<<"$iids"
    normalized=$(printf '%s' "$normalized" | jq --argjson m "$merged" '
      map(. as $o
          | (($m[] | select(.number == $o.number).comments) // []) as $cc
          | .comments = $cc)
    ') || return 1
  fi
  printf '%s' "$normalized" | _itp_gitlab_project_fields "$fields_csv"
}

# itp_gitlab_count_by_state <state> <labels-and-csv> <limit> <any-of-labels-csv>
#
# Spec §3.1 [W1a] — bare non-negative integer count of AND-matches whose
# label set intersects `any-of-labels-csv` (empty any-of = count all
# AND-matches). Same enumeration point as list_by_state.
itp_gitlab_count_by_state() {
  local state="$1" labels_csv="$2" limit="$3" any_of_csv="$4"
  local raw normalized any_of_json
  raw=$(_itp_gitlab_enumerate "$state" "$labels_csv" "$limit") || return 1
  [[ -n "$raw" ]] || return 1
  normalized=$(printf '%s' "$raw" | _itp_gitlab_normalize_issue_row) || return 1
  any_of_json=$(printf '%s' "$any_of_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  printf '%s' "$normalized" | jq --argjson anyof "$any_of_json" '
    [ .[] | select(
        ($anyof | length) == 0
        or ( .labels as $ls | $anyof | any(. as $a | $ls | index($a) != null) )
      )
    ] | length
  '
}

# itp_gitlab_list_forbidden_combos <state> <labels-and-csv> <limit>
#
# Spec §3.1 [W1a] / [INV-25]. GitLab's `not[labels]=X` is useful but
# insufficient for an intersection-of-incompatible-sets — enumerate then
# apply the SAME jq combo filter as the GitHub leaf. Fields:
# `number,labels,assignees` ([#435, ISSUE_FILTER PR-A] — widened
# unconditionally, mirroring the GitHub leaf).
itp_gitlab_list_forbidden_combos() {
  local state="$1" labels_csv="$2" limit="$3"
  local raw normalized
  raw=$(_itp_gitlab_enumerate "$state" "$labels_csv" "$limit") || return 1
  [[ -n "$raw" ]] || return 1
  normalized=$(printf '%s' "$raw" | _itp_gitlab_normalize_issue_row) || return 1
  printf '%s' "$normalized" | jq '
    [ .[] | select(
        (.labels | any(. == "approved" or . == "stalled"))
        and
        (.labels | any(. == "in-progress" or . == "reviewing" or . == "pending-review" or . == "pending-dev"))
      ) | {number, labels, assignees}
    ]
  '
}

# ---------------------------------------------------------------------------
# WRITE + LIFECYCLE leaves.
# ---------------------------------------------------------------------------

# itp_gitlab_transition_state <issue> <remove-csv> <add-csv>
#
# Spec §3.1 / [INV-08] / [INV-97]. SINGLE PUT combining add+remove — cleaner
# than the GitHub leaf's per-flag arg dance. Empty side omits its KEY
# entirely (behavior-parity with the GitHub leaf's empty-side `--…-label`
# omission).
# GitLab endpoint: `PUT /projects/:id/issues/:iid` with body
# `{"add_labels":"csv","remove_labels":"csv"}` (comma-separated strings, spec
# §3.1 precondition — labels comma-free, inert for the pipeline).
itp_gitlab_transition_state() {
  local issue="$1" remove="$2" add="$3" body
  # jq -n composes ONLY the non-empty keys — omit the empty side entirely.
  if [[ -n "$remove" && -n "$add" ]]; then
    body=$(jq -c -n --arg a "$add" --arg r "$remove" '{add_labels:$a, remove_labels:$r}')
  elif [[ -n "$add" ]]; then
    body=$(jq -c -n --arg a "$add" '{add_labels:$a}')
  elif [[ -n "$remove" ]]; then
    body=$(jq -c -n --arg r "$remove" '{remove_labels:$r}')
  else
    # No-op: both sides empty. Byte-parity with the GitHub leaf which would
    # emit no `--*-label` flags at all — succeed silently.
    return 0
  fi
  _gl_api --method PUT --body "$body" "/projects/${GITLAB_PROJECT}/issues/${issue}"
}

# itp_gitlab_read_task <issue> <fields-csv>
#
# Spec §3.1 [W1b]. `FIELDS_CSV ⊆ title,body,state,labels,comments`.
# GitLab field renames: `description` → `body`; `state` `opened|closed` →
# `OPEN|CLOSED` (uppercase — matches the §3.1 tokens `_next_action` consumes).
# Labels already name-strings in GitLab (no `.[].name` unwrap).
# Fail-CLOSED capture-then-check on `_gl_api` rc≠0 or empty stdout.
itp_gitlab_read_task() {
  local issue="$1" fields_csv="$2" raw comments_json='[]'
  raw=$(_gl_api "/projects/${GITLAB_PROJECT}/issues/${issue}") || return 1
  [[ -n "$raw" ]] || return 1
  case ",${fields_csv}," in
    *,comments,*)
      comments_json=$(itp_gitlab_list_comments "$issue") || return 1
      [[ -n "$comments_json" ]] || return 1
      ;;
  esac
  jq --argjson comments "$comments_json" '
    {
      title: (.title // ""),
      body:  (.description // ""),
      state: (
        if   (.state == "opened") then "OPEN"
        elif (.state == "closed") then "CLOSED"
        else "" end
      ),
      labels: (.labels // []),
      comments: $comments
    }
  ' <<<"$raw" | _itp_gitlab_project_fields_object "$fields_csv"
}

# itp_gitlab_post_comment <issue> <body>
#
# Spec §3.1 [M6]. Post a note under the issue. Marker channel is HTML
# (`marker_channel=html` per itp-gitlab.caps) — GitLab markdown preserves
# HTML comments verbatim (spec §5.1 evidence). The BODY is passed as a jq
# --arg (no interpolation, no shell metachar footgun).
itp_gitlab_post_comment() {
  local issue="$1" body="$2" req_body
  req_body=$(jq -c -n --arg b "$body" '{body:$b}')
  _gl_api --method POST --body "$req_body" "/projects/${GITLAB_PROJECT}/issues/${issue}/notes"
}

# itp_gitlab_edit_comment <issue> <comment_id> <body>
#
# Spec §3.1 [M5]. `PUT /projects/:id/issues/:iid/notes/:note_id`. GitLab
# `edit_comment=1`. Byte-parity with the [INV-46] SHA-stamp caller — no
# fallback branch fires.
itp_gitlab_edit_comment() {
  local issue="$1" comment_id="$2" body="$3" req_body
  req_body=$(jq -c -n --arg b "$body" '{body:$b}')
  _gl_api --method PUT --body "$req_body" "/projects/${GITLAB_PROJECT}/issues/${issue}/notes/${comment_id}"
}

# itp_gitlab_list_comments <issue>
#
# Spec §3.3 [INV-90]. Return the normalized ISSUE-level notes array:
# `[{id, author, authorKind, body, createdAt}]`, ascending by `createdAt`
# with `id` tie-break (stable).
#
# GitLab specifics:
#   - **System notes are FILTERED OUT** — `.system == true` is a state-change
#     event, not a comment. Including them would poison the `| last` verdict
#     read (#321) with label-flip events. Matches CHP-side and Asana-side
#     discipline (spec §3.3).
#   - `id` = GitLab's native numeric note id (consumed only by this same
#     provider's `itp_gitlab_edit_comment` — no cross-provider semantics,
#     mirrors the itp-github.sh comment id choice).
#   - `author` = `.author.username` (spec §3.3 [M5] pin).
#   - `authorKind` derivation:
#       - `self` iff `author == BOT_LOGIN` (raw match — GitLab bot logins
#         don't carry a `[bot]` suffix like GitHub, so no stripped-form fold).
#       - `bot` iff username matches `^(project|group)_\d+_bot(_[a-z0-9]+)?$`
#         (GitLab's Project / Group Access Token convention). This is the
#         `distinct_bot_author=1` claim in caps — a personal-PAT deployment
#         degrades this to convention (documented in the .caps caveat).
#       - `human` otherwise.
#   - `body` = `.body // ""`. `createdAt` = `.created_at`.
itp_gitlab_list_comments() {
  local issue="$1" raw
  # Fail-CLOSED capture-then-check (spec §3.5 discipline, matches
  # itp_read_task's posture): a bare `_gl_api … | jq …` pipe under
  # pipefail catches an _gl_api non-zero rc, but rc-0 with EMPTY stdout
  # (transport oddity, stub drift) would let jq iterate zero elements and
  # emit `[]` — a real "no comments" and a silent failure become
  # indistinguishable. Callers of list_comments (`_fetch_agent_verdict_body`
  # #321, [INV-105] marker breaker, INV-46 SHA-stamp lookup) test for
  # empty-array to mean "no matching bot comment yet" — a fail-OPEN empty
  # array would misdrive the verdict / marker / stamp paths silently. So
  # capture, check rc, check non-empty, then jq.
  raw=$(_gl_api --paginate "/projects/${GITLAB_PROJECT}/issues/${issue}/notes?sort=asc&order_by=created_at") || return 1
  [[ -n "$raw" ]] || return 1
  # Reject rc-0 non-array shapes (matches the W1c2 online-review r2
  # discipline on the CHP side): a `{}` or `{"message":"..."}` payload from
  # a transport-hook oddity would slip past jq's `.[]` with a hard error
  # under set -e, but the graceful pattern is to fail-CLOSED loud here.
  printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$raw" | jq --arg bot "${BOT_LOGIN:-}" '
        [ .[]
          | select((.system // false) == false)
          | (.author.username // "") as $a
          | { id: (.id // null),
              author: (if $a == "" then null else $a end),
              authorKind: (
                if   ($a != "" and $bot != "" and $a == $bot) then "self"
                elif ($a | test("^(project|group)_[0-9]+_bot(_[a-z0-9]+)?$")) then "bot"
                else "human"
                end
              ),
              body: (.body // ""),
              createdAt: (.created_at // null) }
        ] | sort_by(.createdAt // "", .id // 0)
      '
}

# itp_gitlab_resolve_dep <owner-repo> <num> <out-var>
#
# Spec §3.1 / [INV-83]. Cross-project dependency lookup. Signature per spec:
# OWNER_REPO and NUM are SEPARATE args (caller has split the `owner/repo#N`
# shorthand — the leaf does NOT parse `#`). OWNER_REPO is a project path,
# possibly slash-bearing (`group/subgroup/project`); it is URL-encoded via
# `_gl_urlencode` before insertion into the path. GitLab `state` maps
# `opened`→`OPEN`, `closed`→`CLOSED`.
#
# FAIL-SOFT: empty out-var on any lookup failure (spec §3.1 documents this
# verb as fail-SOFT; caller fail-safe-blocks).
#
# **[INV-83] simplification**: GitLab's PAT/Project/Group Access Token spans
# ALL accessible projects in a single credential — there is no per-project
# mint like the GitHub App scoped-token dance. So there is no
# `_DEP_TOKEN_CACHE` and no `_gl_app_token`-equivalent. `itp_gitlab_begin_tick`
# accordingly stays as a no-op (see below).
itp_gitlab_resolve_dep() {
  local owner_repo="$1" num="$2" out_var="$3"
  # Locals are `_`-prefixed (matching itp_github_resolve_dep's `_state`
  # convention) so none of them can collide with whatever name the caller
  # passes as `out_var` — production callers pass the literal `"state"`
  # (lib-dispatch.sh's check_deps_resolved), and `printf -v "$out_var"`
  # resolves by name in THIS scope, so an unprefixed `local state` here
  # would shadow the caller's variable and the write would never reach it.
  local _encoded _raw _state _resolved=""
  # _gl_urlencode is defined by lib-gitlab-transport.sh (or the unit test's
  # local stub). Guard on its presence so the leaf fails soft (empty
  # out-var, rc 0) rather than aborting under set -e if the transport lib
  # isn't sourced yet on some ad-hoc invocation path.
  if declare -F _gl_urlencode >/dev/null 2>&1; then
    _encoded=$(_gl_urlencode "$owner_repo" 2>/dev/null) || _encoded=""
  else
    _encoded=""
  fi
  if [[ -n "$_encoded" ]]; then
    _raw=$(_gl_api "/projects/${_encoded}/issues/${num}" 2>/dev/null) || _raw=""
    if [[ -n "$_raw" ]]; then
      _state=$(printf '%s' "$_raw" | jq -r '.state // ""' 2>/dev/null) || _state=""
      _resolved=$(_itp_gitlab_normalize_state "$_state")
    fi
  fi
  printf -v "$out_var" '%s' "$_resolved"
}

# itp_gitlab_mark_checkbox <issue> <new-body>
#
# Spec §3.1 (`body_checkbox=1`). GitLab renders markdown checkboxes in
# descriptions identically to GitHub — the leaf is a body PUT with the
# pre-rewritten NEW_BODY. Caller (mark-issue-checkbox.sh) still owns the GET
# / rewrite / exit-code taxonomy (spec §3.1 [W1b] mirror).
itp_gitlab_mark_checkbox() {
  local issue="$1" new_body="$2" req_body
  req_body=$(jq -c -n --arg d "$new_body" '{description:$d}')
  _gl_api --method PUT --body "$req_body" "/projects/${GITLAB_PROJECT}/issues/${issue}"
}

# itp_gitlab_provision_states <name> <color> <description>
#
# Spec §3.1 (`label_colors=1`). Idempotent probe-or-create using the P3-1
# status channel:
#   1. Probe `_gl_api --tolerate-status 404 /projects/:id/labels/<enc(name)>`.
#      `GL_API_STATUS=200` → `[skip]`, done. `GL_API_STATUS=404` → step 2.
#   2. Create `_gl_api --method POST --tolerate-status 409` on `/labels`.
#      `GL_API_STATUS=409` (concurrent-provisioner race) → downgrade to
#      `[skip]`, leaf rc 0. Any other rc≠0 → propagate.
#
# The status channel discipline is load-bearing here: the leaf MUST NOT wrap
# `_gl_api` in `$( … )` capture (would nuke GL_API_STATUS via subshell). Uses
# `--status-out FILE` on the second call to keep the status observable
# despite the stdout being captured (spec §3.1 [status-out] note, #416).
itp_gitlab_provision_states() {
  local name="$1" color="$2" description="$3"
  local encoded status_file req_body
  # Color-format normalization: the pipeline's `setup-labels.sh` caller
  # passes a 6-hex color WITHOUT the `#` sigil (`0E8A16`, `D93F0B`, …) —
  # byte-identical to what `gh label create --color` accepts. GitLab's
  # `/labels` API requires the `#`-prefixed CSS form (`#0E8A16`); posting
  # the bare hex yields HTTP 400 with `color is invalid`. Normalize IN-LEAF
  # so callers stay provider-neutral (they emit ONE color string, we adapt
  # it per provider). Only prefix a bare 6-hex; passthrough anything else
  # (already-prefixed, CSS names) so a caller that has already conformed to
  # GitLab's shape isn't mangled.
  if [[ "$color" =~ ^[0-9A-Fa-f]{6}$ ]]; then
    color="#${color}"
  fi
  encoded=$(_gl_urlencode "$name") || return 1
  # Probe. GL_API_STATUS lands in the caller's shell because we invoke via
  # redirect (`>/dev/null`), not command substitution.
  _gl_api --tolerate-status 404 "/projects/${GITLAB_PROJECT}/labels/${encoded}" >/dev/null || return 1
  if [[ "${GL_API_STATUS:-}" == "200" ]]; then
    echo "  [skip] '$name' already exists"
    return 0
  fi
  # Create. Use --status-out to survive the (unused) stdout capture and
  # inspect the tolerated-409 arm.
  status_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$status_file'" RETURN
  req_body=$(jq -c -n --arg n "$name" --arg c "$color" --arg d "$description" \
    '{name:$n, color:$c, description:$d}')
  _gl_api --method POST --tolerate-status 409 --body "$req_body" \
    --status-out "$status_file" "/projects/${GITLAB_PROJECT}/labels" >/dev/null || {
      # Any non-tolerated rc≠0 → fail. Self-disarm the RETURN trap
      # (spec §3.1 chp_commit_file [INV-99] pattern) so the parent shell's
      # RETURN trap isn't clobbered on the shim-level return.
      trap - RETURN
      rm -f "$status_file"
      return 1
    }
  local final_status
  final_status=$(cat "$status_file" 2>/dev/null || true)
  trap - RETURN
  rm -f "$status_file"
  if [[ "$final_status" == "409" ]]; then
    # Concurrent-provisioner race — another dispatcher created the label
    # between our probe and our POST. Downgrade to [skip].
    echo "  [skip] '$name' already exists"
    return 0
  fi
  echo "  [created] '$name'"
}

# itp_gitlab_label_event_ts <issue> <label>
#
# Spec §3.1 [m] / [INV-93] / #323. Emit the ISO-8601 UTC `created_at` of the
# FIRST `labeled` event for LABEL, or empty if none / on failure.
# GitLab endpoint: `GET /projects/:id/issues/:iid/resource_label_events` —
# paginated (the endpoint doesn't accept a label filter, so the label match
# runs in-leaf via jq).
#
# INJECTION-SAFE label binding: LABEL is passed via `jq --arg lbl`. **The
# `gh api` jq-binding caveats do NOT apply here** — this leaf runs a LOCAL
# jq process (over `_gl_api`'s stdout), so it fully controls the jq
# invocation and CAN pass --arg cleanly. This is a deliberate divergence
# from the GitHub leaf's pre-encode-to-json-literal dance (which existed
# because `gh api --jq` doesn't forward --arg).
#
# Fail-SOFT per contract: any `_gl_api` failure or empty response → empty
# stdout, leaf rc 0.
itp_gitlab_label_event_ts() {
  local issue="$1" label="$2"
  _gl_api --paginate "/projects/${GITLAB_PROJECT}/issues/${issue}/resource_label_events" 2>/dev/null \
    | jq -r --arg lbl "$label" '
        map(select(.action == "add" and .label.name == $lbl))
        | sort_by(.created_at // "")
        | (.[0].created_at // "")
      ' 2>/dev/null || printf ''
}

# itp_gitlab_begin_tick
#
# Spec §3.6. Documented no-op: GitLab's single-token cross-project auth
# removes the [INV-83] `_DEP_TOKEN_CACHE` reason. The verb still exists so
# the dispatcher's `itp_begin_tick` shim always resolves and a future
# GitLab-scoped cache slots in without a spec revision.
itp_gitlab_begin_tick() {
  return 0
}
