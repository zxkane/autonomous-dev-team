# Design: strip control chars from agy `--model` before validate/forward (PR #192 re-port)

## Problem

[INV-50](../pipeline/invariants.md#inv-50-agy---model-is-validated-against-agy-models-before-forwarding)
validates a resolved agy model id against `agy models` via `grep -Fxq` before
forwarding `--model`. `grep -Fxq`'s **pattern** side splits on embedded
newlines into separate fixed-string, whole-line patterns. A model value like

```
"Gemini 3.5 Flash (High)\nGemini 3.5 Flash (Low)"
```

is really two patterns; if either matches a listing line, `_agy_known_model`
returns 0 — so a composite/injected value can validate even though it is not
itself a listed model, and the **raw** value (embedded newline intact) would
then be forwarded to agy's `--model` argv. A trailing `\r` has the same
bypass shape against a CRLF `agy models` listing.

Originally filed and fixed as PR #192 (`fix/agy-newline-injection`), whose
final reviewed commit (`6bbcf06`) also hardened the newline-only strip to the
full `[[:cntrl:]]` class (covers `\r` too) and switched the enum-failure
sentinel to a `\x01`-wrapped form. #192 is now `CONFLICTING`/`DIRTY` against
`main`: it edited `_agy_known_model` / `_agy_build_model_args` in
`lib-agent.sh`, but PR #232 ([INV-75], merged after #192 was opened) relocated
both functions into `skills/autonomous-dispatcher/scripts/adapters/agy.sh`.
This PR re-applies #192's already-reviewed fix at the new location; no new
review round is needed since the code is byte-identical to #192's final state,
just moved.

## Fix

In `adapters/agy.sh`:

- `_agy_known_model`: strip `model="${model//[[:cntrl:]]/}"` before the
  `grep -Fxq` check.
- `_agy_build_model_args`: strip the SAME class up-front, before calling
  `_agy_known_model`, so the value that validates is the exact value forwarded
  as `--model`. Without this, a value that validates (having been stripped
  inside `_agy_known_model`'s own local copy) would still forward its original
  un-stripped form.
- Enum-failure sentinel changed from `\x01enum-failed\x01` to
  `\x01__ENUM_FAILED__\x01` (readable in logs, still un-typeable — no real
  `agy models` line can collide with it).

This mirrors the [INV-60](../pipeline/invariants.md#inv-60-the-review-model-is-shown-inline-on-every-verdict-comments-review-agent-line)
`[[:cntrl:]]` guard already used in `post-verdict.sh` for the same reason (a
control char in a rendered field can forge a line break in structured output).

## Non-goals

- No behavior change for any non-`agy` CLI (all forward `--model` verbatim,
  unaffected).
- No change to the enumerated-but-unknown / enumeration-failure resolution
  paths (INV-50 rules 2/3) — only the validate/forward value is sanitized.

## Verification

- `tests/unit/test-lib-agent-agy.sh` — AGY-06e/06e2 (behavioral: `run_agent`
  forwards a sanitized value for a trailing `\n` / `\r`), TC-AGYM-KM (adds an
  embedded-newline-injection case → rc 1), TC-AGYM-BM/BM2 (unit: verify the
  exact forwarded array element).
- `bash -n` + `shellcheck -S error` clean on `adapters/agy.sh` and the test
  file.
- Full `tests/unit/test-lib-agent-agy.sh` suite green (66/0); regression sweep
  on `test-lib-review-agy.sh` (36/0), `test-autonomous-review-per-agent-model.sh`
  (53/0), `test-cli-adapters.sh` (44/0).
- Confirmed load-bearing: reverting the adapter to the pre-fix (current main)
  content reproduces exactly the failure this PR closes — 5 of the new/updated
  assertions fail (AGY-06e, AGY-06e2, TC-AGYM-KM newline-injection,
  TC-AGYM-BM, TC-AGYM-BM2).
