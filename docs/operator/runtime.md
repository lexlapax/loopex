# Runtime Operations

<a id="concept"></a>
## Concept

The Loopex runtime is a headless, single-machine loop that a host program
starts explicitly. The durable profile takes a local Store, a model adapter,
a trusted-local executor, tool definitions and a host policy, then returns an
explicit runtime reference. The ephemeral profile composes those boundaries
with an in-memory Store and a temporary root for one host-owned session;
neither profile creates a global default runtime.

This page is for an operator running or embedding either profile directly, and
for anyone recovering a durable session after a crash. The `loopex` command,
the daemon and the app server are hosts over the same kernel; if you only want
to use the command, start with [getting started](getting-started.md) instead.

What you can do here:

- run the complete loop from the source tree, with or without a real provider;
- start, stop and resume a runtime and its sessions in a fixed order;
- recover after a process or machine crash and reconcile an in-flight effect
  from the executor's receipt ledger;
- make a complete offline backup and restore an eligible current-format root;
- read the runtime's refusals as the stop conditions they are.

Only one run can be active per session. Loopex does not provide network session
transport, a remote executor, distribution, or a production credential manager.
The one-active-runtime rule applies to each durable Store and `runtime_id`. An
ephemeral handle and its in-memory conversation end when its host VM exits or
stop is proved. A later process cannot resume it. Keeping sessions alive
between processes for several local clients is the job of
[the daemon](daemon.md#concept).

Developer composition details:
[Runtime and embedding](../developer/runtime-and-embedding.md#technical-depth).

<a id="operator-runtime-available"></a>
## What the Runtime Provides

A host can start the runtime, submit a prompt, call a model, authorize and run
tools, observe durable events, stop, and resume from retained state. The
reference client drives the same embedded API a host has; it owns no test-only
or alternate loop.

| Capability | State |
| --- | --- |
| Run the complete loop from this source tree | Available |
| Use a deterministic model for a credential-free demonstration | Available |
| Use the ReqLLM adapter with a real provider | Available |
| Run an ephemeral session with an in-memory Store and an in-VM model call | Available: `LoopexComposition.Ephemeral` |
| Run `bash` jobs in separate operating-system process groups. Run file and read-only tools in the VM | Available |
| Retain sessions, events and tool receipts, and resume after process loss | Available |
| Drive sessions with the `loopex` command | Available: [coding sessions](coding-sessions.md#concept) |
| Keep sessions alive for several local clients over a Unix-domain socket | Available: [the daemon](daemon.md#concept) |
| Drive a session from another language over standard input and output | Available: [app server operations](app-server.md#concept) |
| Install a released package | Not provided |
| Run a remote executor, network client, or distributed service | Not provided |

The missing surfaces are not hidden routes to the same functionality. Both
profiles drive the same kernel loop; only the composition and retention differ.

For an ephemeral embedding, call `LoopexComposition.Ephemeral.start_session/1`
with an explicit host policy, then `ask/3`, `answer/3`, `history/1` or
`last_result/1`, and finally `stop_session/1`. `run/2` owns that lifecycle for
one prompt and returns a result only after cleanup. The process that calls
`start_session/1` owns the session: passing the opaque handle to another
process does not extend its lifetime, and creator exit starts cleanup. A
successful stop proves the session's provider and tool subtree ended. If
cleanup is unproved and the owner replies, `stop_session/1` returns
`cleanup_unproved` and seals that session. Its report names a retained root
when the owner knows the path. If the owner dies before replying,
`stop_session/1` can return bare `session_unavailable` even when a retained
root exists; that path goes unnamed. A reported path never authorizes
deletion. No later process can resume this profile. Use the durable profile
when recovery and retained history are required.

Ephemeral startup accepts explicit `instructions`, `reasoning` and
`system_class_tokens`. Instructions default to the reference host's captured
workspace prompt; reasoning defaults to `"default"`, and the system ceiling to
1,000 estimated tokens. Preparation checks the whole selection before allocating
the session. If instruction or selected-tool costs exceed the ceiling, choose
shorter instructions or explicitly raise the ceiling within the context budget.
These startup settings apply across prompts; `ask/3` accepts only a timeout
override. See the [exact option grammar and context-budget resolution](../developer/runtime-and-embedding.md#technical-embedding-ephemeral).

<a id="operator-runtime-first-run"></a>
## Run the Working Loop

From the repository root, the credential-free demonstration is:

```bash
MIX_ENV=test mix test apps/loopex_reference_client/test/reference_client_test.exs --seed 0 --trace
```

It starts an isolated runtime and durable local Store in temporary directories,
submits a prompt through the reference client, receives a deterministic model
tool call, runs the controlled workspace-write tool in a child process, consumes
the durable event sequence through `run.finished`, checks the resulting file,
and removes its temporary state. Success is every case in the file passing with
none excluded.

To run the same path through the real ReqLLM adapter, export the provider key
as `LOOPEX_PROVIDER_API_KEY` from your secret store, then:

```bash
MIX_ENV=test mix test apps/loopex_reference_client/test/real_model_session_test.exs --only real_provider --seed 0 --trace
```

It makes two real model calls around one controlled tool effect and checks that
both calls send the canonical request bytes the session already committed. Keep
the credential out of the command line, the repository, the state root, logs and
fixtures, and unset it afterwards if nothing else manages its lifetime.

These are source-tree demonstrations, not a command contract. To embed Loopex in
your own host, follow the
[developer runtime and embedding guide](../developer/runtime-and-embedding.md#concept).

<a id="operator-runtime-prerequisites"></a>
## Before Starting

- For the durable profile, give the runtime one owned state root for the Store
  log, the executor's receipt ledger and the artifact store, and a separate
  workspace for the tools. The ephemeral profile creates its own temporary
  root and takes no state root. Never point a development or test runtime at
  real user state.
- Start only one active runtime for a Store and `runtime_id`. Start a
  replacement only after the previous runtime's operating-system process tree is
  known to be gone or has been stopped.
- In the durable profile, keep the provider credential in the host. Its
  reference composition reads
  `LOOPEX_PROVIDER_API_KEY` once, moves it into private custody and removes it
  from the process environment. A second independent composition without a
  shared credential plane in the same operating-system process refuses with
  `provider_credential_required` rather than finding it again; a host running
  multiple compositions may [share one credential plane](../developer/runtime-and-embedding.md#technical-embedding-composition).
  The credential never belongs in session options,
  commands, Store data, executor jobs, receipts, events, diagnostics, fixtures
  or logs. Where it does go is described under
  [credential boundary](tools-and-policy.md#operator-tools-credential).
- In the ephemeral profile, a selected hosted-provider key is visible to the
  host VM and its HTTP/TLS path during the call; host-installed observers and
  authorized tools may also expose ambient values. Loopex does not inject the
  selected key into its own journal or diagnostics, but this is not structural
  secrecy from trusted host code. See
  [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept).
- The trusted-local executor is not a sandbox. It runs only its registered
  tools beneath a held workspace lease. The `bash` child receives an explicit
  environment containing only `PATH`; in-VM file and search tools, and trusted
  host code, can inspect ambient variables. In the ephemeral profile this
  includes hosted-provider keys. See
  [what local execution can reach](tools-and-policy.md#operator-tools-reach).
- The reference executor needs `/bin/bash` for its own supervision and `/bin/ps`
  to confirm cleanup; see the
  [local supervision prerequisite](tools-and-policy.md#operator-local-supervision-shell).

<a id="operator-runtime-lifecycle"></a>
## Operating Lifecycle

The durable reference composition, `LoopexComposition.start/1` or
`LoopexComposition.with_runtime/2`, performs the first three steps in this order
and the last one in reverse. A host composing its own stack follows the same
order.

1. Start the durable local Store for its log path.
2. Start the workspace lease and the trusted-local executor for the workspace
   and receipt-ledger paths.
3. Start Loopex with an explicit `runtime_id`, Store, model, executor and tools.
   Active tools require a host policy; a model-less, tool-less runtime may omit
   one.
4. Create or resume a session, attach at a durable event cursor, and submit a
   prompt.
5. Consume committed events. `user.message_appended`, `run.started`,
   `assistant.message_appended`, `tool.started`, `tool.finished` and
   `run.finished` are durable public facts. Progress and diagnostics are
   transient and are never durable truth.
6. Stop Loopex before the executor, the lease and the Store. A normal stop
   keeps the Store and ledger bytes for a later resume.

Ordering inside a run is fixed: the canonical model request is committed before
the model is called, effect intent and the host grant are committed before the
executor is asked to act, and a validated receipt is committed before the loop
continues or the matching fact is published.
[What is durable at each step](how-a-run-works-technical.md#technical-run-durability)
has the full table.

<a id="operator-runtime-recovery"></a>
## Crash Recovery

After a normal stop or an ungraceful process or machine death:

1. Reopen the local Store with `recover_stale_writer: true`. That is a request,
   not a removal. The Store reads the writer marker the previous holder left
   (`loopex_store_writer_v2`, recording that process's operating-system pid and
   start identity) and asks the operating system whether that process is still
   alive.
   - A live holder is refused as `store_writer_active`. The one exception is a
     marker recorded by this same VM whose Store process is proved dead; that
     marker is recovered.
   - A holder that is gone, or whose pid now belongs to a different process, is
     recovered.
   - A marker the Store cannot verify is refused as `store_writer_unverifiable`:
     one with no identity in it, unreadable bytes, or a process probe that
     failed or did not answer within five seconds. Remove it by hand only once
     you know its writer is dead.

   Only the probe's exact "no such process" answer counts as absence, and a
   Store that cannot record its own identity refuses to open, so check that
   `/bin/ps` runs where Loopex does. Concurrent recovery is refused.
2. Start a replacement runtime with the same `runtime_id`, Store, workspace,
   executor identity, receipt ledger and tool definitions.
3. Resume the session under a fresh command identity. Resume commits a new owner
   epoch before it accepts commands or consequences.
4. If the session reports an effect awaiting recovery, request its current
   reconciliation query, look up the exact job receipt in the executor ledger,
   and answer the query with that retained receipt.
5. If no provable receipt exists, answer `outcome_unknown`. Never redispatch an
   effect because its result is missing. `outcome_unknown` is durable and ends
   that run.

A receipt is admitted only when the current query, operation, attempt,
canonical request digest, session and executor epochs, executor identity and
fencing token all match the journaled intent. Stale, unsolicited, incomplete or
mismatched evidence is refused, and a field the answer omits counts as a
mismatch. [Crash, and what recovery proves](how-a-run-works-technical.md#technical-run-recovery)
states the full match.

<a id="operator-runtime-backup-restore"></a>
## Offline backup and restore

Use this procedure to recover the latest complete, idle backup of a durable
state root into a fresh root on the same machine. Keep the original workspace
directory at its recorded physical identity. State restore preserves session
history and effect uncertainty; it does not undo a tool's filesystem or other
external effects. Ephemeral sessions have no durable state to restore.

The host embeds `LoopexComposition.Restore.restore/2` and `lookup/3`. There is no
backup or restore CLI command. The host owns backup creation, complete inventory,
plan construction and retained exclusion evidence. The accepted
[physical restore decision](../adr/0051-current-format-physical-restore.md#concept-adr-0051-placement)
and [closed input schemas](../adr/0051-current-format-physical-restore-technical.md#technical-adr-0051-boundary)
define this administrative operation.

This implementation refuses a state root containing any `delegation/` namespace,
including helper locks or temporary files, because its complete helper-ledger
audit is not implemented. Do not omit those entries to make a backup eligible.
That refusal leaves helper-aware restore coverage open; copying opaque helper
state does not prove it recoverable. Another machine, an older snapshot, an
older format, or a lost or recreated workspace is outside this procedure.

<a id="operator-runtime-backup-capture"></a>
### Capture a complete idle backup

1. Stop admitting commands and prevent every client, daemon, embedded host and
   direct executor from accessing the state root or workspace. Stop and
   positively join the Runtime, Store, Local executor, guards, workspace lease,
   worker groups, child managers and placement owners. Include any earlier
   restore administrator and its file resources. A runtime stop or a caller's
   death alone does not prove all these owners ended. If termination cannot be
   proved, keep the roots excluded; the accepted host-reboot assertion must
   cover the previous authority before proceeding.
2. Record the latest idle cut, the source root's path/device/inode placement,
   each Local ledger's placement and generation digest, the original physical
   workspace reference, and the complete prior restore lineage. Exclude all
   other copies and retain evidence that no activity occurred after this cut.
   Retain the capture and host evidence outside all participating roots. A hash
   proves bytes, not latestness or the end of competing authority.
3. Enumerate the whole state root without exclusions. Include the root itself,
   hidden files, empty directories, every session and runtime-control record,
   artifacts, receipts, markers, open/effect claims, private recovery and
   continuation records, resource catalogs, host ledgers, and all earlier
   restore metadata. Include staging or orphan entries; a complete audit must
   accept them rather than silently discard them. Record each path, kind, mode,
   exact regular-file length and SHA-256 in the
   [canonical manifest](../adr/0051-current-format-physical-restore-technical.md#technical-adr-0051-placement).
   Its uncompressed deterministic ETF representation includes every bytewise
   sorted, unique entry, with `"."` for the root. Retain those exact bytes and
   their digest.
4. Make an independent offline copy into a separate backup root while access
   remains excluded. Preserve all directory and file modes, including the root.
   Prove copied-file sync and close, bottom-up directory sync, and termination
   of the copy's owned work. Compare the backup's complete canonical manifest
   to the captured source manifest. Refuse links, special files and imported
   regular files whose link
   count is not one. Do not repair a torn backup, prune a log or discard a
   malformed record. Mode and byte equality do not cover ownership, ACLs or
   extended attributes; the host must protect private state separately.

Keep the backup excluded from ordinary startup. An ordinary copy or move does
not establish a fresh Local generation or authorize that physical placement.
The backup is an input to the offline transition, not a second active root.

If workspace contents may also need recovery, capture a separate host-managed
content backup under the same access exclusion. Keep its evidence separate from
the state-root manifest and record the original workspace directory identity.
The restore operation does not capture or restore workspace contents for you.

<a id="operator-runtime-backup-plan"></a>
### Prepare and run the restore

1. Reestablish exclusion and positive termination before restore, even if the
   backup was taken earlier. Use the retained latest cut only if no post-cut
   activity occurred. Choose an independent empty destination directory. Source,
   backup, destination and workspace paths must be distinct, pairwise nonnested,
   and checked through their existing ancestors without symlinks.
2. Select the source branch honestly. For `"available"`, the original source
   must still match its captured physical placement and complete cut. Restore
   retires it before installing destination generations; retirement is one-way.
   For `"lost"`, prove the original endpoint absent. Permission denial or a
   failed probe is not absence. Retain the original captured placement and the
   host's latestness, exclusion and termination attestation; restore does not
   fabricate a tombstone at a missing source.
3. Construct the closed string-key plan from the complete capture. Supply one
   64-character lowercase hexadecimal `tx_id`, source status and placement,
   backup and destination paths, manifest digest and cut identity, complete
   runtime/Store/ledger descriptors, prior lineage count and digest, original
   workspace reference and host attestation. Descriptor lists cover the whole
   current state, not a selected subset. The attestation asserts `latest_cut`,
   `no_post_cut_activity`, `all_other_copies_excluded` and
   `host_ledgers_validated`, with `old_authority_termination` equal to `"joined"`
   or `"host_rebooted"` and an evidence digest. Use the
   [exact plan and digest recipes](../adr/0051-current-format-physical-restore-technical.md#technical-adr-0051-boundary)
   and [lineage records](../adr/0051-current-format-physical-restore-technical.md#technical-adr-0051-lineage).
   Loopex checks the retained state; it does not establish these host assertions
   from filesystem hashes.
4. Supply an invocation with explicit positive `work_ms` and `cleanup_grace_ms`,
   a `max_total_file_bytes` cap, and prior administrative authority evidence.
   Set `"prior_admin_authority"` to `"none"` and
   `"prior_admin_evidence_sha256"` to nil only when no prior held or stranded
   administrative claim exists. An original-transaction continuation requires
   `"joined"` or `"host_rebooted"` and a nonnull evidence digest covering every
   previous administrator and file resource. Retain the exact plan and
   invocation with the backup evidence.
5. Call `LoopexComposition.Restore.restore(plan, invocation)` from the offline
   host and inspect the result below. Keep all participating roots excluded
   until completion and administrative cleanup are proved. Restore audits the
   complete current Store, Local receipt/open history, artifact relations and
   supported host ledgers before authority changes. It never dispatches an
   effect to settle an unknown result.

The bounds apply to complete encoded objects, not just their constituent rows:

| Input or retained object | Limit |
| --- | --- |
| Complete manifest | 4 MiB, 65,536 entries; all regular bytes within `max_total_file_bytes` |
| Plan, compiled intent, each nonmanifest root or ledger record | 65,536 bytes each |
| Invocation, claim, receipt, observation, refusal, lookup refusal | 2,048 bytes each |
| Lookup limits | 512 bytes |
| Runtime IDs, Store descriptors, ledger descriptors | 256, 1,024, 128 items respectively; sorted and unique |
| Paths and executor IDs | 8,192 UTF-8 bytes each; runtime IDs at most 256 bytes |
| Completed restore lineage | 64 transitions; transition 65 refuses before mutation, with no pruning |

Existing per-format limits also apply, including the Store's 256 MiB log and
4 MiB frame, Local's 2,048-byte generation, 65,536-byte receipt/metadata records,
and 1,024-entry, 4 MiB open index. Work and grace are positive uint64 milliseconds
with checked arithmetic; there is no new default. One captured work cutoff
bounds payload work. The first stop reason, including normal payload completion,
captures one cleanup cutoff with a window of `max(10000, cleanup_grace_ms + 2000)`
milliseconds. Descriptor closure, exact worker joins and terminal claim release
share that cutoff. See the
[ownership and cutoff contract](../adr/0051-current-format-physical-restore-technical.md#technical-adr-0051-lifetime).

<a id="operator-runtime-backup-outcomes"></a>
### Resolve the result before opening the root

| Restore result | Operator action |
| --- | --- |
| `{:committed, receipt}` | Retain the receipt and complete proofs. It confirms synced completion and joined administrative claim release, but returns no live authority. Start the destination through ordinary guarded startup only after the host's exclusion and cleanup obligations are satisfied. Keep the backup excluded and the old source retired. |
| `{:not_committed, refusal}` | Read `code`, `phase` and `claim`. This is a joined refusal before possible intent publication. A retained claim or partially staged destination still needs the original administrative resolution; do not overwrite it or silently reuse it. An incomplete baseline requires explicit disposable-root cleanup under the accepted contract. |
| `{:cleanup_unconfirmed, observation}` | Intent absence was positively proved, but administrative or file cleanup was not. Keep exclusion and prove every previous resource terminated, or supply the accepted covering reboot evidence, before any continuation. |
| `{:commit_unknown, observation}` | Intent or its temporary publication may persist, or a validated transition is unfinished. Keep the original transaction, plan, claims and candidate bytes. Preserve exclusion and resolve that identity after prior authority ends. Never invent a replacement transaction or epoch. |

For bounded read-only inspection, call
`LoopexComposition.Restore.lookup(destination_state_root, tx_id, limits)` with
`%{"work_ms" => work_ms, "cleanup_grace_ms" => cleanup_grace_ms}`. A committed
answer contains the retained receipt and `"view"` equal to `"current"` or
`"historical"`. Current completion requires matching physical proofs and no
unfinished higher transition or administrative claim. A historical receipt
proves retained completion; it grants no authority over an old placement.
Pending, absent and error answers do not activate, reclaim, sync or continue a
transaction. An absent answer describes this read only. It cannot clear an
earlier `commit_unknown`, lost administrative evidence or unproved cleanup.

A root commit record alone is insufficient while a claim remains. Visible
claim deletion is also insufficient if its release or previous file resources
were not joined. Re-present the original plan and `tx_id` after positively
terminating prior authority. A continuation may change invocation limits, but
must reuse the retained cut, attestation and candidate generations, and cannot
extend any retained effect deadline. A fully cleaned committed duplicate with
`"prior_admin_authority"` equal to `"none"`, or a historical completion,
validates retained completion without minting a new generation or reading the
old source or backup. A current transaction submitted with `"joined"` or
`"host_rebooted"` continues retained cleanup and still requires the complete
retained backup and original source-retirement or lost-source checks. Do not
substitute `"none"` to bypass required prior-authority evidence. Loss of sole
intent or claim evidence after uncertainty needs a further reviewed recovery
decision. See the
[exact outcomes and lookup rules](../adr/0051-current-format-physical-restore-technical.md#technical-adr-0051-outcomes).

<a id="operator-runtime-backup-verify"></a>
### Verify state and workspace separately

Compare the complete source or retained capture, backup and staged destination
manifests before transformation. They must match exactly without exclusions.
The completed destination differs from that baseline only by the exact numbered
administrative records and named Local generation replacements authorized by the
[ordered transition](../adr/0051-current-format-physical-restore-technical.md#technical-adr-0051-transition).
Verify the receipt's baseline, activation, retirement, lineage and committed
proof digests against those records. Check the complete final manifest against
the permitted additions and replacements; every other entry, byte and mode stays
unchanged, including earlier restore provenance. Do not demand raw equality with
the pretransition backup after these authorized changes, or exclude arbitrary
metadata to obtain equality. Retain the complete manifests and receipt outside
the roots.

State restore leaves workspace contents and external effects intact. If workspace
contents must also be recovered, the host restores them separately inside the
original workspace directory while access remains excluded. Keep that directory's
physical identity; removing and recreating it is outside this profile. Restoring
file contents does not establish an effect receipt or erase an unknown outcome.
After opening the committed destination, follow
[crash recovery](runtime.md#operator-runtime-recovery) for pending effects and
use exact retained receipt reconciliation. Never blindly redispatch an unknown
effect. Confirmed restore cleanup also does not prove external-effect cleanup.

<a id="operator-runtime-failures"></a>
## Reading Failures

- For durable composition, a missing provider credential is a configuration
  error before the run starts. An ephemeral hosted session reads its selected
  key at each model call, so a prompt may already be admitted when a missing
  key ends that call as `model_call_failed`. For `loopex ask`, a failed provider
  call prints `ending failed` in text mode and exits `2`; JSON reports
  `details.reason` as `model_call_failed`. Durable `run` and `resume` retain
  their `loopex: failed model_call_failed` diagnostic. Neither case is a skipped
  success; inspect ephemeral cleanup before starting another `ask`.
- `commit_unknown` fences its mutation domain until the exact transaction is
  re-presented and reaches a retained resolution. Nothing is acknowledged,
  published or dispatched through that fence.
- A lost workspace lease cancels or kills executor-owned work and produces a
  retained non-success receipt.
- A full attachment queue disconnects only that attachment and returns its last
  stable durable cursor. Reattach from that cursor; the session keeps committing.
- Store corruption, a torn record that cannot be repaired safely, or a writer
  marker whose owner may still be alive is a stop condition, not a reason to
  guess or recreate state.
- A log removed or replaced beneath a live Store is the same kind of stop
  condition. The Store holds that exact file, not its path, so it reports the
  write as ambiguous and stops rather than continuing into a new, empty log.
  Recover it as any `commit_unknown` is recovered: establish that the previous
  process tree is gone, reopen, and re-present the exact transaction. Do not
  restore a partial copy of a state root.

## Related

- [Runtime and embedding](../developer/runtime-and-embedding.md#concept) — the developer companion to this runbook.
- [How a run works](how-a-run-works.md#concept) — the same loop seen from the `loopex` command.
- [Observability](observability.md#concept) — tracing and telemetry for a runtime you host.
- [Development setup](../../DEVELOPMENT.md) — toolchains and repository checks.
- [Operator documentation index](README.md).
