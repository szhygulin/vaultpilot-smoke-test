#!/bin/bash
# .claude/hooks/no_broadcast_gate.sh — PreToolUse hook for the mutating
# vaultpilot-mcp tool surface (Layer 3 of the no-broadcast defense).
#
# Smoke-test runs MUST never broadcast on-chain or persist mutating local
# state on the operator's box. This hook is the third independent layer
# enforcing that rule:
#
#   Layer 1: MCP demo mode (VAULTPILOT_DEMO=true + set_demo_wallet)
#   Layer 2: permissions.deny in .claude/settings.json
#   Layer 3: this PreToolUse hook (regex matcher in settings.json)
#
# All three layers are load-bearing. Weakening any one is a security
# regression — see the "No-broadcast hard gate" section in CLAUDE.md.
#
# This hook always exits 1 (blocking) when invoked. The matcher in
# .claude/settings.json is the source of truth for which tools trigger
# this hook; the script's job is to refuse + surface a clear message
# so the operator can diagnose how Layers 1+2 were bypassed.
#
# Why a hook in addition to permissions.deny:
#   - Defense in depth against compound-command bypass shapes the SDK
#     gate may not anticipate.
#   - Surfaces a structured diagnostic when reached, vs. permissions.deny
#     which silently auto-denies.
#   - Survives accidental allow-list regressions that shadow the deny.
#
# Inputs: PreToolUse hooks may receive a JSON payload on stdin describing
# the tool call. The script reads it best-effort to surface the tool name
# in the diagnostic; the matcher in settings.json is the actual gate.
#
# Exit codes:
#   1 — always (this hook only runs for tools that should be blocked).

set -uo pipefail

# Best-effort: read stdin payload and extract tool_name for diagnostics.
# Older Claude Code versions may not pipe anything; jq may be absent.
payload=""
if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null || true)
fi
tool_name=""
if [[ -n "$payload" ]] && command -v jq >/dev/null 2>&1; then
    tool_name=$(echo "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
fi

cat >&2 <<EOF
BLOCKED by .claude/hooks/no_broadcast_gate.sh:
  tool ${tool_name:-<mutating vaultpilot-mcp tool>} is on the no-broadcast deny list.

Smoke-test runs MUST never broadcast on-chain or persist mutating local
state. The mutating tool surface (send_transaction, submit_*, sign_*,
finalize_*, import_*, share_*, generate_readonly_link) is blocked by
three independent layers:
  1. MCP demo mode (VAULTPILOT_DEMO=true + set_demo_wallet)
  2. permissions.deny in .claude/settings.json
  3. This PreToolUse hook (belt-and-suspenders)

If you reached this hook, Layers 1+2 either failed to engage or were
bypassed by a compound-command shape. Halt the run and inspect:
  - VAULTPILOT_DEMO env var on the vaultpilot-mcp server
  - get_demo_wallet probe returns active demo persona
  - .claude/settings.json deny list still names this tool
  - No stray allow entry shadows the deny

To intentionally weaken (e.g. testing the gate itself): document the
weakening in the PR description per CLAUDE.md "No-broadcast hard gate".
EOF
exit 1
