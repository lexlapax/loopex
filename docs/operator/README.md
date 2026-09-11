# Operator Documentation

Runbooks for starting, observing, stopping, and recovering an embedded Loopex
runtime. Part of the [documentation index](../README.md).

## Contents

| Document | Purpose |
| --- | --- |
| [How a run works](how-a-run-works.md#concept) · [technical](how-a-run-works-technical.md#technical-depth) | The flow of one run from project-resource and skill admission through the prompt, tools, and answer; where each component runs; what is durable; recovery and rollback boundaries; and the bounds an operator controls. |
| [Runtime operations and first run](runtime.md#concept) | What M1 can run, exact source-tree demonstrations, lifecycle, credentials, event observation, shutdown, and crash recovery. |
| [Coding sessions](coding-sessions.md#concept) | Running, streaming, steering, resuming, and stopping a coding task; installing a pinned Git skill; inspecting project-only skills; selecting instructions and supporting files; trust decisions; retained state; and recovery. |
| [Tools and policy](tools-and-policy.md#concept) | The four coding tools, what local execution can reach, how `--policy` selects host authority, why skill content grants no permission, artifacts and how to read one back, and what the local store keeps on disk. |

Loopex is not packaged or published for consumers. These runbooks describe the
source-tree runtime and command; a source milestone tag is not a package release
or compatibility promise.
Start with [running a task](coding-sessions.md#operator-sessions-running) for the
`loopex` command, or with
[what M1 delivers](runtime.md#operator-runtime-available) and
[the working loop](runtime.md#operator-runtime-first-run) for the embedded
runtime beneath it.

An M1-era session data root is not readable by M2. Point the command at a fresh
state root rather than an existing M1 directory.

## Related

- [Developer runtime and embedding guide](../developer/runtime-and-embedding.md#concept) — composition details and boundary contracts.
- [Development setup](../../DEVELOPMENT.md) — toolchain and repository validation commands.
- [Plans and current status](../plans/README.md) — milestone authority and lifecycle.
