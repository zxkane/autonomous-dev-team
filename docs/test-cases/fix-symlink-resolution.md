# Test Cases: Fix Symlink Resolution (#37)

## TC-SYM-001: SCRIPT_DIR resolves through chained symlinks

**Precondition:** `autonomous-dev.sh` is accessed via a symlink chain:
`scripts/autonomous-dev.sh → .claude/skills/.../autonomous-dev.sh → .agents/skills/.../autonomous-dev.sh`

**Steps:**
1. Create a temporary directory structure simulating the symlink chain
2. Source the SCRIPT_DIR resolution line
3. Verify SCRIPT_DIR points to the real script location

**Expected:** SCRIPT_DIR is the absolute path to the real script directory

## TC-SYM-002: SCRIPT_DIR works when invoked directly (no symlink)

**Precondition:** Script is invoked directly, not through a symlink

**Steps:**
1. Run the SCRIPT_DIR resolution on the real script path
2. Verify SCRIPT_DIR resolves correctly

**Expected:** SCRIPT_DIR is the absolute path to the script's directory

## TC-SYM-003: lib-agent.sh _LIB_AGENT_DIR resolves through symlinks

**Precondition:** lib-agent.sh is sourced from a symlinked script

**Steps:**
1. Create a symlink to a test script that sources lib-agent.sh
2. Run the symlinked script
3. Verify _LIB_AGENT_DIR points to the real lib-agent.sh location

**Expected:** _LIB_AGENT_DIR is the absolute path to the real lib-agent.sh directory

## TC-SYM-004: dispatch-local.sh finds autonomous.conf via fallback

**Precondition:** dispatch-local.sh runs from installed skill location where autonomous.conf
does not exist locally, but exists at PROJECT_DIR/scripts/

**Steps:**
1. Create temp project structure with autonomous.conf in scripts/
2. Simulate dispatch-local.sh config loading from a different SCRIPT_DIR
3. Verify autonomous.conf is loaded from the fallback path

**Expected:** Config values from PROJECT_DIR/scripts/autonomous.conf are loaded

## TC-SYM-005: dispatch-local.sh prefers local autonomous.conf over fallback

**Precondition:** autonomous.conf exists in both SCRIPT_DIR and PROJECT_DIR/scripts/

**Steps:**
1. Create both config files with different values
2. Run config loading logic
3. Verify SCRIPT_DIR/autonomous.conf takes precedence

**Expected:** Local config is used, fallback is not loaded
