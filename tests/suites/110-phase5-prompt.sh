#!/bin/bash
# 110-phase5-prompt.sh — exercises tools/build_phase5_prompt.py.
# Verifies (per issue #49):
#   - Builder emits a prompt with required structural elements (§0–§7 anchors,
#     issues.draft.json schema reference, tool discipline).
#   - **A.5/C.5 re-classification block is present and load-bearing**
#     (subagent must re-derive a5_attribution per cell, override per-cell tag).
#   - issues.draft.json `attribution` for A.5/C.5 uses the analyst-derived tag.
#   - §1 mandates the per-cell-vs-analyst disagreement metric.
#   - Workdir override and prior-batches flag thread through.
#   - Builder rejects malformed --prior-batches input.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"

echo ""
echo "=== Suite 110: phase5-prompt builder ==="

BUILDER="$REPO_ROOT/tools/build_phase5_prompt.py"

# Test 1: default invocation — required structural elements
OUT=$(python3 "$BUILDER" --batch 5)
assert_contains "$OUT" "Phase 5 analyst" "default: identifies role"
assert_contains "$OUT" "Smoke-Test Batch-05 Findings" "default: heading carries batch number"
assert_contains "$OUT" "summary.txt" "default: references summary.txt input"
assert_contains "$OUT" "aggregate.json" "default: references aggregate.json input"
assert_contains "$OUT" "transcripts/" "default: references transcripts dir"
assert_contains "$OUT" "scripts.json" "default: references scripts.json input"
assert_contains "$OUT" "vaultpilot-mcp" "default: defaults MCP name to vaultpilot-mcp"
assert_contains "$OUT" "runs/matrix-sampled/batch-05" "default: workdir reflects batch number"

# Test 2: required §0–§7 section anchors present
assert_contains "$OUT" "## 0. Parse-failure surfacing" "§0 anchor present"
assert_contains "$OUT" "## 1. Aggregate resilience numbers" "§1 anchor present"
assert_contains "$OUT" "## 2. Defensive resilience matrix" "§2 anchor present"
assert_contains "$OUT" "## 3. Critical findings" "§3 anchor present"
assert_contains "$OUT" "## 4. Invariant coverage gaps" "§4 anchor present"
assert_contains "$OUT" "## 5. Proposed new invariants" "§5 anchor present"
assert_contains "$OUT" "## 6. Filing recommendations" "§6 anchor present"
assert_contains "$OUT" "## 7. Advisory-finding summary" "§7 anchor present"
assert_contains "$OUT" "§7a — Chat-client output filter" "§7a sub-anchor present"
assert_contains "$OUT" "§7b — Model-layer safety" "§7b sub-anchor present"

# Test 3: A.5/C.5 RE-CLASSIFICATION BLOCK (issue #49 headline)
assert_contains "$OUT" "A.5 / C.5 RE-CLASSIFICATION" "re-classification block header present"
assert_contains "$OUT" "re-derive" "re-classification: instructs re-derivation"
assert_contains "$OUT" "do not rely on the summary record" "re-classification: forbids relying on per-cell tag alone"
assert_contains "$OUT" "OVERRIDES the per-cell" "re-classification: explicit override directive"
assert_contains "$OUT" "injection-shaped" "re-classification: names injection-shaped class"
assert_contains "$OUT" "model-shaped" "re-classification: names model-shaped class"
assert_contains "$OUT" "chat-client output filter" "re-classification: routes injection-shaped to chat-client filter"
assert_contains "$OUT" "Anthropic model-layer safety" "re-classification: routes model-shaped to model-layer safety"

# Test 4: §1 disagreement metric MANDATORY (issue #49 'Done when' #3)
assert_contains "$OUT" "per-cell-vs-analyst disagreement" "§1 mandates disagreement metric"
assert_contains "$OUT" "MANDATORY ROW" "§1 marks disagreement metric as mandatory"

# Test 5: issues.draft.json schema references analyst-derived attribution
assert_contains "$OUT" "advisory-injection-shaped" "schema lists advisory-injection-shaped attribution"
assert_contains "$OUT" "advisory-model-shaped" "schema lists advisory-model-shaped attribution"
assert_contains "$OUT" "mcp-defect" "schema lists mcp-defect attribution"
assert_contains "$OUT" "skill-defect" "schema lists skill-defect attribution"
assert_contains "$OUT" "json-issues-draft" "fenced JSON block uses json-issues-draft language tag"
assert_contains "$OUT" "uses YOUR re-classified tag" "JSON block: A.5/C.5 attribution uses analyst tag"
assert_contains "$OUT" "not the per-cell tag" "JSON block: explicit not-per-cell"

# Test 6: tool discipline (Read tool, no Bash cat, no file writes by subagent)
assert_contains "$OUT" "Use the Read tool" "tool discipline: Read"
assert_contains "$OUT" "Do NOT use Bash" "tool discipline: no Bash for file reads"
assert_contains "$OUT" "Do NOT write files yourself" "tool discipline: subagent does not persist artifacts"
assert_contains "$OUT" "HARD CAP" "tool discipline: tool-call cap"

# Test 7: caveat block (E rows / harness denials / demo-mode blockers)
assert_contains "$OUT" "harness denials are NOT MCP bugs" "caveats: harness-denial filter"
assert_contains "$OUT" "Demo-mode signing-flow blockers" "caveats: demo-mode filter"
assert_contains "$OUT" "E rows where any defense layer fires" "caveats: E false-positive heuristic"
assert_contains "$OUT" "tool-gap" "caveats: tool-gap exception for E"

# Test 8: --workdir override threads through
OUT=$(python3 "$BUILDER" --batch 7 --workdir /tmp/test-batch-7)
assert_contains "$OUT" "/tmp/test-batch-7/summary.txt" "workdir override applies to summary path"
assert_contains "$OUT" "/tmp/test-batch-7/transcripts/" "workdir override applies to transcripts path"
assert_contains "$OUT" "/tmp/test-batch-7/scripts.json" "workdir override applies to scripts path"
assert_contains "$OUT" "Smoke-Test Batch-07" "batch number reflected in heading even with workdir override"

# Test 9: --mcp-name override threads through
OUT=$(python3 "$BUILDER" --batch 5 --mcp-name "some-other-mcp")
assert_contains "$OUT" "some-other-mcp" "--mcp-name flows through"
assert_not_contains "$OUT" "smoke-test of the vaultpilot-mcp MCP" "--mcp-name replaces default"

# Test 10: --prior-batches adds the cross-batch reference block
OUT=$(python3 "$BUILDER" --batch 5 --prior-batches 1,2,3)
assert_contains "$OUT" "Prior batch findings for cross-batch context" "prior-batches: section header present"
assert_contains "$OUT" "runs/matrix-sampled/batch-01/findings.md" "prior-batches: batch-01 listed"
assert_contains "$OUT" "runs/matrix-sampled/batch-02/findings.md" "prior-batches: batch-02 listed"
assert_contains "$OUT" "runs/matrix-sampled/batch-03/findings.md" "prior-batches: batch-03 listed"

# Test 11: no --prior-batches → no Prior batch findings block
OUT=$(python3 "$BUILDER" --batch 5)
assert_not_contains "$OUT" "Prior batch findings for cross-batch context" "no prior-batches: header absent"

# Test 12: malformed --prior-batches → exit 1
set +e
OUT=$(python3 "$BUILDER" --batch 5 --prior-batches "1,not-a-number,3" 2>&1)
EC=$?
set -e
assert_exit_code 1 "$EC" "malformed --prior-batches → exit 1"
assert_contains "$OUT" "comma-separated integers" "stderr explains the error"

# Test 13: --batch is required
set +e
OUT=$(python3 "$BUILDER" 2>&1)
EC=$?
set -e
assert_exit_code 2 "$EC" "missing --batch → argparse exit 2"

# Test 14: cross-batch routing is named explicitly (helps GATE 2 reading)
OUT=$(python3 "$BUILDER" --batch 5)
assert_contains "$OUT" "Routes to **chat-client output filter**" "injection-shaped routing destination labelled in bold"
assert_contains "$OUT" "Routes to **Anthropic model-layer safety**" "model-shaped routing destination labelled in bold"

echo ""
