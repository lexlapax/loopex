<a id="technical-depth"></a>
## Technical depth

Concept: [Headless external consumption](M4.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M4.md#concept-plan-scope).

Concept: [non-goals](M4.md#concept-plan-non-goals).

M4 is unopened. While M3 is Open there is no second planning lookahead. After
M3's accepted governance checkpoint is integrated, the one-successor lookahead
rule may be used exactly as AGENTS.md defines. M4 cannot be accepted or
implemented until M3 is Closed and integrated. Move this triple into docs/plans
only when opening it, absorb the exact permitted base without discarding bound
history, complete its executable contract/vector tests and obtain fresh review.
At final acceptance all inherited gates are green and the M4 boundary remains
truthfully red for missing external behavior.

[Proposed ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept)
must be accepted before M4. ADRs 0024–0028 and M3's actual resource, interaction,
artifact and launch interfaces are inherited prerequisites, not M4 deliverables.
Before acceptance reconcile the entire schema with those implemented interfaces;
no TODO member or unimplemented method earns an advertised capability.

The ninth application and dependency-inventory changes, and the source VERSION
change to 0.1.0, require the applicable Closed M1/M2 gate generations. Resolve
the holder inventory on the exact M3 base, include any M3-bound artifact holder,
and settle each transaction sequentially before binding those bytes in M4.
Do not freeze an inventory that the milestone already promises to replace.
Publication/tag/release and each compatibility freeze remain separate decisions.

M3 owns floor settlement, inherited-gate enforcement, context/dispatcher/permit
repairs and cleanup/configuration consistency. M4 does not carry duplicate
versions of those workstreams. A newly observed inherited defect is reproduced
at the exact base with the same command/signature and dispositioned through
its owner; a protocol workaround cannot conceal it.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M4.md#concept-plan-scope).

| Component | Owns | Cannot own |
| --- | --- | --- |
| `loopex_protocol` | Bounded DTOs, validators, schemas, vectors and capability identity | JSON implementation, runtime or authority |
| `loopex` | M3 facade, session input, interactions, resource admission, artifact-use authorization and truth | Framing or connection policy |
| `loopex_app_server` | Foreground lifetime, UTF-8 JSONL framing, request correlation, bounded writer and facade mapping | Store/coordinator calls, a second loop, resource parsing, policy selection |
| `loopex_composition` | Trusted startup wiring, provider companion, explicit prepared handoff and host resource roots | Wire-supplied implementation selection |
| TypeScript consumer | User workflow and local output presentation | Normative session, trust or policy semantics |

The ordered rejoin is contracts → thin server and client workflow → remaining
method/delivery coverage → integrated audit → independent review. Protocol and
consumer work may develop together against fixed vectors; the integrator owns
one candidate and the real-process rejoin. Prove resource selection, defer,
response, authorized effect, artifact integrity and abrupt restart before
building further UI or generalized transports.

Use the existing command identity for `admit_resources`, `activate_skill` and
`respond_interaction`; request IDs never enter journals or asynchronous facts.
M3's resource queries and read_artifact API supply the results. Client trust
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
contract. Explicit graceful EOF can cancel its owned run; abrupt loss leaves
only what the journal proves. Neither attachment nor transport reconnection
recreates an expired, denied or cancelled interaction. The same cancellation,
provider-protection and executor process-tree guarantees as the CLI must hold.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M4.md#concept-plan-outcomes).

| Outcome | Mandatory proof beyond a unit test |
| --- | --- |
| 1 | Independent raw-byte client launches actual server process, exact init/schema/limits vector, refusal before init, no durable work on malformed startup |
| 2 | Identical command corpus through facade/wire; independent variation of request and command identity; snapshot-before-live; committed admission before correlated delivery; command replay after disconnect |
| 3 | Catalog and selected content identity preserved; stale/missing trust withholds content; manual-only restriction; interaction answer admission separately observed from policy authorization and tool receipt; wire-selected policy/module/root refused |
| 4 | M3 range verification reused, object and range digests distinguished; oversized/fragmented/multiple frames; malformed UTF-8/duplicate keys/depth; slow reader; bounded queue; late progress; stdout contamination; actual process-tree cleanup |
| 5 | TypeScript drives skill/interaction/tool/artifact with real Store and executor; real-provider task separately attended; abrupt kill and fresh-process resume; graceful EOF case remains distinct |
| 6 | Elixir, Python and TypeScript clients execute the same positive/negative vectors without importing the server codec; exact source/schema/client versions and toolchain/platform identities |

The existing raw-process probe witnesses the initial protocol/interaction
subset, not complete skills support. Extend its vectors and the integrated
client fixture after M3 contracts settle; complete and lock them while M4 is
Open. An echo server cannot pass because admissions, event order, exact
interaction/tool identity, real artifact bytes and fresh settled snapshots are
required. Parsing fixture-shaped output is not full JSON conformance.

Every protected selector uses the existing authoritative standalone ExUnit
channel. Preserve the inherited repair manifest rather than re-listing old case
counts in this draft. The complete gate runs inherited predecessors, protected
selectors, whole suite, language clients and retained-evidence validation. Its
scaffolding may be exercised now, but no M4 opening/acceptance proof is claimed
by keeping draft files or obtaining the M2-era EOF observation.

Apply the M3 [integrated audit](../plans/M3-technical.md#technical-plan-evidence)
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
Unknown mutating discriminants refuse. The app-server adds no durable record
family; interactions/resources already belong to M3. Source VERSION is distinct
from protocol generation, journal version, provider build and schema digest.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M4.md#concept-plan-scope).

Prove fresh-process restart on actual M3-format data and old-reader controls for
any separately accepted new format. M4 cannot silently add a Store schema to
support its mapping. Removing the experimental server/client leaves M3's
embedded/terminal capabilities and data intact. Restore any version/inventory
protection through governed transactions; never delete historical authority.
No installed-data migration, in-place downgrade or service installation claim.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M4.md#concept-plan-scope).

Add exactly `loopex_app_server`, the ninth application with role `:client`,
depending inward on core, protocol and composition. It adds zero external
production dependencies; existing ReqLLM edge dependencies remain permitted.
Core and protocol remain stdlib-only. The floor decision makes the stdlib JSON
codec available; duplicate-key and all other strictness requirements remain
independent tests.

Supply a source-built foreground entrypoint and one TypeScript example, plus
small Elixir/Python conformance clients. Pin Node/TypeScript execution and Python
versions in the M4 gate before acceptance; these are isolated client-validation
prerequisites, not a new bootstrap or production dependency. Prefer Node's
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

One application, one stdio mapping, bounded schemas/vectors and the small client
workflow justify growth. No new role or external production dependency; no
transport registry, socket abstraction, daemon supervisor, duplicate resource
resolver, second interaction reducer, direct Store/model/executor dependency or
private coordinator shortcut. Artifact verification and launch configuration
reuse M3. Raw line count is a review signal; behavior and measured limits govern.
<!-- loopex:plan-technical-envelope:end -->
