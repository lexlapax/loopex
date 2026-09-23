Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.AdapterTest do
  @moduledoc """
  ## Concept

  Everything about the adapter boundary that can be proved without spending a
  token: that the pinned model specification still names a real catalog entry,
  that identity crosses the boundary as plain non-secret data, and that missing
  credential custody is reported before provider transport is dispatched.

  ## Technical depth

  These tests are deliberately *not* in `provider_test.exs`, which the M0 gate
  requires to hold only `real_provider`-tagged tests. None of them reaches a
  provider: catalog resolution reads bundled data, and the credential case
  returns before dispatch.
  """

  use ExUnit.Case, async: true

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
    fixture = Fixture.new()
    {:ok, custody} = Loopex.LLM.ReqLLM.CredentialCustody.reference(fixture.custody_pid)
    assert :ok = Loopex.LLM.ReqLLM.CredentialCustody.rotate(custody, nil)

    assert Fixture.complete(fixture) ==
             {:error, {:not_dispatched, "model_call_failed"}}

    assert Fixture.canaries(fixture) == 0
    assert Fixture.count(fixture) == 0
    Fixture.assert_gone(fixture)
  end

  test "the adapter library has no credential environment read" do
    # Concept: credentials enter through host-owned custody only.
    # Technical depth: the worker still reads its non-secret crash policy and
    # the launcher enumerates names solely to scrub the first child image.
    for path <- Path.wildcard(Path.join(__DIR__, "../lib/**/*.ex")) do
      source = File.read!(path)

      reads =
        ~r/System\.get_env\(([^)]*)\)/
        |> Regex.scan(source)
        |> Enum.map(fn [_match, argument] -> String.trim(argument) end)

      expected =
        case Path.basename(path) do
          "provider_worker.ex" -> ["\"ERL_CRASH_DUMP\"", "\"ERL_CRASH_DUMP_SECONDS\""]
          "provider_launcher.ex" -> [""]
          _ -> []
        end

      assert reads == expected
      refute source =~ ~r/System\.fetch_env!?\(/

      # Every other way to read the environment is absent: the Erlang calls
      # and a captured or applied `System.get_env`. The whole-environment read
      # is the launcher's one allowed name enumeration, counted above.
      for form <- [
            ~r/:os\.getenv/,
            ~r/:os\.env\b/,
            ~r/&System\.get_env\//,
            ~r/&System\.fetch_env/,
            ~r/apply\(\s*System\s*,\s*:(get|fetch)_env/
          ] do
        refute source =~ form, "#{Path.basename(path)} reads the environment as #{inspect(form)}"
      end
    end
  end
end
