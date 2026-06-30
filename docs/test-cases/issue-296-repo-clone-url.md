# Test Cases — #316: eliminate lib-auth `gh repo view` survivor (use `origin`, Option A)

Part of #296 (pluggable-providers raw-`gh` migration). Behavior-preserving replacement of
the last `gh repo view` site in `lib-auth.sh`'s `drain_agent_pr_create` head-resolution
fallback: the clone-URL read (`gh repo view "$repo" --json url -q .url || echo
"https://github.com/${repo}.git"`) feeding `git ls-remote --heads <URL>` is replaced by the
local `origin` remote name — mirroring the INV-45 precedent at `autonomous-dev.sh:397`
(`git ls-remote origin "refs/heads/*issue-${issue_num}*"`).

This is NOT a byte-identical leaf move; it is a **behavior-equivalence** change (the remote
source changes from a gh-resolved URL to the `origin` remote name; both resolve to the same
repo from PROJECT_DIR and yield the identical branch name). No new verb is minted —
`git ls-remote` is git-transport plumbing, not code-host REST/CLI I/O (INV-91 does not own it).

## Scope

- `skills/autonomous-dispatcher/scripts/lib-auth.sh` — `drain_agent_pr_create` head-resolution.
- `scripts/providers/cutover-baseline.json` — shrink by exactly 1 (the lib-auth repo-view survivor).
- `docs/pipeline/invariants.md` — INV-91 Migration-log bullet.
- `tests/unit/test-token-split-234.sh` — observed-call + redaction + set-e-safety tests; stale stub cleanup.
- `tests/unit/test-issue-308-b3b4-chp-reads.sh` — stale `repo view` stub-branch/comment cleanup (AC3b).

## Test Cases

### TC-316-01 — observed-call: head resolution uses `git ls-remote --heads origin`, never `gh repo view`
- **Setup**: stub `git` on PATH so `git ls-remote --heads origin "*issue-N*"` echoes a fixture
  line `<sha>\trefs/heads/feat/issue-N-foo` AND logs its argv; stub `gh` so any `repo view`
  logs its argv. Broker file has NO `branch:` line + a title/body; `AGENT_GH_TOKEN_FILE` armed.
- **Action**: call `drain_agent_pr_create N owner/repo`.
- **Expected**:
  - the `git` stub OBSERVED `ls-remote --heads origin "*issue-N*"`.
  - the `gh` stub NEVER recorded a `repo view` call.
  - the resolved branch == `feat/issue-N-foo`; `gh pr create` (the broker create) received
    `--head feat/issue-N-foo`.
- **AC**: AC1, AC2.

### TC-316-02 — no-branch path equivalence: empty ls-remote → WARN + skip (re-queue to pending-dev)
- **Setup**: stub `git` so `ls-remote --heads origin` returns empty; `git remote get-url origin`
  returns a plain `https://github.com/owner/repo.git`. Broker file has NO `branch:` line.
- **Action**: call `drain_agent_pr_create N owner/repo`, capture stderr.
- **Expected**:
  - `gh pr create` is NEVER called (no doomed same-branch PR).
  - the WARN line fires (no head branch) and now also carries the origin URL.
- **AC**: AC3.

### TC-316-03 — credential redaction in the no-branch WARN
- **Setup**: as TC-316-02 but `git remote get-url origin` returns a credential-bearing URL
  `https://x-access-token:SECRET@github.com/owner/repo.git`.
- **Action**: call `drain_agent_pr_create N owner/repo`, capture stderr.
- **Expected**:
  - the WARN line contains `https://<redacted>@github.com/owner/repo.git`.
  - the WARN line NEVER contains the token `SECRET`.
- **AC**: AC3.

### TC-316-04 — `set -e`-safety of `git remote get-url`
- **Setup**: as TC-316-02 but `git remote get-url origin` EXITS NON-ZERO (no origin / failure);
  the surrounding shell runs under `set -e`.
- **Action**: call `drain_agent_pr_create N owner/repo`.
- **Expected**: the function does NOT abort on the failing `git remote get-url`; it still emits
  the no-branch WARN+skip and returns 0 (the `origin_for_log` capture is `|| true`-guarded).
- **AC**: AC3.

### TC-316-05 — no `gh repo view` survives in lib-auth.sh (source grep)
- **Action**: `grep -c 'gh repo view' skills/autonomous-dispatcher/scripts/lib-auth.sh`.
- **Expected**: `0`.
- **AC**: AC1.

### TC-316-06 — cutover guard PASS with baseline −1
- **Action**: `bash check-provider-cutover.sh` (and regenerate via `--generate-baseline`,
  verifying the diff is exactly the one lib-auth repo-view survivor line).
- **Expected**: exits 0; baseline `surviving_sites` count shrinks by exactly 1; the removed
  entry is the `branch=$(git ls-remote --heads "$(gh repo view ...` line.
- **AC**: AC4.

### TC-316-07 — stale gh-repo-view test stub cleanup (AC3b)
- **Action**: confirm no test stubs/comments assert or rely on the removed `gh repo view`
  head-resolution path (`test-token-split-234.sh`, `test-issue-308-b3b4-chp-reads.sh`).
- **Expected**: the `repo view` stub branches/comments tied to the lib-auth head fallback are
  removed; the suites still pass.
- **AC**: AC3b, AC6.

## Acceptance Criteria mapping

| AC | Covered by |
|----|------------|
| AC1 | TC-316-01, TC-316-05 |
| AC2 | TC-316-01 |
| AC3 | TC-316-02, TC-316-03, TC-316-04 |
| AC3b | TC-316-07 |
| AC4 | TC-316-06 |
| AC5 | INV-91 Migration-log bullet (docs) + Spec Drift / Pipeline Docs Gate |
| AC6 | full unit + conformance suite (TC-316-07 + all) |
