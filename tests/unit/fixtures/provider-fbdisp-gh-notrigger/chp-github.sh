#!/bin/bash
# tests/unit/fixtures/provider-fbdisp-gh-notrigger/chp-github.sh
#
# A GitHub-named CHP provider fixture that DEFINES chp_github_pr_list (so the
# bot-trigger broker's PR-number read resolves) but DELIBERATELY OMITS
# chp_github_trigger_bot — for #346 TC-FBDISP-004. Selected through the PUBLIC seam
# with CODE_HOST=github (the default) + AUTONOMOUS_PROVIDERS_DIR=<this dir>, so
# `chp_has_leaf trigger_bot` is FALSE while `${CODE_HOST:-github} == "github"` is
# TRUE → the raw `else` `gh-as-user.sh pr comment …` fallback branch is the one
# exercised (proving it fires byte-identically on the github topology when the
# trigger_bot leaf is somehow absent — the lib-load-degraded github case).
#
# chp_github_pr_list mirrors the real leaf (`gh pr list --repo "$REPO" "$@"`) so the
# broker's PR-number read routes through the on-PATH `gh` stub the test provides.
chp_github_pr_list() {
  gh pr list --repo "$REPO" "$@"
}
