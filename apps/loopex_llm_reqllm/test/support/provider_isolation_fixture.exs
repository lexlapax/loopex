defmodule Loopex.LLM.ReqLLM.ProviderIsolationFixture do
  @moduledoc false

  import ExUnit.Assertions
  alias Loopex.LLM.ReqLLM.{ProviderConfiguration, ProviderWorker}
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.{Model, Runtime.ProviderLifetime}

  # Concept: these fixtures exercise the public adapter, actual protected worker
  # entry, dependency stream, and controlled HTTP transport in a separate OS VM.
  # Technical depth: the escript loads the test VM's compiled code paths and
  # supplies literal synthetic transport configuration and a test manifest.
  # This is process conformance, never evidence of a self-contained package.
  def new(mode \\ :reply, options \\ []) do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-provider-isolation-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    {:ok, events} = Agent.start_link(fn -> [] end)
    {:ok, transport_events} = Agent.start_link(fn -> [] end)
    {:ok, probe_events} = Agent.start_link(fn -> [] end)
    {:ok, probe_listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, probe_port}} = :inet.sockname(probe_listener)

    probe =
      spawn_link(fn ->
        case :gen_tcp.accept(probe_listener) do
          {:ok, socket} ->
            Agent.update(probe_events, &[:connected | &1])
            observation = wait_closed(socket)
            Agent.update(probe_events, &[observation | &1])

          {:error, :closed} ->
            :ok
        end
      end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    expected = Keyword.get(options, :credential, System.get_env(Adapter.credential_variable()))

    response_body =
      if mode == :backpressure,
        do: {root, Keyword.get(options, :stream_prelude), Keyword.fetch!(options, :stream_parts)},
        else: Keyword.get(options, :response_body)

    acceptor =
      spawn_link(fn ->
        accept_loop(listener, events, transport_events, mode, expected, response_body)
      end)

    if mode == :closed_port, do: :gen_tcp.close(listener)

    fixture = %{
      root: root,
      events: events,
      transport_events: transport_events,
      probe_events: probe_events,
      listener: listener,
      acceptor: acceptor,
      mode: mode,
      paused: Keyword.get(options, :paused, false),
      hold_caller: Keyword.get(options, :hold_caller, false)
    }

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
      if Process.alive?(probe), do: Process.exit(probe, :kill)
      :gen_tcp.close(listener)
      :gen_tcp.close(probe_listener)
      if Process.alive?(events), do: Agent.stop(events)
      if Process.alive?(transport_events), do: Agent.stop(transport_events)
      if Process.alive?(probe_events), do: Agent.stop(probe_events)
      File.rm_rf!(root)
    end)

    launch = write_worker(root, mode, port, probe_port)

    if mode == :dotenv do
      File.write!(Path.join(root, ".env"), "LOOPEX_DOTENV_CANARY=loaded\nTIDEWAVE_REPL=true\n")
    end

    Map.put(fixture, :options, launch)
  end

  def request(options \\ []) do
    {:ok, request} =
      Model.request(
        Keyword.get(options, :model, Adapter.default_model()),
        Keyword.get(options, :messages, [%{"role" => "user", "content" => "hello"}]),
        sampling: %{"max_tokens" => 64},
        deadline: System.system_time(:millisecond) + Keyword.get(options, :deadline_ms, 10_000)
      )

    request
  end

  def complete(fixture, request \\ request(), progress \\ Model.discard_progress()),
    do: Adapter.complete(request, fixture.options, progress)

  def managed(
        fixture,
        request \\ request(),
        retainer \\ self(),
        progress \\ Model.discard_progress()
      ) do
    observer = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        result =
          ProviderLifetime.scoped(
            fn guardian, stop_reference ->
              send(observer, {:registered, self(), guardian, stop_reference})
              if fixture.paused, do: receive(do: (:continue -> :ok))
              if retainer == :unmanaged, do: :unmanaged, else: {:managed, retainer, 2_000}
            end,
            fn -> complete(fixture, request, progress) end
          )

        send(observer, {:completed, self(), result})
        if fixture.hold_caller, do: receive(do: (:finish_callback -> :ok))
      end)

    assert_receive {:registered, ^caller, guardian, stop_reference}, 1_000

    %{
      caller: caller,
      caller_monitor: caller_monitor,
      guardian: guardian,
      monitor: Process.monitor(guardian),
      stop_reference: stop_reference
    }
  end

  def stop(call) do
    stop = make_ref()
    deadline = System.monotonic_time(:millisecond) + 2_000

    send(
      call.guardian,
      {:loopex_provider_resource_stop, call.stop_reference, stop, self(), deadline,
       deadline + 100}
    )

    guardian = call.guardian
    monitor = call.monitor
    assert_receive {:loopex_provider_resource_stopped, ^stop, ^guardian}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500
  end

  def events(fixture), do: Agent.get(fixture.events, &Enum.reverse/1)
  def transport_events(fixture), do: Agent.get(fixture.transport_events, &Enum.reverse/1)
  def probe_events(fixture), do: Agent.get(fixture.probe_events, &Enum.reverse/1)
  def count(fixture), do: length(events(fixture))
  def marker(fixture, name), do: Path.join(fixture.root, name)
  def reached?(fixture, name), do: File.regular?(marker(fixture, name))
  def release(fixture), do: File.write!(marker(fixture, "release"), "release")

  def canaries(fixture), do: length(methods(fixture))

  def methods(fixture) do
    case File.read(marker(fixture, "canary")) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  def pid(fixture), do: fixture |> marker("pid") |> File.read!() |> String.to_integer()
  def namespace(fixture), do: fixture |> marker("namespace") |> File.read!()

  def assert_gone(fixture) do
    assert eventually(fn -> not alive?(pid(fixture)) end, 2_500)
    refute File.exists?(namespace(fixture))
  end

  def alive?(pid) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "stat="]) do
      {state, 0} -> not String.starts_with?(String.trim(state), "Z")
      {_output, 1} -> false
      result -> flunk("process observation unavailable: #{inspect(result)}")
    end
  end

  def eventually(fun, timeout \\ 5_000),
    do: await(fun, System.monotonic_time(:millisecond) + timeout)

  defp await(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        await(fun, deadline)
    end
  end

  defp write_worker(root, mode, port, probe_port) do
    manifest = %{
      "source" => "synthetic-process-fixture",
      "version" => "fixture",
      "dependency_lock_sha256" => String.duplicate("0", 64),
      "packaged_input_sha256" => String.duplicate("1", 64),
      "elixir" => System.version(),
      "otp" => ProviderWorker.otp_version()
    }

    source = """
    defmodule Loopex.LLM.ReqLLM.ProviderBuildIdentity do
      def manifest, do: #{inspect(manifest)}
    end
    defmodule LoopexProviderFixtureTransport do
      @behaviour ReqLLM.FinchRequestAdapter
      require Logger
      def call(%Finch.Request{} = request) do
        root = #{inspect(root)}
        mode = #{inspect(mode)}
        File.write!(Path.join(root, "canary"), request.method <> "\\n", [:append])
        File.write!(Path.join(root, "startup"), Jason.encode!(%{
          dotenv_absent: System.get_env("LOOPEX_DOTENV_CANARY") == nil,
          tidewave_absent: System.get_env("TIDEWAVE_REPL") == nil,
          req_dotenv_disabled: Application.get_env(:req_llm, :load_dotenv) == false,
          db_dotenv_disabled: Application.get_env(:llm_db, :load_dotenv) == false,
          no_core: Enum.all?(Application.started_applications(), fn {app, _, _} ->
            app not in [:loopex, :loopex_cli, :loopex_composition, :loopex_llm_reqllm]
          end)
        }))
        if mode == :backpressure, do: observe_backpressure(root)
        if mode == :unlinked_http do
          # The hook is executing inside the real StreamServer callback. A
          # separate child-local observer waits for that callback to attach its
          # real HTTP task, then removes only their dependency-owned link.
          stream_server = self()
          spawn(fn ->
            proof = try do
              Stream.repeatedly(fn -> File.exists?(Path.join(root, "unlink-http")) end)
              |> Enum.reduce_while(nil, fn ready, _ ->
                if ready, do: {:halt, nil}, else: (Process.sleep(10); {:cont, nil})
              end)
              state = :sys.get_state(stream_server, 2_000)
              http_task = state.http_task
              true = is_pid(http_task) and http_task != stream_server
              {:initial_call, {Task.Supervised, _function, _arity}} =
                Process.info(http_task, :initial_call)
              true = http_task in Task.Supervisor.children(ReqLLM.TaskSupervisor)
              {:links, links} = Process.info(stream_server, :links)
              true = http_task in links
              next = :sys.replace_state(stream_server, fn current ->
                true = current.http_task == http_task
                true = Process.unlink(http_task)
                current
              end, 2_000)
              true = next.http_task == http_task
              {:links, server_links} = Process.info(stream_server, :links)
              {:links, task_links} = Process.info(http_task, :links)
              %{
                server_alive: Process.alive?(stream_server),
                http_task_alive: Process.alive?(http_task),
                http_task_supervised: http_task in Task.Supervisor.children(ReqLLM.TaskSupervisor),
                dependency_link_present_before: true,
                dependency_link_removed: http_task not in server_links and stream_server not in task_links
              }
            catch
              _, _ -> %{setup_failed: true}
            end
            File.write!(Path.join(root, "unlinked-http-proof.pending"), Jason.encode!(proof))
            File.rename!(Path.join(root, "unlinked-http-proof.pending"), Path.join(root, "unlinked-http-proof"))
          end)
        end
        if mode in [:detached_descendant, :detached_descendant_malformed] do
          task = Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
            receive do: (:begin -> :ok)
            owner = self()
            session = spawn_link(fn ->
              socket = spawn(fn ->
                {:ok, connection} = :gen_tcp.connect({127, 0, 0, 1}, #{probe_port}, [:binary, active: false], 2_000)
                send(owner, {:socket_open, self()})
                :gen_tcp.recv(connection, 0, :infinity)
              end)
              send(owner, {:session_socket, self(), socket})
              receive do: (:finish -> :ok)
            end)
            monitor = Process.monitor(session)
            receive do
              {:session_socket, ^session, socket} ->
                receive do: ({:socket_open, ^socket} -> :ok)
                send(session, :finish)
                receive do: ({:DOWN, ^monitor, :process, ^session, :normal} -> :ok)
                %{session_dead: not Process.alive?(session), socket_alive: Process.alive?(socket)}
            end
          end)
          task_monitor = Process.monitor(task.pid)
          task_pid = task.pid
          send(task_pid, :begin)
          proof = Task.await(task, 2_000)
          receive do: ({:DOWN, ^task_monitor, :process, ^task_pid, :normal} -> :ok)
          proof = Map.put(proof, :task_dead, not Process.alive?(task_pid))
          File.write!(Path.join(root, "detached-proof"), Jason.encode!(proof))
        end
        if mode in [:hold_before_return, :hold_before_error, :descendant, :backpressure] do
          {:group_leader, local_leader} = Process.info(self(), :group_leader)
          File.write!(Path.join(root, "pre-return-proof.pending"), Jason.encode!(%{
            stream_server_alive: Process.alive?(self()),
            local_group_leader: node(local_leader) == node()
          }))
          File.rename!(Path.join(root, "pre-return-proof.pending"), Path.join(root, "pre-return-proof"))
          if mode == :descendant do
            spawn(fn ->
              Port.open({:spawn_executable, ~c"/bin/sh"}, [
                :binary, :exit_status,
                {:args, [~c"-c", String.to_charlist("echo $$ > " <> Path.join(root, "descendant") <> "; exec /bin/sleep 120")]}])
              Process.sleep(:infinity)
            end)
          end
          Stream.repeatedly(fn -> File.exists?(Path.join(root, "release")) end)
          |> Enum.reduce_while(nil, fn ready, _ ->
            if ready, do: {:halt, :ready}, else: (Process.sleep(10); {:cont, nil})
          end)
        end
        if mode in [:diagnostics, :diagnostics_malformed] do
          key = Enum.find_value(request.headers, fn {name, value} ->
            if String.downcase(name) in ["x-api-key", "authorization"], do: value
          end)
          io_result = fn ->
            try do IO.write(key); :written rescue ArgumentError -> :refused end
          end
          direct = io_result.()
          supervised = ReqLLM.TaskSupervisor |> Task.Supervisor.async(io_result) |> Task.await(1_000)
          File.write!(Path.join(root, "io-results"), Jason.encode!(%{direct: direct, supervised: supervised}))
          for action <- [fn -> IO.write(key) end, fn -> IO.write(:stderr, key) end,
            fn -> Logger.error(key, diagnostic: %{key => key}) end,
            fn -> :logger.error(~c"~ts", [key]) end] do
            try do action.() catch _, _ -> :ok end
          end
          spawn(fn -> raise key end)
          spawn(fn ->
            Stream.repeatedly(fn -> File.exists?(Path.join(root, "release-diagnostics")) end)
            |> Enum.reduce_while(nil, fn ready, _ ->
              if ready, do: {:halt, nil}, else: (Process.sleep(10); {:cont, nil})
            end)
            delayed_direct = io_result.()
            delayed_supervised = ReqLLM.TaskSupervisor |> Task.Supervisor.async(io_result) |> Task.await(1_000)
            File.write!(Path.join(root, "delayed-io-results"), Jason.encode!(%{
              direct: delayed_direct, supervised: delayed_supervised
            }))
            Logger.error(key)
            File.write!(Path.join(root, "delayed-diagnostics"), "attempted")
          end)
          File.write!(Path.join(root, "diagnostics"), "attempted")
        end
        if mode in [:credential_metadata_repeated, :credential_metadata_key,
          :credential_overlap, :credential_ordinary_split, :credential_forms,
          :credential_report, :credential_raise, :credential_throw,
          :credential_exit, :credential_crash_event, :credential_sink_loss] do
          credential_probe(mode, request, root)
        end
        case mode do
          :raise -> raise "synthetic provider failure"
          :throw -> throw(:synthetic_provider_failure)
          :exit -> exit(:synthetic_provider_failure)
          :malformed_return -> {:not_a_finch_request, request.host}
          :diagnostics_malformed -> {:not_a_finch_request, request.host}
          :detached_descendant_malformed -> {:not_a_finch_request, request.host}
          :tagged_not_dispatched -> {:error, {:not_dispatched, "model_call_failed"}}
          _ -> %{request | scheme: :http, host: "127.0.0.1", port: #{port}, path: "/", query: nil}
        end
      end

      # Only this protected child holds diagnostic inputs and raw DOWN reasons.
      # Host markers acknowledge actual calls with bounded, non-secret values.
      defp credential_probe(mode, request, root) do
        key = Enum.find_value(request.headers, fn {name, value} ->
          if String.downcase(name) == "x-api-key", do: value
        end)
        true = is_binary(key) and byte_size(key) > 0
        split = div(byte_size(key), 2)
        <<left::binary-size(split), right::binary>> = key
        report = %{
          label: {:gen_server, :terminate},
          last_message: {:start_http, ReqLLM.Providers.Anthropic, :model, :context,
            [api_key: key], ReqLLM.Finch},
          reason: {:provider_library_throw_after_handoff, key}
        }

        actions = case mode do
          :credential_metadata_repeated ->
            :logger.error("safe", %{safe_diagnostic: key <> "|" <> key})
            ["metadata_repeated"]
          :credential_metadata_key ->
            :logger.error("safe", %{safe_diagnostic: %{key => :present}})
            ["metadata_key"]
          :credential_overlap ->
            true = String.ends_with?(key, "-first")
            other = String.replace_suffix(key, "-first", "-second")
            true = other != key
            :logger.error("safe", %{safe_diagnostic: "first=" <> key <> " second=" <> other})
            ["two_distinct_credentials_one_event"]
          :credential_ordinary_split ->
            ordinary = "ordinary credential=" <> key <> " repeated=" <> key
            chardata = ["split credential=", left, right, " repeated=", key]
            :logger.error(ordinary)
            :logger.error(chardata)
            ["ordinary_repeated", "split_repeated"]
          :credential_forms ->
            :logger.error(["safe-string ", left, right, " repeated ", key])
            :logger.error(~c"safe-format ~ts~ts", [left, right], %{safe_diagnostic: key})
            :logger.error(%{reason: {:safe_report, key}}, %{safe_diagnostic: %{key => key}})
            ["string_chardata", "format_args_metadata", "report_metadata_key"]
          :credential_report ->
            :logger.error(report)
            ["request_credential_report"]
          :credential_sink_loss ->
            sink = Process.group_leader()
            caller = self()
            observer = spawn(fn ->
              monitor = Process.monitor(sink)
              send(caller, {:sink_observer_ready, self()})
              receive do
                {:DOWN, ^monitor, :process, ^sink, reason} ->
                  publish(root, "credential-probe", %{
                    actions: ["sink_loss"], key_present: true,
                    sink_down: true, sink_reason_killed: reason == :killed
                  })
              end
            end)
            receive do: ({:sink_observer_ready, ^observer} -> :ok)
            await_fault_release(root)
            Process.exit(sink, :kill)
            Process.sleep(:infinity)
          ending when ending in [:credential_raise, :credential_throw,
            :credential_exit, :credential_crash_event] ->
            true = System.get_env("LOOPEX_PROVIDER_API_KEY") == nil
            System.put_env("LOOPEX_PROVIDER_API_KEY", "rotated-after-request-construction")
            publish(root, "credential-probe", %{actions: [Atom.to_string(ending)],
              key_present: true, environment_rotated: true})
            if ending != :credential_raise do
              observe_termination(self(), key, root)
              await_fault_release(root)
            end
            case ending do
              :credential_raise -> raise "req_llm_transport_raised_after_handoff " <> key
              :credential_exit -> exit({:provider_library_exit_after_handoff, key})
              _ -> throw({:provider_library_throw_after_handoff, key})
            end
        end
        publish(root, "credential-probe", %{actions: actions, key_present: true})
      end

      defp observe_termination(stream_server, key, root) do
        observer = spawn(fn ->
          monitor = Process.monitor(stream_server)
          send(stream_server, {:termination_observer_ready, self()})
          receive do
            {:DOWN, ^monitor, :process, ^stream_server, reason} ->
              rendered = inspect(reason, limit: :infinity, printable_limit: :infinity)
              publish(root, "termination-proof", %{
                actual_stream_server_down: true,
                credential_in_reason: String.contains?(rendered, key)
              })
          end
        end)
        receive do: ({:termination_observer_ready, ^observer} -> :ok)
      end

      defp publish(root, name, proof) do
        File.write!(Path.join(root, name <> ".pending"), Jason.encode!(proof))
        File.rename!(Path.join(root, name <> ".pending"), Path.join(root, name))
      end

      defp await_fault_release(root) do
        publish(root, "fault-ready", %{observer_installed: true})
        Stream.repeatedly(fn -> File.exists?(Path.join(root, "release-fault")) end)
        |> Enum.reduce_while(nil, fn ready, _ ->
          if ready, do: {:halt, nil}, else: (Process.sleep(10); {:cont, nil})
        end)
      end

      # Concept: this child-only observer never changes admission or calls a
      # producer callback; the real ReqLLM stream does that.
      # Technical depth: exported witnesses contain counts, flags, frame kinds,
      # and stack-function identities, never frames or raw process state.
      defp observe_backpressure(root) do
        worker = Loopex.LLM.ReqLLM.ProviderWorker
        codec = Loopex.LLM.ReqLLM.ProviderCodec
        [slots] = Enum.filter(:ets.all(), &(:ets.info(&1, :name) == worker))
        owner = :ets.info(slots, :owner)
        {:links, links} = Process.info(owner, :links)
        [writer] = Enum.filter(links, fn pid ->
          is_pid(pid) and Process.info(pid, :current_function) ==
            {:current_function, {worker, :write_frames, 5}}
        end)
        [socket] = Enum.filter(Port.list(), fn port ->
          try do
            Port.info(port, :connected) == {:connected, owner} and
              match?({:ok, {:local, _}}, :inet.peername(port))
          catch
            _, _ -> false
          end
        end)
        :ok = :inet.setopts(socket, sndbuf: 1_024, high_watermark: 1_024, low_watermark: 512)
        observer = spawn(fn ->
          Process.monitor(writer)
          receive do
            :observe -> backpressure_observer(root, socket, owner, writer, slots, nil, 0)
          end
        end)
        1 = :erlang.trace_pattern({codec, :send, 3}, true, [:local])
        1 = :erlang.trace(writer, true, [:call, {:tracer, observer}])
        send(observer, :observe)
        publish(root, "backpressure-ready", %{actual_writer: true, private_socket: true})
      catch
        _, _ ->
          publish(root, "backpressure-error", %{setup_failed: true})
          exit(:backpressure_fixture_setup_failed)
      end

      defp backpressure_observer(root, socket, owner, writer, slots, kind, calls) do
        receive do
          {:trace, ^writer, :call,
            {Loopex.LLM.ReqLLM.ProviderCodec, :send, [^socket, next_kind, _payload]}} ->
            backpressure_observer(root, socket, owner, writer, slots, next_kind, calls + 1)
          {:DOWN, _, :process, ^writer, _} -> :ok
        after
          10 ->
            try do
              {:ok, [send_pend: pending]} = :inet.getstat(socket, [:send_pend])
              info = Process.info(writer, [:current_stacktrace, :messages])
              in_send = Enum.any?(info[:current_stacktrace], fn
                {Loopex.LLM.ReqLLM.ProviderCodec, :send, 3, _} -> true
                _ -> false
              end)
              publish(root, "backpressure-observation", %{
                pending_bytes: pending, writer_in_send: in_send,
                actual_send_calls: calls, kind: if(kind, do: Atom.to_string(kind), else: nil),
                slot_items: :ets.info(slots, :size), mailbox_count: length(info[:messages]),
                stack: Enum.map(info[:current_stacktrace], fn {module, function, arity, _} ->
                  Atom.to_string(module) <> "." <> Atom.to_string(function) <> "/" <> Integer.to_string(arity)
                end)
              })
              # The first send may return after filling the driver's bounded
              # queue. Release the next real HTTP delta only after observing
              # that queue; its write must then encounter the busy socket.
              if pending > 0 and not in_send and kind == :delta and
                   :ets.info(slots, :size) == 0 and
                   not File.exists?(Path.join(root, "backpressure-buffered")) do
                publish(root, "backpressure-buffered", %{pending_bytes: pending,
                  writer_in_send: false, actual_send_calls: calls, slot_items: 0})
              end
              if pending > 0 and in_send and kind in [:delta, :terminal] do
                if not File.exists?(Path.join(root, "backpressure-blocked")) do
                  publish(root, "backpressure-blocked", %{pending_bytes: pending,
                    writer_in_send: true, kind: Atom.to_string(kind), actual_send_calls: calls})
                end
                messages = info[:messages]
                terminals = for {:terminal, result} <- messages, do: result
                case terminals do
                  [%{"status" => "reply", "reply" => reply}] ->
                    {:current_stacktrace, owner_stack} = Process.info(owner, :current_stacktrace)
                    waiting_terminal = Enum.any?(owner_stack, fn
                      {Loopex.LLM.ReqLLM.ProviderWorker, :await_terminal, 2, _} -> true
                      _ -> false
                    end)
                    if waiting_terminal and not File.exists?(Path.join(root, "backpressure-complete")) do
                      progress_messages = Enum.count(messages, &(&1 == :progress_ready))
                      publish(root, "backpressure-complete", %{
                        pending_bytes: pending, writer_in_send: true,
                        producer_waiting_terminal: true,
                        slot_items: :ets.info(slots, :size),
                        delta_items: length(:ets.lookup(slots, :delta)),
                        progress_notifications: progress_messages,
                        terminal_messages: length(terminals),
                        other_messages: length(messages) - progress_messages - length(terminals),
                        producer_delta_count: reply.delta_count,
                        terminal_text_bytes: byte_size(reply.text)
                      })
                    end
                  _ -> :ok
                end
              end
            catch
              _, _ ->
                if Process.alive?(writer) and not File.exists?(Path.join(root, "backpressure-error")) do
                  publish(root, "backpressure-error", %{observation_failed: true})
                end
            end
            backpressure_observer(root, socket, owner, writer, slots, kind, calls)
        end
      end

      # Concept: the actual entry crosses both readiness boundaries itself.
      # Technical depth: this observer holds only that process, never supplies
      # a protocol frame, and exports flags rather than socket/process payloads.
      # The host holds its guardian while each reader position is established,
      # so a fast dependency startup cannot race credential delivery.
      def credential_entry(arguments) do
        root = #{inspect(root)}
        deadline = arguments |> List.last() |> String.to_integer()
        codec = Loopex.LLM.ReqLLM.ProviderCodec
        {entry, _monitor} = spawn_monitor(fn ->
          receive do
            :start -> Loopex.LLM.ReqLLM.ProviderWorker.main(arguments)
          after
            max(deadline - System.system_time(:millisecond), 0) ->
              exit(:fixture_deadline)
          end
        end)

        publish(root, "credential-entry-held", %{actual_entry_not_started: true})
        credential_wait(fn -> File.exists?(Path.join(root, "start-entry")) end, deadline)
        send(entry, :start)
        credential_wait(fn -> credential_reader?(entry) end, deadline)
        true = :erlang.suspend_process(entry)
        true = credential_reader?(entry)
        {:status, :suspended} = Process.info(entry, :status)
        [socket] = Enum.filter(Port.list(), fn port ->
          try do
            Port.info(port, :connected) == {:connected, entry} and
              match?({:ok, {:local, _}}, :inet.peername(port))
          catch
            _, _ -> false
          end
        end)
        :ok = :inet.setopts(socket, recbuf: 1_024, buffer: 1_024)
        1 = :erlang.trace_pattern({codec, :send, 3}, true, [:local])
        1 = :erlang.trace(entry, true, [:call, {:tracer, self()}])
        publish(root, "bootstrap-reader-held", %{
          actual_reader_suspended: true, private_socket: true
        })

        credential_wait(fn -> File.exists?(Path.join(root, "resume-bootstrap")) end, deadline)
        true = :erlang.resume_process(entry)
        receive do
          {:trace, ^entry, :call, {^codec, :send, [^socket, :ready, _identity]}} -> :ok
        after
          max(deadline - System.system_time(:millisecond), 0) ->
            exit(:fixture_deadline)
        end
        publish(root, "credential-ready-observed", %{actual_ready_send: true})

        credential_wait(fn ->
          File.exists?(Path.join(root, "hold-credential-reader"))
        end, deadline)
        credential_wait(fn -> credential_reader?(entry) end, deadline)
        true = :erlang.suspend_process(entry)
        true = credential_reader?(entry)
        {:status, :suspended} = Process.info(entry, :status)
        publish(root, "credential-reader-held", %{
          actual_reader_suspended: true, actual_ready_send: true,
          private_socket: true
        })

        # There is deliberately no release for this reader. Only the real OS
        # cleanup owner can end this credential-bearing invocation lifetime.
        Process.sleep(:infinity)
      catch
        _, _ ->
          publish(#{inspect(root)}, "credential-boundary-error", %{setup_failed: true})
          exit(:credential_boundary_setup_failed)
      end

      defp credential_reader?(entry) do
        case Process.info(entry, :current_stacktrace) do
          {:current_stacktrace, stack} ->
            Enum.any?(stack, fn
              {Loopex.LLM.ReqLLM.ProviderCodec, :recv, 2, _} -> true
              _ -> false
            end)
          nil -> false
        end
      end

      defp credential_wait(predicate, deadline) do
        cond do
          predicate.() -> :ok
          System.system_time(:millisecond) >= deadline -> exit(:fixture_deadline)
          true ->
            Process.sleep(10)
            credential_wait(predicate, deadline)
        end
      end
    end
    defmodule LoopexProviderFixtureEntry do
    def main(arguments) do
    Application.put_env(:req_llm, :finch_request_adapter, LoopexProviderFixtureTransport)
    [path | _] = Enum.map(arguments, &List.to_string/1)
    File.write!(#{inspect(Path.join(root, "pid"))}, System.pid())
    File.write!(#{inspect(Path.join(root, "namespace"))}, Path.dirname(path))
    File.write!(#{inspect(Path.join(root, "entry-env"))}, inspect(Enum.sort(Map.keys(System.get_env()))))
    if #{inspect(mode)} == :dotenv, do: File.cd!(#{inspect(root)})
    if #{inspect(mode)} == :pre_entry_crash, do: System.halt(71)
    if #{inspect(mode)} == :hold_before_entry, do: Process.sleep(:infinity)
    if #{inspect(mode)} == :delayed_entry do
      Stream.repeatedly(fn -> File.exists?(#{inspect(Path.join(root, "release"))}) end)
      |> Enum.reduce_while(nil, fn ready, _ ->
        if ready, do: {:halt, nil}, else: (Process.sleep(10); {:cont, nil})
      end)
    end
    if #{inspect(mode)} == :credential_transfer do
      LoopexProviderFixtureTransport.credential_entry(Enum.map(arguments, &List.to_string/1))
    else
    if #{inspect(mode)} in [:credential_sink_loss, :credential_throw,
      :credential_exit, :credential_crash_event] do
      # A fixture-only outer monitor preserves the observation VM after the
      # actual entry dies through its UNCHANGED sink/dependency links. It has
      # no private credential frame and exports neither its raw DOWN reason
      # nor a substitute Worker result or cleanup ACK.
      {entry, monitor} = spawn_monitor(fn ->
        Loopex.LLM.ReqLLM.ProviderWorker.main(Enum.map(arguments, &List.to_string/1))
      end)
      receive do
        {:DOWN, ^monitor, :process, ^entry, reason} ->
          path = #{inspect(Path.join(root, "entry-down"))}
          File.write!(path <> ".pending", Jason.encode!(%{
            worker_down: true, abnormal: reason != :normal
          }))
          File.rename!(path <> ".pending", path)
      end
      Process.sleep(:infinity)
    else
      Loopex.LLM.ReqLLM.ProviderWorker.main(Enum.map(arguments, &List.to_string/1))
    end
    end
    end
    end
    """

    paths = :io_lib.format(~c"~tp", [:code.get_path()]) |> IO.iodata_to_binary()
    script = Path.join(root, "worker.escript")
    beams = prepare_worker(root, source, paths)
    embedded = :io_lib.format(~c"~tp", [beams]) |> IO.iodata_to_binary()

    File.write!(script, """
    #!/usr/bin/env escript
    %%! +S 2:2 +SDcpu 1 +SDio 1 +A 2
    main(Arguments) ->
      ok = code:add_paths(#{paths}),
      {ok, _} = application:ensure_all_started(elixir),
      lists:foreach(fun({Module, Bytes}) ->
        {module, Module} = code:load_binary(Module, "fixture.beam", base64:decode(Bytes))
      end, #{embedded}),
      'Elixir.LoopexProviderFixtureEntry':main(Arguments),
      ok.
    """)

    {:ok, digest} = ProviderConfiguration.file_digest(script)

    [
      worker_path: script,
      interpreter_path: Path.join(List.to_string(:code.root_dir()), "bin/escript"),
      worker_sha256: digest,
      build_manifest_sha256:
        :crypto.hash(:sha256, :erlang.term_to_binary(manifest, [:deterministic]))
        |> Base.encode16(case: :lower),
      cleanup_grace_ms: 2_000
    ]
  end

  # Concept: fixture compilation is preparation, not work charged to a model
  # request. Like the packaged companion, the launched child loads built code.
  # Technical depth: compile only the synthetic modules in an isolated VM
  # before request creation. No worker entry, dependency application startup,
  # model catalog lookup, socket, readiness frame or credential is pre-started.
  # The actual child still owns all those steps under the unchanged deadline.
  # The compiler's ten-second fail-stop starts at its main entry and bounds
  # compilation, not OS bootstrap or immediate response to parent death;
  # it extends neither request deadlines nor ExUnit timeouts. Root cleanup is
  # registered first, including for compiler failure.
  defp prepare_worker(root, source, paths) do
    preparation = Path.join(root, "prepare.escript")

    compiler = """
    for {module, bytes} <- Code.compile_string(Base.decode64!("#{Base.encode64(source)}")) do
      File.write!(Path.join(#{inspect(root)}, Atom.to_string(module) <> ".beam"), bytes)
    end
    """

    File.write!(preparation, """
    #!/usr/bin/env escript
    %%! +S 2:2 +SDcpu 1 +SDio 1 +A 2
    main([]) ->
      spawn(fun() -> receive after 10000 -> erlang:halt(70) end end),
      ok = code:add_paths(#{paths}),
      {ok, _} = application:ensure_all_started(elixir),
      'Elixir.Code':eval_string(base64:decode("#{Base.encode64(compiler)}")),
      ok.
    """)

    environment =
      Loopex.LLM.ReqLLM.ProviderLauncher.spawn_environment()
      |> Map.new(fn {name, false} -> {List.to_string(name), nil} end)
      # Preserve the caller's search path, including bootstrap interpreter
      # shadows. Both launched executables below are nevertheless absolute.
      |> Map.delete("PATH")
      |> Map.merge(%{
        "HOME" => root,
        "TMPDIR" => root,
        "ERL_CRASH_DUMP" => "/dev/null",
        "ERL_CRASH_DUMP_SECONDS" => "0"
      })

    {output, status} =
      System.cmd(
        "/bin/sh",
        [
          "-c",
          "exec \"$1\" \"$2\" </dev/null",
          "fixture-compile",
          Path.join(List.to_string(:code.root_dir()), "bin/escript"),
          preparation
        ],
        env: Map.to_list(environment),
        stderr_to_stdout: true
      )

    assert status == 0, "synthetic worker compilation failed: #{inspect(output)}"

    for module <- [
          Loopex.LLM.ReqLLM.ProviderBuildIdentity,
          LoopexProviderFixtureTransport,
          LoopexProviderFixtureEntry
        ] do
      {module,
       root |> Path.join(Atom.to_string(module) <> ".beam") |> File.read!() |> Base.encode64()}
    end
  end

  defp accept_loop(listener, events, transport_events, mode, expected, response_body) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        Agent.update(transport_events, &[:connected | &1])

        handler =
          spawn_link(fn ->
            receive do
              {:socket, ^socket} ->
                serve(socket, events, transport_events, mode, expected, response_body)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:socket, socket})
        accept_loop(listener, events, transport_events, mode, expected, response_body)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, events, transport_events, mode, expected, response_body) do
    with {:ok, headers, body} <- read_request(socket, "") do
      authorized = is_binary(expected) and String.contains?(headers, expected)
      Agent.update(events, &[{Jason.decode!(body), authorized} | &1])

      case mode do
        :backpressure ->
          serve_backpressure(socket, transport_events, response_body)

        mode when mode in [:blocked, :timeout, :unlinked_http] ->
          observation = wait_closed(socket)
          Agent.update(transport_events, &[observation | &1])

        :rate_limited ->
          respond(socket, "429 Too Many Requests", "application/json", "{}")

        mode when mode in [:http_error, :hold_before_error] ->
          respond(socket, "500 Internal Server Error", "application/json", "{}")

        :malformed_response ->
          respond(socket, "200 OK", "application/json", "{not-json")

        :incomplete_stream ->
          respond(socket, "200 OK", "text/event-stream", "data: {\"type\":\"message_start\"")

        :closed_port ->
          :ok

        _ ->
          respond(socket, "200 OK", "text/event-stream", response_body || stream_body())
      end
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        read_body(socket, headers, body, String.to_integer(length))

      [_partial] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, more} -> read_request(socket, bytes <> more)
          error -> error
        end
    end
  end

  defp read_body(_socket, headers, body, length) when byte_size(body) >= length,
    do: {:ok, headers, binary_part(body, 0, length)}

  defp read_body(socket, headers, body, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, more} -> read_body(socket, headers, body <> more, length)
      error -> error
    end
  end

  defp wait_closed(socket) do
    case :gen_tcp.recv(socket, 0, 100) do
      {:error, :timeout} -> wait_closed(socket)
      {:error, :closed} -> :closed
      _unexpected -> :unexpected_socket_result
    end
  end

  defp serve_backpressure(socket, events, {root, prelude, {prefix, fill, suffix}}) do
    parts = [{"fill-writer", fill, :writer_fill_sent}, {"continue-stream", suffix, :suffix_sent}]

    {first, event, parts} =
      if is_binary(prelude),
        do: {prelude, :prelude_sent, [{"begin-pressure", prefix, :prefix_sent} | parts]},
        else: {prefix, :prefix_sent, parts}

    size = byte_size(first) + Enum.sum(Enum.map(parts, fn {_, bytes, _} -> byte_size(bytes) end))

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: #{size}\r\nrequest-id: req-fixture-001\r\nconnection: close\r\n\r\n" <>
          first
      )

    Agent.update(events, &[event | &1])
    server = self()
    reader = spawn_link(fn -> send(server, {:peer_closed, self(), wait_closed(socket)}) end)

    await_stream_release(
      socket,
      reader,
      root,
      parts,
      events
    )
  end

  defp await_stream_release(_socket, reader, _root, [], events) do
    receive do
      {:peer_closed, ^reader, observation} -> Agent.update(events, &[observation | &1])
    end
  end

  defp await_stream_release(socket, reader, root, [{marker, bytes, event} | rest] = parts, events) do
    receive do
      {:peer_closed, ^reader, observation} -> Agent.update(events, &[observation | &1])
    after
      10 ->
        if File.exists?(Path.join(root, marker)) do
          :ok = :gen_tcp.send(socket, bytes)
          Agent.update(events, &[event | &1])
          await_stream_release(socket, reader, root, rest, events)
        else
          await_stream_release(socket, reader, root, parts, events)
        end
    end
  end

  defp respond(socket, status, type, body),
    do:
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status}\r\ncontent-type: #{type}\r\ncontent-length: #{byte_size(body)}\r\nrequest-id: req-fixture-001\r\nconnection: close\r\n\r\n#{body}"
      )

  defp stream_body do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_fixture",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-haiku-4-5",
          "content" => [],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "loopex"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]
    |> Enum.map_join(fn event -> "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n" end)
  end
end
