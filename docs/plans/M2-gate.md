# M2 Gate

Executable acceptance for `M2`. These canonical UTF-8/LF bytes and their SHA-256
are bound with the accepted plan pair and remain immutable for the milestone.
Progress rows and retained evidence may change only in conformance with that
accepted lock.

The one ordinary gate command is:

```text
bash scripts/check-m2-gate.sh
```

The runner opens by observing the shipped loop itself, and then catches
mechanical accident and drift: a feature whose executable definition does not
exist, a command that stops passing, a protected case renamed or skipped, a
dependency creeping in, a real path that ran against a different provider or
build than the others, an evidence record that does not describe the bytes it
claims. Independent review still judges whether a test asserts what its name
promises, whether cancellations, interrupts, and mutations were honestly
injected, whether the attended demonstration was a genuine coding task rather
than a scripted one, whether the closure documents are current, and whether the
operator experience satisfies the Purpose.

This gate is not `M1`'s. It runs plain `bash` rather than privileged `bash`, it
binds four artifacts rather than nine, and it builds no sealed-environment
apparatus and no environment launcher. Where `M2` needs a check `M1` already
proved, it invokes `M1`'s machinery. What `M2` does not soften is what the
machinery proves: every protected selector still runs through the same
standalone ExUnit channel with the same exact-name, exact-state, and
minimum-count rules, and all eleven of `M1`'s own protected roles — including
both real-provider roles — are re-run beside `M2`'s.

<a id="amendment-transaction-v1"></a>

Any amendment to this gate follows the generic two-revision proposal and rebind
transaction: proposal `A` advances the generation while retaining the prior
Acceptance row and lifecycle state, and its immediate one-parent child `R`
rebinds Acceptance to exact `A` and adds one new disposition anchor. Amendment
sections appear below in physical document order with consecutive numbers.

## Opening Condition

Before reading provider input and before the product state root exists, the
runner refuses `LOOPEX_PROVIDER_API_KEY` when it is present in the initial
environment, disables automatic export, resolves the repository root through
Git, and accepts only the bounded role grammar
`[--preflight | --capture <lane>]`. It then runs the opening condition, which
has a primary part and an additional part, in that order.

### The behavioural probe is primary

The declared red below names a missing operator capability. A check that a file
exists cannot honestly emit it, because writing a file would satisfy the check
without changing what the product does. The runner therefore observes the loop
before it looks at any selector.

The probe is one Elixir program the runner writes into an isolated evidence root
outside the checkout; a root that resolves inside the checkout is refused rather
than used. Compilation goes to a build root inside that evidence root rather than
the checkout's, so neither a stale nor an absent `_build` can change what the
probe sees, and the checkout is never written to. `MIX_BUILD_PATH` takes
precedence over `MIX_BUILD_ROOT` in Mix, so the runner clears it for every
compilation it owns; leaving an ambient value in place would let one inherited
environment variable send the probe back to the checkout's build tree, and an
inherited value has been observed to leave the probe unable to observe the loop
at all, turning a truthful red into an unavailable one. The program composes a
runtime from shipped modules only — the durable local store, the trusted-local
executor, and its own observing model adapter — starts it through
`Loopex.start_link/1`, creates a session, submits one prompt through the public
facade, waits for the session to settle, and emits one observation line carrying
six fields: five behavioural observations and one disclosed shape check.

The five observations are `turns`, how many model requests the loop staged;
`history`, whether the last staged request carried the committed conversation or
one synthesized user message; `progress_messages`, how many items reached the
probe process during the run, which is a mailbox count rather than a filtered
progress-plane count and is therefore only a floor; `tool_set`, whether the
runtime accepted a named active tool set or only one hand-written definition;
and `staged`, the sorted tool identities the first staged request actually
carried. The sixth field, `ports`, is the disclosed shape check that accompanies
those observations rather than being one of them: whether the model and executor
ports declare the arity that carries a progress function. The probe asks for the
`M2` shape first and falls back to the `M1` shape, so one program observes
either tree and a refusal is itself one of the observations. That fallback covers
authority as well as the tool set. Outcome 6 makes an `M2` runtime refuse to
start when no policy is named, so a probe carrying only `M1`'s literal allow term
would be refused by the very tree it exists to observe, and because the probe
gates green in every role, the gate could never pass.

`M2` is present only when all seven conjuncts hold at once: `turns` is at least
three, so the loop ran past turn two while the model kept asking for tools;
`history` is `committed_conversation`, so the last staged request carried an
assistant message and a real tool result; `progress_messages` is greater than
zero, so at least one item reached the probe process during the run — a coarse
mailbox floor, not proof a delta reached the progress plane, which the locked
streaming selector owns; `ports` is `progress_capable`, so both the model and
the executor port can carry progress; `tool_set` is `named_set`; `staged` is
non-empty, so the accepted set actually reached a staged request; and no element
of `staged` names a demonstration tool under either its dot-segmented identity
or its model-visible name, which refuses any staged demonstration tool rather
than only a set composed wholly of them. Both forms are matched because a staged
entry reports its `tool_id` where one is present and its `name` otherwise, and a
refusal that saw only one form would pass the other. Anything else is the
declared red, emitted with the observation line that produced it appended to it
parenthetically on the same line.

The probe's model adapter is a harness. Nothing it observes is a real-path claim,
and it satisfies no outcome and no closure obligation.

### The locked definitions are the additional condition

After the probe, and never in place of it, the runner:

1. checks the eleven `M2` operator features, the supporting tool-registry,
   tool-schema, and stream-owner mechanisms, and the attended demonstration, the supporting checks sitting
   beside the feature they protect rather than after the eleventh. Each check names what an
   operator or the closure evidence would be missing and requires that
   definition to exist as a readable file containing every locked case identity;
2. checks the nine inherited `M1` outcome selector files, the reused
   selector-runner mechanics corpus, the runner-isolation corpus, and the
   dependency corpus at their exact locked case identities;
3. verifies every bound artifact below except its own bytes against the files
   they name, selecting a validated `shasum` or `sha256sum` dialect; its own
   digest is verified by `mix loopex.status`, as Bound Artifacts records;
4. requires every closure document to exist as a tracked ordinary file;
5. requires Darwin or Linux and a wholly clean source tree.

### When the probe cannot run

The probe produces artifacts, so it owns an explicit isolated evidence root and
belongs to the writable evidence lane; the development contract keeps that lane
separate from the inspection-only checks a read-only reviewer must be able to
run. It is hoisted to the front because the declared red must be an observation,
not because the read-only lane depends on it.

A reviewer under a no-file-writes profile, or with no usable temporary
directory, therefore cannot allocate the evidence root, and nothing in the
inspection lane requires one. The probe reports itself unavailable with its
reason, the additional condition reaches the same declared red from the locked
definitions, and the run is refused before the task root is allocated: an
opening condition that could not observe the loop is evidence unavailable, which
is never a pass. Green is therefore impossible without a probe observation, in
every role including `--preflight`.

The `--preflight` role stops exactly here and prints `M2 preflight OK`; beyond
its own evidence root it allocates nothing, runs no product selector, and can
print neither `capture` nor `M2 gate GREEN`.

## Bound Artifacts

| SHA-256 | Path |
| --- | --- |
| `e1fc35c407c17b011059e226e83997606cb20ab6ba9d8ffb171b0a4ba5014b95` | `scripts/check-m2-gate.sh` |
| `cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0` | `scripts/m1-exunit-runner.exs` |
| `0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d` | `apps/loopex/test/m1_exunit_runner_test.exs` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

`scripts/m1-exunit-runner.exs` is bound at exactly the bytes `M1` closed with.
`M2` reuses that authoritative channel unchanged; changing it would change what
every `M1` and `M2` protected result means. Its adversarial corpus,
`apps/loopex/test/m1_exunit_runner_test.exs`, is bound with it: `M2` re-runs that
corpus, `M2` does not change it, and one of its cases — `fake stdout at_exit and
early halt cannot manufacture one authoritative result` — is the proof that the
result channel every outcome below reports through cannot be spoofed. A channel
bound without its corpus would be a digest without a meaning. The gate document
externally binds `scripts/check-m2-gate.sh`, which `mix loopex.status` verifies,
without pretending a runner can verify its own bytes before executing them.

`apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` and
`apps/loopex/test/deps_budget_test.exs` are deliberately **not** bound here.
`M2` changes both: the planned inventory grows from six applications to eight,
the role set gains `:composition` for the wiring-only application the command
depends on and an independent embedder fixture composes through, the `:client`
rule gains a production dependency on at most one `:composition` while still
admitting no other `:client`, and the corpus gains the three adversarial cases
that prove the
inventory, the new role's own permitted and forbidden directions, and the client
rule that consumes it. Those two artifacts carry the whole inventory and role
change; `M2` binds no third artifact for it. Binding bytes the milestone must change would lock a digest
acceptance already knows is wrong. The command stays locked below, and both
corpus identities stay locked in Locked Mechanics Selectors. `M2` therefore does
change a repository check, and says so here rather than claiming otherwise.

That source file is not inert bookkeeping. It is a live oracle inside the
authoritative result channel: before every protected and inherited role, the
runner invokes `Loopex.Checks.DepsBudget.main(["--context", <selector>, ...])`
to derive that selector's owner and its internal and allowed application
closures, so a selector cannot claim a closure its project declaration does not
support. Leaving it unbound is a real reduction in what a digest protects, and
the corpus identities and the `mix loopex.deps_budget` command are what stand in
its place.

The closed `M1` gate binds those same two paths and freezes the
six-application inventory, so no milestone that ships an operator command can
inherit it unchanged. Changing either file makes `mix loopex.status` fail, which
makes `bash scripts/check-bootstrap.sh` fail, which makes the closed `M0` gate
fail. `M1` is `Closed`, so its Acceptance and Closure rows bind the same gate
digest and the ordinary amendment cannot reach it; the rebinding is an
`amendment-transaction-v2` gate generation appended to the closed plan, with both
authority rows left byte-immutable. The accepted plan pair names that generation,
its non-delegable decision owner, and its exact rejoin position; until its rebind
revision lands, `M0`, bootstrap, and the status check are
red. `M2` carries `M1`'s protection forward behaviourally in the meantime: all
eleven of its protected outcome roles are re-run here at their exact locked
identities. The closed `M0` gate binds neither path — it locks the command
without binding its bytes — and remains an inherited required gate re-proved on
both locked pairs at every `M2` source candidate.

## Repository Commands and Owned State

After the opening condition passes, the runner reads the optional provider
frame, then allocates one physically resolved task root under a resolved
temporary directory and owns `LOOPEX_HOME`, `TMPDIR`, the Mix build root, and a
workspace beneath it. It refuses a task root that resolves inside the operator's
real product state or inside the checkout, clears `MIX_BUILD_PATH` where it
exports `MIX_BUILD_ROOT` because the former takes precedence over the latter,
fingerprints the operator's product state before and after the run, and requires
that fingerprint unchanged. It fingerprints the checkout's own `_build` across
the same window and requires it unchanged too, which is what makes the isolation
above a proved claim rather than a declared intent: clearing the variable states
the aim, and the fingerprint pair proves no locked command wrote into the
checkout's build tree. The task root is removed on exit.

`M2` does not rebuild `M1`'s owned candidate checkout or offline package
materializer. It runs the committed tree in place with an owned product state
root and temporary directory, and the clean-tree requirement above is what makes
a result describe committed bytes. That is a smaller containment claim than
`M1`'s, and it is stated rather than implied.

The runner derives the exact running Elixir and OTP versions from the VM rather
than from a declaration. A `--capture` role refuses to run when the running pair
or operating system is not the one its lane declares.

Every command below must exit zero.

| # | Command | Locked obligation |
| --- | --- | --- |
| 1 | `mix loopex.deps_budget` | Application identity, the `M2` eight-application inventory, role rules including `:composition`, and dependency direction |
| 2 | `mix loopex.format_scope` | Effective formatting includes every application source |
| 3 | `mix format --check-formatted` | Formatting is clean |
| 4 | `mix compile --warnings-as-errors` | The default build is warning-free |
| 5 | `MIX_ENV=test mix compile --warnings-as-errors` | A clean isolated test build exists before standalone selectors |
| 6 | `mix loopex.version_train` | Every application carries one version |
| 7 | `MIX_ENV=prod mix cmd --app loopex_cli mix escript.build` | The operator entrypoint builds on this lane |
| 8 | `mix loopex.core_only` | Core remains stdlib/OTP-only and adapter-free |
| 9 | `mix loopex.docs_check` | Covered public code orders Concept before Technical depth |
| 10 | `mix loopex.hook_registration` | Retained hooks keep required event and matcher registration |
| 11 | `mix loopex.matrix` | Closed `M0` matrix behaviour remains intact; it is not `M2` evidence |
| 12 | `mix loopex.status` | Live governance, indexes, links, lifecycle state, and every plan's bound artifacts validate |
| 13 | `bash scripts/check-bootstrap.sh` | The portable aggregate remains green |
| 14 | the root `VERSION` file | Reports exactly `0.0.0` |
| 15 | the eleven protected `M2` outcomes, the supporting registry, tool-schema, and stream-mechanics roles, and both demonstration roles through the standalone channel | Exact names, states, and minima below hold |
| 16 | the eleven inherited `M1` outcome roles and the five mechanics corpora through the standalone channel | `M1`'s proved behaviour still holds |
| 17 | `MIX_ENV=test mix test --exclude real_provider --seed <gate-seed>` | The complete credential-free suite passes at the same seed |
| 18 | retained evidence validation | Negative demonstrations and real-call attestations always; the toolchain matrix in ordinary mode only |

`M2` ships a runnable `loopex` command and no version. Command 7 proves the
operator entrypoint builds; command 14 proves the source tree still reports
`0.0.0`. No tag, package, archive, or release artifact is produced. Keeping
`0.0.0` is also mechanically load-bearing: the bound `M1` selector runner
refuses any sealed real-path report whose adapter build is not
`loopex_llm_reqllm@0.0.0` or whose executor build is not
`loopex_executor_local@0.0.0`.

One canonical decimal seed from `0` through `999999` covers every protected
role, every inherited role, and the final suite. The final ordinary line is
exactly:

```text
M2 gate GREEN seed=<N> protected_executed=<M>
```

`protected_executed` sums executed cases in `M2`'s own locked roles: Outcomes
1–11, the supporting registry, tool-schema, and stream-mechanics roles, and both demonstration roles. Excluded tests
never count, and inherited, mechanics, bootstrap, and full-suite executions are
excluded from that sum.

## Authoritative ExUnit Channel

Every protected and inherited selector runs by invoking the bound `M1` script
directly, never a Mix test task or alias:

```text
elixir scripts/m1-exunit-runner.exs --loopex-m1-selector [--only-real-provider --real-path <model|combined>] <root> <test-build> <selector> <owner> <internal-csv> <allowed-csv> <seed> <minimum> <zero|positive> <state=name>...
```

The owner and its internal and allowed application closures come from the
repository's own dependency authority, invoked directly as
`Loopex.Checks.DepsBudget.main(["--context", <selector>, <project configs>...])`
before each role, so a selector cannot claim a closure its project declaration
does not support.

Every role receives exactly
`LOOPEX_M1_SELECTOR_V1\0<32-lowercase-hex-nonce>\0<key>\0` on stdin. A default
role's key field is empty; a real role's is non-empty. The script consumes stdin
before candidate startup, requires the selector to be a tracked ordinary file
under `apps/<owner>/test/`, verifies the compiled owner and closure, and starts
that application without compilation or `test_helper.exs`. Startup is
credential-free. Official `ExUnit.RunnerStats` supplies totals, failures, skips,
and exclusions; formatter events bind each test to its exact selector, name, and
state. Missing or duplicate names, wrong states, foreign files, unaccounted
exclusions, skips, failures, or a count below the role minimum fail. The runner
prints one nonce-bound authoritative marker and hard-halts; arbitrary stdout is
diagnostic, not authority. A real role additionally seals a fixed identity field
set into that marker: `model` seals provider, model, endpoint, and adapter
build; `combined` seals those plus executor build, executor identity, and tool
identity. That field set is fixed by the bound script and cannot be extended.

Candidate code is trusted and independently reviewed. This channel prevents
accidental or interposed reporting; it does not claim to sandbox hostile
same-VM test code.

## Protected Outcome Selectors

All unqualified roles require zero failures, skips, and exclusions. A split
default role records the exact real case excluded; the real-only role records
the exact deterministic cases excluded. The authoritative exclusion total must
equal the named excluded identities.

| Outcome | Selector / role | Minimum | Locked names and required states |
| --- | --- | --- | --- |
| 1 | `apps/loopex/test/agent_loop_test.exs` / default | 89 | passed: `a prompt runs until the model stops requesting tools rather than after a fixed number of turns`; passed: `every model request carries the committed conversation history including the original prompt`; passed: `an assistant tool call and its real tool result are committed and replayed to the model`; passed: `each turn dispatches exactly the canonical request bytes and digest committed before it`; passed: `a staged request carries complete tool definition bytes and its generation triple and is reconstructible from the journal alone`; passed: `every turn after the first is canonical history replay and the reserved continuation field stays empty`; passed: `the maximum turn bound ends the run bound reached before another provider call`; passed: `the cumulative token budget ends the run bound reached before another provider call`; passed: `the wall clock deadline ends the run bound reached before another provider call`; passed: `the committed absolute deadline is propagated into the model call rather than an independent per call timeout`; passed: `a prompt fixes its deadline at first request staging and not at admission`; passed: `every sampling bound is a declared committed value with no implicit default`; passed: `a provider retry of a model call redispatches the same staged request bytes and reuses their staged request digest under a new recorded attempt`; passed: `the retry allowance a run has already spent is not handed back by a succession`; passed: `a tool call whose run deadline already passed is not dispatched and still commits a terminal fact`; passed: `a committed request that expired while its owner was down is not redispatched to the provider`; passed: `a cancelled turn is charged its request bytes and its committed max tokens in full and marked estimated`; passed: `a reached deadline whose cleanup cannot be confirmed ends outcome unknown rather than bound reached`; passed: `an unproven effect ends the run rather than letting the model be asked again`; passed: `an unproven effect outranks the model stopping on its own and the run never finishes completed`; passed: `an unproven effect stops the tool calls still queued behind it in the same batch`; passed: `an unproven effect outranks the maximum turn bound`; passed: `an unproven effect outranks the cumulative token budget`; passed: `a retried tool operation keeps its operation identity and reconciles against its own attempt bound request digest`; passed: `a reply committed before an admitted abort completes the turn and an abort admitted first keeps the late reply as attempt evidence only`; passed: `a receipt lost after the effect ran ends the run outcome unknown rather than failed`; passed: `a refusal that precedes the effect stays a terminal failed and the loop carries on`; passed: `an executor error the runtime cannot place before the effect is unproven`; passed: `an executor that declares nothing has every error read as unproven`; passed: `an answer that reaches for the pre-start tag and misses its shape declares nothing`; passed: `a pre-start refusal is read from the answer's shape and not from the error's name`; passed: `a complete tool stream closes on its receipt's own progress count`; passed: `a receipt the Store refuses cannot complete its tool stream`; passed: `a reply the Store refuses cannot complete its model stream`; passed: `an abandoned model stream closes on the count this runtime published rather than zero`; passed: `a delta carrying a field its kind does not declare is refused rather than projected`; passed: `the run's terminal reports the cleanup period this session declared`; passed: `no item of a stream domain is emitted after that domain's closure`; passed: `a closed stream domain accepts nothing further and its relay is gone`; passed: `a succession never gives two owners one stream domain`; passed: `a prior ownership verdict cannot suppress notified model cleanup`; passed: `a superseded coordinator is not reaped while cleanup is still pending`; passed: `an abrupt model owner death never gives its successor the same stream domain`; passed: `a model error before its supersession notification cannot close the old domain`; passed: `runtime unavailability while closing a model error does not invent owner supersession`; passed: `handoff cannot move between progress admission and relay emission`; passed: `a stale Store refusal of a model result leaves closure and abandonment to the successor`; passed: `a retained model result closes complete after Control handoff`; passed: `a model result admitted before handoff still closes complete after ownership moves`; passed: `a live executor supersession ends its old stream without claiming the effect abandoned`; passed: `an executor progress ownership refusal ends the stale plane without terminating its worker`; passed: `runtime unavailability during executor progress does not invent owner loss`; passed: `runtime unavailability while closing a refused tool does not invent owner loss`; passed: `a durable owner handoff fences executor progress and closure before its notification arrives`; passed: `a malformed executor receipt cannot close the old domain across an owner handoff`; passed: `a stale non receipt executor answer leaves diagnosis and reconciliation to the successor`; passed: `an executor receipt admitted before handoff still closes complete after ownership moves`; passed: `a retained executor receipt closes complete after Control handoff`; passed: `a stream relay ends with the owner that opened it, ahead of its own backlog`; passed: `two attempts of one tool operation never share a stream domain`; passed: `an executor that declares no cancellation confirms nothing`; passed: `a stream statistic that is not a count is refused rather than published or committed`; passed: `a complete model stream closes on its reply's own delta count`; passed: `a run that no executor answered still reports the period it would have stopped under`; passed: `a model delta emitted after its stream is closed is neither projected nor counted`; passed: `an event emitted after its stream is closed is neither projected nor counted`; passed: `an abandoned tool stream closes on the count this runtime published rather than a claim`; passed: `executor progress proves its whole identity before anything is projected`; passed: `a refused executor event is counted privately and never journaled`; passed: `a refused current-attempt payload preserves its executor sequence gap`; passed: `a validated executor event carries only its bounded named payload across`; passed: `the first delta of a model attempt is sequence zero`; passed: `each executor stream anchors to the current public event at its own dispatch`; passed: `a Store refusal of late model attempt evidence makes clean cancellation unprovable`; passed: `a late model error is retained as bounded attempt evidence without becoming history`; passed: `an unreadable late model reply is retained as a bounded error instead of crashing cleanup`; passed: `a model reply queued behind its deadline is retained with the deadline termination`; passed: `cleanup waits for a model result sent after the supervisor answers`; passed: `late model evidence binds the provider retry attempt that produced it`; passed: `a model tool call preserves a JSON number argument through durable dispatch`; passed: `a schema-invalid tool call fails before policy or executor sees it`; passed: `an undeclared late provider field becomes bounded error and never reaches the journal`; passed: `an unreadable live model reply abandons and retries its attempt`; passed: `nested provider fields are projected out of valid late evidence`; passed: `a deeply nested late provider term becomes bounded error at the Store boundary`; passed: `a malformed streamed flag in a late reply becomes bounded error`; passed: `a late reply whose streamed flag contradicts its count becomes bounded error`; passed: `an oversized valid late reply is retained as bounded error`; passed: `a late model error retains only its generic bounded category` |
| 2 | `apps/loopex_llm_reqllm/test/streaming_conformance_test.exs` / default | 16 | passed: `every model adapter satisfies one streaming conformance suite`; `each canonical delta kind is bounded plain data carrying no provider or host term`; `a text delta is observable while its operation is still incomplete rather than after the reply returns`; `replaying an adapter's emitted deltas reproduces the reply it returned byte identically`; `the model and executor progress domains carry separate sequences each closed by its own content free item`; `a gapless sequence within one stream domain and its closing total make lost progress detectable`; `the canonical identity encoding is injective and sampled distinct encodings derive stable distinct labels`; `a provider retry opens a second stream domain under one turn and neither domain reports the other as loss`; `a retried executor operation attempt opens its own stream domain closed by its own closure item and count`; `the committed assistant message is built from the reply and never assembled from deltas`; `a cancelled stream commits no assistant message and a late reply never becomes canonical`; `an adapter that emits no deltas is conformant and declares that it does not stream`; `a delta missing a field its kind declares is refused rather than projected`; `a delta field whose size the ceiling cannot see is refused rather than projected`; `an abandoned domain is closed and stated rather than guessed from a stream that stopped`; `the model reply contract declares the optional provider response identifier` |
| 3 | `apps/loopex/test/input_algebra_test.exs` / default | 9 | passed: `a prompt starts a run only while the session is settled and is otherwise refused`; `the runtime never infers whether new input is steering or follow up and a steer must name its active run`; `a steer joins the active run after the current tool batch and before the next model request`; `a steer is recorded applied only when a committed request carried it`; `a follow up starts a new run only after the active run and its steering settle`; `a promoted follow up fixes its deadline when its first request stages`; `a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted`; `at most one unapplied steer and one queued follow up exist and both survive owner succession`; `an abort resolves any unapplied steer and queued follow up as cancelled` |
| 4 | `apps/loopex_executor_local/test/coding_tools_test.exs` / default | 39 | passed: `read returns bounded chunked content and reports truncation`; passed: `write creates or replaces a file beneath the workspace root and refuses static escapes`; passed: `edit applies an exact match change and names what differed on a mismatch`; passed: `bash runs an argv command and an explicit raw shell command with distinct semantics`; passed: `bash reports a nonzero exit as failed and names the status the command exited with`; passed: `every filesystem tool refuses a path that escapes the workspace root through traversal or a symlink`; passed: `bash emits real progress before completion with exact identity sequence offsets and receipt count`; passed: `a coding tool command receives a constructed provider credential free environment and its receipt records that declared environment`; passed: `a tool child process group is owned and terminated with its job and no group member survives`; passed: `a long running job carries the run deadline is terminated at expiry and its cleanup is confirmed before the run commits its bound`; passed: `an already expired job is refused before the local executor opens a port`; passed: `the wall time budget the session declared bounds the job and not merely the run`; passed: `a job whose workspace lease is lost mid flight is ended and reported unproven`; passed: `a filesystem tool is bounded while it runs rather than only before it starts`; passed: `write refuses a name that is not an ordinary file and replaces the one it names atomically`; passed: `edit refuses a name that is not an ordinary file before it opens anything`; passed: `a lease lost while a job's output is being retained abandons the retention and reports it unproven`; passed: `a command that backgrounds work and exits is not completed until its group is quiescent`; passed: `a lease lost while a job's group is brought to quiescence is reported unproven`; passed: `a lease lost while a job's receipt is being retained is reported unproven`; passed: `a process group is confirmed clean only by a ps that answered`; passed: `the first process the launcher starts explicitly excludes the provider credential`; passed: `every executor spawn supplies an environment override that excludes the provider credential`; passed: `the run deadline bounds retaining a spilled artifact and the abandonment is reported`; passed: `a receipt that could not be retained is reported rather than answered as a result`; passed: `work this executor cannot bound is abandoned at its bound and a program that never answers confirms nothing`; passed: `the run deadline bounds the demonstration launcher as well as the coding tools`; passed: `the cleanup budget is one configured period with a declared default and every receipt records it`; passed: `a job requiring process cleanup retains its receipt under a separate quarter period bound`; passed: `the configured cleanup budget bounds the whole termination sequence rather than each step of it`; passed: `cancelling a running job answers only for the cleanup it could confirm`; passed: `cancelling an unknown job id leaves another running job untouched`; passed: `each of the three quiescence answers reaches a distinct outcome and only one is proved`; passed: `an answer this executor gives after an effect ran never wears the pre-start tag`; passed: `a job is bounded by the tool's declared budget when that is sooner than the run's`; passed: `a deadline stop whose cleanup could not be confirmed is unproven rather than cancelled`; passed: `a job is refused when the lease it names is held at another fencing token`; passed: `the two containment mechanisms obligation four names by name are the ones the code uses`; passed: `a cleanup helper that outlives its bound is terminated rather than left running` |
| 5 | `apps/loopex_store_local/test/artifact_store_conformance_test.exs` / default | 6 | passed: `every artifact store implementation satisfies one conformance suite`; `tool output beyond its declared bound spills to an artifact instead of truncating silently`; `the durable artifact event carries digest media type size role and an opaque reference`; `the model facing result stays under its bound and names what was truncated`; `the operator retrieves a spilled artifact by its opaque reference through the public facade`; `an artifact round trips byte exactly and a missing artifact reports unavailable` |
| 6a | `apps/loopex_executor_local/test/host_policy_test.exs` / default | 8 | passed: `every host policy implementation satisfies one policy port conformance suite`; `a host policy deny decision issues no grant and starts no operating system process`; `a denied tool call commits a truthful denied outcome the operator can read`; `the run continues or terminates truthfully after a denial and never retries the refused call`; `a policy that raises times out or returns a malformed value fails closed into denial`; `defer is declared and refused in this milestone rather than treated as allow or deny`; `every executor backed tool requires a policy decision including a read only tool`; `a permissive policy applies only when it is named and omitting the policy option refuses runtime start` |
| 6b | `apps/loopex_reference_client/test/allow_all_policy_test.exs` / default | 2 | passed: `the shipped allow all policy allows every decision it is asked`; `the shipped allow all policy emits exactly one permissive authority notice` |
| 7 | `apps/loopex/test/project_resource_trust_test.exs` / default | 7 | passed: `discovery resolves a canonical ordered resource set under declared path size and total limits`; `the operator is shown every resolved path its provenance and the manifest digest`; `an explicit trust decision binds workspace revision manifest and digests`; `a changed workspace revision manifest or content invalidates the decision`; `a headless run without a matching positive decision stages no project block journals a declined receipt and still runs`; `an ordinary workspace read stays a policy governed tool effect and is never context staging`; `an admitted project block changes no tool set policy decision bound or grant` |
| 8 | `apps/loopex/test/cancellation_test.exs` / default | 24 | passed: `an interrupt reaches the run through the public facade and through no private path`; passed: `an abort admitted during a model call cancels the run and schedules no new work`; passed: `an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled`; passed: `cleanup commits a valid executor receipt queued behind its own settlement`; passed: `a run finishes cancelled only when every owned operation is validated terminal and every owned process tree is confirmed cleaned`; passed: `a validated terminal tool fact committed before the abort is preserved and not overwritten`; passed: `an effect without sufficient evidence ends outcome unknown and is never blindly retried`; passed: `a second interrupt reports what is still being cleaned up rather than abandoning the session`; passed: `a second interrupt during cleanup starts no second executor cancellation`; passed: `the operator observes what was cancelled and what actually happened`; passed: `an abort reduced while an unprovable receipt settles finishes the run outcome unknown`; passed: `the abort is durable before its cleanup runs and its ending is a second commit`; passed: `the coordinator answers while a host cancellation is still running`; passed: `a host cancellation that never answers is bounded and settles unconfirmed`; passed: `a run being cleaned up is still active and admits nothing new until its ending commits`; passed: `an executor that never answered leaves its call a terminal fact of its own`; passed: `a recovering owner ends the abandoned call before it ends the run`; passed: `an abort after succession cannot report a clean stop for the predecessor's unproved effect`; passed: `a run does not end while the operation it owns has no committed ending`; passed: `a recovering owner does not end a run whose operation it could not settle`; passed: `a recovering owner ends a run with no dispatched effect outcome unknown`; passed: `a cancellation this runtime cannot read is unproven rather than a confirmed clean stop`; passed: `an abort during an in flight tool call treats an executor cancellation error as outcome unknown with a reconciliation reference`; passed: `an abort admitted after an unprovable effect committed never rewrites the run to cancelled` |
| 9 | `apps/loopex/test/session_directory_test.exs` / default | 5 | passed: `a fresh operating system process lists the sessions in a resolved state root`; `the state root resolves from LOOPEX_HOME and never from application environment`; `a session resumes under the durable runtime placement identity that created it`; `resuming a session through a different runtime identity is refused with an explicit reason`; `a repeated resume command identity returns its historical result while a fresh identity acquires ownership` |
| 10 | `apps/loopex_cli/test/cli_test.exs` / default | 17 | passed: `loopex run submits a prompt and streams the answer with its tool calls and results`; `the operator steers a running task and queues a follow-up from the same terminal`; `prompt steer follow up and abort have distinct explicit affordances and input naming neither is refused`; `tool progress from a running executor job reaches the operator's terminal before the tool finishes`; `loopex sessions lists the operator's sessions and loopex resume continues one`; `an interrupt signal delivered to a running loopex process cancels the task through the public facade`; `an interrupt whose cleanup cannot be confirmed reports outcome unknown with its reconciliation reference`; `loopex cancel reconciles a session left behind by a dead process and is refused against a live owner`; `the policy option selects the governing host policy and a refusal is reported in the transcript`; `the command ships its own permissive policy that is named explicitly, prints one notice, and is never an implicit fallback`; `loopex artifact retrieves a spilled artifact by its opaque reference`; `project resource trust is decided at the terminal and a non interactive run without a decision proceeds with the block withheld`; `the command surface drives only the public facade and owns no loop store cursor or authority`; `a dropped stream closure leaves the terminal falling back to the durable record without inferring abandonment or starting a timer`; `the base system prompt and active tool definitions measure under one thousand tokens`; `argument parsing and terminal output use only the standard library`; `the operator declares how long a stopped run may spend stopping and a bad value is refused` |
| 11 | `apps/loopex_composition/test/kernel_composition_test.exs` / default | 5 | passed: `one page of shipped code starts the application tree a runtime a session a prompt and its events`; `an independent embedder fixture composes the kernel without depending on the command application`; `the shipped composition requires a host supplied policy and ships no permissive default`; `the composition resolves its state root explicitly and never through application environment`; `the composition forwards the executor's declared cleanup period and probe` |

Outcome 10's facade-only case must fail if any module of the command
application reaches a coordinator, store, model, executor, artifact store,
journal, outbox, or cursor internal, or names a concrete Store, Model, Executor,
or ArtifactStore implementation. The host policy modules the command ships for
`--policy` are its single named exception, because policy is the host's own
decision and the one decision the shipped composition refuses to make for it.
Outcome 11 is where the composition itself is locked: it lives in
`apps/loopex_composition`, a `:composition` application the command depends on
and an independent embedder fixture composes through, and its locked case that
the composition requires a
host-supplied policy is what stops shared wiring answering the host's question
for every embedder at once. Outcome 6 is split across two roles
because the two halves prove different things: the executor edge proves the
runtime property that a permissive policy applies only when a host names it,
using the selector's own in-file fixtures and importing nothing from a client,
while the reference client's lane proves what its own shipped `AllowAll` module
does. Neither role may be satisfied by the other.

## Locked Supporting Mechanism Selectors

The tool registry is the internal mechanism Outcomes 1 and 4 both resolve
through. It is not an operator capability and is not an outcome, so it is locked
here rather than in the table above; its executed cases still count toward
`protected_executed`, and its role is protected exactly as an outcome's is.

`apps/loopex/test/tool_registry_test.exs` / default, minimum 5, all passed:

- `a runtime-scoped registry resolves a tool id and version and refuses an unknown id`
- `two runtimes carry independent tool registries with no global registration`
- `a conflicting tool id and version registration is refused with an explicit reason`
- `a session binds one active model visible name to one generation and refuses a name conflict at start`
- `a model request records the exact tool definition generation it used`

The declared tool schema is the internal authority that Outcome 1 applies
before policy and dispatch. Its protocol corpus is locked separately so a
full-runtime refusal cannot stay green while one schema constraint silently
stops being evaluated.

`apps/loopex_protocol/test/tool_definition_test.exs` / default, minimum 10, all
passed:

- `arguments are checked against every declared schema constraint`

Owner-loss admission is cross-cutting stream machinery rather than an operator
outcome. The following supporting role protects the distinction between an
unavailable Control process and an actual owner-loss verdict across progress,
closure, and post-commit publication; its executed cases count toward
`protected_executed` exactly as the registry role does.

`apps/loopex/test/session_lifecycle_test.exs` / default, minimum 3, all passed:

- `progress reports runtime unavailability without inventing owner supersession`
- `progress closure reports runtime unavailability without inventing owner supersession`
- `post commit reports runtime unavailability without inventing owner supersession`

## Mandatory Closure Evidence

One attended real-provider demonstration is required for closure. It is not an
outcome, because completing one demonstration is not a capability an operator
asks for; it is the evidence that the eleven outcomes add up to a coding agent
rather than to eleven passing selectors. That makes it more binding, not less: a
closure candidate without it is refused, and its real-provider role is locked
here exactly as an outcome's role is.

| Role | Selector / role | Minimum | Locked names and required states |
| --- | --- | --- | --- |
| Da | `apps/loopex_cli/test/coding_task_test.exs` / default | 5 | passed: `a multi tool task reads edits and verifies a file in a disposable repository`; `the task transcript shows every tool call decision and result`; `a denied tool call inside a multi tool task is reported and the task continues truthfully`; `the demonstration workspace is disposable and never the operator's own repository`; `a real provider evidence claim fails when the reply carries no provider supplied response identifier`; excluded: the two real cases below |
| Db | same file / real-only, `combined` profile | 2 | passed: `one real provider task streams edits a real repository across several turns and the operator sees the committed result`; `one real provider call surfaces the provider's own response identifier and reported usage that the deterministic adapter cannot produce`; excluded: the five deterministic names above |

Role `Db` carries the attended claim: a real provider drove the shipped command
through several turns and several distinct tools including one `edit` and one
`bash`, the answer streamed and reconstructed once per turn, one host-policy
refusal was reported and the task continued truthfully, and the resulting bytes
exist on disk in a disposable repository created inside the gate's own task root.
The deterministic cases in `Da` support that claim and never substitute for it.

What the runner mechanically proves is narrower than that paragraph, and the
narrower statement is the one that governs. It proves the locked case names ran
and passed with a credential present, that the retained identity is well formed
and agrees across roles, and — through the Real-Call Attestations section below —
that each real-provider role retained provider-supplied response identifiers
matching the identifier form its own record declares for that provider,
unreused, internally consistent with the call count and usage totals they claim,
and byte-identical in identity to what the bound runner sealed in the same run. It does not prove a network call happened. No
offline check can: everything the runner reads is produced inside the same test
process, so a case that fabricated all of it and opened no socket would still
satisfy the runner. The attestation does not close that hole; it makes the hole
externally visible, because the retained identifiers either exist in the
provider's account for the recorded window or they do not, and only a person
looking there can tell. That look is a closure-review step, and it is the single
step in this gate that reaches the provider. The limit applies to every
real-provider role here, inherited or `M2`'s own.
Its retained records are `docs/evidence/M2-coding-demonstration.md` and
`docs/evidence/M2-real-call-attestations.md`, and the identity fields the first
seals are the ones the capture record carries.

## Inherited M1 Protection

`M1` is closed, and the behaviour it proved is the floor this milestone stands
on. Each role below runs through the same authoritative channel at `M1`'s exact
locked identities, states, and minima, including both real-provider roles.
`M2` rewrites the coordinator turn machine, session state, and executor accept
path, so the untrappable-kill reconciliation trace is exactly what must be
re-proved rather than assumed. Their executed counts do not enter
`protected_executed`. A real-provider credential is required for roles 5c and
8b: absence is evidence unavailable, never a skip.

| Role | Selector / role | Minimum | Locked obligation |
| --- | --- | --- | --- |
| 1 | `apps/loopex/test/runtime_test.exs` / default | 3 | Explicit runtime references and two-runtime isolation |
| 2 | `apps/loopex/test/session_lifecycle_test.exs` / default | 6 | Runtime-control creation, owner succession, and derived fault coverage |
| 3 | `apps/loopex_store_local/test/store_conformance_test.exs` / default | 5 | ADR 0006 transaction, fencing, resolution, and durability semantics |
| 4 | `apps/loopex/test/embedded_api_test.exs` / default | 4 | Attachment barriers, bounded queues, restart, and gap-free resume |
| 5a | `apps/loopex_llm_reqllm/test/real_model_lane_test.exs` / default | 1 | One model conformance suite across both adapters |
| 5b | `apps/loopex_reference_client/test/real_model_session_test.exs` / default | 1 | Committed canonical request bytes reach dispatch; the real case is excluded |
| 5c | same file / real-only, `model` profile | 1 | One real non-streaming model call receives the committed canonical bytes and digest and completes inside a session; the deterministic case is excluded |
| 6 | `apps/loopex_executor_local/test/executor_test.exs` / default | 6 | ADR 0007 grant oracle, final pre-start validation, lease, and receipt |
| 7 | `apps/loopex_reference_client/test/reference_client_test.exs` / default | 2 | Facade-only client with no alternate loop |
| 8a | `apps/loopex_reference_client/test/end_to_end_recovery_test.exs` / default | 5 | Reconciliation oracle, one dispatch per effect, `outcome_unknown`; the real trace is excluded |
| 8b | same file / real-only, `combined` profile | 1 | One real-provider trace forces a credential-free tool, survives an untrappable runtime-tree kill after receipt before fact, reconciles one effect without redispatch, preserves its fact, and completes a second real call; the five deterministic cases are excluded |

The exact locked case identities are `M1`'s and are reproduced verbatim in the
runner. If implementation shows that one of them cannot survive an accepted `M2`
outcome, that is a blocking finding requiring an explicit maintainer
disposition, never a silent rename or a quietly dropped row.

## Locked Mechanics Selectors

`apps/loopex/test/m1_exunit_runner_test.exs`, minimum 5, all passed:

- `the standalone selector grammar admits every planned owner and rejects foreign paths`
- `the standalone runner requires one tracked ordinary selector owned by its compiled app`
- `official counts and exact events refuse failures skips exclusions and missing names`
- `fake stdout at_exit and early halt cannot manufacture one authoritative result`
- `only the declared internal dependency closure is reachable and startup never receives the provider key`

`apps/loopex/test/status_check_test.exs`, minimum 43, including these passed
names:

- `a milestone cannot outrun the ADR dispositions its plan pair declares`
- `a Closed milestone's gate is amended by an accepted generation, not a rebind`
- `a gate generation table fails closed on every malformed shape`
- `a gate generations table is append-only in both admitted directions`
- `the integrated phase is derived from the register's closed rows`

`apps/loopex/test/history_anchoring_test.exs`, minimum 25, including these
passed names:

- `an unavailable walk is unavailable evidence in both history checks`
- `a declared Bound Artifacts table that binds nothing is refused`
- `the real history reader carries the register and refuses a laundered prerequisite`
- `a completed Acceptance row is judged even while the register still says Open`
- `a Closed milestone cannot conceal an outstanding prerequisite behind an Open successor`
- `accepting a prerequisite later cannot legalise an earlier acceptance`
- `a Closed milestone's gate generation is one atomic proposal and one rebind`
- `recorded gate generations are append-only across reachable history`
- `a gate generation rebind cannot bind an interposed revision that changes nothing`
- `a gate generation rebind cannot bind an interposed revision carrying unrelated bytes`
- `a gate generation rebind cannot bind a merge or a revision behind one`

Both files are locked here because `M2`'s own prerequisite is the transaction
they enforce. `M0` locks the second at minimum 3 and cannot be reopened, so
without these rows the cases proving a Closed milestone's gate cannot be silently
rebound could be deleted without tripping any count. The machinery that enforces
immutable governance records was otherwise protected only by convention.

`apps/loopex/test/gate_isolation_test.exs`, minimum 2, all passed:

- `an ambient MIX_BUILD_PATH cannot redirect gate owned compilation out of the owned build root`
- `the gate refuses an owned root that resolves inside the checkout or the operator's product state`

This corpus exists because the runner makes a claim about itself. It says it
compiles and runs outside the checkout, and an ambient `MIX_BUILD_PATH` — which
Mix resolves ahead of `MIX_BUILD_ROOT` — silently made that claim false, to the
point where the opening probe reported itself unavailable instead of observing
the loop. A claim a runner makes about its own isolation needs a locked
definition for the same reason a product claim does; prose in the runner about
the runner is not evidence.

`apps/loopex/test/deps_budget_test.exs`, minimum 28, including these passed
names:

- `the repository satisfies the dependency budget and direction`
- `the M2 planned inventory admits exactly eight applications with their declared roles`
- `a composition depends on the edge applications it composes and on no client or external package`
- `a client depends on at most one composition and never on another client`

The minimum rises from `M1`'s 25 by three rather than two because the new
`:composition` role is a separate adversarial claim from the client rule that
consumes it: a corpus proving only the client side would leave a composition
free to declare an external dependency or to depend on a client. Removing a case
to reach the number is a gate weakening and requires the ordinary authority.
This file is one of the two `M1`-bound artifacts the accepted plan pair's
gate-generation prerequisite rebinds, and together with
`apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` it is the whole surface of the
inventory and role change.

## Toolchain Capture and Retained Matrix

The three bound non-gate commands are:

```text
# Darwin, exact floor pair
mise exec erlang@26.0 elixir@1.17.0-otp-26 -- bash scripts/check-m2-gate.sh --capture darwin-floor
# Darwin, exact current pair
bash scripts/check-m2-gate.sh --capture darwin-current
# Linux, exact current pair
bash scripts/check-m2-gate.sh --capture linux-current
```

All three run from the same clean committed source candidate `C`, each with a
fresh, disjoint owned task root. Each refuses to run unless the VM reports its
lane's exact Elixir and OTP versions and its lane's operating system. They run
the complete `M2` command set except matrix validation and emit one
`capture ... verdict=CAPTURE exit=0` record carrying the attended demonstration
role's sealed identity fields. They never invoke the gate recursively, never
print GREEN, and are not merge evidence. Pair order and adjacency are inert;
repeating a green execution proves nothing additional.

The operator separately runs `bash scripts/check-m0-gate.sh` once under the
floor pair and once under the current pair against the same `C`. Bootstrap does
not substitute for either run, and `M2` never nests `M0`.

`docs/evidence/M2-toolchain-matrix.md` carries the `loopex:m2-matrix` markers
around one `text` fence containing these six lines in order:

```text
matrix candidate=<C> gate_sha256=<digest> runner_sha256=<digest> exunit_runner_sha256=<digest> tool_versions_sha256=<digest> command=bash:scripts/check-m2-gate.sh
capture lane=darwin-floor candidate=<C> elixir=1.17.0 otp=26.0 seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 os=darwin arch=<ASCII-token> provider=<ASCII-token> model=<ASCII-token> endpoint=<ASCII-token> adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=<ASCII-token> tool_identity=<ASCII-token> recorded=<UTC-RFC3339-second>
capture lane=darwin-current candidate=<C> elixir=1.20.3 otp=29.0.5 seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 os=darwin arch=<ASCII-token> provider=<same> model=<same> endpoint=<same> adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=<same> tool_identity=<same> recorded=<UTC-RFC3339-second>
capture lane=linux-current candidate=<C> elixir=1.20.3 otp=29.0.5 seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 os=linux arch=<ASCII-token> provider=<same> model=<same> endpoint=<same> adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=<same> tool_identity=<same> recorded=<UTC-RFC3339-second>
m0 lane=floor candidate=<C> gate_sha256=<M0 gate document digest> command=bash:scripts/check-m0-gate.sh elixir=1.17.0 otp=26.0 verdict=GREEN exit=0
m0 lane=current candidate=<C> gate_sha256=<M0 gate document digest> command=bash:scripts/check-m0-gate.sh elixir=1.20.3 otp=29.0.5 verdict=GREEN exit=0
```

Retained tokens are printable ASCII, so Unicode lookalikes and direction
controls cannot change what a reviewer sees.

The runner checks exactly the following and nothing more. It requires both
matrix markers; exactly one `matrix` row; one exact 40-hex candidate on that row
that is reachable from the running revision; that the row's `command` is the
ordinary gate; and that its `gate_sha256`, `runner_sha256`,
`exunit_runner_sha256`, and `tool_versions_sha256` equal this revision's
`docs/plans/M2-gate.md`, `scripts/check-m2-gate.sh`,
`scripts/m1-exunit-runner.exs`, and `.tool-versions`. It requires exactly one
capture row per lane; that each names the same candidate, a `CAPTURE` verdict
and zero exit, its lane's exact `elixir`, `otp`, and `os`, a canonical seed, a
positive executed count, and the two build identities the bound selector runner
can have sealed; that no sealed identity field is empty; and that all three
lanes agree on `provider`, `model`, `endpoint`, `adapter_build`,
`executor_build`, `executor_identity`, and `tool_identity`. It requires exactly
one `m0` row per pair, each naming the same candidate, this revision's `M0` gate
document digest, the `M0` gate command, a `GREEN` verdict, zero exit, and its
pair's Elixir version. It requires the tree difference between the candidate and
the running revision to be empty or exactly the four evidence documents.

Observation times and architectures are independent recorded facts and are not
compared. Review, not the runner, cross-checks every retained field against the
actual captured process output.

## Negative Demonstrations

`docs/evidence/M2-negative-demonstrations.md` contains exactly eight records, in
this order, each one one-line JSON object in its own `json` fence:

1. Outcome 1 / `committed_history_projection` /
   `apps/loopex/test/agent_loop_test.exs`
2. Outcome 2 / `stream_delta_reconstruction` /
   `apps/loopex_llm_reqllm/test/streaming_conformance_test.exs`
3. Tool registry / `tool_definition_generation_binding` /
   `apps/loopex/test/tool_registry_test.exs`
4. Outcome 4 / `workspace_path_scope_containment` /
   `apps/loopex_executor_local/test/coding_tools_test.exs`
5. Outcome 6 / `host_policy_deny_prestart_refusal` /
   `apps/loopex_executor_local/test/host_policy_test.exs`
6. Outcome 7 / `project_resource_trust_admission` /
   `apps/loopex/test/project_resource_trust_test.exs`
7. Outcome 8 / `cancellation_cleanup_confirmation` /
   `apps/loopex/test/cancellation_test.exs`
8. Outcome 10 / `command_surface_facade_only` /
   `apps/loopex_cli/test/cli_test.exs`

The eighth record covers the milestone's headline structural claim. Introducing
a client application is exactly when "session before surface" is most at risk,
so the mechanism that fails a build where a second module reaches past the
facade carries its own mutation record rather than resting on source inspection.

The exact key order is:

```json
{"mechanism_disabled":"<exact ID>","selector":"<exact selector>","observed_failure":"<nonempty printable ASCII>","candidate":"<40 lowercase hex>","artifact":"<safe tracked path>","restored_sha256":"sha256:<64 lowercase hex>"}
```

Each record starts from its own named clean candidate, disables only that
mechanism, runs the named selector which must fail for the named reason,
restores the artifact from `git show <candidate>:<path>`, and verifies whole-tree
cleanliness before the next record. No record stands in for two mechanisms, and
a failure observed from a dirty or previously mutated baseline is no evidence.

The runner checks exactly the following and nothing more. It requires exactly
eight records; that each parses as one line in the canonical key order with the
declared value shapes; that each record's `mechanism_disabled` and `selector`
equal the locked pair for its position; that `selector` and `artifact` are safe
relative paths tracked at this revision; that `candidate` is reachable from the
running revision; and that `restored_sha256` equals this revision's SHA-256 of
`artifact`, which is what makes "restored" a claim about bytes rather than
prose. Whether one clean-baseline mechanism was disabled, whether it caused the
named failure, and whether the whole tree was clean between records remain
review obligations.

## Real-Call Attestations

`M1`'s selector runner is a bound artifact at the bytes `M1` closed with. It
seals a fixed real-path field set and refuses any report whose key set differs,
so no attestation field can be added to that channel without reopening an
immutable artifact. The attestation therefore lives beside that sealed report,
in `docs/evidence/M2-real-call-attestations.md`, which `M2` owns and this runner
validates.

The record carries exactly three one-line JSON objects, each in its own `json`
fence, in this role order:

1. `demonstration_db` / `apps/loopex_cli/test/coding_task_test.exs`, at least
   four real calls
2. `inherited_5c` / `apps/loopex_reference_client/test/real_model_session_test.exs`,
   at least one real call
3. `inherited_8b` / `apps/loopex_reference_client/test/end_to_end_recovery_test.exs`,
   at least two real calls

The floors are the ones each role's own locked cases already claim: the attended
demonstration must complete at least three turns and then make its attestation
call, and the inherited recovery trace explicitly completes a second real call.

The exact key order is:

```json
{"role":"<demonstration_db|inherited_5c|inherited_8b>","selector":"<safe tracked path>","provider":"<lowercase provider>","model":"<printable>","endpoint":"<printable>","adapter_build":"<printable>","calls":<positive integer>,"response_id_form":"<prefix>:<min>-<max>","provider_response_ids":"<id>+<id>...","input_tokens":<positive integer>,"output_tokens":<positive integer>,"candidate":"<40 lowercase hex>","recorded":"<RFC3339 UTC>"}
```

`provider_response_ids` names, in order, every provider response the role
observed; `calls` is their count; and the two token fields are the provider's own
reported totals across exactly those responses.

**The gate holds no opinion about which providers exist.** The record names the
provider and declares the identifier form that provider documents, and the
runner validates the recorded identifiers against that declared form. It carries
no provider allowlist, because the model boundary is replaceable by design and a
runner that recognised two providers and failed closed on a third would make
adding an adapter a governance event. Adding a provider is an ordinary adapter
change here, and never a gate amendment.

`response_id_form` is written `<prefix>:<min>-<max>`: a non-empty literal prefix
of at most sixteen characters drawn from `[A-Za-z0-9_-]`, then the inclusive
length range of the remainder, whose characters come from the same set, with
`1 <= min <= max <= 128`. An identifier satisfies the form when it begins with
that exact prefix and the remainder is that many admitted characters. Anthropic's
documented form is written `msg_:16-64` and OpenAI's chat-completions form
`chatcmpl-:8-128`; neither appears in this runner. All three records must declare
the same form byte for byte, because all three must already agree on the provider
the bound runner sealed, so no one record can relax the shape the other two are
held to. One record declares one form, which is what a role running against one
model at one endpoint produces; a role that observed two identifier shapes could
not be recorded here, and no locked role is one.

**Validating a declared form is weaker than validating a known one, and this
gate says so rather than implying otherwise.** A fabricator declares their own
form, so a declaration cannot make a fabricated identifier detectable; a record
that declared a lax form and then satisfied it would pass. What the check is
worth is internal consistency — every identifier has the shape its own record
claims, no identifier is reused, the count and the reported totals agree — and
the protection that was ever load-bearing is unchanged, because it was never the
form. It is the auditor's lookup of each identifier against the provider
account, below.

The runner checks exactly the following and nothing more. It requires the record
to exist; exactly three records; that each parses as one line in the canonical
key order with the declared value shapes; that each record's `role` and
`selector` equal the locked pair for its position and that `selector` is a safe
tracked path; that `provider`, `model`, `endpoint`, and `adapter_build` are
byte-identical to the identity the bound selector runner sealed for the
real-provider roles in this same run; that `response_id_form` is well formed
under the grammar above and identical across all three records; that every
identifier matches the form its own record declares; that no identifier is
reused within or across records; that `calls` equals the identifier count and
meets the floor above; that the reported token totals are consistent with that
count; that `candidate` is reachable from the running revision; and that no
record contains the provider credential's bytes.

What the runner does not prove, stated plainly because the whole mechanism is
worth only what this paragraph admits: it does not prove that any network call
happened. Every field it reads was produced inside the same test process that
produced the sealed identity, so a case that fabricated a well-formed identifier,
a plausible usage pair, a consistent count, and the form it declares for them
would pass all of the above. It
also cannot bind a retained identifier to the calls a later run made, so a record
copied forward from an earlier run is not mechanically detectable here.

What review owns is therefore the load-bearing half. Closure review looks each
retained identifier up in the provider account, confirms it exists in the window
`recorded` names, and confirms the reported usage matches the billed call. That
is the only step in this gate that reaches the provider, and the only one that
distinguishes a real call from a well-formed fabrication. Review also owns
whether the demonstration was a genuine task, whether the retained fields match
the process output they name, and whether the record describes this candidate's
runs. The gate's contribution is that fabrication now has to survive an external
lookup rather than only a reading of prose.

## Credential and Provider Boundary

The runner refuses `LOOPEX_PROVIDER_API_KEY` in its initial environment. An
optional credential enters only through the bounded stdin frame
`LOOPEX_M2_PROVIDER_V1\0<key>\0`, with a non-empty key of at most 16,384 bytes;
an interactive stdin or an immediate end of file means no key, and any other
input, missing terminator, extra field, or oversized key is refused. The key is
held in one unexported holder and is forwarded only to the three explicitly
tagged real-provider roles — demonstration `Db`, inherited 5c, and inherited 8b —
through the selector runner's own `LOOPEX_M1_SELECTOR_V1\0<nonce>\0<key>\0`
frame. It never appears in argv, in a child environment, in a file, in a
fixture, in an evidence field, or in retained output. Every gate-owned
diagnostic and record is compared against the literal key before emission, and a
collision exits non-zero with the colliding bytes suppressed.

Absence of a credential makes those three roles' evidence unavailable and fails
them. It never becomes a skip, an exclusion, or a pass. Credential-free roles,
compilation, repository commands, and the final suite never receive the key.

This is containment at the runner boundary. `M2` does not rebuild `M1`'s sealed
empty-environment re-exec, its bound OTP launcher, or its core-limit sealing,
and claims no defence against a hostile already-running shell or a privileged
host crash collector. Outcomes 4 and 6 and the attended demonstration separately
require every controlled tool child to receive an explicit credential-free
environment.

All three real-provider roles must agree on `provider`, `model`, `endpoint`, and
`adapter_build`. `M1` pinned exactly those four across its two real roles so one
green real path could not stand in for another run against a different provider
or build, and `M2` keeps that agreement rather than discarding it while claiming
to carry `M1`'s protection forward. The first real role observed sets the
reference identity and every later one must match it; a disagreement fails the
run. The retained real-call attestations must carry that same sealed identity
byte for byte, so the evidence record cannot name a provider, model, endpoint,
or adapter build the run did not actually seal.

## User-State Containment

The runner refuses a task root that resolves inside the operator's real
`~/.loopex`, owns `LOOPEX_HOME`, `TMPDIR`, the Mix build root, and its workspace
beneath the task root, and removes the task root on exit. It fingerprints the
operator's real product state by entry path, type, mode, ownership, size, and
link target before allocation and again after the run, and fails if the
fingerprint changed. Missing product state is recorded as absent rather than
treated as outside. The attended demonstration creates its Git repository inside
the task root and never in the operator's own repository. The opening probe owns
a separate evidence root of its own, allocated and removed before the task root
exists, and writes nowhere else.

## Documentation Obligations

Every row names files that `M2` must create or materially update before closure.
The gate proves their tracked presence; independent closure review proves their
freshness, completeness, and consistency with the implemented behaviour.

| Category | Required closure disposition |
| --- | --- |
| Operator-facing documentation | `docs/operator/coding-sessions.md`, `docs/operator/tools-and-policy.md` |
| Operator README | `docs/operator/README.md` |
| Developer-facing documentation | `docs/developer/agent-loop-and-tools.md`, `docs/developer/compatibility-surfaces.md`, `docs/developer/runtime-and-embedding.md` |
| Developer README | `docs/developer/README.md` |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |

`docs/operator/coding-sessions.md` documents running, streaming, steering,
resuming, and stopping a coding session; the four distinct input affordances;
the narrow meaning of `loopex cancel`; the project-resource trust prompt; and
states plainly that an `M1`-era session data root is not readable by `M2`. It
also states plainly what stopping does and does not promise: an interrupt ends a
run `cancelled` only where every owned operation was proved terminal and every
owned process tree was confirmed cleaned, and otherwise reports
`outcome_unknown` with a reconciliation reference. No operator document in this
milestone says an interrupt always ends a run cleanly.

`docs/operator/tools-and-policy.md` documents the four bootstrap tools, what
local execution can reach, how `--policy` selects a host policy, that a
permissive policy is a host's own named choice rather than a permission model,
and that omitting the policy refuses to start. It documents `loopex artifact`:
what a spilled artifact is, how a reference reaches the operator, and how to
read one back. It also discloses that the local store keeps session records and
artifact bytes unencrypted on the local disk under the resolved state root, so
an operator can decide what to let a session read.

`docs/developer/compatibility-surfaces.md` records that every surface `M2`
touches is unstable, that none is labelled or frozen, and what that means for an
embedder.

## Closure Document Set

Every path below must exist as a tracked ordinary file before green. Review, not
existence alone, proves freshness and completeness.

```text
CHANGELOG.md
README.md
DEVELOPMENT.md
VERSION
docs/README.md
docs/plans/README.md
docs/plans/M2.md
docs/plans/M2-technical.md
docs/plans/M2-gate.md
docs/evidence/README.md
docs/evidence/M2-toolchain-matrix.md
docs/evidence/M2-negative-demonstrations.md
docs/evidence/M2-coding-demonstration.md
docs/evidence/M2-real-call-attestations.md
docs/operator/README.md
docs/operator/coding-sessions.md
docs/operator/tools-and-policy.md
docs/developer/README.md
docs/developer/agent-loop-and-tools.md
docs/developer/compatibility-surfaces.md
docs/developer/runtime-and-embedding.md
docs/developer/agent-context-map.md
```

A `--capture` role may omit only the matrix path it is about to populate.

`docs/evidence/README.md` is in this set, so adding
`docs/evidence/M2-real-call-attestations.md` to the evidence directory means
indexing it there in the same change; an evidence record reachable only by
knowing it exists is not documented.

## Failure Rules and Declared Red

A required red blocks closure. Missing or unparsable evidence and missing
credentials are unavailable, never PASS. Never skip, filter, soften, quarantine,
rewrite, inflate a retry or timeout, or replace a real provider, store,
executor, tool process, or repository with a fake. A same-SHA, same-seed,
same-environment failure that vanishes on retry is a blocking flake until fixed
or explicitly dispositioned.

The gate becomes green only when an operator can run a coding task from the
command line: `loopex` submits a prompt into a durable session, the answer
streams as it is produced, the loop runs as many turns as the task needs while
the model sees the whole conversation and the real output of every tool it ran,
the operator can steer that run and queue the next one, four coding tools act on
a real workspace under a host policy that can refuse, Ctrl-C stops the owned
work and reports what happened, and yesterday's session can be found and
continued.

### Declared Red Condition

At the accepted opening checkpoint the runner emits a single line on standard
error. Its immutable declared-red text is:

```text
M2 gate RED: an operator cannot run a coding task from the command line; the session loop still stops after two turns, sends the model no conversation history, never streams, and offers only two demonstration tools
```

In the ordinary case the probe's observation line is appended to that same line
parenthetically, as `(observed through the public facade: <observation line>)`.
It is not a second line. Where the probe could not run, the additional condition
reaches the same declared red with no parenthetical, after a note on standard
output naming why the probe was unavailable.

That is the truthful state of the product this gate opens against, and it is
what the probe observes rather than what a file list implies. The loop is
hardwired to exactly two turns: turn one forces the single configured tool, and
every later turn is staged with an empty tool list and a `none` tool choice, so
turn two always terminates. No conversation history exists — each request is
built from one user message, and the second turn's content is a synthesized
string about the tool rather than the model's own prior message and the tool's
real output. Nothing streams; neither the model port nor the executor port has a
parameter a progress item could travel through, and nothing reaches the progress
plane during a run. There is no named tool set: the runtime accepts one
hand-written definition, the two demonstration tools exist as hardcoded clauses,
and there is no registry. There is no `loopex` command.

Adding a checker, a document, an evidence record, a status row, a new repository
check, or a test file cannot move this condition. Only the working loop, the
working tools, and the working command can.

<a id="amendment-1"></a>

## Amendment 1 — Close the Probe's Standard Input

**Acceptance: OUTSTANDING.** This section advances the generation and rebinds
one artifact, `scripts/check-m2-gate.sh`. The prior Acceptance row and lifecycle
state are retained here; the immediate child revision rebinds Acceptance to this
one and records the disposition.

The runner reads its provider credential from a bounded stdin frame, and it does
so after the opening probe, because the probe is hoisted to the front so the
declared red is an observation rather than a file check. The probe compiles the
tree and runs one Elixir program, and both inherited the runner's standard
input. A build tool that reads standard input therefore consumed the credential
frame before the runner ever looked at it.

That is not a hypothetical ordering hazard. Under the floor toolchain the
probe's `mix compile` drained the frame, and the run then reported the
credential absent and refused its real-provider roles — a true refusal about a
false absence, which is the worst shape a credential check can take, because it
is indistinguishable from an operator who supplied nothing. On the current
toolchain the same probe spawns the same class of child and the frame survived;
it survived by luck rather than by design, and a boundary that holds by luck on
one toolchain is not a boundary.

Both probe invocations now close standard input explicitly. Nothing else about
the runner changes: the same probe runs, observes the same loop, and emits the
same declared red, and the frame grammar, the credential refusal in the initial
environment, and the forwarding rule are untouched.

This strengthens the credential boundary rather than relaxing it. Before the
amendment a child could consume the frame; after it, no child can. No check is
removed, no threshold moves, no lane is exempted, and nothing that was refused
before is admitted now.

| Generation | Artifact | Rebound SHA-256 |
| --- | --- | --- |
| 1 | `scripts/check-m2-gate.sh` | `a4213ec1224dd863fbd59fc26f10ad2d20f3c75936f504cc34802d20e50b6f10` |
<a id="amendment-2"></a>

## Amendment 2 — Make the Closure Contract Match the Delivered Runtime

**Acceptance: OUTSTANDING.** This section advances the generation and rebinds
one artifact, `scripts/check-m2-gate.sh`. The prior Acceptance row and `In review`
lifecycle state are retained at this proposal. Its immediate one-parent
child rebinds Acceptance to this exact revision and records the maintainer's
disposition in one new amendment-specific anchor.

Closure review found that the accepted envelopes reached beyond the delivered
runtime and that several accepted selector names were weaker than, or no longer
matched, the behavior they claimed to protect. The product repairs precede this
proposal. This revision changes no byte under `apps/`; it amends the plan pair,
the locked gate and runner, and the operator and developer documents that must
describe those product bytes truthfully.

**Three accepted successor decisions are now explicit closure prerequisites.**
[ADR 0012](../adr/0012-executor-cancellation-capability.md#concept) makes
job-scoped executor cancellation a required capability and treats every answer
other than `{:ok, :cleaned}` as unconfirmed.
[ADR 0013](../adr/0013-run-deadline-commitment-at-first-request-staging.md#concept)
commits the declared duration at admission and fixes the absolute instant once,
at the run's first model-request staging.
[ADR 0014](../adr/0014-stream-closure-at-owner-loss.md#concept) requires a closure
only while an authoritative process-local owner can state it truthfully; abrupt
owner death and recognized executor owner loss without a retained terminal fact
end the transient plane without a fabricated closure. Each decision supersedes
only the accepted clauses it names. Nothing in this amendment broadens those
supersessions.

**The tool obligation says what each tool actually does.** `loopex.bash`, the
only coding tool that accepts a model-supplied command, launches a controlled OS
process whose first image and downstream command receive a constructed
credential-free environment. `read`, `write`, and `edit` take paths and data,
not commands; they execute bounded in the runtime and hold no child environment
to leak. Their containment is checked immediately before the effect, writes and
edits use create-exclusive staging plus rename, and the remaining fact that path
resolution and the effect are not one kernel operation is stated in the plan
and operator guidance and retained at the
[accepted limitation disposition](../evidence/M2-recorded-limitations.md#operator-path-race). `bash`
is outside that path-containment claim because it takes a command.

The same obligation now states the other boundaries closure review made
load-bearing: one session-declared cleanup period spans cooperative grace,
forced termination, confirmation, and bounded receipt retention; a process
group is not reported complete until it is confirmed quiescent; the workspace
lease remains held through durable receipt retention; only an executor-declared
pre-effect wrapper proves a refusal preceded an effect; every weaker or
post-effect answer is unproven; and the final effective deadline is checked
immediately before a local process can open.

**Run endings and stream endings are proved rather than inferred.** The
Technical envelope now requires an operation terminal fact to commit before the
run ending derived from it, makes unknown effect truth outrank completion,
abort, and every bound, and requires two-phase cancellation to remain responsive
while host cleanup runs under its declared bound. It also records ADR 0013's
duration-to-instant boundary and ADR 0014's owner-loss algebra. Unavailable
Control is runtime unavailability rather than an owner-loss verdict across
progress, closure, and post-commit publication. A successor never closes or
reuses a predecessor's unowned domain; retained terminal facts remain the only
basis for truthful late closure.

**The locked corpus follows the claims it now protects.** Seven outcome floors
rise: Outcome 1 from 17 to 67, Outcome 2 from 12 to 15, Outcome 3 from 8 to 9,
Outcome 4 from 8 to 39, Outcome 8 from 8 to 24, Outcome 10 from 16 to 17, and
Outcome 11 from 4 to 5. A three-case supporting stream-mechanics role locks the
Control distinction outside any operator outcome. The added identities came
from clause-derived mutation hunts: every survivor those hunts found became a
focused regression before it became a gate lock, and the amended corpus was
attacked again after each new lock.

Two identities locked at Acceptance had become false or stale and are corrected
in both this document and the runner. `every tool refuses a path that escapes
the workspace root through traversal or a symlink` becomes `every filesystem
tool refuses a path that escapes the workspace root through traversal or a
symlink`, because `bash` accepts a command and cannot truthfully be path-checked.
`write creates or replaces a file only beneath the workspace root` becomes
`write creates or replaces a file beneath the workspace root and refuses static
escapes`, which names the static guarantee without implying that resolution and
the effect are one kernel operation. No protected identity is left unresolved.

The retained-matrix sentence is also corrected from three evidence documents to
four, matching the executable rule and every capture. Operator and developer
documentation now describe the deadline, cancellation, containment, and
owner-loss closure boundaries that the code implements; the changelog and
compatibility inventory carry the same operator-visible consequences.

No executable check is removed, no threshold is lowered, and no lane is
exempted. Apart from the two false identities corrected above, the runner's
protected surface only grows. This proposal changes the accepted meaning only
where the accepted successor ADRs or the explicitly dispositioned containment
limitation require it, and makes every remaining claim stricter or more
accurately bounded.

| Generation | Artifact | Rebound SHA-256 |
| --- | --- | --- |
| 2 | `scripts/check-m2-gate.sh` | `508c2090f78be73fe8718cd214b68f705a2c3bb53aeea81269d7eb63f870f099` |
<a id="amendment-3"></a>

## Amendment 3 — Bind Truthful Progress and Bounded Attempt Evidence

**Acceptance: OUTSTANDING.** This section advances the generation and rebinds
one artifact, `scripts/check-m2-gate.sh`. The prior Acceptance row and `In review`
lifecycle state are retained at this proposal. Its immediate one-parent child
rebinds Acceptance to this exact revision and records the maintainer's
disposition in one new amendment-specific anchor.

Independent closure work after Amendment 2 found that progress ownership,
transient durability, provider-reply canonicalization, late-attempt retention,
and tool-schema enforcement could each be false while its locked corpus stayed
green. The product and regression repairs precede this proposal. This revision
changes no byte under `apps/`; it amends only the Technical envelope, this gate,
and its rebound runner.

**Progress ownership and durability now say what the runtime does.** The relay
is the sole transient emitter and orderer, but it assigns only model sequences.
An executor supplies its progress sequence; the coordinator validates the next
expected value and carries it unchanged. A refused current-sequence payload
consumes that producer sequence without consuming its byte offset, so a later
projected item exposes the visible gap. Model attempts and executor jobs each
capture the then-current durable event sequence as their own
`base_event_sequence`. Complete closure uses the retained producer count;
abandoned closure uses the relay's projected count. Closure, refusal accounting,
and refusal diagnostics remain transient and non-durable. Deltas are projected
on that transient plane and are never promoted to durable or stable public
truth.

The shipped local executor now proves that distinction through real child
bytes, not a hand-built event. Its `bash` case holds the command between two
chunks and observes the first before completion, then binds the complete job
identity, zero-based producer sequence, contiguous byte offset including
multibyte UTF-8, bounded chunk, and receipt count. Filesystem and demonstration
tools remain conforming when they emit no progress.

**Late provider results remain attempt evidence.** Abort and deadline cleanup
retain only the provider-neutral canonical reply or a bounded error under the
exact provider attempt that produced it, never as canonical conversation
history. Canonicalization admits only declared top-level and nested fields,
preserves the bounded provider response identifier, validates paired and
consistent stream metadata, and maps provider errors to one generic category.
The complete evidence record, not only its reply member, is checked against the
Store's private-record ceiling. Cleanup waits for the task's own result or
ordered `DOWN`; an earlier answer from the worker supervisor cannot prove that
the mailbox is empty. A Store refusal of that evidence makes cleanup unproven.
The cross-sender ordering, full-record bound, provider retry binding, and every
canonicalization boundary have deterministic regressions.

An unreadable live reply abandons and charges its attempt before the loop
retries; it cannot kill the coordinator or become history. Before policy,
grant, or job construction, every tool call is checked against its staged
definition's declared schema. Fractional JSON numbers remain fractional numbers through canonical
staging, durable dispatch, and Store transaction normalization.

**Rollback preserves governance history.** Restoring the accepted opening
product bytes uses descendant revert commits. It never resets, rebases, or
otherwise rewrites the milestone branch, so accepted ADRs, amendment
transactions, and their bound candidates remain reachable.

**The locked corpus follows those clauses.** Outcome 1 rises from 67 to 89 and
adds twenty-two identities: the prior twelve progress and late-attempt
boundaries plus JSON-number dispatch, schema refusal before policy, live
unreadable-reply retry, undeclared top-level refusal and nested-field projection, deep-term and
complete-record bounds, paired stream metadata, and generic error retention.
The existing admitted-abort case is also strengthened to require the retained
provider response identifier. Six reply/evidence identities also exercise
their surviving cross-products: the exact nested credential key, integer stream
coercion, a tuple-wrapped provider error, stale lower-attempt replay, an
oversized reply carrying a provider identifier, and an unreadable final retry.
Outcome 2 rises from 15 to 16 and locks the exported reply type's optional
provider response identifier. A ten-case protocol role locks evaluation of
every declared schema constraint rather than relying only on the end-to-end
integer refusal. Each added identity or strengthened body came from a
clause-derived mutant that survived the prior locked corpus, and each repaired
corpus was independently re-run against that mutant.

Outcome 4 remains at 39 while its stale identity
`executor progress carries the full identity epoch digest and fence tuple and a
refused event is dropped and counted` becomes `bash emits real progress before
completion with exact identity sequence offsets and receipt count`. The old case
had been replaced by the causal real-child regression before this proposal, so
retaining its name would leave the selector unresolved. The new case also kills
the character-count-for-byte-offset mutant independently.

No executable check is removed, no threshold is lowered, no lane is exempted,
and no previously refused result is admitted. The Outcome 1 and Outcome 2
floors rise, Outcome 4 stays fixed, the new schema role adds protection without
reclassifying an operator outcome, every other protected identity and floor is
unchanged, and the gate document and runner carry the same names and minima.

| Generation | Artifact | Rebound SHA-256 |
| --- | --- | --- |
| 3 | `scripts/check-m2-gate.sh` | `e1fc35c407c17b011059e226e83997606cb20ab6ba9d8ffb171b0a4ba5014b95` |
