# 0044. Run model and reasoning configuration

<a id="concept"></a>
## Concept

Technical depth: [Record, options and evidence](0044-run-model-and-reasoning-configuration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-29
- **Decision owner:** Maintainer
- **Supersedes:** nothing accepted. It conflicts with clause 7 of Proposed
  [ADR 0037](0037-host-configuration-and-path-discovery.md#concept), which
  fixes the model when the composition starts; accepting both requires
  0037 to be revised first
- **Prerequisite for:** M7 outcome 4 (draft), accepted before the
  configuration record is written

<a id="concept-adr-0044-decision"></a>
### Context and Decision

Technical depth: [Record and options](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision).

A session's model is a launch option of its coordinator. It is not a durable
session fact: the model name appears only inside each committed request. A
resumed session takes whatever model the resuming command composed, and
nothing checks that it matches. The only sampling value a host may send is
the output limit, so a model that can reason harder is never asked to.

The vision expects more. It names a `set model` session command and a
`session.configured` event that records "model, reasoning-level, and
active-tool-set changes". It keeps model roles and reasoning controls in the
host, and gives core "exact model identity and declared capabilities".

**The decision.**

1. **Session configuration is a durable fact.** The session records its
   model identity and reasoning level. A change commits a configuration
   record and publishes `session.configured`.
2. **Configuration changes between runs only.** A run stages every request
   with the configuration committed at its admission. There is no model
   switch inside a run.
3. **Reasoning level is a closed set:** `none`, `low`, `medium`, `high` and
   `default`. `default` sends nothing and leaves the choice to the provider.
4. **Core carries the level; the adapter maps it.** An adapter declares
   whether its model accepts a level. A level the model cannot accept is
   refused at configuration, not silently dropped.
5. **Provider state does not cross an incompatible change.** Provider-affine
   state such as reasoning signatures is stripped from the projection when
   the model or provider changes, as the vision requires.
6. **Resume uses the recorded configuration.** A resuming command that names
   no model gets the session's. One that names a different model makes an
   explicit configuration change.
7. **Roles stay in the host.** Names such as `fast` or `capable` resolve to
   an exact model identity in the host before anything reaches core.

<a id="concept-adr-0044-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-evidence).

An operator can ask for more reasoning on a hard task and can move a session
to another model between prompts. An observer always knows which model
produced a run. Higher reasoning levels cost more tokens and time, within
the run's declared bounds.

<a id="concept-adr-0044-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility and rejected alternatives](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-compatibility).

The configuration record and event are additive. A session created before
this decision has no record; its first resume commits one from the composed
model. The durable profile still serves one provider credential, so a change
of provider waits for the per-provider credential decision.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
