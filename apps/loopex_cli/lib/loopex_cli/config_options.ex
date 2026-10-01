defmodule LoopexCli.ConfigOptions do
  @moduledoc """
  ## Concept

  Parse the reference chat and configuration inspection commands before file,
  credential, workspace or runtime effects. Inspection cannot enable tracing or
  select a saved session.

  ## Technical depth

  ADR 0049 fixes the complete flag vocabulary. Duplicate scalar and conflicting
  boolean flags refuse; skill/module arrays retain authored order and replace
  file arrays during later merging. Values remain binary-key host data, with
  exact integers and no input atom creation. Required conversation bounds are
  still validated in the file before overrides. This boundary supplies no
  defaults, resolves no paths and starts no configured service.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Guards
  alias LoopexCli.{AskOptions, TraceSelectors}

  @common ~w(config workspace state-root model reasoning compaction-model max-steps
             deadline-ms token-budget max-tokens context-token-budget system-class-tokens
             cleanup-grace-ms system-prompt-file append-system-prompt-file tools
             skill-dir policy output no-helpers)
  @trace ~w(trace no-trace trace-level trace-module trace-max-entry-bytes
            trace-max-entries-per-second trace-max-queue-entries)
  @boolean ~w(no-helpers trace no-trace effective)
  @paths ~w(config workspace state-root system-prompt-file append-system-prompt-file skill-dir)
  @numbers ~w(max-steps deadline-ms token-budget max-tokens context-token-budget
              system-class-tokens cleanup-grace-ms trace-max-entry-bytes
              trace-max-entries-per-second trace-max-queue-entries)
  @uint64 18_446_744_073_709_551_615
  @decimal ~r/\A[1-9][0-9]*\z/

  @doc """
  ## Concept

  Admit complete argv for chat, config validate or config show.

  ## Technical depth

  Config is required; show additionally requires the standalone effective flag.
  Both `--key value` and `--key=value` forms admit value flags. Boolean flags
  take no value. Positional arguments, unknown flags and structural duplicates
  refuse before value validation. Errors contain only a class and flag pointer.
  Trace name checks consult trusted application metadata without starting apps.
  """
  @spec parse(term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  def parse(["chat" | argv]), do: parse(:chat, argv, @common ++ @trace ++ ["resume"])
  def parse(["config", "validate" | argv]), do: parse(:validate, argv, @common)
  def parse(["config", "show" | argv]), do: parse(:show, argv, @common ++ ["effective"])
  def parse(_), do: error(:invalid_arguments, "")

  defp parse(command, argv, allowed) do
    with {:ok, authored} <- scan(argv, allowed, %{}),
         :ok <- required(authored, command),
         {:ok, flags} <- values(authored) do
      {:ok,
       %{
         command: command,
         config: flags["config"],
         resume: flags["resume"],
         overrides: Map.drop(flags, ~w(config resume effective))
       }}
    end
  end

  defp scan([], _, flags), do: {:ok, flags}

  defp scan([token | rest], allowed, flags) when is_binary(token) do
    if String.valid?(token) do
      case token do
        "--" <> option -> option(option, rest, allowed, flags)
        _ -> error(:invalid_arguments, "")
      end
    else
      error(:invalid_arguments, "")
    end
  end

  defp scan(_, _, _), do: error(:invalid_arguments, "")

  defp option(option, rest, allowed, flags) do
    case String.split(option, "=", parts: 2) do
      [name] when name in @boolean ->
        if name in allowed,
          do: put(name, name != "no-trace", rest, allowed, flags),
          else: error(:invalid_arguments, "")

      [name] ->
        case rest do
          [value | tail] when is_binary(value) ->
            if name in allowed and String.valid?(value) and not String.starts_with?(value, "--"),
              do: put(name, value, tail, allowed, flags),
              else: error(:invalid_arguments, "")

          _ ->
            error(:invalid_arguments, "")
        end

      [name, value] ->
        if name in allowed and name not in @boolean,
          do: put(name, value, rest, allowed, flags),
          else: error(:invalid_arguments, "")
    end
  end

  defp put(name, value, rest, allowed, flags) when name in ["skill-dir", "trace-module"] do
    selected = Map.get(flags, name, [])
    limit = if name == "skill-dir", do: 16, else: 64

    if length(selected) < limit,
      do: scan(rest, allowed, Map.put(flags, name, selected ++ [value])),
      else: error(:too_many_flag_values, name)
  end

  defp put(name, value, rest, allowed, flags) do
    key = if name == "no-trace", do: "trace", else: name

    if Map.has_key?(flags, key),
      do: error(:duplicate_flag, key),
      else: scan(rest, allowed, Map.put(flags, key, value))
  end

  defp required(flags, command) do
    cond do
      not Map.has_key?(flags, "config") ->
        error(:missing_flag, "config")

      command == :show and not Map.has_key?(flags, "effective") ->
        error(:missing_flag, "effective")

      true ->
        :ok
    end
  end

  defp values(flags) do
    flags
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, value}, {:ok, normalized} ->
      case value(name, value) do
        {:ok, admitted} -> {:cont, {:ok, Map.put(normalized, name, admitted)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp value(name, value) when name in @paths and name != "skill-dir",
    do: text(name, value, 4_096)

  defp value("skill-dir", values), do: texts("skill-dir", values, 4_096)
  defp value("resume", value), do: text("resume", value, 256)

  defp value(name, value) when name in ["model", "compaction-model"] do
    case Guards.model(value) do
      {:ok, _} -> {:ok, value}
      _ -> error(:invalid_flag_value, name)
    end
  end

  defp value("reasoning", value), do: choice("reasoning", value, ~w(default none low medium high))
  defp value("tools", value), do: choice("tools", value, ~w(coding read-only none))
  defp value("policy", value), do: choice("policy", value, Map.keys(AskOptions.policy_profiles()))
  defp value("output", value), do: choice("output", value, ["text"])
  defp value("trace-level", value), do: choice("trace-level", value, ~w(calls returns arguments))

  defp value("trace-module", values) do
    case TraceSelectors.resolve(values) do
      {:ok, _} -> {:ok, values}
      _ -> error(:invalid_flag_value, "trace-module")
    end
  end

  defp value(name, value) when name in @numbers do
    if Regex.match?(@decimal, value) do
      integer = String.to_integer(value)
      limit = numeric_limit(name)

      if is_nil(limit) or integer <= limit,
        do: {:ok, integer},
        else: error(:invalid_flag_value, name)
    else
      error(:invalid_flag_value, name)
    end
  end

  defp value(name, value) when name in ["trace", "no-helpers", "effective"], do: {:ok, value}

  defp numeric_limit(name)
       when name in ~w(deadline-ms context-token-budget system-class-tokens cleanup-grace-ms),
       do: @uint64

  defp numeric_limit("trace-max-entry-bytes"), do: Loopex.Trace.Config.ceilings().entry_bytes

  defp numeric_limit("trace-max-entries-per-second"),
    do: Loopex.Trace.Config.ceilings().entries_per_second

  defp numeric_limit("trace-max-queue-entries"), do: Loopex.Trace.Config.ceilings().queued
  defp numeric_limit(_), do: nil

  defp texts(name, values, limit) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, selected} ->
      case text(name, value, limit) do
        {:ok, admitted} -> {:cont, {:ok, selected ++ [admitted]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp text(name, value, limit) do
    if byte_size(value) in 1..limit and String.valid?(value) and
         not String.contains?(value, <<0>>),
       do: {:ok, value},
       else: error(:invalid_flag_value, name)
  end

  defp choice(name, value, allowed) do
    if value in allowed, do: {:ok, value}, else: error(:invalid_flag_value, name)
  end

  defp error(class, ""), do: {:error, {class, ""}}
  defp error(class, name), do: {:error, {class, "/flags/" <> name}}
end
