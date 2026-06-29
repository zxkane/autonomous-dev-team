# Test Cases — issue #301: `REVIEW_PROTECTED_PATHS` override plumbing

INV-92 (#298) introduced `REVIEW_PROTECTED_PATHS` so an operator can override which
paths the review agent classifies as dev-non-actionable. Two plumbing defects (found
by the `kane-review-agent` post-merge findings on PR #300) prevent the override from
taking effect:

- **Defect 1** — the review-agent classification **prompt** (`autonomous-review.sh`
  `build_review_prompt`, ~1314-1322) hardcodes `.github/workflows/` / `CODEOWNERS`
  instead of interpolating `$REVIEW_PROTECTED_PATHS`. So the lib-side matcher
  (`review_path_is_protected`, which DOES read the conf var) and the agent-facing
  prompt diverge: an operator override changes the lib but not what the agent is told.
- **Defect 2** — `lib-review-classify.sh:39` uses `:=` (`${VAR:=default}`), which
  substitutes the default when the var is unset **OR empty**. So an explicit
  `REVIEW_PROTECTED_PATHS=""` (a deliberate "no protected paths") still gets the
  default list. The `autonomous.conf.example` doc already promises `""` disables
  protection — the code didn't deliver it.

Scope: fix the **lib + prompt source-of-truth** only. NO change to dispatcher routing
(Branch B′), the trailer token, or INV-92's classification contract.

## Defect 2 — default-assignment distinguishes unset from explicit-empty (`lib-review-classify.sh`)

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| TC-301-01 | unset var ⇒ default list applies (regression / fail-safe) | `unset REVIEW_PROTECTED_PATHS`; source lib | `review_path_is_protected .github/workflows/ci.yml` → rc 0; `CODEOWNERS` → rc 0; `src/foo.ts` → rc 1 |
| TC-301-02 | explicit empty ⇒ nothing protected | `export REVIEW_PROTECTED_PATHS=""`; source lib | `review_path_is_protected <anything>` → rc 1 (incl. `.github/workflows/ci.yml`, `CODEOWNERS`) |
| TC-301-03 | explicit-empty aggregate ⇒ protected-path finding is dev-actionable again | `REVIEW_PROTECTED_PATHS=""`; source lib | `review_classify_artifact_dev_actionable` on a sole `.github/workflows/ci.yml` blocking finding (field absent) → `true` (no path is protected ⇒ legacy default applies) |
| TC-301-04 | custom override ⇒ only the override matches | `export REVIEW_PROTECTED_PATHS="custom/**"`; source lib | `review_path_is_protected custom/foo` → rc 0; `.github/workflows/ci.yml` → rc 1 (no longer in the list) |

## Defect 1 — prompt is built from `$REVIEW_PROTECTED_PATHS` (single source of truth)

The classification prompt section emitted by `build_review_prompt` must advertise the
SAME list `review_path_is_protected` reads. Verified by sourcing the wrapper enough to
call `build_review_prompt` (or by grepping the rendered prompt) with the var set.

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| TC-301-05 | custom override reflected verbatim in the prompt | `REVIEW_PROTECTED_PATHS="custom/**"`; render the classification prompt | rendered prompt contains the literal `custom/**`; does NOT advertise the hardcoded default `.github/workflows/` as the protected set |
| TC-301-06 | explicit empty ⇒ prompt advertises NO protected paths | `REVIEW_PROTECTED_PATHS=""`; render the classification prompt | rendered prompt states there are no protected paths (the protected-path branch is a no-op); no path-protection instruction is emitted |
| TC-301-07 | unset ⇒ prompt advertises the default list (regression) | `unset REVIEW_PROTECTED_PATHS`; source lib (applies default); render the prompt | rendered prompt contains `.github/workflows/**` and `CODEOWNERS` (the default list, via the same var the lib uses) |

## Non-regression

| ID | Scenario | Expected |
|----|----------|----------|
| TC-301-08 | full existing `test-review-classify.sh` suite | green |
| TC-301-09 | `test-spec-drift.sh` | green (no state-machine / transitions / codesite change) |

## Notes

- `lib-review-classify.sh` is sourced into `autonomous-review.sh` at line 168, BEFORE
  `build_review_prompt` runs — so the `${VAR-default}` assignment in the lib is the
  single place the default is applied, and `build_review_prompt` reads the already-set
  `$REVIEW_PROTECTED_PATHS` value. No duplicate default in the prompt.
- The fix uses `${REVIEW_PROTECTED_PATHS-<default>}` (no colon) so only an UNSET var
  takes the default; an explicit empty string stays empty.
