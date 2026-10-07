<a id="technical-depth"></a>
## Technical depth

Concept: [Attempts event bodies](0057-attempts-event-bodies.md#concept).

<a id="technical-adr-0057-purpose"></a>
### Existing facts and remaining work

Concept: [Purpose and boundary](0057-attempts-event-bodies.md#concept-adr-0057-purpose).

At saved source `6e75c72ae0009e8d50f40cd73de5558cfd495b20`, the private
`Mix.Tasks.Loopex.M7Evidence.AttemptFrames` and `AttemptHeads` helpers implement
canonical framing, full-chain verification and exact greatest committed-head
selection. Their source matches primary at `d2b2298ca94779859a31870ccdf9222c77b0aef9`.
They open no files, interpret no event union and grant no dispatch authority.
Their existing complete frame/head test population is 21.

The accepted [M7 evidence procedure](../plans/M7-technical.md#technical-plan-evidence)
requires literal body shapes and vectors. The historical proposal digest
`b00591ffb23df421a83b7e76f4ed6a352273ff561ee4ed80660a54537463e0fe`
is retained in the [implementation ledger](../evidence/M7-implementation-tasks.md).
That entry records eleven checked examples, explicitly without grammar
acceptance. Its packet bytes were not available when preparing this proposal;
the following recipe is a new reviewable candidate, not a claimed reproduction
of that packet or its hashes.

<a id="technical-adr-0057-records"></a>
### Literal schemas and relations

Concept: [Proposed records and consequences](0057-attempts-event-bodies.md#concept-adr-0057-records).

#### Canonical bytes and domains

Preserve the existing envelope exactly:

```text
{version:1, campaign_id:B, sequence:P, previous_digest:H|null, body:Event, digest:H}
```

Each UTF-8 JSON object has recursively sorted keys and the existing compact
JSON encoding, followed by exactly one LF. Its length before LF is at most
65,536 bytes. SHA-256 covers the exact canonical encoding of the other five
members, without LF. Duplicate members, unknown members, floats, implementation
terms, invalid UTF-8, noncanonical JSON and malformed complete records refuse.
The existing incomplete-tail result remains unresolved. Body validation does
not recover or truncate it.

Domains below apply after duplicate-aware decoding. Sizes count UTF-8 bytes,
not characters. The whole-record cap applies in addition to each local cap.

| Symbol | Exact domain |
| --- | --- |
| `B` | Nonempty UTF-8 string, 1–256 bytes, excluding ASCII control bytes 0–31 and 127. Identifiers remain opaque; they grant no authority. |
| `H` | Exactly 64 lower-case hexadecimal characters: SHA-256. |
| `G` | Exactly 40 lower-case hexadecimal characters: a current repository Git commit identity. |
| `P` | Positive exact JSON integer. Envelope sequence and head sequence keep the existing positive-integer domain; encoded bytes remain bounded by the record cap. |
| `E` | Positive exact JSON integer in 1–18,446,744,073,709,551,615: ownership epoch. No floating-point conversion. |
| `R` | Closed reference object `{reference:Reference, sha256:H}`. No embedded content or arbitrary metadata. |
| `Head` | Closed `{campaign_id:B, sequence:P, digest:H}` object. Sequence is also the count of records in the complete preceding prefix. |

`Reference` is one of two exact string forms, at most 4,096 UTF-8 bytes and
without ASCII control bytes:

- An absolute POSIX file path beginning with `/`, with nonempty segments,
  no `.` or `..` segment and no trailing `/`. The later evidence owner verifies
  that it is a retained file outside repository/workspaces; the codec performs
  no filesystem access or path expansion.
- `git:<G>:docs/<path>` with optional `#<anchor>`. The path has nonempty ASCII
  segments containing only letters, digits, `.`, `_` and `-`, ending in `.md`,
  and no `.` or `..` segment. The optional anchor contains lower-case ASCII
  letters, digits and `-` and is nonempty. Later admission reads that exact
  Git revision and checks the content digest and named authority.

All maps below are closed. Every listed member is required, including nullable
members. `version` is integer 1. Other versions and aliases refuse.

#### Genesis and ownership variants

| `kind` | Exact additional members beyond `kind` and `version` |
| --- | --- |
| `genesis` | `campaign_id:B, codec_version:1` |
| `writer_designated` | `writer_id:B, host_id:B, ownership_epoch:1` |
| `writer_relinquished` | `writer_id:B, host_id:B, ownership_epoch:E, destination_writer_id:B, destination_host_id:B, handoff_id:B, preceding_head:Head, quiescence:R` |
| `writer_accepted` | `writer_id:B, host_id:B, ownership_epoch:E, source_writer_id:B, source_host_id:B, source_ownership_epoch:E, handoff_id:B, relinquishment_head:Head, quiescence:R, source_revocation:R, transfer:R` |
| `campaign_succession` | `writer_id:B, host_id:B, ownership_epoch:1, predecessor_head:Head, prior_rows:R, unavailable_interval:R, disposition:R` |

Genesis is sequence 1, has null predecessor and names the same campaign as its
envelope. No manifest digest or case identity appears in genesis. Designation
is sequence 2, after genesis. No case precedes designation. These are ordered
admission relations; a standalone body codec cannot prove the preceding record.

Relinquishment's `preceding_head` names the envelope's campaign and the exact
sequence/digest immediately before this record. Source and destination writer
IDs differ. The quiescence reference names the retained proof of no active case
or unresolved append. Source revocation is not a relinquishment member: the
retained local marker follows its fsynced append under the accepted procedure.

Acceptance names that exact relinquishment as `relinquishment_head`, its original
handoff and quiescence reference. Its writer/host match the relinquishment's
destination. Its source tuple matches the relinquishing writer/host/epoch.
`ownership_epoch == source_ownership_epoch + 1`, without overflow. The previous
envelope head is the relinquishment head. `source_revocation` and `transfer`
reference complete retained evidence available before acceptance. Handoff back
uses a new handoff identity and next epoch; the old local marker is superseded
only by that host's matching acceptance. Uncertain handoff remains fenced.

Succession is the first event after the successor's designation. Its predecessor
campaign differs from the current envelope campaign. `predecessor_head` binds
the greatest retained committed head/count of that predecessor, `prior_rows`
carries all known earlier rows, `unavailable_interval` preserves the lost
interval as unavailable and `disposition` names the maintainer authorization.
The new manifest pins this successor campaign/genesis on a new candidate.
References or a valid body cannot supply that authorization by themselves.

#### Case variant

The `case` body contains exactly these members:

```text
kind:"case", version:1,
writer_id:B, host_id:B, ownership_epoch:E,
manifest_digest:H, candidate_sha:G, lane_id:B, logical_matrix_id:B|null,
case_key:B, subcase_key:B|null, specification_digest:H,
attempt_id:B|null, state:State, mechanical_result:Mechanical|null,
verdict:Verdict|null, evidence:[R]{1..64}|null,
diagnosis:R|null, disposition:R|null, reviewer_id:B|null,
authorized_candidate_sha:G|null, authorization_evidence:R|null
```

`State` is exactly `not_dispatched`, `started`, `completed`, `reviewed` or
`authorized_next_candidate`. `Mechanical` is exactly `pass`,
`required_action_absent`, `assertion_failed`, `evidence_incomplete_pre_dispatch`,
`evidence_incomplete_post_dispatch` or `provider_environment_failure`.
`Verdict` is exactly `pass`, `product_failure`, `model_nonconformance`,
`evidence_unavailable` or `environment_failure`.

| State | Local member relations |
| --- | --- |
| `not_dispatched` | `attempt_id:null`; `mechanical_result:null` or `evidence_incomplete_pre_dispatch`; nonnull `evidence` proving no execution began. `verdict` is null or `evidence_unavailable`; a nonnull verdict requires nonnull reviewer and diagnosis. Authorization members are null. |
| `started` | Nonnull attempt ID and evidence naming the fresh execution path. Mechanical result, verdict, diagnosis, disposition, reviewer and authorization members are null. |
| `completed` | Nonnull attempt ID; nonnull mechanical result other than `evidence_incomplete_pre_dispatch`. Verdict, reviewer and authorization members are null. Evidence may be null when required retained evidence is missing; no fabricated placeholder establishes completeness. Diagnosis/disposition may reference retained boundary facts. |
| `reviewed` | Nonnull attempt ID, mechanical result other than `evidence_incomplete_pre_dispatch`, verdict and named reviewer. Non-pass verdict requires diagnosis. `pass` requires mechanical `pass` and nonnull evidence. Authorization members are null. |
| `authorized_next_candidate` | Preserve the nonnull attempt, mechanical result, non-pass verdict and reviewer of the reviewed attempt; diagnosis, disposition, authorization evidence and authorized candidate SHA are nonnull. Authorized candidate differs from the original candidate. |

For every post-dispatch state, null `evidence` requires mechanical result
`evidence_incomplete_post_dispatch`. In particular, a mechanical or reviewed
pass cannot claim that all required retained evidence is absent. Nonnull
references still require later complete-byte and cleanup verification; their
presence alone cannot establish a pass.

The codec checks the local relations above, accepted scalar domains and whole
byte cap. Ordered replay additionally joins immutable identities and original
facts across transitions, current writer designation/epoch, actual manifest
case/specification pins and the referenced evidence. An already-started attempt
cannot become `not_dispatched`; completed records are retained, not overwritten.
Review cannot replace the mechanical result. Authorization cannot replace the
failed candidate or its evidence, and cannot permit that same SHA again.

For null-matrix pre-merge work, `lane_id` and candidate bind continuation to the
original lane. For full-matrix work, the nonnull matrix ID joins all invocation
logs. A suspended lane reuses only its completed original rows and executes
only proven `not_dispatched` cases. Abandonment remains the accepted
head-recording commit, not a new body variant: that commit preserves completed
rows, leaves unexecuted rows unexecuted and bars continuation on the old commit.
The greatest committed-head and post-head started-case barriers remain required.

The runner records the first applicable mechanical result in M7's accepted
order. Independent review supplies the cause verdict. Causal authorization
retains a substantive assertion-preserving correction for product/fixture/harness
failure, a reviewed provider outage for environment failure, or an explicitly
approved scope amendment where required. A fresh SHA, account/network
prerequisite failure or missing evidence cannot manufacture an outage or a pass.
The body grammar creates no exception to those rules.

<a id="technical-adr-0057-options"></a>
### Implementation and independent vectors

Concept: [Alternatives, compatibility and proof](0057-attempts-event-bodies.md#concept-adr-0057-options).

After acceptance, the first bounded unit owns only a private event-body codec
and its complete test file in `loopex_cli`. Reuse `AttemptFrames`, canonical JSON
and duplicate-aware decoding. Do not add another framing algorithm or put
campaign governance into Core. A following pure ordered reducer must prove
legal transitions, succession, resume and abandonment before any physical
writer/runner uses these records.

The existing framing-only vectors remain framing evidence. Body admission
rejects maps outside this union. There is one served current body recipe and
no legacy fallback. An old framing-only example is not a migrated campaign.

Independent review checks member closure, nullable relations, UTF-8 byte caps,
exact quantities, every ownership/head relation, genesis cycle avoidance,
case identity retention and causal evidence. Negative vectors include duplicate
members at every nested map, unknown kinds/versions/members, malformed digests,
wrong epoch/host/handoff, null started identity, same-candidate authorization,
unavailable evidence presented as pass, first-over reference/list/frame sizes
and noncanonical JSON. Pure replay tests later include both accepted suspended
continuation and abandoned-lane vectors, all verdict routes, forks, incomplete
tails and uncertain ownership. Physical fsync, interruption, two-host handoff,
redaction and real runner dispatch remain required separate proofs.

The literal vectors below are synthetic codec fixtures. Their reference paths
and reference digests do not identify actual evidence or grant authority. Each
is an independent record example, not one legal replay chain. Independent hash
checking uses plain SHA-256 of the displayed unsigned canonical bytes; it must
not call the codec implementation being tested.

Each following JSON block is exactly the unsigned preimage, without LF or
surrounding whitespace. Its following digest is the envelope's `digest` value.
To obtain the exact complete record, insert that member between `campaign_id`
and `previous_digest`, with compact punctuation, and append one LF. Only these
canonical bytes are positive framing/body-shape vectors; the synthetic
preceding heads do not prove designation, acceptance or case-transition replay.

#### 1. Genesis

```json
{"body":{"campaign_id":"m7-vector","codec_version":1,"kind":"genesis","version":1},"campaign_id":"m7-vector","previous_digest":null,"sequence":1,"version":1}
```

SHA-256: `d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826`.

#### 2. Designation

```json
{"body":{"host_id":"host-1","kind":"writer_designated","ownership_epoch":1,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `398fecfa28498910f0bee161530aff2f83eaca76fc9cddf94dea71fe8c723ce5`.

#### 3. Relinquishment

```json
{"body":{"destination_host_id":"host-2","destination_writer_id":"writer-2","handoff_id":"handoff-1","host_id":"host-1","kind":"writer_relinquished","ownership_epoch":1,"preceding_head":{"campaign_id":"m7-vector","digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":1},"quiescence":{"reference":"/evidence/m7/quiescence.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `285463e0818ca08fdedd7b9982a730ef988e91be5836a0db538e4f45967e4f92`.

#### 4. Acceptance

```json
{"body":{"handoff_id":"handoff-1","host_id":"host-2","kind":"writer_accepted","ownership_epoch":2,"quiescence":{"reference":"/evidence/m7/quiescence.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"relinquishment_head":{"campaign_id":"m7-vector","digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":1},"source_host_id":"host-1","source_ownership_epoch":1,"source_revocation":{"reference":"/evidence/m7/revocation.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"source_writer_id":"writer-1","transfer":{"reference":"/evidence/m7/transfer.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-2"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `d2c5f982622c28b46a1648d0b9c7df6017395ccd23c78bcaae14586725c91462`.

#### 5. Succession

```json
{"body":{"disposition":{"reference":"git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"host_id":"host-1","kind":"campaign_succession","ownership_epoch":1,"predecessor_head":{"campaign_id":"m7-predecessor","digest":"0000000000000000000000000000000000000000000000000000000000000000","sequence":9},"prior_rows":{"reference":"/evidence/m7/prior-rows.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"unavailable_interval":{"reference":"/evidence/m7/lost-interval.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `bdaf0d9d78dbb747b7387d9ded9ffab601df8527d5ac4f9e16c48f504a3db033`.

#### 6. Not dispatched

```json
{"body":{"attempt_id":null,"authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/preflight.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":null,"manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"evidence_incomplete_pre_dispatch","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"not_dispatched","subcase_key":null,"verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `7cb3e21266e5c4ec45b1f9a57c54f9b1cc53b6d52205ce28fdc0b6bffccddda9`.

#### 7. Started

```json
{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/execution-path.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":null,"ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"started","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `7bb7ac0cb7333a66833516619eee03250280729058164bf0b29ac54e33d595d5`.

#### 8. Completed pass

```json
{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/complete.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"pass","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"completed","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `5628498f4787d5084a5c6432f1fd2347462de02fe3475f91ecd06169e36dff6e`.

#### 9. Completed failure

```json
{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":null,"disposition":null,"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":null,"specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"completed","subcase_key":"V1.1","verdict":null,"version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `ff16d18d75a9a27f1a43a73167ce6c1226c4e2cc8e4be0e751fb55c9f2ea3b1d`.

#### 10. Reviewed failure

```json
{"body":{"attempt_id":"attempt-1","authorization_evidence":null,"authorized_candidate_sha":null,"candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":{"reference":"/evidence/m7/diagnosis.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"disposition":null,"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"reviewed","subcase_key":"V1.1","verdict":"environment_failure","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `11241759f571d3d4e579dd66ebfc6e7937175cb9e23c471fc8d06abb0677d16b`.

#### 11. Authorized next candidate

```json
{"body":{"attempt_id":"attempt-1","authorization_evidence":{"reference":"/evidence/m7/authorization.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"authorized_candidate_sha":"2222222222222222222222222222222222222222","candidate_sha":"1111111111111111111111111111111111111111","case_key":"m7.vector","diagnosis":{"reference":"/evidence/m7/diagnosis.json","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"disposition":{"reference":"git:2222222222222222222222222222222222222222:docs/evidence/decision.md#acceptance","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"evidence":[{"reference":"/evidence/m7/boundary.log","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"host_id":"host-1","kind":"case","lane_id":"lane-1","logical_matrix_id":"matrix-1","manifest_digest":"0000000000000000000000000000000000000000000000000000000000000000","mechanical_result":"provider_environment_failure","ownership_epoch":1,"reviewer_id":"reviewer-1","specification_digest":"0000000000000000000000000000000000000000000000000000000000000000","state":"authorized_next_candidate","subcase_key":"V1.1","verdict":"environment_failure","version":1,"writer_id":"writer-1"},"campaign_id":"m7-vector","previous_digest":"d4f20cd596c808cc8f75483de8890ed7f09e44b4f846c809aa41fbb489dc9826","sequence":2,"version":1}
```

SHA-256: `6a668940882a3289b48ecbf8167155d87d84fa042cce42a75bbc8b29f05c8232`.
