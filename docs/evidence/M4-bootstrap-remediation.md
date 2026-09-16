# M4 Bootstrap Remediation

Retained as the replacement evidence named by the M4 bootstrap-at-rebind
disposition in the [context map](../developer/agent-context-map.md#override-disposition-m4-bootstrap-at-rebind-2026-09-15).
The Amendment 7 rebind could not pass `scripts/check-bootstrap.sh` at its own
bytes; this is a complete green run of that aggregate on the `m4`
branch after the commit-title exception landed, taken inside the full M4 gate
and copied here verbatim. The same gate run's inherited-gates lane exited
non-zero on a pre-existing Closed M0 defect, so this record proves the
bootstrap aggregate and nothing beyond it.

- run taken at: `08782a0873a2438fbfedb6ab5a3ecfc73c9c7217`, 2026-09-15
- invoked by: `scripts/check-m4-gate.sh` as its bootstrap step
- result: exit 0 after 2342 seconds
- segment digest: `sha256:c81e881ffc1a1067c7b6efb8e7b016795addbacc8d76354fd608cd99754c8b11` (the fenced block below, exactly)
- gate source line, as emitted:

```
LOOPEX_M4_SOURCE sha=08782a0873a2438fbfedb6ab5a3ecfc73c9c7217 working_digest=sha256:00b0c2f4ceb7d0f3fdf6bae0942fa14c1d897ed41d6bf0ef39f95e8bfc4cba2e seed=3107 elixir=1.20.3 otp=29.0.5 erts=17.0.5 platform=aarch64-apple-darwin25.6.0
```

## Bootstrap segment

```
M4 gate step: env LOOPEX_M3_BOOTSTRAP_ACTIVE=1 LOOPEX_M3_BOOTSTRAP_SENTINEL_FD=9 bash scripts/check-bootstrap.sh
client adapters defer to the canonical contract
agent bootstrap check passed
gitignore check passed
commit message check passed (baseline e0354862fedde5939d7797c2adbf338d987ff538)
18100cafaefd3b6f3fbb73757b590287908738c7: title length waived by recorded M4 maintainer disposition
7bb2a9bd2e33e159a3ed7441a1ad3d0445cda954: title length waived by recorded M4 maintainer disposition
9905a870d7363e93b808459e89cd57865ffc72ee: title length waived by recorded M4 maintainer disposition
2e06da13ee01391690c1731edbf6190ab4471f1c: title length waived by recorded M4 maintainer disposition
d2a916552209408019df8acf83ef5cc5ca3bf0a9: title length waived by recorded M4 maintainer disposition
20fcec3d0e499eacde3599b8fdb41a460c0a5c8b: title length waived by recorded M4 maintainer disposition
3eaeaafb0cb1af6135dccb64d63354944cb1b301: title grammar/length waived by recorded M3 maintainer disposition
2dc0ad4ede416da068004b14333b26441a973f2f: title grammar/length waived by recorded M3 maintainer disposition
2f2dce216cdb63c7387073d8834e756c759ba5c6: title grammar/length waived by recorded M3 maintainer disposition
262ad1a04274a0b52e19484e76c621842f158676: title grammar/length waived by recorded M3 maintainer disposition
9f742e52d32115c8dedd5c2df47d549a60e86777: title grammar/length waived by recorded M3 maintainer disposition
3c8dcc1bc4951d35f6cdee4e695e9682e8bc53db: title grammar/length waived by recorded M3 maintainer disposition
cdc086900515e1bd4d890bb7c62ab3de846ef6fa: title grammar/length waived by recorded M3 maintainer disposition
461d44dc004740110231a459c8359efe407d09e6: title grammar/length waived by recorded M3 maintainer disposition
repo hygiene check passed (against origin/main)
==> loopex
Running ExUnit with seed: 174307, max_cases: 40

........................................................................................
Finished in 37.1 seconds (37.1s async, 0.00s sync)

Result: 88 passed
status check passed
LOOPEX_M4_LANE name=env LOOPEX_M3_BOOTSTRAP_ACTIVE=1 LOOPEX_M3_BOOTSTRAP_SENTINEL_FD=9 bash scripts/check-bootstrap.sh elapsed_seconds=2342 exit=0
```
