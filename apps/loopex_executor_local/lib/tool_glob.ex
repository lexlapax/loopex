defmodule Loopex.Executor.Local.ToolGlob do
  @moduledoc false

  def compile(pattern) do
    segments = String.split(pattern, "/")

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

  defp class_source([{first, _}, {"-", false}, {last, _} | rest]) when first != "-" do
    if first > last, do: throw(:invalid_glob)
    class_literal(first) <> "-" <> class_literal(last) <> class_source(rest)
  end

  defp class_source([{value, _} | rest]), do: class_literal(value) <> class_source(rest)
  defp class_source([]), do: ""
  defp class_literal(value) when value in ["-", "]", "[", "^", "\\"], do: "\\" <> value
  defp class_literal(value), do: value
end
