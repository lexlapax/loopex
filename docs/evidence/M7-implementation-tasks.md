# M7 Implementation Tasks

Execution checklist supplied by the maintainer. The accepted
[plan](../plans/M7.md#concept) and its
[technical companion](../plans/M7-technical.md#technical-depth) govern scope
and proof obligations. This checklist records work; it introduces no decisions.
Part of the [evidence index](README.md).

## Current work

- Done: reproduce cross-run conversation loss with the real session-owner path
  and a scripted model in `apps/loopex/test/agent_loop_test.exs`.
- Done: run-scoped result joins, replayed admission order, revision-1 normalized
  call identities and strict complete-lineage validation. These are projection
  foundations; the coordinator now stages the complete committed lineage.
- Done: v2 request staging, revision-4 nil-continuation receipts, exact lineage
  replay validation, and terminal-derived unknown/cancelled call results.
- Done: conversation integration candidate fast check; all 11 suites pass
  2,638 tests at `2d804649ca82ce87b58511bc0739c93e700c7559`.
- Done: pinned artifact-read generation vectors and pure capability binding;
  instruction capture/render validation preserves exact legacy staging bytes.
- Done: shared v3 genesis normalization/resolution and pure replay retain closed
  configuration, exact tools, artifact-read binding and policy-defer mode.
- Done: exact-genesis live creation and configuration-bound runtime staging;
  two prompts plus restart retain captured instructions, settings and tools.
- Done: captured-configuration runtime candidate fast check; all 11 suites pass
  2,679 tests at `d46c8d10881e6ba811b6c1d5204c9545aa785d37`.
- Done: reference-host instruction capture, exact environment JSON rendering,
  bounded base/appendix/role files and retained-content byte fixtures.
- Done: bounded host JSON syntax decoding with duplicate-key pointers and exact
  integers; pure provider-reference validation against the adapter catalog.
- Done: closed authored-file schema, bounded selected-file loading and relative
  path resolution; trace selectors resolve through trusted module manifests.
- Done: chat/config inspection flag parsing, duplicate/conflict rejection,
  repeatable array selection and exact numeric-domain validation.
- Done: new-session precedence composition and per-value origins, including
  flag/environment/file selection and harmless literal defaults.
- Done: bounded model-limit capture from the verified pinned packaged catalog,
  preserving unknown limits and the one accepted literal Haiku alias.
- Done: shared pure initial-configuration resolution derives context ceilings
  and their origins, validating captured instructions and all selected schemas.
- Done: exact v2 question-tool definition, pinned canonical preimage/digest,
  argument admission and interaction-versus-executor dispatch separation.
- Done: committed model-question requests and atomic answer, decline, expiry and
  abort settlement retain the original call and response identity through replay.
- Done: live owner succession at all four pending/response commit boundaries
  retains one question and one settlement without repeating provider work.
- Done: commit-unknown recovery re-presents exact question/response payloads;
  disk-backed Store restarts retain the pending identity and settled answer.
- Done: shared closed answer normalization and literal answer payload/schema
  vectors pass both the Elixir and independent Node decoders.
- Done: pure whole-candidate configuration updates validate every mutable member,
  advance one version and recompute derived ceilings while retaining explicit ones.
- Done: pure atomic configuration admission/replay retains exact command identity,
  one instruction copy, unchanged earlier run captures and an allowlisted event.
- Done: terminal-tool-history capability preflight validates complete lineage,
  treats empty assistant completions as absent and gates configuration replay.
- Done: configured ordinary staging checks terminal-history capability before
  request intent, committing an unavailable v2 preparation refusal and terminal.
- Done: reproduce and fix false OwnerGroup shutdown_error/noproc reports while
  preserving parallel shutdown, owner-worker barriers and actual fault reporting.
- Done: join host-prepared ordinary configuration to live owner admission, exact
  retained-history sizing, atomic commit, restart and commit-boundary fault proofs.
- Done: implement shared bounded content-reference expansion and pure exact native
  block capture, preserving text slices, ordered arguments and both JSON ceilings.
- Done: prepare strict M7 callback projection and source-bound v3 settlement
  readers, including monotonic cutover and unchanged historical reply shapes.
- Done: emit v3 for every new ordinary settlement, migrate exact callback
  fixtures and preserve conservative accounting and historical reader schemas.
- Next: complete host resolution, maintenance quiescence and checkpoint-aware
  configuration preflight; join native capture to source-bound request envelopes
  and the transport bridge; complete question
  projection/private-record vectors and the remaining M7
  configuration/maintenance/bound payloads before the coordinated /3-/4 switch;
  continue prompt-file and mapping
  preparation, effective inspection and command entry wiring, then live
  chat/configuration composition and non-nil continuation costs in T04/T06/T08.
- Remaining: all unchecked tasks below. Closure, main integration and release
  retain their explicit maintainer decision gates.

## Development observations

- 2026-10-01: every new ordinary settlement now writes model_attempt_settled_v3,
  including retries, transport errors, unreadable callbacks and validated reply
  compaction. The owner uses the run's frozen continuation requirement for strict
  nine/eleven-member callback admission; canonical successful replies retain ten
  members. Eight-member callbacks and invalid capsules retain accounting_evidence
  none and charge the conservative allowance before policy or executor dispatch.
  Model's reply type declares exact v2/v3 variants with a mandatory nil-or-binary
  response ID. Live fixtures and current-generation shape/size probes are migrated;
  explicit historical v1/v2 fixtures keep eight-member canonical replies. Genuine
  M2 archive readers/writers and their expected v2 tag remain unchanged.
  Required closed capsules retain exact content through before/after-commit holds,
  lost commit reply, atomic publication and runtime restart without another model
  call. These are scripted model-port proofs, not native provider conformance.
  Current core regressions pass 267 tests in 54.6 seconds. Adapter streaming/bridge
  checks pass 56 in 43.0 seconds; composition passes 16 in 19.2 seconds; CLI coding,
  accounting and genuine M2 compatibility pass 13 in 63.1 seconds with two existing
  real-provider exclusions; the reference-client check passes one in 0.5 seconds
  with one real-provider exclusion. Final targeted current checks pass 42 in 4.0
  seconds, excluding 65 unselected protocol cases already covered by the broad
  run. The floor pair passes all 108 writer/protocol/configured checks in 25.7
  seconds. A syntax-tree inventory checks 24 raw reply literals across app/script
  source and finds no omitted response-ID fields. The malformed binary-key reply
  retains its identity failure independently of shape rejection; the dispatched
  rollback script now supplies the mandatory nil field.
  Complete outputs are retained outside the repository:
  - `/private/tmp/loopex-m7-v3-writer-core-final.log`, SHA-256
    `5ae6bc4159e85804596905b7820bfcf30d02de8b82ab7c1064bf44909fd207d6`.
  - `/private/tmp/loopex-m7-v3-writer-adapter.log`, SHA-256
    `1486e5f7f9767ffc37238574112ca535681506c417a27bcc459180881733ec14`.
  - `/private/tmp/loopex-m7-v3-writer-composition.log`, SHA-256
    `63602350ed96634d3c2b1cb475690a80b96eeb16fc2a92e27cfe9e2460a836e0`.
  - `/private/tmp/loopex-m7-v3-writer-cli.log`, SHA-256
    `05cc109743142831317055eb916adfd335fd7996e6752e45f95915859abec4a1`.
  - `/private/tmp/loopex-m7-v3-writer-reference.log`, SHA-256
    `e2077a32a5a9a20ed0d638e2ec0891561ca33aa119688efa9b9f60386d91c5e3`.
  - `/private/tmp/loopex-m7-v3-writer-floor.log`, SHA-256
    `258ccdd0347ea8bf86123b26e20dd5c326c01f92faf372503f7a92bc01d49a0d`.
  - `/private/tmp/loopex-m7-v3-writer-final-focused.log`, SHA-256
    `649a25f3cd2668431c71d2c0c9bbefff2a1b3628582dfa9259ef8b77f9691991`.
  Source-bound request envelopes, native transport, continuation accounting and
  mapping registration remain pending. Current compilation and formatting pass;
  compiled documentation covers 986 entries. This does not replace the full fast
  integration check, real-provider or complete migration/rollback lanes, or resolve
  the separate Task.Supervisor cleanup investigation.
- 2026-10-01: ProviderAttempt's M7 projection admits exact nine-field v2 or
  eleven-field v3 callbacks and returns the ten-field canonical v3 shape.
  Missing provider_response_id, mixed/extra fields, missing required capsules,
  non-natural continuation completion and malformed/oversized capsules refuse
  before the caller receives accounting evidence. V2 normalizes to explicit
  nil continuation/unknown completion only when the captured mapping permits it.
  Capsule model, ordered native IDs, complete text and argument consumption bind
  the owning staged request. The historical two-argument projection and v1/v2
  settlement schemas retain their existing meanings. The v3 settlement decoder
  accepts the exact new reply/error shapes; recovery checks its captured run
  mapping and request, retains paired terminals and rejects all v1/v2 rows after
  the first v3 settlement, including a retry or error-only cutover.
  Focused projection/replay checks pass 17 tests in 0.6 seconds on current and
  floor toolchains. Provider authority/accounting/ceiling/configuration/codec
  regressions pass 120 tests in 25.8 seconds; the retained complete output is
  `/private/tmp/loopex-m7-v3-reply-readers.log`, SHA-256
  `6b1cc4ec4bcf32122d7d32bdee11b514070a97e0f123e6aabeb868e335973a91`.
  Deliberately unproved provider-cleanup faults remain visible in that output;
  passing assertions do not resolve the separate Task.Supervisor T16 follow-up.
  This prepares readers before emission. The live writer still uses v2 and the
  historical callback projection; migrate it and every live fixture together
  before claiming complete v3 settlement or callback integration. Source-bound
  request envelopes, native transport, continuation accounting and ordinary
  reasoning registration remain pending.
- 2026-10-01: shared ContentReferences expansion implements the closed literal,
  text_ref and tool_use_ref union against canonical text and ordered arguments.
  Success requires complete UTF-8 text consumption, each call index exactly once,
  one absent ASCII top-level field and the declared open/closed call relation.
  Nested reference-shaped objects remain opaque. Incremental compact JSON counting
  enforces 16,384 bytes, depth/cardinality bounds and 128 blocks without allocating
  encoded JSON; expanded counting includes the complete capsule and separators.
  The adapter's pure NativeContent capture accepts exact native field sets,
  completed thinking signatures, redacted-thinking data and reference-only
  replies; it re-expands and compares the complete native array before return.
  Duplicate IDs, unknown fields, incomplete blocks and stop/call contradictions
  refuse the entire reply. Core configuration/genesis/expansion checks pass 40
  tests in 0.2 seconds; adapter mapping/catalog/native checks pass 19 in 2.3 seconds.
  Final current and floor Elixir/OTP checks each pass eleven expansion tests in
  0.2 seconds; native capture's numeric-encoder addition passes seven tests in
  0.08 seconds on current and 0.1 seconds on floor. Numeric cases match the
  adapter JSON encoder for floats and integers outside JavaScript's exact range.
  Exact-limit multi-block tests include wrapper/separator costs; 455 bounded
  nested/escape/Unicode variations match the existing compact JSON encoder.
  Current compilation and formatting pass; documentation covers 984 entries.
  This is codec evidence, not transport or ordinary reasoning registration.
  Source-bound aggregate envelopes, versioned reply/settlement integration,
  continuation accounting, bounded native streaming and mapping conformance
  remain pending; provider dispatch still uses the existing path.
- 2026-10-01: the private host-prepared configure path uses ordinary attachment
  routing and serial-owner fences. Duplicate lookup precedes candidate validation
  and exact prospective request measurement; configure dispatches no model or
  executor work. A transient minimum request uses retained lineage, immutable
  tools, candidate instructions/bounds and required resource metadata through the
  ordinary request/receipt/Store sizing path. Only history that can be removed
  reports compaction_required; an oversized empty-history minimum refuses the
  configuration. Neither probe becomes a durable run or an operator prompt.
  Runtime restart preserves the latest configuration and earlier run captures.
  Lost commit replies re-present exact proposal bytes before acknowledgement;
  owner crashes before/after linearization retain one version and the original
  disposition. A proved stale-owner non-commit requires a fresh logical ID under
  ADR 0006. Live configuration/admission checks pass 31 tests in 2.5 seconds;
  configuration, interaction, quiescence and journal-ownership regressions pass
  114 in 19.1 seconds with four prescribed long-bound exclusions. A mistaken
  input-test filename matched no file; the actual input algebra then passes all
  11 tests in 5.8 seconds. The earlier 88-test configuration/input/interaction
  run passes assertions in 18.5 seconds but emits Task.Supervisor
  shutdown_error/noproc diagnostics for Task.Supervised children. That separate
  manager/child cleanup investigation remains open under T16; the OwnerGroup
  fix does not establish its resolution. The supported floor pair passes the
  same 31 live configuration/admission tests in 2.4 seconds. Its cold dependency
  compilation emits existing TOML charlist deprecations; this is a focused test
  result, not a warning-free floor closure check. Current-pair project compilation
  and formatting pass; documentation ordering covers 979 entries.
  Host catalog/route preparation, the
  prepared daemon route, future checkpoint projection and maintenance quiescence
  remain pending, as do public /3-/4 contracts and real-provider conformance.
- 2026-10-01: a new orderly-shutdown regression using production bytes from
  `887b2141800416b2ddb5959030a07d9c05123d1b` fails after completed model work:
  9 of its 32 shutdowns report OwnerGroup shutdown_error/noproc. An empty-work
  probe had passed, so it was replaced with the actual completed-work trigger.
  The runtime-local OwnerGroups manager now uses Erlang's simple_one_for_one
  supervisor, whose parallel dynamic-child termination recovers the linked EXIT
  reason when a late monitor reports noproc. Control keeps pid-based temporary
  groups and the same predecessor-worker barrier; no error filter is added.
  The regression passes after the fix, and deterministic held-worker tests prove
  parallel group shutdown and continued reporting of real worker-supervisor
  faults. Configured runtime/quiesce/provider lifetime checks pass 48 tests in
  7.3 seconds; final owner-group/provider-attempt/agent-loop checks pass 173 in
  46.6 seconds. Ephemeral cleanup/lifecycle checks pass 25 in 15.1 seconds.
  Floor Elixir 1.18.5/OTP 27.3.4 owner-group/configured checks pass 18 in 2.0
  seconds. The shared OTP-29 Hex archive could not load on the floor; isolated
  Hex/rebar tooling under `/private/tmp/loopex-m7-floor-mix` enabled that run.
  These local checks resolve the observed cleanup defect; they do not replace
  M7's prescribed Linux load repetitions or the complete floor closure check.
  Final current-pair shutdown/configured tests pass 18 cases in 2.2 seconds
  with fault-log capture isolated from other test cases. Warning-free compilation
  and documentation ordering pass with 979 covered entries.
- 2026-10-01: configured ordinary staging now checks captured terminal-history
  capability before request construction or provider intent. Unsupported history
  retains an atomic unavailable v2 preparation-refusal/failed-terminal pair with
  cause canonical_history_rendering_unsupported, captured configuration/budgets,
  null scope and null observations. Replay derives the cause from the same retained
  lineage and refuses fabricated numbers, changed causes/configuration, added
  failure members and a missing paired terminal. A compatible fixture mapping
  continues with cancelled results intact. Context, input, interaction and
  configuration regressions pass 101 tests in 18.6 seconds. Other nonnumeric
  preparation causes, measured preparation failures, maintenance/headroom variants,
  real adapter conformance and coordinated wire projections remain pending.
  Final configured-runtime assertions explicitly prove no request or provider
  attempt opens for the refused run: 15 tests pass in 1.7 seconds. Compilation
  is warning-free; documentation ordering covers 978 entries. OwnerGroup
  shutdown_error/noproc diagnostics remain unresolved under T16.
- 2026-10-01: terminal-tool-history configuration preflight passes 45 focused
  conversation/configuration/configured-runtime tests in 1.6 seconds. A later
  run's completion cannot complete an earlier terminal tool turn; empty assistant
  messages do not fabricate a completion. Complete lineage is validated before
  inspecting the captured mapping capability. Recovered live cancelled-question
  history rejects an unsupported candidate, accepts a compatible captured mapping
  and rejects its substitution during replay. The compatible mapping is a fixture,
  not evidence about a real provider. Token/request-record preflight, projected
  checkpoint history, owner integration and ordinary provider-intent gating remain
  open. The existing generic invalid-session-configuration command refusal is
  retained; the named ordinary staging failure still needs its closed projection.
- 2026-10-01: pure configuration admission/replay, update, genesis, configured
  runtime, interaction and input regressions pass 88 tests in 17.9 seconds.
  Accepted configuration rows retain full instruction bytes once; their authored
  changes carry a checked version/digest descriptor, and replay reconstructs the
  original command preimage. Tampered candidates, command identities and
  settled-only refusal categories during active work are rejected. These prove
  reducer preparation only: owner history/request preflight, host resolution,
  maintenance quiescence, live configure and coordinated public wire remain open.
  The run still emits the separately tracked OwnerGroup shutdown_error/noproc
  diagnostics; passing assertions do not resolve that T16 investigation.
- 2026-10-01: the focused second-prompt regression executed one test and failed:
  the next request contains only the new prompt. This is a development red,
  not closure evidence. No provider call was made.
- T01 added subtasks: retain admission order through replay; choose lineage
  validation by the staged record/receipt generation; join results by complete
  run/turn/call identity; preserve old staged requests and old receipt decoders.

- 2026-10-01: conversation unit tests pass (12 tests, 0.08 seconds). The full
  agent-loop file passes 103 of 104 tests (24.7 seconds); the sole failure is
  the retained second-prompt regression. Admission-order recovery and promoted
  follow-up accounting tests pass. Compiled documentation ordering passes.
- Revision-1 normalized IDs bind `Canonical.encode([run_id, turn_number,
  tool_call_id])`; fixed r1/r2 vectors retain the exact 48-hex prefix. Source
  references keep the original run/turn/call identities. Historical projection
  retains its saved call IDs. Request/receipt generation integration remains.
- 2026-10-01: the affected conversation, agent-loop, context, skill, resource
  replay and project-trust suites pass 168 tests in 30.9 seconds. Input-algebra
  passes 11 tests in 5.7 seconds. The original second-prompt regression and a
  runtime-restart regression pass. These are development checks; real-provider
  and closure evidence remain pending.
- New requests bind v2 canonical bytes to revision-4 receipts and normalized
  committed lineage. Retained v1 requests and revision-2/3 receipts retain
  their historical validation. Generation mismatches, omitted/null-cost
  violations and self-consistent substituted history are rejected.
- T01 added subtask: derive missing cancelled/unknown results from committed
  terminal facts before promoting follow-ups; an uncertain effect must remain
  explicit in later context and must not be redispatched.

- 2026-10-01: candidate `34e840c64b865efd915ccbf2675db948d094bf0c` fast
  check failed four tests: two raw-call-ID assertions, the interaction old-reader
  positive control using newly staged v2 bytes, and a Pending-cell test reading
  the filled M6 closure page. All other application suites passed. Full output:
  `/private/tmp/loopex-m7-34e840c6-fast-check.log`,
  `sha256:7769090f45a10180b644872fc8d865fa3c0c6983ba737cbe6c83972b33fdcec2`.
- Corrected assertions verify normalized call/result joins. The actual M3
  reader still evaluates both positive and negative interaction controls, using
  explicitly encoded historical v1 staging and revision-2 receipts. The M6
  scaffold test reads the exact tested candidate `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`.
  Focused checks pass: core 35 tests in 23.6 seconds and composition 10 tests
  in 10.2 seconds. No historical evidence or reader behavior was changed.

- 2026-10-01: candidate `2d804649ca82ce87b58511bc0739c93e700c7559` fast check passed in
  842 seconds: 11 application suites, 2,638 passed tests. Full output:
  `/private/tmp/loopex-m7-2d804649-fast-check.log`,
  `sha256:47eb0c4b1c6c355e896adda494e82d05f0f6f772a6912df7cbdeaf0222053f7e`.
  Its exact identity is retained separately in
  `/private/tmp/loopex-m7-2d804649-fast-check.sha`. This is current-toolchain
  development integration evidence; the M7 closure matrix remains pending.

- 2026-10-01: shared `SessionGenesis.resolve/2` and `normalize/1` now own
  v2 creation/replay validation. They retain normalized legacy transaction bytes,
  require captured cleanup and closed inputs, and refuse non-plain data and
  normalized items above 65,536 bytes. Creation preserves its legacy malformed
  option and structural refusal taxonomy. Focused genesis/lifecycle/cancellation/
  timer tests pass 37 cases (31.6 seconds; one standard long-bound exclusion);
  runtime/detailed-result/fault/conversation tests pass 119 cases (24.8 seconds),
  and ephemeral API tests pass 15 cases (7.5 seconds). Compiled documentation
  ordering passes with 925 covered entries. The coordinated v3 decoder/writer,
  configuration and exact-genesis live facade remain unchecked.

- 2026-10-01: literal artifact-read revision 1 binds both complete generation
  triples to retained canonical preimages. Four released reference revisions
  share the legacy null capability; the planned 1.1.0 range definition has an
  explicit binding. Unknown read generations, duplicate selections and modified
  bindings refuse. Focused capability/genesis tests pass 12 cases in 0.04 seconds;
  compiled documentation ordering passes with 930 covered entries. Executor
  registration, live range retrieval and v3 genesis binding remain pending.

- 2026-10-01: pure instruction capture/render validation now implements ADR 0042's
  closed four-member input, ASCII version grammar, byte-counted UTF-8 section
  bounds and exact blank-line rendering. Captured section bytes retain the
  rendered SHA-256; replay validation rejects substitutions and extra members.
  Legacy staging uses the same immutable fallback bytes. Instruction/conversation/
  context tests pass 136 cases in 25.3 seconds; compiled documentation ordering
  passes with 936 covered entries. Host configuration, complete system costs and
  configuration-bound receipt provenance remain pending.

- 2026-10-01: the shared decoder now admits v3's complete closed genesis and
  derives its artifact capability from the selected generation. Name bindings
  must bijectively match retained tool definitions. Pure replay retains initial
  configuration, selection and policy-defer mode; v2 keeps its original bytes
  and no inferred selection/configuration. The configuration validator checks
  captured instructions, declared model/output limits, known/unknown/explicit
  input-budget origins, bounded capability metadata and closed provider mapping.
  The generic default descriptor cannot enable another reasoning level.
  System admission counts exact message and model-facing tool-schema costs.
  Decoder/instruction/capability tests pass 32 cases in 0.09 seconds;
  decoder/runtime/conversation/context tests pass 153 cases in 25.3 seconds.
  A corrected metadata-boundary fixture measures its actual canonical preimage;
  tightened generic-mapping and replay tests pass 21 cases in 0.1 seconds.
  Compiled documentation ordering passes with 938 covered entries. Live v3
  creation, provider mapping conformance, frozen run/configuration binding and
  configuration-aware request/receipt staging remain pending.

- 2026-10-01: host-private exact-genesis creation now retains supplied v2/v3
  bytes and normalized original options. Historical duplicates start no owner
  and bypass changed startup defaults/registrations; fresh v3 creation checks
  admitted definitions/model route and kernel request construction. New
  prompt_admitted_v3 and configured model_request_committed_v2/resource v2
  records bind the admitted configuration version. Follow-up promotion inherits
  the captured configuration. Requests use exact captured instruction text,
  model, reply allowance, provider mapping and immutable tools. Revision-4
  instruction provenance is checked against the owning configuration, including
  a self-consistent renamed-source negative case. Captured policy-defer refusal
  denies without an interaction or executor effect. Ordinary measured numeric
  context_admission_refused_v2 retains its own estimator, scope, configuration
  and hard limits; v1 keeps its original rules. Maintenance/headroom/nonnumeric
  refusal variants remain pending with compaction. Runtime/genesis/conversation/
  context tests pass 158 cases in 25.5 seconds; configured/context tests pass
  32 cases in 2.1 seconds, interaction coverage passes 27 cases in 12.3 seconds,
  and configured/detailed-result checks pass 15 cases in 0.6 seconds. Compiled
  documentation ordering passes with 941 covered entries. Full fast integration
  verification is next; reference-host composition, public schemas, provider
  conformance and the closure matrix remain pending.

- 2026-10-01: candidate `d46c8d10881e6ba811b6c1d5204c9545aa785d37` fast
  check passed in 852 seconds: 11 application suites, 2,679 passed tests and
  33 standard exclusions. Full output:
  `/private/tmp/loopex-m7-d46c8d10-fast-check.log`,
  `sha256:36f2a0b3fd02dd092f36a77b44695158066e69aa1ec528032385cc40b35cfc45`.
  Exact identity is retained separately in
  `/private/tmp/loopex-m7-d46c8d10-fast-check.sha`. This verifies the current
  toolchain development candidate; provider conformance, floor-toolchain checks,
  independent-client proof and the M7 closure matrix remain pending.

- 2026-10-01: reference-host `SessionInstructions` captures default, explicit
  base/appendix and role sections with ADR 0042's distinct versions. The existing
  protocol JSON encoder renders only closed workspace/platform/tool-profile
  facts, plus sorted enabled roles and their catalog digest when present.
  Exact escape/Unicode bytes and their independently calculated SHA-256 are
  pinned in tests; the complete escaped environment admits 4,096 bytes and
  refuses one byte more. The existing composition regular-file reader limits
  each selected section to its byte ceiling plus one, validates opened identity,
  and refuses nonregular or replaced files. Captures retain no paths and survive
  subsequent file edits. Focused host-instruction/ask-grammar tests pass 15 cases
  in 0.08 seconds; warning-free compilation and compiled documentation ordering
  pass with 945 covered entries. Configuration parsing, session-creation wiring,
  complete chat-profile system-cost targets and provider demonstrations remain
  pending. No full integration check is claimed for this new checkpoint.

- 2026-10-01: host `ConfigJson` uses OTP 27's standard-library callbacks rather
  than adding a dependency or another syntax parser. It retains ordered object
  members until duplicate validation, emits RFC 6901 pointers, preserves full
  integer precision, and gives fraction/exponent syntax an internal noninteger
  marker for schema refusal. Byte/UTF-8 checks precede parsing; exception details
  and authored values never enter errors. Exact 256-KiB, nesting, surrogate,
  escaped-duplicate and trailing-byte vectors pass on the current toolchain and
  directly under Elixir 1.18.5/OTP 27 (8 tests, 0.04 seconds). This is focused
  floor evidence, not the floor integration or closure matrix.
- Shared `ProviderBindings` validates the complete closed route map against the
  adapter's compiled catalog and refuses operational slots before custody or
  environment effects. It retains references and derives sorted unique launch
  exclusions, including the legacy key. Existing Ollama admits credential-free
  references; credentialed routes require named slots. Focused binding/durable
  option checks pass 21 cases in 6.2 seconds; JSON/instruction/ask-grammar checks
  pass 23 cases in 0.07 seconds. Warning-free compilation, formatting and compiled
  documentation ordering pass with 950 covered entries. File schema, CLI
  inspection, actual custody loading, durable route dispatch and full integration
  verification of these new bytes remain pending.

- 2026-10-01: `ConfigSchema` validates every authored version-1 object before
  overrides: required bounds/policy/routes, closed optional fields, role and
  delegation references, explicit context ceilings and bounded trace settings.
  Turn/token spending bounds preserve integers above uint64; deadlines, cleanup
  and context values retain their existing uint64 domains. Disabled delegation
  and tracing still validate supplied values. Policy names reuse the existing
  ask registry. Trace selectors resolve only exact trusted application-manifest
  modules and the two application wildcards; existing lookalike atoms confer no
  membership, unknown input creates no atom, and metadata reads start no app.
- `ConfigFile` reads one selected regular file through the existing bounded
  reader, validates JSON/schema before resolution, and retains authored/resolved
  profiles separately. Config-relative paths preserve literal tilde/environment
  text and symlink-sensitive parent components; resolved paths also obey the
  4,096-byte ceiling. Prompt files, credentials and configured services are not
  opened by this stage. Focused schema/file/selector/JSON/instruction/ask-grammar
  checks pass 50 cases in 0.1 seconds. Warning-free compilation, formatting and
  compiled documentation ordering pass with 956 covered entries. Model-window
  and reasoning-support resolution, complete effective-profile validation,
  command grammar/inspection and live creation remain pending. This checkpoint
  has no new full integration or closure-matrix result.

- 2026-10-01: `ConfigOptions` parses the three accepted command forms and the
  complete override inventory. Config is required; show also requires effective.
  Inspection refuses every trace flag and resume. Chat rejects duplicate scalar
  flags and conflicting trace booleans; repeated skill/module selections retain
  order and their accepted item ceilings. No provider flag, implicit model,
  positional prompt or new authority default is introduced. Models/policy/trace
  selectors reuse the admitted registries. Decimal values preserve exact large
  turn/token spending integers while deadline/context/cleanup fields retain
  uint64 and trace fields retain the existing ceilings. Structural errors precede
  value checks and errors never echo authored values. Focused options/schema/
  ask-grammar tests pass 32 cases in 0.08 seconds; all connected configuration
  prerequisite files pass 59 cases in 0.1 seconds. Warning-free compilation,
  formatting and compiled documentation ordering pass with 958 covered entries.
  Effective-profile merging, command dispatch/inspection and live chat remain
  pending; no full integration result is claimed for these new bytes.

- 2026-10-01: `ConfigSelection` composes new-session declarations after checking
  the authored and resolved file schemas. Explicit flags win over the supplied
  LOOPEX_HOME state root, then file values, then harmless literal defaults.
  Flag/environment paths are invocation-relative and preserve literal tilde/env
  text; selected arrays replace file arrays and remove obsolete indexed origins.
  Every selected leaf retains flag/env/file#pointer/default provenance. No
  policy/provider/spending default or committed origin is invented; absent
  context budgets remain unresolved and maintenance never inherits a model.
  No-helpers narrows delegation without replacing authored role/allowance data.
  Resume refuses this new-session composition path, pending committed-profile
  preparation. Invalid authored values cannot be repaired by flags. Focused
  selection/options/file tests pass 26 cases in 0.1 seconds; all connected
  configuration prerequisite files pass 70 cases in 0.2 seconds. Warning-free
  compilation, formatting and compiled documentation ordering pass with 960
  covered entries. Model-capability/reasoning admission, authored/effective
  prompt capture and whole-request preflight, redacted inspection, command entry
  and live chat remain pending. No new full integration result is claimed.

- 2026-10-01: adapter `ModelCapabilities` reads the pinned embedded LLMDB
  snapshot directly and verifies its checksum and exact identity before
  capturing bounded context/output limits. Mutable catalog filters, overlays
  and cold loading do not select inspection metadata. The literal Haiku alias
  selects its dated identity; other aliases remain unregistered. Unknown limits
  stay nil, and the reasoning subset remains empty pending deterministic
  mapping conformance. Four focused tests pass in 2.2 seconds, covering three
  known model limits, alias behavior, unknown limits, source bindings and
  malformed specifications. Provider dispatch and whole-profile admission remain
  pending; no provider call or full integration result is claimed.

- 2026-10-01: `SessionConfiguration.resolve/4` prepares a complete initial
  configuration from closed explicit host selections, captured capabilities,
  provider mapping and all selected definitions. Known windows subtract the
  reply reserve once; unknown windows retain 8,192 input tokens independently
  of reserve. Explicit ceilings remain explicit even when equal to defaults.
  The existing complete validator enforces output/window limits, the strict
  combined instruction/tool-schema cost and bounded retained metadata. The v3
  suite passes 20 tests in 0.1 seconds, including six resolution cases and exact
  genesis rejoin. Warning-free compilation, formatting and compiled documentation
  ordering pass with 963 covered entries. Reference-host preparation/inspection
  and live chat remain pending; this is focused development evidence, not a full
  integration result.

- 2026-10-01: `ToolDefinition` admits only the exact reviewed `loopex.ask`
  interaction definition under format v2. Absent class retains effect semantics,
  format v1 and unchanged canonical fields. Interaction declarations are never
  narrowed or completed. The retained vector pins full definition, canonical
  preimage and digest
  `d8cfe746ca4834f2ceabcfb5fa717fa8f53ba06461ee3ae91499fdfad25e138e`.
  Closed question arguments enforce UTF-8 byte limits, optional nonempty
  choice lists and distinct labels before policy. The coordinator rejects the
  executor path for interaction definitions and classifies model-question policy
  defer as policy_unavailable without a nested interaction. Policy allow still
  returns interaction_unsupported until pending/answer/terminal truth is joined;
  no successful model-question workflow is claimed. Protocol definition tests
  pass 14 cases in 0.09 seconds; configured-runtime and registry tests pass 15
  cases in 0.7 seconds. Warning-free compilation, formatting and documentation
  ordering pass with 965 covered entries. Runtime test output also contains
  supervisor shutdown_error/noproc diagnostics, retained as a T16 follow-up;
  passing assertions do not establish cleanup-diagnostic correctness. No provider
  call or full integration result is claimed.

- 2026-10-01: model-question policy allow now commits a producer-specific pending
  request, bound to the exact original call, argument digest, derived question
  and earlier run deadline. A single response row admits the command, settles
  the interaction and original result, releases the slot and advances work.
  Text, choice and decline remain distinct branches; expiry and abort settle
  without a policy reevaluation or executor job. Legacy policy rows cannot
  resolve model questions, and standalone result/intent rows cannot bypass an
  open model question. Pending replay rejects substituted arguments, request
  members, producer, call identity, turn and expiry.
  Configured-runtime, policy-interaction and v3-genesis tests pass 52 cases in
  12.4 seconds, including an exact 8,192-byte UTF-8 answer, duplicate/conflicting
  and stale responses, expiry-boundary admission and atomic abort settlement.
  The broader loop, cancellation, input-algebra and journal suites pass 161
  cases in 72.6 seconds. Final response-identity event assertions and legacy
  interaction checks pass 32 cases in 12.4 seconds. Warning-free compilation,
  formatting and documentation ordering pass with 968 covered entries.
  Supervisor shutdown_error/noproc diagnostics remain an
  unresolved T16 follow-up. Crash injection, private/public wire vectors and
  one-call responder integration remain pending; no provider or full integration
  result is claimed.

- 2026-10-01: four owner-crash scenarios hold the actual Store immediately before
  or after model-question pending and response commits. Killing the coordinator
  and resuming the same session preserves the committed pending identity and
  expiry, emits one answer and original tool result, and dispatches only the
  next model turn. Retained committed proposal payloads compare byte-for-byte;
  pure replay ends with the same answer and no open slot. No executor job runs.
  The pre-response-commit case proves the old transaction's terminal stale-owner
  non-commit and immutable-ID conflict, then settles with a fresh command ID as
  accepted ADR 0006 requires. The post-response-commit case replays the original
  command acceptance without another settlement. Configured-session tests pass
  13 cases in 1.5 seconds. This is in-memory Store fault injection and live owner
  succession; local-store process restart, ambiguous commit injection and wire
  vectors remain separate obligations. Cleanup diagnostics remain open under T16.

- 2026-10-01: pending-question and response commits each encounter an injected
  after-linearization reply loss. The owner resolves the same immutable proposal
  before acknowledgement or further work; retained payloads equal the original
  proposals, question/answer events each occur once, and provider dispatch is
  unchanged while the transactions are held. A composition test stops and
  reopens the real disk-backed local Store twice, first with a pending question
  and then with its settled choice answer. Pending identity, expiry, choices,
  command acceptance and the exact chosen label survive; no executor job runs
  and the already completed model turn never repeats. Both suites share the
  same captured-v3-genesis fixture rather than separate configuration examples.
  Configured-runtime, legacy interaction and v3-genesis checks pass 54 cases in
  13.0 seconds; local-store restart passes one case in 0.2 seconds. Formatting,
  warning-free compilation and patch checks pass. This is focused development
  evidence, not a VM/OS restart, real-provider or full integration result.
  T16 cleanup diagnostics and T09 decoder/public-event vectors remain pending.

- 2026-10-01: `Session.Answer` centralizes the closed choice/text/decline response
  union. Core command normalization and producer-specific answer validation use
  it while retaining old flat choice admission and normalized choice-command
  digests. Literal answer schema and 20 language-neutral vectors cover opaque
  identities, UTF-8 text, decline, mixed/unknown members, padding and malformed
  identity strings. Exact decoded identity and UTF-8 byte limits are checked by
  both implementations; encoded identities are bounded before decoding. The
  independent Node decoder deliberately matches the inherited base64 decoder's
  unused-bit behavior. Five answer tests including the pinned Node payload
  runner pass in 0.07 seconds; configured questions, legacy policy answers and
  input-algebra checks pass 45 cases in 17.9 seconds. Compilation, formatting
  and documentation ordering pass with 972 covered entries. No live server
  generation or method changed: accepted M7 requires one coordinated switch
  containing complete configuration, compaction, bounds and question schemas.
  These are payload checks, not live transport, authority or privacy-canary proof.

- 2026-10-01: `SessionConfiguration.update/5` prepares the complete next candidate
  from committed configuration, a nonempty closed mutable subset and separate
  host-resolved capability/mapping facts. Internal version, metadata, tools and
  maintenance fields cannot be authored. Derived input budgets recompute from
  the new captured window and reserve; explicit ceilings remain explicit even
  when equal to defaults. Unknown windows retain the independent 8,192 input
  fallback, and legacy system origin retains 1,000. Complete validation checks
  captured instructions, all immutable tool schemas, known limits, metadata and
  reasoning compatibility before returning a candidate. Version overflow and
  invalid or oversized updates refuse without changing the committed input.
  Update, v3-genesis and configured-runtime tests pass 42 cases in 1.6 seconds;
  final bounded-update/genesis checks pass 28 cases in 0.1 seconds. Owner settled
  admission, exact history/request preflight, atomic record/replay and live
  configure remain pending. No catalog lookup, model call or compaction occurs
  during pure preparation.

## T00 — Prepare the specifications and test fixtures
- [ ] Inventory every affected record, API, tool generation, adapter and protocol.
- [x] Map the 22 accepted contract families to implementation owners and retained/new generations.
- [ ] Join that family inventory to exact payload schemas, path inventories and decoder vectors.
- [ ] Pin schema definitions, digests, compatibility vectors and provider mappings.
- [x] Pin legacy and planned M7 read-definition canonical preimages/digests and the revision-1 literal artifact-read capability table.
- [ ] Create the M7 fixture manifest with exact prompts, budgets, allowed changes and objective results.
- [ ] Assign every operator step and negative scenario to a named test or demonstration.
- [ ] Prepare the indexed closure-evidence scaffold with results marked Pending.
- [ ] Retain the exact historical binaries and session roots needed for migration and rollback.
- [ ] Verify manifest completeness, invalid-manifest rejection and actual instruction/tool-schema costs.
## T01 — Preserve conversation across prompts and restarts
- [x] First add a failing test reproducing the current loss of earlier conversation.
- [x] Project the complete committed conversation into subsequent model requests.
- [x] Join tool calls and results using their run, turn and call identities.
- [x] Normalize provider-facing call IDs and reject collisions or incomplete joins.
- [x] Reset each run’s accounting without deleting conversation or recovery facts.
- [x] Preserve already staged requests unchanged.
- [ ] Test multiple prompts, follow-ups, tools, cancellation, failed runs, restart and uncertain commits.
## T02 — Handle large tool output and bounded artifact reads
- [ ] Prepare bounded excerpts while retaining complete original results.
- [ ] Implement capability checks from the exact frozen tool definitions and literal capability table.
- [x] Implement and test pure exact-generation derivation and retained-binding validation; runtime selection and executor dispatch integration remain pending.
- [ ] Keep replay independent of current host-registry availability.
- [ ] Validate artifact ownership and arguments in the session owner before policy admission; add resolved executor data after approval.
- [ ] Implement 4-KiB range reads, encoded-result limits, offsets, progress and EOF.
- [ ] Add bounded preparation, aggregate excerpt allocation and job-owned transfer accounting.
- [ ] Preserve legacy inline behavior where the complete request fits.
- [ ] Test escaping, Unicode, forged references, cross-session access, digest mismatch, exhaustion, cancellation and recovery.
- [ ] Audit the existing attachment-budget baseline without silently taking on deferred M8 work.
## T03 — Implement host-composed instructions
- [ ] Replace core’s fixed instructions with the accepted host instruction map and rendering.
- [x] Implement pure closed instruction capture, exact rendering and retained-digest validation; preserve legacy fallback bytes through the shared renderer.
- [x] Stage captured v3 instructions with configuration-bound revision-4 provenance and exact system/tool costs; reject substituted configuration/source identities on replay.
- [x] Implement reference-host default/explicit/role capture, bounded regular-file reads and exact JSON environment byte/digest vectors; live configuration/chat wiring remains pending.
- [ ] Keep project and skill resources separately typed and admitted.
- [ ] Capture workspace/environment facts and exact selected tool schemas.
- [ ] Enforce the configured system ceiling and complete serialized-request limit.
- [ ] Implement receipt revision 4, including continuation costs and source/configuration binding.
- [ ] Preserve old receipt decoding.
- [ ] Test admitted, declined, changed and oversized instructions, long paths, restart and exact staged bytes.
- [ ] Prove instructions cannot widen policy or helper authority.
## T04 — Implement configuration, genesis and provider routing
- [x] Implement the shared pure genesis resolver and validator.
- [x] Share the v2 resolver/decoder between creation and replay; pin unchanged transaction bytes and exact normalized byte boundaries.
- [x] Extend that same resolver/decoder with v3 configuration, immutable tool selection and literal artifact-read derivation.
- [x] Validate closed captured configuration, combined metadata byte limits, budget origins and complete system-class tool costs; retain v3 settings through pure replay.
- [x] Resolve complete initial configurations through that validator, deriving known/unknown context budgets and retaining explicit/default origins.
- [x] Integrate v3 creation and configuration-aware live owner staging, including frozen request/receipt identities.
- [x] Support exact-genesis creation, finding duplicates before expanding changed defaults.
- [ ] Implement the closed configuration-file schema and command-line grammar.
- [x] Implement bounded JSON syntax decoding with exact integers, redacted errors and duplicate-key JSON pointers; prove callbacks under both supported toolchains.
- [x] Implement shared pure provider-binding/reference validation and sorted launch exclusions from the adapter's compiled catalog; environment resolution/custody/startup integration remains pending.
- [x] Validate closed authored-file objects, required conversation bounds, role/route/delegation relationships, explicit context ceilings and trace limit domains before overrides.
- [x] Load bounded selected regular config files, retaining authored/resolved profiles with config-relative literal paths and resolved byte bounds; prompt-file and effective-profile admission remain later stages.
- [x] Resolve trace selectors through fixed trusted application-module manifests without input atom creation or application startup; owning trace startup/drain/teardown integration remains pending.
- [x] Parse the complete chat/config-inspection flag grammar with duplicate/conflict refusal, bounded array overrides, exact numeric domains and shared registries; effective-profile and command-entry integration remains pending.
- [ ] Implement file/flag precedence, validation and effective-value display.
- [x] Compose new-session file/flag/LOOPEX_HOME precedence and harmless literal defaults with complete value origins and array replacement; capability/instruction admission and redacted effective display remain pending.
- [ ] Require explicit conversation bounds in the file, including when flags override them.
- [ ] Retain committed session settings, tool selections, roles and delegation declarations.
- [ ] Allow maintenance settings to change new episodes while preserving already admitted episodes.
- [ ] Implement named provider and credential bindings through the existing custody boundaries.
- [ ] Abandon prepared owners on every post-preparation refusal; retain uncertain cleanup honestly.
- [ ] Test malformed files, duplicate keys, overrides, resume conflicts, missing bindings, changed catalogs and cleanup failures.
- [ ] Prove configuration inspection reads no credentials and starts no runtime or provider call.
## T05 — Update records, protocols and independent clients
- [ ] Implement every new record/request generation before emitting it.
- [ ] Add foreground protocol /3 and daemon protocol /4.
- [ ] Produce complete payload-schema manifests and reproducible digests.
- [ ] Update both servers and the independent Node clients together.
- [ ] Update daemon mutation, capacity, lease and succession inventories.
- [ ] Implement bounded snapshots and events with consistent replay cursors.
- [ ] Preserve numeric domains without JavaScript rounding or narrowing.
- [ ] Test negotiation order, malformed offers, digest mismatches, old clients, authority checks and replay.
- [ ] Verify private thinking, credentials and host-only data never enter public projections.
- [ ] Run the required independent-client workflows.
## T06 — Build the first complete chat workflow
- [ ] Add loopex chat through the existing session/runtime facade.
- [ ] Join explicit configuration, continuity and instructions.
- [ ] Support prompts, status, wait, abort, bounded output and truthful shutdown.
- [ ] Prove two prompts and restart through the built command.
- [ ] Preserve existing ask, durable-run and embedded workflows.
- [ ] Test startup refusal, admission failure, output and cleanup.
- [ ] Later retain the required attended multi-prompt proof.
## T07 — Implement automatic and explicit compaction
- [ ] Select complete eligible conversation groups.
- [ ] Protect open exchanges and their complete native prefixes from compaction or re-rendering.
- [ ] Have the owner select and encode bounded source excerpts; have the model produce the summary.
- [ ] Capture maintenance model, route, instructions, deadlines, origin and targets before dispatch.
- [ ] Distinguish missing summarizer configuration from invalid configuration.
- [ ] Require complete natural termination, valid output, size limits and progress before committing a checkpoint.
- [ ] Implement bounded attempts, refusal records, terminal ordering and standalone compact results.
- [ ] Resolve uncertain checkpoint commits before publication and charge usage once.
- [ ] Test oversized oldest/newest groups, small problematic groups, trailing inputs, omitted content, length stops and non-progress.
- [ ] Inject crashes around preparation, staging, settlement, checkpoint and publication.
- [ ] Prove automatic compaction, explicit compaction and restart preserve the required facts.
## T08 — Implement model selection and private thinking continuation
- [ ] Implement committed per-run model/reasoning configuration and the permitted configure fields.
- [x] Prepare closed whole-candidate mutable updates with bounded inputs, monotonic versions and retained explicit/derived budget origins.
- [x] Prepare atomic configuration admission/replay with exact command identity, single-copy instructions, retained earlier run captures and public event allowlists.
- [x] Gate prepared configuration admission/replay on captured terminal-tool-history capability, preserving empty-completion and cross-run semantics.
- [x] Gate ordinary configured provider intent on terminal-history capability and retain the unavailable v2 preparation-failure pair without fabricated observations.
- [x] Join prepared ordinary candidates to settled owner admission, exact retained-history preflight, atomic commit and replay.
- [x] Prove configuration restart, commit-unknown re-presentation and owner crashes before/after linearization through the live runtime.
- [ ] Join host resolution and prepared daemon routing; extend configuration preflight to committed checkpoints and maintenance quiescence.
- [x] Capture bounded limits and source bindings from the exact pinned packaged catalog without mutable lookup; preserve unknown limits and the literal accepted alias.
- [ ] Join registered reasoning subsets to completed deterministic mapping conformance and whole-profile preparation.
- [ ] Implement the exact adapter replies, canonical replies and monotonic settlement generations.
- [x] Prepare exact v2/v3 callback projection, source-bound v3 settlement readers and monotonic historical-prefix recovery before writer migration.
- [x] Emit v3 for every new ordinary settlement, migrate exact callback fixtures, and prove whole-record accounting, required-capsule admission and historical schemas through live recovery.
- [x] Implement bounded in-capsule reference expansion, with no artifact substitution or external lookup.
- [x] Implement pure exact native-array capture and reconstruction through the shared expander, with closed fields and stop/call relations.
- [ ] Preserve expanded native blocks, strings, ordering, IDs and parsed arguments.
- [ ] Implement continuation accounting, reserves and compaction headroom targets.
- [ ] Implement all nine accepted thinking cells and the separately configured summarizer.
- [ ] Build the native transport bridge: validate final requests after hooks, capture before conversion, and preserve admitted controls and ceilings.
- [ ] Bound raw streaming/parser buffers; implement fatal-error latching, flushing and wakeup.
- [ ] Test the bridge against a local HTTP server before integrating live-provider proofs.
- [ ] Test model switching, crashes, cancellation, malformed replies, overflow, usage accounting and privacy.
- [ ] Complete the seven thinking-round subcases, nine bound subcases and cancellation witness, including their prescribed subsequent prompts.
## T09 — Implement model-originated questions
- [x] Register the exact question-tool generation without changing old effect definitions.
- [x] Pin its format-v2 canonical preimage/digest and enforce exact schema/byte/choice limits before policy.
- [x] Separate interaction tools from executor dispatch and reject nested policy defer.
- [x] Replace the interim policy-allow refusal with committed model-question pending and producer-specific terminal transitions.
- [x] Admit questions through policy; no executor grant or job is created.
- [x] Implement producer identity, options, text answers, decline and expiry.
- [x] Atomically settle the interaction, original tool result, response identity and next action.
- [x] Preserve the existing policy-defer lifecycle.
- [ ] Test denial, deferred policy, large answers, overflow, duplicate/stale responses, cancellation and expiry.
- [x] Test crashes before and after pending-question and response commits.
- [x] Prove pure recovery retains the actual committed pending question identity.
- [x] Prove live owner restart retains that identity and settles it once.
- [x] Prove commit-unknown re-presentation retains exact pending and response bytes.
- [x] Prove local-store process restart retains the pending question and final answer.
- [ ] Pin pending/response decoder vectors and public question event schemas.
- [x] Pin the shared closed answer schema/union and independent Elixir/Node payload vectors.
- [ ] Join that answer schema and decoder to the complete M7 /3-/4 contracts and both authorized mutation paths.
## T10 — Complete chat controls, pipes and tracing
- [ ] Implement steer, follow-up, answers, decline, wait, interrupt, configure, compact and exit commands.
- [ ] Implement the exact pipe grammar and closed control records.
- [ ] Enforce record limits, bounded input admission, the 256-KiB output queue and control-drain deadline.
- [ ] Implement the unknown-admission resolver using the original transaction identity and proposal.
- [ ] Preserve input ordering while admission is uncertain; do not submit duplicate commands or fenced aborts.
- [ ] Make EOF, incomplete fragments, earlier failures and uncertain cleanup produce the specified outcomes.
- [ ] Implement tracing through flags and files, including enable/disable and owner cleanup.
- [ ] Add the independently draining diagnostic consumer with drop and unconfirmed-delivery accounting.
- [ ] Test PTYs, fragmented pipes, actual question IDs, barriers, slow readers, EOF and signals.
- [ ] Test tracing isolation, redaction, stalled stderr and ask’s JSON output separation.
## T11 — Implement specialized read-only helpers
- [ ] Implement saved roles with exact instructions, models, credentials and finite allowances.
- [ ] Register the opt-in helper tool and immutable read-only tool selection.
- [ ] Add the required read-only runtime/store provenance and effect-intent queries.
- [ ] Implement exact create-result lookup and retain genesis before child creation.
- [ ] Implement parent bindings, catalogs, allowance ledgers, stop records and receipt routing.
- [ ] Implement bounded private codecs, framing checks, writer fencing and reserved completion space.
- [ ] Enforce one unresolved helper per parent while allowing independent parents to progress.
- [ ] Charge attempted reservations conservatively; only the specified pre-effect refusals consume nothing.
- [ ] Implement bounded startup classification of all committed creates, including helpers-disabled startup.
- [ ] Guard existing attachments and settled child sessions against ordinary host mutations.
- [ ] Validate cache coverage, remove refused registrations and handle interrupted publication.
- [ ] Recover completed results and stop unfinished helpers; recovery must never create or re-prompt them.
- [ ] Test read-only authority, nesting refusal, budgets, concurrent parents, cancellation and exhausted-call reopening.
- [ ] Inject faults at every binding, reserve, create, prompt, stop, settlement, receipt and cache boundary.
- [ ] Prove both role demonstrations with unchanged child workspaces and separate/combined usage.
## T12 — Complete ephemeral support
- [ ] Forward accepted instruction, model, reasoning, provider-binding, maintenance, question and trace options.
- [ ] Preserve reusable embedded sessions and buffered transport.
- [ ] Keep questions opt-in and preserve old tool selections.
- [ ] Implement tagged choice, text and decline answers.
- [ ] Consume the question responder only in the one-call API; reject unsupported combinations.
- [ ] Run one monitored responder worker outside the serial owner.
- [ ] Join responder termination before another question or successful cleanup.
- [ ] Test blocked, invalid, failed and late callbacks, cancellation, expiry and cleanup uncertainty.
- [ ] Preserve the existing credential and transport-cleanup guarantees.
- [ ] Complete the attended ephemeral-question witness.
## T13 — Complete coding fixtures and operator instructions
- [ ] Implement the repair fixture and its independent sum assertions.
- [ ] Implement the feature fixture requiring the nil-encoding question.
- [ ] Implement the review fixture with the exact duplicate-fee finding and call chain.
- [ ] Implement the long fixture preserving the required facts through compaction and restart.
- [ ] Implement the trusted fixture wrapper and exact approved test-command policy.
- [ ] Let the agent run approved tests; independently rerun immutable oracles and inspect allowed changes.
- [ ] Pin and execute the maintainer-selected external repository task.
- [ ] Make every V1–V13 instruction runnable, with one owner and evidence slot per step/subcase.
- [ ] Complete the specified human-attended steps with a named operator.
- [ ] Collect previous executions without adding extra model attempts.
## T14 — Implement attempts tracking and evidence validation
- [ ] Implement the canonical, hash-chained attempts index and fsync-before-dispatch.
- [ ] Implement single-writer ownership and safe evidence handoff between machines.
- [ ] Implement all attempt states, verdict classes and legal transitions.
- [ ] Handle missing, corrupted or incomplete evidence as unavailable.
- [ ] Implement pre-dispatch-only continuation without redispatching completed work.
- [ ] Implement suspended-lane abandonment and committed index-head barriers.
- [ ] Enforce causal corrections and independent outage review; a new SHA alone permits no reroll.
- [ ] Add the M7 evidence validator to the existing two check commands.
- [ ] Implement M7 lane selectors while preserving all legacy cases.
- [ ] Test truncation, forks, duplicate writers, interrupted handoff, resume, abandonment, redaction and every verdict route.
## T15 — Prove migration and rollback
- [ ] Upgrade exact settled and unresolved M6 roots without changing staged requests.
- [ ] Prove unknown effects are not redispatched.
- [ ] Observe the actual historical reader against disposable new-format roots.
- [ ] Preserve the existing v0.2.0↔v0.3.0 rollback proof.
- [ ] Add the separate v0.3.0↔M7 proof.
- [ ] Implement access-prevention and complete backup-restore instructions.
- [ ] Restore into an empty root and compare complete manifests.
- [ ] Restore workspace state separately from runtime state.
- [ ] Join automated rollback artifacts to attended restore inspection without rerunning the case.
## T16 — Complete integration and regression checks
- [x] Move M7 to In progress when product work begins.
- [ ] Keep outcome rows linked to actual tests and evidence.
- [ ] Update operator/developer documentation, indexes, compatibility guidance, README, roadmap and changelog.
- [ ] Update verification guidance to the accepted M7 procedures.
- [ ] Run focused unit, property, conformance, fault, security, protocol and CLI tests during development.
- [ ] Run the fast check once per clean integration candidate.
- [ ] Run required selected real-provider, Node, daemon, long-bound and cross-UID lanes.
- [ ] Run changed process-boundary cases thirty times under the prescribed pinned Linux load.
- [ ] Independently review integration changes and fix confirmed defects without weakening checks.
- [x] Investigate and fix OwnerGroup supervisor shutdown_error/noproc diagnostics observed in configured-runtime test cleanup; retain failing-before and process-lifetime evidence independently of passing assertions.
- [ ] Investigate Task.Supervisor shutdown_error/noproc diagnostics for Task.Supervised children in configuration/input/interaction cleanup; retain reproduction and actual task-lifetime evidence.
## T17 — Assemble and test the closure candidate
- [ ] Provision both supported toolchains, pinned Node, provider bindings and the legacy Ollama witness.
- [ ] Provision Linux cross-UID support, descriptor limits, retained evidence storage and attendance.
- [ ] Finish all source, fixtures and documentation before committing the tested candidate.
- [ ] Move the candidate to In review with complete proof mappings and Pending evidence slots.
- [ ] Verify main is an ancestor.
- [ ] Count the existing current-toolchain fast check; run the floor-toolchain check.
- [ ] Run the full logical release matrix in its fixed order.
- [ ] Complete every M7 case, subcase and operator evidence join.
- [ ] Retain outputs, manifests, usage, sizes, durations, failures and independent review with digests.
- [ ] Present the exact candidate for the maintainer’s closure decision.
## T18 — Close M7 and merge back into main
- [ ] Obtain explicit closure approval on the tested candidate and evidence.
- [ ] Create the administrative direct child confined to the five permitted paths and regions.
- [ ] Record both tested and administrative identities correctly.
- [ ] Verify confinement and status transitions.
- [ ] Fast-forward main to the administrative closure commit under the maintainer’s integration authority.
- [ ] Push and verify the resulting repository state.
- [ ] Clean up landed worker branches/worktrees; retain m7 through implementation and decide its disposition after closure.
## T19 — Prepare and publish the separately authorized release
- [ ] Select the release label before testing any version-dependent source changes.
- [ ] On the administrative SHA, prove confinement, documentation structure and documentation meaning.
- [ ] Compare tested and administrative source archives using the required complete manifests.
- [ ] Validate modes, paths, source identities and permitted exclusions.
- [ ] Create the authorized annotated tag at the administrative SHA.
- [ ] Push the authorized tag/publication and verify its target.
- [ ] Reuse unchanged-source closure evidence; do not rerun the suite or provider matrix.
The required test inventory includes 28 named M7 cases, their fixed thinking/question subcases, deterministic negative tests, all 13 operator scenarios, the retained legacy release cases, independent Node workflows, process-boundary load tests and both rollback pairs.

## T00 contract inventory

Accepted contracts mapped to implementation owners. This inventory records
required joins; exact payload vectors and fixture manifests remain separate
unchecked T00 obligations. New readers/writers must rejoin these contracts
before a provider demonstration.

| Boundary | Authority | Retained/new generation | Implementation owners | Status |
| --- | --- | --- | --- | --- |
| Conversation and result joins | ADR 0041 | Run/turn/call identity; admitted lineage order; revision-1 normalized IDs | Conversation; SessionState; SessionCoordinator | Implemented; broader boundary vectors remain |
| Tool-output preparation | ADR 0041 | Immutable receipt plus versioned prepared-reference/preparation-state facts and exact source digests | SessionState; SessionCoordinator; ArtifactStore; local executor | Pending |
| Artifact read capability | ADR 0041 | loopex.artifact_read.v1 binding from literal tool-generation table; resolved executor arguments | ToolDefinition; SessionGenesis; local read tool; SessionCoordinator | Pending |
| Instruction envelope | ADR 0042 | Closed version/base/environment/appendix map, exact rendered bytes/digest | SessionGenesis; configuration reducer; host composition | Pending |
| Context receipts | ADRs 0042–0044 | Old revisions 2/3 unchanged; new 4 has mandatory continuation_cost and frozen source bindings | SessionCoordinator; SessionState; ContextAdmission | Nil-continuation and owning-instruction bindings implemented; maintenance/continuation bindings pending |
| Context refusals and failures | ADR 0043 | Old context_admission_refused_v1 preserved; v2 configurable ceiling and new failure union | ContextAdmission; SessionState; protocol projections | Ordinary measured numeric v2 and unavailable terminal-history preparation failures implemented; other causes, maintenance/headroom and wire projections pending |
| Initial session truth | ADRs 0044/0046 | Read v2/v3 genesis; write coordinated closed v3 configuration/tool-selection/policy-defer payload | Runtime.Control; SessionGenesis; SessionState; Store conformance | Pure decoder/replay and host-private v3 creation implemented; reference-host writer and migration proof pending |
| Exact create and provenance | ADR 0046 | Pure resolve/normalize; exact-genesis create/lookup; read-only creation provenance and stable ordinals | Runtime facade; Control; Store adapters/conformance | Pure helpers and live exact create implemented; exact lookup/provenance pending |
| Atomic configuration | ADR 0044 | Settled configure command; immutable selection; captured version/model/bounds/metadata/mapping | SessionState; SessionCoordinator; composition; protocol | Pure preparation and live ordinary atomic admission/replay, retained-history sizing, restart and commit-boundary faults implemented; host resolution, prepared daemon routing, checkpoint projection and maintenance quiescence pending |
| Model request | ADR 0044 | Read v1/v2; new v2 local-reference continuation with generic expansion | Model; SessionState; SessionCoordinator; model adapters | v2 nil-continuation writer/read compatibility implemented; expansion pending |
| Model reply and settlement | ADR 0044 | Bounded reply v3; model_attempt_settled_v3; atomic reply/continuation/accounting | Model; ProviderAttempt; SessionState; adapters | Capsule expansion, native capture, strict callback projection and source-bound v3 readers/writer implemented with migrated callback fixtures; native adapter emission, request envelopes and continuation accounting pending |
| Thinking mappings | ADR 0044 | Fixed nine registered cells, native block fidelity, frozen-prefix exchange and canonical conversion | ReqLLM mapping/transport; SessionCoordinator | Pending |
| Maintenance and compaction | ADR 0043/0044 | Captured maintenance configuration, immutable checkpoint and strategy revision 3, source_excerpted | SessionState; SessionCoordinator; ContextAdmission; host startup | Pending |
| Question lifecycle | ADR 0045 | model_tool/policy_defer producer; bounded choice/text/decline; atomic disposition/result | Interaction; SessionState; SessionCoordinator; host responder | Pending |
| Helper durable ownership | ADR 0046 | Bounded role/catalog bindings; reservation/allowance/monotonic-stop facts; derived job-index v1 | Host helper adapter; Runtime queries; Store; local executor | Pending |
| Host provider bindings | ADR 0048 | Explicit admitted routes and credential references through existing custody boundaries | Composition; ReqLLM provider route/custody; helper adapter | Pure shared reference/exclusion validation implemented; custody and startup/dispatch integration pending |
| Host configuration grammar | ADR 0049 | Closed file/flag grammar, exact precedence, role selections, safe inspect and trace options | CLI; composition options; host renderer | Bounded JSON decoder, authored schema, relative file paths, trusted trace selectors, flag parser and new-session precedence/origins implemented; capability/instruction admission, command entry and redacted inspection pending |
| Foreground and daemon wire | ADR 0044 coordinated contract | Foreground /3 and daemon /4; complete schema digests/vectors and negotiation | Protocol; AppServer; daemon servers; independent Node clients | Pending |
| Public projection | ADRs 0043–0046/0049 | Versioned snapshots/events; bounded numbers/cursors; allowlisted configuration and maintenance | SessionState; protocol; AppServer; daemon; clients | Pending |
| Ephemeral entry points | ADRs 0042–0045/0048/0049 | Combined closed startup options; one-call responder consumed locally; joined termination | Ephemeral.Options/Preflight/Bootstrap/SessionOwner; facade | Pending |
| Execution evidence | M7 technical acceptance contract | Fixed fixture/operator manifest; Pending scaffold; hash-chained single-writer attempts and fsync barriers | mix loopex.m7_evidence; release runner; PTY driver; evidence files | Pending |
| Upgrade and rollback | M7 compatibility contract | Exact retained M6 artifact/root fixtures; retain old rollback pair and add distinct M7 pair | rollback lane/scripts; Store recovery; operator instructions | Pending |
