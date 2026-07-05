# Test Cases — W-D Runner GitLab Axis + Transport-Hook Passthrough (issue #416)

Runner extensions to `tests/provider-conformance/run-provider-conformance.sh` that make the W-A transport contract provable end-to-end and enable an out-of-tree provider self-certification path (AC3 of #414).

**Suite**: `tests/unit/test-provider-conformance-runner.sh` (extends the existing).
**Discipline**: hermetic; stubbed curl (via `--transport-path-add`) or fixture transport-hook.

## Conventions

- IDs `TC-RGH-NNN`.
- No new fixtures ship for the gitlab axis — leaves come in W-B / W-C. The W-A slice ships only the runner mechanism and the shape of the flag-plumbing.
- Every test uses the existing pass/fail helpers (`ok`, `bad`, `assert_*`).

## Test Cases

### `pcf_resolve_provider_dir` — gitlab axis + absolute-path form

| ID | Scenario | Expected |
|---|---|---|
| TC-RGH-001 | `pcf_resolve_provider_dir <root> gitlab` | rc 0; stdout = `<root>/skills/autonomous-dispatcher/scripts/providers` (same as github — filename prefix disambiguates) |
| TC-RGH-002 | `pcf_resolve_provider_dir <root> /tmp/ext-provider` where `/tmp/ext-provider` exists and is a directory | rc 0; stdout = `/tmp/ext-provider` (self-resolution for out-of-tree providers) |
| TC-RGH-003 | `pcf_resolve_provider_dir <root> /tmp/nonexistent-abs-path` where the path does NOT exist | rc 1; no output |
| TC-RGH-004 | `pcf_resolve_provider_dir <root> unknownname` (non-path, non-fixed) | rc 1 (unchanged from existing behavior) |
| TC-RGH-005 | Existing fixed names still resolve: `github`, `degraded`, `broken` | unchanged from existing behavior |

### `--transport-hook` passthrough

| ID | Scenario | Expected |
|---|---|---|
| TC-RGH-010 | `run-provider-conformance.sh --transport-hook /no/such/file --itp github --chp github` | rc ≠ 0; fatal message names the unreadable path (validated once at startup, exit 2) |
| TC-RGH-011 | `run-provider-conformance.sh --transport-hook <readable> --itp github --chp github` — the readable hook path threads through to `_invoke`'s subshell as `GITLAB_TRANSPORT_HOOK=<path>` | fixture inspection subshell sees the env var set |
| TC-RGH-012 | Byte-identical behavior on github/github with `--transport-hook` present but unused (hook file exists but no gitlab leaves are exercised) | same 31 PASS lines, `CONFORMANCE-SUMMARY total=31 pass=31 fail=0` |

### `--transport-path-add` (isolated PATH extension)

| ID | Scenario | Expected |
|---|---|---|
| TC-RGH-020 | `run-provider-conformance.sh --transport-path-add /some/dir` — a probe verb (or a shim assertion) sees `/some/dir` prepended to its subshell PATH | subshell PATH contains `/some/dir` |
| TC-RGH-021 | Multiple `--transport-path-add A --transport-path-add B` accumulate — subshell PATH contains BOTH `A` and `B` | subshell PATH contains both entries |
| TC-RGH-022 | The added dirs do NOT leak into the runner's OWN env (only into `_invoke` subshells) | the runner's own PATH stays as inherited (does not contain the added dirs after the flag is parsed) |
| TC-RGH-023 | github/github axis with `--transport-path-add` present is byte-identical (extra PATH entries are harmless when unused) | same PASS/FAIL counts |

### `--expect-absent` partial-axis mechanism

| ID | Scenario | Expected |
|---|---|---|
| TC-RGH-030 | `--expect-absent chp:create_pr,chp:merge` on a topology where the named leaves are absent | those verbs downgrade from FAIL to `SKIP <verb> (expected-absent: <next-slice>)`; runner exit code may be 0 if no other absent verbs |
| TC-RGH-031 | `--expect-absent chp:create_pr` — a DIFFERENT absent verb (e.g. `chp_merge`) still FAILs | rc ≠ 0; `chp_merge FAIL (leaf absent: ...)` still present |
| TC-RGH-032 | `--expect-absent chp:create_pr` — the argument seam-qualifies (`chp:create_pr` NOT the same as `itp:create_pr`) | ITP/CHP name-collision safe |
| TC-RGH-033 | `--expect-absent chp:create_pr` — the verb PRESENT on the axis is NOT downgraded (a present verb runs normally) | verb runs its normal assertion |

### `--itp gitlab --chp gitlab` interim (W-D early half)

| ID | Scenario | Expected |
|---|---|---|
| TC-RGH-040 | `run-provider-conformance.sh --itp gitlab --chp gitlab` on today's tree (no leaves) | runner exits non-zero; runner does NOT abort; one per-verb FAIL line per absent verb naming the absent leaf file |
| TC-RGH-041 | Same run — no runner-level Python/bash exception is emitted (only per-verb FAILs) | no stack trace / no `command not found` outside a per-verb reason |
| TC-RGH-042 | Same run with `--expect-absent chp:create_pr,chp:approve,chp:merge,chp:review_threads,...` covering every absent verb → runner exits 0 with SKIP lines | rc 0 iff every absent verb is named |

### github/github parity (AC2 of #414)

| ID | Scenario | Expected |
|---|---|---|
| TC-RGH-050 | `run-provider-conformance.sh --itp github --chp github` — the pre-existing 31 PASS lines still emit | 31 PASS lines; `pending=0`; `fail=0` (byte-identical to today) |

## AC3 shape-check (precondition test)

`AC3` (parent #414) — an end-to-end out-of-tree fixture provider + fixture transport hook + `--transport-path-add` — cannot be fully satisfied until W-B / W-C leaves exist. W-A ships the runner mechanism + a shape-check that the flags plumb correctly (TC-RGH-011, TC-RGH-020, TC-RGH-021, TC-RGH-022). The end-to-end AC3 fixture rides W-B's first PR.
