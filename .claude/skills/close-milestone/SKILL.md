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
