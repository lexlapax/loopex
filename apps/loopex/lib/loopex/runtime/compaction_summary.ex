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

  Owner capture adds the covered-record digest and preserves inherited source
  omissions. Ordinary projection renders the exact six-member checkpoint JSON
  as one user message beside its checkpoint source reference. These pure steps
  neither commit a checkpoint nor verify its retained coverage.
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

  # Concept: replay validates summary output from the exact admitted reply.
  # Technical depth: the owner first validates the closed v3 settlement against
  # its captured request. This shares live output validation without rebuilding
  # a raw callback, consulting a provider or changing retained usage.
  @doc false
  @spec from_reply(map()) :: {:ok, map()} | {:error, atom()}
  def from_reply(reply), do: output(reply)

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

  # Concept: later summaries cannot erase a prior checkpoint's omissions.
  # Technical depth: only the owner supplies the covered-record digest and this
  # source's excerpt classification. The model supplies exactly the existing
  # summary/carry-forward object; its output cannot set either provenance field.
  @doc false
  @spec capture(map(), binary(), map() | nil, boolean()) ::
          {:ok, map()} | {:error, :context_projection_invalid}
  def capture(output, digest, prior, source_excerpted) when is_boolean(source_excerpted) do
    with :ok <- validate(output),
         true <- valid_digest?(digest),
         true <- is_nil(prior) or validate_prior(prior) == :ok do
      inherited = not is_nil(prior) and prior["source_excerpted"]

      {:ok,
       Map.merge(output, %{
         "covered_range_digest" => digest,
         "source_excerpted" => inherited or source_excerpted
       })}
    else
      _ -> {:error, :context_projection_invalid}
    end
  end

  def capture(_, _, _, _), do: {:error, :context_projection_invalid}

  # Concept: a retained summary is conversation data with explicit provenance.
  # Technical depth: ADR 0043 renders exactly one canonical user message. The
  # owner supplies the committed checkpoint identity and covered-record digest;
  # this pure projection grants no authority and proves no coverage by itself.
  @doc false
  @spec project(binary(), map()) :: {:ok, {map(), map()}} | {:error, :context_projection_invalid}
  def project(checkpoint_id, prior)
      when is_binary(checkpoint_id) and byte_size(checkpoint_id) in 1..256 do
    with true <- String.valid?(checkpoint_id),
         :ok <- validate_prior(prior) do
      content =
        prior
        |> Map.put("kind", "compaction_summary")
        |> Map.put("checkpoint_id", checkpoint_id)
        |> json()

      {:ok,
       {%{"kind" => "compaction_summary", "checkpoint_id" => checkpoint_id},
        %{"role" => "user", "content" => content}}}
    else
      _ -> {:error, :context_projection_invalid}
    end
  end

  def project(_, _), do: {:error, :context_projection_invalid}

  # Concept: a new source preserves the previous checkpoint's omission flag.
  # Technical depth: source reuse and ordinary rendering admit the same closed
  # four-member prior data. Owner capture separately ORs this flag with its
  # current excerpt choice; model output never supplies it.
  @doc false
  @spec validate_prior(term()) :: :ok | {:error, :context_projection_invalid}
  def validate_prior(
        %{
          "covered_range_digest" => digest,
          "summary" => summary,
          "carry_forward" => carry,
          "source_excerpted" => excerpted
        } = prior
      ) do
    with true <- map_size(prior) == 4 and valid_digest?(digest),
         true <- is_boolean(excerpted),
         :ok <- validate(%{"summary" => summary, "carry_forward" => carry}) do
      :ok
    else
      _ -> {:error, :context_projection_invalid}
    end
  end

  def validate_prior(_), do: {:error, :context_projection_invalid}

  defp valid_digest?(digest),
    do:
      is_binary(digest) and byte_size(digest) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

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
