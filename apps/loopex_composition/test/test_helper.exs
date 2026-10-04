Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.TestHost do
  @moduledoc false

  alias Loopex.LLM.ReqLLM

  @credential "loopex-composition-test-credential"

  def start(options), do: with_credential(fn -> LoopexComposition.start(options) end)

  def with_runtime(options, callback),
    do: with_credential(fn -> LoopexComposition.with_runtime(options, callback) end)

  defp with_credential(function) do
    variable = ReqLLM.credential_variable()
    System.put_env(variable, @credential)

    try do
      function.()
    after
      System.delete_env(variable)
    end
  end
end

defmodule LoopexComposition.PreparedSessionFixture do
  @moduledoc false

  def capture(configuration) do
    {:ok, genesis} =
      LoopexComposition.Ephemeral.Preflight.genesis(
        configuration,
        configuration.cwd,
        %{"ollama" => %{"credential" => %{"none" => true}}}
      )

    configuration
    |> Map.put(:genesis, genesis)
    |> Map.put(:model, genesis["initial_configuration"]["model"])
    |> Map.put(:context_token_budget, genesis["initial_configuration"]["context_token_budget"])
  end
end

ExUnit.start(exclude: [:real_provider])
