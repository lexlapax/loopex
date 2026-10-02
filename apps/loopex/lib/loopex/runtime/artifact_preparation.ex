defmodule Loopex.Runtime.ArtifactPreparation do
  @moduledoc """
  ## Concept

  An inline result receives durable storage credit before retention. Recovery
  resumes the same reservation and completion publishes only a reference to
  the exact original receipt text.

  ## Technical depth

  ADR 0041 fixes one episode per staging identity, oldest-first sources, at
  most 16 source records and 1,048,576 encoded source-record bytes. The fixed
  60,000-ms cutoff is shortened by an already committed run deadline. This
  pure codec serves proposal construction and journal replay; SessionState
  supplies the independently reconstructed source and staging identity.
  It performs no storage operations and supplies no dispatch authority.
  """

  alias Loopex.ArtifactStore
  alias LoopexProtocol.Canonical

  @uint64_max 18_446_744_073_709_551_615
  @source_limit 16
  @byte_limit 1_048_576
  @source_byte_limit 65_536
  @episode_ms 60_000

  @doc false
  @spec reserve(map() | nil, map(), map(), integer(), integer() | nil) ::
          {:ok, map()} | {:error, atom()}
  def reserve(episode, identity, source, now, run_deadline) do
    with :ok <- source_admitted(source),
         :ok <- clock_admitted(now),
         {:ok, base} <- episode_base(episode, identity, now, run_deadline),
         :ok <- reservation_capacity(base, source, now) do
      {:ok,
       Map.merge(base, %{
         :kind => "tool_result_preparation_state_v1",
         "status" => "reserved",
         "reserved_at_ms" => now,
         "source_count" => base["source_count"] + 1,
         "source_record_bytes" => base["source_record_bytes"] + source.record_byte_cost,
         "source" => fingerprint(source)
       })}
    end
  end

  @doc false
  @spec replay_reservation(map() | nil, map(), map(), map(), integer() | nil) ::
          {:ok, map()} | {:error, atom()}
  def replay_reservation(episode, record, identity, source, run_deadline) do
    with {:ok, expected} <-
           reserve(episode, identity, source, record["reserved_at_ms"], run_deadline),
         true <- record == expected do
      {:ok, record}
    else
      _ -> {:error, :invalid_artifact_preparation_transition}
    end
  end

  @doc false
  @spec complete(map(), map(), map(), integer()) :: {:ok, map()} | {:error, atom()}
  def complete(%{"status" => "reserved"} = episode, source, reference, now) do
    with :ok <- source_admitted(source),
         :ok <- clock_admitted(now),
         :ok <- within_deadline(episode, now),
         true <- episode["source"] == fingerprint(source),
         true <- ArtifactStore.valid_reference?(reference),
         true <- reference.digest == Canonical.digest_bytes(source.content),
         true <- reference.size == byte_size(source.content),
         true <- reference.role == "tool_output",
         true <- reference_use_matches?(reference, source.metadata) do
      {:ok,
       %{
         :kind => "tool_result_reference_prepared",
         "version" => 1,
         "episode_id" => episode["episode_id"],
         "run_id" => episode["run_id"],
         "turn_id" => episode["turn_id"],
         "projection_revision" => 1,
         "completed_at_ms" => now,
         "source" => fingerprint(source),
         "reference" => Map.new(reference, fn {key, value} -> {Atom.to_string(key), value} end)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_artifact_prepared_reference}
    end
  end

  def complete(_, _, _, _), do: {:error, :invalid_artifact_prepared_reference}

  @doc false
  @spec replay_completion(map() | nil, map(), map(), map()) ::
          {:ok, map()} | {:error, atom()}
  def replay_completion(episode, record, source, reference) do
    with {:ok, expected} <- complete(episode, source, reference, record["completed_at_ms"]),
         true <- expected == record do
      {:ok,
       episode
       |> Map.put("status", "completed")
       |> Map.put("cursor", episode["cursor"] + 1)
       |> Map.put("completed_at_ms", record["completed_at_ms"])
       |> Map.put("source", nil)}
    else
      _ -> {:error, :invalid_artifact_preparation_transition}
    end
  end

  @doc false
  @spec failure(map() | nil, map(), map(), integer(), atom()) ::
          {:ok, map()} | {:error, atom()}
  def failure(episode, identity, source, now, cause) when is_map(episode) do
    with :ok <- source_admitted(source),
         :ok <- clock_admitted(now),
         true <- Map.take(episode, ~w(episode_id run_id turn_id)) == identity,
         true <- failure_agrees?(episode, source, now, cause) do
      {:ok,
       Map.merge(identity, %{
         :kind => "tool_result_preparation_failed_v1",
         "cause" => Atom.to_string(cause),
         "observed_at_ms" => now,
         "source" => fingerprint(source)
       })}
    else
      _ -> {:error, :invalid_artifact_preparation_transition}
    end
  end

  def failure(_, _, _, _, _), do: {:error, :invalid_artifact_preparation_transition}

  @doc false
  @spec replay_failure(map() | nil, map(), map(), map()) ::
          {:ok, map()} | {:error, atom()}
  def replay_failure(episode, record, identity, source) do
    with {:ok, cause} <- failure_cause(record),
         {:ok, expected} <- failure(episode, identity, source, record["observed_at_ms"], cause),
         true <- record == expected do
      {:ok,
       Map.merge(episode, %{
         "status" => "failed",
         "cause" => record["cause"],
         "observed_at_ms" => record["observed_at_ms"]
       })}
    else
      _ -> {:error, :invalid_artifact_preparation_transition}
    end
  end

  @doc false
  @spec failure_cause(map()) :: {:ok, atom()} | :error
  def failure_cause(record) do
    case record["cause"] do
      "artifact_preparation_count_exhausted" -> {:ok, :artifact_preparation_count_exhausted}
      "artifact_preparation_bytes_exhausted" -> {:ok, :artifact_preparation_bytes_exhausted}
      "artifact_preparation_deadline" -> {:ok, :artifact_preparation_deadline}
      "artifact_preparation_failed" -> {:ok, :artifact_preparation_failed}
      _ -> :error
    end
  end

  defp failure_agrees?(episode, source, now, :artifact_preparation_failed) do
    episode["status"] == "reserved" and episode["source"] == fingerprint(source) and
      within_deadline(episode, now) == :ok
  end

  defp failure_agrees?(episode, source, now, cause)
       when cause in [
              :artifact_preparation_count_exhausted,
              :artifact_preparation_bytes_exhausted
            ] do
    episode["status"] == "completed" and
      reservation_capacity(episode, source, now) == {:error, cause}
  end

  defp failure_agrees?(episode, _source, now, :artifact_preparation_deadline) do
    episode["status"] in ["reserved", "completed"] and
      within_deadline(episode, now) == {:error, :artifact_preparation_deadline}
  end

  defp failure_agrees?(_, _, _, _), do: false

  defp source_admitted(source) do
    if is_integer(source.record_byte_cost) and
         source.record_byte_cost in 1..@source_byte_limit and
         is_binary(source.content) and String.valid?(source.content),
       do: :ok,
       else: {:error, :context_projection_invalid}
  end

  defp clock_admitted(now) do
    if is_integer(now) and now in 0..@uint64_max,
      do: :ok,
      else: {:error, :invalid_artifact_preparation_clock}
  end

  defp episode_base(nil, identity, now, run_deadline) do
    if now + @episode_ms <= @uint64_max do
      preparation_deadline = now + @episode_ms

      {deadline, origin} =
        if is_integer(run_deadline) and run_deadline < preparation_deadline,
          do: {run_deadline, "run"},
          else: {preparation_deadline, "preparation"}

      {:ok,
       Map.merge(identity, %{
         "projection_revision" => 1,
         "started_at_ms" => now,
         "deadline_ms" => deadline,
         "deadline_origin" => origin,
         "source_count" => 0,
         "source_record_bytes" => 0,
         "cursor" => 0,
         "source" => nil
       })}
    else
      {:error, :invalid_artifact_preparation_clock}
    end
  end

  defp episode_base(%{"status" => "completed"} = episode, identity, _now, _run_deadline) do
    if Map.take(episode, ~w(episode_id run_id turn_id)) == identity,
      do: {:ok, episode},
      else: {:error, :invalid_artifact_preparation_transition}
  end

  defp episode_base(_, _, _, _), do: {:error, :artifact_preparation_already_reserved}

  defp reservation_capacity(base, source, now) do
    with :ok <- within_deadline(base, now) do
      cond do
        base["source_count"] >= @source_limit ->
          {:error, :artifact_preparation_count_exhausted}

        base["source_record_bytes"] + source.record_byte_cost > @byte_limit ->
          {:error, :artifact_preparation_bytes_exhausted}

        true ->
          :ok
      end
    end
  end

  defp within_deadline(episode, now) do
    cond do
      now < episode["deadline_ms"] -> :ok
      episode["deadline_origin"] == "run" -> {:error, :run_deadline_reached}
      true -> {:error, :artifact_preparation_deadline}
    end
  end

  defp fingerprint(source) do
    %{
      "source_reference" => source.source_reference,
      "receipt_journal_version" => source.journal_version,
      "receipt_digest" => source.record_digest,
      "record_byte_cost" => source.record_byte_cost,
      "source_byte_count" => byte_size(source.content),
      "source_digest" => Canonical.digest_bytes(source.content),
      "metadata" => source.metadata
    }
  end

  # Concept: the completed use preserves the source receipt's provenance.
  # Technical depth: ADR 0015's canonical artifact-use-v2 bytes are independently
  # reconstructed from the compact reference and its five original labels.
  # Self-consistent object bytes cannot borrow another receipt's use identity.
  defp reference_use_matches?(reference, metadata) do
    use = %{
      canonicalization_version: Canonical.version(),
      object_digest: reference.digest,
      object_size: reference.size,
      object_locator: reference.locator,
      media_type: reference.media_type,
      role: reference.role,
      metadata: metadata
    }

    digest = Canonical.digest(["artifact-use-v2", use])

    reference.use_canonicalization_version == Canonical.version() and
      reference.use_digest == digest and reference.use_locator == "use:" <> digest
  end
end
