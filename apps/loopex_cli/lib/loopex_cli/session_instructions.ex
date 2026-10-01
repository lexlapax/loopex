defmodule LoopexCli.SessionInstructions do
  @moduledoc """
  ## Concept

  The reference host captures explicit instruction files and environment facts
  before session creation or configuration. Captured content grants no policy,
  tool or helper authority.

  ## Technical depth

  ADR 0042 fixes the section versions and deterministic JSON environment bytes.
  The existing protocol encoder supplies that JSON rendering. Prompt files use
  the composition's regular-file reader, which binds the opened identity and
  reads at most the section ceiling plus one byte. Core captures the resulting
  sections and digest; no path, timestamp or ambient environment value enters
  the instruction record. Callers pass already resolved absolute paths.
  """

  alias Loopex.Runtime.Instructions
  alias LoopexComposition.ProjectResources.ResourceReader
  alias LoopexProtocol.Frame

  @base "You are a coding agent working in a real workspace. " <>
          "Use the tools you are given to inspect and change files, and run commands " <>
          "when you need to. Continue until the task is done, then stop."
  @options ~w(system_file append_file enabled_roles catalog_digest)
  @facts ~w(workspace platform tool_profile)
  @role ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  @doc """
  ## Concept

  Capture the reference default or an explicitly selected base and appendix.

  ## Technical depth

  Options are closed binary-key data. A helper-enabled parent supplies both its
  nonempty enabled-role list and catalog digest. File contents are read once;
  capture returns only ADR 0042's five-member retained instruction map.
  """
  @spec capture(term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def capture(workspace, profile, options \\ %{}) do
    with true <- is_map(options) and Enum.all?(Map.keys(options), &(&1 in @options)),
         {:ok, environment} <- environment(facts(workspace, profile, options)),
         {:ok, base} <- section(options, "system_file", @base, 32_768),
         {:ok, appendix} <- section(options, "append_file", "", 16_384) do
      Instructions.capture(%{
        "version" =>
          if(Map.has_key?(options, "system_file"),
            do: "loopex.explicit.v1",
            else: "loopex.reference.v1"
          ),
        "base" => base,
        "environment" => environment,
        "appendix" => appendix
      })
    else
      false -> {:error, :invalid_instructions}
      {:error, _} = error -> error
    end
  end

  @doc """
  ## Concept

  Capture one selected role's instructions with the child's environment facts.

  ## Technical depth

  The role file supplies the complete base, with an empty appendix and no parent
  catalog facts. Selecting the role and authorizing its tools remain separate
  host and session-owner obligations.
  """
  @spec capture_role(term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def capture_role(workspace, profile, path) do
    with {:ok, environment} <- environment(facts(workspace, profile, %{})),
         {:ok, base} <- read_section(path, 32_768) do
      Instructions.capture(%{
        "version" => "loopex.role.v1",
        "base" => base,
        "environment" => environment,
        "appendix" => ""
      })
    end
  end

  @doc """
  ## Concept

  Render only the explicit environment facts admitted by the reference host.

  ## Technical depth

  Closed shapes prevent accidental ambient data capture. Keys are ASCII-sorted;
  Unicode and standard JSON escapes retain their exact bytes. Enabled roles are
  unique ASCII identifiers sorted before encoding. The complete rendered text,
  after escaping and without the frame newline, must fit 4,096 bytes.
  """
  @spec environment(term()) :: {:ok, binary()} | {:error, atom()}
  def environment(facts) when is_map(facts) do
    with true <- valid_facts?(facts),
         {:ok, encoded} <- Frame.encode(sorted_roles(facts)),
         bytes <- IO.iodata_to_binary(encoded),
         size <- byte_size(bytes) - 1,
         true <- size <= 4_096 do
      {:ok, binary_part(bytes, 0, size)}
    else
      false -> {:error, :invalid_instruction_environment}
      {:error, _} -> {:error, :invalid_instruction_environment}
    end
  end

  def environment(_), do: {:error, :invalid_instruction_environment}

  defp facts(workspace, profile, options) do
    Map.merge(
      %{"workspace" => workspace, "platform" => platform(), "tool_profile" => profile},
      Map.take(options, ~w(enabled_roles catalog_digest))
    )
  end

  defp platform do
    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        _ -> "other"
      end

    architecture = :erlang.system_info(:system_architecture) |> List.to_string()

    architecture =
      cond do
        String.starts_with?(architecture, "aarch64") -> "aarch64"
        String.starts_with?(architecture, "x86_64") -> "x86_64"
        true -> "other"
      end

    %{"os" => os, "architecture" => architecture}
  end

  defp valid_facts?(facts) do
    keys = Enum.sort(Map.keys(facts))

    keys in [Enum.sort(@facts), Enum.sort(@facts ++ ~w(enabled_roles catalog_digest))] and
      path?(facts["workspace"]) and facts["tool_profile"] in ~w(coding read-only none) and
      valid_platform?(facts["platform"]) and valid_roles?(facts)
  end

  defp valid_platform?(%{"os" => os, "architecture" => architecture} = platform) do
    map_size(platform) == 2 and os in ~w(darwin linux other) and
      architecture in ~w(aarch64 x86_64 other)
  end

  defp valid_platform?(_), do: false

  defp valid_roles?(%{"enabled_roles" => roles, "catalog_digest" => digest} = facts) do
    valid_role_list?(roles, []) and is_binary(digest) and byte_size(digest) == 71 and
      String.valid?(digest) and Regex.match?(@digest, digest) and
      facts["tool_profile"] != "none"
  end

  defp valid_roles?(facts), do: not Map.has_key?(facts, "enabled_roles")

  defp valid_role_list?([], seen), do: seen != []

  defp valid_role_list?([role | rest], seen) when length(seen) < 16 do
    is_binary(role) and byte_size(role) in 1..64 and String.valid?(role) and
      Regex.match?(@role, role) and role not in seen and valid_role_list?(rest, [role | seen])
  end

  defp valid_role_list?(_, _), do: false

  defp sorted_roles(%{"enabled_roles" => roles} = facts),
    do: Map.put(facts, "enabled_roles", Enum.sort(roles))

  defp sorted_roles(facts), do: facts

  defp section(options, key, default, limit) do
    case Map.fetch(options, key) do
      :error -> {:ok, default}
      {:ok, path} -> read_section(path, limit)
    end
  end

  defp read_section(path, limit) do
    if path?(path) do
      case ResourceReader.read(path, limit) do
        {:ok, bytes} when byte_size(bytes) > limit ->
          {:error, :instruction_file_too_large}

        {:ok, bytes} ->
          if String.valid?(bytes),
            do: {:ok, bytes},
            else: {:error, :invalid_instruction_file}

        _refused ->
          {:error, :invalid_instruction_file}
      end
    else
      {:error, :invalid_instruction_file}
    end
  end

  defp path?(path) when is_binary(path) and byte_size(path) in 1..4_096 do
    String.valid?(path) and not String.contains?(path, <<0>>) and Path.type(path) == :absolute
  end

  defp path?(_), do: false
end
