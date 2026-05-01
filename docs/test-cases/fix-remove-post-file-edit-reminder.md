# Test Cases: Remove post-file-edit-reminder Hook

## Scope

Guards the removal so the hook cannot be silently re-introduced without an
accompanying test update.

## Cases

### TC-PFER-001 — Hook script is absent
- **Given** `skills/autonomous-common/hooks/`
- **Expect** `post-file-edit-reminder.sh` does not exist
- **Why** The hook was removed in issue #51 due to per-edit noise and
  redundancy with SKILL.md + blocking hooks.

### TC-PFER-002 — No hook registration in Claude Code settings
- **Given** `.claude/settings.json`
- **Expect** No reference to `post-file-edit-reminder`
- **Why** A registration without a matching script would log errors on every
  edit. Removal must be complete on both sides.

### TC-PFER-003 — No hook registration in Kiro CLI config
- **Given** `.kiro/agents/default.json`
- **Expect** No reference to `post-file-edit-reminder`

### TC-PFER-004 — SKILL.md hook config no longer lists the script
- **Given** `skills/autonomous-dev/SKILL.md`
- **Expect** No reference to `post-file-edit-reminder`
- **Why** SKILL.md documents the canonical hook registration; leaving the
  entry would encourage consumers to re-install a deleted script.

### TC-PFER-005 — Settings files remain valid JSON
- **Given** `.claude/settings.json` and `.kiro/agents/default.json` after
  removal
- **Expect** Both parse via `python3 -m json.tool` (or `jq .`)
- **Why** Hand-editing JSON risks trailing commas or stray brackets. Parse
  validation catches that at test time instead of at hook-load time.

## Out of scope

- E2E: triggering an Edit in a live session and observing no reminder. The
  absence assertions above are sufficient — if the script and all
  registrations are gone, no reminder can fire.
- Documentation table rows (README.md, hook README, SKILL table). These are
  human-maintained reference material; inconsistency there would be a docs
  drift, not a behavioral bug.
