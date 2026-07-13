# Test Cases — INV-129: head-agnostic review-round counter (issue #475)

Pins the redefinition of `REVIEW_ROUND` (issue #449 R1) from an
`(issue, head)`-scoped counter that resets on every push to a head-agnostic
series of consecutive decided `failed-substantive` rounds, plus the new
`_review_round_prior_marker` cutoff-then-scan function (mirroring INV-127's
own `_review_cap_prior_marker`) and the `round=0` explicit reset marker on
PASS rounds. Mirrors `docs/test-cases/review-convergence-rules.md`'s
structure: pure logic tables + source-of-truth wiring greps against
`autonomous-review.sh`, since the wrapper itself is too heavy to run
end-to-end.

## Files under test

| File | Role |
|------|------|
| `skills/autonomous-dispatcher/scripts/lib-review-round.sh` | `_review_round_parse_count`/`_review_round_next_count` dropped the `<head>` param (head-permissive `head=.*` regex); `_review_round_marker` unchanged 3-arg signature, empty head → `unknown` placeholder; NEW `_review_round_prior_marker` — cutoff-then-scan sibling of `_review_cap_prior_marker` |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | Read site: drops the empty-`PR_HEAD_SHA`-forces-round=1 branch, calls `_review_round_prior_marker` instead of an inline `contains()` substring scan. Post site: `pass` posts `round=0`; substantive `fail` posts the incremented round (unchanged) |
| `skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh` | `_aggregate_has_p0p1_fail` — byte-identical (regression pin only); doc comment updated |
| `tests/unit/test-review-convergence-rules.sh` | Extended with the TC-INV129-* fixtures below |

## Test scenarios

### Group A — head-agnostic parse/next (no `<head>` param) (TC-INV129-001..008)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-INV129-001 | New-head-every-round series: 3 consecutive decided `failed-substantive` rounds, each on a DIFFERENT head, no PASS/trip/round=0 in between | round increments 1→2→3 (the exact scenario the OLD head-scoped semantics froze at 1 — regression-pin the absence of the old behavior) |
| TC-INV129-002 | Same-head consecutive decided fails (superset of the pre-#475 by-design behavior) | round still increments normally |
| TC-INV129-003 | `_review_round_next_count` no longer accepts a second (head) argument | signature is single-arg (`<marker_text>`) |
| TC-INV129-004 | `_review_round_parse_count` no longer accepts a second (head) argument | signature is single-arg (`<marker_text>`) |
| TC-INV129-005 | Legacy head-KEYED marker (posted by pre-#475 code, e.g. `head=deadbeef`) fed into the new parser | still parses correctly (permissive `head=.*` match, mirrors `_review_cap_parse_count`) |
| TC-INV129-006 | Malformed marker text | parses as round=0, next=1, does not crash (bias-to-MISS, unchanged contract) |
| TC-INV129-007 | Marker constructed with an empty/unset head | renders as the literal `unknown` placeholder (not an empty field), mirrors `_review_cap_marker` |
| TC-INV129-008 | Empty-head marker's round field | still parses and increments correctly — an unknown head must never silently reset the head-agnostic counter |

### Group B — reset channel 1: `passed`/`failed-non-substantive` trailer cutoff (TC-INV129-009..014)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-INV129-009 | `_review_round_prior_marker` given a fixture with a `failed-substantive` round-counter marker followed by a `<!-- review-verdict: passed -->` trailer, no marker posted since | echoes `""` — the PASS resets the series |
| TC-INV129-010 | Same fixture fed into `_review_round_next_count` | returns `1`, not a carry-forward of the pre-reset count |
| TC-INV129-011 | Same shape, but the intervening trailer is `failed-non-substantive` instead of `passed` | also resets — echoes `""` |
| TC-INV129-012 | A HUMAN-authored `<!-- review-verdict: passed -->` forgery between two markers | does NOT reset (authenticity filter — `authorKind != "human"`) |
| TC-INV129-013 | A bot-authored FAIL body that merely quotes/discusses a prior `<!-- review-verdict: passed -->` trailer in prose (not a bare, standalone trailer) | does NOT reset — full-body-anchored (`^...$`), not a substring `test()` |
| TC-INV129-014 | A `failed-substantive` trailer (including `dev-actionable=false`) between two markers | does NOT reset — the prior marker still qualifies (regression pin against a substring mix-up with `failed-non-substantive`) |

### Group C — reset channel 2: INV-127 trip report cutoff (TC-INV129-015..018)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-INV129-015 | `_review_round_prior_marker` given a fixture where an INV-127 trip report (embedding its own `dispatcher-review-cap-breaker` marker, body matching "Review-round-cap circuit-breaker tripped") is the newest comment | echoes `""` — the trip report is itself a reset cutoff; after an operator removes `stalled` and resumes, the next review runs at round 1 |
| TC-INV129-016 | A fixture with an INV-105-style non-convergence trip report (a DIFFERENT breaker) as the newest comment, with a genuine `review-round-counter` marker before it | the marker still qualifies — INV-105 trip reports are NOT a reset cutoff for this series (the series legitimately continues across an unrelated dev-side stall) |
| TC-INV129-017 | A fixture with an INV-122-style same-head-gate-failure trip report as the newest comment, with a genuine `review-round-counter` marker before it | the marker still qualifies — INV-122 trip reports are NOT a reset cutoff either |
| TC-INV129-018 | A genuine `review-round-counter` marker timestamped AFTER the latest INV-127 trip report | that marker qualifies (a fresh post-resume series continuing normally) |

### Group D — reset channel 3: explicit `round=0` marker (TC-INV129-019..023)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-INV129-019 | A `pass` aggregate at the marker-post site | posts `<!-- review-round-counter: issue=<N> head=<sha\|unknown> round=0 -->` instead of the incremented `$REVIEW_ROUND` |
| TC-INV129-020 | A substantive `fail` aggregate at the marker-post site | posts the incremented round exactly as before #475 (unchanged) |
| TC-INV129-021 | `_review_round_next_count` fed a `round=0` marker directly (via the ordinary parse path, NOT the trailer cutoff) | returns `1` — the marker-side channel independently resets even with no qualifying trailer at all |
| TC-INV129-022 | `round=0` marker present with NO `passed`/`failed-non-substantive` trailer anywhere in the fixture (models a transient `emit_verdict_trailer` post failure) | the series still resets to 1 via the marker-side channel alone — proves the reset is dual-channel, not solely dependent on the trailer |
| TC-INV129-023 | A `round=0` marker followed by a later genuine `failed-substantive` marker at round N | the later marker wins (normal "latest qualifying marker" behavior — the round=0 marker is not itself a permanent floor) |

### Group E — read-site wiring: full-body anchor + empty-head handling (TC-INV129-024..029)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-INV129-024 | A comment whose body CONTAINS `review-round-counter:` as a substring but is not the marker's exact standalone body (e.g. a human discussing it in prose, or a bot comment embedding it alongside other text) | rejected — read site uses a full-body-anchored regex (`^<!--...-->[[:space:]]*$`), not `contains()` |
| TC-INV129-025 | A genuine standalone marker comment (exactly the marker, nothing else) | accepted |
| TC-INV129-026 | Wrapper source: the empty-`PR_HEAD_SHA`-forces-`REVIEW_ROUND=1`-and-skip-marker branch from the #449-era code | absent — grep confirms no `WARNING: Issue #449: PR_HEAD_SHA is empty` branch remains |
| TC-INV129-027 | `PR_HEAD_SHA` is empty at the read site (a transient `chp_pr_view` failure) | the round counter reads/parses/increments normally (head is forensic-only) — no special-case short-circuit |
| TC-INV129-028 | `PR_HEAD_SHA` is empty at the post site on a substantive-fail round | the marker is still posted, with `head=unknown` |
| TC-INV129-029 | A bot comment with a `null` `.body` (real GitHub REST shape) present alongside a genuine marker | `_review_round_prior_marker`'s jq scan does not crash (`.body \| type == "string"` guard); the genuine marker is still found |

### Group F — INV-127 gate regression pin (R5) (TC-INV129-030..032)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-INV129-030 | `_aggregate_has_p0p1_fail`'s output on the existing fixture set (the same inputs `test-review-convergence-rules.sh`'s TC-REVIEW-CONV-036b..j already exercise) | byte-identical output to pre-#475 — no behavioral change |
| TC-INV129-031 | `git diff main -- skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh` | comment-only changes (no code line changed) |
| TC-INV129-032/033a | Simulated loop: every round pushes a new head, each round's only finding is `[P2]` (033a pins the round-4 intermediate value within the same loop) | round is 4 after 4 rounds (033a); the review demotes the fail to `pass` at round 5 (032, the acceptance-criteria scenario) — proves the gate is no longer load-bearing for this exact case, since the round now reaches 5 |

### Group G — end-to-end round-progression simulations (TC-INV129-034..036)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-INV129-034 | An all-timeout `fail` (no substantive fail, `_AGGREGATE_SUBSTANTIVE_FAIL == false`) posts no marker at all | the next read still increments from the last REAL marker, not from a phantom round advanced by the skipped post |
| TC-INV129-035 | A genuine `pass` mid-series, confirmed via both reset channels together (trailer cutoff AND `round=0` marker) | round resets to 1 on the next read |
| TC-INV129-036 | Mixed loop: rounds 1-2 are P1 (advance both R1's ratchet and INV-127's cap), rounds 3-5 are P2-only (advance R1's ratchet only, INV-127's cap gate excludes them via `_aggregate_has_p0p1_fail`) | R1's `REVIEW_ROUND` reaches 6 and demotes the round-6 P2 finding to `pass`; INV-127's own counter stays at 2 (never trips) |

## Acceptance criteria for this change (pre-merge verifiable)

- [ ] **Surface**: CI job `hermetic-unit` runs `tests/unit/test-*.sh`; the
  extended `test-review-convergence-rules.sh` passes (all TC-INV129-* green
  alongside the pre-existing TC-REVIEW-CONV-* fixtures). Expected evidence:
  green `Hermetic / Unit + conformance` check on the PR.
- [ ] **Surface**: `docs/pipeline/invariants.md` contains an `INV-129` entry;
  `docs/pipeline/review-agent-flow.md` no longer states the head-scoped
  reset-on-push premise as current behavior (local repro: `grep -n "INV-129"
  docs/pipeline/invariants.md`; `grep -n "resets .* to .*1"
  docs/pipeline/review-agent-flow.md` returns no head-scoped
  round-counter claim).
- [ ] **Surface**: `git diff main --
  skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh` shows
  comment-only changes (R5 — `_aggregate_has_p0p1_fail` unchanged).
- [ ] Full existing unit suite passes (no regression to
  `tests/unit/test-e2e-gate-circuit-breaker.sh`,
  `tests/unit/test-convergence-breaker.sh`, or
  `tests/unit/test-review-convergence-rules.sh`'s pre-existing
  TC-REVIEW-CONV-* fixtures).
- [ ] The existing review-wrapper E2E lane
  (`tests/e2e/run-liveness-watchdog-e2e.sh` and any other pre-existing
  wrapper E2E suite) still passes unmodified — this change is pure
  marker/counter logic exercised by the unit fixtures, not a wrapper
  control-flow change.
- [ ] ShellCheck green on every modified script.
