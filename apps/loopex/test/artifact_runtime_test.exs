Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ArtifactRuntimeTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.ArtifactStore
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Canonical

  defmodule RetainedArtifactStore do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def start do
      Agent.start_link(fn -> %{objects: %{}, uses: %{}} end)
    end

    def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
      digest = Canonical.digest_bytes(bytes)
      object = %{digest: digest, size: byte_size(bytes), locator: "runtime:" <> digest}

      artifact_use = %{
        canonicalization_version: Canonical.version(),
        object_digest: object.digest,
        object_size: object.size,
        object_locator: object.locator,
        media_type: media_type,
        role: role,
        metadata: metadata
      }

      use_digest = Canonical.digest(["artifact-use-v2", artifact_use])

      reference =
        Map.merge(object, %{
          media_type: media_type,
          role: role,
          use_canonicalization_version: Canonical.version(),
          use_digest: use_digest,
          use_locator: "use:" <> use_digest
        })

      Agent.update(pid, fn state ->
        %{
          state
          | objects: Map.put(state.objects, object.locator, {object, bytes}),
            uses: Map.put(state.uses, reference.use_locator, artifact_use)
        }
      end)

      {:ok, reference}
    end

    def put(_pid, _bytes, _use), do: {:error, :adapter_received_unnormalized_use}

    def fetch(pid, object) do
      case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
        {:ok, {_stored, bytes}} -> {:ok, bytes}
        :error -> {:error, :unknown_artifact}
      end
    end

    def stat(pid, locator) do
      case Agent.get(pid, &Map.fetch(&1.objects, locator)) do
        {:ok, {object, _bytes}} -> {:ok, object}
        :error -> {:error, :unknown_artifact}
      end
    end

    def describe(pid, use_locator) do
      case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
        {:ok, artifact_use} -> {:ok, artifact_use}
        :error -> {:error, :unknown_artifact_use}
      end
    end
  end

  test "one Core-retained use is the exact reference journaled published recovered and privately described" do
    {:ok, artifact_store} = RetainedArtifactStore.start()
    on_exit(fn -> if Process.alive?(artifact_store), do: Agent.stop(artifact_store) end)

    private_metadata = %{
      "media_type" => "text/plain",
      "role" => "tool_output",
      "session_id" => "private-session",
      "run_id" => "private-run",
      "operation_id" => "private-operation",
      "attempt" => 1,
      "tool_call_id" => "private-call"
    }

    assert {:ok, reference} =
             invoke_core(:put, [
               %{module: RetainedArtifactStore, handle: artifact_store},
               "one retained runtime artifact",
               private_metadata
             ])

    assert ArtifactStore.valid_reference?(reference)

    assert {:ok, private_use} =
             invoke_core(:describe, [
               %{module: RetainedArtifactStore, handle: artifact_store},
               reference
             ])

    assert private_use.metadata == Map.drop(private_metadata, ["media_type", "role"])

    fixture =
      Fixture.start(
        script: [
          %{
            text: "write it",
            calls: [
              %{id: "artifact-call", name: "write", arguments: %{"path" => "output.txt"}}
            ]
          },
          %{text: "done", calls: []}
        ],
        artifacts: %{"artifact-call" => [reference]}
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    {session_id, attachment, {:accepted, _command_id}} = Fixture.run(fixture, "make output")
    events = await_run_finished(attachment)

    public_reference = %{
      "digest" => reference.digest,
      "media_type" => reference.media_type,
      "size" => reference.size,
      "role" => reference.role,
      "locator" => reference.locator,
      "use_canonicalization_version" => reference.use_canonicalization_version,
      "use_digest" => reference.use_digest,
      "use_locator" => reference.use_locator
    }

    assert tool_finished = Enum.find(events, &(&1.kind == "tool.finished")), inspect(events)
    assert tool_finished["artifacts"] == [public_reference]

    all_records = Fixture.records(fixture, session_id)
    all_events = Fixture.events(fixture, session_id)

    receipt =
      all_records
      |> Enum.find(&(&1.payload[:kind] == "executor_receipt_committed"))
      |> get_in([:payload, "receipt"])

    assert receipt["artifacts"] == [public_reference]

    public_and_durable_planes = %{
      public_tool_event: tool_finished,
      durable_receipt_output: receipt["output"],
      durable_receipt_artifacts: receipt["artifacts"]
    }

    for {plane, projection} <- public_and_durable_planes,
        private <- Map.values(private_use.metadata) |> Enum.reject(&is_integer/1) do
      refute inspect(projection, limit: :infinity, printable_limit: :infinity) =~ private,
             "#{plane} exposed private artifact-use provenance #{inspect(private)}"
    end

    compact_bytes = Canonical.encode(public_reference)

    for private <- Map.values(private_use.metadata) |> Enum.reject(&is_integer/1) do
      refute compact_bytes =~ private
    end

    assert {:ok, recovered} =
             SessionState.recover(
               session_id,
               Fixture.records(fixture, session_id),
               Fixture.events(fixture, session_id)
             )

    [run_id] = recovered.conversation |> Map.keys()

    assert Enum.any?(SessionState.elements(recovered, run_id), fn
             %{kind: :tool_result, artifacts: [^reference]} -> true
             _element -> false
           end)

    assert {:ok, ^private_use} =
             invoke_core(:describe, [
               %{module: RetainedArtifactStore, handle: artifact_store},
               reference
             ])

    for private <- Map.values(private_use.metadata) |> Enum.reject(&is_integer/1) do
      refute inspect(all_records, limit: :infinity, printable_limit: :infinity) =~ private
      refute inspect(all_events, limit: :infinity, printable_limit: :infinity) =~ private
    end

    [first_request, second_request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)

    assert Enum.any?(
             first_request.messages,
             &(&1 == %{"role" => "user", "content" => "make output"})
           )

    assert Enum.any?(second_request.messages, fn
             %{"role" => "tool", "tool_call_id" => "artifact-call"} -> true
             _other -> false
           end),
           "the committed tool result did not reach the next model request"
  end

  test "a malformed or legacy artifact reference fails closed before durable or public success" do
    {reference, _private_use} = compact_reference()

    invalid = [
      Map.drop(reference, [:use_canonicalization_version, :use_digest, :use_locator]),
      %{reference | use_locator: "use:" <> String.duplicate("0", 64)},
      Map.put(reference, :metadata, %{"session_id" => "must-not-inline"})
    ]

    for {candidate, index} <- Enum.with_index(invalid, 1) do
      fixture =
        Fixture.start(
          script: [
            %{
              text: "write it",
              calls: [
                %{id: "artifact-call-#{index}", name: "write", arguments: %{"path" => "x"}}
              ]
            }
          ],
          artifacts: %{"artifact-call-#{index}" => [candidate]}
        )

      on_exit(fn -> Fixture.stop(fixture) end)

      {session_id, attachment, {:accepted, _command_id}} =
        Fixture.run(fixture, "reject malformed artifact #{index}")

      events = await_run_finished(attachment)
      tool = Enum.find(events, &(&1.kind == "tool.finished"))
      finished = Enum.find(events, &(&1.kind == "run.finished"))

      assert tool["outcome"] == "outcome_unknown"
      assert tool["artifacts"] == []
      assert finished["outcome"] == "outcome_unknown"

      records = Fixture.records(fixture, session_id)

      refute Enum.any?(records, &(&1.payload[:kind] == "executor_receipt_committed"))
      refute inspect(records) =~ "must-not-inline"
      refute inspect(events) =~ "must-not-inline"
    end
  end

  defp compact_reference do
    object = %{
      digest: String.duplicate("a", 64),
      size: 23,
      locator: "opaque-artifact-1"
    }

    private_use = %{
      canonicalization_version: Canonical.version(),
      object_digest: object.digest,
      object_size: object.size,
      object_locator: object.locator,
      media_type: "text/plain",
      role: "tool_output",
      metadata: %{
        "session_id" => "private-session",
        "run_id" => "private-run",
        "operation_id" => "private-operation",
        "attempt" => 1,
        "tool_call_id" => "private-call"
      }
    }

    use_digest = Canonical.digest(["artifact-use-v2", private_use])

    reference =
      Map.merge(object, %{
        media_type: private_use.media_type,
        role: private_use.role,
        use_canonicalization_version: private_use.canonicalization_version,
        use_digest: use_digest,
        use_locator: "use:" <> use_digest
      })

    {reference, private_use}
  end

  defp invoke_core(name, arguments) do
    if function_exported?(ArtifactStore, name, length(arguments)) do
      apply(ArtifactStore, name, arguments)
    else
      {:error, {:artifact_object_use_contract_missing, name, length(arguments)}}
    end
  end

  defp await_run_finished(attachment, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect(attachment, deadline, deadline_ms, [])
  end

  defp collect(attachment, deadline, deadline_ms, acc) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        acc = [event | acc]

        if event.kind == "run.finished",
          do: Enum.reverse(acc),
          else: collect(attachment, deadline, deadline_ms, acc)

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("""
          no run.finished within #{deadline_ms}ms.
          last read: #{inspect(other)}
          events observed: #{inspect(Enum.map(Enum.reverse(acc), & &1.kind))}
          """)
        else
          Process.sleep(10)
          collect(attachment, deadline, deadline_ms, acc)
        end
    end
  end
end
