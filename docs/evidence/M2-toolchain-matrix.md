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

Two `m0` rows and one `m1` row accompany them: the closed `M0` gate run once under each pair
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
matrix candidate=f17beef1b62116fa411b3fa496f3e8964b3af81c gate_sha256=bd168781cc7aea2c971f4685416524ef002bfc2ef390275f749ae2c1397361ae runner_sha256=110ad320c252f1edf2661ebf2eeeb49f98faf47421470f371101ade99bd350f2 exunit_runner_sha256=cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0 exunit_corpus_sha256=0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d gate_corpus_sha256=50319510018a4b3e2fab2e5998f3b7979209982b9cabc15e7fa69cfc5782a8cc composition_corpus_sha256=809ca8b835182751f493ef1c931d309f36a73ae48cf78208f84b81fcb05e74a4 tool_versions_sha256=fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999 command=bash:scripts/check-m2-gate.sh
capture lane=darwin-floor candidate=f17beef1b62116fa411b3fa496f3e8964b3af81c elixir=1.17.0 otp=26.0 seed=784724 executed=493 verdict=CAPTURE exit=0 os=darwin arch=arm64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-09-03T14:05:28Z
capture lane=darwin-current candidate=f17beef1b62116fa411b3fa496f3e8964b3af81c elixir=1.20.3 otp=29.0.5 seed=623669 executed=493 verdict=CAPTURE exit=0 os=darwin arch=arm64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-09-03T13:33:30Z
capture lane=linux-current candidate=f17beef1b62116fa411b3fa496f3e8964b3af81c elixir=1.20.3 otp=29.0.5 seed=223684 executed=493 verdict=CAPTURE exit=0 os=linux arch=x86_64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-09-03T13:31:50Z
m0 lane=floor candidate=f17beef1b62116fa411b3fa496f3e8964b3af81c gate_sha256=6e02cd424bab8e3410205ca053adce150ee9fa1a84d7b6f5b032390c4529e09f command=bash:scripts/check-m0-gate.sh elixir=1.17.0 otp=26.0 verdict=GREEN exit=0
m0 lane=current candidate=f17beef1b62116fa411b3fa496f3e8964b3af81c gate_sha256=6e02cd424bab8e3410205ca053adce150ee9fa1a84d7b6f5b032390c4529e09f command=bash:scripts/check-m0-gate.sh elixir=1.20.3 otp=29.0.5 verdict=GREEN exit=0
m1 candidate=f17beef1b62116fa411b3fa496f3e8964b3af81c gate_sha256=0076a8aa7602db0695a03ef12712e4bdf4d31098d8e71219c9f69e1298f852ee command=bash-p:scripts/check-m1-gate.sh elixir=1.20.3 otp=29.0.5 seed=14714 executed=44 verdict=GREEN exit=0
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

<!-- loopex:m2-recapture:start -->
```text
recapture candidate=d4d6699c327d866a115b6895c3ccb5413fe5c017 gate_sha256=5228531fc78d81cda5de3322ab4621d45035eb9d2cf0b38346c775aff2e569dc runner_sha256=14927db7c59378c94e741f704631422a4792c0994c3a9a3e54cfb6a9214be375 exunit_runner_sha256=53d8219bdee584a3849a85a1102e405520d5dd0dfbe21d259434bc9edfc5fcc0 exunit_corpus_sha256=c36253cff3d74ddff1b330695edbc4bde0a4565c1412c67c1293b2fb7ca6129b gate_corpus_sha256=c4ab3706117d0189f83b4807af36a86be9abe7c4eb37b7eb0c3e5b59d7a4928e composition_corpus_sha256=809ca8b835182751f493ef1c931d309f36a73ae48cf78208f84b81fcb05e74a4 tool_versions_sha256=fea095ecec784a4440b872ad5f53a8da2cb4e13e43b6f05add5cfd75bb352879 command=bash:scripts/check-m2-gate.sh
capture lane=darwin-floor candidate=d4d6699c327d866a115b6895c3ccb5413fe5c017 elixir=1.18.5 otp=27.3.4 seed=588274 executed=690 verdict=CAPTURE exit=0 os=darwin arch=arm64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-09-18T21:35:07Z
capture lane=darwin-current candidate=d4d6699c327d866a115b6895c3ccb5413fe5c017 elixir=1.20.3 otp=29.0.5 seed=152023 executed=690 verdict=CAPTURE exit=0 os=darwin arch=arm64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-09-18T22:35:10Z
capture lane=linux-current candidate=d4d6699c327d866a115b6895c3ccb5413fe5c017 elixir=1.20.3 otp=29.0.5 seed=225364 executed=690 verdict=CAPTURE exit=0 os=linux arch=x86_64 provider=anthropic model=claude-haiku-4-5-20251001 endpoint=https://api.anthropic.com adapter_build=loopex_llm_reqllm@0.0.0 executor_build=loopex_executor_local@0.0.0 executor_identity=executor-local tool_identity=loopex.bash@1.0.0+loopex.edit@1.0.0+loopex.read@1.0.0+loopex.write@1.0.0 recorded=2026-09-18T21:29:55Z
m0 lane=floor candidate=d4d6699c327d866a115b6895c3ccb5413fe5c017 gate_sha256=fefc8a54dc8393b66cd16cc7046f5c0290497f6056b47dfa330dcbb54b631bb2 command=bash:scripts/check-m0-gate.sh elixir=1.18.5 otp=27.3.4 verdict=GREEN exit=0
m0 lane=current candidate=d4d6699c327d866a115b6895c3ccb5413fe5c017 gate_sha256=fefc8a54dc8393b66cd16cc7046f5c0290497f6056b47dfa330dcbb54b631bb2 command=bash:scripts/check-m0-gate.sh elixir=1.20.3 otp=29.0.5 verdict=GREEN exit=0
m1 candidate=d4d6699c327d866a115b6895c3ccb5413fe5c017 gate_sha256=f9e660aa84b0d6765fba5fe5c521f81128d7ea696c2b9a73e3541599b6e5e273 command=bash-p:scripts/check-m1-gate.sh elixir=1.20.3 otp=29.0.5 seed=10924 executed=69 verdict=GREEN exit=0
```
<!-- loopex:m2-recapture:end -->
