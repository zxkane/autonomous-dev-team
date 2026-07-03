# Test cases — issue #389: classify_recent_review_verdict structural anchor

Bug: with `BOT_LOGIN` and `FALLBACK_SESSION_ID` both empty (the dispatcher
process's permanent reality), `classify_recent_review_verdict` refused to
classify → `verdict=none` → every completed-session `pending-dev` issue parked
at INV-12 despite a genuine bare verdict trailer being present. 4th occurrence
of the BOT_LOGIN-empty class (siblings fixed in #341 rounds 13/15).

Fix: no-actor-signal branch authenticates candidates via an anchored
whole-body trailer match (exact grammar, horizontal-whitespace-only inside the
trailer) instead of refusing; `GH_AUTH_MODE=app` adds an `authorKind` gate.

## Unit (tests/unit/test-classify-recent-review-verdict.sh, `=== #389 ===` block)

| ID | Setup (no actor signal) | Expected |
|---|---|---|
| TC-389-001 | bare whole-body `failed-substantive` trailer after session end | `failed-substantive` (pre-fix: `none`) |
| TC-389-002 | bare trailer with `cause=bot-timeout` | `failed-non-substantive` + cause |
| TC-389-003 | trailer embedded in prose (leading text) | `none` (anchor rejects) |
| TC-389-004 | trailer with trailing prose | `none` (anchor rejects) |
| TC-389-005 | prose-only comment, no trailer | `none` (legacy fallback stays actor-gated) |
| TC-389-006 | two bare trailers, different createdAt | newest wins |
| TC-389-007 | bare trailer BEFORE session end | `none` (time gate holds) |
| TC-389-008 | bare trailer with `dev-actionable=false` | verdict + da=false through anchor |
| TC-389-009 | bare trailer + trailing newline | classified (trailing-tail tolerance) |
| TC-389-010 | two trailers concatenated on one line | `none` (grammar non-crossing pin) |
| TC-389-011 | unknown verdict token, bare body | `none` (verdict whitelist; forger can't invent vocabulary) |
| TC-389-012 | unknown key after valid verdict | `none` (exact token grammar; legacy fallback unreachable) |
| TC-389-013 | token mode: human author, bare trailer | classified (documented residual, pinned) |
| TC-389-014 | app mode: human author, bare trailer | `none` (authorKind gate) |
| TC-389-015 | app mode: [bot] author, bare trailer | classified (fleet fix preserved under gate) |
| TC-389-016 | trailer with newline INSIDE (`review-verdict:\npassed`) | `none` (horizontal-only inner whitespace; closes the jq-passes/grep-fails legacy-fallback hole) |

Existing TC-INV35-CL-001..008 / TC-INV92-CL-001..006 / edge cases: unchanged,
must stay green (BOT_LOGIN-set and FALLBACK_SESSION_ID-set paths untouched).

## Covered invariants

- INV-35 routing table now reachable in the dispatcher process (the
  fleet-park regression); INV-12 park preserved for verdict-less sessions.
- Park-comment guidance corrected (unpark recipe, not the stale-verdict-guard
  violating pending-review flip).
