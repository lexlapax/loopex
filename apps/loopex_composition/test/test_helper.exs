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

ExUnit.start(exclude: [:real_provider])
