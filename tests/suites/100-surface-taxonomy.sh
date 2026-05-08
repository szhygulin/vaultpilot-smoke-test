#!/bin/bash
# 100-surface-taxonomy.sh — exercises tools/surface_taxonomy.py.
# Verifies:
#   - Pure-advisory categories exclude signing-flow roles
#   - Surface-agnostic roles (A.4, A.5, C.4, C.5, E) apply everywhere
#   - Unknown categories default to {signing, read} (conservative)
#   - edge_unsupported keeps B (special case) but excludes other signing roles
#   - Batch-04's known-wasted cells are now caught

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"

echo ""
echo "=== Suite 100: surface-taxonomy ==="

# Helper — runs is_low_yield(cat, role) and prints "yes"/"no"
_check() {
    local cat="$1" role="$2"
    python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/tools')
from surface_taxonomy import is_low_yield
print('yes' if is_low_yield('$cat', '$role') else 'no')
"
}

# Test 1: pure-advisory categories exclude signing-flow roles
assert_equals "yes" "$(_check tax_regulatory A.1)" "tax_regulatory excludes A.1 (signing)"
assert_equals "yes" "$(_check tax_regulatory A.2)" "tax_regulatory excludes A.2 (signing)"
assert_equals "yes" "$(_check tax_regulatory A.3)" "tax_regulatory excludes A.3 (set-level)"
assert_equals "yes" "$(_check tax_regulatory B)"   "tax_regulatory excludes B (rogue MCP)"
assert_equals "yes" "$(_check tax_regulatory C.1)" "tax_regulatory excludes C.1 (collude bytes)"
assert_equals "yes" "$(_check tax_regulatory D)"   "tax_regulatory excludes D (skill-tamper)"
assert_equals "yes" "$(_check tax_regulatory F)"   "tax_regulatory excludes F (rogue RPC)"

# Test 2: surface-agnostic roles always kept (A.4, C.4, E)
# A.5 / C.5 are explicitly excluded everywhere — see ROGUE_AGENT_ADVISORY_ROLES
# in surface_taxonomy.py. Their findings always bulk-close as architectural
# at the MCP repo (canonical: vaultpilot-mcp#536); excluding them at
# generation time saves Haiku throughput + Phase-5 Opus context.
assert_equals "no" "$(_check tax_regulatory A.4)"  "tax_regulatory keeps A.4 (planted context)"
assert_equals "no" "$(_check tax_regulatory C.4)"  "tax_regulatory keeps C.4 (collude context)"
assert_equals "no" "$(_check tax_regulatory E)"    "tax_regulatory keeps E (control)"

# Test 2b: A.5 / C.5 (rogue-agent advisory) excluded everywhere
assert_equals "yes" "$(_check tax_regulatory A.5)"     "tax_regulatory excludes A.5 (rogue-agent advisory)"
assert_equals "yes" "$(_check tax_regulatory C.5)"     "tax_regulatory excludes C.5 (rogue-agent advisory)"
assert_equals "yes" "$(_check send_native A.5)"        "send_native excludes A.5 (rogue-agent advisory)"
assert_equals "yes" "$(_check send_native C.5)"        "send_native excludes C.5 (rogue-agent advisory)"
assert_equals "yes" "$(_check edge_unsupported A.5)"   "edge_unsupported excludes A.5 (rogue-agent advisory)"
assert_equals "yes" "$(_check brand_new_category A.5)" "unknown category excludes A.5 (rogue-agent advisory)"

# Test 3: unknown category defaults to {signing, read} (kept by default)
assert_equals "no" "$(_check brand_new_category A.1)" "unknown category keeps A.1 (default conservative)"
assert_equals "no" "$(_check brand_new_category B)"   "unknown category keeps B (default conservative)"
assert_equals "no" "$(_check brand_new_category F)"   "unknown category keeps F (default conservative)"

# Test 4: signing categories keep all roles
assert_equals "no" "$(_check send_native A.1)" "send_native keeps A.1"
assert_equals "no" "$(_check swap_cross D)"    "swap_cross keeps D"

# Test 5: edge_unsupported special-case (only B + non-advisory surface-agnostic roles kept)
# A.5 / C.5 are now globally excluded (Test 2b); edge_unsupported still keeps B
# (the cell's purpose is "MCP spoofs success on unsupported chain") and the
# remaining surface-agnostic roles (A.4, C.4, E).
assert_equals "no"  "$(_check edge_unsupported B)"   "edge_unsupported keeps B (b-special)"
assert_equals "no"  "$(_check edge_unsupported A.4)" "edge_unsupported keeps A.4 (planted context)"
assert_equals "no"  "$(_check edge_unsupported E)"   "edge_unsupported keeps E (control)"
assert_equals "yes" "$(_check edge_unsupported A.1)" "edge_unsupported excludes A.1"
assert_equals "yes" "$(_check edge_unsupported D)"   "edge_unsupported excludes D"
assert_equals "yes" "$(_check edge_unsupported F)"   "edge_unsupported excludes F"

# Test 6: batch-04's known-wasted cells (regression — these motivated the filter)
assert_equals "yes" "$(_check edge_unsupported A.2)"      "batch-04 wasted: A.2 on edge_unsupported"
assert_equals "yes" "$(_check trading_education C.1)"     "batch-04 wasted: C.1 on trading_education"
assert_equals "yes" "$(_check trading_education D)"       "batch-04 wasted: D on trading_education"
assert_equals "yes" "$(_check aa_education A.1)"          "batch-04 wasted: A.1 on aa_education"
assert_equals "yes" "$(_check signature_safety B)"        "batch-04 wasted: B on signature_safety"
assert_equals "yes" "$(_check wallet_safety C.3)"         "batch-04 wasted: C.3 on wallet_safety"

# Test 7: env override bypasses filter
EXCLUDED_DEFAULT=$(python3 -c "
import sys, os
sys.path.insert(0, '$REPO_ROOT/tools')
from sample_matrix_run import _flatten_all
default = len(_flatten_all(apply_surface_filter=True))
unfiltered = len(_flatten_all(apply_surface_filter=False))
print(unfiltered - default)
")
EXCLUDED_ENV=$(SAMPLE_MATRIX_NO_SURFACE_FILTER=1 python3 -c "
import sys, os
sys.path.insert(0, '$REPO_ROOT/tools')
from sample_matrix_run import _flatten_all
default = len(_flatten_all(apply_surface_filter=True))
unfiltered = len(_flatten_all(apply_surface_filter=False))
print(unfiltered - default)
")
[[ "$EXCLUDED_DEFAULT" -gt 0 ]] && _test_pass "default filter excludes >0 cells ($EXCLUDED_DEFAULT)" || _test_fail "default filter should exclude cells, got $EXCLUDED_DEFAULT"
assert_equals "0" "$EXCLUDED_ENV" "SAMPLE_MATRIX_NO_SURFACE_FILTER=1 bypasses filter (0 excluded)"

echo ""
