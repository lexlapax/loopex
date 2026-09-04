# 0020: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Durable interaction lifecycle and host-policy authority](0020-durable-interaction-lifecycle-and-host-policy-authority.md#concept).

<a id="technical-adr-0020-context"></a>
## Missing Durable Decision Point

Concept: [Context](0020-durable-interaction-lifecycle-and-host-policy-authority.md#concept-adr-0020-context).

ADR 0009's policy callback already returns allow, deny, or a bounded defer
request. M2's locked one-shot `Loopex.Policy.decide/2` projection maps defer to
`{:deny, :interaction_unsupported}`. M4 preserves that projection and adds the
durable evaluator that can admit the existing defer branch. All state
transitions remain session commands under the one serial owner. The app-server
projects state and submits answers; it is never the interaction store or policy
authority.

<a id="technical-adr-0020-decision"></a>
## Exact State and Race Contract

Concept: [Decision](0020-durable-interaction-lifecycle-and-host-policy-authority.md#concept-adr-0020-decision).

### State

An interaction moves through `pending` to exactly one of `answered`, `denied`,
`expired`, or `cancelled`. `answered` means answer evidence committed and policy
resolution is owed; it does not imply `allowed`. The sibling policy-decision
record holds `allowed` or `denied`, and only `allowed` can lead to a grant.

The record contains bounded plain data: interaction, session, run, turn, and
tool-call identities; the canonical policy request and digest; the validated
choice request and digest; created and effective-expiry instants; status; and,
after response, command ID,
answer bytes/digest, and admission sequence. Limit, accounting, grant, executor
identity, and private policy state remain sibling records owned by their existing
contracts.

### Policy evaluation and bounded answer shape

`Loopex.Policy.decide/2` retains M2's fail-closed result for every defer. M4 adds
`Loopex.Policy.evaluate/2` around the same host `module.decide/1` callback. The
new evaluator validates ADR 0009's existing return algebra without collapsing a
valid defer. Initial evaluation receives ADR 0009's exact policy request.
Resumed evaluation receives those original fields byte-identically plus exactly
one core-created `:interaction_response` member. All callback-map keys are the
fixed atom keys the accepted M2 behavior already uses; no atom comes from
protocol input. No second callback or callback
arity is introduced.

M4's admitted `interaction_request` is the smallest proven question family:
`kind` is exactly `choice`; `prompt` is non-empty UTF-8 of at most 2 KiB;
`choices` contains one to eight entries with a unique 1–64 byte binary `id` and
a non-empty UTF-8 `label` of at most 256 bytes; and `expires_in_ms` is an integer
from 1 through 600,000. An optional bounded host `decision_ref` follows ADR
0009's opaque-reference bound and is retained privately, never projected. The
effective expiry is the earlier of the requested duration from committed
creation and the run deadline. A malformed return resolves to
`policy_unavailable` without creating an interaction.

The core-created response member contains the retained `:interaction_id`, the
exact validated interaction request, `answer = %{choice_id: offered_id}`,
and the SHA-256 answer digest. The runtime validates the offered ID before
response admission. It journals distinct `policy_request_digest`,
`interaction_request_digest`, and `answer_digest` values; none is an executor
`canonical_request_digest`. The host callback may interpret the offered choice,
but the runtime never maps a choice directly to a grant.

Policy implementation selection is a required trusted launch/composition
argument carrying a bounded plain policy identity and revision beside the
process-local module. The interaction retains that identity, never the module
term. A missing or mismatched binding after restart remains suspended and
dispatches nothing. The stdio request algebra contains no policy selector,
policy context, grant, or result field; an unknown `policy` member is refused and
never converted to an atom or module reference.

### Transactions

The transaction that accepts `defer` commits the pending interaction and outbox
event together. Response admission compares session owner epoch, journal version,
pending interaction identity, and command binding, then commits the answer and
public admission atomically. Policy resolution calls `evaluate/2` with the
retained original request plus the core-created response member. It commits the
terminal policy decision and, only for allow, commits the policy resolution,
bounded grant binding, and executor intent together before dispatch. Denial
commits and dispatches nothing. Another defer resolves the answered round and
atomically creates a fresh interaction identity.

Expiry, abort, and deadline are ordinary competing commands/timers ordered at
the journal. The first eligible committed transition wins. A later response is
stale and cannot reopen the record. If deadline cleanup truth is insufficient,
ADR 0010's `outcome_unknown` wins over a clean bound claim.

### Recovery

Owner succession scans for `pending` and `answered` interactions. `pending`
re-publishes from the durable outbox as needed. `answered` re-enters policy
evaluation using the retained exact bytes, three distinct digests, and matching
policy identity/revision. A policy call that may have completed without a
committed result is retried only because policy evaluation is non-authorizing
until its result and any grant/intent commit; an executor effect is never blindly
retried.

<a id="technical-adr-0020-consequences"></a>
## Evidence Consequences

Concept: [Consequences](0020-durable-interaction-lifecycle-and-host-policy-authority.md#concept-adr-0020-consequences).

Conformance injects failure before and after interaction commit, answer
admission, policy result, grant/intent commit, and publication. It covers
restart, identical and conflicting replay, wrong-session and wrong-run answers,
absence, expiry, repeated defer, abort and deadline races, malformed policy
output, timeout, and policy crash. A negative authority property varies client
content, request IDs, metadata, event order, and answer shape and proves none can
mint or widen a grant without a committed host-policy allow.

The inherited M2 case continues to prove that `Loopex.Policy.decide/2` refuses a
defer. M4 separately proves `evaluate/2`, byte-identical original request replay,
the exact response-member construction, a wire policy-selection refusal,
malformed defer and answer negatives, restart binding mismatch, and that only
the configured policy's committed allow creates the grant and intent.

<a id="technical-adr-0020-compatibility"></a>
## Format and Rollback

Concept: [Compatibility, migration, and rollback](0020-durable-interaction-lifecycle-and-host-policy-authority.md#concept-adr-0020-compatibility).

The Store catalogue adds versioned private interaction and policy-resolution
records plus public requested/resolved/expired/cancelled events. Rollback before
closure discards M4 evidence roots and removes those record readers and writers
together. No in-place downgrade claim is made. Packaging and publication remain
outside this decision.
