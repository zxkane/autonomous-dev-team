#!/bin/bash
# Codex hook installer regression tests for issue #486.
# shellcheck disable=SC2015

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-codex-hooks.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

ok() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

bad() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

assert_file_contains() {
  local desc="$1" file="$2" pattern="$3"
  if [[ -r "$file" ]] && grep -qE "$pattern" "$file"; then
    ok "$desc"
  else
    bad "$desc"
  fi
}

assert_file_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  if [[ -r "$file" ]] && ! grep -qE "$pattern" "$file"; then
    ok "$desc"
  else
    bad "$desc"
  fi
}

assert_backup_exists() {
  local desc="$1" file="$2"
  if compgen -G "${file}.bak.*" >/dev/null; then
    ok "$desc"
  else
    bad "$desc"
  fi
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

new_repo() {
  local name="$1"
  mkdir -p "$TMPDIR/$name"
  git -C "$TMPDIR/$name" init --quiet --initial-branch=main
  printf '%s' "$TMPDIR/$name"
}

install() {
  (
    cd "$1" &&
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$1/install.err" &&
      python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' \
        "$1/.codex/config.toml"
  )
}

echo "=== TC-CDCR-001: fresh install uses canonical features.hooks ==="
repo=$(new_repo fresh)
if install "$repo"; then
  ok "fresh install succeeds"
else
  bad "fresh install succeeds"
fi
hooks_file="$repo/.codex/hooks.json"
config_file="$repo/.codex/config.toml"
[[ -f "$hooks_file" && -f "$config_file" ]] \
  && ok "fresh install creates hooks.json and config.toml" \
  || bad "fresh install creates hooks.json and config.toml"
assert_file_contains "canonical hooks=true is present" "$config_file" \
  '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true'
assert_file_not_contains "deprecated codex_hooks is absent" "$config_file" \
  '^[[:space:]]*codex_hooks[[:space:]]*='

echo "=== TC-CDCR-002: Codex-specific hook rendering ==="
if jq -e '[.hooks.PreToolUse[] | select(.matcher == "^apply_patch$")] | length == 1' \
    "$hooks_file" >/dev/null; then
  ok "one direct apply_patch matcher is generated"
else
  bad "one direct apply_patch matcher is generated"
fi
if jq -e '[.hooks.PreToolUse[] | select(.matcher == "Write" or .matcher == "Edit")] | length == 0' \
    "$hooks_file" >/dev/null; then
  ok "Claude Write/Edit matcher groups are removed"
else
  bad "Claude Write/Edit matcher groups are removed"
fi
assert_file_not_contains "generated commands do not use CLAUDE_PROJECT_DIR" \
  "$hooks_file" 'CLAUDE_PROJECT_DIR'
assert_file_contains "generated commands resolve from git worktree root" \
  "$hooks_file" 'git rev-parse --show-toplevel'
if jq -e '.hooks.PreToolUse | any(.matcher == "Bash")' "$hooks_file" >/dev/null; then
  ok "Bash matcher remains present"
else
  bad "Bash matcher remains present"
fi

echo "=== TC-CDCR-002A: rendered hooks.json is schema-legal for Codex's strict parser (#501) ==="
if [[ "$(jq -c '(keys | sort)' "$hooks_file")" == '["description","hooks"]' ]]; then
  ok "top-level keys are exactly description and hooks"
else
  bad "top-level keys are exactly description and hooks"
fi
assert_file_not_contains "no _managed_by key leaks into hooks.json" "$hooks_file" '"_managed_by"'
assert_file_not_contains "no _managed_note key leaks into hooks.json" "$hooks_file" '"_managed_note"'
if [[ "$(jq -r '.description' "$hooks_file")" == \
      "Managed by skills/autonomous-common/scripts/install-codex-hooks.sh — hand-edits are overwritten on the next install." ]]; then
  ok "description carries the exact provenance string"
else
  bad "description carries the exact provenance string"
fi

echo "=== TC-CDCR-002B: canonical template and a non-Codex installer output are unchanged (#501) ==="
TEMPLATE="$PROJECT_ROOT/skills/autonomous-common/scripts/claude-settings.template.json"
if jq -e 'has("_managed_by") and has("_managed_note")' "$TEMPLATE" >/dev/null; then
  ok "canonical template still carries _managed_by/_managed_note"
else
  bad "canonical template still carries _managed_by/_managed_note"
fi
kiro_repo=$(new_repo kiro_unaffected)
if (
  cd "$kiro_repo" &&
    bash "$PROJECT_ROOT/skills/autonomous-common/scripts/install-kiro-hooks.sh" --no-git-hook >/dev/null 2>&1
); then
  ok "kiro installer still runs"
else
  bad "kiro installer still runs"
fi
if jq -e 'has("_managed_by") and has("_managed_note")' \
    "$kiro_repo/.kiro/agents/default.json" >/dev/null; then
  ok "kiro output still carries the _managed_by/_managed_note markers"
else
  bad "kiro output still carries the _managed_by/_managed_note markers"
fi

echo "=== TC-CDCR-002C: render-time validation fails loudly on an illegal top-level key (#501) ==="
# render_codex_hooks only ever deletes _managed_by/_managed_note; any OTHER
# top-level key the template introduces rides straight through the jq
# transform, so it is the case this validation exists to catch. Run against
# a private copy of the scripts dir (never mutate the shared repo template —
# tests/unit/README.md forbids repo-level shared state across concurrent tests).
scripts_copy="$TMPDIR/scripts-copy-illegal-key"
cp -r "$PROJECT_ROOT/skills/autonomous-common/scripts" "$scripts_copy"
jq '. + {"extra_top_level_key": true}' "$scripts_copy/claude-settings.template.json" \
  > "$scripts_copy/claude-settings.template.json.next"
mv "$scripts_copy/claude-settings.template.json.next" \
  "$scripts_copy/claude-settings.template.json"
repo=$(new_repo illegal_key)
if (
  cd "$repo" &&
    bash "$scripts_copy/install-codex-hooks.sh" --no-git-hook \
      >/dev/null 2>"$repo/install.err"
); then
  bad "render-time validation must refuse an illegal top-level key"
else
  ok "render-time validation refuses an illegal top-level key"
fi
[[ ! -f "$repo/.codex/hooks.json" ]] \
  && ok "illegal-key refusal happens before hooks.json is written" \
  || bad "illegal-key refusal happens before hooks.json is written"
assert_file_contains "illegal-key diagnostic is surfaced" "$repo/install.err" \
  'failed validation'

echo "=== TC-CDCR-003: re-run remains idempotent ==="
install "$repo" || bad "second install succeeds"
canonical_count=$(grep -cE '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true' "$config_file")
apply_patch_count=$(jq '[.hooks.PreToolUse[] | select(.matcher == "^apply_patch$")] | length' "$hooks_file")
[[ "$canonical_count" -eq 1 && "$apply_patch_count" -eq 1 ]] \
  && ok "canonical key and apply_patch group appear once" \
  || bad "canonical key and apply_patch group appear once"

echo "=== TC-CDCR-004: unrelated TOML is preserved ==="
repo=$(new_repo no_features)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
# operator setting
[some_other_section]
foo = "bar"
EOF
install "$repo" || bad "install with unrelated TOML succeeds"
assert_file_contains "unrelated section survives" "$repo/.codex/config.toml" \
  '^\[some_other_section\]$'
assert_file_contains "canonical key is appended" "$repo/.codex/config.toml" \
  '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true'
[[ $(grep -cE '^[[:space:]]*\[features\][[:space:]]*$' "$repo/.codex/config.toml") -eq 1 ]] \
  && ok "one features table is present" || bad "one features table is present"

echo "=== TC-CDCR-005/006: existing features table and canonical true ==="
repo=$(new_repo empty_features)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
# operator comment
[features] # feature flags
some_other_flag = true
EOF
install "$repo" || bad "empty features install succeeds"
assert_file_contains "canonical key is inserted into existing features table" \
  "$repo/.codex/config.toml" '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true'
assert_file_contains "existing feature and comments survive insertion" \
  "$repo/.codex/config.toml" 'some_other_flag[[:space:]]*=[[:space:]]*true'
[[ $(grep -cE '^[[:space:]]*\[[[:space:]]*features[[:space:]]*\]' \
    "$repo/.codex/config.toml") -eq 1 ]] \
  && ok "insertion does not duplicate the features table" \
  || bad "insertion does not duplicate the features table"
assert_backup_exists "features-table insertion creates a backup" \
  "$repo/.codex/config.toml"

repo=$(new_repo canonical_true)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
some_other_flag = true
hooks = true # operator enabled
EOF
install "$repo" || bad "canonical true install succeeds"
assert_file_contains "other feature survives" "$repo/.codex/config.toml" \
  '^[[:space:]]*some_other_flag[[:space:]]*='
[[ $(grep -cE '^[[:space:]]*\[features\][[:space:]]*$' "$repo/.codex/config.toml") -eq 1 ]] \
  && ok "existing features table is not duplicated" \
  || bad "existing features table is not duplicated"
[[ $(grep -cE '^[[:space:]]*hooks[[:space:]]*=' "$repo/.codex/config.toml") -eq 1 ]] \
  && ok "existing canonical key is not duplicated" \
  || bad "existing canonical key is not duplicated"
if compgen -G "$repo/.codex/config.toml.bak.*" >/dev/null; then
  bad "canonical no-op should not create a config backup"
else
  ok "canonical no-op does not create a config backup"
fi

echo "=== TC-CDCR-007: canonical false is preserved and refuses partial install ==="
repo=$(new_repo canonical_false)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
hooks = false
EOF
before=$(cat "$repo/.codex/config.toml")
if install "$repo"; then
  bad "canonical false must refuse"
else
  ok "canonical false refuses"
fi
[[ "$(cat "$repo/.codex/config.toml")" == "$before" ]] \
  && ok "canonical false config is unchanged" \
  || bad "canonical false config is unchanged"
[[ ! -f "$repo/.codex/hooks.json" ]] \
  && ok "refusal happens before hooks.json is written" \
  || bad "refusal happens before hooks.json is written"

echo "=== TC-CDCR-008: legacy true migrates to canonical key ==="
repo=$(new_repo legacy_true)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true # legacy operator config
EOF
install "$repo" || bad "legacy true migration succeeds"
assert_file_contains "legacy true becomes canonical true" "$repo/.codex/config.toml" \
  '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true'
assert_file_not_contains "legacy key is removed after migration" "$repo/.codex/config.toml" \
  '^[[:space:]]*codex_hooks[[:space:]]*='
assert_backup_exists "legacy migration creates a config backup" \
  "$repo/.codex/config.toml"

echo "=== TC-CDCR-008A: unrelated array tables survive migration ==="
repo=$(new_repo legacy_with_array)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true

[[other]]
codex_hooks = "operator-data"
EOF
install "$repo" || bad "legacy migration with unrelated array table succeeds"
if python3 - "$repo/.codex/config.toml" <<'PY'
import sys
import tomllib

config = tomllib.load(open(sys.argv[1], "rb"))
assert config["features"]["hooks"] is True
assert "codex_hooks" not in config["features"]
assert config["other"][0]["codex_hooks"] == "operator-data"
PY
then
  ok "migration does not rewrite keys in unrelated array tables"
else
  bad "migration does not rewrite keys in unrelated array tables"
fi

echo "=== TC-CDCR-008B: unrelated quoted table headers survive migration ==="
repo=$(new_repo legacy_with_quoted_table)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true

["operator#table"]
codex_hooks = "operator-data"
EOF
if install "$repo" &&
   python3 - "$repo/.codex/config.toml" <<'PY'
import sys
import tomllib

config = tomllib.load(open(sys.argv[1], "rb"))
assert config["features"]["hooks"] is True
assert "codex_hooks" not in config["features"]
assert config["operator#table"]["codex_hooks"] == "operator-data"
PY
then
  ok "unrelated quoted table survives canonical migration"
else
  bad "unrelated quoted table survives canonical migration"
fi

echo "=== TC-CDCR-008C: multiline arrays cannot hide a failed migration ==="
repo=$(new_repo legacy_with_multiline_array)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
matrix = [
  [1, 2]
]
codex_hooks = true
EOF
cp "$repo/.codex/config.toml" "$repo/before.toml"
if install "$repo"; then
  bad "unsafe multiline-array migration must refuse"
elif cmp -s "$repo/.codex/config.toml" "$repo/before.toml" &&
     [[ ! -e "$repo/.codex/hooks.json" ]] &&
     grep -q 'could not safely canonicalize' "$repo/install.err"; then
  ok "semantic postcondition refuses a missed multiline-array migration"
else
  bad "semantic postcondition refuses a missed multiline-array migration"
fi

echo "=== TC-CDCR-009: legacy false is preserved ==="
repo=$(new_repo legacy_false)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = false
EOF
before=$(cat "$repo/.codex/config.toml")
if install "$repo"; then bad "legacy false must refuse"; else ok "legacy false refuses"; fi
[[ "$(cat "$repo/.codex/config.toml")" == "$before" ]] \
  && ok "legacy false config is unchanged" \
  || bad "legacy false config is unchanged"

echo "=== TC-CDCR-010: same-value dual keys converge ==="
repo=$(new_repo dual_true)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
hooks = true
codex_hooks = true
EOF
install "$repo" || bad "same-value dual-key migration succeeds"
assert_file_contains "canonical true remains" "$repo/.codex/config.toml" \
  '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true'
assert_file_not_contains "same-value legacy alias is removed" "$repo/.codex/config.toml" \
  '^[[:space:]]*codex_hooks[[:space:]]*='

echo "=== TC-CDCR-011: conflicting dual keys fail loudly ==="
repo=$(new_repo conflict)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
hooks = true
codex_hooks = false
EOF
cp "$repo/.codex/config.toml" "$repo/before.toml"
if install "$repo"; then bad "conflicting keys must refuse"; else ok "conflicting keys refuse"; fi
cmp -s "$repo/.codex/config.toml" "$repo/before.toml" \
  && ok "conflicting config is byte-for-byte unchanged" \
  || bad "conflicting config is byte-for-byte unchanged"
assert_file_contains "conflict diagnostic names both keys" "$repo/install.err" \
  'hooks.*codex_hooks|codex_hooks.*hooks'
assert_file_contains "conflict diagnostic names the operator config path" \
  "$repo/install.err" "$repo/.codex/config.toml"

echo "=== TC-CDCR-012: unsupported mutable feature shape refuses ==="
repo=$(new_repo inline_features)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
features = { another_feature = true }
EOF
cp "$repo/.codex/config.toml" "$repo/before.toml"
if install "$repo"; then bad "mutable inline features table must refuse"; else ok "mutable inline features table refuses"; fi
cmp -s "$repo/.codex/config.toml" "$repo/before.toml" \
  && ok "unsupported TOML is unchanged" \
  || bad "unsupported TOML is unchanged"
[[ ! -f "$repo/.codex/hooks.json" ]] \
  && ok "unsupported TOML refuses before hooks are written" \
  || bad "unsupported TOML refuses before hooks are written"

echo "=== TC-CDCR-013: complex valid TOML is preserved ==="
repo=$(new_repo multiline)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
instructions = """
This literal-looking content is data:
[features]
codex_hooks = false
"""
[other]
"quoted.key" = "preserved"
EOF
cp "$repo/.codex/config.toml" "$repo/before.toml"
install "$repo" || bad "config with multiline string installs"
python3 - "$repo/before.toml" "$repo/.codex/config.toml" <<'PY'
import sys
import tomllib

before = tomllib.load(open(sys.argv[1], "rb"))
after = tomllib.load(open(sys.argv[2], "rb"))
after.pop("features")
raise SystemExit(0 if after == before else 1)
PY
if [[ $? -eq 0 ]]; then
  ok "multiline strings and quoted keys retain their semantic value"
else
  bad "multiline strings and quoted keys retain their semantic value"
fi

echo "=== TC-CDCR-014: noncanonical no-op forms are accepted ==="
for form in quoted dotted; do
  repo=$(new_repo "canonical_$form")
  mkdir -p "$repo/.codex"
  if [[ "$form" == "quoted" ]]; then
    printf '[features]\n"hooks" = true\n' > "$repo/.codex/config.toml"
  else
    printf 'features.hooks = true\n' > "$repo/.codex/config.toml"
  fi
  cp "$repo/.codex/config.toml" "$repo/before.toml"
  if install "$repo" && cmp -s "$repo/.codex/config.toml" "$repo/before.toml"; then
    ok "$form canonical true is accepted without rewriting"
  else
    bad "$form canonical true is accepted without rewriting"
  fi
done

echo "=== TC-CDCR-015: noncanonical legacy migration refuses ==="
for form in quoted dotted; do
  repo=$(new_repo "legacy_$form")
  mkdir -p "$repo/.codex"
  if [[ "$form" == "quoted" ]]; then
    printf '[features]\n"codex_hooks" = true\n' > "$repo/.codex/config.toml"
  else
    printf 'features.codex_hooks = true\n' > "$repo/.codex/config.toml"
  fi
  cp "$repo/.codex/config.toml" "$repo/before.toml"
  if install "$repo"; then
    bad "$form legacy key must refuse unsafe migration"
  elif cmp -s "$repo/.codex/config.toml" "$repo/before.toml"; then
    ok "$form legacy key refuses and remains unchanged"
  else
    bad "$form legacy key refuses and remains unchanged"
  fi
done

echo "=== TC-CDCR-016: invalid or array feature tables refuse ==="
for form in array duplicate_key duplicate_table; do
  repo=$(new_repo "$form")
  mkdir -p "$repo/.codex"
  case "$form" in
    array)
      printf '[[features]]\nhooks = true\n' > "$repo/.codex/config.toml"
      ;;
    duplicate_key)
      printf '[features]\nhooks = true\nhooks = true\n' > "$repo/.codex/config.toml"
      ;;
    duplicate_table)
      printf '[features]\nhooks = true\n[features]\nother = true\n' > "$repo/.codex/config.toml"
      ;;
  esac
  cp "$repo/.codex/config.toml" "$repo/before.toml"
  if install "$repo"; then
    bad "$form must refuse"
  elif cmp -s "$repo/.codex/config.toml" "$repo/before.toml" &&
       [[ ! -f "$repo/.codex/hooks.json" ]]; then
    ok "$form refuses before changing either destination"
  else
    bad "$form refuses before changing either destination"
  fi
done

echo "=== TC-CDCR-017: config failure rolls back the earlier hooks install ==="
repo=$(new_repo rollback)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cp "$repo/.codex/hooks.json" "$repo/hooks.before"
real_mv=$(command -v mv)
real_python=$(command -v python3)
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${FAIL_PLACE_DEST:-}" == "${3:-}" &&
      "${2:-}" == *".pending."* ]]; then
  exit 73
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" FAIL_PLACE_DEST="config.toml" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "simulated config replacement failure must fail"
else
  ok "simulated config replacement failure fails"
fi
if cmp -s "$repo/.codex/config.toml" "$repo/config.before" &&
   cmp -s "$repo/.codex/hooks.json" "$repo/hooks.before"; then
  ok "config and hooks are restored after second-file failure"
else
  bad "config and hooks are restored after second-file failure"
fi

echo "=== TC-CDCR-017B: hooks install before the enabling feature flag ==="
repo=$(new_repo replacement_order)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == *".pending."* &&
      ( "${3:-}" == "$ORDER_HOOKS" || "${3:-}" == "$ORDER_CONFIG" ) ]]; then
  printf '%s\n' "$3" >> "$ORDER_LOG"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" ORDER_LOG="$repo/move-order" \
      ORDER_HOOKS="hooks.json" \
      ORDER_CONFIG="config.toml" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  move_order=()
  while IFS= read -r item; do
    move_order[${#move_order[@]}]="$item"
  done < "$repo/move-order"
  if [[ "${move_order[0]:-}" == "hooks.json" &&
        "${move_order[1]:-}" == "config.toml" ]]; then
    ok "hooks are replaced before config enables them"
  else
    bad "hooks are replaced before config enables them"
  fi
else
  bad "replacement-order fixture installs"
fi

echo "=== TC-CDCR-017A: rollback preserves a concurrent operator edit ==="
repo=$(new_repo rollback_concurrent_edit)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${FAIL_PLACE_DEST:-}" == "${3:-}" &&
      "${2:-}" == *".pending."* ]]; then
  exit 73
fi
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == "$ROLLBACK_RACE_HOOKS" &&
      "${3:-}" == *".rollback-current."* &&
      ! -e "$ROLLBACK_SIGNAL_STATE" ]]; then
  : > "$ROLLBACK_SIGNAL_STATE"
  "$REAL_PYTHON" "$@"
  rc=$?
  printf '\n// operator edit during rollback window\n' >> "$3"
  kill -TERM "$PPID"
  sleep 1
  exit "$rc"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" FAIL_PLACE_DEST="config.toml" \
      ROLLBACK_RACE_HOOKS="hooks.json" \
      ROLLBACK_SIGNAL_STATE="$repo/rollback-signal-fired" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "config failure with concurrent hooks edit must fail"
elif grep -q 'operator edit during rollback window' "$repo/.codex/hooks.json" &&
     grep -q '^codex_hooks = true' "$repo/.codex/config.toml" &&
     [[ -e "$repo/rollback-signal-fired" ]] &&
     grep -q 'refusing to overwrite a concurrent edit' "$repo/install.err" &&
     ! grep -q '"sentinel":true' "$repo/.codex/hooks.json"; then
  ok "rollback refuses to overwrite the concurrent operator edit"
else
  bad "rollback refuses to overwrite the concurrent operator edit"
fi

echo "=== TC-CDCR-018: successful replacement preserves file modes ==="
repo=$(new_repo preserve_modes)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
chmod 0640 "$repo/.codex/config.toml"
chmod 0604 "$repo/.codex/hooks.json"
if (umask 000; install "$repo"); then
  ok "install under permissive umask succeeds"
else
  bad "install under permissive umask succeeds"
fi
[[ "$(file_mode "$repo/.codex/config.toml")" == "640" ]] \
  && ok "config mode is preserved" \
  || bad "config mode is preserved"
[[ "$(file_mode "$repo/.codex/hooks.json")" == "604" ]] \
  && ok "hooks mode is preserved" \
  || bad "hooks mode is preserved"

repo=$(new_repo secure_fresh_modes)
if (umask 000; install "$repo"); then
  ok "fresh install under permissive umask succeeds"
else
  bad "fresh install under permissive umask succeeds"
fi
[[ "$(file_mode "$repo/.codex/config.toml")" == "600" &&
   "$(file_mode "$repo/.codex/hooks.json")" == "600" ]] \
  && ok "fresh generated files remain private under permissive umask" \
  || bad "fresh generated files remain private under permissive umask"
[[ "$(file_mode "$repo/.codex")" == "700" ]] \
  && ok "fresh Codex directory remains private under permissive umask" \
  || bad "fresh Codex directory remains private under permissive umask"
assert_file_not_contains "transaction scratch names are not PID-predictable" \
  "$INSTALLER" 'pending\.\$\$|rollback\.\$\$'

echo "=== TC-CDCR-019: non-regular destinations refuse ==="
repo=$(new_repo config_directory)
mkdir -p "$repo/.codex/config.toml"
if install "$repo"; then
  bad "config directory must refuse"
elif [[ -d "$repo/.codex/config.toml" && ! -e "$repo/.codex/hooks.json" ]]; then
  ok "config directory refuses before writing hooks"
else
  bad "config directory refuses before writing hooks"
fi

repo=$(new_repo symlinked_codex_directory)
mkdir -p "$repo/external-codex"
ln -s "$repo/external-codex" "$repo/.codex"
if install "$repo"; then
  bad "symlinked .codex directory must refuse"
elif [[ -L "$repo/.codex" ]] &&
     [[ -z "$(find "$repo/external-codex" -mindepth 1 -print -quit)" ]]; then
  ok "symlinked .codex directory refuses without writing outside the repo path"
else
  bad "symlinked .codex directory refuses without writing outside the repo path"
fi

repo=$(new_repo hooks_symlink)
mkdir -p "$repo/.codex"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/hooks-target.json"
ln -s "$repo/hooks-target.json" "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
if install "$repo"; then
  bad "hooks symlink must refuse"
elif [[ -L "$repo/.codex/hooks.json" ]] &&
     cmp -s "$repo/.codex/config.toml" "$repo/config.before" &&
     grep -q '"sentinel":true' "$repo/hooks-target.json"; then
  ok "hooks symlink refuses without replacing the link or changing config"
else
  bad "hooks symlink refuses without replacing the link or changing config"
fi

echo "=== TC-CDCR-019A: interruption between replacements rolls back ==="
repo=$(new_repo signal_rollback)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cp "$repo/.codex/hooks.json" "$repo/hooks.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" ]]; then
  printf '%s\n' "${3:-}" >> "$SIGNAL_ORDER"
fi
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${FAIL_SIGNAL_DEST:-}" == "${3:-}" &&
      "${2:-}" == *".pending."* &&
      ! -e "${FAIL_SIGNAL_STATE:-}" ]]; then
  : > "$FAIL_SIGNAL_STATE"
  "$REAL_PYTHON" "$@"
  rc=$?
  kill -TERM "$PPID"
  sleep 1
  exit "$rc"
fi
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${FAIL_SIGNAL_DEST:-}" == "${3:-}" &&
      "${2:-}" == *".rollback."* &&
      ! -e "${FAIL_SIGNAL_SECOND_STATE:-}" ]]; then
  : > "$FAIL_SIGNAL_SECOND_STATE"
  "$REAL_PYTHON" "$@"
  rc=$?
  kill -TERM "$PPID"
  sleep 1
  exit "$rc"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
(
  cd "$repo" &&
    REAL_PYTHON="$real_python" FAIL_SIGNAL_DEST="config.toml" \
      FAIL_SIGNAL_STATE="$repo/signal-fired" \
      FAIL_SIGNAL_SECOND_STATE="$repo/second-signal-fired" \
      SIGNAL_ORDER="$repo/signal-order" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
)
rc=$?
if [[ "$rc" -eq 143 ]]; then
  ok "SIGTERM during the transaction exits 143"
else
  bad "SIGTERM during the transaction exits 143 (rc=$rc)"
fi
if cmp -s "$repo/.codex/config.toml" "$repo/config.before" &&
   cmp -s "$repo/.codex/hooks.json" "$repo/hooks.before"; then
  ok "signal handler restores both destinations"
else
  bad "signal handler restores both destinations"
fi
signal_order=()
while IFS= read -r item; do
  signal_order[${#signal_order[@]}]="$item"
done < <(grep -Fx -e "config.toml" -e "hooks.json" "$repo/signal-order")
signal_count=${#signal_order[@]}
if [[ -e "$repo/second-signal-fired" &&
      "$signal_count" -ge 4 &&
      "${signal_order[signal_count - 2]}" == "config.toml" &&
      "${signal_order[signal_count - 1]}" == "hooks.json" ]]; then
  ok "rollback ignores a repeated signal and restores config before hooks"
else
  bad "rollback ignores a repeated signal and restores config before hooks"
fi
if compgen -G "$repo/.codex/*.pending.*" >/dev/null; then
  bad "signal handler removes pending files"
else
  ok "signal handler removes pending files"
fi

echo "=== TC-CDCR-019D: signal during pending staging cleans up ==="
repo=$(new_repo signal_during_staging)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
cp "$repo/.codex/config.toml" "$repo/config.before"
real_cp=$(command -v cp)
cat > "$repo/fakebin/cp" <<'EOF'
#!/bin/bash
"$REAL_CP" "$@"
rc=$?
destination="${@: -1}"
if [[ "$destination" == *".pending."* &&
      ! -e "${FAIL_SIGNAL_STATE:-}" ]]; then
  : > "$FAIL_SIGNAL_STATE"
  kill -TERM "$PPID"
  sleep 1
fi
exit "$rc"
EOF
chmod +x "$repo/fakebin/cp"
(
  cd "$repo" &&
    REAL_CP="$real_cp" FAIL_SIGNAL_STATE="$repo/signal-fired" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
)
rc=$?
if [[ "$rc" -eq 143 ]] &&
   cmp -s "$repo/.codex/config.toml" "$repo/config.before" &&
   [[ ! -e "$repo/.codex/hooks.json" ]] &&
   ! compgen -G "$repo/.codex/*.pending.*" >/dev/null; then
  ok "early signal preserves destinations and removes pending files"
else
  bad "early signal preserves destinations and removes pending files (rc=$rc)"
fi

echo "=== TC-CDCR-019B: concurrent config edit is not overwritten ==="
repo=$(new_repo concurrent_edit)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
cat > "$repo/fakebin/jq" <<'EOF'
#!/bin/bash
"$REAL_JQ" "$@"
rc=$?
if (( rc == 0 )) &&
   [[ "${@: -1}" == *claude-settings.template.json ]]; then
  printf '\n# concurrent operator edit\n' >> "$RACE_CONFIG"
fi
exit "$rc"
EOF
chmod +x "$repo/fakebin/jq"
real_jq=$(command -v jq)
if (
  cd "$repo" &&
    REAL_JQ="$real_jq" RACE_CONFIG="$repo/.codex/config.toml" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "concurrent edit must refuse installation"
elif grep -q 'concurrent operator edit' "$repo/.codex/config.toml" &&
     grep -q '^codex_hooks = true' "$repo/.codex/config.toml" &&
     [[ ! -e "$repo/.codex/hooks.json" ]]; then
  ok "concurrent edit survives and neither destination is replaced"
else
  bad "concurrent edit survives and neither destination is replaced"
fi

echo "=== TC-CDCR-019C: concurrent mode change is not overwritten ==="
repo=$(new_repo concurrent_mode)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
chmod 0644 "$repo/.codex/config.toml"
cat > "$repo/fakebin/jq" <<'EOF'
#!/bin/bash
"$REAL_JQ" "$@"
rc=$?
if (( rc == 0 )) &&
   [[ "${@: -1}" == *claude-settings.template.json ]]; then
  chmod 0600 "$RACE_CONFIG"
fi
exit "$rc"
EOF
chmod +x "$repo/fakebin/jq"
if (
  cd "$repo" &&
    REAL_JQ="$real_jq" RACE_CONFIG="$repo/.codex/config.toml" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "concurrent mode change must refuse installation"
elif [[ "$(file_mode "$repo/.codex/config.toml")" == "600" ]] &&
     grep -q '^codex_hooks = true' "$repo/.codex/config.toml" &&
     [[ ! -e "$repo/.codex/hooks.json" ]]; then
  ok "concurrent mode change survives and neither destination is replaced"
else
  bad "concurrent mode change survives and neither destination is replaced"
fi

echo "=== TC-CDCR-019E: edit in the final placement window is preserved ==="
repo=$(new_repo final_placement_race)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/hooks.json" "$repo/hooks.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${3:-}" == "$RACE_CONFIG" &&
      "${2:-}" == *".pending."* &&
      ! -e "$RACE_STATE" ]]; then
  : > "$RACE_STATE"
  printf '[features]\ncodex_hooks = true\n# final-window operator edit\n' \
    > "$RACE_CONFIG"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" RACE_CONFIG="config.toml" \
      RACE_STATE="$repo/race-fired" PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "final-window edit must abort installation"
elif grep -q 'final-window operator edit' "$repo/.codex/config.toml" &&
     cmp -s "$repo/.codex/hooks.json" "$repo/hooks.before"; then
  ok "final-window edit survives and the earlier hooks replacement rolls back"
else
  bad "final-window edit survives and the earlier hooks replacement rolls back"
fi

echo "=== TC-CDCR-019F: a losing capture leaves ownership with its winner ==="
repo=$(new_repo capture_loser)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == "$CAPTURE_SOURCE" &&
      "${3:-}" == "$CAPTURE_SOURCE".bak.* ]]; then
  "$REAL_MV" "$2" "$CAPTURE_HELD"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_MV="$real_mv" REAL_PYTHON="$real_python" \
      CAPTURE_SOURCE="hooks.json" \
      CAPTURE_HELD="$repo/concurrent-capture.json" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "losing capture must abort installation"
elif [[ ! -e "$repo/.codex/hooks.json" ]] &&
     grep -q '"sentinel":true' "$repo/concurrent-capture.json" &&
     cmp -s "$repo/.codex/config.toml" "$repo/config.before" &&
     ! compgen -G "$repo/.codex/*.bak.*" >/dev/null; then
  ok "losing capture leaves ownership with the concurrent installer"
else
  bad "losing capture leaves ownership with the concurrent installer"
fi

echo "=== TC-CDCR-019P: capture rejects a concurrent symlink replacement ==="
repo=$(new_repo capture_symlink_replacement)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
printf 'operator target\n' > "$repo/operator-target.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == "$CAPTURE_SOURCE" &&
      "${3:-}" == "$CAPTURE_SOURCE".bak.* &&
      ! -e "$CAPTURE_STATE" ]]; then
  : > "$CAPTURE_STATE"
  "$REAL_MV" "$2" "$OPERATOR_HELD"
  ln -s "$OPERATOR_TARGET" "$2"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_MV="$real_mv" REAL_PYTHON="$real_python" \
      CAPTURE_SOURCE="hooks.json" CAPTURE_STATE="$repo/capture-fired" \
      OPERATOR_HELD="$repo/operator-held-hooks.json" \
      OPERATOR_TARGET="$repo/operator-target.json" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "concurrent symlink replacement must abort installation"
elif [[ -L "$repo/.codex/hooks.json" ]] &&
     [[ "$(readlink "$repo/.codex/hooks.json")" == "$repo/operator-target.json" ]] &&
     grep -q 'operator target' "$repo/operator-target.json" &&
     grep -q '"sentinel":true' "$repo/operator-held-hooks.json" &&
     cmp -s "$repo/.codex/config.toml" "$repo/config.before"; then
  ok "capture rejects and preserves the concurrent symlink replacement"
else
  bad "capture rejects and preserves the concurrent symlink replacement"
fi

echo "=== TC-CDCR-019H: ambiguous capture failure reconciles its postcondition ==="
repo=$(new_repo ambiguous_capture)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == "$CAPTURE_SOURCE" &&
      "${3:-}" == "$CAPTURE_SOURCE".bak.* &&
      ! -e "$CAPTURE_STATE" ]]; then
  : > "$CAPTURE_STATE"
  "$REAL_PYTHON" "$@"
  exit 73
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" CAPTURE_SOURCE="hooks.json" \
      CAPTURE_STATE="$repo/capture-fired" PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
) &&
   grep -q '^hooks = true' "$repo/.codex/config.toml" &&
   ! grep -q '"sentinel":true' "$repo/.codex/hooks.json" &&
   grep -q '"sentinel":true' "$repo"/.codex/hooks.json.bak.*; then
  ok "completed capture is accepted despite an ambiguous helper status"
else
  bad "completed capture is accepted despite an ambiguous helper status"
fi

echo "=== TC-CDCR-019I: capture never treats its backup path as a directory ==="
repo=$(new_repo capture_backup_directory)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == "$CAPTURE_SOURCE" &&
      "${3:-}" == "$CAPTURE_SOURCE".bak.* &&
      ! -e "$CAPTURE_STATE" ]]; then
  : > "$CAPTURE_STATE"
  mkdir "$3"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" CAPTURE_SOURCE="hooks.json" \
      CAPTURE_STATE="$repo/capture-fired" PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "capture backup directory must abort installation"
else
  backup_dir=$(find "$repo/.codex" -maxdepth 1 -type d \
    -name 'hooks.json.bak.*' -print -quit)
  if [[ -n "$backup_dir" ]] &&
     [[ -z "$(find "$backup_dir" -mindepth 1 -print -quit)" ]] &&
     grep -q '"sentinel":true' "$repo/.codex/hooks.json" &&
     cmp -s "$repo/.codex/config.toml" "$repo/config.before"; then
    ok "capture preserves both the canonical file and concurrent directory"
  else
    bad "capture preserves both the canonical file and concurrent directory"
  fi
fi

echo "=== TC-CDCR-019J: rollback capture never targets a concurrent directory ==="
repo=$(new_repo rollback_capture_directory)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == *".pending."* &&
      "${3:-}" == "$FAIL_PLACE_DEST" ]]; then
  exit 73
fi
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == "$ROLLBACK_SOURCE" &&
      "${3:-}" == *".rollback-current."* &&
      ! -e "$ROLLBACK_STATE" ]]; then
  : > "$ROLLBACK_STATE"
  mkdir "$3"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" FAIL_PLACE_DEST="config.toml" \
      ROLLBACK_SOURCE="hooks.json" \
      ROLLBACK_STATE="$repo/rollback-fired" PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "rollback capture directory race must fail installation"
else
  rollback_dir=$(find "$repo/.codex" -maxdepth 1 -type d \
    -name 'hooks.json.rollback-current.*' -print -quit)
  if [[ -n "$rollback_dir" ]] &&
     [[ -z "$(find "$rollback_dir" -mindepth 1 -print -quit)" ]] &&
     [[ -f "$repo/.codex/hooks.json" ]] &&
     cmp -s "$repo/.codex/config.toml" "$repo/config.before"; then
    ok "rollback preserves the canonical file and concurrent directory"
  else
    bad "rollback preserves the canonical file and concurrent directory"
  fi
fi

echo "=== TC-CDCR-019K: capture-time SIGTERM is handled, not discarded ==="
repo=$(new_repo signal_during_capture)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cp "$repo/.codex/hooks.json" "$repo/hooks.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == "$CAPTURE_SOURCE" &&
      "${3:-}" == "$CAPTURE_SOURCE".bak.* &&
      ! -e "$CAPTURE_STATE" ]]; then
  : > "$CAPTURE_STATE"
  "$REAL_PYTHON" "$@"
  rc=$?
  kill -TERM "$PPID"
  sleep 1
  exit "$rc"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
(
  cd "$repo" &&
    REAL_PYTHON="$real_python" CAPTURE_SOURCE="hooks.json" \
      CAPTURE_STATE="$repo/capture-fired" PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
)
rc=$?
if [[ "$rc" -eq 143 ]] &&
   cmp -s "$repo/.codex/config.toml" "$repo/config.before" &&
   cmp -s "$repo/.codex/hooks.json" "$repo/hooks.before"; then
  ok "capture-time SIGTERM exits 143 and restores both destinations"
else
  bad "capture-time SIGTERM exits 143 and restores both destinations (rc=$rc)"
fi

echo "=== TC-CDCR-019L: a concurrent directory is never used as a move target ==="
repo=$(new_repo final_directory_race)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${3:-}" == "$RACE_HOOKS" &&
      "${2:-}" == *".pending."* &&
      ! -e "$RACE_STATE" ]]; then
  : > "$RACE_STATE"
  mkdir "$RACE_HOOKS"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" RACE_HOOKS="hooks.json" \
      RACE_STATE="$repo/race-fired" PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "concurrent directory must abort installation"
elif [[ -d "$repo/.codex/hooks.json" ]] &&
     [[ -z "$(find "$repo/.codex/hooks.json" -mindepth 1 -print -quit)" ]] &&
     cmp -s "$repo/.codex/config.toml" "$repo/config.before"; then
  ok "concurrent directory stays empty and config remains unchanged"
else
  bad "concurrent directory stays empty and config remains unchanged"
fi

echo "=== TC-CDCR-019M: parent-directory swap cannot redirect writes ==="
repo=$(new_repo parent_directory_swap)
mkdir -p "$repo/.codex" "$repo/external-codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cp "$repo/.codex/hooks.json" "$repo/hooks.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == *".pending."* &&
      "${3:-}" == "config.toml" &&
      ! -e "$SWAP_STATE" ]]; then
  : > "$SWAP_STATE"
  "$REAL_PYTHON" "$@"
  rc=$?
  "$REAL_MV" "$PROJECT_CODEX" "$HELD_CODEX"
  ln -s "$EXTERNAL_CODEX" "$PROJECT_CODEX"
  exit "$rc"
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" REAL_MV="$real_mv" \
      PROJECT_CODEX="$repo/.codex" HELD_CODEX="$repo/held-codex" \
      EXTERNAL_CODEX="$repo/external-codex" SWAP_STATE="$repo/swap-fired" \
      PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "parent-directory swap must abort installation"
elif [[ -L "$repo/.codex" ]] &&
     cmp -s "$repo/held-codex/config.toml" "$repo/config.before" &&
     cmp -s "$repo/held-codex/hooks.json" "$repo/hooks.before" &&
     [[ -z "$(find "$repo/external-codex" -mindepth 1 -print -quit)" ]]; then
  ok "anchored rollback restores the original directory without external writes"
else
  bad "anchored rollback restores the original directory without external writes"
fi

echo "=== TC-CDCR-019N: rollback never claims an unowned scratch object ==="
repo=$(new_repo rollback_scratch_ownership)
mkdir -p "$repo/.codex" "$repo/fakebin"
cat > "$repo/.codex/config.toml" <<'EOF'
[features]
codex_hooks = true
EOF
printf '{"sentinel":true}\n' > "$repo/.codex/hooks.json"
cp "$repo/.codex/config.toml" "$repo/config.before"
cat > "$repo/fakebin/python3" <<'EOF'
#!/bin/bash
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == *".pending."* &&
      "${3:-}" == "config.toml" ]]; then
  exit 73
fi
if [[ "${CODEX_ATOMIC_PLACE:-}" == "1" &&
      "${2:-}" == "hooks.json" &&
      "${3:-}" == *".rollback-current."* &&
      ! -e "$OWNERSHIP_STATE" ]]; then
  : > "$OWNERSHIP_STATE"
  "$REAL_MV" "$2" "$OPERATOR_HELD"
  printf 'operator-owned scratch\n' > "$3"
  exit 73
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$repo/fakebin/python3"
if (
  cd "$repo" &&
    REAL_PYTHON="$real_python" REAL_MV="$real_mv" \
      OPERATOR_HELD="$repo/operator-held-hooks.json" \
      OWNERSHIP_STATE="$repo/ownership-fired" PATH="$repo/fakebin:$PATH" \
      bash "$INSTALLER" --no-git-hook >/dev/null 2>"$repo/install.err"
); then
  bad "unowned rollback scratch race must fail installation"
else
  scratch_file=$(find "$repo/.codex" -maxdepth 1 -type f \
    -name 'hooks.json.rollback-current.*' -print -quit)
  if [[ ! -e "$repo/.codex/hooks.json" ]] &&
     [[ -n "$scratch_file" ]] &&
     grep -q 'operator-owned scratch' "$scratch_file" &&
     [[ -f "$repo/operator-held-hooks.json" ]] &&
     cmp -s "$repo/.codex/config.toml" "$repo/config.before"; then
    ok "rollback preserves both unowned objects without moving either one"
  else
    bad "rollback preserves both unowned objects without moving either one"
  fi
fi

echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
