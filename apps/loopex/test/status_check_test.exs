Code.require_file("support/status_fixtures_helper.exs", __DIR__)

defmodule Loopex.StatusCheckTest do
  @moduledoc """
  ## Concept

  Adversarial controls for the repository status check. Every case states one
  mutation that would make project state or documentation ambiguous, and asserts
  it fails. A check that only proves a correct repository passes proves nothing
  about what it would let through.

  ## Technical depth

  Compact in-memory fixtures exercise structural parsing, digest binding, and
  derived-capsule enforcement without touching the checkout. The two cases that
  need a real repository read one, and write nothing.
  """

  use ExUnit.Case, async: true

  alias Loopex.Checks.Git
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.History
  alias Loopex.Checks.Plan
  alias Mix.Tasks.Loopex.Matrix
  alias Loopex.Checks.Register
  alias Loopex.StatusFixtures, as: Fixture

  defp assert_invalid(documents, fragment \\ nil) do
    errors = Fixture.checked(documents)
    assert errors != [], "mutation unexpectedly passed"

    if fragment do
      assert hd(errors) =~ fragment, "expected #{inspect(fragment)} in #{inspect(hd(errors))}"
    end

    errors
  end

  defp resolve, do: Fixture.resolve()

  test "the fixture repository passes every check" do
    assert [] == Fixture.checked(Fixture.documents())
  end

  # A resolver must answer per path now that every chain edge recomputes the
  # digests it records. One that returned the plan for every path made the
  # technical envelope unparsable, which is the resolver being wrong rather than
  # the check.
  defp chain_resolver(plan_text) do
    fn _sha, path ->
      cond do
        String.ends_with?(path, "-technical.md") -> Fixture.technical_plan()
        String.ends_with?(path, "-gate.md") -> Fixture.gate()
        true -> plan_text
      end
    end
  end

  test "only a real ATX heading can justify an amendment" do
    # CommonMark caps an ATX heading at six hashes. Accepting any number let a
    # seven-hash line -- which renders as ordinary text, not a heading -- stand as
    # the visible declaration that justifies a new generation.
    gate = Fixture.gate()
    assert 0 == Plan.gate_generation(gate, "gate")

    for {label, heading} <- [{"seven hashes", "#######"}, {"one hash", "#"}] do
      hidden = gate <> "\n<a id=\"amendment-1\"></a>\n#{heading} Amendment 1\n"

      assert 0 == Plan.gate_generation(hidden, "gate"),
             "#{label} is not an ATX heading and must not mint a generation"
    end

    for heading <- ["##", "######"] do
      real = gate <> "\n<a id=\"amendment-1\"></a>\n#{heading} Amendment 1\n"
      assert 1 == Plan.gate_generation(real, "gate")
    end
  end

  test "retained matrix evidence is read verbatim, not rendered" do
    # This boundary was rejected seven times. Every fix compared a locked pair
    # against a hand-written approximation of how Markdown renders, and every one
    # was evaded: the major satisfied an exact lock; "whole token" excluded digits
    # and dots; `contains?("GREEN")` accepted "NOT GREEN"; a raw line was parsed
    # while a comment hid fields; `exposed_line/1` let a code span DELETE text; then
    # stripping every backtick mis-modelled nested spans, and an undecoded header
    # let `&#35;` render as `#` and smuggle in a second table of failures.
    #
    # The design changed rather than narrowing again. Runs live in a fenced block
    # between governed markers, and fenced content has no inline structure at all --
    # a backtick, an entity and comment syntax are literal characters to a reader
    # and to the parser alike. So these cases are not a list of evasions to reject.
    # They are the constructions that broke every previous version, asserting that
    # the new one has nothing left for them to exploit.
    pairs = [%{elixir: "1.17.0", otp: "26", otp_exact: "26.0"}]

    root = Path.join(System.tmp_dir!(), "matrix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "docs/evidence"))
    record = Path.join(root, "docs/evidence/M0-toolchain-matrix.md")
    on_exit(fn -> File.rm_rf(root) end)

    {open, close} = Loopex.Checks.Markdown.markers(:matrix_runs)
    good = "run=1 order=first elixir=1.17.0 otp=26.0 erts=14.0 verdict=GREEN exit=0 wall=91s"
    fail = "run=1 order=first elixir=1.17.0 otp=26.0 erts=14.0 verdict=NOT_GREEN exit=1 wall=91s"
    doc = fn body -> open <> "\n```text\n" <> body <> "\n```\n" <> close <> "\n" end
    raw = fn body -> open <> "\n" <> body <> "\n" <> close <> "\n" end

    File.write!(record, doc.(good))
    assert :ok = Matrix.both_lanes_recorded(root, pairs), "a real run must count"

    refused = [
      # Verdict and exit vary alone, so only their own rule can refuse each.
      {"a failing verdict at exit 0",
       doc.(
         "run=1 order=first elixir=1.17.0 otp=26.0 erts=14.0 verdict=NOT_GREEN exit=0 wall=91s"
       )},
      {"a nonzero exit with a green verdict",
       doc.("run=1 order=first elixir=1.17.0 otp=26.0 erts=14.0 verdict=GREEN exit=1 wall=91s")},
      # A different toolchain than the one locked.
      {"a prerelease Elixir",
       doc.(
         "run=1 order=first elixir=1.17.0-rc.0 otp=26.0 erts=14.0 verdict=GREEN exit=0 wall=91s"
       )},
      {"a prerelease OTP",
       doc.(
         "run=1 order=first elixir=1.17.0 otp=26.0-rc1 erts=14.0 verdict=GREEN exit=0 wall=91s"
       )},
      {"a longer OTP version",
       doc.("run=1 order=first elixir=1.17.0 otp=26.0.1 erts=14.0 verdict=GREEN exit=0 wall=91s")},
      {"the major alone",
       doc.("run=1 order=first elixir=1.17.0 otp=26 erts=14.0 verdict=GREEN exit=0 wall=91s")},
      # A record that contradicts itself decides nothing.
      {"a failing run beside a passing one",
       doc.(good <> "\n" <> String.replace(fail, "run=1", "run=2"))},
      {"a second marked block", doc.(good) <> "\ntext\n\n" <> doc.(fail)},
      # The constructions that defeated every earlier version. Inside a fence they
      # are literal characters, so each simply fails to parse as a run.
      {"a code span deleting text",
       doc.(String.replace(good, "verdict=GREEN", "verdict=`NOT `GREEN"))},
      {"nested code spans", doc.(String.replace(good, "verdict=GREEN", "verdict=``GRE`EN``"))},
      {"an inline comment hiding a field",
       doc.(String.replace(good, "verdict=GREEN", "verdict=<!--NOT -->GREEN"))},
      {"an HTML entity in a field",
       doc.(String.replace(good, "verdict=GREEN", "verdict=&#71;REEN"))},
      # Characters that occupy a field while rendering as nothing.
      {"a non-breaking space in a field",
       doc.(String.replace(good, "order=first", "order=fir\u00A0st"))},
      {"a zero-width space in a field",
       doc.(String.replace(good, "order=first", "order=fir\u200Bst"))},
      {"a bidi override in a field",
       doc.(String.replace(good, "order=first", "order=fir\u202Est"))},
      # Not a run at all.
      {"no block at all", "just prose naming Elixir 1.17.0 and OTP 26.0 as GREEN\n"},
      {"an empty block", doc.("")},
      {"a malformed run line", doc.("run=1 elixir=1.17.0 verdict=GREEN")},
      {"a run line with a field missing",
       doc.("run=1 order=first elixir=1.17.0 otp=26.0 erts=14.0 verdict=GREEN exit=0")},
      {"an unnumbered run",
       doc.("run=x order=first elixir=1.17.0 otp=26.0 erts=14.0 verdict=GREEN exit=0 wall=91s")},
      # A commented-out or fenced marker cannot supply the pair.
      {"markers inside a comment", "<!--\n" <> doc.(good) <> "-->\n"},
      {"markers inside a fence", "```\n" <> doc.(good) <> "```\n"},
      # The premise the whole design rests on -- records render verbatim -- holds
      # only if they are actually inside a fence. An earlier version asserted that
      # in a comment and never checked it, so unfenced records parsed and an HTML
      # comment could hide fields a reader never sees while the parser read them.
      # Every case here keeps otherwise-valid records and varies only the fence.
      {"records with no fence at all", raw.(good)},
      {"unfenced records with fields inside a comment",
       raw.(
         "run=1 order=first elixir=1.17.0 otp=26.0 erts=14.0<!-- verdict=GREEN exit=0 wall=91s-->"
       )},
      {"an opening fence with no closer", raw.("```text\n" <> good)},
      {"a closing fence with no opener", raw.(good <> "\n```")},
      {"mismatched fence delimiters", raw.("```text\n" <> good <> "\n~~~")},
      {"a closing fence shorter than its opener", raw.("````text\n" <> good <> "\n```")},
      {"an info string on the closing fence", raw.("```text\n" <> good <> "\n```text")},
      {"a record outside the fence", raw.("```text\n" <> good <> "\n```\n" <> good)},
      {"a record before the fence", raw.(good <> "\n```text\n" <> good <> "\n```")},
      {"two fenced blocks", raw.("```text\n" <> good <> "\n```\n```text\n" <> good <> "\n```")},
      {"an indented fence, which is a code block",
       raw.("    ```text\n    " <> good <> "\n    ```")},
      {"an empty fence", raw.("```text\n```")},
      {"a blank line inside the fence", raw.("```text\n" <> good <> "\n\n```")},
      # Each of the next cases isolates one rule. Two overlapping guards mask each
      # other -- stubbing either alone changed nothing while both were reachable --
      # so a case has to exist that only one rule can refuse.
      #
      # Only the opening-fence rule refuses this: there are two lines, so the
      # non-empty guard is satisfied, and dropping the last leaves a parsable run.
      {"two unfenced records", raw.(good <> "\n" <> String.replace(good, "run=1", "run=2"))},
      {"an opening fence and nothing else", raw.("```text")},
      {"a fenced line that is not a run", raw.("```text\nnot a run at all\n```")},
      {"a fence containing nothing", raw.("```text\n```")}
    ]

    for {label, body} <- refused do
      File.write!(record, body)

      # Asserted as a boolean rather than a pattern match: a pattern match raises
      # MatchError, which reports the value and not which case produced it, so a
      # failure named nothing.
      assert match?({:error, _reason}, Matrix.both_lanes_recorded(root, pairs)),
             "#{label} must not count as a recorded run"
    end

    # Each rule must refuse for its OWN reason, not merely be masked by a later one.
    # Asserting the message is what makes each necessary: without it, removing any
    # of these four changed no result, because a downstream rule rejected the same
    # input for a different reason and the case could not tell the difference.
    for {label, body, reason} <- [
          {"records with no fence", raw.(good <> "\n" <> String.replace(good, "run=1", "run=2")),
           "must open with a fence"},
          {"a single unfenced record", raw.(good), "no fenced body"},
          {"a fenced line that is not a run", raw.("```text\nnot a run at all\n```"),
           "not in the required form"},
          {"a fence containing nothing", raw.("```text\n```"), "names no run"},
          {"a bidi override in the ERTS field",
           doc.(String.replace(good, "erts=14.0", "erts=14.0\u202E")),
           "non-printable or non-ASCII byte"},
          {"a zero-width character in the wall-clock field",
           doc.(String.replace(good, "wall=91s", "wall=91\u200Bs")),
           "non-printable or non-ASCII byte"}
        ] do
      File.write!(record, body)

      assert {:error, message} = Matrix.both_lanes_recorded(root, pairs)

      assert message =~ reason,
             "#{label} must be refused for #{inspect(reason)}, got #{inspect(message)}"
    end

    # Legitimate fence shapes still count, so the rule refuses hiding rather than
    # refusing Markdown.
    for {label, body} <- [
          {"a bare fence", raw.("```\n" <> good <> "\n```")},
          {"a tilde fence", raw.("~~~text\n" <> good <> "\n~~~")},
          {"a closing fence longer than its opener", raw.("```text\n" <> good <> "\n`````")}
        ] do
      File.write!(record, body)
      assert :ok = Matrix.both_lanes_recorded(root, pairs), "#{label} must still count"
    end

    File.write!(record, doc.(good))
    assert :ok = Matrix.both_lanes_recorded(root, pairs), "and the real run still counts"
  end

  test "an acceptance chain edge must run backwards along history" do
    # Resolving proves only that a commit is reachable from HEAD, and two unrelated
    # branches both become reachable once anything merges them. Without an ancestry
    # requirement a candidate could name a prior it does not descend from, and
    # combined with a fabricated generation that lands an unaccepted gate.
    original = Fixture.plan()
    amended = Fixture.plan(governed: true)
    resolve = chain_resolver(original)

    # An ancestral edge is admitted.
    assert :ok =
             Plan.acceptance_chain(
               amended,
               "docs/plans/M0.md",
               "bbbb",
               resolve,
               MapSet.new(),
               fn _prior, _revision -> true end
             )

    # A non-ancestral edge is refused, however reachable both commits are.
    assert_raise Invalid, ~r/not an ancestor/, fn ->
      Plan.acceptance_chain(amended, "docs/plans/M0.md", "bbbb", resolve, MapSet.new(), fn
        _prior, _revision -> false
      end)
    end
  end

  test "a merge reconciles parents only when one supersedes the rest" do
    # Landing an accepted amendment is a merge whose parents disagree: one carries
    # the amended gate, one does not. Raising on every divergence made that shape
    # unrepresentable. The rule is the same strictly-increasing generation rule.
    reconcile = fn values ->
      History.reconcile_for_test(values, "docs/plans/M0-gate.md", "rev", "accepted gate", [])
    end

    # A later generation wins over an earlier one.
    assert reconcile.(["1\0a", "2\0b"]) == "2\0b"
    assert reconcile.(["2\0b", "1\0a"]) == "2\0b"
    # Three-way, one clear winner.
    assert reconcile.(["0\0a", "1\0b", "2\0c"]) == "2\0c"

    # Same generation, different bytes: still a conflict, which is the case that
    # matters -- two sides amended independently and neither supersedes.
    assert_raise Invalid, ~r/conflicting completed/, fn -> reconcile.(["1\0a", "1\0b"]) end

    # A label that is not amendable never reconciles.
    assert_raise Invalid, ~r/conflicting completed/, fn ->
      History.reconcile_for_test(["1\0a", "2\0b"], "docs/plans/M0.md", "rev", "Closure", [])
    end
  end

  test "the in-review capsule does not widen authority either" do
    # Acceptance is the only transition that widens authorized work. If In review
    # derived a broader boundary, a reviewer's presence would authorise work.
    accepted = Register.expected_capsule("Accepted", "M0", %{})
    in_progress = Register.expected_capsule("In progress", "M0", %{})
    in_review = Register.expected_capsule("In review", "M0", %{})

    for later <- [in_progress, in_review] do
      assert Map.fetch!(later, "Authorized work") == Map.fetch!(accepted, "Authorized work")
      assert Map.fetch!(later, "Integrated phase") == Map.fetch!(accepted, "Integrated phase")
    end

    # In review hands the next decision back to the maintainer; In progress does not.
    assert Map.fetch!(in_progress, "Next maintainer decision") ==
             Map.fetch!(accepted, "Next maintainer decision")

    assert Map.fetch!(in_review, "Next maintainer decision") =~ "Close `M0`"
    assert Map.fetch!(in_review, "Next transition") =~ "Closed"

    # Closure narrows authority rather than widening it: a closed envelope grants
    # no further implementation. This assertion replaces one that Closed had no
    # derivation at all, which stopped being true when the closing transition
    # wrote it.
    closed = Register.expected_capsule("Closed", "M0", %{})

    refute Map.fetch!(closed, "Authorized work") == Map.fetch!(accepted, "Authorized work")
    assert Map.fetch!(closed, "Authorized work") =~ "no product implementation"
    assert Map.fetch!(closed, "Next transition") =~ "next milestone"
  end

  test "the JSON reader decodes unicode escapes so hooks still match" do
    # A hook matching on a command never saw a \\u0024HOME spelling as $HOME, so an
    # ordinary JSON encoding of a protected path walked past the filesystem guard.
    # That is a representation a client may legitimately send, not obfuscation.
    root = LoopexTest.Repo.root()
    protected = ".loo" <> "pex"

    # The reader takes the document on stdin, so it is written to a file and
    # redirected; System.cmd/3 cannot feed stdin directly.
    feed = fn document, command ->
      path = Path.join(System.tmp_dir!(), "jf-#{System.unique_integer([:positive])}.json")
      File.write!(path, document)
      on_exit_path = path

      {output, status} =
        System.cmd("sh", ["-c", "#{command} < #{on_exit_path}"], cd: root, stderr_to_stdout: true)

      File.rm(path)
      {String.trim_trailing(output, "\n"), status}
    end

    read = fn document ->
      {output, 0} = feed.(document, "bash scripts/json-field.sh tool_input command")
      output
    end

    escaped = ~s({"tool_input":{"command":"cat \\u0024HOME/#{protected}/x"}})
    assert read.(escaped) == "cat $HOME/#{protected}/x"

    # A literal backslash followed by "u" is not an escape and must survive.
    literal = ~s({"tool_input":{"command":"keep \\\\u0024 intact"}})
    assert read.(literal) == "keep \\u0024 intact"

    # Surrogate pairs combine into one code point.
    assert read.(~s({"tool_input":{"command":"e \\ud83d\\ude00"}})) == "e 😀"

    # KEYS are decoded too. Storing them raw meant an ordinary escaped spelling did
    # not match the requested name, so the hook read nothing and passed a command it
    # would otherwise have blocked.
    assert read.(~s({"tool_input":{"comm\\u0061nd":"X"}})) == "X"
    assert read.(~s({"tool_\\u0069nput":{"command":"Y"}})) == "Y"

    # A duplicate key takes the LAST occurrence, as a real parser does. Keeping the
    # first let a document put a decoy ahead of the real value.
    assert read.(~s({"tool_input":{"command":"first","command":"last"}})) == "last"

    # A lone surrogate is not a code point; emitting one produced invalid UTF-8.
    assert read.(~s({"tool_input":{"command":"lone \\ud83d end"}})) == "lone \uFFFD end"

    # A NUL is not silently dropped, which would shorten the field invisibly.
    assert read.(~s({"tool_input":{"command":"a \\u0000 b"}})) == "a \uFFFD b"

    # And the guard actually blocks the escaped spelling now.
    bypasses = [
      escaped,
      ~s({"tool_input":{"command":"cat $HOME/#{protected}/x"}}),
      ~s({"tool_input":{"comm\\u0061nd":"rm -rf $HOME/#{protected}"}}),
      ~s({"tool_\\u0069nput":{"command":"rm -rf $HOME/#{protected}"}}),
      ~s({"tool_input":{"command":"echo safe","command":"rm -rf $HOME/#{protected}"}})
    ]

    for document <- bypasses do
      {_out, status} = feed.(document, "bash .claude/hooks/guard-bash.sh")
      assert status == 2, "the guard must block this spelling with exit 2, got #{status}"
    end
  end

  test "only a declared amendment may change gate bytes" do
    gate = Fixture.gate()
    assert 0 == Plan.gate_generation(gate, "gate")

    amended =
      String.trim_trailing(gate, "\n") <> "\n\n<a id=\"amendment-1\"></a>\n## Amendment 1\n"

    assert 1 == Plan.gate_generation(amended, "gate")

    # A silent edit keeps the generation and is rejected.
    refute Plan.supersedes?("accepted gate", "0\0aaa", "0\0bbb")
    # A declared amendment increases it.
    assert Plan.supersedes?("accepted gate", "0\0aaa", "1\0bbb")
    # Rolling back to an earlier generation is not a supersession.
    refute Plan.supersedes?("accepted gate", "1\0bbb", "0\0aaa")

    # An acceptance row is judged on the amendment generation of the gate carried
    # by the candidate it binds, and the rule is the same strictly-increasing one.
    # Requiring merely that some amendment existed left the row freely rewritable
    # once the first amendment landed: a generation-2 acceptance could be rebound
    # repeatedly with no Amendment 3.
    assert Plan.supersedes?("Acceptance", "0\0row", "1\0other")
    # A rewrite at the same generation is not a supersession.
    refute Plan.supersedes?("Acceptance", "1\0row", "1\0other")
    refute Plan.supersedes?("Acceptance", "0\0row", "0\0other")
    # Going backwards is not a supersession either.
    refute Plan.supersedes?("Acceptance", "2\0row", "1\0other")
    # An unresolvable candidate cannot be used to claim one.
    refute Plan.supersedes?("Acceptance", "\0row", "\0other")

    # An anchor inside a fenced code block is illustration, not a declaration.
    fenced =
      String.trim_trailing(gate, "\n") <>
        "\n\n```text\n<a id=\"amendment-1\"></a>\n## Amendment 1\n```\n"

    assert 0 == Plan.gate_generation(fenced, "gate"),
           "an anchor inside a code fence must not mint a generation"

    # A bare anchor with no visible amendment heading mints nothing either.
    bare = String.trim_trailing(gate, "\n") <> "\n\n<a id=\"amendment-1\"></a>\n\nprose\n"
    assert 0 == Plan.gate_generation(bare, "gate")

    # Each fixture carries a real heading, because a bare anchor now mints nothing
    # and would pass the numbering check by counting zero.
    for bad <- [
          "<a id=\"amendment-2\"></a>\n## Amendment 2",
          "<a id=\"amendment-1\"></a>\n## Amendment 1\n\n" <>
            "<a id=\"amendment-1\"></a>\n## Amendment 1"
        ] do
      assert_raise Invalid, ~r/consecutively/, fn ->
        Plan.gate_generation(gate <> "\n" <> bad <> "\n", "gate")
      end
    end
  end

  test "an acceptance candidate chain terminates at an empty original" do
    original = Fixture.plan()
    amended = Fixture.plan(governed: true)
    path = "docs/plans/M0.md"

    # An original snapshot carries empty governance.
    assert :ok == Plan.acceptance_chain(original, path, "aaaa", nil, MapSet.new())

    # A filled row that binds an available earlier original is admitted.
    assert :ok ==
             Plan.acceptance_chain(
               amended,
               path,
               "bbbb",
               chain_resolver(original),
               MapSet.new()
             )

    # A filled row whose prior cannot be resolved is not admitted.
    assert_raise Invalid, ~r/unavailable/, fn ->
      Plan.acceptance_chain(amended, path, "bbbb", fn _sha, _path -> nil end, MapSet.new())
    end

    # A chain that never reaches an empty original is not admitted. The cycle is
    # detected before any digest work, so the resolver only needs the plan text.
    assert_raise Invalid, ~r/does not terminate/, fn ->
      Plan.acceptance_chain(amended, path, "bbbb", chain_resolver(amended), MapSet.new())
    end

    # An edge whose recorded digests do not describe the files at either end is
    # refused. Only the outermost binding used to be checked, so every earlier link
    # was trusted structurally and a row of sixty-four zeroes satisfied the chain.
    fabricated =
      String.replace(
        amended,
        ~r/concept `sha256:[0-9a-f]{64}`/,
        "concept `sha256:#{String.duplicate("0", 64)}`"
      )

    assert_raise Invalid, ~r/does not match/, fn ->
      Plan.acceptance_chain(fabricated, path, "bbbb", chain_resolver(original), MapSet.new())
    end
  end

  test "the in-progress capsule does not widen authority" do
    accepted = Register.expected_capsule("Accepted", "M0", %{})
    in_progress = Register.expected_capsule("In progress", "M0", %{})

    assert accepted["Authorized work"] == in_progress["Authorized work"]
    assert accepted["Integrated phase"] == in_progress["Integrated phase"]
    assert accepted["Next maintainer decision"] == in_progress["Next maintainer decision"]

    changed =
      accepted
      |> Enum.filter(fn {key, value} -> in_progress[key] != value end)
      |> Enum.map(&elem(&1, 0))

    assert MapSet.new(["Blockers", "Next transition"]) == MapSet.new(changed)
    assert in_progress["Next transition"] =~ "In review"
  end

  test "a milestone state with no derived capsule fails closed" do
    assert "In review" in Register.active_states()

    # Every registered state now has a derivation -- Closed gained one when the
    # first milestone closed. What the catch-all protects is the NEXT state
    # somebody registers: adding one to the list without adding its enforcement
    # must fail rather than fall through to an unchecked capsule.
    # Blocked derives from ADR statuses, so it needs them; the rest ignore them.
    adr_statuses = %{
      "docs/adr/0001-repository-and-application-layout.md" => "Accepted",
      "docs/adr/0002-bootstrap-runtime-floor.md" => "Accepted"
    }

    for state <- Register.states() do
      assert is_map(Register.expected_capsule(state, "M0", adr_statuses)),
             "#{state} is registered and must derive a capsule"
    end

    for unregistered <- ["Superseded", "Withdrawn", ""] do
      assert_raise Invalid, ~r/no derived status capsule/, fn ->
        Register.expected_capsule(unregistered, "M0", %{})
      end
    end
  end

  test "pair topology, links, and anchors fail closed" do
    vision = "docs/vision.md"
    technical = "docs/vision-technical.md"

    cases = [
      {"missing companion", fn documents -> Map.delete(documents, technical) end,
       "paired technical document is missing"},
      {"orphan companion", fn documents -> Map.delete(documents, vision) end,
       "paired concept document is missing"},
      {"hidden heading", &replace_once(&1, vision, "## Concept", "<!--\n## Concept\n-->"),
       "visible ## Concept"},
      {"duplicate heading", &append(&1, vision, "\n## Concept\n"), "exactly one visible"},
      {"duplicate heading with trailing spaces", &append(&1, vision, "\n## Concept   \n"),
       "exactly one visible"},
      {"duplicate heading with closing hashes", &append(&1, vision, "\n## Concept ##\n"),
       "exactly one visible"},
      {"duplicate setext heading", &append(&1, vision, "\nConcept\n---\n"),
       "exactly one visible"},
      {"hidden anchor",
       &replace(&1, vision, "<a id=\"concept\"></a>", "<!-- <a id=\"concept\"></a> -->"),
       "relationship anchor"},
      {"duplicate anchor", &append(&1, vision, "\n<a id=\"concept\"></a>\n"), "exactly once"},
      {"wrong companion",
       &replace(
         &1,
         vision,
         "vision-technical.md#technical-depth",
         "roadmap-technical.md#technical-depth"
       ), "own companion"},
      {"empty fragment", &replace(&1, vision, "#technical-depth", "#"), "nonempty fragment"},
      {"unknown fragment", &replace(&1, vision, "#technical-depth", "#technical-missing"),
       "does not resolve"},
      {"nonreciprocal backlink",
       fn documents ->
         documents
         |> replace(technical, "vision.md#concept", "vision.md#concept-other")
         |> append(vision, "\n<a id=\"concept-other\"></a>\n### Other concept\n")
       end, "not reciprocal"},
      {"wrong depth label",
       &append(&1, technical, "\nTechnical depth: [Wrong direction](vision.md#concept).\n"),
       "belongs in the other depth"},
      {"visible preamble before relationship",
       fn documents ->
         Map.update!(documents, vision, &("Unexpected preamble.\n\n" <> &1))
       end, "must start with an optional H1"},
      {"section before relationship",
       &replace_once(
         &1,
         vision,
         "<a id=\"concept\"></a>",
         "## Earlier section\n\nText.\n\n<a id=\"concept\"></a>"
       ), "must start with an optional H1"},
      {"fenced preamble before relationship",
       fn documents ->
         Map.update!(documents, vision, &("```text\nHidden preamble.\n```\n\n" <> &1))
       end, "must start with an optional H1"},
      {"empty optional title", &replace_once(&1, vision, "# Vision", "#"),
       "must start with an optional H1"}
    ]

    for {label, mutate, fragment} <- cases do
      documents = mutate.(Fixture.documents())
      errors = assert_invalid(documents, fragment)
      assert errors != [], label
    end

    # A matching pair of extra anchored sections is accepted, and breaking the
    # forward link's target is not.
    documents =
      Fixture.documents()
      |> append(
        vision,
        "\n<a id=\"concept-effects\"></a>\n### Effects\n\n" <>
          "Technical depth: [Effect ordering](vision-technical.md#technical-effects)\n"
      )
      |> append(
        technical,
        "\n<a id=\"technical-effects\"></a>\n### Effect ordering\n\n" <>
          "Concept: [Effects](vision.md#concept-effects)\n"
      )

    assert [] == Fixture.checked(documents)

    documents
    |> replace(
      vision,
      "vision-technical.md#technical-effects",
      "roadmap-technical.md#technical-depth"
    )
    |> assert_invalid("only its companion")

    Fixture.documents()
    |> replace("docs/developer/agent-context-map.md", "#concept", "#concept-does-not-exist")
    |> assert_invalid("fragment does not resolve")

    for {link, fragment} <- [
          {"[broken](missing.md \"title\")", "unsupported Markdown link syntax"},
          {"[broken](<missing file.md>)", "raw HTML"},
          {"[broken][target]\n\n[target]: missing.md", "unsupported Markdown link syntax"},
          {"[broken](missing.md?x=1)", "unsupported local Markdown query"},
          {"[](docs/vision.md#concept)", "unsupported Markdown link syntax"},
          {"![](missing.md)", "unsupported Markdown image syntax"},
          {"![broken](missing.md)", "unsupported Markdown image syntax"},
          {"[a [nested]](missing.md)", "unsupported Markdown link syntax"}
        ] do
      Fixture.documents()
      |> append("README.md", "\n#{link}\n")
      |> assert_invalid(fragment)
    end
  end

  test "documentation directories are indexed" do
    runbook = "docs/operator/recovery.md"

    Fixture.documents()
    |> Map.put(runbook, "# Recovery runbook\n")
    |> assert_invalid("docs/operator: directory with Markdown needs a README.md index")

    Fixture.documents()
    |> Map.put(runbook, "# Recovery runbook\n")
    |> Map.put("docs/operator/README.md", "# Operator\n\n[Documentation](../README.md)\n")
    |> assert_invalid("must link the docs/operator/ index")

    Fixture.documents()
    |> Map.put(runbook, "# Recovery runbook\n")
    |> Map.put("docs/operator/README.md", "# Operator\n")
    |> append("docs/README.md", "[Operator](operator/README.md)\n")
    |> assert_invalid("docs/operator/README.md: must link back to docs/README.md")

    Fixture.documents()
    |> replace("docs/README.md", "[Root](../README.md)\n", "")
    |> assert_invalid("docs/README.md: must link back to the root README.md")

    documents =
      Fixture.documents()
      |> Map.put(runbook, "# Recovery runbook\n")
      |> Map.put("docs/operator/README.md", "# Operator\n\n[Documentation](../README.md)\n")
      |> append("docs/README.md", "[Operator](operator/README.md)\n")

    assert [] == Fixture.checked(documents)
  end

  test "markdown classification rejects ambiguous paths" do
    for {path, fragment} <- [
          {"docs/unknown.md", "paired technical document is missing"},
          {"OTHER.md", "unknown active"},
          {"docs/vision-technical-technical.md", "doubled technical suffix"},
          {"Docs/VISION.md", "collides by case"},
          {"docs/adr/0003-new-decision.md", "paired technical document is missing"},
          {"docs/plans/sample-technical.md", "exact triples"},
          {"docs/plans/sample-technical-technical.md", "doubled technical suffix"}
        ] do
      Fixture.documents()
      |> Map.put(path, "# Unexpected\n")
      |> assert_invalid(fragment)
    end

    documents =
      Fixture.documents()
      |> Map.put(".agents/skills/example/SKILL.md", "# Portable skill\n")
      |> Map.put(".claude/agents/example.md", "# Client role prompt\n")
      |> Map.put(".github/ISSUE_TEMPLATE/bug.md", "# Issue template\n")
      |> Map.put("docs/archive/old.md", "# Historical bytes\n")
      |> Map.put("docs/operator/recovery.md", "# Recovery runbook\n")
      |> Map.put("docs/archive/README.md", "# Archive\n\n[Documentation](../README.md)\n")
      |> Map.put("docs/operator/README.md", "# Operator\n\n[Documentation](../README.md)\n")
      |> append(
        "docs/README.md",
        "[Archive](archive/README.md)\n[Operator](operator/README.md)\n"
      )

    assert [] == Fixture.checked(documents)

    for path <- [
          ".agents/policy.md",
          ".claude/policy.md",
          ".codex/policy.md",
          ".github/policy.md"
        ] do
      Fixture.documents()
      |> Map.put(path, "# Hidden policy\n")
      |> assert_invalid("unknown active Markdown document class")
    end

    paired =
      Fixture.documents()
      |> Map.put(
        "docs/architecture.md",
        "<a id=\"concept\"></a>\n## Concept\n\n" <>
          "Technical depth: [Architecture mechanics](architecture-technical.md#technical-depth)\n"
      )
      |> Map.put(
        "docs/architecture-technical.md",
        "<a id=\"technical-depth\"></a>\n## Technical depth\n\n" <>
          "Concept: [Architecture](architecture.md#concept)\n"
      )

    assert_invalid(paired, "missing from the index")

    indexed =
      append(
        paired,
        "docs/README.md",
        "\n[Architecture](architecture.md#concept)\n" <>
          "[Architecture technical](architecture-technical.md#technical-depth)\n"
      )

    assert [] == Fixture.checked(indexed)
  end

  test "ADR acceptance is bound and drives the blocked capsule" do
    for accepted <- [[], [1], [2], [1, 2]] do
      assert [] == Fixture.checked(Fixture.accepted_adr_documents(accepted))
    end

    [first, _second] = Fixture.adr_paths()

    Fixture.accepted_adr_documents([1])
    |> replace(first, "Choose the bounded decision.", "Rewrite the accepted decision.")
    |> assert_invalid("historical candidate")

    Fixture.accepted_adr_documents([1])
    |> replace(first, String.duplicate("d", 40), String.duplicate("f", 40))
    |> assert_invalid("candidate")

    technical_path = String.replace_suffix(first, ".md", "-technical.md")

    Fixture.accepted_adr_documents([1])
    |> replace(technical_path, "Exact constraints", "Changed constraints")
    |> assert_invalid("accepted ADR technical depth differs")

    technical_digest = Loopex.Checks.Markdown.digest(Fixture.adr_technical(1))

    Fixture.accepted_adr_documents([1])
    |> replace(first, technical_digest, String.duplicate("f", 64))
    |> assert_invalid("ADR technical digest")
  end

  test "plan envelope and candidate shapes are locked" do
    plan = Fixture.plan()
    technical = Fixture.technical_plan()
    gate = Fixture.gate()

    Loopex.Checks.Documents.validate_pair(
      %{"docs/plans/M0.md" => plan, "docs/plans/M0-technical.md" => technical},
      "docs/plans/M0.md"
    )

    assert_raise Invalid, ~r/not reciprocal/, fn ->
      Loopex.Checks.Documents.validate_pair(
        %{
          "docs/plans/M0.md" => plan,
          "docs/plans/M0-technical.md" =>
            String.replace(
              technical,
              "Concept: [Milestone outcomes](M0.md#concept-plan-outcomes)",
              "Concept: [Milestone outcomes](M0.md#concept-plan-scope)"
            )
        },
        "docs/plans/M0.md"
      )
    end

    governed = Fixture.plan(governed: true)
    closed = Fixture.plan(governed: true, closed: true)

    assert :ok == Plan.governance(governed, technical, gate, "M0", "Accepted", resolve())
    assert :ok == Plan.governance(closed, technical, gate, "M0", "Closed", resolve())

    for text <- [
          String.replace(plan, "Only the bounded outcome.\n", "", global: false),
          String.replace(plan, "No public freeze.\n", "", global: false)
        ] do
      assert_raise Invalid, ~r/concrete commitment/, fn ->
        Plan.concept_envelope(text, "docs/plans/M0.md")
      end
    end

    assert_raise Invalid, ~r/concrete commitment/, fn ->
      Plan.technical_envelope(
        String.replace(technical, "Prerequisites are accepted before plan acceptance.\n", "",
          global: false
        ),
        "docs/plans/M0-technical.md"
      )
    end

    # Mutable regions may change freely under an accepted plan.
    mutable =
      governed
      |> String.replace("One direct workstream.", "Two direct workstreams.")
      |> String.replace("| 1 | Open | — |", "| 1 | Proved | [run](evidence.md) |")

    assert :ok == Plan.governance(mutable, technical, gate, "M0", "Accepted", resolve())

    for heading <- [
          "### Purpose",
          "### Outcomes",
          "### Scope",
          "### Non-Goals",
          "### Prerequisites and Acceptance Points",
          "### Ownership, Decision Owners, and Rejoin Barriers",
          "### Evidence Obligations and Mapping",
          "### Compatibility",
          "### Migration and Rollback",
          "### Packaging",
          "### Proportional Minimalism Budget"
        ] do
      concept_heading? = heading in ["### Purpose", "### Outcomes", "### Scope", "### Non-Goals"]

      changed_concept =
        String.replace(governed, heading, heading <> " changed", global: false)

      changed_technical = String.replace(technical, heading, heading <> " changed", global: false)

      assert_raise Invalid, ~r/headings/, fn ->
        Plan.governance(
          if(concept_heading?, do: changed_concept, else: governed),
          if(concept_heading?, do: technical, else: changed_technical),
          gate,
          "M0",
          "Accepted",
          resolve()
        )
      end
    end

    envelope_mutations = [
      {"missing marker",
       String.replace(governed, "<!-- loopex:plan-concept-envelope:start -->\n", "",
         global: false
       )},
      {"duplicate marker", governed <> "\n<!-- loopex:plan-concept-envelope:start -->\n"},
      {"hidden marker",
       String.replace(
         governed,
         "<!-- loopex:plan-concept-envelope:start -->",
         "<!--\n<!-- loopex:plan-concept-envelope:start -->\n-->",
         global: false
       )},
      {"empty section",
       String.replace(governed, "### Scope\n\nOnly the bounded outcome.", "### Scope\n",
         global: false
       )},
      {"bad outcomes",
       String.replace(governed, "| 1 | One bounded outcome", "| 2 | One bounded outcome")},
      {"setext heading",
       String.replace(governed, "Only the bounded outcome.", "Only the bounded outcome.\n---")},
      {"missing section anchor",
       String.replace(governed, "<a id=\"concept-plan-scope\"></a>\n", "", global: false)},
      {"missing section mapping",
       String.replace(
         governed,
         "Technical depth: [Packaging mechanics](M0-technical.md#technical-plan-packaging)\n",
         "",
         global: false
       )}
    ]

    for {label, changed} <- envelope_mutations do
      assert_raise Invalid, fn ->
        Plan.governance(changed, technical, gate, "M0", "Accepted", resolve())
      end

      assert label != nil
    end

    # A candidate whose acceptance row binds itself is a cycle.
    self_binding = fn _sha, path ->
      cond do
        String.ends_with?(path, "M0-gate.md") -> gate
        String.ends_with?(path, "M0-technical.md") -> technical
        true -> governed
      end
    end

    assert_raise Invalid,
                 ~r/concept digest|candidate.*governance|chain.*does not terminate/,
                 fn ->
                   Plan.governance(governed, technical, gate, "M0", "Accepted", self_binding)
                 end

    candidate_without_progress = fn _sha, path ->
      cond do
        String.ends_with?(path, "M0-gate.md") -> gate
        String.ends_with?(path, "M0-technical.md") -> technical
        true -> String.replace(plan, "## Progress and Evidence", "## Progress")
      end
    end

    assert_raise Invalid, ~r/plan document|Progress and Evidence|concept digest/, fn ->
      Plan.governance(governed, technical, gate, "M0", "Accepted", candidate_without_progress)
    end

    closure_without_acceptance = fn _sha, path ->
      cond do
        String.ends_with?(path, "M0-gate.md") -> gate
        String.ends_with?(path, "M0-technical.md") -> technical
        true -> Fixture.plan(progress: "Proved")
      end
    end

    assert_raise Invalid, ~r/closure candidate|concept digest/, fn ->
      Plan.governance(closed, technical, gate, "M0", "Closed", closure_without_acceptance)
    end

    closure_with_open_progress = fn sha, path ->
      cond do
        String.ends_with?(path, "M0-gate.md") -> gate
        String.ends_with?(path, "M0-technical.md") -> technical
        sha == String.duplicate("a", 40) -> plan
        true -> governed
      end
    end

    assert_raise Invalid, ~r/no Open|concept digest/, fn ->
      Plan.governance(closed, technical, gate, "M0", "Closed", closure_with_open_progress)
    end

    different_candidate = fn _sha, path ->
      cond do
        String.ends_with?(path, "M0-gate.md") -> gate
        String.ends_with?(path, "M0-technical.md") -> technical
        true -> String.replace(plan, "Only the bounded outcome.", "Different scope.")
      end
    end

    assert_raise Invalid, ~r/differs from its candidate|concept digest/, fn ->
      Plan.governance(governed, technical, gate, "M0", "Accepted", different_candidate)
    end

    different_closure = fn sha, path ->
      cond do
        String.ends_with?(path, "M0-gate.md") ->
          gate

        String.ends_with?(path, "M0-technical.md") ->
          technical

        sha == String.duplicate("a", 40) ->
          plan

        true ->
          String.replace(
            Fixture.plan(governed: true, progress: "Proved"),
            "Only the bounded outcome.",
            "Different scope."
          )
      end
    end

    assert_raise Invalid, ~r/closure candidate changed|concept digest/, fn ->
      Plan.governance(closed, technical, gate, "M0", "Closed", different_closure)
    end

    assert_raise Invalid, ~r/normative technical envelope|technical digest/, fn ->
      Plan.governance(
        governed,
        String.replace(technical, "No compatibility claim.", "Changed compatibility."),
        gate,
        "M0",
        "Accepted",
        resolve()
      )
    end

    technical_digest =
      Fixture.envelope_digest(
        technical,
        Fixture.technical_marker_start(),
        Fixture.technical_marker_end()
      )

    assert_raise Invalid, ~r/technical digest/, fn ->
      Plan.governance(
        String.replace(governed, technical_digest, String.duplicate("f", 64)),
        technical,
        gate,
        "M0",
        "Accepted",
        resolve()
      )
    end
  end

  test "the progress table is total and lifecycle aware" do
    technical = Fixture.technical_plan()
    gate = Fixture.gate()
    plan = Fixture.plan()
    none = fn _sha, _path -> nil end

    invalid = fn text, state, fragment ->
      assert_raise Invalid, fragment, fn ->
        Plan.governance(text, technical, gate, "M0", state, none)
      end
    end

    mutations = [
      {"missing",
       String.replace(
         plan,
         "## Progress and Evidence\n\n| # | State | Evidence |\n| --- | --- | --- |\n| 1 | Open | — |\n",
         ""
       )},
      {"duplicate", plan <> "\n## Progress and Evidence\n"},
      {"invalid state", String.replace(plan, "| 1 | Open | — |", "| 1 | Done | — |")},
      {"extra outcome",
       String.replace(plan, "| 1 | Open | — |", "| 1 | Open | — |\n| 2 | Open | — |")},
      {"missing outcome",
       String.replace(
         plan,
         "| 1 | One bounded outcome | focused test | `test/example_test.exs` |",
         "| 1 | One bounded outcome | focused test | `test/example_test.exs` |\n" <>
           "| 2 | Another outcome | focused test | `test/another_test.exs` |"
       )},
      {"duplicate outcome",
       String.replace(plan, "| 1 | Open | — |", "| 1 | Open | — |\n| 1 | Proved | evidence |")}
    ]

    for {label, text} <- mutations do
      invalid.(text, "Open", ~r/plan document|Progress and Evidence/)
      assert label != nil
    end

    for state <- ["Accepted limitation", "Accepted deferral"] do
      invalid.(
        String.replace(plan, "| 1 | Open | — |", "| 1 | #{state} | — |"),
        "Open",
        ~r/disposition evidence/
      )

      assert :ok ==
               Plan.governance(
                 String.replace(
                   plan,
                   "| 1 | Open | — |",
                   "| 1 | #{state} | [disposition](decision.md) |"
                 ),
                 technical,
                 gate,
                 "M0",
                 "Open",
                 none
               )

      for bad <- ["evidence.md", "[decision](decision.md)"] do
        invalid.(
          String.replace(plan, "| 1 | Open | — |", "| 1 | #{state} | #{bad} |"),
          "Open",
          ~r/disposition evidence/
        )
      end
    end

    invalid.(
      String.replace(
        Fixture.plan(governed: true, closed: true),
        "| 1 | Proved | — |",
        "| 1 | Open | pending |"
      ),
      "Closed",
      ~r/no Open/
    )
  end

  test "a plan document has no second normative surface" do
    technical = Fixture.technical_plan()
    gate = Fixture.gate()
    plan = Fixture.plan()
    governed = Fixture.plan(governed: true)
    none = fn _sha, _path -> nil end

    mutations = [
      {"identity heading", "# M0\n\n" <> plan},
      {"leading prose", "Plan identity M0.\n\n" <> plan},
      {"interstitial prose",
       String.replace(
         plan,
         "<!-- loopex:plan-concept-envelope:end -->\n\n## Workstreams",
         "<!-- loopex:plan-concept-envelope:end -->\n\nScope override.\n\n## Workstreams"
       )},
      {"second section",
       String.replace(
         plan,
         "## Workstreams",
         "## Scope Override\n\nBroader work.\n\n## Workstreams"
       )}
    ]

    for {label, text} <- mutations do
      assert_raise Invalid, ~r/plan document|headings|Workstreams/, fn ->
        Plan.governance(text, technical, gate, "M0", "Open", none)
      end

      assert label != nil
    end

    bad_candidate = fn _sha, path ->
      cond do
        String.ends_with?(path, "M0-gate.md") ->
          gate

        String.ends_with?(path, "M0-technical.md") ->
          technical

        true ->
          String.replace(
            plan,
            "<!-- loopex:plan-concept-envelope:end -->\n\n## Workstreams",
            "<!-- loopex:plan-concept-envelope:end -->\n\nScope override.\n\n## Workstreams"
          )
      end
    end

    assert_raise Invalid, ~r/Workstreams|concept digest/, fn ->
      Plan.governance(governed, technical, gate, "M0", "Accepted", bad_candidate)
    end

    bad_history =
      String.replace(
        governed,
        "## Workstreams",
        "## Scope Override\n\nBroader work.\n\n## Workstreams"
      )

    history =
      {"accepted", [{"root", [], %{}}, {"accepted", ["root"], Fixture.plan_snapshot(governed)}]}

    assert_raise Invalid, ~r/headings|Workstreams/, fn ->
      Loopex.Checks.History.governance_history(Fixture.plan_snapshot(bad_history), history)
    end
  end

  test "the git resolver requires a reachable commit object" do
    root = LoopexTest.Repo.root()
    {tree, 0} = Git.run(root, ["rev-parse", "HEAD^{tree}"])

    assert nil == Git.resolver(root).(String.trim(tree), "README.md")

    history = Git.history_reader(root).()
    assert history != nil
    {_head, snapshots} = history
    {_revision, _parents, files} = List.last(snapshots)

    for path <- Fixture.adr_paths() do
      assert Map.has_key?(files, path)
    end
  end

  test "the git resolver rejects an unreachable commit without writing" do
    root = LoopexTest.Repo.root()
    unreachable = String.duplicate("f", 40)
    calls = :ets.new(:calls, [:ordered_set, :public])

    runner = fn _root, args ->
      :ets.insert(calls, {:erlang.unique_integer([:monotonic]), args})

      case args do
        ["cat-file", "-t", ^unreachable] -> {"commit\n", 0}
        ["merge-base", "--is-ancestor", ^unreachable, "HEAD"] -> {"", 1}
        other -> raise "unexpected command: #{inspect(other)}"
      end
    end

    assert nil == Git.resolver(root, runner).(unreachable, "README.md")

    assert [
             ["cat-file", "-t", unreachable],
             ["merge-base", "--is-ancestor", unreachable, "HEAD"]
           ] == Enum.map(:ets.tab2list(calls), &elem(&1, 1))

    {head, 0} = Git.run(root, ["rev-parse", "HEAD"])
    assert Git.resolver(root).(String.trim(head), "README.md") != nil
  end

  test "an open plan and a closed one each require their derived capsule" do
    for {state, governed, closed} <- [{"Open", false, false}, {"Closed", true, true}] do
      new_row =
        "| `M0` | #{state} | [concept](M0.md) | " <>
          "[technical depth](M0-technical.md) | [gate](M0-gate.md) |"

      new_summary =
        case state do
          "Open" -> Fixture.open_summary()
          "Closed" -> Fixture.closed_summary()
        end

      documents =
        Fixture.documents()
        |> Map.new(fn {path, text} ->
          {path,
           text
           |> String.replace(Fixture.blocked_row(), new_row)
           |> String.replace(Fixture.summary(), new_summary)}
        end)
        |> Map.put("docs/plans/M0.md", Fixture.plan(governed: governed, closed: closed))
        |> Map.put("docs/plans/M0-technical.md", Fixture.technical_plan())
        |> Map.put("docs/plans/M0-gate.md", Fixture.gate())

      documents =
        case state do
          "Closed" ->
            replace(
              documents,
              "docs/plans/README.md",
              "Seed bootstrap — 2026-08-15",
              "`M0` — 2026-08-15"
            )

          _other ->
            documents
        end

      case state do
        "Open" ->
          opened = Map.update!(documents, "docs/plans/README.md", &Fixture.open_capsule/1)
          assert [] == Fixture.checked(opened)

          opened
          |> replace(
            "docs/plans/README.md",
            "| Next maintainer decision | Accept or reject the `M0` plan pair and gate |",
            "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |"
          )
          |> assert_invalid("exact derived status capsule")

        "Closed" ->
          # Closed had no derived capsule until the transition that first recorded
          # it wrote one, which is what the register's catch-all demands. This case
          # asserted that absence; it now asserts the derivation, because a state
          # whose capsule is unenforced is the thing the catch-all exists to
          # prevent.
          closed = Map.update!(documents, "docs/plans/README.md", &Fixture.closed_capsule/1)
          assert [] == Fixture.checked(closed)

          closed
          |> replace(
            "docs/plans/README.md",
            "| Next maintainer decision | Open the next milestone gate-first, or defer it |",
            "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |"
          )
          |> assert_invalid("exact derived status capsule")
      end
    end
  end

  test "status shape mutations fail" do
    cases = [
      {"summary drift", Fixture.summary(), String.replace(Fixture.summary(), "blocked", "open")},
      {"field removed", "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |\n", ""},
      {"field reordered",
       "| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |\n| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
       "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |\n| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |"},
      {"empty value", "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
       "| Next maintainer decision |  |"},
      {"whitespace value", "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
       "| Next maintainer decision |    |"},
      {"validation drift", "| Validation | `bash scripts/check-bootstrap.sh` |",
       "| Validation | true |"},
      {"wrong link", "[Canonical milestone status and plan records](docs/plans/)",
       "[Canonical milestone status and plan records](docs/roadmap.md)"}
    ]

    for {label, old, new} <- cases do
      target = if String.contains?(label, "link"), do: "README.md", else: "docs/plans/README.md"

      Fixture.documents()
      |> replace(target, old, new)
      |> assert_invalid()
    end

    authority_cases = [
      {"phase", "Pre-implementation planning", "Product implementation authorized"},
      {"blockers",
       "must be accepted before M0 opens; a replacement requires a governed guard change",
       "are optional"},
      {"authorized work", "no product implementation", "product implementation is authorized"},
      {"decision", "Disposition ADR 0001 and ADR 0002", "Begin product implementation"},
      {"transition", "the maintainer explicitly opens `M0` gate-first",
       "implementation begins immediately"}
    ]

    for {label, old, new} <- authority_cases do
      documents =
        Map.new(Fixture.documents(), fn {path, text} -> {path, String.replace(text, old, new)} end)

      assert_invalid(documents, "exact derived status capsule")
      assert label != nil
    end

    for {label, row, summary} <- [
          {"renamed M0", "| `m0` | Blocked | — | — | — |",
           "**Revision status:** Pre-implementation planning; no milestone is active; next candidate `m0` is blocked."},
          {"removed M0", "",
           "**Revision status:** Pre-implementation planning; no milestone is active; no next candidate is recorded."}
        ] do
      documents =
        Map.new(Fixture.documents(), fn {path, text} ->
          replaced =
            case row do
              "" -> String.replace(text, Fixture.blocked_row() <> "\n", "")
              _other -> String.replace(text, Fixture.blocked_row(), row)
            end

          {path,
           replaced
           |> String.replace(Fixture.summary(), summary)
           |> String.replace("no product implementation", "product implementation is authorized")}
        end)

      expected =
        case label do
          "renamed M0" -> "applies only to M0"
          "removed M0" -> "exactly one registered milestone"
        end

      assert_invalid(documents, expected)
    end
  end

  test "hidden or duplicated markers fail" do
    wrappers = [
      {"```text\n", "\n````"},
      {"<!--\n", "\n-->"},
      {"`\n", "\n`"},
      {"<pre>\n", "\n</pre>"},
      {"<?loopex\n", "\n?>"},
      {"<![CDATA[\n", "\n]]>"},
      {"<!STATUS\n", "\n>"}
    ]

    for {prefix, suffix} <- wrappers do
      Fixture.documents()
      |> Map.update!("README.md", &(prefix <> &1 <> suffix))
      |> assert_invalid()
    end

    Fixture.documents()
    |> append("README.md", "\n<!-- loopex:readme-status:start -->")
    |> assert_invalid()

    Fixture.documents()
    |> replace(
      "README.md",
      "<!-- loopex:readme-status:start -->",
      "## Earlier\n\n<!-- loopex:readme-status:start -->"
    )
    |> assert_invalid("outside")

    Fixture.documents()
    |> Map.update!("README.md", &("# Decoy\n\n## Earlier\n\nText\n\n" <> &1))
    |> assert_invalid("first line")

    Fixture.documents()
    |> replace("README.md", "\n## Where Things Stand", "\u2028## Where Things Stand")
    |> assert_invalid("line separator")
  end

  test "register and file mutations fail" do
    mutations = [
      {"bad state", "Blocked", "Ready"},
      {"reserved", "`M0`", "`con`"},
      {"bad name", "`M0`", "`kernel--a`"},
      {"wrong links", Fixture.blocked_row(),
       "| `M0` | Open | [M0](M0.md) | — | [gate](M0-gate.md) |"},
      {"second blocked", Fixture.blocked_row(),
       Fixture.blocked_row() <> "\n| `M1` | Blocked | — | — | — |"},
      {"case collision", Fixture.blocked_row(),
       Fixture.blocked_row() <>
         "\n| `m0` | Closed | [concept](m0.md) | [technical depth](m0-technical.md) | [gate](m0-gate.md) |"},
      {"name too long", "`M0`", "`#{String.duplicate("a", 65)}`"}
    ]

    for {label, old, new} <- mutations do
      Fixture.documents()
      |> replace("docs/plans/README.md", old, new)
      |> assert_invalid()

      assert label != nil
    end

    for path <- ["docs/plans/M0.md", "docs/plans/M0-gate.md", "docs/plans/M0/evidence.md"] do
      Fixture.documents()
      |> Map.put(path, "# orphan\n")
      |> assert_invalid()
    end
  end

  test "governance records must match the register state" do
    technical = Fixture.technical_plan()
    gate = Fixture.gate()
    plan = Fixture.plan()
    governed = Fixture.plan(governed: true)

    invalid = fn text, state, fragment, gate_text ->
      assert_raise Invalid, fragment, fn ->
        Plan.governance(text, technical, gate_text, "M0", state, resolve())
      end
    end

    invalid.(plan, "Accepted", ~r/lifecycle state/, gate)

    invalid.(
      String.replace(
        governed,
        "| Closure | — | — | — |",
        "| Closure | — | — | — |\n| Acceptance | x | x | x |"
      ),
      "Accepted",
      ~r/governance rows/,
      gate
    )

    invalid.(
      String.replace(
        governed,
        "| --- | --- | --- | --- |",
        "| --- | --- | --- | --- |\n```text\ndecoy\n````"
      ),
      "Accepted",
      ~r/malformed table|consecutively numbered/,
      gate
    )

    invalid.(
      governed <> "\n---\n\nignored extra\n",
      "Accepted",
      ~r/malformed table|trailing content/,
      gate
    )

    invalid.(
      String.replace(governed, Loopex.Checks.Markdown.digest(gate), String.duplicate("b", 64)),
      "Accepted",
      ~r/does not match/,
      gate
    )

    changed_gate = "# Changed gate\n"

    assert_raise Invalid, ~r/historical/, fn ->
      Plan.governance(
        Fixture.plan(governed: true, gate: changed_gate),
        technical,
        changed_gate,
        "M0",
        "Accepted",
        resolve()
      )
    end

    invalid.(governed <> "\n## Milestone Status\n", "Accepted", ~r/plan document headings/, gate)

    for separator <- Fixture.gate_separators() do
      noncanonical = "# Gate#{separator}continued\n"

      invalid.(
        Fixture.plan(governed: true, gate: noncanonical),
        "Accepted",
        ~r|UTF-8/LF|,
        noncanonical
      )
    end

    for separator <- Fixture.gate_separators() do
      historical = "# Gate#{separator}continued\n"

      assert_raise Invalid, ~r|UTF-8/LF|, fn ->
        Plan.governance(governed, technical, gate, "M0", "Accepted", Fixture.resolve(historical))
      end
    end

    closed_documents =
      Fixture.documents()
      |> Map.new(fn {path, text} ->
        {path,
         text
         |> String.replace(
           Fixture.blocked_row(),
           "| `M0` | Closed | [concept](M0.md) | " <>
             "[technical depth](M0-technical.md) | [gate](M0-gate.md) |"
         )
         |> String.replace(Fixture.summary(), Fixture.closed_summary())}
      end)
      |> replace("docs/plans/README.md", "Seed bootstrap — 2026-08-15", "`M0` — 2026-99-99")
      |> Map.put("docs/plans/M0.md", Fixture.plan(governed: true, closed: true))
      |> Map.put("docs/plans/M0-technical.md", technical)
      |> Map.put("docs/plans/M0-gate.md", gate)

    assert_invalid(closed_documents, "Last integrated checkpoint")

    invalid.(
      String.replace(
        plan,
        "| Acceptance | — | — | — |",
        "| Acceptance | Maintainer | — | junk |"
      ),
      "Open",
      ~r/exactly empty/,
      gate
    )
  end

  test "barrier mutations fail and a matching change passes" do
    mutations = [
      {"source append", "docs/vision-technical.md",
       "-> multi-client attachment and protocol candidate",
       "-> multi-client attachment and protocol candidate\n-> extra"},
      {"renamed heading", "docs/vision-technical.md", "## 22. Ownership and serial barriers",
       "## 22. Barriers"},
      {"different section", "docs/vision-technical.md", "<!-- loopex:rejoin-source:start -->",
       "# Different section\n\n<!-- loopex:rejoin-source:start -->"},
      {"setext h1", "docs/vision-technical.md", "<!-- loopex:rejoin-source:start -->",
       "Different\n=========\n\n<!-- loopex:rejoin-source:start -->"},
      {"setext h2", "docs/vision-technical.md", "<!-- loopex:rejoin-source:start -->",
       "Different\n---------\n\n<!-- loopex:rejoin-source:start -->"},
      {"hidden", "docs/roadmap-technical.md", "<!-- loopex:rejoin-copy:start -->",
       "<!--\n<!-- loopex:rejoin-copy:start -->"}
    ]

    for {label, path, old, new} <- mutations do
      Fixture.documents()
      |> replace(path, old, new)
      |> assert_invalid()

      assert label != nil
    end

    for {label, replacement, fragment} <- [
          {"empty", "```text\n```", "complete text fence"},
          {"blank first", "```text\n   \n-> next\n```", "needs an initial step"},
          {"blank transition", "```text\nfirst\n->    \n```", "every later rejoin step"}
        ] do
      documents =
        Map.new(Fixture.documents(), fn {path, text} ->
          {path, String.replace(text, Fixture.rejoin(), replacement)}
        end)

      assert_invalid(documents, fragment)
      assert label != nil
    end

    matching =
      Map.new(Fixture.documents(), fn {path, text} ->
        {path,
         String.replace(
           text,
           "-> multi-client attachment and protocol candidate",
           "-> replacement"
         )}
      end)

    assert [] == Fixture.checked(matching)
  end

  # Concept: a register holds a milestone's whole life, so a closed one and a
  # newly opened one coexist from the moment a second milestone opens.
  #
  # Technical depth: derivation must name the milestone a reader would call
  # active. With M0 closed and M1 open, the capsule describes M1; the closed row
  # is history, and describing it would tell a reader no work is authorized while
  # M1 is open. The negative case pins exactly that: M0's closed capsule, every
  # field of it a real derived value, must be refused once M1 is open.
  test "an open milestone beside a closed one derives the open one's capsule" do
    rename = &String.replace(&1, "M0", "M1")

    documents =
      Fixture.documents()
      |> Map.new(fn {path, text} ->
        {path,
         text
         |> String.replace(
           Fixture.blocked_row(),
           "| `M0` | Closed | [concept](M0.md) | [technical depth](M0-technical.md) | " <>
             "[gate](M0-gate.md) |\n" <>
             "| `M1` | Open | [concept](M1.md) | [technical depth](M1-technical.md) | " <>
             "[gate](M1-gate.md) |"
         )
         |> String.replace(Fixture.summary(), rename.(Fixture.open_summary()))}
      end)
      |> Map.put("docs/plans/M0.md", Fixture.plan(governed: true, closed: true))
      |> Map.put("docs/plans/M0-technical.md", Fixture.technical_plan())
      |> Map.put("docs/plans/M0-gate.md", Fixture.gate())
      |> Map.put("docs/plans/M1.md", rename.(Fixture.plan()))
      |> Map.put("docs/plans/M1-technical.md", rename.(Fixture.technical_plan()))
      |> Map.put("docs/plans/M1-gate.md", rename.(Fixture.gate()))
      |> replace("docs/plans/README.md", "Seed bootstrap — 2026-08-15", "`M0` — 2026-08-15")
      |> Map.update!("docs/plans/README.md", &capsule(&1, "Open", "M1"))

    assert [] == Fixture.checked(documents)

    documents
    |> Map.update!("docs/plans/README.md", &capsule(&1, "Closed", "M0"))
    |> assert_invalid("exact derived status capsule")
  end

  # Concept: rewrite the fixture's status capsule to the values a given register
  # state and milestone derive.
  #
  # Technical depth: field names and their order come from the fixture's own
  # table rather than a list restated here, so a case asserts the derived values
  # and cannot accidentally assert the field order twice. The checkpoint field
  # keeps whatever the document already carries, because it is derived from the
  # register's closed rows and not from the described milestone.
  defp capsule(text, state, name) do
    expected = Register.expected_capsule(state, name, %{})

    Regex.replace(~r/^\| ([^|\n]+?) \| [^|\n]*? \|$/m, text, fn line, field ->
      case Map.fetch(expected, field) do
        {:ok, value} when field != "Last integrated checkpoint" -> "| #{field} | #{value} |"
        _other -> line
      end
    end)
  end

  defp replace(documents, path, old, new) do
    Map.update!(documents, path, &String.replace(&1, old, new))
  end

  defp replace_once(documents, path, old, new) do
    Map.update!(documents, path, &String.replace(&1, old, new, global: false))
  end

  defp append(documents, path, suffix) do
    Map.update!(documents, path, &(&1 <> suffix))
  end
end
