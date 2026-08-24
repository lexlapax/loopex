# M2 recorded limitations

Retained record of known non-conformances carried by milestone `M2`. Part of the
[evidence index](README.md).

This file is a record, not a decision. Each entry names a rule the milestone does
not fully satisfy, why, what an operator can observe as a result, and the
authority that disposed it. An independent reviewer reads these as declared
limitations rather than as undiscovered defects; nothing here authorises work or
changes a commitment.

## Promoted follow-up deadline instant

**Rule.** [ADR 0011](../adr/0011-session-input-algebra-and-streaming.md#concept)
requires a promoted follow-up's absolute deadline instant to be computed at the
promotion commit, so that a recovering owner re-presents it rather than handing
the run back the downtime it slept through.

**What this milestone does instead.** The promotion commits the declared
*duration*. The absolute instant is fixed when the promoted run stages its first
request, and is reused unchanged by every later turn of that run.

**Why.** A clock reading inside a durable record that a successor may rebuild is
exactly what made a command-admission record a function of the clock rather than
of the command. Re-presenting one command then produced different bytes for the
same transaction identifier, and the store correctly refused to resolve the
transaction it was holding. M1's `commit_unknown` fault-injection lane caught
that during this milestone's own implementation, and the same hazard applies to
any record a successor may rebuild — including a run's terminal record.

Satisfying ADR 0011 literally requires a durable commit instant. The Store
contract stamps none, and adding one is a persistent-schema decision in
[ADR 0006](../adr/0006-store-transaction-and-owner-epoch.md#concept) territory.
That decision was deliberately not taken inside this milestone.

**Observable consequence.** Bounded to one commit. Only a failure between
committing a promotion and staging that run's first turn is affected, and its
effect is that the promoted run receives its full declared budget again instead
of the remainder. Nothing is lost, corrupted, or dispatched twice. The error is
one of generosity, not of safety or determinism.

**Disposition.** Maintainer, 2026-08-24: keep the duration split and record the
deviation. The alternative considered and not taken was adding a durable commit
instant to the Store contract, which remains the conforming fix whenever that
decision is made.
