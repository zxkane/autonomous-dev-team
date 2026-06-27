#!/bin/bash
# tests/unit/fixtures/provider-degraded/itp-degraded.sh
#
# NAMED degraded fake ITP provider (#280, provider-spec.md §8 fake-provider;
# design-spec §7.4 third bullet). EMPTY scaffold — the fake provider exists to
# exercise the caps=0 branches via itp-degraded.caps, not to implement real verb
# leaves. Sourcing it is a no-op (it defines no itp_degraded_<verb> bodies).
#
# The capability-branch test (test-provider-dispatch.sh TC-030) selects this
# provider through the PUBLIC seam — ISSUE_PROVIDER=degraded +
# AUTONOMOUS_PROVIDERS_DIR=<this dir> — and reads the paired itp-degraded.caps
# via itp_caps (the real provider-selection path), NOT by reading the .caps file
# directly. A downstream caps-branch test that wants leaf dispatch live can stub
# the itp_degraded_<verb> leaves it needs here.
:
