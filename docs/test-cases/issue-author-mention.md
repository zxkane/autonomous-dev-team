# Test cases: issue-author @-mention (INV-138: provider leaf + composed chain)

> **Integration note (2026-07-17)**: the raw `issue_mention_login` helper no
> longer applies its own github-side `REPO_OWNER` fallback — fallback policy
> (bot detection, three-state `HUMAN_ESCALATION_LOGIN` incl. set-EMPTY mute,
> provider-scoped default) lives in `resolve_escalation_mention` ([INV-138],
> `lib-review-resolve-author.sh`). Composed-chain rows: TC-PAEM-070..084 in
> `tests/unit/test-pr-author-escalation-mention.sh`.

Primary suite: `tests/unit/test-issue-mention-login.sh`
Supporting: `tests/unit/test-w1b-read-task-contracts.sh` (github `author` leaf),
`tests/unit/test-itp-gitlab.sh` TC-WB-041b (gitlab `author` leaf).

## AC1 — `author` field on the `read_task` leaf

| ID | Provider | Input | Expected |
|----|----------|-------|----------|
| GH-1 | github | payload `author.login=filer-jane`, request `title,author` | `.author == "filer-jane"`, keys exactly `title,author` |
| GH-2 | github | payload has no `author`, request `author` | `.author == ""` (never null) |
| GL-1 | gitlab | payload `author.username=gl-filer`, request `title,author` | `.author == "gl-filer"` |
| GL-2 | gitlab | payload has no `author`, request `author` | `.author == ""` |

## AC2 — `issue_mention_login` raw resolution (no fallback — policy lives in resolve_escalation_mention)

| ID | ISSUE_PROVIDER | author | Expected return |
|----|----------------|--------|-----------------|
| M-1 | github | `filer-jane` | `filer-jane` |
| M-2 | gitlab | `gl-filer` | `gl-filer` |
| M-3 | github | absent | `` (empty — no helper-level fallback, [INV-138]) |
| M-4 | gitlab | absent | `` (empty — no group ping) |
| M-5 | github | `read_task` fails (rc≠0) | `zxkane` (degrades, no abort) |
| M-6 | gitlab | `read_task` fails (rc≠0) | `` (degrades, no abort) |

## AC3 — wiring guard

| ID | Check | Expected |
|----|-------|----------|
| W-1 | grep `@${REPO_OWNER}` / `@$REPO_OWNER` in `lib-dispatch.sh` | no match (all migrated to `${_mention:+@}${_mention}`) |
| W-2 | same grep in `autonomous-review.sh` | no match |

## Regression coverage (zero churn to existing argv stubs — on-demand append)

The GitHub leaf appends `author` to `gh issue view --json …` **only when the
caller requests `author`** (the same on-demand pattern `comments` already uses).
Callers that request the pre-existing field sets (`title,body,state,labels`,
`body`, …) therefore emit **byte-identical argv**, so NO existing gh-stub argv
matcher, golden trace, parity payload, or conformance fixture needs to change:

- `test-w1b-read-task-parity.sh`, `test-check-deps-resolved.sh`,
  `test-itp-resolve-dep-golden-trace.sh`, `test-itp-write-leaves.sh`
  (TC-MCB-EQUIV-READSHAPE), `run-cross-repo-dep-e2e.sh`, and the conformance
  fixtures all match `--json title,body,state,labels` (or a subset) and are
  UNCHANGED — verified by an argv assertion that the `body`-only read still
  emits exactly `issue view <N> --repo <R> --json title,body,state,labels`.
- Only `issue_mention_login`'s `itp_read_task <N> author` call triggers the
  `,author` suffix; the GitLab leaf reads the whole issue object regardless, so
  it has no argv to keep stable.

## Notes on local execution

Tests that `source lib-dispatch.sh` require bash 4+ (CI). Under macOS system
bash 3.2 they emit a parse warning and no summary — this is pre-existing and
identical on the base branch; the author/helper/wiring suites above run fully
under bash 3.2 and pass.
