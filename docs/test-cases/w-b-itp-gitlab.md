# Test Cases — W-B: `itp-gitlab.sh` + `itp-gitlab.caps` (issue #417)

Phase-3 W-B slice of #414 (parent) / #416 (P3-1 transport dep). Covers all 14
ITP verbs against the standard GitLab REST Issues API, driven through the
FROZEN `_gl_api` / `_gl_urlencode` contract (#416).

## Scope

- **Under test**: `skills/autonomous-dispatcher/scripts/providers/itp-gitlab.sh`
  (14 leaves `itp_gitlab_*`) + `skills/autonomous-dispatcher/scripts/providers/itp-gitlab.caps`.
- **Hermetic**: no live GitLab. Every test defines a local `_gl_api` /
  `_gl_urlencode` stub that serves recorded fixture payloads and sets
  `GL_API_STATUS`. `itp-gitlab.sh` is sourced AFTER the stubs.
- **Bash 4 target** (matches the repo convention). Run under
  `env -u PROJECT_DIR bash …` for CI parity.
- **GitLab version modeled**: `17.x` (each fixture `.meta` names it).

## Cross-references

- Contracts: `docs/pipeline/provider-spec.md` §3.1 (per-verb) / §3.3 (comment
  shape) / §3.4 (config keys) / §3.5 (list completeness) / §5.1 (GitLab
  research summary).
- GitHub reference leaf: `skills/autonomous-dispatcher/scripts/providers/itp-github.sh`
  — the normalized output MUST match what callers already consume, so most
  shape asserts here mirror `tests/unit/test-w1a-state-read-contracts.sh` and
  `test-w1b-read-task-contracts.sh` on the GitLab side.

## Fixtures

Under `tests/provider-conformance/fixtures/payloads/`:

| Fixture | Endpoint modeled | Shape hint |
|---|---|---|
| `gitlab-issues-list.json` | `/projects/:id/issues?state=opened&labels=…` | array of issue objects (single page) |
| `gitlab-issues-list-p1.json` | same, page 1 | multi-page issues (used with a page-2 fixture) |
| `gitlab-issues-list-p2.json` | same, page 2 | multi-page merge assertion |
| `gitlab-issue-view.json` | `/projects/:id/issues/:iid` | single issue with `description`, `state=opened`, `labels[]` name strings |
| `gitlab-notes-list.json` | `/projects/:id/issues/:iid/notes?sort=asc&order_by=created_at` | notes incl. `system:true` and mixed authors (project bot / human / self) |
| `gitlab-transition-put.json` | `PUT /projects/:id/issues/:iid` | echoed issue after add/remove_labels |
| `gitlab-post-note.json` | `POST /projects/:id/issues/:iid/notes` | created note echo |
| `gitlab-labels-view.json` | `GET /projects/:id/labels/:name` | existing label |
| `gitlab-labels-create.json` | `POST /projects/:id/labels` | created label |
| `gitlab-resource-label-events.json` | `GET /projects/:id/issues/:iid/resource_label_events` | multi-page events with `.action` + `.label.name` |
| `gitlab-issue-view-crossproj.json` | cross-project `resolve_dep` lookup | slash-bearing project path |

Each fixture ships a `.meta` sidecar stating `source`, `capture_date`,
`gitlab_version: 17.x`, `endpoint`, `shape`.

Under `tests/provider-conformance/fixtures/gitlab/probes/` — hand-authored
evidence stubs for the `.caps` entries per R2 (each flagged `hand_authored:
true` in its `.meta`).

## Test Cases

### `itp_gitlab_list_by_state STATE LABELS_AND_CSV LIMIT FIELDS_CSV`

- **TC-WB-001**: opened state, single-label AND filter, single page. Expect
  JSON array sorted ascending by `number`, `labels` as name strings, `number`
  is int, `title` is string, empty query → `[]`.
- **TC-WB-002**: `FIELDS_CSV=comments` triggers a second `_gl_api` call per
  issue to `itp_gitlab_list_comments`; the projected shape carries the [INV-90]
  normalized comment array (system-notes filtered out).
- **TC-WB-003**: `STATE=open` maps to GitLab's `opened`; `STATE=closed` maps to
  `closed`; `STATE=all` maps to `all`. Assert the `state=<opened|closed|all>`
  query-string arm on the recorded `_gl_api` path.
- **TC-WB-004**: multi-page merge — page 1 + page 2 fixtures merge into ONE
  array with entries from both pages in order; length = sum.
- **TC-WB-005**: mid-walk fail — page 1 OK, page 2 sets rc≠0 → leaf rc≠0, NO
  partial stdout (fail-CLOSED per §3.5 / #401 discipline inherited from
  `_gl_api`).
- **TC-WB-006**: `FIELDS_CSV=number` → EXACTLY one key per element (`number`).
  `FIELDS_CSV=number,labels` → exactly two keys.

### `itp_gitlab_count_by_state STATE LABELS_AND_CSV LIMIT ANY_OF_LABELS_CSV`

- **TC-WB-010**: bare integer output; empty any-of counts all AND-matches;
  non-empty any-of intersection semantics.
- **TC-WB-011**: fail-CLOSED — `_gl_api` rc≠0 → leaf rc≠0, no partial stdout.

### `itp_gitlab_list_forbidden_combos STATE LABELS_AND_CSV LIMIT`

- **TC-WB-020**: fixture with 4 issues (terminal-only, transitional-only,
  terminal+transitional, unrelated). Leaf returns only the mixed-combo issue
  with fields `number,labels` and nothing else.
- **TC-WB-021**: fail-CLOSED on any enumeration failure.

### `itp_gitlab_transition_state ISSUE REMOVE ADD`

- **TC-WB-030**: single-label per side — one PUT with body
  `{"add_labels":"pending-review","remove_labels":"in-progress"}`. Assert
  `--method PUT` on the recorded call.
- **TC-WB-031**: CSV multi-label — REMOVE=`in-progress,pending-dev`,
  ADD=`reviewing` renders BOTH removes in the CSV verbatim; still ONE PUT
  (atomic).
- **TC-WB-032**: empty side omits its key entirely — REMOVE=`""` yields
  `{"add_labels":"…"}` with NO `remove_labels` key; ADD=`""` symmetric.
- **TC-WB-033**: fail-CLOSED on `_gl_api` rc≠0.

### `itp_gitlab_read_task ISSUE FIELDS_CSV`

- **TC-WB-040**: `FIELDS_CSV=title,body,state,labels` — single object with
  exactly those keys; `state` normalizes `opened` → `OPEN`, `closed` →
  `CLOSED`; `description` renames to `body`; labels are name-strings.
- **TC-WB-041**: `body` absent in fixture → `""` after normalization.
- **TC-WB-042**: `FIELDS_CSV` includes `comments` → same-tick
  `itp_gitlab_list_comments` invocation; comments carry the [INV-90] shape.
- **TC-WB-043**: fields subset — `FIELDS_CSV=body` returns EXACTLY `{"body":…}`
  with no other keys.
- **TC-WB-044**: fail-CLOSED — `_gl_api` rc≠0 OR empty stdout → leaf rc≠0
  (capture-then-check).

### `itp_gitlab_post_comment ISSUE BODY`

- **TC-WB-050**: `--method POST --body '{"body":"…"}'` shaped call. Assert
  path is `/projects/${GITLAB_PROJECT}/issues/${ISSUE}/notes`.
- **TC-WB-051**: HTML marker round-trip — `BODY` containing
  `<!-- dispatcher-token: … -->` reaches `_gl_api` verbatim (jq -n --arg
  discipline; no substitution).
- **TC-WB-052**: fail-CLOSED on `_gl_api` rc≠0.

### `itp_gitlab_edit_comment ISSUE COMMENT_ID BODY`

- **TC-WB-060**: `--method PUT` against
  `/projects/${GITLAB_PROJECT}/issues/${ISSUE}/notes/${COMMENT_ID}` with
  `{"body":…}`.
- **TC-WB-061**: fail-CLOSED on `_gl_api` rc≠0.

### `itp_gitlab_list_comments ISSUE`

- **TC-WB-070**: paginated call with `sort=asc&order_by=created_at`; leaf
  drives `_gl_api --paginate`. Output is the [INV-90] normalized array:
  `{id, author, authorKind, body, createdAt}`, ascending by `createdAt` with
  `id` tie-break.
- **TC-WB-071**: system-note filter — a fixture note with `system: true` is
  DROPPED entirely (never crosses the seam, matches CHP-side discipline).
- **TC-WB-072**: `authorKind` derivation:
  - `author.username == BOT_LOGIN` → `self`
  - `author.username` matches `^(project|group)_\d+_bot(_[a-z0-9]+)?$` → `bot`
  - else → `human`
- **TC-WB-073**: fail-CLOSED on `_gl_api` rc≠0.
- **TC-WB-074**: sort tie-break — two notes with identical `createdAt`
  preserve ascending `id` order (matches
  `_fetch_agent_verdict_body`'s `| last` reliance, #321).

### `itp_gitlab_resolve_dep OWNER_REPO NUM OUT_VAR`

- **TC-WB-080**: separate positional args (leaf does NOT parse `#`).
  `OWNER_REPO="group/subgroup/project"` (slash-bearing) is URL-encoded via
  `_gl_urlencode` before the lookup path is built. `state=opened` → `OPEN`,
  `state=closed` → `CLOSED` (uppercase tokens per §3.1 W1b precedent).
- **TC-WB-081**: fail-SOFT — `_gl_api` rc≠0 → empty out-var, leaf rc 0 (caller
  fail-safe-blocks).
- **TC-WB-082**: no per-dep-repo token mint under [INV-83] simplification
  (single `GITLAB_TOKEN` spans all accessible projects); assert the leaf
  never sources `gh-app-token.sh` and never references a `_DEP_TOKEN_CACHE`.

### `itp_gitlab_mark_checkbox ISSUE NEW_BODY`

- **TC-WB-090**: `--method PUT` against
  `/projects/${GITLAB_PROJECT}/issues/${ISSUE}` with
  `{"description":"…"}`; the (pre-rewritten) NEW_BODY passes through verbatim.
- **TC-WB-091**: fail-CLOSED on `_gl_api` rc≠0.

### `itp_gitlab_provision_states NAME COLOR DESCRIPTION`

- **TC-WB-100**: existence probe — `_gl_api --tolerate-status 404
  /projects/${GITLAB_PROJECT}/labels/<NAME>`; `GL_API_STATUS=200` → emit
  `  [skip] '<NAME>' already exists`. Assert no POST call is issued.
- **TC-WB-101**: `GL_API_STATUS=404` → follow-up
  `--method POST --tolerate-status 409 /projects/${GITLAB_PROJECT}/labels`
  with `{"name":…,"color":…,"description":…}` body. Emit
  `  [created] '<NAME>'`.
- **TC-WB-102**: `GL_API_STATUS=409` on create (concurrent-provisioner race)
  → downgrade to `[skip]`, leaf rc 0.
- **TC-WB-103**: `_gl_api` rc≠0 (transport-level, not tolerated-status) →
  leaf rc≠0.
- **TC-WB-104**: idempotency across two back-to-back invocations — the second
  call takes the `[skip]` branch.

### `itp_gitlab_label_event_ts ISSUE LABEL`

- **TC-WB-110**: paginated read over `/projects/:id/issues/:iid/resource_label_events`;
  leaf's in-process jq filter selects `action == "add" AND label.name == LABEL`
  and emits the newest `.created_at` string. `--arg` bind is used to keep the
  label-name injection-safe.
- **TC-WB-111**: no matching event → empty stdout, leaf rc 0 (fail-SOFT
  contract).
- **TC-WB-112**: fail-SOFT on `_gl_api` rc≠0 → empty stdout, rc 0.
- **TC-WB-113**: multi-page walk — newest matching event sits on page 2 and
  is returned correctly (proves the leaf uses `--paginate`).

### `itp_gitlab_begin_tick`

- **TC-WB-120**: leaf exists, invokable, returns rc 0 with no side effect
  (documented no-op; GitLab's PAT already spans accessible projects, so no
  `_DEP_TOKEN_CACHE` reset is needed).

### `itp_caps` (parsed from `itp-gitlab.caps`)

- **TC-WB-130**: `itp_caps server_side_state_and` → `1` under
  `ISSUE_PROVIDER=gitlab`.
- **TC-WB-131**: `itp_caps server_side_state_negation` → `1` (GitLab's
  `not[labels]=X`).
- **TC-WB-132**: `itp_caps marker_channel` → `html`.
- **TC-WB-133**: `itp_caps distinct_bot_author` → `1` (project/group access
  tokens post as synthetic `project_<n>_bot*` users).
- **TC-WB-134**: `itp_caps read_after_write_state` → `1`.
- **TC-WB-135**: `itp_caps cross_ref_shorthand` → `1`.
- **TC-WB-136**: `itp_caps body_checkbox` → `1`.
- **TC-WB-137**: `itp_caps edit_comment` → `1`.
- **TC-WB-138**: `itp_caps label_colors` → `1`.

## Cross-cutting

- **AC1 shape**: every list-returning leaf emits `[]` on empty (never `null`).
- **AC1 shape**: every read leaf that projects to `FIELDS_CSV` returns EXACTLY
  the requested keys.
- **AC2 no seam bleed**: no jq-program fragment and no CLI-flag string is
  interpolated into a request body (`jq -n --arg`).
- **AC3 evidence**: every `.caps=1` value cites either an API-doc URL or a
  `fixtures/gitlab/probes/` file (both live in the PR body's Evidence
  section).

## Out of Scope

- Live GitLab smoke (operator post-merge gate per #414).
- CHP-side (`chp-gitlab.sh`/`.caps`) — W-C1 / W-C2.
- Provider-conformance runner ITP-axis wiring beyond a symlink into the
  scratch dir — the runner already accepts an out-of-tree provider dir via the
  fixed table extension shipped in #416 (P3-1 W-D early-half). This slice
  ADDS a same-file gitlab-axis fixture set but does not modify the runner's
  assertion table; a follow-up (or the same PR's `wip(conformance):` commit,
  scheduled for rebase onto #416) wires the assertions to actually run against
  the gitlab-axis fixtures.
