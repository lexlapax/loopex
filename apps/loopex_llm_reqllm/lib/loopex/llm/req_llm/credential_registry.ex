defmodule Loopex.LLM.ReqLLM.CredentialRegistry do
  @moduledoc """
  ## Concept

  A runtime host maps opaque credential tokens to private custody references so
  invocations can resolve independently without a process-wide credential slot.

  ## Technical depth

  Rows contain routing only. `route/2` is deadline-free because the invocation
  guardian owns the sole clock, validates both the exact token and exact
  custody-reference shapes, and normalizes every missing, dead, malformed, or
  producer-invalid outcome to `:unavailable`. OTP status and crash output expose
  no token or route.
  """

  use GenServer

  alias Loopex.LLM.ReqLLM.CredentialCustody
  alias Loopex.LLM.ReqLLM.CredentialRegistry.Handle
  alias Loopex.LLM.ReqLLM.CredentialToken

  require Logger

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options),
    do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec handle(pid()) :: {:ok, Handle.t()} | {:error, :unavailable}
  def handle(pid) when is_pid(pid) do
    try do
      GenServer.call(pid, :handle)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  def handle(_pid), do: {:error, :unavailable}

  @doc false
  @spec put(Handle.t(), CredentialToken.t(), CredentialCustody.Ref.t()) ::
          :ok | {:error, :unavailable}
  def put(handle, token, custody) do
    with :ok <- validate(handle),
         :ok <- CredentialToken.validate(token),
         :ok <- CredentialCustody.validate(custody) do
      call(handle, {:put, handle.incarnation, token, custody})
    else
      _invalid -> {:error, :unavailable}
    end
  end

  @doc false
  @spec route(Handle.t(), CredentialToken.t()) ::
          {:ok, CredentialCustody.Ref.t()} | {:error, :unavailable}
  def route(handle, token) do
    with :ok <- validate(handle),
         :ok <- CredentialToken.validate(token),
         {:ok, custody} <- call(handle, {:route, handle.incarnation, token}),
         :ok <- CredentialCustody.validate(custody) do
      {:ok, custody}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, :invalid_registry_handle}
  def validate(%Handle{} = handle) do
    if map_size(handle) == 3 and
         Map.keys(handle) |> Enum.sort() == [:__struct__, :incarnation, :pid] and
         is_pid(handle.pid) and node(handle.pid) == node() and Process.alive?(handle.pid) and
         is_binary(handle.incarnation) and byte_size(handle.incarnation) == 16 do
      :ok
    else
      {:error, :invalid_registry_handle}
    end
  end

  def validate(_handle), do: {:error, :invalid_registry_handle}

  @impl GenServer
  def init(_options) do
    Logger.debug("provider credential registry started")
    {:ok, %{incarnation: :crypto.strong_rand_bytes(16), routes: %{}}}
  end

  @impl GenServer
  def handle_call(:handle, _from, state) do
    {:reply, {:ok, %Handle{pid: self(), incarnation: state.incarnation}}, state}
  end

  def handle_call(
        {:put, incarnation, %CredentialToken{} = token, custody},
        _from,
        %{incarnation: incarnation} = state
      ) do
    Logger.debug("provider credential route installed")
    {:reply, :ok, %{state | routes: Map.put(state.routes, token, custody)}}
  end

  def handle_call({:put, _incarnation, _token, _custody}, _from, state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call(
        {:route, incarnation, %CredentialToken{} = token},
        _from,
        %{incarnation: incarnation} = state
      ) do
    reply =
      case Map.fetch(state.routes, token) do
        {:ok, custody} -> {:ok, custody}
        :error -> {:error, :unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:route, _incarnation, _token}, _from, state) do
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
    |> Map.put(:state, :redacted_credential_registry_state)
    |> Map.put(:message, :redacted_credential_registry_message)
    |> Map.put(:reason, :redacted_credential_registry_reason)
    |> Map.put(:log, [])
  end

  defp call(%Handle{pid: pid}, message) do
    try do
      GenServer.call(pid, message, :infinity)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end
end
