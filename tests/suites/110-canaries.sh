#!/bin/bash
# 110-canaries.sh — exercises golden-canary regression-detection plumbing in
# tools/sample_matrix_run.py. Verifies:
#   - tools/canaries.json is well-formed and seeds at least one cell per
#     A/B/C/D/E/F threat-model role (issue #47 acceptance criterion).
#   - _aggregate_batch validates canary transcripts against expected_* fields
#     read from scripts.json:
#       * matching transcript → canary_drift_count == 0, no CANARY DRIFT block.
#       * mismatched defense_layer → drift, CANARY DRIFT block at top of
#         summary.txt, drifted id surfaced in aggregate.json.
#       * missing transcript → counted as drift (silent skip protection).
#   - Canary records are excluded from matrix counters (by_role / by_layer etc.).
#   - cmd_mark_completed gates close-out on drift:
#       * drift + no --ack-canary-drift → exit 1, progress NOT marked completed.
#       * drift + --ack-canary-drift → exit 0, progress completed, drift recorded.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"

echo ""
echo "=== Suite 110: canaries ==="

# ---------------------------------------------------------------------------
# Test 1: tools/canaries.json structure — has at least one cell per
# A/B/C/D/E/F role family (issue #47 done-when criterion).
# ---------------------------------------------------------------------------
CANARIES_JSON="$REPO_ROOT/tools/canaries.json"
assert_file_exists "$CANARIES_JSON" "tools/canaries.json present"

ROLES=$(jq -r '.canaries[].role' "$CANARIES_JSON" | sort -u)
for family in A B C D E F; do
    if echo "$ROLES" | grep -qE "^${family}(\.[0-9]+)?$"; then
        _test_pass "canaries.json covers role family $family"
    else
        _test_fail "canaries.json missing role family $family"
    fi
done

# Schema sanity: every canary has the required keys.
N_CANARIES=$(jq '.canaries | length' "$CANARIES_JSON")
[[ "$N_CANARIES" -ge 6 ]] && _test_pass "canaries.json has ≥6 entries (got $N_CANARIES)" \
    || _test_fail "canaries.json has <6 entries (got $N_CANARIES)"

MISSING_FIELDS=$(jq -r '
    .canaries[] |
    select(.id == null or .role == null or .script == null or
           .expected_status == null or .expected_defense_layer == null or
           .expected_tricked == null) |
    .id
' "$CANARIES_JSON")
if [[ -z "$MISSING_FIELDS" ]]; then
    _test_pass "every canary has required keys (id/role/script/expected_*)"
else
    _test_fail "canaries missing required keys: $MISSING_FIELDS"
fi

# IDs must match C\d{3}.
BAD_IDS=$(jq -r '.canaries[].id | select(test("^C[0-9]{3}$") | not)' "$CANARIES_JSON")
if [[ -z "$BAD_IDS" ]]; then
    _test_pass "all canary ids match C\\d{3}"
else
    _test_fail "canaries with bad ids: $BAD_IDS"
fi

# ---------------------------------------------------------------------------
# Aggregator behaviour. Build a synth batch dir with a scripts.json (so
# _load_canary_expectations finds the canary) and a transcripts/ dir.
# ---------------------------------------------------------------------------

# Test 2: matching canary transcript → no drift, canary excluded from matrix counters.
TMP=$(mktempdir)
trap 'cleanup_tempdir "$TMP"' EXIT
BATCH_DIR="$TMP/runs/matrix-sampled/batch-99"
mkdir -p "$BATCH_DIR/transcripts"
write_synth_scripts_with_canary "$BATCH_DIR/scripts.json"
cp "$REPO_ROOT/tests/fixtures/canary-C001-ok.txt" "$BATCH_DIR/transcripts/C001.txt"
# Add a non-canary matrix transcript so we can verify the split.
cp "$REPO_ROOT/tests/fixtures/well-formed.txt" "$BATCH_DIR/transcripts/synth-A.4.txt"

AGG_OK=$(python3 - <<PYEOF
import json, sys, os
sys.path.insert(0, '$REPO_ROOT/tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
agg = smr._aggregate_batch(99, transcripts_dir='$BATCH_DIR/transcripts', quiet=True)
print(json.dumps(agg, indent=2))
PYEOF
)

assert_equals "0" "$(echo "$AGG_OK" | jq -r '.canary_drift_count')" "matching canary: drift_count=0"
assert_equals "1" "$(echo "$AGG_OK" | jq -r '.canary_transcripts')"  "matching canary: 1 canary transcript"
assert_equals "1" "$(echo "$AGG_OK" | jq -r '.matrix_transcripts')" "matching canary: 1 matrix transcript"
# canary's role (A.1) must NOT appear in matrix by_role counter.
assert_equals "null" "$(echo "$AGG_OK" | jq -r '.by_role."A.1" // null')" \
    "canary excluded from matrix by_role"
# matrix counter still has A.4 from the non-canary fixture.
assert_equals "1" "$(echo "$AGG_OK" | jq -r '.by_role."A.4"')" \
    "matrix by_role still counts A.4"

SUMMARY_OK="$BATCH_DIR/summary.txt"
assert_file_exists "$SUMMARY_OK" "summary.txt written"
if grep -q "CANARIES OK" "$SUMMARY_OK"; then
    _test_pass "summary.txt contains CANARIES OK banner on match"
else
    _test_fail "summary.txt missing CANARIES OK banner"
fi
if grep -q "CANARY DRIFT" "$SUMMARY_OK"; then
    _test_fail "summary.txt unexpectedly contains CANARY DRIFT on match"
else
    _test_pass "summary.txt has no CANARY DRIFT block on match"
fi

# Cleanup before next test.
rm -rf "$BATCH_DIR"

# ---------------------------------------------------------------------------
# Test 3: drifted canary (defense_layer wrong) → drift, CANARY DRIFT block.
# ---------------------------------------------------------------------------
mkdir -p "$BATCH_DIR/transcripts"
write_synth_scripts_with_canary "$BATCH_DIR/scripts.json"
cp "$REPO_ROOT/tests/fixtures/canary-C001-drift.txt" "$BATCH_DIR/transcripts/C001.txt"

AGG_DRIFT=$(python3 - <<PYEOF
import json, sys
sys.path.insert(0, '$REPO_ROOT/tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
agg = smr._aggregate_batch(99, transcripts_dir='$BATCH_DIR/transcripts', quiet=True)
print(json.dumps(agg, indent=2))
PYEOF
)

assert_equals "1" "$(echo "$AGG_DRIFT" | jq -r '.canary_drift_count')" \
    "drifted canary: drift_count=1"
DRIFTED_IDS=$(echo "$AGG_DRIFT" | jq -c '.canary_drifted_ids')
assert_contains "$DRIFTED_IDS" "C001" "drifted_ids contains C001"
# The mismatch list must call out defense_layer specifically.
MISMATCH=$(echo "$AGG_DRIFT" | jq -c '.canary_results[0].mismatches[] | select(.field=="defense_layer")')
assert_contains "$MISMATCH" "invariant-2" "defense_layer mismatch records expected=invariant-2"
assert_contains "$MISMATCH" "invariant-7" "defense_layer mismatch records actual=invariant-7"

SUMMARY_DRIFT="$BATCH_DIR/summary.txt"
if grep -q "^CANARY DRIFT" "$SUMMARY_DRIFT"; then
    _test_pass "summary.txt has CANARY DRIFT block at top on drift"
else
    _test_fail "summary.txt missing CANARY DRIFT block on drift"
fi
if grep -q "blocked unless --ack-canary-drift" "$SUMMARY_DRIFT"; then
    _test_pass "summary.txt mentions --ack-canary-drift escape hatch"
else
    _test_fail "summary.txt doesn't mention --ack-canary-drift"
fi

# Cleanup before next test.
rm -rf "$BATCH_DIR"

# ---------------------------------------------------------------------------
# Test 4: missing canary transcript → counted as drift.
# ---------------------------------------------------------------------------
mkdir -p "$BATCH_DIR/transcripts"
write_synth_scripts_with_canary "$BATCH_DIR/scripts.json"
# Only the matrix transcript — canary intentionally missing.
cp "$REPO_ROOT/tests/fixtures/well-formed.txt" "$BATCH_DIR/transcripts/synth-A.4.txt"

AGG_MISSING=$(python3 - <<PYEOF
import json, sys
sys.path.insert(0, '$REPO_ROOT/tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
agg = smr._aggregate_batch(99, transcripts_dir='$BATCH_DIR/transcripts', quiet=True)
print(json.dumps(agg, indent=2))
PYEOF
)

assert_equals "1" "$(echo "$AGG_MISSING" | jq -r '.canary_drift_count')" \
    "missing canary transcript: drift_count=1"
MISSING_FIELD=$(echo "$AGG_MISSING" | jq -r '.canary_results[0].mismatches[0].field')
assert_equals "__transcript__" "$MISSING_FIELD" \
    "missing canary records field=__transcript__"

# Cleanup.
rm -rf "$BATCH_DIR"

# ---------------------------------------------------------------------------
# Test 5: cmd_mark_completed blocks on drift without --ack-canary-drift.
# ---------------------------------------------------------------------------
mkdir -p "$BATCH_DIR/transcripts"
write_synth_scripts_with_canary "$BATCH_DIR/scripts.json"
cp "$REPO_ROOT/tests/fixtures/canary-C001-drift.txt" "$BATCH_DIR/transcripts/C001.txt"
write_synth_progress "$TMP/runs/matrix-sampled/progress.json" 99 in_progress
mkdir -p "$TMP/tools"
cp "$REPO_ROOT/tools/sample_matrix_run.py" "$REPO_ROOT/tools/surface_taxonomy.py" "$TMP/tools/"
# A minimal canaries.json so _load_canaries doesn't error if invoked.
cp "$REPO_ROOT/tools/canaries.json" "$TMP/tools/canaries.json"
# partition.json isn't strictly needed by mark-completed but progress.json IS.

cd "$TMP"
set +e
OUT=$(python3 tools/sample_matrix_run.py mark-completed --batch 99 2>&1)
EC=$?
set -e
assert_exit_code 1 "$EC" "mark-completed exits 1 on canary drift without ack"
assert_contains "$OUT" "CANARY DRIFT" "stderr surfaces CANARY DRIFT"
assert_contains "$OUT" "--ack-canary-drift" "stderr names the ack escape hatch"

# Verify progress.json is still in_progress (close-out did NOT update state).
STATUS=$(jq -r '.batches[0].status' "$TMP/runs/matrix-sampled/progress.json")
assert_equals "in_progress" "$STATUS" \
    "progress.json status remains in_progress after blocked close-out"

# ---------------------------------------------------------------------------
# Test 6: --ack-canary-drift unblocks close-out.
# ---------------------------------------------------------------------------
set +e
OUT2=$(python3 tools/sample_matrix_run.py mark-completed --batch 99 \
    --ack-canary-drift 2>&1)
EC2=$?
set -e
assert_exit_code 0 "$EC2" "mark-completed exits 0 with --ack-canary-drift"
assert_contains "$OUT2" "marked completed" "stdout confirms close-out"
assert_contains "$OUT2" "canary drift acknowledged" \
    "stdout records the deliberate acknowledgement"

STATUS2=$(jq -r '.batches[0].status' "$TMP/runs/matrix-sampled/progress.json")
assert_equals "completed" "$STATUS2" \
    "progress.json status flipped to completed after acknowledged drift"

cd "$REPO_ROOT"
echo ""
