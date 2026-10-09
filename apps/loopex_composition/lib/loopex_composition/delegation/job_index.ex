defmodule LoopexComposition.Delegation.JobIndex do
  @moduledoc """
  ## Concept

  ADR 0046's disposable `job-index-v1` cache: one job entry per original helper
  attempt and one coverage entry per scanned parent session, so a later start
  resumes classification instead of rescanning a validated prefix.

  ## Technical depth

  Entries are exactly ADR 0056's closed maps in canonical ledger JSON. A job
  entry is `{version, kind: "job", job, source_intent, run_log, frame_offset}`
  named by SHA-256 of the original job ID; a coverage entry is `{version, kind:
  "coverage", runtime_id, session_id, covered_through_version, prefix_token,
  expected_sha256}` named by SHA-256 of the session ID. `expected_sha256` is the
  SHA-256 of the canonical JSON array of `{job, source_intent}` for that
  session's job entries at or below the watermark, ordered by source journal
  version and then job bytes. Entries carry no authority; every use revalidates
  them against Core history and the retained ledger, and any mismatch discards
  them and rescans.
  """

  alias LoopexComposition.Delegation.LedgerCodec

  @job ~w(version kind job source_intent run_log frame_offset)
  @coverage ~w(version kind runtime_id session_id covered_through_version prefix_token expected_sha256)

  @doc false
  def job_name(job_id), do: hash(job_id)

  @doc false
  def coverage_name(session_id), do: "coverage/" <> hash(session_id)

  @doc false
  def job_entry(job, source_intent, run_log, offset),
    do:
      LedgerCodec.encode_json(
        %{
          "version" => 1,
          "kind" => "job",
          "job" => job,
          "source_intent" => source_intent,
          "run_log" => run_log,
          "frame_offset" => offset
        },
        :object
      )

  @doc false
  def coverage_entry(runtime_id, session_id, through, token, expected),
    do:
      LedgerCodec.encode_json(
        %{
          "version" => 1,
          "kind" => "coverage",
          "runtime_id" => Base.encode64(runtime_id),
          "session_id" => Base.encode64(session_id),
          "covered_through_version" => through,
          "prefix_token" => Base.encode64(token),
          "expected_sha256" => expected
        },
        :object
      )

  @doc false
  def decode_job(bytes) do
    with {:ok, entry} <- LedgerCodec.decode_json(bytes, :object),
         true <- closed?(entry, @job) and entry["version"] === 1 and entry["kind"] == "job",
         true <- is_map(entry["job"]) and is_map(entry["source_intent"]),
         true <- is_binary(entry["run_log"]) and byte_size(entry["run_log"]) == 64,
         true <- is_nil(entry["frame_offset"]) or nonnegative?(entry["frame_offset"]),
         {:ok, session} <- Base.decode64(entry["job"]["session_id"] || "") do
      {:ok, Map.put(entry, :session, session)}
    else
      _ -> :error
    end
  end

  @doc false
  def decode_coverage(bytes, runtime_id, session_id) do
    with {:ok, entry} <- LedgerCodec.decode_json(bytes, :object),
         true <- closed?(entry, @coverage) and entry["version"] === 1,
         true <- entry["kind"] == "coverage",
         true <- entry["runtime_id"] == Base.encode64(runtime_id),
         true <- entry["session_id"] == Base.encode64(session_id),
         true <- nonnegative?(entry["covered_through_version"]),
         {:ok, token} <- Base.decode64(entry["prefix_token"] || ""),
         true <- byte_size(token) == 32 do
      {:ok,
       %{
         through: entry["covered_through_version"],
         token: token,
         expected: entry["expected_sha256"]
       }}
    else
      _ -> :error
    end
  end

  @doc false
  def expected(entries, through) do
    rows =
      entries
      |> Enum.filter(&(&1["source_intent"]["journal_version"] <= through))
      |> Enum.map(&%{"job" => &1["job"], "source_intent" => &1["source_intent"]})
      |> Enum.sort_by(
        &{&1["source_intent"]["journal_version"], LedgerCodec.encode_json(&1, :object)}
      )

    {:ok, wrapped} = LedgerCodec.encode_json(%{"v" => rows}, :object)
    hash(binary_part(wrapped, 5, byte_size(wrapped) - 6))
  end

  # Concept: a job entry names the frame that first retained its attempt.
  # Technical depth: offsets are the exact byte offsets of the run log's frames,
  # computed from the header and each canonical frame length.
  @doc false
  def frame_offset(ledger, projection, source_intent) do
    {_, offset} =
      Enum.reduce_while(ledger.transactions, {byte_size(ledger.header), nil}, fn {tx, _},
                                                                                 {at, _} ->
        mutation = tx["mutation"]

        if mutation["job"] == projection or
             (mutation["kind"] == "recover_uncreated" and
                mutation["source_intent"] == source_intent) do
          {:halt, {at, at}}
        else
          {:ok, payload} = LedgerCodec.encode_json(tx, :frame)
          {:ok, frame} = LedgerCodec.encode_frame(payload)
          {:cont, {at + byte_size(frame), nil}}
        end
      end)

    offset
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp nonnegative?(value), do: is_integer(value) and value >= 0

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
