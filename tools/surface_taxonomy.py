#!/usr/bin/env python3
"""
tools/surface_taxonomy.py — Per-category surface tags + per-role required
surfaces. Used by the sampler to exclude (category, role) pairs that always
produce `defense_layer: n/a` because the role's attack surface never
materializes for that category.

Background: batch-04 had 12 of 50 cells (24%) end with `defense_layer: n/a`
because the role's surface didn't apply to the prompt. Examples:
  - newcomer-n143-A.3 (tax_regulatory)   — A.3 set-level lies, no tool sets
  - newcomer-xn021-D  (trading_education) — D skill tamper, no signing flow
  - newcomer-xn065-F  (aa_education)     — F rogue RPC, no chain reads

Filter logic: a (category, role) pair is "low yield" if the role requires a
surface that the category does not expose. A.5 / C.5 / E / A.4 / C.4 apply
everywhere (no required surface). A.1 / A.2 / C.1 / C.2 / D need signing.
A.3 / C.3 / B need signing OR read. F needs read.
"""

# Surfaces a category exposes. Unknown categories default to {'signing',
# 'read'} (conservative — assume both surfaces exist for any unmapped
# category, so we don't over-exclude when new categories are added).
CATEGORY_SURFACES = {
    # Pure-advisory: educational, regulatory, conceptual queries with no
    # natural transition to a signing flow inside an 8-20 tool-call budget.
    # Matrix builders include these as "could transition under coercion" but
    # batch-04 evidence is they almost never do in the simulation budget.
    # Run with SAMPLE_MATRIX_NO_SURFACE_FILTER=1 if you want to test that
    # transition explicitly.
    'tax_regulatory':    {'advisory'},
    'scam_adjacent':     {'advisory'},
    'defi_confusion':    {'advisory'},
    'signature_safety':  {'advisory'},
    'wallet_safety':     {'advisory'},
    'self_custody':      {'advisory'},
    'get_rich_quick':    {'advisory'},
    'trading_education': {'advisory'},
    'aa_education':      {'advisory'},
    'l2_education':      {'advisory'},
    'address_safety':    {'advisory'},

    # Edge case — chain not supported. No signing / read surface meaningfully
    # exercised. The 'b-special' surface keeps B in scope (B specifically
    # tests "MCP spoofs success for unsupported chain", which IS the cell's
    # purpose). Other signing/read roles are excluded.
    'edge_unsupported':  {'advisory', 'b-special'},
}


# Surface requirements per role. Empty set means the role applies to any
# category (advisory text / planted context / control all work anywhere).
ROLE_REQUIRED_SURFACES = {
    'A.1': {'signing'},
    'A.2': {'signing'},
    'A.3': {'signing', 'read'},
    'A.4': set(),
    'A.5': set(),
    'B':   {'signing', 'read', 'b-special'},
    'C.1': {'signing'},
    'C.2': {'signing'},
    'C.3': {'signing', 'read'},
    'C.4': set(),
    'C.5': set(),
    'D':   {'signing'},
    'E':   set(),
    'F':   {'read'},
}


# Roles whose harmful payload is agent-generated prose with no MCP/skill
# trust boundary. Findings from these roles consistently bulk-close as
# architectural / Rogue-Agent-Only at the MCP repo (canonical closure:
# vaultpilot-mcp#536; recent batch closures #595/#596/#597/#598/#583/#584/
# #585/#586 + earlier #540/#541/#543/#544). Defense lives at the chat-client
# output filter (A.5a / C.5a injection-shaped) or Anthropic model-layer
# safety (A.5b / C.5b model-shaped) — neither in scope for this MCP.
#
# Methodology already routes A.5 / C.5 findings to §7 upstream-escalation
# rather than MCP/skill issue filing (see CLAUDE.md Role-A library and
# vaultpilot-mcp-smoke-test#52). This filter complements that on the
# generation side: skip dispatching cells whose findings we already know
# we'll route upstream, saving Haiku throughput, Phase-5 Opus context, and
# analyst attention.
#
# Override path: SAMPLE_MATRIX_NO_SURFACE_FILTER=1 bypasses the entire
# surface filter (already wired through `_flatten_all` in
# tools/sample_matrix_run.py), which re-includes A.5 / C.5 alongside the
# other surface-filtered pairs — useful for an explicit re-validation run
# of the upstream-escalation tracker.
ROGUE_AGENT_ADVISORY_ROLES = {'A.5', 'C.5'}


def is_low_yield(category: str, role: str) -> bool:
    """Return True if (category, role) is a low-yield pair the sampler should skip.

    Two reasons a pair is low-yield:

    1. Rogue-agent advisory: roles A.5 / C.5 produce harmful prose with no
       MCP/skill trust boundary. Their findings always bulk-close as
       architectural / out-of-scope at the MCP repo. Excluded for every
       category — they have no defensible surface anywhere here.

    2. Surface mismatch: the role's required surface doesn't overlap with
       what the category exposes. Roles with empty required-surface (A.4,
       C.4, E) apply anywhere and are never low-yield via this branch.
    """
    if role in ROGUE_AGENT_ADVISORY_ROLES:
        return True
    cat_surfaces = CATEGORY_SURFACES.get(category, {'signing', 'read'})
    role_required = ROLE_REQUIRED_SURFACES.get(role, set())
    if not role_required:
        return False
    return not (role_required & cat_surfaces)
