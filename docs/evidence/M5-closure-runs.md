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
| Tested implementation SHA | `fe020e24b62504f6f2fbc6c81711f399803b6fa9`; its runs below are of `9045835d8847a1c8a557e985a9a014e6b213f323`, which it changes only in Markdown, reused under the maintainer's documentation-only decision ([closure disposition](../developer/agent-context-map.md#disposition-m5-closure-2026-09-26)) |
| Source `VERSION` | `0.2.0` |
| Administrative closure SHA | Not recorded on this page: a commit cannot contain its own hash. It is located by the plans register's `Closed` transition and by the tag |

## The fast check under the floor pair, on Darwin

`env -u MIX_BUILD_PATH MIX_BUILD_ROOT="/absolute/retained-work/M5-otp27-build" LOOPEX_CHECK_ALONE=loopex_llm_reqllm mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`

This run is the one that executes Darwin's `LOCAL_PEERCRED` decode and
fail-closed path and its 103/104-byte socket-path boundary.

| Field | Value |
| --- | --- |
| Revision | `9045835d8847a1c8a557e985a9a014e6b213f323`, reused for the tested `fe020e24` (documentation-only delta) |
| Platform | Darwin arm64, macOS 26.7.1 |
| Toolchain | Erlang/OTP 27.3.4 (erts 15.2.7), Elixir 1.18.5 |
| Result | PASS: `EXIT=0`, eleven applications green |
| Measured duration | 1,053 s |
| Retained-output reference | `serenity:~/loopex-retained-work/M5/floor-darwin-check-9045835d-1.log` |
| SHA-256 | `aab3953bab5d425b0b0d8ac08a35d7cafffbed0022034a991e8d9bac516f2947` |

## The fast check under the floor pair, on Linux (serenity)

`env -u MIX_BUILD_PATH MIX_BUILD_ROOT="/absolute/retained-work/M5-otp27-build" LOOPEX_CHECK_ALONE=loopex_llm_reqllm mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`

Both floor runs use this command. The provider suite runs with the host to itself before the other applications
share it, as hosted CI runs it. On serenity's twenty cores the default runs ten
suites at once, and the provider suite's child VMs then missed the product's
10 s deadline, just as they had on the hosted runner.

| Field | Value |
| --- | --- |
| Revision | `9045835d8847a1c8a557e985a9a014e6b213f323`, reused for the tested `fe020e24` (documentation-only delta) |
| Platform | Linux x86_64 (serenity), open-file soft limit 65,536 |
| Toolchain | Erlang/OTP 27.3.4 (erts 15.2.7), Elixir 1.18.5 |
| Result | PASS: `EXIT=0`, eleven applications green |
| Measured duration | 1,021 s |
| Retained-output reference | `serenity:~/loopex-retained-work/M5/floor-check-9045835d-1.log` |
| SHA-256 | `6c78a55709706933473743ac8cf5b5a945846741eb41523ce9b58443fdbe033c` |

## The fast check on the current pair, hosted CI

| Field | Value |
| --- | --- |
| Revision | `fe020e24b62504f6f2fbc6c81711f399803b6fa9` |
| Run | 36228439538 |
| Result | PASS: `bash scripts/check.sh --select` ran the full fast check |
| Measured duration | 23m29s (07:59:41Z–08:23:10Z); `check: PASS total=1387s` |

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
| Revision | `9045835d8847a1c8a557e985a9a014e6b213f323`, reused for the tested `fe020e24` (documentation-only delta) |
| Platform | Linux x86_64 (serenity), open-file soft limit 65,536 |
| Toolchain | Erlang/OTP 29.0.5, Elixir 1.20.3 |
| Node | 22.14.0 |
| Final line | `PASS` (driver: `RELEASE_EXIT=0 ATTENDED_ANSWERS=2`) |
| Measured duration | 1,436 s |
| Retained-output reference | `serenity:~/loopex-retained-work/M5/release-check-9045835d-PASS.log` |
| SHA-256 | `080348938163a3533beb5713e51a79ba8160542dc3cdea4d76055cebe0820fe0` |

| Lane | Executed | Result |
| --- | --- | --- |
| Real-provider manifest, nine rows | 9 of 9, each `executed=1` | PASS |
| Node client: `loopex_app_server`, `loopex_protocol`, `loopex_daemon`, `loopex_cli` | 4, 1, 1, 1 | PASS |
| Long-duration bounds: `loopex`, `loopex_executor_local`, `loopex_daemon` | 5, 2, 5 | PASS |
| Cross-UID, exactly two | 2 | PASS |

### Fresh-source lane

| Field | Value |
| --- | --- |
| Archive manifest retained-output reference | `serenity:~/loopex-retained-work/M5/release-9045835d-retained/source-archive-manifest` (the release lane at `9045835d`); tested-candidate manifest for the pre-tag comparison `serenity:~/loopex-retained-work/M5/source-archive-manifest-fe020e24`, 736 records, staged with caller umask `0777` and scoped umask `022` (`source-archive-manifest-fe020e24.umask`) |
| Archive manifest SHA-256 | `947f48cb935a2f5f5494af5f92c2b076885b50ccc17c05ed4eacb203427a7731`; tested-candidate manifest `72138900ea4e7778f7c04ad9defe4401239a2a6a7c323369fd802481ae4fb2f0` |
| Source inventory retained-output reference | `serenity:~/loopex-retained-work/M5/release-9045835d-retained/source-inventory` |
| Source inventory SHA-256 | `63ab95fd4e95c59ca321bbc9eac16e1ed88539b77bc92650b5c29fe8116dab3d` |
| Extraction identity and `VERSION` | `9045835d8847a1c8a557e985a9a014e6b213f323`, `0.2.0`; `source-archive-check: verified 733 records`; archive sha256 `93d0bcf4b79d722ca383312f17cac962a1c0b771303098960818d3a5043e91ac`; the build left the extraction unchanged |

### Attended real-provider demonstration

The two-process demonstration is the manifest's ninth row,
`apps/loopex_cli/test/multi_client_workflow_real_test.exs`: `loopex daemon`,
a CLI controller killed with `SIGKILL` and the Node observer taking over, each
its own operating-system process, the observer's prompt answered by the real
provider. Its summary line is retained from the release check's output.

| Field | Value |
| --- | --- |
| Provider | anthropic |
| Model | `claude-haiku-4-5-20251001` |
| Provider response identifiers | The ninth row's summary line prints none; the same run's M4 external real workflow row printed `req_011CfRUBGqP6f6f1ctv7KK8Y+req_011CfRUBUapMGVcgKoxRztjZ` |
| Takeover summary line | `real-provider takeover: {"granted":true,"prompt":"accepted","answered":true,"finished":true,"attempts":31}` |

### Full-population orderly stop

The `long_bound` measurement behind `teardown_ms`: 512 initialized, attached
connections. The current-pair value is filled from this release check's
long-duration lane. The floor-pair value is filled from a separate floor-pair
`long_bound` run, `env -u MIX_BUILD_PATH MIX_BUILD_ROOT="/absolute/retained-work/M5-otp27-build" mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- mix test --only long_bound`
in `apps/loopex_daemon` at the tested revision, whose retained output and
SHA-256 are recorded beside it. The run needs a soft open-file limit of at
least 4,096, raised as `scripts/check-release.sh` raises it (`ulimit -Sn 65536`,
or the hard limit when that is lower, and refusing below 4,096). The case holds both ends of 512
connections in one VM, so under a stock 1,024 limit the listener's accept fails
and the run is not evidence.

| Toolchain | Elapsed |
| --- | --- |
| Floor pair (Elixir 1.18.5 / OTP 27.3.4), from the floor-pair `long_bound` run | 56 ms (`elapsed_ms=56`, 512 connections and 512 attachments; `461 tests, 0 failures`) |
| Floor-pair `long_bound` run: retained-output reference and SHA-256 | `serenity:~/loopex-retained-work/M5/floor-long-bound-9045835d.log`, `5c37baf2f3c849374fed093dfce1243c6dfa848bc55169ca98a5490a7b3ffe7a` |
| Current pair, from this release check's long-duration lane | 87 ms (`elapsed_ms=87`, Elixir 1.20.3 / OTP 29) |

### Process RSS beside the retained-payload ceilings

The output ceilings bound retained payload, not memory, so the `long_bound`
lane reports the VM's resident size separately at the full attachment count
(`maximum-population RSS:` line) and at payload pressure, with 508 MiB of queued
output held against the 512 MiB aggregate commitment (`payload-pressure RSS:`
line). The values are reported, not asserted, and are filled from this
release check's long-duration lane output.

| Measurement | Value |
| --- | --- |
| RSS at 512 connections and 512 attachments | 355,128 KiB (OTP 29) |
| RSS before and at 508 MiB retained output | 601,208 KiB before, 964,196 KiB at 532,676,608 retained bytes against the 536,870,912 aggregate ceiling (OTP 29) |

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
| Registry | 20, 0 ms, 0 ms, 0 ms |
| Relay | 22, 0 ms, 3 ms, 3 ms |
| Lease owner | 10, 0 ms, 0 ms, 0 ms |
| Connection (holder close) | 2, 0 ms, 0 ms, 0 ms |

## Outcome 6 security review

Filled from the independent security review of Outcome 6 that the maintainer
commissions against the tested revision; it is not produced by any check
command.

| Field | Value |
| --- | --- |
| Reviewer | An independent, fresh-context, read-only reviewer, over the full `9aef2a9a` review and its addenda chain |
| Revision reviewed | `9045835d8847a1c8a557e985a9a014e6b213f323` (PASS; documentation-only since `db728a00`'s product change), reused for `fe020e24`, whose delta is Markdown only |
| Result | PASS, carrying earlier notes; no credential-plane finding open |
| Retained-report reference | `serenity:~/loopex-retained-work/M5/security-review-outcome6-9045835d.md` (chain: `-f2742c49`, `-bcace82b`, `-c16476ed`, `-db728a00`, `-9aef2a9a`) |
| SHA-256 | `05ca973a1b129fb33b01e9ee181e09cfbddf4708d03f73944b59a5fe7ee2e8be` |

## Independent review of the candidate

| Field | Value |
| --- | --- |
| Revision reviewed | `9045835d8847a1c8a557e985a9a014e6b213f323` (implementation), then the documentation pass at `bc39ba40` and `5f3fcc6d`, whose one should-fix `fe020e24` applies |
| Result | CLOSE WITH NOTES on the implementation; ACCEPT WITH NOTES on the documentation pass, with no outstanding objection to closure after the applied correction |
| Retained-report reference | `serenity:~/loopex-retained-work/M5/external-review-9045835d.md`, `external-review-docs-bc39ba40.md`, `external-review-docs-5f3fcc6d.md` |
| SHA-256 | `61b6a8f04f30d9c6bbaf61ff1a348ed71565c9b728f4dee32fbe5d872a0cff54`; `fd4ec885d07798d22e9b00a12f30a41952affe11e38aaa5b43beab5e493e0a5d`; `a68e4ed371bc7664863ef682a6f0cbb8506d735ae4f376b58fbf162669512bba` |

## Documentation checklist

Every tracked file under `docs/operator` and `docs/developer`, derived with
`git ls-files -- docs/operator docs/developer` at the tested revision, sorted,
each marked *updated* or *reviewed unchanged*, plus the separate
`DEVELOPMENT.md` row the plan predeclares.

| Field | Value |
| --- | --- |
| Derived count | 32 paths, all *updated* |
| Checklist retained-output reference | `serenity:~/loopex-retained-work/M5/documentation-checklist-fe020e24.txt` |
| SHA-256 | `c4532b53cfb866025cf9d727eb107335f36a6d694258a95fbc42ec0ea71a8651` |
| `DEVELOPMENT.md` reviewed against the implemented lanes | Yes; updated in the documentation pass (dependency roles), reviewed against `scripts/check.sh` and `scripts/check-release.sh` |
