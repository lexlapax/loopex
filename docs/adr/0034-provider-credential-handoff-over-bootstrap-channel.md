<a id="concept"></a>
## Concept

Technical depth: [Credential handoff mechanics](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-19
- **Decision owner:** Maintainer
- **Supersedes:** nothing; refines where ADR 0019's credential-bearing
  invocation reads its credential from
- **Prerequisite for:** M5 Outcome 6

<a id="concept-adr-0034-decision"></a>
### Context and Decision

ADR 0019 gave the reference provider adapter a private, one-invocation child
process: a namespace of its own, a nonce, a private Unix-domain socket, a
build manifest digest the child must echo before it is trusted, and an
environment scrubbed down to a fixed `PATH` so the child inherits no ambient
secret. The credential already crosses that private channel as its own frame
rather than through the child's environment.

One thing was left on the process-wide plane. The adapter resolves the
credential by reading the operating-system environment variable
`LOOPEX_PROVIDER_API_KEY` from the parent VM, inside the call, at the moment
it is about to send the frame. The parent VM's environment is a single global
slot, so the credential of whichever invocation wrote it last is the
credential every concurrent invocation sends. That has two costs. It is a
weaker property than the rest of the plane: a secret that has to sit in a
process-wide slot for the duration of every call is reachable by anything in
the VM that can read the environment, and it is exactly the kind of ambient
authority the runtime refuses everywhere else. And it forces serialisation:
the twelve heavy `loopex_llm_reqllm` test modules each install their own
canary in that slot, so two of them running at once would hand each other's
canary to each other's child. The
[verification companion](../developer/verification-technical.md#technical-verification-speed)
measured the result at M4 closure — that application is the critical path of
the fast check, 96% of its time sits in those twelve modules, and no further
test change shortens the check while the slot is shared.

**Decide that the credential is a per-invocation input, delivered on the
child's private channel and never resident in any process-wide slot.** The
host supplies the credential to the adapter with the call, as an opaque
reference it owns; the adapter resolves that reference to bytes only inside
the minimal sender process that writes the credential frame, and only after
the child has proved its nonce, codec version and build manifest digest. The
adapter reads no environment variable for the credential. Nothing else
changes about where the credential may go: it is never in the child's
environment, never in argv, never in the journal, a public event, a snapshot,
a progress item or a diagnostic, never in a process state, a message, an exit
reason or a crash report, and never written to a file. The operator still
names the credential once, to the host, through the same environment variable;
the host reads it where it composes the runtime and holds a reference from
then on, so the variable is a configuration input rather than a live transport
for every call.

**Alternatives rejected.** Keeping the environment variable and buying the
speed by sharding the provider suite across test VMs was rejected: it is
cheaper for speed alone and buys nothing for the credential plane, and it
answers a defect in the product with an arrangement of the tests. A credential
file in the invocation's namespace was rejected because it makes the secret
observable to anything that can read the directory, adds a removal step whose
failure is a leak, and survives a crash that the channel does not. Passing an
already-open file descriptor to the child over the socket was rejected because
it adds a platform-specific mechanism to a channel that already carries bounded
frames, without removing a single place the credential can be observed. Widening
the existing bootstrap frame to carry the credential alongside the manifest
digest was rejected because the child must prove its identity before it is
handed a secret, and that frame is sent before the child has proved anything.

**Evidence its acceptance requires.** This is a trust claim, so its class is
negative tests plus a security review, with a real-provider proof for the path
the release check already runs. Every credential-plane negative that M0 to M2
established is re-pointed at the new handoff and must hold with its assertion
unchanged in meaning; the parent VM's environment is proved empty of the
credential before, during and after a call; two invocations running at once
are proved unable to observe each other's credential; and a named reviewer
reads the handoff — resolution point, frame ordering, failure paths and every
place a value could be retained — and records the reading with the milestone.
The real-provider lane in `bash scripts/check-release.sh` proves the path
still reaches a real provider. The concurrency result is a measurement
recorded beside the M4-closure baseline, not a pass condition.

Technical depth: [Contract and evidence](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-adr-0034-decision).

<a id="concept-adr-0034-consequences"></a>
### Consequences, Compatibility and Rollback

The credential plane gets the property the rest of ADR 0019's design already
has: the secret exists in the parent only inside one short-lived process that
does nothing but send it, and in the child that needs it. Two invocations in
one VM become independent, so the twelve provider test modules can run
concurrently and the fast check stops being pinned by that application. Host
composition gains one explicit input: a host that starts a runtime with this
adapter says which credential reference the adapter is to use, instead of
relying on the VM's environment being right at call time. A host that supplies
no reference gets the adapter's ordinary refusal to dispatch, which is what a
missing environment variable produces today.

Nothing public changes. This is adapter-internal: no Model callback, no public
event, snapshot, artifact, wire method or protocol generation, no durable
record, and no change to what the child may receive, from whom, or when. The
credential-size bound and the refusal behaviour ADR 0019 fixed stay as they
are. Rollback is reverting the adapter change; no data, root or protocol
depends on which mechanism delivered a credential to a process that has since
exited.

Technical depth: [Compatibility mechanics](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-adr-0034-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
