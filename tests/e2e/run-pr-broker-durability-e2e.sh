#!/bin/bash
# Hermetic wrapper E2E for issue #519 (TC-PRBROKER-040): a clean agent exit
# whose GH_WRAPPER_DIR (auth dir) is deleted mid-cleanup — BEFORE the broker
# drain — must still produce exactly one PR (durable request consumed) and
# route the issue to pending-review, consuming no extra dev retry.
#
# Exercises the REAL drain_agent_pr_create + provision_agent_pr_create_file
# from lib-auth.sh against a git fixture and a gh stub; the label routing is
# asserted through the same PR_EXISTS + transition seam shape the wrapper
# uses (a full wrapper run needs live auth; the drain-then-lookup-then-flip
# sequence here mirrors cleanup()'s exact ordering).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

PASS=0
FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- sandbox: lib-auth + CHP seam + stub siblings --------------------------
SBA="$WORK/sandbox"; mkdir -p "$SBA/providers"
cp "$SCRIPTS/lib-auth.sh" "$SBA/"
cp "$SCRIPTS/gh-with-token-refresh.sh" "$SBA/"; chmod +x "$SBA/gh-with-token-refresh.sh"
cp "$SCRIPTS/lib-code-host.sh" "$SBA/"
cp "$SCRIPTS/providers/chp-github.sh" "$SBA/providers/"
cp "$SCRIPTS/providers/chp-github.caps" "$SBA/providers/" 2>/dev/null || true
printf '#!/bin/bash\nload_autonomous_conf() { return 0; }\n' > "$SBA/lib-config.sh"
printf '#!/bin/bash\nget_gh_app_token() { echo T; }\nget_gh_app_scoped_token() { echo T; }\n' > "$SBA/gh-app-token.sh"

# --- gh stub: list empty until a create is recorded, then one PR -----------
GHSB="$WORK/gh-stub"; mkdir -p "$GHSB"
CREATE_LOG="$GHSB/create.log"
cat > "$GHSB/gh" <<GHSTUB
#!/bin/bash
if [[ "\$1" == "api" && "\$2" == "graphql" ]]; then
  if [[ -s "$CREATE_LOG" ]]; then
    printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"body":"Closes #519"}]}}}}'
  else
    printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}'
  fi
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then echo "CREATED \$*" >> "$CREATE_LOG"; exit 0; fi
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  if [[ -s "$CREATE_LOG" ]]; then echo '[{"body":"Closes #519"}]'; else echo '[]'; fi
  exit 0
fi
exit 0
GHSTUB
chmod +x "$GHSB/gh"

# --- git fixture: origin with main + one pushed issue branch ---------------
git init -q --bare "$WORK/origin.git"
git init -q "$WORK/clone"
(
  cd "$WORK/clone"
  git config user.email t@example.com; git config user.name t
  git remote add origin "$WORK/origin.git"
  echo base > f; git add f; git commit -qm c1
  git branch -M main
  git push -q origin main
  git checkout -qb feat/issue-519-fix
  echo fix >> f; git add f; git commit -qm fix
  git push -q origin feat/issue-519-fix
  git checkout -q main
)

# --- the run: provision durable file, agent writes request, auth dir dies,
# --- cleanup drains, PR_EXISTS lookup, label flip --------------------------
RUN_DIR="$WORK/run-artifacts"; mkdir -p "$RUN_DIR"
FINAL_LABELS="$WORK/labels.out"

(
  cd "$WORK/clone"
  PATH="$GHSB:$PATH" REPO="owner/repo" BASE_BRANCH="main" RUN_DIR="$RUN_DIR" \
  bash -c '
    set -uo pipefail
    source "'"$SBA"'/lib-auth.sh"

    # Wrapper startup shape: auth dir + durable request provisioning.
    GH_WRAPPER_DIR=$(mktemp -d /tmp/agent-auth-e2e519-XXXXXX)
    AGENT_GH_TOKEN_FILE="${GH_WRAPPER_DIR}/agent-token"
    echo tok > "$AGENT_GH_TOKEN_FILE"
    provision_agent_pr_create_file 519

    # Agent phase: writes the brokered request (clean exit follows).
    printf "branch: feat/issue-519-fix\nfix: broker durability\nBody.\nCloses #519\n" > "$AGENT_PR_CREATE_FILE"

    # Mid-cleanup incident: the auth dir vanishes BEFORE the drain.
    rm -rf "$GH_WRAPPER_DIR"

    # cleanup() sequence: drain → PR_EXISTS lookup → label flip.
    drain_agent_pr_create 519 owner/repo "fix: broker durability"

    pr_count=$(gh pr list 2>/dev/null | jq "length" 2>/dev/null || echo 0)
    if [[ "$pr_count" -gt 0 ]]; then
      echo "pending-review" > "'"$FINAL_LABELS"'"
    else
      echo "pending-dev" > "'"$FINAL_LABELS"'"
    fi
  '
)

echo "=== TC-PRBROKER-040 assertions ==="
if [[ -s "$CREATE_LOG" && $(grep -c CREATED "$CREATE_LOG") -eq 1 ]]; then
  ok "exactly one PR created despite vanished auth dir"
else
  bad "create log: $(cat "$CREATE_LOG" 2>/dev/null || echo empty)"
fi
if grep -qF -- '--head feat/issue-519-fix' "$CREATE_LOG" 2>/dev/null; then
  ok "created from the agent's pushed branch (durable request consumed)"
else
  bad "wrong head: $(cat "$CREATE_LOG" 2>/dev/null)"
fi
if [[ "$(cat "$FINAL_LABELS" 2>/dev/null)" == "pending-review" ]]; then
  ok "run routes to pending-review (no extra dev retry consumed)"
else
  bad "routed to: $(cat "$FINAL_LABELS" 2>/dev/null || echo unknown)"
fi
if [[ -f "$RUN_DIR/agent-pr-create" ]]; then
  ok "durable request artifact retained in RUN_DIR after drain"
else
  bad "request artifact missing from RUN_DIR"
fi

echo ""
echo "PR-BROKER-E2E-SUMMARY pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]]
