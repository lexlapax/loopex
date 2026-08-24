<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](M2.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M2.md#concept-plan-scope).

Concept: [Milestone non-goals](M2.md#concept-plan-non-goals).

`M1` must be Closed and integrated before this plan is accepted. This milestone
consumes its outbox, cursor semantics, per-attachment queue behaviour, ADR 0006
fencing, and ADR 0007 grant validation as settled contracts and proves none of
them again.

Three decisions block acceptance. None may be settled inside this plan.

**ADR 0008 — session protocol candidate.** Owns command and event envelope
shape, the initialize handshake, capability negotiation and experimental gating,
the canonical encoding, the error model, and the golden-vector obligation.
Public-contract and persistent-schema class. Outcome 2 cannot be implemented
before it is accepted, and outcomes 3, 4, 6, and 9 bind to its encoding.

**ADR 0009 — attachment, cursor, delivery, retention, and residency.** Owns what
an attachment is, whether per-attachment cursors survive daemon restart, the
at-least-once-with-no-gaps guarantee, `cursor_expired` semantics, how much
committed public-event history is retained, and when a session with zero
attachments stops being resident. Outcomes 4, 5, 6, and 8 depend on it.

**ADR 0010 — daemon collaboration policy and takeover.** Owns
one-controller/many-observer, read-only attachment, controller crash takeover,
and stale-writer fencing, and fixes that all of it lives above core. Outcome 7
depends on it and outcome 9 exercises it.

Acceptance points. The maintainer or a recorded delegate accepts both normative
envelopes and the gate's canonical bytes together, and accepts ADR 0008, 0009,
and 0010 **before this plan is accepted** — not merely before the outcomes they
govern are implemented.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M2.md#concept-plan-scope).

One integrator owns rejoin, conflicts, the candidate SHA, and post-rejoin
verification. The maintainer owns ADR 0008, 0009, and 0010, scope deferral, gate
weakening, evidence waiver, and closure.

Rejoin barriers, in order:

1. **A rejoins first.** The protocol candidate and its vectors fix what crosses
   the wire. Building a transport against an unsettled envelope means rewriting
   the transport when the envelope settles.
2. **B rejoins before C.** Attachment, cursor, and backpressure work concerns
   clients attaching to a daemon-owned session. Building it before the lifetime
   inversion means building it against the embedded-caller shape it replaces.
3. **D rejoins last** and may not begin before A, B, and C are integrated. A
   multi-client recovery trace over an unsettled attachment contract
   demonstrates the contract rather than the recovery.

No workstream may create an alternate session loop, a private authority path, or
a competing durability truth to avoid a barrier. The daemon may not cache,
derive, or repair session truth to work around a cursor, retention, or residency
gap; such a gap is a defect in B or C, not a daemon feature.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M2.md#concept-plan-outcomes).

| # | Obligation |
| --- | --- |
| 1 | Sessions driven to a durable terminal result with zero attachments under clean detach, abrupt socket close, and `SIGKILL` of the client OS process, with a counting assertion that no session work paused at the moment of disconnection |
| 2 | Golden vectors as committed canonical bytes; a decoder implemented against those vectors alone, with no access to the Elixir encoder, round-tripping every vector; negative vectors for pre-initialize request, unknown version, and ungated experimental method |
| 3 | A negative corpus at the framing boundary — truncated frame, over-bound frame, mid-command disconnect, malformed envelope — each individually refused with an exact reason, plus an isolation assertion that a second attachment and session truth are unaffected |
| 4 | Concurrent attaches injected during active event production, asserting the snapshot anchors at exactly the barrier sequence and the delivered stream is contiguous across the snapshot/buffer/live seam; deduplication proved by replaying a duplicate |
| 5 | A deliberately stalled consumer with a bounded coordinator-memory assertion, a journal-transaction latency assertion, and a second-client liveness assertion, all taken while the slow attachment is stalled |
| 6 | Cursor resume across client restart and daemon restart; a retention-boundary test driving history past the configured bound and asserting explicit `cursor_expired` plus a usable fresh snapshot; a negative test that paged history read establishes no subscription |
| 7 | Policy conformance in the daemon plus a core-purity negative test: core admits and serializes commands with no controller concept, proved by a module-boundary assertion that no daemon collaboration term appears in core |
| 8 | Residency transitions under a shortened configured grace period: eviction after zero attachments, an observable transition rather than a silent one, durable truth unchanged across eviction, and a post-eviction attach whose snapshot is byte-identical to a resident-session snapshot at the same sequence |
| 9 | One real-provider trace with counted logical dispatches and effects across the daemon kill, proving exactly one of each; observer B's received sequence compared for gaps and duplicates against committed history; retained non-secret provider, model, and endpoint class |

Every negative demonstration is retained with the milestone: the mechanism
disabled, the resulting failure, and the revision it was demonstrated at, with
restoration verified against `git show <candidate>:<path>` rather than a hash
captured during the session.

Fault points for outcomes 1, 8, and 9 derive from the daemon's and coordinator's
actual transition points rather than a hand-listed set, and each run retains
seed, count, and coverage.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M2.md#concept-plan-scope).

No public compatibility claim, freeze, or release candidate. The protocol is
labelled experimental and may change until a milestone past the extension and
activation barrier decides otherwise with independent consumers, migrations, and
upgrade evidence.

The golden vectors are versioned from the commit that introduces them, so a later
change is visibly a change rather than a silent redefinition. That is a
discipline, not a compatibility promise.

The embedded API from `M1` remains available and unchanged. The daemon is a peer
surface; neither is privileged and neither owns an alternate session truth.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M2.md#concept-plan-scope).

No installed base, no released artifact, and no store schema change. `M1`
sessions are readable because the store contract is untouched; that is a
consequence of not changing it, not a migration guarantee.

Rollback is reverting to a tree whose gate is green. Each workstream lands behind
a green gate on every locked lane.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M2.md#concept-plan-scope).

Nothing is published, installed, or versioned for distribution. The daemon starts
from a documented repository command, not an installed service, init unit, or
launch agent.

`DEVELOPMENT.md` gains the daemon's operator entrypoint, because a daemon only
the tests know how to start is not runnable.

Core remains stdlib and OTP only. A serialization or transport dependency would
be an ordinary dependency decision, and the recommendation is to avoid one: the
canonical encoding should be expressible with the standard library.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M2.md#concept-plan-scope).

The multi-client trace is the unit of value. A protocol document, a codec, a
registry, or a checker cannot satisfy an outcome in its place, and the gate's red
condition is that a second client cannot attach to a session whose first client
is gone — never that an artifact is missing.

`M2` adds no new product boundary behaviour. Store, model, and executor remain
the only three. Specifically:

- **No transport behaviour.** One transport does not justify a replaceable
  boundary; the socket server is direct code. The behaviour appears at the remote
  rung when a second transport exists to unify.
- **No broker, event-bus abstraction, or generic policy framework.** The
  dispatcher already exists; collaboration policy is concrete daemon code.
- **No session-engine layer** shared between the embedded API and the daemon.
  Both are thin surfaces over the same runtime reference.

The protocol is a data contract with golden vectors, not a behaviour. A fourth
boundary behaviour or a generic layer above the three requires an accepted plan
amendment naming the concrete current implementations it unifies.

Raw line count is recorded at closure as a review signal, never a pass threshold.
<!-- loopex:plan-technical-envelope:end -->
