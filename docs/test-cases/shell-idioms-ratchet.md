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
| TC-IDIOM-032 | `foo \|\| truex` (not the bare `true` token) | NOT flagged — regression pin for the unbounded-alternation bug; the fix wraps the whole `(true\|echo)` alternation in one POSIX non-word-character boundary `([^[:alnum:]_]\|$)`, which is also portable to `mawk` (`\>` is a GNU-awk-only extension) |
| TC-IDIOM-033 | A clean baseline is committed to a trusted ref; the WORKING TREE (uncommitted) then adds a new swallow violation; run with `--require-trusted-ref` against that ref | FAIL — proves strict mode catches working-tree growth against the trusted baseline, not just baseline-vs-baseline drift |

## Group I — second review pass: whitespace-boundary false negative + baseline schema validation (TC-IDIOM-034..036)

Added during a second review pass: TC-IDIOM-034 pins a false-negative bug
(the `([[:space:]]|$)` boundary only matched swallows followed by
whitespace-or-EOL, missing the single most common real-world shape —
paren/semicolon/brace-terminated, e.g. `x=$(cmd || true)` — confirmed ~130
such sites tree-wide); TC-IDIOM-035/036 pin a silent-failure bug (the
baseline was validated as parseable JSON but never schema-validated, so a
malformed entry silently exempted that file from the ratchet under
`set -uo pipefail`'s no-`-e` semantics, reproducible even under
`--require-trusted-ref` fail-closed strict mode).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-034 | `x=$(cmd1 \|\| true)`, `y=$(cmd2 \|\| echo "fallback")`, `cmd3 \|\| true;`, `{ cmd4 \|\| true; }` — all paren/semicolon/brace-terminated, no trailing whitespace | ALL flagged (4 unjustified occurrences) — regression pin; the fix widens the boundary from `([[:space:]]\|$)` to any non-word character `([^[:alnum:]_]\|$)` |
| TC-IDIOM-035 | A baseline entry with a non-numeric `jq_unguarded` value (`"N/A"`) against a file with real unguarded occurrences, default (non-strict) mode | exit 2 (fails loud) — regression pin; previously the malformed value degraded to a silently-skipped file and a false PASS |
| TC-IDIOM-036 | The same malformed-value shape committed to a trusted ref, checked via `--require-trusted-ref` | exit 1 (fails closed) — regression pin for the strict-mode variant of the same bug, the exact self-ratification bypass this mode exists to prevent |

## Group J — forward-window direction, invalid-JSON baseline, cross-engine parity (TC-IDIOM-037..039)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-037 | Rule J's `type == "string"` guard 15 lines AFTER the match (forward direction — Group A only tested backward) | NOT flagged — the `hi = n + window` boundary is symmetric |
| TC-IDIOM-038 | An existing baseline file containing invalid JSON (not merely absent) in default mode | exit 2 — distinct usage/env error from a missing-file baseline (TC-IDIOM-031) |
| TC-IDIOM-039 | The same fixture tree checked once under `awk` (gawk) and once with `mawk` shadowing `awk` on `PATH` | byte-identical output on both — proves the mawk-portability claim behind TC-IDIOM-032/034's fix rather than resting on a one-time manual check; skips gracefully if mawk isn't installed on the runner |

## Group K — empty-scan-root sanity check, third review round (TC-IDIOM-040..042)

A third review pass (silent-failure-hunter) found a Critical gap: a wrong or
missing `--scan-root` made file discovery silently return nothing. Every
baseline entry then looked like it had "shrunk to 0," and the reconciliation
loop PASSed trivially — even under `--require-trusted-ref` — with zero real
files actually checked. The checker now requires at least one scanned
`*.sh` file before reconciling.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-040 | `--scan-root` pointing at a directory that does not exist, default mode | exit 2 — not a trivial PASS |
| TC-IDIOM-041 | A `--scan-root` that exists but contains zero `*.sh` files, checked via `--require-trusted-ref` against a non-empty trusted baseline | exit 1 (fail-closed) — every baseline entry would otherwise look like a shrink |
| TC-IDIOM-042 | A `--scan-root` with real `*.sh` files and zero violations (the ordinary clean case) | PASSes normally — the guard triggers on zero FILES scanned, never on zero violations found |

## Group L — non-integer numeric baseline values, fourth review round (TC-IDIOM-043..045)

A fourth review pass found that the baseline schema check asserted only
`type == "number"`, not integrality. A non-integer value (e.g. `1.5`) passed
schema validation and then broke the downstream `[ -gt ]`/`[ -lt ]` integer
comparisons, which under `set -uo pipefail` (no `-e`) degrades to a
silently-skipped file rather than a hard failure — defeating the ratchet
even under `--require-trusted-ref`.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-043 | A baseline count that is a valid jq `number` but not an integer (`1.5`), default mode | exit 2 (fails loud) — regression pin |
| TC-IDIOM-044 | The same non-integer shape committed to a trusted ref, checked via `--require-trusted-ref` | exit 1 (fails closed) — regression pin for the strict-mode variant |
| TC-IDIOM-045 | An integer-VALUED number in exponent notation (`1e2 == 100`), which is schema-valid but naively interpolates as `"1E+2"` | reconciles cleanly (no `integer expected` error) — the fix applies `\| floor` to normalize the rendered text before comparison |

## Group M — missing option-argument usage errors, fifth review round (TC-IDIOM-046..049)

A fifth review pass found that a value-taking option (`--scan-root`,
`--baseline`, `--trusted-ref`, `--trusted-baseline-path`) given with no
following value died on an unbound `$2` under `set -u`, exiting 1 (looking
like an internal shell crash) instead of the documented exit-2 usage error.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-046..049 | Each of `--scan-root`/`--baseline`/`--trusted-ref`/`--trusted-baseline-path` given as the last (bare) argument, with no following value | exit 2 (usage error), never an unbound-variable crash — regression pin, one case per option |

## Group N — baseline counts too large for bash comparisons, sixth review round (TC-IDIOM-050..052)

A sixth review pass (the "third review pass" in `invariants.md`'s INV-130
entry, which counts only the schema-validation rounds) found that the Group L
integer fix was insufficient: an integer-VALUED count that exceeds 2^53
(9007199254740992 — the largest
integer jq's IEEE-754 doubles represent exactly) still breaks the same
comparisons. `floor` renders such values in exponential notation (e.g.
`1e20`), and even a plain-decimal value just past bash's int64 ceiling
rounds UP past it when rendered (`9223372036854775808` → `9223372036854776000`,
itself unparsable by `[ -gt ]`/`[ -lt ]`) — both silently PASS under
`set -uo pipefail`'s no-`-e` semantics, even under `--require-trusted-ref`.
The fix bounds the schema check's accepted value at `<= 9007199254740992`,
not just "is an integer."

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-050 | A baseline count that is schema-integer but exceeds the bound in exponent notation (`1e20`), default mode | exit 2 (fails loud), no `integer expected` leak — regression pin |
| TC-IDIOM-051 | A baseline count that is a PLAIN-DECIMAL integer literal just past bash's int64 ceiling (`9223372036854775808`) | exit 2 (fails loud), no `integer expected` leak — proves the fix bounds the numeric value, not just the literal's notation |
| TC-IDIOM-052 | The same out-of-range shape committed to a trusted ref, checked via `--require-trusted-ref` | exit 1 (fails closed) — regression pin for the strict-mode variant |

## Group O — mktemp/scratch-write failures must fail closed, seventh review round (TC-IDIOM-053..055)

A seventh review pass (the "fourth review pass" in `invariants.md`'s INV-130
entry, which counts only the schema-validation/reconciliation-robustness
rounds — see Group N's note on the same numbering split) found that the
reconciliation phase's three `mktemp`
scratch-file allocations, and the writes into them (`discover_counts`, the
baseline-extraction `jq | sort`, the `cut | sort -u` union), were unchecked.
Under `set -uo pipefail` (no `-e`), a failed `mktemp` (e.g. an unavailable
`TMPDIR`) left the corresponding variable empty; every downstream
redirect/read against that empty path also failed silently, every table
looked empty, and the reconciliation loop read that as "every baseline entry
shrank to 0" — the checker printed `shell-idioms-guard: PASS` with exit 0
even though the ratchet comparison never ran, reproducing under
`--require-trusted-ref` too. The fix checks each `mktemp` call and each
scratch-file write explicitly, treating a failure as the documented exit-2
usage/infra error in both default and strict mode (this is a scratch-space
failure, not a ratchet violation, so it does not take the strict-mode exit-1
fail-closed path).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-053 | A simulated `mktemp` failure (fake `PATH` entry) during a default-mode run against a tree with a real violation | exit 2, output never contains `shell-idioms-guard: PASS` — regression pin |
| TC-IDIOM-054 | The same simulated `mktemp` failure under `--require-trusted-ref` against a clean committed trusted baseline | exit 2 (infra error, not the strict-mode exit-1 fail-closed path), output never contains `shell-idioms-guard: PASS` |
| TC-IDIOM-055 | A healthy `mktemp` (no fake `PATH`) against a clean tree | exit 0, output contains `shell-idioms-guard: PASS` — proves the fix does not regress the normal PASS path |

## Group P — current-tree infra-failure hardening, issue #482 (TC-IDIOM-056..061)

Three narrow infra-failure paths in the CURRENT-TREE scan side, split out from
#480/INV-130's review loop at operator takeover (round-5 residual `[P2]`
findings the severity ratchet should have demoted per INV-129's floor). All
three share one shape: an unchecked command substitution in the
discover/reconcile pipeline collapses to empty output on tool failure, and the
surrounding logic reads "no rows" as "no violations."

| ID | Scenario | Expected |
|----|----------|----------|
| TC-IDIOM-056 | A simulated `awk` failure (fake `PATH` stub exiting 1) during `discover_counts`' Rule J/S detector calls, default mode against a tree with a real violation | exit 2, output never contains `shell-idioms-guard: PASS` — regression pin (R1) |
| TC-IDIOM-057 | The same simulated `awk` failure under `--write-baseline` | exit 2, never emits a baseline document (not even a falsely-clean `{}`) |
| TC-IDIOM-058 | A healthy `awk` (no fake `PATH`) against a clean tree | exit 0 — proves the detector-failure check does not regress the normal PASS path |
| TC-IDIOM-059 | A fake `cut` that fails only on its FIRST invocation (deterministically simulating a DISC_TMP read failure, since DISC_TMP is always cut first in the reconciliation phase) during the file-union build, against a tree with a real violation | exit 2, output never contains `shell-idioms-guard: PASS` — regression pin (R2) for the combined-`{ cut; cut; }`-group bug, where the group's exit status is only its LAST command's and silently absorbed a failing first `cut` |
| TC-IDIOM-060 | A healthy `cut` (no fake `PATH`) against a tree matching its baseline | exit 0 — proves the two-separate-cut rewrite does not regress the normal reconciliation path |
| TC-IDIOM-061 | A `.sh` fixture path containing a literal tab byte, with a real violation inside it | exit 2, error names the tab — rejected loudly (R3) rather than corrupting the tab-delimited count table and silently bypassing the ratchet for that file |

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
