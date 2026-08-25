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
| `floor` | `mise exec erlang@26.0 elixir@1.17.0-otp-26 -- bash scripts/check-m2-gate.sh --capture floor` |
| `current` | `bash scripts/check-m2-gate.sh --capture current` |
| `linux-current` | `bash scripts/check-m2-gate.sh --capture linux-current` |

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

The `floor` and `current` lanes are runnable on the development machine: the
locked floor pair is installed and resolves through `mise`. The third is not:

| Lane | What it needs |
| --- | --- |
| `linux-current` | a Linux host running the same candidate |

That absence is unavailable evidence and blocks closure exactly as a red lane
would; it is recorded here rather than left to be discovered during a closure
run.

## Related

- [Coding demonstration](M2-coding-demonstration.md) — the attended real-provider run.
- [Real-call attestations](M2-real-call-attestations.md) — the identity these captures seal.
- [M1 toolchain matrix](M1-toolchain-matrix.md) — the closed milestone's equivalent record.
- [Evidence index](README.md).
