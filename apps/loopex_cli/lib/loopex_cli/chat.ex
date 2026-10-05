defmodule LoopexCli.Chat do
  @moduledoc """
  ## Concept

  Run one foreground durable conversation from an explicit configuration file.
  The runtime owns conversation truth; this command owns placement, signals,
  diagnostic delivery and its input/output transport.

  ## Technical depth

  Validate file/flags, selected instructions and resource directories before
  credential acquisition. Composition owns the provider bindings and every
  concrete edge. A resumed owner stays paused while retained settings are
  checked, its report is submitted and the chat signal holder is installed.
  Recheck the physical workspace immediately before creation or activation.
  The driver returns only provisional local cleanup. Closing follows diagnostic
  joins, composition cleanup, placement release and the serialized signal finish.
  Internal seams replace individual host boundaries for credential-free tests.
  """

  alias LoopexCli.{
    ChatConfiguration,
    ChatControl,
    ChatDriver,
    ChatOutput,
    ConfigInspection,
    ConfigOptions,
    DiagnosticLifetime,
    Interrupt
  }

  alias LoopexComposition.{
    DiagnosticConsumer,
    Placement,
    ProjectResources,
    ProviderBindings,
    ResourcePacks,
    TraceConfiguration,
    WorkspaceIdentity
  }

  @doc false
  def run(argv, options \\ []) do
    deps = Map.merge(defaults(), Map.new(options))
    tag = make_ref()

    result = guarded(fn -> execute(argv, deps, tag) end)
    context = collect(tag, %{})
    finish(result, context, deps)
  end

  defp defaults do
    %{
      cwd: File.cwd!(),
      home: System.get_env("LOOPEX_HOME"),
      input: :stdio,
      output: :stdio,
      diagnostic_device: :stderr,
      mode: if(ProjectResources.operator_present?(), do: :interactive, else: :pipe),
      with_runtime: &LoopexComposition.with_runtime/2,
      read_directories: &ResourcePacks.read_directories/2,
      acquire_placement: &Placement.acquire/2,
      release_placement: &Placement.release/2,
      placement_id: &Loopex.runtime_placement_id/1,
      provider_launch: &LoopexCli.ProviderLaunch.options/0,
      prepare_resume: &Loopex.prepare_resume_known_session/4,
      install_signal: fn driver, ref, grace, activation ->
        if activation,
          do: Interrupt.install_chat(driver, ref, grace, activation),
          else: Interrupt.install_chat(driver, ref, grace)
      end,
      activate: &Interrupt.activate_prepared/1,
      finish_signal: &Interrupt.finish_chat/2,
      fixture_policy: nil
    }
  end

  defp execute(argv, deps, tag) do
    with {:ok, parsed} <- ConfigOptions.parse(argv),
         {:ok, invocation} <- load(parsed, argv, deps),
         {:ok, invocation} <- LoopexCli.Policy.M7Fixture.bind(invocation, deps.fixture_policy),
         {:ok, routes} <- ProviderBindings.validate(invocation.selection.profile["providers"]),
         {:ok, resources} <-
           deps.read_directories.(skills(invocation),
             workspace: workspace(invocation)
           ),
         {:ok, lock} <- deps.acquire_placement.(root(invocation), probe(routes)) do
      remember(tag, :placement_released, false)

      try do
        with {:ok, placement} <- deps.placement_id.(root(invocation)),
             {:ok, consumer} <-
               DiagnosticLifetime.start(deps.diagnostic_device, grace(invocation)) do
          remember(tag, :diagnostics, {consumer, Process.monitor(consumer), grace(invocation)})

          {:ok, driver} =
            ChatDriver.bootstrap(deps.input, deps.output,
              mode: deps.mode,
              cleanup_grace_ms: grace(invocation),
              progress_device: deps.diagnostic_device
            )

          Process.unlink(driver)
          remember(tag, :driver, {driver, Process.monitor(driver)})

          result =
            deps.with_runtime.(
              composition_options(invocation, resources, placement, consumer, driver, deps),
              fn runtime ->
                callback(runtime, invocation, consumer, driver, placement, deps, tag)
              end
            )

          remember(
            tag,
            :outer_cleanup,
            not match?({:error, {:composition_cleanup_unconfirmed, _}}, result)
          )

          result
        end
      after
        released = deps.release_placement.(lock, probe(routes))
        remember(tag, :placement_released, released == :ok)
      end
    end
  end

  defp load(%{resume: nil}, argv, deps),
    do: ChatConfiguration.load(argv, deps.cwd, deps.home)

  defp load(%{resume: _session}, argv, deps),
    do: ChatConfiguration.load_resume(argv, deps.cwd, deps.home)

  defp probe(routes),
    do: fn pid -> Placement.process_incarnation(pid, "/bin/ps", routes.excluded_env_names) end

  defp skills(invocation), do: Map.get(invocation.selection.profile["session"], "skill_dirs", [])
  defp workspace(invocation), do: invocation.selection.profile["paths"]["workspace"]
  defp root(invocation), do: invocation.selection.profile["paths"]["state_root"]
  defp grace(invocation), do: invocation.selection.profile["session"]["cleanup_grace_ms"]

  defp policy(%{harness_fixture: capture}),
    do: %{module: LoopexCli.Policy.M7Fixture, context: capture}

  defp policy(invocation),
    do: Map.fetch!(LoopexCli.AskOptions.policy_profiles(), invocation.selection.profile["policy"])

  defp policy_identity(%{harness_fixture: capture}),
    do: LoopexCli.Policy.M7Fixture.identity(capture)

  defp policy_identity(invocation),
    do: %{"id" => inspect(policy(invocation)), "revision" => "0.2.0"}

  defp status_policy(%{harness_fixture: capture}), do: LoopexCli.Policy.M7Fixture.report(capture)
  defp status_policy(_invocation), do: nil

  defp settings_rows(invocation) do
    rows = ConfigInspection.settings_rows(invocation.selection, %{})

    case status_policy(invocation) do
      nil ->
        rows

      policy ->
        Enum.map(rows, fn row ->
          if row["setting"] == "/policy_identity",
            do:
              Map.merge(row, %{
                "value" =>
                  Map.new(policy, fn {key, value} ->
                    {Atom.to_string(key),
                     if(key == :origin, do: Atom.to_string(value), else: value)}
                  end),
                "origin" => "harness"
              }),
            else: row
        end)
    end
  end

  defp composition_options(invocation, resources, placement, consumer, driver, deps) do
    profile = invocation.selection.profile
    configuration = Map.get(invocation.selection, :configuration, %{})

    [
      runtime_id: placement,
      state_root: root(invocation),
      workspace: workspace(invocation),
      policy: policy(invocation),
      policy_identity: policy_identity(invocation),
      provider_bindings: profile["providers"],
      provider_launch: deps.provider_launch.(),
      resource_manifest: resources.manifest,
      diagnostics_to: consumer,
      progress_to: {:session, driver},
      active_tools: Map.get(invocation, :active_tools, []),
      cleanup_grace_ms: grace(invocation),
      recover_stale_writer: true,
      model: Map.get(configuration, "model", profile["session"]["model"]),
      maintenance_model: get_in(profile, ["maintenance", "model"])
    ]
  end

  defp callback(runtime, invocation, consumer, driver, placement, deps, tag) do
    try do
      with {:ok, prepared, session, activation} <-
             session(runtime, invocation, placement, deps, tag) do
        remember(tag, :grace, grace(prepared))

        DiagnosticConsumer.settings_report(
          consumer,
          settings_rows(prepared)
        )

        with :ok <- trace(runtime, prepared),
             :ok <-
               ChatDriver.bind(driver, runtime, session,
                 configuration: prepared,
                 status_policy: status_policy(prepared),
                 cleanup_grace_ms: grace(prepared),
                 bounds: bounds(prepared)
               ) do
          case guarded(fn -> drive(driver, prepared, activation, deps, tag) end) do
            {:error, :chat_startup_failed} ->
              ChatDriver.interrupt(driver)
              guarded(fn -> ChatDriver.run(driver) end)
              {:error, :chat_startup_failed}

            result ->
              result
          end
        end
      end
    after
      # Concept: diagnostic delivery is sealed while its runtime still exists.
      # Technical depth: retain the exact close certificate/joins before
      # composition can replace a provisional callback result with cleanup loss.
      settle_activation(tag)
      report_progress(driver, consumer)
      remember(tag, :diagnostics_closed, close_diagnostics(consumer, tag))
    end
  end

  defp session(runtime, %{resume_session_id: session} = invocation, _placement, deps, tag) do
    with {:ok, {:prepared, activation}} <-
           deps.prepare_resume.(root(invocation), runtime, session, command_id()) do
      remember(tag, :activation, {:direct, activation})

      case ChatConfiguration.resume(invocation, activation) do
        {:ok, prepared} ->
          {:ok, prepared, session, activation}

        {:error, {:resume_configuration_owner_unconfirmed, _, _}} = refusal ->
          remember(tag, :activation, nil)
          remember(tag, :activation_cleanup, false)
          refusal

        refusal ->
          remember(tag, :activation, nil)
          refusal
      end
    end
  end

  defp session(runtime, prepared, placement, _deps, _tag) do
    with :ok <- recheck(prepared),
         {:ok, session} <-
           Loopex.create_session(runtime, prepared.session_options,
             command_id: command_id(),
             genesis: prepared.genesis
           ),
         :ok <- Loopex.track_session(root(prepared), session, placement) do
      {:ok, prepared, session, nil}
    end
  end

  defp trace(runtime, prepared) do
    with {:ok, selection} <-
           TraceConfiguration.validate(Map.get(prepared.selection.profile, "trace", %{})) do
      if selection.enabled do
        case Loopex.trace(runtime, selection.configuration) do
          {:ok, _} -> :ok
          _ -> {:error, :chat_trace_start_failed}
        end
      else
        :ok
      end
    end
  end

  defp drive(driver, prepared, activation, deps, tag) do
    case ChatDriver.prepare(driver) do
      {:ok, _status} ->
        ref = make_ref()

        case deps.install_signal.(driver, ref, grace(prepared), activation) do
          {:ok, manager} ->
            remember(tag, :signal, {manager, ref})
            if activation, do: remember(tag, :activation, {:transferred, activation})

            case activate(prepared, activation, deps) do
              :ok ->
                remember(tag, :activation, nil)
                ChatDriver.run(driver)

              _ ->
                ChatDriver.refuse_startup(driver, :chat_activation_failed)
            end

          {:unresolved, _} ->
            remember(tag, :activation, nil)
            remember(tag, :activation_cleanup, false)
            ChatDriver.refuse_startup(driver, :chat_signal_start_failed)

          _ ->
            # An uncertain transfer is never retried. Composition remains the
            # owner of cleanup; local transport stops without reading input.
            ChatDriver.refuse_startup(driver, :chat_signal_start_failed)
        end

      {:error, _} = refusal ->
        refusal
    end
  end

  defp activate(prepared, nil, _deps), do: recheck(prepared)

  defp activate(prepared, activation, deps) do
    with :ok <- recheck(prepared), {:ok, _session} <- deps.activate.(activation), do: :ok
  end

  defp recheck(prepared) do
    options = Map.get(prepared, :session_options) || prepared.startup.session_options
    expected = options["workspace_binding"]["workspace_ref"]

    case WorkspaceIdentity.reference(workspace(prepared)) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :chat_workspace_binding_conflict}
    end
  end

  defp bounds(prepared) do
    for {key, value} <- prepared.selection.profile["session"]["bounds"],
        into: %{},
        do:
          {Map.fetch!(
             %{
               "max_turns" => :max_turns,
               "deadline_ms" => :deadline_ms,
               "token_budget" => :token_budget
             },
             key
           ), value}
  end

  defp settle_activation(tag) do
    context = collect(tag, %{})

    result =
      case Map.get(context, :activation) do
        {:direct, activation} -> guarded(fn -> Loopex.abandon_resume(activation) end)
        {:transferred, activation} -> guarded(fn -> Interrupt.abandon_prepared(activation) end)
        _ -> :ok
      end

    Enum.each(context, fn {key, value} -> remember(tag, key, value) end)
    remember(tag, :activation, nil)
    if result != :ok, do: remember(tag, :activation_cleanup, false)
  end

  defp close_diagnostics(consumer, tag) do
    context = collect(tag, %{})
    Enum.each(context, fn {key, value} -> remember(tag, key, value) end)
    {_consumer, monitor, initial_grace} = context.diagnostics
    selected_grace = Map.get(context, :grace, initial_grace)
    closing = DiagnosticLifetime.begin_close(consumer, selected_grace, %{consumer => monitor})
    DiagnosticLifetime.join(consumer, closing)
  end

  defp finish(result, context, deps) do
    if not (is_map(result) and Map.has_key?(result, :exit_code)) do
      case context do
        %{driver: {driver, _}} ->
          guarded(fn -> ChatDriver.refuse_startup(driver, startup_code(result)) end)

        _ ->
          :ok
      end
    end

    case context do
      %{driver: {driver, _}, diagnostics: {consumer, _, _}} -> report_progress(driver, consumer)
      _ -> :ok
    end

    diagnostics =
      case context do
        %{diagnostics_closed: closed} ->
          closed

        %{diagnostics: {consumer, monitor, grace}} ->
          closing = DiagnosticLifetime.begin_close(consumer, grace, %{consumer => monitor})
          DiagnosticLifetime.join(consumer, closing)

        _ ->
          true
      end

    signal =
      case context do
        %{signal: {manager, ref}} -> guarded(fn -> deps.finish_signal.(manager, ref) end)
        _ -> {:ok, :ordinary}
      end

    successful = is_map(result) and Map.has_key?(result, :exit_code)
    outer = Map.get(context, :outer_cleanup, not Map.has_key?(context, :diagnostics))

    cleanup =
      if outer and diagnostics and Map.get(context, :placement_released, true) and
           Map.get(context, :activation_cleanup, true) and match?({:ok, _}, signal),
         do: :confirmed,
         else: :unknown

    minimum = if successful and signal == {:ok, :ordinary}, do: 0, else: 1

    case context do
      %{driver: {driver, monitor}} ->
        code = guarded(fn -> ChatDriver.close(driver, cleanup, minimum) end)

        joined =
          receive do
            {:DOWN, ^monitor, :process, ^driver, :normal} -> true
            {:DOWN, ^monitor, :process, ^driver, _} -> false
          after
            Map.get(context, :grace, 5_000) -> false
          end

        Process.demonitor(monitor, [:flush])
        if is_integer(code) and joined, do: code, else: 1

      _ ->
        startup_failure(deps.output, result, cleanup)
    end
  end

  defp startup_failure(output, result, cleanup) do
    code = startup_code(result)

    guarded(fn ->
      with {:ok, writer} <- ChatOutput.start_link(output),
           {:ok, error} <- ChatControl.encode(:error, %{input_sequence: nil, code: code}),
           :ok <- ChatOutput.write(writer, :control, error),
           {:ok, closing} <-
             ChatControl.encode(:closing, %{exit_code: 1, cleanup: cleanup, last_outcome: nil}),
           :ok <- ChatOutput.write(writer, :control, closing),
           :ok <- ChatOutput.finish(writer),
           do: :ok
    end)

    1
  end

  defp startup_code(result) do
    case result do
      {:error, reason} when is_atom(reason) -> reason
      {:error, {reason, pointer}} when is_atom(reason) and is_binary(pointer) -> reason
      _ -> :chat_startup_failed
    end
  end

  defp report_progress(driver, consumer) do
    guarded(fn ->
      case ChatDriver.seal_progress(driver) do
        {count, true} when is_integer(count) ->
          send(consumer, {:loopex_diagnostic, %{kind: "chat_progress_dropped", dropped: count}})

        _ ->
          :ok
      end
    end)
  end

  defp command_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  defp remember(tag, key, value), do: send(self(), {tag, key, value})

  defp collect(tag, context) do
    receive do
      {^tag, key, value} -> collect(tag, Map.put(context, key, value))
    after
      0 -> context
    end
  end

  defp guarded(function) do
    function.()
  rescue
    _ -> {:error, :chat_startup_failed}
  catch
    _, _ -> {:error, :chat_startup_failed}
  end
end
