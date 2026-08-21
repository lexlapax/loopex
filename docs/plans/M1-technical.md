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
together. Acceptance authorizes only the eight outcomes and their three named
boundary behaviours. Any deferral, gate weakening, evidence waiver, fourth
product boundary behaviour, new persistence decision, or public compatibility
claim requires its ordinary explicit disposition; none is implicit here.

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

1. **A — Store and durable truth rejoins first.** The store behaviour, its
   in-memory and durable local implementations, the production transition
   catalogue, and ADR 0006 conformance are integrated before a runtime relies on
   them.
2. **B — Runtime and embedded API rejoins second.** Explicit supervision,
   session ownership, durable outbox delivery, and the direct embedded facade
   build on A. No model or tool dispatch is integrated before B proves that a
   superseded owner cannot make work eligible.
3. **C — Model and executor boundaries rejoins third.** Deterministic and ReqLLM
   model implementations and the trusted-local executor build on the owned
   session path. A direct configured executor is sufficient; no broker is
   introduced.
4. **D — Client and combined demonstration rejoins last.** The reference client
   and OS-process recovery trace exercise the integrated A, B, and C paths. A
   private client loop, substitute store, fake provider, or bypass executor is
   not a demonstration of the milestone.

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
the focused selectors exercise. Its first real model response requests the real
controlled tool; its second real model call occurs only after OS-process restart
and receipt reconciliation.

Every protected selector retains its exact locked test names, executes at least
the locked minimum, and reports no skipped, excluded, filtered, quarantined, or
pending case. The ordinary full suite remains credential-free. Only the
explicitly tagged provider selectors receive `LOOPEX_PROVIDER_API_KEY`; absence
is evidence unavailable and fails those selectors rather than skipping them.
Retained real-path evidence contains only non-secret provider/model/endpoint and
executor identity.

Durable fault coverage is structural rather than an enumerated test list. The
production durable state machine declares stable transition and fault-point IDs.
The test fault injector is derived from those declarations, and evidence asserts
set equality between declared IDs, injected IDs, and observed IDs. For every
durable transaction path, coverage includes at least:

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
schema's required set. A separate protected conformance assertion compares that
schema with the complete tuple required by the vision and development contract,
so deleting a field from production cannot shrink its own corpus and certify the
omission.

Required mutation evidence starts from a named clean candidate and identifies
the exact path and blob digest under test. Each mutation disables one mechanism,
runs the protected selector that must fail for the named reason, restores the
artifact from `git show <candidate>:<path>`, and verifies its SHA-256 and the
whole-tree cleanliness before another mutation runs. A failure observed from a
dirty or previously mutated baseline is no evidence. This applies at least to
the current-owner post-commit fence, store atomic comparison and unknown fence,
executor final validation, and no-blind-retry recovery rule.

The two locked toolchain pairs run the whole gate in both orders and each pair
also runs after itself. The five-run sequence covers the four required
adjacencies (`floor→floor`, `floor→current`, `current→floor`, and
`current→current`), and every run binds the exact candidate, gate digest,
command, toolchain, platform, counts, timing, and result. A retry does not
replace a flake. Build, dependency, temporary, and product-state roots are
isolated per lane; ordering evidence cannot share mutable compiled artifacts.

Outcome-specific obligations are:

| # | Obligation |
| --- | --- |
| 1 | Start two supervised runtimes in one VM with distinct configuration, store instances, and state roots; prove their data and failures do not cross; prove every public operation needs its explicit runtime reference and that neither a global registration nor application environment can supply one |
| 2 | Generate legal command and recovery histories around store-owned succession; prove a second current owner cannot be admitted and a second prompt is refused while a run is active rather than starting another run; exercise a superseded process at every post-store-result path and prove it cannot newly commit or use a delayed result to change the current cache, publish, dispatch, or authorize; assert complete derived transition-fault coverage |
| 3 | Run the reusable ADR 0006 live transaction-semantic layer unchanged against the in-memory test implementation and durable local store; against the durable implementation additionally cover retained known and unknown transaction resolution, durable non-commit outcomes, consecutive store-stamped versions, outbox identity, restart/replay, corruption visibility, and process/store faults; in both layers cover binding conflicts, all three call outcomes, compare order, atomic owner succession, and `commit_unknown` fencing, then mutate commit-time fencing and prove replay cannot replace it |
| 4 | Prove create/resume, command, and attachment use the explicit embedded runtime facade; atomically establish an attachment barrier at committed sequence N, return an authoritative snapshot anchored at N, then deliver buffered and live durable events after N contiguously with at-least-once deduplication by session, sequence, and event ID; prove dispatcher failure and restart preserve that identity and sequence, a slow subscriber has bounded isolation and cannot delay session commits or grow coordinator memory without bound, and progress or diagnostics cannot be read as durable truth or block a coordinator |
| 5 | Run one conformance suite against a deterministic model and ReqLLM adapter; prove the model receives only the exact canonical request bytes whose versioned digest and intent committed before dispatch; explicitly invoke a real provider and retain its non-secret identity; prove absent credentials and a zero-executed or skipped provider lane cannot pass |
| 6 | Prove only an explicit host-policy `allow` path issues a grant and that model output, Loopex internals, tool metadata, and ordinary client input cannot mint or widen one; assert the production required-binding schema equals ADR 0007's protected independent ten-binding oracle; derive validation and separate missing and present-but-wrong corpora from the production schema, require exact coverage equality and refusal reason per binding; independently canonicalize the immutable `JobRequest`, recompute and compare its digest, and require the retained receipt to echo the verified digest and complete origin tuple; prove no controlled OS process starts before final serialized validation succeeds, the workspace lease remains held for the full job, and lease loss cancels or kills owned work with retained evidence rather than success; then execute one real bounded local tool and retain its receipt |
| 7 | Drive start, create/resume, command, event consumption, terminal observation, and shutdown through the embedded API; replace or instrument that facade so the test fails if the client reaches coordinator, store, model, executor, journal, or outbox internals or owns a second state machine |
| 8 | In one retained trace, count dispatch identity outside both runtime incarnations; use a real provider response to request the real tool; kill the runtime BEAM OS process after the executor durably retains its receipt but before the session commits the receipt fact; start a fresh process, durably advance ownership, issue a current solicited reconciliation query, validate the complete retained receipt tuple, commit it once, publish from the outbox, make a second real model call, and reach a terminal result with one dispatch and no acknowledged-fact loss; derive and refuse an otherwise-valid response with each current-query or retained-origin identity wrong and prove complete schema coverage; separately prove insufficient effect evidence commits immutable `outcome_unknown` and causes no blind retry |

The kill in outcome 8 is an operating-system process kill, not an Erlang-process
restart and not distribution. Durable store bytes, retained executor evidence,
and an external dispatch counter survive the runtime process so the new process
cannot satisfy its assertions from old memory. The harness chooses the fault
point from the production catalogue; a special alternate session loop is
forbidden.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M1.md#concept-plan-scope).

No public contract, protocol, storage format, or package is frozen. The embedded
API is the reference semantic surface for this milestone's one attached caller,
not a released surface. The store, model, and executor behaviours carry reusable
conformance suites so later implementations can be evaluated, but those shapes
remain unreleased until a future accepted milestone supplies schemas, vectors,
independent consumers, migrations, and upgrade/rollback evidence.

Durable M1 sessions must resume across the process kill and the same-candidate
restart exercised here. That is a recovery guarantee, not an installed-version
upgrade or downgrade promise.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M1.md#concept-plan-scope).

There is no installed base and no released artifact. M0 journals and retained
evidence are not migrated; M1 tests and demonstrations create isolated M1 data
roots. No PostgreSQL, SQLite, or other external store migration is claimed.

Before M1 first becomes green, every checkpoint keeps the bootstrap and closed
M0 gate green on both locked pairs while the M1 runner reaches its next truthful
missing-behavior red. The accepted opening checkpoint remains the complete
repository rollback target: reverting unintegrated M1 work to it restores the
accepted red condition without rewriting durable user data. After a complete M1
candidate first becomes green, each later checkpoint must keep both M0 and M1
green or be reverted to the last reviewed green checkpoint.

The branch does not merge while M1 is red. No rollback claim extends to a data
root written by a different source revision, because this milestone accepts no
installed-store compatibility contract.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M1.md#concept-plan-scope).

No package is published, installed, or versioned for distribution. ADR 0001's
umbrella direction and ADR 0002's runtime floor remain unchanged. Core uses only
Elixir/Erlang standard-library and OTP facilities. ReqLLM remains confined to
its model-adapter application, and neither its types nor its dependency crosses
into core.

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
work before acceptance is limited to correcting and composing existing portable
enforcement so it can measure the accepted obligations honestly; it creates no
product mechanism.

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
