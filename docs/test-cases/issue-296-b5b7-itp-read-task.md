# Test Cases — live-wrapper issue READS behind `itp_read_task` (#296 B5+B7)

Test file: `tests/unit/test-itp-read-task-b5b7.sh` (hermetic; stubs `gh`).
Mirrors `tests/unit/test-itp-read-leaves.sh` (#281) and
`tests/unit/test-chp-pr-lifecycle.sh` (#282).

Migrated sites (both byte-identical, pure call-site swaps — the seam is already
sourced in both wrappers, the verb already in production at
`autonomous-dev.sh:1174`):

| Tag | File:line | Verb call |
|---|---|---|
| B5 | `autonomous-dev.sh:887` | `itp_read_task "$ISSUE_NUMBER" title,body,comments -q '.'` |
| B7 | `autonomous-review.sh:3439` | `itp_read_task "$ISSUE_NUMBER" labels -q '[.labels[].name] \| any(. == "no-auto-close")'` |

## 1. Golden-trace — argument-boundary-preserving byte-identical `gh` argv (AC2)

A recording `gh` stub captures the exact argv each migrated site emits **as a
NUL-delimited array** (NOT space-joined — the `-q` selectors contain spaces and
pipes). The test asserts argc + each exact arg, including the verbatim `-q`
selector. A word-split or re-escaped selector FAILS.

| ID | Site / verb call | Assertion |
|---|---|---|
| TC-RT-B5-ARGV | `itp_read_task <N> title,body,comments -q '.'` | argv (NUL array) == `[issue, view, <N>, --repo, <REPO>, --json, title,body,comments, -q, .]` — exactly 9 args (`title,body,comments` is one arg) |
| TC-RT-B7-ARGV | `itp_read_task <N> labels -q '[.labels[].name] \| any(. == "no-auto-close")'` | argv (NUL array) == `[issue, view, <N>, --repo, <REPO>, --json, labels, -q, [.labels[].name] \| any(. == "no-auto-close")]` — exactly 9 args; the selector is ONE arg (the space/pipe survives the boundary) |
| TC-RT-B7-SELECTOR-ONEARG | (negative) | the `-q` selector is a single argv element — a re-escaped / word-split selector (e.g. `[.labels[].name]` and `\|` as separate args) FAILS the argc check |

## 2. Seam + observed-call — the migrated path is EXERCISED, not just reachable (AC4)

Each migrated site sources the real `lib-issue-provider.sh` (which sources
`providers/itp-github.sh`) and asserts the gh-stub OBSERVED the verb's argv.
An undefined verb would fail-soft (these reads wrap in `2>/dev/null`/capture),
so reachability ≠ exercised — the OBSERVED argv is the proof.

| ID | Assertion |
|---|---|
| TC-RT-SEAM-SOURCED | sourcing the real `lib-issue-provider.sh` defines `itp_read_task`; `ISSUE_PROVIDER` defaults to `github` so it routes to `itp_github_read_task` |
| TC-RT-B5-OBSERVED | invoking the B5 verb-call through the real seam → gh-stub records the B5 argv (proves the github leaf ran, not a no-op) |
| TC-RT-B7-OBSERVED | invoking the B7 verb-call through the real seam → gh-stub records the B7 argv |

## 3. Behavior-equivalence — same ISSUE_BODY / HAS_NO_AUTO_CLOSE before & after

The verb emits the identical `gh` argv, so a `gh` stub returning a canned
payload yields the identical captured value the old raw call would have.

| ID | Assertion |
|---|---|
| TC-RT-B5-EQUIV | `ISSUE_BODY=$(itp_read_task <N> title,body,comments -q '.')` with a stubbed `gh` returning a JSON object → `ISSUE_BODY` equals the stub payload (same as the old raw `gh issue view … -q '.'`) |
| TC-RT-B7-EQUIV-TRUE | `gh` stub applies the `-q` selector to a labels payload containing `no-auto-close` → `HAS_NO_AUTO_CLOSE == "true"` |
| TC-RT-B7-EQUIV-FALSE | `gh` stub applies the `-q` selector to a labels payload WITHOUT `no-auto-close` → `HAS_NO_AUTO_CLOSE == "false"` (the `\|\| echo "false"` guard + selector both preserved) |

## 4. Source-of-truth — the wrappers call the verb, not raw `gh`, at the migrated sites (AC1 backstop)

| ID | Assertion |
|---|---|
| TC-RT-B5-SRC | `autonomous-dev.sh` defines `ISSUE_BODY=$(itp_read_task "$ISSUE_NUMBER" title,body,comments -q '.')` and has NO raw `gh issue view … title,body,comments` executable line |
| TC-RT-B7-SRC | `autonomous-review.sh` defines `HAS_NO_AUTO_CLOSE=$(itp_read_task "$ISSUE_NUMBER" labels …)` and has NO raw `gh issue view … --json labels` executable line at the no-auto-close gate |

## 5. Cutover-baseline + spec gate (AC3, AC5, AC6) — verified via CI

| ID | Surface | Assertion |
|---|---|---|
| TC-RT-BASELINE-SHRINK-2 | CI Spec Drift + PR diff | `cutover-baseline.json` shrinks by exactly 2 (the two named survivors); the out-of-scope survivors remain; `check-provider-cutover.sh` exits 0 |
| TC-SPEC-GATE-310 | CI unit | greps `docs/pipeline/invariants.md` for the EXACT INV-91 Migration-log bullet for #296 B5+B7 (AC5) |
| TC-RT-SPECDRIFT-UNCHANGED | CI Spec Drift | `check-spec-drift.sh` exits 0 unchanged — this PR adds/removes NO `--add-label`/`--remove-label` site (AC6, the read-only-scope proof) |

All ACs are deterministic CI greps/tests; no subjective reviewer step.
