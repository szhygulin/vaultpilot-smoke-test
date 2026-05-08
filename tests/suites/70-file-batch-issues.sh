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

# ---------------------------------------------------------------------------
# Tests 6–10: cross-batch dedup (--dedup + --on-dup).
#
# We mock `gh` by prepending a fake binary on PATH. The mock handles only
# `gh issue list`, returning the contents of $GH_MOCK_LIST_RESPONSE, and is
# inert for `gh issue create` / `gh issue comment` (these are gated by
# --dry-run, which short-circuits both code paths before any subprocess call).
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'MOCK_GH'
#!/bin/bash
# Mock gh binary for tests/suites/70-file-batch-issues.sh — exercises the
# --dedup path without touching real GitHub. Reads canned JSON response from
# $GH_MOCK_LIST_RESPONSE; defaults to an empty array when unset.
if [[ "$1" == "issue" && "$2" == "list" ]]; then
  if [[ -n "${GH_MOCK_LIST_RESPONSE:-}" && -f "$GH_MOCK_LIST_RESPONSE" ]]; then
    cat "$GH_MOCK_LIST_RESPONSE"
  else
    echo "[]"
  fi
  exit 0
fi
echo "MOCK GH: unsupported command in dedup tests: $*" >&2
exit 1
MOCK_GH
chmod +x "$TMP/bin/gh"
ORIG_PATH="$PATH"
export PATH="$TMP/bin:$PATH"

# Canned dedup-match payload: one open issue whose title-stem overlaps draft
# #1 ("missing intent-layer refusal on prepare_custom_call") AND shares the
# `security_finding` label.
cat > "$TMP/match-payload.json" <<'PAYLOAD'
[
  {
    "number": 9001,
    "title": "Missing intent-layer refusal on prepare_custom_call",
    "url": "https://github.com/synth/repo/issues/9001",
    "labels": [{"name": "security_finding"}, {"name": "skill_finding"}]
  }
]
PAYLOAD

# Canned no-match payload: candidate share label but title-stem disjoint.
cat > "$TMP/nomatch-payload.json" <<'PAYLOAD'
[
  {
    "number": 7777,
    "title": "Wholly unrelated finding about Solana fee accounting",
    "url": "https://github.com/synth/repo/issues/7777",
    "labels": [{"name": "security_finding"}]
  }
]
PAYLOAD

# Test 6: --dedup with a match + default --on-dup=link → suppresses new filing,
# would-link in dry-run, dedup.log records MATCH.
rm -f runs/matrix-sampled/batch-99/dedup.log
set +e
OUT=$(GH_MOCK_LIST_RESPONSE="$TMP/match-payload.json" \
      python3 tools/file_batch_issues.py --batch 99 --repo synth/repo \
      --dry-run --dedup --only 1 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "--dedup match + link → exit 0"
assert_contains "$OUT" "dedup match: #9001" "match #9001 surfaced"
assert_contains "$OUT" "action=link" "default action is link"
assert_contains "$OUT" "DRY-RUN-COMMENT-#9001" "dry-run comment placeholder rendered"
assert_not_contains "$OUT" "[dry-run] [mcp-defect]" \
    "no fresh issue create line on dedup hit"
assert_file_exists "runs/matrix-sampled/batch-99/dedup.log" "dedup.log written"
assert_file_contains "runs/matrix-sampled/batch-99/dedup.log" \
    "MATCH #9001" "dedup.log records the match"
assert_file_contains "runs/matrix-sampled/batch-99/dedup.log" \
    "mode: dry-run, on-dup: link" "dedup.log header records mode + on-dup"

# Test 7: --dedup with no match → falls through to normal filing, dedup.log
# records NO MATCH for that draft.
rm -f runs/matrix-sampled/batch-99/dedup.log
set +e
OUT=$(GH_MOCK_LIST_RESPONSE="$TMP/nomatch-payload.json" \
      python3 tools/file_batch_issues.py --batch 99 --repo synth/repo \
      --dry-run --dedup --only 1 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "--dedup no-match → exit 0"
assert_not_contains "$OUT" "dedup match:" "no match line printed"
assert_contains "$OUT" "[dry-run] [mcp-defect]" \
    "fresh issue create line still printed on no-match"
assert_file_contains "runs/matrix-sampled/batch-99/dedup.log" \
    "NO MATCH" "dedup.log records no-match for #1"

# Test 8: --dedup --on-dup=skip with a match → skip without commenting.
rm -f runs/matrix-sampled/batch-99/dedup.log
set +e
OUT=$(GH_MOCK_LIST_RESPONSE="$TMP/match-payload.json" \
      python3 tools/file_batch_issues.py --batch 99 --repo synth/repo \
      --dry-run --dedup --on-dup skip --only 1 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "--dedup --on-dup=skip → exit 0"
assert_contains "$OUT" "action=skip" "skip action wired"
assert_contains "$OUT" "skipped (dup of #9001)" "skip message rendered"
assert_not_contains "$OUT" "DRY-RUN-COMMENT" "no comment in skip mode"
assert_not_contains "$OUT" "[dry-run] [mcp-defect]" \
    "no fresh issue created in skip mode"
assert_file_contains "runs/matrix-sampled/batch-99/dedup.log" \
    "action: skip" "dedup.log records skip action"

# Test 9: --dedup --on-dup=file with a match → file new issue anyway.
rm -f runs/matrix-sampled/batch-99/dedup.log
set +e
OUT=$(GH_MOCK_LIST_RESPONSE="$TMP/match-payload.json" \
      python3 tools/file_batch_issues.py --batch 99 --repo synth/repo \
      --dry-run --dedup --on-dup file --only 1 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "--dedup --on-dup=file → exit 0"
assert_contains "$OUT" "action=file" "file action wired"
assert_contains "$OUT" "[dry-run] [mcp-defect]" \
    "fresh issue create line printed despite match"

# Test 10: gh-search failure (mock returns non-zero) → falls through to
# file-new with stderr warning, no match recorded.
cat > "$TMP/bin/gh" <<'MOCK_GH_FAIL'
#!/bin/bash
echo "synthetic gh failure" >&2
exit 1
MOCK_GH_FAIL
chmod +x "$TMP/bin/gh"
rm -f runs/matrix-sampled/batch-99/dedup.log
set +e
OUT=$(python3 tools/file_batch_issues.py --batch 99 --repo synth/repo \
      --dry-run --dedup --only 1 2>&1)
EC=$?
set -e
assert_exit_code 0 "$EC" "gh-search failure → exit 0 (graceful fall-through)"
assert_contains "$OUT" "dedup search failed" "search failure surfaced"
assert_contains "$OUT" "[dry-run] [mcp-defect]" \
    "fall-through files the new issue"
assert_file_contains "runs/matrix-sampled/batch-99/dedup.log" \
    "NO MATCH" "search-fail logs NO MATCH (no candidate returned)"

# Restore PATH so subsequent suites don't see the mock gh.
export PATH="$ORIG_PATH"

cd "$REPO_ROOT"
echo ""
