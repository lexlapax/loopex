# Operator Documentation

Runbooks for building, running, observing, stopping and recovering Loopex from
a source checkout: the `loopex` command, the daemon that keeps sessions alive
between commands, the foreground app server, and the embedded runtime beneath
all three. Part of the [documentation index](../README.md).

New here? Start with [getting started](getting-started.md), which builds the
command, runs a first session, watches it, stops it, and then runs the same work
through a daemon.

## Contents

| Document | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | Building from source, naming a state root and the provider credential, a first coding session, finding and stopping it, running it through a daemon, and the refusals a first-time operator is most likely to meet. |
| [How a run works](how-a-run-works.md#concept) · [technical](how-a-run-works-technical.md#technical-depth) | The flow of one run from the prompt to the answer, where each component runs, what is durable at every step, what a crash leaves behind, the bounds an operator controls, and what changes when a daemon holds the root. |
| [Coding sessions](coding-sessions.md#concept) | The offline `loopex` command: running, steering, following up, stopping, cancelling, finding and resuming a task; the project-resource trust decision; installing, inspecting and selecting project skills; command grammar, state-root layout and resource bounds. |
| [Tools and policy](tools-and-policy.md#concept) | The four coding tools and their budgets, what local execution can reach, run and cleanup bounds, host policy and the two shipped stances, artifacts and how to read one back, what is kept on disk, and where the provider credential goes. |
| [The daemon](daemon.md#concept) | Running one daemon per state root, importing an existing root with `prepare-index`, driving, listing, observing and taking over sessions from separate processes, reconnection, signals, the orderly stop, limits and exit statuses. |
| [App server operations](app-server.md#concept) | The foreground server on standard input and output: its launch inputs, the Node consumer, what a client sees at each stage, skills and trust, the difference between end of input, abrupt death and `session.abort`, answering a question after a restart, artifact transfers and frame limits. |
| [Observability](observability.md#concept) | Runtime-scoped trace sessions and telemetry events: how a host starts and stops tracing, what each level shows, what redaction removes, the ceilings, and the telemetry inventory. |
| [Runtime operations](runtime.md#concept) | The embedded runtime a host composes: what it provides, a credential-free demonstration of the loop, prerequisites, lifecycle, crash recovery and receipt reconciliation, and how to read failures. |

Loopex is built from source and is not packaged or published. These runbooks
describe the command, daemon, server and runtime as the checked-out revision
implements them; a source tag is not a package release or a compatibility
promise, and every surface described here is experimental.

## Related

- [Developer runtime and embedding guide](../developer/runtime-and-embedding.md#concept) — composition details and boundary contracts behind [runtime operations](runtime.md#concept).
- [Agent loop and tools](../developer/agent-loop-and-tools.md#concept) — the loop, tool contract and policy port behind [coding sessions](coding-sessions.md#concept) and [tools and policy](tools-and-policy.md#concept).
- [Compatibility surfaces](../developer/compatibility-surfaces.md#concept) — every surface these runbooks describe and what its experimental status means.
- [The daemon for developers](../developer/daemon.md#concept) and [observability for developers](../developer/observability.md#concept) — the contracts behind those two runbooks.
- [Development setup](../../DEVELOPMENT.md) — toolchain pairs and repository validation commands.
- [Plans and current status](../plans/README.md) — milestone authority and lifecycle.
