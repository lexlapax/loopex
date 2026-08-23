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
outside the checkout. Compilation goes to a build root inside that evidence root
rather than the checkout's, so neither a stale nor an absent `_build` can change
what the probe sees, and the checkout is never written to. The program composes a
runtime from shipped modules only — the durable local store, the trusted-local
executor, and its own observing model adapter — starts it through
`Loopex.start_link/1`, creates a session, submits one prompt through the public
facade, waits for the session to settle, and reports five observations: how many
model requests the loop staged, whether the last staged request carried the
committed conversation or one synthesized user message, how many items reached
the progress plane during the run, whether the model and executor ports expose
the arity that carries a progress function at all, and whether the runtime
accepted a named active tool set or only one hand-written definition. It asks for
the `M2` shape first and falls back to the `M1` shape, so one program observes
either tree and a refusal is itself one of the observations.

`M2` is present only when all five hold at once: the loop ran past turn two while
the model kept asking for tools, the last staged request carried an assistant
message and a real tool result, at least one delta reached the progress plane,
both ports can carry progress, and the accepted tool set is named and is not
composed only of demonstration tools. Anything else is the declared red, emitted
together with the observation line that produced it.

The probe's model adapter is a harness. Nothing it observes is a real-path claim,
and it satisfies no outcome and no closure obligation.

### The locked definitions are the additional condition

After the probe, and never in place of it, the runner:

1. checks the eleven `M2` operator features, the supporting tool-registry
   mechanism, and the attended demonstration in order. Each check names what an
   operator or the closure evidence would be missing and requires that
   definition to exist as a readable file containing every locked case identity;
2. checks the nine inherited `M1` outcome selector files, the reused
   selector-runner mechanics corpus, and the dependency corpus at their exact
   locked case identities;
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
| `66bf9b9287921a8aaa9d424955d14c532d32b3f8464fa0ec0d6e093764bfa1f4` | `scripts/check-m2-gate.sh` |
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
`M2` changes both: the planned inventory grows from six applications to seven,
the `:client` rule widens so a client may declare production dependencies on the
`:edge` applications it composes, and the corpus gains the two adversarial cases
that prove each. Binding bytes the milestone must change would lock a digest
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
real product state, fingerprints that state before and after the run, and
requires the fingerprint unchanged. The task root is removed on exit.

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
| 1 | `mix loopex.deps_budget` | Application identity, the `M2` seven-application inventory, role rules, and dependency direction |
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
| 15 | the eleven protected `M2` outcomes, the supporting registry role, and both demonstration roles through the standalone channel | Exact names, states, and minima below hold |
| 16 | the eleven inherited `M1` outcome roles and the two mechanics corpora through the standalone channel | `M1`'s proved behaviour still holds |
| 17 | `MIX_ENV=test mix test --exclude real_provider --seed <gate-seed>` | The complete credential-free suite passes at the same seed |
| 18 | retained evidence validation | Negative demonstrations always; the toolchain matrix in ordinary mode only |

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
1–11, the supporting registry role, and both demonstration roles. Excluded tests
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
| 1 | `apps/loopex/test/agent_loop_test.exs` / default | 13 | passed: `a prompt runs until the model stops requesting tools rather than after a fixed number of turns`; `every model request carries the committed conversation history including the original prompt`; `an assistant tool call and its real tool result are committed and replayed to the model`; `each turn dispatches exactly the canonical request bytes and digest committed before it`; `a staged request carries complete tool definition bytes and its generation triple and is reconstructible from the journal alone`; `every turn after the first is canonical history replay and the reserved continuation field stays empty`; `the maximum turn bound ends the run bound reached before another provider call`; `the cumulative token budget ends the run bound reached before another provider call`; `the wall clock deadline ends the run bound reached before another provider call`; `the committed absolute deadline is propagated into the model call rather than an independent per call timeout`; `a reply committed before an admitted abort completes the turn and an abort admitted first keeps the late reply as attempt evidence only`; `a cancelled turn is charged its request bytes and its committed max tokens in full and marked estimated`; `every sampling bound is a declared committed value with no implicit default` |
| 2 | `apps/loopex_llm_reqllm/test/streaming_conformance_test.exs` / default | 9 | passed: `every model adapter satisfies one streaming conformance suite`; `each canonical delta kind is bounded plain data carrying no provider or host term`; `a text delta is observable while its operation is still incomplete rather than after the reply returns`; `replaying an adapter's emitted deltas reproduces the reply it returned byte identically`; `the model and executor progress domains carry separate sequences each closed by its own content free item`; `a gapless turn sequence and the reply's delta count make lost progress detectable`; `the committed assistant message is built from the reply and never assembled from deltas`; `a cancelled stream commits no assistant message and a late reply never becomes canonical`; `an adapter that emits no deltas is conformant and declares that it does not stream` |
| 3 | `apps/loopex/test/input_algebra_test.exs` / default | 8 | passed: `a prompt starts a run only while the session is settled and is otherwise refused`; `the runtime never infers whether new input is steering or follow up and a steer must name its active run`; `a steer joins the active run after the current tool batch and before the next model request`; `a steer is recorded applied only when a committed request carried it`; `a follow up starts a new run only after the active run and its steering settle`; `a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted`; `at most one unapplied steer and one queued follow up exist and both survive owner succession`; `an abort resolves any unapplied steer and queued follow up as cancelled` |
| 4 | `apps/loopex_executor_local/test/coding_tools_test.exs` / default | 7 | passed: `read returns bounded chunked content and reports truncation`; `write creates or replaces a file only beneath the workspace root`; `edit applies an exact match change and names what differed on a mismatch`; `bash runs an argv command and an explicit raw shell command with distinct semantics`; `every tool refuses a path that escapes the workspace root through traversal or a symlink`; `executor progress carries the full identity epoch digest and fence tuple and a refused event is dropped and counted`; `a tool child process tree is owned and terminated with its job` |
| 5 | `apps/loopex_store_local/test/artifact_store_conformance_test.exs` / default | 6 | passed: `every artifact store implementation satisfies one conformance suite`; `tool output beyond its declared bound spills to an artifact instead of truncating silently`; `the durable artifact event carries digest media type size role and an opaque reference`; `the model facing result stays under its bound and names what was truncated`; `the operator retrieves a spilled artifact by its opaque reference through the public facade`; `an artifact round trips byte exactly and a missing artifact reports unavailable` |
| 6a | `apps/loopex_executor_local/test/host_policy_test.exs` / default | 8 | passed: `every host policy implementation satisfies one policy port conformance suite`; `a host policy deny decision issues no grant and starts no operating system process`; `a denied tool call commits a truthful denied outcome the operator can read`; `the run continues or terminates truthfully after a denial and never retries the refused call`; `a policy that raises times out or returns a malformed value fails closed into denial`; `defer is declared and refused in this milestone rather than treated as allow or deny`; `every executor backed tool requires a policy decision including a read only tool`; `a permissive policy applies only when it is named and omitting the policy option refuses runtime start` |
| 6b | `apps/loopex_reference_client/test/allow_all_policy_test.exs` / default | 2 | passed: `the shipped allow all policy allows every decision it is asked`; `the shipped allow all policy emits exactly one permissive authority notice` |
| 7 | `apps/loopex/test/project_resource_trust_test.exs` / default | 7 | passed: `discovery resolves a canonical ordered resource set under declared path size and total limits`; `the operator is shown every resolved path its provenance and the manifest digest`; `an explicit trust decision binds workspace revision manifest and digests`; `a changed workspace revision manifest or content invalidates the decision`; `a headless run without a matching positive decision fails closed and stages no project block`; `an ordinary workspace read stays a policy governed tool effect and is never context staging`; `an admitted project block changes no tool set policy decision bound or grant` |
| 8 | `apps/loopex/test/cancellation_test.exs` / default | 8 | passed: `an interrupt reaches the run through the public facade and through no private path`; `an abort admitted during a model call cancels the run and schedules no new work`; `an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled`; `a run finishes cancelled only when every owned operation is validated terminal and every owned process tree is confirmed cleaned`; `a validated terminal tool fact committed before the abort is preserved and not overwritten`; `an effect without sufficient evidence ends outcome unknown and is never blindly retried`; `a second interrupt reports what is still being cleaned up rather than abandoning the session`; `the operator observes what was cancelled and what actually happened` |
| 9 | `apps/loopex/test/session_directory_test.exs` / default | 5 | passed: `a fresh operating system process lists the sessions in a resolved state root`; `the state root resolves from LOOPEX_HOME and never from application environment`; `a session resumes under the durable runtime placement identity that created it`; `resuming a session through a different runtime identity is refused with an explicit reason`; `a repeated resume command identity returns its historical result while a fresh identity acquires ownership` |
| 10 | `apps/loopex_cli/test/cli_test.exs` / default | 15 | passed: `loopex run submits a prompt and streams the answer with its tool calls and results`; `the operator steers a running task and queues a follow-up from the same terminal`; `prompt steer follow up and abort have distinct explicit affordances and input naming neither is refused`; `tool progress from a running executor job reaches the operator's terminal before the tool finishes`; `loopex sessions lists the operator's sessions and loopex resume continues one`; `an interrupt signal delivered to a running loopex process cancels the task through the public facade`; `an interrupt whose cleanup cannot be confirmed reports outcome unknown with its reconciliation reference`; `loopex cancel reconciles a session left behind by a dead process and is refused against a live owner`; `the policy option selects the governing host policy and a refusal is reported in the transcript`; `the command ships its own permissive policy that is named explicitly, prints one notice, and is never an implicit fallback`; `loopex artifact retrieves a spilled artifact by its opaque reference`; `project resource trust is decided at the terminal and a non interactive run without a decision fails closed`; `the command surface drives only the public facade and owns no loop store cursor or authority`; `the base system prompt and active tool definitions measure under one thousand tokens`; `argument parsing and terminal output use only the standard library` |
| 11 | `apps/loopex_cli/test/kernel_composition_test.exs` / default | 3 | passed: `one page of shipped code starts the application tree a runtime a session a prompt and its events`; `the shipped composition is the same one the loopex command uses`; `the composition resolves its state root explicitly and never through application environment` |

Outcome 10's facade-only case must fail if any module outside the single shipped
composition reaches a coordinator, store, model, executor, policy, artifact
store, journal, outbox, or cursor internal. Outcome 6 is split across two roles
because the two halves prove different things: the executor edge proves the
runtime property that a permissive policy applies only when a host names it,
using the selector's own in-file fixtures and importing nothing from a client,
while the reference client's lane proves what its own shipped `AllowAll` module
does. Neither role may be satisfied by the other.

## Locked Supporting Mechanism Selector

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

## Mandatory Closure Evidence

One attended real-provider demonstration is required for closure. It is not an
outcome, because completing one demonstration is not a capability an operator
asks for; it is the evidence that the eleven outcomes add up to a coding agent
rather than to eleven passing selectors. That makes it more binding, not less: a
closure candidate without it is refused, and its real-provider role is locked
here exactly as an outcome's role is.

| Role | Selector / role | Minimum | Locked names and required states |
| --- | --- | --- | --- |
| Da | `apps/loopex_cli/test/coding_task_test.exs` / default | 4 | passed: `a multi tool task reads edits and verifies a file in a disposable repository`; `the task transcript shows every tool call decision and result`; `a denied tool call inside a multi tool task is reported and the task continues truthfully`; `the demonstration workspace is disposable and never the operator's own repository`; excluded: the real case below |
| Db | same file / real-only, `combined` profile | 1 | passed: `one real provider task streams edits a real repository across several turns and the operator sees the committed result`; excluded: the four deterministic names above |

Role `Db` carries the attended claim: a real provider drove the shipped command
through several turns and several distinct tools including one `edit` and one
`bash`, the answer streamed and reconstructed once per turn, one host-policy
refusal was reported and the task continued truthfully, and the resulting bytes
exist on disk in a disposable repository created inside the gate's own task root.
The deterministic cases in `Da` support that claim and never substitute for it.

What the runner mechanically proves is narrower than that paragraph. It proves
one locked case name ran and passed with a credential present, and that the
retained identity record is well formed and agrees across roles. The identity is
supplied by the test, so a case that fabricated it and opened no socket would
satisfy the runner. That limit is inherited from `M1`'s channel and is not
softened here; it means the attended claim rests on closure review reading the
retained record and the demonstration repository rather than on the runner, and
it applies to every real-provider role in this gate, inherited or `M2`'s own.
Its retained record is `docs/evidence/M2-coding-demonstration.md`, and the
identity fields it seals are the ones the capture record carries.

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

`apps/loopex/test/status_check_test.exs`, minimum 42, including these passed
names:

- `a Closed milestone's gate is amended by an accepted generation, not a rebind`
- `a gate generation table fails closed on every malformed shape`
- `a gate generations table is append-only in both admitted directions`
- `the integrated phase is derived from the register's closed rows`

`apps/loopex/test/history_anchoring_test.exs`, minimum 16, including these
passed names:

- `a Closed milestone's gate generation is one atomic proposal and one rebind`
- `recorded gate generations are append-only across reachable history`

Both files are locked here because `M2`'s own prerequisite is the transaction
they enforce. `M0` locks the second at minimum 3 and cannot be reopened, so
without these rows the cases proving a Closed milestone's gate cannot be silently
rebound could be deleted without tripping any count. The machinery that enforces
immutable governance records was otherwise protected only by convention.

`apps/loopex/test/deps_budget_test.exs`, minimum 27, including these passed
names:

- `the repository satisfies the dependency budget and direction`
- `the M2 planned inventory admits exactly seven applications with their declared roles`
- `a client composes the edge applications it depends on and declares no external package`

The minimum rises from `M1`'s 25 because the inventory change and the widened
client rule each require their own adversarial case. Removing a case to reach
the number is a gate weakening and requires the ordinary authority. This file is
one of the two `M1`-bound artifacts the accepted plan pair's gate-generation
prerequisite rebinds.

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
the running revision to be empty or exactly the three evidence documents.

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
run.

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

At the accepted opening checkpoint the runner emits exactly:

```text
M2 gate RED: an operator cannot run a coding task from the command line; the session loop still stops after two turns, sends the model no conversation history, never streams, and offers only two demonstration tools
```

followed, in the ordinary case, by the observation line the probe produced.

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
