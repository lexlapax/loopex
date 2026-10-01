# M7 round 6 disposition

## Concept

The external [round 6 report](M7-external-review-6.md) finds planning candidate
`07b1a19cb7fdcab3155778f1119c043d23ba0d72` not yet ready for acceptance. This
record reconciles all 37 findings and the internal adversarial review of the
repairs. It supersedes round 5's readiness conclusion without rewriting that
historical report or disposition.

The maintainer answered three questions on 2026-09-30. The post-terminal
thinking witness proves provider acceptance after a cut tool run and native
thinking on the exchange after it. The reviewed outage verdict covers
provider-side failures only. Durable host startup classifies helper history
under a fixed, resumable 60-second bound. The
[context map](../developer/agent-context-map.md#disposition-m7-round6-decisions-2026-09-30)
records all three.

Three repairs make a reversible choice the maintainer may change before
acceptance. Any failure of a started case stops the closure matrix instead of
continuing through later paid cases. A short unit in front of an oversized one
is summarized with it from marked excerpts instead of being recorded as a
limitation. The startup scan keeps all durable admission closed until coverage
completes, including new sessions, because no partial opening could be made
safe in this packet; one unreadable session history therefore keeps the durable
host closed until the root is restored from backup. Repairs 2, 7 and 13 each
take one of the report's stated options; repair 6 adapts its first option by
reporting the foreground run rather than null.

M7 remains Open, ADRs 0041–0049 Proposed, and both labelled vision amendments
unaccepted. These are planning repairs and implementation obligations, not
product tests, successful demonstrations or formal acceptance. External audit
still decides whether this packet is ready.

## Technical depth

The received report is retained byte-for-byte with SHA-256
`0bb596b8cbf651b23ae697b297c38f6930af687b8115460cb1504104a10babfd`. Its
read-only method and evidence limits remain those stated in that report. No
provider call, product suite or release lane ran for these text repairs. The
provider behavior behind finding 11 is documented intent retrieved on
2026-09-30, not a live observation. Literal schema, vector and fixture pins
remain phase-0 implementation obligations; naming one does not prove it.

| ID | Disposition | Owning contract and repair |
| --- | --- | --- |
| 1 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): expiry of the fixed pre-staging cutoff ends episode and run with closed cause `compaction_preparation_deadline`; an unrepresentable first maintenance deadline records `maintenance_deadline_unrepresentable`. |
| 2 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): ordinary `explicit` stops after its first committed checkpoint and reports `checkpointed`. |
| 3 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): a complete prefix whose message-list serialization is at most 6,144 bytes and whose next eligible unit cannot join it is selected together with that unit in excerpt form, decided before dispatch. A sole small prefix before a protected tail remains a recorded limitation with explicit compact as remedy. |
| 4 | Obligation explicit | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): the natural-completion gate is a host registration condition; core's guarantee is the post-dispatch failure. |
| 5 | Obligation explicit | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): `run_active` refusal for compact during a run, deadline literal mapping, standalone-scoped exhaustion sentence, cutoff clock owner, shared transaction for non-refusal endings and the unreadable-reply route. |
| 6 | Proposal repaired | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): `run_id`, `outcome` and `last_outcome` name runs only; compaction and configuration results appear in transcript, status and exit code. |
| 7 | Obligation explicit | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): the owner defers every other proposal while an admission proposal is pending and applies them after resolution. |
| 8 | Obligation explicit | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): a live owner with neither preimage nor committed fact answers pending; an interactive host accepts only quit, end of input or interrupt after the resolver deadline. |
| 9 | Obligation explicit | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision) and [M7](../plans/M7-technical.md#technical-plan-operator-validation): `error.code` admits the original disposition code; V12.4 names workspace, pending-policy and missing-route abandonment. |
| 10 | Clarified | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision) and 0049: bash, write and edit keep their generations and use the preparation path; `config validate` accepts both binding forms. |
| 11 | Maintainer choice recorded | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision) and [M7](../plans/M7-technical.md#technical-plan-operator-validation): the post-terminal request proves acceptance, exact mapping, facts and no old native state; one further prompt in the same subcase proves thinking resumes. A `product_failure` with no assertion-preserving correction, including provider rejection of a registered cell, routes to a scope amendment. |
| 12 | Proposal repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): an unregistered exact model resolves `default` to one literal generic descriptor with all three Booleans false; a thinking block under it fails the attempt. |
| 13 | Proposal repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): the reference default string becomes the dated identity; one literal alias entry serves existing configuration and legacy requests, and the host commits the dated literal. |
| 14 | Proposal repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): the buffered path admits its transport-owned `accept-encoding: identity` header. |
| 15 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): the case table and V7.3 name seven thinking-rounds and nine thinking-bound subcases, the Haiku-none switch leg, the baseline tool round and the maintenance key. |
| 16 | Proposal repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): relation row 4 covers every other stop/call combination; an omitted empty completion counts as absent for grouping and the capability check. |
| 17 | Obligation explicit | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): the invocation-owned per-request hook is the validating join; manual values are installed in the native body, never through dependency options. |
| 18 | Clarified | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): "registered for ordinary resolution", "proposed rows" and "any of these facts". |
| 19 | Proposal repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): core's cancelled-before-dispatch terminal is a pre-effect fact; an excess expected operation stays unresolved, helper admission is refused and the parent's ordinary activation proceeds. |
| 20 | Maintainer choice recorded | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): fixed 60,000-ms bound per start; coverage entries in the disposable cache validated by an opaque Store prefix token and a resume form of the intent query; durable admission closed until coverage completes; named refusal with counts; continuation by a resident host or a later start; Concept sentence added. |
| 21 | Proposal repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): closed list of tagged pre-effect refusal reasons and the reserve-append boundary. |
| 22 | Proposal repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): cancelling a registered job with no reserve frame appends nothing and answers cleaned; index failure after reserve has a route. |
| 23 | Proposal repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): terminal rows are emitted only for calls with an earlier intent; the run-level unknown terminal joins by run with a null call identity. |
| 24 | Clarified | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): receipts remain in the ledger; a transient cache fault answers a distinct pending error. |
| 25 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): a new candidate always runs its own complete matrix; "only the affected case" names the lifted fence; the pre-merge carrier is the reviewed index disposition. |
| 26 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): any consumed non-pass result stops the logical matrix, which is then not resumable. Smallest safe reading; reversible by the maintainer. |
| 27 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): a ceiling breach adds its assertion ID; the mechanical result follows the precedence list and the reviewer assigns the cause. |
| 28 | Maintainer choice recorded | [M7](../plans/M7-technical.md#technical-plan-evidence): provider-side transport failure, 5xx/529 and timeout after `started` are outages; 429, quota and host-local network loss are operator prerequisites under the evidence-loss rule. |
| 29 | Proposal disclosed | [M7 Concept](../plans/M7.md#concept-plan-decisions) and the [context map](../developer/agent-context-map.md#disposition-m7-round6-matrix-proposal-2026-09-30) name the logical-matrix rule as a proposed change to what the release check proves. |
| 30 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): committed heads, not the genesis pin, are the anchor; each gated change records the head; a lost index needs a maintainer-authorized successor campaign; a marker is superseded by a verified later acceptance. |
| 31 | Obligation explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): mechanical-result precedence and criterion, matrix ID in the case event, one digest cell for invocation logs, separate committed and Pending heads. |
| 32 | Obligation explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): trace cases are `m7-operator`; the task's commit adds manifest and scaffold skeleton; the daemon observer is a second connection; legacy attended rows keep first position. |
| 33 | Record disclosed | [Context map](../developer/agent-context-map.md#disposition-m7-continuation-vision-amendment-2026-09-30) cites the round 6 brief's restatement of the authorized section 13.4 scope, including the retained descriptor. |
| 34 | Proposal repaired | [0041](../adr/0041-session-lineage-projection-and-context-budget.md#concept) header, Technical and the plan row name the ADR 0009 order amendment. |
| 35 | Proposal repaired | [Concept files](../adr/0044-run-model-and-reasoning-configuration.md#concept): sentences added in 0043 (cutoff, `maintenance_active`, one checkpoint per compact), 0044 (mandatory nine-key replies, unregistered default, alias) and 0046 (startup classification on every durable host). |
| 36 | Proposal repaired | Both [vision](../vision.md#concept) headers list the section 25 risk note. |
| 37 | Clarified | Depends-on lines for 0042, 0044 and 0047; context-map table row and rollback anchor; ADR index names the plan's prerequisite rows as the acceptance annotation set; plans index states the packet rule. |

### Root adversarial pass

The root traced each repair into the surrounding contract before advisory
review. Three interactions changed the first draft:

- A reply without thinking on the post-terminal request must still settle. The
  capsule union already permits a capsule of reference nodes only; ADR 0044 now
  says so, or the selected oracle would fail inside the adapter.
- No pre-existing session can be classified as ordinary before helper-history
  coverage is complete, because child-create identities derive from every
  parent's intents. The resumable bound therefore keeps all durable admission
  closed, including creation of new sessions, until coverage completes; a first
  draft that admitted sessions created in the current incarnation was withdrawn
  because it could not be made safe.
- The plan has no progress section in its technical file. Committed index heads
  go to the Concept file's Progress and Evidence section.

### Advisory review

Three fresh readers reviewed the uncommitted repair diff against the 37
findings, each over a disjoint area and under the same standalone brief shape:
judge each finding repaired or not from current text, then attack the new text
for contradictions, unreachable or doubly assigned states, schema gaps, false
source claims and Concept/Technical parity. They were read-only by procedure,
not an enforced sandbox, and ran no code, check or provider. The lead verified
each report against the cited lines and acted on every finding; none was left
as Consider, Noted or Dismissed.

| Area | Blocking | Should fix | Lead judgment and repair |
| --- | --- | --- | --- |
| Compaction, piped chat, artifacts | 1 | 9 | Act on all. The episode terminal is now the first row of its transaction, so ADR 0017/0018 consecutive pairs stay adjacent and the deadline-staging pair keeps its four-key shape. The small-prefix measure is the message-list `byte_length`; an unfittable pair refuses before dispatch; every run-owned episode captures the cutoff and standalone captures none; a nine-key v2 summary reply fails as incomplete. Status gains `last_compact`; the run-only rule covers every shutdown row; deferral excludes the resolver's own timers and never queues commands. |
| Thinking, verdicts, attempts index | 1 | 17 | Act on all. A ceiling breach no longer fixes a mechanical label against the precedence list. The generic descriptor names its renderer literal and its post-terminal consequence; the relation table covers a thinking block under a non-continuation mapping; thinking-rounds must replay a retained thinking literal; the cancel case takes the same two later prompts; provider B's summarizer needs a registered row. The stop rule covers subcases and `--only` lanes and excludes the resumable pre-dispatch result; committed heads use a follow-up documentation commit; a marker cannot block its own supersession; a successor campaign starts on a new candidate. |
| Helpers, records | 2 | 7 | Act on all. Coverage entries validate through an opaque Store prefix token and a resume form whose watermark sits below the first open intent, with a digest over retained job entries. The bound never opens admission partially. Cancel-before-reserve states both coordinator orderings. The excess state refuses with `helper_slot_occupied` and has no release. The refusal list drops an undecidable reason and fixes its boundary at the reserve attempt. The disposition no longer claims a review before recording it. |

The reader of the retained round 6 report noted that it names a retrieval tool
and a client-specific scratch path. It is kept byte-for-byte as received
evidence; whether to keep those names is the maintainer's call.

Two further fresh readers then rechecked that fix pass, again read-only and
without running code. They confirmed 8 of 19 checked points closed and reported
4 blocking, 20 should-fix and 15 minor defects; the lead acted on every one.
The blocking four were a stale sentence in this record describing a withdrawn
partial-opening design, a corrupt-session state with no exit under the
all-closed rule, the preparation cutoff reading differently in the two ADR 0043
files, and ADR 0044 still rejecting a version-2 summary reply that ADR 0043 now
classifies as incomplete. The repairs: the cutoff applies only before an
episode's first staged maintenance request; a version-2 maintenance reply is
readable and fails as incomplete in both ADRs; the scan token is derived by core
from returned records with no new Store callback, at page-boundary watermarks,
with a digest over immutable job-entry members; an unreadable session keeps the
root closed with restore as the exit; provider B's summarizer is an additional
registered row pinned in phase 0; the stop rule, lane resume, committed index
heads and the event union were pinned. No third recheck was run: the external
audit of the committed bytes is the next independent review, and these last
repairs have not themselves been independently reread.
