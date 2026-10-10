# M7 coding fixtures

The accepted [M7 task catalog](../../../docs/plans/M7-technical.md#technical-plan-evidence)
owns these four tasks. `manifest.json` pins the retained seeds and independent
oracles, literal task prompts, the accepted baseline run bounds, allowed changes,
objective results and required question/helper actions.

Copy only a task's `workspace/` into its disposable writable tree. Keep its
oracle and this catalog in the trusted harness tree. Resolve the invocation's
`{oracle}` and `{workspace}` from those separate roots; feature selects
`M7_NIL_DEFAULT` from the committed question answer, and review supplies the
retained TSV finding through `M7_FINDING`. The fixture policy must approve the
resolved command, executable and scrubbed environment before execution.

The source validator checks all seed and oracle digests/modes. Check complete
workspace inventories and oracle identities before and after both the agent's
approved test invocation and the independent rerun. The review workspace has
no permitted changes. Repair and feature permit only their implementation file;
long permits only its two named output files.

The existing `M7FixtureTest` proves seeded failures, bounded repairs, both nil
defaults, the exact duplicate-fee finding and early-fact file assertions. These
are deterministic fixture checks. Required model actions must additionally join
committed runtime facts; long must join automatic/explicit checkpoints, raw
facts and restart.

`external` pins the maintainer-selected task: the `lapaxworks` repository at
its base commit, the single allowed path `tools/threads.py` and the
harness-owned Python oracle `external/oracle_test.py`, which never writes into
the checkout it judges. The trusted wrapper clones it disposably and never
pushes.

`execution_manifest` pins the attempts campaign and its genesis digest, the
three M7 lanes and their ordered cases, and one owner for every V1–V13 step
and subcase. Each attended case also pins the objective shown to its operator
and its finite ceilings: run, standalone-maintenance and question/tool-hold
counts at their per-unit ceilings, plus cleanup. Cases and owners marked `pending:` name what still blocks them;
a lane holding one cannot run. The catalog authorizes no provider attempt;
actual identities and outcomes live in retained execution records and the
attempts index. The [M7 validation runbook](../../../docs/operator/m7-validation.md)
shows the same mapping.

`execution_manifest.profiles` declares the closed set of demonstrated
reference profile keys, each with its `system_class_tokens` ceiling, and each
case lists the keys it stages: none for a case without a provider call. The
runner sets the attempt's session ceiling to the largest of its case's profile
ceilings and an enabled helper catalog's to the smallest. The plan target is
below 1,000; the [maintainer override](../../../docs/developer/agent-context-map.md#disposition-m7-reference-profile-target-2026-10-10)
admits 1,500 for `chat-coding` and `chat-coding-appendix` and 2,000 for
`chat-coding-helpers`. `M7ProfilesTest` measures every case's staged system
class at its real and a 512-byte workspace path and pins each key's preimage
digests.

`checkpoint-summary.json` is a separate, independently encoded compact UTF-8
rendering vector. Core pins its exact 325 bytes and SHA-256; the native adapter
checks that all nine mappings preserve it as user text in both transport modes.
It is no retained checkpoint or provider execution evidence.
