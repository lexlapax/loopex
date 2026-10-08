<a id="concept"></a>
## Concept

Technical depth: [Creation cancellation admission mechanics](0061-creation-cancellation-admission-envelope-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-07
- **Decision owner:** Maintainer
- **Amends:** [ADR 0059](0059-responsive-creation-transactions.md#concept)'s remote cancellation envelope wording only. All other creation, custody, recovery and verification obligations remain in force.

<a id="concept-adr-0061-purpose"></a>
### Purpose and evidence

Technical depth: [Existing records and the wording conflict](0061-creation-cancellation-admission-envelope-technical.md#technical-adr-0061-purpose).

Clients must distinguish proven creation cancellation from Store unavailability
without receiving a fabricated session identity. ADR 0059 names a remote
`no_activation` disposition in an existing envelope, but both existing remote
admission records have six members and no disposition field. ADR 0055 preserves
that envelope. The ambiguity blocks an exact cancellation codec and its vectors.

<a id="concept-adr-0061-decision"></a>
### Recommended decision

Technical depth: [Exact cancellation record and amendment boundary](0061-creation-cancellation-admission-envelope-technical.md#technical-adr-0061-decision).

Preserve the remote admission envelope. A terminal creation cancellation has
exactly `type`, `request_id`, `method`, `command_id`, `status` and `reason`.
Its fixed values are `admission`, `session.create`, `refused` and
`creation_cancelled`; it echoes the valid request and command identities and
has no `session_id` member. It also has no wire `disposition` member.

`no_activation` names the native detail where that existing mode supplies it,
and the remote guarantee that cancellation activates no session. It is not an
additional JSON field. This decision narrowly supersedes ADR 0059's references
to a remote refused/`no_activation` envelope and remote `disposition
no_activation`. It changes no other refusal reason, accepted or unknown result,
native result mode, carrier ownership, durable cancellation, authored replay,
cleanup bound, canonical recipe or Store contract.

<a id="concept-adr-0061-alternatives"></a>
### Alternative and consequences

Technical depth: [Alternative scope and current-contract integration](0061-creation-cancellation-admission-envelope-technical.md#technical-adr-0061-alternatives).

The alternative adds a literal remote disposition field. It would require a
separate exact specification for accepted creation, other refusals and unknown
results, followed by coordinated server, manifest, codec and independent client
updates. This proposal does not select or implicitly design that alternative.
Preserving the existing record gives clients one stable cancellation reason and
keeps the zero-activation guarantee in the runtime's proved behavior.

Both options retain ADR 0059's durability and replay requirements. The
recommended option adds no persistent schema or old-client compatibility path.
M7 still qualifies complete foreground generation 3 and daemon generation 4
contracts and digests before serving new payloads. Acceptance of this pair
permits the narrowly specified cancellation codec work; it does not activate a
partial generation, close M7, merge or publish a release.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
