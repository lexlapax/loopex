<a id="concept"></a>
## Concept

Technical depth: [Startup and cleanup contracts](0040-ephemeral-startup-interrupt-and-unnamed-root-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-28
- **Decision owner:** Maintainer
- **Supersedes:** only ADR 0039's rules that handler-installation failure stops an already created ephemeral session; that every unproved startup cleanup names a root path; and that unknown root ownership occurs only after a lost exclusive-mkdir return. All other ADR 0039 decisions remain in force.
- **Prerequisite for:** M6's standalone `ask` closure and its ephemeral startup-cleanup evidence.

<a id="concept-adr-0040-decision"></a>
### Decision

Technical depth: [Exact sequence and result](0040-ephemeral-startup-interrupt-and-unnamed-root-technical.md#technical-adr-0040-decision).

The maintainer chose two narrow startup corrections to the accepted M6 design
and required a plain-English retry instruction for their command failures.

1. `loopex ask` installs its correlated signal handler before it creates an ephemeral session. If installation fails, `ask` returns the fixed handler diagnostic and creates no session. A first signal during startup is held while the handler remains alive. If startup returns a handle before an escape, `ask` stops that session before it starts a prompt worker. Before a handle exists, the command has no session stop target; the existing backstop and second-signal escape remain in force.
2. `cleanup_unproved.root` may be `nil` only when startup retains no path for its current candidate and an unproved pre-claim child prevents subtree proof. An earlier exact collision retires that attempt's path; it never becomes a possible Loopex root. In the `nil` case, `root_ownership` is `:unknown`, `pending` is `[:session_subtree]`, the ending is `:none`, and the session is sealed. The command writes `root=null` in its fixed diagnostic and emits no result object. Once the current candidate path is known, every unproved cleanup names it even before a claim grant. A path is never deletion authority: if subtree shutdown is proved and no claim grant was sent for that candidate, startup returns its bare failure without attempting root removal. Startup timeout leaves no late caller reply or unclaimed ready session; unproved cleanup is logged even if cancellation is still queued.
3. A handler-unavailable refusal or unproved cleanup also prints a fixed plain-English instruction on standard error explaining what to check or correct before running `ask` again. The fixed diagnostic code or cleanup detail remains first for scripts. Unknown-root guidance never suggests deleting a guessed path; known-root guidance does not turn a path or ownership label into deletion authority. Neither case writes a result to standard output when no run observation exists.

The first correction closes the interval in which a handle existed without an installed handler. The second reports the path truthfully: candidate preparation makes no directory and cannot claim one without the owner's grant. An unproved child still remains an unproved child.

<a id="concept-adr-0040-consequences"></a>
### Consequences and compatibility

Technical depth: [Proofs, alternatives and rollback](0040-ephemeral-startup-interrupt-and-unnamed-root-technical.md#technical-adr-0040-consequences).

The handler may receive a signal before a handle exists. That interval promises neither a session result nor successful cleanup; a second signal or the fixed backstop can end the VM. Installation refusal now avoids creating a session rather than stopping one.

The `nil` root is an exception for pre-claim startup failure, not a general optional path. Hosts that inspect `cleanup_unproved` must handle this one value. M6 has not been released, so no released `0.3.0` result is changed. The durable profile and the released `0.2.0` contracts are unchanged. If this decision is not accepted, the M6 candidate must restore ADR 0039's startup order and use a separate pre-handle signal latch, and must establish a root path before any uncertain child preparation or keep startup blocked until the path is known.

The additional stderr line changes the unreleased `ask` presentation contract; the
exit status, first diagnostic line and JSON stdout contract stay fixed. It
must not claim that handler failure always preceded session creation or that
unproved cleanup has completed.

M6's proof must show that a stalled candidate-preparation child cannot create a directory after `root: nil` is reported. A later milestone may replace the exception with path preallocation, but that work cannot weaken M6's sealed-session and no-claim guarantees.

Follow-on hardening task: evaluate root-path preallocation before any child
starts. Its proposal must identify the path owner and grant point, prove that
late children cannot create or delete a path after unproved cleanup, and show
how the `nil` public case migrates. This is not a deferred M6 proof obligation
or an accepted change to a later milestone.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m6-adr-0040-acceptance-2026-09-28) | candidate `57b0c6ab725f6502047b21fa7745fd59ccc56850`; concept `sha256:b09d673ce179fcc639cc3494e6fd641ac741d3a4ebfa3c21e17148472f17c5d4`; technical `sha256:7d612590bd3935c305ffd035fe0d2064db74faef7605c55f173ab7a69742b2aa` |
