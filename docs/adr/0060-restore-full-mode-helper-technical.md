<a id="technical-depth"></a>
## Technical depth

Concept: [Restore full-mode helper](0060-restore-full-mode-helper.md#concept).

<a id="technical-adr-0060-purpose"></a>
### Evidence and exact source placement

Concept: [Preserve the complete permission mode](0060-restore-full-mode-helper.md#concept-adr-0060-purpose).

ADR 0051's [complete baseline](0051-current-format-physical-restore-technical.md#technical-adr-0051-placement)
requires full `lstat.mode & 0o7777`, domain 0..4095, root/hidden/empty entries and
no exclusions. Its [lifetime contract](0051-current-format-physical-restore-technical.md#technical-adr-0051-lifetime)
requires original ownership and joined IO. This proposal amends only the latter's
native-only resource scope to admit the fixed subprocess operation below. No
accepted file, receipt, intent, lineage, claim or public codec is rewritten.

Exact [OTP 29.0.5 Unix setter](https://github.com/erlang/otp/blob/OTP-29.0.5/erts/emulator/nifs/unix/unix_prim_file.c#L769)
ANDs the supplied mode with a mask that lacks `S_ISVTX`, then calls path chmod.
That applies to regular files as well as directories. Its fallback also clears
set-ID bits. The [common NIF](https://github.com/erlang/otp/blob/OTP-29.0.5/erts/emulator/nifs/common/prim_file_nif.c#L976)
adds no alternate sticky flag. Exact floor C retrieval was unavailable; current
C evidence is not substituted for that missing audit. Actual original15682
observations on both pairs on Darwin show all three native setters returning
success with requested directory `01750` observed as `0750`. Regular `04750`
set after payload survives native sync/close. These observations do not prove
sticky-file success, Linux behavior or helper lifetime.

Retained observations, under
`/Users/spuri/projects/lexlapax/loopex-evidence/M7/restore-native-mode-probe-20261007-v1`:

| Artifact | SHA-256 |
| --- | --- |
| original-collection.json | `cd95916b5e1f40d0694f956d099e36040a780283d010d55affedfeca8d1000cc` |
| terminal.json | `5ba35154bfceaf75b54c44be92391f5eed7ce013acfc2c561a940e01b5ea8bd3` |
| current-restore-native-mode-probe.log | `43f9722d41c2bf54e74e49d5e1cf4818af16e8bbc3e8912cdaa1577de8027520` |
| floor-restore-native-mode-probe.log | `d81ccab6772574587cc5d850d98f3e3fe06043ac53649733f00d7fe5f3828e6a` |

Each pair has 191 observation rows with original worker joins. Read-only source
review `/private/tmp/m7-restore-sticky-native-source-review-20261007-v1.md`, SHA
`32d18a229e9f23b16424a36c38144f3f6031e865848d9f07df3c89408587173f`,
and placement review `/private/tmp/m7-restore-native-mode-placement-review-20261007-v1.md`,
SHA `90d51bd044901ef82c4ff0b0b201b5f19b89257b0209e30d625063283a414c81`,
retain the detailed source cuts and evidence limits. The earlier decision
`/private/tmp/m7-restore-directory-mode-decision-20261007-v1.md`, SHA
`0a722e1c9e9ae57e8d3e8984a6ade4fa2a615885015eaa2965303c9bb260a82e`,
was directory-scoped. This pair corrects that scope explicitly to sticky files
and imported generation replacements; none of those packets grants acceptance.

The bounded `04750` repair at `768b2191b0bc9a9b02b70d3c78f97b579320cfaf`
passed original66773, all175 selected cases on each pair including three
long-bound cases, zero exclusions/skips/invalid. Its collected output is
`/Users/spuri/projects/lexlapax/loopex-evidence/M7/restore-copy-admission-proof-20261007-v1`:
collection `9a58b2a97a1b6f5696b483878ea42667dbbe2170b1b18a201560ea18d371abf1`,
terminal `fb825b2d4ba3aa40a31e9902aa0b03b4add58a1488385f66c38809890cc19c0d`.
Its 247.849 seconds/eight original joins are historical evidence for that
regular-file ordering repair, not this helper or every mode combination.

Current `Restore.IO` already owns native descriptor tokens and issued/permit/ack
operations through `primitive/2` and `await_permit/7`. `copy_file`, `publish` and
`retained_publication_create` reapply mode after their last write. The helper
belongs at those final sticky-mode cuts and `set_directory_mode`; Workflow keeps
its existing bottom-up directory pass and complete equality before intent.
Initial configuration/readback must distinguish the intended temporary
nonsticky staging mode from the exact required final mode, without weakening
inode/type/link/size/descriptor checks or admitting temporary mode into a manifest.

Local's `answer_within/3` hides original Port/guard ownership, returns
`:no_answer` for missing answer and cleanup uncertainty, and reconstructs a
relative bound. Do not call it here. Its fixed carrier/guard ordering may inform
private implementation, but no Local module dependency or API promotion is
selected. [ADR 0022](0022-local-executor-supervision-shell.md#concept) scopes its
Bash prerequisite to Local; this pair independently proposes Composition's
profile. A small private helper module is justified only if it keeps this
concrete resource inventory visible; no generic subprocess service is authorized.

<a id="technical-adr-0060-profile"></a>
### Executable and first-image admission

Concept: [Fixed prerequisites and host trust](0060-restore-full-mode-helper.md#concept-adr-0060-profile).

Use only absolute `/usr/bin/env`, `/bin/bash`, `/bin/chmod`, `/bin/ps`. Require
regular executable endpoints with root-owned, non-group/world-writable trusted
system ancestry. Resolve only system symlinks, at most16 hops, at most64
ancestors; reject loops, changes and workspace resolution. Paths retain ADR
0051's 8,192-byte UTF-8 ceiling. Capture device, inode, type, link/size/mode and
streaming SHA-256 for each endpoint, at most16 MiB each in at most65,536-byte
reads, under the original work cutoff. Recheck placement and captured bytes
before launch. No global executable registry or repository-wide binary SHA is
selected; retain exact qualified OS executable identities in evidence.

At the Port boundary remove all inherited environment entries before the first
`env` image, including loader variables, `BASH_ENV`, `ENV`, PATH, HOME and
credential variables. Enumerate at most4,096 names/1 MiB, with each name at
most128 bytes and each value at most8,192 bytes; overflow refuses rather than
retaining unknown ambient entries. Host excludes environment changes across
capture/spawn. Do not change global VM environment. The downstream environment
contains only `LC_ALL=C`; every program path is absolute. `env -i` constructs
that downstream environment but does not replace first-image clearing.
Bash uses fixed reviewed source and noninteractive `--noprofile --norc` behavior.

Use a checked existing private administrative claim directory as cwd, outside
payload trees. Recheck its original native identity; do not add cwd files or
manifest exclusions. Paths and modes are separate literal arguments, never
interpolated into shell source. Chmod receives one canonical octal mode in
`0000..7777` and one already-expanded absolute path. No symbolic modes,
recursive flags, custom environment or command text are accepted. Execute only
when `mode & 0o1000 != 0`; other modes retain native handling and full readback.
The loader, shared libraries and invoking trusted host remain outside hostile
replacement isolation. This is a dependency prerequisite, not an elevation.

Bind the mode/path to the validated destination baseline entry or exact
original-ordinal generation temporary file; no source, backup, workspace or
arbitrary target is eligible. Capture that destination target, all checked
ancestors and participating roots before permit. Hold its original raw file
or directory descriptor. Refuse
symlinks, wrong type, regular nlink other than1 and changed native identity.
Recheck all of them after child completion. Full path/descriptor readback and
sync are necessary but path chmod cannot atomically compare inode and mutate.
Host exclusion is the accepted prerequisite for that race; do not claim a
malicious rename is harmless or repaired afterward.

<a id="technical-adr-0060-custody"></a>
### Custody, permits and finite observations

Concept: [Original resources and one deadline](0060-restore-full-mode-helper.md#concept-adr-0060-custody).

Extend the existing guardian's private volatile inventory, not a durable record
or public DTO. Install original monitors and a pending resource token before
launch. Capture/adopt the original Port and OS identity as launch returns, before
any mutation permit. Launch/capture is owned work with no mutation authority.
A capture gap preserves uncertainty rather than fabricating a joined resource.
The fixed process family is:

1. Port-owned carrier, captured from actual Port OS identity.
2. Group guard, captured through token-bound ready evidence and parent/group
   observations. It stays a live member until child/wrapper joins and release.
3. Status wrapper, the direct parent that owns the exact child's wait.
4. Gated child, captured before mutation and exec-replaced by fixed chmod.

Carrier and guard ordering must keep EOF cleanup possible if the Port owner
or carrier dies. The wrapper must capture actual wait results without retrying
an interrupted wait as a new child. Child/wrapper/control identities and
sequence are acknowledged by the guardian before a single mutation permit.
Use an invocation-private 32-byte random token, represented by64 hex bytes,
over private control descriptors, never argv/environment. Close private
control descriptors in the chmod image. Ready frames cannot themselves permit
mutation. The guardian verifies original owner/reference/operation/sequence,
work cutoff and captured native target before it issues that permit.

Control frame≤1,024 bytes, at most32 frames per helper; total helper output≤
65,536 bytes, including protocol and ordinary error output. Keep output private;
no raw path, credential, shell transcript or process table enters public,
progress, diagnostic or durable planes. Bound capture and discard whole
oversized output; incomplete custody never becomes success. The implementation
must demonstrate these bounds at its actual Port delivery/collector boundary,
not merely cap a later decoded list.

Use at most three serial observers, one live at a time. Each is one direct
fixed exec chain `env`→Bash→`exec /bin/ps`, no fork, descendants or recursive
observer. Guardian owns its original Port/OS identity before allowing the
fixed read. No observer can chmod or issue a group signal. Command:

```text
/bin/ps -e -o pid= -o ppid= -o pgid=
```

Parse only complete ASCII decimal triples, positive uint64 PID and uint64
PPID/PGID, no duplicate PID. The captured mutation group must be positive;
zero parent/group values for unrelated system rows grant no authority. Require EOF, status0, exact original wait and closed
Port. Enforce 4 MiB overall, 65,536 rows, 64 bytes per row including newline,
and ancestry walk depth≤64 with no cycle. At any cap/parse/ownership failure,
stop admitting work and retain uncertainty; never truncate the table and call
it empty. The three snapshots are:

| Cut | Required observation |
| --- | --- |
| Before mutation | Exact captured gated child/wrapper/guard/carrier parent and group relationships. No unknown mutation-group member; child has not been permitted. |
| After child/wrapper waits, before release | Actual original child/wrapper wait evidence plus complete table showing both absent; the captured guard remains the signal anchor, with only originally captured carrier/guard group membership permitted. |
| After original carrier/Port wait and close | Original carrier/guard/wrapper/child PIDs absent and original mutation group empty, with complete observer joins. |

Do not infer identity from a generic PID match or infer absence from a signal,
DOWN, exit frame or Port close. Captures bind original parent/Port/nonce lifetime.
Keep signal authority in an original live member; never launch a later killer
against a detached numeric group. If the guard disappears, any uncertain or
reused identity/group remains unconfirmed. Reused matching numeric IDs in the
final table refuse clean completion instead of treating unrelated members as
old authority or omitting them. Snapshot evidence supplements actual original
waits; it cannot replace a missing child/wrapper wait after forced group loss.

At most4 mutation actors plus3 serial observers are created per helper:7 total,
5 simultaneously. Let N be complete baseline entries and L replaced ledger
generations. Helpers≤N+L≤65,536+128=65,664; observers≤3(N+L)≤196,992. Each entry's
final mode is attempted once in this invocation. No observation retry or
helper relaunch obtains another slot or budget. A later original-tx invocation
is separately admissible only under unchanged ADR0051 prior-authority rules.
Capture executable data once per invocation and recheck before each spawn; keep
only the currently owned family and finite counters, not every exited process.
All count/byte arithmetic is checked. The selected deadline may expire well
before these maximum counts; that is truthful refusal/uncertainty, not a
promise to finish the maximum manifest.

The helper never constructs `now + work_ms` or a fresh per-observer grace.
Reuse exactly:

```text
work_cutoff = original_t0 + work_ms
cooperative_cutoff = first_stop_s + cleanup_grace_ms
cleanup_cutoff = first_stop_s + max(10000, cleanup_grace_ms + 2000)
```

All preparation/snapshots and new payload permits use the work endpoint.
Normal completion, refusal, cancellation, caller loss or expiry captures one
terminal stop. At that stop reject further chmod permits. Cleanup observations,
carrier/group termination, descriptor closes and claim release share the one
cleanup endpoint. Any relative Bash wait is bounded by the remaining captured
absolute endpoint; delivery never resets it. EOF and owner loss use the same
owned termination route, not a refreshed shell timeout. A killed original
waiter without complete child evidence leaves uncertainty even if a later
snapshot is empty. Never infer clean shutdown from KILL delivery.

<a id="technical-adr-0060-truth"></a>
### Readback, cleanup and refusal mapping

Concept: [Outcomes and continued exclusion](0060-restore-full-mode-helper.md#concept-adr-0060-truth).

After child success and joins, compare original descriptor and path identity,
full `0o7777` mode, file length/hash and unchanged roots/ancestors. For files,
perform the final mode after all writes, before native file sync/close and
parent sync; retain temporary publication, atomic rename and exact readback.
For directories, retain bottom-up order after all child copies, then exact mode,
directory/parent sync and descriptor close. No later payload write can follow
an imported file's final chmod without another governed final-mode obligation.
Complete baseline equality and all allowed final administrative transformation
checks remain unchanged; generation mode is imported baseline mode.

Use the existing issued/acknowledged operation protocol. Helper evidence means
the exact helper/observer resources joined and full-mode readback completed
within the original cutoff. A file descriptor remains owned until its native
sync/close; helper evidence cannot acknowledge the containing copy/publication
as complete before that. Clean terminal completion still requires every raw
descriptor close and the original worker join. Child exit0 alone proves none
of those duties.
If first-image/executable admission fails and cleanup joins before intent,
Workflow uses its existing `inventory_unavailable` mapping; full readback
mismatch uses existing `inventory_mismatch`. No new refusal/reason enum is
introduced. Later possible intent preserves `commit_unknown`. Any unjoined
resource preserves `cleanup_unconfirmed` before intent and retained claims;
lookup remains bounded read-only and never starts this helper.

Claim release still uses the existing terminal worker only after payload
resources are accounted for, under the same cutoff. If helper evidence cannot
be delivered after guardian death, preserve the original authority uncertainty
and host exclusion; do not manufacture successful cleanup in a replacement
process. Prior authority must be positively joined or covered by the existing
host-reboot evidence before original-tx continuation. No new session/executor
epoch, effect receipt, workspace identity or retained job deadline is created.

<a id="technical-adr-0060-alternatives"></a>
### Alternatives, amendment and rollback mechanics

Concept: [Alternatives and current-format rollback](0060-restore-full-mode-helper.md#concept-adr-0060-alternatives).

Acceptance narrowly amends ADR0051 administrative ownership/dependency scope.
Do not rewrite its historical pair. At acceptance annotate its index row as
amended and bind this exact Proposed pair through the normal governance record.
This draft leaves ADR0051's current index status untouched. Implementation must
stay private to Composition Restore, with inward dependencies; no Local grant,
model tool, generic launcher, public method or persistent schema is implied.

Native-only refusal preserves truthful preactivation equality but leaves the
promised full-mode outcome incomplete. Removing `0o1000`, masking modes to0777
or excluding entries would change an accepted outcome and is not this option.
A custom native binding/patched OTP needs its own accepted compilation,
packaging, dependency, VM-safety and supported-build decision; no alternate
unmodified native setter is established by the retained research.

Current-format rollback may stop new affected operations after all original
resources are joined. It never undoes one-way source retirement, deletes sole
uncertainty evidence or authorizes old-root activation. Keep current restore
records/receipt/lineage readers and original-tx resolution unchanged. No
superseded-format compatibility lane, new recovery authority or cross-version
migration is added. An unavailable profile refuses affected restore rather
than silently selecting arbitrary executables or falling back to lossy modes.

<a id="technical-adr-0060-proof"></a>
### Qualification matrix and retained evidence

Concept: [Acceptance and required proof](0060-restore-full-mode-helper.md#concept-adr-0060-proof).

After exact acceptance and source review, prove the following with actual
system executables, owned temporary roots and no terminal on Darwin and native
Linux, each under OTP29.0.5/Elixir1.20.3 and OTP27.3.4/Elixir1.18.5:

- First-image environment recorder, downstream absence of startup/loader/
  credential values, fixed argv, executable capture/replacement/size/symlink
  refusals, hostile path characters and changed root/ancestor/target checks.
- Actual prepermit Port/group/child/observer captures, authenticated gate and
  exactly one chmod; no source, backup, workspace or unmatched-target mutation.
- Full native directory/file sticky observations, including imported generation
  replacements, combined set-ID/sticky bits, root/nested/empty directories,
  nonempty streamed files and exact complete pre-intent/final manifests. All
  admitted mode values retain full domain0..4095; do not claim every physical
  combination supported from one04750/01750 example. Unsupported filesystem or
  permission behavior must refuse truthfully and is not preservation evidence.
- Three complete finite snapshots, malformed/truncated/overflow/depth/duplicate
  controls, original waits/EOF/close, parent/group mismatch and reuse controls.
  Every observer joins; a snapshot is never a recursive cleanup prerequisite.
- Caller/guardian/carrier/guard/wrapper/child/observer loss, suspended actor,
  blocked syscall, EOF, late ready/result, failed launch/wait/close and forced
  cancellation. Missing waits remain unknown; no post-clean-terminal mutation.
- Original absolute work/grace endpoints under timely and late native IO,
  all original monitors, clean normal completion and terminal claim release;
  no timeout inflation, retry, fake IO, Logger suppression or proof by liveness.
- Existing complete IO/publication/install/prefix populations including all
  three long-bound cases, followed by complete public restore/recovery proof.
  Preserve existing 10,000ms work/1,000ms grace per restore and 600,000ms
  aggregate for the complete64-restore proof, and each fixture's original bound.
  Preserve source/backup unexcluded bytes/modes, allowed administrative changes,
  same physical workspace, settled/unknown receipts and zero effect redispatch.

Retain exact candidate/executable identities, original actor/resource evidence,
raw results/timelines, actual toolchains/platforms, complete manifests and
cleanup outcomes before disposing of fixtures. Source-only preparation proves
none of these runtime obligations. Native Linux qualification, sticky physical
restore and this helper lifetime remain unavailable at this Proposed candidate.
Helper-ledger semantic acceptance, remote creation, event grammar and bounded
progress delivery belong to their own decisions; acceptance here activates none
of them and cannot close all of T15 or M7.
