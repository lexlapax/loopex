<a id="concept"></a>
## Concept

Technical depth: [Private attempts IO prerequisite](0065-private-attempts-io-prerequisite-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-09
- **Decision owner:** Maintainer
- **Refines:** The development prerequisites for [M7's attempts procedure](../plans/M7-technical.md#technical-plan-evidence). Campaign ownership and [ADR 0057](0057-attempts-event-bodies.md#concept)'s event grammar remain authoritative.

<a id="concept-adr-0065-purpose"></a>
### Purpose and evidence

Technical depth: [Available lock mechanisms](0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-purpose).

M7 requires one local writer to hold an exclusive lock while recording and
syncing its attempts index. A crashed writer must release that lock. OTP
supplies no advisory file lock, and creating a lock file atomically leaves a
pathname after a crash, so a pathname cannot provide the required lifetime.

The maintainer asked to minimize external dependencies and to keep the writer
in Elixir if possible, using Python only otherwise.

<a id="concept-adr-0065-decision"></a>
### Decision

Technical depth: [Scope and physical ownership](0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-decision).

The attempts writer stays in Elixir and adds no dependency. Its lock is an
exclusive TCP listener on the IPv4 loopback address at a port fixed once in the
index's immutable lock record. The operating system grants one listener per
address and port and releases it when the holding process or VM exits, which
is the crash-release guarantee the procedure needs.

One Erlang process owns that listener and performs every index read, append
and sync covered by it. If that process dies, the listener and its raw file
descriptors close together; no other process writes the index.

A port held by anything else refuses admission as contention. Loopback
listening being unavailable refuses as unavailable evidence. Neither case is
skipped, and there is no unlocked fallback.

<a id="concept-adr-0065-options"></a>
### Options and consequences

Technical depth: [Alternatives and qualification](0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-options).

1. **Loopback listener in Elixir, selected.** No new dependency, no helper
   process and one implementation on Darwin and Linux. The lock names a port,
   not the index inode, so an unrelated program holding that port refuses the
   writer until it exits. That failure is safe: it blocks writing and never
   admits two writers.
2. **Python standard-library `lockf` helper.** A true file lock, at the cost of
   a Python prerequisite and a second process with its own custody proofs.
3. **Platform lock utilities or a native helper.** Two platform implementations
   or a packaging decision. Not selected.

The lock protects one trusted host. Exclusion across machines still requires
the accepted retained handoff and source revocation.

<a id="concept-adr-0065-current"></a>
### Current contract and rollback

Technical depth: [Current format and rollback](0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-current).

Before 1.0 only this lock path exists. No older decoder, lock marker or
parallel implementation is kept. Complete index history, current-format
replay, uncertain append, cleanup and handoff proofs remain mandatory.
Reverting the writer does not rewrite retained records, and indexed M7
execution cannot fall back to unlocked writes.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
