# M2 recorded limitations

Retained record of known non-conformances carried by milestone `M2`. Part of the
[evidence index](README.md).

This file is a record, not a decision. Each entry names a rule the milestone does
not fully satisfy, why, what an operator can observe as a result, and the
authority that disposed it. An independent reviewer reads these as declared
limitations rather than as undiscovered defects; nothing here authorises work or
changes a commitment.

## Executor cancellation callback

**Rule.**
[ADR 0009](../adr/0009-tool-executor-and-grant-contracts.md#concept) states that
apart from the progress parameter, "nothing else at this boundary moves", and
names the cancellation sequence among the things that are unchanged. M1's only
cancellation signal is workspace-lease loss: the executor watches the lease
process and terminates the job when it dies.

**What this milestone does instead.** `Loopex.Executor` gains one optional
callback, `cancel/2`, which stops a single named job and reports whether its
cleanup could be confirmed.

**Why.** Outcome 8 requires an abort to cancel the in-flight executor job and
confirm cleanup before committing `cancelled`, and lease loss cannot express
that. A lease is per workspace, so revoking it ends every job using that
workspace and leaves the runtime unable to run further work there — a heavy and
surprising consequence for one interrupt. The coordinator also does not own the
lease; the host does. Without a per-job signal, an abort during a tool call
could only ever commit `outcome_unknown`, which fails the locked case and leaves
a real operating-system process running on the operator's machine after they
pressed Ctrl-C.

**Observable consequence.** The boundary is wider by one optional callback. An
executor that does not implement it is treated as having nothing to leave
behind, so existing implementations remain conformant without change. The
isolated executor named as the second implementation will have to satisfy it.

**Disposition.** Maintainer, 2026-08-24: add `cancel/2` to the executor
behaviour. The alternatives considered and not taken were routing cancellation
through lease revocation, refactoring the local executor to non-blocking
execution first, and cancelling only the BEAM side while always reporting
`outcome_unknown`.

## Promoted follow-up deadline instant

**Rule.** [ADR 0011](../adr/0011-session-input-algebra-and-streaming.md#concept)
requires a promoted follow-up's absolute deadline instant to be computed at the
promotion commit, so that a recovering owner re-presents it rather than handing
the run back the downtime it slept through.

**What this milestone does instead.** The promotion commits the declared
*duration*. The absolute instant is fixed when the promoted run stages its first
request, and is reused unchanged by every later turn of that run.

**Why.** A clock reading inside a durable record that a successor may rebuild is
exactly what made a command-admission record a function of the clock rather than
of the command. Re-presenting one command then produced different bytes for the
same transaction identifier, and the store correctly refused to resolve the
transaction it was holding. M1's `commit_unknown` fault-injection lane caught
that during this milestone's own implementation, and the same hazard applies to
any record a successor may rebuild — including a run's terminal record.

Satisfying ADR 0011 literally requires a durable commit instant. The Store
contract stamps none, and adding one is a persistent-schema decision in
[ADR 0006](../adr/0006-store-transaction-and-owner-epoch.md#concept) territory.
That decision was deliberately not taken inside this milestone.

**Observable consequence.** Bounded to one commit. Only a failure between
committing a promotion and staging that run's first turn is affected, and its
effect is that the promoted run receives its full declared budget again instead
of the remainder. Nothing is lost, corrupted, or dispatched twice. The error is
one of generosity, not of safety or determinism.

**Disposition.** Maintainer, 2026-08-24: keep the duration split and record the
deviation. The alternative considered and not taken was adding a durable commit
instant to the Store contract, which remains the conforming fix whenever that
decision is made.

## Provider selection is not reachable from the command

**Rule.**
[Outcome 10](../plans/M2.md) promises an operator a real command, and the
[dependency direction](../../AGENTS.md) makes the Model boundary replaceable by
design: "shared policy never depends on a provider name". A surface that can
reach only one provider is not itself a violation, but it is a gap between what
the kernel supports and what an operator can ask for, and it is recorded here so
a reviewer reads it as declared rather than as undiscovered.

**What this milestone does instead.** `LoopexComposition.start/1` names one model
specification, `anthropic:claude-haiku-4-5`, and the `loopex` command exposes no
option to change it. Selecting another provider requires composing the ports
directly rather than depending on the shipped composition.

**Why.** The accepted plan pair scopes the composition to naming four concrete
implementations and the command to driving the public facade. Threading a model
specification through both is a small change, but it is a change to the command's
input surface and to the locked composition, and neither was in the envelope the
maintainer accepted. Operator-facing provider selection is deferred rather than
added inside an accepted milestone.

**What was proved anyway.** The adapter is provider-neutral in fact and not only
in intent. It was exercised at the boundary against four providers, each
resolving its identity, carrying the committed request, returning a correctly
parsed tool call, and reporting usage and a provider-supplied response
identifier:

| Provider and model | Identity endpoint | Tool call | Response identifier form |
| --- | --- | --- | --- |
| `anthropic:claude-haiku-4-5` | `https://api.anthropic.com` | correct | `msg_…` |
| `openai:gpt-4o-mini` | `https://api.openai.com/v1` | correct | `resp_…` |
| `openrouter:qwen/qwen3-32b` | `https://openrouter.ai/api/v1` | correct | `gen-…` |
| `ollama:qwen3.5:27b` | `http://localhost:11434/v1` | correct | `chatcmpl-…` |
| `ollama:qwen3.6:35b-a3b-q8_0` | `http://localhost:11434/v1` | correct | `chatcmpl-…` |

`ollama:qwen2.5:7b` answered the same prompt without calling the tool. It
declares tool capability and the call reached it correctly, so this is a
statement about that model rather than about the boundary.

**A local provider can never be this milestone's real-call evidence.** An Ollama
response identifier is a per-process counter, not an identifier that exists in a
provider account. The
[real-call attestations](M2-real-call-attestations.md) are worth exactly the
external lookup a person performs against the provider's account, and there is no
account to look in. A local model is a usable provider and is never closure
evidence.

**Observable consequence.** An operator who wants a different provider cannot ask
the shipped command for one and composes the public ports themselves. Nothing is
lost, mis-recorded, or silently redirected; the command does what it says, for
one provider.

**Disposition.** Maintainer, 2026-08-24: record the gap and defer operator-facing
provider selection to a later milestone. The adapter's provider neutrality is
proved at the boundary and is not in question.
