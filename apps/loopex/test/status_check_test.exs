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
  derived-capsule enforcement without touching the checkout. Cases that need a
  real repository read one, and write nothing.
  """

  use ExUnit.Case, async: true

  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Register
  alias Mix.Tasks.Loopex.Matrix
  alias Loopex.StatusFixtures, as: Fixture

  defp assert_invalid(documents, fragment \\ nil) do
    errors = Fixture.checked(documents)
    assert errors != [], "mutation unexpectedly passed"

    if fragment do
      assert hd(errors) =~ fragment, "expected #{inspect(fragment)} in #{inspect(hd(errors))}"
    end

    errors
  end

  test "the fixture repository passes every check" do
    assert [] == Fixture.checked(Fixture.documents())
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

    for args <- [
          ["--evidence", "docs/evidence/M1-toolchain-matrix.md", "--profile", "m1"],
          ["--unknown"]
        ] do
      assert_raise Mix.Error, "usage: mix loopex.matrix", fn -> Matrix.run(args) end
    end

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

  test "the in-review capsule does not widen authority either" do
    # Acceptance is the only transition that widens authorized work. If In review
    # derived a broader boundary, a reviewer's presence would authorise work.
    accepted = Register.expected_capsule("Accepted", "M0", %{})
    in_progress = Register.expected_capsule("In progress", "M0", %{})
    in_review = Register.expected_capsule("In review", "M0", %{})

    for later <- [in_progress, in_review] do
      assert Map.fetch!(later, "Authorized work") == Map.fetch!(accepted, "Authorized work")
    end

    # The capsule no longer carries a phase at all. It used to, as a constant no
    # lifecycle state overrode, and this pair of assertions read as proof that the
    # phase was stable across states when it was only proof that a literal equals
    # itself. `Register.integrated_phase/1` owns the field and is exercised where
    # it can actually vary: against the register.
    for capsule <- [accepted, in_progress, in_review] do
      refute Map.has_key?(capsule, "Integrated phase")
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

  # Concept: the phase states which side of the first closure the repository is
  # on, and nothing else.
  #
  # Technical depth: nothing protected this field before. `@seed_blocked` assigned
  # it once, every capsule builder inherited the constant, and the capsule
  # comparison then required the document to keep the seed value for every
  # representable lifecycle state — so both primary records still read
  # "Pre-implementation planning" after M0 and M1 closed with product integrated,
  # and agreed with each other while doing it. These cases pin the value to the
  # register instead of to a constant, in both directions.
  test "the integrated phase is derived from the register's closed rows" do
    planning = "Pre-implementation planning"
    closed = "Closed milestone product baseline"

    assert Register.integrated_phase([]) == planning

    for state <- Register.states() -- ["Closed"] do
      assert Register.integrated_phase([{"M0", state}]) == planning
    end

    assert Register.integrated_phase([{"M0", "Closed"}]) == closed

    for state <- Register.states() do
      assert Register.integrated_phase([{"M0", "Closed"}, {"M1", state}]) == closed
    end

    assert Register.integrated_phase([{"M0", "Closed"}, {"M1", "Closed"}, {"M2", "Open"}]) ==
             closed

    # Two values, not a ladder: every representable register derives one of them.
    values =
      for rows <- [
            [],
            [{"a", "Blocked"}],
            [{"a", "Open"}],
            [{"a", "Accepted"}, {"b", "Open"}],
            [{"a", "Closed"}],
            [{"a", "Closed"}, {"b", "In review"}]
          ],
          do: Register.integrated_phase(rows)

    assert MapSet.new(values) == MapSet.new([planning, closed])

    # The phase names the kind of state. Identity and date belong to
    # `Last closed product checkpoint`, and authority to `Authorized work`.
    refute closed =~ ~r/`|[0-9]{4}-[0-9]{2}-[0-9]{2}/
    refute closed =~ ~r/authori[sz]/i

    # Fail closed. Closed rows are history and precede every later state, so a
    # Closed row behind a live one is a register shape the lifecycle does not
    # represent — not a phase to be guessed.
    for state <- Register.states() -- ["Closed"] do
      assert_raise Invalid, ~r/Closed milestones must precede/, fn ->
        Register.integrated_phase([{"M0", state}, {"M1", "Closed"}])
      end
    end
  end

  test "a status document cannot carry a phase its register does not derive" do
    # No Closed row, so the closed phase is not merely different prose: it is a
    # claim the register refutes.
    Fixture.documents()
    |> replace(
      "docs/plans/README.md",
      "| Integrated phase | Pre-implementation planning |",
      "| Integrated phase | Closed milestone product baseline |"
    )
    |> assert_invalid("Integrated phase")

    # The old capsule refused this one too, but only by luck of direction: its
    # constant happened to be the right value while nothing had closed, and was
    # the wrong one ever after. The hole it left was one-sided, and the closed
    # register below is where it opened. This pins the property in every state,
    # which one constant could not do in any.
    Fixture.documents()
    |> Map.new(fn {path, text} ->
      {path,
       String.replace(text, "Pre-implementation planning", "Closed milestone product baseline")}
    end)
    |> assert_invalid("Integrated phase")
  end

  test "the JSON reader decodes unicode escapes so hooks still match" do
    # A hook matching on a command never saw a \\u0024HOME spelling as $HOME, so an
    # ordinary JSON encoding of a protected path walked past the filesystem guard.
    # That is a representation a client may legitimately send, not obfuscation.
    root = repository_root()
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

  test "the in-progress capsule does not widen authority" do
    accepted = Register.expected_capsule("Accepted", "M0", %{})
    in_progress = Register.expected_capsule("In progress", "M0", %{})

    assert accepted["Authorized work"] == in_progress["Authorized work"]
    assert accepted["Next maintainer decision"] == in_progress["Next maintainer decision"]

    changed =
      accepted
      |> Enum.filter(fn {key, value} -> in_progress[key] != value end)
      |> Enum.map(&elem(&1, 0))

    assert MapSet.new(["Blockers", "Next transition"]) == MapSet.new(changed)
    assert in_progress["Next transition"] =~ "In review"
  end

  test "accepted M1 truthfully derives its implementation-time ADR blocker" do
    path = "docs/adr/0008-owner-succession-recovery-and-runtime-placement.md"

    m2_prerequisites = %{
      "docs/adr/0009-tool-executor-and-grant-contracts.md" => "Accepted",
      "docs/adr/0010-provider-continuation-and-context-staging.md" => "Accepted",
      "docs/adr/0011-session-input-algebra-and-streaming.md" => "Accepted"
    }

    proposed = Register.expected_capsule("Accepted", "M1", %{path => "Proposed"})
    accepted = Register.expected_capsule("Accepted", "M1", %{path => "Accepted"})

    assert proposed["Blockers"] =~ "ADR 0008"
    assert proposed["Blockers"] =~ "Workstream A"
    assert proposed["Next maintainer decision"] == "Accept or reject ADR 0008"
    assert proposed["Authorized work"] == accepted["Authorized work"]
    assert accepted["Blockers"] == "None; `M1` is accepted and implementation may proceed"

    lookahead_proposed =
      Register.expected_capsule(
        {"M1", "Accepted"},
        {"M2", "Open"},
        Map.put(m2_prerequisites, path, "Proposed")
      )

    lookahead_accepted =
      Register.expected_capsule(
        {"M1", "Accepted"},
        {"M2", "Open"},
        Map.put(m2_prerequisites, path, "Accepted")
      )

    assert lookahead_proposed["Blockers"] =~ "ADR 0008"
    assert lookahead_proposed["Blockers"] =~ "`M2` acceptance"
    assert lookahead_proposed["Next maintainer decision"] =~ "Accept or reject ADR 0008"
    assert lookahead_accepted["Blockers"] =~ "None for `M1` delivery"

    for state <- ["In progress", "In review"] do
      assert_raise Invalid, ~r/ADR 0008/, fn ->
        Register.expected_capsule(state, "M1", %{path => "Proposed"})
      end

      assert is_map(Register.expected_capsule(state, "M1", %{path => "Accepted"}))
    end
  end

  test "a milestone cannot outrun the ADR dispositions its plan pair declares" do
    adrs = [
      {"docs/adr/0009-tool-executor-and-grant-contracts.md", "ADR 0009"},
      {"docs/adr/0010-provider-continuation-and-context-staging.md", "ADR 0010"},
      {"docs/adr/0011-session-input-algebra-and-streaming.md", "ADR 0011"}
    ]

    all_accepted = Map.new(adrs, fn {path, _name} -> {path, "Accepted"} end)
    m1_adr = "docs/adr/0008-owner-succession-recovery-and-runtime-placement.md"

    # The defect this protects against: the generic Open and Accepted
    # derivations discarded ADR statuses, so `M2` derived "implementation may
    # proceed" while all three prerequisites were still Proposed.
    for {path, name} <- adrs do
      statuses = Map.put(all_accepted, path, "Proposed")
      open = Register.expected_capsule("Open", "M2", statuses)

      assert open["Blockers"] =~ name
      assert open["Next maintainer decision"] == "Disposition #{name}"
      assert open["Next transition"] =~ "the prerequisite is accepted"

      for other <- Enum.reject(adrs, &(elem(&1, 1) == name)) do
        refute open["Blockers"] =~ elem(other, 1)
      end

      for state <- ["Accepted", "In progress", "In review", "Closed"] do
        assert_raise Invalid, ~r/`M2` cannot move to #{state} before #{name} is accepted/, fn ->
          Register.expected_capsule(state, "M2", statuses)
        end
      end

      # The composite capsule is the only shape carrying an Open milestone that
      # does not run the Open derivation, so it must still name what that
      # milestone waits on.
      composite =
        Register.expected_capsule(
          {"M1", "Accepted"},
          {"M2", "Open"},
          Map.put(statuses, m1_adr, "Accepted")
        )

      assert composite["Blockers"] =~ name
      assert composite["Next maintainer decision"] =~ name
    end

    two_outstanding =
      all_accepted
      |> Map.put("docs/adr/0009-tool-executor-and-grant-contracts.md", "Proposed")
      |> Map.put("docs/adr/0011-session-input-algebra-and-streaming.md", "Proposed")

    open_two = Register.expected_capsule("Open", "M2", two_outstanding)
    assert open_two["Next maintainer decision"] == "Disposition ADR 0009 and ADR 0011"
    assert open_two["Next transition"] =~ "the prerequisites are accepted"
    refute open_two["Blockers"] =~ "ADR 0010"

    none_accepted = Map.new(adrs, fn {path, _name} -> {path, "Proposed"} end)
    open_none = Register.expected_capsule("Open", "M2", none_accepted)

    assert open_none["Next maintainer decision"] ==
             "Disposition ADR 0009, ADR 0010, and ADR 0011"

    for {_path, name} <- adrs do
      assert open_none["Blockers"] =~ name
    end

    assert_raise Invalid, ~r/ADR 0009, ADR 0010, and ADR 0011 are accepted/, fn ->
      Register.expected_capsule("Accepted", "M2", none_accepted)
    end

    # All three accepted returns the ordinary derivation for each state, and the
    # Open capsule goes back to naming acceptance itself as the open decision.
    open_clear = Register.expected_capsule("Open", "M2", all_accepted)

    assert open_clear ==
             Register.expected_capsule("Open", "unconstrained", all_accepted)
             |> Map.put(
               "Blockers",
               "`M2` is open and not accepted; the recorded acceptance authority must " <>
                 "accept both normative envelopes and the gate"
             )
             |> Map.put(
               "Next maintainer decision",
               "Accept or reject the `M2` plan pair and gate"
             )
             |> Map.put(
               "Next transition",
               "Record the acceptance governance row and move `M2` to Accepted"
             )

    for state <- ["Accepted", "In progress", "In review", "Closed"] do
      assert is_map(Register.expected_capsule(state, "M2", all_accepted))
    end

    composite_clear =
      Register.expected_capsule(
        {"M1", "Accepted"},
        {"M2", "Open"},
        Map.put(all_accepted, m1_adr, "Accepted")
      )

    refute composite_clear["Blockers"] =~ "ADR 00"
    refute composite_clear["Next maintainer decision"] =~ "ADR 00"

    # A declared prerequisite that is not a registered ADR is a governed failure,
    # never a silently resolved one.
    assert_raise Invalid, ~r/names ADR 0009 as a prerequisite/, fn ->
      Register.expected_capsule("Open", "M2", Map.delete(all_accepted, elem(hd(adrs), 0)))
    end
  end

  test "M3 names its skill and permit decisions and cannot outrun either" do
    adrs = [
      {"docs/adr/0025-resource-packs-and-skill-admission.md", "ADR 0025"},
      {"docs/adr/0027-provider-permit-retirement.md", "ADR 0027"}
    ]

    accepted = Map.new(adrs, fn {path, _name} -> {path, "Accepted"} end)
    proposed = Map.new(adrs, fn {path, _name} -> {path, "Proposed"} end)
    open = Register.expected_capsule("Open", "M3", proposed)
    assert open["Next maintainer decision"] == "Disposition ADR 0025 and ADR 0027"
    assert open["Next transition"] =~ "After the prerequisites are accepted"

    for {path, name} <- adrs do
      outstanding = Map.put(accepted, path, "Proposed")
      open = Register.expected_capsule("Open", "M3", outstanding)
      assert open["Blockers"] =~ name
      assert open["Next maintainer decision"] == "Disposition #{name}"

      for state <- ["Accepted", "In progress", "In review", "Closed"] do
        assert_raise Invalid, ~r/`M3` cannot move to #{state} before #{name} is accepted/, fn ->
          Register.expected_capsule(state, "M3", outstanding)
        end

        assert is_map(Register.expected_capsule(state, "M3", accepted))
      end

      assert_raise Invalid, ~r/M3` names #{name} as a prerequisite but/, fn ->
        Register.expected_capsule("Open", "M3", Map.delete(accepted, path))
      end
    end

    clear = Register.expected_capsule("Open", "M3", accepted)
    refute clear["Blockers"] =~ "ADR"
    refute clear["Next maintainer decision"] =~ "ADR"
  end

  test "M4 names its protocol interaction floor and range decisions and cannot outrun any" do
    adrs = [
      {"docs/adr/0023-experimental-public-session-protocol.md", "ADR 0023"},
      {"docs/adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md", "ADR 0024"},
      {"docs/adr/0026-development-floor-refresh.md", "ADR 0026"},
      {"docs/adr/0028-bounded-artifact-retrieval.md", "ADR 0028"},
      {"docs/adr/0030-observability-tracing-and-telemetry.md", "ADR 0030"}
    ]

    accepted = Map.new(adrs, fn {path, _name} -> {path, "Accepted"} end)
    proposed = Map.new(adrs, fn {path, _name} -> {path, "Proposed"} end)
    open = Register.expected_capsule("Open", "M4", proposed)

    assert open["Next maintainer decision"] ==
             "Disposition ADR 0023, ADR 0024, ADR 0026, ADR 0028, and ADR 0030"

    assert open["Next transition"] =~ "After the prerequisites are accepted"

    lookahead = Register.expected_capsule({"M3", "Accepted"}, {"M4", "Open"}, m3_and_m4(proposed))

    assert lookahead["Blockers"] =~
             "`M4` additionally waits on ADR 0023, ADR 0024, ADR 0026, ADR 0028, and ADR 0030"

    assert lookahead["Next maintainer decision"] =~
             "cannot be accepted before `M3` closes; `M4` also waits on"

    for {path, name} <- adrs do
      outstanding = Map.put(accepted, path, "Proposed")
      open = Register.expected_capsule("Open", "M4", outstanding)
      assert open["Blockers"] =~ name
      assert open["Next maintainer decision"] == "Disposition #{name}"

      for state <- ["Accepted", "In progress", "In review", "Closed"] do
        assert_raise Invalid, ~r/`M4` cannot move to #{state} before #{name} is accepted/, fn ->
          Register.expected_capsule(state, "M4", outstanding)
        end

        assert is_map(Register.expected_capsule(state, "M4", accepted))
      end

      assert_raise Invalid, ~r/M4` names #{name} as a prerequisite but/, fn ->
        Register.expected_capsule("Open", "M4", Map.delete(accepted, path))
      end
    end

    clear = Register.expected_capsule({"M3", "Accepted"}, {"M4", "Open"}, m3_and_m4(accepted))
    refute clear["Blockers"] =~ "ADR"
    refute clear["Next maintainer decision"] =~ "ADR"
  end

  defp m3_and_m4(m4_statuses) do
    Map.merge(
      %{
        "docs/adr/0025-resource-packs-and-skill-admission.md" => "Accepted",
        "docs/adr/0027-provider-permit-retirement.md" => "Accepted"
      },
      m4_statuses
    )
  end

  test "a milestone state with no derived capsule fails closed" do
    assert "In review" in Register.delivery_states()

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

  test "an ADR's status and its governance row must say the same thing" do
    for accepted <- [[], [1], [2], [1, 2]] do
      assert [] == Fixture.checked(Fixture.accepted_adr_documents(accepted))
    end

    [first, _second] = Fixture.adr_paths()

    # A status moved without its row, and a row completed without its status,
    # are the two halves of the same defect: a decision that reads as accepted in
    # one place and unaccepted in the other.
    Fixture.accepted_adr_documents([1])
    |> replace(first, "- **Status:** Accepted", "- **Status:** Proposed")
    |> assert_invalid("Status and governance record do not match")

    Fixture.accepted_adr_documents([])
    |> replace(first, "- **Status:** Proposed", "- **Status:** Accepted")
    |> assert_invalid("Status and governance record do not match")

    # A half-filled row names an authority and no bytes, which reads as a
    # recorded decision while recording nothing.
    Fixture.accepted_adr_documents([1])
    |> replace(
      first,
      "candidate `#{String.duplicate("d", 40)}`; concept `sha256:#{String.duplicate("1d", 32)}`; technical `sha256:#{String.duplicate("2d", 32)}`",
      "—"
    )
    |> assert_invalid("exactly empty or structurally complete")

    # Neither is a status the contract recognises.
    for status <- ["Superseded", "accepted"] do
      Fixture.accepted_adr_documents([1])
      |> replace(first, "- **Status:** Accepted", "- **Status:** #{status}")
      |> assert_invalid("status must be Proposed or Accepted")
    end
  end

  test "an open plan and a closed one each require their derived capsule" do
    for state <- ["Open", "Closed"] do
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
        |> Map.put("docs/plans/M0.md", Fixture.plan())
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

          # A closed register cannot keep describing the repository as
          # pre-implementation. Both primary records carried that sentence for two
          # closed milestones because the capsule pinned a constant; restoring the
          # constant here must now fail in both documents.
          for path <- ["docs/plans/README.md", "README.md"] do
            closed
            |> replace(
              path,
              "Closed milestone product baseline",
              "Pre-implementation planning"
            )
            |> assert_invalid()
          end

          closed
          |> replace(
            "docs/plans/README.md",
            "| Integrated phase | Closed milestone product baseline |",
            "| Integrated phase | Pre-implementation planning |"
          )
          |> assert_invalid("Integrated phase")
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

    # The phase moved out of the derived capsule and into its own owner, so this
    # case is retargeted rather than dropped: it still proves a document cannot
    # award itself implementation authority through the phase cell, and it now
    # names the check that refuses it. The other four fields remain capsule
    # fields and keep the capsule's message.
    authority_cases = [
      {"phase", "Pre-implementation planning", "Product implementation authorized",
       "Integrated phase"},
      {"blockers",
       "must be accepted before M0 opens; a replacement requires a governed guard change",
       "are optional", "exact derived status capsule"},
      {"authorized work", "no product implementation", "product implementation is authorized",
       "exact derived status capsule"},
      {"decision", "Disposition ADR 0001 and ADR 0002", "Begin product implementation",
       "exact derived status capsule"},
      {"transition", "the maintainer explicitly opens `M0` gate-first",
       "implementation begins immediately", "exact derived status capsule"}
    ]

    for {label, old, new, fragment} <- authority_cases do
      documents =
        Map.new(Fixture.documents(), fn {path, text} -> {path, String.replace(text, old, new)} end)

      assert_invalid(documents, fragment)
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
          "removed M0" -> "milestone register is empty"
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
  # active. With M0 closed and M9 open in this generic fixture, the capsule
  # describes M9; the closed row is history, and describing it would tell a
  # reader no work is authorized while M9 is open. The negative case pins exactly
  # that: M0's closed capsule, every field of it a real derived value, must be
  # refused once M9 is open.
  test "an open milestone beside a closed one derives the open one's capsule" do
    rename = &String.replace(&1, "M0", "M9")

    # The sentence is composed from the register rather than from the open
    # fixture's, because the closed row moves the phase and only the milestone
    # clauses come from the open one.
    rows = [{"M0", "Closed"}, {"M9", "Open"}]
    summary = Register.summary(Register.integrated_phase(rows), rows)

    assert summary ==
             "**Revision status:** Closed milestone product baseline; active milestone `M9` " <>
               "is open; no next candidate is recorded."

    documents =
      Fixture.documents()
      |> Map.new(fn {path, text} ->
        {path,
         text
         |> String.replace(
           Fixture.blocked_row(),
           "| `M0` | Closed | [concept](M0.md) | [technical depth](M0-technical.md) | " <>
             "[gate](M0-gate.md) |\n" <>
             "| `M9` | Open | [concept](M9.md) | [technical depth](M9-technical.md) | " <>
             "[gate](M9-gate.md) |"
         )
         |> String.replace(Fixture.summary(), summary)}
      end)
      |> Map.put("docs/plans/M0.md", Fixture.plan())
      |> Map.put("docs/plans/M0-technical.md", Fixture.technical_plan())
      |> Map.put("docs/plans/M0-gate.md", Fixture.gate())
      |> Map.put("docs/plans/M9.md", rename.(Fixture.plan()))
      |> Map.put("docs/plans/M9-technical.md", rename.(Fixture.technical_plan()))
      |> Map.put("docs/plans/M9-gate.md", rename.(Fixture.gate()))
      |> replace("docs/plans/README.md", "Seed bootstrap — 2026-08-15", "`M0` — 2026-08-15")
      |> Map.update!("docs/plans/README.md", &Fixture.closed_phase_cell/1)
      |> Map.update!("docs/plans/README.md", &capsule(&1, "Open", "M9"))

    assert [] == Fixture.checked(documents)

    documents
    |> Map.update!("docs/plans/README.md", &capsule(&1, "Closed", "M0"))
    |> assert_invalid("exact derived status capsule")
  end

  test "one delivery milestone may carry exactly one generic Open successor" do
    successor = &String.replace(&1, "M0", "M9")

    rows = [{"M0", "Accepted"}, {"M9", "Open"}]

    # The phase is derived rather than named here, so this literal also pins the
    # other half of the derivation: a register with no Closed row stays
    # pre-implementation however far its delivery milestone has advanced.
    summary = Register.summary(Register.integrated_phase(rows), rows)

    assert summary ==
             "**Revision status:** Pre-implementation planning; active milestone `M0` is " <>
               "accepted; next candidate `M9` is open."

    documents =
      Fixture.documents()
      |> Map.new(fn {path, text} ->
        {path,
         text
         |> String.replace(
           Fixture.blocked_row(),
           "| `M0` | Accepted | [concept](M0.md) | " <>
             "[technical depth](M0-technical.md) | [gate](M0-gate.md) |\n" <>
             "| `M9` | Open | [concept](M9.md) | " <>
             "[technical depth](M9-technical.md) | [gate](M9-gate.md) |"
         )
         |> String.replace(Fixture.summary(), summary)}
      end)
      |> Map.put("docs/plans/M0.md", Fixture.plan())
      |> Map.put("docs/plans/M0-technical.md", Fixture.technical_plan())
      |> Map.put("docs/plans/M0-gate.md", Fixture.gate())
      |> Map.put("docs/plans/M9.md", successor.(Fixture.plan()))
      |> Map.put("docs/plans/M9-technical.md", successor.(Fixture.technical_plan()))
      |> Map.put("docs/plans/M9-gate.md", Fixture.gate())
      |> Map.update!(
        "docs/plans/README.md",
        &capsule(&1, {"M0", "Accepted"}, {"M9", "Open"})
      )

    assert [] == Fixture.checked(documents)

    authorized =
      documents
      |> Map.fetch!("docs/plans/README.md")
      |> Register.current_status()
      |> elem(0)
      |> Map.fetch!("Authorized work")

    assert authorized =~ "accepted `M0`"
    assert authorized =~ "planning, gate construction, and review for Open `M9`"
    assert authorized =~ "no `M9` product implementation"
  end

  test "the generic delivery and lookahead roles reject every adjacent extra shape" do
    states = Register.states()

    assert states == ["Blocked", "Open", "Accepted", "In progress", "In review", "Closed"]

    valid_tails =
      MapSet.new([
        [],
        ["Blocked"],
        ["Open"],
        ["Accepted"],
        ["In progress"],
        ["In review"],
        ["Accepted", "Open"]
      ])

    assert %{delivery: nil, open: nil, blocked: nil} == Register.milestone_roles([])

    sequences =
      1..3
      |> Enum.flat_map(fn length ->
        Enum.reduce(1..length, [[]], fn _position, prefixes ->
          for prefix <- prefixes, state <- states, do: prefix ++ [state]
        end)
      end)

    for sequence <- sequences do
      rows =
        sequence
        |> Enum.with_index(1)
        |> Enum.map(fn {state, index} -> {"milestone-#{index}", state} end)

      {_closed_prefix, tail_rows} =
        Enum.split_while(rows, fn {_name, state} -> state == "Closed" end)

      tail_states = Enum.map(tail_rows, &elem(&1, 1))

      if MapSet.member?(valid_tails, tail_states) do
        expected =
          case tail_rows do
            [] ->
              %{delivery: nil, open: nil, blocked: nil}

            [{_name, "Blocked"} = blocked] ->
              %{delivery: nil, open: nil, blocked: blocked}

            [{_name, "Open"} = open] ->
              %{delivery: nil, open: open, blocked: nil}

            [{_name, state} = delivery]
            when state in ["Accepted", "In progress", "In review"] ->
              %{delivery: delivery, open: nil, blocked: nil}

            [{_delivery_name, "Accepted"} = delivery, {_open_name, "Open"} = open] ->
              %{delivery: delivery, open: open, blocked: nil}
          end

        assert expected == Register.milestone_roles(rows),
               "valid lifecycle sequence failed: #{inspect(sequence)}"
      else
        assert_raise Invalid, ~r/Closed history.*one delivery.*one Open successor/, fn ->
          Register.milestone_roles(rows)
        end
      end
    end

    for state <- ["In progress", "In review"] do
      assert_raise Invalid, ~r/Open successor requires an Accepted predecessor/, fn ->
        Register.expected_capsule({"current", state}, {"next", "Open"}, %{})
      end
    end
  end

  test "the Accepted plus Open capsule pins both delivery and lookahead authority" do
    capsule = Register.expected_capsule({"current", "Accepted"}, {"next", "Open"}, %{})

    assert Map.take(capsule, [
             "Blockers",
             "Authorized work",
             "Next maintainer decision",
             "Next transition"
           ]) == %{
             "Blockers" =>
               "None for `current` delivery; `next` acceptance, integration, and product " <>
                 "implementation wait until `current` closes and the Open candidate is " <>
                 "refreshed and independently reviewed on that closed base",
             "Authorized work" =>
               "Implementation inside the accepted `current` envelopes and locked gate on " <>
                 "its designated milestone branch; planning, gate construction, and review " <>
                 "for Open `next`; no milestone product bytes integrate before closure and " <>
                 "no `next` product implementation",
             "Next maintainer decision" =>
               "None until `current` is ready for independent review; `next` cannot be " <>
                 "accepted before `current` closes",
             "Next transition" =>
               "Turn the locked `current` gate green, move `current` to In progress and " <>
                 "then In review with cleared independent review, and close it; then " <>
                 "refresh and independently review `next` on that closed base"
           }
  end

  # Concept: rewrite the fixture's status capsule to the values a given register
  # state and milestone derive.
  #
  # Technical depth: field names and their order come from the fixture's own
  # table rather than a list restated here, so a case asserts the derived values
  # and cannot accidentally assert the field order twice. The checkpoint field
  # keeps whatever the document already carries, because it is derived from the
  # register's closed rows and not from the described milestone.
  defp capsule(text, {delivery_name, delivery_state}, {open_name, "Open"}) do
    expected =
      Register.expected_capsule(
        {delivery_name, delivery_state},
        {open_name, "Open"},
        %{}
      )

    rewrite_capsule(text, expected)
  end

  defp capsule(text, state, name) do
    rewrite_capsule(text, Register.expected_capsule(state, name, %{}))
  end

  defp rewrite_capsule(text, expected) do
    Regex.replace(~r/^\| ([^|\n]+?) \| [^|\n]*? \|$/m, text, fn line, field ->
      case Map.fetch(expected, field) do
        {:ok, value} when field != "Last closed product checkpoint" -> "| #{field} | #{value} |"
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

  # Concept: find the checkout from this file, not from the working directory.
  #
  # Technical depth: the gate compiles a protected selector on its own, without
  # the application's test helper, so the helper that resolved the repository
  # root is not defined there. Four cases here reached for it and failed under
  # the gate while passing under `mix test` -- which is the difference between a
  # case that passes and a case that is proved. Walking up from this file's own
  # location answers the same in both.
  defp repository_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))
end
