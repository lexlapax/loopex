defmodule Loopex.Checks.Markdown do
  @moduledoc """
  ## Concept

  Reads the deliberately small Markdown subset the repository's governed
  documents are written in. Governed structure — headings, marked blocks, tables,
  semantic anchors, and inline links — must mean exactly one thing, so anything
  ambiguous is rejected rather than interpreted.

  The distinction this module exists for is *visibility*. A heading, marker, or
  anchor inside a fenced block, a code span, or an HTML comment is decoration;
  one outside them is a governed fact. Without that distinction a decoy status
  block hidden in a fence would read as the real one.

  ## Technical depth

  Not a Markdown implementation and not intended to become one. It recognises
  fenced blocks, inline code spans, and HTML comments as hiding constructs,
  tracks them across lines, and refuses raw HTML other than the semantic anchor
  tag. An unclosed construct is a failure, because a document whose remainder is
  hidden cannot be validated at all.

  Line indices are zero-based positions in the normalised line list, which every
  caller shares, so a visibility set computed here can be intersected with any
  other structural scan of the same document.
  """

  alias Loopex.Checks.Invalid
  alias Loopex.Checks.Paths

  # Concept: separators a renderer may or may not break a line on. A governed
  # marker placed after one would be visible to a reader and invisible to a
  # line-oriented check, so the document is rejected instead of guessed at.
  @line_separators [
    "\v",
    "\f",
    "\x1C",
    "\x1D",
    "\x1E",
    "\u0085",
    "\u2028",
    "\u2029"
  ]
  @canonical_separators ["\r" | @line_separators]

  @anchor_id "[a-z0-9]+(?:-[a-z0-9]+)*"

  @fence ~r/\A {0,3}(`{3,}|~{3,})(.*)\z/u
  @html_tag ~r|</?[A-Za-z][^>]*>|u
  @atx ~r/\A {0,3}(\#{1,6})(?:[ \t]+|\z)(.*)\z/u
  @setext ~r/\A {0,3}(?:=+|-+)[ \t]*\z/u
  @anchor_tag ~r/<a id="(#{@anchor_id})"><\/a>/u
  @anchor_only ~r/\A<a id="(#{@anchor_id})"><\/a>\z/u
  @link_any ~r/\[([^\]\r\n]*)\]\(([^()\s]+)\)/u
  @link_only ~r/\A\[([^\]\r\n]*)\]\(([^()\s]+)\)\z/u

  @markers %{
    readme: {"<!-- loopex:readme-status:start -->", "<!-- loopex:readme-status:end -->"},
    current: {"<!-- loopex:current-status:start -->", "<!-- loopex:current-status:end -->"},
    register:
      {"<!-- loopex:milestone-register:start -->", "<!-- loopex:milestone-register:end -->"},
    plan_concept_envelope:
      {"<!-- loopex:plan-concept-envelope:start -->", "<!-- loopex:plan-concept-envelope:end -->"},
    plan_technical_envelope:
      {"<!-- loopex:plan-technical-envelope:start -->",
       "<!-- loopex:plan-technical-envelope:end -->"},
    matrix_runs: {"<!-- loopex:matrix-runs:start -->", "<!-- loopex:matrix-runs:end -->"},
    rejoin_source: {"<!-- loopex:rejoin-source:start -->", "<!-- loopex:rejoin-source:end -->"},
    rejoin_copy: {"<!-- loopex:rejoin-copy:start -->", "<!-- loopex:rejoin-copy:end -->"}
  }

  @known_markers @markers |> Map.values() |> Enum.flat_map(&Tuple.to_list/1) |> MapSet.new()

  @doc """
  ## Concept

  The start and end marker bytes for one governed block, by key.

  ## Technical depth

  Markers are exact whole-line strings. Keeping them in one map means the
  visibility scan can recognise every marker as governed content — a marker line
  is the one HTML comment that is not a hiding construct — without each caller
  restating the list.
  """
  @spec markers(atom()) :: {String.t(), String.t()}
  def markers(key), do: Map.fetch!(@markers, key)

  @doc """
  ## Concept

  Splits document text into the normalised line list every other check indexes
  into, rejecting separators Markdown does not define.

  ## Technical depth

  `CRLF` and a bare `CR` are normalised to `LF` because both are ordinary
  checkout artifacts. Vertical tab, form feed, the C1 separators, `NEL`, and the
  Unicode line and paragraph separators are rejected outright: some renderers
  break lines on them and some do not, so a marker or heading placed after one
  would be visible to a reader and invisible to a line-oriented check.
  """
  @spec lines(String.t(), String.t()) :: [String.t()]
  def lines(text, path) do
    if Enum.any?(@line_separators, &String.contains?(text, &1)) do
      raise Invalid, "#{path}: unsupported non-Markdown line separator"
    end

    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
  end

  @doc """
  ## Concept

  Fails unless the text uses canonical UTF-8 with `LF` line endings only.

  ## Technical depth

  Stricter than `lines/2` because it also rejects `CR`. Digest-bound text cannot
  be normalised before hashing without the digest describing bytes that are not
  in the file, so the bytes themselves must already be canonical.
  """
  @spec require_canonical!(String.t(), String.t(), String.t()) :: :ok
  def require_canonical!(text, path, subject) do
    if Enum.any?(@canonical_separators, &String.contains?(text, &1)) do
      raise Invalid, "#{path}: #{subject} must use canonical UTF-8/LF bytes"
    end

    :ok
  end

  @doc """
  ## Concept

  The set of line indices that carry governed content: everything outside fenced
  blocks, code spans, and HTML comments.

  ## Technical depth

  A single left-to-right pass, because these constructs nest across lines and a
  per-line test cannot see that. A line that *begins* inside an open code span is
  not governed even if it closes the span, so a heading cannot be smuggled in by
  opening a span on the line before.

  Raw HTML outside the semantic anchor tag is rejected here rather than
  elsewhere: HTML can hide arbitrary content from a reader while leaving it in
  the text, which would let a document show one thing and validate as another.
  An unclosed construct at end of text fails, since the remainder of the
  document would otherwise be silently unvalidated.
  """
  @spec visible_line_numbers(String.t(), String.t()) :: MapSet.t(non_neg_integer())
  def visible_line_numbers(text, path) do
    {visible, fence, comment, ticks} =
      text
      |> lines(path)
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), nil, false, nil}, fn {line, number}, state ->
        step(line, number, state, path)
      end)

    if fence != nil or comment or ticks != nil do
      raise Invalid, "#{path}: unclosed Markdown or HTML hiding construct"
    end

    visible
  end

  defp step(line, _number, {visible, {char, count}, comment, ticks}, _path) do
    case fence_closes?(line, char, count) do
      true -> {visible, nil, comment, ticks}
      false -> {visible, {char, count}, comment, ticks}
    end
  end

  defp step(line, _number, {visible, nil, true, ticks}, _path) do
    {visible, nil, not String.contains?(line, "-->"), ticks}
  end

  defp step(line, number, {visible, nil, false, nil}, path) do
    cond do
      opening = fence_open(line) -> {visible, opening, false, nil}
      MapSet.member?(@known_markers, line) -> {MapSet.put(visible, number), nil, false, nil}
      true -> expose(line, number, visible, nil, path)
    end
  end

  defp step(line, number, {visible, nil, false, ticks}, path) do
    expose(line, number, visible, ticks, path)
  end

  defp expose(line, number, visible, ticks, path) do
    started_in_code = ticks != nil
    {exposed, comment, remaining_ticks} = scan(String.to_charlist(line), ticks, [])

    case started_in_code do
      true ->
        {visible, nil, comment, remaining_ticks}

      false ->
        reject_raw_html!(List.to_string(exposed), path)
        {MapSet.put(visible, number), nil, comment, remaining_ticks}
    end
  end

  defp reject_raw_html!(exposed, path) do
    without_anchors = Regex.replace(@anchor_tag, exposed, "")

    if Regex.match?(@html_tag, without_anchors) or
         String.starts_with?(String.trim_leading(without_anchors), "<") do
      raise Invalid, "#{path}: raw HTML is not allowed in active Markdown"
    end

    :ok
  end

  # Concept: walk one line, dropping code spans and comments, and report the
  # hiding state the next line inherits.
  # Technical depth: an unterminated comment stops the walk, because everything
  # after it on this line is inside the comment; the caller inherits `comment`.
  defp scan([], ticks, exposed), do: {Enum.reverse(exposed), false, ticks}

  defp scan([?<, ?!, ?-, ?- | rest], nil, exposed) do
    case comment_end(rest) do
      {:ok, remainder} -> scan(remainder, nil, exposed)
      :error -> {Enum.reverse(exposed), true, nil}
    end
  end

  defp scan([?` | _rest] = chars, nil, exposed) do
    {count, remainder} = backticks(chars, 0)
    scan(remainder, count, exposed)
  end

  defp scan([char | rest], nil, exposed), do: scan(rest, nil, [char | exposed])

  defp scan([?` | _rest] = chars, ticks, exposed) do
    {count, remainder} = backticks(chars, 0)
    scan(remainder, if(count == ticks, do: nil, else: ticks), exposed)
  end

  defp scan([_char | rest], ticks, exposed), do: scan(rest, ticks, exposed)

  defp backticks([?` | rest], count), do: backticks(rest, count + 1)
  defp backticks(rest, count), do: {count, rest}

  defp comment_end([?-, ?-, ?> | rest]), do: {:ok, rest}
  defp comment_end([_char | rest]), do: comment_end(rest)
  defp comment_end([]), do: :error

  defp fence_open(line) do
    case Regex.run(@fence, line) do
      [_all, delimiter | _rest] ->
        {String.first(delimiter), String.length(delimiter)}

      nil ->
        nil
    end
  end

  defp fence_closes?(line, char, count) do
    Regex.match?(~r/\A {0,3}#{Regex.escape(char)}{#{count},}[ \t]*\z/u, line)
  end

  @doc """
  ## Concept

  One line with its inline code spans and HTML comments removed, for a line
  already known to be governed.

  ## Technical depth

  Deliberately stateless: it answers "what does this governed line actually
  say", which is a per-line question once `visible_line_numbers/2` has decided
  the line is governed. An unterminated comment truncates the line rather than
  leaking commented text into a structural comparison.
  """
  @spec exposed_line(String.t()) :: String.t()
  def exposed_line(line) do
    {exposed, _comment, _ticks} = scan(String.to_charlist(line), nil, [])
    List.to_string(exposed)
  end

  @doc """
  ## Concept

  The heading level and text of an ATX heading line, or `nil` when the line is
  not one.

  ## Technical depth

  Returns `{level, text}` with the closing hash run and surrounding whitespace
  removed, so `## Concept ##` and `## Concept` compare equal when a caller is
  asking about heading identity rather than exact bytes. Callers that require
  canonical bytes compare the raw line instead.
  """
  @spec atx(String.t()) :: {pos_integer(), String.t()} | nil
  def atx(line) do
    case Regex.run(@atx, line) do
      [_all, hashes, rest] ->
        {String.length(hashes),
         rest |> String.trim() |> String.replace(~r/[ \t]+\#+[ \t]*\z/u, "")}

      nil ->
        nil
    end
  end

  @doc """
  ## Concept

  Whether a line is a setext heading underline.

  ## Technical depth

  Only the underline is recognised here; a caller decides whether the line above
  is governed and non-blank, which is what makes the pair a heading.
  """
  @spec setext?(String.t()) :: boolean()
  def setext?(line), do: Regex.match?(@setext, line)

  @doc """
  ## Concept

  The semantic anchor a line consists of entirely, or `nil`.

  ## Technical depth

  Whole-line match. A relationship anchor must stand alone so its position
  relative to the heading it names is unambiguous; an anchor buried in prose is
  found by `anchors_in/1` instead.
  """
  @spec anchor_only(String.t()) :: String.t() | nil
  def anchor_only(line) do
    case Regex.run(@anchor_only, line) do
      [_all, anchor] -> anchor
      nil -> nil
    end
  end

  @doc """
  ## Concept

  Every semantic anchor appearing anywhere in a line, in order.

  ## Technical depth

  Used both to build a document's anchor index and to track which anchored
  section a labelled relationship link belongs to, where the last anchor on the
  line is the one in effect.
  """
  @spec anchors_in(String.t()) :: [String.t()]
  def anchors_in(line) do
    @anchor_tag |> Regex.scan(line) |> Enum.map(fn [_all, anchor] -> anchor end)
  end

  @doc """
  ## Concept

  The one Markdown link a value consists of entirely, as `{label, destination}`,
  or `nil`.

  ## Technical depth

  Whole-value match, so a relationship line carrying anything besides the link
  is rejected rather than partially read.
  """
  @spec link_only(String.t()) :: {String.t(), String.t()} | nil
  def link_only(value) do
    case Regex.run(@link_only, value) do
      [_all, label, destination] -> {label, destination}
      nil -> nil
    end
  end

  @doc """
  ## Concept

  Every inline Markdown link in a line, with the byte offset each begins at.

  ## Technical depth

  Offsets are returned because the link-grammar check needs to know what sits
  immediately before a link — an `!` makes it an image — and what text remains
  once the recognised links are removed.
  """
  @spec links_in(String.t()) :: [{non_neg_integer(), String.t(), String.t(), String.t()}]
  def links_in(line) do
    @link_any
    |> Regex.scan(line, return: :index)
    |> Enum.map(fn [{start, length}, label_span, destination_span] ->
      {start, slice(line, {start, length}), slice(line, label_span),
       slice(line, destination_span)}
    end)
  end

  defp slice(_line, {-1, _length}), do: ""
  defp slice(line, {start, length}), do: binary_part(line, start, length)

  @doc """
  ## Concept

  The visible body lines of one marked block, optionally required to sit inside a
  named heading.

  ## Technical depth

  The marker pair must occur exactly once in the raw text and both occurrences
  must be governed lines, so a commented-out or fenced copy cannot supply the
  second occurrence and shift which bytes count as the block.

  When a heading is named, every governed line between it and the block start is
  checked for a competing heading of level one or two: a status block sitting
  after a later section would be indexed under a heading it does not belong to.
  """
  @spec block(String.t(), String.t(), atom(), String.t() | nil) :: [String.t()]
  def block(text, path, key, heading \\ nil) do
    {start, stop} = markers(key)

    if occurrences(text, start) != 1 or occurrences(text, stop) != 1 do
      raise Invalid, "#{path}: #{key} markers must each occur exactly once"
    end

    lines = lines(text, path)
    visible = visible_line_numbers(text, path)
    starts = matching_indices(lines, visible, start)
    stops = matching_indices(lines, visible, stop)

    with [start_index] <- starts,
         [stop_index] <- stops,
         true <- start_index < stop_index do
      if heading, do: require_enclosing_heading!(lines, visible, heading, start_index, path, key)
      Enum.slice(lines, (start_index + 1)..(stop_index - 1)//1)
    else
      _other -> raise Invalid, "#{path}: #{key} markers must be ordered and top-level"
    end
  end

  defp require_enclosing_heading!(lines, visible, heading, start_index, path, key) do
    case matching_indices(lines, visible, heading) do
      [heading_index] when heading_index < start_index ->
        reject_competing_headings!(lines, visible, heading_index, start_index, path, key, heading)

      _other ->
        raise Invalid, "#{path}: #{key} block must follow unique #{inspect(heading)}"
    end
  end

  defp reject_competing_headings!(lines, visible, from, to, path, key, heading) do
    Enum.each((from + 1)..(to - 1)//1, fn index ->
      if MapSet.member?(visible, index) do
        line = Enum.at(lines, index)

        competing =
          case atx(line) do
            {level, _text} when level <= 2 -> true
            _other -> setext_heading?(lines, visible, index)
          end

        if competing do
          raise Invalid, "#{path}: #{key} block is outside #{inspect(heading)}"
        end
      end
    end)
  end

  @doc """
  ## Concept

  Whether the line at `index` is the underline of a setext heading.

  ## Technical depth

  Requires the preceding line to be governed and non-blank, because an
  underline under a blank line or under hidden text is a horizontal rule or
  ordinary text, not a heading.
  """
  @spec setext_heading?([String.t()], MapSet.t(non_neg_integer()), non_neg_integer()) :: boolean()
  def setext_heading?(lines, visible, index) do
    index > 0 and setext?(Enum.at(lines, index)) and MapSet.member?(visible, index - 1) and
      String.trim(Enum.at(lines, index - 1)) != ""
  end

  @doc """
  ## Concept

  Reads an exact pipe table with the given header, returning one list of cell
  values per row.

  ## Technical depth

  The header and separator rows must match byte for byte and every row must have
  the exact column count with non-empty, untrimmed-free cells. A tolerant table
  reader would accept a row whose columns had shifted, and a shifted row is
  exactly how a governed fact ends up under the wrong field name.
  """
  @spec table([String.t()], [String.t()], String.t()) :: [[String.t()]]
  def table(lines, header, path) do
    expected_header = "| " <> Enum.join(header, " | ") <> " |"
    expected_rule = "| " <> Enum.join(Enum.map(header, fn _column -> "---" end), " | ") <> " |"

    if length(lines) < 2 or Enum.take(lines, 2) != [expected_header, expected_rule] do
      raise Invalid, "#{path}: expected exact #{Enum.join(header, " | ")} table"
    end

    lines |> Enum.drop(2) |> Enum.map(&row(&1, length(header), path))
  end

  defp row(line, columns, path) do
    unless String.starts_with?(line, "| ") and String.ends_with?(line, " |") do
      raise Invalid, "#{path}: malformed table row #{inspect(line)}"
    end

    cells =
      line
      |> binary_part(2, byte_size(line) - 4)
      |> String.split(" | ")

    if length(cells) != columns or
         Enum.any?(cells, &(String.trim(&1) == "" or &1 != String.trim(&1))) do
      raise Invalid, "#{path}: malformed table row #{inspect(line)}"
    end

    cells
  end

  @doc """
  ## Concept

  The body of one top-level section, with its first body line index.

  ## Technical depth

  The section runs from its heading to the next governed level-one or level-two
  heading, in either ATX or setext form, and blank lines are trimmed from both
  ends. The heading must occur exactly once as a governed line: two sections with
  the same name would let a reader and a check disagree about which one governs.
  """
  @spec section_body(String.t(), String.t(), String.t()) :: {[String.t()], non_neg_integer()}
  def section_body(text, path, heading) do
    lines = lines(text, path)
    visible = visible_line_numbers(text, path)

    heading_index =
      case matching_indices(lines, visible, heading) do
        [index] ->
          index

        _other ->
          raise Invalid,
                "#{path}: expected one top-level #{Paths.strip_prefix(heading, "## ")} section"
      end

    stop = section_end(lines, visible, heading_index)
    body = lines |> Enum.slice((heading_index + 1)..(stop - 1)//1) |> trim_blank_edges()
    {body, first_content_index(lines, heading_index + 1, stop)}
  end

  defp section_end(lines, visible, heading_index) do
    visible
    |> Enum.sort()
    |> Enum.drop_while(&(&1 <= heading_index))
    |> Enum.find_value(length(lines), fn index ->
      line = Enum.at(lines, index)

      cond do
        match?({level, _text} when level <= 2, atx(line)) -> index
        index - 1 > heading_index and setext_heading?(lines, visible, index) -> index - 1
        true -> nil
      end
    end)
  end

  defp first_content_index(lines, from, stop) do
    case from < stop and Enum.at(lines, from) == "" do
      true -> first_content_index(lines, from + 1, stop)
      false -> from
    end
  end

  defp trim_blank_edges(body) do
    body
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc """
  ## Concept

  Indices of governed lines whose text is exactly `value`.

  ## Technical depth

  Exact whole-line comparison against the normalised line list, intersected with
  the governed set, which is the primitive every marker, heading, and anchor
  lookup in the checks is built from.
  """
  @spec matching_indices([String.t()], MapSet.t(non_neg_integer()), String.t()) ::
          [non_neg_integer()]
  def matching_indices(lines, visible, value) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, index} -> line == value and MapSet.member?(visible, index) end)
    |> Enum.map(fn {_line, index} -> index end)
  end

  @doc """
  ## Concept

  How many times a substring occurs in the raw text.

  ## Technical depth

  Counts in the raw bytes, before any visibility decision, because the
  exactly-once marker rule exists to stop a second copy from being introduced
  anywhere at all — including inside a comment where a governed-line scan would
  never see it.
  """
  @spec occurrences(String.t(), String.t()) :: non_neg_integer()
  def occurrences(text, substring), do: length(String.split(text, substring)) - 1

  @doc """
  ## Concept

  The SHA-256 digest of text, as lowercase hexadecimal.

  ## Technical depth

  Hashes the UTF-8 bytes exactly as they appear. Every digest the governance
  records bind is computed this way, so a digest comparison is a byte comparison
  with a fixed-size representation.
  """
  @spec digest(String.t()) :: String.t()
  def digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
