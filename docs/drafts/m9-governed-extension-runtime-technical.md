<a id="technical-depth"></a>
## Technical depth

Concept: [M9 governed extension runtime](m9-governed-extension-runtime.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites

Concept: [Purpose](m9-governed-extension-runtime.md#concept-plan-purpose).

Concept: [Design decisions](m9-governed-extension-runtime.md#concept-plan-decisions).

M8 closes first. The serial barriers still apply: extension namespaces and
activation proof come before any public-protocol decision. The decisions this
draft names are proposed as ADRs before M9 opens. The vision's trust-boundary
and VM-ownership rules bind every one of them:

- same-VM extensions are trusted generations, not sandboxes;
- code loading is VM-global;
- conflicting trusted generations use isolated VMs or nodes.

<a id="technical-plan-evidence"></a>
### Evidence

Concept: [Outcomes](m9-governed-extension-runtime.md#concept-plan-outcomes).

Concept: [Scope and non-goals](m9-governed-extension-runtime.md#concept-plan-scope).

This follows the roadmap's
[governed-extension proof](../roadmap-technical.md#technical-roadmap-governed-extension-runtime):
- the extension manifest and namespaces;
- quiescent activation;
- state upgrade and downgrade fixtures;
- exact rollback.

A public-protocol release candidate and an extension contribution API come
only if they are separately accepted after the activation proof.
