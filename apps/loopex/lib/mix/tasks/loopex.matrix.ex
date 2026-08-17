defmodule Mix.Tasks.Loopex.Matrix do
  @shortdoc "Proves the running toolchain is a locked pair and both pairs are recorded"

  @moduledoc """
  ## Concept

  ADR 0002 fixes the toolchain as two validated (Elixir, OTP) pairs rather than a
  cross-product. This confirms the toolchain actually running is one of them, and
  that both pairs are still recorded in `.tool-versions`.

  ## Technical depth

  One Mix run has one Erlang runtime, so a single invocation cannot prove both
  pairs. It proves the pair it is running under; the gate runner invokes it once
  per pair and records both runs. That division is deliberate — a task that
  claimed to have verified a pair it never ran on would be reporting a wish.

  `.tool-versions` is the bound artifact, so its bytes are digested by the gate.
  Comparison is on the Elixir version and the OTP major release, because
  `System.otp_release/0` reports the major only; the recorded Erlang patch is for
  the version manager, not for this assertion, and the check says so rather than
  pretending to verify it.
  """

  use Mix.Task

  @tool_versions ".tool-versions"
  @matrix_evidence "docs/evidence/M0-toolchain-matrix.md"

  @impl Mix.Task
  def run(_args) do
    case check(File.cwd!()) do
      {:ok, pair} ->
        Mix.shell().info(
          "running toolchain matches locked pair Elixir #{pair.elixir} / OTP #{pair.otp}"
        )

      {:error, reason} ->
        Mix.raise("toolchain matrix is not satisfied: #{reason}")
    end
  end

  @doc """
  ## Concept

  Confirms `.tool-versions` records exactly two pairs and that the running
  toolchain is one of them.

  ## Technical depth

  Returns the matched pair so a caller can record which lane ran. A file that
  records one pair, three pairs, or a malformed line is an error rather than a
  partial pass: the accepted rule is two validated pairs, and anything else means
  the lock no longer says what ADR 0002 requires.
  """
  @spec check(Path.t()) :: {:ok, %{elixir: String.t(), otp: String.t()}} | {:error, String.t()}
  def check(root) do
    path = Path.join(root, @tool_versions)

    with {:ok, contents} <- read(path),
         {:ok, pairs} <- pairs(contents, path) do
      running = %{elixir: System.version(), otp: System.otp_release()}

      with matched when is_map(matched) <- Enum.find(pairs, &pair_matches?(&1, running)),
           :ok <- both_lanes_recorded(root, pairs) do
        {:ok, matched}
      else
        nil ->
          {:error,
           "running Elixir #{running.elixir} / OTP #{running.otp} is not a locked pair; " <>
             "#{path} records #{describe(pairs)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  ## Concept

  Confirms the retained matrix record names every locked pair as run.

  ## Technical depth

  One Mix run has one Erlang runtime, so this task can only prove the pair it is
  running under. The gate nevertheless claims both pairs are recorded as run, and
  without this check that claim rested on nothing: deleting or staling the retained
  record would not have failed anything. This does not verify that a recorded run
  happened — only review can judge that — but a missing or incomplete record now
  fails rather than passing silently.
  """
  @spec both_lanes_recorded(Path.t(), [%{elixir: String.t(), otp: String.t()}]) ::
          :ok | {:error, String.t()}
  def both_lanes_recorded(root, pairs) do
    record = Path.join(root, @matrix_evidence)

    case File.read(record) do
      {:error, posix} ->
        {:error, "#{record}: #{:file.format_error(posix)}; the matrix record is unavailable"}

      {:ok, contents} ->
        case Enum.reject(pairs, &recorded?(contents, &1)) do
          [] ->
            :ok

          missing ->
            {:error,
             "#{record} does not record a run for #{describe(missing)}; " <>
               "the gate claims both locked pairs are recorded"}
        end
    end
  end

  # A pair counts as recorded when its exact Elixir and OTP versions appear on one
  # line together with a green verdict, so a line naming a pair without an outcome
  # does not satisfy it.
  defp recorded?(contents, pair) do
    contents
    |> String.split("\n")
    |> Enum.any?(fn line ->
      String.contains?(line, pair.elixir) and String.contains?(line, pair.otp) and
        String.contains?(line, "GREEN")
    end)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, posix} -> {:error, "#{path}: #{:file.format_error(posix)}"}
    end
  end

  # Concept: an elixir line carries both the Elixir version and the OTP major it
  # is built against, which is exactly the pair ADR 0002 validates.
  defp pairs(contents, path) do
    parsed =
      contents
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.filter(&String.starts_with?(&1, "elixir "))
      |> Enum.map(&parse_elixir_line/1)

    cond do
      Enum.any?(parsed, &(&1 == :error)) ->
        {:error, "#{path} has an elixir line that is not <version>-otp-<major>"}

      length(parsed) != 2 ->
        {:error,
         "#{path} records #{length(parsed)} elixir pair(s); ADR 0002 requires exactly two"}

      true ->
        {:ok, parsed}
    end
  end

  defp parse_elixir_line("elixir " <> spec) do
    case String.split(spec, "-otp-") do
      [elixir, otp] when elixir != "" and otp != "" ->
        %{elixir: String.trim(elixir), otp: String.trim(otp)}

      _other ->
        :error
    end
  end

  defp pair_matches?(%{elixir: elixir, otp: otp}, %{elixir: elixir, otp: otp}), do: true
  defp pair_matches?(_pair, _running), do: false

  defp describe(pairs) do
    pairs
    |> Enum.map(fn pair -> "Elixir #{pair.elixir} / OTP #{pair.otp}" end)
    |> Enum.join(" and ")
  end
end
