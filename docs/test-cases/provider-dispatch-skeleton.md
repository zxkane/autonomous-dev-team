# Test Cases — Provider dispatch skeleton + `.caps` reader (#280)

Test IDs: `TC-PROVIDER-DISPATCH-NNN`. Lives in
[`tests/unit/test-provider-dispatch.sh`](../../tests/unit/test-provider-dispatch.sh),
mirroring `tests/unit/test-cli-adapters.sh`. Discovered by CI via the
`tests/unit/test-*.sh` glob.

The feature is **pure-additive plumbing with zero behavior change**, so the
suite proves the *plumbing exists and routes/parses correctly* — it does NOT
pin any `gh` argv (no leaf is migrated; golden-trace is downstream).

## Dispatch routing (spec §3.1/§3.2, [INV-87])

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-DISPATCH-001 | Source `lib-issue-provider.sh`; `declare -F` each of the 14 ITP verbs (incl. `itp_label_event_ts`, #323) | all 14 defined |
| TC-PROVIDER-DISPATCH-002 | Source `lib-code-host.sh`; `declare -F` each of the 12 CHP verbs | all 12 defined |
| TC-PROVIDER-DISPATCH-003 | Default-resolution: `ISSUE_PROVIDER`/`CODE_HOST` unset → stub `itp_github_*`/`chp_github_*` echo a sentinel; call `itp_<verb>`/`chp_<verb>` | sentinel returned (routed to `…_github_<verb>`) |
| TC-PROVIDER-DISPATCH-004 | Each ITP shim body forwards to `itp_${ISSUE_PROVIDER}_<verb> "$@"`; each CHP shim to `chp_${CODE_HOST}_<verb> "$@"` | grep of lib bodies confirms the forward literal per verb |
| TC-PROVIDER-DISPATCH-005 | `"$@"` passthrough: stub echoes its args; call shim with multiple args | args forwarded verbatim |
| TC-PROVIDER-DISPATCH-006 | Both libs resolve `providers/<p>.sh` via `readlink -f` of own `BASH_SOURCE` (not `${BASH_SOURCE%/*}`) | grep for `readlink -f` in each lib |

## `.caps` reader (spec §4/§4.1/§4.2, [INV-88], §10 Q1 parsed-never-sourced)

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

## GitHub scaffolds are EMPTY of verb bodies (scope guard)

| ID | Scenario | Expected |
|---|---|---|
| TC-PROVIDER-DISPATCH-020 | Source `providers/itp-github.sh`; `declare -F itp_github_list_by_state` | returns 1 (no verb body shipped — leaf migration downstream) |
| TC-PROVIDER-DISPATCH-021 | Source `providers/chp-github.sh`; `declare -F chp_github_create_pr` | returns 1 |
| TC-PROVIDER-DISPATCH-022 | `bash -n` each `providers/*.sh` scaffold | source-clean, no syntax error |

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

## Explicit NON-tests (documented so a reviewer does not reject the PR)

- **No golden-trace test** — no verb leaf carries a real `gh` argv in this PR
  (spec §7.2). Golden-trace lands in itp-reads / itp-writes / chp-pr-lifecycle /
  entangled-orchestrators-golden-trace.
- **No caller-branch test** — no caller is rewired here; the fixture + reader
  the future caller branches consume IS tested (TC-030), the branches themselves
  are downstream.

## Zero-behavior-change proof (provider-spec.md §7.2 clause 1)

Not a case in `test-provider-dispatch.sh` — a CI-suite expectation: the full
existing `tests/unit/test-*.sh` glob + the conformance suite MUST pass unchanged
(file count not reduced). It is necessary-but-sufficient here precisely because
no caller is rewired (provider-spec.md §7.2 clause 1).

| ID | Scenario | Expected |
|---|---|---|
| (CI-suite) | Run the full existing `tests/unit/test-*.sh` suite + the conformance suite | passes unchanged (file count not reduced) — necessary-but-sufficient here because no caller is rewired |
