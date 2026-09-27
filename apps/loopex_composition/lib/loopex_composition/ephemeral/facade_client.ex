defmodule LoopexComposition.Ephemeral.FacadeClient do
  @moduledoc """
  ## Concept

  Private, non-restarting session client. The creating owner chooses each
  operation and grants its dispatch. This actor alone holds the attachment.

  ## Technical depth

  `start/2` returns the actual linked process and its monitor. One owner request
  `{owner, reference, operation}` produces `{client, reference, :ready}`.
  Only `{owner, reference, :dispatch, native_deadline}` enters the facade;
  `{owner, reference, :cancel}` instead returns `:cancelled`. Results retain
  the facade's shape. Exceptions become `{:error, :facade_client_failed}`.

  Closed private operation variants are `:create`, `:attach`, `:resource_catalog`,
  `:session_status`, `{:command, command_map}` and `:next_event`. Creation uses
  command id `"create"`; attachment starts at sequence zero. The owner sequences
  startup and commands and kills an overdue operation. Deadlines use native
  monotonic time. The actor creates no workflow, timeout worker or retry.
  """

  @doc false
  def start(owner, runtime), do: start(owner, runtime, Loopex)

  @doc false
  def start(owner, runtime, facade) when owner == self() do
    :erlang.spawn_opt(
      fn ->
        monitor = Process.monitor(owner)

        loop(%{
          owner: owner,
          monitor: monitor,
          runtime: runtime,
          facade: facade,
          session: nil,
          attachment: nil
        })
      end,
      [:link, :monitor]
    )
  end

  defp loop(state) do
    receive do
      {owner, ref, operation} when owner == state.owner and is_reference(ref) ->
        if valid_operation?(operation) do
          send(owner, {self(), ref, :ready})
          await_grant(state, ref, operation)
        else
          loop(state)
        end

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.monitor and owner == state.owner ->
        :ok

      _other ->
        loop(state)
    after
      1_000 -> loop(state)
    end
  end

  defp await_grant(state, ref, operation) do
    receive do
      {owner, ^ref, :cancel} when owner == state.owner ->
        send(owner, {self(), ref, :cancelled})
        loop(state)

      {owner, ^ref, :dispatch, deadline}
      when owner == state.owner and is_integer(deadline) ->
        if deadline > System.monotonic_time() do
          {result, state} = execute(state, operation)
          send(owner, {self(), ref, result})
          loop(state)
        else
          await_grant(state, ref, operation)
        end

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.monitor and owner == state.owner ->
        :ok

      _other ->
        await_grant(state, ref, operation)
    after
      1_000 -> await_grant(state, ref, operation)
    end
  end

  defp valid_operation?(operation)
       when operation in [:create, :attach, :resource_catalog, :session_status, :next_event],
       do: true

  defp valid_operation?({:command, command}) when is_map(command), do: true
  defp valid_operation?(_operation), do: false

  defp execute(state, operation) do
    try do
      invoke(state, operation)
    rescue
      _exception -> {{:error, :facade_client_failed}, state}
    catch
      _kind, _reason -> {{:error, :facade_client_failed}, state}
    end
  end

  defp invoke(%{session: nil} = state, :create) do
    result =
      state.facade.create_session(state.runtime, %{"surface" => "embedded"}, command_id: "create")

    state =
      case result do
        {:ok, session} when is_binary(session) -> %{state | session: session}
        _other -> state
      end

    {result, state}
  end

  defp invoke(%{session: session, attachment: nil} = state, :attach) when is_binary(session) do
    result = state.facade.attach(state.runtime, session, after_event_sequence: 0)

    state =
      case result do
        {:ok, attachment} -> %{state | attachment: attachment}
        _other -> state
      end

    {result, state}
  end

  defp invoke(%{session: session} = state, :resource_catalog) when is_binary(session),
    do: {state.facade.resource_catalog(state.runtime, session), state}

  defp invoke(%{session: session} = state, :session_status) when is_binary(session),
    do: {state.facade.session_status(state.runtime, session), state}

  defp invoke(%{attachment: attachment} = state, {:command, command}) when not is_nil(attachment),
    do: {state.facade.command(attachment, command), state}

  defp invoke(%{attachment: attachment} = state, :next_event) when not is_nil(attachment),
    do: {state.facade.next_event(attachment), state}

  defp invoke(state, _operation), do: {{:error, :facade_client_failed}, state}
end
