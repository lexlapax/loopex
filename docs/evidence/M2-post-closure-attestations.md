# M2 Post-Closure Real-Call Attestations

Three records, one per real-provider role, retaken after the post-closure hotfix
sets on `main` at candidate `34069a0a147e4480b4049710aee0cefbbb7be39c`, with Mint at `1.10.0` (the two
published HTTP/1 advisories in 1.9.3 are fixed there). This record exists
because the third independent audit required the real-provider evidence to be
retaken on the current candidate: the attestations the milestone closed with,
`M2-real-call-attestations.md`, bind `f17beef1` and are byte-frozen by the
gate's evidence lifecycle, so they stay as they were and this file sits beside
them.

What it is worth is exactly what that file says of itself: the identifiers have
the form the provider documents, none is reused, the counts and totals agree
with the lines each role printed, and every field was produced inside the same
test process that made the calls. It does not prove a socket was opened. The
load-bearing half is the account lookup below.

## Records

Each line is the record the role's own attestation output produced, with the
candidate and the run's start instant added. Floors are the ones the roles
claim: at least four calls for the demonstration, one for the model session,
two for the recovery trace.

<!-- loopex:m2-post-closure-attestations:start -->
```json
{"role":"demonstration_db","selector":"apps/loopex_cli/test/coding_task_test.exs","provider":"anthropic","model":"claude-haiku-4-5-20251001","endpoint":"https://api.anthropic.com","adapter_build":"loopex_llm_reqllm@0.0.0","calls":8,"response_id_form":"req_:16-64","provider_response_ids":"req_011CejKrYmDvMC1oCShGon9z+req_011CejKrd8f9usTk9dgCTvQL+req_011CejKri83a4s8DfMK1piR1+req_011CejKrpciP84GaAduSVxtA+req_011CejKrurVQRvC2SPMYDs2r+req_011CejKrzLrogME21Kiegaco+req_011CejKs6rmnh4kDPP3BkpLm+req_011CejKsBybdtYv6BWpq1UZx","input_tokens":10189,"output_tokens":539,"candidate":"34069a0a147e4480b4049710aee0cefbbb7be39c","recorded":"2026-09-05T00:13:07Z"}
```

```json
{"role":"inherited_5c","selector":"apps/loopex_reference_client/test/real_model_session_test.exs","provider":"anthropic","model":"claude-haiku-4-5-20251001","endpoint":"https://api.anthropic.com","adapter_build":"loopex_llm_reqllm@0.0.0","calls":2,"response_id_form":"req_:16-64","provider_response_ids":"req_011CejKsQpGeeKmefen9W2o6+req_011CejKsV6FHpZVBMP8F6X5Q","input_tokens":1463,"output_tokens":112,"candidate":"34069a0a147e4480b4049710aee0cefbbb7be39c","recorded":"2026-09-05T00:13:07Z"}
```

```json
{"role":"inherited_8b","selector":"apps/loopex_reference_client/test/end_to_end_recovery_test.exs","provider":"anthropic","model":"claude-haiku-4-5-20251001","endpoint":"https://api.anthropic.com","adapter_build":"loopex_llm_reqllm@0.0.0","calls":2,"response_id_form":"req_:16-64","provider_response_ids":"req_011CejKsoV2jWzSufkCoRyBC+req_011CejKt3pExsJEcPpPr2P1R","input_tokens":1463,"output_tokens":113,"candidate":"34069a0a147e4480b4049710aee0cefbbb7be39c","recorded":"2026-09-05T00:13:07Z"}
```
<!-- loopex:m2-post-closure-attestations:end -->

Total real calls across the three roles: 12. Run window opened
`2026-09-05T00:13:07Z` (UTC).

## Provider-account verification

Not yet performed.

## Related

- [M2 real-call attestations](M2-real-call-attestations.md) (the closure records, frozen)
- [M2 recorded limitations](M2-recorded-limitations.md#second-audit-hotfix) (the disposition that required this retake)
- [Evidence index](README.md)
