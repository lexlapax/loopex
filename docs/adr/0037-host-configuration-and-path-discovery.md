<a id="concept"></a>
## Concept

Technical depth: [Installed host configuration and path discovery](0037-host-configuration-and-path-discovery-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0003](0003-extension-contract-boundary.md#concept) only its ban on any Loopex application reading a user home, narrowed to the installed reference host
- **Depends on:** [ADR 0049](0049-explicit-host-configuration.md#concept), conditional on its acceptance and delivered M7 baseline
- **Prerequisite for:** M8 installed-operator discovery and configuration-management work; not an M7 prerequisite

<a id="concept-adr-0037-decision"></a>
### Context and Decision

Technical depth: [Contract](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-decision).

M7 proposes explicit configuration, named roles and provider routing. The
installed successor reuses that reader and schema, then adds a documented
`~/.loopex` default home, automatic loading of that home's `config.json`,
configuration writers and lifecycle diagnostics. Core and reusable composition
still receive explicit values and never discover home directories.

Lifecycle commands start, stop and report on the service, and a command that
asks for the service may start it on demand. The service reads the home's
configuration file at startup under
[ADR 0050](0050-daemon-attached-conversation.md#concept). A service started on
demand inherits the environment of the command that starts it. That command
first checks that each configured credential reference is present, never
reading a value, and refuses by name without starting anything when one is
absent. Readiness is reported as it is: serving, still classifying helper
history, or closed with the session whose history could not be read.

This proposal no longer introduces another role/provider schema or fixes a
session's model at process launch. ADRs 0044/0048/0049 govern committed selection,
custody and explicit configuration. Only named environment references are
currently proposed. File/keychain/command credentials require a separate future
decision; the sender never gains ambient file/environment reads.

Installed discovery and management are M8 work, conditional on closed M7.
No installed release version is selected here. Exact command compatibility and
any schema additions must be reconciled with the delivered M7 contract before
this pair can be accepted.

<a id="concept-adr-0037-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-evidence).

An installed operator can configure one home, inspect effective values and
origins, and use lifecycle diagnostics. The host still refuses missing authority
or provider bindings. Tests always use temporary homes. Removing config does not
remove durable session truth and may make recovery unavailable.

<a id="concept-adr-0037-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-compatibility).

The existing explicit-file path remains supported. Automatic discovery is a
new host trust choice, not project-context admission. Unsupported schemas refuse
before startup. Configuration deletion is not a rollback procedure; use a
matching prior binary and retained root/configuration backup where compatible.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
