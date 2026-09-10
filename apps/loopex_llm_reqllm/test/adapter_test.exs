Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

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
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture

  setup do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    :ok
  end

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
    fixture = Fixture.new()

    try do
      assert Fixture.complete(fixture) ==
               {:error, {:not_dispatched, "model_call_failed"}}

      assert Fixture.canaries(fixture) == 0
      assert Fixture.count(fixture) == 0
      Fixture.assert_gone(fixture)
    after
      if previous, do: System.put_env(variable, previous)
    end
  end

  test "the adapter reads exactly one credential environment variable" do
    # Concept: other provider keys present on the host are not this lane's to
    # spend. Drift protection against a fallback read being added later; it
    # proves what the adapter reads, not what ReqLLM would read on its own.
    # ADR 0019 moves the sole credential read into the raw sender. The worker
    # reads only its non-secret crash policy, and the launcher enumerates names
    # solely to clear the first image's environment; neither is a key fallback.
    for path <- Path.wildcard(Path.join(__DIR__, "../lib/**/*.ex")) do
      source = File.read!(path)

      reads =
        ~r/System\.get_env\(([^)]*)\)/
        |> Regex.scan(source)
        |> Enum.map(fn [_match, argument] -> String.trim(argument) end)

      expected =
        case Path.basename(path) do
          "provider_bridge.ex" -> ["\"LOOPEX_PROVIDER_API_KEY\""]
          "provider_worker.ex" -> ["\"ERL_CRASH_DUMP\"", "\"ERL_CRASH_DUMP_SECONDS\""]
          "provider_launcher.ex" -> [""]
          _ -> []
        end

      assert reads == expected
      refute source =~ ~r/System\.fetch_env!?\(/
    end
  end
end
