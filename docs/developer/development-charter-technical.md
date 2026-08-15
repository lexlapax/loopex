# Development Charter — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Development charter](development-charter.md#concept).

This companion defines the charter's exact form. Neither file outranks the
other; a conflict blocks acceptance, implementation that depends on the
conflict, and closure.

<a id="technical-one-explanation"></a>
## Pair Ownership and Conflict Handling

Concept: [One explanation at two depths](development-charter.md#concept-one-explanation).

A paired document set uses these paths:

```text
<name>.md
<name>-technical.md
```

The concept file owns:

- purpose and the problem being addressed;
- constraints and non-goals;
- observable behavior and expectations;
- decisions, alternatives at the level needed to choose, and consequences; and
- links to each section whose implementation or proof needs technical depth.

The technical companion owns:

- invariants, state transitions, schemas, algorithms, and boundary data;
- exact commands, fixtures, vectors, selectors, and evidence;
- failure modes, edge cases, compatibility, migration, and rollback mechanics;
- implementation constraints and concrete examples served by abstractions; and
- reciprocal links to the concept sections it explains.

The pair is one authority and one review unit. Add, rename, move, accept,
supersede, or remove both files atomically. Technical detail cannot create an
unstated decision, and concept prose cannot override a technical invariant by
omission. A mismatch is a blocking finding until the pair agrees.

An ADR pair records one status and governance table in its Concept file. Its
acceptance binds the reachable historical Proposed candidate plus the SHA-256
digest of both files. A milestone uses a Concept plan, Technical depth plan,
and gate; acceptance and closure bind the candidate plus all three digests. The
exact formats and lifecycle transitions live in
[the plans index](../plans/README.md).

Pairing applies to substantive concept documents, including the vision,
roadmap, development charters, architecture and protocol documents, ADRs, and
milestone plans. The following are explicit exceptions because they route,
operate, record, or execute rather than explain a concept:

- the canonical `AGENTS.md` development contract and client entrypoints;
- `README.md` files and documentation indexes;
- setup guides and operator runbooks such as `DEVELOPMENT.md`;
- changelogs, status registers, evidence logs, and generated references;
- licenses, executable skills, client role prompts, configuration, and source;
- gates, schemas, fixtures, and other directly executable contracts; and
- immutable, non-normative archive material.

An exception may link both depths. It may not become a hidden source of a
decision that belongs in a pair. The approachable registry in
[docs/README.md](../README.md) indexes active pairs and routes to these
exception rules. A new active Markdown document under `docs/` defaults to a
pair. Unpaired operator/setup runbooks live under `docs/operator/`, generated
references under `docs/generated/`, standalone evidence logs under
`docs/evidence/`, and directly executable schema or fixture documentation under
`docs/schemas/` or `docs/fixtures/`. Repository-level conformance, schema, and
fixture trees, `.github/` interaction templates, and license files are also
reserved exception paths. Any other new exception requires a deliberate checker
and index update rather than passing as an unknown class.

<a id="technical-traceable-depth"></a>
## Anchors, Reciprocal Links, and Placement

Concept: [Traceable depth](development-charter.md#concept-traceable-depth).

Every paired section uses a stable explicit HTML anchor:

```markdown
<a id="concept-vision-recovery-truth"></a>
## Recovery Truth

Effect intent becomes durable before dispatch.

Technical depth:
[Commit ordering](../vision-technical.md#technical-vision-recovery-truth).
```

The companion supplies the reciprocal link:

```markdown
<a id="technical-vision-recovery-truth"></a>
## Recovery Mechanics

Concept:
[Recovery truth](../vision.md#concept-vision-recovery-truth).
```

Anchors are lowercase ASCII, unique within their file, stable across wording
changes, and prefixed `concept-` or `technical-`; path plus fragment identifies
an anchor repository-wide. A concept section
places its `Technical depth:` link immediately after the paragraph, list, table,
or short subsection that depends on it. Pure orientation or purpose prose needs
no ceremonial link. File-level links do not substitute for section links.

Relative links must resolve inside the repository, target the actual companion,
and identify exactly one explicit anchor. Reciprocal links must return to the
originating concept anchor. Link text describes the target rather than using an
ambiguous phrase such as “details here.”

Active repository documentation uses the simple `[label](relative-path#anchor)`
form for local links. Link-title syntax and angle-bracket destinations are not
part of the retained grammar; the structural check rejects them rather than
silently skipping a path it cannot prove. Reference-style links, local query
destinations, embedded-image syntax, and raw HTML beyond exact semantic anchors
and comments are likewise outside this deliberately small grammar.

Every local Markdown fragment link in active documentation targets a stable
explicit HTML anchor; generated heading slugs are not a retained contract.
Paired files use the `concept-*` and `technical-*` prefixes above. Exception
documents may use a descriptive lowercase ASCII anchor without those depth
prefixes.

<a id="technical-development-decisions"></a>
## Development Reports and Decision Packets

Concept: [Development decisions](development-charter.md#concept-development-decisions).

Substantive updates, reviews, questions, and decision packets use exactly these
top-level sections in this order:

```markdown
## Concept

<outcome, expectations, constraints, why, options, and recommendation>

## Technical depth

<files, contracts, evidence, commands, edge cases, compatibility, and migration>
```

Short acknowledgements, direct answers, and compact status notifications are
exempt when splitting them would add ceremony without clarity. A response never
hides a required decision in the technical section. When a decision is needed,
the concept section presents mutually meaningful options, consequences, and a
recommendation; the technical section supplies the proof and implementation
impact.

Documentation describes project roles, artifacts, workflows, and depth
positively. It does not rank participants, speculate about content origin, or
divide expectations by who or what produced the work. Product terms such as
model, coding agent, client, maintainer, operator, and user remain appropriate
when they identify actual domain roles. Specialized vocabulary is defined in
ordinary language at first use in both depths.

<a id="technical-smallest-system"></a>
## Proportional Documentation and Minimalism Review

Concept: [The smallest sufficient system](development-charter.md#concept-smallest-system).

Elixir modules, behaviours, callbacks, public APIs, public types, and important
boundaries carry both sections in `@moduledoc`, `@doc`, or `@typedoc`:

```elixir
@doc """
## Concept

What callers can expect and why the operation exists.

## Technical depth

Invariants, effects, failure modes, ordering, and boundary constraints.
"""
```

A private function receives adjacent `# Concept:` and `# Technical depth:`
comments only when it carries a non-obvious invariant, effect, failure mode, or
design decision. Obvious helpers rely on clear names and direct code. Comments
must not paraphrase syntax or create documentation solely to satisfy a count.

Every proposed abstraction identifies at least two concrete examples or current
implementations it unifies, unless a boundary contract or safety invariant
requires the abstraction independently. A plan may lock a scope-specific size
or dependency budget. Repository-wide readability scores, word quotas, and
universal line-count limits are prohibited because they reward compression and
ceremony rather than clarity.

<a id="technical-portable-development"></a>
## Portable Enforcement and Client Adapters

Concept: [Portable development](development-charter.md#concept-portable-development).

Repository-owned commands enforce structure and retained evidence. Hosted CI
and client hooks call the same commands and do not redefine or waive them. The
bootstrap checks cover:

- classification of every active Markdown file;
- required companion existence and absence of orphan companions;
- unique explicit anchors, exact targets, reciprocal links, and repository-safe
  relative paths;
- paired ADR and plan governance records and exact digests;
- the plan/technical-plan/gate triple for active milestones; and
- the absence of policy that exists only in a client directory.

M0 must add an Elixir/Mix documentation check before product code can close its
first milestone. It reads compiled documentation through `Code.fetch_docs/1`
and requires `## Concept` before `## Technical depth` for modules, behaviours,
callbacks, public APIs, and public types. The accepted M0 plan identifies any
additional important boundaries. Review remains responsible for whether those
sections are useful and for the proportional private-comment rule, which cannot
be inferred safely from syntax alone.

Independent review covers semantic qualities a parser cannot prove: concept
clarity, constraint-first ordering, adequate nearby technical links, locally
defined vocabulary, companion readability, consistency, and absence of hidden
decisions. Structural success never substitutes for that review.

Bootstrap enforcement may use Python 3.11 and `jq` only through M0. Before M0
closes, the accepted Elixir/OTP implementation must preserve the behavioral and
mutation-test corpus while removing both prerequisites. The enduring local
baseline is Git, shell/POSIX tools, and the accepted Elixir/OTP toolchain.

Client files remain adapters. They import or route to `AGENTS.md`, this charter,
and the context map; they may add discovery, invocation, permissions, hooks, and
profiles but no independent methodology. A client change that could alter
development behavior is checked against current primary documentation and
observed installed behavior before shared consequences are proposed.

<a id="technical-change-control"></a>
## Pair Lifecycle and Change Classification

Concept: [Changing this charter](development-charter.md#concept-change-control).

This charter pair is governed by the explicit current maintainer decision that
created it. Later material changes to authority, acceptance, trust, permissions,
evidence, autonomy, parallelism, project-state semantics, or required operator
attention are proposed and paused with options, implications, compatibility or
migration impact, and a recommendation. A reversible compatibility correction
may proceed when it preserves effective behavior.

Vision changes have an additional scope guard: either `docs/vision.md` or
`docs/vision-technical.md` may be edited only when the current maintainer or
developer request explicitly names a vision change. General documentation,
alignment, refactoring, or implementation work does not grant that scope.
Explicit scope does not waive the decision and evidence needed to reverse a
founding boundary or invariant.
