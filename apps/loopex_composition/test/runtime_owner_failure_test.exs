defmodule LoopexComposition.RuntimeOwnerFailureTest do
  use ExUnit.Case, async: false

  @edge :"$loopex_composition_edge_observer"
  @effect :"$loopex_composition_effect_observer"

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
        "loopex-owner-failure-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    options = [
      runtime_id: "owner-failure",
      state_root: Path.join(root, "state"),
      workspace: workspace,
      policy: Policy
    ]

    %{options: options}
  end

  for module <- [Loopex.Store.Local, Loopex.Executor.Local, Loopex.Executor.Local.WorkspaceLease] do
    test "bracketed runtime ends every owned process after #{inspect(module)} dies", %{
      options: options
    } do
      module = unquote(module)
      test = self()

      {caller, caller_down} =
        spawn_monitor(fn ->
          observe_edges(test)

          result =
            LoopexComposition.with_runtime(options, fn _runtime ->
              send(test, {:callback, self()})
              receive do: (:finish -> :callback_result)
            end)

          send(test, {:result, result})
        end)

      acquired = acquired_edges()
      [{owner, _, _} | _] = acquired
      owner_down = Process.monitor(owner)
      on_exit(fn -> cleanup(acquired, caller) end)
      assert_receive {:callback, ^caller}
      {_, ^module, victim} = Enum.find(acquired, &(elem(&1, 1) == module))
      Process.exit(victim, :kill)
      assert_receive {:DOWN, ^owner_down, :process, ^owner, :normal}, 3_000
      assert_all_stopped(acquired)
      send(caller, :finish)

      assert_receive {:result, {:error, {:composition_runtime_stopped, :killed, {:error, _}}}},
                     1_000

      assert_receive {:DOWN, ^caller_down, :process, ^caller, :normal}, 1_000

      # Concept: a killed Store keeps its stale marker.
      # Technical depth: only the explicit stale-writer recovery option permits
      # reopening after a kill; cleanup must not claim an orderly Store exit.
      assert :reopened =
               LoopexComposition.with_runtime(
                 Keyword.put(
                   options,
                   :recover_stale_writer,
                   unquote(module == Loopex.Store.Local)
                 ),
                 fn _ -> :reopened end
               )
    end
  end

  test "a returned runtime stop failure still shuts down the live owned runtime", %{
    options: options
  } do
    observe_edges(self())

    Process.put(@effect, fn
      Loopex, :stop, [_runtime] -> {:error, :runtime_unavailable}
      module, function, arguments -> apply(module, function, arguments)
    end)

    try do
      assert {:error, {:composition_cleanup_unconfirmed, failures}} =
               LoopexComposition.with_runtime(options, fn _ -> :callback_result end)

      assert [{:runtime_stop_unconfirmed, {:error, :runtime_unavailable}}] = failures
      acquired = acquired_edges()
      on_exit(fn -> cleanup(acquired, nil) end)
      [{owner, _, _} | _] = acquired
      owner_down = Process.monitor(owner)
      assert_receive {:DOWN, ^owner_down, :process, ^owner, _}, 3_000
      assert_all_stopped(acquired)
    after
      Process.delete(@edge)
      Process.delete(@effect)
    end

    assert :reopened = LoopexComposition.with_runtime(options, fn _ -> :reopened end)
  end

  defp observe_edges(test) do
    Process.put(@edge, fn module, function, arguments ->
      result = apply(module, function, arguments)
      send(test, {:acquired, self(), module, result})
      result
    end)
  end

  defp acquired_edges do
    for _ <- 1..4 do
      assert_receive {:acquired, owner, module, {:ok, owned}}, 1_000
      {owner, module, owned}
    end
  end

  defp pid(Loopex, runtime), do: runtime.supervisor
  defp pid(_module, pid), do: pid

  defp assert_all_stopped(acquired) do
    for {_, module, owned} <- acquired, do: refute(Process.alive?(pid(module, owned)))
  end

  defp cleanup(acquired, caller) do
    # Concept: a failed assertion must not leave the composed stack alive.
    # Technical depth: kill only the observed owned identities and the held caller.
    for {_, module, owned} <- acquired do
      target = pid(module, owned)
      if Process.alive?(target), do: Process.exit(target, :kill)
    end

    if is_pid(caller) and Process.alive?(caller), do: Process.exit(caller, :kill)
  end
end
