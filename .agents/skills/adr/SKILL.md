---
name: adr
description: "Prepare, revise, or record a governed Loopex architecture decision proposal. Use when a task raises a new decision about ownership, transactions, trust, public or cross-app contracts, persistent schema, dependencies or runtime floors, migration or rollback, packaging, normative budgets, or a vision boundary; do not use merely to log reversible implementation choices."
---

# Architecture Decision Records

Follow `AGENTS.md` authority and decision tiers first; read
`docs/plans/README.md` for canonical status, then use
`docs/developer/agent-context-map.md` for routing and version-specific technical
guidance.

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
   vision sections. Add this empty record after the metadata:

   ```markdown
   ## Governance Record

   | Decision | Authority | Authority evidence | Bound bytes |
   | --- | --- | --- | --- |
   | Acceptance | — | — | — |
   ```

   Keep the ADR to one page unless the decision requires more.
5. Never mark your own proposal `Accepted`. Record acceptance only when the
   maintainer or a previously recorded delegate explicitly accepts the exact ADR
   candidate. In one administrative transition, change only `Status: Proposed`
   to `Status: Accepted` and fill the Acceptance row with `Maintainer` or
   `Delegate: <recorded identity>`, `[disposition](<durable-pointer>)`, and
   the exact candidate/document-digest form defined in `docs/plans/README.md`.
   The digest binds the historical Proposed candidate bytes. Do not change the
   decision text in that transition, and require independent exact-diff review
   before integration; the candidate commit must remain reachable from the
   integrated history. Within the ADR, only Status and the empty row change;
   the same administrative commit updates the plans index's complete derived
   Current Status capsule when the ADR is a current blocker.
6. A gate weakening, waiver, scope deferral, baseline exception, or vision
   reversal requires the exact approval named by `AGENTS.md`; an ADR cannot grant
   that authority.
