# #414 AC evidence sweep — DRAFT (operator-posts after merge)

**Purpose.** #420 R6 requires the P3-5 dev agent to author the final
`## Phase-3 AC evidence sweep` comment for parent #414. This file is the
DRAFT the operator posts to #414 after this PR merges — merge-SHA-dependent
CI links are computed post-merge and swapped into the placeholders below.

Do **not** post this comment pre-merge. Ship it in the PR body as the
"AC-sweep comment URL — pending merge" cross-reference (per #420 R6's
"Capture the comment URL in this issue's PR body" clause).

---

## Phase-3 AC evidence sweep

Parent #414's shipping gate — AC1..AC5 each verified end-to-end with
named evidence.

### AC1 — `run-provider-conformance.sh --itp gitlab --chp gitlab` passes hermetically

**Surface**: CI `unit` job.

**Evidence**: **TC-RGH-060** in `tests/unit/test-provider-conformance-runner.sh`
(landed by #419 P3-4 as the parent #414 AC1 landing gate). The runner-test
assertion is `CONFORMANCE-SUMMARY total=34 pass=32 fail=0 skip=2 pending=0`
— every asserted verb PASSes; the two SKIPs are the durable caps set
(`chp_request_changes` on `rest_request_changes=0`, `chp_trigger_bot` on
`review_bots=0`). The fixture transport hook
`tests/provider-conformance/fixtures/gitlab-hook/gitlab-transport-hook.sh`
(extended by #419 to serve BOTH ITP and CHP endpoints from a single file)
is armed via `--transport-hook`, honoring the [INV-116] single-override-point
contract — `_gl_api` stays lib-owned and enforces the §3.5 fail-CLOSED
pagination + 429/`Retry-After` backoff.

**P3-5's contribution to this AC**: the operator-facing how-to block in
`tests/provider-conformance/README.md` names the same axis invocation +
hook TC-RGH-060 arms, so an operator picking up the suite can reproduce
the axis outside CI without reading the test source.

CI link (post-merge): `<PLACEHOLDER: CI run URL for the merge-of-#420 unit job>`

### AC2 — github/github parity unchanged across P3-1..P3-5

**Surface**: CI `unit` + `spec-drift` per sub-issue.

**Evidence**: TC-PCONF-014 in the same test file (unchanged since W1f)
still asserts `CONFORMANCE-SUMMARY total=31 pass=31 fail=0 pending=0` on
the github/github axis. TC-RGH-050 pins the byte-identical 31-PASS shape.
Every P3-1..P3-5 sub-issue's PR passed CI at merge with those assertions
green.

CI links per sub-issue (post-merge, populated from merge SHAs):
- **P3-1 (#416)**: `<PLACEHOLDER: CI run URL>`
- **P3-2 (#417)**: `<PLACEHOLDER: CI run URL>`
- **P3-3 (#418)**: `<PLACEHOLDER: CI run URL>`
- **P3-4 (#419)**: `<PLACEHOLDER: CI run URL>`
- **P3-5 (#420, this PR)**: `<PLACEHOLDER: CI run URL>`

`spec-drift` (via `tests/unit/test-spec-drift.sh` + `test-provider-spec.sh`)
stays green on the P3-5 merge — the §3.4 CONSUMED-framing prose flip does
not introduce any pending verb-token drift.

### AC3 — P3-1 fixture-transport passes the in-tree GitLab leaves with zero modification

**Surface**: CI `unit` (W-A/W-D tests).

**Evidence**: The out-of-tree transport-hook contract shipped in P3-1
(`--transport-hook` runner flag; `GITLAB_TRANSPORT_HOOK` sourced by the
transport lib; only `_gl_http` overridable per [INV-116]). P3-5's
TC-PCONF-070 exercises that contract end-to-end — the composite hook is
sourced from outside the `providers/` tree (`tests/provider-conformance/fixtures/gitlab-hook/`)
and the runner's isolated PATH is unmodified. The runner's `--itp gitlab
--chp gitlab` axis reaches `fail=0 pending=0` with the ONLY in-tree touch
being the composite hook's location — no `providers/*.sh` modification, no
`lib-gitlab-transport.sh` modification, no runner-lib modification.

CI link (post-merge): `<PLACEHOLDER: CI run URL for TC-PCONF-070>`

### AC4 — cutover guard covers both host-API token classes + `gh-app-token.sh` reconciled

**Surface**: CI guard job.

**Evidence**: [INV-91]'s cutover guard was extended in P3-1 (W-A + W-E
guard-rule half): raw `glab ` (word-boundary) and `/api/v4`-shaped `curl`
outside `providers/lib-gitlab-transport.sh` = strict-from-zero FAIL. The
five legitimate GitHub App JWT-mint `curl` sites in
`skills/autonomous-dispatcher/scripts/gh-app-token.sh` are reconciled via
shape-exclusion (App-mint JWT curl → api.github.com, not `/api/v4`), so
the guard passes both token classes without allowlist churn. The gh
baseline stays shrink-only.

CI link (post-merge): `<PLACEHOLDER: guard job URL>`

### AC5 — GitLab `.caps` values evidence-backed + conformance SKIP/assert split matches manifest

**Surface**: human review gate at each sub-issue's dual pre-implementation
review + the CI-checkable half.

**Evidence — human review half**: Each of P3-2 (`itp-gitlab.caps`), P3-3
(`chp-gitlab.caps` seven read-verb caps), and P3-4 (`chp-gitlab.caps` write-verb
caps) shipped its caps table in the PR body with per-key API-doc citations
or recorded probes. Dual pre-implementation review confirmed the evidence
for every asserted cap value at each sub-issue.

Evidence tables cited (PR-body links, post-merge):
- **P3-2 (#417 caps evidence table)**: `<PLACEHOLDER: PR-body deep link>`
- **P3-3 (#418 caps evidence table)**: `<PLACEHOLDER: PR-body deep link>`
- **P3-4 (#419 caps evidence table)**: `<PLACEHOLDER: PR-body deep link>`

**Evidence — CI-checkable half**: The conformance runner's SKIP/assert
manifest (`tests/provider-conformance/cap-map.conf` + `coverage.conf`)
matches every `.caps` file's read-back. The runner emits `SKIP (cap: …)`
lines only for caps declared `=0` on the selected provider; every `=1`
cap's verb PASSes or fails-out-loud (never silent-skips). TC-PCONF-070's
SKIP set (`chp_request_changes SKIP (cap: rest_request_changes)`) is the
only cap-driven SKIP on the gitlab axis, matching `chp-gitlab.caps`'s
`rest_request_changes=0`.

---

## AC divergences (fill in only if any AC is not verifiable as declared)

None expected. If a divergence surfaces post-merge (e.g. a merge-SHA CI
link revealing an unexpected FAIL), name it here rather than papering
over the AC. Follow the pattern:

> **AC-N divergence**: `<one-sentence description>`. Cause:
> `<one-sentence attribution>`. Follow-up: `<link to filed follow-up
> issue OR PR>`.

---

## Cross-references

- Parent tracking: #414.
- Sub-issue chain (all merged before this comment lands): #416 (P3-1
  transport + W-D early), #417 (P3-2 itp-gitlab), #418 (P3-3 chp-gitlab
  reads), #419 (P3-4 chp-gitlab writes + AC1 landing), #420 (P3-5
  config/docs + this AC sweep).
- W-F (agent-prompt heredoc parameterization) is filed as its own tracking
  successor; it is NOT gated by #414 AC1..AC5 — those close on P3-4's
  `pending=0` axis + P3-5's config/docs surface.
