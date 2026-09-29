# 0047. Reference host run defaults

<a id="concept"></a>
## Concept

Technical depth: [Values, measurement and evidence](0047-reference-host-run-defaults-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-29
- **Decision owner:** Maintainer
- **Supersedes:** nothing. No accepted decision fixes the numeric defaults
- **Prerequisite for:** M7 outcomes 6 and 8 (draft), accepted before the
  conversational command's defaults are written

<a id="concept-adr-0047-decision"></a>
### Context and Decision

Technical depth: [Values and measurement](0047-reference-host-run-defaults-technical.md#technical-adr-0047-decision).

Every run has declared bounds, and ADR 0010 requires that. The default
values exist only in code: 16 turns, 1,000,000 tokens, 10 minutes and a
4,096-token reply. They were sized for short workflow tests. A real coding
task often needs more than 16 model calls, and a file written in one tool
call can exceed 4,096 tokens. A question put to the operator also spends
the same 10 minutes while it waits.

**The decision.**

1. **Core's defaults do not change.** An embedding host that names no bounds
   gets today's values.
2. **The reference host sets its own defaults for coding work:**

   | Bound | One-shot `ask` | Conversational command |
   | --- | --- | --- |
   | Turns per run | 16, unchanged | 64 |
   | Deadline per run | 10 minutes, unchanged | 60 minutes |
   | Tokens per run | 1,000,000, unchanged | 4,000,000 |
   | Reply limit | 4,096, unchanged | 16,384 |

3. **Every bound stays declared and visible.** The command prints the
   bounds in effect when a run starts, and each has a flag.
4. **The values are provisional until measured.** The coding-task set
   records turns, tokens and time per task. The values above are confirmed
   or corrected from that record before closure.
5. **There is no unbounded mode.**

<a id="concept-adr-0047-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0047-reference-host-run-defaults-technical.md#technical-adr-0047-evidence).

A conversational run can work for up to an hour and spend up to four times
the tokens of a one-shot run before it stops with a named bound. Scripts
that call `ask` see no change.

<a id="concept-adr-0047-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility and rejected alternatives](0047-reference-host-run-defaults-technical.md#technical-adr-0047-compatibility).

Bounds are committed per run, so a change of defaults affects only runs
admitted after it. Restoring the old values is a change of four constants
in the reference host.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
