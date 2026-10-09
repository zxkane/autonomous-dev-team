#!/usr/bin/env bash
# Real Git/worktree fixtures for optional session knowledge writeback.
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KNOWLEDGE_TEST_ROOT="$TEST_ROOT"
python3 - <<'PY'
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
import types

SOURCE = Path(os.environ["KNOWLEDGE_TEST_ROOT"])
HELPER = SOURCE / "skills/autonomous-common/scripts/session-knowledge.sh"
HOOK = SOURCE / "skills/autonomous-common/hooks/check-session-knowledge.sh"


class KnowledgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="session-knowledge-test-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "--initial-branch=main")
        self.git("config", "user.name", "Test User")
        self.git("config", "user.email", "user@example.com")
        (self.repo / ".gitignore").write_text(".worktrees/\n")
        (self.repo / "AGENTS.md").write_text("# Guidance\n\nKeep independent rules.\n\nUse Python 2.\n")
        (self.repo / "module").mkdir()
        (self.repo / "module/code.txt").write_text("code\n")
        self.git("add", ".")
        self.git("commit", "-qm", "test: baseline")
        self.baseline = self.git("rev-parse", "HEAD").stdout.strip()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("AUTONOMOUS_KNOWLEDGE_", "SESSION_KNOWLEDGE"))}

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, text=True,
                              capture_output=True, check=True)

    def cli(self, *args, data=None, cwd=None, ok=True):
        result = subprocess.run(["bash", str(HELPER), *args], cwd=cwd or self.repo,
                                input=json.dumps(data) if data is not None else None,
                                text=True, capture_output=True, env=self.env)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def begin(self, session="dev-a", cwd=None, role="dev"):
        self.cli("begin", "--task", "issue-1", "--session", session,
                 "--role", role, cwd=cwd)

    def update(self, **overrides):
        return {"key": "python-runtime", "path": "AGENTS.md", "kind": "guidance",
                "content": "Use Python 3.", "replace": "Use Python 2.",
                "evidence": "Verified the runtime with the repository tests.", **overrides}

    def assess(self, updates=None, local=None, session="dev-a", cwd=None, reason=""):
        return self.cli("assess", "--task", "issue-1", "--session", session,
                        "--input", "-", cwd=cwd,
                        data={"updates": updates or [], "local": local or [], "reason": reason})

    def apply(self, ok=True):
        result = self.cli("apply", "--task", "issue-1", "--base-ref", "main",
                          "--merged-pr", "1", ok=ok)
        return json.loads(result.stdout) if ok else result

    def test_explicit_none_creates_no_document_or_commit(self):
        self.begin()
        self.cli("check", ok=False)
        self.cli("assess", "--none", "No new durable facts.")
        self.cli("check")
        self.assertEqual(self.apply()["status"], "noop")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.baseline)
        self.assertFalse((self.repo / "docs").exists())
        self.assertEqual(len(self.git("worktree", "list", "--porcelain").stdout.split("worktree ")), 2)

    def test_incomplete_assessment_is_not_claimed_as_no_lessons(self):
        self.begin()
        result = self.apply()
        self.assertEqual(result["status"], "pending")
        self.assertEqual(result["unassessed"], 1)

    def test_multiple_sessions_share_ledger_and_latest_key_wins(self):
        self.begin()
        self.assess([self.update()])
        worktree = Path(self.temp.name) / "dev-worktree"
        self.git("worktree", "add", "-qb", "feat/second", str(worktree))
        self.begin("review-b", worktree, "review")
        self.assess([self.update(content="Use Python 3.11 or newer."), self.update(
            key="test-command", path="module/AGENTS.md", content="Run the focused module tests.",
            replace="")], session="review-b", cwd=worktree)
        pending = json.loads(self.cli("pending", "--task", "issue-1").stdout)
        self.assertEqual(len(pending["updates"]), 2)
        self.assertIn("3.11", pending["updates"][0]["content"])
        result = self.apply()
        content = self.git("show", f'{result["commit"]}:AGENTS.md').stdout
        self.assertIn("Keep independent rules.", content)
        self.assertIn("3.11", content)
        self.assertNotIn("Use Python 2.", content)
        self.assertIn("focused module", self.git("show", f'{result["commit"]}:module/AGENTS.md').stdout)

    def test_head_change_invalidates_assessment(self):
        self.begin()
        self.cli("assess", "--none", "No new durable facts.")
        self.git("commit", "--allow-empty", "-qm", "test: another revision")
        self.cli("check", ok=False)
        self.cli("assess", "--none", "Rechecked the new revision.")
        self.cli("check")

    def test_stop_checks_the_assessed_worktree_from_the_primary_checkout(self):
        feature = Path(self.temp.name) / "feature"
        self.git("worktree", "add", "-qb", "feat/source", str(feature))
        self.git("commit", "--allow-empty", "-qm", "test: feature revision", cwd=feature)
        self.cli("begin", "--no-active", "--task", "issue-1", "--session", "dev-a")
        self.cli("assess", "--task", "issue-1", "--session", "dev-a", "--none",
                 "No new durable facts.", cwd=feature)
        env = {**self.env, "AUTONOMOUS_KNOWLEDGE_TASK": "issue-1",
               "AUTONOMOUS_KNOWLEDGE_SESSION": "dev-a"}
        def stop(payload):
            return subprocess.run(["bash", str(HOOK)], cwd=self.repo, input=json.dumps(payload),
                                  capture_output=True, text=True, env=env)
        for payload in ({"cwd": str(self.repo)}, {}):
            result = stop(payload)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.git("commit", "--allow-empty", "-qm", "test: unrelated primary revision")
        self.assertEqual(stop({"cwd": str(self.repo)}).returncode, 0)
        self.git("commit", "--allow-empty", "-qm", "test: changed feature revision", cwd=feature)
        result = stop({"cwd": str(self.repo)})
        self.assertEqual(result.returncode, 2)
        self.assertIn("worktree", result.stderr)

    def test_switching_the_assessed_worktree_branch_invalidates_the_receipt(self):
        feature = Path(self.temp.name) / "feature"
        self.git("worktree", "add", "-qb", "feat/source", str(feature))
        self.cli("begin", "--no-active", "--task", "issue-1", "--session", "dev-a")
        self.cli("assess", "--task", "issue-1", "--session", "dev-a", "--none",
                 "No new durable facts.", cwd=feature)
        self.cli("check", "--task", "issue-1", "--session", "dev-a")
        self.git("checkout", "-qb", "feat/other", cwd=feature)
        self.cli("check", "--task", "issue-1", "--session", "dev-a", ok=False)

    def test_same_cli_review_members_have_independent_assessments(self):
        library = SOURCE / "skills/autonomous-dispatcher/scripts/lib-session-knowledge.sh"
        wrapper = library.with_name("autonomous-review.sh").read_text().splitlines()
        begin = next(line for line in wrapper if "begin_session_knowledge review" in line)
        prompt = next(line for line in wrapper if '_knowledge_prompt="$(render_session_knowledge_prompt review' in line)
        harness = '''set -euo pipefail
source "$KNOWLEDGE_LIBRARY"
RUN_ID=test-run
_agent=codex
_agent_name=codex
for _agent_session_id in member-a member-b; do
BEGIN
PROMPT
  [[ "$_knowledge_prompt" == *"--session ${AUTONOMOUS_KNOWLEDGE_SESSION}"* ]]
  if [[ "$_agent_session_id" == member-a ]]; then
    first_session="$AUTONOMOUS_KNOWLEDGE_SESSION"
    bash "$KNOWLEDGE_HELPER" --repo "$PROJECT_DIR" assess --none 'No new durable facts.' >/dev/null
  else
    [[ "$AUTONOMOUS_KNOWLEDGE_SESSION" != "$first_session" ]]
    ! bash "$KNOWLEDGE_HELPER" --repo "$PROJECT_DIR" check
  fi
done
'''.replace("BEGIN", begin).replace("PROMPT", prompt)
        result = subprocess.run(["bash", "-c", harness], cwd=self.repo, capture_output=True, text=True,
                                env={**self.env, "KNOWLEDGE_LIBRARY": str(library), "KNOWLEDGE_HELPER": str(HELPER),
                                     "PROJECT_DIR": str(self.repo), "LIB_DIR": str(library.parent),
                                     "ISSUE_NUMBER": "1", "PR_HEAD_SHA": self.baseline})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_new_update_preserves_prior_facts_from_the_same_session(self):
        self.begin()
        self.assess([self.update()])
        self.cli("assess", "--none", "No additional facts beyond the prior checkpoint.")
        pending = json.loads(self.cli("pending", "--task", "issue-1").stdout)
        self.assertEqual(len(pending["updates"]), 1)
        self.assertEqual(pending["updates"][0]["content"], "Use Python 3.")

    def test_no_new_update_does_not_repromote_an_older_session_fact(self):
        self.begin()
        self.assess([self.update()])
        self.begin("review-b", role="review")
        self.assess([self.update(content="Use Python 3.11 or newer.")], session="review-b")
        self.cli("assess", "--task", "issue-1", "--session", "dev-a", "--none", "No additional facts.")
        pending = json.loads(self.cli("pending", "--task", "issue-1").stdout)
        self.assertEqual(pending["updates"][0]["content"], "Use Python 3.11 or newer.")

    def test_local_environment_references_are_private_and_shared(self):
        self.begin()
        self.assess(local=[{"key": "credential-source", "content": "Read credentials from env:TEST_TOKEN.",
                            "evidence": "Confirmed the variable is present; no value recorded."}])
        local_file = self.repo / "AGENTS.local.md"
        self.assertEqual(stat.S_IMODE(local_file.stat().st_mode), 0o600)
        self.assertIn("env:TEST_TOKEN", local_file.read_text())
        self.git("check-ignore", "AGENTS.local.md")
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertEqual(self.apply()["status"], "noop")
        self.assertEqual(json.loads(self.cli("pending", "--task", "issue-1").stdout)["updates"], [])

    def test_secret_literals_are_rejected_without_echo(self):
        token = "ghp_" + "A" * 36
        self.begin()
        for data in ({"updates": [self.update(content=token)]},
                     {"local": [{"key": "unsafe", "content": token, "evidence": "Observed locally."}]}):
            result = self.cli("assess", "--input", "-", data=data, ok=False)
            self.assertNotIn(token, result.stdout + result.stderr)
        self.assertFalse((self.repo / "AGENTS.local.md").exists())
        self.cli("check", ok=False)

    def test_short_secret_assignments_are_rejected_but_references_are_allowed(self):
        self.begin()
        for content in ("password=fixture7", 'client_secret="x"', "api_key: z", "access_token=0"):
            for field in ("updates", "local"):
                value = self.update(content=content) if field == "updates" else {
                    "key": "credential", "content": content, "evidence": "Observed locally."}
                result = self.cli("assess", "--input", "-", data={field: [value]}, ok=False)
                self.assertNotIn(content, result.stderr)
        self.assess([self.update(content="password=env:PROJECT_PASSWORD; api_key=<credential-reference>")])

    def test_credential_reference_cannot_contain_a_literal_default(self):
        self.begin()
        for content in ('password=${PROJECT_PASSWORD:-fixture7}',
                        'password=os.getenv("PROJECT_PASSWORD", "fixture7")',
                        'password=process.env.PROJECT_PASSWORD || "fixture7"',
                        'const password = process.env.PROJECT_PASSWORD\n  || "fixture7";',
                        'const password = process.env.PROJECT_PASSWORD // configuration\n  || "fixture7";'):
            for field in ("updates", "local"):
                value = self.update(content=content) if field == "updates" else {
                    "key": "credential", "content": content, "evidence": "Observed locally."}
                self.cli("assess", "--input", "-", data={field: [value]}, ok=False)
        self.assess([self.update(content='password=${PROJECT_PASSWORD}; api_key=os.getenv("PROJECT_KEY")')])

    def test_local_reference_policy_blocks_capture_and_final_commit(self):
        self.begin()
        policy = self.repo / ".git/session-knowledge/security.local.json"
        policy.write_text(json.dumps({"private_references": ["private-fixture"]}))
        policy.chmod(0o600)
        self.cli("assess", "--input", "-", data={"updates": [self.update(
            content="Observed in https://example.com/team/private-fixture/issues/1")]}, ok=False)
        self.assess(local=[{"key": "consumer-location", "content": "Local checkout: private-fixture.",
                            "evidence": "Observed on this machine."}])
        self.assertIn("private-fixture", (self.repo / "AGENTS.local.md").read_text())
        policy.write_text(json.dumps({"private_references": []}))
        self.assess([self.update()])
        policy.write_text(json.dumps({"private_references": ["Python 3"]}))
        self.apply(ok=False)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.baseline)

    def test_private_legacy_reference_can_be_redacted(self):
        old = "Legacy source: private-fixture."
        (self.repo / "AGENTS.md").write_text("# Guidance\n\n" + old + "\n")
        self.git("add", "AGENTS.md")
        self.git("commit", "-qm", "test: legacy reference")
        self.begin()
        policy = self.repo / ".git/session-knowledge/security.local.json"
        policy.write_text(json.dumps({"private_references": ["private-fixture"]}))
        policy.chmod(0o600)
        self.assess([self.update(replace=old, content="Reproduced downstream.")])
        result = self.apply()
        self.assertNotIn("private-fixture", self.git("show", f'{result["commit"]}:AGENTS.md').stdout)

    def test_newly_merged_module_does_not_require_updating_primary_checkout(self):
        feature = Path(self.temp.name) / "feature"
        self.git("worktree", "add", "-qb", "feat/new-module", str(feature))
        (feature / "new-module").mkdir()
        (feature / "new-module/code.txt").write_text("new module\n")
        self.git("add", "new-module/code.txt", cwd=feature)
        self.git("commit", "-qm", "test: new module", cwd=feature)
        self.begin(cwd=feature)
        self.assess([self.update(path="new-module/AGENTS.md", replace="")], cwd=feature)
        result = json.loads(self.cli("apply", "--task", "issue-1", "--base-ref", "feat/new-module",
                                    "--merged-pr", "1").stdout)
        self.assertIn("Use Python 3.", self.git("show", f'{result["commit"]}:new-module/AGENTS.md').stdout)
        self.assertFalse((self.repo / "new-module").exists())

    def test_unknown_assessment_fields_are_rejected(self):
        self.begin()
        self.cli("assess", "--input", "-", data={"updates": [self.update()], "execute": "unexpected"}, ok=False)
        self.cli("assess", "--input", "-", data={"updates": [self.update(command="unexpected")]}, ok=False)

    def test_private_comment_and_cross_repository_reference_are_rejected(self):
        self.begin()
        for content in ("Reproduced downstream: " + "team/consumer" + "#" + str(27),
                        "See " + "issuecomment-" + str(12345) + "."):
            self.cli("assess", "--input", "-", data={"updates": [self.update(content=content)]}, ok=False)

    def test_different_tasks_preserve_all_concurrent_local_facts(self):
        count = 8
        for number in range(count):
            self.cli("begin", "--no-active", "--task", f"issue-{number+1}",
                     "--session", f"dev-{number}", "--role", "dev")
        def write(number):
            return self.cli("assess", "--task", f"issue-{number+1}", "--session", f"dev-{number}",
                            "--input", "-", data={"local": [{"key": f"setting-{number}",
                                "content": f"Machine preference {number}.", "evidence": "Confirmed locally."}]})
        with ThreadPoolExecutor(max_workers=count) as pool:
            list(pool.map(write, range(count)))
        content = (self.repo / "AGENTS.local.md").read_text()
        for number in range(count):
            self.assertIn(f"Machine preference {number}.", content)

    def test_public_account_identifier_rejected_but_local_allowed(self):
        account = "123456" + "789012"
        self.begin()
        self.cli("assess", "--input", "-", data={"updates": [self.update(content=account)]}, ok=False)
        self.assess(local=[{"key": "account", "content": f"Local account: {account}.",
                            "evidence": "Confirmed locally."}])
        self.assertIn(account, (self.repo / "AGENTS.local.md").read_text())

    def test_code_paths_and_traversal_are_rejected(self):
        self.begin()
        for path in ("../AGENTS.md", "module/code.txt", ".worktrees/other/AGENTS.md", "/tmp/AGENTS.md"):
            self.cli("assess", "--input", "-", data={"updates": [self.update(path=path)]}, ok=False)
        self.assertEqual((self.repo / "module/code.txt").read_text(), "code\n")

    def test_tracked_hidden_configuration_directory_can_have_scoped_guidance(self):
        (self.repo / ".github").mkdir()
        (self.repo / ".github/config.txt").write_text("configuration\n")
        self.git("add", ".github/config.txt")
        self.git("commit", "-qm", "test: configuration directory")
        self.begin()
        self.assess([self.update(path=".github/AGENTS.md", replace="")])
        result = self.apply()
        self.assertIn("Use Python 3.", self.git("show", f'{result["commit"]}:.github/AGENTS.md').stdout)

    def test_symlink_target_is_never_overwritten(self):
        outside = Path(self.temp.name) / "outside.md"
        outside.write_text("private\n")
        (self.repo / "module/AGENTS.md").symlink_to(outside)
        self.begin()
        self.cli("assess", "--input", "-", data={"updates": [self.update(path="module/AGENTS.md")]}, ok=False)
        self.assertEqual(outside.read_text(), "private\n")

    def test_local_symlink_is_never_chmodded_or_overwritten(self):
        outside = Path(self.temp.name) / "outside-local.md"
        outside.write_text("private\n")
        outside.chmod(0o644)
        (self.repo / "AGENTS.local.md").symlink_to(outside)
        self.begin()
        self.cli("assess", "--input", "-", data={"local": [{"key": "env", "content": "env:TEST_TOKEN",
                 "evidence": "Observed locally."}]}, ok=False)
        self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o644)
        self.assertEqual(outside.read_text(), "private\n")

    def test_evidence_is_required(self):
        self.begin()
        self.cli("assess", "--input", "-", data={"updates": [self.update(evidence="")]}, ok=False)

    def test_isolated_commit_preserves_the_primary_index(self):
        self.begin()
        self.assess([self.update(), self.update(key="diagnosis", path="docs/troubleshooting/runtime.md",
            kind="troubleshooting", content="# Runtime diagnosis\n\nUse the supported interpreter.", replace="")])
        (self.repo / "module/code.txt").write_text("user change\n")
        self.git("add", "module/code.txt")
        staged = self.git("diff", "--cached").stdout
        result = self.apply()
        self.assertEqual(result["status"], "committed")
        self.assertEqual(self.git("diff", "--cached").stdout, staged)
        files = self.git("diff-tree", "--no-commit-id", "--name-only", "-r", result["commit"]).stdout.splitlines()
        self.assertEqual(set(files), {"AGENTS.md", "docs/troubleshooting/runtime.md"})
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.baseline)

    def test_idempotent_apply_and_published_receipt(self):
        self.begin()
        self.assess([self.update()])
        first = self.apply()
        self.assertEqual(self.apply()["commit"], first["commit"])
        self.cli("published", "--task", "issue-1", "--digest", first["digest"],
                 "--url", "https://example.com/pull/2")
        second = self.apply()
        self.assertEqual(second["status"], "published")
        self.assertEqual(second["commit"], first["commit"])
        self.assertEqual(len(self.git("worktree", "list", "--porcelain").stdout.split("worktree ")), 2)

    def test_empty_publication_identity_does_not_complete_the_receipt(self):
        self.begin()
        self.assess([self.update()])
        first = self.apply()
        for flag in ("--url", "--pr"):
            self.cli("published", "--task", "issue-1", "--digest", first["digest"], flag, "", ok=False)
        self.assertEqual(self.apply()["status"], "committed")
        self.assertTrue(Path(first["worktree"]).exists())

    def test_committed_retry_recreates_a_removed_worktree(self):
        self.begin()
        self.assess([self.update()])
        first = self.apply()
        self.git("worktree", "remove", first["worktree"])
        second = self.apply()
        self.assertTrue(Path(second["worktree"]).exists())
        self.assertEqual(second["commit"], first["commit"])

    def test_branch_collision_is_not_claimed_on_a_second_attempt(self):
        self.begin()
        self.assess([self.update()])
        pending = json.loads(self.cli("pending", "--task", "issue-1").stdout)
        import hashlib
        operations = [{key: value for key, value in item.items() if key not in {"evidence", "kind"}}
                      for item in pending["updates"]]
        digest = hashlib.sha256(json.dumps(operations, sort_keys=True).encode()).hexdigest()
        task_key = hashlib.sha256(b"issue-1").hexdigest()[:12]
        branch = f"docs/knowledge-{task_key}-1-{digest[:12]}"
        self.git("branch", branch)
        self.apply(ok=False)
        self.apply(ok=False)
        self.assertEqual(self.git("rev-parse", branch).stdout.strip(), self.baseline)

    def test_committed_branch_mutation_is_not_published_as_the_recorded_commit(self):
        self.begin()
        self.assess([self.update()])
        first = self.apply()
        self.git("update-ref", "refs/heads/" + first["branch"], self.baseline)
        self.apply(ok=False)

    def test_reverification_only_does_not_open_another_publication(self):
        self.begin()
        self.assess([self.update()])
        first = self.apply()
        self.cli("published", "--task", "issue-1", "--digest", first["digest"],
                 "--url", "https://example.com/pull/2")
        self.begin("review-b", role="review")
        self.assess([self.update(evidence="Reverified the same fact against the unchanged public behavior.")],
                    session="review-b")
        second = self.apply()
        self.assertEqual(second["status"], "published")
        self.assertEqual(second["commit"], first["commit"])
        self.assertEqual(second["digest"], first["digest"])

    def test_foreign_clone_at_the_owned_worktree_path_is_preserved(self):
        self.begin()
        self.assess([self.update()])
        first = self.apply()
        self.git("worktree", "remove", first["worktree"])
        self.git("clone", "-q", str(self.repo), first["worktree"])
        self.git("checkout", "-q", first["branch"], cwd=first["worktree"])
        self.apply(ok=False)
        self.assertTrue(Path(first["worktree"]).exists())

    def test_directory_swap_after_open_cannot_redirect_document_write(self):
        module = types.ModuleType("knowledge")
        module.__file__ = str(HELPER.with_suffix(".py"))
        exec(compile(HELPER.with_suffix(".py").read_text(), module.__file__, "exec"), module.__dict__)
        root = Path(self.temp.name) / "write-root"
        outside = Path(self.temp.name) / "outside"
        (root / "module").mkdir(parents=True)
        outside.mkdir()
        real_open = module.os.open
        swapped = False
        def swap_after_open(path, flags, *args, **kwargs):
            nonlocal swapped
            fd = real_open(path, flags, *args, **kwargs)
            if path == "module" and kwargs.get("dir_fd") is not None and not swapped:
                (root / "module").rename(root / "preserved")
                (root / "module").symlink_to(outside, target_is_directory=True)
                swapped = True
            return fd
        with patch.object(module.os, "open", side_effect=swap_after_open):
            module.write_document(root, "module/AGENTS.md", "verified guidance\n")
        self.assertTrue(swapped)
        self.assertFalse((outside / "AGENTS.md").exists())
        self.assertEqual((root / "preserved/AGENTS.md").read_text(), "verified guidance\n")

    def test_identical_managed_content_produces_no_new_commit(self):
        self.begin()
        self.assess([self.update()])
        first = self.apply()
        self.git("merge", "--ff-only", first["branch"])
        self.begin("dev-b")
        self.assess([self.update()], session="dev-b")
        # The second task models a later feature discovering the same fact.
        self.cli("begin", "--task", "issue-2", "--session", "dev-c", "--role", "dev")
        self.cli("assess", "--input", "-", data={"updates": [self.update()]})
        result = json.loads(self.cli("apply", "--task", "issue-2", "--base-ref", "main", "--merged-pr", "2").stdout)
        self.assertEqual(result["status"], "noop")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), first["commit"])

    def test_conflicting_legacy_replacement_does_not_commit(self):
        self.begin()
        self.assess([self.update(replace="A paragraph that no longer exists."), self.update(
            key="lesson", path="docs/lessons-learned/runtime.md", kind="lesson", content="# Lesson", replace="")])
        self.apply(ok=False)
        self.assertFalse((self.repo / "docs").exists())
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.baseline)
        self.assess([self.update()])
        self.assertEqual(self.apply()["status"], "committed")

    def test_discard_and_remove_are_explicit(self):
        self.begin()
        self.assess([self.update()])
        self.begin("review-b", role="review")
        self.assess([self.update(action="discard", content="")], session="review-b")
        self.assertEqual(self.apply()["status"], "noop")
        self.begin("review-c", role="review")
        self.assess([self.update()], session="review-c")
        first = self.apply()
        self.git("merge", "--ff-only", first["branch"])
        self.cli("begin", "--task", "issue-2", "--session", "dev-d", "--role", "dev")
        self.cli("assess", "--input", "-", data={"updates": [self.update(action="remove", content="")]})
        second = json.loads(self.cli("apply", "--task", "issue-2", "--base-ref", "main", "--merged-pr", "2").stdout)
        content = self.git("show", f'{second["commit"]}:AGENTS.md').stdout
        self.assertNotIn("knowledge:python-runtime", content)
        self.assertIn("Keep independent rules.", content)

    def test_stop_only_blocks_an_active_unassessed_session(self):
        def stop():
            return subprocess.run(["bash", str(HOOK)], cwd=self.repo, input=json.dumps({"cwd": str(self.repo)}),
                                  capture_output=True, text=True, env=self.env)
        self.assertEqual(stop().returncode, 0)
        self.begin()
        result = stop()
        self.assertEqual(result.returncode, 2)
        self.assertIn("assess", result.stderr)
        self.cli("assess", "--none", "No new durable facts.")
        result = stop()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, "")

    def test_hook_uses_event_worktree_directory(self):
        self.begin()
        result = subprocess.run(["bash", str(HOOK)], cwd=self.temp.name,
                                input=json.dumps({"cwd": str(self.repo)}),
                                text=True, capture_output=True, env=self.env)
        self.assertEqual(result.returncode, 2)
        self.assertIn("assess", result.stderr)

    def test_installers_register_the_stop_gate(self):
        installers = SOURCE / "skills/autonomous-common/scripts"
        for agent, destination, event in (("claude", ".claude/settings.json", "Stop"),
                                          ("codex", ".codex/hooks.json", "Stop"),
                                          ("kiro", ".kiro/agents/default.json", "stop")):
            result = subprocess.run(["bash", str(installers / f"install-{agent}-hooks.sh"), "--no-git-hook"],
                                    cwd=self.repo, env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            settings = json.loads((self.repo / destination).read_text())
            self.assertIn("check-session-knowledge.sh", json.dumps(settings["hooks"][event]))


unittest.main(verbosity=2)
PY
