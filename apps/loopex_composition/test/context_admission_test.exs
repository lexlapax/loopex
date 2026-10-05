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

  @model "anthropic:claude-haiku-4-5-20251001"
  @context_window 200_000
  @reply_tokens 4_096

  @uint64_max 18_446_744_073_709_551_615

  test "the reference composition captures the known-model derived budget and preserves explicit input" do
    omitted = start_composition("omitted", [])
    explicit = start_composition("explicit", context_token_budget: 4_096)

    assert {:ok, omitted_configuration} = Runtime.configuration(omitted)
    assert {:ok, explicit_configuration} = Runtime.configuration(explicit)

    omitted_capture = captured_configuration(omitted)
    explicit_capture = captured_configuration(explicit)

    assert omitted_capture["model"] == @model
    assert omitted_capture["model_capabilities"]["context_window"] == @context_window
    assert omitted_capture["max_tokens"] == @reply_tokens
    assert omitted_capture["context_token_budget"] == @context_window - @reply_tokens
    assert omitted_capture["budget_origins"]["context_token_budget"] == "model_window"
    assert omitted_configuration.context_token_budget == @context_window - @reply_tokens

    assert explicit_capture["model"] == @model
    assert explicit_capture["model_capabilities"]["context_window"] == @context_window
    assert explicit_capture["max_tokens"] == @reply_tokens
    assert explicit_capture["context_token_budget"] == 4_096
    assert explicit_capture["budget_origins"]["context_token_budget"] == "explicit"
    assert explicit_configuration.context_token_budget == 4_096
    refute Map.has_key?(explicit_configuration.bounds, :context_token_budget)

    for {label, value} <- [
          {:zero, 0},
          {:negative, -1},
          {:non_integer, "8192"},
          {:overflow, @uint64_max + 1}
        ] do
      root = roots("invalid-#{label}")

      assert {:error, :invalid_session_genesis} =
               LoopexComposition.TestHost.start(
                 runtime_id: "context-invalid-#{label}",
                 state_root: root.state,
                 workspace: root.workspace,
                 policy: LoopexComposition.ContextAdmissionTestPolicy,
                 model: @model,
                 sampling: %{"max_tokens" => @reply_tokens},
                 context_token_budget: value
               )

      assert File.ls!(root.state) == []
    end
  end

  defp start_composition(label, extra) do
    root = roots(label)

    assert {:ok, runtime} =
             LoopexComposition.TestHost.start(
               [
                 runtime_id: "context-#{label}",
                 state_root: root.state,
                 workspace: root.workspace,
                 policy: LoopexComposition.ContextAdmissionTestPolicy,
                 model: @model,
                 sampling: %{"max_tokens" => @reply_tokens}
               ] ++ extra
             )

    on_exit(fn -> stop_runtime(runtime) end)
    runtime
  end

  defp captured_configuration(runtime) do
    {:ok, %{control: control}} = Runtime.children(runtime)
    :sys.get_state(control).session_creation_defaults["initial_configuration"]
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
