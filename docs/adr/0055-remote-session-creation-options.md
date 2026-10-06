<a id="concept"></a>
## Concept

Technical depth: [Remote session creation options](0055-remote-session-creation-options-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-06
- **Decision owner:** Maintainer
- **Amends:** ADR 0044's remote creation and fresh-selection boundary, ADR 0049's immutable host selection projection, and ADR 0050's preparation invocation/lifetime scope. Existing v3 genesis, Store transaction identity and host authority remain.

<a id="concept-purpose"></a>
### Purpose and scope

Technical depth: [Authority and current evidence](0055-remote-session-creation-options-technical.md#technical-purpose).

M7 promises versioned remote creation options for configuration, instructions and
immutable selections. The current foreground and daemon accept an arbitrary
options object, while native creation uses already captured host defaults. A
field decoder alone cannot deliver the promise: model aliases require trusted
host resolution, tools must be selected before genesis, and initial settings
must be committed atomically rather than configured after creation.

Recommend one closed, versioned object for both new protocol generations. It
allows explicit initial settings and an ordered subset of the host's captured
model-visible tool names. It does not let a client construct capabilities,
provider routes, credentials, tool definitions or registries. The host continues
to own policy, workspace placement, cleanup, helper-role bindings and all
credential audiences. Authored instruction sections are data, including the
section called environment; they cannot change those host facts or grant effects.

<a id="concept-options"></a>
### Recommended options

Technical depth: [Closed input and capture](0055-remote-session-creation-options-technical.md#technical-options).

Require `session_options.version` to be the JSON integer `1`. Permit only optional
`configuration` and `tools`. Configuration is a nonempty subset of model,
reasoning, instructions, max_tokens, context_token_budget and system_class_tokens.
Instructions use the existing raw four-field input; token quantities use canonical
positive decimal strings. Tools is an ordered, duplicate-free array of names
from this host's captured creation defaults. Omitted tools keeps that captured
set; an empty array selects none. A name outside that set refuses even if another
tool with that name exists in a larger host registry.

Omission captures defaults once. Explicit values remain explicit, including
values equal to defaults. Omitted configuration uses the captured initial
configuration, validated against the selected tools. Unknown fields, nulls,
wrong versions and malformed values refuse before host preparation. Complete
configuration, instruction/tool budgets and the 65,536-byte genesis ceiling still
apply; field maxima do not guarantee that every combined object fits.

<a id="concept-preparation"></a>
### Fresh creation preparation and lifetime

Technical depth: [One owned preparation and initial version](0055-remote-session-creation-options-technical.md#technical-preparation).

For a fresh request with configuration changes, extend the existing optional
`Model.prepare_configuration/5` invocation to initial creation. Its baseline is
the host-captured version-1 configuration and selected immutable definitions.
It still prepares only a candidate. Validate the existing authored-to-canonical
alias rule, then rebase the verified next-version candidate from version 2 to
initial version 1 before genesis. This pure version change creates no configured
event or intermediate session. Missing preparation capability refuses explicit
configuration; default-only and tool-only creation remain available when their
captured configuration is valid.

Creation preparation belongs to runtime Control and its existing runtime-owned
private worker/group custody, before any session coordinator exists. There is
at most one fresh creation preparation per runtime; overlapping creates receive
the dispositions below, while stop and status remain serviceable. Capture one 60,000 ms
monotonic work cutoff at creation worker start, before Store reads and host
preparation, and the host's immutable creation cleanup grace. Caller/runtime loss or expiry retires and joins invocation work before
success; uncertainty cannot publish successful creation. No credential is
acquired and no model or executor request is dispatched. The already accepted
shared host catalog lifecycle stays distinct; cold catalog contention spends
this preparation deadline.

Accepting only the grammar would leave these new invocation, ownership and
version semantics undecided. This proposal binds them together. Core still
imports only Model; composition resolves aliases and admitted host routes. A
fresh prepared model may differ from the startup model only after this trusted
route validation. No unchecked native supplied genesis gains that exemption.

<a id="concept-overlap"></a>
### Overlapping creates

Technical depth: [Admission without a waiting queue](0055-remote-session-creation-options-technical.md#technical-overlap).

While one creation owns the pre-session slot, a distinct create and an identical
repeat of its command return a transient refused admission with the new reason
`creation_in_progress`. A same-ID request with different authored input returns
`runtime_command_conflict`. These replies activate nothing, write no refusal or
command mapping and do not cancel, replace or extend the original invocation.
The original caller alone receives its eventual creation result. Unjoined
invocation work keeps that one creation slot unavailable; it supplies neither a
second group nor another cleanup allowance. Unrelated session work stays
serviceable. There is no
application-level create waiting queue or collection of duplicate reply waiters.

This new reason is an explicit public contract addition in this proposal, not a
claim that a busy runtime is unavailable or the creation outcome is unknown.
A client may present the same command after the slot settles to obtain its
retained result or begin a fresh attempt if no creation was admitted. Existing
bounded transport intake still governs messages before Control handles them;
this specifies no new wall-clock promise for mailbox scheduling. Stop and caller
loss retain existing work/cleanup obligations.

<a id="concept-replay"></a>
### Capture, identity and replay

Technical depth: [Retained binding before resolution](0055-remote-session-creation-options-technical.md#technical-replay).

The current v3 genesis retains normalized authored options and the complete
canonical initial configuration/tool selection in one existing create
transaction. Keep the authored model spelling. Store instruction section bytes
once, in the complete initial configuration; options retain their version/digest
descriptor. Replay reconstructs and compares the exact authored sections, not
merely a matching rendered digest.

An identical create command returns its original session and disposition before
any fresh alias/default/tool resolution. Different authored options under that
command conflict. Omission and an explicit equal value are different inputs;
ordered tool arrays retain order. Defaults and catalogs may change for a new
command without changing an earlier result. Unknown creation keeps the original
complete transaction and fences its runtime mutation domain. Neither replay nor
unknown recovery prepares a replacement or activates a historical session.
Existing Store provenance/history and exact lookup provide the retained binding.
An absence probe uses only the runtime's already startup-captured baseline, not
the request's candidate or refreshed host defaults. Only an authoritative absent
key permits new preparation; missing, open, conflicting or unavailable retained
evidence never substitutes for that result.

<a id="concept-impact"></a>
### Alternatives and acceptance impact

Technical depth: [Activation, alternatives and proof](0055-remote-session-creation-options-technical.md#technical-impact).

The alternative is a closed default-only object `{version: 1}`. It preserves
atomic creation with host startup settings and needs no fresh preparation use,
but it would amend M7 to remove remote initial configuration/instruction/tool
selection. Configuring afterward is a separate transaction, and immutable tools
cannot be reproduced that way. A caller would need another configured host to
choose those tools. This is a smaller product scope, not an equivalent delivery
of M7's promise.

The recommended option adds adapter conformance and actual creation-lifetime,
replay, overlap admission, unknown-transaction and host-authority proofs. Update
both complete
foreground/daemon manifests, decoders and independent clients together before
activating the new generations. Only current contracts remain before 1.0; older
options objects and clients refuse rather than using a fallback. Existing current
v3 captured histories remain readable without reinterpreting their settings.
Rollback removes new admission from service while retaining exact current
history/recovery readers; it cannot replace committed captures with defaults.
This proposal authorizes no closure, release or implementation before acceptance.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
