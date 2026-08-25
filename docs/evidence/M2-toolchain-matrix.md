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
```
<!-- loopex:m2-matrix:end -->

No lane has been captured at this revision. The block is empty rather than
partially filled, because a matrix that carried one lane and omitted two would
read as a matrix with two lanes still running rather than as a milestone that
has never been run anywhere but one machine.

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
