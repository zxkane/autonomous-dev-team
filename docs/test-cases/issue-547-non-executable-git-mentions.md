# Test cases: non-executable git mentions (issue #547)

## Context

`is_git_command()` claims to match an actual `git <operation>` invocation and
already removes quoted strings before scanning. It does not remove heredoc
bodies or shell comments, so text written to a file or ignored by the shell can
be mistaken for an executable `git commit`.

The same distinction must be preserved by `resolve_git_command_cwd()`. Otherwise
the commit hook still fails closed through resolver return code `2`, even if the
boolean detector is corrected.

Heredoc masking is intentionally bounded to simple external `cat` commands
without shell control operators or physical-line continuations. Other consumers
may interpret stdin as code, and unquoted heredocs can execute substitutions.
Those shapes retain the original command text and fail closed.

## Test matrix

| ID | Scenario | Expected result |
|---|---|---|
| `TC-IGC-547-001` | Quoted-delimiter heredoc body contains `git commit` | `is_git_command commit` returns no match |
| `TC-IGC-547-002` | `<<-EOF` indented heredoc body contains `git add && git commit` | `is_git_command commit` returns no match |
| `TC-IGC-547-003` | Command ends with `# git commit ...` | `is_git_command commit` returns no match |
| `TC-IGC-547-004` | Quoted string contains `git commit` | Existing no-match behavior remains |
| `TC-IGC-547-005` | Resolver receives the quoted-delimiter heredoc case | Returns empty output and status `1` (no commit) |
| `TC-IGC-547-006` | Resolver receives the comment-only case | Returns empty output and status `1` (no commit) |
| `TC-IGC-547-007` | Main-workspace hook receives the heredoc file-generation command | Hook exits `0` |
| `TC-IGC-547-008` | Main-workspace hook receives the indented heredoc file-generation command | Hook exits `0` |
| `TC-IGC-547-009` | Main-workspace hook receives the comment-only command | Hook exits `0` |
| `TC-IGC-547-010` | Genuine `git commit` | Detector still matches |
| `TC-IGC-547-011` | Comment line followed by a genuine `git commit` | Detector still matches the executable line |
| `TC-IGC-547-012` | Genuine `git commit` from a main workspace | Hook still exits `2` |
| `TC-IGC-547-013` | Quoted string contains `#`, followed by a genuine `git commit` | Quoted hash does not begin a comment; detector still matches |
| `TC-IGC-547-014` | Heredoc terminator is followed by a genuine `git commit` | Detector still matches the executable line after the heredoc |
| `TC-IGC-547-015` | Quoted hash is followed by a genuine commit from a main workspace | Hook still exits `2` |
| `TC-IGC-547-016` | Heredoc is followed by a genuine commit from a main workspace | Hook still exits `2` |
| `TC-IGC-547-017` | Double-quoted heredoc delimiter with `git commit` in its body | Detector returns no match |
| `TC-IGC-547-018` | Main-workspace hook receives the double-quoted heredoc case | Hook exits `0` |
| `TC-IGC-547-019` | Here-string is followed by a genuine `git commit` | Here-string is not mistaken for a heredoc; detector matches |
| `TC-IGC-547-020` | Main-workspace hook receives the here-string plus genuine commit | Hook exits `2` |
| `TC-IGC-547-021` | Escaped `#` is followed by a genuine commit | Escaped hash does not begin a comment; detector matches |
| `TC-IGC-547-022` | Mid-word `#` is followed by a genuine commit | Mid-word hash does not begin a comment; detector matches |
| `TC-IGC-547-023` | Quoted text looks like a heredoc opener, followed by a genuine commit | Quoted opener does not start heredoc masking; detector matches |
| `TC-IGC-547-024` | Multiline quoted string contains a line-leading `#`, followed by a genuine commit | Quote state survives newlines; detector matches |
| `TC-IGC-547-025` | One-megabyte heredoc body | No match and completion within two seconds, below the five-second hook timeout |
| `TC-IGC-547-026` | Preprocessor command fails while detector receives a genuine commit | Detector retains the original command and still matches |
| `TC-IGC-547-027` | Preprocessor command fails while resolver receives a genuine commit | Resolver retains the original command and resolves it normally |
| `TC-IGC-547-028` | Heredoc delimiter is followed by an output redirect | Detector returns no match for body prose |
| `TC-IGC-547-029` | Main-workspace hook receives the trailing-redirect heredoc | Hook exits `0` |
| `TC-IGC-547-030` | Backslash-quoted identifier delimiter | Detector returns no match for body prose |
| `TC-IGC-547-031` | One command declares two heredocs containing commit prose | Detector returns no match |
| `TC-IGC-547-032` | Main-workspace hook receives the two-heredoc command | Hook exits `0` |
| `TC-IGC-547-033` | Command substitution is immediately followed by `#suffix`, then a real commit | Detector still matches the executable commit |
| `TC-IGC-547-034` | Main-workspace hook receives that command-substitution case | Hook exits `2` |
| `TC-IGC-547-035` | Multiline arithmetic expression contains `<<IDENT`, followed by a real commit | Arithmetic shift is not treated as heredoc; detector matches |
| `TC-IGC-547-036` | Main-workspace hook receives the arithmetic-shift case | Hook exits `2` |
| `TC-IGC-547-037` | Heredoc declaration line also contains a genuine `git commit` after `;` | Detector still matches executable text on the opener line |
| `TC-IGC-547-038` | `cat` heredoc is piped to a shell interpreter | Detector matches the potentially executable body |
| `TC-IGC-547-039` | Main-workspace hook receives the pipeline-to-shell heredoc | Hook exits `2` |
| `TC-IGC-547-040` | Unquoted heredoc body contains `$(git commit ...)` | Detector matches because command substitution executes |
| `TC-IGC-547-041` | Main-workspace hook receives that unquoted substitution | Hook exits `2` |
| `TC-IGC-547-042` | Unquoted heredoc body contains escaped `\$(git commit ...)` | Detector returns no match because the text is literal |
| `TC-IGC-547-043` | Main-workspace hook receives the escaped substitution prose | Hook exits `0` |
| `TC-IGC-547-044` | Double-quoted argument contains `$(git commit ...)` | Detector matches the executable substitution |
| `TC-IGC-547-045` | Main-workspace hook receives the double-quoted substitution | Hook exits `2` |
| `TC-IGC-547-046` | Double-quoted argument contains a backtick `git commit` substitution | Detector matches the executable substitution |
| `TC-IGC-547-047` | Main-workspace hook receives the backtick substitution | Hook exits `2` |
| `TC-IGC-547-048` | A shell interpreter consumes a quoted heredoc containing `git commit` | Detector keeps the body visible |
| `TC-IGC-547-049` | Main-workspace hook receives the shell-consumer heredoc | Hook exits `2` |
| `TC-IGC-547-050` | Command text defines a `cat` function that sends stdin to Bash | Detector keeps the later heredoc body visible |
| `TC-IGC-547-051` | Main-workspace hook receives the in-command `cat` override | Hook exits `2` |
| `TC-IGC-547-052` | The detector environment already defines `cat` as a function | Heredoc masking is disabled and the commit remains visible |
| `TC-IGC-547-053` | A backslash continuation forms a `cat` function definition across physical lines | Detector keeps the later heredoc body visible |
| `TC-IGC-547-054` | Main-workspace hook receives the continued function-definition case | Hook exits `2` |
| `TC-IGC-547-055` | A double-quoted string runs `$(date)` and separately contains `git commit` prose | Detector returns no match because the git text is not inside the substitution |
| `TC-IGC-547-056` | Main-workspace hook receives that benign quoted substitution | Hook exits `0` |
| `TC-IGC-547-057` | `eval` dynamically defines `cat` before a heredoc containing `git commit` | Detector keeps the heredoc body visible |
| `TC-IGC-547-058` | Main-workspace hook receives the dynamic `cat` replacement | Hook exits `2` |
| `TC-IGC-547-059` | A command substitution runs `bash -c 'git commit ...'` | Detector matches the executable shell code |
| `TC-IGC-547-060` | Main-workspace hook receives the `bash -c` substitution | Hook exits `2` |
| `TC-IGC-547-061` | A command substitution runs `eval 'git commit ...'` | Detector matches the executable evaluated code |
| `TC-IGC-547-062` | Main-workspace hook receives the `eval` substitution | Hook exits `2` |
| `TC-IGC-547-063` | A command substitution runs `echo 'git commit ...'` | Detector returns no match because the text remains data |
| `TC-IGC-547-064` | Main-workspace hook receives the benign `echo` substitution | Hook exits `0` |
| `TC-IGC-547-065` | A substitution contains quoted parentheses before a real commit | Detector matches the later executable commit |
| `TC-IGC-547-066` | Main-workspace hook receives that parenthesized substitution | Hook exits `2` |
| `TC-IGC-547-067` | `bash -c` receives grouped code containing `git commit` | Detector matches the grouped executable commit |
| `TC-IGC-547-068` | Main-workspace hook receives the grouped `bash -c` code | Hook exits `2` |
| `TC-IGC-547-069` | `bash -O extglob -c` receives code containing `git commit` | Detector skips the option argument and matches the code |
| `TC-IGC-547-070` | Main-workspace hook receives the option-bearing shell command | Hook exits `2` |
| `TC-IGC-547-071` | A substitution comment contains `)` before a real commit | Comment text does not truncate the executable substitution body |
| `TC-IGC-547-072` | Main-workspace hook receives that commented substitution | Hook exits `2` |
| `TC-IGC-547-073` | A substitution directly groups `git commit` in a subshell | Detector matches the grouped executable commit |
| `TC-IGC-547-074` | Main-workspace hook receives the grouped substitution | Hook exits `2` |
| `TC-IGC-547-075` | `bash +O extglob -c` receives code containing `git commit` | Detector skips the `+O` argument and matches the code |
| `TC-IGC-547-076` | Main-workspace hook receives the `+O` shell command | Hook exits `2` |
| `TC-IGC-547-077` | `env -u X` wraps `bash -c 'git commit ...'` | Detector skips the env option argument and matches the code |
| `TC-IGC-547-078` | Main-workspace hook receives the env-wrapped shell command | Hook exits `2` |
| `TC-IGC-547-079` | `command -p` wraps `bash -c 'git commit ...'` | Detector skips the command option and matches the code |
| `TC-IGC-547-080` | Main-workspace hook receives the command-wrapped shell command | Hook exits `2` |
| `TC-IGC-547-081` | A completed substitution is followed by `# git commit` prose | Detector removes the top-level EOF comment |
| `TC-IGC-547-082` | Main-workspace hook receives the substitution plus EOF comment | Hook exits `0` |
| `TC-IGC-547-083` | `$SHELL -c` dynamically selects the shell for `git commit` | Detector fails closed on the dynamic executor |
| `TC-IGC-547-084` | Main-workspace hook receives the dynamic shell command | Hook exits `2` |
| `TC-IGC-547-085` | `exec bash -c` runs code containing `git commit` | Detector recognizes the exec wrapper |
| `TC-IGC-547-086` | Main-workspace hook receives the exec-wrapped shell command | Hook exits `2` |
| `TC-IGC-547-087` | An `if` branch runs `bash -c 'git commit ...'` | Detector recognizes the control-flow command boundary |
| `TC-IGC-547-088` | Main-workspace hook receives the conditional shell command | Hook exits `2` |
| `TC-IGC-547-089` | An escaped `\bash` runs code containing `git commit` | Detector resolves the static escaped command name |
| `TC-IGC-547-090` | Main-workspace hook receives the escaped shell command | Hook exits `2` |
| `TC-IGC-547-091` | `! bash -c` runs code containing `git commit` | Detector recognizes the negation prefix |
| `TC-IGC-547-092` | Main-workspace hook receives the negated shell command | Hook exits `2` |
| `TC-IGC-547-093` | An `if` condition runs `bash -c 'git commit ...'` | Detector conservatively matches the executable code |
| `TC-IGC-547-094` | Main-workspace hook receives the condition command | Hook exits `2` |
| `TC-IGC-547-095` | `time` prefixes `bash -c 'git commit ...'` | Detector conservatively matches the executable code |
| `TC-IGC-547-096` | Main-workspace hook receives the timed shell command | Hook exits `2` |
| `TC-IGC-547-097` | A redirection precedes `bash -c 'git commit ...'` | Detector conservatively matches the executable code |
| `TC-IGC-547-098` | Main-workspace hook receives the redirected shell command | Hook exits `2` |
| `TC-IGC-547-099` | Bash reads `git commit` code from a here-string | Detector conservatively matches the stdin code |
| `TC-IGC-547-100` | Main-workspace hook receives the Bash stdin command | Hook exits `2` |
| `TC-IGC-547-101` | `bash -s` reads `git commit` code from a here-string | Detector conservatively matches the stdin code |
| `TC-IGC-547-102` | Main-workspace hook receives the `bash -s` stdin command | Hook exits `2` |
| `TC-IGC-547-103` | A simple `printf` outputs `git commit` prose | Detector treats the quoted text as data |
| `TC-IGC-547-104` | Main-workspace hook receives the benign `printf` substitution | Hook exits `0` |
| `TC-IGC-547-105` | Earlier command text replaces `echo` with an evaluator function | Detector does not apply the builtin data exception |
| `TC-IGC-547-106` | Main-workspace hook receives the shadowed `echo` command | Hook exits `2` |
| `TC-IGC-547-107` | Earlier command text replaces `printf` with an evaluator function | Detector does not apply the builtin data exception |
| `TC-IGC-547-108` | Main-workspace hook receives the shadowed `printf` command | Hook exits `2` |
| `TC-IGC-547-109` | `/tmp/echo` receives `git commit` text | Detector does not trust an explicit path as the `echo` builtin |
| `TC-IGC-547-110` | Main-workspace hook receives the path-qualified echo command | Hook exits `2` |
| `TC-IGC-547-111` | `/tmp/printf` receives `git commit` text | Detector does not trust an explicit path as the `printf` builtin |
| `TC-IGC-547-112` | Main-workspace hook receives the path-qualified printf command | Hook exits `2` |
| `TC-IGC-547-113` | `printf -v` uses an array subscript containing `$(git commit ...)` | Detector excludes assignment mode from the data exception |
| `TC-IGC-547-114` | Main-workspace hook receives the `printf -v` command | Hook exits `2` |
| `TC-IGC-547-115` | `eval` consumes output from `echo 'git commit ...'` | Detector treats the generated code as executable |
| `TC-IGC-547-116` | Main-workspace hook receives the eval consumer | Hook exits `2` |
| `TC-IGC-547-117` | `bash -c` consumes output from `echo 'git commit ...'` | Detector treats the generated code as executable |
| `TC-IGC-547-118` | Main-workspace hook receives the shell code consumer | Hook exits `2` |
| `TC-IGC-547-119` | Bash consumes a process substitution that outputs `git commit` | Detector does not apply the data exception |
| `TC-IGC-547-120` | Main-workspace hook receives the process-substitution consumer | Hook exits `2` |
| `TC-IGC-547-121` | Builtin echo output containing `git commit` is piped to Bash | Detector does not apply the data exception |
| `TC-IGC-547-122` | Main-workspace hook receives the pipeline consumer | Hook exits `2` |
| `TC-IGC-547-123` | Echo redirects generated `git commit` text to a Bash process substitution | Detector rejects the prefix redirection |
| `TC-IGC-547-124` | Main-workspace hook receives the prefix redirect consumer | Hook exits `2` |
| `TC-IGC-547-125` | An array subscript consumes generated text containing `$(git commit ...)` | Detector rejects the parameter-expansion context |
| `TC-IGC-547-126` | Main-workspace hook receives the array subscript consumer | Hook exits `2` |
| `TC-IGC-547-127` | `bash "$f"` runs a dynamic script path without literal git text | Detector returns no match |
| `TC-IGC-547-128` | Main-workspace hook receives that dynamic script path | Hook exits `0` |
| `TC-IGC-547-129` | `sh -c "ls $dir"` contains dynamic shell code without literal git text | Detector returns no match |
| `TC-IGC-547-130` | Main-workspace hook receives that dynamic shell code | Hook exits `0` |
| `TC-IGC-547-131` | `env FOO="$BAR" bash -c ls` contains a dynamic environment value without git text | Detector returns no match |
| `TC-IGC-547-132` | Main-workspace hook receives that dynamic environment value | Hook exits `0` |
| `TC-IGC-547-133` | `exec bash "$f"` uses a dynamic script path without git text | Detector returns no match |
| `TC-IGC-547-134` | Main-workspace hook receives the exec-wrapped dynamic script | Hook exits `0` |
| `TC-IGC-547-135` | `command bash "$f"` uses a dynamic script path without git text | Detector returns no match |
| `TC-IGC-547-136` | Main-workspace hook receives the command-wrapped dynamic script | Hook exits `0` |
| `TC-IGC-547-137` | `eval "$generated"` contains no literal git text | Detector returns no match |
| `TC-IGC-547-138` | Main-workspace hook receives that dynamic eval | Hook exits `0` |
| `TC-IGC-547-139` | An approximately 8 KiB ambiguous command ends with a genuine `git commit` | Main-workspace hook exits `2` within its configured five-second timeout |
| `TC-IGC-547-140` | A masked heredoc terminator is followed by a genuine commit | Resolver returns `2` for a visible but unsupported matching invocation instead of reprocessing and hiding it |
| `TC-IGC-547-141` | An approximately 20 KiB ambiguous command ends with a genuine `git commit` | Main-workspace hook still exits `2` within five seconds, proving the operation-bearing path does not retain quadratic scaling |
| `TC-IGC-547-142` | An approximately 20 KiB ambiguous command ends with `git -p commit` | Main-workspace hook exits `2` within five seconds |
| `TC-IGC-547-143` | An approximately 20 KiB ambiguous command ends with `git 'commit'` | Main-workspace hook exits `2` within five seconds |
| `TC-IGC-547-144` | An approximately 20 KiB ambiguous command ends with `git ${G} commit` | Main-workspace hook exits `2` within five seconds |
| `TC-IGC-547-145` | An approximately 20 KiB ambiguous command contains no literal `git` word | Main-workspace hook exits `0` within five seconds |
| `TC-BP-35` | An approximately 8 KiB ambiguous command ends with `git push origin main` | Trunk-protection hook exits `2` within five seconds; unresolved refspec parsing cannot grant the push |
| `TC-BP-36` | Chained/multiline workflows and a quoted dynamic remote end with a literal feature refspec | Trunk-protection hook exits `0`; the equivalent trunk push and an unquoted dynamic remote exit `2` |
| `TC-BP-37` | Expansion-bearing commands contain no literal `git push`; control uses `$GIT push origin main` | Git-free commands exit `0`; the explicit dynamic Git operation remains fail-closed |
| `TC-BP-38` | An approximately 20 KiB ambiguous command contains no literal `git` word | Trunk-protection hook exits `0` within five seconds |
| `TC-BP-39` | `echo` arguments or heredoc data mention a trunk push before a real feature push | Non-executable push text is ignored; a real trunk push remains blocked |
| `TC-BP-40` | A trunk push appears in a subshell, after a supported or unknown wrapper, after a quoted assignment, or beside a readable feature push | Every trunk destination exits `2`; an unreadable second push cannot inherit the first push's remote scope |
| `TC-BP-41` | A feature-only push is wrapped by `timeout`, shell control flow, `sudo`, `nohup`, `command`, `time`, `stdbuf`, or a quoted environment assignment | Supported prefixed feature pushes exit `0` |
| `TC-BP-42` | A builtin `echo` is the only command and its arguments mention a feature or trunk push | Hook exits `0`; parser rc `1` proves no executable push exists |
| `TC-BP-43` | A trunk refspec is assembled with empty or interior quote fragments | Hook exits `2`; mixed quoting is unknown rather than decoded as a safe feature ref |
| `TC-BP-44` | A feature push is chained to an approximately 21 KiB PR body or carries an approximately 21 KiB single-word push option | Hook exits `0` within five seconds |
| `TC-BP-45` | Builtin `echo`/`printf` push text, including ANSI-quoted or quote-concatenated forms, is piped to a local/remote shell (including absolute paths, quoted remote commands, `source`, `.`, and supported wrappers), sent through `|&`, used in command substitution, or redirected to process substitution | Literal or dynamic executable shell input exits `2`; git-free literal input, dynamic data without a consumer, and regular-file output exit `0` |
| `TC-BP-46` | Feature/trunk pushes use regular redirections, brace groups, or backslash-newline continuations; controls contain a continued non-push command or dynamic global args before definite `status` | Shell syntax is not parsed as a refspec; feature/control commands exit `0` and trunk commands exit `2` |
| `TC-BP-47` | A feature push uses a quoted variable or command substitution as its refspec | Hook exits `2`; the runtime value could target trunk, so dynamic refspecs are intentionally fail-closed |
| `TC-BP-48` | Variable data is piped to `jq`, `tee`, `sort`, `gh`, `cut`, wrapped `jq`, remote `cat`, or `xargs jq` | Hook exits `0`; a pipe is not executable merely because its producer contains `$` |
| `TC-BP-49` | Builtin data commands contain `$((...))` arithmetic expansion and write to a regular file | Hook exits `0`; arithmetic expansion is not command substitution |
| `TC-BP-50` | Dynamic `git -C` is followed by one or more static global options and then `commit` or `log` | Hook exits `0`; the definite non-push operation remains readable after intervening flags |
| `TC-BP-51` | The `push` operation word itself is assembled from mixed quote fragments and targets trunk | Hook exits `2`; resolver uncertainty cannot be discarded as a parser no-match |
| `TC-BP-52` | Benign command substitutions (`$(date)`, `$(cat ...)`, backticks, or a nested `echo` that only generates push text) appear in builtin data commands; controls execute a trunk push from top-level command/process substitution, assignment, `eval`, an arithmetic expression, or an `if` command | Benign substitutions exit `0`; substitution bodies that execute a possible push exit `2` |
| `TC-BP-53` | Trunk-push text is piped to `awk system($0)`, a dynamic `while` body, `tee >(bash)`, or `xargs env`; controls use print/echo/cat-only equivalents | Stdin evaluators exit `2`; data-only consumers exit `0` |
| `TC-BP-54` | Trunk-push text passes through one or more data-only filters before reaching a shell, interpreter, source command, compound command, nested process substitution, or `|&` consumer; controls remain data-only through every stage or place an unrelated shell pipeline after a command-list boundary | Any downstream executable consumer exits `2`; multi-stage data-only and boundary-separated pipelines exit `0` |
| `TC-BP-55` | An approximately 20 KiB git-free ambiguous command contains a benign `$(date)` substitution | Trunk-protection hook exits `0` within five seconds; substitution evidence uses the bounded large-input scanner |
| `TC-BP-56` | Trunk-push text reaches a shell inside `if`, `for`, `select`, single- or multi-arm nested `case`, or an output process substitution, or through an unlisted launcher or `env -S`/`--split-string`; every form has a `cat`-only twin | Executable bodies exit `2`; data-only twins, including `{ cat; }` and `(cat)`, exit `0` |
| `TC-BP-57` | A benign pipeline has 200 `cat` stages; a dynamic-input control has the same stages followed by `bash` | Both finish within five seconds; benign data exits `0` and the executable control exits `2` |

## Evidence contract

On the issue's reported parent revision (`86dd067`), cases `001`, `002`, `003`,
`005`, `006`, `007`, `008`, and `009` must fail while the eight safety controls
`004` and `010` through `016` pass. That RED result demonstrates both the
false-positive detector behavior and its user-visible hook impact without
changing production code. The controls also prevent a future comment/heredoc
stripper from hiding a real commit after quoted text or a heredoc terminator.

The review-regression cases `142` through `145` and `TC-BP-36` through
`TC-BP-57` must fail across the reviewed intermediate fixes: operation-bearing
large commands time out, git-free expansion commands are misclassified,
chained or prefixed feature pushes are blocked, prefixed trunk pushes disappear,
non-executable push text is treated as executable, executable data is treated
as inert, redirection/continuation syntax is treated as a refspec, or mixed
quotes hide the operation or trunk refspec. In particular, `TC-BP-48..51`
reproduce the fourth Opus review's ordinary-pipeline, arithmetic-expansion,
intervening-global-option, and mixed-operation findings before the fix.
`TC-BP-52..53` reproduce the fifth review's benign-substitution false positive,
executable-substitution fail-open, and stdin-evaluator regressions.
`TC-BP-54..55` reproduce the sixth review's downstream-consumer fail-open and
substitution-bearing large-input timeout.
`TC-BP-56..57` reproduce the seventh review's compound/wrapper fail-open and
quadratic downstream pipeline scan.

The eventual fix is complete only when all one hundred forty-five detector
cases and all two hundred fifty-seven trunk-protection assertions pass together with the
existing `test-is-git-command.sh` and
`test-block-commit-outside-worktree.sh` suites.
