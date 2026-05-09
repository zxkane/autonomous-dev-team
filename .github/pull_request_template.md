## Summary

<!-- 1-3 bullets describing what changed and why. -->

## Pipeline Docs (CONTRIBUTING.md Rule 1)

- [ ] If this PR touches a watched path (any `skills/autonomous-*/scripts/*.sh`, `skills/autonomous-common/hooks/*.sh`, or `skills/autonomous-*/SKILL.md` — see [CONTRIBUTING.md](CONTRIBUTING.md#what-pipeline-behavior-means) for the full list), I have updated `docs/pipeline/` to match the new behavior — OR I have applied the `pipeline-docs:none` label with rationale below.

<!-- If pipeline-docs:none is applied, briefly explain why the change has no observable pipeline behavior. -->

## Test Plan

<!-- How was this verified? -->

- [ ] Local checks pass (shellcheck if scripts changed, `bash -n` minimum)
- [ ] CI checks pass

## Linked Issues

<!-- Closes #N / Fixes #N -->
