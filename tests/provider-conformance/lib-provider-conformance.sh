#!/bin/bash
# lib-provider-conformance.sh — pure helpers for run-provider-conformance.sh
# (issue #370, #347 W2). No side effects at source time; every function is
# independently unit-testable (tests/unit/test-provider-conformance-runner.sh).

# pcf_conf_value <file> <key> — read one `key=value` line from a flat conf
# file (coverage.conf / cap-map.conf shape). Strips full-line/inline `#`
# comments and blank lines; matches the FIRST `key=value` whose key equals
# <key>. Mirrors lib-issue-provider.sh::_provider_read_cap's parser exactly
# (same file shape, same trim rules) so the two data formats stay consistent.
# rc 0 + prints the value on a match; rc 1 + no output otherwise.
pcf_conf_value() {
  local file="$1" key="$2" line k v
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" != *=* ]] && continue
    k="${line%%=*}"
    v="${line#*=}"
    k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    if [[ "$k" == "$key" ]]; then printf '%s\n' "$v"; return 0; fi
  done < "$file"
  return 1
}

# pcf_conf_keys <file> — print every key in a flat conf file, one per line,
# in file order. Used by the coverage-table set-diff (R3 tripwire) and by the
# runner's main verb-iteration loop.
pcf_conf_keys() {
  local file="$1" line k
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" != *=* ]] && continue
    k="${line%%=*}"
    k="${k%"${k##*[![:space:]]}"}"
    printf '%s\n' "$k"
  done < "$file"
}

# pcf_resolve_provider_dir <project_root> <name> — resolve a provider NAME to
# its source directory. Fixed table (issue #370 design): github -> the real
# skill tree; degraded -> the existing #280 fixture; broken -> this suite's
# deliberately-broken fixture. Both seams (ITP/CHP) share this same table — a
# name resolves to the same DIR regardless of seam; the caller picks the
# itp-<name> or chp-<name> file inside it. Unknown name -> rc 1, no output
# (the caller treats this as a fatal usage error, not a silent empty provider).
pcf_resolve_provider_dir() {
  local root="$1" name="$2"
  case "$name" in
    github)   printf '%s\n' "$root/skills/autonomous-dispatcher/scripts/providers" ;;
    degraded) printf '%s\n' "$root/tests/unit/fixtures/provider-degraded" ;;
    broken)   printf '%s\n' "$root/tests/provider-conformance/fixtures/provider-broken" ;;
    *)        return 1 ;;
  esac
}

# pcf_materialize_scratch <scratch_dir> <itp_name> <itp_src_dir> <chp_name> <chp_src_dir>
#
# Populates <scratch_dir> with symlinks itp-<itp_name>.{sh,caps} (from
# <itp_src_dir>) and chp-<chp_name>.{sh,caps} (from <chp_src_dir>) so a
# SINGLE AUTONOMOUS_PROVIDERS_DIR (the one env var both lib-issue-provider.sh
# and lib-code-host.sh read at source time) resolves BOTH seams independently
# — the load-bearing trick that makes `--itp X --chp Y` a genuinely
# two-axis selection despite the shared env var (the filename prefixes
# `itp-`/`chp-` never collide). Symlink targets are readlink-f'd first so a
# relative --itp/--chp source dir or a symlinked skill-tree entry resolves
# correctly regardless of the runner's cwd. Missing source files are simply
# not symlinked (e.g. the broken fixture may legitimately omit a `.caps` —
# though today it does not); the two libs already degrade gracefully on a
# missing provider file (source guarded with `[[ -f ... ]]`).
pcf_materialize_scratch() {
  local scratch="$1" itp_name="$2" itp_src="$3" chp_name="$4" chp_src="$5"
  local f
  for f in "sh" "caps"; do
    [[ -f "$itp_src/itp-${itp_name}.${f}" ]] && \
      ln -sf "$(readlink -f "$itp_src/itp-${itp_name}.${f}")" "$scratch/itp-${itp_name}.${f}"
    [[ -f "$chp_src/chp-${chp_name}.${f}" ]] && \
      ln -sf "$(readlink -f "$chp_src/chp-${chp_name}.${f}")" "$scratch/chp-${chp_name}.${f}"
  done
}

# pcf_isolated_path <stub_dir> — compute the R1-mandated isolated PATH: the
# stub dir plus the directories hosting bash, coreutils (env), jq, and
# grep/sed — nothing else, so the real `gh` is NEVER resolvable. Discovers
# each tool's dir via the CALLER's ambient `command -v` (run once, before the
# subshell's PATH is narrowed) and de-duplicates so the isolated PATH is
# short and stable. A tool that is not found (should not happen in any CI or
# dev environment this suite targets) is silently omitted, never fatal — an
# absent leaf-required tool surfaces as a stub-missing/command-not-found
# FAIL on the specific verb that needed it, which is the correct diagnostic.
pcf_isolated_path() {
  local stub_dir="$1"
  local dirs=("$stub_dir") d seen existing
  local tool
  for tool in bash env jq grep sed; do
    d="$(command -v "$tool" 2>/dev/null)" || continue
    d="$(dirname "$d")"
    seen=0
    for existing in "${dirs[@]}"; do [[ "$existing" == "$d" ]] && { seen=1; break; }; done
    [[ "$seen" -eq 0 ]] && dirs+=("$d")
  done
  local IFS=':'
  printf '%s\n' "${dirs[*]}"
}

# pcf_is_json_array <text> — rc 0 iff TEXT parses as JSON and its top-level
# value is an array. Empty/whitespace-only TEXT is treated as "not an array"
# (rc 1) — a leaf that failed soft (empty stdout) is a separate assertion
# from shape, so callers check for emptiness first.
pcf_is_json_array() {
  local text="$1"
  [[ -n "${text//[[:space:]]/}" ]] || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$text"
}

# pcf_spec_pending_verbs <spec_md> — print, one per line sorted+deduped, the
# verb name of every provider-spec.md §3.1/§3.2 table row carrying the literal
# `CONTRACT-PENDING` token. Plain grep/sed anchored on the `| \`<verb>` row
# prefix — no markdown parsing — so prose elsewhere in the doc that merely
# MENTIONS the token (e.g. §10's checklist intro/footer) is excluded. Shared
# by the runner's own tripwire and the test suite's simulated-drift cases so
# the extraction pipeline is defined exactly once.
pcf_spec_pending_verbs() {
  local spec_md="$1"
  grep -E '^\| `[a-zA-Z_]+' "$spec_md" 2>/dev/null | grep "CONTRACT-PENDING" \
    | sed -E 's/^\| `([a-zA-Z_]+)[^`]*`.*/\1/' | sort -u
}

# pcf_is_ascending_by_created_at <json_array_text> — rc 0 iff every element's
# `.createdAt` is lexically >= the previous one's (ISO-8601 UTC strings sort
# lexically, per spec §3.3's normative ascending-sort MUST). An empty array
# or a single-element array is trivially ascending (rc 0).
pcf_is_ascending_by_created_at() {
  local text="$1"
  jq -e '
    [.[].createdAt] as $ts
    | ($ts | length) as $n
    | ([range(0; $n - 1) | ($ts[.] <= $ts[. + 1])] | all)
  ' >/dev/null 2>&1 <<<"$text"
}
