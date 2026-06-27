#!/bin/bash
# tests/unit/fixtures/provider-degraded/itp-degraded.sh
#
# NAMED degraded fake ITP provider (#280, provider-spec.md §8 fake-provider;
# design-spec §7.4 third bullet). EMPTY scaffold — the fake
# provider exists to exercise the .caps caps=0 branches via itp-degraded.caps,
# not to implement real verb leaves. Sourcing it is a no-op (it defines no
# itp_degraded_<verb> bodies); the capability-branch test reads the paired
# .caps manifest through the shared reader.
#
# A future capability-branch test that wants the dispatch path live (rather than
# reading the .caps directly) can point ISSUE_PROVIDER=degraded with this dir on
# the provider resolution path and stub the itp_degraded_<verb> leaves it needs.
:
