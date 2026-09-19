defmodule LoopexComposition.ArtifactTransfersTest do
  @moduledoc false

  use ExUnit.Case, async: false

  # Concept: serving an artifact transfer is a capability a host asks for, and
  # the composition either wires it whole or does not claim it at all.
  #
  # Technical depth: this case lives beside the composition corpus rather than
  # in it because the M2 gate binds that corpus by digest; the gate's lock is on
  # those bytes, and new evidence is added next to them. A runtime handed an
  # artifact store but no transfer owner would answer every transfer with
  # `transfers_unavailable`, which is a worse answer than declaring the family
  # unsupported, so the owner and the runtime's store are one decision here and
  # both are observed through the composition's own caller-local seam rather
  # than by searching the virtual machine for processes.

  alias Loopex.Store.Local.{Artifacts, Transfers}

  defmodule Embedder do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  test "a composition that was not asked for transfers names the runtime no artifact store" do
    {state_root, workspace} = roots()
    observe()

    assert {:ok, runtime} = LoopexComposition.start(options(state_root, workspace))
    stop_later(runtime)

    assert_receive {:composed_runtime, launch}, 5_000
    refute Keyword.has_key?(launch, :artifact_store)
    refute_received {:composed_transfers, _owner}

    # The executor still spills, so an artifact outlives the run; what is absent
    # is only the runtime's ability to serve it over a transfer.
    assert File.dir?(Path.join(state_root, "artifacts"))
  end

  test "asking for transfers starts one owner, names it to the runtime, and stops it with the composition" do
    {state_root, workspace} = roots()
    observe()

    result =
      LoopexComposition.with_runtime(
        options(state_root, workspace) ++ [artifact_transfers: true],
        fn runtime ->
          assert is_map(runtime)
          :served
        end
      )

    assert result == :served

    assert_receive {:composed_transfers, owner}, 5_000
    assert_receive {:composed_runtime, launch}, 5_000

    store = Keyword.fetch!(launch, :artifact_store)

    # The runtime is handed the same placement the hands spill into, carrying
    # this composition's own owner rather than a global one.
    assert store.module == Artifacts
    assert store.handle.transfers == owner

    # The owner went with the composition. A descriptor that outlived its
    # composition would be a file this stack no longer accounts for.
    refute Process.alive?(owner)
  end

  test "the started owner is a live transfer owner, not merely a process" do
    {state_root, workspace} = roots()
    observe()

    assert {:ok, runtime} =
             LoopexComposition.start(options(state_root, workspace) ++ [artifact_transfers: true])

    stop_later(runtime)

    assert_receive {:composed_transfers, owner}, 5_000
    assert Transfers.live(owner) == []
    assert File.dir?(Path.join([state_root, "artifacts", "transfers"]))
  end

  test "anything but a boolean is refused rather than read as truthy" do
    {state_root, workspace} = roots()

    assert {:error, {:invalid_composition_option, :artifact_transfers}} =
             LoopexComposition.start(
               options(state_root, workspace) ++ [artifact_transfers: "true"]
             )

    assert {:error, {:invalid_composition_option, :artifact_transfers}} =
             LoopexComposition.start(options(state_root, workspace) ++ [artifact_transfers: nil])
  end

  defp options(state_root, workspace),
    do: [
      runtime_id: "artifact-transfers",
      state_root: state_root,
      workspace: workspace,
      policy: Embedder
    ]

  defp stop_later(runtime) do
    on_exit(fn ->
      try do
        Loopex.stop(runtime)
      catch
        :exit, _reason -> :ok
      end
    end)
  end

  # Concept: what this composition started, reported by the composition's own
  # caller-local observer rather than found by searching the virtual machine.
  #
  # Technical depth: the observer also reads the option list the runtime is
  # launched with, which is where `artifact_store` either is or is not. Asserting
  # on the launch rather than on a later refusal keeps the case about the wiring
  # decision instead of about one method's error name.
  defp observe do
    parent = self()

    observer = fn
      Transfers, :start_link, [transfer_options] ->
        result = apply(Transfers, :start_link, [transfer_options])
        with {:ok, owner} <- result, do: send(parent, {:composed_transfers, owner})
        result

      Loopex, :start_link, [launch] ->
        send(parent, {:composed_runtime, launch})
        apply(Loopex, :start_link, [launch])

      module, function, arguments ->
        apply(module, function, arguments)
    end

    Process.put(:"$loopex_composition_edge_observer", observer)
    on_exit(fn -> Process.delete(:"$loopex_composition_edge_observer") end)
  end

  defp roots do
    unique = System.unique_integer([:positive])
    state_root = Path.join(System.tmp_dir!(), "loopex-transfers-#{unique}")
    workspace = Path.join(System.tmp_dir!(), "loopex-transfers-ws-#{unique}")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(state_root)
      File.rm_rf(workspace)
    end)

    {state_root, workspace}
  end
end
