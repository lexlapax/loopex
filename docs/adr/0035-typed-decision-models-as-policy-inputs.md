<a id="concept"></a>
## Concept

Technical depth: [Typed decision model mechanics](0035-typed-decision-models-as-policy-inputs-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-19
- **Decision owner:** Maintainer
- **Supersedes:** nothing; it refines where a host may get the *inputs* to the
  ADR 0009 policy decision, and changes nothing about who makes it
- **Prerequisite for:** the milestone after M5. It is **not** an M5
  prerequisite, blocks nothing in M5, and no part of it runs inside M5

<a id="concept-adr-0035-decision"></a>
### Context and Decision

Several places in the runtime need a judgment that is not a lookup and not a
conversation. Should this tool call be treated as destructive? Is this run
going to need the operator? Which of two models should this turn go to? Today
each of those is either a hand-written predicate over validated arguments, or
it is not asked at all, or it would require asking a text model and reading its
prose — which is the worst of the three, because prose is not a value a
program can act on and cannot be journaled as a fact.

A different shape of model has become available. TypeSafe AI's *Jev* is what
they call a **System One** model: it generates no text. It takes one state — a
string or a JSON document — and a map of named, typed questions, and returns a
typed answer per question with a probability: `noul`, a yes/no expressed as a
probability between 0 and 1; `choice`, per-option probabilities with a
confidence; and `score`, ordered levels with a confidence. It is one HTTP call
to `POST https://api.typesafe.ai/v1/systemone` with a bearer key in
`TYPESAFE_API_KEY` and the model alias `jev-latest`. Their guidance is that
questions be atomic, that a batch of them go in one call, that the question
text stay stable so probabilities remain comparable across calls, and that
actions be gated on confidence with thresholds the caller owns.

ReqLLM 1.24.0, released 2026-09-17, added a provider-neutral seam for exactly
this shape: `ReqLLM.Evaluation.evaluate/4`, reached as
`ReqLLM.evaluate("typesafe:jev-latest", state, questions, opts)`. It is
declared in the library as "a model call, not a test run", the provider
supports no chat and no streaming, and the answers come back in
`result.object` under the question's name.

**Decide that a typed decision model may be an input to a host's decision, and
may never be the decision.** A typed answer is data: a probability, a set of
option probabilities, a level, a confidence. It is journaled as a plain-data
fact where a fact is wanted, and it is handed to the host's own policy where a
decision is wanted. It never becomes a grant, never widens what a policy would
otherwise allow, and never shortens a path that would otherwise ask. This is
not a new principle — the development contract already says that IDs,
interactions, model output, context and metadata never grant authority, and
ADR 0009 already makes every executor-backed tool call consult the host's
policy with no exemption predicate. What this decision adds is that a *typed,
calibrated* model answer is still model output, and gets no privilege for
being numeric.

The seams, in the order they are worth doing:

1. **Executor admission triage.** A host policy that asks "is this
   destructive, does it reach outside the workspace, what did the caller
   appear to intend, how risky does this look" gets those as typed answers and
   applies its own thresholds. It consumes them through the policy seam that
   already exists — the host's `Loopex.Policy` implementation, of which the
   reference `AllowAll` and `Ask` are the two shipped examples — so the port,
   its fail-closed resolution table and its deny-on-anything-unexpected
   behaviour are untouched.
2. **Model routing per turn**, journaled as a fact: which model a turn was
   routed to, and the typed answer that informed it, recorded where the run's
   provenance already lives.
3. **Interaction escalation**: "this needs the operator" as a probability, fed
   to the host that owns whether to ask.
4. **Session classification** for listing and residency, a daemon-side
   convenience over sessions it already holds.
5. **Offline transcript scoring** in the release check, over retained
   transcripts, touching no live path at all.

**Alternatives rejected.** Deriving the same judgments by parsing a text
model's output was rejected: the output is uncalibrated, it varies with
phrasing in ways nothing can bound, and there is no value to journal — a
sentence is not a fact a later reader can compare. Using the text model with a
structured-output schema was rejected for the same reason plus its price: a
schema constrains the shape of an answer but yields no probability and no
confidence, so a host has nothing to threshold on, and it costs a full
generation to obtain.

**Evidence its acceptance requires.** This is a trust claim, so its class is
negative tests plus a real-provider proof. The negatives are the load-bearing
half: no typed answer, at any confidence including 1.0, ever produces a grant
the host's policy would not otherwise have produced; a missing, malformed,
slow or refusing evaluation leaves every decision exactly as it would have
been without one; and no answer shortens a path that would otherwise ask. The
real-provider case proves the call reaches the endpoint and returns the typed
shapes, and is where latency and price are first measured.

Technical depth: [Contract and evidence](0035-typed-decision-models-as-policy-inputs-technical.md#technical-adr-0035-decision).

<a id="concept-adr-0035-consequences"></a>
### Consequences, Compatibility and Rollback

A host gains a way to ask a calibrated question and act on the answer with its
own thresholds, instead of writing a predicate that is right until the first
case it did not imagine. Nothing about authority moves: the policy port, its
fail-closed resolution and the executor's validation are unchanged, and a
runtime with no evaluation configured behaves exactly as it does today.

Three consequences are real costs rather than benefits, and are stated as
such. It is a **second provider credential**, `TYPESAFE_API_KEY` alongside the
model credential, which means
[ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept)'s
per-invocation credential **token** has to become one per provider rather than
one per call. ADR 0034 fixes one token per call and does not define that, so
the generalisation is a prerequisite amendment to it, proposed with the
milestone that accepts this decision; this one cannot be implemented before
that lands. Because a token is routed through a host-owned registry, a second
provider is a second row and a second token rather than a wider value, which
is what keeps that amendment small. The **state sent to the model** is bounded, redacted, provenance-typed
data the runtime already holds, under the same context-admission discipline
that governs anything else staged for a provider; nothing new becomes
sendable. And **latency and price are unmeasured** until the first real call;
they are measured from the response's own `usage` there, and no threshold, no
budget and no timing claim is made before that.

Rollback is removing the evaluation: every seam is an input, so a host that
stops asking makes the same decisions it made before, by the same paths. No
durable record depends on an answer existing, because an answer is journaled
as a fact about what was observed, not as a premise anything later requires.

Technical depth: [Compatibility mechanics](0035-typed-decision-models-as-policy-inputs-technical.md#technical-adr-0035-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
