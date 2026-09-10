# 0019. Host-owned provider protection

<a id="concept"></a>
## Concept

Technical depth: [Process ownership and conformance](0019-host-owned-provider-protection-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-07
- **Decision owner:** Maintainer

This proposal isolates the reference provider adapter's credential-bearing
execution from the host VM's diagnostic machinery. It changes adapter launch
and configuration, not Core's Model callback, session authority, or accounting.
It is process separation under the same operating-system account, not a sandbox
against the host, native code, or another process with that account's authority.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-adrs-0019-0021-2026-09-07) | candidate `b7f97092f7b6d6661e66bc775fd88195b92b67a0`; concept `sha256:b743931ccc7435ad4a90973ee6b623fea2afa1133ecaf8733a10a0512605f9dc`; technical `sha256:26ea8ac60e6f4a006018afdd4ffe24308b4e2184c67e175d9cd555a268030c6f` |

<a id="concept-adr-0019-context"></a>
## Context

The current reference adapter installs a primary Logger filter and changes
shared ReqLLM process group leaders when its application starts. Losing its
credential registry can suppress unrelated host logs; restarting ReqLLM's
supervision can leave provider dispatch permanently unavailable. Neither is a
runtime-local consequence an embedder should acquire by starting an adapter.

Explicit host ownership alone does not repair delayed diagnostics. ReqLLM starts
work under shared supervision and can emit raw inspected failures. A finished
callback, a dead worker, and a drained trace mailbox do not establish that every
asynchronous diagnostic has been delivered. Retaining secret-dependent filters
forever would replace one lifetime defect with another.

Technical depth: [Evidence and constraints](0019-host-owned-provider-protection-technical.md#technical-adr-0019-context).

<a id="concept-adr-0019-decision"></a>
## Decision

Run each reference adapter invocation in one fresh, non-distributed provider
BEAM process. The host explicitly owns its launcher and supplies its trusted
worker artifact. The reference composition wires this for the command; an
embedder configures the same adapter without depending on CLI internals.

The worker is a separately built, private companion escript inside the existing
adapter application. It is not a daemon, pool, remote service, ninth application,
extension host, or new published package. The command's build assembles the
pair; a missing or mismatched companion refuses the call rather than falling
back to shared-VM provider execution.

The adapter's bare-model convenience helper gains `complete_prompt/3`, with
explicit options. Its existing two-argument form can no longer dispatch without
host configuration and returns a pre-transport refusal. This changes that unreleased
helper's behavior; it is not a change to the Model callback.

Before credentials are resolved, launch must establish isolated diagnostics,
a private protocol channel, and a cleanup owner that survives the ordinary
Port owner's death. Raw child stdout, stderr, and crash output are not forwarded
to host logging or retained as artifacts. The adapter changes no parent primary
Logger filter, handler, application group leader, or shared ReqLLM supervisor.
Cleanup uses a dedicated control pipe; bounded data uses a private, single-use
local socket, not a TCP listener or session service. Concurrent invocations
keep separate guardians, process groups, and channels.

The existing `LOOPEX_PROVIDER_API_KEY` source remains the only credential source.
A narrow host sender reads it only after protected bootstrap and passes it
privately, never in launch arguments, inherited environment, ordinary service
messages, or files. This proposal adds a **65,536-byte credential limit**;
empty or larger values refuse before disclosure to the child. This is a new
adapter configuration constraint, not an inherited gate or Model limit.
Launch assumes the trusted host does not concurrently introduce arbitrary
environment names; it does not promise atomic environment replacement against
other host code. Explicit credential exclusion remains unconditional.

Core still authorizes one exact worker and calls the existing Model callback.
The adapter invokes the child once and never restarts or resends an uncertain
invocation. A child acknowledgement is not provider acceptance. Lost replies,
EOF, process death, and timeouts cannot establish that no call occurred. Core
alone decides whether a proved pre-transport refusal permits another attempt.

Carry bounded raw replies faithfully to Core, which continues to validate,
retain, account, and settle them. A reply that fits raw admission but not its
complete settlement must still preserve valid reported usage. Best-effort
progress remains bounded and nonblocking; losing a transient delta must not
lose the final reply or erase the producer's count of emitted deltas.

Retain a parent-local lifetime guardian until correlated cleanup completes,
including after a callback result. Retainer loss or cancellation terminates the
owned provider process tree. Private lifetime plumbing carries Core's configured
cleanup period and remaining observation window; standalone direct calls must
declare their cleanup period explicitly. Unconfirmed cleanup remains unproved;
a timeout or closed Port is not a cleanup verdict. Ordinary replacement serves
only later, separately authorized work and never resurrects the old invocation.

Technical depth: [Launch, protocol, and lifetime](0019-host-owned-provider-protection-technical.md#technical-adr-0019-decision).

<a id="concept-adr-0019-alternatives"></a>
## Alternatives

**One isolated process per invocation** is recommended. It removes parent logger
authority and shared provider-supervisor coupling at the cost of BEAM startup,
memory, a companion artifact, bounded framing, and real-process cleanup proof.
Startup consumes the existing deadline; it creates no additional time allowance.

**Host-owned same-VM protection** avoids process startup but couples all shared
ReqLLM users to one diagnostic policy. Stable origin tracking must cover delayed
task, supervisor, and application-exit reports. Exhausted or lost non-replaceable
origin identity may require VM restart. This design is not established merely
by moving today's filter installation into composition.

**Change the provider dependency** could preserve in-process execution if owned
tasks and safe diagnostics are proved end to end. It adds dependency, floor,
transport, and maintenance decisions; a supervisor option alone is insufficient.

Technical depth: [Alternative costs](0019-host-owned-provider-protection-technical.md#technical-adr-0019-alternatives).

<a id="concept-adr-0019-consequences"></a>
## Compatibility, Delivery, and Rollback

Embedders and direct callers must supply the trusted worker configuration;
direct callers migrate to the options-taking helper. Source-tree command
users must build and keep its companion with the command. Existing very large
credentials now refuse, and provider startup adds latency and memory cost that
must be measured before integration. Raw provider diagnostics become unavailable
to the host; bounded non-secret status replaces them. Other host diagnostics
must continue across provider failures and restarts.

No Model callback, durable record, attempt allowance, public progress protocol,
runtime floor, external dependency, or application count changes. No accepted
ADR is superseded: ADRs 0001–0003 still govern application and publication
boundaries, and ADR 0018 retains dispatch, settlement, and recovery authority.
The companion is a source-tree build artifact, not extension activation or a
released distribution. Publication remains a separate decision.

Update adapter, reference wiring, build guidance, compatibility inventory, and
behavioral evidence together. Existing locked checks remain binding; a check
that requires the retired implementation mechanism must be dispositioned
through its holder's Closed-gate transaction, never silently replaced. The
separate accounting proposal, ADR 0021, is neither accepted nor carried by this
decision.

Rollback drains or contains live children before replacing the adapter and its
companion together. It does not rewrite a session or retry an uncertain call.
If reverting would restore unsafe shared-VM logging, disable reference-provider
admission instead until an explicitly accepted safe configuration is available.

These are proposed requirements, not executed conformance evidence. Acceptance
would settle the design; this document itself authorizes no implementation,
gate change, M2 lifecycle change, integration, tag, or publication.

Technical depth: [Delivery, rollback, and required evidence](0019-host-owned-provider-protection-technical.md#technical-adr-0019-consequences).
