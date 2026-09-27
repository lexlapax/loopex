defmodule LoopexCli.AskPrompt do
  @moduledoc """
  ## Concept

  Admits a standalone `ask` command's prompt before either profile starts.

  ## Technical depth

  Positional words take precedence over standard input. Empty argv reads exact
  input bytes through a bounded stream. The helper reuses the embedded API's
  prompt grammar and exposes only fixed command diagnostic atoms.
  """

  alias LoopexComposition.Ephemeral.Options

  @doc """
  ## Concept

  Joins positional words or reads the command's input and admits its prompt.

  ## Technical depth

  The second argument is an internal IO device seam for command tests; the
  runner omits it and uses standard input. It is not a command option.
  """
  @spec admit([binary()], IO.device()) :: {:ok, binary()} | {:error, atom()}
  def admit(words, input \\ :stdio)

  def admit([_ | _] = words, _input), do: words |> Enum.join(" ") |> validate()
  def admit([], input), do: read(input, "")

  # Concept: only the prefix needed to distinguish an admitted prompt from an
  # oversized one crosses the command's input boundary.
  # Technical depth: byte 32,769 refuses immediately. No later input is read
  # and no error reason from the IO device reaches a diagnostic.
  defp read(_input, bytes) when byte_size(bytes) == 32_769,
    do: {:error, :invalid_prompt_too_large}

  defp read(input, bytes) do
    wanted = min(4_096, 32_769 - byte_size(bytes))

    case read_chunk(input, wanted) do
      :eof ->
        validate(bytes)

      chunk when is_binary(chunk) and byte_size(chunk) > 0 and byte_size(chunk) <= wanted ->
        read(input, <<bytes::binary, chunk::binary>>)

      _ ->
        {:error, :command_failed}
    end
  end

  defp read_chunk(input, wanted) do
    try do
      IO.binread(input, wanted)
    rescue
      _ -> {:error, :io_failure}
    catch
      _, _ -> {:error, :io_failure}
    end
  end

  defp validate(prompt) do
    case Options.prompt(prompt) do
      :ok -> {:ok, prompt}
      {:error, {:invalid_prompt, reason}} -> {:error, diagnostic(reason)}
    end
  end

  defp diagnostic(:empty), do: :invalid_prompt_empty
  defp diagnostic(:too_large), do: :invalid_prompt_too_large
  defp diagnostic(:invalid_utf8), do: :invalid_prompt_invalid_utf8
end
