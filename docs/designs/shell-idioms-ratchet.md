# Design — shell-idiom ratchet gate (`check-shell-idioms.sh`, INV-130)

Issue #477. A new CI checker + ratchet, modeled on `check-provider-cutover.sh`
([INV-91]), that blocks **growth** of two recurring shell-idiom bug surfaces
across the dispatcher scripts tree:

- **Rule J** — a jq `.body` string-op (`test`/`contains`/`startswith`/
  `endswith`/`sub`/`gsub`) applied without a nearby `type == "string"` guard.
  A bot comment with `body: null` (a real GitHub REST shape) makes the
  unguarded op a jq **runtime error**, aborting the whole `jq` invocation —
  not a per-row non-match. Prior incidents: the round-6 fix in the #449
  series (`_rr_prior_marker` silently resetting `REVIEW_ROUND` to 1) and the
  identical guard already present in `_review_cap_prior_marker`
  (`lib-review-cap.sh`).
- **Rule S** — `|| true` / `|| echo …` with no adjacent comment explaining
  which-direction-does-this-fail. Each swallow is a fail-open/fail-closed
  decision; several past parks/breakers trace back to an undocumented or
  wrong-direction swallow.

## Why a ratchet, not a fix-all

The repo has ~580 jq call sites and ~629 swallow sites. A from-zero ban would
either be a wall of false positives (the 15-line window is a heuristic, not a
parser) or force a high-risk mass retrofit. [INV-91]'s provider-cutover guard
already proved the ratchet shape works here: freeze today's occurrences in a
committed baseline, fail CI only on **growth** past that baseline per file,
and let the baseline shrink voluntarily as code is cleaned up.

## What the checker does

`check-shell-idioms.sh` — modeled structurally on `check-provider-cutover.sh`
(`set -uo pipefail`, `SCRIPT_DIR`/path-override flags, `fail()`/`info()`,
`::error::`, exit `0/1/2`):

- **Scan scope (R4)**: every `*.sh` under `skills/` (`find -L`, so tracked
  symlinked scripts stay in scope), EXCLUDING any path containing a
  `/tests/` (or `tests/`-prefixed) segment — test scaffolding legitimately
  swallows and is out of scope per the issue body.
- **Rule J detector**: a line matches the ERE
  `\.body[[:space:]]*\|[[:space:]]*(test|contains|startswith|endswith|sub|gsub)\(`.
  It is **guarded** iff a window of the surrounding lines (the match line ±15
  lines, clipped to the file) contains the literal `type == "string"`
  anywhere. Unguarded matches are counted per file.
- **Rule S detector**: a non-comment line matches the ERE
  `\|\|[[:space:]]*(true|echo\b)` (comment-stripped the same way
  `check-provider-cutover.sh` strips gh-detector comment lines — first
  non-space char `#` skips the whole line). It is **justified** iff the same
  line carries a trailing `#` comment after the match, OR any of the 3
  immediately preceding lines is a comment line (`^[[:space:]]*#`).
  Unjustified matches are counted per file.
- **Baseline** (R5): `shell-idioms-baseline.json`, shape
  `{ "<repo-relative-path>": { "jq_unguarded": N, "swallow_unjustified": N }, ... }`,
  sorted keys for reviewable diffs. Per file: `current > baseline` → FAIL
  (print the delta + offending lines); file absent from baseline with
  count > 0 → FAIL; `current < baseline` → PASS + a regeneration notice
  (ratchet-down is a separate voluntary commit, mirroring INV-91's posture).
- **`--require-trusted-ref`** (mirrors INV-91's Check 4/strict mode): reads
  the baseline from `origin/main` via `git show` instead of the working
  tree, and **fails closed** (exit 1) if the trusted ref or its baseline
  file is unresolvable — a PR must not be able to regenerate the baseline
  and self-ratify in the same change.
- **`--write-baseline`**: emits a freshly generated baseline for the current
  tree to stdout, sorted-key deterministic.

Exit codes: `0` pass, `1` violations, `2` usage/infra error (missing `jq`,
unknown flag, unreadable baseline in default mode).

## Heuristic bounds (deliberate, documented)

Both detectors are line-window heuristics, not a bash/jq parser — the issue
body explicitly rules out attempting real parsing. A false positive in
**existing** code is absorbed by the baseline; a false positive in **new**
code costs the author one justification comment (Rule S) or moving the guard
into the window (Rule J) — the exact behavior the gate wants to encourage.
Rule J is scoped to `.body` only (the one field with a confirmed null-crash
history); widening to other fields is explicitly out of scope for this issue.

## CI wiring (R6) — deferred, non-blocking follow-up

The issue asks for a new step in the `hermetic-shellcheck` job in
`.github/workflows/ci.yml`. **The dev agent's scoped GitHub App token has no
`workflows` permission and cannot push a `.github/workflows/` change** — the
same constraint [INV-83]/[INV-91]'s history documents (the provider-cutover
guard's own CI step was deferred to a maintainer follow-up PR, #295, for the
identical reason). This PR ships the checker script, the committed baseline,
the full unit-test suite, and the `docs/pipeline/invariants.md` INV-130
entry; the `ci.yml` step is called out as a maintainer follow-up in the PR
description, mirroring #295's precedent exactly. Until that step lands, the
checker still runs in CI through the existing `tests/unit/test-*.sh` glob
(`test-check-shell-idioms.sh` invokes it against the real repo), so a
regression is caught by the hermetic-unit job even without the dedicated
step.

## Docs

- `docs/pipeline/invariants.md` — new **INV-130** entry: ratchet semantics,
  both rule definitions verbatim, baseline path, fail-closed trusted-ref
  posture, the INV-91 precedent it mirrors, and the deferred-CI-wiring note.

## Test plan

See `docs/test-cases/shell-idioms-ratchet.md` (`TC-IDIOM-NNN`) — fixture-driven
unit tests against `tests/unit/test-check-shell-idioms.sh`, mirroring
`test-provider-cutover.sh`'s scratch-copy pattern.
