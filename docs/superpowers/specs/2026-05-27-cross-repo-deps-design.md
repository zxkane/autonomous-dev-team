# Cross-repo dependency support in `check_deps_resolved`

**Issue**: #157
**Author**: zxkane
**Date**: 2026-05-27
**Status**: approved

## Problem

`check_deps_resolved` (`skills/autonomous-dispatcher/scripts/lib-dispatch.sh:286`) parses the `## Dependencies` section of an issue body by greedy-extracting every `#NNN` substring between the `## Dependencies` heading and the next `## ` heading, then looking each one up in the **current repo** via `gh issue view N --repo "$REPO"`.

Two failure modes follow from this:

1. **Cross-repo refs are silently treated as unresolved.** `owner/repo#NNN` in the section yields a bare `NNN`, queried against `$REPO`. If no such issue exists locally, `gh issue view` returns non-zero, the surrounding `|| true` swallows the error, `$state` is empty, and `[ "$state" != "CLOSED" ]` is true → the issue is **blocked forever**, with no log line and no comment to surface the cause.
2. **Prose/blockquote false positives.** The regex `grep -oE '#[0-9]+'` matches every `#NNN` substring inside the line range, including ones inside blockquotes (`> requires owner/repo#4470 ...`), inline code (`` `#42` ``), and free-form prose. These leak into the loop and trigger the same silent-block failure if the number doesn't exist in `$REPO`.

The function preserves [INV-11](../../pipeline/invariants.md#inv-11-dependency-state-includes-merged) (MERGED counts as resolved) and the portable extraction fix from PR-4. Both must remain green after this change.

## Goals

- Support `owner/repo#NNN` as a first-class dependency specifier.
- Eliminate prose/blockquote false positives (Option B from #157).
- Preserve INV-11 and #73 portability fixes.
- No behavior change for issues that contain only bare `#NNN` list items.

## Non-goals

- URL-form refs (`https://github.com/owner/repo/issues/N`) — not in #157's acceptance criteria.
- GitLab / Bitbucket cross-host refs.
- Inline-code stripping (` `#42` ` on a list-item line is still extracted) — acceptable per #157 acceptance criteria; can be added later if needed.
- Migration of existing issue bodies — old prose-style refs simply stop being parsed, which is the desired outcome.

## Design

### Parser rewrite (`check_deps_resolved`)

Replace the current pipeline with a two-stage parse:

**Stage 1 — restrict scope to list items.** Use `grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]'` to filter the `## Dependencies` section down to lines beginning with a markdown list marker. This drops blockquotes (`> ...`), prose paragraphs, and headings.

**Stage 2 — extract refs with priority.** Per list-item line, scan twice:

1. First, match `owner/repo#NNN` — bash regex `(^|[[:space:]\(])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)`. The leading anchor (start-of-line, whitespace, or `(`) prevents matching inside larger tokens like `https://github.com/owner/repo#NNN`. Each hit fires `gh issue view NNN --repo owner/repo`. Strip the matched substring from the line before continuing.
2. Then, match bare `#NNN` — bash regex `(^|[[:space:]\(])#([0-9]+)`. Each hit fires `gh issue view NNN --repo "$REPO"` (existing same-repo behavior).

State check is unchanged: `state ∉ {CLOSED, MERGED}` returns 1.

Stripping the matched substring after each hit is what makes "match owner/repo#N first, then bare #N on the residue" work correctly — `owner/repo#42` no longer survives stage-1 to be re-extracted as `#42` in stage 2.

### Tests (`tests/unit/test-check-deps-resolved.sh`)

Mock-`gh` extension: state lookups currently key on issue number. They need to key on `repo:num` so the same number in two different repos resolves independently.

```bash
gh() {
  local mode="" issue_num="" repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      view) issue_num="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --json) [[ "$2" == body ]] && mode=body; [[ "$2" == state ]] && mode=state; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$mode" in
    body)  printf '%s' "$_MOCK_BODY" ;;
    state) printf '%s' "${_MOCK_STATES[${repo}:${issue_num}]:-OPEN}" ;;
  esac
}
```

Existing fixtures migrate to `_MOCK_STATES[zxkane/autonomous-dev-team:42]="CLOSED"` etc. — mechanical change.

New cases (numbered to match the acceptance criteria in #157):

1. **Cross-repo dep, list item, CLOSED in remote** → unblocked.
2. **Cross-repo dep, list item, OPEN in remote** → blocked.
3. **Same-repo `#NNN` embedded in prose between headings** → unblocked (was blocked, the regression #157 is about).
4. **Blockquote `> requires owner/repo#4470 to be merged`** → unblocked.
5. **Mixed list: same-repo `#42` (CLOSED) + cross-repo `owner/repo#7` (OPEN)** → blocked.
6. **Inline-code on a list item: `- waiting on \`#99\` ` ** — extracted (documented limitation; not part of #157 acceptance, but worth a regression note).

The five existing test cases (no-section / single-CLOSED / single-MERGED / single-OPEN / multi-mixed / portable-extract `#73`) continue to pass.

### Pipeline doc updates

Per the project's "Pipeline Documentation Authority" rule, this PR also updates:

1. **`docs/pipeline/invariants.md`** — extend INV-11's status block to mention "extraction is restricted to list items; cross-repo `owner/repo#N` resolves against the named repo." A new invariant (INV-NN) is unnecessary; the parsing rule is a refinement of the same dependency-resolution invariant.
2. **`docs/pipeline/dispatcher-flow.md:165`** — change "Extract every `#N` reference" to "Extract `#N` and `owner/repo#N` references from list items only (prose and blockquotes are ignored)."

## Risks

| Risk | Mitigation |
|---|---|
| Bash 3.2 (macOS default) regex semantics differ from 5.x | Patterns use only POSIX char classes, no backreferences. Verify on macOS as part of test run. |
| Existing issue bodies relying on prose extraction | None known; quick `gh issue list --search 'in:body'` audit on `zxkane/autonomous-dev-team`, `zxkane/podcast-curation`, `zxkane/Panoptes`, `zxkane/VidSyllabus`, `zxkane/llm-wiki`, `zxkane/voicebiz-editorial` to confirm no live issue would change blocked-state. |
| `gh issue view --repo owner/repo` for a private repo the dispatcher token can't see | Returns non-zero like the same-repo case today. The current `|| true`-based silent-block is preserved for unknown / unauthorized — this is no worse than today. Future hardening could surface a comment, but is out-of-scope. |

## Acceptance criteria (verbatim from #157)

- [x] A same-repo dep on a list item (`- #NNN`) is checked in `$REPO` as before.
- [x] A cross-repo dep on a list item (`- owner/repo#NNN`) is checked in `owner/repo`.
- [x] A `#NNN` reference embedded in prose, blockquotes, or inline code between `## Dependencies` and the next heading does not cause a false block.
- [x] `None` (or empty section with no list items) returns 0.
- [x] Unit tests cover same-repo CLOSED/OPEN, cross-repo, prose-embedded, empty.

(Inline code in a *list item* is the one carve-out, called out in Non-goals.)
