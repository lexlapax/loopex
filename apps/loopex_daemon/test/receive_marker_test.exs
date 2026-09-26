defmodule LoopexDaemon.ReceiveMarkerTest do
  # Concept: no daemon process that makes synchronous calls and takes alias
  # replies holds a receive marker it never uses. On OTP 26 through 29 a
  # marker the compiler reserves and binds for a fresh reference, then clears
  # without using, corrupts the process's message-queue bookkeeping once the
  # same process also waits on a monitored call and receives alias replies:
  # the VM crashes with a segmentation fault or spins a scheduler.
  #
  # Technical depth: the compiled code of each listed module is disassembled
  # and every function that reserves a receive marker (`recv_marker_reserve`)
  # must also use it (`recv_marker_use`), which is the shape of an
  # unconditional receive on the reference in that same function. A marker
  # reserved in one function for a receive that happens elsewhere, or only on
  # some branch, fails the case with the function named. The check reads the
  # loaded beam files, so it does not depend on load or timing.
  use ExUnit.Case, async: true

  @modules [
    LoopexDaemon.Owner,
    LoopexDaemon.ConnectionRegistry,
    LoopexDaemon.AdmissionRelay,
    LoopexDaemon.LeaseOwner,
    LoopexDaemon.SocketConnection,
    LoopexDaemon.RequestWorker,
    LoopexDaemon.Service
  ]

  test "no listed daemon process reserves a receive marker it does not use" do
    unused =
      for module <- @modules,
          {:function, name, arity, _entry, code} <- functions(module),
          operations = marker_operations(code),
          :recv_marker_reserve in operations,
          :recv_marker_use not in operations,
          do: {module, name, arity}

    assert unused == []
  end

  test "the check sees receive markers where a function does use them" do
    used =
      for {:function, name, arity, _entry, code} <- functions(LoopexDaemon.Service),
          :recv_marker_use in marker_operations(code),
          do: {name, arity}

    assert used != []
  end

  defp functions(module) do
    path = :code.which(module)
    assert is_list(path), "no beam file for #{inspect(module)}"
    {:beam_file, ^module, _exports, _attributes, _info, functions} = :beam_disasm.file(path)
    functions
  end

  defp marker_operations(code) do
    for instruction <- code,
        is_tuple(instruction),
        elem(instruction, 0) in [:recv_marker_reserve, :recv_marker_use],
        do: elem(instruction, 0)
  end
end
