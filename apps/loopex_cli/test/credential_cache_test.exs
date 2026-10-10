defmodule LoopexCli.CredentialCacheTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry}
  alias LoopexCli.CredentialCache
  alias LoopexComposition.CredentialHost

  test "one real host custody serves two planes in a command process" do
    variable = ReqLLM.credential_variable()
    System.put_env(variable, "cache-test-inert-key")

    try do
      assert {:ok, host} = CredentialCache.host()
      assert System.get_env(variable) == nil
      assert {:ok, ^host} = CredentialCache.host()

      assert {:ok, first} = CredentialCache.plane()
      assert :ok = CredentialHost.release_plane(first)
      refute Process.alive?(first.capability_pid)

      registry = Keyword.fetch!(first.model_options, :credential_registry)
      token = Keyword.fetch!(first.model_options, :provider_routes)["anthropic"]
      assert {:ok, _custody} = CredentialRegistry.route(registry, token)

      assert {:ok, second} = CredentialCache.plane()
      assert second.capability_pid != first.capability_pid
      assert :ok = CredentialHost.release_plane(second)
      refute Process.alive?(second.capability_pid)
      assert {:ok, ^host} = CredentialCache.host()
    after
      System.delete_env(variable)
    end
  end

  test "explicit bindings are consumed once and lent through distinct planes" do
    with_bindings(fn bindings ->
      assert {:ok, host} = CredentialCache.host(bindings)
      own(host)
      assert System.get_env("M7_CACHE_A") == nil
      assert System.get_env("M7_CACHE_B") == nil
      System.put_env("M7_CACHE_A", "replacement-canary")
      assert {:ok, ^host} = CredentialCache.host(bindings)
      assert {:ok, ^host} = CredentialCache.host()
      assert {:ok, first} = CredentialCache.plane()
      assert {:ok, second} = CredentialCache.plane()
      assert first.model_options[:provider_routes] == second.model_options[:provider_routes]
      refute first.capability_pid == second.capability_pid
      assert first.excluded_env_names == ~w(LOOPEX_PROVIDER_API_KEY M7_CACHE_A M7_CACHE_B)
      token = first.model_options[:provider_routes]["openai"]
      assert {:ok, custody} = CredentialRegistry.route(host.registry, token)
      assert {:ok, %{credential: "cache-first-canary"}} = CredentialCustody.resolve(custody)
      assert System.get_env("M7_CACHE_A") == "replacement-canary"
      CredentialHost.release_plane(first)
      CredentialHost.release_plane(second)
    end)
  end

  test "changed bindings refuse without consuming new values or replacing a host" do
    with_bindings(fn bindings ->
      assert {:ok, host} = CredentialCache.host(bindings)
      own(host)
      System.put_env("M7_CACHE_A", "replacement-canary")
      changed = Map.put(bindings, "openai", bindings["anthropic"])
      assert {:error, :provider_bindings_conflict} = CredentialCache.host(changed)
      assert {:ok, ^host} = CredentialCache.host(bindings)
      assert System.get_env("M7_CACHE_A") == "replacement-canary"
    end)
  end

  test "a failed explicit load does not cache a partial host" do
    with_bindings(fn bindings ->
      System.delete_env("M7_CACHE_B")
      assert {:error, :provider_credential_required} = CredentialCache.host(bindings)
      assert Process.get(:"$loopex_cli_credential_host") == nil
      System.put_env("M7_CACHE_A", "cache-first-canary")
      System.put_env("M7_CACHE_B", "cache-second-canary")
      assert {:ok, host} = CredentialCache.host(bindings)
      own(host)
    end)
  end

  test "an explicit map cannot replace existing legacy custody" do
    with_bindings(fn bindings ->
      assert {:ok, host} = CredentialCache.host()
      own(host)
      assert {:error, :provider_bindings_conflict} = CredentialCache.host(bindings)
      assert System.get_env("M7_CACHE_A") == "cache-first-canary"
      assert System.get_env("M7_CACHE_B") == "cache-second-canary"
    end)
  end

  defp with_bindings(function) do
    names = ~w(LOOPEX_PROVIDER_API_KEY M7_CACHE_A M7_CACHE_B)
    previous = Map.new(names, &{&1, System.get_env(&1)})
    System.put_env("LOOPEX_PROVIDER_API_KEY", "cache-legacy-canary")
    System.put_env("M7_CACHE_A", "cache-first-canary")
    System.put_env("M7_CACHE_B", "cache-second-canary")

    try do
      function.(%{
        "openai" => %{"credential" => %{"env" => "M7_CACHE_A"}},
        "anthropic" => %{"credential" => %{"env" => "M7_CACHE_B"}}
      })
    after
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end
  end

  defp own(host) do
    tokens = if host.provider_routes, do: Map.values(host.provider_routes), else: [host.token]

    custodies =
      Enum.map(tokens, fn token ->
        {:ok, custody} = CredentialRegistry.route(host.registry, token)
        custody.pid
      end)

    on_exit(fn ->
      for pid <- Enum.uniq(custodies ++ [host.registry.pid]) do
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      end
    end)
  end
end
