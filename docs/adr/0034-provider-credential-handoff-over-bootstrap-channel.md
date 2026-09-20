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

**Decide that the credential is a per-invocation input, named by an opaque
token and resolved only inside the process that writes it to the child's
private channel.** The host supplies the adapter, with each call, a
*credential token*: an opaque identifier that carries no credential, no
routing and no authority of its own. Behind it the host owns two things the
adapter does not: a **routing registry** that maps a token to a custody
process and holds routing only — never bytes, never anything a secret could be
derived from — and the **custody process** that holds the bytes. The adapter
resolves the token exactly once per invocation, inside the minimal sender
process that writes the credential frame, and only after the child has proved
its nonce, codec version and build manifest digest. The adapter reads no
environment variable for the credential. A call that carries no token is
refused before any child is spawned, which is the refusal a missing
environment variable produces today.

The token replaces a `{module, term}` reference an earlier draft used; the
maintainer decided that on 2026-09-20 and the companion records why. A value
that named the resolving module carried the host's arrangement through every
copy of the adapter's configuration, and a second provider would have widened
the value rather than added a registry row. An opaque token discloses nothing
and stays the same shape however many credentials sit behind it.

**The guardian enforces the deadline, and the resolver is not asked to.** The
custody callback takes no deadline. The guardian already owns the invocation
deadline and already supervises the sender, so it bounds the whole resolution
and kills the sender when the instant is reached. An earlier draft handed the
resolver an absolute instant and relied on it to honour one; that is withdrawn
by the same decision, because it made a safety property depend on code the
adapter does not write, and a custody process that simply blocked would have
hung the invocation past its deadline.

**Losing custody or the registry is a refusal, never a reconstruction.** If
the custody process is gone, the registry has no row, or the registry itself
is gone, resolution answers `:unavailable` and every invocation on that token
refuses the same way until the host recomposes. Nothing rebuilds the secret,
and nothing could: the registry holds no bytes to rebuild it from.

**Exactly one credential-bearing transfer exists in the parent, and this pair
names it.** A host that keeps the bytes and answers a resolver call has to send
them to the process that asked; a contract saying the value is never in a
message could never be implemented alongside one. So the rule is a permission
with a boundary: the custody process's reply to the sender is the one
transfer — bounded, unlogged, never forwarded, never retained after the frame
is written — and it is the same class of act as writing the credential frame,
protected the same way ADR 0019 already protects that sender. The registry
lookup before it carries no credential, so routing adds no second place a
secret can be seen, and the credential-bearing call is excluded from tracing
by ADR 0030's existing redaction class, which the companion names and M5
proves.

**Everywhere else the boundary is where the adapter's claims stop.** Inside it
— the token, the sender, the frame, the child — the adapter proves what it
says: the value is never in the child's environment, in argv, in the journal,
in a public event, a snapshot, a progress item or a diagnostic, in adapter
process state, in any message but that one, in an exit reason, a crash report
or an IO request, and never written to a file. Outside it, custody belongs to the host and the adapter
proves nothing about it beyond the two structural rules it does impose: the
registry holds routing only, and losing custody or the registry answers
`:unavailable` rather than reconstructing anything. This pair therefore states
the reference implementations' custody as their own obligation rather than
claiming a property of every host that might compose a registry.

The operator still names the credential once, through the same environment
variable, and the reference implementations — the CLI, the app-server host and
the M5 daemon — read it exactly once where they compose the runtime and delete
it from the VM's environment in the same step, holding the bytes behind the
resolver from then on. The variable is a configuration input consumed at
composition, not a live transport for every call, and from the moment
composition completes the parent VM's environment carries no credential. M5
Outcome 6's claim is stated at that boundary: a claim that the variable is
never set at all would contradict the way an operator supplies a secret to a
process they start.

One enumeration goes with it. The launcher reads the whole parent environment
on every launch, to clear it name by name from the first spawned image. That
read is deleted outright rather than relocated: the launcher passes a fixed,
closed removal list — the credential and loader names it already removes
unconditionally — so no code path reads the environment to build it, at launch
or anywhere else. Moving the read to composition was considered and withdrawn,
because ADR 0019 constrains the host only *during one launch* and a snapshot
reused across launches would claim an immutability that decision never gave.
What the fixed list keeps is ADR 0019's actual guarantee, that credential and
loader names never reach the first image; what it gives up, and this pair says
so, is clearing unlisted names from one short-lived `/usr/bin/env` image that
acts on none of them, whose child is cleared by `env -i` regardless, and whose
environment block is readable only by the user who can already read the parent
VM's.

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
Carrying the credential bytes in the per-invocation configuration, rather than
a token, was rejected because the bytes would then sit in adapter state,
in the messages that configuration travels in, and in any crash report that
prints it — the retention this decision exists to remove. A single
adapter-level credential set once at composition was rejected because it is
the process-wide slot again one level down: two concurrent invocations with
different credentials could not be independent, which is half of what this
decision buys. A resolver supplied as a function was rejected because a
closure is not plain boundary data and its captured environment is exactly the
retention the security review has to exclude.

**Evidence its acceptance requires.** This is a trust claim, so its class is
negative tests plus a security review, with a real-provider proof for the path
the release check already runs. Every credential-plane negative that M0 to M2
established is re-pointed at the new handoff and must hold with its assertion
unchanged in meaning; the parent VM's environment is proved empty of the
credential from the completion of composition onward — before, during and
after a call; two invocations running at once are proved unable to observe
each other's credential; every resolution failure the contract names — absent
token, malformed token, no registry row, a gone registry, a dead custody
process, a refusing custody process, one that blocks past the invocation
deadline, and a value outside the size bound — is proved to refuse with one of
the five closed reason atoms and to leave no retained copy, with the
guardian's timeout proved distinguishable from every refusal and proved to
bound the invocation whatever the custody process does; two resolutions in
flight at once are proved to be independent successes rather than a refusal;
the one permitted credential-bearing reply, and the resolver call that
carries it, are proved excluded from tracing under a trace session at the
`arguments` level; the adapter's library tree is proved to read
no environment variable by any route; and a named reviewer reads
the handoff — the token's opacity, the registry's routing-only contents,
resolution point, frame ordering, failure paths, the host implementations'
custody, and every place a value could be retained
— and records the reading with the milestone.
The real-provider lane in `bash scripts/check-release.sh` proves the path
still reaches a real provider. The concurrency result is a measurement
recorded beside the M4-closure baseline, not a pass condition.

Technical depth: [Contract and evidence](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-adr-0034-decision).

<a id="concept-adr-0034-consequences"></a>
### Consequences, Compatibility and Rollback

The credential plane gets the property the rest of ADR 0019's design already
has. In the parent the secret exists in exactly two places — the host's custody
process, which holds it and answers for it, and the short-lived sender, which
receives it once, writes it and dies — and in the child that needs it. Nowhere
else: not in adapter state, not in the environment, not in a durable or public
plane, and in no message but the one reply this pair permits. Two invocations in
one VM become independent, so the twelve provider test modules can run
concurrently and the fast check stops being pinned by that application. Host
composition gains one explicit input and one explicit obligation: a host that
starts a runtime with this adapter passes a credential token with the call,
instead of relying on the VM's environment being right at call time, and it
owns both the registry that routes the token and the custody process the
bytes live in. A host that supplies no token gets the adapter's ordinary
refusal to dispatch, which is what a missing environment variable produces
today.

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
