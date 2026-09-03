# Operator Documentation

Runbooks for starting, observing, stopping, and recovering an embedded Loopex
runtime. Part of the [documentation index](../README.md).

## Contents

| Document | Purpose |
| --- | --- |
| [How a run works](how-a-run-works.md#concept) · [technical](how-a-run-works-technical.md#technical-depth) | The flow of one run from the prompt to the answer with its diagram, the components and where each runs, what is durable at every step, what a crash at each stage leaves behind, and the bounds an operator controls. |
| [Runtime operations and first run](runtime.md#concept) | What M1 can run, exact source-tree demonstrations, lifecycle, credentials, event observation, shutdown, and crash recovery. |
| [Coding sessions](coding-sessions.md#concept) | Running, streaming, steering, resuming, and stopping a coding task with the `loopex` command; the project-resource trust decision; the configuration a resumed session recovers; and what stopping does and does not promise. |
| [Tools and policy](tools-and-policy.md#concept) | The four coding tools, what local execution can reach, how `--policy` selects host authority, artifacts and how to read one back, and what the local store keeps on disk. |

Loopex is not packaged or released yet. These runbooks describe the source-tree
runtime and command and do not create a public compatibility or support promise.
Start with [running a task](coding-sessions.md#operator-sessions-running) for the
`loopex` command M2 delivers, or with
[what M1 delivers](runtime.md#operator-runtime-available) and
[the working loop](runtime.md#operator-runtime-first-run) for the embedded
runtime beneath it.

An M1-era session data root is not readable by M2. Point the command at a fresh
state root rather than an existing M1 directory.

## Related

- [Developer runtime and embedding guide](../developer/runtime-and-embedding.md#concept) — composition details and boundary contracts.
- [Development setup](../../DEVELOPMENT.md) — toolchain and repository validation commands.
- [Plans and current status](../plans/README.md) — milestone authority and lifecycle.
