# Test Cases — Provider dispatch skeleton + `.caps` reader (#280)

Test IDs: `TC-PROVIDER-DISPATCH-NNN`. Lives in
[`tests/unit/test-provider-dispatch.sh`](../../tests/unit/test-provider-dispatch.sh),
mirroring `tests/unit/test-cli-adapters.sh`. Discovered by CI via the
`tests/unit/test-*.sh` glob.

The feature **originally shipped (#280) as pure-additive plumbing with zero
behavior change** — the suite proved the *plumbing exists and routes/parses
correctly* without pinning any `gh` argv, since no leaf was migrated yet. Every
leaf has since been migrated by its own downstream PR (#281–#284, #296
second-tier); the TC-020..022 block below has been superseded to assert the
migrated state (see that section for the current contract).

## Dispatch routing (spec §3.1/§3.2, [INV-87])

The verb counts below are the CURRENT shipped counts (post #281–#330), not the
12/14 counts #280 originally shipped with a smaller shim set. §3.1/§3.2 of
`provider-spec.md` are the normative source; cite the table there, not a
literal number, when in doubt.

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-DISPATCH-001 | Source `lib-issue-provider.sh`; `declare -F` each of the 14 ITP verbs (incl. `itp_label_event_ts`, #323) | all 14 defined |
| TC-PROVIDER-DISPATCH-002 | Source `lib-code-host.sh`; `declare -F` each of the 19 CHP verbs (18 §3.2 table rows; the `chp_review_threads`/`chp_resolve_thread` row names two) | all 19 defined |
| TC-PROVIDER-DISPATCH-003 | Default-resolution: `ISSUE_PROVIDER`/`CODE_HOST` unset → stub `itp_github_*`/`chp_github_*` echo a sentinel; call `itp_<verb>`/`chp_<verb>` | sentinel returned (routed to `…_github_<verb>`) |
| TC-PROVIDER-DISPATCH-004 | Each ITP shim body forwards to `itp_${ISSUE_PROVIDER}_<verb> "$@"`; each CHP shim to `chp_${CODE_HOST}_<verb> "$@"` | grep of lib bodies confirms the forward literal per verb |
| TC-PROVIDER-DISPATCH-005 | `"$@"` passthrough: stub echoes its args; call shim with multiple args | args forwarded verbatim |
| TC-PROVIDER-DISPATCH-006 | Both libs resolve `providers/<p>.sh` via `readlink -f` of own `BASH_SOURCE` (not `${BASH_SOURCE%/*}`) | grep for `readlink -f` in each lib |

## `.caps` reader (spec §4/§4.1/§4.2, [INV-88], parsed-never-sourced)

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-DISPATCH-010 | `itp_caps marker_channel` against `itp-github.caps` | `html` |
| TC-PROVIDER-DISPATCH-011 | `itp_caps server_side_state_negation` | `0` |
| TC-PROVIDER-DISPATCH-012 | `chp_caps native_issue_pr_link` | `0` |
| TC-PROVIDER-DISPATCH-013 | `chp_caps merge_closes_issue` | `1` |
| TC-PROVIDER-DISPATCH-014 | reader on an **unknown key** | non-zero rc, no stdout (graceful) |
| TC-PROVIDER-DISPATCH-015 | reader ignores `#` comments + blank lines | value parsed past comments/blanks |
| TC-PROVIDER-DISPATCH-016 | parsed-never-sourced guard: grep the reader for `source`/`.` of the `.caps` path | absent; a `while IFS= read` / key= parse loop present |
| TC-PROVIDER-DISPATCH-017 | `itp-github.caps` contains EXACTLY the 9 documented keys/values (§4 block) | literal match each |
| TC-PROVIDER-DISPATCH-018 | `chp-github.caps` contains EXACTLY the 4 documented keys/values | literal match each |

## GitHub leaves are DEFINED — READ (#281) + WRITE (#283) + DEP (#284) + ALL CHP (#282) migrated

Supersedes the original #280 "scaffolds are EMPTY" scope guard: every leaf named
in provider-spec.md §3.1/§3.2 has since been migrated by its own downstream PR.

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-DISPATCH-020 | Source `providers/itp-github.sh`; `declare -F` the migrated READ (#281, e.g. `itp_github_list_comments`), WRITE (#283, e.g. `itp_github_transition_state`), and DEP/tick-lifecycle (#284, `itp_github_resolve_dep`/`itp_github_begin_tick`) leaves | all DEFINED (no scaffolds remain) |
| TC-PROVIDER-DISPATCH-021 | Source `providers/chp-github.sh`; `declare -F chp_github_create_pr` (#282) | DEFINED |
| TC-PROVIDER-DISPATCH-022 | `bash -n` each `providers/*.sh` | source-clean, no syntax error |

## Capability-branch via the fake fixture provider (provider-spec.md §8 fake-provider; design-spec §7.4)

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-DISPATCH-030 | Select the fake provider **through the public seam** — `ISSUE_PROVIDER=degraded` / `CODE_HOST=degraded` + `AUTONOMOUS_PROVIDERS_DIR=<fixture>` — then call `itp_caps`/`chp_caps` for every gated key | every gated cap reports its `caps=0` / `text` value via the public verbs (real provider-selection path), proving each `caps=0` branch is reachable now — the reusable harness downstream caps-branch tests build on (#280 review [P1]) |
| TC-PROVIDER-DISPATCH-031 | Override semantics: (a) `ISSUE_PROVIDER=degraded` with NO `AUTONOMOUS_PROVIDERS_DIR` → `itp_caps` rc 1 (provider not on resolution path); (b) `AUTONOMOUS_PROVIDERS_DIR=<skill-tree providers/>` + `github` → `marker_channel=html` (default path unchanged) | (a) rc 1; (b) `html` — provider resolution is the seam, override defaults to the skill tree |

## Fixture-rule regression ([INV-65], §6 `cp -r providers/`)

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-DISPATCH-040 | Build a fake skill tree (the existing `cp -r adapters/` pattern) that ALSO `cp -r providers/`; source `lib-issue-provider.sh`/`lib-code-host.sh` from the fixture tree | both libs resolve their provider files from the fixture tree via `readlink -f`; `itp_caps`/`chp_caps` read the fixture `.caps` |
| TC-PROVIDER-DISPATCH-041 | `test-entry-point-startup-e2e.sh` fixture now copies `providers/` alongside `adapters/` | the entry-point startup E2E still reaches the post-startup line (no missing-provider crash) |

## Derive-from-spec reconciliation (#367 R2 — the anti-drift gate)

Both the ITP_VERBS/CHP_VERBS arrays in this suite AND the shipped-shim sets are
now DERIVED (from `provider-spec.md` §3.1/§3.2 and from `lib-issue-provider.sh`/
`lib-code-host.sh` respectively) rather than hardcoded literals, so a future mint
self-pins: a new shim minted WITHOUT a matching spec row, or a new spec row
minted WITHOUT a shipped shim, turns the reconciliation red instead of silently
falling out of coverage.

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-DISPATCH-050 | Spec-derived ITP verb set (§3.1) == shipped `lib-issue-provider.sh` shim set (ITP has no guard-helper function to exclude) | equal, same count |
| TC-PROVIDER-DISPATCH-051 | Spec-derived CHP verb set (§3.2) == shipped `lib-code-host.sh` shim set (`chp_has_leaf` excluded — a guard helper, not a verb) | equal, same count |
| TC-PROVIDER-DISPATCH-052 | **Automated negative proof (AC1):** append a fake shim (`chp_frobnicate_unlisted`) to a SCRATCH COPY of `lib-code-host.sh` (never the committed tree, mirrors `test-provider-cutover.sh::fresh_scratch`); re-run the TC-051 reconciliation against the scratch copy | reconciliation turns RED, naming the unlisted shim — demonstrates the derive-from-spec assertion actually catches drift, not just a passing tautology |

## Zero-behavior-change proof (provider-spec.md §7.2 clause 1)

Not a case in `test-provider-dispatch.sh` — a CI-suite expectation: the full
existing `tests/unit/test-*.sh` glob + the conformance suite MUST pass unchanged
(file count not reduced). For #280's *original* dispatch-skeleton scope this was
necessary-but-sufficient because no caller was rewired yet (provider-spec.md
§7.2 clause 1); the leaf-migration siblings (#281–#330) that DID rewire callers
carry their own golden-trace / dispatch-routing proofs (`test-itp-read-leaves.sh`,
`test-itp-write-leaves.sh`, `test-chp-pr-lifecycle.sh`, and the others cited in
the TC-020..022 section above) — this suite still gates only the plumbing.

| ID | Scenario | Expected |
|---|---|---|
| (CI-suite) | Run the full existing `tests/unit/test-*.sh` suite + the conformance suite | passes unchanged (file count not reduced) |
