# Client Adapter Smoke Evidence

Adapter parity requires proof of effective loading, not file presence
(AGENTS.md § Project State and Client Adapters). This file retains the latest
manual smoke results; the deterministic subset runs in CI via
`scripts/check-agent-bootstrap.sh`.

## 2026-08-15 — source SHA `f747b97` (canonical-context pointers)

Skill and client-agent bytes changed (each artifact now defers to `AGENTS.md`
and the context map first). Rerun: `codex-cli 0.147.0`,
`codex exec --sandbox read-only`, ChatGPT login.

| Check | Result |
| --- | --- |
| All four subagent roles still registered | PASS |
| Skills `adr`, `gate`, `close-milestone` still discovered and parsed | PASS |
| Codex reads back the gate skill's read-AGENTS.md-first routing correctly | PASS |

## 2026-08-15 — source SHA `1ee75ef44a73feafc26043fd344c4aecfca71d9e`

### Codex

- Client: `codex-cli 0.147.0`, ChatGPT login, model `gpt-5.6-sol`,
  `codex exec --sandbox read-only`, non-interactive.
- Note: the smoke began on `codex-cli 0.139.0`, which the account's model
  endpoints no longer serve (every 0.139-era slug returned HTTP 400); the CLI
  was upgraded to 0.147.0 and the smoke rerun. `[features] multi_agent_v2`
  remains in `.codex/config.toml` and roles load with it on 0.147.0.
- Prompt: list loaded instruction sources, registered custom subagent roles,
  and available project skills; no edits, no commands.

| Check | Result |
| --- | --- |
| Instruction discovery names root `AGENTS.md` only | PASS |
| `CLAUDE.md` not claimed as Codex guidance | PASS |
| Roles `mechanical_worker`, `milestone_worker`, `release_architect`, `release_reviewer` registered | PASS |
| Skills `adr`, `gate`, `close-milestone` discovered from `.agents/skills` | PASS |
| Skills parse with `disable-model-invocation` frontmatter present | PASS |
| Read-only role delegation inspected via `/agent` | DEFERRED — interactive session required |

Adapter file digests (SHA-256) at the smoke SHA:

```text
af45e8541f28569cf95eb42e7d34fc233126c4a36210805a814afe4da57d9f28  .codex/config.toml
b5a68dd08397bf6dbf1531964c2691283f1af413c192519bd8877b25b5dda0ad  .codex/agents/mechanical-worker.toml
93f96d1bdad124a7037371e5bb008d1351236f694f53dc1a7c3adb79df1daf35  .codex/agents/milestone-worker.toml
4a2077f4fe78064f0bed51fa84d4d32b078999be9e0fd660843f71d6b31c2fd2  .codex/agents/release-architect.toml
cd7272030e96e60e0edac91722dfa734a9fda608580cccf909c1a13a4a321cf4  .codex/agents/release-reviewer.toml
```

`--strict-config` could not be used for deterministic key validation: it
rejects unrelated newer-schema fields in the user-level `~/.codex/config.toml`
before project config is evaluated.

### Claude Code

Observed in a live session at the same tree:

- `CLAUDE.md` `@AGENTS.md` import loads the contract; `.claude/settings.json`
  permissions and hooks are active (the PreToolUse guards blocked live
  attribution-trailer and permission-file edits during the session).
- Skills `adr`, `gate`, `close-milestone` discovered through the
  `.claude/skills -> ../.agents/skills` symlink.
- Subagents `reviewer` (plan mode, read-only tools) and `conformance-author`
  registered from `.claude/agents/`.

Rerun the smoke whenever `.codex/`, `.claude/`, or `.agents/skills` bytes
change, and record the new SHA, client versions, and digests here.
