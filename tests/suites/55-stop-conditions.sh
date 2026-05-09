#!/bin/bash
# 55-stop-conditions.sh — exercises the per-batch quality gate added in #51.
# Verifies:
#   - mark-completed writes batch-NN/stop_conditions.json with measures + triggered list
#   - tricked_yes_count > max triggers a rule
#   - e_row_defense_fire_rate_pct triggers when E rows over-fire
#   - parse_failure_rate_pct triggers above 2%
#   - forward-compat slots (canary_drift_count, calibration_disagreement_rate_pct)
#     evaluate only when the underlying field is present in aggregate.json
#   - next-batch refuses to advance with an unacknowledged triggered batch
#   - ack-stops writes the .stops-acknowledged stamp with the reason
#   - next-batch advances after ack
#   - thresholds are tunable in tools/stop_conditions.json without code changes

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"

echo ""
echo "=== Suite 55: stop-conditions (per-batch quality gate) ==="

TMP=$(mktempdir)
trap 'cleanup_tempdir "$TMP"' EXIT

# Build a self-contained mini-repo: matrix.json, partition, progress, plus
# the tools/ directory with the modules sample_matrix_run.py imports.
mkdir -p "$TMP/test-vectors" "$TMP/runs/matrix-sampled" "$TMP/tools"
write_synth_matrix "$TMP/test-vectors/matrix.json"
cp "$REPO_ROOT/tools/sample_matrix_run.py" "$REPO_ROOT/tools/surface_taxonomy.py" "$TMP/tools/"
cp "$REPO_ROOT/tools/stop_conditions.json" "$TMP/tools/"

# -----------------------------------------------------------------------------
# Test 1: _evaluate_stop_conditions writes batch-NN/stop_conditions.json
#         and triggers tool_surface_tricked_yes_count when count > max.
#         (Issue #71 split — tool-surface roles use the tight bound.)
# -----------------------------------------------------------------------------
BATCH_DIR="$TMP/runs/matrix-sampled/batch-99"
mkdir -p "$BATCH_DIR"

# Synth aggregate with 3 tool-surface tricked-yes (above default max=2).
python3 -c "
import json
agg = {
    'batch': 99,
    'total_transcripts': 50,
    'by_role': {'E': 5, 'A.4': 10, 'B': 35},
    'parse_failures': [],
    'e_false_positive_count': 0,
    'tricked_count': 3,
    'tool_surface_tricked_count': 3,
    'advisory_tricked_count': 0,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"

OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")

assert_file_exists "$BATCH_DIR/stop_conditions.json" "stop_conditions.json written"
TRIG_COUNT=$(echo "$OUT" | jq -r '.triggered | length')
assert_equals "1" "$TRIG_COUNT" "exactly 1 condition triggered (tool_surface_tricked_yes_count > 2)"
TRIG_NAME=$(echo "$OUT" | jq -r '.triggered[0].name')
assert_equals "tool_surface_tricked_yes_count" "$TRIG_NAME" "triggered rule named tool_surface_tricked_yes_count"
TRIG_MEASURE=$(echo "$OUT" | jq -r '.triggered[0].measure')
assert_equals "3" "$TRIG_MEASURE" "triggered measure = 3"

# Forward-compat: canary_drift_count + calibration_disagreement_rate_pct should
# NOT have been evaluated (fields absent in this aggregate.json). Both new
# tricked-yes splits ARE evaluated since the test populates them.
EVAL_COUNT=$(echo "$OUT" | jq -r '.evaluated_count')
assert_equals "4" "$EVAL_COUNT" "evaluated_count = 4 (tool_surface + advisory + e_row + parse_failure)"

# -----------------------------------------------------------------------------
# Test 2: clean batch — no rule triggers.
# -----------------------------------------------------------------------------
python3 -c "
import json
agg = {
    'batch': 99,
    'total_transcripts': 50,
    'by_role': {'E': 5, 'A.4': 10, 'B': 35},
    'parse_failures': [],
    'e_false_positive_count': 0,
    'tricked_count': 0,
    'tool_surface_tricked_count': 0,
    'advisory_tricked_count': 0,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")
TRIG_COUNT=$(echo "$OUT" | jq -r '.triggered | length')
assert_equals "0" "$TRIG_COUNT" "clean batch: 0 conditions triggered"

# -----------------------------------------------------------------------------
# Test 3: e_row_defense_fire_rate_pct triggers above 5% (default max).
#         Synth: 20 E rows, 2 false positives → 10% > 5% → triggers.
# -----------------------------------------------------------------------------
python3 -c "
import json
agg = {
    'batch': 99,
    'total_transcripts': 100,
    'by_role': {'E': 20, 'A.4': 80},
    'parse_failures': [],
    'e_false_positive_count': 2,
    'tricked_count': 0,
    'tool_surface_tricked_count': 0,
    'advisory_tricked_count': 0,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")
TRIG_NAMES=$(echo "$OUT" | jq -r '.triggered[].name' | sort | tr '\n' ',')
assert_contains "$TRIG_NAMES" "e_row_defense_fire_rate_pct" "E false-positive rate triggers"

# -----------------------------------------------------------------------------
# Test 4: parse_failure_rate_pct triggers above 2% (default max).
#         Synth: 100 transcripts, 3 parse failures across 3 distinct files → 3% > 2%.
# -----------------------------------------------------------------------------
python3 -c "
import json
agg = {
    'batch': 99,
    'total_transcripts': 100,
    'by_role': {'E': 5, 'A.4': 95},
    'parse_failures': [
        {'file': 'a.txt', 'field': 'role', 'raw': '', 'canonicalized': 'unknown'},
        {'file': 'b.txt', 'field': 'role', 'raw': '', 'canonicalized': 'unknown'},
        {'file': 'c.txt', 'field': 'role', 'raw': '', 'canonicalized': 'unknown'},
    ],
    'e_false_positive_count': 0,
    'tricked_count': 0,
    'tool_surface_tricked_count': 0,
    'advisory_tricked_count': 0,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")
TRIG_NAMES=$(echo "$OUT" | jq -r '.triggered[].name' | sort | tr '\n' ',')
assert_contains "$TRIG_NAMES" "parse_failure_rate_pct" "parse_failure_rate_pct triggers"

# -----------------------------------------------------------------------------
# Test 5: forward-compat slots — canary_drift_count fires when present.
# -----------------------------------------------------------------------------
python3 -c "
import json
agg = {
    'batch': 99,
    'total_transcripts': 50,
    'by_role': {'E': 5, 'A.4': 45},
    'parse_failures': [],
    'e_false_positive_count': 0,
    'tricked_count': 0,
    'tool_surface_tricked_count': 0,
    'advisory_tricked_count': 0,
    'canary_drift_count': 1,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")
TRIG_NAMES=$(echo "$OUT" | jq -r '.triggered[].name' | sort | tr '\n' ',')
assert_contains "$TRIG_NAMES" "canary_drift_count" "forward-compat: canary_drift_count fires when present"
EVAL_COUNT=$(echo "$OUT" | jq -r '.evaluated_count')
assert_equals "5" "$EVAL_COUNT" "evaluated_count = 5 (tool_surface + advisory + e_row + parse_failure + canary_drift; calibration still absent)"

# -----------------------------------------------------------------------------
# Test 6: next-batch BLOCKS when previous batch has unacknowledged triggers.
#         Setup: batch 99 completed with 3 tricked → triggered.
#         Add a pending batch 100 → next-batch should refuse.
# -----------------------------------------------------------------------------
python3 -c "
import json
# Re-trigger the 3-tricked aggregate (all tool-surface).
agg = {
    'batch': 99,
    'total_transcripts': 50,
    'by_role': {'E': 5, 'A.4': 45},
    'parse_failures': [],
    'e_false_positive_count': 0,
    'tricked_count': 3,
    'tool_surface_tricked_count': 3,
    'advisory_tricked_count': 0,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
# Build a partition with batches 99 (completed) + 100 (pending).
python3 -c "
import json
data = {
    'created_at': '2026-04-29T00:00:00Z',
    'seed': 42,
    'batch_size': 2,
    'budget_constraint': {
        'all_models_weekly_tokens': 50000000,
        'session_all_models_tokens': 5000000,
        'tokens_per_cell': 25000,
        'analysis_tokens': 82000,
        'batch_session_fraction': 0.25,
    },
    'total_cells': 4,
    'total_batches': 2,
    'batches': [
        {'batch': 99, 'cells': [
            {'audience': 'expert', 'row_id': 'synth-001', 'role': 'A.4'},
            {'audience': 'expert', 'row_id': 'synth-001', 'role': 'B'},
        ]},
        {'batch': 100, 'cells': [
            {'audience': 'expert', 'row_id': 'synth-001', 'role': 'A.4'},
            {'audience': 'expert', 'row_id': 'synth-001', 'role': 'B'},
        ]},
    ],
}
json.dump(data, open('$TMP/runs/matrix-sampled/partition.json', 'w'), indent=2)

prog = {
    'created_at': '2026-04-29T00:00:00Z',
    'total_batches': 2,
    'batches': [
        {'batch': 99,  'cell_count': 2, 'status': 'completed', 'started_at': '2026-04-29T00:00:00Z', 'completed_at': '2026-04-29T01:00:00Z', 'transcripts_dir': None},
        {'batch': 100, 'cell_count': 2, 'status': 'pending',   'started_at': None,                   'completed_at': None,                   'transcripts_dir': None},
    ],
}
json.dump(prog, open('$TMP/runs/matrix-sampled/progress.json', 'w'), indent=2)
"
# Force a fresh evaluation so stop_conditions.json reflects the 3-tricked state.
python3 -c "
import os, sys, json
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = json.load(open('$BATCH_DIR/aggregate.json'))
smr._evaluate_stop_conditions(99, agg)
"

cd "$TMP"
set +e
OUT=$(python3 tools/sample_matrix_run.py next-batch 2>&1)
EC=$?
set -e
assert_exit_code 1 "$EC" "next-batch refuses with unacknowledged triggers"
assert_contains "$OUT" "tool_surface_tricked_yes_count" "stderr names the triggered rule"
assert_contains "$OUT" "ack-stops" "stderr surfaces the override path"
assert_contains "$OUT" "stop_conditions.json" "stderr points at the report file"

# Confirm the pending batch 100 was NOT marked in_progress.
STATUS_100=$(jq -r '.batches[] | select(.batch==100) | .status' "$TMP/runs/matrix-sampled/progress.json")
assert_equals "pending" "$STATUS_100" "batch 100 still pending (not advanced)"

# -----------------------------------------------------------------------------
# Test 7: ack-stops creates .stops-acknowledged with the reason.
# -----------------------------------------------------------------------------
set +e
OUT=$(python3 tools/sample_matrix_run.py ack-stops --batch 99 --reason "tricked-yes was a fixture bug, real catches all on-device" 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "ack-stops returns 0 on triggered batch"
assert_file_exists "$TMP/runs/matrix-sampled/batch-99/.stops-acknowledged" ".stops-acknowledged stamp written"
ACK_REASON=$(jq -r '.reason' "$TMP/runs/matrix-sampled/batch-99/.stops-acknowledged")
assert_contains "$ACK_REASON" "tricked-yes was a fixture bug" "reason recorded for audit"
ACK_BATCH=$(jq -r '.batch' "$TMP/runs/matrix-sampled/batch-99/.stops-acknowledged")
assert_equals "99" "$ACK_BATCH" "ack file records batch number"

# -----------------------------------------------------------------------------
# Test 8: next-batch now advances past the gate.
# -----------------------------------------------------------------------------
set +e
OUT=$(python3 tools/sample_matrix_run.py next-batch 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "next-batch passes after ack"
STATUS_100=$(jq -r '.batches[] | select(.batch==100) | .status' "$TMP/runs/matrix-sampled/progress.json")
assert_equals "in_progress" "$STATUS_100" "batch 100 marked in_progress after ack"

# -----------------------------------------------------------------------------
# Test 9: ack-stops on a clean batch refuses (no triggered conditions).
# -----------------------------------------------------------------------------
# Reset batch 99 to clean state.
python3 -c "
import os, sys, json
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = {
    'batch': 99, 'total_transcripts': 50,
    'by_role': {'E': 5, 'A.4': 45}, 'parse_failures': [],
    'e_false_positive_count': 0, 'tricked_count': 0,
    'tool_surface_tricked_count': 0, 'advisory_tricked_count': 0,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
smr._evaluate_stop_conditions(99, agg)
"
# Remove old ack stamp so we test the refusal path.
rm -f "$TMP/runs/matrix-sampled/batch-99/.stops-acknowledged"
set +e
OUT=$(python3 tools/sample_matrix_run.py ack-stops --batch 99 --reason "shouldn't be needed" 2>&1)
EC=$?
set -e
assert_exit_code 1 "$EC" "ack-stops refuses on a clean batch"
assert_contains "$OUT" "no triggered" "stderr explains nothing to acknowledge"

# -----------------------------------------------------------------------------
# Test 10: thresholds tunable via stop_conditions.json (no code changes).
#         Tighten tool_surface_tricked_yes_count.max to 0; tool_surface=1 → triggers.
# -----------------------------------------------------------------------------
python3 -c "
import json
cfg = json.load(open('$TMP/tools/stop_conditions.json'))
cfg['thresholds']['tool_surface_tricked_yes_count']['max'] = 0
json.dump(cfg, open('$TMP/tools/stop_conditions.json', 'w'), indent=2)
"
# tool_surface_tricked_count=1 > max=0 → triggers under the tightened threshold.
python3 -c "
import json
agg = {
    'batch': 99, 'total_transcripts': 50,
    'by_role': {'E': 5, 'A.4': 45}, 'parse_failures': [],
    'e_false_positive_count': 0, 'tricked_count': 1,
    'tool_surface_tricked_count': 1, 'advisory_tricked_count': 0,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")
TRIG_COUNT=$(echo "$OUT" | jq -r '.triggered | length')
assert_equals "1" "$TRIG_COUNT" "tightened tool-surface threshold (max=0) triggers on tool_surface=1"
TRIG_NAME=$(echo "$OUT" | jq -r '.triggered[0].name')
assert_equals "tool_surface_tricked_yes_count" "$TRIG_NAME" "triggered rule named tool_surface_tricked_yes_count"

# -----------------------------------------------------------------------------
# Test 11: advisory_tricked_yes_count uses a SOFT bound (default max=8).
#         A batch with tool_surface=2 (under tight max) + advisory=7 (under soft
#         max) does NOT trigger — replicates the issue #71 batch-5 shape where
#         the legacy combined gate fired spuriously.
# -----------------------------------------------------------------------------
# Restore default thresholds first (Test 10 mutated tool_surface.max to 0).
python3 -c "
import json
cfg = json.load(open('$REPO_ROOT/tools/stop_conditions.json'))
json.dump(cfg, open('$TMP/tools/stop_conditions.json', 'w'), indent=2)
"
python3 -c "
import json
agg = {
    'batch': 99, 'total_transcripts': 50,
    'by_role': {'E': 5, 'A.5': 7, 'A.4': 38}, 'parse_failures': [],
    'e_false_positive_count': 0, 'tricked_count': 9,
    'tool_surface_tricked_count': 2, 'advisory_tricked_count': 7,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")
TRIG_COUNT=$(echo "$OUT" | jq -r '.triggered | length')
assert_equals "0" "$TRIG_COUNT" "split gate: tool_surface=2 (≤2) + advisory=7 (≤8) → no trigger (issue #71 shape)"

# But advisory=9 (over default soft max=8) DOES trigger.
python3 -c "
import json
agg = {
    'batch': 99, 'total_transcripts': 50,
    'by_role': {'E': 5, 'A.5': 9, 'A.4': 36}, 'parse_failures': [],
    'e_false_positive_count': 0, 'tricked_count': 9,
    'tool_surface_tricked_count': 0, 'advisory_tricked_count': 9,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")
TRIG_NAMES=$(echo "$OUT" | jq -r '.triggered[].name' | sort | tr '\n' ',')
assert_contains "$TRIG_NAMES" "advisory_tricked_yes_count" "advisory soft bound triggers above default max=8"

# -----------------------------------------------------------------------------
# Test 12: backward-compat — pre-#71 aggregate.json (no split fields) skips
#          the split rules silently rather than crashing.
# -----------------------------------------------------------------------------
python3 -c "
import json
agg = {
    'batch': 99, 'total_transcripts': 50,
    'by_role': {'E': 5, 'A.4': 45}, 'parse_failures': [],
    'e_false_positive_count': 0, 'tricked_count': 5,
}
json.dump(agg, open('$BATCH_DIR/aggregate.json', 'w'), indent=2)
"
OUT=$(python3 -c "
import os, sys
os.chdir('$TMP')
sys.path.insert(0, 'tools')
import sample_matrix_run as smr
smr.SAMPLE_DIR = '$TMP/runs/matrix-sampled'
smr.STOP_CONDITIONS_PATH = '$TMP/tools/stop_conditions.json'
agg = __import__('json').load(open('$BATCH_DIR/aggregate.json'))
report = smr._evaluate_stop_conditions(99, agg)
import json as _j; print(_j.dumps(report, indent=2))
")
EVAL_COUNT=$(echo "$OUT" | jq -r '.evaluated_count')
assert_equals "2" "$EVAL_COUNT" "pre-#71 aggregate: only e_row + parse_failure evaluated (split rules skipped)"
TRIG_COUNT=$(echo "$OUT" | jq -r '.triggered | length')
assert_equals "0" "$TRIG_COUNT" "pre-#71 aggregate: no rules trigger (split fields absent → silently skipped)"

cd "$REPO_ROOT"
echo ""
