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
source for the executor's validation, for the mutation corpus, and for any
documentation that needs to name a binding.

| Binding | Validated against |
| --- | --- |
| `operation_id` | The operation the executor was asked to run |
| `attempt` | The current attempt for that operation; a previous attempt is refused |
| `canonical_request_digest` | The digest recorded for this job request; recomputed and compared, never trusted from the grant |
| `tool_id` | The tool actually being invoked |
| `tool_version` | The version of that tool's definition |
| `effect_class` | The class the tool declares; a grant for a weaker class does not authorize a stronger effect |
| `workspace_lease` | The lease the executor holds for that workspace |
| `executor_audience` | This executor's own identity; another executor's grant is refused |
| `expiry` | Wall clock at validation; an expired grant is refused |
| `fencing_token` | The current fence; a stale fence is refused |

`optional bounded policy context` is carried and retained but is not
interpreted — Loopex transports host policy evidence without reading a host's
user, role, or approval semantics.

Validation is fail-closed in both directions. A missing binding is refused, and a
present binding whose value does not match what the executor independently knows
is refused identically. The executor never derives the expected value *from the
grant*; it compares the grant against state it already holds. A binding that has
no independent source at the executor cannot be validated and does not belong in
the schema.

The digest binds the chain. The host grant, the durable operation attempt, the
`JobRequest`, and the retained receipt all carry one recorded
`canonical_request_digest`. It is computed once and compared everywhere; there is
no second independently computed digest that can drift at the boundary, and any
mismatch fails closed.

The mutation corpus is derived, not written:

1. Enumerate the schema's required bindings.
2. For each one, construct an otherwise-valid grant with that single binding
   altered to a present, well-formed, wrong value — a different executor's
   audience, the previous attempt, another request's digest, a superseded fence,
   an expiry in the past, a weaker effect class, an older tool version.
3. Assert each is individually refused, and assert the refusal names that
   binding, so two guards cannot mask each other by both firing.
4. Assert the set of bindings the corpus covers **equals** the set the schema
   requires. Not a subset. A binding added to the schema without a corresponding
   case fails this assertion.

Step 4 is the load-bearing one. Steps 1 through 3 are what a careful author
writes anyway; step 4 is what makes the coverage a property of the code rather
than of the author's diligence, and it is what turns the plan's original
omission into a failing build instead of a review finding.

Wrong values are used rather than missing ones because a missing value is the
easy case: it fails almost any implementation. A present, well-formed, wrong
value is what distinguishes a validator from a shape check.

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

Adding a binding is a three-part change: schema, validation, corpus case. The
equality assertion makes the third mandatory. This is friction on purpose, and it
is small — one case per binding, and the case is mechanical.

The security claim `M1` may make is narrow and must stay narrow in every
document: the executor refuses a grant whose bindings do not match. It is not a
claim about forgery, tampering, or transport, and a document that implies
otherwise is a defect regardless of the code being correct.

Validation cost is a fixed comparison per binding, once per effect, against
values the executor already holds. It is not on any hot path that matters.

The retained receipt carries the same digest as the grant and the attempt, so
reconciliation after a restart compares one recorded value rather than
recomputing at a boundary where recomputation could disagree.

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
