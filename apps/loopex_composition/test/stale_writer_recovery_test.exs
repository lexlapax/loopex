defmodule LoopexComposition.StaleWriterRecoveryTest do
  @moduledoc false

  use ExUnit.Case, async: false

  # Concept: breaking a store's writer marker is a request about the world, and
  # the world answers it. The composition forwards the request and decides
  # nothing.
  #
  # Technical depth: this case lives beside the composition corpus rather than
  # in it because the M2 gate binds that corpus by digest; the gate's lock is on
  # those bytes, and new evidence is added next to them. `:recover_stale_writer`
  # used to be read as an assertion the caller had earned, so a caller that
  # passed it broke whatever marker it found -- including one a live embedded
  # runtime was holding on the same state root, which no lock the shipped
  # command can take says anything about. The store now establishes the marker's
  # own holder's liveness, so a live holder refuses every opener and a marker
  # with no identity to check is never broken automatically. Anything but a
  # boolean is still refused rather than read as truthy: a caller who wrote
  # something else has not asked this.
  defmodule Embedder do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  test "a writer marker with no identity to check is never broken automatically" do
    {state_root, workspace} = roots()
    marker = Path.join(state_root, "store.log.writer")
    bytes = "loopex_store_writer_v1\nleft by a process that is gone\n"
    File.write!(marker, bytes)
    options = options(state_root, workspace)

    assert {:error, {:store_writer_active, ^marker}} = LoopexComposition.start(options)
    assert File.regular?(marker), "the refused open removed a marker it did not write"

    assert {:error, {:store_writer_active, ^marker}} =
             LoopexComposition.start(options ++ [recover_stale_writer: false])

    assert {:error, {:invalid_composition_option, :recover_stale_writer}} =
             LoopexComposition.start(options ++ [recover_stale_writer: "true"])

    # The v1 marker names no holder, so nothing can establish that holder is
    # gone and the request is refused rather than granted.
    assert {:error, {:store_writer_active, ^marker}} =
             LoopexComposition.start(options ++ [recover_stale_writer: true])

    assert File.read!(marker) == bytes
  end

  test "a marker left by a dead holder is broken and the runtime starts" do
    {state_root, workspace} = roots()
    marker = Path.join(state_root, "store.log.writer")
    options = options(state_root, workspace)
    observe_stores()

    assert {:ok, _first} = LoopexComposition.start(options)
    assert File.regular?(marker)
    dead = File.read!(marker)
    kill_store()

    assert File.read!(marker) == dead, "an untrappable kill gave the marker back"
    assert {:error, {:store_writer_active, ^marker}} = LoopexComposition.start(options)

    assert {:ok, runtime} = LoopexComposition.start(options ++ [recover_stale_writer: true])
    stop_later(runtime)

    assert {:ok, _session_id} =
             Loopex.create_session(runtime, %{"tenant" => "stale-writer"}, command_id: "create")
  end

  test "a live runtime on the same state root refuses a recovering opener" do
    {state_root, workspace} = roots()
    marker = Path.join(state_root, "store.log.writer")
    options = options(state_root, workspace)

    assert {:ok, embedder} = LoopexComposition.start(options ++ [runtime_id: "embedder"])
    stop_later(embedder)
    bytes = File.read!(marker)

    assert {:error, {:store_writer_active, ^marker}} =
             LoopexComposition.start(options ++ [recover_stale_writer: true])

    assert File.read!(marker) == bytes, "a recovering opener evicted a live runtime"

    # Not being evicted is the point: the embedder is still serving its store.
    assert {:ok, _session_id} =
             Loopex.create_session(embedder, %{"tenant" => "embedder"}, command_id: "create")
  end

  defp options(state_root, workspace),
    do: [
      runtime_id: "stale-writer",
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

  # Concept: the store this composition started, named by the composition's own
  # caller-local observer rather than found by searching the VM.
  defp observe_stores do
    parent = self()

    observer = fn
      Loopex.Store.Local, :start_link, [store_options] ->
        result = apply(Loopex.Store.Local, :start_link, [store_options])
        with {:ok, pid} <- result, do: send(parent, {:composed_store, pid})
        result

      module, function, arguments ->
        apply(module, function, arguments)
    end

    Process.put(:"$loopex_composition_edge_observer", observer)
    on_exit(fn -> Process.delete(:"$loopex_composition_edge_observer") end)
  end

  # Concept: ends the store the way halting an emulator does -- the only ending
  # that leaves a marker behind.
  defp kill_store do
    assert_receive {:composed_store, store}, 5_000
    down = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^down, :process, ^store, :killed}, 5_000
  end

  defp roots do
    unique = System.unique_integer([:positive])
    state_root = Path.join(System.tmp_dir!(), "loopex-stale-writer-#{unique}")
    workspace = Path.join(System.tmp_dir!(), "loopex-stale-writer-ws-#{unique}")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(state_root)
      File.rm_rf(workspace)
    end)

    {state_root, workspace}
  end
end
