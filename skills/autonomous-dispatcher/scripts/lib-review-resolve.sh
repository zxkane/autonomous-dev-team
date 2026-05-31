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
