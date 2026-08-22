<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](M1.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M1.md#concept-plan-scope).

Concept: [Milestone non-goals](M1.md#concept-plan-non-goals).

The architecture prerequisites are settled and accepted:

- **ADR 0001** fixes the repository and application dependency direction.
- **ADR 0002** fixes the OTP 26+/Elixir 1.17+ floor and the two exact validation
  pairs.
- **ADR 0003** fixes the protocol-only contributor boundary for any extension;
  M1 recognises that role but creates or publishes no extension.
- **ADR 0006** fixes the store transaction contract, commit-time owner-epoch and
  incarnation fencing, transaction resolution, and durable record requirements
  used by outcomes 2, 3, and 8.
- **ADR 0007** fixes the trusted-local executor grant, job, receipt, final
  pre-start validation, and independent binding oracle used by outcomes 6 and
  8.

This plan does not reopen or restate those decisions. In particular, replay is
an audit of store enforcement and cannot become the stale-writer fence, and a
grant-shape check cannot replace value comparison at the final serialized
pre-start boundary.

No product implementation is authorized until the maintainer or a recorded
delegate accepts both normative envelopes and the gate's canonical bytes
together. Before that Acceptance record may be completed, the exact clean
candidate must produce the declared M1 opening red on every opening platform
lane and independently keep the immutable M0 gate green on both locked
toolchain pairs, including its real-provider role. The two M0 runs are
out-of-band acceptance evidence: they are never pasted into a gate input,
nested inside the M1 runner, or replaced by bootstrap, status, a credential-free
subset, or a run at another SHA. Missing provider authority makes that evidence
unavailable and blocks acceptance rather than becoming a skip.

Acceptance authorizes only the eight outcomes and their three named boundary
behaviours. Any deferral, gate weakening, evidence waiver, fourth product
boundary behaviour, new persistence decision, or public compatibility claim
requires its ordinary explicit disposition; none is implicit here.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M1.md#concept-plan-scope).

One integrator owns rejoin, conflicts, the candidate SHA, and post-rejoin
verification. The maintainer owns plan and gate acceptance, scope deferral,
gate weakening, evidence waiver, blocking-finding disposition, closure, and any
decision class reserved by the development contract.

The durable store is authoritative for the current
`{owner_epoch, owner_incarnation_id}` and journal version. A coordinator becomes
the current serial session owner only after succession commits. It serializes
reduction and requests store transactions, but cannot override the store's
atomic comparison. A delayed result may describe a transaction that committed
while its originator was current; it never gives a superseded process authority
to update the current cache, publish, dispatch, or authorize work.

Before that ownership can exist, the same Store boundary owns one catalogued
runtime-control transaction that atomically allocates the session ID, resolves
and records the `(runtime_id, command_id)` mapping, and commits genesis. An
identical create re-presentation returns the same session ID; the same identity
with changed canonical bytes conflicts. The initial coordinator and every
resumed coordinator then commit ADR 0006 `advance_owner` before admitting a
session command. Runtime control does not add a fourth product boundary.

The runtime reference owns all instance-local supervision and configuration.
No globally registered process name, application environment value, persistent
term, or other VM-global lookup supplies a runtime reference or hides
per-runtime state. Runtime-scoped registries reached through that explicit
reference remain permitted. The embedded API routes through the same reference.
The public-event path reads the durable outbox; transient progress and
diagnostics are replaceable views and never session truth.

The host is the sole grant issuer. The trusted-local executor independently
holds or receives the values against which it checks the grant, keeps the
workspace lease for the job's lifetime, and alone crosses the final effect-start
boundary. The model adapter and executor return evidence to the coordinator;
neither mutates session truth or publishes durable facts directly.

Rejoin barriers are serial and exact:

1. **A — Store and durable truth rejoins first.** The core Store behaviour and
   production transition catalogue, plus `loopex_store_local`'s in-memory and
   durable local implementations and ADR 0006 conformance, are integrated
   before a runtime relies on them.
2. **B — Runtime and embedded API rejoins second.** Explicit supervision,
   session ownership, durable outbox delivery, and the direct embedded facade
   build on A. No model or tool dispatch is integrated before B proves that a
   superseded owner cannot make work eligible.
3. **C — Model and executor boundaries rejoins third.**
   `loopex_llm_reqllm` owns the concrete ReqLLM implementation and the
   adapter-only Outcome 5 selector; its test-local deterministic implementation
   and reusable conformance run without starting a runtime instance.
   `loopex_executor_local` owns the trusted-local executor and Outcome 6. Both
   are edge applications with a production dependency inward on core and do not
   import a concrete sibling adapter. A direct configured executor is
   sufficient; no broker is introduced.
4. **D — Client and combined demonstration rejoins last.**
   `loopex_reference_client` owns the thin client and the test-only composition
   for Outcome 5's session-integration evidence and the OS-process recovery trace
   through the integrated A, B, and C paths. A private client loop, substitute
   store, fake provider, or bypass executor is not a demonstration of the
   milestone.

Parallel writers use non-overlapping file ownership, separate branches or
checkpoints, separate worktrees, and isolated build/dependency/state roots. No
workstream creates an alternate durability truth, authority path, or session
loop to avoid a barrier.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M1.md#concept-plan-outcomes).

The outcome selectors are necessary but not separable substitutes for the
Purpose. Closure requires one retained vertical demonstration through the same
product runtime, store, model, executor, embedded API, and reference-client code
the focused selectors exercise. The first real call uses a provider- and
adapter-supported forced, deterministic selection of the registered
demonstration tool; prompt-only cooperation does not qualify. Its second real
model call occurs only after the external harness has untrappably killed the
runtime OS-process tree at the named fault point, a new process has restarted,
and the retained receipt has passed current reconciliation. The real-provider
trace itself proves the integrated recovery claims; deterministic cases are
supporting coverage and cannot stand in for it.

Every protected selector runs through the gate-bound standalone
`scripts/m1-exunit-runner.exs`, outside every product application. The gate
invokes that script directly with `elixir`; the script starts and configures
ExUnit itself, dispatches no Mix task or alias, and does not load
`test_helper.exs`. It receives the exact invocation role, selector path, seed,
minimum, exclusion policy, and expected test identity and state. Official
ExUnit results, rather than test-owned stdout, must show every locked name in
the required state, the locked minimum, and no unaccounted skip, exclusion,
filter, quarantine, pending case, setup failure, or test failure.

The runner is an authoritative reporting channel, not a security boundary. It
loads and executes candidate application and selector code in its own VM, so
that code is trusted and remains subject to independent review for dishonest
assertions, process termination, or deliberate interference. The direct
channel prevents Mix-task interposition, accidental `test_helper.exs` state,
and forged human-readable summaries from satisfying the gate; it does not claim
to sandbox a hostile candidate.

The ordinary full suite and every credential-free control remain
credential-free. The outer gate refuses `LOOPEX_PROVIDER_API_KEY` in its initial
environment. Before it reads optional provider stdin or starts any external
child, Bash builtins set and verify both soft and hard core-file limits at zero.
An interactive stdin or immediate EOF means no key; otherwise only exact
`LOOPEX_M1_PROVIDER_V1\0<key>\0` framing is accepted, with a nonempty key of at
most 16,384 bytes, LF preserved inside the key, and every other nonempty input
refused. That exact parse establishes frame validity only: a valid key,
including `0`, is refused later when its literal bytes collide with a required
gate-owned control or complete would-be output. Only the explicitly tagged
real-provider invocations receive the key through exact
`LOOPEX_M1_SELECTOR_V1\0<32-lowercase-hex-nonce>\0<key>\0` framing; absence is
evidence unavailable and fails those invocations rather than skipping them.
The key is never conveyed through argv, an inherited child environment, a file,
or retained output. Immediately after successful frame parsing, the outer Bash
process starts its bounded capture before path discovery, absence-root reads or
redirections, environment inspection, and launcher preparation. It captures
that complete post-intake phase plus combined launcher/child output and exact
status behind a validated non-LF suffix, restores all preceding terminal LF
bytes, counts them under a private
non-exported C byte locale, refuses NUL or a sealed stream exceeding 16,777,216
bytes, and emits only after one literal-key collision check over the complete
would-be output. Inner failure
diagnostics, the environment fixture, and the final capture/GREEN record use the
same complete-LF emission invariant; a collision exits nonzero and suppresses
the colliding bytes rather than redacting or blacklisting a spelling.
Before its first external child, Bash derives and checks the exact executable,
incoming `PATH`, and conventional `_` name, value, and serialized records that
the following outer environment inspection validates. Before the key enters the
launcher frame, Bash separately checks the exact non-secret frame, environment,
and argument arrays used by that invocation. Before the launcher forwards the
key to the sealed child, it independently derives the child manifest from the
exact executable, arguments, environment names and values, and non-secret
inner-frame values used by `open_port` and stdin. Every check refuses literal
collision and is consumed at the boundary that derives it, so no parallel
enumeration can drift from the actual carrier construction.
`run_gate_test` captures selector stdout/stderr plus exact
status by appending a validated non-LF terminal status suffix before Bash
command substitution and removing only that suffix afterward. This preserves
all preceding trailing LF bytes for literal key detection while retaining the
child exit exactly. The retained `ERL_CRASH_DUMP` controls disable gate-owned
BEAM dump files, and the sealed zero hard core limit prevents file-backed OS
core dumps; privileged host crash collectors remain host authority and are not
controlled by the gate. Retained real-path evidence contains
only non-secret provider/model/endpoint, adapter build, executor build and
runtime identity, tool identity, and an exact UTC observation time. Those values
come from the successful real-role process and are sealed into its nonce-bound
authoritative result, not read from candidate prose. Candidate `C` plus the
fixed application/version token identifies the exact adapter and executor
source build.

Durable fault coverage is structural rather than an enumerated test list. A
catalogued durable mutation is any logical operation that can change a
runtime-to-session mapping or genesis, the current owner or head, transaction
resolution, journal record set or version, or outbox eligibility. Every such
operation enters through one production transaction
dispatch, and every executable transition phase carries a stable
`fault_point_id`. The authoritative catalogue key is the exact
`{transition_id, fault_point_id}` pair; one transition ID with uncatalogued phase
positions is insufficient. The mutation backend is unreachable without that
dispatch, and missing or unknown keys are refused. The test fault injector is
derived from those executable declarations, and evidence asserts set equality
between the complete declared, injected, and observed key sets. Closure review
confirms that no durable-mutation bypass exists; it does not fill an omitted
catalogue row. Every durable transaction declares and covers at least these
distinct phase keys:

1. before its store linearization point;
2. after linearization but before the caller receives the result or makes its
   outbox records eligible for publication; and
3. recovery and exact transaction re-presentation.

Effect recovery separately faults after intent commit but before dispatch,
after dispatch when acceptance is unknown, after a durable executor receipt but
before its session fact commits, and after an effect may have occurred without a
provable receipt. A new production transition without a derived injected and
observed case fails the equality assertion instead of silently escaping the
catalogue.

Receipt reconciliation is mutation-sensitive rather than positive-path only.
The production receipt/reconciliation identity schema drives one otherwise-valid
wrong-value case for every required current query/recovery binding and retained
origin binding, and the evidence asserts that the refused-field set equals the
schema's required set. A separate protected conformance assertion strictly reads
the following independent semantic oracle from this accepted envelope and
requires it to be a subset of the production schema, so deleting a required
binding from production cannot shrink its own corpus and certify the omission.
Production may add bindings; every added required binding automatically joins
the derived wrong-value corpus.

<!-- loopex:reconciliation-oracle:start -->
```text
current_reconciliation_query_id
current_session_epoch
expected_executor_identity
current_recovery_contract
journaled_operation_id
original_attempt
journaled_canonical_request_digest
original_session_epoch
original_executor_epoch
origin_executor_identity
origin_fencing_token
```
<!-- loopex:reconciliation-oracle:end -->

These are role-qualified semantic checks, not mandated wire-field spellings.
The current-query values and retained-origin values remain distinct even when an
implementation happens to encode them with related names.

Required mutation evidence contains exactly five ordered, independently restored
records: Outcome 2 / `current_owner_post_commit_fence`; Outcome 3 /
`store_atomic_admission_compare`; Outcome 3 /
`commit_unknown_dispatch_fence`; Outcome 6 /
`executor_final_prestart_validation`; and Outcome 8 /
`no_blind_retry_without_receipt`. Each record starts from its own named clean
candidate, identifies the exact path and candidate blob digest, disables only
that mechanism, runs the named protected selector that must fail for the named
reason, restores the artifact from `git show <candidate>:<path>`, and verifies
the restored SHA-256 and whole-tree cleanliness before the next record. No
record stands in for two mechanisms, and a failure observed from a dirty or
previously mutated baseline is no evidence.

The named mutation selectors are
`apps/loopex/test/session_lifecycle_test.exs` for Outcome 2,
`apps/loopex_store_local/test/store_conformance_test.exs` for both Outcome 3
records, `apps/loopex_executor_local/test/executor_test.exs` for Outcome 6, and
`apps/loopex_reference_client/test/end_to_end_recovery_test.exs` for Outcome 8.
Outcomes 1, 2, and 4 retain their core selectors; Outcome 5 deliberately splits
adapter conformance at
`apps/loopex_llm_reqllm/test/real_model_lane_test.exs` from session integration
at `apps/loopex_reference_client/test/real_model_session_test.exs`; Outcomes 3,
6, 7, and 8 run from the adapter or client application that owns their
implementation or composition, exactly as the Concept outcome table records.

Execution evidence has three non-self-referential full M1 captures: Darwin at
the exact floor pair, Darwin at the exact current pair, and Linux at the exact
current pair. Each capture starts from the same clean committed source candidate
`C`, runs the complete captured M1 command set except verification of the
evidence record it is about to create, and emits one authoritative non-gate
`CAPTURE` record only after those commands pass. A capture never calls the
ordinary gate recursively, emits GREEN, or supplies merge evidence. The Linux
lane is an orthogonal platform proof at the current pair; it does not claim the
untested floor-on-Linux combination or freeze a public support matrix.
Every lane fixes `LANG` and `LC_ALL` to `C.UTF-8`, proves the locale resolves to
the exact `UTF-8` charmap before the opening red, and requires the running BEAM
to report native UTF-8 filename encoding when it validates the toolchain pair.

The same evidence set contains exactly one separate exact-`C` re-proof of the
immutable M0 gate on the floor pair and exactly one on the current pair. The M1
capture runner never nests the M0 runner, and bootstrap cannot substitute for
either inherited-green proof. Each M0 invocation captures stdout and stderr
before any diagnostic and redacts the provider credential before retaining or
printing a field. The retained evidence binds `C`, both gate digests, the exact
commands and toolchain pairs, exit and verdict, and only non-secret
provider/model/endpoint identity.

Each M1 capture row records its exact operating-system family, architecture,
open-file, process, soft-core, and hard-core limits, with both core limits
required to equal zero and serialized in the exact order
`limits=core-soft-0,core-hard-0,nofile-<positive|unlimited>,nproc-<positive|unlimited>`,
then retains eight ordered printable-ASCII/UTC
fields from the combined real-role result: provider, model, endpoint, adapter
build, executor build, executor runtime identity, tool identity, and observation
time. The model-only and combined real roles must agree on their shared fields
before the outer runner may emit the row. All three rows must agree on every
real-path identity except their separately valid observation times; architecture
and limits are independently recorded audit facts rather than equality
constraints. The bound verifier rejects Unicode lookalikes, bidirectional
controls, field drift, an unbound build identity, or a lane/OS/toolchain
mismatch.

Every M1 capture and M0 re-proof uses fresh, disjoint build, dependency,
temporary, `LOOPEX_HOME`, workspace, and product-state roots. No execution may
consume mutable output from another, so physical order and adjacency are
semantically inert; the records are identified by their unique lane, not by a
claimed execution walk. Repeating a green execution proves nothing additional.
A retry is diagnostic, and a same-SHA, same-seed, same-environment failure that
later disappears remains a blocking flake until fixed or explicitly
dispositioned.

The three M1 captures are committed in evidence commit `E`, which must be the
direct one-parent child of `C`. `C→E` may change exactly
`docs/evidence/M1-toolchain-matrix.md`; every other tree byte is identical, and
the current matrix file must equal `E`'s blob. The ordinary gate runs at `E` on
all three execution lanes, uses the bound M1 verifier below to validate the
retained evidence and exact `C→E` relationship, reruns its ordinary commands,
and alone may emit final GREEN. Before closure an interposed descendant of `E`
is not a substitute for `E`.

Closure transition `T` is the unique commit that first completes M1's canonical
Closure record. It must be the direct one-parent child of `E`, and `E→T` may
change exactly `docs/plans/M1.md`, `docs/plans/README.md`, and `README.md` with
no product, selector, harness, evidence, or gate byte. The plan change fills
only the previously empty Closure row, retains Acceptance, and binds reviewed
candidate `E`; the two derived status documents change only their canonical
marked status blocks. An interposed commit, merge parent, bundled product byte,
wrong binding, second first-completion event, or other changed path invalidates
the transition.

Later descendants may retain the historical evidence only while `E` and `T`
remain reachable, the matrix blob remains byte-identical to `E`, and M1's
canonical Closure record remains byte-identical to the binding that names `E`.
The capture records name `C`; the exact evidence-only `C→E` relationship proves
that product, selector, runner, verifier, dependency-authority, toolchain, and
gate bytes reviewed at `E` are those captured at `C`. Changing any of those
bytes before closure requires a new `C`, three new M1 captures, two new M0
re-proofs, and a new direct evidence commit.

One canonical decimal gate seed from `0` through `999999` is supplied to every M1 protected
selector role, provider default-exclusion control, and the ordinary final full
suite in that gate run. It does not describe bootstrap's internal tests.
`protected_executed` is the sum of authoritative executed test counts assigned
to the eight logical Outcomes across their locked selector roles; a test
reported excluded never counts. Mechanics, bootstrap, standalone
default-exclusion-only control executions, and the final full suite are
excluded. Each of the three captures emits its seed and protected executed
count.

Outcome 5 uses three roles with an aggregate logical minimum of three: the
credential-free adapter-default role passes only the shared conformance name;
the credential-free session-default role passes the committed-request name and
records the real session name excluded; and the session-real role receives the
credential, passes only that real session name, and records the deterministic
session name excluded. Outcome 8 retains one credential-free default role and
one real-provider-only role: the default role provides supporting deterministic
coverage and records the real name excluded, while the real-only role passes the
real-path name and records the supporting names excluded. The roles' executed
counts sum to each Outcome's locked logical minimum. Every capture also binds
the exact source candidate, gate digest, command, toolchain, OS, architecture,
limits, timing, seed, authoritative protected count, result, and its nonce-bound
combined real-path identity.

Mechanical and judgment authority are intentionally separate:

| Authority | Owns |
| --- | --- |
| Bound `scripts/m1-evidence-verifier.exs` | The exact M1 matrix/negative-evidence grammar and record cardinality; per-capture platform, limits, and identity validity; cross-lane real-path identity equality; unique Darwin-floor, Darwin-current, and Linux-current records; bound source, gate, ExUnit-runner, dependency-authority, and verifier bytes; the direct one-parent `C→E` evidence-only relationship; the direct one-parent `E→T` transition-only relationship when Closure exists; the exact allowed changed paths and blobs; and the later-descendant reachability, matrix-byte, and Closure-binding invariants |
| `mix loopex.status` | Live consistency among M1's governance rows, plan register state, root README status capsule, indexes, links, and the current revision's lifecycle claims |
| Independent review | Whether retained fields match the actual captured process output; whether tests and assertions are honest; whether platform, limits, provider, model, endpoint, adapter/executor/tool identity, counts, timing, and environment claims are truthful; whether the closure document set is semantically current; and whether the explicit maintainer disposition makes the exact transition acceptable |

`scripts/m1-evidence-verifier.exs` is self-contained M1 gate machinery. It uses
only the Elixir standard library and Git, imports no generic Matrix or status
parser, and makes no semantic acceptance decision. The ordinary gate may run
repository-wide `mix loopex.status`, but M1 does not bind or freeze
`Mix.Tasks.Loopex.Matrix`, the status task, or any generic parser they use.
Those commands remain evolvable repository checks; neither may become a second
M1 evidence grammar or C/E/T authority.

Validation and copying of installed prerequisite sources operate under the
ordinary assumption that another process is not maliciously replacing those
sources between checks. The runner physically validates every copied source root
and traversed symlink target immediately before copying, inventories sources
without following descendant links, and rejects any regular-file device/inode
also present in the first protected-state inventory. It refuses unresolved,
symlinked, hard-linked, or otherwise protected-state aliases, but makes no
cross-process exclusion claim.

Outcome-specific obligations are:

| # | Obligation |
| --- | --- |
| 1 | Start two supervised runtimes in one VM with distinct configuration, store instances, and state roots; prove their data and failures do not cross; prove every public operation needs its explicit runtime reference and that neither a global registration nor application environment can supply one |
| 2 | Make session creation a catalogued runtime-control transaction in the Store boundary that atomically commits session-ID allocation, `(runtime_id, command_id)` resolution and mapping, and genesis before acknowledgement; prove identical create re-presentation returns the same session ID while the same identity with changed canonical bytes conflicts; require the initial and every resumed coordinator to commit ADR 0006 `advance_owner` before admitting a session command; generate legal command and recovery histories around that ownership succession; prove a second current owner cannot be admitted and a second prompt is refused while a run is active rather than starting another run; exercise a superseded process at every post-store-result path and prove it cannot newly commit or use a delayed result to change the current cache, publish, dispatch, or authorize; assert complete derived fault coverage over runtime-control creation and later ADR 0006 mutations |
| 3 | Run the reusable ADR 0006 live transaction-semantic layer unchanged against the in-memory test implementation and durable local store; against the durable implementation additionally cover retained known and unknown transaction resolution, durable non-commit outcomes, consecutive store-stamped versions, outbox identity, restart/replay, corruption visibility, and process/store faults; in both layers cover binding conflicts, all three call outcomes, compare order, atomic owner succession, and `commit_unknown` fencing, then mutate commit-time fencing and prove replay cannot replace it |
| 4 | Prove create/resume, command, and attachment use the explicit embedded runtime facade; atomically establish an attachment barrier at committed sequence N, return an authoritative snapshot anchored at N, then deliver buffered and live durable events after N contiguously with at-least-once deduplication by session, sequence, and event ID; configure a positive finite per-attachment queue capacity B, stop the one caller from consuming, commit more than B events, and prove the queue never exceeds B, the attachment disconnects while retaining its last stable cursor into committed durable public-event history, session commits remain live, and the same caller reattaches after runtime restart and resumes without a gap; do not persist attachment or subscriber state; prove dispatcher failure and restart preserve event identity and sequence, and prove progress or diagnostics cannot be read as durable truth or block a coordinator |
| 5 | Run one supporting conformance suite against the deterministic model and ReqLLM adapter from the adapter application without starting a runtime instance; in the reference-client composition selector's explicitly invoked real-provider role, prove the production adapter receives only the exact canonical request bytes whose versioned digest and intent the session committed before dispatch and completes that real call; retain only non-secret provider identity; prove absent credentials and a zero-executed or skipped provider role cannot pass |
| 6 | Prove only an explicit host-policy `allow` path issues a grant and that model output, Loopex internals, tool metadata, and ordinary client input cannot mint or widen one; assert the production required-binding schema equals ADR 0007's protected independent ten-binding oracle; derive validation and separate missing and present-but-wrong corpora from the production schema, require exact coverage equality and refusal reason per binding; independently canonicalize the immutable `JobRequest`, recompute and compare its digest, and require the retained receipt to echo the verified digest and complete origin tuple; prove no controlled OS process starts before final serialized validation succeeds, the workspace lease remains held for the full job, and lease loss cancels or kills owned work with retained evidence rather than success; then have the executor start a separate OS process that performs one bounded observable write beneath the isolated workspace, prove its exact bytes and bound terminal receipt, and prove that an in-VM function, no-op, or path bypassing executor process start cannot satisfy the evidence |
| 7 | Drive start, create/resume, command, event consumption, terminal observation, and shutdown through the embedded API; replace or instrument that facade so the test fails if the thin client reaches coordinator, store, model, executor, journal, or outbox internals or owns a second state machine; no wire or line-framing contract is introduced |
| 8 | In one real-provider retained trace, count logical dispatch and the observable effect outside both runtime incarnations; use provider- and adapter-supported forced deterministic selection of the registered real tool rather than prompt cooperation; prove the executor starts that tool with an explicit environment containing neither the provider credential name nor its value; after the executor durably retains its receipt but before the session commits the receipt fact, have the external harness untrappably kill the runtime OS-process tree at the production-catalogued phase; start a fresh process, durably advance ownership, issue a current solicited reconciliation query, validate the complete retained receipt tuple, commit it once, publish from the outbox, make a second real model call, and reach a terminal result with exactly one logical dispatch, exactly one effect, and no acknowledged-fact loss; derive and refuse an otherwise-valid response with each current-query or retained-origin identity wrong and prove complete schema coverage; separately prove insufficient effect evidence commits immutable `outcome_unknown` and causes no blind retry; deterministic tests support these edges but do not substitute for the single real trace |

The kill in outcome 8 is an external, untrappable operating-system termination
of the runtime process tree, not an Erlang-process restart, a graceful shutdown,
an in-runtime kill hook, or distribution. Durable store bytes, retained executor
evidence, and external dispatch and effect counters survive the runtime process
so the new process cannot satisfy its assertions from old memory. The harness
chooses the exact phase from the production catalogue; a special alternate
session loop is forbidden.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M1.md#concept-plan-scope).

No public contract, protocol, storage format, or package is frozen. The embedded
API is the reference semantic surface for this milestone's one attached caller,
not a released surface. The store, model, and executor behaviours carry reusable
conformance suites so later implementations can be evaluated, but those shapes
remain unreleased until a future accepted milestone supplies schemas, vectors,
independent consumers, migrations, and upgrade/rollback evidence.

Milestone execution is nevertheless portable across the three locked lanes:
Darwin floor, Darwin current, and Linux current. The Linux lane runs the same
source, shell gate, protected selectors, credential-free suite, real-provider
roles, local executor, process-kill recovery trace, and evidence verifier; it is
not a reduced smoke test. Each row retains its OS, architecture, open-file and
process limits. This demonstrates Linux runnability without asserting a
floor-on-Linux result, a package-install contract, or a permanent public support
matrix.

Durable M1 sessions must resume across the process kill and the same-candidate
restart exercised here. That is a recovery guarantee, not an installed-version
upgrade or downgrade promise.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M1.md#concept-plan-scope).

There is no installed base and no released artifact. M0 journals and retained
evidence are not migrated; M1 tests and demonstrations create isolated M1 data
roots. No PostgreSQL, SQLite, or other external store migration is claimed.

Before M1 first becomes green, every checkpoint offered for integration or
review keeps bootstrap and both exact M0 lanes green while the M1 runner reaches
its next truthful missing-behavior red. The accepted opening checkpoint remains
the complete repository rollback target: reverting unintegrated M1 work to it
restores the accepted red condition without rewriting durable user data. After
a complete M1 candidate first becomes green, each later checkpoint must keep M1
and both M0 lanes green or be reverted to the last reviewed green checkpoint.
Ordinary local red-green work between checkpoints is not represented as an
integration candidate.

The closed M0 gate remains immutable. Its two pre-acceptance runs establish the
green base for the accepted opening SHA; it is then re-proved independently
exactly once on each locked pair at every new source candidate `C` under the
retained evidence obligation above. The direct `C→E→T` chain carries those
same-source proofs through closure; another proof is required whenever a new
`C` is required. M0 is never nested inside the M1 runner.

The branch does not merge while M1 is red. No rollback claim extends to a data
root written by a different source revision, because this milestone accepts no
installed-store compatibility contract.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M1.md#concept-plan-scope).

No package is published, installed, or versioned for distribution. ADR 0001's
umbrella direction and ADR 0002's runtime floor remain unchanged.
`apps/loopex_store_local`, the existing `apps/loopex_llm_reqllm`,
`apps/loopex_executor_local`, and `apps/loopex_reference_client` own the local
Store, ReqLLM model, local Executor, and reference-client implementation or
composition respectively. The Store, ReqLLM model, and Executor applications
are uniform `:edge` roles: each declares a production in-umbrella dependency on
`:loopex` and may also depend directly on `:loopex_protocol` when it uses
contract modules. An edge-specific external dependency remains confined to that
edge application; for M1 the only such direct dependency is exactly
`{:req_llm, "~> 1.17.1"}` in `loopex_llm_reqllm`. ReqLLM and its types do not
cross into core. Core uses only
Elixir/Erlang standard-library and OTP facilities, retains only its inward
protocol edge, and gains no runtime, development, or test dependency on an edge
or client application.

The reference-client application's test configuration may depend on the
concrete Store, model, and Executor implementations solely to compose the
Workstream-D demonstration. Its production client code depends only on and
drives the embedded API. These applications implement the three named boundary
behaviours or compose the direct facade; packaging them does not add a fourth
behaviour.

The gate-bound `Loopex.Checks.DepsBudget` direct source entrypoint is the sole
dynamic application-role and dependency authority for the M1 gate. Every
candidate byte executes from an invocation-owned, non-hardlinked detached
checkout of the exact clean commit, so ignored physical paths and ambient
repository dependency sources cannot join the build. Before Mix evaluates that
checkout, the authority requires the physical and stage-zero umbrella project
sets to agree and statically reads only the configuration needed to prove
project identity, exactly one literal `loopex_role`, literal production and test
dependency declarations, closed internal dependency options, and literal
`elixirc_paths`/`erlc_paths` owned by that application. Existing compiled source
files are tracked ordinary blobs, and the umbrella root owns no application
source. The parser neither executes child project code nor requires a canonical
whole-file AST. Unrelated Mix metadata, ordinary aliases, `application/0`
supervision metadata, test/docs paths, other compiler settings, and other
project configuration remain allowed when they do not alter these authority
fields. Literal locked-command aliases are refused as defense in depth.

The task derives the inventory and all permitted inward edges from those
literal declarations. The physical inventory may contain only the six named M1
applications with their exact roles; core and protocol are always required,
and the protected selectors make the other four mandatory before green.
While that inventory is incomplete, only the existing ReqLLM edge may retain
its inherited M0 production dependency on protocol without core. A complete
inventory—which every green candidate necessarily has—removes that sole staged
exception and requires ReqLLM's production core edge. Every other present app
always obeys its final role rule.
`:contract` has no dependency; `:core` has only its
production `:loopex_protocol` edge and no external or edge/client dependency in
any environment; `:edge` depends on production `:loopex`, may also use
`:loopex_protocol`, and imports no concrete sibling; `:client` depends on
production `:loopex` and may compose concrete edges only in tests. No extension
or seventh application is admitted. Only `loopex_llm_reqllm` may declare a
direct external requirement, exactly `{:req_llm, "~> 1.17.1"}` without source
options. Its canonical `mix.lock` record and exact required non-optional
transitive closure name the only package archives accepted by the offline
materializer; a missing or unsatisfied transitive and any unreachable extra
lock record fail. Both package archive and embedded checksum fields are
verified. The checksum-bound archive's `metadata.config` is parsed as literal
Erlang terms without evaluation and must match the lock's package name,
version, build tools, and dependency records exactly. Every Mix-managed package
has exactly one valid Elixir requirement admitting 1.17.0; a non-Mix package
may omit it, but any present requirement must admit the floor. Every archive is
kept disjoint from protected filesystem identities before and after its bound
read, all package authority is validated before the destination write, and Hex
SCM's `.hex` marker is then derived from the verified name, version, managers,
repository, and inner/outer checksums. A package payload cannot supply that
marker; only regular, safe relative files are written into the owned dependency
tree. The
umbrella root declares no role. Unknown or duplicate identities or
roles, nonliteral dependency construction, alternate path/SCM sources,
redirected in-umbrella paths,
reverse/outward/sibling edges, or foreign compile roots fail closed.

M1's contract compiler input is explicitly Elixir-only. `.erl`, `.hrl`, `.xrl`,
and `.yrl` inputs are refused rather than covered by a partial scanner. The
Elixir scan covers every declared compile root, permits the owned
`Loopex.Protocol.*` namespace in ordinary, explicit-root, and literal-module
forms, rejects other static `Loopex.*` references, and rejects unambiguous
computed dispatch independent of layout. No-parentheses field access remains
valid data access; the deprecated computed-module spelling with the same AST is
inside ADR 0001's existing arbitrary-computed-identity review boundary. Later
Mix project/config execution is trusted candidate code, so arbitrary runtime
task creation is likewise an independent-review boundary rather than a
mechanical non-interposition claim. No second M1 parser or source scan redefines
this inventory or these rules. The single-project parser still recognises ADR
0003's protocol-only extension shape for contract validation, but the M1
repository overlay admits no extension and adds no extension scope.

The durable local store uses the accepted dependency budget. Adding an external
database or storage library is not authorized by accepting this plan and
requires its ordinary dependency decision. No PostgreSQL, SQLite, or other
external adapter or configuration format is M1 scope; only the accepted store
contract constrains a future adapter.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M1.md#concept-plan-scope).

The working trace is the unit of value. Focused tests, retained evidence, and
repository checks support it but cannot satisfy an outcome in its place. Gate
work before acceptance is limited to direct portable enforcement that measures
the accepted obligations honestly: the outer gate runner, one standalone M1
ExUnit runner, one self-contained M1 evidence verifier, one bound OTP
environment launcher, and the single dynamic dependency authority above. The
launcher exists because preserving an ambient search path would weaken M1's
credential and command containment, while assigning one in shell would break
the immutable M0 gate. It only clears and replaces the sealed runner's process
environment, preserves an exact incoming M0 absence-stub root ahead of the
derived toolchain path, conveys bounded versioned private controls over stdin,
and returns the child's bytes and exit status. The outer shell has already
sealed and verified both core limits at zero before it can read those controls
or spawn the launcher. Gate-owned BEAM dump files are disabled by the retained
`ERL_CRASH_DUMP` controls, and the zero hard core limit prevents file-backed OS
core dumps; privileged host crash collectors are host authority and are not
controlled. The launcher is not a general command runner. These tools
remain repository tooling outside the product boundary and create no product
mechanism or generalized evidence framework.

Exactly three product boundary behaviours are permitted:

1. **Store**, giving the in-memory test implementation and durable local store
   one ADR 0006 live transaction contract while reserving persistence, restart,
   and replay conformance for the durable implementation.
2. **Model**, unifying the deterministic and ReqLLM implementations.
3. **Executor**, required even with one trusted-local implementation because it
   is the authority and effect-start boundary fixed by ADR 0007.

The embedded API is a direct facade over an explicit runtime reference. Host
policy may use the documented trusted-local `AllowAll` implementation to issue a
grant, but M1 introduces no generic policy framework. There is no broker,
transport behaviour, daemon, repository registry, generic event bus, alternate
session engine, or common "operation framework" added merely to unify unlike
model and executor semantics.

A fourth product boundary behaviour or a generic layer above the three requires
an accepted plan amendment naming the concrete current implementations it
unifies and why direct code is insufficient. Internal modules and test helpers
remain direct and outcome-specific. Raw line count is recorded at closure as a
review signal, never a pass threshold; required clarity, failure handling, and
evidence are not traded for compression.
<!-- loopex:plan-technical-envelope:end -->
