defmodule Loopex.LLM.ReqLLM.ProviderLaunchExclusionsTest do
  use ExUnit.Case, async: false
  alias Loopex.LLM.ReqLLM.ProviderLauncher

  test "the first image excludes captured names reintroduced after the snapshot" do
    names = Enum.sort(["LOOPEX_PROVIDER_API_KEY" | Enum.map(1..16, &"M7_LATE_PROVIDER_#{&1}")])
    prior = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- prior do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    Enum.each(names, &System.delete_env/1)
    environment = ProviderLauncher.spawn_environment(names)
    Enum.each(names, &System.put_env(&1, "synthetic-late-provider-secret"))

    port =
      Port.open({:spawn_executable, ~c"/usr/bin/env"}, [:binary, :exit_status, env: environment])

    bytes = read(port, "")
    for name <- names, do: refute(bytes =~ name <> "=")
    refute bytes =~ "synthetic-late-provider-secret"
  end

  defp read(port, bytes) do
    receive do
      {^port, {:data, chunk}} -> read(port, bytes <> chunk)
      {^port, {:exit_status, 0}} -> bytes
    after
      5_000 -> flunk("first-image witness did not exit")
    end
  end
end
