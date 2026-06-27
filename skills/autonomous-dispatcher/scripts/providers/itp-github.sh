#!/bin/bash
# providers/itp-github.sh — GitHub Issue-Tracker Provider (ITP) reference impl.
#
# Establishes the provider-prefix convention (#280) and migrates the ITP READ
# leaves (#281). Each ITP verb's GitHub leaf is a function named
# itp_github_<verb>; lib-issue-provider.sh's `itp_<verb>` shim forwards "$@" to
# it when ISSUE_PROVIDER=github (the default). The remaining (WRITE / dep) leaves
# are still scaffolds populated by the downstream itp-writes /
# itp-deps-begin-tick issues, per the verb↔current-function mapping appendix in
# docs/pipeline/provider-spec.md.
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
#   itp_github_resolve_dep         itp_github_begin_tick            [deps-begin-tick]
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
