---
name: adr
description: "Prepare, revise, or record a governed Loopex architecture decision proposal. Use when a task raises a new decision about ownership, transactions, trust, public or cross-app contracts, persistent schema, dependencies or runtime floors, migration or rollback, packaging, normative budgets, or a vision boundary; do not use merely to log reversible implementation choices."
---

# Architecture Decision Records

Follow `AGENTS.md` authority and decision tiers first; route additional
context, including current stage guidance, via
`docs/developer/agent-context-map.md`.

1. Read the current task, constraining vision sections, accepted ADRs, and any
   accepted active plan. Classify the unresolved decision before writing.
2. Record a reversible internal choice in the nearest existing code, test,
   progress note, or subsystem document. Do not create an ADR for it.
3. For an ADR-class decision, present the evidence, viable options,
   recommendation, decision owner, compatibility impact, and migration or
   rollback implications. Propose and pause before dependent implementation.
4. When the current task authorizes a proposal file, create the next
   `docs/adr/NNNN-short-title.md` with `Status: Proposed`, date, decision owner,
   context, decision, alternatives and evidence, consequences including what
   becomes harder, compatibility, migration/rollback, and links to constraining
   vision sections. Keep it to one page unless the decision requires more.
5. Never mark your own proposal `Accepted`. Record acceptance only when the
   maintainer or a previously recorded delegate explicitly accepts the exact ADR
   bytes or digest; retain that authority pointer and do not change the decision
   text in the same edit.
6. A gate weakening, waiver, scope deferral, baseline exception, or vision
   reversal requires the exact approval named by `AGENTS.md`; an ADR cannot grant
   that authority.
