# 0002. Bootstrap runtime floor and version matrix — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Bootstrap runtime floor and version matrix](0002-bootstrap-runtime-floor.md#concept).

This file supplies version-resolution, validation, migration, and evidence
mechanics for ADR 0002. Status, ownership, and governance live in the Concept
file; acceptance binds both files.

<a id="technical-adr-0002-context"></a>
## Sequencing and Upstream Constraint

Concept: [Context](0002-bootstrap-runtime-floor.md#concept-adr-0002-context).

[The repository seed](../vision-technical.md#technical-vision-repository-seed)
sets Erlang/OTP 26+ and Elixir 1.17+ as a starting target and requires evidence
before the first compatibility claim. That evidence includes code loading
across trusted generations, terminal requirements, disposable-node behavior,
adapter dependency floors, and platforms actually exercised. M0 exists in part
to produce it, yet the M0 gate needs a named toolchain before work starts.

Elixir aims to support the three most recent major Erlang/OTP releases at the
time of each Elixir release and may add newer OTP support in patch releases with
only the minimum changes needed for stable operation.[^compat] The floor and
current-stable pairs can therefore share no OTP version. The matrix is a set of
supported pairs, never a cross-product.

<a id="technical-adr-0002-decision"></a>
## Matrix and Validation Contract

Concept: [Decision](0002-bootstrap-runtime-floor.md#concept-adr-0002-decision).

1. M0 runs against OTP 26 / Elixir 1.17 as the floor family. This is a
   development and locally runnable validation target, not a released support
   statement.
2. The M0 gate resolves and locks exactly two upstream-supported pairs:
   - the lowest Elixir 1.17.x with the lowest OTP 26.x supported by Elixir's
     compatibility table; and
   - the newest released Elixir with its newest supported OTP.
3. Exact versions are read from Elixir's current
   `compatibility-and-deprecations` reference when the gate is written. They are
   not inferred from the authoring machine or frozen in this ADR pair.
4. Each validation run reports and checks one exact `(Elixir, OTP)` pair. The
   two pairs are not composed into a cross-product.
5. `apps/loopex` compiles and passes on the floor pair. Core cannot use a
   language or standard-library feature absent there. A current-pair-only green
   run is insufficient evidence.
6. The development and validation platforms are macOS/arm64 and Linux/x86_64.
   Windows uses WSL. Other platforms remain untested and unclaimed.
7. The accepted M0 plan chooses a plain in-repository matrix representation and
   a preflight that verifies the active pair. Loopex does not prescribe a
   third-party version manager; commands use active `elixir` and `mix`
   executables.
8. Before M0 closes, repository checks move to Elixir standard-library or Mix
   entrypoints, preserving the existing structural and mutation-test behavior.
   Tested client hooks call those entrypoints. The gate proves their required
   behavior with `jq` absent.
9. Python 3.11 and `jq` are removed from the development prerequisites together
   at closure. Removing a tested hook instead requires an explicit accepted M0
   disposition with equivalent protection or an explicitly accepted loss.
10. The enduring baseline is Git, shell/POSIX tools, and the accepted
    Elixir/OTP matrix. A further development dependency needs the ordinary
    governed dependency decision.

<a id="technical-adr-0002-alternatives"></a>
## Alternative Analysis and Evidence

Concept: [Alternatives](0002-bootstrap-runtime-floor.md#concept-adr-0002-alternatives).

**Current stable only.** Rejected because it removes floor coverage and narrows
embedding without the compatibility evidence required to raise the floor.

**Defer every version decision until M0.** Rejected as circular: the red gate
cannot lock reproducible commands without a named toolchain policy. This ADR
settles the policy and leaves moving upstream facts to gate authoring.

**Full Elixir/OTP cross-product.** Rejected because upstream does not support
every combination. Unsupported cells add cost without proving a Loopex claim.

**Exact version numbers in this ADR.** Rejected because those are upstream facts
that can move before the M0 gate. The durable decision is the selection rule and
source.

<a id="technical-adr-0002-consequences"></a>
## Evidence, Cost, and Failure Cases

Concept: [Consequences](0002-bootstrap-runtime-floor.md#concept-adr-0002-consequences).

- Gate execution roughly doubles because each required claim runs on two exact
  pairs.
- The floor constrains core language and stdlib use even when a local machine
  provides newer APIs.
- A local aggregate run reports the active pair. If a locked gate requires a
  different pair, that lane is unavailable rather than implicitly passed.
- The matrix representation and preflight are gate-locked bytes. Changes
  invalidate affected evidence.
- M0 closure evidence includes the local aggregate, its mutation corpus, and
  tested client-hook paths running without Python or `jq`.
- A missing version manager, hosted CI, or network connection does not prevent
  ordinary repository use; it can make a particular locked matrix lane
  unavailable until the required local pair is activated.

<a id="technical-adr-0002-compatibility"></a>
## Compatibility, Migration, and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0002-bootstrap-runtime-floor.md#concept-adr-0002-compatibility).

This ADR makes no support claim. A compatibility-bearing release must amend the
pair with the vision's required evidence and state the supported span in release
notes.

Before M0 closes, rollback restores the prior bootstrap checks, hook wiring, and
Python/`jq` prerequisites atomically. A partial rollback that leaves a tested
path silently disabled is invalid. After closure, changing the matrix,
reintroducing a development dependency, or raising the floor requires an
amendment with compatibility, migration, and rollback evidence.

[^compat]: Elixir's `compatibility-and-deprecations` reference, retrieved
    2026-08-15 via Context7 from the `elixir-lang/elixir` repository. Read the
    exact table again when the M0 gate locks the pairs.
