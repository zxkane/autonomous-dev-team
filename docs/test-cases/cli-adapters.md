# Test Cases — Per-CLI Adapter Extraction (#232)

ID format: `TC-ADAPTER-EXTRACT-NNN`. This is a **behavior-preserving** refactor;
the dominant test bar is *parity* — the existing 106-assertion unit suite and the
15-fixture conformance suite green before AND after, plus golden-argv pins that
the per-CLI dispatch argv is byte-identical.

## Parity bars (the merge gate)

| ID | Bar | How verified |
|---|---|---|
| TC-ADAPTER-EXTRACT-001 | Conformance suite green on the commit BEFORE the refactor | `git stash`/baseline run captured: 15/15 PASS |
| TC-ADAPTER-EXTRACT-002 | Conformance suite green AFTER the refactor, SAME fixtures | `bash tests/conformance/run-conformance.sh` → 15/15 PASS |
| TC-ADAPTER-EXTRACT-003 | Full unit suite green AFTER (all existing tests pass unmodified) | every `tests/unit/test-*.sh` exits 0 |
| TC-ADAPTER-EXTRACT-004 | ShellCheck green incl. new `adapters/*.sh` files | `shellcheck -S error` over the updated CI list |

## New unit tests — `tests/unit/test-cli-adapters.sh`

### Adapter dispatch & mode routing

- **TC-ADAPTER-EXTRACT-010** known CLI → adapter: `run_agent` for `claude`
  produces claude argv (`--session-id`, `-p`, `--output-format json`) via the
  adapter (golden argv unchanged from pre-refactor capture).
- **TC-ADAPTER-EXTRACT-011** unknown CLI → generic fallback: `AGENT_CMD=frobnik`
  hits the `*)` branch (`frobnik … -p`, stdin prompt, one-time WARN), NOT an
  adapter.
- **TC-ADAPTER-EXTRACT-012** mode routing: `resume_agent` for `kiro` falls back
  to a fresh session (run_agent path); for `codex` resumes via captured thread-id
  sidecar; for `claude` uses `--resume <uuid>`.
- **TC-ADAPTER-EXTRACT-013** each `adapters/<cli>.sh` defines
  `adapter_invoke_<cli>` after `lib-agent.sh` is sourced
  (`declare -F adapter_invoke_claude` … for all six).

### Golden argv parity (byte-identical for unchanged paths)

- **TC-ADAPTER-EXTRACT-020..025** per CLI (claude/codex/gemini/kiro/opencode/agy):
  `run_agent` argv recorded by a stub binary matches the pre-refactor golden
  (placeholder-aware: `<uuid>`, `<timeout>`, `<logfile>`). Stdin SHA-256 of the
  prompt matches (INV-34 stdin channel preserved).
- **TC-ADAPTER-EXTRACT-026..029** per resumable CLI (claude/codex/gemini/agy):
  `resume_agent` argv matches the pre-refactor golden (`--resume`,
  `exec resume <tid>`, `--conversation <uuid>`).

### Regression pins (per issue Testing Requirements)

- **TC-ADAPTER-EXTRACT-030** agy `--model` validation still wrapper-side: an
  enumerated-but-unknown id is OMITTED (INV-50) — `_agy_build_model_args` lives in
  `adapters/agy.sh` and behaves identically.
- **TC-ADAPTER-EXTRACT-031** codex review fail-closed sentinel: `_run_codex_review`
  returns rc 70 when the PR worktree arg is missing/not-a-dir is degraded with
  WARN per the existing contract (covered by `test-lib-review-codex.sh` unchanged).
- **TC-ADAPTER-EXTRACT-032** kiro trust flags: `--no-interactive` + `--agent`
  argv shape unchanged (kiro permission test unchanged).

### Source-by-path compat (shims)

- **TC-ADAPTER-EXTRACT-040** sourcing `lib-review-codex.sh` (by path) still
  defines `_run_codex_review`, `_classify_codex_drop_reason`,
  `_codex_drop_reason_phrase`, `_codex_review_prepare_worktree`,
  `_codex_review_cleanup_worktree`, `_codex_review_classify_stdout`,
  `_codex_review_compose_body`.
- **TC-ADAPTER-EXTRACT-041** sourcing `lib-review-agy.sh` (by path) still defines
  `_classify_agy_drop_reason`, `_agy_drop_reason_phrase`.
- **TC-ADAPTER-EXTRACT-042** sourcing `lib-review-kiro.sh` (by path) still defines
  `_classify_kiro_drop_reason`, `_kiro_drop_reason_phrase`.
- **TC-ADAPTER-EXTRACT-043** sourcing `adapters/<cli>.sh` directly (after
  lib-agent.sh primitives present) defines the CLI's `adapter_invoke_<cli>` and
  its drop-reason fns (codex/agy/kiro).
- **TC-ADAPTER-EXTRACT-044** (#232 review) sourcing each shim via a DIRECT
  per-lib symlink placed in a dir with NO sibling `adapters/` still defines the
  adapter API — the shim resolves `adapters/<cli>.sh` from its own realpath
  (`readlink -f` of `BASH_SOURCE`, like `lib-agent.sh` per [INV-65]), not the
  symlink's dir. Pins the legacy-install source-by-path contract: a direct
  symlink to `lib-review-codex.sh` alone must not exit 127 on the adapter source.

### INV-75 enforcement (the new invariant, machine-checkable)

- **TC-ADAPTER-EXTRACT-050** `lib-agent.sh` carries no per-CLI flag/argv logic
  inline: the only `claude`/`codex`/`kiro`/`agy`/`gemini`/`opencode` tokens inside
  the `run_agent`/`resume_agent` `case` are the dispatch arm
  (`adapter_invoke_"$AGENT_CMD"`); no `--session-id`/`--trust-all-tools`/
  `exec --json`/`--log-file`/`--conversation`/`exec resume` literals remain in
  `lib-agent.sh`. (Acceptance grep: `grep -n 'case "$AGENT_CMD"'` shows only the
  thin dispatch.)

## E2E gate

- **TC-ADAPTER-EXTRACT-060** Conformance suite as E2E gate; before/after parity
  documented in the PR body with both run outputs (15/15 each).
