# Design: REST existence probe for `itp_github_provision_states` (#362)

## Problem

`itp_github_provision_states()` (`providers/itp-github.sh`) checks label
existence via `gh label view "$name" --repo "$REPO"`. `gh label` has no `view`
subcommand (confirmed on `gh` 2.92.0 and 2.73.0 — only `clone/create/delete/edit/
list`). The call always exits non-zero, so the `if` branch is never taken and
the function always falls through to `gh label create`, which itself exits
non-zero when the label already exists. Under `setup-labels.sh`'s
`set -euo pipefail`, that abort kills the whole script on the first
pre-existing label, so any repo that already has one or more of the 9 pipeline
labels never gets the rest provisioned.

The bug pre-dates the #291 provider migration — `setup-labels.sh:44` had the
identical `gh label view` line before the byte-identical migration into
`providers/itp-github.sh`. The migration faithfully preserved the pre-existing
bug; this fix targets the current leaf only.

## Chosen probe

Replace the existence check with a per-label REST probe:

```bash
if gh api "repos/${REPO}/labels/${name}" --silent &>/dev/null; then
```

`GET /repos/{owner}/{repo}/labels/{name}` returns 200 if the label exists, 404
otherwise; `gh api` maps that to rc 0 / non-zero, giving the same `if`
existence-check shape the (broken) `gh label view` line was meant to provide.
No URL-encoding is needed: all 9 pipeline label names are `[a-z-]` (URL-safe).

## Alternatives rejected

- **`gh label list | grep -qxF "$name"`.** Two hazards: (a) `gh label list`
  defaults to a 30-item page, so a repo with >30 labels would silently miss
  matches without an explicit `--limit`; (b) a `... | grep -q` pipeline under
  `set -euo pipefail` is a known SIGPIPE hazard in this codebase (the
  capture-then-test convention exists for exactly this reason — grep exits
  after the first match while gh's list command is still writing, which can
  raise SIGPIPE and abort the script under `pipefail`). The REST probe avoids
  both: one call per label (matching the existing loop shape), no pagination
  cap, no pipe.

## Behavior preserved

- `label_colors=1` (GitHub): unchanged — `--color <hex> --description <d>` is
  still passed to `gh label create` on the create branch.
- `[skip]` / `[created]` console output: unchanged.
- Loop shape (one call per label, caller-side 9-label table): unchanged.
- `--force`-style update-existing-label behavior: explicitly out of scope
  (pre-existing labels are left untouched, same as before).
