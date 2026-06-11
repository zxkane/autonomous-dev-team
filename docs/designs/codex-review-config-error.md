# Design: codex review deterministic argv rejection → `config-error`, not retried-then-`unavailable` (INV-62, #223)

## Problem

INV-62 (#218) moved the codex review lane to the purpose-built `codex review
"<prompt>"` subcommand but kept the exec-era extra-args contract intact:
`_codex_review_argv` (`lib-review-codex.sh`) splices the resolved per-agent
extra-args **verbatim** into the `codex review` argv. `codex review` accepts only
`-c/--config`, `--base`, `--commit`, `--uncommitted`, `--title`, `--enable`,
`--disable` (verified 0.137.0); anything else is an **exit-2 clap parse error**.

An operator carrying a pre-#218 `codex exec`-era sandbox flag — e.g.
`AGENT_REVIEW_EXTRA_ARGS_CODEX="-s danger-full-access"`, which was valid and
**needed** on the old `codex exec` lane (it defaults to a read-only sandbox) —
now poisons the `codex review` argv:

```
codex review "any prompt" -c 'model="<model>"' -s danger-full-access
# error: unexpected argument '-s' found
# Usage: codex review [OPTIONS] [PROMPT]
# exit code 2
```

The INV-62 re-run controller (`_run_codex_review`, sub-rule 2) treats **every**
non-zero, non-124/137 exit as a transient stream blip (#209's framing) and
re-runs the **identical** argv to `CODEX_REVIEW_MAX_RERUNS` exhaustion — a
deterministic argv rejection can never succeed, so all re-runs fail identically.
The wrapper then drops codex as a bare `unavailable`:

- `_run_codex_review` logs `… likely a transient stream error / turn.failed;
  re-running a fresh review …` (`lib-review-codex.sh:419`) — misleading framing
  that sends the operator chasing upstream/network issues instead of their conf.
- the drop-reason scan (`_classify_codex_drop_reason`) has only a
  `stream-error[:N/M]` bucket; a clap usage block matches nothing, so the agent
  resolves as a bare `unavailable` with **no actionable reason** naming the flag.

The fleet then silently degrades to the surviving members on every fan-out until
someone reads the raw stdout capture (`error: unexpected argument '-s' found`).

## Approach

A deterministic argv rejection must be recognized on the **first** run:

1. **Classify before retrying — gated on rc 2** (`_run_codex_review`). On a run
   that exits **rc 2** (clap's parse-error exit code), scan the stdout capture for
   the clap usage signature (`error: unexpected argument '<flag>' found` /
   `error: invalid value … for`) **before** deciding to re-run. On a match: skip
   the remaining re-runs (re-running identical argv can never succeed) and break
   the loop. The rc still propagates (a non-zero, non-timeout rc → `unavailable`
   via the sweep), so the INV-40 vote is unchanged — this is **observability +
   retry-economy**, not a vote change.

   > **rc-2 gate (PR #225 review finding [P1]).** The capture scan alone is not a
   > sufficient discriminator. A genuine transient failure (e.g. rc 1) whose stdout
   > merely **prints or quotes** `error: unexpected argument '-s' found` — codex
   > echoing a reviewed-diff hunk, or a transport blip after partial output — would
   > otherwise be misread as a deterministic config-error and skip the configured
   > re-runs. So the early-break (and the drop-reason classification in step 2)
   > requires the clap **exit code rc 2** in addition to the capture signature.
   > Every other non-zero rc takes the bounded re-run path (#209) and, if it stays
   > dropped, is classified as the transient it is (`stream-error` / bare).

2. **`config-error` drop-reason bucket — gated on rc 2** (`_classify_codex_drop_reason`
   / `_codex_drop_reason_phrase`). `_classify_codex_drop_reason` takes the agent's
   launch rc as an optional 2nd arg; a clap-rejection capture classifies to a
   distinct `config-error:<flag>` token **only when that rc is 2** (a non-2 rc falls
   through to the stream-error scan, so a transient drop that merely quoted the clap
   string is named for its true cause). The token is rendered as
   `config-error: codex review rejected '-s' (exec-only flag in extra-args)` in
   the WARN line and the posted dropped-agent comment — so the operator sees the
   rejected flag, not a bare opaque `unavailable`. The wrapper threads
   `AGENT_LAUNCH_RC[<sid>]` into the call.

The two changes share one helper (`_codex_review_argv_rejection_flag`) so the
loop and the drop-reason path agree on what "a clap rejection" is and which flag
was rejected.

### Decision: classify, don't filter

The issue offered an optional second fix — **filter/WARN** known exec-only flags
(`-s`, `--sandbox`, `--full-auto`) out of `_codex_review_argv`. We do **not** do
that:

- Filtering is "magical" — it silently mutates an operator-supplied argv, which
  can mask a genuine misconfiguration and is one more list to keep in sync with
  the CLI. The issue explicitly says "If filtering is considered too magical, the
  config-error classification alone fixes the diagnosability."
- The argv stays a faithful passthrough (`_codex_review_argv` is unchanged): the
  rejection is caught **at runtime** from the CLI's own error and surfaced with
  the exact rejected flag. This is the simpler, more maintainable option (the
  autonomous-mode decision-guideline default).

The operator-side remedy is the INV-41 single-space idiom:
`AGENT_REVIEW_EXTRA_ARGS_CODEX=" "` (clear the poison value), documented in the
migration note.

### Why a non-zero rc still resolves `unavailable` (not a deciding FAIL)

A config error is an **operator-conf** condition, not a code rejection — exactly
like the `stream-error` (infra 5xx) and `kiro auth-failed` (expired token) drop
reasons (INV-58/59/61). So `_classify_noverdict_agent` / `_aggregate_review_verdicts`
are untouched: a `config-error` codex stays a dropped `unavailable`, never a
deciding FAIL (it must not block a merge). This is **observability only** — it
changes the WARN/comment wording and the retry economy, nothing in the vote.

## Detection signature

`codex review`'s clap parse error prints, to stderr (folded into the stdout
capture via `2>&1`):

```
error: unexpected argument '-s' found
  ...
Usage: codex review [OPTIONS] [PROMPT]
```

or, for a value error:

```
error: invalid value 'x' for '--enable <CHECK>'
```

The detector matches either `error: unexpected argument '<flag>' found` or
`error: invalid value … for '<flag>'` (case-insensitive). The flag captured is
the first quoted token after `unexpected argument` (or the option name after
`for`). The detector requires the `error:` line — a clean review that merely
prints the words "unexpected argument" in prose does not match (the leading
`error:` + clap grammar is the discriminator).

`codex review`'s clap parser exits **rc 2** on a parse error (clap's standard
usage-error exit code). The detector's match is only TRUSTED when the run also
exited rc 2 (see the rc-2 gate above): the text signature + the exit code
together identify a real parse rejection, so a non-rc-2 run whose capture merely
quotes the string is never short-circuited.

### Precedence vs `stream-error`

A capture is checked for `config-error` **before** `stream-error`, and only when
the run exited rc 2. A clap parse error fails *before* any model stream opens, so
the two never co-occur in a real capture; ordering config-error first is
defensive (a deterministic argv rejection is the more actionable signal, and
re-running it is always pointless). At a non-2 rc the config-error branch is
skipped entirely, so a transient rc-1 failure that streamed a reconnect ladder
AND happened to quote the clap string is correctly classified `stream-error`.

## Files touched

| File | Change |
|---|---|
| `skills/autonomous-dispatcher/scripts/lib-review-codex.sh` | add `_codex_review_argv_rejection_flag` (clap-signature detector → echoes rejected flag); call it in `_run_codex_review`'s loop to skip re-runs on a deterministic rejection; add the `config-error` bucket to `_classify_codex_drop_reason` + `_codex_drop_reason_phrase` |
| `tests/unit/test-lib-review-codex.sh` | new TC-CXRS-CFG-* (classify, no-rerun, drop-reason, phrase); revise TC-CXRS-LAUNCH-06 to assert passthrough-but-classified |
| `tests/unit/fixtures/codex-review-stdout-config-error.txt` | new fixture: a clap `unexpected argument '-s'` capture |
| `docs/pipeline/invariants.md` | INV-62 sub-rules 2 + 5 + Test field updated for the config-error split |
| `docs/pipeline/review-agent-flow.md` | INV-59 (re-scoped) drop-reason section: add the config-error sibling bucket |
| `docs/test-cases/codex-resume-review-extra-args.md` | revise the TC-CXR-XA-01 row to the post-#218 reality + add the migration note |
| `docs/test-cases/codex-review-config-error.md` | this fix's test plan |

## Risks

| Risk | Mitigation |
|---|---|
| The detector false-matches a clean review that quotes a clap-style error | Require the leading `error:` + the clap grammar (`unexpected argument '…' found` / `invalid value … for`); a prose mention without the `error:` line does not match. And both callers gate on **rc 2** (clap's parse-error exit) — a clean (rc 0) review never reaches it, and a transient rc-1 run that quotes the string still re-runs / is classified as the transient it is (PR #225 review finding [P1]). |
| `set -euo pipefail` abort from a non-zero `grep` in the rc-0-always helpers | Same contract as the existing drop-reason helpers: every helper `return 0`-always, pipelines `|| true`-guarded. Tested with a bare call under `set -euo pipefail`. |
| Breaking #209's transient-retry behavior | A genuine transient signature (`stream disconnected before completion`, `Reconnecting... N/M`) does NOT match the clap signature, so it still takes the re-run path and still classifies `stream-error[:N/M]`. Pinned by a regression test. |
