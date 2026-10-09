#!/usr/bin/env bash
# Exercise the real post-merge library against a bare remote and provider fixtures.
set -euo pipefail
export KNOWLEDGE_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(os.environ["KNOWLEDGE_TEST_ROOT"])
HELPER = SOURCE / "skills/autonomous-common/scripts/session-knowledge.sh"
LIBRARY = SOURCE / "skills/autonomous-dispatcher/scripts/lib-session-knowledge.sh"


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="knowledge-merge-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.remote = self.directory / "origin.git"
        subprocess.run(["git", "init", "--bare", "-q", "--initial-branch=main", str(self.remote)], check=True)
        self.repo = self.directory / "repo"
        subprocess.run(["git", "clone", "-q", str(self.remote), str(self.repo)], check=True, capture_output=True)
        self.git("config", "user.name", "Test User")
        self.git("config", "user.email", "user@example.com")
        (self.repo / "AGENTS.md").write_text("# Guidance\n")
        self.git("add", ".")
        self.git("commit", "-qm", "test: baseline")
        self.git("push", "-q", "origin", "main")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.calls = self.directory / "calls"
        self.calls.write_text("")
        self.pr_list = self.directory / "prs.json"
        self.pr_list.write_text("[]")
        self.harness = self.directory / "postmerge.sh"
        self.harness.write_text('''#!/usr/bin/env bash
set -euo pipefail
source "$KNOWLEDGE_LIBRARY"
chp_pr_view() {
  echo view >> "$KNOWLEDGE_CALLS"
  [[ "${STATE_READ_FAIL:-0}" != 1 ]] || return 1
  jq -nc --arg state "${PR_STATE:-MERGED}" --arg timestamp "${MERGED_AT:-2026-10-01T00:00:00Z}" \
    '{state:$state,mergedAt:(if $timestamp == "null" then null else $timestamp end)}'
}
chp_pr_list() {
  echo list >> "$KNOWLEDGE_CALLS"
  if [[ "${FAIL_PUSH:-0}" == 1 ]]; then
    git -C "$PROJECT_DIR" remote set-url --push origin "$MISSING_PUSH_REMOTE"
  fi
  if [[ "${MOVE_BRANCH:-0}" == 1 ]]; then
    branch=$(git -C "$PROJECT_DIR" for-each-ref --format='%(refname:short)' refs/heads/docs/)
    worktree="$PROJECT_DIR/.worktrees/$branch"
    printf '%s\n' 'unrelated file' > "$worktree/unrelated.txt"
    git -C "$worktree" add unrelated.txt
    git -C "$worktree" commit -qm 'test: concurrent unrelated commit'
  fi
  cat "$KNOWLEDGE_PRS"
}
chp_create_pr() {
  echo create >> "$KNOWLEDGE_CALLS"
  [[ "${FAIL_CREATE:-0}" != 1 ]] || return 1
  local commit
  commit=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$1")
  jq -nc --arg branch "$1" --arg commit "$commit" \
    '[{number:2,headRefName:$branch,headRefOid:$commit}]' > "$KNOWLEDGE_PRS"
  [[ "${QUIET_CREATE:-0}" != 1 ]] || return 0
  printf '%s\n' 'https://example.com/pull/2'
}
postmerge_session_knowledge 1 1
''')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("AUTONOMOUS_KNOWLEDGE_", "SESSION_KNOWLEDGE"))}
        self.env.update(PROJECT_DIR=str(self.repo), BASE_BRANCH="main", ISSUE_NUMBER="1",
                        LIB_DIR=str(LIBRARY.parent), KNOWLEDGE_LIBRARY=str(LIBRARY),
                        KNOWLEDGE_CALLS=str(self.calls), KNOWLEDGE_PRS=str(self.pr_list),
                        MISSING_PUSH_REMOTE=str(self.directory / "missing"))

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, text=True, check=True)

    def capture(self):
        subprocess.run(["bash", str(HELPER), "begin", "--task", "issue-1", "--session", "dev-a", "--role", "dev"],
                       cwd=self.repo, env=self.env, check=True, capture_output=True)
        subprocess.run(["bash", str(HELPER), "assess", "--input", "-"], cwd=self.repo, env=self.env,
                       input=json.dumps({"updates": [{"key": "test-command", "kind": "guidance", "path": "AGENTS.md",
                             "content": "Run focused tests for this module.", "evidence": "Verified with the regression fixture."}]}),
                       text=True, check=True, capture_output=True)

    def run_merge(self, ok=True, **overrides):
        result = subprocess.run(["bash", str(self.harness)], cwd=self.repo, env={**self.env, **overrides},
                                text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def branches(self):
        return self.git("for-each-ref", "--format=%(refname:short)", "refs/heads/docs/").stdout.splitlines()

    def test_no_candidates_does_not_read_provider_or_fetch(self):
        self.run_merge()
        self.assertEqual(self.calls.read_text(), "")
        self.assertEqual(self.branches(), [])

    def test_no_confirmed_merge_never_writes_documentation(self):
        self.capture()
        for overrides in ({"PR_STATE": "OPEN"}, {"PR_STATE": "CLOSED"}, {"MERGED_AT": "null"},
                          {"STATE_READ_FAIL": "1"}):
            self.run_merge(ok=False, **overrides)
            self.assertEqual(self.branches(), [])
            self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base)

    def test_success_publishes_once_and_cleans_documentation_worktree(self):
        self.capture()
        self.run_merge()
        branch = self.branches()[0]
        content = self.git("show", f"{branch}:AGENTS.md").stdout
        self.assertIn("focused tests", content)
        self.run_merge()
        self.assertEqual(self.calls.read_text().splitlines().count("create"), 1)
        self.assertEqual(len(self.git("worktree", "list", "--porcelain").stdout.split("worktree ")), 2)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base)

    def test_documentation_pr_is_not_resolved_as_the_original_issue_pr(self):
        self.capture()
        self.run_merge()
        branch = self.branches()[0]
        self.pr_list.write_text(json.dumps([{"number": 2, "headRefName": branch,
                                            "closingIssueNumbers": []}]))
        linkage = self.directory / "linkage.sh"
        linkage.write_text('''#!/usr/bin/env bash
set -euo pipefail
chp_find_pr_for_issue() { cat "$KNOWLEDGE_PRS"; }
source "$KNOWLEDGE_LINKAGE"
[[ -z "$(resolve_pr_for_issue 1)" ]]
! verify_pr_closes_issue 2 1
''')
        result = subprocess.run(["bash", str(linkage)], cwd=self.repo,
                                env={**self.env, "KNOWLEDGE_LINKAGE": str(LIBRARY.with_name("lib-pr-linkage.sh"))},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_push_failure_retains_commit_for_retry(self):
        self.capture()
        self.run_merge(ok=False, FAIL_PUSH="1")
        branch = self.branches()[0]
        commit = self.git("rev-parse", branch).stdout.strip()
        self.assertNotIn("create", self.calls.read_text())
        self.git("remote", "set-url", "--push", "origin", str(self.remote))
        self.run_merge()
        self.assertEqual(self.git("rev-parse", branch).stdout.strip(), commit)
        self.assertEqual(self.calls.read_text().splitlines().count("create"), 1)

    def test_pr_creation_failure_reuses_the_same_commit(self):
        self.capture()
        self.run_merge(ok=False, FAIL_CREATE="1")
        branch = self.branches()[0]
        commit = self.git("rev-parse", branch).stdout.strip()
        self.run_merge()
        self.assertEqual(self.git("rev-parse", branch).stdout.strip(), commit)

    def test_provider_create_success_does_not_require_url_stdout(self):
        self.capture()
        self.run_merge(QUIET_CREATE="1")
        receipts = list((self.repo / ".git/session-knowledge/tasks/issue-1").glob("publication-*.json"))
        self.assertEqual(len(receipts), 1)
        self.assertEqual(json.loads(receipts[0].read_text()).get("pr"), "2")
        self.run_merge(QUIET_CREATE="1")
        self.assertEqual(self.calls.read_text().splitlines().count("create"), 1)
        self.assertEqual(len(self.git("worktree", "list", "--porcelain").stdout.split("worktree ")), 2)

    def test_successful_unrecorded_pr_is_reused(self):
        self.capture()
        self.run_merge(ok=False, FAIL_CREATE="1")
        branch = self.branches()[0]
        commit = self.git("rev-parse", branch).stdout.strip()
        self.pr_list.write_text(json.dumps([{"number": 2, "headRefName": branch, "headRefOid": commit}]))
        self.calls.write_text("")
        self.run_merge()
        self.assertNotIn("create", self.calls.read_text())

    def test_unavailable_pr_list_does_not_create_duplicates(self):
        self.capture()
        self.pr_list.write_text("null")
        self.run_merge(ok=False)
        self.assertNotIn("create", self.calls.read_text())

    def test_foreign_existing_branch_head_is_preserved(self):
        self.capture()
        self.run_merge(ok=False, FAIL_CREATE="1")
        branch = self.branches()[0]
        self.pr_list.write_text(json.dumps([{"number": 2, "headRefName": branch, "headRefOid": self.base}]))
        self.calls.write_text("")
        self.run_merge(ok=False)
        self.assertNotIn("create", self.calls.read_text())

    def test_disabled_capture_is_a_noop(self):
        self.capture()
        self.run_merge(SESSION_KNOWLEDGE="off")
        self.assertEqual(self.calls.read_text(), "")
        self.assertEqual(self.branches(), [])

    def test_push_uses_the_validated_sha_even_if_branch_moves(self):
        self.capture()
        self.run_merge(ok=False, MOVE_BRANCH="1")
        branch = self.branches()[0]
        remote = self.git("ls-remote", "origin", f"refs/heads/{branch}").stdout.split()[0]
        files = self.git("ls-tree", "--name-only", remote).stdout.splitlines()
        self.assertNotIn("unrelated.txt", files)
        self.assertIn("AGENTS.md", files)


unittest.main(verbosity=2)
PY
