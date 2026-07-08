#!/bin/bash
# lib-review-resolve.sh — INV-41 per-agent model / extra-args resolution for
# the multi-agent review wrapper (issue #168).
#
# The INV-40 fan-out (AGENT_REVIEW_AGENTS, #166) runs N verdict-reaching review
# agents in parallel, but originally passed the SAME ${AGENT_REVIEW_MODEL} and
# the SAME ${AGENT_REVIEW_EXTRA_ARGS} to every one. That breaks when two listed
# CLIs use different model namespaces (e.g. kiro wants `claude-sonnet-4.6` while
# a claude-family agent wants `sonnet[1m]` — mutually incompatible ids).
#
# This lib lets each agent resolve its OWN model + extra-args via per-agent
# override keys that extend the flat AGENT_REVIEW_* convention with an
# uppercased agent-name suffix:
#
#   AGENT_REVIEW_MODEL_<AGENT>        e.g. AGENT_REVIEW_MODEL_KIRO="claude-sonnet-4.6"
#   AGENT_REVIEW_EXTRA_ARGS_<AGENT>   e.g. AGENT_REVIEW_EXTRA_ARGS_KIRO="--trust-all-tools"
#
# Precedence (locked in #168): per-agent key (if set AND non-empty) → shared
# AGENT_REVIEW_MODEL / AGENT_REVIEW_EXTRA_ARGS → (for the model, the caller
# applies the lib default `sonnet`). An all-unset config resolves to exactly
# the shared values, so the N=1 / all-unset path is byte-for-byte legacy.
#
# The logic is extracted here so it can be unit-tested in isolation (mirrors
# lib-review-aggregate.sh / lib-review-verdict.sh), without spawning the full
# review wrapper.

# _review_agent_key_suffix <name>
#
# Normalize an agent CLI name into the suffix used for its per-agent override
# keys: uppercase, then map every character outside [A-Z0-9] to `_`.
#
#   agy         → AGY
#   kiro        → KIRO
#   claude-code → CLAUDE_CODE
#   gpt.4o      → GPT_4O
#
# Pure string transform — reads no environment. Echoes the suffix on stdout.
_review_agent_key_suffix() {
  local name="$1"
  # Uppercase (bash 4+ ${var^^}), then replace any non-[A-Z0-9] char with `_`.
  local upper="${name^^}"
  # //[!A-Z0-9]/_  — bash extglob-free char-class negation in a pattern
  # substitution: every char NOT in the set becomes `_`.
  printf '%s' "${upper//[!A-Z0-9]/_}"
}

# _resolve_review_agent_model <name>
#
# Resolve the effective review model for one fan-out agent:
#   AGENT_REVIEW_MODEL_<SUFFIX>  (per-agent key, if set and non-empty)
#   → AGENT_REVIEW_MODEL          (shared review value)
#
# Echoes the resolved value (possibly empty if the shared value is also empty —
# the caller applies the `sonnet` lib default exactly as the legacy run_agent
# arg did, keeping this a pure precedence function). An explicit-empty per-agent
# key falls back to the shared value (matches the `:-` semantics operators
# expect: empty == unset).
_resolve_review_agent_model() {
  local name="$1"
  local suffix per_agent_var
  suffix=$(_review_agent_key_suffix "$name")
  per_agent_var="AGENT_REVIEW_MODEL_${suffix}"
  # Indirect expansion with a `:-` fallback to the shared value. The nested
  # `:-` collapses both unset and explicit-empty per-agent keys to the shared
  # AGENT_REVIEW_MODEL.
  printf '%s' "${!per_agent_var:-${AGENT_REVIEW_MODEL:-}}"
}

# _resolve_review_agent_extra_args <name>
#
# Resolve the effective review extra-args for one fan-out agent:
#   AGENT_REVIEW_EXTRA_ARGS_<SUFFIX>  (per-agent key, if set and non-empty)
#   → AGENT_REVIEW_EXTRA_ARGS          (shared review value)
#
# Echoes the resolved flat string (possibly empty — the common default). The
# string is tokenized downstream by lib-agent.sh's _parse_extra_args (same eval
# trust model as AGENT_LAUNCHER), so quoted multi-token values survive intact.
_resolve_review_agent_extra_args() {
  local name="$1"
  local suffix per_agent_var
  suffix=$(_review_agent_key_suffix "$name")
  per_agent_var="AGENT_REVIEW_EXTRA_ARGS_${suffix}"
  printf '%s' "${!per_agent_var:-${AGENT_REVIEW_EXTRA_ARGS:-}}"
}

# _resolve_review_agent_launcher <name>   (INV-42, issue #173)
#
# Resolve the effective per-agent launcher for one fan-out agent:
#   AGENT_REVIEW_LAUNCHER_<SUFFIX>  (per-agent key, if set and non-empty)
#   → "" (empty)
#
# Unlike _resolve_review_agent_model / _resolve_review_agent_extra_args, there
# is DELIBERATELY no fallback to the shared AGENT_REVIEW_LAUNCHER. The shared
# launcher is claude-only (gated by INV-38's startup guard in lib-agent.sh);
# auto-applying it to a non-claude per-agent slot would re-introduce exactly the
# "claude-only `cc` bridge wraps a non-claude CLI" breakage INV-38 prevents (a
# `cc` launcher ending in `claude "$@"` would produce `claude codex ...`). A
# shared model id is merely namespace-specific (agy just warns and ignores
# `--model`), but a shared launcher PREFIX is actively harmful to the wrong CLI.
# So the safe resolution for an un-keyed agent is "no per-agent launcher" —
# empty — and the fan-out subshell then keeps the current INV-38 behavior
# (non-claude → zeroed; claude → keeps the shared launcher via the wrapper's
# rebind). The per-agent key is a targeted opt-in: when an operator sets it they
# are asserting "this launcher is correct for THIS CLI", which the fan-out
# honors by tokenizing the value and bypassing the claude-only guard for that
# agent specifically.
#
# Echoes the resolved launcher string (possibly empty). The string is tokenized
# downstream by the fan-out subshell's `eval` (same trust model as
# AGENT_LAUNCHER), so quoted multi-token values survive intact. An explicit-empty
# per-agent key resolves to empty (empty == unset for this knob).
_resolve_review_agent_launcher() {
  local name="$1"
  local suffix per_agent_var
  suffix=$(_review_agent_key_suffix "$name")
  per_agent_var="AGENT_REVIEW_LAUNCHER_${suffix}"
  printf '%s' "${!per_agent_var:-}"
}

# _resolve_review_agent_model_label <name>   (issue #220)
#
# Render the HONEST display label for one fan-out agent's review model — the
# value shown in the INV-60 verdict trailer, the INV-04 `Reviewed HEAD:` trailer,
# and the INV-58 `Fanning out …` fan-out line. This is the display-layer counterpart
# to `_resolve_review_agent_model` (the LAUNCH-arg resolver).
#
# WHY it differs from _resolve_review_agent_model: agy validates the launch
# `--model` against `agy models` and SILENTLY DROPS an unknown id (INV-50,
# `lib-agent.sh::_agy_build_model_args` → `_agy_known_model`), then runs its
# own `settings.json` default. So for an `agy` member whose wrapper-RESOLVED id
# is NOT an `agy models` id (e.g. the shared `claude-sonnet-4.6` set for kiro,
# with no `AGENT_REVIEW_MODEL_AGY` key), the resolved value is exactly the one
# INV-50 discards — labeling agy with it asserts a model agy never ran. This
# helper mirrors INV-50's outcome for the LABEL: an agy member whose resolved id
# is dropped is rendered as its default, never the dropped id. claude/kiro/codex
# (which HONOR `--model`) are unchanged — their resolved id is what ran.
#
# Resolution:
#   1. resolved = _resolve_review_agent_model "$name", then `:-sonnet` (the same
#      launch default the producers apply).
#   2. If $name (case-insensitive) is `agy` AND _agy_known_model proves the
#      resolved id is NOT a known agy model (INV-50 would drop it) → echo the agy
#      default label. We can name it precisely (`agy default (settings.json)`)
#      only because INV-50 told us the id is dropped; we don't read the actual
#      default name (agy gives no machine-readable "current default").
#   3. Otherwise echo `resolved` verbatim.
#
# Fail-safe (issue #220 AC #4): NEVER assert a wrong id and NEVER abort the
# `set -euo pipefail` wrapper.
#   - _agy_known_model rc 2 (`agy models` enumeration unavailable) → we cannot
#     prove the id invalid, BUT we also can't prove it's the runtime model, and
#     for agy the resolved id is frequently a non-agy id → degrade to the generic
#     `agy default` rather than echo a possibly-wrong id.
#   - _agy_known_model UNDEFINED (this lib sourced WITHOUT lib-agent.sh, e.g. the
#     resolve-lib unit tests) → same conservative degrade to `agy default`. In the
#     live wrapper lib-agent.sh is sourced first, so the validator is present.
#   - The validator call's rc is captured with `|| true`-style guarding so a
#     non-zero rc under `set -e` can't abort the caller.
#
# The `agy default …` labels are short, single-line, and parens-shaped like a
# legitimate agy model id (`Gemini 3.5 Flash (High)`), so they pass the INV-60
# verdict-trailer model-arg validation (control-char/length only) and keep the
# single-line `Review Agent:` trailer intact.
_REVIEW_AGY_DEFAULT_LABEL='agy default (settings.json)'
_REVIEW_AGY_DEFAULT_LABEL_GENERIC='agy default'
_resolve_review_agent_model_label() {
  local name="$1" resolved
  resolved="$(_resolve_review_agent_model "$name")"
  resolved="${resolved:-sonnet}"

  # Only agy needs the INV-50-drop honesty correction; every other CLI honors
  # `--model`, so its resolved id IS what ran → echo verbatim.
  local name_lc="${name,,}"
  if [[ "$name_lc" != "agy" ]]; then
    printf '%s' "$resolved"
    return 0
  fi

  # agy: mirror INV-50. If the validator is absent (lib-agent.sh not sourced),
  # degrade conservatively to the generic default — never the possibly-wrong id.
  if ! declare -f _agy_known_model >/dev/null 2>&1; then
    printf '%s' "$_REVIEW_AGY_DEFAULT_LABEL_GENERIC"
    return 0
  fi

  # _agy_known_model enumerates via ${AGENT_CMD:-agy}. The label producers run in
  # the MAIN wrapper context where AGENT_CMD is the shared default (possibly a
  # non-agy CLI), so force the agy binary locally for the enumeration — this is a
  # query of *agy's* model list, independent of the fleet's shared AGENT_CMD. The
  # `local` shadow never leaks past this function.
  local AGENT_CMD="agy"
  local rc=0
  # Strip control chars ONCE, before validation, so the value that validates is
  # byte-identical to the value the rc=0 branch prints below — _agy_known_model
  # only sanitizes its own internal copy for the grep check and never returns it,
  # so without this the caller's copy could still carry e.g. a trailing \r or an
  # embedded \n through to the rc=0 printf. Mirrors _agy_build_model_args's
  # up-front strip in adapters/agy.sh.
  resolved="${resolved//[[:cntrl:]]/}"
  _agy_known_model "$resolved" || rc=$?
  case "$rc" in
    0)  printf '%s' "$resolved" ;;                              # known agy id → ran as-is
    2)  printf '%s' "$_REVIEW_AGY_DEFAULT_LABEL_GENERIC" ;;     # can't validate → generic default
    *)  printf '%s' "$_REVIEW_AGY_DEFAULT_LABEL" ;;             # INV-50 dropped it → settings.json default
  esac
  return 0
}

# _review_fanout_model_label <agent...>   (INV-58, issue #205)
#
# Render a human-facing summary of the model EACH fan-out agent will actually
# review with — the per-agent honest label (`_resolve_review_agent_model_label`,
# issue #220 — which mirrors INV-50's agy drop), NOT the shared
# `AGENT_REVIEW_MODEL` default. For the `Fanning out …` log line.
#
# Before #205 the fan-out line printed `(shared model: ${AGENT_REVIEW_MODEL})` —
# which, for a fleet with per-agent overrides (e.g. `AGENT_REVIEW_MODEL_AGY=
# "Gemini 3.5 Flash (High)"`), actively MISLED the operator into suspecting a
# model-pin bug when the per-agent model was in fact resolved correctly. This
# label reflects the real per-agent resolution.
#
# Output shape:
#   - all agents resolve to the SAME id → `model: <id>` (the common case;
#     equivalent to the old shared-model line but rendering the RESOLVED value).
#   - any divergence → `models: <agent>=<id>, <agent>=<id>, …` so each member's
#     effective model is visible at a glance.
# A resolved-empty model is rendered as the lib's `sonnet` default (the same
# `${...:-sonnet}` the run_agent call applies), so the label matches the value
# the agent is actually launched with. Each member's id is rendered through
# `_resolve_review_agent_model_label` (issue #220), so an agy member whose
# resolved id is dropped by INV-50 shows its default — not the dropped id.
_review_fanout_model_label() {
  local agent resolved
  local -a pairs=()
  local first="" uniform=1
  for agent in "$@"; do
    resolved="$(_resolve_review_agent_model_label "$agent")"
    pairs+=("${agent}=${resolved}")
    if [[ -z "$first" ]]; then
      first="$resolved"
    elif [[ "$resolved" != "$first" ]]; then
      uniform=0
    fi
  done
  if [[ "${#pairs[@]}" -eq 0 ]]; then
    printf 'model: %s' "${AGENT_REVIEW_MODEL:-sonnet}"
  elif [[ "$uniform" -eq 1 ]]; then
    printf 'model: %s' "$first"
  else
    local joined
    joined=$(printf '%s, ' "${pairs[@]}")
    printf 'models: %s' "${joined%, }"
  fi
}
