defmodule Loopex.Runtime.Instructions do
  @moduledoc """
  ## Concept

  Hosts supply explicit instruction sections. The runtime captures their exact
  bytes and validates retained content without discovering or refreshing files,
  environment facts or project resources.

  ## Technical depth

  ADR 0042's closed input has version, base, environment and appendix members.
  Capture adds the SHA-256 digest of the rendered text. Rendering prefixes the
  version and joins nonempty sections with one blank line, preserving section
  bytes. Retained validation checks both the original bounds and digest. This
  pure boundary does not grant policy authority or perform system-budget checks;
  admission must count the complete system message and selected tools together.
  """

  @input_keys Enum.sort(~w(version base environment appendix))
  @captured_keys Enum.sort(~w(version base environment appendix digest))
  @legacy %{
    "version" => "loopex.system.v1",
    "base" =>
      "You are a coding agent working in a real workspace. " <>
        "Use the tools you are given to inspect and change files, and run commands " <>
        "when you need to. Continue until the task is done, then stop.",
    "environment" => "",
    "appendix" => ""
  }

  @typedoc """
  ## Concept

  Captured host instructions with their exact rendered-content identity.

  ## Technical depth

  Five binary-key members retain the four bounded input fields and the lowercase
  hexadecimal SHA-256 digest. Original section bytes are retained once; replay
  reconstructs the text and requires the digest to match.
  """
  @type captured :: %{required(binary()) => binary()}

  @doc """
  ## Concept

  Capture explicit instruction sections before configuration admission.

  ## Technical depth

  Unknown or missing members, invalid UTF-8, empty base and overlong byte sections
  refuse. Versions contain one to 64 ASCII identifier bytes. No trimming,
  normalization, templating or inferred environment content occurs.
  """
  @spec capture(term()) :: {:ok, captured()} | {:error, :invalid_instructions}
  def capture(input) when is_map(input) and map_size(input) == 4 do
    if Enum.sort(Map.keys(input)) == @input_keys and valid_sections?(input) do
      {:ok, Map.put(input, "digest", digest(render_sections(input)))}
    else
      {:error, :invalid_instructions}
    end
  end

  def capture(_input), do: {:error, :invalid_instructions}

  @doc """
  ## Concept

  Validate retained instructions without rewriting their content.

  ## Technical depth

  The closed captured shape passes the original input bounds and recomputes its
  exact rendered digest. Substituted bytes or digest and extra members refuse.
  """
  @spec validate(term()) :: :ok | {:error, :invalid_instructions}
  def validate(captured) when is_map(captured) and map_size(captured) == 5 do
    with true <- Enum.sort(Map.keys(captured)) == @captured_keys,
         {:ok, expected} <- capture(Map.delete(captured, "digest")),
         true <- captured == expected do
      :ok
    else
      _invalid -> {:error, :invalid_instructions}
    end
  end

  def validate(_captured), do: {:error, :invalid_instructions}

  @doc """
  ## Concept

  Render only validated captured instruction content.

  ## Technical depth

  Version and section bytes determine the text exactly. Empty optional sections
  add no separator. Digest validation prevents silently changing retained bytes
  if rendering rules change.
  """
  @spec render(term()) :: {:ok, binary()} | {:error, :invalid_instructions}
  def render(captured) do
    with :ok <- validate(captured), do: {:ok, render_sections(captured)}
  end

  @doc """
  ## Concept

  The immutable compatibility instructions for legacy callers.

  ## Technical depth

  Version loopex.system.v1 preserves the complete pre-M7 system text. It supplies
  no host environment facts and does not refresh already staged requests.
  """
  @spec legacy() :: captured()
  def legacy do
    {:ok, captured} = capture(@legacy)
    captured
  end

  defp valid_sections?(input) do
    version = input["version"]

    is_binary(version) and byte_size(version) in 1..64 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, version) and
      valid_text?(input["base"], 1, 32_768) and
      valid_text?(input["environment"], 0, 4_096) and
      valid_text?(input["appendix"], 0, 16_384)
  end

  defp valid_text?(value, minimum, maximum) do
    is_binary(value) and byte_size(value) >= minimum and byte_size(value) <= maximum and
      String.valid?(value)
  end

  defp render_sections(input) do
    sections =
      Enum.reject([input["base"], input["environment"], input["appendix"]], &(&1 == ""))

    input["version"] <> ": " <> Enum.join(sections, "\n\n")
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
