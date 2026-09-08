# M2 Post-Closure Real-Call Attestations

The first three records, one per real-provider role, were retaken after the post-closure hotfix
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

<a id="source-4e514fb"></a>
## New-Source Checkpoint — 4e514fb

These additional observations ran serially at exact source
`4e514fb0680c48b7cec8b61024f9daada53ecabf` on 2026-09-08. They do not relabel
the earlier source's records. The task-only capture invoked the unchanged bound
`scripts/m1-exunit-runner.exs` directly with the gate's exact real-role profiles,
locked names, minima and named exclusions, seed 3107, after clean-source
formatting and forced product compilation. The complete M2 gate did **not**
produce these records; its earlier exact-R run failed before the demonstration.

Provider `anthropic`, model `claude-haiku-4-5-20251001`, endpoint
`https://api.anthropic.com`, adapter build `loopex_llm_reqllm@0.0.0`; current
Darwin Elixir 1.20.3 / OTP 29.0.5, isolated roots, actual account HOME, four
normal schedulers and two each of dirty CPU/IO schedulers. Provider secrets
entered only the runner's bounded private stdin frame from the authorized
environment file, never an argument or exported startup value. The collector
checked the actual credential literal against all captured role output before
writing it. No credential was found.

| Role / case | UTC lane window | Calls | Reported input tokens | Reported output tokens | Result |
| --- | --- | --- | --- | --- | --- |
| Db: separate response-identifier check | 08:43:17–08:43:53 | 1 | 15 | 4 | Passed |
| Db: coding task | Same Db lane window | 7 | 10310 | 572 | Passed |
| inherited 5c: model session | 08:43:56–08:44:08 | 2 | 1463 | 112 | Passed |
| inherited 8b: recovery trace | 08:44:11–08:44:26 | 2 | 1463 | 112 | Passed |

Db executed two cases and excluded exactly its five deterministic cases; 5c
executed one and excluded exactly its deterministic case; 8b executed one
and excluded exactly its five deterministic cases. These are gate-selected
real roles, not an ordinary suite excluding its required live cases. Db's
one-call identifier check and seven-call task are separate attestation lines
with the same role label; they are not combined into an eight-turn task.

The coding task observed seven turns, six tool calls, four effects, two policy
denials, all four shipped coding tools, and the expected committed file result.
The fixture composes a real same-source companion through explicit host
configuration. Paired-package wiring and artifact hashes remain separate
evidence; this capture does not label a release binary.

| Observation | Provider-supplied identifiers, in reported order |
| --- | --- |
| Db identifier check | `req_011CeqgCA5ssm8udRpTkaXy1` |
| Db coding task | `req_011CeqgCkfkLM37NXWmau3r7`, `req_011CeqgCxpjopwg63yAqxV4E`, `req_011CeqgDCbDSLyXhVdrtJ9AX`, `req_011CeqgDRnU8aCPVxV1ovTUy`, `req_011CeqgDeuWGbUijXMqcEJPa`, `req_011CeqgDsXH2kDPPpAVje3Fe`, `req_011CeqgE5uuuF9Gy8PsDN1zs` |
| inherited 5c | `req_011CeqgEyp5RTXHoctjphqrd`, `req_011CeqgFCvce3L7fLESjiixk` |
| inherited 8b | `req_011CeqgGAhhZKZMyjvXrv1Rk`, `req_011CeqgGVaFi4NLT7QBzJsBL` |

The totals are twelve calls, 13251 reported input tokens and 800 reported
output tokens. They are adapter-reported aggregates, not account-verified
per-call usage or a billing statement. The times are lane start/end windows,
including fixture work, not individual request timestamps. Cache accounting
and per-call timing must be compared with the provider account separately.

Retained role-log SHA-256:

- Db: `929882eea0b7bce6d20329bd446ba9b5bdfa09e31dfca884046b20af29c401b6`.
- 5c: `262166830f1b94fef9b0048ab8cfc0aba356ddc3e5d0492b14cb7b392324c288`.
- 8b: `89a64b01d70d47fb954674f5394cc891663a5fe47e706a5b14914203f6e0ddcd`.
- Task-only capture driver: `07796fcdd2307509d02ef4d4302555c19e589069cd47de4eeb7d837f62c4c528`.

Raw role logs, exit/window records, compile/format logs, the capture driver
and the distinct unresolved-gate diagnostics are preserved in the maintainer's
`loopex-reviews/M2-4e514fb-checkpoint-2026-09-08.Fz1rL0` archive. All 21 manifest
entries were verified after copying. This is a partial archive, not an accepted
release-evidence bundle.

**Account verification: not performed for these twelve identifiers.** The
authenticated Chrome surface is unavailable while the Mac is locked; automatic
unlock failed. No earlier account row, identifier syntax, test assertion or
successful runner result fills that gap. Required final account confirmation
and the unresolved complete-gate result remain outstanding.

<a id="source-4e514fb-account-verification"></a>
## Provider-Account Verification — 2026-09-08

The earlier account-unavailable status above describes the capture checkpoint.
On 2026-09-08, the authenticated Claude Platform Logs page at
`https://platform.claude.com/workspaces/default/logs` was refreshed and inspected
read-only through Chrome. The page reported its refresh at 03:27 PDT. All twelve
identifiers for source `4e514fb0680c48b7cec8b61024f9daada53ecabf` were found in the
account, each with model `claude-haiku-4-5-20251001`, type Streaming and service
tier Standard. No identifier was inferred from its spelling or from another
source's test output.

The table displays relative time. Its actual rendered `time` elements carry
absolute `datetime` attributes; those were read through Chrome's Elements
inspector, with each time associated with the identifier in the same table row.
No page code, requests, credentials or account settings were changed. Every
input-token breakdown was opened: cache reads and both five-minute and one-hour
cache writes were zero for each of these twelve requests.

| Role | Account request identifier | Account UTC timestamp, 2026-09-08 | Input tokens | Output tokens |
| --- | --- | --- | --- | --- |
| Db identifier check | `req_011CeqgCA5ssm8udRpTkaXy1` | 08:43:26.883 | 15 | 4 |
| Db coding task | `req_011CeqgCkfkLM37NXWmau3r7` | 08:43:35.429 | 1128 | 79 |
| Db coding task | `req_011CeqgCxpjopwg63yAqxV4E` | 08:43:38.626 | 1224 | 121 |
| Db coding task | `req_011CeqgDCbDSLyXhVdrtJ9AX` | 08:43:41.679 | 1366 | 98 |
| Db coding task | `req_011CeqgDRnU8aCPVxV1ovTUy` | 08:43:44.765 | 1485 | 77 |
| Db coding task | `req_011CeqgDeuWGbUijXMqcEJPa` | 08:43:47.806 | 1588 | 96 |
| Db coding task | `req_011CeqgDsXH2kDPPpAVje3Fe` | 08:43:50.578 | 1710 | 84 |
| Db coding task | `req_011CeqgE5uuuF9Gy8PsDN1zs` | 08:43:53.149 | 1809 | 17 |
| inherited 5c | `req_011CeqgEyp5RTXHoctjphqrd` | 08:44:05.773 | 680 | 87 |
| inherited 5c | `req_011CeqgFCvce3L7fLESjiixk` | 08:44:08.401 | 783 | 25 |
| inherited 8b | `req_011CeqgGAhhZKZMyjvXrv1Rk` | 08:44:21.829 | 680 | 87 |
| inherited 8b | `req_011CeqgGVaFi4NLT7QBzJsBL` | 08:44:25.850 | 783 | 25 |

Every timestamp is within its role's retained lane window at that window's
one-second precision. In particular, the recorded end seconds `08:43:53` and
`08:44:08` include their fractional second; they were not millisecond-precision
cutoffs at `.000`. The provider timestamps are not reinterpreted as dispatch
instants or inferred from table ordering.

The per-role sums match the captured adapter reports exactly: Db identifier
15/4, Db coding task 10310/572, inherited 5c 1463/112, inherited 8b 1463/112;
total 13251 input and 800 output tokens across twelve calls. Account existence,
model, time-window and token-accounting verification for this checkpoint is
complete. This is not a billing audit, a new live run at a later SHA, a passing
complete M2 gate, or an acceptance of the final release candidate. The original
unexplained Outcome 4 gate failure remains independently outstanding.

## Related

- [M2 real-call attestations](M2-real-call-attestations.md) (the closure records, frozen)
- [M2 recorded limitations](M2-recorded-limitations.md#second-audit-hotfix) (the disposition that required this retake)
- [Evidence index](README.md)
