#!/usr/bin/env python3
"""Retain verified session candidates and commit optional post-merge docs."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import unquote


class KnowledgeError(Exception):
    pass


def git(root, *args, allow_failure=False):
    # Linked worktrees have their own index. Never inherit an index override.
    env = {k: v for k, v in os.environ.items() if k not in {
        "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"}}
    result = subprocess.run(["git", "-C", str(root), *args], env=env,
                            capture_output=True, text=True)
    if result.returncode and not allow_failure:
        # Git hooks and credentials helpers can print secrets on failure.
        raise KnowledgeError(f"Git {args[0]} failed (exit {result.returncode}); writeback remains pending.")
    return result


def relative_path(relative):
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or path.as_posix() != relative or any(p in {"..", "."} for p in path.parts):
        raise KnowledgeError("Expected a repository-relative path without traversal.")
    return path


def safe_path(root, relative):
    path = relative_path(relative)
    target = root
    for part in path.parts:
        target /= part
        if target.is_symlink():
            raise KnowledgeError("Refusing a symbolic-link destination or parent.")
        if target.exists() and target != root / path and not target.is_dir():
            raise KnowledgeError("Destination parent is not a directory.")
    if target.exists() and not target.is_file() and not target.is_dir():
        raise KnowledgeError("Destination is not a regular file or directory.")
    return target


def atomic_write(path, content):
    safe_path(path.parent, path.name)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=".knowledge-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            os.chmod(temporary, 0o600)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        safe_path(path.parent, path.name)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def save_json(path, value):
    atomic_write(path, json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")


def write_document(root, relative, content):
    """Anchor every parent and the replacement to descriptors, without symlink traversal."""
    parts = relative_path(relative).parts
    directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = ".knowledge-" + uuid.uuid4().hex
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, mode=0o755, dir_fd=directory_fd)
            except FileExistsError:
                pass
            child_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = child_fd
        try:
            destination = os.stat(parts[-1], dir_fd=directory_fd, follow_symlinks=False)
            if not stat.S_ISREG(destination.st_mode):
                raise KnowledgeError("Public documentation destination is not a regular file.")
        except FileNotFoundError:
            pass
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=directory_fd)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, parts[-1], src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    finally:
        try:
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        finally:
            os.close(directory_fd)


def load_json(path):
    safe_path(path.parent, path.name)
    return json.loads(path.read_text()) if path.exists() else None


def scan_text(value, public=False, private_references=()):
    patterns = [r"-----BEGIN [A-Z ]*PRIVATE KEY-----", r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
                r"\bgh[opusr]_[A-Za-z0-9]{20,}\b", r"\bgithub_pat_[A-Za-z0-9_]{20,}\b",
                r"\bsk-[A-Za-z0-9_-]{20,}\b"]
    if any(re.search(pattern, value) for pattern in patterns):
        raise KnowledgeError("Possible credential literal rejected. Record its environment/file reference instead.")
    assignments = re.finditer(
        r'''(?ix)\b(?:password|passwd|client[_-]?secret|api[_-]?key|access[_-]?token|token|private[_-]?key|aws_secret_access_key)\b
            ["']?\s*[:=]\s*("[^"]*"|'[^']*'|`[^`]*`|<[^>]*>|\{[^}]*\}|[^\s,;]+)''', value)
    for assignment in assignments:
        assigned = assignment.group(1).strip("\"'`")
        name = r"[A-Za-z_][A-Za-z0-9_]*"
        reference = re.fullmatch(
            rf'''env:{name}|\${name}|\$\{{{name}\}}|process\.env\.{name}|
                os\.environ\[(?:"{name}"|'{name}')\]|os\.getenv\((?:"{name}"|'{name}')\)|
                <[^<>]+>|\{{[^{{}}]+\}}|file:[^$|;&`'"]+''', assigned, re.X)
        remainder = value[assignment.end():]
        remainder = re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", "", remainder)
        fallback = re.match(r"\s*(?:\|\||\?\?|\bor\b|\?)", remainder)
        if fallback or (assigned and assigned not in {"null", "None", "REDACTED", "..."} and not reference):
            raise KnowledgeError("Credential assignment must use a pure reference or placeholder, without literal defaults.")
    if public:
        normalized = unquote(value).casefold()
        if any(reference.casefold() in normalized for reference in private_references) or re.search(
                r"issuecomment-[0-9]+|(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|<owner>/<repo>)#[0-9]+", normalized):
            raise KnowledgeError("Private/cross-repository reference rejected; use generic phrasing in public knowledge.")
        if re.search(r"\b\d{12}\b|/(?:home|Users)/[A-Za-z0-9_.-]+/", value):
            raise KnowledgeError("Public knowledge requires placeholders for environment identifiers.")
        for address in re.findall(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", value):
            if not address.endswith(("@example.com", "@example.net")):
                raise KnowledgeError("Public knowledge requires placeholder email addresses.")


def text_field(item, key, required=True):
    value = item.get(key, "")
    if not isinstance(value, str) or len(value) > 16384 or (required and not value.strip()):
        raise KnowledgeError(f"Expected a nonempty, bounded {key} string.")
    return value.strip()


def validate_update(root, item, local=False, private_references=(), check_destination=True):
    if not isinstance(item, dict):
        raise KnowledgeError("Each learning must be an object.")
    allowed_fields = {"key", "action", "content", "evidence"} | (set() if local else {"path", "kind", "replace"})
    if item.keys() - allowed_fields:
        raise KnowledgeError("Unknown learning fields; use the documented assessment schema.")
    key = text_field(item, "key")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", key):
        raise KnowledgeError("Learning keys must be short lowercase identifiers.")
    action = item.get("action", "upsert")
    if action not in {"upsert", "remove", "discard"}:
        raise KnowledgeError("Unknown learning action.")
    content = text_field(item, "content", action == "upsert")
    evidence = text_field(item, "evidence")
    if "<!-- knowledge:" in content:
        raise KnowledgeError("Learning content cannot inject managed-section markers.")
    scan_text(content + "\n" + evidence, public=not local and action == "upsert", private_references=private_references)
    result = {"key": key, "action": action, "content": content, "evidence": evidence}
    if local:
        return result
    path = text_field(item, "path")
    parts = relative_path(path).parts
    reserved = {".git", ".ssh", ".worktrees", ".agents", ".agent", ".venv", "node_modules", "vendor"}
    if any(part in reserved for part in parts) or re.search(r"[\x00-\x1f\x7f]", path) or (
            len(parts) > 1 and parts[0] in {".claude", ".codex", ".kiro"} and parts[1] in {"skills", "state"}):
        raise KnowledgeError("Knowledge cannot target runtime, installed or vendor directories.")
    kind = item.get("kind", "guidance")
    allowed = (kind == "guidance" and PurePosixPath(path).name == "AGENTS.md") or (
        kind == "troubleshooting" and path.startswith("docs/troubleshooting/") and path.endswith(".md")) or (
        kind in {"lesson", "decision", "verification", "tooling"} and
        path.startswith("docs/lessons-learned/") and path.endswith(".md"))
    if not allowed:
        raise KnowledgeError("Knowledge targets must be scoped AGENTS.md or the dedicated documentation directories.")
    scan_text(path + "\n" + key, public=action == "upsert", private_references=private_references)
    if check_destination:
        target = safe_path(root, path)
        if kind == "guidance" and not target.parent.is_dir():
            raise KnowledgeError("Place guidance in an existing relevant repository directory.")
        if git(root, "check-ignore", "--no-index", "--", path, allow_failure=True).returncode == 0:
            raise KnowledgeError("Public knowledge cannot target a Git-ignored path.")
        if target.exists() and not target.is_file():
            raise KnowledgeError("Knowledge destination is not a regular file.")
    replace = text_field(item, "replace", False)
    # Legacy identifiers may need removal. This field remains in private receipts
    # and is never rendered; credential VALUES are still forbidden everywhere.
    scan_text(replace)
    result.update(path=path, kind=kind, replace=replace)
    return result


def edit_section(original, update):
    key, content, action = update["key"], update["content"], update["action"]
    if action == "discard":
        return original
    start, end = f"<!-- knowledge:{key}:start -->", f"<!-- knowledge:{key}:end -->"
    if original.count(start) != original.count(end) or original.count(start) > 1:
        raise KnowledgeError("Ambiguous or damaged managed section; correct the candidate before retrying.")
    block = f"{start}\n{content}\n{end}"
    if start in original:
        left, right = original.index(start), original.index(end) + len(end)
        if original.index(end) < left:
            raise KnowledgeError("Invalid managed-section ordering.")
        result = original[:left] + (block if action == "upsert" else "") + original[right:]
        return result if action == "upsert" else result.rstrip() + "\n"
    replace = update.get("replace", "")
    if replace:
        if original.count(replace) != 1:
            raise KnowledgeError("Legacy replacement is stale or ambiguous; correct the candidate before retrying.")
        result = original.replace(replace, block if action == "upsert" else "", 1)
        return result if action == "upsert" else result.rstrip() + "\n"
    if action != "upsert" or content in original:
        return original
    return (original.rstrip() + "\n\n" if original.strip() else "") + block + "\n"


class Repository:
    def __init__(self, directory):
        self.root = Path(git(directory, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
        self.common = Path(git(self.root, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()).resolve()
        self.git_dir = Path(git(self.root, "rev-parse", "--path-format=absolute", "--git-dir").stdout.strip()).resolve()
        roots = git(self.root, "worktree", "list", "--porcelain").stdout.splitlines()
        self.primary = Path(next(line[9:] for line in roots if line.startswith("worktree "))).resolve()
        self.active_path = safe_path(self.git_dir, "session-knowledge-active.json")
        self.active = load_json(self.active_path) or {}
        if self.active.get("branch") != self.branch():
            self.active = {}

    def branch(self):
        return git(self.root, "branch", "--show-current").stdout.strip()

    def head(self):
        return os.environ.get("AUTONOMOUS_KNOWLEDGE_HEAD") or git(self.root, "rev-parse", "HEAD").stdout.strip()

    def assessment_head(self, assessment):
        # Stop's cwd can be the launcher checkout, not the worktree the agent
        # assessed. Bind the receipt to its actual source and verify ownership.
        source = Path(assessment.get("source_root", str(self.root))).resolve()
        try:
            common = Path(git(source, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()).resolve()
            branch = git(source, "branch", "--show-current").stdout.strip()
            if common != self.common or branch != assessment.get("source_branch", branch):
                return None
            return os.environ.get("AUTONOMOUS_KNOWLEDGE_HEAD") or git(source, "rev-parse", "HEAD").stdout.strip()
        except KnowledgeError:
            return None

    def identity(self, args):
        task = args.task or os.environ.get("AUTONOMOUS_KNOWLEDGE_TASK") or self.active.get("task")
        session = args.session or os.environ.get("AUTONOMOUS_KNOWLEDGE_SESSION") or self.active.get("session")
        if args.command == "begin":
            task = task or "branch-" + hashlib.sha256(self.branch().encode()).hexdigest()[:16]
            session = session or "interactive-" + str(uuid.uuid4())
        for value in (task, session):
            if value and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,159}", value):
                raise KnowledgeError("Invalid task/session identifier.")
        return task, session

    def private_references(self):
        configured = os.environ.get("SESSION_KNOWLEDGE_REDACTION_FILE")
        if configured:
            policy = Path(configured).expanduser()
            policy = (policy if policy.is_absolute() else self.primary / policy).resolve()
        else:
            policy = safe_path(self.common, "session-knowledge/security.local.json")
        if not policy.exists():
            if configured:
                raise KnowledgeError("Configured private-reference policy is missing.")
            return []
        if not policy.is_file() or stat.S_IMODE(policy.stat().st_mode) & 0o077:
            raise KnowledgeError("Private-reference policy must be a private mode-600 JSON file.")
        try:
            relative = policy.relative_to(self.root)
        except ValueError:
            relative = None
        if relative and self.common not in policy.parents and git(
                self.root, "check-ignore", "--no-index", "--", str(relative), allow_failure=True).returncode:
            raise KnowledgeError("Private-reference policy must be outside tracked content or Git-ignored.")
        data = load_json(policy)
        references = data.get("private_references", []) if isinstance(data, dict) else None
        if not isinstance(references, list) or len(references) > 256 or any(not isinstance(item, str) or not item or len(item) > 256 for item in references):
            raise KnowledgeError("Private-reference policy must contain a bounded list of private_references strings.")
        return references

    def ensure_exclusions(self):
        with locked_file(safe_path(self.common, "session-knowledge/exclusions.lock")):
            path = safe_path(self.common, "info/exclude")
            existing = path.read_text() if path.exists() else ""
            patterns = [".worktrees/", "*.local.*", ".local.json", "CLAUDE.local.md", ".env", ".env.*"]
            missing = [pattern for pattern in patterns if pattern not in existing.splitlines()]
            if missing:
                atomic_write(path, existing.rstrip() + "\n" + "\n".join(missing) + "\n")

    def write_local(self, updates):
        if not updates:
            return
        with locked_file(safe_path(self.common, "session-knowledge/local.lock")):
            path = safe_path(self.primary, "AGENTS.local.md")
            if git(self.primary, "ls-files", "--error-unmatch", "--", "AGENTS.local.md", allow_failure=True).returncode == 0:
                raise KnowledgeError("AGENTS.local.md is tracked; refuse to write machine-local knowledge.")
            self.ensure_exclusions()
            if git(self.primary, "check-ignore", "--", "AGENTS.local.md", allow_failure=True).returncode:
                raise KnowledgeError("AGENTS.local.md must be ignored before writing local knowledge.")
            content = path.read_text() if path.exists() else "# Local agent knowledge\n"
            for update in updates:
                content = edit_section(content, update)
            atomic_write(path, content)


@contextmanager
def locked_file(lock_path):
    safe_path(lock_path.parent, lock_path.name)
    lock_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise KnowledgeError("Knowledge task is busy; retry the assessment.")
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)


@contextmanager
def locked_task(repo, task):
    directory = safe_path(repo.common, "session-knowledge/tasks/" + task)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Only directories owned by this feature are made private.
    for path in (repo.common / "session-knowledge", directory.parent, directory):
        path.chmod(0o700)
    with locked_file(safe_path(directory, "lock")):
        yield directory


def receipts(directory):
    return [load_json(path) for path in sorted(directory.glob("session-*.json"))]


def snapshot(directory):
    records = receipts(directory)
    latest = {}
    for record in records:
        for update in record.get("updates", []):
            key = (update["path"], update["key"])
            sequence = update.get("_sequence", record.get("sequence", 0))
            if key not in latest or sequence > latest[key][0]:
                latest[key] = (sequence, update)
    updates = [{key: value for key, value in item.items() if key != "_sequence"}
               for _, (_, item) in sorted(latest.items()) if item["action"] != "discard"]
    return {"updates": updates, "unassessed": sum(record["status"] != "assessed" for record in records)}


def dirty_paths(root):
    status = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all").stdout
    paths = []
    for entry in status.split("\0"):
        if not entry:
            continue
        if entry[0] in "RC" or entry[1] in "RC":
            raise KnowledgeError("Unexpected rename/copy in knowledge worktree.")
        paths.append(entry[3:])
    return paths


def verify_worktree(repo, worktree, branch):
    common = Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()).resolve()
    root = Path(git(worktree, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
    if common != repo.common or root != worktree.resolve() or git(worktree, "branch", "--show-current").stdout.strip() != branch:
        raise KnowledgeError("Knowledge worktree belongs to a different repository or branch.")


def apply_updates(repo, directory, args):
    data = snapshot(directory)
    if not data["updates"]:
        return {"status": "pending" if data["unassessed"] else "noop", "unassessed": data["unassessed"]}
    if not re.fullmatch(r"[1-9][0-9]*", args.merged_pr or ""):
        raise KnowledgeError("A confirmed merged PR identifier is required.")
    private_references = repo.private_references()
    for update in data["updates"]:
        validate_update(repo.root, update, private_references=private_references, check_destination=False)
    # Evidence/classification stay in private receipts; only planned public edits
    # determine whether an already-published update needs a new commit/PR.
    operations = [{key: value for key, value in item.items() if key not in {"evidence", "kind"}}
                  for item in data["updates"]]
    digest = hashlib.sha256(json.dumps(operations, sort_keys=True).encode()).hexdigest()
    receipt_path = safe_path(directory, f"publication-{args.merged_pr}-{digest}.json")
    previous = load_json(receipt_path)
    if previous and previous.get("base_ref", args.base_ref) != args.base_ref:
        raise KnowledgeError("Knowledge receipt belongs to a different merge target; preserve it for inspection.")
    # Never expose an issue-N token: INV-86 treats it as issue/PR linkage.
    task_key = hashlib.sha256(args.task.encode()).hexdigest()[:12]
    branch = f"docs/knowledge-{task_key}-{args.merged_pr}-{digest[:12]}"
    worktree = safe_path(repo.primary, ".worktrees/" + branch)
    if previous and previous["status"] in {"published", "noop"}:
        return previous
    branch_exists = git(repo.root, "show-ref", "--verify", "refs/heads/" + branch, allow_failure=True).returncode == 0
    if previous and previous["status"] == "committed":
        actual = git(repo.root, "rev-parse", "--verify", "refs/heads/" + branch).stdout.strip()
        if actual != previous["commit"] or previous["branch"] != branch:
            raise KnowledgeError("The committed knowledge branch changed; preserve it for inspection.")
        for path in previous["files"]:
            scan_text(git(repo.root, "show", f"{previous['commit']}:{path}").stdout,
                      public=True, private_references=private_references)
        if not worktree.exists():
            worktree.parent.mkdir(parents=True, exist_ok=True)
            git(repo.root, "worktree", "add", str(worktree), branch)
        verify_worktree(repo, worktree, branch)
        if dirty_paths(worktree) or (
                git(worktree, "rev-parse", "HEAD").stdout.strip() != previous["commit"]):
            raise KnowledgeError("Committed knowledge worktree has unrelated edits; preserve it for inspection.")
        previous["worktree"] = str(worktree)
        save_json(receipt_path, previous)
        return previous
    if not previous and (branch_exists or worktree.exists()):
        raise KnowledgeError("Knowledge branch/worktree already exists without an owned receipt.")
    base = git(repo.root, "rev-parse", "--verify", "--end-of-options", args.base_ref + "^{commit}").stdout.strip()
    result = previous or {"status": "pending", "digest": digest, "branch": branch,
                          "base": base, "base_ref": args.base_ref, "worktree": str(worktree), "merged_pr": args.merged_pr}
    base = result["base"]
    save_json(receipt_path, result)
    repo.ensure_exclusions()
    if not worktree.exists():
        worktree.parent.mkdir(parents=True, exist_ok=True)
        git(repo.root, "worktree", "add", *([] if branch_exists else ["-b", branch]), str(worktree), branch if branch_exists else base)
    verify_worktree(repo, worktree, branch)
    desired, originals = {}, {}
    for update in data["updates"]:
        validate_update(worktree, update, private_references=private_references)
        path = update["path"]
        if path not in desired:
            before = git(worktree, "show", f"{base}:{path}", allow_failure=True)
            desired[path] = before.stdout if before.returncode == 0 else ""
            originals[path] = desired[path]
        desired[path] = edit_section(desired[path], update)
    for content in desired.values():
        scan_text(content, public=True, private_references=private_references)
    changed = sorted(path for path in desired if desired[path] != originals[path])
    dirty = dirty_paths(worktree)
    if any(path not in changed or safe_path(worktree, path).read_text() != desired[path] for path in dirty):
        raise KnowledgeError("Knowledge worktree has unrelated edits; preserve it for inspection.")
    head = git(worktree, "rev-parse", "HEAD").stdout.strip()
    trailer = "Knowledge-Digest: " + digest
    if head != base:
        message = git(worktree, "log", "-1", "--format=%B").stdout
        count = git(worktree, "rev-list", "--count", base + "..HEAD").stdout.strip()
        committed_paths = git(worktree, "diff", "--name-only", "-z", base, "HEAD").stdout.rstrip("\0").split("\0")
        if dirty or trailer not in message.splitlines() or count != "1" or set(committed_paths) != set(changed) or any(
                git(worktree, "show", f"HEAD:{path}").stdout != desired[path] for path in changed):
            raise KnowledgeError("Unexpected commit in knowledge worktree; preserve it for inspection.")
    elif changed:
        for path in changed:
            write_document(worktree, path, desired[path])
        git(worktree, "diff", "--check")
        git(worktree, "add", "--", *changed)
        git(worktree, "diff", "--cached", "--check")
        git(worktree, "commit", "-m", "docs(knowledge): retain verified session lessons\n\n" + trailer)
        head = git(worktree, "rev-parse", "HEAD").stdout.strip()
        committed_paths = git(worktree, "diff", "--name-only", "-z", base, "HEAD").stdout.rstrip("\0").split("\0")
        if set(committed_paths) != set(changed) or dirty_paths(worktree) or any(
                git(worktree, "show", f"HEAD:{path}").stdout != desired[path] for path in changed):
            raise KnowledgeError("Commit hooks changed the planned documentation; preserve the pending worktree for inspection.")
    result.update(status="committed" if changed else "noop", commit=head if changed else "", files=changed)
    save_json(receipt_path, result)
    if not changed:
        git(repo.root, "worktree", "remove", str(worktree))
        git(repo.root, "update-ref", "-d", "refs/heads/" + branch, base)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("begin", "assess", "check", "pending", "apply", "published"):
        sub = commands.add_parser(command)
        sub.add_argument("--task")
        sub.add_argument("--session")
        if command == "begin":
            sub.add_argument("--role", choices=("dev", "review"), default="dev")
            sub.add_argument("--no-active", action="store_true")
        if command == "assess":
            source = sub.add_mutually_exclusive_group(required=True)
            source.add_argument("--input", help="JSON file, or '-' for stdin")
            source.add_argument("--none", help="Reason no durable update is needed")
        if command == "apply":
            sub.add_argument("--base-ref", required=True)
            sub.add_argument("--merged-pr", required=True)
        if command == "published":
            sub.add_argument("--digest", required=True)
            sub.add_argument("--merged-pr")
            publication = sub.add_mutually_exclusive_group(required=True)
            publication.add_argument("--url")
            publication.add_argument("--pr")
    args = parser.parse_args()
    repo = Repository(args.repo)
    task, session = repo.identity(args)
    if not task or (args.command in {"begin", "assess", "check"} and not session):
        if args.command == "check":
            return 0
        raise KnowledgeError("Begin an assessment or supply a task/session identifier.")
    args.task = task
    with locked_task(repo, task) as directory:
        receipt = safe_path(directory, "session-" + hashlib.sha256((session or "").encode()).hexdigest() + ".json")
        current = load_json(receipt)
        if args.command == "begin":
            if not current:
                save_json(receipt, {"status": "pending", "session": session, "role": args.role, "updates": [], "sequence": 0})
            if not args.no_active:
                save_json(repo.active_path, {"task": task, "session": session, "branch": repo.branch()})
            output = {"task": task, "session": session, "status": "begun"}
        elif args.command == "check":
            if not current or current["status"] != "assessed" or not current.get("head") or current["head"] != repo.assessment_head(current):
                source = (current or {}).get("source_root", str(repo.root))
                print(f"Assess durable session knowledge from source worktree {source} before finishing. "
                      "Use session-knowledge.sh assess --input <json-file> "
                      "or assess --none 'reason no update is needed'. No lesson or documentation change is required.", file=sys.stderr)
                return 2
            return 0
        elif args.command == "assess":
            if not current:
                raise KnowledgeError("Begin this session before recording its assessment.")
            if args.none:
                data = {"updates": [], "local": [], "reason": args.none}
            else:
                raw = sys.stdin.read(131073) if args.input == "-" else Path(args.input).read_text()
                if len(raw) > 131072:
                    raise KnowledgeError("Assessment is too large; retain facts, not transcripts.")
                data = json.loads(raw)
            if not isinstance(data, dict) or data.keys() - {"updates", "local", "reason"} or not isinstance(data.get("updates", []), list) or not isinstance(data.get("local", []), list):
                raise KnowledgeError("Assessment must contain updates/local arrays.")
            private_references = repo.private_references() if data.get("updates") else []
            updates = [validate_update(repo.root, item, private_references=private_references) for item in data.get("updates", [])]
            local = [validate_update(repo.primary, item, local=True) for item in data.get("local", [])]
            reason = text_field(data, "reason", not updates and not local)
            scan_text(reason)
            if len({(value["path"], value["key"]) for value in updates}) != len(updates):
                raise KnowledgeError("Each assessment must have unique path/key pairs.")
            repo.write_local(local)
            sequence = max((item.get("sequence", 0) for item in receipts(directory)), default=0) + 1
            retained = {(item["path"], item["key"]): {**item, "_sequence": item.get("_sequence", current.get("sequence", 0))}
                        for item in current.get("updates", [])}
            retained.update({(item["path"], item["key"]): {**item, "_sequence": sequence} for item in updates})
            current.update(status="assessed", head=repo.head(), source_root=str(repo.root), source_branch=repo.branch(),
                           updates=list(retained.values()), reason=reason,
                           local_count=len(local), sequence=sequence)
            save_json(receipt, current)
            output = {"status": "assessed", "public_updates": len(updates), "local_updates": len(local)}
        elif args.command == "pending":
            output = snapshot(directory)
        elif args.command == "apply":
            output = apply_updates(repo, directory, args)
        else:
            matches = [path for path in directory.glob("publication-*.json") if load_json(path).get("digest") == args.digest
                       and (not args.merged_pr or load_json(path).get("merged_pr") == args.merged_pr)]
            if len(matches) != 1 or (args.url is not None and not re.fullmatch(r"https://[^\s]+", args.url)) or (
                    args.pr is not None and not re.fullmatch(r"[1-9][0-9]*", args.pr)):
                raise KnowledgeError("A unique committed receipt and PR URL/number are required.")
            output = load_json(matches[0])
            if output["status"] not in {"committed", "published"}:
                raise KnowledgeError("Cannot publish an uncommitted knowledge update.")
            worktree = Path(output["worktree"])
            if worktree.exists():
                verify_worktree(repo, worktree, output["branch"])
                if dirty_paths(worktree) or git(worktree, "rev-parse", "HEAD").stdout.strip() != output["commit"]:
                    raise KnowledgeError("Published worktree has unexpected edits; preserve it for inspection.")
                git(repo.root, "worktree", "remove", str(worktree))
            output.update(status="published", **({"url": args.url} if args.url else {"pr": args.pr}))
            save_json(matches[0], output)
        print(json.dumps(output, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KnowledgeError, OSError, ValueError, TypeError, KeyError) as exc:
        # JSON decode errors can embed input; never print those values.
        message = str(exc) if isinstance(exc, KnowledgeError) else "Invalid or inaccessible knowledge data; no completion recorded."
        print("session-knowledge: " + message, file=sys.stderr)
        sys.exit(2)
