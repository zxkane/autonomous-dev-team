#!/bin/bash
# providers/itp-github.sh — GitHub Issue-Tracker Provider (ITP) reference impl.
#
# Establishes the provider-prefix convention (#280) and migrates the ITP READ
# leaves (#281), the WRITE leaves (#283), the dependency-resolution +
# tick-lifecycle leaves (#284, [INV-83]), and the W1a abstract state-read
# contracts (#371, #347 phase-2). Each ITP verb's GitHub leaf is a function
# named itp_github_<verb>; lib-issue-provider.sh's `itp_<verb>` shim forwards
# "$@" to it when ISSUE_PROVIDER=github (the default), per the
# verb↔current-function mapping appendix in docs/pipeline/provider-spec.md.
#
# CONVENTION (so the downstream migrations slot in mechanically):
#   - Each ITP verb's GitHub leaf is a function named  itp_github_<verb>.
#   - lib-issue-provider.sh's `itp_<verb>` shim forwards "$@" to it when
#     ISSUE_PROVIDER=github (the default). A verb not defined here yet makes
#     `declare -F itp_github_<verb>` return non-zero until its migration lands.
#   - The GitHub `.caps` manifest beside this file (itp-github.caps) declares
#     exactly today's GitHub behavior — the no-behavior-change anchor ([INV-88]).
#
# PRECONDITION: sourced by lib-issue-provider.sh from the REAL skill tree
# (readlink -f of that lib's BASH_SOURCE). `$REPO` (and, for the comment
# authorKind discriminator, `$BOT_LOGIN`) are in scope from the caller's
# environment (lib-dispatch.sh's required env).
#
# 14 ITP verbs (spec §3.1):
#   itp_github_list_by_state       itp_github_count_by_state        [#371 W1a]
#   itp_github_list_forbidden_combos                                [#371 W1a]
#   itp_github_read_task           itp_github_list_comments         [#281 READ]
#   itp_github_transition_state    itp_github_post_comment          [itp-writes]
#   itp_github_edit_comment        itp_github_mark_checkbox         [itp-writes]
#   itp_github_provision_states                                     [itp-writes]
#   itp_github_resolve_dep         itp_github_begin_tick            [#284 DEP]
#   itp_github_label_event_ts                                       [#323 OBSERVE]
# (itp_caps reads the .caps manifest in the dispatcher, not a function here.)

# ---------------------------------------------------------------------------
# W1a abstract state-read contracts (#371, #347 phase-2). Unlike the other ITP
# leaves in this file (byte-identical gh-argv pass-throughs, #281), these three
# verbs are a deliberate SHAPE change: NO gh flags and NO jq programs cross the
# seam (docs/pipeline/provider-spec.md §3.1). The caller passes abstract
# filters (state, label-AND set, limit, field set); this leaf owns the
# `--state/--label/--limit/--json` mapping AND the normalization jq. Caller-side
# predicates (the [INV-25] terminal-state subtraction, negation) are re-derived
# by the caller by filtering the returned NORMALIZED array — see
# lib-dispatch.sh's list_* selectors.
# ---------------------------------------------------------------------------

# _itp_github_state_read <state> <labels-and-csv> <limit> — internal helper
# shared by list_by_state/count_by_state/list_forbidden_combos: runs the
# server-side state+label-AND+limit enumeration and normalizes to the full
# {number, title, labels, comments} shape (comments per [INV-90]/§3.3), sorted
# ascending by number. <labels-and-csv> empty → no --label flag. Fail-closed:
# a `gh` failure propagates its non-zero rc with no partial stdout (no `|| true`
# anywhere in this chain).
# [#393] state-read comments' authorKind is GraphQL-DERIVED and therefore
# CANNOT distinguish App bots (GraphQL strips the `[bot]` suffix and exposes
# no author type): an App-authored comment reports authorKind="human" here.
# This field MUST NOT be used for authenticity gates — the authoritative
# per-issue read is `itp_list_comments` (REST-sourced, correct authorKind).
# Kept GraphQL deliberately: a REST comments call PER ISSUE in the bulk
# state-read would multiply tick API cost; no shipped caller consumes this
# field today (list_pending_dev requests `comments` but the tick reads only
# `.number`). The `self` arm tolerates BOT_LOGIN in raw or stripped form.
_itp_github_state_read() {
  local state="$1" labels_csv="$2" limit="$3"
  local -a args=(issue list --repo "$REPO" --state "$state" --limit "$limit")
  [[ -n "$labels_csv" ]] && args+=(--label "$labels_csv")
  args+=(--json number,title,labels,comments)
  gh "${args[@]}" | jq --arg bot "${BOT_LOGIN:-}" '
    [ .[] | {
        number: .number,
        title: (.title // ""),
        labels: [ (.labels // [])[].name ],
        comments: [ (.comments // [])[]
          | { id: ( ( (.url // "") | capture("issuecomment-(?<n>[0-9]+)$") | .n | tonumber ) // null ),
              author: (.author.login // null),
              authorKind: ( (.author.login // "") as $a
                            | ($bot | sub("\\[bot\\]$"; "")) as $bstripped
                            | if ($a != "" and $bot != "" and ($a == $bot or $a == $bstripped)) then "self"
                              elif ($a | endswith("[bot]")) then "bot"
                              else "human" end ),
              body: (.body // ""),
              createdAt: (.createdAt // null) }
          ] | sort_by(.createdAt // "")
      }
    ] | sort_by(.number)
  '
}

# _itp_github_project_fields <fields-csv> — internal helper: reads the full
# normalized array on stdin and projects down to EXACTLY the requested fields
# (spec R1). <fields-csv> ⊆ number,title,labels,comments.
_itp_github_project_fields() {
  local fields_csv="$1" fields_json
  fields_json=$(printf '%s' "$fields_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  jq --argjson fields "$fields_json" 'map(. as $o | ($fields | map({(.): $o[.]}) | add // {}))'
}

# itp_github_list_by_state <state> <labels-and-csv> <limit> <fields-csv> —
# abstract state-filtered issue enumeration leaf (spec §3.1, R1).
#
# <state> ∈ open|closed|all. <labels-and-csv> comma-separated label names,
# AND semantics (gh's own --label comma behavior), empty = no filter.
# <limit> applied SERVER-SIDE (gh --limit) before any caller-side subtraction.
# <fields-csv> ⊆ number,title,labels,comments. No matches → `[]`.
itp_github_list_by_state() {
  local state="$1" labels_csv="$2" limit="$3" fields_csv="$4"
  _itp_github_state_read "$state" "$labels_csv" "$limit" | _itp_github_project_fields "$fields_csv"
}

# itp_github_count_by_state <state> <labels-and-csv> <limit> <any-of-labels-csv>
# — server-side COUNT leaf (spec §3.1 [M3]; bare non-negative INTEGER).
#
# Same enumeration point as list_by_state; the RETURN is the count of matches
# that additionally carry AT LEAST ONE label from <any-of-labels-csv> (empty
# any-of = count all AND-matches). Distinct verb because count_active returns
# an int the dispatcher compares numerically — enumerate+count would lose the
# server-side count semantics and could silently change failure behavior.
itp_github_count_by_state() {
  local state="$1" labels_csv="$2" limit="$3" any_of_csv="$4" any_of_json
  any_of_json=$(printf '%s' "$any_of_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  _itp_github_state_read "$state" "$labels_csv" "$limit" | jq --argjson anyof "$any_of_json" '
    [ .[] | select(
        ($anyof | length) == 0
        or ( .labels as $ls | $anyof | any(. as $a | $ls | index($a) != null) )
      )
    ] | length
  '
}

# itp_github_list_forbidden_combos <state> <labels-and-csv> <limit> —
# [INV-25] forbidden-label-combination leaf (spec §3.1 [M3]).
#
# The LEAF owns the combo filter (server-side-optimizable for providers with
# query languages): terminal set = {approved, stalled}; transitional set =
# {in-progress, reviewing, pending-review, pending-dev}; forbidden = terminal
# AND transitional (per [INV-25]). Returns the normalized array shape with
# fields number,labels, already filtered to the forbidden combos — the caller
# (list_hygiene_residue) is a thin pass-through.
itp_github_list_forbidden_combos() {
  local state="$1" labels_csv="$2" limit="$3"
  _itp_github_state_read "$state" "$labels_csv" "$limit" | jq '
    [ .[] | select(
        (.labels | any(. == "approved" or . == "stalled"))
        and
        (.labels | any(. == "in-progress" or . == "reviewing" or . == "pending-review" or . == "pending-dev"))
      ) | {number, labels}
    ]
  '
}

# itp_github_read_task ISSUE FIELDS_CSV — single-task ABSTRACT field read
# ([W1b], #396, #347 phase-2).
#
# Spec §3.1: FIELDS_CSV ⊆ title,body,state,labels,comments. Returns a single
# JSON object with EXACTLY the requested fields, normalized: title/body as
# strings (absent body → ""), state passed through as GitHub's own OPEN/CLOSED
# token (already the provider-neutral vocabulary — deliberate, so status.sh's
# `_next_action` gate ships byte-unchanged), labels as an array of NAME
# strings (not `{name}` objects), comments as the [INV-90] normalized array.
# No gh flags / jq programs cross the seam — this leaf owns the `--json` field
# mapping AND the normalization jq internally (unlike the pre-#396
# byte-identical passthrough this replaces). Fail-closed: a `gh` failure or
# malformed JSON propagates non-zero with no partial stdout.
# [#393] like `_itp_github_state_read`, this leaf's `comments` field is
# GraphQL-derived and therefore CANNOT distinguish App bots (GraphQL strips
# the `[bot]` suffix and exposes no author type) — an App-authored comment
# reports authorKind="human" here. No shipped caller of this verb consumes
# `comments` for an authenticity gate (the two callers requesting it embed the
# object as agent-prompt context); the authoritative per-issue read for that
# purpose remains `itp_list_comments` (REST-sourced, correct authorKind).
itp_github_read_task() {
  local issue="$1" fields_csv="$2" fields_json
  fields_json=$(printf '%s' "$fields_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  gh issue view "$issue" --repo "$REPO" --json title,body,state,labels,comments \
    | jq --arg bot "${BOT_LOGIN:-}" --argjson fields "$fields_json" '
        {
          title: (.title // ""),
          body: (.body // ""),
          state: (.state // ""),
          labels: [ (.labels // [])[].name ],
          comments: [ (.comments // [])[]
            | { id: ( ( (.url // "") | capture("issuecomment-(?<n>[0-9]+)$") | .n | tonumber ) // null ),
                author: (.author.login // null),
                authorKind: ( (.author.login // "") as $a
                              | ($bot | sub("\\[bot\\]$"; "")) as $bstripped
                              | if ($a != "" and $bot != "" and ($a == $bot or $a == $bstripped)) then "self"
                                elif ($a | endswith("[bot]")) then "bot"
                                else "human" end ),
                body: (.body // ""),
                createdAt: (.createdAt // null) }
            ] | sort_by(.createdAt // "")
        } as $norm
        | ($fields | map({(.): $norm[.]}) | add // {})
      '
}

# itp_github_list_comments ISSUE — the normalized comment array ([INV-90],
# spec §3.3): [{id, author, authorKind, body, createdAt}] sorted ascending by
# createdAt (id tie-break). [#393] REST-sourced (see the in-function comment):
# `gh api --paginate --slurp repos/<repo>/issues/N/comments` — user.type drives
# authorKind, user.login is VERBATIM incl [bot], id is REST's numeric .id.
# §3.5 complete set via --paginate; --slurp wraps pages, .[][] flattens.
itp_github_list_comments() {
  local issue="$1"
  # [#393] REST, not GraphQL: `gh issue view --json comments` (GraphQL) STRIPS
  # the `[bot]` suffix from App logins and exposes no author type, so the
  # authorKind derivation classified every App-authored comment as "human" —
  # inert-ing the #390 app-mode verdict gate and the INV-105 marker
  # authenticity check (the 5th BOT_LOGIN-empty-class bug). REST exposes
  # `user.type == "Bot"` (authoritative, no login sniffing) and the VERBATIM
  # `user.login` incl `[bot]` — which is what spec §3.3 [M5] required all
  # along ("user.login including the [bot] suffix verbatim"); the GraphQL
  # leaf silently violated that contract, and per Pipeline Documentation
  # Authority the spec wins. `id` is REST's numeric .id (the URL-capture
  # hack retires). §3.5 complete set: `--paginate --slurp` wraps each page
  # in an outer array (a plain --paginate would emit concatenated top-level
  # arrays jq reads as separate documents); `.[][]` flattens. `self`
  # tolerates BOT_LOGIN in raw or `[bot]`-stripped form (a stripped-form
  # BOT_LOGIN from a GraphQL-era resolver still matches).
  gh api --paginate --slurp "repos/${REPO}/issues/${issue}/comments" | jq "
    [ .[][]
      | { id: (.id // null),
          author: (.user.login // null),
          authorKind: ( (.user.login // \"\") as \$a
                        | ( \$a | sub(\"\\\\[bot\\\\]\$\"; \"\") ) as \$stripped
                        | if (\$a != \"\" and \"${BOT_LOGIN:-}\" != \"\" and (\$a == \"${BOT_LOGIN:-}\" or \$stripped == \"${BOT_LOGIN:-}\")) then \"self\"
                          elif ((.user.type // \"\") == \"Bot\") then \"bot\"
                          else \"human\" end ),
          body: (.body // \"\"),
          createdAt: (.created_at // null) }
    ] | sort_by(.createdAt // \"\", .id // 0)
  "
}

# ===========================================================================
# WRITE leaves (#283). Each is the byte-identical innermost `gh` I/O the caller
# emitted before the verb existed — the no-behavior-change golden-trace anchor
# (spec §7.3, [INV-87]). ALL INV-coupled logic (marker text, retry, dedup,
# idempotency, terminal-state jq subtraction, fail-closed rc) stays CALLER-side;
# only the leaf moves here. See the verb↔current-function mapping appendix in
# docs/pipeline/provider-spec.md.
# ===========================================================================

# itp_github_transition_state ISSUE REMOVE ADD — atomic label state move.
#
# Spec §3.1: remove REMOVE, add ADD in ONE `gh issue edit` (atomic per [INV-08]).
# Moves the leaf out of `label_swap` (lib-dispatch.sh) byte-identically.
#
# CSV multi-label ([INV-97], #331): REMOVE and ADD are each ONE label OR a
# comma-separated LIST of labels. A single label is a CSV of length 1, so every
# existing 3-positional single-label caller emits BYTE-IDENTICAL argv (exactly one
# `--remove-label`/`--add-label`). A CSV emits one flag per NON-EMPTY member, in
# order; an empty member is dropped; an empty side omits its flag entirely
# (preserving the `[ -n ]` empty-side guards the original single-label leaf used).
# This expresses the multi-`--remove-label` Part-A flips (e.g.
# "in-progress,pending-dev" → two removes) the prior single-remove leaf could not,
# keeping them ATOMIC (one edit, [INV-08]) rather than splitting into a remove-only
# verb + a separate add.
#
# Precondition (spec §3.1): the comma IS the member separator — a label NAME that
# itself contains a comma is unsupported via this path (it would split). Inert for
# the pipeline (every label is comma-free; hygiene_strip's CSV is built from a
# hardcoded comma-free jq allowlist), but documented as a provider-portability
# boundary. The split is a pure `IFS=,` shell op on caller-controlled label names
# fed to `--remove-label`/`--add-label` argv (NOT a jq pattern) — no injection.
#
# The terminal-state jq subtraction in list_pending_review/list_pending_dev
# ([INV-25] defense-in-depth) is NOT this leaf's concern — it stays caller-side.
itp_github_transition_state() {
  local issue_num="$1" remove="$2" add="$3"
  local args=() _csv=() _m
  IFS=',' read -ra _csv <<<"$remove"
  for _m in "${_csv[@]}"; do [ -n "$_m" ] && args+=(--remove-label "$_m"); done
  IFS=',' read -ra _csv <<<"$add"
  for _m in "${_csv[@]}"; do [ -n "$_m" ] && args+=(--add-label "$_m"); done
  gh issue edit "$issue_num" --repo "$REPO" "${args[@]}"
}

# itp_github_post_comment ISSUE BODY — post a machine-marker / progress comment.
#
# Spec §3.1 [M6] / [INV-89]: the SINGLE choke-point for ALL machine markers —
# agent progress/verdict comments AND the dispatcher's own markers
# (post_dispatch_token [INV-18], _dep_block_comment [INV-39]). The BODY (incl. the
# verbatim `<!-- dispatcher-token: … -->` / `<!-- dep-block:… -->` HTML markers)
# is composed CALLER-side and passed through unmodified — GitHub's
# marker_channel=html round-trips HTML comments verbatim (a marker_channel=text
# provider would post via a non-sanitizing plain field instead). The caller owns
# the `2>/dev/null || true` fail-safe / retry-`&&` framing; this leaf is the bare
# byte-identical `gh issue comment` emit.
itp_github_post_comment() {
  local issue_num="$1" body="$2"
  gh issue comment "$issue_num" --repo "$REPO" --body "$body"
}

# itp_github_edit_comment ISSUE COMMENT_ID BODY — edit a comment in place.
#
# Spec §3.1 [M5] / [INV-46]: the SHA evidence-marker PATCH leaf
# (lib-review-e2e.sh). GitHub has comment edit-in-place (`edit_comment=1`), so the
# byte-identical leaf is `gh api -X PATCH …/issues/comments/<id> -f body=<body>`.
# The path is the ISSUE/PR-comments REST endpoint (PR comments are issue comments
# for this endpoint); it uses $REPO_OWNER/$REPO_NAME (the caller's env, matching
# the pre-refactor call exactly). The GET-comment-id / GET-body READ leaves and
# the idempotent SHA-already-present skip stay caller-side (itp-reads + caller).
# A backend without edit (`edit_comment=0`) is handled by the CALLER falling back
# to re-posting the FULL report body + marker as a fresh comment via
# itp_post_comment (never marker-only — _fetch_sha_evidence returns the comment's
# full body to the E2E gate) — not in this leaf.
itp_github_edit_comment() {
  local _issue="$1" comment_id="$2" body="$3"
  gh api -X PATCH "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${comment_id}" \
    -f body="$body"
}

# itp_github_mark_checkbox ISSUE NEW_BODY — persist a task-body checkbox tick.
#
# Spec §3.1 (`body_checkbox`): GitHub ticks a markdown body checkbox, so the leaf
# is the byte-identical body PATCH `gh api repos/$REPO/issues/<n> --method PATCH
# --field body=<new_body> --silent`. The caller (mark-issue-checkbox.sh) owns the
# GET-body fetch, the `- [ ]`→`- [x]` awk rewrite, and the not-found / already-
# checked exit codes (0/1/2) — only the PATCH primitive moves here, receiving the
# already-rewritten body. A `body_checkbox=0` backend remaps to a native-subtask
# completion in the caller (defined; not implemented this PR).
itp_github_mark_checkbox() {
  local issue_num="$1" new_body="$2"
  gh api "repos/${REPO}/issues/${issue_num}" \
    --method PATCH \
    --field body="$new_body" \
    --silent
}

# itp_github_provision_states NAME COLOR DESCRIPTION — provision one state primitive.
#
# Spec §3.1 [m5] (`label_colors`): GitHub state primitives are labels, so the leaf
# is the idempotent per-label probe-or-create (REST existence probe `gh api
# repos/<repo>/labels/<name> --silent`; else `gh label create --color <hex>
# --description <d>`). [#362] `gh label` has no `view` subcommand (only
# clone/create/delete/edit/list) — the prior existence check (`gh label` +
# `view`) always failed, so the function always fell through to `gh label
# create`, which itself aborts under set -e when the label already exists. The
# REST probe is the fix; it is NOT byte-identical to any pre-existing `gh` argv
# (the check itself was always broken), only the create-branch argv stays
# byte-identical to setup-labels.sh's original loop body. No URL-encoding
# needed: all 9 pipeline label names are URL-safe (`[a-z-]`). The 9-label
# definition table stays caller-side.
# `label_colors=1` (GitHub) → the `--color` hex is emitted; a `label_colors=0`
# backend omits `--color` (defined; not live this PR). Echoes the same
# `[skip]`/`[created]` lines the caller printed before, so console output is
# unchanged.
itp_github_provision_states() {
  local name="$1" color="$2" description="$3"
  if gh api "repos/${REPO}/labels/${name}" --silent &>/dev/null; then
    echo "  [skip] '$name' already exists"
  else
    gh label create "$name" --repo "$REPO" \
      --color "$color" \
      --description "$description"
    echo "  [created] '$name'"
  fi
}

# ===========================================================================
# DEPENDENCY-RESOLUTION + TICK-LIFECYCLE leaves (#284, [INV-83]). The cross-repo
# dependency state lookup + the per-dep-repo scoped-token mint + the tick-scoped
# `_DEP_TOKEN_CACHE` are GitHub-internal concerns and live HERE, behind the
# itp_resolve_dep / itp_begin_tick verbs. The `## Dependencies` body parse, the
# [INV-11] CLOSED/MERGED predicate, the fail-safe block decision, and the
# `_dep_block_comment` call all stay CALLER-side in lib-dispatch.sh's
# check_deps_resolved (spec §3.6, the verb↔current-function mapping appendix).
# ===========================================================================

# [INV-83] Permissions object for the per-dep-repo cross-repo lookup token.
# Read-only issue state is all the dependency check needs. `metadata` is NOT
# requested — it is implicit for GitHub App installation tokens and the
# `POST /app/installations/{id}/access_tokens` exchange returns HTTP 422 if it
# is named explicitly. Per the issue #269 locked decision (cross-model review),
# the empirical contract is: `{"issues":"read"}` → HTTP 200 + a token that reads
# issue state; `{"issues":"read","metadata":"read"}` → HTTP 422. The one live
# mint against api.github.com confirming this is an OPERATOR pre-merge step
# (#269 T8) — it is not run from inside a wrapper (no live credential mint here).
# Operator-overridable via DEP_LOOKUP_PERMISSIONS if a future App grant differs.
# (Default assigned in two steps so the JSON value stays literal — embedding it
# inside a `${VAR:-...}` default would let the inner quotes be taken literally.)
_DEP_LOOKUP_PERMISSIONS_DEFAULT='{"issues":"read"}'
DEP_LOOKUP_PERMISSIONS="${DEP_LOOKUP_PERMISSIONS:-$_DEP_LOOKUP_PERMISSIONS_DEFAULT}"

# [INV-83] Cross-repo dependency lookup-token cache, keyed by `owner/repo`.
# TICK-SCOPED (AC #2): deduplicates every dep on the same external repo to a
# SINGLE mint across ALL issues processed in one dispatcher tick — not per-issue.
# A failed mint is cached negatively (empty string) so a doomed repo is not
# re-minted for every ref. Lives at module scope (the GitHub ITP provider is
# sourced once by lib-issue-provider.sh, itself sourced once per dispatcher
# process), so the cache naturally persists across the tick's multiple
# check_deps_resolved calls (and across the per-ref itp_github_resolve_dep calls
# within each, which run in the CALLER's shell — see the out-var note below). It
# is cleared ONLY at the tick boundary by itp_github_begin_tick (dispatcher-tick.sh
# calls itp_begin_tick once, before Step 2). In PAT mode the mint branch is never
# entered, so the cache stays empty — no dep-lookup token can leak into PAT mode;
# the per-tick fresh process (cron) plus the explicit boundary reset prevent any
# cross-tick leak.
declare -A _DEP_TOKEN_CACHE 2>/dev/null || true

# itp_github_begin_tick — [INV-83] tick-lifecycle hook (spec §3.6). Clears the
# cross-repo lookup-token cache at the TICK boundary. dispatcher-tick.sh calls
# itp_begin_tick once per tick (before Step 2 scan-new) so the cache starts each
# tick clean; the multi-project tick runs each project in its own subshell, so a
# fresh subshell already gives per-project isolation, and this boundary reset
# covers the rare reused-shell case (e.g. a long-lived dispatcher process or test
# harness) without sacrificing the within-tick cross-issue dedup ([INV-83],
# #269 AC #2/T4). This is the new home of the body previously in lib-dispatch.sh's
# `_reset_dep_token_cache`.
itp_github_begin_tick() {
  unset _DEP_TOKEN_CACHE
  declare -gA _DEP_TOKEN_CACHE 2>/dev/null || true
}

# itp_github_resolve_dep <owner/repo> <num> <out_var> — [INV-83] cross-repo aware
# state lookup. The GitHub leaf behind the itp_resolve_dep verb (spec §3.1/§3.6).
#
# Writes the dependency's GitHub state (OPEN / CLOSED / MERGED) into the named
# out-var (3rd arg), or empty on lookup failure (404 / transport error / App not
# installed). Always returns 0 — the caller fail-safe-blocks on an empty value.
#
# An OUT-VAR (not stdout) is used deliberately: the token mint mutates the
# module-level _DEP_TOKEN_CACHE, and that write MUST happen in the caller's shell
# so the cache survives across the multiple refs in one `check_deps_resolved`
# call. If this echoed and the caller captured via `state=$(...)`, the whole body
# — including the cache write — would run in a command-substitution subshell and
# the dedup cache would reset on every ref (re-minting per ref). `printf -v` keeps
# it in-shell. The full caller→shim→provider chain (resolve_dep_state →
# itp_resolve_dep → itp_github_resolve_dep) is out-var all the way down, so no
# link introduces a subshell.
#
# Token routing (the #269 fix):
#   - In app mode (GH_AUTH_MODE=app with both DISPATCHER_APP_ID and
#     DISPATCHER_APP_PEM set) for a CROSS-repo dep (owner_repo != $REPO), the
#     lookup uses a token scoped to the TARGET repo, minted once per `owner/repo`
#     via get_gh_app_scoped_token and cached in _DEP_TOKEN_CACHE. The ambient
#     $GH_TOKEN is scoped to the DISPATCHING repo only, so it 404s on any other
#     repo — the root cause of #269.
#   - For a SAME-repo dep (owner_repo == $REPO) the ambient $GH_TOKEN already
#     covers the dispatching repo, so NO mint happens — byte-identical to the
#     pre-#284 same-repo `gh issue view --repo $REPO --json state` leaf (which
#     used the ambient token with no mint). This keeps the #269 mint scoped to
#     genuinely cross-repo refs (TC-CRDEP-005: zero mints for the dispatching repo).
#   - In PAT mode (or app mode with creds absent), no mint happens; the lookup
#     uses the ambient $GH_TOKEN, which (for a PAT) already spans repos. This is
#     byte-identical to the pre-#269 behavior.
#
# A per-repo mint FAILURE is cached as the empty string so the lookup falls back
# to the ambient token (which then 404s → empty state → fail-safe block) and the
# doomed repo is not re-minted for every ref. The mint NEVER aborts the tick — a
# same-repo issue in the same body must still dispatch (#269 T4).
itp_github_resolve_dep() {
  local owner_repo="$1" num="$2" out_var="$3"
  # `${GH_TOKEN:-}` guard: in PAT mode the dispatcher does NOT export GH_TOKEN
  # (it relies on `gh auth login`), so an unguarded `$GH_TOKEN` would trip
  # `set -u`. Empty here just means "use whatever ambient auth gh already has".
  local lookup_token="${GH_TOKEN:-}"

  # App mode with creds present AND a genuinely CROSS-repo dep → mint a
  # target-repo-scoped read token, cached. A same-repo dep (owner_repo == $REPO)
  # skips the mint: the ambient token already covers the dispatching repo.
  if [ "${GH_AUTH_MODE:-token}" = "app" ] \
     && [ -n "${DISPATCHER_APP_ID:-}" ] && [ -n "${DISPATCHER_APP_PEM:-}" ] \
     && [ "$owner_repo" != "${REPO:-}" ]; then
    if [ -z "${_DEP_TOKEN_CACHE[$owner_repo]+set}" ]; then
      # First sight of this dep repo this tick — mint once. get_gh_app_scoped_token
      # lives in gh-app-token.sh, sourced by dispatcher-tick.sh in app mode; source
      # it lazily (LIB_DIR pattern) so a standalone-sourced provider (unit tests,
      # ad-hoc) still resolves it. Guard on the function existing.
      if ! declare -F get_gh_app_scoped_token >/dev/null 2>&1; then
        local _self _lib_dir
        _self="${BASH_SOURCE[0]:-$0}"
        # providers/itp-github.sh → ../ is the scripts/ skill tree where
        # gh-app-token.sh lives. readlink -f follows any project-side symlink.
        _lib_dir="$(cd "$(dirname "$(readlink -f "$_self")")/.." && pwd 2>/dev/null)" || _lib_dir=""
        [ -n "$_lib_dir" ] && [ -r "${_lib_dir}/gh-app-token.sh" ] \
          && source "${_lib_dir}/gh-app-token.sh"
      fi
      local _minted=""
      if declare -F get_gh_app_scoped_token >/dev/null 2>&1; then
        _minted=$(get_gh_app_scoped_token \
          "$DISPATCHER_APP_ID" "$DISPATCHER_APP_PEM" \
          "${owner_repo%/*}" "${owner_repo#*/}" "$DEP_LOOKUP_PERMISSIONS" 2>/dev/null || true)
      fi
      # Negative-cache an empty mint so the doomed repo is not re-minted per ref.
      _DEP_TOKEN_CACHE[$owner_repo]="$_minted"
    fi
    # Use the cached scoped token when non-empty; otherwise fall back to ambient.
    [ -n "${_DEP_TOKEN_CACHE[$owner_repo]}" ] && lookup_token="${_DEP_TOKEN_CACHE[$owner_repo]}"
  fi

  # `GH_TOKEN="$lookup_token"` prefix: in app mode this is the target-repo scoped
  # token; in PAT mode lookup_token is empty, and `gh` treats an empty-string
  # GH_TOKEN as not-present (falling back to the host `gh auth login` creds),
  # which is byte-identical to the pre-#269 unprefixed `gh issue view` call.
  local _state
  _state=$(GH_TOKEN="$lookup_token" gh issue view "$num" --repo "$owner_repo" --json state -q '.state' 2>/dev/null || true)
  printf -v "$out_var" '%s' "$_state"
}

# ===========================================================================
# OBSERVE-ONLY METRICS leaf (#323, [INV-93]). The TTHW label-time read behind the
# itp_label_event_ts verb. Best-effort / non-blocking: any failure returns empty
# and the metrics aggregator falls back to the dispatch-instant event `ts`
# (pre-#228 behavior) — it NEVER blocks dispatch. See the verb↔current-function
# mapping appendix in docs/pipeline/provider-spec.md.
# ===========================================================================

# itp_github_label_event_ts ISSUE LABEL — first-`labeled`-event timestamp leaf.
#
# Spec §3.1 [m]: echo the ISO-8601 UTC `created_at` of the FIRST `labeled` event
# for LABEL visible in the GitHub issue timeline, or empty if none / on failure.
# The `event` / `.label.name` / `.created_at` fields are GitHub-internal REST
# timeline vocabulary with NO provider-neutral shape, so the leaf owns the query
# and returns a neutral SCALAR (a timestamp string) — the documented #281
# exception ("jq stays caller-side" governs provider-NEUTRAL shapes), mirroring
# itp_count_by_state returning an int / itp_resolve_dep returning an abstract
# state. NOT the §3.3 comment-array shape.
#
# INJECTION-SAFE label (#323 review R1 [P1]): a raw `${label}` interpolation into
# the `--jq` string is a jq INJECTION — a label like `autonomous" or .label.name
# == "bug` would widen the selector, and a quote-bearing valid label would be a
# jq syntax error. So the label is JSON-ENCODED to a string literal and spliced
# into the program. Two on-box-verified gotchas:
#   (1) the `--arg` name MUST be `lbl` — jq 1.6 reserves `label` as a KEYWORD, so
#       `--arg label` + `$label` is a parse error;
#   (2) `gh api` has NO `--arg` flag (`unknown flag: --arg`) — it does not forward
#       jq variable bindings, so the label MUST be pre-encoded, not bound on the
#       `gh api` call.
# For LABEL=autonomous, `lbl_json` is exactly `"autonomous"` → the spliced program
# is argv-equivalent to the inline selector dispatcher-tick.sh emitted pre-#323.
#
# BEST-EFFORT / no pagination (byte-identical to the pre-#323 read): the single
# `gh api …/timeline` call carries NO `--paginate`, so a label event beyond the
# default page returns empty (aggregator falls back to `ts`). The preserved
# `2>/dev/null || true` swallows a malformed/non-array gh response (`map()` errors)
# → empty, identical to the prior caller-side read.
itp_github_label_event_ts() {
  local issue="$1" label="$2" lbl_json
  # Pre-encode LABEL to a JSON string literal (injection-safe). On any jq error
  # here (should not happen for a normal label), fail soft → empty.
  lbl_json="$(jq -rn --arg lbl "$label" '$lbl | @json')" || { echo ""; return 0; }
  gh api "repos/${REPO}/issues/${issue}/timeline" \
    --jq "map(select(.event == \"labeled\" and .label.name == ${lbl_json})) | (.[0].created_at // empty)" \
    2>/dev/null || true
}
