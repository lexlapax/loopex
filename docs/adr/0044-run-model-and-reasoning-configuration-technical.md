<a id="technical-depth"></a>
## Technical depth

Concept: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration.md#concept).

<a id="technical-adr-0044-decision"></a>
### Contract

Concept: [Context and decision](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-decision).

The closed configuration contains exact `model` string, `reasoning`,
`configuration_version`, `instructions` bytes/digest under ADR 0042, `max_tokens`,
`context_token_budget`, `system_class_tokens` and budget origins. Initial legacy
fallback may be represented explicitly without rewriting prior requests. Active
tools remain the immutable generation under ADR 0009; changing them is out of
M7's configure command.

`configure` is a normal idempotent session command containing any nonempty subset
of mutable model/reasoning/instructions/max_tokens/context_token_budget/
system_class_tokens. Merge against committed state, validate the whole candidate,
and commit one version or one unchanged refusal. Replayed identical command ID
returns its original disposition; different payload reuse refuses. The session
must be settled with no unresolved effect, provider attempt or maintenance.
Configuration preflight may report compaction required; it does not call a model
or compact as a side effect. The operator can compact with the prior model first.

Validation uses ADR 0048's admitted provider routes, declared model capabilities,
ADR 0041's window/reserve calculation and exact byte/token staging preflight with
the retained history and immutable active tools. Recompute derived budgets when
a model or reply reserve changes; explicit overrides remain explicit and must
still fit. A rejected candidate changes neither projection nor defaults.

Each new run and maintenance episode binds its configuration version at admission.
`reasoning` enters canonical sampling and digest when non-default; `default`
omits it. Existing committed request bytes and provider attempts remain immutable.
The ReqLLM adapter maps admitted levels to its verified `reasoning_effort` support;
never assume every model accepts every catalog value. Unknown capability permits
`default` only. Reasoning token budgets and provider-specific option bags stay out.

For projection under a new model, strip opaque continuation tokens, reasoning
signatures/content and provider-specific tool metadata from messages produced by
incompatible model identities. Keep canonical text, tool arguments and committed
results. Normalize tool IDs deterministically from `(run_id, turn, call_id)`
under ADR 0041; return to A does not resurrect stripped B-affine state or old
continuation tokens. M7 uses canonical-history replay only: continuation remains empty even for
the same model, as ADR 0010 requires. Retained provider-private reasoning,
signatures and response state never become later request input. Conversion is
a pure projection, not journal rewriting. Native continuation requires a separate
amendment and is outside this decision.

Protocol adds `session.configure`, `session.configured` and configuration snapshot
fields with a new experimental schema/generation jointly with ADRs 0043/0045.
No old client receives unknown shapes under unchanged negotiation. Exact vectors
and independent Node client update precede implementation integration.

<a id="technical-adr-0044-evidence"></a>
### Evidence

Concept: [Observable consequences](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-consequences).

- Atomic creation/configure, strict validation, version capture and idempotency.
- Active/unresolved change refusal; legacy model derivation versus conflict.
- Restart at configure and staging boundaries preserves configuration/digest.
- Reasoning capability negatives, default omission and real non-default usage.
- Deterministic same-model/cross-provider history, repeated tool IDs and raw-history
  preservation; real A→B→A with restart and tool results.
- Schema negotiation, events/snapshots and independent client vectors.

<a id="technical-adr-0044-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-compatibility).

A future adapter may extend capability mapping through a new explicit decision.
No within-run switching, automatic model routing or mutable tool generation is
admitted. Legacy-root upgrade records the inferred configuration only when its
identity is proved. Exact downgrade fixtures must distinguish unchanged staged
requests from new configuration/schema support; backups preserve the prior state.
