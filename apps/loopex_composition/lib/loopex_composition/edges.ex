defmodule LoopexComposition.Edges do
  @moduledoc """
  ## Concept

  A long-lived host such as the daemon starts the reference edges in its own
  process, so it holds their links, can name each one's exit and can stop them
  in its own order. This module tracks exactly which edges started and lets
  the host stop composition between edges.

  ## Technical depth

  `start/4` runs `LoopexComposition`'s one composition chain in the caller's
  process. It installs a tracking starter through that chain's existing edge
  seam: before each of the Store, transfers, workspace lease,
  executor and runtime it evaluates the host's `interrupt`, and after each
  successful start it records the pid, or the runtime together with its
  supervisor. The same interrupt remains active while observing creation startup.
  Any other start the chain performs passes through unchanged. An
  interrupt `{:stop, reason}`, an invalid interrupt answer, or an exception in
  an interrupt or edge starter ends composition with the exact partial map;
  exceptions carry only their kind. The host supplies its own credential
  plane, so no environment variable is read here.
  """

  alias LoopexComposition.{CredentialPlane, ProviderBindings}
  alias Loopex.LLM.ReqLLM.{CredentialRegistry, ProviderConfiguration}

  @edge :"$loopex_composition_edge_observer"
  @owned :"$loopex_composition_owned"
  @started :"$loopex_composition_started_edges"
  @keys %{
    Loopex.Store.Local => :store,
    Loopex.Store.Local.Transfers => :transfers,
    Loopex.Executor.Local.WorkspaceLease => :workspace_lease,
    Loopex.Executor.Local => :executor,
    Loopex => :runtime
  }

  @doc false
  @spec credential_plane(keyword(), (module(), keyword() -> term())) ::
          {:ok, map()} | {:error, term()}
  def credential_plane(options, start_edge) do
    case Keyword.fetch(options, :credential_plane) do
      {:ok, plane} ->
        if valid_plane?(plane),
          do: {:ok, plane},
          else: {:error, {:invalid_composition_option, :credential_plane}}

      :error ->
        case Keyword.fetch(options, :provider_bindings) do
          {:ok, bindings} -> CredentialPlane.open(bindings, start_edge)
          :error -> CredentialPlane.open(start_edge)
        end
    end
  end

  @doc false
  def admitted_routes(options) do
    case {Keyword.fetch(options, :provider_bindings), Keyword.fetch(options, :credential_plane)} do
      {{:ok, _}, {:ok, _}} ->
        {:error, {:invalid_composition_option, :provider_bindings}}

      {{:ok, bindings}, :error} ->
        with {:ok, _} <- ProviderBindings.validate(bindings),
             false <- Map.has_key?(bindings, "ollama") do
          {:ok, Map.keys(bindings)}
        else
          true -> {:error, {:composition, :durable_model_unsupported}}
          {:error, _} = error -> error
        end

      {:error, {:ok, plane}} ->
        if valid_plane?(plane) do
          case plane do
            %{version: 2} -> {:ok, Map.keys(plane.model_options[:provider_routes])}
            _ -> {:ok, :legacy}
          end
        else
          {:error, {:invalid_composition_option, :credential_plane}}
        end

      {:error, :error} ->
        {:ok, :legacy}
    end
  end

  # Concept: borrowed planes admit only their immutable routes and exclusions.
  # Technical depth: preflight checks the whole closed shape and resolves every
  # token in the supplied registry without reading credential values. The legacy
  # branch keeps its separate grammar. A malformed keyword list is a refusal.
  defp valid_plane?(
         %{version: 2, capability: capability, model_options: options, excluded_env_names: names} =
           plane
       ) do
    Map.keys(plane) --
      [:version, :capability, :model_options, :excluded_env_names, :capability_pid] == [] and
      model_options?(options, [:credential_registry, :provider_routes, :tracing_capability]) and
      common_plane?(plane, capability, options) and
      ProviderBindings.validate_exclusions(names) == :ok and
      ProviderConfiguration.validate_routes(options[:provider_routes]) == :ok and
      Enum.all?(options[:provider_routes], fn {_provider, token} ->
        match?({:ok, _}, CredentialRegistry.route(options[:credential_registry], token))
      end)
  end

  defp valid_plane?(%{capability: capability, model_options: options} = plane) do
    Map.keys(plane) -- [:capability, :model_options, :capability_pid] == [] and
      model_options?(options, [:credential_registry, :credential_token, :tracing_capability]) and
      common_plane?(plane, capability, options) and
      Loopex.LLM.ReqLLM.CredentialToken.validate(options[:credential_token]) == :ok
  end

  defp valid_plane?(_plane), do: false

  defp model_options?(options, keys) do
    Keyword.keyword?(options) and length(options) == length(keys) and
      Enum.sort(Keyword.keys(options)) == keys
  end

  defp common_plane?(plane, capability, options) do
    Loopex.Trace.Capability.validate(capability) == :ok and
      options[:tracing_capability] == capability and
      CredentialRegistry.validate(options[:credential_registry]) == :ok and
      (not Map.has_key?(plane, :capability_pid) or plane.capability_pid == capability.pid)
  end

  @doc false
  @spec start(term(), term(), (term() -> term()), (term() -> term())) ::
          {:ok, map()} | {:error, term(), map()}
  def start(options, lifecycle, validate, compose)
      when is_list(options) and is_list(lifecycle) do
    with {:ok, interrupt} <- interrupt_option(lifecycle),
         :ok <- supplied_plane(options),
         {:ok, configuration} <- validate.(options) do
      run(configuration, interrupt, compose)
    else
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  def start(_options, _lifecycle, _validate, _compose),
    do: {:error, :invalid_composition_options, %{}}

  defp run(configuration, interrupt, compose) do
    previous_edge = Process.get(@edge)
    previous_owned = Process.get(@owned)
    interrupt_key = LoopexComposition.StartupGate.interrupt_key()
    previous_interrupt = Process.get(interrupt_key)
    observer = previous_edge || (&apply/3)
    Process.put(@owned, [])
    Process.put(@started, %{})

    Process.put(interrupt_key, fn ->
      case checkpoint(interrupt, :runtime) do
        :continue -> :ok
        {:stop, reason} -> {:error, {:stop, reason}}
        other -> {:error, {:invalid_composition_interrupt_result, other}}
      end
    end)

    Process.put(@edge, fn module, function, arguments ->
      tracked(interrupt, observer, module, function, arguments)
    end)

    try do
      case compose.(configuration) do
        {:ok, _runtime} ->
          case LoopexComposition.StartupGate.confirm() do
            :ok -> {:ok, Process.get(@started)}
            {:error, reason} -> {:error, reason, Process.get(@started)}
          end
        {:error, reason} -> {:error, reason, Process.get(@started)}
      end
    catch
      {@started, reason} -> {:error, reason, Process.get(@started)}
    after
      restore(@edge, previous_edge)
      restore(@owned, previous_owned)
      restore(interrupt_key, previous_interrupt)
      Process.delete(@started)
    end
  end

  defp tracked(interrupt, observer, module, :start_link, arguments)
       when is_map_key(@keys, module) do
    key = Map.fetch!(@keys, module)

    case checkpoint(interrupt, key) do
      :continue -> :ok
      {:stop, reason} -> throw({@started, {:stop, reason}})
      other -> throw({@started, {:invalid_composition_interrupt_result, other}})
    end

    result =
      try do
        observer.(module, :start_link, arguments)
      catch
        kind, _reason -> throw({@started, {:composition_edge_exception, key, kind}})
      end

    record(key, result)
    result
  end

  defp tracked(_interrupt, observer, module, function, arguments),
    do: observer.(module, function, arguments)

  defp checkpoint(interrupt, key) do
    interrupt.()
  catch
    kind, _reason -> throw({@started, {:composition_interrupt_exception, key, kind}})
  end

  defp record(:runtime, {:ok, %Loopex.Runtime{supervisor: supervisor} = runtime}) do
    started = Process.get(@started)
    Process.put(@started, Map.merge(started, %{runtime: runtime, runtime_supervisor: supervisor}))
  end

  defp record(key, {:ok, pid}) when is_pid(pid),
    do: Process.put(@started, Map.put(Process.get(@started), key, pid))

  defp record(_key, _refusal), do: :ok

  defp interrupt_option(lifecycle) do
    with [] <- Keyword.keys(lifecycle) -- [:interrupt],
         interrupt when is_function(interrupt, 0) <-
           Keyword.get(lifecycle, :interrupt, fn -> :continue end) do
      {:ok, interrupt}
    else
      _invalid -> {:error, :invalid_composition_options}
    end
  end

  defp supplied_plane(options) do
    if Keyword.has_key?(options, :credential_plane),
      do: :ok,
      else: {:error, {:invalid_composition_option, :credential_plane}}
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)
end
