<a id="concept"></a>
## Concept

Technical depth: [Physical restore contracts and
proof](0051-current-format-physical-restore-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-05
- **Decision owner:** Maintainer
- **Supersedes:** 0016, only its absence of an authorized physical restore transition for a complete current-format latest quiescent backup. Ordinary Local generation binding, copied-root refusal, effect uncertainty and configured job cleanup remain unchanged.
- **Constrained by:** [ADR 0016](0016-configured-cancellation-observation.md#concept), [ADR 0049](0049-explicit-host-configuration.md#concept) and [M7 current-format recovery](../plans/M7-technical.md#technical-depth).

<a id="concept-adr-0051-context"></a>
### Purpose and amendment

Technical depth: [Constraints and source
evidence](0051-current-format-physical-restore-technical.md#technical-adr-0051-context).

Recover a complete latest quiescent state backup into an empty root while the original
workspace remains available at its retained physical identity. The maintainer selected
this direction, including recovery after loss of the original state directory. That
choice does not accept this pair's API, persistent records, trust assertions or limits.
They are proposed here as one review unit. ADR 0016 remains accepted as recorded until
this successor is explicitly accepted; its historical bytes are not rewritten.

Restore all current session, runtime-control, artifact, executor-receipt, private
continuation/recovery, catalog and host-ledger state. Keep original effect and
reconciliation tuples and bytes. Create fresh physical Local ledger generations only
through this offline transition. An ordinary copied/moved root continues to refuse
activation. State restore does not undo workspace effects; workspace contents are
held/restored separately at the same directory identity.

Another-host recovery, a lost/recreated workspace, arbitrary historical snapshot rewind,
malicious-host isolation and automatic removal of uncertain effects are outside this
decision. A backup hash proves its bytes, not latestness or the end of competing
authority. No Runtime command, executor effect envelope, backup CLI, generic migration
engine or vision change is added.

<a id="concept-adr-0051-boundary"></a>
### Host administrative boundary

Technical depth: [Signatures and closed
inputs](0051-current-format-physical-restore-technical.md#technical-adr-0051-boundary).

Propose host-only `LoopexComposition.Restore.restore(plan, invocation)` and
`lookup(destination_state_root, tx_id, limits)`. Restore owns offline copying, audit,
source retirement and destination generation installation. It returns a bounded
committed receipt, a joined pre-intent refusal, pre-intent unconfirmed cleanup, or
post-intent commit uncertainty. Lookup reads checked retained facts and returns
current/historical completion, a pending observation, present absence or bounded error.
Neither method returns live authority or dispatches an effect. Invocation work, cleanup
and byte limits are explicit, with no new product default or changed effect deadline.

Accept the companion's closed string-key, deterministic uncompressed ETF schemas and
fixed trusted return tags as a new cross-application administrative contract. Plan
identity includes the complete authored cut/placement/attestation; a retry changes only
invocation limits after prior administrative authority is positively terminated. The
same transaction with changed plan bytes conflicts. No input atoms, process handles,
credential values or implementation terms enter the persistent contract or public
evidence planes.

<a id="concept-adr-0051-placement"></a>
### Eligibility, identity and complete-copy profile

Technical depth: [Physical preimages and unexcluded
manifests](0051-current-format-physical-restore-technical.md#technical-adr-0051-placement).

The host stops and positively joins old Runtime, Store, Local, guard, lease,
worker-group, child-manager and placement authority, excludes competing copies and
preserves the physical workspace. Available source must match the retained latest
complete cut and physical identity. It is durably retired before fresh destination
authority is installed. Lost source must be positively absent; unavailable or
permission-denied does not mean lost.

Accept a new trusted-host attestation of latest cut, no post-cut activity, old-authority
termination, all other copies excluded and host-ledger validation, with retained
evidence. Host reboot can establish termination when required by ADR 0016, but cannot
establish effect outcome. For a lost source there is no original-root tombstone. The
attestation supplies exclusion/freshness that this operation cannot prove mechanically;
an external nonrollbackable fence is the stronger alternative below.

Accept the companion's distinct state-root path/device/inode binding and the existing
Local ledger binding. Preserve every baseline kind, mode, relative path and file
byte/hash without exclusions, including all prior restore metadata. Audit complete
current Store/Local/receipt/artifact/host-ledger history. Torn, malformed, missing or
oversized input refuses. Preserve root/directory/file modes; new administrative
directories are 0700 and files are 0600. This profile refuses symlinks, special nodes,
imported regular files with nlink other than 1, and non-UTF-8/NUL or unsafe paths.
Paths/roots are nonnested and independent. Ownership, ACLs and xattrs are outside the
mode/bytes proof; host protection of private state remains required.

The following new bounds are part of the proposed decision. Individual existing
Store/Local codec limits remain in force too; no partial inventory can pass.

| Proposed item | Bound |
| --- | --- |
| Complete manifest |4 MiB encoded, 65536 entries; total regular bytes within required caller uint64 cap |
| Plan / compiled intent / each nonmanifest root or ledger record |65536 encoded bytes each, measured independently before first intent publication |
| Invocation / claim / receipt / observation / refusal / lookup refusal |2048 encoded bytes each |
| Lookup limits |512 encoded bytes |
| Runtime IDs / Store descriptors / ledger descriptors |256 /1024 /128 items, sorted and unique |
| Absolute/relative paths and executor IDs |8192 UTF-8 bytes each; runtime IDs 256 bytes; current WorkspaceIdentity codec |
| Work and cleanup grace durations |Positive uint64 milliseconds; checked arithmetic and representable monotonic conversion |
| Complete restore lineage |64 completed transitions; transition 65 refuses before mutation, with no pruning |

<a id="concept-adr-0051-lineage"></a>
### Repeatable provenance

Technical depth: [Append-only root and ledger
records](0051-current-format-physical-restore-technical.md#technical-adr-0051-lineage).

A restored current root can be backed up and restored again within the proposed bounds.
Append one numbered private root transition and corresponding per-ledger records. Copy
all earlier current-format records and modes unchanged; validate their complete chain.
The available source's per-ledger retirement records also remain at destination as
historical source evidence, so later backup/lookup can check them after the old root is
lost. Earlier source or destination generation evidence does not authorize that old
placement.

Accept the exact reserved paths, canonical digest domains, source/destination record
roles and current codec in the companion. Missing, malformed, conflicting or partial
higher-ordinal metadata fences ordinary opens; it cannot fall back to an earlier
committed head. Fresh candidate bytes are generated once and retained in intent.
Original-transaction resolution reuses them. The 64-transition limit is a new
retention/persistence decision; reaching it refuses without pruning, metadata exclusions
or superseded-format compatibility.

Complete baseline comparison precedes the authority transformation. Thereafter only
exact append-only administrative records and named Local generation bytes may change,
with original generation mode preserved. Activation and final manifests account for
every proof addition without self-hashing a commit record. Ordinary evolved
session/Store data need not equal an earlier activation cut; historical verification
reconstructs only that retained administrative image.

<a id="concept-adr-0051-lifetime"></a>
### Administrative ownership and cleanup

Technical depth: [Claims, direct IO and captured
cutoffs](0051-current-format-physical-restore-technical.md#technical-adr-0051-lifetime).

Accept private external path-bound administrative claims for available source and
destination, with exclusive 0700/0600 publication, exact transaction/plan identity and
no age-based reclaim. A monitored guardian owns serial direct raw file IO; shared
file-server work and detached copy/hash actors cannot stand in for owned IO.
Source/backup/workspace/destination stay under host exclusion. Every descriptor
operation/close and exact worker termination must be proved; worker DOWN alone does not
prove an in-flight file resource closed. Forced killing, a missing acknowledgement or an
unjoined actor leaves cleanup uncertain. No acknowledgement/activation follows unknown
file or parent fsync.

Capture one work cutoff. Normal payload completion is a first stop reason for new
payload IO, alongside refusal, cancellation, caller loss and deadline. Capture exactly
one cleanup cutoff on that first reason. Cooperative cleanup uses the explicit grace;
final observation uses max 10000 ms or grace+2000 ms, whichever is larger. Exact joins
and the terminal claim-release worker share that cutoff without refreshing it.
Pre-intent unconfirmed cleanup returns its own bounded uncertainty; possible intent
persistence always returns commit_unknown. Claims and host exclusion remain until the
original identity is resolved and previous admin/file authority is joined or covered by
the accepted reboot assertion.

Composition structurally checks its known state-root claim before mutable startup. A
standalone Local instance cannot discover an arbitrary enclosing state-root claim before
per-ledger restore metadata exists. Direct trusted Local opens therefore require host
exclusion during that interval. After metadata exists, suffix-checked enclosing-root
lookup and exact physical bindings govern Local prepare, prepared revalidation and claim
acquisition. Copied source-role retirement evidence at a committed destination does not
retire that destination. This is explicit host trust, not universal isolation from a
bypassing host.

<a id="concept-adr-0051-transition"></a>
### Retirement, unknown resolution and activation

Technical depth: [Ordered physical transition and
guards](0051-current-format-physical-restore-technical.md#technical-adr-0051-transition).

Publish destination intent before source retirement. An available source's root intent
fences composition, then per-ledger intent/retirement and final root retirement fence
that source before destination generations change. Lost-source retirement evidence names
the host attestation and never fabricates physical source proofs. Replace each
destination generation only against its exact imported or already-retained candidate
bytes, with real file sync/close, atomic rename, directory sync and readback. Publish
checked per-ledger proofs and final root commit before joined claim release and receipt.

There is no cross-root atomic commit. Safety follows source retirement or explicit
lost-source exclusion before destination activation. A failure can strand availability
but cannot make the old source safe to reopen. Re-present only the original transaction
after positively joining prior administrative and IO authority, recheck/re-sync its
exact phase and complete remaining work. Do not create a replacement epoch or refresh
any retained job deadline. Deletion or loss of sole intent/claim evidence after unknown
needs a further reviewed recovery decision; lookup absence does not clear that
uncertainty.

Preserve all original receipt, marker, open/claim, Store and public/private effect bytes
and tuples. Unknown outcomes remain fenced and are never redispatched. Confirmed
administrative cleanup does not confirm external-effect cleanup. Restore can truthfully
retain a quarantined Local root; it cannot discard that state to make activation appear
successful.

<a id="concept-adr-0051-outcomes"></a>
### Receipts and read-only lookup

Technical depth: [Closed outcomes, precedence and historical
checks](0051-current-format-physical-restore-technical.md#technical-adr-0051-outcomes).

Accept the companion's exact bounded receipt/refusal/observation/lookup grammar,
phase/reason vocabulary and refusal precedence. Receipts identify retained completion,
with no live authority or raw private paths. Current lookup requires complete physically
matching root/ledger proofs and no unfinished higher transition or admin claim.
Historical lookup returns the same retained receipt without inferring old-root liveness
or authority. A malformed dependency is an error, not a historical completion.

Lookup owns and joins bounded read IO but never syncs, writes, reclaims, continues or
activates. Pending observations cannot grant permission. Present absence cannot override
a previously observed unknown transaction, data loss or unproved prior administrative
cleanup. A retained claim still blocks activation even if a root commit record exists;
original-tx resolution must finish cleanup. Host exclusion persists after unknown
release even when deletion became visible.

<a id="concept-adr-0051-compatibility"></a>
### Alternatives, current compatibility and rollback

Technical depth: [Alternatives and amendment
mechanics](0051-current-format-physical-restore-technical.md#technical-adr-0051-compatibility).

Recommend this explicit offline host-owned profile. It implements the selected
empty-root direction with bounded current provenance and identifies the trust needed
after source loss. An external nonrollbackable exclusion/freshness registry would
provide stronger protection against stale cuts or simultaneous copied-root authority,
but adds an authority service, availability dependency and recovery contract. Keeping
ordinary Local binding alone avoids this new administrative contract but cannot deliver
the selected empty-root recovery outcome. A writable original-root-only transition also
cannot cover original-directory loss.

The amendment is additive to accepted ADR 0016. Its ordinary binding and copied root
refusal remain. Only the closed current restore codec is maintained before 1.0; there is
no older-root migration, compatibility decoder or generation-v2 upgrade. Rollback cannot
delete provenance, undo source retirement or reactivate an old root. Unproved shutdown
keeps the affected roots excluded; reactivating a retired source or losing transition
evidence requires another explicit authority decision. Removing an implementation with
retained restore metadata is not permission to run an old binary over it.

This proposal changes no accepted vision text or milestone status and authorizes no
publication. Its acceptance must bind this exact Proposed pair before dependent
implementation. The separate policy question and helper-accounting/mutation decisions
are not answered here.

<a id="concept-adr-0051-proof"></a>
### Required proof

Technical depth: [Physical conformance and evidence
limits](0051-current-format-physical-restore-technical.md#technical-adr-0051-proof).

Prove actual successive A→B→C current restores with available/lost-source combinations,
complete unexcluded modes/bytes manifests, unchanged earlier provenance, 64/65 refusal,
source/destination guards and fresh-candidate reuse. Exercise real file/parent fsync,
rename/readback faults and process-death cuts, including normal completion,
suspended/in-flight raw IO, exact descriptor/worker joins, pre-intent cleanup
uncertainty, post-intent unknown and claim release. Use both supported toolchain pairs
and preserve all failures; no fake IO, inflated bounds, retry-to-pass or error-report
suppression.

Actual settled/unknown Local receipt recovery must preserve original tuples and show
zero effect redispatch. Restore state independently of mutable workspace effects, then
restore workspace contents separately at the same physical identity. Current
Store/receipt/artifact/host-ledger audit remains required. Full helper-aware T 15 proof
waits for its current helper-ledger grammar; copying opaque state does not close it.
Source research, this draft and the unavailable independent review are not execution
evidence or approval.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
