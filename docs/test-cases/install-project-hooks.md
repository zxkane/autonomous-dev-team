# Test cases: `install-project-hooks.sh`

Closes #153.

## TC-IPH-01 — clean install symlinks every dispatcher script

**Setup**: empty git repo, fixture skills tree at
`<repo>/.agents/skills/autonomous-{dispatcher,common}/`. Dispatcher
scripts dir contains `lib-agent.sh`, `lib-auth.sh`,
`autonomous-dev.sh`, `autonomous-review.sh`.

**Run**: `bash install-project-hooks.sh --no-git-hook`

**Expect**:
- `<repo>/scripts/lib-agent.sh` is a symlink → dispatcher's `lib-agent.sh`
- Same for `lib-auth.sh`, `autonomous-dev.sh`, `autonomous-review.sh`
- `<repo>/hooks` is a symlink → autonomous-common's `hooks/`
- Exit code 0

## TC-IPH-02 — does not overwrite project-local files

**Setup**: as TC-IPH-01, plus a real (non-symlink)
`<repo>/scripts/autonomous.conf` and a real `<repo>/scripts/deploy.sh`.

**Run**: `bash install-project-hooks.sh --no-git-hook`

**Expect**:
- `autonomous.conf` is still a real file (not a symlink), unchanged.
- `deploy.sh` is still a real file, unchanged.
- The dispatcher `*.sh` files are still symlinked.

## TC-IPH-03 — re-run picks up newly-added upstream file

**Setup**: as TC-IPH-01. After first run, **add** a new file
`<dispatcher-scripts>/lib-review-verdict.sh`. Re-run the script.

**Expect**:
- `<repo>/scripts/lib-review-verdict.sh` is now a symlink → the new file.
- Existing symlinks are not duplicated or churned.

## TC-IPH-04 — re-run prunes a dangling symlink for a removed upstream file

**Setup**: as TC-IPH-01. After first run, **remove**
`<dispatcher-scripts>/lib-auth.sh`. Re-run the script.

**Expect**:
- `<repo>/scripts/lib-auth.sh` is removed (was a dangling symlink).
- Other symlinks remain intact.
- Stderr surfaces a `Pruned dangling symlink:` line.

## TC-IPH-05 — bash -n syntax check

`bash -n install-project-hooks.sh` returns 0.

## TC-IPH-06 — abort with clear error if dispatcher skill not installed

**Setup**: empty git repo with NO skills installed (no
`.agents/skills/` etc.).

**Run**: `bash install-project-hooks.sh --no-git-hook`

**Expect**:
- Exit code != 0.
- Stderr contains "autonomous-dispatcher" and "npx skills add" guidance.

## TC-IPH-07 — git pre-push hook installed by default

**Setup**: clean git repo with skills tree.

**Run**: `bash install-project-hooks.sh` (no flag)

**Expect**:
- `.git/hooks/pre-push` exists and is executable.

## TC-IPH-08 — `--no-git-hook` suppresses pre-push

**Setup**: clean git repo with skills tree.

**Run**: `bash install-project-hooks.sh --no-git-hook`

**Expect**:
- `.git/hooks/pre-push` does not exist.

## Integration: bash -n the wrapper after install

After running the installer, `bash -n
<repo>/scripts/autonomous-review.sh` succeeds. (Indirectly verifies
that all `source`d libs resolve.)

## Acceptance

All eight tests pass + integration check. CI shellcheck clean on the new
script.
