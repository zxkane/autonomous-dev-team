# Test cases — fail-loud disposition for lib-auth leaf-absent raw-`gh` fallbacks (#346)

The drain-broker tests live in `tests/unit/test-token-split-234.sh` (the `TC-FBDISP-*`
block). R3's already-github-gated interim close stays pinned by
`tests/unit/test-chp-pr-lifecycle.sh` TC-CHP-CAP-MCI0-NONGH (unchanged). Run the full
suite under `env -u PROJECT_DIR` for CI parity.

The two named fake NON-github CHP providers are selected through the PUBLIC seam
(`CODE_HOST=<name>` + `AUTONOMOUS_PROVIDERS_DIR=<fixture dir>`):
- `tests/unit/fixtures/provider-fbdisp-noleaf/chp-fbdispnoleaf.{sh,caps}` —
  `CODE_HOST=fbdispnoleaf`, `review_bots=1`, defines ONLY `chp_fbdispnoleaf_pr_list`
  (so the broker reads resolve); OMITS `create_pr`/`trigger_bot` leaves.
- `tests/unit/fixtures/provider-fbdisp-leaf/chp-fbdispleaf.{sh,caps}` —
  `CODE_HOST=fbdispleaf`, `review_bots=1`, `create_pr`/`trigger_bot` leaves DEFINED
  (they record argv to `CHP_FBDISP_LEAF_LOG`).
- `tests/unit/fixtures/provider-fbdisp-gh-notrigger/chp-github.{sh,caps}` — a
  GitHub-named fixture (`CODE_HOST=github`) that DEFINES `chp_github_pr_list` but
  OMITS `chp_github_trigger_bot`, `review_bots=1`. Drives `TC-FBDISP-004`: the PR
  read resolves while `chp_has_leaf trigger_bot` is false and `CODE_HOST==github`,
  so the raw `else` gh-as-user.sh fallback is the branch exercised.

The env var `CHP_FBDISP_PR_BODY` controls each fixture's canned PR body so one
fixture serves both broker reads (default body does NOT mention `#<issue>` → the
pr-create existence COUNT is 0; set it to mention `#<issue>` for the bot-trigger
PR-NUMBER read).

## AC1 — github topology → byte-identical fallback argv (golden trace)

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-FBDISP-001` | `drain_agent_pr_create` on the DEFAULT **github** seam (`chp_github_create_pr` leaf IS defined → the VERB path forwards to the same `gh pr create` argv the raw fallback would emit), scoping armed, explicit `branch:` line, `gh` stub recording argv | `gh pr create --repo owner/repo --head <branch> --title … --body …` recorded — byte-identical to pre-#346 |
| `TC-FBDISP-002` | `drain_agent_bot_triggers` on the DEFAULT **github** seam (`chp_github_trigger_bot` leaf defined → VERB path forwards to the same argv), scoping armed, allow-listed phrases, `gh-as-user.sh` stub recording posts | each allow-listed trigger posts via `bash "$gh_as_user" pr comment <pr> --repo owner/repo --body <phrase>` — byte-identical to pre-#346 |
| `TC-FBDISP-003` | `drain_agent_pr_create` with the CHP seam ABSENT (no `lib-code-host.sh`/`providers/` beside `lib-auth.sh` → `chp_has_leaf` UNDEFINED, `CODE_HOST` unset), scoping armed, explicit `branch:` line, `gh` stub | the RAW `elif [[ ${CODE_HOST:-github} == github ]]` fallback branch fires byte-identically (`gh pr create --repo owner/repo --head <branch> …`) — the lib-load-failure degraded path the `:-github` default protects. This is the branch TC-FBDISP-001 does NOT reach (it takes the verb path). |
| `TC-FBDISP-004` | `drain_agent_bot_triggers` with the CHP seam ABSENT (`chp_has_leaf` undefined, `CODE_HOST` unset), scoping armed, allow-listed phrase, `gh-as-user.sh` stub | the RAW `else` `gh-as-user.sh pr comment … --body <phrase>` fallback fires byte-identically — the degraded path complement of `-003`. |

## AC2 — non-github + leaf-absent → loud error, zero raw `gh`/`gh-as-user` (tripwire)

Tripwire pattern from TC-RRC-021: a `gh` stub (and `gh-as-user.sh` stub) that writes a
sentinel on ANY invocation; the assertion is the sentinel file stays empty.

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-FBDISP-010` | `drain_agent_pr_create`, `CODE_HOST=fbdispnoleaf` + `AUTONOMOUS_PROVIDERS_DIR=provider-fbdisp-noleaf` (no `chp_fbdispnoleaf_create_pr` leaf), scoping armed, valid broker file, tripwire `gh` stub | broker emits a loud `[INV-79]/[INV-91]` ERROR naming the non-github backend; **NO `gh pr create` executed** (tripwire sentinel empty); returns 0 (fail-safe broker contract) |
| `TC-FBDISP-011` | `drain_agent_bot_triggers`, `CODE_HOST=fbdispnoleaf` (no `chp_fbdispnoleaf_trigger_bot` leaf, `review_bots=1` so the earlier review_bots gate does not short-circuit first, `CHP_FBDISP_PR_BODY` mentions `#346` so the PR-number read resolves), scoping armed, allow-listed phrases, tripwire `gh-as-user.sh` stub | broker emits a loud `[INV-79]/[INV-91]` ERROR; **NO `gh-as-user.sh` post executed** (tripwire sentinel empty); returns 0 |

## AC2 (verb-present) — non-github + leaf-present → verb path taken

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-FBDISP-020` | `drain_agent_pr_create`, `CODE_HOST=fbdispleaf` + `provider-fbdisp-leaf` (`chp_fbdispleaf_create_pr` DEFINED, records argv), scoping armed, valid broker file | the **verb** path is taken (`chp_create_pr --head … --title … --body …`); NO raw `gh pr create` executed |
| `TC-FBDISP-021` | `drain_agent_bot_triggers`, `CODE_HOST=fbdispleaf` (`chp_fbdispleaf_trigger_bot` DEFINED, records argv, `review_bots=1`, `CHP_FBDISP_PR_BODY` mentions `#346`), scoping armed, allow-listed phrase | the **verb** path is taken (`chp_trigger_bot <pr> <phrase>`); NO raw `gh-as-user.sh` post executed |

## AC1 — regression: existing github/github behavior preserved

Covered by the sibling `TC-TOKEN-SPLIT-070`/`-095`/`-097` drain tests running in the
SAME `test-token-split-234.sh` file (69+ PASS / 0 FAIL) — the guard is a no-op on the
github topology they exercise. No separate assertion ID is minted for this.

## AC3 — spec-drift / cutover baseline

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-FBDISP-041` | source-shape: `drain_agent_pr_create` gates the raw `gh pr create` under `${CODE_HOST:-github}" == "github"`; both loud-error strings present; the raw `gh pr create` line byte-identical to the baselined content | all four `grep -qF` source anchors present |

The cutover-baseline pin (the `lib-auth.sh` `_pr_create_ok() { gh pr create …}`
signature count is unchanged; `check-provider-cutover.sh --require-trusted-ref`
green — baseline neither grows nor shrinks) is asserted by
`tests/unit/test-provider-cutover.sh` (which drives the guard in strict mode), not a
separate TC-FBDISP id.

## R3 (documentation-only) — already pinned, no new test

`autonomous-review.sh` interim close is already github-gated + pinned by
`test-chp-pr-lifecycle.sh` TC-CHP-CAP-MCI0-NONGH (verb absent + non-github → loud
`TRANSITION_ERROR`, no wrong `gh issue close`). No code change and no new test; R3 is
a provider-spec / INV-91 documentation disposition only.

## AC-suite

Full existing unit suite green under `env -u PROJECT_DIR` (no regression to the
sibling drain / baseline-pin / source-shape tests).
