<a id="technical-depth"></a>
## Technical depth

Concept: [Responsive creation transactions](0059-responsive-creation-transactions.md#concept).

<a id="technical-adr-0059-purpose"></a>
### Current path and accepted constraints

Concept: [Purpose and evidence](0059-responsive-creation-transactions.md#concept-adr-0059-purpose).

Source base is `92f86ae8`, the administrative acceptance child of ADR 0055.
Accepted [creation custody](0055-remote-session-creation-options-technical.md#technical-preparation)
requires serviceable stop/status and prohibits worker Store writes.
[The active slot](0055-remote-session-creation-options-technical.md#technical-overlap)
lasts through terminal disposition and specifies no-Store overlap refusals.
The prohibition is amended only by the explicit exception below.

Current source has no asynchronous transaction mechanism meeting both clauses:

| Source | Inspected mechanism |
| --- | --- |
| `apps/loopex/lib/loopex/runtime/control.ex:2281–2296` | `create_session` constructs the proposal, reads freshness and calls `resolve_transaction` before returning from Control's callback. |
| `control.ex:4008–4013` | Resolution calls OwnerLane synchronously and makes one further exact presentation on `commit_unknown`. |
| `apps/loopex/lib/loopex/store/owner_lane.ex:75–148` | Caller-owned lane validates scope/immutable binding, calls Store and then updates its fence. It creates no process. |
| `apps/loopex/lib/loopex/store.ex:978–1002` | `Store.transact` invokes the adapter in its caller and normalizes adapter exit/lost reply to the original transaction's `commit_unknown`. |
| `apps/loopex_store_local/lib/loopex/store/local.ex:65,115–117,204–215` | Local serializes mutations through `GenServer.call` with a 30,000 ms call timeout. A blocked adapter wait blocks its caller. |

The existing timeout is not responsive intake: Control cannot process another
message during the call. A throwaway process that calls `OwnerLane.transact`
and returns a replacement lane also fails the ownership requirement if Control
has not retained the binding/fence before dispatch. Dropping that process can
otherwise drop the only caller-side ambiguity fence.

[ADR 0006](0006-store-transaction-and-owner-epoch.md#concept-adr-0006-decision)
retains three Store outcomes and exact bindings;
[ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept)
retains serial runtime placement and recovery. The selected amendment adds
closed creation transactions, private durable custody and one optional read,
not an adapter-specific message format. The existing
Store may live outside the runtime tree; runtime stop cannot promise that its
queued transaction is removed.

<a id="technical-adr-0059-decision"></a>
### Exact proposal, mechanical carrier and placement

Concept: [Proposed carrier and Store-owned custody](0059-responsive-creation-transactions.md#concept-adr-0059-decision).

The normative exception to ADR 0055's sentence “No worker writes Store,
publishes durable events or allocates an active session” is:

> Preparation and read workers never mutate Store. For creation startup/recovery
> or the active creation only, Control may permit an owned mechanical transaction carrier to make
> one call to the existing `Store.transact` with the exact Control-retained
> claim, reserve, final-create or close transaction. Control retains the canonical proposal and its complete
> immutable runtime-domain OwnerLane binding and fence before that permit.
> The carrier has no independent mutation selection, lane ownership, retry,
> publication or session-activation authority.

Store RPC means invoking the existing mutation callback, not writing files or sending
private adapter messages. The Store remains responsible for its atomic
transaction, binding checks, durable outcome and internal resources. A carrier
may not substitute another Store, tx ID, canonical record, digest, selected
definitions or genesis. The current v3 genesis cap remains 65,536 bytes.

Control retains the active entry required by ADR 0055 and, for presentation:
exact canonical transaction and immutable binding, mutation scope, original
command/caller, owner/incarnation, invocation identity, phase, original
cutoffs, exact carrier PID/monitor, one-use permit identity and outcome/join
observations. These actor/cutoff/permit values are private volatile owner values.
The complete candidate and creation head specified below are separately durable
plain data; no PID, handle, monitor, cutoff or permit enters them or public
DTOs. Store handles and monitors remain private.

Before dispatch Control validates the proposal and rechecks its lane. It
installs the complete binding as a conservative runtime-domain fence, not a
durable claim that a commit happened. An undispatched cancellation may clear
this local provisional fence only with exact no-permit/no-dispatch and owned cleanup proof.
Once permitted, only exact terminal resolution or the expressly governed
dead-owner claim/close transitions below can clear the matching ambiguity. No
unrelated transaction may bypass it.

Use an internal pure admission/outcome split of the existing OwnerLane logic,
with Control retaining its updated value, rather than giving authoritative
lane state to the carrier. Independent synchronous OwnerLane callers outside
this Control creation domain retain their existing semantics. Within this
domain, neither of the existing native create handlers may call the lane while
the authored slot is held, even for a matching binding. This is a bounded
internal ownership refactor. The new Store contracts below are separately
Proposed; they do not authorize other mutation workers.

#### Trusted placement and owner selection

Reuse ADR 0008's placement key: the logical authoritative Store namespace plus
runtime ID `R`, not equality of handles or a Store PID. The native host selects
that namespace through the supplied `%Store{}` and supplies `runtime_id` to
`Runtime.start_link/1`. Current validation (`runtime.ex:125–136,978–1032`) binds
both into immutable root options; `Runtime.Supervisor.init/1:55–97` passes them
to Control. `Control.init/1:349–414` retains this exact Store/R pair. These
mechanics bind supplied values; they cannot verify external host exclusion.

Before starting a replacement, the host must quiesce or positively know the
prior Control for that logical placement ended, as accepted ADR 0008 already
requires. Same-root rest-for-one restart retains the original monitored Control
join under supervision. A new root/VM needs the host's external dead-owner
fact; local observations cover only locally owned actors. No startup metadata
from clients, returned UUID or Store generation establishes that fact. No new
namespace/placement-check API or VM-global lock is proposed. Simultaneous raw
Store conformance contenders prove CAS, not supported active-active runtimes.

Each new Control incarnation privately allocates one selection `S`: 32 fresh
cryptographic bytes encoded as 64 lowercase hexadecimal bytes. It retains
`S`, root/token and the supplied Store/R before claim dispatch. A restarted
Control, even under the same root, selects a new `S`; selections never transfer
between owners. The same owned Control retains `S` across its bounded claim
attempts. The head's returned generation/selection is an observation, never
permission to displace a live placement. No new host identity API is required.

This is a runtime-control fence, not a session owner epoch or a routing lease.
It never grants session activation, effect authority or cross-runtime access.
The existing host exclusion and current session fences still apply.

<a id="technical-adr-0059-serviceability"></a>
### Nonblocking intake and original bounds

Concept: [Serviceability and limits](0059-responsive-creation-transactions.md#concept-adr-0059-serviceability).

Actor/admission limits are one active creation/startup-recovery slot, one invocation,
at most one live transaction carrier and one outstanding transaction permit
for that slot. Existing preparation callback work retains its existing owned
group and admitted child bounds. Its cleanup must be proved before transaction
dispatch; a carrier cannot hide outstanding preparation work. No second
preparation, duplicate reply waiter or application-level create queue is added.
Existing transport intake capacities remain unchanged.

Install the carrier in the runtime-owned private custody before sending its
permit. The carrier waits for the exact Control/incarnation/invocation/permit
tuple, makes one exact Store call and returns its normalized outcome to Control.
Immediately before that call it checks the original work cutoff and any
received stop/owner-loss signal; it cannot start an expired RPC. After a permit
has been sent, lack of a matching terminal result still retains uncertainty,
not an inferred non-commit. Only exact owned no-dispatch evidence can establish
that the adapter was never called.
It cannot loop on unknown or renew a cutoff. Control validates the full result
identity and requires the original actor joins, not a monitor installed after
the actor may already have exited. A result-owning guardian or retained group
keeps proof through caller/Control loss; an unjoined resource remains uncertain.
Host Store/telemetry callbacks remain trusted boundary code, and any
callback-created invocation actors must satisfy the existing custody rules;
the carrier is not a sandbox or an exception to those rules.

Capture `work_cutoff` once at original creation worker start plus 60,000 ms,
before initial reads, and use that same instant for preparation, carrier
admission and resolution. Preserve host-captured cleanup grace and existing
absolute cleanup selection/observation rules. Neither a later phase nor exact
re-presentation starts a fresh work or cleanup period. Control enforces stop
and expiry independently while the carrier waits. Existing forced retirement
and original join observations remain required; killing a blocked carrier is
not Store cancellation evidence.

Control returns from its handler with the slot retained and processes later
messages. After ordinary authority/syntax validation, overlaps compare only
the retained normalized authored input, including supplied-member presence,
exact instruction sections and ordered tools. They use ADR 0055's three exact
dispositions, perform no Store call and add no waiter. Status routes and stop
intake perform no wait on the active creation Store RPC. Stopped/expired work
cannot admit preparation, reservation or a final-create permit. Only an exact
non-activating resolution/close may spend the already selected cleanup episode;
it gains no new work cutoff or grace.

The occupied-slot gate applies before candidate reconstruction or any Store
freshness/provenance/OwnerLane operation to both current native handlers:
`{:create_session,token,command_id,session_options,mode}` and
`{:create_session_with_genesis,token,command_id,session_options,genesis}`
at `control.ex:528–565`. Existing authority, quiescing and pure syntax refusals
retain their precedence. A valid native request while the authored slot is
held receives `creation_in_progress`, regardless of its command ID or supplied
genesis, including an exact same binding. The implicit handler uses its existing
legacy/detailed mode; the complete-genesis handler uses its existing detailed
result with `no_activation` and no session ID. Native busy intake performs no
binding reconstruction/comparison, Store call, reservation or second carrier.
It does not cancel the active command. Authored intake still compares original
normalized authored input purely and returns `runtime_command_conflict` for
its same-ID changed-input branch. The native busy response proves occupation,
not an authored conflict. After slot release, both native routes must obey the
current generation, reservation and final eligibility rules below. They use the
same owned slot and carrier; neither retains an unreserved synchronous fresh
create path. Existing legacy/detailed result envelope shapes remain, with the
explicit closed cancellation reason below. While startup/recovery has not established eligibility,
creation uses existing bounded unavailable/no-activation disposition, never a
pending queue.

Other Store-dependent Control intake uses immediate existing unavailable
results for the entire held interval, including preparation, carrier work and
retirement. Existing authority/pure syntax checks run first. It starts zero
read workers, retains zero additional reply entries and adds zero queued
reads. It does not call the bounded reader and wait, defer a reply, spend the
original creation allowance on another request or manufacture an absent key.
The active invocation's already-authorized reads/RPC remain separately owned
under its original limits; this policy applies to other Control intake.

Complete current Store-wait inventory and existing occupied results:

| Control intake or internal path | Current Store wait | Required occupied behavior |
| --- | --- | --- |
| Native implicit/default and complete-genesis create, `:528–565,2281–2296` | Freshness `Store.runtime_command`; OwnerLane transaction and exact resolution | Existing `creation_in_progress`, existing native error/detail envelope, `no_activation`; no lookup/transact even for exact binding. |
| `session_existence`, `:566–579` | `Store.ownership_head` | Existing `{:ok,:store_unavailable}`; no authoritative present/absent observation. |
| Both `lookup_create_result` handlers, `:581–611,2520–2555` | `Store.runtime_command` through the existing lookup | Existing `{:ok,:store_unavailable}`; no candidate reconstruction or historical/fresh lookup. |
| `creation_provenance`, `:613–625` | `Store.creation_provenance` | Existing `{:ok,:store_unavailable}`; no provenance observation. |
| `effect_intents`, `:627–641` | `EffectIntents.read` inside `bounded_store_read` | Existing `{:error,:history_unavailable}` immediately; no read guardian or reader. |
| `resume_session`, `:643–711` | `Store.runtime_command` | Existing `{:error,:store_unavailable}` through the handler's current legacy/detailed mode with `no_activation`; no owner succession. |
| `provider_dispatch` to `provider_position_binding`, `:865–883,3703–3734` | Cardinality-bounded attempt-open/tail `Store.load_records` under the bounded reader | Existing unavailable-read refusal `{:error,:invalid_provider_attempt_binding}` at the Store-proof branch; no permit/spent-map addition and no reader. Existing earlier pure owner/deadline/spent checks retain their refusals. |
| `post_commit` to `retire_settled_attempts`, `:886–910,1247–1284` | Optional committed settlement-range `Store.load_records` via `bounded_receipt_records_read` | Skip the retirement read, retain the complete spent map, acknowledge the otherwise valid post-commit receipt and preserve existing route/position updates. Do not infer settlement or drop a spent key. |

`Store.create_session`, `Store.immutable_binding`, normalization/measurement and
cardinality helpers are pure constructors/validators, not additional adapter
waits. Nevertheless occupied native create and lookup do not reconstruct their
candidates. The scan of Control's Store calls and both bounded reader call
sites found the paths above; no quiesce helper is inferred. Post-commit retains
spent identities when settlement proof is unavailable under its existing rule.
Those retained identities grant no new dispatch authority.

There is no established equivalent local provider proof to substitute here.
Control's current owner entry retains journal position, and post-commit receipt
retains positions; neither supplies the full attempt-open binding and validated
tail required by `provider_position_binding`. Existing spent entries are prior
permit evidence, not fresh attempt authority. The current source explicitly
reads committed Store rows for that proof. A new cached authority record would
be a separate design and is not implemented or implicitly authorized here.

This policy may refuse another session's next provider permit while fresh
creation owns the slot even if Store is healthy. That consequence is proposed
explicitly. Already-issued work is not cancelled, ready session/status routes
remain usable, and optional spent retirement does not stall its post-commit
acknowledgement. The policy promises responsive Control intake, not Store
availability, immediate scheduling or completion of other Store-dependent
operations. Occupied-read policy uses existing failure categories; the separate
terminal cancellation reason below is an explicit additional proposed value.

<a id="technical-adr-0059-recovery"></a>
### State transitions and unknown recovery

Concept: [Cancellation and durable truth](0059-responsive-creation-transactions.md#concept-adr-0059-recovery).

#### Closed private records and canonical identities

Use fixed native keys/tags, no extensible metadata. `R`, command ID `X` and
transaction IDs obey the existing 256-byte ID domain; `S` is the selection
above. `G` and `V` are unsigned 64-bit owner generation and domain version.
`U = 18,446,744,073,709,551,615`. Nullable IDs are either a valid ID or `nil`;
they are not omitted. Digests are exactly 32 raw SHA-256 bytes. Reject extra
keys, structs, resources, arbitrary terms and inconsistent conditional members.

| Record | Exact keys and relationships |
| --- | --- |
| Head, indexed by `R` | `version: 1`, `owner_generation: G`, `owner_selection: S`, `domain_version: V`, `active_command_id: X or nil`. Absent head is the normalized zero head (`G=V=0`, `S=nil`, active=nil); only that initial head admits nil selection. |
| Command capsule, indexed by `{R,X}` | `version: 1`, `runtime_id: R`, `command_id: X`, `reservation_tx_id`, `reservation_owner_generation`, `reservation_owner_selection`, `reservation_domain_version`, `genesis`, `state`, `final_resolution`, `session_id`. Reservation generation/selection are its pre-reserve origin; reservation domain version is the resulting `V+1`. |
| Capsule `state: :reserved` | `final_resolution=nil`, `session_id=nil`; head active is exactly X. |
| Capsule `state: :created` | `final_resolution=:committed`, valid `session_id` equals the original create receipt; no active reference to this capsule. |
| Capsule `state: :not_committed` | `final_resolution={:not_committed,:creation_cancelled}`, `session_id=nil`; no active reference to this capsule. No arbitrary adapter reason/text enters this DTO. |

`genesis` is the complete original unstamped current v3 genesis, validated by
current SessionGenesis and authored-capture validators, at most 65,536 bytes.
Its existing options retain supplied-member presence, instruction sections,
ordered tools, alias and resolved captures. There is one authoritative genesis
in the discoverable capsule, not another editable capture. Reconstruct final
transaction `F = Store.create_session(R,X,genesis)` only from it. Compare both
full canonical bytes and digest; equal digests never excuse differing bytes.
Existing retained transaction history may contain its own immutable binding,
as it already must; that is not another candidate owner.

Every new mutation has exactly its semantic keys below plus
`canonical_record_bytes` and `canonical_mutation_digest`. Encode the listed
ordered semantic values with the existing deterministic canonical recipe
`term_to_binary(["loopex_store_transaction_v1" | values], [:deterministic])`;
require recomputation equality and existing 1,048,576-byte canonical ceiling.
The type value is part of those bytes. Identifier recipes below use
lowercase-hex SHA-256 of deterministic encoding of the bracketed list; they
do not hash the candidate to conceal same-ID changed-byte conflicts.

| Family | Ordered semantic keys and transaction-ID recipe |
| --- | --- |
| `:claim_creation_domain` | `type,runtime_id,expected_owner_generation,owner_selection,tx_id`; ID from `["loopex_creation_claim_v1",R,expected_G,S]`. |
| `:reserve_creation` | `type,runtime_id,command_id,owner_generation,owner_selection,expected_domain_version,genesis,tx_id`; ID from `["loopex_creation_reserve_v1",R,X,G]`. |
| `:close_creation_reservation` | `type,runtime_id,command_id,owner_generation,owner_selection,expected_domain_version,reservation_tx_id,reservation_domain_version,final_canonical_record_bytes,final_canonical_mutation_digest,tx_id`; ID from `["loopex_creation_close_v1",R,X,reservation_tx_id,G,V,S]`. |

Final `:create_session` keeps exactly its current semantic keys
`type,runtime_id,command_id,genesis`, its existing canonical recipe and final
transaction ID X. The required reservation identity/version relation is
looked up atomically by `{R,X}`: the capsule's reservation terminal binding
must match its origin generation/selection, resulting reservation V, complete
genesis and reconstructed F. An unknown final presentation without that exact
durable relation is refused, even from a native/direct Store caller. No ID or
digest-only check substitutes for full bytes. The relation remains unchanged
when a successor claims the runtime generation.

New-family transaction resolutions are scoped by `{R,type,tx_id}`, separately
from the existing runtime command `{R,X}` final resolution. Existing final
history keeps its current namespace and exact binding. Lookup of a known
binding precedes eligibility: known committed or cancelled F returns its exact
original outcome, even under a later generation. A changed binding returns
`tx_id_conflict`/runtime-command conflict and cannot replace the command capsule.
These are current known histories, not an unreserved unknown-create fallback.
After migration all constructors/callers use the same current eligibility.

Claim/reserve receipts have exactly `type,runtime_id,owner_generation,
owner_selection,domain_version,active_command_id`; reserve additionally has
`reservation_tx_id,reservation_domain_version`. Close receipts have those six
common keys plus `command_id,reservation_tx_id,final_resolution,session_id`.
Receipt counters are resulting head values; terminal outcome members use the
capsule grammar above. Receipt validation cannot promote a known historical
claim receipt to current eligibility. Final-create receipt remains unchanged.
All mutation callbacks retain the three existing outer Store outcomes.

New-family terminal refusal reasons are a closed private set:
`invalid_transaction`, `tx_id_conflict`, `stale_creation_generation`,
`creation_domain_conflict`, `creation_in_progress`, `runtime_command_conflict`,
`creation_counter_exhausted`, `creation_recovery_too_large` and
`creation_reservation_conflict`. Validate known full binding first; reject
malformed shape as invalid, changed known binding as tx-ID conflict, current
G/S mismatch as stale generation, V mismatch as domain conflict, occupied
reserve as creation-in-progress, retained X mismatch as runtime-command
conflict, insufficient increments as counter exhausted, measured reply overflow
as recovery-too-large, and wrong close reservation relation as reservation
conflict. These refusals change no head/capsule, and reserve refusal never
creates a logical command record. Their own valid transaction resolution is
retained under the new-family namespace. An unknown unreserved final F receives
retained `creation_reservation_required` under its exact final binding; runtime
never invokes that path after migration. Malformed or differing final F cannot
close any capsule. Infrastructure loss is unknown, not one of these refusals.
Runtime maps `runtime_command_conflict` and `tx_id_conflict` to existing
`runtime_command_conflict`, occupied reserve to existing `creation_in_progress`,
and the other internal ineligibility reasons (including unreserved-final
defence) to existing `store_unavailable`, all with no activation. Earlier pure
syntax/authority refusals retain precedence. It exports no new reason from this set.
The separately specified retained `creation_cancelled` is the added observable
refusal. Adapter/schema validation must enforce these distinctions, not accept
arbitrary adapter reason text into a capsule.

#### Atomic mutation rules and close headroom

1. Claim compares expected G against the atomic current/initial head, increments
   G once and installs S. It preserves V and active capsule exactly. A known
   exact claim resolves first; a fresh wrong-generation claim is a retained
   terminal stale-generation refusal. New Control eligibility requires its
   matching claim receipt **and** a matching post-claim atomic head observation,
   never the receipt alone. Claim cannot change session ownership or routing.
2. Reserve runs only after successful preparation and all original preparation
   actors are joined. It compares current G/S, expected V, active=nil and fresh
   logical command X. It validates the entire capsule and its recoverable reply
   preflight. Atomically it retains the reservation binding/receipt, installs
   the capsule, sets active=X and increments G and V once. The receipt supplies
   the resulting head to the same Control. No session, public event, model or
   executor request exists yet. Same X with different canonical genesis is a
   conflict; a stale-generation reserve never overwrites current history.
3. Unknown final F is eligible only against that exact reserved capsule and
   active head reference. It need not borrow a successor's selection: an old
   already-permitted F may still win, but only for that immutable candidate.
   Success atomically writes the ordinary session/genesis/result, exact F
   binding/committed resolution, command state created, active=nil and G+1/V+1.
   The matching terminal refusal of an admitted reserved F is the cancellation
   installed by close below; infrastructure uncertainty remains unknown, not
   a new capsule refusal. Invalid or mismatched F cannot close another capsule.
   Resulting head values are read
   before another fresh create; ordinary final receipt remains unchanged.
4. Close is a distinct immutable transaction, never changed F bytes under X.
   It validates exact R/X/reservation ID/version and reconstructed full F
   bytes/digest. Atomically, known exact F terminal history is checked before
   new eligibility: retain close's own binding/receipt returning that historical
   result, without overwriting it or advancing/releasing another head. Otherwise
   require current G/S/V and active X, then close writes
   the **original F canonical bytes, digest and terminal**
   `{:not_committed,:creation_cancelled}` resolution to final transaction
   history, sets its capsule not_committed, clears only active X and advances
   G/V once, together with close's own committed binding/receipt. This newly
   specified durable cancellation is not assumed from today's non-commit
   persistence. A delayed F resolves that cancellation before eligibility and
   cannot create or reopen. Mismatched close cannot affect another reservation.

No counter wraps/resets. Reserve requires G and V at most `U-2`, reserving two
increments for reserve and final/close. Claim over an active capsule requires
G at most `U-2` (claim plus terminal close); over an empty head it requires
G at most `U-3` (claim plus reserve plus terminal close). A terminal final/close
is permitted with G/V at most `U-1`; it never requires another increment to
become readable. If a bounded successor claim cannot preserve closing headroom,
creation remains unavailable; no counter reset or silent capsule abandonment.
These checks apply atomically, including raw conformance contenders.

Expose terminal cancellation as the new closed `creation_cancelled` refusal:
native `{:error,:creation_cancelled}` in its existing mode, remote admission
status `refused`, reason `creation_cancelled`, disposition `no_activation`, no
session ID. It is not mapped to `store_unavailable`. An identical later authored
command point-reads its cancelled capsule and compares original normalized
authored presence/sections/tool order/alias before returning cancellation, with
zero preparation/catalog/default work. Changed input returns command conflict.
Native implicit replay compares supplied original options against retained
capture before reconstructing F; complete-genesis replay compares exact genesis.
Neither regenerates cancelled captures from current defaults. Both generation
manifests/closed schemas and literal independent Node/replay readers must add
and prove this reason and its no-session/no-activation correlation. Runtime
command normalization/lookup must retain the cancellation outcome, not collapse
it to absence, unavailable or an ordinary successful create result.

Known final terminal history and capsule state must agree before any active
release. Exact final/close races have two outcomes: F wins and close returns
created history, or close wins and every F returns durable cancellation. No
third stale receipt authorizes activation. Store queue/transport actors remain
Store/host-owned; Caller DOWN, joined carrier, an absent read or elapsed grace
does not retract their messages.

#### Optional bounded recovery read

Propose adapter `creation_recovery(reference, request)` and Core wrapper
`Store.creation_recovery(store, request)`, both arity two. It is an optional
capability; absent callback, exception, lost reply, malformed response or
inconsistent identity yields `:unavailable`. Missing capability refuses
authored **and native fresh creation**, with no synchronous/unreserved fallback.

Request keys are exactly `runtime_id,command_id`: command_id=nil selects the
one active capsule, valid X selects only that command. Result is
`{:ok,%{version: 1,runtime_id: R,head: head,command: capsule_or_nil}}` or
`:unavailable`; malformed request is `{:error,:invalid_creation_recovery}`.
The complete head and at most one capsule are observed atomically. Head absent
uses the initial zero head; requested command absence uses nil. Neither
observation cancels a deliverable old request. A nil command means no capsule,
not absence of existing final command history: ADR 0055's bounded historical
provenance/exact runtime-command lookup still runs before deciding X is fresh.
Known current final histories resolve their original complete captured genesis
without manufacturing a reservation or running preparation. Active selection must return its
exact capsule or be unavailable; command selection may return terminal history
for X while head points to another command. There is no enumeration, page,
pending list or caller-provided candidate. A nil active result becomes fresh
eligibility only after matching the successor's committed claim G/S.

Validate the complete closed envelope and its fixed scalar/ID members; normalize
its one genesis with the existing item normalizer and depth-at-most-12/item
limits. Fixed head/capsule envelope nesting does not spend the genesis item's
existing depth budget or expand its admitted depth. Measure the entire normalized
reply's deterministic encoding at at most 1,048,576 bytes. At most one complete
genesis is returned; fixed envelope structure cannot introduce another arbitrary
map/list or unbounded depth.
Before reserve linearization, measure prospective active and both terminal
response forms, including the maximum legal session ID and bounded refusal
member, and refuse before mutation if any exceeds this ceiling. Thus every
admitted capsule remains discoverable, not truncated or silently omitted.
The atomic read carries no public/progress/snapshot/diagnostic candidate bytes;
it cannot repurpose historical creation_provenance as current authority.

#### Finite live and successor episodes

Only the generation claim precedes fresh preparation. The complete-candidate
reservation follows joined successful preparation and precedes the final
permit. There is no unprepared-input reservation or bind-prepared family.
Loss before a reservation permit has no Store-dispatched candidate. Original
actors must still join, and lost claim/owner state still requires the generation
barrier before fresh preparation. Native complete-genesis creates skip Model
preparation but validate their complete candidate and obey the same reserve.

Startup/recovery owns one slot, original monitors and at most one live carrier,
plus at most one bounded recovery reader at a time; readers are fully joined
before mutation carriers. Capture its work cutoff once at start+60,000 ms and
the same startup host cleanup grace used by live creation. No old VM monotonic
cutoff is serialized, translated or reused. This separate episode grants zero
historical activation and never renews an ongoing request's cutoff.

Within one episode allow at most two **fresh** claim-CAS candidates. A live
unknown candidate has at most one further exact presentation after its original
carrier joins, under the same allowance; it cannot become a fresh claim merely
because of absence. A terminal stale CAS permits one current-head reread and
the second fresh candidate. After second stale/unknown, stop unavailable; no
automatic new episode. Count at most four recovery reads: initial head, one
stale-CAS reread, matching post-claim head/capsule and post-terminal head. At
most one close binding and its one further exact resolution are admitted.
Unavailable reads do not loop. Failure keeps Control alive and creation
unavailable, rather than crashing it to trigger an automatic restart loop.
`Runtime.start_link/1` retains its dispatcher-readiness contract; creation
eligibility is a separate gated state, with safe status/stop still usable.
There is no new public recovery API or repeated-create renewal. A later
explicitly host-started replacement, after the old placement/owned cleanup
ended, owns a new finite episode and fresh Control selection. Ordinary
supervised replacement after a genuine Control failure likewise observes its
local original join. Neither activates or recaptures historical commands.

On a matching post-claim active capsule, select close of its original F, not
fresh final creation or preparation. If old F already committed, return exact
created history. If close wins, return retained cancellation. Changed defaults,
catalogs, aliases or rendering collisions cannot modify retained authored bytes
or command X. On matching post-claim nil active, late old-generation reserve is
permanently stale and fresh creation may begin. Historical command lookup uses
the exact command selector and original capture; it performs zero preparation.
An X whose reservation never linearized may be prepared again only after the
completed barrier proves its old reserve delivery permanently ineligible. Its
new generation uses a distinct reservation ID. Never re-present a changed B
under an old reservation ID, or changed F under a permitted/retained X. An
already-retained command/reservation/final binding remains immutable. The
barrier cannot recover bytes that were never durable; it proves that their old
delivery cannot enter, not that a transient absence cancelled them.

Live creation retains its original 60,000 ms and single captured cleanup episode
for reads/preparation/reserve/final/exact resolution; phase changes add none.
Each reserve/final/close binding permits one presentation plus the existing
one further exact unknown resolution, never concurrent carriers or a retry
loop. Count at most three recovery reads for that live request: initial command,
one matching head/capsule before close if resolution requires it, and one
post-terminal head, alongside ADR 0055's existing bounded capture reads. Every
owned reader is joined before the next carrier. Stop after possible
reserve/final dispatch may select only exact
non-activating resolution/close during the remaining work or already captured
cleanup allowance. If closure or original cleanup cannot be proved by cutoff,
retain the fence and return no successful cleanup/activation. Runtime shutdown
may end its actors while durable unresolved custody remains for successor;
it must not acknowledge that Store was cancelled.

OwnerLane keeps the original immutable fence before every permit. Its normal
exact-only rule is amended solely for creation: after positively ended old
owner and new placement/selection, the claim CAS can supersede old unlinearized
claim/reserve; exact close can terminate the retained F binding. No other
session/runtime mutation gains that bypass. Current session owner epoch,
post-commit authority and executor fencing remain separate.

| Loss point | Required durable disposition and zero-activation rule |
| --- | --- |
| Claim permit, outcome lost | Same live owner exact-resolves. After its end, successor fresh selection uses bounded current-head CAS; both old-first/new-first orders are checked. No preparation before matching claim/read. |
| Preparation before reserve permit | Original work joins; no candidate dispatched. Successor claim makes old-owner reserve inadmissible before any fresh preparation. |
| Reserve permit, not yet visible | Old reserve wins first: complete B is discoverable and preserved by claim. Successor claim wins first: all old reserve is permanently stale. Absence alone proves neither. |
| Reserve durable, final unpermitted | Stop/recovery closes original F atomically; no new final permit or activation. |
| Final permitted, outcome lost | Only exact B/F can resolve. Close races the delayed original F atomically; retain created or cancelled history and never activate after loss. |
| Final committed, reply lost or owner replaced | Known original bytes return created history before eligibility; no new session, preparation or historical activation. |
| Close permit/reply lost | Exact live close resolves; successor claim/read retains B or its terminal history and closes/resolves exact F. No head-flag shortcut. |
| Full root/VM or Store process loss | Durable head/capsule/resolutions replay intact. Host first establishes exclusive placement/prior owner ended. Store unavailable means creation unavailable; no volatile or default reconstruction fallback. |

<a id="technical-adr-0059-impact"></a>
### Scope and qualification

Concept: [Alternatives, compatibility and rollback](0059-responsive-creation-transactions.md#concept-adr-0059-impact).

An alternative amendment could confine responsiveness to preparation and
exclude synchronous mutation/resolution waits. Held Store calls would then
delay Control intake up to adapter timeouts, or indefinitely for a callback
that does not honor a bound. Existing Local permits a 30,000 ms wait for each
call, including the further exact presentation. Overlap no-Store refusal and
stop/status-through-terminal proof would have to be narrowed explicitly.
This proposal selects the carrier exception and Store-owned custody instead
and preserves those accepted intake outcomes. Host-owned durable custody is a
viable alternative only with a new durable host retain/recover/settle port and
an atomic delivery barrier. It must retain complete B before each permit,
recover it after whole VM loss, and prove every old queue/retry path permanently
retired before declaring clean. Missing host capsule or delivery proof keeps
creation unavailable. A root-owned table alone covers Control loss, not root/VM
loss. No smaller generic mechanism is established by naming a worker, relying
on Local queue order, or writing a fictitious session journal.

Implementation scope after acceptance includes Control/startup slot and
selection state, OwnerLane admission/outcome mechanics and a private owned
carrier using existing worker/group custody; Core Store constructors/closed
validators/query/receipt/scopes; Store.Transitions' catalogue and all declared
fault phases; Local atomic state, canonical log/replay and current-format
restore/Audit. Every adapter must implement the new mutations and optional
recovery capability before fresh creation is available. No direct/native new
session path may bypass reservation. A private module is justified only by
custody, not a reusable transaction framework. Current v3 genesis, original
final command identity/bytes, preparation callback, protocol result envelopes
and occupied `creation_in_progress` remain. Review generation/client bindings
for the actual changed semantics; no pending DTO is made public.

The new current persistent format retains head, complete capsule, claim/reserve/
close identities and exact final terminal bindings. Local replay rejects
inconsistent head/capsule/session/resolution relations, altered bytes, missing
lineage and impossible counters; no fresh defaults fill missing records. Full
current-format backup/restore Audit includes all pending and closed custody
and its command history, not only session genesis or visible result rows.
Format/version validators and exported/imported accounting must change
together. Before 1.0 this is one current format: superseded write/decoder
fallbacks and unreserved unknown-create paths are removed. Existing current
exact known final histories remain historical resolutions under unchanged F,
not migration permission to decode an older Store format. No old-root upgrade
or cross-version rollback guarantee is introduced.

Accepted ADR 0055 bytes are not edited by this proposal. Acceptance would amend
only the specified carrier, creation recovery and eligibility semantics; its
grammar/capture/one-slot/live bounds remain. ADR 0008 host placement, session
owner succession, ADR 0006's three outcomes/exact binding and ADR 0051 complete
current restore remain. No other Proposed pair is activated.

Focused proof must exercise actual native Control and Store calls with retained
original actors, not a synchronous helper tested in isolation:

- Hold the original transaction before linearization, after actual commit but
  before reply, and during exact unknown resolution. In each phase require
  serviceable stop/status, all three overlap dispositions, zero overlap Store
  calls/preparation/waiters, unchanged slot/canonical proposal/cutoffs, and no
  second carrier while the first is live.
- In each held phase exercise both native create routes with different command,
  identical command/binding and changed complete-genesis inputs. Require the
  specified native busy result and zero Store freshness/provenance/OwnerLane
  calls, reconstructions or carriers. An exact-binding native retry must not
  reach OwnerLane's ordinarily permitted synchronous presentation. Keep authored
  same-ID changed-input conflict distinct. After slot release, verify native
  creation/replay retains its result modes while every fresh direct/native
  first create without exact reservation is refused.
- Before permit, lose caller/Control/carrier and prove no mutation dispatch,
  exact original joins and no activation. After permit, lose each actor while
  the actual Store call is held; require original-ID unknown, retained binding
  and no replacement genesis. Release the Store and observe actual disposition,
  including a commit after carrier loss. DOWN must not prove rollback.
- After actual durable commit, hold terminal delivery/activation, then stop or
  expire the original invocation. Require no activation from late/stale
  completion, unchanged historical result and exact replay with preparation
  count zero. Check Control incarnation, monitor/permit identities and changed
  request conflicts independently.
- Exercise blocked preparation cleanup, carrier cleanup/forced retirement,
  original deadline near phase changes and missing result/monitor evidence.
  Neither phase transition nor resolution gains a fresh 60,000 ms or grace.
  Failed/unproved cleanup keeps admission unavailable and never returns
  successful creation.
- While the slot is held, repeatedly present every Store-dependent intake row
  above, including both lookup shapes and effect_intents. Require its exact
  existing unavailable result, zero Store calls, zero read workers/guardians,
  zero retained replies and no queue/capacity growth, with stop/status and ready
  session routes serviceable. Repeat during a healthy Store preparation hold
  to prove the documented occupied policy rather than an accidental outage.
- While occupied, present an actual unrelated session provider-dispatch proof
  request and valid post-commit receipt. Require existing provider proof refusal
  with no permit/reader or spent addition; require post_commit acknowledgement,
  unchanged retained spent map and no settlement read. After slot release,
  prove the ordinary Store-backed proof/retirement behavior remains. Do not
  replace the committed-row proof with a caller or cache assertion.
- Preserve complete creation grammar/capture/alias/version/preflight tests,
  exact unknown replay/restart, native unchecked-candidate refusal and both
  foreground/daemon independent-client obligations from ADR 0055. Run focused
  conformance on both supported pairs before integration; final complete checks
  remain required under the existing verification contract.

- Lose the first claim before/after commit and race both original/successor CAS
  orders with the exact two-candidate/read bounds. Prove no live placement is
  stolen and a historical successful claim never grants current authority.
- Lose original reserve permit before linearization through Control/root/VM
  loss. Hold its actual deliverable Store call while successor claims: check
  both orders, complete B recovery or permanent old-generation rejection,
  and no fresh preparation from an absence before that barrier.
- Race actual delayed final F against atomic close in both orders. Require
  original full bytes/digest persisted with created or cancelled terminal
  resolution, active release only in that same commit, exact late repeats,
  no reopening/second session and zero historical activation. Unknown close
  must survive another loss and resolve through intact custody.
- Reject wrong R/X/selection/generation/reservation version, equal digest with
  changed bytes, malformed caps/conditional fields and maximum reply/headroom
edges before reservation. Test the optional callback absent/unavailable
  path with no native fallback. Preserve native result envelopes.
- Exercise current-format Store restart and complete backup/restore with
  active, created and cancelled capsules plus exact known pre-existing final
  histories. Verify full lineage and unchanged original authored captures
  after defaults/catalog changes; source inspection is not this proof.

No test, VM, parser/import, formatter, compiler, check, network retrieval or Git
mutation establishes those proofs in this draft. Source inspection establishes
the synchronous wait and proposal feasibility only. Before 1.0
there is no superseded worker path or decoder fallback. A rollback stops new
affected creates, joins their original runtime-owned actors and retains
exact uncertain bindings/current custody histories. A build lacking this
current format must refuse opening it, not erase/import around reservations.
Rollback cannot erase a possible Store commit, imply cancellation from actor
joins or make synchronous Control serviceability a qualified substitute.
