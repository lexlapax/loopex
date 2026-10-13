<a id="technical-depth"></a>
## Technical depth

Concept: [M8 installed durable operator](M8.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M8.md#concept-plan-purpose).

Concept: [Design decisions](M8.md#concept-plan-decisions).

M7 is Closed. Its closure row names tested implementation commit
`70ed6675`, and tag `v0.4.0` names administrative closure commit `9fe9618b`;
`VERSION` still reads `0.3.0`. Its implemented schema,
wire generations, provider custody, host ledger, record inventory, restore
transition and source identity are M8's baseline, as delivered rather than as
planned.

| Decision | Outcomes | Acceptance point |
| --- | --- | --- |
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | 2, 4 | Freeze the discovery, writer, lifecycle and readiness grammar against the delivered CLI and daemon before implementing it |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | 1, 6, 7 | Fill the pinned build recipe, allowed libraries and each host's minimum base from the retained build before release-build or install code |
| [ADR 0071](../adr/0071-daemon-attached-conversation.md#concept) | 4, 5 | Fill the method mapping against `loopex.experimental/4` and the daemon's configuration rules before the attached command or daemon configuration reader |
| [ADR 0072](../adr/0072-store-readiness-marker-backup-and-restore.md#concept) | 3, 7 | Fill the marker name and bytes, the backup layout and capture record, and the restore command's plan construction before marker, backup or restore code |

Accepted decisions constrain M8 without being reopened:
[ADR 0051](../adr/0051-current-format-physical-restore.md#concept) owns the
restore transition, its inputs, limits and outcomes;
[ADR 0066](../adr/0066-owned-artifact-transfer-opening.md#concept) owns
transfer accounting; and
[ADR 0070](../adr/0070-pre-1-superseded-surface-retirement.md#concept) owns
the retired surfaces.

The store engine decision (ADR 0036) and typed policy inputs (ADR 0035) are not
M8 prerequisites and are deliberately not linked here; the first follows from
proposal P2. No typed policy input, new credential source or publication
enters through these prerequisites. Public-name clearance remains a separate
decision.

**Before acceptance.** These are planning obligations, not product proof:

1. Fill every cell the four Proposed pairs mark as fixed at acceptance,
   against the delivered M7 code.
2. Record the maintainer's selections for proposals P1, P2 and P4 to P8 in the
   Concept plan. Decisions D1 to D4 are already recorded; P3 is superseded.
3. Obtain independent review of the reconciled pair and its four ADR pairs.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Workstreams](M8.md#concept-plan-workstreams).

| Workstream | Owns | Rejoins at |
| --- | --- | --- |
| Integration | Launcher, discovery, configuration reader and writers, lifecycle commands, readiness, attached conversation | The first installed workflow |
| Packaging | Release recipe, manifest, companion relocation, install lane | The first installed workflow, with a locally built archive |
| Backup and restore | Current-format marker, backup producer, `store backup` and `store restore` over ADR 0051 | After the first installed workflow, before the installed demonstration |

Packaging and backup and restore use non-overlapping paths and one worktree
per writer. One integrator owns rejoin, conflicts and post-rejoin
verification. Documentation follows the same accepted grammar as the commands.

Constraints that hold across workstreams:

- **One resolver.** No second configuration resolver, role schema or provider
  schema. Discovery and writers wrap ADR 0049's reader.
- **One session owner.** The attached conversation is a client. It owns no
  runtime, no durable conversation state and no alternate loop.
- **One restore.** The restore command calls
  `LoopexComposition.Restore.restore/2` and `lookup/3`. It adds no second copy
  or audit of the root format and no second transition.
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

Each delivered fact creates an obligation that its owning ADR fixes before
acceptance.

| Delivered M7 fact | M8 obligation | Owner |
| --- | --- | --- |
| `loopex chat` owns a foreground durable runtime and accepts no daemon socket | Outcome 5 maps every conversation action onto `loopex.experimental/4` and the controller lease | ADR 0071 |
| The foreground server serves only `loopex.experimental/3`; the daemon serves only `loopex.experimental/4`, whose methods include `session.acquire_control`, `session.release_control`, `session.configure` and `session.compact` | The attached command and the Node client lane use `/4`; a method it lacks is a named addition with vectors | ADR 0071 |
| Daemon clients detach and reattach at a cursor without cancelling the run, proved by `m7.daemon-detach` | The attached conversation reuses that path; quitting, end of input and interrupt detach | ADR 0071 |
| The daemon's startup flags are `--state-root`, `--workspace`, `--provider-launch`, `--policy`, `--cleanup-grace-ms` and `--socket`, with environment fallbacks; it reads one credential from `LOOPEX_PROVIDER_API_KEY` into ADR 0070's one-route plane and reads no configuration file | The service reads ADR 0049's file at startup; a client still names no host value; each flag, environment input and the single credential get explicit rules under a file | ADR 0071 |
| The foreground conversation aborts active work on quit, end of input and interrupt | Attached, the same three detach and the run continues, as existing daemon commands do on a signal | ADR 0071 |
| The daemon asks about a workspace `AGENTS.md` before it listens, and no flag admits project resources non-interactively | A start on demand does not prompt and leaves them unadmitted, and readiness says so | ADR 0037 |
| The daemon activates at most 64 sessions per lifetime | Unchanged; the refusal is shown to the operator and documented for a long-running service | ADR 0071 |
| Trace controls exist on `chat` and `ask` only; the daemon exposes none, and a client gains no trace authority | Any service trace control comes from the service's own startup inputs; attached chat rejects trace flags | ADR 0037 |
| Durable admission stays closed until helper-history classification completes, bounded at 60,000 ms per start and resumable | Readiness reports "serving", "classifying" with its two counts, "closed" with the named session, or "unavailable" with a code and no session; start-on-demand does not report ready early | ADR 0037 |
| One unreadable session history closes the durable host until the root is restored from backup | The backup and restore commands exist; the service's readiness report names the session | ADR 0072 |
| ADR 0051 delivers host-embedded `LoopexComposition.Restore.restore/2` and `lookup/3` from a complete, unexcluded, idle backup copy into an empty root on the same machine. The host owns backup creation, the capture record, plan construction and the attestation; there is no backup or restore command | `store backup` produces that backup and capture record; `store restore` builds the plan and calls the delivered functions | ADR 0072 |
| Session replay refuses a record kind outside the current inventory as `invalid_private_history`; a root with only the retired session catalogue is refused (`session_catalog_retired`, exit 85); `daemon prepare-index` is gone | No second record inventory. The refusal of an unsupported root moves before any write, because the Store takes its writer marker and may repair a torn tail before replay | ADR 0072 |
| Per-connection transfer accounting with a 1,073,741,824-byte cumulative allowance is enforced under ADR 0066 | None; the earlier outcome 8 is dropped | — |
| `config show` and chat's startup report give value origins from a closed set: `flag`, `env`, `file#pointer`, `default` and `committed` | A discovered file reuses the `file#pointer` origin; inspection also states which file was selected and why, without adding an origin member | ADR 0037 |

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M8.md#concept-plan-outcomes).

Concept: [Verification](M8.md#concept-plan-verification).

| # | Required proof | Release check |
| --- | --- | --- |
| 1 | Exact manifest and external checksum; provider companion identity verified before launch; native linkage confined to the allowed base set; install from the retained archive on a clean `darwin-arm64` host and a clean Ubuntu 22.04 `linux-x86_64` container; a simulated quarantined download on macOS cleared by the documented step | Yes |
| 2 | Explicit-file and discovered-file equivalence; default-home selection; per-value origins; unknown schema and unknown member refusal; atomic-write fault cuts leave prior bytes; stale-lock refusal; no credential value read during inspection | No |
| 3 | `store backup` refuses a held root and a remaining writer marker; its backup's complete canonical manifest equals an independent walk of the source; `store restore` returns ADR 0051's committed receipt into an empty root, and refuses a nonempty target, a changed backup and a held source; an interrupted restore resolves through the same transaction; a restored root starts with no preparation step; a root with one unreadable session history is named by the readiness report and serves again after restore of an earlier backup | No, except the restore step of 6 |
| 4 | Concurrent start converges under existing placement ownership; readiness distinguishes serving, classifying, closed and unavailable; stop drains within the existing bound; the diagnostic command reports references, marker and placement without resolving credentials or scanning history; on-demand start refuses by name when a configured reference is absent, never prompts, and reports unadmitted project resources | No |
| 5 | Every conversation action through a real daemon on terminal and piped input; quit, end of input and each signal detach with the run active and its identity unchanged; reconnect delivers the snapshot, contiguous events and a pending question; a killed client's lease lapses and a second terminal acquires control; a stale writer epoch is refused; a second conversation is refused while control is held; attached chat refuses every host and trace flag; the foreground conversation refuses a root a service holds | Attended reconnect case |
| 6 | Installed real-provider workflow on each supported host with complete output and archive evidence; an identified operator follows the runbook, including backup and restore | Yes, attended |
| 7 | A root without the current marker, with an unknown marker, or with a retired catalogue is refused by name before any write, by every command that opens a root, and its complete manifest is unchanged afterward; a fresh root receives the marker before any other write; a backup taken by the candidate restores under the candidate and serves | Yes, the same-build restore step |

The two repository checks and the closure matrix apply unchanged. The evidence
page is `docs/evidence/M8-closure-runs.md`, created and indexed on its actual
candidate, with complete immutable outputs outside the repository.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Non-goals](M8.md#concept-plan-scope).

Concept: [Rollout](M8.md#concept-plan-rollout).

| Surface | Proposed boundary |
| --- | --- |
| Local storage container | Retained until M9's explicit engine migration; the current-format marker identifies the root format and proves nothing about other builds |
| Durable records and host ledger | Delivered M7 versions as the current format; no older-reader or older-root promise |
| Restore transition | Accepted ADR 0051, unchanged; the commands are its operator front end |
| Daemon protocol | `loopex.experimental/4`. Any method the attached conversation or readiness needs and that generation lacks is a named addition with vectors, settled in ADR 0071 or ADR 0037 before acceptance |
| Foreground protocol and embedded API | `loopex.experimental/3` and the delivered embedded API, unchanged |
| Configuration | ADR 0049's versioned schema and resolver; discovery, writers and daemon-startup loading added by ADRs 0037 and 0071 |
| Existing commands | The foreground `chat` keeps its grammar and exit semantics. `run`, `resume`, `attach` and `sessions` keep theirs against a running service; under P8, `run` and `resume` additionally start the service on demand when they use the home's socket |
| Installed archive | New experimental packaging contract under ADR 0038 |

<a id="technical-plan-migration"></a>
### Current-Format Roots and Recovery

Concept: [Rollout and compatibility](M8.md#concept-plan-rollout).

No record is migrated and no older root is upgraded. The
[pre-1.0 rule](../process/agent-context-map.md#disposition-pre1-current-contract-2026-10-02)
retires older-root upgrade, historical-reader and cross-version rollback
proof; that retirement is a scope change, not passing evidence. Current-format
restart, uncertain-effect nonredispatch, authority, cleanup and backup and
restore remain required.

The candidate writes the current-format marker into a new root before any
other write, under the placement lock. Every command that opens a root checks
the marker first. It refuses a missing or unknown marker by name, before it
takes a lock, writer marker or socket inside the root and before any Store
repair. A root written by the M6 or M7 source builds carries no marker and is
refused, even if its records would happen to decode. The exact marker and
refusal classes are ADR 0072's to fix.

Recovery from a refused or unservable root uses the build whose format the
root is in. A backup taken by `0.5.0` restores under `0.5.0`. For a root that
an M7 source build wrote, the M7 build's host-embedded ADR 0051 restore is the
only path; M8 claims nothing about it. Never remove records to make any build
start. Engine migration and interrupted import are M9 work.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M8.md#concept-plan-scope).

ADR 0038 owns the platform-specific OTP archive, bundled ERTS, relative
provider companion lookup and manifest. The release label is `0.5.0` (D3). The
M8 candidate advances `VERSION` to `0.5.0` before its tested runs, and the
label is then used consistently in `VERSION`, the build layout, the manifest,
the daemon readiness record and the artifacts, so the eventual tag and
`VERSION` agree. M6's released `0.3.0` and M7's source release `v0.4.0` are
not repurposed.

The two supported hosts (D4) are `darwin-arm64` and `linux-x86_64` built in an
Ubuntu 22.04 container with glibc 2.35 as its base. The macOS archive is not
signed or notarized: the operator guide verifies the archive against its
checksum and manifest, then removes the quarantine attribute with a
documented command. No dependency framework, configuration library or service
layer is implied. Any native dependency is owned by its adapter and included
in the pinned build and linkage proof. Service-manager units, distribution
packages and publication are outside M8.
