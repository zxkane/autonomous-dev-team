# Design: codex severity extraction scores the wrong text (issue #481)

> **Spec revision 2** (operator, applied mid-implementation): this design
> reflects the FINAL mechanism after the issue's operator posted a
> pre-merge ambiguity review. Two deltas from the original issue body:
> R1 must branch on `AGENT_VERDICT_SOURCES[$_i]` — a real, branchable
> per-agent flag — rather than "prefer the body when non-empty"; R2 must
> locate a structural `user`→echo→trace→`codex` turn-marker boundary in the
> combined `codex review` capture, not the finding-tag boundary the
> malformed-prompt-echo detector (INV-73) uses. Both are reflected below.

## Problem

`autonomous-review.sh`'s pre-aggregation severity ratchet (issue #449 R1,
INV-129) picks the text it scores per agent right before calling
`_review_extract_highest_severity`:

```bash
if [[ "${AGENT_NAMES[$_i]}" == "codex" && -n "${AGENT_CODEX_LOGS[$_i]:-}" && -f "${AGENT_CODEX_LOGS[$_i]}" ]]; then
  _sev_text=$(cat -- "${AGENT_CODEX_LOGS[$_i]}" 2>/dev/null || true)
else
  _sev_text="${AGENT_VERDICT_BODIES[$_i]:-}"
fi
```

For a codex member with a captured stdout file, this ALWAYS scores the raw
`codex review` combined stdout/stderr capture — even when the agent's
verdict was actually resolved from a validated verdict ARTIFACT or the
ordinary comment-poll path, both of which already produced a clean rendered
findings body in `AGENT_VERDICT_BODIES[i]`. The raw capture, per
`_run_codex_review`, has the shape `<CLI header> → <user turn marker> →
<echoed prompt, dozens of untagged numbered instruction/checklist lines> →
<reasoning/tool trace> → <codex turn marker(s)> → <final response>`.
`_review_extract_highest_severity`'s per-finding fail-safe scan (added by
issue #449 to stop a correctly-tagged low-severity finding from masking a
genuinely untagged one) sees the echoed checklist's untagged numbered lines
and collapses the WHOLE scan to `none` — regardless of what severity tags
the agent's actual final response carried.

`none` always blocks (`shouldBlockFinding`'s fail-safe default), so:
- R1's ratchet never demotes a codex verdict resolved this way, ever.
- `_aggregate_has_p0p1_fail` treats `none` as P0/P1-class (by design — an
  unscoreable finding must never be excluded from the terminal floor), so
  INV-127's round-cap counter advances even on a P2-only round, and
  eventually trips with a false "P0/P1 floor is still failing" report.

## Root cause

The call site picks its input by **agent identity** (`codex` vs not), not by
**how the verdict was actually resolved**. Every other agent scores
`AGENT_VERDICT_BODIES[i]` — the rendered findings text, whichever channel
produced it. Codex is special-cased to score its raw stdout unconditionally,
even on the artifact-resolved / comment-poll-resolved paths where a clean,
already-rendered body is sitting right there in `AGENT_VERDICT_BODIES[i]`.

## Fix

**R1 — branch on `AGENT_VERDICT_SOURCES`, never parsed logs.** A NEW,
distinct value — `codex-stdout-fallback` — is assigned into
`AGENT_VERDICT_SOURCES[$_i]` at the EXACT call site in `autonomous-review.sh`
where `_codex_review_classify_stdout` supplies the verdict (the legacy
stdout-classify route, INV-62) — a real, branchable per-agent array entry,
not a log line. The severity call site then branches on that value
explicitly:

```bash
if [[ "${AGENT_VERDICT_SOURCES[$_i]:-}" == "codex-stdout-fallback" && -n "${AGENT_CODEX_LOGS[$_i]:-}" && -f "${AGENT_CODEX_LOGS[$_i]}" ]]; then
  _sev_text=$(_codex_review_strip_prompt_echo "${AGENT_CODEX_LOGS[$_i]}")
else
  _sev_text="${AGENT_VERDICT_BODIES[$_i]:-}"
fi
```

Every OTHER resolution channel — `artifact`, `artifact-malformed` (never
reaches this point live), `comment-fallback`, or a codex agent that
self-posted through the ordinary poll loop — falls into the `else` branch
and scores `AGENT_VERDICT_BODIES[i]`, identical to the non-codex path. This
is a strict narrowing versus a body-emptiness check: it is possible (though
not the live-path norm) for `AGENT_VERDICT_BODIES[i]` to be non-empty on the
stdout-fallback route too (the wrapper's own composed post), but that body
is NOT what gets scored — the raw capture, stripped, is — because the
resolution-channel flag is the authority, not body presence.

**R2 — harden the stdout fallback with structural turn-marker stripping.**
New helper `_codex_review_strip_prompt_echo` (`adapters/codex.sh`, sibling
to `_codex_review_stdout_is_malformed`). The boundary is located in three
validated steps:

1. **Validate a leading CLI header** — reuses `_codex_review_stdout_is_malformed`'s
   own established signals (the `OpenAI Codex v…` banner as the capture's
   first non-empty line, OR the `workdir:`+`model:`+`provider:` triple in
   the contiguous leading region). No header at all → fail-safe, whole
   capture unchanged.
2. **Locate the FIRST standalone `user` turn-marker line** (column 0, exact
   word, nothing else on the line, outside any fenced block) — this is the
   header's OWN marker, immediately bounding it. Never the LAST `user` line:
   reviewed file content or tool-execution output quoted later in the
   capture could legitimately contain a bare `user` word (the "over-
   stripping" hazard the revised issue calls out), and searching for the
   last one would silently truncate real findings text. No `user` marker
   after a validated header → fail-safe, whole capture unchanged.
3. **Locate the LAST standalone `codex` turn-marker line** after that `user`
   marker (same column-0/exact-word/unfenced discipline) — a `codex review`
   turn typically emits several `codex`-role turns (reasoning, tool calls,
   final response); the LAST one bounds the FINAL response, which is the
   only text that should ever be scored (an earlier reasoning/tool-trace
   turn is not the agent's verdict). No `codex` marker found → fail-safe,
   whole capture unchanged.

Only text STRICTLY AFTER that last `codex` marker is returned. The
fenced-block exclusion (mirroring `_echo_region`'s own established
discipline) means a reviewed diff snippet or tool-output line that happens
to quote the literal words `user`/`codex` inside a fenced block is never
mistaken for a genuine marker — closing the over-stripping gap the revised
issue explicitly requires a fixture for.

**R3 — no scanner change.** `_review_extract_highest_severity` is untouched.
Its per-finding fail-safe (an untagged numbered line collapses the whole
scan to `none`) is exactly what we want it to keep doing — on the RIGHT
input, selected by the RIGHT mechanism.

**R4 — docs.** Amend the pre-aggregation severity section of
`docs/pipeline/review-agent-flow.md` and the INV-127/INV-129 paragraphs in
`docs/pipeline/invariants.md` to state the scored-text source per resolution
path (verdict body for artifact/comment-poll; stripped final response for
the stdout-classify fallback) and record this bug as the motivating
incident. New invariant `INV-132` (INV-131 is already claimed by the
base-branch work) documents the call-site contract itself. INV-126 (the
unrelated timeout-binary invariant) is NOT touched.

## Alternatives considered

- **Widen `_review_extract_highest_severity` to ignore instruction-shaped
  lines.** Rejected — that's a scanner change (explicitly out of scope, and
  risks reintroducing the very untagged-finding-masking bug #449 fixed) when
  the actual defect is at the call site: the wrong text is being handed to a
  scanner that is behaving exactly as designed.
- **Branch on body-emptiness instead of an explicit `AGENT_VERDICT_SOURCES`
  flag (round-1 draft of this fix).** Rejected by the issue's own
  spec-revision-2 operator review: body-emptiness is an indirect proxy for
  "which channel resolved this verdict" and is fragile if a future change
  populates a body on the stdout-fallback route too (which the wrapper's own
  composed-post-then-refetch flow already does) — an explicit, real
  branchable flag set exactly where the resolution happens is the correct
  mechanism.
- **Strip the echo based on the finding-tag boundary (round-1 draft,
  reusing `_echo_region`'s grammar verbatim).** Rejected — that boundary is
  "the first tagged/JSON finding line," which happens to work for a
  wrapper-authored prompt's checklist shape but is not actually where the
  echoed PROMPT ends in a real `codex review` transcript; the transcript's
  own `user`/`codex` role structure is the authoritative, CLI-defined
  boundary and is what the revised issue specifies.
- **Strip at `_codex_review_compose_body` composition time (round-1
  follow-up fix, addressing a gap where the severity call site's fallback
  branch was unreachable on the live path).** Superseded by R1's explicit
  `AGENT_VERDICT_SOURCES` branch: because the severity call site now keys on
  the resolution-channel FLAG rather than body-emptiness, the
  `codex-stdout-fallback`-tagged branch always fires for that route
  regardless of whether a body happens to exist — so the composed body
  (still un-stripped, deliberately — R2 scopes stripping to severity scoring
  only, not the human-facing comment) is never scored, and the round-1
  reachability gap does not apply to this mechanism.

## Test plan

See `docs/test-cases/codex-severity-extraction.md` (`TC-SEVEXT-NNN`,
`TC-CXSTRIP-NNN`).
