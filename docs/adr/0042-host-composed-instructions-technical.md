<a id="technical-depth"></a>
## Technical depth

Concept: [Host-composed instructions](0042-host-composed-instructions.md#concept).

<a id="technical-adr-0042-decision"></a>
### Contract

Concept: [Context and decision](0042-host-composed-instructions.md#concept-adr-0042-decision).

Creation and atomic `configure` accept an `instructions` map with exactly:

| Member | Bound |
| --- | --- |
| `version` | Nonempty ASCII identifier, at most 64 bytes |
| `base` | Nonempty UTF-8, at most 32 KiB |
| `environment` | UTF-8, at most 4 KiB, empty allowed |
| `appendix` | UTF-8, at most 16 KiB, empty allowed |

Stage `version + ": " + sections joined by one blank line`, omitting empty
sections. Core does no templating. Retain bytes/digest in configuration and
record the version/digest in the context receipt. Unknown fields, oversize
sections and a projected system class at or above the selected ceiling refuse
creation/configure before its mutation commits. Count actual model-facing tool
definitions in the system class. The ceiling defaults to 1,000 for legacy
callers; an explicit positive host value cannot exceed the input context budget.
The full model-request record still must fit ADR 0017's byte bound.

The reference default lives in the CLI host; reusable composition accepts
explicit bytes or the fallback. Environment facts are captured at creation or
explicit configuration, not regenerated on replay. The configuration transaction
in ADR 0044 validates model, instructions, ceilings and immutable tool definitions
together. File paths and role aliases do not enter the instruction record.
Legacy fallback text and request revisions are handled explicitly in decoder
fixtures, without rewriting already staged requests.

<a id="technical-adr-0042-evidence"></a>
### Evidence

Concept: [Observable consequences](0042-host-composed-instructions.md#concept-adr-0042-consequences).

- Exact staging and digest change for a one-byte edit; no project/skill promotion.
- Unknown field, UTF-8, section and strict system-ceiling boundary negatives.
- One atomic model/instruction update; active-run refusal and restart retention.
- Legacy fallback test and immutable previously staged request vectors.
- Retain measurements for the default and each demonstrated opt-in tool set;
  no silent ceiling increase to fit helper/question definitions.
- Real coding task follows host instructions with separately admitted resources.

<a id="technical-adr-0042-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0042-host-composed-instructions.md#concept-adr-0042-compatibility).

Keep the fallback solely for compatibility. Per-model prompt selection,
project discovery and templating stay out of core. Raising the host ceiling
changes a declared configuration, not the stored-request byte bound. M7 adds
no new resource-admission authority.
