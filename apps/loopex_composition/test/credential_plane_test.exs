defmodule LoopexComposition.CredentialPlaneTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry, CredentialToken}
  alias Loopex.Trace.Capability

  @edge :"$loopex_composition_edge_observer"
  @effect :"$loopex_composition_effect_observer"
  @trace_installed :"$loopex_credential_trace_installed"

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-credential-plane-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    variable = ReqLLM.credential_variable()
    previous = System.get_env(variable)

    on_exit(fn ->
      Process.delete(@edge)
      Process.delete(@effect)
      :erlang.trace_pattern({System, :get_env, 1}, false, [:local])

      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)

      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, variable: variable}
  end

  test "composition consumes one credential read and owns the complete credential plane", %{
    root: root,
    workspace: workspace,
    variable: variable
  } do
    credential = "composition-private-canary"
    System.put_env(variable, credential)
    test = self()
    assert :erlang.trace_pattern({System, :get_env, 1}, true, [:local]) == 1

    Process.put(@effect, fn module, function, arguments ->
      unless Process.get(@trace_installed) do
        Process.put(@trace_installed, true)
        :erlang.trace(self(), true, [:call, {:tracer, test}])
        send(test, {:composition_owner, self()})
      end

      apply(module, function, arguments)
    end)

    Process.put(@edge, fn module, function, arguments ->
      result = apply(module, function, arguments)
      send(test, {:composition_edge, self(), module, arguments, result})
      result
    end)

    result =
      LoopexComposition.with_runtime(
        [
          runtime_id: "credential-plane",
          state_root: Path.join(root, "state"),
          workspace: workspace,
          policy: Policy
        ],
        fn runtime ->
          assert System.get_env(variable) == nil
          assert_receive {:composition_owner, owner}

          edges = receive_edges(7, [])
          assert Enum.all?(edges, &(elem(&1, 0) == owner))

          {_owner, Loopex, [runtime_options], {:ok, ^runtime}} =
            Enum.find(edges, &(elem(&1, 1) == Loopex))

          model_options =
            runtime_options
            |> Keyword.fetch!(:model)
            |> Map.fetch!(:options)

          token = Keyword.fetch!(model_options, :credential_token)
          registry = Keyword.fetch!(model_options, :credential_registry)
          capability = Keyword.fetch!(model_options, :tracing_capability)

          assert :ok = CredentialToken.validate(token)
          assert :ok = CredentialRegistry.validate(registry)
          assert :ok = Capability.validate(capability)
          assert :ok = Capability.bind(capability, runtime)
          assert {:ok, custody} = CredentialRegistry.route(registry, token)
          assert {:ok, %{credential: ^credential}} = CredentialCustody.resolve(custody)

          component_pids =
            for {_owner, _module, _arguments, {:ok, owned}} <- edges do
              case owned do
                %{supervisor: supervisor} -> supervisor
                pid when is_pid(pid) -> pid
              end
            end

          {owner, component_pids}
        end
      )

    assert {owner, component_pids} = result
    refute Process.alive?(owner)
    assert Enum.all?(component_pids, &(not Process.alive?(&1)))

    credential_reads =
      collect_traces([])
      |> Enum.filter(&match?({:trace, ^owner, :call, {System, :get_env, [^variable]}}, &1))

    assert length(credential_reads) == 1
    assert System.get_env(variable) == nil
  end

  defp receive_edges(0, edges), do: Enum.reverse(edges)

  defp receive_edges(remaining, edges) do
    assert_receive {:composition_edge, owner, module, arguments, result}, 1_000
    receive_edges(remaining - 1, [{owner, module, arguments, result} | edges])
  end

  defp collect_traces(messages) do
    receive do
      {:trace, _pid, :call, _mfa} = message -> collect_traces([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end
end
