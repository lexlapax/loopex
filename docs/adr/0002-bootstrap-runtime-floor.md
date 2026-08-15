# 0002. Bootstrap runtime floor and version matrix

- **Status:** Proposed
- **Date:** 2026-08-15
- **Decision owner:** Maintainer
- **Prerequisite for:** the M0 gate (see [docs/roadmap.md](../roadmap.md))

## Context

[Vision §20.1](../vision.md) sets Erlang/OTP 26+ and Elixir 1.17+ as the
repository-start compatibility target and calls it "not an eternal promise." It
requires a runtime-floor ADR to validate the exact code-loading, terminal,
disposable-node, dependency, and platform requirements **before the first
compatibility claim**. [AGENTS.md](../../AGENTS.md) pins that floor until an
accepted ADR changes it, and requires CI to cover the floor and current
supported versions. [Vision §27](../vision.md) keeps the question open: does the
floor survive dependency and platform evidence?

There is a sequencing problem in that requirement. The validating evidence —
how BEAM code loading behaves across generations, whether disposable nodes work
as assumed, what the terminal client needs — is exactly what M0 exists to
produce. An ADR written now cannot honestly carry it. But the M0 gate must name
the toolchain its commands run under before M0 can start.

This ADR therefore decides only what M0 needs, and explicitly makes no
compatibility claim.

Upstream constraint: Elixir aims to support the three most recent major
Erlang/OTP releases at the time of each Elixir release, and may add newer OTP
support in patch releases with only the minimum changes needed for stable
operation.[^compat] A consequence is that the floor pair and the current-stable
pair may share no OTP version — the matrix is a set of validated pairs, never a
cross-product.

## Decision

1. **The floor stays OTP 26 / Elixir 1.17 for development and M0**, unchanged
   from the AGENTS.md bootstrap pin. This ADR restates it as the development and
   CI target only.
2. **This ADR carries no compatibility claim.** No released surface, package, or
   support statement may cite it. The first compatibility-bearing release
   requires this ADR to be amended with the vision §20.1 evidence: code-loading
   behavior across trusted generations, terminal requirements, disposable-node
   behavior, the dependency floor of every adapter application, and the
   platforms actually exercised.
3. **The matrix is exactly two validated pairs**, locked by the M0 gate:
   - the floor pair — the lowest Elixir 1.17.x with the lowest OTP 26.x that
     Elixir's own compatibility table supports; and
   - the current-stable pair — the newest released Elixir with its newest
     supported OTP.

   The exact versions are resolved and recorded when the M0 gate is written, by
   reading Elixir's `compatibility-and-deprecations` reference — not asserted
   here, and not inferred from whatever a developer machine happens to have.
4. **Pairs are validated, not composed.** A gate run names an exact
   (Elixir, OTP) pair. If the two pairs share no OTP version, that is expected
   and is not a failure.
5. **Core must compile and pass on the floor pair.** No `apps/loopex` code may
   use a stdlib or language feature unavailable on the floor pair. A green run on
   the current pair alone is not evidence.
6. **Platforms** for development and CI are macOS on arm64 and Linux on x86_64.
   Windows is supported through WSL only, matching
   [DEVELOPMENT.md](../../DEVELOPMENT.md). Any other platform is untested and
   must not be claimed.
7. **The toolchain is pinned in-repo** by a version file the documented
   toolchain manager reads, so the local aggregate and the hosted mirror run the
   same versions. DEVELOPMENT.md records the exact command.

## Alternatives and evidence

**Raise the floor to the current stable pair only.** Rejected. It would remove
the floor coverage AGENTS.md requires, and it silently narrows who can embed
Loopex — the opposite of a host-neutral, embeddable runtime. Raising the floor
is a compatibility decision that needs the §20.1 evidence, in either direction.

**Defer the floor decision until M0 produces evidence.** Rejected as circular:
the M0 gate must lock exact commands, and a command with no named toolchain is
not a lock. Deciding the development target now and deferring only the
*compatibility claim* resolves the circularity honestly.

**Test the full cross-product of supported Elixir and OTP versions.** Rejected.
Upstream does not support every combination, so most cells would be meaningless,
and CI cost would grow without adding evidence about any claim Loopex makes.

**Assert the exact version pairs in this ADR.** Rejected. The pairs are facts
owned by upstream release tables that move between now and the M0 gate. Naming
the rule and the source is durable; naming the numbers here would be a guess
with an ADR's authority attached to it.

## Consequences

- The M0 gate can name a toolchain, so it can be written.
- Floor coverage is a standing constraint on core: two pairs run, and the floor
  pair is not optional.

What becomes harder:

- Every core change is constrained by the oldest supported stdlib. Convenient
  newer APIs are unavailable in `apps/loopex` even when a developer machine has
  them, and the failure surfaces in CI rather than locally.
- Gate runs roughly double in wall-clock and cost from the second pair.
- Developer machines will commonly run neither pair. The local aggregate must
  either pin through the toolchain manager or report which pair it actually
  ran — an unpinned local green is weaker evidence than it looks.
- The pinned version file becomes a gate-locked byte; changing it invalidates
  affected evidence.

## Compatibility

None claimed. This ADR is explicitly not a supported-version statement. The
first release that claims a supported version span must amend this ADR with
evidence and record the span in release notes.

## Migration and rollback

No code exists. Rollback is reverting the version pin file. A later floor change
is an amendment to this ADR with compatibility notes, per vision §20.1.

## Links

- [Vision §20.1](../vision.md) — bootstrap runtime floor and its evidence duty
- [Vision §27](../vision.md) — the open floor question and its trigger
- [AGENTS.md](../../AGENTS.md) — the current pin and CI coverage requirement
- [DEVELOPMENT.md](../../DEVELOPMENT.md) — prerequisites and platform support
- [docs/roadmap.md](../roadmap.md) — ADR agenda and milestone sequencing

[^compat]: Elixir's `compatibility-and-deprecations` reference, retrieved
    2026-08-15 via Context7 from the `elixir-lang/elixir` repository. The exact
    per-version table is read again when the M0 gate locks the pairs.
