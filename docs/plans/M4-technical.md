<a id="technical-depth"></a>
## Technical depth

Concept: [Headless external consumption](M4.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M4.md#concept-plan-scope).

Concept: [non-goals](M4.md#concept-plan-non-goals).

M4 is Open as the one permitted planning lookahead after M3's accepted
governance checkpoint integrated to `main`. Its planning base is
`4bba8b74f5e260dc2a364fcbd3554c7badd1a09c`, retained as an ancestor without
rebasing or squashing bound history. The M0–M2 Closed aggregate was proved
green once at the opening candidate; under the reviewed
[planning-revision aggregate override](../developer/agent-context-map.md#override-disposition-m4-planning-aggregate-2026-09-11)
later planning-only revisions of this lineage rely on that result and are not
rerun, while any revision touching product, portable-enforcement or bound
Closed-gate bytes, the refresh onto M3's closure, acceptance, rejoins, rebinds
and closure candidates keep the ordinary aggregate obligation. While Open it records M3 as `Accepted` and
holds no implementation authority. M4 cannot be accepted or implemented until
M3 is Closed and integrated: absorb that exact closed product base, re-prove
every inherited gate green and this milestone's own distinct red, complete its
executable contract/vector tests and obtain fresh exact-SHA review. At final
acceptance all inherited gates are green and the M4 boundary remains
truthfully red for missing external behavior.

M4 accepts four decisions before dependent work:

| Decision | Owner and acceptance point | Effect |
| --- | --- | --- |
| [**ADR 0023**](../adr/0023-experimental-public-session-protocol.md#concept) | Maintainer, before M4 acceptance; must carry the connection state table below | Transport-neutral experimental protocol, exact initialization, identity ownership and fail-closed boundary |
| [**ADR 0024**](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | Maintainer, before M4 acceptance; must fix the exact maximum of successive answer → defer rounds per tool decision | Durable policy `defer`/answer lifecycle owned by the session with host-policy authority preserved |
| [**ADR 0026**](../adr/0026-development-floor-refresh.md#concept) | Maintainer, before M4 acceptance; holder transactions below settle after M3 closes | Explicit floor/current validation pairs replacing the derived pin rule |
| [**ADR 0028**](../adr/0028-bounded-artifact-retrieval.md#concept) | Maintainer, before M4 acceptance; carries the transfer design below | Bounded artifact transfer through the facade and ArtifactStore with distinct object/chunk digests |

**Artifact transfer design (decided).** The earlier draft admitted
1–16,384-byte ranges while the local store admits 64 MiB objects and verified
the complete object on every range, so saving a maximal object would have
verified it 4,096 times. On 2026-09-10, during the M4 planning task, the
maintainer chose one authorized, verified transfer that verifies once and emits
bounded chunks from an owned, cancellable reader, over independent range reads
that would have reduced the feature to bounded excerpts. ADR 0028 now proposes
that design. Both envelopes bind exact values at acceptance for: the opening
verification's deadline and work budget, chunk bytes, per-read deadline,
open-transfer lifetime, concurrent transfers per connection and per runtime,
connection work budget, and read amplification (at most one complete
verification plus one sequential emit per authorized transfer). Missing values
block acceptance.

**Connection state table (required content of ADR 0023).**

| Situation | Required behavior |
| --- | --- |
| Before `initialize` | Every other frame refuses; nothing durable is created |
| Repeated `initialize` or no common generation | Refuse; the connection stays uninitialized; each generation binds exactly one schema digest |
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

**Holder transactions.** The floor refresh (proposed Elixir 1.18.5/OTP 27.3.4
and current 1.20.3/OTP 29.0.5, with real matrix evidence), the ninth
application, the dependency-rule change and source VERSION 0.1.0 each change
bytes that Closed gates bind. The default sequence is exact:

| Phase | When | Transactions |
| --- | --- | --- |
| A. Successor enabling | After M3 closes and integrates, before M4 acceptance | Derive the exact M0–M3 holder inventory on the integrated closure; settle the floor refresh with every `.tool-versions` holder; refresh M4 on that base and re-prove every inherited gate green plus this gate's own red; then accept |
| B. Implementation | After acceptance, on branch `m4`, before the first rejoin that runs the full lanes | Land the M1 dependency-oracle transaction (nine applications, client → contract edge, negative tests) as its own v2 `A`/`R`; then add the ninth application as ordinary product work |
| C. Closure rejoin | At the closure candidate | Apply the separately approved version transition to 0.1.0 and settle every version holder below through its own v2 `A`/`R` in register order; M4 rebinds its own table last |

Because M4 cannot be accepted before M3 closes, every holder is Closed when
its transaction runs; no v1 route applies. Phase A settles before acceptance;
phases B and C do not, and nothing in them is a precondition of acceptance.
ADR 0026 governs only the floor and is satisfied by phase A. The ledger at the
planning base is:

| Artifact | Holders | Restriction today | Planned change | Phase | Route and checks |
| --- | --- | --- | --- | --- | --- |
| `.tool-versions` | M0, M1, M2, M3 | Floor 1.17.0/OTP 26.0, current 1.20.3/OTP 29.0.5 | Floor 1.18.5/OTP 27.3.4 | A | One v2 `A`/`R` per holder in register order, or a recorded override naming all four; matrix evidence on both pairs; each holder's gate green at its `R`; bootstrap |
| `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, `apps/loopex/test/deps_budget_test.exs` | M1 | Eight-application inventory; a client may depend only on core and a composition | Nine-application inventory, permitted client → contract production edge, negative tests | B | One M1 v2 `A`/`R` covering both files; M1 gate green at `R` |
| `apps/loopex_app_server` | None | Absent | Ninth application | B | Ordinary M4 product work after the M1 transaction |
| `VERSION`, application versions | Every holder below | 0.0.0 | 0.1.0 | C | Separately approved version transition; evidence names the exact version |
| `scripts/m1-exunit-runner.exs`, `apps/loopex/test/m1_exunit_runner_test.exs` | M1, M2, M3, M4 | The selector runner refuses a real report whose build identities are not `@0.0.0` | Version-aware build identities; required, because M4's real lane runs through this runner | C | v2 for M1, M2 and M3 in register order; M4 rebinds |
| `scripts/m1-evidence-verifier.exs` | M1 | Fixes `@0.0.0` build identities | Version-aware | C | M1 v2 |
| `scripts/check-m2-gate.sh` | M2 | Requires the version train to report exactly `0.0.0` and `@0.0.0` build identities | Version-aware | C | M2 v2; otherwise the Closed M2 gate is red after the transition |
| `scripts/m3-gate-support.exs`, `scripts/check-closed-gates.sh` | M3, M4 | M3's combined real-path verifier fixes `@0.0.0` | Version-aware; M4's own verifier already reads `VERSION` | C | M3 v2; M4 rebinds |

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
stale. Publication and compatibility freezes still require separate authority.
No floor change is made by this opening.

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
| `loopex` | Inherited resource facade plus new M4 interaction lifecycle, artifact transfer queries and artifact-use authorization | Framing or connection policy |
| `loopex_app_server` | Foreground lifetime, UTF-8 JSONL framing, request correlation, bounded writer and facade mapping | Store/coordinator calls, a second loop, resource parsing, policy selection |
| `loopex_composition` | Trusted startup wiring, provider companion, explicit prepared handoff and project resource configuration | Wire-supplied implementation selection |
| TypeScript consumer | User workflow and local output presentation | Normative session, trust or policy semantics |

The ordered rejoin is prerequisite transactions/contracts → core interaction
and artifact-range witnesses → thin server/client workflow → remaining
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
| 2 | Identical command corpus through facade/wire; independent variation of request and command identity; snapshot-before-live; committed admission before correlated delivery; command replay after disconnect |
| 3 | Durable interaction request/answer/policy/intent cuts, fixed timestamps through commit_unknown, expiry/abort/restart races, the exact successive-round bound and policy identity; catalog and selected content identity preserved; stale/missing trust withholds content; manual-only restriction; interaction answer admission separately observed from policy re-evaluation, grant/intent commit and tool receipt; every immutable launch input proved unreplaceable from the wire |
| 4 | ADR 0028 one verification per transfer and bounded allocation proved at ArtifactStore and facade with object and chunk digests distinguished; wrong-session use, object/use swap and corruption outside the requested window refused at open; concurrent-transfer and connection-work exhaustion, lifetime expiry, cancellation and descriptor release; oversized/fragmented/multiple frames; malformed UTF-8/duplicate keys/depth; slow reader; bounded queue; late progress; stdout contamination; actual process-tree cleanup |
| 5 | TypeScript drives skill, interaction answer, policy re-evaluation, committed grant/intent, tool and artifact with real Store and executor from operator input, embedding no identities; real-provider task separately attended; abrupt kill and fresh-process resume; stdin EOF performs orderly shutdown with no cancellation and a still-pending interaction; `session.abort` is the separate deliberate-cancellation case |
| 6 | Elixir, Python and TypeScript clients execute the same positive/negative vectors without importing the server codec; pinned interpreter versions verified before the lane, absence or mismatch reported as unavailable evidence; exact source/schema/client versions and toolchain/platform identities recorded in the retained report |

The opening runner binds one real behavioral red for outcome 3: through a
real local session and Store, a host-policy `defer` is denied as
`interaction_unsupported` instead of committing a pending interaction. It proves
that one missing core behavior; it proves no protocol, range, client or
workflow behavior. Its green requires the exact pending record for the probe's
tool call, an explicit pending interaction in the facade status and no terminal,
intent or executor invocation; a run that merely fails to settle is a witness
error, never green. The superseded raw-process scaffold retained at
`ba51d1898bcca109a5ed32a8cc3ba831323113a1` is historical design input.
Reconstruct and reconcile the raw-process probe, vectors and the integrated
client fixture against settled contracts before acceptance. An echo server
cannot pass because admissions, event order, exact interaction/tool identity,
real artifact bytes and fresh settled snapshots are required. Parsing
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

All surfaces remain experimental. Exact generation/schema agreement is required;
there is no mixed-generation promise, public-protocol freeze or daemon claim.
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

Add exactly `loopex_app_server`, the ninth application with role `:client`,
depending inward on core, protocol and composition. The client-role rule and
application inventory in `loopex.deps_budget.ex` change under their holders'
transactions to permit the direct contract dependency; it is not hidden behind a
transitive edge. It adds zero external production dependencies; existing ReqLLM
edge dependencies remain permitted.
Core and protocol remain stdlib-only. The floor decision makes the stdlib JSON
codec available; duplicate-key and all other strictness requirements remain
independent tests.

Supply a source-built foreground entrypoint and one TypeScript example, plus
small Elixir/Python conformance clients. Pin Node/TypeScript execution and Python
versions in `scripts/fixtures/m4/client-toolchain.txt` and bind it in the M4
gate before acceptance; the runner verifies the pinned executables before any
client lane and reports absence or mismatch as UNAVAILABLE. These are isolated
client-validation prerequisites, not a new bootstrap or production dependency. Prefer Node's
supported native type stripping and dependency-free TypeScript; if the accepted
runtime cannot execute it, settle the validation-toolchain decision before
acceptance rather than download a compiler during a gate.

At the separately approved version transition set source VERSION/application
versions to 0.1.0. Build the server and provider companion together and run
outside the checkout; retain exact artifact identities. No publication, tag,
package or service install follows from closure alone.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M4.md#concept-plan-scope).

One application, the core policy-interaction slice, the optional ArtifactStore
transfer capability, one stdio mapping and bounded schemas/client fixtures
justify growth. No new role or external production dependency, transport registry, socket
abstraction, daemon supervisor, duplicate resource resolver or second interaction
reducer. The app-server has no direct Store/model/executor dependency or private
coordinator shortcut. Artifact object/use identity and launch configuration
reuse existing owners. Implement new interaction/range behavior once in core/ports,
then prove all consumer mappings against it. Raw line count is a review signal; behavior and measured limits govern.
<!-- loopex:plan-technical-envelope:end -->
