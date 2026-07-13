# Test Cases — shell-idiom ratchet gate (issue #477, INV-130)

Drives `check-shell-idioms.sh` against scratch fixture trees via the
`--scan-root`/`--baseline` path-override flags (mirrors
`test-provider-cutover.sh`'s scratch-copy pattern). The committed repo files
and the real `shell-idioms-baseline.json` are never modified by the mutating
cases below. Credential-free (bash + jq + coreutils only).

## Files under test

| File | Role |
|------|------|
| `skills/autonomous-dispatcher/scripts/check-shell-idioms.sh` | the checker (Rule J + Rule S + baseline reconcile + `--require-trusted-ref` + `--write-baseline`) |
| `skills/autonomous-dispatcher/scripts/shell-idioms-baseline.json` | committed baseline for the real tree |
| `tests/unit/test-check-shell-idioms.sh` | fixture-driven unit tests below |

## Group A — Rule J (jq nullable-string guard) (TC-IDIOM-001..006)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-001 | `select(.body \| test("x"))` with no `type == "string"` anywhere in the file | flagged as 1 unguarded `jq_unguarded` occurrence |
| TC-IDIOM-002 | Same construct, with `select(.body \| type == "string")` on the line immediately above | NOT flagged (guarded — within the window) |
| TC-IDIOM-003 | Same construct, with the `type == "string"` guard 15 lines away (inside the window boundary) | NOT flagged |
| TC-IDIOM-004 | Same construct, with the guard 20 lines away (outside the window) | flagged (guard too far to count) |
| TC-IDIOM-005 | All six ops (`test`/`contains`/`startswith`/`endswith`/`sub`/`gsub`) each applied unguarded to `.body` in the same file | 6 unguarded occurrences counted |
| TC-IDIOM-006 | A `.title \| test(...)` (non-`.body` field) unguarded | NOT flagged — Rule J is deliberately scoped to `.body` only |

## Group B — Rule S (swallow justification) (TC-IDIOM-007..013)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-007 | `foo \|\| true` with a trailing same-line comment (`foo \|\| true  # rationale`) | NOT flagged (justified — same-line comment) |
| TC-IDIOM-008 | `foo \|\| true` with a comment line exactly 3 lines above | NOT flagged (justified — within the 3-line lookback) |
| TC-IDIOM-009 | `foo \|\| true` with a comment line 4 lines above (outside the lookback) and no same-line comment | flagged (unjustified) |
| TC-IDIOM-010 | `foo \|\| echo "msg"` (the `echo` variant) with no comment anywhere nearby | flagged (unjustified) |
| TC-IDIOM-011 | `foo \|\| echo` with a trailing comment | NOT flagged (justified) |
| TC-IDIOM-012 | A swallow token appearing INSIDE a comment line (e.g. `# see foo || true above`) | NOT counted as an occurrence at all — comment lines are stripped before matching |
| TC-IDIOM-013 | `foo \|\| echoinvalid` (not a real `echo` token, e.g. `echoStatus`) | NOT flagged — the ERE requires a word boundary after `echo` |

## Group C — baseline reconciliation (TC-IDIOM-014..020)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-014 | File's discovered count == its baseline count (both rules) | PASS |
| TC-IDIOM-015 | File's discovered `jq_unguarded` count EXCEEDS its baseline | FAIL, prints the offending `file:line` + matched text for the excess occurrence(s) |
| TC-IDIOM-016 | File's discovered `swallow_unjustified` count EXCEEDS its baseline | FAIL, prints the offending `file:line` + matched text |
| TC-IDIOM-017 | File's discovered count is BELOW its baseline (some occurrences were cleaned up) | PASS, with an informational notice recommending baseline regeneration |
| TC-IDIOM-018 | A NEW file (absent from the baseline entirely) with ≥1 violation | FAIL — an absent file with count > 0 is a violation, not silently accepted |
| TC-IDIOM-019 | A NEW file with zero violations (absent from baseline, no occurrences) | PASS — nothing to ratchet against |
| TC-IDIOM-020 | A baseline entry naming a file that no longer exists in the scratch tree | does not crash; treated as an implicit shrink (file removed), not a failure |

## Group D — scan scope (TC-IDIOM-021..022)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-021 | A violation planted under a `tests/` subdirectory inside the scanned root | excluded from the scan entirely (not counted, not flagged, not baselined) |
| TC-IDIOM-022 | A violation planted in a normal (non-`tests/`) nested subdirectory | included in the scan (recursive `find -L`) |

## Group E — `--require-trusted-ref` fail-closed posture (TC-IDIOM-023..026)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-023 | `--require-trusted-ref` with an unresolvable trusted ref (no git / ref absent) | FAIL closed — exit non-zero, never a silent pass |
| TC-IDIOM-024 | `--require-trusted-ref` with a trusted ref that resolves but carries no baseline file at the expected path | FAIL closed — exit non-zero |
| TC-IDIOM-025 | `--require-trusted-ref` with a trusted ref that DOES carry a valid baseline, tree unchanged vs it | PASS |
| TC-IDIOM-026 | Default mode (no `--require-trusted-ref`) reading the working-tree baseline directly, real repo | PASS against the committed baseline (load-bearing: proves the shipped baseline matches HEAD) |

## Group F — `--write-baseline` determinism (TC-IDIOM-027..028)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-027 | Run `--write-baseline` twice against the same unchanged fixture tree | byte-identical output both times (sorted keys, stable ordering) |
| TC-IDIOM-028 | `--write-baseline` output fed back in as `--baseline` against the same tree | the checker PASSES (round-trip: generator ⇄ checker consistent by construction) |

## Group G — infra / usage (TC-IDIOM-029..031)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-029 | `jq` unavailable (simulated via `PATH` override) | exit 2, clear error naming `jq` |
| TC-IDIOM-030 | Unknown CLI flag | exit 2 |
| TC-IDIOM-031 | Missing/unreadable baseline file in default (non-strict) mode | exit 2 (usage/env error, distinct from a strict-mode fail-closed FAIL) |

## Group H — regression pin + strict-mode growth (TC-IDIOM-032..033)

Added during review: TC-IDIOM-032 pins a bug caught in the code-review pass
(the `(true|echo\>)` alternation only bounded the `echo` branch, so bare
`true` prefix-matched `truex`); TC-IDIOM-033 closes a coverage gap flagged in
the same review (`--require-trusted-ref`'s core self-ratification-bypass
property — reading the baseline from the ref while scanning the WORKING
tree — had no direct test).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-032 | `foo \|\| truex` (not the bare `true` token) | NOT flagged — regression pin for the unbounded-alternation bug; the fix wraps the whole `(true\|echo)` alternation in one POSIX word-end boundary `([[:space:]]\|$)`, which is also portable to `mawk` (`\>` is a GNU-awk-only extension) |
| TC-IDIOM-033 | A clean baseline is committed to a trusted ref; the WORKING TREE (uncommitted) then adds a new swallow violation; run with `--require-trusted-ref` against that ref | FAIL — proves strict mode catches working-tree growth against the trusted baseline, not just baseline-vs-baseline drift |

## Acceptance criteria for this change (pre-merge verifiable)

- [ ] `check-shell-idioms.sh --write-baseline` run against the current tree
  matches the committed `shell-idioms-baseline.json`, and default-mode
  `check-shell-idioms.sh` exits 0 against the real repo (TC-IDIOM-026).
- [ ] All `TC-IDIOM-*` fixtures pass — CI evidence: green `Hermetic / Unit +
  conformance` job (`tests/unit/test-check-shell-idioms.sh` runs via the
  existing `test-*.sh` glob).
- [ ] `docs/pipeline/invariants.md` contains an `INV-130` entry (local
  repro: `grep -n "INV-130" docs/pipeline/invariants.md`).
- [ ] ShellCheck clean on `check-shell-idioms.sh` (`shellcheck -S error`).
