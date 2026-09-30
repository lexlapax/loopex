# M7 round 2 repair record

Date: 2026-09-30. Reviewed base:
`10749d084bd74487aac423d9640ac2eb1d05bee6`.

## Concept

M7 is not ready for acceptance or another external handoff. The external report
identified real feasibility gaps, especially summary processing and thinking
continuation capacity. Several numerical claims overstate what their examples
prove. The repairs below preserve the maintainer's selected 64 KiB request
ceiling, bounded thinking support, stop-only helper recovery, approved agent-run
tests, strict demonstrations and interactive/piped chat.

The maintainer asked for our own adversarial review and fixes after the external
report, before receiving another candidate SHA and review prompt. That final
packet review remains outstanding. Three internal read-only advisory workstreams
checked the report against source, followed by fresh checks of repaired helper,
configuration and credential contracts. They are not formal acceptance reviews.
No product implementation, provider call or milestone acceptance is claimed.

The maintainer selected [option A: marked bounded excerpts](../developer/agent-context-map.md#disposition-m7-compaction-excerpts-2026-09-30)
for oversized older content, retaining complete originals. The detailed source
projection remains to be repaired after the requested restart checkpoint. Further
material choices will be presented one at a time, including thinking headroom
and supported modes, native-response delivery/privacy, protocol compatibility
and the scope of the parallel-helper ban. A report's request for a decision
does not by itself reopen a choice the maintainer already made.

## Technical depth

### Source and measurement limits

The received [external report](M7-external-review-2.md) is retained byte-for-byte.
Its SHA-256 is
`7f445b3638917d7e1c782218b13cf4e4c6efeefc6b879cac5e8e7731da6a5483`.
Historical reports and their contract hashes still describe their original
revisions. This record tracks subsequent proposals, not new acceptance evidence.

A bounded synthetic probe used freshly compiled `Canonical.encode/1` and
`Store.normalize_and_measure_item/2` from the reviewed base. It omitted the
context receipt deliberately. Request measurements are lower bounds, not
completed M7 request proofs. No real provider signatures were measured.

| Input | Measured size |
| --- | --- |
| 10,000-character write group plus 6,000-character prior summary | 16,496 JSON bytes in summary source |
| 12,000-character prompt plus that prior summary | 18,115 JSON bytes in summary source |
| Eight 2,048-byte result messages plus current coding tools | 46,539 request-record bytes before receipt |
| Same eight results plus 6,000 summary characters | 58,638 request-record bytes before receipt |
| Twelve such results, without summary | 65,637 request-record bytes before receipt |
| Five rounds with 512 thinking characters and an 88-character signature per round | 7,324 continuation JSON bytes; 30,464 request-record bytes before receipt |
| Eight of those rounds | 11,533 continuation JSON bytes; 43,391 request-record bytes before receipt |
| Five rounds with 2,048 thinking characters per round | 15,004 continuation JSON bytes; 45,824 request-record bytes before receipt |
| Eight of those larger rounds | 23,821 continuation JSON bytes; 67,967 request-record bytes before receipt |

The retained directory is `/tmp/loopex-m7-round2-size-10749d08/` on the review
machine. Complete files and SHA-256 digests:

| File | SHA-256 |
| --- | --- |
| `probe.exs` | `877aa809c35263ab3c6538a999f90bcddff101d0b36d4ef48391023dbef7cbe0` |
| `inputs.exs` | `0eb66e48cd8d650a4128c489e6e1c135f744fe32c11cbe68525157e2d83660e7` |
| `results.exs` | `1d72a3fc381c81720666037f4bb70da66c4fe13aa50756c3e6546d13e35b03fa` |

These establish counterexamples and disprove universal round-count assertions.
They do not prove useful model behavior or acceptance of an actual rendered
M7 request. Subsequent complete-profile and maintenance examples follow.

### Complete profile sizing

A second probe used source checkpoint
`9431b1c95c38d4c4261309e59c7a9526c3aa85c9`, with actual base definitions,
complete proposed read/question/helper parameter shapes, useful instructions,
the exact workspace/platform, two concrete roles and their full catalog digest.
Two bounded wording passes shortened new-generation descriptions without
changing the estimator or removing fields and validation refinements.

| Complete profile | Current base descriptions plus proposed tools, estimated tokens | Second concise candidate, canonical bytes / estimated tokens |
| --- | ---: | ---: |
| Coding chat | 1,061 | 2,420 / 809 |
| Read-only chat | 865 | 2,360 / 789 |
| Helper-enabled coding chat | 1,282 | 2,990 / 1,000 |
| Helper-enabled read-only chat | 1,086 | 2,930 / 980 |
| Reviewer child | 688 | 1,969 / 659 |

The system class sums `ceil(bytes/3)` separately for the canonical system
message and each `ToolDefinition.model_facing/1` encoding. It is not a provider
token count or a whole request-record size. The coding/helper candidate fails
the strict `< 1000` rule at exactly 1,000. This near miss does not establish
impossibility; it also gives no useful margin for longer workspace paths or
larger role catalogs. Other profiles demonstrate arithmetic feasibility for
these supplied inputs, not instruction effectiveness.

Current tool schemas support primitive fields, required members, enums, items
and descriptions. Bounds, exclusive branches and role membership remain
explicit owner/executor refinements, not unsupported JSON-schema keywords.
The proposed interaction class/zero artifact budget is not yet accepted by
current definition validation. No production definition was changed.

Complete sources, candidate text, refinements and estimator preimages are
retained in `/tmp/loopex-m7-profile-9431b1c9/`:

| File | SHA-256 |
| --- | --- |
| `probe.exs` | `72326fef7783108b8cf989128b3bcad2cba18ceb526c99f68dc8bb4b442a4e6d` |
| `inputs.exs` | `9892dc90f507ffe14b46ce78ebba4da24c59ea44e24a62c1d0d2652be6d05eb1` |
| `results.exs` | `c9e163df21610d428697b2b3c561ef223f33d1c5b4ab556b7596fe9497ea9b9a` |

### Maintenance sizing example

At the same `9431b1c9` checkpoint, `C43-small-cache-inspection` retains exact
host instructions, canonical source and an authored six-section summary of a
cache defect. The summary preserves constraints, proposed work, unrun checks
and an unresolved old-key question. It is not a provider response or a quality
verdict. Its instruction uses the proposed `version + ": " + body` rendering.

| Measurement | Result |
| --- | ---: |
| Rendered instruction | 1,393 bytes |
| Complete source JSON | 9,066 / 16,384 bytes |
| Complete output JSON | 1,258 / 6,144 bytes |
| Encoded summary string / carry-forward object | 1,080 / 149 bytes |
| Maintenance input estimate + reply reserve | 3,527 + 1,024 = 4,551 |
| Current-shaped maintenance owning record | 23,538 / 65,536 bytes |
| Ordinary record before → after substitution | 24,510 → 7,103 bytes |
| Ordinary input estimate before → after | 3,369 → 690 tokens |

Seven source modules were extracted from that checkpoint. The probe uses the
actual request constructor/validator, canonical serializer, per-message
estimator, required-context admission and record normalization with the
receipt's fixed-point self-size. Setting either measured byte or input limit
one below the observed value produces its named refusal. Four identical
input-plus-reserve calculations total 18,204; the current no-reply accounting
fallback totals 18,504. Both are below 32,768 for this fixture. Neither promises
four successes or completion within 60 seconds; four is the total attempt
ceiling, including allowed retries.

New M7 maintenance/configuration/checkpoint constructors do not yet exist.
These supplied current-shaped records include current duplication and receipt
cost, but do not prove future record sizes, real provider output tokens,
committed-history replay or the final artifact projection. Receipt provenance
and tool results are synthetic. Exact final serialization and real summary
quality remain implementation/acceptance obligations. The example gives no
reason by itself to increase the 1,024-token reply reserve.

Complete artifacts are retained in `/tmp/loopex-m7-maintenance-9431b1c9/`:

| File | SHA-256 |
| --- | --- |
| `hashes.json` (all inputs, probe, source manifest and preimages) | `9d78659db27feec885b0796eeca20f235759e8dda8d27b523ccef968ebef9301` |
| `maintenance-instructions.txt` | `25e7e4e99e645f7e567fd5985ba6493a7d7d121a112c084150497dcafd7b2f4a` |
| `source.json` | `3ccca7c0ac8882a52d71bdbdcc2e440f502cb8b63ddad6776c1396951f9f4c9a` |
| `output.json` | `a4c4fb2d6d02619de0a75e27e86b7bdb3029250ef9fa14daead18c5cd80e3f88` |
| `measurements.json` | `dd4e5f92b5234c0ff3559d18684166280e7506e8e00c9a4ece5ac9d7f3f2b899` |

### Aggregate result sizing

At checkpoint `bdb48d73c23c7cb4bddea8b4f55988287336087a`, a bounded probe used
the current four-tool coding profile, system instructions, request serializer,
Store normalization and current receipt construction. Each source reply calls
`read(path="a")` with distinct IDs. Current `ProviderAttempt` validation admits
the supplied reply/settlement shapes. The result notice is an explicit M7
prototype encoded inside existing tool-message content, not implemented output.

| Calls | Source settlement bytes | Request with maximal excerpts | Request with zero excerpts |
| --- | ---: | ---: | ---: |
| 8 | 1,544 | 51,957 | 26,317 |
| 12 | 1,828 | 72,041 | 33,581 |
| 64 | 5,549 | 333,162 | 128,042 |

For twelve calls, 1,326 raw ASCII excerpt bytes per result yields a 65,513-byte
current-shaped request. Its 23-byte margin does not prove a final M7 fit:
new configuration/continuation provenance is absent. The prototype's zero-text
notice is 447 JSON bytes; this is a fixture cost, not a universal minimum.
The 64-call reply fits, but its required result metadata cannot fit this next
request even without excerpt text. Individual executor-intent records were not
constructed, and no runtime/provider workflow ran. The 1,024-member collection
ceiling is not a guarantee of 1,024 admissible calls or messages.

ADR 0041 now specifies shared-prefix allocation over eligible retained outputs,
with exact full preflight, preserved explicit range reads and frozen prefixes,
unchanged preparation limits and irreducible refusal. It neither shrinks
user/model-authored content nor creates a new call-count limit.
The paragraph review caught a receipt-growth edge: allocation must pass both
the initial resource header and the existing reserved longest empty header,
so later optional-resource withholding cannot consume unreserved bytes.

Artifacts are retained in `/tmp/loopex-m7-aggregate-results-bdb48d73/`:

| File | SHA-256 |
| --- | --- |
| `probe.exs` | `f8b268df923470095baa6c4b24eaa85db59f928cd6e26b9da831bcc1f74bd96d` |
| `inputs.exs` | `26f153c9e8575a415cd363e816209f74e979495d2318d2c4626ac02fc7ede2fc` |
| `results.exs` | `e3aea9f36e5060dea3689a1060e7f8125a30cacf8178040b22f6b48b844b1c4d` |

### Native-reference capacity comparison

A separate probe at `bdb48d73` compares full native capsules with an unselected
adapter-created local-reference layout. The authored three-round cache-repair
example has two calls and two distinct text blocks per round, literal thinking
and redacted-thinking blocks, and six 1,313-byte result strings. Five/eight
rounds repeat those operation shapes with fresh identities solely for sizing.
Model identity, signatures, outcomes and usage are synthetic; no task ran.

| Rounds | Full / reference request-record bytes | Full / reference stored-envelope JSON bytes |
| --- | ---: | ---: |
| 3 | 68,473 / 55,841 | 10,915 / 4,561 |
| 5 | 111,517 / 88,433 | 19,090 / 7,433 |
| 8 | 170,003 / 134,277 | 29,755 / 11,739 |

The proposed layout preserves block order. Text descriptors consume exact
UTF-8 slices from canonical assistant text; tool descriptors retain native
ID/name and refer to that same reply/request's canonical arguments. Thinking,
signatures and redacted data remain literal. Capture verifies full lossless
expansion before atomic settlement. Staging checks exact source bindings;
dispatch expands from the self-contained request only, without journal or
artifact reads. Unequal canonical/native IDs need explicit mapping vectors;
this fixture uses equal IDs and does not prove that path.

Only the three-round reference case fits the measured 64 KiB record. Expanded
envelope sizes remain 10,915/19,090/29,755, so the unchanged expanded 16 KiB gate
also rejects five/eight rounds. Preserving the conservative expanded-envelope
estimator yields 10,263/17,305/26,856 input estimates; references do not reduce
provider input. No cap, estimator policy, delivery mode or model subset changed.

The probe measures supplied proposed-v2 records with the current serializer,
Store and context admission plus a current-style receipt/continuation descriptor.
Final M7 schemas and some binding metadata are absent. It is not a decoder,
replay, fault, provider-token or quality proof. It demonstrates storage savings
and their limits; the continuation/headroom decision remains open.

Exact sources, inputs, candidate records and report are retained under
`/tmp/loopex-m7-native-references-bdb48d73/`. `SHA256SUMS` binds all artifacts
except itself, with SHA-256
`46589a0d02632a37090fcb68df91d1ff19fd843f6e10b0c44a4c18427b0da2b9`.
The `measurements.json` SHA-256 is
`6410d09b9c914a8484b2c155c691cc894534488c57dcfccd2606c40c4492ad3c`.

### Finding dispositions

“Repaired” means the proposal now states the requirement and planned witness.
It does not mean implemented or tested. Pending rows prevent a readiness claim.

| # | Disposition | Reason, repair or remaining work |
| --- | --- | --- |
| 1 | Valid; A selected, contract repair next | Use marked bounded excerpts of oversized eligible older content and retain complete originals. Repair the source grammar/allocation so a large old prompt, model write or group metadata does not permanently block selection; no new admission restriction or chunked model workflow was selected. |
| 2 | Partly valid; bounded comparison retained, design pending | Local-reference prototypes reduce one three-round record from 68,473 to 55,841 bytes but five/eight-round examples still fail. Counts remain fixture-dependent. Representation, expanded-cap semantics and a useful pre-exchange reserve remain unselected; required data cannot leave request digest coverage. |
| 3 | Partly valid; pending matrix | Manual thinking is not Haiku-only: the current official matrix also permits older Opus/Sonnet families. Always-on models cannot satisfy the draft's universal thinking-off maintenance rule. ReqLLM's adaptive display injection conflicts with `provider_default`. Resolve the supported matrix and maintenance policy explicitly. |
| 4 | Small complete example measured; quality proof remains | A useful authored fixture fits the declared input/output caps and current-shaped record with receipt. This does not prove provider output tokens or quality. Retain the reserve pending actual implemented witnesses; do not infer that every maximal member must fit simultaneously. |
| 5 | Existing rule overlooked; concrete join repaired | ADR 0041 already required new output to spill before receipt. Clarify the encoded projection trigger and require new search-tool artifact allowances; old one-byte allowances cannot retain their output. |
| 6 | Aggregate proposal repaired; finite capacity retained | The complete baseline probe fits eight maximal outputs, repairs twelve with a shared allowance, and demonstrates irreducible metadata overflow at 64. ADR 0041 now allocates eligible excerpts together with exact preflight, unchanged preparation limits and frozen-prefix/range-read protection. Final M7 records still require measurement. |
| 7 | Usability choice pending | Batched calls mean 1 KiB reads need not consume fifteen turns, but explicit retrieval is still costly. Decide its usable bound separately from unsolicited excerpts. |
| 8 | Deliberate compatibility restriction; pending disposition | Old generations lack artifact retrieval. Choose a bounded inline compatibility exception or name this refusal explicitly in upgrade expectations; never migrate tool definitions implicitly. |
| 9 | Meaningful prototypes measured; target risk remains | Complete ordinary profiles fit after bounded wording work. Helper-enabled coding reaches exactly 1,000 and therefore refuses. No impossible-target claim or ceiling increase follows; actual final profiles and path/catalog margins still need proof. |
| 10 | Claimed subtraction rejected; wording repaired | 8,192 is the fallback input budget. ADR 0041 now says so explicitly. Actual mandatory-content preflight still applies. |
| 11 | Repaired | ADR 0044 uses settlement v3, preserves ADR 0021 v2 and its accounting evidence, and charges invalid continuation conservatively. |
| 12 | Feasible route found; delivery choice pending | Built-in Anthropic preparation plus per-request Req steps can capture buffered native replies without global provider registration. Native streaming needs additional lifecycle work; do not silently narrow its promise. |
| 13 | Pending maintainer choice | Existing public reasoning summaries conflict with blanket suppression. Decide permitted public summary versus private native data and name any accepted-contract amendment. |
| 14 | Evidence gap repaired | Add real continuation after bound/cancel with a new prompt and exact rendered grouping. Unsupported rendering refuses; no invented assistant completion. |
| 15 | Clarified | Define deterministic derived IDs and collision refusal. A chosen prefix cannot prove disjointness from native IDs. |
| 16 | Coverage clarified; headroom remains pending | Enumerate CLI JSON/transcript, Node, diagnostics and dependency telemetry witnesses. Preserve the existing private-store and host-VM audience limits. |
| 17 | Intentional availability limit retained | Unclassified cancellation closes helpers for that router incarnation, including a local-job race. Add that explicit witness; a bounded per-job registry is optional complexity. |
| 18 | Truthful uncertainty retained | Nested cleanup may outlast the parent's observation window. Add this case and preserve unknown even after later child cleanup; no unapproved extra spending/deadline margin. |
| 19 | Repaired for safety | Retain original child creation inputs and resolved cleanup grace. Changed-runtime reconstruction conflicts, unavailable or unexpected lookup remain unknown, never false absence. This does not promise successful recovery under changed grace. |
| 20 | Repaired | Every reference-host resume/prompt route classifies helpers before activation. Independent adoption, including a new prompt to a settled helper, refuses. |
| 21 | Repaired with internal correction | Executor cancellation depends on causation and confirmed cleanup. Preserve a completed/failed child fact that won first; distinguish model-facing failure from receipt outcome. |
| 22 | Cardinality claim rejected; ownership clarified | 128 is a ceiling, not guaranteed capacity. The 16 MiB log may refuse earlier and must reserve closing credit. Composition owns the ledger. |
| 23 | Repaired | Volatile stop fences launches immediately. Bounded best-effort abort may proceed during unknown stop commit without authorizing new ledger mutations, refunds or success. Conservative adapter-wide uncertainty remains explicit. |
| 24 | Repaired | State exact process/runtime-incarnation fencing. Do not claim Local's constant numeric epoch increments after restart. |
| 25 | Repaired | Persist expiry refusal idempotently; resolve unknown admission/refusal by its original transaction, not a new clock check. |
| 26 | Repaired | Complete bounded per-operation stop/reconciliation before affected parent activation. Expired recovery remains unknown. |
| 27 | Partly repaired; chosen pipe behavior retained | Stdin TTY selects mode. Specify status/acknowledgement, choices and outcome framing. Static unexpected questions fail honestly; bidirectional producers answer actual IDs. No new no-question flag is implied. |
| 28 | Repaired; fresh review applied | Name ADR 0019/0039 amendments, closed multi-binding plane, exclusive supplied-plane/reference options, all custody/launch joins and preserved legacy receipt meaning. New all-binding exclusion needs launch canaries, not reinterpretation of old false bits. |
| 29 | Repaired | Reply/context/system budgets stay committed on resume. Only max turns, relative deadline and token budget are new-run overrides. |
| 30 | Repaired | Explicit ephemeral `questions: true`, default false, preserves existing definitions. State callback termination and trusted-host non-recursion obligations. |
| 31 | Repaired with an explicit limit | Propose owner-managed ephemeral trace startup, application selectors and separate drain/writer. Bound pending output and one write; preserve ADR 0030's best-effort sink mailbox. A hard whole-consumer claim is unsupported without changing all producer paths. |
| 32 | Inventory repaired; compatibility decision pending | The plan inventories changed create/configure/compact/prompt/follow-up/answer methods, events, snapshots, bounds, authority joins and independent payload checks. Choose old-generation refusal or dual service. No reused generation name or unchanged schema digest may carry new shapes. |
| 33 | Clarified | Keep the pinned historical pair and add a distinct M6↔M7 matrix. Source-built exact M6 artifacts are allowed with identity evidence. Blocking old-binary access is an operator precondition, not a claimed future marker. |
| 34 | Repaired | Required new selectors join the full closure matrix. Durable A/B are hosted credentialed routes; pin their models and reference names before runs and pass every selected name through redactor/PTY self-tests. |
| 35 | Name-as-provider-authentication claim rejected | The host authorizes variable slots; spelling cannot establish the issuer of a value. Explicit options and redacted configured-only inspection are now stated. |
| 36 | Strict requirement retained; consequences clarified | A missed required action fails and blocks closure. No same-revision reroll or cosmetic new SHA converts it to pass. Scope/oracle changes require maintainer disposition. Add a controlled steer barrier. |
| 37 | Repaired | Name the trusted fixture-chat wrapper, normal file validation and fixed composition injection. Production policy registry remains closed. |
| 38 | Repaired | Enumerate closure slots, run identities, manifests, measurements, operator/reviewer identities and immutable pre-attempt external task pin. |
| 39 | Repaired | Extend both pending vision amendments to question authority/flow consequences and pending §27 dispositions. Register already named paired vision acceptance; roadmap now points to it too. |
| 40 | Pending maintainer clarification | Earlier record says no parallel helpers; later drafts say one per parent run. Confirm scope before calling those equivalent. |
| 41 | Repaired | Complete the accepted ADR 0010/0017 amendment table and add settlement provenance/credential-source dependencies. |
| 42 | Repaired | Name the attended ephemeral demo host and operator identity form; require every scenario step/subcase in the fixture evidence manifest. |
| 43 | Clarified; meaningful measurements retained | Record the existing lineage conformance defect, complete profile prototypes and rationale for core's closed reasoning level. Final integrated sizes and helper-coding target margin remain unproved. Context-map decision pointers remain authority; external pin has a destination. |
| 44 | Repaired | Concept explains host compaction instructions, native capture/render boundary and config/rollback operator coverage. |

### Fresh internal findings

The post-repair helper review found two defects in the revised draft. A blanket
cancelled receipt would overwrite a child completion that won before parent
cancellation. The repaired rule preserves causation and has a race witness.
Repeated startup could also append another stop and exhaust reserved log credit.
Stop is now write-once per operation, as are settlement and each attempt receipt;
repeat recovery returns the original fact without a replacement append.

The post-repair configuration review found ambiguous simultaneous supplied
plane/binding options, credential availability claims without environment reads,
and an implied daemon/app-server file grammar. The revised contract rejects
mixed credential sources, labels inspection as configured-only, and keeps new
file grammar in chat/config. Other reference hosts accept equivalent explicit
programmatic options; their old CLI startup remains single-route.

The trace review rejected a hard whole-consumer mailbox claim. The existing
dispatcher can send drop summaries outside its saturation check, and session
coordinators/registries also send diagnostics directly. Separating the writer
therefore bounds pending output but cannot alone bound the drain mailbox. The
proposal now names ADR 0030's existing best-effort limit instead of inventing a
subscription guarantee; no required existing diagnostic check is removed.

The protocol pass found that both existing generation digests cover metadata,
while the Node vector runner proves framing rather than method payloads. The
new inventory requires complete payload identity and independent semantic
witnesses. A further source check found prompt/follow-up normalization omits
authored bounds. A subsequent authority check confirmed that ADRs 0011/0017
deliberately specify the old identity; it is not a source conformance defect.
ADR 0046 now explicitly proposes the new authored-bound identity, preserving
historical digests and replay. Prompt partial overrides remain supported.
The first inventory incorrectly applied those ordinary overrides to follow-up
as well. That overreach is removed: follow-up adds only its own absolute
ceiling and preserves ordinary limit inheritance from the active run.
The same pass adds exact new bound encodings without narrowing core integer
domains, a new bounded snapshot revision, allowlisted public projections and
independent Node digest assertions before mutation. Literal payload vectors
and live authority/replay witnesses remain separate obligations.

The maintenance pass exposed an unnamed instruction injection/lifetime contract.
ADR 0043 now proposes an explicit immutable runtime option, exact bounded
rendering and capture in each episode. Missing configuration refuses new
maintenance; recovery uses an admitted episode's retained bytes. The source
envelope and single-string summary shape are explicit. These repairs preceded
the maintainer's excerpt selection; its detailed source projection and the
always-on thinking policy remain unfinished.

Outstanding work: resolve the pending choices,
complete the final profile/request capacity design, update all affected
pairs, then run a fresh adversarial pass over the complete packet and repair
its findings before preparing another external SHA/prompt. A documentation
check alone cannot establish implementation readiness.

<a id="resume-checkpoint"></a>
### Resume checkpoint, 2026-09-30

The maintainer requested commit/push and a restart checkpoint immediately after
selecting A. No new question is pending. Resume this work on branch `m7` in
`/Users/spuri/projects/lexlapax/loopex`; inspect Git before changing anything.
All work remains planning/docs, with commits and pushes authorized. M7 is Open,
ADRs 0041–0049 are Proposed, and the paired vision amendment is unaccepted.
Do not implement product changes or present a final external-review SHA/prompt
until the remaining decisions, repairs and whole-packet adversarial pass finish.

1. Apply selected A to ADR 0043 and affected plan/ADR pairs. Preserve originals,
   whole-group checkpoint cuts, exact provenance, the protected recent tail,
   the open-thinking exclusion, 16 KiB source and 64 KiB request limits, and
   bounded maintenance attempts. Define marked omissions, deterministic source
   allocation, UTF-8/JSON handling, prior-summary handling and restart identity.
   Cover large user text, generated arguments and large group metadata; reducing
   only executor-result text leaves the original blocker unresolved.
2. Ask remaining material questions one at a time, with plain-English options
   and consequences. The question tool was invisible to this user; display the
   options in the chat as well. Next resolve useful thinking capacity/modes;
   then native-response delivery/privacy, explicit range-read usability, old
   tool/protocol compatibility and the parallel-helper ban's scope. Do not
   reopen recorded choices or infer approval from silence.
3. Use the retained probes above. Local native references are an unselected
   design comparison, not an adopted ADR 0044 format. Aggregate result allocation
   is already drafted in ADR 0041. Final integrated sizes and helper-coding prompt
   margin remain unproved. No provider or product-test evidence exists for M7.
4. Update all affected pairs, perform the requested fresh whole-packet internal
   adversarial review, repair its findings, verify and push. Only then provide
   the exact external-review candidate SHA and a review prompt. Acceptance is
   a later maintainer decision.

Before this restart note, `e6e083fec34585059fd18534ac2edea3e54f9226` was pushed
and its documentation gate passed in 15 seconds. Its complete log is
`/tmp/loopex-m7-e6e083fe-docs.log`, SHA-256
`dd180695d9a584e6c942e215bee9de733e61c974d0c2d1b2a9ecd0a2c0dfcc95`.
This note adds a new checkpoint; that prior run is not evidence for these new
bytes. Background design work was interrupted for the restart; no worker owns
uncommitted repository changes. Read durable records rather than relying on
worker memory or an old chat summary.
