# Provider conformance suite

A standalone, **hermetic** test suite that pins the
[`provider-spec.md`](../../docs/pipeline/provider-spec.md) contract for the
**ITP/CHP provider verbs** (§3.1/§3.2) — the issue-tracker and code-host seams
that abstract the GitHub coupling in the dispatcher/dev/review subsystem
([INV-106](../../docs/pipeline/invariants.md#inv-106-provider-conformance-is-spec-defined-and-regression-pinned-by-a-hermetic-provider-parameterized-runner--any-itp-namesh-chp-namesh--caps-pair-must-clear-it)).

> **Not to be confused with [`tests/conformance/`](../conformance/)** — that
> suite pins the **agent-CLI adapter** contract (`AdapterResult`,
> [INV-74](../../docs/pipeline/invariants.md#inv-74-adapter-conformance-is-regression-pinned-by-a-hermetic-fixture-manifest-runner)) —
> claude/codex/kiro/agy/gemini/opencode dispatch classification. This suite
> pins the **provider verb** contract — `itp_*`/`chp_*` shape, fail-closed rc,
> sort stability, and each verb's documented failure contract — for whichever
> `ISSUE_PROVIDER`/`CODE_HOST` backend is under test (`github` today, any
> future `itp-gitlab.sh`/`chp-gitlab.sh` pair tomorrow).

```
tests/provider-conformance/
├── run-provider-conformance.sh      # the runner
├── lib-provider-conformance.sh      # pure helpers (conf parsing, shape asserts)
├── coverage.conf                    # verb -> asserted|pending (R3 tripwire data)
├── cap-map.conf                     # verb -> governing cap (R4 SKIP/ASSERT data)
└── fixtures/
    ├── payloads/*.json[.meta]       # raw pre-transform gh payloads + provenance sidecars
    └── provider-broken/             # deliberately-broken fixture (AC2)
```

## Run the suite

```bash
# GitHub reference provider on both axes (default):
bash tests/provider-conformance/run-provider-conformance.sh

# Explicit / mixed axes — ITP and CHP are two INDEPENDENT selection axes:
bash tests/provider-conformance/run-provider-conformance.sh --itp github --chp github
bash tests/provider-conformance/run-provider-conformance.sh --itp degraded --chp degraded
bash tests/provider-conformance/run-provider-conformance.sh --itp github --chp degraded

# Full GitLab axis with the fixture transport hook (#420 P3-5 how-to;
# runner-test coverage: TC-RGH-060, #419). The same hook file serves ITP
# endpoints (/issues, /notes, /labels, resource-label-events) and CHP
# endpoints (/merge_requests, /discussions, /approvals, files/branches
# for chp_gitlab_commit_file). `--transport-hook` is exactly ONE arg
# (spec [INV-116]). Expected SUMMARY: fail=0 pending=0, 2 SKIPs
# (chp_request_changes rest_request_changes=0 + chp_trigger_bot review_bots=0).
bash tests/provider-conformance/run-provider-conformance.sh \
  --itp gitlab --chp gitlab \
  --transport-hook tests/provider-conformance/fixtures/gitlab-hook/gitlab-transport-hook.sh

# env fallback (used when a flag is omitted):
ITP_UNDER_TEST=degraded CHP_UNDER_TEST=degraded bash tests/provider-conformance/run-provider-conformance.sh
```

Built-in provider names: `github` (the reference impl,
`skills/autonomous-dispatcher/scripts/providers/`), `degraded` (the
capability-limited fixture, `tests/unit/fixtures/provider-degraded/`), and
`broken` (the deliberately-broken fixture, `fixtures/provider-broken/`, AC2).

Output is one line per verb plus a summary:

```
CONFORMANCE-PCONF github/github itp_list_comments PASS
CONFORMANCE-PCONF degraded/degraded itp_edit_comment SKIP (cap: edit_comment)
CONFORMANCE-COVERAGE PASS (spec CONTRACT-PENDING set == coverage.conf pending set, 0 verbs)
CONFORMANCE-SUMMARY total=31 pass=31 fail=0 skip=0 pending=0
```

The runner exits **non-zero** on any `FAIL` — a wrong-shape output, an
rc-0-on-error write, a missing verb function, or a coverage-tripwire
asymmetry. A `SKIP` (a capability-gated verb reading `0` for the selected
provider) and a `PENDING` (a not-yet-conformance-checked W1-backlog verb) are
never a `FAIL` by themselves.

## What this suite asserts (§3.1/§3.2's `Asserted` cells)

Per [`provider-spec.md` §10](../../docs/pipeline/provider-spec.md#10-per-verb-conformance-checklist-370)'s
`TC-PCONF-NNN` checklist — the 26 provider-neutral verbs whose contract is
already committed (W1a=#371 landed the three ITP state-reads as normalized
shapes; W1b=#396 landed `itp_read_task`; W1c1=#397 added
`chp_find_pr_for_issue` and `chp_pr_list`; W1c2=#398 added `chp_pr_view`
and `chp_list_inline_comments`; W1d=#399 added `chp_ci_status` and
`chp_mergeable` as normalized-token leaves; W1e=#400 landed the three CHP
write verbs `chp_create_pr` / `chp_approve` / `chp_merge`. All CHP
lifecycle verbs are now asserted; no `CONTRACT-PENDING` remains):

- **Fail-closed writes** (`itp_transition_state`, `itp_post_comment`,
  `itp_edit_comment`, `itp_mark_checkbox`, `itp_provision_states`,
  `chp_resolve_thread`, `chp_reply_review_comment`, `chp_request_changes`,
  `chp_create_pr`, `chp_approve`, `chp_merge`) —
  rc 0 + the documented `gh` argv shape on success; rc≠0 with no partial
  output on failure.
- **Fail-soft observe/lookup** (`itp_resolve_dep`, `itp_label_event_ts`) —
  rc **0** and an empty value on failure (the documented contract; asserting
  fail-closed here would be a false finding).
- **Shape + malformed-JSON handling** (`itp_list_comments`,
  `chp_review_threads`, `chp_list_inline_comments`) — the [INV-90] / W1c2
  normalized array shape (+ ascending `createdAt` for issue-level and inline
  comments), and graceful (non-crashing, empty) handling of a malformed
  payload. `chp_list_inline_comments` (W1c2, #398) additionally asserts the
  leaf-side `line // original_line // null` fold + fail-CLOSED on any page
  fail AND on rc-0 empty stdout (a real zero-comment PR emits literal `[]`).
  **`chp_review_threads` (W1f, #401) also asserts multi-page completeness**:
  the payload-sequence stub-gh mode drives the leaf against a 2-page thread
  fixture (and a nested >first-page comments fixture) and asserts a full
  merged M8 array (both pages present); a mid-walk-failure fixture asserts
  rc != 0 with no partial output. The degraded provider asserts SHAPE ONLY
  here — completeness is per-provider, scoped to `--chp github`.
- **Single-object shape + fields-subset + fail-closed** (`itp_read_task`,
  W1b #396; `chp_pr_view`, W1c2 #398) — the normalized-object shape, a
  fields-subset request returning EXACTLY the requested keys, and fail-CLOSED
  (non-zero rc, no partial output) on both a `gh` failure AND rc-0 empty
  stdout AND malformed JSON (capture-then-check). `chp_pr_view` supports
  every §3.2.1 vocabulary field and folds `closingIssueNumbers` from BOTH the
  flat `[{number}]` gh shape AND the GraphQL cursor `{nodes:[…]}` form.
- **Abstract PR-list-read shape** (`chp_find_pr_for_issue`, `chp_pr_list`,
  both W1c1 #397) — the [§3.2.1] normalized PR-field vocabulary: `body`
  pinned to a string (`null` → `""`, #148 hazard fix), `closingIssueNumbers`
  as an int-array (the [INV-86] resolution key), COMPLETE-set cursor page
  walk with fail-CLOSED cap-hit, empty match → `[]` (never null). Missing
  STATE or FIELDS-CSV positional args → rc != 0.
- **Caller-side render, no leaf dispatch** (`chp_close_keyword`) — the three
  `_render_close_keyword` branches (`Closes #N` / `Related to #N` / empty),
  never `chp_has_leaf close_keyword` — see the design doc's "deliberate
  NON-leaf exception" callout (`../../docs/designs/provider-conformance-runner.md`).
- **State-read leaves** (`itp_list_by_state`, `itp_count_by_state`,
  `itp_list_forbidden_combos`) — the W1a-normalized shape and ascending-by-
  `number` sort.
- **Normalized-token CI + mergeable** (`chp_ci_status`, `chp_mergeable`, W1d
  #399) — `chp_ci_status` derives exactly one token from
  `green|pending|failed|none` per the R1 decision order (rule 2 beats rule 3);
  `chp_mergeable` returns exactly one raw GitHub token from
  `MERGEABLE|CONFLICTING|UNKNOWN` (the caller's `-q '.mergeable'` absorbed
  into the leaf). Assertions: token-set membership on canned payloads
  (all-success, mixed-failure, empty for `chp_ci_status`; `MERGEABLE` for
  `chp_mergeable`); the green-predicate on the all-success payload;
  fail-closed on stub-gh failure (rc≠0, no partial output — the leaves
  themselves reject empty stdout / unknown mergeable tokens).

## `CONTRACT-PENDING` verbs (R3) — none left (post-W1a/W1b/W1c1/W1c2/W1d/W1e)

Every CHP-lifecycle verb has now been migrated to its abstract contract by
W1a=#371 (three ITP state-reads), W1b=#396 (`itp_read_task`), W1c1=#397
(two CHP linkage-reads), W1c2=#398 (`chp_pr_view` + `chp_list_inline_comments`),
W1d=#399 (`chp_ci_status` + `chp_mergeable`), and W1e=#400 (three CHP write
verbs `chp_create_pr` / `chp_approve` / `chp_merge`). No spec row carries
`CONTRACT-PENDING`; `coverage.conf` has zero `pending` rows. The runner's
`CONFORMANCE-COVERAGE` set-diff tripwire is vacuously green (both sides
empty) but stays wired so a future new-verb addition with a pending status
would trigger it.

The pending count shrinks as W1 slices land — the original 13-verb set at
#370 has already lost `itp_list_by_state` / `itp_count_by_state` /
`itp_list_forbidden_combos` to #371 (W1a), `itp_read_task` to #396 (W1b),
and `chp_find_pr_for_issue` / `chp_pr_list` to #397 (W1c1), leaving **7**
verbs pending as of #401. Prefer citing the exact list above (or the
runner's live `CONFORMANCE-COVERAGE` line) over a bare number in prose
elsewhere in the repo so the next slice doesn't re-drift the count.

## Governing capability map (R4)

`cap-map.conf` maps each asserted verb to its governing `.caps` key (`-` for
none). The runner reads the SELECTED provider's cap through the public seam
(`itp_caps`/`chp_caps`) before asserting; a `0`/absent cap is a `SKIP`, never
a silent pass and never a `FAIL`. See
[`provider-spec.md` §4.4](../../docs/pipeline/provider-spec.md#44-conformance-verb--governing-cap-map-370)
for the full table.

## Adding a new provider (e.g. `itp-gitlab.sh`/`chp-gitlab.sh`)

1. Add `github`/`gitlab` (or whatever name) to
   `lib-provider-conformance.sh::pcf_resolve_provider_dir`'s fixed table,
   pointing at the new provider's real source dir.
2. Run `bash tests/provider-conformance/run-provider-conformance.sh --itp gitlab --chp gitlab`.
3. Every `ASSERTED` verb your new backend implements must PASS (or `SKIP`
   honestly per its `.caps`). This is the acceptance gate.
4. There are no residual `CONTRACT-PENDING` verbs to worry about — every
   §3.2 CHP-lifecycle row is asserted post-W1e (#400). If a future spec
   change re-adds a `CONTRACT-PENDING` marker, the runner's set-diff
   tripwire immediately catches an asymmetry between spec and
   `coverage.conf`; the slice landing that new marker owns adding its
   conformance check in the same PR.

## Scope

- **In scope**: the hermetic, credential-free regression tier for the
  provider-neutral ITP/CHP verb contract.
- **Out of scope**: WAIVED→LIVE caps wiring (that's `test-provider-caps-branches.sh`'s
  tripwire); error-path/pagination fixtures for the residual `CONTRACT-PENDING`
  verbs (7 as of #401 — arrive per W1 slice); any wrapper, provider-leaf,
  or dispatcher behavior change. (`chp_review_threads` pagination-completeness
  moved IN scope in #401 / #347 W1f, per the "Shape + malformed-JSON
  handling" bullet above; the degraded provider still asserts shape only.)

## CI placement

Runs in CI through the existing `hermetic-unit` job's
`for test in tests/unit/test-*.sh` loop
(`tests/unit/test-provider-conformance-runner.sh` is auto-discovered) — no
`ci.yml` edit needed, mirroring [INV-91]'s scoped-token accommodation (a
dev-side App token cannot push `.github/workflows/`).
