# Session knowledge test cases

| Case | Scenario | Expected result |
|---|---|---|
| SK-01 | Completed session has no durable learning | Explicit no-update receipt satisfies Stop; no files or commits |
| SK-02 | Multiple dev/review sessions use linked worktrees | One task ledger, latest stable key wins, earlier independent facts survive |
| SK-03 | HEAD changes after assessment | Stop requests a fresh assessment |
| SK-04 | Machine-specific learning | Ignored root `AGENTS.local.md`, mode 600, no public candidate |
| SK-05 | Credential literal or public environment identifier | Rejected without echoing the value or persisting the assessment |
| SK-06 | Traversal, code target or symlink | Rejected without touching the destination |
| SK-07 | Confirmed merge with new facts | Scoped Markdown applied in an isolated worktree and committed |
| SK-08 | Incorrect legacy fact | Unique exact paragraph replaced; unrelated guidance preserved |
| SK-09 | Identical fact already documented | No empty commit or PR |
| SK-10 | Legacy fact changed or occurs twice | Writeback stays pending; no partial documentation commit |
| SK-11 | Obsolete/incorrect queued fact | Explicit discard prevents publication; remove deletes only the named managed section |
| SK-12 | Candidate lacks evidence | Rejected |
| SK-13 | Main checkout contains staged user changes | Original index untouched; knowledge commit contains only eligible documentation |
| SK-14 | Repeated apply or publish after failure | Commit reused; existing PR reused; completed receipts skip duplicate work |
| SK-15 | Merge fails, PR is open/closed, or provider state read fails | No knowledge commit or publication |
| SK-16 | Stop in an unrelated session or on an assessed session | Silent success, no model call or repeated reminder |
| SK-17 | Hook installers | New hook appears in translated Stop definitions |
| SK-18 | Failed push or PR creation | Durable committed receipt remains available for manual retry |
