# Operator Documentation

Runbooks for starting, observing, stopping, and recovering an embedded Loopex
runtime. Part of the [documentation index](../README.md).

## Contents

| Document | Purpose |
| --- | --- |
| [How a run works](how-a-run-works.md#concept) · [technical](how-a-run-works-technical.md#technical-depth) | The flow of one run from project-resource and skill admission through the prompt, tools, and answer; where each component runs; what is durable; recovery and rollback boundaries; and the bounds an operator controls. |
| [Runtime operations and first run](runtime.md#concept) | What M1 can run, exact source-tree demonstrations, lifecycle, credentials, event observation, shutdown, and crash recovery. |
| [Coding sessions](coding-sessions.md#concept) | Running, streaming, steering, resuming, and stopping a coding task; installing a pinned Git skill; inspecting project-only skills; selecting instructions and supporting files; trust decisions; retained state; and recovery. |
| [Observability](observability.md#concept) | Runtime-scoped trace sessions: what each level shows, what redaction removes and what it leaves, the ceilings and what happens at them, and when tracing is unavailable. Telemetry events: the emission inventory, what a span carries and what it never carries, and how a slow sink is handled. |
| [The daemon](daemon.md#concept) | Running one daemon per state root, importing a released root with `prepare-index`, driving, listing, observing and taking over sessions from separate client processes, recovery after a lost connection, signals, the orderly stop bound, limits and exit statuses. |
| [App server operations](app-server.md#concept) | Launching the foreground stdio server and the Node consumer from a source build; what an operator sees at each stage of a session; skills and the trust decision a client cannot make for itself; the difference between clean EOF, abrupt death and `session.abort`; answering an interaction after a restart; artifact transfer limits; and what the generation does not provide. |
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
