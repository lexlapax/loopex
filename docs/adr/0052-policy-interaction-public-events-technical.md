<a id="technical-depth"></a>
## Technical depth

Concept: [Policy interaction public events](0052-policy-interaction-public-events.md#concept).

<a id="technical-adr-0052-context"></a>
### Current behavior and amendment scope

Concept: [Purpose](0052-policy-interaction-public-events.md#concept-adr-0052-context).

The inspected source baseline is e327e46c51298d49deee045e3cb03fc9e375dc94.
SessionState.interaction_requested_event/2 emits seven data members.
interaction_resolved_event/4 emits interaction/run/call/resolution, optional
choice and optional reason. The answered interaction already retains the actual
answer command. resolvable?/2 admits allowed/denied only from answered;
expiry/cancel accepts pending or answered. Both transport event builders currently
pass these policy data maps through. The existing /1 and /2 literal schemas
instead name turn_id and make denied answer fields null. These are inspected
source facts, not a claim that a new generation or test has passed.

On acceptance, this pair narrowly amends:

| Authority | Named scope | Preserved boundary |
| --- | --- | --- |
| ADR 0024 Concept decision / Technical exact state and race contract | Requested/terminal native and wire payloads below; terminal answer-command disclosure and exact public cursor relation | Host-policy authority, distinct digests, answer admission, journal races, bounded repeated defer, commit-before-publication |
| ADR 0044 coordinated wire amendment | These payloads in complete foreground loopex.experimental/3 and daemon loopex.experimental/4 manifests | Existing canonical manifest recipe, negotiation and server-specific authority |
| ADR 0049 Concept terminal-run objects / Technical closed terminal schema | Exception to retained-public-event encoding preservation solely for native policy interaction terminal turn and answer_command_id | Run TerminalOutcome, ask JSON, chat event grammar and cleanup semantics |

ADR 0045's model producer, text/choice/decline settlement and question-tool
contract are unchanged. The accepted permission-answer disposition governs the
existing nine-member admission event and ten/twelve-member open views; it does
not already approve this requested/terminal contract. Historical accepted ADR
bytes remain historical authority records; this successor supplies only the
named amendment when accepted. No vision boundary is reversed.

<a id="technical-adr-0052-decision"></a>
### Exact payloads

Concept: [Proposed decision](0052-policy-interaction-public-events.md#concept-adr-0052-decision).

A *payload* is the data map without the existing event envelope. Native envelope
members remain :kind, :event_id, :event_sequence; wire framing keeps its
existing session identity and event kind/identity/sequence. Plain maps only;
extra payload keys and implementation terms refuse. No new event kind or
private journal kind is introduced.

**Scalar domains.**

| Scalar | Native | Wire |
| --- | --- | --- |
| Interaction, run, tool call and admitted answer command | Opaque binary, 1–65536 bytes | Canonical unpadded base64url of those exact bytes |
| Offered/selected choice ID | Opaque binary, 1–64 bytes | Same canonical encoding |
| Turn | Arbitrary positive integer | Canonical positive decimal string; no leading zero, sign, fraction or JSON numeric scalar |
| Effective expiry | Nonnegative uint64 integer | Canonical nonnegative decimal string |
| Prompt | Nonempty valid UTF-8, at most 2048 bytes | Same text |
| Choice label | Nonempty valid UTF-8, at most 256 bytes | Same text |
| Optional existing native reason | Binary within the existing owning-record bound, at most 65536 bytes | Omitted |

Choices contain one through eight plain maps with exactly id and label;
IDs are distinct. Opaque IDs are never required to be UTF-8. Empty reason bytes,
if present in a valid existing native record, are not converted into another
reason. This decision adds no free-form reason to the wire. Existing complete
record/transaction and negotiated frame bounds still apply: valid individual
scalars do not imply their aggregate fits. Encoders check exact complete output
sizes and use the existing bounded transport failure/lifecycle path without
partial publication; they never truncate identities or silently drop required
fields. This proposal introduces no larger bound or new failure outcome.

**Native policy request.**

interaction.requested has exactly these **seven** data members:

    interaction_id, run_id, turn, tool_call_id, prompt, choices, expires_at

Values use the domains above. These are the current native request names;
policy producer, choice kind and pending status are fixed by this exact branch.
A model request uses its separate producer-specific codec. Absence of a producer
in an arbitrary map is insufficient to classify it as policy.

**Native policy terminal.**

Each of interaction.resolved, interaction.expired, interaction.cancelled
has exactly the following **six required** data members, plus the two allowed
conditional members below:

    interaction_id, run_id, turn, tool_call_id, resolution, answer_command_id

Resolution is one of allowed, denied, expired, cancelled, correlated to
kind below. answer_command_id is the actual admitted command or null. It is
never a timer, abort, policy-resolution command or synthesized hash.

| Conditional member | Exact condition |
| --- | --- |
| choice_id | Present and the actual offered selected ID exactly when answer_command_id is non-null; absent exactly when it is null |
| reason | Present exactly when the existing owning resolution record retained a binary reason; otherwise absent. Preserve its bytes; do not synthesize reason for cancellation. |

An allowed/denied native resolution requires a non-null command and present
choice. Expiry/cancel permits either an unanswered absent-choice/null-command
branch or the answered present-choice/non-null-command branch. No mixed pair.
The new required turn and command are derived before the owning transaction
commits, and the complete expected outbox authenticates them on current replay.

**Wire policy request.**

interaction.requested has exactly **ten required** data members:

| Member | Constraint |
| --- | --- |
| interaction_id | Actual opaque identity |
| run_id | Actual opaque identity |
| turn | Actual numbered turn, canonical decimal |
| tool_call_id | Actual opaque identity |
| producer | Literal policy_defer |
| interaction_kind | Literal choice |
| status | Literal pending |
| prompt | Bounded request text |
| choices | Bounded offered choices |
| expires_at | Retained effective expiry, canonical decimal |

The codec adds only the three fixed literals to the exact native request and
encodes bounded scalars. It does not fetch policy, synthesize a question or
create any deadline.

**Wire policy terminal.**

Every terminal branch has exactly **nine required** data members:

    interaction_id, run_id, turn, tool_call_id, producer, interaction_kind,
    status, answer_choice_id, answer_command_id

Producer/kind are the same fixed literals. Native choice_id projects to
answer_choice_id; absent native choice projects to null. Native resolution
projects to the kind-correlated status below. Native reason is excluded.

| Event kind | Native resolution | Wire status | Exact answer pair |
| --- | --- | --- | --- |
| interaction.resolved | allowed | answered | Both actual non-null IDs |
| interaction.resolved | denied | denied | Both actual non-null IDs |
| interaction.expired | expired | expired | Both null before admitted answer; both actual IDs after it |
| interaction.cancelled | cancelled | cancelled | Both null before admitted answer; both actual IDs after it, including repeated-defer replacement |

Answered in a resolved terminal denotes the existing allowed resolution;
answered in interaction.answer_admitted denotes resolution still owed. Event
kind and cursor distinguish them. Neither status alone grants authority.

The approved interaction.answer_admitted remains exactly the same nine names,
producer/kind literals, status answered and both non-null answer IDs, using the
same domains. It is an admission event, never a terminal event. Pending and
answered open views remain their approved ten and twelve members respectively.
No model terminal or text answer is admitted by this policy codec.

<a id="technical-adr-0052-delivery"></a>
### Reducer relations, bounded delivery and activation

Concept: [Delivery and current history](0052-policy-interaction-public-events.md#concept-adr-0052-delivery).

Validate payload shape separately from its relation to prior committed state:

1. The owning private reducer verifies a requested event's current
   run/turn/call tuple. Public prefix reduction requires its exact closed payload
   and an empty interaction slot; it installs the exact pending choice view.
2. Answer admission requires that pending policy view, an identical
   interaction/run/turn/call tuple and an offered choice. Its actual committed
   command/choice pair installs the answered view. No effect dispatch follows
   admission without the existing committed host-policy allow.
3. Allowed/denied terminal events require that exact answered view, complete
   tuple and identical admitted answer pair. Pending→allowed/denied refuses.
4. Expired/cancelled terminal events require the exact pending or answered
   view and tuple. The pending branch requires null command and absent native
   choice; the answered branch requires both exact retained IDs. Terminal
   closure clears the slot at its own event sequence. A terminal with no matching
   open question, altered tuple or fabricated/missing answer refuses.
5. Repeated defer derives old answered cancellation and fresh request in order
   from the same existing owning transaction. The old cancellation preserves its
   answer; every prefix, including the cursor between these two events, is
   independently valid. Existing run/turn/call round counting and three-question
   ceiling remain unchanged.

The sole serial owner derives these fields from retained private interaction and
answer records, commits the complete expected outbox with the existing mutation,
and publishes only after confirmed commit. Unknown commit fences admission,
publication and effect dispatch until the original transaction resolves. Replay
checks the exact expected payload and all cursor prefixes without reading newer
coordinator state or substituting current host defaults. Current prepared
recovery preserves an answered question without dispatch until the owner is
activated with the matching retained policy binding.

Use one shared pure policy projection for foreground and daemon, both exact
native-to-wire and wire validation where consumed. It unifies their existing
separate event builders and independent client contract; no session loop,
actor, host authority type or dependency is added to Core. Independent Node
validation derives its own canonical scalars and exact branch checks, rather
than accepting any map with matching top-level event kind.

Include every policy request/admission/terminal payload and referenced nested
choice union in both complete current manifests. Preserve ADR 0044's closed
seven-member manifest, canonicalization revision, ordered inventories and
independent canonical digest recipe. Serve only complete foreground
loopex.experimental/3 and daemon loopex.experimental/4 after the coordinated
implementation and its proof. Old-only/wrong-server offers refuse before
attachment; mixed offers select only that server's current generation. Clients
verify the exact independently pinned digest before session work and close on
mismatch without downgrade or command replay. Remove superseded served readers,
old turn-ID recipes and mixed status/resolution fallback paths in that change.

No stored event is rewritten or filled in after publication. The current replay
reader must validate the complete expected terminal schema; a root with missing
current outbox captures refuses before activation. This is current-format
validation, not an older-root migration promise. Current restart/replay and
accepted current-format physical restore keep all real answer and unresolved
effect facts. This decision authorizes no snapshot rewind, uncertain-effect
redispatch, journal rewrite, migration helper or cross-version rollback.

<a id="technical-adr-0052-alternatives"></a>
### Alternatives

Concept: [Alternatives and consequences](0052-policy-interaction-public-events.md#concept-adr-0052-alternatives).

The native-vocabulary alternative would define exact seven-member wire request
{interaction_id, run_id, turn, tool_call_id, prompt, choices, expires_at} and
terminal {interaction_id, run_id, turn, tool_call_id, resolution, choice_id,
answer_command_id}. Scalars, kind correlation and nullable answer pairs would
follow the same tables, with reason omitted. It would omit producer/kind/status
and require exact model/policy branch selection plus client translation to the
approved admission/open vocabulary. It still changes native terminal disclosure
and wire schemas; it does not avoid governance or preserve an old-client promise.

Keeping the literal old M4 payload requires a separately approved turn_id
preimage/ownership rule absent from current records and correcting its denied
both-null rule. A transport-local hash would invent public identity; retaining
that rule would erase an admitted answer. An unchanged old schema and current
raw pass-through do not form a valid alternative contract.

<a id="technical-adr-0052-evidence"></a>
### Verification before activation

Concept: [Required proof and acceptance boundary](0052-policy-interaction-public-events.md#concept-adr-0052-evidence).

| Obligation | Required evidence |
| --- | --- |
| Exact codecs and bounds | Literal complete field/key sets, all terminal rows, paired nulls, arbitrary positive turn and opaque-byte limits, canonical decimal/base64 mutations, UTF-8 prompt/label limits, duplicate/oversized choices, wrong kind/producer/status, missing/extra/private members and exact aggregate encoded-size refusal; independent Node vectors agree |
| Answer and cursor truth | Pending→admission→allow/deny, expiry/cancel before and after answer, exact actual command including idempotent/conflicting/late responses, mixed-pair/tuple mismatch negatives and every relevant prefix snapshot/attach/inspection correspondence |
| Current durability | Real current Store history, exact expected outbox and reducer replay, owner loss before/after answer and terminal commit/publication, unresolved commit fencing and recovery with missing/mismatched policy binding; missing current captures refuse before dispatch |
| Repeated defer | Old answer preserved through cancellation before the fresh request in the same transaction, cursor between events valid, no extra question past the existing bound and no executor intent from unanswered/denied states |
| Both transports | Foreground/daemon identical current encoded policy data, malformed native shapes fail without partial frame publication, original bounded queue/connection cleanup, current generation/digest negotiation and old/wrong-server refusal |
| Independent consumer | Actual decoded identity answered once through the public command, real admitted command retained in deny/expiry/cancel terminal history, no mixed-vocabulary fallback, current snapshot/cursor and replay parity |
| Candidate evidence | Focused affected tests on both supported toolchains, required selected wire release lanes, complete documentation checks and independent semantic review of the exact proposal/candidate; retain exact source SHA and all failures |

The original M7 closure matrix and real-path outcomes remain required. This
proposal contains no executed result, test waiver, retry allowance or milestone
closure decision. The maintainer must accept the exact Proposed pair before
implementation depending on its new public data or amendment begins.
