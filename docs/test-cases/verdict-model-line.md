# Test cases: show the review model on every verdict comment (INV-60)

Issue: #208. Invariant: [INV-60](../pipeline/invariants.md). Related:
[INV-56], [INV-41], [INV-40], [INV-20], [INV-04].

All regression tests **FAIL before** the change and **PASS after**.

Run CI-equivalently (the dispatcher box exports `PROJECT_DIR`, which would pull
in the live `autonomous.conf`):

```bash
env -u PROJECT_DIR bash tests/unit/test-post-verdict.sh
env -u PROJECT_DIR bash tests/unit/test-autonomous-review-verdict-via-helper.sh
```

## No E2E

This is a pure wrapper/helper/prompt + doc change. There is **no deployed
resource** whose behavior changes — the verdict comment is composed entirely by
the `post-verdict.sh` shell helper and the wrapper-rendered prompt. **No E2E
test is required or applicable.**

## `tests/unit/test-post-verdict.sh` (extends the TC-PV-NN series)

| TC | Scenario | Expected |
|----|----------|----------|
| TC-PV-17 | 6th arg present (`claude-sonnet-4.6`) | trailer line is exactly `Review Agent: kiro (model: claude-sonnet-4.6)`; exit 0 |
| TC-PV-18 | 6th arg omitted | trailer line is exactly `Review Agent: kiro` — byte-for-byte the pre-change output (backward compatibility); the parenthetical does NOT appear |
| TC-PV-19 | 6th arg explicit-empty (`""`) | same as omitted: `Review Agent: kiro`, no parenthetical |
| TC-PV-20 | model id with spaces + parens (`Gemini 3.5 Flash (High)`) | accepted; rendered verbatim → `Review Agent: agy (model: Gemini 3.5 Flash (High))`; exit 0 |
| TC-PV-21 | model id with a control char — newline (a/b) OR carriage return (c/d) | rejected → exit 2 (either would split the single-line trailer / forge a second `Review Agent:` line); no gh call |
| TC-PV-22 | model id over the length cap | rejected → exit 2 |
| TC-PV-23 | with 6th arg, the `Review Session:` line + first-line `Review PASSED` / `Review findings:` guarantees are unchanged | both present and correct |
| TC-PV-24 (discriminator) | [INV-40] predicate `test("Review Agent: kiro")` against the new line `Review Agent: kiro (model: claude-sonnet-4.6)` | matches (substring test); validated against **real `gh --jq`** Go RE2 where available, skipped otherwise |

## `tests/unit/test-autonomous-review-verdict-via-helper.sh` (extends TC-PVP-NN)

| TC | Scenario | Expected |
|----|----------|----------|
| TC-PVP-07 | all three concrete `post-verdict.sh` invocations in the rendered prompt | each carries a 6th model arg after `<session-id>` |
| TC-PVP-08 | the model 6th arg value | equals the per-agent resolved model (`_resolve_review_agent_model` → `:-sonnet`) for the rendered agent |
| TC-PVP-09 | per-agent override set (`AGENT_REVIEW_MODEL_KIRO=claude-sonnet-4.6`) | the rendered 6th arg is `claude-sonnet-4.6`, not the shared default |
| TC-PVP-10 | rendered for a codex agent AND a non-codex agent | the 6th-arg model is present identically in BOTH (no per-CLI branch); each agent's value is ITS resolved model |
| TC-PVP-11 | no model configured | the rendered 6th arg is `sonnet` (the launch default), matching the `Reviewed HEAD:` trailer + `run_agent` launch arg |
| TC-PVP-12 | a per-agent model with spaces + parens (`Gemini 3.5 Flash (High)`) | the rendered 6th arg is **single-quoted** (`'Gemini 3.5 Flash (High)'`) in every invocation so an agent copying it verbatim passes it as ONE token — not split into args 6/7/8 (truncating to `(model: Gemini)`) nor a bash syntax error on `(` |
| TC-PVP-12b | the rendered multi-word-model example | actually parses (eval against a stub) and arrives at `post-verdict.sh` as a single `$6` |

## Backward-compat gate (must stay green)

- `tests/unit/test-post-verdict.sh` TC-PV-01..16 (unchanged behavior when no 6th arg)
- `tests/unit/test-autonomous-review-verdict-via-helper.sh` TC-PVP-01..06
- `tests/unit/test-autonomous-review-per-agent-model.sh` (INV-41 resolution untouched)
- `tests/unit/test-autonomous-review-multi-agent.sh` (INV-40 attribution untouched)
