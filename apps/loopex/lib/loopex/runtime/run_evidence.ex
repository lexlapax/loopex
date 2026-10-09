defmodule Loopex.Runtime.RunEvidence do
  @moduledoc """
  ## Concept

  Reads one run's admission, ending and usage from retained history without
  starting, attaching or activating its session.

  ## Technical depth

  ADR 0069's private query. Control authenticates the runtime capability and
  runs this read under its bounded Store-read guardian. The session must have
  been created by this runtime; its complete private prefix through the
  captured ownership head is replayed by `SessionState.run_evidence/3`, so the
  answer is the reducer's own fold and identical after restart. No record is
  written and no answer is projected onto a wire.
  """

  alias Loopex.Runtime.SessionState
  alias Loopex.Store

  @page 256

  @doc false
  @spec read(Store.t(), binary(), term(), term()) ::
          {:ok, map()} | {:error, :unknown_run | :runtime_unavailable}
  # Concept: ADR 0069 closes the answer to a map, unknown_run or runtime_unavailable.
  # Technical depth: Store unavailability, a gapped page and history the reducer
  # refuses all mean no evidence can be given, so they share runtime_unavailable;
  # none is ever reported as an unknown run or as usage.
  def read(store, runtime_id, session_id, run_id) do
    with true <- identifier?(session_id) and is_binary(run_id) and byte_size(run_id) in 1..8_192,
         {:historical, _} <-
           Store.creation_provenance(store, runtime_id, %{kind: :session, session_id: session_id}),
         {:ok, %{journal_version: head}} when is_integer(head) and head > 0 <-
           Store.ownership_head(store, session_id, "session"),
         {:ok, records} <- load(store, session_id, 0, head, []) do
      case SessionState.run_evidence(session_id, records, run_id) do
        {:ok, evidence} -> {:ok, evidence}
        {:error, :unknown_run} -> {:error, :unknown_run}
        {:error, _invalid} -> {:error, :runtime_unavailable}
      end
    else
      false -> {:error, :unknown_run}
      :absent -> {:error, :unknown_run}
      :conflict -> {:error, :unknown_run}
      _unavailable -> {:error, :runtime_unavailable}
    end
  end

  # Concept: the answer covers exactly the captured prefix, never a later append.
  # Technical depth: pages must be consecutive; a short or gapped page is
  # unavailable evidence rather than a shorter history.
  defp load(_store, _session, through, through, acc), do: {:ok, Enum.reverse(acc)}

  defp load(store, session, after_version, through, acc) do
    case Store.load_records(store, session, after_version, min(@page, through - after_version)) do
      {:ok, [_ | _] = records} ->
        Enum.reduce_while(records, {:ok, after_version, acc}, fn record, {:ok, last, rows} ->
          if record.journal_version == last + 1 and record.journal_version <= through,
            do: {:cont, {:ok, record.journal_version, [record | rows]}},
            else: {:halt, :error}
        end)
        |> case do
          {:ok, last, rows} -> load(store, session, last, through, rows)
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..256
end
