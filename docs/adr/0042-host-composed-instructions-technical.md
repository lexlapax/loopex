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

M7 uses fresh context-provider receipt revision 4. Revision 3 already belongs to
ADR 0025's resource-pack receipt. Retain ADR 0017's sixteen-key outer shape when
no resource header applies, and ADR 0025's seventeen-key shape, resource header,
`resource_pack` provenance bucket/source reference and validation when it does.
The existing applicability rule determines the shape; callers cannot select one
to avoid metadata costs. Retain six descriptor members, cost/digest recipes and
record-relative validation. Change `provider_revision` to 4 and extend the
closed source-reference union without removing either earlier union's variants.
Host instructions use exactly `{kind: "host_instructions", version, digest}`,
where version is the captured instruction identifier and digest is SHA-256 of
the exact rendered instruction bytes. Bind both to the owning request's frozen
configuration. The descriptor remains `system` /
`host_owned_trusted_brain_content`; its content digest/cost measures the full
canonical system message, not just its text. ADR 0043 uses the same variant for
captured maintenance instructions and adds its two conversation-source variants.
This changes no trust class or grant. Preserve old receipt revisions 2 and 3 and
their staged request validation; never relabel a legacy receipt as revision 4
on replay. New variants are not valid under either old revision.

The reference default lives in the CLI host; reusable composition accepts
explicit bytes or the fallback. Environment facts are captured at creation or
explicit configuration, not regenerated on replay. The configuration transaction
in ADR 0044 validates model, instructions, ceilings and immutable tool definitions
together. Prompt-file paths do not enter the instruction record. Workspace and
enabled role names are deliberate host environment facts below, never authority.
The reference host uses instruction version `loopex.reference.v1` for its
default, `loopex.explicit.v1` for an explicit base file and `loopex.role.v1` for
role instructions. Their bytes, not file names or timestamps, define the digest.
Its environment section is compact UTF-8 JSON with ASCII-sorted object keys,
no insignificant whitespace, escaped quotes/backslashes, the standard short
escapes for backspace/formfeed/LF/CR/tab, `\u00xx` for other controls, and
unescaped valid non-ASCII characters. This is a versioned host JSON renderer,
not the Erlang-term `LoopexProtocol.Canonical` encoding. Pin byte vectors.
Fields are `workspace` as the exact resolved root accepted by the local executor,
`platform` as `{os: darwin|linux|other, architecture: aarch64|x86_64|other}`
with string values, and `tool_profile` as the selected profile name. For a
helper-enabled parent include `enabled_roles` sorted by ASCII name plus
`catalog_digest` as `sha256:` followed by 64 lowercase hex digits. These are
captured host facts, not shell output.
The complete rendered section must fit 4 KiB, including escaping; oversize
refuses. No clock, ambient env values or credential references are included.
Explicit instruction reconfiguration refreshes mutable host facts while keeping
the immutable tool/catalog facts equal to the session binding.

Legacy fallback text and request revisions are handled explicitly in decoder
fixtures, without rewriting already staged requests.

<a id="technical-adr-0042-evidence"></a>
### Evidence

Concept: [Observable consequences](0042-host-composed-instructions.md#concept-adr-0042-consequences).

- Exact staging and digest change for a one-byte edit; no project/skill promotion.
- Unknown field, UTF-8, section and strict system-ceiling boundary negatives.
- One atomic model/instruction update; active-run refusal and restart retention.
- Legacy fallback test and immutable previously staged request vectors.
- Revision-4 instruction source binding and record-relative receipt validation;
  mismatched version/digest, unknown variants and relabelled legacy bytes refuse.
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
