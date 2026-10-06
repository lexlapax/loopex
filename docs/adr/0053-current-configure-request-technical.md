<a id="technical-depth"></a>
## Technical depth

Concept: [Current configure request](0053-current-configure-request.md#concept).

<a id="technical-adr-0053-decision"></a>
### Exact fields and domains

Concept: [Purpose and proposed decision](0053-current-configure-request.md#concept-adr-0053-decision).

The foreground request is exactly:

```text
{request_id, method: "session.configure", command_id, changes}
```

The daemon request is exactly:

```text
{request_id, method: "session.configure", command_id, changes, writer_epoch}
```

There are no optional envelope members. Existing request correlation and scalar
rules apply: request_id is 1–64 ASCII bytes matching `[A-Za-z0-9._~-]+`;
command_id is an opaque 1–65,536-byte identity in unpadded base64url. Daemon
writer_epoch keeps its existing opaque 1–64-byte unpadded base64url identity,
not a quantity. Duplicate JSON keys refuse before map conversion. Existing
frame, nesting, string and collection limits remain unchanged. No session_id,
metadata, bounds or second update spelling is admitted.

`changes` is a nonempty JSON object with only these six optional members:

| Member | Exact input domain |
| --- | --- |
| `model` | Nonempty valid UTF-8 text, including host-admitted aliases; retain authored bytes without trimming or canonical-model substitution. Existing transport and bounded native-data limits apply; no new model-name ceiling is added. |
| `reasoning` | One of `default`, `none`, `low`, `medium`, `high`; the resolved candidate must support the selected level. |
| `instructions` | The raw four-member object below. |
| `max_tokens` | Canonical positive uint64 decimal string. |
| `context_token_budget` | Canonical positive uint64 decimal string. |
| `system_class_tokens` | Canonical positive uint64 decimal string. |

Each quantity matches `[1-9][0-9]*` and is at most
`18446744073709551615`. JSON numbers, zero, null, empty strings, signs,
whitespace, leading zeros, decimal points, exponents, non-ASCII digits and
overflow refuse. Decode directly to an exact native integer before native
validation; never round through a floating-point number.

Raw instructions require exactly:

| Member | Exact input domain |
| --- | --- |
| `version` | 1–64 ASCII bytes matching `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`. |
| `base` | 1–32,768 valid UTF-8 bytes. |
| `environment` | 0–4,096 valid UTF-8 bytes. |
| `appendix` | 0–16,384 valid UTF-8 bytes. |

Bounds count decoded UTF-8 bytes, not JSON escape spelling or character count.
The decoder calls existing pure `Instructions.capture/1`, which preserves all
four authored sections and adds only their deterministic rendered digest.
Caller-supplied digest, capabilities, provider mapping, configuration version,
budget origins, tool selection, maintenance settings and other unknown fields
refuse. Native whole-change and complete-candidate bounds still apply; passing
an individual field ceiling does not prove the complete command fits.

<a id="technical-adr-0053-admission"></a>
### Existing admission semantics

Concept: [Authority, preparation and command identity](0053-current-configure-request.md#concept-adr-0053-admission).

The existing attachment selects the session. Check foreground mutation authority
or daemon current writer/controller authority before invoking Core. Configure
joins the daemon's existing mutation, relay, queue and succession-capacity
inventories; parser acceptance cannot bypass those owners.

Follow [ADR 0044's whole-candidate contract](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision)
and [ADR 0050's preparation order](0050-host-configuration-preparation-technical.md#technical-preparation).
Retained disposition/unknown fencing and settledness precede host resolution.
Omitted mutable members remain omissions in authored changes; merge and derived
budget rules use committed state. Validate model, reasoning, instructions,
context/reply/system ceilings and retained-history preflight together. Configure
performs no compaction or provider/executor dispatch. Missing preparation
capability or required admitted route inventory retains the existing refusal.
The already accepted externally prepared facade remains separate from wire
input. The 60,000-ms preparation cutoff and retained cleanup bounds do not change.

Pure instruction capture and exact quantity decoding precede native command
normalization. The existing command digest binds those normalized authored
changes, not the host-resolved canonical model. Preserve
[ADR 0050's alias and replay rules](0050-host-configuration-preparation-technical.md#technical-alias-identity):
identical retries return their original fact before catalog access; alias and
canonical spelling differ under one command ID; an omitted model cannot
retarget it. Unknown admission never reconstructs or re-resolves a candidate.
Admission, refusal and unknown remain distinct from committed configuration
output. Raw instructions and private host resolution facts remain excluded from
that output's existing allowlist.

<a id="technical-adr-0053-impact"></a>
### Implementation and verification

Concept: [Alternatives, compatibility and proof](0053-current-configure-request.md#concept-adr-0053-impact).

Current source evidence at `68f2ac12e86a4a24567dd4bc67a12e77d5055f41`:

- `SessionConfiguration.validate_update/1`, lines 104–117, closes the six mutable
  fields; `positive?/1` and `text?/1`, lines 483–486, fix native quantities and
  model text. Its bounded-data check and whole candidate validation still apply.
- `Instructions.capture/1` and `valid_sections?/1`, lines 36–46 and 94–105,
  fix raw keys, byte bounds, version alphabet and pure digest capture.
- Foreground `Mapping.capture_configuration_changes/1`, lines 54–80, and daemon
  `Request.capture_configuration_changes/1`, lines 101–127, capture already
  decoded settings; they do not implement configure request quantity decoding.
- `Wire.identity/2` and `u64/1` provide existing scalar encodings. Daemon
  `Request.writer_epoch/1` uses the existing 64-byte opaque identity limit.
- The [M7 technical plan](../plans/M7-technical.md#technical-plan-prerequisites)
  requires configure correlation and controller authority. ADR 0044 and 0050
  settle mutable semantics and preparation but leave the request member open.

The source gap was retained in
`/private/tmp/loopex-m7-current-wire-field-gap-4ee52100-20261006-v1/report.md`,
SHA-256 `e29e219513fbe85cef49a398b37076fb0bbe754d177832134640cdd3eba58cef`.
It is evidence of the gap, not acceptance.

Implement the chosen `changes` grammar in both ingress paths and the complete
foreground generation 3/daemon generation 4 request definitions, then update
independent Node clients and their full manifest pins together. A decoder or
standalone schema alone does not activate either generation. Remove any
superseded request spelling/decoder; retain no dual service or older-client
fallback. The alternative `configuration` requires only a different outer key
and translation into native changes, with the same domains and admission.
This proposal introduces no native/private record, migration or cross-version
rollback; current-format restart and exact command replay remain mandatory.

Required vectors include every nonempty mutable subset, exact positive uint64
limits and overflow, all malformed quantity forms, unknown and missing fields,
duplicate keys, Unicode byte ceilings, empty optional instruction sections,
caller-supplied digest/private facts and opaque command/writer identities.
Real foreground and daemon workflows must prove authority, unchanged refusal,
central alias preparation, settledness, same-ID replay/conflict, unknown
admission without another resolver call, current recovery and preparation
cleanup on both supported toolchain pairs. Independent consumers verify the
complete negotiated manifest before session mutations. Existing required wire
and milestone checks remain; this docs-only proposal runs none of them.
