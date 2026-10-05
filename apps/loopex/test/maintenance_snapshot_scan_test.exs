defmodule Loopex.Runtime.MaintenanceSnapshotScanTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Session.MaintenanceView

  test "every cursor and page width preserves both owners' bounded historical view" do
    for kind <- ["run", "compact"] do
      first = view(kind)

      second = %{
        first
        | "episode_id" => <<1, 255>>,
          "owner" => %{"kind" => kind, "id" => <<2, 255>>}
      }

      {events, expected} =
        if kind == "run" do
          {
            [
              row("user.message_appended", %{"run_id" => first["owner"]["id"]}),
              change(first),
              row("run.started", %{"run_id" => first["owner"]["id"]}),
              change(nil),
              row("run.finished", %{"run_id" => first["owner"]["id"]}),
              row("user.message_appended", %{"run_id" => second["owner"]["id"]}),
              change(second),
              change(nil),
              row("run.finished", %{"run_id" => second["owner"]["id"]})
            ],
            [nil, nil, first, first, nil, nil, nil, second, nil, nil]
          }
        else
          {[change(first), change(nil), change(second), change(nil)],
           [nil, first, nil, second, nil]}
        end

      events = stamp(events)

      for width <- 1..length(events), anchor <- 0..length(events) do
        scan = scan(events, anchor, width)
        assert {:ok, result} = SessionState.finish_snapshot_scan(scan)
        assert result.tail == length(events)
        assert result.snapshot.event_sequence == anchor
        assert result.active_maintenance == Enum.at(expected, anchor)
        assert result.snapshot.active_maintenance == result.active_maintenance

        assert Map.keys(scan) |> Enum.sort() ==
                 Enum.sort(
                   ~w(session_id requested_anchor tail active_run open_interaction configuration checkpoint active_maintenance last_compact anchor_projection)a
                 )

        refute Map.has_key?(scan, :events)
        refute Map.has_key?(scan, :maintenance_episodes)

        assert {:ok, _} =
                 MaintenanceView.encode_wire(%{"active_maintenance" => result.active_maintenance})
      end

      assert {:ok, tail} = events |> scan(nil, 1) |> SessionState.finish_snapshot_scan()
      assert tail.active_maintenance == nil
      assert tail.snapshot.event_sequence == length(events)
    end
  end

  test "choice and text questions share their exact historical cursor with all snapshot views" do
    for {producer, kind, choices} <- [
          {"policy_defer", "choice", [%{"id" => <<255>>, "label" => "Proceed"}]},
          {"model_tool", "choice", [%{"id" => "choice-1", "label" => "Proceed"}]},
          {"model_tool", "text", []}
        ] do
      run_id = <<0, 255>>

      requested =
        row("interaction.requested", %{
          "interaction_id" => <<1, 255>>,
          "run_id" => run_id,
          "turn" => Integer.pow(10, 100),
          "tool_call_id" => <<2, 255>>,
          "prompt" => "Choose",
          "choices" => choices,
          "expires_at" => 18_446_744_073_709_551_615
        })

      requested =
        if producer == "model_tool",
          do: requested |> Map.put("producer", producer) |> Map.put("interaction_kind", kind),
          else: requested

      endings =
        if producer == "policy_defer" do
          [
            row("interaction.answer_admitted", %{
              "interaction_id" => <<1, 255>>,
              "run_id" => run_id,
              "turn" => Integer.pow(10, 100),
              "tool_call_id" => <<2, 255>>,
              "producer" => "policy_defer",
              "interaction_kind" => "choice",
              "status" => "answered",
              "answer_choice_id" => <<255>>,
              "answer_command_id" => <<3, 255>>
            }),
            row("interaction.resolved", %{"interaction_id" => <<1, 255>>})
          ]
        else
          [row("interaction.answered", %{"interaction_id" => <<1, 255>>})]
        end

      events =
        stamp(
          [row("user.message_appended", %{"run_id" => run_id}), requested] ++
            endings ++ [row("run.finished", %{"run_id" => run_id})]
        )

      for width <- 1..length(events), anchor <- 0..length(events) do
        {:ok, result} = events |> scan(anchor, width) |> SessionState.finish_snapshot_scan()
        snapshot = result.snapshot
        assert snapshot.configuration == result.configuration
        assert snapshot.open_interaction == result.open_interaction
        assert {:ok, wire} = LoopexProtocol.Session.Snapshot.encode_wire(snapshot)
        assert {:ok, ^snapshot} = LoopexProtocol.Session.Snapshot.decode_wire(wire)

        if anchor == 2 do
          assert snapshot.open_interaction["producer"] == producer
          assert snapshot.open_interaction["kind"] == kind
          assert snapshot.open_interaction["turn"] == Integer.pow(10, 100)
          assert snapshot.open_interaction["choices"] == choices
          assert snapshot.active_run_id == run_id
        else
          if producer == "policy_defer" and anchor == 3 do
            assert snapshot.open_interaction["status"] == "answered"
            assert snapshot.open_interaction["answer_choice_id"] == <<255>>
            assert snapshot.open_interaction["answer_command_id"] == <<3, 255>>
            assert snapshot.open_interaction["turn"] == Integer.pow(10, 100)
            assert map_size(snapshot.open_interaction) == 12
          else
            assert snapshot.open_interaction == nil
          end
        end
      end
    end
  end

  test "an anchor retains admission bounds while the public run advances" do
    admitted = view("run")

    events =
      stamp([
        row("user.message_appended", %{"run_id" => admitted["owner"]["id"]}),
        change(admitted),
        row("run.started", %{"run_id" => admitted["owner"]["id"]})
      ])

    assert {:ok, at_admission} = events |> scan(2, 1) |> SessionState.finish_snapshot_scan()
    assert at_admission.snapshot.active_run_phase == "admitted_unstaged"
    assert at_admission.active_maintenance == admitted
    assert at_admission.active_maintenance["bounds"]["run_deadline"] == nil
    assert {:ok, at_tail} = events |> scan(nil, 2) |> SessionState.finish_snapshot_scan()
    assert at_tail.snapshot.active_run_phase == "started"
    assert at_tail.active_maintenance == admitted
  end

  test "last compact retains one exact result at every cursor through successive episodes" do
    first = view("compact")

    second = %{
      first
      | "episode_id" => <<1, 255>>,
        "owner" => %{"kind" => "compact", "id" => <<2, 255>>}
    }

    first_completion = completion(first)
    second_completion = completion(second)

    events =
      stamp([
        change(first),
        change(nil),
        row("context.compaction_finished", first_completion),
        change(second),
        change(nil),
        row("context.compaction_finished", second_completion)
      ])

    expected = [
      nil,
      nil,
      nil,
      first_completion,
      first_completion,
      first_completion,
      second_completion
    ]

    for width <- 1..length(events), anchor <- 0..length(events) do
      assert {:ok, result} = events |> scan(anchor, width) |> SessionState.finish_snapshot_scan()
      assert result.last_compact == Enum.at(expected, anchor)
      assert result.snapshot.last_compact == result.last_compact
      assert result.snapshot.event_sequence == anchor
    end

    assert {:ok, result} = events |> scan(nil, 1) |> SessionState.finish_snapshot_scan()
    assert result.last_compact == second_completion
    assert result.active_maintenance == nil
  end

  test "malformed, duplicate or overlapping compact completions refuse" do
    compact = view("compact")
    run = view("run")
    complete = completion(compact)
    finish = row("context.compaction_finished", complete)
    {:ok, initial} = SessionState.start_snapshot_scan("session", nil, configuration())

    for poisoned <- [
          Map.put(complete, "private", "PRIVATE_LAST_COMPACT_CANARY"),
          put_in(complete, ["result", "source"], "PRIVATE_LAST_COMPACT_CANARY"),
          put_in(complete, ["result", "usage", "total_tokens"], 1),
          Map.put(complete, "episode_id", nil)
        ] do
      assert {:error, :invalid_public_compact_completion} =
               SessionState.scan_snapshot_page(
                 initial,
                 stamp([row("context.compaction_finished", poisoned)])
               )
    end

    for events <- [
          [finish, finish],
          [change(compact), finish],
          [row("user.message_appended", %{"run_id" => run["owner"]["id"]}), finish]
        ] do
      assert {:error, :invalid_public_compact_transition} =
               SessionState.scan_snapshot_page(initial, stamp(events))
    end
  end

  test "unbounded exact run quantities survive scanning without private additions" do
    admitted = view("run")
    integer = Integer.pow(10, 100) + 1
    admitted = put_in(admitted, ["bounds", "token_budget"], integer)
    admitted = %{admitted | "configuration_version" => integer}

    events =
      stamp([
        row("user.message_appended", %{"run_id" => admitted["owner"]["id"]}),
        change(admitted)
      ])

    assert {:ok, result} =
             events |> scan(nil, 1, configuration(integer)) |> SessionState.finish_snapshot_scan()

    assert result.active_maintenance["configuration_version"] == integer
    assert result.active_maintenance["bounds"]["token_budget"] == integer

    assert {:ok, wire} =
             MaintenanceView.encode_wire(%{"active_maintenance" => result.active_maintenance})

    assert wire["active_maintenance"]["bounds"]["token_budget"] == Integer.to_string(integer)
  end

  test "private fields and malformed native projections refuse before becoming snapshot data" do
    admitted = view("compact")

    for altered <- [
          Map.put(admitted, "instructions", "PRIVATE_SNAPSHOT_CANARY"),
          Map.put(admitted, "provider_mapping", %{"route" => self()}),
          Map.delete(admitted, "configuration_version"),
          %{admitted | "configuration_version" => 0},
          %{admitted | "reasoning" => "low"},
          %{admitted | "model" => <<255>>},
          put_in(admitted, ["bounds", "token_budget"], "32768"),
          put_in(admitted, ["bounds", "token_budget"], 32_769)
        ] do
      {:ok, scan} = SessionState.start_snapshot_scan("session", nil, configuration())

      assert {:error, :invalid_public_maintenance_view} =
               SessionState.scan_snapshot_page(scan, stamp([change(altered)]))
    end

    {:ok, scan} = SessionState.start_snapshot_scan("session", nil, configuration())
    poisoned = Map.put(change(admitted), "instructions", "PRIVATE_SNAPSHOT_CANARY")

    assert {:error, :invalid_public_maintenance_view} =
             SessionState.scan_snapshot_page(scan, stamp([poisoned]))
  end

  test "duplicate transitions and replacement of a live episode are impossible" do
    admitted = view("compact")
    changed_owner = put_in(admitted, ["owner", "id"], <<0, 1>>)
    changed_episode = %{admitted | "episode_id" => <<0, 2>>}

    for events <- [
          [change(nil)],
          [change(admitted), change(admitted)],
          [change(admitted), change(changed_owner)],
          [change(admitted), change(changed_episode)],
          [change(admitted), change(nil), change(nil)]
        ] do
      {:ok, scan} = SessionState.start_snapshot_scan("session", nil, configuration())

      assert {:error, :invalid_public_maintenance_transition} =
               SessionState.scan_snapshot_page(scan, stamp(events))
    end
  end

  test "run ownership and settled compaction are verified against the same public prefix" do
    run = view("run")
    compact = view("compact")
    prompt = row("user.message_appended", %{"run_id" => run["owner"]["id"]})
    finish = row("run.finished", %{"run_id" => run["owner"]["id"]})

    question =
      row("interaction.requested", %{
        "interaction_id" => "question",
        "run_id" => run["owner"]["id"],
        "turn" => 1,
        "tool_call_id" => "call",
        "prompt" => "Choose",
        "choices" => [%{"id" => "choice", "label" => "Proceed"}],
        "expires_at" => 60_000
      })

    for events <- [
          [change(run)],
          [prompt, change(put_in(run, ["owner", "id"], "another-run"))],
          [prompt, change(compact)],
          [prompt, change(run), finish],
          [prompt, change(run), question],
          [prompt, question, change(run)]
        ] do
      {:ok, scan} = SessionState.start_snapshot_scan("session", nil, configuration())

      assert {:error, :invalid_public_maintenance_transition} =
               SessionState.scan_snapshot_page(scan, stamp(events))
    end
  end

  defp scan(events, anchor, width, configuration \\ configuration()) do
    {:ok, initial} = SessionState.start_snapshot_scan("session", anchor, configuration)

    Enum.reduce(Enum.chunk_every(events, width), initial, fn page, scan ->
      assert {:ok, next} = SessionState.scan_snapshot_page(scan, page)
      next
    end)
  end

  defp configuration(version \\ 1) do
    path = Path.join(:code.priv_dir(:loopex_protocol), "vectors/configuration-projection.v1.json")
    vector = Enum.find(JSON.decode!(File.read!(path))["cases"], &(&1["name"] == "initial"))
    {:ok, configuration} = LoopexProtocol.Session.Configuration.decode_wire(vector["input"])
    %{configuration | "configuration_version" => version}
  end

  defp stamp(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      event |> Map.put(:event_id, "event-#{index}") |> Map.put(:event_sequence, index)
    end)
  end

  defp change(value), do: row("context.maintenance_changed", %{"active_maintenance" => value})
  defp row(kind, data), do: Map.put(data, :kind, kind)

  defp completion(view) do
    %{
      "episode_id" => view["episode_id"],
      "command_id" => view["owner"]["id"],
      "result" => %{
        "disposition" => "unchanged",
        "checkpoint_id" => nil,
        "failure" => nil,
        "cleanup" => "confirmed",
        "usage" => %{
          "attempts" => 0,
          "reported_tokens" => 0,
          "estimated_tokens" => 0,
          "total_tokens" => 0
        }
      }
    }
  end

  defp view(kind) do
    path = Path.join(:code.priv_dir(:loopex_protocol), "vectors/maintenance-view.v1.json")
    name = if kind == "run", do: "run-captured-null-deadline", else: "compact-captured-ceilings"
    vector = Enum.find(JSON.decode!(File.read!(path))["cases"], &(&1["name"] == name))
    {:ok, %{"active_maintenance" => native}} = MaintenanceView.decode_wire(vector["input"])
    native
  end
end
