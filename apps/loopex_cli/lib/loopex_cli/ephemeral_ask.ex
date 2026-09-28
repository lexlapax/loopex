defmodule LoopexCli.EphemeralAsk do
  @moduledoc """
  ## Concept

  Runs one standalone question in an ephemeral session. The command's main
  process owns the session handle, stops it after the question, and prints only
  after the signal handler has decided whether ordinary completion or an
  interrupt won.

  ## Technical depth

  A monitored worker makes the blocking `ask/2` call. Its result is provisional
  until its exact `DOWN`, the mandatory session stop, and the correlated
  signal-manager finish have all been observed. Only the fixed command renderer
  sees the selected public observation and cleanup proof.
  """

  alias LoopexCli.{AskResult, Interrupt}
  alias LoopexComposition.Ephemeral

  @reap_ms 1_000
  @manager_poll_ms 250

  @doc """
  ## Concept

  Returns one complete ephemeral `ask` command result without printing it.

  ## Technical depth

  The caller has already admitted arguments, workspace and prompt. The fourth
  argument replaces named process boundaries in tests; production uses the
  public ephemeral API and the exact signal manager.
  """
  @spec run(map(), binary(), binary(), keyword()) :: map()
  def run(options, cwd, prompt, seams \\ []) do
    dependencies = Map.merge(defaults(), Map.new(seams))
    mode = if options.output == "json", do: :json, else: :text

    case protected(fn -> dependencies.quiet_logger.() end) do
      {:ok, :ok} ->
        start(options, cwd, prompt, mode, dependencies)

      _ ->
        AskResult.diagnostic(:composition_unavailable)
    end
  end

  defp start(options, cwd, prompt, mode, dependencies) do
    reference = make_ref()

    case protected(fn -> dependencies.install_interrupt.(self(), reference) end) do
      {:ok, {:ok, manager}} when is_pid(manager) ->
        if signal_manager?(manager, reference, dependencies) do
          start_with_handler(options, cwd, prompt, mode, dependencies, manager, reference)
        else
          _ = protected(fn -> dependencies.finish_interrupt.(manager, reference) end)
          AskResult.diagnostic(:interrupt_handler_unavailable)
        end

      _ ->
        AskResult.diagnostic(:interrupt_handler_unavailable)
    end
  end

  defp start_with_handler(options, cwd, prompt, mode, dependencies, manager, reference) do
    case protected(fn -> dependencies.start_session.(session_options(options, cwd)) end) do
      {:ok, {:ok, session}} ->
        run_session(session, prompt, mode, dependencies, manager, reference)

      {:ok, {:error, {:cleanup_unproved, map}}} ->
        finish_startup(
          AskResult.render(:none, {:unproved, map}, mode),
          {:error, {:cleanup_unproved, map}},
          mode,
          dependencies,
          manager,
          reference
        )

      {:ok, {:error, reason}} ->
        finish_startup(
          AskResult.diagnostic(startup_code(reason)),
          :none,
          mode,
          dependencies,
          manager,
          reference
        )

      _ ->
        finish_startup(
          AskResult.diagnostic(:composition_unavailable),
          :none,
          mode,
          dependencies,
          manager,
          reference
        )
    end
  end

  defp finish_startup(result, cleanup, mode, dependencies, manager, reference) do
    case protected(fn -> dependencies.finish_interrupt.(manager, reference) end) do
      {:ok, {:ok, :ordinary}} -> result
      {:ok, {:ok, :interrupted}} -> %{result | status: 130, stdout: ""}
      _ -> cleanup_diagnostic(cleanup, :none, mode, :interrupt_handler_unavailable)
    end
  end

  defp defaults do
    %{
      start_session: &Ephemeral.start_session/1,
      ask: &Ephemeral.ask/2,
      start_worker: &spawn_monitor/1,
      worker_after_send: fn -> :ok end,
      stop_session: &Ephemeral.stop_session/1,
      quiet_logger: fn -> :logger.set_primary_config(:level, :none) end,
      install_interrupt: &Interrupt.install_ask/2,
      finish_interrupt: &Interrupt.finish_ask/2,
      handler_live: &Interrupt.ask_live/2,
      interrupt_phase: &Interrupt.ask_phase/2,
      signal_manager: fn -> Process.whereis(:erl_signal_server) end,
      halt: &System.halt/1,
      monotonic_ms: fn -> System.monotonic_time(:millisecond) end
    }
  end

  defp session_options(options, cwd) do
    [policy: options.policy, cwd: cwd, tools: options.tools, skills: options.skills] ++
      optional(:model, options.model) ++
      optional(:max_steps, options.max_steps) ++
      optional(:deadline_ms, options.deadline_ms)
  end

  defp optional(_key, nil), do: []
  defp optional(key, value), do: [{key, value}]

  defp run_session(session, prompt, mode, dependencies, manager, reference) do
    if signal_manager?(manager, reference, dependencies) do
      case protected(fn -> dependencies.interrupt_phase.(manager, reference) end) do
        {:ok, :stopping} ->
          stop = stop(session, dependencies)

          case protected(fn -> dependencies.finish_interrupt.(manager, reference) end) do
            {:ok, {:ok, :interrupted}} -> render_interrupted(:none, stop, mode)
            _ -> cleanup_diagnostic(stop, :none, mode, :interrupt_handler_unavailable)
          end

        {:ok, :idle} ->
          run_worker(session, prompt, mode, dependencies, manager, reference)

        _ ->
          stop_diagnostic(
            session,
            mode,
            dependencies,
            manager,
            reference,
            :interrupt_handler_unavailable
          )
      end
    else
      stop_diagnostic(
        session,
        mode,
        dependencies,
        manager,
        reference,
        :interrupt_handler_unavailable
      )
    end
  end

  defp run_worker(session, prompt, mode, dependencies, manager, reference) do
    main = self()

    case protected(fn -> Process.monitor(manager) end) do
      {:ok, manager_monitor} when is_reference(manager_monitor) ->
        try do
          case protected(fn ->
                 dependencies.start_worker.(fn ->
                   result = dependencies.ask.(session, prompt)
                   send(main, {self(), reference, result})
                   dependencies.worker_after_send.()
                 end)
               end) do
            {:ok, {worker, worker_monitor}}
            when is_pid(worker) and is_reference(worker_monitor) ->
              await_worker(%{
                session: session,
                mode: mode,
                dependencies: dependencies,
                reference: reference,
                manager: manager,
                manager_monitor: manager_monitor,
                worker: worker,
                worker_monitor: worker_monitor
              })

            _ ->
              finish_worker_start_failure(session, mode, dependencies, manager, reference)
          end
        after
          Process.demonitor(manager_monitor, [:flush])
        end

      _ ->
        finish_worker_start_failure(session, mode, dependencies, manager, reference)
    end
  end

  defp finish_worker_start_failure(session, mode, dependencies, manager, reference) do
    stop = stop(session, dependencies)

    case protected(fn -> dependencies.finish_interrupt.(manager, reference) end) do
      {:ok, {:ok, :ordinary}} -> cleanup_diagnostic(stop, :none, mode, :command_failed)
      {:ok, {:ok, :interrupted}} -> render_interrupted(:none, stop, mode)
      _ -> cleanup_diagnostic(stop, :none, mode, :interrupt_handler_unavailable)
    end
  end

  defp await_worker(state) do
    %{worker: worker, worker_monitor: worker_monitor, manager: manager, reference: reference} =
      state

    receive do
      {^worker, ^reference, result} ->
        reap_provisional(state, result, state.dependencies.monotonic_ms.() + @reap_ms)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        result = queued_result(worker, reference)
        finish_ordinary(state, result)

      {^manager, ^reference, :interrupt} ->
        case interrupt_phase(state) do
          :stopping -> finish_interrupted(state, :none)
          :idle -> await_worker(state)
          :unavailable -> finish_manager_failure(state)
        end

      {:DOWN, manager_monitor, :process, ^manager, _reason}
      when manager_monitor == state.manager_monitor ->
        finish_manager_failure(state)
    after
      @manager_poll_ms ->
        if signal_manager?(manager, reference, state.dependencies),
          do: await_worker(state),
          else: finish_manager_failure(state)
    end
  end

  defp reap_provisional(state, result, deadline) do
    %{worker: worker, worker_monitor: worker_monitor, manager: manager, reference: reference} =
      state

    remaining = max(deadline - state.dependencies.monotonic_ms.(), 0)

    if remaining == 0 do
      Process.exit(worker, :kill)

      if queued_down(worker, worker_monitor),
        do: finish_ordinary(state, result),
        else: hard_halt(state, 1)
    else
      receive do
        {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
          finish_ordinary(state, result)

        {^manager, ^reference, :interrupt} ->
          case interrupt_phase(state) do
            :stopping -> finish_interrupted(state, result)
            :idle -> reap_provisional(state, result, deadline)
            :unavailable -> finish_manager_failure(state)
          end

        {:DOWN, manager_monitor, :process, ^manager, _reason}
        when manager_monitor == state.manager_monitor ->
          finish_manager_failure(state)
      after
        min(remaining, @manager_poll_ms) ->
          if signal_manager?(manager, reference, state.dependencies),
            do: reap_provisional(state, result, deadline),
            else: finish_manager_failure(state)
      end
    end
  end

  defp finish_ordinary(state, first) do
    stop = stop(state)

    case finish_handler(state) do
      {:ok, :ordinary} -> render_selected(first, stop, state.mode)
      {:ok, :interrupted} -> render_interrupted(first, stop, state.mode)
      _ -> cleanup_diagnostic(stop, first, state.mode, :interrupt_handler_unavailable)
    end
  end

  defp finish_interrupted(state, first) do
    stop = stop(state)

    case reap_after_stop(state, first) do
      {:ok, result} ->
        case finish_handler(state) do
          {:ok, :interrupted} -> render_interrupted(result, stop, state.mode)
          _ -> cleanup_diagnostic(stop, result, state.mode, :interrupt_handler_unavailable)
        end

      :halted ->
        hard_halt(state, 130)
    end
  end

  defp finish_manager_failure(state) do
    first = queued_result(state.worker, state.reference)
    stop = stop(state)

    case reap_after_stop(state, first) do
      {:ok, result} ->
        cleanup_diagnostic(stop, result, state.mode, :interrupt_handler_unavailable)

      :halted ->
        hard_halt(state, 1)
    end
  end

  defp reap_after_stop(state, first) do
    result = if first == :none, do: queued_result(state.worker, state.reference), else: first

    if queued_down(state.worker, state.worker_monitor) do
      {:ok, result}
    else
      Process.exit(state.worker, :kill)
      deadline = state.dependencies.monotonic_ms.() + @reap_ms
      await_killed_worker(state, result, deadline)
    end
  end

  defp await_killed_worker(state, result, deadline) do
    remaining = max(deadline - state.dependencies.monotonic_ms.(), 0)

    receive do
      {:DOWN, monitor, :process, worker, _reason}
      when monitor == state.worker_monitor and worker == state.worker ->
        latest = if result == :none, do: queued_result(worker, state.reference), else: result
        {:ok, latest}
    after
      remaining -> :halted
    end
  end

  defp queued_result(worker, reference) do
    receive do
      {^worker, ^reference, result} -> result
    after
      0 -> :none
    end
  end

  defp queued_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> true
    after
      0 -> false
    end
  end

  defp stop(state), do: stop(state.session, state.dependencies)

  defp stop(session, dependencies) do
    case protected(fn -> dependencies.stop_session.(session) end) do
      {:ok, result} -> result
      _ -> {:error, :session_unavailable}
    end
  end

  defp finish_handler(state) do
    case protected(fn -> state.dependencies.finish_interrupt.(state.manager, state.reference) end) do
      {:ok, {:ok, decision}} when decision in [:ordinary, :interrupted] -> {:ok, decision}
      _ -> {:error, :interrupt_handler_unavailable}
    end
  end

  defp stop_diagnostic(session, mode, dependencies, manager, reference, code) do
    stopped = stop(session, dependencies)
    _ = protected(fn -> dependencies.finish_interrupt.(manager, reference) end)
    cleanup_diagnostic(stopped, :none, mode, code)
  end

  defp cleanup_diagnostic({:error, {:cleanup_unproved, map}}, _first, mode, _code),
    do: AskResult.render(:none, {:unproved, map}, mode)

  defp cleanup_diagnostic(
         {:error, :session_unavailable},
         {:error, {:cleanup_unproved, map}},
         mode,
         _code
       ),
       do: AskResult.render(:none, {:unproved, map}, mode)

  defp cleanup_diagnostic(_stop, _first, _mode, code), do: AskResult.diagnostic(code)

  defp render_selected(first, stop, mode) do
    case select(first, stop) do
      {:selected, ending, cleanup} -> AskResult.render(ending, cleanup, mode)
      :unavailable -> AskResult.diagnostic(:session_unavailable)
    end
  end

  defp render_interrupted(first, stop, mode) do
    case select(first, stop) do
      {:selected, :none, cleanup} ->
        only_root(cleanup, mode)

      {:selected, ending, cleanup} ->
        case AskResult.render(ending, cleanup, mode) do
          %{status: status} = rendered when status in 0..6 and status != 1 ->
            %{rendered | status: 130, stdout: if(mode == :text, do: "", else: rendered.stdout)}

          _ ->
            only_root(cleanup, mode)
        end

      :unavailable ->
        %{status: 130, stdout: "", stderr: ""}
    end
  end

  defp only_root({:unproved, _} = cleanup, mode) do
    rendered = AskResult.render(:none, cleanup, mode)
    %{rendered | status: 130, stdout: ""}
  end

  defp only_root(_, _mode), do: %{status: 130, stdout: "", stderr: ""}

  defp select(_first, {:error, {:cleanup_unproved, %{ending: ending} = map}}),
    do: {:selected, normalize(ending), {:unproved, map}}

  defp select({:error, {:cleanup_unproved, %{ending: ending}}}, :ok),
    do: {:selected, normalize(ending), :proved}

  defp select(
         {:error, {:cleanup_unproved, %{ending: ending} = map}},
         {:error, :session_unavailable}
       ),
       do: {:selected, normalize(ending), {:unproved, map}}

  defp select(_first, {:error, :session_unavailable}), do: :unavailable
  defp select(first, :ok), do: {:selected, normalize(first), :proved}
  defp select(_, _), do: :unavailable

  defp normalize({:error, reason}) when reason in [:session_closed, :session_unavailable],
    do: :none

  defp normalize(other), do: other

  defp signal_manager?(manager, reference, dependencies) do
    case protected(fn ->
           {dependencies.signal_manager.(), dependencies.handler_live.(manager, reference)}
         end) do
      {:ok, {^manager, true}} -> Process.alive?(manager)
      _ -> false
    end
  end

  defp interrupt_phase(state) do
    case protected(fn ->
           state.dependencies.interrupt_phase.(state.manager, state.reference)
         end) do
      {:ok, phase} when phase in [:idle, :stopping] -> phase
      _ -> :unavailable
    end
  end

  defp hard_halt(state, status) do
    state.dependencies.halt.(status)
    exit(:halt_returned)
  end

  defp startup_code({:session_create, :failed}), do: :session_create_failed
  defp startup_code({:client_start, :failed}), do: :session_tracking_failed
  defp startup_code({:attach, :failed}), do: :attachment_failed
  defp startup_code({:resource_admission, :failed}), do: :resource_admission_failed
  defp startup_code({:skill_activation, :failed}), do: :skill_activation_failed
  defp startup_code({:composition, :workspace_unusable}), do: :workspace_unusable

  defp startup_code({:composition, reason})
       when reason in [
              :skill_directory_unusable,
              :unclassified_skill_directory,
              :duplicate_skill,
              :skill_manifest_invalid
            ],
       do: :skill_directories_unavailable

  defp startup_code(:session_unavailable), do: :session_unavailable
  defp startup_code(_), do: :composition_unavailable

  defp protected(function) do
    try do
      {:ok, function.()}
    rescue
      _ -> :failed
    catch
      _, _ -> :failed
    end
  end
end
