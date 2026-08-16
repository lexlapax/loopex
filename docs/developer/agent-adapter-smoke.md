# Client Adapter Evidence

This log records what the current source proves about client loading and
development routing. A structural check proves configuration shape. A live
smoke proves only the behavior it actually exercised. Unavailable evidence is
never promoted to a pass.

The governing method is in [AGENTS.md](../../AGENTS.md), the current mapping is
in the [context map](agent-context-map.md), and the capability classes are
defined by the [Concept rule](development-charter.md#concept-capability-follows-consequence)
and [Technical depth](development-charter-technical.md#technical-capability-follows-consequence).

## 2026-08-16 — read-only review lane, positive and negative smoke

Four consecutive independent reviews reported `workspace-write` and were
therefore advisory rather than formal evidence under the review-environment
rule. The enforced lane was re-verified.

Invocation:

```sh
RUST_LOG=error codex exec -C . --sandbox read-only --ignore-user-config "<prompt>"
```

| Observation | Result |
| --- | --- |
| Reports effective filesystem profile as read-only | PASS |
| Negative: an attempted write is rejected by the sandbox, not declined by the agent (`patch rejected: writing is blocked by read-only sandbox`) | PASS |
| Positive: reads the checkout, resolves an exact SHA, and runs `bash scripts/check-bootstrap.sh` | PASS |
| Worktree unchanged after the run | PASS |

The write rejection is the fail-closed evidence the context map requires: the
refusal comes from the sandbox rather than from agent compliance. A review that
reports `workspace-write` must stop and report evidence unavailable.

Environment note: under this sandbox `git` emits
`confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR` on
macOS, once per invocation. It is noise from the restricted temporary directory
and does not affect exit status.

## 2026-08-15 — exact source `fd918ca7db463e86261fc37c1a61b7f27a8d212a`

This is the final source candidate over repository baseline
`94eac3c4890da2eff261b222a94303a78467c595`. Its immediate parent is
`b171e599ddd326ab6adb7e1c0579bf8aa3c83af1`. The evidence-only commit that
follows may change this file and no other path; it does not change the source
under test.

### Source binding

```text
fd918ca7db463e86261fc37c1a61b7f27a8d212a  source commit
2fe0b3e33ccfbf7b89ebcdadcf28736cf24f5e48  source tree
18859eb00aa07db520d68e2a3f8fd4d3efcc4086  .codex tree
dde7f472de9a3889594ea3b7e5d415f8bd48a200  .claude tree
6e37f14f6da445086660ecb9e7c85db297d5084c  .agents/skills tree
d3b94ce9f553c5e016effaa9eb9fdc7cb2e16e49  scripts tree
```

`.claude/skills` is the tracked mode-`120000` blob
`2b7a412b8fa0fb7e985b0793321bd4e698f2b6cd`, targeting
`../.agents/skills`. The configured path therefore resolves to the canonical
shared bytes rather than a client-local copy; live discovery is assessed
separately below.

### Clean-checkout validation

The actual run substituted a canonical absolute path for
`<exact-clean-checkout>`; no temporary suffix or local account path is retained.

```sh
git clone --no-hardlinks . <exact-clean-checkout>
git -C <exact-clean-checkout> checkout --detach \
  fd918ca7db463e86261fc37c1a61b7f27a8d212a
cd <exact-clean-checkout>
git status --porcelain=v1 --untracked-files=all
bash scripts/check-bootstrap.sh
git diff --check \
  94eac3c4890da2eff261b222a94303a78467c595 \
  fd918ca7db463e86261fc37c1a61b7f27a8d212a
git status --porcelain=v1 --untracked-files=all
```

Both status commands and the diff check returned no bytes. The aggregate
passed all five public checks. The status lane passed 20 test methods, including
its positive and adversarial cases.

Two fail-closed controls were run in the same detached checkout:

```sh
PYTHONOPTIMIZE=1 bash scripts/check-agent-bootstrap.sh

mv .github/workflows/agent-bootstrap.yml <saved-workflow>
python3 -B scripts/check-agent-bootstrap.py
mv <saved-workflow> .github/workflows/agent-bootstrap.yml
python3 -B scripts/check-agent-bootstrap.py
git status --porcelain=v1 --untracked-files=all
```

The optimized run exited 1 with
`Python optimization disables bootstrap assertions`. The missing-workflow run
exited 1 with `missing required regular-file hosted bootstrap wrapper`. After
restoration, the check passed and the checkout was clean. These controls prove
that disabled assertions or a silently absent configured wrapper cannot create
a false pass.

### Capability routing

The accepted shared policy uses provider-neutral classes. The dated documented
recommendation was:

| Class | Codex mapping | Claude Code mapping | Typical work |
| --- | --- | --- | --- |
| Efficient | Luna, medium effort | Haiku, medium effort | Objective, repeatable work |
| Balanced | Terra, high effort | Sonnet, high effort | Bounded implementation and integration |
| Deep | Sol, high effort | Opus, high effort | Architecture, durability, security, gates, rejoin decisions, and independent review |

The caller selects a supported mapping before invocation and verifies the
effective model and effort during or after invocation when the client exposes
them. A stronger profile may perform lower-class work. A role name,
description, or static check is routing metadata, not capability proof. Model
selection never changes authority, scope, permissions, acceptance, or the
evidence required by a gate.

Primary references checked on 2026-08-15 were
[OpenAI model guidance](https://developers.openai.com/api/docs/models) and
[Claude Code model configuration](https://code.claude.com/docs/en/model-config).
Installed clients reported `codex-cli 0.147.0` and Claude Code `2.1.233`.

### Static client evidence

`scripts/check-agent-bootstrap.py` passed at the exact source. It proves:

- every Codex role layer contains only the approved role keys and carries no
  project-local model or provider selector;
- every Claude agent omits `model` or uses exact `inherit`;
- client role and skill entrypoints reference AGENTS before the context map;
- the Claude reviewer configuration lists exactly `Read`, `Grep`, and `Glob`;
- protected shared skills carry the checked explicit-only metadata; and
- configured hooks and the hosted wrapper retain their checked structure.

This is configuration evidence, not a claim that a named child role loaded or
that an effective model met a capability class. AGENTS owns status routing,
while the aggregate's status lane validates the canonical records.

### Live exact-source evidence

| Client lane | Result | Meaning |
| --- | --- | --- |
| Codex direct instruction and skill discovery | UNAVAILABLE | The execution environment declined transmission of the newer exact-source context before the client process started. No model output was received. |
| Codex named project-role delegation | UNAVAILABLE | No exact-source child binding was exercised; static role registration is not a live-loading pass. |
| Claude Code instruction, agent, and skill discovery | UNAVAILABLE | It was not retried through another provider because that would reproduce the declined source-transmission operation. |

These unavailable lanes do not weaken the repository checks or authorize a
parity claim. Work requiring an effectively read-only independent review must
use a separately verified invocation or remain unavailable.

### Evidence boundary

Earlier source-scoped client observations remain available in Git history.
They describe only their recorded SHA, client version, prompt, and environment;
they are not current-source support claims and cannot fill the unavailable
lanes above. This concise record supersedes historical prose that inferred role
loading from a requested role name, an echoed prompt, or file presence.

After creating the evidence-only commit, the integrator must verify all of the
following against its exact SHA before push:

- its parent is the exact source commit above;
- its diff from that source contains only this file;
- `.codex`, `.claude`, and `.agents/skills` tree IDs are unchanged;
- the aggregate and diff checks still pass.

After push, the integrator separately confirms that no branch, worktree, client
process, temporary checkout, or generated cache remains.
