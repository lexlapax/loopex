<a id="concept"></a>
## Concept

Technical depth: [Prerequisites and evidence](m9-governed-extension-runtime-technical.md#technical-depth).

**Draft, not a registered plan.** This draft comes from the maintainer's
reframing of 2026-09-26 and is refined as earlier milestones proceed. It moves
into `docs/plans/` as the Open lookahead once M8 closes.

<a id="concept-plan-purpose"></a>
### Purpose

Technical depth: [Prerequisites](m9-governed-extension-runtime-technical.md#technical-plan-prerequisites).

**M9 is the governed extension runtime,** the rung the
[roadmap](../roadmap.md#concept-roadmap-governed-extension-runtime) projects.
Its product question is:

> Can reviewed and promoted trusted behavior evolve without changing session
> truth, weakening authority, or pretending executable code is runtime-local?

Trusted OTP applications activate as quiescent, versioned generations with
tested state upgrade and downgrade and exact rollback. Code evolves, and
session history survives. Less-trusted code still crosses the executor
protocol into OS isolation, as the vision requires.

<a id="concept-plan-outcomes"></a>
### Outcomes

Technical depth: [Evidence](m9-governed-extension-runtime-technical.md#technical-plan-evidence).

| # | Outcome |
| --- | --- |
| 1 | **Extension manifest and namespaces.** A retained, digest-bound trusted artifact with declared capabilities and contribution points |
| 2 | **Quiescent activation.** A generation activates only at a quiescent point, through the VM code-generation manager that alone loads code |
| 3 | **State upgrade and downgrade.** Fixtures prove each extension's state moves forward and back |
| 4 | **Exact rollback.** The previous generation is restored with its state, proved |

<a id="concept-plan-scope"></a>
### Scope and Non-Goals

Technical depth: [Evidence](m9-governed-extension-runtime-technical.md#technical-plan-evidence).

**Scope.** The manifest, promotion into a retained trusted artifact,
quiescent activation, state migration fixtures, rollback, and the operator
documentation.

**Non-goals.**

- **Isolation:** no sandboxing by supervision tree.
- **Distribution:** no marketplace and no remote workers.
- **Freezes:** no public-protocol or extension-contribution freeze, which
  needs a separate accepted decision after the activation proof.

<a id="concept-plan-decisions"></a>
### Design Decisions

Technical depth: [Prerequisites](m9-governed-extension-runtime-technical.md#technical-plan-prerequisites).

**What stays.**
[ADR 0003](../adr/0003-extension-contract-boundary.md#concept) keeps the
extension contract boundary.

**Still to be decided,** before M9 opens:

- the manifest and namespace decision;
- the activation and rollback decision;
- the promotion rule that turns generated or third-party code into a retained
  trusted artifact.
