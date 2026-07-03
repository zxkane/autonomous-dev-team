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
| `itp_list_by_state STATE LABELS_AND_CSV LIMIT FIELDS_CSV` | `list_new_issues` (`lib-dispatch.sh:47`), `list_pending_review` (`:73`), `list_pending_dev` (`:91`), `list_stale_candidates` (`:110`) | **ABSTRACT contract ([W1a], #371) — no gh flags and no jq programs cross the seam.** `STATE` ∈ `open\|closed\|all`. `LABELS_AND_CSV` = comma-separated label names combined with AND semantics, empty = no label filter. `LIMIT` = positive int, applied **server-side** to the AND-labels-filtered candidate set **before any caller-side subtraction** (same pipeline point as the pre-W1a `gh --limit`). `FIELDS_CSV` ⊆ `number,title,labels,comments`. Returns a JSON array of objects with EXACTLY the requested fields, normalized: `number` (int), `title` (string), `labels` (array of label-NAME strings — not `{name}` objects), `comments` (the [INV-90] normalized comment array, ascending by `createdAt`). Canonical sort: `number` ascending — the leaf pins ONE order regardless of `gh`'s default. No matches → `[]` (never null/empty string). **MUST return the full set** (provider walks pagination internally — see §3.5). Caller-side predicates (the [INV-25] terminal-state subtraction, negation) are re-derived by the caller by filtering the returned normalized array — they do NOT travel as a jq program. **Asserted** (shape/sort/fail-closed) by `tests/provider-conformance/run-provider-conformance.sh` (#370, R6). |
| `itp_count_by_state STATE LABELS_AND_CSV LIMIT ANY_OF_LABELS_CSV` | `count_active` (`:35`, returns an **integer**) | **ABSTRACT contract ([W1a], #371).** Same enumeration point as `itp_list_by_state` (state/labels-AND/limit); returns a bare non-negative INTEGER — the count of AND-matches that additionally carry AT LEAST ONE label from `ANY_OF_LABELS_CSV` (empty any-of = count all AND-matches). Distinct verb because `count_active` returns an int the dispatcher compares numerically (`dispatcher-tick.sh` concurrency gate); forcing callers to enumerate+count would lose the server-side count semantics and change failure behavior. **[M3]** **Asserted** by `tests/provider-conformance/run-provider-conformance.sh` (#370, R6). |
| `itp_list_forbidden_combos STATE LABELS_AND_CSV LIMIT` | `list_hygiene_residue` (`:143`) | **ABSTRACT contract ([W1a], #371).** Same enumeration point as `itp_list_by_state`. Returns the normalized array shape with fields `number,labels`, already filtered to the **[INV-25] forbidden label combination** — the LEAF owns the combo filter (server-side-optimizable for providers with query languages): terminal set = `{approved, stalled}`; transitional set = `{in-progress, reviewing, pending-review, pending-dev}`; forbidden = terminal AND transitional. This is the ONE deliberate exception to "predicates stay caller-side" — `list_hygiene_residue` is now a thin pass-through. Distinct verb because a single `STATE` set cannot express an intersection-of-incompatible-states query. **[M3]** **Asserted** by `tests/provider-conformance/run-provider-conformance.sh` (#370, R6). |
| `itp_transition_state ISSUE REMOVE ADD` | `label_swap` (`:1986`); the four live-wrapper label-flips (`autonomous-dev.sh` PR-found, `autonomous-review.sh` approved-flip + auto-merge-fail re-queue, `lib-dispatch.sh::hygiene_strip_residual_labels`) — migrated **#331** | Atomic state move (remove REMOVE, add ADD). **REMOVE and ADD are each one label OR a comma-separated LIST** ([INV-97], #331) — a single label is a CSV of length 1, so every 3-positional single-label caller is byte-identical; a CSV emits one `--remove-label`/`--add-label` per non-empty member, an empty member is dropped, an empty side omits its flag. This expresses the multi-`--remove-label` Part-A flips (e.g. `"in-progress,pending-dev"`) atomically ([INV-08]) without a remove-only verb. GitHub: one `gh issue edit --remove-label … [--remove-label …] --add-label …`. **Precondition:** the comma is the member separator — a label name that itself contains `,` is unsupported via this path (it would split); inert for the pipeline (all labels are comma-free; `hygiene_strip`'s CSV is built from a hardcoded comma-free jq allowlist). The split is a pure `IFS=,` shell op on label names fed to argv (not a jq pattern) — no injection. **Note:** the terminal-state jq subtraction in `list_pending_review`/`list_pending_dev` ([INV-25] defense-in-depth) stays **caller-side**, not in this verb. **Asserted** by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `itp_read_task ISSUE FIELD` | `gh issue view --json title,body,state` sites | Return `title` / `body` / `state` for one task. **CONTRACT-PENDING** (#370). |
| `itp_post_comment ISSUE BODY` | every `gh issue comment` site (agent **and** dispatcher — incl. `post_dispatch_token` ([INV-18], `lib-dispatch.sh:1227`), `_dep_block_comment` ([INV-39], `:400`) — see [M6]) | Post a progress / verdict / audit / dispatcher-marker comment **through the provider's declared `marker_channel`** (§4). The single choke-point for ALL machine markers. MAY return the new comment's `id`/`url` (matches `reply-to-comments.sh:44-45`). **Asserted** by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `itp_edit_comment ISSUE COMMENT_ID BODY` | `lib-review-e2e.sh:486` (`gh api -X PATCH …/issues/comments/${id}`, [INV-46] SHA stamp) | Edit a comment in place. **New verb [M5]** — an append-only `itp_post_comment` could not satisfy the [INV-46] evidence-marker stamp, which GETs the last bot comment's `id` then PATCHes it. Capability-gated: a backend without edit (`edit_comment=0`) falls back to re-posting **the full report body WITH the marker appended** as a fresh comment (NOT a marker-only post — `_fetch_sha_evidence` returns the `last` SHA-marked comment's full body, so a marker-only fallback would pass the E2E gate with no report/screenshots/AC; [INV-46]). **Asserted** (gh-only; SKIPped when `edit_comment=0`) by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `itp_list_comments ISSUE` | every issue-level `gh issue view --json comments -q …` site (28 sites) | Return ISSUE-level comments as a **normalized JSON array** `[{id, author, body, createdAt}]`, **sorted ascending by `createdAt` (normative MUST** — the `\| last` / `sort_by(.createdAt)` idioms depend on it). `id`/`author`/`createdAt` contract pinned in §3.3. **Scoped to issue-level comments only** — review-thread / inline-PR comments are a separate CHP shape (§3.2, [M8]). **Asserted** (shape + malformed-JSON handling) by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `itp_resolve_dep REF` | `resolve_dep_state` (`lib-dispatch.sh`) / `check_deps_resolved` leaf I/O only | Given a dependency ref, write the abstract state `OPEN`/`CLOSED`/`MERGED` (GitHub PR refs report `MERGED`; empty on lookup failure) into the caller's out-var. **Realized as `itp_resolve_dep OWNER_REPO NUM OUT_VAR`** (the abstract `REF` is the `OWNER_REPO`+`NUM` pair) — the **out-var (`printf -v`) contract is mandatory** so the [INV-83] per-dep-repo scoped-token mint + tick-scoped `_DEP_TOKEN_CACHE` (which **move into the provider**, GitHub leaf `itp_github_resolve_dep`, behind the `itp_begin_tick` lifecycle hook — see §3.6) mutate the cache in the caller's shell, not a command-substitution subshell. The `## Dependencies` body parse, the [INV-11] CLOSED/MERGED predicate, and the block/proceed decision stay **caller-side**. The cross-repo `owner/repo#N` ref form is capability-gated (§4: `cross_ref_shorthand=1` for GitHub); the same-repo `#N` arm resolves against `$REPO` with the mint skipped (ambient token). A provider that has **not implemented the leaf** (`itp_${ISSUE_PROVIDER}_resolve_dep` absent — the always-present shim would otherwise call an undefined function) makes `check_deps_resolved` **skip dependency-gating** (proceed, no block, no `set -e` abort) — it cannot evaluate deps through the seam; GitHub defines the leaf so production gating is intact. **Migrated #284.** **Asserted** (fail-soft contract, same-repo arm) by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `itp_mark_checkbox ISSUE SELECTOR` | `mark-issue-checkbox.sh` | Mark a task sub-item done. GitHub: tick a body markdown checkbox. Capability-gated (§4: `body_checkbox`). **Asserted** (gh-only; SKIPped when `body_checkbox=0`) by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `itp_provision_states` | `setup-labels.sh:47` (`gh label create --color <hex>`) | Provision the backend's state primitives (GitHub: create the 9 pipeline labels). **New verb [m5]** — was an un-refactored ITP write surface. Hex color is a GitHub/GitLab concern (gate via the `label_colors` cap); Asana creates single-select options instead. **[#362] existence check**: the leaf probes existence via `gh api repos/<repo>/labels/<name> --silent` (a REST GET, rc 0 = exists), NOT `gh label view` — `gh label` has no `view` subcommand (only `clone/create/delete/edit/list`), so the pre-#362 check always failed and the leaf always fell through to `gh label create`, aborting under `set -e` on any pre-existing label. **Asserted** by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `itp_caps` | — (new) | Emit the capability map (§4). Resolved to a declarative `.caps` manifest + thin reader (§6). |
| `itp_begin_tick` | `dispatcher-tick.sh` `_reset_dep_token_cache` call + the `_DEP_TOKEN_CACHE` declaration ([INV-83]) | Tick-lifecycle hook — see §3.6. The dispatcher calls it **once** before Step 2; the GitHub provider's leaf `itp_github_begin_tick` owns `_DEP_TOKEN_CACHE` (declared + reset internally) and is the new home of the body previously in `lib-dispatch.sh::_reset_dep_token_cache`. **New verb [m2]; migrated #284**. |
| `itp_label_event_ts ISSUE LABEL` | `dispatcher-tick.sh` Step-2 TTHW timeline read (`gh api …/issues/<n>/timeline --jq …`, the [INV-70] `labeled_at`) | **Observe-only / non-blocking** ([INV-93]). Echo the ISO-8601 UTC `created_at` of the FIRST `labeled` event for `LABEL` visible in the provider's existing timeline read, or **empty** if none / on failure / leaf-absent — the aggregator then falls back to the dispatch-instant event `ts`. A **focused verb**: the `event`/`.label.name`/`.created_at` fields are GitHub-internal timeline vocabulary with no provider-neutral shape, so the leaf owns the query and returns a neutral **scalar** (the documented [#281](#) exception — "jq stays caller-side" governs provider-NEUTRAL shapes — mirroring `itp_count_by_state` returning an int / `itp_resolve_dep` returning an abstract state; NOT the §3.3 comment-array shape). The leaf **JSON-encodes** `LABEL` into the jq string literal (injection-safe: a raw `${label}` interpolation would widen the selector / be a jq syntax error; the `--arg` name MUST be `lbl` because jq 1.6 reserves `label`, and `gh api` has no `--arg` so the label is pre-encoded, not bound). Best-effort: the GitHub leaf keeps today's single non-paginated `gh api …/timeline` read. The TTHW math, the `issue_labeled` emit, and the `labeled_at`-vs-`ts` preference all stay **caller-side**. **New verb [m]; migrated #323.** **Asserted** (fail-soft contract) by `tests/provider-conformance/run-provider-conformance.sh` (#370). |

> **Implementation status.** The READ leaves `itp_read_task` / `itp_list_comments`
> are **migrated for the GitHub backend in #281** (`providers/itp-github.sh`),
> proven byte-identical by golden-trace
> ([`tests/unit/test-itp-read-leaves.sh`](../../tests/unit/test-itp-read-leaves.sh)).
> **The state-read leaves — `itp_list_by_state`/`itp_count_by_state`/
> `itp_list_forbidden_combos` — were migrated from a byte-identical gh-argv
> passthrough to the ABSTRACT contract above in #371 (W1a, #347 phase-2).** This
> is a deliberate SHAPE change (the byte-identical constraint is explicitly
> lifted for these three verbs), proven by DECISION-level behavior-parity tests
> ([`tests/unit/test-w1a-state-read-parity.sh`](../../tests/unit/test-w1a-state-read-parity.sh))
> instead of argv golden traces: for each of the six `lib-dispatch.sh` callers,
> OLD (pre-#371) and NEW select the same issue-number set / count / branch
> decision on four fixture classes (normal, empty, over-limit, terminal-label
> residue). Leaf-level shape/argv/fail-closed coverage lives in
> [`tests/unit/test-w1a-state-read-contracts.sh`](../../tests/unit/test-w1a-state-read-contracts.sh).
> Every downstream consumer of the old `.labels[].name` object-array shape
> (`dispatcher-tick.sh` Step 5, `_has_terminal_label`,
> `hygiene_strip_residual_labels`) was rewritten in the same PR to consume the
> new name-string array. **The WRITE leaves —
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
> caller-side. **Correction (#362)**: the byte-identical claim for
> `itp_provision_states` covers the CREATE-branch argv only. The migration
> ALSO faithfully preserved a pre-existing bug in the existence-check branch —
> `gh label view`, a subcommand that has never existed on real `gh` (only
> `clone/create/delete/edit/list`) — which always failed and always fell
> through to `gh label create`, aborting `setup-labels.sh` under `set -e` on
> any repo with a pre-existing pipeline label. #362 fixed the existence check
> (a REST probe, `gh api repos/<repo>/labels/<name> --silent`) without
> touching the create-branch argv, so the byte-identical claim now holds for
> real. **The dependency-resolution + tick-lifecycle leaves —
> `itp_resolve_dep`/`itp_begin_tick` — are migrated for the GitHub backend in
> #284** ([INV-83],
> [`tests/unit/test-itp-resolve-dep-golden-trace.sh`](../../tests/unit/test-itp-resolve-dep-golden-trace.sh)):
> `itp_github_resolve_dep` owns the cross-repo + same-repo `gh issue view --json
> state` leaf, the per-dep-repo scoped-token mint, the `_DEP_TOKEN_CACHE`, the
> `DEP_LOOKUP_PERMISSIONS` default, and the `get_gh_app_scoped_token` lazy-source;
> `itp_github_begin_tick` owns the tick-boundary cache reset.
> `lib-dispatch.sh::resolve_dep_state` is a thin wrapper forwarding to
> `itp_resolve_dep` (out-var contract preserved); `dispatcher-tick.sh` calls
> `itp_begin_tick` once before Step 2; the `## Dependencies` parse, the [INV-11]
> predicate, the fail-safe block, and the `_dep_block_comment` call stay
> caller-side, with the cross-repo arm gated on `cross_ref_shorthand`
> (`grep -c 'gh issue view .*--json state' lib-dispatch.sh` == 0).
> **The observe-only TTHW timeline read — `itp_label_event_ts` — is migrated for
> the GitHub backend in #323** ([INV-93],
> [`tests/unit/test-label-event-ts.sh`](../../tests/unit/test-label-event-ts.sh)):
> `itp_github_label_event_ts` owns the `gh api …/issues/<n>/timeline --jq …` read
> (JSON-encoding the label, injection-safe) and returns the first `labeled`-event
> timestamp scalar; the `dispatcher-tick.sh` Step-2 emit routes through the verb
> behind the bare `itp_${ISSUE_PROVIDER}_label_event_ts` guard, closing
> `dispatcher-tick.sh` as a raw-`gh` caller (cutover baseline 67 → 66 signatures).
> The TTHW math + `issue_labeled` emit + `labeled_at`-vs-`ts` preference stay
> caller-side; it never blocks dispatch.

### 3.2 Code-Host Provider (CHP) verbs

**What this section owns (normative, #367).** Every verb named in the table
below is a dispatchable CHP verb — the full set this section normatively
owns, **18 table rows naming 19 verbs** (one row, `chp_review_threads` /
`chp_resolve_thread`, names two verbs sharing one contract cell). This
includes the 11 named PR-lifecycle verbs (`chp_find_pr_for_issue` …
`chp_close_keyword`), the 3 general read/write primitives added for the
incidental-PR-I/O sites (`chp_pr_view`/`chp_pr_list`/`chp_pr_comment`, #282
review r8 / #329), and the 4 focused single-purpose verbs added by later PRs
(`chp_list_inline_comments` #328, `chp_reply_review_comment` #327,
`chp_count_reviews_by_login` #324, `chp_commit_file` #330). **`chp_caps` is a
verb too** — it is the capability-map reader, not a leaf-dispatching shim.
**`chp_has_leaf` is explicitly NOT a verb** — it is a caller-side guard helper
(`declare -F chp_${CODE_HOST}_<verb>`) that never appears in a `.caps`
manifest or forwards `"$@"` to a leaf; it is footnoted here, not tabled,
precisely so a future mint does not miscount it as a 20th verb. The GitHub
reference implementation (`lib-code-host.sh`) therefore defines **20
top-level `chp_*()` functions**: the 19 verb shims (18 table rows) + the 1
non-verb `chp_has_leaf` guard helper. Where a count needs to appear in prose
elsewhere in this repo, prefer citing "the §3.2 table (18 rows / 19 verbs)"
over a bare number, so the next mint does not re-drift the prose.

| Verb | Replaces | Contract |
|---|---|---|
| `chp_find_pr_for_issue ISSUE FIELDS` | `fetch_pr_for_issue` (`lib-dispatch.sh:1471`, signature is `(issue_num, FIELDS)`) | Return PR JSON projected to the **caller-supplied `FIELDS`** field list, or empty. **`FIELDS` is a REQUIRED arg [M1]** — every caller varies it (`number,headRefOid,body`; `number,mergedAt,reviews`; `number,headRefOid`; `number,body,updatedAt` / `number,body,headRefOid` in `dispatcher-tick.sh`; `number,reviewDecision,mergeable,state,body` in `status.sh`). The GitHub impl forwards `FIELDS` to `gh pr list --json $FIELDS` **byte-identically**. The documented field vocabulary MUST include `reviewDecision`, `mergeable`, `state`. Regression anchors: #148 (omitting `body` silently breaks the `select(.body\|test("#N"))` filter), #274. **CONTRACT-PENDING** (#370). |
| `chp_ci_status PR [extra gh args…]` | `ci_is_green` (`lib-dispatch.sh`) | **Current shipped contract (#367 correction):** a **focused-raw** leaf, the `chp_mergeable` shape — the caller supplies the `--json state -q '[.[].state]'` tail and the leaf forwards it byte-identically to `gh pr checks PR --repo $REPO "$@"`, returning the RAW per-check state array (e.g. `["SUCCESS","SUCCESS"]`). The `length>0 and all(.=="SUCCESS")` boolean gate that `ci_is_green` applies to that array **stays caller-side**; `ci_is_green` itself returns a boolean (`rc 0`/`1`), never a string. **Target contract — W1(d) (out of scope here):** normalizing the leaf itself to return one of `green`/`pending`/`failed`/`none` — the tokens this cell previously (incorrectly) claimed are produced today — is the still-open W1(d) slice; see the Mapping appendix row below for the as-shipped cut line. **CONTRACT-PENDING** (#370). |
| `chp_mergeable PR [extra gh args…]` | **`autonomous-review.sh`** (`gh pr view … --json mergeable`), **NOT** `lib-review-mergeable.sh` | **Focused-raw** leaf: the caller supplies the `--json mergeable -q '.mergeable'`(or similar) tail and the leaf forwards it byte-identically to `gh pr view PR --repo $REPO "$@"`, returning the **raw backend `mergeable` token** (`MERGEABLE`/`CONFLICTING`/`UNKNOWN`/empty). **[M2]** `lib-review-mergeable.sh` is PURE classifiers (`_classify_mergeable_gate`, `_pr_open_gate`, [INV-44]/[INV-54]) doing zero gh I/O — its own header says the query "stays in the wrapper". Those classifiers **stay in the provider-neutral caller layer** and consume the verb's raw token; only the `gh pr view` leaf moves behind the verb. **CONTRACT-PENDING** (#370). |
| `chp_create_pr …` | `gh pr create` site(s) | Create PR/MR. **CONTRACT-PENDING** (#370). |
| `chp_approve PR` | `gh pr review --approve` | Approve. **CONTRACT-PENDING** (#370). |
| `chp_request_changes PR` | `gh pr review --request-changes` | Request changes. Capability-gated (§4: `rest_request_changes`). **Asserted** (gh-only; SKIPped when `rest_request_changes=0`) by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `chp_merge PR` | `gh pr merge` | Merge. **Cross-seam note [M4]:** on GitHub, merging a PR whose body carries `Closes #N` performs the ITP terminal transition as a **side effect** ([INV-33] — the wrapper MUST NOT call `gh issue close`). This coupling is now explicit via the `merge_closes_issue` capability (§4) — when absent, the caller MUST call `itp_transition_state` after `chp_merge`. **CONTRACT-PENDING** (#370). |
| `chp_review_threads PR` / `chp_resolve_thread …` | `resolve-threads.sh`, `lib-review-resolve.sh` | Review-thread I/O. **Separate shape from `itp_list_comments` [M8]:** `{thread_id, resolved, comments:[{id, path, line, author, body, createdAt}]}`. `resolve-threads.sh` selects GraphQL `reviewThreads.nodes[]\|select(.isResolved==false).id` and resolves by `threadId`; inline fields (`.path`/`.line`/`.original_line`, `autonomous-dev.sh`) are CHP-owned, never folded into the ITP issue-comment shape. **Known cut-line (§3.5):** the GitHub leaf's GraphQL walk is `reviewThreads(first: 100)` with no cursor pagination — §3.5 mandates the COMPLETE set; a PR with >100 threads is under-covered on GitHub today. Fixing the cursor walk is **W1(f)**, out of scope here — this cell only documents the known gap so the spec stops overclaiming completeness for this one leaf. **Asserted** (shape only, NOT pagination completeness) by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `chp_list_inline_comments PR` | the dev-resume `PR_REVIEW_COMMENTS` read (`autonomous-dev.sh`, the flat REST `gh api repos/$REPO/pulls/$PR/comments`) | Return the PR's **inline (file-anchored) review comments** — the comments the dev agent is told to address + reply-to + resolve. **New verb [INV-95]** (#296 second-tier, #328). **Separate shape** from `chp_review_threads` (GraphQL thread tree), `chp_pr_view` (no `pulls/N/comments` sub-resource), and `itp_list_comments` (issue-level normalized): the flat `.path`/`.line`/`.original_line` inline fields are **CHP-owned**, never folded into the ITP issue-comment shape. **Focused-raw** (#281): the leaf does no formatting; the caller threads its own `--jq` formatter (the `- **path:line** — body` prompt rendering) via `"$@"` byte-identically. **Self-guarding shim** (#282 convention, like `chp_pr_view`/`chp_pr_list`): invoked unguarded in a `$(… 2>/dev/null \|\| true)` site, so leaf-absent → WARN + `return 1` (degrades to empty), never a `set -e` abort. No `--paginate` today. **CONTRACT-PENDING** (#370). |
| `chp_pr_view PR [--json … -q …]` | the PR-number-keyed incidental reads (`autonomous-dev.sh` / `autonomous-review.sh`, e.g. `gh pr view $PR --json comments/state/headRefName/headRefOid/reviews`) | **General READ primitive** — NOT one of the named PR-lifecycle verbs above; added so the caller layer carries zero executable raw `gh pr view`. Forwards to `gh pr view PR --repo $REPO "$@"`; the caller keeps its own `--json`/`-q` projection, byte-identical. **Self-guarding shim** (#282 review round 9): invoked unguarded by the incidental-read call sites — leaf-absent → WARN + `return 1` (degrades to empty read), never a `set -e` abort. **MIGRATED #282 (review r8).** **CONTRACT-PENDING** (#370). |
| `chp_pr_list [--state … --json … -q …]` | the issue-keyed body-mention existence/number lookups (`autonomous-dev.sh`, e.g. `gh pr list … select(.body\|test("#N"))`) | **General READ primitive** — the loose body-mention PR list/existence lookup, DISTINCT from `chp_find_pr_for_issue` (the [INV-86] close-linkage resolver, which takes a REQUIRED `FIELDS` arg). Forwards to `gh pr list --repo $REPO "$@"`; caller keeps its own `--state`/`--json`/`-q`. Self-guarding shim, same convention as `chp_pr_view`. **MIGRATED #282 (review r8).** **CONTRACT-PENDING** (#370). |
| `chp_pr_comment PR [--body … \| extra args]` | the 7 PR-comment writes (`gh pr comment $PR` — auto-merge markers `autonomous-review.sh`, E2E-failure reports + the [INV-79] brokered E2E report `lib-review-e2e.sh`) | **General WRITE primitive** — the PR-comment sibling of `chp_pr_view`/`chp_pr_list`; DISTINCT from `itp_post_comment` (the ISSUE-level marker choke-point), different seam owner for a split-backend topology. Forwards to `gh pr comment PR --repo $REPO "$@"`; the caller keeps its own redirect/capture/gating framing (4 forms observed: `… 2>/dev/null \|\| true`, `if ! _err=$(… 2>&1 >/dev/null)`, `… 2>/dev/null \|\| rc=$?`, broker `… >/dev/null 2>&1`) — the leaf adds none. Self-guarding shim. **MIGRATED #329 (#296 second-tier), [INV-102].** |
| `chp_trigger_bot PR TRIGGER` | `lib-review-bots.sh` | Post a bot trigger. Capability-gated (§4: `review_bots`). |
| `chp_close_keyword ISSUE` | the `Closes #${ISSUE_NUMBER}` literal in the PR-body prompt (`autonomous-dev.sh:851/866/914/1151`) | Render the backend's PR-body auto-close keyword for the prompt builder to interpolate. **New verb [M4]** — the keyword was hardcoded GitHub-specific prompt text; a GitLab/Asana prompt builder would otherwise emit a non-functional `Closes #N`. GitHub returns `Closes #<n>`; a backend with `merge_closes_issue=0` returns empty (caller transitions explicitly post-merge). **Asserted** — the caller-side `_render_close_keyword` render contract (all 3 `merge_closes_issue`/`native_issue_pr_link` branches), not the leaf dispatch — by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `chp_reply_review_comment PR COMMENT_ID BODY` | `reply-to-comments.sh:41` (`gh api …/pulls/<n>/comments -X POST … in_reply_to=…`) | Reply to one PR **review comment** (`in_reply_to`). GitHub leaf emits `gh api "repos/$REPO/pulls/$PR/comments" -X POST -f body=$BODY -F in_reply_to=$COMMENT_ID --jq '{id, url}'` byte-identically; the caller composes `REPO="$OWNER/$REPO"` for the leaf's scope (owner/repo split + `COMMENT_ID` numeric sanitization stay caller-side). **New verb [INV-96], #327** — the last raw `gh` reply-POST site (the #283-deferred CHP review-thread reply). NOT capability-gated (a core code-host write); no injection pre-encode (`body`/`in_reply_to` are REST `-f`/`-F` fields, the `--jq '{id,url}'` a fixed literal). **Asserted** by `tests/provider-conformance/run-provider-conformance.sh` (#370). |
| `chp_count_reviews_by_login REPO PR LOGIN` | the inline review-count in `missing_bot_reviews` (`lib-review-bots.sh`, the [INV-79] bot-review hard-gate) | Return the **integer count** of reviews on PR (in REPO) by LOGIN, across ALL pages, or `0` on ANY failure. **[INV-94], #324.** The `--paginate` all-pages sum (`--jq '\|length'` emits one length per page) is a GitHub-transport artifact encapsulated in the leaf, returning a provider-neutral int (mirrors `itp_count_by_state`); the `^[0-9]+$` validation + the `-eq 0` MISSING decision STAY caller-side (mirrors `chp_mergeable`'s raw-token / classify-caller-side split). **REPO is an explicit param** (NOT global `$REPO`) — the caller threads its own `repo`. **Injection-safe**: LOGIN is JSON-encoded into the `--jq` string literal. **Fail-SAFE**: the leaf CAPTURES the read output and CHECKS its exit BEFORE summing, so a partial-pagination stream (page-1 length emitted, page-2 errors) → `0` → bot MISSING (never the pre-#324 fail-open where the swallowed exit summed page-1's count → false PRESENT). The 3 agent-facing prompt-prose `gh api …/reviews` heredoc lines in `lib-review-bots.sh` are NOT migrated (permanent residue). |
| `chp_commit_file REPO BRANCH FILE_PATH CONTENT_BASE64 MESSAGE` | the 8 raw git-Data-API `gh api` calls in `upload-screenshot.sh` (`git/ref` → `git/blobs` → `git/trees` → `git/commits` → `git/refs` → re-`git/ref` verify → `contents` GET → `contents` PUT) | **Whole-op write verb [INV-99]** — commit a single file onto a branch (creating an orphan branch if absent) and echo the committed blob SHA; non-zero on commit failure. GitHub has no single "commit one file to a branch" primitive, so the leaf IS the cohesive op's 8-call implementation (the `chp_review_threads`-wraps-a-whole-GraphQL-walk posture, NOT 8 thin shims); a GitLab backend is ONE Files API call (`POST …/repository/files/:path`, `encoding=base64`). `REPO` is threaded **explicitly** ($1, not a global — `upload-screenshot.sh` is a standalone util resolving its own `$REPO`, the #324 dropped-repo-arg lesson). `CONTENT_BASE64` is the provider-neutral currency (GitLab's Files API also takes `encoding=base64`). The local file-read + `base64 -w0` encode + the `[[ -n "$SHA" ]] \|\| fail` glue + the `/blob/` URL render stay caller-side. The leaf's temp-file cleanup uses a **self-disarming** function-scoped `trap '…; trap - RETURN' RETURN` (no `trap … EXIT` — clobbers the caller's EXIT trap; a BARE `trap … RETURN` — persists and re-fires on the `chp_commit_file` shim's return with the leaf's `local`s out of scope → `unbound variable` under `set -u`; both reproduced on-box — the self-disarm keeps the RETURN-trap contract while firing exactly once). |
| `chp_caps` | — (new) | Emit the capability map (§4). |

> **Implementation status (#367 sweep — covers the FULL 18-row/19-verb §3.2
> surface, not just the original 11-verb PR-lifecycle subset).** The 9
> golden-traced PR-lifecycle verbs —
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
> **defined** in `providers/chp-github.sh` (completing the verb contract), and
> their live executable leaves are the auth-side brokers (`drain_agent_pr_create`
> / `drain_agent_bot_triggers` in `lib-auth.sh`), which route through the verb
> (leaf-only swap, guarded on `chp_has_leaf`; byte-identical argv).
>
> **The remaining 8 verbs beyond the 11-verb PR-lifecycle set are ALSO
> migrated**, each by its own later PR: the 3 general read/write primitives
> `chp_pr_view` / `chp_pr_list` (#282 review r8) and `chp_pr_comment` (#329,
> [INV-102]) close the caller layer's incidental PR I/O — the issue-keyed
> body-mention `gh pr list … select(.body|test("#N"))` existence COUNT/number
> lookups (`autonomous-dev.sh`), the PR-number-keyed
> `gh pr view $PR --json comments/state/headRefName/headRefOid/reviews` reads
> (`autonomous-dev.sh` / `autonomous-review.sh`), and the 7 PR-comment writes
> are **no longer raw `gh`**. `chp_list_inline_comments` (#328, [INV-95])
> migrates the dev-resume inline-comment read. `chp_reply_review_comment`
> (#327, [INV-96]) migrates the review-comment reply POST. `chp_count_reviews_by_login`
> (#324, [INV-94]) migrates the bot-review hard-gate's review count. `chp_commit_file`
> (#330, [INV-99]) migrates `upload-screenshot.sh`'s 8-call git-Data-API commit
> op. `chp_caps` (#280) is the `.caps` capability-map reader, not a leaf-dispatch
> shim — it has no leaf to migrate. Every named verb in the §3.2 table is
> therefore DEFINED and, except `chp_caps`'s reader body, leaf-migrated; the
> caller layer carries zero executable raw `gh pr` (enforced by the cutover
> guard, §9/[INV-91]).
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
> is exempt — it has a real reader body, not a leaf-dispatching shim. The four
> general read+write primitives `chp_pr_view` / `chp_pr_list` (#282), the
> inline-comment read `chp_list_inline_comments` (#328), and `chp_pr_comment`
> (#329, the PR-comment WRITE primitive) are invoked unguarded by the
> incidental read/write sites, so the SHIMS themselves are **self-guarding**
> (#282 review round 9): when the enabled provider omits the leaf they emit a WARN
> and `return 1` (a clean non-zero the call sites' `|| echo/true/return` reads and
> `… 2>/dev/null || true` comment-writes already degrade on) rather than
> dispatching to an undefined leaf and aborting.
>
> The leaf-absent **fallback must still honor the capability contract**, not just
> avoid the abort: `chp_close_keyword`'s caller (`_render_close_keyword`) renders,
> when the leaf is absent AND `chp_caps merge_closes_issue=0`, a NON-auto-closing
> reference — `Related to #N` when `native_issue_pr_link=0` (so the body-grep
> PR-discovery still links the PR; `Related to` is not a GitHub close keyword) and
> the empty string when `native_issue_pr_link=1` — and the GitHub literal
> `Closes #N` only when `merge_closes_issue=1` or the cap is unreadable (#282
> review rounds 5-7). The leaf guard prevents the crash; the cap reads keep the
> rendered value both non-auto-closing AND discoverable. The matching post-merge
> transition (`autonomous-review.sh`) is likewise provider-gated: `itp_transition_state`
> when defined, else `gh issue close` only under `ISSUE_PROVIDER=github`, else a
> loud error (never a wrong GitHub close on a non-GitHub tracker).
>
> **Capability-fallback rows — the leaf-absent disposition of the three
> github-gated raw-`gh` residues (#296 second-tier, #346).** The three surviving
> leaf-absent fallbacks that could re-couple to GitHub are now each dispositioned
> as **spec-sanctioned github-gated residue** — the raw call is retained ONLY under
> an explicit backend-identity guard; a non-GitHub backend with the leaf absent
> fails LOUD (the #303/B1 + #327 no-silent-fallback pattern), never a silent GitHub
> call:
>
> | Site (`file`) | Leaf | Leaf-absent + `github` | Leaf-absent + non-github | Regression pin |
> |---|---|---|---|---|
> | `drain_agent_pr_create` (`lib-auth.sh`) | `chp_create_pr` | retained raw `gh pr create --repo … --head … --title … --body …` under `${CODE_HOST:-github} == "github"` (byte-identical; baselined [INV-91] residue) | loud `[INV-79]/[INV-91]` error, **NO** PR created (no-PR retry re-queues to pending-dev) | `test-token-split-234.sh` TC-FBDISP-001/010/020/041 |
> | `drain_agent_bot_triggers` (`lib-auth.sh`) | `chp_trigger_bot` | retained raw `gh-as-user.sh pr comment … --body <phrase>` under `${CODE_HOST:-github} == "github"` (the `gh-as-user.sh` transport wrapper is allowlisted, so no baseline entry) | loud `[INV-79]/[INV-91]` error checked ONCE before the posting loop, **NO** bot triggers posted | `test-token-split-234.sh` TC-FBDISP-002/011/021/041 |
> | `autonomous-review.sh:~3512` interim close | `itp_transition_state` | retained `gh issue close … --reason completed` under `${ISSUE_PROVIDER:-github} == "github"` (#282 round 7 — the [INV-33] single sanctioned interim close) | loud `TRANSITION_ERROR`, **NO** wrong `gh issue close` (a maintainer / the itp-writes verb completes the transition) | `test-chp-pr-lifecycle.sh` TC-CHP-CAP-MCI0-NONGH (**documentation-only** disposition in #346 — this site was already github-gated + pinned; no code change) |
>
> `${CODE_HOST:-github}` / `${ISSUE_PROVIDER:-github}` (the #327 precedent): an
> unset backend var defaults to `github`, i.e. today's exact behavior — the raw
> path is retained. Zero behavior change on the github/github topology; the retained
> raw calls stay baselined ([INV-91]) as residue with an explicit guard, so the
> cutover baseline neither grows nor shrinks for #346.

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
| `author` | a **stable machine handle for EXACT equality**, NOT a display name. GitHub: `user.login` **including the `[bot]` suffix verbatim**. Asana: `created_by.gid`. GitLab: `author.username`. | callers do exact `==` over the **normalized** `author` field: `lib-review-poll.sh` `_fetch_agent_verdict_body` (`.author == BOT_LOGIN`, #321 — was `.author.login` against gh's raw shape), `lib-dispatch.sh` [INV-85] (`select((.author // "") == $dev)`). A display name silently breaks `== $dev`. |
| `authorKind` | normalized enum `bot` / `human` / `self`. | lets `distinct_bot_author=0` backends (Asana w/o Service Accounts) satisfy bot/self discrimination that the raw `.author.login==BOT` jq cannot — the only path when the backend has no distinct bot identity. **New field [M5].** |
| `createdAt` | **ISO-8601 UTC string; the array is sorted ascending (normative MUST). The sort MUST be STABLE** — for two comments with an equal whole-second `createdAt` it preserves the backend's insertion order, so a `\| last` returns the later-inserted of a same-second tie. | the `\| last` and `sort_by(.createdAt) \| last` idioms (`classify_recent_review_verdict`) and the `.createdAt > cutoff` string compares (`count_agent_failures`, [INV-05]/[INV-57]) depend on order + format; `autonomous-dev.sh`'s `:1051` REVIEW_COMMENTS builder additionally relies on the **stable** tie-break to pick the most recent of two same-second findings (GitHub's `itp_github_list_comments` satisfies it via jq's stable `sort_by`). The verdict choke-point `_fetch_agent_verdict_body` (`lib-review-poll.sh`, #321) re-sorts caller-side on `sort_by(.createdAt // "", .id // 0) \| last` so a same-second verdict tie resolves to the newest comment **deterministically** via the monotone REST `id`, rather than relying on the producer's stable-sort alone (re-sorting an already-ascending array is idempotent — the producer MUST above is untouched). |

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

The cross-repo dependency lookup mints a **target-repo-scoped** GitHub-App token
and caches it in `_DEP_TOKEN_CACHE`, whose lifetime is **tick-scoped** and reset
once per tick ([INV-83] / #269). Moving the leaf behind `itp_resolve_dep` without
a lifecycle hook would either re-mint per ref (the #269 regression) or strand the
cache. So the ITP exposes an **`itp_begin_tick`** hook the dispatcher calls **once
before Step 2**.

**Realized in #284:** the GitHub provider's `itp_github_begin_tick`
(`providers/itp-github.sh`) owns `_DEP_TOKEN_CACHE` — it declares the cache at
provider-module scope and resets it (`unset` + `declare -gA`), exactly the body
that previously lived in `lib-dispatch.sh::_reset_dep_token_cache`. The leaf state
lookup + the per-dep-repo scoped-token mint + the `DEP_LOOKUP_PERMISSIONS` default
+ the `get_gh_app_scoped_token` lazy-source all live in `itp_github_resolve_dep`.
`dispatcher-tick.sh` calls `itp_begin_tick` once before Step 2 (the position
`_reset_dep_token_cache` occupied); `lib-dispatch.sh::resolve_dep_state` is a thin
wrapper forwarding `(owner_repo, num, out_var)` to `itp_resolve_dep` with the
out-var contract intact, so the cache mutation stays in the dispatcher's shell.
The `_DEP_TOKEN_CACHE` persists across the tick's `check_deps_resolved` calls
because `providers/itp-github.sh` is sourced once per dispatcher process (via
`lib-issue-provider.sh`, self-sourced by `lib-dispatch.sh`). Cross-namespace dep
resolution may need provider-internal token re-scoping ([INV-83]).

**`itp_begin_tick` is an OPTIONAL hook.** `lib-issue-provider.sh` ALWAYS defines
the `itp_begin_tick` shim (it forwards to `itp_${ISSUE_PROVIDER}_begin_tick`), but
a provider with no per-tick state (no token cache) legitimately implements no
leaf. The dispatcher therefore guards the call on the **provider leaf**
(`declare -F "itp_${ISSUE_PROVIDER}_begin_tick"`), NOT the always-present shim — an
absent leaf is a no-op, never a `command not found` abort under `set -e` (the
degraded fixture provider and any not-yet-migrated GitLab/Asana backend take this
no-op path). This preserves the pre-#284 `declare -F _reset_dep_token_cache`
no-op-when-absent guard semantics. The GitHub default DOES define the leaf, so the
reference dispatcher resets the cache every tick (#284 review [P1]).

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

### 4.4 Conformance verb → governing-cap map (#370, R4)

`tests/provider-conformance/run-provider-conformance.sh` parses the enabled
provider's `.caps` **before** asserting each of the R2 provider-neutral verbs.
The governing cap for a verb determines whether the runner asserts it for
real or emits a `SKIP <verb> (cap: <name>)` line. Mirrors
`tests/provider-conformance/cap-map.conf` (the runner's sourced data file) —
that file is the source of truth; this table exists so the mapping is visible
in the normative doc per Pipeline Documentation Authority.

| Verb | Governing cap | `0`/absent disposition |
|---|---|---|
| `itp_list_comments` | `-` (none) | always asserted |
| `itp_transition_state` | `-` (none) | always asserted |
| `itp_post_comment` | `-` (none) | always asserted |
| `itp_edit_comment` | `edit_comment` | `SKIP` |
| `itp_mark_checkbox` | `body_checkbox` | `SKIP` |
| `itp_provision_states` | `-` (none) | always asserted |
| `itp_resolve_dep` | `-` (none) | always asserted (fail-soft contract, same-repo arm) |
| `itp_label_event_ts` | `-` (none) | always asserted (fail-soft contract) |
| `chp_review_threads` | `-` (none) | always asserted (shape only) |
| `chp_resolve_thread` | `-` (none) | always asserted |
| `chp_request_changes` | `rest_request_changes` | `SKIP` |
| `chp_reply_review_comment` | `-` (none) | always asserted |
| `chp_close_keyword` | `-` (none) | always asserted (the caller-side `_render_close_keyword` render contract, not `chp_degraded_close_keyword` leaf dispatch — see the runner's design doc) |

A verb whose governing cap reads `0`/absent is **never** a FAIL for that
reason alone — it is a `SKIP` naming the cap. A verb whose caps are satisfied
but whose provider function is missing or wrong-shaped is a FAIL (the
provider broke its own capability declaration).

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
    itp-github.sh                # itp_github_*  — reference impl. READ leaves (list_by_state, count_by_state, list_forbidden_combos, read_task, list_comments) MIGRATED #281; WRITE leaves (transition_state, post_comment, edit_comment, mark_checkbox, provision_states) MIGRATED #283; dep/tick-lifecycle leaves (resolve_dep, begin_tick) MIGRATED #284 — no scaffolds remain
    itp-github.caps              # declarative capability manifest (parsed, not sourced)  (#280)
    chp-github.sh                # chp_github_*  — reference impl. ALL PR-lifecycle leaves MIGRATED #282; the general read/write primitives + focused verbs MIGRATED by their own #296-second-tier PRs (#324/#327/#328/#329/#330) — no scaffolds remain
    chp-github.caps              # declarative capability manifest  (#280)
    # gitlab / asana files land in future, separately-funded issues
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
  - `check_deps_resolved` — the `gh issue view --json body` task read became
    `itp_read_task` (migrated #306/B2) + `resolve_dep_state`'s mint+lookup became
    `itp_resolve_dep`/`itp_begin_tick` (migrated #284); the `## Dependencies` parse
    + block/proceed stay caller-side.
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

## 9. Cutover guard — anti-regression for the sole choke-point ([INV-91])

The "provider-dispatch is spec-defined" property ([INV-87]) — every issue/code-host
op routes through an `itp_*`/`chp_*` verb, the host-I/O leaves live ONLY under
`scripts/providers/` — is only durable if a CI gate stops a NEW raw `gh` from
re-entering the provider-neutral caller layer (`lib-dispatch.sh`,
`autonomous-dev.sh`, `autonomous-review.sh`, every `lib-review-*.sh`). That gate
is **`check-provider-cutover.sh`** ([INV-91], issue #286) — a credential-free
grep/jq lint modeled on `check-spec-drift.sh`:

- **Scan** the WHOLE dispatcher scripts tree **recursively** (`find -L` over every
  `*.sh` at any depth — top-level, `adapters/`, `providers/`, and any future nested
  subdir) for a raw `gh ` token via the RE2-safe consuming boundary
  `(^|[^A-Za-z_-])gh ` (never a look-behind — `gh --jq` runs Go RE2; see
  `invariants.md`). Recursing the whole tree — not just top-level + the caller
  layer — is #286 AC #41 ("every surviving raw-gh in
  `skills/autonomous-dispatcher/scripts/` resolves to providers/ or an allowlisted
  file"), so dispatcher/util scripts (`setup-labels.sh`, `lib-auth.sh`,
  `dispatcher-tick.sh`) AND nested `adapters/*.sh` are in scope. `-L` follows
  symlinks so the tracked-but-symlinked scripts (`mark-issue-checkbox.sh`,
  `reply-to-comments.sh`, `upload-screenshot.sh`, `gh-as-user.sh`) stay scanned. A
  drift FAILs LOUD naming the exact `file:line` (AC #2).
- **Allowlist** (declarative, in the script): the auth/transport wrappers
  `scripts/gh`, `gh-with-token-refresh.sh`, `gh-app-token.sh`, `gh-as-user.sh`,
  `dispatch-remote-aws-ssm.sh` (§8: GitHub auth is unchanged, NOT refactored),
  `upload-screenshot.sh` (#344, #296 FINAL batch — a single-purpose non-caller-layer
  utility whose only surviving signature after #330/#335 is a `command -v gh`
  capability-presence guard, not I/O) + the `providers/` tree (the legitimate home
  of host I/O). The guard script is **NOT** allowlisted (round 2 [P1] #2): it is
  scanned like any file and its own `gh `-mentioning **PASS/FAIL message strings**
  are baselined survivors, so a NEW raw `gh` added to the checker trips the guard.
  Everything else must be a baselined survivor.
- **The guard's own infrastructure lines are structurally exempt** (#286-amendment,
  #343): three lines in `check-provider-cutover.sh` change content whenever the
  **allowlist policy** changes — the `ALLOWLISTED_FILES=(…)` array declaration, the
  guard's own primary matcher line, and the generated baseline `_comment:` template
  (which used to embed the allowlist file-list). Baselining them meant an allowlist
  disposition **self-tripped Check 4 monotonicity**: the edited line's
  `(file,content)` signature changes, so the old signature "no longer found" AND a
  NEW unbaselined signature appears — forcing a hand-edit of the baseline in the
  same PR (the exact self-ratification the guard exists to prevent), so the #296
  final allowlist batch could not land. The scan (both the check path AND
  `--generate-baseline`) now STRUCTURALLY SKIPS these three lines — but ONLY in
  `check-provider-cutover.sh`, and ONLY when the line matches a top-of-line
  structural anchor (`is_checker_infra_line`: `^ALLOWLISTED_FILES=(`, the
  `grep -aE '(^|[^…])` matcher prefix, or the `_comment:` generator prefix), NEVER a
  magic comment an arbitrary file could carry — a general escape hatch would invite
  self-allowlisting (TC-CUTOVER-014). The exemption is **file-scoped**: the same
  shapes in any OTHER file are still caught. The `_comment` template also drops the
  embedded allowlist file-list (single source of truth stays in `ALLOWLISTED_FILES`),
  so an allowlist edit no longer churns it. The deliberate self-scan of the guard's
  PASS/FAIL MESSAGE strings STAYS normative: a NEW raw `gh` added to the checker
  (not matching an anchor) still FAILs LOUD. This amendment shrank the baseline by
  exactly the three exempted signatures (`63 → 60` distinct, `69 → 66` occurrences).
- **Baseline-anchored** (NOT a from-zero ban yet): the depends-on issues
  (#281–#285) migrated only the §3.1/§3.2 verb leaves, so the caller layer still
  carries the surviving raw-gh the first deliverable did not migrate. Those are
  frozen in `providers/cutover-baseline.json`, keyed by `(file, trimmed-content)`
  COUNT (the same discovered-vs-declared reconciliation as `check-spec-drift.sh`
  Check C.4). The guard PASSES today, FAILs any NEW raw-gh, FAILs a DUPLICATE of
  a baselined line, and FAILs a REMOVED baselined site — so a migration PR that
  pulls a `gh` leaf behind a verb MUST shrink the baseline in the same PR. As the
  survivors migrate, the baseline shrinks to empty and the guard becomes the
  strict from-zero ban.
- **Monotonicity-anchored to the trusted ref** (closes the same-PR
  self-ratification bypass): the baseline-reconcile above only proves the tree
  matches WHATEVER baseline ships in the same change, so a PR that BOTH adds a
  raw-gh AND `--generate-baseline`s would pass it. The guard therefore also reads
  the trusted (merged) baseline at `--trusted-ref` (default `origin/main`, override
  via the flag or `CUTOVER_TRUSTED_REF`) and FAILs if the working-tree baseline
  GREW — a new `(file,content)` signature or a higher count — so a PR can only ever
  SHRINK the baseline; ratifying a new site is rejected even when the in-PR reconcile
  is satisfied. The trusted survivor set comes from one of two sources: (1) the
  trusted baseline JSON at the ref (the steady state, once the baseline has landed on
  main); else (2) it is **DERIVED FROM THE TRUSTED TREE** itself — discovering raw-gh
  directly from the ref's `*.sh` via `git show <ref>:<path>` (dereferencing symlinked
  tracked scripts, the ref-tree analogue of the working-tree `find -L`). Source (2)
  closes the **initial-landing self-ratification hole** (#286 review finding #1): the
  PR that INTRODUCES the baseline has no baseline JSON on main to compare against, so
  deriving from the tree means a new raw-gh added to an EXISTING (on-ref) caller-layer
  script is still caught even on that first PR. A growth in a file ABSENT from the
  trusted ref is this PR legitimately introducing a NEW file (e.g. the guard itself) —
  allowed (still gated by the tree-wide reconcile above), not a monotonicity
  regression. Off-git, or when the ref is unresolvable (shallow / fork checkout),
  this check SKIPS gracefully **by default** — BUT under
  `--require-trusted-ref` (env `CUTOVER_REQUIRE_TRUSTED_REF=1`) an unresolvable ref
  is a hard FAILURE, not a skip. That strict mode closes the shallow-CI hole (#286
  review): the hermetic job runs the guard via the test glob under a depth-1
  checkout where `origin/main` is absent, so a permissive skip there would let a
  self-ratifying PR pass green. The unit test drives the guard with
  `--require-trusted-ref` against a self-contained git fixture (so monotonicity is
  enforced regardless of checkout depth), and the operator-applied ci.yml step uses
  `fetch-depth: 0` + `--require-trusted-ref` so the dedicated step enforces it too.
  The scan greps with `-a` (force text) so a script carrying UTF-8 punctuation is
  never misclassified "binary" and silently skipped.

The guard explicitly covers the dispatcher's own marker writers
`post_dispatch_token` ([INV-18]) and `_dep_block_comment` ([INV-39]), which post
through `itp_post_comment` (the sole marker choke-point [M6], [INV-89]).

**Caps-branch coverage gate (dead-code guard for `caps=0` branches).** The §7.4
fake degraded-capability fixture provider (`tests/unit/fixtures/provider-degraded/`,
selected through the public seam `ISSUE_PROVIDER=degraded` / `CODE_HOST=degraded`
+ `AUTONOMOUS_PROVIDERS_DIR`) is promoted to a coverage gate
(`tests/unit/test-provider-caps-branches.sh`). It splits the 13 caps (9 ITP + 4
CHP, §4.1/§4.2) honestly:

- **EXERCISED (8)** — the caps with a LIVE caller branch on this GitHub-only HEAD
  (`cross_ref_shorthand`, `edit_comment`, `label_colors`, `body_checkbox`,
  `native_issue_pr_link`, `rest_request_changes`, `review_bots`,
  `merge_closes_issue`): the gate asserts the branch is reachable AND its degraded
  value is driveable through the public seam, and RUNS four of them end-to-end
  against the degraded fixture (`label_colors=0` via a real `setup-labels.sh`
  subprocess; `merge_closes_issue=0` + `native_issue_pr_link=0/1` via the real
  `_render_close_keyword`; `body_checkbox=0` via a real `mark-issue-checkbox.sh`
  subprocess that fires the documented native-subtask-remap error without issuing a
  PATCH) — so "reachable" is demonstrated by execution, not just grep.
- **WAIVED (5)** — the caps whose caller branch is not yet wired (it lands with the
  GitLab/Asana PRs, §4.3; the degraded fixture `.sh` are empty scaffolds, so there
  is no branch to run). These are NOT a free pass: each is asserted STILL unwired
  behind a **fail-on-wiring tripwire** — if a waived cap ever gains a caller branch
  the suite FAILs ("move it to EXERCISED + add a real exercise test"), so no
  future `caps=0` branch can ship untested.

The headline prints `exercised=8 waived=5 total=13` and asserts the split equals
the full matrix, and a tripwire self-test proves the branch-detector is not a
no-op grep. (Exercising all 13 is not possible on a GitHub-only HEAD — 5 branches
do not exist — and fabricating a test-only consumer would violate §4.3's
no-behavior-change anchor; the waiver + tripwire is the honest maximum.)

CI wiring: the intended `.github/workflows/ci.yml` change adds a dedicated
`check-provider-cutover.sh` step to the credential-free `spec-drift` job (sibling
to `check-spec-drift.sh`) and adds `check-provider-cutover.sh` +
`tests/unit/test-provider-cutover.sh` + `tests/unit/test-provider-caps-branches.sh`
to the hermetic `shellcheck -S error` file list. For Check 4 (monotonicity) to run
in that dedicated step, the step's `actions/checkout` would use `fetch-depth: 0` (so
`origin/main` resolves) and invoke the guard with `--require-trusted-ref`. **This
ci.yml wiring is a NON-BLOCKING maintainer follow-up (#295), NOT part of this PR**
(owner ruling 2026-06-28): the dev-side scoped GitHub-App token CANNOT push
`.github/workflows/` ([INV-83]: a `git push` of any workflow change is rejected
`without 'workflows' permission`), and #286 was explicitly re-scoped so the PR MUST
NOT be blocked on a workflows edit. Meanwhile the guard runs in CI through the
existing `tests/unit/test-*.sh` loop: `test-provider-cutover.sh` invokes
`check-provider-cutover.sh` against the real repo (Checks 1-3), AND drives the
strict Check 4 / `--require-trusted-ref` fail-closed + monotonicity behavior against
self-contained git fixtures (TC-CUTOVER-017/019/020/021), so the property is
enforced regardless of checkout depth even before #295 lands the dedicated step.

---

## 10. Per-verb conformance checklist (#370)

`tests/provider-conformance/run-provider-conformance.sh` ([INV-106]) makes
the spec's "each normative clause maps 1:1 to a conformance check" promise
(§0/§introduction) true for the **implemented** subset (§4.4's ASSERTED
verbs) and explicitly lists the **pending** subset (the 13
`CONTRACT-PENDING`-tokened verbs, §3.1/§3.2). Each row below is one `TC-PCONF`
id in [`docs/test-cases/provider-conformance-runner.md`](../test-cases/provider-conformance-runner.md).

| Normative clause | Verb | `TC-PCONF` |
|---|---|---|
| §3.3 normalized shape + ascending `createdAt` | `itp_list_comments` | TC-PCONF-001 |
| §3.1 atomic remove+add | `itp_transition_state` | TC-PCONF-002 |
| §3.1 marker-channel post | `itp_post_comment` | TC-PCONF-003 |
| §3.1 edit-in-place, `edit_comment` gate | `itp_edit_comment` | TC-PCONF-004 |
| §3.1 checkbox tick, `body_checkbox` gate | `itp_mark_checkbox` | TC-PCONF-005 |
| §3.1 idempotent provision | `itp_provision_states` | TC-PCONF-006 |
| §3.1 fail-soft out-var, same-repo arm | `itp_resolve_dep` | TC-PCONF-007 |
| §3.1 fail-soft empty-on-failure | `itp_label_event_ts` | TC-PCONF-008 |
| §3.2 [M8] thread shape (shape only) | `chp_review_threads` | TC-PCONF-009 |
| §3.2 [M8] resolve mutation | `chp_resolve_thread` | TC-PCONF-010 |
| §3.2 request-changes, `rest_request_changes` gate | `chp_request_changes` | TC-PCONF-011 |
| §3.2 reply POST, `{id,url}` echo | `chp_reply_review_comment` | TC-PCONF-012 |
| §3.2 [M4] close-keyword render (3 branches) | `chp_close_keyword` | TC-PCONF-013 |
| Deliberately-broken fixture: wrong shape | `itp_list_comments` (broken) | TC-PCONF-020 |
| Deliberately-broken fixture: rc-0-on-error | `itp_transition_state` (broken) | TC-PCONF-021 |
| Deliberately-broken fixture: missing verb function | `chp_resolve_thread` (broken) | TC-PCONF-022 |
| Deliberately-broken fixture: non-array output | `chp_review_threads` (broken) | TC-PCONF-023 |
| §4.4 caps-conditioned SKIP, annotated cap | `itp_edit_comment`/`itp_mark_checkbox`/`chp_request_changes` (degraded) | TC-PCONF-030 |
| R3 CONTRACT-PENDING tripwire (spec↔runner set-diff) | (coverage-table meta-check) | TC-PCONF-040 |

Pending subset (§4's the 13 `CONTRACT-PENDING` verbs) carries no `TC-PCONF`
row — each gets one when its W1 slice lands (removing the spec token and
flipping `coverage.conf`'s line to `asserted` in the same PR, per R3).

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
| `label_swap` (`lib-dispatch.sh`) | `itp_transition_state` | (a) separable-leaf | the atomic remove+add `gh issue edit` — **migrated #283** (the `mark_stalled` inline `pending-dev→stalled` edit was folded into a `label_swap` call so every transition funnels through the one verb). **#331** extended the verb to CSV multi-label REMOVE/ADD ([INV-97]) and migrated the **last four** raw `gh issue edit` label-flip survivors behind it (the two Part-A multi-`--remove-label` flips + `hygiene_strip_residual_labels`'s variadic-N remove + the single-remove auto-merge-fail re-queue) — `lib-dispatch.sh`, `autonomous-dev.sh`, `autonomous-review.sh` now hold ZERO raw `gh issue edit` (cutover baseline shrank by 4). |
| `resolve_dep_state` (`lib-dispatch.sh`) | `itp_resolve_dep` + `itp_begin_tick` | (b) entangled | **migrated #284**: leaf state lookup → `itp_github_resolve_dep` (out-var contract preserved); [INV-83] scoped-token mint + `_DEP_TOKEN_CACHE` + `DEP_LOOKUP_PERMISSIONS` default + `get_gh_app_scoped_token` lazy-source → provider; tick reset (`_reset_dep_token_cache` body) → `itp_github_begin_tick`. `resolve_dep_state` is now a thin caller-side wrapper forwarding to `itp_resolve_dep`; the `## Dependencies` parse stays caller-side |
| `check_deps_resolved` (`lib-dispatch.sh`) | `itp_read_task` + `itp_resolve_dep` | (b) entangled | the issue-body task read routes through `itp_read_task` (**migrated #306/B2** — `gh issue view … --json body -q '.body'` byte-identical via the GitHub leaf); the per-ref lookup (both the cross-repo and same-repo arms) routes through `itp_resolve_dep` (**migrated #284**, cross-repo arm gated on `cross_ref_shorthand`); the `## Dependencies` parse, the [INV-11] CLOSED/MERGED predicate, the fail-safe `return 1`, and the `_dep_block_comment` call stay caller-side. |
| `mark_stalled` (`lib-dispatch.sh`) | `itp_post_comment` + `itp_transition_state` | **(b) entangled multi-op orchestrator** | **leaf I/O migrated #283; golden-trace gate landed #285.** Per-site cut: the [INV-26] deferral-marker dedup READ → `itp_list_comments` + caller-side `select(contains(…)) | length` glue; the deferral comment post → `itp_post_comment`; the terminal `pending-dev→stalled` edit → `label_swap` (→ `itp_transition_state "$issue_num" pending-dev stalled`); the stalled-summary comment → `itp_post_comment`. **Caller-side (NOT a verb):** `pid_alive --at-cap`/`issue`, `get_pid`, the `EXECUTION_BACKEND` resolve (the TC-RPA-010 separate-line invariant), `count_agent_failures`/`count_dispatcher_crashes`/`count_dispatcher_false_positives`, the `: > $log` truncate. NO caps gate inside the function — GitHub takes the identical path. |
| `handle_completed_session_routing` (`lib-dispatch.sh`) | `itp_post_comment` + `itp_transition_state` + `chp_find_pr_for_issue` (+ dispatch) | **(b) entangled multi-op orchestrator** | **leaf I/O migrated #283/#282; golden-trace gate landed #285.** Per-arm cut: `none`/default → `itp_list_comments` (dedup) + `itp_post_comment` (INV-12-completed handoff); `passed` → no host op (race no-op); `failed-non-substantive` → `itp_post_comment` (review-aware-flip) + `label_swap pending-dev pending-review`, or at REVIEW_RETRY_LIMIT `itp_post_comment` + `mark_stalled`; `failed-substantive` → `fetch_pr_for_issue "$issue_num" "number,headRefOid,body"` (→ `chp_find_pr_for_issue`, the #148 body-inclusion anchor) then Branch A (bot-unfixable) / B (no-progress) `itp_list_comments`+`itp_post_comment`+`mark_stalled`, or Branch C `itp_list_comments`+`itp_post_comment`(INV-35-fresh-dev)+`label_swap pending-dev in-progress`+`post_dispatch_token`+`dispatch dev-new`+`itp_post_comment` (the [INV-85] `no-progress-substantive-attempt:<head>` HTML marker, #274 anchor). **Caller-side (NOT a verb):** `classify_recent_review_verdict`, `count_review_aware_flips`, `last_reviewed_head`, `dev_report_bot_unfixable`, the [INV-35]/[INV-85] routing decision, the `: > $log` truncate, `post_dispatch_token`, `dispatch dev-new`. NO caps gate inside the function. |
| `post_dispatch_token` (`lib-dispatch.sh`) | `itp_post_comment` | (a) separable-leaf | the [INV-18] dispatcher-marker comment write — routes through the ITP choke-point ([INV-89]) — **migrated #283** (marker BODY composed caller-side, verbatim) |
| `_dep_block_comment` (`lib-dispatch.sh`) | `itp_post_comment` | (a) separable-leaf | the [INV-39] dependency-block dispatcher-marker comment write — **migrated #283** (the dedup READ stays on `itp_list_comments`) |
| `dispatcher-tick.sh` Step-2 TTHW timeline read (`gh api …/issues/<n>/timeline --jq …`, [INV-70] `labeled_at`) | `itp_label_event_ts` | (a) separable-leaf | **migrated #323** ([INV-93], observe-only): the GitHub-internal timeline `gh api …--jq …` leaf moves to `itp_github_label_event_ts` (JSON-encoding the label, injection-safe) and returns the first-`labeled` timestamp scalar; the TTHW math, the `issue_labeled` emit, and the `labeled_at`-vs-`ts` preference stay caller-side. Guarded on the bare `itp_${ISSUE_PROVIDER}_label_event_ts` (leaf-absent / any failure → empty → fall back to `ts`, never blocks dispatch). Closes `dispatcher-tick.sh` as a raw-`gh` caller (cutover baseline 67 → 66). |
| `resolve_pr_for_issue` (`lib-pr-linkage.sh:73`) + `verify_pr_closes_issue` (`:99`); `fetch_pr_for_issue` (`lib-dispatch.sh`) is the kept same-named delegate shim | `chp_find_pr_for_issue` | (b) entangled | the `gh pr list --json $FIELDS` leaf moves with `FIELDS` forwarded byte-identically ([M1]); the [INV-86] close-linkage/branch resolution + projection `$q` stay caller-side. **MIGRATED #282.** (Post-#277 `fetch_pr_for_issue` is a pure delegate to `resolve_pr_for_issue` — that delegate stays as the function-mock shim, §7.2 m3.) |
| `ci_is_green` (`lib-dispatch.sh`) | `chp_ci_status` | (a) separable-leaf | the `gh pr checks --json state -q '[.[].state]'` leaf moves, forwarding the caller's `--json`/`-q` byte-identically and returning the raw per-check state array; the `length>0 and all(.=="SUCCESS")` boolean gate stays caller-side (`ci_is_green` returns rc 0/1, not a `green`/`pending`/`failed`/`none` string — normalizing the leaf itself to those tokens is the open W1(d) slice, §3.2). **MIGRATED #282.** |
| `autonomous-review.sh` mergeable poll (`gh pr view … --json mergeable`) | `chp_mergeable` | (b) entangled | only the `gh pr view --json mergeable` leaf moves ([M2]); the UNKNOWN-retry loop + `_classify_mergeable_gate`/`_pr_open_gate` ([INV-44]/[INV-54], `lib-review-mergeable.sh` byte-unchanged) stay caller-side. **MIGRATED #282.** |
| `gh pr create` (the broker `drain_agent_pr_create`, `lib-auth.sh`) | `chp_create_pr` | (a) separable-leaf | the `gh pr create --head/--title/--body` leaf; the broker routes through the verb (leaf-only swap, no INV-79 change). **MIGRATED #282.** **Leaf-absent disposition #346:** the retained raw `gh pr create` fallback is github-gated (`${CODE_HOST:-github} == "github"`) — a non-GitHub backend without the leaf fails LOUD (no PR created), never a silent GitHub PR. Spec-sanctioned [INV-91] residue (byte-identical, baseline unchanged). |
| `gh pr review --approve` (`autonomous-review.sh` PASS path) | `chp_approve` | (a) separable-leaf | the `--approve --body …` leaf; the [INV-52]/[INV-79] wrapper-owns-approve ownership + PASS-gate chain stay caller-side. **MIGRATED #282.** |
| `gh pr review --request-changes` (`submit_request_changes`, `lib-review-request-changes.sh`) | `chp_request_changes` | (b) entangled | the `--request-changes --body $body` leaf; gated by `rest_request_changes` (§4.2). The best-effort return-0 + token-refresh glue stays caller-side. **MIGRATED #282.** |
| `gh pr merge` (`autonomous-review.sh` merge path) | `chp_merge` | (a) separable-leaf | the `--squash --delete-branch` leaf. [M4]/[INV-33]: `merge_closes_issue=1` (GitHub) means the wrapper MUST NOT transition post-merge; a `merge_closes_issue=0` backend transitions via `itp_transition_state` (else github-gated `gh issue close`). **MIGRATED #282.** |
| `resolve-threads.sh` reviewThreads list + `resolveReviewThread` mutation | `chp_review_threads` / `chp_resolve_thread` | (a) separable-leaf | the two `gh api graphql` leaves → the M8 thread shape `{thread_id, resolved, comments:[{id, path, line, …}]}`; the select-unresolved + resolved/failed tally stay caller-side. **MIGRATED #282.** |
| bot-trigger post (the broker `drain_agent_bot_triggers`, `lib-auth.sh`; `gh-as-user.sh pr comment`) | `chp_trigger_bot` | (a) separable-leaf | the real-user trigger post, gated by `review_bots` (§4.2); `parse_review_bots`/login mapping + allow-list stay caller-side; the broker routes through the verb. **MIGRATED #282.** **Leaf-absent disposition #346:** the retained raw `gh-as-user.sh pr comment` fallback is github-gated (`${CODE_HOST:-github} == "github"`, checked once before the posting loop) — a non-GitHub backend without the leaf fails LOUD (no triggers posted), never a silent GitHub-user comment. The `gh-as-user.sh` transport wrapper is allowlisted so this residue carries no cutover-baseline entry ([INV-91]). |
| incidental `gh pr view $PR --json …` reads + body-mention `gh pr list … select(.body\|test("#N"))` lookups (`autonomous-dev.sh` / `autonomous-review.sh`) | `chp_pr_view` / `chp_pr_list` (general read primitives) | (a) separable-leaf | the PR-number-keyed `gh pr view` + loose body-mention `gh pr list` leaves; caller keeps its `--json`/`-q`. NOT named §3.2 lifecycle verbs — added so the caller layer carries zero executable raw `gh pr`. **MIGRATED #282 (review r8).** |
| dev-resume `PR_REVIEW_COMMENTS` inline-comment read (`autonomous-dev.sh`, the flat REST `gh api repos/$REPO/pulls/$PR/comments --jq <fmt>`) | `chp_list_inline_comments` | (a) separable-leaf | the PR-number-keyed `gh api …/pulls/N/comments` leaf; caller keeps its `--jq` `- **path:line** — body` formatter ([#281] jq-stays-caller). Self-guarding shim ([#282] convention). **MIGRATED #296 second-tier (#328), [INV-95].** The distinct `:1093` `issues/N/comments` AUTO_MERGE-marker read this issue had scoped OUT was migrated independently behind `itp_list_comments` by #334. |
| the 7 PR-comment writes (`gh pr comment $PR` — auto-merge markers `autonomous-review.sh`, E2E-failure reports + the [INV-79] brokered E2E report `lib-review-e2e.sh`) | `chp_pr_comment` (general write primitive) | (a) separable-leaf | the PR-number-keyed `gh pr comment` write leaf; the caller keeps its own redirect/capture/gating framing (4 forms: `… 2>/dev/null \|\| true`, `if ! _err=$(… 2>&1 >/dev/null)`, `… 2>/dev/null \|\| rc=$?`, broker `… >/dev/null 2>&1`) — the leaf adds NONE. The PR-comment sibling of `chp_pr_view`/`chp_pr_list`; DISTINCT from `itp_post_comment` (the ISSUE-level marker choke-point), different seam owner for a split-backend topology. **MIGRATED #329 (#296 second-tier), [INV-102] (renumbered from INV-95, then INV-101, on successive rebases — see the note under the INV-102 heading).** |
| `setup-labels.sh:47` `gh label create` | `itp_provision_states` | (a) separable-leaf | the state-primitive provisioning leaf; hex color gated by `label_colors` — **migrated #283** (the 9-label table stays caller-side). **[#362]**: the #283 migration byte-identically preserved a PRE-EXISTING bug — the existence check called `gh label view`, a subcommand that does not exist on real `gh` (only `clone/create/delete/edit/list`), so it always fell through to `gh label create` and aborted under `set -e` on the first pre-existing label. Fixed by replacing the check with a REST existence probe (`gh api repos/<repo>/labels/<name> --silent`); the create-branch argv is unchanged. |
| `reply-to-comments.sh:41` | `chp_reply_review_comment` (returning `id`/`url`) | (a) separable-leaf | the reply-comment POST leaf returning `{id, url}` — a CHP review-thread reply (`pulls/.../comments`), owned by chp-pr-lifecycle. **MIGRATED #327** ([INV-96]): the `gh api …/comments -X POST -f body=… -F in_reply_to=… --jq '{id,url}'` leaf moves to `chp_github_reply_review_comment` byte-identically; the standalone util self-sources the CHP seam via `readlink -f` (the #315 `mark-issue-checkbox.sh` precedent), composes `REPO="$OWNER/$REPO"` for the leaf scope, and fails LOUD (no raw-`gh` fallback) if the leaf is absent. Closes `reply-to-comments.sh` as a raw-`gh` caller (cutover baseline 66 → 65). NOT capability-gated; no `@json` pre-encode (REST `-f`/`-F` fields, fixed `--jq` literal). |
| `lib-review-e2e.sh` PATCH ([INV-46]) | `itp_edit_comment` | (a) separable-leaf | the edit-in-place PATCH leaf; gated by `edit_comment` — **migrated #283** (`edit_comment=0` → `itp_post_comment` re-posts the full report body + marker, never marker-only). The GET-comment-id / GET-body reads formerly stayed caller-side (raw `gh api`); **migrated #345** behind `itp_list_comments` — see the dedicated row below. |
| `lib-review-e2e.sh:492` (GET-comment-id) + `:504` (GET-body) — `_stamp_browser_evidence_marker` ([INV-46]) | `itp_list_comments` | (a) separable-leaf → ONE call, shape-equivalent | **migrated #345** (#296 deferred): the two raw `gh api` reads (paginated id-lookup by `--jq … \| last \| .id`, then a second id-keyed body GET) collapse into a SINGLE `itp_list_comments "$PR_NUMBER"` call over the normalized [INV-90] array. Caller-side jq re-selects the newest matching report via `sort_by(.createdAt // "", .id // 0) \| last` (the #321 verdict-poll tie-break precedent) and reads `.body` from the SAME selected element — no second id-keyed GET. `.user.login`→`.author`, `.created_at`→`.createdAt` (both normalized-field re-expressions, [INV-90]); the `.body \| contains(...)` predicate is unchanged (no regex, so no RE2→Oniguruma divergence). Retires the former INV-46 carve-out that kept these two reads raw; shrinks the [INV-91] cutover baseline by exactly 2 signatures. |
| `Closes #${issue_num}` literals (`autonomous-dev.sh` PR-body prompts) | `chp_close_keyword` | (a) separable-leaf | the hardcoded auto-close keyword becomes a verb-rendered string ([M4]); caps-aware `_render_close_keyword` renders `Related to #N` (non-closing) when `merge_closes_issue=0`+`native_issue_pr_link=0`. **MIGRATED #282.** |
| inline review-count in `missing_bot_reviews` (`lib-review-bots.sh`, the [INV-79] bot-review hard-gate) | `chp_count_reviews_by_login REPO PR LOGIN` | (a) separable-leaf | the `--paginate \| --jq '\|length' \| awk` sum leaf → a provider-neutral int; the `^[0-9]+$` validation + `-eq 0` MISSING decision stay caller-side. REPO threaded as a param, LOGIN JSON-encoded (injection-safe), capture-check-sum closes the partial-pagination fail-open ([INV-94]). The 3 agent-facing prompt-prose `gh api …/reviews` heredoc lines stay (permanent residue). **MIGRATED #324.** |
| `upload-screenshot.sh` 8 raw git-Data-API `gh api` calls (`git/ref`→`git/blobs`→`git/trees`→`git/commits`→`git/refs`→re-`git/ref`→`contents` GET→`contents` PUT) | `chp_commit_file` | (b) entangled → ONE whole-op verb | **migrated #330** ([INV-99]): the WHOLE commit-a-PNG-to-an-orphan-branch op (the 8 calls incl. the orphan-branch create-vs-update branching + the ARG_MAX temp-file JSON build) moves to `chp_github_commit_file` and echoes the committed SHA; the local file-read + `base64 -w0` encode + the `\|\| fail`-on-empty-SHA glue + the `/blob/` URL render stay caller-side. REPO threaded explicitly ($1, not a global — #324). Leaf cleanup uses a SELF-DISARMING function-scoped `trap … RETURN` (AC2) — a bare `trap … EXIT`/non-self-disarming `… RETURN` both crash the standalone caller, reproduced on-box; the self-disarm (`trap - RETURN` as the trap body's own last action) fires exactly once per invocation. The `command -v gh` presence guard stays (residue, not a call site). Shrinks the cutover baseline by 8 occurrences / 7 signatures (60→52 occurrences, 54→47 signatures); `upload-screenshot.sh` now holds ONLY the `command -v gh` survivor. |

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
- [`invariants.md` § INV-91](invariants.md#inv-91-the-provider-neutral-caller-layer-routes-all-host-io-through-itp_chp_-verbs--a-new-raw-gh-outside-providers-is-a-ci-failing-cutover-regression-baseline-anchored) — the cutover guard (`check-provider-cutover.sh`, §9 above) that keeps the caller layer raw-gh-free.
- [`invariants.md` § INV-78](invariants.md#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent) — the verdict-artifact channel (issue #279 cites it as INV-77; renumbered to INV-78) reconciled above.
- [`invariants.md` § INV-79](invariants.md#inv-79-in-app-mode-the-agent-process-gets-only-a-scoped-token-the-wrapper-keeps-full-write-and-is-the-sole-approvemergepr-create-path) / [INV-83](invariants.md#inv-83-cross-repo-dependency-lookups-use-a-per-dep-repo-scoped-read-token-the-app-must-be-installed-on-the-dep-repo) — the per-seam auth cut (CHP-side / ITP-side).
- [`adapter-spec.md`](adapter-spec.md) — the agent-CLI adapter spec this provider spec mirrors ([INV-66]/[INV-75]).
- [`state-machine.md`](state-machine.md) — the abstract pipeline states the ITP renders per-backend.
