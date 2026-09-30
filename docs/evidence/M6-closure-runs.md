# M6 closure runs

This is the indexed evidence scaffold for the M6 tested implementation
candidate. It reserves the results and identities the closure matrix, two
platform demonstrations, security review and independent review will produce
after that exact commit exists. Complete immutable outputs stay outside the
repository; the administrative direct child may fill only the `Pending` values
already declared here. Back to the [evidence index](README.md).

## Candidate and source identity

| Field | Value |
| --- | --- |
| Tested implementation SHA | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`; references below are relative to `/Users/spuri/projects/lexlapax/loopex-evidence/M6/` |
| Source `VERSION` | `0.3.0` |
| Administrative closure SHA | Located by the plans register's `Closed` transition and the tag; this page cannot name its own commit |
| `v0.2.0` rollback source SHA | `3f81b04828901a6fb05b29e8b6bed211eed2d376` |
| Core runtime comparison against `v0.2.0` | PASS: runtime-library diff empty outside Mix tasks; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/lock-and-core-comparison.md`; SHA-256 `741373aa427bc302b7f99197b96faf9acc09b21da1490b571fbf12d5615b629c` |
| Independent `v0.2.0`–candidate `mix.lock` package-key comparison | PASS: 22 sorted package keys equal at tested SHA `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`; retained lists `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/baseline-package-keys.txt` and `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/candidate-package-keys.txt` each SHA-256 `d93ebb2fef2dfb325a0f110662f524dae19b6965a1a88c08dd42e9efb1c29cb8`; comparison `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/lock-and-core-comparison.md` SHA-256 `741373aa427bc302b7f99197b96faf9acc09b21da1490b571fbf12d5615b629c` |

The core runtime comparison value records its result, retained-output
reference and SHA-256. The package-key comparison value records its result,
tested candidate SHA, retained sorted-key lists, comparison-output reference
and SHA-256. These fixed requirements remain outside the fillable cells.

## Fast-check matrix

Each complete run records its exact source revision, platform, OTP/Elixir
pair, result, measured duration, retained-output reference and SHA-256.
The default closure rule takes a current-pair CI run of the exact candidate,
or a clean local run of the same fast check. For M6 only, the
[approved reuse disposition](../developer/agent-context-map.md#disposition-m6-evidence-reuse-2026-09-29)
allows a successful earlier run to cover unchanged code after the intervening
diff and affected or missing checks are verified. Every cell names its actual
revision; no reused run is represented as an exact-candidate execution.

| Run | Revision | Platform and toolchain | Result and duration | Retained-output reference | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| Floor `bash scripts/check.sh` on Darwin | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19` | Darwin; OTP 27.3.4 / Elixir 1.18.5 | PASS; check 1,555 s, floor lane 2,195 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/darwin-floor/check.log` | `b815d0ad8455b58440a71acb0dc1c4f001e73de8ea5043141d48f8b4ddb954fe` |
| Floor `bash scripts/check.sh` on Linux | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19` | Linux; OTP 27.3.4 / Elixir 1.18.5 | PASS; check 1,380 s, floor lane 2,018 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-floor/check.log` | `650e1530eeb0099e0c3341319a3e72926beb2c6cf78bc9644b14cdd0ff993bc4` |
| Current-pair `bash scripts/check.sh` (CI or local) | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19` | Linux; OTP 29.0.5 / Elixir 1.20.3 | PASS; 872.538 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/current-fast.log` | `1edfacc983cdf9592e2273b6091f112b1d75db5dd5f8ec4d7ce331f4877a1bcb` |
| Floor `--long-bound` transport drain on Darwin | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19` | Darwin; OTP 27.3.4 / Elixir 1.18.5 | PASS; three groups measured 582 + 28 + 26 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/darwin-floor/long-bound.log` | `c4e7b39db9bfcb8b8df03d9465efc26b6066c8f78bbb0e3ba83375d98720f2c4` |
| Floor `--long-bound` transport drain on Linux | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19` | Linux; OTP 27.3.4 / Elixir 1.18.5 | PASS; three groups measured 583 + 28 + 25 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-floor/long-bound.log` | `b31791777ee926a46490524eca9994167eba67b6f92b8655bb22e7425f034c74` |

## Approved evidence-reuse reconciliation

These fields bind the exceptional proof to the tested implementation SHA.
The administrative closure commit fills only the reserved values; it does not
add a new result, reference or digest field after the candidate was tested.

| Proof | Actual revisions and result | Retained-output reference | SHA-256 |
| --- | --- | --- | --- |
| Complete intervening diff from the reused integration candidate to the tested implementation candidate | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19` → `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`; six paths; PASS `git diff --check` | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/intervening.diff`; path list `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/intervening-paths.txt` | `61ef70f567cdbd260402deadb46b1b28862cfbd5ec5d9a79230ecf2b90706e2b`; paths `d4c9166f4b0eeedb37dcd8d09aa4c1e452b35f4835f7ec7895bf7a1c86dae1c5` |
| Unchanged production code, dependency lock and core runtime comparison across that diff | PASS; application `lib` paths and `mix.lock` unchanged; core runtime equals `v0.2.0` outside Mix tasks | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/verification-reconciliation.md`; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/lock-and-core-comparison.md` | `8d848364ad69ab28832baee808a231cacacb99152a9ea93c61d9cd84ab74f519`; `741373aa427bc302b7f99197b96faf9acc09b21da1490b571fbf12d5615b629c` |
| Affected and missing focused checks, including the corrected cross-UID fixture, rollback, demonstration oracle and documentation/examples | PASS: cross-UID at `be272ea380a0b921b6570b6e0bda95f4ad5b9da4`; rollback and ten examples at `1a78a1fc532b1b590a4d0210ac978b9523010c11`; oracle fixture and docs at `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3` | `be272ea380a0b921b6570b6e0bda95f4ad5b9da4/cross-uid-077-fix.log`; `1a78a1fc532b1b590a4d0210ac978b9523010c11/rollback-retain/rollback.log`; `1a78a1fc532b1b590a4d0210ac978b9523010c11/documentation-examples-1a78a1fc-run.log`; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/demonstration-fixture.log`; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/docs-check.log` | `e6e46d4af383c5e3561ee76fed2a09a532c206708078b605d9feab0566e379dd`; `ecf2049e5a728b180ce6e8f25c82aa02b199b670dbf2aa8280c648303d812177`; `8fac17b289e0aad8709135dc4b6c1ab6fa1bdf7071b1b3058f526aaa4486a6fc`; `f036253cecfc90f91fed64a33c1027c98ff75ac088fee550227aab281b7faf8e`; `114b0bd598e8e21eebe8c5c364b6bb30671720155c265c81e0276e0fa4af9fef` |
| Reused successful check inventory and excluded failed-run inventory, each with its actual revision | PASS inventory at `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`; failed full release run and earlier demonstrations remain failures; reconciliation at `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3` | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/verification-reconciliation.md`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-redacted.log` | `8d848364ad69ab28832baee808a231cacacb99152a9ea93c61d9cd84ab74f519`; `9af585a099959792ffde8f9003a7a1fbce607ccf57afed237380cfb029e60880` |

## Current-pair release check on Linux and approved evidence reuse

`LOOPEX_CROSS_UID_USER=<second user> bash scripts/check-release.sh` ran once
from a clean M6 integration candidate, with the provider credential, pinned
Node and the required attended answers. Its actual result and every executed
lane's complete output are retained separately; a failed full run is never
relabeled `PASS`.

For M6 only, the maintainer's
[evidence-reuse disposition](../developer/agent-context-map.md#disposition-m6-evidence-reuse-2026-09-29)
replaces the single exact-candidate full-run `PASS` requirement with successful
unchanged-code evidence, a verified intervening diff, and affected or missing
checks at their actual revisions. The rows below record both the original run
and the disposition; they do not assert that the full runner passed.

| Field | Value |
| --- | --- |
| Revision, platform, OTP/Elixir and Node | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`; Linux x86_64; current OTP 29.0.5 / Elixir 1.20.3; pinned Node executed, version not recorded in retained runner output |
| Final line and exit status | FAIL: `ATTENDED_FAILURE=release_check_failed`, `EVIDENCE_EXIT=1`; cross-UID RED; all eleven provider, four Node and four long-bound groups preceding it passed; rollback not reached |
| Measured duration | 1,507.476 s outer wrapper; 1,507 s runner |
| Complete-output reference and SHA-256 | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-redacted.log` SHA-256 `9af585a099959792ffde8f9003a7a1fbce607ccf57afed237380cfb029e60880`; wrapper `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-wrapper.log` SHA-256 `a97cd32deb146566d5ccc97d254ab703a96e04a2e9b32c6b594e2f88c429abc9` |
| Cross-UID second-user identity and two-case result | A distinct `LOOPEX_CROSS_UID_USER` was configured; its account name is not in the retained redacted transcript. Original two-case group failed at `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`; corrected two-case fixture passed under umask 077 at `be272ea380a0b921b6570b6e0bda95f4ad5b9da4` (`cross-uid-077-fix.log`, SHA-256 `e6e46d4af383c5e3561ee76fed2a09a532c206708078b605d9feab0566e379dd`) |
| Attended answer authority, transcript reference and SHA-256 | Strict descendant `f9736632cd84d3c2f99390545ea0527ff6872351` authorized answers for tested `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-redacted.log.attended.authority` SHA-256 `00ad845bbfb47a0d80f5238b41cf6d693fadbf57729a03668b668aad30e836cb`; transcript `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-redacted.log.attended` SHA-256 `d2e7648712fdfadfef0ce51e12d7831a7adf3f7a5dbcb1e0d15863e4b9727607` |

| Release lane | Executed/result | Retained-output reference | SHA-256 |
| --- | --- | --- | --- |
| Real provider 1: pinned Git skill workflow | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 120 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-1.log` | `8adf8699e07e239a282b00ebd521829f7351fcf61ead127b7b0d451fd26e774d` |
| Real provider 2: coding task | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 56 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-2.log` | `2de2bd29a4607e3c8674d682bb04063e37ede5628c7b10156d0c7bf0da724192` |
| Real provider 3: provider response identity and usage | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 39 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-3.log` | `d0d9961c70eebf5ade528373b00589b28c3268530ac5adb38b34ac4953ba6f69` |
| Real provider 4: app-server external workflow | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 87 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-4.log` | `b61c6caa67da8a6a52cf4b3dc8ce983ac344494903a4ec5041368ba513f8428a` |
| Real provider 5: model boundary | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 41 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-5.log` | `c93ef6db6901d11583ecca33ddca04657d16e913cc8ae04b484d3bfc3066e05a` |
| Real provider 6: killed-tree receipt recovery | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 60 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-6.log` | `b902888e5850650040b260620d6e2f9b558f51affc59df7b4954c99fe1dd87e8` |
| Real provider 7: canonical session request | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 43 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-7.log` | `58a92fcb7d0e378b5d8aedea095ab71ddeee28b57b3fbe26f74673847c0ce3b9` |
| Real provider 8: daemon socket workflow | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 56 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-8.log` | `fe79ee7add60df6cc9d2fff1705737d047c760f76be9cf5cba91e6a340ad8667` |
| Real provider 9: Node takeover | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 86 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-9.log` | `7df1b2f823fb7aa01e1bc700f524b46cb52fbcca190cc792a5defa0ec9b12b20` |
| Real provider 10: separate-process local Ollama `ask` | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 11 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-10.log` | `75c0eea7b05cbffea260949c0e23c1d62a59b211dfc675795b1df476e3f464a4` |
| Real provider 11: embedded in-process Anthropic | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: 1 executed, PASS, 4 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/real-provider-11.log` | `772cc804efefeb80a9f5e7f5d18e83ef31ff30ad1c1c692764d5dec0079a7ca2` |
| Node client, four applications | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: PASS, app server 4/48 s, protocol 1/1 s, daemon 1/38 s, CLI 1/38 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/node-client-loopex_app_server.log`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/node-client-loopex_protocol.log`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/node-client-loopex_daemon.log`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/node-client-loopex_cli.log` | app server `43d840d61799b4a5761563d83b668e2471b8001fbaeaaa773343de34debf5cce`; protocol `92472fa066f337593685b61e63e2e386042e08bdaf2cfccffab29b4da0342be8`; daemon `22f0770a630c9bfabdcbab34a777b3be99fc739143ac73fac01bef21cc07664a`; CLI `0f4dd6602bb926668bdd687e1616743624e5dc9ee4d6df42d4d117f21fc26c31` |
| Long bounds, including current-pair transport drain | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: PASS, core 5/583 s, executor 2/28 s, daemon 5/25 s, ReqLLM 1/1 s | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/long-bound-loopex.log`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/long-bound-loopex_executor_local.log`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/long-bound-loopex_daemon.log`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/long-bound-loopex_llm_reqllm.log` | core `77adcfa0a9d57eb4c17cfede5c335f4e7b94b481915eb8f8f68cad7f1d78198f`; executor `cf6ce4bb6b840601bb9256e2a70cc6830d7d2a6c040fb4f58dbd882f65457622`; daemon `96774eb2d8840284b3ede2824aa0849e430a3fd60e6abb06be6068711e13e134`; ReqLLM `63758c981bfb3e72bbe45a2c619d30799cf9fe15aa7abd421f5ef9805ace58e2` |
| Cross-UID, two cases | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`: RED; corrected fixture at `be272ea380a0b921b6570b6e0bda95f4ad5b9da4`: PASS, 2/2 under umask 077 | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/cross-uid.log`; `be272ea380a0b921b6570b6e0bda95f4ad5b9da4/cross-uid-077-fix.log` | `6686f9cf8e715ca7457f99aa6e2f3d3cf9c3d8e3db21e3429e896c5f6dc202b9`; `e6e46d4af383c5e3561ee76fed2a09a532c206708078b605d9feab0566e379dd` |
| Rollback against pristine `v0.2.0` and candidate archives | Not reached by failed full run at `3ddeca3f8fb753cd7378bc92f33243fdd38acc19`; selected lane at `1a78a1fc532b1b590a4d0210ac978b9523010c11`: PASS, 110 s | `1a78a1fc532b1b590a4d0210ac978b9523010c11/rollback-retain/rollback.log` | `ecf2049e5a728b180ce6e8f25c82aa02b199b670dbf2aa8280c648303d812177` |

### Fresh-source and rollback archive identities

Retain the exact NUL-delimited manifest bytes outside each extraction. Both
archive projections must match independently enumerated archive members and
Git-tree modes before document exclusions. The administrative comparison is a
separate pre-tag proof after closure. Its result, complete-patch reference and
digests belong in the later release tag annotation. They are not closure
placeholders because the comparison cannot run until the administrative commit
exists.

| Artifact or check | Source SHA or result | Retained-output reference | SHA-256 |
| --- | --- | --- | --- |
| Candidate archive bytes and source identity | Tested SHA `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`, version `0.3.0` | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/candidate.archive.tar`; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/source-archive-manifest.source-identity` | archive `a742a168fa28bf9c43da07acac4bec2684b38a7be39d35bfc0f509cb7aee21c5`; identity `62087ce50d1b3589c341b66dbaec05314c86e842b0b9693db4c97dd7badfeddb` |
| Candidate source-archive manifest, exact bytes | NUL-delimited bytes retained for tested SHA `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3` | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/source-archive-manifest` | `5480bee329473f903bb143d814bde104829b2541cbb014e83f56f524bdbbcbca` |
| Candidate source inventory and Git-tree projection | PASS: archive inventory and independent Git-tree projection match before exclusions | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/source-inventory`; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/candidate.projection` | inventory `9d89757bee711b925ea44b9ecc30c64dd539a61cdb1e23139bc197c50fd00cd4`; projection `e402840286539f74da96cc1170d0da0d183038357fef4908eb64b2033f62287e` |
| Pristine `v0.2.0` rollback archive bytes and source identity | Source `3f81b04828901a6fb05b29e8b6bed211eed2d376` | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/rollback-old.archive.tar`; `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/rollback-old.identity` | archive `e9591aada4e138fd6b71806333ef228cbb145d1aab575f09dc4cd4eb5c070e50`; identity `00ae103fa8daf4b5ef1181d594112875e968574424152f7e6c5788ad3b715ad7` |
| `v0.2.0` rollback Git-tree projection | PASS: independently enumerated pristine `v0.2.0` archive and Git-tree projection | `3ddeca3f8fb753cd7378bc92f33243fdd38acc19/linux-matrix/release-retain/rollback-old.projection` | `2c834ffc2644fdf2f72f0eddc54142388a8d8e75314eb435a1171693a5c1bc6e` |
| Archive staging output and scoped umask values | PASS: caller umask 0777, extraction umask 0022; nine self-checks on tested candidate | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/archive-self-check.log` | `45368dca422d45bde46d8566cb455430617a848c942c896f74f04df956f5e59d` |
| Rollback two-direction interaction, unknown tool, dispatched effects, skill and daemon results | PASS at `1a78a1fc532b1b590a4d0210ac978b9523010c11`; selected lane 110 s; pristine `v0.2.0` versus then-candidate archive, not the final exact-candidate archive | `1a78a1fc532b1b590a4d0210ac978b9523010c11/rollback-retain/rollback.log` | `ecf2049e5a728b180ce6e8f25c82aa02b199b670dbf2aa8280c648303d812177` |

## Four-step acceptance demonstration

`scripts/m6-demonstration.sh` runs once per platform from a clean checkout
with no `LOOPEX_HOME`. Each platform's complete transcript, result and duration
is retained; each of its four steps prints its own result and elapsed time.

| Platform | Tested SHA and toolchain | Four-step result and measured duration | Retained-output reference | SHA-256 |
| --- | --- | --- | --- | --- |
| Darwin | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`; Elixir 1.20.3; OTP version not independently recorded in transcript | PASS 4/4; `EVIDENCE_EXIT=0`; 44.649 s; actual workspace artifacts retained in `darwin-workspace/` | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/darwin-demonstration.log`; artifact inventory `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/workspace-artifacts-manifest.log` | log `f877e1d8b4536ddea73dfb9a7262287c3f644240861647708cf32376650a1825`; inventory `0307cb644c77b001c144618bea5712163316c710eeb797c63b90da5b2b0289b9` |
| Linux | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`; Elixir 1.20.3; OTP version not independently recorded in transcript | PASS 4/4; `EVIDENCE_EXIT=0`; 38.271 s; actual workspace artifacts retained in `linux-workspace/` | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/linux-demonstration.log`; artifact inventory `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/workspace-artifacts-manifest.log` | log `cb7d46f1abbdb12c491fb2c5622d699b010792b609c5f476da70e69697942796`; inventory `0307cb644c77b001c144618bea5712163316c710eeb797c63b90da5b2b0289b9` |

## Outcome 2 security review

An independent fresh-context read-only reviewer assesses the in-VM credential
audience, provider-controlled reply rejection, hosted tool use, transport and
cleanup proofs, session-local seals, catalog trust scope, and release-only
socket/TLS drain witness. This is a review of the tested SHA, not a claim of
heap erasure or same-user tool isolation.

| Field | Value |
| --- | --- |
| Reviewer and tested SHA | Fresh-context read-only `/root/m6_security_delta_review`; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3` |
| Result and notes disposition | READY; correction confirms both demonstration transcripts carry `EVIDENCE_EXIT=0`; earlier security reports and named trust limits remain in force |
| Retained complete-report reference | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/security-review.md` |
| SHA-256 | `a5c322fb8b6df23979d7d708f124dd89f1fc39c0538a9c4816a5b17a629fb3d7` |

## Independent candidate review

| Field | Value |
| --- | --- |
| Reviewer and tested SHA | Independent external post-implementation reviewer, supplied by maintainer; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`; internal fresh-context `/root/m6_delta_audit` also reviewed that SHA |
| Result and notes disposition | External ACCEPT WITH NOTES for implementation and closure evidence, no blocker; notes on proof strength and search-tool behavior retained without upgrading guarantees; internal candidate review READY |
| Retained complete-report reference | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/external-postimplementation-review.txt`; `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/candidate-review.md` |
| SHA-256 | external `6f99bee199ecf22ec4b41ea697dccf60e5e93b748bb802ba7ffbc5d0c1eb3c7c`; internal `cdd3567e22c2a6e2989df3fed15c54b514c96eed2ed982c9fba25cfa5fd1ec77` |

## Semantic documentation review

The checklist covers the existing operator and developer pages named in
[the plan](../plans/M6-technical.md#technical-plan-evidence), both getting-started
paths and their examples, the root README and changelog. Each affected page is
marked updated or reviewed unchanged against the tested candidate.

| Field | Value |
| --- | --- |
| Tested SHA and derived path count | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`; 21 operator/developer product pages byte-identical to reviewed `3ddeca3f8fb753cd7378bc92f33243fdd38acc19` |
| Example execution result | PASS: ten operator/developer examples at `1a78a1fc532b1b590a4d0210ac978b9523010c11`; exact-candidate docs check PASS in 17 s |
| Complete checklist retained-output reference | `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/semantic-docs-review.md`; mapping `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3/semantic-docs-reuse.log`; examples `1a78a1fc532b1b590a4d0210ac978b9523010c11/documentation-examples-1a78a1fc-run.log` |
| SHA-256 | checklist `bbdd9b42cb6dd35254d20dcdf1189312fceb410c570af16b4254798d6274253c`; mapping `ac813c5daa5d91c2d7513e96a916656bd23ad88c19d85ed53875a11ff16cb02c`; examples `8fac17b289e0aad8709135dc4b6c1ab6fa1bdf7071b1b3058f526aaa4486a6fc` |
