defmodule LoopexComposition.StartEdgesTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry, CredentialToken}
  alias Loopex.Trace.Capability

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-start-edges-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, registry_pid} = CredentialRegistry.start_link([])
    {:ok, registry} = CredentialRegistry.handle(registry_pid)
    {:ok, custody_pid} = CredentialCustody.start_link(credential: "start-edges-canary")
    {:ok, custody} = CredentialCustody.reference(custody_pid)
    token = CredentialToken.new()
    :ok = CredentialRegistry.put(registry, token, custody)
    {:ok, capability_pid} = Capability.start_link([])
    {:ok, capability} = Capability.handle(capability_pid)

    plane = %{
      capability: capability,
      model_options: [
        credential_token: token,
        credential_registry: registry,
        tracing_capability: capability
      ]
    }

    options = [
      runtime_id: "start-edges",
      state_root: Path.join(root, "state"),
      workspace: workspace,
      policy: Policy,
      credential_plane: plane
    ]

    %{options: options, host: [registry_pid, custody_pid, capability_pid]}
  end

  test "the caller owns exactly the edges started, with the runtime and its supervisor together",
       %{options: options, host: host} do
    assert {:ok, edges} = LoopexComposition.start_edges(options)

    assert Map.keys(edges) |> Enum.sort() ==
             [:executor, :runtime, :runtime_supervisor, :store, :workspace_lease]

    {:links, links} = Process.info(self(), :links)

    for key <- [:store, :workspace_lease, :executor, :runtime_supervisor] do
      assert Map.fetch!(edges, key) in links
    end

    assert edges.runtime.supervisor == edges.runtime_supervisor

    assert {:ok, _session_id} =
             Loopex.create_session(edges.runtime, %{"purpose" => "edges"}, command_id: "c1")

    stop_all(edges, host)
  end

  test "an interrupt stops composition before the next edge and returns what exists",
       %{options: options, host: host} do
    counter = :counters.new(1, [])

    interrupt = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 3, do: {:stop, :operator_stop}, else: :continue
    end

    assert {:error, {:stop, :operator_stop}, partial} =
             LoopexComposition.start_edges(options, interrupt: interrupt)

    assert Map.keys(partial) |> Enum.sort() == [:store, :workspace_lease]
    assert Process.alive?(partial.store)
    stop_all(partial, host)
  end

  test "lifecycle options and interrupt answers are closed", %{options: options, host: host} do
    assert {:error, {:invalid_composition_option, :credential_plane}, %{}} =
             LoopexComposition.start_edges(Keyword.delete(options, :credential_plane))

    assert {:error, :invalid_composition_options, %{}} =
             LoopexComposition.start_edges(options, unknown: true)

    assert {:error, :invalid_composition_options, %{}} =
             LoopexComposition.start_edges(options, interrupt: :not_a_function)

    assert {:error, {:invalid_composition_interrupt_result, :maybe}, %{}} =
             LoopexComposition.start_edges(options, interrupt: fn -> :maybe end)

    assert {:error, {:composition_interrupt_exception, :store, :error}, %{}} =
             LoopexComposition.start_edges(options, interrupt: fn -> raise "boom" end)

    Enum.each(host, &stop_process/1)
  end

  defp stop_all(edges, host) do
    if runtime = Map.get(edges, :runtime), do: Loopex.stop(runtime)

    edges
    |> Map.drop([:runtime, :runtime_supervisor])
    |> Map.values()
    |> Enum.each(&stop_process/1)

    Enum.each(host, &stop_process/1)
  end

  defp stop_process(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
