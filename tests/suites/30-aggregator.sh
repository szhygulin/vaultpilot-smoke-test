#!/bin/bash
# 30-aggregator.sh — exercises _aggregate_batch over a synthetic transcripts
# directory. Verifies:
#   - aggregate.json structure (all expected keys present)
#   - parse_failures correctly aggregated across transcripts
#   - by_outcome_status + by_refusal_class counters populated
#   - E false-positive heuristic: tightened (only refused-AND-not-tool-gap)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"

echo ""
echo "=== Suite 30: aggregator ==="

TMP=$(mktempdir)
trap 'cleanup_tempdir "$TMP"' EXIT

# Build a synth batch dir with fixture transcripts.
BATCH_DIR="$TMP/runs/matrix-sampled/batch-99"
mkdir -p "$BATCH_DIR/transcripts"
cp "$REPO_ROOT/tests/fixtures/well-formed.txt" "$BATCH_DIR/transcripts/"
cp "$REPO_ROOT/tests/fixtures/missing-refusal-class.txt" "$BATCH_DIR/transcripts/"
cp "$REPO_ROOT/tests/fixtures/e-control-clean.txt" "$BATCH_DIR/transcripts/"
cp "$REPO_ROOT/tests/fixtures/e-tool-gap-not-fp.txt" "$BATCH_DIR/transcripts/"
cp "$REPO_ROOT/tests/fixtures/e-genuine-fp.txt" "$BATCH_DIR/transcripts/"

# Invoke _aggregate_batch directly (not via mark-completed, which depends on
# progress.json). Use the SAMPLE_DIR override.
AGG_JSON=$(python3 - <<PYEOF
import sys, json, os
# Override SAMPLE_DIR so _aggregate_batch's batch_dir resolves into our temp.
os.chdir('$TMP')
sys.path.insert(0, '$REPO_ROOT/tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
agg = smr._aggregate_batch(99, transcripts_dir='$BATCH_DIR/transcripts', quiet=True)
print(json.dumps(agg, indent=2))
PYEOF
)

# 1. Structure: all expected top-level keys present.
for k in batch total_transcripts by_defense_layer by_did_user_get_tricked by_role by_outcome_status by_refusal_class by_a5_attribution e_false_positive_count e_false_positive_script_ids parse_failures tricked_count tricked_script_ids tool_surface_tricked_count tool_surface_tricked_script_ids advisory_tricked_count advisory_tricked_script_ids; do
    assert_contains "$AGG_JSON" "\"$k\":" "aggregate.json contains key '$k'"
done

# 2. Counters
assert_equals "5"       "$(echo "$AGG_JSON" | jq -r '.total_transcripts')" "aggregate: 5 transcripts"
assert_equals "0"       "$(echo "$AGG_JSON" | jq -r '.tricked_count')"     "aggregate: 0 tricked"
# Issue #71 split fields (no tricked records in this fixture → both 0).
assert_equals "0"       "$(echo "$AGG_JSON" | jq -r '.tool_surface_tricked_count')" "aggregate: 0 tool-surface tricked"
assert_equals "0"       "$(echo "$AGG_JSON" | jq -r '.advisory_tricked_count')"     "aggregate: 0 advisory tricked"

# 3. by_role distribution: expected A.4=1, B=1, E=3
assert_equals "1" "$(echo "$AGG_JSON" | jq -r '.by_role."A.4"')" "by_role.A.4 = 1"
assert_equals "1" "$(echo "$AGG_JSON" | jq -r '.by_role.B')"     "by_role.B = 1"
assert_equals "3" "$(echo "$AGG_JSON" | jq -r '.by_role.E')"     "by_role.E = 3"

# 4. by_refusal_class — only fixtures with status=refused emit refusal_class:
#    well-formed (security), missing-refusal-class (unknown), e-tool-gap (tool-gap),
#    e-genuine-fp (security). e-control-clean is status=success → not counted.
assert_equals "2" "$(echo "$AGG_JSON" | jq -r '.by_refusal_class.security // 0')" "by_refusal_class.security = 2"
assert_equals "1" "$(echo "$AGG_JSON" | jq -r '.by_refusal_class."tool-gap" // 0')" "by_refusal_class.tool-gap = 1"
assert_equals "1" "$(echo "$AGG_JSON" | jq -r '.by_refusal_class.unknown // 0')"   "by_refusal_class.unknown = 1 (missing field)"

# 5. parse_failures: missing-refusal-class.txt should appear exactly once
PF_COUNT=$(echo "$AGG_JSON" | jq -r '.parse_failures | length')
assert_equals "1" "$PF_COUNT" "parse_failures has exactly 1 entry"
PF_FIELD=$(echo "$AGG_JSON" | jq -r '.parse_failures[0].field')
assert_equals "refusal_class" "$PF_FIELD" "parse_failures entry: field=refusal_class"
PF_FILE=$(echo "$AGG_JSON" | jq -r '.parse_failures[0].file')
assert_equals "missing-refusal-class.txt" "$PF_FILE" "parse_failures entry: file=missing-refusal-class.txt"

# 6. E false-positive heuristic (Lane 1 tightening):
#    e-control-clean.txt — defense=none, status=success → NOT FP
#    e-tool-gap-not-fp.txt — defense=non-empty BUT refusal_class=tool-gap → NOT FP
#    e-genuine-fp.txt — defense=invariant-5, status=refused, refusal_class=security → IS FP
#    Expected count: exactly 1 (only the genuine FP).
assert_equals "1" "$(echo "$AGG_JSON" | jq -r '.e_false_positive_count')" "E FP heuristic: counts only genuine over-trigger"
FP_IDS=$(echo "$AGG_JSON" | jq -c '.e_false_positive_script_ids')
assert_contains "$FP_IDS" "synth-E-genuine-fp" "E FP list contains synth-E-genuine-fp"
assert_not_contains "$FP_IDS" "synth-E-toolgap" "E FP list does NOT contain synth-E-toolgap (correct: tool-gap excluded)"
assert_not_contains "$FP_IDS" "synth-E-clean"  "E FP list does NOT contain synth-E-clean (correct: status=success)"

echo ""
