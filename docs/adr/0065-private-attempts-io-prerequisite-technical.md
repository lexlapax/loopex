<a id="technical-depth"></a>
## Technical depth

Concept: [Private attempts IO prerequisite](0065-private-attempts-io-prerequisite.md#concept).

<a id="technical-adr-0065-purpose"></a>
### Available lock mechanisms

Concept: [Purpose and evidence](0065-private-attempts-io-prerequisite.md#concept-adr-0065-purpose).

[Development prerequisites](../../DEVELOPMENT.md) currently allow Python 3 for
M6 demonstration and attended fixtures while excluding it from direct
`check-release.sh` prerequisites. Existing Python task-status and evidence
scripts do not amend that scope.

Inspected OTP 27.3.4 and 29.0.5 `file` and `prim_file` exports provide IO and
sync operations but no advisory lock API. `file:open`'s exclusive option uses
create-if-absent semantics; a surviving pathname does not prove a live writer
or authorize deleting its owner. VM-local names and mutexes cannot exclude
another VM. Neither Darwin `lockf` nor Linux `flock` belongs to the currently
required common POSIX baseline.

Python's standard-library `fcntl.lockf` exposes process-associated POSIX record
locking without packing a platform-specific native structure. See the
[Python fcntl reference](https://docs.python.org/3.11/library/fcntl.html),
[Darwin fcntl manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)
and [Linux locking manual](https://man7.org/linux/man-pages/man2/fcntl_locking.2.html).
These references describe mechanics, not proof of an installed helper.

<a id="technical-adr-0065-decision"></a>
### Scope and physical ownership

Concept: [Recommended decision](0065-private-attempts-io-prerequisite.md#concept-adr-0065-decision).

The prerequisite is Python 3 with the Unix `fcntl` and `os` standard-library
operations used by the private helper. This decision introduces no additional
Python version floor or third-party package. Capability admission checks the
required interpreter and operations before index mutation or case dispatch.
Do not use an interpreter from an untrusted workspace or pass credentials to
this helper.

The helper opens one dedicated stable local lock inode for write access and
uses this exclusive nonblocking whole-file record lock:

```python
fcntl.lockf(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
```

Contention refuses admission; other lock errors supply unavailable evidence.
Nonblocking locking bounds contention waiting, not every filesystem syscall.
Never unlink or replace the lock inode to release it. Check the actual path,
ancestor and descriptor identities under the accepted trusted-host boundary.

Use one directly executed Python helper and a retained BEAM Port custodian for
the first unit, with no shell wrapper, fork or subprocess writer. A private
control thread may remain responsive while the serial IO thread works; both
belong to that same OS process. The custodian retains the original direct-child
exit-status route until terminal observation. Lost custody is unproved cleanup.

The same OS process holds the lock descriptor and performs all index reads,
appends and syncs covered by it. POSIX locks are not inherited across fork.
Do not place the lock in a parent while an unprotected child performs IO.
Closing any descriptor for the lock inode in the holding process releases its
process-associated locks; retain one private lock descriptor and avoid aliases.
A helper's death releases its lock but proves neither fsync success nor the
absence of a possibly consumed case.

Elixir owns the accepted closed body/frame validation, full-chain replay,
greatest committed head, campaign designation and dispatch admission. The
private helper returns physical IO evidence and carries exact validated bytes;
it does not become another event codec or assign verdicts. Its bounded private
request mechanics remain implementation work under the accepted M7 procedure.
No persistent schema or public method is introduced by this dependency choice.

Capture each invocation's work and cleanup cutoffs once within its committed
finite enclosing budget. Neither lock acquisition, reads, append, sync nor
retirement renews them. This proposal supplies no new numeric allowance.
Retain the 65,536-byte record limit and refuse uncertain or incomplete appends
until the original index is exclusively resolved. Never truncate a tail or
start a replacement campaign merely because acknowledgement was lost.

Success requires the complete append and native fsync before acknowledgement
or dispatch, while the original owner and original work allowance remain valid.
Use unbuffered descriptor IO, or prove every buffered flush before fsync. See
[Python fsync](https://docs.python.org/3.11/library/os.html#os.fsync).

Ordinary cleanup requires positive original descriptor-close evidence and the
actual native IO owner's exact exit for this first unit. Port DOWN, EOF and `port_close`
alone do not prove that owner or its descriptors are gone. A direct helper's
original exit-status observation must be distinguished from a wrapper's exit;
see [OTP Port semantics](https://www.erlang.org/docs/27/apps/erts/erlang.html#open_port/2).
If a custodian has a child, its original exact-child wait supplies physical
join evidence. A numeric process-table observation is insufficient.

A blocked filesystem syscall may outlive the application allowance. At cutoff,
stop acknowledgement and further dispatch, retain the original cleanup bounds,
and seek physical retirement through the retained owner. If it is unproved,
report unavailable cleanup and retain the affected writer fence and custody.
Lock reacquisition alone is insufficient: an alias close can release a lock
while the process still has live IO. No forced-close or fresh-owner shortcut
may turn uncertainty into success.

<a id="technical-adr-0065-options"></a>
### Alternatives and qualification

Concept: [Options and consequences](0065-private-attempts-io-prerequisite.md#concept-adr-0065-options).

The utility alternative needs explicit Darwin `lockf` and Linux `flock`
prerequisites plus platform-specific descriptor, wrapper and child-death proofs.
The native alternative needs compiler and artifact packaging decisions.
Neither is an implicit fallback if Python admission fails.

After acceptance, update DEVELOPMENT.md and the affected direct M7 preflight
and physical tests to state the prerequisite. Preserve unrelated direct lanes'
no-Python behavior. Absence or unsupported capability must fail before index
mutation or actual case execution, without skipping a required test.

Qualify real independent VM/native-process contenders on Darwin and Linux:
exclusive lock contention, actual IO-owner crash and reacquisition, stable inode
identity, alias-close and fork controls, complete history and original head,
append/fsync holds without acknowledgement or dispatch, caller/Port/native-owner
loss, normal cleanup and honest uncertain cleanup. Preserve original finite
work/cleanup allowances. Do not replace physical lock tests with a VM mutex or
fake callback. Current and floor toolchain proofs remain required.

The first helper unit remains separate from whole two-host handoff, retained
source revocation, manifest execution authority, independent clients and paid
runner activation. Its passing tests cannot close those T14 obligations.

<a id="technical-adr-0065-current"></a>
### Current format and rollback

Concept: [Current contract and rollback](0065-private-attempts-io-prerequisite.md#concept-adr-0065-current).

Keep ADR 0057's exact current event union and the accepted envelope/digest
recipe. No Python codec, older-index compatibility or persistent dependency
marker is needed. Dependency admission precedes opening the physical writer;
current-format replay, complete history and conservative uncertainty remain.

Before rollback, quiesce original live resources and retain unresolved cleanup
custody. Removing a source path does not erase a consumed attempt or prove a
native writer gone. A source rollback may remove the helper only with indexed M7 execution disabled
until an accepted, qualified replacement exists. Retained records are unchanged;
no unlocked append, stale marker removal, history rewrite or cross-version
migration is authorized. Acceptance does not waive any existing physical,
handoff, authority or closure proof.
