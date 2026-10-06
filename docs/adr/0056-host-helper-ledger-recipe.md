<a id="concept"></a>
## Concept

Technical depth: [Host helper ledger byte recipe](0056-host-helper-ledger-recipe-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-06
- **Decision owner:** Maintainer
- **Completes:** [ADR 0046](0046-child-session-tool.md#concept)'s private host persistence recipe; its helper authority, allowance, recovery and cancellation decisions remain unchanged.
- **Constrained by:** [ADR 0049](0049-explicit-host-configuration.md#concept), [ADR 0051](0051-current-format-physical-restore.md#concept) and the [current-contract disposition](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02).

<a id="concept-adr-0056-purpose"></a>
### Purpose and boundary

Technical depth: [Authority and implementation gap](0056-host-helper-ledger-recipe-technical.md#technical-adr-0056-purpose).

A helper must retain its original creation input, reservation, stop, settlement
and every admitted attempt's receipt before reporting those facts. ADR 0046
already chooses the composition owner, mutation families and finite storage
limits. It leaves literal framing and several closed payloads unspecified. T11
therefore cannot safely implement append, replay or complete helper-aware restore
by treating arbitrary JSON as a ledger.

Recommend one current private recipe: canonical UTF-8 JSON inside checksummed
frames, immutable content-addressed objects, closed mutation maps and a pure
ordered reducer. Keep the existing 1 MiB object and binding-log caps,
65,536-byte frame payload, 16 MiB run log and 128-child ceiling. Reserve one
maximum frame for each possible remaining transition and each admitted attempt's
receipt. Exact integer arithmetic preserves overshoot and never refunds uncertain
usage. The byte limit may deny work before the child-count limit.

This decision fixes private persisted bytes and their validation, not a helper
scheduler, a Core ledger, a new public accounting query or a backup command.
Core owns genesis, session history, executor facts and accounting. Composition
owns the helper declaration and ledger. Existing validators are reused; private
Core schemas and reducers are not copied into the host.

<a id="concept-adr-0056-recipe"></a>
### Proposed persistence and recovery

Technical depth: [Bytes, objects and mutations](0056-host-helper-ledger-recipe-technical.md#technical-adr-0056-recipe).

Bind filenames, transaction identities and mutation digests to length-preserving
canonical identity preimages. Preserve opaque IDs as schema-declared padded
base64, integer epochs as integers, exact current genesis bytes and the original
attempt tuple. The companion closes catalog, declaration, creation, binding,
run and derived-index records. New ledger/cache directories use 0700 and their
files 0600; existing object and lease writers retain their current modes. No
credential value or grant is retained.

ADR 0046's accepted Core command revision must bind the original prompt text,
authored bounds and absolute cutoff before helpers can prompt a child. Its
owning normalized-command constructor remains unimplemented. This recipe uses
only that owner's digest and retained admission; it supplies no host substitute
or fallback to the current command identity, which omits authored bounds.

One serial adapter owner and the existing exclusive placement/writer lease own
all mutations. An append is acknowledged only after file sync. Partial write or
sync uncertainty fences that adapter's mutations, including another parent's
settlement and slot release, until the original transaction is resolved.
Identical transaction replay returns the original result; conflicting bytes
refuse. Only a genuinely incomplete final frame may be removed after positive
writer termination and exclusive recovery. A complete corrupt frame refuses.

Recovery remains stop-only. Retained IDs, digests, receipts and index entries
never authorize creation, prompt, activation or grant replacement. Missing
reservation recovery still requires complete intent coverage and conclusive
absence of the original child creation. It charges a count conservatively and
cannot turn a lost log into a fresh allowance. Parent-session slots span runs;
independent parents can progress concurrently when the adapter is not fenced.

<a id="concept-adr-0056-accounting"></a>
### Accounting prerequisite

Technical depth: [Settlement and completion credit](0056-host-helper-ledger-recipe-technical.md#technical-adr-0056-accounting).

A settlement requires the owning Core's verified whole-child-run charges,
including automatic run-owned maintenance, and conclusive terminal and cleanup
facts. A last-charge source or a terminal usage summary cannot prove that all
attempts reported usage. Standalone compaction is a separate session charge and
cannot be folded into the child run by proximity.

The companion defines the ledger's stored settlement projection and exact
reservation/refund arithmetic. It does not choose the pending accounting read's
API, captured-head/fence contract, lifetime or response caps. That producer and
its representability proof remain prerequisites to helper execution and truthful
settlement. Until they exist, no arbitrary host map may claim exact usage, no
private reducer copy supplies it, and uncertain work retains its reservation and
occupied slot. Accepting this recipe alone does not enable helpers.

<a id="concept-adr-0056-options"></a>
### Options and consequences

Technical depth: [Alternatives and evidence](0056-host-helper-ledger-recipe-technical.md#technical-adr-0056-options).

1. **Recommend the closed JSON recipe.** It completes ADR 0046's selected
   representation, permits independent byte vectors and direct inspection, and
   reuses the existing retained-object and genesis codecs. Maximum-frame credit
   is conservative and simple to audit; it can refuse earlier than a tighter
   per-kind formula.
2. **Use tighter per-kind maxima with the same recipe.** This can admit more
   operations within 16 MiB, but requires proofs for every encoded field,
   attempt receipt and future transition. A missed member could strand admitted
   work. A later reversible optimization must preserve the same credit guarantee.
3. **Replace the host ledger with a Store transaction family or ETF log.** This
   would require amending ADR 0046's ownership or representation, add coupling
   and new restore decoders, and does not resolve the accounting prerequisite.
   It is not recommended for this bounded gap.

The proposal introduces no new allowance, queue, cleanup deadline, provider
billing guarantee or authority claim. Required real-path, fault, independent
vector and whole-root restore proofs remain open.

<a id="concept-adr-0056-compatibility"></a>
### Compatibility and disposition

Technical depth: [Current-format implementation and restore](0056-host-helper-ledger-recipe-technical.md#technical-adr-0056-compatibility).

Before 1.0, implement only this current helper contract. Refuse unsupported,
malformed or incompletely validated state; add no older-root importer or fallback.
Current-format restart, retained duplicate results and complete backup/restore
remain required. ADR 0051 must validate every shipped helper object, frame,
reference and history relation without activating actors or repairing the backup.
A checksum proves retained bytes, not latestness, terminated owners or exclusion
of other roots. Removing the adapter cannot erase unresolved helper obligations.

This pair remains Proposed. Independent review and exact-byte maintainer
acceptance precede dependent implementation. The separately pending request
schema question and public accounting decision are unchanged.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
