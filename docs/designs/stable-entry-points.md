# Design: Phase-0 stable entry points — two-dir resolution (issue #227)

## Problem

Every dispatcher `lib-*.sh` currently requires its own per-project symlink in
`<project>/scripts/`. Entry scripts (and the libs themselves) compute a single
`SCRIPT_DIR` from the **unresolved** `${BASH_SOURCE[0]:-$0}` (per [INV-14]) and
use it for BOTH:

1. **conf lookup** — `load_autonomous_conf "$SCRIPT_DIR"` must resolve from the
   project's `scripts/` (where `autonomous.conf` lives). The unresolved path is
   load-bearing here.
2. **sibling sourcing** — `source "${SCRIPT_DIR}/lib-*.sh"`. Because `SCRIPT_DIR`
   is the project's `scripts/`, every transitive lib must ALSO be symlinked into
   the project's `scripts/`.

When an upstream PR adds a new lib (e.g. `lib-review-e2e.sh`), the consumer's
`scripts/` has no symlink to it. The wrapper `source`s the missing file → `set
-e` exit → the issue strands in `reviewing`/`in-progress` for hours. This is the
documented missing-lib-symlink crash class (drift sibling #153). The upcoming
adapter refactor will churn lib files repeatedly, multiplying the hazard.

## Solution: split the one directory into two

Every entry script computes TWO directories:

| Var | Computed from | Used for |
|---|---|---|
| `CONF_DIR` | `dirname` of the **unresolved** `${BASH_SOURCE[0]:-$0}` | `load_autonomous_conf "$CONF_DIR"` (preserves [INV-14] conf lookup from the project's `scripts/`) AND the legacy `${CONF_DIR}/../../../scripts/autonomous.conf` fallback |
| `LIB_DIR` | `dirname` of `readlink -f "${BASH_SOURCE[0]:-$0}"` (the REAL skill-tree path) | every `source "${LIB_DIR}/lib-*.sh"` / sibling source |

`readlink -f` on a non-symlink path is identity, so direct invocation still
yields `LIB_DIR == CONF_DIR`. Under a project-side symlink, `LIB_DIR` resolves
into the skill tree (where all the libs live, real files) while `CONF_DIR` stays
at the project's `scripts/` (where `autonomous.conf` lives). Result: **lib
sourcing no longer consults the project's `scripts/` at all** → no per-lib
symlink needed.

### Why this is backward compatible

A project that still holds per-lib symlinks keeps working: `readlink -f` follows
each symlink to the same real lib in the skill tree, so `LIB_DIR` points at the
real tree either way; the stale per-lib symlinks are simply never read. The
installer prunes them, but their presence is harmless.

### Libs that source siblings

`lib-agent.sh` and `lib-auth.sh` also source siblings (`lib-config.sh`,
`gh-app-token.sh`). They get the same split:

- `_LIB_*_CONF_DIR` (unresolved) — passed to `load_autonomous_conf`.
- `_LIB_*_DIR` (real-path) — used for `source "${_LIB_*_DIR}/lib-config.sh"` etc.

`lib-config.sh` itself does NOT change — it never sources a sibling and never
calls `readlink`; it consumes the `script_dir` arg the caller passes (always the
CONF dir). The #58 / TC-CONTENT-003 "lib-config.sh must not call readlink -f"
contract is preserved verbatim.

### Helper: shared resolution snippet

To avoid drift across ~10 entry scripts, the two-dir computation is small and
inlined consistently:

```bash
# [INV-65] Two-dir resolution. CONF_DIR = unresolved BASH_SOURCE dir (conf
# lookup, INV-14). LIB_DIR = realpath dir (sibling sourcing from the skill tree
# — no per-project lib symlink needed).
_SELF="${BASH_SOURCE[0]:-$0}"
CONF_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
```

Entry scripts that previously named the var `SCRIPT_DIR` keep `SCRIPT_DIR` as an
alias for `CONF_DIR` (minimizes diff; conf lookups already use it) and add
`LIB_DIR` for the `source` lines.

## Audit of source / conf sites

| File | conf site (→ CONF_DIR) | lib source sites (→ LIB_DIR) |
|---|---|---|
| `autonomous-dev.sh` | (via lib-agent/lib-auth) | `lib-agent.sh`, `lib-auth.sh` |
| `autonomous-review.sh` | (via lib-agent/lib-auth) | `lib-agent.sh`, `lib-auth.sh`, `lib-review-*.sh` (12) |
| `dispatch-local.sh` | `autonomous.conf` + depth-3 fallback | `lib-config.sh` |
| `dispatcher-tick.sh` | `load_autonomous_conf` | `lib-config.sh`, `lib-dispatch.sh`, `lib-review-bots.sh`, `gh-app-token.sh` |
| `setup-labels.sh` | `autonomous.conf` + depth-3 fallback | (none) |
| `gh-token-refresh-daemon.sh` | (none — no conf) | `gh-app-token.sh` |
| `gh-with-token-refresh.sh` | (none) | (none — SELF_DIR only locates token file) |
| `dispatch-remote-aws-ssm.sh` | (none) | `lib-ssm.sh` |
| `liveness-check-remote-aws-ssm.sh` | (none) | `lib-ssm.sh` |
| `lib-agent.sh` | `load_autonomous_conf` (CONF) | `lib-config.sh` (LIB) |
| `lib-auth.sh` | `load_autonomous_conf` (CONF) | `lib-config.sh`, `gh-app-token.sh` (LIB) |
| `lib-dispatch.sh` | (none) | spawns `liveness-check-remote-aws-ssm.sh` via real-path `${_src%/*}` |
| autonomous-common hooks | n/a (no conf) | whole-dir symlink → `dirname` already lands in real dir; unchanged |

**Note on `gh-with-token-refresh.sh`**: `SELF_DIR` is used only to locate the
sibling token-refresh state, not to `source`. It can stay BASH_SOURCE-based;
switching to real-path is harmless but unnecessary. Left unchanged to keep the
diff minimal and its INV-14 comment accurate.

**Note on autonomous-common hooks**: `<project>/hooks` is a whole-directory
symlink into `autonomous-common/hooks/`, so `dirname "${BASH_SOURCE[0]}"`
already resolves to the real hooks dir (the symlink is on the dir, not each
file). They don't read `autonomous.conf`. No change needed.

## Installer changes (`install-project-hooks.sh`)

1. **Symlink only the stable manifest** going forward — entry points + agent-
   callable utilities. Manifest (the public interface, stable forever):

   ```
   autonomous-dev.sh autonomous-review.sh dispatch-local.sh dispatcher-tick.sh
   dispatcher-multi-tick.sh setup-labels.sh
   gh-app-token.sh gh-with-token-refresh.sh gh-token-refresh-daemon.sh
   ```
   Plus the already-symlinked agent-callable utilities (`gh`, `post-verdict.sh`,
   `mark-issue-checkbox.sh`, `reply-to-comments.sh`, `resolve-threads.sh`,
   `gh-as-user.sh`, `upload-screenshot.sh`).

   `lib-*.sh` are NO LONGER symlinked (lib sourcing resolves from the skill tree
   via `LIB_DIR`). The two `*-aws-ssm.sh` helpers are ALSO excluded (#227 P1):
   they source `lib-ssm.sh` from their own dir and the dispatcher invokes them
   from the skill tree (`dispatch()` via `LIB_DIR`; liveness via
   `lib-dispatch.sh`'s skill-tree `BASH_SOURCE`), so a project-side symlink to
   them would resolve the now-absent `lib-ssm.sh` and crash. The manifest rule
   is encoded in `is_entry_script()` as "NOT `lib-*.sh` AND NOT `*-aws-ssm.sh`".

2. **Prune stale non-manifest symlinks** the installer previously created: any
   `<project>/scripts/<file>.sh` that is a symlink into the dispatcher dir but
   is NOT an entry script per `is_entry_script()` — i.e. `lib-*.sh` AND
   `*-aws-ssm.sh` — is removed (now dead weight). Keying the prune on
   `is_entry_script()` keeps it in lock-step with the create rule. Reuses the
   existing dangling-prune loop.

3. **`--doctor`**: report broken/missing entry symlinks, conf presence +
   permissions (0600 expected), and entry-resolution sanity (does `LIB_DIR`
   resolve to a real dir containing `lib-config.sh`?). Read-only; exit 0 = clean,
   exit 1 = problems found.

4. **`--dry-run`**: print every planned create/repoint/prune without touching the
   filesystem. Asserted by an mtime/inode snapshot in tests.

`gh-token-refresh-daemon.sh` and `gh-with-token-refresh.sh` stay in the manifest
because they are spawned/exec'd directly (the daemon is `nohup`'d; the `gh`
symlink points at `gh-with-token-refresh.sh`). They are entry points, not libs.

## Invariant / doc updates

- New **INV-65** in `invariants.md`: the two-dir resolution contract. CONF_DIR =
  unresolved (extends INV-14), LIB_DIR = realpath. Cross-reference INV-14.
- `dispatcher-flow.md`: update the install/topology note — the installer now
  manages only the stable entry manifest; lib sourcing is skill-tree-resolved.
- INV-14 gets a back-reference paragraph pointing to INV-65 for the lib half.

## Test plan (TC-ENTRY-SHIM-NNN)

See `docs/test-cases/stable-entry-points.md`.

- Two-dir resolution: direct, symlinked, nested-symlink invocation.
- Regression pin: upstream adds `lib-new.sh` with NO project symlink → entry
  sources it successfully (the crash class is gone).
- Legacy layout (per-lib symlinks present) behaves identically.
- `--doctor` detects broken symlink + missing conf; `--dry-run` makes zero fs
  changes (inode/mtime snapshot).
- E2E: temp project + symlinked entry + conf → wrapper startup path to first log
  line with one lib deliberately unsymlinked.

## Out of scope

- Node/TypeScript entry shims (later gated phase).
- Installer redesign beyond doctor/dry-run/prune.
