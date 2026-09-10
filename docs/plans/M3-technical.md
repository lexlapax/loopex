<a id="technical-depth"></a>
## Technical depth

Concept: [Extensible local foundations](M3.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M3.md#concept-plan-scope).

Concept: [non-goals](M3.md#concept-plan-non-goals).

The base is integrated M2 at
`b637873ddc39542ec27add71015b46a4f7c7f80e`. Merge it into the existing M3 history;
do not discard bound candidates by rebase or squash. Prove bootstrap and every
Closed gate on the refreshed base and the candidate's distinct capability red.
M3 stays Open until a fresh exact-candidate review and explicit acceptance.

The acceptance packet settles these proposals before dependent implementation:

| Decision | Owner and acceptance point | Effect |
| --- | --- | --- |
| [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | Maintainer, before M3 acceptance | Session-owned defer and response lifecycle; M4 only maps it |
| [ADR 0025](../adr/0025-resource-packs-and-skill-admission.md#concept) | Maintainer, before M3 acceptance | Narrow extension of ADR 0010 resources and ADR 0017's single optional block proof; acquisition, trust, retention and progressive activation |
| [ADR 0026](../adr/0026-development-floor-refresh.md#concept) | Maintainer, before M3 acceptance | Deliberately chosen distinct floor/current pairs, then sequential Closed-gate generations |
| [ADR 0027](../adr/0027-provider-permit-retirement.md#concept) | Maintainer, before M3 acceptance | Narrow supersession of ADR 0018's whole-generation spent-reference retention |
| [ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept) | Maintainer, before M3 acceptance | Range access with bounded allocation and honest object/use integrity |
| [ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept) | Maintainer, before M4 acceptance | Protocol decision, not an M3 prerequisite |

Settle the floor before M3 is accepted and binds `.tool-versions`. The change
requires three sequential v2 gate-generation transactions for Closed M0, M1 and
M2, not an avoidable fourth self-amendment on Accepted M3. Each proposal and its
immediate rebind child retain the exact evidence required by AGENTS.md; old
Acceptance and Closure records stay immutable. The M0 diagnostic correction and
any still-needed bound isolation-test repair join the applicable holder's
proposal only if their complete bytes and meaning have been reviewed together.
No product work or parallel bound-byte edits enter those transactions. The
planning checkpoint itself changes neither toolchain pins nor Closed gates.

A floor decision does not waive any matrix lane. The proposed floor is Elixir
1.18.5/OTP 27.3.4; current remains 1.20.3/29.0.5. These are explicit pins, not a
claim that they are today's newest patches. Re-prove Darwin floor/current and
Linux current. If the packet cannot be accepted, resolve the plan prerequisite
with the maintainer while Open; implementation must not improvise a substitute.

### Complete readiness packet

Before acceptance, all future protected tests and exact boundary vectors exist
and can execute against the unchanged base. Their failures must be the stated
missing behavior, never undefined helpers, incomplete runners, unavailable
dependencies or governance status. The existing runner retains the superseded debt-only probe. This documentation
revision implements no gate code and supplies no new behavioral red. All
selector, suite, evidence and opening-probe lanes must be completed while Open
and reviewed before their lock. No lane is completed by milestone product
implementation.

Each outcome has one obligation row recording: operator result; public entry;
owner; authority input; durable identity; transaction/recovery cuts; bounded
resource; expected refusal; exact test witness; attended evidence; compatibility
and rollback. Resolve conflicting ADR clauses, configuration propagation and
error semantics in that row before the first implementation task is assigned.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin Barriers

Concept: [Scope](M3.md#concept-plan-scope).

| Slice | Owned boundary and paths | Rejoin evidence |
| --- | --- | --- |
| Prerequisites | Maintainer dispositions, ADR pairs, affected Closed gate generations | All prerequisite transactions settled and inherited green proof on exact source |
| Resources | `loopex_composition` host resource resolver/importer; core fixed admission and context staging; CLI commands | Reference and explicit host root agree; exact selected bytes reach staged model input; no path or network access enters core |
| Interactions | Core input algebra, reducer, coordinator and policy evaluator; CLI presentation | One durable winner under answer/expiry/abort/deadline; policy allow precedes executor intent |
| Queries | Public facade plus Store artifact implementation | Resources are separately retained; artifact use identity and streaming full-object verification precede bounded range delivery |
| Repairs | Context admission, event dispatcher and Control | Generated bounds, held-Store availability, retired-permit refusal and successor safety |
| Integration | Composition, CLI and evidence fixtures | Same semantics through both entries, real effects and fresh-process reconstruction |
| Gate protection | Repository scripts and test-honesty witnesses | Acyclic inherited invocation, exact regression lock and decisive mutations |

The integration order is: prerequisites → one thin vertical workflow → bounded
feature expansion and independent repairs → integrated self-audit → final
independent review. Parallel work is optional and follows AGENTS.md isolation
and ownership rules; it creates no additional acceptance or milestone gates.

The first integrated workflow uses one small pinned skill, one selected
supporting resource, one existing host-registered tool, policy defer/answer, a
real local executor result and bounded artifact read. Capture actual staged
provider input and restart a separate process against the real local Store.
Run through direct embedding and the shipped CLI, including the built CLI and
provider companion outside the source directory. Do this before registry breadth,
UI polish or additional skill formats. M4's projected DTOs must be representable
from these results, but M3 implements no wire server.

The shared model/executor launch options are trusted host data. Resolve them
once in composition and preserve them through prepared recovery. Existing
provider protection and explicit participant handoff remain the actual path;
no hidden process dictionary, VM-global logger substitution or bypass fixture.

### Transaction and failure matrix

| Boundary | Required state cuts and negatives |
| --- | --- |
| Fetch/install | Allow/deny/cancel/timeout; source resolves to different commit; truncated download; cap exceeded; redirect policy; link/special file; interrupted atomic publication; existing destination; no script or hook execution |
| Trust/context | Missing/stale/revoked decision; catalog addition/removal; changed bytes after discovery; manual-only selection; duplicate name; unsupported field; required-only fit/fail; aggregate tokens/bytes/depth/cardinality; no partial instruction truncation |
| Interaction | Before/after request, response, resolution, grant and intent commits; commit_unknown at each; duplicate/conflicting answer; expiry vs abort/deadline; second defer; changed policy identity; owner loss; no effect before allow |
| Provider | Exact staged content vs dispatch authority; before/after permit spend; ambiguous open attempt; settled old attempt replay after retirement; successor fencing; preserve usage-v2 provenance |
| Dispatcher | Held Store, asynchronous read result after detach or replacement, stale owner/cursor, overflow, blocked observer, bounded acknowledgement and ordered publication |
| Artifact | Object/use mismatch, cross-session reference, absent object, corruption before and after range, zero/last/over-range, concurrent read, bounded memory and descriptor cleanup |
| Host lifecycle | CLI/embedding configuration equivalence; abrupt parent VM loss; graceful cancellation; second interrupt; prepared transfer; late completion; provider companion identity and actual process exit |

An interaction cancelled during graceful shutdown stays cancelled. The restart
proof resumes retained pending/answered state after abrupt loss, not a question
already resolved by the shutdown contract. Creation and expiry instants are
chosen once before their transaction and retained through uncertainty; a retry
never changes a mutation digest by reading the clock again.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M3.md#concept-plan-outcomes).

The gate's future data manifest is the single executable selector inventory. Re-derive
M2 repair case identities from integrated source, not the old 79-case snapshot.
Existing locks stay intact. Lock repaired-path cases by actual ExUnit identity
and state and run them through `scripts/m1-exunit-runner.exs`; deletion, rename,
skip or exclusion fails. Counts support identity checks and are not a delivery
objective. A test's file digest may bind the inherited snapshot only while the
candidate is Open; before acceptance, bind its identities rather than freeze
bytes M3 must extend.

For each outcome retain the following additional proof:

1. **Acquisition:** actual local Git and loopback HTTPS source, including exact
   commit/content identity and interrupted publication. An attended public-source
   import proves the network path; online availability is not a deterministic
   gate dependency and a cached import is not that proof.
2. **Context:** generated lists through cardinality 1,024; full maximal receipt
   shape; whole-block withholding across all four admission dimensions; actual
   staged bytes and digests before/after restart; no source reread for a retained
   request. No provider redispatch inferred from retained bytes.
3. **Interactions:** reducer properties plus real Store cuts and a fresh-process
   answer-to-authorized-effect trace. Answer admission and policy authorization
   are separately observed.
4. **Common foundations:** CLI and embedded workflow, genuine model/tool task,
   resource/artifact inspection, trusted launch configuration and source-built
   CLI/companion identities. Artifact range checks measure peak allocation, not
   only output frame size.
5. **Repairs:** required-only lower-bound properties and historical refusal
   replay; bounded unrelated-session control under a held Store; long-history
   permit-retention observation with hostile late requests and succession.
6. **Inherited protection:** register-derived gate enumeration; missing/red gate
   and omitted-invocation negatives; no bootstrap recursion; cross-VM scratch
   allocation; mutations of known repaired failure clauses and sibling branches.
7. **Closure:** exact source/gate/toolchain/platform/seed/limits; real-path build
   identities; old-reader positive controls and refusal of new records before
   effects; every documentation row; integrated audit and independent review.

### Review workflow that addresses M2's failure pattern

- Review the contract/ownership matrix and the first integrated workflow before
  broad implementation. Each slice ends with production-boundary proof and a
  focused diff review; final review should not be the first composition check.
- Every negative test first proves that it reached the intended boundary. Use
  actual values, captured requests, receipts and liveness witnesses. Source text,
  configuration literals, startup failure and a short silent interval cannot
  substitute for the behavior claimed.
- Preserve legacy guarantees while extending tests. Before gate amendment or
  closure handoff, apply the repository mutant-hunt procedure to each changed
  obligation and adjacent failure path. Surviving meaningful mutants block that
  handoff until repaired or explicitly dispositioned.
- A repeated finding class triggers an audit of all entrypoints and sibling
  transitions in that class. Resolve its root cause and update the obligation
  map once; do not turn serial reviewer comments into the implementation plan.
- Before final review, the implementer audits contracts/composition, lifetime,
  test honesty, trust/diagnostics, toolchain/build/rollback and documentation as
  one product. Freeze clean source S, run required lanes serially, and retain
  evidence naming S. Evidence-only descendants name their source; they never
  back-project a result onto different bytes.
- Relevant product/configuration/schema changes invalidate their affected
  evidence and review. Shared ownership or unknown impact means the full gate.
  No fixed number of review rounds, weakened gate or retry-to-green rule is
  introduced. Environment failure remains unavailable evidence.

### Acyclic gate ownership

The outer repository entrypoint `scripts/check-closed-gates.sh` reads the
register and invokes each Closed gate's exact command. Closed leaf gates may
call bootstrap; bootstrap never calls the aggregate. The active M3 runner calls
the aggregate once. A structural check and adversarial test verify the active
runner's mandatory call and reject a bootstrap back-edge. Hosted CI may call
that entrypoint and owns no additional acceptance semantics. When M3 closes,
its inherited invocation is a bounded prefix of predecessors, excluding itself;
a future aggregate must not recursively execute the same Closed gate. Prove
this transition before acceptance with a synthetic register containing Closed
M3 and a successor. No skip environment variable suppresses required gates.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Scope](M3.md#concept-plan-scope).

New resource/activation and interaction command variants, resource queries and
bounded artifact reads are experimental additions to the public facade. Core
receives canonical plain data; YAML, URLs, paths and host selection stay at the
edge. New resource and interaction durable records are versioned, never hidden
optional changes to a closed exact record shape. Existing AGENTS.md and M2
refusals replay unchanged. ADR 0025 owns optional-resource structural admission;
ADR 0027 changes retention, not the provider attempt or accounting algebra.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M3.md#concept-plan-scope).

Preserve M2 roots and prove a new reader can replay genuine M2 histories. New
M3 records use fresh task roots during development. An old binary is not a
rollback plan for a root containing unknown new records: prove it refuses
before dispatch with an unchanged historical prefix, alongside a genuine
old-format positive control. Return to the retained pre-upgrade root/binary
pair; do not delete or rewrite operator history. No in-place downgrade promise.

Resource installation publishes into a host-owned retained-pack directory by
atomic rename only after complete validation. Interrupted imports leave the
previous installed pack intact; cleanup affects only task-owned staging.
Already staged context remains available independently of installed-pack
removal. No fallback reread or refetch changes a retained request.

Floor and gate rollback follow new accepted transactions, not Git reversion of
immutable authority records. Artifact API changes are additive with the old
fetch path retained; exact ADR 0015 object/use identity remains unchanged.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M3.md#concept-plan-scope).

Eight umbrella applications and existing roles remain. Resource parsing and
acquisition live in the host/composition and hand; core and protocol remain
stdlib/OTP only. Use the existing executor command job for explicitly authorized
Git acquisition, with argument vectors and a closed environment; HTTPS uses the
existing edge dependency closure. No new external library, generic YAML runtime
or executor job kind is authorized. Support the bounded Agent Skills frontmatter
subset explicitly; reject unsupported YAML constructs with a useful diagnostic.
Git is a prerequisite for Git import only, probed before side effects.

The existing CLI and private provider companion gain source-built foundation
commands and examples. Root VERSION and application versions remain the M2
values. No tag, release, package publication or installation service is created.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M3.md#concept-plan-scope).

Justified growth is the fixed skills resource class, one durable interaction
slice, bounded query plumbing, host resource acquisition and three direct core
repairs, plus necessary evidence. Use existing Store transactions, policy and
executor jobs rather than a second workflow engine. Keep one admission owner,
one manifest format and one activation path across CLI and embedding.

No new application/role, external production dependency, generic pipeline,
transport abstraction, plugin loader, worker pool, retention-policy framework,
or second session reducer. Resource/interaction limits are concrete in the ADR
proposals; toolchain and gate prerequisites are settled before locking them.
Do not impose arbitrary line caps that reward compressed code or lost evidence.
Review code growth against actual reused boundaries and delete obsolete paths.
<!-- loopex:plan-technical-envelope:end -->

## Research and Scope Rationale

Research reviewed for this proposal on 2026-09-09 distinguishes portable
resource directories, discovery catalogs and hosted services:

- [Agent Skills specification](https://agentskills.io/specification) defines
  SKILL.md metadata, instructions and optional supporting files. Its
  [client guidance](https://agentskills.io/client-implementation/adding-skills-support)
  informs discovery, explicit selection and progressive loading. Compatibility
  is a declared tested subset, not permission to inherit every vendor field.
- [skills.md documentation](https://skills.md/docs) describes hosted execution
  through service interfaces. Downloadable resource packs meet M3's local
  foundation outcome; adding a hosted execution provider is separate scope.
- [skills.sh](https://skills.sh/) and the
  [Vercel installer source](https://github.com/vercel-labs/skills/blob/main/src/local-lock.ts)
  inform distribution and local lock/provenance. The previous blanket claim
  that this installer carries no checksums or provenance is incorrect: its
  lock records source information and a computed content hash.
- [GitHub CLI skill installation](https://cli.github.com/manual/gh_skill_install)
  illustrates explicit sources and pinned revisions. Loopex still makes its own
  acquisition, containment, retention and trust decisions.
- [SkillsMP](https://skillsmp.com/) is a discovery index, and
  [Tessl evaluation](https://docs.tessl.io/evaluate) supplies evaluation signals;
  neither is a runtime authority or substitute for Loopex's negative tests.
- [Claude Code skills](https://code.claude.com/docs/en/skills) include richer
  execution and invocation semantics. Preserve manual-only restrictions and
  diagnose unsupported execution fields; do not import tool permission grants.
- [OpenClaw skills](https://docs.openclaw.ai/skills) illustrates another skills
  and registry ecosystem. Package discovery and trusted code activation remain
  separate decisions in Loopex.

A skill is the first resource-pack capability, not the definition of the whole
foundation milestone. Durable interactions, resource identity, bounded artifact
access, explicit launch wiring and safe core availability/retention are the
other shared requirements that would otherwise be discovered while building M4.
