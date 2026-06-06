# Design: per-agent launcher for the multi-agent review fan-out (#173, INV-42)

## Problem

The INV-40 multi-agent review fan-out (`AGENT_REVIEW_AGENTS`, #166/#167) runs N
verdict-reaching agents in parallel, and INV-41 (#168/#169) lets each resolve its
OWN model + extra-args. The remaining gap that blocks adding a third reviewer in
practice is the **launcher**: every CLI in the fan-out shares whatever
`AGENT_LAUNCHER_ARGV` the review wrapper hands it, and the fan-out subshell
actively **zeroes** that array for any non-`claude` member (INV-38 reasoning: a
claude-only `cc` bridge must not wrap a non-claude CLI).

Concrete trigger: a downstream project wants to add `codex` as a third reviewer
alongside `kiro agy`. On the host, `codex` (like `cc` for claude) is a bash
function in `~/.bash_aliases` that auto-starts a per-machine bedrock proxy and
exports `OPENAI_BASE_URL` + a dummy `OPENAI_API_KEY` before exec'ing the real
CLI. Without that bridge, a headless `codex exec` from the dispatcher's nohup
shell fails (no `OPENAI_API_KEY`, no proxy). The pattern is exactly the one
solved for `cc` by `AGENT_DEV_LAUNCHER` — but on the **review** side, today we
can't express it per-agent.

Two hard limits block expressing a per-agent launcher:

1. **`lib-agent.sh` startup guard** (INV-38): `AGENT_REVIEW_LAUNCHER` non-empty
   requires `AGENT_REVIEW_CMD=claude`. Most multi-agent setups have a non-claude
   `AGENT_REVIEW_CMD` (the N=1 fallback), so the gate fires before the fan-out
   even starts.
2. **Fan-out subshell** (`autonomous-review.sh`): force-clears
   `AGENT_LAUNCHER_ARGV=()` for any non-claude member. No escape valve for an
   operator-supplied per-agent launcher meant precisely for that CLI.
3. No per-agent launcher knob exists — INV-41 added per-agent model + extra-args
   but no symmetric `AGENT_REVIEW_LAUNCHER_<AGENT>`.

## Locked design decisions (from the issue)

1. **Naming** — extends the INV-41 flat `AGENT_REVIEW_*` convention with an
   uppercased agent-name suffix (every char outside `[A-Z0-9]` → `_`), reusing
   the existing `_review_agent_key_suffix`:
   - `AGENT_REVIEW_LAUNCHER_<AGENT>` (e.g.
     `AGENT_REVIEW_LAUNCHER_CODEX=$'bash -c \'source ~/.bash_aliases && codex "$@"\' --'`)
2. **Precedence** (mirrors `_resolve_review_agent_model`):
   - `AGENT_REVIEW_LAUNCHER_<AGENT>` (per-agent, set AND non-empty) → applies as
     the agent's launcher argv.
   - else → fall through to the current INV-38 behavior: non-claude → zeroed;
     claude → keeps the shared `AGENT_REVIEW_LAUNCHER` already rebound onto
     `AGENT_LAUNCHER_ARGV`.
3. **INV-38 bypass is per-agent only.** When a per-agent launcher IS set the
   operator is asserting "this launcher is correct for this CLI", so the INV-38
   claude-only guard is bypassed **for that agent specifically** — the bypass
   lives entirely inside the fan-out subshell and never touches the startup
   guard. The shared `AGENT_REVIEW_LAUNCHER` keeps its claude-only restriction
   (it is a blanket default; the per-agent key is a targeted opt-in).
4. **Scope** — per-subshell only, exactly like INV-41 model/extra-args. Never
   leaks across fan-out members or sides.

## Why the shared `AGENT_REVIEW_LAUNCHER` resolver does NOT auto-apply

`_resolve_review_agent_launcher` returns **empty** when only the shared
`AGENT_REVIEW_LAUNCHER` is set (no per-agent key). This is intentional and is
the one place the launcher resolver diverges from the model resolver
(`_resolve_review_agent_model` *does* fall back to the shared value):

- The shared `AGENT_REVIEW_LAUNCHER` is claude-only by INV-38's startup guard.
  If the launcher resolver fell back to it, a non-claude per-agent slot would
  inherit the claude-only `cc` bridge and produce `claude codex ...` — the exact
  breakage INV-38 prevents.
- A shared model id is namespace-specific but not *dangerous* to pass to the
  wrong CLI (a wrong model id just makes that CLI fail to launch — or, for agy
  post-[INV-50] (#190), get validated against `agy models` and omitted with a
  WARN, degrading to agy's default rather than a wrong invocation). A shared
  launcher prefix IS dangerous to the wrong CLI. So the safe default for an
  un-keyed agent is "no launcher" (the INV-38 zeroing for non-claude; the
  shared launcher for claude via the rebind), never the shared launcher
  auto-applied to a non-claude slot.

So the resolver's job is narrow: return the per-agent value if present, else
empty. The fan-out subshell then decides: per-agent value present → apply it
(bypassing INV-38 for this agent); absent → current INV-38 branch.

## Implementation

### 1. `lib-review-resolve.sh` — `_resolve_review_agent_launcher <name>`

```sh
_resolve_review_agent_launcher() {
  local name="$1"
  local suffix per_agent_var
  suffix=$(_review_agent_key_suffix "$name")
  per_agent_var="AGENT_REVIEW_LAUNCHER_${suffix}"
  # Per-agent key only — NO shared-value fallback (the shared
  # AGENT_REVIEW_LAUNCHER is claude-only by INV-38 and must not auto-apply
  # to a non-claude per-agent slot; see design doc). Unset/empty → empty.
  printf '%s' "${!per_agent_var:-}"
}
```

Same suffix transform as the model/extra-args resolvers. Pure: reads only the
indirected per-agent var, echoes the resolved string (possibly empty).

### 2. `autonomous-review.sh` fan-out subshell

Replace the current `if [[ "$_agent" != "claude" ]]; then AGENT_LAUNCHER_ARGV=();
fi` with:

```sh
_per_agent_launcher=$(_resolve_review_agent_launcher "$_agent")
if [[ -n "$_per_agent_launcher" ]]; then
  # Operator asserted this launcher fits THIS CLI → bypass INV-38 for it.
  if ! eval "AGENT_LAUNCHER_ARGV=($_per_agent_launcher)" 2>/dev/null; then
    log "ERROR: AGENT_REVIEW_LAUNCHER_<$_agent> failed to tokenize; running naked. Value: $_per_agent_launcher"
    AGENT_LAUNCHER_ARGV=()
  fi
elif [[ "$_agent" != "claude" ]]; then
  # INV-38: claude-only shared launcher must not wrap a non-claude CLI.
  AGENT_LAUNCHER_ARGV=()
fi
```

`eval` is the same trust model used everywhere else for launcher tokenization
(`AGENT_LAUNCHER`, `AGENT_DEV_LAUNCHER`, `_parse_extra_args`) — `autonomous.conf`
is trusted at the same level as the wrapper. Tokenization failure logs a clear
line and degrades to naked (empty argv) rather than crashing the subshell.

Scope is the subshell only: `AGENT_LAUNCHER_ARGV` is already a per-subshell
binding here (the fan-out runs each agent in `( ... ) &`).

### 3. `lib-agent.sh` startup guard — UNCHANGED

The INV-38 guard at `lib-agent.sh` is specifically about the **shared**
`AGENT_REVIEW_LAUNCHER` default (the blanket knob). Its semantics are correct
and unchanged: the shared default stays claude-only. The per-agent key is a
targeted opt-in resolved entirely inside the fan-out subshell, AFTER the startup
guard has run, so it never trips the guard. No guard-text edit is required: the
guard already names `AGENT_REVIEW_LAUNCHER` (the shared var), which is accurate —
we only extend its leading comment to point at INV-42 for the per-agent opt-in.

## Resolution matrix

| per-agent `_<AGENT>` | shared `AGENT_REVIEW_LAUNCHER` | agent is claude? | resulting `AGENT_LAUNCHER_ARGV` |
|---|---|---|---|
| set, non-empty | (any) | (any) | tokenized per-agent launcher (INV-38 bypassed for this agent) |
| set, non-empty, malformed | (any) | (any) | `()` + ERROR log line |
| unset / empty | set (claude-only) | yes (claude) | shared launcher (kept via the wrapper's rebind) |
| unset / empty | set (claude-only) | no (non-claude) | `()` (INV-38 zeroing) |
| unset / empty | unset | yes (claude) | `()` (nothing to keep) |
| unset / empty | unset | no (non-claude) | `()` (INV-38 zeroing) |

## Backward compatibility

- **N=1 path** (`AGENT_REVIEW_AGENTS` unset): `REVIEW_AGENTS_LIST=("$AGENT_CMD")`;
  no per-agent launcher key set → `_resolve_review_agent_launcher` returns empty
  → the fan-out takes the `elif` / claude branch exactly as today. Byte-for-byte
  unchanged.
- **`AGENT_REVIEW_AGENTS="kiro agy"` with no per-agent launchers**: every member
  resolves empty → kiro/agy hit the non-claude `elif` (zeroed, today's INV-38
  behavior); a claude member keeps the shared launcher. Byte-for-byte unchanged.

## Doc/spec updates (same PR)

- `docs/pipeline/invariants.md` — new **INV-42**: per-agent launcher resolution;
  suffix convention; precedence (per-agent → empty, NOT shared); INV-38 bypass
  for the per-agent path only; the deliberate no-shared-fallback rationale.
- `docs/pipeline/review-agent-flow.md` — fan-out subshell bullet mentions the
  per-agent launcher resolution alongside model + extra-args.
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` — commented
  `AGENT_REVIEW_LAUNCHER_<AGENT>` block with a working `AGENT_REVIEW_LAUNCHER_CODEX`
  example reusing the `bash -c 'source ~/.bash_aliases && codex "$@"' --` shape.

## Tests (TDD)

- Resolver unit (extend `test-autonomous-review-per-agent-model.sh` or a new
  sibling): per-agent set → value; only-shared-set → empty; suffix transform on
  non-alphanumeric names; explicit-empty per-agent → empty.
- Fan-out branch harness: extract the three branches and assert applied /
  keep-claude / cleared-non-claude.
- Regression (fails before, passes after): with
  `AGENT_REVIEW_AGENTS="kiro codex"` + `AGENT_REVIEW_LAUNCHER_CODEX="echo CODEX_LAUNCHED --"`,
  the captured argv for the codex member starts with `echo CODEX_LAUNCHED`.
