# 0013. Run-deadline commitment at first request staging — technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Run-deadline commitment at first request staging](0013-run-deadline-commitment-at-first-request-staging.md#concept).

<a id="technical-adr-0013-context"></a>
## The Conflicting Records and the Shared Pre-staging Window

Concept: [Context](0013-run-deadline-commitment-at-first-request-staging.md#concept-adr-0013-context).

This decision supersedes the deadline-timing and promotion-record-shape parts of
these accepted clauses:

- ADR 0010's Concept decision that all three bounds, including the absolute
  deadline, commit with run admission and that downtime always counts against
  that instant;
- ADR 0010's technical admission/recovery table, which computes the absolute
  instant at prompt admission;
- ADR 0011's Concept decision that the promotion record carries the successor's
  complete configuration, including all three bound fields, and its rejected
  alternative, consequences, and compatibility sections wherever they require
  that literal record shape or say promotion starts the absolute instant; and
- ADR 0011's technical run-terminal transition, recovery rule, evidence,
  alternatives, consequences, and persistent-record inventory wherever they
  put `max_turns`, `token_budget`, or `deadline_instant` in the promotion record.

Every other deadline property remains: the instant is canonical request data,
recovery never recomputes a committed instant, an elapsed committed deadline
prevents another provider call, every executor job carries the same instant, and
unprovable cleanup outranks a clean bounded stop.

Prompt admission and follow-up promotion have the same relevant deadline shape.
The prompt's `command_admitted` record creates a new `run_id` and literally
carries its declared bounds. Promotion inside the prior run's terminal
transaction creates a successor `run_id` and deterministically inherits the
active run's already committed declared bounds; the terminal record does not
repeat them. Neither path has a staged request or an absolute deadline yet.
Both can be followed by owner loss before the first request commits. A rule that
describes only promotion leaves the prompt path contradicting ADR 0010 and gives
two equivalent windows different semantics.

<a id="technical-adr-0013-decision"></a>
## Record Shapes and Recovery Invariant

Concept: [Decision](0013-run-deadline-commitment-at-first-request-staging.md#concept-adr-0013-decision).

The relevant durable records are:

```text
command_admitted (prompt)
  run_id
  max_turns
  token_budget
  deadline_ms

run_terminal_committed with queued follow-up
  reducer creates successor run_id
  reducer inherits the active run's committed:
    max_turns
    token_budget
    deadline_ms

model_request_committed (first turn)
  canonical request
    deadline                  absolute instant
  staged_request_digest       covers that exact request
```

`deadline_ms` is a positive duration. Prompt admission records it as plain data.
Promotion reads the already committed declared-bounds map from reducer state and
assigns that same map to the successor inside the terminal transition. It does
not read a clock, and replay derives the same successor state from the same
record sequence.

At first staging:

```text
deadline = system_time_ms() + deadline_ms
request = canonical_request(..., deadline: deadline)
commit model_request_committed(request, staged_request_digest(request))
```

The request digest and its transaction identity cover the chosen instant. If
that commit returns unknown, the live owner re-presents the same proposal bytes.
A successor that discovers the committed record loads its exact deadline. If no
staged record exists, there is no committed instant to preserve and the
successor performs first staging once under its own clock. It never invents a
replacement for an instant that is already durable.

The reducer installs the deadline with put-once semantics when the first request
record applies. A later turn supplies the existing instant to request
canonicalization. Recovery of a staged request dispatches its committed bytes
unchanged; recovery with an elapsed deadline terminates before a provider call.
Every executor `JobRequest` receives the same value, while its dispatch-local
effective deadline remains outside the canonical request digest as ADR 0009
already requires.

The state boundary is therefore:

```text
admitted or promoted, no staged request
  deadline duration committed; no absolute instant

first model_request_committed
  absolute instant committed exactly once

every later state
  exact instant reused; downtime counts
```

<a id="technical-adr-0013-alternatives"></a>
## Why Each Alternative Changes a Larger Contract

Concept: [Alternatives](0013-run-deadline-commitment-at-first-request-staging.md#concept-adr-0013-alternatives).

Reading a clock inside command admission makes one `command_id` and canonical
command digest propose different durable bytes on replay. Reading it inside
promotion does the same to the prior run's terminal transaction. Both violate
the deterministic re-presentation required to resolve `commit_unknown`.

A Store-stamped commit instant avoids that problem because every owner reads one
durable value rather than sampling its own clock. It also changes the Store
transaction result and persistent schema, every adapter and fault-injection
fixture, and the migration contract. This ADR records staging semantics; it does
not silently add that larger port decision.

Active-time accounting is a different operator promise. It needs durable start
and stop spans across model work, executor work, cleanup, and owner downtime,
rather than one absolute instant propagated everywhere.

<a id="technical-adr-0013-consequences"></a>
## Evidence, Compatibility, and Rollback

Concept: [Consequences](0013-run-deadline-commitment-at-first-request-staging.md#concept-adr-0013-consequences).

`M2` closure evidence must prove all of the following independently:

- a prompt committed and then handed to a successor before first staging retains
  its declared duration and commits one absolute instant at the successor's first
  staged request;
- a follow-up promoted and then handed to a successor before first staging does
  the same, under the promoted `run_id`, without starting twice;
- once either run has a committed first request, owner succession reuses the
  byte-identical deadline rather than granting another duration;
- an already elapsed committed deadline causes no provider call; and
- every later turn and executor job receives the same committed instant.

Mutation evidence must separately fail if prompt admission or promotion stores
an absolute clock reading, if first staging omits the instant, or if recovery
recomputes an already committed value. A single follow-up succession case does
not protect the equivalent prompt window.

**Compatibility.** The affected journal records and embedded surface are
unreleased and explicitly unstable. The observable change from ADR 0010/0011 is
the bounded generosity before first staging; after staging, deadline behavior is
unchanged. The recorded-limitation and operator documentation must state that
boundary without calling the duration an absolute deadline.

**Rollback before closure.** The conforming alternative requires a
Store-committed timestamp and its migration and fault-injection evidence. A
rollback cannot merely move `system_time_ms()` into command admission or
promotion, because that recreates the nondeterministic transaction this decision
exists to prevent.
