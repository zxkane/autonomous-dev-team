#!/usr/bin/env bash
# lib-installer-translate.sh — schema translation helpers for hook installers.
#
# Used by per-agent installers whose hook config schema is a near-clone
# of Claude Code's but uses different event names, tool-name matchers,
# or timeout units. Sourced AFTER lib-installer.sh.
#
# The canonical hook intent lives in claude-settings.template.json. Each
# near-clone installer translates that intent into the agent's flavor at
# install time, with a small declarative mapping table.
#
# Translation primitives:
#
#   translate_event_name <claude-event>
#     Echo the per-agent event name. Override AGENT_EVENT_MAP before
#     calling. Example: AGENT_EVENT_MAP="PreToolUse:preToolUse PostToolUse:postToolUse Stop:stop"
#
#   translate_tool_matcher <claude-matcher>
#     Echo the per-agent tool-name matcher. Override AGENT_TOOL_MAP before
#     calling. Example: AGENT_TOOL_MAP="Bash:execute_bash Write:fs_write Edit:fs_write"
#     Empty value means drop the matcher (event-only). "REGEX:..." prefix
#     emits a regex literal (Gemini-style).
#
#   translate_template <source-template> <jq-projection>
#     Run the source template through jq with all event/tool names
#     remapped per AGENT_EVENT_MAP / AGENT_TOOL_MAP. Echo the resulting
#     JSON to stdout. Caller wraps with their final shape (multi-key vs
#     hooks-only, timeout unit conversion, etc.).
#
# Timeout unit conversion is small enough that callers handle it inline
# via jq: `timeout * 1000` for milliseconds, `tonumber` to keep seconds.

set -euo pipefail

# Get the mapped event name. Returns the original if not in the map
# (so unmapped events pass through unchanged — the caller is responsible
# for verifying the agent supports them).
translate_event_name() {
  local claude_event="$1"
  local pair
  for pair in ${AGENT_EVENT_MAP:-}; do
    if [[ "${pair%%:*}" == "$claude_event" ]]; then
      echo "${pair#*:}"
      return 0
    fi
  done
  echo "$claude_event"
}

# Get the mapped tool matcher. Special return values:
#   "" (empty)        → drop the matcher field (event fires for all tools)
#   "REGEX:pattern"   → wrap as regex literal in the output
#   anything else     → use as the verbatim matcher value
translate_tool_matcher() {
  local claude_matcher="$1"
  local pair
  for pair in ${AGENT_TOOL_MAP:-}; do
    if [[ "${pair%%:*}" == "$claude_matcher" ]]; then
      echo "${pair#*:}"
      return 0
    fi
  done
  echo "$claude_matcher"
}

# Translate the canonical template into the agent's schema.
#
# Strategy: for each top-level event key in the source template's `hooks`
# object, look up the per-agent event name. For each entry's `matcher`
# field, look up the per-agent tool matcher. Drop the matcher if empty.
#
# The output is a JSON object with the SAME top-level shape as the
# source template's `hooks` field — just with translated keys and
# matchers. The caller decides the final wrapping (multi-key
# settings.json vs hooks-only file).
#
# Args:
#   $1 — source template path (claude-settings.template.json)
#
# Output: JSON to stdout. Same hooks block shape, translated names.
#
# Limitations:
#   - Doesn't handle PostToolUseFailure or other Claude-specific events
#     beyond what the template currently uses (PreToolUse, PostToolUse,
#     Stop). Add to the event map if needed.
#   - Doesn't convert timeout units. Callers do that with a follow-up
#     jq pass.
translate_template_hooks() {
  local template="$1"

  # Build jq filter that remaps event names and matcher values via the
  # bash-local maps. We do this by emitting a jq expression that uses
  # bash-substituted constants (safe because we only emit known event
  # names and matcher values).
  #
  # Build event-name remap as a jq object literal:
  local event_remap=""
  local pair
  for pair in ${AGENT_EVENT_MAP:-}; do
    local from="${pair%%:*}"
    local to="${pair#*:}"
    event_remap+="\"$from\": \"$to\", "
  done
  event_remap="{${event_remap%, }}"

  # Tool-matcher remap: same shape, with empty values signaling "drop".
  local tool_remap=""
  for pair in ${AGENT_TOOL_MAP:-}; do
    local from="${pair%%:*}"
    local to="${pair#*:}"
    tool_remap+="\"$from\": \"$to\", "
  done
  tool_remap="{${tool_remap%, }}"

  # Three passes inside one jq:
  #   1. with_entries: rename event keys.
  #   2. map: rename matcher values (or drop if mapped to "").
  #   3. group_by(.matcher) + reduce: merge entries with the same
  #      matcher value (concat their `hooks` arrays). Many-to-one tool
  #      mappings (e.g. Kiro's Write→fs_write + Edit→fs_write) would
  #      otherwise produce duplicate matcher entries that fire the same
  #      check twice (PR-11b code review C2).
  jq --argjson event_map "$event_remap" --argjson tool_map "$tool_remap" '
    .hooks
    | with_entries(
        .key |= ($event_map[.] // .)
        | .value |= map(
            if has("matcher")
            then
              ($tool_map[.matcher] // .matcher) as $new
              | if $new == ""
                then del(.matcher)
                else .matcher = $new
                end
            else .
            end
          )
        | .value |=
            (
              # Group by matcher (or by absence of matcher), then merge
              # each group into a single entry whose .hooks is the
              # concatenation of all source .hooks arrays.
              group_by(.matcher // "__no_matcher__")
              | map(
                  reduce .[] as $entry (
                    {hooks: []};
                    (if $entry | has("matcher") then .matcher = $entry.matcher else . end)
                    | .hooks += $entry.hooks
                  )
                )
            )
      )
  ' "$template"
}

# Convert all `timeout` field values from seconds to milliseconds
# in-place inside a JSON blob. Used by Kiro (whose schema names the
# field `timeout_ms` and expects ms).
#
# Reads from stdin, writes to stdout.
convert_timeouts_to_ms() {
  jq '
    walk(
      if type == "object" and (.timeout | type) == "number"
      then .timeout_ms = (.timeout * 1000) | del(.timeout)
      else .
      end
    )
  '
}

# fold_matcher_into_event — for agents whose event names already encode
# the tool kind (e.g. Windsurf has separate `pre_run_command` vs
# `pre_write_code` events instead of `PreToolUse + matcher`). Folds the
# Claude `event + matcher` pair into a single agent event name.
#
# Map syntax: AGENT_FOLD_MAP is a whitespace-separated list of triplets
# of the form `<claude_event>:<claude_matcher>:<agent_event>`. Empty
# matcher is allowed for events with no matcher (Stop etc.).
#
#   Example for Windsurf:
#     AGENT_FOLD_MAP="
#       PreToolUse:Bash:pre_run_command
#       PreToolUse:Write:pre_write_code
#       PreToolUse:Edit:pre_write_code
#       PostToolUse:Bash:post_run_command
#       Stop::post_cascade_response
#     "
#
# Output shape:
#   {
#     "<agent-event>": [
#       {command, timeout, ...},   # flat hook list — no matcher field
#       ...
#     ],
#     ...
#   }
#
# Multiple Claude `(event, matcher)` pairs that map to the same agent
# event get their hooks lists concatenated (e.g. Edit + Write →
# pre_write_code). Claude pairs not in the fold map are dropped (they
# don't map to anything in the target schema).
#
# Args: $1 — source template path (claude-settings.template.json)
# Output: JSON to stdout.
fold_matcher_into_event() {
  local template="$1"

  # Build a JSON array of fold-map triplets that jq can iterate over.
  local fold_array_items="" triplet
  for triplet in ${AGENT_FOLD_MAP:-}; do
    local claude_evt rest claude_match agent_evt
    claude_evt="${triplet%%:*}"
    rest="${triplet#*:}"
    claude_match="${rest%%:*}"
    agent_evt="${rest#*:}"
    fold_array_items+="{\"claude_event\":\"$claude_evt\",\"claude_matcher\":\"$claude_match\",\"agent_event\":\"$agent_evt\"}, "
  done
  local fold_array="[${fold_array_items%, }]"

  jq --argjson fold_map "$fold_array" '
    .hooks
    | to_entries
    | map(
        .key as $claude_event
        | .value
        | map(
            (.matcher // "") as $matcher
            | .hooks
            | map(
                . + {
                  __target: (
                    [
                      $fold_map[]
                      | select(.claude_event == $claude_event)
                      | select(.claude_matcher == $matcher)
                      | .agent_event
                    ] | first
                  )
                }
              )
          )
        | flatten
      )
    | flatten
    | map(select(.__target != null))
    | group_by(.__target)
    | map({key: .[0].__target, value: map(del(.__target))})
    | from_entries
  ' "$template"
}
