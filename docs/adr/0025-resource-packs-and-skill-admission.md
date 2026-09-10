<a id="concept"></a>
## Concept

Technical depth: [Resource packs and skill admission mechanics](0025-resource-packs-and-skill-admission-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-09
- **Decision owner:** Maintainer
- **Prerequisite for:** M3 acceptance
- **Supersedes:** 0007
- **Supersedes:** 0009
- **Supersedes:** 0010
- **Supersedes:** 0017

<a id="concept-adr-0025-decision"></a>
### Context and Decision

M2 admits one root AGENTS.md. Compatible skill directories add reusable operator
capability, but internet content is untrusted and multiple optional blocks
invalidate ADR 0017's single-flat-block proof. Acquisition, retention, admission
and execution need distinct owners before that capability ships.

Add one fixed resource-pack class, with Agent Skills as its first format.
Compatibility means the ADR's closed, dependency-free frontmatter subset and
conformance vectors, not general YAML or every vendor extension; a skill outside
that subset is diagnosed and refused. Hosts acquire and parse bounded packs; core receives canonical plain data and
owns exact context admission. Preserve root AGENTS.md behavior unchanged.

Support only project `.agents/skills/<name>/SKILL.md`, with bounded supporting
files from an operator-selected directory at an exact commit in a public,
credential-free HTTPS Git repository. No HTTPS single-file acquisition,
private/credentialed source, configured/home root or content-directed discovery.

Acquisition is one operator-only administrative executor effect, separate from
session tool calls. Runtime Control and Store own the command, durable intent,
attempt, reconciliation query/result, terminal truth and commit-unknown fence.
The host owns the canonical
workspace-root/reference/lease binding and its issuance or revocation; the
existing host policy port owns explicit allow or deny. A narrow resource-
acquisition hand validates the current binding and owns Git, its process tree,
staging, validation, no-replace publication, retained receipts and solicited
reconciliation responses. The reference local hand uses one repository-owned,
libc-only native port helper for no-follow filesystem operations, durable local
journaling and atomic no-replace publication. Builders need a C11 compiler and
platform headers on supported Darwin and Linux targets; shipped runtimes contain
the built helper and need no compiler. The helper is process-isolated from the
BEAM and adds no package dependency.
The helper image and every Git image are fixed for one acquisition-hand executor
epoch. The hand executes an already verified object where the platform supports
it; otherwise the native supervisor must prove the kernel-selected child image
at a pre-effect execution barrier. A target that cannot prove either mode makes
Git acquisition unavailable while ordinary sessions and local skill discovery
continue. Any path, object, byte or child-image mismatch invalidates the graph
and ends that executor epoch for new acquisition.
Composition only wires those owners. The
operation has its own request/grant/receipt family and carries no fictitious
session, run, turn, tool-call or tool identity; the existing session
`JobRequest`, tool registry and ordinary grant bytes remain unchanged.

The Store confirms command, intent, bound grant and attempt before the authorized
hand can start Git. An existing destination refuses before mutation. For an
absent destination, the hand safely creates only the fixed missing project
parents, stages under a same-filesystem sibling outside `.agents/skills`, and
syncs prepared provenance under the verified pack
digest, publishes with an atomic no-replace operation, syncs the containing
directory, verifies the final destination and complete bytes, then syncs the
committed destination binding and terminal receipt. A prepared attempt is never
provenance authority. Across cuts, attempt-owned writes leave the destination
absent or one complete pack; an unrelated racing writer may leave other bytes,
which the hand preserves and never attributes to the attempt. A complete pack
without matching committed hand and Store truth is treated as local. An
acquisition whose dispatch, process, receipt or cleanup cannot be proved is
retained as unknown and quarantines its owned staging and destination label.
Exact solicited reconciliation may prove that an attempt never dispatched or
that its process is no longer live, but it never rewrites an unknown operation
to success, retries blindly, or automatically removes staging or destination
bytes.
Rediscovery attaches the remote commit and tree identity only when the Store
terminal, retained hand receipt, committed provenance binding, destination
identity and current complete bytes all agree; a prepared, missing, stale or
mismatched fact is treated as local and never advertised as verified remote
provenance. Copying or committing an installed directory without its matching
hand retention deliberately degrades it to local/unverified content. Session
trust is a separate decision bound to all pack bytes. Before admission the
operator can page through the complete repository, provenance and file-identity
view and every exact file body from retained snapshot bytes. Confirmation is
accepted only after the terminal body page of every manifested file for that
exact digest; terminal and headless presentation remain bounded and control-safe. Expose metadata,
then operator-selected instructions and explicitly selected manifested supporting
labels. Admission and selection require settled state before a run; the run keeps
an immutable selection. Model output is never an acquisition or resource command.
Scripts run only as ordinary authorized tools.

The resource manifest displays and binds a workspace repository origin only
when the host supplies an already-canonical, credential-free public HTTPS
identity. Any raw remote containing credentials or a local, SSH, query-bearing,
or otherwise noncanonical form becomes nil before core, retention, display, or
digest construction.

For review, this Proposed pair recommends one explicit host-supplied resource
binding envelope: one workspace identity and zero or one immutable snapshot,
plus a bounded fresh workspace attestation and durable pre-submit binding intent,
committed or matched before runtime children start. The intent records the exact
match-authorized transaction before its first Store call and recovers an unknown
submission without authorizing changed bytes; the attestation remains live launch
evidence outside the immutable binding. Changed or unavailable current bytes reopen an existing
bound runtime only for exact replay, status, reconciliation and source-free
settlement; every new run or resource authority requires another runtime identity
and trust decision. Omitting that
envelope preserves a core-only, resource-disabled start and cannot later enable
resources under the same durable runtime identity. It also recommends four
selected skills and eight supporting files per skill. Packs may still contain 64 files. The host retains source bytes
durably; core holds one normalized in-memory snapshot for the runtime lifetime,
while sessions retain only identities. Resource-enabled requests pay a fixed
bounded receipt-header cost before optional admission. These choices require
explicit ADR acceptance; this revision implements no runtime behavior.

The reference CLI records one bounded workspace/snapshot-bound recovery-journal
family before any `skill add` Store call: an active recovery journal and, only at
safe terminal cleanup, its compact administrative-runtime retirement frame. A
lost binding or command acknowledgement reopens only the exact authorized
transaction. If the workspace changes after the binding settles but before a
command exists, the CLI records the no-effect retirement path instead of
submitting a new command in recovery mode or retaining an unbounded orphan. A
lost command acknowledgement reopens that exact administrative runtime and
command without a second Git effect. The live
administrative runtime remains bound to its immutable launch snapshot and cannot
observe bytes its acquisition later publishes. Actual use occurs through a different fresh runtime that
rediscovers the changed project, joins provenance through the original
runtime/operation identity, displays the new manifest and obtains new trust.
Existing sessions do not migrate to the installed bytes.

The reference host enforces aggregate retention with one host-global lock and
durable per-artifact reservations rather than a counter that can diverge from
the files it counts. It reserves the CLI journal before its first Store call,
the snapshot before materialization and binding, and one combined local-attempt
plus retained-evidence entitlement before the Store attempt is submitted. That
reservation embeds the one exact Store attempt transaction, so restart resolves
or re-presents it without repeating policy or minting a grant. The closed
ceilings are 1,024 lifetime CLI journals charging 512 MiB; 16 runtime snapshots
charging 1 GiB content and 128 MiB metadata; six unresolved or quarantined
attempts charging 480 MiB; and 1,024 retained evidence packages charging 2 GiB.
An unknown, quarantined, corrupt, or release-in-progress artifact remains
charged. Release records the matching Store, local, retirement, and dependency
proof before deleting any owned bytes; restart resumes that exact transition.
Capacity refusal happens before Store attempt commit and crosses no local effect
boundary. A lost-before-dispatch attempt releases only after its `not_dispatched` result is known
committed. CLI retirement keeps a permanent runtime-reuse fence; direct
embedders use the same private retention owner and Store-idle proof.

For administrative resource acquisition only, supersede ADR 0007's universal
session `JobRequest`; job/session/run/turn/tool-call and session-origin identities;
tool-ID/tool-version grant bindings; executor accepted/started/progress event
sequence; session-origin terminal-receipt tuple; and session/coordinator-epoch
reconciliation. Refine the matching universal language in Concept vision
section 15 and Technical vision sections 6.3, 8.4, 9.3, 9.4, 15.1, 17.1 and
23.3, including section 17.1's statement that every hand package sits behind the
session job protocol. Its hand-package trust classification and host-policy
requirement remain unchanged.
Those session epoch/origin rules continue to govern every session-owned effect.
The replacement is one tagged runtime-control
acquisition request with origin `(runtime_control_resource_acquisition,
runtime_id, command_id)`, operation/attempt plus separately bound original-effect
and current-responder lease/executor epochs and fence identity,
the same host-policy-only authority and final pre-start validation, acquisition-
kind/protocol-version bindings in place of tool identity, retained receipt-only
completion, a bounded status query, Runtime Control-owned reconciliation, and
fixed no-artifact, bounded counted-and-discarded output policy. Existing session `JobRequest`,
ten-binding grants, events, receipts, reconciliation and conformance oracle remain
exact. This is a narrow hand-package effect exception for the Git acquisition the
vision already requires to cross executor policy; it creates no generic
administrative executor family.

For administrative resource acquisition only, supersede ADR 0009's closed
tool-call-only policy-request shape by adding one tagged runtime-control request
variant to the same host policy callback. Existing tool-policy requests,
decisions, grants and receipts keep their exact meaning, and an unknown variant
fails closed. The variant consumes ADR 0009's normalized result without
reinterpretation: only a valid allow can proceed, every valid denial category is
retained exactly, malformed/failed policy returns become `policy_unavailable`,
and defer becomes `interaction_unsupported`; none of those denial paths creates
a grant, attempt or hand dispatch. For project skills only, supersede ADR 0010's root-AGENTS-only permitted label,
fixed-class/cardinality, no-recursion/no-globbing and session-start-only trust
timing restrictions. The discovery exception is bounded to a content-independent
walk inside one fixed `.agents/skills/<name>/` directory; it adds no root, link,
escape or content-directed lookup. Add pre-run resource admission while settled,
not arbitrary paths or mid-run trust.
For project skills only, supersede ADR 0017's closed source-reference variant
set, descriptor provenance-class set, three-key provenance totals, revision-2
successful-receipt shape, and zero-or-one optional-block implication only for
the new `model_request_committed_resources_v1` record kind. That kind adds
exactly one `resource_pack` source-reference variant, provenance class and
totals bucket, one exact `resource_packs` receipt member, provider revision 3,
and the multi-block step-5 proof below. ADR 0017's exact `project_resource`
receipt, dispositions and whole-class withholding remain unchanged for root
AGENTS.md. Project-skill dispositions apply per whole block; a refused block is
never trimmed, and later blocks may still fit. Historical
`model_request_committed` records retain their exact revision-2 schema and
meaning; no historical byte is reinterpreted.
Resource bundles use host-owned content-addressed retention, not ADR 0015's
closed tool_output use schema. Context already staged for a request is durable
session data, independent of later bundle installation or removal.

Technical depth: [Contract and evidence](0025-resource-packs-and-skill-admission-technical.md#technical-adr-0025-decision).

<a id="concept-adr-0025-consequences"></a>
### Consequences, Compatibility and Rollback

An operator can reuse portable skills in the local CLI and embedding API.
M4 can consume the same catalog, selection and inspection semantics without a
second parser, trust store or activation engine. Unsupported vendor execution
fields are reported, not silently advertised as compatible. Activating even a
hostile pack must leave registered tools, the policy result for an identical
request and grants unchanged. Hosted remote
skills services, automatic updates, registry search, hot plugins and generic
context pipelines remain outside this decision.

Add experimental facade queries and command variants under the session owner,
plus the administrative acquisition command under Runtime Control.
New readers must replay genuine M2 histories unchanged. An M2 reader cannot open
a session containing any `resource_command_v1`, including a session whose only
resource command was refused; it refuses the unknown journal kind before effects.
Sessions with no resource command retain M2-compatible record forms. Omitting
the resource-binding envelope preserves a core-only or genuine M2 runtime in
that form, but that durable identity cannot later enable resources. Supplying
the envelope commits a new snapshot-binding record before children, so an M2
binary cannot safely open that Store root even when no acquisition or session
resource command follows. Store acquisition records have the same old-reader
refusal requirement. M3's separate host-private journal, reservation, snapshot,
and hand files are invisible to an M2 binary; they cannot serve as old-reader
refusal or rollback evidence, and the old host must never infer that their
absence or silence authorizes reuse. Rollback therefore restores a retained old-
format Store root, matching old host state, and matching binary rather than
pointing the old binary at a resource-enabled M3 root; no rewrite or in-place
downgrade is promised. M3 hand
receipts and Store terminals remain retained while a current committed import
generation names them; losing either deliberately degrades rediscovery to local
content and is not permitted retention. The CLI journal and retirement fence
are host-private state that M2 neither opens nor interprets. An M3 host prevents
a matching old host from reusing or deleting the associated administrative
runtime; that protection is a host routing/rollback obligation, not a claim that
M2 parses the new sibling file. Project directories alone grant nothing, so an
M2 binary ignores an installed skill directory. Existing admitted AGENTS.md
behavior and provider redispatch restrictions remain intact.

Technical depth: [Compatibility mechanics](0025-resource-packs-and-skill-admission-technical.md#technical-adr-0025-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
