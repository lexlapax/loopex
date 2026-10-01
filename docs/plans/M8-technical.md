<a id="technical-depth"></a>
## Technical depth

Concept: [M8 installed durable operator](M8.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M8.md#concept-plan-purpose).

Concept: [Design decisions](M8.md#concept-plan-decisions).

M7 closes first. Its exact implemented schema, protocol generations, provider
custody, host ledger, record inventory and source identity become M8's
baseline. M7 is Accepted and unimplemented, so this plan describes none of
those capabilities as shipped, and the status contract refuses M8's acceptance
until M7 is Closed.

| Decision | Outcomes | Acceptance point |
| --- | --- | --- |
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | 2, 4 | Freeze the discovery, writer and lifecycle grammar against delivered M7 before implementing it |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | 1, 6, 7 | Fill the pinned build recipe, allowed libraries, supported hosts and the prior build before release-build or install code |
| [ADR 0050](../adr/0050-daemon-attached-conversation.md#concept) | 4, 5 | Fill the method mapping against the delivered M7 daemon generation before the attached command or daemon configuration reader |
| [ADR 0051](../adr/0051-store-readiness-marker-backup-and-restore.md#concept) | 3, 7 | Fill the marker location, archive layout and record-capability inventory before marker, reader-boundary, backup or restore code |

Accepted [ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept)
constrains outcome 8; use its existing exact limits and refusal contract.

The store engine decision (ADR 0036) and typed policy inputs (ADR 0035) are not
M8 prerequisites and are deliberately not linked here. No typed policy input,
new credential source or publication enters through these prerequisites.
Installed version selection and any public-name clearance remain separate
decisions.

**Before acceptance.** These are planning obligations, not product proof:

1. Reconcile all four Proposed pairs with the closed M7 baseline and fill
   every cell they mark as fixed at acceptance.
2. Record the maintainer's selections for proposals P1 to P6 and choices C1 to
   C3 in the Concept plan.
3. Name the exact prior build, the supported record versions and the
   restoration tool for outcome 7.
4. Obtain independent review of the reconciled pair and its four ADR pairs.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Workstreams](M8.md#concept-plan-workstreams).

| Workstream | Owns | Rejoins at |
| --- | --- | --- |
| Integration | Launcher, discovery, configuration reader and writers, lifecycle commands, attached conversation | The first installed workflow |
| Packaging | Release recipe, manifest, companion relocation, install lane | The first installed workflow, with a locally built archive |
| Store readiness | Marker, reader boundary, backup and restore | After the first installed workflow, before the upgrade matrix |
| Transfer accounting | Outcome 8 in the daemon | Any time; it touches no other workstream's paths |

Packaging, store readiness and transfer accounting use non-overlapping paths
and one worktree per writer. One integrator owns rejoin, conflicts and
post-rejoin verification. Documentation follows the same accepted grammar as
the commands.

Constraints that hold across workstreams:

- **One resolver.** No second configuration resolver, role schema or provider
  schema. Discovery and writers wrap ADR 0049's reader.
- **One session owner.** The attached conversation is a client. It owns no
  runtime, no durable conversation state and no alternate loop.
- **Closed schema.** The M9 capacity option needs a versioned successor to ADR
  0049's closed schema or its explicit amendment. Installed discovery and
  writers refuse that future member under version 1. M8 adds no capacity
  member merely because it manages files.
- **Helper concurrency.** The delivered M7 boundary holds: one active helper
  per parent conversation, with independent parents permitted to overlap.
  Installation adds no runtime-wide slot.

<a id="technical-plan-inherited"></a>
### What M8 Inherits From M7

Concept: [Scope and non-goals](M8.md#concept-plan-scope).

M7's accepted contracts create obligations that the earlier installed-operator
draft did not carry. Each is fixed by its owning ADR before acceptance.

| M7 fact | M8 obligation | Owner |
| --- | --- | --- |
| `loopex chat` owns a foreground durable runtime; attachment is successor work | Outcome 5 maps every conversation action onto the daemon generation and the controller lease | ADR 0050 |
| The daemon keeps its existing startup grammar and reads no configuration file | The service reads ADR 0049's file at startup; a client still names no host value | ADR 0050 |
| Trace controls exist on chat, ask and daemon startup only; a client gains no trace authority | Lifecycle commands that start the service carry the daemon's trace controls; attached chat rejects them | ADR 0037 |
| Durable admission stays closed until helper-history classification completes, bounded at 60,000 ms per start and resumable | Readiness reports "serving", "classifying" with its two counts, or "closed" with the named session; start-on-demand does not report ready early | ADR 0037 |
| One unreadable session history closes the durable host until the root is restored from backup | Backup and restore exist; the diagnostic command names the session | ADR 0051 |
| The host ledger, role snapshots and child sessions live under the host root; the job index and helper coverage entries are derived caches | The backup inventory includes the first group and excludes rebuildable caches, which are rebuilt after restore | ADR 0051 |
| New record kinds: checkpoints, maintenance request, attempt and settlement records, version-3 settlements with a monotonic cutover, questions, immutable selections | The reader boundary and the upgrade matrix name each kind; no older build is assumed to refuse them | ADR 0051 |
| Foreground and daemon protocol generations are new and serve updated clients only | The Node client lane and the attached command use the delivered daemon generation | ADR 0050 |
| `config show` and chat's startup report give value origins from a closed set: `flag`, `env`, `file#pointer`, `default` and `committed` | A discovered file reuses the `file#pointer` origin; inspection also states which file was selected and why, without adding an origin member | ADR 0037 |

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M8.md#concept-plan-outcomes).

Concept: [Verification](M8.md#concept-plan-verification).

| # | Required proof | Release check |
| --- | --- | --- |
| 1 | Exact manifest and external checksum; provider companion identity verified before launch; native linkage confined to the allowed base set; install from the retained archive on a clean host of each platform; a simulated quarantined download on macOS | Yes |
| 2 | Explicit-file and discovered-file equivalence; default-home selection; per-value origins; unknown schema and unknown member refusal; atomic-write fault cuts leave prior bytes; stale-lock refusal; no credential value read during inspection | No |
| 3 | Marker commit ordering; missing-marker record-capability checks; refusal of an unknown format or unsupported record before any write; complete closed-root backup including the host ledger, role snapshots and child sessions; restore digest verification; refusal of a live root and of a nonempty target; caches rebuilt after restore | No, except the restore step of 6 and 7 |
| 4 | Concurrent start converges under existing placement ownership; readiness distinguishes serving, classifying and closed; stop drains within the existing bound; the diagnostic command reports references, marker, placement and the named unreadable session without resolving credentials; on-demand start refuses by name when a configured reference is absent | No |
| 5 | Every conversation action through a real daemon on terminal and piped input; detach leaves the run active and its identity unchanged; reconnect delivers the snapshot, contiguous events and a pending question; a killed client's lease expires and a second terminal takes over; a stale writer epoch is refused; attached chat refuses every host and trace flag; the foreground conversation refuses a root a service holds | Attended reconnect case |
| 6 | Installed real-provider workflow on each supported platform with complete output and archive evidence; an identified operator follows the runbook | Yes, attended |
| 7 | The prior build and the candidate against M6, M7 and candidate roots; unsupported reopening refused before writes where the reader can refuse; the pre-upgrade backup restored by the candidate's tool into an empty root and opened by the prior build with its facts intact | Yes |
| 8 | Extend `transfer_bound_test.exs`: one connection across several attachments shares its count and allowance, another connection stays independent; cumulative work beyond 1 GiB refuses; the daemon Node lane passes; operator and developer pages remove only the now-proved divergence | Daemon Node lane |

The two repository checks and the closure matrix apply unchanged. The evidence
page is `docs/evidence/M8-closure-runs.md`, created and indexed on its actual
candidate, with complete immutable outputs outside the repository.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Non-goals](M8.md#concept-plan-scope).

Concept: [Rollout](M8.md#concept-plan-rollout).

| Surface | Proposed boundary |
| --- | --- |
| Local storage container | Retained until M9's explicit engine migration; the marker alone proves no record compatibility |
| Durable records and host ledger | Delivered M7 versions, with explicit reader fixtures; no old-reader promise from container identity |
| Daemon protocol | The delivered M7 generation. Any method the attached conversation needs and that generation lacks is a named addition with vectors, settled in ADR 0050 before acceptance |
| Foreground protocol and embedded API | Delivered M7 contract, unchanged |
| Configuration | M7's versioned schema and resolver; discovery, writers and daemon-startup loading added by ADRs 0037 and 0050 |
| Existing commands | `run`, `resume`, `attach`, `sessions` and the foreground `chat` keep their grammar and exit semantics |
| Installed archive | New experimental packaging contract under ADR 0038 |

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Rollout and compatibility](M8.md#concept-plan-rollout).

No Store record is migrated. The candidate writes a container marker into a
supported local root without rewriting records.

Before acceptance, fill the source and target build identities, the supported
record versions, the marker and the restoration tool. Fixtures include roots
with M7 model and instruction configuration, compaction checkpoints, text and
declined questions and delegated work, including unresolved operations where
safe fixtures can establish recovery.

Validate unknown formats and records before writes in the new reader. Test
prior readers as they exist, not as this plan wishes them to behave. Where a
prior build cannot safely reject a newer root, the runbook prevents the
reopening and restores the pre-upgrade backup into a separate empty root.
Never remove new records to make an old build start. Verify backup manifests,
exact record order and digests, and the matching reader's behavior.

The prior build for outcome 7 is the closed M7 source build. It has no
installed layout and no restore command, so restoration uses the candidate's
tool and produces an ordinary root layout that build opens. Upgrade between
two installed releases needs a second installed release and is not claimed
here. Engine migration and interrupted import are M9 work.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M8.md#concept-plan-scope).

ADR 0038 owns the platform-specific OTP archive, bundled ERTS, relative
provider companion lookup and manifest. A release label is selected at M8
acceptance and then used consistently in `VERSION`, the build layout and the
artifacts. M6's released `0.3.0` is not repurposed, and no label is assumed to
be free after M7. No dependency framework, configuration library or service
layer is implied. Any native dependency is owned by its adapter and included
in the pinned build and linkage proof. Service-manager units, distribution
packages and publication are outside M8.
