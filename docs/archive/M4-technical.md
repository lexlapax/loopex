<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](M4.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M4.md#concept-plan-scope).

Concept: [Milestone non-goals](M4.md#concept-plan-non-goals).

This Open plan is planning-only. M2 remains `Accepted` and is the sole product
implementation authority. M4 acceptance, integration, and implementation are
refused until M2 is Closed and integrated to `main`; this branch then absorbs
that exact product base, proves all inherited gates green and the distinct M4
red, and receives a fresh exact-SHA review.

Two proposed decisions are prerequisites for accepting this plan pair:

- **ADR 0019 — Experimental public session protocol.** Owns transport-neutral
  DTOs, stdio JSONL framing, initialization and capability negotiation, identity
  separation, record families, error and unknown-value behavior, resource
  bounds, app-server ownership, and source-version versus protocol-version
  identity.
- **ADR 0020 — Durable interaction lifecycle and host-policy authority.** Owns
  `interaction_id`, durable states and records, response admission, expiry,
  abort/deadline races, restart reconstruction, and the rule that an answer is
  policy evidence and not a grant.

Four further decisions remain separate from plan acceptance:

1. Closed M1 and M2 gate generations must be explicitly approved before the
   ninth application and dependency-budget changes can rebind their protected
   inventory and direction evidence.
2. Closed M1 and M2 gate generations must be explicitly approved before source
   `VERSION=0.1.0`; the replacement must validate real-path identities against
   the candidate's canonical `VERSION`, not merely substitute one literal for
   another.
3. M4 acceptance and any governance-only integration remain maintainer
   decisions after the required rebase and fresh review.
4. Publication, tag, package, release, compatibility freeze, or any M4 deferral
   remains separately approval-gated and is not implied by M4 closure.
5. The closed-gate aggregate this milestone owns must have its own invocation
   structurally verified, either by placing invocation in a repository
   entrypoint that owns the rule, or by a check that fails when a milestone gate
   omits its one mandatory call. Without that it is `M2`'s waiver with more
   machinery. The obligation originates in the `M2` disposition anchored
   `disposition-m2-inherited-gate-enforcement-2026-08-27` in the agent context
   map, which is not reachable from this branch until it absorbs `M2`'s closed
   base; link it there once it is.
6. The `M0` gate reports any outcome-1 command failure as
   `the effective formatter configuration does not cover application sources`,
   so an unrelated crash reads as a formatter problem. Observed 2026-08-27: a
   floor-toolchain run over current-pair build artifacts died in
   `Protocol.extract_from_beam/2` with `:badarg`, because `check-m0-gate.sh`
   sets no `MIX_BUILD_ROOT` and OTP 26 cannot read an OTP 29 beam. The verdict
   named the formatter. `M0` is Closed, so correcting the label is an
   `amendment-transaction-v2` gate generation; it is folded into the closed-gate
   aggregate above rather than opened on its own, because that work reaches these
   gates anyway. Until then the workaround is to clear `_build` between toolchain
   pairs, and to read the stack above the verdict rather than the verdict.
7. Raising the bootstrap runtime floor is an amendment to accepted ADR 0002,
   never an edit to a gate or to `.tool-versions`. ADR 0002 derives the pins
   from upstream rather than choosing them: the floor is the lowest Elixir
   1.17.x with the lowest OTP 26.x that Elixir's compatibility table supports,
   and the current pair is the newest released Elixir with its newest supported
   OTP. Because Elixir supports the three most recent OTP releases, the two
   pairs can share no OTP version, so the floor cannot be set equal to the
   current pair without collapsing the matrix to a single toolchain and losing
   every lane that could detect toolchain sensitivity. Raising the floor family
   is the available move; setting floor equal to current is not.
8. Accepted ADR 0009 requires the tool cleanup grace period to be a declared
   session configuration value with a default, reported in the terminal
   outcome's evidence. `M2` implements it as a `cleanup_grace_ms` start option
   of `Loopex.Executor.Local`, with `process_probe` beside it, both recorded on
   every retained receipt and readable from the running executor. Three things
   the ADR asks for are absent and are this milestone's to supply: the shipped
   `loopex_composition` neither accepts nor forwards either value, so a
   reference embedder and a command-line operator both get the defaults;
   `SessionState.decode_receipt/1` omits them from its field list, so neither
   survives reconstruction from the journal; and no run terminal projects the
   period. Closing this is a session-configuration decision rather than an
   executor one, so it carries whatever amendment to ADR 0009 the final shape
   requires — including the possibility that the right answer is to narrow the
   ADR instead, which is a decision this milestone must take explicitly rather
   than inherit. The `M2` disposition is anchored
   `cleanup-grace-not-session-visible` in `docs/evidence/M2-recorded-limitations.md`,
   which is not reachable from this branch until it absorbs `M2`'s closed base;
   link it there once it is.

Deferred decisions and trigger points:

| Deferred decision | Trigger |
| --- | --- |
| Generic context pipeline | Before the first registered provider, transformer, selector, or observer; M4 only projects M2's fixed project-resource stage |
| Generic transport behavior | After a second real transport exists and supplies common evidence |
| Daemon lifetime, controller leases, concurrent clients, takeover, and service authentication | M4, before any background or multi-client host ships |
| Persistent-store migration and downgrade | Before any installed data or daemon Store compatibility claim |
| Public protocol compatibility range | Before publication or a claim that different generations interoperate |
| Bootstrap runtime floor family, by amendment to accepted ADR 0002 | Before this plan pair is accepted, and in any case before the first released support statement, after which raising it is a breaking change requiring migration under the 0.x compatibility policy |
| Whether the cleanup period and process probe become session configuration reported on the terminal, or ADR 0009 narrows to executor configuration | Before `M4` closes, because the app server is the surface that would carry them to a client and the shape cannot be settled twice |

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M4.md#concept-plan-scope).

`loopex_protocol` owns transport-neutral plain DTOs, validators, schemas, and
vectors. `loopex` owns interaction truth, policy resumption, snapshots, event
cursors, and every durable command. `loopex_app_server` owns only process
lifetime, framing, connection-local correlation, the bounded writer, stderr
diagnostics, trusted launch-configuration intake, and mapping to the public
facade. It receives the required policy implementation and its bounded identity
from the launcher, supplies no fallback, and accepts no wire policy selector.
`loopex_composition` retains the reference adapter wiring. Sample clients own no
normative semantics.

Identity ownership is exact:

| Identity | Owner and guarantee |
| --- | --- |
| `request_id` | App-server connection; ephemeral correlation, never durable authority |
| `command_id` | Session command; durable idempotency under the one serial owner |
| `interaction_id` | Session interaction; durable suspended-decision identity |
| `session_id`, `run_id`, `turn_id` | Existing M2 durable semantics |
| `event_sequence` | Durable per-session event cursor |
| `stream_domain_id` | Transient attempt-progress domain, never journal truth |
| artifact reference | Opaque artifact-store retrieval reference, never a path |
| source `VERSION` | Repository version train, never protocol compatibility |

The rejoin barrier is A → B → C → D. A is dependency-free and runtime-free. B
imports no app-server or codec. C depends inward on the public facade and
composition, never on internals. D executes consumers against the exact schema
and may not widen it. One integrator owns the candidate, gate evidence, and
post-rejoin checks.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M4.md#concept-plan-outcomes).

Every protected selector runs through the repository's authoritative standalone
ExUnit channel with exact case identities, states, minima, seed, owner and
dependency closure. The M4 gate also re-runs all inherited Closed gates after
the M2 product base is integrated. During this lookahead it instead proves the
accepted M2 opening red and the distinct M4 red as separate commands.

| Outcome | Required proof beyond its selector |
| --- | --- |
| 1 | Gate-owned raw-byte client launches a separate BEAM process; no product code or product codec judges stdout; exact initialization/schema/capability/limit vector; no mutation before success |
| 2 | Same command corpus through facade and wire; explicit attachment yields snapshot/cursor before commands; exact request, command, and session identities bind admission; gap-free durable events and admission are observed before progress and terminal output; each identity kind's replay rule is varied independently |
| 3 | Snapshot/cursor/live-event ordering properties, stream-domain gap and missing-closure fallback, kill and fresh-process resume, no attachment-survival claim |
| 4 | Exact manifest projection, positive/stale/missing decisions, changed workspace invalidation, withheld-content task completion, and separation from policy defer and grants |
| 5 | Chunk/range reconstruction and digest equality, opaque-reference negatives, no path, bounded frame under oversized output |
| 6 | Failure before/after interaction commit, answer admission, policy result, grant/intent commit, and publication; M2 one-shot defer refusal beside M4 interaction-aware evaluation; restart binding identity and all competing transitions; wire-cannot-select-policy and answer-cannot-grant properties; observed authorized tool result after resolution |
| 7 | Invalid UTF-8, duplicate keys, excessive nesting, fragmented and multiple frames per read, oversized input/output, blocked reader, stdout contamination, process loss and cleanup |
| 8 | Exact schema/vector manifest plus executed Elixir, Python, and JavaScript standard-library clients at named versions; missing interpreter is unavailable evidence, never PASS |

Mandatory closure evidence additionally includes one real-provider, real-tool
coding task driven entirely by a non-Elixir client through the shipped
app-server; an interaction suspend/restart/respond trace; protocol and schema
digests; provider/adapter/executor identity under M2's disclosed attestation
limit; toolchain/platform matrix; and a negative dependency/facade demonstration.

The raw probe is a bounded ordered-state check over canonical response records,
not a general JSON conformance claim. Product selectors and golden vectors own
order-independent semantic parsing. A server that merely echoes frames cannot
pass because the probe requires explicit attachment, exact command-bound
admission, kind-complete zero-based domain progress anchored to an already
observed durable event, byte-identical-only duplicate events with globally
unique event IDs, a policy interaction and admitted response, a completed tool
result carrying that interaction's exact `tool_call_id`, gap-free canonical
`run.finished` then `session.settled` events, and a fresh settled attachment for
the same session.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M4.md#concept-plan-scope).

The protocol is experimental and requires exact generation and schema-digest
agreement. Unknown output fields follow the one negotiated generation's reader
rule; unknown mutating discriminants are always refused. No cross-generation,
network, daemon, installed-data, or package compatibility is claimed. Existing
M2 embedded and command surfaces remain peers and keep their semantics.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M4.md#concept-plan-scope).

M2 evidence roots are not migrated. M4's private Store catalogue adds
interaction records additively, and an M2 binary is not promised to reopen an
M4 root containing them. Before closure, rollback removes interaction state,
app-server, direct codec declaration, schema bundle, clients, and `VERSION`
change together and discards M4 evidence roots. No in-place downgrade is
claimed.

Process restart recovery is not Store migration: a new M4 process resumes the
same M4 data through the public facade. Any installed-data promise, new Store,
or daemon migration requires a later accepted decision.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M4.md#concept-plan-scope).

The new `loopex_app_server` is the ninth umbrella application with role
`:client`. It declares production dependencies on `:loopex`,
`:loopex_protocol`, and `:loopex_composition`, takes no external dependency because
the standard-library `JSON` module covers the codec, depends on no other client, and exposes one source-built foreground entrypoint. The human
command remains a peer and has no new external dependency.

At the closure rejoin, all application versions and the root `VERSION` become
exactly `0.1.0` under the separately approved gate generations. The app-server
is not published, packaged, tagged, or installed as a service. Elixir, Python,
and JavaScript sample clients are source fixtures/examples and use only their
language standard libraries.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M4.md#concept-plan-scope).

Justified permanent growth is one application, one direct external dependency,
one transport mapping, one interaction reducer slice, exact schemas/vectors,
and three small clients. The following negative constraints are gate-locked:

- exactly nine umbrella applications and no new application role;
- exactly one direct external production dependency owned only by
  `loopex_app_server`;
- no generic transport behavior, transport registry, socket abstraction,
  daemon supervisor, connection lease, second loop, or second session reducer;
- `loopex_protocol` and core remain dependency-free and contain no JSON term;
- app-server modules have no direct coordinator, Store, model, executor,
  journal, cursor, or human-command dependency;
- each sample client is one file using its language standard library;
- artifact bytes are chunked and no frame, queue, identifier, string,
  collection, diagnostic, or wait is unbounded.

Raw line count is a review signal, not a substitute for those structural
ceilings. A reusable abstraction needs a second real consumer before it enters
this milestone.
<!-- loopex:plan-technical-envelope:end -->
