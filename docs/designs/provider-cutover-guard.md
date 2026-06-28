# Design — providers cutover guard (`check-provider-cutover.sh`, INV-91)

Issue #286. Final strangler-fig cutover guard for the pluggable-providers refactor
(spec §7 / §9). Guards that no NEW raw `gh` call re-enters the provider-neutral
caller layer outside `scripts/providers/`.

> **Revision (review round 1, codex 4 BLOCKING findings).** This design was
> updated after review. The authoritative descriptions now live in
> `docs/pipeline/invariants.md` (INV-91) and `provider-spec.md` §9; the changes:
> - **F1/AC #2**: failure messages now name the exact `file:line` (resolved live
>   via `grep -nF` at report time; the baseline stays line-number-free).
> - **F2/AC #41**: the scan is **tree-wide** (every `*.sh` + `providers/*.sh`),
>   not just the caller layer — `setup-labels.sh`/`lib-auth.sh`/`dispatcher-tick.sh`
>   etc. are in scope; the baseline grew from 49→76 sigs accordingly, and the
>   guard script allowlists itself.
> - **F3**: the guard RUNS in CI via the existing `tests/unit/test-*.sh` loop
>   (the [INV-83] precedent), because the scoped App token cannot push
>   `.github/workflows/`. The ci.yml step is an optional operator enhancement, not
>   a precondition for CI execution — the docs no longer claim a dedicated step
>   exists.
> - **F4**: the caps gate no longer emits a bare PASS for the unwired caps. The
>   8 live caps are EXERCISED (4 run end-to-end against the degraded fixture); the
>   5 are WAIVED behind a fail-on-wiring tripwire; headline `exercised=8 waived=5
>   total=13`. (`body_checkbox` is live-branched in `mark-issue-checkbox.sh` — its
>   degraded `body_checkbox=0` native-subtask-remap path is run end-to-end.)
>
> **Revision (review round 2, codex 2 BLOCKING findings).**
> - **R2-F1**: the scan now RECURSES (`find -L` over every `*.sh` at any depth) —
>   the old top-level + `providers/`-only glob missed `adapters/*.sh` and any
>   nested subdir. `-L` keeps the tracked-but-symlinked scripts
>   (`mark-issue-checkbox.sh`, `reply-to-comments.sh`, `upload-screenshot.sh`,
>   `gh-as-user.sh`) in scope (a plain `-type f` would skip a symlink and silently
>   drop their gh sites). Baseline regrew to 82 sigs / 104 occ.
> - **R2-F2**: `check-provider-cutover.sh` is NO LONGER wholesale-allowlisted — it
>   is scanned like any file and its own `gh `-mentioning lines are baselined
>   survivors, so a real `gh api user` added to the checker now trips the guard.
>   Regression tests: TC-CUTOVER-015 (nested `adapters/codex.sh`), TC-CUTOVER-016
>   (symlinked `mark-issue-checkbox.sh`), TC-CUTOVER-014 (rewritten: a new gh in
>   the checker FAILs).
>
> **Revision (later review round, codex — same-PR baseline self-ratification).**
> - The checker's baseline was self-ratifying: a PR that BOTH added a raw-gh AND
>   `--generate-baseline`d passed Check 1 (review reproduced `gh issue view 123` +
>   regenerate → exit 0). Added **Check 4 — baseline monotonicity vs the trusted
>   ref** (`origin/main` by default; `--trusted-ref` / `CUTOVER_TRUSTED_REF`): the
>   working-tree baseline may only SHRINK vs the merged copy; a grown signature or
>   count FAILs naming the site. Skips gracefully off-git / on the first PR that
>   introduces the baseline (the merge gate re-runs it with `origin/main`).
>   Regression tests: TC-CUTOVER-017 (bypass closed), TC-CUTOVER-018 (shrink/clean
>   allowed + missing-ref graceful skip).
> - The detector now greps with **`-a`** (force text): a script carrying UTF-8
>   punctuation can be misclassified "binary" by grep under some locales, silently
>   suppressing matches — a latent hole where a real raw-gh could slip the scan.
>
> **Revision (later review round, codex — shallow-CI Check 4 skip hole).**
> - Check 4's graceful skip on an unresolvable trusted ref disabled it in the one
>   place the guard runs: the hermetic-unit job uses a depth-1 `actions/checkout`
>   (no `origin/main`), so a PR could add a raw-gh + regenerate the baseline and
>   pass green (reproduced in a shallow clone). Added **`--require-trusted-ref`**
>   (env `CUTOVER_REQUIRE_TRUSTED_REF=1`): an unresolvable trusted ref becomes a
>   hard FAILURE, not a skip. Default stays permissive (fork / ad-hoc runs); the
>   unit test drives the guard with it ON against a self-contained git fixture
>   (TC-CUTOVER-019), so monotonicity is enforced regardless of checkout depth, and
>   the operator-applied ci.yml step uses `fetch-depth: 0` + `--require-trusted-ref`.
>
> **Revision (later review round, codex — initial-landing self-ratification + CI-vs-main).**
> - Check 4 returned PASS when the trusted ref existed but had no `cutover-baseline.json`
>   yet ("nothing to regress against"), so the PR that INTRODUCES the baseline could
>   bake in new raw-gh (reproduced: add `gh issue view 999` to `dispatcher-tick.sh` +
>   `--generate-baseline` -> exit 0). Fix: when the trusted baseline JSON is absent at
>   the ref, **DERIVE the trusted survivor set from the trusted TREE** (`git show
>   <ref>:<path>` over its `*.sh`, dereferencing symlinked tracked scripts -- the
>   ref-tree analogue of `find -L`). A new raw-gh in an EXISTING on-ref script is then
>   caught even on the landing PR; a growth in a file ABSENT from the ref is the
>   legitimate introduction of a NEW file (e.g. the guard itself), allowed + still
>   gated by Check 1. Regression test: TC-CUTOVER-020.
> - finding #2 (CI never compares this branch's baseline to real `origin/main`): the
>   monotonicity algorithm is proven against self-contained fixtures, and the real
>   branch-vs-main comparison runs once the ci.yml step lands `fetch-depth: 0` +
>   `--require-trusted-ref` — that step is a **non-blocking maintainer follow-up
>   (#295)**, NOT part of this PR (owner ruling 2026-06-28; the scoped token can't
>   push `.github/workflows/`, INV-83).
>
> **Revision (owner AC rewrite, 2026-06-28 — strict-mode fail-closed, AC #6).**
> - Owner rewrote the ACs to be satisfiable and split ci.yml (#295) + the 104-site
>   migration (#296) into non-blocking follow-ups. The one real defect to fix:
>   **AC #6 strict-mode fail-closed.** Under `--require-trusted-ref`, a
>   missing/unreadable/unparseable baseline — or a trusted ref lacking
>   `cutover-baseline.json` — now `exit 1`s (no silent derive-from-tree fallback in
>   strict mode; derive-from-tree stays the NON-strict best-effort belt). A baseline
>   is (re)generated only under `--generate-baseline`. Tests: TC-CUTOVER-021.

## Reality check that shapes this design (the load-bearing decision)

The issue body assumes the depends-on issues (#281–#285) left the caller layer
**fully migrated** (zero raw `gh`), so a strict "no raw `gh` in the caller layer"
lint would `exit 0` on HEAD. **That premise does not hold on the merged HEAD
(`d81e2c2`).** The first deliverable migrated only the **spec-named verb leaves**
(provider-spec.md §3.1/§3.2); ~48 genuine wrapper-executed `gh issue/pr/api`
calls (and ~70 `gh ` tokens once heredoc-prose lines are counted) **survive** in
the caller layer — many self-documented "itp_transition_state not yet migrated →
GitHub-rendered close". `autonomous-review.sh` alone carries 15 raw `gh issue
edit` label flips alongside 12 `itp_transition_state` calls.

A strict ban therefore **cannot** `exit 0` today. This was escalated on the issue
with three options; no maintainer reply arrived and the dispatcher kept
re-dispatching, so this PR ships the **option the blocker recommended** — a
**baseline-anchored regression guard** — and flags the divergence from the
literal ACs loudly in the PR body for the reviewer to rule on.

The issue's own AC #41 sanctions this reading: *"every SURVIVING raw-gh site …
resolves to either `providers/` **or an allowlisted** [file/construct]"* and the
Check-3 allowlist text already lists *"comment-anchor lines"*. The surviving
caller-layer sites are the allowlisted set — recorded **declaratively in a
manifest file**, NOT by editing the wrapper files (Out-of-Scope: "touches NO
runtime wrapper logic"; self-hosting: never dirty a live wrapper).

## What the lint does

`check-provider-cutover.sh` — credential-free grep/jq, modeled byte-for-byte on
`check-spec-drift.sh` (`set -uo pipefail`, `SCRIPT_DIR`/`PROJECT_ROOT`,
`fail()`/`info()`, `::error::`, path-override flags, exit `0/1/2/3`). Header cites
**INV-91**.

- **Check 1 — no NEW raw-gh in the caller layer.** Scan the caller-layer files
  (`lib-dispatch.sh`, `autonomous-dev.sh`, `autonomous-review.sh`, every
  `lib-review-*.sh`) for a raw `gh ` token using the RE2-safe **consuming
  boundary** `(^|[^A-Za-z_-])gh ` (never a look-behind — memory
  `project_gh_jq_re2_no_lookbehind`). Skip comment lines (first non-space char
  `#`). Each surviving site is `(file, trimmed-content)`. Reconcile the discovered
  **per-(file,content) count** against the declarative baseline
  `providers/cutover-baseline.json`: a discovered site absent from the baseline,
  or a count above baseline, or a baseline entry with no discovered site → FAIL
  LOUD naming `file` + content. This catches a NEW raw-gh (different content),
  a DUPLICATE of an existing one (count bump), and a REMOVED one (count drop →
  forces baseline shrink as migration lands). Mirrors `check-spec-drift.sh` C.4.
- **Check 2 — provider files exist + are the only NON-baselined gh holders.**
  Assert `providers/itp-github.sh` and `providers/chp-github.sh` exist. Every
  raw-gh site discovered anywhere under `skills/autonomous-dispatcher/scripts/`
  must resolve to: `providers/`, an allowlisted file, or a baseline entry.
- **Check 3 — allowlist + baseline integrity.** The file allowlist (`gh`,
  `gh-with-token-refresh.sh`, `gh-app-token.sh`, `gh-as-user.sh`,
  `dispatch-remote-aws-ssm.sh`) is declarative in the script; a stale entry
  (file gone) FAILs. The baseline JSON must be well-formed; a baseline entry
  whose file no longer exists FAILs.
- **Check 4 — baseline MONOTONICITY vs the trusted (merged) ref.** Closes the
  same-PR self-ratification bypass: Check 1 only proves the tree matches WHATEVER
  baseline ships in the same change, so a PR that BOTH adds a raw-gh AND
  `--generate-baseline`s would pass Check 1 (the #286 review reproduced this with
  `gh issue view 123` + a regenerated baseline → exit 0). Check 4 reads the trusted
  baseline at `--trusted-ref` (default `origin/main`, overridable via the flag or
  `CUTOVER_TRUSTED_REF`) with `git show <ref>:<path>` and FAILs if the working-tree
  baseline GREW — a new `(file,content)` signature, or a higher count for an
  existing one. SHRINKING (a migration removed a leaf) is allowed; the baseline may
  only ever get smaller. When not in a git work tree, or the ref / trusted baseline
  is unresolvable (shallow / fork checkout, or the very first PR that introduces the
  baseline), Check 4 SKIPS gracefully with an `info` note — the credential-free
  merge gate re-runs it with `origin/main` present, and Check 1 still anchors the
  tree to the in-repo baseline meanwhile.

Baseline keyed by content (not line numbers) → robust to line drift. Count-based
→ robust to identical-duplicate lines. The detector greps with `-a` (force text):
a script carrying UTF-8 punctuation can be misclassified "binary" by grep under
some locales, which would SILENTLY suppress matches — `-a` makes the scan
content/locale-independent.

## Caps-branch coverage gate (`test-provider-caps-branches.sh`)

Spec §4.3: on this GitHub-only HEAD, only the caps that have a **live caller
degradation branch** can be exercised. Grep proves **7 of 13** caps have a live
branch:

| cap (=0/degraded) | live caller branch |
|---|---|
| `cross_ref_shorthand` | lib-dispatch.sh |
| `edit_comment` | lib-review-e2e.sh |
| `label_colors` | setup-labels.sh |
| `native_issue_pr_link` | autonomous-dev.sh |
| `rest_request_changes` | lib-review-request-changes.sh |
| `review_bots` | lib-auth.sh, autonomous-review.sh |
| `merge_closes_issue` | autonomous-review.sh, autonomous-dev.sh |

The other 6 (`server_side_state_and`, `server_side_state_negation`,
`distinct_bot_author`, `read_after_write_state`, `body_checkbox`,
`marker_channel`) have **NO caller branch yet** — their degradation lands with
the GitLab/Asana PRs (spec §4.3 "the only live branches are GitHub's current
ones"). The coverage gate therefore:
- for each cap WITH a live branch: drives the fake degraded provider's caps=0
  path through the public seam and asserts the caller branch is **reached** (not
  dead code);
- for each cap WITHOUT a live branch: asserts **no caller branch keys on it yet**
  (a structural "nothing to cover"), so the gate cannot fabricate coverage AND a
  future PR that wires the branch is forced to add its coverage assertion (the
  "no branch exists" assertion flips red until updated).

Fixture: the existing `tests/unit/fixtures/provider-degraded/` driven via
`ISSUE_PROVIDER=degraded` + `AUTONOMOUS_PROVIDERS_DIR` (per #280 TC-030/031).

## Docs

- `invariants.md` — **INV-91** (next free; INV-86..90 taken by #278/#287/#281),
  machine-checked triage tag pointing at `tests/unit/test-provider-cutover.sh`.
- `provider-spec.md` §9 — reference INV-91 as the cutover/anti-regression guard;
  note the baseline manifest + allowlist + CI wiring; cross-ref the caps-branch
  coverage gate.
- `state-machine.md` — **no change** (this lint guards the gh-call surface, not
  the label-write/transition surface).

## CI wiring

`ci.yml` — run `bash skills/autonomous-dispatcher/scripts/check-provider-cutover.sh`
in the credential-free spec-drift job; add the script + the test to the hermetic
`shellcheck -S error` list (sibling to `check-spec-drift.sh`).
