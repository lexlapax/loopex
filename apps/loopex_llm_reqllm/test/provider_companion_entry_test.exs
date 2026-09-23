Code.require_file("support/provider_build_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderCompanionEntryTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.ProviderBuildFixture

  # Concept: the companion a build produces accepts that build's own identity
  # and reaches its bootstrap socket. Without this, a manifest change can make
  # every real companion refuse at entry while every scripted-worker test and
  # every test that expects a failure still passes.
  #
  # Technical depth: the worker is started with the crash-dump environment its
  # launcher supplies and the build's own manifest digest; it must connect to
  # the offered Unix-domain socket before it would read any bootstrap frame.
  # No credential and no network are involved.
  test "a freshly built companion accepts its own manifest and connects to its socket" do
    root = Path.join(System.tmp_dir!(), "lce-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf(root) end)

    launch = ProviderBuildFixture.options!(root)
    path = Path.join("/tmp", "lce-#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> File.rm(path) end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, active: false])
    deadline = System.system_time(:millisecond) + 60_000

    port =
      Port.open({:spawn_executable, Keyword.fetch!(launch, :interpreter_path)}, [
        :binary,
        :exit_status,
        env: [{~c"ERL_CRASH_DUMP", ~c"/dev/null"}, {~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}],
        args: [
          Keyword.fetch!(launch, :worker_path),
          path,
          String.duplicate("a", 64),
          Keyword.fetch!(launch, :build_manifest_sha256),
          Integer.to_string(deadline)
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)]) end)

    assert {:ok, socket} = :gen_tcp.accept(listener, 30_000),
           "the built companion refused at entry instead of connecting"

    :gen_tcp.close(socket)
  end
end
