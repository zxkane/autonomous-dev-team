# Design: structured AC-coverage artifact for the review fan-out (INV-49, #183)

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

The validation contract lives in one shared pure helper in `lib-review-e2e.sh`
(unit-testable in isolation, mirrors `_classify_e2e_gate` / `_fetch_sha_evidence`):

```
_validate_ac_coverage_json            # stdin JSON → canonical compact JSON | empty
_extract_ac_coverage_artifact <text>  # fence-slice + _validate → compact JSON | empty
_revalidate_ac_coverage_file          # re-read+re-validate the sidecar → JSON | empty
```

- `_validate_ac_coverage_json` is the **single source of truth** for the contract:
  reads a candidate JSON on stdin, and with `jq` requires a non-empty flat object
  whose every value is exactly `"pass"` or `"fail"`, emitting the canonical
  compact form (`jq -c`). Any failure echoes empty + returns 0 (fail-safe). When
  `jq` is unavailable it echoes empty (fall back) — never crashes.
- `_extract_ac_coverage_artifact` slices the bytes between the FIRST
  `ac-coverage:begin` / `ac-coverage:end` fence pair (awk; a stray second fence
  is ignored so the result is always a single object) and pipes them through
  `_validate_ac_coverage_json`.

The command lane calls it after the parser produces the evidence block (fresh
run) and after `_fetch_sha_evidence` returns a reused comment (reuse path), via
`_write_ac_coverage_sidecar`, which writes the validated JSON (or empty) to a
sidecar:

```
/tmp/e2e-ac-coverage-${PR_NUMBER}.json
```

- The lane truncates the sidecar at entry and (re)writes it even when empty, so a
  prior round's artifact never leaks into a round whose parser stopped emitting it.
- **Write-failure = no map (codex finding 2).** If the sidecar cannot be made to
  hold exactly this round's artifact (non-writable / chmodded / not truncatable),
  `_write_ac_coverage_sidecar` does NOT swallow the failure — it `unset`s
  `E2E_AC_COVERAGE_FILE` for the rest of the run and logs, so the fan-out reads
  **no** structured map (free-form fallback) rather than a possibly-stale file.

### 3. Flow to the review fan-out — re-validated at prompt-read time

The wrapper exports `E2E_AC_COVERAGE_FILE=/tmp/e2e-ac-coverage-${PR_NUMBER}.json`
into the fan-out environment (command-mode only). `build_review_prompt`:

- Calls `_revalidate_ac_coverage_file`, which re-reads the sidecar's **current**
  bytes and re-runs the same `_validate_ac_coverage_json`. When that returns a
  non-empty object, it injects a **"prefer the structured AC-coverage map"**
  block (the agent reads the map deterministically, checks each issue AC against
  it, and only falls back to the free-form comment for criteria absent from the
  map). Otherwise the existing #182 free-form `## E2E Evidence — READ AS INPUT`
  block is emitted unchanged.
- **Re-validation at prompt-read time is a TOCTOU defense (codex finding 1).**
  The sidecar lives at a predictable, exported `/tmp` path, and PR-controlled
  command-mode `E2E_COMMAND` / parser code runs between
  `_write_ac_coverage_sidecar`'s validation and prompt construction — so it could
  overwrite the file with attacker-chosen content (a prompt-injection / fail-open
  path if the wrapper trusted the bytes with a plain `cat`). Re-validating means
  only a freshly-re-validated, canonicalized object is ever interpolated; a
  now-malformed/replaced sidecar falls back to free-form. The check-and-use is a
  single read inside `build_review_prompt`, so there is no second TOCTOU window.

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

| Condition | Result |
|---|---|
| no fence | empty sidecar → free-form path (back-compat) |
| valid JSON object, pass/fail values | sidecar has compact JSON; re-validated at prompt-read → structured-map block |
| invalid JSON / not object / bad values | log warning, empty sidecar → free-form path (fail-safe) |
| fence present, jq missing | empty sidecar → free-form path (no crash) |
| sidecar truncate/write fails | `E2E_AC_COVERAGE_FILE` unset → free-form path (no stale leak) |
| sidecar overwritten after the lane (TOCTOU) | prompt-read re-validation rejects/canonicalizes → free-form unless it still validates |

A malformed, replaced, or unwritable artifact never reaches the agents as
"structured" and never bypasses the free-form double-check, so it cannot silently
pass the gate.

## Out of scope

- Browser-mode structured equivalent (browser evidence is free-form by nature).
- Changing the E2E hard gate to consume the map (the gate stays the dual-signal
  rc+evidence decision from INV-46).
