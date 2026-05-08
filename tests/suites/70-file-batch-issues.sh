#!/bin/bash
# 70-file-batch-issues.sh — exercises tools/file_batch_issues.py.
# Verifies:
#   - Default --dry-run with only --repo files mcp-defect; advisory-* unrouted;
#     missing-attribution falls back to mcp-defect with a warning
#   - --advisory-repo routes advisory-* to the upstream repo
#   - --skill-repo routes skill-defect (synth fixture has no skill-defect, so
#     this is exercised via a second fixture that includes one)
#   - --strict-attribution + missing-attribution issue → exit 2, skipped
#   - --exclude N,M skips those indices and adjusts the count
#   - --only and --exclude together → exit 1 (mutually exclusive)
#   - advisory-upstream.md is written outside --dry-run when there are
#     unrouted findings, and removed when there are none
#   - Out-of-range --exclude indices don't crash (no-op)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/helpers.sh"

echo ""
echo "=== Suite 70: file-batch-issues ==="

TMP=$(mktempdir)
trap 'cleanup_tempdir "$TMP"' EXIT

# Stage a temp REPO_ROOT — file_batch_issues.py computes REPO_ROOT from its
# own __file__ location, so copying it to $TMP/tools/ makes $TMP the resolved
# REPO_ROOT and runs/matrix-sampled/batch-99/ resolves under $TMP.
mkdir -p "$TMP/tools" "$TMP/runs/matrix-sampled/batch-99"
cp "$REPO_ROOT/tools/file_batch_issues.py" "$TMP/tools/"
cp "$REPO_ROOT/tests/fixtures/file-batch-issues/issues.draft.json" \
   "$TMP/runs/matrix-sampled/batch-99/issues.draft.json"

cd "$TMP"

# Test 1: plain --dry-run with only --repo
#   Fixture has 3 issues: mcp-defect, advisory-injection-shaped, no-attribution.
#   - #1 (mcp-defect)   → routed to synth/repo
#   - #2 (advisory-*)   → unrouted (no --advisory-repo)
#   - #3 (no attr)      → fallback to mcp-defect, routed to synth/repo + warning
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 99 --repo synth/repo --dry-run 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "plain --dry-run → exit 0"
assert_contains "$OUT" "Filing 2 of 3" "advisory-* unrouted by default → 2 of 3"
assert_contains "$OUT" "[mcp-defect]" "issue #1 attribution rendered"
assert_contains "$OUT" "[advisory-injection-shaped]" "issue #2 attribution rendered"
assert_contains "$OUT" "[skip]" "issue #2 marked as [skip]"
assert_contains "$OUT" "Synth issue #1" "issue #1 title rendered"
assert_contains "$OUT" "Synth issue #3" "issue #3 title rendered (back-compat)"
assert_contains "$OUT" "WARNING" "missing-attribution warning emitted"
assert_contains "$OUT" "fall" "warning explains fallback to mcp-defect"
DRY_LINE_COUNT=$(echo "$OUT" | grep -c "\[dry-run\]" || true)
assert_equals "2" "$DRY_LINE_COUNT" "exactly 2 [dry-run] lines (#1 + #3 fallback)"
SKIP_LINE_COUNT=$(echo "$OUT" | grep -c "\[skip\]" || true)
assert_equals "1" "$SKIP_LINE_COUNT" "exactly 1 [skip] line (#2 advisory)"

# Test 1b: advisory-upstream.md is NOT written under --dry-run
assert_file_not_exists "runs/matrix-sampled/batch-99/advisory-upstream.md" \
    "advisory-upstream.md absent under --dry-run"

# Test 2: --advisory-repo routes advisory-* upstream
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 99 --repo synth/repo \
        --advisory-repo synth/upstream --dry-run 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "--advisory-repo → exit 0"
assert_contains "$OUT" "Filing 3 of 3" "advisory-* now routed → 3 of 3"
assert_contains "$OUT" "→ synth/upstream" "advisory issue routed to upstream repo"
assert_contains "$OUT" "→ synth/repo" "mcp-defect issue routed to --repo"

# Test 3: --exclude 2,3 skips those, files only #1 (advisory + no-attr both excluded)
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 99 --repo synth/repo --dry-run --exclude 2,3 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "--exclude 2,3 → exit 0"
assert_contains "$OUT" "Filing 1 of 3" "dry-run reports filing 1 of 3 with --exclude 2,3"
assert_contains "$OUT" "Synth issue #1" "non-excluded issue #1 still printed"
assert_not_contains "$OUT" "Synth issue #2" "excluded issue #2 absent"
assert_not_contains "$OUT" "Synth issue #3" "excluded issue #3 absent"

# Test 4: --only and --exclude together → exit 1
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 99 --repo synth/repo --dry-run --only 1 --exclude 2 2>&1)
EC=$?
set -e
assert_exit_code 1 "$EC" "--only + --exclude → exit 1"
assert_contains "$OUT" "mutually exclusive" "stderr explains mutual exclusivity"

# Test 5: --strict-attribution + missing-attribution issue → exit 2, #3 skipped
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 99 --repo synth/repo \
        --strict-attribution --dry-run 2>&1)
EC=$?
set -e
assert_exit_code 2 "$EC" "--strict-attribution + missing → exit 2"
assert_contains "$OUT" "Filing 1 of 3" "strict mode: only mcp-defect #1 files"
assert_contains "$OUT" "strict-skip-no-attribution" "strict-skip reason in [skip] line"
assert_contains "$OUT" "ERROR" "strict mode prints ERROR summary"

# Test 6: out-of-range --exclude doesn't crash
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 99 --repo synth/repo --dry-run --exclude 99 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "--exclude 99 (out-of-range) → exit 0"
assert_contains "$OUT" "Filing 2 of 3" "out-of-range exclude is a no-op (still 2 routed)"

# Test 7: --skill-repo routes skill-defect — separate fixture with skill-defect entry
mkdir -p "$TMP/runs/matrix-sampled/batch-98"
cat > "$TMP/runs/matrix-sampled/batch-98/issues.draft.json" <<'EOF'
{
  "batch": 98,
  "issues": [
    {"title": "Skill issue", "labels": [], "attribution": "skill-defect",
     "summary": "synth", "repro": "synth", "suggested_fix": "synth"},
    {"title": "MCP issue", "labels": [], "attribution": "mcp-defect",
     "summary": "synth", "repro": "synth", "suggested_fix": "synth"}
  ]
}
EOF

# 7a: without --skill-repo, skill-defect is unrouted
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 98 --repo synth/repo --dry-run 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "skill without --skill-repo → exit 0"
assert_contains "$OUT" "Filing 1 of 2" "skill-defect unrouted by default → 1 of 2"
assert_contains "$OUT" "[skill-defect]" "skill-defect attribution rendered"
assert_contains "$OUT" "skill-defect" "skill-defect mentioned"

# 7b: with --skill-repo, skill-defect routes
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 98 --repo synth/repo \
        --skill-repo synth/skill --dry-run 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "skill with --skill-repo → exit 0"
assert_contains "$OUT" "Filing 2 of 2" "skill routed → 2 of 2"
assert_contains "$OUT" "→ synth/skill" "skill issue routed to skill repo"

# Test 8: advisory-upstream.md written when running for real (not --dry-run)
# Use a fixture-only path: GH_TOKEN unset + --dry-run-style trick won't work
# because we need the side-effect of advisory-upstream.md being written, which
# only happens in non-dry-run. We synthesize a "no advisory" fixture so no real
# `gh` call is made, then verify the file is removed/absent.
mkdir -p "$TMP/runs/matrix-sampled/batch-97"
cat > "$TMP/runs/matrix-sampled/batch-97/issues.draft.json" <<'EOF'
{
  "batch": 97,
  "issues": [
    {"title": "Advisory issue", "labels": [], "attribution": "advisory-injection-shaped",
     "summary": "synth", "repro": "synth", "suggested_fix": "synth"}
  ]
}
EOF
# This batch has only an advisory-* issue and no --advisory-repo, so nothing
# files (no `gh` call) but advisory-upstream.md SHOULD be written.
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 97 --repo synth/repo 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "all-advisory batch (no gh call) → exit 0"
assert_contains "$OUT" "Filing 0 of 1" "all-advisory → 0 routed"
assert_file_exists "runs/matrix-sampled/batch-97/advisory-upstream.md" \
    "advisory-upstream.md written for unrouted advisory finding"
assert_file_contains "runs/matrix-sampled/batch-97/advisory-upstream.md" \
    "Advisory issue" "advisory-upstream.md includes the unrouted title"
assert_file_contains "runs/matrix-sampled/batch-97/advisory-upstream.md" \
    "advisory-injection-shaped" "advisory-upstream.md includes the attribution"

cd "$REPO_ROOT"
echo ""
