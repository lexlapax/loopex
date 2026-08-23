# M2 Gate

Executable acceptance for `M2`. These canonical UTF-8/LF bytes and their SHA-256
are bound with the accepted plan pair and remain immutable for the milestone.
Progress rows and retained evidence may change only in conformance with that
accepted lock.

The one ordinary gate command is:

```text
bash scripts/check-m2-gate.sh
```

The runner catches mechanical accident and drift: a feature whose executable
definition does not exist, a command that stops passing, a protected case
renamed or skipped, a dependency creeping in, an evidence record never filled
in. Independent review still judges whether a test asserts what its name
promises, whether cancellations and mutations were honestly injected, whether
the attended demonstration was a genuine coding task rather than a scripted one,
whether the closure documents are current, and whether the operator experience
satisfies the Purpose.

This gate is not `M1`'s. It runs plain `bash` rather than privileged `bash`, it
binds three artifacts rather than nine, and it builds no sealed-environment
apparatus, no evidence verifier, and no environment launcher. Where `M2` needs
a check `M1` already proved, it invokes `M1`'s machinery. What `M2` does not
soften is what the machinery proves: every protected selector still runs through
the same standalone ExUnit channel with the same exact-name, exact-state, and
minimum-count rules, and `M1`'s own eight protected selectors are re-run beside
`M2`'s.

<a id="amendment-transaction-v1"></a>

Any amendment to this gate follows the generic two-revision proposal and rebind
transaction: proposal `A` advances the generation while retaining the prior
Acceptance row and lifecycle state, and its immediate one-parent child `R`
rebinds Acceptance to exact `A` and adds one new disposition anchor. Amendment
sections appear below in physical document order with consecutive numbers.

## Read-Only Opening Condition

Before reading provider input, spawning any child for product work, creating any
directory, or running Mix, the runner:

1. refuses `LOOPEX_PROVIDER_API_KEY` when it is present in the initial
   environment, disables automatic export, resolves the repository root through
   Git, and accepts only the bounded role grammar
   `[--preflight | --capture <lane>]`;
2. checks the nine `M2` operator features in order. Each check names the feature
   an operator would miss and requires that feature's protected selector to
   exist as a readable file containing every locked case identity. The first
   failure is the declared red;
3. checks the eight inherited `M1` outcome selectors, the reused selector-runner
   mechanics corpus, and the dependency corpus at their exact locked case
   identities;
4. verifies the bound artifacts below against the files they name, selecting a
   validated `shasum` or `sha256sum` dialect;
5. requires every closure document to exist as a tracked ordinary file;
6. requires Darwin or Linux and a wholly clean source tree.

No write may move above that condition. A read-only reviewer with no writable
root therefore reaches the declared red. The `--preflight` role stops exactly
there and prints `M2 preflight OK`; it allocates nothing, invokes no Mix or
product selector, and can print neither `capture` nor `M2 gate GREEN`.

## Bound Artifacts

| SHA-256 | Path |
| --- | --- |
| `cccb7612517528ef127f447605a9a84c6171a7a1d7189e6f0435fbd856bed163` | `scripts/check-m2-gate.sh` |
| `cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0` | `scripts/m1-exunit-runner.exs` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

`scripts/m1-exunit-runner.exs` is bound at exactly the bytes `M1` closed with.
`M2` reuses that authoritative channel unchanged; changing it would change what
every `M1` and `M2` protected result means. The gate document externally binds
`scripts/check-m2-gate.sh`, which `mix loopex.status` verifies, without
pretending a runner can verify its own bytes before executing them.

`apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` is deliberately **not** bound.
`M2` changes it: the planned inventory grows from six applications to seven, and
the `:client` rule widens so a client may declare production dependencies on the
`:edge` applications it composes. Binding bytes the milestone must change would
lock a digest acceptance already knows is wrong. The command stays locked, and
its adversarial corpus grows two cases that prove the new inventory and the new
client rule. `M2` therefore does change a repository check, and says so here
rather than claiming otherwise.

The closed `M1` gate binds those same bytes and freezes the six-application
inventory, so it cannot be inherited unchanged by any milestone that ships an
operator command. `M2` carries `M1`'s protection forward behaviourally instead:
its eight protected outcome selectors are re-run here at their exact locked
identities. The closed `M0` gate is unaffected — it locks the command without
binding its bytes — and remains an inherited required gate re-proved on both
locked pairs at every `M2` source candidate.

## Repository Commands and Owned State

After the read-only condition passes, the runner reads the optional provider
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
| 12 | `mix loopex.status` | Live governance, indexes, links, and lifecycle state validate |
| 13 | `bash scripts/check-bootstrap.sh` | The portable aggregate remains green |
| 14 | the root `VERSION` file | Reports exactly `0.1.0` |
| 15 | the nine protected `M2` outcomes through the standalone channel | Exact names, states, and minima below hold |
| 16 | the eight inherited `M1` outcomes and the two mechanics corpora through the standalone channel | `M1`'s proved behaviour still holds |
| 17 | `MIX_ENV=test mix test --exclude real_provider --seed <gate-seed>` | The complete credential-free suite passes at the same seed |
| 18 | retained evidence validation | Negative demonstrations always; the toolchain matrix in ordinary mode only |

One canonical decimal seed from `0` through `999999` covers every protected
role, every inherited role, and the final suite. The final ordinary line is
exactly:

```text
M2 gate GREEN seed=<N> protected_executed=<M>
```

`protected_executed` sums executed cases assigned to Outcomes 1–9 only.
Excluded tests never count, and inherited, mechanics, bootstrap, and full-suite
executions are excluded from that sum.

## Authoritative ExUnit Channel

Every protected and inherited selector runs by invoking the bound `M1` script
directly, never a Mix test task or alias:

```text
elixir scripts/m1-exunit-runner.exs --loopex-m1-selector [--only-real-provider --real-path combined] <root> <test-build> <selector> <owner> <internal-csv> <allowed-csv> <seed> <minimum> <zero|positive> <state=name>...
```

The owner and its internal and allowed application closures come from the
repository's own dependency authority, invoked directly as
`Loopex.Checks.DepsBudget.main(["--context", <selector>, <project configs>...])`
before each role, so a selector cannot claim a closure its project declaration
does not support.

Every role receives exactly
`LOOPEX_M1_SELECTOR_V1\0<32-lowercase-hex-nonce>\0<key>\0` on stdin. The default
role's key field is empty; the real role's is non-empty. The script consumes
stdin before candidate startup, requires the selector to be a tracked ordinary
file under `apps/<owner>/test/`, verifies the compiled owner and closure, and
starts that application without compilation or `test_helper.exs`. Startup is
credential-free. Official `ExUnit.RunnerStats` supplies totals, failures, skips,
and exclusions; formatter events bind each test to its exact selector, name, and
state. Missing or duplicate names, wrong states, foreign files, unaccounted
exclusions, skips, failures, or a count below the role minimum fail. The runner
prints one nonce-bound authoritative marker and hard-halts; arbitrary stdout is
diagnostic, not authority.

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
| 1 | `apps/loopex/test/agent_loop_test.exs` / default | 5 | passed: `a prompt runs until the model stops requesting tools rather than after a fixed number of turns`; `every model request carries the committed conversation history including the original prompt`; `an assistant tool call and its real tool result are committed and replayed to the model`; `a bounded turn ceiling ends the run truthfully instead of stopping silently`; `each turn dispatches exactly the canonical request bytes and digest committed before it` |
| 2 | `apps/loopex/test/tool_registry_test.exs` / default | 4 | passed: `a runtime-scoped registry resolves a tool id and version and refuses an unknown id`; `two runtimes carry independent tool registries with no global registration`; `a conflicting tool id and version registration is refused with an explicit reason`; `a model request records the exact tool definition generation it used` |
| 3 | `apps/loopex_executor_local/test/coding_tools_test.exs` / default | 7 | passed: `read returns bounded chunked content and reports truncation`; `write creates or replaces a file only beneath the workspace root`; `edit applies an exact match change and names what differed on a mismatch`; `bash runs an argv command and an explicit raw shell command with distinct semantics`; `every tool refuses a path that escapes the workspace root through traversal or a symlink`; `tool output beyond its declared bound spills to an artifact`; `a tool child process tree is owned and terminated with its job` |
| 4 | `apps/loopex_executor_local/test/host_policy_test.exs` / default | 4 | passed: `a host policy deny decision issues no grant and starts no operating system process`; `a denied tool call commits a truthful denied outcome the operator can read`; `the run continues or terminates truthfully after a denial and never retries the refused call`; `the trusted local allow all policy is explicit configuration rather than an implicit fallback` |
| 5 | `apps/loopex/test/cancellation_test.exs` / default | 5 | passed: `an abort admitted during a model call cancels the run and schedules no new work`; `an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled`; `a validated terminal tool fact committed before the abort is preserved and not overwritten`; `an effect without sufficient evidence ends outcome unknown and is never blindly retried`; `the operator observes what was cancelled and what actually happened` |
| 6 | `apps/loopex/test/session_directory_test.exs` / default | 5 | passed: `a fresh operating system process lists the sessions in a resolved state root`; `the state root resolves from LOOPEX_HOME and never from application environment`; `a session resumes under the durable runtime placement identity that created it`; `resuming a session through a different runtime identity is refused with an explicit reason`; `a repeated resume command identity returns its historical result while a fresh identity acquires ownership` |
| 7 | `apps/loopex_cli/test/cli_test.exs` / default | 6 | passed: `loopex run submits a prompt and prints the streamed answer with its tool calls and results`; `loopex sessions lists the operator's sessions and loopex resume continues one`; `loopex cancel stops the running task and prints what was observed`; `the command surface drives only the public facade and owns no loop store cursor or authority`; `the base system prompt and active tool definitions measure under one thousand tokens`; `argument parsing and terminal output use only the standard library` |
| 8 | `apps/loopex_cli/test/kernel_composition_test.exs` / default | 3 | passed: `one page of shipped code starts a runtime creates a session submits a prompt and consumes events`; `the shipped composition is the same one the loopex command uses`; `the composition resolves its state root explicitly and never through application environment` |
| 9a | `apps/loopex_cli/test/coding_task_test.exs` / default | 4 | passed: `a multi tool task reads edits and verifies a file in a disposable repository`; `the task transcript shows every tool call decision and result`; `a denied tool call inside a multi tool task is reported and the task continues truthfully`; `the demonstration workspace is disposable and never the operator's own repository`; excluded: the real case below |
| 9b | same file / real-only | 1 | passed: `one real provider task edits a real repository across several turns and the operator sees the committed result`; excluded: the four deterministic names above |

Outcome 9's real case itself proves the attended claim: a real provider drove
the shipped command through several turns and several distinct tools including
one `edit` and one `bash`, one host-policy refusal was reported and the task
continued truthfully, and the resulting bytes exist on disk in a disposable
repository created inside the gate's own task root. The deterministic cases
support that claim and never substitute for it. Outcome 7's facade-only case
must fail if any module outside the single shipped composition reaches a
coordinator, store, model, executor, journal, outbox, or cursor internal.

## Inherited M1 Protection

`M1` is closed, and the behaviour it proved is the floor this milestone stands
on. Each selector below runs through the same authoritative channel at `M1`'s
exact locked identities, states, and minima. Their executed counts do not enter
`protected_executed`.

| Selector / role | Minimum | Locked obligation |
| --- | --- | --- |
| `apps/loopex/test/runtime_test.exs` / default | 3 | Explicit runtime references and two-runtime isolation |
| `apps/loopex/test/session_lifecycle_test.exs` / default | 6 | Runtime-control creation, owner succession, and derived fault coverage |
| `apps/loopex_store_local/test/store_conformance_test.exs` / default | 5 | ADR 0006 transaction, fencing, resolution, and durability semantics |
| `apps/loopex/test/embedded_api_test.exs` / default | 4 | Attachment barriers, bounded queues, restart, and gap-free resume |
| `apps/loopex_llm_reqllm/test/real_model_lane_test.exs` / default | 1 | One model conformance suite across both adapters |
| `apps/loopex_reference_client/test/real_model_session_test.exs` / default | 1 | Committed canonical request bytes reach dispatch; the real case is excluded |
| `apps/loopex_executor_local/test/executor_test.exs` / default | 6 | ADR 0007 grant oracle, final pre-start validation, lease, and receipt |
| `apps/loopex_reference_client/test/reference_client_test.exs` / default | 2 | Facade-only client with no alternate loop |
| `apps/loopex_reference_client/test/end_to_end_recovery_test.exs` / default | 5 | Reconciliation oracle, one dispatch per effect, `outcome_unknown`; the real trace is excluded |

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

`apps/loopex/test/deps_budget_test.exs`, minimum 27, including these passed
names:

- `the repository satisfies the dependency budget and direction`
- `the M2 planned inventory admits exactly seven applications with their declared roles`
- `a client composes the edge applications it depends on and declares no external package`

The minimum rises from `M1`'s 25 because the inventory change and the widened
client rule each require their own adversarial case. Removing a case to reach
the number is a gate weakening and requires the ordinary authority.

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
fresh, disjoint owned task root. They run the complete `M2` command set except
matrix validation and emit one `capture ... verdict=CAPTURE exit=0` record
carrying the successful real role's sealed identity fields. They never invoke
the gate recursively, never print GREEN, and are not merge evidence. Pair order
and adjacency are inert; repeating a green execution proves nothing additional.

The operator separately runs `bash scripts/check-m0-gate.sh` once under the
floor pair and once under the current pair against the same `C`. Bootstrap does
not substitute for either run, and `M2` never nests `M0`.

`docs/evidence/M2-toolchain-matrix.md` carries the `loopex:m2-matrix` markers
around one `text` fence containing these six lines in order:

```text
matrix candidate=<C> gate_sha256=<digest> runner_sha256=<digest> exunit_runner_sha256=<digest> tool_versions_sha256=<digest> command=bash:scripts/check-m2-gate.sh
capture lane=darwin-floor candidate=<C> elixir=1.17.0 otp=26.0 seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 os=darwin arch=<ASCII-token> provider=<ASCII-token> model=<ASCII-token> endpoint=<ASCII-token> adapter_build=loopex_llm_reqllm@0.1.0 executor_build=loopex_executor_local@0.1.0 executor_identity=<ASCII-token> tool_identity=<ASCII-token> recorded=<UTC-RFC3339-second>
capture lane=darwin-current candidate=<C> elixir=1.20.3 otp=29.0.5 seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 os=darwin arch=<ASCII-token> provider=<same> model=<same> endpoint=<same> adapter_build=loopex_llm_reqllm@0.1.0 executor_build=loopex_executor_local@0.1.0 executor_identity=<same> tool_identity=<same> recorded=<UTC-RFC3339-second>
capture lane=linux-current candidate=<C> elixir=1.20.3 otp=29.0.5 seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 os=linux arch=<ASCII-token> provider=<same> model=<same> endpoint=<same> adapter_build=loopex_llm_reqllm@0.1.0 executor_build=loopex_executor_local@0.1.0 executor_identity=<same> tool_identity=<same> recorded=<UTC-RFC3339-second>
m0 lane=floor candidate=<C> gate_sha256=<M0 digest> command=bash:scripts/check-m0-gate.sh elixir=1.17.0 otp=26.0 verdict=GREEN exit=0
m0 lane=current candidate=<C> gate_sha256=<M0 digest> command=bash:scripts/check-m0-gate.sh elixir=1.20.3 otp=29.0.5 verdict=GREEN exit=0
```

Retained tokens are printable ASCII, so Unicode lookalikes and direction
controls cannot change what a reviewer sees. The runner requires the matrix
markers, one exact 40-hex candidate shared by every row, that candidate to be
reachable from the running revision, one valid capture row per lane, both `M0`
re-proof rows, and that the tree difference between the candidate and the
running revision is empty or exactly the three evidence documents. All three
capture rows must agree on provider, model, endpoint, adapter build, executor
build, executor identity, and tool identity; their observation times and
architectures are independent recorded facts. Review cross-checks every retained
field against the actual captured process output.

The three captures, the negative demonstrations, and the attended demonstration
record are committed in evidence commit `E`, the direct one-parent child of `C`.
`C→E` may change exactly `docs/evidence/M2-toolchain-matrix.md`,
`docs/evidence/M2-negative-demonstrations.md`, and
`docs/evidence/M2-coding-demonstration.md`. The ordinary gate runs at `E` on all
three lanes and alone may emit final GREEN. Closure transition `T` is the unique
commit that first completes `M2`'s canonical Closure record and is the direct
one-parent child of `E`; `E→T` changes exactly `docs/plans/M2.md`,
`docs/plans/README.md`, and `README.md`.

## Negative Demonstrations

`docs/evidence/M2-negative-demonstrations.md` contains exactly five records, in
this order, each one one-line JSON object in its own `json` fence:

1. Outcome 1 / `committed_history_projection` /
   `apps/loopex/test/agent_loop_test.exs`
2. Outcome 2 / `tool_definition_generation_binding` /
   `apps/loopex/test/tool_registry_test.exs`
3. Outcome 3 / `workspace_path_scope_containment` /
   `apps/loopex_executor_local/test/coding_tools_test.exs`
4. Outcome 4 / `host_policy_deny_prestart_refusal` /
   `apps/loopex_executor_local/test/host_policy_test.exs`
5. Outcome 5 / `cancellation_cleanup_confirmation` /
   `apps/loopex/test/cancellation_test.exs`

The exact key order is:

```json
{"mechanism_disabled":"<exact ID>","selector":"<exact selector>","observed_failure":"<nonempty printable ASCII>","candidate":"<40 lowercase hex>","artifact":"<safe tracked path>","restored_sha256":"sha256:<64 lowercase hex>"}
```

Each record starts from its own named clean candidate, disables only that
mechanism, runs the named selector which must fail for the named reason,
restores the artifact from `git show <candidate>:<path>`, and verifies the
restored digest and whole-tree cleanliness before the next record. No record
stands in for two mechanisms, and a failure observed from a dirty or previously
mutated baseline is no evidence. The runner proves record identity and
cardinality; review proves one clean-baseline mechanism was disabled and caused
the named failure.

## Credential and Provider Boundary

The runner refuses `LOOPEX_PROVIDER_API_KEY` in its initial environment. An
optional credential enters only through the bounded stdin frame
`LOOPEX_M2_PROVIDER_V1\0<key>\0`, with a non-empty key of at most 16,384 bytes;
an interactive stdin or an immediate end of file means no key, and any other
input, missing terminator, extra field, or oversized key is refused. The key is
held in one unexported holder and is forwarded only to the explicitly tagged
real-provider role through the selector runner's own
`LOOPEX_M1_SELECTOR_V1\0<nonce>\0<key>\0` frame. It never appears in argv, in a
child environment, in a file, in a fixture, in an evidence field, or in retained
output. Every gate-owned diagnostic and record is compared against the literal
key before emission, and a collision exits non-zero with the colliding bytes
suppressed.

Absence of a credential makes the real-provider role's evidence unavailable and
fails that role. It never becomes a skip, an exclusion, or a pass. Credential-
free roles, compilation, repository commands, and the final suite never receive
the key.

This is containment at the runner boundary. `M2` does not rebuild `M1`'s sealed
empty-environment re-exec, its bound OTP launcher, or its core-limit sealing,
and claims no defence against a hostile already-running shell or a privileged
host crash collector. Outcomes 3, 4, and 9 separately require every controlled
tool child to receive an explicit credential-free environment.

## User-State Containment

The runner refuses a task root that resolves inside the operator's real
`~/.loopex`, owns `LOOPEX_HOME`, `TMPDIR`, the Mix build root, and its workspace
beneath the task root, and removes the task root on exit. It fingerprints the
operator's real product state by entry path, type, mode, ownership, size, and
link target before allocation and again after the run, and fails if the
fingerprint changed. Missing product state is recorded as absent rather than
treated as outside. The demonstration in Outcome 9 creates its Git repository
inside the task root and never in the operator's own repository.

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

`docs/operator/coding-sessions.md` documents running, resuming, and stopping a
coding session and states plainly that an `M1`-era session data root is not
readable by `M2`. `docs/operator/tools-and-policy.md` documents the four
bootstrap tools, what local execution can reach, and that the `AllowAll` default
is for a trusted developer rather than a permission model.
`docs/developer/compatibility-surfaces.md` records the five surfaces `M2`
labels, all `experimental`, and what an experimental label promises.

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
command line: `loopex` submits a prompt into a durable session, the loop runs as
many turns as the task needs while the model sees the whole conversation and the
real output of every tool it ran, four coding tools act on a real workspace under
host policy that can refuse, stopping the task stops the owned work and reports
what happened, and yesterday's session can be found and continued.

### Declared Red Condition

At the accepted opening checkpoint the runner emits exactly:

```text
M2 gate RED: an operator cannot run a coding task from the command line; the session loop still stops after two turns, sends the model no conversation history, and offers only two demonstration tools
```

That is the truthful state of the product this gate opens against. The loop is
hardwired to exactly two turns: turn one forces the single configured tool, and
every later turn is sent an empty tool list and a `none` tool choice, so turn
two always terminates. No conversation history exists — each request is built
from one user message, and the second turn's content is a synthesized string
about the tool rather than the model's own prior message and the tool's real
output. Two demonstration tools exist as hardcoded clauses, one per session,
with no registry. There is no `loopex` command.

Adding a checker, a document, an evidence record, a status row, or a new
repository check cannot move this condition. Only the working loop, the working
tools, and the working command can.
