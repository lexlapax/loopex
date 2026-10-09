# M7 validation runbook

How a named operator runs the M7 coding-task validation from a clean candidate
checkout: create the retained attempts index, run each lane through the
trusted fixture wrapper, and find which test, case or demonstration owns every
V1–V13 scenario step. The [accepted plan](../plans/M7-technical.md#technical-plan-operator-validation)
owns the scenarios; `test/fixtures/m7/manifest.json` owns the mapping below,
and `mix loopex.m7_evidence` fails when this page and the manifest disagree.
Part of the [operator index](README.md).

No command on this page is a paid run by itself. A real-provider attempt needs
the maintainer's separate authorization for that candidate and its case list;
a credential is supplied by the maintainer at that time and never written to
any file named here.

## Before any attempt

1. Start from a clean checkout of the exact candidate and build it as in
   [getting started](getting-started.md).
2. Choose a fresh retained directory outside the repository, for example
   `/retained/m7`, with `markers/` and `runs/` inside it.
3. Write the explicit configuration file the conversation will use. Its
   `paths` members are replaced for each attempt with that attempt's fresh
   workspace and state root; every other member is validated as written.
4. Check what is still pending:

   ```bash
   mix loopex.m7_evidence
   ```

   Expected output names the campaign and its genesis digest, the eleven
   legacy and the M7 case families, and the number of pending cases and step
   owners. A lane with a pending case cannot run.

## Create the campaign index once

The first invocation for the campaign creates the index and its lock record,
then designates this host's writer. Later invocations omit `--create`.

```bash
mix run --no-start scripts/m7-fixture-chat.exs -- --create --check \
  --lane m7-operator --attempts-index /retained/m7/attempts.jsonl \
  --writer maintainer-workstation --host workstation-1 \
  --markers /retained/m7/markers --run-root /retained/m7/runs \
  --operator Maintainer chat --config /retained/m7/config.json
```

`--check` admits the lane against the committed `index-head:` lines and
prints the cases it would run, without staging a workspace or starting a
conversation. Any refusal prints `m7-fixture-chat: evidence unavailable:`
and exits 2.

## Run a lane

```bash
mix run --no-start scripts/m7-fixture-chat.exs -- \
  --lane m7-operator --attempts-index /retained/m7/attempts.jsonl \
  --writer maintainer-workstation --host workstation-1 \
  --markers /retained/m7/markers --run-root /retained/m7/runs \
  --operator Maintainer \
  --external-repository ~/projects/lexlapax/lapaxworks \
  chat --config /retained/m7/config.json
```

For every admitted case, in manifest order, the wrapper:

- stages `runs/<attempt>/workspace` (a copy of the fixture seed, or a
  disposable clone of the external repository at its pinned base with no
  remote) and `runs/<attempt>/trusted` (the oracle and its fixed runner);
- validates the configuration and the pinned fixture policy, then records the
  case as `started` in the index before the conversation can call a model;
- runs the conversation: piped prompts with `/wait` barriers by default,
  reopening the recorded session for repair's and long's final prompt, or the
  operator's terminal with `--terminal`. A conversation with a harness-driven
  step (a hold, the observer, the model gate, an interrupt or a prescribed loss)
  stays piped under `--terminal`. Where it needs a human answer, as in
  `m7.question-restart`, the wrapper shows the emitted question on the
  terminal and sends the operator's typed choice;
- reruns the pinned oracle independently and checks the workspace against the
  allowed changes;
- records the case `completed` with its mechanical result and the retained
  files under `runs/<attempt>/records/`.

It stops the lane after a non-pass result or a pre-dispatch refusal. Output
ends with `m7-fixture-chat: passed:`, `stopped:` or `evidence unavailable:`
and the attempt identities. A stopped case is never rerun on the same
candidate; review assigns its verdict and any causal authorization is
recorded in the index before a later candidate.

Continue a lane suspended by a pre-dispatch stop on the same commit with
`--continue`. After a lane ends, the next commit of that work appends its
`index-head: <campaign_id> <sequence> <sha256>` line to the M7 plan's
Progress and Evidence section.

## Through the release check

The full closure matrix runs every lane in order and records each in the same
index under one logical matrix:

```bash
bash scripts/check-release.sh --attempts-index /retained/m7/attempts.jsonl \
  --writer maintainer-workstation --host workstation-1 --markers /retained/m7/markers \
  --m7-config /retained/m7/config.json --operator Maintainer
```

It prints `check-release: logical matrix ID`. After a pre-dispatch stop, rerun
on the same commit with `--resume-matrix ID`: completed lanes are skipped and
named, fresh-source is rebuilt and must reproduce its first archive manifest,
and only not-dispatched cases run. A lane that started and did not pass ends
the matrix; it is never resumed. Set `LOOPEX_M7_EXTERNAL_REPOSITORY` to the
external repository's checkout for the operator lane's external task.

## External task

The maintainer-selected external task changes `slugify` in
`tools/threads.py` of the `~/projects/lexlapax/lapaxworks` repository at
`30a49d6059b2a69b54e6e97f69a5623ce977b16d` so accented Latin letters
transliterate to ASCII, without changing any other output. Only that file may
change. The harness-owned oracle `test/fixtures/m7/external/oracle_test.py`
checks the slugify cases and that `python3 tools/threads.py --check` exits 0.
The checkout is disposable and is never pushed; the original repository is
read only by the clone.

## Ephemeral question case

`m7.ephemeral-question` runs the feature fixture through one public ephemeral
call instead of a chat session, using the configuration's model and provider
routes. With `--terminal` the wrapper prints the model's question and numbered
choices and reads the operator's line: a choice label or number answers,
`decline` declines. The retained `records/ephemeral.json` names the operator,
question, typed answer, selected choice and outcome. The independent oracle
reruns the branch for the selected default, so a run that ignores the answer
fails. The ephemeral call runs under the case's pinned fixture policy, passed
as a contextual policy reference, so it admits the same invocations and paths
as the chat cases. `scripts/m7-ephemeral-question-demo.exs` runs the
same host outside a lane for rehearsal; its record is not lane evidence.

## Compaction and thinking cases

These cases need maintenance instructions, which chat now composes from the
reference host's versioned block. `m7.oversized-source` sends a pinned,
backslash-dense ledger that fits an ordinary run. The ledger forces an
excerpted summary source, and the case checks that the complete original
stays in host history. `m7.thinking-rounds` runs each continuation-required
cell (Haiku low, medium and high; Fable default, low, medium and high) in one
session. Each cell first compacts the earlier cells, then reads three files in
three rounds; afterwards the session reopens. A counted round's committed
request must replay a thinking literal and equal the reply it names.

`m7.cross-provider-maintenance` configures the always-on thinking Fable model
and summarizes with Haiku at reasoning `none`. The adapter registers Haiku at
`none` as the only thinking-off summarizer, so both models share the
Anthropic route. The case therefore proves distinct models, not distinct
provider routes. Pins `thinking_model` and `summarizer` override the models.

`m7.thinking-bound` cuts each of the nine ADR 0044 cells with a one-turn
limit after its first tool group commits. `m7.thinking-cancel` instead wraps
the selected adapter with the trusted pre-transport cancellation gate. The
gate holds the second staged request, the observer joins the committed tool
result, and the wrapper sends `/abort`. In both cases two later prompts on the
same model must complete without replaying the cut run's native state, and the
last reply must use native thinking exactly when the cell requires
continuation. The cancel case's pinned cell is Fable at `low`; pin
`cancel_cell` overrides it.

The wrapper restores the configuration's named credential variables before
each conversation, because composition consumes them and every case runs in
one VM.

## Held cases

`m7.steer-barrier` and `m7.interrupt` ask the model to run
`/bin/sh <attempt>/trusted/hold.sh` once. The runner waits on
`trusted/hold.fifo`, outside the writable workspace, and the fixture policy
admits only that pinned invocation. The wrapper knows the call is running when
the runner opens the FIFO. It then prints `/status`. For the steer case it
also sends `/steer` and `/follow-up`. Next an independent read-only attachment
to the same runtime confirms the active run and its held operation. The
wrapper also requires the runtime to have accepted those commands. Only then
does it write one line to the FIFO. The interrupt case never writes: it
delivers the terminal interrupt and the run must end by cancellation with
confirmed cleanup. A hold of 90 seconds without release, below the 120-second
tool wall time, releases the runner and records `hold_expired` as a failure.
After the run, committed facts decide the case. The steer and follow-up must be
admitted before the held operation's receipt. The steer must be applied to the
held run, and the follow-up must run separately with the held run's context.
These cases stay piped even under `--terminal`; an operator's Ctrl-C under
`mix run` would end the whole harness rather than reach the chat.

## Step ownership

Every key below has exactly one owner: `case:` an M7 manifest case run by its
lane, `test:` a credential-free test in the fast check, `pending:` work that
still blocks closure, or `retired:` a step the pre-1.0 disposition removed.
Attended keys need a named operator recorded with the execution; an automated
answer never stands in for attendance.

<!-- generated: steps -->

| Key | Classification | Owner |
| --- | --- | --- |
| `V1.1` | attended | `case:m7.baseline.ask` |
| `V1.2` | attended | `case:m7.baseline.ask` |
| `V1.3.ask` | attended | `case:m7.baseline.ask` |
| `V1.3.durable` | attended | `case:m7.baseline.durable` |
| `V1.4` | attended | `case:m7.baseline.durable` |
| `V1.5` | attended | `case:m7.baseline.durable` |
| `V2.1` | attended | `case:m7.repair` |
| `V2.2` | attended | `case:m7.repair` |
| `V2.3` | attended | `case:m7.repair` |
| `V2.4` | attended | `case:m7.repair` |
| `V2.5` | attended | `case:m7.repair` |
| `V2.6.answer` | automated | `case:m7.pipe-answer` |
| `V2.6.decline` | automated | `case:m7.pipe-answer` |
| `V3.1` | attended | `case:m7.instructions.admitted` |
| `V3.2` | attended | `case:m7.instructions.admitted` |
| `V3.3` | automated | `case:m7.instructions.declined` |
| `V3.4` | automated | `case:m7.instructions.changed` |
| `V3.5` | automated | `test:apps/loopex/test/configured_session_test.exs#captured host sections cannot replace a denying policy with model-declared permission` |
| `V4.1` | attended | `case:m7.steer-barrier` |
| `V4.2` | attended | `case:m7.steer-barrier` |
| `V4.3` | attended | `case:m7.steer-barrier` |
| `V4.4` | attended | `case:m7.steer-barrier` |
| `V4.5` | automated | `test:apps/loopex/test/input_algebra_test.exs#a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted` |
| `V5.1` | attended | `case:m7.feature` |
| `V5.2` | attended | `case:m7.feature` |
| `V5.3` | attended | `case:m7.question-restart` |
| `V5.4.cancel` | automated | `test:apps/loopex/test/configured_session_test.exs#aborting a pending model question settles its slot and preserves a cancelled result` |
| `V5.4.decline` | automated | `test:apps/loopex_cli/test/chat_pty_test.exs#terminal declines the actual pending question without dispatching an executor effect` |
| `V5.4.denied` | automated | `test:apps/loopex/test/configured_session_test.exs#the admitted question generation never dispatches an executor effect` |
| `V5.4.expiry` | automated | `test:apps/loopex/test/configured_session_test.exs#a live question deadline settles once and rejects a late answer after recovery` |
| `V5.5.authority` | automated | `test:apps/loopex/test/interaction_lifecycle_test.exs#a committed answer re-enters host policy and only an allow result mints a grant before dispatch` |
| `V5.5.inactivity` | automated | `test:apps/loopex/test/configured_session_test.exs#model questions settle exact text, choice and decline in one transaction` |
| `V5.6.absent` | automated | `test:apps/loopex_composition/test/ephemeral_model_integration_test.exs#one-shot questions without a responder deny before waiting and preserve ordinary effects` |
| `V5.6.cancel` | automated | `test:apps/loopex_composition/test/ephemeral_api_test.exs#stop aborts an unanswered interaction and proves its terminal` |
| `V5.6.positive` | attended | `case:m7.ephemeral-question` |
| `V6.1` | attended | `case:m7.long` |
| `V6.2.long` | attended | `case:m7.long` |
| `V6.2.range` | automated | `test:apps/loopex_composition/test/artifact_range_executor_test.exs#a mixed source of at least 16 KiB reads exactly through EOF in 4 KiB ranges` |
| `V6.3` | attended | `case:m7.long` |
| `V6.4` | attended | `case:m7.long` |
| `V6.5.input-only` | automated | `test:apps/loopex/test/conversation_test.exs#terminal input-only runs keep failed and cancelled prompts eligible` |
| `V6.5.metadata` | automated | `test:apps/loopex/test/compaction_source_test.exs#an oversized assistant and all its results remain one covered unit` |
| `V6.5.positive` | attended | `case:m7.oversized-source` |
| `V6.5.size` | automated | `test:apps/loopex/test/maintenance_episode_recovery_test.exs#an automatic episode with no fitting excerpt ends durably before dispatch` |
| `V6.6.ambiguous` | automated | `test:apps/loopex/test/maintenance_request_staging_test.exs#only a proven not-dispatched first attempt permits the exact retained retry` |
| `V6.6.atomic-commit` | automated | `test:apps/loopex/test/maintenance_request_staging_test.exs#checkpoint and event commit together while exact raw facts remain readable` |
| `V6.6.missing-route` | automated | `test:apps/loopex_composition/test/durable_bindings_startup_test.exs#missing ordinary or maintenance routes and local bindings refuse before consumption` |
| `V6.6.positive` | attended | `case:m7.long` |
| `V6.6.summarizer-change` | automated | `test:apps/loopex/test/standalone_compact_projection_test.exs#standalone succession reuses capture before consulting new settings, clock or work` |
| `V6.7` | automated | `case:m7.cross-provider-maintenance` |
| `V7.1` | attended | `case:m7.provider-switch` |
| `V7.2` | attended | `case:m7.provider-switch` |
| `V7.3.barriers` | automated | `test:apps/loopex_cli/test/chat_workflow_test.exs#actual model progress reaches both channels before settlement without releasing wait` |
| `V7.3.near-limit` | automated | `test:apps/loopex/test/maintenance_episode_recovery_test.exs#thinking preparation continues past a hard-limit fit until the captured targets fit` |
| `V7.3.open-exchange-restart` | automated | `test:apps/loopex/test/configured_session_test.exs#owner recovery reuses frozen project content without the original host manifest` |
| `V7.3.positive` | attended | `case:m7.thinking-rounds` |
| `V7.3.split-events` | automated | `test:apps/loopex_llm_reqllm/test/native_stream_test.exs#every byte boundary uses the pinned parser and exact native stop establishes completion` |
| `V7.4` | attended | `case:m7.provider-switch` |
| `V7.5.in-run-change` | automated | `test:apps/loopex/test/configured_session_test.exs#live configure refusal while a provider is active remains stable after it settles` |
| `V7.5.missing-binding` | automated | `test:apps/loopex_cli/test/chat_resume_configuration_test.exs#missing retained model route refuses and abandons, without credential reads` |
| `V7.5.unsupported-level` | automated | `test:apps/loopex_cli/test/chat_configuration_test.exs#configure preparation refuses host metadata, missing routes and unsupported reasoning` |
| `V7.6.canaries` | automated | `test:apps/loopex_composition/test/native_model_switch_test.exs#native private continuation stays out of a real tool-created artifact across reopen` |
| `V7.6.conflicting-limits` | automated | `test:apps/loopex_llm_reqllm/test/native_request_test.exs#each manual thinking budget must fit strictly below the committed output limit` |
| `V7.6.limits` | automated | `test:apps/loopex/test/configured_session_test.exs#aggregate continuation overflow records an unavailable projection before another attempt` |
| `V7.6.missing-state` | automated | `test:apps/loopex/test/configured_session_test.exs#required continuation refuses v2 and malformed v3 before tools or reported accounting` |
| `V7.6.open-exchange-compaction` | automated | `test:apps/loopex/test/maintenance_episode_admission_test.exs#no episode overlaps an open exchange, interaction, abort or provider/effect stage` |
| `V7.6.summary-progress` | automated | `test:apps/loopex_composition/test/native_model_switch_test.exs#verified native summary stays progress and out of the next canonical request after reopen` |
| `V7.7.bound` | automated | `case:m7.thinking-bound` |
| `V7.7.cancel` | automated | `case:m7.thinking-cancel` |
| `V8.1` | attended | `case:m7.review` |
| `V8.2` | attended | `case:m7.review` |
| `V8.3` | attended | `case:m7.review` |
| `V8.4` | attended | `case:m7.review` |
| `V8.5.failure` | automated | `test:apps/loopex_composition/test/delegation_run_ledger_test.exs#a created child never prompted settles failed at zero and refunds its reservation` |
| `V8.5.bound` | automated | `test:apps/loopex_composition/test/delegation_helper_test.exs#count and token exhaustion refuse before any reservation and a new run reopens` |
| `V8.5.cancel` | automated | `test:apps/loopex_composition/test/delegation_helper_test.exs#cancelling the parent stops its child and confirms cleanup` |
| `V8.6` | automated | `test:apps/loopex_composition/test/delegation_recovery_test.exs#an exhausted serial child allowance survives restart and the parent reopens` |
| `V8.7` | automated | `test:apps/loopex_composition/test/delegation_child_creation_test.exs#only authored enabled roles in the retained catalog admit` |
| `V9.1` | attended | `case:m7.policy-denial` |
| `V9.2` | attended | `case:m7.interrupt` |
| `V9.3` | automated | `test:apps/loopex_reference_client/test/end_to_end_recovery_test.exs#every acknowledged fact survives the restart` |
| `V9.4` | automated | `case:m7.daemon-detach` |
| `V9.5` | automated | `test:apps/loopex_reference_client/test/end_to_end_recovery_test.exs#an effect without a durable receipt becomes outcome_unknown and is not blindly retried` |
| `V10.1` | attended | `case:m7.external` |
| `V10.2` | attended | `case:m7.external` |
| `V10.3` | attended | `case:m7.external` |
| `V10.4` | attended | `case:m7.external` |
| `V10.5` | attended | `case:m7.external` |
| `V11.1.file` | attended | `case:m7.trace.file` |
| `V11.1.flag` | attended | `case:m7.trace.flag` |
| `V11.2.file` | attended | `case:m7.trace.file` |
| `V11.2.flag` | attended | `case:m7.trace.flag` |
| `V11.3.invalid` | automated | `test:apps/loopex_cli/test/ask_options_test.exs#trace controls reject conflicts, unsupported selectors and limits even when disabled` |
| `V11.3.override` | automated | `test:apps/loopex_cli/test/chat_workflow_test.exs#no-trace overrides an enabled file through actual chat startup` |
| `V11.4.json` | automated | `test:apps/loopex_cli/test/ask_integration_test.exs#startup trace reaches stderr while a real command keeps JSON stdout clean` |
| `V11.5.file` | attended | `case:m7.trace.file` |
| `V11.5.flag` | attended | `case:m7.trace.flag` |
| `V11.5.json` | attended | `case:m7.trace.json` |
| `V12.1` | attended | `case:m7.trace.file` |
| `V12.2` | attended | `case:m7.trace.flag` |
| `V12.3` | automated | `test:apps/loopex_cli/test/config_file_test.exs#JSON and authored schema refusals happen before relative resolution` |
| `V12.4` | automated | `test:apps/loopex_cli/test/chat_resume_configuration_test.exs#restart preserves exact settings and ignores changed file instructions, tools and helper defaults` |
| `V12.5.in-flight` | automated | `test:apps/loopex/test/session_configuration_admission_test.exs#active work, interactions, aborts and unresolved effects cannot be configured` |
| `V12.5.legacy-defaults` | automated | `test:apps/loopex_cli/test/ask_ephemeral_test.exs#legacy one-shot defaults leave model, bounds and questions to the ephemeral profile` |
| `V13.1` | attended | `case:m7.restore` |
| `V13.2` | automated | `case:m7.rollback` |
| `V13.3` | retired | `retired:docs/developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02` |
| `V13.4` | attended | `case:m7.restore` |
| `V13.5` | attended | `case:m7.restore` |
| `V13.6` | attended | `case:m7.restore` |

## Cases

One row per manifest case in lane order; `pending:` names what still blocks it.

| Case | Lane | Driver | Status |
| --- | --- | --- | --- |
| `m7.baseline.ask` | `m7-operator` | scenario-ask | `ready` |
| `m7.baseline.durable` | `m7-operator` | scenario-chat | `ready` |
| `m7.trace.flag` | `m7-operator` | scenario-chat | `ready` |
| `m7.trace.file` | `m7-operator` | scenario-chat | `ready` |
| `m7.trace.json` | `m7-operator` | scenario-ask | `ready` |
| `m7.repair` | `m7-operator` | fixture-chat | `ready` |
| `m7.instructions.admitted` | `m7-operator` | scenario-chat | `ready` |
| `m7.steer-barrier` | `m7-operator` | demonstration | `ready` |
| `m7.feature` | `m7-operator` | fixture-chat | `ready` |
| `m7.question-restart` | `m7-operator` | demonstration | `ready` |
| `m7.ephemeral-question` | `m7-operator` | demonstration | `ready` |
| `m7.long` | `m7-operator` | fixture-chat | `ready` |
| `m7.oversized-source` | `m7-operator` | demonstration | `ready` |
| `m7.provider-switch` | `m7-operator` | scenario-chat | `ready` |
| `m7.thinking-rounds` | `m7-operator` | demonstration | `ready` |
| `m7.review` | `m7-operator` | fixture-chat | `ready` |
| `m7.policy-denial` | `m7-operator` | scenario-chat | `ready` |
| `m7.interrupt` | `m7-operator` | demonstration | `ready` |
| `m7.external` | `m7-operator` | external-chat | `ready` |
| `m7.restore` | `m7-operator` | demonstration | `pending:attended restore driver` |
| `m7.pipe-answer` | `m7-provider` | scenario-chat | `ready` |
| `m7.instructions.declined` | `m7-provider` | scenario-chat | `ready` |
| `m7.instructions.changed` | `m7-provider` | scenario-chat | `ready` |
| `m7.cross-provider-maintenance` | `m7-provider` | provider-wrapper | `ready` |
| `m7.thinking-bound` | `m7-provider` | provider-wrapper | `ready` |
| `m7.thinking-cancel` | `m7-provider` | provider-wrapper | `ready` |
| `m7.daemon-detach` | `m7-provider` | provider-wrapper | `pending:daemon host fixture driver` |
| `m7.rollback` | `m7-rollback` | release-lane | `ready` |
