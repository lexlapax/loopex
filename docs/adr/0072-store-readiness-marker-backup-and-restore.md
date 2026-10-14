<a id="concept"></a>
## Concept

Technical depth: [Marker, adopt, backup and restore commands, and evidence](0072-store-readiness-marker-backup-and-restore-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30; reconciled with the delivered M7 baseline on 2026-10-13; detailed for implementation on 2026-10-13 against the maintainer's decisions of that day; the maintainer's older-backup decision, the daemon exit-status renumbering, the two-phase adoption and adopt's hold of the placement lock through its commit recorded on 2026-10-13; the walk's credential-directory identity check and the corrected old-writer rationale recorded on 2026-10-13; the restore guard entry point, the mount refusal and the post-commit cleanup outcome recorded on 2026-10-13; the maintainer's Linux filesystem-path guard and mount-table rule, and the outcome of a stop in the final check after the commit, recorded on 2026-10-13; ADR 0037's mounts-above rule (D21) adopted by every walk on 2026-10-13; after the holistic internal review on 2026-10-13, the format-number rule and its inventory test, the job index kept on disk by backup and admitted by `restore/3`, and the maintainer's retained M7-built root for adoption (D24); the maintainer's product-path adoption of a live M7-written root in the release check (D26) recorded on 2026-10-14; the maintainer's format-number policy (D28), the golden-vector pin and the read-only child audit of the product-path adoption recorded on 2026-10-14; the maintainer's decision that credential separation is a path rule only (D27), which removes the restore guard, every walk rule for mounts and credential-directory identities and the third ADR 0051 amendment, recorded on 2026-10-14; the maintainer's decision that `restore/2` always leaves the helper job index out of its audit index, which drops `restore/3` (D29), recorded on 2026-10-14; after an internal review on 2026-10-14, the golden-vector pin replaced by a retained format-1 fixture check, and the child audit given its shape precheck; the maintainer's D33 to D35 (time-zone-independent lock and writer-marker records, the `m7-adopt` prerequisites, the ADR 0056 amendment) and an internal review's fixes recorded on 2026-10-14; the maintainer's D45 (adopt rebinds a ledger bound through an alias) and a second internal review's fixes recorded on 2026-10-14; the maintainer's D48 (the rebinding carries the ledger's open authority, amending ADR 0016) and a third internal review's fixes recorded on 2026-10-14; the maintainer's D55 (the path-derived identity of `resource-packs/receipts`) and a fourth internal review's fixes recorded on 2026-10-14; the maintainer's D59 (no rebinding of `resource-packs/receipts` holding a receipt) and a fifth internal review's fixes recorded on 2026-10-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing. It narrowly amends accepted [ADR 0016](0016-configured-cancellation-observation.md#concept) in one clause (D45, D48): `store adopt`, under the placement lock, the `adopting` fence and the `--old-writer stopped` attestation, may replace a ledger generation bound through the selected alias with a fresh-epoch generation bound to the physical path, carrying the open index, markers and receipts unchanged, and for `resource-packs/receipts`, whose identity is path-derived, only while it holds no open effect and no receipt, and with the physical path's identity (D55, D59). It narrowly amends accepted [ADR 0051](0051-current-format-physical-restore.md#concept) in two clauses only, listed under [Amendments](#concept-adr-0072-amendment): its statement that no backup CLI is added; and its restriction of restore to the latest backup, which an explicit `--discard-later-work` statement relaxes for a lost source. It narrowly amends accepted [ADR 0056](0056-host-helper-ledger-recipe.md#concept) in one clause, stated in five sentences: the helper job index is left out of ADR 0051's audit (D35). It adds operator commands in front of ADR 0051's otherwise unchanged transition. It also takes the operator backup and restore work out of Proposed [ADR 0036](0036-daemon-grade-store-engine-and-migration.md#concept), which keeps the engine selection, migration and capacity refusal. That split is M8's proposal P2, which the maintainer accepted on 2026-10-13
- **Depends on:** [ADR 0051](0051-current-format-physical-restore.md#concept) for the restore transition, its backup profile, inputs, limits and outcomes; [ADR 0056](0056-host-helper-ledger-recipe.md#concept) for the helper ledgers the audit decodes; [ADR 0070](0070-pre-1-superseded-surface-retirement.md#concept) and the current replay for record refusal; [ADR 0031](0031-daemon-grade-store-selection-and-migration.md#concept) for the local adapter and its limits; [ADR 0046](0046-child-session-tool.md#concept) for the closed-host rule restore answers; [ADR 0037](0037-host-configuration-and-path-discovery.md#concept) for the command family, root and workspace selection, the physical root path every opener receives, the configuration writer, `doctor` and the readiness report
- **Prerequisite for:** M8 outcomes 3 and 7, accepted before any marker, adopt, backup or restore command code is written

<a id="concept-adr-0072-decision"></a>
### Context and Decision

Technical depth: [Contract and ownership](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-decision).

This record was first proposed before M7 was built, as a container marker, a
reader inventory and a backup archive with its own restore. M7 then settled
most of that.

- **Restore exists.** Accepted ADR 0051 delivers
  `LoopexComposition.Restore.restore/2` and `lookup/3`. They restore a
  complete, unexcluded, idle backup of a current-format root into an empty
  root on the same machine, retire or exclude the original source, and never
  redispatch an uncertain effect. The host owns backup creation, the capture
  record, plan construction and the attestation. No operator command exists.
- **Unknown records are refused.** Session replay refuses a record kind outside
  the current inventory as `invalid_private_history`. ADR 0070 refuses a root
  that has only the retired session catalogue. Before 1.0 no older root,
  reader or client is supported.

Two gaps remain for an installed operator. Backup and restore need a host
program. And an unsupported root is refused only after Loopex has written to
it: the placement lock, the runtime identity file, the Store's writer marker
and any torn-tail repair all come before replay can refuse anything.

The maintainer decided the following on 2026-10-13. They are recorded here as
decided, not proposed:

1. **Current-format roots only.** No upgrade from an older root and no
   cross-version rollback.
2. **Root marker.** The 0.5.0 build writes a current-format marker into every
   new root, and refuses an unmarked or unknown-marked root before any write:
   before the placement lock, the Store writer marker or any torn-tail repair.
3. **`store adopt`.** A one-time command marks an existing root that the M7
   source build wrote, or any unmarked current-format root. It writes
   nothing but the marker; the root's own placement lock, whose taking
   removes a dead contender's leftover lock files as any start does; the
   removal of stray marker temporaries and of rebinding temporaries an
   earlier adopt left; and, for a root whose executor ledger was bound
   through an alias of its path, a rebound ledger generation that carries
   the ledger's open effect authority unchanged (D45 and D48, which narrow
   this decision and amend ADR 0016). Adoption has two phases,
   decided by the maintainer on 2026-10-13. The operator first states
   `--old-writer stopped`: no process of the build that wrote the root is
   running. Adopt then takes the root's placement lock, the
   same exclusion the service and every root-opening command take, and holds
   it for its whole run. Under the lock it publishes an `adopting` marker,
   which every entry point of this build refuses, so no new start can write
   during the audit. It decodes every record and confirms the root is current
   format. Only when the audit passes and the root is still exactly what was
   audited does it rename the marker to current, still under the lock; that
   rename is the commit, and adopt releases the lock after it. An adopt killed
   or refused before the rename leaves `adopting`, and running adopt again
   redoes the whole audit; one killed after it leaves a committed current
   root. A concurrent adopt or start is refused by the existing placement
   refusal while adopt holds the lock.
4. **Restore attestation.** `store restore` refuses unless the operator states
   the source branch, available or lost, and confirms that the old writer is
   stopped. The command also checks that the placement lock is free and that
   no writer marker is live, and reports those checks, but does not treat them
   as proof.
5. **After restore.** The command restores into a new empty root, prints that
   root and the exact ADR 0037 configuration command that selects it. It never
   rewrites configuration.
6. **Unreadable session history (P6).** It is recovered by restore. The
   readiness report names the unreadable session. There is no quarantine.
   The operator moves the root aside and restores with `--source lost`,
   adding `--discard-later-work` when the backup predates later work
   (decision 9).
7. **`store backup`** produces ADR 0051's complete backup of a closed root.
8. **Ownership.** ADR 0037 owns the command family framework, `doctor` and the
   status report, which show this record's root facts by reference. This
   record owns the `store backup|restore|adopt` grammar and the readiness
   facts.
9. **Older backups.** `store restore` may restore a backup that is not the
   latest state of the root only when the operator gives the explicit
   `--discard-later-work` statement. Without it, restore stays strict: the
   operator states that the backup is the latest state, as ADR 0051 requires.
   The statement is recorded in the retained attestation in place of the two
   latest-state statements.

This record decides how each of those works. ADR 0051 still decides the
restore transition and ADR 0070 the retirements.

<a id="concept-adr-0072-marker"></a>
### The Current-Format Marker

Technical depth: [Marker path, bytes, write procedure and check](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-marker).

Every state root this build uses carries one small file,
`loopex-root-format`, whose whole content is `loopex-root-format 1` and a line
feed. Format 1 is the current format. The file is published atomically and
never rewritten.

The check runs inside the code that every root-opening path already passes
through, so no entry point can skip it. Before the placement lock is taken, and
again before composition starts a Store:

- an absent directory, or an empty one, is a new root: the marker is written
  first, then work proceeds;
- a root marked current proceeds;
- a nonempty root without the marker is refused as `root_unmarked`;
- a root whose marker says `adopting` is refused as `root_adopting`: an
  adoption started and has not finished;
- a marker naming another format or version is refused as
  `root_format_unknown`; one that cannot be read is `root_marker_unreadable`.

A refused root is left byte-identical: no lock, no runtime identity file, no
writer marker, no repair. Commands that only read a root, such as `sessions`,
check the marker without ever writing it. The foreground commands exit `1`
with the code named. The service exits with one new status per code, so a
service manager can tell them apart.

**The number moves with the format.** Format 1 is exactly what this build
durably writes into a root: its private session records and the events its
Store log carries, the Store log and snapshot, the session catalogue and
runtime identity, executor and helper ledgers and their job index, artifact
and resource records, ADR 0051's restore records, the placement lock record,
and this record's backup records and layout, together with every shape one of
them delegates to another module, such as a session's initial settings. The
maintainer decided on 2026-10-14 (D28) that any change to a durable member,
shape or encoding of any of them requires a new format number, in any
release, a `0.5.x` patch as much as a later minor release. A build therefore
never opens a root in a format it does not read; it refuses it by name, and
roots of an earlier number stay refused until a separately decided migration
exists.

The check that holds the rule is small and its reach is stated. One
format-1 root, written once by the real runtime with only the model
scripted and retained as a repository fixture with a pinned digest, and the
retained M7-written root are decoded in the fast check by the same full
audit adopt runs. The codecs that are pure functions of their input must
also re-encode what they decoded to the exact retained bytes, and a short
named list of size limits is checked one unit over each limit and, where a
valid input that large is cheap to build, at it. A change that makes a
retained record unreadable, or changes a pure codec's bytes or one of those
limits, therefore fails the fast check. It passes again only with a new
fixture, which under D28 comes with a new number; the check does not tie
the two together, and review does. Everything else is review's too: a shape
no retained record reaches, a change to what a writer process writes when
the retained bytes still decode, such as a new optional member, and a
regenerated fixture under an unchanged number are caught, under D28, by
review of any change to a format owner, not by the check.

<a id="concept-adr-0072-adopt"></a>
### Adopting a Root the Source Build Wrote

Technical depth: [Adopt algorithm, limits and crash safety](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-adopt).

`loopex store adopt --old-writer stopped` exists for roots written before the
marker: by the M7 source build, or by any build whose records are already
current format. It is not a migration. It changes no record, except that it
rebinds an executor ledger bound through an alias (below). The statement is
required and has no default: the operator states that no process of the build
that wrote the root is running, because that build does not know the marker
and nothing else can stop it.

Adopt first takes the root's placement lock, the same lock the service and
every lock-taking command take on a root, and holds it until the root is
committed. A service, a command or a second adopt that tries to take the
root meanwhile is refused as the lock already refuses a held root. A stale
lock left by a dead process, such as a killed adopt, is reclaimed as any start
reclaims it. The lock's own files are lock state, not records, and adopt's
manifests leave them out.

Adoption then has two phases.

1. **Fence.** Adopt checks that the root is closed and publishes the marker in
   its `adopting` form. From then on every entry point of this build refuses
   the root as `root_adopting`: the service, every foreground command, `ask`,
   an embedded durable start, `store backup` and `store restore`.
2. **Audit, then commit.** Adopt records the root's complete manifest and
   reads the whole root with the same decoders and audit ADR 0051's restore
   uses: every Store frame, every session's replay, every receipt and ledger,
   artifact, resource record and helper log, and the session catalogue
   through the host's own reader. It then records the manifest again. Only
   when everything decoded and the second manifest equals the first does it
   rebind any ledger bound through an alias, then replace the `adopting`
   marker with the current one in one atomic rename, still holding the
   lock. That rename is the commit. Adopt then releases the lock and checks
   nothing more.

A root marked `adopting` is never used. Adopt stops at the first record it
cannot decode and names it; it refuses a root that is held, that stopped
uncleanly or that has only the retired catalogue before publishing anything.

The executor ledger binds the path it was first opened through, and this
build opens every root by its physical path, as ADR 0037 hands it to every
opener. The maintainer decided on 2026-10-14 (D45) that adopt rebinds a
ledger the old build bound through the root path the operator selects, when
that path is a symbolic-link alias of the physical one: after the audit and
the second manifest, and before
the commit, still under the lock, it replaces that ledger's generation with
a new one bound to the physical path, the way restore installs a fresh
generation, and changes no other ledger file: the open effects, markers and
receipts the audit read stay the ledger's authority, unchanged and never
redispatched (D48). One ledger, the resource importer's
`resource-packs/receipts`, takes its executor identity from its own path,
and each of its open effects and receipts records that identity (D55, D59):
adopt rebinds it only when it holds neither, and then also gives its
generation the identity its physical path derives; one holding an open
effect or a receipt is refused before the fence as `ledger_path_mismatch`.
So a root whose `resource-packs/receipts` the old build bound through the
alias, and which ever imported a resource pack, cannot be adopted and stays
with that build. ADR 0016 treats an alias as an administrator rewrite and requires a
migration to close the old open authority first; this record amends that
for adopt alone (below). A crash in between leaves
`adopting`, and the rerun audits each ledger as it then is and rebinds only
those still bound through the alias; the old build can no longer open a
rebound ledger through its alias, so the operator reruns adopt. A ledger bound under any other path,
such as a moved or copied root or an alias the operator did not select, is
refused before the fence as `ledger_path_mismatch`, with nothing written.

Every failure after the fence, and an adopt killed before the rename, leaves
`adopting`: `root_changed` when the root changed during the audit, and the
decode refusal when a record cannot be read. An adopt killed after the rename
leaves a committed current root. Running adopt again redoes the full audit
from the start and never trusts an earlier run. The delivered M7 daemon and
CLI hosts take this same placement lock on the same file. This build writes
its lock record as `loopex-placement-v2`, whose process identity no longer
depends on the time zone (D33); an M7 process reads it as unreadable and, by
its delivered liveness-only rule, refuses while adopt's process lives. The
`--old-writer stopped` statement remains required all the same: the M7 build
does not read the marker, so once adopt releases the lock, after a refusal or
kill that left `adopting` or after the commit, an M7 process can open the
root again, and an embedded or other non-cooperating host may never take the
lock at all. `doctor` reports an `adopting` root. The maintainer decided on
2026-10-13 (D24) that adoption is proved on a real root the M7 build wrote:
the `v0.4.0` source build writes and stops a root holding a conversation and
one helper run, and that root is retained as a test fixture that the adopt
tests audit and mark and the installed lane refuses. Because that fixture is
moved into a new place, neither its workspace nor its executor ledger's
directory matches what the M7 build recorded, so the fixture test supplies
the workspace reference and ledger placement recorded at production and
proves the audit and the marker, not the product path. The maintainer
decided on 2026-10-14 (D26) that the product path is proved as well: the full
release check builds the `v0.4.0` release, lets it write and stop a root on a
live workspace with a conversation and a helper run, then runs the
candidate's own `loopex store adopt --old-writer stopped` on that root and
opens it with the candidate, which finds the root current and lists the
conversation. The M7 build never listed the helper's child session in its
session catalogue and adopt adds only the marker to that root, whose ledger
the M7 build bound to its physical path, so the child's
journal and terminal record are checked by a read-only audit over the
delivered decoders, and every record the M7 build wrote stays
byte-identical. Building the release, the M7 write and a check of the run's
shape are host prerequisites (D34): a real provider need not do what the
review asks, and when the build or the M7 write fails, or the shape check
reports unavailable (the run did not leave exactly one helper run whose
child was prompted) or prints no verdict, the case stops before it starts
and, as every such stop does, so do the release cases after it; in an
indexed run they are recorded not dispatched, and they run again on the
same candidate. This is never a failure of the candidate. A second release case runs the
`v0.4.0` build's own lock and Store writer code against this build's
records, and this build's against M7's, under different time zones (D33).
Running adopt on a root already marked
current reports that and writes nothing. A root adopt cannot read stays with
the build that wrote it; this build never opens it.

<a id="concept-adr-0072-backup"></a>
### Backup

Technical depth: [Backup capture, layout and verification](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-backup).

`loopex store backup BACKUP` captures the selected root into a new directory.
The root must be marked and closed: no live or stale placement lock, no Store
or helper writer marker, no restore claim and no torn tail. The command says
what it will back up, then copies the whole root with ADR 0051's owned copy
and checks the copy against the source twice. It audits the copy exactly as
restore will, so a backup that restore would refuse is never published. The
helper job index, a disposable cache the service rebuilds, is copied like
every other file and left in place in the source. The audit never indexes
or decodes it, in every mode: adopt's, backup's and, as M8 changes it, ADR
0051's own restore (D29). Backup writes nothing into the source but the
removal of stray marker temporaries. It refuses, as `ledger_path_mismatch`,
a root whose executor ledger is bound to a path other than its physical
one, which only an embedded host opening a new root through an alias can
make; this build cannot back such a root up.

The copy takes every file of the root, under ADR 0051's complete manifest,
with no exclusion. Provider sign-in tokens and gcloud's Application Default
Credentials file never enter it because ADR 0037 keeps their directories
apart from every state root by path, not because backup leaves anything out.
Each store command checks every path it will walk, the root, the backup, the
destination and an available restore source, against those two directories
before its first read or write of that path, comparing paths after symbolic
links are resolved; and the walk refuses any symbolic link or hard-linked
file inside a root, as ADR 0051's manifest always has. The maintainer decided
on 2026-10-14 that this path rule is the whole of the separation (D27): no
mount is examined, so the operator must not mount credential storage into or
over a state root, backup or restore destination. Such a mount, of any kind,
and a credential file the operator copies into a root are outside the
guarantee.

The backup directory holds the complete copy, the canonical manifest and a
capture record carrying everything ADR 0051's plan needs except the
operator's statements and the destination. It appears at its final name only
when complete. A service start during the backup changes the source and makes
the backup refuse rather than capture a moving root.

<a id="concept-adr-0072-restore"></a>
### Restore

Technical depth: [Plan construction, attestation, checks and output](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-restore).

`loopex store restore BACKUP DESTINATION --source available|lost
--old-writer stopped|rebooted` restores into a new empty directory. Both
statements are required and have no default. For `available` the original
root must be unchanged since the backup and is retired by the restore; for
`lost` its original path must be positively absent.

The command checks the backup against its manifest, the destination, the
workspace identity, and, for an available source, the placement lock and the
writer markers. It prints what it observed and refuses only when an
observation contradicts the operator, such as a live lock holder. It retains
the exact plan and the operator's statements beside the backup, then calls
ADR 0051's restore once.

**Restoring an older backup.** When work happened on the root after the
backup, the operator adds `--discard-later-work`. It is accepted only with
`--source lost`: the operator first moves the original root aside, and the
command refuses the flag with an available source. With the flag the operator
no longer states that the backup is the latest state. They state instead that
every session turn, record and approval after the backup is abandoned, and
that external effects performed after it stand as they are, unrecorded and
unreconciled. The command prints that statement, records it in the retained
attestation and in the plan, and restores the backup exactly as for a latest
backup. Without the flag nothing changes: the operator states the backup is
the latest state, as before.

After a committed restore it prints the new root's physical path and the ADR
0037 command that selects it, and changes no configuration. After an
uncertain result it prints the transaction and the exact command that
re-presents it, which reuses the retained plan byte for byte. The command adds no copy, audit or transition of
its own.

<a id="concept-adr-0072-readiness"></a>
### Readiness Facts

Technical depth: [Root facts and service readiness fields](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-readiness).

`doctor` shows this record's root facts without writing or scanning history:
the marker and its format, including a root left `adopting`, whether the root is held, stale, or has writer
markers left, its restore state, and the root and backup formats this build
reads and writes. The running service's readiness report carries the facts
this record fixes: for a closed host, the session whose history cannot be read
and why; for an unavailable host, a code and no session; and whether the
workspace's project resources were admitted, including the "not admitted"
that a start on demand always leaves. A closed root is left closed and
recovered by restore; there is no quarantine.

<a id="concept-adr-0072-consequences"></a>
### Observable Consequences

Technical depth: [Evidence and test plan](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-evidence).

Technical depth: [Failure modes and exit statuses](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-failures).

`loopex store backup`, `loopex store restore` and `loopex store adopt` exist in
the installed release. An operator stops the service, takes a backup, and can
later restore it into a new root on the same machine, then selects it with
one printed command. The original workspace must still be at its recorded
physical identity. Restore leaves workspace contents and external effects
alone, and the documentation says so plainly.

An operator whose service reports a closed root learns which session is
unreadable, moves the unservable root aside and restores a backup into a new
root with `--source lost`. If the service did work after that backup, which is
the usual case, the operator adds `--discard-later-work` and knowingly gives
up that work; the restored root's history ends at the backup, and effects made
after it are not reconciled. An operator who points the release at an unmarked or unknown root gets a
named refusal and an unchanged root, never a partial upgrade. A root the M7
source build wrote is adopted once, after its writer is stopped, and then used
normally; until adoption completes, the root is refused as `root_adopting`.

<a id="concept-adr-0072-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics and alternatives](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-compatibility).

The private Store ports, session and command identity, public event schemas,
the daemon's placement rules and ADR 0051's records and outcomes do not
change, except that M8 changes `restore/2` to commit a root holding a helper
job index that it refused before (D29). ADR 0051's plan gains one
alternative attestation form, used only with `--discard-later-work`; a plan
in the existing form is unchanged. The placement lock record and the Store
writer marker take new versions whose process identity no longer depends on
the time zone; an M7 process reads either as unreadable and never reclaims it
while its holder lives (D33). For the same reason `TZ` can no longer name a
credential variable or a Store launch exclusion. `store adopt` gives a Local
ledger the old build bound through the selected alias a new generation
bound to the physical path, with its open authority unchanged (D45, D48),
and for `resource-packs/receipts`, only with no open effect and no
receipt, the identity of the physical path (D55, D59). The marker, the backup layout and its records
are experimental current-format contracts, each with its own version. Before 1.0 only the
current version of each is read. A backup is a directory holding the complete
copy, ADR 0051's manifest and this record's capture record; there is no
archive. The store engine and its migration are M9's work under ADR 0036,
which reads its source root through the marker check and states its rollback
as a restore of one of these backup directories.

This decision is removed by not shipping the three commands and the marker
writer. A root that already carries a marker stays readable by the build that
wrote it; no other build is promised to read it.

<a id="concept-adr-0072-amendment"></a>
### Amendments of ADRs 0016, 0051 and 0056

Technical depth: [Amendment text](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-amendment).

ADRs 0016, 0051 and 0056 stay byte-for-byte as accepted. On acceptance this
record amends exactly two clauses of ADR 0051 and one each of ADRs 0056 and
0016, and the ADR index records all four:

1. **Backup CLI.** ADR 0051 says no backup CLI is added. This record adds
   `store backup`, `store restore` and `store adopt` as host commands in front
   of ADR 0051's transition.
2. **Latest backup only.** ADR 0051 places arbitrary historical snapshot
   rewind outside its decision, and its supersession, purpose, attestation and
   audit sentences require the backup to be the latest cut with no activity
   after it. The maintainer decided on 2026-10-13 to admit an older backup
   when the host instead attests that later work is deliberately discarded,
   for a lost source only. Everything else ADR 0051 decides stays: the same
   machine and workspace, a complete idle backup, an empty destination,
   exclusion of every other copy, fresh ledger generations, and never
   redispatching an uncertain effect.
3. **The job index in restore's audit (D29, D35).** ADR 0056 requires ADR
   0051's offline audit to enumerate the complete helper namespace, which
   holds the disposable job index, and lets corrupt helper state prevent
   restore completion. The maintainer decided on 2026-10-14 that M8 changes
   `restore/2` to leave the job index out of its audit index (D29), and that
   this narrowly amends ADR 0056 (D35): the job index is not audited, and a
   corrupt entry is discarded and rescanned at startup, as the delivered
   helper already does. Its bytes are still copied and stay in every
   manifest, so a current root that holds a job index restores through
   `restore/2`, which today refuses it as `invalid_current_history`. No ADR
   0051 sentence names the job index or what the audit's index holds, so this
   amends no ADR 0051 clause; its manifests, copy, comparisons, walks, phases
   and result grammar are unchanged. There is no `restore/3`.
4. **Adopt's ledger rebinding (ADR 0016, D45, D48).** ADR 0016 binds a
   Local ledger's generation to the expanded path and directory it was
   opened through, refuses a root moved to another path, replaced or
   copied, treats retargeting a path through an alias as an unsupported
   administrator rewrite, and requires a
   future migration to close every old open authority before it creates a
   new generation, never copying the old one as authority. The maintainer
   decided on 2026-10-14 that `store adopt`, and nothing else, may, under
   the placement lock, the `adopting` fence and the `--old-writer stopped`
   attestation, replace a generation bound through the selected alias with
   a fresh-epoch generation bound to the physical path, carrying the
   audited open index, markers and receipts unchanged. For
   `resource-packs/receipts`, whose executor identity is derived from its
   path, adopt does so only while it holds no open entry and no receipt,
   and the new generation also carries the identity of the physical path
   (D55, D59). Every other ADR 0016
   rule stands, for every other migration as well.

<a id="concept-adr-0072-open"></a>
### Open for the Maintainer

Technical depth: [Resolved choice](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-open).

Nothing remains open. The older-backup choice was decided on 2026-10-13 as
decision 9, with the amendment above.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
