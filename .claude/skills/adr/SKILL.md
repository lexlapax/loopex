---
name: adr
description: Record an architecture decision as a one-page ADR (act-and-record tier).
---

Create `docs/adr/NNNN-short-title.md` (next free number) with sections:
Status (Proposed/Accepted, date) · Context (≤8 lines) · Decision (what, not
how) · Consequences (incl. what becomes harder) · Compatibility (affected
public surfaces; "none" is a claim, verify it). One page maximum. Link the
constraining vision section. If the decision would weaken a gate, invariant,
budget, or vision boundary, it is stop-and-ask — do not write it as an ADR;
present options to the maintainer instead.
