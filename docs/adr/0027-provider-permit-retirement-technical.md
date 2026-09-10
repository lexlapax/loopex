<a id="technical-depth"></a>
## Technical depth

Concept: [Provider permit retirement](0027-provider-permit-retirement.md#concept).

<a id="technical-adr-0027-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0027-provider-permit-retirement.md#concept-adr-0027-decision).

### Retirement predicate

For a session Control keeps its current owner epoch and current eligible
operation/attempt identity. Durable registration updates that identity only
from an acknowledged transaction whose canonical digest matches the intended
attempt-open/settlement. A delayed registration with old epoch/version or a
non-current attempt is rejected before considering the spent set. Version
comparison never trusts caller-supplied evidence without the existing bounded
Store binding check.

Retire a spent worker/reference only after its matching settlement is committed
and the session's authorization domain records it as closed. With no live
attempt the domain permits none. With a successor attempt it permits only that
exact committed attempt; a missing spent-set entry is never sufficient. Domain
retirement on session release retains existing owner-epoch fencing. An attempt
closed only by a run terminal, with no matching committed settlement, does not
satisfy the earlier retirement predicate and remains retained until session
release. Control restart reconstructs the same refusal from durable truth before
issuing any permit. Do not invent a permanent tombstone per historic attempt,
which merely moves the unbounded set.

### Required proof

Use generated histories, a long real attempt sequence and measured retained
state to show O(active sessions + unresolved work). Inject requests after
settlement, after pruning, during successor registration, after Control restart,
and across ownership transfer. Delay the Store check past its bound and mutate
epoch/digest/operation/attempt independently. Removing the current-domain check
must make a locked test fail even when the spent set is empty.

Keep ADR 0018's single allowed not_dispatched retry and ADR 0021's usage-v2
provenance unchanged. If existing durable records cannot establish the predicate,
stop before implementation and amend this proposal; a new journal kind is not
implicitly authorized by this decision.

<a id="technical-adr-0027-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0027-provider-permit-retirement.md#concept-adr-0027-consequences).

No new durable provider record is necessary: use existing attempt-open and
settlement-v2 evidence plus current ownership. Existing readers and journals
keep their semantics. Rollback retains more evidence and preserves the same
fence; it must not reinstate a path that treats a retired identity as fresh.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M3 gate's required paths execute.
