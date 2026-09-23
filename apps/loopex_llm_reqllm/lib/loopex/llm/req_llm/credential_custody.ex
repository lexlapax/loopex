defmodule Loopex.LLM.ReqLLM.CredentialCustody do
  @moduledoc """
  ## Concept

  A host-owned process keeps one provider credential outside runtime,
  diagnostics, configuration, and durable state, and releases the current
  value only to an invocation sender that holds its exact private reference.

  ## Technical depth

  Resolution uses one deadline-free `GenServer.call`: the caller's guardian
  owns the invocation deadline. The only credential-bearing reply is the exact
  keyed map `{:ok, %{credential: bytes}}`. State, messages, reasons, and logs
  are replaced in OTP status and crash reports. Rotation replaces the one copy
  in custody and does not change the reference.
  """

  use GenServer

  alias Loopex.LLM.ReqLLM.CredentialCustody.Ref

  require Logger

  @max_credential_bytes 65_536

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec reference(pid()) :: {:ok, Ref.t()} | {:error, :unavailable}
  def reference(pid) when is_pid(pid) do
    try do
      GenServer.call(pid, :reference)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  def reference(_pid), do: {:error, :unavailable}

  @doc false
  @spec resolve(Ref.t()) ::
          {:ok, %{credential: binary()}} | {:error, :missing | :expired | :unavailable}
  def resolve(reference) do
    with :ok <- validate(reference) do
      try do
        GenServer.call(reference.pid, {:resolve, reference.incarnation}, :infinity)
      catch
        :exit, _reason -> {:error, :unavailable}
      end
    else
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc false
  @spec rotate(Ref.t(), binary() | nil, integer() | :infinity) ::
          :ok | {:error, :unavailable}
  def rotate(reference, credential, expires_at \\ :infinity) do
    with :ok <- validate(reference),
         :ok <- validate_credential(credential),
         :ok <- validate_expiry(expires_at) do
      try do
        GenServer.call(
          reference.pid,
          {:rotate, reference.incarnation, credential, expires_at},
          :infinity
        )
      catch
        :exit, _reason -> {:error, :unavailable}
      end
    else
      _invalid -> {:error, :unavailable}
    end
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, :invalid_custody_reference}
  def validate(%Ref{} = reference) do
    if map_size(reference) == 3 and
         Map.keys(reference) |> Enum.sort() == [:__struct__, :incarnation, :pid] and
         is_pid(reference.pid) and node(reference.pid) == node() and
         Process.alive?(reference.pid) and is_binary(reference.incarnation) and
         byte_size(reference.incarnation) == 16 do
      :ok
    else
      {:error, :invalid_custody_reference}
    end
  end

  def validate(_reference), do: {:error, :invalid_custody_reference}

  @impl GenServer
  def init(options) do
    credential = Keyword.get(options, :credential)
    expires_at = Keyword.get(options, :expires_at, :infinity)

    with :ok <- validate_credential(credential),
         :ok <- validate_expiry(expires_at) do
      Logger.debug("provider credential custody started")

      {:ok,
       %{
         incarnation: :crypto.strong_rand_bytes(16),
         credential: credential,
         expires_at: expires_at
       }}
    else
      _invalid -> {:stop, :invalid_credential_custody}
    end
  end

  @impl GenServer
  def handle_call(:reference, _from, state) do
    {:reply, {:ok, %Ref{pid: self(), incarnation: state.incarnation}}, state}
  end

  def handle_call({:resolve, incarnation}, _from, %{incarnation: incarnation} = state) do
    reply =
      cond do
        is_nil(state.credential) ->
          {:error, :missing}

        state.expires_at != :infinity and System.monotonic_time(:millisecond) >= state.expires_at ->
          {:error, :expired}

        true ->
          {:ok, %{credential: state.credential}}
      end

    {:reply, reply, state}
  end

  def handle_call({:resolve, _incarnation}, _from, state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call(
        {:rotate, incarnation, credential, expires_at},
        _from,
        %{incarnation: incarnation} = state
      ) do
    Logger.debug("provider credential custody rotated")
    {:reply, :ok, %{state | credential: credential, expires_at: expires_at}}
  end

  def handle_call({:rotate, _incarnation, _credential, _expires_at}, _from, state) do
    {:reply, {:error, :unavailable}, state}
  end

  # Concept: a request this process does not recognize is refused, never a
  # crash: a crash's exit reason carries its arguments and state to every
  # monitor and linked owner, and GenServer's default for an unexpected
  # message logs its content. Either could carry credential bytes.
  def handle_call(_request, _from, state), do: {:reply, {:error, :unavailable}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_credential_custody_state)
    |> Map.put(:message, :redacted_credential_custody_message)
    |> Map.put(:reason, :redacted_credential_custody_reason)
    |> Map.put(:log, [])
  end

  defp validate_credential(nil), do: :ok

  defp validate_credential(credential)
       when is_binary(credential) and byte_size(credential) in 1..@max_credential_bytes,
       do: :ok

  defp validate_credential(_credential), do: {:error, :invalid_credential}

  defp validate_expiry(:infinity), do: :ok
  defp validate_expiry(expires_at) when is_integer(expires_at), do: :ok
  defp validate_expiry(_expires_at), do: {:error, :invalid_expiry}
end
