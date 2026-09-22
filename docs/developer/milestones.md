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
outcome. Here `Proved` maps completed implementation to a named proof
obligation; it does not claim that a closure run or review performed after the
commit already has a result. Those later results and identities occupy the
scaffold's predeclared `Pending` fields. The same candidate commit moves the
register and its two marked status blocks from `In progress` to `In review`.
It also carries the indexed evidence-page scaffold that closure will fill.
From that exact commit run the fast check under the floor toolchain pair and
the release check once; ask an independent reviewer to read the candidate;
then present the packet to the maintainer. The maintainer closes it; the
administrative direct child makes only the `In review` to `Closed` transition,
the plan records the closing decision and the tested implementation SHA, and
that commit fills the existing evidence page with the run and review
identities, retained-output references, and SHA-256 digests, plus every
plan-required outcome field or placeholder the tested scaffold predeclared.
The release check's fresh-source lane stages the tested archive under the
[canonical archive-extraction rule](milestones-technical.md#technical-milestones-archive-extraction).
Use the `close-milestone` skill.

**Closure names two commits, because one cannot name itself.** The checks and
the review are of a **tested implementation commit**; recording the closure is
a further commit that necessarily comes after, and that the evidence therefore
cannot have been taken from. The tested commit carries the indexed evidence-page
scaffold; the administrative commit fills it with runs *of* the tested commit.
Earlier wording created the page in the second commit, which also required its
index to change and broke the confinement rule then in force.
So a closure carries the **tested implementation SHA**, which the runs and the
review name, and the **administrative closure SHA**, which records the
decision as the tested commit's direct child. That second commit is
**confined to five paths and the exact administrative region in each** — the
register row and supplied marked status block, the plan's Closure row, an appended
context-map disposition, the evidence scaffold's designated placeholders and
the root README's supplied marked status summary — which
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
closure commit, reusing the closure evidence when implementation source is
unchanged and re-proving the administrative documentation. A
package, installer or publication is its own decision with its own evidence.

The two-commit closure and tag procedure below governs M5 and later
milestones. Earlier closures and tags remain governed by the procedures their
records name; the existing `v0.1.0` tag identifies M4's integrated source
commit and is not retrofitted to this later procedure.

**The tag names the administrative closure SHA**, which is the commit that
carries the closure record and therefore the tree a reader who fetches the tag
gets. That is only safe because the administrative commit is confined to
[its five paths and allowed regions](milestones-technical.md#technical-milestones-confinement),
and the release step verifies that rather than trusting it: a name-only diff
must name exactly those five, and the retained complete patch must map every
changed byte to the named region in its file. A diff that reaches anything
else means the tag would publish source the
closure evidence does not cover, and the release stops. The root README is the
only confined path outside `docs/`; it is reconstructed as the tested file with
only its marked block replaced, then checked byte-for-byte as well as by
`check.sh --docs`, including that command's `mix loopex.status` step.
The plans index is reconstructed separately from the tested file by replacing
both its exact milestone register row and its marked Current Status block.

**Four pre-tag proofs run before the tag exists, and none is a second closure.** The
administrative tree differs from the tested one only in documentation, so
`bash scripts/check.sh --docs` runs on the administrative SHA. The final
semantic documentation gate then reads the relevant `docs/operator/` and
`docs/developer/` pages from that same SHA. From M5 onward, the archive
manifest is also recomputed from a fresh `git archive` extraction staged under
the technical guide's
[canonical archive-extraction rule](milestones-technical.md#technical-milestones-archive-extraction)
by the M5-delivered repository-owned `scripts/source-archive-manifest.sh` command
whose exact NUL-delimited output the tested run retained. Before exclusions,
each archive's complete `(kind, mode, path)` projection must match its commit's
independent Git-tree projection, and the tested and administrative projections
must match each other. Every entry outside
`docs/`, except the root `README.md` and the M5-delivered `SOURCE_IDENTITY`,
must match the tested archive entry. The
README is validated by the marked-block confinement proof and
documentation/status checks. Each archive's
`SOURCE_IDENTITY` differs by design and must name that archive's own commit and
source identity correctly.
This comparison catches archive inclusion or exclusion changes that
`.gitattributes` can cause without a path appearing in the commit diff. No
suite is re-run, no release check is re-run, and no provider credential is
spent again.

**Run evidence is immutable.** Complete closure-matrix outputs stay outside the
repository; the administrative commit records their retained-output references
and SHA-256 digests on the existing evidence page. Complete release-proof
outputs also stay outside the repository; the tag annotation records their
results, retained-output references, and SHA-256 digests when the tag is
created. The evidence page never changes after the administrative commit, and
the tag never predates evidence named by its annotation. This sequence needs
two commits and one tag, with no third commit.
Technical depth: [Tags](milestones-technical.md#technical-milestones-release).

### The skills

Four repository skills carry the procedures: `open-milestone` and
`close-milestone` require explicit invocation because no actor may open or
close its own milestone; `adr` prepares a decision proposal; `mutant-hunt` is
an optional technique for judging how strong a guarantee's tests are.
