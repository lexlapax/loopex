defmodule Loopex.LLM.ReqLLM.CredentialPlaneTest do
  @moduledoc """
  ## Concept

  What the shipped adapter is allowed to let escape while it is holding the
  host's credential.

  ## Technical depth

  ADR 0018 requires credential-shaped raw errors to be absent from every
  prohibited plane, and the logger's crash report is one of them: an uncaught
  error inside the provider worker is reported by the VM with a stacktrace whose
  frames can carry the argument list the call was made with, and that argument
  list is `call_options`, which carries `api_key`. These cases hold the adapter
  to the two halves of that: nothing the worker does while the credential is
  live may terminate it uncaught, and every reason the drain does return is
  bounded and has that credential substituted out of it.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.CredentialFilter
  alias Loopex.Model

  @sentinel "sk-loopex-credential-plane-sentinel-2f9c41"
  @credential_registry Loopex.LLM.ReqLLM.CredentialFilter.Registry
  @credential_supervisor Loopex.LLM.ReqLLM.Application.Supervisor
  @provider_io_sink Loopex.LLM.ReqLLM.ProviderIOSink
  @filter_id :loopex_req_llm_credential_filter
  @filter_configuration :loopex_req_llm_v3
  @activity_key {CredentialFilter, :logger_activity}
  @provider_io_key {CredentialFilter, :provider_io_originals}
  @capsule_tag :loopex_req_llm_credential_capsule_v1

  setup do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(variable)
        value -> System.put_env(variable, value)
      end
    end)

    %{variable: variable}
  end

  describe "a stream that ends by throwing or exiting" do
    test "a progress function that throws ends the drain as a bounded interruption" do
      response = stream_response()

      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(response, request(), identity(), throwing_progress())

      assert is_binary(reason)
      assert byte_size(reason) <= 4_096
    end

    test "a progress function that exits ends the drain as a bounded interruption" do
      response = stream_response()

      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(response, request(), identity(), exiting_progress())

      assert is_binary(reason)
      assert byte_size(reason) <= 4_096
    end
  end

  describe "the credential in a returned reason" do
    test "a provider error echoing the key is substituted before it is returned",
         %{variable: variable} do
      System.put_env(variable, @sentinel)

      response = stream_response(echoing_stream())

      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(
                 response,
                 request(),
                 identity(),
                 Model.discard_progress()
               )

      refute reason =~ @sentinel
      assert reason =~ "[redacted credential]"
    end
  end

  describe "the provider worker while the credential is live" do
    test "the credential registry is supervised and an inactive restart recovers" do
      assert :ok = CredentialFilter.ensure_installed()
      registry = Process.whereis(@credential_registry)
      supervisor = Process.whereis(@credential_supervisor)
      sink = Process.whereis(@provider_io_sink)
      assert is_pid(registry)
      assert is_pid(supervisor)
      assert is_pid(sink)
      assert {:links, links} = Process.info(registry, :links)
      assert supervisor in links

      monitor = Process.monitor(registry)
      Process.exit(registry, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^registry, :killed}, 1_000

      restarted = await_registry_restart(registry)
      restarted_sink = Process.whereis(@provider_io_sink)
      refute restarted_sink == sink
      assert :ok = CredentialFilter.ensure_installed()
      assert :ok = CredentialFilter.isolate_provider_io()

      assert {:group_leader, ^restarted_sink} =
               ReqLLM.Supervisor |> Process.whereis() |> Process.info(:group_leader)

      assert {:group_leader, ^restarted_sink} =
               ReqLLM.TaskSupervisor |> Process.whereis() |> Process.info(:group_leader)

      assert is_pid(restarted)
    end

    test "an inactive credential filter never waits on the registry" do
      assert :ok = CredentialFilter.ensure_installed()

      assert :ignore =
               CredentialFilter.filter(
                 %{level: :info, msg: {:string, "safe"}, meta: %{}},
                 :loopex_req_llm_v3
               )

      registry = Process.whereis(@credential_registry)
      :ok = :sys.suspend(registry)

      task =
        Task.async(fn ->
          CredentialFilter.filter(
            %{level: :info, msg: {:string, "safe"}, meta: %{}},
            :loopex_req_llm_v3
          )
        end)

      try do
        assert {:ok, :ignore} = Task.yield(task, 500)
      after
        :ok = :sys.resume(registry)
        _ = Task.shutdown(task, :brutal_kill)
      end
    end

    test "the credential registry protocol never returns active credentials" do
      {:ok, lease} = CredentialFilter.acquire(@sentinel)

      try do
        registry = Process.whereis(@credential_registry)
        state = :sys.get_state(registry)
        refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ @sentinel
        assert_raise ArgumentError, fn -> :ets.tab2list(state.credentials) end
        assert {:error, :unsupported} = GenServer.call(registry, :active_credentials)

        reference = make_ref()

        send(
          registry,
          {:loopex_req_llm_credential_registry, self(), reference, :active_credentials}
        )

        refute_receive {:loopex_req_llm_credential_registry, ^registry, ^reference, _response},
                       100
      after
        assert :ok = CredentialFilter.release(lease)
      end
    end

    test "credential generations reject stale events and retain overlapping leases" do
      first = @sentinel <> "-first"
      second = @sentinel <> "-second"
      {:ok, first_lease} = CredentialFilter.acquire(first)

      {:active, registry, first_epoch} =
        :persistent_term.get({CredentialFilter, :logger_activity})

      {:ok, second_lease} = CredentialFilter.acquire(second)

      try do
        assert :ok = CredentialFilter.release(first_lease)

        event = %{
          level: :error,
          msg: {:string, "first=#{first} second=#{second}"},
          meta: %{}
        }

        filtered = CredentialFilter.filter(event, :loopex_req_llm_v3)
        rendered = inspect(filtered, limit: :infinity, printable_limit: :infinity)

        assert rendered =~ first
        refute rendered =~ second
        assert rendered =~ "[redacted credential]"
        assert :stop = GenServer.call(registry, {:sanitize, first_epoch, event})
      after
        CredentialFilter.release(first_lease)
        CredentialFilter.release(second_lease)
      end

      assert :ignore =
               CredentialFilter.filter(
                 %{level: :info, msg: {:string, second}, meta: %{}},
                 :loopex_req_llm_v3
               )
    end

    test "metadata redaction replaces every occurrence in one binary" do
      {:ok, lease} = CredentialFilter.acquire(@sentinel)

      try do
        filtered =
          CredentialFilter.filter(
            %{
              level: :error,
              msg: {:string, "safe"},
              meta: %{safe_diagnostic: "#{@sentinel}|#{@sentinel}"}
            },
            @filter_configuration
          )

        assert get_in(filtered, [:meta, :safe_diagnostic]) ==
                 "[redacted credential]|[redacted credential]"

        refute inspect(filtered, limit: :infinity, printable_limit: :infinity) =~ @sentinel
      after
        CredentialFilter.release(lease)
      end
    end

    test "nested metadata map keys are redacted" do
      {:ok, lease} = CredentialFilter.acquire(@sentinel)

      try do
        filtered =
          CredentialFilter.filter(
            %{
              level: :error,
              msg: {:string, "safe"},
              meta: %{safe_diagnostic: %{@sentinel => :present}}
            },
            @filter_configuration
          )

        assert get_in(filtered, [:meta, :safe_diagnostic]) == %{
                 "[redacted credential]" => :present
               }

        refute inspect(filtered, limit: :infinity, printable_limit: :infinity) =~ @sentinel
      after
        CredentialFilter.release(lease)
      end
    end

    test "one event redacts every distinct overlapping live credential" do
      first = "sk-loopex-overlap-first-2f9c41"
      second = "sk-loopex-overlap-second-8ab730"
      {:ok, first_lease} = CredentialFilter.acquire(first)
      {:ok, second_lease} = CredentialFilter.acquire(second)

      try do
        filtered =
          CredentialFilter.filter(
            %{
              level: :error,
              msg: {:string, "safe"},
              meta: %{safe_diagnostic: "first=#{first} second=#{second}"}
            },
            @filter_configuration
          )

        rendered = inspect(filtered, limit: :infinity, printable_limit: :infinity)
        refute rendered =~ first
        refute rendered =~ second
        assert length(:binary.matches(rendered, "[redacted credential]")) == 2
      after
        CredentialFilter.release(first_lease)
        CredentialFilter.release(second_lease)
      end
    end

    test "owner loss retains its credential until the lease is explicitly released" do
      observer = self()

      {owner, owner_monitor} =
        spawn_monitor(fn ->
          {:ok, lease} = CredentialFilter.acquire(@sentinel)
          send(observer, {:credential_owner_ready, self(), lease})

          receive do
            :credential_owner_stop -> :ok
          end
        end)

      assert_receive {:credential_owner_ready, ^owner, lease}, 1_000

      try do
        registry = Process.whereis(@credential_registry)
        {_owner, registry_monitor} = :sys.get_state(registry).leases[lease]

        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000

        await_registry_state(fn state ->
          not Map.has_key?(state.monitors, registry_monitor)
        end)

        assert {:active, ^registry, _epoch} = :persistent_term.get(@activity_key)

        filtered =
          CredentialFilter.filter(
            %{
              level: :error,
              msg: {:string, "safe"},
              meta: %{safe_diagnostic: @sentinel}
            },
            @filter_configuration
          )

        refute filtered in [:ignore, :stop]
        refute inspect(filtered, limit: :infinity, printable_limit: :infinity) =~ @sentinel

        assert :ok = CredentialFilter.release(lease)
        state = await_clean_registry(registry)
        assert {:idle, state.epoch} == :persistent_term.get(@activity_key)
      after
        Process.exit(owner, :kill)
        Process.demonitor(owner_monitor, [:flush])
        CredentialFilter.release(lease)
        reset_credential_plane_if_live()
      end
    end

    test "missing activity state stops a logger event" do
      {:ok, lease} = CredentialFilter.acquire(@sentinel)
      activity = :persistent_term.get(@activity_key)

      try do
        :persistent_term.erase(@activity_key)

        assert :stop =
                 CredentialFilter.filter(
                   %{
                     level: :error,
                     msg: {:string, "safe"},
                     meta: %{safe_diagnostic: @sentinel}
                   },
                   @filter_configuration
                 )
      after
        :persistent_term.put(@activity_key, activity)
        CredentialFilter.release(lease)
      end
    end

    test "registry loss with an active lease poisons logging and provider admission" do
      {:ok, _lease} = CredentialFilter.acquire(@sentinel)
      {:active, registry, epoch} = :persistent_term.get(@activity_key)
      monitor = Process.monitor(registry)

      try do
        Process.exit(registry, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^registry, :killed}, 1_000
        restarted = await_registry_restart(registry)

        assert {:poisoned, poisoned_epoch} = :persistent_term.get(@activity_key)
        assert poisoned_epoch > epoch

        assert :stop =
                 CredentialFilter.filter(
                   %{
                     level: :error,
                     msg: {:string, "safe"},
                     meta: %{safe_diagnostic: @sentinel}
                   },
                   @filter_configuration
                 )

        assert {:error, :credential_filter_unavailable} = CredentialFilter.ensure_installed()
        assert is_pid(restarted)
      after
        recover_poisoned_registry()
      end
    end

    test "post-transfer filter conflict refuses credential acquisition" do
      registry = Process.whereis(@credential_registry)
      observer = self()
      barrier = make_ref()
      debug_id = {:credential_transfer_barrier, barrier}

      {@filter_id, expected_filter} =
        List.keyfind(:logger.get_primary_config().filters, @filter_id, 0)

      debug = fn state, event, _name ->
        case event do
          {:in, {:"ETS-TRANSFER", _capsule, _owner, {@capsule_tag, _request, _lease}}} ->
            send(observer, {:credential_transfer_blocked, barrier})

            receive do
              {:release_credential_transfer, ^barrier} -> state
            end

          _other ->
            state
        end
      end

      :ok = :sys.install(registry, {debug_id, debug, :ready})
      {acquirer, acquirer_monitor} = start_credential_acquirer(@sentinel)

      try do
        assert_receive {:credential_transfer_blocked, ^barrier}, 1_000
        :ok = remove_primary_filter(@filter_id)

        :ok =
          :logger.add_primary_filter(
            @filter_id,
            {fn event, _configuration -> event end, :conflicting_configuration}
          )

        send(registry, {:release_credential_transfer, barrier})

        case await_credential_acquisition(acquirer) do
          {:error, :credential_filter_unavailable} ->
            :ok

          {:ok, leaked_lease} ->
            CredentialFilter.release(leaked_lease)
            flunk("post-transfer verification authorized provider transport")
        end

        state = await_clean_registry(registry)
        assert {:idle, state.epoch} == :persistent_term.get(@activity_key)

        send(acquirer, :credential_acquirer_stop)
        assert_receive {:DOWN, ^acquirer_monitor, :process, ^acquirer, :normal}, 1_000
      after
        send(registry, {:release_credential_transfer, barrier})
        Process.exit(acquirer, :kill)
        Process.demonitor(acquirer_monitor, [:flush])
        _ = :sys.remove(registry, debug_id)
        :ok = remove_primary_filter(@filter_id)
        :ok = :logger.add_primary_filter(@filter_id, expected_filter)
        reset_credential_plane_if_live()
      end
    end

    test "a transfer timeout is cancelled when the delayed capsule reaches the registry" do
      registry = Process.whereis(@credential_registry)
      observer = self()
      barrier = make_ref()
      debug_id = {:delayed_credential_transfer, barrier}

      debug = fn state, event, _name ->
        case event do
          {:in, {:"ETS-TRANSFER", _capsule, _owner, {@capsule_tag, _request, _lease}}} ->
            send(observer, {:credential_transfer_delayed, barrier})

            receive do
              {:release_delayed_credential_transfer, ^barrier} -> state
            end

          _other ->
            state
        end
      end

      :ok = :sys.install(registry, {debug_id, debug, :ready})
      {acquirer, acquirer_monitor} = start_credential_acquirer(@sentinel)

      try do
        assert_receive {:credential_transfer_delayed, ^barrier}, 1_000

        assert {:error, :credential_filter_unavailable} =
                 await_credential_acquisition(acquirer)

        # The timeout refused acquisition but did not claim cleanup. Releasing
        # the registry lets the keyed cancellation settle the delayed transfer.
        send(registry, {:release_delayed_credential_transfer, barrier})
        state = await_clean_registry(registry)
        assert {:idle, state.epoch} == :persistent_term.get(@activity_key)

        send(acquirer, :credential_acquirer_stop)
        assert_receive {:DOWN, ^acquirer_monitor, :process, ^acquirer, :normal}, 1_000
      after
        send(registry, {:release_delayed_credential_transfer, barrier})
        Process.exit(acquirer, :kill)
        Process.demonitor(acquirer_monitor, [:flush])
        _ = :sys.remove(registry, debug_id)
        reset_credential_plane_if_live()
      end
    end

    test "provider IO isolation restores only after the last credential is released" do
      {:ok, lease} = CredentialFilter.acquire(@sentinel)

      try do
        sink = Process.whereis(@provider_io_sink)
        fallback = Process.group_leader()
        supervisor = Process.whereis(ReqLLM.Supervisor)
        task_supervisor = Process.whereis(ReqLLM.TaskSupervisor)
        originals = :persistent_term.get(@provider_io_key)
        {^supervisor, supervisor_original} = List.keyfind(originals, supervisor, 0)
        {^task_supervisor, task_supervisor_original} = List.keyfind(originals, task_supervisor, 0)

        assert {:error, :credential_filter_unavailable} =
                 CredentialFilter.restore_provider_io(fallback)

        assert {:group_leader, ^sink} =
                 ReqLLM.Supervisor |> Process.whereis() |> Process.info(:group_leader)

        assert {:group_leader, ^sink} =
                 ReqLLM.TaskSupervisor |> Process.whereis() |> Process.info(:group_leader)

        assert :ok = CredentialFilter.release(lease)
        state = await_clean_registry(Process.whereis(@credential_registry))
        assert {:idle, state.epoch} == :persistent_term.get(@activity_key)

        assert :ok = CredentialFilter.restore_provider_io(fallback)

        expected_supervisor =
          if Process.alive?(supervisor_original), do: supervisor_original, else: fallback

        expected_task_supervisor =
          if Process.alive?(task_supervisor_original),
            do: task_supervisor_original,
            else: fallback

        assert Process.info(supervisor, :group_leader) ==
                 {:group_leader, expected_supervisor}

        assert Process.info(task_supervisor, :group_leader) ==
                 {:group_leader, expected_task_supervisor}
      after
        CredentialFilter.release(lease)
        rebind_provider_io_for_test()
      end
    end

    test "a transport raise after environment rotation is redacted by the real logger pipeline",
         %{variable: variable} do
      previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
      System.put_env(variable, @sentinel)

      Application.put_env(
        :req_llm,
        :finch_request_adapter,
        Loopex.LLM.ReqLLM.CredentialPlaneTest.RaisingTransport
      )

      on_exit(fn ->
        case previous_adapter do
          nil -> Application.delete_env(:req_llm, :finch_request_adapter)
          value -> Application.put_env(:req_llm, :finch_request_adapter, value)
        end
      end)

      {:ok, live} =
        Model.request(
          Adapter.default_model(),
          [%{"role" => "user", "content" => "credential plane"}],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 2_000
        )

      log =
        capture_log(fn ->
          assert Adapter.complete(live, [], Model.discard_progress()) ==
                   {:error, {:dispatched_or_unknown, "model_call_failed"}}

          Process.sleep(200)
        end)

      refute log =~ @sentinel
      assert log =~ "[redacted credential]"
      assert log =~ "req_llm_transport_raised_after_handoff"
    end

    test "ordinary and split logger messages redact every active credential" do
      {:ok, lease} = CredentialFilter.acquire(@sentinel)
      on_exit(fn -> CredentialFilter.release(lease) end)

      split_at = div(byte_size(@sentinel), 2)
      <<left::binary-size(^split_at), right::binary>> = @sentinel

      log =
        capture_log(fn ->
          Logger.error(
            "req_llm ordinary diagnostic credential=#{@sentinel} repeated=#{@sentinel}"
          )

          Logger.error(fn ->
            ["req_llm split diagnostic credential=", left, right, " repeated=", @sentinel]
          end)
        end)

      refute log =~ @sentinel
      assert length(:binary.matches(log, "[redacted credential]")) == 4

      assert log =~
               "req_llm ordinary diagnostic credential=[redacted credential] repeated=[redacted credential]"

      assert log =~
               "req_llm split diagnostic credential=[redacted credential] repeated=[redacted credential]"
    end

    test "all Logger message forms and metadata use the active credential registry" do
      {:ok, lease} = CredentialFilter.acquire(@sentinel)
      on_exit(fn -> CredentialFilter.release(lease) end)

      split_at = div(byte_size(@sentinel), 2)
      <<left::binary-size(^split_at), right::binary>> = @sentinel

      events = [
        %{
          level: :error,
          msg: {:string, ["safe-string ", left, right, " repeated ", @sentinel]},
          meta: %{}
        },
        %{
          level: :error,
          msg: {~c"safe-format ~s~s", [left, right]},
          meta: %{safe_diagnostic: @sentinel}
        },
        %{
          level: :error,
          msg: {:report, %{reason: {:safe_report, @sentinel}}},
          meta: %{}
        }
      ]

      for event <- events do
        filtered = CredentialFilter.filter(event, :loopex_req_llm_v3)
        rendered = inspect(filtered, limit: :infinity, printable_limit: :infinity)

        refute filtered == :stop
        refute rendered =~ @sentinel
        assert rendered =~ "[redacted credential]"
        assert rendered =~ "safe"
      end

      assert :ok = CredentialFilter.release(lease)

      assert :ignore =
               CredentialFilter.filter(
                 %{level: :error, msg: {:string, @sentinel}, meta: %{}},
                 :loopex_req_llm_v3
               )
    end

    for ending <- [:throw, :exit] do
      @ending ending

      test "a provider request adapter that #{@ending}s cannot put the credential in a stream-server crash report",
           %{variable: variable} do
        previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
        previous_ending = Application.get_env(:loopex_llm_reqllm, :credential_plane_ending)
        System.put_env(variable, @sentinel)

        Application.put_env(
          :req_llm,
          :finch_request_adapter,
          Loopex.LLM.ReqLLM.CredentialPlaneTest.EndingTransport
        )

        Application.put_env(:loopex_llm_reqllm, :credential_plane_ending, @ending)

        on_exit(fn ->
          restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

          restore_application_env(
            :loopex_llm_reqllm,
            :credential_plane_ending,
            previous_ending
          )
        end)

        {:ok, live} =
          Model.request(
            Adapter.default_model(),
            [%{"role" => "user", "content" => "credential crash report"}],
            sampling: %{"max_tokens" => 1},
            deadline: System.system_time(:millisecond) + 2_000
          )

        log =
          capture_log(fn ->
            assert Adapter.complete(live, [], Model.discard_progress()) ==
                     {:error, {:dispatched_or_unknown, "model_call_failed"}}

            Process.sleep(200)
          end)

        refute log =~ @sentinel

        if log != "" do
          assert log =~ "[redacted credential]"
          assert log =~ "provider_library_#{@ending}_after_handoff"
        end
      end
    end

    test "the crash-report filter retains diagnostics and redacts the event's own credential" do
      {:ok, lease} = CredentialFilter.acquire(@sentinel)
      on_exit(fn -> CredentialFilter.release(lease) end)

      event = %{
        level: :error,
        msg:
          {:report,
           %{
             label: {:gen_server, :terminate},
             last_message:
               {:start_http, ReqLLM.Providers.Anthropic, :model, :context, [api_key: @sentinel],
                ReqLLM.Finch},
             reason: {:provider_library_throw_after_handoff, @sentinel}
           }},
        meta: %{}
      }

      filtered = CredentialFilter.filter(event, :loopex_req_llm_v3)
      rendered = inspect(filtered, limit: :infinity, printable_limit: :infinity)

      assert filtered != :stop,
             "the filter stopped rather than redacted this event: " <>
               String.replace(
                 inspect(event, limit: :infinity, printable_limit: :infinity),
                 @sentinel,
                 "[sentinel]"
               )

      refute rendered =~ @sentinel
      assert rendered =~ "[redacted credential]"
      assert rendered =~ "provider_library_throw_after_handoff"
    end

    test "the filter redacts an actual stream-server termination event", %{
      variable: variable
    } do
      filter_id = :loopex_req_llm_credential_filter
      probe_id = :loopex_req_llm_credential_event_probe
      previous_filter = List.keyfind(:logger.get_primary_config().filters, filter_id, 0)
      previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
      previous_ending = Application.get_env(:loopex_llm_reqllm, :credential_plane_ending)
      System.put_env(variable, @sentinel)
      {:ok, lease} = CredentialFilter.acquire(@sentinel)

      :ok = remove_primary_filter(filter_id)

      :ok =
        :logger.add_primary_filter(
          probe_id,
          {&__MODULE__.capture_credential_event/2, {self(), @sentinel}}
        )

      Application.put_env(
        :req_llm,
        :finch_request_adapter,
        Loopex.LLM.ReqLLM.CredentialPlaneTest.EndingTransport
      )

      Application.put_env(:loopex_llm_reqllm, :credential_plane_ending, :throw)

      on_exit(fn ->
        CredentialFilter.release(lease)
        :ok = remove_primary_filter(probe_id)
        :ok = remove_primary_filter(filter_id)

        if previous_filter do
          {^filter_id, filter} = previous_filter
          :ok = :logger.add_primary_filter(filter_id, filter)
        end

        restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

        restore_application_env(
          :loopex_llm_reqllm,
          :credential_plane_ending,
          previous_ending
        )
      end)

      {_caller, monitor} =
        spawn_monitor(fn ->
          ReqLLM.stream_text(
            Adapter.default_model(),
            "actual credential-bearing stream-server crash",
            api_key: @sentinel,
            max_tokens: 1
          )
        end)

      assert_receive {:DOWN, ^monitor, :process, _caller, _reason}, 5_000
      assert_receive {:credential_bearing_logger_event, event}, 5_000

      filtered = CredentialFilter.filter(event, :loopex_req_llm_v3)
      rendered = inspect(filtered, limit: :infinity, printable_limit: :infinity)

      refute filtered == :stop,
             "the filter stopped rather than redacted this event: " <>
               String.replace(
                 inspect(event, limit: :infinity, printable_limit: :infinity),
                 @sentinel,
                 "[sentinel]"
               )

      refute rendered =~ @sentinel
      assert rendered =~ "[redacted credential]"
      assert rendered =~ "provider_library_throw_after_handoff"
    end

    test "a conflicting credential filter refuses before provider transport", %{
      variable: variable
    } do
      filter_id = :loopex_req_llm_credential_filter
      previous = List.keyfind(:logger.get_primary_config().filters, filter_id, 0)
      previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)

      :ok = remove_primary_filter(filter_id)
      :ok = :logger.add_primary_filter(filter_id, {fn event, _ -> event end, :conflict})
      System.put_env(variable, @sentinel)
      Application.put_env(:req_llm, :finch_request_adapter, RaisingTransport)

      on_exit(fn ->
        :ok = remove_primary_filter(filter_id)

        if previous do
          {^filter_id, filter} = previous
          :ok = :logger.add_primary_filter(filter_id, filter)
        end

        restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)
      end)

      assert Adapter.complete(request(), [], Model.discard_progress()) ==
               {:error, {:not_dispatched, "model_call_failed"}}
    end
  end

  defmodule RaisingTransport do
    @moduledoc false

    @behaviour ReqLLM.FinchRequestAdapter

    @impl ReqLLM.FinchRequestAdapter
    def call(%Finch.Request{headers: headers}) do
      credential =
        Enum.find_value(headers, fn
          {"x-api-key", value} -> value
          _other -> nil
        end)

      System.put_env(
        Loopex.LLM.ReqLLM.credential_variable(),
        "rotated-after-request-construction"
      )

      raise("req_llm_transport_raised_after_handoff credential=#{credential}")
    end
  end

  @doc false
  def capture_credential_event(event, {observer, sentinel}) do
    if event
       |> inspect(limit: :infinity, printable_limit: :infinity)
       |> String.contains?(sentinel) do
      send(observer, {:credential_bearing_logger_event, event})
      :stop
    else
      :ignore
    end
  end

  defmodule EndingTransport do
    @moduledoc false

    @behaviour ReqLLM.FinchRequestAdapter

    @impl ReqLLM.FinchRequestAdapter
    def call(%Finch.Request{}) do
      variable = Loopex.LLM.ReqLLM.credential_variable()
      credential = System.fetch_env!(variable)
      System.put_env(variable, "rotated-after-request-construction")

      case Application.fetch_env!(:loopex_llm_reqllm, :credential_plane_ending) do
        :throw -> throw({:provider_library_throw_after_handoff, credential})
        :exit -> exit({:provider_library_exit_after_handoff, credential})
      end
    end
  end

  defp throwing_progress, do: fn _delta -> throw(:progress_refused) end
  defp exiting_progress, do: fn _delta -> exit(:progress_gone) end

  defp request do
    {:ok, request} =
      Model.request(Adapter.default_model(), [%{"role" => "user", "content" => "hi"}],
        sampling: %{"max_tokens" => 8},
        deadline: System.system_time(:millisecond) + 60_000
      )

    request
  end

  defp identity do
    {:ok, identity} = Adapter.identity(Adapter.default_model())
    identity
  end

  defp restore_application_env(application, key, nil),
    do: Application.delete_env(application, key)

  defp restore_application_env(application, key, value),
    do: Application.put_env(application, key, value)

  defp remove_primary_filter(filter_id) do
    case :logger.remove_primary_filter(filter_id) do
      :ok -> :ok
      {:error, {:not_found, ^filter_id}} -> :ok
    end
  end

  defp start_credential_acquirer(credential) do
    observer = self()

    spawn_monitor(fn ->
      result = CredentialFilter.acquire(credential)
      send(observer, {:credential_acquisition_result, self(), result})

      receive do
        :credential_acquirer_stop -> :ok
      end
    end)
  end

  defp await_credential_acquisition(acquirer) do
    assert_receive {:credential_acquisition_result, ^acquirer, result}, 2_000
    result
  end

  defp await_registry_restart(previous, attempts \\ 100)

  defp await_registry_restart(_previous, 0), do: flunk("credential registry did not restart")

  defp await_registry_restart(previous, attempts) do
    case Process.whereis(@credential_registry) do
      registry when is_pid(registry) and registry != previous ->
        registry

      _not_restarted ->
        Process.sleep(10)
        await_registry_restart(previous, attempts - 1)
    end
  end

  defp await_registry_state(predicate, attempts \\ 100)

  defp await_registry_state(_predicate, 0),
    do: flunk("credential registry did not reach the expected state")

  defp await_registry_state(predicate, attempts) do
    state = @credential_registry |> Process.whereis() |> :sys.get_state()

    if predicate.(state) do
      state
    else
      Process.sleep(10)
      await_registry_state(predicate, attempts - 1)
    end
  end

  defp await_clean_registry(registry) do
    await_registry_state(fn state ->
      state.leases == %{} and
        state.monitors == %{} and
        state.transfers == %{} and
        MapSet.size(state.cancelled_transfers) == 0 and
        :ets.info(state.credentials, :size) == 0 and
        match?({:idle, _epoch}, :persistent_term.get(@activity_key, :missing))
    end)
    |> tap(fn state ->
      assert Process.whereis(@credential_registry) == registry
      assert state.leases == %{}
      assert state.monitors == %{}
      assert state.transfers == %{}
      assert MapSet.size(state.cancelled_transfers) == 0
      assert :ets.info(state.credentials, :size) == 0
    end)
  end

  defp reset_credential_plane_if_live do
    registry = Process.whereis(@credential_registry)

    case :sys.get_state(registry) do
      %{
        credentials: credentials,
        leases: leases,
        monitors: monitors,
        transfers: transfers,
        cancelled_transfers: cancelled_transfers
      }
      when map_size(leases) == 0 and map_size(monitors) == 0 and map_size(transfers) == 0 ->
        if :ets.info(credentials, :size) == 0 and MapSet.size(cancelled_transfers) == 0 and
             match?({:idle, _epoch}, :persistent_term.get(@activity_key, :missing)) do
          :ok
        else
          recover_poisoned_registry()
        end

      _active_or_malformed ->
        recover_poisoned_registry()
    end
  catch
    _kind, _reason -> recover_poisoned_registry()
  end

  defp recover_poisoned_registry do
    epoch =
      case :persistent_term.get(@activity_key, :missing) do
        {:poisoned, value} when is_integer(value) -> value
        {:active, _registry, value} when is_integer(value) -> value
        {:idle, value} when is_integer(value) -> value
        _missing_or_malformed -> 0
      end

    :persistent_term.put(@activity_key, {:idle, epoch})
    registry = Process.whereis(@credential_registry)
    monitor = Process.monitor(registry)
    Process.exit(registry, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^registry, :killed}, 1_000
    _restarted = await_registry_restart(registry)
    assert :ok = CredentialFilter.ensure_installed()
  end

  defp rebind_provider_io_for_test do
    sink = Process.whereis(@provider_io_sink)

    Enum.each([ReqLLM.Supervisor, ReqLLM.TaskSupervisor], fn name ->
      process = Process.whereis(name)
      assert Process.group_leader(process, sink)
      assert Process.info(process, :group_leader) == {:group_leader, sink}
    end)

    assert :ok = CredentialFilter.ensure_installed()
  end

  # Concept: the same lazy stream the library hands the adapter, with the ending
  # this case is about.
  defp stream_response(stream \\ nil) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{finish_reason: :stop, status: 200, headers: [], usage: %{}}
      end)

    {:ok, model} = ReqLLM.model(Adapter.default_model())

    %ReqLLM.StreamResponse{
      stream: stream || Stream.map(["Hel", "lo"], &ReqLLM.StreamChunk.text/1),
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: ReqLLM.Context.new([ReqLLM.Context.user("hi")])
    }
  end

  # Concept: exactly the shape a provider that rejected the key produces -- the
  # key echoed back inside the error body the library raises out of the stream.
  defp echoing_stream do
    Stream.map([:reject], fn _rejected ->
      raise %ReqLLM.Error.API.Stream{
        reason: "Stream failed: authentication_error for x-api-key #{@sentinel}",
        cause: :closed
      }
    end)
  end
end
