<a id="concept"></a>
## Concept

Technical depth: [Startup and cleanup contracts](0040-ephemeral-startup-interrupt-and-unnamed-root-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-28
- **Decision owner:** Maintainer
- **Supersedes:** only ADR 0039's rules that handler-installation failure stops an already created ephemeral session; that every unproved startup cleanup names a root path; and that unknown root ownership occurs only after a lost exclusive-mkdir return. All other ADR 0039 decisions remain in force.
- **Prerequisite for:** M6's standalone `ask` closure and its ephemeral startup-cleanup evidence.

<a id="concept-adr-0040-decision"></a>
### Decision

Technical depth: [Exact sequence and result](0040-ephemeral-startup-interrupt-and-unnamed-root-technical.md#technical-adr-0040-decision).

The maintainer chose two narrow corrections to the accepted M6 design.

1. `loopex ask` installs its correlated signal handler before it creates an ephemeral session. If installation fails, `ask` returns the fixed handler diagnostic and creates no session. A first signal during startup is held while the handler remains alive. If startup returns a handle before an escape, `ask` stops that session before it starts a prompt worker. Before a handle exists, the command has no session stop target; the existing backstop and second-signal escape remain in force.
2. `cleanup_unproved.root` may be `nil` only when startup has not learned a temporary-root path and an unproved pre-claim child prevents subtree proof. In that case, `root_ownership` is `:unknown`, `pending` is `[:session_subtree]`, the ending is `:none`, and the session is sealed. The command writes `root=null` in its fixed diagnostic and emits no result object. Once a path is known, every unproved cleanup continues to name it. A missing path never authorizes deletion or a cleanup-success claim.

The first correction closes the interval in which a handle existed without an installed handler. The second reports the path truthfully: candidate preparation makes no directory and cannot claim one without the owner's grant. An unproved child still remains an unproved child.

<a id="concept-adr-0040-consequences"></a>
### Consequences and compatibility

Technical depth: [Proofs, alternatives and rollback](0040-ephemeral-startup-interrupt-and-unnamed-root-technical.md#technical-adr-0040-consequences).

The handler may receive a signal before a handle exists. That interval promises neither a session result nor successful cleanup; a second signal or the fixed backstop can end the VM. Installation refusal now avoids creating a session rather than stopping one.

The `nil` root is an exception for pre-claim startup failure, not a general optional path. Hosts that inspect `cleanup_unproved` must handle this one value. M6 has not been released, so no released `0.3.0` result is changed. The durable profile and the released `0.2.0` contracts are unchanged. If this decision is not accepted, the M6 candidate must restore ADR 0039's startup order and use a separate pre-handle signal latch, and must establish a root path before any uncertain child preparation or keep startup blocked until the path is known.

M6's proof must show that a stalled candidate-preparation child cannot create a directory after `root: nil` is reported. A later milestone may replace the exception with path preallocation, but that work cannot weaken M6's sealed-session and no-claim guarantees.

Follow-on hardening task: evaluate root-path preallocation before any child
starts. Its proposal must identify the path owner and grant point, prove that
late children cannot create or delete a path after unproved cleanup, and show
how the `nil` public case migrates. This is not a deferred M6 proof obligation
or an accepted change to a later milestone.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
