defmodule LoopexDaemon.Command do
  @moduledoc """
  ## Concept

  The daemon startup and offline index import are different commands with
  different inputs. This parser keeps that distinction before either command
  can acquire a state-root resource.

  ## Technical depth

  Parsing is effect-free. Every flag takes one nonempty value and may appear
  only once. Both `--flag value` and `--flag=value` are accepted; a bare `--`
  ends option parsing, after which every word is a refused positional argument.
  The result retains only the closed flag set for the selected form.
  """

  @startup_flags ~w(state-root workspace provider-launch policy cleanup-grace-ms socket)
  @prepare_index_flags ~w(state-root)

  defguardp is_flag?(value)
            when is_binary(value) and byte_size(value) >= 2 and
                   binary_part(value, 0, 2) == "--"

  @typedoc false
  @type mode :: :start | :prepare_index

  @typedoc false
  @type parsed :: {mode(), %{optional(binary()) => binary()}}

  @doc false
  @spec parse([binary()]) :: {:ok, parsed()} | {:error, :invalid_daemon_arguments}
  def parse(arguments) when is_list(arguments) do
    case arguments do
      ["prepare-index" | rest] -> parse_flags(:prepare_index, @prepare_index_flags, rest)
      rest -> parse_flags(:start, @startup_flags, rest)
    end
  end

  def parse(_arguments), do: {:error, :invalid_daemon_arguments}

  defp parse_flags(mode, allowed, arguments),
    do: parse_flags(mode, MapSet.new(allowed), arguments, %{})

  defp parse_flags(mode, _allowed, [], flags), do: {:ok, {mode, flags}}

  defp parse_flags(mode, _allowed, ["--"], flags), do: {:ok, {mode, flags}}

  defp parse_flags(_mode, _allowed, ["--" | [_positional | _rest]], _flags),
    do: {:error, :invalid_daemon_arguments}

  defp parse_flags(mode, allowed, ["--" <> encoded | rest], flags) do
    case String.split(encoded, "=", parts: 2) do
      [name, value] ->
        put_flag(mode, allowed, name, value, rest, flags)

      [name] ->
        case rest do
          [value | tail] when is_binary(value) and not is_flag?(value) ->
            put_flag(mode, allowed, name, value, tail, flags)

          _missing ->
            {:error, :invalid_daemon_arguments}
        end
    end
  end

  defp parse_flags(_mode, _allowed, _positionals, _flags),
    do: {:error, :invalid_daemon_arguments}

  defp put_flag(mode, allowed, name, value, rest, flags) do
    if MapSet.member?(allowed, name) and value != "" and not Map.has_key?(flags, name) do
      parse_flags(mode, allowed, rest, Map.put(flags, name, value))
    else
      {:error, :invalid_daemon_arguments}
    end
  end
end
