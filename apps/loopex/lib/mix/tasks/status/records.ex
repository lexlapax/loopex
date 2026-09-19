defmodule Loopex.Checks.Records do
  @moduledoc """
  ## Concept

  Reads governance records: the rows in which a plan or decision names who
  accepted it, where that disposition is recorded, and which bytes were bound.

  A governance row is either untouched or complete. A half-filled row is the
  dangerous state, because it reads as a recorded decision while naming no
  authority, no evidence, or no bytes — so it is rejected rather than treated as
  progress toward acceptance.

  ## Technical depth

  Structural only, and deliberately so: this module proves a row's shape, not
  that the disposition it transcribes happened. Whether the recorded authority
  actually accepted the bytes is established by the disposition the evidence
  column points at, which a reader follows.
  """

  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Markdown

  @authority ~r/\A(?:Maintainer|Delegate: [A-Za-z0-9][A-Za-z0-9 ._@-]*)\z/u
  @evidence ~r/\A\[disposition\]\([^) \t]+\)\z/u
  @empty ["—", "—", "—"]

  @adr_bound ~r/\Acandidate `([0-9a-f]{40})`; concept `sha256:([0-9a-f]{64})`; technical `sha256:([0-9a-f]{64})`\z/u

  @header ["Decision", "Authority", "Authority evidence", "Bound bytes"]

  @doc """
  ## Concept

  Whether a cell names an acceptance authority the contract recognises.

  ## Technical depth

  Either the maintainer, or a named delegate. A delegate's scope is recorded
  independently before acceptance, so this check proves the row names one rather
  than proving the delegation existed.
  """
  @spec authority?(String.t()) :: boolean()
  def authority?(cell), do: Regex.match?(@authority, cell)

  @doc """
  ## Concept

  Whether a cell links a durable disposition record.

  ## Technical depth

  Exactly one `[disposition](target)` link. The label is fixed so a reviewer can
  find every disposition pointer in the repository by searching for one string,
  and so an ordinary reference link cannot pass as authority evidence.
  """
  @spec evidence?(String.t()) :: boolean()
  def evidence?(cell), do: Regex.match?(@evidence, cell)

  @doc """
  ## Concept

  The three bound values an ADR governance row carries: candidate revision, and
  the concept and technical-depth digests.

  ## Technical depth

  An ADR has no gate, so its bound record has three fields rather than four. A
  plan record therefore cannot be pasted into an ADR row or the reverse.
  """
  @spec adr_bound(String.t()) :: {String.t(), String.t(), String.t()} | nil
  def adr_bound(cell) do
    case Regex.run(@adr_bound, cell) do
      [_all, candidate, concept, technical] -> {candidate, concept, technical}
      nil -> nil
    end
  end

  @doc """
  ## Concept

  Whether a row's three value cells are all the empty marker.

  ## Technical depth

  The em dash is the one accepted empty value. Any other placeholder — a hyphen, a
  question mark, blank — either fails the table's non-empty cell rule or reads as
  a recorded value, and both are worse than a single explicit convention.
  """
  @spec empty_row?([String.t()]) :: boolean()
  def empty_row?(row), do: Enum.drop(row, 1) == @empty

  @doc """
  ## Concept

  Reads a governance table with the exact decision names it must carry, in order,
  and returns the rows with the line index of each.

  ## Technical depth

  Content after the table is rejected unless it is a single semantic anchor,
  because a governance section is a record rather than a discussion: prose after
  the rows would be an unversioned qualification of an immutable decision.
  """
  @spec records_table(String.t(), String.t(), String.t(), [String.t()]) ::
          {[[String.t()]], [non_neg_integer()]}
  def records_table(text, path, heading, decisions) do
    {body, body_start} = Markdown.section_body(text, path, heading)
    table_length = 2 + length(decisions)
    table_body = Enum.take(body, table_length)
    trailing = body |> Enum.drop(table_length) |> Enum.reject(&(&1 == ""))

    unless trailing == [] or
             (length(trailing) == 1 and Markdown.anchor_only(hd(trailing)) != nil) do
      raise Invalid, "#{path}: governance rows have trailing content"
    end

    rows = Markdown.table(table_body, @header, path)

    if length(rows) != length(decisions) or Enum.map(rows, &hd/1) != decisions do
      raise Invalid, "#{path}: governance rows must be #{Enum.join(decisions, " then ")}"
    end

    {rows, Enum.to_list((body_start + 2)..(body_start + 1 + length(rows))//1)}
  end
end
