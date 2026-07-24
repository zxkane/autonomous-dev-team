# Test cases: block-commit command context

Issues #534 and #537 are covered by
`tests/unit/test-block-commit-outside-worktree.sh`. The test creates two
independent repositories and linked worktrees under a fresh `mktemp` directory,
so it is safe under the parallel unit runner.

## Repository policy cases

| ID | Scenario | Unit assertion |
|---|---|---|
| `TC-BCOW-001` | Exact reproduction: hook cwd is repo A main; command is `cd ~/unrelated-repo && git add some/file && git commit ...` | Hook exits `0`; this assertion fails with exit `2` on the parent implementation |
| `TC-BCOW-002` | Bare commit from repo A main | Hook exits `2` |
| `TC-BCOW-003` | Explicit absolute `cd` to repo A main | Hook exits `2` |
| `TC-BCOW-004` | Explicit `cd` to repo A linked worktree | Hook exits `0` |
| `TC-BCOW-005` | Explicit `cd` to repo B main | Hook exits `0` |
| `TC-BCOW-006` | Explicit `cd` to repo B linked worktree | Hook exits `0` |
| `TC-BCOW-007` | Relative, single-quoted, double-quoted, literal/escaped-backslash, escaped-quote, symlinked, tilde, and symlink-plus-`..` paths | Helper returns the canonical target; double-quote escapes are decoded without expansion, and `cd` applies logical dot-segment handling before canonicalization |
| `TC-BCOW-008` | One two-token `git -C <repo-B> commit`, with absolute/quoted, relative, and symlink-plus-`..` paths | Hook exits `0`; helper resolves from its base directory using physical filesystem traversal |
| `TC-BCOW-009` | Missing path and existing non-git directory from repo A main | Target probing falls back to hook cwd; hook exits `2` |
| `TC-BCOW-011` | Bare commit with hook cwd in repo A linked worktree | Hook exits `0` |
| `TC-BCOW-012` | A command containing `--amend` from repo A main | Existing blanket exemption remains; hook exits `0` |

These assertions cover all rows of the repository decision table: A main
(`002`/`003`), A linked (`004`/`011`), B main (`001`/`005`/`008`), B linked
(`006`), unresolved target (`009`), and unsupported target (`010` below).

## Parser safety cases

| ID | Scenario | Unit assertion |
|---|---|---|
| `TC-BCOW-010` | Variable expansion, command substitution, backticks, process substitution, arithmetic expansion, brace expansion, repeated `cd`, special `cd -`, mixed `cd` plus `git -C`, another command between `cd` and commit, malformed quotes, expansion/escape syntax inside command words, generic git global options, whole/fragmented ANSI-C command words using literal, hex, octal, modulo-octal, Unicode, control, invalid, or segment-truncated content, multiple commits, multiple `-C`, attached `-C<path>`, subshell, pipeline, background command, `;`, `||`, `env`, and `sudo` | The helper returns empty output/`2` and the hook exits `2` from repo A main for every form; command/process-substitution sentinels remain absent |
| `TC-BCOW-013` | Direct helper contract | Supported match returns canonical cwd/`0`; deterministic ANSI-C non-git input, a NUL segment followed by a non-git suffix, and ordinary no-match input return empty/`1`; unsupported or missing-path match returns empty/`2` |
| `TC-BCOW-014` | Variable-bearing arguments to `-C`, `-c`, `--git-dir`, `--work-tree`, `--namespace`, and `--super-prefix`, including long `--flag=value` forms and compound statements | Non-commit operations return empty/`1` and the hook exits `0`; variable-bearing or command-substitution operation words return empty/`2` and the hook exits `2` |
| `TC-BCOW-015` | Bare, looped, and chained commits; escaped or dynamic global flag spellings; field-splitting, process-substitution, escaped-space, and quoted-multiword flag operands; dynamic operation words; plus unchanged literal-path, no-global-flag, and linked-worktree contexts | Real or hidden commits remain blocked from repo A main, including commits injected by unsafe option syntax; read-only commands and linked-worktree commits retain their previous outcomes |

`TC-BCOW-010` passes all command strings as inert JSON data to the hook. The
sentinel assertions prove the hook does not execute path-producing input.

## Acceptance mapping

| Acceptance criterion | Evidence |
|---|---|
| Exact false-positive fixed | `TC-BCOW-001` is red before the implementation and green after it |
| Repository identity and worktree policy | `TC-BCOW-002` through `TC-BCOW-009`, plus `TC-BCOW-011` |
| Input never executed; unsupported syntax fails closed | `TC-BCOW-010` and absent sentinels |
| Existing behavior preserved | `TC-BCOW-011`, `TC-BCOW-012`, and the full unit suite |
| Helper exit contract | `TC-BCOW-007` and `TC-BCOW-013` |
| Variable global-flag arguments are not operation words | `TC-BCOW-014` |
| Real and hidden commits remain fail-closed | `TC-BCOW-014` and `TC-BCOW-015` |
