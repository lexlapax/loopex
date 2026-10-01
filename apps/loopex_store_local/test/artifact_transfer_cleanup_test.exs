defmodule Loopex.Store.Local.ArtifactTransferCleanupTest do
  use ExUnit.Case, async: false

  alias Loopex.Store.Local.Artifacts
  alias Loopex.Store.Local.Transfers

  test "snapshot creation failure closes the source before returning" do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-transfer-cleanup-#{System.unique_integer([:positive])}"
      )

    owner = start_supervised!({Transfers, root: root})
    on_exit(fn -> File.rm_rf!(root) end)
    handle = %{root: root, transfers: owner}

    assert {:ok, reference} =
             Artifacts.put(handle, "source bytes", %{
               media_type: "text/plain",
               role: "tool_output",
               metadata: %{}
             })

    scratch = Path.join(root, "transfers")
    File.rmdir!(scratch)
    File.write!(scratch, "not a directory")

    :erlang.trace_pattern({File, :open, 2}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(owner, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({File, :open, 2}, false, [:local])
    end)

    object = Map.take(reference, [:digest, :size, :locator])

    assert {:error, _reason} =
             Artifacts.open_transfer(handle, object, reference.use_locator, %{start: 0})

    assert_receive {:trace, ^owner, :return_from, {File, :open, 2}, {:ok, reader}}

    # Concept: failure releases the actual descriptor while its owner stays alive.
    # Technical depth: raw descriptors can only be read by their opening process;
    # inspect it there after the failed open has acknowledged completion.
    observer = self()

    :sys.replace_state(owner, fn state ->
      send(observer, {:source_read_after_failure, :file.read(reader, 1)})
      state
    end)

    assert_receive {:source_read_after_failure, {:error, :einval}}
    assert Transfers.live(owner) == []
    assert Process.alive?(owner)
  end
end
