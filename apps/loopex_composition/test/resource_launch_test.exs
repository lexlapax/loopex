defmodule LoopexComposition.ResourceLaunchTest do
  use ExUnit.Case, async: false

  defmodule Embedder do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  defp roots do
    root = temporary_root!()
    state_root = Path.join(root, "state")
    workspace = Path.join(root, "workspace")
    File.mkdir!(state_root)
    File.mkdir!(workspace)

    {state_root, workspace}
  end

  defp temporary_root! do
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    root = Path.join(System.tmp_dir!(), "loopex-resource-launch-#{nonce}")

    case File.mkdir(root) do
      :ok ->
        on_exit(fn -> File.rm_rf!(root) end)
        root

      {:error, :eexist} ->
        temporary_root!()

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make test directory", path: root
    end
  end

  test "resource launch retains the exact snapshot before runtime admission" do
    {state_root, workspace} = roots()
    skill = Path.join([workspace, ".agents", "skills", "review", "SKILL.md"])
    File.mkdir_p!(Path.dirname(skill))

    File.write!(
      skill,
      "---\nname: review\ndescription: Review this change.\n---\nRead the diff.\n"
    )

    assert {:ok, manifest} =
             LoopexComposition.ResourcePacks.discover(workspace,
               workspace_ref: "workspace:test"
             )

    {:ok, digest, normalized} = Loopex.ResourcePack.digest(manifest)
    test = self()
    marker = make_ref()
    observer = :"$loopex_composition_edge_observer"

    Process.put(observer, fn
      Loopex, :start_link, [runtime_options] ->
        send(test, {marker, runtime_options})
        {:error, :stop_after_resource_observation}

      module, function, arguments ->
        apply(module, function, arguments)
    end)

    try do
      assert {:error, :stop_after_resource_observation} =
               LoopexComposition.start(
                 runtime_id: "resource-launch",
                 state_root: state_root,
                 workspace: workspace,
                 policy: Embedder,
                 resource_manifest: manifest
               )

      assert_receive {^marker, runtime_options}
      assert Keyword.fetch!(runtime_options, :resource_manifest) == normalized
      assert {:ok, ^normalized} = LoopexComposition.ResourcePacks.load(state_root, digest)
    after
      Process.delete(observer)
    end
  end

  test "invalid resource manifests are validated before the first effect" do
    edge_observer = :"$loopex_composition_edge_observer"
    effect_observer = :"$loopex_composition_effect_observer"

    refuse_effect = fn module, function, _arguments ->
      flunk("#{module}.#{function} caused an effect")
    end

    Process.put(edge_observer, refuse_effect)
    Process.put(effect_observer, refuse_effect)

    try do
      assert {:error, {:invalid_composition_option, :resource_manifest}} =
               LoopexComposition.start(
                 runtime_id: "prevalidated",
                 state_root: "/unused",
                 workspace: "/unused",
                 policy: Embedder,
                 resource_manifest: %{}
               )
    after
      Process.delete(edge_observer)
      Process.delete(effect_observer)
    end
  end

  test "with_runtime returns only after every owned process stops orderly" do
    {state_root, workspace} = roots()
    test = self()
    marker = make_ref()
    observer = :"$loopex_composition_edge_observer"

    Process.put(observer, fn module, function, arguments ->
      result = apply(module, function, arguments)
      send(test, {marker, module, result})
      result
    end)

    try do
      assert :callback_result =
               LoopexComposition.with_runtime(
                 [
                   runtime_id: "bracketed-runtime",
                   state_root: state_root,
                   workspace: workspace,
                   policy: Embedder
                 ],
                 fn runtime ->
                   assert Loopex.Runtime.alive?(runtime)
                   :callback_result
                 end
               )

      acquired =
        for _index <- 1..4 do
          assert_receive {^marker, module, {:ok, owned}}
          {module, owned}
        end

      for {module, owned} <- acquired, module != Loopex do
        refute Process.alive?(owned)
      end

      refute File.exists?(Path.join(state_root, "store.log.writer"))
    after
      Process.delete(observer)
    end
  end

  test "with_runtime reports forced cleanup after stopping every owned process" do
    {state_root, workspace} = roots()
    observer = :"$loopex_composition_effect_observer"

    Process.put(observer, fn
      Process, :exit, [pid, :shutdown] ->
        case Process.get(:loopex_force_one_cleanup) do
          nil ->
            Process.put(:loopex_force_one_cleanup, true)
            :ok

          true ->
            apply(Process, :exit, [pid, :shutdown])
        end

      module, function, arguments ->
        apply(module, function, arguments)
    end)

    try do
      assert {:error, {:composition_cleanup_unconfirmed, failures}} =
               LoopexComposition.with_runtime(
                 [
                   runtime_id: "forced-cleanup-runtime",
                   state_root: state_root,
                   workspace: workspace,
                   policy: Embedder
                 ],
                 fn runtime ->
                   assert Loopex.Runtime.alive?(runtime)
                   :callback_result
                 end
               )

      assert length(failures) == 1
      assert Enum.all?(failures, &match?({_module, :forced_stop, _, _, :killed}, &1))
      refute File.exists?(Path.join(state_root, "store.log.writer"))
    after
      Process.delete(observer)
    end
  end

  test "with_runtime reraises callback exceptions after cleanup" do
    {state_root, workspace} = roots()

    assert_raise RuntimeError, "callback failed", fn ->
      LoopexComposition.with_runtime(
        [
          runtime_id: "exception-runtime",
          state_root: state_root,
          workspace: workspace,
          policy: Embedder
        ],
        fn _runtime -> raise "callback failed" end
      )
    end

    refute File.exists?(Path.join(state_root, "store.log.writer"))

    assert :reopened =
             LoopexComposition.with_runtime(
               [
                 runtime_id: "exception-runtime-reopened",
                 state_root: state_root,
                 workspace: workspace,
                 policy: Embedder
               ],
               fn _runtime -> :reopened end
             )
  end
end
