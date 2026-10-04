defmodule Loopex.Store.CreationProvenance do
  @moduledoc """
  ## Concept

  Bounded historical creation observations for host recovery. A creating command,
  a session identity or a complete captured runtime cut can be inspected without
  activating sessions or granting mutation authority.

  ## Technical depth

  ADR 0046 fixes the closed selectors, six-member historical projection and
  contiguous per-runtime creation ordinals. This pure validator is shared by the
  Store port and the shipped memory/local transition owner. It checks scalar
  bounds and current genesis version 3 before ETF measurement and visits at
  most sixteen page rows. Missing
  callbacks or malformed observations remain unavailable, never empty coverage.
  """

  @uint64_max 18_446_744_073_709_551_615
  @row_bytes 65_536
  @page_bytes 1_114_112

  @doc false
  def valid_selector?(runtime, %{kind: :command, command_id: command} = selector),
    do: map_size(selector) == 2 and identifier?(runtime) and identifier?(command)

  def valid_selector?(runtime, %{kind: :session, session_id: session} = selector),
    do: map_size(selector) == 2 and identifier?(runtime) and identifier?(session)

  def valid_selector?(runtime, %{kind: :runtime_page, cursor: cursor, limit: limit} = selector),
    do:
      map_size(selector) == 3 and identifier?(runtime) and is_integer(limit) and
        limit in 1..16 and valid_cursor?(runtime, cursor)

  def valid_selector?(_, _), do: false

  @doc false
  def valid_cursor?(runtime, nil), do: identifier?(runtime)

  def valid_cursor?(
        runtime,
        %{
          version: 1,
          runtime_id: runtime,
          through_create_ordinal: through,
          after_create_ordinal: after_ordinal
        } = cursor
      ),
      do:
        map_size(cursor) == 4 and identifier?(runtime) and quantity?(through) and
          quantity?(after_ordinal) and after_ordinal <= through

  def valid_cursor?(_, _), do: false

  @doc false
  def normalize(runtime, %{kind: kind} = selector, {:historical, row} = result)
      when kind in [:command, :session] do
    if valid_row?(runtime, row, false) and point_binding?(selector, row),
      do: result,
      else: :unavailable
  end

  def normalize(runtime, %{kind: :runtime_page} = selector, {:page, page} = result) do
    with %{
           version: 1,
           runtime_id: ^runtime,
           through_create_ordinal: through,
           rows: rows,
           next_cursor: next
         } <- page,
         true <- map_size(page) == 5 and quantity?(through),
         {:ok, after_ordinal} <- page_start(selector.cursor, through),
         true <-
           valid_rows?(
             runtime,
             rows,
             after_ordinal,
             min(selector.limit, through - after_ordinal),
             []
           ),
         last = min(after_ordinal + selector.limit, through),
         true <- next == cursor(runtime, through, last),
         true <- byte_size(:erlang.term_to_binary(page)) <= @page_bytes do
      result
    else
      _ -> :unavailable
    end
  end

  def normalize(_, %{kind: kind}, result)
      when kind in [:command, :session] and result in [:absent, :conflict, :unavailable],
      do: result

  def normalize(_, %{kind: :runtime_page}, :conflict), do: :unexpected
  def normalize(_, _, _), do: :unavailable

  @doc false
  def cursor(_runtime, through, through), do: nil

  def cursor(runtime, through, after_ordinal),
    do: %{
      version: 1,
      runtime_id: runtime,
      through_create_ordinal: through,
      after_create_ordinal: after_ordinal
    }

  @doc false
  def valid_row?(runtime, row, ordinal?) when is_map(row) do
    expected_size = if ordinal?, do: 7, else: 6

    row[:version] == 1 and row[:runtime_id] == runtime and
      map_size(row) == expected_size and identifier?(row[:runtime_id]) and
      identifier?(row[:command_id]) and identifier?(row[:session_id]) and
      row[:genesis_version] == 3 and digest?(row[:canonical_create_digest]) and
      (not ordinal? or (quantity?(row[:create_ordinal]) and row[:create_ordinal] > 0)) and
      byte_size(:erlang.term_to_binary(row)) <= @row_bytes
  end

  def valid_row?(_, _, _), do: false

  defp page_start(nil, _through), do: {:ok, 0}

  defp page_start(
         %{through_create_ordinal: through, after_create_ordinal: after_ordinal},
         through
       ),
       do: {:ok, after_ordinal}

  defp page_start(_, _), do: :error

  defp valid_rows?(_runtime, [], _previous, 0, _seen), do: true

  defp valid_rows?(runtime, [row | rest], previous, remaining, seen) when remaining in 1..16 do
    valid_row?(runtime, row, true) and row.create_ordinal == previous + 1 and
      Enum.all?(seen, &(&1.command_id != row.command_id and &1.session_id != row.session_id)) and
      valid_rows?(runtime, rest, previous + 1, remaining - 1, [row | seen])
  end

  defp valid_rows?(_, _, _, _, _), do: false

  defp point_binding?(%{kind: :command, command_id: command}, row), do: row.command_id == command
  defp point_binding?(%{kind: :session, session_id: session}, row), do: row.session_id == session
  defp identifier?(id), do: is_binary(id) and byte_size(id) in 1..256
  defp quantity?(value), do: is_integer(value) and value >= 0 and value <= @uint64_max

  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: Enum.all?(:binary.bin_to_list(digest), &(&1 in ?0..?9 or &1 in ?a..?f))

  defp digest?(_), do: false
end
