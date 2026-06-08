# Design: deterministic `post-verdict.sh` for review-agent verdicts (issue #202)

## Problem

Review agents post their verdict comment by hand-rolling a bare `gh issue comment`
inside the agent prompt. This is unreliable across CLIs: the `agy` review agent
**exits 0 claiming it posted the verdict, but the comment never lands** — so the
wrapper's verdict poller (INV-40) finds nothing and drops `agy` as `unavailable`
on every multi-agent review.

Root cause (verified on the #193 review): in the **same** agy run that was dropped
`unavailable`, agy's `bash scripts/mark-issue-checkbox.sh` calls **landed** (a
deterministic helper using `gh api` via the token-refresh wrapper), while agy's OWN
multi-line `gh issue comment` for the verdict **never landed**. Same agent, same
token, same PATH, same run. When agy goes through a deterministic project helper
the gh op succeeds; only its hand-rolled `gh issue comment` (a multi-line `--body`
it mis-forms / mis-escapes) fails.

## Fix

Add a deterministic, wrapper-provided helper `scripts/post-verdict.sh` (mirroring
`mark-issue-checkbox.sh`) and route **every** verdict-post instruction in
`build_review_prompt` through it. The agent passes structured args + a body **file**;
the helper composes the canonical `Review Session:` / `Review Agent:` trailer itself
and posts via the token-refresh `gh` proxy. This sidesteps the agent's shell-quoting
of a multi-line `--body` — the exact suspected agy failure.

**The fix is RELIABLE POSTING via the helper, not an exit-code signal.** `unavailable`
is decided by the wrapper's verdict poller on comment-absence; the agent's exit code
is not consulted for that decision. The helper still exits non-zero on a failed post
(hygiene + a future hook the out-of-scope wrapper-side change would consume), but that
exit code does not, by itself, change today's verdict.

## `post-verdict.sh` contract

```
Usage: post-verdict.sh <issue-number> <pass|fail> <body-file|-> <agent-name> <session-id>
```

| Arg | Meaning | Validation |
|-----|---------|------------|
| `issue-number` | issue to comment on | positive integer |
| `verdict` | `pass` or `fail` (case-insensitive) | exact set |
| `body-file` | path to a file holding the findings body, or `-` for stdin | readable file, ≤ 64 KiB |
| `agent-name` | review agent name (INV-40 discriminator) | `[A-Za-z0-9._-]`, ≤ 64 chars |
| `session-id` | the agent's Review Session UUID | `[A-Za-z0-9-]`, ≤ 64 chars |

Behavior:

1. **First-line guard.** The poller (`lib-review-poll.sh::_classify_verdict_body`)
   matches the first line. The helper ENSURES the body's first line begins with the
   canonical prefix:
   - `pass` → must start with `Review PASSED`. If the supplied body does not, the
     helper PREPENDS a `Review PASSED - <body>` (or `Review PASSED` alone for an
     empty body).
   - `fail` → must start with `Review findings:`. If not, the helper PREPENDS a
     `Review findings:` line.
   This makes the verdict phrasing deterministic regardless of how the agent worded
   its body.
2. **Trailer composition.** The helper APPENDS, on their own lines, the two
   load-bearing trailer lines (INV-40 / INV-20):
   ```
   Review Session: `<session-id>`
   Review Agent: <agent-name>
   ```
   The agent never hand-writes the trailer — this also closes the session-id-rebind
   hazard (a stale/old session id can't be carried). **NOTE:** this is the AGENT
   verdict trailer, distinct from `lib-review-verdict.sh::emit_verdict_trailer`
   (the wrapper's machine-readable `<!-- review-verdict: … -->` marker — do not
   conflate).
3. **Posting.** Posts via the token-refresh proxy `"${SCRIPT_DIR}/gh" issue comment
   <issue> --repo <REPO> --body <composed>` — NOT bare gh. `REPO` is read from the
   co-located/dispatcher/project `autonomous.conf` exactly like `mark-issue-checkbox.sh`.
   If `${SCRIPT_DIR}/gh` is missing/non-executable the helper **exits non-zero** — it
   does NOT fall back to bare PATH `gh` (which would resolve to the host operator's
   identity and mis-attribute the verdict). A missing proxy means a broken install
   (`install-project-hooks.sh` materializes it); failing loud surfaces that. (codex
   review finding on PR #203.)
4. **Fail loudly.** Non-zero exit if the post fails (gh non-zero) or the proxy is
   absent. On success, echo the created comment URL.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Comment posted; URL echoed on stdout |
| 1 | gh post failed, or config/runtime error |
| 2 | Invalid arguments (bad issue number / verdict / unreadable body / bad name) |

## Prompt routing (three spots in `build_review_prompt`)

1. **Decision block — PASS branch** (~line 857-865): instruct the agent to post the
   verdict **only** via `bash scripts/post-verdict.sh <issue> pass <body-file> <name>
   <sid>`; explicitly forbid bare `gh issue comment`; note the helper appends the
   trailer.
2. **Decision block — FAIL branch** (~line 867-875): same, with `fail`.
3. **INV-55 codex-inline-diff block** (~lines 650, 666): the "produce findings + post
   your verdict comment in THIS turn" / "post the verdict in as few turns as possible"
   language defers to the same `post-verdict.sh` instruction (no loose "post your
   verdict comment" that permits bare gh on the codex lane).

All CLIs (claude/codex/agy/kiro/gemini/opencode) go through the same helper — no
per-CLI branch in the prompt for the verdict post. The first-line phrasing the poller
matches (`Review PASSED` / `Review findings:`) is preserved (the helper guarantees it).

## Scope

- **Verdict comment only.** Other gh calls the prompt mentions (mergeability
  `gh pr view --json`, `gh pr checks`, the Step-0 rebase) are out of scope.
  `mark-issue-checkbox.sh` is already a helper — unchanged.
- The wrapper-side "agent exited 0 but posted no verdict → re-runnable vs unavailable"
  detection is a FOLLOW-UP, not this issue.

## Invariant

New `INV-56` in `docs/pipeline/invariants.md`: *review verdict is posted via the
deterministic `post-verdict.sh` helper, not the agent's bare gh.* `review-agent-flow.md`
updated in the same PR (Pipeline Documentation Authority).

(INV-55 is the current max on main; INV-52 is in-flight on another branch, so INV-56
is the next free number that cannot collide.)

## Post-install / upgrade

This PR **adds** `scripts/post-verdict.sh`. After merge + `npx skills update -g`,
re-run `install-project-hooks.sh` on every onboarded project (CLAUDE.local.md →
Post-merge Step 2) or their review wrappers will reference a `scripts/post-verdict.sh`
symlink that doesn't exist yet.
