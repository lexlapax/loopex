# M2 Real-Call Attestations

Three records, one per real-provider role, each naming every provider response
the role observed and the provider's own reported token totals across exactly
those responses.

M1's selector runner is a bound artifact at the bytes M1 closed with. It seals a
fixed real-path field set and refuses any report whose key set differs, so no
attestation field can be added to that channel without reopening an immutable
artifact. This record therefore lives beside that sealed report, and M2's gate
runner validates it.

**What this record is worth, stated before the records themselves.** The runner
checks internal consistency: that every identifier has the shape its own record
declares, that no identifier is reused within or across records, that the count
and the reported totals agree, that the sealed identity matches what the bound
runner sealed in the same run, and that the candidate is reachable. It does not
prove that any network call happened, and no offline check can — every field
here was produced inside the same test process that produced the sealed
identity, so a case that fabricated a well-formed identifier, a plausible usage
pair, and the form it declares for them would pass all of it.

The load-bearing half is review. Closure review looks each retained identifier
up in the provider account, confirms it exists in the window `recorded` names,
and confirms the reported usage matches the billed call. That is the only step
in this gate that reaches the provider, and the only one that distinguishes a
real call from a well-formed fabrication. What the mechanism achieves is that
fabrication now has to survive an external lookup rather than only a reading of
prose.

## Record order and floors

| # | Role | Selector | Minimum real calls |
| --- | --- | --- | --- |
| 1 | `demonstration_db` | `apps/loopex_cli/test/coding_task_test.exs` | 4 |
| 2 | `inherited_5c` | `apps/loopex_reference_client/test/real_model_session_test.exs` | 1 |
| 3 | `inherited_8b` | `apps/loopex_reference_client/test/end_to_end_recovery_test.exs` | 2 |

The floors are the ones each role's own locked cases already claim: the attended
demonstration completes at least three turns and then makes its attestation
call, and the inherited recovery trace explicitly completes a second real call.

All three records must declare the same `response_id_form` byte for byte and the
same `provider`, `model`, `endpoint`, and `adapter_build` as the bound selector
runner sealed, because all three must already agree on the provider that runner
sealed. Anthropic's documented identifier form is written `msg_:16-64`.

## Records

<!-- loopex:m2-attestations:start -->
```json
{"role":"demonstration_db","selector":"apps/loopex_cli/test/coding_task_test.exs","provider":"","model":"","endpoint":"","adapter_build":"","calls":0,"response_id_form":"","provider_response_ids":"","input_tokens":0,"output_tokens":0,"candidate":"","recorded":""}
```

```json
{"role":"inherited_5c","selector":"apps/loopex_reference_client/test/real_model_session_test.exs","provider":"","model":"","endpoint":"","adapter_build":"","calls":0,"response_id_form":"","provider_response_ids":"","input_tokens":0,"output_tokens":0,"candidate":"","recorded":""}
```

```json
{"role":"inherited_8b","selector":"apps/loopex_reference_client/test/end_to_end_recovery_test.exs","provider":"","model":"","endpoint":"","adapter_build":"","calls":0,"response_id_form":"","provider_response_ids":"","input_tokens":0,"output_tokens":0,"candidate":"","recorded":""}
```
<!-- loopex:m2-attestations:end -->

The three records above carry their locked role and selector and no observed
values. They are populated by the attended gate run that produces the closure
candidate, from the identifiers that run emitted, and this revision is the
implementation candidate rather than the closure candidate. Writing identifiers
here from an earlier run would produce a record that describes a run the
candidate did not make — which the runner cannot detect, and which is exactly
why it is not done.

Each locked role emits its observed identifiers on the diagnostic stream as it
runs, in the form

```text
loopex attestation <role>: calls=<n> ids=<id>+<id>… input_tokens=<n> output_tokens=<n>
```

so an attended run hands them over directly. No case writes this file: a case
that wrote its own evidence would be attesting to itself.

## Related

- [Coding demonstration](M2-coding-demonstration.md) — the attended demonstration these identifiers come from.
- [Toolchain matrix](M2-toolchain-matrix.md) — the sealed identity all three roles must agree on.
- [Evidence index](README.md).
