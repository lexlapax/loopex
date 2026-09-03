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
sealed.

**The retained identifier is the per-call request identifier, `req_:16-64`, not
the assembled message identifier.** The shipped adapter streams, and a streamed
call cannot carry the message identifier: the client library keeps only usage
from the provider's opening event and discards the rest. What survives is the
`request-id` header the provider returns for every call, which is the identifier
its own account and support surface use — so it is the one an auditor looks a
retained claim up by, and it is what these records declare. The gate names
`msg_:16-64` as an example of a documented form and carries no provider
allowlist; the record declares the form its own run produced, which is what the
runner validates against.

## Records

<!-- loopex:m2-attestations:start -->
```json
{"role":"demonstration_db","selector":"apps/loopex_cli/test/coding_task_test.exs","provider":"anthropic","model":"claude-haiku-4-5-20251001","endpoint":"https://api.anthropic.com","adapter_build":"loopex_llm_reqllm@0.0.0","calls":8,"response_id_form":"req_:16-64","provider_response_ids":"req_011CegojiTgkSsL46QN3SUVF+req_011CegojomvCW9DZMRujAxX1+req_011Cegojvi8kQTKfnyvyW2Hh+req_011Cegok2XP2ecJiA5YUywDX+req_011Cegok7qcoL5deWYe2zdYg+req_011CegokFLKCcGVLwevMs3pH+req_011CegokLbpQvVXvVW35obbb+req_011CegokQA8dCgSUsCYart5L","input_tokens":10394,"output_tokens":603,"candidate":"f17beef1b62116fa411b3fa496f3e8964b3af81c","recorded":"2026-09-03T16:19:29Z"}
```

```json
{"role":"inherited_5c","selector":"apps/loopex_reference_client/test/real_model_session_test.exs","provider":"anthropic","model":"claude-haiku-4-5-20251001","endpoint":"https://api.anthropic.com","adapter_build":"loopex_llm_reqllm@0.0.0","calls":2,"response_id_form":"req_:16-64","provider_response_ids":"req_011CegomZN3v6ZrEQCTb1Rh5+req_011CegomfZN7pesDN2g2X6yj","input_tokens":1475,"output_tokens":124,"candidate":"f17beef1b62116fa411b3fa496f3e8964b3af81c","recorded":"2026-09-03T16:19:29Z"}
```

```json
{"role":"inherited_8b","selector":"apps/loopex_reference_client/test/end_to_end_recovery_test.exs","provider":"anthropic","model":"claude-haiku-4-5-20251001","endpoint":"https://api.anthropic.com","adapter_build":"loopex_llm_reqllm@0.0.0","calls":2,"response_id_form":"req_:16-64","provider_response_ids":"req_011CegomuqbvhJNkrbazZSj1+req_011Cegon8HToG7UrSnXk9bXk","input_tokens":1463,"output_tokens":112,"candidate":"f17beef1b62116fa411b3fa496f3e8964b3af81c","recorded":"2026-09-03T16:19:29Z"}
```
<!-- loopex:m2-attestations:end -->

Each record above carries the identifiers its role actually observed, at the
candidate it names, in runs made for this record and not copied from an earlier
one. `demonstration_db` carries eight because that role is two cases: the
attended coding task, which took seven turns, and the single attestation call
beside it; the retained observation line in the demonstration record and the
audit below both count the same eight. The task's own count is what the demonstration record reports; this
record counts the role, so the two numbers differ by design and neither is the
other's correction. The identifiers appear grouped by case rather than in the
order the two cases happened to be scheduled, which the seed decides.

Each locked role emits its observed identifiers on the diagnostic stream as it
runs, in the form

```text
loopex attestation <role>: calls=<n> ids=<id>+<id>… input_tokens=<n> output_tokens=<n>
```

so an attended run hands them over directly. No case writes this file: a case
that wrote its own evidence would be attesting to itself.

## Provider-account audit

Audited on 2026-09-03 at 09:18 PDT against the authenticated Claude Platform
Logs page for the workspace that owns the credential. All twelve identifiers
retained above were present across the first two pages, each on model
`claude-haiku-4-5-20251001`, type Streaming, service tier Standard, recorded
one to two minutes before the audit. Per-call usage in the account sums to
each record's own totals: the attended demonstration's eight calls to 10,394
input and 603 output tokens, `inherited_5c`'s two calls to 1,475 and 124, and
`inherited_8b`'s two calls to 1,463 and 112. The two inherited roles run the
same fixture prompt; their totals differ this time because the model's replies
differed, and each matches its own two calls.

## Related

- [Coding demonstration](M2-coding-demonstration.md) — the attended demonstration these identifiers come from.
- [Toolchain matrix](M2-toolchain-matrix.md) — the sealed identity all three roles must agree on.
- [Evidence index](README.md).
