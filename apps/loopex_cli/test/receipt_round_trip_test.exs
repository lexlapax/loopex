# Concept: the CLI composition retains an executor result that fits the public
# coding-tool capture budget through artifact and durable Store boundaries.
#
# Technical depth: this deterministic integration case lives outside the
# provider-backed coding-task selector. It drives the real Local executor and
# Store with only the model scripted, then reads both the next model request and
# the committed private receipt and the complete retained artifact.
Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/demonstration.ex", __DIR__)
Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexCli.ReceiptRoundTripTest do
  @moduledoc false

  # Not async: the setup erases the fixed `{AllowAll, :announced}` key in
  # `:persistent_term`, VM-global state that `cli_test` erases too; a
  # concurrent erase would make its announced-once assertions order-dependent.
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.CodingTools
  alias LoopexCli.Demonstration
  alias LoopexCli.Policy.AllowAll

  setup do
    :persistent_term.erase({AllowAll, :announced})
    :ok
  end

  test "an exact-limit read survives artifact retention and the receipt Store commit" do
    limit = CodingTools.limits().read_bytes
    exact = String.duplicate("x", limit)

    stack =
      stack(
        label: "exact-limit-read",
        script: [
          %{
            text: "reading the exact-limit file",
            calls: [Demonstration.call("c1", "read", %{"path" => "notes.md"})]
          },
          %{text: "done", calls: []}
        ]
      )

    File.write!(Path.join(stack.workspace, "notes.md"), exact)

    definitions =
      Enum.filter(
        CodingTools.definitions(),
        &(&1["tool_id"] in ~w(loopex.read loopex.write loopex.edit loopex.bash))
      )

    genesis = Loopex.ConfiguredGenesisFixture.genesis(definitions)

    assert {:ok, session_id} =
             Loopex.create_session(stack.runtime, %{}, command_id: "create-1", genesis: genesis)

    assert {:ok, attachment} = Loopex.attach(stack.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, _} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt-1",
               content: "read notes.md"
             })

    events = drain(attachment)
    finished = Enum.find(events, &(&1.kind == "run.finished"))

    assert finished["outcome"] == "completed", inspect(events)

    [_first, second] = Loopex.AgentLoopTestModel.dispatched(stack.model)
    tool_result = Enum.find(second.messages, &(&1["role"] == "tool"))
    assert tool_result["outcome"] == "completed"
    assert {:ok, encoded} = LoopexProtocol.Frame.encode(tool_result)
    assert IO.iodata_length(encoded) - 1 <= 2_048
    assert {:ok, projection} = LoopexProtocol.Frame.decode(tool_result["content"], 2_048)
    assert projection["excerpt_source"] == "receipt_content"
    assert projection["omitted"] == true

    receipt =
      stack.store
      |> Demonstration.records(session_id)
      |> Enum.find(&(&1.payload.kind == "executor_receipt_committed_v2"))
      |> get_in([:payload, "receipt"])

    [plain_reference] = receipt["artifacts"]

    reference =
      Map.new(plain_reference, fn {key, value} -> {String.to_existing_atom(key), value} end)

    assert reference.size == limit
    assert {:ok, ^exact} = Loopex.ArtifactStore.fetch(stack.artifacts, reference)
    assert projection["use_locator"] == reference.use_locator
    assert projection["object_digest"] == reference.digest
    assert projection["object_size"] == limit
    assert projection["source_byte_count"] == byte_size(receipt["output"])

    assert projection["excerpt"] ==
             binary_part(receipt["output"], 0, projection["excerpt_byte_count"])

    assert Enum.find(events, &(&1.kind == "tool.finished"))["artifacts"] == [plain_reference]

    assert :ok =
             Loopex.Store.validate_private_record(%{
               "receipt" => receipt,
               kind: "executor_receipt_candidate"
             })
  end

  defp stack(options) do
    {root, workspace} = Demonstration.repository(Keyword.fetch!(options, :label))
    state_root = Path.join(root, "state")

    artifact_root = Path.join(state_root, "artifacts")
    transfers = start_supervised!({Loopex.Store.Local.Transfers, root: artifact_root})

    artifacts = %{
      module: Loopex.Store.Local.Artifacts,
      handle: %{root: artifact_root, transfers: transfers}
    }

    stack =
      Demonstration.start(
        Keyword.merge(options, state_root: state_root, workspace: workspace, artifacts: artifacts)
      )

    on_exit(fn ->
      Demonstration.stop(stack)
      File.rm_rf(root)
    end)

    Map.merge(stack, %{root: root, state_root: state_root, artifacts: artifacts})
  end

  defp drain(attachment, acc \\ [], idle \\ 0) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} -> Enum.reverse([event | acc])
      {:ok, event} -> drain(attachment, [event | acc], 0)
      _absent when idle < 800 -> Process.sleep(10) && drain(attachment, acc, idle + 1)
      _absent -> Enum.reverse(acc)
    end
  end
end
