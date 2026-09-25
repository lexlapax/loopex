# M5 closure runs

The check runs, review and demonstration retained for the M5 closure
candidate, each named by the exact source revision, platform and toolchain it
ran at. Complete logs and reports are kept by the maintainer outside the
repository; this page records their identities, results and SHA-256 digests.
Back to the [evidence index](README.md).

This page is the tested candidate's closure scaffold. Every value marked
`Pending` is the result or identity of a run or review taken of the tested
commit after it exists, and the administrative closure commit fills only those
values.

## Candidate

| Field | Value |
| --- | --- |
| Tested implementation SHA | Pending |
| Source `VERSION` | `0.2.0` |
| Administrative closure SHA | Not recorded on this page: a commit cannot contain its own hash. It is located by the plans register's `Closed` transition and by the tag |

## The fast check under the floor pair, on Linux (serenity)

`env -u MIX_BUILD_PATH MIX_BUILD_ROOT="/absolute/retained-work/M5-otp27-build" mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`

| Field | Value |
| --- | --- |
| Revision | Pending |
| Platform | Pending |
| Toolchain | Pending |
| Result | Pending |
| Measured duration | Pending |
| Retained-output reference | Pending |
| SHA-256 | Pending |

## The fast check on the current pair, hosted CI

| Field | Value |
| --- | --- |
| Revision | Pending |
| Run | Pending |
| Result | Pending |
| Measured duration | Pending |

## The release check on the current pair, on Linux

`LOOPEX_CROSS_UID_USER=<second user> bash scripts/check-release.sh`, with the
provider credential and Node 22.14.0. Closure requires a plain `PASS` final
line; `PASS (closure-incomplete: cross_uid not run)` is not that. The two
attended cases were answered by the implementing session's terminal driver on
the maintainer's instruction, not by a person watching, which the maintainer
accepted as the closure run of record
([disposition](../developer/agent-context-map.md#disposition-m5-driver-attendance-2026-09-23)).

| Field | Value |
| --- | --- |
| Revision | Pending |
| Platform | Pending |
| Toolchain | Pending |
| Node | Pending |
| Final line | Pending |
| Measured duration | Pending |
| Retained-output reference | Pending |
| SHA-256 | Pending |

| Lane | Executed | Result |
| --- | --- | --- |
| Real-provider manifest, nine rows | Pending | Pending |
| Node client: `loopex_app_server`, `loopex_protocol`, `loopex_daemon`, `loopex_cli` | Pending | Pending |
| Long-duration bounds: `loopex`, `loopex_executor_local`, `loopex_daemon` | Pending | Pending |
| Cross-UID, exactly two | Pending | Pending |

### Fresh-source lane

| Field | Value |
| --- | --- |
| Archive manifest retained-output reference | Pending |
| Archive manifest SHA-256 | Pending |
| Source inventory retained-output reference | Pending |
| Source inventory SHA-256 | Pending |
| Extraction identity and `VERSION` | Pending |

### Attended real-provider demonstration

The two-process demonstration is the manifest's ninth row,
`apps/loopex_cli/test/multi_client_workflow_real_test.exs`: `loopex daemon`,
a CLI controller killed with `SIGKILL` and the Node observer taking over, each
its own operating-system process, the observer's prompt answered by the real
provider. Its summary line is retained from the release check's output.

| Field | Value |
| --- | --- |
| Provider | Pending |
| Model | Pending |
| Provider response identifiers | Pending |
| Takeover summary line | Pending |

### Full-population orderly stop

The `long_bound` measurement behind `teardown_ms`: 512 initialized, attached
connections. The current-pair value is filled from this release check's
long-duration lane. The floor-pair value is filled from a separate floor-pair
`long_bound` run, `env -u MIX_BUILD_PATH MIX_BUILD_ROOT="/absolute/retained-work/M5-otp27-build" mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- mix test --only long_bound`
in `apps/loopex_daemon` at the tested revision, whose retained output and
SHA-256 are recorded beside it.

| Toolchain | Elapsed |
| --- | --- |
| Floor pair (Elixir 1.18.5 / OTP 27.3.4), from the floor-pair `long_bound` run | Pending |
| Floor-pair `long_bound` run: retained-output reference and SHA-256 | Pending |
| Current pair, from this release check's long-duration lane | Pending |

### Process RSS beside the retained-payload ceilings

The output ceilings bound retained payload, not memory, so the `long_bound`
lane reports the VM's resident size separately at the full attachment count
(`maximum-population RSS:` line) and at payload pressure, with 508 MiB of queued
output held against the 512 MiB aggregate commitment (`payload-pressure RSS:`
line). The values are reported, not asserted, and are filled from this
release check's long-duration lane output.

| Measurement | Value |
| --- | --- |
| RSS at 512 connections and 512 attachments | Pending |
| RSS before and at 508 MiB retained output | Pending |

### Step durations at the full population (T15)

The `long_bound` lane traces every collaboration-owner step at 512 connections
while the owner is under load: grants, releases and lease-owner losses run in
the middle of two bursts of 252 concurrent refused acquires. It prints one
`maximum-population steps:` line per step class — registry, relay, lease owner
and connection — with its count, p50, p99 and maximum in milliseconds. The
owner's deadline path is traced too, and a step that reaches it counts as at
least 5,000 ms, so the test fails if any class is unsampled or any step
reaches its 5,000 ms instant; the distribution is judged before the workload's
replies and the exit status. Filled from this release check's long-duration
lane output.

| Step class | Count, p50, p99, maximum |
| --- | --- |
| Registry | Pending |
| Relay | Pending |
| Lease owner | Pending |
| Connection (holder close) | Pending |

## Outcome 6 security review

Filled from the independent security review of Outcome 6 that the maintainer
commissions against the tested revision; it is not produced by any check
command.

| Field | Value |
| --- | --- |
| Reviewer | Pending |
| Revision reviewed | Pending |
| Result | Pending |
| Retained-report reference | Pending |
| SHA-256 | Pending |

## Independent review of the candidate

| Field | Value |
| --- | --- |
| Revision reviewed | Pending |
| Result | Pending |
| Retained-report reference | Pending |
| SHA-256 | Pending |

## Documentation checklist

Every tracked file under `docs/operator` and `docs/developer`, derived with
`git ls-files -- docs/operator docs/developer` at the tested revision, sorted,
each marked *updated* or *reviewed unchanged*, plus the separate
`DEVELOPMENT.md` row the plan predeclares.

| Field | Value |
| --- | --- |
| Derived count | Pending |
| Checklist retained-output reference | Pending |
| SHA-256 | Pending |
| `DEVELOPMENT.md` reviewed against the implemented lanes | Pending |
