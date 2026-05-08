#!/bin/bash
# .claude/hooks/preflight_gate.sh — PreToolUse hook for Agent calls.
#
# Blocks Agent dispatches during smoke-test batches that have NOT been
# explicitly confirmed by the user. The user confirms by surfacing the cost
# preflight, getting an explicit "go", then running:
#   python3 tools/sample_matrix_run.py confirm-batch --batch NN
# That subcommand writes a CONTENT-BOUND JSON stamp at
# runs/matrix-sampled/batch-NN/.preflight-confirmed binding the confirmation
# to a sha256 of (scripts.json || progress[batch-N entry]) plus a confirmedAt
# timestamp. This hook re-runs the binding via `verify-stamp`, which:
#   - rejects stamps with content drift (scripts.json or progress entry changed
#     between confirm-time and dispatch-time),
#   - rejects stamps older than PREFLIGHT_TTL_HOURS (default 6h),
#   - rejects legacy presence-only stamps (empty file, missing batchHash).
#
# Single point of truth for the hash recipe: tools/sample_matrix_run.py's
# `_compute_batch_hash`. Both confirm-batch and verify-stamp call it. This
# hook delegates to that helper rather than reimplementing the recipe in
# bash — drift between two recipes would silently re-introduce the gap.
#
# Exit codes:
#   0 — let the Agent call through (no smoke-test batch in progress, OR
#       stamp is valid + content-bound + within TTL).
#   1 — block the Agent call and surface the reason via stderr.
#
# How it integrates with the rest of the pipeline:
#   - tools/sample_matrix_run.py next-batch  →  marks a batch in_progress.
#   - /run-batch slash command surfaces preflight, asks user, on OK runs:
#       python3 tools/sample_matrix_run.py confirm-batch --batch NN
#   - This hook runs before every `Agent` tool call. Reads progress.json,
#     finds the in-progress batch, calls verify-stamp on it.
#   - When the batch completes (mark-completed), the next batch's preflight
#     is required again. Stamps are per-batch.
#
# Trade-off (documented in CLAUDE.md): this hook fires on EVERY Agent call
# while a batch is in_progress, including non-smoke-test ones. If you need
# a non-smoke-test Agent call mid-batch, complete or pause the batch first
# (delete the stamp + reset progress.json's in_progress entry).

set -euo pipefail

progress="runs/matrix-sampled/progress.json"

# No partition yet → no smoke test in flight → let through.
if [[ ! -f "$progress" ]]; then
    exit 0
fi

# Pick the first in_progress batch. If none, no gate to enforce.
batch=$(jq -r '.batches[]? | select(.status=="in_progress") | .batch' "$progress" 2>/dev/null | head -1)
if [[ -z "$batch" ]]; then
    exit 0
fi

pad=$(printf '%02d' "$batch")
stamp="runs/matrix-sampled/batch-${pad}/.preflight-confirmed"

# Delegate to the Python helper for content-bound verification. It owns the
# hash recipe + TTL logic; bash side just propagates the verdict.
verify_err=$(mktemp)
trap 'rm -f "$verify_err"' EXIT
if python3 tools/sample_matrix_run.py verify-stamp \
        --batch "$batch" --quiet 2>"$verify_err"; then
    exit 0
fi

reason=$(cat "$verify_err" 2>/dev/null || echo "(no reason emitted)")

cat >&2 <<EOF
BLOCKED by .claude/hooks/preflight_gate.sh:
  batch ${batch} is in_progress but the preflight stamp at ${stamp} did not
  verify against current state.

Reason from verify-stamp:
${reason}

To proceed:
  1. Surface the cost preflight (Phase 2.5) to the user.
  2. Get an explicit OK on this specific batch.
  3. Run: python3 tools/sample_matrix_run.py confirm-batch --batch ${batch}
  4. Retry the Agent call.

To bypass (non-smoke-test Agent work mid-batch):
  - Complete or pause the batch: jq '.batches[] |= (if .status=="in_progress" then .status="paused" else . end)' ${progress} > /tmp/p.json && mv /tmp/p.json ${progress}
  - Or delete the stamp file when done: rm ${stamp}

This hook exists because CLAUDE.md mandates per-batch cost-preflight
confirmation, and prior runs (batch-2 in this repo) showed the orchestrator
can mentally skip the gate. The hook physically prevents that. Stamp content-
binding (issue #54) prevents the hook from being satisfied by stale or
drifted confirmations — see tools/sample_matrix_run.py's _compute_batch_hash.
EOF
exit 1
