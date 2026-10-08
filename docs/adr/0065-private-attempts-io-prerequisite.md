<a id="concept"></a>
## Concept

Technical depth: [Private attempts IO prerequisite](0065-private-attempts-io-prerequisite-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-08
- **Decision owner:** Maintainer
- **Refines:** The development prerequisites for [M7's attempts procedure](../plans/M7-technical.md#technical-plan-evidence). Campaign ownership and [ADR 0057](0057-attempts-event-bodies.md#concept)'s event grammar remain authoritative.

<a id="concept-adr-0065-purpose"></a>
### Purpose and evidence

Technical depth: [Available lock mechanisms](0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-purpose).

M7 requires one local writer to hold an exclusive file lock while recording
and syncing its attempts index. A crashed writer must release that lock.
The current Git, shell, POSIX and Elixir/OTP baseline supplies no selected
portable API for this operation. Creating a lock file atomically leaves a
pathname after a crash and cannot provide the required lifetime guarantee.

Python 3 is already a prerequisite for demonstration and attended fixtures.
The development contract explicitly excludes it from the direct release
command. Using its standard-library file lock in the direct indexed M7 path
therefore needs an explicit dependency decision.

<a id="concept-adr-0065-decision"></a>
### Recommended decision

Technical depth: [Scope and physical ownership](0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-decision).

Permit Python 3's Unix standard library for a private M7 attempts IO helper
on Darwin and Linux. One directly started helper process holds the stable local lock
and performs the index IO covered by that lock. It starts no descendant writer;
retained custody observes its actual exit. Elixir retains event validation,
replay and dispatch decisions. Add no third-party Python package.

Python becomes an explicit prerequisite for the physical attempts-writer tests
and direct indexed M7 release paths. Consequently, the full fast suite also
needs Python when it includes those physical tests. Unrelated direct release
lanes retain their existing prerequisites. Core, ordinary CLI chat, embedded
runtimes and App Server acquire no Python runtime dependency.

Missing Python, unsupported locking or uncertain cleanup refuses the affected
work. Required physical tests fail or report unavailable evidence; they are not
skipped. Dependency acceptance alone supplies no campaign designation,
authority to run a paid case, new event format or passing physical proof.

<a id="concept-adr-0065-options"></a>
### Options and consequences

Technical depth: [Alternatives and qualification](0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-options).

1. **Python standard library, recommended.** One helper implementation supports
   Darwin and Linux without another package or a native build. Hosts running
   indexed M7 checks and physical writer tests must install Python 3.
2. **Platform lock utilities.** Specify Darwin's `lockf` and Linux's `flock`
   prerequisites and their different descriptor and child lifetimes. This
   avoids Python for this path but requires a revised decision and two platform
   implementations before the writer can be qualified.
3. **Bundled native helper.** Specify compiler, source-archive, build and
   distribution support. Runtime tooling could consume a compiled artifact,
   but this requires a separate packaging proposal and native source review.

The recommendation adds a development-tool dependency, not a public runtime
contract. It leaves local locks' trusted-host scope unchanged: exclusion across
machines still requires the accepted retained handoff and source revocation.
No advisory lock protects against a hostile host replacing the lock inode.

<a id="concept-adr-0065-current"></a>
### Current contract and rollback

Technical depth: [Current format and rollback](0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-current).

Before 1.0 retain only this current helper path if accepted. No older decoder,
fallback lock marker or parallel implementation is required. Existing complete
index history, current-format replay, uncertain append, cleanup and handoff
proofs remain mandatory.

Reverting the helper does not rewrite retained index records. First quiesce its
original live resources; retain any unresolved cleanup custody. Until a replacement
physical lock implementation is accepted and proved, indexed M7 execution must
remain unavailable. It cannot fall back to unlocked writes. Acceptance permits
the dependency and bounded helper implementation; milestone closure, merge,
paid campaigns and publication retain their separate authorization.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
