# 0017. Durable context and record admission budgets — technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Durable context and record admission budgets](0017-durable-context-admission-budget.md#concept).

<a id="technical-adr-0017-context"></a>
## The Two Missing Admission Dimensions

Concept: [Context](0017-durable-context-admission-budget.md#concept-adr-0017-context).

The context receipt already measures per-block costs, but no durable value turns
their sum into a repository-estimator admission decision. Separately, Store validates every
private record against an exact 65,536-byte encoded-item ceiling. Context token
cost omits envelope and provenance bytes, so neither limit implies the other.

The split is observable in the reference stack. The exact provider-facing system
message plus four model-facing tool projections is 2,331 canonical bytes and 779
estimated tokens. The receipt's full tool-definition accounting is 4,382 bytes
and 1,462 tokens before its own structural overhead. A 65,536-byte project file
produces a 65,655-byte canonical project message and an approximately 69,735-byte
request before receipt duplication, so the intake maximum cannot be a staging
promise.

<a id="technical-adr-0017-decision"></a>
## Exact Two-Dimensional Admission

Concept: [Decision](0017-durable-context-admission-budget.md#concept-adr-0017-decision).

Run admission state adds:

```text
context_token_budget positive_uint64
```

The field is not a fourth member of `Loopex.Bounds.bounds/0` and cannot produce
`bound_reached`. An accepted top-level prompt is exactly:

```text
%{
  kind: "prompt_admitted_v2",
  "command_id" => nonempty_bounded_binary,
  "command_digest" => lowercase_sha256_hex,
  "command_type" => "prompt",
  "admission" => "accepted",
  "run_id" => nonempty_bounded_binary,
  "content" => nonempty_bounded_binary,
  "max_turns" => positive_uint64,
  "token_budget" => positive_uint64,
  "deadline_ms" => positive_uint64,
  "context_token_budget" => positive_uint64
}
```

Its exact key set is the eleven keys shown; missing or unknown members refuse
replay. The prompt command digest binds the normalized command identity, type,
content, and all four committed configuration values together. Other accepted
and refused command kinds retain their existing exact shapes. The new reducer
rejects a legacy accepted prompt admission using `command_admitted`, and the
prior reducer rejects `prompt_admitted_v2`. A queued follow-up remains exactly
`{type, command_id, content}` under ADR 0011. Promotion inherits all four values
from the active run's committed configuration under ADR 0013; it does not read a
new command option or duplicate bounds into the queued record. Recovery requires
the committed member. Old development records without it and prior runtimes
that do not recognize the new prompt record kind both fail unavailable.

The fixed record ceiling is read from core's Store contract rather than
duplicated as a caller option:

```text
Store.max_item_bytes() -> 65_536
Store.normalize_and_measure_item(:record | :event, item) ->
  {:ok, normalized_item, encoded_bytes} | {:error, reason}
```

These are core functions, not adapter callbacks, and an adapter cannot override
either result. `normalize_and_measure_item/2` applies the same record-or-event
normalization, exact deterministic external-term encoding, depth/cardinality
checks, and 65,536-byte ceiling that `Store.transact/2` applies. Staging uses the
returned normalized item as the exact transaction member; no approximate string
sum, second encoding, or normalize-after-preflight path defines the budget.

ADR 0010's class ceilings are:

```text
system_class_token_ceiling = 1_000
project_resource_class_token_ceiling =
  Bounds.estimate(canonical_project_block(ProjectResource.class_total_bytes()))
  = 21_885 at this proposal's canonical bytes and estimator
```

The second value is a derived invariant, not a separately configurable literal.
Changing the wrapper, estimator, or accepted intake ceiling changes the derived
measurement and its evidence together. The committed `context_token_budget` is
the total ceiling across the final provider-visible request; passing it never
waives either applicable class ceiling.

For M2's one-label resource shape, the accepted per-file and class-total byte
ceilings are equal, so an admitted block cannot exceed the derived project class
token ceiling. A property proves that relationship at the exact maximum. The
check and receipt field remain for future multi-label shapes, but no M2 evidence
claims an independently reachable class-token refusal.

Estimated context cost is:

```text
sum(Canonical.encode(message) |> Bounds.estimate()
    for message in final_provider_messages)
+
sum(ToolDefinition.model_facing(definition)
    |> Canonical.encode()
    |> Bounds.estimate()
    for definition in final_active_tools)
```

Full tool-definition bytes and generation triples remain in the durable staged
request and are covered by exact record bytes. The receipt names the estimator,
ordered descriptors, per-class token totals, provider total, record byte cost,
and both ceilings. Source references and trust labels are storage facts; they
are never silently charged as provider content.

This estimator-owned ceiling is deterministic before dispatch. It does not
claim to reproduce any provider tokenizer or prove that a chosen model accepts
the request; provider capability remains a host/provider concern. The runtime
does claim that the exact provider-visible bytes were measured under the named
repository estimator and did not exceed the committed admission policy.

Evaluation is ordered:

1. build the exact provider-visible messages and active tool projections;
2. measure provider tokens, verify descriptor source/content digests, and
   enforce the 1,000-token `system` class ceiling;
3. withhold a project class that exceeds its accepted 65,536-byte intake limit;
   evaluate and retain the derived class ceiling, whose M2 one-label invariant
   proves that no intake-valid block exceeds it;
4. if required provider content exceeds its class ceiling or
   `context_token_budget`, construct the compact refused receipt and atomically
   retain it with `failed(context_budget_exceeded, false)` and the public
   terminal event, dispatching nothing;
5. if adding project content alone exceeds the token budget, withhold the whole
   class, rebuild, and record `project_resource_declined(context_token_budget)`;
6. construct the exact successful `model_request_committed` candidate with full
   tool definitions and receipt, then measure it through Store's exact function;
7. if project content is present and the candidate exceeds the record ceiling,
   withhold the whole class, rebuild, and record
   `project_resource_declined(context_record_bytes)`;
8. if the required-only candidate still exceeds the record ceiling, atomically
   retain the compact refused receipt, `failed(context_budget_exceeded, false)`,
   and its public terminal event, dispatching nothing; and
9. commit the admitted receipt and staged request atomically before dispatch.

The compact refusal receipt contains bounded category and dimension, estimator
identity, project disposition, class counts, one digest over the final ordered
descriptor identities, observed token and record-byte totals, and both limits.
It contains neither the descriptor list nor descriptor content or source
references, so its size is independent of history length. Its own exact encoded
bytes must validate before the atomic receipt-and-terminal transaction can be
proposed; inability to retain even that transaction is Store unavailability,
never a fabricated context verdict or a stranded failed run.

Step 7 is not trimming. Project resources are optional under ADR 0010, and the
request is canonicalized only after the whole class is removed. Session history,
system content, steer input, and active tool definitions are never dropped or
summarized. No pre-dispatch refusal increments cumulative provider usage.

Cumulative accounting no longer uses this admission estimator as a substitute
for provider usage. A complete provider usage report retains ADR 0010's exact
reported charge. For any dispatched turn whose usage is absent or partial, or
whose reply is incomplete, the retained `estimated` charge is exactly
`token_budget - cumulative_tokens_before_call`. That makes the cumulative value
equal the committed bound before any further provider dispatch. It is a
conservative allowance charge, not a reconstructed provider invoice, and it
supersedes ADR 0010's two estimator-based fallback rows together rather than
silently weakening them.

<a id="technical-adr-0017-alternatives"></a>
## Alternative Costs

Concept: [Alternatives](0017-durable-context-admission-budget.md#concept-adr-0017-alternatives).

A token-only check leaves uncharged provenance able to trip Store. A Store-only
check cannot enforce the chosen context-admission policy. Reusing cumulative usage minimizes schema
but destroys semantic independence. Requiring an explicit value from every
reference operator removes one default but also removes a working out-of-box
reference policy. Continuing to estimate cumulative spend after incomplete
provider usage would permit undercount; provider-specific tokenizer ownership
would broaden core. Selective history trimming breaks lineage truth. The
selected pair adds one host-owned scalar and one exact fixed preflight while
keeping every existing terminal meaning intact.

<a id="technical-adr-0017-consequences"></a>
## Compatibility, Rollback, and Evidence

Concept: [Consequences](0017-durable-context-admission-budget.md#concept-adr-0017-consequences).

Required closure evidence includes:

- the measured reference base binds the exact provider-visible bytes and stays
  below 1,000 tokens while the full definitions remain in the durable request;
- estimated-context and exact-record-byte boundaries pass one below and exactly at
  their ceilings and refuse one above;
- a request below its token ceilings but above the exact record ceiling is
  caught before Store, proving token success cannot fall through to
  `item_too_large`;
- an over-intake, total-token, or record-only project block is wholly withheld,
  stages no project descriptor, and lets the task continue with a truthful
  declined receipt; a separate property proves the derived project class
  ceiling bounds every intake-valid M2 block rather than pretending that branch
  is independently reachable;
- required context over either dimension commits run `failed`, zero provider
  calls, a compact retained receipt, and no partial staged request or fabricated
  assistant message;
- cumulative `token_budget` remains distinct and its `bound_reached` observed
  value is never populated from either admission dimension; complete reported
  usage remains exact, while missing, partial, and incomplete provider evidence
  consumes the entire remaining run budget before another dispatch;
- prompt, queued follow-up admission, promotion, succession, and restart reuse
  the exact committed context budget rather than the current runtime default;
- the queued follow-up retains ADR 0011's exact input shape while promotion
  inherits all four committed predecessor values under ADR 0013;
- malformed, missing, overflowed, or inconsistent budget/cost data fails closed;
  and
- mutants substituting cumulative budget, dropping a provider-visible tool
  projection, measuring a non-final record, repeating oversized bodies in the
  refusal, or calling the provider after refusal fail protected cases.

The rollback unit is runtime validation, the `prompt_admitted_v2` record,
promotion and recovery, context staging, Store limit/size introspection,
reference composition/command defaults, operator and compatibility
documentation, and tests. The prior reducer refuses the new prompt record kind;
rollback therefore makes new development histories unavailable rather than
replaying them under a dropped budget. No Store object migration is required on
the unreleased surface.
