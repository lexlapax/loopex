<a id="concept"></a>
## Concept

Technical depth: [Configure request grammar](0053-current-configure-request-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-10-06
- **Decision owner:** Maintainer
- **Proposed amendment:** [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept), only the exact configure request grammar in its current foreground generation 3 and daemon generation 4.
- **Constrained by:** [ADR 0042](0042-host-composed-instructions.md#concept), [ADR 0050](0050-host-configuration-preparation.md#concept), existing transport authority and framing, and the [pre-1.0 current-contract rule](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02).

<a id="concept-adr-0053-decision"></a>
### Purpose and proposed decision

Technical depth: [Exact fields and domains](0053-current-configure-request-technical.md#technical-adr-0053-decision).

Give both wire clients one exact request for the already accepted settled-only
configure command. ADR 0044 requires a nonempty mutable update but does not name
its outer request member or its quantity representation. Native commands call
the authored update `changes`; committed configuration is a separate complete
fact.

Use `changes`. Foreground requests contain exactly `request_id`, `method`,
`command_id` and `changes`. Daemon requests additionally require the existing
`writer_epoch`. The method is `session.configure`; the attachment selects the
session. Changes contain any nonempty subset of model, reasoning, instructions,
reply limit, context budget and system ceiling. The three quantities use
canonical positive uint64 decimal strings. Model and reasoning keep their
existing domains. Raw instructions contain exactly version, base, environment
and appendix, with their existing byte limits; clients cannot supply a digest
or private metadata. Unknown members refuse.

<a id="concept-adr-0053-admission"></a>
### Authority, preparation and command identity

Technical depth: [Existing admission semantics](0053-current-configure-request-technical.md#technical-adr-0053-admission).

Keep foreground attachment authority and daemon controller fencing. Central
Model preparation validates the complete candidate against committed settings
and immutable tools. Unsupported or invalid candidates leave configuration
unchanged. This request supplies no capability, catalog, credential route,
prepared candidate or grant. Preparation dispatches no model or executor work.

Retain the authored model spelling, including an admitted alias, in command
identity. An identical command returns its original disposition without another
resolution; a different payload under the same command ID conflicts. Unknown
admission retains the original proposal and transaction. Configuration output
continues to name the captured canonical model.

<a id="concept-adr-0053-impact"></a>
### Alternatives, compatibility and proof

Technical depth: [Implementation and verification](0053-current-configure-request-technical.md#technical-adr-0053-impact).

1. **Use `changes`, recommended.** Wire and native authored commands share the
   same name. Both transports and independent clients implement one closed
   decoder and exact quantity conversion.
2. **Use `configuration`.** The same update and preparation rules apply, but
   clients and transports translate this partial request into native `changes`.
   The name also appears on complete committed configuration output.

Only the selected spelling is served. Before 1.0, remove superseded decoders and
aliases rather than serving both. This decision changes no persistence,
configuration output, preparation timeout, host authority or native command
semantics. It adds exact request definitions to the coordinated current
manifests and clients. Current restart/replay, unknown-admission resolution,
lease fencing and owned preparation cleanup remain required.

Prove closed decoding, exact scalar boundaries and instruction capture with
independent vectors and both transports' real configure workflows. Acceptance
binds this exact pair before dependent implementation. It does not activate a
partial manifest or authorize milestone closure, publication or relaxed checks.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-configure-request-2026-10-06) | candidate `838cf0e3a9faa0fe13a8824465115a3372bad15b`; concept `sha256:4b15cd997d612b39769274c3614988f0911f2c3a804a2db8fa0541ea806691b6`; technical `sha256:faee5f4558fcc40658b601aaa107979123efb5a64cdd68279cc3abd8451e1a21` |
