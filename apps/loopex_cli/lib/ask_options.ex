defmodule LoopexCli.AskOptions do
  @moduledoc """
  ## Concept

  Parses the standalone `ask` command and its `-p` alias before the command
  touches a workspace, starts an application, or reads a credential.

  ## Technical depth

  The returned private map keeps raw positional words for the runner to validate
  after cwd resolution. A nil optional member means its flag was omitted; the
  runner leaves that profile's own default in charge. Failure returns only a
  fixed diagnostic atom, never caller bytes.
  """

  @flags ~w(model output skill-dir tools policy cwd max-steps deadline-ms state-root)
  @uint64_max 18_446_744_073_709_551_615
  @policies %{
    "allow-all" => LoopexCli.Policy.AllowAll,
    "shell-allowlist" => LoopexCli.Policy.ShellAllowlist,
    "refuse-all" => LoopexCli.Policy.RefuseAll
  }

  @doc false
  def policy_profiles, do: @policies

  @doc """
  ## Concept

  Validates the command's flag grammar and returns its choices for later startup.

  ## Technical depth

  Accepts complete argv beginning with literal `ask` or `-p`. The first
  structural error in argv order wins; value checks run afterward in the
  accepted flag order. Cwd resolution, prompt admission and skill filesystem
  inspection remain later runner steps.
  """
  @spec parse(term()) :: {:ok, map()} | {:error, atom()}
  def parse([command | rest]) when command in ["ask", "-p"] do
    with {:ok, flags, words} <- scan(rest, %{}, []),
         :ok <- output(Map.get(flags, "output", "text")),
         :ok <- path(Map.get(flags, "state-root"), :invalid_state_root),
         :ok <- path(Map.get(flags, "cwd"), :invalid_cwd),
         :ok <- model(Map.get(flags, "model")),
         {:ok, tools} <- tools(Map.get(flags, "tools")),
         :ok <- skills(Map.get(flags, "skill-dir", [])),
         {:ok, max_steps} <- positive(Map.get(flags, "max-steps"), :invalid_max_steps),
         {:ok, deadline_ms} <- positive(Map.get(flags, "deadline-ms"), :invalid_deadline),
         {:ok, policy} <- policy(Map.get(flags, "policy")) do
      {:ok,
       %{
         profile: if(Map.has_key?(flags, "state-root"), do: :durable, else: :ephemeral),
         output: Map.get(flags, "output", "text"),
         policy: policy,
         state_root: Map.get(flags, "state-root"),
         cwd: Map.get(flags, "cwd"),
         model: Map.get(flags, "model"),
         tools: tools,
         skills: Map.get(flags, "skill-dir", []),
         max_steps: max_steps,
         deadline_ms: deadline_ms,
         words: words
       }}
    end
  end

  def parse(_), do: {:error, :invalid_arguments}

  defp scan([], flags, words), do: {:ok, flags, Enum.reverse(words)}

  defp scan(["--" | rest], flags, words) do
    if proper_binary_list?(rest),
      do: {:ok, flags, Enum.reverse(words) ++ rest},
      else: {:error, :invalid_arguments}
  end

  defp scan(["--" <> raw | rest], flags, words) do
    case String.split(raw, "=", parts: 2) do
      [key, value] ->
        with :ok <- admit(key, flags),
             true <- value != "" do
          scan(rest, put(flags, key, value), words)
        else
          _ -> {:error, :invalid_arguments}
        end

      [key] ->
        with :ok <- admit(key, flags),
             [value | tail] <- rest,
             true <- is_binary(value) and value != "" and not String.starts_with?(value, "--") do
          scan(tail, put(flags, key, value), words)
        else
          _ -> {:error, :invalid_arguments}
        end
    end
  end

  defp scan([word | rest], flags, words) when is_binary(word),
    do: scan(rest, flags, [word | words])

  defp scan(_, _, _), do: {:error, :invalid_arguments}

  defp admit(key, flags) do
    if key in @flags and (key == "skill-dir" or not Map.has_key?(flags, key)),
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  defp put(flags, "skill-dir", value),
    do: Map.update(flags, "skill-dir", [value], &(&1 ++ [value]))

  defp put(flags, key, value), do: Map.put(flags, key, value)
  defp proper_binary_list?([]), do: true

  defp proper_binary_list?([value | tail]) when is_binary(value),
    do: proper_binary_list?(tail)

  defp proper_binary_list?(_), do: false

  defp output(value) when value in ["text", "json"], do: :ok
  defp output(_), do: {:error, :invalid_output}

  defp path(nil, _reason), do: :ok

  defp path(value, reason) when is_binary(value) do
    if byte_size(value) in 1..65_536 and String.valid?(value) and
         :binary.match(value, <<0>>) == :nomatch do
      :ok
    else
      {:error, reason}
    end
  end

  defp path(_, reason), do: {:error, reason}

  defp model(nil), do: :ok

  defp model(value) when is_binary(value) do
    if byte_size(value) in 1..512 and String.valid?(value) do
      case String.split(value, ":", parts: 2) do
        [provider, id] when provider != "" and id != "" -> :ok
        _ -> {:error, :invalid_model}
      end
    else
      {:error, :invalid_model}
    end
  end

  defp model(_), do: {:error, :invalid_model}

  defp tools(nil), do: {:ok, :coding}
  defp tools("coding"), do: {:ok, :coding}
  defp tools("none"), do: {:ok, :none}
  defp tools("read-only"), do: {:ok, :read_only}
  defp tools(_), do: {:error, :invalid_tools}

  defp skills(paths) do
    cond do
      length(paths) > 4 -> {:error, :invalid_skills}
      Enum.any?(paths, &(path(&1, :invalid_skills) != :ok)) -> {:error, :invalid_skills}
      length(Enum.uniq(paths)) != length(paths) -> {:error, :invalid_skills}
      true -> :ok
    end
  end

  defp positive(nil, _reason), do: {:ok, nil}

  defp positive(value, reason) when is_binary(value) do
    if byte_size(value) in 1..20 and String.valid?(value) and
         Regex.match?(~r/\A[1-9][0-9]*\z/, value) do
      integer = String.to_integer(value)
      if integer <= @uint64_max, do: {:ok, integer}, else: {:error, reason}
    else
      {:error, reason}
    end
  end

  defp positive(_, reason), do: {:error, reason}

  defp policy(nil), do: {:error, :policy_required}

  defp policy(value) do
    case Map.fetch(@policies, value) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :invalid_policy}
    end
  end
end
