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

M4 accepts ADR 0023 (protocol), ADR 0024 (durable interactions), ADR 0026
(development floor) and ADR 0028 (bounded artifact retrieval) before dependent
work. ADRs 0025/0027 and M3's working resource/launch/repair interfaces are
inherited. Reconcile the schema with those interfaces and the new core contracts;
no TODO member or unproved method earns an advertised capability.

The first prerequisite workstream settles the floor before M4 binds its own
future edits: proposed Elixir 1.18.5/OTP 27.3.4 and current 1.20.3/29.0.5, with
real matrix evidence. Inventory every Closed holder of changed artifacts on the
exact integrated M3 base. M0/M1/M2 are known floor holders; include M3 if its gate
binds the pins or affected machinery. Use each holder's v2 proposal/rebind by
default. An expressly scoped maintainer override may replace only the development-
time holder transaction or procedure; it cannot replace ADR 0026 acceptance, an
accepted ADR decision, or a released public contract. One explicit instruction
may name a coherent set of holders, replacement bindings and validation without
repeatedly asking for the same decision, but the operative disposition is first
recorded and independently reviewed in its own commit. Each affected holder then
lands its replacement row in that holder's own commit, names the override and
holder, passes status validation, and receives exact-SHA read-only review before
the next holder proceeds. No override ignores a stale hash or rewrites a prior
Acceptance/Closure row. Without such approval, retain the default transaction and
its required evidence. Moving this cost from M3 does not remove it, and no floor
change is made by this archived draft.

The ninth app, dependency inventory and source VERSION 0.1.0 also require their
actual holders' transactions or the explicitly approved development-time override
route above. Where the same holder binds several planned changes, review the
complete coherent proposal together rather than lock known future edits and
repeat the transaction. Do not combine unrelated decisions, combine different
holders' replacement commits, or skip any holder. All replacement bindings settle
before M4 acceptance; publication and compatibility freezes still require
separate authority.

M3 owns resource admission, inherited-gate enforcement and the three repairs.
M4 adds core defer/answer and ArtifactStore ranges before the app-server maps
them. An inherited defect is reproduced at the exact base and repaired at its
owner; a wire workaround cannot conceal it.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M4.md#concept-plan-scope).

| Component | Owns | Cannot own |
| --- | --- | --- |
| `loopex_protocol` | Bounded DTOs, validators, schemas, vectors and capability identity | JSON implementation, runtime or authority |
| `loopex` | Inherited resource facade plus new M4 interaction lifecycle, range query and artifact-use authorization | Framing or connection policy |
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
M3 resource queries and M4's ADR 0028 facade range query supply the results. Client trust
answers are evidence presented to host policy, not a way to name arbitrary
filesystem roots or import a URL. Acquisition remains M3's operator-only
runtime-control and authorized-hand workflow; M4 adds no acquisition wire method.
The host alone supplies M3's exact bound-manifest/current-attestation envelope
as immutable process-start configuration. The app-server retains it without
starting or attaching a runtime until protocol initialization succeeds. It then
starts or attaches that runtime, allows M3's pre-child binding transaction to
settle, and only afterwards accepts the first post-initialization request. A
missing, malformed or incompatible initialization produces zero runtime
attachment, binding transaction or other durable mutation. Exact match permits
ordinary service; changed or unavailable source permits only the inherited
recovery operations. No
initialization field, request, interaction answer, or client schema may select or
weaken that mode.

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
| 3 | Durable interaction request/answer/policy/intent cuts, fixed timestamps through commit_unknown, expiry/abort/restart races and policy identity; catalog and selected content identity preserved; M3 bound-manifest/current-attestation and recovery-only mode preserved across process restart; stale/missing trust withholds content; manual-only restriction; interaction answer admission separately observed from policy authorization and tool receipt; wire-selected policy/module/root/snapshot/attestation/mode refused |
| 4 | ADR 0028 full-object verification and range allocation proved at ArtifactStore and facade, object and range digests distinguished; oversized/fragmented/multiple frames; malformed UTF-8/duplicate keys/depth; slow reader; bounded queue; late progress; stdout contamination; actual process-tree cleanup |
| 5 | TypeScript drives skill/interaction/tool/artifact with real Store and executor; real-provider task separately attended; abrupt kill and fresh-process resume; graceful EOF case remains distinct |
| 6 | Elixir, Python and TypeScript clients execute the same positive/negative vectors without importing the server codec; exact source/schema/client versions and toolchain/platform identities |

The superseded raw-process scaffold is retained in Git history at
`ba51d1898bcca109a5ed32a8cc3ba831323113a1`; it is removed from live scripts.
Reconstruct and reconcile vectors and the integrated client fixture only when
M4 opens. Complete and lock the revised executable proof before acceptance. An echo server cannot pass because admissions, event order, exact
interaction/tool identity, real artifact bytes and fresh settled snapshots are
required. Parsing fixture-shaped output is not full JSON conformance.

Every protected selector uses the existing authoritative standalone ExUnit
channel. Preserve the inherited repair manifest rather than re-listing old case
counts in this draft. The complete gate runs inherited predecessors, protected
selectors, whole suite, language clients and retained-evidence validation. Use M3
checkpoint/full modes and one decisive named witness per clause; ordinary
negatives stay in the required suite without freezing their inventories. Real
provider cases live in separate files. No current M4 opening proof is claimed.

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
Unknown mutating discriminants refuse. ADR 0024 adds versioned core interaction
records; the app-server itself writes no private record. M3 snapshot binding,
current-attestation, recovery-only, acquisition provenance, and separate fresh-
runtime use semantics remain intact. Source VERSION is distinct
from protocol generation, journal version, provider build and schema digest.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M4.md#concept-plan-scope).

Prove new readers on genuine resource-enabled M3 histories and genuine resource-
disabled M2-form histories, interaction recovery on M4 records, and old readers
refusing unknown interaction records before effects. Retain both positive
controls and their matching old root/binary pairs; removing the server does not
make an interaction-bearing root readable by M3. An M4 host preserves the exact
M3 launch envelope and recovery-only behavior across server restart. Resource behavior and
existing artifact formats remain unchanged. Range capability removal restores
the previous full-object API without rewriting artifacts. Restore floor/version/
inventory protections through governed transactions. No in-place downgrade,
installed-data migration or service installation claim.

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

One application, the core policy-interaction slice, optional ArtifactStore range
capability, one stdio mapping and bounded schemas/client fixtures justify growth. No new role or external production dependency, transport registry, socket
abstraction, daemon supervisor, duplicate resource resolver or second interaction
reducer. The app-server has no direct Store/model/executor dependency or private
coordinator shortcut. Artifact object/use identity and launch configuration
reuse existing owners. Implement new interaction/range behavior once in core/ports,
then prove all consumer mappings against it. Raw line count is a review signal; behavior and measured limits govern.
<!-- loopex:plan-technical-envelope:end -->
