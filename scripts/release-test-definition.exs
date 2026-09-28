defmodule ReleaseTestDefinition do
  @moduledoc """
  ## Concept

  Identify a release witness by the test macro actually present in its module,
  not by matching a comment or source string that names the test.

  ## Technical depth

  Only direct module or `describe` test forms count. The caller still checks
  that exactly one line is returned and that Mix executes one selected test.
  This script parses source but never evaluates it.
  """

  def main([path, name]) do
    case File.read(path) do
      {:ok, source} ->
        case Code.string_to_quoted(source, file: path) do
          {:ok, ast} ->
            ast
            |> forms()
            |> Enum.flat_map(&module_lines(&1, name))
            |> Enum.each(&IO.puts/1)

          {:error, _} ->
            System.halt(1)
        end

      {:error, _} ->
        System.halt(1)
    end
  end

  def main(_), do: System.halt(2)

  defp forms({:__block__, _, items}), do: items
  defp forms(item), do: [item]

  defp module_lines({:defmodule, _, [_, [do: body]]}, name) do
    body |> forms() |> Enum.flat_map(&test_lines(&1, name))
  end

  defp module_lines(_, _), do: []

  defp test_lines({:test, metadata, [literal, [do: _]]}, name)
       when is_binary(literal) and literal == name do
    case metadata[:line] do
      line when is_integer(line) and line > 0 -> [line]
      _ -> []
    end
  end

  defp test_lines({:describe, _, [_, [do: body]]}, name) do
    body |> forms() |> Enum.flat_map(&test_lines(&1, name))
  end

  defp test_lines(_, _), do: []
end

ReleaseTestDefinition.main(System.argv())
