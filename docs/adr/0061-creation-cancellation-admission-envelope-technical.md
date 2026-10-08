<a id="technical-depth"></a>
## Technical depth

Concept: [Creation cancellation admission decision](0061-creation-cancellation-admission-envelope.md#concept).

<a id="technical-adr-0061-purpose"></a>
### Existing records and the wording conflict

Concept: [Purpose and evidence](0061-creation-cancellation-admission-envelope.md#concept-adr-0061-purpose).

Accepted [ADR 0055](0055-remote-session-creation-options-technical.md#technical-options)
changes creation options and semantics while preserving the admission/result
envelope. Its overlap table uses `no_activation` in the native column; the
remote column requires a refused admission without a session ID.
Accepted [ADR 0059](0059-responsive-creation-transactions-technical.md#technical-adr-0059-recovery)
adds `creation_cancelled` and explicitly describes a remote `disposition
no_activation`. Its Concept cancellation paragraph likewise calls that an
existing remote envelope.

Actual foreground `apps/loopex_app_server/lib/loopex_app_server/mapping.ex`
`admission/4` and daemon
`apps/loopex_daemon/lib/loopex_daemon/wire_records.ex` `admission/5` emit the same
six admission members, adding a session identity on successful create/resume.
The daemon's private argument named `disposition` becomes `status` and `reason`,
not a JSON member. Both current protocol manifests,
`apps/loopex_protocol/priv/schema/loopex-experimental-1.json` and
`loopex-experimental-2.json`, define those members and no admission disposition.
These source observations establish the ambiguity, not acceptance or a serving
contract for M7.

This clarification follows the vision's
[shared protocol semantics](../vision.md#concept-vision-public-protocol) and
[truthful cancellation](../vision-technical.md#technical-vision-recovery-truth).
It preserves the [accepted M7 protocol integration](../plans/M7-technical.md#technical-plan-prerequisites)
and ADR 0044's distinct complete generations rather than using a current served
manifest as authority to expose a partial new contract.

<a id="technical-adr-0061-decision"></a>
### Exact cancellation record and amendment boundary

Concept: [Recommended decision](0061-creation-cancellation-admission-envelope.md#concept-adr-0061-decision).

The terminal remote cancellation branch is a closed ordinary JSON object with
exactly these members:

| Member | Required value or existing domain |
| --- | --- |
| `type` | Literal `admission` |
| `request_id` | Echoed connection-local request identity: 1–64 ASCII bytes from `[A-Za-z0-9._~-]`, under ADR 0023 |
| `method` | Literal `session.create` |
| `command_id` | Echoed creation command identity: canonical unpadded base64url of 1–256 original opaque bytes, retaining the existing create-specific facade bound |
| `status` | Literal `refused` |
| `reason` | Literal `creation_cancelled` |

For example, command bytes `0xff` and request identity `cancel-1` produce:

```json
{"type":"admission","request_id":"cancel-1","method":"session.create","command_id":"_w","status":"refused","reason":"creation_cancelled"}
```

`session_id` and `disposition` are absent, including their null forms. Unknown,
missing or additional members refuse this branch. A cancellation reason cannot
be paired with accepted status, another method or a session identity.
Decoding establishes shape and correlation data; it does not prove cancellation
or grant authority. Connection request matching remains with the existing
transport/client machinery. No quantity member is added; all existing quantity
and opaque identity domains in other records remain unchanged.

Only ADR 0059's Concept cancellation paragraph's remote
refused/`no_activation` envelope description and its Technical depth terminal
cancellation paragraph's remote `disposition no_activation` wording are
superseded. Read them as refused/`creation_cancelled` with no session ID and
zero activation. Keep native `{:error, :creation_cancelled}` in its existing
mode and its existing detailed result shape where applicable. Preserve all
other ADR 0059 carrier, custody, generation, cancellation/close, original
candidate, transaction, replay, capacity, deadline and cleanup rules. In
particular, cancellation is retained proven non-commit; Store uncertainty
remains unavailable/unknown and never becomes cancellation by decoding.

Identical authored replay still returns retained cancellation without
preparation, catalogue or default resolution. Changed authored input conflicts.
A codec cannot substitute for those durable runtime/replay proofs.

<a id="technical-adr-0061-alternatives"></a>
### Alternative scope and current-contract integration

Concept: [Alternative and consequences](0061-creation-cancellation-admission-envelope.md#concept-adr-0061-alternatives).

A literal disposition field would alter the public envelope. Its exact presence
and value for other creation outcomes would require another accepted decision;
this pair defines no such branch. The recommended record requires no Store
migration, cancellation recipe change, native DTO change or compatibility shim.
Before 1.0, retain only the selected current contract; current-format restart,
replay, authority, cleanup and restore obligations remain mandatory.

The [M7 plan](../plans/M7-technical.md#technical-plan-prerequisites) requires complete
foreground `loopex.experimental/3` and daemon `loopex.experimental/4` manifests,
including payload schemas in their canonical digest recipes. Include this
closed cancellation branch in both complete definitions and independently
pinned client digests. Existing served generation 1/2 metadata digests cannot
carry the new payload. A dormant codec and vectors may be prepared after exact
pair acceptance, but serving activation waits for coordinated integration.
Implementation rollback removes unactivated code as appropriate; disabling
serving never erases retained cancellation facts or weakens ADR 0059 recovery.

Meaningful proof includes positive opaque-byte and request-boundary literals;
negative accepted status, wrong method, missing/extra/null members, malformed or
noncanonical base64url, empty/over-limit identities, invalid request identity,
and session/disposition injection. Preserve complete existing vector
populations and refusal reasons. Elixir and independent Node codecs must agree
on the closed branch. Both real transports must correlate cancellation to the
request and original command without a session ID or activation, including
retained identical replay and changed-input conflict. These required wire
proofs join ADR 0059's durable/replay and M7's complete-generation proofs;
source review or an isolated payload codec does not replace them.
