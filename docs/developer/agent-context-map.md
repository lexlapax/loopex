# Agent Context Map

This is the lazy-loaded routing map for coding agents. It points to the first
documents to read when the active plan and local code are not enough. Until
implementation produces code, ADRs, and developer docs, most rows route into
[docs/vision.md](../vision.md) by section; replace vision-section pointers
with ADR and code pointers as they land.

## How To Use

1. Read `AGENTS.md`, the active plan in `docs/plans/`, and constraining ADRs
   first.
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
| Client adapters, skills, portable enforcement | AGENTS.md § Project State and Client Adapters and § Parallel Work and Portable Enforcement; [agent-adapter-smoke.md](agent-adapter-smoke.md); `scripts/` | Canonical skills live in `.agents/skills`; `.claude/` and `.codex/` are thin adapters over the same bytes; smoke evidence is appended whenever adapter bytes change; every check runs locally, hosted CI is a replaceable runner. |

## Test Quick Reference

Until a test-strategy doc exists: `mix test` against a temporary
`LOOPEX_HOME`; run the affected conformance suites (`conformance/`) for any
adapter or behaviour change; property tests own reducer/replay claims;
fault-injection owns durable-transition claims. Real-provider runs are a
tagged, explicitly invoked lane — never part of the default suite.

## Version-Specific Guidance

This section holds temporary in-flight guidance while a specific version is
being planned and implemented. It is cleared at release closeout; add the
next version's working notes here when that work begins.

### Seed bootstrap (updated 2026-08-15)

The seed bootstrap is complete and green. Any client should reach the same
state from these facts alone:

- `scripts/check-agent-bootstrap.sh` and `scripts/check-gitignore.sh` are the
  executable definition of "bootstrap green"; both pass from a clean checkout
  with stock tools. Hosted CI runs the same scripts as a thin wrapper.
- Client-adapter loading is proven, not assumed:
  [agent-adapter-smoke.md](agent-adapter-smoke.md) retains the evidence.
  Rerun and append whenever `.codex/`, `.claude/`, or `.agents/skills` bytes
  change. The Codex read-only role-delegation check is still deferred to an
  interactive session.
- Settled seed decisions — do not relitigate without new evidence:
  `[features] multi_agent_v2` stays in `.codex/config.toml` (project roles
  load on codex-cli 0.147.0); the AGENTS.md durability paragraph stays
  complete per vision §20.3; the `gate` and `close-milestone` skills carry
  `disable-model-invocation: true` (Codex parses it); enforcement scripts use
  stock `grep -E`, never ripgrep.
- Known pre-commitment to revisit at the Mix scaffold:
  `.claude/hooks/deps-budget.sh` hardcodes `apps/loopex/mix.exs` and is
  silently inert under any other layout. The layout decision (vision §20.1
  leaves the tree unfrozen) must update that hook in the same change.
- Nothing beyond seed-scope work is authorized until the maintainer
  explicitly opens the next stage gate-first (AGENTS.md § Milestones and
  Gates, seed-bootstrap clause; `gate` skill).
