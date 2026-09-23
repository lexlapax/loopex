defmodule Loopex.Store.Local.LogCapacityTest do
  use ExUnit.Case, async: true

  alias Loopex.Store.Local.Log

  @max_log_bytes 256 * 1_048_576

  # Concept: the journal has a fixed ceiling, and an append that would pass it
  # is refused with its own reason before a byte is written, so the Store stops
  # rather than growing the log past what it will read back.
  #
  # Technical depth: the log is a sparse file sixteen bytes under the 256 MiB
  # ceiling, prepared by the Store's own path preparation; any encoded frame is
  # larger than the space left. The append answers
  # `{:store_capacity_exceeded, 268435456}` and the file's size is unchanged.
  test "an append that would pass the ceiling is refused and writes nothing" do
    root = Path.join(System.tmp_dir!(), "llc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "store.log")

    {:ok, file} = :file.open(path, [:write, :raw, :binary])
    {:ok, _position} = :file.position(file, @max_log_bytes - 17)
    :ok = :file.write(file, "x")
    :ok = :file.close(file)

    assert {:ok, identity} = Log.prepare_path(path)

    assert Log.append(path, %{"type" => "capacity-probe"}, identity) ==
             {:error, {:store_capacity_exceeded, @max_log_bytes}}

    assert File.stat!(path).size == @max_log_bytes - 16
  end
end
