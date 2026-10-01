# M7 Implementation Tasks

Execution checklist supplied by the maintainer. The accepted
[plan](../plans/M7.md#concept) and its
[technical companion](../plans/M7-technical.md#technical-depth) govern scope
and proof obligations. This checklist records work; it introduces no decisions.
Part of the [evidence index](README.md).

Progress reports use the maintainer's original T00–T19 checklist. Each task's
Original checklist section preserves its supplied items; only those checkboxes
count toward original-checklist completion. Added implementation subtasks are
tracked separately and do not increase the original denominator. An unchecked
original item may have substantial partial implementation; it closes only when
its entire stated outcome is proved.

## Current work

- Done: original T01 is complete, including live conversation after failure and
  prompt commit uncertainty on either side of persistence. The real-provider
  conversation witness remains a separate release obligation.
- Done: T02 exact-generation capability checks now guard runtime admission,
  registry loading and the local executor's compiled tool inventory. Original
  checklist completion is 23/186 items and 1/20 top-level tasks.
- Done: T02 attachment-budget baseline audit distinguishes existing attachment
  limitations from the required job-owned bounds. Snapshot creation failure now
  closes its source descriptor before returning; both toolchains prove the repair.
- Done: T02 pure range-result encoding selects the largest UTF-8 prefix within
  the complete 8,192-byte conversation-message limit, including double escaping,
  normalized call identity and metadata. Storage and executor integration remain open.
- Decision recorded: on 2026-10-01 the maintainer selected the separate optional
  `ArtifactStore.read_job_range(handle, validated_job)` callback for job reads.
  Implement it with the accepted job bounds and shared transfer capacity; legacy
  adapters without it refuse job reads. Existing attachment callbacks remain compatible.
- Done: T02 resolves committed-receipt artifact membership before policy and
  binds approved ranges to their exact source in the journaled job. Prepared
  references and real range transfers remain open, so original counts are unchanged.
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
- Done: source-bound ordinary continuation envelopes, full expanded costs,
  frozen project content through owner recovery, native-ID collision refusal,
  and independently replayed aggregate-overflow preparation failures.
- Done: bounded native Anthropic event assembly and pinned SSE parsing/flush
  checks preserve signatures, block order and final usage with permanent failure.
- Done: captured-cell native request rendering, exact tool/limit preservation
  and final Finch request sealing against the pinned dependency's mutation hooks.
- Done: join native capture/rendering to the durable worker's ReqLLM transport,
  with strict replies, eligible summary projection, fatal wakeup and owned drain
  cleanup; resolve canonical tool names through their complete generations.
- Done: repair the historical interaction control, complete CLI/daemon native
  fixtures, retain Core accounting witnesses over actual provider transports,
  and route config model validation through composition.
- Done: join buffered native capture and request rendering to OneShotHTTP1,
  screen captured private values for the selected key, and keep native request
  bytes out of Finch metadata through one-use invocation-owned body streams.
- Done: register all nine literal adapter cells after deterministic native
  conformance; share exact mapping resolution with transport validation.
- Done: join new-session host selection to explicit provider routes, captured
  instructions, exact mappings and whole-configuration admission.
- Done: validate and capture explicit Core maintenance settings, forward them
  privately to session owners, and resolve the host's separate thinking-off
  summarizer with fixed-budget native transport conformance.
- Done: validate maintenance instructions before durable/ephemeral owned effects
  and forward them through every durable constructor and ephemeral SessionOwner
  into the real runtime and coordinator.
- Done: join explicit ephemeral provider bindings to committed-model dispatch,
  caller-only credential resolution and separately resolved maintenance startup.
- Done: full fast check of the maintenance/ephemeral-routing integration at
  `7c266c4678776908b159bea13927117e1bf40bd7`, with all 11 suites passing.
- Done: admit closed durable token-route maps and select exactly one token from
  the committed request before provider-process startup, retaining the existing
  private credential bootstrap and cleanup path.
- Done: shared explicit durable binding loading and version-2 plane construction;
  borrowing hosts retain custody while issuing fresh trace capabilities.
- Done: executor-local launch exclusions reach ordinary jobs and cleanup helpers;
  first images exclude all 17 names even when reintroduced after the snapshot.
- Done: validated credential exclusions reach project revision discovery, skill-import
  executors and placement probes; placement release accepts the same scoped probe.
- Done: direct and borrowed version-2 durable startup validates complete planes,
  selected routes and maintenance models before owned effects, then forwards
  immutable exclusions to Store, executor and provider launches.
- Done: consolidate constructor preflight in DurableOptions, restoring the
  reference composition to 154 effective lines under its unchanged 180-line gate.
- Done: daemon bootstrap validates explicit bindings before placement/environment
  effects, uses shared custody loading, forwards model/maintenance options and
  preserves classified cleanup for every custody plus scoped placement exclusions.
- Done: offline CLI startup caches explicit bindings across compositions, refuses
  rebinding, forwards model/maintenance options and scopes discovery/placement
  exclusions. Chat, daemon-command and remaining host entrypoints are unfinished.
- Done: full fast check of `cf7e875f61e86538867d54135a7c136e235e3ff1`,
  all 11 application suites passing in 970 seconds.
- Done: foreground app-server programmatic provider options, with whole-map and
  selected-route preflight, fixed missing-credential refusal and real two-route
  startup/EOF cleanup. Host and policy witnesses pass on both toolchains.
- Done: bounded chat line reading and explicit command parsing, with no read
  beyond a wait line, exact answer decoding and malformed-input refusal.
- Done: bounded independently draining chat output and quoted transcript
  rendering, including progress eviction, unchanged control deadlines, inherited
  shutdown bounds and joined IO-worker cleanup on both supported toolchains.
- Next: join configuration preparation, ChatInput and ChatOutput to the runtime-
  owning chat driver and closed control records for the first complete workflow.
- Done: new-chat preparation captures exact v3 genesis from file/flag selection,
  instructions and immutable tools. Explicit question selection reaches every
  durable constructor. Configuration and constructor tests pass on both supported
  toolchains, including real durable creation and restart. Chat dispatch is still open.
- Decision pending: expose captured genesis through the existing Loopex creation
  facade, or keep that facade unchanged and route chat through composition to
  the accepted host-private exact-genesis operation. No dependent public API
  change has been made.
- Decision pending: ADR 0043's required-only refusal counts cannot describe an
  oversized ADR 0044 frozen request containing project/resource blocks. The
  proposed v2 amendment adds explicit counts for those classes. Do not implement
  the dependent refusal schema without the maintainer's decision.
- Next: complete whole-profile and startup integration, maintenance
  quiescence and checkpoint-aware configuration preflight; complete question
  projection/private-record vectors and the remaining M7
  configuration/maintenance/bound payloads before the coordinated /3-/4 switch;
  continue prompt-file and mapping
  preparation, effective inspection and command entry wiring, then live
  chat/configuration composition and maintenance accounting in T04/T06/T08.
- Remaining: all unchecked tasks below. Closure, main integration and release
  retain their explicit maintainer decision gates.

## Development observations

- 2026-10-01: ChatOutput admits rendered bytes only from its creating host,
  counts active and queued writes together against 256 KiB, evicts queued
  progress before required output, and never truncates a control record above
  65,536 bytes. Its independent IO worker is linked and monitored. A successful
  finish follows worker termination; IO failures, overflow and the original
  five-second control deadline seal the writer and notify the host once.
  Later progress and finish preserve an earlier deadline; an existing host
  shutdown deadline can shorten finish. Owner loss joins blocked IO, and abrupt
  manager loss kills its linked worker. OTP status excludes buffered text.
  Render.chat_text prefixes every model/tool line, escapes terminal and Unicode
  format controls, terminates a final fragment before the next host record and
  refuses invalid UTF-8 or expansion beyond the queue limit. Eleven cases pass
  in 5.6 seconds on current and 5.4 seconds on floor. Closed control schemas,
  driver integration, real pipe/PTY tests and the prescribed Linux load runs
  remain open; no original checklist item is closed by this standalone stage.
  - Current: `/private/tmp/loopex-m7-chat-output-final-current.log`, SHA-256
    `0971b7c3633f6c2ca417bd8b0d8c457af324e423786cf5e3db03021e2e0c5cea`.
  - Floor: `/private/tmp/loopex-m7-chat-output-floor.log`, SHA-256
    `6110f49e17f378aca7166170c74ed378f32905092979a08dc628675339d91ce9`.
  - Initial nine-case pass: `/private/tmp/loopex-m7-chat-output-current.log`,
    SHA-256 `3d1639b6b85e21fcd3f234283e75149eb8782e5081fa7ff998f52c6be0bdeedd`.

- 2026-10-01: ChatConfiguration joins the existing explicit file/flag resolvers,
  required paths, exact instruction capture, selected tool definitions and
  shared genesis resolver without credential loading or runtime startup. Coding
  and read-only profiles include the exact question generation; none is empty.
  DurableOptions registers that interaction only when explicitly selected, leaving
  omitted/default selections unchanged. The prepared genesis creates a real
  local-Store session and survives runtime restart unchanged. The complete selected
  definitions contribute to system-budget admission. Credential-free profiles
  remain valid authored input but refuse durable chat; resume and enabled helper
  preparation remain explicit unfinished paths, not silently narrowed profiles.
  No chat command entry or new public creation API is enabled by this change.
  CLI configuration/flag regressions pass 31 cases on current/floor in 4.0/4.2
  seconds; all-constructor regressions pass 17 cases in 7.7/7.6 seconds.
  - Current CLI: `/private/tmp/loopex-m7-chat-configuration-routes-current.log`,
    SHA-256 `3ed2ab06dd2cd56512e400516e685aeb9b3fdf254dc279aaac35e0d210583e93`.
  - Floor CLI: `/private/tmp/loopex-m7-chat-configuration-floor.log`, SHA-256
    `99372e515de5f7f7cc5c74b7ad26768ddda2d374c09e54aac9e5540836d851dc`.
  - Current constructors: `/private/tmp/loopex-m7-chat-tools-current.log`, SHA-256
    `d524331052cab71427df4f5cde421cc9f02926144d8d336c63580f0386ab77a6`.
  - Floor constructors: `/private/tmp/loopex-m7-chat-tools-floor.log`, SHA-256
    `2007ae84eb151456e79c8aec9d96496f023975897941f51a30c37f486b76e4fd`.
  - Initial run failed before test bodies because a fixture used ExUnit's reserved
    file field: `/private/tmp/loopex-m7-chat-configuration-current.log`, SHA-256
    `6eb804de7c5f0e9282c8b1aa5e697e37f62945593cd8ecca2f0d3410afaf9733`.
    After correcting it, six cases passed in 2.3 seconds:
    `/private/tmp/loopex-m7-chat-configuration-fixture-current.log`, SHA-256
    `7e220900bae1c021504dadc2e4f9687258cd206b586d9e8ce56577a8bd90ddec`.
    The first expanded 31-case run passed in 3.8 seconds, but its credential-free
    test used an invalid binding shape. It was strengthened to require authored
    schema acceptance and the exact durable-model refusal before the final runs:
    `/private/tmp/loopex-m7-chat-configuration-final-current.log`, SHA-256
    `ecbe9fef5322320dfbc3b2339aaa73b5ce6d170937a386f00670d165b21fd894`.

- 2026-10-01: Restored reporting against the maintainer's original numbered
  checklist after clarification. It contains 20 tasks and 186 original items;
  20 original items are checked, with all top-level tasks still open. Earlier
  86/262 reporting counted added implementation work and is not the original
  checklist's completion measure. Original T09 recovery proof is restored as
  one checked item, supported by its pure, live-owner and local-Store restart
  witnesses below; those implementation witnesses remain separate additions.

- 2026-10-01: ChatInput reads one LF/CRLF line at a time with a 65,536-byte
  pre-terminator ceiling. It consumes no next-command byte after a wait line.
  EOF fragments, bare CR, NUL, malformed UTF-8 and failed IO refuse. Explicit
  command parsing preserves prompt text, decodes question/choice wire IDs and
  JSON answer strings once, and rejects duplicate configure members. The driver
  still owns admission, input sequence/command IDs, barriers and cancellation;
  this is not yet a callable chat workflow. Nine focused cases pass on both
  toolchains in 0.2 seconds each.
  The initial floor run exposed a test cleanup race. Removing a link did not
  solve StringIO's owner monitor; the final fixture uses its callback bracket
  to close before owner exit. Failed outputs are retained, not counted as passes.
  - Initial current pass: `/private/tmp/loopex-m7-chat-input-current.log`, SHA-256
    `8c616b29c29ae70b2fe461c309b19ae779d2f1dad32dd04a2270f4a9fc87f1de`.
  - Initial floor failure: `/private/tmp/loopex-m7-chat-input-floor.log`, SHA-256
    `3bb0887f4258ac64795d4946859dd8fdabdc21bcd87e9df2630fc0054316aa3c`.
  - Unlink-only failures: `/private/tmp/loopex-m7-chat-input-fixed-current.log`,
    SHA-256 `af21dc060b326ac3fde279185552adc2dd7d0bf66fce6bb0cff15cf0da5d316d`;
    `/private/tmp/loopex-m7-chat-input-fixed-floor.log`, SHA-256
    `97fa074cf840d90d143ffeccc9fdbe1577c637f083015678ea4cb484eed6cdab`.
  - Final current pass: `/private/tmp/loopex-m7-chat-input-bracket-current.log`,
    SHA-256 `00bce9e55ed81ad771df87996509b3ab072c9b36f014d99209957eeaaee579b3`.
  - Final floor pass: `/private/tmp/loopex-m7-chat-input-bracket-floor.log`, SHA-256
    `40921e3c6f10662b016634983f2d4fdee133d2c53de3163d934bc3fa73fc5ea5`.

- 2026-10-01: The exact offline-binding integration candidate
  `cf7e875f61e86538867d54135a7c136e235e3ff1` passes the full fast check in a
  clean detached worktree. All 11 application suites pass; total 970 seconds.
  The complete output is `/private/tmp/loopex-m7-cf7e875f-fast-check.log`, SHA-256
  `1aafc2f1799a25a43b6d5d3caea88b6d92cbe79471f754ff3efc30c832ddd1de`.
  Foreground changes below were outside that exact candidate.

- 2026-10-01: Foreground `Host.serve/1` accepts the closed programmatic durable
  options without loading a configuration file. Binding and route validation
  precede launch effects. Missing explicit credentials use a fixed diagnostic.
  Real subprocess fixtures exercise invalid maps, unbound ordinary/maintenance
  routes, missing credentials, two-route startup, maintenance/tool forwarding,
  environment deletion and joined EOF cleanup of all nine owned processes.
  Host and policy tests pass 20 cases on current and floor toolchains in 6.6 and
  6.0 seconds respectively. Both runs also report the existing AllowAll notice
  table's ETS transfer to `:init`; that diagnostic is retained for investigation.
  - `/private/tmp/loopex-m7-foreground-current.log`, SHA-256
    `32c033f3cfe25befd72e4ca13f33ec00ec55f0216c670e138add7cbcd65e6b49`.
  - `/private/tmp/loopex-m7-foreground-floor.log`, SHA-256
    `e17daadf7ca27e3a339014882b66244e8207eb5a0afb8daf8272f1f12977319e`.

- 2026-10-01: The offline CLI's existing credential cache accepts an explicit
  immutable binding map and lends it through fresh trace capabilities. A changed
  map or replacement of legacy custody refuses without consuming another value;
  a failed load leaves no cached partial host. Runtime startup validates selected
  ordinary and maintenance routes before loading credentials, forwards the
  programmatic model/bounds/sampling/active-tool/maintenance options, and captures
  exclusions for project discovery and placement acquisition/release. Runtime
  composition receives the borrowed plane without a conflicting raw binding map.
  Repeated real composition reaches the Core startup boundary with identical
  tokens, distinct capabilities and original keys after environment reinsertion.
  This proves shared offline startup; the chat driver, daemon command, foreground
  server and remaining ask/helper entrypoint work stay open.
  Seven new/existing cache and offline cases pass in 1.6 seconds. The affected
  CLI, prepared-recovery, ask and context-budget regression set passes 155 cases
  on both toolchains: current 48.4 seconds, floor 47.5 seconds.
  - `/private/tmp/loopex-m7-offline-bindings-current.log`, SHA-256
    `272d38f08b0bc0ca21ac07df0ce5085963ea035da76f60bca7251dc26a07ef94`.
  - `/private/tmp/loopex-m7-offline-bindings-regression-current.log`, SHA-256
    `40911dd043f424f6b0df6d5f7e23c2c84f25ff42167915aa7605b121c9930b7f`.
  - `/private/tmp/loopex-m7-offline-bindings-regression-floor.log`, SHA-256
    `3a1707a411d60fc92a904bef5cb124012c5fc1f5b6f53d8a836f6125e89215e2`.

- 2026-10-01: Daemon Service accepts explicit provider bindings through the
  shared durable loader. Conflicting value-bearing credentials, invalid complete
  maps and unbound ordinary/maintenance selections refuse before placement or
  environment effects under the existing credential-plane startup class. Each
  unique slot gets one tracked custody; shared references reuse its token.
  The existing orderly and failed-start teardown now visit every custody before
  its registry, with custody loss retaining the existing fatal class. Fatal
  fail-stop retains ADR 0031's bounded executor/Store tail and VM-halt lifetime
  for the remaining VM-local components. No new failure class or wire record is
  introduced. Placement acquisition/release capture validated exclusions;
  composition receives the model, bounds, sampling, active-tool selection and
  explicit maintenance settings alongside its version-2 plane.
  New real-daemon tests cover route selection, private configuration, shared-slot
  deduplication, pre-effect refusals, partial loading, post-bootstrap failure,
  orderly joins and loss of either custody. The current toolchain passes 52
  initial binding/legacy-lifecycle cases in 137.8 seconds, then all six final
  binding cases in 1.6 seconds after adding post-bootstrap cleanup and complete
  forwarding assertions. The floor toolchain passes the final 53-case set in
  137.9 seconds. CLI discovery, early credential consumption and entrypoint
  forwarding remain unfinished.
  - `/private/tmp/loopex-m7-daemon-bindings-fixed-current.log`, SHA-256
    `55c12430170266af60bf95cf84c7156cee29a8f21f0d4c63393938b56a839644`.
  - `/private/tmp/loopex-m7-daemon-bindings-final-current.log`, SHA-256
    `b7b0c5069f4e81770ae46124b04550442a7cb36ad19376afbccffd8ba7ef5c1c`.
  - `/private/tmp/loopex-m7-daemon-bindings-floor.log`, SHA-256
    `52cb41295740c9ad029aa49487fb1204ff73cc3d1aef6ba56cfef7c7091308c0`.
  The first new test run failed two witnesses: it treated the second acquisition
  probe as the release probe and required orderly custody cleanup after fatal
  fail-stop. The corrected witnesses select a distinct release worker and follow
  ADR 0031's VM-halt contract; in-process fixtures explicitly join remaining
  children in cleanup. Existing lifecycle tests and bounds are unchanged.
  Initial output: `/private/tmp/loopex-m7-daemon-bindings-current.log`, SHA-256
  `20daa95697fcfb64c995e3a3400c95bd007edaa9b3dcaf1c4629e695cf3a41b6`.

- 2026-10-01: The complete fast check on
  `53a60e346e3523c09b0e95fbfda3877146dd15ba` failed only the reference
  composition's existing size assertion: 198 effective lines exceeded 180.
  All ten other application suites passed. The composition suite passed its
  other 385 tests; this run is retained as failed evidence, not a pass.
  Complete output: `/private/tmp/loopex-m7-53a60e34-fast-check.log`, SHA-256
  `395b7c5c7f84187b3e18f2afe94f242dcb6e8018fc072d143c4df3dd222904cd`.
  The repair moves the existing required-input and launch-option validation
  into DurableOptions, which already owns model, bounds, sampling, active-tool
  and maintenance validation. All three constructors use its complete preflight;
  order, error values, first-duplicate behavior and effect boundaries are unchanged.
  Composition retains startup wiring and now has 154 effective lines. The test
  and its 180-line ceiling are unchanged. Focused constructor, precedence,
  failure-cleanup and binding-startup tests pass 33 cases on each toolchain:
  current in 10.4 seconds and floor in 9.7 seconds. These focused results prove
  the repair; they do not relabel the failed integration candidate as green.
  - `/private/tmp/loopex-m7-validation-owner-current.log`, SHA-256
    `d7657b9baed490a6333658daec63397791138a542c085c5e27a315875f45b513`.
  - `/private/tmp/loopex-m7-validation-owner-floor.log`, SHA-256
    `93054405c4f2ce2742cc8fcfbfb9fe31f88d91ccdbfbd84ab3b35598399c71c2`.

- 2026-10-01: Durable composition now admits direct explicit bindings and
  borrowed version-2 planes. Preflight checks complete plane/model-option shapes,
  tracing-capability agreement, optional capability PID identity, every token's
  membership in the exact registry, sorted launch exclusions, the ordinary route
  and the separately selected maintenance route. Conflicting bindings and planes,
  local durable routes and unbound selections refuse before owned effects.
  Maintenance metadata is resolved once from admitted provider identities without
  inventing credential references or inheriting an unconfigured summarizer.
  Borrowed planes never reread reintroduced keys; direct partial-load failure
  joins the created custodies. Tests cover start, with_runtime and start_edges,
  public-view exclusion and the existing exhaustive durable-option subsets.
  The launch audit also found Store writer probes and provider companion Port
  startup. Both now receive instance-scoped exclusions; Store validates names
  before preparing its path and keeps them out of marker/log bytes. Provider
  configuration validates the same shared host-name grammar; the first-image
  witness reinserts all 17 names after the snapshot. Actual provider launch
  forwarding and cleanup retain their existing process-group conformance.
  Current proof includes 41 durable cases in 17.8 seconds, then all five final
  binding-startup cases in 2.2 seconds after adding partial-load cleanup; Store
  passes 10 in 7.6 seconds and the final launcher file passes eight in 5.3 seconds.
  Floor proof passes Store 10 in 7.3 seconds, provider 40 in 70.7 seconds and
  durable composition 42 in 16.3 seconds, each application in its own VM.
  Complete successful outputs:
  - `/private/tmp/loopex-m7-durable-startup-fixed-current.log`, SHA-256
    `f05d5b07be369a949b63f5d469ea5dbd2abe6b766c3c5151a21bb7ed95258d9b`.
  - `/private/tmp/loopex-m7-durable-startup-final-current.log`, SHA-256
    `5ac7c91d78bbe88be7ca3ad4db2cbbd2945dbceb307c579ac33207e866dcba5d`.
  - `/private/tmp/loopex-m7-store-exclusions-current.log`, SHA-256
    `bc1dcf0990476b2b2cdda9b37e070424b494079391ebd3a4a05da581331c1b5a`.
  - `/private/tmp/loopex-m7-provider-launcher-final-current.log`, SHA-256
    `205a0172d02f8659bc9d50595749ded8632bd8f57fb45a076b3fa6456e769b52`.
  - `/private/tmp/loopex-m7-store-exclusions-floor.log`, SHA-256
    `579043888dd49e9ae3c43bf42a457cd24d5cf42181d9a72a33b33c16d6b6cb2e`.
  - `/private/tmp/loopex-m7-provider-exclusions-floor.log`, SHA-256
    `1ae4e3c86b77e2cd37472bda5aa64e89b361c580164a6dbd6aaae932f1967f5a`.
  - `/private/tmp/loopex-m7-durable-startup-floor.log`, SHA-256
    `3ad16c3d8e8fbdf3cc865da37239b63cc8a4f9b975791fbccc49f4d032dfefd6`.
  The first integration run exposed the missing Store option allowlist entry
  and a fixture cleanup lookup after its registry had stopped. Both were fixed.
  The provider witness needed a separate trace observer and its exclusions on
  the actual launch fixture, rather than the earlier vector-only fixture. These
  were code/test changes; no failing run was relabelled as a pass or retried
  unchanged. Retained failure outputs:
  - `/private/tmp/loopex-m7-durable-startup-current.log`, SHA-256
    `962e37a11648cd91ed21aaffef57f83d1637c669103e9f609aaac4c3250502e4`.
  - `/private/tmp/loopex-m7-provider-exclusions-current.log`, SHA-256
    `58a56679a32584168cb1e3c281657c75d43a2039332e878cb3f192fae951ba53`.
  - `/private/tmp/loopex-m7-provider-exclusions-fixed-current.log`, SHA-256
    `b238e73296b5fde40ced7fcd78ec9e918046cf0c977311856da4a5d1db01bba6`.
  Daemon binding ownership/conflict handling, CLI entrypoints and helper-host
  forwarding remain pending. This checkpoint does not claim those workflows.

- 2026-10-01: Project revision discovery, resource-import executors and placement
  probes now accept the same bounded sorted credential-exclusion list. Shared
  validation rejects malformed lists before discovery reads entries, import
  creates directories, or a placement probe starts its subprocess.
  Discovery and placement explicitly unset every captured name at System.cmd;
  resource import passes the list into the actual local executor constructor.
  Placement release can use the same scoped probe as acquisition and inspection.
  The legacy single-name defaults and existing receipt fields remain unchanged.
  The reference adapter additionally reserves `LC_ALL`, as ADR 0048 permits
  narrower exclusions: placement requires `LC_ALL=C`, which would conflict with
  removing that name if it were admitted as a credential slot. The shared
  binding validator rejects it before custody reads or startup.
  Tests observe discovery after all 17 names are reintroduced, actual placement
  acquisition/inspection/release, the actual import executor's startup options,
  unchanged receipts, invalid-name refusal and custody admission. Final focused
  suites pass 42 cases on current in 38.3 seconds and on the floor in 37.9 seconds.
  Complete outputs:
  - `/private/tmp/loopex-m7-composition-exclusions-final-verified-current.log`, SHA-256
    `594b395860ff77139ae7a98db2d194036d43d050032d710280787e1ecdac4f04`.
  - `/private/tmp/loopex-m7-composition-exclusions-verified-floor.log`, SHA-256
    `c63d9b7c9669ff0ace83475d8d7bd82e998c9903233ed3aa388ff167756e87cf`.
  Two test-witness defects were fixed before this proof. The first tried to read
  job context from the separate bounded unlink worker; it now observes the real
  executor constructor. The floor then exposed an order-dependent trace install
  before module loading. A fresh-VM diagnostic proved zero matched functions
  before loading and one after; the test explicitly loads the module and asserts
  both trace-install counts. Neither timeout nor required check was relaxed.
  Retained diagnosis:
  - `/private/tmp/loopex-m7-composition-exclusions-current.log`, SHA-256
    `fa5da6cee0d9d98716ba012a57a5cc4cb41dfda0c1794ac6998498e10a6fef36`.
  - `/private/tmp/loopex-m7-composition-exclusions-floor.log`, SHA-256
    `79aae65f5fe9d92ff6a9e14006cdd9a9de0f8a645093cd44967c5ede298afc62`.
  - `/private/tmp/loopex-m7-import-trace-load-diagnostic.log`, SHA-256
    `b36ac8dd48de8ed6ecb51bc153fb5a86f5ea616289374e1b13860119b9dc0a98`.
  Runtime composition and reference-host entrypoints still need to forward the
  plane's immutable list. Version-2 durable planes remain refused until that
  integration also supplies route validation and selected-model startup.

- 2026-10-01: The trusted local executor accepts a bounded, sorted unique
  `excluded_env_names` startup list containing the legacy provider key. It
  retains that list only in private executor/job context, transfers it to launch
  and drain workers, and restores the caller's context after execution. The
  single production Port boundary explicitly removes every listed name after
  the ambient snapshot; ordinary jobs and cleanup helpers use that boundary.
  Existing jobs and receipt fields are unchanged. A real first-image witness
  reinserts all 17 admitted names after the snapshot for both coding and
  demonstration environments. A separate actual-job trace proves that configured
  exclusions reach the ordinary launch and its cleanup helpers; malformed lists
  refuse before ledger creation. The focused executor and coding suites pass
  147 cases on current in 122.0 seconds and on the floor in 119.4 seconds.
  Complete outputs:
  - `/private/tmp/loopex-m7-executor-exclusions-current.log`, SHA-256
    `6987a3d3bf4ab8d2a4d815e022a371b9adb0b1429a27789323eee87f8986502d`.
  - `/private/tmp/loopex-m7-executor-exclusions-floor.log`, SHA-256
    `b7f8153ed99e9a957c3291da5228e489feb0f02f2919e73e2071da31950c735e`.
  The first sandboxed invocation could not acquire Mix's local TCP lock and
  executed no tests; the recorded runs used the authorized local test environment.
  Composition forwarding, project discovery, resource-import executors and
  placement probes remain pending. Version-2 credential planes are still
  refused by durable runtime composition until those paths join.

- 2026-10-01: CredentialPlane's explicit-binding branch and CredentialHost.open/1
  now share one loader. It validates all references before environment access,
  refuses local durable routes, loads sorted unique credential names once and
  deletes an unselected legacy variable without reading it. Shared names reuse
  custody; separately named credentials retain distinct tokens. Partial missing
  credentials, constructor refusals, constructor exceptions and capability-start
  failure join every returned child's termination before refusing. Constructor
  failures expose a fixed class. Successful processes stay linked to the opener.
  Borrowed version-2 planes retain their exact routes, registry and exclusion
  set with a fresh trace capability, and do not reread reintroduced environment
  values. Trace-counted synthetic tests and existing legacy tests pass nine
  cases on current in 0.5 seconds and on the floor in 0.4 seconds. The invalid
  input test explicitly observes attempted starts outside the starter callback,
  so the loader's exception reduction cannot swallow a failed assertion.
  Complete outputs:
  - `/private/tmp/loopex-m7-durable-bindings-verified-current.log`, SHA-256
    `fc5c1a8e3743fc77130b0a70fed3f45244062ca5199a52e1be777e3777c16b54`.
  - `/private/tmp/loopex-m7-durable-bindings-floor.log`, SHA-256
    `77c022c6a39dae254ae90ddc7e75af2f8b7aa4a7b5ea9cce876a5b9bb556c466`.
  Composition still refuses these new planes. Runtime acceptance, launch-name
  exclusions, daemon ownership and selected-model startup must join together
  before the host entrypoints expose multi-provider durable execution.

- 2026-10-01: The durable adapter accepts the explicit provider-routes branch
  alongside the separate legacy single-token branch. It rejects mixed branches,
  partial registry/capability options, malformed tokens and unsupported provider
  keys. Before starting an invocation, the bridge selects only the committed
  request's provider token and removes the routing table from its invocation
  configuration. A missing route refuses before any child starts. The existing
  excluded credential sender, registry/custody lookup, private bootstrap frame
  and process-retirement proof are unchanged. A real companion fixture receives
  alternating selected credentials with independently distinct lengths and
  proves each child gone; an unbound provider produces no child or credential
  frame. The 30-case configuration/bridge selection passes on current in
  38.5 seconds and on the floor in 66.7 seconds. Complete outputs:
  - `/private/tmp/loopex-m7-durable-route-current.log`, SHA-256
    `617f6045dafbf340a6fb2b6e7e7dbb2d67aa2a1a8b368f5095f6c588a1f80457`.
  - `/private/tmp/loopex-m7-durable-route-floor.log`, SHA-256
    `524f0f8ff9e57d4d01681bdb4db2f4f91b8a0ec6773893362475fc3488fe4163`.
  The shared durable binding loader, version-2 host planes, launch exclusions,
  daemon assembly and host model/configuration wiring remain pending. This
  adapter change does not yet make those host entrypoints accept multiple keys.

- 2026-10-01: The full fast check passes on exact integration commit
  `7c266c4678776908b159bea13927117e1bf40bd7`: all 11 application suites,
  2,905 tests passed and 34 excluded, in 872 seconds. Compilation, formatting,
  structure, documentation ordering, runner/archive fixtures, dependency
  direction and version checks also pass. Complete output:
  `/private/tmp/loopex-m7-7c266c46-fast-check.log`, SHA-256
  `ab4f135d79d664f6bb949b872847e11e3609a53881bdec4ff53c1c66e10b289a`.
  The checkout stayed unchanged throughout the run. Later durable routing work
  is outside this proof and requires its own focused validation.

- 2026-10-01: Ephemeral startup accepts explicit provider bindings and a separate
  maintenance model. It validates every reference, requires the ordinary and
  summarizer routes, and forwards the resolved maintenance map privately.
  Omission retains legacy single-route behavior; a supplied map adds no routes.
  The adapter now owns the one shared reference validator used by composition
  and dispatch. Each committed request selects its own provider reference before
  admission, while only the sensitive caller reads the value. Mixed legacy and
  explicit callback options refuse. Route tables do not enter caller input;
  it receives only the selected reference. Tests cover native TLS calls using
  alternating synthetic keys, a missing selected key despite a populated
  default, credential-free calls, unknown/missing routes, reserved names,
  resolved maintenance startup, public-view exclusion and repeated embedded
  turns through the complete callback and cleanup path.
  The initial focused invocation incorrectly combined applications in one VM.
  Adapter tests passed 22 in 9.9 seconds, but ReqLLM startup state from that
  suite caused 13 composition `req_llm_dotenv_enabled` refusals. The repository's
  required one-application-per-VM execution removes that test-runner
  contamination without changing or relaxing a guard. In a separate current VM,
  all 61 composition cases pass in 23.2 seconds. Separate floor VMs pass the
  same 22 adapter cases in 9.5 seconds and 61 composition cases in 23.7 seconds.
  Retained outputs:
  - Initial mixed run, including the adapter pass and composition failure:
    `/private/tmp/loopex-m7-ephemeral-bindings-current.log`, SHA-256
    `bd99b9315da0dad6c1f825073d614d2dc7b381edc034ffb13fcb91039923f79e`.
  - Current composition:
    `/private/tmp/loopex-m7-ephemeral-bindings-composition-current.log`, SHA-256
    `28b6ee5e2be832912e47441c1b611027b5f4c59bd6604724906ff55838cf6f2e`.
  - Floor adapter: `/private/tmp/loopex-m7-ephemeral-bindings-adapter-floor.log`,
    SHA-256 `d3039116192773abf7b213a18683176a2a50f51c9aa39501cd3c5c72ebb2c439`.
  - Floor composition:
    `/private/tmp/loopex-m7-ephemeral-bindings-composition-floor.log`, SHA-256
    `ab47e9c1402ca3a95c6632cc584287331647f103fe21582839b96245245165fc`.
  Additional managed-callback cases prove mixed legacy/explicit options and a
  missing selected route refuse before admission or child startup. The 17-case
  callback file passes both pairs in 4.4 seconds each:
  - `/private/tmp/loopex-m7-ephemeral-bindings-callback-current.log`, SHA-256
    `212fbd31f233e78e45918fd87219a71be4c0cb4db57539ed2b149847a58a9a88`.
  - `/private/tmp/loopex-m7-ephemeral-bindings-callback-floor.log`, SHA-256
    `f7e073859841d404b6c879a5d17458642e4f7ab445f7be3a4c0037f86dc9d412`.
  Compilation, formatting, documentation ordering across 1,022 covered entries,
  dependency direction and status checks pass.
  Durable custody, daemon routing, host configure/resume and maintenance episode
  dispatch remain pending. These local synthetic calls are not counted paid
  provider attempts or live closure witnesses.

- 2026-10-01: All three durable constructors and ephemeral startup now accept
  explicit `maintenance_instructions`, validate them before owned effects and
  forward the exact version/body input to Core's runtime-local capture. Missing
  or nil remains unconfigured. Ephemeral per-call overrides remain refused.
  Tests exercise all durable constructors, the real ephemeral runtime and
  coordinator, exact Unicode/newline content, the inclusive body ceiling,
  malformed-input refusal before owner allocation and public-view exclusion.
  The four focused files pass 54 cases on the current toolchain in 19.3 seconds
  and 54 on the floor in 19.0 seconds. Their existing deliberate cleanup faults
  retain their diagnostic output. Complete outputs:
  - Current: `/private/tmp/loopex-m7-maintenance-host-forward-current.log`, SHA-256
    `1c8b253eca9b740a33890e7096fc7ac06c227882b32cb32866cedbdc9415b193`.
  - Floor: `/private/tmp/loopex-m7-maintenance-host-forward-floor.log`, SHA-256
    `c09270964b68f0ff125f3f4a5401c26b4b5e2904535c4f07718cfcfc2eaa2469`.
  Provider-binding/custody integration is still required before composition can
  forward the separately selected maintenance model. The shared reference
  instruction block and episode/compaction implementation also remain pending.

- 2026-10-01: Core startup now validates the closed maintenance model and captures
  the exact versioned instruction bytes and digest. Runtime-local settings reach
  each coordinator without entering ordinary session truth or public runtime
  configuration. Startup capacity validation remains distinct from episode
  reasoning eligibility. Composition resolves only an explicitly selected,
  routed, registered thinking-off summarizer, and CLI preparation retains nil
  when none is selected. Streaming HTTP and buffered TLS tests exercise the
  fixed 1,024-token allowance, disabled thinking, absent tools and natural
  summary completion. Current and floor focused checks passed 19 provider,
  12 composition and 14 CLI cases. The broader Core check initially failed one
  of 51 cases because the extracted validator added an unnecessary 512-byte
  model limit. Removing that restriction preserved the existing independent
  2-KiB metadata boundary test; all 51 Core cases then passed on both pairs in
  0.3 seconds each. Initial failed outputs remain retained separately:
  - Current: `/private/tmp/loopex-m7-maintenance-startup-current.log`, SHA-256
    `271ef1debdf4891dfe083a8e9f0e761c30b03293c5fc76eb215d9dd1486148bc`.
  - Floor, including the passing provider/composition/CLI groups:
    `/private/tmp/loopex-m7-maintenance-startup-floor.log`, SHA-256
    `d285019974c9baea3d4f139f3f4f73f25f000fd7a72ecd0fc0f4cee58bc6c035`.
  - Repaired current Core:
    `/private/tmp/loopex-m7-maintenance-startup-repaired-core-current.log`, SHA-256
    `9ee5a827b08ee5eaa10c800b6e1dabea1173d5cbe828a225e6f6b6ffcec08695`.
  - Repaired floor Core:
    `/private/tmp/loopex-m7-maintenance-startup-repaired-core-floor.log`, SHA-256
    `6825255e5e0287467459bded3c6a3947c8f0dcb4a976af4e96dd06c4aec9c320`.
  Durable and ephemeral host startup forwarding, the shared reference instruction
  block, episode capture, dispatch, recovery and checkpoint accounting remain
  pending. This checkpoint does not implement compaction. Warning-free
  compilation, formatting, documentation ordering across 1,020 covered entries,
  dependency direction and status checks pass. The dependency check first
  refused the untracked new module; staging the source satisfied its tracked
  ordinary-file requirement without changing the check.

- 2026-10-01: ProviderBindings now resolves a closed initial declaration through
  complete route validation, pinned capability capture, literal alias resolution,
  exact reasoning/reply mapping and Core's whole-configuration validator.
  ConfigSelection joins the file/flag selection to that boundary with the host's
  already captured instruction block and complete selected definitions. Derived
  ceilings acquire default origins; explicit origins remain unchanged. No
  credential reference, path or host routing value enters the core configuration,
  and neither stage acquires credentials or starts services. Tests cover every
  registered cell, missing routes, malformed bindings, authored metadata,
  manual/output/context limits, unknown windows, instruction/tool system cost,
  literal alias resolution and a prompt file changed after capture. The initial
  CLI fixture run passed 29/31: one fixture omitted its file model's route, and
  another expected an unbound override to survive the existing earlier schema
  guard. Corrected fixtures preserve that guard; production code was unchanged.
  Current focused checks pass 11 composition cases in 5.9 seconds and 31 CLI
  cases in 1.0 second. The floor passes the same 11 in 5.7 seconds and 31 in
  0.9 seconds. Retained floor output:
  `/private/tmp/loopex-m7-host-configuration-preparation-floor.log`, SHA-256
  `4052203445e6a612fcd575e8a68b44e1efb26ddcf0c7f0c3e769180c66816785`.
  This is initial session preparation. Complete maintenance/role preparation,
  effective-value rendering, command entry, startup and configure/resume wiring
  remain pending.

- 2026-10-01: the full fast check passed on
  `14275a2949567b885f3a91b4a47d3d042dd3e376`: all 11 application suites,
  2,880 passed and 34 excluded, in 870 seconds. This proves the integrated
  native bridge and the earlier fixture/config-routing repairs. Complete output:
  `/private/tmp/loopex-m7-14275a29-fast-check.log`, SHA-256
  `752e5ef2c8c5873d7740726e80f0b619ec72ef28443138644f6d6897a4cfd347`.
- 2026-10-01: all nine literal cells now have streaming HTTP evidence for exact
  controls, reply ceilings, literal response identity, public summary eligibility,
  private block retention and open/closed capsules. Each cell's post-terminal
  request groups retained tool results and the next prompt in one user array,
  omits empty assistant completions and uses canonical tool IDs. All seven
  continuation-required cells preserve their own expanded native arrays and
  original IDs in both render modes. Per-cell streaming cases refuse foreign
  identity, raw-content and block-count overflow, and complete-wrapper overflow
  after otherwise successful bounded assembly. These added tests passed before
  ordinary registration: 27 tests in 2.6 seconds. ModelCapabilities now exposes
  precisely the accepted Haiku and Fable reasoning subsets and their literal
  mappings. NativeRequest uses that same mapping function without a catalog
  refresh. Manual budgets refuse at equality without increasing max_tokens;
  Fable none and unknown non-default modes refuse. All nine resolved records
  pass whole-configuration admission within the existing metadata envelope.
  Seven focused files, including both transports and cleanup, pass 76 tests in
  21.1 seconds on the current pair and 76 in 20.9 seconds on the floor pair.
  This completes adapter registration; host startup/configure/resume integration,
  the separate summarizer and counted live witnesses remain pending. Outputs:
  - `/private/tmp/loopex-m7-nine-cell-conformance-current.log`, SHA-256
    `4294a57180b6f94add28c1c244a08ddfe8debca9d2fdb44609f215a7b6741c70`.
  - `/private/tmp/loopex-m7-registered-cells-current.log`, SHA-256
    `83ef6f5dd3ff6f8fe578595e2164b33864327ba9b177551b2db123806d6858bc`.
  - `/private/tmp/loopex-m7-registered-cells-floor.log`, SHA-256
    `ce1554089a10df7ff77dda1c6c85783b642ca140ef82da34fc63662a7cbf0067`.

- 2026-10-01: the buffered Anthropic path now validates its captured cell before
  credential lookup, installs exact native messages/controls at OneShotHTTP1's
  final encoded-request boundary and captures the raw response before SDK
  conversion. The existing invocation tag correlates caller-local request and
  response entries; the cleanup owner still receives only its closed route
  proof. Capture requires a complete native envelope, literal registered model,
  bounded native content and the same stop/call relationship as streaming.
  Supported usage counters remain unknown when missing or malformed. The caller
  returns completion/capsule fields with zero progress deltas and screens every
  newly retained private value for the selected credential. SDK payload capture
  is disabled per call, and raw SDK fixture capture refuses before dispatch.
  Local verified TLS exercises all nine literal cells, open and closed capsules,
  Unicode/text/tool ordering, exact controls/limits, malformed/native-limit/model
  refusals and selected-key echoes in thinking, signatures and redacted blocks.
  Final review also retained raw usage until selected-key screening, so reducing
  a malformed counter to unknown cannot erase a credential echo. The pure and
  actual-TLS regressions for this final correction pass 14 tests in 6.1 seconds
  on the current pair and 14 in 5.8 seconds on the floor pair.
  Ordinary reasoning registration and the live thinking witnesses remain open.
  Finch's own events retain the outgoing request object, independently of SDK
  payload settings. Both native paths now supply a one-use body stream whose
  callback retains only the invocation handle. The streaming capture owns its
  bytes until the first read and clears them on failure; the buffered caller
  consumes its body entry once and removes it on every transport exit. Exact
  content-length preserves the existing wire bytes and framing. Tests inspect
  actual Finch events and serialized callback terms, prove exact transmission
  and refuse a second read. Existing host-owned header observability is unchanged;
  this supplies no secrecy from trusted code executing in the transport process.
  Buffered memory remains bounded by the existing 8,388,608-byte raw collector,
  its transient joined binary and decoded response, the already admitted outgoing
  request, and the 16,384-byte compact/expanded native-content limits. The private
  capture adds only the admitted canonical text/calls/capsule and supported usage;
  it retains no response event log. Caller cleanup removes its capture entries.
  A low-level TLS fixture originally sent an empty Anthropic body without an
  invocation context; its pre-claim refusal exposed a fixture owner waiting only
  for a claim. The fixture now supplies valid native request/response bytes and
  acknowledges teardown before or after claim. The failed 73/74 run is retained
  as failed; its orphaned child was identified and terminated. The repaired exact
  case passes in 2.0 seconds. Floor conformance passes all 74 cases in 18.3 seconds;
  current worker/backpressure/accounting regressions pass 25 in 95.1 seconds and
  host credential-exclusion workflows pass two in 10.8 seconds. All 21 current
  one-shot cases pass in 9.4 seconds after the shared fixture repair. Retained
  outputs:
  - `/private/tmp/loopex-m7-buffered-native-key-screen-current.log`, SHA-256
    `dbc4266a0f718c93052c25286410bc57a70d5263be04d08ea63fc27f9b0b13dc`.
  - `/private/tmp/loopex-m7-buffered-native-key-screen-floor.log`, SHA-256
    `29f8d2032ffe579a30b16f4e4c008b34950907f0d1431a6f0ff76ab4e4889c81`.
  - `/private/tmp/loopex-m7-buffered-native-conformance.log`, SHA-256
    `c996c82672c7d86119eea71131a33437c1e5711da97252f7d58a193d8a1321d9`.
  - `/private/tmp/loopex-m7-buffered-native-floor.log`, SHA-256
    `768d72ec8df13705931747cfc28a30f23c0cd1ce7c2295e09d25bd7ea195a9b6`.
  - `/private/tmp/loopex-m7-buffered-native-one-shot-repaired.log`, SHA-256
    `667ad7ad2b339197d15380752c6b4c3fe06b82a512200341f46e22e9b332a2fc`.
  - `/private/tmp/loopex-m7-private-body-worker-regressions.log`, SHA-256
    `c25bf126d4dbfc2f0e8631267f35f99eb75af7ff7cb6f223be578f9ee5696743`.
  - `/private/tmp/loopex-m7-buffered-native-host-exclusion.log`, SHA-256
    `bb0f287c520bb094a339f2b9a12636a4a62fe63fafe6a5201d47dc0fb7edf147`.

- 2026-10-01: the full fast check of
  `ca63492e008c001046aba0dde159d2818253850e` failed 27 tests across core,
  daemon and CLI; the other eight application suites passed, including all
  369 adapter tests. Retained output:
  `/private/tmp/loopex-m7-ca63492e-fast-check.log`, SHA-256
  `00dd58b8d6af79a24a096ff59c29da83e124b7b63c2172a766b0282706214ece`.
  The historical interaction positive control still contained a v3 settlement;
  nine synthetic native stream builders omitted the initial null stop fields;
  and both new configuration parsers directly named an adapter implementation.
  The raw-byte accounting witness also reached Anthropic's new smaller native
  ceiling before Core admission. Corrections encode the historical control's
  v2 settlement explicitly, complete the native fixtures, route model syntax
  through composition, and exercise the same 65,537-byte Core refusal over the
  existing OpenAI Responses HTTP path. Settlement-depth compaction remains an
  Anthropic HTTP witness. No bound, accounting assertion, cleanup assertion or
  architectural scan was weakened. This failed candidate is retained as failed.
  Focused current-toolchain validation passes the historical reader case in
  4.0 seconds, 29 accounting/configuration/boundary cases in 6.3 seconds,
  30 live CLI cases in 395.2 seconds and three daemon cases in 16.0 seconds.
  The source-built foundation and multi-client cases also passed in the first
  nine-case repair run, whose sole remaining raw-byte failure was fixed and
  re-proved in the accounting run. That exploratory run remains recorded as
  eight passed and one failed, not as a green run. Retained outputs:
  - `/private/tmp/loopex-m7-config-accounting-repaired.log`, SHA-256
    `3761ecf1a854749d167d956fe8f35c2707fc9b9dc794403b573e78db797d01dd`.
  - `/private/tmp/loopex-m7-native-fixtures-live-cli.log`, SHA-256
    `215b9bf248d54112e58a7f2b3485b00219d8e96f498d6577d10dec45c4004846`.
  - `/private/tmp/loopex-m7-native-fixtures-daemon.log`, SHA-256
    `354bc84cb671481972b734cd124c4de7e499dc706745c488dc012e6ea753540f`.
  - `/private/tmp/loopex-m7-fixture-regression-cli.log`, SHA-256
    `a007c6636f6203c87a517d8a7615e80d2c51b53d778234401d8e4bf791ca73a5`.
  The floor pair passes the boundary case separately in 1.6 seconds and all
  28 accounting/configuration cases in 7.3 seconds. Its ExUnit line selector
  excludes the other files when mixed, so those files ran separately.
  Warning-free compilation, formatting, 1,008-entry documentation ordering,
  dependency direction and milestone status checks pass. Floor outputs:
  - `/private/tmp/loopex-m7-config-accounting-floor.log`, SHA-256
    `c83531d10ef48b2035ab9ecad4668328bab13d9a986da3fe057fd4235a20ab5b`.
  - `/private/tmp/loopex-m7-config-accounting-floor-files.log`, SHA-256
    `a8b9b3f810cfde4487b96f614e24ec390e407a9b60004126c5c77fe1dc466b12`.

- 2026-10-01: the durable Anthropic worker now normalizes model/options/context
  before the pinned `Streaming.start_stream/4` handoff and uses invocation-owned
  provider/parser callbacks. The exact callback inventory is `stream_transport/2`,
  `stream_protocol_parser/2`, `parse_stream_protocol/2`, `init_stream_state/1`,
  `decode_stream_event/3`, `flush_stream_state/2` and `attach_stream/4`.
  Native content stays in private capture; only admitted public deltas and the
  actual message-stop marker enter dependency conversion. The private failure
  latch independently wakes the owner, which cancels the exact stream and joins
  its drain. The drain is linked as well as monitored so owner death also stops
  a blocked progress callback. The selected credential enters only the private
  request builder; raw payload telemetry is disabled per invocation, and its
  model contains no capture handle. Capture status formatting excludes private
  state, messages and reasons. Existing protected-companion custody remains the
  production boundary; this adds no host-VM secrecy claim.
  Native stop evidence now produces v3 completion/capsule fields through the
  private codec. Generic rows reject thinking/redacted blocks and preserve
  natural/limit/unknown classification. Converted thinking labels on other
  paths no longer authorize reasoning disclosure. The shared canonical-call
  mapper uses full generations and refuses malformed arguments. Terminal result
  groups and following prompts share one native user array across empty assistant
  completions. Buffered capture, ordinary cell registration and live-provider
  proof remain open.
  The local HTTP cases exercise byte-framed Unicode/tool JSON, redacted blocks,
  exact outgoing limits, response identity, summary eligibility and invalid
  terminal controls, malformed interior input, incomplete original EOF, raw
  comment overflow, blocked-drain cancellation, owner death and telemetry
  exclusion. Companion fixture routes are now selected before the final hook.
  Backpressure fixtures use a 12,288-byte head within the native content ceiling;
  their actual socket-pending, writer-stack, queue/count and cleanup assertions
  remain required. Incomplete native input now fails at parser/flush rather than
  converted completion metadata; typed transport and callback diagnostics retain
  their closed categories.
  Memory accounting for pinned ReqLLM 1.24.0: one cumulative 8,388,608-byte body
  budget covers pending parser input, tool JSON and each transient decoded batch.
  Completed native content is capped at 16,384 JSON bytes/128 blocks. Capture
  keeps no event log, and the drain retains only one delta plus its count. Each
  public fragment passes the Model payload bound; total queued payload and event
  count are bounded by the same raw-body budget, including a batch that exceeds
  the dependency's 500-chunk watermark. The synchronous single Finch producer
  cannot add an unbounded pending-call queue. `ChunkAccumulator` ignores the
  private delta envelope; StreamServer metadata replaces its last delta rather
  than accumulating them, object mode is off, and fixture raw capture is refused.
  Dependency telemetry retains bounded summaries/options and the already bounded
  request; its model has no invocation handle and its options have no selected
  credential. Request/capture/codec values retain their existing independent
  bounds. These bounds include linear term overhead; no byte-exact BEAM heap
  size or new response-header bound is claimed.
  A broad exploratory adapter run from the dirty checkout was stopped after
  identifying fixture-route migrations and clean-source prerequisites. It is
  failed/incomplete evidence, not a fast-check or candidate pass.
  Final focused checks pass 126 tests in 103.4 seconds on the current toolchain,
  including actual companion/backpressure/failure-category cases, and 101
  native/mapping/codec/conformance tests in 12.3 seconds on the floor pair.
  Retained outputs:
  - `/private/tmp/loopex-m7-native-bridge-checkpoint-current.log`, SHA-256
    `92e5b85ff1907ff038bd9f8537e8497453c4497d04d40e670cf5e9ba1620a770`.
  - `/private/tmp/loopex-m7-native-bridge-integrated-floor.log`, SHA-256
    `ae90d3003bd5709c661f25ab6821e08a57b94025a30ea26de461dcbfd20e58c0`.

- 2026-10-01: native request preparation now validates the nine literal captured
  cells, strict manual-budget/output-limit relation and unchanged tool definitions
  before rendering controls and expanded native arrays. Known call names resolve
  through their complete generation; retained arrays are checked against canonical
  text and calls, and tool results use retained native IDs. Unregistered default
  requests retain dependency rendering and have no summary disclosure eligibility.
  The pinned Anthropic builder preserves these controls and ceilings for all nine
  cells and a continued tool exchange. A final invocation hook compares the whole
  Finch request after the global hook, refusing body, route, header or transport
  mutations with a fixed error without logging request material. Only the admitted
  tool beta is allowed, and only when tools are present.
  Focused request/stream/capture checks pass 25 tests in 1.7 seconds on each
  supported toolchain. Retained outputs:
  - `/private/tmp/loopex-m7-native-request-current.log`, SHA-256
    `4f68fef72fb21c18f4312f30ff387343c371e2823133924c883388e4ce87c089`.
  - `/private/tmp/loopex-m7-native-request-floor.log`, SHA-256
    `86f58a470ca55dce97e34802f416a7fc96e84d87bd2a740df0e2c85b3aba4ad8`.
  This prepares the boundary but does not yet join the live transport, buffered
  capture, fatal wakeup or public summary path, or register thinking support.

- 2026-10-01: added the private native stream reducer used to prepare the
  invocation bridge. It admits exact message/block ordering, literal response
  identity, type-correct deltas, concatenated signatures and parsed object
  arguments, preserving empty and redacted blocks. Final cumulative usage
  replaces prior counters; missing/invalid evidence remains unknown. It retains
  assembled blocks and one open block instead of an event log. Failure clears
  captured content and cannot be reversed by later input or flush. Raw HTTP
  bytes, including comments/pings/framing, spend one 8,388,608-byte budget before
  parsing. The native array has an inclusive 16,384-byte JSON cap and 128-block
  limit. Tests pin ServerSentEvents.Parser 1.1.0 and ReqLLM 1.24.0's SSE.flush/1;
  unknown parser states and incomplete original framing refuse instead of
  acquiring completeness from synthetic newlines. Byte-split input reconstructs
  the same native content as buffered capture.
  Native assembly/capture checks pass 15 tests in 0.2 seconds on each supported
  toolchain. Compilation is warning-free; format, documentation ordering and
  dependency direction pass. Retained outputs:
  - `/private/tmp/loopex-m7-native-stream-assembly-current.log`, SHA-256
    `a16c4b78512843bef85dc7ad4b6afcff8f82d27365b7b7a90c799adfa5f5246c`.
  - `/private/tmp/loopex-m7-native-stream-assembly-floor.log`, SHA-256
    `f4a8dd73e158a6e5c7073f3fcc6071abe75c7fe203fe10b21322bf94e50405b1`.
  The invocation-owned wrapper, fatal notification and blocked-drain wakeup,
  final request-hook validation, buffered transport join, dependency queue
  memory proof, public-summary classification and per-cell transport conformance
  remain open. This reducer alone does not change live transport or register
  thinking support.

- 2026-10-01: ordinary open exchanges now stage the closed ADR 0044 envelope
  from committed full settlement records and canonical lineage source positions.
  The shared expander checks both complete-envelope JSON limits, entry/block
  limits, ordered call/result mappings and native/canonical ID collisions.
  Revision-four receipts charge Canonical.encode(E(request)) independently of
  ordinary descriptor totals; replay derives source identities and all cost
  fields instead of accepting self-consistent replacements. V1 requests remain
  nil-only. A three-turn scripted exchange proves stable prefixes, exact source
  digests and capsules, extended mappings, cost arithmetic and next-prompt nil
  continuation. Collision refusal occurs before another tool intent. An owner
  killed after executor receipt commit resumes on a new runtime without its
  original project manifest, preserving the frozen content and avoiding a
  repeated effect. Unexpandable aggregate content produces a replay-verifiable
  unavailable preparation failure before another provider attempt.
  The current affected core run passes 249 tests in 48.6 seconds; the supported
  floor passes 34 continuation/configured-owner tests in 3.1 seconds. Adapter
  mapping/native-content checks pass 20 tests in 3.0 seconds. Warning-free
  compilation, formatting, dependency direction, documentation ordering and
  repository status pass. Retained outputs:
  - `/private/tmp/loopex-m7-continuation-owner-core.log`, SHA-256
    `6c35be6163ae7cd21e3f6a48f033d49d49ca6be0e9414720ac0a48cdc1f1a680`.
  - `/private/tmp/loopex-m7-continuation-owner-floor.log`, SHA-256
    `1e87297ced677377735df67c4b9f5f0fa3ffbd78487de570a0b8030b6c04163a`.
  - `/private/tmp/loopex-m7-continuation-owner-adapter.log`, SHA-256
    `b8909e8a86828918051719331a8df758d56371606a5da5cd9050be5a75ea240f`.
  These are model-port proofs. Native transport, registered thinking cells,
  resource-pack restart vectors, maintenance accounting/headroom and full
  real-provider evidence remain open. The measured size-refusal path for a
  frozen request with optional-provenance blocks awaits the schema decision
  above; no substitute failure or fabricated count has been introduced.

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

### Original checklist

- [ ] Inventory every affected record, API, tool generation, adapter and protocol.
- [ ] Pin schema definitions, digests, compatibility vectors and provider mappings.
- [ ] Create the M7 fixture manifest with exact prompts, budgets, allowed changes and objective results.
- [ ] Assign every operator step and negative scenario to a named test or demonstration.
- [ ] Prepare the indexed closure-evidence scaffold with results marked Pending.
- [ ] Retain the exact historical binaries and session roots needed for migration and rollback.
- [ ] Verify manifest completeness, invalid-manifest rejection and actual instruction/tool-schema costs.

### Added implementation subtasks

- [x] Map the 22 accepted contract families to implementation owners and retained/new generations.
- [ ] Join that family inventory to exact payload schemas, path inventories and decoder vectors.
- [x] Pin legacy and planned M7 read-definition canonical preimages/digests and the revision-1 literal artifact-read capability table.

<a id="t01-conversation-continuity"></a>
## T01 — Preserve conversation across prompts and restarts

### Original checklist

- [x] First add a failing test reproducing the current loss of earlier conversation.
- [x] Project the complete committed conversation into subsequent model requests.
- [x] Join tool calls and results using their run, turn and call identities.
- [x] Normalize provider-facing call IDs and reject collisions or incomplete joins.
- [x] Reset each run’s accounting without deleting conversation or recovery facts.
- [x] Preserve already staged requests unchanged.
- [x] Test multiple prompts, follow-ups, tools, cancellation, failed runs, restart and uncertain commits.

### Verification evidence

T01's final original item is proved by the following live-runtime cases, with
pure projection/replay tests supplementing them:

- Multiple prompts and tools: `agent_loop_test.exs` checks the second actual
  model request's complete ordered prompt, assistant and tool history.
- Follow-ups: the promoted-follow-up case retains the predecessor's history
  while its new run starts with zero charged tokens.
- Cancellation: `configured_session_test.exs` aborts a pending model question
  and checks that the next actual request retains its cancelled tool result.
- Failed runs: the new agent-loop case commits a tool exchange, fails the next
  model call after transient text, then checks the following prompt retains
  the exchange and excludes that uncommitted text. Live and recovered lineage
  are identical.
- Restart: both legacy and captured-genesis cases stop the runtime and stage
  later prompts from retained history; the configured case also preserves
  exact captured instructions, settings and tools.
- Uncertain commits: the new cases inject `commit_unknown` before persistence
  and after persistence but before the Store reply. Retrying the same prompt
  retains two total runs and exactly one later model request. The recovered
  conversation contains each prompt and answer once.

The complete `agent_loop_test.exs`, `conversation_test.exs` and
`configured_session_test.exs` pass 151 tests on both supported pairs on
2026-10-01. Current takes 26.9 seconds and floor takes 27.0 seconds. These
credential-free checks complete the original T01 testing item; the real-provider
second-prompt witness and milestone closure checks remain open.

- Current output: `/private/tmp/loopex-m7-t01-continuity-current.log`, SHA-256
  `a3fe73a479845861f7e0c53aa087e64c5435352ec21912b3584b901c1bf534f5`.
- Floor output: `/private/tmp/loopex-m7-t01-continuity-floor.log`, SHA-256
  `d2b576cf58dba3c0d3154f9dc6c4ed2e5337085f5a5f4b3cdbc7d40592043969`.

## T02 — Handle large tool output and bounded artifact reads

### Original checklist

- [ ] Prepare bounded excerpts while retaining complete original results.
- [x] Implement capability checks from the exact frozen tool definitions and literal capability table.
- [ ] Keep replay independent of current host-registry availability.
- [ ] Validate artifact ownership and arguments in the session owner before policy admission; add resolved executor data after approval.
- [ ] Implement 4-KiB range reads, encoded-result limits, offsets, progress and EOF.
- [ ] Add bounded preparation, aggregate excerpt allocation and job-owned transfer accounting.
- [ ] Preserve legacy inline behavior where the complete request fits.
- [ ] Test escaping, Unicode, forged references, cross-session access, digest mismatch, exhaustion, cancellation and recovery.
- [x] Audit the existing attachment-budget baseline without silently taking on deferred M8 work.

### Added implementation subtasks

- [x] Implement and test pure exact-generation derivation and retained-binding validation.
- [x] Enforce the literal read-generation table during runtime/registry loading and executor startup; select executor tools by exact ID/version and retain the frozen capability through restart with an empty host registry. Artifact range execution and prepared-reference replay remain pending.
- [x] Resolve committed-receipt artifact membership and closed range arguments before policy, keep policy/deferred identity on original arguments, and bind approved job resolution to the exact retained source. Prove cross-session refusal, uncertain receipt commits, restart and altered-source replay refusal; prepared-reference membership remains pending.
- [x] Reproduce and repair source-descriptor leakage on snapshot creation failure; close snapshot descriptors on permission/unlink failure and verify existing transfer behavior on both supported toolchains.
- [ ] Enforce the accepted job-owned cancellation/deadline and cumulative-work bounds when integrating range execution; the attachment implementation does not yet provide these guarantees.
- [x] Implement pure UTF-8 range-result encoding and prove maximal progress under the complete encoded conversation-message ceiling, including escaped content and metadata, through the real lineage projector.
- [ ] Implement the maintainer-selected optional job-range callback and join its verified bytes to the range encoder and executor settlement.

### Verification evidence

On 2026-10-01, the maintainer answered the storage-boundary decision with
“Separate optional job-range callback (recommended).” The presented choice was
`ArtifactStore.read_job_range(handle, validated_job)`, performing one verified
window with job deadline/cancellation, shared four-transfer capacity, bounded
work accounting and cleanup before return. Adapters lacking the callback refuse
job range reads; the existing attachment triple stays compatible. The alternative
was versioning and extending that triple with job context. This records the
current maintainer decision authorizing the new cross-application callback;
implementation and its conformance proof remain pending.

`Executor.Local.ArtifactRange` now encodes an already verified window, without
storage access or a claim of membership/integrity validation. It retains the
original full reference, actual offset/count, next offset and EOF. Malformed
UTF-8 and starts inside a codepoint refuse; a partial trailing codepoint shortens
only before object EOF. If no whole character fits, it refuses instead of
returning zero progress. Offset at EOF permits an empty result. A binary search
over codepoint boundaries chooses the largest prefix fitting the encoded limit.

Sizing includes the actual conversation tool-message shape, including its
second JSON escaping of the inner range content. Revision 1's fixed 51-byte
normalized call ID permits exact measurement without putting a fabricated ID
into executor output. A real `Conversation.lineage_entries/1` witness uses a
long original provider ID, retains the range bytes exactly and proves the final
message matches that measurement. Additional cases cover escaping, UTF-8,
metadata exhaustion, invalid windows, final ranges and maximality across seven
limits. This prepares encoding; it does not yet enable the 1.1.0 executor tool
or complete the original range-read checkbox.

All seven range-encoding tests pass in 0.09 seconds on each supported toolchain.
Retained outputs:

- Current: `/private/tmp/loopex-m7-range-projection-current.log`, SHA-256
  `a5a85d11d33bec3fac3c37c02870ba8c67a1e629e5450726cb9802fe4501f0e2`.
- Floor: `/private/tmp/loopex-m7-range-projection-floor.log`, SHA-256
  `68ef29af9d964c47bc74555be1ca5ba58444a14fb49bb57bf8da8d6d74b0cfdd`.

The attachment baseline audit follows `Runtime.EventDispatcher` through
`Store.Local.Artifacts` into `Store.Local.Transfers`. The dispatcher counts two
transfers per attachment, and the shared store owner counts four live transfers.
It does not implement a connection-wide cumulative work ledger. This agrees
with the existing disclosure in
[runtime and embedding](../developer/runtime-and-embedding.md#technical-embedding-transfers).
The local verifier checks the 64-MiB object limit, hashes the whole object into
an unlinked snapshot, checks an elapsed open deadline between copy blocks, and
subtracts source reads plus snapshot writes from its per-open budget. That
budget is checked on the next iteration rather than reserved before storage.
The read path bounds emitted chunks but does not enforce the advertised
five-second read deadline. Neither adapter forwarding nor its transfer owner
binds open/read work to an executor job's deadline or cancellation.

These findings do not prove ADR 0041's job profile. Its one-window ownership,
shared runtime capacity, shortened deadlines, pre-storage reservation, minimum
open debit and cumulative job allowance remain implementation obligations.
Connection-wide attachment remediation remains outside this T02 audit; no
protocol, connection budget or attachment ownership behavior changes here.

The audit also reproduced a cleanup defect: replacing the snapshot directory
with a regular file makes snapshot creation fail after the source opens. The
new serial regression captures that descriptor and reads it in its owning
process after the failure acknowledgement. Before the fix it returned a source
byte; afterward it returns `einval`, with the owner still alive and no retained
transfer. Source opening now scopes cleanup over snapshot creation and copying.
Snapshot permission/unlink failures also close the opened snapshot descriptor
and attempt to remove its path. The latter branches are inspected cleanup paths;
the deterministic fault witness exercises snapshot creation failure.

Both complete transfer test files pass 30 tests in 1.5 seconds on each supported
toolchain. Retained outputs:

- Initial failing regression: `/private/tmp/loopex-m7-transfer-cleanup-before.log`,
  SHA-256 `f323d15cfcf0dbe34aa7e80dbc2a55689aa6a22449a8b67de4e252362c5556ce`.
- Current: `/private/tmp/loopex-m7-transfer-cleanup-current.log`, SHA-256
  `ada62ea8a3b5c5d303bf4ef77b183f4fa10c9b86196a729d9fc57056b7514314`.
- Floor: `/private/tmp/loopex-m7-transfer-cleanup-floor.log`, SHA-256
  `523119e0701cfa20b6855f3232951a53ef3bd1a837969cd372a7bf3576d3bbde`.

Receipt admission now reconstructs a private use index from committed executor
receipts. The index stores the full reference and its earliest source identity;
conflicting reference bytes make a use unusable. The source digest is the
canonical digest of the complete private receipt-record payload, alongside its
journal position and original run/operation/attempt/call identities. This is a
derived cache, with no new receipt fields or object reads. Ordinary path arguments
and artifact ranges have separate closed branches for the exact M7 read generation.
Unknown/injected/cross-session uses, invalid bounds and offsets beyond object size
produce the same failed `invalid_tool_arguments` disposition before policy.
Offset equal to object size remains admissible for the executor's EOF handling.

Policy and deferred interaction identity retain the original model arguments.
After allow, the journaled executor job receives `resolved_artifact`; replay
recomputes it from preceding committed sources and frozen definitions. A
self-consistent job digest cannot substitute the source. Receipt commit-unknown
on either side of persistence retains one reference, and a held uncommitted
receipt admits no subsequent read policy or job. Restart reconstructs membership
with an empty host registry. These tests use a scripted executor to prove owner
admission; real range IO, transfer accounting and prepared-reference records are
still pending and the original ownership/recovery items remain unchecked.

Seven new cases plus the affected artifact, agent-loop, interaction and configured
session suites pass 165 tests on each supported pair, in 38.5 seconds on current
and 38.7 seconds on floor.

- Current admission/regressions:
  `/private/tmp/loopex-m7-t02-artifact-admission-regressions-current.log`, SHA-256
  `57321d9da5d4a4a0fefc299669318e28c760fa0f37cd3643cc0e59b4a22afa80`.
- Floor admission/regressions:
  `/private/tmp/loopex-m7-t02-artifact-admission-regressions-floor.log`, SHA-256
  `ba8fd9afb57b534732335a060ed3de2039b4f657a6901bd2cf4c0c08eb15a9eb`.
- Initial five-case admission proof, 0.7 seconds:
  `/private/tmp/loopex-m7-t02-artifact-admission-current.log`, SHA-256
  `1fc7dfee0dfdeff15191a060cd1c7bb689614bd979307c830ee34ae0d7481747`.

Runtime startup and reference registry loading refuse changed read versions,
descriptions and budgets. Both pinned read generations coexist in the runtime
registry and resolve individually. The local executor checks its compiled
definitions against the same literal table before starting; job resolution
matches ID and version together. A valid host grant cannot make an unavailable
read version execute as the legacy generation. The configured-session restart
test stages three prompts across two runtimes with the exact M7 read definition;
the second runtime has no registered read tool, while recovered genesis retains
the original capability digest and staged definitions.

For the generation-check change at `1c3670de5cd51057dde2be23c173a5a42ab26a1b`,
the current Core suite passes 785 tests with its five existing long-duration
exclusions in 158.4 seconds. The 86 affected Core tests pass on the floor pair
in 3.8 seconds. Local-executor/coding-tool tests pass 148 cases on both pairs,
in 114.5 seconds on current and 116.5 seconds on floor.

- Current Core: `/private/tmp/loopex-m7-t02-core-fixed-current.log`, SHA-256
  `297e08c4f0960c94139fc581b191d63f0e8d1529c4eaf44c23d58e5bc2c3d1ba`.
- Floor Core: `/private/tmp/loopex-m7-t02-core-floor.log`, SHA-256
  `941753f9293a8f8655f68b07d3133536ac9c4c0748cd8b1ca63bdd9b452e570c`.
- Current executor: `/private/tmp/loopex-m7-t02-read-executor-current.log`, SHA-256
  `b8019ca4cfc0d8905cf90673e60cf0b659400721e9fd224cedd5139d96484fca`.
- Floor executor: `/private/tmp/loopex-m7-t02-read-executor-floor.log`, SHA-256
  `f0345548b40d5897efd9be1a5dc7637081b4fc1782d55306cc9d1d01f0f9a5f6`.

The first Core run failed six tests. Five used a stale reference read fixture
with a 65,536-byte output budget instead of the pinned 16,384-byte value. The
fixture now matches the literal generation without changing its exact size or
token assertions; its obsolete startup fallback no longer turns a refusal into
a bogus runtime reference. The sixth test depended on suppressed SASL reports
and raw rather than translated supervisor text. It now enables that report class
within the serial test, restores the original filter configuration and still
requires the actual child-failure report and reason. No production logger policy
or check was relaxed.

- Initial Core failure: `/private/tmp/loopex-m7-t02-core-current.log`, SHA-256
  `46233f458a3036707c926c07eb575a66f0fbe99f1e453f6a716fabdedd5d7136`.
- Focused repair proof, 26 cases in 2.1 seconds:
  `/private/tmp/loopex-m7-t02-regression-repairs-current.log`, SHA-256
  `26a26f4e237d3a44279837b66221c6b9f5e4cef31837d10891bb7cc7cb5707f0`.
- Initial registry test expected an internal refusal instead of the established
  public `invalid_runtime_options` response:
  `/private/tmp/loopex-m7-t02-read-registration-current.log`, SHA-256
  `e66f11bae7f1c59c0ab32d44524f4590e4b4018ffb634ceeb4d5d5a95e01fbf6`.
  Corrected 32-case run passes in 0.5 seconds:
  `/private/tmp/loopex-m7-t02-read-registration-fixed-current.log`, SHA-256
  `37e9f867e0ac1c0efe0af5a3fc12aa287ac6ad7b0ca6d03ca06fdc3c0afbbdbf`.

## T03 — Implement host-composed instructions

### Original checklist

- [ ] Replace core’s fixed instructions with the accepted host instruction map and rendering.
- [ ] Keep project and skill resources separately typed and admitted.
- [ ] Capture workspace/environment facts and exact selected tool schemas.
- [ ] Enforce the configured system ceiling and complete serialized-request limit.
- [ ] Implement receipt revision 4, including continuation costs and source/configuration binding.
- [ ] Preserve old receipt decoding.
- [ ] Test admitted, declined, changed and oversized instructions, long paths, restart and exact staged bytes.
- [ ] Prove instructions cannot widen policy or helper authority.

### Added implementation subtasks

- [x] Implement pure closed instruction capture, exact rendering and retained-digest validation; preserve legacy fallback bytes through the shared renderer.
- [x] Stage captured v3 instructions with configuration-bound revision-4 provenance and exact system/tool costs; reject substituted configuration/source identities on replay.
- [x] Implement reference-host default/explicit/role capture, bounded regular-file reads and exact JSON environment byte/digest vectors; live configuration/chat wiring remains pending.

## T04 — Implement configuration, genesis and provider routing

### Original checklist

- [x] Implement the shared pure genesis resolver and validator.
- [x] Support exact-genesis creation, finding duplicates before expanding changed defaults.
- [ ] Implement the closed configuration-file schema and command-line grammar.
- [ ] Implement file/flag precedence, validation and effective-value display.
- [ ] Require explicit conversation bounds in the file, including when flags override them.
- [ ] Retain committed session settings, tool selections, roles and delegation declarations.
- [ ] Allow maintenance settings to change new episodes while preserving already admitted episodes.
- [ ] Implement named provider and credential bindings through the existing custody boundaries.
- [ ] Abandon prepared owners on every post-preparation refusal; retain uncertain cleanup honestly.
- [ ] Test malformed files, duplicate keys, overrides, resume conflicts, missing bindings, changed catalogs and cleanup failures.
- [ ] Prove configuration inspection reads no credentials and starts no runtime or provider call.

### Added implementation subtasks

- [x] Share the v2 resolver/decoder between creation and replay; pin unchanged transaction bytes and exact normalized byte boundaries.
- [x] Extend that same resolver/decoder with v3 configuration, immutable tool selection and literal artifact-read derivation.
- [x] Validate closed captured configuration, combined metadata byte limits, budget origins and complete system-class tool costs; retain v3 settings through pure replay.
- [x] Resolve complete initial configurations through that validator, deriving known/unknown context budgets and retaining explicit/default origins.
- [x] Integrate v3 creation and configuration-aware live owner staging, including frozen request/receipt identities.
- [x] Implement bounded JSON syntax decoding with exact integers, redacted errors and duplicate-key JSON pointers; prove callbacks under both supported toolchains.
- [x] Implement shared pure provider-binding/reference validation and sorted launch exclusions from the adapter's compiled catalog; environment resolution/custody/startup integration remains pending.
- [x] Validate closed authored-file objects, required conversation bounds, role/route/delegation relationships, explicit context ceilings and trace limit domains before overrides.
- [x] Load bounded selected regular config files, retaining authored/resolved profiles with config-relative literal paths and resolved byte bounds; prompt-file and effective-profile admission remain later stages.
- [x] Resolve trace selectors through fixed trusted application-module manifests without input atom creation or application startup; owning trace startup/drain/teardown integration remains pending.
- [x] Parse the complete chat/config-inspection flag grammar with duplicate/conflict refusal, bounded array overrides, exact numeric domains and shared registries; effective-profile and command-entry integration remains pending.
- [x] Compose new-session file/flag/LOOPEX_HOME precedence and harmless literal defaults with complete value origins and array replacement; capability/instruction admission and redacted effective display remain pending.
- [x] Join selected new-session declarations, captured instructions and tool definitions to credential-free route/mapping resolution and whole-configuration admission, preserving effective budget origins.
- [x] Admit the durable adapter's closed token-route branch and select the committed provider before child startup; prove selected private bootstrap and unbound-route refusal.
- [x] Share explicit durable credential loading between direct and borrowing plane constructors, with complete-name validation, deduplicated reads, joined partial-start cleanup and fresh borrowed trace capabilities.
- [x] Carry configured launch exclusions through executor job and drain ownership, preserving legacy receipts; prove first-image exclusion after reinsertion and real job/helper propagation.
- [x] Validate and forward captured exclusions inside project Git discovery, resource-import executors and placement probes, including lock release; reject the conflicting LC_ALL credential slot before loading.
- [x] Admit direct and borrowed version-2 planes in durable runtime composition, validating every token route and resolving explicit maintenance selection before owned effects; prove all three constructor lifecycles and partial-loading cleanup.
- [x] Forward immutable exclusions to Store writer probes, executor launches and provider companions; preserve private model options and unchanged marker, job and receipt formats.
- [x] Wire daemon bootstrap through shared binding validation/loading, multi-custody ownership and cleanup, model/maintenance forwarding and scoped placement acquisition/release.
- [x] Extend the offline CLI credential cache and shared startup to borrow explicit routes, refuse rebinding and scope discovery/placement exclusions; verify existing recovery workflows on both toolchains.
- [x] Forward explicit foreground-server provider/model/maintenance options with preflight refusal and real subprocess startup/EOF cleanup on both toolchains.
- [ ] Finish provider bindings and captured exclusions through chat, daemon-command and remaining ask/helper entrypoints, including discovery and helper preparation.

## T05 — Update records, protocols and independent clients

### Original checklist

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

### Original checklist

- [ ] Add loopex chat through the existing session/runtime facade.
- [ ] Join explicit configuration, continuity and instructions.
- [ ] Support prompts, status, wait, abort, bounded output and truthful shutdown.
- [ ] Prove two prompts and restart through the built command.
- [ ] Preserve existing ask, durable-run and embedded workflows.
- [ ] Test startup refusal, admission failure, output and cleanup.
- [ ] Later retain the required attended multi-prompt proof.

### Added implementation subtasks

- [x] Prepare exact new-chat configuration, instructions and immutable tools before credentials; wire opt-in question definitions through durable constructors and prove prepared genesis creation/restart on both toolchains.

## T07 — Implement automatic and explicit compaction

### Original checklist

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

### Added implementation subtasks

- [x] Validate explicit Core maintenance model/instruction startup settings and privately forward exact captured instruction bytes to session owners.
- [x] Validate and forward explicit maintenance instructions through all durable constructors and ephemeral startup before owned effects, preserving per-call refusal.
- [x] Resolve the separately configured host summarizer and prove its fixed-budget thinking-off native request and natural completion through both transports.

## T08 — Implement model selection and private thinking continuation

### Original checklist

- [ ] Implement committed per-run model/reasoning configuration and the permitted configure fields.
- [ ] Implement the exact adapter replies, canonical replies and monotonic settlement generations.
- [x] Implement bounded in-capsule reference expansion, with no artifact substitution or external lookup.
- [ ] Preserve expanded native blocks, strings, ordering, IDs and parsed arguments.
- [ ] Implement continuation accounting, reserves and compaction headroom targets.
- [ ] Implement all nine accepted thinking cells and the separately configured summarizer.
- [x] Build the native transport bridge: validate final requests after hooks, capture before conversion, and preserve admitted controls and ceilings.
- [x] Bound raw streaming/parser buffers; implement fatal-error latching, flushing and wakeup.
- [x] Test the bridge against a local HTTP server before integrating live-provider proofs.
- [ ] Test model switching, crashes, cancellation, malformed replies, overflow, usage accounting and privacy.
- [ ] Complete the seven thinking-round subcases, nine bound subcases and cancellation witness, including their prescribed subsequent prompts.

### Added implementation subtasks

- [x] Prepare closed whole-candidate mutable updates with bounded inputs, monotonic versions and retained explicit/derived budget origins.
- [x] Prepare atomic configuration admission/replay with exact command identity, single-copy instructions, retained earlier run captures and public event allowlists.
- [x] Gate prepared configuration admission/replay on captured terminal-tool-history capability, preserving empty-completion and cross-run semantics.
- [x] Gate ordinary configured provider intent on terminal-history capability and retain the unavailable v2 preparation-failure pair without fabricated observations.
- [x] Join prepared ordinary candidates to settled owner admission, exact retained-history preflight, atomic commit and replay.
- [x] Prove configuration restart, commit-unknown re-presentation and owner crashes before/after linearization through the live runtime.
- [ ] Join host resolution and prepared daemon routing; extend configuration preflight to committed checkpoints and maintenance quiescence.
- [x] Capture bounded limits and source bindings from the exact pinned packaged catalog without mutable lookup; preserve unknown limits and the literal accepted alias.
- [x] Register all nine literal reasoning cells after deterministic native request/response, bound, disclosure and terminal-history conformance; share exact mappings with transport validation.
- [ ] Join registered reasoning subsets and exact mapping resolution to whole-profile preparation.
- [x] Prepare exact v2/v3 callback projection, source-bound v3 settlement readers and monotonic historical-prefix recovery before writer migration.
- [x] Emit v3 for every new ordinary settlement, migrate exact callback fixtures, and prove whole-record accounting, required-capsule admission and historical schemas through live recovery.
- [x] Implement pure exact native-array capture and reconstruction through the shared expander, with closed fields and stop/call relations.
- [x] Build and validate bounded aggregate request envelopes from full committed settlements and lineage positions, including source/configuration replay checks.
- [x] Charge the complete expanded ordinary envelope in revision-four receipts and independently verify every retained cost field.
- [x] Preserve frozen project input through owner recovery, reject native-ID collisions before tools, and retain replayable aggregate-overflow preparation failures.
- [ ] Resolve and implement the numeric refusal schema for frozen project/resource input; prove its exact bounds and replay.
- [ ] Prove frozen resource-pack input and steer ordering across continuation/restart boundaries.
- [x] Implement bounded native event assembly and pinned SSE parse/flush validation with permanent failure, exact content reconstruction and cumulative usage evidence.
- [x] Render captured native requests and seal the final Finch request; prove exact tools, controls and ceilings against the pinned builder and hook order.
- [x] Join native capture and request sealing to the durable worker, with strict reply fields and an owned, monitored drain.
- [x] Prove local HTTP framing, private/public projection, blocked-drain failure, owner death and telemetry exclusion.
- [x] Share full-generation canonical call rendering and refuse malformed argument repair across ordinary and native request paths.
- [x] Join buffered native capture/rendering to OneShotHTTP1 with invocation-correlated private state, complete native identity/usage checks and selected-key screening.
- [x] Keep native request bytes out of Finch metadata through bounded one-use body streams without changing wire framing or response delivery.

## T09 — Implement model-originated questions

### Original checklist

- [x] Register the exact question-tool generation without changing old effect definitions.
- [x] Admit questions through policy; no executor grant or job is created.
- [x] Implement producer identity, options, text answers, decline and expiry.
- [x] Atomically settle the interaction, original tool result, response identity and next action.
- [x] Preserve the existing policy-defer lifecycle.
- [ ] Test denial, deferred policy, large answers, overflow, duplicate/stale responses, cancellation and expiry.
- [x] Test crashes before and after pending-question and response commits.
- [x] Prove recovery retains the actual pending question identity.

### Added implementation subtasks

- [x] Pin its format-v2 canonical preimage/digest and enforce exact schema/byte/choice limits before policy.
- [x] Separate interaction tools from executor dispatch and reject nested policy defer.
- [x] Replace the interim policy-allow refusal with committed model-question pending and producer-specific terminal transitions.
- [x] Prove pure recovery retains the actual committed pending question identity.
- [x] Prove live owner restart retains that identity and settles it once.
- [x] Prove commit-unknown re-presentation retains exact pending and response bytes.
- [x] Prove local-store process restart retains the pending question and final answer.
- [ ] Pin pending/response decoder vectors and public question event schemas.
- [x] Pin the shared closed answer schema/union and independent Elixir/Node payload vectors.
- [ ] Join that answer schema and decoder to the complete M7 /3-/4 contracts and both authorized mutation paths.

## T10 — Complete chat controls, pipes and tracing

### Original checklist

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

### Added implementation subtasks

- [x] Implement bounded single-line framing and explicit chat-action parsing, with wait-line backpressure, exact JSON answers and malformed-input refusal on both toolchains; driver admission remains pending.
- [x] Implement the bounded independently draining output writer and escaped transcript lines; prove progress eviction, control deadlines and joined worker cleanup on both toolchains. Closed records and driver integration remain pending.

## T11 — Implement specialized read-only helpers

### Original checklist

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

### Original checklist

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

### Added implementation subtasks

- [x] Join explicit provider bindings to startup and committed-model dispatch, preserve caller-only credential resolution, and forward separately resolved maintenance models to Core.

## T13 — Complete coding fixtures and operator instructions

### Original checklist

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

### Original checklist

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

### Original checklist

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

### Original checklist

- [x] Move M7 to In progress when product work begins.
- [ ] Keep outcome rows linked to actual tests and evidence.
- [ ] Update operator/developer documentation, indexes, compatibility guidance, README, roadmap and changelog.
- [ ] Update verification guidance to the accepted M7 procedures.
- [ ] Run focused unit, property, conformance, fault, security, protocol and CLI tests during development.
- [ ] Run the fast check once per clean integration candidate.
- [ ] Run required selected real-provider, Node, daemon, long-bound and cross-UID lanes.
- [ ] Run changed process-boundary cases thirty times under the prescribed pinned Linux load.
- [ ] Independently review integration changes and fix confirmed defects without weakening checks.

### Added implementation subtasks

- [x] Restore the reference composition size gate by consolidating preflight in the existing DurableOptions owner; preserve validation precedence and constructor behavior on both toolchains.
- [x] Encode the historical interaction positive control with its reader's v2 settlement format while retaining refusal of new interaction records.
- [x] Route configuration model validation through composition and preserve the command-surface dependency scan.
- [x] Complete native stream fixtures across CLI/daemon workflows and retain real-HTTP Core byte-refusal and settlement-depth accounting witnesses.
- [x] Investigate and fix OwnerGroup supervisor shutdown_error/noproc diagnostics observed in configured-runtime test cleanup; retain failing-before and process-lifetime evidence independently of passing assertions.
- [ ] Investigate Task.Supervisor shutdown_error/noproc diagnostics for Task.Supervised children in configuration/input/interaction cleanup; retain reproduction and actual task-lifetime evidence.
- [ ] Investigate the AllowAll notice table ETS-transfer diagnostic emitted to `:init` during host-policy tests; retain an explicit lifecycle witness.

## T17 — Assemble and test the closure candidate

### Original checklist

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

### Original checklist

- [ ] Obtain explicit closure approval on the tested candidate and evidence.
- [ ] Create the administrative direct child confined to the five permitted paths and regions.
- [ ] Record both tested and administrative identities correctly.
- [ ] Verify confinement and status transitions.
- [ ] Fast-forward main to the administrative closure commit under the maintainer’s integration authority.
- [ ] Push and verify the resulting repository state.
- [ ] Clean up landed worker branches/worktrees; retain m7 through implementation and decide its disposition after closure.

## T19 — Prepare and publish the separately authorized release

### Original checklist

- [ ] Select the release label before testing any version-dependent source changes.
- [ ] On the administrative SHA, prove confinement, documentation structure and documentation meaning.
- [ ] Compare tested and administrative source archives using the required complete manifests.
- [ ] Validate modes, paths, source identities and permitted exclusions.
- [ ] Create the authorized annotated tag at the administrative SHA.
- [ ] Push the authorized tag/publication and verify its target.
- [ ] Reuse unchanged-source closure evidence; do not rerun the suite or provider matrix.

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
| Context receipts | ADRs 0042–0044 | Old revisions 2/3 unchanged; new 4 has mandatory continuation_cost and frozen source bindings | SessionCoordinator; SessionState; ContextAdmission | Ordinary nil/non-nil continuation costs and source/configuration bindings implemented; maintenance bindings pending |
| Context refusals and failures | ADR 0043 | Old context_admission_refused_v1 preserved; v2 configurable ceiling and new failure union | ContextAdmission; SessionState; protocol projections | Ordinary measured numeric v2 and unavailable terminal-history preparation failures implemented; other causes, maintenance/headroom and wire projections pending |
| Initial session truth | ADRs 0044/0046 | Read v2/v3 genesis; write coordinated closed v3 configuration/tool-selection/policy-defer payload | Runtime.Control; SessionGenesis; SessionState; Store conformance | Pure decoder/replay and host-private v3 creation implemented; reference-host writer and migration proof pending |
| Exact create and provenance | ADR 0046 | Pure resolve/normalize; exact-genesis create/lookup; read-only creation provenance and stable ordinals | Runtime facade; Control; Store adapters/conformance | Pure helpers and live exact create implemented; exact lookup/provenance pending |
| Atomic configuration | ADR 0044 | Settled configure command; immutable selection; captured version/model/bounds/metadata/mapping | SessionState; SessionCoordinator; composition; protocol | Pure preparation and live ordinary atomic admission/replay, retained-history sizing, restart and commit-boundary faults implemented; host resolution, prepared daemon routing, checkpoint projection and maintenance quiescence pending |
| Model request | ADR 0044 | Read v1/v2; new v2 local-reference continuation with generic expansion | Model; SessionState; SessionCoordinator; model adapters | v2 source-bound staging, bounded expansion, v1 nil-only compatibility and streamed/buffered native rendering implemented |
| Model reply and settlement | ADR 0044 | Bounded reply v3; model_attempt_settled_v3; atomic reply/continuation/accounting | Model; ProviderAttempt; SessionState; adapters | Capsule expansion, native capture, strict callback projection and source-bound v3 readers/writer implemented with migrated callback fixtures; source-bound request envelopes and ordinary expanded accounting implemented; durable and buffered native emission implemented; maintenance accounting pending |
| Thinking mappings | ADR 0044 | Fixed nine registered cells, native block fidelity, frozen-prefix exchange and canonical conversion | ReqLLM mapping/transport; SessionCoordinator | Nine ordinary adapter mappings registered with both native transports, per-cell streaming/bound/disclosure and canonical terminal-history conformance; host integration, separate summarizer and live witnesses pending |
| Maintenance and compaction | ADR 0043/0044 | Captured maintenance configuration, immutable checkpoint and strategy revision 3, source_excerpted | SessionState; SessionCoordinator; ContextAdmission; host startup | Core startup capture and durable/ephemeral instruction forwarding implemented; model routing, episode capture, checkpoint and compaction pending |
| Question lifecycle | ADR 0045 | model_tool/policy_defer producer; bounded choice/text/decline; atomic disposition/result | Interaction; SessionState; SessionCoordinator; host responder | Pending |
| Helper durable ownership | ADR 0046 | Bounded role/catalog bindings; reservation/allowance/monotonic-stop facts; derived job-index v1 | Host helper adapter; Runtime queries; Store; local executor | Pending |
| Host provider bindings | ADR 0048 | Explicit admitted routes and credential references through existing custody boundaries | Composition; ReqLLM provider route/custody; helper adapter | Shared reference/exclusion validation, ephemeral startup/dispatch, durable token selection and direct/borrowed/daemon custody startup implemented; CLI and helper integration pending |
| Host configuration grammar | ADR 0049 | Closed file/flag grammar, exact precedence, role selections, safe inspect and trace options | CLI; composition options; host renderer | Bounded JSON decoder, authored schema, relative file paths, trusted trace selectors, flag parser, new-session precedence/origins and initial capability/instruction admission implemented; complete role/maintenance preparation, command entry and redacted inspection pending |
| Foreground and daemon wire | ADR 0044 coordinated contract | Foreground /3 and daemon /4; complete schema digests/vectors and negotiation | Protocol; AppServer; daemon servers; independent Node clients | Pending |
| Public projection | ADRs 0043–0046/0049 | Versioned snapshots/events; bounded numbers/cursors; allowlisted configuration and maintenance | SessionState; protocol; AppServer; daemon; clients | Pending |
| Ephemeral entry points | ADRs 0042–0045/0048/0049 | Combined closed startup options; one-call responder consumed locally; joined termination | Ephemeral.Options/Preflight/Bootstrap/SessionOwner; facade | Pending |
| Execution evidence | M7 technical acceptance contract | Fixed fixture/operator manifest; Pending scaffold; hash-chained single-writer attempts and fsync barriers | mix loopex.m7_evidence; release runner; PTY driver; evidence files | Pending |
| Upgrade and rollback | M7 compatibility contract | Exact retained M6 artifact/root fixtures; retain old rollback pair and add distinct M7 pair | rollback lane/scripts; Store recovery; operator instructions | Pending |
