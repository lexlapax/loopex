# 0007. Local executor grant, job, and receipt

<a id="concept"></a>
## Concept

Technical depth: [Binding schema and validation mechanics](0007-local-executor-grant-job-receipt-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-21
- **Decision owner:** Maintainer
- **Prerequisite for:** `M1` acceptance, and implementation of its outcome 6

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0007-context"></a>
## Context

`M1` runs one controlled local tool. Before any effect, the executor must
validate what authorizes it. The vision already fixes that an executor validates
audience, operation and attempt, digest, lease, expiry, and fence, and that host
policy alone owns allow, deny, and defer. What is unresolved is the concrete
shape of the thing being validated and how far `M1` claims to have secured it.

The `M1` plan currently answers by listing seven field names in an outcome row.
That is the wrong kind of answer twice over. It omits bindings the vision
requires — `tool_id` and `tool_version`, and the effect class — so a grant
conforming to the plan is not a grant conforming to the vision. And a list in a
plan row is a list a test will transcribe, which makes the test's coverage a
copy of the plan's omission rather than a check on it.

The list also invites the weaker test. Checking that each field is *present*
passes a grant whose audience names a different executor, whose attempt is a
previous attempt, or whose digest is some other request's digest. Every field is
there; the grant still authorizes nothing.

Technical depth: [Why an enumerated field list is the wrong contract](0007-local-executor-grant-job-receipt-technical.md#technical-adr-0007-context).

<a id="concept-adr-0007-decision"></a>
## Decision

- **One required-binding schema, declared once in code.** The set of bindings a
  grant must carry is a single structural definition. The plan does not restate
  it, the gate does not restate it, and tests do not transcribe it.
- **The schema carries every vision-required binding**, including the two the
  current plan omits: `tool_id` and `tool_version`, and the effect class. A
  binding the vision requires and the schema lacks is a defect in the schema.
- **Validation is fail-closed and compares values, not presence.** Each binding
  is checked against what the executor independently knows or was handed: this
  executor's audience, this operation and attempt, this request's digest, this
  workspace lease, the current fence, the wall-clock expiry. A present-but-wrong
  binding is refused exactly like a missing one.
- **The mutation corpus derives from the schema.** Tests enumerate the schema's
  required bindings, alter each present binding independently, and assert that
  every one is individually refused. They also assert that the set of bindings
  covered by the corpus **equals** the set the schema requires, so adding a
  binding without a test fails the suite rather than silently reducing coverage.
- **Trusted-local, with no authenticity claim.** In `M1` the grant is a
  structured value produced and consumed inside one trusted VM. `M1` claims that
  the executor refuses a grant that does not bind correctly. It does **not**
  claim the grant is unforgeable, tamper-evident, or safe to transport, and no
  document may say otherwise.
- **A job and a receipt bind the same digest.** The grant, the durable operation
  attempt, the job request, and the retained receipt all carry one recorded
  `canonical_request_digest`. There is no second independently computed digest
  that can drift, and any mismatch fails closed.

Technical depth: [Exact bindings, refusal rules, and corpus derivation](0007-local-executor-grant-job-receipt-technical.md#technical-adr-0007-decision).

<a id="concept-adr-0007-alternatives"></a>
## Alternatives

**An opaque grant reference plus a fail-closed host verifier** is viable. Loopex
would carry a reference rather than the bindings, and ask the host to verify it
before each effect. It matches the eventual shape most closely, since a real host
issues grants Loopex cannot interpret. It is not recommended for `M1` because
there is no host yet: the verifier would be a fake, and a fake verifier that
always allows proves nothing about a boundary whose entire purpose is refusal.

**Signed portable grants** — cryptographic authenticity so a grant survives
leaving the VM — is unnecessary `M1` scope. `M1` has one machine, one attached
caller, and no remote executor, so a signature would secure a boundary that is
not crossed. It becomes the right decision when a hand runs in OS isolation or on
another host, and it is a successor decision then.

**Validating presence only** is what the current plan's phrasing yields. It is
rejected: a grant with every field present and the wrong audience passes it.

Technical depth: [Alternative analysis](0007-local-executor-grant-job-receipt-technical.md#technical-adr-0007-alternatives).

<a id="concept-adr-0007-consequences"></a>
## Consequences

The grant is a Loopex-shaped structure in `M1`, and adopting a host's real grant
format later is an adapter plus a schema change. That cost is accepted because
the alternative is designing against a host that does not exist.

`M1`'s security claim is deliberately narrow, and every document must keep it
narrow. "The executor refuses a wrong binding" is provable now. "The grant cannot
be forged" is not, and stating it would be the kind of untested claim a gate
cannot catch.

Adding a binding later means adding it to the schema, which fails the equality
assertion until its mutation case exists. That is the intended friction: it makes
an untested binding a build failure rather than a review finding.

Technical depth: [Operational consequences](0007-local-executor-grant-job-receipt-technical.md#technical-adr-0007-consequences).

<a id="concept-adr-0007-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists and no grant is persisted across a version boundary,
so nothing requires migration. Receipts retained by `M1` are bound to `M1`'s
record.

No public compatibility claim is made. The executor protocol carries a
conformance suite so a later milestone can make one with vectors and independent
implementations.

Rollback is removing the executor boundary while no tool depends on it.

Technical depth: [Compatibility and rollback mechanics](0007-local-executor-grant-job-receipt-technical.md#technical-adr-0007-compatibility).

## Links

- [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) — the store
  contract whose fence this grant binds
- [ADR 0003](0003-extension-contract-boundary.md#concept) — the extension and
  distribution boundary this decision does not reopen
- [Vision §6.3](../vision.md#concept) — authority grants and what a grant binds
- [AGENTS.md](../../AGENTS.md) — authority grants, trust boundaries, brains and
  hands
