<a id="technical-depth"></a>
## Technical depth

Concept: [Explicit conversational run limits](0047-reference-host-run-defaults.md#concept).

<a id="technical-adr-0047-decision"></a>
### Contract

Concept: [Context and decision](0047-reference-host-run-defaults.md#concept-adr-0047-decision).

The host maps `--max-steps` to `max_turns`, `--deadline-ms` to `deadline_ms`,
`--token-budget` to `token_budget` and `--max-tokens` to the reply cap. Parse
positive integers without coercing strings, floats, booleans or overflow.
Apply the runtime's existing accepted maximum for each value where one exists;
otherwise cap host JSON integers at 2^53−1. Cross-field admission must leave a
positive input budget and obey the 65,536-byte request-record ceiling.

The selected file must itself have all three run-bound keys even if a flag
would override one. Invalid base declarations refuse rather than being hidden
by an override. Echo resolved values and origins without reading credentials.
Core and `ask` keep 16 turns, 600,000 ms and 1,000,000 run tokens where applicable,
and the existing 4,096 reply cap. Compaction uses ADR 0043's separately bounded
settled operation or charges an active run; child accounting follows ADR 0046.

For every coding task retain turns, reported/estimated tokens, wall duration,
largest reply, bound reached and objective result. Retain failed attempts. A
baseline increase needs a recorded reason and maintainer disposition before it
becomes the recommendation; a retry with larger limits is a distinct attempt.

<a id="technical-adr-0047-evidence"></a>
### Evidence

Concept: [Observable consequences](0047-reference-host-run-defaults.md#concept-adr-0047-consequences).

- File omissions, invalid values and conflicting CLI input refuse before dispatch.
- File values and flag overrides reach the committed run; resume retains them.
- Each bound produces its existing truthful terminal outcome.
- `ask` and core default fixtures remain unchanged.
- Every real task has a measurement record, including failed attempts; no larger
  recommendation is presented as selected without its disposition.

<a id="technical-adr-0047-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0047-reference-host-run-defaults.md#concept-adr-0047-compatibility).

Larger automatic defaults and an unbounded mode were rejected. Requiring file
limits implements the maintainer's choice even when the command has flags.
The configuration schema is experimental; ADR 0049 owns its version and readers.
No default increase is required for acceptance of this proposal.
