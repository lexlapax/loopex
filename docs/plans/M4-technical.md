<a id="technical-depth"></a>
## Technical depth

Concept: [Headless external consumption](M4.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M4.md#concept-plan-scope).

Concept: [non-goals](M4.md#concept-plan-non-goals).

M4 opened as the one permitted planning lookahead after M3's accepted
governance checkpoint integrated to `main`. Its opening base was
`4bba8b74f5e260dc2a364fcbd3554c7badd1a09c`, retained as an ancestor without
rebasing or squashing bound history. M3 subsequently Closed on `main` at
`72c0a30`, and the M4 branch absorbed that Closed product base in `e1b37b1`.
The M0–M2 Closed aggregate was proved green once at the opening candidate.
Before the M3 refresh, under the reviewed
[planning-revision aggregate override](../developer/agent-context-map.md#override-disposition-m4-planning-aggregate-2026-09-11)
and its reviewed
[widened scope](../developer/agent-context-map.md#override-disposition-m4-planning-aggregate-scope-2026-09-11),
later planning revisions of the Open lineage relied on that result: plan and gate
documents, manifests, runner and support work, prerequisite ADR proposals,
documentation, and repository-status enforcement with its tests, provided the
revision added no milestone product implementation and bootstrap passed at the
revision. That override does not cover the M3 refresh, acceptance, rejoins,
rebind children or closure candidates; those keep the ordinary inherited-gate
obligation. M4 remains Open and holds no implementation authority. Before it
can be accepted, re-prove every inherited gate green and its own distinct red on
the refreshed base, bind the complete schema/vector contract bytes and prove
their fixture shape and digest integrity on the refreshed floor and current
toolchains with the bound standard-library Elixir check and mutation tests
named in the gate, then obtain fresh exact-SHA review. This
pre-acceptance check does not claim that a client or server conforms to those
fixtures.
Behavioral client conformance test bodies arrive during implementation and
must pass before closure. At final
acceptance all inherited gates are green and the M4 boundary remains
truthfully red for missing external behavior.

M4 accepts five decisions before dependent work:

| Decision | Owner and acceptance point | Effect |
| --- | --- | --- |
| [**ADR 0023**](../adr/0023-experimental-public-session-protocol.md#concept) | Maintainer, before M4 acceptance; must carry the connection state table below | Transport-neutral experimental protocol, exact initialization, identity ownership and fail-closed boundary |
| [**ADR 0024**](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | Maintainer, before M4 acceptance; must fix the exact maximum of successive answer → defer rounds per tool decision | Durable policy `defer`/answer lifecycle owned by the session with host-policy authority preserved |
| [**ADR 0026**](../adr/0026-development-floor-refresh.md#concept) | Maintainer, before M4 acceptance; holder transactions below settle after M3 closes | Explicit floor/current validation pairs replacing the derived pin rule |
| [**ADR 0028**](../adr/0028-bounded-artifact-retrieval.md#concept) | Maintainer, before M4 acceptance; carries the transfer design below | Bounded artifact transfer through the facade and ArtifactStore with distinct object/chunk digests |
| [**ADR 0030**](../adr/0030-observability-tracing-and-telemetry.md#concept) | Maintainer, before M4 acceptance; the core dependency is admitted by the recorded [vision change](../developer/agent-context-map.md#disposition-m4-vision-core-telemetry-2026-09-13), supersedes only the two ADR 0001 empty-dependency clauses for `apps/loopex`, and lands through the M1 dependency-oracle transaction in phase B | Runtime-owned isolated OTP trace sessions with identity-only default capture and exact limits; `:telemetry` spans at every port callback and transaction cut in a bound arity-exact inventory; the `loopex_telemetry` edge owning the only Loopex-attached handler; dispatcher-owned bounded diagnostics admission with counted drops |

**Artifact transfer design (decided).** The earlier draft admitted
1–16,384-byte ranges while the local store admits 64 MiB objects and verified
the complete object on every range, so saving a maximal object would have
verified it 4,096 times. On 2026-09-10, during the M4 planning task, the
maintainer chose one authorized, verified transfer that verifies once and emits
bounded chunks from an owned, cancellable reader, over independent range reads
that would have reduced the feature to bounded excerpts. Accepted ADR 0028 carries
that design. The accepted M4 ceiling is a 64 MiB transferable object; each
opening is limited to 60 seconds and 128 MiB of source-read plus snapshot-write
work; reads emit at most 32 KiB raw bytes within five seconds; transfers expire
after ten minutes; concurrency is two per connection and four per runtime;
and a connection admits 1 GiB of cumulative source-read, snapshot-write and
emitted-read work with at least a 1 MiB debit per open. Read amplification is
at most one complete verification plus one sequential emit per authorized
transfer. ADR 0028 is accepted with these values; they remain unmeasured
safety ceilings until the required evidence proves them.

**Connection state table (required content of ADR 0023).**

| Situation | Required behavior |
| --- | --- |
| Before `initialize` | Every other frame refuses; nothing durable is created |
| First `initialize` with no common generation | Refuse and remain uninitialized; no second negotiation attempt in that process |
| Repeated `initialize` after success or refusal | Refuse without changing state; a successful connection remains initialized on its selected generation, and a refused one remains uninitialized |
| Attachment | At most one active attachment per foreground process; a second `session.attach` refuses with a stable reason unless it names explicit replacement, which detaches the first at its last completely emitted cursor |
| Request identity | `request_id` is unique among in-flight requests on the connection; reuse while in flight refuses; reuse after completion is ordinary correlation |
| Pre-admission pressure | Refuse the mutation before any durable write |
| Post-admission pressure | Drop or coalesce progress first; if durable output still cannot drain, detach at the last completely emitted cursor and say so |
| Clean stdin EOF | Connection closed by the host: inherited orderly foreground shutdown, no new dispatch, open transfers closed, no cancellation record, no interaction state change |
| Abrupt process death | Host loss: nothing is recorded by the dying process; the journal alone states what settled and the inherited recovery contract resolves unresolved outcomes |
| Deliberate cancellation | Only the durable `session.abort` command; never inferred from EOF or death |
| Restart | A fresh process attaches with snapshot and cursor first; pending interactions remain pending; cancelled, expired or denied ones never reappear |

**Immutable launch inputs.** State root, workspace identity, resource snapshot,
policy module plus identity and revision, provider, executor and ArtifactStore
are fixed at launch. A decisive witness proves that no request, parameter,
model output, project resource or answer replaces any of them.

The accepted M3 decisions on resource packs and permit retirement and M3's
working resource/launch/repair interfaces are inherited. Reconcile the schema
with those interfaces and the new core contracts; no TODO member or unproved
method earns an advertised capability.

**Holder transactions.** The floor refresh (accepted Elixir 1.18.5/OTP 27.3.4
and current 1.20.3/OTP 29.0.5, with real matrix evidence), the ninth and
tenth applications, the dependency-rule changes (client → contract edge and
`:telemetry` in core) and source VERSION 0.1.0 each change bytes that Closed
gates bind. The default sequence is exact:

| Phase | When | Transactions and routes |
| --- | --- | --- |
| A. Successor enabling | M3 is Closed and integrated; before M4 acceptance | Derive the exact M0–M3 holder inventory on the integrated closure; settle the floor refresh and active floor literals: Closed M0–M3 each through v2 `A`/`R` in register order, with M1's bound verifier, dependency-budget task and tests and M2's bound runner changed in their own proposals; refresh Open M4's table directly; use holder-scoped artifact validation with named pending holders at intermediate `R` revisions, then re-prove global bootstrap and every inherited gate green plus this gate's own red after the final binding; submit that candidate for independent review and maintainer acceptance |
| B. Implementation | After acceptance, on branch `m4`, before the first rejoin that runs the full lanes | One Closed-M1 v2 proposal `A` that atomically carries M1's next gate generation, both dependency-oracle artifacts with the ten-application inventory, the client → contract edge, `:telemetry` admitted as core's sole external dependency, negative tests, and the minimal M4-authorized `loopex_app_server` and `loopex_telemetry` applications that make the new inventory true, following the M1 Amendment 7 pattern; exact-SHA review and explicit acceptance of `A`; immediate governance-only `R`; then ordinary implementation continues |
| C. Closure rejoin | At the closure candidate | Apply the separately approved version transition to 0.1.0 and settle every version holder below: Closed M1, M2 and M3 through v2 `A`/`R` in register order, then Accepted M4 through its own v1 amendment proposal and rebind, last |

Phase A settles before acceptance; phases B and C do not, and nothing in them
is a precondition of acceptance. The dependency-oracle change and the new
applications cannot be separated: the checker's complete-inventory predicate
would become false with a ten-application inventory and missing applications
and would route the provider edge through an incompatible legacy rule, so all
land in one reviewed proposal. ADR 0026 governs only the floor and is
satisfied by phase A. The ledger at the planning base is:

| Artifact | Holders | Restriction today | Planned change | Phase | Route and checks |
| --- | --- | --- | --- | --- | --- |
| `.tool-versions` | M0, M1, M2, M3, M4 | Floor 1.17.0/OTP 26.0, current 1.20.3/OTP 29.0.5 at the planning base; settled to floor 1.18.5/OTP 27.3.4 by M0 generation 7, M1 generation 10, M2 generation 11, M3 generation 4 and the M4 refresh on 2026-09-13 and 2026-09-14 | Floor 1.18.5/OTP 27.3.4 | A | v2 `A`/`R` for Closed M0–M3 in register order, or a recorded override naming all of them; Open M4 refreshes its own table; holder-scoped binding and pending-holder report at each intermediate `R`; matrix evidence on both pairs and global bootstrap/inherited greens only after the final M4 binding |
| `scripts/m1-evidence-verifier.exs`, `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, `apps/loopex/test/m1_gate_evidence_test.exs`, `apps/loopex/test/deps_budget_test.exs`, `scripts/check-m2-gate.sh` | M1 holds the verifier, dependency task and tests; M2 holds its gate runner | Active checks name the old floor literally | Change only the floor literals and their expectations | A | Include M1's files in its floor v2 proposal and M2's runner in its own floor v2 proposal; prove floor/current behavior without mixing Phase B's later ten-application dependency decision |
| `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, `apps/loopex/test/deps_budget_test.exs`, `apps/loopex_app_server`, `apps/loopex_telemetry` | M1 (the applications are unbound M4 product) | Eight-application inventory; a client may depend only on core and a composition; core admits no external dependency; both applications are absent | Ten-application inventory, permitted client → contract production edge, `:telemetry` admitted as core's sole external dependency, negative tests, and the minimal ninth and tenth applications in the same proposal | B | One M1 v2 `A` carrying all of these plus M1's generation row; review and accept `A`; governance-only `R`; M1 gate green at `R` |
| `VERSION`, application versions | Every holder below | 0.0.0 | 0.1.0 | C | Separately approved version transition; evidence names the exact version |
| `scripts/m1-exunit-runner.exs`, `apps/loopex/test/m1_exunit_runner_test.exs` | M1, M2, M3, M4 | The selector runner refuses a real report whose build identities are not `@0.0.0` | Version-aware build identities; required, because M4's real lane runs through this runner | C | v2 for M1, M2 and M3 in register order; Accepted M4 last through v1 |
| `scripts/m1-evidence-verifier.exs` | M1 | Fixes `@0.0.0` build identities | Version-aware | C | M1 v2 |
| `scripts/check-m2-gate.sh` | M2 | Requires the version train to report exactly `0.0.0` and `@0.0.0` build identities | Version-aware | C | M2 v2; otherwise the Closed M2 gate is red after the transition |
| `scripts/m3-gate-support.exs`, `scripts/check-closed-gates.sh` | M3, M4 | M3's combined real-path verifier fixes `@0.0.0` | Version-aware; M4's own verifier already reads `VERSION` | C | M3 v2; Accepted M4 last through v1 |

M2 deliberately binds neither dependency file, so it is not a holder there.
The planned `loopex_app_server` depends directly on `loopex_protocol`; the
current client-role rule rejects every internal edge other than core and a
composition. Permit client → contract production dependencies deliberately and
add negative tests, rather than reach the protocol through a transitive
dependency. Where the same holder binds several planned changes, review the
complete coherent proposal together rather than repeat the transaction. Do not
combine unrelated decisions, combine different holders' replacement commits, or
skip any holder. An expressly scoped maintainer override may replace only the
development-time holder transaction or procedure; it cannot replace ADR 0026
acceptance, an accepted ADR decision, or a released public contract. The
operative disposition is recorded and independently reviewed in its own commit;
each holder then lands its replacement row in its own status-checked,
exact-SHA-reviewed commit before the next proceeds. No override ignores a stale
hash or rewrites a prior Acceptance/Closure row. Phase A bindings settle before
M4 acceptance; phase B and C bindings settle before the rejoin or closure
candidate that depends on them, and closure cannot be recorded while any is
stale. The source-only `v0.1.0` release requires the separate release/tag
disposition specified below; no package publication or compatibility freeze is
implied. No floor change is made by this planning edit.

M3 owns resource admission, inherited-gate enforcement and the three repairs.
M4 adds core defer/answer and ArtifactStore transfers before the app-server
maps them. An inherited defect is reproduced at the exact base and repaired at its
owner; a wire workaround cannot conceal it.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M4.md#concept-plan-scope).

| Component | Owns | Cannot own |
| --- | --- | --- |
| `loopex_protocol` | Bounded DTOs, validators, schemas, vectors and capability identity | JSON implementation, runtime or authority |
| `loopex` | Inherited resource facade plus new M4 interaction lifecycle, artifact transfer queries, artifact-use authorization, the trace-session owner and every telemetry emission point | Framing or connection policy; any attached telemetry handler, reporter, exporter or trace sink beyond the diagnostics plane and Logger |
| `loopex_telemetry` | Edge: the single bounded forwarding handler from telemetry events to the diagnostics plane, and reference reporter wiring | Emission points, session semantics, any handler that blocks an emitting process |
| `loopex_app_server` | Foreground lifetime, UTF-8 JSONL framing, request correlation, bounded writer and facade mapping | Store/coordinator calls, a second loop, resource parsing, policy selection |
| `loopex_composition` | Trusted startup wiring, provider companion, explicit prepared handoff and project resource configuration | Wire-supplied implementation selection |
| Independent consumer | User workflow and local output presentation | Normative session, trust or policy semantics |

The ordered rejoin is prerequisite transactions/contracts → observability
(trace sessions and telemetry boundaries) → core interaction
and artifact-transfer witnesses → thin server/client workflow → remaining
method/delivery coverage → integrated audit → independent review. Protocol and
consumer work may develop together against fixed vectors; the integrator owns
one candidate and the real-process rejoin. Prove resource selection, defer,
response, authorized effect, artifact integrity and abrupt restart before
building further UI or generalized transports.

Use the existing command identity for `admit_resources`, `activate_skill` and
`respond_interaction`; request IDs never enter journals or asynchronous facts.
M3 resource queries and M4's ADR 0028 facade transfer queries supply the results. Client trust
answers are evidence presented to host policy, not a way to name arbitrary
filesystem roots or import a URL. Acquisition remains an explicit host workflow.

Initialization negotiates `loopex.experimental/1`, exact schema digest and
server-enforced ceilings. The complete request method table, closed enum sets,
unknown-field policy, numeric representation and every collection/string/frame
bound live in ADR 0023 and canonical schema/vector bytes. Duplicate-key refusal
must be tested before semantic decoding; an ordinary map decoder cannot recover
lost duplicate-key evidence. Stdlib JSON at the accepted floor is the codec;
no external dependency is added to the app-server.

The wire set excludes `session.list` and the two `project_resources` trust
methods. The consumer retains or asks for a known session ID for resume, and
the host's launch configuration alone fixes root AGENTS.md trust.
Unknown-method tests refuse those names without an eager directory scan, a
trust change or durable admission. This preserves the bounded wire and M3
facade-only mapping without adding a new listing index or host trust-management
workflow to M4.

A foreground app-server loss invokes the inherited host shutdown/recovery
contract. Clean EOF shuts down in order without cancelling; abrupt loss leaves
only what the journal proves; only `session.abort` cancels. Neither attachment
nor transport reconnection recreates an expired, denied or cancelled
interaction. The same cancellation,
provider-protection and executor process-tree guarantees as the CLI must hold.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M4.md#concept-plan-outcomes).

| Outcome | Mandatory proof beyond a unit test |
| --- | --- |
| 1 | Independent raw-byte client launches actual server process, exact init/schema/limits vector, refusal before init, no durable work on malformed startup |
| 2 | Identical command corpus through facade/wire; independent variation of request and command identity; snapshot-before-live with the unchanged revision-2 map and same-cursor open-interaction view; committed admission before correlated delivery; command replay after disconnect; core commits exactly one distinct `session.settled` after `run.finished` when no follow-up is queued, none on promotion, with replay and fresh attachment showing no duplicate |
| 3 | Durable interaction request/answer/policy/intent cuts, fixed timestamps through commit_unknown, expiry/abort/restart races, the exact successive-round bound and policy identity; catalog and selected content identity preserved; stale/missing trust withholds content; manual-only restriction; interaction answer admission separately observed from policy re-evaluation, grant/intent commit and tool receipt; every immutable launch input proved unreplaceable from the wire |
| 4 | ADR 0028 one verification per transfer and bounded allocation proved at ArtifactStore and facade with object and chunk digests distinguished; wrong-session use, object/use swap and corruption outside the requested window refused at open; concurrent-transfer and connection-work exhaustion, lifetime expiry, cancellation and descriptor release; oversized/fragmented/multiple frames; malformed UTF-8/duplicate keys/depth; slow reader; bounded queue; late progress; stdout contamination; actual process-tree cleanup |
| 5 | From a fresh extraction of the exact source candidate, an operator follows the documented prerequisites and commands, supplies their own workspace, provider and policy inputs, and launches the foreground app-server and Node consumer; the attended real-provider selector itself runs from the extracted tree and drives skill, interaction answer, policy re-evaluation, committed grant/intent, tool and artifact with real Store and executor, embedding no identities; abrupt kill and fresh-process resume; stdin EOF performs orderly shutdown with no cancellation and a still-pending interaction; `session.abort` is the separate deliberate-cancellation case |
| 6 | Elixir and Node clients execute the same positive/negative vectors without importing the server codec; pinned interpreter versions verified before the lane, absence or mismatch reported as unavailable evidence; the retained full-gate report records the exact candidate commit and tree, archive and extracted-build SHA-256, `VERSION`, lockfile SHA-256, schema/client versions and toolchain/platform identities, and the support verifier rejects missing, reordered or malformed fields |
| 7 | With a real runtime and Store: a session traces only allowed modules and owned processes and leaves a second VM tracer unaffected; each level reports its documented fields; the `arguments` level redacts credential references, model content, tool arguments and artifact bytes to typed placeholders; the exact entry, rate and queue limits drop with a counted entry and never block a coordinator; no session command, client content, model output, project resource or app-server request can start, change or stop a session; stopping releases every trace flag; an OTP release without trace sessions reports unavailability; every callback and transaction cut in ADR 0030's emission inventory emits start/stop or exception with duration and only documented metadata; a crashing handler is isolated; a slow or blocked forwarding sink in `loopex_telemetry` never delays a coordinator and drops with a counted entry; enabled-trace and no-handler overheads are measured and retained |

The opening runner binds one real behavioral red for outcome 3: through a
real local session and Store, a host-policy `defer` is denied as
`interaction_unsupported` instead of committing a pending interaction. It proves
that one missing core behavior; it proves no protocol, transfer, client or
workflow behavior. Its green requires the exact pending record for the probe's
tool call, an explicit pending interaction in the facade status and no terminal,
intent or executor invocation; a run that merely fails to settle is a witness
error, never green. The superseded raw-process scaffold retained at
`ba51d1898bcca109a5ed32a8cc3ba831323113a1` is historical design input.
Before acceptance, bind the real opening red, the exact selectors and witness
names, the canonical schema and vector bytes, the client interpreter pins, the
exact limits and fail-closed routing. After acceptance, implement the server,
the raw-process probe, the language clients and the consumer workflow; every
lane must pass before closure. An echo server cannot pass because admissions,
event order, exact interaction/tool identity, real artifact bytes and fresh
settled snapshots are required. Parsing
fixture-shaped output is not full JSON conformance.

Every protected selector uses the existing authoritative standalone ExUnit
channel. Preserve the inherited repair manifest rather than re-listing old case
counts in this plan. The complete gate runs inherited predecessors, protected
selectors, whole suite, language clients and retained-evidence validation. Use
M3-style checkpoint/full modes and one decisive named witness per clause;
ordinary negatives stay in the required suite without freezing their
inventories. Real provider cases live in separate files. Under the same
preparation rule M3 recorded, future test bodies are written with
implementation; a missing witness is never a pass, and every named witness
must pass before closure.

Apply the M3 [integrated audit](M3-technical.md#technical-plan-evidence)
to direct facade, CLI, wire, recovery child and actual built server/companion.
Test every transaction/lifetime cut and each decoder-side negative at the
receiver, not just the encoder. Run actual Darwin floor/current and Linux
current lanes early. A repeated finding class triggers a full adjacent-path
audit. Final exact-source evidence and independent review remain mandatory;
no fixed review-round limit or retry-to-green rule.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Scope](M4.md#concept-plan-scope).

The `v0.1.0` source tag identifies a numbered release, not a compatibility
freeze. All surfaces remain experimental. Exact generation/schema agreement is
required; there is no mixed-generation promise, public-protocol freeze or daemon
claim.
Unknown mutating discriminants refuse. ADR 0024 adds versioned core interaction
records; the app-server itself writes no private record. M3 resource semantics
remain intact. Source VERSION is distinct
from protocol generation, journal version, provider build and schema digest.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M4.md#concept-plan-scope).

Prove new readers on genuine M3 histories, interaction recovery on M4 records
and old readers refusing unknown interaction records before effects. Retain an
old-format positive control and old root/binary pair; removing the server does
not make an interaction-bearing root readable by M3. Resource behavior and
existing artifact formats remain unchanged. Transfer capability removal restores
the previous full-object API without rewriting artifacts. Restore floor/version/
inventory protections through governed transactions. No in-place downgrade,
installed-data migration or service installation claim.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M4.md#concept-plan-scope).

Add exactly two applications: `loopex_app_server`, the ninth, with role
`:client`, depending inward on core, protocol and composition; and
`loopex_telemetry`, the tenth, with role `:edge`, depending inward on core and
outward on `:telemetry` only. The client-role rule and application inventory
in `loopex.deps_budget.ex` change under their holders' transactions to permit
the direct contract dependency; it is not hidden behind a transitive edge. The
app-server adds zero external production dependencies; existing ReqLLM edge
dependencies remain permitted. Core adds exactly `:telemetry`, a pure-Erlang
library with no dependencies of its own, under the recorded vision change and
ADR 0030 through the same M1 transaction; protocol remains stdlib-only. No
reporter, exporter or OpenTelemetry package enters core, protocol or the
app-server; `loopex_telemetry` owns the only Loopex-attached handler. The floor decision makes the stdlib JSON
codec available; duplicate-key and all other strictness requirements remain
independent tests.

Supply a source-built foreground entrypoint and one independent example, plus
a small Elixir conformance client. Pin the Node version
in `scripts/fixtures/m4/client-toolchain.txt` and bind it in the M4
gate before acceptance; the runner verifies the pinned executable before any
client lane and reports absence or mismatch as UNAVAILABLE. Two independent
implementations are what prove the contract is bytes rather than an Elixir
interface; a third adds breadth, not proof, and belongs to whichever later
milestone wants that breadth. These are isolated
client-validation prerequisites, not a new bootstrap or production dependency. The
example runs on the pinned Node with no build step, package manifest, lockfile
or dependency, so a client lane installs nothing and a gate downloads no
compiler; a later example that needs one settles that decision before it lands
rather than during a lane.

At the separately approved version transition set source VERSION/application
versions to 0.1.0. The full gate stages a tar source archive from its exact
committed candidate with `git archive`, extracts it outside the checkout, and
compiles that extracted source. It runs the attended real-provider selector
from the extracted tree, using the operator guide to launch the server and
Node consumer with operator-supplied inputs. The retained full-gate
report records the candidate commit and tree, archive and extracted-build
SHA-256, `VERSION`,
`mix.lock` SHA-256, schema and client-pin digests, and toolchain/platform. The
source archive contains source and documentation, not credentials, installed
data, a binary, an installer, or a service image. The gate proves this staged
candidate before closure; it cannot require a tag that does not yet exist.
After independent exact-SHA closure review, explicit closure and release/tag
authority, and integration to `main`, create one annotated `v0.1.0` tag on
the exact integration commit on `main` that contains the reviewed closure
transition. Verify that the integration tree preserves the reviewed closure
tree except the approved governance transition bytes. Generate the release
source archive from the tagged commit and retain its separate SHA-256, commit
and tree; verify that the tag, release archive and `VERSION` identify that
commit. The candidate archive smoke remains bound to its own exact SHA and is
not relabeled as a test of the later integration commit. Do not move the tag or
publish Hex packages, binaries, installers or service artifacts.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M4.md#concept-plan-scope).

Two applications, the core policy-interaction slice, the optional ArtifactStore
transfer capability, one stdio mapping, bounded schemas/client fixtures, one
trace-session owner, a bound inventory of telemetry emission points and one
edge forwarding handler justify growth. No per-function logging, no second
event dispatcher, no handler or reporter in core. No new role, and no external
production dependency beyond `:telemetry` in core and in `loopex_telemetry`;
no transport registry, socket abstraction, daemon supervisor, duplicate
resource resolver or second interaction reducer. The app-server has no direct Store/model/executor dependency or private
coordinator shortcut. Artifact object/use identity and launch configuration
reuse existing owners. Implement new interaction/transfer behavior once in core/ports,
then prove all consumer mappings against it. Raw line count is a review signal; behavior and measured limits govern.
<!-- loopex:plan-technical-envelope:end -->
