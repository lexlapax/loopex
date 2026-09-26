<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon-grade store engine and migration](0036-daemon-grade-store-engine-and-migration.md#concept).

<a id="technical-adr-0036-decision"></a>
### Selection Procedure

Concept: [Context and decision](0036-daemon-grade-store-engine-and-migration.md#concept-adr-0036-decision).

**What stays fixed.** The `Loopex.Store` behaviour, its transaction and
`commit_unknown` semantics, the result unions the coordinator reads, and the
shared conformance suite in `apps/loopex/test/support` that `Loopex.Store.Local`
and `Loopex.M1RuntimeTestStore` already run. The adapter is one new
application, `loopex_store_indexed` or the name the experiment record settles,
with role `:store`, depending inward on core and nothing else in the umbrella;
`mix loopex.deps_budget` and its cases change in the same reviewed change that
adds it, exactly as M5 added `loopex_daemon`. Core's dependency list stays
`:telemetry` alone.

**Candidates.** Three, measured on identical fixtures:

| Candidate | What it is | Dependency cost |
| --- | --- | --- |
| A. Segmented indexed log | The existing append-only record format split into bounded segments, one durable index of session heads and record offsets, and compaction of sealed segments; pure Elixir on `:file` and `:disk_log`-free primitives | None |
| B. SQLite | One database file per root through a NIF-backed library, records as rows, the index as tables | A native dependency in the adapter application, a compiler at build time, per-platform binaries in the release |
| C. OTP-native tables | `:dets` or Mnesia disc copies | None, but `:dets` carries a 2 GiB file limit and repair-on-open costs that replace one ceiling with another |

**Measurements**, each retained with the toolchain pair, platform and fixture
identity:

1. Open time and memory for roots of 1,000, 10,000 and 100,000 sessions, and
   for one session of 100,000 records, against a stated bound of two seconds
   to serve the first attach on the release host class.
2. Append latency at the 4 MiB frame ceiling and at a 64 KiB typical frame,
   under one writer, with `fsync` semantics stated per candidate.
3. Replay of one session at cursor offsets 0, mid and tail, against the
   at-least-once contiguous contract ADR 0032 fixes.
4. The fault matrix: kill during append, kill during segment seal or
   checkpoint, disk-full on append, disk-full on index write, torn last
   record; every injection answers as the conformance suite requires and no
   injection produces a silent partial commit.
5. Capacity behaviour: the definite, survivable refusal at a configured
   ceiling, proved through the same fault matrix on the local adapter too, so
   the separated error class is shown definite on every adapter.
6. Migration time and peak disk usage for the largest fixture, and the
   interrupted-migration matrix below.

**Selection rule.** Candidate A is selected if it meets every bound;
candidate B is selected only if A fails a bound that B meets, and that
selection carries the dependency decision in the same acceptance; candidate C
is recorded as measured and not selected unless both fail. The maintainer
accepts this pair with the engine cell filled from the retained record and the
record's reference and SHA-256 digest in this section.

<a id="technical-adr-0036-migration"></a>
### Migration and Interrupted-Import Contract

Concept: [Observable consequences](0036-daemon-grade-store-engine-and-migration.md#concept-adr-0036-consequences).

`loopex store migrate <root>` is explicit, offline and idempotent:

1. It refuses while the placement lock or the writer marker is held, with the
   same classes the daemon's startup uses.
2. It reads the `0.2` root through the local adapter's own reader, never a
   private copy of the format, so a record the local adapter cannot read is a
   refusal before any write.
3. It writes the target beside the source under a fixed temporary name, then
   verifies it by replaying every session from the target and comparing
   session heads, record counts and per-record digests with the source.
4. Only after verification does it publish the target with one atomic rename
   and retire the source under a fixed archive name that `loopex store restore`
   accepts. Nothing deletes the source.
5. A migration interrupted at any point converges on the next run: a partial
   target is detected by a marker written first and removed last, and is
   discarded and rebuilt; a verified-but-unpublished target is published; a
   published target with a retained source is complete.

The interrupted-migration matrix forces a kill before the marker, during
target writes, after verification, between rename and source retirement, and
after completion, and asserts the converged state and the exit class of the
next run in each case.

**Reader boundary.** The root carries a format version file written last. A
`0.2` reader that opens a `0.3` root refuses with `store_format_unsupported`,
a class M5's exit-status map does not carry and M7 adds; it writes nothing.
The `0.3` reader opens `0.2` roots read-only for `loopex doctor` and the
listing, and refuses to serve sessions from one until migrated.

**Backup and restore.** `loopex store backup <root> <archive>` produces one
archive of a closed root with a manifest of every file, its size and SHA-256,
the format version and the source commit that produced it; `loopex store
restore <archive> <root>` refuses a non-empty target, verifies every digest,
and restores atomically. Rollback is `restore` of the pre-migration backup
under the previous release, and the plan proves it.

<a id="technical-adr-0036-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Compatibility and rollback](0036-daemon-grade-store-engine-and-migration.md#concept-adr-0036-compatibility).

The vision's migration list is discharged item by item in the technical plan
of the milestone that ships the engine: source and target versions, forward
migration, interrupted detection and recovery, backup/restore as downgrade
policy, the previous-binary boundary, and the packaged rollback procedure.
M7's technical plan discharges the items that apply to `0.4.0`'s unchanged
format and marks the rest not applicable until then. Extension-state fixtures
do not apply; no extension state exists.

**Alternatives rejected.**

- *Raising the local log's capacity* trades a truthful refusal for unbounded
  replay at open; ADR 0031 rejected it and the reason stands.
- *Migrating on first open* hides a long, failure-prone write inside a command
  the operator thinks is a read, and makes an interrupted migration
  indistinguishable from a crash.
- *A new public journal schema* is not needed: the record content and the
  public event families are unchanged; only the container changes.
- *Deciding the engine here* was rejected for the reason ADR 0031 gave when it
  withdrew its own successor half.

**Open before acceptance.** The engine cell and the retained experiment record
it cites; the adapter application's name; the exact capacity ceiling the
definite refusal enforces and how the operator configures it, which ADR 0037's
schema carries once this pair names the key.
