# M7 handoff checkpoint, 2026-10-10 (closure candidate)

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
2026-10-09 at the end of the [context map](../process/agent-context-map.md).

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

### Open work at this checkpoint, 2026-10-10

All agent work is merged into `m7`. After the In review documentation
commits, the final integration fixes recorded in the task ledger's 2026-10-11
entry (test-wait sweep, attempts-writer lock release, `m7.long` overflow
prompts and the committed attempts head) changed source before the closure
candidate. No agent is running and no `worktree-agent-*` branch holds
unmerged work. `main` (`e78fa64c`) is an ancestor of the candidate.

- Open defect, recorded under the 2026-10-10 stress-chase cap:
  `chat_pipe_test.exs:180` with the `""` fragment failed 2/30 under pinned load
  with `{:reader_down, :noproc}`, then 0/75 in later pinned runs. It is not
  counted toward the T16 thirty-run row; the task ledger has the evidence and
  hypothesis. A failure of it in either check command is still fixed, never
  retried.
- Next: the candidate fast check on both pairs, once each, from the clean
  candidate SHA. Current pair: `bash scripts/check.sh`; floor pair:
  `scripts/floor-lane.sh SHA --output-dir DIR --long-bound` or the milestone
  guide's `env -u MIX_BUILD_PATH MIX_BUILD_ROOT=/absolute/M7-otp27-build`
  floor command. Retain each complete output and SHA-256 outside the
  repository.
- Then T17: `scripts/attended-release.sh` with the M7 options from
  [DEVELOPMENT.md](../../DEVELOPMENT.md): `--output LOG --attempts-index FILE
  --writer W --host H --markers DIR --m7-config FILE --operator Maintainer`.
  The maintainer approved the run with a $150 provider-spend cap and keeps
  Ollama row 10; the maintainer attends the `m7-operator` block.
- Prerequisites for that run:
  - `LOOPEX_PROVIDER_API_KEY` (Anthropic, provider A) and `OPENAI_API_KEY`
    (provider B), read with `read -rs`, never on the command line;
  - `LOOPEX_RELEASE_OLLAMA_MODEL=ollama:qwen3.5:9b` with Ollama serving at
    `127.0.0.1:11434`;
  - `LOOPEX_CROSS_UID_USER` naming a second unprivileged user runnable with
    `sudo -n` (passwordless) on this Linux host;
  - Node 22.14.0 (`mise x ... node@22.14.0`) and an open-file limit of at
    least 4,096;
  - `LOOPEX_M7_EXTERNAL_REPOSITORY=~/projects/lexlapax/lapaxworks` at the
    pinned `30a49d6`;
  - the retained attempts index created once with
    `scripts/m7-fixture-chat.exs --create` as in the
    [M7 validation runbook](M7-validation-runbook.md), outside the
    checkout, with its writer identity and markers directory.
- Also owed for the candidate: the independent review, and ADR 0068's Darwin
  physical output proof on both pairs, which this Linux host cannot run.
- T18 (closure) and T19 (release) need separate maintainer approval.

Worktree branches named `worktree-agent-*` hold unmerged agent work; merge or
discard them deliberately. Their committed heads survive a restart; uncommitted
files in `.claude/worktrees/*` do not.
