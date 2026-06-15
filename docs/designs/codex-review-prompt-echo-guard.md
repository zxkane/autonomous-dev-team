# Design: codex review prompt-echo / startup-trace stdout is misclassified as a blocking `[P1]` FAIL (INV-73, #252)

## Problem

`codex review` (the subcommand path added in #218, [INV-62](../pipeline/invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback))
sometimes exits **rc 0** but writes its **own prompt + CLI startup trace** to stdout instead of a review:
the codex startup banner (`OpenAI Codex vX.Y.Z` / `workdir:` / `model:` / `provider:` / `approval:` / `sandbox:`)
followed by the verbatim review prompt (the inlined decision-gate rules, the `gh issue view` comment-history
dump, the issue body), with no analysis and no verdict — truncated at the wrapper's char cap.

Two existing helpers in `lib-review-codex.sh` then mishandle that echo:

1. `_codex_review_classify_stdout` runs `grep -qF '[P1]'` over the **entire** captured stdout. The review
   prompt itself contains `[P1]` (the instruction "Prefix EACH blocking finding with `[P1]`", plus quoted
   prior-round findings in the comment-history dump). So an echoed prompt **always** matches → a false
   **FAIL**.
2. `_codex_review_compose_body` then caps that same stdout at 50000 chars and posts it verbatim as the
   `Review findings:` body — a 700+-line dump of the prompt/trace with zero actual findings.

Because the CLI **exited 0** ("succeeded", just produced garbage), none of the existing failure paths catch
it: #209 (`turn.failed` / 5xx stream-error → retry) keys on a non-zero/stream-error exit; #246 (smoke rc
124/137 → UNAVAILABLE) keys on timeout; #247/INV-69 (post-failed breadcrumb) keys on a failed `gh` post; #223
(`config-error`) keys on the clap exit-2. This is a distinct **fourth** failure mode: **clean exit (rc 0),
well-formed-looking-but-bogus stdout.** Under the [INV-40](../pipeline/invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)
unanimous-PASS gate, that single phantom FAIL vetoes an otherwise-clean PR on every round, producing a
non-self-terminating dev↔review loop.

Observed in the wild 3× across one PR's review rounds (codex CLI `0.139.0`, model `openai.gpt-5.4`, provider
`amazon-bedrock`) on a consumer project's PR — the PR was independently PASSED twice by `claude` on the same
HEAD, CI-green and `MERGEABLE`, yet repeatedly bounced back to dev solely by these malformed codex verdicts.

## Goal

A `codex review` stdout that is **prompt-echo / startup-trace rather than a real review** is detected as
**malformed** and is NOT classified as a blocking `[P1]` FAIL. A malformed output is **retried** (the existing
bounded re-run, since `codex review` is stateless and re-reads the diff each invocation — same precedent as
the #209 stream-error re-run); if it stays malformed after the retry budget, codex is dropped `unavailable`
with a specific drop reason (`malformed-output (prompt-echo/trace, no verdict)`), contributing no INV-40 vote.
A genuine codex review with real `[P1]` findings still FAILs; a genuine review with no `[P1]` still PASSes.
No happy-path change.

## Approach (minimum viable, fits the existing INV-62 shape)

This is a targeted near-term guard. It does NOT depend on the #233 verdict-artifact channel (which would
subsume it by moving verdicts off stdout-scraping entirely). It mirrors the per-CLI drop-reason scrapers
already established for agy (INV-58), codex stream-error (INV-59/62), codex config-error (#223), kiro
(INV-61), and post-failed (INV-69).

### 1. New malformed-stdout detector — `_codex_review_stdout_is_malformed <stdout-file>`

Returns rc 0 iff the capture is prompt-echo / startup-trace, NOT a real review. Three cheap, robust signals
(ANY one sufficient — defense in depth, none alone has to be perfect):

- **Banner/header signal.** The codex startup banner (`^OpenAI Codex v…`) is the capture's **first non-empty
  line**, OR a `workdir:` + `model:` + `provider:` triple appears within the **contiguous leading header
  region** (the run of lines from the top up to the first blank / ``` fence / `## ` heading / `[P1]` finding
  line). Keyed on the ACTUAL launch-trace structure, not the strings appearing anywhere near the top: a real
  `codex review` writes review text first, so a banner/header a genuine review *quotes* in a fenced block
  sits after review prose (outside the leading region, never the first non-empty line) and does NOT match.
  This is the PR #253 2nd-round review finding [P1] correction: an earlier `head -n 12` scan dropped a
  genuine `[P1]` review that quoted the banner/header fixture in a code block near the top.
- **Prompt-echo signal (≥2 markers in the echo region).** The capture reproduces the wrapper's own prompt
  SCAFFOLDING VERBATIM at the TOP as bare structure; a real review writes findings and at most *quotes*
  prompt text inside ``` fences or after its findings. So this signal requires **≥2 distinct** prompt
  markers — the `## Step 0:` / `## Step 0.5:` `MANDATORY PRE-REVIEW` headings (counted separately), the
  `## You are running inside codex review` header, the `## Review Checklist` / `## Review Process` /
  `## Acceptance Criteria Verification` headings, the `Prefix EACH blocking finding` instruction line, or
  the `You are reviewing PR #…` opener — counted **only in the echo region**: the capture with fenced code
  blocks STRIPPED and truncated at the first **finding-boundary** line (`_echo_region`). The finding boundary
  (shared with the leading-header region) recognizes numbered / markdown-list / bold / JSON finding forms
  (`1. **[P1] …`, `- [P1]`, `"severity":"P1"`) — NOT just a bare leading `[P1]`, and NOT the prompt's
  `Prefix EACH blocking finding with [P1]` instruction. Three `[P1]` findings drove this: **PR #253 1st-round**
  (a bare single-marker substring match dropped a review quoting ONE marker → require ≥2); **#252 3rd-round,
  session fdc9ff60** (≥2 markers *anywhere* still dropped a review that QUOTED two prompt headings in a fenced
  code block → ignore fenced quotes + markers that trail a finding); **#252 4th-round, session 6000c69c** (the
  boundary missed the wrapper's own NUMBERED+BOLD finding format `1. **[P1] …` → widen it to
  numbered/markdown/JSON forms). The boundary is inlined as literal awk regexes — passing it via `awk -v`
  mangles the `\[`/`\]` backslashes.
- **Truncated-no-verdict signal.** The capture is at/near the wrapper's char cap AND contains no recognizable
  verdict structure (no `Review PASSED` / `Review findings:` / a `Summary:` / `Findings` heading the gate
  rules ask for) **AND no genuine finding boundary** (a real `[P1]`/numbered/bullet/JSON finding) — i.e. it
  was cut mid-dump with neither a conclusion nor a finding. The finding-boundary exemption is the **#252
  5th-round finding-2 [P1]** fix: a genuine LONG review carrying numbered/bold `[P1]` findings but none of
  those exact headings is a real review (it falls through to the `[P1]` scan and FAILs), not a truncated dump.

Fail-safe: empty / missing / unreadable / short capture → NOT malformed (rc 1), so a normal review is never
mis-flagged. rc 0/1 only; never aborts under `set -euo pipefail`. The signal helpers are individually
unit-tested.

> **Conservative direction.** `_codex_review_classify_stdout`'s existing comment notes the `[P1]` scan is
> deliberately conservative ("a false FAIL only re-queues the PR to dev") — but that reasoning assumed the
> stdout is a real review. The malformed detector must therefore be tuned to fire ONLY on clear
> echo/trace shapes; a real review that merely *mentions* the banner words or quotes an instruction must NOT
> be flagged. The signals key on structure (banner-at-top, prompt scaffolding, truncated-no-verdict), not on
> a bare keyword anywhere.

### 2. Classification ordering — `_codex_review_classify_stdout` gains a `malformed` token

The classifier echoes one of `pass | fail | malformed`. The malformed check runs **FIRST**, BEFORE the `[P1]`
scan, so a `[P1]` quoted inside an echoed prompt / comment-history dump can never produce a verdict:

```
malformed?  → echo malformed   (no [P1] scan, no body composed from it)
[P1] present → echo fail
otherwise    → echo pass
```

rc 0 always (fail-safe). Existing pass/fail behavior is unchanged for non-malformed captures.

### 3. The wrapper's stdout-fallback treats `malformed` as "no verdict → re-run / drop"

In `autonomous-review.sh`'s INV-62 stdout-fallback block (already gated on rc 0): if the classifier returns
`malformed`, the wrapper does NOT compose a `Review findings:` body and does NOT post a verdict — it leaves
the agent UNRESOLVED for the terminal sweep, which resolves it `unavailable` (no vote). The existing bounded
re-run in `_run_codex_review` already retries a malformed-shaped output — BUT the existing re-run keys on a
non-zero rc, and a prompt-echo exits rc 0. So `_run_codex_review` gains a malformed check on a clean (rc 0)
run: a malformed rc-0 capture is treated like a transient failure and RE-RUN (a fresh `codex review`,
stateless, may produce a real review), bounded by the SAME `CODEX_REVIEW_MAX_RERUNS` + wall-clock deadline.
After the budget is exhausted while still malformed, the run is reported as a non-verdict (the existing
fallback's rc-0 gate + the classifier's `malformed` token together leave codex unresolved → `unavailable`).

> **Why retry at rc 0.** The issue explicitly asks for a bounded re-run (the prompt is stateless, so a fresh
> invocation may produce a real review — same precedent as #209). Implementing the malformed retry inside the
> existing `_run_codex_review` loop reuses the bound + deadline + the duplicate-verdict / timeout-veto
> guards already proven there, rather than adding a second loop.

### 4. Distinct drop reason — `_classify_codex_drop_reason` gains a `malformed-output` bucket

In the drop-classification loop, a dropped (`unavailable`) codex member whose rc-0 capture is malformed (and
is NOT a clap config-error and NOT a stream-error) classifies to `malformed-output`. Checked AFTER
`config-error` (rc-2 gated) and the stream-error scan — those are more specific (a clap error or a 5xx
disconnect is a different cause). `_codex_drop_reason_phrase` renders it as
`malformed-output (codex review echoed its prompt/startup trace instead of a review — no verdict; retried, still malformed)`.

Observability only — a `malformed-output` codex stays a dropped `unavailable`, NEVER a deciding FAIL (exactly
the INV-40 "absent ⇒ not a deciding vote" semantics the issue calls for). `_classify_noverdict_agent` /
`_aggregate_review_verdicts` untouched.

### 5. The all-unavailable terminal path routes a `malformed-output` drop NON-substantive (#252 5th-round [P1] #1)

A malformed prompt-echo exits **rc 0**. The terminal all-unavailable branch keys `AGENT_EXIT` on launch rc
(rc 0 → `failed-substantive`, rc ≠ 0 → `failed-non-substantive`). So in a single-agent codex fleet, a
malformed codex left unresolved at rc 0 would route through the rc-0 `failed-substantive` branch — turning
the no-vote infra drop back into a blocking request-changes FAIL (the exact non-self-terminating loop a
single-agent-codex repo hit). Fix: the drop-classification loop sets `_any_nonsubstantive_drop=true` when a
dropped agent's reason is `malformed-output`, and the all-unavailable branch raises `AGENT_EXIT=1` on that
flag → `failed-non-substantive` (re-dispatchable), the same terminal class as a non-zero `stream-error` drop.
`stream-error`/`config-error`/`auth-failed`/`quota-exhausted` already exit non-zero (the rc scan routes them
non-substantive); only the rc-0 `malformed-output` case needed the explicit flag.

## Decision Gate ordering rationale

The classifier ordering (`malformed` before `[P1]`) and the drop-reason ordering (`config-error` rc-2 → then
`stream-error` → then `malformed-output`) are the load-bearing decisions:

- **Classifier — `malformed` first.** The whole bug is that a `[P1]` inside an echoed prompt produces a
  phantom FAIL. Scanning for `[P1]` only AFTER ruling out a malformed shape is the fix.
- **Drop reason — `malformed-output` last among the codex buckets.** `config-error` (rc 2) and `stream-error`
  (5xx disconnect) are MORE specific causes with their own clear signatures; a rc-0 prompt-echo is neither,
  so it is the residual bucket. It does not shadow them, and a clean review (no echo, no stream error, no
  clap) still yields empty (bare `unavailable`) — no over-claim.

## Files

| File | Change |
|---|---|
| `skills/autonomous-dispatcher/scripts/lib-review-codex.sh` | New `_codex_review_stdout_is_malformed` + signal sub-helpers; `_codex_review_classify_stdout` gains the `malformed` token (checked first); `_run_codex_review` re-runs a malformed rc-0 capture (bounded); `_classify_codex_drop_reason` gains the `malformed-output` bucket; `_codex_drop_reason_phrase` renders it. |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | The INV-62 stdout-fallback block treats `malformed` as no-verdict (no body composed, no post → unresolved → `unavailable`). |
| `tests/unit/test-lib-review-codex.sh` | New `TC-CXRS-MAL-*` block: classifier malformed-first, each signal independently, the rc-0 malformed re-run state machine, the drop-reason bucket + phrase, fail-safe, and the INT behavioral fallback (malformed → NOPOST → unresolved). Plus regression guards that a genuine `[P1]` still FAILs and a clean review still PASSes. |
| `tests/unit/fixtures/codex-review-stdout-prompt-echo.txt` | New fixture: banner + echoed prompt with `[P1]` present only as quoted instruction text, no verdict, truncated. |
| `tests/e2e/*` | Extend the stub-fleet test driving `autonomous-review.sh` with a stubbed codex whose stdout is the prompt-echo shape; assert no phantom FAIL, the rendered drop reason names `malformed-output`, and the aggregate is decided by the surviving agents. |
| `docs/pipeline/invariants.md` | New **INV-73** entry. |
| `docs/pipeline/review-agent-flow.md` | New `### codex malformed-output (prompt-echo) drop reason (INV-73)` section under the codex drop-reason walkthroughs. |
| `docs/test-cases/codex-review-prompt-echo.md` | Test-case document (TC-CXRS-MAL-NNN). |

## Pipeline Documentation Authority

This PR touches the review wrapper (`autonomous-review.sh`) and its codex review lib (`lib-review-codex.sh`),
so per [CLAUDE.md → Pipeline Documentation Authority] it adds a new `INV-73` entry to `invariants.md` and a
matching `review-agent-flow.md` section in the SAME PR. No state-machine transition changes (the malformed
codex still terminally resolves `unavailable`, a state already in the diagram).

## Post-install / upgrade

This PR EDITS existing files (`lib-review-codex.sh`, `autonomous-review.sh`) — it does NOT add or remove a
dispatcher script / `lib-*.sh`. No new `source` target is introduced, so the per-project
`install-project-hooks.sh` re-run is NOT required after merge; `npx skills update -g` alone refreshes the
user-scope copy (the existing per-file symlinks already resolve to the updated content).
