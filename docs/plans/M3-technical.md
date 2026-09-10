<a id="technical-depth"></a>
## Technical depth

Concept: [Extensible local foundations](M3.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M3.md#concept-plan-scope).

Concept: [Non-goals](M3.md#concept-plan-non-goals).

The integrated M2 base is `b637873ddc39542ec27add71015b46a4f7c7f80e`, retained
as an ancestor without rebasing or squashing bound history. The maintainer's
independently reviewed
[M3 acceptance aggregate override](../developer/agent-context-map.md#override-disposition-m3-acceptance-aggregate-2026-09-10)
waives a new M0–M2 aggregate only at this plan-acceptance transition. Before
acceptance, prove the replacement validation named there: bootstrap, the complete
deterministic suite, the distinct behavioral red, every applicable runner mode,
the accepted-floor runner regression proof, exact bindings and independent
review. Record the aggregate as explicitly waived, not green or unavailable.
M3 stays Open until explicit acceptance of the reviewed plan pair and gate.

Only two new ADRs are M3 prerequisites:

| Decision | Owner and acceptance point | Effect |
| --- | --- | --- |
| [**ADR 0025**](../adr/0025-resource-packs-and-skill-admission.md#concept) | Maintainer, before M3 acceptance | Fixed project-skill class; runtime-control/Store acquisition truth; policy-authorized public Git hand; trust, pre-run selection, retention and optional-block admission. Solely for tagged runtime-control resource acquisition, it narrowly supersedes ADR 0007's universal session `JobRequest`; job/session/run/turn/tool-call/session-origin identities; tool-ID/tool-version grant bindings; executor accepted/started/progress event sequence; session-origin terminal-receipt tuple; session/coordinator-epoch reconciliation; ADR 0009's tool-call-only policy-request member set; and the corresponding universal wording in Concept vision section 15 and Technical vision sections 6.3, 8.4, 9.3, 9.4, 15.1 and 23.3. Exact runtime-control replacements are runtime/command/operation/attempt identity, original effect and current responder epochs, receipt-only completion, bounded status and Runtime Control reconciliation. Session epoch/origin remains mandatory for every session-owned effect; existing session jobs, grants, policy requests, events, receipts, reconciliation and oracle remain unchanged. |
| [**ADR 0027**](../adr/0027-provider-permit-retirement.md#concept) | Maintainer, before M3 acceptance | Safe retirement of whole-generation in-memory spent references under unchanged fencing and accounting |

Accepted M2 ADRs remain inherited constraints. ADRs 0023, 0024, 0026 and 0028
belong to M4: protocol, durable interactions, floor and artifact ranges. No floor
change or Closed-gate transaction is an M3 opening prerequisite. An
inherited restriction changes through its holder's transaction or an explicitly
scoped maintainer override under AGENTS.md. M4 must derive its own holder inventory, including
M3 if M3's accepted gate binds a file it changes. Deferral moves transaction cost;
it does not prove that only three holders will exist later.

**Approved CLI exception.** The maintainer's
[ratified scoped override](../developer/agent-context-map.md#override-disposition-m3-cli-extension-ratification-2026-09-10)
changes the continuing assertion in `cli_test.exs`: preserve the five inherited
commands and permit `skill` in M3. The old protected test name remains a
historical selector identity, not a permanent command ceiling. No Closed gate,
runner or bound-artifact bytes change and no additional amendment transaction
blocks the CLI workstream. That test owns the literal command inventory; its
historical name's no-wire/line-framing phrase was never asserted by its body.
Separate facade/dependency witnesses and this plan's no-protocol scope remain
required. This exception accepts no M3 product implementation.

**Complete readiness packet**

The current opening probe exercises required-only admission through real session
staging and retained Store receipts. It proves that one missing repair; it does
not prove skills work. Under the maintainer's
[ratified preparation-rule approval](../developer/agent-context-map.md#override-disposition-m3-incremental-witness-ratification-2026-09-10),
acceptance binds complete outcome clauses, exact contracts, witness identities,
checkpoint routing and executable closure commands. Test bodies and feature
fixtures are developed with implementation; they need not all exist before
acceptance. The first implementation checkpoint must demonstrate the integrated
skill workflow before feature breadth. A harness cannot supply missing product
behavior. Undefined helpers, compile failures and absent witnesses never supply
the opening red or a passing closure lane.

Each obligation row settles operator result, entrypoint, owner, authority input,
durable identity, transaction cuts, bounds, refusal, witness, compatibility and
rollback before implementation. Exact accepted commands and witness identities
are completed while Open. No unresolved contract is delegated to an implementer.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M3.md#concept-plan-scope).

| Slice | Owned boundary and paths | Rejoin evidence |
| --- | --- | --- |
| Resources | `Loopex.Runtime.start_link/1`, host-retained binding intent and Store pre-child snapshot binding; Runtime Control and Store acquisition/reconciliation/terminal records; host-owned canonical root/reference/lease, complete four-member launch envelope and fresh-attestation input; existing Policy port's acquisition variant; `Loopex.ResourceAcquisition` algebra; `Loopex.ResourceAcquirer` hand port and retained solicited response; `loopex_executor_local` Git/receipt/provenance implementation; composition wiring; core admission/staging; CLI commands and bounded recovery locator | Durable no-follow/no-replace/sync/reopen intent after exact-match attestation and before first Store call; atomic unused-identity binding or exact intent-authorized recovery before children; changed-source recovery-only behavior; confirmed command→intent→policy→bound grant/attempt→hand→terminal ordering; acquisition-version serialization; total one-open-operation lifecycle; exact public command/query replies and request/grant/original-attempt/current-responder lease/epoch/fence binding; restart-safe reconciliation without blind retry or automatic cleanup; safe fixed-parent creation plus sibling staging; atomic operation-owned prepared slot→no-replace publish→verified committed provenance; fresh runtime/trust for use; no root in records/core and no model/tool surface |
| Repairs | Context staging/admission, dispatcher and Control | Required-only properties, held-Store availability, retirement and succession negatives |
| Integration | Composition and CLI using existing policy, executor and ArtifactStore | Same configured skill/tool/artifact result through embedding and built CLI |
| Gate protection | Repository entrypoints, governance-history guard and behavioral witness manifest | Override authority predating acceptance across integration merges; focused checkpoint selection, acyclic inherited calls and truthful failure propagation |

One integrator owns rejoin and the exact candidate. Sequence: decisions and gate
readiness → one thin workflow → bounded expansion and independent repairs →
integrated self-audit → independent closure review. Parallel work follows the
repository isolation/ownership rules; workstreams have no separate gate. Each
parallel workstream rejoin runs the full inherited aggregate at its exact rejoined
revision before dependent work continues.

The first workflow starts with both fixed project parents absent, submits one
tiny pinned public-HTTPS project skill through a fresh administrative Runtime
Control, receives explicit host-policy allow, commits the exact attempt, and
drives the local hand through safely created parents, outside-discovery staging,
committed provenance and Store terminal truth. It loses one command acceptance
reply and recovers it through the pre-submit CLI locator without a second Git
effect. It then launches a different fresh runtime, rediscovers and newly trusts
that complete changed manifest, admits it, selects its
instructions and one already manifested supporting label, uses one existing tool
under ordinary allow/deny policy, and inspects the real artifact through the
existing full-object fetch. Capture actual staged model input and reconstruct
retained state in a fresh process, including imported provenance reattached only
from the source runtime's matching Store terminal, hand receipt, provenance record, current destination
identity and a complete fresh `.agents/skills` directory/file-set attestation.
Exercise direct embedding and the source-built CLI/provider companion outside the
checkout before breadth. No policy defer, range API or wire implementation enters
this M3 workflow.

**Transaction and failure matrix**

| Boundary | Required state cuts and negatives |
| --- | --- |
| Git/import | Host root/ref/lease issuance and revoke; one-open-operation/busy behavior; every exact ADR 0009 allow/deny/defer/unavailable mapping; every no-effect, pending-policy, attempt-open, reconciliation, terminal and quarantined transition; competing-Control version CAS; Store `commit_unknown` fences at binding, command, attempt, query, result and terminal cuts; exact acquisition/reconciliation/status input, reply, validation, replay and conflict behavior; exact command/intent/request/grant/attempt/query/local-admission/local-open/local-authority/retained-response/result/status/terminal/receipt shapes, digests, reason/nullability relations and replay; responder supersession and no-call replay after route change; request/grant equal deadline/expiry, overflow, original-attempt lease/epoch/current-responder lease/epoch/fence mutation; one-shot guard crash cuts, atomic admission/authority creation, and locked authority revocation before non-dispatch or unknown-outcome response; every later hand mutation conditional on active authority; collision-proof staging identity and conditional open-ledger replacement; canonical anonymous HTTPS-only source and closed Git through the counted transport, with closed global-unicast classification, complete DNS answer pinning and rebinding/private/reserved refusal; exact-commit/name mismatch; network/object/staging/file/process/output caps; safe first-parent creation, outside-discovery same-filesystem staging, links/gitlinks/special files; atomic prepared-slot contention plus prepared/no-replace/reverify/receipt/terminal cuts; existing/racing destinations; crash-safe lost CLI acknowledgement; separate acquisition/use runtime; normal-mode-only non-dispatch retry, recovery-only parking, in-flight retention, immutable unknown and post-unknown process-absence release without cleanup; no hook/filter/script/credential execution |
| Trust/context | Missing/stale decision; changed workspace/repository/provenance/bytes; canonical-or-nil secret-free repository origin; complete fresh-directory attestation including additions/removals; exact four-member launch envelope and match-authorized durable binding intent; exact match/changed/unavailable launch-attestation relations; recovery-only refusals and source-free settlement; directory/frontmatter name equality; paginated complete review and final-page confirmation; pre-run-only commands; manifested-label selection with explicit SKILL.md refusal and in-place same-skill replacement; canonical model-visible block framing; whole-block withholding; exact revision-3 receipt/detail/nullability relations; exact-count receipt reservation; fixed header/block first-failure order; resource-class arithmetic and unreachable internal class-token guard; zero-or-one single-workspace snapshot ownership with durable pre-child binding and current-binding recovery |
| Authority | Hostile allowed-tools/hooks/script pack; compare canonical tool registry, same ordinary-request policy result and grant set plus acquisition state before/after activation; byte-identical ordinary ADR 0007 job/grant/event/receipt/reconciliation/oracle and ADR 0009 request/decision/context before and after acquisition; no effect from resource commands; no model-originated acquisition or selection |
| Provider | Exact staged bytes vs dispatch authority, permit spend, ambiguous attempt, settled old identity after retirement, owner succession and settlement-v2 preservation |
| Dispatcher | Held Store, late result after detach/replacement, stale owner/cursor, overflow, unrelated-session acknowledgements and ordered publication |
| Existing artifact/host paths | Authorized full-object use and integrity checks; CLI/embedding launch equivalence, abrupt loss vs graceful cancel, prepared transfer, provider companion/process cleanup |

Resource commands require settled state before the next run and freeze a per-run
selection. Late model output cannot mutate it. Supporting requests choose only
existing manifest labels. Replay uses retained exact request bytes without
refetch or inferred permission to redispatch an ambiguous provider attempt. One
runtime serves one workspace identity and zero or one immutable snapshot. It
creates or matches `resource_snapshot_binding_v1` before children start. The
host supplies a separate bounded current attestation. Exact match permits
ordinary use; changed/unavailable state permits only retained inspection,
replay, reconciliation, active-run completion and source-free settlement. Every
new run/resource operation refuses before an authority boundary and requires a
new runtime identity. Nil/non-nil binding mismatch receives
`resource_binding_changed`. Before the first non-nil binding transaction, host
retention durably syncs and reopens the exact normalized snapshot and provenance
under its workspace and manifest identities; commit-unknown preserves it, and
every resume reloads and recomputes it before supplying the binding. Host
retention owns durable bytes and provenance, core holds the one normalized
snapshot until shutdown, and sessions retain indices/digests plus staged requests.
Launch or prepared resume may transiently hold the host input and core copy at
once; no session or second workspace receives another snapshot copy. A new
unstaged request after recovery requires fresh complete-directory discovery and
revalidation under the live workspace lease; the acquisition attempt fence is
separate. An old retained snapshot or isolated destination check alone is
insufficient. Already staged request bytes remain
independent of source.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M3.md#concept-plan-outcomes).

The Concept outcomes and gate obligation table use the same exact selector
paths. Lock one named decisive witness per required clause; one integrated case
may prove multiple clauses only when each has its own observed assertion.
Keep additional negatives in the ordinary required suite without freezing their
names, whole-file counts or exclusions. Adding or renaming an unprotected test
is not a gate amendment. Changing a protected obligation needs its amendment or
an explicit maintainer override. Existing Closed locks remain fully enforced
with only the recorded CLI assertion exception at required contract moments.

Do not freeze test-file bytes that M3 must extend. Bind canonical gate/harness,
fixture/vector and result-channel bytes present at acceptance; lock the
declared future protected tests by identity and
required runnable state. Deterministic and real-provider cases live in separate
files so no mutable mixed-file exclusion inventory becomes a lock. A protected
case that is missing, skipped or excluded fails. Counts are not a delivery
objective. Before acceptance refresh repaired-path clause witnesses against
`b637873ddc39542ec27add71015b46a4f7c7f80e`; do not inherit the obsolete 79-case
snapshot or freeze every test added since a moving historical revision.

1. **Acquisition:** drive real Runtime Control and Local Store through the complete
   one-open-operation lifecycle: busy/no-effect, pending policy, attempt open,
   reconciliation, every terminal and quarantined release. Lock exact command,
   intent, request, grant, attempt, query, response, result, status, terminal and
   receipt member sets, public input/reply/validation/replay/conflict behavior,
   canonical digests, reason/nullability relations and replay
   through every Store fault point and `commit_unknown` recovery. Prove the
   acquisition-version CAS against competing Controls, deterministic transaction
   identity, retained hand response, restart reconstruction, responder
   supersession, no-call replay after responder change, and unchanged attempt/fence
   on query/result commits. Lock the exact local admission/open record member sets,
   keys, phase/nullability relations, conditional replacement and the sole
   admission-without-open non-dispatch proof. Exercise
   every ADR 0009 normalized allow, denial category, invalid/failed return, defer,
   and absent-policy row with no grant/attempt/hand call outside valid allow. Prove exact
   non-dispatch retry, in-flight retention, terminal settlement, immutable unknown,
   post-unknown process-absence release without cleanup, and stale/unsolicited
   response refusal. Drive the real local hand over a credential-free loopback
   HTTPS Git fixture, proving request/grant bytes, canonical skill-source/file-set/
   publication/request/grant/receipt/reconciliation-response digests, canonical
   public source, original-attempt and current-responder lease/executor epochs,
   fence binding, exact deadline/grant-expiry equality and overflow refusal,
   collision-proof staging identity, one-shot guarded release, closed and counted Git
   transport, every resource budget, retained receipt recovery, missing-parent
   creation/races/syncs, outside-discovery same-filesystem staging,
   absent/existing/racing destinations, competing identical-pack prepared-slot
   attempts and every interrupted no-replace publication cut. Recover a lost CLI
   acknowledgement from its pre-submit locator without another Git effect, then
   rediscover/use through a different fresh runtime and trust decision. An attended
   public anonymous HTTPS Git acquisition separately proves the network path.
2. **Context:** catalog/instruction/supporting stages, hostile-pack invariance,
   complete paginated trust display with canonical terminal escaping and
   structured headless fields, canonical-or-nil secret-free workspace
   repository origin, directory/frontmatter name equality, in-place
   same-skill selection replacement, and the ADR 0017 step-5 proof for the exact
   fallback plus every actual candidate count from zero through 37 across legal
   status/detail/index boundaries and descriptor cardinality through 1,024. Prove
   canonical model-visible message framing, the exact revision-3 receipt and
   detail/nullability relations, first-failure ordering, resource-class arithmetic
   and unreachable `resource_class_tokens`, actual staged request capture, zero-or-
   one deterministic single-workspace snapshot ownership; the exact four-member
   launch envelope; durable host snapshot sync/reopen plus
   exact no-follow/no-replace/sync/reopen binding-intent schema, digest, key and
   idempotency before the first Store call; zero-Store/zero-child failure;
   intent-authorized commit-unknown settlement after current-source change;
   commit-unknown retention and resume digest reconstruction; plus
   `resource_snapshot_binding_v1` committed or matched before children start,
   exact restart equality, match/changed/unavailable attestation relations,
   recovery-only negative authority and source-free settlement, changed-byte/new-
   runtime use and no per-session copies, complete fresh-process discovery that detects added/removed packs and
   every file-set change, and source-free replay of already staged bytes.
   The core selector proves canonical data, binding and admission. The two
   protected Outcome 3 integration cases prove the host half of this outcome:
   actual CLI/headless pagination and final-page confirmation, plus literal
   filesystem discovery and fresh-process re-attestation. A fabricated snapshot
   cannot satisfy those host obligations.
3. **Workflow:** both entries and source-built CLI/companion, actual tool result,
   existing full-object artifact inspection, trusted launch/recovery configuration,
   and same-runtime coexistence preserving exact ADR 0007 ordinary job/grant/event/
   receipt/reconciliation/oracle bytes plus ADR 0009 ordinary policy request/
   decision/context bytes with no cross-family members;
   an attended real-provider task in
   `apps/loopex_cli/test/foundation_workflow_real_test.exs`.
4. **Repairs:** required-only fixed-point lower-bound/first-failure properties and
   historical refusal replay; held-Store unrelated-session latency; long-history
   retention with delayed requests and owner succession; an attempt closed only
   by a run terminal remains retained until session release when no settlement
   committed. Use ADR 0017's existing refusal members and meanings, not a new
   inferred lower-bound receipt field.
5. **Gate protection:** override-citation ancestry across ordinary integration
   merges plus laundering refusal; synthetic register invocation and M3-Closed
   transition; missing/red/omitted predecessor; bootstrap recursion refusal;
   cross-VM scratch allocation; and mutations of repaired-path clauses and
   sibling transitions.

**Cheap checkpoints and full contract evidence**

The locked default command is the complete closure gate. `--checkpoint` is
explicitly focused diagnostic evidence: inspection, isolated compile/opening
probe, and changed-outcome deterministic witnesses selected by a digest-bound
path-to-outcome map. Shared or unclassified product paths select all outcomes;
unknown acceptance impact requires the full gate. Selection starts from an
explicit retained comparison SHA, includes tracked/untracked relevant work,
and cannot interpret an empty/invalid comparison as no work. The exact mapping
and role grammar must exist and be negatively tested before acceptance.

The reviewed acceptance aggregate override removes only the acceptance-base run
for this transition. Run the full inherited aggregate at every parallel
workstream rejoin, every amendment or bound-holder rebind child, each closure
candidate, at least once in each UTC day when dependent product work lands on
the M3 branch, and after every change that invalidates later inherited evidence.
Existing gates must remain green between those moments. A missing
scheduled or rejoin run is a process defect, and focused results do not replace
full evidence or excuse an observed inherited failure. Do not put the aggregate
inside protected-selector execution or bootstrap. This plan creates no client
automation; repository/hosted scheduling must invoke the repository command and
retain the source-bound result for each active-work day.
Record per-lane duration so cost is observable; no promised minute count.

**Review and closure evidence**

Every negative proves it reached its intended boundary. Source regexes, literal
configuration, startup failure and short silence cannot witness behavior.
Preserve inherited assertions. Before amendment/closure handoff, use mutant-hunt
on changed obligations and sibling paths, then independent review. Repeated
finding classes trigger an all-entrypoint root-cause audit, not another narrow
patch/reviewer loop. The implementer self-audits composition, lifetime, trust,
rollback, packaging and docs before final review.

Freeze source S for required evidence. Bind source/gate/commands/seed, limits,
actual toolchains/platforms and non-secret build identities. Run real build and
platform paths early and at closure; retained old-reader positive controls,
new-format refusal and every documentation row remain mandatory. Relevant byte
changes invalidate affected evidence/review; unknown scope means the full gate.
A same-source disappearing failure is a blocking flake, not a successful retry.

**Acyclic gate ownership**

`scripts/check-closed-gates.sh` reads the canonical register and runs the exact
required commands. Bootstrap is a leaf. The full M3 runner owns the inherited
aggregate call; checkpoint mode cannot claim full-gate completion. Once M3 is
Closed its inherited call selects only its predecessor prefix, excluding itself.
Prove that synthetic transition and reject missing invocation/back-edges before
acceptance. No environment skip or authority bypass is permitted.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Scope](M3.md#concept-plan-scope).

Resource queries, admission/activation commands and administrative acquisition
are experimental additions. Core receives canonical data; Git, paths and parsing
stay in the hand/host edge. The same Policy callback gains one fail-closed tagged
acquisition variant; ADR 0009's five normalized denial categories and defer/
failure mappings remain exact, while an absent optional acquisition policy makes
only acquisition unavailable. Existing tool request/decision/grant bytes remain
unchanged.
Solely for that tagged runtime-control acquisition, ADR 0025 narrowly supersedes
ADR 0007's universal session `JobRequest`; job/session/run/turn/tool-call/session-
origin identities; tool-ID/tool-version grant bindings; executor accepted/
started/progress event sequence; session-origin terminal-receipt tuple; session/
coordinator-epoch reconciliation; ADR 0009's tool-call-only policy-request member
set; and the corresponding universal wording in Concept vision section 15 and
Technical vision sections 6.3, 8.4, 9.3, 9.4, 15.1 and 23.3. The runtime-control family substitutes runtime/command/operation/
attempt identity, separately bound original-effect and current-responder epochs,
receipt-only completion, bounded status, and Runtime Control-owned
reconciliation. Session epoch/origin remains mandatory for every session-owned
effect. Existing session jobs, grants, policy requests, events, receipts,
reconciliation and oracle remain byte- and meaning-unchanged, with same-runtime
coexistence proof required. Version new resource and runtime-control records/receipts and preserve
genuine M2 replay, root AGENTS and historical refusals. ADR 0025 explicitly
narrows its supersession of ADR 0010's
no-recursion/no-globbing rule to bounded content-independent enumeration inside
the fixed skill directory, and re-proves ADR 0017's admission implication for the
larger receipt/descriptor shape. ADR 0027 changes in-memory retention, not
attempt/accounting algebra. Existing allow/deny policy and full-object
ArtifactStore contracts remain unchanged.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M3.md#concept-plan-scope).

Use fresh M3 evidence roots. Prove new readers on genuine M2 roots and prove
that an M2 reader cannot open a session with any `resource_command_v1`, including
a refusal-only history, while a no-resource-command session retains its M2 journal
form. A non-nil resource binding makes its Store root M3-format before
acquisition; an unbound genuine M2 identity reopens only resource-disabled and
cannot upgrade in place. Once a binding or acquisition exists, the M2 binary
cannot safely open the M3 Store/hand root even if those individual sessions are
old-form. Roll back with retained
M2 Store/hand root and binary pairs; never point M2 at M3 state, rewrite operator
history or promise in-place downgrade.

Import commits Store command/intent and attempt before one hand guard can release
Git. The hand safely creates missing fixed parents, retains their identities, and
validates/syncs task-owned same-filesystem staging outside the discovery root,
then syncs prepared
`skill_import_v1`, publishes to an absent destination atomically without
replacement, syncs the parent, reverifies the destination, commits provenance and
retains its receipt. Runtime Control then commits terminal truth. An existing
destination is never replaced. Across interruption cuts, attempt-owned writes
leave it absent or complete; unrelated racing writes may leave other bytes and are
preserved without attempt attribution. A published pack with only prepared
provenance is local and unverified. Rediscovery/restart attaches remote commit/tree
identity only when the source runtime/operation identity, a complete fresh-
directory attestation, current bytes/destination identity, hand receipt/
provenance and Store terminal all match. The importing runtime remains bound to
its immutable launch snapshot; a later start selects recovery-only mode only when
fresh attestation no longer matches. Actual use starts a distinct runtime and
obtains new trust.
Already staged model bytes survive later pack removal. Reconciliation never
automatically deletes staging or destination bytes; post-unknown process absence
only releases process quarantine. No floor or artifact format migration is added.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M3.md#concept-plan-scope).

Keep eight apps and existing roles, versions, package dependencies and Elixir/OTP pins.
Core/protocol remain stdlib/OTP only. Add one pre-child snapshot-binding Store
transaction, one fixed runtime-control acquisition Store transaction, one small
reference-host CLI recovery locator, and one optional administrative
`Loopex.ResourceAcquirer` port,
implemented by `loopex_executor_local` and wired by composition. The local
executor also builds one repository-owned C11/libc Port helper from
`apps/loopex_executor_local/c_src/loopex_fs_guard.c` for protected-root journal
locking/sync, no-follow directory operations, stable identity and atomic
no-replace publication. Darwin uses `renameatx_np(RENAME_EXCL)` and Linux uses
`renameat2(RENAME_NOREPLACE)`; the build needs a C11 compiler plus platform
headers, while the shipped target runtime contains the helper and needs no
compiler or new package dependency. Prove the exact source-built helper,
compiler identity, Port isolation and atomic-race startup self-probe on the
accepted-floor Darwin lane and current Linux lane before broader acquisition
tests. `DEVELOPMENT.md` documents the compiler probe, build command, supported
targets and packaged-helper runtime check. The hand invokes
an optional host-supplied probed Git executable with anonymous HTTPS, closed environment/configuration,
redirects and credentials disabled, a task-owned exact-authority counted CONNECT
relay, a 30-second maximum deadline, exact request budgets and captured process
cleanup. It adds no session `JobRequest` kind,
model/default tool, HTTP library or generic administrative framework. Parse a
declared bounded frontmatter subset and diagnose unsupported constructs. The CLI
gains skill add/list/show/operation list/resume/forget/inspection/reconciliation and explicit pre-run
selection. If Git is absent or cannot enforce the hand contract, acquisition alone
is unavailable while ordinary sessions continue. No publication or service install.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M3.md#concept-plan-scope).

Justified growth is one fixed ResourcePack boundary, resource catalog/read
queries, admit/activate commands, one pre-child snapshot binding, one Runtime
Control/Store acquisition family, one bounded CLI recovery locator, one narrow
acquisition hand, composition/CLI adapters, three direct core repairs
and repository verification. One admission owner, manifest and selection path
serve both hosts. No new app/Hex package dependency/session-job kind, second policy evaluator,
generic administrative executor, interaction family, range port, default tool,
private credential channel, plugin loader, generic pipeline, worker pool or
second reducer. Review growth against actual boundary reuse; arbitrary line
ceilings do not replace complete evidence.
<!-- loopex:plan-technical-envelope:end -->
