# Test Cases: cross-repo dependency scoped token (#269)

Component: `lib-dispatch.sh::check_deps_resolved` / `resolve_dep_state`,
`gh-app-token.sh::_app_install_token`.

## Unit — `tests/unit/test-check-deps-resolved.sh` (extended)

The mock `gh()` is made **`$GH_TOKEN`-aware**: a cross-repo lookup returns
empty/error UNLESS the injected lookup-token sentinel is in scope. Without this
the regression test passes with OR without the fix (theater).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CRDEP-001 | App mode, cross-repo CLOSED dep; repo-A token in scope, mint yields a repo-B-scoped lookup token | resolves, rc 0 (AC #1) — **fails without the fix** because the repo-A token returns empty state |
| TC-CRDEP-002 | App mode, cross-repo MERGED dep, scoped mint | rc 0 |
| TC-CRDEP-003 | App mode, cross-repo OPEN dep, scoped mint | rc 1 (blocked) |
| TC-CRDEP-004 | App mode, cross-repo empty-state (App not installed → 404) | rc 1 + sharpened WARNING text asserted (`the App may not be installed on <repo>`) |
| TC-CRDEP-005 | Token routing: same-repo `#N` uses the ambient token; cross-repo uses the per-repo lookup token | same-repo resolves with ambient sentinel, cross-repo resolves only with the per-repo sentinel |
| TC-CRDEP-006 | Per-repo mint FAILURE degrades to fail-safe block, does NOT poison same-repo dispatch (no `exit 1`); same-repo dep in the same body still evaluated | cross-repo blocks (rc 1), function returns (does not exit), same-repo arm still ran |
| TC-CRDEP-007 | PAT mode: no mint, ambient fallback, no behavior change | identical to legacy: cross-repo CLOSED → rc 0 using ambient token, no mint recorded |
| TC-CRDEP-008 | PR-number dependency ref (`gh issue view --json state` on a PR returns OPEN/CLOSED/MERGED) resolves correctly | MERGED PR cross-repo dep → rc 0 |
| TC-CRDEP-009 | Cache: two deps in the SAME cross-repo are minted ONCE | mint recorded exactly once for two refs in `owner/repo` |
| TC-CRDEP-010 | Block-visibility comment posted once-per-ref on a persistent block (dedup marker) | comment with `<!-- dep-block:<repo>#<num> -->` posted once; a second call does not duplicate |

## Unit — `tests/unit/test-gh-app-token-split-269.sh` (new)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-APPTOK-269-001 | `_app_install_token` exists and `get_gh_app_token` delegates to it (structural T1) | source-level: `get_gh_app_token` calls `_app_install_token`; the function is defined |
| TC-APPTOK-269-002 | `get_gh_app_token` body is byte-identical full-grant when no permissions arg (regression) | `_build_access_token_body 'r' ''` → `{"repositories":["r"]}` (also covered by TC-TOKEN-SPLIT-001) |

## Regression (CRITICAL — must stay green)

- `tests/unit/test-check-deps-resolved.sh` existing same-repo cases.
- `tests/unit/test-token-split-234.sh` TC-TOKEN-SPLIT-001/002/003.
- `tests/unit/test-dispatcher-tick-app-auth.sh` (all TC-DISP-AUTH-*).

## Integration / Conformance

- Hermetic end-to-end driver `tests/e2e/run-cross-repo-dep-e2e.sh` (the existing
  `tests/conformance/` harness is adapter-spec-shaped — per-CLI classification —
  not dispatcher-tick shaped, so a dedicated driver is the right fit). It
  exercises the REAL `check_deps_resolved` + `resolve_dep_state` with a stub `gh`
  that enforces token scope, proving the end-to-end CLOSED-cross-repo-dep →
  dispatch path, with a counter-proof that the no-mint path 404s.
- The driver is run in the hermetic CI tier through
  `tests/unit/test-cross-repo-dep-e2e-wrapper.sh` — a thin unit-suite wrapper that
  execs the driver and asserts its `CROSS-REPO-DEP-E2E-SUMMARY pass=N fail=0`.
  CI's `Run all unit tests` step iterates `tests/unit/test-*.sh`, so the wrapper
  pulls the E2E into CI WITHOUT a `.github/workflows/` change (a scoped App token
  lacks the `workflows` permission, [INV-79], and cannot edit `ci.yml`).

## API verification (T8, manual pre-merge)

One real mint against `api.github.com` with `{"issues":"read"}` → HTTP 200 +
a token that reads issue state. Recorded in a code comment in `lib-dispatch.sh`.
