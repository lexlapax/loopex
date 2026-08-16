# 0006. Maintainer toolchain matrix

<a id="concept"></a>
## Concept

Technical depth: [Matrix mechanics](0006-maintainer-toolchain-matrix-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-16
- **Decision owner:** Maintainer
- **Supersedes:** [0002](0002-bootstrap-runtime-floor.md#concept)

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0006-context"></a>
## Context

[ADR 0002](0002-bootstrap-runtime-floor.md#concept) requires the M0 gate to lock
"the newest stable supported pair." Written that way, the current lane tracks
upstream releases rather than the packages the maintainer actually develops on.

Today those coincide: Homebrew stable is Elixir 1.20.3 with OTP 29.0.5, which is
also the newest release. They will not always coincide. Package managers lag
upstream by days or weeks, and when they do, ADR 0002 as written obliges the
matrix to require a toolchain the maintainer cannot install by ordinary means —
turning a routine `brew upgrade` into a governed exception.

The maintainer develops on ordinary Homebrew packages. A rule that describes
that is honest; a rule that describes upstream releases and is satisfied by
accident is not.

Technical depth: [What changes and what does not](0006-maintainer-toolchain-matrix-technical.md#technical-adr-0006-context).

<a id="concept-adr-0006-decision"></a>
## Decision

ADR 0002 stands unchanged in every respect except the definition of the current
pair. This decision restates it in full so one document is the current
commitment.

- Keep OTP 26 / Elixir 1.17 as the development and M0 floor family.
- Make no released compatibility or support claim from this ADR.
- Have the M0 gate lock exactly two upstream-supported pairs: the lowest
  supported pair in the floor family, and **the newest pair available as
  Homebrew stable**, which must itself be an upstream-supported combination.
- Validate those pairs individually rather than constructing a cross-product.
- Require core to compile and pass on the floor pair.
- Exercise macOS/arm64 and Linux/x86_64; use WSL for Windows development.
- Record and verify the exact matrix in the repository without requiring a
  particular third-party toolchain manager.
- Complete the self-hosting transition before M0 closes: repository checks and
  tested client-hook paths move to Elixir standard-library or Mix entrypoints,
  prove required behavior with `jq` absent, and remove Python and `jq` from the
  prerequisites.

The enduring development baseline is Git, shell/POSIX tools, and the accepted
Elixir/OTP matrix. Another development dependency requires its own governed
decision.

Technical depth: [Matrix and validation contract](0006-maintainer-toolchain-matrix-technical.md#technical-adr-0006-decision).

<a id="concept-adr-0006-alternatives"></a>
## Alternatives

**Leaving ADR 0002 unchanged** was rejected. It works only while Homebrew and
upstream agree, and the first time they diverge the matrix demands a toolchain
the maintainer cannot install without a version manager, for no benefit to any
claim this milestone makes.

**Tracking whatever is installed** was rejected. That is how the gate came to
lock Elixir 1.19.5: a version chosen because it was present, not because a rule
selected it. "Installed" is not a rule; "Homebrew stable" is.

**Dropping the current pair** was rejected. Two pairs are what prove the floor
is a floor rather than the only tested configuration.

Technical depth: [Alternative analysis](0006-maintainer-toolchain-matrix-technical.md#technical-adr-0006-alternatives).

<a id="concept-adr-0006-consequences"></a>
## Consequences

A routine `brew upgrade elixir erlang` keeps the maintainer on the current lane
without a governed exception, and the matrix describes the development
environment that actually exists.

The current lane may sit behind the newest upstream release while Homebrew
catches up. That is acceptable because this ADR still makes no compatibility
claim; the first release that claims a supported span amends this pair with
evidence, exactly as ADR 0002 required.

The floor pair predates what Homebrew carries, so that lane runs through a
version manager or CI. The gate requires both lanes recorded, not both run
locally on every invocation.

Homebrew becomes a named input to a governed decision. If it ever ships a
combination upstream does not support, the constraint above rejects it and the
pair stops at the newest supported one.

Technical depth: [Operational consequences](0006-maintainer-toolchain-matrix-technical.md#technical-adr-0006-consequences).

<a id="concept-adr-0006-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists and no supported version span is claimed, so nothing
requires migration. The M0 gate's `.tool-versions` bytes already name the pair
this decision describes.

Rollback is a further successor ADR restoring the ADR 0002 wording. ADR 0002's
own bytes are never edited; it remains exactly as accepted.

Technical depth: [Compatibility and rollback mechanics](0006-maintainer-toolchain-matrix-technical.md#technical-adr-0006-compatibility).

## Links

- [ADR 0002](0002-bootstrap-runtime-floor.md#concept) — the decision this
  supersedes, retained unchanged
- [M0 gate](../plans/M0-gate.md) — where the matrix is locked
- [Vision: repository seed](../vision.md#concept-vision-repository-seed)
