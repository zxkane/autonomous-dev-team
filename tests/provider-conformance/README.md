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
CONFORMANCE-PCONF github/github chp_ci_status PENDING (coverage.conf)
CONFORMANCE-COVERAGE PASS (spec CONTRACT-PENDING set == coverage.conf pending set, 7 verbs)
CONFORMANCE-SUMMARY total=27 pass=20 fail=0 skip=0 pending=7
```

The runner exits **non-zero** on any `FAIL` — a wrong-shape output, an
rc-0-on-error write, a missing verb function, or a coverage-tripwire
asymmetry. A `SKIP` (a capability-gated verb reading `0` for the selected
provider) and a `PENDING` (a not-yet-conformance-checked W1-backlog verb) are
never a `FAIL` by themselves.

## What this suite asserts (§3.1/§3.2's `Asserted` cells)

Per [`provider-spec.md` §10](../../docs/pipeline/provider-spec.md#10-per-verb-conformance-checklist-370)'s
`TC-PCONF-NNN` checklist — the 19 provider-neutral verbs whose contract is
already committed (W1a=#371 landed the three ITP state-reads as normalized
shapes; W1b=#396 landed `itp_read_task`; W1c1=#397 adds
`chp_find_pr_for_issue` and `chp_pr_list` to the asserted set):

- **Fail-closed writes** (`itp_transition_state`, `itp_post_comment`,
  `itp_edit_comment`, `itp_mark_checkbox`, `itp_provision_states`,
  `chp_resolve_thread`, `chp_reply_review_comment`, `chp_request_changes`) —
  rc 0 + the documented `gh` argv shape on success; rc≠0 with no partial
  output on failure.
- **Fail-soft observe/lookup** (`itp_resolve_dep`, `itp_label_event_ts`) —
  rc **0** and an empty value on failure (the documented contract; asserting
  fail-closed here would be a false finding).
- **Shape + malformed-JSON handling** (`itp_list_comments`,
  `chp_review_threads`) — the [INV-90] normalized array shape (+ ascending
  `createdAt` for comments), and graceful (non-crashing, empty) handling of a
  malformed payload.
- **Single-object shape + fields-subset + fail-closed** (`itp_read_task`,
  W1b #396) — the normalized-object shape (`labels` as name strings), a
  fields-subset request returning EXACTLY the requested keys, and fail-CLOSED
  (non-zero rc, no partial output) on both a `gh` failure and malformed JSON
  — unlike the array leaves above, a single-task read has no valid "empty"
  representation.
- **Abstract PR-read shape** (`chp_find_pr_for_issue`, `chp_pr_list`, both
  W1c1 #397) — the [§3.2.1] normalized PR-field vocabulary: `body` pinned to a
  string (`null` → `""`, #148 hazard fix), `closingIssueNumbers` as an
  int-array (the [INV-86] resolution key), COMPLETE-set cursor page walk
  with fail-CLOSED cap-hit, empty match → `[]` (never null). Missing STATE
  or FIELDS-CSV positional args → rc != 0.
- **Caller-side render, no leaf dispatch** (`chp_close_keyword`) — the three
  `_render_close_keyword` branches (`Closes #N` / `Related to #N` / empty),
  never `chp_has_leaf close_keyword` — see the design doc's "deliberate
  NON-leaf exception" callout (`../../docs/designs/provider-conformance-runner.md`).

## The 7 `CONTRACT-PENDING` verbs (R3, post-W1a/W1b/W1c1)

The residual gh-argv passthrough verbs (`chp_ci_status`, `chp_mergeable`,
`chp_pr_view`, `chp_list_inline_comments`, `chp_create_pr`, `chp_approve`,
`chp_merge`) have no conformance check yet — `provider-spec.md` tokens
their rows `CONTRACT-PENDING` and `coverage.conf` lists them `pending`.
Landed W1 slices (W1a=#371 for the three ITP state-reads, W1b=#396 for
`itp_read_task`, W1c1=#397 for the two CHP linkage-reads) each removed
their own spec tokens and flipped `coverage.conf` in the same PR. A
future W1 slice does the same — the runner's `CONFORMANCE-COVERAGE`
check is a set-diff tripwire that FAILs on any asymmetry between the
two. All four ITP READ verbs are now asserted, leaving only the CHP
PR-lifecycle verbs pending.

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
4. The 7 residual `CONTRACT-PENDING` verbs are not required for THIS gate
   (they land with the remaining W1 slices) — but any verb you DO implement
   for the pending set still needs its own conformance check added in that
   slice's PR.

## Scope

- **In scope**: the hermetic, credential-free regression tier for the
  provider-neutral ITP/CHP verb contract.
- **Out of scope**: WAIVED→LIVE caps wiring (that's `test-provider-caps-branches.sh`'s
  tripwire); error-path/pagination fixtures for the residual `CONTRACT-PENDING`
  verbs (arrive per W1 slice); `chp_review_threads` pagination-COMPLETENESS
  (shape only — see `provider-spec.md` §3.2's known cut-line); any wrapper,
  provider-leaf, or dispatcher behavior change.

## CI placement

Runs in CI through the existing `hermetic-unit` job's
`for test in tests/unit/test-*.sh` loop
(`tests/unit/test-provider-conformance-runner.sh` is auto-discovered) — no
`ci.yml` edit needed, mirroring [INV-91]'s scoped-token accommodation (a
dev-side App token cannot push `.github/workflows/`).
