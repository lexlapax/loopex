defmodule LoopexComposition.Ephemeral.PreflightTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral.Preflight

  defmodule Policy do
    @behaviour Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  test "option grammar wins before workspace and provider selection" do
    absent = Path.join(System.tmp_dir!(), "loopex-m6-preflight-absent-#{System.unique_integer()}")

    assert {:error, {:invalid_option, :unknown_key}} =
             Preflight.prepare(policy: Policy, cwd: absent, model: "missing:model", unknown: true)

    assert {:error, {:invalid_option, :duplicate_key}} =
             Preflight.prepare(policy: Policy, policy: Policy, cwd: absent)
  end

  test "workspace failure precedes skill, provider and shared startup" do
    absent = Path.join(System.tmp_dir!(), "loopex-m6-preflight-absent-#{System.unique_integer()}")

    assert {:error, {:composition, :workspace_unusable}} =
             Preflight.prepare(
               policy: Policy,
               cwd: absent,
               skills: ["missing"],
               model: "missing:model"
             )
  end

  test "named skill failure precedes provider selection" do
    assert {:error, {:composition, :skill_directory_unusable}} =
             Preflight.prepare(
               policy: Policy,
               cwd: File.cwd!(),
               skills: [".agents/skills/loopex-m6-absent-#{System.unique_integer()}"],
               model: "missing:model"
             )
  end

  test "provider selection precedes host-global guards" do
    previous = System.get_env("SSLKEYLOGFILE")
    System.put_env("SSLKEYLOGFILE", "/tmp/loopex-preflight-keylog-never-opened")

    try do
      assert {:error, {:composition, :unknown_provider}} =
               Preflight.prepare(policy: Policy, cwd: File.cwd!(), model: "missing:model")
    after
      restore_env("SSLKEYLOGFILE", previous)
    end
  end

  test "host guard refuses before starting a provider dependency" do
    previous = System.get_env("SSLKEYLOGFILE")
    System.put_env("SSLKEYLOGFILE", "/tmp/loopex-preflight-keylog-never-opened")

    try do
      assert {:error, {:composition, :ssl_key_log_enabled}} =
               Preflight.prepare(policy: Policy, cwd: File.cwd!(), model: "ollama:llama3.2")
    after
      restore_env("SSLKEYLOGFILE", previous)
    end
  end

  test "local selection reaches the guarded dependency and returns an explicit address" do
    assert {:ok, selection} =
             Preflight.prepare(policy: Policy, cwd: File.cwd!(), model: "ollama:llama3.2")

    assert selection.provider.provider == :ollama
    assert selection.provider.credential_variable == nil
    assert String.starts_with?(selection.base_url, "http://")
    assert selection.skills.shadowed_skills == []
    assert is_map(selection.skills.manifest)
  end

  test "a hosted address refuses HTTP without reading a key" do
    assert {:error, {:composition, :provider_base_url_unsupported}} =
             Preflight.prepare(
               policy: Policy,
               cwd: File.cwd!(),
               model: "openai:gpt-4o-mini",
               base_url: "http://example.test/v1"
             )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
