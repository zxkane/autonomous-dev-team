# Test Cases — `create-issue` Dependencies guidance

Tracks: issue #120.

## Scenario

The `create-issue` skill's pre-fix Dependencies guidance was too
permissive. LLMs filled the section with parent-epic references,
forward-references ("must merge before #N-B / #N-C"), and meta-tracker
context — anything that contained `#NNN`. The autonomous dispatcher's
`check_deps_resolved` parses the section literally with a regex that
extracts every `#NNN`, so any OPEN issue number found there silently
blocks the issue forever (no error, just skipped on every tick).

The fix tightens three doc sites: the placeholder in
`references/issue-templates.md`, the Writing Guidelines bullet in
`SKILL.md`, and the Multi-Issue Creation step 2 in `SKILL.md`. This
test pins the new wording so future drift trips a regression alarm.

## Test Cases

| ID | Site | Expected text fragment present |
|----|---|---|
| TC-DEPS-001 | `references/issue-templates.md` Dependencies block | HTML comment with `IMPORTANT: List ONLY` |
| TC-DEPS-002 | `references/issue-templates.md` Dependencies block | `parses this section literally` |
| TC-DEPS-003 | `references/issue-templates.md` Dependencies block | `silently skipped` |
| TC-DEPS-004 | `references/issue-templates.md` Dependencies block | explicit `Do NOT list:` enumeration with parent epics, unblocked-by issues, context references |
| TC-DEPS-005 | `references/issue-templates.md` Dependencies block | `If there are no blocking prerequisites, write exactly: None` |
| TC-DEPS-006 | `SKILL.md` Writing Guidelines Dependencies bullet | `parses this section literally` |
| TC-DEPS-007 | `SKILL.md` Writing Guidelines Dependencies bullet | `silently skipped` |
| TC-DEPS-008 | `SKILL.md` Writing Guidelines Dependencies bullet | `Do NOT include` (with the three categories: parent epics, issues this one unblocks, non-blocker references) |
| TC-DEPS-009 | `SKILL.md` Multi-Issue Creation step 2 | `directly blocking` |
| TC-DEPS-010 | `SKILL.md` Multi-Issue Creation step 2 | warning that every `#NNN` is treated as a hard blocker |

## Acceptance

- All TC-DEPS-001..010 pass after the fix
- All fail before the fix (the new strings don't exist on `main` yet)
