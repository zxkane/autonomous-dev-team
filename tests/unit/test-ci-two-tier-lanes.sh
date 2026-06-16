#!/bin/bash
# test-ci-two-tier-lanes.sh — Structural gate-logic assertions for the two-tier
# CI split (issue #238, INV-77).
#
# WHAT IT PINS
# ------------
# `.github/workflows/ci.yml` must encode the two-tier contract:
#   • Tier 1 (hermetic): every job whose name starts with `hermetic` runs on
#     `ubuntu-latest` and references NO credentials — so a fork PR with no
#     secrets gets a fully green, fully meaningful CI.
#   • Tier 2 (live): a `live-smoke` job gated by the `run-live-smoke` label
#     (pull_request labeled) OR push to main, targeting the self-hosted pool,
#     invoking tests/e2e/run-agent-smoke.sh (#222), with NO pull_request_target
#     foot-gun.
# And `setup-labels.sh` must define the `run-live-smoke` gate label so it exists
# on day one.
#
# The structural truth-table assertions use Python + pyyaml (portable, no extra
# binary). CI additionally runs `actionlint` over the workflows for the deeper
# syntax / pull_request_target lint — this test is the always-runnable gate-logic
# half that needs no install.
#
# Run: bash tests/unit/test-ci-two-tier-lanes.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_YML="$PROJECT_ROOT/.github/workflows/ci.yml"
SETUP_LABELS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/setup-labels.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; [[ -n "${2:-}" ]] && echo "      $2"; FAIL=$((FAIL + 1)); }

# assert_py <desc> <python-snippet-printing-OK-or-FAIL:msg>
# The driver below loads ci.yml, exposes the parsed doc as `doc`, the jobs map as
# `jobs`, the trigger block as `on`, and the raw text as `raw`, then exec's the
# caller's snippet which must print `OK` (pass) or `FAIL:<reason>` (failure).
#
# The snippet is passed via the CI_TIERS_PROG env var (NOT heredoc
# interpolation) and the heredoc delimiter is QUOTED, so bash performs no
# expansion on the Python source — a snippet containing `$`, backticks, or `()`
# can never be misparsed as a shell command.
assert_py() {
  local desc="$1" prog="$2" out
  out=$(CI_YML="$CI_YML" CI_TIERS_PROG="$prog" python3 - <<'PYEOF' 2>&1
import os, re, sys
try:
    import yaml
except Exception as e:
    print("FAIL:pyyaml-not-available:%s" % e); sys.exit(0)
path = os.environ["CI_YML"]
with open(path) as f:
    raw = f.read()
try:
    doc = yaml.safe_load(raw)
except Exception as e:
    print("FAIL:yaml-parse-error:%s" % e); sys.exit(0)
jobs = (doc or {}).get("jobs", {}) or {}
# YAML parses the bare key `on` as the boolean True, so the trigger block is
# doc[True]; fall back to the literal 'on' string just in case.
on = doc.get(True, doc.get("on")) if isinstance(doc, dict) else None
# Caller snippets reference doc/jobs/on/raw and the yaml/re modules.
exec(os.environ["CI_TIERS_PROG"], {"yaml": yaml, "re": re, "doc": doc, "jobs": jobs, "on": on, "raw": raw})
PYEOF
)
  if [[ "$out" == OK* ]]; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

echo "=== TC-CI-TIERS-010: ci.yml parses as valid YAML ==="
if [[ -f "$CI_YML" ]]; then
  assert_py "TC-CI-TIERS-010 ci.yml is valid YAML with a jobs map" \
    'print("OK" if isinstance(jobs, dict) and jobs else "FAIL:no-jobs-map")'
else
  fail "TC-CI-TIERS-010 ci.yml exists" "not found at $CI_YML"
fi

echo "=== TC-CI-TIERS-011: hermetic jobs run on ubuntu-latest ==="
assert_py "TC-CI-TIERS-011 at least one hermetic-* job, all on ubuntu-latest" '
herm = {k: v for k, v in jobs.items() if str(k).startswith("hermetic")}
if not herm:
    print("FAIL:no-hermetic-prefixed-job")
else:
    bad = [k for k, v in herm.items() if (v or {}).get("runs-on") != "ubuntu-latest"]
    print("OK" if not bad else "FAIL:hermetic-jobs-not-ubuntu-latest:%s" % bad)
'

echo "=== TC-CI-TIERS-012: hermetic jobs reference no credentials ==="
assert_py "TC-CI-TIERS-012 hermetic-* jobs are credential-free" '
herm = {k: v for k, v in jobs.items() if str(k).startswith("hermetic")}
secret_re = re.compile(r"secrets\.|AWS_ACCESS|AWS_SECRET|BEDROCK|ANTHROPIC_API_KEY|GH_APP_PRIVATE_KEY|RUNNER_TOKEN")
offenders = []
for name, job in herm.items():
    blob = yaml.safe_dump(job)
    if secret_re.search(blob):
        offenders.append(name)
print("OK" if not offenders else "FAIL:credential-ref-in-hermetic:%s" % offenders)
'

echo "=== TC-CI-TIERS-013: live-smoke job exists ==="
assert_py "TC-CI-TIERS-013 live-smoke job present" '
print("OK" if "live-smoke" in jobs else "FAIL:no-live-smoke-job")
'

echo "=== TC-CI-TIERS-014: live-smoke gated by run-live-smoke label ==="
assert_py "TC-CI-TIERS-014 live-smoke.if contains the label gate" '
cond = str((jobs.get("live-smoke") or {}).get("if", ""))
ok = "github.event.label.name" in cond and "run-live-smoke" in cond
print("OK" if ok else "FAIL:label-gate-missing-in-if:%r" % cond)
'

echo "=== TC-CI-TIERS-015: live-smoke gated by push-to-main ==="
assert_py "TC-CI-TIERS-015 live-smoke.if contains the push-to-main gate" '
cond = str((jobs.get("live-smoke") or {}).get("if", ""))
ok = "push" in cond and "refs/heads/main" in cond
print("OK" if ok else "FAIL:push-main-gate-missing-in-if:%r" % cond)
'

echo "=== TC-CI-TIERS-016: no pull_request_target foot-gun ==="
# Assert on the PARSED trigger keys, not the raw text — a comment that explains
# *why we avoid* pull_request_target is legitimate and must not trip the gate.
# The foot-gun is an actual `pull_request_target:` trigger key.
assert_py "TC-CI-TIERS-016 on: block has no pull_request_target trigger" '
keys = list((on or {}).keys()) if isinstance(on, dict) else [on]
print("OK" if "pull_request_target" not in keys else "FAIL:pull_request_target-present:%s" % keys)
'
# Belt-and-suspenders: no UNCOMMENTED `pull_request_target:` line in the source
# (the parsed-key check above already covers the active trigger; this guards
# against it hiding under another mapping). Comment lines (leading #) are
# allowed so the threat-model rationale can name it.
echo "=== TC-CI-TIERS-051: no uncommented pull_request_target line ==="
pr_target_hit=$(grep -nE '^[[:space:]]*pull_request_target[[:space:]]*:' "$CI_YML" || true)
if [[ -n "$pr_target_hit" ]]; then
  fail "TC-CI-TIERS-051 no active pull_request_target: line" "$pr_target_hit"
else
  pass "TC-CI-TIERS-051 no active pull_request_target: line (comments allowed)"
fi

echo "=== TC-CI-TIERS-017: pull_request declares the labeled type ==="
assert_py "TC-CI-TIERS-017 on.pull_request.types contains labeled" '
pr = (on or {}).get("pull_request") if isinstance(on, dict) else None
types = (pr or {}).get("types", []) if isinstance(pr, dict) else []
print("OK" if "labeled" in (types or []) else "FAIL:labeled-type-missing:%s" % types)
'

echo "=== TC-CI-TIERS-018: live-smoke invokes run-agent-smoke.sh ==="
assert_py "TC-CI-TIERS-018 live-smoke runs tests/e2e/run-agent-smoke.sh" '
blob = yaml.safe_dump(jobs.get("live-smoke") or {})
print("OK" if "tests/e2e/run-agent-smoke.sh" in blob else "FAIL:run-agent-smoke-not-invoked")
'

echo "=== TC-CI-TIERS-019: live-smoke is not pinned to ubuntu-latest ==="
assert_py "TC-CI-TIERS-019 live-smoke.runs-on targets self-hosted (not ubuntu-latest)" '
runs_on = str((jobs.get("live-smoke") or {}).get("runs-on", ""))
ok = "ubuntu-latest" not in runs_on and ("self-hosted" in runs_on or "RUNNER_LABEL" in runs_on)
print("OK" if ok else "FAIL:live-smoke-runs-on-unexpected:%r" % runs_on)
'

echo "=== TC-CI-TIERS-020: live-smoke writes a job summary ==="
assert_py "TC-CI-TIERS-020 live-smoke writes SMOKE evidence to GITHUB_STEP_SUMMARY" '
blob = yaml.safe_dump(jobs.get("live-smoke") or {})
print("OK" if "GITHUB_STEP_SUMMARY" in blob else "FAIL:no-step-summary-write")
'

echo "=== TC-CI-TIERS-030: setup-labels.sh defines run-live-smoke ==="
if grep -qE '"run-live-smoke\|[0-9A-Fa-f]{6}\|[^"]+"' "$SETUP_LABELS"; then
  pass "TC-CI-TIERS-030 setup-labels.sh LABELS has run-live-smoke|color|description"
else
  fail "TC-CI-TIERS-030 setup-labels.sh LABELS has run-live-smoke|color|description" \
    "no matching LABELS entry in $SETUP_LABELS"
fi

echo
echo "=================================================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "=================================================="
[[ "$FAIL" -eq 0 ]]
