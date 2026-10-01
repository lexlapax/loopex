<a id="concept"></a>
## Concept

Technical depth: [M8 installed durable operator](m8-installed-durable-operator-technical.md#technical-depth).

**Draft, not registered or accepted.** This successor follows the
[Accepted M7 coding-agent plan](../plans/M7.md#concept). The earlier installed
plan was called M6, then M7. Its current number is M8; historical acceptance
records keep their original names. No release version is selected here.

<a id="concept-plan-purpose"></a>
### Purpose

Technical depth: [Prerequisites](m8-installed-durable-operator-technical.md#technical-plan-prerequisites).

An operator should install a verified artifact, configure a home, start and
recover the durable service, and upgrade or roll back using a documented reader
boundary. M7's coding conversation, explicit configuration, saved roles and
provider routing are predecessor deliverables conditional on M7 closure.
M8 extends those capabilities with installation and lifecycle management.

The store remains the existing local adapter within its documented limits.
M8 measures the proposed engine choices and prepares backup, marker and reader
boundaries; M9 implements the selected engine and explicit migration. M10
addresses trusted extension activation. No unmeasured engine is selected here.

<a id="concept-plan-outcomes"></a>
### Outcomes

Technical depth: [Evidence mapping](m8-installed-durable-operator-technical.md#technical-plan-evidence).

| # | Outcome | Evidence class |
| --- | --- | --- |
| 1 | One installed command from a verified platform-specific OTP release archive with bundled ERTS and provider companion | Manifest/linkage/install proof on clean supported platform hosts |
| 2 | Installed default home, discovery and atomic configuration management over M7's single schema/resolver; explicit-file use remains available | Precedence, provenance, invalid-input and write-fault tests |
| 3 | Store readiness: measured engine-selection experiment, container marker, supported-record reader boundary and closed-root backup/restore | Both-toolchain experiment plus exact reader and archive fixtures |
| 4 | Lifecycle commands, bounded diagnostics and start-on-demand using existing daemon/controller contracts | Process races, readiness, attachment, drain and operator recovery tests |
| 5 | Installed operator demonstration: install, configure, run, detach/reconnect, stop, restart, inspect and remove installation | Real-provider installed-artifact lane and attended record |
| 6 | Upgrade/rollback for exact supported predecessor/candidate binary and record combinations | Pre-upgrade backup restore under matching prior artifact, unsupported-reader negatives |
| 7 | ADR 0028 artifact-transfer concurrency counted per connection and its accepted 1 GiB cumulative transfer-work allowance, replacing the disclosed per-attachment divergence | Multi-attachment boundary tests, cumulative-work refusal and the real daemon Node client lane |

<a id="concept-plan-scope"></a>
### Scope

Technical depth: [Packaging](m8-installed-durable-operator-technical.md#technical-plan-packaging).

M8 owns installation, home discovery, configuration writers, lifecycle UX and
store readiness. It retains the maintainer-directed 2026-09-26 ADR 0028 transfer
bound repair as outcome 7. Operator/developer documentation accompanies every
outcome, with copyable commands and semantic review. It inherits M7's instruction-bearing roles, model switching,
environment-reference-only custody and bounded helpers. It does not introduce a
second provider/role schema or turn ephemeral `ask` into durable operation merely
because a home exists. A remote conversation attachment may be proposed using
the public session/controller contract; its exact scope is settled before M8 opens.

<a id="concept-plan-non-goals"></a>
### Non-Goals

Technical depth: [Compatibility](m8-installed-durable-operator-technical.md#technical-plan-compatibility).

No store engine implementation, extension activation, protocol/API freeze,
parallel helpers within one parent conversation, writable helpers,
file/keychain/command credentials or live configuration
reload is implied. No package publication, name clearance or release version is
authorized. Any added capability needs a scoped acceptance decision.

<a id="concept-plan-decisions"></a>
### Design Decisions

Technical depth: [Prerequisites](m8-installed-durable-operator-technical.md#technical-plan-prerequisites).

| Decision | Work it governs |
| --- | --- |
| [ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept) | Measured engine selection and the store-readiness/migration contract; engine cell filled before acceptance |
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | Installed discovery and writers, a narrow ADR 0003 home-reading amendment, reusing ADR 0049 |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | Artifact, manifest, native linkage, supported hosts, install and rollback proof |

Before opening, reconcile these Proposed pairs with the exact closed M7 baseline,
select the installed version and supported hosts, and name an actually available
rollback artifact. M6's released 0.3.0 remains a historical source identity, not
a promise that it supplied later installation or configuration features.

<a id="concept-plan-verification"></a>
### How Each Outcome Is Verified

Technical depth: [Evidence mapping](m8-installed-durable-operator-technical.md#technical-plan-evidence).

Extend existing conformance, CLI, process and release lanes. The installed lane
runs on each claimed clean platform without a toolchain or unbundled library
that the artifact promises to carry. Preserve complete outputs and archive
manifest/digests. Run ADR 0036's selection experiment on both supported toolchains
before choosing its engine. No real provider or rollback proof is replaced by
mocked results.

<a id="concept-plan-rollout"></a>
### Rollout and Compatibility

Technical depth: [Compatibility](m8-installed-durable-operator-technical.md#technical-plan-compatibility).

Technical depth: [Migration and rollback](m8-installed-durable-operator-technical.md#technical-plan-migration).

Storage container format, durable-record capabilities and binary version are
separate. An unchanged container does not imply that an older binary understands
M7 configuration, checkpoint, question or host-ledger records. Prove exact reader
combinations, and use a pre-upgrade backup plus matching prior binary for
unsupported downgrade. Restoring that backup discards later facts; it is not
reopening a newer root. A prior binary may not have an installed layout or restore
command. The runbook must use available artifacts and restoration tools.

<a id="concept-plan-workstreams"></a>
## Workstreams

Technical depth: [Ownership and rejoin](m8-installed-durable-operator-technical.md#technical-plan-ownership).

One integrator owns launch/configuration rejoin. Independent packaging and store
readiness work may proceed after contracts settle, with separate writer worktrees.

## Progress and Evidence

All outcomes remain Open. This 2026-09-30 revision reconciles the successor with
M7's proposed scope and removes unsupported backward-reader promises.

| # | State | Evidence |
| --- | --- | --- |
| 1 | Open | Installed artifact and host matrix remain to be proved |
| 2 | Open | Depends on delivered M7 schema; discovery/writers remain successor work |
| 3 | Open | Experiment and exact store-readiness fixtures remain to be produced |
| 4 | Open | Existing daemon is the baseline; added lifecycle workflow unproved |
| 5 | Open | Installed demonstration remains to be run |
| 6 | Open | Exact predecessor/candidate artifacts and record matrix not yet selected |
| 7 | Open | Per-connection transfer accounting and 1 GiB cumulative-work repair remain to be proved |

## Governance Records

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
| Closure | — | — | — |
