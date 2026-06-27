# Design: ITP read-leaf migration (#281)

> Issue: #281 — providers: migrate ITP read leaves behind
> `itp_list_by_state`/`count`/`forbidden_combos` + `read_task` + `list_comments`.
> Depends on #280 (the `lib-issue-provider.sh` dispatch skeleton + `.caps` reader +
> empty `providers/itp-github.{sh,caps}` scaffolds). Implements the READ half of
> the ITP contract in `docs/pipeline/provider-spec.md` §3.1/§3.3/§3.5.

## Goal

Move the **issue-tracker READ leaf I/O** out of `lib-dispatch.sh` (and two
read sites in the wrappers) and behind five ITP read verbs, with **ZERO
behavior change** on the GitHub backend:

| Verb | GitHub leaf (current) | Cut line |
|---|---|---|
| `itp_list_by_state STATE...` | `gh issue list … --json …` in `list_new_issues`/`list_pending_review`/`list_pending_dev`/`list_stale_candidates` | the state-filtered enumeration leaf moves; the **[INV-25]** terminal-state jq subtraction (`contains([…])\|not`) stays caller-side |
| `itp_count_by_state STATE...` | `count_active` (`\| length`) | the integer-count leaf moves; the numeric compare at `dispatcher-tick.sh` stays caller-side (still an INTEGER) |
| `itp_list_forbidden_combos` | `list_hygiene_residue` | the 2-axis (terminal AND transitional) **[INV-25]** forbidden-combo predicate leaf moves verbatim |
| `itp_read_task ISSUE FIELD` | `gh issue view --json title,body,state` reads | per-field issue read |
| `itp_list_comments ISSUE` | the **28** `gh issue view --json comments -q '…'` marker-scanners | the FETCH moves; all `capture()`/`sort_by`/exact-eq parse stays caller-side over the **normalized array** |

## The normalized comment shape (spec §3.3 / [INV-90])

`itp_list_comments ISSUE` returns a JSON array, sorted **ascending by
`createdAt`** (normative MUST), each element:

```json
{ "id": <REST numeric id>, "author": "<user.login incl [bot] verbatim>",
  "authorKind": "bot"|"human"|"self", "body": "<text>", "createdAt": "<ISO-8601 UTC>" }
```

- `id` — GitHub REST **numeric** comment id (`[INV-46]` PATCH needs numeric, not node_id).
- `author` — `user.login` **including any `[bot]` suffix verbatim** — a stable
  machine handle for EXACT `==` (`[INV-85]` `select((.author)==$dev)`).
- `authorKind` — derived: `self` when `author == $BOT_LOGIN` (env, the pipeline's
  own bot identity), else `bot` when the login ends in `[bot]`, else `human`.
  New field per spec §3.3 [M5]; lets `distinct_bot_author=0` backends discriminate.
- `body`, `createdAt` — passed through verbatim.

**The shape INV is already authored as [INV-90] by #279 — this PR REFERENCES it,
it does NOT author a new comment-shape invariant.** (The issue body's
"INV-89 (comment-shape)" is stale numbering; the live comment-shape invariant is
INV-90. INV-89 is the `marker_channel` pin.)

## No-behavior-change strategy

### List / count / read_task verbs — byte-identical `gh` argv

The state-list and read_task leaves move their `gh` call **verbatim** into
`itp_github_<verb>`. The caller invokes `itp_<verb>` and applies its (unchanged)
client-side jq subtraction afterward. Golden-trace tests capture the emitted
`gh` argv + `--json` field list and assert it byte-identical pre/post refactor.

`itp_list_by_state` accepts an explicit positional shape descriptor so the FOUR
distinct caller queries (each with a different `--json` field list and a
different `--label` selector) are preserved exactly. Rather than reconstruct
each query from an abstract STATE set (which would NOT be byte-identical), the
GitHub leaf takes the **same args the caller passes today** and forwards them to
`gh` unchanged — the abstract-state→primitive mapping is GitHub-trivial (states
ARE labels) so the leaf is a faithful pass-through. See "Verb arg shape" below.

### `itp_list_comments` — fetch moves, parse stays; 28→1 consolidation

The 28 `gh issue view --json comments -q '<varies>'` sites become
`itp_list_comments ISSUE` + caller-side jq over the normalized array. The
verb's INTERNAL `gh` call is `gh issue view ISSUE --repo REPO --json comments`
piped to a normalizer; the per-site parse (`.comments[]` → `.[]`,
`.author.login` → `.author`) stays caller-side and provider-neutral.

Golden-trace for the comment-fetch is anchored on the **28-site count** (a
grep/lint assertion) — NOT a per-site byte-identical argv, because the 28
distinct `-q` queries are deliberately consolidated.

### Test compatibility (function-mock-shim audit, spec §7.3 m3)

- **No caller function is renamed.** `count_agent_failures`,
  `extract_dev_session_id`, `classify_recent_review_verdict`,
  `last_reviewed_head`, `dev_report_bot_unfixable`, `recent_error_envelope`,
  `latest_*_age_seconds`, … keep their exact names. Every existing
  FUNCTION-level mock (`test-handle-completed-session-routing.sh`,
  `test-dispatcher-tick-app-auth.sh`, `test-dispatcher-step4-stale-verdict.sh`,
  `test-dispatcher-review-near-success.sh`) overrides the whole function and is
  therefore unaffected.
- **gh-binary stubs survive.** `itp_github_list_comments` calls
  `gh … --json comments -q '<normalize reading .comments[]>'`, so the existing
  gh stubs (which apply the requested `-q` to `{comments:[…]}`) return the
  normalized array; the caller's rewritten jq runs over it. Fixtures stay
  `{comments:[…]}`-shaped. The bare-`--json comments` stub variant (used by
  `dev_report_bot_unfixable`'s standalone-jq hits-scan) still works because that
  caller now pipes `itp_list_comments` (one gh call) to its standalone jq.

## Scope boundary (per issue Out-of-Scope)

- **OUT:** the dep-lookup reads in `resolve_dep_state` / `check_deps_resolved`
  (`--json state` @ lib-dispatch.sh:444 + :547, `--json body` @ :504) and the
  `_DEP_TOKEN_CACHE`. **Owned by #284** (`providers: migrate dependency resolution
  behind itp_resolve_dep + itp_begin_tick token-cache lifecycle (INV-83)`).

  **Why these are NOT #281's `itp_read_task` work** (the resolution of the
  apparent AC contradiction — the issue's read_task line lists `388/448/491`,
  which now resolve to these dep functions, but the issue's *own* Out-of-Scope
  says "THIS issue MUST NOT move the dep-lookup leaf"). The **authoritative spec**
  ([`provider-spec.md`](../pipeline/provider-spec.md), the documented tiebreaker
  per CLAUDE.md → Pipeline Documentation Authority) settles it:
  - **Mapping appendix line 563** — `resolve_dep_state` (`:348`) →
    **`itp_resolve_dep` + `itp_begin_tick`** (class-(b) entangled), **NOT
    `itp_read_task`**. Its `--json state` leaf carries the [INV-83] scoped-token
    mint + `_DEP_TOKEN_CACHE`, so it CANNOT be lifted as a plain `itp_read_task`
    field read.
  - **Mapping appendix line 564 + §7.1(b)** — `check_deps_resolved` (`:438`) is a
    **single entangled migration unit**: its `gh issue view --json body` read
    moves *together with* `resolve_dep_state`'s mint+lookup (`§7.1(b)`: "`gh issue
    view --json body` + `resolve_dep_state`'s mint+lookup become verbs"). The
    `## Dependencies` parse + block/proceed decision stay caller-side. Splitting
    the `--json body` read off into #281 would fracture the entangled unit and
    leave a half-migrated `check_deps_resolved` straddling two PRs.
  - **#284 explicitly claims these leaves**: its ACs require `itp_github_resolve_dep`
    to "move the `gh issue view ... --json state` leaf from lib-dispatch.sh:388
    verbatim, plus the same-repo ... leaf from lib-dispatch.sh:491", and assert
    `git grep -c 'gh issue view .*--json state' lib-dispatch.sh` → 0 there.
    Moving them in #281 would COLLIDE head-on with #284 and risk the #269
    single-mint-per-tick regression the `_DEP_TOKEN_CACHE` guards.

  So #281's read_task migration is **only the standalone field reads** —
  `autonomous-dev.sh:1097` (`--json title,body`) and `status.sh:85`
  (`--json state,labels,title`) — which carry no dep-token machinery. The dep
  reads stay byte-identical and untouched, by spec, until #284.
- **OUT:** all ITP WRITE verbs (`gh issue comment`/`gh issue edit`/label_swap),
  all CHP verbs, the orchestrator GLUE in `mark_stalled`/`handle_completed_session_routing`
  (the `itp_post_comment`+`itp_transition_state`+dispatch interleave). Those
  functions DO contain comment-FETCH scanners (the 28 count), and those FETCH
  reads move; their WRITE/decision logic does not.

## Files touched

- `providers/itp-github.sh` — add the 5 `itp_github_<verb>` read bodies.
- `lib-issue-provider.sh` — the shims already ship in #280; no change needed
  (they forward `"$@"`). Verified.
- `lib-dispatch.sh` — re-point the 5 state-list callers + the 28 comment-scanners.
- `autonomous-dev.sh:1097`, `status.sh:85` — re-point read_task.
- `docs/pipeline/provider-spec.md` — fill the read-verb contracts (now implemented).
- `docs/pipeline/invariants.md` — update INV-87/88 Status; REFERENCE INV-90.
- `tests/unit/` — golden-trace, dispatch-routing, caps-parse, normalized-shape,
  capability-branch, fixture `cp -r providers/`.

## Verb arg shape (GitHub pass-through)

To keep argv byte-identical AND keep the abstract seam, the GitHub list verbs
take the caller's existing query parameters as positional args and forward them
to `gh` unchanged:

- `itp_github_list_by_state <gh issue list flags…>` — forwards `"$@"` to
  `gh issue list --repo "$REPO" "$@"`. Each caller passes its existing
  `--state open --limit 100 --label … --json … -q …` verbatim.
- `itp_github_count_by_state …` / `itp_github_list_forbidden_combos …` — same
  pass-through; the count vs list vs forbidden-combo distinction lives entirely
  in the `-q` the caller supplies (preserving the byte-identical contract and the
  integer-vs-list return semantics).
- `itp_github_read_task ISSUE FIELD` — `gh issue view ISSUE --repo "$REPO"
  --json FIELD -q '.<FIELD>'` for a single field; callers needing multiple
  fields (`title,body`) pass the combined FIELD and consume the JSON object.

This pass-through is the GitHub reference impl's privilege (states ARE labels);
GitLab/Asana impls (later issues) translate the abstract state set into their
own primitive and do NOT receive raw `gh` flags.
