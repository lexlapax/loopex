# 0021. Compacted provider-accounting provenance — Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Compacted provider-accounting provenance](0021-compacted-provider-accounting-provenance.md#concept).

<a id="technical-adr-0021-context"></a>
## The Missing Durable Distinction

Concept: [Context](0021-compacted-provider-accounting-provenance.md#concept-adr-0021-context).

[ADR 0018](0018-provider-attempt-authority-and-recovery-technical.md#technical-adr-0018-decision)
fixes version-1 settlement at twelve root keys. Its unreadable result has only
`kind: error` and `category: unreadable_model_answer`. The current
[producer](../../apps/loopex/lib/loopex/runtime/session_state.ex) distinguishes
prevalidation rejection from full-settlement compaction, but the
[validator](../../apps/loopex/lib/loopex/runtime/provider_attempt.ex) cannot retain
or check the corresponding usage distinction. The
[review follow-up](../evidence/M2-ff17990-review-followup.md) records that gap.

The compact form cannot prove omitted content passed validation. Its committed
observation needs producer-path evidence, just as ADR 0017's compact context
refusal separates live observation from replay-verifiable relations. Adding
fields to the exact old schema is not a compatible repair.

<a id="technical-adr-0021-decision"></a>
## Version-2 Representation and Validation

Concept: [Decision](0021-compacted-provider-accounting-provenance.md#concept-adr-0021-decision).

### Exact schema

`model_attempt_settled_v2` retains ADR 0018's exact twelve root keys and their
meaning: `kind`, `run_id`, `turn_id`, `operation_id`, `attempt`,
`staged_request_digest`, `transport`, `termination`, `conversation`, `next`,
`result`, and `accounting`. Only the kind value and unreadable result schema
change. Normal reply and model-failure results remain exactly:

```text
%{"kind" => "reply", "reply" => bounded_canonical_reply_v2}
%{"kind" => "error", "category" => "model_call_failed"}
```

An unreadable result is exactly:

```text
%{
  "kind" => "error",
  "category" => "unreadable_model_answer",
  "accounting_evidence" => evidence
}
```

Its evidence is one of these exact maps:

```text
%{"kind" => "none"}

%{
  "kind" => "validated_reply_compaction_v1",
  "usage" => normalized_usage,
  "dimension" => "record_bytes" | "record_depth",
  "observed" => uint64,
  "limit" => uint64
}
```

`normalized_usage` is ADR 0018's exact reported pair or unreported category.
Missing/extra keys at every named level, unknown kinds, and invalid values are
refused. `none` asserts only absence of validated accounting evidence; it must
not authorize a reported figure.

For bytes, limit is `65_536` and observed is the exact normalized external-term
size of the rejected full version-2 settlement, strictly above that limit.
`Store.normalize_and_measure_item/2` supplies the size; the caller compares it
with the Store ceiling. The helper does not itself return a byte-limit refusal.
For depth, limit is `12` and observed is `13`, the first rejected depth returned
by Store's structural traversal, not a claim to retain the full tree depth.

Cardinality cannot newly exceed its ceiling through fixed small settlement
wrappers around an admitted canonical reply. Raw over-cardinality material is
rejected before this boundary and receives `none`. Other unexpected preflight
failures make settlement unavailable, not a fabricated compaction observation.

### Closed relations

The old combination table still governs all ordinary result cells. Unreadable
version-2 cells are restricted to:

| Evidence | Usage | Accounting |
| --- | --- | --- |
| `none` | absent | exact `estimated / remaining_allowance` |
| compact | reported pair | reported pair equal in both members |
| compact | unreported | exact `estimated / remaining_allowance` |

Each requires transport `dispatched_or_unknown`, conversation `none`, next
`terminal`, and termination nil, abort, or deadline. Owner loss remains an
estimated `model_call_failed`, never invented reply compaction. No unreadable
cell retries or enters tools/conversation. A reported figure requires exactly
matching usage in either the retained reply or the compact evidence map.

### Producer proof and replay proof

The live writer:

1. Admits and canonicalizes the raw reply under ADR 0018.
2. Uses that single immutable canonical reply and its normalized usage to build
   the intended full version-2 settlement and its accounting.
3. Applies Store-owned structural normalization and exact byte measurement to
   that full record, then compares size with the owning record ceiling.
4. Only on the named byte/depth overage replaces the result and conversation
   with compact unreadable/no-conversation while retaining that usage and the
   exact overage observation. The compact verdict is terminal, preserving an
   earlier abort/deadline winner rather than any full reply's continue action.
5. Preflights the actual compact settlement and paired terminal independently
   and commits only their admitted normalized bytes.

Malformed or prevalidation-refused raw input uses `none` and estimated
accounting. A size-fitting settlement does not become compact merely because
its separate terminal record or Store transaction is unavailable. Unexpected
refusal of the compact pair makes the session unavailable without fabricated
accounting, conversation, dispatch, or terminal truth.

Replay checks exact schemas, known versions, bounded values, the fixed
overage relations, normalized usage, and usage/accounting equality. It cannot
prove from a self-declared map that validation happened or recompute omitted
content. Producer-path tests must prove the usage and observation came from the
same canonical reply/full-settlement candidate. The Store transaction protects
the retained observation afterward. No discarded-reply digest, raw reply,
adapter call, or current-limit recomputation participates in replay.

### Version cutover and recovery

Attempt-open remains `model_attempt_opened_v1`, with unchanged two-attempt
allowance and exact prior-settlement proof. A version-2 settlement may close an
already committed version-1 open attempt. Recovery must not redispatch it to
obtain new-format evidence. New writers emit only version-2 settlements,
independent of session age, attempt number, configuration, or reply size.

The new reader accepts old cells under ADR 0018's exact rules: canonical reply
with matching accounting, not-dispatched with no accounting, model failure with
estimated accounting, and unreadable with estimated accounting. A formerly
admissible version-1 unreadable-plus-reported cell fails specifically as
`ambiguous_legacy_provider_accounting`. It is not rewritten, estimated, queried
from the provider, or retrospectively declared validated. Invalid old cells stay
invalid. Unknown future versions fail closed.

Versions may coexist across turns/attempts as a version-1 prefix followed by
version 2. After the first version-2 settlement, a version-1 settlement is invalid
history; replay never reopens the legacy allowance. A reader must reduce through the
committed head before owner readiness, recovered dispatch, or semantic session
work. Existing ownership acquisition can commit fenced administration before
that reduction; this proposal neither moves that boundary nor claims an old
reader writes nothing. Failure at version 2 prevents it from scheduling or
appending attempt, settlement, terminal-accounting, or public effects afterward.
The first version-2 settlement is enough to make an old reader unavailable;
there is no separate cutover record or in-place hot-upgrade claim.

### Commit-unknown and terminal atomicity

Normalize settlement version, evidence, accounting, paired terminal, and outbox
events once before transaction construction. The existing canonical mutation
digest binds these retained bytes. Commit-unknown re-presents the identical
transaction under the same identity, never switches version, remeasures a reply,
changes an observation, or recalculates usage from reconstructed material.

Terminal settlement remains exactly:

```text
[model_attempt_settled_v2, run_terminal_committed]
```

The pending reducer marker accepts either known settlement version. Its first
row exposes no semantic effect until the exact consecutive matching terminal,
including across a page boundary. Missing, intervening, duplicate, or mismatched
rows are invalid. Accounting, conversation, run state, and terminal outbox
effects apply together. Retry/continue settlements retain one-row transactions.
The compact evidence adds no terminal/public field.

<a id="technical-adr-0021-alternatives"></a>
## Alternative Costs

Concept: [Alternatives](0021-compacted-provider-accounting-provenance.md#concept-adr-0021-alternatives).

Estimating all unreadable cells loses known usage. Grandfathering ambiguous old
pairs preserves availability but explicitly retains their validation gap.
Rewriting them changes historical cumulative totals and later budget decisions.
Full-reply artifacts need separate ownership, retention, failure, and rollback
decisions. Another attempt-open version adds no authority fact. The selected
representation keeps dependency direction and budgets unchanged, trading narrow
legacy availability for explicit accounting validation.

<a id="technical-adr-0021-consequences"></a>
## Rollback and Decisive Evidence

Concept: [Compatibility, delivery, and rollback](0021-compacted-provider-accounting-provenance.md#concept-adr-0021-consequences).

No in-place journal migration is supplied. Stop current owners and preserve a
complete backup before changing binaries. Old code supports only histories
without version 2; new-version or ambiguous legacy sessions remain unavailable
rather than guessed or rewritten. Existing Store/executor termination and
rollback preconditions still apply. Restart and full replay, not hot upgrade,
define the compatibility boundary. Historical authority records are not edited;
the later acceptance record must state the exact correction to the misleading
blanket-conservative reading of ADR 0018 in override 21.

Implementation changes producer, reducer, mixed-version recovery, guidance, and
tests together. It changes no public DTO, Store ceiling, token arithmetic,
attempt allowance, dispatch permit, adapter callback, reconciliation policy,
canonical reply, or terminal algebra.

Required decisive evidence includes:

- exact root/result/evidence/usage keys, enums, and integer boundaries;
- measured byte and depth boundaries, preserving exact observation and usage;
- malformed/raw-admission refusals with plausible usage still yielding `none`
  and estimated accounting;
- each reported-member mismatch refused; unreported compaction estimated;
- producer observations from the same immutable canonical reply and actual full
  settlement, including tool replies whose compact verdict becomes terminal;
- every unambiguous old cell, narrow ambiguous-legacy refusal, mixed versions
  with no version-1 settlement after cutover,
  unknown versions, and settling an old open attempt without redispatch;
- real old-reader replay refusal before readiness/effects, distinguishing any
  fenced ownership-administration writes from semantic work;
- page-size-one pairing and every missing/reordered/duplicate/mismatched row;
- commit-unknown byte identity for one-row and terminal-pair transactions; and
- no evidence map in conversation, public events, diagnostics, or rendering.

Selective mutants must fail when they report from `none`, admit unrelated
reported figures, derive usage/observation from another candidate, compact raw
admission failure, keep continue after compacting tool calls, emit version 1
from the new writer, requery/rebuild during replay, apply an unpaired settlement,
change commit-unknown bytes, or schedule after incompatible replay.

Acceptance precedes dependent schema work. These are not claims of executed
proof or newly locked tests. Any Closed-M2 gate change needs its separate
additive generation proposal, acceptance, rebind, and review.
