<a id="technical-depth"></a>
## Technical depth

Concept: [Current-format physical
restore](0051-current-format-physical-restore.md#concept).

<a id="technical-adr-0051-context"></a>
### Constraints and source evidence

Concept: [Constraints and source
evidence](0051-current-format-physical-restore.md#concept-adr-0051-context).

This successor narrowly amends [ADR
0016](0016-configured-cancellation-observation.md#concept-adr-0016-decision)'s absence
of an authorized physical-restore transition. Its [ordinary Local generation codec and
binding](0016-configured-cancellation-observation-technical.md#technical-adr-0016-decision)
remain current. [M7](../plans/M7-technical.md#technical-depth) requires complete
current-format empty-root restore and separate workspace handling. [ADR
0049](0049-explicit-host-configuration.md#concept) constrains retained physical
workspace identity.

The current accepted constraints remain:

- ADR 0016 Concept 129–151 and Technical 239–275/329–350: ordinary whole-copy/move/refusal remains; old Runtime/Local/guard/workers/placement authority must be positively joined, or the host rebooted when termination is unconfirmed. No current cross-root registry exists. Its explicit no-migration clause needs a narrow amendment for this operation.
- `apps/loopex_executor_local/lib/ledger.ex:155–170,191–199,233–270,764–834`: prepare, physical binding, exact generation and claim revalidation. Generation is at most 2048 bytes. `:406–421` fixes 1024 open entries and4 MiB complete snapshot. `:1102–1159` shows actual file fsync/close→rename→directory fsync mechanics, but does not prove bounded ownership of a new administrative worker.
- `apps/loopex_store_local/lib/loopex/store/local/log.ex:26–29,77–95` and `state.ex:41–52`:4 MiB frames/256 MiB log, exact read-only frame decoding and pure semantic replay. An offline audit must not start a Store, truncate a torn cut or resolve a mutation as an incidental read.
- `apps/loopex_executor_local/lib/executor.ex:33,50–80,2007–2030,8234–8298,8401–8404`: closed current receipt≤65536, exact retained tuple, exact job-digest basename. Private physical generation and public executor epoch differ (`:1254,1328`; `apps/loopex_composition/lib/loopex_composition.ex:309–329`). Restore need not rewrite a public executor epoch/fence or a retained receipt. Current Core solicited recovery at `apps/loopex/lib/loopex/runtime/session_coordinator.ex:10367–10460` retains original tuples and validates the fresh query route.
- `apps/loopex_composition/lib/workspace_identity.ex:18–39`, `apps/loopex_cli/lib/loopex_cli/chat_configuration.ex:332–353`, ADR 0049 Technical 121–130: original physical workspace and retained pending references remain required.
- M7 Technical 2019–2025: stop owners/prevent access; copy all sessions/control/artifacts/receipts/private recovery/catalogs/host ledgers; restore empty root; compare complete manifests; separate workspace. There is no M8 backup command here. Current-format helper-ledger semantic coverage remains a prerequisite when those ledgers ship; opaque copying cannot close helper-aware T 15.

This Proposed pair records new decisions for the host administrative signatures, current
private lineage grammar/reserved paths, state-root binding domain, lost-source
attestations, finite lineage/manifest/path/count limits and modes, exact IO/cleanup
ownership, administrative claim reclaim, root/Local open guards, and
receipt/lookup/refusal vocabulary below. Module spelling and pure-validator extraction
are reversible implementation choices. This proposal adds no Core public mutation/query,
executor effect envelope, generic migration engine or backup CLI.

<a id="technical-adr-0051-boundary"></a>
### Administrative signatures and input grammar

Concept: [Administrative signatures and input
grammar](0051-current-format-physical-restore.md#concept-adr-0051-boundary).

Proposed host-only `LoopexComposition.Restore` signatures:

```elixir
restore(plan, invocation) ::
  {:committed, receipt}
  | {:not_committed, refusal}
  | {:cleanup_unconfirmed, observation}
  | {:commit_unknown, observation}

lookup(destination_state_root, tx_id, limits) ::
  {:committed, %{"receipt" => receipt, "view" => "current" | "historical"}}
  | {:pending, observation}
  | {:absent, %{"tx_id" => hex64, "observation" => "not_present"}}
  | {:error, lookup_refusal}
```

Only these fixed trusted return-tag atoms exist; all encoded data uses closed string-key
maps. Every input/persistent map is deterministic uncompressed ETF, decoded with safe
atom handling and exact re-encoding/key/type/whole-size checks. Reject
compressed/trailing/noncanonical input before semantics; no input atom creation,
functions, PIDs, ports, monitors, references or arbitrary terms. Existing generation
bytes keep their existing trusted fixed `ledger_kind` atom. No public evidence plane
receives these private maps.

Notation: `u64=0..2^64-1`, `positive_u64=1..2^64-1`, `hex64=exact64 lowercase ASCII
hex`, `ordinal=1..64`. Absolute paths are exact `Path.expand` UTF-8 bytes, 1..8192
bytes, without NUL; relative paths have the same byte bound and no
absolute/empty/dot/dotdot component, except the manifest root path exactly `"."`. No
Unicode normalization/realpath rewriting. Filesystem entries with undecodable UTF8 path
bytes refuse this proposed narrow profile. List bounds below and byte/path restrictions
are proposed values, not existing whole-state guarantees.

```text
placement = {"expanded_root": absolute_path, "major_device": u64, "inode": u64}
ledger_descriptor = {
 "relative_root": relative_path,
 "executor_identity": nonempty_UTF8_1..8192_bytes,
 "source_generation_sha256": hex64,
 "source_placement": placement
}
plan = {
 "version": 1, "tx_id": hex64,
 "source_state_root": absolute_path,
 "source_state_placement": placement,
 "source_status": "available" | "lost",
 "backup_state_root": absolute_path,
 "destination_state_root": absolute_path,
 "manifest_sha256": hex64, "cut_id": hex64,
 "prior_restore_count": 0..64, "prior_lineage_sha256": hex64,
 "runtime_ids": [nonempty_UTF8_1..256_bytes],
 "stores": [{"relative_path": relative_path, "sha256": hex64}],
 "ledgers": [ledger_descriptor],
 "workspace": {"root": absolute_path, "workspace_ref": current_workspace_ref},
 "host_attestation": {
   "latest_cut": true, "no_post_cut_activity": true,
   "all_other_copies_excluded": true,
   "old_authority_termination": "joined" | "host_rebooted",
   "host_ledgers_validated": true, "evidence_sha256": hex64
 }
}
invocation = {
 "work_ms": positive_u64, "cleanup_grace_ms": positive_u64,
 "max_total_file_bytes": u64,
 "prior_admin_authority": "none" | "joined" | "host_rebooted",
 "prior_admin_evidence_sha256": nil | hex64
}
limits = {"work_ms": positive_u64, "cleanup_grace_ms": positive_u64}
```

Plan≤65536 bytes, invocation≤2048, lookup limits≤512. Sorted unique runtime list≤256,
Store list≤1024 and ledger list≤128; every complete compiled record must fit too.
Stores/ledgers sorted by relative path; descriptors cover the entire current known state
placement, not merely a user-selected subset. Source-root string equals source placement
expanded_root; every source ledger placement expanded_root equals source root joined
with its relative_root. `prior_restore_count=64` refuses before any staging/claim
change. `prior_lineage_sha256` is checked as section4 specifies, including the exact
empty-lineage digest. Same tx/changed canonical plan conflicts; a fresh tx cannot
replace an unfinished original transition or consume the same old source generation
while excluded.

All source/backup/destination/workspace roots are distinct, pairwise nonnested, checked
directory/no-symlink through every component. `lost` requires original path positively
absent, not EACCES/unavailable/unknown; its original placement is a retained capture
fact checked against copied bindings. `available` reobserves source physical placement
and complete cut. Workspace reference is checked by the existing codec and
twice-observed physical identity; no replacement identity is minted. File aliases/hard
links between participating trees must be refused or the caller must prove independent
copy before mutation; propose refusing imported regular entries with nlink≠1, to avoid
destination generation/admin edits changing a shared source or backup inode. This is a
NEW profile restriction requiring acceptance.

`prior_admin_authority=none` requires prior_admin_evidence_sha 256=nil and no old
held/stranded administrative claim. `joined`/`host_rebooted` requires a nonnull evidence
digest covering every exact prior admin worker and IO resource, not just caller death.
Evidence is retained by the host outside participating roots. This attestation cannot
waive an unresolved effect-open entry or permit a replacement tx. Host attestation is
necessary in both source branches: no post-cut effects, competing roots or stale
snapshot activity can be inferred from a manifest. No copied authority is activated
automatically.

Plan digest: lowercase SHA-256 of `<<"loopex:current-restore-plan:v1",0,
canonical_plan_bytes>>`. Invocation/limits are excluded, so an eligible original-tx
administrative continuation may capture new admin limits after prior authority is
positively terminated. It never changes plan/cut/attestation/candidate bytes or extends
a retained effect/job deadline.

<a id="technical-adr-0051-placement"></a>
### Physical bindings and complete baseline

Concept: [Physical bindings and complete
baseline](0051-current-format-physical-restore.md#concept-adr-0051-placement).

A state-root binding has a distinct NEW domain; it must not reuse a Local ledger digest:

```text
SHA256_hex(<<"loopex:current-state-root-binding:v1",0,
 byte_size(expanded_state_root)::unsigned-64-big,
 expanded_state_root::binary,
 major_device::unsigned-64-big, inode::unsigned-64-big>>)
```

Use the exact expanded path and nonnegative uint64 device/inode from a checked physical
directory observation, matching the existing Local `File.stat(...,time: :posix)` fields.
Administrative no-symlink checks precede it. A state placement is the three-field map
above; its binding is always recomputed, never accepted as arbitrary caller truth.
Per-ledger binding and generation bytes use unchanged ADR 0016 preimage
`loopex:local-root-binding:v1` and its existing closed generation_v1 grammar. Fresh
private epoch is nonzero 256-bit, unequal to every prior retained source/destination
epoch for that ledger and all candidates in this transition. Generate once; original-tx
continuations reuse the exact bytes in intent. Public receipt/job epochs/fences stay
unchanged.

Complete manifest bytes are deterministic ETF:

```text
["loopex:current-state-manifest:v1", [entry,...]]
entry = {"path": relative_path_or_dot, "kind": "directory" | "regular",
         "mode": 0..4095, "size": u64, "sha256": nil | hex64}
```

Directory size 0/sha nil; regular exact length/sha including empty files. Include root,
hidden files, every empty directory and every private prior-restore file. Unique
bytewise sorted paths; no exclusions. Proposed full cap 4 MiB/65536 entries; total
regular bytes≤caller max_total_file_bytes using checked sums. Preserve imported
`lstat.mode &0o7777` exactly, including root and dirs. Ownership/ACL/xattrs are not
proved by this manifest; host placement/private-data protection remains its
responsibility. NEW admin directories 0700 and regular records/manifests/temp files
0600. Symlink/special/linked entries and unsupported paths refuse, not normalize.
Existing per-format ceilings remain: generation 2048, receipts/Local metadata 65536,
open index 1024/4 MiB, Store frame 4 MiB/log 256 MiB. Hash/copy≤65536-byte chunks is an
internal streaming choice.

Capture baseline externally before IO. Compare available source↔backup↔fully staged
destination for exact complete equality before authority changes; source-lost compares
backup to the retained capture manifest with latestness explicitly attested. Complete
Store tails/current pure reducers, Local generation/marker/open/refusal/receipt
relations, exact artifact references and every shipped host-ledger grammar must
validate. Do not start actors merely to audit, remove unknowns, repair a torn backup or
substitute truncated data.

<a id="technical-adr-0051-lineage"></a>
### Current root and per-ledger lineage

Concept: [Current root and per-ledger
lineage](0051-current-format-physical-restore.md#concept-adr-0051-lineage).

Paths use a fixed eight-digit decimal ordinal, not untrusted tx text. Root paths:

```text
.loopex-restore/lineage/000000NN/{baseline, intent, source-retirement, committed}
```

Available source appends the same ordinal's `intent` and `source-retirement`;
destination appends all four. Each imported ledger appends:

```text
restore-lineage/000000NN/{intent, source-retired}     (available source)
restore-lineage/000000NN/{intent, source-retired?, committed} (destination)
```

Destination source-retired is required exactly for the available-source branch, with
identical bytes copied from that source ledger. It is historical source-role evidence at
destination, not a destination retirement flag. Lost-source branch has no such
per-ledger file, matching nil retirement digests. Thus later complete backups retain the
actual canonical per-ledger retirement evidence even if the old source is subsequently
unavailable.

Root `baseline` is the exact canonical complete pretransition manifest≤4 MiB. All other
root/per-ledger records≤65536; claim≤2048. Only numbered1..64 paths and the exact named
files/directories are admitted. Missing/conflicting/noncanonical/partial/unknown
reserved entries are a fenced history error. Temp `*.tmp` paths belong solely to this
original transition and are absent at commit; a persisted intent temp counts as possible
intent, never as harmless absence.

A complete root has an unbroken root sequence1..n of committed current-format histories.
For next restore append n+1, retaining every earlier root/per-ledger file and mode
byte-for-byte. Per-ledger histories need only the ordinals when that ledger was
imported; new ledgers can legitimately first appear at a later ordinal. Every older root
proof's listed per-ledger records must remain present and hash-valid. Current
latest-covered generation at each present imported ledger must equal its last retained
candidate and the current physical binding; missing/changed referenced generations
refuse rather than recreate authority. This does not promise recovery after partial
deletion or arbitrary retention rewrites, already outside ADR 0016's guarantee.

Prior-lineage digest is SHA-256_hex of `<<"loopex:current-restore-lineage:v1",0,
canonical_entries>>`, where canonical_entries is the bytewise sorted list of
manifest-entry maps (section3) restricted **only for this digest** to all existing
`.loopex-restore` and `restore-lineage` directories/files. The complete baseline itself
is never filtered. At n=0 the list is exactly[] (no administration dir). The digest
binds kinds/modes/paths/bytes of all earlier evidence; validate every record and chain
before using the digest. Older physical placements are historical captured identities;
don't compare them to the new root or infer that those old roots remain live.

For record definitions below `common(kind)` means the exact fields
`{"kind":kind,"ordinal":ordinal,"tx_id":hex64}`; `proof_common(kind)` adds
`"intent_sha256":hex64`. These are closed field unions, not extensible base classes.
Every digest of a record is SHA-256 of its exact canonical bytes.

```text
intent = common("loopex_current_restore_intent_v1") + {
 "plan_digest": hex64, "plan": exact_plan,
 "prior_lineage_sha256": hex64,
 "source_state_binding": hex64,
 "destination_state_placement": placement,
 "destination_state_binding": hex64,
 "generations": [candidate]
}
candidate = {
 "relative_root": relative_path, "executor_identity": bounded_executor_id,
 "source_generation_bytes": binary_1..2048,
 "destination_generation_bytes": binary_1..2048,
 "source_ledger_binding": hex64,
 "destination_ledger_placement": placement,
 "destination_ledger_binding": hex64
}
ledger_intent = proof_common("loopex_current_restore_ledger_intent_v1") + {
 "relative_root": relative_path,
 "source_state_binding": hex64, "destination_state_binding": hex64,
 "source_generation_sha256": hex64, "destination_generation_sha256": hex64,
 "source_ledger_binding": hex64, "destination_ledger_binding": hex64
}
ledger_retired = proof_common("loopex_current_restore_ledger_retired_v1") + {
 "ledger_intent_sha256": hex64, "relative_root": relative_path,
 "source_state_binding": hex64, "source_ledger_binding": hex64,
 "source_generation_sha256": hex64,
 "destination_state_binding": hex64, "destination_generation_sha256": hex64
}
source_retirement = proof_common("loopex_current_restore_source_retirement_v1") + {
 "disposition": "source_retired" | "lost_source_host_excluded",
 "source_state_binding": hex64, "destination_state_binding": hex64,
 "host_evidence_sha256": hex64,
 "ledger_retirements": [{"relative_root": relative_path,
                         "record_sha256": hex64 | nil}]
}
ledger_committed = proof_common("loopex_current_restore_ledger_committed_v1") + {
 "relative_root": relative_path, "ledger_intent_sha256": hex64,
 "source_retirement_sha256": hex64,
 "destination_state_binding": hex64, "destination_ledger_binding": hex64,
 "destination_generation_sha256": hex64
}
committed = proof_common("loopex_current_restore_committed_v1") + {
 "plan_digest": hex64, "prior_lineage_sha256": hex64,
 "baseline_manifest_sha256": hex64, "activation_manifest_sha256": hex64,
 "source_retirement_sha256": hex64,
 "destination_state_binding": hex64,
 "ledger_proofs": [{"relative_root": relative_path, "record_sha256": hex64}]
}
```

Candidate/retirement/proof arrays exactly equal plan ledger coverage in sorted
order,≤128. Every extracted identity/digest/binding equals its referenced canonical
intent/candidate; source generation SHA equals descriptor. Source-retired disposition
requires one actual canonical ledger_retired digest per ledger, all physically at
source, then root retirement; lost-source disposition requires all record_sha 256=nil
and source_status=lost, never fabricated original-root files. Root source_retirement and
all available-source ledger_retired bytes are identical at source and destination.
Per-ledger intent is identical at both roots. Root/per-ledger retired facts refer to the
source role; candidate/committed facts to destination role. An available root with a
newer outgoing intent refuses ordinary opening even if its earlier history was committed
there.

Measure and validate the entire compiled intent, every per-ledger record, retirement and
final committed record **before the first intent write**, including temp. Individual
plan acceptance does not imply combined record acceptance. Failure refuses without
splitting fields across unbounded sidecars. Root committed cannot hash itself:
activation_manifest is the complete destination manifest after source-retirement and
candidate replacement but **before** all new per-ledger committed files and root
committed. Final complete external manifest then admits only those exact proof
additions. Baseline→activation permits only append-only current ordinal admin dirs/files
and exact listed generation-byte replacements (generation mode stays its original
baseline mode). All earlier provenance, receipts/markers/open/Store/artifacts/private
recovery/catalog/other host-ledger bytes and modes remain unchanged. No other
additions/deletions are allowed at commit.

<a id="technical-adr-0051-lifetime"></a>
### Claims, IO ownership and cutoffs

Concept: [Claims, IO ownership and
cutoffs](0051-current-format-physical-restore.md#concept-adr-0051-lifetime).

Do not acquire existing `Placement` inside state and exclude its new files from
equality: `placement.ex:583` places placement.lock inside the root and `:404` its guard.
Existing Local file writes (`ledger.ex:1125–1144`) create normal File IO servers.
Existing helpers' ordering can be reused; their actor ownership cannot be assumed for
this new bounded operation.

Propose a private temporary claim outside each participating live state root:
`Path.join(Path.dirname(expanded_state_root), ".loopex-restore-claim-" <>
claim_digest)`, with digest SHA-256_hex of
`<<"loopex:current-restore-claim:v1",0,byte_size(expanded_state_root)::u64-big,expanded_state_root::binary>>`.
Path, rather than inode, binds exclusion when a destination starts empty or is replaced.
Available source and destination claims are acquired in bytewise path order; lost source
uses destination claim plus explicit host exclusion. Backup/workspace are held read-only
under host access exclusion. Atomic mkdir 0700, owner 0600/file fsync/parent fsync
before IO. No age/TTL/absence-of-response reclaim.

```text
claim_owner = {
 "kind": "loopex_current_restore_claim_v1", "tx_id": hex64,
 "plan_digest": hex64, "claim_nonce": hex64,
 "state_root": absolute_path, "role": "source" | "destination"
}
```

Nonce is live invocation identity; original tx/plan stays fixed. No PID is persisted. An
unreadable or owner-less claim is stranded, not free. A new invocation can reclaim only
matching original tx/plan after exact prior administrative authority joins or trusted
host reboot/evidence; mismatched plans refuse. Composition structurally checks its known
state-root claims before mutable startup. Before per-ledger metadata exists, standalone
Local cannot discover an arbitrary enclosing state-root claim from its ledger path and
requires explicit host exclusion. After metadata exists, suffix-checked enclosing-root
lookup and exact physical binding govern Local prepare/revalidation/claim acquisition,
including the applicable root claim and outgoing/incomplete metadata. A direct trusted
host intentionally bypassing composition/Local guards remains outside malicious-host
isolation; runtime-only clients cannot call restore.

One monitored guardian owns one serial IO worker, installed/monitored before any IO;
monitor caller and cancel on caller loss. No asynchronous file-server operation,
detached hash/copy process or other unowned actor is admitted. Prefer a private direct
raw-IO implementation: `:prim_file` open/read/write/close/sync plus direct namespace
primitives make_dir/rename/delete/list_dir_all/read_link_info/write_file_info. Installed
pinned OTP 29.0.5 `prim_file.erl:130–160,286–302,608–650,804–826` and OTP 27.3.4
`:130–158,286–300,583,626–630,785–807` show these execute directly; public `file.erl`
rename/make_dir instead calls the shared file server (current 571–597; floor 567–593).
This is a source-backed candidate, not paired lifetime proof or a blanket promise that
killing a NIF has joined IO. No delayed_write/sendfile/server-backed convenience API in
this worker. Use raw descriptors, not transferable public handles.

Track each open/close and issued synchronous operation in the guardian's private
volatile inventory, using exact worker messages/monitor identity; all raw descriptor
opens and closes require acknowledgements before a clean result. Worker issues no next
operation after stop/cutoff; guardian never dispatches a new
generation/retirement/commit write after work cutoff. Direct raw IO is an internal
pinned-toolchain technique, not a new public capability. A hung/in-flight NIF, missing
open/close acknowledgement or forced-killed worker is cleanup-unconfirmed even when its
BEAM DOWN arrived. A DOWN alone never proves an unobserved resource closed. If raw IO
cannot demonstrate exact close/join under fault on both pairs, implementation stops at
that prerequisite; it must not quietly fall back to shared file-server IO or infer a
joined result.

At invocation admission capture monotonic `t0`; `work_cutoff=t0+work_ms`. Normal payload
completion is the first stop reason for further payload IO when no earlier refusal,
cancellation, caller loss or expiry occurred. On that first stop reason at
`s≤work_cutoff`, including normal completion, or exactly work_cutoff on expiry, capture
once:

```text
cooperative_cutoff = s + cleanup_grace_ms
cleanup_window_ms  = max(10000, cleanup_grace_ms + 2000)
cleanup_cutoff    = s + cleanup_window_ms
```

No refresh on messages/retries/each descriptor. These NEW admin cancellation values
explicitly reuse the existing executor observation formula
(`apps/loopex/lib/loopex/executor.ex:455–471`) without changing any job/receipt/provider
deadline. Sums must fit uint64 durations and monotonic conversion must be representable;
invalid limits refuse before IO. Signal cooperative stop immediately; at
cooperative_cutoff kill the exact still-live worker; collect its exact DOWN and all
required descriptor/IO completion acknowledgements until cleanup_cutoff. No
success/refusal is inferred from mailbox timeout, Process.alive? or caller exit.
Guardian work is serial and bounded; when child proof is incomplete at cleanup_cutoff
return uncertainty with claims retained, never a joined success. Caller monitors the
guardian and uses the captured work+cleanup bound; guardian death/no result preserves
the same uncertainty and host exclusion.

Normal completion first captures that same single terminal cleanup cutoff, stops issuing
payload IO, closes/acknowledges every descriptor, receives exact worker DOWN and joins
any tracked carrier before success. Normal completion does not obtain a fresh cutoff
when claim release begins. Claim release is a separate owned terminal IO worker allowed
only to remove/sync claim files/dirs, with no state/source-generation authority; monitor
before launch, exact descriptor closes/DOWN before receipt. It shares the same single
cleanup cutoff, never obtains a fresh one. Lost/late release/fsync/join leaves unknown;
no automatic open. A new guarded open is permitted only after the host receives
committed or resolves original-tx uncertainty and positively joins all admin authority.
Host access exclusion persists until then even if a claim deletion became visible before
its acknowledgement. This last rule is an explicit trusted-host precondition, not a
structural claim about hostile opens during unknown release.

Before any possible intent persistence, joined IO may produce not_committed. If a
partial/unactivated baseline remains, retain destination claim to fence it and return
claim=retained; only exact complete baseline plus proved absent intent may continue the
same tx. Incomplete baseline needs explicit disposable-root cleanup, not silent
overwrite. If neither state root changed nor intent can exist, release claims with the
same joined terminal worker. If any admin worker/resource is unjoined at cutoff, return
cleanup_unconfirmed even before intent. After an intent/temp may persist, return
commit_unknown regardless of whether cleanup joined. Claims stay until original identity
is resolved. No new admin invocation may resume under a live or unproved previous
guardian/IO worker; prior_admin assertion does not override contradictory live monitors.

<a id="technical-adr-0051-transition"></a>
### Ordered transition and open guards

Concept: [Ordered transition and open
guards](0051-current-format-physical-restore.md#concept-adr-0051-transition).

Stable phase enum: `"claim"`, `"inventory"`, `"baseline_copy"`, `"destination_intent"`,
`"source_retirement"`, `"destination_generations"`, `"destination_proofs"`,
`"claim_release"`, `"complete"`. These are bounded observations, not authority or
generic progress truth.

1. Positively join old Runtime/Store/Local/lease/guard/worker-group/child-manager/placement authority and all prior admin IO. Host excludes every copy/root and preserves workspace identity. Capture limits/monitor guardian; acquire exact external claims. Read prior lineage and full baseline; validate every shipped current ledger, Store, receipt/artifact relation and all bounds. Source-lost latest cut and exclusion remain attested. Unknown effects remain unknown.
2. Copy complete exact baseline, real file fsync/close and bottom-up directory fsync, preserve modes; re-enumerate unexcluded equality. No Local prepare on copied generations. Before publication compile all candidate/intent/proof bytes and enforce their whole caps; only then create current ordinal admin paths. A malformed higher ordinal always fences ordinary opens rather than falling back to an earlier head.
3. Persist destination baseline manifest then exact root intent via owned 0600 exclusive temp→file fsync/close→atomic rename→dir fsync→exact readback. Existing equal bytes are read/re-synced; changed/conflicting bytes refuse. Before the first temp intent IO the guardian marks intent-may-persist. Original tx/nonce/plan claim binds continuation even if visible intent is malformed or missing; inability to recover its complete canonical candidate leaves unknown, not permission to invent another epoch.
4. Available source: while held, recheck complete cut and original physical generation bytes. Append root intent first to fence all source composition opens, then each source ledger intent/retired record, then root source_retirement; each write/sync/readback and exact source-role binding is required. Copy that exact root retirement evidence and every canonical source ledger_retired record to destination and sync/read back them; later lookup verifies their actual retained bytes against all listed hashes. Lost source: persist source_retirement with lost_source_host_excluded and nil per-ledger retirement digests; no nonexistent source tombstone. Only complete retirement/exclusion evidence permits candidate replacement.
5. Publish destination ledger intent. For each generation compare exact imported original bytes or exact already-retained candidate, never unconditionally replace changed bytes. Candidate temp is original-ordinal-bound; file fsync/close→rename→ledger-directory fsync→readback. Preserve baseline mode. Retry re-synces the same bytes and binding. Original receipt/marker/open/effect claim/Store data remains untouched; deletion is no remedy for quarantine.
6. Reaudit exact allowed baseline transformation and capture full activation manifest outside root. Publish all canonical per-ledger committed records, then root committed, each fully synced/read back; validate complete physical bindings and hashes. Root committed is final payload publication. Copy source/backup remains excluded; no live authority is returned. Join IO, release claims with bounded joined terminal IO, then return retained receipt. A committed record present with unresolved claim/admin cleanup remains pending for ordinary activation until original-tx resolution finishes cleanup.
7. Ordinary composition opening checks the exact current highest root transition. Current committed destination matches physical state binding; a newer outgoing intent/retirement refuses source_retired, a higher incomplete/malformed transition refuses restore_incomplete/history_invalid. Local imported ledger opening additionally checks its last covered candidate, matching ledger proof and root proof; standalone per-ledger proof does not bypass unfinished root commit. Per-ledger source-role intent/retired blocks previously prepared authority as well as fresh prepare/revalidate/claims; copied source-retired evidence at a physically bound committed destination does not retire that destination. Missing expected generation cannot mint fresh authority. An ordinary root with no restore metadata keeps all existing generation checks; a copied ledger still refuses.

The per-ledger current record locates its enclosing state root without a new option:
remove its validated relative_root suffix component-by-component from the expanded
physical ledger path, require exact join-back equality, stat that state directory and
recompute the state-root binding. Read the exact ordinal root intent there; require its
candidate entry and ledger_intent SHA match. A source-role binding refuses. A
destination-role binding requires the current root committed proof and exact candidate
generation; historical/source-retired evidence cannot grant authority. For a ledger
without restore metadata, ordinary generation validation remains unchanged; composition
checks root exclusion before creating its Local binding. A trusted standalone host is
still required to exclude all direct Local opens during the offline transition,
including before the first per-ledger intent appears. No ledger-level metadata claims
structural discovery of an enclosing state root before any binding exists.

Original-tx restore reads/checks and re-synces exact prior stages after old admin
authority termination, then completes remaining stages in this order. A same-plan
already committed duplicate returns the same retained receipt after bounded
validation/joins; it performs no replacement epoch, replay dispatch or source
reactivation. After a later restore, old receipts remain historical completion evidence
and do not authorize their old placement. Original source retirement never gets undone
to recover availability.

No cross-root atomic transaction exists. Safety comes from available-source fence before
destination activation and lost-source host exclusion, with uncertainty fencing the
original mutation domain. Deleting/loss of sole intent/claim evidence after unknown is
not proof of noncommit and cannot authorize a new tx; it is a further reviewed recovery
prerequisite. Restore does not reset executor deadlines or turn reboot into effect
completion.

<a id="technical-adr-0051-outcomes"></a>
### Closed receipts, refusals and lookup

Concept: [Closed receipts, refusals and
lookup](0051-current-format-physical-restore.md#concept-adr-0051-outcomes).

Returned receipt≤2048, derived exactly from fully checked retained records; it carries
no physical path, live authority or raw job/host evidence:

```text
receipt = {
 "kind": "loopex_current_restore_receipt_v1", "tx_id": hex64,
 "ordinal": ordinal, "plan_digest": hex64,
 "intent_sha256": hex64, "committed_sha256": hex64,
 "source_retirement_sha256": hex64,
 "baseline_manifest_sha256": hex64,
 "activation_manifest_sha256": hex64,
 "prior_lineage_sha256": hex64,
 "destination_state_binding": hex64, "ledger_count": 0..128
}
observation = {
 "kind": "loopex_current_restore_observation_v1", "tx_id": hex64,
 "ordinal": nil | ordinal, "phase": phase_enum,
 "intent": "absent" | "may_exist" | "validated",
 "cleanup": "joined" | "unconfirmed",
 "claim": "none" | "held" | "retained",
 "reason": reason_enum
}
refusal = {
 "kind": "loopex_current_restore_refusal_v1", "tx_id": nil | hex64,
 "code": refusal_enum, "phase": phase_enum,
 "cleanup": "joined", "claim": "none" | "retained"
}
lookup_refusal = {
 "kind": "loopex_current_restore_lookup_refusal_v1", "tx_id": nil | hex64,
 "code": lookup_code_enum, "cleanup": "joined" | "unconfirmed"
}
```

Observation/refusal/lookup-refusal≤2048 each. No unbounded error text, raw paths, OS
reason terms or recursive evidence in results. reason_enum exactly `"none"`,
`"deadline"`, `"caller_lost"`, `"io_error"`, `"readback_mismatch"`,
`"fsync_unconfirmed"`, `"worker_unjoined"`, `"descriptor_unclosed"`,
`"authority_unconfirmed"`, `"history_invalid"`, `"claim_release_unconfirmed"`.
`intent=absent` requires no possible issued temp/final-intent write and a joined read;
timeout cannot produce absent. lookup never labels the live old worker joined from
filesystem bytes; it uses cleanup only for its own owned read workers. It reports claim
held/retained conservatively as retained unless a caller-owned live guardian proves
held.

Before first possible intent, first applicable refusal_enum wins after bounded joined
cleanup: invalid_plan, invalid_placement, restore_conflict, authority_unconfirmed,
destination_not_empty, inventory_unavailable, inventory_limit_exceeded,
inventory_mismatch, invalid_current_history, source_changed. Lineage 64→65 is
inventory_limit_exceeded. For invalid/missing tx, tx_id=nil. After possible intent these
codes are not retroactive not_committed; use commit_unknown observation. A pre-intent
unjoined cleanup uses cleanup_unconfirmed instead of not_committed. Phase/refusal
evaluation cannot wait unboundedly to obtain later precedence.

lookup_code_enum exactly invalid_query, administrative_path_unavailable,
restore_history_invalid, restore_conflict, physical_destination_changed,
inventory_limit_exceeded, deadline, cleanup_unconfirmed. This replaces v2's inconsistent
error spelling. Lookup uses bounded monitored raw read IO and the same work/cleanup
rules, but no claim reclaim/sync/write/cleanup-of-state, no continuation or activation.
Join failure returns error code cleanup_unconfirmed with cleanup=unconfirmed and
preserves host exclusion of any retained previous admin claim.

To validate a historical activation_manifest_sha 256 without comparing ordinary evolved
runtime files to an old cut, reconstruct its exact canonical manifest from that
ordinal's retained baseline: apply only the specified generation entry byte/size changes
and exact admin entry additions (known canonical record hashes/lengths, 0700/0600 modes,
including copied available-source ledger_retired files). Existing parent-directory modes
remain the baseline modes; new ones are 0700. Per-ledger/root committed additions are
excluded only from this pre-commit activation image, as prescribed by its capture order,
and validated separately as the exact subsequent additions. Require the reconstructed
activation digest and every retained baseline/proof/retirement/hash to match. This is
validation of retained administrative evidence, not a claim that today's Store files
still equal a past activation cut. The complete next backup manifest includes all of it
unexcluded.

Lookup committed/current requires checked latest root/per-ledger
intent/candidate/retirement/committed chain, current physical state/ledger bindings, no
unfinished higher ordinal and no retained admin claim. Historic tx at an earlier
committed ordinal returns the same receipt with view=historical only after whole
retained lineage validation, without reobserving unavailable old roots or implying their
authority. A newer outgoing intent may retire a currently present source; querying its
older completed receipt then yields historical, never current. Missing/corrupt dependent
proof is an error, not historical completion.

Lookup pending validates enough intent/claim identity to identify the original tx, then
returns the earliest incomplete phase with intent validated/may_exist and exact bounded
reason; it is not permission to dispatch or reclaim. Root committed plus retained claim
yields phase claim_release, never committed/current. Absent is only a present
observation when no matching retained intent/claim/lineage exists and reads joined; it
cannot override a previously observed unknown or authorize replacement after
administrative data loss. Caller keeps its retained original-tx uncertainty/evidence.

<a id="technical-adr-0051-compatibility"></a>
### Alternatives and amendment mechanics

Concept: [Alternatives and amendment
mechanics](0051-current-format-physical-restore.md#concept-adr-0051-compatibility).

This additive successor leaves the historical accepted ADR 0016 pair unchanged. Its
narrow supersession applies only after explicit acceptance of this exact pair and before
dependent implementation. Ordinary prepare still uses generation_v1 and its unchanged
2048-byte codec/path-device-inode preimage; no generation-v2 rewrite, dual decoder,
older-root migration or compatibility path is introduced. Retained private restore files
use only the current v1 grammar defined here.

The recommended profile uses trusted host attestations and local append-only provenance.
A nonrollbackable external registry would need separately governed identifiers,
ownership, storage, exclusion/freshness, outage and recovery semantics. It is not
smuggled into the external per-path claim: that temporary claim serializes one
host-selected path, not every independently copied root. Original-path-only recovery
cannot deliver the selected lost-directory branch. Ordinary prepare without this
transition continues to refuse fresh-root copies.

Source retirement is one-way within the protocol. Original-tx resolution completes only
the same retained intent/candidates. No file deletion, loss of a claim, timeout or
rollback to an earlier binary authorizes old-root reactivation. A requested reversal
must positively terminate the destination and use a new reviewed transition. Lost
intent/claim identity after unknown requires a further reviewed recovery decision.
Current-format restart, replay, retained unknowns and complete backup/restore remain
required; superseded-format readers are not an acceptance obligation before 1.0.

The method lives in composition/Local administrative code; Core depends only on its
existing inward ports and retains the same operation/public tuple truth. It does not add
a Runtime API, generic migration layer, backup CLI, transport route or extra provider
attempt. Module spelling and pure existing validator extraction are reversible
implementation choices after acceptance; introducing another authority service or IO
ownership assumption is not.

<a id="technical-adr-0051-proof"></a>
### Physical proof obligations and evidence

Concept: [Physical proof obligations and
evidence](0051-current-format-physical-restore.md#concept-adr-0051-proof).

Focused proof after acceptance must cover at least two successive complete current
restores (A→B→C, available and lost source combinations), exact unchanged prior lineage
bytes/modes, earlier proof historical-only, partial higher ordinal blocks older
authority, fresh candidate reuse on unknown, 64/65 boundary without pruning, and new
ledgers with sparse per-ledger provenance. Preserve source/backup/staged/full activation
manifests and every exact permitted administrative change. Exercise actual file/parent
fsync, rename/readback faults and process-death cuts at every phase; include
delayed/in-flight raw IO, unclosed descriptor and suspended/killed guardian/worker,
pre-intent cleanup_unconfirmed, post-intent unknown, release uncertainty and exact
joins. No fake IO, actor-liveness substitution, timeout/retry inflation or Logger
suppression.

Prove available-source prepare and already-prepared/claim revalidation refusal before
destination authority; lost-source report identifies trusted attestation rather than
fake tombstone. Actual settled/unknown Local receipt/reconciliation preserves original
bytes/tuples and zero effect redispatch; open/quarantine/stranded effect claims remain
truthful. Current Store semantic audit, exact missing
artifact/receipt/history/cap/physical-binding refusal, real separate physical workspace
retained while state restore leaves mutable effects intact, then separate workspace
content restore at same directory identity. Future helper-ledger semantic acceptance
stays separately blocked until its current grammar exists; this unit cannot close all T
15.

Evidence retained before implementation:

- Proposal packet `/private/tmp/loopex-m7-current-restore-exact-amendment-research-20261005-v3-final.md`, SHA-256 `4f9f07b54d69ed68426b487fa3e5ce9d1b189994228a3ff8d01f440e9ada6df2`.
- Exact 32-source inventory `/private/tmp/loopex-m7-current-restore-exact-amendment-research-20261005-v3-final-sources.json`, SHA-256 `a3d9d80ec9e9f9efc0d478fef06c5ea46fa8aa6c191fc7b81a515fd4893519a4`, source snapshot root `b9b6ec85d58183db5eb2dfe88a1ebe1979ea2fcb`.
- Integrator review `/private/tmp/loopex-m7-current-restore-integrator-review-20261005-v2.md`, SHA-256 `92e5a617a48596d9e4ffd04575d3159d7b475c2102f60554a8fd2d790bf85325`. Its two clarifications are included in both depths: normal completion captures the one terminal cleanup cutoff; standalone Local needs host exclusion before metadata permits enclosing-root discovery.
- Failed actual copy/restore draft commit `427c9cb5631e8c921748aa0e787d7205930ed703` and retained decision packet `/private/tmp/loopex-m7-current-restore-decision-packet.md`, SHA-256 `4665662ca927b02d20fc979497ad6b412f583cf8afed95fe309ddd45666b8a6a`. The draft remains unintegrated; mode/copy and fresh physical generation failure evidence is preserved.

These are research/draft/review pointers, not successful product tests. The prior
independent architecture audit was unavailable and inspected nothing. Pinned OTP raw IO
source inspection is feasibility evidence only; both-pair physical lifetime/fault
conformance remains required. No product PASS, helper-aware T 15 closure, maintainer
acceptance or independent exact-candidate closure review is supplied by this pair.

