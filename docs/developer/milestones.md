# Milestones

<a id="concept"></a>
## Concept

Technical depth: [Milestone mechanics](milestones-technical.md#technical-depth).

A milestone is bounded work with one plan pair, one closure and, if the
maintainer decides so, one release. This page is how to plan one, run it and
close it under the post-M4 structure; the checks a change must pass are in the
[verification guide](verification.md#concept). There is no gate script, no
locked test corpus and no amendment transaction: the plan says what will be
proved and by which tests, the suite proves it, and the maintainer decides.

<a id="concept-milestones-agree"></a>
### Agree

A milestone starts with a plan pair in `docs/plans/`: `NAME.md` owns the
purpose, the numbered outcomes, the scope and non-goals, and the design
decisions; `NAME-technical.md` owns, for every outcome, how it will be
verified — which tests, which real-path proof, which demonstration — plus the
ownership and rejoin order if workstreams will run in parallel, and the
compatibility, migration and rollback expectations. A decision about
ownership, transactions, trust, a public or cross-application contract,
persistent schema, a major dependency, the runtime floor, migration or
packaging is an ADR, proposed with the plan and accepted before the outcome
that depends on it is implemented.

Size the milestone so that its outcomes can each be proved by tests that exist
by closure. The register in `docs/plans/README.md` lists it as `Open`; the
maintainer's acceptance moves it to `Accepted`. Use the `open-milestone`
skill to write the pair.
Technical depth: [Plan pair contents](milestones-technical.md#technical-milestones-agree).

<a id="concept-milestones-develop"></a>
### Develop

Work lands on `main` in small reviewed changes: each one passes the fast
check in CI and an independent read of its diff, as the verification guide
sets out. A milestone branch is the exception, for a slice that cannot be
merged safely in pieces; it is short-lived and rejoins `main` the same way.
Parallel workstreams use one worktree per writer with non-overlapping paths
and one integrator.

Write the first integrated workflow early, then add boundary and failure
cases as the implementation reaches them. Keep the plan's progress table
current: each outcome's row names the tests that prove it so far. Changing
an accepted plan is an ordinary reviewed change to the pair that records, in
the progress section, what changed and why; a change that drops an outcome or
adds scope is the maintainer's decision.
Technical depth: [Branches, worktrees and progress](milestones-technical.md#technical-milestones-develop).

<a id="concept-milestones-close"></a>
### Close

A closure candidate is one commit on `main` at which every outcome maps to
tests, retained evidence or a demonstration, the documentation the milestone
changed is updated, and the plan's progress table says Proved for each
outcome. From that exact commit run the fast check under the floor toolchain
pair and the release check once; ask an independent reviewer to read the
candidate; then present the packet to the maintainer. The maintainer closes
it; the register moves to `Closed`, the plan records the closing decision and
the tested implementation SHA, and the run identities are written to the
milestone's evidence page
— by that closing commit, since the runs are of the candidate and the
candidate cannot carry runs of itself. Use the `close-milestone` skill.

**Closure names two commits, because one cannot name itself.** The checks and
the review are of a **tested implementation commit**; recording the closure is
a further commit that necessarily comes after, and that the evidence therefore
cannot have been taken from — the runs are *of* the tested commit, so the
evidence page that holds them is written by the second, not the first. Earlier
wording asked for both from one SHA, which no sequence of commits can satisfy.
So a closure carries the **tested implementation SHA**, which the runs and the
review name, and the **administrative closure SHA**, which records the
decision. That second commit is **confined to four paths** — the register row,
the plan's Closure row, the context-map entry and the evidence page — which
the [technical companion](milestones-technical.md#technical-milestones-confinement)
states once and everything else refers to. A closure whose administrative
commit touches anything else is not administrative, and its evidence is
stale.

The closure matrix is run **once**, from the tested implementation SHA, and
nothing in closure is re-run because of the administrative commit. What that
commit can invalidate is a matter for the release, which is where the tag
exists; Close states the two SHAs and their relation and stops there.

Technical depth: [The closure packet](milestones-technical.md#technical-milestones-close).

<a id="concept-milestones-release"></a>
### Release

A release is a separate maintainer decision: a tag on the exact integrated
closure commit, reusing the closure evidence when the source is unchanged. A
package, installer or publication is its own decision with its own evidence.

**The tag names the administrative closure SHA**, which is the commit that
carries the closure record and therefore the tree a reader who fetches the tag
gets. That is only safe because the administrative commit is confined to
[its four paths](milestones-technical.md#technical-milestones-confinement),
and the release step verifies that rather than trusting it —
`git diff --name-only <tested>..<administrative>` against exactly those four.
A diff that reaches anything else means the tag would publish source the
closure evidence does not cover, and the release stops. All four are under
`docs/`, so a passing check also establishes that nothing outside `docs/`
moved; that is a consequence of the confinement, not a second rule.

**Two checks run at the tag, and neither is a second closure.** The tagged
tree differs from the tested one only in documentation, so what is re-proved
is documentation: `bash scripts/check.sh --docs` runs on the tagged SHA, and
the archive manifest is recomputed from the tagged SHA and compared with the
one recorded on the evidence page for the tested SHA, **entry by entry
outside `docs/`**, which must match exactly. It is not compared whole — the archive carries `docs/` too, so
a whole-manifest equality could never hold and would be a check that always
fails. Comparing the rest is what catches an archive that includes or excludes
differently from the tree the first step examined, which `.gitattributes` can
do without any diff showing it. No suite is re-run, no release check is
re-run, and no provider credential is spent again. Their results join the evidence
page with the tag named.

**Run evidence is immutable.** A run's identity, platform, toolchain, result
and duration are retained where they cannot be edited after the packet is
read: attached to the annotated tag once it exists, or — for everything
produced before the tag, which is all of the closure matrix — held outside the
repository with its digest recorded on the evidence page. An evidence page
that can be rewritten after a reviewer read it is a record of what someone
later wished had happened.
Technical depth: [Tags](milestones-technical.md#technical-milestones-release).

### The skills

Four repository skills carry the procedures: `open-milestone` and
`close-milestone` require explicit invocation because no actor may open or
close its own milestone; `adr` prepares a decision proposal; `mutant-hunt` is
an optional technique for judging how strong a guarantee's tests are.
