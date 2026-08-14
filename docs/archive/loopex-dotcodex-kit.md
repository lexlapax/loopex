# Loopex `.codex/` adapter kit

This is the copy-ready Codex adapter for a new Loopex repository. It implements
client-specific orchestration around the root `AGENTS.md`; it is not a second
source of project authority, acceptance, permissions, or product policy.

Codex reads root `AGENTS.md` directly, so it needs no instruction-import shim.
Project `.codex/` configuration loads only after the checkout is trusted. The
initial adapter is deliberately small:

```text
.codex/
  config.toml
  agents/
    mechanical-worker.toml
    milestone-worker.toml
    release-architect.toml
    release-reviewer.toml
```

Copy `loopex-dotcodex-config.toml` to `.codex/config.toml`, then create the four
agent files below. The model identifiers are current defaults, not project
authority; verify that the workspace exposes them. If one is unavailable, omit
that role's model line to inherit the parent and rerun the adapter smoke rather
than changing the role contract.

The config is an explicit compatibility index: each `[agents.<name>]` entry
points to one profile. Its description intentionally matches the profile
description and adapter drift checks keep the duplicates equal. Do not replace
the index with scalar `[agents]` defaults such as `enabled`,
`max_concurrent_threads_per_session`, or `default_subagent_model` until the
repository declares a Codex version floor whose parser accepts them. Some
current Codex surfaces support those scalars, while `codex-cli 0.139.0` treats
every key under `[agents]` as a role declaration. Client/user defaults own the
concurrency and fallback model in the meantime.

## Boundary

- Root `AGENTS.md` and accepted plans/ADRs/contracts retain the declared
  authority order. Repository commands and CI remain the canonical enforcement
  and evidence mechanisms. Agent files specialize work; they cannot change
  authority, acceptance, or accept their own output.
- Do not set project-wide `approval_policy`, `approvals_reviewer`,
  `sandbox_mode`, provider/auth, notification, telemetry, MCP, or network
  settings here. The user, client, or managed environment owns those choices.
- Per-agent `sandbox_mode` is a requested role default, not an isolation proof.
  Parent live overrides and managed policy can supersede it. Verify the
  effective worker environment; reviewer instructions and independent process
  remain required even when the client cannot enforce read-only operation.
- Do not duplicate gate, ADR, or closure procedures under `.codex/`. Put shared
  progressive workflows under `.agents/skills/` so Codex, Claude Code, and
  other conforming clients use the same bytes.
- Do not seed `.codex/hooks.json`. Add hooks only after a repository-owned
  command exists and a measured workflow shows that early feedback is useful.
  Hooks call that command; they never contain the only implementation of a
  rule, and disabling or failing a hook never waives CI.
- Do not seed `.codex/rules/`. Command rules govern out-of-sandbox execution,
  not project semantics, and remain experimental. If later needed, make them
  restrictive, test them with `codex execpolicy check`, and retain ordinary
  approval and sandbox boundaries.
- Do not package this adapter as a plugin. A plugin is a distribution unit for
  reusable skills/tools, not a repository-policy container.

## `.codex/agents/mechanical-worker.toml`

```toml
name = "mechanical_worker"
description = "Luna worker for narrow repeatable scans, inventories, extraction, mechanical transformations, fixture work, and test-log triage."
model = "gpt-5.6-luna"
model_reasoning_effort = "medium"
sandbox_mode = "workspace-write"
developer_instructions = """
Perform only objective, repeatable work with a stated completion check.
Prefer read-heavy scans, inventories, extraction, mechanical transformations,
fixture updates, cross-reference checks, and log triage.

Before any write, confirm an isolated working directory/state root and explicit,
non-overlapping path ownership. Preserve unrelated edits and shared integration
files. For generated inventories or bulk edits, report the generating command,
expected count, actual count, and unmatched anchors.

Stop and return the ambiguity when the task requires architecture, authority,
security, public-contract, scope, persistence, migration, dependency, gate, or
acceptance judgment. Do not weaken evidence, edit accepted normative artifacts,
commit, push, merge, publish, or accept the work.
"""
```

## `.codex/agents/milestone-worker.toml`

```toml
name = "milestone_worker"
description = "Terra implementation worker for one bounded milestone workstream with explicit ownership, contracts, and focused verification."
model = "gpt-5.6-terra"
model_reasoning_effort = "high"
sandbox_mode = "workspace-write"
developer_instructions = """
Implement only the bounded workstream assigned by the parent, inside its
declared isolated working directory/state root and owned paths. Read AGENTS.md,
the active plan and gate lock, applicable ADRs/contracts, code, and tests before
editing.

Use red-green-refactor where behavior changes. Prove new guards fail for the
intended reason before implementation, then pass focused verification. Treat
accepted tests, selectors, fixtures, vectors, harness/configuration, and gate
digests as protected. Never skip, soften, quarantine, rewrite, inflate retries
or timeouts, or replace a required real path with a fake to pass.

Do not make authority, scope, public-contract, persistence, migration/rollback,
dependency/floor, packaging, or gate decisions. Do not edit another worker's
paths or shared integration files unless the integrator explicitly assigns
them. Preserve unrelated changes. Do not commit, push, merge, publish, or accept
the work.

Return changed files, commands and results, expected-versus-actual counts for
bulk work, remaining integration needs, and every unresolved contradiction.
"""
```

## `.codex/agents/release-architect.toml`

```toml
name = "release_architect"
description = "Sol read-only architect for ambiguity involving ownership, durability, authority, security, public contracts, compatibility, and release boundaries."
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
sandbox_mode = "read-only"
developer_instructions = """
Work as a read-only architecture and decision reviewer. Reconcile the current
task, AGENTS.md authority order, active plan and retained evidence, applicable
ADRs/contracts, vision, code, and tests. Do not treat current implementation or
a green gate as authority over a higher source.

Trace runtime/session/VM ownership, transaction boundaries, durability order,
fencing and reconciliation identity, brain/hand trust, grants and credentials,
plain boundary data, public event semantics, compatibility, migration/rollback,
dependency direction, core-minimality, and release evidence. State concrete
failure scenarios and cite files and symbols.

For a genuinely unresolved decision, return the decision owner, evidence,
viable options, recommendation, compatibility/migration impact, and acceptance
conditions. Do not edit files, mutate state, draft an accepted status, waive or
change gates, commit, push, merge, publish, or accept a candidate.
"""
```

## `.codex/agents/release-reviewer.toml`

```toml
name = "release_reviewer"
description = "Sol read-only independent milestone reviewer for correctness, security, plan adherence, test honesty, rollback, and exact-SHA evidence."
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
sandbox_mode = "read-only"
developer_instructions = """
Review the exact candidate SHA independently, like an adversarial release owner.
Compare it with AGENTS.md, every active-plan Purpose outcome, the accepted gate
lock, applicable ADRs/contracts, code, tests, retained evidence, and required
demonstrations. Evidence must identify the same candidate SHA.

Prioritize logic and concurrency defects, durability/recovery violations,
security and authority regressions, compatibility or rollback gaps, core scope
creep, and false-green tests. Inspect changes to tests, selectors, fixtures,
vectors, harness/configuration, retries, timeouts, and evidence requirements for
gate erosion. A claimed pre-existing failure requires matching base-SHA proof;
compare baselines element by element, not only by totals.

Report each finding with severity, file/line or evidence reference, violated
claim, concrete failure scenario, and required remediation. Say APPROVE only
when no blocking or high-severity gap remains; APPROVE is review evidence, not
project acceptance. Do not edit, run mutating validation, commit, push, merge,
publish, waive evidence, or close the milestone.
"""
```

## Routing and rejoin

The root agent remains the sole integrator:

- use `mechanical_worker` for bounded inventories, transformations, fixtures,
  and log triage;
- use `milestone_worker` for one explicitly owned implementation workstream;
- use `release_architect` before work that depends on an unresolved
  architecture/authority/public-contract decision;
- use `release_reviewer` after rejoin on the exact candidate SHA;
- use a separately identified security review whenever a trust boundary changes.

Read-heavy agents may run together. Parallel writers require separate
worktrees or clones, separate state roots and branch/checkpoint namespaces, and
non-overlapping ownership. One integrator rejoins changes and runs
post-integration proof. Spawning an agent grants no new authority or permission.

## Shared workflows

When repeated use justifies them, derive gate, ADR, closure, conformance, and
adapter-smoke skills under `.agents/skills/`. Each skill should contain only
procedure and call repository-owned Mix tasks for deterministic work. It must
not encode hidden acceptance logic, grant permission, create its own decision
owner, or become a vendor-only source of truth. Validate the same skill with at
least Codex and Claude Code before calling it portable.

Likewise, dependency-budget, temporary-home, warning-free, gate-lock, and
AI-attribution checks belong in Loopex code, test helpers, Mix tasks, and CI.
Codex hooks may invoke a fast subset later, after explicit hook review and trust.

## Adapter conformance smoke

Run these after copying the kit into a trusted checkout and whenever the Codex
adapter changes:

1. **Instruction discovery**

   ```bash
   codex --cd . --ask-for-approval never \
     "List the project instruction sources you loaded. Do not edit or run project commands."
   ```

   PASS: root `AGENTS.md` is named; `CLAUDE.md` is not claimed as Codex
   guidance; no truncation warning appears.

2. **Read-only role**

   Start a fresh interactive session with no prior permission broadening:

   ```bash
   codex --sandbox read-only --ask-for-approval never
   ```

   Do not use `/permissions` or another live override. Ask Codex to delegate a
   repository review to `release_reviewer`, then inspect it with `/agent`.

   PASS: the custom role is selected; the recorded parent mode and observed
   child mode are both read-only; it reports findings only; and the checkout is
   unchanged. The profile's `sandbox_mode` line alone is not proof because a
   parent live override can supersede it.

3. **Writer isolation**

   From a disposable worktree with its own temporary `LOOPEX_HOME`, assign a
   narrow path set to `milestone_worker`.

   PASS: it stays within the assigned paths, preserves unrelated changes, runs
   focused proof, and reports rather than deciding any new trigger.

4. **Mechanical accountability**

   Give `mechanical_worker` an inventory with a known fixture count.

   PASS: it returns the command, expected/actual counts, and unmatched items,
   without making architectural conclusions.

5. **Recorded evidence**

   Retain the Codex version, source SHA, config and agent-file digests, prompt,
   observed instruction sources, selected role, sandbox result, and output at
   the evidence destination named by the active plan. A transcript or local
   client cache alone is not acceptance evidence.

Adapter parity proves effective loading and behavior, not merely file presence.
Automate the deterministic portions in repository CI once stable; keep model
behavior smokes pinned, reviewable, and non-authoritative.

## What not to copy from the Claude adapter

- `CLAUDE.md` import syntax or `.claude/settings.json` permission patterns;
- Claude hook payloads, matcher assumptions, or exit semantics;
- Claude-specific skill metadata or slash commands;
- Claude agent Markdown frontmatter or `isolation: worktree` declarations;
- provider-specific GitHub actions, API secrets, or autonomous fix loops.

Preserve the portable outcome instead: canonical `AGENTS.md`, shared skills,
repository-owned checks, clean CI, isolated writers, one integrator,
independent exact-SHA review, and acceptance by the named authority.

## Current Codex references

Verify the adapter against current official documentation when bootstrapping or
updating it:

- [AGENTS.md discovery](https://developers.openai.com/codex/agent-configuration/agents-md)
- [Project configuration](https://developers.openai.com/codex/config-basic)
- [Custom subagents](https://developers.openai.com/codex/agent-configuration/subagents)
- [Hooks](https://developers.openai.com/codex/hooks)
- [Rules](https://developers.openai.com/codex/agent-configuration/rules)
- [Skills](https://developers.openai.com/plugins/concepts/skills)
