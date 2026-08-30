# M2 Toolchain Matrix

Every M2 gate capture of the locked toolchain lanes, with the revision it was
taken at and the sealed identity the run produced.

The matrix proves that the milestone's verdict does not depend on one developer's
machine: the same gate command, at the same candidate, on the runtime floor and
on the current supported pair, and on a second operating system. A lane that was
not run is unavailable evidence, never a pass.

## Lanes

| Lane | Command |
| --- | --- |
| `darwin-floor` | `mise exec erlang@26.0 elixir@1.17.0-otp-26 -- bash scripts/check-m2-gate.sh --capture darwin-floor` |
| `darwin-current` | `bash scripts/check-m2-gate.sh --capture darwin-current` |
| `linux-current` | `bash scripts/check-m2-gate.sh --capture linux-current` |

Two `m0` rows accompany them: the closed `M0` gate run once under each pair
against the same candidate. Bootstrap does not substitute for either, and `M2`
never nests `M0`.

Each lane contributes exactly one capture row. All three must name the same
candidate, a `CAPTURE` verdict and zero exit, their lane's exact `elixir`, `otp`,
and `os`, a canonical seed, a positive executed count, and the build identities
the bound selector runner sealed; and all three must agree on `provider`,
`model`, `endpoint`, `adapter_build`, `executor_build`, `executor_identity`, and
`tool_identity`.

Observation times and architectures are independent recorded facts and are not
compared. Review, not the runner, cross-checks every retained field against the
actual captured process output.

## Captures

<!-- loopex:m2-matrix:start -->
```text
matrix candidate=2c6b3a1367d699f71bf127abfc2668033c60392d gate_sha256=1b24752f6068efaa4eada3758566ff05c0ff950e5af2a81a6cec0a0e2f8d3306 runner_sha256=508c2090f78be73fe8718cd214b68f705a2c3bb53aeea81269d7eb63f870f099 exunit_runner_sha256=cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0 tool_versions_sha256=fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999 command=bash:scripts/check-m2-gate.sh
capture lane=darwin-floor candidate=2c6b3a1367d699f71bf127abfc2668033c60392d elixir=1.17.0 otp=26.0 seed=637613 executed=257 verdict=CAPTURE exit=0 os=darwin arch=arm64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-08-30T21:56:51Z
capture lane=darwin-current candidate=2c6b3a1367d699f71bf127abfc2668033c60392d elixir=1.20.3 otp=29.0.5 seed=658448 executed=257 verdict=CAPTURE exit=0 os=darwin arch=arm64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-08-30T21:37:43Z
capture lane=linux-current candidate=2c6b3a1367d699f71bf127abfc2668033c60392d elixir=1.20.3 otp=29.0.5 seed=189557 executed=257 verdict=CAPTURE exit=0 os=linux arch=x86_64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-08-30T22:14:45Z
m0 lane=floor candidate=2c6b3a1367d699f71bf127abfc2668033c60392d gate_sha256=6e02cd424bab8e3410205ca053adce150ee9fa1a84d7b6f5b032390c4529e09f command=bash:scripts/check-m0-gate.sh elixir=1.17.0 otp=26.0 verdict=GREEN exit=0
m0 lane=current candidate=2c6b3a1367d699f71bf127abfc2668033c60392d gate_sha256=6e02cd424bab8e3410205ca053adce150ee9fa1a84d7b6f5b032390c4529e09f command=bash:scripts/check-m0-gate.sh elixir=1.20.3 otp=29.0.5 verdict=GREEN exit=0
```
<!-- loopex:m2-matrix:end -->

All three lanes captured at one candidate, each with a fresh and disjoint owned
task root, and all three agree on the demonstration role's sealed provider,
model, endpoint, adapter build, executor build, executor identity, and tool
identity. The two `m0` rows are the closed `M0` gate run once under each pair
against the same candidate.

All three lanes are reachable. The two Darwin lanes run on the development
machine, where the locked floor pair is installed and resolves through `mise`,
and the Linux lane runs on a host carrying the same candidate and the locked
current pair.

Every lane must run against one clean committed candidate, each with a fresh and
disjoint owned task root, so the captures are taken together once the candidate
is settled rather than accumulated as it changes.

## Related

- [Coding demonstration](M2-coding-demonstration.md) — the attended real-provider run.
- [Real-call attestations](M2-real-call-attestations.md) — the identity these captures seal.
- [M1 toolchain matrix](M1-toolchain-matrix.md) — the closed milestone's equivalent record.
- [Evidence index](README.md).
