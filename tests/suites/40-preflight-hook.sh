#!/bin/bash
# 40-preflight-hook.sh — exercises .claude/hooks/preflight_gate.sh.
# Verifies:
#   - No progress.json → exit 0 (passthrough)
#   - In-progress batch, no stamp → exit 1 with stderr message
#   - In-progress batch, valid content-bound stamp → exit 0
#   - Drift detection: scripts.json mutated after confirm → exit 1
#   - Drift detection: progress entry mutated after confirm → exit 1
#   - Legacy presence-only stamp (empty file) → exit 1
#   - TTL: stamp older than PREFLIGHT_TTL_HOURS → exit 1
#   - Batch in 'paused' / 'completed' status → exit 0 (no in_progress to gate)
#   - Stderr message includes the stamp path
#
# Layout: each test cds into a fresh tempdir that contains a `tools/` symlink
# to the real repo's tools/ (so `python3 tools/sample_matrix_run.py` resolves)
# and exports SAMPLE_MATRIX_REPO_ROOT=$TMP so the Python helper reads the
# tempdir's progress.json + scripts.json instead of the real ones.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"

echo ""
echo "=== Suite 40: preflight hook (content-bound) ==="

HOOK="$REPO_ROOT/.claude/hooks/preflight_gate.sh"
assert_file_exists "$HOOK" "hook script exists"

TMP=$(mktempdir)
trap 'cleanup_tempdir "$TMP"' EXIT

# Bridge tools/ into the tempdir so `python3 tools/sample_matrix_run.py` resolves.
# SAMPLE_MATRIX_REPO_ROOT redirects the Python helper at the tempdir's
# runs/matrix-sampled/ (where the test fixtures live).
ln -sfn "$REPO_ROOT/tools" "$TMP/tools"
export SAMPLE_MATRIX_REPO_ROOT="$TMP"

# Helper: write a synthetic scripts.json so _compute_batch_hash can read it.
write_synth_scripts() {
    local path="$1" batch_n="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<JSON
{
  "_comment": "synthetic test scripts for batch ${batch_n}",
  "batch": ${batch_n},
  "addressBook": {},
  "roleLegend": {},
  "scripts": [{"id": "synth-001", "audience": "expert", "row_id": "synth-001", "role": "A.4", "category": "send_native", "chain": "ethereum", "script": "test", "attack": "test"}]
}
JSON
}

# Test 1: no progress.json → exit 0
cd "$TMP"
set +e
"$HOOK" >/dev/null 2>&1
EC=$?
set -e
assert_exit_code 0 "$EC" "no progress.json → exit 0 (passthrough)"

# Test 2: in_progress batch, no stamp → exit 1
write_synth_progress "$TMP/runs/matrix-sampled/progress.json" 99 in_progress
write_synth_scripts "$TMP/runs/matrix-sampled/batch-99/scripts.json" 99
set +e
STDERR=$("$HOOK" 2>&1 >/dev/null)
EC=$?
set -e
assert_exit_code 1 "$EC" "in_progress, no stamp → exit 1"
assert_contains "$STDERR" "BLOCKED" "stderr starts with BLOCKED"
assert_contains "$STDERR" "batch 99" "stderr names the batch"
assert_contains "$STDERR" "runs/matrix-sampled/batch-99/.preflight-confirmed" "stderr names the stamp path"
assert_contains "$STDERR" "confirm-batch" "stderr instructs to run confirm-batch (not bare touch)"

# Test 3: in_progress batch, content-bound stamp → exit 0
python3 tools/sample_matrix_run.py confirm-batch --batch 99 >/dev/null
set +e
"$HOOK" >/dev/null 2>&1
EC=$?
set -e
assert_exit_code 0 "$EC" "in_progress, content-bound stamp → exit 0"

# Test 4: scripts.json mutated after confirm → drift detected → exit 1
echo "// drift" >> "$TMP/runs/matrix-sampled/batch-99/scripts.json"
set +e
STDERR=$("$HOOK" 2>&1 >/dev/null)
EC=$?
set -e
assert_exit_code 1 "$EC" "scripts.json drift after confirm → exit 1"
assert_contains "$STDERR" "drift detected" "stderr names content drift"

# Restore scripts.json + reconfirm for next tests
write_synth_scripts "$TMP/runs/matrix-sampled/batch-99/scripts.json" 99
python3 tools/sample_matrix_run.py confirm-batch --batch 99 >/dev/null
set +e
"$HOOK" >/dev/null 2>&1
EC=$?
set -e
assert_exit_code 0 "$EC" "post-restore + reconfirm → exit 0"

# Test 5: progress entry mutated after confirm → drift detected → exit 1
# Mutate started_at — simulates next-batch being re-invoked on a reset batch.
python3 - <<'PY'
import json, os
path = os.path.join(os.environ['SAMPLE_MATRIX_REPO_ROOT'],
                    'runs/matrix-sampled/progress.json')
with open(path) as f:
    data = json.load(f)
for b in data['batches']:
    if b['batch'] == 99:
        b['started_at'] = '2099-12-31T23:59:59Z'
with open(path, 'w') as f:
    json.dump(data, f)
PY
set +e
STDERR=$("$HOOK" 2>&1 >/dev/null)
EC=$?
set -e
assert_exit_code 1 "$EC" "progress entry drift after confirm → exit 1"
assert_contains "$STDERR" "drift detected" "stderr names content drift on progress mutation"

# Restore progress + reconfirm
write_synth_progress "$TMP/runs/matrix-sampled/progress.json" 99 in_progress
python3 tools/sample_matrix_run.py confirm-batch --batch 99 >/dev/null
set +e
"$HOOK" >/dev/null 2>&1
EC=$?
set -e
assert_exit_code 0 "$EC" "post-restore-progress + reconfirm → exit 0"

# Test 6: legacy presence-only stamp (empty file) → exit 1
> "$TMP/runs/matrix-sampled/batch-99/.preflight-confirmed"
set +e
STDERR=$("$HOOK" 2>&1 >/dev/null)
EC=$?
set -e
assert_exit_code 1 "$EC" "legacy empty stamp → exit 1"
assert_contains "$STDERR" "not valid JSON" "stderr names malformed JSON for legacy stamp"

# Reconfirm; now test TTL.
python3 tools/sample_matrix_run.py confirm-batch --batch 99 >/dev/null
set +e
"$HOOK" >/dev/null 2>&1
EC=$?
set -e
assert_exit_code 0 "$EC" "post-reconfirm → exit 0 (default TTL)"

# Test 7: TTL exceeded → exit 1.
# Mutate confirmedAt to far in the past while keeping batchHash intact, so
# the hash check still passes and the TTL check is the sole rejector.
python3 - <<'PY'
import json, os
path = os.path.join(os.environ['SAMPLE_MATRIX_REPO_ROOT'],
                    'runs/matrix-sampled/batch-99/.preflight-confirmed')
with open(path) as f:
    data = json.load(f)
assert data.get('batchHash'), 'batchHash should be present pre-edit'
data['confirmedAt'] = '2020-01-01T00:00:00Z'
with open(path, 'w') as f:
    json.dump(data, f)
PY
set +e
STDERR=$(PREFLIGHT_TTL_HOURS=0.001 "$HOOK" 2>&1 >/dev/null)
EC=$?
set -e
assert_exit_code 1 "$EC" "TTL exceeded → exit 1"
assert_contains "$STDERR" "older than" "stderr names TTL expiry"

# TTL=0 disables → exit 0 with the same stale stamp
set +e
PREFLIGHT_TTL_HOURS=0 "$HOOK" >/dev/null 2>&1
EC=$?
set -e
assert_exit_code 0 "$EC" "TTL=0 disables expiry → exit 0"

# Restore default state for status tests below.
python3 tools/sample_matrix_run.py confirm-batch --batch 99 >/dev/null

# Test 8: batch in 'paused' status → exit 0 (no in_progress to gate)
write_synth_progress "$TMP/runs/matrix-sampled/progress.json" 99 paused
rm -f "$TMP/runs/matrix-sampled/batch-99/.preflight-confirmed"  # ensure no stamp
set +e
"$HOOK" >/dev/null 2>&1
EC=$?
set -e
assert_exit_code 0 "$EC" "paused status → exit 0 (gate doesn't apply)"

# Test 9: batch in 'completed' status → exit 0
write_synth_progress "$TMP/runs/matrix-sampled/progress.json" 99 completed
set +e
"$HOOK" >/dev/null 2>&1
EC=$?
set -e
assert_exit_code 0 "$EC" "completed status → exit 0"

cd "$REPO_ROOT"
echo ""
