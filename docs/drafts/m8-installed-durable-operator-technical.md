<a id="technical-depth"></a>
## Technical depth

Concept: [M8 installed durable operator](m8-installed-durable-operator.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](m8-installed-durable-operator.md#concept-plan-purpose).

Concept: [Design decisions](m8-installed-durable-operator.md#concept-plan-decisions).

M7 closes first. Its exact implemented schema, protocol generation, provider
custody, host ledger and source identity become M8's baseline. M7 is Accepted
for implementation but not Closed, so this draft does not describe those
capabilities as shipped.

| Decision | Acceptance point |
| --- | --- |
| [ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept) | Retain the measured selection experiment and fill the engine cell before store-readiness implementation |
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | Resolve exact discovery/writer/lifecycle grammar against delivered M7 before implementing it |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | Fill the pinned build recipe, allowed libraries, supported hosts and real previous artifact before release-build/install code |

Accepted [ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept)
constrains outcome 7; use its existing exact limits and refusal contract.

ADR 0035 remains deferred. No typed policy input, new credential source or
publication enters through these prerequisites. Installed version selection and
any public-name clearance remain separate decisions.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Workstreams](m8-installed-durable-operator.md#concept-plan-workstreams).

Configuration/discovery and launch have one integration owner. Store readiness
and packaging use non-overlapping ownership and separate worktrees. Rejoin at
one installed workflow before adding failure matrices; documentation follows the
same accepted grammar. No second configuration resolver or durable session owner.
The M9 capacity option needs a versioned successor to ADR 0049's closed schema
or its explicit amendment; installed discovery/writers must refuse that future
member under version 1 and migrate through the same resolver. M8 adds no capacity
member merely because it manages files.
Helper concurrency inherits the delivered M7 boundary: one active helper per
parent conversation, with independent parents permitted to overlap. Installation
adds no runtime-wide slot, parallel children within a parent or writable helper.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](m8-installed-durable-operator.md#concept-plan-outcomes).

Concept: [Verification](m8-installed-durable-operator.md#concept-plan-verification).

| # | Required proof |
| --- | --- |
| 1 | Exact manifest/checksum, provider companion identity, native linkage and clean-platform install from retained archive |
| 2 | Existing M7 explicit-file equivalence; default-home selection, per-value origins, unknown schema refusal, atomic-write fault cuts and no credential value inspection |
| 3 | ADR 0036 experiment per toolchain; marker commit ordering; missing-marker record capability checks; complete quiescent-root backup including M7 host ledger and child sessions; restore digest verification and nonempty/live target refusal |
| 4 | Concurrent start converges under existing placement ownership; readiness, observer/controller takeover, drain, restart and bounded logs retain established behavior |
| 5 | Installed real-provider workflow on each supported platform, complete output and archive evidence |
| 6 | Exact prior and candidate binaries versus supported historical/M7/new roots; unsupported downgrade protection; pre-upgrade backup restored by a compatible tool and opened by matching prior binary |
| 7 | Extend `transfer_bound_test.exs`: one connection across multiple attachments shares its count/allowance, another connection remains independent; cumulative work beyond 1 GiB refuses; the daemon independent Node lane passes and operator/developer docs remove only the now-proved divergence |

The two repository checks and closure matrix still apply. The evidence page is
`docs/evidence/M8-closure-runs.md`, created/indexed on its actual candidate, with
complete immutable outputs outside the repository. No evidence exists yet.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Non-goals](m8-installed-durable-operator.md#concept-plan-non-goals).

Concept: [Rollout](m8-installed-durable-operator.md#concept-plan-rollout).

| Surface | Proposed boundary |
| --- | --- |
| Local storage container | Retained until M9's explicit engine migration; marker alone proves no record compatibility |
| Durable records and host ledger | Delivered M7 versions, with explicit reader fixtures; no old-reader promise from container identity |
| Public session protocol and embedded API | Delivered M7 contract; any further change needs explicit scope and vectors |
| Configuration | Reuse M7 versioned schema/resolver; discovery and writer semantics added by ADR 0037 |
| Installed archive | New experimental packaging contract under ADR 0038 |

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Rollout and compatibility](m8-installed-durable-operator.md#concept-plan-rollout).

Before acceptance, fill source/target binary identities, supported record versions,
container markers and available restoration tools. Include roots with M7 model/
instruction configuration, compaction, text/decline questions and delegated work,
including unresolved operations where safe fixtures can establish recovery.

Validate unknown formats/records before writes in the new reader. Test released
readers as they exist, not as this proposal wishes them to behave. If an old reader
cannot safely reject a newer root, prevent unsupported reopening and restore the
pre-upgrade backup into a separate empty root. Never remove new records to make
an old binary start. Verify backup manifests, exact record order/digests and
matching reader behavior. Engine migration and interrupted import are M9 work.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](m8-installed-durable-operator.md#concept-plan-scope).

ADR 0038 owns the platform-specific OTP archive, bundled ERTS, relative provider
companion lookup and manifest. Select a release label at M8 acceptance, then use
it consistently in VERSION, build layout and artifacts. Do not repurpose M6's
released 0.3.0 or assume 0.4.0 is available after M7. No dependency framework,
configuration library or service layer is implied. Any native dependency is
owned by its adapter and included in the pinned build/linkage proof.
