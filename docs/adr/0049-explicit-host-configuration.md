<a id="concept"></a>
## Concept

Technical depth: [Explicit host configuration and conversation command](0049-explicit-host-configuration-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0039](0039-ephemeral-embedded-profile.md#concept) only its closed ephemeral startup-option set, adding an opt-in owner-managed trace configuration; credential audience and cleanup guarantees remain unchanged
- **Depends on:** [ADR 0042](0042-host-composed-instructions.md#concept), [ADR 0043](0043-context-compaction-checkpoint.md#concept), [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept), [ADR 0045](0045-model-originated-questions.md#concept), [ADR 0046](0046-child-session-tool.md#concept), [ADR 0047](0047-reference-host-run-defaults.md#concept) and [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
- **Also amends:** [ADR 0016](0016-configured-cancellation-observation.md#concept) prepared-recovery admission so every post-preparation refusal abandons its owner before reporting; its immutable cleanup contract remains. Extends the session facade with observational command disposition and owner-driven resolution of an identical unknown admission transaction, preserving Store fencing.
- **Prerequisite for:** M7 outcomes 6 and 7

<a id="concept-adr-0049-decision"></a>
### Context and Decision

Technical depth: [Contract](0049-explicit-host-configuration-technical.md#technical-adr-0049-decision).

M7 adds a versioned file selected explicitly by `--config FILE`, with CLI
overrides and inspectable effective values. File inspection shows what a new
session would use and never a session's committed values. Chat reports its
effective values and origins once at startup on stderr, best-effort, with
committed values on resume. Only the reference host reads the file.
Embedding callers pass equivalent explicit options. There is no automatic
home/project discovery, hot reload, interpolation or config writer.

`loopex chat` owns one foreground durable runtime and uses the public session
facade for conversation, answers, steering, follow-up, configuration and
compaction. Existing one-shot and daemon commands retain their grammar; M7
adds trace startup controls to chat, ask and daemon startup only. A connected client
never gains runtime trace authority. Remote conversational-terminal attachment
and installed lifecycle management remain successor work.

The file requires an existing closed-registry policy profile. Tool profiles are
coding, read-only and none. Chat enables questions in nonempty profiles; helpers
remain opt-in with a complete declaration. None disables both and refuses an
enabled helper declaration. The selected set is immutable. The trusted fixture
host may inject its pinned test policy after ordinary file validation; inspection
shows harness origin and identity. The validation cases reopen through that
same pinned wrapper; only pending interactions carry a retained core policy
identity. There is no file
policy-module option.

Provider references and saved role definitions belong to the host. Roles have
no permission, workspace or tool overrides. The selected file must explicitly
declare conversational and, when enabled, delegation limits. Instructions are
read once as exact bounded host bytes. Project resources still require their
separate admission. Existing sessions retain committed ordinary settings and
their frozen role catalog; file edits to those values affect new sessions. Explicit between-run
configuration is the only way to change admitted model or instruction settings.
New chat sessions retain their verified physical workspace identity. Resume
requires that retained binding and refuses a different workspace, a retargeted
symlink, or a replacement directory. An explicit path never adopts an unbound
session. The maintainer's 2026-10-02 current-contract decision retires the
pre-1.0 legacy model-selection and unbound-workspace exceptions.
Resume also keeps the session's committed cleanup period. A changed file value
is a default for new sessions; a conflicting explicit cleanup flag refuses
through ADR 0016's prepared-recovery path before work can start. Preparation
compares retained policy questions with the selected policy identity and revision,
and keeps every provider route needed by already-admitted work. An answered
question remains paused until the holder activates the recovered session.
The reference host also supplies ADR 0043's shared versioned compaction
instructions at runtime startup. They have no new file field or CLI flag;
an admitted episode retains its block across restart, while future episodes
use the block supplied by the current host.
The summarizer model is explicit through `maintenance.model` or
`--compaction-model`. There is no default or conversation-model inheritance.
Without it ordinary work remains available only while ordinary staging and any
initial thinking reserve fit, and compaction reports unconfigured. Status warns
when the committed conversation requires continuation but has no summarizer.
This host setting affects new maintenance episodes; an admitted episode keeps
its captured model across restart. It is separate from ordinary `/configure`.

Tracing uses ADR 0030's runtime-scoped API, existing redaction and ceilings.
The creating host submits its already-redacted effective settings report once
through the existing diagnostic consumer. This submission never waits for IO.
It uses the same bounded pending output and loss accounting as diagnostics;
oversized rows drop whole rather than misrepresenting a selected value.
Provider rows show identity and reference form/validity, with credential names
and values excluded. Instructions, role prompts, capabilities, mappings and
private continuation remain outside the report. This implements the accepted
[startup-report decision](../developer/agent-context-map.md#disposition-m7-chat-startup-2026-10-02).
The host reports effective scope/limits and emitted/dropped counts through a
stderr writer with bounded pending output, separately from result output.
The diagnostic sink mailbox keeps ADR 0030's best-effort backpressure; these
flags do not promise a total host-memory bound. Chat is a text transcript; piped
mode also emits bounded versioned @loopex control lines for admissions, questions,
barriers, status, errors and closing. Barrier and closing lines name run outcomes
only; a compaction result appears in the transcript, status and exit code.
While an admission is unresolved the owner holds internal results and timer
transitions and admits no other command; an unresolvable admission stays reported as unknown, after which
interactive chat accepts only exit. Validation accepts a credential-free
provider binding and names the commands it cannot run. Exit succeeds only when every admitted operation
succeeded and cleanup is confirmed. Every refusal discovered after resume
preparation abandons the owner; unknown admission is observed through its
coordinator resolver, without command resubmission or fabricated success.
Existing `ask --output json` retains its defined format and carries no diagnostics on stdout. No raw debug mode or
VM-global tracing is added.
Ephemeral startup and one-shot composition accept the same opt-in trace
configuration. Their private owner starts and stops tracing with its runtime
and the stderr drain/writer. An embedding caller gains no raw runtime
reference or remote trace authority through that option.

<a id="concept-adr-0049-terminal-outcome"></a>
### Terminal run objects

Technical depth: [Closed terminal schema](0049-explicit-host-configuration-technical.md#technical-adr-0049-terminal-outcome).

Chat barriers and closing records use one compact object containing exactly
`outcome` and `details`. It reports a terminal run, with the existing bound,
failure or reconciliation evidence. It contains no transcript, profile,
duplicate run identity or host cleanup claim. Quantities preserve Core's domains;
reconciliation references preserve opaque bytes. Existing ask JSON and retained
public events keep their encodings. This experimental presentation needs no
stored-data migration and can be removed with the chat command on rollback.

The maintainer [approved this amendment](../evidence/M7-implementation-tasks.md#decision-m7-chat-terminal-outcome-2026-10-02)
on 2026-10-02. The original acceptance row below still binds its historical
candidate; it does not claim to include this later amendment.

<a id="concept-adr-0049-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0049-explicit-host-configuration-technical.md#technical-adr-0049-evidence).

An operator can validate the file, inspect values and origins without reading
credentials, and start a conversation with explicit bounds. Invalid/unknown
input refuses before runtime startup. Chat accepts interactive and piped input
with the same text/slash grammar. A `/wait` barrier sequences scripted prompts;
answers and declines name the actual pending interaction. Piped errors stop the
script and report nonzero status. Normal text is a new prompt only while settled; active-run input must
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
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-acceptance-2026-09-30) | candidate `2986150b878151524ecdd9bac5a9779e69e196b4`; concept `sha256:e317e526e2f8279bd79d9d47a31eb00375c29e3b5d56f3dcb8ff5c89b2902702`; technical `sha256:894637cd3fedb3f72eb741956510314e67fd7132705c76ec51c31ac1e7fe8165` |
