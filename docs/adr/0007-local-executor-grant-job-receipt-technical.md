# 0007: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Local executor grant, job, and receipt](0007-local-executor-grant-job-receipt.md#concept).

<a id="technical-adr-0007-context"></a>
## Why an Enumerated Field List Is the Wrong Contract

Concept: [Context](0007-local-executor-grant-job-receipt.md#concept-adr-0007-context).

The `M1` plan names seven things an executor validates: audience, operation,
attempt, digest, lease, expiry, and fence. The vision requires those and also
`tool_id`, `tool_version`, and the effect class. A grant satisfying the plan
therefore satisfies less than the vision requires, and the gap is invisible
because both documents read as complete lists.

That gap propagates. A test written from the plan enumerates the plan's seven,
passes, and is counted as evidence that the boundary validates its bindings. The
missing three are never refused because they were never mentioned, and nothing in
the chain from plan to gate to test can notice, because every link transcribed
the same list.

Restating a set in three places is the mechanism. Each restatement can drift, and
none of them is authoritative, so the version a reader checks against depends on
which document they opened. One structural definition removes the possibility:
there is nothing to drift from.

The second failure is subtler and is the one a presence check hides. Consider a
grant for operation `op-1`, attempt 2, addressed to executor `alpha`, with
`fence: 7`. Now hand the executor that same grant while it is `beta`, or while
the attempt is 3, or while the fence has advanced to 8. Every field is present
and well-formed. The grant is for a different situation, and an executor that
checks presence runs the effect.

That is not a hypothetical weakness — it is the exact class the fence exists to
stop. A fence that is validated for presence rather than for value is a field in
a struct, not a fence.

<a id="technical-adr-0007-decision"></a>
## Exact Bindings, Refusal Rules, and Corpus Derivation

Concept: [Decision](0007-local-executor-grant-job-receipt.md#concept-adr-0007-decision).

The required-binding schema is one structural definition in code. It is the sole
source for the executor's validation and generated mutation corpus. Its
completeness has a separate oracle: conformance asserts that its keys equal the
closed ten-binding set in this decision, so an implementation cannot
omit a binding and then derive a self-consistent but incomplete test suite from
the same omission.

| Binding | Validated against |
| --- | --- |
| `operation_id` | The operation the executor was asked to run |
| `attempt` | The current attempt for that operation; a previous attempt is refused |
| `canonical_request_digest` | The digest recorded for this job request; recomputed and compared, never trusted from the grant |
| `tool_id` | The tool actually being invoked |
| `tool_version` | The version of that tool's definition |
| `effect_class` | Exact equality with the class the tool declares for this job; `M1` defines no strength ordering |
| `workspace_lease` | The lease the executor holds for that workspace |
| `executor_audience` | This executor's own identity; another executor's grant is refused |
| `expiry` | Wall clock at validation; an expired grant is refused |
| `fencing_token` | The current fence; a stale fence is refused |

`optional bounded policy context` is carried and retained but is not
interpreted — Loopex transports host policy evidence without reading a host's
user, role, or approval semantics.

Only an explicit host-policy `allow` decision may issue the grant. The
trusted-local reference host may deliberately use the vision's documented
`AllowAll` policy for a trusted workspace, which is still a host decision with a
visible policy boundary. Loopex, the model, a tool declaration, an interaction
response, context, metadata, or ordinary client input cannot mint, select, or
widen authority.

Validation is fail-closed in both directions. A missing binding is refused, and a
present binding whose value does not match what the executor independently knows
is refused identically. The executor never derives the expected value *from the
grant*; it compares the grant against state it already holds. A binding that has
no independent source at the executor cannot be validated and does not belong in
the schema.

The digest binds the chain. The host grant, the durable operation attempt, the
`JobRequest`, and the retained receipt all carry one
`canonical_request_digest` semantic. The coordinator computes and journals it
using the protocol-versioned canonicalization. At the final executor boundary,
the executor independently applies that same canonicalization to the immutable
semantic `JobRequest` fields, compares the result with the recorded and granted
value, and refuses any mismatch. The receipt echoes the value the executor
verified. There is one digest identity, not one physical computation.

Validation happens after queueing at the executor's final serialized pre-start
boundary. The executor compares all bindings, checks expiry and the current
fence, confirms that it still holds the named workspace lease, and only then
starts the effect. Expiry grants authority to start, not to outlive the
workspace lease. The lease remains held for the whole job; loss invokes the
vision's cancellation, cleanup, bounded-output, and retained-evidence path and
never becomes silent success.

Completeness and behavior use separate checks:

1. Assert independently that the implementation schema equals this ADR's closed
   set of ten required bindings.
2. Construct one valid baseline and prove it is admitted at the final pre-start
   boundary.
3. Enumerate the implementation schema's required bindings.
4. For each one, construct an otherwise-valid grant with that single binding
   absent and assert the exact missing-binding refusal reason.
5. For each one, construct an otherwise-valid grant with that single binding
   altered to a present, well-formed, wrong value — a different executor's
   audience, the previous attempt, another request's digest, a superseded fence,
   an expiry in the past, a different effect class, an older tool version.
6. Assert each is individually refused, and assert the refusal names that
   binding, so two guards cannot mask each other by both firing.
7. Assert separately for the missing and wrong-value corpora that each set of
   covered bindings **equals** the set the schema requires. Not a subset. A
   binding added to the schema without a corresponding case fails this
   assertion.

Step 1 is the completeness boundary: deriving a corpus from the implementation
alone cannot detect a field omitted from that implementation. Steps 4 through 7
make every implemented binding test-sensitive without manually duplicating the
implementation list.

Wrong values are used rather than missing ones because a missing value is the
easy case: it fails almost any implementation. A present, well-formed, wrong
value is what distinguishes a validator from a shape check.

These ten bindings are only the grant-binding subset. Implementations still
carry and validate the vision's complete `JobRequest`, executor event identity,
terminal receipt, and solicited reconciliation tuples, including job, session,
run, turn, tool-call, origin session/executor epoch, executor identity,
reconciliation query, and output-policy fields where that contract requires
them. This ADR narrows no field outside the grant.

<a id="technical-adr-0007-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0007-local-executor-grant-job-receipt.md#concept-adr-0007-alternatives).

**Opaque reference plus host verifier.** Loopex carries a reference; the host
verifies. This is the eventual shape, because a real host issues grants Loopex
must not interpret. In `M1` there is no host, so the verifier is a fake, and the
only fake that lets the milestone proceed is one that allows. A boundary whose
purpose is refusal, tested against a verifier that never refuses, produces
evidence of nothing. It becomes correct as soon as a host policy port has an
implementation to verify against.

**Signed portable grants.** Cryptographic authenticity so a grant survives
leaving the trusted VM. `M1` has one machine, one caller, and an in-VM executor,
so the grant never crosses a boundary a signature would protect. Adding it now
would mean writing key management, rotation, and verification for a threat model
`M1`'s non-goals exclude, and the security claim would still rest on the
in-process path being trusted. It is the right decision at the first isolated or
remote hand.

**Presence-only validation.** Rejected in the context section: a grant with every
field present and the wrong audience, attempt, or fence passes it.

**Ad-hoc per-binding checks with no schema.** Each binding validated where it
happens to be convenient. This is what produces the drift the decision closes;
coverage becomes unknowable without reading every call site, and the equality
assertion has nothing to assert against.

<a id="technical-adr-0007-consequences"></a>
## Operational Consequences

Concept: [Consequences](0007-local-executor-grant-job-receipt.md#concept-adr-0007-consequences).

Adding a binding is a four-part change: decision, schema, validation, and the
derived missing/wrong-value corpus. The independent equality assertion makes the
decision update visible instead of letting the schema certify itself. This is
friction on purpose, and it is small — two mechanical cases per binding.

The security claim `M1` may make is narrow and must stay narrow in every
document: the executor refuses a grant whose bindings do not match. It is not a
claim about forgery, tampering, or transport, and a document that implies
otherwise is a defect regardless of the code being correct.

Validation cost is a fixed comparison per binding, once per effect, against
values the executor already holds. It is not on any hot path that matters.

The retained receipt carries the same verified digest as the grant and the
attempt, so reconciliation after a restart compares one digest identity. The
executor-side recomputation is deliberate conformance evidence for that identity,
not a competing canonicalization.

<a id="technical-adr-0007-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0007-local-executor-grant-job-receipt.md#concept-adr-0007-compatibility).

No grant is persisted across a version boundary and none is published, so there
is no migration. Receipts retained by `M1` stay bound to `M1`'s record.

Adopting a host's real grant format later is an adapter at the edge plus a schema
change, which is the ordinary cost of having designed against a Loopex-shaped
structure while no host existed.

Rollback is removing the executor boundary while no tool depends on it. After a
tool ships, changing a required binding is a successor decision rather than an
edit, because the binding set is what the corpus asserts equality against.

No public compatibility claim is made. The executor protocol carries a
conformance suite so a later milestone can make one with vectors and independent
implementations.
