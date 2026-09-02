defmodule LoopexComposition.ContextAdmissionTestPolicy do
  @moduledoc false

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(_request), do: {:allow, nil}
end

defmodule LoopexComposition.ContextAdmissionTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Runtime

  @uint64_max 18_446_744_073_709_551_615

  test "the reference composition defaults only omission to 8192 and forwards an explicit context budget unchanged" do
    omitted = start_composition("omitted", [])
    explicit = start_composition("explicit", context_token_budget: 4_096)

    assert {:ok, omitted_configuration} = Runtime.configuration(omitted)
    assert {:ok, explicit_configuration} = Runtime.configuration(explicit)

    assert omitted_configuration.context_token_budget == 8_192
    assert explicit_configuration.context_token_budget == 4_096
    refute Map.has_key?(explicit_configuration.bounds, :context_token_budget)

    for {label, value} <- [
          {:zero, 0},
          {:negative, -1},
          {:non_integer, "8192"},
          {:overflow, @uint64_max + 1}
        ] do
      root = roots("invalid-#{label}")

      assert {:error, :invalid_context_token_budget} =
               LoopexComposition.start(
                 runtime_id: "context-invalid-#{label}",
                 state_root: root.state,
                 workspace: root.workspace,
                 policy: LoopexComposition.ContextAdmissionTestPolicy,
                 context_token_budget: value
               )
    end
  end

  defp start_composition(label, extra) do
    root = roots(label)

    assert {:ok, runtime} =
             LoopexComposition.start(
               [
                 runtime_id: "context-#{label}",
                 state_root: root.state,
                 workspace: root.workspace,
                 policy: LoopexComposition.ContextAdmissionTestPolicy
               ] ++ extra
             )

    on_exit(fn -> stop_runtime(runtime) end)
    runtime
  end

  defp roots(label) do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "loopex-composition-context-#{label}-#{unique}")
    state = Path.join(root, "state")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(state)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{state: state, workspace: workspace}
  end

  defp stop_runtime(runtime) do
    try do
      Loopex.stop(runtime)
    catch
      :exit, _reason -> :ok
    end
  end
end
