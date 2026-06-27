#!/bin/bash
# providers/itp-github.sh — GitHub Issue-Tracker Provider (ITP) reference impl.
#
# Establishes the provider-prefix convention (#280) and migrates the ITP READ
# leaves (#281), the WRITE leaves (#283), and the dependency-resolution +
# tick-lifecycle leaves (#284, [INV-83]). Each ITP verb's GitHub leaf is a
# function named itp_github_<verb>; lib-issue-provider.sh's `itp_<verb>` shim
# forwards "$@" to it when ISSUE_PROVIDER=github (the default), per the
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
# 13 ITP verbs (spec §3.1):
#   itp_github_list_by_state       itp_github_count_by_state        [#281 READ]
#   itp_github_list_forbidden_combos                                [#281 READ]
#   itp_github_read_task           itp_github_list_comments         [#281 READ]
#   itp_github_transition_state    itp_github_post_comment          [itp-writes]
#   itp_github_edit_comment        itp_github_mark_checkbox         [itp-writes]
#   itp_github_provision_states                                     [itp-writes]
#   itp_github_resolve_dep         itp_github_begin_tick            [#284 DEP]
# (itp_caps reads the .caps manifest in the dispatcher, not a function here.)

# ---------------------------------------------------------------------------
# itp_github_list_by_state — state-filtered issue enumeration leaf.
#
# Spec §3.1: enumerate tasks matching an abstract state set. On GitHub a
# pipeline state IS a label, so the GitHub leaf is a faithful pass-through:
# the caller passes the exact `gh issue list` argument tail it emits today
# (`--state open --limit 100 --label … --json … -q '<INV-25 subtraction>'`)
# and the leaf forwards it to `gh issue list --repo "$REPO" "$@"`. This keeps
# the emitted argv + `--json` field list BYTE-IDENTICAL to the pre-refactor
# call (the no-behavior-change golden-trace anchor, spec §7.1(a)/§7.2) while
# routing the leaf through the verb ([INV-87]). The [INV-25] terminal-state jq
# subtraction is authored in the CALLER's body and travels as the `-q` arg — it
# is NOT logic this provider-neutral leaf knows about (spec §3.1 note).
#
# §3.5: `gh`'s transparent `--json` auto-pagination + secondary-rate-limit retry
# return the COMPLETE set with zero added page-walk code (today's behavior).
itp_github_list_by_state() {
  gh issue list --repo "$REPO" "$@"
}

# itp_github_count_by_state — server-side COUNT leaf (returns an INTEGER).
#
# Spec §3.1 [M3]: distinct from list_by_state because `count_active` returns an
# int the dispatcher compares numerically (the concurrency gate at
# dispatcher-tick.sh:249/264/318/342). The caller supplies the `-q '… | length'`
# that collapses the list to a count via gh's jq; forwarding `"$@"` keeps that
# argv byte-identical and preserves the integer return semantics.
itp_github_count_by_state() {
  gh issue list --repo "$REPO" "$@"
}

# itp_github_list_forbidden_combos — [INV-25] forbidden-label-combination leaf.
#
# Spec §3.1 [M3]: returns tasks carrying a terminal-AND-transitional label
# combination (a 2-axis predicate, NOT a single state set). The caller
# (`list_hygiene_residue`) supplies the 2-axis `-q` predicate; the leaf forwards
# it byte-identically. Kept a DISTINCT verb because `STATE...` cannot express an
# intersection-of-incompatible-states query.
itp_github_list_forbidden_combos() {
  gh issue list --repo "$REPO" "$@"
}

# itp_github_read_task ISSUE FIELD [extra gh args…] — single-task field read.
#
# Spec §3.1: return `title`/`body`/`state` for one task. FIELD is the `--json`
# field list (`title`, `body`, `state`, or a combination like `title,body`).
# The leaf forwards the argv byte-identically; the caller projects the returned
# JSON object (or, for a single field, the bare value via a forwarded `-q`).
# Trailing args after FIELD (e.g. an explicit `-q '.state'`) are forwarded
# verbatim so the call site controls raw-object vs single-field projection,
# keeping the emitted `gh issue view --json <field>` argv byte-identical.
itp_github_read_task() {
  local issue="$1" field="$2"; shift 2
  gh issue view "$issue" --repo "$REPO" --json "$field" "$@"
}

# itp_github_list_comments ISSUE — ISSUE-level comments, NORMALIZED (spec §3.3).
#
# Fetches `gh issue view ISSUE --repo "$REPO" --json comments` (today's leaf,
# byte-identical) and normalizes to the spec §3.3 / [INV-90] array:
#   [{id, author, authorKind, body, createdAt}]  sorted ASCENDING by createdAt.
#
#   id         — REST numeric comment id (GraphQL node_id stays out; [INV-46]
#                PATCH needs the numeric id). gh's `--json comments` puts the
#                GraphQL node_id (`IC_kwD…`) in `.id`; the REST numeric id is the
#                trailing number of the comment `url`
#                (`…/issues/<n>#issuecomment-<id>`) — the only numeric id gh
#                exposes for an issue comment. Null when no parseable url.
#   author     — `.author.login` INCLUDING any `[bot]` suffix verbatim (a stable
#                machine handle for EXACT `==`, NOT a display name; [INV-85]).
#   authorKind — derived enum: `self` when author == $BOT_LOGIN (the pipeline's
#                own bot identity, env), else `bot` when the login ends `[bot]`,
#                else `human`. Spec §3.3 [M5]; lets distinct_bot_author=0
#                backends discriminate self/other without a raw `author==BOT`.
#   body,createdAt — verbatim. createdAt is gh's ISO-8601 UTC string.
#
# The ascending sort is the normative MUST the caller-side `| last` /
# `sort_by(.createdAt)|last` idioms depend on. ALL marker-parsing (capture /
# exact-eq / cutoff compare) stays CALLER-side over this array (spec §3.3).
#
# The normalization is a single `-q` jq over the raw comments object, so a unit
# test that stubs the `gh` BINARY and applies the requested `-q` to a
# `{comments:[…]}` fixture returns the normalized array unchanged — the existing
# gh-stub tests keep working without a fixture rewrite.
#
# §3.5: complete set via gh's transparent `--json` auto-pagination, zero added
# page-walk code.
itp_github_list_comments() {
  local issue="$1"
  gh issue view "$issue" --repo "$REPO" --json comments -q "
    [ .comments[]
      | { id: ( ( (.url // \"\") | capture(\"issuecomment-(?<n>[0-9]+)\$\") | .n | tonumber ) // null ),
          author: (.author.login // null),
          authorKind: ( (.author.login // \"\") as \$a
                        | if (\$a != \"\" and \$a == \"${BOT_LOGIN:-}\") then \"self\"
                          elif (\$a | endswith(\"[bot]\")) then \"bot\"
                          else \"human\" end ),
          body: (.body // \"\"),
          createdAt: (.createdAt // null) }
    ] | sort_by(.createdAt // \"\")
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
# Moves the leaf out of `label_swap` (lib-dispatch.sh) byte-identically: the
# empty-REMOVE / empty-ADD cases STILL omit the corresponding flag, preserving
# the `[ -n "$remove" ]` / `[ -n "$add" ]` guards the caller used. The terminal-
# state jq subtraction in list_pending_review/list_pending_dev ([INV-25]
# defense-in-depth) is NOT this leaf's concern — it stays caller-side (spec §3.1).
itp_github_transition_state() {
  local issue_num="$1" remove="$2" add="$3"
  local args=()
  [ -n "$remove" ] && args+=(--remove-label "$remove")
  [ -n "$add" ] && args+=(--add-label "$add")
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
# is the idempotent per-label view-or-create
# (`gh label view` skip; else `gh label create --color <hex> --description <d>`),
# byte-identical to setup-labels.sh's loop body. The 9-label definition table stays
# caller-side. `label_colors=1` (GitHub) → the `--color` hex is emitted; a
# `label_colors=0` backend omits `--color` (defined; not live this PR). Echoes the
# same `[skip]`/`[created]` lines the caller printed before, so console output is
# unchanged.
itp_github_provision_states() {
  local name="$1" color="$2" description="$3"
  if gh label view "$name" --repo "$REPO" &>/dev/null; then
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
