# Loopex `.claude/` kit — the executable half of AGENTS.md

Seed contents for the loopex repository's `.claude/` directory and CI. Each
block names its destination path. Verify hook/settings field shapes against
the current Claude Code references at repo creation
(https://code.claude.com/docs/en/hooks.md,
https://code.claude.com/docs/en/settings.md) — event names and JSON shapes
are stable but evolve.

Layout:

```text
.claude/
  settings.json            # from loopex-dotclaude-settings.json
  hooks/
    guard-bash.sh
    after-edit.sh
    stop-gate.sh
    deps-budget.sh
  skills/
    gate/SKILL.md
    adr/SKILL.md
    close-milestone/SKILL.md
  agents/
    reviewer.md
    conformance-author.md
.github/workflows/gates.yml
```

All hook scripts: `chmod +x`, exit `0` = pass, exit `2` = block with the
message on stderr fed back to the agent.

---

## `.claude/hooks/guard-bash.sh`

Blocks attribution trailers and any command touching a real Loopex home.

```bash
#!/usr/bin/env bash
# PreToolUse[Bash]: stdin is the tool-call JSON.
set -euo pipefail
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

case "$cmd" in
  *"git commit"*)
    if printf '%s' "$cmd" | grep -qiE 'co-authored-by|generated with|generated-by'; then
      echo "Blocked: no AI-attribution trailers in commits (AGENTS.md)." >&2
      exit 2
    fi
    ;;
esac

if printf '%s' "$cmd" | grep -qE '(~|\$HOME)/\.loopex'; then
  echo "Blocked: never touch a real LOOPEX_HOME; use a temp dir (AGENTS.md)." >&2
  exit 2
fi
exit 0
```

## `.claude/hooks/after-edit.sh`

Auto-formats edited Elixir files; enforces the core dependency budget the
moment `apps/loopex/mix.exs` changes.

```bash
#!/usr/bin/env bash
# PostToolUse[Edit|Write]: stdin is the tool-call JSON.
set -euo pipefail
input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[ -z "$file" ] && exit 0

case "$file" in
  *.ex|*.exs) mix format "$file" >/dev/null 2>&1 || true ;;
esac

case "$file" in
  */apps/loopex/mix.exs|apps/loopex/mix.exs)
    .claude/hooks/deps-budget.sh || exit 2
    ;;
esac
exit 0
```

## `.claude/hooks/deps-budget.sh`

The mechanical form of vision §7.2: the `loopex` core application depends on
the Elixir/Erlang standard runtime only.

```bash
#!/usr/bin/env bash
set -euo pipefail
MIX_EXS="apps/loopex/mix.exs"
[ -f "$MIX_EXS" ] || exit 0
# Any {:dep, ...} tuple in the core deps list violates the budget.
if awk '/defp? deps/,/end/' "$MIX_EXS" | grep -qE '\{:\w+'; then
  echo "Blocked: apps/loopex may depend on stdlib+OTP only (vision §7.2)." >&2
  echo "Provider/store/terminal/JSON deps belong in adapter apps." >&2
  exit 2
fi
exit 0
```

## `.claude/hooks/stop-gate.sh`

Fast checks only — full gates are CI's job; Stop must never take minutes.

```bash
#!/usr/bin/env bash
set -euo pipefail
fail=0
if ! mix format --check-formatted >/dev/null 2>&1; then
  echo "Stop blocked: run mix format (warning-free checkpoints, AGENTS.md)." >&2
  fail=2
fi
.claude/hooks/deps-budget.sh || fail=2
exit $fail
```

---

## `.claude/skills/gate/SKILL.md`

```markdown
---
name: gate
description: Open a milestone gate-first — scaffold the plan note and the red acceptance gate.
disable-model-invocation: true
---

Open milestone $1 gate-first (AGENTS.md § Gate Workflow):

1. Create `docs/plans/$1-plan.md` with exactly five sections: Purpose (≤5
   lines), Gate (pointer to the gate test path and `mix loopex.gate $1`),
   Out of scope, Freeze points, Expected stop-and-ask items.
2. Create `test/gates/$1_gate_test.exs` tagged `:gate_$1`, expressing the
   milestone's acceptance from the vision as failing tests: named invariant
   checks (vision §23.3), conformance-suite invocations, and golden-vector
   assertions. Do not stub them green.
3. Wire `mix loopex.gate $1` to run exactly that tag plus affected
   conformance suites.
4. Commit red with `gates: open $1`. Then stop — the maintainer reviews the
   gate before implementation begins (that review is the leverage point).
```

## `.claude/skills/adr/SKILL.md`

```markdown
---
name: adr
description: Record an architecture decision as a one-page ADR (act-and-record tier).
---

Create `docs/adr/NNNN-short-title.md` (next free number) with sections:
Status (Proposed/Accepted, date) · Context (≤8 lines) · Decision (what, not
how) · Consequences (incl. what becomes harder) · Compatibility (affected
public surfaces; "none" is a claim, verify it). One page maximum. Link the
constraining vision section. If the decision would weaken a gate, invariant,
budget, or vision boundary, it is stop-and-ask — do not write it as an ADR;
present options to the maintainer instead.
```

## `.claude/skills/close-milestone/SKILL.md`

```markdown
---
name: close-milestone
description: Close a milestone — gate green in CI, adversarial pass, demo, five-line note.
disable-model-invocation: true
---

Close milestone $1:

1. Verify `mix loopex.gate $1` is green locally AND in CI on a clean
   checkout (link the CI run — that link is the evidence).
2. Run `/code-review`; run `/security-review` too if the milestone touched a
   trust boundary. Fix or file every finding; findings inform, gates decide.
3. Produce the demo the vision names for this milestone; record how to
   reproduce it in one line.
4. Append a closure note to `docs/plans/$1-plan.md` — five lines maximum:
   outcome, CI run link, demo pointer, deviations (each with its ADR), next
   milestone. No ledgers.
5. Tag-worthy? Releases and tags are stop-and-ask — propose, don't push.
```

---

## `.claude/agents/reviewer.md`

```markdown
---
name: reviewer
description: Adversarial pre-merge reviewer. Use before any merge to main; read-only.
tools: Read, Grep, Glob, Bash
---

You are the adversarial reviewer for Loopex. You do not edit; you find. For
the diff under review, hunt in this order: violations of the judgment rules
in AGENTS.md (durability order, recovery truth, type/trust boundaries,
credentials, injected-context); concrete failure scenarios (inputs/state →
wrong outcome) rather than style; gate erosion — any change that makes a
gate, invariant, or budget weaker or a test less honest (report this as
severity-critical); silent scope creep into core that could be an
extension/adapter/host concern. Report each finding as: file:line, claim,
failure scenario, severity. If you find nothing, say so plainly — do not
manufacture findings.
```

## `.claude/agents/conformance-author.md`

```markdown
---
name: conformance-author
description: Writes behaviour conformance suites and golden vectors for a named port (LLM, store, executor, extension, transport).
tools: Read, Grep, Glob, Bash, Edit, Write
isolation: worktree
---

Given a behaviour/port name, write or extend its reusable conformance suite
under `conformance/<port>/`: exercise every callback contract, every
documented failure shape, and the invariants the vision assigns to that port
(§23.2–§23.3). Add language-neutral golden vectors where wire shapes exist.
Suites must run against the fake adapter and any real adapter unchanged —
parameterized by module. A hook or callback that no test proves load-bearing
is a defect: add the proof or report the gap.
```

---

## `.github/workflows/gates.yml`

```yaml
name: gates
on:
  push: { branches: [main] }
  pull_request:
  schedule:
    - cron: "0 6 * * *"   # nightly full gates + dependency audit

jobs:
  gates:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        pair:
          - { otp: "26.2", elixir: "1.17" }   # floor
          - { otp: "27.3", elixir: "1.18" }   # current; update as stable moves
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with: { otp-version: "${{ matrix.pair.otp }}", elixir-version: "${{ matrix.pair.elixir }}" }
      - run: mix deps.get
      - run: mix format --check-formatted
      - run: mix compile --warnings-as-errors
      - run: .claude/hooks/deps-budget.sh
      - run: LOOPEX_HOME="$(mktemp -d)" mix loopex.gate all
```

Optional agent fix-loop job (act-tier: fixing red is autonomous), added once
the repo is stable enough to trust it:

```yaml
  fix-red:
    needs: gates
    if: failure() && github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: anthropics/claude-code-action@v1
        with:
          prompt: "The nightly gates are red. Diagnose and fix until `mix loopex.gate all` passes. Never weaken a gate to pass it (AGENTS.md). Open a PR."
          claude_args: "--max-turns 30"
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```
