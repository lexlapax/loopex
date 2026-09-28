defmodule LoopexCli.CredentialCacheTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.CredentialRegistry
  alias LoopexCli.CredentialCache
  alias LoopexComposition.CredentialHost

  test "one real host custody serves two planes in a command process" do
    variable = ReqLLM.credential_variable()
    System.put_env(variable, "cache-test-inert-key")

    try do
      assert {:ok, host} = CredentialCache.host()
      assert System.get_env(variable) == nil
      assert {:ok, ^host} = CredentialCache.host()

      assert {:ok, first} = CredentialCache.plane()
      assert :ok = CredentialHost.release_plane(first)
      refute Process.alive?(first.capability_pid)

      registry = Keyword.fetch!(first.model_options, :credential_registry)
      token = Keyword.fetch!(first.model_options, :credential_token)
      assert {:ok, _custody} = CredentialRegistry.route(registry, token)

      assert {:ok, second} = CredentialCache.plane()
      assert second.capability_pid != first.capability_pid
      assert :ok = CredentialHost.release_plane(second)
      refute Process.alive?(second.capability_pid)
      assert {:ok, ^host} = CredentialCache.host()
    after
      System.delete_env(variable)
    end
  end
end
