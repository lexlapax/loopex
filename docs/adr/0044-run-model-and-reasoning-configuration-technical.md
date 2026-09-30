<a id="technical-depth"></a>
## Technical depth

Concept: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration.md#concept).

<a id="technical-adr-0044-decision"></a>
### Contract

Concept: [Context and decision](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-decision).

The closed configuration contains exact `model` string, `reasoning`,
`configuration_version`, `instructions` bytes/digest under ADR 0042, `max_tokens`,
`context_token_budget`, `system_class_tokens`, budget origins and the resolved
`model_capabilities` envelope defined below. Initial legacy
fallback may be represented explicitly without rewriting prior requests.

One coordinated `session_genesis_v3` extends ADR 0016's v2 with this initial
configuration, full immutable tool definitions/name mapping and policy-defer
mode from ADR 0046. The closed payload is:

```text
{kind: "session_genesis_v3",
 options: normalized_session_options,
 runtime_configuration: {cleanup_grace_ms: positive_uint64},
 initial_configuration: <the closed configuration above>,
 tool_selection: {definitions: [<complete normalized definitions>],
                  names: <name-to-id/version/digest map>},
 policy_defer_mode: "admit" | "refuse"}
```

Use the existing record envelope for journal version 1, owner epoch 0 and nil
owner incarnation; those are not extra genesis payload members. Definition
format versions distinguish legacy effect definitions from interaction-class
ones. Require each name mapping to match exactly one retained definition and
reject duplicates/unused mappings. Preserve mandatory committed cleanup.
Preflight the complete genesis against 65,536 bytes before create commits.
The M7 decoder explicitly reads v2/v3. Preserve v2 staged requests/effects;
resolve historical selections from retained evidence, rejecting contradictions.
For a settled session with no historical request, require an explicit host
selection and commit its migration before dispatch. An unfinished session
without sufficient evidence refuses unsupported recovery, preserving admission
and uncertainty; no invented default may dispatch it. Never infer helper status; legacy
policy uses `admit`. Missing cleanup remains invalid. Prove actual M6 reader
behavior on disposable v3 copies; no claim that the old binary knows v3 follows.

Active tools remain the immutable generation under ADR 0009; changing them is out of
M7's configure command.

`configure` is a normal idempotent session command containing any nonempty subset
of mutable model/reasoning/instructions/max_tokens/context_token_budget/
system_class_tokens. Merge against committed state, validate the whole candidate,
and commit one version or one unchanged refusal. Replayed identical command ID
returns its original disposition; different payload reuse refuses. The session
must be settled with no unresolved effect, provider attempt or maintenance.
Configuration preflight may report compaction required; it does not call a model
or compact as a side effect. The operator can compact with the prior model first.

Host admission first checks controller authority and any host-owned ceilings.
Validation uses ADR 0048's admitted provider routes, declared model capabilities,
ADR 0041's window/reserve calculation and exact byte/token staging preflight with
the retained history and immutable active tools. Recompute derived budgets when
a model or reply reserve changes; explicit overrides remain explicit and must
still fit. A rejected candidate changes neither projection nor defaults.

The host normalizes the pinned ReqLLM/LLMDB catalog into bounded plain metadata:
exact model, optional positive context/output limits, verified reasoning subset,
source revision and digest. Core receives no dependency structs and performs no
catalog lookup. At most five reasoning levels and a 128-byte source revision
are admitted; the whole canonical metadata envelope is at most 2 KiB. Retain its
values and provenance with each configuration; replay never reinterprets a run
using a newer catalog. Public configure input cannot supply capability metadata;
the host resolves and validates it before committing the internal configuration.
A claimed reasoning level requires adapter conformance,
not just a catalog label. Require `max_tokens <=` the known model output limit.
Only an unknown context window uses ADR 0041's 8,192 input fallback; unknown
output capacity has no invented catalog guarantee. Existing explicit reply
limits remain enforced and visible.

Each new run and maintenance episode binds its configuration version at admission.
`reasoning` enters canonical sampling and digest when non-default; `default`
omits it. Existing committed request bytes and provider attempts remain immutable.
The ReqLLM adapter maps admitted levels to its verified `reasoning_effort` support;
never assume every model accepts every catalog value. Unknown capability permits
`default` only. Reasoning token budgets and provider-specific option bags stay out under the
current canonical-only draft, pending the maintainer's scope decision. Inspect
the adapter's effective outgoing request before dispatch: dependency option
translation cannot raise the committed `max_tokens` or enable an unadmitted
reasoning mode. Reject or explicitly normalize before staging, never afterwards.

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


Source evidence for the pending choice, checked 2026-09-30: the official
[Anthropic tool/thinking workflow](https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows)
requires applicable thinking blocks to accompany tool results unchanged. A
text-only completion does not prove that workflow compatible with empty
continuation. Pinned ReqLLM 1.24.0's `adjust_max_tokens_for_thinking/2` raises a
reply limit at or below its thinking budget to that budget plus 201; its legacy
high mapping uses 4,096. Thus a nominal 4,096 can become 4,297. Request-level
vectors and a real admitted tool loop must prove the selected compatibility
subset and unchanged effective reply ceiling. No provider credential or live
call was used for this planning research.
