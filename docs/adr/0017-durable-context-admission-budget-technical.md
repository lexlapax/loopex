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

The split is observable in the reference stack. In the named reference fixture,
the exact provider-facing system message plus four model-facing tool projections
is 2,393 canonical bytes and 799 estimated tokens. The full retained tool
definitions occupy 4,382 staged-record storage bytes and measure 1,462 tokens
under the same estimator, but those full definitions are not provider-token
accounting. A 65,536-byte project file produces a 65,653-byte canonical wrapped
project message and 21,885 estimated tokens. Request and receipt records are
measured separately from those exact components; this ADR makes no unsupported
combined approximate-byte claim.

<a id="technical-adr-0017-decision"></a>
## Exact Two-Dimensional Admission

Concept: [Decision](0017-durable-context-admission-budget.md#concept-adr-0017-decision).

Run admission state adds:

```text
context_token_budget positive_uint64
```

The value enters core only as the required top-level Runtime option
`:context_token_budget`. It is deliberately outside `:bounds`; no call to
`Bounds.declare/1` sees it. `Loopex.Composition` accepts the same top-level
option and inserts `8_192` when absent, and the reference CLI maps
`--context-token-budget` to that composition option. A direct Runtime caller
must supply it. Omission defaults only at Composition and therefore at the
reference CLI; direct Runtime omission and an explicitly supplied non-integer,
non-positive, or above-uint64 value at either boundary use
`:invalid_context_token_budget` before starting Runtime Control, creating a
session, or touching Store.

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
  "max_turns" => positive_integer,
  "token_budget" => positive_integer,
  "deadline_ms" => positive_integer,
  "context_token_budget" => positive_uint64
}
```

Its exact key set is the eleven keys shown; missing or unknown members refuse
replay. The three existing bounds retain their unbounded positive-integer
domain; only the new context admission value is unsigned 64-bit so it is always
compactly persistable. The prompt command digest remains ADR 0011's digest of
the normalized operator input only: type, command identity, and content. The
four resolved configuration values live in the admitted record and are covered
by its Store transaction, but are not command identity. Other accepted
and refused command kinds retain their existing exact shapes except for the
neutral over-size refusal below. The new reducer rejects a legacy accepted
prompt admission using `command_admitted`, and the prior reducer rejects both
`prompt_admitted_v2` and `command_admission_refused_v1`. A queued follow-up
remains exactly `{type, command_id, content}` under ADR 0011. Promotion inherits all four values
from the active run's committed configuration under ADR 0013; it does not read a
new command option or duplicate bounds into the queued record. Recovery requires
the committed member. Old development records without it and prior runtimes
that do not recognize the new prompt record kind both fail unavailable.

ADR 0016's prepared owner-status projection adds exactly
`active_context_token_budget: positive_uint64 | nil`. It is non-null exactly
while an admitted or started active run exists and equals that run's committed
value; a settled session reports nil. This is read-only recovered truth, not a
new Runtime default or session-genesis member. Ordinary immediate
`Loopex.resume_session/3` keeps its existing embedded contract and performs no
configuration comparison. The reference `resume` and `cancel` paths compare an
explicit `--context-token-budget` only after ADR 0016's explicit cleanup-period
comparison has matched, only when status carries a non-null active value, and
before prepared-handler installation, activation, or abort admission. Omission accepts the non-null retained value without resolving
Composition's 8,192 default. An unequal explicit value calls
`abandon_resume/1`; confirmed abandonment returns
`{:error, :context_token_budget_configuration_conflict}`, and unconfirmed
abandonment returns
`{:error, {:context_token_budget_configuration_conflict_owner_unconfirmed,
abandon_reason}}`. If both explicit options mismatch, ADR 0016's cleanup
configuration conflict wins first. No mismatch schedules work, admits an abort,
or substitutes current process configuration. When status is nil, omitted and
explicit values cause no comparison or abandonment; the explicit value or
reference default remains only the process default for a later newly admitted
prompt.

Preserving the existing three positive-integer bound domains requires one more
admission check. Before accepting any command that creates a run identity, Core
constructs and measures the exact normalized private `bound_reached` terminal
and exact normalized unstamped public `run.finished` payload for every bound
that run can reach. The payload is the exact caller-supplied value Store itself
validates before adding `event_sequence`; Store-owned stamps are not part of the
caller ceiling. The conservative candidate values are fixed:

- `max_turns`: declared limit and observed value are the exact committed
  `max_turns`;
- `token_budget`: each complete provider usage member is a non-negative unsigned
  64-bit integer, so observed reserves `token_budget - 1 +
  2 * (2^64 - 1)`, the largest one-turn input-plus-output overshoot after a call
  admitted with one token remaining;
- `deadline_ms`: `declared_limit` and `observed` both reserve the maximum
  supported non-negative unsigned 64-bit absolute clock instant at command
  admission. At first staging, `declared_limit` is the exact chosen absolute
  deadline and `observed` is the exact clock observation; the committed duration
  is not a terminal sibling.

For each bound and each private/public plane, Core constructs every legal
`accounting_source` variant—exactly `nil`, `"reported"`, and `"estimated"`—and
uses the largest normalized encoded candidate as that plane's observation.
Ties resolve in that written order. It does not assume the admission-time source
or a shorter reported spelling, because a later provider result can lawfully
change the terminal's source without changing the run identity or bound. The
selected refusal still names the bound and plane; its `observed` is the maximum
variant's exact byte count.

Both private and public candidates must fit at 65,536 bytes. They are measured
in bound order `max_turns`, `token_budget`, `deadline_ms`, private before public;
the first overage selects `future_bound_record_bytes`. This preflight narrows no
bound's in-memory integer domain: it rejects only a value whose deterministic
future durable truth cannot fit. Prompt uses its exact run identity; follow-up
uses its already derivable promoted run identity; steer creates no run and adds
no future-bound candidate.

At first staging, `system_time_ms()` must be a non-negative unsigned 64-bit
integer and checked addition of the committed positive `deadline_ms` must yield
an absolute deadline no greater than `2^64 - 1`; arithmetic never wraps. Core
then constructs and measures the exact private and unstamped-public future
deadline terminal candidates again with that chosen instant before it proposes
`model_request_committed`. Clock-domain or checked-addition failure commits no
model attempt or stream domain. Instead one ordinary ADR 0006 session-journal
transaction contains exactly:

```text
%{kind: "deadline_staging_failed_v1", "run_id" => run_id,
  "turn_id" => turn_id,
  "category" => "clock_out_of_domain" |
    "deadline_addition_overflow"}
run_terminal_committed(failed("deadline_preflight_failed", false))
```

The compact first row never retains the invalid or giant value and is itself
proved representable. Rowwise recovery uses
`deadline_staging_pending_terminal`: no provider call, attempt/domain,
accounting, queue, outbox, or public terminal effect applies until the exact
consecutive pair is complete. Head, intervening, duplicate, or mismatched rows
are invalid history; commit-unknown re-presents the same ordered bytes. The
admission-time maximum-instant reservation proves that a legal exact instant
cannot make either exact terminal candidate exceed the already admitted maximum.
The staging-time size check remains a defense-in-depth assertion over the actual
transaction; if it disagrees with admission, Core reports the Store/session
unavailable and fabricates no operator failure category or terminal. A valid
history cannot select a private/public size failure at this stage.

Every content-bearing command admission is replay-first. Prompt follows this
order:

1. normalize the operator command and compute its unchanged command digest;
2. consult the recovered command binding; equal digest replays its retained
   answer and unequal digest returns `idempotency_conflict`, without resolving a
   current process default;
3. for an unbound command, inspect recovered session state. If a run is active,
   commit ADR 0011's ordinary compact `rejected_run_active` answer without
   resolving any run value;
4. only for an unbound command in a settled session, resolve and validate the
   four run values;
5. construct and exactly measure the complete `prompt_admitted_v2` candidate,
   prove that record's fit implies the exact normalized unstamped
   `user.message_appended` payload fits, and measure the six future-bound
   candidates above before proposing its Store transaction.

Steer and follow-up first apply ADR 0011's active-run, matching-run, and queue
preconditions. Only a command that would otherwise be accepted is measured.
Steer measures its exact accepted command record; its content can enter a later
staged request only through the separate context preflight below. Follow-up
measures both its exact accepted command record and the exact unstamped
`user.message_appended` event that deterministic promotion will emit, using the
already derivable successor run and event identities, then its six future-bound
candidates. Here and above, "unstamped" means the exact normalized payload Store
validates immediately before adding its own `event_sequence`. Accepted-record
measurement precedes event measurement for every command. One below and exactly
at 65,536 bytes fit; the first candidate one above commits exactly:

```text
%{
  kind: "command_admission_refused_v1",
  "command_id" => nonempty_bounded_binary,
  "command_digest" => lowercase_sha256_hex,
  "command_type" => "prompt" | "steer" | "follow_up",
  "admission" => "rejected_durable_candidate_bytes",
  "dimension" =>
    "command_record_bytes" | "command_event_bytes" |
    "future_bound_record_bytes",
  "candidate" =>
    "prompt_record" | "steer_record" | "follow_up_record" |
    "follow_up_user_message_event" |
    "max_turns_private_terminal" | "max_turns_public_finish" |
    "token_budget_private_terminal" | "token_budget_public_finish" |
    "deadline_private_terminal" | "deadline_public_finish",
  "observed" => nonnegative_integer,
  "limit" => 65_536
}
```

The refusal's exact nine-key shape contains no command body or resolved giant
integer. `observed` is the selected measured candidate size, must be a positive
integer, and must be greater than its fixed limit; an at-or-below-limit retained
refusal is invalid history. `candidate` names the exact bound and private/public
plane when `dimension` is `future_bound_record_bytes`, the promoted event when
it is `command_event_bytes`, and the exact command kind when it is
`command_record_bytes`; every other dimension/candidate pair is invalid. The
compact refusal itself is normalized and proved
to fit before it is proposed. `command_event_bytes` is valid only for the
promoted follow-up event; prompt's smaller immediate event is an implication
check, not a selectable refusal, and steer has no deterministic command event.
It returns
`{:error, {:command_admission_too_large, dimension, candidate, observed,
65_536}}`; replay
derives that same answer from the retained record before reading new defaults or
current run state. It installs no run, steer, or follow-up and emits no public
event. A run-active prompt keeps ADR 0011's ordinary compact
`rejected_run_active` record and never resolves configuration it cannot use.
The refusal starts no run, model task, executor job, effect, or queue work and
emits no public event; the already-running session owner performs the admission
decision.

An accepted prompt transaction emits `user.message_appended` and zero
`run.started` events. Completion of its first staged request plus ADR 0018's
attempt-open transaction emits exactly one `run.started` with the staged bytes
and model intent; a pending staging transaction, replay, and later turns emit
none. An oversized command refusal emits no public event. The
public-history reducer therefore distinguishes an active
`admitted_unstaged(run_id)` from `started(run_id)`: the accepted prompt or a
promoted follow-up's user-message event installs the first state, a matching
start advances it, and `run.finished` may close either state for any valid
terminal category, including abort or owner loss before staging and a context
refusal at staging. A start for another run, a second start, or a finish with no
matching admitted/started run is invalid.

Every new public attachment snapshot uses the exact revision-2 shape:

```text
%{
  snapshot_revision: 2,
  session_id: nonempty_bounded_binary,
  event_sequence: nonnegative_integer,
  active_run_id: nonempty_bounded_binary | nil,
  active_run_phase: "admitted_unstaged" | "started" | nil
}
```

The two active members are nil together or non-nil together. A user-message
event from no active run installs `admitted_unstaged` for that event's run; a
later steer message for the same admitted or started run leaves the phase
unchanged, and a user message naming another run is invalid. A matching first
start advances to `started`, and a matching finish clears both. Snapshot scan state,
an anchored projection, replay, and attachment recovery retain the phase rather
than inventing a start. The prior unreleased three-member snapshot shape is no
longer emitted, and no phase is inferred from `active_run_id` alone.

The fixed record ceiling is read from core's Store contract rather than
duplicated as a caller option:

```text
Store.max_item_bytes() -> 65_536
Store.max_item_depth() -> 12
Store.max_item_cardinality() -> 1_024
Store.normalize_and_measure_item(:record | :event, item) ->
  {:ok, normalized_item, encoded_bytes}
  | {:error, {:item_structure_exceeded, :depth | :cardinality,
              observed, limit}}
  | {:error, reason}
```

These are core functions, not adapter callbacks, and an adapter cannot override
their results. `normalize_and_measure_item/2` and `Store.transact/2` call one
shared normalizer/validator/sizer; there is no later `plain?/2` pass with
different semantics. Root depth is zero, every child increments depth by one,
and every node including a scalar must have depth at most 12. Map cardinality is
the complete normalized map size, including required root `kind` and `event_id`
members after they are restored; list cardinality is its length. Each collection
may contain at most 1,024 members.

Traversal is deterministic depth-first pre-order. Each node first classifies
its form without a whole-list predicate: a scalar admitted by bounded plain
data, `[]`, a cons cell, or a plain map may continue, while a struct or any
other non-plain term returns the ordinary invalid-data result regardless of its
depth. An admitted-form node then checks depth. Before allocating normalized
keys or visiting child values, maps use constant-time `map_size/1`; a list
counter pattern-matches no more than 1,025 successive cons cells and never calls
`is_list/1` or `length/1` on the untrusted tail. A tail reached within 1,024
cells must be exactly `[]`, otherwise the value is ordinary invalid data. A
1,025th cons cell returns cardinality immediately even if a later tail would be
improper. A raw collection above 1,024 therefore returns cardinality with
observed `1_025`. At a cardinality-admitted map, root required-field extraction and all
remaining key normalization and collision checks form the next phase; any
invalid key, required atom/binary duplicate, or post-normalization collision
returns the ordinary invalid-data result. In `:event`
mode, the atom or binary spellings of `event_sequence`, `owner_epoch`, and
`owner_incarnation_id` are additionally reserved at every root or nested map;
encountering one returns the ordinary invalid-event result in this
post-cardinality key phase. Root raw cardinality includes required `kind` and,
for events, `event_id` before extraction; restoring those same members cannot
increase the admitted map's cardinality, so there is no second or synthetic
post-normalization overage. Child values
are visited in unsigned bytewise lexicographic
order of their normalized binary key spellings; the restored atom keys use the
logical spellings `"kind"` and `"event_id"` for this ordering. Lists visit
values in list order only after their bounded count passes. Thus depth precedes
cardinality, raw cardinality protects map-key normalization and list traversal,
and collection cardinality precedes key validity and visiting any child. A structural refusal is the first exact tuple
`{:item_structure_exceeded, dimension, observed, limit}` under that order, where
depth's observed value is the rejected node depth and cardinality's is the
first rejected witness `1_025`, not a complete oversized collection count.
Invalid keys, key-normalization collisions,
structs, and other non-plain data retain their ordinary invalid-data result and
are not relabelled structural overages.

Two transaction protections remain deliberately outside this item helper.
Outbox event IDs must still be unique across the complete transaction, and the
transaction validator still rejects the current owner-incarnation capability
wherever it occurs as a key, value, substring, or nested public-event member.
The helper has neither the sibling events nor the transaction's expected owner
identity, so it cannot discharge either check. A public event containing that
capability may normalize and measure successfully in isolation and must still
be refused by `Store.transact/2`; the shared-normalizer rule does not replace or
weaken that transaction-bound security scan.

A structurally valid item is measured with a deterministic external-term size
calculator without first allocating the encoded byte string. It returns the
exact count even above `max_item_bytes/0`; only an item at or below the ceiling
is later encoded for commit. The caller and `Store.transact/2` compare that same
count with the same ceiling. Staging uses the returned normalized item as the
exact transaction member; no approximate string sum, second normalization, or
normalize-after-preflight path defines the budget.

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

Estimated context-member cost is:

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
request and are covered by exact record bytes. Source references and trust
labels are storage facts; they are never silently charged as provider content.
For a message descriptor, `content_digest`, `byte_cost`, and `token_cost` use
`Canonical.encode(final_message)`. For a tool descriptor those three members use
`Canonical.encode(ToolDefinition.model_facing(definition))`; its
structured `source_reference` still carries the complete definition digest,
tool ID, version, and therefore the whole generation identity. Thus `totals` measures exactly the provider-
visible preimage while the full definition remains independently bound and
charged by record sizing.

The exact `blocks` order is every message descriptor in the final canonical
request's `messages` order followed by every tool descriptor in that request's
`tools` order. Active tools retain the same deterministic order in the staged
request, descriptor list, totals walk, and adapter input; neither provenance nor
trust class regroups either half. `totals.byte_cost` is the sum of every block's
`byte_cost`; `totals.token_cost` is the sum of every block's `token_cost` and
equals `provider_estimated_tokens`. Each exact `by_provenance` bucket is the
filtered pair of those same sums and is zero exactly when that class has no
block; the three buckets sum back to both outer totals.

`source_reference` is structured canonical data, not a delimiter-concatenated
string. It is exactly one of these key sets and no other:

```text
%{"kind" => "system", "identity" => "loopex.system.v1"}

%{"kind" => "session_command", "run_id" => run_id,
  "command_id" => command_id}

%{"kind" => "session_assistant", "run_id" => run_id,
  "turn" => positive_integer}

%{"kind" => "session_tool_result", "run_id" => run_id,
  "turn" => positive_integer, "call_id" => call_id}

%{"kind" => "session_steer", "run_id" => run_id,
  "command_id" => command_id}

%{"kind" => "project_resource", "workspace_ref" => workspace_ref,
  "manifest_digest" => lowercase_sha256_hex,
  "relative_label" => validated_relative_label}

%{"kind" => "tool_definition", "tool_id" => tool_id,
  "tool_version" => tool_version,
  "definition_digest" => lowercase_sha256_hex}
```

Every identifier reuses the bound of the durable source record that supplied it;
no formatter reparses one string to recover members. The tool form is exactly
the generation triple, and the project form is exactly the manifest entry
identity used by its trust decision. Canonical encoding of these maps under
`loopex.canonical.v1` is the only source-reference preimage. Unknown/missing
keys, wrong variants, a scalar legacy reference, and delimiter-shaped aliases
fail replay rather than being normalized into a v2 descriptor.

Every ordered context descriptor retains ADR 0010's exact six members:

```text
%{
  "source_reference" => source_reference_v2,
  "provenance_class" =>
    "system" | "session" | "project_resource",
  "trust_class" =>
    "host_owned_trusted_brain_content" |
    "session_owned_durable_truth" |
    "untrusted_behavior_shaping_data",
  "content_digest" => lowercase_sha256_hex,
  "byte_cost" => nonnegative_uint64,
  "token_cost" => nonnegative_uint64
}
```

The successful `model_request_committed` record keeps `context_receipt` at its
existing record-root location and changes that value to this exact sixteen-key
shape:

```text
%{
  "provider_identity" => "loopex.context.reference",
  "provider_revision" => 2,
  "transformer_identity" => nil,
  "transformer_revision" => nil,
  "selector_identity" => nil,
  "selector_revision" => nil,
  "token_estimator" => "loopex.context_bytes.v1",
  "descriptor_canonicalization_version" => "loopex.canonical.v1",
  "blocks" => [ordered_context_descriptor],
  "totals" => %{
    "byte_cost" => nonnegative_uint64,
    "token_cost" => nonnegative_uint64,
    "by_provenance" => %{
      "system" => %{"byte_cost" => nonnegative_uint64,
                    "token_cost" => nonnegative_uint64},
      "session" => %{"byte_cost" => nonnegative_uint64,
                     "token_cost" => nonnegative_uint64},
      "project_resource" => %{"byte_cost" => nonnegative_uint64,
                              "token_cost" => nonnegative_uint64}
    }
  },
  "project_resource" => exact_project_resource_receipt,
  "context_token_budget" => positive_uint64,
  "provider_estimated_tokens" => nonnegative_uint64,
  "context_record_byte_ceiling" => 65_536,
  "record_byte_cost" => positive_uint64,
  "ordered_descriptor_digest" => lowercase_sha256_hex
}
```

The two absent-stage identity pairs are exact: both members of each pair are
`nil` together. M2 has no transformer or selector stage, so `nil` is more
truthful than inventing a no-op implementation. A later real stage replaces its
pair with a bounded identity and positive revision only through a separately
accepted decision. Provider identity/revision remain the exact supported
reference values above. These six identity members satisfy the vision and ADR
0010 pipeline-identity requirement without claiming unshipped machinery.

`exact_project_resource_receipt` is not an open map. Its outer shape is exactly:

```text
%{
  "class" => "project_resource",
  "receipt_revision" => 2,
  "disposition" => project_disposition,
  "detail" => exact_detail_for(project_disposition)
}
```

The eight dispositions and their exact detail shapes are:

| Disposition | Exact `detail` |
| --- | --- |
| `staged` | `%{"manifest_digest" => sha256, "decision_source" => "interactive_operator" | "host_supplied", "workspace_ref" => bounded_binary, "entries" => entries}` where `entries` is exactly length zero or one and its one admitted member is `%{"relative_label" => "AGENTS.md", "content_digest" => sha256, "byte_size" => nonnegative_uint64}` |
| `no_manifest` | `%{}` |
| `manifest_rejected` | `%{"reason" => "invalid_manifest" | "invalid_workspace" | "too_many_entries" | "entry_not_bounded_plain_data" | "unpermitted_label" | "entry_not_reported_contained" | "declared_size_mismatch" | "declared_digest_mismatch", "label" => bounded_binary | nil}` |
| `over_limit` | `%{"dimension" => "project_resource_bytes", "observed" => nonnegative_uint64, "limit" => 65_536, "label" => bounded_nonempty_binary}` |
| `no_decision` | `%{"manifest_digest" => sha256}` |
| `binding_changed` | `%{"reason" => "digest_mismatch" | "workspace_mismatch" | "invalid_decision", "expected_manifest_digest" => sha256, "decision_manifest_digest" => sha256 | nil}` |
| `context_token_budget` | `%{"dimension" => "context_tokens", "observed" => nonnegative_uint64, "limit" => positive_uint64}` |
| `context_record_bytes` | `%{"dimension" => "context_record_bytes", "observed" => nonnegative_uint64, "limit" => 65_536}` |

Every listed map admits no missing or unknown key. The byte observation for
`context_record_bytes` is the fixed-point optional-present candidate before the
whole class is removed; the replacement candidate is recomputed to its own
fixed point. The token observation is the optional-inclusive provider total.
M2 defines no optional-project depth or cardinality disposition because its one
flat binary block cannot independently produce either before the byte ceiling.

Each disposition also has exact semantic relations:

- `staged` with zero entries has zero project descriptors, messages, and
  provenance cost. With one entry it has exactly one project descriptor and one
  project message; its source reference carries the same workspace, manifest
  digest, and `AGENTS.md` label, and all outer request/totals relations match.
- `no_manifest` has empty detail and zero project descriptor/cost.
- `manifest_rejected` uses `label: nil` for `invalid_manifest`,
  `invalid_workspace`, `too_many_entries`, and
  `entry_not_bounded_plain_data`; every label-specific failure carries the exact
  bounded non-nil label. It has zero project descriptor/cost.
- `over_limit` has the sole dimension `project_resource_bytes`, a bounded
  non-nil label, `observed > 65_536`, and zero project descriptor/cost.
- `no_decision` carries a valid manifest digest and zero project descriptor/cost.
- `binding_changed/digest_mismatch` carries two valid unequal digests;
  `workspace_mismatch` carries two valid equal digests; and
  `invalid_decision` carries either `nil` or an independently valid decision
  digest. All have zero project descriptor/cost.
- `context_token_budget` has `limit == context_token_budget`, optional-inclusive
  `observed > limit`, an admitted replacement total at or below the limit, and
  zero retained project contribution.
- `context_record_bytes` has `observed > 65_536`, final replacement
  `record_byte_cost <= 65_536`, and zero retained project contribution.

Every successful receipt also requires system subtotal `< 1_000`, outer
provider total `<= context_token_budget`, and final `record_byte_cost <= 65_536`.
Manifest containment, raw declared size, decision validity, and other live
preimages not retained in the request remain Store-integrity-protected
construction facts; replay validates the retained exact shapes and derivable
relations without pretending to reconstruct omitted input.

Project resolution is one deterministic first-match table, not a set of
independent predicates:

1. no supplied manifest yields `no_manifest`;
2. manifest validation runs before limits. Every outer manifest, workspace,
   entry, and decision exact-key check first uses `map_size/1` and fixed
   `Map.fetch/2` operations. It never enumerates or sorts keys or allocates a key
   list before rejecting an enormous map. The outer manifest shell and exact
   top-level member set are checked first; failure yields `manifest_rejected`
   with `invalid_manifest` and `label: nil` without inspecting workspace or
   entries. The raw `entries` member is then classified without `is_list/1` or
   `length/1`: only `[]` and a one-cons list ending in `[]` are admitted; an
   improper tail yields `invalid_manifest`, while observing a second cons yields
   `too_many_entries` with `label: nil` immediately and never visits that entry
   or any later tail. This is the exact allocation-safe M2 zero-or-one resource
   boundary. Only after it passes is the workspace map's exact shape and bounded
   members checked; failure yields `invalid_workspace` and `label: nil`. The
   optional one entry must then have the exact entry shell and a bounded binary
   label; failure yields `entry_not_bounded_plain_data` and `label: nil`.
   The admitted zero-or-one entries are then in canonical label order and test permitted label,
   containment, and declared size in that order, retaining the actual bounded
   label for each failure;
3. limits use O(1) body byte sizes and saturating addition before hashing any
   content. They test the canonical one entry against its per-resource bound.
   `over_limit` uses `project_resource_bytes` and that entry's label. The equal
   one-entry class-total calculation is retained as a future-shape invariant but
   is not an independently selectable M2 disposition. Only after the limit passes does declared-digest verification
   hash each bounded entry in canonical order; the first mismatch retains its
   label;
4. an absent decision yields `no_decision` with the exact manifest digest;
5. decision exact-key/type/source/scope/issued-at validation, ADR 0010's required
   `revocation_state: active`, and its required `expires_at: nil` run before
   binding. Failure yields `binding_changed/invalid_decision`, carrying the
   decision digest only when it is independently a valid SHA-256 value;
6. manifest-digest mismatch precedes workspace mismatch and yields
   `digest_mismatch`; an equal digest with a different workspace yields
   `workspace_mismatch`. Both carry the expected digest and the valid decision
   digest;
7. a matching decision yields `staged`. A valid empty manifest
   retains `entries: []`, stages zero project descriptors and zero project
   bytes/tokens, and never enters optional budget withholding. A one-entry
   manifest retains the one exact entry and produces the one optional block.

When more than one condition is false, this order alone chooses the receipt.
Commit-unknown re-presents that exact transaction; after recovery, transaction
resolution precedes any fresh candidate. ADR 0017 adds no clock interpretation,
revocation state, or expiry state to ADR 0010's M2 trust-decision domain.

The provenance totals always carry all three exact keys, using zero costs for an
absent class, and `provider_estimated_tokens` equals the outer token total. The
project receipt replaces ADR 0010's open detail with the versioned exact shape
above and adds only the two reachable whole-class budget dispositions
`context_token_budget` and `context_record_bytes`.

Receipt validation is record-relative, never receipt-only. At live construction
and replay, Core passes the entire adjacent `model_request_committed` record and
reconstructs the expected descriptor sequence from the exact final
`request.messages` order, exact `request.tools` order using
`ToolDefinition.model_facing/1`, reducer-derived session/steer source identities,
fixed system identity, full-definition tool source bindings, and the exact
zero-or-one project contribution selected by the project disposition. The
retained `blocks` list must equal that expected list member-for-member and
byte-for-byte. Core then recomputes every content digest, byte/token cost,
provenance bucket, outer total, provider-estimator total, record-cost fixed point,
and ordered descriptor digest. An internally consistent receipt describing a
different message set, projection, order, source binding, or project contribution
is invalid history even if its own arithmetic balances.

`ordered_descriptor_digest` uses an incremental SHA-256 preimage. It starts with
the exact ASCII domain `loopex.context.descriptors.v1` followed by one zero byte;
then, for each ordered descriptor, appends its eight-byte unsigned big-endian
canonical-byte length and
`LoopexProtocol.Canonical.encode(descriptor)` under the carried
`loopex.canonical.v1` version. Incremental hashing allocates no aggregate encoded
descriptor list. An unknown canonicalization version is unavailable rather than
decoded using the current encoder by assumption.

This estimator-owned ceiling is deterministic before dispatch. It does not
claim to reproduce any provider tokenizer or prove that a chosen model accepts
the request; provider capability remains a host/provider concern. The runtime
does claim that every exact final provider-visible message and model-facing tool
projection was measured under the named repository estimator and their sum did
not exceed the committed admission policy. Model identity, sampling, deadline,
continuation, enclosing request structure, provider envelope, and provider
translation are outside that preimage and are not described as charged bytes.

Evaluation is ordered:

1. resolve project trust and intake into either one exact pre-budget decline
   receipt or an eligible optional class of zero or one block, without adding it
   yet;
2. build the exact required-only provider messages, active tool projections, and
   ordered descriptors; the required compact counts and descriptor digest are
   fixed here;
3. measure required provider tokens, verify descriptor source/content digests,
   enforce the 1,000-token `system` class ceiling, and then enforce
   `context_token_budget` over the required total;
4. if either required token check fails, atomically retain the compact refusal,
   `failed(context_budget_exceeded, false)`, and public terminal, dispatching
   nothing; an otherwise eligible project is recorded as
   `not_evaluated_required_failure`, while an already declined project keeps its
   exact non-budget disposition;
5. prove required-only record admissibility before optional evaluation. Apply
   the shared structural walk to a non-durable candidate shell using a
   structurally maximal instance of the exact project-receipt schema. Separately
   resolve and measure a required-only lower-bound candidate whose project
   member is the smallest exact receipt shape and whose descriptor list is the
   required list fixed at step 2. A structural failure or an above-ceiling
   lower bound follows the same compact-refusal transaction before optional
   evaluation. An eligible project uses `not_evaluated_required_failure`; a
   project already declined at step 1 preserves that exact disposition. The lower-bound
   candidate is never retained; on an above-ceiling refusal its fixed-point
   size is the compact receipt's `observed` and `record_byte_cost`, explicitly a
   required-only lower-bound cost rather than a fabricated final admitted
   record cost. It proves that any required descriptor cardinality capable of
   being pushed over the Store limit by one optional descriptor already exceeds
   the byte ceiling. Generated evidence binds that implication at every list
   cardinality through 1,024;
6. if project is eligible, add its zero or one canonical block, evaluate and retain the
   derived class guard, and withhold it with `context_token_budget` when the
   optional-inclusive provider total alone exceeds the committed total;
7. construct the exact successful `model_request_committed` candidate with full
   tool definitions and receipt; resolve `record_byte_cost` by the fixed-point
   procedure and measure it through Store's shared function;
8. if an optional-present candidate exceeds record bytes, withhold the whole
   class with the exact `context_record_bytes` detail, rebuild, and recompute the
   fixed point; if the replacement or an already required-only candidate still
   exceeds bytes, depth, or cardinality, commit the compact refusal instead.
   The required-only structural and byte proofs plus the M2 flat-shape
   invariant mean optional content cannot be the sole cause of a structural
   refusal; and
9. commit the admitted receipt and staged request atomically before dispatch.

The compact refusal receipt is exactly:

```text
%{
  kind: "context_admission_refused_v1",
  "run_id" => nonempty_bounded_binary,
  "turn_id" => nonempty_bounded_binary,
  "category" => "context_budget_exceeded",
  "dimension" =>
    "system_class_tokens" | "context_tokens" | "context_record_bytes" |
      "context_record_depth" | "context_record_cardinality",
  "token_estimator" => "loopex.context_bytes.v1",
  "descriptor_canonicalization_version" => "loopex.canonical.v1",
  "project_disposition" =>
      "not_evaluated_required_failure" | "no_manifest" |
      "manifest_rejected" | "over_limit" | "no_decision" |
      "binding_changed" |
      "staged_empty" | "context_token_budget" | "context_record_bytes",
  "system_message_count" => nonnegative_uint64,
  "session_message_count" => nonnegative_uint64,
  "steer_message_count" => nonnegative_uint64,
  "tool_definition_count" => nonnegative_uint64,
  "provider_estimated_tokens" => nonnegative_uint64,
  "context_token_budget" => positive_uint64,
  "record_byte_cost" => nonnegative_uint64 | nil,
  "context_record_byte_ceiling" => 65_536,
  "ordered_descriptor_digest" => lowercase_sha256_hex,
  "observed" => nonnegative_uint64,
  "limit" => positive_uint64
}
```

Its exact nineteen-key outer shape admits no unknown member. The estimator,
canonicalization version, and descriptor-digest preimage are the same fixed
values as the successful receipt. `observed` and `limit` name the selected
dimension. `record_byte_cost` is `nil` when token or structural refusal precedes
record construction. For a step-5 record-byte refusal it is the exact normalized
fixed-point cost of the required-only lower-bound candidate; for a later
record-byte refusal it is the exact fixed candidate cost. In either case it
equals `observed` and never claims a candidate was admitted.
All four counts and the digest describe the same required-only ordered
descriptor set fixed at step 2. `system_message_count` counts provider messages
whose source provenance is `system` and excludes tools;
`session_message_count` counts durable lineage messages and excludes the
separately counted steer messages; `steer_message_count` is the number of steer
messages; and `tool_definition_count` is the number of final model-facing tool
projections. Their sum equals the required-only descriptor count. The four
counts partition the exact sequence whose bytes determine
`provider_estimated_tokens` and `ordered_descriptor_digest`; incrementing or
reclassifying one count without changing that sequence is rejected by the live
constructor and its property evidence. After commit, those compact values are
durable observations protected by the Store transaction digest; recovery has no
descriptor bodies from which to recompute them and does not pretend otherwise.
An eligible
project not evaluated because required content already
failed uses `not_evaluated_required_failure`; no field suggests it was staged.
If a matching empty manifest was evaluated successfully but the final
required-only record later fails its byte preflight, the compact receipt uses
`staged_empty`; it never relabels that truthful zero-block decision as absent,
declined, or withheld.
If the optional class was evaluated and withheld before a later required-only
record failure, the compact receipt preserves `context_token_budget` or
`context_record_bytes` rather than relabelling that earlier decision.
The receipt contains neither the descriptor list nor descriptor content or
source references, so its size is independent of history length. Its own exact
encoded bytes must validate before the atomic receipt-and-terminal transaction
can be proposed; inability to retain even that transaction is Store
unavailability, never a fabricated context verdict or a stranded failed run.

The private terminal and public `run.finished` event for this refusal each add
the same exact bounded projection:

```text
"failure" => %{
  "category" => "context_budget_exceeded",
  "retryable" => false,
  "dimension" =>
    "system_class_tokens" | "context_tokens" | "context_record_bytes" |
      "context_record_depth" | "context_record_cardinality",
  "observed" => nonnegative_uint64,
  "limit" => positive_uint64
}
```

The corresponding private terminal is the exact eleven-key record:

```text
%{
  kind: "run_terminal_committed",
  "run_id" => same_run_id,
  "outcome" => "failed",
  "bound" => nil,
  "observed" => nil,
  "declared_limit" => nil,
  "accounting_source" => nil,
  "reconciliation_ref" => nil,
  "cleanup_grace_ms" => committed_positive_integer,
  "command_id" => nil,
  "failure" => exact_five_key_failure
}
```

The corresponding `run.finished` event keeps its existing exact root members,
sets `outcome` to `"failed"`, reconciliation and command to `nil`, carries the
same cleanup grace, and adds only that same five-key `failure` map. The legacy
bound/accounting siblings stay absent from the event and nil in the private
terminal; no root-level observation or limit may contradict the nested failure.
Unknown or missing root or nested members refuse the pair.

For `system_class_tokens`, `observed` and `limit` are the required system
provenance subtotal and 1,000. For `context_tokens`, they are the receipt's
`provider_estimated_tokens` and `context_token_budget`; for
`context_record_bytes`, they are `record_byte_cost` and 65,536; for either
structural dimension they are the Store preflight's exact observed depth or
collection cardinality and its Store-owned limit. This exact five-key map is
exclusive to `outcome: "failed"` with category
`"context_budget_exceeded"`. Non-failed variants carry no `failure` member;
other failed categories retain their accepted exact failure projection rather
than being erased or widened by this decision. The CLI renders these five safe
context fields and no private descriptor or source identity.

A context-admission terminal is not admitted through the generic terminal
transition. Its one Store transaction has exactly the private record pair
`[context_admission_refused_v1, run_terminal_committed]`; applying the terminal
record performs steer resolution and queued-follow-up promotion or session
settlement in reducer state, without restoring ADR 0011's superseded private
promotion or steer-resolution records.

Applying the first row, live or during recovery, installs only the transient
in-memory marker
`%{kind: :context_refusal_pending_terminal, first_version: version, refusal: normalized_record}`.
It changes no durable-derived run state, emits no event, resolves no queue, and
dispatches no work. The immediately next journal version must be the exact
matching `run_terminal_committed`; on that row the reducer consumes the marker
and applies both records as one semantic unit. A pagination boundary after the
first row is valid and carries the marker into the next fetch. Reaching the
durable head with the marker still pending, or observing any intervening,
duplicated, non-consecutive, or mismatched row, is invalid incomplete history
and leaves the session unavailable. The live Store result and commit-unknown
recovery use this same reducer path rather than a special whole-list shortcut.

The public outbox keeps the accepted terminal ordering. With a queued follow-up
it is exactly `[run.finished, steer.resolved?, user.message_appended]`; any
`steer.resolved` has ADR 0011's unchanged exact reason `"run_terminal"`. Promotion
of the successor identity and inherited configuration is private reducer state.
Without a follow-up it is exactly
`[run.finished, steer.resolved?, session.settled]`. Neither branch emits
`run.started`; completion of the successor's first staged request plus ADR
0018's attempt-open transaction emits that event once with the staged bytes and
model intent, including after a crash between promotion and staging.

The terminal outcome is `failed`; its private failure map and the one
`run.finished` event
copy the refusal record's four shared fields `category`, `dimension`,
`observed`, and `limit`, and add the fixed fifth member `retryable: false`.
Before installing the transient marker, the reducer requires the record's
`run_id` to be the active run, its `turn_id` to equal
`stable_id("turn", run_id, next_turn_number(work))`, its context budget to equal
the run's committed value, its estimator and canonicalization identities to be
the exact supported versions, and each dimension to satisfy only its derivable
compact relation:

- `context_tokens` requires `observed == provider_estimated_tokens`,
  `limit == context_token_budget`, and `observed > limit`;
- `context_record_bytes` requires `observed == record_byte_cost`,
  `limit == 65_536`, and `observed > limit`;
- `context_record_depth` requires `observed == 13` and `limit == 12`, because
  depth advances one node at a time and 13 is the first rejected depth;
- `system_class_tokens` requires `limit == 1_000`, `observed >= limit`, and
  `observed <= provider_estimated_tokens`, but the exact system subtotal is a
  Store-digest-protected live observation; and
- `context_record_cardinality` requires `limit == 1_024` and
  `observed == 1_025`, the first allocation-safe rejected witness.

For token or structural dimensions `record_byte_cost` is nil; only the byte
dimension admits it. The reducer validates the compact counts, digest, token
estimate, project disposition, and selected dimension for exact shape, domain,
enum membership, and the relations above, but treats every value whose preimage
is omitted as a committed observation. The refusal intentionally retains no
descriptor bodies, active tool definitions, or rejected structural candidate
from which recovery could recompute them. The live constructor alone has that
preimage and proves the partition, digest, exact system subtotal, exact rejected
cardinality, token estimate, project resolution, and selected first failure
before it builds the Store transaction. The reducer
admits the pair only at the request-staging boundary
from `model_pending` or `turn_settled`, before any `model_request_committed`,
provider attempt, effect intent, executor job, or other in-flight operation for
that turn exists. A missing, reordered, duplicated, or mismatched pair, or the
same pair presented from `model_dispatched`, `effect_pending`, or any later
stage, is invalid history rather than authority to abandon work. Commit-unknown
re-presents that exact whole transaction.

The exact successful-record cost is not measured against a value that its own
insertion invalidates. Core starts with `record_byte_cost: 0`, calls the
allocation-safe `normalize_and_measure_item/2`, replaces the field with that
external byte count, and repeats without encoding the candidate until the
embedded value equals the next normalized size. The sequence is monotone and,
for any finite candidate, can change only when the deterministic integer
encoding crosses one of finitely many integer widths. Failure to converge or
any normalization change outside that one field returns the exact
Store-unavailable reason `:context_record_preflight_unavailable`; it does not
manufacture a context dimension, terminal, or provider dispatch. A stable value
above the Store ceiling follows the exact compact `context_record_bytes`
refusal path. Structural refusal exits immediately with its exact dimension.
Core then calls `Store.normalize_and_measure_item/2`
once on the fixed record, requires the returned normalized item to equal the
fixed candidate, and requires the returned byte count to equal that candidate's
embedded `record_byte_cost`. Only that at-or-below-ceiling item may be encoded
for transaction construction.

Step 7 is not trimming. Project resources are optional under ADR 0010, and the
request is canonicalized only after the whole class is removed. Session history,
system content, steer input, and active tool definitions are never dropped or
summarized. No pre-dispatch refusal increments cumulative provider usage.

Provider-attempt authority begins only after this admission boundary has
committed the exact staged request and digest. ADR 0018 exclusively owns the
Model callback error forms, reply and usage normalization, attempt-open and
settlement records, the Control dispatch permit, cumulative accounting, retry,
termination races, and crash recovery. This ADR's estimator is never used as
provider billing evidence, and no context refusal increments cumulative
provider usage or creates provider-attempt state.

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

- Runtime omission of `:context_token_budget` and explicit non-integer, zero,
  negative, and above-uint64 values each return
  `:invalid_context_token_budget` before Runtime Control starts, session state
  exists, or Store receives a call. Composition and the reference CLI each
  default omission to exactly `8_192`; an explicit valid override propagates
  unchanged; and `--context-token-budget` maps only to the top-level Composition
  option, never into `:bounds`. Unknown, missing-value, malformed, zero,
  negative, and overflow CLI forms fail before Runtime or Store. Mutants adding
  a Runtime default, defaulting an explicit invalid value, moving the member
  into bounds, starting Control before validation, or dropping the CLI mapping
  fail named cases;
- reference `resume` and `cancel` each cross omitted, explicitly equal, and
  explicitly unequal context budgets against a prepared owner. Omitted and equal
  values recover the exact committed budget even after the Composition default
  changes; unequal values dispatch no work or abort and return the exact
  `context_token_budget_configuration_conflict` result after confirmed abandon,
  or its exact `context_token_budget_configuration_conflict_owner_unconfirmed`
  composite after failed or unproved abandon. A case where cleanup and context
  both differ proves cleanup conflict wins first. Mutants comparing omission
  with 8,192, reading a current Runtime default, comparing before cleanup,
  activating before comparison, admitting cancel before comparison, or
  collapsing the two abandonment results fail by command and branch;
- settled prepared-owner status with nil active context is crossed with both an
  omitted and explicit reference value. Neither abandons or reports conflict;
  the chosen process value becomes only the default for a later newly admitted
  prompt. A mutant comparing an explicit value with nil or treating nil as a
  retained active-run budget fails by command;
- command replay is consulted before current defaults and current run state: an
  equal prompt, steer, or follow-up replay returns its original accepted or
  oversized-record refusal result after defaults or queues change, while changed
  normalized input conflicts; an active run's compact prompt rejection resolves
  no unused configuration;
- the exact `prompt_admitted_v2` and `command_admission_refused_v1` key sets are
  accepted at their boundaries, missing or unknown members fail closed, and a
  gigantic otherwise-valid existing bound is measured without allocating its
  full encoded candidate, retains the compact nine-key refusal, starts no run,
  model task, executor job, effect, or queue work, and replays that refusal without retaining the command body or giant
  integer. Replay accepts only an observation above 65,536; zero, one below, and
  exact-at-limit retained refusals are invalid history;
- exact normalized command-record boundaries for prompt, steer, and follow-up
  pass one below and exactly at 65,536 and commit the compact refusal one above.
  Prompt's accepted record is proved to dominate its exact immediate normalized
  unstamped `user.message_appended` payload, so deleting that implication check
  fails but no impossible prompt `command_event_bytes` refusal is claimed.
  Follow-up's deterministic promoted event independently exercises
  `command_event_bytes`. For max-turn, token, and deadline bounds, both future
  private terminal and public payload pass at the boundary and select
  `future_bound_record_bytes` one above in fixed order; deleting only this
  future-record preflight admits a prompt whose admission fits but terminal does
  not and fails by name. Each private/public boundary crosses nil, reported, and
  estimated accounting sources, and a mutant sizing only a shorter source
  admits a later estimated terminal that cannot fit and fails by name. The selected dimension, exact candidate enum, and
  observed value name the first reachable failing candidate; every illegal
  dimension/candidate pair and a mutant hardcoding command-record admission
  fail replay. Refusal mutates no run or queue, emits no
  event, and replay remains independent of later run state. Mutants measuring
  content alone, omitting the follow-up event, measuring a payload different
  from Store's exact normalized unstamped value, or relabelling a body-caused
  refusal as configuration failure fail their named cases;
- deadline future-terminal evidence reserves the maximum unsigned-64-bit
  absolute instant at admission, then at first staging checks non-negative clock
  shape, checked-add overflow, and the exact chosen private/public candidates
  before model dispatch. Clock-domain and addition-overflow failures each commit the exact compact
  `deadline_staging_failed_v1`/failed-terminal pair, open no attempt/domain, and
  call no provider. A mutant substituting the committed duration for the
  absolute `declared_limit` fails. If either exact size assertion disagrees with
  the admitted maximum, the session is unavailable and no test-only or invalid
  history is represented as an operator failure. Page-size-one replay, first-row crash, missing/intervening/
  duplicate/mismatched second row, and commit-unknown prove the transient pending
  marker applies no terminal effect and re-presents identical bytes. Vectors
  cross every external-term integer-width edge;
  replacing the absolute-instant reservation with `deadline_ms`, wrapping the
  addition, accepting a negative/above-domain clock, or deleting the exact
  staging recheck fails by name;
- cross-version replay refuses in both directions: the new reducer rejects a
  legacy accepted `command_admitted` prompt, while the prior reducer rejects a
  v2 accepted history and a refusal-only `command_admission_refused_v1` history;
  no direction supplies, drops, or re-evaluates a context budget;
- command-admission commit-unknown is exercised separately for prompt, steer,
  and follow-up. Each re-presents the identical exact nine-key refusal and
  command binding until Store resolves it; mutation of any field or ordered
  record byte conflicts, no run/queue/public/provider state moves while
  unresolved, neither a fresh default nor an alternate accepted/refused record
  is proposed, and recovery projects the one committed result exactly once;
- accepted prompt admission emits its user-message event but no `run.started`;
  completion of the first request-plus-attempt-open transaction emits exactly one
  start, its pending first row, later turns, and replay emit none, and oversized
  command refusal emits no public event. Snapshot/recovery
  use the exact revision-2 five-member map, retain admitted-unstaged versus
  started phase at a live and historical anchor, accept a matching pre-staging
  context-failure, abort, owner-loss, and generic-terminal finish, and reject a
  start/finish for the wrong run or a duplicate start. The prior three-member
  snapshot, a phase inconsistent with `active_run_id`, a same-run steer that
  resets phase, a cross-run user message, moving start back to admission, or
  losing the pending phase fails protected cases;
- one named measured reference fixture binds 2,393 provider-visible bytes and
  799 tokens, 4,382 retained full-definition bytes and 1,462 estimator tokens,
  and a 65,536-byte project file's 65,653-byte/21,885-token wrapped message;
  mutating any exact value fails while full definitions remain durable but do
  not enter provider-token accounting;
- total estimated-context and exact-record-byte boundaries pass one below and
  exactly at their ceilings and refuse one above; the inherited reference-system
  class passes one below and refuses exactly at and one above its 1,000-token
  ceiling;
- Store normalization passes depth and collection-cardinality values one below
  and exactly at each maximum and returns the exact structural dimension,
  first rejected witness, and limit one above, including root required members,
  scalar depth, bytewise normalized-key map order, and depth-before-cardinality
  ties. Enormous outer-manifest, workspace, entry, and decision maps each fail by
  `map_size/1` plus fixed fetch without allocating/sorting a key list. An enormous
  general Store map allocates no normalized-key copy and an enormous list
  visits only 1,025 cons cells without a whole-list predicate; both report
  `1_025`. An improper list ending inside the admitted range is ordinary invalid
  data, while a tail beyond the 1,025th cons cannot outrank cardinality.
  Invalid/colliding keys in a raw
  map above the ceiling prove cardinality wins, while an admitted raw map proves
  key validity after cardinality; restoring required root members preserves the
  admitted count and creates no fictitious second overage. Event
  vectors cover atom and binary `event_sequence`, `owner_epoch`, and
  `owner_incarnation_id` keys at the root and nested maps and prove reserved-key
  refusal after an admitted cardinality, while an oversized raw map refuses for
  cardinality first. A normalized event containing the current owner
  capability still passes the isolated helper but is rejected by the complete
  transaction, while duplicate outbox event IDs remain a separate transaction
  refusal; mutants moving either protection into or out of its declared boundary
  fail. Generated
  conformance across every admitted scalar, map, list, key-normalization, and
  nesting form proves normalized output equals Store transaction normalization,
  the allocation-safe count equals
  `byte_size(:erlang.term_to_binary(normalized, [:deterministic]))` for bounded
  samples; helper and actual Store transaction normalization and structural
  results are identical, while `byte_count <= max_item_bytes()` holds exactly
  when the Store's item-byte validation admits the normalized item, including
  one below, at, and one above the byte boundary; the
  oversize traversal and byte-size calculation allocate no full encoded candidate;
- required-only preflight proves structure and a deterministic record-size lower
  bound before optional evaluation; generated cases across every descriptor
  cardinality through 1,024 prove that adding one optional descriptor cannot be
  the first structural overage when the required lower bound fits 65,536 bytes,
  and mutants that omit or reorder this proof fail;
- a request below its token ceilings but above the exact record ceiling is
  caught before Store, proving token success cannot fall through to
  `item_too_large`;
- an over-intake, total-token, or record-byte project block is wholly withheld,
  stages no project
  descriptor, and lets the task continue with the matching truthful declined
  receipt and exact nested detail; a separate property proves the derived
  project class ceiling bounds every intake-valid M2 block and that the fixed
  flat block cannot independently cross Store depth/cardinality before bytes,
  rather than pretending either branch is independently reachable;
- project-resolution cross-products lock the exact first-failure order, every
  reason-specific `nil` versus retained field, digest-before-workspace binding,
  the allocation-safe zero-or-one entry boundary before workspace and entry
  inspection, canonical-label order after that boundary, O(1) declared-size and
  per-entry limit before any content hash, the one-entry class-total equality as
  a future-shape property rather than a disposition, outer-manifest failure before
  workspace failure, and strict refusal of every
  non-`active` revocation state or non-null expiry as `invalid_decision`;
  mutants swapping adjacent checks, hashing an oversized body, calling a
  whole-list predicate, visiting a second entry or later tail, or changing one
  detail value fail. A
  matching empty manifest retains `staged` with
  `entries: []`, zero descriptors and costs, while the one-entry form retains
  exactly one entry and one optional block. Required-only byte-boundary cases
  prove that a later final refusal preserves `staged_empty` for the former and
  the applicable withholding disposition for the latter;
- required context over the system-class-token, total-token, record-byte, record-depth, or
  record-cardinality dimension commits run `failed`, zero provider calls, the
  exact nineteen-key compact retained receipt and exact five-key
  private/public failure projection, and no partial staged request or fabricated
  assistant message; non-failed variants carry no `failure`, other failed
  categories retain their accepted exact projection, and the CLI renders only
  those five bounded context fields;
- first-turn and later-turn staging refusals prove the exact contiguous
  two-record refusal/terminal set and order, the terminal's exact eleven keys,
  nil legacy bound/accounting siblings, four-field equality from the refusal
  plus fixed `retryable: false` in both terminal projections, and
  admission only from `model_pending` or `turn_settled`; wrong active run,
  wrong stable next-turn identity, wrong committed context budget, or a breach
  of the dimension-specific replay relations fails closed. Live-construction
  properties separately mutate every count, digest, token total, exact system
  observation, exact cardinality observation, project disposition, and selected
  first-failure dimension against the full preimage; replay validates only the
  bounded committed shapes and locally derivable relations listed above and
  never claims it can reconstruct omitted bodies. Page-size-one replay carries the transient
  first-row marker across a fetch and applies no terminal effect until the
  matching consecutive row arrives; crash/restart, durable-head missing-tail,
  intervening, reordered, duplicated, mismatched, commit-unknown, and third
  private promotion/steer-record cases lock the same rule. Attempts from
  provider/effect in-flight stages fail closed, and mutants routing the pair
  through the generic terminal transition, treating page end as pair end, or
  introducing one contradictory root duplicate fail;
- both terminal outbox branches are exact: a follow-up yields `run.finished`,
  optional steer resolution with reason `run_terminal`, then
  `user.message_appended` with private
  promotion and no start/settled event; no follow-up yields `run.finished`,
  optional steer resolution, then `session.settled`. A promoted successor emits
  exactly one `run.started` only when its first request-plus-attempt-open
  transaction completes, including across recovery, and moving that event back
  to the request row or promotion, or duplicating it on replay, fails;
- the successful receipt admits exactly its sixteen outer keys, six descriptor
  keys, an exact three-key `totals` map, all three exact provenance keys, and an
  exact two-key cost map in every provenance bucket; the outer byte and token
  totals equal the sums of the descriptors, every provenance bucket equals the
  descriptors in that class, the three buckets sum back to both outer totals,
  and `provider_estimated_tokens` equals the outer token total. It also carries
  the exact supported provider identity/revision, exact nil/nil transformer and
  selector pairs, estimator and canonicalization identities, and the eight exact project
  dispositions; deleting, adding, swapping, or changing any outer, totals,
  bucket, or nested project-detail member fails closed,
  and restoring
  `loopex.conservative_bytes.v1` fails rather than carrying its former guarantee
  into the narrowed policy. Validation receives the whole adjacent staged
  request and rejects a self-consistent receipt whose messages, model-facing tool
  projections, descriptor order, session/steer source binding, or project
  contribution differs; each substitution is a separate mutant;
- every structured source-reference variant above has a literal canonical-byte
  and digest golden vector. Delimiter-containing identifiers remain distinct
  because they are map members, not parsed strings; scalar legacy references,
  cross-kind key reuse, missing/extra members, tool-generation substitution,
  project workspace/manifest/label substitution, and each session identity
  substitution fail the whole-record replay check;
- message descriptor preimages use exact final-message bytes and tool descriptor
  preimages use exact model-facing projections; changing only storage metadata
  changes the full-definition source identity and record cost but not provider
  byte/token cost, while changing the projection changes descriptor digest and
  provider totals;
- the ordered-descriptor digest is reproduced only from the exact domain byte,
  eight-byte unsigned big-endian length framing, ordered canonical descriptor
  bytes, and carried canonicalization version; reordering two descriptors,
  omitting a length, changing one descriptor, or substituting an unknown version
  changes the digest or fails unavailable without allocating one aggregate
  descriptor encoding;
- successful-stage and compact-refusal commit-unknown paths each re-present the
  identical normalized transaction until resolved, dispatch no provider while
  unresolved, and after recovery expose exactly one staged request or one failed
  terminal rather than proposing a different context decision;
- a context refusal with queued steer and queued follow-up commits the compact
  record, failed terminal, public event, steer resolution, and promotion in one
  transaction; the successor inherits all four values, event order is exact,
  commit-unknown re-presents identical bytes, and restart advances neither run
  twice;
- cumulative `token_budget` remains distinct and its `bound_reached` observed
  value is never populated from either admission dimension. ADR 0018's
  provider-attempt evidence independently protects reply normalization,
  accounting, retry, settlement, and recovery;
- prompt, queued follow-up admission, promotion, succession, and restart reuse
  the exact committed context budget rather than the current runtime default;
- the queued follow-up retains ADR 0011's exact input shape while promotion
  inherits all four committed predecessor values under ADR 0013;
- malformed, missing, unknown, overflowed, or inconsistent budget/cost data
  fails closed, including every compact-receipt project disposition outside the
  exact declared set, the `staged_empty` boundary when a zero-block evaluated
  manifest precedes a final required-only byte refusal, and the two
  post-withholding dispositions needed when the required replacement
  subsequently fails; changing one compact count without the required-only
  descriptor partition, digest, and estimated-token preimage fails;
  the three existing bounds still admit positive integers above unsigned 64-bit,
  while the new context value refuses one above its unsigned 64-bit maximum;
  and
- mutants substituting cumulative budget, dropping a provider-visible tool
  projection, charging a full tool definition instead of its model-facing
  projection, measuring any request-envelope field instead of the exact final
  context members, substituting non-final bytes for the step-7/8 final-candidate
  cost, allocating the full oversize
  candidate before refusal, skipping the depth or cardinality walk, mapping one
  structural dimension to another, changing traversal order or tie precedence,
  relabelling a deeply nested struct or other non-plain value as a depth
  overage, treating fixed-point non-convergence as a context verdict,
  resolving defaults before replay, replacing
  a commit-unknown transaction, widening either exact refusal shape, changing
  any successful-receipt or nested project-detail key set, failing to recompute
  the fixed point after project removal, changing digest framing, repeating oversized bodies
  in the refusal, leaking a failure projection onto another terminal, or calling
  the provider after refusal fail protected cases.

The rollback unit is runtime validation, both `prompt_admitted_v2` and
`command_admission_refused_v1`, `deadline_staging_failed_v1`, promotion and
recovery of the committed context value, the revision-2 public snapshot
projection, context staging, Store limit/size introspection,
reference composition/command defaults, operator and compatibility
documentation, and tests. The prior reducer refuses the new prompt admission and
generic command-refusal record kinds, including a refusal-only history with no v2 admission, and the new
reducer refuses the legacy accepted `command_admitted` prompt kind. Cross-version
replay therefore makes incompatible development histories unavailable rather
than replaying them under a dropped or invented budget. No Store object
migration is required on the unreleased surface.
If ADR 0016's receipt-fitting path or ADR 0018's settlement-preflight path is
present, rollback preserves `Store.normalize_and_measure_item/2` and limit
introspection until every consumer is removed, or removes the dependent units
atomically. Reversing that order leaves a required receipt or settlement
preflight without its normalization and measurement authority.
