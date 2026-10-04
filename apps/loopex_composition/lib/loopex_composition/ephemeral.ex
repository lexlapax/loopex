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
  Optional `:instructions` is ADR 0042's closed version/base/environment/appendix
  map. Omission captures the reference host's default with workspace and platform
  facts. Optional `:reasoning` is default, none, low, medium or high as a binary;
  omission selects default. Optional `:system_class_tokens` is a positive uint64
  ceiling; omission selects 1,000. All three are startup settings; per-call
  changes refuse. Preparation resolves model capabilities and the exact mapping,
  then admits current genesis with immutable selected tool definitions. Omitted
  context capacity derives from the captured model window minus the reply
  reserve, or 8,192 for an unknown window; explicit capacity remains explicit.
  Invalid whole settings refuse before owner activation or temporary resources.
  Optional `:maintenance_instructions` is the explicit closed version/body
  startup map. It is validated before allocating an owner and forwarded for
  Core's exact capture. Missing or nil stays unconfigured; per-call overrides
  are refused.
  Optional `:provider_bindings` admits only its named provider routes; omission
  selects the model provider's reference route. References stay private and values
  are resolved only by each invocation's sensitive caller. Optional
  `:maintenance_model` is a separately selected provider:model string with an
  admitted thinking-off mapping. Missing or nil remains unconfigured.
  Optional `:trace` uses the closed binary-keyed host trace map. Omission or a
  disabled selection creates no diagnostic actors. An enabled selection installs
  the owner-managed stderr consumer and starts tracing after capability binding,
  before the facade can dispatch work. It stays active across prompts and ends
  with the session. Startup refusal unwinds the owned composition; unproved
  diagnostic teardown prevents a successful cleanup acknowledgement. Per-call
  trace changes, callbacks, sinks and runtime references are refused.
  Optional `:questions` is Boolean and defaults false. True adds the exact
  model-question tool to a nonempty tool profile. A reusable session answers
  through `answer/3`; an empty profile with questions enabled refuses.
  """
  @spec start_session(keyword()) :: {:ok, session()} | {:error, reason()}
  def start_session(options) do
    with {:ok, configuration} <- Preflight.prepare(options),
         do: start_prepared(configuration)
  end

  defp start_prepared(configuration) do
    with {:ok, supervisor} <- owner_supervisor(),
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
  The one-call-only `:question_responder` is a host function receiving the
  bounded question DTO and returning tagged text, choice or decline. It stays
  outside startup and durable data. One supervised worker at a time answers
  through the serial owner's existing validation and command slot; its exact
  termination precedes another question and cleanup. The caller's wait deadline
  is captured once across all questions. Invalid replies and exceptions abort
  the run and return `:responder_failed` after proved cleanup. Expiry and run
  bounds retain Core's committed outcome. Host callback effects have no rollback;
  trusted host code must not recursively create another call or session here.
  With questions enabled and no callback, a contextual host policy denies the
  exact model-question generation before an interaction can open. Ordinary
  tool decisions still consult the supplied host policy.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(prompt, options \\ []) do
    with {:ok, startup_options, responder} <-
           LoopexComposition.Ephemeral.Options.run_options(options),
         :ok <- valid_prompt(prompt),
         {:ok, configuration} <- Preflight.prepare(startup_options),
         {:ok, session} <- start_prepared(one_shot_configuration(configuration, responder)) do
      {:loopex_ephemeral_session, owner, _cell} = session

      deadline =
        System.monotonic_time() +
          System.convert_time_unit(configuration.timeout, :millisecond, :native)

      first = request(owner, {:ask, prompt, {:deadline, deadline}})
      result = respond_to_questions(first, owner, responder, deadline)
      stop = stop_session(session)
      run_result(result, stop)
    end
  end

  defp respond_to_questions(
         {:error, {:interaction_pending, %{"producer" => "model_tool", "interaction_id" => id}}},
         owner,
         callback,
         deadline
       )
       when is_function(callback, 1) do
    result =
      case request(owner, {:question_responder, id, callback, deadline}) do
        {:ok, response} ->
          with {:ok, answer} <- answer_response(response) do
            case request(owner, {:answer_until, id, answer, deadline}) do
              {:error, :invalid_interaction_answer} -> request(owner, {:wait_run, deadline})
              other -> other
            end
          end

        {:error, :responder_expired} ->
          request(owner, {:wait_run, deadline})

        {:error, :responder_failed} ->
          {:error, :responder_failed}

        {:error, :responder_cancelled} ->
          {:error, :session_unavailable}

        other ->
          other
      end

    respond_to_questions(result, owner, callback, deadline)
  end

  defp respond_to_questions(result, _owner, _callback, _deadline), do: result

  defp one_shot_configuration(%{questions: true} = configuration, nil) do
    configuration
    |> Map.put(:policy_identity, %{"id" => inspect(configuration.policy), "revision" => "0.2.0"})
    |> Map.put(:policy, %{
      module: LoopexComposition.Ephemeral.QuestionPolicy,
      context: configuration.policy
    })
  end

  defp one_shot_configuration(configuration, _responder), do: configuration

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
  Choice-ID shorthand stays available; model questions also accept tagged text,
  tagged choice and explicit decline.

  ## Technical depth

  The handle is checked before response grammar. Responses are a choice ID,
  `{:choice, id}`, `{:text, text}` or `:decline`. Text is nonempty UTF-8 of at
  most 8,192 bytes. The serial owner checks the pending producer and kind before
  occupying its existing command slot: policy-defer questions remain choice-only.
  This call grants no authority and starts no responder worker.
  """
  @spec answer(
          session(),
          String.t(),
          String.t() | {:choice, binary()} | {:text, binary()} | :decline
        ) ::
          {:ok, map()} | {:error, term()}
  def answer(session, interaction_id, response) do
    with {:ok, owner} <- available(session, :read),
         true <- bounded_id?(interaction_id, 256),
         {:ok, answer} <- answer_response(response) do
      request(owner, {:answer, interaction_id, answer})
    else
      false -> {:error, :invalid_interaction_answer}
      error -> error
    end
  end

  defp answer_response({:choice, id}), do: answer_response(id)

  defp answer_response(id) when is_binary(id) do
    if bounded_id?(id, 64), do: {:ok, id}, else: {:error, :invalid_interaction_answer}
  end

  defp answer_response({:text, text}), do: model_response(%{"text" => text})
  defp answer_response(:decline), do: model_response(%{"disposition" => "declined"})
  defp answer_response(_), do: {:error, :invalid_interaction_answer}

  defp model_response(answer) do
    case LoopexProtocol.Session.Answer.normalize(answer) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_interaction_answer}
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
  defp run_result({:responder_join_unproved, uncertainty}, :ok), do: uncertainty
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
