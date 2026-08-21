# M1 Gate

Executable acceptance for `M1`. This file is the lock: its canonical UTF-8/LF
bytes and SHA-256 digest are bound with the accepted plan pair and stay immutable
for the milestone. Conforming progress and retained evidence are not part of the
lock.

The runner is `bash scripts/check-m1-gate.sh`. It catches mechanical accident and
drift. It cannot decide whether a test asserts what its name promises, whether a
fault was honestly injected, whether retained run prose is truthful, or whether
the resulting loop satisfies the Purpose. Independent closure review owns those
judgments.

This gate opens red because the product selectors do not exist. It may not become
green through a checker, evidence file, registry, or document alone.

## Read-Only Opening Condition

Before any temporary directory, dependency copy, or Mix invocation, the runner:

1. disables shell tracing, removes `LOOPEX_PROVIDER_API_KEY` from the environment,
   and proves both it and the non-exported holding variable are absent from a
   checked child environment; it also exports and verifies
   `GIT_OPTIONAL_LOCKS=0` before any Git child so inspection cannot refresh the
   index;
2. resolves and enters the repository root with checked command status;
3. requires every protected selector and every exact locked test name; and
4. once those product bytes exist, requires a clean whole tree before allocation.

At the opening checkpoint the first missing selector is
`apps/loopex/test/runtime_test.exs`, producing exactly:

```text
M1 gate RED: no apps/loopex/test/runtime_test.exs; the outcome it proves does not exist yet
```

The physical user-state alias checks below also run before allocation once the
selectors exist. No write may move above this boundary.

## Bound Artifacts

| SHA-256 | Path |
| --- | --- |
| `dbf4beb0323d509185479fcd1fce9fdf3519c3a0432b61d54d032af140dada6f` | `scripts/check-m1-gate.sh` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

`.tool-versions` carries ADR 0002 forward unchanged. On every run that passes
the opening preflight, `mix loopex.status` compares these paths with the declared
digests and the lifecycle history. A byte change changes this gate candidate and
invalidates evidence or review taken against its prior bytes.

## Locked Repository Commands

The runner invokes every command below. Each must exit zero.

| # | Command | Mechanical obligation |
| --- | --- | --- |
| 1 | `mix loopex.format_scope` | The effective formatter covers application sources |
| 2 | `mix format --check-formatted` | The checkout is formatting-clean |
| 3 | `mix compile --warnings-as-errors` | Compilation is warning-free |
| 4 | `mix loopex.deps_budget` | Dependency budget and direction hold; core stays stdlib and OTP only |
| 5 | `mix loopex.version_train` | Every application carries one version |
| 6 | `mix loopex.matrix --evidence docs/evidence/M1-toolchain-matrix.md --profile m1` | The running pair is exact and M1's retained five-run matrix has all four adjacencies |
| 7 | `mix loopex.core_only` | Core builds and starts against its declared inward dependency set with no adapter resolved or started |
| 8 | `mix loopex.docs_check` | Covered public code orders Concept before Technical depth |
| 9 | `mix loopex.hook_registration` | Every retained client hook is registered under its required event and matcher |
| 10 | `mix loopex.status` | Project status, governance, indexes, links, gate locks, and bound artifacts validate |
| 11 | `bash scripts/check-bootstrap.sh` | The portable repository aggregate is green |
| 12 | `mix test apps/loopex/test/m1_gate_evidence_test.exs` | The M1 evidence readers reject their locked adversarial corpus |
| 13 | `mix loopex.m1_evidence` | Outcomes 2, 3, 6, and 8 carry structurally valid, byte-restored negative demonstrations |
| 14 | `mix test` | The ordinary credential-free full suite passes |

The runner gives its build, dependency-source copy, Rebar cache, `HOME`,
`LOOPEX_HOME`, and workspace a per-run isolated root. It never fetches a missing
dependency; ordinary Mix failure reports unavailable prerequisites.

## Protected Outcome Selectors

Every selector runs with the stated minimum count. Its source must contain every
locked name exactly, and the run must report zero skipped and zero excluded tests.
Thus a present locked test cannot be hidden by a tag while unrelated cases meet
the aggregate minimum.

| Outcome | Selector | Minimum | Locked names |
| --- | --- | --- | --- |
| 1 | `mix test apps/loopex/test/runtime_test.exs` | 3 | `two runtimes coexist without a global name`; `a runtime reference is required rather than inferred` |
| 2 | `mix test apps/loopex/test/session_lifecycle_test.exs` | 5 | `a session resumes with the durable truth it committed`; `a superseded owner cannot newly commit or use a delayed result to update cache publish dispatch or authorize`; `the durable transition catalogue is completely fault injected`; `a prompt cannot start a second active run` |
| 3 | `mix test apps/loopex/test/store_conformance_test.exs` | 5 | `every implementation atomically refuses a stale owner epoch incarnation and version`; `a killed writer loses no acknowledged fact`; `replay audits durable truth but grants no write authority` |
| 4 | `mix test apps/loopex/test/embedded_api_test.exs` | 4 | `progress and diagnostics never carry durable truth`; `committed events survive delivery with stable identity`; `attachment snapshots at N and streams events after N without a gap`; `a slow subscriber cannot block session commits or grow coordinator memory without bound` |
| 5 | `mix test apps/loopex/test/real_model_lane_test.exs --include real_provider` | 3 | `deterministic and ReqLLM adapters satisfy one model conformance suite`; `model dispatch receives only the committed canonical request bytes and digest`; `one real non-streaming model call completes inside a session` |
| 6 | `mix test apps/loopex/test/executor_test.exs` | 6 | `required grant bindings equal the independent contract oracle`; `each missing and wrong grant binding is refused before process start`; `only an explicit host-policy allow decision can issue or widen a grant`; `the executor recomputes the canonical JobRequest digest and the receipt retains verified origin identity`; `the workspace lease is held for the job lifetime and loss kills owned work with retained evidence`; `one controlled tool executes and commits its effect` |
| 7 | `mix test apps/loopex/test/reference_client_test.exs` | 2 | `the client drives the loop through the embedded API only` |
| 8 | `mix test apps/loopex/test/end_to_end_recovery_test.exs --include real_provider` | 5 | `one vertical loop survives an OS-process kill and continues through a second real model call`; `exactly one dispatch ever carried each effect across the restart`; `an effect without a durable receipt becomes outcome_unknown and is not blindly retried`; `every acknowledged fact survives the restart`; `each wrong reconciliation and receipt identity is refused` |

Outcome 3's reusable suite covers the shared transaction semantics against both
the in-memory and durable-local implementations. Restart durability and storage
fault injection apply to the durable-local implementation; the gate makes no
durability claim for the in-memory implementation.

The gate-mechanics selector has minimum 8 and locks these names:

- `the no-argument M0 record remains the default and M1 never falls back to it`
- `matrix command refuses partial unknown and ambiguous explicit arguments`
- `M1 matrix requires the five-run walk covering all four adjacencies`
- `M1 matrix metadata binds the reachable candidate current gate command platform and limits`
- `negative evidence binds one visible JSON record per constitutional outcome`
- `negative evidence requires both the committed and current blob to equal the digest`
- `the read-only prefix disables optional Git locks before repository inspection`
- `the user-state fingerprint includes a command-line symlink target root`

## Toolchain Matrix

One Mix process observes one toolchain. Both ADR 0002 pairs therefore run this
whole runner, and `docs/evidence/M1-toolchain-matrix.md` retains exactly one
metadata line followed by exactly five run lines inside its governed verbatim
fence. The metadata form is:

```text
matrix candidate=<40 lowercase hex> gate_sha256=<64 lowercase hex> command=bash:scripts/check-m1-gate.sh platform=<printable token> limits=<printable token>
```

The candidate must be a reachable commit ancestor of `HEAD`. Its committed
`docs/plans/M1-gate.md` blob, the current gate bytes, and `gate_sha256` must all
agree, so an arbitrary pre-gate ancestor cannot be labelled as the run source.
The command identifier maps to the exact command
`bash scripts/check-m1-gate.sh`. Platform and limits are required printable
audit fields whose truthfulness remains review work.

Each run has this exact field order:

```text
run=<N> order=<ordinal> elixir=<exact> otp=<exact> erts=<retained> seed=<digits> executed=<positive integer> verdict=GREEN exit=0 wall=<retained>
```

The `run` fields are `1` through `5`, the `order` fields are `first` through
`fifth`, every row names one exact locked pair, and their four adjacent edges are
exactly:

```text
floor -> floor
floor -> current
current -> floor
current -> current
```

The five lines are a minimal walk; an extra run is not silently ignored. The
explicit `--evidence` path and `--profile m1` prevent M0's closed record from
standing in for M1. With no arguments `mix loopex.matrix` retains its unchanged
M0 behavior.

The task proves exact record structure, referential candidate/gate/command
identity, exact pair identity, numeric seed/count fields, green/zero verdicts,
and the adjacency set. It cannot prove the recorded processes ran or that the
platform, limits, counts, seed, or timing values are truthful; review compares
those claims with independent runs.

## Real-Provider Lanes and Credential Boundary

The provider key is removed before the first child and retained only in a
non-exported shell variable. It is injected through an environment assignment
only into these two captured Mix commands:

```text
mix test apps/loopex/test/real_model_lane_test.exs --include real_provider
mix test apps/loopex/test/end_to_end_recovery_test.exs --include real_provider
```

The first must execute at least three tests. The second must execute at least five,
combining the deterministic recovery cases with the real-provider vertical case.
Both exact real-path tests carry `@tag :real_provider` on the preceding nonblank
source line, and the runtime application's test helper must contain the exact
default exclusion `ExUnit.start(exclude: [:real_provider])`.
Separate unfiltered runs prove the model file executes at least two deterministic
cases and excludes at least one, while the recovery file executes at least four deterministic cases
and excludes at least one. The final full suite has neither credential name in
its environment.

Provider failures are captured and literal credential bytes are replaced inside
the runner shell before diagnostic output is printed. This proves environment,
argv, default-lane, and runner-output containment. Whether product code copies a
credential into another plane remains a code-and-evidence review obligation; the
runner does not claim semantic taint tracking.

`docs/evidence/M1-provider.md` records exactly one populated line for each of
`provider`, `model`, `endpoint`, and `recorded`. The runner checks those raw line
fields for presence only. Review judges Markdown visibility, identity, and
truthfulness.

## Negative Demonstrations

`docs/evidence/M1-negative-demonstrations.md` is one canonical fixed skeleton:
the exact title `# M1 Negative Demonstrations`, then outcome 2, 3, 6, and 8
sections in that order, with no other lines. Each section contains exactly one
fenced, one-line JSON object:

```json
{"mechanism_disabled":"<specific production mechanism>","observed_failure":"<protected assertion and observed result>","candidate":"<40 lowercase hex>","artifact":"<safe tracked repository-relative path>","restored_sha256":"sha256:<64 lowercase hex>"}
```

The exact skeleton leaves no alternative Markdown heading or visibility form to
interpret. The complete JSON reader rejects malformed data, duplicate keys,
missing keys, extra keys, and decoded description strings outside printable
ASCII. The candidate must be a reachable ancestor of `HEAD`. The named artifact
must be a tracked regular file reached without a symlink path component, and all
three byte identities must agree: the candidate blob, the current working-tree
file, and `restored_sha256`.

The runner separately requires a clean whole tree before and after validation.
Together these checks prevent a mutation from being certified while a tracked or
ordinary untracked residue remains. Ignored runtime/build state is not claimed as
restoration evidence. Whether the mechanism was really disabled and caused the
recorded failure is still closure-review work.

## Durable Fault Evidence

The production durable-transition catalogue is the source of truth for fault
identifiers. Outcomes 2 and 3 require equality between the catalogue identifiers,
the injected identifiers, and the observed identifiers, covering failure before
linearization, after linearization but before reply or publication, and recovery
or re-presentation. Outcome 8 additionally proves that a possibly performed
effect with no durable receipt becomes `outcome_unknown` and is not blindly
retried.

Mutation runs name a clean candidate and tracked production artifact and restore
with that candidate's committed bytes. The structural restoration check above is
required, but it cannot replace review of the mutation or fault-injection result.

## User-State Containment

The runner physically resolves the real `~/.loopex` path and every inherited root
it will use before allocation. Relative paths, `..`, dangling links, link chains,
case-folded aliases, and device/inode aliases are refused when they enter the
protected directory; an unresolvable path is refused as unavailable evidence.

The writable lane relocates `HOME`, `LOOPEX_HOME`, and the workspace. Defense in
depth fingerprints the real state before and after using entry paths, types,
permission modes, symlink targets, device/inode identities, and regular-file
contents. When the command-line root is a symlink, a separate record covers the
fully resolved target root's path, identity, type, mode, and file contents when
applicable. A mismatch fails, but the physical relocation is the containment
mechanism.

## Closure Document Set

All paths below must exist before the gate can be green. Review, not mere
presence, establishes that each is complete and current.

```text
CHANGELOG.md
README.md
DEVELOPMENT.md
docs/plans/README.md
docs/plans/M1.md
docs/evidence/M1-toolchain-matrix.md
docs/evidence/M1-provider.md
docs/evidence/M1-negative-demonstrations.md
docs/evidence/README.md
docs/developer/agent-context-map.md
```

## Failure Rules

A red required gate blocks closure. Missing or unparsable evidence is unavailable,
not PASS. Never skip, filter, soften, quarantine, rewrite, inflate a retry or
timeout, or substitute a fake for a required real provider, executor, store,
process kill, or restart.

A retry is diagnostic. A same-SHA, same-seed, same-environment failure that
disappears is a blocking flake until fixed or explicitly dispositioned.

## Declared Red Condition

At the accepted opening checkpoint there is no explicit supervised runtime and
none of the eight protected product selectors exists. The runner reaches the
missing `runtime_test.exs` condition above without allocating storage or starting
Mix.

The gate becomes green only when one embedded caller crosses one runtime contract
through a committed real-model request and controlled local effect, observes
durable committed events, survives an OS-process kill after an executor receipt,
reconciles without a second dispatch, makes a second real-model call, and reaches
a continued terminal result.
