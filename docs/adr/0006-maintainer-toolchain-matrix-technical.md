# 0006: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Maintainer toolchain matrix](0006-maintainer-toolchain-matrix.md#concept).

<a id="technical-adr-0006-context"></a>
## What Changes and What Does Not

Concept: [Context](0006-maintainer-toolchain-matrix.md#concept-adr-0006-context).

One clause changes. ADR 0002 said the gate locks "the newest stable supported
pair"; this says it locks the newest pair available as Homebrew stable, subject
to that pair being upstream-supported.

Everything else is restated verbatim: the floor family, the no-compatibility
claim, individual per-pair validation, the core-on-floor requirement, the
platform set, the no-required-version-manager rule, and the self-hosting
transition bound to M0 closure.

The predecessor is not edited. An accepted ADR pair is anchored across reachable
history, so supersession is additive: this document declares `Supersedes: 0002`
and ADR 0002 stays exactly as accepted. Its status remains `Accepted`, which is
still true — it was accepted, and a later decision replaced it.

<a id="technical-adr-0006-decision"></a>
## Matrix and Validation Contract

Concept: [Decision](0006-maintainer-toolchain-matrix.md#concept-adr-0006-decision).

The current pair is selected by this procedure, recorded when the gate is
written or amended:

1. Read Homebrew's stable versions: `brew info elixir` and `brew info erlang`.
2. Confirm the combination appears in Elixir's official compatibility table. If
   Homebrew's Erlang is newer than the Elixir minor supports, step down to the
   newest OTP that minor does support.
3. Record both versions exactly, including patch, in `.tool-versions`.

At the time of writing, Homebrew stable is Elixir 1.20.3 and Erlang 29.0.5, and
Elixir 1.20 supports OTP 27 through 29, so the pair is `1.20.3` with `29.0.5`.

The floor pair is unchanged: Elixir 1.17.3 with OTP 26.2.5, valid because 1.17
supports OTP 25 through 27.

Two properties this procedure has that "whatever is installed" does not: it is
reproducible by anyone with Homebrew, and it fails closed when Homebrew ships a
combination upstream does not support, rather than silently locking one.

A single Mix invocation has one Erlang runtime, so the gate cannot run both
lanes at once. `mix loopex.matrix` verifies the running toolchain is one of the
locked pairs, and the gate runner is invoked once per pair with both runs
recorded.

<a id="technical-adr-0006-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0006-maintainer-toolchain-matrix.md#concept-adr-0006-alternatives).

**Keep ADR 0002 as written.** Correct exactly while Homebrew and upstream agree.
On divergence it obliges a toolchain the maintainer cannot install by ordinary
means, converting a routine upgrade into a governed exception, and buying
nothing because this ADR claims no supported span.

**Track the installed toolchain.** Rejected, and it is worth naming why: the
gate previously locked Elixir 1.19.5 for precisely this reason — the version was
present on the machine, and no rule had selected it. Independent review found it
as an accepted-ADR violation. "Installed" describes an accident; "Homebrew
stable" is a rule someone else can reproduce and check.

**Drop the current pair and test only the floor.** Rejected. Two pairs are what
distinguish a floor from the only configuration ever exercised.

<a id="technical-adr-0006-consequences"></a>
## Operational Consequences

Concept: [Consequences](0006-maintainer-toolchain-matrix.md#concept-adr-0006-consequences).

- `brew upgrade elixir erlang` moves the maintainer onto the current lane. No
  governed exception is needed for an ordinary package update.
- The current lane can lag upstream. Acceptable while no compatibility claim
  exists; the first release claiming a supported span amends the pair with
  evidence.
- The floor lane needs a version manager or CI, because Homebrew carries one
  Elixir and one Erlang. The gate requires both lanes recorded, not both run
  locally on every invocation.
- Homebrew is now a named input to a governed decision. It is not a project
  dependency: the repository still requires no particular version manager, and
  a contributor without Homebrew reads the exact versions from `.tool-versions`.
- Changing either pair changes those bytes, which changes the gate that binds
  them, which after acceptance requires the authority that accepted it.

<a id="technical-adr-0006-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0006-maintainer-toolchain-matrix.md#concept-adr-0006-compatibility).

No public surface exists and no supported span is claimed, so nothing migrates.
The M0 gate already locks the pair this decision describes, so acceptance
records the rule that produced it rather than changing it.

Rollback is a further successor ADR restoring the earlier wording. ADR 0002's
bytes are never edited and remain exactly as accepted.

Changing the selection procedure, the platform set, or the self-hosting
obligation requires a successor ADR declaring `Supersedes: 0006`.
