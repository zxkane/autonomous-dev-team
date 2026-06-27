# Design — Provider dispatch skeleton + `.caps` reader (#280)

> Companion design canvas for the **dispatch-skeleton** deliverable of the
> pluggable-providers feature. The authoritative contract is
> [`docs/pipeline/provider-spec.md`](../pipeline/provider-spec.md) (authored by
> #279/#287); this canvas only records the *implementation shape* of the thin
> plumbing this issue adds. **Zero behavior change** — no caller is rewired, no
> `gh` leaf is migrated.

## Goal

Stand up the ITP/CHP provider seam **plumbing** so every later caps-branch /
verb-migration issue builds on it:

1. Two thin verb-dispatch libs — `lib-issue-provider.sh`, `lib-code-host.sh` —
   mirroring `lib-agent.sh`'s `adapter_invoke_<cli>` precedent ([INV-75]).
2. A declarative `.caps` manifest **reader** (parsed key=value, **never
   sourced**, per spec §4 / [INV-88]).
3. Empty `providers/itp-github.{sh,caps}` + `chp-github.{sh,caps}` scaffolds
   whose `.caps` describe **exactly today's GitHub behavior** (§4.3 /
   [INV-88]).
4. A named **degraded fake fixture provider** under `tests/` exercising the
   `caps=0` branches, plus the extension of the `cp -r adapters/`
   fake-skill-tree rule to `cp -r providers/` ([INV-75] fixture rule, §6).

ZERO verb leaves are migrated; the leaf migration is the downstream
`itp-reads` / `itp-writes` / `chp-pr-lifecycle` issues.

## Architecture (mirrors `adapters/<cli>.sh` / [INV-75])

```
scripts/
  lib-issue-provider.sh   # NEW. itp_<verb>() → itp_${ISSUE_PROVIDER}_<verb> "$@"; sources providers/itp-${_p}.sh
  lib-code-host.sh        # NEW. chp_<verb>() → chp_${CODE_HOST}_<verb> "$@";   sources providers/chp-${_p}.sh
  providers/              # NEW dir, sibling to adapters/, flat (spec §6)
    itp-github.sh         # EMPTY scaffold — header + provider-prefix convention only, NO verb bodies
    itp-github.caps       # declarative key=value manifest (9 ITP caps = today's GitHub behavior)
    chp-github.sh         # EMPTY scaffold — header only, NO verb bodies
    chp-github.caps       # declarative key=value manifest (4 CHP caps)
```

### Dispatch shim shape (one per verb)

```bash
itp_caps()           { _itp_read_caps "$@"; }                    # the only verb with a body in this PR
itp_list_by_state()  { itp_"${ISSUE_PROVIDER}"_list_by_state "$@"; }
# … 11 more ITP shims …
chp_find_pr_for_issue() { chp_"${CODE_HOST}"_find_pr_for_issue "$@"; }
# … 11 more CHP shims …
```

- `ISSUE_PROVIDER` / `CODE_HOST` default to `github` when unset (spec §2).
- Each shim forwards `"$@"` verbatim, exactly like
  `lib-agent.sh:adapter_invoke_"$AGENT_CMD" … "$@"`.
- `itp_caps` / `chp_caps` are the only shims with a real body in this PR — they
  call the shared `.caps` reader. All other shims forward to a
  `itp_github_<verb>` / `chp_github_<verb>` that **does not exist yet** (leaf
  migration is downstream) — that is intentional and per scope.

### `readlink -f`-of-`BASH_SOURCE` skill-tree resolution ([INV-14]/[INV-65])

Both libs source their `providers/<p>.{sh,caps}` from the REAL skill tree using
the same idiom `lib-agent.sh:56-60` uses:

```bash
_SELF="${BASH_SOURCE[0]:-$0}"
_REAL_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
source "${_REAL_DIR}/providers/itp-${_p}.sh"
```

This is why **no `install-project-hooks.sh` re-run** is needed — the new
`lib-*.sh` + sourced provider files resolve via the skill tree after `npx
skills update -g` alone (Step 1 only, per the lib-vs-entry rule, spec §6/§8).

The provider search dir is **overridable** via `AUTONOMOUS_PROVIDERS_DIR`
(defaults to the skill-tree `providers/`). This is the hook that lets a
**non-`github` backend selected through the public seam** (`ISSUE_PROVIDER=<name>`
/ `CODE_HOST=<name>`) resolve its `providers/{itp,chp}-<name>.{sh,caps}` from an
alternate dir — so the named degraded fake fixture provider is exercised through
`itp_caps`/`chp_caps` (the real provider-selection path), NOT by reading its
`.caps` file directly. That is what makes the fixture the reusable caps=0 harness
downstream caps-branch tests build on (#280 review [P1]). The same key is shared
by both seams, so an `asana`/`asana`-style topology can point both at one dir.

### `.caps` reader — parsed, NEVER sourced ([INV-88], spec §4/§10 Q1)

```bash
_provider_read_cap() {       # <caps-file> <key>  → value on stdout
  local file="$1" key="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                       # strip inline + full-line comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [[ -z "$line" ]] && continue             # skip blanks
    [[ "$line" != *=* ]] && continue
    if [[ "${line%%=*}" == "$key" ]]; then printf '%s\n' "${line#*=}"; return 0; fi
  done < "$file"
  return 1                                   # unknown key → non-zero, no output
}
```

A `while IFS= read` parse loop — never `source`/`.` of the manifest — so the
manifest is readable under `set -euo pipefail` without the unguarded-source
crash mode that bites this codebase.

## Why these design choices

| Choice | Rationale |
|---|---|
| One shim per verb forwarding `"$@"` | Byte-for-byte mirror of `adapter_invoke_<cli>` ([INV-75]); a reviewer can grep the forward literal per verb. |
| `itp_caps`/`chp_caps` are the only bodied shims | The caps reader is the only behavior the skeleton OWNS; every other verb's body is a downstream migration (out of scope). |
| `.caps` parsed not sourced | Spec §4 / [INV-88]: declarative file is testable under `set -euo pipefail`; sourcing a provider just to read a flag is the documented crash mode. |
| `providers/` flat, sibling to `adapters/` | Spec §6 — the seam lives in the filename, matching the proven adapter precedent + its `cp -r` fixture rule. |
| GitHub `.caps` = today's behavior, not all-ones | [INV-88] no-behavior-change anchor: `server_side_state_negation=0`, `native_issue_pr_link=0` honestly declared. |
| Named degraded fake fixture provider | provider-spec.md §8 (fake-provider) / design-spec §7.4: makes every `caps=0` branch reachable NOW even though the caller branches ship downstream. |

## Out of scope (per issue #280)

- Migrating any `gh` leaf into a verb body (downstream itp-reads / itp-writes /
  chp-pr-lifecycle).
- `itp_resolve_dep` leaf + `itp_begin_tick` INV-83 token-cache logic (this issue
  declares only the shim names).
- Any caller rewire in `lib-dispatch.sh` / wrappers / `lib-review-*.sh`.
- A new INV heading — this issue **references** the existing [INV-87] /
  [INV-88] / [INV-89] (authored by #279/#287); it does not mint a new one.
- Golden-trace tests — no verb leaf carries a `gh` argv here, so there is no
  argv to pin (spec §7.2; golden-trace lands with the leaf-migration issues).
