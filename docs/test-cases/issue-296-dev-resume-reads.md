# Test cases — issue #296: migrate `autonomous-dev.sh` resume comment-reads behind `itp_list_comments`

Tracks the migration of the two resume-time review-feedback comment scanners in
`skills/autonomous-dispatcher/scripts/autonomous-dev.sh` from raw
`gh issue view --json comments -q '<selector>'` to
`itp_list_comments "$ISSUE" | jq -r '<rewritten selector>'` (issue #296 batch B6,
part of the pluggable-providers raw-`gh` cutover, [INV-87]/[INV-90]/[INV-91]).

## What changed

| Site | Function | Before | After |
|---|---|---|---|
| `:613` (now `:622`) | `emit_post_approval_findings_block` `findings_at` (INV-57) | `gh issue view "$issue_num" --repo "$REPO" --json comments -q '[.comments[] \| select(<recognizer>) \| .createdAt] \| sort \| last // empty'` | `itp_list_comments "$issue_num" 2>/dev/null \| jq -r '[.[] \| select(<rewritten recognizer>) \| .createdAt] \| sort \| last // empty'` |
| `:1051` (now `:1075`) | `REVIEW_COMMENTS` resume-prompt builder | `gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments -q '[.comments[] \| select(<recognizer>)] \| last // empty'` | `itp_list_comments "$ISSUE_NUMBER" 2>/dev/null \| jq -r '[.[] \| select(<rewritten recognizer>)] \| last // empty'` |

Both reads are **shape-equivalent, NOT byte-identical** — two unavoidable changes:

1. **Array shape flattens.** `itp_list_comments` returns the normalized [INV-90]
   array `[{id, author, authorKind, body, createdAt}]` (sorted ascending by
   `createdAt`), so the selector iterates `.[]` instead of gh's `.comments[]`.
2. **Regex engine boundary.** The select moves from gh's embedded jq (Go **RE2**)
   to the system jq (**Oniguruma**). RE2 and Oniguruma diverge on `\b`/`\s`/`(?i)`
   for non-ASCII input, so the selector text is rewritten so it selects
   identically in both engines (= the old RE2 behavior).

The `:613` site is **order-immune** (explicit `| sort` on projected ISO-8601
strings). The `:1051` site's `| last` relies on `itp_list_comments`' ascending,
**stable** `sort_by(.createdAt)` ([INV-90] MUST) — the same guarantee gh's raw
`.comments[]` gave, including the same-second tie-break (later-inserted wins).

## The regex-engine rewrite (the load-bearing correctness work)

| Old (RE2, gh `--jq`) | New (Oniguruma, system `jq`) | Why |
|---|---|---|
| `(?i)(^\|[^A-Za-z-])BLOCKING\b` | `(?i:(^\|[^A-Za-z-])BLOCKING)($\|[^A-Za-z0-9_])` | the case-insensitive scope wraps ONLY the literal; the right boundary `($\|[^A-Za-z0-9_])` is explicit ASCII and stays OUTSIDE `(?i)`. A global `(?i)` would leak into the boundary class so Oniguruma's `(?i)[A-Za-z]` matches Unicode simple-fold chars (`K` U+212A, `ſ` U+017F), diverging from RE2's ASCII `\b`. |
| `\[P1\]` | `(?i:\[P1\])` | scoped; equivalent — brackets/digits have no case. |
| `(?i)^\s*(...)` | `^[ \t\r\n\f]*(?i:...)` | explicit ASCII whitespace (excludes NBSP, matching RE2's `\s`); the `(?i)` scope wraps only the alternation. |

The left boundary `(^|[^A-Za-z-])` stays INSIDE the scoped group (NOT hoisted) so
`KBLOCKING`/`ſBLOCKING` prefix behavior is unchanged.

**Selection-equivalence (not match-span equivalence):** the boolean `select`
result is identical to the old RE2 selector; the explicit right boundary consumes
the boundary char where `\b` did not, but neither site reads the match span (both
project `.createdAt` / `.body`), so this is behavior-preserving.

## Test cases

### Equivalence anchor — the 17 TC-RFB cases (unchanged) run through system jq

`tests/unit/test-resume-review-comments-filter.sh` extracts the live `:1051`
selector and runs all 17 `TC-RFB-001..017` fixtures through the **system jq**
(Oniguruma). The fixtures are unchanged; only the extractor and the fixture
*shape* (normalized array) are retargeted. The selector must select identically
to the pre-migration RE2 selector for every case.

| TC | Scenario | Expected |
|---|---|---|
| TC-RFB-001 | only real findings | picked |
| TC-RFB-002..004 | findings + later dispatcher status (Moving to / Dispatching / no-new-commits) | real findings preferred |
| TC-RFB-005 | only `Review PASSED` | picked |
| TC-RFB-006 | dispatcher chatter only | empty |
| TC-RFB-007 | multiple findings rounds | last wins |
| TC-RFB-008 | mid-sentence "review" mention | does not shadow findings |
| TC-RFB-009..011 | broadened recognition (`## Codex review findings` + `[P1]`, bare operator note) | recognized; token-free status not pulled |
| TC-RFB-012..013 | `NON-BLOCKING` note | does not match (consuming anchor rejects hyphen) |
| TC-RFB-014..016 | `Review PASSED - No BLOCKING`, dev impl status, Agent Session Report | PASS recognized; status not misclassified |
| TC-RFB-017 | exclusion alternation byte-identical across both call sites | drift guard (retargeted to the new `^[ \t\r\n\f]*(?i:...)` form) |

### Engine-divergence regression fixtures (the migration-specific proof)

`tests/unit/test-resume-selector-re2-compat.sh` (retargeted) and
`test-resume-review-comments-filter.sh` run the ACTUAL migrated selector through
system jq across the divergence classes:

| TC | Subject | Expected | Why |
|---|---|---|---|
| TC-DIV-K | `BLOCKING` + `K` (U+212A KELVIN) | SELECTED | RE2 ASCII `\b`: U+212A is non-word → boundary holds |
| TC-DIV-LONGS | `BLOCKING` + `ſ` (U+017F) | SELECTED | same — Unicode simple-fold char must NOT be word-joined |
| TC-DIV-ACCENT | `BLOCKING` + `é` | SELECTED | RE2 treats `é` as non-word |
| TC-DIV-CJK | `BLOCKING` + `中` | SELECTED | RE2 treats `中` as non-word |
| TC-DIV-NBSP | NBSP-prefixed `Moving to …` | SELECTED as finding (NOT excluded-as-status) | RE2 `\s` excludes NBSP, so `^\s*Moving` does not anchor |
| TC-DIV-LOWER-B | lowercase `blocking` | SELECTED | `(?i:)` scope |
| TC-DIV-LOWER-P | lowercase `[p1]` | SELECTED | `(?i:)` scope |
| TC-DIV-NONBLK | `NON-BLOCKING` | NOT selected | left consuming anchor rejects hyphen |
| TC-DIV-PLURAL | `BLOCKINGS` | NOT selected | right consuming boundary rejects trailing letter |

### Same-second-tie test

`tests/unit/test-resume-review-comments-filter.sh` (TC-RFB-TIE): two matching
findings with byte-identical whole-second `createdAt`, inserted A then B →
`:1051`'s `| last` picks B (the later-inserted) via jq's **stable**
`sort_by`; `:613`'s explicit `sort` projects the identical timestamp.

### Static / wiring guards (false-green hazard closed)

- Each extractor asserts the extracted selector is **NON-EMPTY** and matches the
  live migrated assignment **EXACTLY ONCE** (it is not silently extracting a stale
  pattern).
- A **static guard** asserts the 2 old `gh issue view ... --json comments -q`
  sites are GONE from `autonomous-dev.sh`.
- TC-RFB-017 asserts the new exclusion alternation is byte-identical across both
  call sites (distinct variants == 1, occurrences >= 2).

### Host jq assertion

`tests/unit/test-resume-selector-re2-compat.sh` asserts the wrapper-execution host
carries jq >= 1.5 (Oniguruma) — the engine the migrated reads now run under.

## Acceptance criteria mapping

| AC | Test |
|---|---|
| AC1 (both sites via `itp_list_comments \| jq -r`; no raw `gh issue view --json comments`) | static guard in all 3 extractors + `check-provider-cutover.sh` |
| AC2 (17 TC-RFB + divergence fixtures select identically) | `test-resume-review-comments-filter.sh` + `test-resume-selector-re2-compat.sh` |
| AC3 (extractors retargeted, non-empty + unique-live-site + old-site-gone) | all 3 extractors |
| AC4 (same-second tie; `:613` order-immune) | `test-resume-review-comments-filter.sh` TC-RFB-TIE (`:1051` `\| last`) + `test-dev-resume-post-approval-findings.sh` TC-PAF-TIE (`:613` order-immune) |
| AC5 (`cutover-baseline.json` −2; guard exits 0) | `test-provider-cutover.sh` + regenerated baseline |
| AC6 (INV-90/§3.3 stable-sort MUST; INV-91 migration-log bullet) | `test-provider-spec.sh` + `check-spec-drift.sh` |
| AC7 (host jq>=1.5; full suite green) | `test-resume-selector-re2-compat.sh` + CI |
