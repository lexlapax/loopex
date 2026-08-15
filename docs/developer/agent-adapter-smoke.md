# Client Adapter Smoke Evidence

Adapter parity requires proof of effective loading, not file presence
(AGENTS.md § Project State and Client Adapters). This file retains the latest
manual smoke results; the deterministic subset runs in CI via
`scripts/check-agent-bootstrap.sh`.

## 2026-08-15 — closure candidate SHA `cd8d2ae8f8347d051e6ea82fbdd5f19005e0c427`

The final technical candidate adds a tracked Python assertion script so the
provider-neutral aggregate runs inside an effectively read-only reviewer
without a writable checkout or ambient temporary directory. From a clean
candidate checkout, `bash scripts/check-bootstrap.sh` and `git diff --check`
both passed.

Exact independent-review invocation and prompt:

```sh
RUST_LOG=error codex exec -C . --sandbox read-only --ignore-user-config \
  -m gpt-5.6-sol -c 'model_reasoning_effort="medium"' \
  "Review exact candidate SHA cd8d2ae8f8347d051e6ea82fbdd5f19005e0c427 against base 0d663d0b9c5412b908c15513e7dde2110f4250ec. Have release_reviewer perform the independent seed-bootstrap closure review. It must first report its effective filesystem, network, and approval profile and confirm custom instructions loaded; stop if not read-only. Verify HEAD and clean worktree, inspect the full exact diff and retained evidence, and run bash scripts/check-bootstrap.sh plus git diff --check in the read-only environment. Confirm the prior here-document blocker is resolved. Do not edit or affect external state. Wait and return its exact disposition."
```

Codex-cli 0.147.0 loaded the configured `release_reviewer` under filesystem
`read-only`, restricted network, and approvals `never`. The reviewer verified
the exact SHA and clean tree, ran both commands successfully, confirmed the
here-document blocker resolved, reported no blocking, high-severity, or
non-blocking findings, and returned `APPROVE`. This is independent review
evidence; the maintainer's closure disposition is retained in the context map.

The scripts tree object and changed check digests at the candidate SHA are:

```text
e8ee7b393c5ef716875668bd4255b814b096f8bf  scripts tree
9061eac87afff739abc25c8f0a8dd855b30a5f55db7a8e94f38f2466aad81c30  scripts/check-agent-bootstrap.sh
a9966e5c5aabcd0a66d80149794ce8fcbb19389b8663a88abaf7686d6c37a851  scripts/check-agent-bootstrap.py
22162cef70f9440b839f5adf013dc410a93519b860a224eb3fc3498bfc870a5f  scripts/check-bootstrap.sh
dbe9687987377f8b0d374a4e983afe43d20bfbc9a7fc2b1bb3556b30a76e173d  scripts/check-gitignore.sh
```

## 2026-08-15 — source SHA `d1782a8d1c1c2c7f1399fe0aeebaa4a86b36f240` (bootstrap hardening)

This is the exact adapter-changing candidate over base
`0d663d0b9c5412b908c15513e7dde2110f4250ec`. The evidence-recording commit
follows the tested source SHA and changes no client adapter, shared skill,
hook, workflow, or bootstrap-check bytes.

### Repository checks

| Check | Result |
| --- | --- |
| `bash scripts/check-bootstrap.sh` from the committed candidate | PASS |
| `git diff --check 0d663d0b9c5412b908c15513e7dde2110f4250ec d1782a8d1c1c2c7f1399fe0aeebaa4a86b36f240` | PASS |
| `PYTHONOPTIMIZE=1 bash scripts/check-agent-bootstrap.sh` negative control | PASS — the command exits nonzero before running assertions |
| Shared-skill frontmatter and Codex metadata validation inside `bash scripts/check-agent-bootstrap.sh` | PASS |

The aggregate was also rerun from a clean, local, network-free clone of the
committed candidate. `git status --porcelain=v1` returned no bytes before the
check:

```sh
mktemp -d /tmp/loopex-bootstrap-check.XXXXXX
# output: /tmp/loopex-bootstrap-check.gRZkcF
git clone --no-hardlinks . /tmp/loopex-bootstrap-check.gRZkcF/repo
git -C /tmp/loopex-bootstrap-check.gRZkcF/repo checkout --detach d1782a8d1c1c2c7f1399fe0aeebaa4a86b36f240
git -C /tmp/loopex-bootstrap-check.gRZkcF/repo status --porcelain=v1
cd /tmp/loopex-bootstrap-check.gRZkcF/repo
bash scripts/check-bootstrap.sh
PYTHONOPTIMIZE=1 bash scripts/check-agent-bootstrap.sh
```

The aggregate passed; the negative control exited 1 with `Python optimization
disables bootstrap assertions`.

Primary vendor references checked on 2026-08-15:

- [OpenAI Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
  for project-scoped custom agents, natural-language invocation, and parent
  sandbox/approval overrides;
- [OpenAI Build Skills](https://learn.chatgpt.com/docs/build-skills) for
  `policy.allow_implicit_invocation: false` and explicit `$skill` invocation;
- [Claude Code custom subagents](https://code.claude.com/docs/en/sub-agents)
  for tool lists, `permissionMode`, skill discovery, and parent-mode
  precedence; and
- [Claude Code hooks](https://code.claude.com/docs/en/hooks) for hook input and
  permission-mode behavior.

### Codex

- Client: `codex-cli 0.147.0`, ChatGPT login, model `gpt-5.6-sol`.

Exact positive read-only invocation and prompt, run from the repository root:

```sh
RUST_LOG=error codex exec -C . --sandbox read-only --ignore-user-config \
  -m gpt-5.6-sol -c 'model_reasoning_effort="medium"' \
  "Review committed source SHA d1782a8d1c1c2c7f1399fe0aeebaa4a86b36f240 against base 0d663d0b9c5412b908c15513e7dde2110f4250ec. Have release_reviewer perform the review using committed Git objects only and ignore uncommitted working-tree bytes. It must first report its effective filesystem, network, and approval profile and confirm whether its custom instructions loaded; if the filesystem is not read-only, it must stop without inspection. It may run only read-only commands and must not edit or affect external state. Wait for release_reviewer and return its response without changing its disposition."
```

- Positive permission smoke: a top-level `codex exec --sandbox read-only
  --ignore-user-config` session delegated the exact candidate/base review to
  the configured `release_reviewer`. The custom role loaded, reported
  filesystem `read-only`, network restricted, approvals `never`, and inspected
  the candidate. Its initial result was `NOT APPROVED` solely because this
  candidate-bound evidence and the accompanying maintainer decision record did
  not yet exist; both remediations are in the following evidence commit.

Exact writable-parent negative-control invocation and prompt:

```sh
RUST_LOG=error codex exec -C . --sandbox workspace-write --ignore-user-config \
  -m gpt-5.6-sol -c 'model_reasoning_effort="medium"' \
  "Have release_reviewer report its effective filesystem, network, and approval profile and confirm whether its custom instructions loaded. It must stop before repository inspection or commands if the effective filesystem is not read-only. Wait for release_reviewer and return its response without changing its disposition. Do not inspect, edit, or affect external state in the parent."
```

- Negative permission smoke: the same configured role launched from the
  writable parent session, reported the effective workspace-write override,
  returned `STOPPED`, and stopped before repository inspection or commands.

Exact protected-skill invocation and prompt:

```sh
RUST_LOG=error codex exec -C . --sandbox read-only --ephemeral \
  --ignore-user-config -m gpt-5.6-sol \
  -c 'model_reasoning_effort="medium"' \
  "At exact source SHA d1782a8d1c1c2c7f1399fe0aeebaa4a86b36f240, without opening or invoking any project skill, report: (1) the canonical instruction files you were given, (2) the names of repository project skills visible for explicit invocation, and (3) whether the protected gate or milestone-closure skill bodies were automatically injected into your active context. Do not run commands, delegate, browse, edit, or create a plan."
```

- Protected-skill smoke: a fresh read-only session, told not to invoke or open
  any skill, saw `AGENTS.md` as its injected repository contract and `adr` as
  implicitly available. It reported that neither `gate` nor
  `close-milestone`, nor their bodies, was injected. This is the intended
  effect of `allow_implicit_invocation: false`; both remain available only by
  explicit operator invocation.
- The delegation smokes intentionally omit `--ephemeral`: codex-cli 0.147.0
  twice returned transient `no thread with id` errors when an ephemeral parent
  attempted to spawn a child. The protected-skill probe does not delegate and
  remained ephemeral. Persisted client thread state is a disposable cache, not
  repository state or evidence by itself.

### Claude Code

- Client: Claude Code 2.1.233. `claude doctor` exited zero and accepted the
  repository settings; its two machine-level warnings were a non-writable
  macOS Keychain and npm global updater, neither of which changes repository
  loading.

Exact health and initialization invocations, including the complete prompt:

```sh
claude doctor
claude -p --agent reviewer --permission-mode plan \
  --output-format stream-json --verbose --include-hook-events \
  --no-session-persistence --max-budget-usd 0.05 \
  "At exact source SHA d1782a8d1c1c2c7f1399fe0aeebaa4a86b36f240, report your effective tools, permission mode, loaded root instructions, and discovered project skills. Do not edit or run commands."
```

- Exact-candidate initialization with `--agent reviewer --permission-mode
  plan --output-format stream-json --verbose` emitted tools exactly
  `Read`, `Grep`, and `Glob`; permission mode `plan`; custom agents `reviewer`
  and `conformance-author`; and project skills `adr`, `gate`, and
  `close-milestone`. This proves effective agent and shared-skill discovery
  through the tracked adapter and symlink.
- The client then returned `authentication_failed` because no Claude account is
  logged in. No model turn ran and cost was zero. This is retained as unavailable
  inference evidence, not called PASS; the candidate's Claude-only changes are
  hook comments, while hook wiring, protected Claude metadata, tools, mode,
  agents, and skill discovery are covered by initialization and deterministic
  checks.

Recursive Git tree object IDs at the tested SHA:

```text
8b04d44d1b3ec34f435f54ee3988a71c8e807c66  .codex
d698dbb46ccad42590848bdc42a63311c929b620  .claude
ebbea544fb6fdaa4d4dab786af1d81a6d7b3c227  .agents/skills
```

Selected SHA-256 digests at the tested SHA:

```text
e3180dc876c917870a9c1b33e2935ccac1331cd793646c10d12176917074b375  .codex/config.toml
e82575120a128c5c7f2e40d4be5d56e45db5716174c4aad4a25260fecb437e6a  .codex/agents/mechanical-worker.toml
81db92cce73ed91555c04783624d68c2bc39d9cfbd32ad3625265c2935d388bf  .codex/agents/milestone-worker.toml
40d60ce716b3965ff2939df04ef52239e8867cc5c6d302fb272d23bab162a69f  .codex/agents/release-architect.toml
f05a8ac19dfa7630b3d7896db8438cab73f872e689ffda70466eb95a2be8b525  .codex/agents/release-reviewer.toml
4ba218fd1a6d60f1b80a5698f84530d2955ba8f1a85ab9bff388ff4a92b3bd55  .agents/skills/close-milestone/SKILL.md
666e795cc635c0a962a707a6f68fd49f13389a769045f6618fbab376980f3429  .agents/skills/close-milestone/agents/openai.yaml
539c5d3ba590526c7ef79fd77441a18b227bc980a5c9ea45de5c058d21200314  .agents/skills/gate/agents/openai.yaml
15d97f0b0844bada69cc1f9d1a25550b2031d15f7e3cae6366a7ce8fd5f08804  .claude/settings.json
11083c046c8b728994a85e6bbe85f34055ce887d7540a785f5c68939e829aef1  .claude/agents/reviewer.md
8ebf638c16e265e2c12bbdd15a084329687881839324e88b02517ddf166935ff  .claude/agents/conformance-author.md
a56129918a1f92c47d30152374b42b23c921c6e9b8598d851d4c88e848bd767e  scripts/check-agent-bootstrap.sh
22162cef70f9440b839f5adf013dc410a93519b860a224eb3fc3498bfc870a5f  scripts/check-bootstrap.sh
```

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
