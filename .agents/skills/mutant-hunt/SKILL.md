---
name: mutant-hunt
description: "Find a change to production code that breaks a stated guarantee while its tests stay green. A technique for judging how strong a guarantee's tests are, used before closing a milestone or after those tests were rewritten; never a required step, and never a substitute for review."
---

# Hunt a Mutant the Tests Miss

Follow `AGENTS.md` first; read `docs/plans/README.md` for the register, then
use `docs/developer/agent-context-map.md` for routing and version-specific
technical guidance.

This is negative evidence. Tests prove that the behaviour they drive is
present; they say nothing about what they do not drive. A hunt asks, for one
stated guarantee, what the smallest production change is that would make it
false without any test noticing.

Run it against the claim, not the diff. Mutating a line somebody just edited
samples exactly the mutation the tests written beside that edit catch. Every
hole found this way so far sat one step away from an edited line: a sibling
branch, a failure-only path, a consequence nothing observed. So the hunter is
someone who has not seen the change: give them the guarantee, the production
files and the test files, and keep `git log`, `git diff` and `git show` out of
scope.

1. Take the claim: a milestone outcome in `docs/plans/<name>.md`, a product
   non-negotiable in `AGENTS.md`, or a module's Concept section. Split it into
   sentences that must each be true of the shipped code, and number them.
2. Work in a disposable worktree, never in the reviewed checkout.
3. For each sentence, make the smallest production edit that makes it a lie
   and run the tests that claim to cover it. A mutation that turns them red is
   uninteresting; you are looking for one that stays green.
4. Report each survivor: the sentence, the mutation, and why the tests missed
   it. Do not fix it in the same task; the fix is a new test, reviewed like any
   other change.

A hunt is worth running for a guarantee whose failure would be silent: fencing,
recovery, authority, credential handling, redaction. It is not worth running
for every edit.
