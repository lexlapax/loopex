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
| Administrative closure SHA | Pending |

## The fast check under the floor pair, on Darwin

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
line; `PASS (closure-incomplete: cross_uid not run)` is not that.

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
| Real-provider manifest, eight rows | Pending | Pending |
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

| Field | Value |
| --- | --- |
| Provider | Pending |
| Model | Pending |
| Provider response identifiers | Pending |

### Full-population orderly stop

The `long_bound` measurement behind `teardown_ms`: 512 initialized, attached
connections.

| Toolchain | Elapsed |
| --- | --- |
| Floor pair (Elixir 1.18.5 / OTP 27.3.4) | Pending |
| Current pair | Pending |

## Outcome 6 security review

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
