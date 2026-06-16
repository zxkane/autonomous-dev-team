# Design — Per-CLI Adapters with Mode Axis (#232)

```
status: implementation design (behavior-preserving refactor)
issue: #232
spec:   docs/pipeline/adapter-spec.md (#229, NORMATIVE target contract)
parity: tests/conformance/run-conformance.sh (#230, INV-74) green before AND after
```

## Goal

Extract every per-CLI special case out of the orchestration core into one
adapter file per CLI: `skills/autonomous-dispatcher/scripts/adapters/<cli>.sh`.
`run_agent` / `resume_agent` become **thin dispatchers**; the
`lib-review-{codex,agy,kiro}.sh` per-CLI review/drop-reason logic relocates into
the matching adapter. **Behavior-preserving** — conformance + full unit suite
green before and after; argv goldens byte-identical for unchanged paths.

This is the highest-risk change in the funded scope. The governing rule (issue
"Design Considerations"): **move code, do not improve it.** Improvements are
follow-ups.

## What stays exactly the same (the parity contract)

The conformance runner (#230) and `lib-agent-smoke.sh` reach the dispatch path
by **sourcing files by path** and **calling functions by name**. None of these
may change:

| Surface | Caller | Must keep |
|---|---|---|
| `run_agent <sid> <prompt> [model] [name]` | conformance, wrappers, smoke | exact signature, rc semantics, stdin (INV-34), argv |
| `resume_agent <sid> <prompt> [model] [name]` | conformance, wrappers, smoke | exact signature, rc, argv (per-CLI resume / fresh fallback) |
| `_run_codex_review <prompt> <model> <out> <pr_workdir>` | conformance, autonomous-review.sh | rc 70 fail-closed, positional `[PROMPT]`, re-run loop |
| `_classify_{codex,agy,kiro}_drop_reason` | `_smoke_classify`, autonomous-review.sh, conformance | same tokens |
| `_{codex,agy,kiro}_drop_reason_phrase` | `_smoke_classify`, autonomous-review.sh | same prose |
| `_smoke_classify` | conformance, smoke harness | unchanged (stays in lib-agent-smoke.sh) |
| `source lib-review-codex.sh` (by path) | conformance runner, lib-agent-smoke.sh | path keeps providing codex review + drop-reason fns |
| `source lib-review-{agy,kiro}.sh` (by path) | lib-agent-smoke.sh | path keeps providing drop-reason fns |
| CI shellcheck file list | `.github/workflows/ci.yml` | lib-review-*.sh paths still lint-clean (now + new adapters added) |

## The architecture

### Adapter files: `adapters/<cli>.sh`

One file per supported CLI: `claude.sh`, `codex.sh`, `kiro.sh`, `agy.sh`,
`gemini.sh`, `opencode.sh`. Each is **sourced** (not exec'd) and defines, as
appropriate for that CLI:

- `adapter_invoke_<cli> <mode> <session_id> <prompt> <model> <session_name>` —
  the **mode-axis entry**. `mode ∈ {dev-new, dev-resume}` today (review for codex
  via `_run_codex_review`; e2e-browser is CLI-agnostic and not an adapter mode).
  It assembles the *exact* argv the current `case` branch built, feeds the prompt
  on stdin (INV-34) — except codex review's positional carve-out (Clause A2) — and
  returns the CLI's rc with the same `PIPESTATUS[1]` discipline.
- the CLI's **session-handle capture/recall** helpers (codex thread-id sidecar,
  opencode `ses_` sidecar, agy `--log-file` UUID grep, agy model validation
  INV-50).
- the CLI's **drop-reason scraper + phrase** (`_classify_<cli>_drop_reason`,
  `_<cli>_drop_reason_phrase`) for codex/agy/kiro (the providers with a
  documented "lying mode", spec §7).
- (codex only) the full **review lane** (`_run_codex_review` + helpers, INV-62).

Adapters are **pure code-relocation**: the function bodies move verbatim from
`lib-agent.sh` / `lib-review-*.sh`, with no logic change.

### `lib-agent.sh` becomes a thin dispatcher

`run_agent` / `resume_agent` keep their signatures, preflight, and
`_parse_extra_args` calls, then `case "$AGENT_CMD"` reduces to:

```sh
case "$AGENT_CMD" in
  claude|codex|gemini|kiro|opencode|agy)
    adapter_invoke_"$AGENT_CMD" dev-new "$session_id" "$prompt" "$model" "$session_name" ;;
  *)  # generic fallback (unknown CLI) — preserved verbatim
      <generic stdin -p branch> ;;
esac
```

The generic-fallback branch (the `*)` case, including the one-time WARN) stays
inline in `lib-agent.sh` — it is the CLI-agnostic default, not a per-CLI case.
`lib-agent.sh` sources every `adapters/*.sh` at load time (after `lib-config.sh`,
before the function defs use them — sourcing only *defines* functions, the
dispatch happens at call time, so order is flexible). Shared primitives
(`_run_with_timeout`, `_parse_extra_args`, `preflight_agent_binary`,
`pid_dir_for_project`, the launcher/timeout globals) **stay in `lib-agent.sh`** —
adapters call them as already-sourced functions.

### `lib-review-{codex,agy,kiro}.sh` become thin compat shims

Each shrinks to a header + `source adapters/<cli>.sh` (BASH_SOURCE-relative,
INV-14). This is chosen over deletion because:

- The conformance runner does `source .../lib-review-codex.sh` **by path**; the
  CI shellcheck list names these paths; `lib-agent-smoke.sh` sources all three by
  path. Keeping the path = the source-by-path contract is preserved with zero
  edits to those callers ⇒ **strictly less churn and risk** than deletion for a
  behavior-preserving refactor. (Issue explicitly permits "thin compat shims OR
  deletion".)

A shim is:

```sh
#!/usr/bin/env bash
# lib-review-codex.sh — COMPAT SHIM. The codex review lane + drop-reason logic
# moved into adapters/codex.sh (#232). This shim preserves the source-by-path
# contract (conformance runner, lib-agent-smoke.sh, CI shellcheck list).
_LIB_REVIEW_CODEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=adapters/codex.sh
source "${_LIB_REVIEW_CODEX_DIR}/adapters/codex.sh"
```

### Adapter sourcing & lib resolution (INV-14 / INV-65)

Adapters live in `adapters/` *under* `scripts/`. They are sourced by
`lib-agent.sh` (and by the shims). An adapter that needs a sibling primitive
relies on it already being defined by the time `run_agent` is *called* (lib-agent
sources adapters; the dispatch is at call time). Adapters do NOT re-source
`lib-agent.sh` (would recurse) — they assume `_run_with_timeout` etc. exist,
exactly as the case branches did when they were inline. The codex adapter, when
sourced standalone via the `lib-review-codex.sh` shim path (conformance codex
lane sources the shim, which sources the adapter), needs `_run_with_timeout`;
the conformance runner sources `lib-agent-smoke.sh` first (→ lib-agent.sh →
adapters), so `_run_with_timeout` is present. Documented as a precondition in the
codex adapter header.

## New invariant

**INV-75 — all per-CLI behavior lives in that CLI's adapter.** Per-CLI argv
assembly, session-handle persistence, model validation, the review lane, and the
drop-reason scrapers live in `adapters/<cli>.sh`. An inline `case "$AGENT_CMD"`
(or `$cli`) conditional carrying per-CLI *flag/argv/classification logic* in
orchestration code (`lib-agent.sh`, `autonomous-review.sh`, `lib-agent-smoke.sh`)
is a **defect**. The only permitted CLI conditional in orchestration code is the
thin dispatch (`adapter_invoke_"$AGENT_CMD"` selection) and the generic-fallback
`*)` branch.

## Out of scope (per issue)

- The verdict-artifact data channel (the four-axis result becomes a *typed file*
  later) — this PR keeps the existing rc + scraper-classification mechanism.
- Any TypeScript. Changing which CLIs are supported.
- Improving any per-CLI logic — strictly mechanical relocation.

## Risk & mitigation

| Risk | Mitigation |
|---|---|
| argv drifts during move | conformance asserts argv byte-identical (placeholder-aware) — green before/after |
| a sourced-by-path function vanishes | shims preserve every path; golden-argv unit tests pin run_agent/resume_agent argv per CLI |
| sourcing order / recursion | adapters never source lib-agent.sh; lib-agent sources adapters once; double-source guarded |
| classification token change | conformance + per-lib drop-reason unit tests unchanged and green |
