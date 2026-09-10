<a id="technical-depth"></a>
## Technical depth

Concept: [Resource packs and skill admission](0025-resource-packs-and-skill-admission.md#concept).

<a id="technical-adr-0025-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0025-resource-packs-and-skill-admission.md#concept-adr-0025-decision).

All member sets, bounds and new record forms below remain **Proposed** for
maintainer review with this pair. They are not accepted persistent contracts or
authorization for dependent product implementation.

### Owners and public entrypoints

`Loopex.Runtime.Control` is the sole serial owner of resource-acquisition command,
intent, attempt, reconciliation and terminal truth. It commits those facts through
the Store's runtime-control namespace before dispatch or acknowledgement. The host
supplies the canonical root/reference/lease binding, its issuance or revocation,
executor placement, retention policy and an explicit policy decision.
`Loopex.ResourceAcquisition` owns one
bounded administrative request, grant, receipt and recovery algebra.
`Loopex.ResourceAcquirer` is the narrow executor-side hand port, and
`loopex_executor_local` supplies the M3 implementation. That hand exclusively
owns Git invocation, process-tree lifetime, fetch and staging bounds, containment
validation of the current workspace binding, no-replace publication, retained execution evidence and
`skill_import_v1` provenance writes. `loopex_composition` wires these owners and
supplies no authority of its own.
`Loopex.Runtime.start_link/1` owns only the immutable launch-binding transaction
below, before it starts the runtime supervisor or any child. It has no continuing
mutation authority; after launch, Runtime Control remains the sole acquisition
owner.

The behavior has exactly these six process-local callbacks:

```text
capabilities(acquirer_ref) ->
  {:ok, %{executor_identity: binary(), executor_epoch: non_neg_integer(),
          workspace_ref: binary(), workspace_lease: binary(),
          git_graph_identity: binary(), capabilities: [atom()]}}
  | {:error, :acquirer_unavailable}

prepare(acquirer_ref, resource_acquisition_preparation_v1) ->
  {:ok, resource_acquisition_preparation_receipt_v1}
  | {:error, :acquirer_unavailable}

prepared(acquirer_ref, runtime_id, operation_id) ->
  {:ok, :absent | resource_acquisition_preparation_v1}
  | {:error, :acquirer_unavailable}

release_preparation(acquirer_ref,
                    resource_acquisition_preparation_release_v1) ->
  {:ok, :released}
  | {:error, :acquirer_unavailable}

acquire(acquirer_ref, resource_acquisition_request_v1,
        resource_acquisition_grant_v1) ->
  {:ok, resource_acquisition_receipt_v1}
  | {:error, :acquirer_unavailable}

reconcile(acquirer_ref, resource_acquisition_reconciliation_query_v1) ->
  {:ok, resource_acquisition_reconciliation_response_v1}
  | {:error, :acquirer_unavailable}
```

`acquirer_ref` is an opaque trusted-composition reference selected by the host's
trusted route before policy evaluation. `capabilities/1` is read-only: it creates
no process, file, network request, durable record, or authority. Its exact
validated result supplies the executor, graph, workspace, lease, and capability
members of the policy request. Runtime Control calls it again after an allow and
requires byte equality before constructing the request and grant; a failure or
change commits the pre-attempt `acquirer_unavailable` terminal. After that
second observation Runtime Control constructs the request, grant, exact Store
attempt transaction and preparation record below. `prepare/2` durably reserves
the attempt's complete scratch, log and prospective evidence entitlement before
Runtime Control may submit that Store transaction. `prepared/3` is the
read-only recovery observation for a lost prepare reply or replacement Control;
it returns `:absent` only after the capacity lock proves that no reservation for
the operation exists, returns the one exact `prepared` record, and reports
unavailable for a conflicting, corrupt, settling or multiply owned record.
`release_preparation/2` releases only a prepared transaction whose Store status
observer proves the exact final `not_committed` result. None of these three
callbacks creates an admission, process, network request, workspace byte,
policy result or Store fact. The attempt and hand then bind the same capability,
request, grant and preparation bytes.

The reference also contains one host-owned, non-grant-derived current-authority observer whose exact private
result is `{:ok, %{runtime_id: runtime_id, operation_id: operation_id,
command_id: command_id, attempt: attempt,
authority_kind: :dispatch | :reconciliation,
state: :attempt_open | :terminal_quarantined,
preparation_id: preparation_id, preparation_digest: preparation_digest,
canonical_request_digest: canonical_request_digest,
canonical_grant_digest: canonical_grant_digest, workspace_ref: workspace_ref,
workspace_lease: workspace_lease, executor_identity: executor_identity,
executor_epoch: executor_epoch, fencing_token: fencing_token,
current_reconciliation_query_id: query_id_or_nil,
current_recovery_epoch: recovery_epoch_or_nil,
current_reconciliation_query_digest: query_digest_or_nil,
authority_hold: opaque_ref}}` or
`{:error, :authority_unavailable}`. The observer folds the current Store attempt
and fence and the host's current workspace/executor lease; request, grant,
caller input, and pack content cannot supply it. No settled, superseded, absent,
or different attempt or query may return the success form. The `dispatch` form
requires `attempt_open`, no committed current reconciliation query, and all
three query members nil. The `reconciliation` form requires the exact current
committed unresolved query and all three query members non-null; its digest is
the canonical complete query digest below, and its state equals that query's
base state. No other kind/state/nullability relation is legal. `authority_hold` is
process-local, cannot be encoded or compared as grant data, and remains held
through guard release and process lifetime; its invalidation enters the durable
cancellation path. `loopex_executor_local` calls that observer while holding its
final serialized attempt lock immediately before local admission and guard
creation and requires the dispatch form, then compares every durable member
independently with the preparation, request and grant. Observer unavailability returns `{:error, :acquirer_unavailable}` with no
local admission, receipt, or effect and leaves the committed Store attempt open
for solicited reconciliation. A well-formed mismatch produces the corresponding
existing `refused_before_effect` receipt. `acquire/3` requires
`:attempt_open` and the dispatch form. Before `reconcile/2` performs any local tombstone, process
status/signal/wait, response append, or return, it invokes the same observer
under the attempt lock and requires the reconciliation form with the query's
exact `:attempt_open` or `:terminal_quarantined` base. It independently compares
runtime, command, operation, attempt, preparation, both request/grant digests,
current query ID, recovery epoch and query digest, current responder
workspace/executor lease/epoch, and the attempt-stable fencing token. Failure returns
`{:error, :acquirer_unavailable}` with no local mutation or response; the
committed query remains reconciling. This is the exact current-responder fence
check, so another redundant fence field is not added to the query schema. The same trusted route
delivers lease, executor-epoch, fence, deadline, and Control-channel loss to the
running hand's cancellation path; inability to retain that route makes the
capability unavailable before attempt commit.

The reference additionally contains one host-owned, non-authorizing settlement
observer used only for capacity release. Its success form identifies the exact
runtime, command, operation, attempt, preparation, request/grant digests, and one of three
closed dispositions. `attempt_not_committed` carries the prepared Store attempt
transaction ID and digest plus the exact final not-committed reason and has nil
reconciliation and terminal members. `pending_policy_not_dispatched` carries the positive
committed reconciliation-result ordinal and result-record digest and has nil
terminal members; `terminal` carries the Store terminal transaction ID, terminal
record digest, outcome, and nullable receipt digest and has nil reconciliation
members. It folds only current Store truth and returns
`{:error, :settlement_unavailable}` on absence, ambiguity, or unavailability.
Neither form grants effect, cleanup, or release authority until the hand also
matches its immutable local records under the capacity and attempt locks.

Runtime Control selects the trusted route and validates the closed capabilities
map and required-capability set before policy evaluation, then revalidates the
same map after allow. Before evaluating policy from `pending_policy`, it first
calls `prepared/3`: an exact retained preparation bypasses a new policy or grant
and re-presents only its retained Store transaction; `:absent` permits a new
policy evaluation; unavailable state leaves the operation pending with no new
transaction. After allow it must resolve `prepare/2` to an exact receipt or an
authoritative `prepared/3` result before submitting the Store attempt. A
confirmed prepare refusal with authoritative absence commits the pre-attempt
`acquirer_unavailable` terminal. A lost or unavailable prepare observation
leaves `pending_policy`; it cannot be converted to absence. After a final Store
`not_committed` result, Runtime Control calls `release_preparation/2` and cannot
start another policy attempt until release is confirmed. It invokes `acquire/3`
only after the prepared attempt commits, in a supervised
task outside the Control mailbox, and invokes `reconcile/2` only for the current
committed solicited query. A malformed return, callback raise/exit, deadline, or
transport loss proves no effect fact: after attempt commit it leaves the attempt
open; after query commit it leaves the query reconciling. Only a validated
receipt or response supplies a Store transition candidate. A capability-query
failure before attempt commit may produce the specified pre-attempt
`acquirer_unavailable` terminal. The callbacks create no session event or public
progress record. A prepared record authorizes only submission or
resolution of its one embedded Store attempt transaction; it grants no effect.
Every effect or reconciliation action still requires the committed attempt or
query and the exact current-authority form above.

Acquisition extends the Store transition catalogue while preserving ADR 0006's
three outcomes and exact-representation recovery and ADR 0008's one-Control-per-
Store/runtime placement. It adds no active-active placement claim. It adds one
tagged acquisition request to the existing `Loopex.Policy` callback rather than
a second policy evaluator. Policies that do not recognize the variant deny it;
no fallback allows it. For this variant only, ADR 0025 supersedes ADR 0009's
tool-call-only request member set. The callback, bounded allow context, closed
denial classes, failure-to-deny behavior and every existing tool-call request
remain unchanged.

For this administrative acquisition class only, ADR 0025 also supersedes ADR
0007's universal session `JobRequest`; `job_id` and session/run/turn/tool-call/
session-origin identities; exact tool-ID/tool-version grant bindings; executor
accepted/started/progress event sequence; session-origin terminal-receipt tuple;
and session/coordinator-epoch reconciliation. It narrows the matching universal
statements in Concept vision section 15 and Technical vision sections 6.3, 8.4,
9.3, 9.4, 15.1, 17.1 and 23.3, including section 17.1's statement that every
hand package sits behind the session job protocol. The hand-package trust class
and host-policy requirement remain unchanged. Session epoch/origin remains mandatory for every
session-owned effect. It preserves their
governing principles: one durable operation/attempt, one request-digest semantic,
host-policy-only grant authority, independently validated audience/lease/expiry/
fence at the final pre-start boundary, bounded output, retained receipt and
solicited recovery. Its exact replacements are `runtime_id`, `command_id`,
`operation_id`, `attempt`, original executor identity/epoch and fence; origin
`(runtime_control_resource_acquisition, runtime_id, command_id)`; acquisition
kind/protocol version in place of tool ID/version; no public executor progress
sequence; receipt-only hand completion committed by Runtime Control; the bounded
status query; and the Runtime Control reconciliation records below. The fixed
policies return no ArtifactStore artifact and expose no subprocess output to a
model or session. Existing session jobs and ADR 0007's ten-binding schema, oracle,
events, receipts and reconciliation stay byte- and meaning-exact. Evidence must
mutate every replacement binding and prove the existing session oracle unchanged.
This bounded refinement creates no second generic job framework.

The experimental `acquire_resource(runtime, command)` host API submits
`acquire_resource` as a runtime-control command keyed by
`(runtime_id, command_id)`. Canonical repetition returns the retained
admission/terminal reference; the same identity with changed bytes refuses with
`idempotency_conflict`. Admission returns `{:accepted, operation_id}` only after
the command and intent are durably committed; the effect then runs asynchronously
so Runtime Control remains available. `resource_acquisition_status(runtime,
operation_id)` is a bounded read. `reconcile_resource_acquisition(runtime,
request)` starts one solicited reconciliation for an
open or unknown exact attempt. The reference CLI exposes those as
`loopex skill operation show <operation-id>` and
`loopex skill operation reconcile <operation-id>`.

The public reply algebra is closed. A malformed command returns
`{:error, :invalid_resource_acquisition_command}`; a confirmed accepted or busy
command returns the retained tuple stated below; changed bytes under a retained
command identity return `{:error, :idempotency_conflict}`. Store failure before
any candidate can be submitted or authoritatively observed returns
`{:error, :store_unavailable}`. Once a transaction was submitted but its outcome
is unknown, the call returns `{:error, :commit_unknown}` and exact replay may
only resolve or re-present that same transaction. It never builds a replacement
candidate until the Store proves the submitted transaction absent. These errors
are caller replies, not durable acquisition terminals.

Exactly one accepted nonterminal acquisition operation may exist per runtime.
A second well-formed command while that slot is occupied durably records only a
refused command with `disposition: acquisition_busy`, nil `operation_id`, and no
intent, policy call, attempt or effect. Exact replay returns that refusal. A new
operation is admitted only after the prior operation is terminal and any required
post-unknown process quarantine has been released.

An acquisition has no `session_id`, `run_id`, `turn_id`, `tool_call_id`, model
tool name or tool-registry presence. It never enters the existing session
`Loopex.Executor.JobRequest`; inventing those identities merely to reuse that
struct is forbidden. Model output, resource metadata, activation and
`allowed-tools` cannot submit or authorize acquisition. Core receives bounded
canonical pack data and never a path, Git process, or credential. Runtime
Control receives only the opaque configured hand reference above; the pure
session resource boundary receives no acquisition callback. Core owns a pure
`Loopex.ResourcePack` boundary:
`digest(manifest)` returns `{:ok, manifest_digest, normalized_manifest}` or a
bounded refusal; `catalog(manifest, decision)` returns `{:staged, entries,
receipt}` or `{:declined, reason, receipt}`. Catalog entries contain only
source-qualified identity, name, description, digest and manual-only status.
These pure functions are necessary for pre-session inspection; they grant no
session authority.

`Loopex.ResourcePackReview` owns the one process-local pre-trust review cursor
over that immutable normalized snapshot. Both the reference CLI and a headless
host use this same owner and algebra; neither implements its own page counter or
confirmation shortcut:

```text
open_review(normalized_manifest, review_id) ->
  {:ok, review_ref, resource_review_page_v1, resource_review_cursor_v1}
  | {:error, :invalid_resource_review | :resource_review_unavailable}

next_review_page(review_ref, resource_review_cursor_v1) ->
  {:ok, resource_review_page_v1, resource_review_cursor_v1}
  | {:complete, resource_review_completion_v1}
  | {:error, :invalid_resource_review | :resource_review_out_of_order |
             :resource_review_unavailable}

confirm_review(review_ref, resource_review_confirmation_v1) ->
  {:ok, resource_review_evidence_v1}
  | {:error, :invalid_resource_review | :resource_review_incomplete |
             :resource_review_changed | :resource_review_unavailable}

cancel_review(review_ref) -> :ok
```

`review_ref` is an opaque process-local reference and grants no trust. Review ID
is an independent 128-bit random value encoded as 32 lowercase hex bytes. The
cursor has exactly `kind`, `review_id`, `workspace_ref`, `manifest_digest`,
`next_page_ordinal`, and `prior_page_digest`; generation zero has ordinal zero
and nil prior digest. Each successful page increments the ordinal and binds the
canonical digest of the preceding page under kind
`loopex.resource_review_page/1`. The first presentation of the exact current
cursor advances once. After advancement the owner retains that request cursor
and its exact response, so a lost-reply retry of that one cursor returns the
same page and successor without advancing again. Any earlier, skipped, changed,
or other-review cursor refuses without advancing.

The page has exactly `kind`, `review_id`, `workspace_ref`, `manifest_digest`,
`page_ordinal`, `page_kind`, and `payload`. `page_kind` is `identity` or `body`.
An identity payload has exactly `first_row`, `row_count`, and `rows`, with one to
32 consecutive canonical identity rows and the 32 KiB display bound below. A
body payload has exactly `pack_index`, `file_index`, `label`, `file_digest`,
`encoding`, `byte_offset`, `page_length`, `terminal`, and `body`, with the exact
8 KiB source/24 KiB display limits and encoding below. An empty file has the one
terminal zero-byte body page. The completion has exactly `kind`, `review_id`,
`workspace_ref`, `manifest_digest`, `page_count`, and `terminal_page_digest` and
is returned only after every identity row and every file byte appeared once in
canonical order.

The flattened identity sequence is closed: first one `manifest_identity` row,
then for each pack in manifest order one `pack_identity` row followed by all of
that pack's `file_identity` rows in file order. `first_row` is the zero-based
offset in that sequence and `row_count` equals the exact list length. The row
member sets are:

```text
manifest_identity
  row_kind, workspace_ref, manifest_digest, repository_origin, revision,
  pack_count

pack_identity
  row_kind, pack_index, source_id, origin, name, description, manual_only,
  commit, tree_digest, pack_digest, file_count

file_identity
  row_kind, pack_index, file_index, label, size, digest
```

Every value is the byte-identical normalized manifest value. The manifest's
repository origin/revision and a locally authored pack's commit/tree identity
retain their declared nullable relations; imported provenance requires all
remote identity members. Indices are canonical nonnegative integers and counts
match the complete manifest. No extra row kind/member, reordering, omission, or
duplicate is legal. All identity pages precede body pages; body pages then use
pack/file/byte order.

Confirmation repeats those six completion members exactly under kind
`resource_review_confirmation_v1`. Evidence repeats them under kind
`resource_review_evidence_v1` and is returned once; exact confirmation replay
returns the same evidence. Changed confirmation bytes refuse. The evidence is
proof that this host workflow reached its confirmation cut, not a policy grant
or a decision by itself. Only the trusted host/operator may translate it into
the separately bounded decision supplied to `admit_resources`. EOF, owner exit,
cancel, cursor/digest/order failure, or snapshot change destroys the ephemeral
review and produces no evidence, admission command, or trust. A process restart
starts a new review ID at page zero.

The public facade exposes `resource_catalog(runtime, session_id)` and
`read_resource(runtime, session_id, request)`. Session input gains
`admit_resources` and `activate_skill`, each using the existing command identity
and transaction discipline. Both require a settled session before a new run;
changes during a run refuse. `admit_resources` carries one bounded host decision
and manifest identity; `activate_skill` carries catalog identity and its exact
digest plus an ordered unique `supporting_labels` list (default empty, at most
eight labels from that pack's admitted manifest). Persist labels with pre-run
selection and freeze them into the run. Unknown/wrong-pack/duplicate labels
refuse; replay of a command ID with changed labels conflicts. `read_resource`
is inspection-only and changes no selection. Reading content returns bounded
data, never a filesystem path. The
coordinator rechecks the current decision and identity before staging it.

Propose one optional runtime launch input, `resource_binding: nil |
%{workspace_ref: workspace_ref, manifest: nil | manifest,
current_attestation: current_attestation,
binding_intent: binding_intent}`. The non-nil envelope has exactly those four
members. `workspace_ref` is a trusted host-supplied,
nonempty opaque UTF-8 binary of at most 1,024 bytes; no path, executor option,
project manifest or process environment supplies a fallback. A non-nil manifest
must carry that exact workspace reference or launch refuses
`resource_binding_changed`. `resource_binding: nil` is the default core-only,
resource-disabled form and preserves existing starts. A non-nil envelope enables
resources and durably binds its workspace even when `manifest` is nil. A non-nil
manifest is one complete immutable canonical snapshot, not paths or a resolver
callback, and is fixed for that runtime's lifetime. A newly imported
pack is therefore visible only after fresh discovery and a subsequent runtime
launch; it never mutates an already-running runtime. Validate counts, sizes,
digests and containment assertions before starting children. File contents total
at most 64 MiB; canonical metadata with content omitted totals at most 8 MiB.
Launch bytes never enter genesis or a command record. Before children start,
`Loopex.Runtime.start_link/1` atomically creates or matches one immutable
`resource_snapshot_binding_v1` in the Store's runtime-control namespace with
exactly `kind`, `runtime_id`, `workspace_ref`, `manifest_digest`, and
`binding_digest`. Manifest digest is nil exactly when the non-nil binding
envelope's `manifest` is nil.
The binding digest uses kind `loopex.resource_snapshot_binding/1` over the other
four exact members. Reopening the same durable runtime requires exact binding
equality; a missing, changed, or nil/non-nil mismatch refuses
`resource_binding_changed`. Ordinary use of changed bytes requires both a new
runtime identity and a new trust decision; a decision alone cannot replace the
durable binding. For every non-nil resource envelope, before submitting the
first binding transaction the host durably syncs the exact normalized snapshot
form and its verified provenance in its resource-retention store under
`{runtime_id, tx_id}`, reopens those bytes, and recomputes the same digest. The
retained bundle repeats the workspace and manifest identities and the complete
ordered imported-provenance dependency set; it is a per-runtime copy and is
never shared by two bindings, even when their manifest digests match. This
makes retirement ownership exact. The reference host admits at most 16 retained
resource-runtime bundles, 1 GiB of snapshot content and 128 MiB of canonical
metadata across them; reaching any limit returns
`resource_snapshot_capacity` before the Store transaction. Failure otherwise
refuses launch before the Store transaction and before any child starts. A
`commit_unknown` binding result keeps that retained snapshot; it
cannot be collected while the transaction may have committed. On every resume
the host reloads those retained bytes and recomputes their digest before
supplying the bound manifest. Missing, malformed, or digest-mismatched retained
bytes refuse launch as `resource_snapshot_unavailable` with zero children. This
retained snapshot is separate from installation and tool artifacts and never
substitutes for the fresh current-workspace attestation.

A nil manifest uses the same snapshot reservation, bundle, binding intent, and
retirement path. Its canonical snapshot preimage under kind
`loopex.resource_snapshot_retention/1` is exactly `%{"manifest" => nil,
"provenance_dependencies" => []}`; `manifest_digest` is nil, content and
metadata charges are zero, and dependencies are empty. It still consumes one of
the 16 runtime-snapshot slots. This gives the workspace-bound empty-skills form
the same crash recovery and prevents an untracked intent-only exception.

The per-runtime retained bundle is the closed record
`resource_snapshot_retention_v1` with exactly `kind`, `runtime_id`,
`binding_tx_id`, `workspace_ref`, `manifest_digest`, `snapshot_digest`,
`content_bytes`, `metadata_bytes`, and `provenance_dependencies`. Its separate
capacity reservation below precedes materialization and binds these exact
identity, digest, count, and dependency values. The reservation may advance to
`materialized` only after the bundle and its separately stored snapshot bytes
have been synced, reopened, and matched to every declared count and digest. That
state authorizes creation of only the prospective binding intent already bound
by the reservation; the Store call still requires `attached`.
`snapshot_digest` uses kind `loopex.resource_snapshot_retention/1` over the
normalized manifest plus every dependency row. Counts equal the retained bytes.
Each imported pack contributes one row, sorted by manifest pack order, with
exactly `source_id`, `pack_digest`, `import_generation_digest`,
`source_runtime_id`, `operation_id`, `attempt`, `store_terminal_tx_id`,
`store_terminal_record_digest`, `hand_receipt_digest`,
`evidence_package_digest`, and
`publication_identity`; locally authored packs contribute no row. Manifest,
provenance, receipt, Store, and publication members must match their respective
owners below. `evidence_package_digest` matches the attached evidence
reservation and reopened `resource_acquisition_evidence_v1` for the same
runtime/operation/attempt; that package's exact receipt and provenance generation
plus its Store terminal ID/digest pair in turn match the other row members and
the authoritative Store record. It is deliberately not
a field of the earlier committed provenance generation, which precedes Store
terminal and evidence-package creation.
The Store terminal record digest uses kind
`loopex.resource_acquisition_terminal/1`. Missing, duplicate, reordered, or
mismatched dependencies make the snapshot unavailable before a Store binding
call.

Aggregate host ceilings are enforced by one kernel-released capacity lock over
the protected-root reservation directory. There is no independently mutable
global counter. Each complete canonical reservation file is one inventory row;
the reference host uses the literal global directories
`<state_root>/resource-capacity/reservations/` and
`<state_root>/resource-capacity/evidence/` plus the lock label
`<state_root>/resource-capacity/resource-capacity.lock`. Every workspace-key
hand root configured under that state root shares this one lock and inventory;
per-workspace counting is invalid. These paths never enter core or a durable
product record. Under the lock the helper validates every ordinary no-follow
file and sums the
class counts and charges before creating, changing, or removing one. An unknown
label, malformed chain, invalid count, over-bound existing artifact, second
temporary file, or unavailable inventory makes capacity unavailable and is
never treated as free space.

The same locked inventory walks the fixed protected-state CLI-journal,
per-workspace snapshot/intent, attempt-log, provenance, and global evidence-
package directories.
Every complete artifact belongs to exactly one reservation in a state that
permits it, and every artifact required by an attached, retired, materialized,
or releasing reservation exists with the bound identity and digest. Only the one
identity/transaction/state-qualified partial form named by the recovery rules
may be completed or removed. Workspace scratch/staging is deliberately outside
that global walk because its path is not retained and only a supplied current
workspace-root handle may resolve it. Every acquisition reservation carrying attempt capacity still charges
the full 64 MiB; the matching object token and closed scratch shape are validated
when that root is supplied, and unavailable workspace evidence leaves the charge
intact. An unmatched protected-state artifact, duplicate owner, attached-
artifact mismatch, or unrecognized temporary byte makes capacity unavailable;
it is never omitted from accounting or adopted by a new operation.

Every reservation has the exact member set below. Its derived
`reservation_digest` uses kind `loopex.resource_capacity_reservation/1` over the
complete canonical record bytes; it is not another record member.
`transaction_id` uses kind `loopex.resource_capacity_transaction/1` over the
complete candidate record with `transaction_id` omitted. The canonical filename
uses kind `loopex.resource_capacity_reservation_key/1` over exactly `%{"kind" =>
kind, "key" => key}`, where key is the CLI local operation ID, the snapshot
runtime/binding-transaction pair, or the attempt runtime/operation/attempt tuple
as applicable. A create or update uses one temporary name derived
from the reservation key and transaction ID. Under the capacity lock the helper
first resolves that exact temporary name, writes and syncs complete candidate
bytes, reopens and validates them, performs a no-replace create or expected-
generation/prior-digest atomic replacement, syncs the parent, and reopens the
winner. Create or replacement uncertainty is resolved from the canonical file,
generation and digest. An exact replay matches; different bytes conflict. A
sole exact complete temporary file may finish its interrupted transaction. An
incomplete generation-zero create temporary file may be removed only when the
canonical file is absent and the class-specific boundary was forbidden before
installation. An incomplete successor-update temporary file may be removed and
recreated when the canonical file still byte-matches that transaction's exact
expected generation and digest and no successor is installed. Any other
predecessor, successor, or temporary relation is unavailable.

```text
skill_cli_reservation_v1
  kind, generation, prior_digest, transaction_id, state,
  local_operation_id, runtime_id, journal_frame, journal_frame_digest,
  journal_bytes_charge

resource_snapshot_reservation_v1
  kind, generation, prior_digest, transaction_id, state,
  runtime_id, binding_tx_id, workspace_ref, manifest_digest, snapshot_digest,
  binding_intent_digest, content_bytes_charge, metadata_bytes_charge,
  provenance_dependencies, release_proof_digest

resource_acquisition_reservation_v1
  kind, generation, prior_digest, transaction_id, state,
  runtime_id, command_id, operation_id, attempt, preparation_id,
  preparation_digest, preparation_record_digest,
  canonical_request_digest, canonical_grant_digest,
  store_attempt_tx_id, store_attempt_transaction_digest,
  store_attempt_transaction, scratch_bytes_charge, log_bytes_charge,
  evidence_bytes_charge, local_proof_digest, settlement_observation,
  preparation_release_proof_digest, attempt_release_proof_digest,
  evidence_package_digest,
  evidence_release_proof_digest
```

Generation zero has nil `prior_digest`; every successor increments by one and
binds the complete prior reservation digest. Key, identity, and charge members
repeat byte-for-byte. A snapshot's `release_proof_digest` is nil until
`releasing`; the releasing successor binds the exact retirement/idle/use proof.
An acquisition reservation's preparation and transaction members repeat
byte-for-byte for its lifetime. Its three charges are fixed at 64 MiB, 16 MiB,
and 2 MiB. The state determines which charges count after effect evidence is
attached; changing their literal values is never a release. The three proof
members and evidence-package digest follow the state table below. No member,
state, transition, or nullability relation beyond those listed here is legal.
The attempt release proof uses kind `loopex.resource_attempt_release/1` over
exactly `%{"local_proof_digest" => digest, "settlement_observation" =>
complete_settlement_observer_result}`. The snapshot release proof uses kind
`loopex.resource_snapshot_release/1` over exactly `retirement_kind`,
`retirement_digest`, the complete Store-idle observation, and the canonical
empty staged/admitted-use inventory. `retirement_kind` is `cli_retired`, whose
digest names the exact retired CLI frame, or `embedding_retired`, whose digest
names the exact host retirement record below. The retained-evidence release
proof uses kind `loopex.resource_evidence_release/1` over exactly its current-provenance absence,
the complete validated snapshot-reservation inventory digest, and the canonical
empty staged/admitted-use inventory. A missing or unrepeatable proof prevents
the releasing transition.

Three physical reservation classes enforce four logical ceilings:

- `skill_cli_reservation_v1`, keyed by `local_operation_id`, embeds the complete
  generation-zero `prepared` journal frame and binds its digest plus runtime ID.
  The embedded frame is at most 64 KiB, its digest is the exact
  `loopex.skill_cli_operation/1` digest, and both repeat byte-for-byte in every
  reservation generation.
  States are `reserved`, `attached`, and `retired`. `reserved` precedes journal
  materialization; the byte-identical journal must reopen before `attached`; no
  Store call is legal before `attached`. Retirement syncs the journal's retired
  frame first and the reservation's retired successor second. Both remain as
  permanent runtime-ID reuse fences. Up to 1,024 files charge 512 KiB each and
  512 MiB total in every state; physical retirement compaction does not release
  the logical charge or lifetime slot.
  Recovery of `reserved` plus an absent journal can materialize only the embedded
  generation-zero frame; `reserved` plus that exact journal advances to
  `attached`. `Attached` plus an absent or mismatched journal is unavailable.
  An attached reservation plus an exact retired journal advances only to
  `retired`, and a retired reservation requires that exact retired journal.
  None of these repairs makes a Store call.
- `resource_snapshot_reservation_v1`, keyed by `{runtime_id, binding_tx_id}`,
  binds workspace, manifest, snapshot and prospective binding-intent digests, exact content
  and metadata charges, and the full ordered provenance dependencies. States are
  `reserved`, `materialized`, `attached`, and `releasing`. `reserved` precedes
  the snapshot. The complete snapshot bundle and bytes must reopen and match
  before `materialized`; only that state may create the exact prospective intent.
  Both snapshot and intent must reopen before `attached`; no Store binding call
  is legal before `attached`. A reserved or materialized crash may finish exact artifacts or remove
  only its proven partial artifacts and reservation because the boundary was not
  crossed. `attached` survives binding `commit_unknown`. `releasing` retains its
  full charge and dependency pins until snapshot and intent absence are reopened,
  then the reservation is removed and the parent synced. Up to 16 reservations
  charge at most 1 GiB of snapshot content and 128 MiB of metadata.
- `resource_acquisition_reservation_v1`, keyed by
  `{runtime_id, operation_id, attempt}`, atomically owns the attempt's 64 MiB
  scratch charge, 16 MiB log charge and 2 MiB prospective retained-evidence
  entitlement. Generation zero is created by `prepare/2` before the embedded
  Store attempt transaction may be submitted. It binds the complete exact
  preparation record and Store transaction, so a crash cannot leave a committed
  attempt with no bounded tombstone or evidence capacity and cannot strand one
  half of a split reservation. Up to six reservations that still carry attempt
  charges consume at most 480 MiB; up to 1,024 reservations that carry evidence
  entitlement or retained evidence consume at most 2 GiB. Both independent
  ceilings must admit generation zero. Capacity refusal therefore happens before
  Store attempt commit and cannot require an off-budget reconciliation record.

The acquisition reservation has exactly these states and nullability:

| State | Legal successor and retained relation | Counted charge |
| --- | --- | --- |
| `prepared` | generation zero only; all proof, settlement and package members nil; embeds the one Store attempt transaction. Exact local admission may exist only at the interrupted attach cut. It may advance to `attached`, `preparation_releasing`, `attempt_releasing`, or remain for exact transaction resolution | scratch + log + evidence |
| `preparation_releasing` | only after the observer proves that embedded attempt transaction finally did not commit; only `settlement_observation` and `preparation_release_proof_digest` are non-null | scratch + log + evidence until reservation absence is reopened |
| `attached` | requires the exact admission and generation-zero active authority; all proof, settlement and package members nil. Open, commit-unknown, quarantined and outcome-unknown attempts remain here | scratch + log + evidence |
| `attempt_releasing` | only after exact local terminal or `revoked/not_dispatched` proof and matching committed Store settlement; local proof, settlement and attempt-release proof are non-null; evidence members remain nil | scratch + log + evidence until scratch, log and reservation absence are reopened |
| `evidence_materializing` | same local and Store proof as `attempt_releasing`, plus the prospective non-null evidence-package digest; package may be absent, partial only in the one recoverable temporary form, or exact | scratch + log + evidence |
| `evidence_releasing` | exact evidence package is synced and reopened; all attempt proof and package members are non-null; evidence-release proof is nil | scratch + log + evidence until scratch and log absence are reopened |
| `evidence_attached` | exact evidence package remains; attempt proof and package members are non-null; evidence-release proof is nil; scratch and log are proved absent | evidence only |
| `evidence_retiring` | `evidence_attached` plus the non-null dependency-absence evidence-release proof | evidence until package and reservation absence are reopened |

`preparation_release_proof_digest` uses kind
`loopex.resource_preparation_release/1` over the complete
`attempt_not_committed` settlement observation and the preparation-record
digest. Every other state requires it to be nil. `attempt_release_proof_digest`
uses the attempt release proof defined above and is non-null exactly from
`attempt_releasing` or `evidence_materializing` onward. `evidence_package_digest`
is non-null exactly in the four evidence states. `evidence_release_proof_digest`
is non-null only in `evidence_retiring`. `local_proof_digest` and
`settlement_observation` are both nil or both non-null, except that
`preparation_releasing` carries only the settlement observation. A state change
cannot alter any preparation, transaction, identity, request, grant or charge
member.
The complete acquisition reservation is at most 256 KiB. A candidate that
cannot contain the already bounded preparation and transaction within that
limit is an authoritative preparation refusal before Store submission; no
truncation or external locator substitutes for the embedded bytes.

`prepare/2` validates the complete preparation, current initialized
workspace/executor binding and advertised capability envelope without invoking
the current-attempt observer, because the Store attempt does not exist yet. Under
the capacity lock it inventories every class and either creates and reopens the
one exact `prepared` reservation or returns exact replay. A different retained
preparation at the key or ID is unavailable. A lost reply is resolved only by
`prepared/3`. `release_preparation/2` invokes the settlement observer, requires
the exact `attempt_not_committed` form for the embedded transaction, advances to
`preparation_releasing`, removes no attempt log or workspace path because none
may have been authorized, removes and reopens reservation absence, and syncs the
parent. An absent transaction is re-presented rather than released; Store
unavailability or `commit_unknown` retains the full charge.

After the Store attempt commits, `acquire/3` takes the capacity then attempt lock,
reopens the exact `prepared` reservation, invokes the current-authority observer
and races any solicited reconciliation at that lock. If admission wins, it
atomically appends and reopens admission plus generation-zero active authority,
then advances the reservation to `attached`; guard release requires both. A
crash with exact admission under `prepared` may only finish that transition. If
the current responder wins while admission and authority are absent, it appends
the exact `revoked/not_dispatched` tombstone and response; a later committed
Store result authorizes the direct `prepared` to `attempt_releasing` transition.
Any other partial or mismatched relation is unavailable. Thus delayed dispatch
and reconciliation have one winner and neither can create unreserved state.

Each reservation contributes the state-specific charge in the table until its
canonical file or authorized successor is durably established; every releasing
state still counts, and dependency pins remain through evidence retirement. A
CLI reservation is never deleted. A snapshot may enter `releasing` only after one exact synced retirement
source, a Store idle proof, and proof that no staged or admitted use names the
binding. The reference CLI source is its retired journal frame. For direct
embedding, trusted composition supplies a private `retention_ref`; after the
embedder stops the runtime, its host-only `retire_runtime(retention_ref,
runtime_id, retirement_id)` operation holds the same runtime lock, rechecks
Store idle and the empty-use inventory, then writes and
reopens `resource_runtime_retirement_v1` with exactly `kind`, `runtime_id`,
`retirement_id`, `binding_tx_id`, `store_idle_observation_digest`, and
`use_inventory_digest`. The record is at most 16 KiB and its canonical digest
uses kind `loopex.resource_runtime_retirement/1`. It authorizes only the matching
snapshot releasing transition and can be removed after that reservation is
durably absent. The historical Store binding remains and its runtime ID remains
non-reusable. Exact operation replay returns the retained result; reuse of the
retirement ID with different bytes conflicts; unavailable Store or inventory
truth returns unavailable without a record or cleanup. This is a host-private
retention operation, not a core/session facade or wire command. Every provenance retirement or compaction
takes the capacity lock and refuses to remove a generation named by any snapshot
reservation or acquisition evidence package.

Attempt capacity remains charged through open, commit-unknown, outcome-unknown
and quarantined states. Before each new preparation or admission and during executor-local startup recovery,
the hand checks release candidates under the capacity then attempt lock. Release
requires its host-owned settlement observer to prove either the exact matching Store terminal or
the exact committed reconciliation result that returned the attempt to
`pending_policy` as `not_dispatched`. Store unavailability, result-commit
ambiguity, or a digest/ordinal mismatch retains the reservation. Before deleting
anything, the hand appends or reopens the immutable local terminal or
`revoked/not_dispatched` proof and computes one release-proof digest over that
local proof plus the exact settlement-observer result. It then follows exactly
one branch.

For proven `not_dispatched`, or a known non-unknown terminal needing no retained
local evidence, recovery advances `prepared` or `attached` to
`attempt_releasing`, removes only exact-owned scratch and the local log, reopens
their absence, then removes the reservation and syncs the parent before another
attempt may be prepared. `terminal_quarantined` and every `outcome_unknown`
remain fully charged in `attached` and cannot enter this branch. For a proven
terminal whose receipt or provenance remains required, recovery advances
`attached` to `evidence_materializing` with the prospective immutable-package
digest, writes, syncs and reopens that package, advances to
`evidence_releasing`, removes exact-owned scratch and the attempt log, reopens
their absence, then advances to `evidence_attached`. Only this last transition
releases the 80 MiB attempt charge; the 2 MiB evidence entitlement remains.
Every releasing or materializing state retains the full charge and is the sole
cleanup authority after a crash. Exact conversion replay uses the same
generations and digests. Retained evidence may advance to `evidence_retiring`
only after no current provenance generation, snapshot dependency, staged
request, or admitted use names it. Recovery then removes and reopens package
absence, removes the reservation, and syncs the parent. No cross-form proof is
accepted. These rules preserve bounded progress without treating an unknown
Store result or elapsed cleanup time as free capacity.

The immutable evidence package is the closed record
`resource_acquisition_evidence_v1` with exactly `kind`, `runtime_id`,
`command_id`, `operation_id`, `attempt`, `canonical_request_digest`,
`canonical_grant_digest`, `receipt`, `receipt_digest`, `completion_intent`,
`completion_intent_digest`, `provenance_generation`,
`import_generation_digest`, `store_terminal_tx_id`,
`store_terminal_record_digest`, `git_metadata_digests`, and `evidence_digest`.
Its filename is the canonical digest under kind
`loopex.resource_acquisition_evidence_key/1` of the runtime/operation/attempt
tuple. `evidence_digest` uses kind `loopex.resource_acquisition_evidence/1` over
every other member. The receipt, intent and provenance members are the exact
retained bytes and digests defined by their owners. The Store remains the
authoritative owner of terminal bytes: the package retains only its exact
transaction ID and canonical record digest, and recovery must re-read and match
that Store record before using them. Neither pair is evidence of terminal truth
when the Store read is unavailable. No projection of the three copied records is
accepted.

`git_metadata_digests` is the exact ordered list of one map per authenticated
metadata reply with exactly `command_ordinal`, `command_kind`, and
`reply_digest`. Ordinals start at zero and are consecutive; command kind is
`commit_type`, `selected_tree`, `tree_walk`, `object_type`, or `object_size`;
reply digest is the per-reply `loopex.git_metadata/1` digest below. The list has
at most 131 rows: three fixed replies plus type and size for each of at most 64
accepted files. The 512 KiB completion-intent frame, 512 KiB provenance slot,
48 KiB receipt, digest list, Store ID/digest pair and canonical framing fit the
package's 2 MiB bound. A candidate that does not fit keeps the attempt charge
and makes retention unavailable rather than dropping evidence.

`current_attestation` is validated launch evidence and is never part of the
immutable snapshot-binding digest. It is a closed map with exactly `kind`,
`workspace_ref`, `workspace_lease`, `state`, `manifest_digest`, and `reason`.
`kind` is
`resource_workspace_attestation_v1`; workspace reference and lease are
nonempty opaque UTF-8 binaries of at most 1,024 bytes, and the complete
canonical map is at most 8 KiB. `state`
is `match`, `changed`, or `unavailable`. `match` has nil reason and a manifest
digest exactly equal to the supplied bound manifest's digest, including
nil/nil equality. `changed` has reason `manifest_changed` and the freshly
observed digest, including nil when the current directory is absent, differs
from the bound digest. `unavailable` has nil manifest digest and reason exactly
`workspace_unavailable`, `skills_root_invalid`, `snapshot_invalid`, or
`workspace_lease_changed`. No other state, reason, or nullability relation is
valid. Its workspace reference equals the outer envelope, and its lease equals
the trusted current acquisition-hand launch binding; a host that cannot
establish that equality uses `workspace_lease_changed`. The trusted host
produces this map from one complete fresh discovery under that named live
workspace lease; model content, retained
snapshot bytes, destination-only inspection, and the caller's asserted state
cannot produce it. Core verifies the exact member set, bounds, binding, and
state relation but does not treat this host assertion as filesystem authority
of its own. The acquisition `fencing_token` is a separate Store attempt fence;
it never enters or authenticates this workspace attestation.

`binding_intent` is the exact durable host pre-submit authority for one snapshot
binding transaction. It is a closed map with exactly `kind`, `runtime_id`,
`workspace_ref`, `manifest_digest`, `binding_digest`, `tx_id`,
`canonical_binding_bytes`, `canonical_mutation_digest`,
`authorized_attestation`, and `authorized_attestation_digest`. `kind` is
`resource_snapshot_binding_intent_v1`; the authorized attestation is the complete
exact `match` attestation used to authorize first submission, and its digest is
the canonical SHA-256 digest under kind
`loopex.resource_workspace_attestation/1`. Every other member equals the binding
and transaction defined below. The complete intent is at most 32 KiB and its
canonical digest uses kind `loopex.resource_snapshot_binding_intent/1`.

After retaining any non-nil snapshot bytes and while the attestation is still an
exact match, the host creates this intent with no-follow/no-replace semantics
under `{runtime_id, tx_id}`, syncs and reopens it, and verifies its complete bytes
before the first Store submission. Exact replay is idempotent; changed bytes at
that key conflict. Failure or uncertainty refuses launch with zero Store calls
and zero children. The intent is retained with the snapshot until the runtime
root is retired. It authorizes re-presentation of only those exact transaction
bytes after process loss, including when the current workspace later changes;
it never authorizes another binding or ordinary resource use.

Every start first makes the bounded Store observation
`resource_snapshot_binding(runtime_id)`, which returns
`{:ok, :absent | resource_snapshot_binding_v1}` or
`{:error, :store_unavailable}` and grants no mutation authority. A non-nil
launch for an unused runtime identity requires the exact durable binding intent.
Creating that intent requires a `match` attestation. Once it exists, an absent
Store binding re-presents only its exact authorized transaction, even if the
fresh attestation is now changed or unavailable; this settles the earlier
authorized cut and cannot originate a different binding. No child starts until
the result is known. A committed binding with a non-match fresh attestation
enters recovery-only mode. An
existing resource-enabled identity requires the supplied bound manifest and
workspace reference and intent to equal its retained binding. With a matching current
attestation it starts normally. With `changed` or `unavailable` it may start
only in `resource_recovery_only` mode so already committed work remains
settleable without accepting the changed source as trusted content. An omitted
binding with an existing binding refuses `resource_binding_changed`; a Store
observation that is unavailable returns the ordinary Store-unavailable launch
error. The create-or-match transaction, rather than this observation, remains
the authority for first placement. ADR 0008's one-Control-per-Store/runtime
host rule also forbids racing nil and non-nil launches for one identity; M3
adds no active-active arbitration outside the Store checks stated here.

The launch entrypoint submits exactly this second, bootstrap-only Store
transaction family:

```text
%{
  type: :resource_snapshot_binding_commit,
  runtime_id: runtime_id,
  tx_id: tx_id,
  binding: resource_snapshot_binding_v1,
  canonical_binding_bytes: canonical_binding_bytes,
  canonical_mutation_digest: canonical_mutation_digest
}
```

`tx_id` is the lowercase SHA-256 canonical digest under kind
`loopex.resource_snapshot_binding_tx/1` of exactly `%{"runtime_id" =>
runtime_id, "binding_digest" => binding_digest}`. It is therefore recoverable
after process loss without a child process or separately retained random value.
Canonical binding bytes encode the complete exact record; `canonical_mutation_digest` uses kind
`loopex.resource_snapshot_binding_commit/1` over `type`, `runtime_id`, `tx_id`
and those bytes. The transaction is at most 16 KiB. In one atomic
linearization against every record namespace for that runtime identity, an
absent binding plus no retained runtime-control, placement, session-genesis or
journal state creates that exact binding; an identical existing binding returns
its retained committed resolution without rewriting; and either a different
binding or absent binding with any retained runtime state returns `not_committed`
with `resource_binding_changed`. Binding creation and the existing first runtime/
session placement transition share this Store serialization point: if raced,
exactly one wins, and no preflight read can authorize both. Store outcomes remain exactly `committed`,
`not_committed` and `commit_unknown`. The transition catalogue adds
`runtime_resource_snapshot_binding_commit` with
`before_linearization`, `after_linearization_before_result` and
`recovery_representation`; declared, injected and observed faults must match.
On `commit_unknown`, that `start_link` call returns
`{:error, :resource_binding_commit_unknown}` with zero children. A later call,
including from a fresh process, derives the same transaction ID and re-presents
the identical transaction before doing anything else; it returns the same error
while the Store still cannot resolve it. No bootstrap process or retry loop
survives the call. No supervisor, Control, registry, session or other runtime
child starts until an exact committed create-or-match result exists. Store
unavailability returns the ordinary Store-unavailable launch error. Neither case
creates a partial runtime.

A runtime identity with retained state and no snapshot-binding record is a
resource-disabled runtime. M3 may open it only with `resource_binding: nil` in
`legacy_no_resources` mode, without writing a binding or changing its existing
record forms. Resource acquisition, admission, activation, catalog and reads are
unavailable for that identity; enabling resources requires a new runtime
identity and the binding transaction above. A new identity with
`resource_binding: nil` likewise writes no binding, retains M2-compatible record
forms and cannot later gain resources under that identity after durable state
exists. A new identity with a non-nil envelope always commits a binding,
including the nil-manifest form. This resource-disabled form is the sole
exception to the pre-child binding rule and preserves core-only and genuine M2
starts without silently upgrading their format.

On resume, `manifest` is the retained immutable snapshot named by the Store
binding, while `current_attestation` reports a freshly discovered and
revalidated current snapshot. The attestation covers the literal
`.agents/skills` directory identity, its complete
immediate entry set, every admitted child-directory identity, and every pack's
complete walked file set under the same live workspace lease. It must
therefore detect a new, removed, renamed, or replaced pack as well as changed
bytes. An ordinary start requires the recomputed manifest digest to equal the
bound manifest; a retained snapshot or per-destination spot check by itself is
not current-workspace evidence. A mismatch starts only the recovery mode described above;
ordinary use requires a new runtime binding plus trust decision. Recovery-only
first returns retained truth for exact replay of any already committed
`resource_command_v1` or resource-acquisition command before current-binding or
mode validation. The sole pre-commit continuation is a reference-CLI
`command_resolving` frame durably authorized under a matching attestation before
the current change: recovery first re-presents its exact command transaction,
then commits `unavailable/resource_binding_changed` from `pending_policy` with
zero policy, grant, attempt, hand or executor call. No request lacking that exact
write-ahead frame can use this path. Recovery-only also permits bounded status and inspection of retained truth,
continuation of that same retained operation, solicited reconciliation, completion of
an already active ordinary run, and source-free settlement of already staged
provider or acquisition bytes. Reconciliation may durably record
`not_dispatched` and return the operation to `pending_policy`, but recovery-only
parks it there with zero policy, grant, hand or executor call; only a later
exact-attestation-match normal-mode start may re-evaluate policy and create the
next attempt. It refuses every new run or acquisition command, admission,
activation, catalog, or resource-read request before policy, hand, executor, or
provider invocation with the existing bounded `resource_binding_changed`
reason. A live normal-mode runtime keeps its immutable launch snapshot through
acquisition and cannot discover or admit newly published bytes in place; a later
start chooses normal or recovery-only mode solely from its fresh attestation and
retained binding. Only a request already staged before interruption
is recoverable from retained staged bytes without a filesystem read, snapshot
substitution or network fetch. M3 proposes no hot replacement API, session
migration, or automatic retained-pack garbage collection.

A resource-enabled durable runtime identity is bound to exactly one
`workspace_ref` and zero or one immutable resource snapshot across process
restarts. Neither a nil nor non-nil snapshot binding can be replaced. A
decision, admission, resume, or query
naming another workspace or manifest refuses with `resource_binding_changed`; a
host that serves another workspace or changed manifest starts another runtime.
The resource-disabled form has no workspace/snapshot authority and follows the
legacy rule above.
The host owns durable snapshot and import-
provenance retention. Core keeps one normalized in-memory snapshot, up to the
64 MiB content and 8 MiB metadata ceilings, until runtime shutdown; sessions keep
only indices and digests plus already staged request bytes. Launch or prepared
resume may transiently hold the host input and the normalized core copy at once,
so peak startup residency can be two snapshot copies. It does not create a second
session-owned copy or a multi-workspace cache. The reference host retains hand
admissions/open attempts/receipts, import provenance and verified snapshots below
`<state_root>/resource-packs/<workspace-key>/`, where `workspace-key` is the
lowercase SHA-256 canonical digest of the opaque workspace reference under kind
`loopex.workspace_ref/1`. Its `hand`, `imports`, and `snapshots` subdirectories
are host data, never discovery roots or core-visible paths. Runtime acquisition
command/attempt/terminal truth remains in the Store's runtime-control namespace.
Equivalent embedders may use another protected hand store but must preserve the
same record identities, sync barriers and restart behavior.

Reference CLI:
`loopex skill add <source> --rev <commit> --path <directory> --name <name>` for
credential-free public HTTPS Git only, `loopex skill list`,
`loopex skill show <source-qualified-name>`, and `loopex run --skill <name>` for
explicit selection, with repeatable `--skill-resource <skill>:<label>` arguments
for supporting labels. Before trust, the CLI drives the exact
`Loopex.ResourcePackReview` algebra above; one bounded review cursor displays the
manifest digest, workspace repository origin/revision, every pack's source,
commit/tree identity and every file label, size and digest, followed by every
file body from the retained snapshot. Identity pages contain at most 32 file rows
and 32 KiB of canonical display data. Body pages carry at most 8 KiB of original
bytes and 24 KiB of canonical display data and bind the manifest digest, pack and
file indices, label, file digest, encoding, byte offset, page length and terminal
flag. A valid UTF-8 body uses `utf8_escaped`; another byte string uses lowercase
two-digit `hex`. Pages follow manifest, pack, file and byte order. A file counts
as reviewed only after its terminal body page, and confirmation is accepted only
after the terminal body page of every manifested file for that exact digest.
Zero-length files still have one terminal zero-byte page. The review cursor is
ephemeral and grants no trust; EOF, skipped/out-of-order pages, refusal or any
changed digest admits nothing.

The terminal view never writes pack-controlled bytes directly. For every valid
UTF-8 metadata or body value it emits printable ASCII U+0020 through U+007E
unchanged except that backslash becomes `\\`, and renders every other Unicode
scalar as exactly `\\u{` plus six uppercase hexadecimal digits plus `}`. Binary
body pages emit only lowercase hexadecimal. Constant field labels, page counters
and the confirmation prompt are emitted outside those projections. C0/C1
controls, ESC, DEL, bidi controls and other nonprinting/format characters
therefore cannot alter terminal state or forge a prompt. The projection is
presentation only; digests and trust bind the original canonical bytes. Headless
hosts receive the same ordered review records with body bytes encoded as
unpadded RFC 4648 base64url structured fields, not terminal escapes, and must
enforce the same cursor and exact-digest completion rule before supplying a
decision explicitly. Add never implies trust. The acquisition policy
must allow the exact request before an attempt is
committed and a grant is minted. A script used later as an ordinary tool remains
subject to the existing tool policy and grant.

Every `skill add` invocation allocates a fresh administrative `runtime_id`,
`command_id`, and local operation handle. Under the runtime, operation, and
capacity locks it first creates the `reserved` CLI reservation containing the
exact generation-zero frame, then materializes and reopens that byte-identical
journal and advances the reservation to `attached`. Only after that sequence may
it submit a binding or acquisition Store call. The journal's immutable host
record is:

```text
skill_cli_operation_v1
  kind, generation, prior_digest, state, disposition,
  local_operation_id, runtime_id, workspace_ref, manifest_digest,
  binding_digest, binding_tx_id, binding_intent_digest,
  command_id, command_digest, command, operation_id,
  store_observation_digest
```

All IDs are nonempty binaries of at most 256 bytes, `command` is the complete
canonical acquisition command, its digest is the command digest defined below,
and the workspace/manifest/binding members equal the exact non-nil launch
envelope, durable binding intent and derived Store binding transaction for that
administrative runtime. Each frame is at most 64 KiB, so every legal 16 KiB
command plus its fixed identities fits. The reference CLI generates each of its
three IDs as independent 128-bit cryptographic random values encoded as 32
lowercase hex bytes and rejects a journal, reservation, runtime, command,
operation, or Store collision before submission. The reference host retains at
most 1,024 such operation journals and matching reservations under the same
protected state root as its Store and acquisition hand. A journal contains at
most eight append-only frames and 512 KiB; the capacity charges above apply. A new add refuses
`operation_journal_full` before any Store call when any bound is reached.

The portable journal filename is the canonical digest under kind
`loopex.skill_cli_operation_key/1` of exactly `%{"local_operation_id" =>
local_operation_id}`, not that opaque ID. Every frame's canonical digest uses
kind `loopex.skill_cli_operation/1` over the complete record; `kind` is exactly
`skill_cli_operation_v1`. Initial, resume, status and forget paths all take the
same per-operation kernel-released exclusive lock and keep it across each
write-ahead frame, Store call and authoritative result fold. Every successor
increments the generation, binds the complete prior-frame digest, repeats every
immutable identity/command byte exactly, syncs the append and parent, then
reopens and validates the whole chain before proceeding. A retry in a resolving
state reuses that existing synced frame rather than appending another. Exact
successor replay is idempotent; a changed frame conflicts. Each physical frame
is an unsigned 32-bit big-endian nonzero canonical-byte length, those exact
bytes, and their 32-byte SHA-256 digest. Under the operation lock, reopen parses
from offset zero. A final EOF inside one frame is the sole repairable form: the
helper truncates to the last complete validated boundary, syncs the file and
parent, reopens and validates, then resumes from that last frame. A crash during
repair repeats the same truncation. A complete bad digest, broken prior-digest
chain, interior garbage, over-bound length, or bytes after a complete final
frame are corruption and remain unavailable; none grants submission authority.

Every reference-host start, resume, acquisition call, status/reconciliation
call, and retirement for a resource-enabled `runtime_id` also takes one
kernel-released runtime lock from before retained-state inspection until that
runtime process exits. The lock namespace is shared across all CLI operation
journals and direct embedding on that host. A retired journal is a permanent
reuse fence for its runtime ID. This serializes an idle Store observation and
snapshot cleanup against every possible new command or runtime start; a host
that cannot route all entrypoints through that lock cannot use CLI retirement.

The closed state/field relation is:

| State | Legal predecessor | Disposition | Operation ID | Store-observation digest |
| --- | --- | --- | --- | --- |
| `prepared` | none; generation zero only | nil | nil | nil |
| `intent_ready` | `prepared` | nil | nil | nil |
| `binding_resolving` | `intent_ready` | nil | nil | nil |
| `command_resolving` | `binding_resolving` after authoritative binding commit/match | nil | nil | non-null binding-match plus command-absent observation |
| `operation_open` | `command_resolving` after accepted command | nil | exact non-null returned operation ID | non-null accepted/open observation |
| `terminal` | `prepared`, `binding_resolving`, `command_resolving`, or `operation_open` as constrained below | one terminal disposition | disposition-specific | disposition-specific |
| `retired` | `terminal` only | unchanged | unchanged | unchanged |

The terminal dispositions are closed. `binding_changed_before_submit` is legal
only from `prepared` and has nil operation/observation because no intent or Store
submission state ever existed. `binding_changed_before_command` is legal only
from `binding_resolving` after its exact transaction resolves and before a
`command_resolving` frame exists. It has nil operation and binds the complete
binding result plus command-absent observation.
`command_busy` is legal only from `command_resolving`, has nil operation, and
binds the complete busy observation plus a later exact idle-slot observation.
Until the slot is idle it remains `command_resolving`. `command_terminal` is legal only from
`operation_open`, preserves its operation ID, and binds a matching observation
whose state is exactly `terminal`; `terminal_quarantined` keeps the journal
`operation_open` and cannot retire. Its slot observation is likewise exactly
idle. No other state, edge, disposition or
nullability is valid.
`intent_ready` follows only after the snapshot and binding intent are durably
reopened and their snapshot reservation is `attached`. A `materialized`
reservation may finish that exact intent and attach; only while the CLI journal
remains `prepared` and no Store call was possible may recovery instead remove
its exact artifacts through the reserved cleanup path. `binding_resolving` is
synced before its first binding mutation and
`command_resolving` is synced after its non-authorizing binding/command reads but
before its first command mutation. `retired` authorizes only bounded host cleanup. Lock, create,
append, sync, reopen, decode, bound, capacity, or durability uncertainty is
`operation_journal_unavailable`; a possibly submitted state must be resolved,
never treated as absent. Crash-cut evidence covers every transition and Store
call.

Before accepting another `skill add`, every reference CLI startup and
`loopex skill operation list` takes the capacity lock and inventories all CLI
reservations. A `reserved` reservation with an absent journal must materialize
and reopen only its embedded generation-zero frame; a byte-identical journal
advances it to `attached`. The command then lists every attached or retired
handle, including those reconstructed after a process died before displaying
the handle. A missing or conflicting reservation/journal relation makes the
inventory unavailable and refuses a new add; no lifetime slot can remain hidden
from the operator enumeration.

`loopex skill operation list` pages at most 32 handles per response,
`loopex skill operation resume <local-operation-id>` reopens the exact recorded
runtime, retained snapshot, binding intent and journal under the same operation
lock, freshly attests the current workspace, and follows only the recorded state.
A changed workspace in `prepared` records terminal
`binding_changed_before_submit` with zero Store calls. Once `intent_ready` has
advanced to `binding_resolving`, resume must re-present only that exact binding
transaction until its disposition is authoritative, even after a source change.
After a committed/matching binding and before writing `command_resolving`,
resume reads the exact command identity. If it is absent and the attestation
changed, it records terminal `binding_changed_before_command` with zero command
mutation. Once `command_resolving` is synced, a crash may have left the original
Store call in flight, so even a later absent read cannot authorize retirement.
Resume re-presents only the exact recorded command until its disposition is
authoritative. An accepted result advances to `operation_open`; under a changed
attestation Runtime Control then commits the exact
`unavailable/resource_binding_changed` terminal through its recovery-only path
after `prepared/3` proves absence, with zero policy, grant, attempt, `prepare/2`,
`acquire/3`, or `reconcile/2` call. A busy result remains resolving
until the runtime slot is idle. Restoring old source bytes cannot reverse a
terminal journal disposition.

`loopex skill operation forget <local-operation-id>` operates only from a
durable `terminal` journal while holding both the operation and exclusive runtime
locks. For `command_terminal` or `command_busy`, the Store must also prove the
runtime slot idle; the runtime lock keeps that observation true through cleanup.
It appends `retired` before removing only this runtime's `{runtime_id, tx_id}`
snapshot bundle and binding-intent bytes through identity-checked no-follow
operations. It then advances the matching CLI reservation to `retired` and the
snapshot reservation to `releasing`; after reopened absence of the snapshot and
intent it removes only the snapshot reservation. The compact journal and CLI
reservation remain the host reuse fences while the Store root exists. A crash
after `retired` retries only these state-bound cleanup steps, and exact replay is
idempotent. `prepared`, resolving, open, unknown, unavailable, corrupt,
conflicting or unproved journals cannot be forgotten. Because every initial,
resume and forget path shares the lock and a Store call must have its preceding
resolving frame, an in-flight transaction cannot appear after retirement.
A lost
acceptance reply is therefore recoverable without inventing an operation ID or
redispatching Git: exact command replay returns the Store's retained operation
identity, and status or reconciliation continues from there. A crash after the
binding submission but before the command either resumes the exact binding or
settles the no-effect retirement path above; it cannot strand an unbounded
snapshot or manufacture command history. This host journal is recovery state,
never command, policy, Store terminal, or provenance truth.

The administrative runtime resumes in `resource_recovery_only` only when its
fresh attestation is changed or unavailable; exact replay/status/reconciliation
remain available there. Once the operation settles, that CLI process
exits. A later `loopex run --skill <name>` always uses a different fresh runtime
identity, freshly discovers the complete changed manifest, creates its own
matching snapshot binding, displays that digest, and obtains a new operator
trust decision before admission and selection. It joins imported provenance
through the `skill_import_v1` generation's retained source `runtime_id` and
operation ID against the same Store and hand state root. Existing sessions stay
bound to their old runtime and snapshot; they can inspect and settle retained
work in recovery mode but never migrate or adopt the installed bytes in place.

### Canonical manifest and limits

`manifest` has exactly `version`, `workspace_ref`, `repository_origin`,
`revision`, `packs`; version is `loopex.resource_manifest/1`. `repository_origin`
describes the workspace repository, not an imported pack source. It is nil or
the exact already-canonical, credential-free public HTTPS byte grammar defined
for `source` below, with the same 1,024-byte bound and no equivalence rewriting.
The reference host maps an absent, SSH/scp, local/file, userinfo, explicit-port,
query, fragment, percent-escaped, noncanonical, or credential-bearing remote to
nil; raw remote configuration never enters core, display, retention, or a
digest. Core refuses a non-nil value outside that grammar. This resource-pack
field does not change ADR 0010 root-AGENTS `repository_origin` semantics.
`revision` is a bounded UTF-8 host observation of at most 1,024 bytes or nil. A
non-null Git revision is its exact native object ID; another host revision
scheme is a bounded opaque identity. A pack has exactly
`source_id`, `origin`, `commit`, `tree_digest`, `name`, `description`,
`manual_only`, `files`. Origin is a bounded sanitized source descriptor with no
credential/query secret. For imported packs, `commit` is the exact Git commit
object ID and `tree_digest` is the selected directory's Git tree object ID.
Both use the repository's native object format: 40 lowercase hex characters for
SHA-1 or 64 for SHA-256, with matching formats. Locally authored project packs
use `origin: "project"`, `source_id: "project:" <> name`, and null commit and
tree identity; they must never claim verified remote provenance. Imported
`source_id` is `"git:"` followed by the lowercase SHA-256 canonical digest under
kind `loopex.skill_source/1`. Its value is exactly
`%{"source" => sanitized_source, "commit" => native_commit_id,
"source_directory" => normalized_source_directory}`. Rediscovered project bytes may
carry that imported identity and non-null commit/tree identity only through the
matching retained hand receipt, Store terminal and `skill_import_v1` record
defined below. Each file
has exactly `label`, `size`, `digest`, `content`, `contained`; content is binary,
size and SHA-256 must match, contained must be true. Labels are relative display
strings only. The manifest digest covers normalized metadata and every file's
identity, size and digest, not just SKILL.md. Sort packs by source_id/name and
files by label. Reject duplicate identity, duplicate label or normalized-path
collision before publication or admission. `SKILL.md` is the one instruction
label and is never legal in `supporting_labels`; it cannot be staged twice. An
ambiguous unqualified name refuses;
there is no search-order authority.

Discovery is a fixed two-phase walk. Phase one opens the canonical workspace's
literal `.agents/skills` directory without following links and enumerates at most
64 immediate ordinary directories whose basenames satisfy the skill-name grammar;
any additional entry, invalid name, link or special object refuses the complete
snapshot. Phase two opens each selected child by its retained directory identity,
requires the one ordinary top-level `SKILL.md`, requires its parsed frontmatter
`name` to equal that child basename, and performs one content-
independent depth-first walk below that child. The walk admits at most 64 ordinary
files, 1 MiB total bytes, 1,024-byte normalized relative labels and eight relative
components. It refuses symbolic links, hard links, gitlinks, sockets, devices,
FIFOs, parent/absolute escapes, normalization collisions and identity changes
during the read. Names, frontmatter and file content cannot add a root, filename,
glob, pattern or recursion decision. The hand returns a complete immutable plain-
data snapshot; core never repeats the walk.

An absent literal `.agents/skills` directory yields `manifest: nil` inside the
host's non-nil resource-binding envelope. An existing ordinary directory yields
a non-nil manifest even when it contains
zero packs, so absence and an attested empty directory are distinct. A file, link
or special object at that literal label refuses runtime launch rather than being
normalized to nil.

| Bound | Ceiling |
| --- | --- |
| Catalog packs per session | 64 |
| Files per pack | 64 |
| Imported Git tree entries below one selected pack | 512 total tree/blob rows |
| Retained bytes per pack | 1 MiB |
| SKILL.md / one text resource | 64 KiB |
| Discovery depth below one pack directory | 8 relative components |
| UTF-8 label or source descriptor | 1,024 bytes |
| Skill name | Agent Skills spec's 1–64 character lowercase name grammar |
| Description | 1,024 UTF-8 bytes |
| Model-visible catalog | 16 KiB before ordinary context admission |
| Active skills per run | 4 |
| Selected supporting files | 8 per skill; 32 per run |
| One requested supporting resource | 16 KiB, whole text or refusal |
| One complete resource command record | 16 KiB |
| Resource receipt metadata | 8 KiB; at most 37 compact block dispositions |
| Provider-visible `resource_pack` class bytes | 65,536 canonical message bytes |
| `resource_pack` class tokens | 21,870 under `loopex.context_bytes.v1` |

These are candidate limits for explicit acceptance, not measurements or format
requirements imposed on the internet ecosystem. Oversized packs are diagnosed
as outside the supported subset. Total staged context still obeys the existing
run token and 65,536-byte Store-record limits; a 1 MiB retained bundle does not
mean 1 MiB of context can be admitted. The resource-class byte ceiling is the
sum of the canonical provider-message byte costs for staged catalog,
instruction and supporting blocks. At most 37 nonempty blocks contribute. The
estimator is `ceil(message_bytes / 3)` per block, so the greatest token sum at
65,536 class bytes is `((65_536 - 37) / 3) + 37 = 21_870`; evidence fixes the
integer arithmetic and all block counts. Passing the byte ceiling therefore
makes the class-token refusal independently unreachable in M3. The token guard
remains a versioned future-shape invariant, and the Store record ceiling can
withhold the class sooner because the record also carries descriptors and
receipts.

Loopex digests are lowercase 64-character SHA-256 hex; the native Git object IDs
above are exempt from this framing. File digests use
`LoopexProtocol.Canonical.digest_bytes/1`. Manifest and pack digests use
`Canonical.digest/1` over `%{"encoding" => Canonical.version(), "kind" => kind,
"value" => normalized_metadata}`. Kinds are `loopex.resource_manifest/1` and
`loopex.resource_pack/1`. The manifest value contains its complete normalized
metadata, including workspace repository origin/revision and remote pack
provenance, and omits only file content.
The pack value contains exactly `name`, `description`, `manual_only`, and the
ordered file `label`, `size`, and `digest` identities. `file_set_digest` uses
kind `loopex.resource_file_set/1` and a value equal to that same complete ordered
list of `%{"label" => label, "size" => size, "digest" => digest}` maps. It
deliberately excludes
`source_id`, `origin`, `commit`, `tree_digest`, workspace identity, containment
evidence, and file bodies so the exact installed bytes can reproduce the pack
digest independently of retained provenance. The enclosing manifest digest still
binds those excluded source and trust fields. Verified file sizes and digests bind
the bodies. Pack/file indices are zero-based canonical positions and always
qualified by the manifest digest. Equal digest indices do not permit unequal
retained bytes.

### Proposed command and query member sets

New commands normalize atom/string aliases once into durable string-key maps;
duplicate aliases, extra keys and malformed members refuse before retention.
Command IDs are nonempty binaries of at most 256 bytes. Historical command
normalization remains unchanged.

```elixir
%{type: :admit_resources, command_id: id, manifest_digest: digest,
  decision: nil | %{manifest_digest: digest, workspace_ref: workspace,
    trust_scope: "project_skills",
    decision_source: "interactive_operator" | "host_supplied",
    issued_at: iso8601, expires_at: nil,
    revocation_state: "active" | "revoked"}}

%{type: :activate_skill, command_id: id, manifest_digest: digest,
  source_id: source, name: name, pack_digest: digest, supporting_labels: []}
```

Workspace/source labels are at most 1,024 UTF-8 bytes; issuance is a valid
ISO-8601 timestamp of at most 64 bytes. Supporting labels are ordered, unique
and at most eight per skill; `SKILL.md` is implicit and an explicit occurrence
refuses with `resource_support_not_found`. Both commands require
settled state. Canonical repetition returns its durable result before checking
current resources. Positive admission requires the configured snapshot and all
decision bindings to match. Nil/revoked decisions disable resource admission.
Disabling names the existing admitted manifest and uses its retained workspace
binding even if the launch snapshot is missing; without prior admission it
returns `resource_not_admitted`. The outer digest must match that retained
admission. A non-nil revoked decision must also match that digest, retained
workspace and `project_skills` trust scope. A mismatch returns
`resource_binding_changed` without changing resource state. Revocation never
requires rereading a pack.
New successful admission clears selections; replay does not clear them again.
Repeating an identical selection preserves order; a new command can replace
that skill's supporting labels while settled and retains its original selection
slot. Only the labels change; replacement never moves the skill to the end. A
fifth distinct skill refuses.
Existing reply forms remain `{:accepted, command_id}` or `{:error, reason}`.

State-dependent refusals are retained and replayed. Their closed reasons are
`run_active`, `resource_manifest_missing`, `resource_binding_changed`,
`resource_not_admitted`, `resource_not_found`, `resource_selection_limit`,
`resource_support_not_found`. Malformed commands use the existing validation
error envelope and commit no partial resource state.

Propose `resource_command_v1` with exactly `kind`, `command`, `command_digest`,
`disposition`, `resolved`. The complete normalized small command uses the existing
canonical command-digest framing. Disposition is `accepted` or a reason above;
rejected records have nil resolution. Accepted admission resolves to
`workspace_ref`, `manifest_digest`. Accepted activation resolves to `pack_index`,
`instruction_file_index`, `instruction_digest`, `supporting_files`; supporting
entries have exactly `file_index`, `digest`, `size`, in requested order. Measure
the complete candidate with `Store.normalize_and_measure_item/2` and enforce
16 KiB before commit. Existing fencing and commit-unknown discipline applies.

Prompt admission freezes current resource state; follow-up promotion freezes
the then-current state. Replay reconstructs it from preceding commands without
an extra run record. `selection_digest` uses the framing above with kind
`loopex.resource_selection/1` and value containing exactly `decision` and ordered
resolved `selections`. Later requests use that frozen run snapshot.

`resource_catalog` returns exactly `configured_manifest_digest`,
`admitted_manifest_digest`, `decision_disposition`, `entries`, inside the existing
facade success envelope. Missing digests are nil. Disposition is `no_decision`,
`active`, `revoked`, `binding_changed` or `retained_content_missing`. Entries have
exactly `pack_index`, `source_id`, `name`, `description`, `pack_digest`,
`manual_only`. The complete response is bounded to 256 KiB or refuses before
return. `read_resource` accepts exactly `manifest_digest`, `source_id`, `name`,
`label`, requires active matching admission and retained content, verifies its
digest, and returns exactly `digest`, `size`, `content` in the success envelope.
This operator inspection query returns `SKILL.md` or another manifested text
file up to the general 64 KiB text-resource ceiling without truncation. The
separate 16 KiB supporting-resource ceiling applies when a selected supporting
block is staged for the model. Absent, oversized or mismatched content refuses
with `resource_manifest_missing`, `resource_not_admitted`,
`resource_binding_changed`, `resource_not_found` or `resource_byte_limit` as
applicable; a catalog response over its ceiling returns `resource_catalog_limit`.
Reading never selects. Pre-admission CLI inspection uses host data.

#### Closed `SKILL.md` frontmatter profile

Loopex supports one closed, dependency-free YAML subset. It does not claim
general YAML compatibility. A valid ecosystem skill outside this syntax is
reported as outside the Loopex subset and is not admitted.

`SKILL.md` is at most 65,536 bytes, is valid UTF-8 without BOM or NUL, uses LF
line endings, and begins at byte zero with `---\n`. The first later line exactly
equal to `---\n` closes frontmatter; the remainder is Markdown and is not parsed
as YAML. CR, a tab in frontmatter syntax, trailing whitespace, a YAML directive,
or an unclosed delimiter refuses. Input order has no authority.

The grammar is one top-level mapping. A top-level key begins in column zero,
matches `[A-Za-z][A-Za-z0-9_-]{0,63}`, and is followed by `:`, then either one
or more ASCII spaces and a scalar, one allowed block-scalar header, or the
special nested `metadata` mapping. Blank lines and comment-only lines whose
first non-space byte is `#` are allowed between entries. Inline comments are
unsupported. A `#` inside quoted or block-scalar content is data.

A single-line string is exactly one of these forms:

- a nonempty plain scalar with no leading or trailing space, control byte, `:`,
  or `#`; its first byte is not a YAML indicator (`-`, `?`, `:`, `,`, `[`, `]`,
  `{`, `}`, `#`, `&`, `*`, `!`, `|`, `>`, single quote, double quote, `%`, `@`,
  or ASCII `0x60`). Plain values have no implicit null, number, timestamp, or
  boolean typing except where a field below explicitly requires a boolean;
- a single-quoted scalar on one physical line, where `''` decodes to one
  apostrophe and backslash has no special meaning; or
- a double-quoted scalar on one physical line, with only `\"`, `\\`, `\/`,
  `\b`, `\f`, `\n`, `\r`, `\t`, `\xHH`, `\uHHHH`, and `\UHHHHHHHH` escapes.
  A hex escape must decode to one Unicode scalar other than NUL; surrogates,
  values above U+10FFFF, and every other escape refuse.

There is no interpolation. Dollar signs, command markers and similar accepted
bytes remain inert data. Literal and folded block strings are allowed only for
top-level string fields. Their headers are exactly `|`, `|-`, `|+`, `>`, `>-`,
or `>+`; explicit indentation indicators are unsupported. Every nonempty
content line begins with exactly two spaces, which are removed. Tabs and further
leading indentation refuse. Literal form preserves remaining bytes and line
breaks. Folded form joins consecutive nonempty lines with one ASCII space and
each run of empty lines contributes that many LF bytes. Strip chomping removes
all terminal LFs, clip chomping retains exactly one, and keep chomping retains
every physical terminal LF. A `#` in a block is content.

The recognized fields are closed:

| Field | Exact contract |
| --- | --- |
| `name` | Required single-line string matching `[a-z0-9]+(?:-[a-z0-9]+)*`, 1–64 ASCII bytes, and byte-equal to the containing directory basename. |
| `description` | Required nonempty string of at most 1,024 Unicode scalars and 1,024 UTF-8 bytes. |
| `license` | Optional nonempty string of at most 1,024 UTF-8 bytes. |
| `compatibility` | Optional nonempty string of at most 500 Unicode scalars and 500 UTF-8 bytes. The byte ceiling is an intentional stricter Loopex subset of the ecosystem character ceiling. |
| `metadata` | Optional nonempty mapping of at most 32 contiguous child entries. Each begins with exactly two spaces, uses a case-sensitive unique key matching `[A-Za-z0-9][A-Za-z0-9._/-]{0,127}`, and has a single-line string value of at most 1,024 UTF-8 bytes. Decoded key and value bytes total at most 8,192. An empty or flow mapping refuses. |
| `allowed-tools` | Optional nonempty string of at most 4,096 UTF-8 bytes, retained for inspection and always inert. It never adds a tool, policy allowance, capability or grant. |
| `disable-model-invocation` | Optional plain scalar exactly `true` or `false`; quoted values and YAML boolean aliases refuse. `true` maps to `manual_only: true`; missing or `false` maps to false. This is a supported vendor extension, not an Agent Skills standard field. |

There are at most 32 top-level entries. An unknown top-level key is accepted
only with a string scalar or block string of at most 4,096 decoded UTF-8 bytes.
It produces an `unsupported_frontmatter_field` diagnostic and has no runtime
meaning; its original bytes remain covered by the file digest. Unknown mappings
or sequences refuse, so hook-like or command-like content can be inspected only
as inert scalar text and cannot acquire executable structure.

Every top-level and metadata key is unique. A missing required field, empty
required value, duplicate, wrong recognized-field type, invalid or mismatched
name, or exceeded count/byte bound refuses. Flow collections, sequences, nested
mappings other than `metadata`, anchors, aliases, tags, merge keys, directives,
explicit type annotations, and multiple documents refuse. Unicode is not
normalized: decoded scalar sequences are retained exactly and the original file
bytes remain digest-bound.

Parser failures use the closed classes `encoding`, `frame`, `syntax`,
`duplicate_key`, `unsupported_structure`, `type`, `required`, `name`, and
`limit`. Acquisition maps each to the existing durable `pack_invalid` terminal.
Safe operator diagnostics may include the class and one-based line number but
never untrusted content. Discovery and Git acquisition use the same bounded byte
scanner in the resource-pack boundary. It invokes no external parser or process
and adds no YAML dependency.

Conformance evidence retains the exact input bytes and either the exact decoded
result or failure class. Positive vectors cover the official minimal example,
the official optional-fields example including quoted `"1.0"` metadata, every
quoting form, all six block headers with exact decoded bytes, UTF-8 and escape
decoding, full-line comments, both `disable-model-invocation` values, inert
`allowed-tools`, and one unknown scalar extension. Negative vectors cover BOM,
invalid UTF-8, NUL, CRLF, missing or displaced delimiters, tabs, trailing
whitespace, inline comments, illegal escapes, every excluded YAML construct,
duplicate top-level and metadata keys, missing required fields, every wrong
recognized-field type, invalid or directory-mismatched names, and an unknown
structured extension. Boundary vectors accept every exact ceiling and refuse
its smallest exceeding value, including decoded byte/scalar limits, entry
counts, metadata aggregate bytes and the complete file bound. The hostile-pack
witness additionally proves that accepted `allowed-tools`, hook-like scalar
text and command markers leave tool-registry bytes, policy results, grants and
executor intent unchanged.

### Acquisition and retention

The command requires `source`, `commit`, `source_directory` and
`destination_name` before any policy call or Git process. `destination_name`
satisfies the skill-name grammar and derives the exact destination
`.agents/skills/<destination_name>`. After fetch, the selected directory basename
and parsed SKILL.md `name` must both equal it. A mismatch is a pre-publication
failure. The exact source directory tree and complete file identities are retained.
The normalized public command is exactly `%{type: :acquire_resource,
command_id: command_id, source: source, commit: commit,
source_directory: source_directory, destination_name: destination_name}` with no
extra member. Its `command_digest` is the lowercase SHA-256 canonical digest
under kind `loopex.resource_acquisition_command/1` over that complete normalized
string-key map, with `"type" => "acquire_resource"` and the other five keys
spelled as above. `command_id` is a nonempty binary of at most 256 bytes.
Atom/string aliases normalize once; source and source-directory values must then
already satisfy their canonical grammars before the 16 KiB complete-command
check. Alias spellings and rejected source bytes never enter a digest or policy
evaluation. A malformed command returns
`{:error, :invalid_resource_acquisition_command}` and creates no record. The
first well-formed presentation returns `{:accepted, operation_id}` only after
the accepted command and intent commit, or `{:error, :acquisition_busy}` only
after that refusal commits. An exact replay returns the retained reply; reuse of
`(runtime_id, command_id)` with any changed normalized byte returns
`{:error, :idempotency_conflict}` and creates no policy call, operation or
effect.

Runtime Control generates each `operation_id` as a nonempty binary of at most
256 bytes before the accepted command/intent transaction. It is unique within
the runtime and remains the operation identity across attempts, reconciliation
and terminal replay.

The existing policy callback gains this one exact bounded request variant:

```text
%{
  request_kind: "resource_acquisition",
  origin_kind: "runtime_control_resource_acquisition",
  runtime_id: runtime_id,
  command_id: command_id,
  operation_id: operation_id,
  acquisition_kind: "git_skill_directory",
  source: canonical_public_https_source,
  commit: native_git_object_id,
  source_directory: normalized_relative_label,
  destination_name: skill_name,
  destination_label: ".agents/skills/" <> skill_name,
  executor_identity: executor_identity,
  git_graph_identity: git_graph_identity,
  required_capabilities: required_capabilities,
  effect_class: "external_effect",
  idempotency_class: "reconcile_then_retry",
  workspace_ref: workspace_ref,
  workspace_lease: workspace_lease,
  authentication: "public_anonymous_https",
  resource_budgets: resource_budgets,
  retention_policy_ref: "loopex.resource_pack_retention.v1",
  output_policy: fixed_output_policy,
  artifact_policy: fixed_artifact_policy
}
```

Every scalar is bounded plain data. The policy input carries no credential,
function, pid, port, reference or provider value. Runtime Control receives only
ADR 0009's already normalized policy result and never sees or reinterprets the
raw callback output:

| ADR 0009 observation | Acquisition resolution |
| --- | --- |
| Valid `{:allow, context}` | proceed with that exact bounded context; its optional `decision_ref` is the authorization reference |
| Valid `{:deny, category}` | Store `denied` with that same exact closed category |
| Invalid allow context, invalid deny, callback raise/exit/timeout, or any other return | Store `denied` with `policy_unavailable` |
| `{:defer, _}` | Store `denied` with `interaction_unsupported` |
| No acquisition policy configured | Store `unavailable` with `policy_unavailable`; ordinary sessions continue |

The acquisition denial categories are exactly `policy_denied`,
`effect_class_not_permitted`, `workspace_not_permitted`,
`interaction_unsupported`, and `policy_unavailable`. Every denied or unavailable
command terminates durably without grant, attempt, `acquire/3`, `reconcile/2`,
process, network, or filesystem effect. The prior read-only `capabilities/1`
observation may have occurred. The reference composition has no acquisition-
policy default.

After allow and executor placement, Runtime Control constructs exactly one
`resource_acquisition_request_v1`. Its ordered semantic fields are:

```text
protocol_version
origin_kind
runtime_id
command_id
operation_id
attempt
preparation_id
acquisition_kind
executor_identity
executor_epoch
git_graph_identity
required_capabilities
effect_class
source
commit
source_directory
destination_name
destination_label
workspace_ref
workspace_lease
operation_deadline
resource_budgets
output_policy
artifact_policy
idempotency_class
fencing_token
authentication
retention_policy_ref
cleanup_grace_ms
```

`protocol_version` is 1, `origin_kind` is
`runtime_control_resource_acquisition`, `acquisition_kind` is `git_skill_directory`,
`effect_class` is `external_effect`, `authentication` is
`public_anonymous_https`, `idempotency_class` is `reconcile_then_retry`, and
`retention_policy_ref` is `loopex.resource_pack_retention.v1`, and
`cleanup_grace_ms` is 2,000. `required_capabilities` is the ordered set
`git_https_public`, `bounded_transport`, `durable_receipt`,
`atomic_no_replace`, `nofollow_tree`, `durable_sync`,
`process_tree_cleanup`, `process_resource_limits`, and `bounded_scratch`.
`preparation_id` is a fresh 128-bit cryptographic random value encoded as 32
lowercase hexadecimal bytes. It is generated only after the post-allow
capability revalidation and is never reused by another attempt. A collision
with any retained preparation or reservation refuses before Store submission.
After a valid policy allow and before constructing the
request or grant, Runtime Control captures one nonnegative Unix-millisecond wall
clock instant. `operation_deadline` is the checked sum of that instant and the
fixed `wall_time_ms` budget of 30,000; the grant's `expiry` is exactly the same
integer. An unavailable or invalid clock, arithmetic overflow, or a deadline
that is no longer in the future before attempt commit stores the pre-attempt
`unavailable` terminal with reason `deadline_elapsed_before_attempt` and creates
no attempt, grant, or hand call. The hand derives one private monotonic deadline
from the remaining duration; that derived time is neither retained nor compared
across clock domains.

`output_policy` is exactly `%{"stdout" => "counted_discarded",
"stderr" => "counted_discarded", "verified_blob_channel" =>
"bounded_staged_file", "verified_git_metadata_channel" =>
"bounded_parsed_records", "model_visible" => false,
"session_visible" => false, "truncation" => "terminate_without_success"}`.
`artifact_policy` is exactly `%{"returned_artifacts" => "none",
"publication" => "atomic_no_replace_skill_directory",
"destination_label" => destination_label}`. Subprocess output is counted while
the process runs and discarded after classification; only its two byte counts
in `observed_budgets` survive. It is never a session message or ArtifactStore
object. Reaching either diagnostic-output cap terminates the process group and
cannot yield `completed`. Two closed semantic stdout routes are exceptions to
discarding. The Git type/size/tree commands named below write only to an
authenticated metadata pipe whose command-specific parser accepts the exact
bounded grammar before returning a record to the hand; those bytes count against
the separate `git_metadata_bytes` ceiling, while diagnostic stdout alone counts
against `stdout_bytes`. A raw blob child's predeclared
content descriptor connects stdout directly to the helper's bounded staged-file
operation, never to a diagnostic collector. The helper knows the object's
already checked size and digest, accepts exactly that many bytes, and syncs a
non-executable no-follow/no-replace file or refuses the attempt. This blob
channel counts against object, staging, file and pack budgets. Neither channel
can carry a command or terminal result, and malformed, extra, missing, NUL-
incorrect, or over-bound metadata/blob output terminates without success. The
installed project directory is the governed effect, not a returned artifact
reference.

`resource_budgets` admits exactly these fixed M3 ceilings:

| Member | Ceiling |
| --- | --- |
| `wall_time_ms` | 30,000 |
| `cpu_time_seconds` | 20 per process |
| `address_space_bytes` | 512 MiB per process |
| `network_received_bytes` | 16 MiB |
| `git_object_bytes` | 16 MiB |
| `git_object_count` | 4,096 |
| `git_index_bytes` | 512 KiB |
| `git_metadata_bytes` | 576 KiB |
| `task_scratch_bytes` | 64 MiB |
| `child_file_bytes` | 20 MiB per regular file |
| `staging_bytes` | 32 MiB |
| `installed_pack_bytes` | 1 MiB |
| `file_count` | 64 |
| `process_count` | 16 |
| `open_files_per_process` | 64 |
| `stdout_bytes` | 64 KiB |
| `stderr_bytes` | 64 KiB |

The request is at most 16 KiB. Its canonical digest uses kind
`loopex.resource_acquisition_request/1` and covers every ordered semantic field.
The Store attempt, grant, hand admission, receipt, reconciliation and provenance
generation carry that one attempt-bound request digest. Transport framing,
derived monotonic time and diagnostics are excluded. The separate grant digest
below is the authorization-byte identity; it is not a second request or job
identity. The local hand advertises every ceiling and must establish the
pre-exec wall, per-process CPU/address-space/file-size/open-file,
diagnostic-output and network limits before accepting the request. The supervisor
admits only the fixed child graph and counts its process images; content cannot
select another executable or spawn path. Object, scratch, staging, file and
installed-pack limits are checked at every child boundary inside that hard
envelope: crossing one refuses and cleans only proven attempt-owned scratch. An
implementation that lets Git choose an unaccounted object directory, temp root
or output path is nonconforming. If its Git/platform combination cannot establish
these controls, acquisition is unavailable before process start.

`resource_acquisition_grant_v1` is a closed string-key map with exactly `kind`, `issued_by`,
`operation_id`, `attempt`, `preparation_id`, `canonical_request_digest`, `acquisition_kind`,
`protocol_version`, `effect_class`, `workspace_lease`, `executor_audience`,
`expiry`, `fencing_token`, and `policy_context`. `issued_by` is
`host_policy_allow`; `policy_context` is ADR 0009's bounded non-secret context,
including its optional bounded `decision_ref` when the host supplied one.
The eleven binding fields are the intervening members from `operation_id` through
`fencing_token`. This family uses `acquisition_kind` and `protocol_version`
instead of inventing a tool ID/version. Canonical encoding uses
`LoopexProtocol.Canonical` under kind `loopex.resource_acquisition_grant/1`; its
lowercase SHA-256 `canonical_grant_digest` covers every grant member, including
the complete bounded policy context. The hand independently recomputes both
request and grant digests and checks every binding, the current executor
identity/epoch, workspace lease, fence, exact equality of grant expiry and
operation deadline, and that deadline's freshness at its final serialized
pre-start boundary. Changed canonical grant bytes under a
retained digest refuse. Queueing grants no authority.

The preparation binding avoids a digest cycle. Runtime Control first constructs
the complete request containing `preparation_id` and computes
`canonical_request_digest`, then constructs the complete grant containing that
same ID and request digest and computes `canonical_grant_digest`. It next
computes `preparation_digest` under kind
`loopex.resource_acquisition_preparation_identity/1` over exactly
`runtime_id`, `command_id`, `operation_id`, `attempt`, `preparation_id`,
`canonical_request_digest`, and `canonical_grant_digest`. The Store attempt
record carries that digest. Runtime Control then constructs the complete Store
attempt transaction and finally the closed preparation record:

```text
resource_acquisition_preparation_v1
  kind, protocol_version, runtime_id, command_id, operation_id, attempt,
  preparation_id, preparation_digest, canonical_request_digest,
  canonical_grant_digest, store_attempt_tx_id,
  store_attempt_transaction_digest, store_attempt_transaction

resource_acquisition_preparation_receipt_v1
  kind, protocol_version, runtime_id, operation_id, attempt, preparation_id,
  preparation_record_digest, reservation_digest, state

resource_acquisition_preparation_release_v1
  kind, protocol_version, runtime_id, command_id, operation_id, attempt,
  preparation_id, preparation_record_digest, store_attempt_tx_id,
  store_attempt_transaction_digest
```

The preparation's transaction is the complete canonical
`resource_acquisition_commit` candidate defined below, including its complete
attempt record, request and grant. `store_attempt_transaction_digest` equals
that transaction's `canonical_mutation_digest`; its ID equals the transaction's
`tx_id`. `preparation_record_digest` uses kind
`loopex.resource_acquisition_preparation/1` over every preparation member.
Every record is at most 192 KiB; all identifiers and nested records retain their
stricter bounds. The receipt state is exactly `prepared` and its digests equal
the reopened reservation. The release record is only a request to verify and
release that exact preparation; it carries no Store observation supplied by the
caller. A different byte, digest, transaction, attempt or state refuses. The
preparation record is the sole restart source for the Store candidate; no
policy callback, clock sample, random ID or grant is reconstructed across that
cut.

The host initializes each acquisition-hand reference with one trusted canonical
workspace root and the current `(workspace_ref, workspace_lease)` binding. The
root is process-local host configuration: it never enters the canonical request,
grant, Store/hand records or core. At dispatch the hand requires the request and
grant binding to equal that initialized current binding, then resolves the
literal destination label beneath the root through no-follow directory handles.
Only the host may issue, rotate or revoke the binding; lease loss cancels the
owned effect and can never retarget it. Each acquisition-hand
`(executor_identity, executor_epoch)` binds exactly one protected local-ledger
root for that epoch's lifetime; changing the root requires a new executor epoch.
The reconciliation expected-responder identity/epoch therefore also identifies
the only ledger allowed to attest or revoke that attempt.

The Store adds one acquisition transaction type in its runtime-control namespace:

```text
%{
  type: :resource_acquisition_commit,
  runtime_id: runtime_id,
  command_id: command_id,
  operation_id: operation_id_or_nil,
  mutation_domain: :resource_acquisition,
  expected_acquisition_version: non_neg_integer(),
  tx_id: digest(),
  canonical_record_bytes: binary(),
  canonical_mutation_digest: digest(),
  records: [map(), ...]
}
```

`resource_acquisition_commit` carries no Control-incarnation token. ADR 0008
requires the host to quiesce or establish the death of the prior
`Loopex.Control` before installing its replacement; the Store does not turn
that host obligation into another ownership protocol. It serializes this
mutation domain by `expected_acquisition_version`, validates the proposed
bundle against the authoritative folded acquisition state, stamps the next
consecutive version, and commits at most one candidate at a version. If
multiple Controls violate placement, at most one candidate commits. Every
loser receives `{:not_committed, :stale_acquisition_version}`, performs no
consequence, folds the durable head, and either returns retained truth or
continues from that state. Store unavailability fences acquisition work.

`canonical_record_bytes` is the canonical encoding of the complete ordered
`records` list. `record_set_digest` is
`loopex.resource_acquisition_record_set/1` over that exact list. `tx_id` is
`loopex.resource_acquisition_tx/1` over exactly `%{"runtime_id" => runtime_id,
"expected_acquisition_version" => expected_acquisition_version,
"record_set_digest" => record_set_digest}`. `canonical_mutation_digest` is
`loopex.resource_acquisition_commit/1` over every semantic transaction member:
`type`, `runtime_id`, `command_id`, nullable `operation_id`,
`mutation_domain`, `expected_acquisition_version`, `tx_id`, and `records`. It
excludes itself and the redundant canonical-record byte string. The Store
retains `tx_id` with a committed or final not-committed result. Reusing it with
different canonical bytes returns `{:error, :tx_id_conflict}`; exact
re-presentation returns the retained result and never duplicates records.

Only these ordered record bundles are legal:

| Folded state and transition | Exact `records` bundle |
| --- | --- |
| No operation; command accepted | `[resource_acquisition_command_v1, resource_acquisition_intent_v1]` |
| Another operation open | `[resource_acquisition_command_v1]`, with `acquisition_busy` and transaction `operation_id: nil` |
| Normalized policy denial, absent-policy unavailable, or pre-attempt capability/deadline failure | `[resource_acquisition_terminal_v1]` |
| Prepared authorized dispatch | `[resource_acquisition_attempt_v1]` |
| Direct hand terminal | `[resource_acquisition_terminal_v1]` |
| Begin or supersede reconciliation | `[resource_acquisition_reconciliation_query_v1]` |
| Nonterminal reconciliation observation or quarantine release | `[resource_acquisition_reconciliation_result_v1]` |
| Reconciliation settles or quarantines the operation | `[resource_acquisition_reconciliation_result_v1, resource_acquisition_terminal_v1]` |

Every non-busy record shares the transaction's runtime and non-null operation
identity. Every non-busy transaction `command_id` equals the accepted/open
operation's retained command identity, and every member that carries a
`command_id` equals it; query and result records bind it transitively through
their exact operation, attempt, request and retained command/intent. The busy
bundle instead carries the refused second command's own submitted `command_id`
in both the transaction and its sole command record, with transaction and record
`operation_id: nil`; it never borrows the open operation's command identity.
Exact replay of that refused command returns the same busy record, while reuse
of its identity with changed bytes conflicts. No other combination
or order is valid. Every committed bundle advances `acquisition_version`
exactly once. Only an attempt bundle advances the acquisition fence and attempt
number; query and result bundles never advance either. Malformed canonical
bytes or an illegal bundle returns
`{:error, :invalid_resource_acquisition_transaction}` before mutation. A valid
candidate at a stale expected version returns the not-committed result above
with no record, acknowledgement, dispatch, or publication consequence.

Acquisition version is the Store CAS sequence; it is not the executor fence. A separate consecutive runtime
acquisition-fence counter advances only when a new attempt commits. That token
remains current through dispatch and every reconciliation transaction until the
attempt settles or an exact `not_dispatched` result authorizes the next attempt.
Queries and results do not accidentally stale the hand they observe. Because one
runtime has only one open acquisition operation, another operation cannot advance
the fence underneath a live hand. An `OwnerLane` scopes an unresolved transaction to
`{runtime_control, runtime_id, resource_acquisition}`: it blocks new acquisition
mutation and dispatch, but not unrelated session journals. Outcomes stay exactly
`committed`, `not_committed` and `commit_unknown`. The production transition
catalogue adds `runtime_control_resource_acquisition_commit` with
`before_linearization`, `after_linearization_before_result`, and
`recovery_representation`; declared, injected and observed fault sets remain
equal.

The Store supplies two bounded, non-authorizing recovery reads:

```text
resource_acquisition_head(runtime_id) ->
  {:ok, %{acquisition_version: non_neg_integer(),
          fencing_token: non_neg_integer(), folded_state: map()}}
  | {:error, :store_unavailable}

resource_acquisition_transaction_status(runtime_id, tx_id) ->
  {:terminal, :committed}
  | {:terminal, {:not_committed, :stale_acquisition_version}}
  | :absent
  | :unavailable
```

The head's `folded_state` is `:none` or the exact 16-KiB-bounded acquisition
status projection defined below, without `kind`, `protocol_version`, or
`runtime_id`; its operation belongs to the queried runtime. It is a recovery
observation, not policy, dispatch, receipt, or publication authority.

A live Control receiving `commit_unknown` retains the exact candidate and may
only re-present those bytes or query that transaction status. A replacement
Control first reads transaction status when the transaction ID is available,
then folds the authoritative head. It need not reconstruct an unknown
predecessor candidate whose bytes did not survive. If the predecessor
transaction is absent, it may build a new candidate at the returned version; a
late predecessor call and that replacement race only at that version, where the
Store commits one and the loser folds the winner.

The acquisition-start and terminal records are closed string-key maps:

```text
resource_acquisition_command_v1
  kind, runtime_id, command_id, command_digest, operation_id, disposition

resource_acquisition_intent_v1
  kind, runtime_id, command_id, operation_id, acquisition_kind, workspace_ref,
  source, commit, source_directory, destination_name, destination_label,
  retention_policy_ref, idempotency_class

resource_acquisition_attempt_v1
  kind, runtime_id, command_id, operation_id, attempt, preparation_id,
  preparation_digest, canonical_request_digest, canonical_grant_digest,
  request, grant

resource_acquisition_terminal_v1
  kind, runtime_id, command_id, operation_id, attempt,
  canonical_request_digest, canonical_grant_digest, outcome, reason, receipt
```

Command disposition is exactly `accepted` or `acquisition_busy`. An accepted
command has a non-null operation ID and commits atomically with its intent before
policy evaluation. A busy command has nil operation ID and no other record.
Malformed input creates no record. Each record is at most 64 KiB; the request
remains under its stricter 16 KiB bound. Acquisition observation uses a separate
non-authorizing Store read,
`resource_acquisition_command(runtime_id, command_id, command_digest)`. It returns
`{:ok, :absent}` or exactly
`{:ok, %{kind: :resource_acquisition_command_observation_v1, runtime_id:
runtime_id, command_id: command_id, command_digest: command_digest, disposition:
:acquisition_busy | :accepted, operation_id: nil | operation_id, state:
:open | :terminal | :terminal_quarantined}}`; busy requires nil operation and
terminal state, accepted requires a non-null operation, and
`terminal_quarantined` is legal only for an accepted unknown operation whose
process absence remains unproved. No other relation is legal. A changed digest
returns `{:error, :idempotency_conflict}`; unavailable Store truth returns
`{:error, :store_unavailable}`. This read folds only the acquisition namespace,
creates no record or authority, and does not change or overload the existing
session `Store.runtime_command/2` variants. The CLI journal's
`store_observation_digest` uses canonical kind
`loopex.skill_cli_store_observation/1` over exactly `%{"binding" =>
resource_snapshot_binding_result, "command" =>
resource_acquisition_command_result, "slot" =>
resource_acquisition_slot_result}`; each value is the complete normalized Store
reply, including `:absent` or `:idle`, so a binding-only cut cannot be represented
as command absence alone. The companion non-authorizing
`resource_acquisition_slot(runtime_id)` returns `{:ok, :idle}` or exactly
`{:ok, %{kind: :resource_acquisition_slot_observation_v1, runtime_id:
runtime_id, operation_id: operation_id, state: :open |
:terminal_quarantined}}`; Store unavailability is the only error. A busy command may
enter terminal CLI state only after the slot is authoritatively idle; until then
its resolving frame remains and forget refuses. These reads create no CAS or
authority.

The acknowledged lifecycle is total:

| Durable state | Next event | Required transition and effect authority |
| --- | --- | --- |
| no open operation | valid command | atomically commit accepted command plus intent, enter `pending_policy`, then acknowledge the operation; no effect exists |
| any open operation | another valid command | commit only `acquisition_busy`; create no operation, policy request, grant or effect |
| `terminal_quarantined` | another valid command | commit only `acquisition_busy` until exact post-unknown process absence releases quarantine |
| `pending_policy` | initial drive or restart | select the trusted route and call read-only `prepared/3` before policy; an exact preparation re-presents only its embedded Store attempt transaction, `:absent` permits the capability and policy path, and unavailable/conflicting state leaves the operation pending |
| `pending_policy` | route or capability observation unavailable or malformed before policy | commit `unavailable` / `acquirer_unavailable` with zero policy call, grant, attempt, or effect; clear the open-operation slot |
| `pending_policy` | any normalized policy denial, including policy failure/defer | commit the matching `denied` pre-attempt terminal and exact category; clear the open-operation slot |
| `pending_policy` | exact recovery-only CLI write-ahead command after source change and `prepared/3` proves absence | commit `unavailable` / `resource_binding_changed` with zero policy, grant, attempt, `prepare/2`, `acquire/3` or `reconcile/2` call; clear the open-operation slot |
| `pending_policy` | no acquisition policy configured | commit `unavailable` / `policy_unavailable`; clear the open-operation slot |
| `pending_policy` | allow but capability revalidation changes/fails or the deadline elapsed | commit the matching pre-attempt unavailable terminal; clear the open-operation slot |
| `pending_policy` | allow and identical capability revalidation | build the request, grant, preparation identity and exact Store attempt transaction; call `prepare/2`; only a confirmed exact reservation permits Store submission |
| `pending_policy` | confirmed preparation capacity refusal with authoritative absence | commit `unavailable` / `acquirer_unavailable` with zero attempt or effect; clear the open-operation slot |
| `pending_policy` | lost or unavailable prepare result | call `prepared/3`; an exact record resumes its embedded transaction, authoritative absence may settle unavailable, and uncertainty remains pending without a replacement policy/grant |
| prepared attempt | initial submission or restart | re-present the byte-identical embedded Store transaction; no new policy, clock, random identity, request or grant is permitted |
| attempt commit | `not_committed` | call `release_preparation/2`; remain `pending_policy` and dispatch nothing only after the exact prepared reservation is durably absent |
| attempt commit | `commit_unknown` | fence the acquisition OwnerLane and re-present the identical transaction until its exact outcome is known |
| attempt commit | `committed` | enter `attempt_open`, then call `acquire/3`; under the attempt lock the hand attaches only the matching prepared reservation and local admission before guard release |
| `attempt_open` | valid retained hand terminal | atomically commit the matching terminal and clear or quarantine the open slot as defined below |
| `attempt_open` | timeout, crash, malformed result or lost reply | remain open and report retained status; do not redispatch; only an accepted reconciliation command may commit a query |
| `attempt_open` or `terminal_quarantined` | valid reconciliation request | atomically commit one exact solicited query, acknowledge its ID, then invoke only the named recovery hand |
| query commit | `not_committed` | make no hand call; fold the durable acquisition head and return retained state |
| query commit | `commit_unknown` | fence the OwnerLane and resolve that exact transaction; do not acknowledge or call the hand until committed |
| current unresolved query after commit or restart | expected responder still current | send the exact query; lost reply or hand unavailability remains reconciling and later replay/restart re-drives it |
| current unresolved query after responder change | accepted replacement query | atomically append the next recovery epoch, supersede the old query without an observation, then send only the replacement |
| reconciliation | exact `not_dispatched` | atomically append the result and return the same operation to `pending_policy`; the next allow creates a new attempt/fence |
| reconciliation | exact `in_flight` | append the result and remain `attempt_open` |
| reconciliation of `attempt_open` | exact `terminal` | atomically append result plus the terminal derived from the retained receipt; a terminal result never exists only in one half of that pair |
| reconciliation of `attempt_open` | exact `indeterminate_evidence` | atomically append result plus immutable `outcome_unknown`; retain process quarantine |
| reconciliation of `terminal_quarantined` | exact `post_unknown_absent` | append the result, release only the process quarantine and permit a later operator command; preserve the unknown terminal and every staging/destination byte |
| result commit | `not_committed` | discard the proposed consequence, fold the durable head and return retained state |
| result commit | `commit_unknown` | retain and re-present exact bytes; after Control loss, re-drive the current query and reconstruct them from the hand's retained response |
| any terminal transaction | `commit_unknown` | retain receipt/result bytes, fence the OwnerLane and re-present that exact transaction; never acknowledge or attach provenance early |
| `terminal` | exact replay | return retained truth; start no policy call or effect |

Runtime Control validates the current request/grant digests, hand receipt and
fence before constructing a terminal. A terminal result is neither acknowledged
nor usable as remote provenance until its exact transaction is confirmed
committed. Process quarantine survives a terminal `outcome_unknown` until the
current retained hand later proves the old process absent; the unknown outcome
itself never changes.

The attempt retains the complete preparation identity and canonical request and grant maps. Their stored
digests must match those exact bytes; the grant's eleven binding members and complete
policy context are therefore durable and independently replayable rather than an
undefined projection.

The hand retains this exact terminal shape before returning it:

```text
resource_acquisition_receipt_v1
  kind, protocol_version, runtime_id, command_id, operation_id, attempt,
  preparation_id, preparation_digest, canonical_request_digest,
  canonical_grant_digest, workspace_ref,
  workspace_lease, executor_identity, git_graph_identity,
  executor_epoch, fencing_token, outcome, reason, process_cleanup, source,
  commit, source_directory, destination_name, destination_label,
  created_parents, tree_digest,
  pack_digest, file_set_digest, file_count, pack_bytes, publication_state,
  publication_identity, git_metadata_digest, observed_budgets
```

The complete canonical receipt is at most 48 KiB. Together with the terminal's
fixed identities and framing it must fit the Store record's 64 KiB ceiling. A
larger candidate becomes local non-success
`indeterminate_evidence/receipt_unavailable`; it cannot become a Store terminal
or remote provenance.

Hand outcomes are `completed`, `refused_before_effect`, `failed`, `cancelled`,
and `indeterminate_evidence`; publication states are `none`, `prepared`,
`published_unverified`, and `committed`; process-cleanup values are `not_started`,
`confirmed`, and `indeterminate`. `observed_budgets` is an exact map with the same
seventeen member names as `resource_budgets`; every receipt carries all seventeen
nonnegative integers. `cpu_time_seconds`, `address_space_bytes`,
`child_file_bytes` and `open_files_per_process` echo the exact hard limit the
helper installed in every child, because the supported kernels do not expose a
portable exact lifetime peak for those dimensions. `process_count` is the
supervisor's exact peak admitted child-image count. Wall, network, diagnostic,
Git-metadata, object, index, scratch, staging, pack and file members are actual monotonic or
barrier-peak measurements; scratch is the greatest complete no-follow inventory
at a required child boundary and makes no claim about a deleted transient between
those boundaries. The receipt therefore distinguishes enforced ceilings from
portable observations by this fixed member classification without inventing
sampled precision. A hard pre-exec or helper-mediated value never exceeds its
grant. The three post-child Git
observations—object bytes, object count and index bytes—may report the bounded
actual value above their acceptance ceiling only with a non-success
`budget_exhausted` receipt; no later child or publication may follow. Scratch
still remains inside its hard complete-task ceiling. No successful receipt
contains an over-limit observation.
`git_metadata_digest` is always the lowercase SHA-256 canonical digest under
kind `loopex.git_metadata_transcript/1` of the evidence package's exact ordered
`git_metadata_digests` list, including the canonical empty-list digest when no
metadata reply was accepted. The receipt, completion intent, local terminal,
evidence package, and replay all require byte-identical equality; a digest alone
never substitutes for the retained list while that evidence is required.
`created_parents` is an ordered list of at most three exact maps with only
`label` and `object_token`. Labels are drawn, in this order, from `.agents`,
`.agents/skills`, and `.agents/.loopex-skill-staging`; a row exists only when
this attempt created that directory. Object tokens use the same stable,
no-follow, at-most-256-byte platform identity required for publication.

Reason and evidence pairings are closed:

| Hand outcome | Exact reason set | Required evidence relation |
| --- | --- | --- |
| `completed` | nil | `process_cleanup: confirmed`, `publication_state: committed`, non-null publication identity, and complete tree/pack/file-set identities |
| `refused_before_effect` | `invalid_request`, `invalid_grant`, `expired_before_start`, `workspace_binding_changed`, `executor_binding_changed`, `fence_changed`, `unsupported_platform`, or `destination_exists` | `process_cleanup: not_started`, `publication_state: none`, and no process/publication identity |
| `failed` | `workspace_prepare_failed`, `git_failed`, `source_mismatch`, `commit_mismatch`, `pack_invalid`, `budget_exhausted`, `prepared_conflict`, or `publication_failed` | `process_cleanup: confirmed`; publication is `none`, `prepared`, or `published_unverified` according to the reached cut |
| `cancelled` | `deadline_elapsed`, `lease_lost`, `fence_lost`, or `control_channel_lost` | `process_cleanup: confirmed`; publication is `none`, `prepared`, or `published_unverified` according to the reached cut |
| `indeterminate_evidence` | `cleanup_unproved`, `ledger_unavailable`, `receipt_unavailable`, or `publication_evidence_unproved` | `process_cleanup: indeterminate`; no success or remote provenance may be inferred |

Tree, pack and file-set identities are either all nil before complete pack
validation or all present afterwards. `publication_identity` is nil for `none`
and `prepared` and non-null for `published_unverified` or `committed`. A bare
error, malformed receipt or lost reply proves nothing and begins reconciliation.

The Store terminal relation is also exact:

| Store outcome | Store reason | Attempt/digest/receipt relation |
| --- | --- | --- |
| `denied` | exactly `policy_denied`, `effect_class_not_permitted`, `workspace_not_permitted`, `interaction_unsupported`, or `policy_unavailable` | attempt, request digest, grant digest, and receipt are all nil |
| `unavailable` | `policy_unavailable` only when no acquisition policy is configured, `resource_binding_changed` only for the exact recovery-only CLI write-ahead path, otherwise `acquirer_unavailable` or `deadline_elapsed_before_attempt` | attempt, request digest, grant digest, and receipt are all nil |
| `completed` | nil | positive attempt, both exact digests, matching `completed` receipt |
| `refused_before_effect` | matching hand reason | positive attempt, both exact digests, matching refusal receipt |
| `failed` | matching hand reason | positive attempt, both exact digests, matching failed receipt |
| `cancelled` | matching hand reason | positive attempt, both exact digests, matching cancelled receipt |
| `outcome_unknown` | `hand_indeterminate` or `reconciliation_indeterminate` | positive attempt and both exact digests; respectively a matching `indeterminate_evidence` receipt or nil receipt |

No other outcome/reason/nullability combination replays. The canonical receipt
digest is `LoopexProtocol.Canonical.digest/1` over the complete receipt under kind
`loopex.resource_acquisition_receipt/1`.

The public read call is exactly
`resource_acquisition_status(runtime, operation_id)`, where the operation ID is
a nonempty binary of at most 256 bytes. It creates no record or state transition and
returns `{:ok, status}` for a retained operation,
`{:error, :resource_acquisition_not_found}` for an absent or other-runtime operation, or
`{:error, :invalid_resource_acquisition_query}` for malformed input, or
`{:error, :store_unavailable}` when the authoritative Store read is unavailable.
That failure is never retained as an acquisition terminal. The status
map has exactly `kind`, `protocol_version`, `runtime_id`, `command_id`,
`operation_id`, `state`, `attempt`,
`canonical_request_digest`, `canonical_grant_digest`, `outcome`, `reason`,
`current_reconciliation_query_id`, `current_recovery_epoch`,
`latest_reconciliation_result_ordinal`, and `receipt_digest`. `kind` is exactly
`resource_acquisition_status_v1` and `protocol_version` is 1. State is `pending_policy`,
`attempt_open`, `reconciling`, `terminal`, or `terminal_quarantined`.
Initial `pending_policy` has nil attempt/digests/outcome/reason/receipt and
nil query/epoch and result ordinal zero. `pending_policy` after `not_dispatched`
retains the last positive attempt, both digests and positive latest result
ordinal, with nil current query/epoch/outcome/reason/
receipt; those fields do not authorize redispatch. `attempt_open` has positive
attempt and both digests but nil outcome/reason/receipt. `reconciling` means one
committed current query has no accepted result and carries its non-null query ID
and positive recovery epoch. It has exactly two base projections: from
`attempt_open`, outcome, reason and receipt remain nil; from
`terminal_quarantined`, it preserves the exact `outcome_unknown`, reason and
receipt digest of that quarantined terminal. Those nullability relations identify
the base without another field, and accepting or superseding the query restores
that base unless the result performs a listed transition. Other states have nil
current query and epoch. Terminal states carry the exact terminal projection and
latest result ordinal. Only an
`outcome_unknown` whose process absence is unproved uses `terminal_quarantined`;
after an exact `post_unknown_absent` result it remains `outcome_unknown` but uses
`terminal`. Every non-unknown terminal has `terminal` state. Receipt digest is
non-null exactly when the terminal retains a receipt. The response is at most
16 KiB and exposes no canonical request/grant, subprocess diagnostic, path or
mutation authority.

The local ledger directory is workspace scoped, but every
`{runtime_id, operation_id, attempt}` owns one independent append-only,
checksummed transaction log and one kernel-released lock. The portable filename
is the lowercase SHA-256 canonical digest of that complete tuple under kind
`loopex.local_resource_acquisition_attempt/1`; every frame retains the tuple and
must recompute the filename before use. No two lock identities may append one
physical log. It uses the same length/canonical-bytes/SHA-256 framing and
under-lock last-incomplete-tail truncation, sync, reopen, and validation rule as
the CLI journal. Only final EOF truncation is repairable; a complete invalid
frame, interior corruption, or broken chain is unavailable and can prove no
effect state. Each framed transaction carries the exact prior authority
generation/digest and prior open generation/digest, appends one closed record
bundle, syncs the log and containing directory, and acknowledges only after
reopen/validation. A frame is at most 512 KiB; one attempt log is at most 64
frames and 16 MiB, with the last two frames and 1 MiB reserved for a terminal or
indeterminate response/authority transaction. The capacity inventory admits at
most six unresolved or quarantined attempts and charges 80 MiB for each one's
log plus complete task scratch. Local admission requires the one exact prepared
acquisition reservation above. Capacity refusal or unavailable inventory returns
`{:error, :acquirer_unavailable}` without an admission, open, authority, receipt,
guard, Store attempt, or workspace byte when preparation was never installed.
A lost preparation reply is resolved from its reservation; after a committed
Store attempt, solicited reconciliation records the reserved no-admission
`not_dispatched` proof before that reservation can release. This bounds repeated
unknown attempts; elapsed cleanup time never frees capacity.
Equivalent durable implementations must preserve that per-attempt atomic
compare-and-append behavior.

The ledger retains six distinct record classes. The first four are exact
closed records:

```text
local_resource_acquisition_admission_v1
  kind, protocol_version, runtime_id, command_id, operation_id, attempt,
  canonical_request_digest, canonical_grant_digest, request, grant

local_resource_acquisition_open_v1
  kind, protocol_version, runtime_id, command_id, operation_id, attempt,
  canonical_request_digest, canonical_grant_digest, phase, staging_label,
  staging_object_token, created_parents, process_group_identity,
  cleanup_reason, cleanup_deadline, open_generation, prior_open_digest

local_resource_acquisition_authority_v1
  kind, protocol_version, runtime_id, command_id, operation_id, attempt,
  canonical_request_digest, canonical_grant_digest, generation, state, reason,
  terminal_receipt_digest, revocation_query_id, revocation_recovery_epoch,
  revoking_workspace_lease, revoking_executor_identity,
  revoking_executor_epoch

local_resource_acquisition_completion_intent_v1
  kind, protocol_version, runtime_id, command_id, operation_id, attempt,
  canonical_request_digest, canonical_grant_digest, open_head_digest,
  prior_provenance_digest, prospective_receipt_digest,
  prospective_receipt, git_metadata_digests
```

Each is keyed in the workspace-scoped ledger by its record kind plus
`{runtime_id, operation_id, attempt}`; `protocol_version` is 1, and `command_id`
equals the complete request's command identity. The admission's
request and grant are the complete canonical maps whose digests it carries, it
is at most 64 KiB, and it is immutable after its first synced write. Exact
re-presentation is idempotent; changed bytes at that key refuse. The open record
is at most 16 KiB. Its digests equal the admission, its phase is exactly
`preparing` or `ready`, `created_parents` has the receipt shape and order, and
`process_group_identity` is one nonempty opaque stable identity of at most 256
bytes. In `preparing`, staging label and token are both nil or both non-nil; in
`ready`, both are non-nil and identify the deterministic attempt staging
directory. `cleanup_reason` and `cleanup_deadline` are both nil until
termination begins and both non-null afterwards. The reason is exactly
`deadline_elapsed`, `lease_lost`, `fence_lost`, or `control_channel_lost`; the
deadline is one nonnegative Unix-millisecond instant fixed by checked addition
of the 2,000-ms cleanup grace. A non-null pair is the irreversible durable
termination cut. The canonical open-record digest uses kind
`loopex.local_resource_acquisition_open/1` over the complete record. Open
creation has `open_generation: 0` and nil prior digest and requires the matching
admission, no open head at the same key, and the exact current `active` authority
record. Every later same-attempt update appends a successor whose generation is
exactly one higher and whose prior digest equals the complete current open head;
the ledger CAS validates both that head and unchanged active authority. Exact
successor replay is idempotent, while a missing or different predecessor refuses
without changing the ledger. Open generations are never deleted or reused for
another attempt, and the highest valid chain member is the sole open head.

The authority record uses the same key. Initial hand admission atomically creates
the admission and generation-zero `active` authority only when admission, open,
receipt and authority are all absent. Active has nil reason, terminal-receipt
digest and every `revocation_*`/`revoking_*` field. Its sole successor is
generation one. `terminal/terminal` has a non-null exact receipt digest and nil
revocation fields. `revoked/not_dispatched` has nil receipt digest and non-null
query ID/recovery epoch plus revoking workspace lease/executor identity/epoch
that exactly match the solicited query and current responder.

There are exactly two `revoked/outcome_unknown` forms. A direct
`indeterminate_evidence` receipt has its non-null exact receipt digest, nil query
ID and recovery epoch, and non-null revoking workspace lease/executor
identity/epoch equal to the original hand binding in that receipt. A
reconciliation-derived `indeterminate_evidence` result has nil receipt digest
and non-null query ID/recovery epoch plus revoking workspace lease/executor
identity/epoch equal to the solicited query and current responder. No mixed
nullability is legal. Before returning either direct receipt or reconciliation
response, the hand atomically appends it with the matching generation-one
`revoked/outcome_unknown` successor. A later reconciliation of the direct form
appends only its retained response; it cannot create or replace authority. This
prevents any late terminal or publication while Store settlement is pending.

There is one second legal initial form. A solicited current responder that holds
the attempt lock and finds admission, open, receipt and authority all absent may
atomically append the exact retained `not_dispatched` response with a
generation-zero `revoked/not_dispatched` tombstone. Its revocation fields bind
that query and responder as above. A delayed original dispatch can create
admission only if authority remains absent, so the admission and tombstone race
has one winner. No generation-two transition or other
state/reason/nullability relation exists. The canonical
authority-record digest uses kind
`loopex.local_resource_acquisition_authority/1` over the complete record.

The completion intent is legal only after the child group is confirmed absent,
the destination is reopened and fully verified, every observed-budget member is
final, and the current open head still has nil cleanup fields. Its prospective
receipt is the complete exact `completed` receipt below, including
`publication_state: committed`; the intent is preparation evidence and does not
make that prospective state true. Its digest uses kind
`loopex.local_resource_acquisition_completion_intent/1`. Under the attempt lock
its `git_metadata_digests` is the complete exact ordered transcript defined for
the evidence package, and its canonical transcript digest must equal the
prospective receipt's `git_metadata_digest`. This retained list is the recovery
source after the provenance and Store-terminal crash cuts; the aggregate digest
alone cannot reconstruct it. The complete intent remains within the 512 KiB
frame ceiling or completion becomes `indeterminate_evidence/receipt_unavailable`
before provenance. Under the attempt lock
the helper appends, syncs, reopens, and validates this intent before it may commit
provenance. Exact replay is idempotent and changed bytes conflict. If cancellation
wins before provenance, the intent remains nonauthorizing and the cancellation
receipt wins. If matching committed provenance exists, the intent makes the
byte-identical completed receipt reconstructible and completion wins.

The other two classes are the retained reconciliation response below and the
complete synced terminal receipt. That receipt is keyed by
`{runtime_id, operation_id, attempt}`. Its first complete synced write wins;
exact byte replay returns the retained receipt, while any changed byte at that
key conflicts and can never overwrite or create a second terminal receipt. A
known non-indeterminate terminal appends the receipt and matching generation-one `terminal`
authority record in the same local-ledger transaction.

Every open create/update, guard release, Git process start, workspace mutation,
publication transition and receipt write is routed through the local helper
while it holds the attempt lock and conditionally verifies the complete current
generation-zero `active` authority record. Guard release, Git, workspace,
staging, provenance, publication, and ordinary open updates additionally require
the current open head's cleanup fields to be nil. No BEAM task or child may mutate the
workspace or local ledger outside that mediated path. A paused old hand that
resumes after revocation therefore fails before mutation even if it still holds
old request or grant bytes.

On deadline, lease, fence, or Control-channel loss, the helper takes the attempt
lock and then the provenance lock, if a generation exists. A matching already
committed provenance generation is the completion-wins cut: cancellation cannot
begin and recovery must finish the completed receipt. Otherwise the helper
appends, syncs, reopens, and validates one open successor with the fixed cleanup
reason/deadline before sending any signal. Cancellation has then won. Only
authenticated process status/signal/wait, exact-owned staging/prepared cleanup,
and the matching cancelled or indeterminate receipt-plus-authority transaction
remain legal. Restart from a non-null cleanup pair resumes only that sequence; it
cannot release the guard, run Git, mutate the destination, or promote matching
bytes to committed provenance. After confirmed absence it records the exact
cancelled receipt; if process or publication evidence cannot be proved it records
the direct indeterminate receipt and revokes authority. Tests race the durable
cleanup successor against the committed-provenance cut in both orders.

The only atomic local-ledger bundles are: admission plus generation-zero active
authority; generation-zero no-admission tombstone plus retained
`not_dispatched` response; one open creation or successor; one retained
completion intent; one retained reconciliation response; one retained response plus generation-one revocation
for admitted `not_dispatched` or `outcome_unknown`; one direct indeterminate
receipt plus generation-one `revoked/outcome_unknown`; and one non-indeterminate
terminal receipt plus generation-one terminal authority. The helper holds the same attempt lock from
the active-authority/open-head comparison through guard creation or release,
parent/staging mutation, prepared/committed provenance mutation, no-replace
publication, receipt construction, and the corresponding append/sync. A crash
may leave the prior proven generation plus inspectable external bytes, but no
concurrent revocation or later stale hand can cross that locked authority cut.

After admission the hand creates one task-owned guard process in a new process
group. The guard cannot `exec` Git until it reads the one exact single-use release
token from a private pipe. Wrong input, EOF or owner death exits without exec.
The hand captures the group identity and first syncs the open record in
`preparing` phase with nil staging and empty created parents. Each parent or
staging creation replaces and syncs that exact attempt's record with the newly
proved identities. Only the final `ready` phase has a non-null staging identity,
and only then does the hand send the release token. A crash after child creation
but before the first sync therefore closes the pipe and cannot start Git; a crash
after release has a durable process/staging identity for reconciliation. To
answer `not_dispatched`, the current hand holds the attempt lock, verifies the
complete attempt/query/current-responder bindings, and chooses one exact atomic
path: when admission and active authority exist but open and receipt do not, it
appends the generation-one `revoked/not_dispatched` successor plus response; when
admission, open, receipt and authority are all absent, it appends the
generation-zero revoked tombstone plus response. That committed revocation is
the sole positive proof. An open or receipt record, inconsistent partial state,
failed revocation or malformed evidence can never prove it from elapsed time or
process absence. Race tests require both orders: tombstone before delayed
admission makes that admission fail, while admission before reconciliation uses
the active-to-revoked path and prevents later open/guard release.

`source` is one already-canonical ASCII HTTPS Git repository URL of at most
1,024 bytes. Its exact grammar is lowercase `https://`, a lowercase DNS host,
and `/` followed by one to 64 nonempty path components. The host is two or more
dot-separated A-labels, has no empty or trailing label, is at most 253 ASCII
bytes, and has a final label containing at least one `[a-z]` so numeric shorthand
cannot become an IP literal. Each label is 1–63 bytes, begins and ends with
`[a-z0-9]`, and otherwise contains only `[a-z0-9-]`; a path component
contains only RFC 3986 unreserved ASCII bytes `[A-Za-z0-9._~-]`, preserves case,
and is neither `.` nor `..`. The URL has no explicit port, trailing slash,
userinfo, query, fragment, percent escape, backslash, control byte, Unicode byte,
empty/repeated component or credential material. M3 performs no equivalence
normalization: input outside that grammar refuses. `source`,
`canonical_public_https_source`, `sanitized_source`, and the source retained in
the command, policy request, hand request, receipt, provenance generation,
imported manifest `origin` and `loopex.skill_source/1` preimage are that
identical byte string. M3 permits only anonymous HTTPS. It refuses IP-literal authorities,
SSH/scp syntax, `git://`, `file://`, `ext`, local paths, interactive prompts,
private authentication and fallback to ambient credentials. The hand sets a closed environment and Git configuration:
no system/global repository config, askpass, credential helper, redirect,
submodule, hook, filter, LFS, alternates or protocol except HTTPS. Only the HTTPS
remote helper belonging to the selected Git executable may run. A local source
exists only behind the hand conformance fixture and is not a production request.
A later private-source secret channel requires another protocol version and
decision.

`source_directory` is an already-normalized relative UTF-8 label of at most
1,024 bytes and eight components. It has no leading/trailing slash, empty, `.` or
`..` component, backslash, control byte, normalization collision or platform
separator alias; `/` is its only separator. Each component uses the same bounded
portable filename subset `[A-Za-z0-9._~-]` and is at most 128 bytes. Input that
would change under normalization refuses rather than acquiring another tree. The command
digest, policy request, hand request, receipt and `loopex.skill_source/1`
preimage retain these exact normalized bytes.

The reference hand makes the transport byte ceiling enforceable by routing Git's
HTTPS connection through one task-owned loopback CONNECT relay. The hand clears
all proxy-bypass inputs, configures only that relay, and permits one CONNECT to
the canonical source authority's exact host and port. The relay performs no TLS
termination, redirect, authentication or content interpretation; it counts every
remote-to-Git octet, closes both directions before accepting octet 16,777,217,
and records the count in `network_received_bytes`. Git therefore retains end-to-
end TLS validation while the hand owns the cutoff. An implementation that cannot
force all Git transport through an equivalently closed counted path reports
acquisition unavailable before the guard release. Git receives exactly one
helper-created bare task repository, object directory and temp root; their
stable identities and allowed relative label classes are fixed before exec and
Git cannot select another writable root.

The reference graph version is `loopex.git_skill_fetch/1`. The 40- or 64-byte
lowercase commit selects `sha1` or `sha256` respectively before repository
creation; no negotiation changes that choice.

Before `capabilities/1` may advertise acquisition, the Port owner establishes
one executable snapshot for `loopex_fs_guard`, `git`, `git-remote-https`, and
`git-index-pack`. It starts each resolution from a retained host-approved
executable-root directory handle, examines every component without following it
implicitly, and opens the final ordinary executable regular file without
following the final label. A symbolic alias is permitted only through an
explicit acyclic walk of at most eight links and 4,096 aggregate raw target
bytes; every target must remain beneath the retained root. Absolute or escaping
targets, loops, another object kind, an unreadable component, or an unverifiable
object refuse the graph.

An executable-image row has exactly `%{"name" => name, "binary_digest" =>
sha256, "byte_length" => nonnegative_uint64, "file_mode" =>
nonnegative_uint32, "object_token" => object_token, "resolution_digest" =>
resolution_digest, "launch_mode" => "verified_handle" |
"verified_child_image"}`. `object_token` is the platform's stable no-follow
object identity of at most 256 bytes. `resolution_digest` is the lowercase
SHA-256 canonical digest under kind `loopex.executable_resolution/1` of the
executable-root object token and ordered component transcript; each transcript
row contains the component-name digest, observed object kind and object token,
plus the raw-target digest only for an alias. Absolute paths and raw alias
targets remain process-local. The owner retains the final open handle and
resolution transcript for the executor epoch.

`git_graph_identity` is the lowercase SHA-256 canonical digest under kind
`loopex.git_skill_fetch/1` of exactly `%{"graph_version" =>
"loopex.git_skill_fetch/1", "object_format" => object_format, "git_version" =>
exact_version_line, "guard_helper" => guard_helper_row,
"git_binary_digest" => git_row.binary_digest, "exec_programs" => [git_row,
git_remote_https_row, git_index_pack_row], "common_config_digest" => sha256,
"environment_shape_digest" => sha256, "write_grammar_digest" => sha256}`. The
executor identity and epoch bind exactly this graph identity, and capabilities,
policy request, acquisition request and receipt carry the same value.

At the final serialized pre-start boundary, while the attempt lock and
current-authority hold remain active and immediately before the one-shot guard
release, the hand re-stats and fully rehashes every retained executable handle,
compares its object token, length, mode and digest, and repeats the
descriptor-relative no-follow resolution from the retained root. The fresh
resolution must reach the same retained object and reproduce the exact
resolution digest. This detects both path-component replacement and in-place
byte change; a retained handle alone does not waive it. Any mismatch keeps the
guard closed, yields `refused_before_effect/executor_binding_changed`, and
permanently disables new acquisition for that executor epoch.

Let `G` be the absolute verified Git binary followed, in this exact order, by
`-c credential.helper=`, `-c core.hooksPath=<verified-empty-directory>`,
`-c protocol.version=2`, `-c protocol.file.allow=never`,
`-c protocol.ext.allow=never`, `-c protocol.git.allow=never`,
`-c protocol.http.allow=never`, `-c protocol.https.allow=always`,
`-c submodule.recurse=false`, `-c fetch.recurseSubmodules=false`,
`-c fetch.writeCommitGraph=false`, `-c maintenance.auto=false`,
`-c gc.auto=0`, `-c pack.writeReverseIndex=false`,
`-c fetch.unpackLimit=0`, `-c transfer.unpackLimit=0`,
`-c transfer.fsckObjects=true`, `-c fetch.fsckObjects=true`,
`-c http.followRedirects=false`, and `-c http.sslVerify=true`. The ordered child
program is closed:

| Phase | Exact argv after `G` | stdin / semantic stdout | Allowed writes after the child |
| --- | --- | --- | --- |
| initialize | `init --bare --quiet --template=<verified-empty-directory> --object-format=<sha1-or-sha256> --initial-branch=loopex-empty <task-repository>` | closed / none | fixed directories plus `HEAD` and `config`; reopened config has only the init keys and chosen object format |
| fetch | `--git-dir=<task-repository> fetch --quiet --no-tags --no-recurse-submodules --no-write-fetch-head --no-auto-maintenance --no-auto-gc --no-write-commit-graph --no-show-forced-updates --jobs=1 --depth=1 -- <source> <commit>` | closed / none | `shallow`, transient `shallow.lock`, one `objects/pack/tmp_pack_<6-to-64-alnum>` and one `tmp_idx_<6-to-64-alnum>`, replaced by exactly one `pack-<native-object-id>.pack` and matching `.idx` |
| commit type | `--git-dir=<task-repository> cat-file -t <commit>` | closed / metadata `commit\n` | none |
| selected tree | `--git-dir=<task-repository> ls-tree -z --full-tree <commit> -- <source-directory>` | closed / exactly one tree row naming the byte-identical source directory | none |
| tree walk | `--git-dir=<task-repository> ls-tree -r -t -z <selected-tree-object-id>` exactly once | closed / zero or more recursive tree/blob rows in Git order | none |
| object type/size | `--git-dir=<task-repository> cat-file -t <object-id>` then `cat-file -s <object-id>` | closed / exact type line then unsigned-decimal size line | none |
| blob | `--git-dir=<task-repository> cat-file blob <blob-object-id>` | closed / authenticated predeclared blob stream | only the helper-owned exact staged file |

There is no shell, ref-name, tag, checkout, reset, archive, submodule, filter, or
content-selected child. Git may internally execute only the bound HTTPS helper
and index-pack program during `fetch`; the supervisor rejects every other image.
The metadata channel accepts only ASCII `commit\n`, `tree\n`, `blob\n`, an
unsigned decimal size plus LF, or NUL-terminated rows of exactly six octal mode
digits, space, `tree|blob`, space, the full native object ID, tab, and a raw name.
Type and size replies remain at most 64 bytes each; the selected-tree row,
recursive walk, and all type/size replies share the 576 KiB
`git_metadata_bytes` attempt ceiling. The recursive walk accepts at most 512
tree/blob rows, the exact worst-case directory-plus-file cardinality for 64 files
at eight components; Git stores no empty directory. Names then pass the portable
label/UTF-8/depth/cardinality rules before use. Extra fields, missing or
extra terminators, abbreviated IDs, duplicate/colliding names, invalid type/mode,
or output after the accepted grammar refuses. The metadata digest uses kind
`loopex.git_metadata/1` over command ordinal plus the exact raw reply and is
retained in the evidence package's exact ordered `git_metadata_digests` list;
the receipt's `git_metadata_digest` binds that complete list. Neither digest
permits replay from unretained or reparsed diagnostic output.

Every child receives only `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`, the helper-owned
`HOME`, `XDG_CONFIG_HOME`, `TMPDIR`, and empty-search `PATH`, the verified
`GIT_EXEC_PATH`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_SYSTEM=/dev/null`,
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`,
`GCM_INTERACTIVE=never`, and uppercase/lowercase HTTPS proxy variables naming
the loopback relay. Every HTTP, ALL_PROXY, and NO_PROXY spelling and every other
`GIT_*`, credential, askpass, SSH, loader, alternate-object, and proxy variable
is absent. The graph passes arguments directly to `execve`; stdout/stderr routes
are exactly those in the table and output policy.

The helper rejects any file outside the table's fixed directories and label
classes, any ref or `FETCH_HEAD`, loose object, commit graph, reverse index,
additional pack/index/temp, or write by a metadata child. A fetch that completes
without the exact full object ID, including a server refusal to serve an
unadvertised SHA, maps to `commit_mismatch`; it never retries a branch, tag,
abbreviation, or advertised tip. Transport/TLS/relay failure maps to
`git_failed`, and an object-format disagreement maps to `commit_mismatch`.
`cat-file -t` must then return `commit` for that exact ID.

The closed write graph also proves the scratch ceiling without sampling deleted
files: at most two 16 MiB pack extents (temporary/final replacement cut), one
20 MiB hard-limited index/temp extent, 1 MiB of staged pack content, and less
than 64 KiB of fixed repository metadata can coexist, totaling less than 64
MiB. The final accepted object/index ceilings remain 16 MiB and 512 KiB, and the
index fanout table must report at most 4,096 objects. Every other regular file is
helper-created under the staged aggregate and 20 MiB per-file limit. The
supervisor records every admitted image from spawn through reap; the bound graph
has at most four simultaneous images and the request ceiling of 16 leaves no
content-driven expansion. An unobserved descendant, label, or write makes the
platform/Git build unsupported before ordinary acquisition. Startup and
per-attempt probes inject an extra image and every write-class violation to prove
the monitor kills the group and cannot publish. Per-process CPU/address-space
limits and the group wall limit contain compressed or delta-expanded hostile
input. These object limits are retained-content acceptance bounds; neither
substitutes for the transport or process envelope.

The relay exclusively owns DNS resolution. It normalizes IPv4-mapped IPv6 forms
to IPv4 before classification and deduplicates binary addresses. The complete
answer must contain 1–16 unique addresses and its canonical family-then-byte-
sorted encoding must fit 1,024 bytes. A larger, empty, malformed or partially
unclassifiable answer refuses before guard release.

`global_unicast_v1` is this frozen longest-prefix-match table. It deliberately
defines the conservative ordinary-public subset M3 permits, rather than treating
every address marked globally reachable by a mutable registry as suitable for
Git. IPv4 begins with allow and the listed prefixes deny; IPv6 begins with deny,
`2000::/3` allows, and its more-specific listed prefixes deny.

| Family | Prefix | Action |
| --- | --- | --- |
| IPv4 | `0.0.0.0/0` | allow |
| IPv4 | `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8` | deny |
| IPv4 | `169.254.0.0/16`, `172.16.0.0/12` | deny |
| IPv4 | `192.0.0.0/24`, `192.0.2.0/24`, `192.88.99.0/24`, `192.168.0.0/16` | deny |
| IPv4 | `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24` | deny |
| IPv4 | `224.0.0.0/4`, `240.0.0.0/4` | deny |
| IPv6 | `::/0` | deny |
| IPv6 | `2000::/3` | allow |
| IPv6 | `2001::/23`, `2001:db8::/32`, `2002::/16`, `3fff::/20` | deny |

The table is acceptance-frozen from the IANA IPv4 and IPv6 special-purpose
registries reviewed on 2025-10-09; later registry changes do not silently alter
M3 and require an ADR/gate amendment. The relay pins the complete validated
answer set and its canonical digest before guard release, connects only in
deterministic sorted order within that set without re-resolution, and preserves
the canonical DNS hostname for CONNECT authority and end-to-end TLS verification.
Mixed allow/deny answers, mapped aliases that classify differently, resolution
changes and connection fallback outside the pinned set refuse with zero Git
start. The loopback Git
fixture enters only through a test-build conformance injection that production
request bytes cannot select; production resolution never exempts loopback or
private addresses.

The hand uses only the tabled graph against the isolated pack/index; it never
performs a working-tree checkout. Metadata inspection proves the requested object is a
commit, opens only the selected tree, bounds every object before extraction, and
refuses gitlinks, symlinks and special modes. One raw blob at a time enters only
the verified content channel above; the helper writes its exact declared bytes
with fixed non-executable permissions and syncs them before the next object.
This permits a legal non-text pack member up to the pack ceiling without
reclassifying arbitrary Git diagnostics as content. `SKILL.md`, inspection text
resources and selected model-staged blocks retain their stricter ceilings. Every child belongs to the
captured process group and receives the hard CPU, address-space, file-size and
open-file limits plus the closed process/write graph above. Deadline, lease loss, fence loss,
control-channel loss or budget exhaustion invokes group termination, bounded
grace, forced cleanup and a retained truthful receipt. Downloaded instructions,
hooks, scripts and executable bits are never invoked.

The reference implementation realizes its no-follow, durable-journal,
process-supervision and no-replace guarantees through the repository-owned
`apps/loopex_executor_local/c_src/loopex_fs_guard.c`, built as the private Port
executable `loopex_executor_local/priv/loopex_fs_guard`. It is a C11, libc-only
helper with a closed length-prefixed command protocol and 1 MiB request/response
bounds. That frame contains one at-most-512-KiB local record or provenance CAS,
its complete append/compare envelope, and framing without truncation; exact
maximal-envelope proof remains required. The 2 MiB evidence package and verified
snapshot, pack, Git-metadata and blob
streams use separately authenticated length-bounded descriptors and never enter
that frame. A snapshot descriptor binds the exact manifest/content lengths,
digest and destination identity before a stream begins; the helper enforces the
64 MiB content and 8 MiB metadata ceilings, syncs, reopens and recomputes the
complete snapshot before acknowledging it. One helper instance independently opens
the host-supplied canonical workspace root and the executor-epoch-bound protected
hand/state root with no-follow semantics, compares both expected stable object
identities, and never resolves a label from one root beneath the other. Canonical
records retain only their opaque root/lease bindings, not either path.

The Port owner admits the running `loopex_fs_guard` child only after an
independent kernel-backed check proves that the child's actual executable image
matches the bound helper row. A pathname, `argv[0]`, version output, helper
self-report, or reopening the pathname is not image proof. No root handle,
command frame, authority hold, relay endpoint or writable descriptor is
delivered before that check succeeds.

`verified_handle` means the kernel executes the retained final handle without
another pathname lookup. `verified_child_image` means a platform execution-event
barrier holds the newly selected image before it can perform an effect, exposes
a kernel-authenticated handle or stable identity for that actual image, and
permits the supervisor to hash and compare it with the bound row before release.
The helper applies one of those modes to the main Git child and every internally
selected `git-remote-https` and `git-index-pack` image. `GIT_EXEC_PATH`, directory
membership, a matching basename and a pre-exec pathname digest are routing
inputs only; none proves the selected image. An unexpected, changed or
unverifiable child receives no release, and the helper terminates and reaps the
group.

Startup self-probes each selected launch mode on the current target. If neither
mode can prove the helper and every permitted Git image, `capabilities/1`
returns `{:error, :acquirer_unavailable}` and ordinary sessions continue
without Git acquisition. A mismatch before the one-shot guard release is
`refused_before_effect/executor_binding_changed`. A child-image mismatch after
release settles as `failed/git_failed` only with confirmed process-group
cleanup; otherwise it is `indeterminate_evidence/cleanup_unproved`.

One acquisition-hand process incarnation owns one never-reused executor epoch
and exactly one executable graph. Any resolution, digest, handle or actual-image
mismatch permanently disables new acquisition and child creation in that
incarnation; the hand does not re-resolve, recompute or substitute an executable
under the same epoch. Already-open attempts may use the verified running helper
only for status, termination, retained-receipt recovery and settlement, never
for another child or publication. Helper or acquirer loss ends the incarnation.
A replacement requires a fresh executor epoch, fresh graph identity and
successful startup probe; the host's current-authority route refuses reuse of
the ended epoch. The current Darwin and Linux lanes prove their concrete mode
before claiming Git acquisition support; a target with only pathname checks is
explicitly acquisition-unavailable.

The helper protocol is closed to these operation families:

- open/reopen both roots and compare their expected stable identities;
- acquire/release the runtime, CLI-operation, capacity, attempt, and provenance
  locks;
- create/reopen the append-only CLI journal, compare-and-append one frame,
  repair only its final incomplete frame, append retirement, and remove only the
  named runtime snapshot/intent after retirement;
- create/reopen/remove one per-runtime snapshot and binding intent, inventory
  the three reservation classes under the capacity lock, and create, update,
  convert, or retire their exact reservation files;
- create/reopen the per-attempt local ledger, compare-and-append a closed bundle
  against authority/open heads, and repair only its final incomplete frame;
- create/reopen/identify/sync directories; stream and verify bounded snapshot,
  evidence-package, Git-metadata, pack, and staged regular-file bytes; inventory the closed scratch
  graph; compare-and-swap the provenance slots; publish with no replacement; and
  remove only exact-owned staging;
- spawn/release/status/signal/wait the authenticated guard process group and
  append the durable cancellation open successor before its first signal.

The universal lock order when several are held is runtime, CLI operation,
capacity, attempt, then provenance locks in canonical provenance-digest order.
Capacity admission or release may hold the capacity lock followed by one
attempt lock and the provenance locks required to validate exact dependencies;
it never acquires them in reverse order. Every cross-root workspace mutation
holds the attempt lock and uses only workspace-root handles. A provenance mutation also holds its canonical
`{workspace_ref, pack_digest}` lock; its conditional slot write is synced and
reopened before release. Two lock identities never append one log or mutate one
provenance slot concurrently. Unknown lock, CAS, or repair completion is reopened
and resolved exactly; it is never treated as absence or free capacity.

The helper uses relative `openat`/`mkdirat`/`fstatat`, no-follow/no-replace
creation, fixed modes, exact-length writes, and file/directory syncs. It supplies
the hard child resource limits and a per-attempt supervisor identity containing
the supervisor PID, platform start token, process-group ID and an unpredictable
control nonce bound to its state-root endpoint. Status or termination succeeds
only after authenticated nonce/start-token verification; a missing supervisor,
leader death, reused PID/group or unverifiable descendant state is unknown, not
absence. Owner/control loss makes the supervisor terminate and reap the group;
only its authenticated quiescence acknowledgement proves process absence. On
Darwin the publish
operation is `renameatx_np(..., RENAME_EXCL)`; on Linux it is
`renameat2(..., RENAME_NOREPLACE)` through the platform syscall interface. Any
missing syscall or resource-limit primitive, unsupported filesystem sync/identity
behavior, swapped/replaced root, malformed helper reply, helper crash, or failed
startup self-probe makes acquisition unavailable before Git or workspace
mutation. The helper is a Port, never a NIF, so a native fault cannot corrupt the
BEAM VM.

Building `loopex_executor_local` for either supported target therefore requires a
C11 compiler and system libc headers; the repository Mix compiler records the
compiler identity and builds the helper from that one source. A packaged runtime
ships the target helper under `priv` and requires no runtime compiler. Acceptance
proves source-built behavior and the atomic-race self-probe on Darwin with the
accepted Elixir/OTP floor pair and on the current Linux lane. A prebuilt helper
from another source or target cannot satisfy that evidence.

Before process start the hand resolves the destination chain from the retained
workspace-root handle and checks the exact destination with no-follow
primitives. Any existing destination file, directory, link, or special object
yields `refused_before_effect` and remains byte-for-byte unchanged. After the
attempt and guard/open record are durable, but before guard release, the hand
may create missing fixed parent labels `.agents`, `.agents/skills`, and
`.agents/.loopex-skill-staging` in that order as ordinary mode-0755 directories.
Each step uses a directory-relative no-follow create, syncs the containing
directory, reopens the result, verifies a stable object identity, and updates
and syncs its open ledger before continuing. A concurrent ordinary directory
creation is accepted only after the same checks; a file, link, special object,
replacement, identity change, or unsupported directory-sync primitive fails
with `workspace_prepare_failed` before Git runs. The hand never infers ownership
of a directory another actor created.

Each attempt writes only to
`.agents/.loopex-skill-staging/<staging-digest>`, where `staging-digest` is the
64-byte lowercase SHA-256 canonical digest under kind
`loopex.resource_acquisition_staging/1` over exactly `%{"workspace_ref" =>
workspace_ref, "runtime_id" => runtime_id, "operation_id" => operation_id,
"attempt" => attempt, "canonical_request_digest" =>
canonical_request_digest}`. This is a task-owned ordinary directory whose
stable object token is in the synced open ledger before guard release. A
first creation of that label refuses `workspace_prepare_failed` before guard
release when any object already exists and never adopts or removes it. Only
reconciliation or resume of an already-open exact attempt may reopen the object,
and then the matching open record must name the same stable directory identity;
a mismatch is left untouched and fails. This location is a same-filesystem sibling of the
literal discovery root `.agents/skills`, never beneath it, so incomplete staging
cannot enter discovery and the final rename cannot cross a filesystem. The hand
verifies every identity and bound, syncs all staged regular files and
directories, and computes the complete ordered file-set and pack digests.
Interruption or failure may leave fixed empty parent directories; those ordinary
workspace bytes are never removed automatically and a later fresh discovery
reports an attested empty skills directory rather than absence. Cleanup removes
only the exact attempt staging directory while its ownership and non-unknown
outcome remain proved.

Publication uses one two-generation `skill_import_v1` in the hand's workspace-
scoped retention store, keyed by installed `pack_digest`. The outer entry has
exactly `kind`, `workspace_ref`, `pack_digest`, `committed`, and `prepared`.
Each non-null generation has exactly:

```text
state, runtime_id, operation_id, attempt, canonical_request_digest, canonical_grant_digest,
destination_label, publication_identity, source_id, source, commit,
source_directory, tree_digest, file_set_digest, files,
completion_intent_digest, hand_receipt_digest
```

`files` is one through 64 exact `%{"label" => label, "size" => size,
"digest" => digest}` maps in canonical label order. Source, source ID, commit,
tree, file-set and outer pack digest obey the canonical relations in this ADR.
The outer `kind`
is exactly `skill_import_v1`; `committed` and `prepared` are independently nil
or one generation subject to the two-slot limit. A non-null prepared generation
has `state: prepared` and nil `publication_identity`, `completion_intent_digest`,
and `hand_receipt_digest`. A non-null committed generation has `state: committed`
and all three are non-null; every
other generation field is non-null and matches its Store runtime/operation,
outer workspace, and pack digest. No other state value or slot/state/nullability
relation is legal. `import_generation_digest` is the lowercase SHA-256 canonical
digest under kind `loopex.skill_import_generation/1` over every generation
member and its outer workspace/pack identity. The committed completion-intent
and receipt digests must match the exact local records for that attempt. The
store retains at most one current committed generation plus one operation/
attempt-qualified prepared generation. Every slot transition uses the helper's
kernel-released provenance lock keyed by the canonical digest of
`{workspace_ref, pack_digest}` while the caller already holds its attempt lock;
the helper compares the complete prior two-slot bytes, conditionally writes one
successor, syncs and reopens it before acknowledgement. M3 never replaces a
different committed generation. A non-null committed generation matching this
exact operation/attempt/request/grant is terminal replay; any other non-null
committed generation refuses before preparing or publishing. Its prepared-slot
transition is one atomic conditional write: nil may become only this exact
operation/attempt/request/grant generation while committed is nil;
an exact re-presentation is idempotent; a different live generation refuses
without changing either slot. Before any unknown outcome exists, normal cleanup
conditionally clears only the exact matching operation/attempt/request/grant
generation. Once its owner is unknown, the prepared slot and staging remain
untouched until explicit operator recovery outside this protocol. A conflicting
or unresolved prepared slot blocks publication. Prepared is written and synced
with nil publication identity only while committed is nil. An identical pack
digest never overwrites committed merely because a new attempt started. The hand then
performs one atomic no-replace rename; a racing destination is a known failure
and is untouched. A platform without a provable no-replace primitive reports
acquisition unavailable before Git starts.

After rename the hand syncs the parent, reopens the destination without following
links, recomputes every byte and identity, and captures a stable no-follow object
token of at most 256 bytes from the platform directory handle. The platform must
let the hand compare that token after restart without following or reopening a
different object; otherwise acquisition is unavailable before Git starts.
`publication_identity` is the lowercase SHA-256 canonical digest under kind
`loopex.skill_publication/1` of exactly `%{"workspace_ref_digest" =>
workspace_ref_digest, "destination_label" => destination_label,
"object_token" => object_token, "file_set_digest" => file_set_digest}`. The
workspace digest uses kind `loopex.workspace_ref/1`. Only then may the hand
construct the complete prospective completed receipt with final observed
budgets and append the exact synced completion intent. Only after reopening that
intent may it
atomically copy every prepared member unchanged except `state`, install the
verified publication identity plus the matching completion-intent and receipt
digests, install the committed slot only if it is still nil (or exact-match an
already installed byte-identical generation during replay), and clear only that
exact prepared generation under the same provenance CAS. A different committed
generation refuses and remains unchanged. After that synced and
reopened successor it appends the byte-identical completed receipt and terminal
authority and returns. A crash before the provenance CAS leaves a nonauthorizing
completion intent; cancellation or exact recovery may settle it. A crash after
the CAS reconstructs the receipt from that intent, and committed provenance is
the completion-wins cut. It never guesses observed budgets or terminal bytes.
Normal cleanup abandons only its own prepared generation and staging before an
unknown outcome exists. It never removes or changes a destination it cannot prove
this attempt published. Across interruption, attempt-owned destination writes are
absent or complete; a racing external writer may instead leave an arbitrary
existing object, which remains untouched and has no attempt provenance.
Prepared-only or published-unverified content is ordinary local content and is
never auto-promoted from matching bytes.

The public reconciliation request is exactly
`%{type: :reconcile_resource_acquisition,
reconciliation_query_id: reconciliation_query_id,
operation_id: operation_id}`. Both IDs are nonempty binaries of at most 256
bytes. It is permitted only for `attempt_open` or `terminal_quarantined`.
Runtime Control atomically commits the query record below before returning
`{:accepted, reconciliation_query_id}` or invoking the hand. Re-presenting the
same query ID for the same operation creates no second query. While it remains
the current unresolved query and its expected responder binding remains current,
replay returns that retained acceptance and schedules the same idempotent hand
query. If that responder binding changed, replay returns the same retained
`{:accepted, reconciliation_query_id}` without a hand call; only a different
well-formed query ID may commit the next recovery epoch and supersede it. After
result, supersession, a later attempt, or terminal, exact replay likewise returns
that original accepted tuple without a hand call; callers use the separate
status query for current state. Reusing
the query ID for another operation returns `{:error, :idempotency_conflict}`.
A different ID while one query is outstanding and its expected responder
binding remains current returns `{:error, :reconciliation_busy}`. If any
expected responder workspace-lease, executor-identity, or executor-epoch member
has changed, a different well-formed query ID may atomically supersede the
current query at the next recovery epoch; supersession records no observation
and authorizes no effect inference. `pending_policy` and settled `terminal` return
`{:error, :reconciliation_not_permitted}`; an absent or other-runtime operation
returns `{:error, :resource_acquisition_not_found}`. These state observations
create no durable record. Malformed input returns
`{:error, :invalid_resource_acquisition_reconciliation}` and writes nothing. A
later observation requires a new query ID. A superseded query remains replayable
as retained acceptance but never calls the hand again.

Store unavailability before a reconciliation candidate is submitted returns
`{:error, :store_unavailable}` with no hand call. Once its exact query
transaction was submitted but has no authoritative disposition, the call
returns `{:error, :commit_unknown}` and replay only resolves or re-presents that
same candidate. `not_committed` folds current state and returns the applicable
retained reply or closed state error above; it never invokes the hand. A callback
or transport failure after the query commits leaves the accepted query
reconciling, so exact replay continues to return its retained
`{:accepted, reconciliation_query_id}` while rescheduling only the same solicited
query when its responder binding remains current.

Reconciliation uses exact solicited request/response forms:

```text
resource_acquisition_reconciliation_query_v1
  kind, protocol_version, reconciliation_query_id, recovery_epoch, runtime_id,
  operation_id, attempt, canonical_request_digest, canonical_grant_digest,
  workspace_ref, attempt_workspace_lease, attempt_executor_identity,
  attempt_executor_epoch, expected_responder_workspace_lease,
  expected_responder_executor_identity, expected_responder_executor_epoch,
  fencing_token

resource_acquisition_reconciliation_response_v1
  kind, protocol_version, reconciliation_query_id, recovery_epoch, runtime_id,
  operation_id, attempt, canonical_request_digest, canonical_grant_digest,
  workspace_ref, attempt_workspace_lease, attempt_executor_identity,
  attempt_executor_epoch, responder_workspace_lease, responder_executor_identity,
  responder_executor_epoch, fencing_token, observation, process_disposition,
  destination_disposition, destination_identity, receipt

resource_acquisition_reconciliation_result_v1
  kind, protocol_version, reconciliation_query_id, recovery_epoch, runtime_id,
  operation_id, attempt, canonical_request_digest, canonical_grant_digest,
  workspace_ref, attempt_workspace_lease, attempt_executor_identity,
  attempt_executor_epoch, expected_responder_workspace_lease,
  expected_responder_executor_identity, expected_responder_executor_epoch,
  responder_workspace_lease, responder_executor_identity,
  responder_executor_epoch, fencing_token, ordinal, response_digest,
  observation, process_disposition, destination_disposition,
  destination_identity, receipt_digest, consequence
```

Each `kind` is exactly its displayed record name and each `protocol_version` is
1. `current_reconciliation_query_digest` in the authority observation is the
lowercase SHA-256 canonical digest of the complete query under kind
`loopex.resource_acquisition_reconciliation_query/1`; the hand recomputes it
from the received query rather than accepting a caller-supplied digest. Query
IDs are unique bounded runtime-control identities. `recovery_epoch` is
operation-wide, begins at one, and advances by exactly one for each accepted
initial or superseding query; it never resets at an attempt boundary. The
query's attempt
lease and executor fields equal the original committed request and grant. Its
expected responder lease and executor fields come from the current host route.
The response echoes the attempt bindings and carries the actual responder
bindings; the result retains the expected and actual responder bindings. Actual
responder fields must equal the expected fields. A successor responder epoch or
lease may differ from the original attempt; equality across those two identities
is neither required nor sufficient.

`observation` is exactly `not_dispatched`, `in_flight`, `terminal`,
`indeterminate_evidence`, or `post_unknown_absent`. `process_disposition` is
exactly `not_started`, `running`, `absent`, or `indeterminate`.
`destination_disposition` is exactly `absent`, `complete_unverified`,
`committed_match`, or `other`. Destination identity is non-null exactly for
`complete_unverified` and `committed_match`. When non-null it is the
`loopex.skill_publication/1` digest recomputed from the currently observed
destination using the same exact workspace-reference digest, destination label,
stable no-follow object token and file-set digest construction as
`publication_identity`. `committed_match` additionally requires equality with
the receipt's publication identity and the current committed `skill_import_v1`
generation; `complete_unverified` supplies no such provenance claim. `other`
covers an unreadable, partial, linked, special, over-bound or otherwise invalid
pack destination and therefore carries no identity. The closed relations are:

| Durable state and observation | Process | Destination | Receipt | Consequence |
| --- | --- | --- | --- | --- |
| `attempt_open` / `not_dispatched` | `not_started` | any truthful current disposition and matching identity nullability | nil | `next_attempt_permitted` |
| `attempt_open` / `in_flight` | `running` | any truthful current disposition and matching identity nullability | nil | `remain_open` |
| `attempt_open` / `terminal` | `not_started` for a before-effect refusal, `absent` for confirmed cleanup, or `indeterminate` for an indeterminate receipt | any truthful current destination disposition and matching identity nullability | complete retained receipt matching every operation, request, grant, workspace, executor and fence binding | `settle_terminal` |
| `attempt_open` / `indeterminate_evidence` | `absent` or `indeterminate` | any truthful current disposition and matching identity nullability | nil | `commit_outcome_unknown` |
| `terminal_quarantined` / `post_unknown_absent` | `absent` | any truthful current disposition and matching identity nullability | nil | `new_operation_permitted` |

Destination state does not prove whether this attempt dispatched because an
unrelated writer may race at any cut. `next_attempt_permitted` releases only the
attempt fence; the next hand still performs the ordinary existing-destination
refusal before any effect.

`not_dispatched` requires the matching `prepared` or `attached` acquisition
reservation and the current committed query proved by the authority observer.
Exactly two local cuts are legal: admission plus active authority with no open
or receipt atomically advances to generation-one `revoked/not_dispatched` plus
the response; or complete absence of admission, open, receipt and authority
atomically installs the generation-zero tombstone plus response. Both cuts prove
that the one-shot guard was never released. The atomic append wins against a
delayed admission or open transition under the same attempt lock; every other
partial relation is unavailable.
`in_flight` requires the current retained hand, open record and captured process-
group identity. `terminal` requires the complete retained receipt. An
`indeterminate_evidence` response means no valid terminal receipt establishes the
effect, even if the old process currently appears absent. To answer
`post_unknown_absent`, the current responder holds the attempt lock, verifies
one of the two exact retained generation-one `revoked/outcome_unknown` authority
forms, verifies the original hand identity in the direct form or prior responder
identity in the reconciliation-derived form against the same bound ledger root,
and independently verifies its current query/responder binding. It then proves
the exact captured process group absent and appends the exact retained response
without another authority generation. Because every later mutation and guard release
already requires active authority under that same lock, a paused original hand
task cannot resume an effect. Recovery may inspect and terminate the captured
process group while authority is revoked, but it cannot mutate staging,
provenance or destination bytes. Missing files, another ledger root or executor
identity/epoch, failed revocation, elapsed time, or a bare PID lookup cannot
establish any positive row.

Before sending a query, Runtime Control atomically commits its exact
`resource_acquisition_reconciliation_query_v1` record; only one query is current
for the operation. A replacement Control folds that query and re-drives it
whenever it remains unresolved and its expected responder binding is still
current. Repeated sends are permitted because the hand deduplicates the complete
identity and bytes below. Runtime Control accepts a response only when the query ID,
monotonically increasing recovery epoch, operation/attempt, both digests,
attempt workspace lease and executor identity/epoch, expected current responder
workspace lease and executor identity/epoch, recovery epoch and current fence all
match the current query and recovery route. The actual responder fields must
equal the query's expected responder fields. Any embedded receipt must match the
original attempt lease and executor identity/epoch rather than the responder's
current fields. The outer response therefore authenticates the current recovery
hand and the embedded receipt authenticates the original effect. The
canonical `response_digest` covers the complete response under kind
`loopex.resource_acquisition_reconciliation_response/1`; `receipt_digest` is nil
exactly when the response receipt is nil and otherwise uses the receipt digest
defined above. Runtime Control appends the exact result shape shown above.
Result ordinals are operation-wide, start at one, and increase only when a
reconciliation-result record commits; they never reset at an attempt boundary.
Each result carries its query's recovery epoch. Query IDs and response digests
are unique for the operation. The latest valid ordinal is the current
observation, and history is never rewritten. Every result is bounded to 64 KiB.

Before returning any response byte, including a nonterminal observation, the
local hand syncs this exact record, either alone or in the same atomic
local-ledger transaction as a required authority successor:

```text
local_resource_acquisition_reconciliation_v1
  kind, protocol_version, runtime_id, operation_id, attempt,
  reconciliation_query_id, recovery_epoch, query_digest, response_digest,
  query, response
```

The record key is `(runtime_id, operation_id, attempt, recovery_epoch,
reconciliation_query_id)`. The query digest is
`loopex.resource_acquisition_reconciliation_query/1` over the complete exact
query; the response digest is
`loopex.resource_acquisition_reconciliation_response/1` over the complete exact
response. Exact key and query-byte replay returns the retained byte-identical
response. Reusing the key with changed query bytes refuses
`reconciliation_query_conflict`. The hand retains the record until the matching
Store result is known committed and never evicts it while that transaction is
`commit_unknown`. Query and response are each at most 64 KiB; the complete local
record is at most 192 KiB and refuses before retention or return if it cannot fit.

For `settle_terminal` and `commit_outcome_unknown`, the result and matching
terminal record are members of one Store transaction. A transaction whose commit
is unknown is re-presented byte-for-byte; neither half can appear alone.
`not_dispatched` returns the same operation to `pending_policy`, where a new allow
creates the next attempt, grant and fence. `in_flight` leaves the attempt open.
An indeterminate hand receipt or response commits the operation's immutable
`outcome_unknown` terminal and retains process quarantine. A later exact
`post_unknown_absent` result releases only that process quarantine and permits a
new operator command. It does not delete staging, clear a prepared generation,
alter destination bytes, attach remote provenance, or change the unknown outcome.
Quarantined staging remains host-retained for explicit operator recovery outside
this protocol. If Control dies after the hand syncs a response but before the
result commits, restart re-drives the exact current query; the retained response
reconstructs the byte-identical result transaction and deterministic transaction
ID. If the responder binding changed, a newly committed next-epoch query
supersedes the old one, and a late response for the old epoch cannot commit.
A complete unverified destination may enter fresh discovery only
as local content after process quarantine is released; acquisition still refuses
that existing destination. Old unsolicited completions, duplicate responses and
stale epochs are refused.

While an operation is `terminal_quarantined`, discovery and admission refuse the
matching destination label with `resource_binding_changed`; bytes that a live or
unknown old process may still mutate cannot enter a snapshot. After exact
`post_unknown_absent`, the destination may participate in the complete fresh
discovery walk, but it is local/unverified unless every remote-provenance fact
below matches.

Rediscovery attaches remote identity only when the Store has a completed
`resource_acquisition_terminal_v1` under the generation's exact `runtime_id`,
its exact hand receipt matches operation,
attempt, request/grant digests, workspace, executor/epoch, fence, source/tree/pack/file-
set, destination and publication identity, the committed `skill_import_v1`
generation matches those same facts, the `evidence_attached` acquisition reservation and
reopened `resource_acquisition_evidence_v1` match that receipt, generation and
Store terminal, and current no-follow destination identity and complete bytes
recompute them. Any missing, prepared, unknown, old-epoch,
replaced or mismatched fact discards all remote-qualified fields and normalizes
the pack to `origin: "project"`, `source_id: "project:" <> name`, and null
commit/tree identity. Copying the installed directory, committing it, or moving
it to another workspace without matching hand retention intentionally has that
local/unverified result.

The host retains snapshot bytes, provenance and unresolved hand records under its
configured protected state root, separate from discovery and tool artifacts.
Retention policy may keep more history but may not evict an unresolved attempt;
a receipt needed by an uncommitted Store transaction; the matching attached
evidence package and hand receipt named by the current committed
`skill_import_v1` generation; that provenance generation itself; the evidence
package, hand receipt, Store terminal transaction/record, and provenance
generation named by any retained snapshot dependency row; or any
per-runtime snapshot bundle and binding intent named by a retained
`resource_snapshot_binding_v1` until that runtime root and its staged/admitted
uses are retired.
Retiring a provenance generation is the only operation that may
release its matched receipt retention, and it first proves that no current
generation, retained snapshot dependency, staged request, or admitted use names
it. Store-terminal and evidence-package compaction apply the same dependency
predicate. A reference-CLI administrative runtime may release its snapshot and
intent only after the exact synced retirement frame above; a direct embedder
uses the private retained retirement record above. A current provenance
generation can still keep its terminal/receipt
facts after that host-only runtime retirement. Staged and admitted uses may extend
retention beyond the binding lifetime. A
host unable to retain those facts refuses before effect. Existing content under
one digest must be byte-identical. Retention paths never become discovery roots.

### Trust, activation and admission

A decision binds `workspace_ref`, `manifest_digest`, the fixed
`project_skills` scope, issuance/source and active status. The manifest digest
transitively binds workspace repository origin/revision and every source-
qualified pack/file identity; M3 does not add a second per-source trust scope.
M3 follows existing non-expiring project decision semantics; removal/revocation
is an explicit new admission command, not a wall-clock guess. A catalog,
workspace, repository, provenance or byte change invalidates the whole manifest
decision. A missing or stale decision yields a bounded declined receipt and no
skill content, while ordinary coding continues.

Selection enters the fixed context stage, never an independent injection path.
The model sees catalog entries but cannot activate them. Only an explicit
operator/host command admits or selects resources while the session is settled.
Supporting requests name labels already in the admitted manifest; no model text,
link or script expands it. Each run freezes
an ordered set of at most four selected identities; duplicate selection is
idempotent, changed digest requires renewed trust, and a fifth selection
refuses rather than silently evicting another. Unselected instructions and
supporting files stay out of context. Resolve all requested content once and
stage its exact bytes/digests before provider intent commits.

Every staged resource block becomes exactly one provider message. `kind` is
exactly the ASCII string `catalog`, `instruction`, or `supporting`; no alias is
legal. Its content is this byte construction, with ASCII field names and LF separators, unpadded
RFC 4648 base64url for the three bounded UTF-8 labels, canonical nonnegative
decimal indices/counts, and no trailing bytes added after `body`:

```text
"LOOPEX_RESOURCE_BLOCK_V1\n" <>
"kind=" <> kind <> "\n" <>
"manifest=" <> manifest_digest <> "\n" <>
"pack=" <> pack_index <> "\n" <>
"file=" <> file_index <> "\n" <>
"source=" <> base64url(source_id) <> "\n" <>
"name=" <> base64url(skill_name) <> "\n" <>
"label=" <> base64url(file_label) <> "\n" <>
"bytes=" <> decimal_byte_size(body) <> "\n\n" <>
body
```

The complete provider message is exactly `%{"role" => "user", "content" =>
constructed_bytes}`. Instruction and supporting bodies are the exact selected
UTF-8 file bytes. The catalog uses sentinel indices `64/64`, empty source/name
labels, the literal label `catalog`, and a body beginning
`"# Available project skills\n"`. Each manifest-order entry then appends this
exact construction, with the description copied as exact UTF-8 bytes:

```text
"skill " <> pack_index <> "\n" <>
"name " <> name <> "\n" <>
"source " <> source_id <> "\n" <>
"digest " <> pack_digest <> "\n" <>
"manual-only " <> boolean <> "\n" <>
"description-bytes " <> decimal_byte_size(description) <> "\n" <>
description <> "\n"
```

The `boolean` field is exactly lowercase ASCII `true` or `false` with no numeric,
atom or capitalization alias. Decimal values have no sign or leading zero except
for the single byte `0`.

This constructor, including the envelope, defines
the provider-visible byte/token cost and descriptor `content_digest`; the
source-reference `file_digest` covers the raw file body or catalog body. A body
that resembles a header or delimiter stays inert untrusted content and cannot
alter the structured descriptor, source reference, tool set or admission order.

Admission first resolves and fixed-point measures required-only content under ADR
0017 step 5. Required-only failure performs no optional read, optional-inclusive
measurement or provider call. Only after that succeeds does it consider root
AGENTS.md, the catalog, selected instruction blocks and requested supporting
blocks in that fixed order, with selections in durable command order. Each
optional block is admitted whole if the resulting complete request and receipt
fit the resource-class byte/token, total-token, depth, cardinality and record-byte
limits; otherwise it withholds that block with the first reason in the exact order
below. Later blocks may still fit. Refusal preserves ADR 0017's existing
first-failure and `observed`/`record_byte_cost` meaning; no second lower-bound
field is added to historical receipts. Historical M2 refusal members retain their
meaning and bytes.

Propose `model_request_committed_resources_v1` as a distinct journal record
kind. Its model-request root members are unchanged, and its `context_receipt`
is exactly this seventeen-key revision-3 shape (durable maps use string keys):

```text
%{
  "provider_identity" => "loopex.context.reference",
  "provider_revision" => 3,
  "transformer_identity" => nil,
  "transformer_revision" => nil,
  "selector_identity" => nil,
  "selector_revision" => nil,
  "token_estimator" => "loopex.context_bytes.v1",
  "descriptor_canonicalization_version" => "loopex.canonical.v1",
  "blocks" => [ordered_context_descriptor],
  "totals" => %{
    "byte_cost" => nonnegative_uint64,
    "token_cost" => nonnegative_uint64,
    "by_provenance" => %{
      "system" => %{"byte_cost" => nonnegative_uint64,
                    "token_cost" => nonnegative_uint64},
      "session" => %{"byte_cost" => nonnegative_uint64,
                     "token_cost" => nonnegative_uint64},
      "project_resource" => %{"byte_cost" => nonnegative_uint64,
                              "token_cost" => nonnegative_uint64},
      "resource_pack" => %{"byte_cost" => nonnegative_uint64,
                           "token_cost" => nonnegative_uint64}
    }
  },
  "project_resource" => exact_project_resource_receipt,
  "resource_packs" => %{
    "version" => 1,
    "manifest_digest" => lowercase_sha256_hex,
    "selection_digest" => lowercase_sha256_hex,
    "status" => resource_header_status,
    "detail" => resource_header_detail,
    "blocks" => [
      %{"pack" => resource_pack_index,
        "file" => resource_file_index,
        "status" => resource_block_status,
        "detail" => resource_block_detail}
    ]
  },
  "context_token_budget" => positive_uint64,
  "provider_estimated_tokens" => nonnegative_uint64,
  "context_record_byte_ceiling" => 65_536,
  "record_byte_cost" => positive_uint64,
  "ordered_descriptor_digest" => lowercase_sha256_hex
}
```

Every displayed map admits exactly its displayed keys. The four
`by_provenance` buckets are the filtered byte/token sums of the same ordered
descriptor list and sum exactly to both outer totals.
`provider_estimated_tokens` equals the outer token total. The existing
`exact_project_resource_receipt` remains byte-for-byte ADR 0017 revision 2.
The new `resource_packs` member and its status sets are defined below.
Historical `model_request_committed` records continue to require ADR 0017's
exact sixteen-key revision-2 receipt and three-key provenance totals.

Header statuses are exactly `not_evaluated`, `evaluated`, `no_decision`,
`revoked`, `binding_changed`, `retained_content_missing`, and `metadata_budget`.
Block statuses are exactly `not_evaluated`, `staged`, `catalog_byte_limit`,
`resource_byte_limit`, `unsupported_text`, `resource_class_bytes`,
`context_tokens`, `context_record_depth`, `context_record_cardinality`, and
`context_record_bytes`. No integer alias or other value is admitted. The exact
header detail is `%{}` for every status except `metadata_budget`, whose detail is
`%{"dimension" => "context_record_bytes", "observed" => observed,
"limit" => 65_536}`. The exact block details are:

| Block status | Exact detail |
| --- | --- |
| `not_evaluated`, `staged` | `%{}` |
| `catalog_byte_limit` | `%{"dimension" => "block_bytes", "observed" => observed, "limit" => 16_384}` |
| `resource_byte_limit` | `%{"dimension" => "block_bytes", "observed" => observed, "limit" => 65_536}` for instructions or the same map with limit `16_384` for supporting content |
| `unsupported_text` | `%{"reason" => "invalid_utf8"}` |
| `resource_class_bytes` | `%{"dimension" => "resource_class_bytes", "observed" => observed, "limit" => 65_536}` |
| `context_tokens` | `%{"dimension" => "context_tokens", "observed" => observed, "limit" => context_token_budget}` |
| `context_record_depth` | `%{"dimension" => "context_record_depth", "observed" => observed, "limit" => 12}` |
| `context_record_cardinality` | `%{"dimension" => "context_record_cardinality", "observed" => observed, "limit" => 1_024}` |
| `context_record_bytes` | `%{"dimension" => "context_record_bytes", "observed" => observed, "limit" => 65_536}` |

Every `observed` is the first rejected nonnegative integer and is greater than
its matching limit. Its measured preimage is exact: `catalog_byte_limit` and
`resource_byte_limit` measure raw `body` bytes before the provider-message
envelope; `resource_class_bytes` measures the cumulative sum of
`byte_size(LoopexProtocol.Canonical.encode(provider_message))` for previously
staged resource blocks plus the candidate; `context_tokens` measures ADR 0017's
complete provider estimate after adding that candidate; and each record depth,
cardinality or byte observation measures the
complete normalized Store candidate containing that row through
`Store.normalize_and_measure_item/2`. Header `metadata_budget` measures the
fixed-point bytes of the exact-count maximal resource-member shell that failed
reservation. No display encoding,
descriptor projection or partial map substitutes for these preimages. Catalog
indices are `64/64`; normal indices are `0..63`. At
most 37 rows exist: catalog, four instructions, and 32 supporting files. The
complete member, including all detail maps, is at most 8 KiB; non-UTF-8 selected
text is unsupported. The internal `resource_class_tokens` check remains required
after the class-byte check and observes the matching cumulative sum of
`Bounds.estimate(LoopexProtocol.Canonical.encode(provider_message))`. Its
proven-unreachable result is never a legal
durable block status. Reaching it under this record version is corruption or an
unsupported implementation and refuses before request commit.

Header `evaluated` with empty detail carries one row for each candidate block in
the fixed catalog, instruction and supporting-file order. A `staged` row
contributes exactly one
matching `resource_pack` descriptor and provider message; every other row
contributes neither. The resource-pack provenance bucket is exactly the sum of
those staged descriptors. `no_decision`, `revoked`, `binding_changed`,
`retained_content_missing`, and `metadata_budget` carry empty rows and zero
resource-pack provenance cost and the exact header detail defined above.
`not_evaluated` header/block values exist only in
the non-durable lower-bound and maximal-reservation candidates; a successful
committed request cannot retain them. Unknown statuses or details, a detail that
does not match its status, duplicate rows, wrong order, mixed sentinel indices,
or a row/descriptor/message mismatch fail replay.

Required-only preflight first constructs and fixed-point measures both the
minimal fixed header with status `not_evaluated` and empty blocks and the exact
header-only `metadata_budget` fallback with empty blocks.
Use the durable admitted manifest digest, including its retained identity after
revocation. Without a prior successful resource admission, retain the M2 request
form even if a launch snapshot is configured; catalog inspection reports the
missing decision without versioning an otherwise ordinary request. The
selection digest binds a nil/revoked decision and empty selections when admission
has been disabled. A header with status `no_decision` denotes that explicit nil
decision.
These sizes are independent of optional contents and selection count: an
explicit new-format envelope cost that leaves M2 records unchanged. If the
fallback itself cannot fit, the existing required-only compact
`context_record_bytes` refusal is retained before any optional evaluation;
`metadata_budget` cannot describe that case.

The durable header disposition order after required-only success is exact. With
no prior successful resource admission, retain the M2 form. Otherwise evaluate:
explicit nil/no decision, decision/manifest/workspace binding mismatch, matching
revocation, missing or mismatched retained content, metadata reservation, then
`evaluated`. The first matching state fixes respectively `no_decision`,
`binding_changed`, `revoked`, `retained_content_missing`, `metadata_budget`, or
`evaluated`; later checks and all content reads are skipped. These observations
come from retained admission/selection identities, current decision and the
already validated runtime snapshot. Replay can validate every non-content state
from records alone; `retained_content_missing` is a live staging observation and
cannot be invented during record replay.

Before reading optional content, derive the exact ordered candidate identities
from the retained catalog and selections. The candidate count is therefore known
as an integer from zero through 37 without reading any body. Construct a
non-durable maximal resource member with exactly that many rows, not 37 rows
unconditionally. Each row uses the byte-largest legal status/detail encoding and
the largest legal index pair, and the complete candidate uses fixed-point Store
measurement. If that exact-count reservation cannot fit, fix the resource class
at `metadata_budget` with empty rows, then evaluate root AGENTS.md while reserving
the already proved fallback. The resource-free request may still dispatch. If it
fits, evaluate root AGENTS.md while reserving that exact shell; a root candidate
that would consume the reservation is withheld by ADR 0017's existing record-byte
disposition. Only after the root disposition is fixed may resource bodies be
read.

For each catalog, instruction and supporting block, first failure order is exact:
the block's declared intake byte ceiling (`catalog_byte_limit` for the catalog,
otherwise `resource_byte_limit`); UTF-8/text validity; the cumulative 65,536-byte
resource-class ceiling; the derived 21,870-token class assertion; the run's total
context-token budget; record depth; record cardinality; then exact fixed-point
record bytes. A staged block passes every earlier check. A withheld block does not
consume class totals, and later blocks may still fit. The class-token guard is
proved unreachable while the preceding class-byte invariant and M3 estimator/
cardinality remain unchanged; if it becomes reachable, request construction
fails unavailable before commit rather than emitting a durable disposition or
reordering the checks.

The separate 8 KiB resource-member ceiling is a format invariant checked
independently for every valid member and for the maximal reservation. Exceeding
it, or structurally failing the bounded reservation, is an invalid
implementation/candidate and cannot be reported as `metadata_budget`.

This re-proves ADR 0017 step 5 for the larger exact shape before optional content
is evaluated. The maximum remains one fixed header plus 37 disposition rows, 38
structural items total, while an actual request reserves only its exact candidate
count. Generated evidence covers every row count from zero through 37, every
legal status family, index extreme and resulting ordered descriptor cardinality
through 1,024, with the final descriptor list never exceeding 1,024. Exact-
boundary cases put the fallback and each exact-count shell at the record ceiling
and one byte over. A fallback failure performs zero resource reads and provider
calls; a shell-only failure performs zero resource reads and may dispatch the
resource-free request after root disposition. Every legal member stays at or
below 8 KiB, including its largest legal detail maps. This proves required-only
admissibility using the exact-count maximal
receipt shape and lower-bound candidate rather than ADR 0017's one-optional-block
implication. Structural boundaries, class arithmetic and the 64-pack/four-
selection maximum remain mandatory implementation and closure proof.

For `model_request_committed_resources_v1` only, `source_reference` admits ADR
0017's existing variants plus exactly this variant and no other:

```text
%{
  "kind" => "resource_pack",
  "manifest_digest" => lowercase_sha256_hex,
  "pack" => resource_pack_index,
  "file" => resource_file_index,
  "file_digest" => lowercase_sha256_hex
}
```

The only admitted index pairs are `{64, 64}` for the catalog sentinel and
`{pack, file}` with both values in `0..63` for an ordinary manifested file.
Mixed sentinel/ordinary pairs refuse. For `{64, 64}`, `file_digest` is
`Canonical.digest_bytes/1` over the exact catalog body defined above. For an
ordinary pair it is the selected manifest file's digest. Descriptor
`content_digest`, byte cost and token cost cover the complete constructed
provider message, matching ADR 0017's provider-visible preimage rule.

Every descriptor keeps ADR 0017's exact six keys, with this
record-kind-specific provenance extension:

```text
%{
  "source_reference" => source_reference_v3,
  "provenance_class" =>
    "system" | "session" | "project_resource" | "resource_pack",
  "trust_class" =>
    "host_owned_trusted_brain_content" |
    "session_owned_durable_truth" |
    "untrusted_behavior_shaping_data",
  "content_digest" => lowercase_sha256_hex,
  "byte_cost" => nonnegative_uint64,
  "token_cost" => nonnegative_uint64
}
```

A `resource_pack` source reference requires
`provenance_class: "resource_pack"` and
`trust_class: "untrusted_behavior_shaping_data"`, and that provenance class
requires this source-reference variant. Root AGENTS.md retains
`provenance_class: "project_resource"` and ADR 0017's exact
`project_resource` source reference. No cross-pairing is admitted. Neither the
file digest nor content digest includes its descriptor or receipt.
The request/attempt-open atomic pairing stays unchanged; no third request record
or new provider-attempt transaction is proposed. Sessions that never use resource
commands keep the existing M2 record forms.

Recovery uses the retained staged request, not today's files or network.
Unstaged later requests resolve only the run's admitted immutable snapshot.
Missing retained content declines that class with status
`retained_content_missing`, rather than
substituting new bytes or stopping ordinary coding. Exact
request identity does not authorize provider redispatch: ADR 0018's only
not_dispatched retry and ambiguous-attempt rules continue unchanged.

### Evidence and alternatives

Drive real Runtime Control and Local Store command, intent, policy denial,
attempt, reconciliation and terminal transactions through every declared Store
fault point and `commit_unknown` recovery. Mutation-test every request/grant/
original-attempt lease/executor epoch, current-responder lease/executor epoch and
fence binding independently. Submit two legal bundles from competing Controls at
one acquisition version and prove exactly one commits. Kill Control after a hand
response sync and before result commit, then reconstruct the byte-identical
result and transaction ID after restart; repeat with an unknown result commit,
a responder-epoch replacement, and a late old-epoch response. Prove query/result
transactions never advance attempt or fence. Exercise every normalized ADR 0009
allow, five-category deny, invalid/failed callback, defer and absent-policy row.
The prior read-only `prepared/3` and `capabilities/1` observations may occur;
prove zero `prepare/2`, grant, Store attempt, `acquire/3`, `reconcile/2`, process,
network or filesystem effect on every non-allow. Prove canonical command replay
and conflict, same-operation next-attempt authority only after retained
`not_dispatched`, terminal-commit ambiguity, append-only reconciliation ordinals,
immutable unknown, the complete closed terminal/status/reconciliation relations,
post-unknown process-absence release without cleanup, and refusal of unsolicited
or stale completion.
Exercise `prepare/2`, `prepared/3` and `release_preparation/2` at every write,
sync, reopen, reply-loss, Store submission and Store-result cut. Prove that the
combined reservation exists before every Store attempt, embeds the exact
transaction, reserves both attempt and evidence ceilings atomically, re-presents
only those bytes after restart, and releases a noncommitted transaction only
from the exact observer proof. Exhaust each independent ceiling, corrupt every
state/proof relation, interrupt every reservation generation and race delayed
admission against the current-query tombstone. No failure may create an
off-budget ledger record, second policy/grant, uncharged effect, hidden capacity
release or cross-attempt cleanup.

Drive the real local acquisition hand over a credential-free loopback HTTPS Git
fixture. Prove source grammar, disabled ambient credentials/configuration/
redirects/helpers, partial raw-object fetch, every network/object/staging/file/
process/output boundary, exact-authority loopback CONNECT confinement and cutoff,
and confirmed process-group cleanup. Kill the hand at
child creation, open-record sync, guard release and every later phase; before the
synced open record Git never execs, and after release the exact process/staging
identity is reconcilable. Refuse a mismatched destination name, commit/tree,
truncated object set, links/gitlinks/special files, unsupported metadata and every
limit without executing downloaded content. Exercise first installation with
both fixed parents absent, every parent-creation race and sync cut, and a staged
attempt outside the discovery directory; links and special objects at every
fixed label refuse, while only exact attempt-owned staging is cleaned.
Race every executable path component and alias by rename, replacement and
in-place rewrite after startup observation, after policy allow and at the final
guard boundary. Substitute the Port-helper path before and during spawn, and
force wrong or unverifiable main-Git, HTTPS-helper and index-pack images. Prove
zero guard release for every pre-start mismatch, exact post-release termination
and receipt classification, permanent same-epoch graph invalidation, no
pathname-only fallback, and recovery only through a fresh executor epoch and
freshly probed graph.

Exercise every file sync, prepared provenance, no-replace rename, parent sync,
destination verification, committed provenance, retained receipt and Store
terminal cut. Existing and racing destinations remain byte-identical. Every cut
leaves attempt-owned destination writes absent or complete; unrelated racing
writes may leave other bytes and are preserved without attempt attribution.
Prepared-only publication is local, and only matching committed hand plus Store
truth restores remote provenance. Copy/move/repository-only provenance degrades
to local. Lose the CLI acceptance reply, recover through the retained local
handle without a second Git effect, prove the live administrative runtime keeps
its old immutable snapshot and a restart selects mode from fresh attestation,
and prove a different fresh runtime performs rediscovery and new trust before
using the imported skill. Retain an attended public HTTPS
import separately.

For trust and staging, test the complete paginated pre-admission display and
final-page/digest confirmation, actual staged model bytes, progressive loading,
manual-only selection, `SKILL.md` supporting-label refusal, every exact-count
metadata reservation, header and block first-failure order, class-budget
arithmetic/unreachability, exact block framing and receipt detail relations,
revoked/stale identity, both hosts, directory/frontmatter name equality, in-place
selection replacement, and fresh-process complete-directory recovery. A
credential-bearing or noncanonical raw workspace remote must become nil before
manifest, digest, display, or retention; a nonnil invalid core value refuses. A
hostile-pack witness carries
`allowed-tools: Bash(*)`, hooks and a script, then compares canonical tool
registry bytes, the host-policy result and grants for an identical ordinary tool
request, plus administrative acquisition state, before and after activation. All
are unchanged and no executor intent arises from activation. Also refuse model-
originated acquisition/selection and mid-run mutation.
In one configured runtime supporting both paths, capture ordinary behavior before
and after acquisition/admission and require byte- and member-identical ADR 0007
ordinary `JobRequest`, ten-binding grant, accepted/started/progress/terminal
events, receipt, reconciliation query/response/result and conformance-oracle
result, plus ADR 0009's ordinary tool-policy request, normalized decision and
context. No acquisition tag or member may enter an ordinary form, and no ordinary
session identity may enter an acquisition form.
The residency witness deterministically inspects ownership rather than heap size:
one runtime creates or matches its durable snapshot binding before children and
owns one complete normalized snapshot for one workspace/manifest;
multiple sessions add no complete snapshot holder and retain only identities
until their own request stages exact bytes; a second workspace refuses without
replacing or duplicating the first snapshot; shutdown removes the core holder
while host retention remains; and restart rehydrates one snapshot only after
rewalking and reattesting the complete current project source and matching the
immutable Store binding. Prove deterministic binding-transaction recovery,
first-placement serialization, nonnil-to-nil refusal, and genuine unbound M2
resource-disabled restart. A changed or unavailable current attestation opens
only recovery mode, refuses every new resource/run authority with zero boundary
calls, and settles already staged bytes; ordinary use requires a new runtime
identity. A
"copy" means a complete canonical snapshot
held in product-owned state, independent of BEAM binary-sharing details.
Use a tiny gate-owned fixture plus a license-reviewed public example; do not
copy external code or scripts into Loopex without the ordinary reuse decision.

Deferring skills until VM-global extensions is unnecessary: their resource
contract is data-only in the code-loading sense. Building a generic context
pipeline now adds unproved plugin ownership. Treating every vendor field as
executable imports foreign authority. This fixed class is the bounded alternative.

<a id="technical-adr-0025-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0025-resource-packs-and-skill-admission.md#concept-adr-0025-consequences).

For resource acquisition only, ADR 0025 supersedes ADR 0009's tool-call-only
policy-request member set with the one tagged runtime-control variant above. It
does not change the callback, existing request form, decision context, denial
algebra, ordinary grant or tool/effect records. Unknown variants fail closed.
For the same narrow variant it supersedes ADR 0007's universal session
`JobRequest`; job/session/run/turn/tool-call/session-origin identities; tool-ID/
tool-version grant bindings; executor accepted/started/progress event sequence;
session-origin terminal-receipt tuple; session/coordinator-epoch reconciliation;
and the matching universal wording in Concept vision section 15 and Technical
vision sections 6.3, 8.4, 9.3, 9.4, 15.1, 17.1 and 23.3. Section 17.1's
hand-package rule is superseded only for this tagged Runtime Control
acquisition hand; every ordinary session hand remains behind the existing
session `JobRequest` boundary. Session epoch/origin remains mandatory for every
session-owned effect. The runtime-control replacements are runtime/command/operation/attempt
identity, separately bound original-effect and current-responder epochs,
receipt-only completion, bounded status and Runtime Control reconciliation. The
new administrative grant is a separate operation-kind encoding with the same
host-policy authority and final pre-start validation principles; it does not
reinterpret ADR 0007's exact session `JobRequest`, grant, event, receipt,
reconciliation or conformance oracle and changes no existing session behavior.

Resource supersession is limited to ADR 0010's root-only label/class/cardinality,
no-recursion/no-globbing, and session-start-only timing rules for the new skills
class. For `model_request_committed_resources_v1` only, it is further limited
to ADR 0017's exact source-reference variant set, descriptor
`provenance_class` set, three-key `totals.by_provenance` map,
`provider_revision: 2`, sixteen-key successful-receipt shape, and
zero-or-one optional-block step-5 implication. The replacements are exactly the
single `resource_pack` source-reference variant, provenance value and totals
bucket, provider revision 3, seventeen-key receipt with `resource_packs`, and
the multi-block proof above. ADR 0017's `project_resource` receipt and
whole-class semantics remain unchanged for root AGENTS.md, while resource-pack
refusal withholds one complete block and may continue to later blocks.
Validation remains record-kind-specific: `model_request_committed` accepts only
the historical revision-2 schema, and `model_request_committed_resources_v1`
accepts only the revision-3 schema. The ADR 0010
discovery exception permits only one bounded, content-independent recursive walk
below an already selected `.agents/skills/<name>/` directory. Runtime, operator,
user, metadata and pack content supply no glob or match pattern. The exception
permits no additional root, parent escape, symbolic or hard link, special file,
workspace-history lookup, configured path, or filename/pattern/import supplied by
pack content. Root AGENTS discovery, core's no-path boundary and whole-manifest
trust remain unchanged.

Add experimental facade queries and pre-run command variants under the session
owner, one Runtime Control acquisition transaction family, one immutable
pre-child snapshot-binding transaction family, one bounded reference-host CLI
recovery journal and one optional administrative hand port. Existing
`Loopex.Executor.JobRequest`, executor callback,
tool definitions, ordinary grants, session identities and tool receipts remain
byte- and meaning-unchanged. Existing custom executors remain conformant. A host
without the acquisition hand or explicit policy reports that one capability
unavailable while ordinary sessions continue.

New readers must replay genuine M2 histories unchanged. The M2 closed
record-kind allowlist makes a session containing any `resource_command_v1`
unopenable by the M2 binary before effects, including a session whose only
resource command has a refused disposition. A committed
`model_request_committed_resources_v1` is likewise a distinct unknown kind.
Sessions that contain no resource command retain M2-compatible journal forms.
An omitted resource binding keeps a new core-only start and a genuine M2 runtime
in that old form. A non-nil resource-binding envelope commits
`resource_snapshot_binding_v1` before children, so an M2 binary cannot safely
open that Store root even if no acquisition or session resource command follows.
M2 likewise refuses Store acquisition records when it parses that Store root.
The separate M3 CLI journal, reservations, snapshot retention, and hand ledger
are host-private sibling state that M2 never opens; they are invisible and
non-authorizing to M2 and cannot serve as its refusal evidence. An existing unbound M2 runtime can continue in
`legacy_no_resources` mode, but it cannot be upgraded in place to resources.
Rollback restores a retained M2 Store/hand root and matching binary; it never
points M2 at a resource-enabled M3 root, rewrites M3 state or promises an in-
place downgrade. Rollback also restores matching old host state and routing; it
never relies on an M2 process to detect M3-private sibling files. M2 ignores
installed project skill directories, which confer no authority by themselves.
Existing admitted AGENTS.md behavior and provider redispatch restrictions
remain intact.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M3 gate's required paths execute.
