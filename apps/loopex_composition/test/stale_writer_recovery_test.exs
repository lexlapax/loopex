defmodule LoopexComposition.StaleWriterRecoveryTest do
  @moduledoc false

  use ExUnit.Case, async: false

  # Concept: breaking a store's writer marker is an assertion about the world,
  # and the composition makes it only for a caller that actually made it.
  #
  # Technical depth: this case lives beside the composition corpus rather than
  # in it because the M2 gate binds that corpus by digest; the gate's lock is
  # on those bytes, and new evidence is added next to them. The shipped command
  # may assert recovery because it holds the placement lock, whose acquisition
  # probed the recorded owner and found it gone. An embedder has established
  # nothing of the kind, so the default is unchanged and a marker it did not
  # write still refuses it. Anything but a boolean is refused rather than read
  # as truthy: a caller who wrote something else has not said this.
  defmodule Embedder do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  test "a stale writer marker is broken only for a caller that asserted it may be" do
    {state_root, workspace} = roots()
    marker = Path.join(state_root, "store.log.writer")
    File.write!(marker, "loopex_store_writer_v1\nleft by a process that is gone\n")

    options = [
      runtime_id: "stale-writer",
      state_root: state_root,
      workspace: workspace,
      policy: Embedder
    ]

    assert {:error, {:store_writer_active, ^marker}} = LoopexComposition.start(options)
    assert File.regular?(marker), "the refused open removed a marker it did not write"

    assert {:error, {:store_writer_active, ^marker}} =
             LoopexComposition.start(options ++ [recover_stale_writer: false])

    assert {:error, {:invalid_composition_option, :recover_stale_writer}} =
             LoopexComposition.start(options ++ [recover_stale_writer: "true"])

    assert {:ok, runtime} = LoopexComposition.start(options ++ [recover_stale_writer: true])

    on_exit(fn ->
      try do
        Loopex.stop(runtime)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert {:ok, _session_id} =
             Loopex.create_session(runtime, %{"tenant" => "stale-writer"}, command_id: "create")
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
