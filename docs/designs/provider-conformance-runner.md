# Design: provider-parameterized conformance runner (#370, #347 W2)

## Goal

A hermetic runner that, given `--itp <name> --chp <name>`, asserts the
provider-spec.md contract for the provider-neutral subset of ITP/CHP verbs
against whichever backend is selected — GitHub today, any future
`itp-<name>.sh`/`chp-<name>.sh` pair tomorrow.

## Layout

```
tests/provider-conformance/
├── README.md
├── run-provider-conformance.sh      # the runner (entry point)
├── lib-provider-conformance.sh      # pure helpers: caps parse, shape asserts, argv capture
├── coverage.conf                    # verb=asserted|pending  (R3 tripwire data)
├── cap-map.conf                     # verb=<cap|cap1,cap2|->  (R4 governing-cap data)
└── fixtures/
    └── provider-broken/
        ├── itp-broken.sh
        ├── itp-broken.caps
        ├── chp-broken.sh
        └── chp-broken.caps
```

`tests/unit/test-provider-conformance-runner.sh` is the `tests/unit/test-*.sh`
auto-discovered wrapper that invokes the runner against the repo (github/github
+ github/degraded) so it runs in the existing hermetic-unit CI loop with no
`ci.yml` edit (mirrors `check-provider-cutover.sh`'s accommodation — a scoped
dev-side token cannot push `.github/workflows/`).

## Provider selection (the two independent axes)

`lib-issue-provider.sh` / `lib-code-host.sh` both read a SINGLE shared
`AUTONOMOUS_PROVIDERS_DIR` override at source time. To let `--itp X --chp Y`
select two DIFFERENT source directories (e.g. `--itp github --chp degraded`),
the runner resolves each name to its source dir via a fixed table —

| name | source dir |
|---|---|
| `github` | `skills/autonomous-dispatcher/scripts/providers/` (skill tree, `readlink -f`) |
| `degraded` | `tests/unit/fixtures/provider-degraded/` |
| `broken` | `tests/provider-conformance/fixtures/provider-broken/` |

— then materializes a **scratch provider dir** per run containing symlinks
`itp-<itp_name>.{sh,caps}` (from the ITP name's source dir) and
`chp-<chp_name>.{sh,caps}` (from the CHP name's source dir), and points the
single `AUTONOMOUS_PROVIDERS_DIR` at the scratch dir. This is the load-bearing
trick that makes the two axes genuinely independent despite the shared env var.
`ITP_UNDER_TEST` / `CHP_UNDER_TEST` env vars are the fallback when the flags are
omitted; both default to `github`.

## Hermetic stub `gh`

Mirrors `tests/conformance/run-conformance.sh`'s discipline: a stub `gh`
(covering `issue view/edit/comment`, `api` incl. `graphql`, `label create`, `pr
*`) is installed on an isolated `PATH`. Per R1's explicit allowlist, the
isolated PATH is **stub dir + the dirs hosting `bash`, coreutils, `jq`, and
`grep`/`sed`** — not just "stub dir + coreutils" (several leaves, e.g.
`itp_github_label_event_ts`, shell out to a real `jq` binary directly rather
than through `gh`, so `jq`'s dir must be reachable too). The stub is
**configurable per assertion**: a control file tells it to emit a canned
payload (success) or fail (rc≠0, empty stdout), and it always records the
exact argv it received to `.argv.json` — the same mechanism
`test-itp-read-leaves.sh`'s recording `gh()` function uses, generalized into a
real PATH binary so both `github` and `degraded` leaves (which both shell out
to `gh`) resolve to it identically. `FAIL stub-missing` fires if the
provider's leaf resolves any binary outside the stub dir — never a silent
fallthrough to a real CLI (mirrors the INV-74 hermeticity guard). The scratch
provider dir and stub dir are both `mktemp -d`, cleaned by an `EXIT` trap
(mirrors `run-conformance.sh`'s `work_root` trap).

## Coverage table (R3)

`coverage.conf` — one `verb=asserted|pending` line per verb in the 13 R2 verbs
(`asserted`) and the 13 R3 gh-argv-passthrough verbs (`pending`). The tripwire
test (in the runner, reported as its own `CONFORMANCE-COVERAGE` check) does a
set-diff against every `CONTRACT-PENDING` token grepped from
`provider-spec.md` §3.1/§3.2: every `pending` verb here MUST have the token on
its spec row, and vice versa — asymmetry is a FAIL naming the verb. This is
plain `grep`, not markdown parsing (per the issue's explicit steer).

## Governing-cap map (R4)

`cap-map.conf` — one `verb=<cap-name|cap1,cap2|->` line per ASSERTED verb.
Resolved caps (github/degraded, both known-good matrices already committed in
`itp-github.caps`/`chp-github.caps`/the degraded fixture's `.caps`):

| verb | governing cap | degraded value | degraded disposition |
|---|---|---|---|
| `itp_list_comments` | `-` | n/a | ASSERT (unconditional shape) |
| `itp_transition_state` | `-` | n/a | ASSERT |
| `itp_post_comment` | `-` | n/a | ASSERT |
| `itp_edit_comment` | `edit_comment` | `0` | SKIP |
| `itp_mark_checkbox` | `body_checkbox` | `0` | SKIP |
| `itp_provision_states` | `-` | n/a | ASSERT |
| `itp_resolve_dep` | `-` | n/a | ASSERT (fail-soft contract) |
| `itp_label_event_ts` | `-` | n/a | ASSERT (fail-soft contract) |
| `chp_review_threads` | `-` | n/a | ASSERT |
| `chp_resolve_thread` | `-` | n/a | ASSERT |
| `chp_request_changes` | `rest_request_changes` | `0` | SKIP |
| `chp_reply_review_comment` | `-` | n/a | ASSERT |
| `chp_close_keyword` | `-` | n/a | ASSERT (pure render, caps-branch content) |

So R4 requires **9** degraded leaves to actually exist and behave correctly
(the `-`-governed rows, EXCLUDING `chp_close_keyword` — see the callout below)
— `itp-degraded.sh`/`chp-degraded.sh` gain minimal leaf bodies (structurally
like the GitHub leaves — same `gh`/`gh api` shape, stripped of GitHub-specific
entanglement like token caching/injection pre-encoding, since those aren't
part of the provider-neutral contract under test) so the degraded run has
something real to assert against instead of universal `command not found`.
This is squarely R4's ask ("flesh out chp-degraded.sh from empty scaffold to
a loadable provider that fails closed per its `.caps`") extended to
`itp-degraded.sh` for symmetry (chp alone can't carry
`itp_transition_state`/`itp_post_comment`/etc.).

**`chp_close_keyword` is a deliberate NON-leaf exception.** Adding
`chp_degraded_close_keyword` would flip `chp_has_leaf close_keyword` from
absent to present, which changes `tests/unit/test-chp-pr-lifecycle.sh`'s
`TC-CHP-LEAF-GUARD` — that test pins the exact leaf-absent + `merge_closes_issue=0`
+ `native_issue_pr_link=0` degraded state to prove the caller-side
`_render_close_keyword` fallback (`autonomous-dev.sh`) renders the non-closing
`Related to #N` backref. So the runner's `chp_close_keyword` ASSERT is scoped
to the **caller-side render contract**, not the verb dispatch: it evals the
real `_render_close_keyword` body from `autonomous-dev.sh` (the same technique
`test-provider-caps-branches.sh`'s `render_kw` helper already uses) against a
stubbed `chp_caps`, and asserts the three documented outputs
(`merge_closes_issue=1` → `Closes #N`; `=0`+`native_issue_pr_link=0` →
`Related to #N`; `=0`+`native_issue_pr_link=1` → empty) — never touching
`chp_has_leaf`/`chp_degraded_close_keyword`. `chp-degraded.sh` stays
leaf-less for `close_keyword`, matching today's fixture exactly. The
cap-map's disposition label for this row is `ASSERT (render-only, no leaf
dispatch)`, distinguishing it from the other 9 `-`-governed rows that DO
assert through the dispatched verb.

## Per-verb assertions (R2)

Four assertion *shapes*, applied per verb per the cap-map:

1. **Fail-closed write** (`itp_transition_state`, `itp_post_comment`,
   `itp_edit_comment`(gh only), `itp_mark_checkbox`(gh only),
   `itp_provision_states`, `chp_resolve_thread`, `chp_reply_review_comment`,
   `chp_request_changes`(gh only, SKIPped on degraded per the cap-map)):
   invoke once with the stub `gh` set to SUCCEED → assert rc 0 + the argv the
   stub recorded matches the verb's documented `gh` call shape; invoke again
   with the stub set to FAIL → assert rc≠0 and no partial/garbage stdout.
2. **Fail-soft observe/lookup** (`itp_resolve_dep`, `itp_label_event_ts`):
   invoke with the stub failing → assert rc **0** and the documented empty
   value (out-var empty / stdout empty) — asserting fail-closed here would
   contradict the shipped contract (the issue's own callout). `itp_resolve_dep`'s
   ASSERT is scoped to the **same-repo arm only** (`owner_repo == $REPO`, no
   token mint) — the cross-repo arm is separately gated by `cross_ref_shorthand`
   (degraded=0) and is Out of Scope here (no WAIVED→LIVE caps wiring). Adding
   `itp_degraded_resolve_dep` for this ASSERT does mean
   `test-itp-resolve-dep-golden-trace.sh`'s `TC-RDGT-010` (which today pins the
   *leaf-absent* skip-gating branch of `check_deps_resolved` against the
   degraded fixture) exercises a different code path after this PR — its
   assertions (`DEPS-RC=0`, no abort) still pass because our leaf returns
   `CLOSED`/empty exactly like the pre-existing raw-`gh` mock did, but the
   regression it pins shifts from "no leaf" to "leaf present, dep resolves
   normally." Flagged here so the PR that adds the leaf double-checks
   `TC-RDGT-010` still asserts something meaningful (or is updated to use a
   provider with no `resolve_dep` leaf at all, e.g. a THIRD scratch provider
   with zero leaves, if the leaf-absent contract still needs its own pin).
3. **Shape + malformed-JSON** (`itp_list_comments`, `chp_review_threads`):
   invoke with a valid canned payload → assert the array shape (`id`/
   `author`/`authorKind`/`body`/`createdAt` for comments; `thread_id`/
   `resolved`/`comments[]` for threads) and, for comments, ascending
   `createdAt` order; invoke with a malformed-JSON canned payload → assert the
   leaf fails gracefully (empty output, does not crash the runner — no
   uncaught `jq` parse error propagating past the subshell).
4. **Caller-side render, no leaf dispatch** (`chp_close_keyword` — see the
   callout above): no `gh` call, no `chp_has_leaf`/`chp_degraded_close_keyword`
   probe — eval the real `_render_close_keyword` body and assert its three
   documented `chp_caps`-branch outputs directly against a stubbed `chp_caps`.

Each assertion runs in its own subshell so a leaf that `command not found`s
(a genuinely missing function on the deliberately-broken fixture, or a
mis-mapped cap) is captured as one `FAIL <verb> <reason>` line, never a runner
abort — mirrors the INV-74 runner's per-fixture isolation.

## Deliberately-broken fixture (AC2 / Testing Requirements)

`fixtures/provider-broken/{itp,chp}-broken.{sh,caps}` — caps all `=1` (so
nothing legitimately SKIPs) with these violations, one per Testing-Requirements
category:

- **wrong shape**: `itp_broken_list_comments` returns a bare object, not an
  array.
- **rc-0-on-error**: `itp_broken_transition_state` always exits 0 even when
  the stub `gh` fails.
- **missing verb function**: `chp_broken_resolve_thread` is not defined at
  all.
- **non-array output**: `chp_broken_review_threads` returns a bare object.

Running `--itp broken --chp broken` must exit non-zero with exactly one FAIL
line per violated clause (proven by `tests/unit/test-provider-conformance-runner.sh`,
which greps the runner's own output — the runner testing itself, same pattern
`test-provider-cutover.sh` uses on `check-provider-cutover.sh`).

## Output contract

```
CONFORMANCE-PCONF <itp>/<chp> <verb> PASS
CONFORMANCE-PCONF <itp>/<chp> <verb> FAIL <reason>
CONFORMANCE-PCONF <itp>/<chp> <verb> SKIP (cap: <name>)
CONFORMANCE-PCONF <itp>/<chp> <verb> PENDING (coverage.conf)
CONFORMANCE-SUMMARY total=N pass=N fail=N skip=N pending=N
```
Non-zero exit on ANY FAIL. `PENDING` lines are informational (never fail the
run by themselves) — they exist so `--itp github --chp github`'s output
visibly enumerates the W1 backlog per R3.

## Docs (R5/R6, same PR)

- `docs/pipeline/provider-spec.md`: add the `CONTRACT-PENDING` token to the
  gh-argv-passthrough verb rows in §3.1/§3.2 (13 rows at #370 landing; #371
  W1a removed 3 and #400 W1e removed 3, leaving 7 as of writing) (R3); add
  the verb→governing-cap table to §4 (R4, mirrors `cap-map.conf`); add a
  per-verb `TC-PCONF-NNN` checklist section (R5).
- `docs/pipeline/invariants.md`: new `INV-106` — "provider conformance is
  spec-defined and regression-pinned by a hermetic parameterized runner" —
  with the `_Triage (issue #236): [machine-checked: tests/unit/test-provider-conformance-runner.sh]_`
  tag within 2 lines, per the #323 convention.
- `docs/test-cases/provider-conformance-runner.md` — `TC-PCONF-NNN` IDs
  covering the four Testing-Requirements scenarios.

## Non-goals (Out of Scope, unchanged)

No WAIVED→LIVE caps wiring; no error-path/pagination fixtures for the 13
`CONTRACT-PENDING` verbs; no `chp_review_threads` pagination-completeness
assertion (shape only); no wrapper/provider-leaf behavior change (this PR adds
tests + a governing-cap DATA file + degraded leaf bodies that fail closed —
`itp-github.sh`/`chp-github.sh` are untouched).
