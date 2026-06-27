# Pluggable Providers Spec — Issue-Tracker & Code-Host Seams

```
spec_version: 1
status: NORMATIVE — this document is the contract later phases implement
scope: the two provider seams (issue-tracker, code-host) that abstract the
       GitHub coupling in the dispatcher / dev / review subsystem
```

> **This is the pluggable-providers deliverable's keystone artifact.** Later
> issues — the dispatch-skeleton + `.caps` reader, the ITP/CHP GitHub migrations,
> the entangled-orchestrator golden-trace, the GitLab/Asana providers —
> *implement* this spec and **MUST NOT redefine it**. When this spec and the
> wrapper code disagree, this spec is authoritative for the *target contract*; a
> current wrapper that diverges is documented in the
> [Mapping appendix](#mapping-appendix--verbcurrent-function) as a known cut line,
> not a contradiction of the spec.
>
> This revision is **spec + invariants only — no wrapper / `lib-dispatch.sh` /
> `lib-review-*.sh` / `lib-auth.sh` / `setup-labels.sh` behavior change.** It
> describes what a provider MUST do; it does not yet refactor any `gh` call site
> behind a verb, add any `providers/` file, or ship any `.caps` manifest. See
> [INV-87](invariants.md#inv-87-provider-dispatch-is-spec-defined--callers-route-every-issuecode-host-op-through-itp_chp_-never-a-raw-gh-in-the-caller-layer).
> This mirrors the [`adapter-spec.md`](adapter-spec.md) / [INV-66] precedent: write
> the contract now, implement one reference backend (GitHub), prove zero behavior
> change.

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**,
**SHOULD**, **SHOULD NOT**, **MAY**, and **OPTIONAL** are to be interpreted as
described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119). Each normative
clause is written so a conformance check can map 1:1 to it.

---

## 1. Why this spec exists

The autonomous pipeline is hard-wired to GitHub. GitHub today fills **two
distinct roles** that the codebase conflates:

- an **issue tracker** — *what to work on*: list tasks by state, the
  label-driven state machine, progress/verdict comments, cross-task
  dependencies, body checkboxes; and
- a **code host** — *PR/MR lifecycle*: find the PR for an issue, CI status,
  mergeability, create/approve/request-changes/merge, review threads, review-bot
  triggers.

An Explore sweep found **~145 distinct `gh` call sites across ~30 files**,
concentrated in `lib-dispatch.sh` (~50), the two wrappers (`autonomous-dev.sh`,
`autonomous-review.sh`, ~15 each), and the `lib-review-*.sh` family. There is
**no existing issue-source abstraction** — every operation is a direct `gh`
call. By contrast, the agent-CLI layer *does* already have an adapter pattern
under `adapters/<cli>.sh` ([INV-75]) — this spec mirrors that precedent rather
than inventing a new one.

The two roles must be **two independent, separately-configured seams** that
compose freely, because the headline target topologies the user asked for split
them: GitLab as both tracker and host (end-to-end GitLab-native), and **Asana as
issue tracker only** with GitHub *or* GitLab as the code host.

### 1.1 First deliverable (what this PR is part of)

**Design + GitHub refactor only.** Define both provider interfaces, refactor the
existing GitHub code behind them as the reference implementation, and prove zero
behavior change against the existing test suite. **No GitLab or Asana
implementation** in this deliverable — those land in later, separately-funded
issues that *implement* this spec and MUST NOT redefine it. **This PR** is the
doc-only keystone: it lands this normative spec, the four provider invariants
([INV-87]..[INV-90]), the `state-machine.md` abstract-state note, and one
doc-validation test ([`tests/unit/test-provider-spec.sh`](../../tests/unit/test-provider-spec.sh)).
It ships ZERO code/wrapper change.

---

## 2. Architecture: two independent seams

| Seam | Responsibility | `gh` surface it owns today | Config key |
|---|---|---|---|
| **Issue-Tracker Provider (ITP)** | list tasks by state, read task title/body, apply state transitions (the label state machine), post/read comments, resolve cross-task dependencies, mark checkboxes, provision state primitives | issue listing, `gh issue edit` labels, `gh issue comment`, `gh issue view --json comments`, dependency lookups, `gh label create` | `ISSUE_PROVIDER` |
| **Code-Host Provider (CHP)** | find PR/MR for a task, CI status, mergeability, create/approve/request-changes/merge, review threads, trigger review bots, render the PR-body auto-close keyword | `gh pr *`, `gh pr checks`, `gh pr review`, `gh pr merge`, review-thread `gh api` | `CODE_HOST` |

```
ISSUE_PROVIDER ∈ { github (default), gitlab, asana }
CODE_HOST      ∈ { github (default), gitlab }
```

Both default to `github`. These two seams **compose freely** — the four
topologies are `github`/`github` (today), `gitlab`/`gitlab`, `asana`/`github`,
and `asana`/`gitlab`.

### 2.1 The state machine stays provider-neutral

The pipeline states (`autonomous`, `in-progress`, `pending-review`, `reviewing`,
`pending-dev`, `approved`, `stalled`) are **abstract pipeline states**. The
existing [`state-machine.md`](state-machine.md) is unchanged — only its
*projection onto a backend* moves behind the ITP:

- GitHub renders a state as a **label**.
- GitLab renders a state as a **label** too.
- Asana renders a state as the value of a **single-select custom field** (the
  only Asana primitive that is intrinsically single-valued, transitions in one
  atomic `PUT`, and is first-class in the advanced-search filter grammar).

All marker-parsing, retry counting, verdict routing, and INV-coupled timing
logic **stays in the provider-neutral caller layer** (`lib-dispatch.sh` and the
wrappers). Only the leaf I/O call moves behind a verb. The mermaid diagram, the
transition table, and `transitions.json` are **NOT** changed by the provider
seams — see [INV-80].

### 2.2 Mirrors the existing CLI-adapter precedent

This is the same pattern the redesign established for agent CLIs ([INV-75],
[`adapter-spec.md`](adapter-spec.md)):

- a **normative spec** (this doc),
- a **thin dispatcher** that routes verb calls to `itp_<provider>_<verb>` /
  `chp_<provider>_<verb>` (exactly like `adapter_invoke_<cli>`),
- **one file per backend** under a new `providers/` dir (sibling to `adapters/`),
- **conformance fixtures** + new `INV-NN` entries.

---

## 3. The two provider interfaces (verbs)

Each seam will be one bash file per backend under `scripts/providers/`, sourced
by the same `readlink -f`-of-`BASH_SOURCE` skill-tree mechanism the adapters use
([INV-14]/[INV-65]) — so lib resolution needs **no installer re-run** (Step 1
only, per the lib-vs-entry rule). A thin dispatcher in a new
`lib-issue-provider.sh` / `lib-code-host.sh` routes each verb to its provider
function. (No such file ships in *this* PR — it is the dispatch-skeleton sibling
issue. This section is the contract those files implement.)

### 3.1 Issue-Tracker Provider (ITP) verbs

Derived 1:1 from the real `lib-dispatch.sh` functions, renamed provider-neutral.
The *callers* keep their logic; only the leaf `gh` call moves behind a verb.

| Verb | Replaces (current function / call site) | Contract |
|---|---|---|
| `itp_list_by_state STATE...` | `list_new_issues` (`lib-dispatch.sh:47`), `list_pending_review` (`:73`), `list_pending_dev` (`:91`), `list_stale_candidates` (`:110`) | **Enumerate** task ids (one per line) matching an **abstract** state set (incl. negation, e.g. "autonomous AND NOT in-progress"). The provider maps states→backend primitive. **MUST return the full set** (provider walks pagination internally — see §3.5). |
| `itp_count_by_state STATE...` | `count_active` (`:35`, returns an **integer** via jq `\| length`) | **Count**, not list. Distinct verb because `count_active` returns an int the dispatcher compares numerically (`dispatcher-tick.sh` concurrency gate); forcing callers to `wc -l` a list would lose the server-side count and change failure semantics. **[M3]** |
| `itp_list_forbidden_combos` | `list_hygiene_residue` (`:143`) | Return tasks carrying an **[INV-25] forbidden label combination** (terminal AND transitional) — a 2-axis predicate, NOT a single state set. Distinct verb because `STATE...` cannot express an intersection-of-incompatible-states query. **[M3]** |
| `itp_transition_state ISSUE REMOVE ADD` | `label_swap` (`:1986`) | Atomic state move (remove REMOVE, add ADD). GitHub: `gh issue edit --remove-label --add-label` in one call. **Note:** the terminal-state jq subtraction in `list_pending_review`/`list_pending_dev` ([INV-25] defense-in-depth) stays **caller-side**, not in this verb. |
| `itp_read_task ISSUE FIELD` | `gh issue view --json title,body,state` sites | Return `title` / `body` / `state` for one task. |
| `itp_post_comment ISSUE BODY` | every `gh issue comment` site (agent **and** dispatcher — incl. `post_dispatch_token` ([INV-18], `lib-dispatch.sh:1227`), `_dep_block_comment` ([INV-39], `:400`) — see [M6]) | Post a progress / verdict / audit / dispatcher-marker comment **through the provider's declared `marker_channel`** (§4). The single choke-point for ALL machine markers. MAY return the new comment's `id`/`url` (matches `reply-to-comments.sh:44-45`). |
| `itp_edit_comment ISSUE COMMENT_ID BODY` | `lib-review-e2e.sh:486` (`gh api -X PATCH …/issues/comments/${id}`, [INV-46] SHA stamp) | Edit a comment in place. **New verb [M5]** — an append-only `itp_post_comment` could not satisfy the [INV-46] evidence-marker stamp, which GETs the last bot comment's `id` then PATCHes it. Capability-gated: a backend without edit (`edit_comment=0`) falls back to re-posting **the full report body WITH the marker appended** as a fresh comment (NOT a marker-only post — `_fetch_sha_evidence` returns the `last` SHA-marked comment's full body, so a marker-only fallback would pass the E2E gate with no report/screenshots/AC; [INV-46]). |
| `itp_list_comments ISSUE` | every issue-level `gh issue view --json comments -q …` site (28 sites) | Return ISSUE-level comments as a **normalized JSON array** `[{id, author, body, createdAt}]`, **sorted ascending by `createdAt` (normative MUST** — the `\| last` / `sort_by(.createdAt)` idioms depend on it). `id`/`author`/`createdAt` contract pinned in §3.3. **Scoped to issue-level comments only** — review-thread / inline-PR comments are a separate CHP shape (§3.2, [M8]). |
| `itp_resolve_dep REF` | `resolve_dep_state` (`:348`) / `check_deps_resolved` (`:438`) leaf I/O only | Given a dependency ref, return abstract state `OPEN`/`CLOSED`. **The [INV-83] per-dep-repo scoped-token mint + tick-scoped `_DEP_TOKEN_CACHE` move into the provider** behind the `itp_begin_tick` lifecycle hook (see §3.6); the `## Dependencies` body parse + block/proceed decision stay **caller-side**. Ref form is capability-gated (§4: `cross_ref_shorthand`). |
| `itp_mark_checkbox ISSUE SELECTOR` | `mark-issue-checkbox.sh` | Mark a task sub-item done. GitHub: tick a body markdown checkbox. Capability-gated (§4: `body_checkbox`). |
| `itp_provision_states` | `setup-labels.sh:47` (`gh label create --color <hex>`) | Provision the backend's state primitives (GitHub: create the 9 pipeline labels). **New verb [m5]** — was an un-refactored ITP write surface. Hex color is a GitHub/GitLab concern (gate via the `label_colors` cap); Asana creates single-select options instead. |
| `itp_caps` | — (new) | Emit the capability map (§4). Resolved to a declarative `.caps` manifest + thin reader (§6). |
| `itp_begin_tick` | `dispatcher-tick.sh:228` `_reset_dep_token_cache` + the `lib-dispatch.sh:306` `_DEP_TOKEN_CACHE` ([INV-83]) | Tick-lifecycle hook — see §3.6. The dispatcher calls it **once** before Step 2; the GitHub provider maps it to `_reset_dep_token_cache` and owns `_DEP_TOKEN_CACHE` internally. **New verb [m2]**. |

> **Implementation status.** The READ leaves —
> `itp_list_by_state`, `itp_count_by_state`, `itp_list_forbidden_combos`,
> `itp_read_task`, `itp_list_comments` — are **migrated for the GitHub backend in
> #281** (`providers/itp-github.sh`), proven byte-identical by golden-trace
> ([`tests/unit/test-itp-read-leaves.sh`](../../tests/unit/test-itp-read-leaves.sh)).
> The GitHub list verbs are faithful pass-throughs: the caller passes its existing
> `gh issue list` argument tail (`--state open --limit 100 --label … --json … -q
> '<INV-25 subtraction>'`) and the leaf forwards it to `gh issue list --repo
> "$REPO" "$@"`, so the emitted argv + `--json` field list stay byte-identical and
> the INV-25 terminal-state subtraction stays in the caller's `-q` (caller-side,
> provider-neutral). **The WRITE leaves —
> `itp_transition_state`/`itp_post_comment`/`itp_edit_comment`/`itp_mark_checkbox`/
> `itp_provision_states` — are migrated for the GitHub backend in #283**
> ([`tests/unit/test-itp-write-leaves.sh`](../../tests/unit/test-itp-write-leaves.sh)):
> `label_swap` routes through `itp_transition_state`; all 18 `gh issue comment`
> sites in `lib-dispatch.sh` (including the dispatcher markers `post_dispatch_token`
> [INV-18] / `_dep_block_comment` [INV-39]) route through `itp_post_comment` ([INV-89],
> `grep -c 'gh issue comment' lib-dispatch.sh` == 0); the INV-46 SHA stamp
> (`lib-review-e2e.sh`) routes through `itp_edit_comment` with an `edit_comment=0`
> fallback that re-posts the full report body + SHA marker (never marker-only);
> `mark-issue-checkbox.sh` routes through `itp_mark_checkbox`;
> `setup-labels.sh` through `itp_provision_states` — all byte-identical, with the
> marker text / retry / dedup / [INV-25] terminal-state subtraction staying
> caller-side. The dep leaves (`itp_resolve_dep`/`itp_begin_tick`) are still
> scaffolds (downstream itp-deps-begin-tick).

### 3.2 Code-Host Provider (CHP) verbs

| Verb | Replaces | Contract |
|---|---|---|
| `chp_find_pr_for_issue ISSUE FIELDS` | `fetch_pr_for_issue` (`lib-dispatch.sh:1471`, signature is `(issue_num, FIELDS)`) | Return PR JSON projected to the **caller-supplied `FIELDS`** field list, or empty. **`FIELDS` is a REQUIRED arg [M1]** — every caller varies it (`number,headRefOid,body`; `number,mergedAt,reviews`; `number,headRefOid`; `number,body,updatedAt` / `number,body,headRefOid` in `dispatcher-tick.sh`; `number,reviewDecision,mergeable,state,body` in `status.sh`). The GitHub impl forwards `FIELDS` to `gh pr list --json $FIELDS` **byte-identically**. The documented field vocabulary MUST include `reviewDecision`, `mergeable`, `state`. Regression anchors: #148 (omitting `body` silently breaks the `select(.body\|test("#N"))` filter), #274. |
| `chp_ci_status PR` | `ci_is_green` (`lib-dispatch.sh:1485`) | Return `green` / `pending` / `failed` / `none`. |
| `chp_mergeable PR` | **`autonomous-review.sh:3159`** (`gh pr view … --json mergeable`), **NOT** `lib-review-mergeable.sh` | Return the **raw backend `mergeable` token**. **[M2]** `lib-review-mergeable.sh` is PURE classifiers (`_classify_mergeable_gate`, `_pr_open_gate`, [INV-44]/[INV-54]) doing zero gh I/O — its own header says the query "stays in the wrapper". Those classifiers **stay in the provider-neutral caller layer** and consume the verb's raw token; only the `gh pr view` leaf moves behind the verb. |
| `chp_create_pr …` | `gh pr create` site(s) | Create PR/MR. |
| `chp_approve PR` | `gh pr review --approve` | Approve. |
| `chp_request_changes PR` | `gh pr review --request-changes` | Request changes. Capability-gated (§4: `rest_request_changes`). |
| `chp_merge PR` | `gh pr merge` | Merge. **Cross-seam note [M4]:** on GitHub, merging a PR whose body carries `Closes #N` performs the ITP terminal transition as a **side effect** ([INV-33] — the wrapper MUST NOT call `gh issue close`). This coupling is now explicit via the `merge_closes_issue` capability (§4) — when absent, the caller MUST call `itp_transition_state` after `chp_merge`. |
| `chp_review_threads PR` / `chp_resolve_thread …` | `resolve-threads.sh`, `lib-review-resolve.sh` | Review-thread I/O. **Separate shape from `itp_list_comments` [M8]:** `{thread_id, resolved, comments:[{id, path, line, author, body, createdAt}]}`. `resolve-threads.sh` selects GraphQL `reviewThreads.nodes[]\|select(.isResolved==false).id` and resolves by `threadId`; inline fields (`.path`/`.line`/`.original_line`, `autonomous-dev.sh`) are CHP-owned, never folded into the ITP issue-comment shape. |
| `chp_trigger_bot PR TRIGGER` | `lib-review-bots.sh` | Post a bot trigger. Capability-gated (§4: `review_bots`). |
| `chp_close_keyword ISSUE` | the `Closes #${ISSUE_NUMBER}` literal in the PR-body prompt (`autonomous-dev.sh:851/866/914/1151`) | Render the backend's PR-body auto-close keyword for the prompt builder to interpolate. **New verb [M4]** — the keyword was hardcoded GitHub-specific prompt text; a GitLab/Asana prompt builder would otherwise emit a non-functional `Closes #N`. GitHub returns `Closes #<n>`; a backend with `merge_closes_issue=0` returns empty (caller transitions explicitly post-merge). |
| `chp_caps` | — (new) | Emit the capability map (§4). |

> **Implementation status.** ALL CHP verbs above —
> `chp_find_pr_for_issue`, `chp_ci_status`, `chp_mergeable`, `chp_approve`,
> `chp_request_changes`, `chp_merge`, `chp_review_threads`,
> `chp_resolve_thread`, `chp_close_keyword` — are **migrated for the GitHub
> backend in #282** (`providers/chp-github.sh`), proven byte-identical by
> golden-trace
> ([`tests/unit/test-chp-pr-lifecycle.sh`](../../tests/unit/test-chp-pr-lifecycle.sh)).
> The innermost `gh` primitive moves behind the verb while the INV-coupled logic
> stays caller-side: the [M1] `select(.body|test("#N"))` resolution, the
> [INV-44]/[INV-54] mergeable/open-PR classifiers ([M2],
> `lib-review-mergeable.sh` byte-unchanged), the [INV-52]/[INV-79]
> wrapper-owns-approve/merge ownership, and the review-thread select-unresolved
> all remain provider-neutral. `chp_create_pr` and `chp_trigger_bot` are also
> **defined** in `providers/chp-github.sh` (completing the verb contract), but
> their live executable leaves are the auth-side brokers (`drain_agent_pr_create`
> / `drain_agent_bot_triggers` in `lib-auth.sh`); the broker→verb rewire is an
> auth-side follow-up because `lib-auth.sh` is outside #282's scope ("NO
> auth-code change"). A small set of **incidental PR reads** that no CHP verb in
> §3.2 names — the issue-keyed body-mention `gh pr list … select(.body|test("#N"))`
> existence COUNT/number lookups (`autonomous-dev.sh`) and the PR-number-keyed
> `gh pr view $PR --json comments/state/headRefName/headRefOid/reviews`
> (`autonomous-dev.sh` / `autonomous-review.sh`) — are deliberately left as raw
> `gh` and are owned by no current verb (the literal-`gh`-freedom lint is the
> separate cutover-guard issue).
>
> **Caller guard convention (`chp_has_leaf`, #282 review round 4).** A caller that
> conditionally invokes a CHP verb MUST guard on whether the ENABLED provider
> actually defines the **leaf** (`chp_has_leaf <verb>` → `declare -F
> chp_${CODE_HOST}_<verb>`), NOT on `declare -F chp_<verb>` (the thin shim is
> ALWAYS defined once `lib-code-host.sh` is sourced, so it would dispatch to an
> undefined leaf and abort the caller under `set -e` on a backend whose provider
> file omits that leaf — the degraded fake CHP fixture has exactly that shape).
> This applies to the optional/fallback-bearing verbs the GitHub callers guard
> (`chp_close_keyword`, `chp_create_pr`, `chp_trigger_bot`); core verbs invoked in
> an `if`-condition / `$(… || …)` context are abort-safe without the guard. `chp_caps`
> is exempt — it has a real reader body, not a leaf-dispatching shim.

### 3.3 The normalized comment-JSON contract (load-bearing)

Today 28 marker-scanners (`extract_dev_session_id`, `last_reviewed_head`,
`classify_recent_review_verdict`, `count_agent_failures`,
`latest_review_verdict_age_seconds`, `recent_error_envelope`, the [INV-85]
bot-unfixable detector, …) each call `gh issue view --json comments -q '…'`
inline. They are refactored to read `itp_list_comments`' normalized array.

**The marker-parsing logic stays in the caller layer (provider-neutral).** Only
the *fetch* moves behind the ITP. This keeps every INV-coupled comment semantic
([INV-03], [INV-04], [INV-05], [INV-18], [INV-21], [INV-25], [INV-31], [INV-35],
[INV-39], [INV-85], …) in one provider-agnostic place.

**Normalized shape — `[{id, author, body, createdAt}]`** (corrected per design
review M5):

| Field | Contract | Why it's load-bearing |
|---|---|---|
| `id` | backend-native comment id consumed by the **same provider's** `itp_edit_comment` / reply verbs. GitHub: REST **numeric** id (the [INV-46] PATCH path needs a REST numeric id, not a GraphQL node_id). | a 3-field shape that dropped it → `lib-review-e2e.sh:462` (`… \| last \| .id`) then `:486` PATCH ([INV-46]) and `reply-to-comments.sh:44` (`in_reply_to=$id`) could not identify-then-mutate. |
| `author` | a **stable machine handle for EXACT equality**, NOT a display name. GitHub: `user.login` **including the `[bot]` suffix verbatim**. Asana: `created_by.gid`. GitLab: `author.username`. | callers do exact `==`: `lib-review-poll.sh` (`.author.login == BOT_LOGIN`), `lib-dispatch.sh` [INV-85] (`select((.author.login // "") == $dev)`). A display name silently breaks `== $dev`. |
| `authorKind` | normalized enum `bot` / `human` / `self`. | lets `distinct_bot_author=0` backends (Asana w/o Service Accounts) satisfy bot/self discrimination that the raw `.author.login==BOT` jq cannot — the only path when the backend has no distinct bot identity. **New field [M5].** |
| `createdAt` | **ISO-8601 UTC string; the array is sorted ascending (normative MUST).** | the `\| last` and `sort_by(.createdAt) \| last` idioms (`classify_recent_review_verdict`) and the `.createdAt > cutoff` string compares (`count_agent_failures`, [INV-05]/[INV-57]) depend on order + format. |

**Deliberately OUT of the list shape** (verified zero consumers — no `reactions`,
`isMinimized`, `permalink`, `viewerDidAuthor`, or `authorAssociation` reader):
no reactions, no `isMinimized`, no `permalink` (POST verbs MAY return a `url`),
no `viewerDidAuthor` (the pipeline does self/other via `author` exact-eq + body
marker + timestamp order, never `viewerDidAuthor`). `updatedAt` / `lastEditedAt`
are omitted (GitHub markers are append-only; the sole edit is [INV-46]'s additive
stamp via `itp_edit_comment`) — recorded as a **forward risk** for any future
in-place-edit backend.

### 3.4 `REPO` stays — as the GitHub provider's config namespace

`REPO` / `REPO_OWNER` / `REPO_NAME` and the `GH_AUTH_MODE` / `*_APP_ID` /
`*_APP_PEM` keys are **not removed** — they become the GitHub provider's config
namespace. New providers read their own keys (`GITLAB_PROJECT`, `GITLAB_HOST`,
`GITLAB_TOKEN`; `ASANA_WORKSPACE_GID`, `ASANA_STATE_FIELD_GID`,
`ASANA_PROJECT_GID`). Callers never read provider-scoped config directly. See the
[§auth](#auth--per-seam-ownership-boundary-m9) section for the per-seam auth-context cut.

### 3.5 List completeness, pagination & retry

Every list-returning verb (`itp_list_by_state`, `itp_count_by_state`,
`itp_list_forbidden_combos`, `itp_list_comments`, `chp_review_threads`) **MUST
return the COMPLETE set** — the provider walks backend pagination internally. The
GitHub impl relies on `gh`'s transparent `--json` auto-pagination + secondary-
rate-limit retry (today's behavior, zero change); a `curl`-based provider
(GitLab keyset/offset, Asana cursors) implements page-walking and `429` /
`Retry-After` backoff **inside the provider**. **Rate-limit/retry ownership is
provider-internal** — callers never see a partial page or a 429.

> **GitHub read leaves (#281) honor this with ZERO added page-walk code.** Each
> migrated read verb (`itp_github_list_by_state` / `itp_github_count_by_state` /
> `itp_github_list_forbidden_combos` / `itp_github_list_comments`) is a thin
> wrapper over the same `gh issue list` / `gh issue view --json comments` call the
> caller emitted before — `gh` already walks `--json` pagination and retries
> secondary rate limits transparently, so the COMPLETE-set guarantee is inherited
> unchanged.

### 3.6 Tick lifecycle hook (`itp_begin_tick`)

`resolve_dep_state` mints a **target-repo-scoped** GitHub-App token and caches it
in `_DEP_TOKEN_CACHE` (`lib-dispatch.sh:306`), whose lifetime is **tick-scoped**
and reset once per tick by `dispatcher-tick.sh:228` `_reset_dep_token_cache`
([INV-83] / #269). Moving the leaf behind `itp_resolve_dep` without a lifecycle
hook would either re-mint per ref (the #269 regression) or strand the cache. So
the ITP exposes an **`itp_begin_tick`** hook the dispatcher calls **once before
Step 2**; the GitHub provider maps it to `_reset_dep_token_cache` and owns
`_DEP_TOKEN_CACHE` internally. Cross-namespace dep resolution may need
provider-internal token re-scoping ([INV-83]).

---

## 4. Capability flags

Live API research (against current GitLab REST/GraphQL and Asana REST docs)
proved the abstraction is *feasible* on both backends but **not uniform**: GitHub
satisfies every verb richly; GitLab has one genuinely awkward verb
(`chp_request_changes`); Asana needs four graceful-degradation paths and one hard
channel pin. Forcing every provider to fake GitHub's full surface produces
**silent breakage** (e.g. Asana strips `<!-- -->` HTML comments → the marker
scheme dies silently).

So each provider **declares a capability map** and callers branch on it.
Capabilities are declared in a **per-provider `.caps` manifest** — a declarative
file is testable without sourcing the provider under `set -euo pipefail` (the
unguarded-source crash mode is real in this codebase); a thin `itp_caps`/`chp_caps`
reader parses it. Shown here as `key=value` for readability:

```ini
# providers/itp-github.caps
server_side_state_and=1      # filter by label-AND server-side (GitHub: yes)
server_side_state_negation=0 # filter by NOT-label server-side (GitHub: NO — done client-side via jq)  [M3]
distinct_bot_author=1        # a real bot identity exists for self/other discrimination
read_after_write_state=1     # a transition is immediately visible to a re-list
cross_ref_shorthand=1        # owner/repo#N style dep refs work (else gid/permalink)
body_checkbox=1              # markdown checkbox in body (else native subtask)
edit_comment=1               # comment edit-in-place exists (INV-46 stamp; else re-post full report+marker)  [M5]
label_colors=1               # state primitive carries a hex color (GitHub/GitLab; Asana: n/a)  [m5]
marker_channel=html          # html=HTML comments survive; text=plain only (covers dispatcher markers too)  [M6]

# providers/chp-github.caps
native_issue_pr_link=0       # native issue↔PR link (else grep PR body for #N — GitHub greps)
rest_request_changes=1       # a REST verb to submit "request changes"
review_bots=1                # slash-command review-bot triggers are meaningful
merge_closes_issue=1         # merging a PR with `Closes #N` auto-transitions the issue (INV-33)  [M4]
```

> A single `server_side_state_query` boolean would conflate AND-filtering (GitHub
> does server-side) with negation (GitHub does **client-side** via jq),
> misdescribing current behavior. It is split into the two flags above.

### 4.1 ITP capability matrix (9 keys)

| Capability | github | gitlab | asana | Caller behavior when absent |
|---|---|---|---|---|
| `server_side_state_and` | ✓ | ✓ | ✗ (search premium + eventually-consistent) | list-all + client-side AND filter |
| `server_side_state_negation` | ✗ (jq client-side today) | ✓ (`not[labels]`) | ✗ | client-side negation filter (GitHub's current path) |
| `distinct_bot_author` | ✓ | ✓ | ✗ (Service Accounts Enterprise-only) | use the normalized `authorKind` field, not raw `author==BOT` |
| `read_after_write_state` | ✓ | ✓ | ✗ (search lag 10–60s) | post-transition guard: read the task directly (consistent), not via search |
| `cross_ref_shorthand` | ✓ | ✓ (path%2F + iid) | ✗ (opaque gid) | dependency refs carry full id / permalink URL |
| `body_checkbox` | ✓ | ✓ (string-rewrite) | ✗ (no body checkboxes) | `itp_mark_checkbox` maps to **subtask-complete** |
| `edit_comment` | ✓ | ✓ | ✓ (`PUT /tasks/.../stories`) | [INV-46] stamp falls back to re-posting the full report body + marker as a fresh comment (never marker-only) |
| `label_colors` | ✓ | ✓ | ✗ (single-select options, no hex) | `itp_provision_states` skips color |
| `marker_channel` | `html` | `html` | `text` | marker writer **and** read-side `capture()` regex both branch on channel (Asana `html_text` **rejects** `<!-- -->` with HTTP 400) — covers dispatcher markers ([INV-18]/[INV-39]) too |

### 4.2 CHP capability matrix (4 keys)

| Capability | github | gitlab | Caller behavior when absent |
|---|---|---|---|
| `native_issue_pr_link` | ✗ (grep PR body for `#N`) | ✓ (`/closed_by`, `/related_merge_requests`) | grep PR/MR body for the issue ref (current GitHub behavior). When absent, the **backref token** the dev agent writes is provider-supplied via `chp_close_keyword` / id rendering, not hardcoded `#N`. |
| `rest_request_changes` | ✓ (`POST /pulls/:n/reviews {event:REQUEST_CHANGES}`) | ✗ (**no REST verb**) | emulate via quick-action note `/submit_review requested_changes` or an unresolved-discussion convention |
| `review_bots` | ✓ (`/q review`, `/codex review`, …) | ✗ (no native custom-slash registry) | `chp_trigger_bot` is a no-op; rely on the in-process review agent only |
| `merge_closes_issue` | ✓ (PR body `Closes #N` auto-transitions on merge, [INV-33]) | ✓ (MR `Closes #N` closes the issue) | **caller MUST call `itp_transition_state ISSUE <non-terminal> <terminal>` after `chp_merge`** (else the issue never reaches its terminal state) **[M4]** |

> Note `native_issue_pr_link=0` for GitHub: GitHub is the backend that lacks the
> *native* link and greps the PR body. GitLab is **stronger** here. The capability
> flag therefore describes the backend honestly rather than treating GitHub as the
> ceiling.

### 4.3 For THIS PR — GitHub `.caps` = today's behavior

GitHub's `.caps` manifests above **describe exactly today's behavior** — that is
the no-behavior-change anchor ([INV-88]). This is "GitHub honestly declared," not
"GitHub = all-ones": `server_side_state_negation=0` and `native_issue_pr_link=0`
are GitHub's real current behavior (negation done client-side via jq; PR found by
grepping the body for `#N`). Every caller therefore takes the **identical code
path** it takes now. The capability branches are *defined now in the spec* so
GitLab/Asana PRs slot in without re-architecting callers, but the only live
branches are GitHub's current ones. Same discipline as the
[`adapter-spec.md`](adapter-spec.md): write the contract now, implement one
reference backend, prove zero behavior change.

---

## 5. Per-backend feasibility (research summary)

### 5.1 GitLab (issue tracker + code host) — viable end-to-end

Maps almost 1:1; several verbs are a **cleaner** fit than GitHub: native label
AND (`labels=A,B`) and negation (`not[labels]=Y`, no jq post-filter); atomic
`add_labels`+`remove_labels` transition; native issue↔MR link (`/closed_by`);
discussion-resolve by `discussion_id`. Field renames the adapter maps:
body→`description`, comments→`notes`, `user.login`→`author.username`, PR→MR,
`pipeline.status`→`head_pipeline.status` (null = no CI → `none`),
mergeable→`detailed_merge_status` (≈20-value enum; `merge_status` is deprecated).
**The one genuine gap → `chp_request_changes`:** GitLab has **no REST verb** to
submit "request changes" — `rest_request_changes=0` gates the quick-action-note
workaround. CLI: `glab` (the official `gh` analog) for green-path verbs + raw
`curl` REST for the long tail. Auth: no single GitHub-App equivalent — closest is
a Project/Group Access Token or a Premium/Ultimate Service Account.

### 5.2 Asana (issue tracker only) — viable, four capabilities become optional

State primitive = single-select custom field (intrinsically single-valued, one
atomic `PUT`). **Marker channel hard-pin:** post via the plain `text` story field
(round-trips `<!-- marker -->` verbatim); the `html_text` field is
strict-XML-whitelisted and **rejects HTML comments with HTTP 400** — so
`marker_channel=text` is mandatory for Asana. Tier-gated → optional:
`server_side_state_and` (paid-tier search, `402` on free) and
`distinct_bot_author` (Enterprise-only Service Accounts). Eventual consistency →
`read_after_write_state=0` (search lags 10–60s; re-read the task directly).
Identity: opaque global `gid`, no `#N` → `cross_ref_shorthand=0`. Checkbox →
subtask (`body_checkbox=0`). No CLI — raw `curl` REST.

---

## 6. File layout & implementation shape (later issues)

Flat, mirroring `adapters/<cli>.sh` — the seam lives in the filename, not a
subdir, matching the proven `adapters/` precedent and its `cp -r adapters/`
fixture rule ([INV-75]):

```
scripts/
  lib-issue-provider.sh          # itp_<verb>() dispatch → itp_${ISSUE_PROVIDER}_<verb>; reads .caps  (#280)
  lib-code-host.sh               # chp_<verb>() dispatch → chp_${CODE_HOST}_<verb>; reads .caps        (#280)
  providers/                     # dir, sibling to adapters/  (#280)
    itp-github.sh                # itp_github_*  — reference impl. READ leaves (list_by_state, count_by_state, list_forbidden_combos, read_task, list_comments) MIGRATED in #281; WRITE leaves still scaffold (itp-writes); dep leaves still scaffold (itp-deps-begin-tick)
    itp-github.caps              # declarative capability manifest (parsed, not sourced)  (#280)
    chp-github.sh                # chp_github_*  — reference impl (EMPTY scaffold in #280; gh leaves moved verbatim by the chp-pr-lifecycle sibling)
    chp-github.caps              # declarative capability manifest  (#280)
    # gitlab / asana files added in later PRs
```

All new files are `lib-*.sh` / sourced provider files → picked up via the
skill-tree `readlink -f` resolution. **No new entry-point script → no
`install-project-hooks.sh` re-run** required on consumers (Step 1 `npx skills
update -g` alone suffices). The conformance + unit fixtures' fake-skill-tree must
`cp -r providers/` exactly as it already `cp -r adapters/` —
[`tests/unit/test-entry-point-startup-e2e.sh`](../../tests/unit/test-entry-point-startup-e2e.sh)
does both as of #280. **The dispatch skeleton (the two `lib-*.sh` dispatchers,
the empty `providers/itp-github.{sh,caps}` / `chp-github.{sh,caps}` scaffolds,
and the `.caps` reader) ships in issue #280** with ZERO verb leaves migrated and
zero behavior change; the `gh`-leaf migration into the `itp_github_*` /
`chp_github_*` bodies is the downstream itp-reads / itp-writes / chp-pr-lifecycle
issues. #279 (this doc) ships ZERO code.

---

## 7. No-behavior-change proof strategy (for the code-bearing siblings)

The move is **not uniformly mechanical**, and "the unit tests stay green" is
necessary but NOT sufficient.

### 7.1 Extraction taxonomy — separable leaves vs entangled functions

The refactor classifies each moved function:

- **(a) Separable leaf** — fetch-then-parse, parse is provider-neutral. Example:
  `extract_dev_session_id` (fetch → `itp_list_comments`; the
  `capture("Dev Session ID: …")` parse stays caller-side). Clean.
- **(b) Entangled function** — the body interleaves I/O + INV-coupled logic +
  (sometimes) token minting + a decision. Only the **innermost I/O primitive**
  becomes a verb; the surrounding logic stays caller-side. Named cases:
  - `check_deps_resolved` — `gh issue view --json body` + `resolve_dep_state`'s
    mint+lookup become verbs; the `## Dependencies` parse + block/proceed stay.
  - `resolve_dep_state` — the leaf lookup becomes `itp_resolve_dep`; the [INV-83]
    scoped-token mint + `_DEP_TOKEN_CACHE` move into the provider behind
    `itp_begin_tick` (§3.6).
  - `mark_stalled` / `handle_completed_session_routing` — **entangled multi-op
    orchestrators**: after the refactor they become *glue* calling 5+ verbs
    (comment posts, label swap) interleaved with NON-host ops (`pid_alive`,
    `: > $log_file` truncate, `dispatch dev-new`). Those non-host ops **stay
    caller-side** — they are not provider concerns.

The implementation issue MUST tag every one of the ~18 functions (a) or (b) and
state its cut line, or the "zero behavior change" claim is unverifiable.

### 7.2 Regression gate + golden-trace anchor

1. **The existing unit suite + the conformance suite MUST pass unchanged.** This
   is necessary but **not sufficient**: a test that stubs the `gh` *binary*
   passes by construction if the verb's GitHub impl still calls `gh`.
2. **Golden-trace test per entangled (class-b) function** — capture the exact
   `gh` argv (and `--json` field list) the function emits today, refactor, assert
   **byte-identical** argv. Anchor on #148 / #274. *(These are the
   code-bearing siblings' tests — NOT this PR.)*
3. **Function-mock shim audit.** Some unit tests mock the bash **function**
   (`fetch_pr_for_issue`), not `gh`. The implementation MUST audit `tests/unit`
   for function-level mocks of the ~18 moved functions and state a shim-vs-rename
   policy per function before claiming "tests pass unchanged."

---

## 8. Scope boundary (what this PR does NOT do)

- **No** provider code — no `lib-issue-provider.sh`, `lib-code-host.sh`,
  `providers/itp-github.sh`, `providers/chp-github.sh`, or any `.caps` manifest.
- **No** refactor of any `gh` call site in `lib-dispatch.sh`, `autonomous-dev.sh`,
  `autonomous-review.sh`, `lib-review-*.sh`, `lib-auth.sh`, `setup-labels.sh`.
- **No** GitLab or Asana implementation (later, separately-funded issues).
- **No** change to the agent-CLI adapters (`adapters/<cli>.sh`) or
  [`adapter-spec.md`](adapter-spec.md) beyond cross-reference links.
- **No** state-machine semantics change — the mermaid diagram, transition table,
  `transitions.json`, `spec-codesite-map.json`, and `spec-guard-map.json` are NOT
  modified ([INV-80]).
- **No** new entry-point script and **no** consumer `install-project-hooks.sh`
  re-run.
- **No** golden-trace / capability-branch (fake-provider) / dispatch-routing /
  `.caps`-parse runtime tests — those gate the code-bearing sibling issues
  (dispatch-skeleton-caps-reader §7, entangled-orchestrators-golden-trace, itp/chp
  migrations). This PR ships only the doc-consistency test
  ([`tests/unit/test-provider-spec.sh`](../../tests/unit/test-provider-spec.sh)).

---

## INV-77 verdict reconciliation

> **Numbering note.** The pluggable-providers issue (#279) refers to the
> "verdict-artifact channel" as **INV-77**. In the live `invariants.md` that
> invariant has since been renumbered to **[INV-78](invariants.md#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent)**
> ("review verdicts resolve from a typed artifact FILE first; comment scraping is
> an explicitly-logged fallback") — `INV-77` is now "CI is two tiers". This
> section reconciles the **typed-artifact verdict channel** by its current number
> (INV-78) so the cross-reference resolves; the design intent is identical.

The review verdict comment is the most INV-dense channel in the pipeline —
[INV-20](invariants.md#inv-20-verdict-authenticity-binding-actor--window--trailer-presence)
(the `Review Session:` trailer the wrapper attributes its own verdict by),
[INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)
(the `Review Agent:` multi-agent discriminator + unanimous aggregation),
[INV-53](invariants.md#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message)
(verdict convergence keys on the verdict trailer text, not any `agent_message`),
and the typed-artifact channel **[INV-78](invariants.md#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent)**
(the typed verdict **artifact FILE** is read first; comment scraping is an
explicitly-logged fallback). It must not fall between the provider spec and the
adapter spec.

**Pin (normative).** The verdict channel is split across the two specs, and the
split is deliberate:

- The **typed verdict artifact** (INV-78, `lib-review-artifact.sh`) is the
  primary verdict transport and is a **CHP-adjacent / agent-CLI-adapter concern**
  ([`adapter-spec.md`](adapter-spec.md) §5 verdict-artifact contract) — it is a
  file written atomically by the review lane, **not** an ITP comment. It does
  **not** route through `itp_post_comment`.
- The **fallback verdict comment** (the `post-verdict.sh` issue comment that
  INV-78 scrapes only when the artifact is absent, and the
  `Review PASSED` / `Review findings:` + `Review Session:` / `Review Agent:`
  trailer it carries) **IS** an issue-level machine marker and therefore **MUST**
  post through `itp_post_comment` on the declared `marker_channel` (§4), exactly
  like every other dispatcher/agent marker ([INV-89](invariants.md#inv-89-every-machine-marker--agent-and-dispatcher-inv-18inv-39-included--is-posted-only-through-the-declared-marker_channel-the-read-side-capture-regex-branches-on-channel)).
  A `text`-channel provider (Asana) thus carries the fallback verdict comment
  through the plain `text` field, never a sanitizing rich field.

So: **artifact-first stays artifact-first (does not become an ITP call); the
comment fallback becomes an `itp_post_comment` call.** This keeps the INV-78
(issue-cited INV-77) file-first-comment-fallback contract intact while routing
the comment half through the ITP marker choke-point. No verdict-channel behavior
changes in this PR — this only documents which seam each half belongs to so the
GitLab/Asana PRs
don't re-cut it.

---

## §auth — per-seam ownership boundary [M9]

Auth is a **per-SEAM concern, not a GitHub monolith.** A v1 framing folded
`lib-auth.sh` / `gh-app-token.sh` into "the GitHub provider" as one unit. But the
headline `asana`/`github` topology authenticates to Asana (ITP) and GitHub (CHP)
with **two independent credential lifecycles**, and the two concerns are *already*
separable inside GitHub today:

- the **[INV-83]** cross-repo scoped-token mint (`resolve_dep_state` → dependency
  lookup) is **ITP-side** (it is an issue-tracker read), and
- the **[INV-79]** approve/merge App token (the wrapper-held full-write token that
  is the sole approve/merge/PR-create path) is **CHP-side** (it is a code-host
  write).

So each seam owns its own auth context: an **ITP auth context** and a **CHP auth
context**, each provided by the provider bound to that seam. The token-refresh
daemon stays with whichever GitHub seam(s) are active.

**For `github`/`github` (today) they resolve to the SAME token** — zero change.
For `asana`/`github` the Asana ITP and the GitHub CHP each authenticate
independently. **GitHub auth code is UNCHANGED in this PR** — this section
documents the ownership cut only, so the later GitLab/Asana PRs don't re-cut it.
`REPO` / `GH_AUTH_MODE` / `*_APP_ID` / `*_APP_PEM` stay as the GitHub provider's
config namespace (§3.4).

---

## Mapping appendix — verb↔current-function

How today's behavior maps onto the contract. Each `~18` moved function is tagged
**(a) separable-leaf** or **(b) entangled** per §7.1; only the innermost I/O leaf
becomes a verb, the surrounding INV-coupled logic stays caller-side.

| Current function / site | Verb it backs | Class (§7.1) | Cut line |
|---|---|---|---|
| `count_active` (`lib-dispatch.sh:35`) | `itp_count_by_state` | (a) separable-leaf | the `gh issue list … \| jq length` integer move; numeric compare stays caller-side |
| `list_new_issues` (`:47`) | `itp_list_by_state` | (a) separable-leaf | the state-filtered `gh issue list` enumeration leaf |
| `list_pending_review` (`:73`) | `itp_list_by_state` | (b) entangled | leaf moves; the terminal-state jq subtraction ([INV-25] defense-in-depth) stays caller-side |
| `list_pending_dev` (`:91`) | `itp_list_by_state` | (b) entangled | same [INV-25] subtraction stays caller-side |
| `list_stale_candidates` (`:110`) | `itp_list_by_state` | (a) separable-leaf | the staleness-window enumeration leaf |
| `list_hygiene_residue` (`:143`) | `itp_list_forbidden_combos` | (a) separable-leaf | the [INV-25] forbidden-combination query leaf |
| `label_swap` (`lib-dispatch.sh`) | `itp_transition_state` | (a) separable-leaf | the atomic remove+add `gh issue edit` — **migrated #283** (the `mark_stalled` inline `pending-dev→stalled` edit was folded into a `label_swap` call so every transition funnels through the one verb) |
| `resolve_dep_state` (`:348`) | `itp_resolve_dep` + `itp_begin_tick` | (b) entangled | leaf lookup → `itp_resolve_dep`; [INV-83] scoped-token mint + `_DEP_TOKEN_CACHE` → provider behind `itp_begin_tick`; the `## Dependencies` parse stays caller-side |
| `check_deps_resolved` (`:438`) | `itp_read_task` + `itp_resolve_dep` | (b) entangled | `gh issue view --json body` + the per-ref lookup become verbs; the parse + block/proceed decision stay caller-side |
| `mark_stalled` (`lib-dispatch.sh`) | `itp_post_comment` + `itp_transition_state` | **(b) entangled multi-op orchestrator** | **leaf I/O migrated #283**: its comment posts → `itp_post_comment`, its `pending-dev→stalled` edit → `label_swap` (→ `itp_transition_state`); the NON-host ops (`pid_alive`, log truncate) stay caller-side. The orchestrator restructuring itself is owned by entangled-orchestrators-golden-trace |
| `handle_completed_session_routing` (`lib-dispatch.sh`) | `itp_post_comment` + `itp_transition_state` (+ dispatch) | **(b) entangled multi-op orchestrator** | **leaf I/O migrated #283**: all comment posts → `itp_post_comment`, label moves → `label_swap`; the [INV-35]/[INV-85] routing decision + `dispatch dev-new` + log truncate stay caller-side |
| `post_dispatch_token` (`lib-dispatch.sh`) | `itp_post_comment` | (a) separable-leaf | the [INV-18] dispatcher-marker comment write — routes through the ITP choke-point ([INV-89]) — **migrated #283** (marker BODY composed caller-side, verbatim) |
| `_dep_block_comment` (`lib-dispatch.sh`) | `itp_post_comment` | (a) separable-leaf | the [INV-39] dependency-block dispatcher-marker comment write — **migrated #283** (the dedup READ stays on `itp_list_comments`) |
| `resolve_pr_for_issue` (`lib-pr-linkage.sh:73`) + `verify_pr_closes_issue` (`:99`); `fetch_pr_for_issue` (`lib-dispatch.sh`) is the kept same-named delegate shim | `chp_find_pr_for_issue` | (b) entangled | the `gh pr list --json $FIELDS` leaf moves with `FIELDS` forwarded byte-identically ([M1]); the [INV-86] close-linkage/branch resolution + projection `$q` stay caller-side. **MIGRATED #282.** (Post-#277 `fetch_pr_for_issue` is a pure delegate to `resolve_pr_for_issue` — that delegate stays as the function-mock shim, §7.2 m3.) |
| `ci_is_green` (`lib-dispatch.sh`) | `chp_ci_status` | (a) separable-leaf | the `gh pr checks --json state -q '[.[].state]'` leaf moves; the `length>0 and all(.=="SUCCESS")` gate → `green`/`pending`/`failed`/`none` stays caller-side. **MIGRATED #282.** |
| `autonomous-review.sh` mergeable poll (`gh pr view … --json mergeable`) | `chp_mergeable` | (b) entangled | only the `gh pr view --json mergeable` leaf moves ([M2]); the UNKNOWN-retry loop + `_classify_mergeable_gate`/`_pr_open_gate` ([INV-44]/[INV-54], `lib-review-mergeable.sh` byte-unchanged) stay caller-side. **MIGRATED #282.** |
| `gh pr create` (the broker `drain_agent_pr_create`, `lib-auth.sh`) | `chp_create_pr` | (a) separable-leaf | the `gh pr create --head/--title/--body` leaf; the broker routes through the verb (leaf-only swap, no INV-79 change). **MIGRATED #282.** |
| `gh pr review --approve` (`autonomous-review.sh` PASS path) | `chp_approve` | (a) separable-leaf | the `--approve --body …` leaf; the [INV-52]/[INV-79] wrapper-owns-approve ownership + PASS-gate chain stay caller-side. **MIGRATED #282.** |
| `gh pr review --request-changes` (`submit_request_changes`, `lib-review-request-changes.sh`) | `chp_request_changes` | (b) entangled | the `--request-changes --body $body` leaf; gated by `rest_request_changes` (§4.2). The best-effort return-0 + token-refresh glue stays caller-side. **MIGRATED #282.** |
| `gh pr merge` (`autonomous-review.sh` merge path) | `chp_merge` | (a) separable-leaf | the `--squash --delete-branch` leaf. [M4]/[INV-33]: `merge_closes_issue=1` (GitHub) means the wrapper MUST NOT transition post-merge; a `merge_closes_issue=0` backend transitions via `itp_transition_state` (else github-gated `gh issue close`). **MIGRATED #282.** |
| `resolve-threads.sh` reviewThreads list + `resolveReviewThread` mutation | `chp_review_threads` / `chp_resolve_thread` | (a) separable-leaf | the two `gh api graphql` leaves → the M8 thread shape `{thread_id, resolved, comments:[{id, path, line, …}]}`; the select-unresolved + resolved/failed tally stay caller-side. **MIGRATED #282.** |
| bot-trigger post (the broker `drain_agent_bot_triggers`, `lib-auth.sh`; `gh-as-user.sh pr comment`) | `chp_trigger_bot` | (a) separable-leaf | the real-user trigger post, gated by `review_bots` (§4.2); `parse_review_bots`/login mapping + allow-list stay caller-side; the broker routes through the verb. **MIGRATED #282.** |
| incidental `gh pr view $PR --json …` reads + body-mention `gh pr list … select(.body\|test("#N"))` lookups (`autonomous-dev.sh` / `autonomous-review.sh`) | `chp_pr_view` / `chp_pr_list` (general read primitives) | (a) separable-leaf | the PR-number-keyed `gh pr view` + loose body-mention `gh pr list` leaves; caller keeps its `--json`/`-q`. NOT named §3.2 lifecycle verbs — added so the caller layer carries zero executable raw `gh pr`. **MIGRATED #282 (review r8).** |
| `setup-labels.sh:47` `gh label create` | `itp_provision_states` | (a) separable-leaf | the state-primitive provisioning leaf; hex color gated by `label_colors` — **migrated #283** (the 9-label table stays caller-side) |
| `reply-to-comments.sh:44-45` | `itp_post_comment` (returning `id`/`url`) | (a) separable-leaf | the reply-comment POST leaf returning `{id, url}` — this is a CHP review-thread reply (`pulls/.../comments`), owned by chp-pr-lifecycle, NOT migrated in #283 |
| `lib-review-e2e.sh` PATCH ([INV-46]) | `itp_edit_comment` | (a) separable-leaf | the edit-in-place PATCH leaf; gated by `edit_comment` — **migrated #283** (GET-comment-id / GET-body reads stay caller-side; `edit_comment=0` → `itp_post_comment` re-posts the full report body + marker, never marker-only) |
| `Closes #${issue_num}` literals (`autonomous-dev.sh` PR-body prompts) | `chp_close_keyword` | (a) separable-leaf | the hardcoded auto-close keyword becomes a verb-rendered string ([M4]); caps-aware `_render_close_keyword` renders `Related to #N` (non-closing) when `merge_closes_issue=0`+`native_issue_pr_link=0`. **MIGRATED #282.** |

> `mark_stalled` and `handle_completed_session_routing` are explicitly **entangled
> multi-op orchestrators** — they are the load-bearing examples that "the caller
> logic doesn't move" is *incomplete*: after the refactor they call 5+ verbs and
> retain all their non-host ops caller-side.

---

## Cross-references

- [`invariants.md` § INV-87](invariants.md#inv-87-provider-dispatch-is-spec-defined--callers-route-every-issuecode-host-op-through-itp_chp_-never-a-raw-gh-in-the-caller-layer) — provider dispatch is spec-defined (this document).
- [`invariants.md` § INV-88](invariants.md#inv-88-the-github-caps-manifests-describe-current-behavior-exactly-the-no-behavior-change-anchor--honestly-declared-not-all-ones) — GitHub `.caps` = today's behavior (the no-behavior-change anchor).
- [`invariants.md` § INV-89](invariants.md#inv-89-every-machine-marker--agent-and-dispatcher-inv-18inv-39-included--is-posted-only-through-the-declared-marker_channel-the-read-side-capture-regex-branches-on-channel) — the `marker_channel` pin.
- [`invariants.md` § INV-90](invariants.md#inv-90-the-normalized-issue-comment-shape-is-id-author-body-createdat-sorted-ascending-by-createdat-with-author-a-machine-handle-for-exact-equality) — the normalized comment shape.
- [`invariants.md` § INV-78](invariants.md#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent) — the verdict-artifact channel (issue #279 cites it as INV-77; renumbered to INV-78) reconciled above.
- [`invariants.md` § INV-79](invariants.md#inv-79-in-app-mode-the-agent-process-gets-only-a-scoped-token-the-wrapper-keeps-full-write-and-is-the-sole-approvemergepr-create-path) / [INV-83](invariants.md#inv-83-cross-repo-dependency-lookups-use-a-per-dep-repo-scoped-read-token-the-app-must-be-installed-on-the-dep-repo) — the per-seam auth cut (CHP-side / ITP-side).
- [`adapter-spec.md`](adapter-spec.md) — the agent-CLI adapter spec this provider spec mirrors ([INV-66]/[INV-75]).
- [`state-machine.md`](state-machine.md) — the abstract pipeline states the ITP renders per-backend.
