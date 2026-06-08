# Test Cases: `post-verdict.sh` deterministic verdict helper (issue #202)

Covers the new `skills/autonomous-dispatcher/scripts/post-verdict.sh` helper and
the three `build_review_prompt` routing spots in `autonomous-review.sh`.

Test scripts:
- `tests/unit/test-post-verdict.sh` — helper behavior (stubbed `gh`).
- `tests/unit/test-autonomous-review-verdict-via-helper.sh` — prompt source-of-truth.

## Helper behavior — `tests/unit/test-post-verdict.sh`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PV-01 | PASS verdict, body file → composed body captured via stubbed `gh` | Body contains the agent's text AND ends with both trailer lines: `` Review Session: `<sid>` `` and `Review Agent: <name>` |
| TC-PV-02 | PASS verdict, body that does NOT start with `Review PASSED` | First line begins with `Review PASSED` (helper prepends the canonical prefix) so `_classify_verdict_body` matches |
| TC-PV-03 | FAIL verdict, body that does NOT start with `Review findings:` | First line begins with `Review findings:` (helper prepends) |
| TC-PV-04 | PASS verdict, body ALREADY starts with `Review PASSED` | First line not duplicated — exactly one `Review PASSED` prefix |
| TC-PV-05 | FAIL verdict, body ALREADY starts with `Review findings:` | Not duplicated |
| TC-PV-06 | Stubbed `gh` exits non-zero | Helper exits non-zero (≠0), error surfaced on stderr |
| TC-PV-07 | Stubbed `gh` succeeds, prints a comment URL | Helper exits 0 AND echoes the URL on stdout |
| TC-PV-08 | Body via stdin (`-` for body-file arg) | Same trailer + first-line guarantees as a file body |
| TC-PV-09 | Multi-line body with backticks/quotes/`$()` | Posted verbatim as DATA (the helper forms the gh call from a file, not an argv string) — no mangling, special chars preserved |
| TC-PV-10 | Invalid issue number (non-numeric) | Exit 2, usage/error on stderr, no gh call |
| TC-PV-11 | Invalid verdict (not pass/fail) | Exit 2 |
| TC-PV-12 | Unreadable / missing body file | Exit 2 |
| TC-PV-13 | Trailer uses the EXACT phrasing the poller + wrapper attribution expect | `` Review Session: `<sid>` `` (backtick-wrapped sid) and `Review Agent: <name>` literal lines |
| TC-PV-14 | `verdict` arg is case-insensitive (`PASS` / `Fail`) | Treated as pass/fail |
| TC-PV-15 | Posts via the token-refresh proxy `gh` (NOT bare gh) | The helper invokes `gh issue comment <n> --repo <REPO>` (script-dir gh, resolved through the wrapper) |

## Prompt source-of-truth — `tests/unit/test-autonomous-review-verdict-via-helper.sh`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-PVP-01 | Decision PASS branch references the helper | `build_review_prompt` body mentions `scripts/post-verdict.sh` in the PASS-branch instruction |
| TC-PVP-02 | Decision FAIL branch references the helper | Same for the FAIL branch |
| TC-PVP-03 | INV-55 codex-inline-diff block defers to the helper | The codex "post your verdict comment in THIS turn" / "post the verdict in as few turns" language points at `post-verdict.sh` (no loose bare-gh verdict post on the codex lane) |
| TC-PVP-04 | The verdict-post instruction explicitly FORBIDS bare `gh issue comment` for the verdict | Prompt body says do NOT use bare `gh issue comment` for the verdict |
| TC-PVP-05 | First-line phrasing preserved | Prompt still mentions `Review PASSED` and `Review findings:` so the poller match is unchanged |
| TC-PVP-06 | No per-CLI branch for the verdict post | The `post-verdict.sh` instruction is not gated on a specific `_agent_name`; it applies to all agents (rendered identically for codex and a non-codex agent) |

## Notes / acceptance mapping

- TC-PV-01/02/03/04/05/13 ⇒ AC "composes the trailer" + first-line preservation.
- TC-PV-06/07 ⇒ AC "exits non-zero on post failure, echoes confirmation on success".
- TC-PV-09 ⇒ the actual fix mechanism: structured args / body file sidestep agy's
  bare-`gh issue comment` mis-escaping.
- TC-PVP-* ⇒ AC "all three verdict-post spots route through the helper; bare gh forbidden".
