# Design: block-commit command context

Issue #534 changes `block-commit-outside-worktree.sh` so worktree policy is
applied to the repository targeted by the matching `git commit`, rather than
unconditionally to the hook process's current directory.

## Problem

The hook's boolean detector can find a commit in a chained command, but the
subsequent `git rev-parse` calls always run in the inherited current directory.
For example, a hook installed in repo A currently blocks this command even
though the commit targets unrelated repo B:

```text
cd ~/unrelated-repo && git add some/file && git commit -m "unrelated change"
```

The hook needs a bounded command-context resolver. It must not execute or fully
interpret shell input.

## Helper contract

`resolve_git_command_cwd <operation> <command> <base-dir>` is defined in
`skills/autonomous-common/hooks/lib.sh`.

| Exit | Meaning | Standard output |
|---:|---|---|
| `0` | Exactly one supported matching invocation has a resolvable cwd | Canonical absolute cwd plus newline |
| `1` | No matching invocation exists | Empty |
| `2` | A matching invocation exists, but its cwd is ambiguous, unsupported, or unresolvable | Empty |

The helper never changes the caller's current directory. Directory
canonicalization runs in a subshell with the parsed path passed as a quoted
argument. Command text is never passed to `eval`, `source`, `bash -c`, or any
other execution mechanism.

## Supported grammar

The complete supported command grammar is:

```text
git <operation> ...
cd <literal-path> && git <operation> ...
cd <literal-path> && git add ... && git <operation> ...
git -C <literal-path> <operation> ...
```

There must be exactly one matching invocation. A literal path is one of:

- an absolute or relative unquoted shell word;
- unquoted `~` or `~/...`, expanded only with `HOME`;
- one single-quoted literal; or
- one double-quoted literal containing no expansion or escape syntax.

Relative `cd` and `git -C` paths are resolved from `<base-dir>`. Mixed quoting,
shell expansion syntax, and a missing or non-directory target are not resolved.

Unsupported forms include repeated `cd`, `cd` combined with `git -C`, another
command between `cd` and the commit, other git global options before the
operation, subshells, pipelines, background commands, `;` or `||` control flow,
`env` or `sudo` wrappers, variable/command/process/arithmetic/brace expansion,
malformed quoting, option-like or special `cd` operands, multiple matching
invocations, multiple `-C` options, and attached `-C<path>`.

This is deliberately not a general shell parser. The existing
`is_git_command` function remains the boolean detector; command-context
resolution is a separate, stricter step.

## Hook flow

1. Capture the hook cwd and repo A's canonical `git-common-dir`.
2. Run the boolean detector and command-context resolver independently.
3. Exit when both report that no matching invocation exists.
4. Preserve the blanket `--amend` exemption.
5. On helper exit `2`, discard partial context and use the hook cwd.
6. Probe the selected target only with `git -C "$target"`.
7. If target probing fails, use the hook cwd as the fail-closed target.
8. Compare canonical `git-common-dir` values before applying repo A's
   worktree policy.

Helper exit `1` is a no-op because there is no matching invocation. Helper exit
`2` is fail-closed: uncertainty never allows a commit that the inherited-cwd
policy would block.

## Repository decision table

| Resolved target | Repo identity | Worktree state | Hook exit |
|---|---|---|---:|
| repo A main worktree | same canonical `git-common-dir` | `git-dir == git-common-dir` | `2` |
| repo A linked worktree | same canonical `git-common-dir` | `git-dir != git-common-dir` | `0` |
| repo B main worktree | different canonical `git-common-dir` | any | `0` |
| repo B linked worktree | different canonical `git-common-dir` | any | `0` |
| missing/non-git path | unresolved | fail-closed against hook cwd | inherited-cwd result (`2` in the main-worktree fixture) |
| unsupported/ambiguous syntax | unresolved | fail-closed against hook cwd | inherited-cwd result (`2` in the main-worktree fixture) |

## Security properties

- No command input is executed.
- Quoting is parsed one character at a time; expansion syntax is rejected
  rather than interpreted.
- A path is used only as a quoted argument to directory and `git -C` probes.
- Canonical absolute paths are compared, so relative spelling and symlinks do
  not change repository identity.
- Unsupported syntax cannot bypass the existing worktree requirement.

## Test plan

The hermetic unit fixture creates repo A and repo B, plus one linked worktree
for each, under a fresh temporary directory. It invokes the real hook from each
required cwd and sources the helper for direct exit-contract assertions. See
`docs/test-cases/block-commit-command-context.md`.
