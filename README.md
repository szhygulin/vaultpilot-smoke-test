# vaultpilot-mcp-smoke-test

Snapshot of a two-pass smoke test of [vaultpilot-mcp](https://github.com/szhygulin/vaultpilot-mcp) and the [vaultpilot-preflight](https://github.com/szhygulin/vaultpilot-security-skill) skill, run on **2026-04-28**.

This is a **frozen artifact set** — scripts, transcripts, and analysis from a specific run. The methodology lives in two companion skill repos:

- [`mcp-smoke-test-skill`](https://github.com/szhygulin/mcp-smoke-test-skill) — base honest-baseline methodology, MCP-agnostic
- [`crypto-security-smoke-test-skill`](https://github.com/szhygulin/crypto-security-smoke-test-skill) — adversarial red-team extension

Findings filed as issues #427–#463 on `szhygulin/vaultpilot-mcp` (tracker issues [#448](https://github.com/szhygulin/vaultpilot-mcp/issues/448) and [#456](https://github.com/szhygulin/vaultpilot-mcp/issues/456)).

## TL;DR — start with `SUMMARY.md`

The cross-pass executive overview is at [`SUMMARY.md`](SUMMARY.md). Read that first; everything below is supporting evidence.

## How to set up and run a test using Claude Code

This is the workflow distilled from the actual run that produced this corpus. Follow it to re-run against a future vaultpilot-mcp release, or against any other MCP that meets the prerequisites.

### Prerequisites

- **Claude Code** installed and running (this skill is harness-specific).
- **`gh` CLI** authenticated to GitHub (`gh auth status` should show ✓). Issues will be filed via `gh issue create`.
- **Target MCP server** installed and reachable from Claude Code's MCP config. For an adversarial run, the MCP must support a **demo / sandbox mode** — the smoke test never broadcasts real transactions.
- **Companion preflight / security skill** (if testing a wallet or signing-surface MCP) installed at `~/.claude/skills/<preflight-skill>/SKILL.md`. The adversarial defenses are measured against this skill; without it, "did the defense catch the attack?" has no defined success criterion.
- **Disk + token budget.** A 220-script run is roughly 6–7M tokens of subagent fanout + analysis. Budget accordingly.

### 1. No skill install needed

The methodology lives in `CLAUDE.md` (always loaded by Claude Code in this repo). Just clone the repo and open it in Claude Code; the `Smoke-test methodology` section is auto-loaded into every session.

Earlier versions of this README walked through installing a separate skill at `~/.claude/skills/mcp-smoke-test/`. That install is no longer needed (Lane 2 of the 4-lane overhaul, 2026-04-29). See the *Trade-offs* section below for why we moved it inline.

### 2. Pick a test vector

Three catalogs ship in [`test-vectors/`](test-vectors/), each tested in production:

| File | Use case | Entries | Role mix |
|---|---|---|---|
| [`honest-baseline.json`](test-vectors/honest-baseline.json) | Pass 1 — feature/UX/unprovoked-security baseline. Expert-style prompts. | 120 | All Role E (honest) |
| [`adversarial.json`](test-vectors/adversarial.json) | Pass 2 — red-team the defense surface against expert prompts. | 111 | A 25, B 44, C 5, D 1, E 4 (initial) + 67 b-scripts |
| [`newcomer-adversarial.json`](test-vectors/newcomer-adversarial.json) | Pass 3 — newcomer search-term style prompts, high Role-A density (newcomers don't recognize risk patterns). | 220 | A 104, B 7, C 1, D 2, E 106 |

Or generate your own — see `CLAUDE.md (Smoke-test methodology section)` Phase 2 for catalog targets.

### 3. Workdir is in-repo (don't create folders outside)

All test artifacts live under `runs/matrix-sampled/batch-NN/` inside this repository — see CLAUDE.md *Test workdir stays inside this repo* rule. The `/run-batch` slash command and `tools/sample_matrix_run.py` create + populate that directory automatically; you don't need to set up a workdir manually.

```
runs/matrix-sampled/
├── partition.json                    # the deterministic 181-batch plan (seed 42)
├── progress.json                     # which batches are pending / in_progress / completed
└── batch-NN/
    ├── scripts.json                  # the 50 cells dispatched in this batch
    ├── transcripts/{cell-id}.txt     # per-cell subagent reports
    ├── summary.txt                   # structured per-script summary
    ├── aggregate.json                # role / defense / tricked counters + parse_failures
    ├── findings.md                   # Phase 5 markdown analysis
    ├── issues.draft.json             # 5-8 fileable issues
    └── issues.md                     # filing log with #NNN URLs
```

(Earlier README walkthroughs pointed at `~/dev/<target-mcp>-smoke-test/` as the workdir — that pattern was for a portable methodology installed across multiple repos. Lane 2 of the 4-lane overhaul moved the methodology into CLAUDE.md, so workdir + methodology + artifacts are all versioned together in this single repo.)

### 4. Trigger the skill

Open Claude Code in the workdir. Prompt the agent:

> Run a smoke test on `<your-target-mcp>` using the script catalog at `scripts.json`. Apply demo/sandbox mode — no broadcasts.

For an adversarial run, add:

> Use adversarial mode. Each subagent gets the role assignment from `scripts.json[role]`. Apply the companion `<preflight-skill>` skill on signing flows.

The skill picks up the catalog and dispatches subagents in **background batches of 10**. Each subagent writes a transcript to `transcripts/NNN.txt`.

### 5. Wait — but don't sit on it

Subagents run in background. Each one's completion notifies Claude Code in the parent session. **Don't poll progress** — the harness handles notifications. Total wall time is roughly:

- 10 subagents in parallel × ~2 min average = ~2 min per batch
- 22 batches for a 220-script run ≈ 30–60 min wall time

Use the time productively. Don't kill the parent session.

### 6. Concatenate, parse, analyze (Phase 4 + 5)

Once all transcripts land, the skill:

1. Concatenates `transcripts/*.txt` → `all_transcripts.txt`
2. Runs the Python parser (Phase 5.2 in `CLAUDE.md (Smoke-test methodology section)`) → `summary.txt`
3. Delegates to a **fresh analysis subagent** with the canonical prompt (Phase 5.4)
4. Writes the subagent's reply → `findings.md`

The analysis is mandatory in a separate subagent; the parent has too much context bloat from dispatch to produce honest analysis. See the "How exactly to analyze the chat histories" section of `CLAUDE.md (Smoke-test methodology section)` for the recipe.

### 7. File feedback (Phase 6)

The skill files one GitHub issue per distinct gap on the target MCP's repo, plus a tracker. Confirm `gh auth status` is healthy first. The skill respects rate limits on any in-MCP feedback tool (e.g. `request_capability`-style) and falls back to `gh issue create` otherwise.

If the user said "without my approval" up front, the skill batch-files. Otherwise it files one issue, surfaces the URL, and asks before continuing.

### 8. Commit the artifacts

The full workdir (scripts.json + transcripts/ + summary.txt + findings.md + all_transcripts.txt) is the audit trail. Commit it to a results repo (this one is the canonical example):

```bash
cd <workdir>
git init && git add . && git commit -m "Smoke-test corpus for <target-mcp> on <date>"
gh repo create szhygulin/<target-mcp>-smoke-test --private --source=. --push
```

For protection rules matching this repo, see `gh api -X PUT repos/.../branches/main/protection` (1 PR review required, force-push disabled, deletions disabled).

### Lessons from the actual run

- **Subagent permission denials** muddy ~30% of read-only scripts in some Claude Code configs. Document once as meta-finding; don't generate per-script bug reports.
- **Don't merge dispatch and analysis in the same agent.** Cross-context contamination produces narrative-confirmation bias.
- **Inv #2 hash-recompute is tautological in 100% of rogue-MCP cases** (44 b-scripts confirmed verbatim). Mention this in the analysis prompt so the analyzer doesn't mis-rank Inv #2 vs Inv #1.
- **Selection-layer attacks** (Role A "agent picks the wrong durable object") need explicit attention in the analysis prompt or they get bucketed as bytes-tamper and mis-classified.
- **Always include 4–10 control scripts (Role E)** in adversarial runs to confirm the analyzer isn't inflating false-positive defense triggers.

## Layout

```
.
├── SUMMARY.md                         # cross-pass executive overview (start here)
├── README.md                          # this file
├── CLAUDE.md                          # methodology — Smoke-test methodology section is the synthesized 6-phase pipeline (was skill/SKILL.md before Lane 2)
│
├── .claude/                           # project-scope Claude Code config
│   ├── settings.json                  # hooks (PreToolUse preflight gate) + base permissions
│   ├── commands/run-batch.md          # /run-batch slash command (Lane 4)
│   └── hooks/preflight_gate.sh        # blocks Agent calls without preflight stamp (Lane 3)
│
├── tools/                             # helper scripts shelled out to between subagent dispatches
│   ├── concat_transcripts.sh          # Phase 4: transcripts/*.txt → all_transcripts.txt
│   ├── parse_summary.py               # Phase 5.2 honest mode: extract per-script summary
│   ├── parse_summary_adversarial.py   # Phase 5.2 adversarial mode: + [ADVERSARIAL_RESULT]
│   ├── find_missing_transcripts.sh    # Phase 3: surface in-flight subagents
│   ├── wait_for_transcripts.sh        # Phase 3/4 transition: block until N transcripts present
│   └── README.md                      # tool inventory
│
├── test-vectors/                      # reusable script catalogs
│   ├── honest-baseline.json           # 120 expert-style scripts
│   ├── adversarial.json               # 111 expert + adversarial overlay
│   ├── newcomer-adversarial.json      # 220 newcomer-search-term scripts + adversarial overlay
│   ├── build_adversarial.py
│   ├── build_newcomer.py
│   └── README.md
│
└── runs/                              # frozen test results — one subdir per pass
    ├── pass-1-honest-pruned/          # Pass 1: honest baseline (pruned 120-script run)
    │   ├── scripts.json               # 120-script catalog
    │   ├── transcripts/NNN.txt        # 120 individual transcripts
    │   ├── all_transcripts.txt        # concatenated corpus
    │   ├── summary.txt                # per-script structured extract
    │   └── findings.md                # full analysis
    │
    └── pass-2-adversarial-pruned/     # Pass 2: red-team (pruned 111-script run)
        ├── scripts.json               # 44-script initial adversarial catalog (with role tags)
        ├── enrichment.json            # 30 security-enriched scripts (121-150)
        ├── scripts-base.json          # copy of Pass-1 scripts.json for reference
        ├── transcripts/               # 111 adversarial transcripts (44 initial + 67 b-prefixed)
        ├── all_transcripts.txt        # initial 44-script concat
        ├── all_transcripts_full.txt   # full 111-script concat (1.8 MB)
        ├── summary.txt                # initial structured extract
        ├── summary_full.txt           # full structured extract (103 KB)
        ├── findings_adversarial.md    # initial 44-script analysis
        └── findings_adversarial_full.md  # full 111-script analysis (latest)
```

## Coverage at a glance

| | Pass 1 (honest) | Pass 2 (adversarial) |
|---|---|---|
| Scripts | 120 | 111 |
| Caught / passed | 120 (no successful attacks because everything was honest) | 104 caught cleanly + 1 tricked-unless-second-LLM (a086) + 6 defense-by-gap or depends-on-user |
| Filed issues | 22 (#427–#447 + tracker #448) | 6 + 4 (#450–#455, #460–#463 + tracker #456) |
| Threat-model roles | 1 (all honest) | 5 (rogue agent, rogue MCP, combined, supply-chain tamper, control) |

## Reproducing

This corpus is a frozen snapshot. To re-run on a future vaultpilot-mcp release, use the methodology in the two skill repos linked above against a fresh workdir.

## Caveats

- All testing was in vaultpilot-mcp **demo mode** (no real funds, no Ledger paired, broadcast intercepted).
- Adversarial subagents simulated attacks via transcript narration — no actual exfiltration, no real broadcasts.
- ~30% of read-only scripts in Pass 1 hit Claude Code subagent permission denials. Documented as a meta-finding; not a vaultpilot bug.
- The corpus is signing-flow-heavy. Several CF-* surfaces (BIP-137 message signing, EIP-712 typed-data, EIP-7702 setCode) are under-sampled in the adversarial pass and remain documented by 1–3 scripts each.

---

## Trade-offs

This repo's smoke-test pipeline embeds methodology + tooling into CLAUDE.md (loaded into every session) rather than a separately-installed skill, with PreToolUse hooks enforcing critical gates. The trade-offs below were the reasoning behind that design after running batches 1 and 2.

### Lane 4 — Autonomous batch run (`/run-batch`)

| Choice | Trade-off |
| --- | --- |
| One slash command (`/run-batch`) for the whole pipeline | + Single entry point, hard to skip steps. − Less flexibility if a batch needs a custom variant; would need a new slash command. |
| 2 manual user gates (preflight, filing) | + Cost-incurring + GitHub-visible actions stay user-confirmed. − Slightly slower than full auto. |
| Auto-commit on this repo (branch + PR) | + No manual git work per batch. − If `tools/post_batch_commit.sh` has a bug, it bakes into every batch until fixed. Mitigated by branch (never main) + PR (reviewable). |

### Lane 3 — PreToolUse hook enforces preflight

| Choice | Trade-off |
| --- | --- |
| Block ALL `Agent` calls during in_progress batch (no smart matcher) | + Simple + loud + fail-safe. − Non-smoke-test Agent calls during a batch are blocked too; have to complete/pause batch first. |
| Hook in `.claude/settings.json` (project scope) | + Repo-local; doesn't affect other projects. − Anyone cloning this repo gets the hook; documented in CLAUDE.md to avoid surprises. |
| Content-bound stamp (`.preflight-confirmed` per batch, JSON `{batch, batchHash, confirmedAt}`) | + Hash binds confirmation to a snapshot of `scripts.json` + `progress[batch-N entry]`; drift between confirm and dispatch (regenerated scripts.json, mutated progress entry, prior-session committed stamp) is rejected by the hook. + Stamps older than `PREFLIGHT_TTL_HOURS` (default 6h) expire so stale confirmations from a prior session fail closed. − One more subcommand (`confirm-batch`) than `touch`; orchestrator must call it instead of `touch`. |

### Lane 1 — No silent skips

| Choice | Trade-off |
| --- | --- |
| `parse_failures` list in `aggregate.json` instead of opaque `unknown` bucket | + Every parse failure surfaces in Phase 5 §0. − Slightly larger aggregate.json; analysis prompt has one extra mandatory section. |
| `refusal_class` taxonomy (5 classes) on subagent reports | + Distinguishes tool-gap from security-refusal. − Subagent prompt is one field longer; one more thing for Haiku to get right. |
| E false-positive heuristic tightening (require `refused` AND not `tool-gap`) | + Removes 100% of the noise we observed. − Risk of missing a genuine over-trigger if a future flow has `success` status with a defense firing. Re-evaluate after batches 3-4. |
| Default include (don't silently skip malformed cells); `next-batch` exits 1 on malformed cell | + Users see every test that ran. − A single bad cell halts dispatch until resolved; some friction for hand-edited matrix.json. |
| "OUT OF SCOPE" → "Routed to §7" wording sweep | + Less dismissive read; analyst doesn't drop A.5/C.5 findings. − Slightly longer text in many places. Same routing decision. |

### Lane 2 — Skill content in CLAUDE.md

| Choice | Trade-off |
| --- | --- |
| Full merge of all ~58k chars of skill content into CLAUDE.md | + Single source of truth, always loaded, no install dance. − Every session in this repo loads ~58k chars of methodology even if not running smoke tests. |
| Delete `skill/` directory | + No drift between two files. − Loses the "minimal skill file you can install elsewhere" portability claim from the previous README §1. |
| Drop `~/.claude/skills/mcp-smoke-test/` install | + No symlink/file-copy dance. − Skill-discovery / `/skills` dialog won't show this methodology. Users find it via reading CLAUDE.md instead. |
| Repo becomes single-purpose for smoke-test work | + Sessions in this repo are dedicated to smoke-testing; other work belongs in other repos. − Harder to use this repo as a general scratch space. |

### Combined trade-off: enforced flow vs. flexibility

The four lanes together create a **strong opinion + safety-rail pipeline**: do this exact thing in this exact order, with hard blocks if you skip a step. Quality-of-life gain is large (~6 manual gates → 2). Cost is reduced agility for one-off / experimental flows; if you want to do something off-script, you have to deliberately work around the gates (delete stamp file, ignore slash command, etc.). For a pipeline that runs the same 14-role × 670-row matrix in 181 deterministic batches, the trade is right.
