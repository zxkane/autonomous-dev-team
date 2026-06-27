# Design Canvas — `docs/pipeline/provider-spec.md` (issue #279)

> Docs-only keystone deliverable. ZERO code / wrapper change. This canvas records
> the structural decisions for the new normative provider spec; the authoritative
> source content is the committed design spec
> `docs/superpowers/specs/2026-06-27-pluggable-issue-and-code-host-providers-design.md`
> (branch `feat/pluggable-providers-spec`).

## Goal

Land `docs/pipeline/provider-spec.md` as the normative contract for the two
pluggable provider seams — Issue-Tracker Provider (ITP, `ISSUE_PROVIDER`) and
Code-Host Provider (CHP, `CODE_HOST`) — mirroring the existing
`adapter-spec.md` / INV-66 precedent. Plus: four provider invariants
(INV-87..INV-90) in `invariants.md`, an abstract-state note in
`state-machine.md`, an INV-77/78 verdict reconciliation, and a single docs-only
validation test.

## Why (no-behavior-change anchor)

This is the first deliverable of the pluggable-providers redesign: **design +
GitHub refactor only, with ZERO behavior change.** The normative contract and the
invariants must land **before** any refactor begins so every downstream issue
(dispatch skeleton + caps reader, ITP/CHP migrations, cutover guard) references a
stable doc without re-deriving it. GitLab / Asana implementation is out of scope.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Doc shape | Mirror `adapter-spec.md` (RFC-2119 header, NORMATIVE banner, numbered sections, Mapping appendix) | Reuse the proven INV-66 precedent; reviewers already know the shape |
| Seams | Two independent config keys `ISSUE_PROVIDER` / `CODE_HOST`, compose freely | Asana-issues + GitHub/GitLab-code requires the two roles be separate seams |
| Verb naming | `itp_*` (13 verbs) / `chp_*` (12 verbs), 1:1 from real `lib-dispatch.sh` fns | Each verb names the exact current function/site it replaces |
| Capabilities | Per-provider `.caps` manifest, key=value, read-not-sourced | Testable under `set -euo pipefail` without the unguarded-source crash mode |
| Comment shape | `[{id, author, body, createdAt}]` + `authorKind`, ascending-`createdAt` MUST | id=INV-46 PATCH path; author=INV-85 exact-equality; order=`\| last` idioms |
| New INV numbers | **INV-87..INV-90** | The issue was authored when INV-85 was max and asked for "next free above INV-85" → it named INV-86..89. PR #278 (issue #277) then merged its own **INV-86** ("PR↔issue binding via `closingIssuesReferences`") on `main` first. So "the next free numbers above INV-85" is now objectively **INV-87..90**, and renumbering back to INV-86 would either DUPLICATE #278's INV-86 (breaking `test-spec-drift.sh`'s unique-heading count) or renumber an *existing* INV (which AC-11 forbids). The two binding AC-11 clauses — "next free numbers" + "NO existing INV renumbered" — both point at INV-87..90; only the now-stale literal "INV-86..89" (premised on INV-85 still being max) does not. Per the Pipeline Documentation Authority rule, the docs/invariant numbering is authoritative; the issue ACs are updated to the post-#278 reality. |
| Triage tags | `_Triage (issue #236): [machine-checked: tests/unit/test-provider-spec.sh]_` | Required by test-spec-drift.sh TC-SPEC-GATE-040/041 (heading-count == tag-count, within 2 lines) |
| State machine | Abstract-state note only; mermaid diagram + transition table UNCHANGED | This PR adds no code-bearing label write → no transitions.json change |
| Verdict channel | Reconcile with the typed-artifact channel: verdict resolves from the typed artifact first (INV-78 — the design-spec's "INV-77"); `itp_post_comment` is the fallback/marker channel | Keeps the INV-dense channel (INV-20/40/53/78) from falling between two specs |
| Test | One docs-validation test modeled on `test-adapter-spec-schemas.sh` | Auto-discovered by ci.yml `for test in tests/unit/test-*.sh`; credential-free |

## Out of scope

No provider code (no `lib-issue-provider.sh`, `lib-code-host.sh`,
`providers/*`, no `.caps` manifest file); no gh-call-site refactor; no GitLab /
Asana impl; no adapter / `adapter-spec.md` change beyond cross-reference links;
no state-machine semantics change (`transitions.json`, `spec-*-map.json`
untouched); no new entry-point script; no runtime provider tests (golden-trace /
capability-branch / dispatch-routing gate the code-bearing sibling issues).

## Files touched

- `docs/pipeline/provider-spec.md` — NEW normative file.
- `docs/pipeline/invariants.md` — add INV-87..INV-90.
- `docs/pipeline/state-machine.md` — add abstract-state note (diagram unchanged).
- `tests/unit/test-provider-spec.sh` — NEW docs-validation test.
- `docs/designs/provider-spec.md` — this canvas (review-checklist requirement).
- `docs/test-cases/provider-spec.md` — test-case doc (review-checklist requirement).
