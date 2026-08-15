# Development Charter

<a id="concept"></a>
## Concept

Technical depth: [Development charter mechanics](development-charter-technical.md#technical-depth).

> **Clarity before mechanism.** Loopex explains purpose, constraints, and
> observable behavior before implementation machinery. Every important
> commitment remains traceable to precise technical contracts and evidence.
> Nothing essential depends on hidden context.

<a id="concept-one-explanation"></a>
## One Explanation at Two Depths

Important project concepts are explained in a concise concept document and a
companion containing the technical depth needed to implement and verify them.
They are two views of one explanation, not separate sources of truth.

The concept view owns purpose, constraints, observable behavior, and decisions.
Its companion owns invariants, schemas, commands, evidence, edge cases, and
implementation constraints. A companion may explain or prove a concept; it may
not introduce hidden scope or a decision that the concept view does not state.
When an ADR or milestone pair is governed, acceptance and later versioning bind
both files as one decision or commitment.

Technical depth: [Pair ownership and conflict handling](development-charter-technical.md#technical-one-explanation).

<a id="concept-traceable-depth"></a>
## Traceable Depth

A reader should be able to start with the concept, follow a nearby link for the
detail they need, and return without reconstructing intent from source history
or private context. Links therefore identify the exact companion section, not
merely another file.

Technical depth: [Anchors, reciprocal links, and placement](development-charter-technical.md#technical-traceable-depth).

<a id="concept-development-decisions"></a>
## Development Decisions

Loopex is maintainer-directed. Coding tools are a normal part of implementation,
testing, review, and documentation, while project roles and repository records
make authority explicit. Purpose, irreversible choices, accepted gates,
demonstrations, promotion, and publication remain governed decisions.

Development reports state outcomes and decisions before mechanics. Questions
lead with the consequence of each option and then provide the technical facts
needed to choose. Specialized terms are explained where they first matter.

Technical depth: [Development reports and decision packets](development-charter-technical.md#technical-development-decisions).

<a id="concept-smallest-system"></a>
## The Smallest Sufficient System

Simple is better. Production code, tests, fixtures, helpers, documentation,
public surface, and abstractions all carry cost. Prefer direct OTP, reuse, and
deletion before adding a layer. An abstraction must name the concrete examples
or current implementations it unifies and explain why direct code is
insufficient.

Size is evidence for review, not a universal target. Required clarity,
correctness, failure handling, and proof are never traded for a smaller count.

Public code and important boundaries explain their concept before technical
depth; private code carries paired explanation only for a non-obvious
invariant, effect, failure mode, or decision.

Technical depth: [Proportional documentation and minimalism review](development-charter-technical.md#technical-smallest-system).

<a id="concept-portable-development"></a>
## Portable Development

The complete development and validation path works with ordinary repository
tools. Optional clients and hosted services may improve feedback, but cannot be
the only home of policy, checks, or acceptance evidence. Client adapters route
back to the shared contract and context map.

Technical depth: [Portable enforcement and client adapters](development-charter-technical.md#technical-portable-development).

<a id="concept-change-control"></a>
## Changing This Charter

The two files in this charter are changed and reviewed together. A material
change to authority, acceptance, trust, evidence, autonomy, parallel work, or
project-state semantics is proposed with options and implications before it is
adopted. Reversible wording and compatibility repairs may proceed when they
preserve the established behavior.

Technical depth: [Pair lifecycle and change classification](development-charter-technical.md#technical-change-control).
