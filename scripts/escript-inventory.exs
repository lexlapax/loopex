defmodule LoopexEscriptInventory do
  @moduledoc """
  ## Concept

  Check that each release escript contains the logger and provider application
  bytes needed when ReqLLM starts at runtime.

  ## Technical depth

  An escript has a text preamble before its ZIP payload. Require an ordinary
  file without following a symlink, inspect the ZIP directory with OTP, reject
  duplicate entries, and require nonempty bytes for each named application
  entry. This script needs no dependency beyond the accepted Elixir/OTP
  toolchain.
  """

  @required ~w(
    logger/ebin/logger.app
    logger/ebin/Elixir.Logger.beam
    req_llm/ebin/req_llm.app
    req/ebin/req.app
    finch/ebin/finch.app
  )

  @doc """
  ## Concept

  Validate the CLI and provider escripts and print one result for each.

  ## Technical depth

  Exit 2 for grammar errors and 1 for an absent, malformed or incomplete
  archive. No input file is modified.
  """
  def main([cli, provider]) do
    Enum.each([cli, provider], fn path ->
      case check(path) do
        :ok ->
          IO.puts(
            "escript-inventory: PASS #{Path.basename(path)} logger and provider dependency bytes"
          )

        {:error, reason} ->
          IO.puts(:stderr, "escript-inventory: FAIL #{reason} in #{path}")
          System.halt(1)
      end
    end)
  end

  def main(_) do
    IO.puts(:stderr, "usage: escript-inventory.exs CLI_ESCRIPT PROVIDER_ESCRIPT")
    System.halt(2)
  end

  defp check(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, payload} <- zip_payload(bytes),
         {:ok, entries} <- :zip.table(payload),
         {:ok, inventory} <- inventory(entries) do
      missing = Enum.reject(@required, &Map.has_key?(inventory, String.to_charlist(&1)))
      empty = Enum.filter(@required, &(Map.get(inventory, String.to_charlist(&1), 1) == 0))

      cond do
        missing != [] -> {:error, "missing required applications"}
        empty != [] -> {:error, "empty required application entry"}
        true -> :ok
      end
    else
      {:ok, _other} -> {:error, "missing escript"}
      {:error, :enoent} -> {:error, "missing escript"}
      {:error, :duplicate} -> {:error, "duplicate archive entries"}
      {:error, _} -> {:error, "invalid escript archive"}
    end
  end

  defp zip_payload(bytes) do
    case :binary.match(bytes, <<"PK", 3, 4>>) do
      {offset, _} -> {:ok, binary_part(bytes, offset, byte_size(bytes) - offset)}
      :nomatch -> {:error, :invalid}
    end
  end

  defp inventory(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {:zip_comment, _}, {:ok, found} ->
        {:cont, {:ok, found}}

      {:zip_file, name, info, _comment, _offset, _compressed_size}, {:ok, found}
      when is_list(name) and is_tuple(info) ->
        cond do
          tuple_size(info) < 2 or elem(info, 0) != :file_info or
              not is_integer(elem(info, 1)) ->
            {:halt, {:error, :invalid}}

          Map.has_key?(found, name) ->
            {:halt, {:error, :duplicate}}

          true ->
            {:cont, {:ok, Map.put(found, name, elem(info, 1))}}
        end

      _, _ ->
        {:halt, {:error, :invalid}}
    end)
  end
end

LoopexEscriptInventory.main(System.argv())
