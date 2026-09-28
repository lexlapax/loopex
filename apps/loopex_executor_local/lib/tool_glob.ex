defmodule Loopex.Executor.Local.ToolGlob do
  @moduledoc false

  def compile(pattern) do
    segments = split_segments(String.codepoints(pattern), [], [])

    if Enum.any?(segments, &(&1 in ["", ".", ".."])) do
      {:error, :invalid_glob}
    else
      try do
        source = segments(segments)
        Regex.compile("\\A" <> source <> "\\z", "u")
      catch
        :invalid_glob -> {:error, :invalid_glob}
      end
    end
  end

  # Concept: a quoted slash is a literal matcher scalar, not a pattern boundary.
  # Technical depth: retain escape pairs for the segment and class parser, and
  # split only an unquoted slash before applying whole-segment ** rules.
  defp split_segments([], current, segments),
    do: Enum.reverse([Enum.reverse(current) | segments]) |> Enum.map(&Enum.join/1)

  defp split_segments(["\\", next | rest], current, segments),
    do: split_segments(rest, [next, "\\" | current], segments)

  defp split_segments(["/" | rest], current, segments),
    do: split_segments(rest, [], [Enum.reverse(current) | segments])

  defp split_segments([point | rest], current, segments),
    do: split_segments(rest, [point | current], segments)

  defp segments([]), do: ""
  defp segments(["**"]), do: "(?:[^/]+(?:/[^/]+)*)?"
  defp segments(["**" | rest]), do: "(?:[^/]+/)*" <> segments(rest)
  defp segments([part]), do: segment(String.codepoints(part))
  defp segments([part, "**"]), do: segment(String.codepoints(part)) <> "(?:/[^/]+)*"
  defp segments([part | rest]), do: segment(String.codepoints(part)) <> "/" <> segments(rest)

  defp segment([]), do: ""
  defp segment(["*", "*" | _]), do: throw(:invalid_glob)
  defp segment(["*" | rest]), do: "[^/]*" <> segment(rest)
  defp segment(["?" | rest]), do: "[^/]" <> segment(rest)
  defp segment(["\\"]), do: throw(:invalid_glob)
  defp segment(["\\", literal | rest]), do: Regex.escape(literal) <> segment(rest)

  defp segment(["[" | rest]) do
    {negation, rest} =
      case rest do
        ["^" | tail] -> {"^", tail}
        _ -> {"", rest}
      end

    {members, tail} = class_members(rest, [])
    if members == [], do: throw(:invalid_glob)
    "(?:(?!/)[" <> negation <> class_source(members) <> "])" <> segment(tail)
  end

  defp segment([literal | rest]), do: Regex.escape(literal) <> segment(rest)

  defp class_members([], _), do: throw(:invalid_glob)
  defp class_members(["\\"], _), do: throw(:invalid_glob)
  defp class_members(["]" | rest], members), do: {Enum.reverse(members), rest}
  defp class_members(["/" | _], _), do: throw(:invalid_glob)
  defp class_members(["\\", "/" | _], _), do: throw(:invalid_glob)

  defp class_members(["\\", value | rest], members),
    do: class_members(rest, [{value, true} | members])

  defp class_members([value | rest], members), do: class_members(rest, [{value, false} | members])

  # Concept: only the class's original first and last hyphens can be literals.
  # Technical depth: range consumption carries original-position state, so a
  # leftover interior hyphen cannot become literal at a recursive suffix's start.
  defp class_source(members), do: class_source(members, true)

  defp class_source([{first, first_quoted?}, {"-", false}, {last, last_quoted?} | rest], first?) do
    if (first == "-" and not first_quoted? and not first?) or
         (last == "-" and not last_quoted? and rest != []),
       do: throw(:invalid_glob)

    if first > last, do: throw(:invalid_glob)
    class_literal(first) <> "-" <> class_literal(last) <> class_source(rest, false)
  end

  defp class_source([{"-", false} | rest], false) when rest != [], do: throw(:invalid_glob)
  defp class_source([{value, _} | rest], _), do: class_literal(value) <> class_source(rest, false)
  defp class_source([], _), do: ""
  defp class_literal(value) when value in ["-", "]", "[", "^", "\\"], do: "\\" <> value
  defp class_literal(value), do: value
end
