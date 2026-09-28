defmodule LoopexRollbackOptionsCase do
  @moduledoc """
  ## Concept

  Compare each M6 durable option against the released and candidate composition
  entrypoints in their independently built source archives.

  ## Technical depth

  A malformed host credential plane is a late, non-credential sentinel. Released
  0.2 ignores the four new keys and reaches it for both values; M6 reaches it
  only for valid values. Each case owns a separate path under the rollback
  lane's temporary extraction.
  """

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:deny, :rollback_option_fixture}
  end

  @entries [:start, :with_runtime, :start_edges]
  @cases [
    model: {"openai:rollback", "missing-colon"},
    bounds: {%{max_turns: 1}, %{max_turns: 0}},
    sampling: {%{"max_tokens" => 1}, %{"max_tokens" => 0}},
    active_tools: {[], ["unknown.tool"]}
  ]

  @doc """
  ## Concept

  Execute the same rollback vectors against one built side.

  ## Technical depth

  No provider credential is needed or read. A callback or edge unexpectedly
  reached, an unexpected partial edge, or a different refusal fails the lane.
  """
  def run! do
    side = System.fetch_env!("ROLLBACK_OPTIONS_SIDE")
    base = System.fetch_env!("ROLLBACK_OPTIONS_ROOT")

    unless side in ["old", "new"], do: raise("rollback options: invalid side")

    for {key, {valid, invalid}} <- @cases,
        {kind, value} <- [valid: valid, invalid: invalid],
        entry <- @entries do
      root = Path.join(base, "#{entry}-#{key}-#{kind}")
      workspace = Path.join(root, "workspace")
      File.mkdir_p!(workspace)

      options =
        [
          policy: Policy,
          state_root: Path.join(root, "state"),
          workspace: workspace,
          runtime_id: "rollback-options-#{entry}-#{key}-#{kind}",
          credential_plane: nil
        ] ++ [{key, value}]

      expected_key = if side == "new" and kind == :invalid, do: key, else: :credential_plane
      expected = {:error, {:invalid_composition_option, expected_key}}
      actual = invoke(entry, options)

      if actual != expected do
        raise(
          "rollback options: #{side} #{entry} #{key} #{kind} expected #{inspect(expected)}, got #{inspect(actual)}"
        )
      end
    end

    IO.puts("rollback: #{side} durable option entrypoints 24/24")
  end

  defp invoke(:start, options), do: LoopexComposition.start(options)

  defp invoke(:with_runtime, options),
    do: LoopexComposition.with_runtime(options, fn _ -> raise("rollback callback ran") end)

  defp invoke(:start_edges, options) do
    case LoopexComposition.start_edges(options) do
      {:error, reason, partial} when partial == %{} -> {:error, reason}
      other -> other
    end
  end
end

LoopexRollbackOptionsCase.run!()
