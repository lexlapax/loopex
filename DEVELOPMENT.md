# Development

Loopex has closed its M0 feasibility milestone and is preparing the M1 working
loop. Product implementation is authorized only after M1 carries recorded
acceptance. This document describes how to validate and work on the repository,
and it owns the commands, not the milestone state. There is no installable
package and no public product surface.

The canonical status for the checked-out revision, including currently
authorized work and the next maintainer decision, is in
[docs/plans/README.md](docs/plans/README.md). Its Directing the Work section
owns how development is requested — the verbs and where each one stops. This
file owns the commands those verbs run, and milestone state lives in neither.
The split is deliberate: the verbs outlive the toolchain, so replacing the seed
bridges with Mix entrypoints changed the commands here and nothing there. The
[development charter](docs/developer/development-charter.md#concept) explains the
project's clarity and traceability commitments; its
[technical companion](docs/developer/development-charter-technical.md#technical-depth) defines
the exact documentation, review, and code-comment conventions.

## Bootstrap Prerequisites

The provider-neutral bootstrap check requires:

- Git;
- Bash;
- a POSIX userland providing `awk`, `cat`, `grep`, `readlink`, `sed`, and `tr`; and
- the accepted Elixir/OTP toolchain, which supplies `mix`.

That is the whole list, and it is the enduring development baseline: Git,
shell/POSIX tools, and the accepted Elixir/OTP toolchain. The seed's two bridge
prerequisites are gone — repository checks now run as repository-owned Mix
commands, and the client hooks read a tool call through
`scripts/json-field.sh`, which uses `awk` from the baseline rather than an
added dependency. Shell is not retired: a check may remain a shell entrypoint
that calls Mix, and several do.

Adding another development dependency requires the ordinary dependency
decision.

The M1 gate's stronger filesystem and containment lane additionally requires
`stat`, `find`, `sort`, `comm`, `od`, `mktemp`, `cp`, `uname`, `/usr/bin/env`,
`/usr/bin/id`, `/usr/bin/locale`, and either `shasum` or `sha256sum`. The runner probes and validates
the BSD/GNU `stat` and SHA-256 dialects before trusting their output. Its closed
child environment fixes `LANG=C.UTF-8` and `LC_ALL=C.UTF-8`; a platform without
that locale is unavailable M1 evidence rather than an implicit encoding change.

The checkout must preserve the tracked relative `.claude/skills` symlink. On
Windows, WSL is the straightforward path; Git Bash also requires Windows
Developer Mode or equivalent symlink permission and Git symlink support. Native
PowerShell bootstrap commands are not provided yet.

Verify a checkout from the repository root:

```bash
git status --short --branch
bash scripts/check-bootstrap.sh
```

The aggregate runs five checks: agent/client bootstrap, ignore policy, commit
messages, branch/worktree hygiene, and status/document drift. It requires
no GitHub account, `gh` CLI, hosted CI service, credentials, network access,
coding-agent client, or product dependency download. Hosted CI may mirror this
command but does not define it.

Every check reads the checkout and writes nothing to it. The aggregate does need
a writable build directory, because it now runs on Mix and Mix compiles: that is
the direct consequence of moving repository validation onto the accepted
toolchain. A reviewer who must not write to an ambient temporary directory
directs the build into an explicit isolated task root through the
`MIX_BUILD_PATH` variable. The read-only inspection lane is the milestone gate
runner's prefix, which reaches its declared condition before it allocates any
storage.

The individual repository commands can also be run directly:

```bash
mix loopex.status              # paired documents, register, governance, history
mix loopex.agent_bootstrap     # client adapter structure and hook registration
mix loopex.hook_registration   # each hook's required event and matcher
mix loopex.docs_check          # compiled Concept-before-Technical-depth ordering
mix loopex.self_hosting        # replacement measurement and dropped behaviors
```

## Optional Development Clients

Development clients are optional tools, not project dependencies. The currently
tested adapters are Claude Code and Codex; their retained versions and loading
evidence live in
[docs/developer/agent-adapter-smoke.md](docs/developer/agent-adapter-smoke.md).
Canonical behavior lives in [AGENTS.md](AGENTS.md) and routes through
[the agent context map](docs/developer/agent-context-map.md). Candidate clients,
including OpenCode, Pi, and a future Loopex coding surface, are unsupported until
their adapters and parity smokes exist.

## Product Toolchain

The bootstrap floor is OTP 26+ and Elixir 1.17+, and ADR 0002 locks two exact
pairs, recorded in `.tool-versions`. The product scaffold exists, so installing
the toolchain lets you build and test today: `mix test` from the repository root,
`bash scripts/check-bootstrap.sh` for the aggregate,
`bash scripts/check-m0-gate.sh` for the closed M0 gate, and
`/bin/bash -p scripts/check-m1-gate.sh` for the M1 gate. The
privileged-Bash flag is part of the command: the runner refuses an ordinary Bash
because inherited functions and `BASH_ENV` would otherwise precede its
environment boundary.

Before implementation begins, the M1 gate is deliberately red and must report
the declared missing runtime selector before allocating a state root. The plan
pair and gate gain implementation authority only through exact-SHA independent
review and explicit recorded maintainer acceptance; the declared red is opening
proof, not implementation authority.

After the protected product selectors exist, M1's two explicitly tagged
real-provider selectors require `LOOPEX_PROVIDER_API_KEY`. The runner removes
the entire ambient exported environment before its first external child,
establishes an exact non-secret allowlist, and passes the credential over standard
input only to the two direct real-provider VMs. Each runner consumes it before
candidate startup, starts the application without the credential, and installs
it only for the explicitly tagged real-provider selector; do not put the value
in a command argument, log, fixture, or retained evidence. The ordinary full
suite and repository checks remain credential-free.

The M0 gate locks the self-hosting transition, and that transition has landed:
the local aggregate, its structural and mutation checks, and the tested
client-hook paths all run through the accepted Elixir/OTP toolchain, with the
seed's two bridge prerequisites removed. `mix loopex.self_hosting` reports the
replacement's measured size and names every behavior it dropped with the reason,
which is the material an independent reviewer weighs; no run passes or fails on
the figure.

The same gate installs `mix loopex.docs_check`, a repository-owned check over
**compiled** documentation. It reads the doc chunk of every compiled module, so it
answers what a reader of the published documentation would see rather than what
characters appear in a source file. Covered public code must carry `## Concept`
before `## Technical depth`; a module with no documentation at all fails, and one
marked `@moduledoc false` is excluded and counted in the report. Semantic
usefulness and proportional private comments remain review obligations.

Core will use only the Elixir/Erlang standard runtime. Every child project
declares one literal `loopex_role`: `:contract`, `:core`, `:edge`, `:client`, or
`:extension`. The reusable parser recognises the extension role, but the M1
repository overlay permits only its exact six planned application identities
and admits no extension. Contract carries no dependency; core depends only on
protocol; store/model/executor edges depend in production on core and may also
depend on protocol; a client depends in production on core and composes concrete
edges only in tests. The only M1 direct external dependency is exactly
`{:req_llm, "~> 1.17.1"}` in the ReqLLM edge. At the accepted red opening, that
existing edge may retain
its M0 protocol-only inward shape while the six-app inventory is incomplete;
every complete inventory, and therefore every green gate, requires its core
edge too. The M1 gate requires physical child projects to equal the candidate
index and reads the literal dependency authority before Mix. It rejects locked-command aliases,
redirected umbrella paths, identity mismatches, duplicates, alternate
path/source-control dependencies, and statically visible unknown or reverse
edges. The offline materializer derives the exact required non-optional lock
closure, refuses missing, unsatisfied, and unreachable records, and admits an
archive only after its checksums and literal `metadata.config` package,
build-tool, dependency, and Elixir-floor authority match the lock. Cached
archives remain ordinary and physically disjoint from protected user state, and
all are validated before the gate-owned dependency tree is written without
consulting an ambient `deps/`.
Later project callbacks and task definitions remain trusted candidate code
reviewed independently; they are not claimed as mechanically absent.

## Implementation Posture

Start with direct OTP and the smallest clear implementation. Production code,
tests, fixtures, helpers, public surface, and abstractions all count as system
cost. A new abstraction must name the concrete examples or current
implementations it unifies and why direct code is insufficient; do not add a
layer for a hypothetical future consumer.

Each accepted plan carries a proportional minimalism budget and locks any useful
ceilings or negative constraints in its gate. Raw line count is a review signal,
not a universal gate: it must not reward compressed code, hidden complexity, or
missing evidence. Keep tests focused and reusable, but never delete required
coverage merely to make the repository smaller.

Elixir modules, behaviours, callbacks, public APIs, public types, and important
boundaries explain both `## Concept` and `## Technical depth` in their standard
documentation. A private function uses adjacent `# Concept:` and
`# Technical depth:` comments only for a non-obvious invariant, effect, failure
mode, or design decision. Obvious helpers rely on clear names and direct code;
documentation should clarify rather than paraphrase syntax.

## Before Working

Read [AGENTS.md](AGENTS.md), then the
[plans status register](docs/plans/README.md), and use the
[agent context map](docs/developer/agent-context-map.md) only to load relevant
Concept sections and their exact Technical depth. `M0` is closed. `M1` is the
active milestone on this development line; consult the marked register capsule
for its exact lifecycle state and currently authorized work. Product
implementation begins only after the M1 plan pair and red gate are independently
reviewed and explicitly accepted.

Tests use a temporary `LOOPEX_HOME` and temporary workspaces, and the helpers fail
before touching real user state. Never point development or test commands at a
real `~/.loopex`.

## Toolchain pairs

ADR 0002 locks two validated pairs, recorded in `.tool-versions`. Homebrew carries
only the current one, and it pairs Elixir against whatever OTP it ships, so the
floor pair needs a version manager. `mise` was used to provide both:

```text
mise install erlang@26.0
mise install elixir@1.17.0-otp-26
mise exec erlang@26.0 elixir@1.17.0-otp-26 -- bash scripts/check-m0-gate.sh
mise exec erlang@26.0 elixir@1.17.0-otp-26 -- /bin/bash -p scripts/check-m1-gate.sh
```

### M1 retained toolchain evidence

M1 capture is deliberately not an ordinary gate pass. Start from one clean,
committed source candidate `C` and run the three bound non-gate roles, retaining
each final `capture ... verdict=CAPTURE exit=0` record:

```text
Darwin floor     mise exec erlang@26.0 elixir@1.17.0-otp-26 -- /bin/bash -p scripts/check-m1-gate.sh --capture floor
Darwin current   /bin/bash -p scripts/check-m1-gate.sh --capture current
Linux current    /bin/bash -p scripts/check-m1-gate.sh --capture linux-current
```

Each capture uses a fresh, disjoint task root, runs every M1 command except
validation of the matrix it will populate, prints `CAPTURE` rather than GREEN,
and is not merge evidence. Physical order and adjacency carry no meaning because
the three processes share no mutable run state. Do not edit or amend `C` between
captures. The Linux lane requires the exact current pair; it is not satisfied by
a nearby distribution package and makes no floor-on-Linux claim.

On the `serenity` Linux evidence host, the distribution VM is not a locked pair.
The reproducible current-pair environment performs no toolchain or dependency
download at gate runtime and is made from these exact linux/amd64 manifests:

```dockerfile
FROM hexpm/elixir@sha256:ae4e58c68e37ef304ed2438ff098fb08da6d087e99c478a28d14cc2a0240e0b8 AS toolchain
FROM buildpack-deps@sha256:0a1caa1cbfad810ca0d10eec9fc5924ea1033eeecb13cdab9fb00bfb47f196bd
RUN apt-get update \
 && apt-get install -y --no-install-recommends 'libsctp1=1.0.19+dfsg-2build1' \
 && rm -rf /var/lib/apt/lists/*
COPY --from=toolchain /usr/local/ /usr/local/
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
```

The first image supplies Elixir 1.20.3 / OTP 29.0.5; the second supplies Git and
the baseline userland. The pinned `libsctp1` runtime package preserves the OTP
build's enabled SCTP support after `/usr/local` is copied into the second stage;
the prepared image is built before the gate and the gate performs no package
download. Run with an account represented in the container's
passwd database and owning the checkout: either copy the exact candidate into a
root-owned read-only tree for the image's root account, or provision the host
UID/GID, passwd entry, and matching home explicitly. Mount the prepared Mix/Hex
inputs read-only and give the account an owned writable `/tmp`. The two tagged
real-provider roles still require provider network access. Pass their credential
through a wrapper's standard input rather than an image argument or environment
flag. Docker is an evidence-host provisioner here, not a Loopex product or
development dependency, and another Linux environment is valid if it supplies
the same exact pair and gate prerequisites.

Against that same source candidate, separately run
`bash scripts/check-m0-gate.sh` under the floor pair and then the current pair.
Capture each process's combined stdout and stderr before displaying any
diagnostic, replace literal provider-key bytes in-process, and retain only the
non-secret provider, model, and endpoint identity beside the exact candidate,
M0 gate digest, toolchain, verdict, and exit. Bootstrap does not replace either
M0 run, and the M1 runner never invokes M0 recursively.

Write one canonical metadata record, the Darwin floor/current and Linux-current
capture records, and the two M0 records to
`docs/evidence/M1-toolchain-matrix.md`. The metadata binds `C`, the M1 gate,
shell runner, standalone ExUnit runner, dependency authority, self-contained
evidence verifier, `.tool-versions`, and canonical command. Each capture binds
its OS, architecture, open-file/process limits, and nonce-bound observed
provider/model/endpoint, adapter build, executor build and runtime identity,
tool identity, and observation time.
The model-only and combined real roles must agree on their shared fields before
the capture row is emitted. Candidate `C` plus each fixed application/version
identifies the exact source build. Commit the matrix alone as direct evidence
commit `E` of `C`. The
ordinary M1 gate runs on `E` and validates that the complete trees differ only at
that path before it may print GREEN. An open descendant of `E` is invalid.

At closure, the unique first-closing transition `T` must be `E`'s direct
one-parent child and change exactly `docs/plans/M1.md`, `docs/plans/README.md`,
and `README.md`: only the empty Closure row and canonical marked status blocks
may change, and Closure must bind `E`. Later descendants retain the evidence only
while `E` and `T` stay reachable, the Closure binding stays byte-identical, and
the matrix bytes remain those committed at `E`. Any interposed commit or earlier
product, selector, harness, toolchain, or gate change requires a new `C`, three
new M1 captures, two new M0 re-proofs, and a new direct `E`.

Alternating pairs also shares mutable dependency state. `MIX_BUILD_PATH` alone
leaves `deps/` and the Rebar cache common to both, which produces cache
restore/discard diagnostics and, once observed, a self-healing corrupt-beam
warning. Neither changed an exit status. The M1 runner instead reconstructs
`MIX_DEPS_PATH` offline from the exact package archives checksum-bound by the
candidate's literal `mix.lock`; it never copies the ambient repository `deps/`
tree. A missing cached package is unavailable evidence and fails. Outside the
gate, prime the ordinary Hex cache with the accepted toolchain before capture.
A manual isolated command must likewise set both paths:

```text
env MIX_BUILD_PATH=<root>/build MIX_DEPS_PATH=<root>/deps mix <task>
```

Do not activate a version manager inside the checkout. `.tool-versions` is a
digest-bound gate artifact listing both pairs, so a tool that reads it would pick
one arbitrarily; invoke the pair explicitly instead. The floor pair also needs its
own Hex and rebar archives (`mix local.hex --force`, `mix local.rebar --force`),
which are per-Elixir-version and live outside the checkout.
