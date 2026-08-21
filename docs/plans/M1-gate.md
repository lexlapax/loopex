# M1 Gate

Executable acceptance for `M1`. This file is the lock: its canonical UTF-8/LF
bytes and their SHA-256 digest are bound at acceptance and stay immutable for the
milestone. Conforming progress recorded in the plan pair is not part of the lock.

The runner is `bash scripts/check-m1-gate.sh`. It is a replaceable runner of
repository-owned commands, never the only home of a check, and it judges
mechanics only. Whether a demonstration is honest, whether an abstraction earned
its place, and whether an outcome is truly met are review readings that no runner
substitutes for.

This gate exists to fail because the working session loop does not exist. It adds
no repository check, and no outcome may be satisfied by adding one.

## Runner

`bash scripts/check-m1-gate.sh` runs from a clean checkout on either locked
toolchain pair, with the documented portable toolchain in `DEVELOPMENT.md`. It is
invoked once per locked pair, and both runs are recorded in the retained matrix
evidence, because one Mix run has one Erlang runtime and cannot prove both.

The runner reuses M0's proved machinery rather than reimplementing it: the same
toolchain matrix task, the same user-state isolation discipline, the same
real-provider lane rules, and the same negative-demonstration format. Anything
M0 locked that M1 also depends on is invoked, not copied.

## Bound Artifacts

Each path is compared against its digest at every validation. A relevant byte
change invalidates affected evidence and review.

| SHA-256 | Path |
| --- | --- |
| `332b46070fb091e8c88b9f0dcba38560771d7998cc6039d5d40a2306a3e9df90` | `scripts/check-m1-gate.sh` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

`.tool-versions` carries forward from M0 unchanged; ADR 0002 is not reopened by
this milestone. The runner's digest is the bytes that produced the declared red
condition; changing them changes the gate and requires the acceptance authority.

## Locked Commands

Every command runs and must exit zero. Unknown or shared scope runs the full gate.

| # | Command | Proves |
| --- | --- | --- |
| 1 | `mix format --check-formatted` | Checkpoints are formatting-clean |
| 2 | `mix compile --warnings-as-errors` | Checkpoints are warning-free |
| 3 | `mix loopex.deps_budget` | Dependency budget and direction hold; core stays stdlib and OTP only |
| 4 | `mix loopex.version_train` | Every application carries one version |
| 5 | `mix loopex.matrix` | The running toolchain is a locked pair and both pairs are recorded as run |
| 6 | `mix loopex.core_only` | Core builds and passes against fakes with no adapter resolved or started |
| 7 | `mix loopex.docs_check` | Covered public code documents Concept before Technical depth |
| 8 | `mix loopex.hook_registration` | Every client hook is registered under its required event and matcher |
| 9 | `mix test` | The full suite passes with the real-provider lane excluded by default |

Commands 1 through 8 are M0's, invoked unchanged. M1 adds no repository check of
its own, which is the point: the gate must go green because the loop works.

## Protected Tests and Selectors

Each selector runs with a minimum executed count, so a file emptied of its cases
fails rather than passing vacuously. Each named test must exist by exact name.

| Selector | Minimum | Locked names |
| --- | --- | --- |
| `apps/loopex/test/runtime_test.exs` | 3 | `two runtimes coexist without a global name`; `a runtime reference is required rather than inferred` |
| `apps/loopex/test/session_lifecycle_test.exs` | 4 | `a session resumes with the durable truth it committed`; `a second coordinator cannot own a live session` |
| `apps/loopex/test/store_conformance_test.exs` | 5 | `every implementation refuses a stale writer at replay`; `a killed writer loses no acknowledged fact` |
| `apps/loopex/test/embedded_api_test.exs` | 4 | `progress and diagnostics never carry durable truth` |
| `apps/loopex/test/real_model_lane_test.exs` | 1 | `one real model call completes inside a session` |
| `apps/loopex/test/executor_test.exs` | 8 | `each missing grant element is refused individually`; `one controlled tool executes and commits its effect` |
| `apps/loopex/test/reference_client_test.exs` | 2 | `the client drives the loop through the embedded API only` |
| `apps/loopex/test/end_to_end_recovery_test.exs` | 2 | `exactly one dispatch ever carried each effect across the restart`; `every acknowledged fact survives the restart` |

The executor minimum is eight because seven grant elements are refused
individually and one real execution succeeds; a smaller count means an element is
untested.

## Closure Document Set

`M1` must update this exact set before closure. Drift blocks closure like any
unmet outcome. The runner does not judge whether a document is current — that is
a closure-review reading — but the set is fixed here so the reading has a
checklist rather than a guess.

```text
CHANGELOG.md
README.md                              (derived status summary)
docs/plans/README.md                   (register row and status capsule)
docs/plans/M1.md                       (progress rows and governance)
docs/evidence/M1-toolchain-matrix.md
docs/evidence/M1-provider.md
docs/evidence/M1-negative-demonstrations.md
docs/evidence/README.md
docs/developer/agent-context-map.md    (version-specific guidance)
```

## Toolchain Matrix

Both locked pairs run the whole runner, in both orders and each pair after
itself, and every run is recorded in `docs/evidence/M1-toolchain-matrix.md` in the
verbatim fenced form `mix loopex.matrix` reads. A per-lane pass proves nothing
about ordering: a shared build directory once made the second lane fail on beams
the first had compiled.

## Evidence Classes

| Class | Required for |
| --- | --- |
| Property over generated histories | Outcomes 2, 3 |
| Fault injection at every durable transition | Outcomes 2, 3, 8 |
| Reusable conformance suite at a replaceable boundary | Outcome 3 |
| Negative corpus, each element individually refused | Outcome 6 |
| Real-path run with retained non-secret identity | Outcome 5 |
| Counting collector across a restart | Outcome 8 |
| Negative demonstration, one per constitutional outcome | Outcomes 2, 3, 6, 8 |

## User-State Isolation

Tests use temporary `LOOPEX_HOME` and workspaces, and helpers fail before
touching real user state. The runner relocates `HOME` and asserts real user state
is unchanged after the run, as M0's does. A run that reaches real user state fails
regardless of every other result.

## Real-Provider Lane

Outcome 5 requires one real model call from an explicitly invoked lane. The lane
is excluded by default and invoked with `--only real_provider`.

An absent `LOOPEX_PROVIDER_API_KEY` reports evidence unavailable and fails; it
never skips. A skipped lane is not a pass. Retained evidence records the
non-secret provider, model, and endpoint class; the credential never enters a
journal, a fixture, a log, a diagnostic, an argument list, or a committed byte.

## Negative Demonstrations

For each of outcomes 2, 3, 6, and 8, `docs/evidence/M1-negative-demonstrations.md`
records exactly one of each field, in a section headed `## Outcome N`:

```text
- mechanism disabled: <what was turned off>
- observed failure: <which protected test failed, and on what assertion>
- demonstrated at: <resolvable revision>, reverted before commit and confirmed
  byte-identical by SHA-256 of <the artifact>
```

Exactly one of each field per outcome. A duplicate field lets a real value sit
beside an unfilled dash; a second section lets a populated one cover a
placeholder.

## What the Runner Is For, and What Review Owns

The runner proves that named commands exited zero, that protected selectors ran
with their minimum counts, that locked names exist, that bound bytes match their
digests, and that retained evidence is present and well formed.

Review owns everything else, and the list is not decorative. Whether a
demonstration disabled a mechanism that mattered. Whether a test passes for the
reason it names. Whether an abstraction unified anything. Whether the reference
client is a client or a second implementation of the kernel. Whether the loop a
reader would call working is the loop the gate went green on.

## Failure Rules

A red required gate blocks closure. Never skip, filter, soften, quarantine,
rewrite, inflate retries or timeouts, or substitute a fake for a required real
path to make work pass.

A retry is diagnostic, not a pass. A same-SHA, same-seed, same-environment
failure that disappears is a blocking flake until fixed or explicitly
dispositioned. Environment failure means evidence unavailable, not PASS.

## Declared Red Condition

At the opening checkpoint this gate fails because the working session loop does
not exist. Specifically: no explicit runtime starts, no store port exists, no
embedded API is exposed, no executor validates a grant, no reference client
drives anything, and none of the eight protected selectors exist.

That is the declared missing behaviour. The gate must not go green by adding a
checker, a registry, or a document. It goes green when a caller can start Loopex,
hold a session across a kill, and see that no effect ran twice.
