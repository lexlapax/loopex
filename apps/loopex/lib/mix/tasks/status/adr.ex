defmodule Loopex.Checks.Adr do
  @moduledoc """
  ## Concept

  Validates architecture decision records. An accepted ADR is an immutable
  record: its decision, status, and consequences may change only through a
  versioned amendment accepted by the same authority class. This module proves
  that an accepted ADR is byte-identical to the candidate it binds, apart from
  the two cells the disposition itself writes.

  ## Technical depth

  The status field and the governance row must agree — `Proposed` with an empty
  row, `Accepted` with a complete one — so neither can be moved without the
  other. Acceptance is verified by reconstructing the proposal: the accepted text
  with its status and governance row reset must equal the historical candidate
  exactly. Anything else changed between proposal and acceptance therefore fails,
  including a rewritten decision that keeps the same digest fields filled in.
  """

  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Paths
  alias Loopex.Checks.Records

  @status_prefix "- **Status:** "
  @statuses ["Proposed", "Accepted"]
  @empty_row "| Acceptance | — | — | — |"

  @doc """
  ## Concept

  Reads an ADR's status and governance row, or returns `nil` for a historical
  revision that predates the governance convention.

  ## Technical depth

  `legacy_ok` exists only for the history walk, where an early revision of a
  document legitimately has no governance section. In the current tree the
  section is required, because a missing one there would mean the convention was
  removed rather than not yet introduced.
  """
  @spec record(String.t(), String.t(), keyword()) ::
          {String.t(), [String.t()], boolean(), non_neg_integer(), non_neg_integer()} | nil
  def record(text, path, options \\ []) do
    legacy_ok = Keyword.get(options, :legacy_ok, false)

    if String.contains?(text, "\r") do
      raise Invalid, "#{path}: ADR text must use canonical UTF-8/LF bytes"
    end

    lines = Markdown.lines(text, path)
    visible = Markdown.visible_line_numbers(text, path)

    statuses =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, index} ->
        String.starts_with?(line, @status_prefix) and MapSet.member?(visible, index)
      end)
      |> Enum.map(fn {_line, index} -> index end)

    heading_present =
      Markdown.matching_indices(lines, visible, "## Governance Record") != []

    case legacy_ok and not heading_present do
      true -> nil
      false -> read_record!(lines, statuses, text, path)
    end
  end

  defp read_record!(lines, statuses, text, path) do
    status_index =
      case statuses do
        [index] -> index
        _other -> raise Invalid, "#{path}: expected one visible ADR Status field"
      end

    status = Paths.strip_prefix(Enum.at(lines, status_index), @status_prefix)

    unless status in @statuses do
      raise Invalid, "#{path}: bootstrap ADR status must be Proposed or Accepted"
    end

    {rows, row_indices} =
      Records.records_table(text, path, "## Governance Record", ["Acceptance"])

    row = Enum.at(rows, 0)

    complete =
      Records.authority?(Enum.at(row, 1)) and Records.evidence?(Enum.at(row, 2)) and
        Records.adr_bound(Enum.at(row, 3)) != nil

    empty = Records.empty_row?(row)

    unless empty or complete do
      raise Invalid, "#{path}: ADR governance row must be exactly empty or structurally complete"
    end

    if status == "Proposed" != empty or status == "Accepted" != complete do
      raise Invalid, "#{path}: ADR Status and governance record do not match"
    end

    {status, row, complete, status_index, Enum.at(row_indices, 0)}
  end

  @doc """
  ## Concept

  Validates one ADR pair against the candidate its acceptance row binds, and
  returns its status.

  ## Technical depth

  A `Proposed` ADR needs no candidate. An accepted one must resolve its candidate
  and its candidate's technical companion, must find the candidate still carrying
  the `Proposed` status with an empty row, and must match both bound digests. The
  final comparison rebuilds the proposal from the accepted bytes, which is what
  catches a decision edited in the same change that accepted it.
  """
  @spec validate(
          String.t(),
          String.t(),
          String.t(),
          (String.t(), String.t() -> String.t() | nil) | nil
        ) ::
          String.t()
  def validate(text, technical_text, path, resolve_file) do
    case record(text, path) do
      nil ->
        raise Invalid, "#{path}: ADR governance record is unavailable"

      {status, _row, false, _status_index, _row_index} ->
        status

      {status, row, true, status_index, row_index} ->
        verify_accepted!(text, technical_text, path, resolve_file, row, status_index, row_index)
        status
    end
  end

  defp verify_accepted!(text, technical_text, path, resolve_file, row, status_index, row_index) do
    bound = Records.adr_bound(Enum.at(row, 3))

    if bound == nil do
      raise Invalid, "#{path}: accepted ADR bound bytes are malformed"
    end

    {revision, concept_digest, technical_digest} = bound
    technical_path = Paths.technical(path)
    candidate = resolve_file && resolve_file.(revision, path)
    technical_candidate = resolve_file && resolve_file.(revision, technical_path)

    if candidate == nil do
      raise Invalid, "#{path}: accepted ADR candidate is unavailable"
    end

    if technical_candidate == nil do
      raise Invalid, "#{technical_path}: accepted ADR candidate is unavailable"
    end

    candidate_record = record(candidate, "#{path} at historical candidate #{revision}")

    if candidate_record == nil do
      raise Invalid, "#{path}: historical candidate ADR governance record is unavailable"
    end

    {candidate_status, _candidate_row, candidate_complete, _index, _row} = candidate_record

    if candidate_status != "Proposed" or candidate_complete do
      raise Invalid, "#{path}: historical candidate must be the Proposed ADR with an empty record"
    end

    if Markdown.digest(candidate) != concept_digest do
      raise Invalid, "#{path}: ADR concept digest does not match its historical candidate"
    end

    if Markdown.digest(technical_candidate) != technical_digest do
      raise Invalid, "#{path}: ADR technical digest does not match its historical candidate"
    end

    if technical_text != technical_candidate do
      raise Invalid, "#{technical_path}: accepted ADR technical depth differs from its candidate"
    end

    reconstructed =
      text
      |> Markdown.lines(path)
      |> List.replace_at(status_index, @status_prefix <> "Proposed")
      |> List.replace_at(row_index, @empty_row)
      |> Enum.join("\n")

    if reconstructed != candidate do
      raise Invalid,
            "#{path}: accepted ADR differs from its historical candidate outside the disposition record"
    end

    :ok
  end
end
