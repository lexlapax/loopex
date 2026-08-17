# M0 Self-Hosting Report

Produced by `mix loopex.self_hosting` when outcome 8 runs. Records what the
Elixir replacement measures and what it dropped from the retired bridge, so a
reviewer can judge whether the result is proportionate.

The size figure is audit material. No run passes or fails on it.

- measured size: 9,096 lines against the retired 4,462, a factor of 2.04 — 1,694 documentation, 230 comment, 1,326 blank, 5,846 code
- dropped behaviors: eight, listed below and printed in full by `mix loopex.self_hosting` so the list cannot drift from the figure
- recorded: 2026-08-17 on Elixir 1.20.3 / OTP 29.0.5

## What the figure means

The gate states plainly that this measurement is audit and review material and
that no run passes or fails on it. It is recorded here so a reviewer can weigh it
against the dropped-behaviour list rather than against an expectation.

Three things account for most of the growth, and only the third is Elixir being
Elixir:

- **Documentation is 19% of the lines.** This repository's contract requires
  ordered Concept and Technical depth sections on every module and documented
  function, and `mix loopex.docs_check` now enforces it on this code. The retired
  Python carried far less.
- **About 850 lines replace two dependencies rather than two files.** The bridge
  read JSON with `jq` and TOML with a Python library, both free to it. Neither is
  available to core, which is stdlib and OTP only, so readers for both had to be
  written. That is a cost of the dependency budget, not of the migration.
- **The rest is style.** Formatted Elixir is more vertical than Python.

Coverage grew as well: 37 executed tests across the three ported selectors where
the retired suite had 29. That is not a defence of the figure, only a fact a
reviewer should have alongside it.

## Dropped behaviours

Eight, with the reason each was dropped rather than ported. Items 1 and 7 are the
two a reviewer should look at hardest, because they are the only ones that change
what the repository can detect or where it can run.

1. **Untracked-file enumeration in the adapter check.** The retired checker
   globbed the filesystem, so an untracked stray file failed an
   exactly-these-files assertion. Enumeration now reads the Git index. A tracked
   stray still fails. This was a deliberate integrator directive after a
   recursive working-directory scan matched four nested agent worktrees and failed
   a commit that was clean from a fresh clone.
2. **Interpreter self-assertions.** Assertions-enabled and minimum-version checks
   described the retired runtime. Nothing to preserve.
3. **Standalone configuration-syntax validation.** Now implied and stronger: the
   Mix commands parse whole documents and reject malformed text, duplicate keys,
   and unescaped control characters.
4. **General path queries in the client hooks.** Replaced by a token-enumerating,
   depth-counting reader that is path aware for the depth-2 shape every hook uses
   but is not a general expression language. A hook runs before every tool call,
   so a language runtime per call is not viable.
5. **The input-not-mutated assertion.** Unrepresentable — the data is immutable.
   Its positive half is preserved.
6. **Introspection-based capsule assertion.** One retired test asserted by naming
   convention that no derivation existed for a register state lacking lifecycle
   enforcement. The derivation is now one function with a failing catch-all
   clause, so the property is asserted directly at the call site.
7. **The read-only-reviewer property of the bootstrap aggregate.** The aggregate
   now calls Mix, and Mix needs a writable build directory, so it no longer runs
   under an effectively read-only reviewer without one. This follows from the
   accepted migration itself rather than from a choice made here. The read-only
   inspection lane remains the gate runner's prefix before it allocates storage,
   and a reviewer may direct the build into an explicit isolated task root;
   `DEVELOPMENT.md` records both.
8. **A gitignore probe naming a retired path.** Replaced by two probes covering
   the same pattern classes.
