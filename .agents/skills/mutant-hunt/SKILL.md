---
name: mutant-hunt
description: "Attack a Loopex milestone obligation's clauses to find a mutation of production code that makes a clause false while the locked test corpus stays green. Use before offering a gate amendment or a closure candidate for independent review, and whenever a locked selector's minimum or names change; do not use it to review a diff, to fix what it finds, or in place of the independent review it precedes."
---

# Hunt a Mutant the Corpus Misses

Follow `AGENTS.md` authority and decision tiers first; read
`docs/plans/README.md` for canonical status, then use
`docs/developer/agent-context-map.md` for routing and version-specific technical
guidance.

This is a **negative-evidence** procedure. A locked test corpus proves that the
behaviour it drives is present. It says nothing about the behaviour it does not
drive, and a gate whose minimum has just risen is exactly where that gap hides:
new names look like new protection and may be none.

## Why it is run against the claim and never against the diff

Mutating a line somebody just edited samples the mutation a corpus written
alongside that edit is most likely to catch. Every hole found this way in `M2`
sat one step away from an edited line — a sibling branch, a failure-only path, a
guarantee with no observable consequence. The hunt is therefore run by an actor
that has **not** seen the change, from the obligation text and the current code
alone.

If you are the author of the change, delegate this. Give the delegate the
obligation, the production files, the corpus files, and nothing else, and tell it
plainly that `git log`, `git diff`, and `git show` are out of scope for the task.

## Procedure

1. **Take the claim, not the change.** Read the milestone's outcome obligation in
   `docs/plans/<name>-technical.md` and split it into its clauses. Each clause is
   one sentence that must be true of the shipped code. Number them.
2. **Work in a disposable clone.** Never mutate the reviewed checkout.
3. **For each clause, ask: what is the smallest edit to production that makes
   this sentence a lie?** Make that edit and run the file the clause's locked
   selector names. A mutation that turns the suite red is uninteresting — the
   corpus catches those. You are looking for a lie the corpus cannot see.
4. **Confirm a survivor against the whole suite**, not just one file, and against
   formatting and a warnings-as-errors compile: a survivor that trips another
   check is caught, just not where you expected.
5. **Report; do not fix.** Each survivor gets the exact edit, the clause it
   falsifies, a concrete failure scenario an operator or a conforming
   third-party implementation would hit, and the command output proving the
   suite stayed green.

## Where the corpus has actually been blind

Offered as a starting posture, not a checklist to work through.

- An assertion that observes a helper, a returned option list, or a value the
  test itself constructed, rather than the production path. A public function
  added so a case can observe production is the seam that makes the case observe
  the seam instead.
- A guarantee whose violation costs nothing on the happy path — no elapsed time,
  no different outcome — so both implementations return the same thing at the
  same moment.
- One branch of a function where a sibling branch is what the case drives.
- A path reached only when something fails, where every case drives success.
- A public function that no test calls at all, while production calls it on every
  abort.
- A count, bound, identity, or clock base taken from the wrong party.
- A comparison on text where the domain is paths, process groups, or versions.

## Judging what you find

A survivor is not automatically a defect in production; it is always a defect in
the evidence. Three dispositions, and the amendment or closure packet must say
which:

- **Lock it behaviourally.** Preferred. If the trigger is an environmental
  condition the code hardcodes — a program path, a clock base — consider whether
  naming it is a real configuration question in its own right. If it is, naming
  it is a product improvement that happens to make the branch drivable. If it is
  not, do not invent a knob to reach a branch.
- **Lock it structurally**, by asserting the shape in the source. Weaker. Only
  where the trigger genuinely cannot be arranged, and the case must say so in its
  own words rather than presenting itself as behavioural.
- **Delete the unobservable invariant.** If no case can observe it and no
  operator can, it is not an invariant. Say so and remove it rather than keeping
  a claim nothing supports.

Record the hunt's result with the change it guards: what was attacked, what
survived, how each survivor is now locked, and which locks are structural.
