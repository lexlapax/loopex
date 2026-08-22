# M1 Gate

Executable acceptance for `M1`. These canonical UTF-8/LF bytes and their
SHA-256 are bound with the accepted plan pair and remain immutable for the
milestone. Progress rows and retained evidence may change only in conformance
with that accepted lock.

The one ordinary gate command is:

```text
/bin/bash -p scripts/check-m1-gate.sh
```

Privileged Bash is part of the command: it prevents inherited shell functions
and `BASH_ENV` from interposing before the runner establishes its closed child
environment. A bound OTP launcher performs the one operation a shell runner
cannot perform without violating the immutable M0 gate: it replaces the child
environment while the shell leaves its search-path variable unchanged. The
runner catches mechanical accident and drift. Independent review still judges
whether tests assert what their names promise, mutations and process faults
were honestly injected, retained run fields are truthful, the closure documents
are current, and the working loop satisfies the Purpose.

This gate opens red because the product selectors do not exist. A checker,
evidence file, status row, or document alone cannot make it green.

## Read-Only Opening Condition

Before any temporary directory, dependency copy, Mix command, or product test,
the runner:

1. requires the exact privileged-Bash mode, disables tracing and automatic
   export, and privately captures only the provider key, supplied home,
   temporary-root input, installed Mix-prerequisite root, gate seed, and
   toolchain path;
2. resets aliases, hashing, options, glob controls, `IFS`, `CDPATH`, and umask;
   removes ambient mutable variables, leaves the shell search-path value and
   export attribute untouched, and resolves the absolute OTP `escript`
   executable beside the selected `erl`;
3. sends the private controls over a pipe—not argv, environment, a file, or
   retained output—to the digest-bound launcher, whose bootstrap environment
   contains only locale and crash-dump controls and no provider credential;
4. has the launcher clear every inherited environment entry for its child,
   install exactly the derived absolute toolchain `PATH`, `HOME=/`,
   `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`, and `GIT_OPTIONAL_LOCKS=0`, and start the
   same bound shell in its sealed-inner role; when the incoming path begins with
   M0's dynamically created absence directory, the outer shell admits it only
   after proving with builtins that the directory contains exactly the complete
   core plus any versioned interpreter stubs with M0's exact bytes and no entry
   capable of shadowing an allowed command, then retains it first in the sealed
   path; the inner shell removes only Bash-created ambient entries without
   assigning or changing the export attribute of `PATH`, then makes
   `/usr/bin/env` its first external child and requires the complete output to
   equal that allowlist plus the conventional `_=/usr/bin/env` entry;
5. keeps `ERL_CRASH_DUMP=/dev/null` and `ERL_CRASH_DUMP_SECONDS=0` in force for
   the launcher and every later BEAM child, resolves the actual account home
   through validated Bash account expansion, and requires the supplied home to
   have the same physical device/inode identity;
6. resolves the repository and every inherited task, toolchain, Mix, and
   temporary path outside the actual account's physical `~/.loopex`;
7. requires Darwin or Linux, proves the canonical locale resolves to the exact
   `UTF-8` charmap, selects a validated BSD or GNU `stat` dialect and a validated
   `shasum` or `sha256sum` dialect, records populated
   architecture and resource limits, and any capture lane's exact OS pairing;
   and
8. requires every protected selector as a tracked ordinary `100644` blob,
   every exact locked name, and each exact real-provider tag.

An invalid raw `execve` environment name is not an ordinary Bash identifier.
Bash releases either expose it during imported-name enumeration or retain it
only in the inherited environment. The outer shell or launcher refuses it
without reproducing the entry, and the sealed child never receives it. The gate
does not claim the bootstrap launcher itself never received an invalid raw
entry; it does prove the provider credential arrives only through the private
pipe and that no ambient entry survives into the sealed child. Invocation
through a non-privileged or hostile already-running shell is outside the
accepted command and fails.

At the accepted opening checkpoint the first missing selector is
`apps/loopex/test/runtime_test.exs`, producing exactly:

```text
M1 gate RED: no apps/loopex/test/runtime_test.exs; the outcome it proves does not exist yet
```

No write may move above that condition. The runner's bounded
`--environment-fixture` role executes the same environment, account-home,
repository, and physical-path preflight, then prints a second environment dump
and `M1 environment preflight OK`. It allocates no task root, invokes no Mix or
product selector, and can print neither `CAPTURE` nor `M1 gate GREEN`.

## Bound Artifacts

| SHA-256 | Path |
| --- | --- |
| `cff2458a835d5d8461d8b781c50ad7a7ec3c0f3f2e009c2754341463eae23cee` | `scripts/check-m1-gate.sh` |
| `d29358ad791436eefb677fc04077ddd720b521a77d3a8f708c11fd76db17e2ba` | `scripts/m1-gate-launcher.escript` |
| `954ff0e05521ac1b59e2438ba4e0f836f5137d44175eefdb85d509e3aa37aaa4` | `scripts/m1-exunit-runner.exs` |
| `0e67f7bec0edeb1296a64c9fecec9fa1486fe18f98154c2ca11fdf220abb23dc` | `scripts/m1-evidence-verifier.exs` |
| `1b9d41d083ace5f39ac9af0c289065d9eb52aea129d04c174b1acc63d33b6861` | `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` |
| `4592da35e4d1146a3618f34088d742cfa32d36ad0af7906c78bfbd118df81177` | `apps/loopex/test/m1_gate_evidence_test.exs` |
| `662ca1cd0838ca8f5689697181a04e0e137a07fd017e207c1689fb7941bec20b` | `apps/loopex/test/m1_exunit_runner_test.exs` |
| `36d86e989d39507b971c3be6726d300373ceebc2c80b2574a21fd2d32604d750` | `apps/loopex/test/deps_budget_test.exs` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

These are the complete M1-specific verdict machinery and its adversarial
corpora. The sealed inner shell verifies every delegated source/corpus digest
before loading candidate code. The gate document externally binds the outer
shell and launcher bootstrap entrypoints without pretending either can verify
itself before execution. The launcher is a narrow process boundary, not a second gate: it can
only clear and replace the child environment, convey private stdin, and return
the sealed shell's output and exact exit status. Retaining a structurally exact
incoming M0 absence root means the M1 environment boundary does not make the
M0 aggregate's retired interpreters available again merely to escape its
textual scan. A lookalike root, an incomplete stub set, changed stub bytes, a
special file, or an additional entry fails closed. Generic status, Markdown,
Git, JSON, and Matrix code remains
evolvable and is not part of the M1 trust root. Product selectors and Mix
projects are not byte-bound: their candidate bytes are bound historically by
the capture commit, while paths, roles, dependency direction, names, states,
counts, and results are checked structurally on every run.

## Repository Commands and Owned State

After every selector exists, and still before allocation, the runner verifies
the bound artifacts, the complete indexed project path set, and a wholly clean
source tree. The writable lane creates one physically resolved task root,
clones the exact candidate locally with hard links disabled, checks it out
detached, and executes every candidate byte from that owned checkout. Ignored
physical paths, source-worktree hard links, ambient repository metadata, and an
ambient `deps/` tree therefore cannot enter candidate execution.

The bound dependency source is invoked directly with `elixir -r ...
Loopex.Checks.DepsBudget.main/1` before Mix evaluates the owned checkout. It
requires the physical umbrella project set to equal the stage-zero candidate
inventory, checks the role graph, and cannot be replaced by a Mix alias or local
task. Later Mix project/config execution is trusted candidate code and remains
an independent-review boundary; literal locked-command aliases are refused as
defense in depth, not described as exhaustive proof against executable task
creation.

The task root owns `HOME`, `LOOPEX_HOME`, workspace, `TMPDIR`, `MIX_HOME`,
`HEX_HOME`, build, dependency, Rebar-cache, and candidate-checkout paths. Hex is
offline. Dependency source is reconstructed without Mix, Hex, or network access
from the exact installed package archives named and checksum-bound by the
candidate's literal `mix.lock`; missing, malformed, special, redirected, extra,
checksum-mismatched, or protected-identity package input fails, and each archive
keeps one physical identity across its checksum-bound read. Installed `hex-*`
tooling and the per-Elixir Rebar subtree are separately copied as build-tool prerequisites.
Every copied source root and descendant is an ordinary file/directory with no
symlink. The complete resolved closure of generated development and test build
trees may retain links only within the task root; cycles are identity-bounded,
and every reachable regular file is compared with protected user state.
Executable `ebin` directories are link-free when loaded. Validation and
adjacent use assume no hostile concurrent source replacement; the gate claims
no filesystem handle or cross-process serialization.

Every command below must exit zero. `CAPTURE` omits only matrix-record
validation; ordinary mode runs it too.

| # | Command | Locked obligation |
| --- | --- | --- |
| 1 | direct bound `Loopex.Checks.DepsBudget.main/1` over the complete project inventory, then its `--materialize` role | Pre-Mix application identity, role, lock-backed dependency authority, locked aliases, and offline package reconstruction |
| 2 | `mix loopex.format_scope` | Effective formatting includes every application source |
| 3 | `mix format --check-formatted` | Formatting is clean |
| 4 | `mix compile --warnings-as-errors` | Default build is warning-free |
| 5 | `MIX_ENV=test mix compile --warnings-as-errors` | A clean isolated test build exists before standalone selectors |
| 6 | `mix loopex.version_train` | All applications carry one version |
| 7 | `elixir scripts/m1-evidence-verifier.exs --pair --root <root>` | The VM is exactly the floor or current locked pair |
| 8 | bound evidence verifier with matrix and negative roles (ordinary), or negative role only (`CAPTURE`) | Canonical M1 evidence and lifecycle, or its non-self-referential capture subset, holds |
| 9 | no-argument `mix loopex.matrix` | Closed M0 matrix behavior remains intact; it is not M1 evidence |
| 10 | `mix loopex.core_only` | Core remains stdlib/OTP-only and adapter-free |
| 11 | `mix loopex.docs_check` | Covered public code orders Concept before Technical depth |
| 12 | `mix loopex.hook_registration` | Retained hooks keep required event/matcher registration |
| 13 | `mix loopex.status` | Live governance, indexes, links, and current lifecycle state validate |
| 14 | `bash scripts/check-bootstrap.sh` | The portable aggregate remains green |
| 15 | the three bound mechanics selectors through the standalone channel | Every locked adversarial gate, selector-runner, and dependency case executes |
| 16 | the eight protected logical Outcomes through the standalone channel | Exact names/states and minima below hold |
| 17 | `MIX_ENV=test mix test --exclude real_provider --seed <gate-seed>` | The complete credential-free suite passes with the same seed |

One canonical decimal integer seed from `0` through `999999` covers all protected roles and the
final suite. The final ordinary line is exactly:

```text
M1 gate GREEN seed=<N> protected_executed=<M>
```

`protected_executed` sums executed deterministic and real-role cases assigned
to Outcomes 1–8. Excluded tests never count. Mechanics, bootstrap,
default-exclusion-only controls, and the final full suite do not count.

## Dynamic Dependency Authority

The bound `Loopex.Checks.DepsBudget` parser reads only the literal project data
that carries authority. The root must declare the umbrella `apps_path`, no
application role, no dependency, and no alias for a locked command. The
physical and stage-zero child-project sets must agree exactly and be a subset of
the six named M1 applications: `loopex_protocol`, `loopex`,
`loopex_store_local`, `loopex_llm_reqllm`, `loopex_executor_local`, and
`loopex_reference_client`. Core and protocol are always required; the protected
selector inventory requires the other four before the gate can turn green. No
seventh application is admitted. Every child declares one directory-matching
application, one literal `loopex_role`, literal unique dependency records,
closed internal dependency options, literal owned `elixirc_paths`/`erlc_paths`,
and no locked-command alias.

The accepted opening inventory is intentionally incomplete. Until all six
planned identities exist, only the existing `loopex_llm_reqllm` edge may retain
its inherited M0 internal shape: one production protocol dependency and no core
dependency. All other present applications already obey their final rule. Once
the inventory is complete—as every green candidate must be because the
protected selectors require all six—the ReqLLM edge must also carry its one
production core dependency. No other opening-stage exception exists.
Every existing compile source is a tracked ordinary blob beneath its owning
application; the umbrella root owns no application source. Unrelated project
metadata, helpers, `application/0`, test/docs paths, compiler settings other
than compile roots, and ordinary aliases remain allowed.

The six applications have exact roles: protocol is `:contract`, core is
`:core`, Store/model/Executor are `:edge`, and the reference client is
`:client`:

- contract carries no dependency;
- core depends in production only on `:loopex_protocol`;
- a complete-inventory edge depends in production on `:loopex` and may also
  depend on protocol;
- only `loopex_llm_reqllm` carries a direct external dependency, exactly
  `{:req_llm, "~> 1.17.1"}`;
- client depends in production on core and may compose concrete edge apps only
  in tests; and
- no extension application or other direct external dependency is M1 scope.

Every in-umbrella name must resolve to the discovered inventory. The one direct
external requirement has no source options and resolves to an exact canonical
Hex entry in `mix.lock`. The offline materializer derives its complete required
non-optional transitive closure, refuses missing, unsatisfied, or unreachable
lock records, and accepts only checksum-bound archives whose literal Erlang
`metadata.config` name, version, build tools, and dependencies exactly match the
lock. Every Mix-managed package carries exactly one Elixir requirement that
admits the bound 1.17.0 floor; another build tool may omit it, but any present
requirement must admit the floor. All authority is validated before the
destination is touched. The materializer creates Hex SCM's `.hex` marker only
from the verified lock checksums and metadata; an archive payload carrying that
marker is refused. Duplicate or unknown identities/dependencies,
nonliteral authority fields, alternate SCM/path sources, and reverse, outward, sibling,
redirected-source, or wrong-environment edges fail. M1 contract compiler input
is explicitly Elixir-only: Erlang headers and Erlang/generated-source forms are
refused rather than incompletely scanned. The Elixir scan covers all declared
roots, permits its owned `Loopex.Protocol.*` namespace in normal, explicit-root,
and literal-atom forms, rejects every other static `Loopex.*` form, and rejects
unambiguous computed dispatch (`apply/3`, parenthesized dynamic calls, and named
captures). Elixir's no-parentheses field-access AST is admitted; the deprecated
computed-module spelling with the identical AST remains inside the recorded
arbitrary-computed-identity review boundary. Executable Mix task creation is
also a trusted-candidate review boundary, not a claim of exhaustive textual
detection. Before each selector, the
same source emits its owner, complete internal-app set, and allowed transitive
internal closure. The standalone runner refuses an owner mismatch or a compiled
`.app` edge to an internal sibling outside that source-derived closure; an
undeclared sibling cannot become reachable merely because its beam exists.

## Authoritative ExUnit Channel

Every protected selector runs by invoking the bound script directly, never a
Mix test task or alias:

```text
elixir scripts/m1-exunit-runner.exs --loopex-m1-selector [--only-real-provider] <root> <test-build> <selector> <owner> <internal-csv> <allowed-csv> <seed> <minimum> <zero|positive> <state=name>...
```

The default role receives exactly a random 32-lowercase-hex nonce plus LF on
stdin. A real-only role receives that nonce and LF followed by the nonempty,
NUL-free provider key as raw bytes to EOF. The key appears in neither argv nor
the inherited environment. The script consumes stdin before candidate startup,
requires the selector to be a tracked ordinary `100644` file under
`apps/<owner>/test/`, verifies the compiled owner and source-derived dependency
closure, adds only link-free closure `ebin` paths, and starts that application
without compilation or `test_helper.exs`. Startup is credential-free. Only the
real role then sets the canonical key inside that VM for selector execution and
deletes it before result validation.

The script starts/configures ExUnit itself with `autorun: false`, one owned
formatter, the gate seed, `dry_run: false`, zero repeat-until-failure, no
`only_test_ids`, infinite max failures, no failures manifest, and exact role
filters. Official `ExUnit.RunnerStats` supplies totals, failures, skips, and
exclusions, including module/setup failure effects. Formatter events bind each
test to the exact selector, name, and state. Missing/duplicate names, wrong
states, foreign files, unknown/duplicate events, incomplete suite events,
unaccounted exclusions, skips, failures, or a count below the role minimum fail.

After in-memory validation the script forces a new stdout record boundary,
prints exactly one nonce-bound marker with selector, seed, executed count, and
deterministic report digest, then hard-halts. Arbitrary stdout is diagnostic,
not authority. A fake summary or marker, partial-line output, `System.at_exit`
callback, early halt, missing/extra marker, or nonzero process status cannot
satisfy the shell. Candidate code is trusted and independently reviewed; this
channel prevents accidental/interposed reporting and does not claim to sandbox
hostile same-VM test code.

## Protected Outcome Selectors

All unqualified roles require zero failures, skips, and exclusions. A split
default role records the exact real test excluded; a real-only role records the
exact deterministic names excluded. The authoritative exclusion total must
equal the named excluded identities.

| Outcome | Selector / role | Minimum | Locked names and required states |
| --- | --- | --- | --- |
| 1 | `apps/loopex/test/runtime_test.exs` / default | 3 | passed: `two runtimes coexist without a global name`; `a runtime reference is required rather than inferred`; `a supervised runtime starts and stops with explicit configuration` |
| 2 | `apps/loopex/test/session_lifecycle_test.exs` / default | 6 | passed: `session creation atomically records its runtime command mapping and genesis re-presents identical bytes idempotently and conflicts on changed bytes`; `initial and resumed coordinators commit advance_owner before admitting commands`; `a superseded owner cannot newly commit or use a delayed result to update cache publish dispatch or authorize`; `declared injected and observed transition and fault point pairs are equal`; `a prompt cannot start a second active run`; `only one coordinator owns a session at a time after durable succession` |
| 3 | `apps/loopex_store_local/test/store_conformance_test.exs` / default | 5 | passed: `every implementation atomically refuses a stale owner epoch incarnation and version`; `a killed writer loses no acknowledged fact`; `replay audits durable truth but grants no write authority`; `known transactions return their retained resolution without a second mutation`; `the durable local store survives process death with consecutive store-stamped history` |
| 4 | `apps/loopex/test/embedded_api_test.exs` / default | 4 | passed: `progress and diagnostics never carry durable truth`; `committed events survive delivery with stable identity`; `attachment snapshots at N and streams events after N without a gap`; `a full attachment queue disconnects with a durable-history cursor and resumes gap-free after runtime restart without persisted attachment state` |
| 5a | `apps/loopex_llm_reqllm/test/real_model_lane_test.exs` / adapter-default | 1 | passed: `deterministic and ReqLLM adapters satisfy one model conformance suite` |
| 5b | `apps/loopex_reference_client/test/real_model_session_test.exs` / session-default | 1 | passed: `model dispatch receives only the committed canonical request bytes and digest`; excluded: `one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session` |
| 5c | same file / session-real | 1 | excluded: the deterministic session name; passed: the real session name above |
| 6 | `apps/loopex_executor_local/test/executor_test.exs` / default | 6 | passed: `required grant bindings equal the independent contract oracle`; `each missing and wrong grant binding is refused before process start`; `only an explicit host-policy allow decision can issue or widen a grant`; `the executor recomputes the canonical JobRequest digest and the receipt retains verified origin identity`; `the workspace lease is held for the job lifetime and loss kills owned work with retained evidence`; `the executor starts one credential-free OS tool that writes the expected workspace bytes and retains its receipt` |
| 7 | `apps/loopex_reference_client/test/reference_client_test.exs` / default | 2 | passed: `the client drives the loop through the embedded API only`; `the reference client owns no policy durable state or alternate loop` |
| 8a | `apps/loopex_reference_client/test/end_to_end_recovery_test.exs` / default | 5 | excluded: the real trace below; passed: `reconciliation schema covers the independent recovery contract oracle`; `exactly one dispatch ever carried each effect across the restart`; `an effect without a durable receipt becomes outcome_unknown and is not blindly retried`; `every acknowledged fact survives the restart`; `each wrong reconciliation and receipt identity is refused` |
| 8b | same file / real-only | 1 | passed: `one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call`; excluded: the five deterministic names above |

Outcome 3's shared transaction cases run against in-memory and durable-local
stores; persistence, restart, replay, and storage-fault claims apply only to the
durable implementation. Outcome 5's real session test itself proves the
production adapter received the exact already-committed canonical bytes/digest
and completed. Outcome 8's one real trace itself proves forced real-tool
selection, a credential-free child, durable receipt, untrappable process-tree
kill before fact, current reconciliation, one dispatch/effect, fact survival,
a second real call, and terminal continuation. Deterministic cases support but
never substitute for those real assertions.

## Locked Mechanics Selectors

The mechanics files are themselves bound above. Every listed test must be
reported passed by the authoritative channel.

`apps/loopex/test/m1_gate_evidence_test.exs`, minimum 10:

- `M1 pair verifier derives only the exact running locked pair`
- `M1 evidence verifier requires one exact capture and inherited M0 proof per locked lane`
- `M1 evidence verifier binds source evidence and closure transition ancestry`
- `M1 evidence verifier binds each negative mechanism to committed and restored bytes`
- `the environment preflight removes credential aliases and unrelated ambient state`
- `the read-only prefix disables optional Git locks before repository inspection`
- `the user-state fingerprint includes every entry identity and a command-line symlink target root`
- `prerequisite copies refuse protected-state hard links and symlinks`
- `platform filesystem identity and SHA-256 select validated dialects`
- `owned candidate and generated closures exclude ambient aliases`

`apps/loopex/test/m1_exunit_runner_test.exs`, minimum 5:

- `the standalone selector grammar admits every planned owner and rejects foreign paths`
- `the standalone runner requires one tracked ordinary selector owned by its compiled app`
- `official counts and exact events refuse failures skips exclusions and missing names`
- `fake stdout at_exit and early halt cannot manufacture one authoritative result`
- `only the declared internal dependency closure is reachable and startup never receives the provider key`

`apps/loopex/test/deps_budget_test.exs`, minimum 25:

- `the repository satisfies the dependency budget and direction`
- `a forbidden core dependency is rejected`
- `an extension may carry external dependencies but not the runtime`
- `dependency identity and role come only from the canonical project declaration`
- `internal dependencies cannot redirect canonical umbrella source ownership`
- `compiled source roots remain inside their owning application`
- `duplicate dependency names are rejected`
- `the tracked inventory is dynamic and includes its ordinary root`
- `the dynamic inventory cannot omit the fixed contract or core`
- `unrelated project metadata helpers application data and ordinary aliases are permitted`
- `root and child aliases may not interpose on locked commands`
- `M1 planned applications accept only their declared dependency shapes`
- `dependency context separates discovered apps from the selector's declared closure`
- `each role rejects an adjacent outward or wrong-environment edge`
- `child identity must match its directory and decoys cannot supply it`
- `an extra guarded project clause cannot hide behind one literal clause`
- `the bound dependency verdict bypasses evaluated Mix tasks`
- `offline materializer proves the exact floor-compatible lock closure`
- `the contract protocol namespace is not a runtime reverse edge`
- `static runtime references outside the protocol namespace are rejected`
- `a reverse edge from contract to runtime is rejected` (retained M0 identity)
- `dynamic module dispatch is rejected independent of formatting`
- `a dynamic module reference across the boundary is rejected` (retained M0 identity)
- `plain module-like data is not treated as an executable reference`
- `all declared contract compile roots receive reverse-edge checks`

## Toolchain Capture and Retained Matrix

The three bound non-gate commands are:

```text
# Darwin, exact floor pair
mise exec erlang@26.0 elixir@1.17.0-otp-26 -- /bin/bash -p scripts/check-m1-gate.sh --capture floor
# Darwin, exact current pair
/bin/bash -p scripts/check-m1-gate.sh --capture current
# Linux, exact current pair
/bin/bash -p scripts/check-m1-gate.sh --capture linux-current
```

All three run from the same clean committed source candidate `C`, each with a
fresh, disjoint owned task root. They run the complete M1 command set except
matrix validation, validate negative evidence, and emit one `capture ...
verdict=CAPTURE exit=0` record carrying the successful real role's observed
identity only after success. They never recursively invoke the gate, never print
GREEN, and are not merge evidence. Pair order and adjacency are inert. The
runner itself requires `floor` and `current` on Darwin and `linux-current` on
Linux, and requires the exact floor/current VM appropriate to each lane.

The operator separately runs `bash scripts/check-m0-gate.sh` once under the
floor pair and once under the current pair against the same `C`. Each process's
stdout/stderr is captured before diagnostic display and provider bytes are
redacted in-process. Bootstrap does not substitute for either run, and M1 never
nests M0.

The same two exact commands must already have exited zero against the clean
opening candidate before M1 Acceptance is recorded. Those pre-acceptance runs
are review evidence only and are not committed into this gate, the matrix, or
another candidate input. A new acceptance candidate invalidates them. This
keeps the opening runner read-only and truthfully red without postponing the
green-base invariant until implementation or closure.

`docs/evidence/M1-toolchain-matrix.md` is exactly one title, the
`loopex:m1-matrix` markers, one `text` fence, and these six lines in order:

```text
matrix candidate=<C> gate_sha256=<digest> runner_sha256=<digest> launcher_sha256=<digest> exunit_runner_sha256=<digest> deps_budget_sha256=<digest> verifier_sha256=<digest> tool_versions_sha256=<digest> command=bash-p:scripts/check-m1-gate.sh
capture lane=floor candidate=<C> gate_sha256=<M1 digest> command=bash-p:scripts/check-m1-gate.sh elixir=1.17.0 otp=26.0 erts=<exact> seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 wall=<ASCII-token> os=darwin arch=<ASCII-token> limits=nofile-<positive|unlimited>,nproc-<positive|unlimited> provider=<ASCII-token> model=<ASCII-token> endpoint=<ASCII-token> adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=<ASCII-token> tool_identity=<ASCII-token> recorded=<UTC-RFC3339-second>
capture lane=current candidate=<C> gate_sha256=<M1 digest> command=bash-p:scripts/check-m1-gate.sh elixir=1.20.3 otp=29.0.5 erts=<exact> seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 wall=<ASCII-token> os=darwin arch=<independent-ASCII-token> limits=nofile-<positive|unlimited>,nproc-<positive|unlimited> provider=<same> model=<same> endpoint=<same> adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=<same> tool_identity=<same> recorded=<UTC-RFC3339-second>
capture lane=linux-current candidate=<C> gate_sha256=<M1 digest> command=bash-p:scripts/check-m1-gate.sh elixir=1.20.3 otp=29.0.5 erts=<exact> seed=<0..999999> executed=<positive> verdict=CAPTURE exit=0 wall=<ASCII-token> os=linux arch=<independent-ASCII-token> limits=nofile-<positive|unlimited>,nproc-<positive|unlimited> provider=<same> model=<same> endpoint=<same> adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=<same> tool_identity=<same> recorded=<UTC-RFC3339-second>
m0 lane=floor candidate=<C> gate_sha256=<M0 digest> command=bash:scripts/check-m0-gate.sh elixir=1.17.0 otp=26.0 provider=<nonsecret> model=<nonsecret> endpoint=<nonsecret> verdict=GREEN exit=0
m0 lane=current candidate=<C> gate_sha256=<M0 digest> command=bash:scripts/check-m0-gate.sh elixir=1.20.3 otp=29.0.5 provider=<nonsecret> model=<nonsecret> endpoint=<nonsecret> verdict=GREEN exit=0
```

The self-contained bound verifier checks exact grammar/cardinality, pair and
command identity, numeric fields, all seven M1 metadata digests against both `C`
and the current bytes, all three capture rows' exact OS/toolchain and
runtime-bound real-path identities, independently valid architecture and limits,
identity equality across lanes except for observation time, the immutable M0
gate digest against `C` and current bytes, and the two exact M0 lane rows.
Retained audit tokens are printable ASCII, so Unicode lookalikes or direction
controls cannot change what a reviewer sees. The verifier does not import
generic Matrix or status parsers. No-argument `mix loopex.matrix` remains the
inherited M0 check. Review cross-checks OS, architecture, limits,
provider/model/endpoint, adapter/executor/tool identity, seed, count, timing,
and execution truth against the retained process output and test assertions.

The matrix is committed alone as evidence commit `E`, the direct one-parent
child of `C`; every other tree byte is identical, and the current matrix equals
`E`. Ordinary gates run at `E` on Darwin floor/current and Linux current. Any
open descendant of `E` is invalid.

The unique first commit completing M1 Closure is transition `T`, the direct
one-parent child of `E`. `E→T` changes exactly `docs/plans/M1.md`,
`docs/plans/README.md`, and `README.md`: only the empty Closure row and canonical
marked status blocks change, Acceptance remains unchanged, and Closure binds
reviewed candidate `E` and the M1 gate digest. An interposed commit, merge,
parallel first-completion branch, bundled product/evidence byte, wrong binding,
or edit outside those bytes fails. Later descendants pass only while `E` and
`T` remain reachable and the retained matrix and Closure row remain
byte-identical. `mix loopex.status` independently checks live semantic
governance; independent transition review remains mandatory.

## Negative Demonstrations

`docs/evidence/M1-negative-demonstrations.md` has one exact title and five exact
ordered sections, each containing one one-line JSON object in its own `json`
fence and no other line:

1. Outcome 2 / `current_owner_post_commit_fence` /
   `apps/loopex/test/session_lifecycle_test.exs`
2. Outcome 3 / `store_atomic_admission_compare` /
   `apps/loopex_store_local/test/store_conformance_test.exs`
3. Outcome 3 / `commit_unknown_dispatch_fence` /
   `apps/loopex_store_local/test/store_conformance_test.exs`
4. Outcome 6 / `executor_final_prestart_validation` /
   `apps/loopex_executor_local/test/executor_test.exs`
5. Outcome 8 / `no_blind_retry_without_receipt` /
   `apps/loopex_reference_client/test/end_to_end_recovery_test.exs`

The exact key order is:

```json
{"mechanism_disabled":"<exact ID>","selector":"<exact selector>","observed_failure":"<nonempty printable ASCII>","candidate":"<40 lowercase hex>","artifact":"<safe tracked path>","restored_sha256":"sha256:<64 lowercase hex>"}
```

The verifier rejects any other skeleton, JSON encoding, key order/set,
mechanism/selector pairing, unsafe path, unreachable candidate, or digest. The
candidate blob and current tracked ordinary artifact bytes must both equal the
recorded restored digest. The shell separately requires the whole tree clean
before and after. Machines prove structure and restoration identity; review
proves one clean-baseline mechanism was disabled and caused the named failure.

## Credential and Provider Boundary

The structural child-environment allowlist removes ambient credential aliases,
proxy values, client state, and unrelated exported secrets even when the
canonical key is absent. The key remains in one private outer-runner holder and
is sent only to real-only selector VMs through stdin after their nonce. It is
never an argv field, inherited child-environment entry, fixture, evidence field,
or crash dump. Credential-free roles, compilation, repository commands, and the
full suite never receive the canonical key.

Provider stdout/stderr is captured. On failure the outer Bash removes every
literal occurrence in-process, proves the bytes absent, and otherwise emits only
a fixed suppressed diagnostic; successful provider output is not printed.
Outcome 6 separately requires its controlled OS tool to receive an explicit
credential-free environment, and Outcome 8 repeats that assertion in the real
trace. This is containment at the runner and product boundaries, not semantic
taint tracking through trusted provider code.

The standalone runner exposes one test-only real-path reporter. The exact tagged
model role must submit one provider/model/endpoint/adapter-build observation;
the combined recovery role must submit one observation that adds executor
build, executor runtime identity, and tool identity. No report, more than one,
the wrong profile, a placeholder, or a non-ASCII value refuses the selector.
The runner adds the UTC observation time and seals the fields into its
nonce-bound authoritative result digest. The outer gate requires the two real
roles to agree on their shared fields and copies only the combined observation
into that lane's `capture` record. Candidate `C` plus each fixed
application/version is the exact adapter and executor build identity.

Candidate tests remain trusted: they could report a value they did not actually
observe. The gate makes that assertion visible and run-bound; independent
review still verifies that each real test obtains the report fields from the
adapter response, executor receipt, and controlled tool after the named
operation. Static source prose or a pre-authored evidence file cannot satisfy
this obligation.

## Durable Fault and Truth Evidence

Session creation is a catalogued runtime-control Store transaction: session-ID
allocation, `(runtime_id, command_id)` resolution/mapping, and genesis commit
atomically before acknowledgement; identical canonical re-presentation returns
the same ID and changed bytes conflict. Initial and resumed coordinators commit
ADR 0006 `advance_owner` before admitting a command. The exact
`{transition_id, fault_point_id}` sets declared by production, injected by the
fault harness, and observed by tests must be equal across runtime creation and
session mutations. Outcome 8 separately proves that an effect which may have
occurred without a durable receipt becomes immutable `outcome_unknown` and is
never blindly retried.

## User-State Containment

Physical resolution, not string spelling, protects actual `~/.loopex`.
Relative paths, `..`, dangling links, link chains, case aliases, and
device/inode aliases fail closed when they enter protected state. Missing
identity is unavailable evidence, not outside. Tool executables and every
copied/traversed prerequisite root and descendant are checked before use. One
validated BSD or GNU `stat` dialect supplies every physical identity and mode;
one validated `shasum` or `sha256sum` dialect supplies every content digest.
Output from a failed or malformed dialect cannot contaminate a fallback. The first
protected-state inventory records every regular-file device/inode. The exact
candidate executes from a non-hardlinked owned checkout, copied sources are
intersected with protected identities, and the complete resolved link closure
of both generated build trees is identity-checked, so an ignored path,
source-worktree hard link, nested generated link, or external hard-link spelling
cannot expose a protected file.

Defense in depth fingerprints real user state before and after with an
injective NUL-framed record containing each entry path, type, mode,
device/inode, link-target or regular-content digest, plus a resolved root-target
record when `~/.loopex` itself is a symlink. The first fingerprint follows owned
task-root allocation but precedes prerequisite inventory and copying. Source
inventories never follow symlinks; retained matrix and closure documents must be
tracked ordinary files. Containment is the primary control; the fingerprint
detects drift and does not substitute for relocation.

## Closure Document Set

Every path below must exist before green. Review, not existence alone, proves
freshness and completeness.

```text
CHANGELOG.md
README.md
DEVELOPMENT.md
docs/plans/README.md
docs/plans/M1.md
docs/evidence/M1-toolchain-matrix.md
docs/evidence/M1-negative-demonstrations.md
docs/evidence/README.md
docs/developer/agent-context-map.md
```

`CAPTURE` may omit only the matrix path it is about to populate.

## Failure Rules and Declared Red

A required red blocks closure. Missing/unparsable evidence or credentials are
unavailable, never PASS. Never skip, filter, soften, quarantine, rewrite,
inflate a retry/timeout, or replace a real provider, store, executor, process
kill, or restart with a fake. A same-SHA/seed/environment failure that vanishes
on retry is a blocking flake until fixed or explicitly dispositioned.

The gate becomes green only when one embedded caller crosses one runtime
contract through a committed real-model request and credential-free controlled
OS tool, observes durable public events, survives an OS-process-tree kill after
a retained receipt, reconciles without redispatch, makes a second real call,
and reaches a durable terminal result.
