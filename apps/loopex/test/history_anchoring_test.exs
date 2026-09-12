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

  alias Loopex.Checks.Git
  alias Loopex.Checks.History
  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Plan
  alias Loopex.Checks.Status
  alias Loopex.StatusFixtures, as: Fixture

  @good "#!/usr/bin/env bash\nexit 1\n"
  @bad "#!/usr/bin/env bash\nexit 0\n"
  @other "x = 1\n"
  @runner "scripts/run-gate.sh"
  @config "cfg.exs"
  @gate_path "docs/plans/M0-gate.md"

  defp one_artifact_gate do
    artifact_gate() <>
      "| `#{Markdown.digest(@good)}` | `#{@runner}` |\n"
  end

  defp two_artifact_gate do
    artifact_gate() <>
      "| `#{Markdown.digest(@good)}` | `#{@runner}` |\n" <>
      "| `#{Markdown.digest(@other)}` | `#{@config}` |\n"
  end

  defp config_only_gate do
    artifact_gate() <>
      "| `#{Markdown.digest(@other)}` | `#{@config}` |\n"
  end

  defp artifact_gate do
    String.trim_trailing(Fixture.gate()) <>
      "\n\n## Bound Artifacts\n\n| SHA-256 | Path |\n| --- | --- |\n"
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

  test "sequential shared bindings settle each holder without erasing intermediate history" do
    snapshots = shared_binding_history()
    assert :ok == History.artifact_history({elem(List.last(snapshots), 0), snapshots})
    assert :ok == generation_history(snapshots)
    # Artifact history previously admitted a fully matching atomic update;
    # governance independently decides whether that document transition is legal.
    base = hd(snapshots)
    last = List.last(snapshots)

    assert :ok ==
             History.artifact_history(
               {"atomic", [base, {"atomic", [elem(base, 0)], elem(last, 2)}]}
             )

    partial = Enum.take(snapshots, 3)

    assert_raise Invalid, ~r/unfinished shared binding/, fn ->
      History.artifact_history({elem(List.last(partial), 0), partial})
    end

    assert %{binding_scope: "M1", pending_holders: ["M2", "M3"]} =
             History.artifact_history({elem(List.last(partial), 0), partial}, holder: "M1")

    assert_raise Invalid, ~r/holder scope/, fn ->
      History.artifact_history({elem(List.last(partial), 0), partial}, holder: "M2")
    end
  end

  test "shared binding scope rejects changed bytes dropped holders overlap and unrelated progress" do
    history = shared_binding_history()
    [base, a1, r1, a2, r2, a3, r3] = history
    change = fn {sha, parents, files}, fun -> {sha, parents, fun.(files)} end

    invalid = [
      # An earlier mismatch cannot be laundered by a later legitimate sequence.
      [
        base,
        {"early", [elem(base, 0)], Map.put(elem(base, 2), @runner, @bad)},
        {elem(a1, 0), ["early"], elem(a1, 2)}
      ] ++ Enum.drop(history, 2),
      [base, change.(a1, &Map.delete(&1, "docs/plans/M2-gate.md"))] ++ Enum.drop(history, 2),
      [
        base,
        change.(a1, &Map.put(&1, "docs/plans/M2-gate.md", elem(a2, 2)["docs/plans/M2-gate.md"]))
      ] ++ Enum.drop(history, 2),
      [base, a1, {elem(a2, 0), [elem(a1, 0)], elem(a2, 2)}, r2, a3, r3],
      [base, a1, r1, {"ordinary", [elem(r1, 0)], elem(r1, 2)}],
      [base, a1, r1, change.(a2, &Map.put(&1, @runner, @good)), r2, a3, r3],
      [
        base,
        a1,
        r1,
        change.(a2, fn files ->
          Map.update!(
            files,
            "docs/plans/M2-gate.md",
            &String.replace(&1, Markdown.digest(@bad), Markdown.digest("different"))
          )
        end),
        r2,
        a3,
        r3
      ],
      [
        base,
        change.(a1, fn files ->
          Map.update!(
            files,
            "docs/plans/M1-gate.md",
            &String.replace(
              &1,
              "| `#{Markdown.digest(@bad)}` | `#{@runner}` |",
              "| `#{Markdown.digest(@bad)}` | `#{@runner}` |\n| `#{Markdown.digest(@good)}` | `#{@runner}` |"
            )
          )
        end)
      ] ++ Enum.drop(history, 2),
      [base, a1, change.(r1, &Map.put(&1, @runner, @good))],
      [base, a1, {"wrong-parent", [elem(base, 0)], elem(r1, 2)}],
      Enum.take(history, 3) ++
        [{"working tree", [elem(r1, 0)], Map.put(elem(r1, 2), @runner, @bad <> "x")}]
    ]

    for snapshots <- invalid do
      head = elem(List.last(snapshots), 0)
      assert_raise Invalid, fn -> History.artifact_history({head, snapshots}, holder: "M1") end
    end

    assert_raise Invalid, ~r/holder scope/, fn ->
      History.artifact_history({elem(r3, 0), history}, holder: "unknown")
    end

    assert_raise Invalid, ~r/holder scope/, fn ->
      History.artifact_history({elem(a1, 0), [base, a1]}, holder: "M1")
    end
  end

  test "shared binding completion permits covered prefixes but refuses divergent pending merges" do
    history = shared_binding_history()
    [base, a1, r1 | _] = history
    last = List.last(history)
    covered = history ++ [{"merge", [elem(last, 0), elem(r1, 0)], elem(last, 2)}]
    assert :ok == History.artifact_history({"merge", covered})

    diverged = [
      base,
      a1,
      r1,
      {"other", [elem(base, 0)], elem(base, 2)},
      {"merge", [elem(r1, 0), "other"], elem(r1, 2)}
    ]

    assert_raise Invalid, ~r/divergent lineage/, fn ->
      History.artifact_history({"merge", diverged}, holder: "M1")
    end
  end

  test "a pending holder may change its local artifact only in its own proposal" do
    history = shared_binding_history()
    local = "scripts/local-second.exs"

    with_local = fn change_index, shared? ->
      Enum.with_index(history)
      |> Enum.map(fn {{revision, parents, files}, index} ->
        bytes = if index >= change_index, do: "new local", else: "old local"

        files =
          Enum.reduce(if(shared?, do: ["M2", "M3"], else: ["M2"]), files, fn holder, files ->
            expected =
              if holder == "M2" and index >= change_index, do: "new local", else: "old local"

            gate = "docs/plans/#{holder}-gate.md"
            text = Map.fetch!(files, gate)

            text =
              String.replace(
                text,
                "| --- | --- |",
                "| --- | --- |\n| `#{Markdown.digest(expected)}` | `#{local}` |"
              )

            Map.put(files, gate, text)
          end)
          |> Map.put(local, bytes)

        {revision, parents, files}
      end)
    end

    valid = with_local.(3, false)
    assert :ok == History.artifact_history({elem(List.last(valid), 0), valid})

    for bad <- [with_local.(4, false), with_local.(3, true)] do
      assert_raise Invalid, fn -> History.artifact_history({elem(List.last(bad), 0), bad}) end
    end
  end

  test "scoped status requires both current bytes and full history" do
    documents = Fixture.documents()
    assert [message] = Status.validate(documents, artifact_holder: "M1")
    assert message =~ "requires current artifact bytes and complete history"

    assert [message] =
             Status.validate(documents, artifact_holder: "M1", read_artifact: fn _ -> @good end)

    assert message =~ "requires current artifact bytes and complete history"
  end

  test "scoped status validates complete governance and current bytes before its explicit pending result" do
    history = shared_status_history()
    # Plan's existing ancestry check uses Git; give synthetic contents real,
    # linearly related node identities without changing that ancestry proof.
    root = Path.expand("../../..", __DIR__)

    {revisions, 0} =
      Loopex.Checks.Git.run(root, ["rev-list", "--first-parent", "--max-count=10", "HEAD"])

    replacements =
      Enum.zip(Enum.map(history, &elem(&1, 0)), revisions |> String.split() |> Enum.reverse())

    history =
      Enum.map(history, fn {revision, parents, files} ->
        replace = fn text ->
          Enum.reduce(replacements, text, fn {old, new}, text ->
            String.replace(text, old, new)
          end)
        end

        {replace.(revision), Enum.map(parents, replace),
         Map.new(files, fn {path, text} -> {path, replace.(text)} end)}
      end)

    partial = Enum.take(history, 6)

    check = fn snapshots, options ->
      {head, _, files} = List.last(snapshots)

      Status.validate(
        Map.delete(files, @runner),
        [
          plan_history: fn -> {head, snapshots} end,
          resolve_file: generation_resolver(snapshots),
          read_artifact:
            Keyword.get(options, :read_artifact, fn target -> Map.get(files, target) end)
        ] ++ Keyword.delete(options, :read_artifact)
      )
    end

    assert %{binding_scope: "first", pending_holders: ["second", "third"]} =
             check.(partial, artifact_holder: "first")

    assert [global_error] = check.(partial, [])
    assert global_error =~ "unfinished shared binding"
    assert [] == check.(history, [])
    # Every holder's A/R is locally well formed, but their overlap is not a
    # sequential shared-byte update even though no stale row ever appears.
    {a, [parent], first_proposal} = Enum.at(history, 4)
    {r, _, _} = Enum.at(history, 5)
    {_, _, final_files} = List.last(history)

    proposals =
      Enum.reduce([{"first", 4}, {"second", 6}, {"third", 8}], final_files, fn {name, index},
                                                                               files ->
        Map.put(
          files,
          "docs/plans/#{name}.md",
          elem(Enum.at(history, index), 2)["docs/plans/#{name}.md"]
        )
      end)
      |> Map.put(
        "docs/developer/agent-context-map.md",
        first_proposal["docs/developer/agent-context-map.md"]
      )

    simultaneous_rebind =
      Map.new(final_files, fn {path, text} ->
        {path,
         Enum.reduce([6, 8], text, fn index, text ->
           String.replace(text, elem(Enum.at(history, index), 0), a)
         end)}
      end)

    overlapping =
      Enum.take(history, 4) ++ [{a, [parent], proposals}, {r, [a], simultaneous_rebind}]

    assert :ok == generation_history(overlapping)
    assert [overlap_error] = check.(overlapping, [])
    assert overlap_error =~ "simultaneous shared binding proposals"

    assert [dirty_error] =
             check.(partial,
               artifact_holder: "first",
               read_artifact: fn _ -> @bad <> "dirty" end
             )

    assert dirty_error =~ "locked digest"
    assert [_] = check.(partial, artifact_holder: "second")
    assert [_] = check.(partial, artifact_holder: "unknown")
    assert [_] = check.(Enum.take(history, 5), artifact_holder: "first")
    {_, _, rebound_files} = List.last(partial)

    malformed =
      List.update_at(partial, 4, fn {r, parents, files} ->
        {r, parents,
         Map.put(
           files,
           "docs/developer/agent-context-map.md",
           rebound_files["docs/developer/agent-context-map.md"]
         )}
      end)

    assert [authority_error] = check.(malformed, artifact_holder: "first")
    assert authority_error =~ "disposition"
  end

  defp shared_status_history do
    [base | tail] = shared_binding_history()
    base_files = elem(base, 2)
    old_gate = one_artifact_gate()

    stages =
      for {id, governed, progress} <- [
            {"a", false, "Open"},
            {"b", true, "Open"},
            {"c", true, "Proved"}
          ] do
        files =
          Enum.reduce(["M1", "M2", "M3"], base_files, fn name, files ->
            Map.put(
              files,
              "docs/plans/#{name}.md",
              Fixture.plan(governed: governed, progress: progress, gate: old_gate)
            )
          end)

        parent =
          case id do
            "a" -> []
            "b" -> [sha("a")]
            "c" -> [sha("b")]
          end

        {sha(id), parent, files}
      end

    [{a1, _, files} | rest] = tail
    raw = stages ++ [{sha("d"), [sha("c")], base_files}, {a1, [sha("d")], files} | rest]
    names = [{"M1", "first"}, {"M2", "second"}, {"M3", "third"}]

    Enum.map(raw, fn {revision, parents, source} ->
      documents =
        Enum.reduce(names, Fixture.documents(), fn {old, name}, docs ->
          path = "docs/plans/#{old}.md"
          concept = source[path] |> String.replace("M0", name)
          technical = Fixture.technical_plan() |> String.replace("M0", name)
          gate = source["docs/plans/#{old}-gate.md"] |> String.replace("M0", name)

          concept_hash =
            concept |> Plan.concept_envelope(path) |> elem(0) |> Plan.envelope_digest()

          technical_hash = technical |> Plan.technical_envelope(path) |> Plan.envelope_digest()

          concept =
            concept
            |> String.replace(
              ~r/concept `sha256:[0-9a-f]{64}`/,
              "concept `sha256:#{concept_hash}`"
            )
            |> String.replace(
              ~r/technical `sha256:[0-9a-f]{64}`/,
              "technical `sha256:#{technical_hash}`"
            )

          concept =
            Enum.reduce(raw, concept, fn {_, _, historical}, text ->
              old_gate = historical["docs/plans/#{old}-gate.md"]

              String.replace(
                text,
                Markdown.digest(old_gate),
                Markdown.digest(String.replace(old_gate, "M0", name))
              )
            end)

          docs
          |> Map.put("docs/plans/#{name}.md", concept)
          |> Map.put("docs/plans/#{name}-technical.md", technical)
          |> Map.put("docs/plans/#{name}-gate.md", gate)
        end)

      rows = [{"first", "Closed"}, {"second", "Closed"}, {"third", "Accepted"}]

      rows =
        if revision in [sha("a"), sha("b"), sha("c")],
          do:
            Enum.map(rows, fn {name, _} ->
              {name, if(revision == sha("a"), do: "Open", else: "Accepted")}
            end),
          else: rows

      index =
        documents["docs/plans/README.md"]
        |> String.replace(
          Fixture.blocked_row(),
          Enum.map_join(rows, "\n", fn {name, state} ->
            "| `#{name}` | #{state} | [concept](#{name}.md) | [technical depth](#{name}-technical.md) | [gate](#{name}-gate.md) |"
          end)
        )

      summary =
        Loopex.Checks.Register.summary("Closed milestone product baseline", [
          {"first", "Closed"},
          {"second", "Closed"},
          {"third", "Accepted"}
        ])

      {capsule, old_summary} = Loopex.Checks.Register.current_status(index)

      expected =
        Loopex.Checks.Register.expected_capsule("Accepted", "third", %{})
        |> Map.put("Last closed product checkpoint", "`second` — 2026-09-12")
        |> Map.put("Integrated phase", Loopex.Checks.Register.integrated_phase(rows))

      index =
        Enum.reduce(expected, String.replace(index, old_summary, summary), fn {key, value},
                                                                              text ->
          if Map.has_key?(capsule, key),
            do: String.replace(text, "| #{key} | #{capsule[key]} |", "| #{key} | #{value} |"),
            else: text
        end)

      documents =
        documents
        |> Map.put("docs/plans/README.md", index)
        |> Map.update!("README.md", &String.replace(&1, old_summary, summary))
        |> Map.put(
          "docs/developer/agent-context-map.md",
          source["docs/developer/agent-context-map.md"]
        )
        |> Map.put(@runner, source[@runner])

      {revision, parents, documents}
    end)
  end

  defp shared_binding_history do
    old_gate = one_artifact_gate()
    new_gate = Fixture.amended_gate(1, mutated_artifact_gate())
    old_plan = Fixture.plan(governed: true, closed: true, gate: old_gate)

    files =
      Map.new(["M1", "M2", "M3"], fn name ->
        {"docs/plans/#{name}-gate.md", old_gate}
      end)

    files =
      Enum.reduce(["M1", "M2", "M3"], files, fn name, acc ->
        plan = if name == "M3", do: Fixture.plan(governed: true, gate: old_gate), else: old_plan

        acc
        |> Map.put("docs/plans/#{name}.md", plan)
        |> Map.put("docs/plans/#{name}-technical.md", Fixture.technical_plan())
      end)
      |> Map.put(@runner, @good)

    index =
      Fixture.documents()
      |> Map.fetch!("docs/plans/README.md")
      |> String.replace(
        Fixture.blocked_row(),
        Enum.map_join(["M1", "M2", "M3"], "\n", fn name ->
          state = if name == "M3", do: "Accepted", else: "Closed"

          "| `#{name}` | #{state} | [concept](#{name}.md) | [technical depth](#{name}-technical.md) | [gate](#{name}-gate.md) |"
        end)
      )

    files =
      files
      |> Map.put("docs/plans/README.md", index)
      |> Map.put("docs/developer/agent-context-map.md", "# Context\n")

    {_files, history} =
      Enum.reduce(
        Enum.with_index(["M1", "M2", "M3"], 1),
        {files, [{sha("a"), [], files}]},
        fn {name, index}, {prior, history} ->
          a = String.duplicate(Integer.to_string(index * 2), 40)
          r = String.duplicate(Integer.to_string(index * 2 + 1), 40)
          disposition = "../developer/agent-context-map.md#shared-binding-#{index}"

          gate =
            if name == "M3",
              do:
                String.replace(new_gate, "amendment-transaction-v2", "amendment-transaction-v1"),
              else: new_gate

          proposal =
            if name == "M3" do
              Fixture.plan(governed: true, gate: old_gate)
            else
              Fixture.plan(
                governed: true,
                closed: true,
                gate: old_gate,
                generations: [Fixture.proposed_generation(1, gate)]
              )
            end

          accepted =
            if name == "M3" do
              Fixture.plan(governed: true, gate: gate)
              |> String.replace("candidate `#{sha("a")}`", "candidate `#{a}`")
              |> String.replace("../vision.md#concept", disposition)
            else
              Fixture.plan(
                governed: true,
                closed: true,
                gate: old_gate,
                generations: [Fixture.accepted_generation(1, a, gate, disposition)]
              )
            end

          proposed =
            prior
            |> Map.put("docs/plans/#{name}-gate.md", gate)
            |> Map.put("docs/plans/#{name}.md", proposal)
            |> Map.put(@runner, @bad)

          rebound =
            proposed
            |> Map.put("docs/plans/#{name}.md", accepted)
            |> Map.update!(
              "docs/developer/agent-context-map.md",
              &(&1 <> "\n<a id=\"shared-binding-#{index}\"></a>\nAccepted.\n")
            )

          parent = elem(List.last(history), 0)
          {rebound, history ++ [{a, [parent], proposed}, {r, [a], rebound}]}
        end
      )

    history
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

  # The additive transaction a Closed milestone must use, because its Closure row
  # binds the same gate digest its Acceptance row binds, so rebinding one of the
  # two would leave the other naming bytes that no longer exist.
  @disposition "../developer/agent-context-map.md#gate-generation-1"
  @index_path "docs/plans/README.md"
  @context_path "docs/developer/agent-context-map.md"

  defp mutated_artifact_gate do
    artifact_gate() <> "| `#{Markdown.digest(@bad)}` | `#{@runner}` |\n"
  end

  defp closed_index(state) do
    Fixture.documents()
    |> Map.fetch!(@index_path)
    |> String.replace(
      Fixture.blocked_row(),
      "| `M0` | #{state} | [concept](M0.md) | " <>
        "[technical depth](M0-technical.md) | [gate](M0-gate.md) |"
    )
  end

  defp context_before, do: "# Context map\n"

  defp context_after do
    context_before() <>
      "\n<a id=\"gate-generation-1\"></a>\n## Gate generation 1\n\nMaintainer accepted it.\n"
  end

  defp generation_snapshot(plan, gate, artifact, context, state \\ "Closed") do
    plan
    |> Fixture.plan_snapshot(gate)
    |> Map.put(@index_path, closed_index(state))
    |> Map.put(@context_path, context)
    |> Map.put(@runner, artifact)
  end

  defp generation_resolver(snapshots) do
    files = Map.new(snapshots, fn {revision, _parents, contents} -> {revision, contents} end)
    fn revision, path -> files |> Map.get(revision, %{}) |> Map.get(path) end
  end

  defp generation_history(snapshots) do
    {head, _parents, files} = List.last(snapshots)
    History.governance_history(files, {head, snapshots}, generation_resolver(snapshots))
  end

  test "a Closed milestone's gate generation is one atomic proposal and one rebind" do
    original_gate = one_artifact_gate()
    amended_gate = Fixture.amended_gate(1, mutated_artifact_gate())

    closed = Fixture.plan(governed: true, closed: true, gate: original_gate)

    proposal_plan =
      Fixture.plan(
        governed: true,
        closed: true,
        gate: original_gate,
        generations: [Fixture.proposed_generation(1, amended_gate)]
      )

    rebind_plan = fn candidate ->
      Fixture.plan(
        governed: true,
        closed: true,
        gate: original_gate,
        generations: [Fixture.accepted_generation(1, candidate, amended_gate, @disposition)]
      )
    end

    origin = sha("a")
    proposal = sha("1")
    rebind = sha("2")

    opening = [
      {"root", [], %{}},
      {origin, ["root"],
       generation_snapshot(Fixture.plan(), original_gate, @good, context_before(), "Open")}
    ]

    base =
      opening ++
        [
          {"closed", [origin],
           generation_snapshot(closed, original_gate, @good, context_before())},
          {proposal, ["closed"],
           generation_snapshot(proposal_plan, amended_gate, @bad, context_before())}
        ]

    valid =
      base ++
        [
          {rebind, [proposal],
           generation_snapshot(rebind_plan.(proposal), amended_gate, @bad, context_after())}
        ]

    assert :ok == generation_history(valid)

    # The split this transaction exists to make fatal. The middle revision moves
    # the artifact and rebinds it in the amended gate together, which is
    # everything the artifact walk asks for, and leaves the generation record for
    # the next revision. The artifact walk is satisfied at every revision here;
    # only the generation coupling refuses it, and no descendant heals it.
    undeclared_gate =
      mutated_artifact_gate() <> "\n<a id=\"amendment-1\"></a>\n## Amendment 1\n"

    for {split_gate, expected} <- [
          {amended_gate, ~r/must record its accepted gate generations/},
          {undeclared_gate, ~r/no longer matches its Closure record/}
        ] do
      split =
        opening ++
          [
            {"closed", [origin],
             generation_snapshot(closed, original_gate, @good, context_before())},
            {"split", ["closed"],
             generation_snapshot(closed, split_gate, @bad, context_before())},
            {proposal, ["split"],
             generation_snapshot(proposal_plan, amended_gate, @bad, context_before())}
          ]

      assert :ok == History.artifact_history({proposal, split})

      assert_raise Invalid, expected, fn -> generation_history(split) end
    end

    # A rebind records who accepted the proposal it descends from and nothing
    # else; binding another revision would let one review stand for other bytes.
    wrong_parent =
      base ++
        [
          {rebind, [proposal],
           generation_snapshot(rebind_plan.(origin), amended_gate, @bad, context_after())}
        ]

    assert_raise Invalid, ~r/must bind its sole proposal parent/, fn ->
      generation_history(wrong_parent)
    end

    # An acceptance is a record written after reviewing this proposal, so its
    # disposition is absent at the proposal and appears exactly once at the
    # rebind.
    reused =
      base ++
        [
          {rebind, [proposal],
           generation_snapshot(rebind_plan.(proposal), amended_gate, @bad, context_before())}
        ]

    assert_raise Invalid, ~r/must first appear exactly once at rebind/, fn ->
      generation_history(reused)
    end

    stale_disposition =
      opening ++
        [
          {"closed", [origin],
           generation_snapshot(closed, original_gate, @good, context_after())},
          {proposal, ["closed"],
           generation_snapshot(proposal_plan, amended_gate, @bad, context_after())},
          {rebind, [proposal],
           generation_snapshot(rebind_plan.(proposal), amended_gate, @bad, context_after())}
        ]

    assert_raise Invalid, ~r/already existed at proposal/, fn ->
      generation_history(stale_disposition)
    end

    # A gate generation reopens no lifecycle state.
    reopened =
      base ++
        [
          {rebind, [proposal],
           generation_snapshot(
             rebind_plan.(proposal),
             amended_gate,
             @bad,
             context_after(),
             "In progress"
           )}
        ]

    assert_raise Invalid, ~r/gate generation rebind.*changed lifecycle state/, fn ->
      generation_history(reopened)
    end
  end

  test "recorded gate generations are append-only across reachable history" do
    original_gate = one_artifact_gate()
    amended_gate = Fixture.amended_gate(1, mutated_artifact_gate())
    second_gate = Fixture.amended_gate(2, mutated_artifact_gate())

    closed = Fixture.plan(governed: true, closed: true, gate: original_gate)

    generations = fn rows ->
      Fixture.plan(governed: true, closed: true, gate: original_gate, generations: rows)
    end

    proposed = Fixture.proposed_generation(1, amended_gate)
    origin = sha("a")
    proposal = sha("1")
    rebind = sha("2")
    accepted = Fixture.accepted_generation(1, proposal, amended_gate, @disposition)

    base = [
      {"root", [], %{}},
      {origin, ["root"],
       generation_snapshot(Fixture.plan(), original_gate, @good, context_before(), "Open")},
      {"closed", [origin], generation_snapshot(closed, original_gate, @good, context_before())},
      {proposal, ["closed"],
       generation_snapshot(generations.([proposed]), amended_gate, @bad, context_before())},
      {rebind, [proposal],
       generation_snapshot(generations.([accepted]), amended_gate, @bad, context_after())}
    ]

    assert :ok == generation_history(base)

    # An accepted row is immutable. The transaction shape refuses a restatement
    # or a deletion; the merge below proves the anchor refuses it independently.
    rewritten = String.replace(accepted, "Maintainer |", "Delegate: Reviewer |", global: false)

    for {plan, expected} <- [
          {generations.([rewritten]),
           ~r/completes exactly the proposed row|completed gate generations/},
          {closed, ~r/must record its accepted gate generations/}
        ] do
      assert_raise Invalid, expected, fn ->
        generation_history(
          base ++
            [
              {sha("3"), [rebind], generation_snapshot(plan, amended_gate, @bad, context_after())}
            ]
        )
      end
    end

    # Two generations cannot be in flight at once, and a generation never
    # arrives already accepted: it is proposed, reviewed, then recorded.
    assert_raise Invalid, ~r/only one gate generation may await/, fn ->
      generation_history(
        base ++
          [
            {sha("3"), [proposal],
             generation_snapshot(
               generations.([proposed, Fixture.proposed_generation(2, second_gate)]),
               second_gate,
               @bad,
               context_before()
             )}
          ]
      )
    end

    assert_raise Invalid, ~r/appends exactly one proposed row/, fn ->
      generation_history(
        base ++
          [
            {sha("3"), [rebind],
             generation_snapshot(
               generations.([
                 accepted,
                 Fixture.accepted_generation(2, sha("3"), second_gate, @disposition)
               ]),
               second_gate,
               @bad,
               context_after()
             )}
          ]
      )
    end

    # Two branches accepting the same generation against different candidates is
    # a conflict rather than a merge: the gate bytes agree, so only the record
    # differs, and neither record supersedes the other.
    sibling_proposal = sha("4")
    sibling_rebind = sha("5")
    sibling = Fixture.accepted_generation(1, sibling_proposal, amended_gate, @disposition)

    merged =
      base ++
        [
          {sibling_proposal, ["closed"],
           generation_snapshot(generations.([proposed]), amended_gate, @bad, context_before())},
          {sibling_rebind, [sibling_proposal],
           generation_snapshot(generations.([sibling]), amended_gate, @bad, context_after())},
          {sha("6"), [rebind, sibling_rebind],
           generation_snapshot(generations.([accepted]), amended_gate, @bad, context_after())}
        ]

    assert_raise Invalid, ~r/conflicting completed gate generations/, fn ->
      generation_history(merged)
    end
  end

  # Concept: the amendment transaction reduced to the three revisions the
  # interposition cases below vary.
  #
  # Technical depth: the plan binds the original gate in both governance rows
  # throughout, because the additive transaction exists precisely so a Closed
  # milestone need not rebind them. Only the gate file, the artifact it binds,
  # and the generations table move.
  defp amendment_fixtures do
    original_gate = one_artifact_gate()
    amended_gate = Fixture.amended_gate(1, mutated_artifact_gate())

    %{
      original_gate: original_gate,
      amended_gate: amended_gate,
      closed: Fixture.plan(governed: true, closed: true, gate: original_gate),
      proposal_plan:
        Fixture.plan(
          governed: true,
          closed: true,
          gate: original_gate,
          generations: [Fixture.proposed_generation(1, amended_gate)]
        ),
      rebind_plan: fn candidate ->
        Fixture.plan(
          governed: true,
          closed: true,
          gate: original_gate,
          generations: [Fixture.accepted_generation(1, candidate, amended_gate, @disposition)]
        )
      end
    }
  end

  defp amendment_base(fixtures, proposal) do
    origin = sha("a")

    [
      {"root", [], %{}},
      {origin, ["root"],
       generation_snapshot(
         Fixture.plan(),
         fixtures.original_gate,
         @good,
         context_before(),
         "Open"
       )},
      {"closed", [origin],
       generation_snapshot(fixtures.closed, fixtures.original_gate, @good, context_before())},
      {proposal, ["closed"],
       generation_snapshot(fixtures.proposal_plan, fixtures.amended_gate, @bad, context_before())}
    ]
  end

  defp carries_proposal(fixtures, revision, parents, plan \\ nil) do
    {revision, parents,
     generation_snapshot(
       plan || fixtures.proposal_plan,
       fixtures.amended_gate,
       @bad,
       context_before()
     )}
  end

  defp amendment_rebind(fixtures, revision, parents, candidate) do
    {revision, parents,
     generation_snapshot(
       fixtures.rebind_plan.(candidate),
       fixtures.amended_gate,
       @bad,
       context_after()
     )}
  end

  @interposed ~r/must bind the one-parent revision that first proposed the generation/

  # Concept: the substitution the atomic-transaction case above cannot see. A
  # rebind that binds its sole parent is not yet binding the revision anyone
  # reviewed.
  #
  # Technical depth: every revision in `A -> P -> R` is individually well
  # formed. `A` appends the proposal; `P` changes no governed field, so the
  # change-set walk admits it unconditionally; `R` completes the row and binds
  # its sole parent `P`. Only requiring the bound parent to be the revision where
  # the pending row came into existence separates the reviewed `A` from the
  # unreviewed `P`. Each case first asserts the direct transaction passes, so a
  # failure means the interposition was refused rather than the fixture drifting.
  test "a gate generation rebind cannot bind an interposed revision that changes nothing" do
    fixtures = amendment_fixtures()
    proposal = sha("1")
    interposed = sha("2")
    rebind = sha("3")
    base = amendment_base(fixtures, proposal)

    assert :ok ==
             generation_history(
               base ++ [amendment_rebind(fixtures, rebind, [proposal], proposal)]
             )

    empty =
      base ++
        [
          carries_proposal(fixtures, interposed, [proposal]),
          amendment_rebind(fixtures, rebind, [interposed], interposed)
        ]

    assert_raise Invalid, @interposed, fn -> generation_history(empty) end
  end

  test "a gate generation rebind cannot bind an interposed revision carrying unrelated bytes" do
    fixtures = amendment_fixtures()
    proposal = sha("1")
    interposed = sha("2")
    rebind = sha("3")
    base = amendment_base(fixtures, proposal)

    assert :ok ==
             generation_history(
               base ++ [amendment_rebind(fixtures, rebind, [proposal], proposal)]
             )

    # Ungoverned prose inside the plan itself, plus a file no walk anchors: `P`
    # is an ordinary commit someone could land between review and rebind, and it
    # still changes no governed field.
    restated =
      String.replace(
        fixtures.proposal_plan,
        "One direct workstream.",
        "One direct workstream, restated."
      )

    refute restated == fixtures.proposal_plan

    {^interposed, parents, files} = carries_proposal(fixtures, interposed, [proposal], restated)

    unrelated =
      base ++
        [
          {interposed, parents, Map.put(files, "lib/unrelated.ex", @other)},
          amendment_rebind(fixtures, rebind, [interposed], interposed)
        ]

    assert_raise Invalid, @interposed, fn -> generation_history(unrelated) end
  end

  test "a gate generation rebind cannot bind a merge or a revision behind one" do
    fixtures = amendment_fixtures()
    proposal = sha("1")
    merge = sha("2")
    rebind = sha("3")
    side = sha("4")
    behind = sha("5")

    sibling =
      {side, ["closed"],
       generation_snapshot(fixtures.closed, fixtures.original_gate, @good, context_before())}

    base = amendment_base(fixtures, proposal)

    # The merge's own tree is the proposal's tree, so it changes no governed
    # field and the walk admits it. Binding it would let a merge — which no
    # single revision is accountable for — stand in for the reviewed one.
    merged = base ++ [sibling, carries_proposal(fixtures, merge, [proposal, side])]

    assert_raise Invalid, @interposed, fn ->
      generation_history(merged ++ [amendment_rebind(fixtures, rebind, [merge], merge)])
    end

    # A merge further back is the same substitution with one more hop.
    assert_raise Invalid, @interposed, fn ->
      generation_history(
        merged ++
          [
            carries_proposal(fixtures, behind, [merge]),
            amendment_rebind(fixtures, rebind, [behind], behind)
          ]
      )
    end

    # A rebind that is itself a merge is refused by the one-parent rule the
    # strict transaction already carries, so no descendant can launder one.
    assert_raise Invalid, ~r/require one direct parent/, fn ->
      generation_history(
        base ++ [sibling, amendment_rebind(fixtures, rebind, [proposal, side], proposal)]
      )
    end
  end

  @m2_adrs [
    {"docs/adr/0009-tool-executor-and-grant-contracts.md", "ADR 0009"},
    {"docs/adr/0010-provider-continuation-and-context-staging.md", "ADR 0010"},
    {"docs/adr/0011-session-input-algebra-and-streaming.md", "ADR 0011"}
  ]

  # Concept: the register as it stood at one revision, with the milestone rows a
  # case needs.
  #
  # Technical depth: only the Milestone Register block matters here. The status
  # capsule is `Status.validate/2`'s concern, and driving that would require plan
  # and gate documents this case does not need, so the fixture keeps the index
  # and the ADR pairs and nothing else.
  defp prerequisite_index(rows) do
    Fixture.documents()
    |> Map.fetch!(@index_path)
    |> String.replace(
      Fixture.blocked_row(),
      Enum.map_join(rows, "\n", fn {name, state} ->
        "| `#{name}` | #{state} | [concept](#{name}.md) | " <>
          "[technical depth](#{name}-technical.md) | [gate](#{name}-gate.md) |"
      end)
    )
  end

  defp prerequisite_adr(path, status) do
    technical =
      path
      |> String.replace_prefix("docs/adr/", "")
      |> String.replace_suffix(".md", "-technical.md")

    record =
      case status do
        "Proposed" ->
          "| Acceptance | — | — | — |"

        "Accepted" ->
          "| Acceptance | Maintainer | [disposition](../vision.md#concept) | " <>
            "candidate `#{sha("f")}`; concept `sha256:#{Markdown.digest("c")}`; " <>
            "technical `sha256:#{Markdown.digest("t")}` |"
      end

    """
    # #{path}

    <a id="concept"></a>
    ## Concept

    Technical depth: [Decision details](#{technical}#technical-depth)

    - **Status:** #{status}
    - **Date:** 2026-08-23
    - **Decision owner:** Maintainer

    ## Governance Record

    | Decision | Authority | Authority evidence | Bound bytes |
    | --- | --- | --- | --- |
    #{record}

    ## Context

    Concrete decision context for #{path}.

    ## Decision

    Choose the bounded decision.
    """
  end

  # Concept: the plan companion that declares the prerequisites, since the guard
  # reads each milestone's own declaration rather than a table.
  defp declaring_technical_plan do
    String.replace(
      Fixture.technical_plan(),
      "Prerequisites are accepted before plan acceptance.",
      "Prerequisites are accepted before plan acceptance.\n\n" <>
        Enum.map_join(@m2_adrs, "\n", fn {_path, name} ->
          "- **#{name}** must carry recorded acceptance."
        end)
    )
  end

  defp prerequisite_files(rows, status) do
    base = %{
      @index_path => prerequisite_index(rows),
      "docs/plans/M2-technical.md" => declaring_technical_plan()
    }

    Enum.reduce(@m2_adrs, base, fn {path, _name}, acc ->
      acc
      |> Map.put(path, prerequisite_adr(path, status))
      |> Map.put(
        String.replace_suffix(path, ".md", "-technical.md"),
        "# Technical depth\n\n<a id=\"technical-depth\"></a>\n## Technical depth\n\n" <>
          "Concept: [Decision](#{Path.basename(path)}#concept)\n"
      )
    end)
  end

  defp prerequisite_history(snapshots) do
    {head, _parents, files} = List.last(snapshots)
    History.governance_history(files, {head, snapshots}, generation_resolver(snapshots))
  end

  @m3_adrs [
    {"docs/adr/0025-resource-packs-and-skill-admission.md", "ADR 0025"},
    {"docs/adr/0027-provider-permit-retirement.md", "ADR 0027"}
  ]

  defp m3_prerequisite_files(state, proposed, format) do
    declarations =
      Enum.map_join(@m3_adrs, "\n", fn {path, name} ->
        label =
          if format == :bold,
            do: "**#{name}**",
            else: "[#{name}](../adr/#{Path.basename(path)}#concept)"

        "| #{label} | Before M3 acceptance |"
      end)

    technical =
      Fixture.technical_plan()
      |> String.replace("M0", "M3")
      |> String.replace(
        "Prerequisites are accepted before plan acceptance.",
        "Only two new ADRs are M3 prerequisites:\n\n" <>
          "| Decision | Acceptance point |\n| --- | --- |\n" <>
          declarations <>
          "\n\nADRs 0023, 0024, 0026 and 0028 belong to M4. ADR 0026 is not an M3 prerequisite."
      )

    Enum.reduce(
      @m3_adrs,
      %{
        @index_path => prerequisite_index([{"M3", state}]),
        "docs/plans/M3-gate.md" => Fixture.gate(),
        "docs/plans/M3-technical.md" => technical
      },
      fn {path, name}, files ->
        status = if name == proposed, do: "Proposed", else: "Accepted"

        files
        |> Map.put(path, prerequisite_adr(path, status))
        |> Map.put(
          String.replace_suffix(path, ".md", "-technical.md"),
          "## Technical depth\n\nConcept: [Decision](#{Path.basename(path)}#concept)\n"
        )
      end
    )
  end

  test "M3 history enforces each bold or linked prerequisite in every accepted lifecycle state" do
    for format <- [:bold, :link], state <- ["Accepted", "In progress", "In review", "Closed"] do
      settled = m3_prerequisite_files(state, nil, format)
      assert :ok == prerequisite_history([{sha("a"), [], settled}])

      for {_path, name} <- @m3_adrs do
        outstanding = m3_prerequisite_files(state, name, format)

        assert_raise Invalid, ~r/`M3` is #{state} while #{name} is not accepted/, fn ->
          prerequisite_history([{sha("a"), [], outstanding}])
        end
      end
    end
  end

  test "M3 history refuses either missing declared ADR and allows unsettled Open planning" do
    for format <- [:bold, :link], {path, name} <- @m3_adrs do
      open = m3_prerequisite_files("Open", name, format)
      assert :ok == prerequisite_history([{sha("a"), [], open}])

      assert_raise Invalid, ~r/`M3` names #{name} as a prerequisite but no such decision/, fn ->
        prerequisite_history([{sha("a"), [], Map.delete(open, path)}])
      end
    end
  end

  test "M3 later ADR acceptance cannot launder an earlier transition or completed Open acceptance" do
    for format <- [:bold, :link], {_path, name} <- @m3_adrs, state <- ["Accepted", "Open"] do
      outstanding = m3_prerequisite_files(state, name, format)
      settled = m3_prerequisite_files(state, nil, format)

      {outstanding, settled, trigger} =
        if state == "Open" do
          plan = Fixture.plan(governed: true) |> String.replace("M0", "M3")

          {Map.put(outstanding, "docs/plans/M3.md", plan),
           Map.put(settled, "docs/plans/M3.md", plan), "carries a complete Acceptance row"}
        else
          {outstanding, settled, "is Accepted"}
        end

      assert_raise Invalid, ~r/#{sha("a")}: `M3` #{trigger} while #{name}/, fn ->
        prerequisite_history([
          {sha("a"), [], outstanding},
          {sha("b"), [sha("a")], settled}
        ])
      end
    end
  end

  @override_anchor "override-disposition-m3-test-2026-09-10"

  defp m3_override_files(state, context) do
    m3_prerequisite_files(state, nil, :link)
    |> Map.update!("docs/plans/M3-technical.md", fn technical ->
      technical <>
        "\nOverride authority: [override disposition]" <>
        "(../developer/agent-context-map.md##{@override_anchor}).\n"
    end)
    |> Map.put(@context_path, context)
  end

  defp first_override_citation_files do
    plan = Fixture.plan(governed: true) |> String.replace("M0", "M3")
    before = "# Context map\n"
    recorded = before <> "\n<a id=\"#{@override_anchor}\"></a>\nReviewed override.\n"

    original =
      m3_prerequisite_files("Accepted", nil, :link)
      |> Map.put("docs/plans/M3.md", plan)
      |> Map.put(@context_path, before)

    standalone = Map.put(original, @context_path, recorded)

    cited =
      Map.update!(standalone, "docs/plans/M3.md", fn text ->
        String.replace(
          text,
          "One direct workstream.",
          "One direct workstream. [Override](../developer/agent-context-map.md##{@override_anchor})."
        )
      end)

    {original, standalone, cited}
  end

  test "an already Accepted milestone may first cite a prior standalone override" do
    {original, standalone, cited} = first_override_citation_files()

    assert :ok ==
             prerequisite_history([
               {sha("a"), [], original},
               {sha("b"), [sha("a")], standalone},
               {sha("c"), [sha("b")], cited}
             ])
  end

  test "a first Accepted override citation cannot borrow or create its approval record" do
    {original, standalone, cited} = first_override_citation_files()

    assert_raise Invalid, ~r/first added by that transition/, fn ->
      prerequisite_history([{sha("a"), [], original}, {sha("c"), [sha("a")], cited}])
    end

    duplicate = Map.update!(standalone, @context_path, &(&1 <> &1))

    assert_raise Invalid, ~r/parent .* carries 2 anchors; one reviewed standalone record/, fn ->
      prerequisite_history([{sha("a"), [], duplicate}, {sha("c"), [sha("a")], cited}])
    end

    initial = Map.put(standalone, @index_path, prerequisite_index([{"M3", "Open"}]))

    assert_raise Invalid, ~r/no parent carries both the prior citation/, fn ->
      prerequisite_history([{sha("a"), [], initial}, {sha("c"), [sha("a")], cited}])
    end

    assert_raise Invalid, ~r/no parent carries both the prior citation/, fn ->
      prerequisite_history([
        {sha("a"), [], original},
        {sha("b"), [sha("a")], standalone},
        {sha("c"), [sha("a"), sha("b")], cited}
      ])
    end

    changed_acceptance =
      Map.update!(cited, "docs/plans/M3.md", fn text ->
        String.replace(text, "| Acceptance | Maintainer |", "| Acceptance | Delegate: Reviewer |")
      end)

    assert_raise Invalid, ~r/completed Acceptance/, fn ->
      prerequisite_history([
        {sha("a"), [], original},
        {sha("b"), [sha("a")], standalone},
        {sha("c"), [sha("b")], changed_acceptance}
      ])
    end

    assert_raise Invalid, ~r/no parent carries both the prior citation/, fn ->
      prerequisite_history([
        {sha("a"), [], Map.delete(standalone, "docs/plans/M3.md")},
        {sha("c"), [sha("a")],
         Map.delete(cited, "docs/plans/M3.md")
         |> Map.update!(
           "docs/plans/M3-technical.md",
           &(&1 <>
               "\n[Override](../developer/agent-context-map.md##{@override_anchor}).\n")
         )}
      ])
    end
  end

  test "an M3 override disposition anchor predates acceptance" do
    before = "# Context map\n"

    recorded =
      before <>
        "\n<a id=\"#{@override_anchor}\"></a>\n" <>
        "### Reviewed maintainer override\n\nExact instruction and bounded scope.\n"

    open = m3_override_files("Open", recorded)
    accepted = m3_override_files("Accepted", recorded)

    assert :ok ==
             prerequisite_history([
               {sha("a"), [], open},
               {sha("b"), [sha("a")], accepted}
             ])

    unrelated = m3_prerequisite_files("Open", nil, :link) |> Map.put(@context_path, before)

    assert :ok ==
             prerequisite_history([
               {sha("a"), [], unrelated},
               {sha("b"), [], open},
               {sha("c"), [sha("a"), sha("b")], accepted}
             ])

    cited_without_record = m3_override_files("Open", before)
    unrelated_with_record = Map.put(unrelated, @context_path, recorded)

    assert_raise Invalid, ~r/first added by that transition/, fn ->
      prerequisite_history([
        {sha("a"), [], cited_without_record},
        {sha("b"), [], unrelated_with_record},
        {sha("c"), [sha("a"), sha("b")], accepted}
      ])
    end

    missing = m3_override_files("Accepted", before)

    assert_raise Invalid, ~r/cites missing override disposition/, fn ->
      prerequisite_history([{sha("a"), [], missing}])
    end

    duplicate = m3_override_files("Accepted", recorded <> recorded)

    assert_raise Invalid, ~r/cites duplicate override disposition/, fn ->
      prerequisite_history([
        {sha("a"), [], m3_override_files("Open", recorded)},
        {sha("b"), [sha("a")], duplicate}
      ])
    end

    added_by_transition = m3_override_files("Accepted", recorded)

    assert_raise Invalid, ~r/first added by that transition/, fn ->
      prerequisite_history([
        {sha("a"), [], m3_override_files("Open", before)},
        {sha("b"), [sha("a")], added_by_transition}
      ])
    end

    open_without_record = m3_override_files("Open", before)
    committed = [{sha("a"), [], open_without_record}]

    assert_raise Invalid, ~r/working tree.*first added by that transition/s, fn ->
      History.governance_history(
        added_by_transition,
        {sha("a"), committed},
        generation_resolver(committed)
      )
    end
  end

  test "a Closed milestone cannot conceal an outstanding prerequisite behind an Open successor" do
    # The live capsule only ever describes the milestone a reader would call
    # active, so once `M2` is Closed beside an Open successor nothing asks again
    # what `M2`'s prerequisites were. History is where that stays visible.
    concealed = prerequisite_files([{"M2", "Closed"}, {"M9", "Open"}], "Proposed")

    assert_raise Invalid, ~r/`M2` is Closed while ADR 0009 is not accepted/, fn ->
      prerequisite_history([{sha("a"), [], concealed}])
    end

    settled = prerequisite_files([{"M2", "Closed"}, {"M9", "Open"}], "Accepted")
    assert :ok == prerequisite_history([{sha("a"), [], settled}])
  end

  test "accepting a prerequisite later cannot legalise an earlier acceptance" do
    # Every revision is judged against the ADR statuses it carried, so a decision
    # taken afterwards repairs nothing: the revision that recorded the state is
    # still walked and still fails.
    outstanding = prerequisite_files([{"M2", "Accepted"}], "Proposed")
    settled = prerequisite_files([{"M2", "Accepted"}], "Accepted")

    assert_raise Invalid, ~r/#{sha("a")}: `M2` is Accepted while ADR 0009/, fn ->
      prerequisite_history([
        {sha("a"), [], outstanding},
        {sha("b"), [sha("a")], settled}
      ])
    end

    assert :ok ==
             prerequisite_history([
               {sha("a"), [], settled},
               {sha("b"), [sha("a")], settled}
             ])
  end

  @m2_plan "docs/plans/M2.md"

  # Concept: a plan whose Acceptance row is complete while its lifecycle row is
  # still Open.
  #
  # Technical depth: only the Governance Records table matters to the trigger, so
  # the fixture carries that and the preamble the reader needs, with a candidate
  # that never has to resolve because the guard reads the row's completeness and
  # not its binding.
  defp accepted_plan_pair do
    %{
      @m2_plan => Fixture.plan(governed: true),
      "docs/plans/M2-technical.md" => declaring_technical_plan(),
      "docs/plans/M2-gate.md" => Fixture.gate()
    }
  end

  defp current_files!(root) do
    root
    |> git!(["ls-files"])
    |> String.split("\n", trim: true)
    |> Map.new(fn path -> {path, File.read!(Path.join(root, path))} end)
  end

  defp git_resolver(root) do
    fn revision, path ->
      case System.cmd("git", ["-C", root, "show", "#{revision}:#{path}"], stderr_to_stdout: true) do
        {content, 0} -> content
        _other -> nil
      end
    end
  end

  defp git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end

  defp git_commit!(root, message) do
    git!(root, ["add", "-A"])
    git!(root, ["-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", message])
    root |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp write_files!(root, files) do
    Enum.each(files, fn {path, text} ->
      absolute = Path.join(root, path)
      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, text)
    end)
  end

  defp temporary_repository! do
    root = Path.join(System.tmp_dir!(), "prereq-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "-q", "-b", "main"])
    git!(root, ["config", "user.email", "fixture@example.invalid"])
    git!(root, ["config", "user.name", "Fixture"])
    root
  end

  test "the real history reader carries the register and refuses a laundered prerequisite" do
    # The guard reads the canonical register at every revision, so the reader has
    # to deliver it. It did not: the plans index was excluded from historical
    # snapshots, and an absent index made the check pass over the whole of real
    # history while its unit cases went on passing against injected maps.
    root = temporary_repository!()

    write_files!(root, prerequisite_files([{"M2", "Open"}], "Proposed"))
    seed = git_commit!(root, "seed")

    {head, snapshots} = Git.history_reader(root).()

    assert head == seed
    assert Enum.all?(snapshots, fn {_r, _p, files} -> Map.has_key?(files, @index_path) end)

    # A milestone reaching Accepted with its prerequisites outstanding is refused
    # at the revision that recorded it, read back out of real Git.
    write_files!(root, prerequisite_files([{"M2", "Accepted"}], "Proposed"))
    laundered = git_commit!(root, "accept M2 early")

    write_files!(root, prerequisite_files([{"M2", "Accepted"}], "Accepted"))
    git_commit!(root, "accept the prerequisites afterwards")

    {head, snapshots} = Git.history_reader(root).()
    current = current_files!(root)

    assert_raise Invalid, ~r/#{laundered}: `M2` is Accepted while ADR 0009/, fn ->
      History.governance_history(current, {head, snapshots}, git_resolver(root))
    end

    assert head == elem(List.last(snapshots), 0)
  end

  test "a completed Acceptance row is judged even while the register still says Open" do
    # The evasion the lifecycle trigger alone misses: complete the Acceptance row
    # while the row beside it still reads Open, let the prerequisites be accepted
    # afterwards, then move the state. Every inspected state passes. The row is
    # therefore a trigger in its own right.
    root = temporary_repository!()

    open_outstanding = prerequisite_files([{"M2", "Open"}], "Proposed")
    write_files!(root, open_outstanding)
    git_commit!(root, "open M2")

    write_files!(root, Map.merge(open_outstanding, accepted_plan_pair()))
    early = git_commit!(root, "complete the Acceptance row while still Open")

    write_files!(
      root,
      Map.merge(prerequisite_files([{"M2", "Open"}], "Accepted"), accepted_plan_pair())
    )

    git_commit!(root, "accept the prerequisites afterwards")

    {head, snapshots} = Git.history_reader(root).()

    assert_raise Invalid,
                 ~r/#{early}: `M2` carries a complete Acceptance row while ADR 0009/,
                 fn ->
                   History.governance_history(
                     current_files!(root),
                     {head, snapshots},
                     git_resolver(root)
                   )
                 end
  end

  test "an unavailable walk is unavailable evidence in both history checks" do
    # The governance walk always said so; the artifact walk returned :ok. Today
    # ordering hides that — the governance raise fires first — so the disagreement
    # was one reordered call away from making every bound artifact at every
    # revision a clean pass.
    assert_raise Invalid, ~r/governance history is unavailable/, fn ->
      History.governance_history(%{}, nil, nil)
    end

    assert_raise Invalid, ~r/artifact history is unavailable/, fn ->
      History.artifact_history(nil)
    end
  end

  test "a declared Bound Artifacts table that binds nothing is refused" do
    # Declaring the section and binding no row reads like protection and is none.
    header = artifact_gate()

    assert_raise Invalid, ~r/binds no artifact/, fn ->
      Plan.bound_artifacts(header, @gate_path)
    end

    assert [{_digest, @runner}] = Plan.bound_artifacts(one_artifact_gate(), @gate_path)
  end
end
