# M7 round 8 disposition

## Concept

The external [round 8 report](M7-external-review-8.md) finds one remaining
defect in planning candidate `9392e19d5f6a2f3bfd20a4c61dffa67adf74c75d`: ADR
0046's Concept described the resident-host startup limitation more narrowly
than its Technical file. That phrase is corrected. The report found no
remaining blocker in behavior, recovery or evidence mechanisms.

The maintainer then asked for a full internal implementation-readiness review
before acceptance. Six fresh readers each read one area of the whole packet
against the paired-document rule, which makes any Concept and Technical
mismatch blocking. They found 22 blocking items, 35 should-fix items and 14
minor ones. Most blocking items were Concept sentences that were silent or
narrower than a sound Technical rule; five were real contradictions or
undecided states. All were repaired.

The repairs made ten further author choices where the text allowed two
readings. Each takes the reading the surrounding rules already implied, each is
now stated in a Concept file, and the maintainer may reverse any of them:

- Compaction during a run covers only history from before that run.
- An abort or elapsed deadline wins over a summary still waiting to commit.
- Trace flags exist on chat, ask and daemon startup only.
- A settled legacy session with no prior model request resumes only with an
  explicit model flag; `config show` reports no committed values.
- A model with a registered row refuses its unlisted levels instead of falling
  back to the generic descriptor.
- A helper child that finishes cleanup after its parent's window is settled
  when its evidence becomes conclusive.
- Simultaneous helper refusal conditions resolve in one fixed order.
- Direct core startup accepts a well-formed summarizer map and refuses at
  episode time when a required setting is missing.
- A read offset beyond the object size is refused before policy.
- A session with no artifact-capable read tool keeps the inline result form.

The three author choices recorded in round 6 are unchanged. None of the
readiness-review repairs in this record has been read by an external round; the
internal rechecks are listed under Recheck.
M7 remains Open, ADRs 0041–0049 Proposed, and both labelled vision amendments
unaccepted. These are planning repairs, not product tests, demonstrations or
acceptance.

## Technical depth

The received report is retained byte-for-byte with SHA-256
`6f1b0d2511cb78cf48fcf31654c54bf31c0e8da5862ead3e2b9764810640ee50`. No provider
call, product suite or release lane ran for these repairs.

| ID | Disposition | Owning contract and repair |
| --- | --- | --- |
| R8-1 | Proposal repaired | [0046 Concept](../adr/0046-child-session-tool.md#concept): the first resident-only case is "a root whose enumeration and saved-entry validation together exceed one bound", matching the Technical rule. |
| Noted | Clarified | [M7](../plans/M7-technical.md#technical-plan-evidence): the fixed ordering sentence opens "During the full matrix". |

### Final internal readiness review

Each reader had one area, read its files completely, and reported pair
mismatches, contradictions, undecided reachable states, wrong source claims and
header inaccuracies with replacement wording. They were read-only by procedure,
not an enforced sandbox, and ran no code, check or provider. The lead verified
each report and acted on every finding.

| Area | Blocking | Should fix | Minor | Repairs |
| --- | --- | --- | --- | --- |
| ADRs 0041, 0042 | 3 | 3 | 4 | A session whose `artifact_read` is null keeps the inline form, and `artifact_read_unavailable` has one defined trigger. The Concept names preparation causes and the new grep, find and ls generations. Small inline results are fixed, not prepared. The owner refuses an out-of-range offset before policy. Ephemeral instruction options are stated in 0042. |
| ADR 0043 | 6 | 7 | 2 | Current-run groups are irreducible. The Concept states the per-episode cutoff, the settled-summary exception, multi-summary explicit compact over a hard limit, and both public events. The `project_resource` member keeps ADR 0017's four-key shape. Completion is checked before content. Clock failure at admission, direct-core startup, new maintenance record kinds and abort during a pending checkpoint are decided. The header names the ADR 0010, 0017 and 0018 amendments. |
| ADR 0044 | 5 | 4 | 0 | The Concept states that thinking resumes only on continuation-required cells, that a model mismatch fails the call, the third core-checked flag, the provider-B summarizer row and the limit-stop failure on thinking modes. A registered model refuses unlisted levels. Response-model equality applies to every registered row. |
| ADRs 0045, 0047, 0048, 0049 | 1 | 5 | 2 | Trace flags are on chat, ask and daemon startup only, in both 0049 files and the plan. `config show` reports no committed origin. Every owner timer is deferred during an unknown admission. The question expiry formula has no undefined operand. A legacy session needs an explicit model flag. 0047 and 0048 were clean. |
| ADR 0046 | 4 | 5 | 3 | `invalid_tool_arguments` joins the closed refusal list with a fixed precedence order. The Concept states both causes of the conservative charge, the permanent cross-run helper lockout, the two reported counts, the ledger byte cap, registry refusal and follow-up cutoff. Settlement is deferred until evidence is conclusive. Enumeration failure and the two counts are defined. |
| Plan pair and governance | 3 | 11 | 3 | The Concept lists every ephemeral addition, the resident-host limits, the maintainer disposition routes and the author-choice labels. Head lines carry the campaign ID so a successor campaign can pass preflight, and are owed after any indexed lane or stopped matrix. Resume re-stages the fresh-source extraction. `cross_uid` is ordered. The A→B→A case owns a restart. `m7.rollback` creates the V13.1 roots it later reads. The acceptance rows no longer promise another external audit. |

### Recheck

Three fresh readers rechecked the readiness-review repairs, each over a
disjoint set of files, under the same read-only procedure. They found 18
blocking items, 18 should-fix items and 5 minor ones, and the lead acted on
every one. The blocking items fell into three groups:

- Seven author choices had no Concept sentence although this record said each
  did. Each now has one, in ADRs 0041, 0043, 0044, 0046 and 0049.
- Six repairs collided with neighbouring text. ADR 0043's new maintenance
  record kinds contradicted ADR 0044's settlement writer; a standalone clock
  failure had no legal completion shape; "a settled summary finishes its
  checkpoint" ignored the abort and progress rules; `config show` was told both
  to read no store and to show an active episode model; a malformed helper role
  had two refusal reasons; and a completed closure matrix was told to write an
  index-head line that the five-path closure commit may not write. The final
  head of a completed matrix now goes only to the scaffold's Pending slots.
- Five Concept sentences were not exactly true under their Technical rules, in
  ADRs 0041, 0043, 0044, 0046 and 0049.

A second recheck by two fresh readers then read only the sentences changed by
that pass. It found 3 blocking, 9 should-fix and 5 minor defects, all acted on.
The blocking three were the Concept's explicit-compact sentence overstating
rendering repair after a size trigger, the standalone clock failure still being
told to use an episode record it does not have, and `/status` being told to show
a summarizer origin its closed record cannot carry.

A third reader then checked only the sentences changed by that second pass. It
found 3 blocking and 2 minor defects. Two concerned a chat startup report this
review had introduced: it could not be written before the runtime that supplies
committed values, and its failed-write refusal had no Concept sentence. That
report is now a best-effort stderr diagnostic that never gates startup. The
third was an unscoped measurement sentence in ADR 0041. The lead applied these
five corrections and reread them in place; no reader has checked them. Blocking
counts across the passes were 22, 18, 3 and 3.
