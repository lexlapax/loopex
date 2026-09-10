# ADR 0022 — Local executor supervision shell: technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Local executor supervision shell](0022-local-executor-supervision-shell.md#concept).

<a id="technical-supervision-shell-decision"></a>
## Mechanism and Evidence

Concept: [Decision and scope](0022-local-executor-supervision-shell.md#concept-supervision-shell-decision).

At source `7d1cdde971221bc86972012cfe86198a4c4d87a8`, the ordinary native
Linux executor suite passed 91 of 161 cases and failed 70. Research isolated
two independent properties of noninteractive dash: an asynchronous `<&0`
launch read EOF despite an available frame, and `set -m` returned zero while
disabling job control without a terminal. In the latter probe the helper guard
remained in its carrier's group rather than the guard-led group the protocol
assumed. The corresponding Darwin shell probes passed.

A native Bash 5.2.21 carrier and guard, with pre-fork descriptor capture,
received the exact frame and created the distinct helper group. Its raw command
still ran through `/bin/sh` in that group. This establishes the proposed
mechanism, not production cleanup. The [qualification record](../evidence/M2-ff17990-review-followup.md)
retains the original failures and task evidence; no later success replaces them.

The first process image remains absolute `/usr/bin/env` with the existing spawn
environment construction. Its downstream clearing boundary invokes absolute
`/bin/bash` for the internal carrier, and that carrier invokes absolute
`/bin/bash` for its guard. Neither interpreter is resolved from an operator or
workspace search path. The raw command interpreter remains `/bin/sh`; argv
execution remains direct. No credential moves into arguments or control frames
that were previously public.

Capture the carrier's incoming control descriptor before asynchronous launch,
connect the guard's stdin to that preserved descriptor, then close the redundant
copy in both processes. The guard's private status descriptor remains closed
in the model command. Model commands do not inherit the initialization/permit
input or private status capability. Do not change control-frame tokens, receipt
fields, process-group signal authority, quiescence checks or deadlines.

<a id="technical-supervision-shell-consequences"></a>
## Compatibility and Alternatives

Concept: [Consequences and alternatives](0022-local-executor-supervision-shell.md#concept-supervision-shell-consequences).

The new prerequisite belongs only to the concrete local executor. A host lacking
an executable `/bin/bash` must not fall back to `/bin/sh` or claim that a command
or cleanup succeeded. Preserve the existing refusal/unknown-effect rules:
absence of launch evidence is not proof that an effect completed. The repair
adds no public callback, configuration selector, application, persistent schema,
tool grammar or group-ownership transfer. The separate provider companion's
supervision interpreter is outside this decision.

Use syntax compatible with the already qualified Darwin Bash and native Linux
Bash; qualification records name their observed versions. This decision is not
a claim that every Bash version on every host is qualified.

Alternatives have these costs:

- A platform-specific session/group launcher adds executable or native-build
  dependencies, multiple lifecycle paths and per-platform packaging evidence.
  No portable Darwin/Linux substitute was established by the investigation.
- A shared helper/carrier group removes the surviving carrier on final group
  KILL. It therefore needs a new authenticated acknowledgement/exit design,
  rather than changing one group identifier under the current protocol.
- A Darwin-only release changes the required platform coverage and needs a
  separately authorized waiver; it is not a passing Linux result.

Fixed internal Bash keeps the current ownership model and limits this new
dependency to the adapter that needs it. None of these choices authorizes
editing a frozen gate or disposing of a failing required check.

<a id="technical-supervision-shell-rollout"></a>
## Verification and Rollback

Concept: [Rollout and rollback](0022-local-executor-supervision-shell.md#concept-supervision-shell-rollout).

Before review, run the existing complete executor corpus serially on Darwin
and native Linux without a terminal. Observe public raw and argv commands and
actual bounded-helper entry/results. Verify carrier/guard/helper process groups
by observation, not merely a successful `set -m` status. Retain the signal,
loss, cancellation, receipt-retention and descendant-cleanup cases unchanged
unless an assertion itself demonstrably described the broken mechanism.

Add benign descriptor observations that detect intentionally opened non-secret
descriptors as a positive control and prove that model commands receive neither
private supervision descriptors nor control input. Do not read tokens or forge
control messages merely to observe descriptor presence. A mutation detector
must fail because the property is false, not because a fixture never starts.

Update a structural spelling check when its intended topology is unchanged,
but do not call the updated source-text assertion behavioral evidence. Retain
exact-source commands, failures and results; run formatting and warnings-as-errors
compilation and the whole suite before handing off. No retry, larger bound,
filtered protected case or changed gate minimum may substitute for a repair.

There is no on-disk migration. Stop new work and let admitted effects settle
under their original owners before changing deployed binaries. Existing
uncertain effects remain quarantined and require ordinary reconciliation; an
interpreter change cannot erase their history. Reverting to the old shell path
on Linux restores the known defect, not a supported fallback.
