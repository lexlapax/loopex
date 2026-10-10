# M7 handoff checkpoint, 2026-10-09 (Linux takeover)

Part of the [evidence index](README.md). This is the current resume runbook. It
does not accept an ADR, close M7 or authorize publication. The previous macOS
handoff is in git history (`git log -- docs/evidence/M7-handoff.md`).

## Concept

Continue M7 on branch `m7` in `~/projects/lexlapax/loopex` (Linux). The goal is
complete implementation with all tests passing, committed and pushed in bounded
units, with the T00–T19 checklist tallied as original and added rows
(`python3 scripts/m7-task-status.py`). Maintainer direction: no backward
compatibility before 1.0, less code is better, minimal external dependencies,
and decisions are asked as clear options with consequences.

Read first: [AGENTS.md](../../AGENTS.md), [plans register](../plans/README.md),
[M7](../plans/M7.md#concept), the newest entries at the top of the
[task ledger](M7-implementation-tasks.md), and the dispositions dated
2026-10-09 at the end of the [context map](../developer/agent-context-map.md).

## Technical depth

### Decisions taken in this takeover

All recorded in the context map with exact identities:

- ADR 0065 rewritten and accepted: Elixir loopback-listener lock, no Python.
- ADRs 0067 (two `tool.finished` variants) and 0068 (CLI-owned output, 5,000 ms) accepted.
- ADR 0069 accepted: private `run_evidence/3` query and host-route helper guard.
- ADR 0070 accepted: retire no-caller leftovers, the legacy credential plane,
  the demo tools and the offline prepare-index import.
- Quiesce test reserves of about 1,000 ms, plus a strict late-wakeup refusal.
- Provider B is OpenAI (`gpt-4.1-mini` thinking-off summarizer); helper children
  prepare their own model; public restore audits and accepts helper roots.
- External task: lapaxworks `30a49d6`, `tools/threads.py` slugify.
- Paid real-provider runs wait for approval at candidate time.
- History rewrite dropped `b8aa9457`; old-to-new identities are in the context map.
- Python remains only for the lapaxworks oracle and pre-M7 dev scripts.

### Environment

- Evidence root `~/projects/lexlapax/loopex-evidence/M7/claude-20261009/`, with
  per-unit folders and `SHA256SUMS`.
- Current pair: `mise x elixir@1.20.3-otp-29 erlang@29.0.5 node@22.14.0 --`.
- Floor pair: `mise x elixir@1.18.5-otp-27 erlang@27.3.4 node@22.14.0 -- env MIX_BUILD_ROOT=$PWD/_build_floor`.
- Run with `LANG=C.UTF-8` and a temporary `LOOPEX_HOME`. Node client cases need `--include node_client`.
- Commit titles must be at most 72 characters with no trailers. Run
  `scripts/check-commit-messages.sh` before every push.

### Open work at this checkpoint

m7 head at this checkpoint contains every agent unit; no agent is running and
no `worktree-agent-*` branch holds unmerged work.

- ADR 0070 groups 1–4 are merged, but whole-app floor-pair runs for the
  credential-plane and demo-tool removals and the single-catalog change are
  still owed. Rerun the whole suites on both pairs, one pair at a time.
- Composition whole suite: green on current (two seeds) and floor (one seed);
  one more floor seed is owed.
- Fix the isolated provider worker's per-call model-catalog cold load (context
  map, 2026-10-09 credential-plane and cold-load disposition). This is what
  makes `m7_case_runner_test` "thinking rounds" flake under load.
- CLI source-scan failure: `apps/loopex_cli/lib/mix/tasks/m7_evidence/execution_manifest.ex`
  names `Loopex.LLM`; route it through composition as was done for the other
  m7_evidence files.
- Then: the full `bash scripts/check.sh` on both pairs; the remaining T16 rows
  (focused/fast/release lanes, process-boundary stress thirty times on Linux,
  independent review); the T05 migration row and the T04 Control-slot row once
  the full check is green; and T08/T06/T07/T12 rows whose remaining proof is the
  full check or the paid/attended campaign.
- Then T17: present the paid/attended case list and its cost; run the closure
  matrix through `scripts/attended-release.sh` with the M7 options. T18 and T19
  need separate maintainer approval.

Worktree branches named `worktree-agent-*` hold unmerged agent work; merge or
discard them deliberately. Their committed heads survive a restart; uncommitted
files in `.claude/worktrees/*` do not.
