defmodule Loopex.LLM.ReqLLM.AdapterTest do
  @moduledoc """
  ## Concept

  Everything about the adapter boundary that can be proved without spending a
  token: that the pinned model specification still names a real catalog entry,
  that identity crosses the boundary as plain non-secret data, and that a missing
  credential is reported before anything is dispatched.

  ## Technical depth

  These tests are deliberately *not* in `provider_test.exs`, which the M0 gate
  requires to hold only `real_provider`-tagged tests. None of them reaches a
  provider: catalog resolution reads bundled data, and the credential case
  returns before dispatch.
  """

  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM, as: Adapter

  test "the pinned reference model resolves to a non-secret identity" do
    assert {:ok, identity} = Adapter.identity(Adapter.default_model())

    assert identity.provider == "anthropic"
    assert is_binary(identity.model) and identity.model != ""
    assert String.starts_with?(identity.endpoint, "https://")

    # Concept: identity is plain boundary data. A provider struct crossing here
    # would leak an implementation type into whatever records the evidence.
    assert Map.keys(identity) |> Enum.sort() == [:endpoint, :model, :provider]
    assert Enum.all?(Map.values(identity), &is_binary/1)
  end

  test "an unresolvable model specification is an error, not a guessed identity" do
    assert {:error, {:unresolved_model, "nosuchprovider:nothing", _reason}} =
             Adapter.identity("nosuchprovider:nothing")
  end

  test "a missing credential is reported before any provider is called" do
    variable = Adapter.credential_variable()
    assert variable == "LOOPEX_PROVIDER_API_KEY"

    # Concept: a test must not disarm the lane that carries the real-path evidence.
    #
    # Technical depth: the variable is restored afterwards so this test cannot
    # disarm the real-provider lane for a later run in the same VM. `async:
    # false` keeps the mutation off concurrent tests.
    previous = System.get_env(variable)
    System.delete_env(variable)

    try do
      assert Adapter.complete(Adapter.default_model(), "unreachable") ==
               {:error, {:credential_unset, variable}}
    after
      if previous, do: System.put_env(variable, previous)
    end
  end

  test "the adapter reads exactly one environment variable" do
    # Concept: other provider keys present on the host are not this lane's to
    # spend. Drift protection against a fallback read being added later; it
    # proves what the adapter reads, not what ReqLLM would read on its own.
    source = File.read!(Path.join(__DIR__, "../lib/loopex/llm/req_llm.ex"))

    reads =
      ~r/System\.get_env\(([^)]*)\)/
      |> Regex.scan(source)
      |> Enum.map(fn [_match, argument] -> String.trim(argument) end)

    assert reads == ["@credential_variable"]
  end
end
