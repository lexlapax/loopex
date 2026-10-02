defmodule Loopex.Runtime.CompactionSummary do
  @moduledoc """
  ## Concept

  A summary can replace history only after a naturally completed provider reply
  supplies valid bounded output. A usable-looking truncated reply cannot create
  a checkpoint. Its admitted usage still belongs to the maintenance attempt.

  ## Technical depth

  ADR 0043 orders completion before tool and output validation. The existing
  provider boundary admits the whole raw callback and normalizes its accounting;
  this module retains that canonical reply beside the summary verdict. V2
  replies classify as unknown completion. Unreadable callbacks supply no reply
  or accounting evidence. No tool is dispatched, output repaired or call retried.

  New output and prior checkpoint reuse share one closed summary/carry-forward
  validator. Canonical JSON limits include quotes and escaping: 4,096 bytes for
  summary, 2,048 for carry-forward, and 6,144 for their combined envelope. Each
  path is at most 1,024 UTF-8 bytes, with at most 32 entries in either path list.
  These checks admit content; progress and post-substitution limits remain the
  session owner's separate obligations before committing a checkpoint.
  """

  alias Loopex.Runtime.ProviderAttempt
  alias LoopexProtocol.Frame

  @doc false
  @spec admit(term(), map()) ::
          {:ok, map(), {:ok, map()} | {:error, atom()}} | {:error, :unreadable_model_answer}
  def admit(raw, request) do
    with {:ok, reply} <- ProviderAttempt.canonical_reply(raw, request, false) do
      {:ok, reply, output(reply)}
    end
  end

  # Concept: termination classification wins even when the output looks useful.
  # Technical depth: the canonical boundary supplies completion after admitting
  # every raw field. Parsing occurs only for natural completion with no calls.
  defp output(%{"completion" => completion}) when completion != "natural",
    do: {:error, :maintenance_summary_incomplete}

  defp output(%{"tool_calls" => [], "text" => text}) do
    text = Regex.replace(~r/\A[ \t\r\n]+|[ \t\r\n]+\z/, text, "")

    with {:ok, summary} <- Frame.decode(text, 65_536),
         :ok <- validate(summary) do
      {:ok, summary}
    else
      _invalid -> {:error, :maintenance_summary_invalid}
    end
  end

  defp output(_reply), do: {:error, :maintenance_summary_invalid}

  @doc false
  @spec validate(term()) :: :ok | {:error, :maintenance_summary_invalid}
  def validate(%{"summary" => summary, "carry_forward" => carry} = output)
      when map_size(output) == 2 do
    with true <- is_binary(summary) and byte_size(summary) <= 4_094,
         true <- String.valid?(summary),
         true <- valid_carry?(carry),
         true <- byte_size(json(summary)) <= 4_096,
         true <- byte_size(json(carry)) <= 2_048,
         true <- byte_size(json(output)) <= 6_144 do
      :ok
    else
      _invalid -> {:error, :maintenance_summary_invalid}
    end
  end

  def validate(_), do: {:error, :maintenance_summary_invalid}

  defp valid_carry?(%{"files_read" => read, "files_changed" => changed} = carry)
       when map_size(carry) == 2 and is_list(read) and is_list(changed) do
    Enum.all?([read, changed], fn paths ->
      length(paths) <= 32 and
        Enum.all?(paths, fn path ->
          is_binary(path) and byte_size(path) <= 1_024 and String.valid?(path)
        end)
    end)
  end

  defp valid_carry?(_), do: false

  defp json(value) do
    {:ok, framed} = Frame.encode(%{"v" => value})
    bytes = IO.iodata_to_binary(framed)
    binary_part(bytes, 5, byte_size(bytes) - 7)
  end
end
