defmodule Loopex.Trace.Config do
  @moduledoc """
  ## Concept

  The bounded description of one trace session: which modules it may observe,
  how much it reports about each call, the ceilings it runs under, and where
  its entries go. A host may narrow any of it and can raise none of it.

  ## Technical depth

  A configuration is plain data. Wildcards exist only over the two Loopex
  namespaces, because a wildcard over anything else would let a trace session
  observe code the runtime does not own; a host that wants an adapter traced
  names that module exactly. Every ceiling below is a maximum: a supplied value
  is accepted when it is positive and no larger, and refused otherwise, so no
  configuration can widen what the accepted ADR fixed.
  """

  @levels [:calls, :returns, :arguments]
  @namespaces [:loopex, :loopex_protocol]
  @sinks [:diagnostics, :logger]

  @entry_bytes 4_096
  @entries_per_second 2_000
  @queued 8_192

  @type level :: :calls | :returns | :arguments
  @type t :: %{
          modules: [atom()],
          level: level(),
          limits: %{
            entry_bytes: pos_integer(),
            entries_per_second: pos_integer(),
            queued: pos_integer()
          },
          sink: :diagnostics | :logger
        }

  @doc """
  ## Concept

  Validates a host-supplied configuration, filling in the default session.

  ## Technical depth

  The default allowlist is the two namespace wildcards, the default level is
  `calls`, the default sink is the runtime's diagnostics plane, and the default
  limits are the ceilings. Any other shape is refused by name rather than
  silently corrected, because a session that quietly traced more or reported
  more than a host asked for is exactly what this validation exists to prevent.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, atom()}
  def validate(config) when is_map(config) do
    with :ok <- validate_keys(config),
         {:ok, modules} <- validate_modules(Map.get(config, :modules, @namespaces)),
         {:ok, level} <- validate_level(Map.get(config, :level, :calls)),
         {:ok, limits} <- validate_limits(Map.get(config, :limits, %{})),
         {:ok, sink} <- validate_sink(Map.get(config, :sink, :diagnostics)) do
      {:ok, %{modules: modules, level: level, limits: limits, sink: sink}}
    end
  end

  def validate(_config), do: {:error, :invalid_trace_configuration}

  @doc """
  ## Concept

  The namespace wildcards a session may use.

  ## Technical depth

  The wildcards are fixed by this contract, so a session names a namespace the
  runtime already knows rather than an arbitrary module pattern. A trace
  session cannot widen its own scope by naming something outside this list.
  """
  @spec namespaces() :: [atom()]
  def namespaces, do: @namespaces

  @doc """
  ## Concept

  The ceilings this contract fixes, which a host may lower and never raise.

  ## Technical depth

  Returned as data so the operator runbook, the session that applies a
  configuration and the tests that check it all quote one set of numbers rather
  than three copies that can drift apart.
  """
  @spec ceilings() :: %{
          entry_bytes: pos_integer(),
          entries_per_second: pos_integer(),
          queued: pos_integer()
        }
  def ceilings,
    do: %{entry_bytes: @entry_bytes, entries_per_second: @entries_per_second, queued: @queued}

  defp validate_keys(config) do
    case Map.keys(config) -- [:modules, :level, :limits, :sink] do
      [] -> :ok
      _unknown -> {:error, :invalid_trace_configuration}
    end
  end

  defp validate_modules(modules) when is_list(modules) and modules != [] do
    if Enum.all?(modules, &allowed_module?/1) do
      {:ok, Enum.uniq(modules)}
    else
      {:error, :invalid_trace_modules}
    end
  end

  defp validate_modules(_modules), do: {:error, :invalid_trace_modules}

  # Concept: a namespace wildcard, or one exactly named module.
  #
  # Technical depth: `:loopex` and `:loopex_protocol` are the only wildcards,
  # and they are resolved from the applications' own module lists rather than
  # from a name prefix, so a module that merely begins with `Loopex` in another
  # application is not swept in. Any other atom names one module exactly, which
  # is how a host puts its adapter under trace.
  defp allowed_module?(module) when module in @namespaces, do: true

  defp allowed_module?(module) when is_atom(module) do
    module not in [nil, true, false] and not wildcard_name?(module)
  end

  defp allowed_module?(_module), do: false

  defp wildcard_name?(module) do
    name = Atom.to_string(module)
    String.contains?(name, "*") or String.contains?(name, "?")
  end

  defp validate_level(level) when level in @levels, do: {:ok, level}
  defp validate_level(_level), do: {:error, :invalid_trace_level}

  defp validate_sink(sink) when sink in @sinks, do: {:ok, sink}
  defp validate_sink(_sink), do: {:error, :invalid_trace_sink}

  defp validate_limits(limits) when is_map(limits) do
    with :ok <- validate_limit_keys(limits),
         {:ok, entry_bytes} <- validate_limit(limits, :entry_bytes, @entry_bytes),
         {:ok, entries_per_second} <-
           validate_limit(limits, :entries_per_second, @entries_per_second),
         {:ok, queued} <- validate_limit(limits, :queued, @queued) do
      {:ok, %{entry_bytes: entry_bytes, entries_per_second: entries_per_second, queued: queued}}
    end
  end

  defp validate_limits(_limits), do: {:error, :invalid_trace_limits}

  defp validate_limit_keys(limits) do
    case Map.keys(limits) -- [:entry_bytes, :entries_per_second, :queued] do
      [] -> :ok
      _unknown -> {:error, :invalid_trace_limits}
    end
  end

  defp validate_limit(limits, key, ceiling) do
    case Map.get(limits, key, ceiling) do
      value when is_integer(value) and value > 0 and value <= ceiling -> {:ok, value}
      _refused -> {:error, :invalid_trace_limits}
    end
  end
end
