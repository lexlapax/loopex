defmodule Loopex.ReferenceClient do
  @moduledoc """
  ## Concept

  The thin M1 embedded client. It starts one explicit runtime, creates or
  resumes one session, attaches, submits commands, consumes committed events,
  offers recovery evidence, and stops through `Loopex` only.

  ## Technical depth

  This module is a direct facade with no process and no reducer. Its struct holds
  transient public handles only; it owns no policy decision, Store reference,
  coordinator, model, executor, cursor truth, or alternate loop. Durable state
  and event authority remain behind the embedded API.
  """

  @opaque t :: %__MODULE__{
            runtime: Loopex.Runtime.t(),
            session_id: binary() | nil,
            attachment: term()
          }
  defstruct [:runtime, :session_id, :attachment]

  @prompt_bound_keys [:max_turns, :token_budget, :deadline_ms]
  @prompt_bounds %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 300_000}

  @doc """
  ## Concept

  Starts one explicitly configured embedded runtime.

  ## Technical depth

  Configuration passes unchanged to `Loopex.start_link/1`; the client neither
  discovers defaults nor rewrites host authority.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(options) when is_list(options) do
    case Loopex.start_link(options) do
      {:ok, runtime} -> {:ok, %__MODULE__{runtime: runtime}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  Creates and attaches to one durable session.

  ## Technical depth

  The returned client retains only the opaque attachment supplied by the API.
  """
  @spec create(t(), map(), binary()) :: {:ok, t()} | {:error, term()}
  def create(%__MODULE__{runtime: runtime} = client, genesis, command_id)
      when is_map(genesis) and is_binary(command_id) do
    with {:ok, session_id} <- Loopex.create_session(runtime, genesis, command_id: command_id),
         {:ok, attachment} <- Loopex.attach(runtime, session_id, after_event_sequence: 0) do
      {:ok, %{client | session_id: session_id, attachment: attachment}}
    end
  end

  @doc """
  ## Concept

  Resumes and reattaches to an existing durable session.

  ## Technical depth

  The caller supplies the durable event cursor. The client does not infer or
  persist one.
  """
  @spec resume(t(), binary(), binary(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def resume(%__MODULE__{runtime: runtime} = client, session_id, command_id, cursor)
      when is_binary(session_id) and is_binary(command_id) and is_integer(cursor) and cursor >= 0 do
    with {:ok, ^session_id} <-
           Loopex.resume_session(runtime, session_id, command_id: command_id),
         {:ok, attachment} <-
           Loopex.attach(runtime, session_id, after_event_sequence: cursor) do
      {:ok, %{client | session_id: session_id, attachment: attachment}}
    end
  end

  @doc """
  ## Concept

  Submits one user prompt to the attached session.

  ## Technical depth

  This is one direct embedded command; model and tool continuation occurs inside
  the runtime, not in this client.
  """
  @spec prompt(t(), binary(), binary(), keyword()) :: {:accepted, binary()} | {:error, term()}
  def prompt(%__MODULE__{attachment: attachment}, command_id, content, options \\ [])
      when is_binary(command_id) and is_binary(content) and is_list(options) do
    # Concept: a run declares its bounds when it starts.
    #
    # Technical depth: there is no default for any of the three, so this client
    # names them explicitly on the caller's behalf. A host embedding Loopex
    # decides its own; these are the reference client's, not the kernel's.
    with {:ok, bounds} <- prompt_bounds(options) do
      Loopex.command(attachment, %{
        type: :prompt,
        command_id: command_id,
        content: content,
        bounds: bounds
      })
    end
  end

  # Concept: the reference client names one visible five-minute allowance and
  # refuses to reinterpret misspelled caller input as a runtime default.
  #
  # Technical depth: `deadline_ms` is the accepted duration key. The runtime
  # converts it to an absolute instant when the first request is staged. An
  # unknown key is refused here before a command can become durable; otherwise a
  # misspelling survives `Map.merge/2` beside the runtime's ten-minute default
  # and the operator silently receives a different bound than the one supplied.
  defp prompt_bounds(options) do
    case Keyword.fetch(options, :bounds) do
      :error ->
        {:ok, @prompt_bounds}

      {:ok, bounds} when is_map(bounds) and not is_struct(bounds) ->
        if Map.keys(bounds) -- @prompt_bound_keys == [],
          do: {:ok, bounds},
          else: {:error, :invalid_declared_bounds}

      {:ok, _invalid} ->
        {:error, :invalid_declared_bounds}
    end
  end

  @doc """
  ## Concept

  Consumes the next committed event from the embedded attachment.

  ## Technical depth

  Empty and disconnection retain the API's exact semantics; no client queue or
  alternate cursor is introduced.
  """
  @spec next_event(t()) :: {:ok, map()} | {:disconnected, non_neg_integer()} | {:error, term()}
  def next_event(%__MODULE__{attachment: attachment}), do: Loopex.next_event(attachment)

  @doc """
  ## Concept

  Opens the runtime's current solicited recovery query.

  ## Technical depth

  The client stores no query. It returns the runtime value directly.
  """
  @spec reconciliation_query(t()) :: {:ok, map()} | {:error, term()}
  def reconciliation_query(%__MODULE__{attachment: attachment}),
    do: Loopex.reconciliation_query(attachment)

  @doc """
  ## Concept

  Offers one recovery response to the runtime.

  ## Technical depth

  Validation and the durable transition remain in the current session owner.
  """
  @spec reconcile(t(), map()) :: :ok | {:error, term()}
  def reconcile(%__MODULE__{attachment: attachment}, response) when is_map(response),
    do: Loopex.reconcile(attachment, response)

  @doc """
  ## Concept

  Observes the embedded session's current durable projection.

  ## Technical depth

  This delegates by explicit runtime and session ID and caches nothing.
  """
  @spec status(t()) :: {:ok, map()} | {:error, term()}
  def status(%__MODULE__{runtime: runtime, session_id: session_id}),
    do: Loopex.session_status(runtime, session_id)

  @doc """
  ## Concept

  Stops the explicit runtime.

  ## Technical depth

  Durable Store and executor ledgers are not deleted by client shutdown.
  """
  @spec stop(t()) :: :ok | {:error, term()}
  def stop(%__MODULE__{runtime: runtime}), do: Loopex.stop(runtime)
end
