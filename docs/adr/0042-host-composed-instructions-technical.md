<a id="technical-depth"></a>
## Technical depth

Concept: [Host-composed instructions](0042-host-composed-instructions.md#concept).

<a id="technical-adr-0042-decision"></a>
### Envelope and Bounds

Concept: [Context and decision](0042-host-composed-instructions.md#concept-adr-0042-decision).

**Present state, read from source on 2026-09-29.**

| Fact | Location |
| --- | --- |
| `system_block/1` returns a constant beginning `loopex.system.v1:` and ignores its argument | `apps/loopex/lib/loopex/runtime/session_coordinator.ex` |
| The system class ceiling is the constant 1,000 | `apps/loopex/lib/loopex/runtime/context_admission.ex` |
| The prompt and four tool definitions measure 799 estimated tokens | ADR 0017 |
| The digest covers model identity, messages, tool definitions, sampling, deadline and the continuation field | ADR 0010 technical, "Canonical model request" |
| Prompt selection belongs to hosts and extensions | `docs/vision-technical.md` §13.5 |
| The reference prompt target is under 1,000 tokens before project context | `docs/vision-technical.md` §23.4 |

**The option.** Session creation accepts `instructions`, a map with exactly
these members:

| Member | Type and bound |
| --- | --- |
| `version` | Non-empty ASCII identifier of at most 64 bytes, chosen by the host |
| `base` | Non-empty UTF-8 of at most 32 KiB |
| `environment` | UTF-8 of at most 4 KiB, may be empty |
| `appendix` | UTF-8 of at most 16 KiB, may be empty |

Unknown members refuse. The staged system message is `version`, a colon and
a space, then the three sections joined by one blank line, with empty
sections omitted. Core performs no templating and no substitution.

**Measurement.** The system class is measured as today, over the staged
block and the model-facing tool definitions. A block over the host's
system-class ceiling refuses session creation with `system_class_tokens`.
The ceiling is a runtime option with no default in core; the reference host
supplies 1,000.

**Receipt.** The context receipt's system descriptor records the host's
`version` as its source reference and the block's content digest. The
provider revision advances by one.

**Reference default.** It lives in the reference host, not in core or the
reusable composition. It names the tools by their model-facing names, asks
for concise answers, and tells the model to continue until the task is done
and then stop. The environment section is composed at session creation from
the workspace the host already supplies.

<a id="technical-adr-0042-evidence"></a>
### Evidence

Concept: [Observable consequences](0042-host-composed-instructions.md#concept-adr-0042-consequences).

- The staged system message equals the composed block byte for byte.
- Changing one byte of the block changes the staged request digest.
- An unknown member, an oversize section or a block over the ceiling refuses
  before any session record commits.
- A session with no block projects the fallback, and its request bytes equal
  a request staged before this decision.
- A block changed between runs applies to the next run and not to a run
  recovered after restart.
- A source check finds no instruction text in `apps/loopex` beyond the
  fallback.
- The reference default with the active tool definitions measures under
  1,000 estimated tokens, with the measured value retained.
- Real provider: the default block drives one coding task to completion.

<a id="technical-adr-0042-compatibility"></a>
### Compatibility and Rejected Alternatives

Concept: [Compatibility and rollback](0042-host-composed-instructions.md#concept-adr-0042-compatibility).

- *Keep the constant and add an appendix only.* Rejected. The host still
  could not replace core's wording, and core would still author prompt text.
- *Per-model prompt files.* Rejected for the reference host. One block is
  the smallest sufficient system, and a host that wants variants supplies
  them through the same option.
- *Templating in core.* Rejected. It puts prompt logic in the kernel and
  makes staged bytes depend on something other than committed data.
- *Put project files inside the block.* Rejected. It would bypass the
  admission decision and the provenance class ADR 0010 gives them.
