# Test cases — W1e CHP write contracts (issue #400)

**Scope**: proves the three CHP write verbs (`chp_create_pr`, `chp_approve`, `chp_merge`) migrate from byte-identical gh-argv passthrough to abstract positional contracts, and that the three call sites in `lib-auth.sh` (broker) and `autonomous-review.sh` (PASS/merge) preserve the DECISIONS they made pre-#400.

All TC IDs are `TC-W1E-NNN`. Cross-refs: [#400], [#347 W1e], [INV-87 Migration-log], `provider-spec.md` §3.2 / §10 / Mapping appendix rows 987–990.

## Parity (R5) — `tests/unit/test-w1e-chp-write-parity.sh`

Decision-level parity against the frozen golden `tests/unit/fixtures/w1e-parity/decision-golden.json` (captured PRE-change on the FIRST TDD commit).

| ID | Verb | Class | What it asserts |
|---|---|---|---|
| TC-W1E-100 | `chp_create_pr` | rc 0 success | broker emits `"brokered the PR create for issue #400"`; no raw `gh` call leaked (leaf is defined). |
| TC-W1E-101 | `chp_create_pr` | rc 1 failure | broker emits `"brokered PR create (head=feat/issue-400-foo) failed"` WARN and returns 0 (the success-path no-PR retry re-queues). |
| TC-W1E-110 | `chp_approve` | rc 0 success | wrapper logs `"PR #4242 approved successfully."` and falls through to the merge/no-auto-close branching (NO manual-merge notification, NO transition, NO exit). |
| TC-W1E-111 | `chp_approve` | rc 1 failure | wrapper logs `"Falling back to manual review notification."`, posts the manual-merge notification (`itp_post_comment`), does the `reviewing→approved` transition (`itp_transition_state`), and exits 0. |
| TC-W1E-120 | `chp_merge` | rc 0 success | wrapper logs `"PR #4242 merged successfully."`; emits `metrics_emit merge result=success`; does the CSV `reviewing,autonomous→approved` transition; NO auto-merge-failure marker; NO pending-dev verdict trailer. |
| TC-W1E-121 | `chp_merge` | rc 1 failure | wrapper logs `"Auto-merge failed (rc=1)"` with the leaf's stderr; emits `metrics_emit merge result=failure`; posts a `chp_pr_comment` marker whose body is the first-500-chars excerpt of the leaf's stderr (past-500 tail excluded — bound preserved through the seam); emits the `failed-non-substantive`/`merge-conflict-unresolvable` verdict trailer; does the `reviewing→pending-dev` transition. |

The `chp_merge` failure fixture uses a 600-char stderr suffix to prove the caller's `${MERGE_OUT:0:500}` bound survives the leaf's ownership of `--squash --delete-branch` (the leaf now emits the flags internally, but its stderr is still surfaced back to the caller — parity with the pre-#400 byte-identical passthrough).

## Argv-pin rewrites (R7) — `tests/unit/test-chp-pr-lifecycle.sh` (existing file, re-pinned)

The pre-#400 tests golden-traced the caller's flag-tail forwarding through a byte-identical seam. Post-#400 the leaf owns the flags; the emitted `gh` argv is IDENTICAL but is now driven by positional inputs. Re-pinned:

| ID | Verb | New pin (leaf-emitted argv from positional inputs) |
|---|---|---|
| TC-CHP-CREATE | `chp_create_pr feat/x T B` | `pr create --repo $REPO --head feat/x --title T --body B` |
| TC-CHP-APPROVE | `chp_approve 42 OK` | `pr review 42 --repo $REPO --approve --body OK` |
| TC-CHP-MERGE | `chp_merge 42` | `pr merge 42 --repo $REPO --squash --delete-branch` |
| TC-CHP-BROKER-CREATE | broker + `chp_create_pr` | broker calls `chp_create_pr "feat/issue-282-foo" "My title" "Body line."` (three positionals; leaf emits the flags). |

## Broker / source-shape pins (R7)

| ID | Where | New pin |
|---|---|---|
| TC-FBDISP-020 | `test-token-split-234.sh` (leaf-present arm) | `chp_fbdispleaf_create_pr` records `VERB_CREATE_PR feat/issue-346-foo feat: title Body.` — positional argv, no `--head/--title/--body`. |
| TC-FBDISP-041 | `test-token-split-234.sh` (github-fallback arm) | BYTE-IDENTICAL to pre-#400 — the `_pr_create_ok() { gh pr create --repo "$repo" --head "$branch" --title "$title" --body "$body" >/dev/null 2>&1; }` line stays as spec-sanctioned INV-91 residue. |
| TC-RC-SRC-07 | `test-autonomous-review-request-changes.sh` | source grep `'chp_approve .*"$PR_NUMBER"'` on the PASS path (was `'chp_approve .*--approve'` — the flag moves to the leaf). |
| TC-RMF-SRC-01 | `test-autonomous-review-auto-merge-failure.sh` | source grep `'chp_merge "\$PR_NUMBER"'` on the merge site (was `'chp_merge.*--squash'` — the flag moves to the leaf). |

## AC2 seam-trace (R7 supplement)

`TC-W1E-200` (in the parity test above): the wrapper does not itself pass any `^--` token when it invokes the three verbs — proven structurally by the positional shape of the invocations rewritten in `lib-auth.sh:527` and `autonomous-review.sh:3512, 3553`.

Secondary AC2 guard — a source-grep of the three files ensures no `--head`/`--approve`/`--squash` token appears on `chp_(create_pr|approve|merge)` caller lines outside `providers/`. The github-gated raw fallback in `lib-auth.sh` is EXEMPT: it is a `gh pr create` line, not a `chp_create_pr` line.

## Conformance runner (R6) — `tests/provider-conformance/run-provider-conformance.sh`

Three new `_run_write_assert` cases (template: the `chp_request_changes` case at `run-provider-conformance.sh:456`):

| Verb | Success stub-argv needle (positional through the leaf) | Failure fixture assertion |
|---|---|---|
| `chp_create_pr` | `pr create --repo o/r --head feat/x --title t --body b` — positionals `feat/x t b` | `_PCF_GH_MODE=fail` → rc ≠ 0 (fail-closed). |
| `chp_approve` | `pr review 42 --repo o/r --approve --body msg` — positionals `42 msg` | `_PCF_GH_MODE=fail` → rc ≠ 0. |
| `chp_merge` | `pr merge 42 --repo o/r --squash --delete-branch` — positional `42` | `_PCF_GH_MODE=fail` → rc ≠ 0; stderr diagnostics preserved. |

`coverage.conf` flips these three from `pending`→`asserted` and the three `CONTRACT-PENDING` tokens in spec §3.2 disappear, so the R3 tripwire (coverage.conf ↔ spec CONTRACT-PENDING set-diff) reconciles.

`cap-map.conf` gains three new rows: `chp_create_pr=-`, `chp_approve=-`, `chp_merge=-`. All three are core writes with no governing capability — the same shape as the existing `chp_reply_review_comment=-` / `chp_review_threads=-` / `chp_resolve_thread=-` rows.

## Degraded fixture (R4) — `tests/unit/fixtures/provider-degraded/chp-degraded.sh`

Three new leaves that RECORD received argv and return rc 0 with no output on well-formed positionals:

- `chp_degraded_create_pr <head> <title> <body>` — records argv; NO issue transition.
- `chp_degraded_approve <pr> <body>` — records argv.
- `chp_degraded_merge <pr>` — records argv; performs NO issue transition (the degraded `.caps` sets `merge_closes_issue=0` — so the caps=0 caller branch tests must observe the CALLER doing the explicit `itp_transition_state`, never the fixture inferring GitHub auto-close).

The existing `TC-CHP-CAP-MCI0-*`/`TC-CHP-CAP-BOTS0-*`/`TC-CHP-LEAF-GUARD*` pins in `test-chp-pr-lifecycle.sh` are UNCHANGED — those branches are caller-side and untouched by W1e.

## Out-of-scope

- `chp_request_changes` (already positional/abstract per #282); `chp_close_keyword` (already abstract per #282).
- The `merge_closes_issue`/`review_bots`/`rest_request_changes` caps CALLER branches — those are caller-side and unchanged.
- W1(f) `chp_review_threads` pagination — next slice, serialized behind #400.
- Prompt-prose `gh pr create` instructions to unscoped agents — phase-3 per #347.
