# Design: structured AC-coverage artifact for the review fan-out (INV-47, #183)

> Follow-up to #182 (INV-46). Scope: **command-mode E2E only.** Browser-mode
> evidence stays free-form by nature and is explicitly out of scope.

## Problem

Post-#182, the command-mode E2E runs once in a dedicated wrapper lane
(`lib-review-e2e.sh::_run_command_e2e_lane`) and posts a SHA-bound markdown
evidence comment. The N fan-out review agents then **LLM-parse that free-form
markdown table** to double-check acceptance-criteria coverage against the issue
body.

LLM parsing of a free-form table is the weak link on the auto-merge gate: a
re-worded header, a merged cell, or a truncated row can make the double-check
miss a *failing* criterion — a false-negative that lets a non-covering PR slip
through the review.

The evidence parser **already computes** per-criterion pass/fail when it builds
the markdown table (see `references/e2e-command-mode.md` — "A summary table
mapping each acceptance-criterion item from the issue body to a verifiable
result"). The information exists; it just isn't exposed machine-readably.

## Goal

Let the parser **optionally** emit a structured AC-coverage artifact (a JSON map
`{ "<criterion-id-or-text>": "pass" | "fail", ... }`) alongside the markdown
block. The wrapper extracts + validates it and hands it to the review fan-out so
the agents verify AC coverage **deterministically** from the map instead of
LLM-parsing the markdown.

Three hard requirements:

1. **Optional / back-compat.** A parser that does NOT emit the artifact yields
   the exact post-#182 free-form double-check — byte-for-byte, no regression.
2. **Fail-safe, not fail-open.** A malformed artifact (invalid JSON, not an
   object, wrong value domain) is logged and the wrapper falls back to the
   free-form path. A bad artifact NEVER silently passes the gate.
3. **Command-mode only.** The browser lane is untouched.

## Approach

### 1. Emission contract (parser-side, opt-in)

The parser keeps writing its markdown evidence block to stdout. To expose the
structured map without a second file-path handshake and without disturbing the
rendered comment, the parser embeds the JSON inside an HTML-comment fence in the
**same stdout**:

```
<!-- ac-coverage:begin
{ "raw.json has >= 3 clusters": "pass", "verified.json has >= 3 speakers": "fail" }
ac-coverage:end -->
```

- HTML comments render invisibly, so the posted evidence comment stays readable.
- The fence travels with the evidence block into the PR comment, so the artifact
  is recoverable on the idempotent reuse path (a SHA-matching comment from a
  prior tick) exactly the same way as on a fresh run.
- A parser that omits the fence changes nothing — the extraction returns empty
  and the wrapper uses the free-form path.

JSON shape: a flat object whose keys are criterion ids/text and whose values are
the strings `"pass"` or `"fail"`. Any other shape is rejected (fail-safe).

### 2. Extraction + validation (wrapper-side, in the command lane)

A new pure helper `_extract_ac_coverage_artifact` lives in `lib-review-e2e.sh`
(unit-testable in isolation, mirrors `_classify_e2e_gate` / `_fetch_sha_evidence`):

```
_extract_ac_coverage_artifact <text>   # echoes validated compact JSON, or empty
```

- Slices the bytes between `ac-coverage:begin` and `ac-coverage:end` (awk).
- Validates with `jq`: must parse, must be an object, every value must be
  exactly `"pass"` or `"fail"`. On any failure echoes empty + returns 0
  (fail-safe — the caller treats empty as "no artifact, use free-form").
- When `jq` is unavailable, returns empty (fall back) — never crashes.

The command lane calls it after the parser produces the evidence block (fresh
run) and after `_fetch_sha_evidence` returns a reused comment (reuse path). The
validated JSON (or empty) is written to a sidecar:

```
/tmp/e2e-ac-coverage-${PR_NUMBER}.json
```

The lane writes the sidecar even when empty (truncates a stale one) so a prior
round's artifact never leaks into a round whose parser stopped emitting it.

### 3. Flow to the review fan-out

The wrapper exports `E2E_AC_COVERAGE_FILE=/tmp/e2e-ac-coverage-${PR_NUMBER}.json`
into the fan-out environment (command-mode only). `build_review_prompt`:

- When the sidecar exists AND is non-empty: inject a **"prefer the structured
  AC-coverage map"** block. The agent reads the map (deterministic), checks each
  issue AC against it, and only falls back to reading the comment for criteria
  absent from the map.
- When the sidecar is missing/empty: the existing #182 free-form
  `## E2E Evidence — READ AS INPUT` block is emitted unchanged.

The structured-map block is purely additive guidance to the same review agents;
it does not change the E2E hard gate, the verdict attribution, or the
aggregation. The gate (`_classify_e2e_gate`) is unchanged — the artifact is a
*review double-check* aid, not a new gate signal.

## Why not a separate sidecar file from the parser?

A second parser-output file would need a new config field, a new path contract,
and a new failure mode (file written but evidence post failed, or vice-versa).
Embedding the JSON in the evidence stdout reuses the existing single-output
contract and the existing SHA-bound comment as the durable carrier, so the
reuse path gets the artifact for free. Simpler, fewer moving parts.

## Fail-safe matrix

| Parser emits | jq validates | Result |
|---|---|---|
| no fence | — | empty sidecar → free-form path (back-compat) |
| valid JSON object, pass/fail values | yes | sidecar has compact JSON → structured-map prompt block |
| invalid JSON / not object / bad values | no | log warning, empty sidecar → free-form path (fail-safe) |
| fence present, jq missing | — | empty sidecar → free-form path (no crash) |

A malformed artifact never reaches the agents as "structured" and never bypasses
the free-form double-check, so it cannot silently pass the gate.

## Out of scope

- Browser-mode structured equivalent (browser evidence is free-form by nature).
- Changing the E2E hard gate to consume the map (the gate stays the dual-signal
  rc+evidence decision from INV-46).
