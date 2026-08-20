# M0 Self-Hosting Report

Produced by `mix loopex.self_hosting` when outcome 8 runs. Records what the
Elixir replacement measures and what it dropped from the retired bridge, so a
reviewer can judge whether the result is proportionate.

The size figure is audit material. No run passes or fails on it.

- measured size: reported by `mix loopex.self_hosting`, which prints a per-file
  breakdown and a total. The figure at the closure candidate is recorded in the
  run log below. It is deliberately not restated in prose elsewhere: it was
  transcribed into three places and went stale twice, once because the commit that
  recorded it changed the number it recorded.
- dropped behaviors: eight, listed below and printed in full by the same command so
  the list cannot drift from the figure
- recorded: 2026-08-17 on Elixir 1.20.3 / OTP 29.0.5

## Measurement at the closure candidate

Taken by running `mix loopex.self_hosting`, not transcribed:

```text
documentation 1719   comment 412   blank 1395   code 6232   total 9758
```

Against the 4,462-line gate-commit baseline the plan binds, that is
2.19x. Against the 4,688 lines those files actually held at the
revision they were retired, it is 2.08x. Both are stated because a
reader comparing to the deleted files computes the second, and the two numbers are
different.

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

Eight, with the reason each was dropped rather than ported. Items 1, 4 and 7 are
the ones a reviewer should look at hardest, because they are the ones that change
what the repository can detect or where it can run. Item 4 was previously described
as not affecting detection; a review demonstrated otherwise, and that correction is
part of why it is called out here.

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
   so a language runtime per call is not viable. **This one is a detection change
   and is listed below with items 1 and 7 for that reason.** Two reviews found real
   bypasses in it: escapes left unresolved, so an ordinary JSON spelling of a
   protected path passed a guard; then keys left raw and duplicates taking the
   first value, which allowed an escaped key alias and a decoy. All are fixed, and
   decoding is now done once on the returned value and written out in pieces,
   because decoding every candidate by string concatenation was quadratic and could
   push a hook past its configured timeout — where the client sees exit 124, which
   does not block. What remains dropped is the general query language, not escape
   handling.
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
