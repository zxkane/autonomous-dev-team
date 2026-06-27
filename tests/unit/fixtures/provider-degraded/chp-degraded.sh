#!/bin/bash
# tests/unit/fixtures/provider-degraded/chp-degraded.sh
#
# NAMED degraded fake CHP provider (#280, provider-spec.md §8 fake-provider;
# design-spec §7.4 third bullet). EMPTY scaffold — pairs
# with chp-degraded.caps. Sourcing it is a no-op; the capability-branch test
# reads the paired .caps manifest through the shared reader.
:
