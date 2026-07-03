#!/bin/bash
# lib-dispatch.sh — composable helpers for the autonomous-dispatcher tick.
#
# All gh / jq / regex logic that used to live in autonomous-dispatcher/SKILL.md
# is consolidated here as small, testable functions. Sourced by
# dispatcher-tick.sh and the per-step scan-*.sh / detect-stale.sh scripts.
#
# Behavior contract (PR-3 preserves all of these byte-for-byte):
#   - Comment phrasings (INV-06 "crashed/process not found" keyword contract)
#   - Label transition order (INV-08 atomic per-edit)
#   - Retry-counter cutoff rule (INV-05)
#   - JUST_DISPATCHED skip rule (INV-09)
#   - Strict > 300s idle gate (INV-10)
#   - SHA trailer format (INV-04)
#   - Session-id format (INV-03 — Dev not Review)
#
# See docs/pipeline/ for the spec.

set -euo pipefail

# Required env: REPO, REPO_OWNER, PROJECT_ID, MAX_RETRIES (default 3),
#               MAX_CONCURRENT (default 5).
: "${REPO:?REPO must be set in autonomous.conf}"
: "${REPO_OWNER:?REPO_OWNER must be set in autonomous.conf}"
: "${PROJECT_ID:?PROJECT_ID must be set in autonomous.conf}"
MAX_RETRIES="${MAX_RETRIES:-3}"
MAX_CONCURRENT="${MAX_CONCURRENT:-5}"

# [INV-86] Authoritative PR↔issue resolution (resolve_pr_for_issue /
# verify_pr_closes_issue) lives in lib-pr-linkage.sh so the review wrapper —
# which does NOT source this heavy lib — can resolve PRs identically. Source it
# from the real skill tree (readlink -f, the LIB_DIR pattern) so a standalone
# unit test that sources only lib-dispatch.sh still gets the delegate target.
# Idempotent (re-source is harmless).
if ! declare -F resolve_pr_for_issue >/dev/null 2>&1; then
  _ld_self="${BASH_SOURCE[0]:-$0}"
  _ld_dir="$(cd "$(dirname "$(readlink -f "$_ld_self")")" && pwd 2>/dev/null)" || _ld_dir=""
  if [ -n "$_ld_dir" ] && [ -r "${_ld_dir}/lib-pr-linkage.sh" ]; then
    # shellcheck source=lib-pr-linkage.sh
    source "${_ld_dir}/lib-pr-linkage.sh"
  fi
  unset _ld_self _ld_dir
fi

# [INV-87] Issue-Tracker Provider dispatch. The state-list / read_task /
# list_comments READ leaves below route through the `itp_*` shims
# (`itp_<verb>` → `itp_${ISSUE_PROVIDER}_<verb>`) defined in
# lib-issue-provider.sh, which also sources providers/itp-${ISSUE_PROVIDER}.sh
# (the GitHub reference impl is providers/itp-github.sh). Sourced from the REAL
# skill tree via readlink -f (the same idiom as lib-pr-linkage.sh above) so a
# standalone unit test that sources only lib-dispatch.sh still gets the verbs.
# Idempotent (the shims and the .caps reader guard their own redefinition).
if ! declare -F itp_list_comments >/dev/null 2>&1; then
  _ld_self="${BASH_SOURCE[0]:-$0}"
  _ld_dir="$(cd "$(dirname "$(readlink -f "$_ld_self")")" && pwd 2>/dev/null)" || _ld_dir=""
  if [ -n "$_ld_dir" ] && [ -r "${_ld_dir}/lib-issue-provider.sh" ]; then
    # shellcheck source=lib-issue-provider.sh
    source "${_ld_dir}/lib-issue-provider.sh"
  fi
  unset _ld_self _ld_dir
fi

# [INV-87] Code-Host Provider dispatch (#282). `ci_is_green` (and, via
# lib-pr-linkage.sh, the PR↔issue resolvers) route their innermost `gh pr *`
# leaf through the `chp_*` shims (`chp_<verb>` → `chp_${CODE_HOST}_<verb>`)
# defined in lib-code-host.sh, which also sources providers/chp-${CODE_HOST}.sh
# (the GitHub reference impl is providers/chp-github.sh). Same readlink -f idiom
# as the lib-pr-linkage / lib-issue-provider sources above; idempotent.
if ! declare -F chp_ci_status >/dev/null 2>&1; then
  _ld_self="${BASH_SOURCE[0]:-$0}"
  _ld_dir="$(cd "$(dirname "$(readlink -f "$_ld_self")")" && pwd 2>/dev/null)" || _ld_dir=""
  if [ -n "$_ld_dir" ] && [ -r "${_ld_dir}/lib-code-host.sh" ]; then
    # shellcheck source=lib-code-host.sh
    source "${_ld_dir}/lib-code-host.sh"
  fi
  unset _ld_self _ld_dir
fi

# [INV-106] (302b, #361): pid_dir_for_project() (lib-config.sh) is the shared
# per-user runtime-dir resolver the controller-side dispatch marker (below)
# reuses — same idempotent, symlink-defended directory `acquire_pid_guard`
# already writes PID/heartbeat files into. dispatcher-tick.sh sources
# lib-config.sh itself before this file, so this guard only matters for a
# standalone unit test that sources lib-dispatch.sh directly. Same
# readlink -f idiom as the itp/chp sources above; idempotent.
if ! declare -F pid_dir_for_project >/dev/null 2>&1; then
  _ld_self="${BASH_SOURCE[0]:-$0}"
  _ld_dir="$(cd "$(dirname "$(readlink -f "$_ld_self")")" && pwd 2>/dev/null)" || _ld_dir=""
  if [ -n "$_ld_dir" ] && [ -r "${_ld_dir}/lib-config.sh" ]; then
    # shellcheck source=lib-config.sh
    source "${_ld_dir}/lib-config.sh"
  fi
  unset _ld_self _ld_dir
fi

# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------

# Count issues currently in active state (in-progress or reviewing).
# Echoes a non-negative integer.
#
# [INV-87]/[W1a, #371] Routes through the ABSTRACT itp_count_by_state contract:
# state=open, labels-AND="autonomous", limit=100, any-of="in-progress,reviewing".
# No gh flags/jq programs cross the seam — the leaf owns the enumeration AND the
# any-of-label count; only the abstract filter set is caller-side.
count_active() {
  itp_count_by_state open "autonomous" 100 "in-progress,reviewing"
}

# ---------------------------------------------------------------------------
# Issue queries (one per step)
# ---------------------------------------------------------------------------

# Step 2: issues with `autonomous` label and NO state label.
# Echoes JSON array of {number, labels, title}.
#
# [INV-87]/[W1a, #371] The enumeration routes through the ABSTRACT
# itp_list_by_state contract (state=open, labels-AND="autonomous", limit=100,
# fields=number,labels,title — normalized `labels` is an array of NAME
# strings). The no-state-label jq subtraction is re-derived CALLER-side over
# the normalized array (spec §3.1 note / mapping appendix).
list_new_issues() {
  itp_list_by_state open "autonomous" 100 "number,labels,title" | jq '[.[] | select(
    (.labels | any(. == "in-progress" or . == "pending-review" or . == "reviewing"
                   or . == "pending-dev" or . == "stalled" or . == "approved")) | not
  )]'
}

# Step 3: issues with `autonomous` + `pending-review` AND NOT `reviewing`.
# Echoes JSON array of {number, labels}.
#
# Terminal-state subtraction (`approved`, `stalled`) is defense-in-depth on
# top of Step 0 hygiene ([INV-25], PR #117). Step 0 strips `pending-review`
# from terminal issues at the top of every tick; if it fails for any reason
# (rate-limit, API outage, future regression), this inline filter still
# keeps the selector from picking the residue and spawning a review against
# an already-approved or stalled issue. Issue #115 (Bug C re-scoped post-
# investigation: original "dev wrapper flips back" hypothesis was wrong;
# the actual third producer was this missing filter).
list_pending_review() {
  # [INV-87]/[W1a, #371] leaf via the ABSTRACT itp_list_by_state contract; the
  # [INV-25] terminal-state subtraction (`reviewing`/`approved`/`stalled`
  # defense-in-depth, #115 Bug C) STAYS caller-side, re-derived over the
  # normalized `labels` name-string array.
  itp_list_by_state open "autonomous,pending-review" 100 "number,labels" | jq '[.[] | select(
    (.labels | any(. == "reviewing") | not) and
    (.labels | any(. == "approved") | not) and
    (.labels | any(. == "stalled") | not)
  )]'
}

# Step 4: issues with `autonomous` + `pending-dev`.
# Echoes JSON array of {number, labels, comments}.
#
# Terminal-state subtraction same as list_pending_review above. Issue
# #115 (Bug C). Without this, an `approved + pending-dev` residue would
# trigger Step 4's `pending-dev → in-progress` swap and spawn dev-resume
# against an approved issue — the actual mechanism behind the wedge that
# motivated this issue.
list_pending_dev() {
  # [INV-87]/[W1a, #371] leaf via the ABSTRACT itp_list_by_state contract. The
  # fields=number,labels,comments field set (comments is the [INV-90]
  # normalized array) and the [INV-25] terminal-state subtraction stay
  # caller-side per spec §3.1, re-derived over the normalized shape.
  itp_list_by_state open "autonomous,pending-dev" 100 "number,labels,comments" | jq '[.[] | select(
    (.labels | any(. == "approved") | not) and
    (.labels | any(. == "stalled") | not)
  )]'
}

# Step 5: issues currently in active state (in-progress OR reviewing) — same
# query as count_active but returning {number, labels} so callers can branch on
# which active label is set.
#
# `approved` is subtracted: an issue in the `approved` terminal state that
# still carries a transitional label (residue from a wrapper crash between
# two label edits, or from the [INV-15] SIGTERM race) must NOT be treated
# as stale. Issue #115 Bug A: without this exclusion, Step 5 swaps the
# active label to `pending-dev`, which re-arms Step 4 on the next tick —
# infinite loop burning tokens on a terminally-decided issue.
list_stale_candidates() {
  # [INV-87]/[W1a, #371] leaf via the ABSTRACT itp_list_by_state contract; the
  # active-state selector + the `approved` subtraction (#115 Bug A) stay
  # caller-side per spec §3.1, re-derived over the normalized `labels` array.
  itp_list_by_state open "autonomous" 100 "number,labels" | jq '[.[] | select(
    (.labels | any(. == "in-progress" or . == "reviewing")) and
    (.labels | any(. == "approved") | not)
  )]'
}

# ---------------------------------------------------------------------------
# Step 0: label hygiene helpers ([INV-25], issue #115 Bug B)
# ---------------------------------------------------------------------------

# Terminal-label predicate. Pure function over a labels JSON — a NORMALIZED
# array of NAME strings (`["foo","bar",...]`, the [W1a, #371] itp_list_by_state
# / itp_list_forbidden_combos shape). Returns 0 if the label set contains
# `approved` or `stalled` (i.e. the issue is in a sticky terminal state); 1
# otherwise. Future selectors can use this to subtract terminals without each
# rewriting the contains([...]) algebra.
_has_terminal_label() {
  local labels_json="$1"
  jq -e '(contains(["approved"]) or contains(["stalled"]))' \
    <<<"$labels_json" >/dev/null
}

# List autonomous issues whose label set is in violation of the
# state-machine "Forbidden transitions" rules:
#   - approved + (in-progress | reviewing | pending-review | pending-dev)
#   - stalled  + (in-progress | reviewing | pending-review | pending-dev)
# Returns a JSON array of {number, labels:[{name}]}. Empty array when no
# residue exists (the steady state).
list_hygiene_residue() {
  # [INV-87]/[W1a, #371] leaf via the ABSTRACT itp_list_forbidden_combos
  # contract: the 2-axis (terminal AND transitional) [INV-25] forbidden-combo
  # predicate MOVED INTO THE LEAF (spec R1's one deliberate exception to
  # "predicates stay caller-side") — this caller is now a thin pass-through.
  itp_list_forbidden_combos open "autonomous" 100
}

# Strip transitional labels from an issue that also carries a terminal
# label. Single bundled `gh issue edit` so the strip is atomic per
# issue. Echoes the space-separated list of labels stripped (so the
# caller can feed it to hygiene_post_audit_comment), or empty when the
# issue is already clean.
hygiene_strip_residual_labels() {
  local issue_num="$1"
  local labels_json="$2"

  # Build the list of transitional labels actually present. labels_json is the
  # [W1a, #371] normalized array of NAME strings (not {name} objects).
  local stripped
  stripped=$(jq -r '
    . as $names
    | ["in-progress","reviewing","pending-review","pending-dev"]
    | map(select(. as $t | $names | index($t)))
    | join(" ")
  ' <<<"$labels_json")

  if [[ -z "$stripped" ]]; then
    return 0
  fi

  # Bail if the issue isn't in a terminal state — defensive: caller
  # should have prefiltered with list_hygiene_residue, but a stray
  # invocation against a plain transitional issue (TC-HYG-006) must NOT
  # strip anything.
  if ! _has_terminal_label "$labels_json"; then
    return 0
  fi

  # [INV-97] CSV multi-remove: route the atomic strip through the ITP verb. The
  # REMOVE operand is the variable-N `$stripped` list (a hardcoded, comma-free
  # transitional-label set per the jq allowlist above) joined space→comma; no add.
  # One verb call = one atomic `gh issue edit`, identical to the prior bundled edit
  # (the per-issue atomicity [INV-25] depends on). The `2>/dev/null || true`
  # fail-safe framing and the `echo "$stripped"` return are preserved byte-for-byte.
  # The CSV is built on its OWN line into `$remove_csv` so the verb call carries
  # only `$`-leading variable operands — the spec-gate Form-3 scanner's skip-variable
  # guard then emits no (garbage) movement (identical posture to label_swap's
  # fully-variable `itp_transition_state "$issue_num" "$remove" "$add"` delegation);
  # the LITERAL transitional-label set is validated upstream by the jq allowlist +
  # the hygiene-strip-residue-* transitions (P1.1 variable_write_allowlist).
  local remove_csv
  remove_csv=$(echo "$stripped" | tr ' ' ',')
  itp_transition_state "$issue_num" "$remove_csv" "" 2>/dev/null || true
  echo "$stripped"
}

# Post a one-shot audit comment on an issue when residual labels were
# stripped. Idempotency is keyed on `<sorted-stripped-labels>` so the
# same issue+residue-set never gets two comments. Different residue sets
# on the same issue (rare — implies a second drift) do post a fresh
# comment.
#
# `terminal_label` is the sticky label (`approved` / `stalled`) used in
# the comment body; `stripped_labels` is the space-separated list from
# hygiene_strip_residual_labels.
hygiene_post_audit_comment() {
  local issue_num="$1"
  local terminal_label="$2"
  local stripped_labels="$3"

  if [[ -z "$stripped_labels" ]]; then
    return 0
  fi

  # Sort for stable marker. The trailing `;` is a delimiter that makes the
  # contains()-based probe equality-safe: without it, a marker for the
  # wider residue set (`...:in-progress,reviewing`) would substring-match
  # a probe for a narrower set (`...:in-progress`), suppressing
  # legitimate audit comments when residue regresses from a wider to a
  # narrower set on the same issue. Labels are kebab-case lowercase so
  # `;` cannot collide.
  local sorted
  sorted=$(echo "$stripped_labels" | tr ' ' '\n' | sort | tr '\n' ',' | sed 's/,$//')
  local marker="INV-25-hygiene:${sorted};"

  local existing
  existing=$(itp_list_comments "$issue_num" 2>/dev/null \
    | jq -r "[.[].body | select(contains(\"${marker}\"))] | length" \
    2>/dev/null || echo 0)

  if [[ "$existing" != "0" ]]; then
    return 0
  fi

  local pretty
  pretty=$(echo "$stripped_labels" | tr ' ' '\n' | awk 'NF{printf "%s`%s`", (NR>1?", ":""), $1}')
  itp_post_comment "$issue_num" \
    "Label hygiene: stripped ${pretty} from \`${terminal_label}\` issue (INV-25). <!-- ${marker} -->" \
    2>/dev/null || true
}

# Step 0 entry point. Iterates list_hygiene_residue and applies
# hygiene_strip_residual_labels + hygiene_post_audit_comment. Always
# safe to call — no-op when no residue exists.
run_hygiene_pass() {
  local residue
  residue=$(list_hygiene_residue)
  local count
  count=$(jq 'length' <<<"$residue")
  if [[ "$count" -eq 0 ]]; then
    return 0
  fi

  local i
  for i in $(seq 0 $((count - 1))); do
    local issue_num labels_json terminal stripped
    issue_num=$(jq -r ".[$i].number" <<<"$residue")
    labels_json=$(jq -c ".[$i].labels" <<<"$residue")

    # Determine which terminal label drove the residue (approved wins
    # when both are present — caller can audit further from the comment).
    # labels_json is the [W1a, #371] normalized array of NAME strings.
    if jq -e 'contains(["approved"])' <<<"$labels_json" >/dev/null; then
      terminal="approved"
    else
      terminal="stalled"
    fi

    stripped=$(hygiene_strip_residual_labels "$issue_num" "$labels_json")
    if [[ -n "$stripped" ]]; then
      hygiene_post_audit_comment "$issue_num" "$terminal" "$stripped"
    fi
  done
}

# ---------------------------------------------------------------------------
# Step 2: dependency check
# ---------------------------------------------------------------------------

# [INV-83] resolve_dep_state <owner/repo> <num> <out_var> — cross-repo aware
# dependency state lookup. Thin CALLER-side wrapper (#284): the leaf state lookup,
# the per-dep-repo scoped-token mint, the tick-scoped `_DEP_TOKEN_CACHE`, and the
# `DEP_LOOKUP_PERMISSIONS` default all moved INTO the GitHub ITP provider
# (providers/itp-github.sh) behind the `itp_resolve_dep` verb + the
# `itp_begin_tick` lifecycle hook (spec §3.6). This wrapper simply forwards to the
# verb, preserving the (owner_repo, num, out_var) signature so the call site in
# check_deps_resolved is unchanged.
#
# THE OUT-VAR CONTRACT IS LOAD-BEARING (AC + §3.6): the result MUST flow via
# `printf -v "$out_var"`, NOT stdout/`$(...)`. The mint mutates the module-level
# `_DEP_TOKEN_CACHE` (now owned by the GitHub provider), and that write MUST stay
# in the caller's shell so the cache survives across the multiple refs in one
# `check_deps_resolved` call and across issues in one tick. A command-substitution
# capture would run mint+cache-write in a subshell and reset the dedup cache per
# ref. The whole chain — resolve_dep_state → itp_resolve_dep →
# itp_github_resolve_dep — is out-var all the way down (none of these links
# captures via `$(...)`), so the cache ownership chain reaches the provider
# in-shell. itp_github_resolve_dep does the `printf -v "$out_var"`; this wrapper
# only forwards the out-var NAME, never the value.
#
# Always returns 0 — the caller fail-safe-blocks on an empty out-var value. Token
# routing (app-mode scoped mint vs PAT-mode ambient), negative-cache on mint
# failure, and no-tick-abort are all the provider's concern now ([INV-83]).
resolve_dep_state() {
  itp_resolve_dep "$@"
}

# _dep_block_comment <issue_num> <owner/repo> <num> — [INV-83] block visibility.
#
# Posts a once-per-issue-per-ref comment when a cross-repo dependency stays
# unresolvable, so a persistent block is not invisible behind a stderr WARN.
# Dedup is keyed on a hidden `<!-- dep-block:<repo>#<num> -->` marker scanned
# from existing comments (fail-closed: a transient gh error yields empty output,
# grep returns non-zero, and we skip the post). Best-effort — never changes the
# caller's fail-safe rc.
_dep_block_comment() {
  local issue_num="$1" owner_repo="$2" num="$3"
  local marker="dep-block:${owner_repo}#${num}"
  if itp_list_comments "$issue_num" 2>/dev/null \
      | jq -r "[.[].body | select(contains(\"${marker}\"))] | length" \
      2>/dev/null | grep -q '^0$'; then
    itp_post_comment "$issue_num" \
      "Dependency \`${owner_repo}#${num}\` could not be resolved — the App may not be installed on \`${owner_repo}\` (or the issue is private/deleted). This issue stays blocked until the dependency is reachable and CLOSED/MERGED. <!-- ${marker} -->" \
      2>/dev/null || true
  fi
}

# Returns 0 (resolved) if every issue referenced in the issue body's
# `## Dependencies` section is in a resolved state (CLOSED or MERGED).
# Returns 1 (blocked) on the first unresolved dependency. Returns 0 if no
# dependencies are listed.
#
# Parsing rules (see INV-11 in docs/pipeline/invariants.md):
#   - Only list-item lines (`-`, `*`, or `1.` markers) inside the
#     `## Dependencies` section are scanned. Prose, blockquotes, and
#     headings are ignored — this is what stops false positives where a
#     `#NNN` mentioned in passing got greedy-extracted (#157).
#   - Two ref shapes are recognized, longest first per line:
#       * `owner/repo#N` → resolved against the named repo
#       * `#N`           → resolved against $REPO (same-repo)
#   - Both shapes require a left boundary (start-of-line or whitespace) so
#     URL fragments (`https://github.com/.../issues/123`) and inline
#     punctuation aren't misparsed.
#
# Token routing ([INV-83], #269): the cross-repo `owner/repo#N` arm resolves
# state via resolve_dep_state, which (in app mode) mints a token scoped to the
# TARGET repo — the ambient $GH_TOKEN is scoped to the DISPATCHING repo only and
# 404s on any other repo, the root cause of #269. The same-repo `#N` arm keeps
# the ambient $GH_TOKEN unchanged.
#
# Closes #61 (MERGED PRs report `state: "MERGED"`, not `"CLOSED"`),
# #73 (replace GNU-only `grep -oP '#\K[0-9]+'` with portable extraction),
# #157 (cross-repo refs + list-only scope), and #269 (cross-repo scoped token).
check_deps_resolved() {
  local issue_num="$1"
  local body section line state dep_repo dep_num matched
  # [INV-83] The dep-lookup token cache is TICK-scoped, NOT per-issue: AC #2
  # requires caching by `owner/repo` *within the tick* so two issues in the same
  # tick that depend on the same external repo reuse ONE minted token. The cache
  # (now provider-internal, owned by the GitHub ITP provider behind
  # itp_begin_tick — #284) therefore persists across check_deps_resolved calls
  # here and is cleared only at the tick boundary by `itp_begin_tick`
  # (dispatcher-tick.sh calls it once, before Step 2). Do NOT reset it here — that
  # defeats the cross-issue dedup (#269 review [P1]).
  #
  # [INV-83] cross_ref_shorthand capability gate (#284, spec §4): the cross-repo
  # `owner/repo#N` shorthand is recognized ONLY when the enabled ITP provider
  # declares cross_ref_shorthand=1 (GitHub → today's path). A
  # cross_ref_shorthand=0 backend (opaque gid / permalink dep refs) does NOT parse
  # the `owner/repo#N` shorthand here; its full-id/permalink ref form ships when
  # that backend lands (only GitHub's =1 path is live now). Read once per call.
  local _xref_shorthand
  _xref_shorthand=$(itp_caps cross_ref_shorthand 2>/dev/null || echo 1)

  # [INV-83] Provider-leaf presence guard (#284 review [P1]). BOTH dep arms (the
  # cross-repo Stage 2a and the same-repo Stage 2b) resolve state through
  # `resolve_dep_state` → the `itp_resolve_dep` verb. lib-issue-provider.sh ALWAYS
  # defines the `itp_resolve_dep` SHIM, but a provider that has not migrated its
  # dependency-resolution leaf yet (the degraded fixture provider, any
  # not-yet-migrated gitlab/asana backend) defines no `itp_${ISSUE_PROVIDER}_resolve_dep`
  # — so the shim would call an undefined function → `command not found` → abort the
  # tick under `set -e` (and, even if it didn't abort, every dep would spuriously
  # block on an empty state). A provider without the leaf simply CANNOT evaluate
  # cross-task dependencies through the seam, so dependency-gating is skipped:
  # `check_deps_resolved` returns 0 (resolved/proceed) rather than aborting or
  # permanently blocking. GitHub (the only live provider) DOES define the leaf, so
  # this guard is never taken in production and dep-gating works exactly as designed.
  # This restores the pre-#284 "any provider can do the same-repo lookup" robustness
  # the raw `gh issue view` call had, without re-introducing a raw caller-side gh
  # call (AC #4) — it degrades the whole dep check, not a single arm.
  #
  # NOTE (#296 B2, #306): this guard is keyed on the `resolve_dep` verb. The body
  # read below now routes through the DIFFERENT `read_task` verb. Both leaves exist
  # for the live GitHub provider, so the GitHub path is unaffected; widening this
  # guard to also cover `read_task` is out of scope for B2 (the raw `gh` ran
  # regardless before, so the "zero behavior change" claim holds for GitHub).
  if ! declare -F "itp_${ISSUE_PROVIDER:-github}_resolve_dep" >/dev/null 2>&1; then
    return 0
  fi

  # [INV-87] (#296 B2, #306) the issue-BODY read routes through the itp_read_task
  # verb (GitHub leaf itp_github_read_task → `gh issue view "$issue_num" --repo
  # "$REPO" --json body -q '.body'`, byte-identical). lib-issue-provider.sh is
  # already sourced above, so the shim is reachable. The `## Dependencies` sed
  # extraction + per-ref predicate stay caller-side (spec §3.6).
  body=$(itp_read_task "$issue_num" body -q '.body')
  section=$(printf '%s\n' "$body" | sed -n '/^## Dependencies/,/^## /p')

  # Stage 1: restrict to list-item lines. `grep -E` exits non-zero when
  # nothing matches; the trailing `|| true` keeps the pipeline alive so
  # the while loop simply runs zero times and we fall through to rc=0.
  while IFS= read -r line; do
    # Stage 2a: cross-repo `owner/repo#N` — gated on cross_ref_shorthand=1.
    # Matched longest-first so that `owner/repo#42` doesn't survive to be
    # re-parsed as bare `#42`. The left boundary `(^|[[:space:]\(])` rules out
    # URL fragments and inline punctuation while still allowing parenthesized
    # refs like `- (owner/repo#42)`. When cross_ref_shorthand=0 this loop is
    # skipped entirely (the shorthand is not this provider's dep-ref form).
    while [ "$_xref_shorthand" = "1" ] \
          && [[ "$line" =~ (^|[[:space:]\(])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+) ]]; do
      matched="${BASH_REMATCH[0]}"
      dep_repo="${BASH_REMATCH[2]}"
      dep_num="${BASH_REMATCH[3]}"
      # [INV-83] Resolve against the TARGET repo with a target-repo-scoped token
      # (app mode); the ambient $GH_TOKEN is locked to the dispatching repo (#269).
      # Out-var (not `state=$(...)`) so the per-tick mint cache, mutated inside
      # resolve_dep_state, survives across refs (a subshell capture would reset it).
      state=""
      resolve_dep_state "$dep_repo" "$dep_num" state
      # Empty state means the lookup failed (404, network error, private repo, or
      # — the #269 case — the App is not installed on the dep repo). [INV-39]:
      # fail-safe blocks dispatch, but the failure must be observable. The
      # sharpened WARNING names the scope/installation cause FIRST ([INV-83]); a
      # once-per-ref comment ([INV-83] T5) surfaces a persistent block on the
      # issue so it is not invisible behind a stderr WARN.
      if [ -z "$state" ]; then
        echo "[check_deps_resolved] WARNING: cross-repo lookup failed for ${dep_repo}#${dep_num} (issue ${issue_num}) — the App may not be installed on ${dep_repo} (or the issue is private/deleted); blocking" >&2
        _dep_block_comment "$issue_num" "$dep_repo" "$dep_num"
        return 1
      fi
      if [ "$state" != "CLOSED" ] && [ "$state" != "MERGED" ]; then
        return 1
      fi
      line="${line/"$matched"/ }"
    done
    # Stage 2b: bare `#N` on the residue. Same-repo lookup against $REPO. The
    # leaf moved into the provider (#284) behind itp_resolve_dep — same out-var
    # contract as the cross-repo arm — but for owner_repo == $REPO the provider
    # skips the mint and uses the ambient $GH_TOKEN (UNCHANGED: the dispatcher
    # token already covers $REPO). The emitted argv stays byte-identical to the
    # pre-#284 same-repo issue-state read (the leaf now lives in the provider).
    while [[ "$line" =~ (^|[[:space:]\(])#([0-9]+) ]]; do
      matched="${BASH_REMATCH[0]}"
      dep_num="${BASH_REMATCH[2]}"
      state=""
      resolve_dep_state "$REPO" "$dep_num" state
      if [ -z "$state" ]; then
        echo "[check_deps_resolved] WARNING: lookup failed for ${REPO}#${dep_num} (issue ${issue_num}); blocking" >&2
        return 1
      fi
      if [ "$state" != "CLOSED" ] && [ "$state" != "MERGED" ]; then
        return 1
      fi
      line="${line/"$matched"/ }"
    done
  done < <(printf '%s\n' "$section" | grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]' || true)

  return 0
}

# ---------------------------------------------------------------------------
# Step 4: retry counter
# ---------------------------------------------------------------------------

# Echoes the count of failure events on the issue, using the stalled-cutoff
# rule [INV-05]: only count failures after the most recent
# "Marking as stalled" comment. Two event sources are counted:
#   - Agent Session Report (Dev) comments with non-zero exit code (always)
#   - Dispatcher-detected crash comments matching [INV-06]'s keyword regex,
#     BUT only when the agent has confirmed startup at some point in the
#     current retry cycle (a "Dev Session ID:" comment exists post-cutoff).
#     Without that gate, dispatcher false positives from the cold-start
#     window (Bug 1 in #99) consume MAX_RETRIES even though the agent
#     never actually failed. See [INV-18].
#
# When MAX_RETRIES is hit, mark_stalled() is the appropriate action.
count_retries() {
  local issue_num="$1"
  local agent_failures dispatcher_crashes
  agent_failures=$(count_agent_failures "$issue_num")
  dispatcher_crashes=$(count_dispatcher_crashes "$issue_num")

  # Bug 5 (#99): only count dispatcher-detected crashes when the agent has
  # confirmed startup at some point in this retry cycle. Pre-confirmation
  # crashes are dispatcher-side false positives (cold-start window, missing
  # exec bit, broken auth handoff) and must NOT consume MAX_RETRIES.
  if _agent_started_since_stall "$issue_num"; then
    echo $((agent_failures + dispatcher_crashes))
  else
    echo "$agent_failures"
  fi
}

# Echoes the count of dispatcher-detected false positives (no session ID
# observed in this retry cycle). Reported alongside the canonical counters
# in mark_stalled() so operators can see Bug 1 cold-start crashes are
# being suppressed instead of silently absorbed.
count_dispatcher_false_positives() {
  local issue_num="$1"
  if _agent_started_since_stall "$issue_num"; then
    echo 0
  else
    count_dispatcher_crashes "$issue_num"
  fi
}

# Returns 0 if at least one "Dev Session ID: <id>" comment appears after the
# most recent "Marking as stalled" cutoff AND that comment did NOT come from
# a startup-failure path (i.e., the agent really did start, not just
# wrapper-side post-mortem with a forwarded session id). [INV-19] gate for
# Bug 5.
#
# Why exclude `Mode: startup-failure`: autonomous-dev.sh's startup-failure
# trap (when AGENT_RAN=false, e.g. gh-with-token-refresh couldn't find a
# real gh — #92) still emits a session report containing the SESSION_ID
# that was passed to --session for dev-resume mode. Counting that as
# "agent confirmed startup" would arm dispatcher-crash counting on a
# wrapper that never actually invoked the agent.
_agent_started_since_stall() {
  local issue_num="$1"
  local last_stalled_at session_seen
  last_stalled_at=$(itp_list_comments "$issue_num" \
    | jq -r '[.[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')
  session_seen=$(itp_list_comments "$issue_num" \
    | jq -r "[.[] | select((.createdAt > \"${last_stalled_at}\") and (.body | test(\"Dev Session ID: .[a-zA-Z0-9_-]+\")) and (.body | test(\"Mode: startup-failure\") | not))] | length")
  [ "${session_seen:-0}" -gt 0 ]
}

# Echoes the agent_failures count separately (used by mark_stalled comment).
count_agent_failures() {
  local issue_num="$1"
  local last_stalled_at
  last_stalled_at=$(itp_list_comments "$issue_num" \
    | jq -r '[.[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')
  # Exit code exclusions:
  #   0   → success (pre-existing exclusion).
  #   143 → SIGTERM. Almost always caused by `dispatch-local.sh::kill_stale_wrapper`
  #         when the dispatcher decides to kick a stale wrapper to spawn a fresh
  #         one. Counting the dispatcher's own kill as an "agent failure"
  #         consumed retry budget the agent never spent (see #121 Fix A).
  #   137 → SIGKILL. The escalation path when SIGTERM is ignored, again driven
  #         by kill_stale_wrapper. Same reasoning as 143.
  # Genuine hangs are still bounded by `lib-agent.sh::_run_with_timeout`'s
  # exit code 124 (kept counting) and any non-listed non-zero exit (real
  # agent crashes). The regex anchors on word boundaries (`Exit code:
  # 143\b`-equivalent via `\\b`) so 144 / 1430 / etc. don't false-match.
  itp_list_comments "$issue_num" \
    | jq -r "[.[] | select(
         (.createdAt > \"${last_stalled_at}\")
         and (.body | test(\"Agent Session Report \\\\(Dev\\\\)\"))
         and (.body | test(\"Exit code: 0\\\\b\") | not)
         and (.body | test(\"Exit code: 143\\\\b\") | not)
         and (.body | test(\"Exit code: 137\\\\b\") | not)
       )] | length"
}

count_dispatcher_crashes() {
  local issue_num="$1"
  local last_stalled_at
  last_stalled_at=$(itp_list_comments "$issue_num" \
    | jq -r '[.[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')
  itp_list_comments "$issue_num" \
    | jq -r "[.[] | select((.createdAt > \"${last_stalled_at}\") and (.body | test(\"Task appears to have crashed \\\\(no PR found\\\\)|process not found\")))] | length"
}

# may_stall_now — shared INV-26 liveness/eligibility PREDICATE (no side-effect).
#
# Returns 0 (eligible to stall NOW) / 1 (defer — a dev wrapper is still alive).
# This is the liveness gate extracted out of `mark_stalled` so BOTH `mark_stalled`
# AND the [INV-105] convergence circuit-breaker (#297) share ONE source of truth
# for "is it safe to take a terminal action against this issue right now" — no
# copy-pasted `pid_alive` block ([INV-105] C4′/C9b).
#
# Scope of the extraction (C9b): the LIVENESS PREDICATE ONLY —
#   - the `pid_alive [--at-cap]` probe, AND
#   - the local-backend empty-PID→DEAD narrowing (issue #263).
# It emits NO comment. `mark_stalled` keeps its own idempotent
# `INV-26-stall-deferral` "Stall decision deferred" operator comment (so INV-26's
# operator-visible deferral behavior is byte-identical before/after this factoring
# — the deferral comment is NOT part of the predicate).
#
# Optional leading positional `--at-cap` flag (issue #263): propagated to the
# `pid_alive` probe. Passed ONLY by the retry-budget-exhausted `mark_stalled`
# caller (`dispatcher-tick.sh` Step 4). The review-retry-cap `mark_stalled`
# caller AND the #297 breaker both call WITHOUT `--at-cap` (they are not
# retry-budget-exhausted), so an indeterminate remote-SSM verdict keeps [INV-30]'s
# ALIVE-bias → defer (a MISS, which the #297 design biases toward — C9b/R4). The
# flag is positional, never an env var, so it cannot leak between callers.
#
# Returns 1 (DEFER) when a wrapper is ALIVE; returns 0 (ELIGIBLE) otherwise
# (dead PID, absent PID file, or local empty-PID→DEAD).
may_stall_now() {
  local at_cap=false
  if [ "${1:-}" = "--at-cap" ]; then at_cap=true; shift; fi
  local issue_num="$1"

  local _alive
  if [ "$at_cap" = true ]; then
    pid_alive --at-cap issue "$issue_num" && _alive=0 || _alive=1
  else
    pid_alive issue "$issue_num" && _alive=0 || _alive=1
  fi
  if [ "$_alive" = 0 ]; then
    local pid _backend
    pid=$(get_pid issue "$issue_num")
    # Resolve the backend on its own line, compare against the literal on
    # the next — keep the env-var name and the backend literal on SEPARATE
    # lines. TC-RPA-010 sets its awk in_block on the FIRST line naming both
    # together, so they must never co-occur on one line at or before
    # `pid_alive`. Do NOT collapse the assignment and the comparison below.
    _backend="${EXECUTION_BACKEND:-local}"

    # Empty-PID = DEAD shortcut, narrowed to local backend (issue #263).
    # Under local backend `pid_alive` can return ALIVE via tier-2 PID-file
    # mtime or tier-3 heartbeat mtime even when the PID file *content* is
    # empty (no wrapper holds it) — an empty PID then means no wrapper is
    # running, so treat it as DEAD (eligible to stall). Do NOT apply under
    # the remote backend: there the PID file lives on the wrapper box and
    # dispatcher-side `get_pid` is ALWAYS empty regardless of wrapper state,
    # so empty-PID is the steady state, not a DEAD signal — the `--at-cap`
    # flag handles the indeterminate case instead. Re-introducing an
    # unconditional empty-PID shortcut here would resurrect the #121 /
    # downstream-consumer false-stall bug under the remote backend.
    if [ "$_backend" != "remote-aws-ssm" ] && [ -z "$pid" ]; then
      return 0   # eligible (no live wrapper)
    fi
    return 1     # defer (a wrapper is alive)
  fi
  return 0       # eligible (pid_alive says DEAD)
}

# Mark issue as stalled (retry exhausted). Posts the canonical "Marking as
# stalled" comment that the next stalled-cutoff calculation will key off.
#
# Optional leading positional `--at-cap` flag (issue #263): propagated to the
# liveness probe (`pid_alive --at-cap`) via the shared `may_stall_now`. It MUST
# be passed ONLY by the retry-budget-exhausted caller (`dispatcher-tick.sh`
# Step 4, fired at `count_retries >= MAX_RETRIES`). The other caller —
# `handle_completed_session_routing`'s `REVIEW_RETRY_LIMIT` branch — is the
# review-retry-cap state, NOT the retry-budget-exhausted state, so it does
# NOT pass the flag and therefore retains [INV-30]'s indeterminate→ALIVE
# bias under the remote backend. (A blanket `--at-cap` would over-apply the
# DEAD bias to that path; flagged BLOCKING in #263 review.) The flag is
# positional, never an env var, so it cannot leak between callers.
mark_stalled() {
  local at_cap=false
  if [ "${1:-}" = "--at-cap" ]; then at_cap=true; shift; fi
  local issue_num="$1"

  # Liveness defer (#121 Fix C): if a dev wrapper is still alive on this
  # issue, the retry counter is almost certainly wrong (the wrapper is
  # making real progress; the dispatcher's "crash" detection or its own
  # kill_stale_wrapper SIGTERMs are scoring a healthy wrapper). Posting
  # `+stalled` here would lie about a working wrapper — and worse, the
  # wrapper trap will then write `pending-review` onto a stalled issue,
  # producing the `approved + stalled` co-existence wedge documented in
  # #121's reproduction (podcast-curation#204 / 2026-05-14).
  #
  # Defense: defer the decision when `pid_alive` reports ALIVE. Post a
  # one-shot deferral comment (idempotency-keyed on the agent's current
  # session id pulled from the wrapper PID file path, so re-ticks against
  # the same alive wrapper don't fill the timeline).
  #
  # At-cap propagation ([INV-30] exception, issue #263): when this call was
  # made `--at-cap` (the MAX_RETRIES caller), pass the flag through to
  # `pid_alive` (via the shared `may_stall_now` predicate) so a
  # persistently-indeterminate remote-SSM verdict flips from ALIVE-bias to DEAD,
  # bounding the defer loop to one tick instead of forever (a downstream
  # consumer's ~40h hang). When NOT at-cap (the review-retry-cap caller), the
  # plain probe keeps INV-30's ALIVE-bias. Definite ALIVE/DEAD verdicts are
  # unaffected either way.
  #
  # [INV-105] (#297): the liveness predicate itself (pid_alive + local
  # empty-PID→DEAD narrowing) is now the shared `may_stall_now` helper — but the
  # idempotent `INV-26-stall-deferral` OPERATOR COMMENT stays HERE, so
  # mark_stalled's deferral-comment behavior is byte-identical before/after the
  # #297 factoring (the comment is NOT part of the predicate — C9b). The #297
  # breaker calls `may_stall_now` WITHOUT posting this comment (its own deferral
  # is a silent MISS).
  local _may
  if [ "$at_cap" = true ]; then
    may_stall_now --at-cap "$issue_num" && _may=0 || _may=1
  else
    may_stall_now "$issue_num" && _may=0 || _may=1
  fi
  if [ "$_may" = 1 ]; then
    # Defer — a dev wrapper is still alive. Post a one-shot deferral comment
    # (idempotency-keyed on the wrapper PID so re-ticks against the same alive
    # wrapper don't fill the timeline).
    local pid current_session_marker
    pid=$(get_pid issue "$issue_num")
    current_session_marker="INV-26-stall-deferral:pid=${pid}"
    if itp_list_comments "$issue_num" 2>/dev/null \
        | jq -r "[.[].body | select(contains(\"${current_session_marker}\"))] | length" \
        2>/dev/null | grep -q '^0$'; then
      itp_post_comment "$issue_num" \
        "Stall decision deferred: dev wrapper PID ${pid} is still alive — counter says ${MAX_RETRIES} but a wrapper is making progress. Re-evaluating next tick. (\`${current_session_marker}\`)"
    fi
    return 0
  fi

  local agent_failures dispatcher_crashes false_positives
  agent_failures=$(count_agent_failures "$issue_num")
  dispatcher_crashes=$(count_dispatcher_crashes "$issue_num")
  false_positives=$(count_dispatcher_false_positives "$issue_num")
  # [INV-87]/[INV-89] The pending-dev→stalled transition routes through the single
  # label_swap helper (→ itp_transition_state) instead of an inline `gh issue
  # edit`, so every transition funnels through one choke-point. Same labels, same
  # order, same atomic bundled edit — zero behavior change.
  label_swap "$issue_num" "pending-dev" "stalled"
  # Operator visibility: counted vs. suppressed dispatcher events ([INV-18]).
  # Suppressed events are dispatcher-detected crashes that occurred before the
  # agent confirmed startup (no Dev Session ID written) — these are
  # dispatcher-side false positives and do NOT consume MAX_RETRIES.
  local counted_dispatcher_crashes=$(( dispatcher_crashes - false_positives ))
  itp_post_comment "$issue_num" \
    "Issue has exceeded the maximum retry limit (${MAX_RETRIES} failed attempts: ${agent_failures} agent failures + ${counted_dispatcher_crashes} dispatcher-detected crashes; ${false_positives} dispatcher false positives suppressed per #99). Marking as stalled. @${REPO_OWNER} please investigate manually."
}

# ---------------------------------------------------------------------------
# Step 4: session-id extraction
# ---------------------------------------------------------------------------

# Echoes the most recent Dev Session ID for the issue (must NOT match
# Review Session ID — see [INV-03]). Echoes empty string if none found.
#
# Closes #70: jq 1.6+ uses Oniguruma which expects `(?<id>...)` — Python
# style `(?P<id>...)` errors with "Regex failure: undefined group option"
# and the `// empty` fallback does NOT catch it (jq exits non-zero before
# `//` is evaluated). See [INV-16].
extract_dev_session_id() {
  local issue_num="$1"
  itp_list_comments "$issue_num" \
    | jq -r '[.[].body | capture("Dev Session ID: `(?<id>[a-zA-Z0-9_-]+)`"; "g") | .id] | last // empty'
}

# is_session_completed — return 0 if the agent's last log object indicates a
# session state that resume cannot recover from. Two cases qualify:
#
#   1. end_turn|completed         — normal exit, agent has nothing left to do.
#                                   Resuming would attach to a closed SSE
#                                   stream and hang (#59, INV-12).
#   2. *|prompt_too_long          — JSONL transcript exceeded the model's
#                                   input window. claude -p has no auto-
#                                   compaction, so resuming re-feeds the
#                                   whole transcript and crashes again. The
#                                   only recovery is a fresh session with a
#                                   smaller seed prompt.
#
# Used by Step 4 to skip resume against a session that cannot make progress.
# The caller distinguishes (1) vs (2) via the optional capture-mode arg
# (`is_session_completed N reason_var`) — case (1) is left for the operator
# to decide; case (2) flips the label back to pending-dev so the next tick
# auto-retries with a fresh session.
#
# Returns 1 (false) for: AGENT_CMD != claude, missing/unreadable log, no JSON
# object found, malformed JSON, or any non-terminal stop reason (api_error,
# stop_sequence, etc.).
# Conservative: a false negative just means we still try to resume (existing
# behavior); a false positive (claiming terminal when it isn't) would
# mistakenly skip a legitimate retry.
#
# Per-CLI scope (AGENT_CMD-gated by design — see follow-up TODO):
#   claude   — fully covered. JSON shape `{"type":"result", stop_reason,
#              terminal_reason}` is documented + tested.
#   codex    — NOT covered. codex `exec --json` emits a different event
#              schema (thread.started / task.completed / error). Resume is
#              server-side, so the prompt_too_long failure mode may not even
#              manifest the same way. Falls through to false → dispatcher
#              attempts resume; relies on AGENT_TIMEOUT (INV-13) as the
#              safety net for hangs. PTL recovery for codex is tracked as a
#              follow-up — needs a real codex JSONL fixture to write the
#              gate against, not guessed.
#   kiro     — by design. Kiro has no session model (every invocation is a
#              fresh conversation, see lib-agent.sh kiro branch), so PTL
#              cannot occur and "completed" has no meaning. Returning false
#              here lets the dispatcher run the next dev-resume which the
#              wrapper transparently turns into dev-new.
#   opencode — NOT covered, same reasoning as codex. Server-side sessions
#              and unknown PTL event shape; needs a real fixture.
#
# Until coverage is extended, non-claude PTL crashes will surface via the
# normal stale-detection path (Step 5b) instead of this gate. That's a
# correct degradation — slower recovery (one full tick cycle) but no risk
# of false-positive auto-recovery on a CLI whose JSON we haven't observed.
#
# [INV-101] (#356) Backend seam: the log this function reads lives on the
# box that runs the dev wrapper, NOT necessarily the box running this tick.
# Under `EXECUTION_BACKEND=remote-aws-ssm` the read is dispatched to the
# execution host via `_remote_session_log_probe` (mirrors [INV-30]'s
# `pid_alive` shape). The local branch below is BYTE-IDENTICAL to the
# pre-#356 implementation.
is_session_completed() {
  local issue_num="$1"
  local reason_var="${2:-}"
  local end_ts_var="${3:-}"
  # Gate on dev-side CLI per [INV-37] — this function parses the dev
  # wrapper's log, so the dispatcher-side $AGENT_CMD (project default)
  # is the wrong value to check under split-CLI deployments
  # (e.g. AGENT_CMD=claude AGENT_DEV_CMD=codex).
  local _dev_cmd="${AGENT_DEV_CMD:-${AGENT_CMD:-claude}}"
  [ "$_dev_cmd" = "claude" ] || return 1

  local last_line log_file _end_epoch=""
  if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]; then
    # [INV-101] Remote branch: the log lives on the execution host. The
    # driver echoes the last `{"type":"result"...}` line on stdout line 1
    # and (only when line 1 is non-empty) the log's mtime as a Unix epoch
    # on line 2. SSM error/timeout/no-match all collapse to empty output —
    # fail-closed, never fabricate a completed state (see the driver's own
    # contract comment).
    local _probe_out
    _probe_out=$(_remote_session_log_probe "$issue_num")
    last_line=$(printf '%s\n' "$_probe_out" | sed -n '1p')
    _end_epoch=$(printf '%s\n' "$_probe_out" | sed -n '2p')
  else
    log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
    [ -r "$log_file" ] || return 1

    # Claude --output-format json emits one full JSON object per line, including
    # a final `{"type":"result", ...}` with stop_reason and terminal_reason on
    # clean exit. We must NOT regex-truncate this object — it contains nested
    # objects (`usage`) and the model's `result` string (which routinely
    # contains `}` inside markdown / code blocks). Instead grab the whole last
    # `result` line and let jq parse it.
    #
    # Multiple result objects are possible (resume cycles): the LAST line wins.
    last_line=$(grep '^{"type":"result"' "$log_file" 2>/dev/null | tail -1)
  fi
  [ -n "$last_line" ] || return 1

  local fields
  fields=$(jq -er '"\(.stop_reason // "")|\(.terminal_reason // "")"' <<<"$last_line" 2>/dev/null) || return 1

  local terminal_reason="${fields##*|}"

  if [ "$fields" = "end_turn|completed" ] || [ "$terminal_reason" = "prompt_too_long" ]; then
    [ -n "$reason_var" ] && printf -v "$reason_var" '%s' "$terminal_reason"
    if [ -n "$end_ts_var" ]; then
      # INV-35: derive session-end ISO-8601 timestamp from the log file's
      # mtime. The wrapper writes the final "Agent exited" log line at
      # session end so mtime is a reliable proxy across any agent CLI; the
      # claude result-JSON itself does not carry a date. Empty on date(1)
      # failure — the caller treats empty as "no time filter", which is
      # safe (we surface ALL bot comments rather than miss a recent one).
      local _mtime_iso=""
      if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]; then
        [ -n "$_end_epoch" ] && _mtime_iso=$(_epoch_to_iso "$_end_epoch")
      else
        _mtime_iso=$(date -u -r "$log_file" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      fi
      printf -v "$end_ts_var" '%s' "$_mtime_iso"
    fi
    return 0
  fi
  return 1
}

# _epoch_to_iso <epoch> — Unix epoch seconds → ISO-8601 UTC. Empty on
# failure. Used by is_session_completed's remote branch to convert the
# execution host's log mtime (fetched as an epoch over SSM, since we can't
# `stat` a remote path from here) into the same ISO-8601 shape the local
# branch derives via `date -u -r`.
_epoch_to_iso() {
  local epoch="$1"
  [[ "$epoch" =~ ^[0-9]+$ ]] || { echo ""; return; }
  date -u -d "@${epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r "${epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || echo ""
}

# _session_log_probe_driver_path — resolves the session-log-probe driver
# script path via parameter expansion (no `dirname`, PATH-scrubbed-safe),
# honoring the test override (`_SESSION_LOG_PROBE_DRIVER_OVERRIDE`). Shared
# by `_remote_session_log_probe` and `_reset_session_log` so the resolution
# logic (mirroring `_remote_pid_alive_query`'s shape) lives in one place.
_session_log_probe_driver_path() {
  if [ -n "${_SESSION_LOG_PROBE_DRIVER_OVERRIDE:-}" ]; then
    printf '%s\n' "$_SESSION_LOG_PROBE_DRIVER_OVERRIDE"
  else
    local _src="${BASH_SOURCE[0]:-$0}"
    printf '%s\n' "${_src%/*}/session-log-probe-remote-aws-ssm.sh"
  fi
}

# _remote_session_log_probe <issue_num> — [INV-101] (#356). Synchronous SSM
# query into the dev wrapper's per-issue log on the execution host.
#
# ALWAYS returns 0 — driver failure (rc≠0: SSM transport fault, timeout,
# validation error) collapses to empty stdout, exactly like "log not found /
# no result line yet". The caller (is_session_completed) treats empty
# identically in both cases: not completed, fail-closed to the existing
# residual park. This is deliberately asymmetric with [INV-30]'s ALIVE-bias
# on indeterminate — there, deferring a crash declaration is the safe
# default; here, NOT fabricating a completed/terminal state is the safe
# default (a false "completed" could route a live/crashed session through
# the wrong branch).
_remote_session_log_probe() {
  local issue_num="$1"
  local driver
  driver="$(_session_log_probe_driver_path)"

  local out rc
  out=$(bash "$driver" --probe "$issue_num" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out"
  return 0
}

# _reset_session_log <issue_num> — [INV-101] (#356) backend-aware truncate.
# Companion seam to `_remote_session_log_probe`: once a remote session
# becomes detectable as completed/PTL, the two existing recovery-truncate
# call sites (`handle_completed_session_routing`'s failed-substantive
# branch, and the tick's INV-12 PTL branch) must reset the log ON THE SAME
# HOST the probe read it from — a controller-side bare `: > <path>` would
# create/truncate the WRONG file while the execution host's stale result
# line survives, turning the park into an infinite dev-new loop (worse than
# today's deadlock). Returns 0 on success, non-zero on failure; callers keep
# their existing fail-closed skip-dispatch behavior on non-zero.
_reset_session_log() {
  local issue_num="$1"
  if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]; then
    local driver
    driver="$(_session_log_probe_driver_path)"
    bash "$driver" --truncate "$issue_num" >/dev/null 2>&1
    return $?
  fi
  local _log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
  : > "$_log_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# INV-35: review-verdict classification for completed dev sessions.
# ---------------------------------------------------------------------------
#
# classify_recent_review_verdict <issue_num> <session_end_iso> <verdict_var> <cause_var> [dev_actionable_var]
#
# Reads issue comments, finds the newest comment that:
#   (a) was authored by ${BOT_LOGIN} (or matches the session-id-binding
#       fallback when BOT_LOGIN is empty per the gh-api-user-403 pattern),
#   (b) was created strictly after <session_end_iso>,
#   (c) has body containing a `<!-- review-verdict: ... -->` HTML-comment
#       trailer — OR is a generic verdict comment without a trailer (legacy).
#
# Out-vars receive:
#   verdict_var ∈ { none, passed, failed-substantive, failed-non-substantive }
#   cause_var   — non-empty only when verdict is failed-non-substantive.
#   dev_actionable_var — INV-92 (#298) OPTIONAL 5th arg. When supplied, receives
#       `true` or `false`: `false` only when the failed-substantive trailer
#       carried `dev-actionable=false`; `true` otherwise (absent token ⇒ `true`,
#       the zero-regression default). The ≥10 existing 4-arg callers do not pass
#       this var and are unaffected — the write is GUARDED on `[ -n "$_da_var" ]`
#       so it never `printf -v` into an empty name (which would crash under set -u).
#
# Always returns 0. See docs/designs/inv35-review-aware-resume.md § 5 and
# docs/designs/issue-298-verdict-finding-classification.md § 3.5.
classify_recent_review_verdict() {
  local issue_num="$1"
  local session_end="$2"
  local verdict_var="$3"
  local cause_var="$4"
  # INV-92 (#298): optional 5th out-param. "${5:-}" is set -u-safe; the write
  # below is guarded on a non-empty name so the 4-arg callers never trip it.
  local _da_var="${5:-}"

  printf -v "$verdict_var" '%s' "none"
  printf -v "$cause_var"   '%s' ""
  # Default the dev-actionable out-var to "true" (absent token ⇒ today's
  # behavior). Guarded so a 4-arg caller (empty name) is a no-op.
  [ -n "$_da_var" ] && printf -v "$_da_var" '%s' "true"

  # Build the actor predicate. When BOT_LOGIN is empty (the gh-api-user-403
  # fallback), drop actor-binding and rely on FALLBACK_SESSION_ID embedded
  # in the comment body (the same "Review Session: <sid>" trailer the
  # review wrapper already emits per autonomous-review.sh:588-590).
  # Over itp_list_comments' normalized array, `author` IS the login string
  # (spec §3.3: `user.login` incl `[bot]` verbatim), so the actor binding is a
  # flat `.author == BOT_LOGIN` exact-eq — equivalent to the pre-refactor
  # `.author.login == BOT_LOGIN` over the raw `.comments[]`.
  #
  # #389 (4th occurrence of the BOT_LOGIN-empty class; siblings fixed in
  # #341 rounds 13/15): BOT_LOGIN is NEVER set in the dispatcher's own
  # process (it is resolved only inside autonomous-review.sh's SEPARATE
  # process) and FALLBACK_SESSION_ID is never assigned anywhere in this
  # codebase — so the pre-#389 refuse-to-classify branch below was the
  # UNCONDITIONAL path in every real deployment, parking every
  # completed-session pending-dev issue at INV-12 even with a genuine
  # verdict trailer present. Fix: STRUCTURAL authentication (the
  # convergence breaker's `authentic_verdict` round-14 posture) — a
  # genuine `emit_verdict_trailer` comment's ENTIRE body is the bare
  # trailer line, so an end-to-end anchored whole-body match works
  # without an actor signal. Two hardenings beyond the breaker's anchor,
  # because HERE the match drives dispatch (a forged `failed-substantive`
  # burns a MAX_RETRIES slot; at the breaker it can only trip/shield a
  # stall):
  #   1. EXACT grammar, not `[^>]*`: verdict is whitelisted
  #      (passed|failed-substantive|failed-non-substantive) and only the
  #      known `cause=`/`dev-actionable=` tokens may follow — mirroring
  #      the downstream trailer_line grep, so under this branch neither
  #      the legacy no-trailer fallback nor the unknown-verdict `case *)`
  #      arm is reachable (an anchored-but-unknown body never becomes a
  #      candidate; it stays verdict=none → INV-12 park). Whitespace
  #      INSIDE the trailer is `[ \t]` (horizontal only), NOT
  #      `[[:space:]]`: Oniguruma `[[:space:]]` matches `\n`, so an
  #      embedded-newline body would pass this predicate yet fail the
  #      line-oriented downstream grep and drop into the legacy
  #      fallback — exactly the unreachability hole the exact grammar
  #      exists to close (codex review, PR #390). Only the post-`-->`
  #      tail keeps `[[:space:]]*` (trailing-newline tolerance).
  #   2. In GH_AUTH_MODE=app, additionally require
  #      `authorKind != "human"` — the genuine review wrapper posts under
  #      a GitHub App identity (`…[bot]` login ⇒ authorKind=bot), so this
  #      shrinks the forgery surface from "anyone who can comment" to
  #      "bot/App actors on the repo". Deliberately NOT applied in token
  #      mode: the round-13 BLOCKING finding proved a genuine token-mode
  #      verdict is posted under the shared PAT identity and normalizes
  #      to authorKind=human — an unconditional gate would reject every
  #      genuine verdict and reintroduce the fleet-wide park this fix
  #      removes. Token-mode residual (a human posting a byte-for-byte
  #      bare trailer as their whole comment) is the same documented,
  #      accepted exposure as at the breaker's call sites.
  local _anchored_trailer_re='^<!--[ \t]*review-verdict:[ \t]*(passed|failed-substantive|failed-non-substantive)([ \t]+(cause=[a-zA-Z0-9_-]+|dev-actionable=[a-z]+))*[ \t]*-->[[:space:]]*$'
  local actor_predicate
  if [ -n "${BOT_LOGIN:-}" ]; then
    actor_predicate=".author == \"${BOT_LOGIN}\""
  elif [ -n "${FALLBACK_SESSION_ID:-}" ]; then
    actor_predicate="(.body | test(\"Review Session.*${FALLBACK_SESSION_ID}\"))"
  else
    actor_predicate="(.body | test(\"${_anchored_trailer_re}\"))"
    if [ "${GH_AUTH_MODE:-token}" = "app" ]; then
      actor_predicate="((.authorKind // \"human\") != \"human\") and ${actor_predicate}"
    fi
  fi

  # Pull the newest qualifying comment body. Strict `>` on createdAt
  # excludes a comment timestamped exactly at session end (rare, but the
  # design pins this for determinism). `.id` tie-breaks same-second
  # comments (monotonic per issue; mirrors the sibling breaker's
  # `sort_by(.createdAt // "", .id // 0)` — codex review, PR #390).
  local newest_body
  newest_body=$(itp_list_comments "$issue_num" 2>/dev/null \
    | jq -r "[.[] | select(${actor_predicate} and (.createdAt > \"${session_end}\"))] | sort_by(.createdAt // \"\", .id // 0) | last | .body // empty" \
    2>/dev/null)

  [ -n "$newest_body" ] || return 0

  # Match the trailer — first occurrence wins (TC-INV35-CL-007 pins this
  # to "first" rather than "last" so a quoted prior verdict can't override
  # the actual current verdict in pathological cases).
  #
  # INV-92 (#298): the optional `dev-actionable=true|false` token rides the
  # failed-substantive trailer. The regex now tolerates EITHER optional token
  # (`cause=…` for failed-non-substantive, `dev-actionable=…` for
  # failed-substantive) in the post-verdict span. The verdict + each token are
  # extracted independently below, so a legacy `cause`-only trailer and a new
  # `dev-actionable`-only trailer both parse.
  local trailer_line
  trailer_line=$(printf '%s' "$newest_body" | grep -oE '<!--[[:space:]]*review-verdict:[[:space:]]*[a-z-]+([[:space:]]+(cause=[a-zA-Z0-9_-]+|dev-actionable=[a-z]+))*[[:space:]]*-->' | head -1)

  if [ -z "$trailer_line" ]; then
    # Legacy: bot-authored comment with no trailer is conservatively
    # treated as failed-substantive so a pre-INV-35 in-flight verdict
    # routes to the safe fresh-dev branch (rather than silently no-op
    # like 'passed' would). See design §4 backwards-compat note.
    printf -v "$verdict_var" '%s' "failed-substantive"
    return 0
  fi

  # Parse trailer fields.
  # Avoid generic local names (v, c) — they would shadow the caller-supplied
  # var names that printf -v resolves through, e.g. caller passes "v" as the
  # out-var name and `local v` would mask it.
  local _parsed_verdict _parsed_cause _parsed_dev_actionable
  _parsed_verdict=$(printf '%s' "$trailer_line" | sed -nE 's/<!--[[:space:]]*review-verdict:[[:space:]]*([a-z-]+).*-->/\1/p')
  _parsed_cause=$(printf '%s' "$trailer_line" | sed -nE 's/.*cause=([a-zA-Z0-9_-]+).*/\1/p')
  # INV-92 (#298): extract the optional dev-actionable token. Absent ⇒ "" here;
  # the out-var stays at its "true" default (set at function entry). Only an
  # explicit `dev-actionable=false` flips it to false. `sed -n …/p` prints
  # nothing when the token is absent, so `_parsed_dev_actionable` is empty.
  _parsed_dev_actionable=$(printf '%s' "$trailer_line" | sed -nE 's/.*dev-actionable=([a-z]+).*/\1/p')

  case "$_parsed_verdict" in
    passed|failed-substantive|failed-non-substantive)
      printf -v "$verdict_var" '%s' "$_parsed_verdict"
      [ "$_parsed_verdict" = "failed-non-substantive" ] && printf -v "$cause_var" '%s' "$_parsed_cause"
      # Only `failed-substantive` + an explicit `dev-actionable=false` sets the
      # out-var to false; everything else leaves it at the "true" default.
      if [ -n "$_da_var" ] && [ "$_parsed_verdict" = "failed-substantive" ] \
         && [ "$_parsed_dev_actionable" = "false" ]; then
        printf -v "$_da_var" '%s' "false"
      fi
      ;;
    *)
      # Unknown verdict token — treat as missing-trailer (failed-substantive).
      printf -v "$verdict_var" '%s' "failed-substantive"
      ;;
  esac
  return 0
}

# Echo the count of review-aware-flip markers scoped to a given dev session.
# Used by Step 4b.5.1 to enforce REVIEW_RETRY_LIMIT on a per-session basis
# (a fresh dev_new resets the counter, by design).
count_review_aware_flips() {
  local issue_num="$1"
  local session_id="$2"
  [ -n "$session_id" ] || { printf '%s' "0"; return 0; }
  itp_list_comments "$issue_num" 2>/dev/null \
    | jq -r "[.[].body | select(contains(\"<!-- review-aware-flip:non-substantive\")) | select(contains(\"session=${session_id}\"))] | length" \
    2>/dev/null || printf '%s' "0"
}

# ---------------------------------------------------------------------------
# INV-105 (#297): convergence circuit-breaker helpers.
# ---------------------------------------------------------------------------

# convergence_canonical <verdict> <cause> <dev_actionable>
#
# Echoes the canonical trailer string `{verdict}|{cause}|{dev-actionable}`
# (pipe-delimited, empty string for absent fields), derived from the
# `classify_recent_review_verdict` OUT-VARS — NOT body text ([INV-105] C1/C2). This
# is the SINGLE source of truth for the convergence match key: `convergence_trailer_hash`
# hashes it for the compact marker key, and `count_frozen_convergence_rounds` joins
# each zero-commit round's preceding verdict against it ([P1] finding 1: only rounds
# whose classified trailer matches the ACTIVE {head, trailer} case count).
convergence_canonical() {
  printf '%s|%s|%s' "${1:-}" "${2:-}" "${3:-}"
}

# convergence_trailer_hash <verdict> <cause> <dev_actionable>
#
# Echoes a stable hash of the canonical string (see convergence_canonical), used as
# the SECONDARY convergence gate (same verdict CLASS across rounds) and as the
# idempotency-marker + report key. `review-comment-id` / `dev-session-id` /
# timestamps are deliberately EXCLUDED from the hash — each is fresh per round, so
# including them would make strict key-equality never match (codex R2/C2).
#
# Prefers `sha1sum` (12-char prefix, stable + collision-resistant enough for an
# idempotency key); falls back to `cksum` when sha1sum is absent so the helper
# never aborts the tick under `set -e`.
convergence_trailer_hash() {
  local _canon
  _canon="$(convergence_canonical "${1:-}" "${2:-}" "${3:-}")"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$_canon" | sha1sum | cut -c1-12
  else
    printf '%s' "$_canon" | cksum | tr -d ' ' | cut -c1-12
  fi
}

# _frozen_convergence_rounds_json <issue_num> <frozen_head> <active_canonical>
#
# Emits a JSON array of the COMPLETED zero-commit dev-resume rounds on
# `<frozen_head>` that belong to the ACTIVE convergence case — each element is
# `{createdAt}` (the round comment's timestamp), sorted ascending. This is the
# single source of truth backing BOTH `count_frozen_convergence_rounds` (its
# length) and the [INV-105] report's per-round timestamp evidence ([P1] finding 2).
#
# Derivation ([INV-105] C1/C9a): rounds are the pre-existing per-round dispatcher
# comment (`dispatcher-tick.sh` Step 5b, the [INV-06]-guarded "Dev process exited
# (no new commits since last review at `<head>`)…"), which fires exactly once per
# completed zero-commit round and embeds the frozen head. #297 writes NO per-round
# breadcrumb of its own — a new per-round write on a NON-trip round would
# reintroduce the C7 orphan-artifact TOCTOU. We SCAN the already-emitted comment.
#
# JOIN ([P1] finding 1 — the fix for early-trip / forever-suppression): counting
# EVERY frozen-head zero-commit comment is wrong — stale `failed-non-substantive`
# or `dev-actionable=false` history on the SAME SHA (from an earlier, now-resolved
# case) would either trip the breaker early or, via the old blanket
# `non-actionable-finding:<head>` zero-out, suppress a genuine later
# `dev-actionable=true` non-convergence forever. Instead, each round is joined to
# the review VERDICT it was reacting to — the newest `<!-- review-verdict: … -->`
# trailer comment strictly BEFORE the round comment — and counted ONLY when that
# verdict's canonical `{verdict}|{cause}|{dev-actionable}` equals `<active_canonical>`
# (the current `failed-substantive|<cause>|true` case, per convergence_canonical).
# So the count is the ACTIVE {head, trailer} window, not the whole head's history:
# a `dev-actionable=false` round's canonical (`…|false`) or a non-substantive
# round's (`failed-non-substantive|…`) never matches and is excluded — no separate
# #298-marker zero-out needed (a false round is handled by Branch B′ precedence for
# the CURRENT round, and excluded from the count for PRIOR rounds).
#
# ROUND-COMMENT AUTHENTICITY (review round-7 [P1], tightened round-15
# [BLOCKING]): a bare `contains()` over the status phrase counted ANY comment
# quoting it — a human/reviewer comment that quotes the Step-5b line ("Dev
# process exited (no new commits since last review at `<head>`)…") inflated
# the round count and could trip the breaker early on a still-converging
# issue. Two filters restore authenticity, both matching how the round
# comment is actually emitted (dispatcher-tick.sh Step 5b via itp_post_comment
# under the pipeline's own token ⇒ normalized authorKind=self; a
# resumed/legacy tick posting as a [bot] is authorKind=bot — still machine):
#   1. `authorKind != "human"` — spec §3.3 [M5] discriminator; a human quoting
#      the line is excluded when BOT_LOGIN is set (`$strict_author != "0"`).
#      GATED off (accepted unconditionally) when BOT_LOGIN is empty — the
#      call site's PERMANENT reality — because the provider then cannot
#      derive `self` and the dispatcher's OWN genuine comments also
#      normalize to `human`; see below for why this residual gap is now
#      closed by filter 2 alone.
#   2. **round-15 [BLOCKING]**: exact body EQUALITY against the full literal
#      dispatcher-tick.sh Step 5b emits — not merely `startswith`. The prior
#      `startswith` anchor authenticated any comment BEGINNING with the exact
#      sentence, including a human's genuine quote-plus-commentary ("Dev
#      process exited (no new commits since last review at `<head>`).
#      Moving to pending-dev for retry. Actually I disagree, let's discuss.")
#      — that forgery inflated the round count toward tripping the breaker on
#      fewer than the required N genuine rounds, especially exploitable
#      because filter 1 is UNCONDITIONALLY dropped when BOT_LOGIN is empty
#      (the dispatcher's own comments need it dropped to be genuine rounds at
#      all — see round-13's identical rationale on the preceding-verdict
#      side). The round comment's ENTIRE body is this one fixed sentence
#      (dispatcher-tick.sh:671 — no free-text suffix, no per-round variation
#      beyond `<head>`), so equality is the correct, tighter anchor: it
#      authenticates the genuine comment exactly and rejects ANY quote with
#      so much as one extra trailing character, closing the gap `startswith`
#      left open without needing an actor signal that does not exist here.
#
# PRECEDING-VERDICT AUTHENTICITY (review round-11 [P1] BLOCKING, corrected
# round-13 [BLOCKING]): the ROUND comment was authenticated (above), but the
# PRECEDING verdict trailer ($pv, below) was NOT — any comment containing a
# `<!-- review-verdict: … -->`-shaped string, however posted, could be picked
# as "the verdict this round reacted to". A maintainer/reviewer comment
# QUOTING a trailer (e.g. discussing a past verdict, or pasting one for
# context) posted between the real bot verdict and the Step-5b round comment
# would win the `last` selection over the genuine trailer, letting arbitrary
# discussion comments trip OR suppress the breaker.
#
# round-11's first fix gated on `.author == BOT_LOGIN` when set, else
# `authorKind != "human"`. **That fallback was WRONG (round-13 BLOCKING)**:
# `BOT_LOGIN` is NEVER set in the dispatcher's own process (it is resolved only
# inside `autonomous-review.sh`'s SEPARATE process via `gh api user`, and never
# threaded to `dispatcher-tick.sh`/`lib-dispatch.sh`) — so this call site
# ALWAYS takes the empty-BOT_LOGIN branch, in EVERY `GH_AUTH_MODE`. In
# `GH_AUTH_MODE=token` specifically, the review wrapper's genuine verdict
# comment is posted under the SAME shared PAT identity as everything else, so
# the provider normalizes it to `authorKind=human` (it cannot derive `self`
# without `BOT_LOGIN`) — `authorKind != "human"` therefore REJECTED EVERY
# GENUINE verdict, making `count_frozen_convergence_rounds` permanently 0 and
# Branch B″ dead in the common token-mode topology. (Reproduced: 3 genuine
# frozen `failed-substantive` rounds, all `authorKind=human` — pre-fix count
# was 0.)
#
# Fix: use the SAME structural signal `recent_review_verdict_body` already
# relies on to distinguish a genuine trailer comment from prose that merely
# mentions/quotes one — `lib-review-verdict.sh::emit_verdict_trailer` posts the
# trailer as its OWN bare comment whose body is JUST the trailer line, no
# human text ("posting an additional, separate comment … so it doesn't render
# in the GitHub issue UI" — see that function's header). So an ANCHORED
# full-body match against the trailer shape is authorship-independent and
# reliably TRUE for the genuine wrapper-emitted comment, FALSE for a human's
# "Just quoting for context: <!-- review-verdict: ... -->" (prose BEFORE the
# trailer). `.author == BOT_LOGIN` is kept as an ADDITIONAL, strictly-stronger
# check for the rare case BOT_LOGIN IS somehow set (defense in depth; never
# observed live today). A round whose only candidate verdict fails this gate
# has no authenticated `$pv` and is excluded (fail-closed toward NOT tripping)
# — the #286-adjacent MISS bias this breaker is designed for.
#
# round-14 [Critical]: the FIRST round-13 fix used `startswith` alone (not
# anchored at the end), which also authenticates a forged comment that pastes
# the genuine trailer text and then appends MORE content after it (e.g. a
# forged matching trailer with trailing prose, or two trailers concatenated).
# With `BOT_LOGIN` empty — the permanent reality at this call site — that
# `startswith` check was the ENTIRE gate, so such a forgery could manufacture
# a false trip or shadow a genuine trailer via the `last`-before-round
# selection, reopening the exact round-11 threat model for a slightly
# different forgery shape. Tightened to a full `^...$`-anchored match — see
# `authentic_verdict(c)` below for the exact pattern and its residual
# (author-blind, unavoidable) exposure to a byte-for-byte bare-trailer copy.
#
# Fail-closed toward NOT tripping: an empty/error fetch yields `[]` (biases to
# MISS per R4). The trailer parse mirrors classify_recent_review_verdict: verdict
# = first `[a-z-]+` token; cause captured ONLY for failed-non-substantive; absent
# dev-actionable ⇒ "true". jq 1.6 Oniguruma `capture()` (same engine the sibling
# session-id/dispatcher-token reads use). The frozen head is 7-40 lowercase hex.
_frozen_convergence_rounds_json() {
  local issue_num="$1"
  local frozen_head="$2"
  local active_canonical="$3"
  { [ -n "$frozen_head" ] && [ -n "$active_canonical" ]; } || { printf '%s' "[]"; return 0; }

  local _comments
  _comments=$(itp_list_comments "$issue_num" 2>/dev/null) || { printf '%s' "[]"; return 0; }

  # authorKind strictness gate: the normalized authorKind is only meaningful
  # when BOT_LOGIN is set (providers derive `self` from author==BOT_LOGIN;
  # with it EMPTY, a token-mode dispatcher's own comments normalize to
  # `human` and the author filter would exclude GENUINE rounds — breaker
  # dead in GH_AUTH_MODE=token). Mirror the sibling verdict scan's
  # empty-BOT_LOGIN branching (classify path ~:965): with BOT_LOGIN empty,
  # drop the author filter and rely on the startswith() anchor alone
  # (mid-body quotes still excluded; a human pasting the EXACT line at
  # offset 0 is accepted — the pre-existing exposure, strictly better than
  # the old contains() which accepted any placement). The SAME flag also
  # gates the preceding-verdict actor predicate below (round-11 [P1]) — one
  # source of truth for "is BOT_LOGIN available to bind against".
  local _strict_author=1
  [ -n "${BOT_LOGIN:-}" ] || _strict_author=0

  # jq program:
  #  - `canon(body)`: parse the review-verdict trailer into the canonical
  #    `{verdict}|{cause}|{dev-actionable}`, mirroring classify_recent_review_verdict
  #    (cause only for failed-non-substantive; absent dev-actionable ⇒ true).
  #  - `authentic_verdict(c)`: STRUCTURAL authenticity for a CANDIDATE verdict
  #    comment `c` (round-11, corrected round-13 [BLOCKING], tightened round-14
  #    [Critical] — see below) — the body MUST match the trailer shape
  #    `emit_verdict_trailer` actually posts, ANCHORED end-to-end (`^...$`, no
  #    leading or trailing bytes) — not merely `startswith`. This is
  #    authorship-independent, so it works identically whether or not
  #    `BOT_LOGIN` is available. `.author == $bot_login` is layered on TOP as
  #    an additional (strictly stronger) requirement on the rare path where
  #    `BOT_LOGIN` happens to be set — never the SOLE gate, since the empty-
  #    `BOT_LOGIN` case (the observed live reality at this call site) must
  #    still authenticate correctly.
  #  - round-14 [Critical]: round-13's fix used `startswith` alone, which
  #    authenticates ANY comment merely BEGINNING with the trailer text —
  #    including a human's forged comment that pastes the trailer verbatim
  #    with extra prose or another trailer APPENDED after it (e.g. a fake
  #    matching trailer followed by more text, still passes `startswith`).
  #    With `BOT_LOGIN` empty — the call site's permanent reality — that was
  #    the entire gate, so such a forgery could manufacture a false trip or
  #    shadow a genuine trailer via the `last`-before-round selection. The
  #    full-anchor match closes this: `emit_verdict_trailer` posts NOTHING
  #    else in the comment body, so a genuine trailer always matches the
  #    anchored pattern exactly, while a forgery with ANY extra content
  #    (leading prose OR trailing content) fails it. This does not (and
  #    cannot, absent an actor signal) defend against a human posting a
  #    byte-for-byte copy of a genuine bare trailer with nothing else in the
  #    comment — the same fundamental, already-documented residual exposure
  #    the sibling round-comment check accepts (line ~1307 above: "a human
  #    pasting the EXACT line at offset 0 is accepted").
  #  - For each round comment on the frozen head, find the newest AUTHENTIC
  #    verdict trailer comment with createdAt < the round's, compute its
  #    canonical, keep the round iff that canonical == $ac. Emit the matched
  #    rounds' {createdAt}, sorted.
  jq -c --arg head "$frozen_head" --arg ac "$active_canonical" --arg strict_author "$_strict_author" --arg bot_login "${BOT_LOGIN:-}" '
    def trailer($b):
      ($b | capture("<!--[[:space:]]*review-verdict:[[:space:]]*(?<v>[a-z-]+)(?<rest>[^>]*)-->"; "g") ) // null;
    def canon($b):
      trailer($b) as $t
      | if $t == null then null
        else
          ($t.v) as $v
          | ( $t.rest | (capture("cause=(?<c>[a-zA-Z0-9_-]+)").c) // "" ) as $c
          | ( $t.rest | (capture("dev-actionable=(?<d>[a-z]+)").d) // "true" ) as $d
          | (if $v == "failed-non-substantive" then $c else "" end) as $cc
          | "\($v)|\($cc)|\($d)"
        end;
    def authentic_verdict(c):
      (c.body | test("^<!--[[:space:]]*review-verdict:[[:space:]]*[a-z-]+[^>]*-->[[:space:]]*$"))
      and (if $strict_author == "0" then true else c.author == $bot_login end);
    ( [ .[] | select(.body | type == "string") ] | sort_by(.createdAt) ) as $all
    | [ $all[]
        | select(($strict_author == "0") or (.authorKind != "human"))
        | select(.body == "Dev process exited (no new commits since last review at `" + $head + "`). Moving to pending-dev for retry.")
        | . as $round
        | ( [ $all[] | select((.createdAt < $round.createdAt) and authentic_verdict(.) and (canon(.body) != null)) ]
            | last ) as $pv
        | select($pv != null and (canon($pv.body) == $ac))
        | {createdAt: $round.createdAt}
      ]
  ' 2>/dev/null <<<"$_comments" || printf '%s' "[]"
}

# count_frozen_convergence_rounds <issue_num> <frozen_head> <active_canonical>
#
# Echoes the number of ACTIVE-case completed zero-commit dev-resume rounds on
# `<frozen_head>` — the length of `_frozen_convergence_rounds_json` ([INV-105]
# C1/C9a + [P1] finding 1: only rounds whose preceding verdict matches the active
# `{verdict}|{cause}|{dev-actionable}` canonical count). Fail-closed to 0.
count_frozen_convergence_rounds() {
  local _rounds _n
  _rounds="$(_frozen_convergence_rounds_json "$1" "$2" "${3:-}")"
  # `|| echo 0` guards the substitution under `set -euo pipefail` for symmetry with
  # the live Branch B″ site (which inlines the guarded variant). `_rounds` is always
  # `[]` or valid `jq -c` output today, but a future live caller must not risk a
  # tick abort here.
  _n="$(jq -r 'length' 2>/dev/null <<<"$_rounds" || echo 0)"
  printf '%s' "${_n:-0}"
}

# recent_review_verdict_body <issue_num> <session_end_iso>
#
# Echoes the body of the newest BOT-authored review VERDICT/FINDINGS comment
# created after the dev session ended — the verbatim repeated finding shown in
# the [INV-105] convergence report's evidence block. Mirrors
# `classify_recent_review_verdict`'s actor-predicate + strict-`>` timestamp
# selection (spec §3.3: `author` is the login string incl `[bot]`), but returns
# the raw body rather than parsing the trailer. Best-effort: an empty/error fetch
# yields empty (the report omits the excerpt gracefully) — never aborts the tick.
#
# EXCLUDES two wrapper-metadata comment shapes the normal review-round posting
# sequence appends AFTER the agent's own findings comment (same bot actor, later
# timestamp), which would otherwise win the plain "newest" selection
# `classify_recent_review_verdict` uses (that function WANTS the newest,
# including a trailer-only comment — see lib-review-verdict.sh's
# emit_verdict_trailer header note — because it parses the trailer. This
# function wants the human-readable finding text instead):
#   - `Reviewed HEAD: ...` — the per-round forensic-attribution comment
#     (autonomous-review.sh, posted right after the agent's findings comment).
#   - a BARE `<!-- review-verdict: ... -->` trailer with no other content
#     (emit_verdict_trailer's entire body IS the trailer literal).
# Both are recognized structurally (body starts with the exact literal), not by
# a magic marker, so a real findings comment that merely mentions "Reviewed
# HEAD" or a verdict trailer mid-body is never excluded.
#
# BINDING (round-15 [BLOCKING], corrects a THIRD occurrence of the round-13
# BOT_LOGIN-empty class of bug): the pre-fix code returned empty outright
# when neither `BOT_LOGIN` nor `FALLBACK_SESSION_ID` was set — but exactly
# like `_frozen_convergence_rounds_json`'s preceding-verdict join (round-13),
# `BOT_LOGIN` is NEVER set in the dispatcher's own process (only inside
# `autonomous-review.sh`'s SEPARATE process) and `FALLBACK_SESSION_ID` is
# never assigned anywhere in this codebase — so this call site ALWAYS took
# the empty branch, meaning the convergence report's evidence excerpt was
# permanently "(verdict body unavailable...)" in every real deployment.
# (Reproduced: with BOT_LOGIN/FALLBACK_SESSION_ID both unset and a genuine
# `Review findings:` comment present after session_end, the pre-fix function
# returned nothing.)
#
# Fix: when NEITHER actor signal is available, fall back to the SAME kind of
# structural anchor round-13/14 introduced for the preceding-verdict join — a
# genuine review-wrapper verdict/findings comment always STARTS WITH the
# literal `Review findings:` or `Review PASSED` (the canonical first-line
# prefix `post-verdict.sh`'s COMPOSED body and `lib-review-artifact.sh`'s
# artifact-verdict body always carry; `_classify_verdict_body` keys off the
# same prefixes). This is author-independent, so it authenticates correctly
# with no actor signal at all — the same posture the round-comment and
# preceding-verdict checks already take at this call site. This is a
# best-effort EVIDENCE excerpt (never gates the breaker's trip decision, only
# quotes text into the human-readable report), so the residual exposure to a
# human posting a comment that happens to start with the exact same literal
# is accepted here too, mirroring the already-documented residual elsewhere
# in this function.
recent_review_verdict_body() {
  local issue_num="$1"
  local session_end="$2"
  local actor_predicate
  if [ -n "${BOT_LOGIN:-}" ]; then
    actor_predicate=".author == \"${BOT_LOGIN}\""
  elif [ -n "${FALLBACK_SESSION_ID:-}" ]; then
    actor_predicate="(.body | test(\"Review Session.*${FALLBACK_SESSION_ID}\"))"
  else
    actor_predicate='((.body | startswith("Review findings:")) or (.body | startswith("Review PASSED")))'
  fi
  local exclude_predicate='((.body | startswith("Reviewed HEAD:")) or (.body | startswith("<!-- review-verdict:"))) | not'
  itp_list_comments "$issue_num" 2>/dev/null \
    | jq -r "[.[] | select(${actor_predicate} and (.createdAt > \"${session_end}\") and (${exclude_predicate}))] | sort_by(.createdAt) | last | .body // empty" \
    2>/dev/null
}

# ---------------------------------------------------------------------------
# INV-35 Step 4b.5.1: review-aware routing for `completed` sessions.
# ---------------------------------------------------------------------------
#
# handle_completed_session_routing <issue_num> <session_id> <session_end_iso>
#
# Returns 0 always (caller `continue`s after this branch).
#
# Routes a `pending-dev` issue whose prior dev session reached
# `end_turn|completed` per the verdict-classification table in
# docs/designs/inv35-review-aware-resume.md § 3:
#
#   verdict=none                          → INV-12-completed marker (idempotent)
#   verdict=passed                        → no-op + WARN log (race window)
#   verdict=failed-substantive            → INV-35-fresh-dev + truncate +
#                                           label_swap → in-progress + dev-new
#   verdict=failed-non-substantive,
#     under cap                           → label_swap → pending-review +
#                                           review-aware-flip marker
#   verdict=failed-non-substantive,
#     at/over cap (REVIEW_RETRY_LIMIT)    → mark_stalled + operator @-mention
handle_completed_session_routing() {
  local issue_num="$1"
  local session_id="$2"
  local session_end_iso="$3"

  # INV-92 (#298): capture the optional dev-actionable signal (5th out-param).
  # Defaults to "true" when the trailer carries no token — today's behavior.
  local _verdict="" _cause="" _dev_actionable="true"
  classify_recent_review_verdict "$issue_num" "$session_end_iso" _verdict _cause _dev_actionable

  case "$_verdict" in
    none)
      # Original INV-12 operator handoff — preserved for back-compat.
      log "  issue #${issue_num} session ${session_id} already completed (no post-session verdict) — operator handoff"
      local _notice_marker="INV-12-completed:${session_id}"
      if itp_list_comments "$issue_num" 2>/dev/null \
          | jq -r "[.[].body | select(contains(\"${_notice_marker}\"))] | length" \
          2>/dev/null | grep -q '^0$'; then
        itp_post_comment "$issue_num" \
          "Session \`${session_id}\` already ended (stop_reason=end_turn, terminal_reason=completed) and no post-session review verdict was found. Resume would hang on idle SSE — skipping. If review findings exist, unpark by flipping to \`in-progress\` + posting a dispatcher-token comment + running \`dispatch-local.sh dev-resume <issue>\` (a fresh session re-reads the issue and findings; do NOT flip to \`pending-review\` — the stale-verdict guard rejects an already-reviewed HEAD). Close the issue if the work is done. (\`${_notice_marker}\`)"
      fi
      return 0
      ;;

    passed)
      # Race: review wrapper posted `passed` and was about to flip to
      # `approved`/`reviewing`-cleanup, but the issue is currently still
      # `pending-dev` (operator manually flipped, or a label-edit raced).
      # Don't post — Step 0 hygiene reconciles next tick.
      log "  WARN: issue #${issue_num} pending-dev with passed verdict (race) — no-op, Step 0 will reconcile"
      return 0
      ;;

    failed-non-substantive)
      local _flip_count
      _flip_count=$(count_review_aware_flips "$issue_num" "$session_id")
      _flip_count="${_flip_count:-0}"
      local _limit="${REVIEW_RETRY_LIMIT:-2}"
      # cap=0 → unbounded (operator opt-in to bounce-forever).
      if [ "$_limit" -gt 0 ] && [ "$_flip_count" -ge "$_limit" ]; then
        log "  issue #${issue_num} non-substantive review failure (cause=${_cause}) reached REVIEW_RETRY_LIMIT=${_limit} — stalling"
        itp_post_comment "$issue_num" \
          "Persistent review-failure-non-substantive on session \`${session_id}\` (cause=\`${_cause}\`, flips=${_flip_count}/${_limit}). Marking stalled. @${REPO_OWNER} please investigate the upstream review dependency (bot/CI/transport)."
        mark_stalled "$issue_num"
        return 0
      fi
      log "  issue #${issue_num} non-substantive review failure (cause=${_cause}, flip ${_flip_count}/${_limit}) — flipping to pending-review"
      itp_post_comment "$issue_num" \
        "$(printf '%s\n%s' \
          "<!-- review-aware-flip:non-substantive cause=${_cause} session=${session_id} -->" \
          "Re-routing to review (last review failed for non-substantive reason: ${_cause}).")"
      label_swap "$issue_num" "pending-dev" "pending-review"
      return 0
      ;;

    failed-substantive)
      # [INV-85] (#274) No-progress / bot-unfixable guard — symmetric to the
      # #106 last_reviewed_head guard in handle_pending_dev_pr_exists, applied
      # to THIS completed-session substantive-failure path (which #106 did not
      # cover). Without it, a substantive FAIL the dev agent cannot resolve
      # (bot lacks permission to edit the PR body, or the finding is only
      # satisfiable post-merge) loops dev-new every tick forever: no new commit
      # → identical re-review against the unchanged HEAD → another dev-new.
      #
      # Compute the PR HEAD and the last-reviewed HEAD once for both sub-checks.
      local _np_pr_info _np_current_head _np_last_head
      # We read `.headRefOid` here. `body` stays in the field list for
      # back-compat (it is carried through to the echoed object and a #274
      # source-pin grep test asserts the literal field list), but under
      # [INV-86] (#277) `fetch_pr_for_issue` binds by GitHub's parsed
      # `closingIssuesReferences` — NOT a `.body | test("#N")` mention — so
      # `body` is no longer load-bearing for the resolution that returns this
      # object. The unit tests mock fetch_pr_for_issue.
      _np_pr_info=$(fetch_pr_for_issue "$issue_num" "number,headRefOid,body")
      _np_current_head=$(jq -r '.headRefOid // empty' <<<"$_np_pr_info" 2>/dev/null)
      # [INV-105] (#297): the PR number for the convergence report's evidence line.
      local _np_pr_number
      _np_pr_number=$(jq -r '.number // empty' <<<"$_np_pr_info" 2>/dev/null)
      _np_last_head=$(last_reviewed_head "$issue_num")
      local _np_notice_marker="no-progress-substantive:${_np_current_head}"

      # Branch A — bot-unfixable: the dev agent reported a 403 on a PR-metadata
      # edit (its scoped token can't do it) or a maintainer/post-merge-only
      # finding, within the CURRENT HEAD's review cycle. No commit clears it →
      # escalate with ZERO dev-new.
      #
      # Gated on `current_head == last_head` (#274 review [P1] finding 1): a 403
      # only blocks when HEAD has NOT advanced since the last review. If the dev
      # pushed new commits (HEAD moved) — or a maintainer applied the metadata
      # edit and a re-review advanced the trailer — the prior 403 is stale and
      # this branch must NOT fire; we fall through to branch C and dispatch a
      # fresh dev-new against the new HEAD. `dev_report_bot_unfixable` is itself
      # HEAD-window-scoped (see its definition) as defense-in-depth, but the
      # same-HEAD gate here is the primary guard against a stale-403 permanent
      # stall. (Empty current_head — no PR yet — also skips this branch: there
      # is no PR body to have hit a 403 against.)
      if [ -n "$_np_current_head" ] && [ -n "$_np_last_head" ] \
         && [ "$_np_current_head" = "$_np_last_head" ] \
         && dev_report_bot_unfixable "$issue_num" "$_np_current_head"; then
        log "  issue #${issue_num} substantive review failure is bot-unfixable (PR-metadata 403 / maintainer-only) — escalating to operator, no dev-new"
        if itp_list_comments "$issue_num" 2>/dev/null \
            | jq -r "[.[].body | select(contains(\"${_np_notice_marker}\"))] | length" \
            2>/dev/null | grep -q '^0$'; then
          itp_post_comment "$issue_num" \
            "Substantive review failure on completed session \`${session_id}\` is **not resolvable by the autonomous dev agent**: its scoped token hit \`Resource not accessible by integration\` on a PR-metadata edit, or the finding requires a maintainer / post-merge action. Marking stalled — no further \`dev-new\` will be dispatched. @${REPO_OWNER} please apply the PR-body / metadata change manually, or split the post-merge criterion into a follow-up. (\`${_np_notice_marker}\`)"
        fi
        mark_stalled "$issue_num"
        return 0
      fi

      # Branch B — no-progress: the current PR HEAD already matches the last
      # reviewed HEAD AND a prior dev-new already ran against this HEAD (the
      # attempt marker below was dropped on the previous tick). The earlier
      # dev-new produced no new commit, so a fresh one would loop. Escalate.
      if [ -n "$_np_last_head" ] && [ -n "$_np_current_head" ] \
         && [ "$_np_current_head" = "$_np_last_head" ] \
         && itp_list_comments "$issue_num" 2>/dev/null \
              | jq -r "[.[].body | select(contains(\"no-progress-substantive-attempt:${_np_current_head}\"))] | length" \
              2>/dev/null | grep -q -v '^0$'; then
        log "  issue #${issue_num} substantive review failure with no HEAD progress since \`${_np_current_head}\` (prior dev-new made no new commit) — escalating to operator, no dev-new"
        if itp_list_comments "$issue_num" 2>/dev/null \
            | jq -r "[.[].body | select(contains(\"${_np_notice_marker}\"))] | length" \
            2>/dev/null | grep -q '^0$'; then
          itp_post_comment "$issue_num" \
            "Substantive review failure on completed session \`${session_id}\`, but PR HEAD \`${_np_current_head}\` is unchanged since the last review and a prior fresh dev session already ran against it without producing a new commit. The finding appears un-actionable by the dev agent. Marking stalled — no further \`dev-new\` will be dispatched. @${REPO_OWNER} please investigate. (\`${_np_notice_marker}\`)"
        fi
        mark_stalled "$issue_num"
        return 0
      fi

      # Branch B′ — [INV-92] (#298) non-actionable finding: the review wrapper
      # classified EVERY blocking finding as not dev-agent-actionable (a
      # protected-path / missing-token-scope finding — e.g. a `.github/workflows`
      # edit the agent's scoped token can't make, or a CODEOWNERS change), folded
      # into the trailer as `dev-actionable=false`. A dev-resume cannot satisfy
      # it, so escalate — reuse the existing `pending-dev→stalled` movement
      # (mark_stalled, a NEW CALL SITE of an existing edge, NOT a new label
      # transition) with a structured `reason=non_actionable_finding` distinct
      # from the retry-exhaustion `reason=max_retries_exceeded`. This is the
      # PROACTIVE complement to INV-85 Branch A (which only fires reactively,
      # after a dev agent burns a cycle hitting the 403) — it skips the wasted
      # first dev-new and covers findings the dev agent would never signal with
      # that exact 403 string. Placed between Branch B (no-progress) and Branch C
      # (dev-new): a `true`/absent token (the legacy / common case) falls straight
      # through to Branch C, byte-identical to today.
      #
      # Idempotent per-HEAD: keyed on the current PR HEAD (or `none` when no PR is
      # resolved), the notice posts once. mark_stalled is itself idempotent w.r.t.
      # the label (label_swap is a no-op if already stalled).
      if [ "$_dev_actionable" = "false" ]; then
        local _na_head="${_np_current_head:-none}"
        local _na_marker="non-actionable-finding:${_na_head}"
        log "  issue #${issue_num} substantive review failure is NOT dev-agent-actionable (every blocking finding requires a human / privileged token, [INV-92]) — escalating to operator, no dev-new"
        if itp_list_comments "$issue_num" 2>/dev/null \
            | jq -r "[.[].body | select(contains(\"${_na_marker}\"))] | length" \
            2>/dev/null | grep -q '^0$'; then
          itp_post_comment "$issue_num" \
            "Substantive review failure on completed session \`${session_id}\` is **not resolvable by the autonomous dev agent**: the review classified every blocking finding as requiring a human or a privileged token the agent's scoped token lacks (e.g. a \`.github/workflows\` edit needs the \`workflows\` scope, or a CODEOWNERS / maintainer-owned change — [INV-92]). Marking stalled — no \`dev-new\` will be dispatched (\`reason=non_actionable_finding\`). @${REPO_OWNER} please apply the change manually, grant the required scope, or split the criterion into a maintainer follow-up. (\`${_na_marker}\`)"
        fi
        mark_stalled "$issue_num"
        return 0
      fi

      # Branch B″ — [INV-105] (#297) convergence circuit-breaker. Reached ONLY for
      # a `failed-substantive` + `dev-actionable=true` verdict that survived
      # Branch A (bot-unfixable), Branch B (INV-85 single-shot no-progress), and
      # Branch B′ (INV-92 non-actionable). This is the BELT to INV-85's
      # single-attempt-marker suspenders: it counts the DURABLE per-round
      # "no new commits" comments (C9a) rather than a fragile one-shot marker, so
      # it catches the #286 shape — a genuinely dev-actionable-looking but
      # un-satisfiable spec that churns dev-resume for 6+ rounds against a frozen
      # head (each round completes with zero commits, so INV-85's marker resets on
      # every log-truncating dev-new).
      #
      # PRIMARY signal (C1): the PR head SHA is FROZEN across ≥ threshold COMPLETED
      # zero-commit rounds. SECONDARY gate (C1/C2): the normalized trailer-hash
      # (`{verdict}|{cause}|{dev-actionable}` — from the classify out-vars, NOT body
      # text) is stable; here it is `failed-substantive|<cause>|true` by
      # construction. Match key = `{head, trailer-hash}` ONLY.
      #
      # Bias to MISS (R4): a head that has NOT frozen (no PR / advanced HEAD /
      # empty last-reviewed head), fewer than `threshold` rounds, OR a live dev PID
      # → do NOT trip. `MAX_RETRIES`→`mark_stalled` is the cheap backstop for
      # everything this misses. A false-trip discards a converging loop's work +
      # removes `autonomous` (expensive on an unattended pipeline).
      local _cb_threshold="${CONVERGENCE_STALL_THRESHOLD:-3}"
      # Defensive numeric guards: a mis-set conf value or a surprising count must
      # never abort the tick under `set -e` (a non-numeric operand to `[ -ge ]`
      # errors out). A non-numeric threshold ⇒ default 3; a non-numeric count ⇒ 0
      # (bias to MISS, R4).
      [[ "$_cb_threshold" =~ ^[0-9]+$ ]] || _cb_threshold=3
      # The ACTIVE convergence case's canonical `{verdict}|{cause}|{dev-actionable}`
      # ([P1] finding 1): the count + report timestamps window on THIS case, not the
      # whole head's stale history. Here it is `failed-substantive|<cause>|true` by
      # construction (Branch A/B/B′ already returned for the other classes).
      local _cb_canonical
      _cb_canonical="$(convergence_canonical "$_verdict" "$_cause" "$_dev_actionable")"
      local _cb_rounds=0 _cb_rounds_json="[]"
      # Frozen head requires a resolved, unchanged HEAD (same gate INV-85 A/B use).
      if [ -n "$_np_current_head" ] && [ -n "$_np_last_head" ] \
         && [ "$_np_current_head" = "$_np_last_head" ]; then
        # Compute the matched-rounds JSON ONCE (used for both the count and the
        # report's per-round timestamp evidence, [P1] finding 2).
        _cb_rounds_json="$(_frozen_convergence_rounds_json "$issue_num" "$_np_current_head" "$_cb_canonical")"
        _cb_rounds="$(jq -r 'length' 2>/dev/null <<<"$_cb_rounds_json" || echo 0)"
        [[ "$_cb_rounds" =~ ^[0-9]+$ ]] || _cb_rounds=0
      fi
      if [ "$_cb_threshold" -gt 0 ] && [ "$_cb_rounds" -ge "$_cb_threshold" ]; then
        # Eligibility PRE-GATE (C4′/C7/C9b): check liveness BEFORE any write. If a
        # dev PID is ALIVE, post NOTHING, mark NOTHING, defer to next tick — no
        # orphan report/marker. Call WITHOUT `--at-cap` (not retry-exhausted; an
        # indeterminate remote verdict biases ALIVE→defer = MISS, per R4).
        if ! may_stall_now "$issue_num"; then
          log "  issue #${issue_num} convergence breaker: ≥${_cb_threshold} frozen-head rounds on \`${_np_current_head}\` but a dev wrapper is ALIVE — deferring terminal action ([INV-105])"
          return 0
        fi

        local _cb_hash
        _cb_hash=$(convergence_trailer_hash "$_verdict" "$_cause" "$_dev_actionable")
        # SESSION-SCOPED marker (round-12 [BLOCKING]): binding the marker to
        # `session_id` — NOT just `{issue, head, trailer-hash}` — is what makes the
        # breaker re-trippable after an operator re-arms the pipeline (removes
        # `stalled`, per the documented resume path). `handle_completed_session_routing`
        # is called at most once per completed dev session (Step 4 gates on
        # `is_session_completed`), so `session_id` is a fresh, non-reused identifier
        # per dev-resume episode: a re-arm mints a NEW dev-new session_id (INV-35
        # PTL/fresh-dev pattern), so a genuinely NEW non-convergence episode —
        # even with the SAME {head, trailer-hash} as a prior, already-resolved trip
        # — carries a DIFFERENT marker and is NOT suppressed. Within the SAME
        # session (the intended idempotency case — e.g. a tight re-tick before the
        # label transition is externally visible), the marker is identical and the
        # dedupe still fires. Without this, the OLD trip's marker (still present on
        # the issue from BEFORE the re-arm) would make the breaker "one-shot only".
        local _cb_marker="<!-- dispatcher-convergence-breaker: issue=${issue_num} head=${_np_current_head} trailer=${_cb_hash} session=${session_id} -->"

        # Idempotency (C5/R6): if THIS exact case ({issue, head, trailer-hash,
        # session}) was already reported, post NOTHING and do NOT re-transition. A
        # genuinely NEW non-convergence case (a new trailer-hash OR a new session on
        # the same frozen head) has a DIFFERENT marker → re-evaluates.
        #
        # AUTHENTICITY (round-12 [BLOCKING]): the dedupe read is gated on
        # machine-authorship — `authorKind != "human"`. This is the breaker's OWN
        # marker, posted via `itp_post_comment` under the DISPATCHER's identity
        # (the same actor that posts the Step-5b round comment) — NOT the review
        # agent's `BOT_LOGIN` identity (those can be, and in GH_AUTH_MODE=app
        # typically ARE, two distinct bot accounts). So this mirrors the
        # round-comment authenticity check in `_frozen_convergence_rounds_json`
        # (round-7), NOT the `.author == BOT_LOGIN` exact binding used there for
        # the PRECEDING-VERDICT check (round-11) — that binding authenticates a
        # REVIEW-BOT comment specifically and would wrongly reject the
        # dispatcher's own genuine marker whenever the two identities differ.
        # `authorKind != "human"` is sufficient here (unlike the round-11 case)
        # because the breaker's marker is never itself a candidate the review bot
        # could impersonate into a false verdict — the only threat model is a
        # HUMAN quoting/pasting the marker text, which this excludes regardless of
        # `BOT_LOGIN` being set.
        # `|| echo 0` guards the bare assignment under `set -euo pipefail`: a
        # routine `gh` transport error (5xx / token expiry / network blip) exits
        # non-zero, and under `pipefail` an UNGUARDED substitution would abort the
        # whole tick. Mirrors the pre-existing count-markers idiom at
        # dispatcher-tick.sh:298. On a fetch error the count is "0" → we FALL
        # THROUGH to the report+transition; that is the fail-toward-halt posture
        # for a breaker that has ALREADY confirmed ≥N frozen rounds + eligibility
        # (a missing dedup read must not silently defer a confirmed non-convergence
        # trip). Re-posting is bounded: the marker lands on this same tick, and a
        # subsequent tick re-reads it.
        local _cb_present
        _cb_present=$(itp_list_comments "$issue_num" 2>/dev/null \
          | jq -r --arg marker "$_cb_marker" \
              '[.[] | select(.authorKind != "human") | select(.body | contains($marker))] | length' \
          2>/dev/null || echo 0)
        if [ "${_cb_present:-0}" != "0" ]; then
          log "  issue #${issue_num} convergence breaker already reported for head \`${_np_current_head}\` session \`${session_id}\` (trailer=${_cb_hash}) — idempotent no-op ([INV-105])"
          return 0
        fi

        log "  issue #${issue_num} NON-CONVERGENCE detected: ${_cb_rounds} completed zero-commit rounds on frozen head \`${_np_current_head}\` (trailer=${_cb_hash}) — halting per [INV-105]"

        # Extract the verbatim repeated finding (the newest bot-authored review
        # verdict comment after the dev session end) for the report's evidence,
        # best-effort. Absent ⇒ omit gracefully.
        local _cb_verdict_body
        _cb_verdict_body=$(recent_review_verdict_body "$issue_num" "$session_end_iso" 2>/dev/null || true)

        # Per-round timestamps of the counted completed dev-resume rounds ([P1]
        # finding 2 / #297 spec evidence block): a comma-separated ISO list, in
        # order, from the SAME matched-rounds JSON the count is derived from — so
        # the report shows exactly which completed zero-commit rounds tripped the
        # breaker. Best-effort; empty ⇒ the report omits the list gracefully.
        local _cb_round_ts
        _cb_round_ts="$(jq -r '[.[].createdAt] | join(", ")' 2>/dev/null <<<"$_cb_rounds_json" || true)"

        # ATOMICITY (round-10 [P1] BLOCKING finding 1): the terminal `label_swap`
        # runs BEFORE the marker/report is posted — the same ordering `mark_stalled`
        # already uses (transition first, comment second). This is the fix for a
        # TOCTOU where posting the marker FIRST let a subsequent transient
        # `label_swap` failure leave the issue stuck `pending-dev` forever: the
        # idempotency check (above) would see the marker on every later tick and
        # suppress the retry, even though the transition never landed. With the
        # transition FIRST:
        #   - `label_swap` fails → this statement is unguarded, so `set -euo
        #     pipefail` aborts the tick before the marker is ever posted. No orphan
        #     marker exists; the NEXT tick re-evaluates this issue from scratch
        #     (still `pending-dev`, count/eligibility recomputed) and retries the
        #     transition — self-healing, matching mark_stalled's existing risk
        #     profile (its own `label_swap` call is equally unguarded).
        #   - `label_swap` succeeds → the issue is now correctly `stalled` (the
        #     state change has LANDED) before we attempt to post the report. If the
        #     SUBSEQUENT `itp_post_comment` then fails, the operator loses the
        #     report text, but the pipeline state is already correct (halted) —
        #     a lost report is a much smaller defect than a permanently-stuck loop.
        # `label_swap` uses the plain declared `pending-dev → stalled` movement —
        # the SAME movement `mark_stalled` uses (no undeclared `autonomous →
        # stalled` edge; `autonomous` is retained throughout, never part of this
        # movement; passes check-spec-drift Check C.2).
        label_swap "$issue_num" "pending-dev" "stalled"

        # Post the ONE structured `reason=non-convergence` report + marker AFTER
        # the transition has landed (C4′/C5/C7 eligibility-gated unit). Exactly ONE
        # terminal comment (NOT mark_stalled's "@owner retry exhausted" — C4).
        # Reuse `stalled`; no new label (R5).
        itp_post_comment "$issue_num" "$(cat <<CBREPORT
${_cb_marker}
## ⛔ Convergence circuit-breaker tripped — halting a non-converging dev↔review loop (\`reason=non-convergence\`, [INV-105])

The autonomous dev↔review loop is **not converging**: the review keeps failing
substantively on PR **#${_np_pr_number:-?}** while the PR head SHA stays **frozen**
— the dev agent completed **${_cb_rounds}** dev-resume rounds against
\`${_np_current_head}\` (≥ threshold ${_cb_threshold}) and produced **zero new
commits** each time. This is the #286 deadlock shape: a \`failed-substantive\`
verdict the dev agent cannot satisfy (typically a self-contradictory / malformed
acceptance criterion, or a fix the agent's scoped token can't apply).

**Dispatcher actions taken** (this loop is now HALTED — no more \`dev-resume\`):
- Transitioned the issue to \`stalled\` (autonomy halted; \`pending-dev\` removed; \`autonomous\` is retained) — REMOVING the \`stalled\` label is the operator's explicit opt-in to resume (re-enters via Step 2; retry counter resets, INV-05).
- Posted this one-time report.

**Evidence**
- PR: #${_np_pr_number:-<none>}
- Frozen PR head: \`${_np_current_head}\`
- Repeated substantive review verdict (\`cause=${_cause:-<none>}\`, \`dev-actionable=${_dev_actionable}\`):
$(if [ -n "$_cb_verdict_body" ]; then printf '  > %s\n' "${_cb_verdict_body:0:600}"; else printf '  > (verdict body unavailable — see the latest review comment above)\n'; fi)
- Repeated-failure count on this frozen head: **${_cb_rounds}**
- Counted completed dev-resume rounds (timestamps): ${_cb_round_ts:-(unavailable)}

**Human action needed** — pick one, then resume:
- [ ] Rewrite the invalid / self-contradictory acceptance criterion in the issue body, OR
- [ ] Grant the permission / scope the dev agent lacked (if the fix needs a privileged token or a protected-path edit), OR
- [ ] Close the issue, or split the un-satisfiable part into a maintainer follow-up.

**To resume: fix per the checklist above, then REMOVE the \`stalled\` label (the \`autonomous\` label is retained; removal re-arms the pipeline and resets the retry counter, INV-05).**
@${REPO_OWNER}
CBREPORT
)"
        return 0
      fi

      # Branch C — first substantive attempt against THIS head (or HEAD moved,
      # or no PR yet): fall through to the existing INV-35 dev-new dispatch. The
      # per-HEAD `no-progress-substantive-attempt:<head>` marker that makes the
      # NEXT same-HEAD tick take branch B is recorded AFTER the dispatch
      # succeeds (see below), NOT here (#274 review [P1] finding 2): writing it
      # up-front would, on a transient truncate/label/dispatch failure (the
      # `return 0` fail-closed path below), leave a marker claiming a dev-new ran
      # for this HEAD when none did — stalling the issue on the next tick. This
      # bounds dev-new to exactly one attempt per unchanged HEAD (#274 proposal
      # #2, N=1) only once a fresh session is actually launched.
      #
      # [INV-106] (302b, #361 R1): acquire BEFORE any side effect of this
      # branch. This router has two entry points (Step 4b.5.1 directly, and
      # Step 4a.5's same-HEAD delegation, [INV-98]) — a concurrent tick racing
      # either path for the same issue must be caught here, not just at a
      # single dispatcher-tick.sh call site.
      if ! acquire_dispatch_marker "$issue_num" "dev-new"; then
        log "  issue #${issue_num} dev-new dispatch marker held by a concurrent tick — skipping INV-35 fresh-dev ([INV-106])"
        return 0
      fi
      log "  issue #${issue_num} substantive review failure on completed session ${session_id} — minting fresh dev session"
      local _fresh_marker="INV-35-fresh-dev:${session_id}"
      if itp_list_comments "$issue_num" 2>/dev/null \
          | jq -r "[.[].body | select(contains(\"${_fresh_marker}\"))] | length" \
          2>/dev/null | grep -q '^0$'; then
        itp_post_comment "$issue_num" \
          "Review failed substantively on completed session \`${session_id}\`. A completed session cannot be resumed; minting a fresh dev session via the INV-12 PTL recovery pattern. (\`${_fresh_marker}\`)"
      fi
      # Truncate per-issue log so the next tick sees an empty log and
      # doesn't re-trigger this completed-detection branch. Fail-closed
      # (mirrors the INV-12 PTL guard at dispatcher-tick.sh:298-303): if
      # truncate fails, the next tick would re-read the same stale log
      # line, the idempotency marker would suppress a fresh notice, and
      # we'd silently dispatch dev-new every tick forever.
      #
      # [INV-101] (#356): the truncate routes through `_reset_session_log`,
      # which is backend-aware — under EXECUTION_BACKEND=remote-aws-ssm it
      # resets the log ON THE EXECUTION HOST via SSM (the same host
      # `_remote_session_log_probe` read from), not a controller-local path.
      # The error text below reflects whichever path was actually touched
      # (or attempted) so an operator debugging a remote-SSM project isn't
      # sent to inspect a controller-local file the reset never wrote to.
      local _log_file _log_location
      if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]; then
        _log_file="/tmp/agent-${SSM_REMOTE_PROJECT_ID:-?}-issue-${issue_num}.log"
        _log_location="${_log_file} on the execution host (SSM_INSTANCE_ID=${SSM_INSTANCE_ID:-?})"
      else
        _log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
        _log_location="${_log_file}"
      fi
      if ! _reset_session_log "$issue_num"; then
        log "  ERROR: failed to truncate ${_log_location} (perm/disk/SSM?). Skipping INV-35 dev-new dispatch to avoid re-detection loop."
        itp_post_comment "$issue_num" \
          "Could not reset agent log at \`${_log_location}\` for fresh INV-35 dispatch (permission, disk, or SSM transport error). Operator: please clear the log file and retry. Skipping dispatch to prevent a silent retry loop." 2>/dev/null || true
        # [INV-106] (#361 review [P1]): no wrapper will launch this tick for
        # this (issue, mode) — release NOW rather than let it sit for the
        # full TTL. MAX_RETRIES still bounds the retry budget; this only
        # controls how soon the NEXT tick is allowed to try again.
        release_dispatch_marker "$issue_num" "dev-new"
        return 0
      fi
      label_swap "$issue_num" "pending-dev" "in-progress"
      post_dispatch_token "$issue_num" "dev-new"
      dispatch dev-new "$issue_num"
      # [INV-106] (#361 review [P1]): dispatch() returned — a wrapper is
      # confirmed launched. Confirm so the tick-level EXIT trap leaves this
      # marker alone; it lives out its normal TTL.
      dispatch_marker_confirm_launched "$issue_num" "dev-new"
      # Record the per-HEAD attempt marker ONLY now that the fresh dev-new has
      # actually been dispatched (the marker means "a dev-new ran for this
      # HEAD"; writing it before dispatch would leave a phantom marker on an
      # aborted dispatch). The next tick that sees the same HEAD still failing
      # substantively finds this marker and takes branch B (escalate) instead of
      # looping another dev-new. Skipped when the HEAD is unknown (no PR) —
      # branch B can't key on an empty head anyway.
      #
      # Do NOT swallow a marker-write failure with `|| true` (#274 review [P1]
      # finding 2): the one-per-HEAD bound depends on this comment landing. If
      # GitHub rejects it (rate-limit/auth/network blip), retry once, and on
      # persistent failure post a LOUD operator notice so the degraded bound is
      # visible — the `MAX_RETRIES` retry-count backstop (this dev-new consumed a
      # retry slot, per INV-35) still caps the loop, but the operator should know
      # the tighter N=1 guarantee was lost for this HEAD.
      if [ -n "$_np_current_head" ]; then
        # The marker is an HTML comment carrying the EXACT token branch B greps
        # for (`no-progress-substantive-attempt:<head>`). The operator notice
        # below must NOT contain that literal token verbatim — otherwise the
        # notice itself would satisfy branch B's presence check next tick and
        # cause the very false-stall this guard prevents. The notice therefore
        # describes the marker without reproducing the grep token.
        local _attempt_marker="<!-- no-progress-substantive-attempt:${_np_current_head} session=${session_id} -->"
        if ! itp_post_comment "$issue_num" "$_attempt_marker" 2>/dev/null \
           && ! itp_post_comment "$issue_num" "$_attempt_marker" 2>/dev/null; then
          log "  WARNING: failed to post the no-progress attempt marker for issue #${issue_num} HEAD ${_np_current_head} after retry — N=1 no-progress bound degraded for this HEAD (MAX_RETRIES remains the backstop)."
          itp_post_comment "$issue_num" \
            "⚠️ Dispatched a fresh dev session for the substantive review failure, but could not record the per-HEAD no-progress attempt tracker for \`${_np_current_head}\` (GitHub API rejected the hidden marker comment twice). The per-HEAD one-retry bound ([INV-85]) is degraded for this HEAD; the issue is still bounded by \`MAX_RETRIES\`. @${REPO_OWNER} no action needed unless the issue churns dev retries against an unchanged HEAD." 2>/dev/null \
            || log "  WARNING: operator notice for the degraded no-progress tracker also failed to post for issue #${issue_num}."
        fi
      fi
      return 0
      ;;

    *)
      # Defensive — classifier should never return anything else, but if
      # it does, fall through to the original INV-12-completed operator
      # handoff (safest).
      log "  WARN: classify_recent_review_verdict returned unknown verdict '${_verdict}' for issue #${issue_num} — falling back to operator handoff"
      local _notice_marker_default="INV-12-completed:${session_id}"
      if itp_list_comments "$issue_num" 2>/dev/null \
          | jq -r "[.[].body | select(contains(\"${_notice_marker_default}\"))] | length" \
          2>/dev/null | grep -q '^0$'; then
        itp_post_comment "$issue_num" \
          "Session \`${session_id}\` completed; verdict classifier returned unexpected value. Operator handoff. (\`${_notice_marker_default}\`)"
      fi
      return 0
      ;;
  esac
}


# ---------------------------------------------------------------------------
# Dispatch-token marker (Bugs 1 + 2 in #99 — [INV-17])
# ---------------------------------------------------------------------------
#
# At dispatch time the dispatcher writes a structured marker to the issue:
#
#   <!-- dispatcher-token: <uuid> at <iso8601> mode=<dev-new|dev-resume|review> run=<run-id> -->
#   Dispatching autonomous development...
#
# The `run=<run-id>` field is [INV-106] (302b, #361) — optional in the regex
# for backward compat with pre-#361 marker comments that lack it. The HTML
# comment is machine-parseable; the human-readable line preserves the
# existing wording for backward compat. Three roles:
#
#   1. Cold-start grace period (Bug 1). Step 5 reads the latest token's age
#      via latest_dispatch_token_age_seconds and skips stale detection if
#      `age < DISPATCH_GRACE_PERIOD_SECONDS`. Defaults to 10 min — empirical
#      wrapper startup is 1–7 sec, this leaves ~90× headroom for slow MCP
#      negotiation or remote SSM dispatch without trapping genuinely-dead
#      wrappers indefinitely.
#
#   2. Dispatcher-controlled dispatch identity (Bug 2). The dispatcher no
#      longer relies on the agent's session-id-comment to know "did we just
#      dispatch this?" — which used to fail when the agent crashed before
#      its EXIT trap.
#
#   3. Forensic attribution ([INV-106], #361). `run=` carries the dispatching
#      tick's run id (or a pid+start-ts fallback — see `_dispatcher_run_id`),
#      so a duplicate pair of tokens on one issue (the #298 incident: two
#      overlapping controller ticks each dispatched the same (issue, mode))
#      is attributable post-hoc to the two ticks that raced, without journald.

# Echoes seconds since the most recent dispatch-token comment on the issue.
# Empty if no token comment exists, or if the timestamp is unparseable.
latest_dispatch_token_age_seconds() {
  local issue_num="$1"
  local latest_iso
  latest_iso=$(itp_list_comments "$issue_num" \
    | jq -r '[.[].body | capture("<!-- dispatcher-token: [a-zA-Z0-9_-]+ at (?<ts>[0-9TZ:-]+) mode=[a-z-]+( run=[^ ]+)? -->"; "g") | .ts] | last // empty')
  [ -n "$latest_iso" ] || { echo ""; return; }
  _iso_age_seconds "$latest_iso"
}

# Echoes seconds between now and an ISO-8601 UTC timestamp. Empty on parse
# failure. Cross-platform (GNU `date -d` vs BSD `date -j -f`). Shared by
# pr_idle_seconds and latest_dispatch_token_age_seconds.
_iso_age_seconds() {
  local iso="$1"
  local epoch now_epoch
  epoch=$(date -u -d "$iso" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
    || echo "")
  [ -n "$epoch" ] || { echo ""; return; }
  now_epoch=$(date -u +%s)
  echo $(( now_epoch - epoch ))
}

# Echoes a path's mtime as a Unix epoch. Empty if the path doesn't exist or
# stat fails. Cross-platform (GNU `stat -c %Y` vs BSD `stat -f %m`). Shared by
# pid_alive's tier-2/tier-3 mtime checks and acquire_dispatch_marker's TTL
# comparison — the same one-liner was duplicated three times before this
# extraction (INV-106, #361 review).
_mtime_epoch() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo ""
}

# Returns 0 if the issue's latest dispatch token is younger than
# DISPATCH_GRACE_PERIOD_SECONDS. Returns 1 otherwise (also when no token
# exists — backward-compat fallthrough). Strict `<`: at-or-past the
# threshold is OUT of grace.
#
# DISPATCH_GRACE_PERIOD_SECONDS=0 disables the grace window entirely.
is_within_grace_period() {
  local issue_num="$1"
  local grace="${DISPATCH_GRACE_PERIOD_SECONDS:-600}"
  [ "$grace" -gt 0 ] || return 1
  local age
  age=$(latest_dispatch_token_age_seconds "$issue_num")
  [ -n "$age" ] || return 1
  [ "$age" -lt "$grace" ]
}

# Echoes a stable identifier for THIS dispatcher tick process, for the
# dispatch-token's `run=` field ([INV-106], #361 R2). Honors an externally
# injected `DISPATCHER_RUN_ID` (e.g. the orchestration layer that schedules
# ticks — OpenClaw's cron run id, or a future multi-tick per-project id) when
# present; otherwise mints `$$-<epoch-seconds>` (pid + this process's start
# time) on first call and CACHES it, so every `post_dispatch_token` call
# within the same tick process shares the identical run id (a tick that spans
# a wall-clock second boundary must not mint two different ids for itself).
#
# Sets `_DISPATCHER_RUN_ID_CACHE` as a SIDE EFFECT rather than echoing —
# callers read the global after calling. A caller that instead captured the
# result via `$(...)` command substitution would fork a subshell, and the
# cache assignment inside it would never propagate back to the parent shell:
# every call would then re-mint a fresh id, defeating the whole point of
# caching (the exact bug this shape avoids).
_DISPATCHER_RUN_ID_CACHE=""
_dispatcher_run_id() {
  [ -n "$_DISPATCHER_RUN_ID_CACHE" ] && return
  _DISPATCHER_RUN_ID_CACHE="${DISPATCHER_RUN_ID:-$$-$(date -u +%s)}"
}

# Post a dispatcher-controlled dispatch-token marker as an issue comment.
# Args: <issue_num> <mode>   where mode ∈ dev-new|dev-resume|review.
# Body retains the existing human-readable phrasing, prefixed with the
# machine-parseable HTML comment.
post_dispatch_token() {
  local issue_num="$1" mode="$2"
  local token now human run_id
  if command -v uuidgen >/dev/null 2>&1; then
    token=$(uuidgen | tr 'A-Z' 'a-z' | tr -d '-' | cut -c1-12)
  else
    # Fallback: 12 hex chars from /dev/urandom.
    token=$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo "$$$(date +%s%N)")
  fi
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _dispatcher_run_id
  run_id="$_DISPATCHER_RUN_ID_CACHE"
  case "$mode" in
    dev-new)     human="Dispatching autonomous development..." ;;
    dev-resume)  human="Resuming autonomous development..." ;;
    review)      human="Dispatching autonomous review..." ;;
    *)           human="Dispatching ${mode}..." ;;
  esac
  # [INV-18]/[INV-89] The dispatcher's own dispatch-token marker is a machine
  # marker — it MUST post through itp_post_comment (the marker_channel choke-point)
  # like every other marker. The `<!-- dispatcher-token: … -->` HTML marker text is
  # composed CALLER-side and passed verbatim as the BODY (GitHub's html channel
  # round-trips it unchanged; the read-side capture() depends on it surviving).
  # [INV-106] (#361 R2): `run=${run_id}` is APPENDED after `mode=` — the comment
  # format stays backward-compatible (existing `capture()`/`test()` readers key
  # on the `dispatcher-token:` prefix and `mode=` token, never on what follows).
  itp_post_comment "$issue_num" "<!-- dispatcher-token: ${token} at ${now} mode=${mode} run=${run_id} -->
${human}"
}

# ---------------------------------------------------------------------------
# Controller-side per-(issue,mode) dispatch dedup marker ([INV-106], 302b, #361)
# ---------------------------------------------------------------------------
#
# Closes the #298 incident: two overlapping controller ticks (e.g. a slow
# tick still running when the next cron-triggered tick starts) each read the
# same pre-dispatch issue state and both proceeded to label_swap +
# post_dispatch_token + dispatch() for the SAME (issue, mode) — the tick-local
# JUST_DISPATCHED array (an in-memory bash array) only protects the CURRENT
# tick's own Step 5 pass; it cannot see a second tick racing at Steps 2-4.
#
# Scope (the issue's explicit design constraint): dedup is scoped to ticks of
# ONE controller. The remote-SSM topology runs every project's ticks on a
# single OpenClaw gateway process, so a controller-local marker is a correct
# dedup point for tick-vs-tick races; cross-HOST state (SSM/DynamoDB) is not
# required. Two controllers dispatching one project is out of contract — not
# defended against here. The definitive second line of defense against
# anything that slips past this marker is 302a's wrapper-host atomic
# `acquire_pid_guard` ([INV-103]).
#
# acquire_dispatch_marker <issue_num> <mode>
#
# Args: mode ∈ dev-new|dev-resume|review (the same vocabulary post_dispatch_token
# takes) — the marker key is (issue_num, mode), per R1.
#
# Returns:
#   0 — acquired (proceed): either this call created a fresh marker, or the
#       marker infrastructure itself is unavailable (fails OPEN — see below).
#       The caller should proceed with label_swap + post_dispatch_token +
#       dispatch().
#   1 — a concurrent tick already holds a live marker for this (issue, mode).
#       The caller MUST skip — no label edit, no token post, no dispatch()
#       call. This is NOT an error; the concurrent tick owns this dispatch
#       (R1). The caller is responsible for logging the skip.
#
# Atomicity: `mkdir` is a single atomic syscall (EEXIST if the path already
# exists) — the literal primitive R1 specifies. This is the SAME primitive
# 302a's FIRST draft used before being replaced by `flock`, because that
# draft's STALE-marker RECLAIM step (rmdir + mkdir) was itself racy: two
# callers could each observe the same stale marker and both decide to
# reclaim, with the second caller's `rmdir` deleting the FIRST caller's
# freshly-created (non-stale) marker instead of the one it inspected —
# reopening the double-dispatch hole this function exists to close, just
# relocated to the reclaim path (see [INV-103]). This function reaches its
# reclaim branch ONLY for a marker whose mtime age is already >= TTL (R3) — a
# crashed prior tick's leftover — and reclaims via `mv` (POSIX rename(2),
# atomic) rather than `rmdir`: the marker directory is renamed to a
# per-caller-unique temp path FIRST; if a concurrent caller already renamed
# it away, THIS caller's `mv` fails (ENOENT) and it cleanly loses the reclaim
# race (falls through to `return 1`) instead of ever deleting a directory it
# did not itself just claim via the rename — this closes the EXACT #365-
# documented rmdir double-reclaim hole (two callers both destroying the SAME
# stale marker; here at most one `mv` of a given source path can ever
# succeed). It does NOT make the whole acquire+reclaim sequence as airtight
# as 302a's kernel-held `flock`: between this caller's winning `mv` and its
# follow-up `mkdir` recreating the path fresh, the path is briefly absent,
# and a different, unrelated caller doing a plain top-of-function `mkdir`
# could land in that microsecond window and ALSO acquire. That residual
# window is exactly what 302a's wrapper-host atomic lock ([INV-103]) exists
# to backstop — per the issue's own design constraint, this controller-side
# marker is the belt (dedup within ticks of one controller, using the literal
# mkdir/O_EXCL primitive R1 specifies), 302a's flock is the suspenders.
#
# TTL (R3): parameterized via DISPATCH_MARKER_TTL_SECONDS, default =
# DISPATCH_GRACE_PERIOD_SECONDS ([INV-18], 600s / 10 min — "the existing
# just-dispatched grace" the issue names). A marker is never a permanent
# lock: once its mtime age passes the TTL, the next acquire attempt (a later
# step in the SAME tick, or a future tick) reclaims and proceeds — a crashed
# tick's marker never wedges the issue.
acquire_dispatch_marker() {
  local issue_num="$1" mode="$2"
  local base_dir
  base_dir=$(pid_dir_for_project 2>/dev/null)
  if [ -z "$base_dir" ]; then
    # Marker infrastructure unavailable (HOME/XDG_RUNTIME_DIR unset, disk
    # full, etc.) — fail OPEN. 302a's wrapper-host atomic lock is the
    # definitive second line of defense; a controller-side infra hiccup must
    # never freeze the whole pipeline's dispatch.
    echo "[lib-dispatch] WARN: acquire_dispatch_marker could not resolve pid_dir_for_project — proceeding without controller-side dedup for issue #${issue_num} mode=${mode} (302a wrapper-host lock remains) [INV-106]" >&2
    return 0
  fi

  local marker_dir="${base_dir}/dispatch-marker-${issue_num}-${mode}"
  local ttl="${DISPATCH_MARKER_TTL_SECONDS:-${DISPATCH_GRACE_PERIOD_SECONDS:-600}}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=600

  # Symlink defense-in-depth, same posture as [INV-02]'s PID-file check —
  # fail OPEN (a planted symlink must not be able to block dispatch entirely).
  if [ -L "$marker_dir" ]; then
    echo "[lib-dispatch] WARN: dispatch marker path is a symlink — refusing to use it (issue #${issue_num} mode=${mode}) [INV-106]" >&2
    return 0
  fi

  if mkdir "$marker_dir" 2>/dev/null; then
    _dispatch_marker_pending_add "$issue_num" "$mode"
    return 0   # acquired fresh
  fi

  # mkdir failed. Distinguish the dedup-hit path (marker EXISTS — EEXIST)
  # from a marker-CREATION failure (non-EEXIST: permissions drift or ENOSPC
  # after the base dir already resolved). The latter is the same
  # marker-infrastructure class as the pid_dir_for_project failure above and
  # must fail OPEN — no marker was created, so treating it as "held by a
  # concurrent tick" would silently stall every retry for the TTL with
  # nothing to expire (#361 review round-6 [P1]). `-e`/`-L` together also
  # catch a non-dir obstruction (a plain file or dangling symlink planted at
  # the path), which the mtime path below handles as an existing marker.
  if [ ! -e "$marker_dir" ] && [ ! -L "$marker_dir" ]; then
    # One retry before failing open: "nothing at the path" is ALSO reachable
    # when the holder's release (rm -rf) landed between our failed mkdir and
    # the existence check — not a creation failure at all. The retry either
    # acquires properly (release-race case: dedup stays airtight) or fails
    # with the path still absent (genuine EACCES/ENOSPC: fall through to
    # fail-open; a real infra failure repeats deterministically).
    if mkdir "$marker_dir" 2>/dev/null; then
      _dispatch_marker_pending_add "$issue_num" "$mode"
      return 0
    fi
    if [ ! -e "$marker_dir" ] && [ ! -L "$marker_dir" ]; then
      echo "[lib-dispatch] WARN: dispatch-marker creation failed twice (non-EEXIST: permissions/ENOSPC?) — proceeding without controller-side dedup for issue #${issue_num} mode=${mode} (302a wrapper-host lock remains) [INV-106]" >&2
      return 0
    fi
    # Path appeared between retry-mkdir and re-check — a concurrent acquire
    # won the retry race; fall through to the mtime/TTL path below.
  fi

  # Marker already exists. If it's fresh (age < TTL), a concurrent tick holds
  # it — fail cleanly (R1: not an error, the concurrent tick owns this issue).
  local mtime now age
  mtime=$(_mtime_epoch "$marker_dir")
  if [ -z "$mtime" ]; then
    # Existed at the check above but can't be stat'ed now (true TOCTOU:
    # vanished between the existence check and stat) — treat conservatively
    # as held; the next tick re-evaluates from scratch.
    return 1
  fi
  now=$(date -u +%s)
  age=$(( now - mtime ))
  if [ "$age" -lt "$ttl" ]; then
    return 1   # fresh — a concurrent tick owns this (issue, mode)
  fi

  # Stale (R3) — reclaim via atomic rename (see function header for why this
  # avoids the #360 double-reclaim race). A losing reclaim attempt returns 1,
  # same as "someone else holds it" — the next tick re-evaluates (now against
  # whatever the winner created).
  local reclaim_tmp="${marker_dir}.reclaim.$$"
  if ! mv "$marker_dir" "$reclaim_tmp" 2>/dev/null; then
    return 1
  fi
  rm -rf "$reclaim_tmp" 2>/dev/null
  if ! mkdir "$marker_dir" 2>/dev/null; then
    return 1
  fi
  _dispatch_marker_pending_add "$issue_num" "$mode"
  return 0
}

# ---------------------------------------------------------------------------
# Auto-release on pre-spawn failure ([INV-106] follow-up, #361 review [P1])
# ---------------------------------------------------------------------------
#
# codex finding: `acquire_dispatch_marker` runs before label edits, notice
# comments, log resets, token posting, and the `dispatch()` launcher call —
# but nothing released it when one of THOSE steps aborted before a wrapper
# was actually running. Every failure mode in that window (a transient
# GitHub API error from `label_swap`/`post_dispatch_token`/`itp_post_comment`,
# an SSM transport fault from `_reset_session_log`, or `dispatch()` itself
# failing to background the wrapper) is a BARE command in `dispatcher-tick.sh`
# — under the script's own `set -euo pipefail`, any one of them aborts the
# ENTIRE tick immediately. Without a fix, the freshly-created marker then
# survives on disk for the full TTL (default 600s): the very next tick — which
# would otherwise retry right away — instead reads a fresh, unexpired marker
# and skips the issue as "held by a concurrent tick", turning one transient
# hiccup into a ~10 minute false stall.
#
# Design: a tick-local pending list (mirrors the existing `JUST_DISPATCHED`
# array pattern in dispatcher-tick.sh). `acquire_dispatch_marker` appends
# `(issue_num, mode)` here on every REAL acquire (never on the fail-open path,
# where no marker was created to release). The caller confirms via
# `dispatch_marker_confirm_launched` immediately after `dispatch()` itself
# returns successfully — the ONE signal that a wrapper is actually running
# and the marker should now live out its TTL undisturbed (protecting Step 5's
# cold-start grace window, [INV-18]). `dispatcher-tick.sh` installs
# `_dispatch_marker_release_pending` as a script-level `trap ... EXIT` right
# after sourcing this file: whether the tick ends normally (an explicit
# `continue`/`return` past a soft failure, e.g. the existing PTL/INV-35
# log-truncate-failure branches) or is torn down mid-loop by `set -e`, every
# `(issue_num, mode)` that never reached `dispatch_marker_confirm_launched`
# gets released before the tick process exits — so ONLY a wrapper that
# actually launched consumes the dedup window, exactly the codex finding's ask.
_DISPATCH_MARKER_PENDING=()

_dispatch_marker_pending_add() {
  _DISPATCH_MARKER_PENDING+=("$1:$2")
}

# Removes `<issue_num>:<mode>` from the pending list, if present. Shared by
# `dispatch_marker_confirm_launched` (marker should NOT be touched — it lives
# out its TTL) and `release_dispatch_marker` (marker IS being removed right
# now — so the EXIT trap must not redundantly try again later).
_dispatch_marker_pending_drop() {
  local key="$1:$2" kept=() entry
  for entry in "${_DISPATCH_MARKER_PENDING[@]:-}"; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$key" ] || kept+=("$entry")
  done
  _DISPATCH_MARKER_PENDING=("${kept[@]:-}")
}

# dispatch_marker_confirm_launched <issue_num> <mode> — call ONLY after
# `dispatch()` itself has returned successfully (a wrapper is confirmed
# launched). Drops the pair from the pending list so the EXIT-trap release
# below leaves this marker alone on disk; it lives out its normal TTL.
dispatch_marker_confirm_launched() {
  _dispatch_marker_pending_drop "$1" "$2"
}

# _dispatch_marker_release_pending — the EXIT-trap handler. Releases every
# marker still in the pending list (never confirmed) and clears the list.
# Idempotent (a second call sees an empty list and no-ops); never propagates
# a non-zero status — an EXIT trap that itself fails would clobber the
# script's real exit code.
_dispatch_marker_release_pending() {
  local entry issue mode
  for entry in "${_DISPATCH_MARKER_PENDING[@]:-}"; do
    [ -n "$entry" ] || continue
    issue="${entry%%:*}"
    mode="${entry#*:}"
    release_dispatch_marker "$issue" "$mode"
  done
  _DISPATCH_MARKER_PENDING=()
  return 0
}

# release_dispatch_marker <issue_num> <mode> — removes the on-disk marker
# `acquire_dispatch_marker` created. Also drops it from the pending list (a
# caller that releases directly, e.g. a soft-failure branch or a test, must
# not leave a stale pending entry for the EXIT trap to redundantly re-release
# later — harmless since `rm -rf` on an absent path is a no-op, but the drop
# keeps the pending list an accurate reflection of "still needs releasing").
#
# Idempotent and best-effort: `rm -rf` on an absent path is a silent no-op
# (rc 0), and a release failure (e.g. permissions) is swallowed — a marker
# that fails to release just falls back to the existing TTL-expiry safety
# net, never a hard error that could abort the tick mid-loop.
release_dispatch_marker() {
  local issue_num="$1" mode="$2"
  _dispatch_marker_pending_drop "$issue_num" "$mode"
  local base_dir
  base_dir=$(pid_dir_for_project 2>/dev/null) || return 0
  [ -n "$base_dir" ] || return 0
  rm -rf "${base_dir}/dispatch-marker-${issue_num}-${mode}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 5: stale detection helpers
# ---------------------------------------------------------------------------

# Resolve the PID file path for this issue+kind. Centralized so pid_alive
# and get_pid stay in lockstep with the wrapper-side path scheme.
# Echoes the path (or empty string if pid_dir_for_project fails — the
# callers already treat "no PID file" as "DEAD" so a soft failure here is
# safe and matches the prior /tmp behavior on filesystem errors).
_pid_file_for() {
  local kind="$1" issue_num="$2" dir
  dir=$(pid_dir_for_project 2>/dev/null) || return 0
  echo "${dir}/${kind}-${issue_num}.pid"
}

# Returns 0 if the wrapper PID for this issue+kind is alive, 1 otherwise.
# `kind` is "issue" (dev wrapper) or "review".
#
# Three-tier check (#111 Part B + INV-29, closes #129):
#   1. `kill -0 <pid>` succeeds → ALIVE.
#   2. PID file mtime is fresh (within HEARTBEAT_INTERVAL_SECONDS * 3,
#      default 360s) → ALIVE. Back-compat path for pre-INV-29 wrappers
#      that only touch the PID file.
#   3. Sibling `<base>.heartbeat` file mtime is fresh → ALIVE.
#   Otherwise → DEAD.
#
# Why two files (INV-29): the heartbeat sibling's lifecycle is owned
# exclusively by the wrapper — created and cleaned up by the wrapper's
# cleanup trap, NOT by the dispatcher. The dispatcher's
# `kill_stale_wrapper` may legitimately delete the PID file (after
# killing its holder); without the sibling, a spurious PID-file
# deletion against a still-alive wrapper would strand `pid_alive` and
# false-flag the agent as DEAD on subsequent ticks (the failure mode in
# #129). The sibling survives such deletions, so the wrapper's
# still-running heartbeat keeps the mtime fresh and the probe stays
# accurate. The PID file content (holding the agent-tree session leader
# PID) is not used here beyond tier 1 — its mtime is a back-compat
# heartbeat carrier only.
#
# _remote_pid_alive_query <kind> <issue_num>
#
# Synchronous SSM query into the wrapper box's PID file + heartbeat
# state. Used by `pid_alive` under `EXECUTION_BACKEND=remote-aws-ssm`
# ([INV-30]). Prints exactly one of `ALIVE` / `DEAD` / empty on stdout
# (the tri-state contract from `liveness-check-remote-aws-ssm.sh`).
#
# Resolves the driver path via parameter expansion (no `dirname`) so
# PATH-scrubbed callers still work. Test override:
# `_LIVENESS_CHECK_DRIVER_OVERRIDE` lets tests substitute a stub
# driver without modifying PATH.
#
# IMPORTANT: this helper MUST NOT increment any per-process counter
# itself, because callers consume its stdout via `$(...)` command
# substitution which forks a subshell. Counter mutations inside that
# subshell die with it. The counter + WARN cadence are owned by
# `pid_alive` directly (see TC-RPA-008/009 regression).
_remote_pid_alive_query() {
  local kind="$1" issue_num="$2"
  local driver
  if [ -n "${_LIVENESS_CHECK_DRIVER_OVERRIDE:-}" ]; then
    driver="$_LIVENESS_CHECK_DRIVER_OVERRIDE"
  else
    local _src="${BASH_SOURCE[0]:-$0}"
    driver="${_src%/*}/liveness-check-remote-aws-ssm.sh"
  fi

  local out rc
  out=$(bash "$driver" "$kind" "$issue_num" 2>/dev/null)
  rc=$?

  case "$rc:$out" in
    0:ALIVE) printf 'ALIVE' ;;
    0:DEAD)  printf 'DEAD'  ;;
    *)       printf ''      ;;
  esac
  return 0
}

# HEARTBEAT_INTERVAL_SECONDS=0 disables both mtime tiers entirely
# (legacy strict behavior).
#
# Under EXECUTION_BACKEND=remote-aws-ssm (#137, [INV-30]): the
# dispatcher's box doesn't host the wrapper's filesystem, so all three
# legacy tiers always miss. A remote-backend short-circuit consults
# `liveness-check-remote-aws-ssm.sh` (which reaches the wrapper box via
# SSM) and returns its tri-state verdict. Indeterminate verdicts
# (transport fault, timeout, parse error) bias toward ALIVE — the
# whole point of [INV-30] is that the dispatcher must never declare
# crashed because it lacks information.
#
# `_REMOTE_LIVENESS_DEGRADED_COUNT` (per-process counter) records
# consecutive indeterminate verdicts; `_remote_pid_alive_query` emits
# a WARN to stderr on the 1st and every 10th indeterminate tick so
# operators see the degraded state without per-tick log spam.
_REMOTE_LIVENESS_DEGRADED_COUNT="${_REMOTE_LIVENESS_DEGRADED_COUNT:-0}"

pid_alive() {
  # Optional leading `--at-cap` positional flag ([INV-30] at-cap exception,
  # issue #263). When set, the remote-backend *indeterminate* verdict flips
  # from ALIVE-bias to DEAD. The flag reaches here only via `mark_stalled
  # --at-cap`, which the dispatcher passes ONLY from its MAX_RETRIES site
  # (`dispatcher-tick.sh` Step 4) — at that point the wrapper has no claim to
  # the one-tick deference INV-30 normally grants, and persistent
  # indeterminate would otherwise defer the stall forever. The review-retry-
  # cap caller of `mark_stalled` omits the flag, so its probe keeps the
  # ALIVE-bias. A positional flag (NOT an exported env var) is required so
  # the at-cap policy cannot leak into unrelated `pid_alive` calls across
  # exported functions. All ALIVE/DEAD verdicts and all non-at-cap callers
  # are unchanged.
  local at_cap=false
  if [ "${1:-}" = "--at-cap" ]; then at_cap=true; shift; fi
  local kind="$1" issue_num="$2"
  local pid_file pid hb_file

  # Remote-backend short-circuit ([INV-30]). Runs first because under
  # remote-aws-ssm the legacy three-tier below would all miss; running
  # them anyway just wastes filesystem stat calls.
  if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ] \
     && [ "${REMOTE_LIVENESS_CHECK_DISABLE:-false}" != "true" ]; then
    local _verdict
    _verdict=$(_remote_pid_alive_query "$kind" "$issue_num")
    # At-cap exception ([INV-30], issue #263): when the caller has proven
    # retry budget is exhausted, an indeterminate verdict means "stop
    # waiting" — return DEAD instead of biasing ALIVE. Placed BEFORE the
    # `case` so the `*)` branch body (and its `return 0`) stays byte-for-byte
    # intact for TC-RPA-010's source-of-truth grep. Definite ALIVE/DEAD
    # verdicts skip this guard and fall through to the case unchanged.
    if [ "$at_cap" = true ] && [ "$_verdict" != "ALIVE" ] && [ "$_verdict" != "DEAD" ]; then
      _REMOTE_LIVENESS_DEGRADED_COUNT=$((_REMOTE_LIVENESS_DEGRADED_COUNT + 1))
      echo "[lib-dispatch] WARN: remote liveness check indeterminate at-cap" \
           "(kind=$kind issue=$issue_num" \
           "count=$_REMOTE_LIVENESS_DEGRADED_COUNT); returning DEAD to stop deferring per [INV-30] at-cap exception" >&2
      return 1
    fi
    case "$_verdict" in
      ALIVE) return 0 ;;
      DEAD)  return 1 ;;
      *)
        # Indeterminate (driver rc≠0 or stdout neither ALIVE nor
        # DEAD). User-chosen policy ([INV-30]): bias toward ALIVE so
        # a flaky transport never produces a false crash declaration.
        # The legacy three-tier below would all miss under remote
        # backend (filesystem on the wrong box), so falling through
        # would always declare DEAD — exactly the failure mode this
        # invariant closes. Treat indeterminate as ALIVE here so the
        # caller defers crash declaration by one tick.
        #
        # Source-of-truth: TC-RPA-010 grep-asserts this `*) return 0`
        # exact form. A reflexive cleanup PR that flips it to
        # `return 1` re-introduces the #182 false-stall bug.
        #
        # Counter + WARN cadence MUST live here, NOT inside
        # `_remote_pid_alive_query`, because that function's stdout
        # is captured via `$(...)` (a subshell) — counter mutations
        # there would die with the subshell. (TC-RPA-008/009)
        _REMOTE_LIVENESS_DEGRADED_COUNT=$((_REMOTE_LIVENESS_DEGRADED_COUNT + 1))
        # Emit WARN on the 1st indeterminate tick AND every 10th
        # thereafter (counts 1, 10, 20, 30, ...). Frequent enough to
        # surface a degraded transport quickly; sparse enough to not
        # spam logs once the operator is aware. (TC-RPA-009)
        if [ "$_REMOTE_LIVENESS_DEGRADED_COUNT" -eq 1 ] \
           || [ $((_REMOTE_LIVENESS_DEGRADED_COUNT % 10)) -eq 0 ]; then
          echo "[lib-dispatch] WARN: remote liveness check indeterminate" \
               "(kind=$kind issue=$issue_num" \
               "count=$_REMOTE_LIVENESS_DEGRADED_COUNT); biasing toward ALIVE per [INV-30]" >&2
        fi
        return 0
        ;;
    esac
  fi

  pid_file=$(_pid_file_for "$kind" "$issue_num")
  [ -n "$pid_file" ] || return 1
  hb_file="${pid_file%.pid}.heartbeat"
  pid=$(cat "$pid_file" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  local hb_interval="${HEARTBEAT_INTERVAL_SECONDS:-120}"
  # Defensive numeric guard: a typo here would silently flip ALIVE → DEAD,
  # the exact failure mode #111 fixes. Treat non-numeric / negative as
  # "fallback disabled" (legacy strict).
  [[ "$hb_interval" =~ ^[0-9]+$ ]] || return 1
  [ "$hb_interval" -gt 0 ] || return 1

  local now threshold mtime
  now=$(date -u +%s)
  threshold=$(( hb_interval * 3 ))

  # Tier 2: PID-file mtime (back-compat with pre-INV-29 wrappers that
  # only touch the PID file). Symlink-defended (CWE-59).
  if [ -f "$pid_file" ] && [ ! -L "$pid_file" ]; then
    mtime=$(_mtime_epoch "$pid_file")
    if [ -n "$mtime" ] && [ $(( now - mtime )) -lt "$threshold" ]; then
      return 0
    fi
  fi

  # Tier 3: heartbeat sibling mtime (INV-29). Owned exclusively by the
  # wrapper — survives spurious PID-file deletion. Same symlink defence.
  if [ -f "$hb_file" ] && [ ! -L "$hb_file" ]; then
    mtime=$(_mtime_epoch "$hb_file")
    if [ -n "$mtime" ] && [ $(( now - mtime )) -lt "$threshold" ]; then
      return 0
    fi
  fi

  return 1
}

# Echoes the current PID for the issue+kind, or empty if none.
get_pid() {
  local kind="$1" issue_num="$2"
  local pid_file
  pid_file=$(_pid_file_for "$kind" "$issue_num")
  [ -n "$pid_file" ] && cat "$pid_file" 2>/dev/null || echo ""
}

# Step 5a/5b: fetch PR info for the issue. Echoes the JSON object (single
# line) with the requested fields, or empty string if no PR found.
# `fields` is a comma-separated list passed to `--json` (e.g.
# "number,body,updatedAt" or "number,body,headRefOid").
#
# [INV-86] Delegates to the authoritative resolver in lib-pr-linkage.sh — binds
# by GitHub's parsed close linkage (`closingIssuesReferences`) with a
# branch-name fallback, NOT by a loose `#N` body mention (which bound an issue
# to a cross-referencing sibling PR — issue #277). The function name is
# preserved so the spec guard-map anchor (pr-exists-for-issue / no-pr-for-issue
# → fetch_pr_for_issue) keeps resolving, and all existing callers
# (review_near_success, handle_pending_dev_pr_exists, INV-85's body-bearing
# fetch) keep their echo-JSON-object contract unchanged.
fetch_pr_for_issue() {
  local issue_num="$1" fields="$2"
  resolve_pr_for_issue "$issue_num" "$fields"
}

# Step 5a: returns 0 if every CI check is SUCCESS (and at least one exists).
# Returns 1 on any other state (pending, failing, empty, transport error).
# Captures stderr to a mktemp file so transport errors can be diagnosed
# without coupling concurrent dispatcher instances to a shared /tmp path
# (CWE-377 mitigation).
ci_is_green() {
  local pr_num="$1"
  local ci_states ci_err_file ci_err_content
  ci_err_file=$(mktemp)
  # [INV-87] the `gh pr checks --json state` leaf moves behind chp_ci_status; the
  # `-q '[.[].state]'` projection + the green/pending/failed/none gate below stay
  # caller-side (provider-neutral). Byte-identical argv (spec §3.2).
  if ci_states=$(chp_ci_status "$pr_num" --json state -q '[.[].state]' 2>"$ci_err_file"); then
    rm -f "$ci_err_file"
  else
    ci_err_content=$(cat "$ci_err_file")
    rm -f "$ci_err_file"
    if [ -n "$ci_err_content" ]; then
      echo "WARN: CI-status query (chp_ci_status) failed for PR #${pr_num}: ${ci_err_content}" >&2
    fi
    ci_states='[]'
  fi
  jq -e 'length > 0 and all(. == "SUCCESS")' <<<"$ci_states" >/dev/null 2>&1
}

# Step 5a: echoes seconds since PR.updatedAt. Empty on parse failure
# (caller should fail-closed and leave the issue alone).
pr_idle_seconds() {
  _iso_age_seconds "$1"
}

# Step 5b: echoes the SHA from the most recent "Reviewed HEAD: \`<sha>\`"
# trailer comment on the issue. Empty if none found (caller routes to
# pending-review per [INV-07]).
last_reviewed_head() {
  local issue_num="$1"
  itp_list_comments "$issue_num" \
    | jq -r '[.[].body | capture("Reviewed HEAD: `(?<sha>[0-9a-f]{7,40})`"; "g") | .sha] | last // empty'
}

# [INV-85] (#274): returns 0 (true) if any issue comment carries the
# bot-permission signature that proves the only fix is one the scoped agent
# token cannot perform — a `Resource not accessible by integration` 403 in a
# PR-metadata-edit context (`gh pr edit`, a `PATCH .../pulls/N`, or an explicit
# "PR body"/"pull request" mention). When present, no commit the bot can push
# clears the finding, so the completed-session failed-substantive branch
# escalates to the operator without spending even one `dev-new`.
#
# Fail-safe: a `gh` transport error / no match yields empty → return 1 (NOT
# unfixable), so the caller falls through to the bounded-retry path (which still
# terminates the loop). We short-circuit ONLY on a positive signature, never on
# absence — we don't fabricate an operator handoff. The jq `test()` filter is
# RE2-safe (plain alternation, no look-behind/ahead) so a `gh --jq` run can't
# abort the wrapper under `set -e` ([gh --jq is RE2]).
dev_report_bot_unfixable() {
  # NOTE: arg 2 (the current PR head) is intentionally accepted-but-unused — the
  # lower bound is now the current dev attempt's dispatch token, not a HEAD
  # trailer (see scoping (2) below). Kept in the signature for call-site
  # stability and because the caller already gates on the head.
  local issue_num="$1" _current_head_unused="${2:-}" since_iso="" dev_login="" hits

  # Count a PR-metadata 403 ONLY when it was authored BY the dev agent during the
  # CURRENT dev attempt. A 403 only proves the *active dev attempt* is bot-blocked
  # when the dev agent reported it in this attempt — not when a reviewer, a
  # maintainer/owner, or a human comment merely *quotes* the signature, and not
  # when a PRIOR same-HEAD attempt hit a 403 the maintainer has since cleared.
  # Three scopings, all fail-open toward NOT unfixable (so a same-HEAD failure
  # still gets its one bounded retry rather than a spurious stall):
  #
  #   (1) AUTHOR allow-list (#274 review [P1] round-5): resolve the dev agent's
  #       comment author login from the most recent `Agent Session Report (Dev)`
  #       comment, then count a 403 ONLY in comments by that same author. A
  #       maintainer/owner/reviewer comment quoting the 403 has a different author
  #       → excluded. If the dev author can't be resolved (no dev session report
  #       yet), return NOT-unfixable — the active attempt keeps its bounded retry.
  #       This is the primary, robust discriminator; the review-marker exclusion
  #       below is kept only as belt-and-suspenders.
  #   (2) Lower-bound the scan at the CURRENT dev attempt's start — the most
  #       recent dispatcher-token comment with `mode=dev-new` / `mode=dev-resume`
  #       (posted by post_dispatch_token / Step 4 BEFORE the agent runs, so it
  #       precedes the agent's completion 403 — round-4 finding 2 stays fixed).
  #       This EXPIRES a 403 after each same-HEAD review cycle (#274 review [P1]
  #       round-6): every re-dispatch posts a fresh dev-dispatch token, so a 403
  #       the dev hit in a PRIOR attempt against the same HEAD falls before the
  #       new token and is ignored — if a maintainer clears the obstacle (no new
  #       commit) and a later same-HEAD review finds a *different* actionable
  #       issue, that new finding still gets its bounded `dev-new`. NOT bounded at
  #       a `Reviewed HEAD:` trailer (review-side, persists across same-HEAD
  #       cycles) nor the cleanup-time `Dev Session ID:` trailer (posted after the
  #       agent's 403). "No lower bound" only when no dev-dispatch token exists.
  #   (3) EXCLUDE review-agent comments (`Review Session:` / `Review findings` /
  #       `Review Agent:` markers) — redundant given (1) but harmless.
  #
  # The caller additionally gates this whole branch on
  # `current_head == last_reviewed_head`, so HEAD-advanced attempts never reach
  # here regardless of the bounds.

  # (1) Resolve the dev-agent author from its session-report comment. Fail-open:
  # no resolvable dev author → not unfixable (return 1). Over the normalized
  # array, `author` IS the login (spec §3.3) — `.author` replaces `.author.login`.
  dev_login=$(itp_list_comments "$issue_num" 2>/dev/null \
    | jq -r "[.[] | select((.body // \"\") | test(\"Agent Session Report \\\\(Dev\\\\)\")) | .author // empty] | last // empty" \
    2>/dev/null) || dev_login=""
  [ -n "$dev_login" ] || return 1

  # (2) Current-dev-attempt lower bound: createdAt of the most recent
  # `dispatcher-token ... mode=dev-new|dev-resume` comment. The `mode=dev-`
  # prefix matches both and excludes `mode=review`. RE2-safe (literal substring,
  # no look-behind/ahead).
  since_iso=$(itp_list_comments "$issue_num" 2>/dev/null \
    | jq -r "[.[] | select((.body // \"\") | test(\"<!-- dispatcher-token: .* mode=dev-\")) | .createdAt] | last // empty" \
    2>/dev/null) || since_iso=""
  since_iso="${since_iso:-1970-01-01T00:00:00Z}"

  # `.body` is null when a comment has an empty body; `null | test(...)` aborts
  # the jq filter (silently hiding any match — #148), so guard with `// ""`.
  # The `test()` filters are RE2-safe (plain alternation, no look-behind/ahead).
  # The dev login is passed to a standalone `jq --arg` (the normalized array
  # carries `author` as the bare login string, spec §3.3) so a `[bot]`-suffixed
  # login is matched literally via EXACT `==` ([INV-85]) — no string
  # interpolation of the login into the jq program, no regex of it. The fetch
  # moved behind itp_list_comments; the whole select/exact-eq parse stays here.
  hits=$(itp_list_comments "$issue_num" 2>/dev/null \
    | jq -r --arg dev "$dev_login" \
      "[.[]
         | select((.author // \"\") == \$dev)
         | select(.createdAt > \"${since_iso}\")
         | (.body // \"\")
         | select((test(\"Review Session:\") or test(\"Review findings\") or test(\"Review Agent:\")) | not)
         | select(test(\"Resource not accessible by integration\"))
         | select(test(\"pr edit\"; \"i\") or test(\"PATCH\"; \"i\") or test(\"pull request\"; \"i\") or test(\"PR body\"; \"i\") or test(\"pull_request\"; \"i\"))] | length" \
    2>/dev/null) || return 1
  [ -n "$hits" ] && [ "$hits" != "0" ]
}

# Step 5b: echoes seconds since the most recent review-agent verdict
# comment on the issue. The verdict comment is matched on a leading
# "Review PASSED" or "Review findings" — same prefix the wrapper writes
# in autonomous-review.sh. Empty on parse failure / no match (caller
# treats as "no recent verdict").
latest_review_verdict_age_seconds() {
  local issue_num="$1"
  local latest_iso
  latest_iso=$(itp_list_comments "$issue_num" \
    | jq -r '[.[] | select(.body | test("^Review (PASSED|findings)"))] | last | .createdAt // empty')
  [ -n "$latest_iso" ] || { echo ""; return; }
  _iso_age_seconds "$latest_iso"
}

# Step 5b: echoes seconds since the most recent "Agent Session Report
# (Dev) ... Exit code: 0" comment on the issue. Empty on parse failure
# / no match (caller treats as "no recent success").
latest_dev_success_age_seconds() {
  local issue_num="$1"
  local latest_iso
  latest_iso=$(itp_list_comments "$issue_num" \
    | jq -r '[.[] | select((.body | test("Agent Session Report \\(Dev\\)")) and (.body | test("Exit code: 0\\b")))] | last | .createdAt // empty')
  [ -n "$latest_iso" ] || { echo ""; return; }
  _iso_age_seconds "$latest_iso"
}

# Step 5b: echoes seconds since the most recent "Dev Session ID:"
# comment on the issue. Empty on no match (caller treats as
# "no recent startup confirmation"). The dev wrapper writes this
# comment as part of its startup handshake ([INV-21]); a recent one
# means the agent confirmed startup within the window — a `pid_alive`
# miss in that window is overwhelmingly likely a transient probe race.
latest_dev_session_id_age_seconds() {
  local issue_num="$1"
  local latest_iso
  latest_iso=$(itp_list_comments "$issue_num" \
    | jq -r '[.[] | select(.body | test("Dev Session ID:"))] | last | .createdAt // empty')
  [ -n "$latest_iso" ] || { echo ""; return; }
  _iso_age_seconds "$latest_iso"
}

# Step 5b: dev_near_success <issue_num>
#
# Dev-side analog of `review_near_success` (see [INV-24]). Returns 0
# (skip the "Task appears to have crashed (no PR found)" path) if ANY
# of these signals are positive within DEV_NEAR_SUCCESS_WINDOW_SECONDS
# (default 300s):
#
#   1. Most recent `Agent Session Report (Dev) ... Exit code: 0`
#      comment within window — agent already finished successfully (no
#      PR yet, but operator may not have reviewed; PR detection failure
#      on the dispatcher side is NOT an agent failure).
#   2. Most recent `Dev Session ID:` comment within window — agent
#      confirmed startup recently; the `pid_alive` miss is a transient
#      probe race against a healthy wrapper.
#   3. Defensive `kill -0 <pid>` against the current PID-file content
#      now succeeds — the original `pid_alive` miss raced with normal
#      wrapper scheduling.
#   4. Process-group walk (#137; parity with [INV-24] signal 5):
#      `_pgid_has_agent_process <pgid>` finds an AGENT_CMD descendant
#      under the wrapper's PGID. Catches the gap reproduced on a
#      downstream consumer's #182 (long-running TDD agent SIGTERMed
#      before it could emit a `Dev Session ID:` comment): signals 1+2
#      are timestamp-based and miss when the agent never produced an
#      artifact, signal 3 misses when the session-leader PID drifts out
#      of `kill -0` reachability under launcher indirection, but the
#      PGID walk catches a live agent subtree.
#
# DEV_NEAR_SUCCESS_WINDOW_SECONDS=0 disables the short-circuit (legacy
# strict — every pid_alive miss declares crashed). Non-numeric /
# negative falls back to legacy strict (parity with [INV-24]).
#
# Returns 1 if all four signals are negative — caller proceeds with
# the existing "Task appears to have crashed" comment + label swap.
#
# This invariant is [INV-27]; see also [INV-24] (review-side analog),
# [INV-26] (downstream gate that defers `mark_stalled` when the
# wrapper is alive), and [INV-30] (remote-aws-ssm `pid_alive`
# authoritative override that reaches the wrapper box directly).
dev_near_success() {
  local issue_num="$1"
  local window="${DEV_NEAR_SUCCESS_WINDOW_SECONDS:-300}"
  [[ "$window" =~ ^[0-9]+$ ]] || return 1
  [ "$window" -gt 0 ] || return 1

  # Signal 1: recent successful Session Report.
  local success_age
  success_age=$(latest_dev_success_age_seconds "$issue_num")
  if [ -n "$success_age" ] && [ "$success_age" -lt "$window" ]; then
    return 0
  fi

  # Signal 2: recent Dev Session ID confirmation.
  local startup_age
  startup_age=$(latest_dev_session_id_age_seconds "$issue_num")
  if [ -n "$startup_age" ] && [ "$startup_age" -lt "$window" ]; then
    return 0
  fi

  # Signal 3: defensive PID re-check.
  local pid
  pid=$(get_pid issue "$issue_num")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  # Signal 4: process-group walk (#137 parity with [INV-24] signal 5).
  # Skipped silently when PID is empty / unparseable (mirrors the
  # caller-site contract used by review_near_success in this same file).
  # Pass dev-side CLI per [INV-37] so a project running
  # AGENT_DEV_CMD=codex still finds the codex process even when the
  # dispatcher's $AGENT_CMD is the project default (e.g. claude).
  if [ -n "$pid" ] && _pgid_has_agent_process "$pid" "${AGENT_DEV_CMD:-${AGENT_CMD:-claude}}"; then
    return 0
  fi

  return 1
}

# _pgid_has_agent_process <pgid> [agent_cmd_override]
#
# Process-group walk shared between dev_near_success (signal 4, #137)
# and review_near_success (signal 5, #132). Walks the wrapper's process
# group (PGID == content of `<kind>-${ISSUE}.pid`; setsid in
# lib-agent.sh::_run_with_timeout makes the session-leader PID equal to
# the PGID) and returns 0 if any group member's `comm` matches the
# expected agent CLI name.
#
# 2nd arg [INV-37, agy review Finding 2 from PR #156]: optional
# per-side CLI override. Empty / missing falls back to $AGENT_CMD for
# back-compat with existing call sites and tests. Required when the
# project uses split per-side CLIs (e.g. AGENT_DEV_CMD=claude,
# AGENT_REVIEW_CMD=agy): the dispatcher tick's $AGENT_CMD is the
# project default, but each wrapper runs with its side's override —
# matching against the dispatcher-side $AGENT_CMD would false-negative
# the live wrapper. Callers MUST pass the correct per-side value
# (dev_near_success → AGENT_DEV_CMD, review_near_success →
# AGENT_REVIEW_CMD).
#
# Returns 1 silently in three cases — never fail-closed:
#   - PGID is not a positive integer (empty / unparseable PID file)
#   - `pgrep` or `ps` not on PATH (mismatched host)
#   - No member of the group has a comm matching the resolved CLI name
#
# Substring match (`*${agent_cmd}*`) is intentionally tolerant: Linux
# truncates `comm` to 15 chars (so `claude-cli-with-extras` shows up as
# `claude-cli-with`), and CLI values are typically 5–10 chars.
# Over-match is safe here — this signal only runs after pid_alive missed
# AND the cheaper signals already failed, so a false positive defers a
# crash declaration by one tick at most, while a false negative
# reproduces the #209 / #182 false-crash patterns that drove the
# addition of this signal on each side.
#
# (Was originally named `_review_pgid_has_agent_process` in #132; renamed
# in #137 once the dev side gained a parity signal. No backwards-compat
# shim — the only out-of-lib consumer was the existing test mock at
# tests/unit/test-dispatcher-review-near-success.sh, updated in the
# same PR.)
_pgid_has_agent_process() {
  local pgid="$1"
  local agent_cmd="${2:-${AGENT_CMD:-claude}}"
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
  [ "$pgid" -gt 0 ] || return 1
  command -v pgrep >/dev/null 2>&1 || return 1
  command -v ps >/dev/null 2>&1 || return 1

  local pid comm
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ -n "$comm" ] || continue
    if [[ "$comm" == *"$agent_cmd"* ]]; then
      return 0
    fi
  done < <(pgrep -g "$pgid" 2>/dev/null)

  return 1
}

# Step 5b: review_near_success <issue_num>
#
# Returns 0 (skip the "crashed" path) if ANY of these signals are
# positive within REVIEW_NEAR_SUCCESS_WINDOW_SECONDS (default 300s):
#
#   1. PR.mergedAt within window — wrapper finished merging.
#   2. Most recent APPROVED review event within window — wrapper reached
#      approve step.
#   3. Most recent "Review PASSED|findings" comment within window —
#      wrapper completed verdict.
#   4. Defensive `kill -0 <pid>` against the current PID-file content
#      now succeeds — the original pid_alive miss raced with the
#      wrapper's normal scheduling.
#   5. Process-group walk (#132): the review wrapper's PGID still has
#      at least one descendant whose comm matches AGENT_CMD. Catches
#      the "long-running review wrapper, pre-verdict window" case where
#      signals 1–4 all trail the still-mid-flight wrapper. Reproduced
#      on a downstream consumer's #209 (2026-05-15 UTC).
#
# Signal ordering is cost-driven, cheapest first: 1+2 share one
# fetch_pr_for_issue call, 3 is one gh-api call, 4 is a single kill -0,
# 5 hits the kernel proc table. Earlier signals short-circuit before
# later ones run; TC-RNS-009 pins this ordering so a future refactor
# can't silently reorder and double the per-tick cost.
#
# REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0 disables the entire short-circuit
# (legacy strict behavior — every pid_alive miss declares crashed). The
# strict knob fires at the early numeric guard, before any signal runs;
# TC-RNS-010 pins that the new signal cannot override the strict knob.
#
# Returns 1 if all five signals are negative — caller proceeds with the
# existing crashed-comment + label-swap.
review_near_success() {
  local issue_num="$1"
  local window="${REVIEW_NEAR_SUCCESS_WINDOW_SECONDS:-300}"
  # Defensive numeric guard: non-numeric / negative falls back to legacy
  # strict (every pid_alive miss declares crashed) instead of silently
  # short-circuiting on a malformed config.
  [[ "$window" =~ ^[0-9]+$ ]] || return 1
  [ "$window" -gt 0 ] || return 1

  # Signals 1 + 2: PR.mergedAt and reviews[].
  local pr_info merged_at approved_at age
  pr_info=$(fetch_pr_for_issue "$issue_num" "number,mergedAt,reviews")
  if [ -n "$pr_info" ]; then
    merged_at=$(jq -r '.mergedAt // empty' <<<"$pr_info" 2>/dev/null)
    if [ -n "$merged_at" ] && [ "$merged_at" != "null" ]; then
      age=$(_iso_age_seconds "$merged_at")
      if [ -n "$age" ] && [ "$age" -lt "$window" ]; then
        return 0
      fi
    fi

    approved_at=$(jq -r '[.reviews[]? | select(.state == "APPROVED") | .submittedAt] | sort | last // empty' <<<"$pr_info" 2>/dev/null)
    if [ -n "$approved_at" ] && [ "$approved_at" != "null" ]; then
      age=$(_iso_age_seconds "$approved_at")
      if [ -n "$age" ] && [ "$age" -lt "$window" ]; then
        return 0
      fi
    fi
  fi

  # Signal 3: review-agent verdict comment.
  local verdict_age
  verdict_age=$(latest_review_verdict_age_seconds "$issue_num")
  if [ -n "$verdict_age" ] && [ "$verdict_age" -lt "$window" ]; then
    return 0
  fi

  # Signal 4: defensive PID re-check.
  local pid
  pid=$(get_pid review "$issue_num")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  # Signal 5: process-group walk (#132; renamed to shared helper in #137).
  # Skipped silently when PID is empty / unparseable (TC-RNS-011) — the
  # helper's own integer guard would catch it, but checking here keeps
  # the caller's contract explicit and avoids ever spawning the helper
  # subshell on bad input.
  # Pass review-side CLI per [INV-37] so a project running
  # AGENT_REVIEW_CMD=agy still finds the agy process even when the
  # dispatcher's $AGENT_CMD is the project default (e.g. claude).
  if [ -n "$pid" ] && _pgid_has_agent_process "$pid" "${AGENT_REVIEW_CMD:-${AGENT_CMD:-claude}}"; then
    return 0
  fi

  return 1
}

# recent_error_envelope <issue_num> — [INV-72] Step-5 stale-handling helper.
#
# When a wrapper aborts on a config-class failure it surfaces an
# `<!-- adt-error-envelope: {json} -->` marker on the issue (lib-error.sh).
# Before the Step-5b DEAD branch posts its generic "appears to have crashed"
# comment, it calls this to find the MOST RECENT such marker within
# ERROR_ENVELOPE_WINDOW_SECONDS (default 1800 = 30m, the typical re-dispatch
# horizon). When found, it echoes a one-line `<code> — <remediation>` summary so
# the dispatcher links the surfaced config error instead of the opaque generic
# crash text (which would otherwise misreport a config crash as a transient one
# and burn retries). Echoes empty + returns 1 when no recent envelope exists.
#
# Robust against gh's RE2 --jq (no look-behind): the marker is matched with a
# plain `test("adt-error-envelope:")` and the JSON parsed by piping the comment
# body through jq, NOT by an in-`--jq` regex capture.
recent_error_envelope() {
  local issue_num="$1"
  local window="${ERROR_ENVELOPE_WINDOW_SECONDS:-1800}"
  [[ "$window" =~ ^[0-9]+$ ]] || { echo ""; return 1; }
  [ "$window" -gt 0 ] || { echo ""; return 1; }

  # Newest comment whose body carries the envelope marker, with its createdAt.
  local latest_json
  latest_json=$(itp_list_comments "$issue_num" 2>/dev/null \
    | jq -r '[.[] | select(.body | test("adt-error-envelope:"))] | last | {body, createdAt} // empty' 2>/dev/null)
  [ -n "$latest_json" ] || { echo ""; return 1; }

  local created_iso age
  created_iso=$(jq -r '.createdAt // empty' <<<"$latest_json" 2>/dev/null)
  [ -n "$created_iso" ] || { echo ""; return 1; }
  age=$(_iso_age_seconds "$created_iso")
  [ -n "$age" ] || { echo ""; return 1; }
  [ "$age" -lt "$window" ] || { echo ""; return 1; }

  # Extract the embedded JSON object from the marker and pull code+remediation.
  # sed strips the `<!-- adt-error-envelope: ... -->` wrapper without any PCRE
  # look-behind (portable + gh-RE2-safe).
  local marker_json code remediation
  marker_json=$(jq -r '.body' <<<"$latest_json" 2>/dev/null \
    | sed -n 's/.*<!-- adt-error-envelope: \(.*\) -->.*/\1/p' | head -1)
  [ -n "$marker_json" ] || { echo ""; return 1; }
  code=$(jq -r '.code // empty' <<<"$marker_json" 2>/dev/null)
  remediation=$(jq -r '.remediation // empty' <<<"$marker_json" 2>/dev/null)
  [ -n "$code" ] || { echo ""; return 1; }
  echo "${code} — ${remediation}"
  return 0
}

# Step 4a.5: PR-exists short-circuit on the pending-dev scan. Mirrors
# Step 5b's `last_reviewed_head` check so a stale FAILED verdict against
# an unchanged PR HEAD doesn't drive an infinite re-review loop (#106).
#
# Returns:
#   0 — handled (caller should `continue` to next issue)
#   1 — no PR for this issue, OR the same-HEAD session hit `prompt_too_long`
#       (caller falls through to session/dispatch logic — the tick's INV-12
#       PTL branch owns PTL recovery; see the same-HEAD block below).
#
# Side effects (only when returning 0):
#   - HEAD differs OR no prior review → flips pending-dev → pending-review
#     and posts the Bug 3 transition comment.
#   - Same HEAD already reviewed ([INV-98], #351): the park is NOT terminal.
#     For a `completed` dev session it DELEGATES to
#     `handle_completed_session_routing` (Step 4b.5.1) so the INV-35 / INV-85 /
#     INV-92 verdict-routing table (bounded dev-new / non-substantive re-review
#     / non-actionable stall) is reachable. It falls back to the idempotent
#     `stale-verdict:<sha>` park (label stays pending-dev) ONLY for the residual
#     cases the router cannot handle: no resolvable session id, a session that
#     is NOT completed per `is_session_completed` (a live/crashed wrapper — Step
#     5 owns liveness; note this is log-based detection scoped to the claude dev
#     CLI, so non-claude dev CLIs park by design), or a verdict the classifier
#     cannot bind (the router's own `none`/unknown arms fail-closed to an
#     operator handoff — never a spurious dispatch).
handle_pending_dev_pr_exists() {
  local issue_num="$1"
  local pr_info pr_num current_head pr_ref last_head notice_marker
  pr_info=$(fetch_pr_for_issue "$issue_num" "number,headRefOid")
  if [ -z "$pr_info" ]; then
    return 1
  fi

  pr_num=$(jq -r '.number // empty' <<<"$pr_info")
  current_head=$(jq -r '.headRefOid // empty' <<<"$pr_info")
  pr_ref="${pr_num:+#${pr_num}}"
  pr_ref="${pr_ref:-(number unknown)}"
  last_head=$(last_reviewed_head "$issue_num")

  if [ -n "$last_head" ] && [ -n "$current_head" ] && [ "$current_head" = "$last_head" ]; then
    # Same HEAD already reviewed — verdict was FAILED (otherwise the issue
    # wouldn't be in pending-dev). Don't redo review.
    #
    # [INV-98] (#351): before parking, try to route the review feedback to the
    # dev side. If the prior dev session reached a terminal `completed` state,
    # delegate to `handle_completed_session_routing` — the SAME router the tick
    # calls at Step 4b.5.1 — which classifies the newest post-session verdict
    # and implements the INV-35 (fresh dev-new) / INV-85 (one dev-new per
    # unchanged HEAD, then stall) / INV-92 (non-actionable → stall) table.
    # Without this delegation the park is unconditional and, because a PR
    # always exists after a review FAIL, the entire verdict-routing table is
    # unreachable and every issue deadlocks in pending-dev after one review
    # round (the #351 repro).
    #
    # `prompt_too_long` is explicitly EXCLUDED from delegation: it needs the
    # tick's INV-12 PTL recovery (log reset + `INV-12-prompt-too-long:<sid>`
    # notice + fresh dev-new), NOT the INV-35 completed-session path. We return
    # 1 so the caller falls through to Step 4b, where `is_session_completed`
    # re-detects the PTL state and the PTL branch fires. (`is_session_completed`
    # is a cheap single-log-line read; calling it twice on the PTL path is
    # harmless.)
    local _sid _term_reason="" _end_iso=""
    _sid=$(extract_dev_session_id "$issue_num")
    if [ -n "$_sid" ] && is_session_completed "$issue_num" _term_reason _end_iso; then
      if [ "$_term_reason" = "prompt_too_long" ]; then
        return 1
      fi
      # _term_reason == "completed" (the only other rc=0 case). Route the
      # verdict to the dev/review side via the shared INV-35 router.
      handle_completed_session_routing "$issue_num" "$_sid" "$_end_iso"
      return 0
    fi

    # Residual park: no resolvable session id, or a session that is not
    # `completed` per `is_session_completed` (a live/crashed wrapper — Step 5
    # owns liveness — or a non-claude dev CLI whose log has no `{"type":"result"}`
    # line, which returns false BY DESIGN). Surface the stale verdict and keep
    # pending-dev.
    #
    # Idempotency check uses `grep -q '^0$'` (fail-closed): a transient
    # `gh issue view` error yields empty output, grep returns 1, and we
    # skip the post — preventing duplicate notices on rate-limit / auth
    # refresh blips. Mirrors the existing INV-12-completed marker pattern
    # in dispatcher-tick.sh:267-269.
    notice_marker="stale-verdict:${current_head}"
    if itp_list_comments "$issue_num" 2>/dev/null \
        | jq -r "[.[].body | select(contains(\"${notice_marker}\"))] | length" \
        2>/dev/null | grep -q '^0$'; then
      itp_post_comment "$issue_num" \
        "PR ${pr_ref} HEAD \`${current_head}\` already reviewed with FAILED verdict; awaiting new commits before re-review. (\`${notice_marker}\`)"
    fi
    return 0
  fi

  # New HEAD or first review — keep existing Bug 3 (#99) behavior.
  itp_post_comment "$issue_num" \
    "PR ${pr_ref} exists for this issue; transitioning to pending-review instead of retrying dev (#99 Bug 3)."
  label_swap "$issue_num" "pending-dev" "pending-review"
  return 0
}

# ---------------------------------------------------------------------------
# Label transitions (atomic per-edit, see [INV-08])
# ---------------------------------------------------------------------------

# Atomic single-call swap. Both label args may be empty strings.
#
# [INV-87]/[INV-89] The atomic remove+add `gh issue edit` leaf routes through
# itp_transition_state (GitHub impl: itp_github_transition_state forwards the same
# args and rebuilds the byte-identical `gh issue edit … "${args[@]}"`, omitting
# --remove-label/--add-label for an empty side exactly as before). The empty-arg
# guards stay here (the caller decides which flags to pass); the [INV-25]
# terminal-state jq subtraction in list_pending_review/list_pending_dev stays
# caller-side (spec §3.1 note), NOT folded into the transition verb.
label_swap() {
  local issue_num="$1" remove="$2" add="$3"
  itp_transition_state "$issue_num" "$remove" "$add"
}

# ---------------------------------------------------------------------------
# JUST_DISPATCHED skip helper
# ---------------------------------------------------------------------------

# Returns 0 (was dispatched this tick) if the issue is in JUST_DISPATCHED.
# Caller passes the array as a space-separated string in env JUST_DISPATCHED.
was_just_dispatched() {
  local issue_num="$1"
  case " ${JUST_DISPATCHED:-} " in
    *" ${issue_num} "*) return 0 ;;
    *) return 1 ;;
  esac
}
