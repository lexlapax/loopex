Code.require_file("support/provider_build_fixture.exs", __DIR__)
Code.require_file("support/provider_phase_diagnostic.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderTest do
  @moduledoc """
  ## Concept

  Outcome 7's explicitly invoked lane: one real model call through the adapter's
  model boundary, against a real provider.

  ## Technical depth

  This file holds nothing but `real_provider`-tagged tests. The M0 gate runs it
  unfiltered as well and requires that run to execute none of them, so an
  untagged test added here would put a provider call into the default suite and
  fail the gate. Anything that does not call a provider belongs in
  `adapter_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderBuildFixture

  @prompt "Reply with exactly one word: loopex"

  @tag :real_provider
  test "one real model call completes through the model boundary" do
    model_spec = Adapter.default_model()

    root =
      Path.join(System.tmp_dir!(), "loopex-real-provider-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    options = ProviderBuildFixture.options!(root) ++ [cleanup_grace_ms: 2_000]

    Loopex.LLM.ReqLLM.ProviderPhaseDiagnostic.capture(fn ->
      case Adapter.complete_prompt(model_spec, @prompt, options) do
        {:ok, reply} ->
          # Concept: retained non-secret identity. The credential never appears
          # here; provider, model, and endpoint class are what a reviewer needs to
          # judge the claim, and they are printed so the operator can transcribe
          # them into docs/evidence/M0-provider.md.
          IO.puts("""
          real-provider lane identity
            provider: #{reply.identity.provider}
            model:    #{reply.identity.model}
            endpoint: #{reply.identity.endpoint}
            usage:    input=#{inspect(reply.usage.input_tokens)} output=#{inspect(reply.usage.output_tokens)}
          """)

          assert {:ok, identity} = Adapter.identity(model_spec)
          assert reply.identity == identity
          assert is_binary(reply.text)
          assert String.trim(reply.text) != "", "the provider returned no assistant text"

        {:error, {:not_dispatched, "model_call_failed"}} ->
          # Concept: a refusal before the transport - a missing credential, an
          # unresolved model, an invalid request - is unavailable evidence, and
          # unavailable evidence fails. Skipping would report a pass for a lane
          # that never ran. ADR 0018 bounds the reason to this generic shape, so the
          # credential variable is named here rather than read from the refusal.
          variable = Adapter.credential_variable()

          flunk("""
          evidence unavailable: the adapter refused before its transport

          Outcome 7 requires one real model call from the adapter application. \
          Export #{variable} for a provider that serves #{model_spec} and invoke \
          this lane again. A skipped lane is not a pass.
          """)

        {:error, {:dispatched_or_unknown, "model_call_failed"}} ->
          flunk("the real model call failed after the transport was entered")
      end
    end)
  end
end
