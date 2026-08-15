# 0002. Bootstrap runtime floor and version matrix

<a id="concept"></a>
## Concept

Technical depth: [Runtime floor mechanics](0002-bootstrap-runtime-floor-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-08-15
- **Decision owner:** Maintainer
- **Prerequisite for:** the M0 gate (see [the roadmap](../roadmap.md#concept-roadmap-m0))

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-founding-adrs-2026-08-15) | candidate `c703a65b665a5e64159e98833c63d29ff521cd2b`; concept `sha256:bc2d6dfe35707ec2551691186bbc16c7b6c34a5ebb7c6355ae9cda8c232d4a4f`; technical `sha256:06f0546ee680a97b88251a3f773ca95575c81aa1e5b3ec4a5490c53b0e9d4b8f` |

<a id="concept-adr-0002-context"></a>
## Context

Loopex starts with OTP 26+ and Elixir 1.17+, but that starting floor is not a
release promise. The evidence needed to make a compatibility claim—code-loading
behavior, terminal and disposable-node requirements, adapter dependencies, and
tested platforms—is work that M0 must produce. At the same time, the M0 gate
needs a reproducible toolchain policy before M0 can open.

This ADR decides only the development and locally runnable validation target
needed to break that sequencing loop. It makes no compatibility claim.

Technical depth: [Sequencing and upstream constraint](0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-context).

<a id="concept-adr-0002-decision"></a>
## Decision

- Keep OTP 26 / Elixir 1.17 as the development and M0 floor family.
- Make no released compatibility or support claim from this ADR.
- Have the M0 gate lock exactly two upstream-supported pairs: the lowest
  supported pair in the floor family and the newest stable supported pair.
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

Technical depth: [Matrix and validation contract](0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-decision).

<a id="concept-adr-0002-alternatives"></a>
## Alternatives

Testing only the newest pair would discard the intended floor without evidence.
Deferring every version decision would leave the M0 gate without a reproducible
toolchain. Testing a full cross-product would include combinations upstream does
not support. Freezing exact patch versions in this proposal would turn moving
upstream facts into a stale project decision.

Technical depth: [Alternative analysis and evidence](0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-alternatives).

<a id="concept-adr-0002-consequences"></a>
## Consequences

The M0 gate can name a toolchain, and floor coverage becomes a standing
constraint on core. Validation cost grows because two pairs run. Newer language
or standard-library conveniences remain unavailable in core until the floor is
changed with evidence. A local green run on an unlisted pair does not satisfy a
locked matrix lane.

M0 also carries an explicit tooling-migration outcome: the aggregate, mutation
tests, and tested client paths must run without Python or `jq` before closure.

Technical depth: [Evidence, cost, and failure cases](0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-consequences).

<a id="concept-adr-0002-compatibility"></a>
## Compatibility, Migration, and Rollback

None is claimed. The first release that states a supported version span must
amend this pair with evidence and record the span in release notes.

Two events trigger that amendment. Publishing any package declares a language
requirement to consumers, so a first publication is a compatibility claim
regardless of how the release is labelled. Retaining a prebuilt extension
artifact makes the same claim in the other direction: the artifact records the
toolchain its bytes were compiled with, and a brain must verify that record
against its own runtime before activation. The validated pairs therefore govern
what may be built and loaded, not only what this repository tests.

Before M0 closes, rollback restores bootstrap checks, hook wiring, and the
Python/`jq` prerequisites together. After closure, changing the matrix,
reintroducing a development dependency, or changing the floor requires an
amendment with compatibility and migration consequences.

Technical depth: [Compatibility, migration, and rollback mechanics](0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-compatibility).

## Links

- [Vision — repository seed](../vision.md#concept-vision-repository-seed)
- [Vision — open questions](../vision.md#concept-vision-open-questions)
- [AGENTS.md](../../AGENTS.md) — the current pin and repository-validation
  coverage requirement
- [DEVELOPMENT.md](../../DEVELOPMENT.md) — prerequisites and platform support
- [Roadmap — M0](../roadmap.md#concept-roadmap-m0)
