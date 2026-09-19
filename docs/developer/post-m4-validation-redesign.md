# Post-M4 validation redesign

<a id="concept"></a>
## Concept

Technical depth: [Verification profiles, transition, and audit evidence](post-m4-validation-redesign-technical.md#technical-depth).

Discussion proposal, rewritten as one system on 2026-09-18. It changes no active
M4 requirement and grants no waiver, implementation, or release authority.
Begin the transition only after the agreed M4 work finishes.

<a id="concept-post-m4-decision"></a>
### 1. Decision and purpose

Replace accumulating milestone gates with one evolving product suite, a short
verification guide, and source-bound acceptance evidence. Preserve what the
product promises. Let its implementation and the means of testing it change.

The maintainer has selected:

- A whole-system redesign, including tests, execution, and amendment rules.
- Protection of approved checkpoints and new changes, without permanent semantic
  validation of every intermediate development commit.
- One local regression run for ordinary integration. Expensive checks run before
  closure or release and earlier when affected.

The design must accommodate frequent architectural changes and aim for
verification to consume approximately 15-20% of development time. The reported
80-90% current share has not been independently measured.

Two details remain recommendations, not approved instructions: normal review for
maintenance that preserves requirements, and counting all verification work in
the percentage. Section 4 defines the proposed approval boundary; section 5
defines the accounting. Approval of the forward policy must resolve both.

Technical depth: [Current checks without a permanent history engine](post-m4-validation-redesign-technical.md#technical-post-m4-history).

Technical depth: [One transition, five implementation steps](post-m4-validation-redesign-technical.md#technical-post-m4-transition).

<a id="concept-post-m4-diagnosis"></a>
### 2. The problem is accumulated procedure, not capability progression

The milestones add useful product guarantees:

| Milestone | Distinct guarantees worth carrying forward |
| --- | --- |
| M0 | Replay and uncertain-effect fencing, dependency isolation, and foundational feasibility evidence. |
| M1 | Durable sessions and Store transactions, ownership fencing, authorized execution, event delivery, and recovery without duplicate effects. |
| M2 | The coding loop, budgets, tools, streaming, artifacts, trust, cancellation, CLI, and resume. |
| M3 | Pinned skills, provenance, context admission, common host workflows, dispatcher availability, and permit fencing. |
| M4 | External clients and protocol agreement, durable policy interactions, verified transfers, bounded delivery, observability, and source installation. |

The problem is making each historical gate both an immutable acceptance record
and a validator of every future implementation. Shared helper changes then
require old-holder amendments, while successor gates rerun their predecessors.

Static tracing finds eight ordinary suite invocations, eight bootstraps, and
twelve full status validations in the audited M4 path. M4 calls M0-M3; M3 calls
M0-M2 again. Protected selectors also repeat ordinary-suite cases. The status
checker enforces procedural validity across 1,194 reachable commits. A corrected
intermediate mistake can still invalidate the final branch.

These costs follow from the same ownership error. Historical milestones should
own historical evidence. The current product should own current tests. Completed
feasibility experiments need not become permanent regressions unless current
behavior still depends on their claims.

Technical depth: [Evidence supporting the proposal](post-m4-validation-redesign-technical.md#technical-post-m4-evidence).

<a id="concept-post-m4-progression"></a>
### 3. One progression and one evidence-reuse rule

A gate is an approval point, not a new test framework.

| Stage | Decision and checks |
| --- | --- |
| Agree on the work | Approve outcomes, important boundary changes, and the verification approach. Use the approved baseline. Do not prebuild and lock every future selector, runner, or report format. |
| Develop and integrate | Run focused checks during editing. For a coherent product integration candidate, run the local profile once and any affected qualification profiles. No new maintainer ceremony for each edit. |
| Accept the milestone | Review the integrated candidate against its outcomes. Complete required qualification and the operator workflow. Reuse matching integration evidence under the rule below. |
| Publish, if authorized | Verify the approved source and actual artifact, and complete outstanding packaging proof. Permission remains separate; permission alone does not require retesting the product. |

**Evidence-reuse rule:** a required profile needs one successful result for its
candidate inputs and environment. Closure can use the integration result when
those inputs match. Release can use the closure result when those inputs match.
Preserve the source identity where the command actually ran; never relabel reused
evidence as a new execution.

Reuse depends on each profile's actual inputs, not a "documentation-only" label.
A narrow diff can preserve product results when code, tests, fixtures, dependency
locks, execution configuration, and relevant toolchain are unchanged. However,
operator commands, schemas, generated content, and archive contents can be inputs
to workflow or source qualification. Those affected profiles need renewed proof
even when product results remain reusable. Publication evidence always identifies
the actual published archive, not an earlier archive's digest.

Product or execution-input changes require the affected profiles again; a new
product integration candidate receives the local profile. Relevant external
changes, including provider configuration, can also invalidate evidence. When
equivalence is uncertain, rerun the affected profile. No generic cross-commit
cache or automatic impact engine is required.

This removes duplicate integration-to-closure runs as well as predecessor
recursion. It does not prohibit focused reruns during development or overlap
where a different environment or interaction proves a distinct claim. Missing
prerequisites and incomplete runs remain unavailable, never green.

Technical depth: [What runs, and when](post-m4-validation-redesign-technical.md#technical-post-m4-profiles).

<a id="concept-post-m4-changes"></a>
### 4. Evolving architecture and proportionate approval

The proposed review policy separates promises from implementation choices:

| Change | Proposed treatment |
| --- | --- |
| Refactor internals, repair a runner, improve isolation, or replace an equivalent test | Change code and tests together under ordinary review. Preserve current requirements. No historical milestone amendments. |
| Change ownership, persistence, trust, a public contract, or an accepted architecture decision | Obtain one explicit decision, with compatibility and migration evidence where needed. Implement within it without repeatedly approving the same choice. |
| Reduce required evidence, defer an outcome, or weaken a guarantee | Obtain explicit maintainer disposition. Calling a change an optimization does not exempt it. |
| Accept a milestone or publish a release | Retain maintainer authority and the exact reviewed source. |

Review the effect of changed tests, not merely the author's claim of equivalence.
Keep behavioral assertions such as stale owners cannot commit. Let obsolete
assertions about private fields, source spelling, application counts, and helper
layout change with their design. A source tag does not freeze every internal
interface; supported external and persistent contracts retain their stated
compatibility protection.

Moving runtime modules selects runtime tests. Adding an edge application selects
dependency direction, reusable port conformance, and one composition workflow.
Replacing a Store selects transaction and recovery conformance, real-backend
faults, and migration tests if existing roots are affected. Each then follows
section 3. None requires repairing historical gate generations.

Guard agents through bounded scope, permissions, dependency checks, review of code
and test changes, and behavioral evidence. Accept that unfinished commits may be
procedurally inconsistent. We no longer claim every development step followed
every rule. A same-repository checker cannot authenticate human approval or
prevent a malicious writer from altering the checker; permanent history policing
should not substitute for external controls.

Technical depth: [Test design and concurrency serve the same contract](post-m4-validation-redesign-technical.md#technical-post-m4-tests).

<a id="concept-post-m4-cost"></a>
### 5. The 15-20% target must include the work we remove

Measure across a milestone, not as a hard stop for each change. The recommended
accounting includes test development and maintenance, gate tooling, verification
review and approval bookkeeping, execution, and blocked waiting. Report these
categories separately rather than excluding inconvenient costs. The maintainer
has not yet selected this denominator over gate-overhead-only accounting.

Use command timings and rough work-chunk estimates, not a time-tracking service.
Report effort separately from elapsed waiting; overlapping agent and machine
work must not be added twice to wall-clock development time.

The main reductions follow directly from the model: fewer historical transactions,
no routine history audit, no recursive suites, less duplicated setup, and tests
that survive refactoring. Parallelism addresses remaining execution bottlenecks.

The target is not a demonstrated speedup. If verification takes 85 hours and other
development takes 15, a 20% share with those same 15 hours permits 3.75 hours of
verification. That example needs about a 23-fold reduction. Eight-to-one suite
deduplication alone cannot establish it.

If measured cost remains excessive, simplify the largest remaining cause or
explicitly reconsider expensive support commitments. Do not stop required tests
at the budget limit, hide failures, or call incomplete work passed. Risk-heavy
changes can exceed the average without making their exceptional procedure the
default for every later change.

Technical depth: [Evidence supporting the proposal](post-m4-validation-redesign-technical.md#technical-post-m4-evidence).
