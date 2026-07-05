# Test Cases — P3-3: GitLab CHP read leaves (#418)

**Scope.** The seven GitLab CHP READ leaves in `skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh`:
`chp_gitlab_ci_status`, `chp_gitlab_mergeable`, `chp_gitlab_pr_view`,
`chp_gitlab_pr_list`, `chp_gitlab_find_pr_for_issue`,
`chp_gitlab_list_inline_comments`, `chp_gitlab_review_threads`.

**Harness.** `tests/unit/test-chp-gitlab-reads.sh` is hermetic. Each case defines
a **test-local `_gl_api` stub** (serving a fixture payload, optionally setting
`GL_API_STATUS`, optionally exiting non-zero mid-walk to simulate a transport
failure), THEN sources `providers/chp-gitlab.sh`. `lib-gitlab-transport.sh` does
NOT exist on this branch — the leaves' contract is against the FROZEN #416
signature (`_gl_api [--method M] [--paginate] [--body JSON] <path>` /
`_gl_urlencode`), not any real transport. Every assertion is leaf-contract-vs-spec
(shape, sort, fail-closed, page-completeness, projection, enum-bucketing);
callers already abstract behind `chp_<verb>` (phase-2, #347) so no caller test
belongs here (W1c1/W1c2/W1d/W1f pin the caller side).

**Conventions.**
- Each TC pins the exact leaf argv, the fixture payload, and the expected
  normalized output (byte-for-byte where possible, or a jq-driven shape assert).
- "fail-CLOSED" = leaf returns rc≠0 with **no partial stdout**.
- "empty" list = `[]` (NEVER `null`).
- ISO-8601 timestamps sort **lexically ascending**; the leaf-side stable sort
  matches the [INV-90] contract from §3.3.
- Fixtures live at `tests/provider-conformance/fixtures/payloads/gitlab-chp-*.json`
  with `.meta` sidecars naming `gitlab_version=17.x` (the modeled version — R3's
  `detailed_merge_status` enum changed shape across versions, so the version is
  load-bearing).

---

## R2 — `chp_gitlab_ci_status` (11-value bucket table)

Reads `GET /projects/:GITLAB_PROJECT/merge_requests/:iid` and projects
`.head_pipeline.status` through the pinned `green|pending|failed|none` bucket.
`null` `head_pipeline` → `none`; unknown-future token → `pending` (conservative
not-green not-terminal, matches the GitHub leaf's decision order).

| ID | Payload `.head_pipeline.status` | Expected stdout | Expected rc |
|----|----------------------------------|-----------------|-------------|
| TC-P33-001 | (`head_pipeline` is `null`)    | `none`          | 0 |
| TC-P33-002 | `success`                        | `green`         | 0 |
| TC-P33-003 | `failed`                         | `failed`        | 0 |
| TC-P33-004 | `canceled`                       | `failed`        | 0 |
| TC-P33-005 | `skipped`                        | `pending`       | 0 |
| TC-P33-006 | `manual`                         | `pending`       | 0 |
| TC-P33-007 | `created`                        | `pending`       | 0 |
| TC-P33-008 | `waiting_for_resource`           | `pending`       | 0 |
| TC-P33-009 | `preparing`                      | `pending`       | 0 |
| TC-P33-010 | `pending`                        | `pending`       | 0 |
| TC-P33-011 | `running`                        | `pending`       | 0 |
| TC-P33-012 | `scheduled`                      | `pending`       | 0 |
| TC-P33-013 | unknown-future token (e.g. `quantum_pending`) | `pending` | 0 |
| TC-P33-014 | (`_gl_api` rc≠0)                 | (empty)         | ≠0 |
| TC-P33-015 | (rc 0 payload MISSING `head_pipeline` key at all) | (empty) | ≠0 (payload-type gate; a missing key is a data-shape failure the leaf must reject rather than silently answer `none`) |
| TC-P33-016 | (rc 0 payload is a JSON array, not an object) | (empty) | ≠0 (payload-type gate; matches the GitHub leaf's `type == "object"` posture) |

---

## R3 — `chp_gitlab_mergeable` (detailed_merge_status bucket table)

Reads the same MR-view and buckets `.detailed_merge_status` into
`MERGEABLE|CONFLICTING|UNKNOWN`. `merge_status` is deprecated (≥15.6) and NOT
read.

| ID | `.detailed_merge_status` | Expected stdout |
|----|--------------------------|-----------------|
| TC-P33-020 | `mergeable`               | `MERGEABLE`    |
| TC-P33-021 | `conflict`                | `CONFLICTING`  |
| TC-P33-022 | `need_rebase`             | `CONFLICTING`  |
| TC-P33-023 | `commits_status`          | `CONFLICTING`  |
| TC-P33-024 | `broken_status`           | `CONFLICTING` (documented as CONFLICTING when present in the modeled version) |
| TC-P33-025 | `checking`                | `UNKNOWN`      |
| TC-P33-026 | `unchecked`               | `UNKNOWN`      |
| TC-P33-027 | `preparing`               | `UNKNOWN`      |
| TC-P33-028 | `approvals_syncing`       | `UNKNOWN`      |
| TC-P33-029 | `not_open`                | `UNKNOWN`      |
| TC-P33-030 | `ci_must_pass`            | `UNKNOWN`      |
| TC-P33-031 | `ci_still_running`        | `UNKNOWN`      |
| TC-P33-032 | `not_approved`            | `UNKNOWN`      |
| TC-P33-033 | `requested_changes`       | `UNKNOWN`      |
| TC-P33-034 | `merge_request_blocked`   | `UNKNOWN`      |
| TC-P33-035 | `discussions_not_resolved`| `UNKNOWN`      |
| TC-P33-036 | `draft_status`            | `UNKNOWN`      |
| TC-P33-037 | `status_checks_must_pass` | `UNKNOWN`      |
| TC-P33-038 | `jira_association_missing`| `UNKNOWN`      |
| TC-P33-039 | `merge_time`              | `UNKNOWN`      |
| TC-P33-040 | `security_policy_violations` | `UNKNOWN`   |
| TC-P33-041 | `security_policy_pipeline_check` | `UNKNOWN` |
| TC-P33-042 | `locked_paths`            | `UNKNOWN`      |
| TC-P33-043 | `locked_lfs_files`        | `UNKNOWN`      |
| TC-P33-044 | `title_regex`             | `UNKNOWN`      |
| TC-P33-045 | unknown-future token      | `UNKNOWN`      |
| TC-P33-046 | (`_gl_api` rc≠0)          | (empty) rc≠0   |

---

## R4 — `chp_gitlab_pr_view <pr> <fields-csv>`

`GET …/merge_requests/:iid` and project to the §3.2.1 vocabulary (all 14
members). System-note filter applies on `comments`. Fetch-cost gate: `_gl_api`
is called for the extra sub-resources `/closes_issues`, `/notes`,
`/approvals` ONLY when the corresponding vocabulary field is requested.

- TC-P33-050 — full vocabulary read: `chp_gitlab_pr_view 42
  number,state,title,body,createdAt,updatedAt,mergedAt,headRefName,headRefOid,reviewDecision,mergeable,closingIssueNumbers,comments,reviews`.
  Fixture: an MR whose `.state=opened, .iid=42, .description="Body"`, one
  `/closes_issues` entry `.iid=7`, one non-system `/notes` entry, one
  `/approvals.approved_by` entry. Expected top-level keys exactly the 14 fields;
  `number == 42`, `state == "OPEN"`, `body == "Body"`, `reviewDecision == ""`
  (GitLab-honesty), `closingIssueNumbers == [7]`, `comments[0].author ==
  "<username>"`, `reviews[0].state == "APPROVED"`.
- TC-P33-051 — `locked→CLOSED` mapping: fixture `.state=locked` → normalized
  `state == "CLOSED"` (accepted asymmetry documented in R5's `pr_list closed`
  note).
- TC-P33-052 — `merged→MERGED`: `.state=merged` → `state == "MERGED"`.
- TC-P33-053 — `opened→OPEN`: `.state=opened` → `state == "OPEN"`.
- TC-P33-054 — `closed→CLOSED`: `.state=closed` → `state == "CLOSED"`.
- TC-P33-055 — unrecognized future state → `state == ""` (data-source-honesty).
- TC-P33-056 — `body` null → `""` (the #148 hazard fix): fixture `.description
  == null` → `body == ""`.
- TC-P33-057 — `reviewDecision → ""` unconditional: fixture without
  approvals still emits `reviewDecision == ""`.
- TC-P33-058 — `closingIssueNumbers` empty: fixture `/closes_issues` is `[]` →
  `closingIssueNumbers == []`.
- TC-P33-059 — `closingIssueNumbers` fetch-cost gate: `chp_gitlab_pr_view 42
  number` MUST NOT trigger the `/closes_issues` fetch (only the base MR-view
  call; assert with a call-count check in the stub `_gl_api`).
- TC-P33-060 — `comments` fetch-cost gate: single-field read `number` MUST NOT
  trigger the `/notes` fetch.
- TC-P33-061 — `reviews` fetch-cost gate: single-field read `number` MUST NOT
  trigger the `/approvals` fetch.
- TC-P33-062 — `comments` system-note filter: `/notes` returns two entries, one
  with `.system == true` and one with `.system == false`; the normalized
  `comments` array MUST contain ONLY the non-system entry.
- TC-P33-063 — `comments` normalized shape: element keys ==
  `{id, author, body, createdAt}`; `author = note.author.username`; `body` null
  → `""`; ascending by `createdAt`.
- TC-P33-064 — `reviews` normalized shape: element keys ==
  `{author, state, submittedAt}`; `state == "APPROVED"` (synthesized);
  `author = approved_by[].user.username`; `submittedAt = approved_by[].approved_at`
  (verified against the recorded probe named in the leaf header).
- TC-P33-065 — `/closes_issues` rc≠0 on REQUESTED `closingIssueNumbers` fails
  the leaf rc≠0 (data-source honesty — a `[]`-on-failure would be a lie).
- TC-P33-066 — `/notes` rc≠0 on REQUESTED `comments` fails the leaf rc≠0.
- TC-P33-067 — `/approvals` rc≠0 on REQUESTED `reviews` fails the leaf rc≠0.
- TC-P33-068 — vocabulary rejection: `chp_gitlab_pr_view 42 iid` (GitLab-native
  name) → rc 2, loud stderr, ZERO `_gl_api` calls (must be caught BEFORE the
  HTTP dispatch — mirrors the W1c2 GitHub gate).
- TC-P33-069 — vocabulary rejection: `chp_gitlab_pr_view 42 description` →
  rc 2, zero `_gl_api` calls.
- TC-P33-070 — vocabulary rejection: `chp_gitlab_pr_view 42 notes` → rc 2.
- TC-P33-071 — vocabulary rejection: `chp_gitlab_pr_view 42 source_branch` →
  rc 2.
- TC-P33-072 — vocabulary rejection: `chp_gitlab_pr_view 42 bogus_field` →
  rc 2.
- TC-P33-073 — missing FIELDS-CSV (2nd positional) → rc 2, zero `_gl_api`
  calls.
- TC-P33-074 — MR fetch rc≠0 → leaf rc≠0 with no partial stdout.
- TC-P33-075 — MR fetch rc 0 but empty stdout → leaf rc≠0 (capture-then-check
  fail-CLOSED, same posture as chp_github_pr_view's #P1-2 fix).
- TC-P33-076 — MR fetch rc 0 non-object payload → leaf rc≠0 (`type ==
  "object"` gate).

---

## R5 — `chp_gitlab_pr_list <state> <fields-csv>`

`GET …/merge_requests?state=<gitlab-state>&order_by=created_at&sort=desc`
page-walked internally via `_gl_api --paginate`. State enum is DISJOINT:

- TC-P33-080 — STATE mapping `open → opened`: fixture returns two `opened` MRs
  → array length 2; leaf-side `.state == "opened"` post-filter passes both.
- TC-P33-081 — STATE mapping `closed → closed`: fixture returns two `closed`
  MRs; a mixed-in `merged` MR is post-filtered OUT (DISJOINT guarantee — GitLab
  natively excludes merged from `state=closed`, but the leaf post-filters
  regardless).
- TC-P33-082 — STATE mapping `merged → merged`: fixture returns two `merged`
  MRs; array length 2.
- TC-P33-083 — STATE mapping `all → all`: fixture returns one each of
  opened/closed/merged/locked; array length 4 (no post-filter narrows).
- TC-P33-084 — invalid STATE argument (`foo`) → rc 2, zero `_gl_api` calls.
- TC-P33-085 — missing STATE → rc 2.
- TC-P33-086 — missing FIELDS-CSV → rc 2.
- TC-P33-087 — REJECT `comments` in FIELDS-CSV (loud rc≠0, same W1c1 support
  matrix as GitHub `pr_list`).
- TC-P33-088 — `reviews` supported (each candidate's `/approvals` fetched for
  synthesis when requested).
- TC-P33-089 — page walk 2-page: `_gl_api --paginate` returns a merged array
  of length 4 (2 per page, arrival order preserved).
- TC-P33-090 — mid-walk failure: `_gl_api --paginate` rc≠0 on page 2 → leaf
  rc≠0 with EMPTY stdout (fail-CLOSED §3.5).
- TC-P33-091 — page cap: `CHP_GITLAB_PR_LIST_PAGE_CAP=2` while the fixture
  reports a 3rd page → leaf rc≠0 with EMPTY stdout, loud stderr naming the
  cap-hit.
- TC-P33-092 — empty match → `[]` rc 0 (never `null`).
- TC-P33-093 — projection-only: `chp_gitlab_pr_list open body,number` returns
  elements with EXACTLY `{body,number}` keys; unrequested vocabulary members
  absent (no fabrication).
- TC-P33-094 — `body` null → `""` normalization across every element.

---

## R6 — `chp_gitlab_find_pr_for_issue <issue> <fields-csv>`

Uses `GET /projects/:GITLAB_PROJECT/issues/:iid/closed_by` as the CLOSE-LINKAGE
source (spec §3.2, R6). Post-filters `.state == "opened"` in-leaf. Projects to
`FIELDS-CSV ∪ {number, closingIssueNumbers, headRefName}` per W1c1.

- TC-P33-100 — narrowing: `/issues/42/closed_by` returns MR#7 + MR#8, both
  `opened`; `/merge_requests/7/closes_issues` returns `[42]`,
  `/merge_requests/8/closes_issues` returns `[42, 43]`. Leaf emits an array of
  length 2, each element carrying `closingIssueNumbers` reflecting the
  per-MR `/closes_issues` result.
- TC-P33-101 — state post-filter: `/closed_by` returns MR#7 `opened` +
  MR#8 `merged` → only MR#7 survives (`.state == "opened"` filter).
- TC-P33-102 — empty candidate set: `/closed_by` returns `[]` → `[]` rc 0
  (never `null`).
- TC-P33-103 — REJECT `comments` in FIELDS-CSV (rc≠0 loud).
- TC-P33-104 — FIELDS-CSV projection ∪ resolution keys: caller asks for
  `body`; each element carries `body` PLUS `number`, `closingIssueNumbers`,
  `headRefName` (the W1c1 forced-union contract).
- TC-P33-105 — `body` null → `""` across every element.
- TC-P33-106 — `/closed_by` rc≠0 → leaf rc≠0, no partial output.
- TC-P33-107 — mid-walk per-MR `/closes_issues` rc≠0 (a follow-up
  fetch on the candidate set fails) → leaf rc≠0, no partial output
  (data-source honesty on REQUESTED `closingIssueNumbers`).

---

## R7 — `chp_gitlab_list_inline_comments <pr>`

`GET …/merge_requests/:iid/discussions` page-walked; FLATTENED to
`[{id, path, line, author, body, createdAt}]` ascending. INLINE-only:
`.position == null` notes are filtered; `.system == true` notes are filtered.

- TC-P33-120 — mixed inline/non-inline: fixture has 2 inline notes + 1
  general (`position == null`) + 1 system (`system == true`); result has EXACTLY
  the 2 inline entries.
- TC-P33-121 — position fold `line`: fixture note has
  `.position.new_line == 5` → normalized `.line == 5`.
- TC-P33-122 — position fold `line // old_line`: fixture note has
  `.position.new_line == null, .position.old_line == 7` → normalized
  `.line == 7`.
- TC-P33-123 — position fold `path // old_path`: fixture note has
  `.position.new_path == null, .position.old_path == "foo.py"` → normalized
  `.path == "foo.py"`.
- TC-P33-124 — both position fields null → `.line == null` (caller renders
  `// "N/A"`).
- TC-P33-125 — body null → `""` normalization.
- TC-P33-126 — ascending by createdAt (id tie-break).
- TC-P33-127 — multi-page walk: 2 pages of discussions → merged array in
  arrival order, length = sum of per-page inline notes.
- TC-P33-128 — mid-walk failure → rc≠0 no partial output.
- TC-P33-129 — empty → `[]` rc 0.

---

## R8 — `chp_gitlab_review_threads <pr>`

`GET …/merge_requests/:iid/discussions` full page-walk. Emits M8 shape:
`[{thread_id, resolved, comments:[...]}]`. `thread_id` is the COMPOUND string
`"<mr-iid>:<discussion.id>"`. Resolvable-only filter: `resolvable != true` →
discussion excluded.

- TC-P33-140 — compound `thread_id`: fixture MR #42, discussion id `abc` →
  emitted `thread_id == "42:abc"`.
- TC-P33-141 — resolvable-only filter: fixture has 3 discussions
  (`resolvable=true resolved=false`, `resolvable=true resolved=true`,
  `resolvable=false`) → result has EXACTLY 2 entries; the non-resolvable
  discussion is EXCLUDED (must not reach `resolve-threads.sh`'s mutation loop).
- TC-P33-142 — `resolved` derivation: fixture discussion first-note
  `resolvable=true resolved=true` → `.resolved == true`.
- TC-P33-143 — `resolved` false: `resolvable=true resolved=false` →
  `.resolved == false`.
- TC-P33-144 — `comments` element shape: R7 mapping applies (same position
  fold; system notes filtered).
- TC-P33-145 — multi-page walk (COMPLETE §3.5 — GitLab returns all notes per
  discussion in ONE response, so ONE pagination level suffices; this is
  simpler than the GitHub W1f two-level walk). 2-page discussion list → merged
  array in arrival order.
- TC-P33-146 — page cap: `CHP_GITLAB_REVIEW_THREADS_PAGE_CAP=1` while the
  fixture reports a 2nd page → rc≠0 EMPTY stdout, loud stderr.
- TC-P33-147 — mid-walk failure: page 1 OK, page 2 `_gl_api` rc≠0 → leaf
  rc≠0 EMPTY stdout (the assigned mandatory failure fixture — mirrors #401's
  fail-CLOSED discipline for the GitHub W1f leaf).
- TC-P33-148 — empty discussion set → `[]` rc 0.

---

## Cross-cutting positional-validation gates

- TC-P33-160 — `chp_gitlab_ci_status ""` → rc 2, ZERO `_gl_api` calls.
- TC-P33-161 — `chp_gitlab_ci_status abc` (non-numeric MR iid) → rc 2, ZERO
  `_gl_api` calls (mirrors the W1e convention `^[0-9]+$` guard).
- TC-P33-162 — `chp_gitlab_mergeable ""` / `abc` → rc 2.
- TC-P33-163 — `chp_gitlab_review_threads ""` / `abc` → rc 2.
- TC-P33-164 — `chp_gitlab_list_inline_comments ""` / `abc` → rc 2.
- TC-P33-165 — `chp_gitlab_pr_view ""` / `abc` → rc 2.
- TC-P33-166 — `chp_gitlab_find_pr_for_issue ""` / `abc` → rc 2.

---

## Caps manifest (R11 — evidence-cited)

- TC-P33-180 — `chp-gitlab.caps` exists as a sibling of `chp-gitlab.sh`.
- TC-P33-181 — `native_issue_pr_link=1` present (with the same-project-scope
  caveat comment).
- TC-P33-182 — `rest_request_changes=0` present.
- TC-P33-183 — `review_bots=0` present.
- TC-P33-184 — `merge_closes_issue=1` present WITH the default-branch-only
  caveat verbatim in the caps comment.
- TC-P33-185 — `marker_channel=html` present.

---

## Behavior-parity framing (R14)

- TC-P33-200 — no caller-layer file is edited by this PR (the phase-2 abstract
  seam already routes every call site through `chp_<verb>`).
- TC-P33-201 — `check-provider-cutover.sh` passes: no raw `glab` outside
  `providers/`; no raw `/api/v4`-shaped curl outside
  `providers/lib-gitlab-transport.sh` (which doesn't exist yet on this branch —
  the leaves use `_gl_api` only, so the guard has nothing to complain about).
- TC-P33-202 — github axis stays 31/31 `pending=0`
  (`run-provider-conformance.sh --itp github --chp github`).
- TC-P33-203 — INV-91 guard green: zero out-of-providers `glab`/`/api/v4`
  hits.

---

## Notes on runner wiring (R13 — deferred to a `wip(conformance):` commit)

Per the pre-implementation brief, conformance-runner wiring is kept in ONE
final commit labeled `wip(conformance):` and will be redone at rebase after
#416 (transport) lands. Until then, the AC1 assertion "`run-provider-conformance.sh
--itp github --chp gitlab --expect-absent <write-verb-csv>` runs the seven read
verbs green under the fixture transport" is proven by the unit suite
(`tests/unit/test-chp-gitlab-reads.sh`), not the conformance runner. The runner
adapters + fixture `_gl_api` hook land after #416 provides
`--transport-hook`/`--transport-path-add`.
