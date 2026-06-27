# Design: dependency resolution behind `itp_resolve_dep` + `itp_begin_tick` (INV-83)

Issue #284. Part of the pluggable issue-tracker + code-host providers first
deliverable (design + GitHub refactor only, ZERO behavior change). Design spec:
`docs/superpowers/specs/2026-06-27-pluggable-issue-and-code-host-providers-design.md`
(referenced; this is a class-(b) entangled-function migration per §7.1(b) / §3.6).

## Goal

Cut the cross-repo dependency-resolution **leaf I/O** in `lib-dispatch.sh` behind
two new ITP verbs (`itp_resolve_dep`, `itp_begin_tick`) while keeping every
INV-coupled caller decision provider-neutral. GitHub-refactor-only, no behavior
change. A golden-trace test pins the byte-identical `gh issue view` argv and the
single-mint-per-tick / cross-issue-dedup behavior so the #269 regression cannot
return.

## What moves vs. what stays

```
                          BEFORE (#269/INV-83)                         AFTER (#284)
                          ───────────────────                          ────────────
lib-dispatch.sh
  resolve_dep_state()  ── gh issue view --json state (cross-repo) ──┐
                          + scoped-token mint + _DEP_TOKEN_CACHE     │  thin caller wrapper:
                                                                     │  delegates leaf+mint+cache
  _DEP_TOKEN_CACHE        (module-scope assoc array)                 │  to itp_resolve_dep via
  _reset_dep_token_cache  (clears the cache)                         │  the SAME out-var contract
  DEP_LOOKUP_PERMISSIONS  (the {"issues":"read"} default)            │
                                                                     ▼
  check_deps_resolved()   parse + INV-11 predicate + fail-safe   ── STAYS caller-side (unchanged),
                          + same-repo `#N` ambient gh leaf           same-repo leaf STAYS caller-side,
                          + _dep_block_comment CALL                  + cross-repo arm gated on
                                                                       `cross_ref_shorthand` cap

providers/itp-github.sh
  itp_github_resolve_dep()  ◄── NEW: the cross-repo + same-repo `gh issue view --json state`
                                leaf, the scoped-token mint, the get_gh_app_scoped_token
                                lazy-source, DEP_LOOKUP_PERMISSIONS. Uses an out-var so the
                                cache mutation stays in the caller's shell.
  itp_github_begin_tick()   ◄── NEW: owns _DEP_TOKEN_CACHE (declare) + the reset body that
                                was _reset_dep_token_cache.

dispatcher-tick.sh:227-229   _reset_dep_token_cache  ──►  itp_begin_tick  (once, before Step 2)
```

## The out-var contract (load-bearing — AC + §3.6)

`resolve_dep_state` MUST keep writing its result via `printf -v "$out_var"`, NOT
stdout / `$(...)`. Reason (verbatim from the pre-existing INV-83 rationale): the
per-tick mint mutates the module-level `_DEP_TOKEN_CACHE`; that write must happen
in the **caller's shell** so the cache survives across the multiple refs in one
`check_deps_resolved` call (and across issues in one tick). A command-substitution
capture would run the whole body — mint + cache write — in a subshell and the
dedup cache would reset on every ref.

To preserve this **through the provider seam**, the chain is:

```
check_deps_resolved   → resolve_dep_state OWNER_REPO NUM OUT_VAR   (caller, in-shell)
resolve_dep_state     → itp_resolve_dep   OWNER_REPO NUM OUT_VAR   (shim, in-shell)
itp_resolve_dep       → itp_github_resolve_dep OWNER_REPO NUM OUT_VAR
itp_github_resolve_dep: mint+cache (_DEP_TOKEN_CACHE) + gh issue view; printf -v "$OUT_VAR"
```

No link in that chain uses command substitution, so `_DEP_TOKEN_CACHE` (now
declared/owned by `itp_github_begin_tick`, a module-scope global) is mutated in
the dispatcher's shell and the tick-scoped dedup is preserved. The spec's abstract
`itp_resolve_dep REF` signature is realized as `itp_resolve_dep OWNER_REPO NUM
OUT_VAR` — the `REF` is the `OWNER_REPO`+`NUM` pair, and the out-var is the
in-shell channel the cache lifecycle requires.

## `cross_ref_shorthand` capability gate (AC + §7.4)

`check_deps_resolved`'s parse recognizes two ref shapes today: `owner/repo#N`
(cross-repo) and `#N` (same-repo). The `owner/repo#N` **shorthand** is a
capability — `cross_ref_shorthand=1` for GitHub (today's path). The caller reads
`itp_caps cross_ref_shorthand` once and gates the Stage-2a cross-repo loop on it:

- `cross_ref_shorthand=1` (GitHub) → the `owner/repo#N` shape is parsed exactly as
  today (no behavior change).
- `cross_ref_shorthand=0` (e.g. the degraded fake provider, or a future
  gid/permalink backend) → the `owner/repo#N` shorthand is NOT recognized; refs
  would carry a full id / permalink (that full-id branch is not live this PR —
  only GitHub's `=1` path runs in production — but the branch exists so the
  capability is not dead untested code, per §7.4).

The same-repo `#N` arm is unconditional and unchanged (ambient `gh`, no cap gate).

## Why no new INV

Per the issue's design-review audit note: UPDATE the existing INV-83 entry
(provider-internal mint+cache behind `itp_begin_tick`; leaf lookup behind
`itp_resolve_dep`); mint NO new INV. INV-83's guarantees are all preserved:
single mint per `owner/repo` per tick, negative-cache on mint failure, no tick
abort, PAT-mode no-mint fallback, tick-boundary reset. They simply now live
inside the GitHub ITP provider.

## Resolution / standalone-source safety

`lib-dispatch.sh` already self-sources `lib-issue-provider.sh` from the real skill
tree via `readlink -f` (lines 53-61) when `itp_list_comments` is undefined — so
`itp_resolve_dep` / `itp_begin_tick` resolve to `itp_github_*` (default
`ISSUE_PROVIDER=github`) in EVERY context that sources `lib-dispatch.sh`:
`dispatcher-tick.sh`, the standalone unit test, and the e2e driver. No new source
line is needed in `dispatcher-tick.sh`. The provider's
`get_gh_app_scoped_token` lazy-source (the `gh-app-token.sh` `readlink -f` block)
moves into the provider verbatim so a unit test that stubs the mint function still
wins (the lazy-source guards on `declare -F`).
