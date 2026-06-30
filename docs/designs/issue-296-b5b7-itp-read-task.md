# Design — migrate live-wrapper issue READS behind `itp_read_task` (#296 B5+B7)

## Goal

Migrate the two byte-identical `gh issue view` READ sites in the live wrappers
behind the already-shipped `itp_read_task` verb. **Zero behavior change** — the
verb is a raw argv passthrough, so the emitted `gh` command is identical.

Part of #296 (pluggable-providers raw-`gh` migration). This is the **read-only
subset of the live-wrapper tier (B5 + B7)**, deliberately split from the
label-WRITE sites (B8 / #311) — writes carry state-machine-routing stakes +
spec-drift-manifest coupling and are handled separately.

## The verb (shipped — no wiring)

`itp_read_task` is the shim in `lib-issue-provider.sh`:

```sh
itp_read_task()            { itp_${ISSUE_PROVIDER}_read_task "$@"; }
```

routing to the GitHub leaf in `providers/itp-github.sh`:

```sh
itp_github_read_task() {
  local issue="$1" field="$2"; shift 2
  gh issue view "$issue" --repo "$REPO" --json "$field" "$@"
}
```

The trailing `--json <fields>` arrives as `$field`; the trailing `-q '<sel>'`
rides through `"$@"` unchanged → **byte-identical** `gh` argv.

The ITP seam is **already sourced** in both wrappers
(`autonomous-dev.sh:69`, `autonomous-review.sh:207`) and the exact verb form is
already in production (`autonomous-dev.sh:1174`: `itp_read_task "$ISSUE_NUMBER" title,body -q '.'`).
These are **pure call-site swaps**: no new `source` line, no wiring.

## The two sites (verified against merged main)

| Tag | File:line | Before | After |
|---|---|---|---|
| B5 | `autonomous-dev.sh:887` | `ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body,comments -q '.')` | `ISSUE_BODY=$(itp_read_task "$ISSUE_NUMBER" title,body,comments -q '.')` |
| B7 | `autonomous-review.sh:3439` | `HAS_NO_AUTO_CLOSE=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels \`<br>`  -q '[.labels[].name] \| any(. == "no-auto-close")' 2>/dev/null \|\| echo "false")` | `HAS_NO_AUTO_CLOSE=$(itp_read_task "$ISSUE_NUMBER" labels \`<br>`  -q '[.labels[].name] \| any(. == "no-auto-close")' 2>/dev/null \|\| echo "false")` |

The B7 site is a multi-line command; only the **first physical line** carries
the `gh` token (the `--repo "$REPO" --json labels` collapses into the verb's
positional args), and the second line (the `-q '<selector>'` + the
`2>/dev/null || echo "false"` guard) is unchanged.

## Why this is autonomous-safe

1. **Byte-identical**, pure argv passthrough — golden-trace provable.
2. **No spec-drift coupling**: these are READS, not label writes.
   `check-spec-drift.sh` only reconciles `--add-label`/`--remove-label` write
   sites; reads are invisible to it (AC6 asserts the count is UNCHANGED).
3. **Live-wrapper edit is safe**: the autonomous dev agent works in a worktree;
   the dispatcher reads committed state; merge is atomic; a running wrapper
   already forked its file. Worktree isolation is identical to the merged lib
   batches (B1–B4).
4. **Precedent**: `itp_read_task … -q` already ships at `autonomous-dev.sh:1174`.

## Baseline impact (AC3)

`scripts/providers/cutover-baseline.json` shrinks by **exactly 2** surviving
signatures — the autonomous-dev.sh `gh issue view … title,body,comments`
survivor and the autonomous-review.sh `gh issue view … labels` survivor.
Both new lines (`itp_read_task …`) carry no `gh` token, so the scanner drops
them. Regenerated in-PR via `bash check-provider-cutover.sh --generate-baseline`.

## Out of scope (must remain baselined)

- B8 label-WRITE sites (`gh issue edit` → `itp_transition_state`) → #311
  (spec-drift-manifest-coupled, needs a human spec-design decision first).
- Comment-reads (`autonomous-dev.sh:612/1048` `gh issue view --json comments` →
  `itp_list_comments` NORMALIZES shape, not byte-identical; `:1060/1067`
  `gh api …/comments` → need new verb).
- The `gh issue close`, remove-only / multi-remove label flips.
- Minting verbs; the #286-amendment; GitLab/Asana.
