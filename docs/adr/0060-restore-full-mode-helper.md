<a id="concept"></a>
## Concept

Technical depth: [Full-mode helper contracts and proof](0060-restore-full-mode-helper-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-07
- **Decision owner:** Maintainer
- **Amends:** [ADR 0051](0051-current-format-physical-restore.md#concept), only administrative subprocess ownership and fixed system prerequisites for exact full-mode preservation. Its manifests, authority, transition, receipts and deadlines remain unchanged.
- **Constrained by:** [Ownership and trust](../vision.md#concept-vision-ownership-trust), [dependency direction](../vision.md#concept-vision-dependency-doctrine) and [M7](../plans/M7.md#concept).

<a id="concept-adr-0060-purpose"></a>
### Preserve the complete permission mode

Technical depth: [Evidence and source placement](0060-restore-full-mode-helper-technical.md#technical-adr-0060-purpose).

Restore must preserve every imported `mode & 0o7777`, including the sticky bit
`0o1000` on regular files and directories. The current OTP Unix setter masks
that bit out. Moving a directory setter later cannot repair it, and the same
mask applies to files. The proved regular-file `0o4750` repair fixes write
ordering; it does not establish sticky-file or directory preservation.

Recommend one fixed, private Composition administrative chmod operation for
sticky modes. Apply it after the last file write and before file sync/close,
including imported generation replacement, and to directories bottom-up after
child copies. Keep native setters and exact readback for other modes. Preserve
initial staging protection; a temporary nonsticky mode is never accepted as
final manifest equality. No mode is normalized, excluded or replaced in the
retained source, backup or destination manifest.

This is an ownership and dependency amendment. Composition's existing restore
guardian will own the helper's operating-system resources before allowing a
mode change. This is offline host administration with the invoking user's
existing filesystem authority. It adds no model tool, executor job, arbitrary
launcher, Core dependency, public option or persistent record. Local's private
observation helper is not an approved substitute for this ownership.

<a id="concept-adr-0060-profile"></a>
### Fixed prerequisites and host trust

Technical depth: [Executable and first-image admission](0060-restore-full-mode-helper-technical.md#technical-adr-0060-profile).

Select absolute `/usr/bin/env`, `/bin/bash`, `/bin/chmod` and `/bin/ps` for this
Composition operation. The qualified `ps` dialect must return PID, parent PID
and process-group ID. No PATH lookup, custom executable, interpreter selector,
production Python, installation, sudo or alternate helper fallback is added.
Only an affected sticky-mode restore acquires these prerequisites; read-only
lookup, Core and ordinary native-mode operations do not.

Capture root-owned system executable placement, identities and bytes through
non-group/world-writable system ancestors within the original invocation, then
recheck before launch. Trusted system symlinks may
resolve through captured trusted ancestors. The first process image must
receive a scrubbed environment at the Port boundary, before `env` executes;
`env -i` alone is too late. The downstream environment is fixed and contains
no host credential or startup hook. Executables, loader and system libraries
remain trusted host code. This profile is not protection from a malicious host.

Host exclusion continues to cover every participating tree, old authority,
system executable replacement and launch-environment mutation. Fixed chmod is
path-based. Held descriptors and before/after root, ancestor and target checks
can detect substitution, but cannot make path chmod an atomic inode operation
or undo a change made through a malicious concurrent rename. The host must
honor exclusion; stricter hostile-host isolation needs another decision.

Select finite admission ceilings: each executable at most 16 MiB; at most 16
system-symlink hops and 64 ancestors; launch-environment inventory at most 4,096
entries and 1 MiB, names at most 128 bytes and values at most 8,192 bytes.
These are availability limits, not permissions to truncate
inputs. An unavailable, changed, oversized or unqualified profile refuses the
affected operation without a clean success. Cleanup uncertainty is retained.

<a id="concept-adr-0060-custody"></a>
### Original resources and one deadline

Technical depth: [Custody, permits and finite observations](0060-restore-full-mode-helper-technical.md#technical-adr-0060-custody).

The original monitored restore guardian owns the Port, carrier, live group
guard, status wrapper and gated direct child before permitting chmod. A private
token over control descriptors binds captures and acknowledgements. The child
is identified while gated, then becomes the fixed chmod image without changing
PID. At most one mutation group and one process-table observer are live.

Select three fixed serial observations per helper: captured actors before the
mutation permit, waited child/wrapper before group release, and original actor
and group absence after Port termination. Each observer is a direct fixed exec
with no descendant launcher or recursive observation. Its own original wait,
EOF and close must be proved. Each complete table is capped at 4 MiB, 65,536
rows, 64 bytes per row and ancestry depth 64. Control frames are capped at 1,024
bytes and 32 frames; all helper output is capped at 65,536 bytes. Overflow,
malformed or incomplete observations preserve uncertainty.

A helper creates at most seven original OS processes in total, five at once:
four mutation actors and three serial observers. A restore admits at most one
helper per baseline entry plus one per replaced ledger generation, at most
65,664 helpers and 196,992 observers across the invocation. These ceilings bound
work; they do not promise that a maximum-size restore fits its selected time.

Every executable read, launch, observation, mode change, sync and join spends
the original absolute work cutoff and single terminal cleanup cutoff from ADR
0051. No helper, directory, observation or retry receives another allowance.
Carrier/guard/child loss, caller loss, EOF and cancellation stop new permits.
Group signals require a still-owned live member. Signal delivery, exit status,
a closed Port or BEAM DOWN alone cannot prove that permission work has stopped.
Missing original wait/close/absence evidence cannot produce a clean result.

<a id="concept-adr-0060-truth"></a>
### Outcomes and continued exclusion

Technical depth: [Readback, cleanup and refusal mapping](0060-restore-full-mode-helper-technical.md#technical-adr-0060-truth).

Only exact full-mode readback, required syncs, original descriptor closes and
complete helper/observer joins may acknowledge a completed file/directory operation. Helper evidence alone
does not finish the native sync/close duties. Complete
baseline equality still precedes intent; root commit remains the final payload
publication. Original effect receipts and unknown outcomes remain unchanged.
No effect is redispatched, no source retirement is reversed and the physical
workspace identity remains the same.

Preserve ADR 0051's outcome grammar. Before possible intent, a fully joined
failure uses the existing refusal mapping. Unconfirmed pre-intent cleanup
returns `cleanup_unconfirmed`; possible intent returns `commit_unknown` even
when cleanup joined. Retain claims and host exclusion while resource evidence
is unresolved. A missing prerequisite cannot be relabelled successful mode
preservation. Read-only lookup starts no permission helper.

<a id="concept-adr-0060-alternatives"></a>
### Alternatives and current-format rollback

Technical depth: [Alternatives, amendment and rollback mechanics](0060-restore-full-mode-helper-technical.md#technical-adr-0060-alternatives).

| Option | Consequence |
| --- | --- |
| Fixed Composition helper, recommended | Provides an implementable route to exact sticky modes on the current pairs. Adds the fixed system profile, host trust and owned-resource qualification described here. Acceptance permits implementation; it does not prove preservation or cleanup. |
| Keep native-only refusal | Adds no dependency. Complete manifest comparison continues to refuse lossy copies before activation. The full-mode outcome remains incomplete and T15 cannot close on that refusal. |
| Custom native setter or patched OTP build | Could supply descriptor-based chmod. Adds native compilation, VM safety, packaging, toolchain and platform qualification decisions. No supported alternative is established by current evidence. |

Before 1.0, keep only the current implementation. No dual helper, older-root
migration or cross-version rollback is proposed. Removing this helper stops
new affected restores; it cannot clear unknown claims, revive a retired source
or claim sticky preservation from the demonstrated native setter. Original-tx
continuation still requires positively terminated prior authority and all
unchanged plan, manifest, lineage and effect bindings.

<a id="concept-adr-0060-proof"></a>
### Acceptance and required proof

Technical depth: [Qualification matrix and retained evidence](0060-restore-full-mode-helper-technical.md#technical-adr-0060-proof).

The maintainer must accept the exact pair before dependent implementation.
Prove real fixed executables and full physical modes on both supported pairs on
Darwin and native Linux, without a terminal. Prove original actor/resource
capture, first-image scrubbing, deadlines, cancellation, faults, late mutation
and exact joins; preserve the existing per-restore and aggregate test bounds.
Complete manifests, public restore, unknown receipts and current-format
recovery remain required. No Linux, full-mode or helper-cleanup PASS is claimed
by this proposal. Other Proposed ADRs remain separate decisions.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
