# Concept: the shared provider fixture loads only under an explicit temporary home.
# Technical depth: Core's fixture guard runs during require, before case setup;
# restore the host environment immediately after loading these test modules.
fixture_home =
  Path.join(System.tmp_dir!(), "model-wrapper-load-#{System.unique_integer([:positive])}")

File.mkdir_p!(fixture_home)
prior_home = System.get_env("LOOPEX_HOME")
System.put_env("LOOPEX_HOME", fixture_home)

try do
  Code.require_file(
    "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
    __DIR__
  )
after
  if prior_home,
    do: System.put_env("LOOPEX_HOME", prior_home),
    else: System.delete_env("LOOPEX_HOME")

  File.rm_rf!(fixture_home)
end

defmodule LoopexComposition.ModelTest do
  use ExUnit.Case, async: false
  alias LoopexComposition.{Model, ProviderBindings}
  alias Loopex.Runtime.{Instructions, SessionConfiguration}

  setup do
    root =
      Path.join(System.tmp_dir!(), "model-wrapper-case-#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)
    previous = Map.new(~w(LOOPEX_HOME LOOPEX_WORKSPACE), &{&1, System.get_env(&1)})
    System.put_env("LOOPEX_HOME", home)
    System.put_env("LOOPEX_WORKSPACE", workspace)

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  defmodule Recording do
    @moduledoc false
    @behaviour Loopex.Model
    @impl true
    def complete(request, options, progress) do
      send(Keyword.fetch!(options, :observer), {:completion, request, options, progress})
      {:ok, Keyword.fetch!(options, :reply)}
    end
  end

  test "completion forwards the exact underlying options, request, progress and result" do
    reply = %{retained: "adapter-result"}
    original = [observer: self(), reply: reply, private_key: "original-options"]

    reference =
      Model.reference(%{module: Recording, model: "recording:v1", options: original},
        provider_bindings: bindings(),
        workspace: "HOST_WORKSPACE_ONLY",
        state_root: "HOST_PLACEMENT_ONLY"
      )

    assert Enum.sort(Map.keys(reference)) == [:model, :module, :options]
    assert reference.options[:host_options] == [provider_bindings: bindings()]
    refute :erlang.term_to_binary(reference.options) =~ "HOST_WORKSPACE_ONLY"
    refute :erlang.term_to_binary(reference.options) =~ "HOST_PLACEMENT_ONLY"
    request = %{model: "recording:v1", private: "exact-request"}
    progress = fn _ -> :ok end
    assert {:ok, ^reply} = Model.complete(request, reference.options, progress)
    assert_receive {:completion, ^request, ^original, ^progress}
    refute Keyword.has_key?(original, :host_options)
    refute Keyword.has_key?(original, :adapter)
  end

  test "the actual ReqLLM and InProcess adapters preserve their refusal through the wrapper" do
    progress = Loopex.Model.discard_progress()

    for adapter <- [Loopex.LLM.ReqLLM, Loopex.LLM.ReqLLM.InProcess] do
      original = [not_an_adapter_option: "PRIVATE_WRAPPER_CANARY"]

      reference =
        Model.reference(%{module: adapter, model: "openai:test", options: original},
          provider_bindings: bindings()
        )

      assert Model.complete(%{}, reference.options, progress) ==
               adapter.complete(%{}, original, progress)
    end
  end

  test "wrapped ReqLLM succeeds through its real isolated local transport and retires it" do
    fixture = Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply)
    request = Loopex.LLM.ReqLLM.ProviderIsolationFixture.request()

    reference =
      Model.reference(
        %{module: Loopex.LLM.ReqLLM, model: request.model, options: fixture.options},
        provider_bindings: bindings()
      )

    assert {:ok, reply} =
             Model.complete(request, reference.options, Loopex.Model.discard_progress())

    assert reply.text == "loopex"
    assert reply.canonical_request_bytes == request.canonical_request_bytes
    assert reply.staged_request_digest == request.staged_request_digest
    assert Loopex.LLM.ReqLLM.ProviderIsolationFixture.methods(fixture) == ["POST"]
    assert [{_body, true}] = Loopex.LLM.ReqLLM.ProviderIsolationFixture.events(fixture)
    Loopex.LLM.ReqLLM.ProviderIsolationFixture.assert_gone(fixture)
  end

  test "explicit admitted host routes resolve an authored alias and preserve captured instructions" do
    current = current()

    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "changed.v1",
        "base" => "exact changed bytes 猫",
        "environment" => "",
        "appendix" => ""
      })

    authored = %{
      "model" => "anthropic:claude-haiku-4-5",
      "reasoning" => "high",
      "instructions" => instructions
    }

    reference = reference(provider_bindings: bindings())

    assert {:ok, candidate} =
             Model.prepare_configuration(current, authored, [], context(), reference.options)

    assert candidate["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert candidate["configuration_version"] == current["configuration_version"] + 1
    assert candidate["instructions"] == instructions
    assert candidate["reasoning"] == "high"
    assert :ok = SessionConfiguration.validate_candidate(current, authored, candidate, [])
    refute :erlang.term_to_binary(candidate) =~ "HOST_REFERENCE_ONLY_KEY"
  end

  test "omitted model remains exact and explicit ceilings retain their authored origins" do
    {:ok, current} =
      ProviderBindings.resolve_configuration(
        declaration()
        |> Map.put("context_token_budget", 8192)
        |> Map.put("system_class_tokens", 1000),
        bindings(),
        []
      )

    reference = reference(provider_bindings: bindings())

    assert {:ok, candidate} =
             Model.prepare_configuration(
               current,
               %{"reasoning" => "low"},
               [],
               context(),
               reference.options
             )

    assert candidate["model"] == current["model"]
    assert candidate["context_token_budget"] == 8192
    assert candidate["system_class_tokens"] == 1000
    assert candidate["budget_origins"] == current["budget_origins"]
  end

  test "legacy, absent and unadmitted routes cannot prepare a configuration" do
    current = current()
    authored = %{"model" => "anthropic:claude-haiku-4-5"}

    for host <- [
          [],
          [provider_bindings: %{"openai" => env("OTHER_HOST_KEY")}],
          [provider_bindings: %{"ollama" => %{"credential" => %{"none" => true}}}]
        ] do
      reference = reference(host)

      assert {:error, :configuration_not_prepared} =
               Model.prepare_configuration(current, authored, [], context(), reference.options)
    end

    reference = reference(provider_bindings: bindings())
    expired = %{context() | deadline_monotonic_ms: System.monotonic_time(:millisecond)}

    assert {:error, :configuration_not_prepared} =
             Model.prepare_configuration(current, authored, [], expired, reference.options)
  end

  defp reference(host),
    do:
      Model.reference(
        %{module: Recording, model: "anthropic:claude-haiku-4-5-20251001", options: []},
        host
      )

  defp context,
    do: %{
      deadline_monotonic_ms: System.monotonic_time(:millisecond) + 60_000,
      cleanup_grace_ms: 5_000
    }

  defp current do
    {:ok, current} = ProviderBindings.resolve_configuration(declaration(), bindings(), [])
    current
  end

  defp declaration do
    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "host.v1",
        "base" => "exact initial instructions",
        "environment" => "",
        "appendix" => ""
      })

    %{
      "model" => "anthropic:claude-haiku-4-5",
      "reasoning" => "default",
      "configuration_version" => 1,
      "max_tokens" => 8192,
      "instructions" => instructions
    }
  end

  defp bindings, do: %{"anthropic" => env("HOST_REFERENCE_ONLY_KEY")}
  defp env(name), do: %{"credential" => %{"env" => name}}
end
