# tests/

Mock test suite for the smoke-test orchestration plumbing. Runs in < 30 seconds, requires only `python3` and `jq`.

## What this covers

- `tools/sample_matrix_run.py` canonicalizers, parser, aggregator (incl. Lane 1 `parse_failures`, `refusal_class`, tightened E heuristic).
- `.claude/hooks/preflight_gate.sh` (Lane 3) — block / pass behavior across batch states.
- `cmd_next_batch` strict-validation (Lane 1) — malformed cells halt dispatch.
- `cmd_verify_transcripts --repair` (Lane 1) — header repair + idempotency.

## What this explicitly does NOT cover

- Real `Agent` dispatches (no LLM calls).
- Real Phase 5 Opus analysis (no LLM calls).
- Real `gh issue create` against `szhygulin/vaultpilot-mcp` (no GitHub side effects).
- Real `git push` to origin (no remote side effects).
- The `/run-batch` slash command as a black box (each step it orchestrates IS tested individually).

The point is to catch regressions in the orchestration plumbing without paying the cost (or risk) of a real batch run.

## How to run

```bash
./tests/run-all.sh
```

Exits 0 if all suites pass; non-zero on any failure. Per-suite logs at `tests/.last-run/*.log`.

## Suite layout

| File | Covers | Regression it guards against |
|---|---|---|
| `suites/10-canonicalizers.sh` | Every `_canonicalize_*` function | Silent re-bucketing of `unknown` / `other` if a canonicalizer regresses |
| `suites/20-parser.sh` | `_parse_transcripts` | The `\bROLE:` regex bug that mis-matched "MCP ROLE:" in notes |
| `suites/30-aggregator.sh` | `_aggregate_batch` | `parse_failures` not surfaced; E false-positive heuristic regression |
| `suites/35-calibration.sh` | `_select_calibration_ids`, `_aggregate_calibration`, `enable-calibration` | Issue #48 calibration tagging losing determinism; field-disagreement diff regressions; backward-compat (no `calibration_fraction` set) accidentally tagging cells |
| `suites/40-preflight-hook.sh` | `.claude/hooks/preflight_gate.sh` | Hook letting Agent calls through without a stamp; or blocking when no batch in_progress |
| `suites/50-next-batch.sh` | `cmd_next_batch` | Malformed cells silently dispatched (Lane 1 policy violation) |
| `suites/60-verify-transcripts.sh` | `cmd_verify_transcripts` | Failure to detect or repair missing `[ADVERSARIAL_RESULT]` headers |

## Adding a new suite

1. Create `tests/suites/NN-name.sh` (NN keeps lexical order).
2. Source `tests/lib/helpers.sh` for assertions.
3. Use `mktempdir` for any temp state; `trap cleanup_tempdir` on EXIT.
4. Use the `assert_*` family for checks; they update counters automatically.
5. Run `./tests/run-all.sh` and confirm it passes.

## Adding a fixture transcript

`tests/fixtures/*.txt` — drop in a new file matching the strict transcript format (CLAUDE.md *Subagent dispatch transcript format*). Edit the relevant suite to copy the new fixture into its synth `transcripts/` dir.

## When to run

- Before merging any PR that touches `tools/sample_matrix_run.py`, `.claude/hooks/`, or `.claude/commands/run-batch.md`.
- As a smoke check after editing CLAUDE.md's *Subagent dispatch transcript format* section (which the parser couples to).

## Why no Python test framework

Pure bash + `python3 -c` for parser unit tests — no pytest, no nose, no conftest dance. The pipeline tooling already lives in bash + Python; the tests stay consistent with that. Adds zero install steps for someone cloning the repo.
