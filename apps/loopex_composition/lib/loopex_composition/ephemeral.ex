defmodule LoopexComposition.Ephemeral do
  @moduledoc """
  ## Concept

  Starts one ephemeral Loopex session without a caller-supplied state root. The
  returned in-VM handle belongs to the process that created it and is usable
  only after the session, attachment and selected resources are ready.

  ## Technical depth

  Shared preflight finishes before a temporary owner receives configuration.
  The owner is a temporary supervised child monitored by the creator, never
  linked to it. The handle carries only that owner and its session-local
  lifecycle cell. Startup failure returns the owner's fixed public error after
  its bounded cleanup attempt; no partial handle is exposed.
  """

  alias LoopexComposition.Ephemeral.{OwnerActivation, Preflight, SessionOwner}

  @uint64_max 18_446_744_073_709_551_615
  @prompt_max 32_768
  @stop_response_ms 11_000

  @opaque session() :: {:loopex_ephemeral_session, pid(), :atomics.atomics_ref()}
  @type reason() :: term()

  @doc """
  ## Concept

  Creates an ephemeral session from one host-selected policy and optional model,
  tool, skill, workspace and bound choices.

  ## Technical depth

  Grammar and shared dependency checks run before owner activation. One private
  begin token gives a single owner permission to start its temporary subtree.
  Its result is withheld until the facade attachment, selected resources and
  active status have all been confirmed under the same startup deadline.
  Optional `:maintenance_instructions` is the explicit closed version/body
  startup map. It is validated before allocating an owner and forwarded for
  Core's exact capture. Missing or nil stays unconfigured; per-call overrides
  are refused.
  Optional `:provider_bindings` admits only its named provider routes; omission
  retains the legacy single-route defaults. References stay private and values
  are resolved only by each invocation's sensitive caller. Optional
  `:maintenance_model` is a separately selected provider:model string with an
  admitted thinking-off mapping. Missing or nil remains unconfigured.
  """
  @spec start_session(keyword()) :: {:ok, session()} | {:error, reason()}
  def start_session(options) do
    with {:ok, configuration} <- Preflight.prepare(options),
         {:ok, supervisor} <- owner_supervisor(),
         {:ok, activation} <- OwnerActivation.start(supervisor),
         {:ok, cell} <- OwnerActivation.begin(activation),
         owner = OwnerActivation.owner(activation),
         {:ok, :session_ready} <- SessionOwner.start_session(owner, configuration, 16_000) do
      {:ok, {:loopex_ephemeral_session, owner, cell}}
    end
  end

  @doc """
  ## Concept

  Runs one prompt in a new ephemeral session, then stops that session.

  ## Technical depth

  The stop is mandatory after a handle exists. An unproved stop takes precedence
  over the prompt result so the caller is not told its temporary root vanished.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(prompt, options \\ []) do
    with {:ok, _selected} <- LoopexComposition.Ephemeral.Options.parse(options),
         :ok <- valid_prompt(prompt),
         {:ok, session} <- start_session(options) do
      first = ask(session, prompt)
      stop = stop_session(session)
      run_result(first, stop)
    end
  end

  @doc """
  ## Concept

  Admits one prompt to an open session and waits for its next question or ending.

  ## Technical depth

  The handle check precedes options and prompt validation. The owner alone
  dispatches commands and reads the attachment; this caller only waits on its
  exact monitored request.
  """
  @spec ask(session(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ask(session, prompt, options \\ []) do
    with {:ok, owner} <- available(session, :read),
         {:ok, timeout} <- ask_timeout(options),
         :ok <- valid_prompt(prompt) do
      request(owner, {:ask, prompt, timeout})
    end
  end

  @doc """
  ## Concept

  Answers the session's current pending interaction by its exact offered id.

  ## Technical depth

  Identifier shape is checked after the handle, before the owner compares the
  live pending question and its choices.
  """
  @spec answer(session(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def answer(session, interaction_id, choice_id) do
    with {:ok, owner} <- available(session, :read),
         true <- bounded_id?(interaction_id, 256) and bounded_id?(choice_id, 64) do
      request(owner, {:answer, interaction_id, choice_id})
    else
      false -> {:error, :invalid_interaction_answer}
      error -> error
    end
  end

  @doc """
  ## Concept

  Reads the latest observation of the current run without consuming it.

  ## Technical depth

  The owner retains the projection and never opens a second event reader.
  """
  @spec last_result(session()) :: {:ok, map()} | {:error, term()} | :none
  def last_result(session) do
    with {:ok, owner} <- available(session, :read), do: request(owner, :last_result)
  end

  @doc """
  ## Concept

  Reads the session's bounded committed conversation projection.

  ## Technical depth

  This operation neither mutates the session nor consumes an attachment event.
  """
  @spec history(session()) :: {:ok, map()} | {:error, term()}
  def history(session) do
    with {:ok, owner} <- available(session, :read), do: request(owner, :history)
  end

  @doc """
  ## Concept

  Stops a session and returns success only after its cleanup is proved.

  ## Technical depth

  The shared cell makes proved closure idempotent even after the owner exits.
  An unproved live owner may accept a bounded retry.
  """
  @spec stop_session(session()) :: :ok | {:error, term()}
  def stop_session(session) do
    with {:ok, owner} <- available(session, :stop), do: request(owner, :stop)
  end

  defp run_result(_first, {:error, {:cleanup_unproved, _}} = stop), do: stop

  defp run_result({:error, {:cleanup_unproved, %{ending: ending}}} = first, stop) do
    case stop do
      :ok -> one_shot_ending(ending)
      {:error, :session_unavailable} -> first
      other -> other
    end
  end

  defp run_result(_first, {:error, :session_unavailable} = stop), do: stop
  defp run_result(first, :ok), do: one_shot_ending(first)

  defp one_shot_ending({:error, {:interaction_pending, _}}),
    do: {:error, :interaction_requires_session}

  defp one_shot_ending(:none), do: {:error, :session_unavailable}
  defp one_shot_ending(other), do: other

  defp available({:loopex_ephemeral_session, owner, cell}, operation)
       when is_pid(owner) and is_reference(cell) do
    try do
      case {:atomics.get(cell, 1), operation, Process.alive?(owner)} do
        {2, :stop, _} -> {:ok, :proved_closed}
        {2, _, _} -> {:error, :session_closed}
        {state, :stop, true} when state in [0, 1, 3] -> {:ok, owner}
        {0, :read, true} -> {:ok, owner}
        _ -> {:error, :session_unavailable}
      end
    rescue
      _ -> {:error, :session_unavailable}
    end
  end

  defp available(_session, _operation), do: {:error, :session_unavailable}

  defp request(:proved_closed, :stop), do: :ok

  # Concept: a stop whose owner cannot answer is unavailable, never proved.
  # Technical depth: the owner's own cleanup deadline is 5,000 ms of grace
  # plus 5,000 ms of teardown. The requester has 11,000 ms to answer and
  # at most 1,000 ms more to be reaped. The helper owns any late owner reply;
  # its answer to the host goes through a process alias that is retired before
  # this function returns, so even a helper whose DOWN is delayed cannot put
  # a stale result in the host mailbox.
  defp request(owner, :stop) do
    parent = self()
    tag = make_ref()
    reply_to = Process.alias()

    {worker, monitor} =
      spawn_monitor(fn ->
        parent_monitor = Process.monitor(parent)

        case request_owner(owner, :stop, parent_monitor, parent) do
          :parent_down -> :ok
          result -> send(reply_to, {self(), tag, result})
        end
      end)

    try do
      await_stop(worker, monitor, tag, System.monotonic_time(:millisecond) + @stop_response_ms)
    after
      Process.unalias(reply_to)

      receive do
        {^worker, ^tag, _result} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp request(owner, operation), do: request_owner(owner, operation)

  defp request_owner(owner, operation, parent_monitor \\ nil, parent \\ nil) do
    reference = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {self(), reference, :public, operation})
    await(owner, reference, monitor, parent_monitor, parent)
  end

  defp await_stop(worker, monitor, tag, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^worker, ^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        receive do
          {^worker, ^tag, result} -> result
        after
          0 -> {:error, :session_unavailable}
        end
    after
      remaining ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        after
          1_000 -> :ok
        end

        receive do
          {^worker, ^tag, _result} -> :ok
        after
          0 -> :ok
        end

        {:error, :session_unavailable}
    end
  end

  defp await(owner, reference, monitor, parent_monitor, parent) do
    receive do
      {^owner, ^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :session_unavailable}

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        Process.demonitor(monitor, [:flush])
        :parent_down
    after
      1_000 -> await(owner, reference, monitor, parent_monitor, parent)
    end
  end

  defp ask_timeout(options) when is_list(options) do
    cond do
      not Keyword.keyword?(options) ->
        {:error, {:invalid_option, :options}}

      length(options) != length(Enum.uniq_by(options, &elem(&1, 0))) ->
        {:error, {:invalid_option, :duplicate_key}}

      Enum.any?(options, fn {key, _} -> key != :timeout end) ->
        {:error, {:invalid_option, :unknown_key}}

      options == [] ->
        {:ok, nil}

      true ->
        timeout = Keyword.fetch!(options, :timeout)

        if positive_uint64?(timeout),
          do: {:ok, timeout},
          else: {:error, {:invalid_option, :timeout}}
    end
  end

  defp ask_timeout(_options), do: {:error, {:invalid_option, :options}}

  defp valid_prompt(prompt) when is_binary(prompt) do
    cond do
      byte_size(prompt) == 0 -> {:error, {:invalid_prompt, :empty}}
      byte_size(prompt) > @prompt_max -> {:error, {:invalid_prompt, :too_large}}
      not String.valid?(prompt) -> {:error, {:invalid_prompt, :invalid_utf8}}
      true -> :ok
    end
  end

  defp valid_prompt(_prompt), do: {:error, {:invalid_prompt, :invalid_utf8}}

  defp bounded_id?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp positive_uint64?(value),
    do: is_integer(value) and value > 0 and value <= @uint64_max

  defp owner_supervisor do
    case Process.whereis(LoopexComposition.Ephemeral.OwnerSupervisor) do
      supervisor when is_pid(supervisor) -> {:ok, supervisor}
      _ -> {:error, {:composition, :composition_application_start_failed}}
    end
  end
end
