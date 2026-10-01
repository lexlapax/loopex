defmodule LoopexComposition.Ephemeral.Options do
  @moduledoc false

  @keys [
    :policy,
    :model,
    :req_llm,
    :tools,
    :skills,
    :cwd,
    :max_steps,
    :deadline_ms,
    :max_tokens,
    :context_token_budget,
    :timeout,
    :base_url,
    :maintenance_instructions,
    :provider_bindings,
    :maintenance_model
  ]
  @uint64_max 18_446_744_073_709_551_615

  # Concept: grammar validation precedes every composition effect.
  # Technical depth: absent workspace and address values remain nil until their
  # later guards resolve defaults. Explicit nil still fails the value grammar.
  def parse(options) do
    with :ok <- outer(options, @keys) do
      Enum.reduce_while(@keys, {:ok, %{}}, fn key, {:ok, normalized} ->
        result =
          case Keyword.fetch(options, key) do
            {:ok, value} -> validate(key, value)
            :error -> default(key, normalized)
          end

        case result do
          {:ok, value} -> {:cont, {:ok, Map.put(normalized, key, value)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  def ask_options(options, timeout) do
    with :ok <- outer(options, [:timeout]) do
      case Keyword.fetch(options, :timeout) do
        {:ok, value} -> validate(:timeout, value)
        :error -> {:ok, timeout}
      end
    end
  end

  def prompt(value) when is_binary(value) do
    cond do
      byte_size(value) == 0 -> {:error, {:invalid_prompt, :empty}}
      byte_size(value) > 32_768 -> {:error, {:invalid_prompt, :too_large}}
      not String.valid?(value) -> {:error, {:invalid_prompt, :invalid_utf8}}
      true -> :ok
    end
  end

  def prompt(_), do: {:error, {:invalid_prompt, :invalid_utf8}}

  defp default(:policy, _), do: {:error, {:composition, :host_policy_required}}

  defp default(:model, _),
    do: validate(:model, System.get_env("LOOPEX_MODEL") || "ollama:llama3.2")

  defp default(key, _) when key in [:req_llm, :cwd, :base_url], do: {:ok, nil}
  defp default(:tools, _), do: {:ok, :coding}
  defp default(:skills, _), do: {:ok, []}
  defp default(:max_steps, _), do: {:ok, 16}
  defp default(:deadline_ms, _), do: {:ok, 600_000}
  defp default(:max_tokens, _), do: {:ok, 4096}
  defp default(:context_token_budget, _), do: {:ok, 8192}
  defp default(:timeout, normalized), do: {:ok, min(normalized.deadline_ms + 30_000, @uint64_max)}
  defp default(:maintenance_instructions, _), do: {:ok, nil}
  defp default(key, _) when key in [:provider_bindings, :maintenance_model], do: {:ok, nil}

  defp validate(:provider_bindings, value) do
    with {:ok, _} <- LoopexComposition.ProviderBindings.validate(value), do: {:ok, value}
  end

  defp validate(:maintenance_model, nil), do: {:ok, nil}

  defp validate(:maintenance_model, value),
    do: accept(:maintenance_model, value, LoopexComposition.ProviderBindings.valid_model?(value))

  defp validate(:maintenance_instructions, value) do
    with {:ok, _capture} <- Loopex.Runtime.MaintenanceConfiguration.capture_instructions(value),
         do: {:ok, value}
  end

  defp validate(:policy, value) do
    valid =
      is_atom(value) and not is_nil(value) and Code.ensure_loaded?(value) and
        function_exported?(value, :decide, 1) and text?(inspect(value), 256)

    accept(:policy, value, valid)
  end

  defp validate(:model, value) do
    valid =
      text?(value, 512) and
        case String.split(value, ":", parts: 2) do
          [prefix, model] -> prefix != "" and model != ""
          _ -> false
        end

    accept(:model, value, valid)
  end

  defp validate(:req_llm, value), do: accept(:req_llm, value, value == :host_started)
  defp validate(:tools, value), do: accept(:tools, value, value in [:none, :coding, :read_only])

  defp validate(:skills, value) do
    cond do
      not is_list(value) or not proper_list?(value) -> invalid(:skills)
      length(value) > 4 -> invalid(:too_many_skills)
      true -> accept(:skills, value, Enum.all?(value, &path?/1))
    end
  end

  defp validate(key, value) when key in [:cwd, :base_url], do: accept(key, value, path?(value))

  defp validate(:max_tokens, value),
    do: accept(:max_tokens, value, positive_integer?(value, 1_000_000))

  defp validate(key, value), do: accept(key, value, positive_integer?(value, @uint64_max))

  defp positive_integer?(value, max), do: is_integer(value) and value >= 1 and value <= max

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp path?(value), do: text?(value, 65_536) and not String.contains?(value, <<0>>)
  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_), do: false
  defp accept(_, value, true), do: {:ok, value}
  defp accept(key, _, false), do: invalid(key)

  defp outer(options, keys) do
    cond do
      not Keyword.keyword?(options) ->
        invalid(:options)

      Enum.any?(options, fn {key, _} -> key not in keys end) ->
        invalid(:unknown_key)

      length(Keyword.keys(options)) != length(Enum.uniq(Keyword.keys(options))) ->
        invalid(:duplicate_key)

      true ->
        :ok
    end
  end

  defp invalid(reason), do: {:error, {:invalid_option, reason}}
end
