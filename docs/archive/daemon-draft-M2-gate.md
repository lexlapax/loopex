# M2 Gate

Executable acceptance for `M2`. This file is the lock: its canonical UTF-8/LF
bytes and their SHA-256 digest are bound at acceptance and stay immutable for the
milestone. Conforming progress recorded in the plan pair is not part of the lock.

**Draft.** This gate is under mutable lookahead construction and is not yet
accepted. Its bytes and digest bind only when the maintainer accepts them, which
cannot happen before `M1` is Closed and integrated.

The runner is `bash scripts/check-m2-gate.sh`. It judges mechanics only: commands
exited zero, protected selectors ran with their minimum counts, locked names
exist, bound bytes match their digests, and retained evidence is present and well
formed. Whether a demonstration was honest, whether the daemon is a peer surface
or a second engine, and whether the loop a reader would call multi-client is the
loop this went green on are review readings no runner substitutes for.

This gate exists to fail because a second client cannot attach to a session whose
first client is gone. It adds no repository check, and no outcome may be
satisfied by adding one.

## Runner

`bash scripts/check-m2-gate.sh` runs from a clean checkout on every locked lane
recorded in `DEVELOPMENT.md`, once per lane, because one Mix run has one Erlang
runtime and cannot prove two.

The runner invokes `M1`'s proved machinery rather than reimplementing it: the
same toolchain matrix task, the same user-state isolation discipline, the same
credential channel rules, and the same negative-demonstration format. Anything
`M1` locked that `M2` also depends on is invoked, not copied.

## Bound Artifacts

| SHA-256 | Path |
| --- | --- |
| `2d966c0c50e74690aa4d860da29d54657b7c6fb3f2382d4518520e02494604b4` | `scripts/check-m2-gate.sh` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

Digests are recorded here as the draft stands and are rebound at acceptance once
the bytes are final. `.tool-versions` carries forward unchanged; ADR 0002 is not
reopened by this milestone.

## Locked Commands

Every command runs and must exit zero. Unknown or shared scope runs the full gate.

| # | Command | Proves |
| --- | --- | --- |
| 1 | `mix format --check-formatted` | Checkpoints are formatting-clean |
| 2 | `mix compile --warnings-as-errors` | Checkpoints are warning-free |
| 3 | `mix loopex.deps_budget` | Dependency budget and direction hold; core stays stdlib and OTP only |
| 4 | `mix loopex.version_train` | Every application carries one version |
| 5 | `mix loopex.matrix` | The running toolchain is a locked pair and every lane is recorded as run |
| 6 | `mix loopex.core_only` | Core builds and passes against fakes with no adapter resolved or started |
| 7 | `mix loopex.docs_check` | Covered public code documents Concept before Technical depth |
| 8 | `mix loopex.hook_registration` | Every client hook is registered under its required event and matcher |
| 9 | `mix loopex.status` | Register, capsule, derived summary, and plan/ADR structure are coherent |
| 10 | `mix test` | The full suite passes with the real-provider role excluded by default |

Commands 1 through 9 are inherited and invoked unchanged. `M2` adds no
repository check of its own, which is the point: the gate goes green because
independent clients can attach, not because a checker was added.

## Protected Tests and Selectors

Each selector runs with a minimum executed count, so a file emptied of its cases
fails rather than passing vacuously. Each named test must exist by exact name.

| Selector | Minimum | Locked names |
| --- | --- | --- |
| `apps/loopex_daemon/test/session_lifetime_test.exs` | 4 | `a session survives the death of the client that created it`; `work continues with zero attachments` |
| `apps/loopex_protocol/test/protocol_vectors_test.exs` | 6 | `a vector-only decoder round-trips every golden vector`; `a request before initialize is refused`; `an ungated experimental method is refused` |
| `apps/loopex_daemon/test/transport_test.exs` | 6 | `each malformed frame is refused individually`; `a broken attachment does not disturb another` |
| `apps/loopex_daemon/test/attachment_test.exs` | 5 | `the snapshot anchors at exactly the barrier sequence`; `concurrent attaches each receive a gapless stream` |
| `apps/loopex_daemon/test/backpressure_test.exs` | 4 | `a stalled consumer cannot delay a journal transaction`; `a stalled consumer cannot block another client` |
| `apps/loopex_daemon/test/cursor_test.exs` | 5 | `a cursor resumes contiguously across daemon restart`; `an expired cursor returns cursor_expired with a fresh snapshot`; `paged history read establishes no subscription` |
| `apps/loopex_daemon/test/collaboration_test.exs` | 5 | `a read-only attachment never acquires command authority`; `core carries no controller lease` |
| `apps/loopex_daemon/test/residency_test.exs` | 4 | `a session with zero attachments becomes non-resident`; `a post-eviction attach resumes with an identical snapshot` |
| `apps/loopex_daemon/test/end_to_end_multi_client_test.exs` | 2 | `exactly one dispatch carried each effect across the daemon kill`; `the observer cursor resumes with no gap` |

The protocol minimum is six because three negative refusals and the vector
round-trip are separate cases; a smaller count means a refusal is untested.

## Closure Document Set

`M2` must update this exact set before closure. Drift blocks closure like any
unmet outcome.

```text
CHANGELOG.md
README.md                              (derived status summary)
DEVELOPMENT.md                         (daemon operator entrypoint)
docs/plans/README.md                   (register row and status capsule)
docs/plans/M2.md                       (progress rows and governance)
docs/evidence/M2-toolchain-matrix.md
docs/evidence/M2-provider.md
docs/evidence/M2-negative-demonstrations.md
docs/evidence/README.md
docs/developer/agent-context-map.md    (version-specific guidance)
```

## Toolchain Matrix

Every locked lane runs the whole runner, and every run is recorded in
`docs/evidence/M2-toolchain-matrix.md` in the verbatim fenced form
`mix loopex.matrix` reads. A per-lane pass proves nothing about ordering.

## Evidence Classes

| Class | Required for |
| --- | --- |
| Client and daemon OS-process fault injection | Outcomes 1, 8, 9 |
| Language-neutral golden vectors plus an implementation-blind decoder | Outcome 2 |
| Negative corpus, each element individually refused | Outcomes 2, 3 |
| Attachment-race injection during active event production | Outcome 4 |
| Bounded-memory and liveness assertions under a stalled consumer | Outcome 5 |
| Retention-boundary and restart tests | Outcomes 6, 8 |
| Core-purity negative test | Outcome 7 |
| Real-path run with retained non-secret identity | Outcome 9 |
| Counting collector across a restart | Outcome 9 |
| Negative demonstration, one per constitutional outcome | Outcomes 1, 4, 7, 9 |

## User-State Isolation

Tests use temporary `LOOPEX_HOME`, workspaces, and socket paths, and helpers fail
before touching real user state. The runner relocates `HOME` and asserts real
user state is unchanged after the run. A run that reaches real user state fails
regardless of every other result.

## Real-Provider Role

Outcome 9 requires one real model call from an explicitly invoked role. The role
is excluded by default. The credential is forbidden in the runner's initial
environment and reaches only the role that needs it, as `M1` established.

An absent credential reports evidence unavailable and fails; it never skips. A
skipped role is not a pass. Retained evidence records the non-secret provider,
model, and endpoint class.

## Negative Demonstrations

For each of outcomes 1, 4, 7, and 9,
`docs/evidence/M2-negative-demonstrations.md` records exactly one of each field,
in a section headed `## Outcome N`:

```text
- mechanism disabled: <what was turned off>
- observed failure: <which protected test failed, and on what assertion>
- demonstrated at: <resolvable revision>, restored and confirmed identical by
  git show <candidate>:<path>
```

## What the Runner Is For, and What Review Owns

The runner proves that named commands exited zero, that protected selectors ran
with their minimum counts, that locked names exist, that bound bytes match their
digests, and that retained evidence is present and well formed.

Review owns everything else. Whether the daemon is a peer surface or a second
engine. Whether a demonstration disabled a mechanism that mattered. Whether a
test passes for the reason it names. Whether the protocol is genuinely
language-neutral or merely serialised Elixir. Whether the loop a reader would
call multi-client is the loop the gate went green on.

## Failure Rules

A red required gate blocks closure. Never skip, filter, soften, quarantine,
rewrite, inflate retries or timeouts, or substitute a fake for a required real
path to make work pass.

A retry is diagnostic, not a pass. A same-SHA, same-seed, same-environment
failure that disappears is a blocking flake until fixed or explicitly
dispositioned. Environment failure means evidence unavailable, not PASS.

## Declared Red Condition

At the opening checkpoint this gate fails because a second client cannot attach
to a session whose first client is gone. Specifically: no daemon exists, no
transport is served, no protocol candidate or vectors exist, no attachment is
race-free at N, no residency policy exists, and none of the nine protected
selectors exist.

That is the declared missing behaviour. The gate must not go green by adding a
checker, a registry, or a document. It goes green when one client can start a
session, die, and another can pick it up without a gap or a duplicated effect.
