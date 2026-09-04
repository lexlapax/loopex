# M4 Gate

Executable acceptance for `M4`. These canonical UTF-8/LF bytes and their
SHA-256 are mutable while M4 is Open and become immutable only when the plan
pair and gate are explicitly accepted. Progress and retained evidence may then
change only in conformance with that lock.

The ordinary gate command is:

```text
bash scripts/check-m4-gate.sh
```

This gate proves a headless application boundary, not a daemon. It observes a
real child process over stdin and stdout before it inspects future product
selectors. Independent review still judges whether the app-server reaches only
the public facade, whether a response can accidentally grant authority, whether
the executed language clients are independent, and whether the real task and
restart trace satisfy the Purpose.

<a id="amendment-transaction-v1"></a>

Any amendment after acceptance follows the repository's direct proposal and
rebind transaction. No amendment exists while this gate remains Open.

## Opening Condition

M4 is the one planning lookahead from accepted M2 governance. Opening evidence
is therefore two independent red commands, not an inherited-green claim:

```text
bash scripts/check-m2-gate.sh
bash scripts/check-m4-gate.sh
```

At the lookahead base, the first command must reproduce M2's exact accepted red
and observation:

```text
LOOPEX_M2_PROBE turns=2 history=single_user_message progress_messages=0 ports=no_progress_channel tool_set=single_hand_written staged=loopex_demo_write
```

The second command must fail for M4's own missing external behavior. Neither
runner invokes the other before producing its own observation, so one red cannot
mask the other. After M2 closes and integrates, the refreshed M4 candidate must
instead re-run every inherited gate green and reproduce only M4's distinct red
before acceptance.

### The raw-process probe is primary

The gate-owned client launches a separate BEAM child with the proposed shipped
entrypoint, a gate-owned defer-once policy and workspace supplied through trusted
start options, sends the exact initialization vector over stdin, and observes
stdout as raw bytes. Policy and workspace never appear in a client frame. The
client never searches for an app-server module or file and does not load product
ebin paths or the product JSON codec into its own VM. The child may be absent,
refuse, exit, emit non-protocol output, or answer partially; each is an observed
boundary result rather than a missing-file verdict.

The full green conjunction requires one process to:

1. accept initialization at `loopex.experimental/1` with the exact schema
   digest;
2. admit session creation, then explicitly attach at cursor zero and return an
   authoritative inactive snapshot before a prompt is submitted;
3. echo the exact prompt request, command, and session identities in an accepted
   durable admission before any progress for that command;
4. emit at least one recognized zero-based ADR 0011 progress item and a gap-free
   durable event stream with no transport request IDs on asynchronous records;
5. publish a durable policy interaction, accept the exact response command,
   report that interaction resolved, and then publish a completed tool result
   for the same `tool_call_id`, proving the launch-configured policy authorized
   that deferred effect;
6. publish canonical `run.finished` followed by distinct `session.settled`, then
   satisfy a fresh attachment at that settled cursor with an authoritative
   inactive snapshot for the same session; and
7. emit only protocol-shaped records on stdout.

The client uses bounded pattern extraction and an ordered state machine over
canonical probe records. That is disclosed as an ordered shape check, not
general JSON conformance. Product selectors and golden vectors prove
order-independent decoding, semantic validation, and every error. Exact identity
matching, zero-based progress, gap-free event cursors, policy-authorized tool
completion, two terminal facts, and a fresh settled attachment prevent an echo
process or auto-resolving interaction from passing.

Anything short of the conjunction emits exactly:

```text
M4 gate RED: a separate program cannot initialize the experimental stdio JSONL session protocol or drive one Loopex session through correlated durable admission, asynchronous progress, a durable interaction round trip, terminal settlement, and a later snapshot
```

The bounded `LOOPEX_M4_PROBE` observation is appended on the same line. At
`cf77165` the expected observation begins with `launch=started initialize=eof`
because the healthy child process has no app-server entrypoint and closes without
a protocol record. A compile failure, missing dependency, unbounded wait, or
inability to allocate the isolated evidence root is unavailable evidence and
uses exit 2, never the declared red.

### Roles and isolation

The exact role grammar is ordinary, `--inspect`, or `--preflight`.

- `--inspect` verifies bound artifacts and governance paths without allocating
  a task root, compiling, or writing the checkout. It is the read-only review
  lane and can print only `M4 inspection OK`.
- `--preflight` adds the isolated compile and raw-process probe and stops after
  `M4 preflight OK`; it is a writable evidence lane.
- ordinary runs the complete gate after the probe turns green.

Every role refuses `LOOPEX_PROVIDER_API_KEY` before its first child. The writable
lanes require and physically resolve the checkout, ambient home, and real
product-state boundary, and install cleanup immediately after allocating one
task root outside both while retaining the original allocated path. They clear
ambient Mix, Hex, and Rebar path overrides; own
`MIX_BUILD_ROOT`, `HOME`, `HEX_HOME`, `REBAR_CACHE_DIR`, `LOOPEX_HOME`, `TMPDIR`,
and the probe workspace; force Hex offline; and compile into the initially absent
build root. Dependency source is reconstructed under that root only from
`mix.lock`-checksum-bound archives in the physically resolved fixed-home Hex
cache. The fixed-home installed Hex archive and per-Elixir Rebar tree are
validated as ordinary unlinked trees and snapshotted under the task root before
use. A success message is printed only after verified task-root removal.

The child receives an exact allowlist of toolchain and task-root variables, and
no provider credential. A child-output file limit is scoped to the raw probe,
stdout overflow is a behavioral red, and the client boundedly confirms direct
child exit with TERM/KILL fallback. The gate launches that client as leader of
an owned process group, terminates and boundedly confirms that whole group on
normal exit or interruption, and removes the task root only after confirmed
group extinction. A group that cannot be confirmed gone makes the gate
unavailable and leaves its isolated evidence root intact for diagnosis. Product
selectors separately prove product-directed cleanup of the entire app-server,
executor, and tool process tree. The deterministic opening probe makes no
real-provider claim.

Before its first child, ordinary mode boundedly reads at most one
`LOOPEX_M4_PROVIDER_V1\0<key>\0` frame into an explicitly de-exported shell
holder and redirects ambient stdin to `/dev/null`. No frame is required to prove
the opening red; if the primary probe becomes green, a missing frame is then
unavailable evidence. The retained key is translated only into the
already-accepted M0 environment input and M1/M2 bounded stdin frames.
Malformed or trailing credential input is unavailable, never PASS.
`--inspect` and `--preflight` define no credential input lane.

## Bound Artifacts

| SHA-256 | Path |
| --- | --- |
| `68735f06065184a5d836b9c90f1e66915b2ef664fe6460484cc3b9f1af815909` | `scripts/check-m4-gate.sh` |
| `e025f5f5d50109dfd181430ef1a8536b71f4d105c64b9af5b1c366d27cd57a7f` | `scripts/m4-black-box-client.exs` |
| `9cda7a770cd930558b2f0d7733e40ba29314f81eb96a49484330051dc4fe377c` | `scripts/fixtures/m4/session-protocol.schema.json` |
| `2941a4ff74824a0d84e10dce46a9807ff6ff900e71b8fb2d9c1dc20e5b3b826f` | `scripts/fixtures/m4/initialize.jsonl` |
| `49cf0f45523ed704ac400d3a971d802fb973f2b8b9c162a65464b727259d9c4c` | `scripts/fixtures/m4/probe-requests.jsonl` |
| `d30b04d60967ddc480efe258c9f30c384341bad71080bbd286959d79e80e57c9` | `scripts/fixtures/m4/defer-once-policy.exs` |
| `cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0` | `scripts/m1-exunit-runner.exs` |
| `0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d` | `apps/loopex/test/m1_exunit_runner_test.exs` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

The gate document externally binds its runner. The runner verifies every other
bound artifact before allocating evidence state. The standalone ExUnit runner
and adversarial corpus stay byte-identical to the inherited authoritative
channel; M4 adds roles but does not redefine what a protected result means.

The schema and request vectors are proposed protocol bytes. They are real and
digest-bound so the Open gate has a determinate probe, but they remain mutable
with the rest of the Open candidate. Before acceptance, ADR 0019 must be
Accepted, the complete schema/vector manifest must replace any draft breadth,
the gate must bind every canonical vector, and a fresh exact-SHA review must
judge their semantics. That is gate completion, not product implementation.

## Repository Commands

After the primary probe turns green, ordinary mode runs in this order:

| # | Command | Protection |
| --- | --- | --- |
| 1 | `mix loopex.status` | Governance, links, exact lifecycle capsule, plan envelopes, ADRs, and bound artifacts |
| 2 | `bash scripts/check-bootstrap.sh` | Portable repository aggregate |
| 3 | `bash scripts/check-m0-gate.sh` | Closed M0 protection |
| 4 | `/bin/bash -p scripts/check-m1-gate.sh` | Closed M1 protection at its latest accepted generation |
| 5 | `bash scripts/check-m2-gate.sh` | Closed M2 product behavior at its latest accepted generation |
| 6 | standalone protected M4 selectors | Exact roles, names, states, minima, seed, ownership, and dependency closure |
| 7 | complete credential-free suite at the gate seed | Unselected regression protection |
| 8 | retained evidence validation | Real task, restart, interaction, clients, malformed input, slow reader, matrix, package identity, and documentation |

The current Open runner names the product-selector command that becomes
reachable only after the primary red turns green. Before acceptance it must be
expanded to invoke every protected role through the authoritative standalone
channel and to validate the complete retained-evidence manifest. The accepted
bytes may not rely on a missing selector as their declared red.

## Protected Outcome Selectors

Each case below must exist, pass, and run through the authoritative standalone
channel at no less than the stated minimum before acceptance. Exact role names,
seeds, credential lanes, and case-state manifests are added to the canonical
runner bytes during Open review; their absence can never turn the primary probe
green.

| Outcome | Selector | Minimum | Locked cases |
| --- | --- | --- | --- |
| 1a | `apps/loopex_app_server/test/initialization_test.exs` | 6 | `a mutation before initialization creates no durable work`; `initialization succeeds exactly once and a repeated initialization is refused`; `no common protocol generation is refused`; `initialization returns the exact schema digest capabilities and enforced limits`; `protocol stdout carries only LF delimited JSON objects`; `bounded diagnostics use stderr and never stdout` |
| 1b | `apps/loopex_app_server/test/black_box_session_test.exs` | 3 | `a raw external client drives one session without loading candidate code`; `durable admission precedes asynchronous progress and terminal settlement`; `the settled session is proved by a later snapshot rather than an echoed frame` |
| 2a | `apps/loopex_app_server/test/session_rpc_test.exs` | 6 | `a client creates lists resumes inspects and attaches to sessions through the public facade`; `attachment returns an authoritative snapshot and current cursor`; `resume uses a fresh durable command identity`; `a different runtime placement identity is refused`; `a query response is correlation and never durable admission`; `an app server process owns no session truth after exit` |
| 2b | `apps/loopex_app_server/test/command_rpc_test.exs` | 7 | `prompt steer follow up and abort preserve the explicit M2 input algebra`; `every mutation returns one correlated durable admission or refusal`; `transport request identity is never used as durable command identity`; `identical command replay returns its historical admission`; `changed semantics under one command identity conflict despite changed JSON layout`; `unknown mutation is refused before durable admission`; `unsupported capability is explicit and never inferred` |
| 3 | `apps/loopex_app_server/test/stream_rpc_test.exs` | 7 | `snapshot cursor and later durable events are gap free in one session`; `progress never advances the durable event cursor`; `a progress gap falls back to durable state`; `a missing closure falls back to durable state without a timeout inference`; `provider and executor retry domains are never conflated`; `slow progress may coalesce without changing durable truth`; `a fresh process resumes from Store without claiming attachment continuity` |
| 4 | `apps/loopex_app_server/test/project_resource_rpc_test.exs` | 5 | `the client sees the exact resolved manifest before deciding`; `a matching positive decision stages the project block`; `an absent decision withholds the block journals decline and still runs`; `a stale workspace revision manifest or content invalidates approval`; `project trust grants neither tool authority nor policy approval` |
| 5 | `apps/loopex_app_server/test/artifact_rpc_test.exs` | 5 | `a spilled artifact is retrieved byte exactly through bounded chunks`; `each chunk reports range total media type and digest`; `an opaque reference exposes no path or Store handle`; `an invalid range or missing reference is refused`; `oversized artifact bytes never enter one oversized frame` |
| 6a | `apps/loopex/test/interaction_lifecycle_test.exs` | 15 | `policy defer commits a pending interaction before publication and dispatches nothing`; `an answer admission is not a policy allow or grant`; `an answered interaction survives owner succession and resumes policy evaluation`; `identical response replay returns its historical admission`; `changed duplicate stale expired mismatched and post abort responses are refused`; `response and expiry race by committed order`; `response and abort race by committed order`; `deadline keeps bound reached and outcome unknown precedence`; `a repeated defer resolves the prior interaction and creates a new identity`; `no client content request identity event or metadata can mint or widen a grant`; `M2 one shot policy decision refuses defer while M4 interaction aware evaluation preserves it`; `resumed policy evaluation reconstructs the byte exact original request and core created response member`; `malformed defer requests and invalid answers dispatch nothing`; `restart with a missing or mismatched policy binding stays suspended`; `only the configured policy allow commits a grant and executor intent` |
| 6b | `apps/loopex_app_server/test/interaction_rpc_test.exs` | 6 | `a requested interaction reaches the external client after its durable commit`; `the matching response command reaches only the public facade`; `restart reconstructs the pending interaction`; `transport loss changes no interaction state`; `resolved expired denied and cancelled states project truthfully`; `wire input cannot select or replace policy or provide policy context or a grant` |
| 7a | `apps/loopex_app_server/test/framing_test.exs` | 8 | `fragmented input and multiple frames per read preserve frame boundaries`; `invalid UTF 8 is refused`; `duplicate object keys are refused before map conversion`; `a top level non object is refused`; `excessive nesting strings collections and frames are bounded`; `unknown discriminants never create atoms`; `CRLF trailing bytes and EOF inside a frame are explicit errors`; `malformed input cannot contaminate later stdout records` |
| 7b | `apps/loopex_app_server/test/slow_consumer_test.exs` | 4 | `a stalled reader cannot block the session coordinator`; `durable output detaches at a stated cursor or admission refuses before mutation`; `progress pressure is bounded and may coalesce or drop`; `EOF grants nothing and leaves shutdown truth to the runtime` |
| 8 | `apps/loopex_protocol/test/public_schema_conformance_test.exs` | 7 | `transport neutral DTOs satisfy exact schema and golden vectors`; `protocol owns no JSON or runtime dependency`; `unknown field and value behavior is explicit`; `Elixir sample client executes the vector corpus`; `Python sample client executes the vector corpus`; `JavaScript sample client executes the vector corpus`; `source VERSION protocol generation and schema digest remain distinct identities` |

## Locked Supporting Mechanism Selectors

| Selector | Minimum | Protection |
| --- | --- | --- |
| `apps/loopex_app_server/test/facade_only_test.exs` | 4 | App-server modules reach only the public `Loopex` facade, own no second reducer, import no concrete adapter or human command, and cannot load product code into the raw gate client |
| `apps/loopex/test/status_check_test.exs` | accepted minimum plus M4 cases | M4 prerequisites remain visible in the Accepted-plus-Open composite and M4 cannot outrun any disposition |
| `apps/loopex/test/deps_budget_test.exs` | accepted minimum plus app-server cases | Exactly nine apps, no external dependency anywhere in the umbrella, and no client-to-client edge |

## Mandatory Closure Evidence

Closure requires retained records bound to the exact product candidate SHA, gate
digest, schema/vector manifest digest, command, seed, toolchain/platform, limits,
and non-secret provider/model/adapter/executor identities:

1. raw black-box transcript and stdout/stderr capture;
2. protocol/schema/vector conformance report;
3. real-provider, real-tool coding task driven by a non-Elixir client;
4. process-kill and fresh-process resume trace with no duplicate admission;
5. interaction suspend, restart, answer, policy decision, and effect trace;
6. malformed, oversized, fragmented, duplicate-key, and stdout-contamination negatives;
7. slow-reader queue, memory, and timing evidence;
8. executed Elixir, Python, and JavaScript sample-client records at declared
   interpreter versions;
9. a record proving the app-server encodes and decodes with the
   standard-library `JSON` module and declares no external dependency;
10. Darwin and Linux evidence on the accepted toolchain pairs; and
11. facade-only and no-second-loop negative demonstration.

Credentials, tenant identifiers, and secrets never enter those artifacts. A
missing interpreter, provider channel, platform, or retained record is
unavailable evidence and blocks closure rather than becoming a skipped pass.

## Documentation Obligations

| Category | Required closure disposition |
| --- | --- |
| Operator-facing documentation | `docs/operator/app-server.md` |
| Operator README | `docs/operator/README.md` |
| Developer-facing documentation | `docs/developer/app-server-protocol.md`, `docs/developer/runtime-and-embedding.md` |
| Developer README | `docs/developer/README.md` |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |
