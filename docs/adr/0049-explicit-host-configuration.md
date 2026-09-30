<a id="concept"></a>
## Concept

Technical depth: [Explicit host configuration and conversation command](0049-explicit-host-configuration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** nothing
- **Depends on:** [ADR 0042](0042-host-composed-instructions.md#concept), [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept), [ADR 0047](0047-reference-host-run-defaults.md#concept) and [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
- **Prerequisite for:** M7 outcomes 6 and 7

<a id="concept-adr-0049-decision"></a>
### Context and Decision

Technical depth: [Contract](0049-explicit-host-configuration-technical.md#technical-adr-0049-decision).

M7 adds a versioned file selected explicitly by `--config FILE`, with CLI
overrides and inspectable effective values. Only the reference host reads it.
Embedding callers pass equivalent explicit options. There is no automatic
home/project discovery, hot reload, interpolation or config writer.

`loopex chat` owns one foreground durable runtime and uses the public session
facade for conversation, answers, steering, follow-up, configuration and
compaction. Existing one-shot and daemon commands retain their grammar; M7
adds trace startup controls to runtime-owning commands. A connected client
never gains runtime trace authority. Remote conversational-terminal attachment
and installed lifecycle management remain successor work.

Provider references and saved role definitions belong to the host. Roles have
no permission, workspace or tool overrides. The selected file must explicitly
declare conversational and, when enabled, delegation limits. Instructions are
read once as exact bounded host bytes. Project resources still require their
separate admission. Existing sessions retain committed settings and their
frozen role catalog; file edits affect new sessions. Explicit between-run
configuration is the only way to change admitted model or instruction settings.

Tracing uses ADR 0030's runtime-scoped API, existing redaction and ceilings.
The host reports effective scope/limits and emitted/dropped counts through a
bounded stderr consumer, separately from result output. Chat has text output only; existing `ask --output
json` retains its defined format and carries no diagnostics on stdout. No raw debug mode or
VM-global tracing is added.

<a id="concept-adr-0049-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0049-explicit-host-configuration-technical.md#technical-adr-0049-evidence).

An operator can validate the file, inspect values and origins without reading
credentials, and start a conversation with explicit bounds. Invalid/unknown
input refuses before runtime startup. A non-TTY chat refuses with a direction
to existing `ask` or protocol clients; M7 does not invent a piped interaction
language. Normal text is a new prompt only while settled; active-run input must
name its action. EOF detaches only after explicit abort and bounded cleanup of
this foreground-owned work, reporting uncertainty if cleanup cannot be proved.

<a id="concept-adr-0049-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0049-explicit-host-configuration-technical.md#technical-adr-0049-compatibility).

The JSON schema and command are experimental. Existing commands retain their
existing option meanings and defaults. The file is host configuration, not a
session journal or authority grant. Deleting it cannot reset saved session
configuration, role snapshots or unresolved work. Installed default discovery
remains Proposed ADR 0037 for M8.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
