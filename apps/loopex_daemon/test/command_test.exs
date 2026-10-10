defmodule LoopexDaemon.CommandTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.{Command, ExitStatus}

  test "startup accepts only its exact grammar" do
    assert {:ok,
            {:start,
             %{
               "state-root" => "/state",
               "workspace" => "/workspace",
               "provider-launch" => "/provider.launch",
               "policy" => "allow-all",
               "cleanup-grace-ms" => "18446744073709551615",
               "socket" => "/state/daemon/service.sock"
             }}} =
             Command.parse([
               "--state-root=/state",
               "--workspace",
               "/workspace",
               "--provider-launch=/provider.launch",
               "--policy",
               "allow-all",
               "--cleanup-grace-ms=18446744073709551615",
               "--socket",
               "/state/daemon/service.sock"
             ])

    assert {:ok, {:start, %{}}} = Command.parse(["--"])

    for arguments <- [
          ["--unknown", "value"],
          ["--state-root", ""],
          ["--state-root="],
          ["--state-root", "/one", "--state-root", "/two"],
          ["--workspace"],
          ["positional"],
          ["--", "positional"],
          ["prepare-index", "--state-root", "/state"],
          ["--state-root", :not_a_binary]
        ] do
      assert {:error, :invalid_daemon_arguments} = Command.parse(arguments)
    end
  end

  test "the daemon failure map is closed injective and contiguous" do
    classes = ExitStatus.classes()
    statuses = Map.values(classes)

    assert map_size(classes) == 46
    assert Enum.sort(statuses) == Enum.to_list(65..110)
    assert length(Enum.uniq(statuses)) == map_size(classes)
    assert ExitStatus.success() == 0
    assert ExitStatus.parser_refusal() == 1

    for {class, status} <- classes do
      assert ExitStatus.fetch(class) == {:ok, status}
    end

    assert ExitStatus.fetch(:unknown) == :error
  end
end
