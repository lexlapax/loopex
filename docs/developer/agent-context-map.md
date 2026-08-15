# Agent Context Map

This is the lazy-loaded routing map for coding agents. It points to the first
documents to read when the active plan and local code are not enough. Until
implementation produces code, ADRs, and developer docs, most rows route into
[docs/vision.md](../vision.md) by section; replace vision-section pointers
with ADR and code pointers as they land.

## How To Use

1. Read `AGENTS.md`, any accepted active plan and gate contract when one exists,
   and constraining accepted ADRs first.
2. Use the table below to find an area's anchor sections and docs.
3. Prefer code and tests over stale prose. Flag conflicts.

## Area Routing

| Area | Start with | Notes |
| --- | --- | --- |
| Doctrine, product definition, principles | Vision §2–§4 | "Runtime is the framework"; what Loopex is and is not; the 21 principles. |
| Domain language | Vision §5 | Session/run/turn, operation/attempt/epoch/fence, journal vs public event, brain vs hand. Use these terms exactly. |
| Ownership and trust boundaries | Vision §6 | The Loopex/host/executor ownership map; policy port (`allow/deny/defer`); grants. Mechanism in Loopex, governance in the host. |
| Stack, dependency budget, runtime floor | Vision §7 | Protocol/Core/Runtime namespaces; stdlib+OTP-only core; BEAM-native persistence doctrine; OTP 26+/Elixir 1.17+. |
| Runtime instances, supervision, reducer | Vision §8, later `docs/architecture.md` | Multi-instance; SessionTree `:one_for_all`; pure reducer; one bounded journal transaction. |
| Transactions, operations, recovery, cancellation | Vision §9 | `commit_unknown` three-state store contract; operation lifecycle; reconciliation table; closed outcome algebra. |
| Agent loop, queues, tool ordering | Vision §10 | One run per session; prompt/steer/follow-up/respond_interaction; serial tools first; split payloads. |
| Public protocol, events, attachments | Vision §11, later `docs/protocol/` | Four stream planes; command/event envelopes; snapshot-first attach; no controller lease in core. |
| Journal, stores, branches, compaction, artifacts | Vision §12 | Private journal surfaces; in-memory for tests and simple embedding; a human-readable local adapter is optional, private, and experimental; durable store selection remains open pending evidence and an ADR; credentials and content protection. |
| Model boundary and continuation | Vision §13.1–§13.4 | Canonical Loopex types; `Loopex.LLM`; ReqLLM reference adapter; provider-native sidecar. |
| Context pipeline (memory, retrieval, prompts) | Vision §13.5, §17.3 | The sole seam for memory/RAG/prompt systems; providers/transformers/selectors/observers; receipts; agentic-search code posture. |
| Tools and the coding surface | Vision §14 | Seven tools, budget-constrained; tool metadata grants nothing. |
| Executors, brain/hand, distribution security | Vision §15 | Job/receipt protocol; three trust classes; distribution connects trusted gateways only. |
| Trust classes, project resources, sensitive data | Vision §16 | Resource admission; multi-tenant rule; observability redaction. |
| Extensions, generations, generated code | Vision §17 | Three package classes; quiescent activation; exact A→B→A rollback; generated-code promotion path. |
| Embedded API, transports, clients, ACP | Vision §18 | One semantic contract; JSONL RPC first; reference daemon/CLI; ACP before protocol v1 freeze. |
| Hosts and wrappers | Vision §19 | Expected consumers; secured sample host; prior-system evidence and clean-room rule. |
| Repository layout, derived docs, ADR agenda | Vision §20 | What to create next and which decisions need ADRs. |
| Delivery shape and milestones | Vision §21, the active plan | §21 is a suggestion; the active plan is the commitment. |
| Verification, invariants, budgets | Vision §23 | Test layers; the named invariant suite; minimalism budgets; performance evidence rules. |
| Compatibility and release governance | Vision §24 | Six separately versioned surfaces; 0.x labeling; migration/rollback duties. |
| Prior-system evidence (Allbert Assist) | Vision §19.3, §29.6 | All consulted documents are directly linked there with full URLs. Lessons flow in; code does not. |
| Coding-agent ecosystem, adapters, skills, portable enforcement | AGENTS.md § Project State and Client Adapters and § Parallel Work and Portable Enforcement; [DEVELOPMENT.md](../../DEVELOPMENT.md); [agent-adapter-smoke.md](agent-adapter-smoke.md); `scripts/` | Check current primary vendor docs and installed behavior, derive coding-agent-agnostic consequences first, then keep `.claude/`, `.codex/`, and future tested adapters thin. OpenCode, Pi, and a future Loopex coding surface are candidates, not supported clients. Every check runs locally; hosted CI is replaceable. |

## Test Quick Reference

Until a test-strategy doc exists: `mix test` against a temporary
`LOOPEX_HOME`; run the affected conformance suites (`conformance/`) for any
adapter or behaviour change; property tests own reducer/replay claims;
fault-injection owns durable-transition claims. Real-provider runs are a
tagged, explicitly invoked lane — never part of the default suite.

## Coding-Agent Ecosystem Guidance

- `scripts/check-agent-bootstrap.sh` and `scripts/check-gitignore.sh` define
  "bootstrap green" behind the provider-neutral aggregate
  `scripts/check-bootstrap.sh`. They run from a clean checkout with the
  toolchain in [DEVELOPMENT.md](../../DEVELOPMENT.md); hosted CI may invoke only
  the aggregate as a replaceable thin wrapper.
- Maintainer decision (explicit bootstrap task, 2026-08-15): the exact-SHA,
  repository-owned local aggregate is mandatory evidence; hosted CI is
  supplementary unless an accepted gate or release claim explicitly locks a
  hosted or real-provider lane. A hosted-required default was rejected because
  it would make an open-source checkout depend on one provider; removing the
  thin hosted mirror was rejected because it remains useful supplementary
  signal. Existing GitHub automation therefore stays replaceable, forks need no
  GitHub tooling to develop, and a later material change requires a new
  option-and-implication packet and maintainer approval.
- Client-adapter loading is proven, not assumed. Retain versions, source SHA,
  adapter digests, prompts, observed instruction/role/skill loading, and
  permission results in [agent-adapter-smoke.md](agent-adapter-smoke.md). Rerun
  relevant smokes whenever `.codex/`, `.claude/`, or `.agents/skills` bytes
  change.
- Independent review requires an effectively read-only environment. A client
  role default is not proof: if the live parent or client overrides it with a
  writable profile, the reviewer reports unavailable and stops. Retain both a
  positive read-only smoke and a negative fail-closed smoke where supported.
- For coding-agent ecosystem changes, check current primary vendor docs or
  release notes plus installed behavior, derive any coding-agent-agnostic
  consequence first, and retain version-specific facts here. Material changes
  to development behavior require an option-and-implication packet and
  maintainer approval before adapter edits.
- Current Codex compatibility: `[features] multi_agent_v2` stays in
  `.codex/config.toml` because project roles are proven with codex-cli 0.147.0;
  removal requires a separately reviewed compatibility smoke. The `gate` and
  `close-milestone` skills require explicit invocation: Claude consumes
  `disable-model-invocation: true`, while Codex consumes
  `agents/openai.yaml` policy `allow_implicit_invocation: false`. Enforcement
  scripts use stock `grep -E`, never ripgrep.
- Mix-scaffold rider: `.claude/hooks/deps-budget.sh` hardcodes
  `apps/loopex/mix.exs` and is silently inert under any other layout. Vision
  §20.1 leaves the tree unfrozen; the layout decision must update that hook in
  the same change.

## Version-Specific Guidance

This section holds temporary in-flight guidance while a specific version is
being planned and implemented. It is cleared at release closeout; add the
next version's working notes here when that work begins.

### Seed bootstrap closure candidate (updated 2026-08-15)

The maintainer authorized this final cross-client hardening pass and asked to
close agent bootstrap after its evidence and review agree. The adapter-changing
candidate is `d1782a8d1c1c2c7f1399fe0aeebaa4a86b36f240`; its retained smokes
are in [agent-adapter-smoke.md](agent-adapter-smoke.md). Do not call the seed
bootstrap closed until the following evidence commit passes repository checks
and exact-SHA independent review. Push and any hosted-wrapper result are
supplementary publication evidence, not closure authority or a development
dependency. Any client should derive the candidate state from these facts alone:

- The permanent Coding-Agent Ecosystem Guidance above, retained smoke evidence,
  and the AGENTS.md durability paragraph (complete per vision §20.3) are the
  candidate's shared memory; do not move these facts into client-only state.
- Nothing beyond seed-scope work is authorized until the maintainer
  explicitly opens the next stage gate-first (AGENTS.md § Milestones and
  Gates, seed-bootstrap clause; `gate` skill).
