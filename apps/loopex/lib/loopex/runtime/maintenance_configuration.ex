defmodule Loopex.Runtime.MaintenanceConfiguration do
  @moduledoc """
  ## Concept

  A runtime carries explicitly selected summarizer settings independently of its
  conversation model. Missing settings remain unconfigured.

  ## Technical depth

  ADR 0043's instruction block and resolved model map are bounded plain data.
  Startup validates their shape and model capacity; episode admission separately
  requires verified thinking-off settings. No provider, file, environment or
  catalog is consulted, and no ordinary instruction or model default is inherited.
  """

  alias Loopex.Runtime.SessionConfiguration
  @levels ~w(default none low medium high)
  @version ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  @doc """
  ## Concept

  Capture an explicit maintenance instruction block without changing its bytes.

  ## Technical depth

  Nil is unconfigured. The closed input has version and body, bounded to 64
  identifier bytes and 2,048 nonempty UTF-8 bytes respectively. The private
  capture retains version, exact version-colon-space-body rendering and its
  SHA-256 digest. An admitted episode copies this capture rather than rereading
  current host settings during recovery.
  """
  @spec capture_instructions(term()) ::
          {:ok, map() | nil} | {:error, :maintenance_instructions_invalid}
  def capture_instructions(nil), do: {:ok, nil}

  def capture_instructions(%{"version" => version, "body" => body} = input)
      when map_size(input) == 2 do
    if is_binary(version) and byte_size(version) in 1..64 and String.valid?(version) and
         Regex.match?(@version, version) and is_binary(body) and byte_size(body) in 1..2048 and
         String.valid?(body) do
      bytes = version <> ": " <> body

      {:ok,
       %{
         "version" => version,
         "rendered_bytes" => bytes,
         "digest" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
       }}
    else
      {:error, :maintenance_instructions_invalid}
    end
  end

  def capture_instructions(_), do: {:error, :maintenance_instructions_invalid}

  @doc """
  ## Concept

  Admit a runtime's resolved summarizer selection without requiring it to be
  usable for a new maintenance episode yet.

  ## Technical depth

  The map contains exactly model, reasoning, model_capabilities and
  provider_mapping. It shares ordinary metadata bounds, but the fixed summary
  reserve requires a known context window above 1,024 and output capacity at
  least 1,024. Unknown capacities remain nil. Well-formed unsupported reasoning
  is retained so episode admission can report its distinct refusal.
  """
  @spec validate_model(term()) :: {:ok, map() | nil} | {:error, :maintenance_model_invalid}
  def validate_model(nil), do: {:ok, nil}

  def validate_model(
        %{
          "model" => model,
          "reasoning" => level,
          "model_capabilities" => capabilities,
          "provider_mapping" => mapping
        } = input
      )
      when map_size(input) == 4 do
    with true <- level in @levels,
         :ok <- SessionConfiguration.validate_model_metadata(model, capabilities, mapping),
         window = capabilities["context_window"],
         output = capabilities["output_limit"],
         true <- is_nil(window) or window > 1024,
         true <- is_nil(output) or output >= 1024 do
      {:ok, input}
    else
      _ -> {:error, :maintenance_model_invalid}
    end
  end

  def validate_model(_), do: {:error, :maintenance_model_invalid}

  @doc """
  ## Concept

  Require an explicit thinking-off model before admitting maintenance work.

  ## Technical depth

  Core checks generic declared facts only: reasoning none, thinking_disabled true
  and continuation_required false. Composition additionally proves these claims
  from its registered native mapping before startup. A direct embedder's reply
  still requires natural completion when the summary settles.
  """
  @spec eligible_model(term()) :: :ok | {:error, atom()}
  def eligible_model(nil), do: {:error, :maintenance_model_unconfigured}

  def eligible_model(input) do
    with {:ok, model} <- validate_model(input),
         true <- model["reasoning"] == "none",
         true <- model["provider_mapping"]["thinking_disabled"],
         false <- model["provider_mapping"]["continuation_required"] do
      :ok
    else
      _ -> {:error, :maintenance_reasoning_unsupported}
    end
  end
end
