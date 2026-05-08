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
    if fallback_warnings:
        print(f"  WARNING: {len(fallback_warnings)} issue(s) with no `attribution` "
              f"field; falling back to mcp-defect "
              f"(indices: {','.join(str(i) for i in fallback_warnings)}). "
              f"Re-run with --strict-attribution to refuse instead.", file=sys.stderr)
    print()

    urls = []
    for idx, issue, target, eff_attr, reason in plan:
        if target is None:
            _print_unrouted(issue, idx, len(issues), eff_attr, reason)
            continue
        body = _format_body(issue, args.batch, draft.get("source_attribution"))
        print(f"[{idx}/{len(issues)}] {issue['title'][:80]}")
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
