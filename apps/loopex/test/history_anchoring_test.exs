Code.require_file("support/status_fixtures_helper.exs", __DIR__)

defmodule Loopex.HistoryAnchoringTest do
  @moduledoc """
  ## Concept

  Proves the replacement still anchors bound artifacts and completed governance
  records across reachable history, which is the guarantee retiring the previous
  checker would otherwise have dropped silently.

  The cases that matter are the ones a current-tree check cannot see. A commit
  mutates a bound runner and a later commit restores it; a branch mutates it and a
  merge lands a clean tree; a gate declares an artifact that is not in the tree at
  all. Every final tree in those histories is valid, so only history catches them.

  ## Technical depth

  Histories are supplied as data — revision, parents, and the file contents that
  revision carried — so merges, deletions, and restorations can be constructed
  exactly. Digests are computed from the fixture bytes, so a case fails because the
  history is wrong rather than because a pasted hash drifted.
  """

  use ExUnit.Case, async: true

  alias Loopex.Checks.History
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Status
  alias Loopex.StatusFixtures, as: Fixture

  @good "#!/usr/bin/env bash\nexit 1\n"
  @bad "#!/usr/bin/env bash\nexit 0\n"
  @other "x = 1\n"
  @runner "scripts/run-gate.sh"
  @config "cfg.exs"
  @gate_path "docs/plans/M0-gate.md"

  defp one_artifact_gate do
    "# Gate\n\n## Bound Artifacts\n\n| SHA-256 | Path |\n| --- | --- |\n" <>
      "| `#{Markdown.digest(@good)}` | `#{@runner}` |\n"
  end

  defp two_artifact_gate do
    "# Gate\n\n## Bound Artifacts\n\n| SHA-256 | Path |\n| --- | --- |\n" <>
      "| `#{Markdown.digest(@good)}` | `#{@runner}` |\n" <>
      "| `#{Markdown.digest(@other)}` | `#{@config}` |\n"
  end

  defp config_only_gate do
    "# Gate\n\n## Bound Artifacts\n\n| SHA-256 | Path |\n| --- | --- |\n" <>
      "| `#{Markdown.digest(@other)}` | `#{@config}` |\n"
  end

  defp sha(letter), do: String.duplicate(letter, 40)

  defp run(documents, snapshots, read_artifact) do
    {head, _parents, _files} = List.last(snapshots)

    Status.validate(documents,
      plan_history: fn -> {head, snapshots} end,
      read_artifact: read_artifact
    )
  end

  defp clean_reader, do: fn _target -> @good end

  defp two_artifact_reader do
    fn target -> if target == @config, do: @other, else: @good end
  end

  describe "bound artifacts across reachable history" do
    setup do
      gate = one_artifact_gate()
      {:ok, gate: gate, documents: Fixture.open_milestone_documents(gate)}
    end

    test "a clean history passes", %{gate: gate, documents: documents} do
      snapshots = [
        {sha("a"), [], %{@gate_path => gate, @runner => @good}},
        {sha("b"), [sha("a")], %{@gate_path => gate, @runner => @good}}
      ]

      assert [] == run(documents, snapshots, clean_reader())
    end

    test "a mutated then restored artifact is rejected", %{gate: gate, documents: documents} do
      # The current tree is clean and every check over it passes, so only the
      # intervening revision carries the mutation.
      snapshots = [
        {sha("a"), [], %{@gate_path => gate, @runner => @good}},
        {sha("b"), [sha("a")], %{@gate_path => gate, @runner => @bad}},
        {sha("c"), [sha("b")], %{@gate_path => gate, @runner => @good}}
      ]

      errors = run(documents, snapshots, clean_reader())
      assert errors != []
      assert hd(errors) =~ "does not match its locked digest"
    end

    test "a merge parent carrying a mutated artifact is rejected", %{
      gate: gate,
      documents: documents
    } do
      # The merge commit's own tree is clean; one of its parents is not.
      snapshots = [
        {sha("a"), [], %{@gate_path => gate, @runner => @good}},
        {sha("b"), [sha("a")], %{@gate_path => gate, @runner => @bad}},
        {sha("c"), [sha("a")], %{@gate_path => gate, @runner => @good}},
        {sha("d"), [sha("c"), sha("b")], %{@gate_path => gate, @runner => @good}}
      ]

      errors = run(documents, snapshots, clean_reader())
      assert errors != []
      assert hd(errors) =~ "does not match its locked digest"
    end

    test "an artifact missing from history is rejected", %{gate: gate, documents: documents} do
      snapshots = [{sha("a"), [], %{@gate_path => gate}}]

      errors = run(documents, snapshots, clean_reader())
      assert errors != []
      assert hd(errors) =~ "is missing"
    end
  end

  test "artifact binding persists along every parent" do
    two = two_artifact_gate()
    one = config_only_gate()
    documents = Fixture.open_milestone_documents(two)
    base = %{@gate_path => two, @runner => @good, @config => @other}

    # The gate file itself is deleted, then restored.
    errors =
      run(
        documents,
        [
          {sha("a"), [], base},
          {sha("b"), [sha("a")], %{@runner => @bad, @config => @other}},
          {sha("c"), [sha("b")], base}
        ],
        two_artifact_reader()
      )

    assert errors != []
    assert hd(errors) =~ "gate disappeared"

    # One row is removed from an otherwise valid table, then restored.
    errors =
      run(
        documents,
        [
          {sha("a"), [], base},
          {sha("b"), [sha("a")], %{@gate_path => one, @runner => @bad, @config => @other}},
          {sha("c"), [sha("b")], base}
        ],
        two_artifact_reader()
      )

    assert errors != []
    assert hd(errors) =~ "no longer declared"

    # A merge whose other parent dropped the gate is still caught.
    errors =
      run(
        documents,
        [
          {sha("a"), [], base},
          {sha("b"), [sha("a")], %{@runner => @bad, @config => @other}},
          {sha("c"), [sha("a")], base},
          {sha("d"), [sha("c"), sha("b")], base}
        ],
        two_artifact_reader()
      )

    assert errors != []
    assert hd(errors) =~ "gate disappeared"
  end

  test "a malformed or removed artifact declaration fails" do
    gate = one_artifact_gate()
    malformed = "# Gate\n\n## Bound Artifacts\n\nnot a table at all\n"
    absent = "# Gate\n"
    documents = Fixture.open_milestone_documents(gate)

    errors =
      run(
        documents,
        [
          {sha("a"), [], %{@gate_path => gate, @runner => @good}},
          {sha("b"), [sha("a")], %{@gate_path => malformed, @runner => @bad}},
          {sha("c"), [sha("b")], %{@gate_path => gate, @runner => @good}}
        ],
        clean_reader()
      )

    assert errors != []
    assert hd(errors) =~ "malformed"

    errors =
      run(
        documents,
        [
          {sha("a"), [], %{@gate_path => gate, @runner => @good}},
          {sha("b"), [sha("a")], %{@gate_path => absent, @runner => @bad}},
          {sha("c"), [sha("b")], %{@gate_path => gate, @runner => @good}}
        ],
        clean_reader()
      )

    assert errors != []
    assert hd(errors) =~ "disappeared"
  end

  test "gate bound artifacts are verified against the working tree" do
    gate = one_artifact_gate()
    documents = Fixture.open_milestone_documents(gate)

    assert [] ==
             Fixture.checked(documents,
               historical_gate: gate,
               read_artifact: fn _target -> @good end
             )

    errors =
      Fixture.checked(documents, historical_gate: gate, read_artifact: fn _target -> @bad end)

    assert errors != []
    assert hd(errors) =~ "does not match its locked digest"

    errors =
      Fixture.checked(documents, historical_gate: gate, read_artifact: fn _target -> nil end)

    assert errors != []
    assert hd(errors) =~ "is missing"
  end

  test "completed governance rows are history anchored" do
    original = Fixture.plan(governed: true)
    current = String.replace(original, "| 1 | Open | — |", "| 1 | Proved | evidence |")
    snapshot = &Fixture.plan_snapshot(&1, Fixture.gate())

    anchored =
      {"first-completion",
       [{"root", [], %{}}, {"first-completion", ["root"], snapshot.(original)}]}

    assert :ok == History.governance_history(snapshot.(current), anchored)

    mutations = [
      {"authority", "Maintainer", "Delegate: Reviewer"},
      {"evidence", "../vision.md#concept", "../vision.md#concept-other"},
      {"candidate", sha("a"), sha("b")}
    ]

    for {label, old, new} <- mutations do
      changed = String.replace(original, old, new, global: false)

      assert_raise Invalid, ~r/completed Acceptance/, fn ->
        History.governance_history(snapshot.(changed), anchored)
      end

      assert label != nil
    end

    changed_gate = "# Changed gate\n"

    changed =
      String.replace(
        Fixture.plan(governed: true, gate: changed_gate),
        "Maintainer | [disposition](../vision.md#concept)",
        "Delegate: Reviewer | [disposition](../vision.md#concept-other)"
      )

    assert_raise Invalid, ~r/completed Acceptance/, fn ->
      History.governance_history(snapshot.(changed), anchored)
    end

    for {label, intermediate} <- [
          {"mutate then restore",
           String.replace(original, "Maintainer", "Delegate: Reviewer", global: false)},
          {"clear then restore", Fixture.plan()}
        ] do
      history =
        {"later",
         [
           {"root", [], %{}},
           {"first-completion", ["root"], snapshot.(original)},
           {"later", ["first-completion"], snapshot.(intermediate)}
         ]}

      assert_raise Invalid, ~r/completed Acceptance|accepted gate/, fn ->
        History.governance_history(snapshot.(original), history)
      end

      assert label != nil
    end

    deleted =
      {"deleted",
       [
         {"root", [], %{}},
         {"first-completion", ["root"], snapshot.(original)},
         {"deleted", ["first-completion"], %{}}
       ]}

    assert_raise Invalid, ~r/disappeared/, fn ->
      History.governance_history(snapshot.(original), deleted)
    end

    assert_raise Invalid, ~r/disappeared/, fn ->
      History.governance_history(%{}, anchored)
    end

    closed_original = Fixture.plan(governed: true, closed: true)

    closure_history =
      {"closure", [{"root", [], %{}}, {"closure", ["root"], snapshot.(closed_original)}]}

    assert_raise Invalid, ~r/completed Closure/, fn ->
      History.governance_history(
        snapshot.(
          String.replace(
            closed_original,
            "../roadmap.md#concept",
            "../roadmap.md#concept-other",
            global: false
          )
        ),
        closure_history
      )
    end

    assert_raise Invalid, ~r/history is unavailable/, fn ->
      History.governance_history(snapshot.(original), nil)
    end

    merged = String.replace(original, "Maintainer", "Delegate: Reviewer", global: false)

    merge_history =
      {"merge",
       [
         {"root", [], %{}},
         {"accepted-topic", ["root"], snapshot.(original)},
         {"main-work", ["root"], %{}},
         {"merge", ["main-work", "accepted-topic"], snapshot.(merged)}
       ]}

    assert_raise Invalid, ~r/completed Acceptance/, fn ->
      History.governance_history(snapshot.(merged), merge_history)
    end
  end

  test "an accepted gate is anchored but an open gate is mutable" do
    gate = Fixture.gate()
    accepted = Fixture.plan(governed: true)
    changed_gate = "# Changed gate\n"

    history =
      {"accepted",
       [{"root", [], %{}}, {"accepted", ["root"], Fixture.plan_snapshot(accepted, gate)}]}

    assert :ok ==
             History.governance_history(Fixture.plan_snapshot(accepted, gate), history)

    assert_raise Invalid, ~r/accepted gate/, fn ->
      History.governance_history(Fixture.plan_snapshot(accepted, changed_gate), history)
    end

    for {label, later} <- [
          {"mutate then restore", Fixture.plan_snapshot(accepted, changed_gate)},
          {"delete then restore", Fixture.plan_snapshot(accepted)}
        ] do
      {_head, snapshots} = history
      traversed = {"later", snapshots ++ [{"later", ["accepted"], later}]}

      assert_raise Invalid, ~r/accepted gate|gate is missing/, fn ->
        History.governance_history(Fixture.plan_snapshot(accepted, gate), traversed)
      end

      assert label != nil
    end

    merged =
      {"merge",
       [
         {"root", [], %{}},
         {"accepted", ["root"], Fixture.plan_snapshot(accepted, gate)},
         {"main", ["root"], Fixture.plan_snapshot(Fixture.plan(), changed_gate)},
         {"merge", ["main", "accepted"], Fixture.plan_snapshot(accepted, changed_gate)}
       ]}

    assert_raise Invalid, ~r/accepted gate/, fn ->
      History.governance_history(Fixture.plan_snapshot(accepted, changed_gate), merged)
    end

    open_history =
      {"open",
       [{"root", [], %{}}, {"open", ["root"], Fixture.plan_snapshot(Fixture.plan(), gate)}]}

    assert :ok ==
             History.governance_history(
               Fixture.plan_snapshot(Fixture.plan(), changed_gate),
               open_history
             )

    noncanonical = "# Gate\r\n"

    assert_raise Invalid, ~r|UTF-8/LF|, fn ->
      History.governance_history(
        Fixture.plan_snapshot(accepted, noncanonical),
        {"accepted",
         [
           {"root", [], %{}},
           {"accepted", ["root"], Fixture.plan_snapshot(accepted, noncanonical)}
         ]}
      )
    end
  end

  test "paired technical history rejects restore, delete, and merge divergence" do
    gate = Fixture.gate()
    accepted = Fixture.plan(governed: true)

    changed_technical =
      String.replace(
        Fixture.technical_plan(),
        "No compatibility claim.",
        "A different compatibility claim."
      )

    accepted_snapshot = Fixture.plan_snapshot(accepted, gate)
    history = {"accepted", [{"root", [], %{}}, {"accepted", ["root"], accepted_snapshot}]}

    assert_raise Invalid, ~r/normative technical envelope/, fn ->
      History.governance_history(
        Fixture.plan_snapshot(accepted, gate, changed_technical),
        history
      )
    end

    {_head, snapshots} = history

    mutated =
      {"mutated",
       snapshots ++
         [{"mutated", ["accepted"], Fixture.plan_snapshot(accepted, gate, changed_technical)}]}

    assert_raise Invalid, ~r/normative technical envelope/, fn ->
      History.governance_history(accepted_snapshot, mutated)
    end

    without_technical = %{"docs/plans/M0.md" => accepted, @gate_path => gate}
    deleted = {"deleted", snapshots ++ [{"deleted", ["accepted"], without_technical}]}

    assert_raise Invalid, ~r/technical depth disappeared/, fn ->
      History.governance_history(accepted_snapshot, deleted)
    end

    merged =
      {"merge",
       [
         {"root", [], %{}},
         {"accepted", ["root"], accepted_snapshot},
         {"main", ["root"], %{}},
         {"merge", ["main", "accepted"], Fixture.plan_snapshot(accepted, gate, changed_technical)}
       ]}

    assert_raise Invalid, ~r/normative technical envelope/, fn ->
      History.governance_history(
        Fixture.plan_snapshot(accepted, gate, changed_technical),
        merged
      )
    end

    # An open plan's technical depth is not yet anchored, so it may change.
    open_history =
      {"open",
       [{"root", [], %{}}, {"open", ["root"], Fixture.plan_snapshot(Fixture.plan(), gate)}]}

    assert :ok ==
             History.governance_history(
               Fixture.plan_snapshot(Fixture.plan(), gate, changed_technical),
               open_history
             )

    accepted_adr = Fixture.adr(1, true)
    adr_snapshot = Fixture.adr_snapshot(1, accepted_adr)

    adr_history =
      {"accepted-adr", [{"root", [], %{}}, {"accepted-adr", ["root"], adr_snapshot}]}

    technical_path =
      Fixture.adr_paths() |> Enum.at(0) |> String.replace_suffix(".md", "-technical.md")

    changed_adr_snapshot =
      Map.update!(
        adr_snapshot,
        technical_path,
        &String.replace(&1, "Exact constraints", "Different constraints")
      )

    assert_raise Invalid, ~r/accepted technical depth/, fn ->
      History.governance_history(changed_adr_snapshot, adr_history)
    end

    {_adr_head, adr_snapshots} = adr_history

    restored =
      {"restored", adr_snapshots ++ [{"changed", ["accepted-adr"], changed_adr_snapshot}]}

    assert_raise Invalid, ~r/accepted technical depth/, fn ->
      History.governance_history(adr_snapshot, restored)
    end
  end

  test "accepted ADR history is anchored through merges" do
    path = Enum.at(Fixture.adr_paths(), 0)
    proposal = Fixture.adr(1)
    accepted = Fixture.adr(1, true)

    legacy =
      (proposal |> String.split("## Governance Record", parts: 2) |> hd()) <>
        "## Context\n\nLegacy.\n"

    history =
      {"accepted",
       [
         {"legacy", [], %{path => legacy}},
         {"proposal", ["legacy"], Fixture.adr_snapshot(1, proposal)},
         {"accepted", ["proposal"], Fixture.adr_snapshot(1, accepted)}
       ]}

    assert :ok == History.governance_history(Fixture.adr_snapshot(1, accepted), history)

    changed =
      String.replace(accepted, "Choose the bounded decision.", "Rewrite the accepted decision.")

    assert_raise Invalid, ~r/accepted concept/, fn ->
      History.governance_history(Fixture.adr_snapshot(1, changed), history)
    end

    {_head, snapshots} = history
    deleted = {"deleted", snapshots ++ [{"deleted", ["accepted"], %{}}]}

    assert_raise Invalid, ~r/disappeared/, fn ->
      History.governance_history(Fixture.adr_snapshot(1, accepted), deleted)
    end

    merged =
      {"merge",
       [
         {"root", [], %{}},
         {"accepted", ["root"], Fixture.adr_snapshot(1, accepted)},
         {"main", ["root"], %{}},
         {"merge", ["main", "accepted"], Fixture.adr_snapshot(1, changed)}
       ]}

    assert_raise Invalid, ~r/accepted concept/, fn ->
      History.governance_history(Fixture.adr_snapshot(1, changed), merged)
    end

    documents = Map.delete(Fixture.documents(), Enum.at(Fixture.adr_paths(), 1))
    errors = Fixture.checked(documents)
    assert errors != []
    assert hd(errors) =~ "unknown active"
  end

  test "a plan envelope is anchored with acceptance history" do
    original = Fixture.plan(governed: true)
    changed = String.replace(original, "Only the bounded outcome.", "A larger scope.")
    snapshot = &Fixture.plan_snapshot(&1, Fixture.gate())

    history =
      {"accepted", [{"root", [], %{}}, {"accepted", ["root"], snapshot.(original)}]}

    progress_changed =
      String.replace(original, "| 1 | Open | — |", "| 1 | Proved | [run](evidence.md) |")

    assert :ok == History.governance_history(snapshot.(progress_changed), history)

    assert_raise Invalid, ~r/normative concept envelope/, fn ->
      History.governance_history(snapshot.(changed), history)
    end

    merge =
      {"merge",
       [
         {"root", [], %{}},
         {"accepted", ["root"], snapshot.(original)},
         {"main", ["root"], %{}},
         {"merge", ["main", "accepted"], snapshot.(changed)}
       ]}

    assert_raise Invalid, ~r/normative concept envelope/, fn ->
      History.governance_history(snapshot.(changed), merge)
    end
  end

  test "a declared generation advances envelopes without admitting drift or divergence" do
    original_gate = Fixture.gate()

    amended_gate =
      original_gate <>
        "\n<a id=\"amendment-1\"></a>\n" <>
        "## Amendment 1 — revise the accepted lifecycle\n"

    original = Fixture.plan(governed: true)
    changed = String.replace(original, "Only the bounded outcome.", "A revised outcome.")

    changed_again =
      String.replace(original, "Only the bounded outcome.", "A conflicting revision.")

    accepted = Fixture.plan_snapshot(original, original_gate)
    amended = Fixture.plan_snapshot(changed, amended_gate)
    conflicting = Fixture.plan_snapshot(changed_again, amended_gate)

    sequential =
      {"amended",
       [
         {"root", [], %{}},
         {"accepted", ["root"], accepted},
         {"amended", ["accepted"], amended}
       ]}

    assert :ok == History.governance_history(amended, sequential)

    silent =
      {"silent",
       [
         {"root", [], %{}},
         {"accepted", ["root"], accepted},
         {"silent", ["accepted"], Fixture.plan_snapshot(changed, original_gate)}
       ]}

    assert_raise Invalid, ~r/normative concept envelope/, fn ->
      History.governance_history(Fixture.plan_snapshot(changed, original_gate), silent)
    end

    rollback =
      {"rollback",
       [
         {"root", [], %{}},
         {"accepted", ["root"], accepted},
         {"amended", ["accepted"], amended},
         {"rollback", ["amended"], accepted}
       ]}

    assert_raise Invalid, ~r/accepted gate|normative concept envelope/, fn ->
      History.governance_history(accepted, rollback)
    end

    clean_merge =
      {"merge",
       [
         {"root", [], %{}},
         {"accepted", ["root"], accepted},
         {"main", ["accepted"], accepted},
         {"amended", ["accepted"], amended},
         {"merge", ["main", "amended"], amended}
       ]}

    assert :ok == History.governance_history(amended, clean_merge)

    divergent_merge =
      {"merge",
       [
         {"root", [], %{}},
         {"accepted", ["root"], accepted},
         {"left", ["accepted"], amended},
         {"right", ["accepted"], conflicting},
         {"merge", ["left", "right"], amended}
       ]}

    assert_raise Invalid, ~r/conflicting completed normative concept envelope/, fn ->
      History.governance_history(amended, divergent_merge)
    end

    changed_technical =
      String.replace(
        Fixture.technical_plan(),
        "No compatibility claim.",
        "A revised compatibility claim."
      )

    technical_amendment =
      Fixture.plan_snapshot(original, amended_gate, changed_technical)

    technical_history =
      {"technical-amendment",
       [
         {"root", [], %{}},
         {"accepted", ["root"], accepted},
         {"technical-amendment", ["accepted"], technical_amendment}
       ]}

    assert :ok == History.governance_history(technical_amendment, technical_history)
  end

  test "a higher-generation sibling amendment cannot displace an accepted lineage" do
    original = Fixture.gate()

    amendment_one =
      original <>
        "\n<a id=\"amendment-1\"></a>\n" <>
        "## Amendment 1 — first branch\n"

    sibling_amendment_two =
      original <>
        "\n<a id=\"amendment-1\"></a>\n" <>
        "## Amendment 1 — sibling branch\n\n" <>
        "<a id=\"amendment-2\"></a>\n" <>
        "## Amendment 2 — sibling branch\n"

    original_candidate = sha("a")
    original_acceptance = sha("b")
    first_candidate = sha("c")
    first_rebind = sha("d")
    sibling_candidate = sha("e")
    sibling_rebind = sha("f")
    merge = sha("1")

    empty = Fixture.plan()
    accepted = Fixture.plan(governed: true)

    first_bound =
      Fixture.plan(governed: true, gate: amendment_one)
      |> String.replace("candidate `#{original_candidate}`", "candidate `#{first_candidate}`")

    sibling_bound =
      Fixture.plan(governed: true, gate: sibling_amendment_two)
      |> String.replace(
        "candidate `#{original_candidate}`",
        "candidate `#{sibling_candidate}`"
      )

    root = {"root", [], %{}}
    original_snapshot = Fixture.plan_snapshot(empty, original)
    accepted_snapshot = Fixture.plan_snapshot(accepted, original)
    first_candidate_snapshot = Fixture.plan_snapshot(accepted, amendment_one)
    first_rebind_snapshot = Fixture.plan_snapshot(first_bound, amendment_one)
    sibling_candidate_snapshot = Fixture.plan_snapshot(accepted, sibling_amendment_two)
    sibling_rebind_snapshot = Fixture.plan_snapshot(sibling_bound, sibling_amendment_two)

    shared = [
      root,
      {original_candidate, ["root"], original_snapshot},
      {original_acceptance, [original_candidate], accepted_snapshot}
    ]

    first_history =
      {first_rebind,
       shared ++
         [
           {first_candidate, [original_acceptance], first_candidate_snapshot},
           {first_rebind, [first_candidate], first_rebind_snapshot}
         ]}

    sibling_history =
      {sibling_rebind,
       shared ++
         [
           {sibling_candidate, [original_acceptance], sibling_candidate_snapshot},
           {sibling_rebind, [sibling_candidate], sibling_rebind_snapshot}
         ]}

    assert :ok == History.governance_history(first_rebind_snapshot, first_history)
    assert :ok == History.governance_history(sibling_rebind_snapshot, sibling_history)

    merged_history =
      {merge,
       shared ++
         [
           {first_candidate, [original_acceptance], first_candidate_snapshot},
           {first_rebind, [first_candidate], first_rebind_snapshot},
           {sibling_candidate, [original_acceptance], sibling_candidate_snapshot},
           {sibling_rebind, [sibling_candidate], sibling_rebind_snapshot},
           {merge, [first_rebind, sibling_rebind], sibling_rebind_snapshot}
         ]}

    assert_raise Invalid, ~r/conflicting completed Acceptance/, fn ->
      History.governance_history(sibling_rebind_snapshot, merged_history)
    end
  end
end
