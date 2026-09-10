defmodule Loopex.LLM.ReqLLM.ProviderConfiguration do
  @moduledoc false

  alias Loopex.Executor

  @paths [:worker_path, :interpreter_path]
  @digests [:worker_sha256, :build_manifest_sha256]
  @keys @paths ++ @digests ++ [:cleanup_grace_ms]

  # Concept: provider execution is host-configured, never discovered through a
  # workspace or an ambient search path.
  # Technical depth: this pure shape check precedes credential resolution and
  # process launch. The independently supplied artifact digest is checked on
  # disk separately, rather than trusting the child's self-reported identity.
  @doc false
  def validate(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         keys = Keyword.keys(options),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @keys)),
         true <- Enum.all?(@paths, &absolute_path?(Keyword.get(options, &1))),
         true <- Enum.all?(@digests, &digest?(Keyword.get(options, &1))),
         :ok <- optional_cleanup(options) do
      {:ok, Map.new(options)}
    else
      _refused -> {:error, :invalid_provider_configuration}
    end
  end

  def validate(_options), do: {:error, :invalid_provider_configuration}

  @doc false
  def verify_artifact(configuration) do
    with {:ok, worker} <- File.stat(configuration.worker_path),
         true <- worker.type == :regular,
         {:ok, interpreter} <- File.stat(configuration.interpreter_path),
         true <- interpreter.type == :regular,
         true <- Bitwise.band(interpreter.mode, 0o111) != 0,
         {:ok, actual} <- file_digest(configuration.worker_path),
         true <- actual == configuration.worker_sha256 do
      :ok
    else
      _refused -> {:error, :provider_artifact_unavailable}
    end
  rescue
    _error -> {:error, :provider_artifact_unavailable}
  end

  # Concept: a managed invocation spends the session's committed cleanup period;
  # a standalone caller must declare its own period explicitly.
  # Technical depth: an adapter option cannot replace the retainer's period.
  # Both paths use the existing Core validator, including its uint64 boundary.
  @doc false
  def cleanup_period(_configuration, {:managed, retainer, grace}) when is_pid(retainer) do
    case Executor.cancellation_bounds(grace) do
      {:ok, _bounds} -> {:ok, grace}
      _refused -> {:error, :invalid_provider_cleanup}
    end
  end

  def cleanup_period(%{cleanup_grace_ms: grace}, :unmanaged) do
    case Executor.cancellation_bounds(grace) do
      {:ok, _bounds} -> {:ok, grace}
      _refused -> {:error, :invalid_provider_cleanup}
    end
  end

  def cleanup_period(_configuration, _lifetime), do: {:error, :invalid_provider_cleanup}

  @doc false
  def file_digest(path) do
    digest =
      path
      |> File.stream!(65_536, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    _error -> {:error, :provider_artifact_unavailable}
  end

  defp optional_cleanup(options) do
    case Keyword.fetch(options, :cleanup_grace_ms) do
      :error ->
        :ok

      {:ok, grace} ->
        case Executor.cancellation_bounds(grace) do
          {:ok, _bounds} -> :ok
          _refused -> :error
        end
    end
  end

  defp absolute_path?(value) when is_binary(value) and byte_size(value) > 0,
    do:
      String.valid?(value) and not String.contains?(value, <<0>>) and
        Path.type(value) == :absolute

  defp absolute_path?(_value), do: false

  defp digest?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp digest?(_value), do: false
end
