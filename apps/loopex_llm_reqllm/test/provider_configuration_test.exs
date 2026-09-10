defmodule Loopex.LLM.ReqLLM.ProviderConfigurationTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.ProviderConfiguration

  test "provider configuration requires explicit absolute paths and both exact digest forms" do
    assert {:ok, configuration} = ProviderConfiguration.validate(options())
    assert configuration.worker_path == "/host/loopex_provider"

    for key <- [:worker_path, :interpreter_path, :worker_sha256, :build_manifest_sha256] do
      assert {:error, :invalid_provider_configuration} =
               options() |> Keyword.delete(key) |> ProviderConfiguration.validate()
    end

    for value <- ["relative", "", nil, "/bad" <> <<0>>],
        key <- [:worker_path, :interpreter_path] do
      assert {:error, :invalid_provider_configuration} =
               options() |> Keyword.put(key, value) |> ProviderConfiguration.validate()
    end

    for value <- [String.duplicate("A", 64), String.duplicate("a", 63), "", nil],
        key <- [:worker_sha256, :build_manifest_sha256] do
      assert {:error, :invalid_provider_configuration} =
               options() |> Keyword.put(key, value) |> ProviderConfiguration.validate()
    end
  end

  test "unknown duplicate and malformed launch options refuse rather than select a default" do
    for invalid <- [
          options() ++ [worker_path: "/other"],
          options() ++ [unknown: true],
          [:not_a_pair],
          %{},
          options() ++ [cleanup_grace_ms: 0]
        ] do
      assert {:error, :invalid_provider_configuration} = ProviderConfiguration.validate(invalid)
    end
  end

  test "managed cleanup uses the retained period and unmanaged cleanup requires an explicit value" do
    assert {:ok, 999} =
             ProviderConfiguration.cleanup_period(%{cleanup_grace_ms: 1}, {:managed, self(), 999})

    assert {:ok, 17} = ProviderConfiguration.cleanup_period(%{cleanup_grace_ms: 17}, :unmanaged)

    assert {:error, :invalid_provider_cleanup} =
             ProviderConfiguration.cleanup_period(%{}, :unmanaged)

    for invalid <- [0, -1, nil, 18_446_744_073_709_551_616] do
      assert {:error, :invalid_provider_cleanup} =
               ProviderConfiguration.cleanup_period(%{}, {:managed, self(), invalid})
    end

    assert {:error, :invalid_provider_cleanup} =
             ProviderConfiguration.cleanup_period(%{}, {:managed, self()})
  end

  test "artifact validation hashes the actual worker bytes and requires an executable interpreter" do
    root =
      Path.join(System.tmp_dir!(), "loopex-provider-config-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    worker = Path.join(root, "loopex_provider")
    interpreter = Path.join(root, "escript")
    File.write!(worker, "actual independently hashed worker")
    File.write!(interpreter, "host supplied interpreter fixture")
    File.chmod!(interpreter, 0o700)

    digest =
      :crypto.hash(:sha256, "actual independently hashed worker") |> Base.encode16(case: :lower)

    configuration = %{worker_path: worker, interpreter_path: interpreter, worker_sha256: digest}
    assert :ok = ProviderConfiguration.verify_artifact(configuration)
    File.write!(worker, "different worker")

    assert {:error, :provider_artifact_unavailable} =
             ProviderConfiguration.verify_artifact(configuration)

    File.write!(worker, "actual independently hashed worker")
    File.chmod!(interpreter, 0o600)

    assert {:error, :provider_artifact_unavailable} =
             ProviderConfiguration.verify_artifact(configuration)
  end

  defp options do
    [
      worker_path: "/host/loopex_provider",
      interpreter_path: "/host/escript",
      worker_sha256: String.duplicate("a", 64),
      build_manifest_sha256: String.duplicate("b", 64)
    ]
  end
end
