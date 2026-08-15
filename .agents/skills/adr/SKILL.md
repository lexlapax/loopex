---
name: adr
description: "Prepare, revise, or record a governed Loopex architecture decision proposal. Use when a task raises a new decision about ownership, transactions, trust, public or cross-app contracts, persistent schema, dependencies or runtime floors, migration or rollback, packaging, normative budgets, or a vision boundary; do not use merely to log reversible implementation choices."
---

# Architecture Decision Records

Follow `AGENTS.md` authority and decision tiers first; read
`docs/plans/README.md` for canonical status, then use
`docs/developer/agent-context-map.md` for routing and version-specific technical
guidance. Read the development charter pair for Concept/Technical depth
ownership, anchors, reciprocal links, and review form.

1. Read the current task, constraining vision sections, accepted ADRs, and any
   accepted active plan. Classify the unresolved decision before writing.
2. Record a reversible internal choice in the nearest existing code, test,
   progress note, or subsystem document. Do not create an ADR for it.
3. For an ADR-class decision, use `## Concept` and then `## Technical depth` to
   present evidence, viable options, recommendation, decision owner,
   compatibility impact, and migration or rollback implications. Propose and
   pause before dependent implementation.
4. When the current task authorizes a proposal, create one pair:

   ```text
   docs/adr/NNNN-short-title.md
   docs/adr/NNNN-short-title-technical.md
   ```

   The Concept file starts with its `concept` anchor, one `## Concept`, and an
   immediate exact link to `#technical-depth`. It owns `Status: Proposed`, date,
   decision owner, purpose/context, decision, observable consequences,
   compatibility and rollback summary, and this empty governance record:

   ```markdown
   ## Governance Record

   | Decision | Authority | Authority evidence | Bound bytes |
   | --- | --- | --- | --- |
   | Acceptance | — | — | — |
   ```

   The Technical depth file starts with its `technical-depth` anchor, one
   `## Technical depth`, and an immediate exact backlink to `#concept`. It owns
   detailed evidence, invariants, schemas or commands, edge cases,
   implementation constraints, alternatives, compatibility mechanics, and
   migration/rollback mechanics. Every substantive section has exact reciprocal
   anchors. Neither file may introduce a decision absent from the other. Add the
   pair to `docs/README.md`. Keep Concept compact; add only depth the decision
   requires.
5. Never mark your own proposal `Accepted`. Record acceptance only when the
   maintainer or a previously recorded delegate explicitly accepts the exact ADR
   pair candidate. In one administrative transition, change only
   `Status: Proposed` to `Status: Accepted` and fill the Concept file's
   Acceptance row with `Maintainer` or
   `Delegate: <recorded identity>`, `[disposition](<durable-pointer>)`, and
   the exact candidate/concept-digest/technical-digest form defined in
   `docs/plans/README.md`. The digests bind both historical Proposed files. Do
   not change decision or technical bytes in that transition, and require
   independent exact-diff review before integration; the candidate commit must
   remain reachable from the integrated history. Within the pair, only Status
   and the empty row change; the same administrative commit updates the plans
   index's complete derived Current Status capsule when the ADR is a blocker.
6. A gate weakening, waiver, scope deferral, baseline exception, or vision
   reversal requires the exact approval named by `AGENTS.md`; an ADR cannot grant
   that authority.
