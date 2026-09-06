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
