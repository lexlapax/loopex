defmodule ReleaseTestDefinition do
  @moduledoc """
  ## Concept

  Identify a release witness by a direct call to the fully rooted ExUnit test
  macro, not by matching a comment, source string, or locally imported macro.

  ## Technical depth

  Only direct top-level `Elixir.ExUnit.Case.test` forms count. `describe`
  scopes are deliberately unsupported. The caller requires exactly one
  module/line definition, then independently checks the executed ExUnit event.
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
            |> Enum.each(fn {module, line} -> IO.puts("#{module}\t#{line}") end)

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

  defp module_lines({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, name)
       when is_list(parts) do
    module =
      case parts do
        [:"Elixir" | rest] -> "Elixir." <> Enum.join(rest, ".")
        _ -> "Elixir." <> Enum.join(parts, ".")
      end

    body |> forms() |> Enum.flat_map(&test_lines(&1, name, module))
  end

  defp module_lines(_, _), do: []

  defp test_lines(
         {{:., _, [{:__aliases__, _, [:"Elixir", :ExUnit, :Case]}, :test]}, metadata,
          [literal, [do: _]]},
         name,
         module
       )
       when is_binary(literal) and literal == name do
    case metadata[:line] do
      line when is_integer(line) and line > 0 -> [{module, line}]
      _ -> []
    end
  end

  defp test_lines(_, _, _), do: []
end

ReleaseTestDefinition.main(System.argv())
