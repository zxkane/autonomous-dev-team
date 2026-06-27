# Test Cases: `itp_resolve_dep` + `itp_begin_tick` migration (INV-83, #284)

Class-(b) entangled-function migration. Golden-trace mandatory (§7.1/§7.3).
GitHub-refactor-only, ZERO behavior change.

## Existing suite re-pointed (no semantic edits)

`tests/unit/test-check-deps-resolved.sh` (TC-CRDEP-001..012) is the regression
suite. After the refactor it runs against the **verb seam**: it sources only
`lib-dispatch.sh` (which self-sources `lib-issue-provider.sh` → `itp-github.sh`,
default `ISSUE_PROVIDER=github`). The mocks stay function/binary-level:

- `get_gh_app_scoped_token` is stubbed as a shell function `export -f`'d BEFORE
  sourcing — the provider's `itp_github_resolve_dep` lazy-source guards on
  `declare -F`, so the stub wins (no live mint). **Shim policy:** the mock is a
  function-level stub of the mint primitive, NOT a rename — `get_gh_app_scoped_token`
  must stay resolvable from the provider's lazy-source path (test header lines
  56/70-73). The `gh` BINARY mock (the `gh()` function) is the leaf I/O stub; the
  `gh issue view --json state` argv emitted by `itp_github_resolve_dep` must remain
  byte-identical so the same binary mock applies unchanged.
- `_reset_dep_token_cache` in the test (`_reset_states` + TC-CRDEP-012) is RE-POINTED
  to `itp_begin_tick` — the cache is now provider-owned; the test resets it through
  the verb, proving the cache is cleared by the verb (TICK-BOUNDARY RESET requirement).

| TC | Scenario | Expectation |
|---|---|---|
| TC-CRDEP-001 | app mode, cross-repo CLOSED → scoped mint | rc 0; mint count 1 |
| TC-CRDEP-002 | app mode, cross-repo MERGED | rc 0 |
| TC-CRDEP-003 | app mode, cross-repo OPEN | rc 1 (blocked) |
| TC-CRDEP-004 | App-not-installed (empty state) | rc 1 + sharpened WARN + dep-block comment |
| TC-CRDEP-005 | token routing: same-repo ambient vs cross-repo scoped | rc 0; mint only for cross-repo |
| TC-CRDEP-006 | per-repo mint FAILURE degrades, does NOT exit | rc 1 (fail-safe), process alive |
| TC-CRDEP-007 | PAT mode — no mint, ambient fallback | rc 0; mint count 0 |
| TC-CRDEP-008 | PR-number cross-repo dep MERGED | rc 0 |
| TC-CRDEP-009 | two deps SAME cross-repo minted ONCE (within-call dedup) | mint count 1 |
| TC-CRDEP-010 | block-visibility comment once-per-ref (dedup marker) | no duplicate post |
| TC-CRDEP-011 | TICK-scoped cross-ISSUE dedup (SINGLE-MINT-PER-TICK, #269 anchor) | mint count 1 across 2 issues |
| TC-CRDEP-012 | tick-boundary reset re-mints (via `itp_begin_tick`) | mint count 2 across 2 ticks |

## New: `tests/unit/test-itp-resolve-dep-golden-trace.sh`

| TC | Scenario | Expectation |
|---|---|---|
| TC-RDGT-001 | GOLDEN-TRACE cross-repo argv | `itp_github_resolve_dep` emits EXACTLY `gh issue view <num> --repo <owner/repo> --json state -q .state` under the scoped `GH_TOKEN` prefix (captured argv compared byte-for-byte to the pre-refactor literal) |
| TC-RDGT-002 | GOLDEN-TRACE same-repo argv (`check_deps_resolved` Stage 2b) | the same-repo arm emits EXACTLY `gh issue view <dep_num> --repo $REPO --json state -q .state` with the ambient token — byte-identical to pre-refactor |
| TC-RDGT-003 | DISPATCH-ROUTING | `itp_resolve_dep` routes to `itp_github_resolve_dep` and `itp_begin_tick` routes to `itp_github_begin_tick` under `ISSUE_PROVIDER=github` |
| TC-RDGT-004 | SINGLE-MINT-PER-TICK via `itp_begin_tick` | two issues, one dep repo, one `itp_begin_tick` → `get_gh_app_scoped_token` invoked ONCE |
| TC-RDGT-005 | TICK-BOUNDARY RESET via the verb | second `itp_begin_tick` re-mints → 2 total (cache cleared by the verb, not by `check_deps_resolved`) |
| TC-RDGT-006 | CAPABILITY-BRANCH `cross_ref_shorthand=0` (fake provider) | a degraded fake ITP provider with `cross_ref_shorthand=0` drives the dep-ref path down the non-shorthand branch — the `owner/repo#N` shape is NOT parsed as a cross-repo shorthand (proves the branch is reachable, not dead) |
| TC-RDGT-007 | PAT-mode no-mint via the verb | `itp_github_begin_tick` leaves the cache empty; PAT-mode resolve uses ambient token, zero mint |
| TC-RDGT-008 | NEGATIVE-CACHE no-tick-abort | per-dep-repo mint failure negative-cached (empty), never aborts; a same-repo dep in the same body still resolves (#269 T4) |

## E2E (hermetic, CI-gated)

`tests/unit/test-cross-repo-dep-e2e-wrapper.sh` → `tests/e2e/run-cross-repo-dep-e2e.sh`
(E2E-CRDEP-1..5, incl. E2E-CRDEP-5 cross-issue dedup) must pass against the verb
seam unchanged in intent — the e2e driver's `_reset_dep_token_cache` call is
re-pointed to `itp_begin_tick`.

## Provider-dispatch suite

`tests/unit/test-provider-dispatch.sh` TC-PROVIDER-DISPATCH-020..022: the
`itp_github_resolve_dep` / `itp_github_begin_tick` bodies are now DEFINED (no
longer scaffolds), so the `assert_not_contains "ITP_DEP_PRESENT"` flips to
`assert_contains`.
