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

  @prompt "Reply with exactly one word: loopex"

  @tag :real_provider
  test "one real model call completes through the model boundary" do
    model_spec = Adapter.default_model()

    case Adapter.complete(model_spec, @prompt) do
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

      {:error, {:credential_unset, variable}} ->
        # Concept: a missing credential is unavailable evidence, and unavailable
        # evidence fails. Skipping would report a pass for a lane that never ran.
        flunk("""
        evidence unavailable: #{variable} is not set

        Outcome 7 requires one real model call from the adapter application. \
        Export #{variable} for a provider that serves #{model_spec} and invoke \
        this lane again. A skipped lane is not a pass.
        """)

      {:error, {:unresolved_model, spec, reason}} ->
        flunk("evidence unavailable: #{inspect(spec)} did not resolve (#{inspect(reason)})")

      {:error, {:provider_call_failed, detail}} ->
        flunk("the real model call failed: #{detail}")
    end
  end
end
