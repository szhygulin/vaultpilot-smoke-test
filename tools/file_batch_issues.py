#!/usr/bin/env python3
"""
tools/file_batch_issues.py — File a batch's issue drafts as GitHub issues.

Reads `runs/matrix-sampled/batch-NN/issues.draft.json` (produced by the
Phase 3.6 / Phase 5 analysis subagent), files each as a GitHub issue via
`gh issue create`, and records the resulting URLs in
`runs/matrix-sampled/batch-NN/issues.md`.

Usage:
  python3 tools/file_batch_issues.py --batch N --repo owner/repo
  python3 tools/file_batch_issues.py --batch N --repo owner/repo --dry-run
  python3 tools/file_batch_issues.py --batch N --repo owner/repo --only 1,3,7
  python3 tools/file_batch_issues.py --batch N --repo owner/repo --exclude 2,4
  python3 tools/file_batch_issues.py --batch N --repo owner/repo \\
      --skill-repo owner/skill-repo --advisory-repo owner/upstream
  python3 tools/file_batch_issues.py --batch N --repo owner/repo \\
      --strict-attribution
  python3 tools/file_batch_issues.py --batch N --repo owner/repo --dedup
  python3 tools/file_batch_issues.py --batch N --repo owner/repo --dedup --on-dup=skip

Routing by `attribution`:
  - mcp-defect              → --repo (required; default destination)
  - skill-defect            → --skill-repo (optional; if absent → unrouted)
  - advisory-injection-shaped, advisory-model-shaped
                            → --advisory-repo (optional; if absent → unrouted)
  - <missing attribution>   → falls back to mcp-defect with a warning, OR
                              hard-skipped if --strict-attribution is set

Unrouted issues are written to `runs/matrix-sampled/batch-NN/advisory-upstream.md`
and NOT filed against any repo. This stops advisory-prose-only findings from
being filed against vaultpilot-mcp by default (per issue #52). To file them
upstream, pass `--advisory-repo <repo>`.

Cross-batch dedup (`--dedup`):
  Matrix runs span ~1000 batches; the same finding class will recur across
  batches. With `--dedup`, the script searches the per-issue target repo's
  open issues via `gh issue list --search "<title-stem>" --state open`
  before filing. A match is declared when the candidate's normalized title
  stem overlaps the draft's stem AND the candidate shares at least one label
  with the draft (when the draft has labels). Search target is the per-issue
  routed repo (mcp-defect → --repo, skill-defect → --skill-repo,
  advisory-* → --advisory-repo) — unrouted issues are not searched.

  On match, behavior is controlled by `--on-dup`:
    - link    (default): post a cross-batch comment on the existing issue
                         with this batch's repro IDs and source link; do not
                         file a new issue.
    - skip              : skip both filing and commenting; just log.
    - file              : ignore the match and file a new issue anyway.
    - prompt            : interactive prompt asking link / file / skip per
                          match (requires a TTY; falls back to `link` if not).

  Decisions are logged to `runs/matrix-sampled/batch-NN/dedup.log` for audit
  whenever `--dedup` is set, regardless of `--dry-run`.

Input schema (`issues.draft.json`):
{
  "batch": 1,
  "source_attribution": "Smoke-test batch-1 ... <free-form>",   # optional
  "issues": [
    {
      "title": "<≤120 chars>",
      "labels": ["security_finding", "tool_gap"],
      "attribution": "mcp-defect",   # optional, default mcp-defect; one of:
                                      #   mcp-defect | skill-defect |
                                      #   advisory-injection-shaped |
                                      #   advisory-model-shaped
                                      # used by orchestrator GATE 2 + dry-run
                                      # display; not rendered in issue body.
      "summary": "1-2 paragraphs of context",
      "repro": "scripts X, Y, Z (free-form)",
      "suggested_fix": "concrete API/behavior change",
      "extra_sections": {                                       # optional
        "Structural risk": "..."
      }
    }
  ]
}

Each filed issue body is assembled in the Phase 6 template:
  ## Summary
  ## Repro
  ## Suggested fix
  [## Structural risk]   (if extra_sections.Structural risk)
  ## Source
  Smoke-test reference + 🤖 Generated with attribution.

Idempotency:
- The script appends to `issues.md` rather than rewriting, so re-running
  with `--only` is safe.
- Pass `--dry-run` to print the planned `gh issue create` calls without
  executing them.

Pre-reqs:
- `gh auth status` clean
- Labels referenced in `issues.draft.json` must exist on the repo (or be
  pre-created via `gh label create`); the script does not auto-create.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SAMPLE_DIR = REPO_ROOT / "runs" / "matrix-sampled"

# Attribution → routing-flag-name. Issues with an attribution outside this map
# (or missing attribution + no --strict-attribution) fall back to mcp-defect.
ATTRIBUTION_TO_FLAG = {
    "mcp-defect": "repo",
    "skill-defect": "skill_repo",
    "advisory-injection-shaped": "advisory_repo",
    "advisory-model-shaped": "advisory_repo",
}
KNOWN_ATTRIBUTIONS = set(ATTRIBUTION_TO_FLAG.keys())

# Cross-batch dedup tunables.
# `--search` returns up to N candidates ranked by GitHub's relevance score; we
# re-filter locally on title-stem overlap + label intersection.
_DEDUP_SEARCH_LIMIT = 30

# Words shorter than this are dropped when extracting a stable search stem; they
# inflate the result set without narrowing it (gh's search is keyword-based).
_DEDUP_MIN_KEYWORD_LEN = 4


def _batch_dir(batch_n: int) -> Path:
    return SAMPLE_DIR / f"batch-{batch_n:02d}"


def _format_body(issue: dict, batch_n: int, source_attribution: str | None) -> str:
    parts = ["## Summary\n", issue["summary"].strip(), "\n\n"]
    parts += ["## Repro\n", issue.get("repro", "").strip() or "(none)", "\n\n"]
    parts += ["## Suggested fix\n", issue.get("suggested_fix", "").strip() or "(none)", "\n\n"]
    for header, body in (issue.get("extra_sections") or {}).items():
        parts += [f"## {header}\n", body.strip(), "\n\n"]
    parts += ["## Source\n"]
    if source_attribution:
        parts += [source_attribution.strip(), "\n\n"]
    else:
        parts += [
            f"Smoke-test batch-{batch_n} (matrix-sampled adversarial run). "
            f"Findings: `runs/matrix-sampled/batch-{batch_n:02d}/findings.md`.\n\n"
        ]
    parts += ["🤖 Generated with [Claude Code](https://claude.com/claude-code)\n"]
    return "".join(parts)


def _route(issue: dict, repos: dict, strict_attribution: bool) -> tuple:
    """Resolve (target_repo, effective_attribution, route_reason) for an issue.

    Returns:
      (target_repo_or_None, effective_attribution, route_reason)
    where:
      target_repo: 'owner/name' if filable, None if unrouted.
      effective_attribution: the attribution label after fallback (used only
          for display/diagnostics).
      route_reason: short string for dry-run output:
          'fallback-mcp-defect' if attribution missing and not strict
          'strict-skip-no-attribution' if --strict-attribution and missing
          'unrouted-no-flag' if attribution maps to an unset flag
          'unknown-attribution' if attribution is non-empty but unrecognized
          'routed' if filing
    """
    attribution = issue.get("attribution")
    if not attribution:
        if strict_attribution:
            return None, "(missing)", "strict-skip-no-attribution"
        # Back-compat: fall back to mcp-defect with a warning printed by caller.
        attribution = "mcp-defect"
        flag = ATTRIBUTION_TO_FLAG[attribution]
        target = repos.get(flag)
        return target, attribution, "fallback-mcp-defect" if target else "unrouted-no-flag"

    flag = ATTRIBUTION_TO_FLAG.get(attribution)
    if flag is None:
        # Attribution string set but not recognized — treat as unrouted with a
        # diagnostic. Do not silently fall back; the analyst should commit to
        # a known label.
        return None, attribution, "unknown-attribution"
    target = repos.get(flag)
    if target is None:
        return None, attribution, "unrouted-no-flag"
    return target, attribution, "routed"


def _title_stem(title: str) -> str:
    """Normalize a title for cross-batch comparison.

    - Lowercase.
    - Strip leading bracketed prefixes ("[A.5a] ", "[batch-12] ").
    - Drop trailing batch references (" (batch 12)", " — batch-12", "(b12)").
    - Collapse whitespace.

    The stem is used for two things: (1) building the `gh issue list --search`
    query, and (2) substring-comparing against returned candidates' stems to
    re-filter relevance-ranked noise.
    """
    s = title.strip().lower()
    # Drop trailing batch refs in any common shape.
    s = re.sub(
        r"\s*[—\-–]?\s*\(?\s*batch[\s\-]*\d+\s*\)?\s*$",
        "",
        s,
    )
    # Drop leading bracketed prefixes.
    s = re.sub(r"^\[[^\]]+\]\s*", "", s)
    # Collapse whitespace.
    s = re.sub(r"\s+", " ", s).strip()
    return s


def _search_query(stem: str) -> str:
    """Reduce a title stem to a keyword query for `gh issue list --search`.

    Strategy: keep tokens that are alphanumeric + length >= _DEDUP_MIN_KEYWORD_LEN,
    cap to 6 tokens to avoid hyper-specific queries that miss close matches.
    Drops common smoke-test boilerplate words ("issue", "smoke") that don't
    narrow the search.
    """
    stop = {
        "issue", "smoke", "with", "from", "this", "that", "when", "what",
        "where", "their", "would", "could", "should",
    }
    tokens = re.findall(r"[a-z0-9_]+", stem)
    keep = [
        t for t in tokens
        if len(t) >= _DEDUP_MIN_KEYWORD_LEN and t not in stop
    ]
    return " ".join(keep[:6])


def _search_existing_issues(repo: str, draft_issue: dict) -> dict | None:
    """Search `repo`'s open issues for one matching `draft_issue`.

    Returns the matched candidate as a dict
    `{"number", "title", "url", "labels": [str, ...]}` on a confident match,
    or None on no match / search failure.

    A match requires:
      - non-empty title-stem overlap (substring either direction), AND
      - non-empty label intersection (when the draft has labels; if the draft
        has none, label-intersection is skipped).
    """
    stem = _title_stem(draft_issue["title"])
    query = _search_query(stem)
    if not query:
        return None
    cmd = [
        "gh", "issue", "list",
        "--repo", repo,
        "--state", "open",
        "--search", query,
        "--json", "number,title,labels,url",
        "--limit", str(_DEDUP_SEARCH_LIMIT),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  ⚠ dedup search failed ({result.stderr.strip()[:120]}); "
              f"falling through to file-new", file=sys.stderr)
        return None
    try:
        candidates = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        print(f"  ⚠ dedup search returned non-JSON; falling through to file-new",
              file=sys.stderr)
        return None
    draft_labels = set(draft_issue.get("labels") or [])
    for c in candidates:
        c_stem = _title_stem(c.get("title", ""))
        if not c_stem:
            continue
        if not (stem in c_stem or c_stem in stem):
            continue
        c_labels = {l["name"] for l in c.get("labels") or []}
        if draft_labels and not (draft_labels & c_labels):
            continue
        return {
            "number": c["number"],
            "title": c["title"],
            "url": c["url"],
            "labels": sorted(c_labels),
        }
    return None


def _format_dedup_comment(
    draft_issue: dict, batch_n: int, source_attribution: str | None,
) -> str:
    """Compose the cross-batch comment body posted to a matched existing issue."""
    parts = [
        f"## Cross-batch dedup\n\n",
        f"This finding class also surfaced in **batch-{batch_n}** "
        f"(matrix-sampled smoke-test run).\n\n",
    ]
    repro = (draft_issue.get("repro") or "").strip()
    if repro:
        parts += ["**This batch's repro:**\n\n", repro, "\n\n"]
    suggested = (draft_issue.get("suggested_fix") or "").strip()
    if suggested:
        parts += ["**Suggested fix (from this batch):**\n\n", suggested, "\n\n"]
    attribution = draft_issue.get("attribution", "mcp-defect")
    parts += [f"**Attribution:** `{attribution}`.\n\n"]
    parts += ["## Source\n"]
    if source_attribution:
        parts += [source_attribution.strip(), "\n\n"]
    else:
        parts += [
            f"Smoke-test batch-{batch_n} (matrix-sampled adversarial run). "
            f"Findings: `runs/matrix-sampled/batch-{batch_n:02d}/findings.md`.\n\n"
        ]
    parts += [
        "🤖 Filed by `tools/file_batch_issues.py --dedup` "
        "(cross-batch dedup hit).\n"
    ]
    return "".join(parts)


def _post_dup_comment(
    repo: str, issue_number: int, body: str, dry_run: bool,
) -> str:
    """Post a comment on `issue_number` in `repo`. Returns URL or sentinel."""
    if dry_run:
        return f"DRY-RUN-COMMENT-#{issue_number}"
    cmd = [
        "gh", "issue", "comment", str(issue_number),
        "--repo", repo,
        "--body", body,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  ✗ dedup-comment FAILED: {result.stderr.strip()[:120]}",
              file=sys.stderr)
        return f"FAILED-COMMENT — {result.stderr.strip()[:80]}"
    return result.stdout.strip()


def _resolve_dup_action(default_action: str, draft_idx: int,
                        draft_title: str, match: dict) -> str:
    """Resolve the on-dup action — `prompt` reads stdin if interactive."""
    if default_action != "prompt":
        return default_action
    if not sys.stdin.isatty():
        # Non-interactive context (CI, background dispatch); prompt is unsafe.
        # Fall back to link, the orchestrator's preferred matrix-run default.
        return "link"
    print(
        f"  [DUP CANDIDATE] draft #{draft_idx} \"{draft_title[:80]}\"\n"
        f"      matches existing #{match['number']} "
        f"\"{match['title'][:80]}\" — {match['url']}"
    )
    while True:
        choice = input("    action? [l]ink / [s]kip / [f]ile / [q]uit: ").strip().lower()
        if choice in ("l", "link"):
            return "link"
        if choice in ("s", "skip"):
            return "skip"
        if choice in ("f", "file"):
            return "file"
        if choice in ("q", "quit"):
            sys.exit("aborted at dedup prompt")


def _file_one(issue: dict, body: str, repo: str, dry_run: bool,
              effective_attribution: str) -> str:
    cmd = [
        "gh", "issue", "create",
        "--repo", repo,
        "--title", issue["title"],
        "--body", body,
    ]
    for label in issue.get("labels", []):
        cmd.extend(["--label", label])
    if dry_run:
        labels_str = ",".join(issue.get("labels", [])) or "—"
        print(f"  [dry-run] [{effective_attribution}] [{labels_str}] "
              f"→ {repo}: {issue['title'][:100]}")
        return f"DRY-RUN-{issue['title'][:40]}"
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  ✗ FAILED: {result.stderr.strip()}", file=sys.stderr)
        return f"FAILED — {result.stderr.strip()[:120]}"
    return result.stdout.strip()


def _print_unrouted(issue: dict, idx: int, total: int,
                    effective_attribution: str, route_reason: str) -> None:
    """Print a one-line skip diagnostic for an unrouted issue."""
    labels_str = ",".join(issue.get("labels", [])) or "—"
    reason_blurb = {
        "unrouted-no-flag": "no destination repo for this attribution",
        "unknown-attribution": "unrecognized attribution label",
        "strict-skip-no-attribution": "missing attribution + --strict-attribution",
    }.get(route_reason, route_reason)
    print(f"  [skip] [{effective_attribution}] [{labels_str}] "
          f"→ unrouted ({reason_blurb}): {issue['title'][:100]}")


def _write_advisory_summary(batch_n: int,
                            unrouted: list,
                            source_attribution: str | None) -> Path:
    """Write/overwrite advisory-upstream.md with the unrouted set.

    Each call rewrites the file (idempotent for re-runs). If `unrouted` is
    empty, the file is removed if present (so a clean run leaves no stale
    state).
    """
    out_path = _batch_dir(batch_n) / "advisory-upstream.md"
    if not unrouted:
        if out_path.exists():
            out_path.unlink()
        return out_path

    lines = [f"# Batch-{batch_n} — unrouted findings (advisory + skill, no destination repo)\n\n"]
    if source_attribution:
        lines.append(f"_Source: {source_attribution.strip()}_\n\n")
    lines.append(
        "These findings were produced by the Phase 5 analyst but were NOT filed "
        "against any GitHub repo. Re-run `tools/file_batch_issues.py` with "
        "`--advisory-repo <repo>` and/or `--skill-repo <repo>` to file them.\n\n"
    )
    lines.append("## Routing rationale\n\n")
    lines.append(
        "- `advisory-injection-shaped` / `advisory-model-shaped`: harmful prose with "
        "no signing-flow traversal (no `prepare_*` / `preview_*` / `send_transaction` "
        "tool call); defense lives at the chat-client output filter or model-layer "
        "safety, not at MCP / skill code. Per CLAUDE.md Smoke-test methodology, "
        "advisory-* findings default to this summary unless `--advisory-repo` is set.\n"
        "- `skill-defect`: cooperating-agent skill rule gap. Files against `--skill-repo` "
        "if set; otherwise listed here.\n"
        "- `unknown-attribution`: analyst emitted a label outside the known set. "
        "Re-run analysis with the canonical labels.\n\n"
    )
    lines.append("| # | attribution | reason | labels | title |\n")
    lines.append("|---|---|---|---|---|\n")
    for entry in unrouted:
        idx, issue, attribution, route_reason = entry
        labels_md = ", ".join(f"`{l}`" for l in issue.get("labels", [])) or "—"
        title_safe = issue["title"].replace("|", "\\|")
        lines.append(
            f"| {idx} | `{attribution}` | `{route_reason}` | {labels_md} | {title_safe} |\n"
        )
    lines.append("\n## Per-finding detail\n\n")
    for entry in unrouted:
        idx, issue, attribution, route_reason = entry
        lines.append(f"### {idx}. {issue['title']}\n\n")
        lines.append(f"- **Attribution:** `{attribution}`\n")
        lines.append(f"- **Route reason:** `{route_reason}`\n")
        labels = issue.get("labels", [])
        if labels:
            lines.append(f"- **Labels:** {', '.join(f'`{l}`' for l in labels)}\n")
        lines.append("\n")
        if issue.get("summary"):
            lines.append(f"**Summary.** {issue['summary'].strip()}\n\n")
        if issue.get("repro"):
            lines.append(f"**Repro.** {issue['repro'].strip()}\n\n")
        if issue.get("suggested_fix"):
            lines.append(f"**Suggested fix.** {issue['suggested_fix'].strip()}\n\n")
        for header, body in (issue.get("extra_sections") or {}).items():
            lines.append(f"**{header}.** {body.strip()}\n\n")

    with out_path.open("w") as f:
        f.write("".join(lines))
    return out_path


def _write_dedup_log(
    batch_n: int, dry_run: bool, on_dup: str, lines: list[str],
) -> None:
    """Write `runs/matrix-sampled/batch-NN/dedup.log` for this --dedup pass.

    Overwrites any prior log for the same batch — the log reflects the most
    recent --dedup invocation rather than accumulating across reruns. Audit
    history lives in git and in the appended issues.md.
    """
    log_path = _batch_dir(batch_n) / "dedup.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    header = (
        f"# dedup.log — batch-{batch_n}\n"
        f"# mode: {'dry-run' if dry_run else 'live'}, on-dup: {on_dup}\n"
        f"# entries: {len(lines)}\n\n"
    )
    log_path.write_text(header + "".join(lines))
    print(f"\nWrote dedup decisions to {log_path} ({len(lines)} entries)")


def _append_to_issues_md(batch_n: int, urls: list[tuple]) -> None:
    """Append the filed-issue table to runs/matrix-sampled/batch-NN/issues.md."""
    md_path = _batch_dir(batch_n) / "issues.md"
    fresh = not md_path.exists()
    with md_path.open("a") as f:
        if fresh:
            f.write(f"# Batch-{batch_n} — issues filed\n\n")
            f.write("| # | Issue | Repo | Labels | Title |\n|---|---|---|---|---|\n")
        for idx, title, url, labels, target_repo in urls:
            labels_md = ", ".join(f"`{l}`" for l in labels) if labels else "—"
            f.write(f"| {idx} | {url} | `{target_repo}` | {labels_md} | {title} |\n")
    print(f"\nAppended {len(urls)} entries to {md_path}")


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--batch", type=int, required=True,
                    help="Batch number (e.g. 1)")
    ap.add_argument("--repo", required=True,
                    help="Target repo for `attribution: mcp-defect` issues "
                         "(e.g. szhygulin/vaultpilot-mcp). Required.")
    ap.add_argument("--skill-repo", default=None,
                    help="Optional target repo for `attribution: skill-defect` "
                         "issues (e.g. szhygulin/vaultpilot-security-skill). "
                         "If unset, skill-defect issues are NOT filed and are "
                         "listed in the unrouted advisory summary.")
    ap.add_argument("--advisory-repo", default=None,
                    help="Optional target repo for `advisory-injection-shaped` / "
                         "`advisory-model-shaped` issues. If unset (default), "
                         "advisory-* issues are NOT filed and are listed in "
                         "`runs/matrix-sampled/batch-NN/advisory-upstream.md`.")
    ap.add_argument("--strict-attribution", action="store_true",
                    help="Refuse to file any issue with no `attribution` field. "
                         "Default is to fall back to mcp-defect (back-compat) "
                         "and print a warning. Strict mode hard-skips and exits "
                         "non-zero, forcing the analyst to commit to a routing.")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print planned gh calls, don't execute. The advisory "
                         "summary file is NOT written under --dry-run.")
    ap.add_argument("--only", default=None,
                    help="Comma-separated 1-based indices to file (e.g. '1,3,5'); "
                         "default: all")
    ap.add_argument("--exclude", default=None,
                    help="Comma-separated 1-based indices to skip (e.g. '2,4'); "
                         "default: none. Mutually exclusive with --only.")
    ap.add_argument("--dedup", action="store_true",
                    help="Search each issue's routed target repo for matching "
                         "title-stem + labels before filing. Default off "
                         "(preserves legacy behavior). Unrouted issues are not "
                         "searched.")
    ap.add_argument("--on-dup", default="link",
                    choices=("link", "skip", "file", "prompt"),
                    help="Action on dedup match: link a comment to the existing "
                         "issue (default), skip filing entirely, file a new "
                         "issue anyway, or interactively prompt per match.")
    args = ap.parse_args()

    draft_path = _batch_dir(args.batch) / "issues.draft.json"
    if not draft_path.exists():
        sys.exit(f"draft not found: {draft_path}\n"
                 f"the analysis subagent must produce this file as part of "
                 f"Phase 3.6 (per CLAUDE.md Smoke-test methodology section)")

    draft = json.loads(draft_path.read_text())
    issues = draft.get("issues", [])
    if not issues:
        sys.exit("no issues in draft")

    only_set = None
    if args.only:
        only_set = {int(x.strip()) for x in args.only.split(",") if x.strip()}

    exclude_set = set()
    if args.exclude:
        exclude_set = {int(x.strip()) for x in args.exclude.split(",") if x.strip()}

    if only_set and exclude_set:
        sys.exit("error: --only and --exclude are mutually exclusive")

    repos = {
        "repo": args.repo,
        "skill_repo": args.skill_repo,
        "advisory_repo": args.advisory_repo,
    }

    # Pre-pass: classify every issue.
    plan = []  # list of (idx, issue, target_repo_or_None, effective_attribution, route_reason)
    fallback_warnings = []
    for i, issue in enumerate(issues, start=1):
        if only_set and i not in only_set:
            continue
        if i in exclude_set:
            continue
        target, eff_attr, reason = _route(issue, repos, args.strict_attribution)
        plan.append((i, issue, target, eff_attr, reason))
        if reason == "fallback-mcp-defect":
            fallback_warnings.append(i)

    routed = [p for p in plan if p[2] is not None]
    unrouted = [p for p in plan if p[2] is None]
    strict_skips = [p for p in unrouted if p[4] == "strict-skip-no-attribution"]

    print(f"Filing {len(routed)} of {len(issues)} draft issues "
          f"({len(unrouted)} unrouted)"
          f"{' (DRY-RUN)' if args.dry_run else ''}")
    print(f"  --repo (mcp-defect):     {args.repo}")
    print(f"  --skill-repo:            {args.skill_repo or '(unset, skill-defect → unrouted)'}")
    print(f"  --advisory-repo:         {args.advisory_repo or '(unset, advisory-* → unrouted)'}")
    if args.strict_attribution:
        print(f"  --strict-attribution:    on (missing-attribution issues will be skipped)")
    if args.dedup:
        print(f"  --dedup:                 on (on-dup={args.on_dup})")
    if fallback_warnings:
        print(f"  WARNING: {len(fallback_warnings)} issue(s) with no `attribution` "
              f"field; falling back to mcp-defect "
              f"(indices: {','.join(str(i) for i in fallback_warnings)}). "
              f"Re-run with --strict-attribution to refuse instead.", file=sys.stderr)
    print()

    urls = []
    dedup_log_lines: list[str] = []
    for idx, issue, target, eff_attr, reason in plan:
        if target is None:
            _print_unrouted(issue, idx, len(issues), eff_attr, reason)
            continue
        body = _format_body(issue, args.batch, draft.get("source_attribution"))
        print(f"[{idx}/{len(issues)}] {issue['title'][:80]}")

        match = None
        action = "file"
        if args.dedup:
            match = _search_existing_issues(target, issue)
            if match:
                action = _resolve_dup_action(
                    args.on_dup, idx, issue["title"], match,
                )
                marker = "[would]" if args.dry_run else "[acting]"
                print(
                    f"  ⤷ {marker} dedup match: "
                    f"#{match['number']} \"{match['title'][:60]}\" "
                    f"→ action={action}"
                )
                dedup_log_lines.append(
                    f"[{idx}] {issue['title']}\n"
                    f"    → MATCH #{match['number']} {match['url']} "
                    f"(action: {action})\n"
                )
            else:
                dedup_log_lines.append(
                    f"[{idx}] {issue['title']}\n"
                    f"    → NO MATCH (action: file)\n"
                )

        if match and action == "skip":
            url = f"SKIPPED-DUP-#{match['number']}"
            print(f"  ⤷ skipped (dup of #{match['number']})")
        elif match and action == "link":
            comment_body = _format_dedup_comment(
                issue, args.batch, draft.get("source_attribution"),
            )
            comment_url = _post_dup_comment(
                target, match["number"], comment_body, args.dry_run,
            )
            url = f"LINKED-#{match['number']} {comment_url}"
            if not comment_url.startswith("FAILED"):
                print(f"  ✓ linked dup comment on #{match['number']} → {comment_url}")
        else:
            # action == "file" (no match, or --on-dup=file overrides)
            url = _file_one(issue, body, target, args.dry_run, eff_attr)
            if url and not url.startswith("FAILED"):
                print(f"  ✓ {url}")
        urls.append((idx, issue["title"], url, issue.get("labels", []), target))

    print("\n=== Summary ===")
    for idx, title, url, labels, target in urls:
        labels_str = ",".join(labels) if labels else "—"
        print(f"  #{idx}  {url}  [{target}]  [{labels_str}]  {title[:80]}")
    if unrouted:
        print(f"\n=== Unrouted ({len(unrouted)}) ===")
        for idx, issue, _, eff_attr, reason in unrouted:
            print(f"  #{idx}  [{eff_attr}]  ({reason})  {issue['title'][:80]}")

    if args.dedup:
        _write_dedup_log(args.batch, args.dry_run, args.on_dup, dedup_log_lines)

    # Write advisory-upstream.md unless this is a dry-run.
    # We pass ALL unrouted findings (advisory-* + skill-defect-without-flag +
    # unknown-attribution + strict-skip) so the user has one place to inspect
    # what was held back.
    if not args.dry_run:
        unrouted_records = [
            (idx, issue, eff_attr, reason)
            for idx, issue, _, eff_attr, reason in unrouted
        ]
        adv_path = _write_advisory_summary(
            args.batch, unrouted_records, draft.get("source_attribution")
        )
        if unrouted_records:
            print(f"\nWrote {len(unrouted_records)} unrouted finding(s) to {adv_path}")
        if urls:
            _append_to_issues_md(args.batch, urls)

    if strict_skips:
        # Force the analyst to commit to a routing on the next run.
        print(f"\nERROR: {len(strict_skips)} issue(s) skipped under "
              f"--strict-attribution (no `attribution` field set). "
              f"Re-run analysis with attribution committed.", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
