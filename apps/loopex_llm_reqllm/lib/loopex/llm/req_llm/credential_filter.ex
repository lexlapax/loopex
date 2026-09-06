defmodule Loopex.LLM.ReqLLM.CredentialFilter do
  @moduledoc false

  use GenServer

  alias Loopex.LLM.ReqLLM.ProviderIOSink

  @filter_id :loopex_req_llm_credential_filter
  @filter_configuration :loopex_req_llm_v3
  @registry_name Loopex.LLM.ReqLLM.CredentialFilter.Registry
  @registry_identity :loopex_req_llm_credential_registry_v3
  @registry_protocol :loopex_req_llm_credential_registry_v3
  @capsule_tag :loopex_req_llm_credential_capsule_v1
  @activity_key {__MODULE__, :logger_activity}
  @provider_io_key {__MODULE__, :provider_io_originals}
  @registry_timeout 1_000
  @filter_timeout 250
  @redacted "[redacted credential]"

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, :start, Keyword.put_new(options, :name, @registry_name))
  end

  @doc false
  @spec ensure_installed() :: :ok | {:error, :credential_filter_unavailable}
  def ensure_installed do
    expected = expected_filter()

    with :ok <- install_or_verify_filter(expected),
         :ok <- verify_registry(),
         :ok <- verify_provider_io() do
      :ok
    else
      _unavailable -> {:error, :credential_filter_unavailable}
    end
  catch
    _kind, _reason -> {:error, :credential_filter_unavailable}
  end

  @doc false
  @spec acquire(binary()) :: {:ok, reference()} | {:error, :credential_filter_unavailable}
  def acquire(credential) when is_binary(credential) and credential != "" do
    with :ok <- ensure_installed(),
         {:ok, lease} <- transfer_credential(credential) do
      case verify_filter_and_registry() do
        :ok ->
          {:ok, lease}

        {:error, :credential_filter_unavailable} = unavailable ->
          _ = registry_call({:release, lease})
          unavailable
      end
    else
      _unavailable -> {:error, :credential_filter_unavailable}
    end
  catch
    _kind, _reason -> {:error, :credential_filter_unavailable}
  end

  def acquire(_credential), do: {:error, :credential_filter_unavailable}

  @doc false
  @spec isolate_provider_io() :: :ok | {:error, :credential_filter_unavailable}
  def isolate_provider_io, do: ensure_installed()

  @doc false
  @spec restore_provider_io(pid()) :: :ok | {:error, :credential_filter_unavailable}
  def restore_provider_io(fallback_group_leader) when is_pid(fallback_group_leader) do
    case registry_call({:restore_provider_io, fallback_group_leader}) do
      :ok -> :ok
      _unavailable -> {:error, :credential_filter_unavailable}
    end
  end

  @doc false
  @spec release(reference()) :: :ok
  def release(lease) when is_reference(lease) do
    # A missing acknowledgement deliberately leaves the active generation in
    # place. Losing the owner while a credential might still be live stops logs
    # and future provider attempts rather than silently reopening either plane.
    _ = registry_call({:release, lease})
    :ok
  end

  def release(_lease), do: :ok

  @doc false
  def filter(event, @filter_configuration) when is_map(event) do
    case :persistent_term.get(@activity_key, :missing) do
      {:idle, _epoch} ->
        :ignore

      {:active, registry, epoch} when is_pid(registry) and registry != self() ->
        sanitize_call(registry, epoch, event)

      _unavailable_or_unproved ->
        :stop
    end
  catch
    _kind, _reason -> :stop
  end

  def filter(_event, _configuration), do: :stop

  @impl GenServer
  def init(:start) do
    {mode, epoch} = startup_state()
    credentials = :ets.new(__MODULE__, [:set, :private])
    publish_activity(mode, epoch, credentials)

    with :ok <- install_filter_only(expected_filter()),
         :ok <- bind_provider_io() do
      {:ok,
       %{
         mode: mode,
         epoch: epoch,
         credentials: credentials,
         leases: %{},
         monitors: %{}
       }}
    else
      {:error, :credential_filter_unavailable} -> {:stop, :credential_filter_unavailable}
    end
  end

  @impl GenServer
  def handle_call(:identity, _from, %{mode: :healthy} = state) do
    {:reply, {:ok, @registry_identity}, state}
  end

  def handle_call(:identity, _from, state) do
    {:reply, {:error, :credential_filter_unavailable}, state}
  end

  def handle_call({:release, lease}, _from, %{mode: :healthy} = state)
      when is_reference(lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        {:reply, :ok, state}

      {{_owner, monitor}, leases} ->
        Process.demonitor(monitor, [:flush])
        true = :ets.delete(state.credentials, lease)
        monitors = Map.delete(state.monitors, monitor)
        next = advance_activity(%{state | leases: leases, monitors: monitors})
        {:reply, :ok, next}
    end
  end

  def handle_call({:release, _lease}, _from, state) do
    {:reply, {:error, :credential_filter_unavailable}, state}
  end

  def handle_call({:restore_provider_io, fallback}, _from, state) when is_pid(fallback) do
    result = restore_provider_io_leaders(fallback)
    {:reply, result, state}
  end

  def handle_call({:sanitize, epoch, event}, _from, %{mode: :healthy} = state)
      when is_integer(epoch) and epoch == state.epoch and is_map(event) do
    credentials = credential_values(state.credentials)

    reply =
      case credentials do
        [] -> :stop
        active -> safe_redact_event(event, active)
      end

    {:reply, reply, state}
  end

  def handle_call({:sanitize, _epoch, _event}, _from, state) do
    {:reply, :stop, state}
  end

  def handle_call(_unsupported, _from, state) do
    {:reply, {:error, :unsupported}, state}
  end

  @impl GenServer
  def handle_info(
        {:"ETS-TRANSFER", capsule, owner, {@capsule_tag, request_reference, lease}},
        state
      )
      when is_reference(request_reference) and is_reference(lease) and is_pid(owner) do
    case import_credential(capsule, owner, lease, state) do
      {:ok, next} ->
        send(owner, {@registry_protocol, self(), request_reference, {:ok, lease}})
        {:noreply, next}

      {:error, next} ->
        send(
          owner,
          {@registry_protocol, self(), request_reference,
           {:error, :credential_filter_unavailable}}
        )

        {:noreply, next}
    end
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    # The credential may still exist in a detached provider resource. Retaining
    # its value for redaction is the only safe conclusion after its owner dies.
    {:noreply, %{state | monitors: Map.delete(state.monitors, monitor)}}
  end

  def handle_info(_unknown, state), do: {:noreply, state}

  defp startup_state do
    case :persistent_term.get(@activity_key, :missing) do
      :missing -> {:healthy, 0}
      {:idle, epoch} when is_integer(epoch) -> {:healthy, epoch + 1}
      {:active, _registry, epoch} when is_integer(epoch) -> {:poisoned, epoch + 1}
      {:poisoned, epoch} when is_integer(epoch) -> {:poisoned, epoch + 1}
      _malformed -> {:poisoned, 0}
    end
  end

  defp publish_activity(:healthy, epoch, credentials) do
    marker =
      if :ets.info(credentials, :size) == 0 do
        {:idle, epoch}
      else
        {:active, self(), epoch}
      end

    :persistent_term.put(@activity_key, marker)
  end

  defp publish_activity(:poisoned, epoch, _credentials) do
    :persistent_term.put(@activity_key, {:poisoned, epoch})
  end

  defp advance_activity(state) do
    next = %{state | epoch: state.epoch + 1}
    publish_activity(next.mode, next.epoch, next.credentials)
    next
  end

  defp transfer_credential(credential) do
    capsule = :ets.new(:loopex_req_llm_credential_capsule, [:set, :private])

    try do
      true = :ets.insert(capsule, {:credential, credential})
      registry = Process.whereis(@registry_name)
      true = is_pid(registry)
      lease = make_ref()
      request_reference = make_ref()
      monitor = Process.monitor(registry)

      true =
        :ets.give_away(capsule, registry, {@capsule_tag, request_reference, lease})

      await_credential_transfer(registry, monitor, request_reference)
    after
      delete_owned_capsule(capsule)
    end
  catch
    _kind, _reason -> {:error, :credential_filter_unavailable}
  end

  defp await_credential_transfer(registry, monitor, request_reference) do
    receive do
      {@registry_protocol, ^registry, ^request_reference, response} ->
        Process.demonitor(monitor, [:flush])
        response

      {:DOWN, ^monitor, :process, ^registry, _reason} ->
        {:error, :credential_filter_unavailable}
    after
      @registry_timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :credential_filter_unavailable}
    end
  end

  defp delete_owned_capsule(capsule) do
    if :ets.info(capsule, :owner) == self() do
      :ets.delete(capsule)
    end
  catch
    _kind, _reason -> :ok
  end

  defp import_credential(capsule, owner, lease, %{mode: :healthy} = state) do
    result =
      try do
        case :ets.take(capsule, :credential) do
          [{:credential, credential}] when is_binary(credential) and credential != "" ->
            monitor = Process.monitor(owner)
            true = :ets.insert(state.credentials, {lease, credential})
            {:ok, monitor}

          _invalid ->
            :error
        end
      rescue
        _error -> :error
      catch
        _kind, _reason -> :error
      after
        delete_registry_capsule(capsule)
      end

    case result do
      {:ok, monitor} ->
        next =
          state
          |> Map.put(:leases, Map.put(state.leases, lease, {owner, monitor}))
          |> Map.put(:monitors, Map.put(state.monitors, monitor, lease))
          |> advance_activity()

        {:ok, next}

      :error ->
        {:error, state}
    end
  end

  defp import_credential(capsule, _owner, _lease, state) do
    delete_registry_capsule(capsule)
    {:error, state}
  end

  defp delete_registry_capsule(capsule) do
    :ets.delete(capsule)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp credential_values(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_lease, credential} -> credential end)
    |> Enum.uniq()
  catch
    _kind, _reason -> []
  end

  defp expected_filter, do: {&__MODULE__.filter/2, @filter_configuration}

  defp installed_filter(expected) do
    filters = Map.get(:logger.get_primary_config(), :filters, [])

    case List.keyfind(filters, @filter_id, 0) do
      nil -> :absent
      {@filter_id, ^expected} -> :expected
      _different -> :different
    end
  end

  defp install_or_verify_filter(expected) do
    case installed_filter(expected) do
      :expected -> :ok
      :absent -> install_filter_only(expected)
      :different -> {:error, :credential_filter_unavailable}
    end
  end

  defp install_filter_only(expected) do
    case :logger.add_primary_filter(@filter_id, expected) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> verify_expected_filter(expected)
      {:error, _reason} -> {:error, :credential_filter_unavailable}
    end
  end

  defp verify_expected_filter(expected) do
    case installed_filter(expected) do
      :expected -> :ok
      _different -> {:error, :credential_filter_unavailable}
    end
  end

  defp verify_filter_and_registry do
    with :ok <- verify_expected_filter(expected_filter()),
         :ok <- verify_registry(),
         :ok <- verify_provider_io() do
      :ok
    end
  end

  defp verify_registry do
    case registry_call(:identity) do
      {:ok, @registry_identity} -> :ok
      _different -> {:error, :credential_filter_unavailable}
    end
  end

  defp verify_provider_io do
    with sink when is_pid(sink) <- Process.whereis(ProviderIOSink),
         supervisor when is_pid(supervisor) <- Process.whereis(ReqLLM.Supervisor),
         task_supervisor when is_pid(task_supervisor) <- Process.whereis(ReqLLM.TaskSupervisor),
         true <- group_leader?(supervisor, sink),
         true <- group_leader?(task_supervisor, sink) do
      :ok
    else
      _unavailable -> {:error, :credential_filter_unavailable}
    end
  end

  defp bind_provider_io do
    with sink when is_pid(sink) <- Process.whereis(ProviderIOSink),
         supervisor when is_pid(supervisor) <- Process.whereis(ReqLLM.Supervisor),
         task_supervisor when is_pid(task_supervisor) <- Process.whereis(ReqLLM.TaskSupervisor),
         processes = [supervisor, task_supervisor],
         {:ok, originals} <- provider_io_originals(processes, sink),
         :ok <- set_group_leaders(processes, sink, originals),
         true <- Enum.all?(processes, &group_leader?(&1, sink)) do
      :persistent_term.put(@provider_io_key, originals)
      :ok
    else
      _unavailable -> {:error, :credential_filter_unavailable}
    end
  catch
    _kind, _reason -> {:error, :credential_filter_unavailable}
  end

  defp provider_io_originals(processes, sink) do
    case :persistent_term.get(@provider_io_key, :missing) do
      originals when is_list(originals) ->
        merge_group_leaders(processes, sink, originals)

      :missing ->
        capture_group_leaders(processes)
    end
  end

  defp merge_group_leaders(processes, sink, originals) do
    root_original = originals |> List.first() |> original_leader(Process.group_leader())

    Enum.reduce_while(processes, {:ok, []}, fn process, {:ok, merged} ->
      case List.keyfind(originals, process, 0) do
        {^process, original} ->
          {:cont, {:ok, merged ++ [{process, original}]}}

        nil ->
          case Process.info(process, :group_leader) do
            {:group_leader, ^sink} ->
              {:cont, {:ok, merged ++ [{process, root_original}]}}

            {:group_leader, current} when is_pid(current) ->
              {:cont, {:ok, merged ++ [{process, current}]}}

            _missing ->
              {:halt, {:error, :credential_filter_unavailable}}
          end
      end
    end)
  end

  defp original_leader({_process, original}, _fallback), do: original
  defp original_leader(nil, fallback), do: fallback

  defp capture_group_leaders(processes) do
    Enum.reduce_while(processes, {:ok, []}, fn process, {:ok, originals} ->
      case Process.info(process, :group_leader) do
        {:group_leader, leader} when is_pid(leader) ->
          {:cont, {:ok, originals ++ [{process, leader}]}}

        _missing ->
          {:halt, {:error, :credential_filter_unavailable}}
      end
    end)
  end

  defp set_group_leaders(processes, leader, originals) do
    changed =
      Enum.reduce_while(processes, [], fn process, complete ->
        if Process.group_leader(process, leader) do
          {:cont, [process | complete]}
        else
          {:halt, :error}
        end
      end)

    case changed do
      :error ->
        _ = restore_pairs(originals, Process.group_leader())
        {:error, :credential_filter_unavailable}

      _complete ->
        :ok
    end
  catch
    _kind, _reason ->
      _ = restore_pairs(originals, Process.group_leader())
      {:error, :credential_filter_unavailable}
  end

  defp group_leader?(process, expected) do
    Process.info(process, :group_leader) == {:group_leader, expected}
  end

  defp restore_provider_io_leaders(fallback) do
    originals = :persistent_term.get(@provider_io_key, [])

    if restore_pairs(originals, fallback) == :ok do
      :persistent_term.erase(@provider_io_key)
      :ok
    else
      {:error, :credential_filter_unavailable}
    end
  catch
    _kind, _reason -> {:error, :credential_filter_unavailable}
  end

  defp restore_pairs(originals, fallback) do
    if Enum.all?(originals, fn {process, original} ->
         if Process.alive?(process) do
           leader = if Process.alive?(original), do: original, else: fallback
           Process.group_leader(process, leader) and group_leader?(process, leader)
         else
           true
         end
       end) do
      :ok
    else
      {:error, :credential_filter_unavailable}
    end
  catch
    _kind, _reason -> {:error, :credential_filter_unavailable}
  end

  defp registry_call(request) do
    case Process.whereis(@registry_name) do
      registry when is_pid(registry) -> safe_genserver_call(registry, request, @registry_timeout)
      nil -> {:error, :credential_filter_unavailable}
    end
  end

  defp sanitize_call(registry, epoch, event) do
    case safe_genserver_call(registry, {:sanitize, epoch, event}, @filter_timeout) do
      :ignore -> :ignore
      :stop -> :stop
      sanitized when is_map(sanitized) -> sanitized
      _invalid -> :stop
    end
  end

  defp safe_genserver_call(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, _reason -> {:error, :credential_filter_unavailable}
  end

  defp safe_redact_event(event, credentials) do
    redact_event(event, credentials)
  rescue
    _error -> :stop
  catch
    _kind, _reason -> :stop
  end

  defp redact_event(event, credentials) do
    with {:ok, message} <- redact_message(Map.fetch!(event, :msg), credentials) do
      event
      |> Map.put(:msg, message)
      |> redact_term(credentials)
    else
      :error -> :stop
    end
  end

  defp redact_message({:string, chardata}, credentials) do
    case iodata_to_binary(chardata) do
      {:ok, rendered} -> {:ok, {:string, redact_binary(rendered, credentials)}}
      :error -> :error
    end
  end

  defp redact_message({:report, report}, credentials) do
    rendered = inspect(report, limit: :infinity, printable_limit: :infinity)
    {:ok, {:string, redact_binary(rendered, credentials)}}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp redact_message({format, arguments}, credentials)
       when (is_binary(format) or is_list(format)) and is_list(arguments) do
    try do
      rendered = format |> :io_lib.format(arguments) |> IO.iodata_to_binary()
      {:ok, {:string, redact_binary(rendered, credentials)}}
    rescue
      _error -> :error
    catch
      _kind, _reason -> :error
    end
  end

  defp redact_message(_unknown, _credentials), do: :error

  defp redact_term(term, credentials) do
    Enum.reduce(credentials, term, &redact(&2, &1))
  end

  defp redact_binary(binary, credentials) do
    Enum.reduce(credentials, binary, fn credential, current ->
      :binary.replace(current, credential, @redacted, [:global])
    end)
  end

  defp redact(binary, credential) when is_binary(binary) do
    :binary.replace(binary, credential, @redacted, [:global])
  end

  defp redact([], _credential), do: []

  defp redact(list, credential) when is_list(list) do
    case iodata_to_binary(list) do
      {:ok, binary} -> redact(binary, credential)
      :error -> Enum.map(list, &redact(&1, credential))
    end
  end

  defp redact(tuple, credential) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&redact(&1, credential))
    |> List.to_tuple()
  end

  defp redact(map, credential) when is_map(map) do
    map
    |> Map.to_list()
    |> Map.new(fn {key, value} ->
      {redact(key, credential), redact(value, credential)}
    end)
  end

  defp redact(other, _credential), do: other

  defp iodata_to_binary(iodata) do
    {:ok, IO.iodata_to_binary(iodata)}
  rescue
    ArgumentError -> :error
  end
end
