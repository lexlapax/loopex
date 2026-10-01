<a id="concept"></a>
## Concept

Technical depth: [Host provider routing and credential bindings](0048-host-provider-routing-and-credential-bindings-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0019](0019-host-owned-provider-protection.md#concept) only its sole `LOOPEX_PROVIDER_API_KEY` source; [ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept) only its single model/token/registry-binding restriction; [ADR 0039](0039-ephemeral-embedded-profile.md#concept) only its fixed selected-provider environment-variable names, durable single-source restriction and closed startup-option set for explicit provider references
- **Depends on:** [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept)
- **Prerequisite for:** M7 outcomes 3, 4 and 7

<a id="concept-adr-0048-decision"></a>
### Context and Decision

Technical depth: [Contract](0048-host-provider-routing-and-credential-bindings-technical.md#technical-adr-0048-decision).

A parent and a read-only helper may use different providers; an existing
conversation may explicitly switch providers between runs. ADR 0043's explicitly
configured summarizer may also use a different admitted provider. The host admits a
bounded immutable collection of provider bindings at runtime startup, one per
provider. The committed exact `provider:model` selects one binding. Model output,
role text and saved defaults cannot select an unadmitted credential.

Credentialed routes store only named environment references. Existing ephemeral
credential-free local-provider use remains supported without an invented key.
Durable local-provider support is not added by this proposal. Configuration for
credentialed routes stores only those references. No raw keys, files,
keychain lookups, commands, custom endpoints or multiple accounts for one
provider enter M7. Missing or mismatched binding refuses before dispatch; no
provider fallback is allowed.

Durable composition retains host custody and the separate-process handoff.
Ephemeral composition retains caller-only value resolution and ADR 0039's
host-VM audience, ambient-tool trust and cleanup limits. These paths must not
share a loader that gives either profile the other's credential lifetime.
Runtime restart may rebind the same provider to a host-authorized replacement
key; it never changes an admitted request's model or digest.
Host binding configuration is explicit in durable and ephemeral composition
options. Every reference host passes it through the same validated composition
boundary. Environment-variable names identify host-selected slots; they cannot
prove which provider issued the stored value.

<a id="concept-adr-0048-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0048-host-provider-routing-and-credential-bindings-technical.md#technical-adr-0048-evidence).

The operator can identify the provider used by each run, summary and child. Provider
A→B→A preserves canonical conversation facts and validates model capability
and context before committing each switch. Credentials, variable names and
custody handles remain outside durable model requests and public diagnostics.

<a id="concept-adr-0048-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0048-host-provider-routing-and-credential-bindings-technical.md#technical-adr-0048-compatibility).

The amendment leaves readiness, trace exclusion, private credential transfer,
deadlines, teardown and missing-custody refusal unchanged. It does not accept
ADR 0035's typed durable decision redesign. Existing single-provider callers
remain valid. Downgrade of roots with M7 configuration follows ADR 0044.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-acceptance-2026-09-30) | candidate `2986150b878151524ecdd9bac5a9779e69e196b4`; concept `sha256:26602eb1948ca9034940fa52adef8f027bb43056522cda27aec54e97a76d9233`; technical `sha256:dac68afe1dc995b17783439577020ca69ea41dd3ce209d88689c203c721fb81a` |
