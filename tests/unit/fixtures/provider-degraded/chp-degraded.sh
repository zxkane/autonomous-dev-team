#!/bin/bash
# tests/unit/fixtures/provider-degraded/chp-degraded.sh
#
# NAMED degraded fake CHP provider (#280, provider-spec.md §8 fake-provider;
# design-spec §7.4 third bullet). EMPTY scaffold — pairs with chp-degraded.caps.
# Sourcing it is a no-op. The capability-branch test (test-provider-dispatch.sh
# TC-030) selects this provider through the PUBLIC seam — CODE_HOST=degraded +
# AUTONOMOUS_PROVIDERS_DIR=<this dir> — and reads chp-degraded.caps via chp_caps
# (the real provider-selection path), NOT by reading the .caps file directly.
:
