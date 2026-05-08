#!/bin/bash
# 45-no-broadcast-hook.sh — exercises .claude/hooks/no_broadcast_gate.sh
# and the deny/matcher coverage in .claude/settings.json.
# Verifies:
#   - Hook script exists and is executable
#   - Hook always exits 1 (blocking), regardless of stdin payload shape
#   - Stderr message includes "BLOCKED" + diagnostic context
#   - settings.json permissions.deny covers all expected mutating tools
#   - settings.json registers the hook with a matcher covering the same set
#   - prepare_* family remains in the allow surface (NOT denied)
#   - deny list and hook matcher cover the SAME tool set (parity check)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"

echo ""
echo "=== Suite 45: no-broadcast hook ==="

HOOK="$REPO_ROOT/.claude/hooks/no_broadcast_gate.sh"
SETTINGS="$REPO_ROOT/.claude/settings.json"
assert_file_exists "$HOOK" "hook script exists"
assert_file_exists "$SETTINGS" "settings.json exists"

if [[ -x "$HOOK" ]]; then
    _test_pass "hook script is executable"
else
    _test_fail "hook script is not executable"
fi

# The canonical mutating tool surface — keep aligned with the issue body
# and with the deny + matcher in .claude/settings.json.
EXPECTED_DENIED=(
    "mcp__vaultpilot-mcp__send_transaction"
    "mcp__vaultpilot-mcp__submit_safe_tx_signature"
    "mcp__vaultpilot-mcp__sign_btc_multisig_psbt"
    "mcp__vaultpilot-mcp__sign_message_btc"
    "mcp__vaultpilot-mcp__sign_message_ltc"
    "mcp__vaultpilot-mcp__finalize_btc_psbt"
    "mcp__vaultpilot-mcp__import_strategy"
    "mcp__vaultpilot-mcp__share_strategy"
    "mcp__vaultpilot-mcp__import_readonly_token"
    "mcp__vaultpilot-mcp__generate_readonly_link"
)

# Test 1: hook exits 1 with a JSON payload naming a denied tool
set +e
STDERR=$(echo '{"tool_name":"mcp__vaultpilot-mcp__send_transaction"}' | "$HOOK" 2>&1 >/dev/null)
EC=$?
set -e
assert_exit_code 1 "$EC" "hook exits 1 (blocking) with a denied tool payload"
assert_contains "$STDERR" "BLOCKED" "stderr starts with BLOCKED"
assert_contains "$STDERR" "no-broadcast deny list" "stderr names the deny list"
assert_contains "$STDERR" "send_transaction" "stderr surfaces tool_name from payload"

# Test 2: hook exits 1 with empty stdin (older Claude Code versions / test contexts)
set +e
STDERR=$(: | "$HOOK" 2>&1 >/dev/null)
EC=$?
set -e
assert_exit_code 1 "$EC" "hook exits 1 with empty stdin"
assert_contains "$STDERR" "BLOCKED" "stderr still BLOCKED with empty stdin"

# Test 3: hook exits 1 with malformed JSON payload (jq failure shouldn't crash)
set +e
STDERR=$(echo 'not json at all' | "$HOOK" 2>&1 >/dev/null)
EC=$?
set -e
assert_exit_code 1 "$EC" "hook exits 1 with malformed JSON payload"
assert_contains "$STDERR" "BLOCKED" "stderr still BLOCKED with malformed JSON"

# Test 4: stderr names all three layers so the operator can diagnose bypass
assert_contains "$STDERR" "MCP demo mode" "stderr names Layer 1 (demo mode)"
assert_contains "$STDERR" "permissions.deny" "stderr names Layer 2 (deny list)"
assert_contains "$STDERR" "PreToolUse hook" "stderr names Layer 3 (this hook)"

# Test 5: settings.json deny list covers every expected mutating tool
for tool in "${EXPECTED_DENIED[@]}"; do
    if jq -e --arg t "$tool" '.permissions.deny | index($t)' "$SETTINGS" >/dev/null 2>&1; then
        _test_pass "deny list contains $tool"
    else
        _test_fail "deny list missing $tool"
    fi
done

# Test 6: hook is registered as a PreToolUse entry pointing at no_broadcast_gate.sh
HOOK_MATCHER=$(jq -r '
    .hooks.PreToolUse[]?
    | select(.hooks[]?.command == ".claude/hooks/no_broadcast_gate.sh")
    | .matcher
' "$SETTINGS" 2>/dev/null || echo "")
if [[ -n "$HOOK_MATCHER" ]]; then
    _test_pass "no_broadcast_gate.sh registered as PreToolUse hook"
else
    _test_fail "no_broadcast_gate.sh not registered in settings.json hooks"
fi

# Test 7: hook matcher (treated as regex) covers every expected denied tool
if [[ -n "$HOOK_MATCHER" ]]; then
    for tool in "${EXPECTED_DENIED[@]}"; do
        if echo "$tool" | grep -qE "$HOOK_MATCHER"; then
            _test_pass "matcher regex covers $tool"
        else
            _test_fail "matcher regex does not cover $tool (matcher: $HOOK_MATCHER)"
        fi
    done
fi

# Test 8: prepare_* family is NOT in deny list (those are the test surface)
PREPARE_TOOLS=(
    "mcp__vaultpilot-mcp__prepare_token_send"
    "mcp__vaultpilot-mcp__prepare_custom_call"
)
for tool in "${PREPARE_TOOLS[@]}"; do
    if jq -e --arg t "$tool" '.permissions.deny | index($t)' "$SETTINGS" >/dev/null 2>&1; then
        _test_fail "prepare-family tool $tool unexpectedly in deny list (test surface must remain allowed)"
    else
        _test_pass "$tool correctly NOT in deny list"
    fi
done

# Test 9: matcher does NOT match prepare_* tools (no over-matching)
if [[ -n "$HOOK_MATCHER" ]]; then
    for tool in "${PREPARE_TOOLS[@]}"; do
        if echo "$tool" | grep -qE "$HOOK_MATCHER"; then
            _test_fail "matcher regex over-matches $tool (test surface must not fire the gate)"
        else
            _test_pass "matcher correctly does NOT match $tool"
        fi
    done
fi

# Test 10: existing preflight hook on Agent still wired up (no regression)
PREFLIGHT_PRESENT=$(jq -r '
    .hooks.PreToolUse[]?
    | select(.matcher == "Agent" and (.hooks[]?.command == ".claude/hooks/preflight_gate.sh"))
    | .matcher
' "$SETTINGS" 2>/dev/null || echo "")
if [[ "$PREFLIGHT_PRESENT" == "Agent" ]]; then
    _test_pass "Agent → preflight_gate.sh hook still registered"
else
    _test_fail "Agent → preflight_gate.sh hook missing (regression)"
fi

cd "$REPO_ROOT"
echo ""
