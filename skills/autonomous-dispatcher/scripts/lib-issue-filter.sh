#!/bin/bash
# lib-issue-filter.sh — per-dispatcher issue-selection scope (ISSUE_FILTER,
# issue #436, docs/designs/issue-filter.md).
#
# A boolean expression (`and`/`or`/`not`, parentheses) over `label:<v>` /
# `assignee:<v>` / `assignee:none` atoms, compiled to a jq predicate that is
# evaluated CALLER-side (INV-25 precedent — no jq programs cross the ITP
# seam). Sourced by lib-dispatch.sh via the established idempotent
# readlink -f guard block (same idiom as its lib-pr-linkage/lib-issue-provider/
# lib-code-host sources), so a standalone unit test that sources only
# lib-dispatch.sh resolves `issue_filter_apply` unchanged.
#
# Four public functions (design §4):
#   issue_filter_compile <expr>   — parses <expr>, sets ISSUE_FILTER_JQ /
#                                    ISSUE_FILTER_ARGS on success, rc≠0 + a
#                                    stderr message naming the offending
#                                    token on failure.
#   issue_filter_apply            — reads a normalized JSON array on stdin,
#                                    writes the filtered array (always
#                                    stripping `assignees`). Lazy-compiles on
#                                    first use when ISSUE_FILTER is non-empty.
#   issue_filter_validate         — dry-run compile + eval against `[]`, plus
#                                    the reserved-label and assignee-capability
#                                    gates. Called by dispatcher-tick.sh in its
#                                    upfront conf-validator block.
#   issue_filter_fields <csv>     — appends `,assignees` to <csv> only when
#                                    ISSUE_FILTER is non-empty.
#
# Injection safety: atom values NEVER appear in the jq program text — they
# travel exclusively via `--arg`. A label value like `") or true"` can only
# ever be an exact-match literal (design §4.1).

# Guard against double-source (lib-dispatch.sh sources this idempotently).
if [[ -n "${_LIB_ISSUE_FILTER_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_LIB_ISSUE_FILTER_SOURCED=1

# Reserved atoms (design §4.3): pipeline state labels + the `autonomous`
# baseline. A compiled filter referencing any of these is a conf error —
# slice membership keyed on a state label would mutate as the state machine
# runs (the §7.2 stability corollary), and `autonomous` is already implicit.
_ISSUE_FILTER_RESERVED_LABELS="in-progress reviewing pending-review pending-dev stalled approved autonomous"

# ---------------------------------------------------------------------------
# Tokenizer — character scanner, NOT a whitespace split. `(` / `)` self-
# delimit (so "(label:a" tokenizes as "(" + "label:a" with no space needed);
# a `"` immediately after `key:` opens a quoted value that may contain
# whitespace and closes at the next `"` (embedded `"` unsupported → error);
# everything else is whitespace-delimited.
#
# On success, sets the global array _IFT_TOKENS. rc≠0 on an unterminated
# quote, with a message naming the offending fragment.
# ---------------------------------------------------------------------------
_issue_filter_tokenize() {
  local expr="$1"
  local -a tokens=()
  local i=0 n=${#expr} c buf
  while (( i < n )); do
    c="${expr:i:1}"
    if [[ "$c" == " " || "$c" == $'\t' || "$c" == $'\n' || "$c" == $'\r' ]]; then
      ((i++)); continue
    fi
    if [[ "$c" == "(" || "$c" == ")" ]]; then
      tokens+=("$c")
      ((i++))
      continue
    fi
    # Scan a whitespace/paren-delimited word, honoring an in-place quoted
    # value after a `key:` prefix (e.g. label:"a b").
    buf=""
    while (( i < n )); do
      c="${expr:i:1}"
      if [[ "$c" == " " || "$c" == $'\t' || "$c" == $'\n' || "$c" == $'\r' || "$c" == "(" || "$c" == ")" ]]; then
        break
      fi
      if [[ "$c" == '"' ]]; then
        # Opening quote: consume through the NEXT `"`. Embedded `"` is
        # unsupported (no escape mechanism) — the first closing quote wins.
        local qbuf="" closed=0
        ((i++))
        while (( i < n )); do
          c="${expr:i:1}"
          if [[ "$c" == '"' ]]; then
            closed=1
            ((i++))
            break
          fi
          qbuf+="$c"
          ((i++))
        done
        if (( closed == 0 )); then
          echo "issue_filter_compile: unterminated quoted value starting near '${buf}\"${qbuf}'" >&2
          return 1
        fi
        buf+="\"${qbuf}\""
        continue
      fi
      buf+="$c"
      ((i++))
    done
    tokens+=("$buf")
  done
  _IFT_TOKENS=("${tokens[@]}")
  return 0
}

# _issue_filter_atom_kv <token> — splits a `key:value` token (value may be
# `"quoted"`). Sets _IFT_ATOM_KEY / _IFT_ATOM_VAL / _IFT_ATOM_QUOTED (1/0).
# rc≠0 if the token has no `:` (bare token) or the value is empty.
_issue_filter_atom_kv() {
  local tok="$1"
  if [[ "$tok" != *:* ]]; then
    echo "issue_filter_compile: bare token '${tok}' (expected key:value, '(' , ')' , 'and', 'or', or 'not')" >&2
    return 1
  fi
  _IFT_ATOM_KEY="${tok%%:*}"
  local raw="${tok#*:}"
  if [[ -z "$raw" ]]; then
    echo "issue_filter_compile: empty atom value in '${tok}'" >&2
    return 1
  fi
  if [[ "$raw" == \"*\" && ${#raw} -ge 2 ]]; then
    _IFT_ATOM_QUOTED=1
    _IFT_ATOM_VAL="${raw:1:-1}"
    if [[ -z "$_IFT_ATOM_VAL" ]]; then
      echo "issue_filter_compile: empty atom value in '${tok}'" >&2
      return 1
    fi
  else
    _IFT_ATOM_QUOTED=0
    _IFT_ATOM_VAL="$raw"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Recursive-descent parser (design §4.1 grammar):
#   expr   := term (or term)*
#   term   := factor (and factor)*
#   factor := not factor | ( expr ) | atom
#
# Parser state: _IFT_TOKENS (array), _IFT_POS (cursor). Each _issue_filter_p_*
# function returns 0 on success and sets _IFT_JQ (the jq boolean sub-
# expression text for the parsed node) + appends to the global _IFT_ARGS
# array (one "--arg aN <value>" pair per atom, via a monotonically
# incrementing _IFT_ARGN counter). rc≠0 on any grammar violation, with a
# stderr message naming the offending token/position.
# ---------------------------------------------------------------------------

_issue_filter_peek() {
  if (( _IFT_POS < ${#_IFT_TOKENS[@]} )); then
    printf '%s' "${_IFT_TOKENS[$_IFT_POS]}"
  fi
}

_issue_filter_p_atom() {
  local tok
  tok="$(_issue_filter_peek)"
  if [[ -z "$tok" ]]; then
    echo "issue_filter_compile: unexpected end of expression (expected an atom, '(' , or 'not')" >&2
    return 1
  fi
  if ! _issue_filter_atom_kv "$tok"; then
    return 1
  fi
  local key="$_IFT_ATOM_KEY" val="$_IFT_ATOM_VAL" quoted="$_IFT_ATOM_QUOTED"
  case "$key" in
    label)
      _IFT_ARGN=$((_IFT_ARGN + 1))
      local an="a${_IFT_ARGN}"
      _IFT_ARGS+=(--arg "$an" "$val")
      _IFT_JQ="((.labels // []) | index(\$${an}) != null)"
      ;;
    assignee)
      if [[ "$quoted" == "0" && "$val" == "none" ]]; then
        _IFT_JQ="((.assignees // []) | length == 0)"
      else
        _IFT_ARGN=$((_IFT_ARGN + 1))
        local an="a${_IFT_ARGN}"
        _IFT_ARGS+=(--arg "$an" "$val")
        _IFT_JQ="((.assignees // []) | index(\$${an}) != null)"
      fi
      ;;
    *)
      echo "issue_filter_compile: unknown atom key '${key}' in token '${tok}' (expected 'label' or 'assignee')" >&2
      return 1
      ;;
  esac
  _IFT_POS=$((_IFT_POS + 1))
  return 0
}

_issue_filter_p_factor() {
  local tok
  tok="$(_issue_filter_peek)"
  if [[ "$tok" == "not" ]]; then
    _IFT_POS=$((_IFT_POS + 1))
    if ! _issue_filter_p_factor; then
      return 1
    fi
    _IFT_JQ="(${_IFT_JQ} | not)"
    return 0
  fi
  if [[ "$tok" == "(" ]]; then
    _IFT_POS=$((_IFT_POS + 1))
    # Empty sub-expression: `()` — the next token is the closing paren.
    if [[ "$(_issue_filter_peek)" == ")" ]]; then
      echo "issue_filter_compile: empty parenthesized sub-expression '()'" >&2
      return 1
    fi
    if ! _issue_filter_p_expr; then
      return 1
    fi
    if [[ "$(_issue_filter_peek)" != ")" ]]; then
      echo "issue_filter_compile: unbalanced parentheses — expected ')' at position ${_IFT_POS}" >&2
      return 1
    fi
    _IFT_POS=$((_IFT_POS + 1))
    _IFT_JQ="(${_IFT_JQ})"
    return 0
  fi
  if [[ "$tok" == ")" ]]; then
    echo "issue_filter_compile: unbalanced parentheses — unexpected ')' at position ${_IFT_POS}" >&2
    return 1
  fi
  if [[ "$tok" == "and" || "$tok" == "or" ]]; then
    echo "issue_filter_compile: dangling operator '${tok}' with no preceding operand" >&2
    return 1
  fi
  _issue_filter_p_atom
}

_issue_filter_p_term() {
  if ! _issue_filter_p_factor; then
    return 1
  fi
  local left="$_IFT_JQ" tok
  while [[ "$(_issue_filter_peek)" == "and" ]]; do
    _IFT_POS=$((_IFT_POS + 1))
    tok="$(_issue_filter_peek)"
    if [[ -z "$tok" || "$tok" == "and" || "$tok" == "or" ]]; then
      echo "issue_filter_compile: dangling operator 'and' with no following operand" >&2
      return 1
    fi
    if ! _issue_filter_p_factor; then
      return 1
    fi
    left="(${left} and ${_IFT_JQ})"
  done
  _IFT_JQ="$left"
  return 0
}

_issue_filter_p_expr() {
  if ! _issue_filter_p_term; then
    return 1
  fi
  local left="$_IFT_JQ" tok
  while [[ "$(_issue_filter_peek)" == "or" ]]; do
    _IFT_POS=$((_IFT_POS + 1))
    tok="$(_issue_filter_peek)"
    if [[ -z "$tok" || "$tok" == "and" || "$tok" == "or" ]]; then
      echo "issue_filter_compile: dangling operator 'or' with no following operand" >&2
      return 1
    fi
    if ! _issue_filter_p_term; then
      return 1
    fi
    left="(${left} or ${_IFT_JQ})"
  done
  _IFT_JQ="$left"
  return 0
}

# issue_filter_compile <expr> — public entry point (design §4.1).
#
# Whitespace-only <expr> is treated as unset (identity with the empty-filter
# path): clears ISSUE_FILTER_JQ/ISSUE_FILTER_ARGS and returns 0 without
# parsing. Otherwise tokenizes + parses the full grammar; a non-empty parse
# that leaves unconsumed tokens (trailing tokens after a complete expression)
# is a parse error — the parser must consume the entire token stream.
#
# On success (rc 0): sets two globals —
#   ISSUE_FILTER_JQ   — the compiled jq boolean expression (references only
#                        $aN variables and .labels / .assignees).
#   ISSUE_FILTER_ARGS — array of "--arg" "aN" "<value>" triples, in order.
issue_filter_compile() {
  local expr="${1:-}"
  local trimmed="$expr"
  # Trim leading/trailing whitespace to detect the whitespace-only case.
  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [[ -z "$trimmed" ]]; then
    ISSUE_FILTER_JQ=""
    ISSUE_FILTER_ARGS=()
    return 0
  fi

  if ! _issue_filter_tokenize "$expr"; then
    return 1
  fi
  if [[ ${#_IFT_TOKENS[@]} -eq 0 ]]; then
    ISSUE_FILTER_JQ=""
    ISSUE_FILTER_ARGS=()
    return 0
  fi

  _IFT_POS=0
  _IFT_ARGN=0
  _IFT_ARGS=()
  _IFT_JQ=""

  if ! _issue_filter_p_expr; then
    return 1
  fi
  if (( _IFT_POS < ${#_IFT_TOKENS[@]} )); then
    echo "issue_filter_compile: unexpected trailing token '$(_issue_filter_peek)' after a complete expression" >&2
    return 1
  fi

  ISSUE_FILTER_JQ="$_IFT_JQ"
  ISSUE_FILTER_ARGS=("${_IFT_ARGS[@]}")
  return 0
}

# issue_filter_apply — reads a normalized JSON array on stdin, writes the
# filtered array (design §4.2).
#
# Empty/unset ISSUE_FILTER → strips `assignees` (a no-op `del` when the key
# is absent) with no select — identity is SEMANTIC (jq-equal), not byte-level.
# Non-empty ISSUE_FILTER → lazy-compiles on first use (a standalone caller
# that never ran issue_filter_validate still gets defined, fail-closed
# behavior: a compile failure here returns rc≠0, never `[]`).
issue_filter_apply() {
  if [[ -z "${ISSUE_FILTER:-}" ]]; then
    jq 'map(del(.assignees))'
    return $?
  fi
  if [[ -z "${ISSUE_FILTER_JQ+x}" ]]; then
    if ! issue_filter_compile "$ISSUE_FILTER"; then
      return 1
    fi
  fi
  # Re-check: a whitespace-only ISSUE_FILTER compiles to an empty
  # ISSUE_FILTER_JQ (identity path) even though ISSUE_FILTER itself is
  # non-empty by the `[[ -z ]]` test above.
  if [[ -z "$ISSUE_FILTER_JQ" ]]; then
    jq 'map(del(.assignees))'
    return $?
  fi
  jq "${ISSUE_FILTER_ARGS[@]}" "[.[] | select(${ISSUE_FILTER_JQ})] | map(del(.assignees))"
}

# issue_filter_fields <base-csv> — appends `,assignees` to <base-csv> only
# when ISSUE_FILTER is non-empty (design §4.4). Leaves <base-csv> unchanged
# when empty/unset — the leaf is asked for `assignees` only when a filter
# will actually consume it.
issue_filter_fields() {
  local base_csv="${1:-}"
  if [[ -n "${ISSUE_FILTER:-}" ]]; then
    if [[ -n "$base_csv" ]]; then
      printf '%s,assignees' "$base_csv"
    else
      printf 'assignees'
    fi
  else
    printf '%s' "$base_csv"
  fi
}

# _issue_filter_uses_assignee <jq-expr> — true if the compiled program
# references the assignees field (used by the capability gate). Cheap
# substring check on the compiled jq text — safe because atom VALUES never
# appear in that text (they travel via --arg), so this can never false-match
# on a label value that happens to contain the word "assignees".
_issue_filter_uses_assignee() {
  [[ "$1" == *".assignees"* ]]
}

# _issue_filter_uses_reserved_label <expr> — true if any label: atom in the
# raw (pre-compile) expression names a reserved label. Scans the ORIGINAL
# expression text rather than the compiled jq (which only carries $aN
# placeholders, not literal values) by re-tokenizing and inspecting atoms
# directly — deliberately independent of issue_filter_compile's jq output.
_issue_filter_uses_reserved_label() {
  local expr="$1" tok reserved
  if ! _issue_filter_tokenize "$expr"; then
    return 1
  fi
  local t
  for t in "${_IFT_TOKENS[@]}"; do
    [[ "$t" == label:* ]] || continue
    if ! _issue_filter_atom_kv "$t" 2>/dev/null; then
      continue
    fi
    for reserved in $_ISSUE_FILTER_RESERVED_LABELS; do
      if [[ "$_IFT_ATOM_VAL" == "$reserved" ]]; then
        echo "$reserved"
        return 0
      fi
    done
  done
  return 1
}

# issue_filter_validate — dry-run compile + eval against `[]`, plus the
# reserved-label and assignee-capability gates (design §4.3). Called by
# dispatcher-tick.sh in its upfront conf-validator block. Fail-closed:
# rc≠0 on ANY of — compile failure, reserved-label atom, or an assignee atom
# against a provider whose caps lack `assignees=1`. Empty/unset ISSUE_FILTER
# always passes (nothing to validate).
issue_filter_validate() {
  local filter="${1:-${ISSUE_FILTER:-}}"
  local trimmed="$filter"
  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [[ -z "$trimmed" ]]; then
    return 0
  fi

  if ! issue_filter_compile "$filter"; then
    return 1
  fi

  # Dry-run eval against `[]` — proves the compiled jq program is
  # syntactically valid and evaluable, independent of any real data.
  if ! printf '[]' | jq -e "${ISSUE_FILTER_ARGS[@]}" "[.[] | select(${ISSUE_FILTER_JQ})]" >/dev/null 2>&1; then
    echo "issue_filter_validate: compiled filter failed dry-run evaluation" >&2
    return 1
  fi

  local reserved_hit
  if reserved_hit=$(_issue_filter_uses_reserved_label "$filter"); then
    echo "issue_filter_validate: ISSUE_FILTER references reserved label '${reserved_hit}' (pipeline state labels and 'autonomous' cannot be filter atoms)" >&2
    return 1
  fi

  if _issue_filter_uses_assignee "$ISSUE_FILTER_JQ"; then
    local caps_bit
    caps_bit=$(itp_caps assignees 2>/dev/null || echo 0)
    if [[ "$caps_bit" != "1" ]]; then
      echo "issue_filter_validate: ISSUE_FILTER contains an assignee: atom but the '${ISSUE_PROVIDER:-github}' provider does not declare the 'assignees' capability" >&2
      return 1
    fi
  fi

  return 0
}
