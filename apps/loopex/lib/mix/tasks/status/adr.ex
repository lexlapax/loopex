defmodule Loopex.Checks.Adr do
  @moduledoc """
  ## Concept

  Validates architecture decision records in the current tree. An ADR's declared
  status and its governance record must say the same thing: a `Proposed` record
  carries an empty acceptance row, an `Accepted` one carries a complete row
  naming the authority, the evidence, and the bytes it bound.

  ## Technical depth

  The status field and the governance row must agree — `Proposed` with an empty
  row, `Accepted` with a complete one — so neither can be moved without the
  other. The check reads the checked-out bytes only; it does not resolve the
  bound candidate revision, because that costs a Git read per accepted ADR and
  the byte-level immutability claim it supported is no longer enforced here.
  """

  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown
  alias Loopex.Checks.Paths
  alias Loopex.Checks.Records

  @status_prefix "- **Status:** "
  @statuses ["Proposed", "Accepted"]

  @doc """
  ## Concept

  Reads an ADR's status and governance row.

  ## Technical depth

  Returns the status, the acceptance row, whether that row is structurally
  complete, and the line indices of the status field and the row, so a caller can
  report exactly where a mismatch is. A document with no governance heading at
  all fails: the section is required in the current tree, because a missing one
  means the convention was removed rather than not yet introduced.
  """
  @spec record(String.t(), String.t()) ::
          {String.t(), [String.t()], boolean(), non_neg_integer(), non_neg_integer()}
  def record(text, path) do
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

    read_record!(lines, statuses, text, path)
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

  Validates one ADR and returns its declared status.

  ## Technical depth

  Reading the record is the validation: `record/2` raises unless the status is
  one of the two admitted values and the governance row agrees with it. The
  status is returned because the plans index derives its blocker capsule from
  which bootstrap ADRs are accepted.
  """
  @spec validate(String.t(), String.t()) :: String.t()
  def validate(text, path) do
    {status, _row, _complete, _status_index, _row_index} = record(text, path)
    status
  end
end
