<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](M2.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M2.md#concept-plan-scope).

Concept: [Milestone non-goals](M2.md#concept-plan-non-goals).

These accepted decisions are consumed unchanged and are not reopened:

- **ADR 0001** fixes the repository and application dependency direction.
  Adapter and client applications depend inward on `:loopex`; a client
  application is created only by an accepted plan naming its responsibility.
- **ADR 0002** fixes the OTP 26+/Elixir 1.17+ floor and the two exact validation
  pairs. Core cannot use a language or standard-library feature absent at the
  floor, so `:json` (OTP 27) and `JSON` (Elixir 1.18) are unavailable to every
  application this milestone touches.
- **ADR 0003** fixes the protocol-only contributor boundary. M2 recognises that
  role and creates no extension.
- **ADR 0006** fixes the store transaction contract, commit-time owner-epoch and
  incarnation fencing, transaction resolution, and durable record requirements.
  Every new durable fact this milestone commits — a conversation turn, a tool
  definition generation, a cancellation, a denial — enters through one
  catalogued production transition.
- **ADR 0007** fixes the trusted-local executor grant, job, receipt, final
  pre-start validation, and independent binding oracle. The four coding tools
  are ordinary jobs under that contract; none of them widens it.
- **ADR 0008** fixes owner-succession recovery and runtime placement. Its
  constraints are load-bearing for Outcomes 6 and 7 and are restated as
  ownership invariants below.

Two decisions must carry recorded acceptance before this plan pair and gate are
accepted and before any implementation begins:

- **ADR 0009 — Tool, executor, and grant contracts.** The loop cannot dispatch
  an effect before the tool definition, job, receipt, and grant shape exist.
  Outcomes 2, 3, 4, and 9 depend on it.
- **ADR 0010 — Provider continuation and exact context staging.** A model call
  dispatches only the exact canonical context committed with its intent, and a
  continuation binding is what makes turn two a continuation rather than a new
  conversation. Outcomes 1, 5, and 9 depend on it.

Deferred decisions and their named acceptance points:

| Deferred decision | Acceptance point |
| --- | --- |
| Context pipeline contracts — registered providers, transformers, selectors, and observers | Before the first registered context provider or extension-contributed transformer exists. M2 implements only the initial local-kernel stage ADR 0010 fixes: canonical history, a fixed reference project-resource stage, trust admission, total budget enforcement, and exact receipts |
| The reference default active-tool profile | After M2's measured prompt cost and task utility. M2 ships `read`, `write`, `edit`, `bash` and measures; it does not fix a reference default |
| Interactive `defer` approval and the interaction round trip | Before the first surface that can ask an operator a mid-run question. `allow` and `deny` are complete in M2 |
| Store selection and migrations | Durable service rung, as the roadmap records |
| Name, trademark, domain, and Hex clearance | Before public packaging, which this milestone does not do |
| JSONL RPC, a reference daemon, and multi-client attachment | The rung after durable local truth, per the vision's serial barriers |

Three decisions are disposed by accepting this plan pair itself, in the way ADR
0008 was disposed by accepting an existing plan's requirement for it. None is
implicit; each is named so acceptance is a decision rather than a side effect.

**One. A seventh application and a widened client rule.** `apps/loopex_cli` is
added with role `:client`. A `:client` application may declare a production
dependency on `:loopex`, optionally on `:loopex_protocol`, and production
dependencies on the in-umbrella `:edge` applications it composes. It may declare
no external dependency and no dependency on another `:client`. The widening is
required rather than convenient: a shipped composition must name concrete Store,
Model, and Executor implementations to build an `escript`, core may depend only
on the protocol, and an edge may not import a concrete sibling, so the
composition can live only in a client application. Dependency direction is
unchanged — every edge remains inward — and the composition's reach is bounded
by the exact-inspection rule in Ownership below.

**Two. `0.1.0` with labelled surfaces and no publication.** The root `VERSION`
moves from `0.0.0` to `0.1.0`, so every application in the single version train
reports `0.1.0`. Every public surface is labelled `experimental`. No package,
archive, or release artifact is produced or published.

**Three. The closed M1 gate is carried forward behaviourally, not by byte
identity.** The closed M0 gate remains an inherited required gate and is
re-proved on both locked pairs at every M2 source candidate; nothing in M2
touches a byte M0 binds. The closed M1 gate cannot be inherited the same way,
and pretending otherwise would make this milestone unsatisfiable rather than
protected:

- M1's Bound Artifacts bind `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` by
  SHA-256, and that file's planned-inventory constant freezes the repository at
  exactly six applications with the reference client as the only `:client`. A
  seventh application fails it, and so does the widened client rule.
- M1's retained matrix binds `adapter_build=loopex_llm_reqllm@0.0.0` and
  `executor_build=loopex_executor_local@0.0.0`. Version `0.1.0` changes both.

No M2 that delivers its Purpose can leave those bytes unchanged, and M1's gate
is immutable, so re-running it would be an unsatisfiable obligation rather than
a protection. M1 is `Closed`: its outcomes are proved history, not a live
commitment. M2 therefore carries M1's protection forward behaviourally. The M2
gate re-runs all eight M1 protected outcome selectors through the same bound
`scripts/m1-exunit-runner.exs`, at their exact locked test identities, states,
and minima, as an inherited table beside M2's own, and re-runs M1's locked
selector-runner mechanics corpus unchanged. If implementation shows that an M1
locked identity cannot survive an accepted M2 outcome, that is a blocking
finding requiring an explicit maintainer disposition, never a silent rename or a
quietly dropped row.

Accepting this plan pair authorizes only the nine outcomes and the three named
boundary behaviours. Any further deferral, gate weakening, evidence waiver,
fourth product boundary behaviour, new persistence decision, external
dependency, publication, or public compatibility claim requires its ordinary
explicit disposition.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M2.md#concept-plan-scope).

One integrator owns rejoin, conflicts, the candidate SHA, and post-rejoin
verification. The maintainer owns plan and gate acceptance, scope deferral, gate
weakening, evidence waiver, blocking-finding disposition, closure, the `0.1.0`
tag, and every decision class the development contract reserves.

**Session truth stays where M1 put it.** The session coordinator remains the
sole serial writer of its session's durable truth. The tool registry is
runtime-scoped read-mostly data reached through the explicit runtime reference;
it registers no global name and stores no session state. The model adapter and
executor return evidence; neither mutates session truth nor publishes a durable
fact. Conversation history is a projection of committed durable records, never a
second store: a turn is not part of the conversation until its record commits.

**The command surface owns nothing durable.** `loopex_cli` calls only the public
`Loopex` facade for every session operation. Exactly one module in that
application — the shipped composition — may name concrete Store, Model, and
Executor implementations, and it may do so only to build the runtime options
passed to `Loopex.start_link/1`. No other module in the application may
reference a coordinator, journal, outbox, store, adapter, or executor module,
hold a cursor as truth, or make an authority decision. The gate proves this by
source inspection, exactly as M1 proved it for the reference client.

**ADR 0008 placement is an invariant of the operator experience, not a detail.**
The command surface must obey all four consequences:

1. A session is permanently bound to the `runtime_id` that created it. Resume
   through a different `runtime_id` is refused, and the refusal is reported to
   the operator in words that say what to do.
2. `runtime_id` is durable placement identity that must be re-presented after
   restart. A command that generates a fresh random `runtime_id` per invocation
   strands every session it created. The command surface therefore persists its
   placement identity in the resolved state root and re-presents it.
3. Once a create or resume command completes, re-presenting the same
   `command_id` returns the historical result without advancing the owner epoch.
   Acquiring a live replacement owner requires a fresh unique `command_id`; a
   deterministic `resume-<session_id>` would return a stale result and never
   acquire ownership.
4. Loopex provides no VM-global lock, so the host owns mutual exclusion of
   Runtime Controls on one `(Store identity, runtime_id)` placement key. The
   command surface owns that exclusion for its own state root and fails closed
   with an explicit message when it cannot acquire it, rather than starting a
   second Control.

Rejoin barriers are serial and exact:

1. **A — Tool contract and registry rejoins first.** The tool definition shape
   in `loopex_protocol` and the runtime-scoped registry in core are integrated
   before any caller names a tool.
2. **B — Loop, committed history, and continuation rejoins second.** The turn
   machine, canonical history projection, per-turn exact staging, and the
   continuation binding build on A. No tool implementation is integrated before
   B proves a turn dispatches only its committed bytes.
3. **C — Coding tools and host policy rejoins third.** `loopex_executor_local`
   implements the four tools against A's contract, gains the `deny` path, and
   gains owned-process termination. It imports no concrete sibling adapter.
4. **D — Cancellation and the session directory rejoins fourth.** Cancellation
   needs C's termination evidence and B's turn machine. The session directory
   needs the resolved state root and ADR 0008 placement identity.
5. **E — Operator surface and demonstration rejoins last.** `loopex_cli` builds
   only on the integrated A–D paths through the public facade. A private client
   loop, substitute store, fake provider, or bypass executor is not a
   demonstration of this milestone.

Core is a serial ownership chain across A, B, and D rather than parallel
writers, because those workstreams touch the same coordinator and session-state
modules. Parallel writing is confined to the pairs that own disjoint
applications. Every parallel writer uses non-overlapping file ownership,
separate branches or checkpoints, separate worktrees, and isolated build,
dependency, and state roots. No workstream creates an alternate durability
truth, authority path, or session loop to avoid a barrier.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M2.md#concept-plan-outcomes).

The outcome selectors are necessary but not separable substitutes for the
Purpose. Closure requires one retained attended demonstration in which a real
provider drives the shipped `loopex` command through a genuine multi-tool coding
task in a real Git repository, using the same product runtime, store, model,
executor, tool registry, executor tools, embedded API, and command code the
focused selectors exercise. Deterministic tests are supporting coverage and
cannot stand in for it.

Every protected selector runs through the bound `scripts/m1-exunit-runner.exs`,
invoked directly with `elixir` outside every product application, exactly as M1
proved. The script starts and configures ExUnit itself, dispatches no Mix task
or alias, and loads no `test_helper.exs`. It receives the exact invocation role,
selector path, seed, minimum, exclusion policy, and expected test identity and
state. Official ExUnit results, rather than test-owned stdout, must show every
locked name in the required state, the locked minimum, and no unaccounted skip,
exclusion, filter, quarantine, pending case, setup failure, or test failure. M2
reuses that channel rather than building a second one, and reuses its
`LOOPEX_M1_SELECTOR_V1` nonce frame as the only path a provider credential takes
into a selector VM.

The ordinary full suite and every credential-free control remain
credential-free. The gate runner refuses `LOOPEX_PROVIDER_API_KEY` in its
initial environment and accepts an optional credential only through a bounded
`LOOPEX_M2_PROVIDER_V1` stdin frame, held in one unexported holder and forwarded
only to the explicitly tagged real-provider role. Absence is evidence
unavailable and fails that role rather than skipping it. Gate-owned output is
compared against the literal key before emission. This is containment at the
runner boundary; M2 does not rebuild M1's sealed-environment apparatus and makes
no claim to defend against a hostile already-running shell.

Outcome-specific obligations are:

| # | Obligation |
| --- | --- |
| 1 | Generate legal multi-turn histories and prove the run continues while the model requests tools and ends when it does not, with a declared bounded turn ceiling that ends the run truthfully rather than stopping silently; prove every request after the first contains the original prompt, the model's own prior assistant message including its tool call, and the real tool result rather than a synthesized string; prove the canonical request bytes and digest committed before each dispatch are exactly the bytes the adapter receives; prove a provider continuation binding is carried, and that an incompatible model or provider change invalidates it rather than reusing it; assert complete derived fault coverage over every new durable transition |
| 2 | Resolve a tool by ID and version through a runtime-scoped registry; refuse an unknown ID and refuse a conflicting registration with an explicit reason; prove two runtimes in one VM carry independent registries and that no global registration, application-environment value, or persistent term supplies one; prove each model request records the exact definition generation used, and that an in-flight operation's semantics cannot change because the registry changed |
| 3 | Run one shared conformance suite over `read`, `write`, `edit`, and `bash`, covering bounded and truncation-reporting output, workspace-root resolution, refusal of every path that escapes the root through traversal, a symlink, or a link chain, exact edit preconditions with a mismatch diagnostic that names what differed, explicit shell-versus-argv semantics, ownership and termination of the whole child process tree, and artifact spill when output exceeds its declared bound; each tool executes as a real controlled OS process under ADR 0007 with a credential-free environment |
| 4 | Prove a host-policy `deny` decision issues no grant, that no operating-system process starts, and that the refusal is a committed durable fact the operator can read; prove the run continues or terminates truthfully after a denial and never retries the refused call; prove model output, tool metadata, IDs, and ordinary client input cannot mint or widen a grant; prove the trusted-local `AllowAll` implementation is explicit configuration documented as a developer default rather than an implicit fallback that would hide a missing decision |
| 5 | Prove cancellation is the acknowledged protocol: the request is durably recorded, scheduling stops, the in-flight model call and executor job receive a cooperative cancel, a bounded grace period elapses, the owned process tree is terminated, and `cancelled` commits only after cleanup is confirmed; prove a validated terminal tool fact that committed before the abort is preserved and is not overwritten by `cancelled`; prove insufficient effect evidence commits immutable `outcome_unknown` with no blind retry; prove an aborted model response never becomes a canonical assistant message; prove the operator observes both what was cancelled and what actually happened |
| 6 | List sessions from a state root resolved from `LOOPEX_HOME` in a fresh operating-system process with no inherited runtime; prove the state root is never read from application environment; prove a session resumes under its creating `runtime_id`, that a different `runtime_id` is refused with an explicit reason, that a repeated resume command identity returns its historical result without advancing the owner epoch, and that a fresh identity acquires live ownership; prove the placement identity survives restart because it is persisted and re-presented rather than regenerated |
| 7 | Drive `run`, `sessions`, `resume`, and `cancel` end to end through the embedded API; replace or instrument that facade so the test fails if any module outside the single shipped composition reaches a coordinator, store, model, executor, journal, outbox, or cursor internal or owns a second state machine; measure the base system prompt plus active tool definitions with the documented deterministic estimator and require the result under one thousand tokens before project context; prove argument parsing and terminal output use only the standard library and that the application declares no external dependency; prove no wire or line-framing contract is introduced |
| 8 | Start a runtime, create a session, submit a prompt, and consume events using only the shipped composition module; measure that module and require at most sixty effective lines, counting neither blank lines nor comments; prove the `loopex` command uses that same composition rather than a second one; prove the composition resolves its state root explicitly and reads none from application environment |
| 9 | In one attended real-provider run of the shipped command against a disposable Git repository created inside the gate's own task root, complete a task that requires at least three turns and at least three distinct tools including one `edit` and one `bash`; count turns, tool calls, and effects outside the runtime; include one host-policy refusal and prove the transcript reports it and the task continues truthfully; prove the resulting file bytes on disk; retain non-secret provider, model, endpoint, executor, tool, and prompt-measurement identity from the successful role, and prove that a zero-executed, skipped, or credential-free run cannot pass this role |

Durable fault coverage stays structural, as M1 established. Every new logical
operation that can change durable session truth enters through one production
transaction dispatch, every executable transition phase carries a stable
`fault_point_id`, and evidence asserts set equality between the complete
declared, injected, and observed `{transition_id, fault_point_id}` key sets. A
new production transition without a derived injected and observed case fails
that equality assertion rather than silently escaping the catalogue.

Required mutation evidence is five ordered, independently restored records in
`docs/evidence/M2-negative-demonstrations.md`. Each starts from its own named
clean candidate, identifies the exact path and candidate blob digest, disables
only that mechanism, runs the named protected selector that must fail for the
named reason, restores the artifact from `git show <candidate>:<path>`, and
verifies the restored SHA-256 and whole-tree cleanliness before the next record:

1. Outcome 1 / `committed_history_projection` /
   `apps/loopex/test/agent_loop_test.exs`
2. Outcome 2 / `tool_definition_generation_binding` /
   `apps/loopex/test/tool_registry_test.exs`
3. Outcome 3 / `workspace_path_scope_containment` /
   `apps/loopex_executor_local/test/coding_tools_test.exs`
4. Outcome 4 / `host_policy_deny_prestart_refusal` /
   `apps/loopex_executor_local/test/host_policy_test.exs`
5. Outcome 5 / `cancellation_cleanup_confirmation` /
   `apps/loopex/test/cancellation_test.exs`

No record stands in for two mechanisms, and a failure observed from a dirty or
previously mutated baseline is no evidence.

Execution evidence has three non-self-referential full M2 captures — Darwin at
the exact floor pair, Darwin at the exact current pair, and Linux at the exact
current pair — plus one exact-candidate re-proof of the immutable M0 gate on
each locked pair. Each capture starts from the same clean committed source
candidate `C`, runs the complete captured M2 command set except validation of
the record it is about to create, and emits one authoritative non-gate `CAPTURE`
record only after those commands pass. A capture never calls the ordinary gate
recursively, emits GREEN, or supplies merge evidence. Every capture and M0
re-proof uses fresh, disjoint build, dependency, temporary, `LOOPEX_HOME`,
workspace, and product-state roots; physical order and adjacency are inert.

The three captures and the attended demonstration record are committed in
evidence commit `E`, the direct one-parent child of `C`. `C→E` may change
exactly `docs/evidence/M2-toolchain-matrix.md`,
`docs/evidence/M2-negative-demonstrations.md`, and
`docs/evidence/M2-coding-demonstration.md`; every other tree byte is identical.
The ordinary gate runs at `E` on all three lanes and alone may emit final GREEN.
Closure transition `T` is the unique commit that first completes M2's canonical
Closure record and is the direct one-parent child of `E`.

Mechanical and judgment authority stay separate:

| Authority | Owns |
| --- | --- |
| `bash scripts/check-m2-gate.sh` | Bound artifact digests, protected and inherited selector identities, states and minima, locked command exit status, evidence record structure and candidate reachability, the credential boundary, and user-state containment |
| `mix loopex.status` | Live consistency among M2's governance rows, register state, root README status capsule, indexes, links, and the current revision's lifecycle claims |
| Independent review | Whether tests assert what their names promise, whether mutations and cancellations were honestly injected, whether retained fields match actual captured output, whether the attended demonstration was a genuine task rather than a scripted one, whether the closure documents are current, and whether the operator experience satisfies the Purpose |

One canonical decimal gate seed from `0` through `999999` is supplied to every
M2 protected selector role, every inherited M1 selector role, the provider
default-exclusion control, and the ordinary final full suite in that gate run.
`protected_executed` is the sum of authoritative executed test counts assigned
to the nine M2 Outcomes across their locked selector roles; a test reported
excluded never counts, and inherited, mechanics, bootstrap, and full-suite
executions are excluded from that sum.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M2.md#concept-plan-scope).

No public contract, protocol, storage format, or package is frozen. `0.1.0` is a
version number on a source tree, and the vision's seventh compatibility surface
— released package names, their contents, and the constraints they declare —
stays inert because nothing is published.

Under the 0.x policy every public surface carries a label. M2 labels five, all
`experimental`: the embedded Elixir API, the `loopex` command surface, the
private journal and store schema, the executor job and receipt protocol, and the
tool contract. An experimental surface may break in a later minor release with
explicit migration notes. Internal process topology, process messages, and
private structs are not public API and carry no label. No surface becomes a
release candidate here, because none of them has schemas, independent consumers,
vectors, or migration evidence.

The private journal and store schema changes in this milestone: conversation
turns, tool definition generations, denials, and cancellations are new durable
records. A session data root written by an M1-era revision is therefore not
readable by M2. That is stated plainly in the operator documentation rather than
worked around, because M1 accepted no installed-store compatibility contract and
M2 accepts none either.

Milestone execution remains portable across the three locked lanes: Darwin
floor, Darwin current, and Linux current. Each lane runs the same source, gate
runner, protected selectors, inherited selectors, credential-free suite,
real-provider role, coding tools, and demonstration. The floor lane is the
binding constraint on implementation technique, not a reduced smoke test: with
neither `:json` nor `JSON` available there, any JSON encoding or decoding this
milestone needs is repository-owned code proved on that lane. The Linux lane
demonstrates runnability at the current pair without asserting a floor-on-Linux
result or a permanent public support matrix.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M2.md#concept-plan-scope).

There is no installed base and no released artifact. M0 and M1 journals and
retained evidence are not migrated; M2 tests, demonstrations, and gate runs
create isolated M2 data roots. No PostgreSQL, SQLite, or other external store
migration is claimed.

Before M2 first becomes green, every product checkpoint offered for review keeps
the bootstrap aggregate and both exact M0 lanes green while the M2 runner
reaches its next truthful missing-feature red. The accepted opening checkpoint
is the complete repository rollback target for unintegrated M2 product work:
reverting the designated milestone branch to it restores the accepted red
condition without rewriting durable user data. After a complete M2 candidate
first becomes green, each later checkpoint must keep M2 and both M0 lanes green
or be reverted to the last reviewed green checkpoint. Ordinary local red-green
work between checkpoints is not an integration candidate.

The accepted governance checkpoint is the one integration exception before M2
closure. After its exact transition is independently reviewed and the maintainer
separately approves the protected-branch merge, the accepted plan and gate
machinery, governance, derived status and documentation, and portable
enforcement may integrate to `main` while the exact accepted opening gate
remains red. That surface contains no M2 product implementation bytes; `main`'s
product baseline therefore remains M1. The designated M2 branch stays live
because it owns the unintegrated product work through closure.

An accepted-plan amendment is not a source candidate `C`. It uses the generic
direct one-parent proposal and rebind transaction declared by the
`amendment-transaction-v1` marker in the gate. Proposal `A` is the first
revision to advance the generation and retains the prior Acceptance row and
lifecycle state, so binding validation, bootstrap, and any inherited gate that
invokes them must fail there only for the stale binding, while
binding-independent checks and the M2 runner's truthful product state are proved
directly at `A`. Its immediate child `R` rebinds Acceptance to exact `A`, adds
one new amendment-specific disposition anchor to an existing durable document,
and changes no envelope, gate, portable-enforcement, or product byte. Only `R`
is integration-eligible, and evidence always names the revision where it ran.

The `v0.1.0` tag is applied by the maintainer at closure and only at closure. It
is a name for a reviewed commit, not release authority, and it publishes
nothing. Rolling it back means deleting a tag; no external consumer depends on
it, because none exists.

No M2 product implementation merges while M2 is red or before closure. No
rollback claim extends to a data root written by a different source revision.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M2.md#concept-plan-scope).

No package is published or installed. ADR 0001's umbrella direction and ADR
0002's runtime floor are unchanged.

The planned inventory becomes exactly seven applications with exact roles:
`loopex_protocol` as `:contract`, `loopex` as `:core`, `loopex_store_local`,
`loopex_llm_reqllm`, and `loopex_executor_local` as `:edge`, and
`loopex_reference_client` and `loopex_cli` as `:client`. The role rules are:

- `:contract` declares no dependency of any kind, in any environment;
- `:core` declares exactly one production dependency, `:loopex_protocol`, and no
  external, edge, or client dependency in any environment;
- `:edge` declares a production dependency on `:loopex`, may also depend on
  `:loopex_protocol`, and imports no concrete sibling adapter;
- `:client` declares a production dependency on `:loopex`, may also depend on
  `:loopex_protocol`, may declare production dependencies on the `:edge`
  applications it composes, may declare no external dependency, and may not
  depend on another `:client`.

This changes the repository's own dependency check. `mix loopex.deps_budget` and
its bound source, `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, are product
code this milestone edits: the planned inventory grows from six named
applications to seven and the client rule widens as above. The M2 gate states
that plainly rather than claiming M2 adds or changes no check, and the M2 gate
does not bind that file's bytes, because binding bytes the milestone must change
would lock a digest that acceptance already knows is wrong. The command itself
stays locked, its adversarial corpus in `apps/loopex/test/deps_budget_test.exs`
grows two cases for the new inventory and the new client rule, and the M0 gate —
which locks the command but not its bytes — must still pass.

`loopex_llm_reqllm` remains the only application permitted a direct external
dependency, exactly `{:req_llm, "~> 1.17.1"}` without source options. Core
remains Elixir/Erlang standard-library and OTP only. `loopex_cli` declares
production dependencies on `:loopex`, `:loopex_store_local`,
`:loopex_llm_reqllm`, and `:loopex_executor_local`, and no external dependency
in any environment; its argument parsing and terminal output are standard
library only.

The operator entrypoint is an `escript`. `apps/loopex_cli/mix.exs` declares an
`escript` main module, `mix escript.build` produces an executable named `loopex`
in that application, and `loopex --version` reports `0.1.0`. The escript must
build and run on all three locked lanes. It is not installed, signed, archived,
attached to a release, or published, and the gate produces it inside its own
owned task root.

The root `VERSION` file moves from `0.0.0` to `0.1.0`. Every application reads
that file at compile time, so there is one edit and one source;
`mix loopex.version_train` continues to prove the single train and now proves
`0.1.0`.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M2.md#concept-plan-scope).

The operator experience is the unit of value. Focused tests, retained evidence,
and repository checks support it and cannot satisfy an outcome in its place.

**No fourth product boundary behaviour.** Store, Model, and Executor remain the
only three, exactly as M1 accepted them. The tool registry is runtime-scoped
data plus resolution rules inside core; it defines no replaceable
implementation, has no conformance suite of its own, and adds no behaviour
module. Host policy stays the small explicit decision function ADR 0007 already
requires. A fourth boundary behaviour, or a generic layer above the three,
requires an accepted plan amendment naming the concrete current implementations
it unifies and why direct code is insufficient.

**The registry unifies six concrete tool implementations, all of which exist in
this repository when it ships:** `read`, `write`, `edit`, and `bash`, plus the
two retained demonstration tools `loopex.demo.write` and
`loopex.demo.wait_write`. The demonstration tools remain registered rather than
deleted, because M1's inherited protected executor and recovery selectors
exercise them and the registry must prove it resolves more than one generation
of definition. Six implementations behind one resolution rule is why the
registry is not a speculative layer; four of them are new in this milestone.

**The command surface is a client application, not a boundary.** It defines no
behaviour, no callback, and no replaceable implementation. It is permitted
exactly one composition module that names concrete adapters, and that module has
a hard ceiling: at most sixty effective lines, counting neither blank lines nor
comments, measured by a protected test. That ceiling is the executable form of
the vision's requirement that one page of code can start a runtime, create a
session, submit a prompt, and consume events — a budget the repository currently
fails, because the only such composition is test support.

**The reference prompt has a measured ceiling.** The base system prompt plus
active built-in tool definitions must measure under one thousand tokens before
project context. The measurement is deterministic and dependency-free: a
documented conservative estimator over the exact UTF-8 bytes, asserted by a
protected credential-free test, and the attended real-provider role additionally
records the provider's own reported input-token count for the same prompt. Both
must be under the ceiling. A measurement that needs a tokenizer dependency is
out of budget.

**Explicitly forbidden in this milestone,** whether or not something would find
them convenient: a transport behaviour, a daemon, a socket, a wire protocol or
line framing, a controller lease, a broker, a policy engine, a generic event
bus, a plugin macro system, a context-provider or transformer registry, an
alternate session engine, a second composition module, and any built-in
sub-agent, plan, objective, background job, team workflow, or social channel.
The last group is a standing vision constraint, not an M2 preference.

**Gate machinery is limited to two files:** the new `scripts/check-m2-gate.sh`
and the reused, already-proved `scripts/m1-exunit-runner.exs`. M2 adds no
evidence verifier, no environment launcher, and no generalized evidence
framework. Where M2 needs a check M1 already proved, it invokes M1's machinery
instead of writing a second one.

Raw line count is recorded at closure as a review signal, never a pass
threshold, except for the two scope-specific ceilings above, which the gate
locks. Required clarity, failure handling, and evidence are not traded for
compression.
<!-- loopex:plan-technical-envelope:end -->
