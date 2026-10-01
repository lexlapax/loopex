defmodule LoopexComposition.CredentialBindingsTest do
  use ExUnit.Case, async: false
  alias LoopexComposition.{CredentialHost, CredentialPlane}
  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry}
  alias Loopex.Trace.Capability

  @first "M7_BINDING_A"
  @second "M7_BINDING_B"
  @legacy "LOOPEX_PROVIDER_API_KEY"

  setup do
    previous = Map.new([@first, @second, @legacy], &{&1, System.get_env(&1)})

    on_exit(fn ->
      :erlang.trace_pattern({System, :get_env, 1}, false, [:local])

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    put_keys()
    :ok
  end

  test "all references validate before reading deleting or starting any edge" do
    for invalid <- [
          Map.put(bindings(), "openrouter", env("HOME")),
          Map.put(bindings(), "unknown", env(@first)),
          %{"ollama" => %{"credential" => %{"none" => true}}}
        ] do
      {result, reads} =
        traced(fn ->
          CredentialPlane.open(invalid, fn _, _ ->
            send(self(), :invalid_binding_started_edge)
            {:error, :injected}
          end)
        end)

      assert {:error, _} = result
      refute_receive :invalid_binding_started_edge, 0
      assert reads == []
      assert System.get_env(@first) == "first-binding-canary"
      assert System.get_env(@second) == "second-binding-canary"
      assert System.get_env(@legacy) == "unselected-legacy-canary"
    end
  end

  test "unique names load once and unused legacy deletion never reads its value" do
    {starter, marker} = starter()
    {{:ok, plane}, reads} = traced(fn -> CredentialPlane.open(bindings(), starter) end)
    pids = started(marker)
    on_exit(fn -> CredentialPlane.stop_bindings(%{pids: pids}) end)
    assert Enum.sort(reads) == Enum.sort([@first, @second])
    assert length(pids) == 4
    assert Enum.all?([@first, @second, @legacy], &(System.get_env(&1) == nil))

    assert Enum.sort(Map.keys(plane)) == [
             :capability,
             :excluded_env_names,
             :model_options,
             :version
           ]

    assert plane.version == 2
    assert plane.excluded_env_names == Enum.sort([@first, @second, @legacy])
    routes = plane.model_options[:provider_routes]
    assert routes["openai"] == routes["openrouter"]
    refute routes["openai"] == routes["anthropic"]
    assert credential(plane, "openai") == "first-binding-canary"
    assert credential(plane, "anthropic") == "second-binding-canary"
    refute :erlang.term_to_binary(plane) =~ "binding-canary"
  end

  test "every partial loading failure joins all returned children before refusing" do
    for failure <- [:missing, :custody_return, :custody_raise, :capability] do
      put_keys()
      if failure == :missing, do: System.delete_env(@second)
      {starter, marker} = starter(failure)
      assert {:error, reason} = CredentialPlane.open(bindings(), starter)
      assert reason in [:provider_credential_required, :credential_binding_start_failed]
      pids = started(marker)
      assert length(pids) >= 2
      assert Enum.all?(pids, &(not Process.alive?(&1)))
      assert System.get_env(@first) == nil
      assert System.get_env(@second) == nil
      assert System.get_env(@legacy) == nil
    end
  end

  test "a host lends the same routes with fresh capabilities without another environment read" do
    {{:ok, host}, reads} = traced(fn -> CredentialHost.open(bindings()) end)
    assert Enum.sort(reads) == Enum.sort([@first, @second])
    {:ok, first} = CredentialHost.plane(host)

    custodies =
      for {_provider, token} <- host.provider_routes do
        {:ok, custody} = CredentialRegistry.route(host.registry, token)
        custody.pid
      end

    on_exit(fn ->
      CredentialPlane.stop_bindings(%{pids: Enum.uniq(custodies) ++ [host.registry.pid]})
    end)

    System.put_env(@first, "replacement-must-not-be-read")
    {{:ok, second}, reads} = traced(fn -> CredentialHost.plane(host) end)
    assert reads == []
    assert first.model_options[:provider_routes] == second.model_options[:provider_routes]
    assert first.model_options[:credential_registry] == second.model_options[:credential_registry]
    refute first.capability == second.capability
    assert credential(second, "openai") == "first-binding-canary"
    assert System.get_env(@first) == "replacement-must-not-be-read"

    for plane <- [first, second] do
      assert :ok = CredentialHost.release_plane(plane)
      refute Process.alive?(plane.capability_pid)
    end

    assert Process.alive?(host.registry.pid)
    assert Enum.all?(custodies, &Process.alive?/1)
  end

  defp credential(plane, provider) do
    {:ok, custody} =
      CredentialRegistry.route(
        plane.model_options[:credential_registry],
        plane.model_options[:provider_routes][provider]
      )

    {:ok, %{credential: value}} = CredentialCustody.resolve(custody)
    value
  end

  defp starter(failure \\ nil) do
    test = self()
    marker = make_ref()

    fun = fn module, options ->
      cond do
        module == Capability and failure == :capability ->
          {:error, :injected}

        module == CredentialCustody and options[:credential] == "second-binding-canary" and
            failure == :custody_return ->
          {:error, "secret-reason-must-not-escape"}

        module == CredentialCustody and options[:credential] == "second-binding-canary" and
            failure == :custody_raise ->
          raise "secret-exception-must-not-escape"

        true ->
          {:ok, pid} = module.start_link(options)
          send(test, {marker, pid})
          {:ok, pid}
      end
    end

    {fun, marker}
  end

  defp started(marker, pids \\ []) do
    receive do
      {^marker, pid} -> started(marker, [pid | pids])
    after
      0 -> pids
    end
  end

  defp traced(fun) do
    collector = spawn_link(fn -> collect([]) end)
    :erlang.trace_pattern({System, :get_env, 1}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, collector}])
    result = fun.()
    :erlang.trace(self(), false, [:call])
    fence = :erlang.trace_delivered(self())
    receive do: ({:trace_delivered, _, ^fence} -> :ok)
    send(collector, {:result, self()})
    reads = receive do: ({:reads, ^collector, reads} -> reads)
    :erlang.trace_pattern({System, :get_env, 1}, false, [:local])
    {result, Enum.filter(reads, &(&1 in [@first, @second, @legacy]))}
  end

  defp collect(reads) do
    receive do
      {:trace, _, :call, {System, :get_env, [name]}} -> collect([name | reads])
      {:result, recipient} -> send(recipient, {:reads, self(), reads})
      _ -> collect(reads)
    end
  end

  defp put_keys do
    System.put_env(@first, "first-binding-canary")
    System.put_env(@second, "second-binding-canary")
    System.put_env(@legacy, "unselected-legacy-canary")
  end

  defp bindings,
    do: %{"openai" => env(@first), "anthropic" => env(@second), "openrouter" => env(@first)}

  defp env(name), do: %{"credential" => %{"env" => name}}
end
