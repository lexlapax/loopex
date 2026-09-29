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
| Tested implementation SHA | Pending |
| Source `VERSION` | `0.3.0` |
| Administrative closure SHA | Located by the plans register's `Closed` transition and the tag; this page cannot name its own commit |
| `v0.2.0` rollback source SHA | `3f81b04828901a6fb05b29e8b6bed211eed2d376` |
| Core runtime comparison against `v0.2.0` | Pending |
| Independent `v0.2.0`–candidate `mix.lock` package-key comparison | Pending |

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
| Floor `bash scripts/check.sh` on Darwin | Pending | Pending | Pending | Pending | Pending |
| Floor `bash scripts/check.sh` on Linux | Pending | Pending | Pending | Pending | Pending |
| Current-pair `bash scripts/check.sh` (CI or local) | Pending | Pending | Pending | Pending | Pending |
| Floor `--long-bound` transport drain on Darwin | Pending | Pending | Pending | Pending | Pending |
| Floor `--long-bound` transport drain on Linux | Pending | Pending | Pending | Pending | Pending |

## Approved evidence-reuse reconciliation

These fields bind the exceptional proof to the tested implementation SHA.
The administrative closure commit fills only the reserved values; it does not
add a new result, reference or digest field after the candidate was tested.

| Proof | Actual revisions and result | Retained-output reference | SHA-256 |
| --- | --- | --- | --- |
| Complete intervening diff from the reused integration candidate to the tested implementation candidate | Pending | Pending | Pending |
| Unchanged production code, dependency lock and core runtime comparison across that diff | Pending | Pending | Pending |
| Affected and missing focused checks, including the corrected cross-UID fixture, rollback, demonstration oracle and documentation/examples | Pending | Pending | Pending |
| Reused successful check inventory and excluded failed-run inventory, each with its actual revision | Pending | Pending | Pending |

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
| Revision, platform, OTP/Elixir and Node | Pending |
| Final line and exit status | Pending |
| Measured duration | Pending |
| Complete-output reference and SHA-256 | Pending |
| Cross-UID second-user identity and two-case result | Pending |
| Attended answer authority, transcript reference and SHA-256 | Pending |

| Release lane | Executed/result | Retained-output reference | SHA-256 |
| --- | --- | --- | --- |
| Real provider 1: pinned Git skill workflow | Pending | Pending | Pending |
| Real provider 2: coding task | Pending | Pending | Pending |
| Real provider 3: provider response identity and usage | Pending | Pending | Pending |
| Real provider 4: app-server external workflow | Pending | Pending | Pending |
| Real provider 5: model boundary | Pending | Pending | Pending |
| Real provider 6: killed-tree receipt recovery | Pending | Pending | Pending |
| Real provider 7: canonical session request | Pending | Pending | Pending |
| Real provider 8: daemon socket workflow | Pending | Pending | Pending |
| Real provider 9: Node takeover | Pending | Pending | Pending |
| Real provider 10: separate-process local Ollama `ask` | Pending | Pending | Pending |
| Real provider 11: embedded in-process Anthropic | Pending | Pending | Pending |
| Node client, four applications | Pending | Pending | Pending |
| Long bounds, including current-pair transport drain | Pending | Pending | Pending |
| Cross-UID, two cases | Pending | Pending | Pending |
| Rollback against pristine `v0.2.0` and candidate archives | Pending | Pending | Pending |

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
| Candidate archive bytes and source identity | Pending | Pending | Pending |
| Candidate source-archive manifest, exact bytes | Pending | Pending | Pending |
| Candidate source inventory and Git-tree projection | Pending | Pending | Pending |
| Pristine `v0.2.0` rollback archive bytes and source identity | Pending | Pending | Pending |
| `v0.2.0` rollback Git-tree projection | Pending | Pending | Pending |
| Archive staging output and scoped umask values | Pending | Pending | Pending |
| Rollback two-direction interaction, unknown tool, dispatched effects, skill and daemon results | Pending | Pending | Pending |

## Four-step acceptance demonstration

`scripts/m6-demonstration.sh` runs once per platform from a clean checkout
with no `LOOPEX_HOME`. Each platform's complete transcript, result and duration
is retained; each of its four steps prints its own result and elapsed time.

| Platform | Tested SHA and toolchain | Four-step result and measured duration | Retained-output reference | SHA-256 |
| --- | --- | --- | --- | --- |
| Darwin | Pending | Pending | Pending | Pending |
| Linux | Pending | Pending | Pending | Pending |

## Outcome 2 security review

An independent fresh-context read-only reviewer assesses the in-VM credential
audience, provider-controlled reply rejection, hosted tool use, transport and
cleanup proofs, session-local seals, catalog trust scope, and release-only
socket/TLS drain witness. This is a review of the tested SHA, not a claim of
heap erasure or same-user tool isolation.

| Field | Value |
| --- | --- |
| Reviewer and tested SHA | Pending |
| Result and notes disposition | Pending |
| Retained complete-report reference | Pending |
| SHA-256 | Pending |

## Independent candidate review

| Field | Value |
| --- | --- |
| Reviewer and tested SHA | Pending |
| Result and notes disposition | Pending |
| Retained complete-report reference | Pending |
| SHA-256 | Pending |

## Semantic documentation review

The checklist covers the existing operator and developer pages named in
[the plan](../plans/M6-technical.md#technical-plan-evidence), both getting-started
paths and their examples, the root README and changelog. Each affected page is
marked updated or reviewed unchanged against the tested candidate.

| Field | Value |
| --- | --- |
| Tested SHA and derived path count | Pending |
| Example execution result | Pending |
| Complete checklist retained-output reference | Pending |
| SHA-256 | Pending |
