Code.require_file("support/provider_phase_diagnostic.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderBridgeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Loopex.Model
  alias Loopex.Runtime.ProviderLifetime
  alias Loopex.LLM.ReqLLM.{ProviderBridge, ProviderConfiguration, ProviderPhaseDiagnostic}

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:crypto)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-provider-bridge-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    previous = System.get_env("LOOPEX_PROVIDER_API_KEY")
    System.put_env("LOOPEX_PROVIDER_API_KEY", "synthetic-provider-credential")

    on_exit(fn ->
      if previous,
        do: System.put_env("LOOPEX_PROVIDER_API_KEY", previous),
        else: System.delete_env("LOOPEX_PROVIDER_API_KEY")

      File.rm_rf!(root)
    end)

    {:ok, request} =
      Model.request("fixture:model", [%{"role" => "user", "content" => "hello"}],
        sampling: %{"max_tokens" => 4},
        deadline: System.system_time(:millisecond) + 10_000
      )

    {:ok, root: root, request: request}
  end

  test "an unmanaged reply returns only after real child cessation", %{
    root: root,
    request: request
  } do
    configuration = worker(root, :reply)

    assert {:ok, reply} =
             ProviderBridge.complete(request, configuration, Model.discard_progress())

    assert reply.text == "answer"
    assert reply.usage == %{input_tokens: 7, output_tokens: 2}
    assert reply.canonical_request_bytes == request.canonical_request_bytes
    assert reply.staged_request_digest == request.staged_request_digest
    assert reply.delta_count == 10_000
    assert File.read!(Path.join(root, "credential-size")) == "29"
    refute process_alive?(child_pid(root))
    refute File.exists?(File.read!(Path.join(root, "namespace")))
  end

  test "a managed normal callback exit leaves the retainer in charge", %{
    root: root,
    request: request
  } do
    configuration = worker(root, :reply) |> Map.put(:cleanup_grace_ms, 1)
    parent = self()

    retainer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        result =
          ProviderLifetime.scoped(
            fn guardian, stop_reference ->
              send(parent, {:registered, guardian, stop_reference})
              {:managed, retainer, 2_000}
            end,
            fn -> ProviderBridge.complete(request, configuration, Model.discard_progress()) end
          )

        send(parent, {:reply, result})
      end)

    assert_receive {:registered, guardian, stop_reference}, 1_000
    guardian_monitor = Process.monitor(guardian)
    assert_receive {:reply, {:ok, _reply}}, 5_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert Process.alive?(guardian)
    assert process_alive?(child_pid(root))
    stop = make_ref()
    until = System.monotonic_time(:millisecond) + 2_000

    send(
      guardian,
      {:loopex_provider_resource_stop, stop_reference, stop, self(), until, until + 100}
    )

    assert_receive {:loopex_provider_resource_stopped, ^stop, ^guardian}, 2_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 500
    refute process_alive?(child_pid(root))
    send(retainer, :stop)
  end

  test "retainer loss during bootstrap stops the real child", %{root: root, request: request} do
    configuration = worker(root, :stall_ready)
    parent = self()

    retainer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    caller =
      spawn(fn ->
        ProviderLifetime.scoped(
          fn guardian, stop_reference ->
            send(parent, {:registered, guardian, stop_reference})
            {:managed, retainer, 2_000}
          end,
          fn -> ProviderBridge.complete(request, configuration, Model.discard_progress()) end
        )
      end)

    assert_receive {:registered, guardian, _stop_reference}, 1_000
    assert eventually(fn -> File.regular?(Path.join(root, "pid")) end, 5_000)
    monitor = Process.monitor(guardian)
    Process.exit(retainer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 2_500
    refute process_alive?(child_pid(root))
    refute File.exists?(File.read!(Path.join(root, "namespace")))
    Process.exit(caller, :kill)
  end

  test "after bootstrap the provider namespace refuses a second client", %{
    root: root,
    request: request
  } do
    {caller, guardian, stop_reference} = registered_call(request, worker(root, :stall_ready))
    send(caller, :continue)
    assert eventually(fn -> File.regular?(Path.join(root, "booted")) end, 5_000)
    namespace = File.read!(Path.join(root, "namespace"))

    # Receipt of bootstrap proves that the first connection was accepted; the
    # second connect must now be refused by the actual closed listener, not
    # merely receive no application reply before an arbitrary wait expires.
    assert {:error, :econnrefused} =
             :gen_tcp.connect({:local, namespace <> "/data"}, 0, [
               :binary,
               active: false,
               packet: :raw
             ])

    refute File.exists?(Path.join(root, "credential-size"))
    stop_registered(guardian, stop_reference)
    assert_receive {:completed, {:error, {:dispatched_or_unknown, "model_call_failed"}}}, 1_000
    refute process_alive?(child_pid(root))
    refute File.exists?(namespace)
  end

  test "well formed readiness from another invocation never receives the credential", %{
    root: root,
    request: request
  } do
    for field <- ["nonce", "build_manifest_sha256"] do
      case_root = Path.join(root, field)
      File.mkdir!(case_root)

      assert {:error, {:not_dispatched, "model_call_failed"}} =
               ProviderBridge.complete(
                 request,
                 worker(case_root, {:wrong_ready, field}),
                 Model.discard_progress()
               )

      refute File.exists?(Path.join(case_root, "credential-size"))
      refute process_alive?(child_pid(case_root))
      refute File.exists?(File.read!(Path.join(case_root, "namespace")))
    end
  end

  test "well formed dispatch and reply bindings cannot cross invocation identities", %{
    root: root,
    request: request
  } do
    for phase <- [:dispatch, :terminal], field <- ["nonce", "staged_request_digest"] do
      case_root = Path.join(root, "#{phase}-#{field}")
      File.mkdir!(case_root)

      assert {:error, {:dispatched_or_unknown, "model_call_failed"}} =
               ProviderBridge.complete(
                 request,
                 worker(case_root, {:wrong_binding, phase, field}),
                 Model.discard_progress()
               )

      assert File.read!(Path.join(case_root, "credential-size")) == "29"
      refute process_alive?(child_pid(case_root))
      refute File.exists?(File.read!(Path.join(case_root, "namespace")))
    end
  end

  test "credential limits are checked after readiness and before invocation", %{
    root: root,
    request: request
  } do
    for {key, expected} <- [
          {nil, :refused},
          {"", :refused},
          {String.duplicate("x", 65_536), :sent},
          {String.duplicate("x", 65_537), :refused}
        ] do
      case key do
        nil -> System.delete_env("LOOPEX_PROVIDER_API_KEY")
        value -> System.put_env("LOOPEX_PROVIDER_API_KEY", value)
      end

      case_root = Path.join(root, "case-#{System.unique_integer([:positive])}")
      File.mkdir!(case_root)
      configuration = worker(case_root, :reply)
      result = ProviderBridge.complete(request, configuration, Model.discard_progress())

      if expected == :sent do
        assert {:ok, _reply} = result
        assert File.read!(Path.join(case_root, "credential-size")) == "65536"
      else
        assert result == {:error, {:not_dispatched, "model_call_failed"}}
        refute File.exists?(Path.join(case_root, "credential-size"))
      end

      refute process_alive?(child_pid(case_root))
    end
  end

  test "only the closed unreadable status maps to the invalid Core candidate", %{
    root: root,
    request: request
  } do
    configuration = worker(root, :unreadable)
    assert {:ok, %{}} = ProviderBridge.complete(request, configuration, Model.discard_progress())
  end

  test "duplicate terminal frames fail closed after possible delivery", %{
    root: root,
    request: request
  } do
    configuration = worker(root, :duplicate)

    assert {:error, {:dispatched_or_unknown, "model_call_failed"}} =
             ProviderBridge.complete(request, configuration, Model.discard_progress())

    refute process_alive?(child_pid(root))
  end

  test "a finite failure is exposed only after its single terminal and clean EOF", %{root: root} do
    for ending <- [:clean, :duplicate, :extra_frame, :partial_frame, :malformed] do
      case_root = Path.join(root, Atom.to_string(ending))
      File.mkdir!(case_root)
      configuration = worker(case_root, {:failure, ending})

      report =
        failure_diagnostic(fn ->
          assert {:error, {:dispatched_or_unknown, "model_call_failed"}} =
                   ProviderBridge.complete(
                     fresh_request(),
                     configuration,
                     Model.discard_progress()
                   )

          assert File.read!(Path.join(case_root, "credential-size")) == "29"
          refute process_alive?(child_pid(case_root))
          refute File.exists?(File.read!(Path.join(case_root, "namespace")))
        end)

      assert report["counts"]["terminal_unknown"] >= 1
      assert report["cleanup_confirmed"] and report["healthy"]
      refute report["incomplete"]

      if ending == :clean do
        assert report["failure"] == %{"stage" => "stream", "class" => "stream_transport_timeout"}
      else
        assert report["failure"] == nil
        assert report["counts"]["fail"] >= 1
      end
    end
  end

  test "the original deadline discards a terminal whose channel remains open", %{root: root} do
    configuration = worker(root, {:failure, :withheld_eof})

    report =
      failure_diagnostic(fn ->
        assert {:error, {:dispatched_or_unknown, "model_call_failed"}} =
                 ProviderBridge.complete(fresh_request(), configuration, Model.discard_progress())

        refute process_alive?(child_pid(root))
        refute File.exists?(File.read!(Path.join(root, "namespace")))
      end)

    assert report["counts"]["terminal_unknown"] >= 1
    assert report["counts"]["fail"] >= 1
    assert report["failure"] == nil
    assert report["cleanup_confirmed"] and report["healthy"]
    refute report["incomplete"]
  end

  test "caller loss stops the EOF receiver and discards its provisional failure", %{root: root} do
    configuration = worker(root, {:failure, :withheld_eof})

    report =
      failure_diagnostic(fn ->
        {caller, guardian, stop_reference} = registered_call(fresh_request(), configuration)
        send(caller, :continue)
        assert eventually(fn -> is_pid(eof_receiver(guardian)) end, 5_000)
        receiver = eof_receiver(guardian)
        receiver_monitor = Process.monitor(receiver)
        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^receiver_monitor, :process, ^receiver, :killed}, 2_500
        assert eventually(fn -> not process_alive?(child_pid(root)) end, 2_500)
        refute File.exists?(File.read!(Path.join(root, "namespace")))
        # Cleanup ends the child; the managed retainer still owns the guardian.
        assert Process.alive?(guardian)
        stop_registered(guardian, stop_reference)
      end)

    assert report["counts"]["terminal_unknown"] >= 1
    assert report["failure"] == nil
    assert report["cleanup_confirmed"] and report["healthy"]
    refute report["incomplete"]
  end

  test "version-one readiness is refused before the credential is sent", %{root: root} do
    assert {:error, {:not_dispatched, "model_call_failed"}} =
             ProviderBridge.complete(
               fresh_request(),
               worker(root, :old_ready),
               Model.discard_progress()
             )

    assert File.regular?(Path.join(root, "ready"))
    refute File.exists?(Path.join(root, "credential-size"))
    refute process_alive?(child_pid(root))
    refute File.exists?(File.read!(Path.join(root, "namespace")))
  end

  test "queued EOF after the original deadline cannot publish a failure category", %{root: root} do
    configuration = worker(root, {:failure, :release_eof})
    request = fresh_request()

    report =
      failure_diagnostic(fn ->
        {caller, guardian, stop_reference} = registered_call(request, configuration)
        send(caller, :continue)
        assert eventually(fn -> is_pid(eof_receiver(guardian)) end, 5_000)
        receiver = eof_receiver(guardian)
        assert :erlang.suspend_process(guardian)

        try do
          File.write!(Path.join(root, "release-eof"), "release")

          assert eventually(
                   fn ->
                     {:messages, messages} = Process.info(guardian, :messages)

                     Enum.any?(
                       messages,
                       &match?({:provider_frame, ^receiver, {:error, :closed}}, &1)
                     )
                   end,
                   5_000
                 )

          assert eventually(
                   fn -> System.system_time(:millisecond) >= request.deadline end,
                   10_000
                 )
        after
          if Process.alive?(guardian), do: :erlang.resume_process(guardian)
        end

        assert_receive {:completed, {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                       1_000

        stop_registered(guardian, stop_reference)
        refute process_alive?(child_pid(root))
        refute File.exists?(File.read!(Path.join(root, "namespace")))
      end)

    assert report["counts"]["terminal_unknown"] >= 1
    assert report["counts"]["fail"] >= 1
    assert report["failure"] == nil
    assert report["cleanup_confirmed"] and report["healthy"]
    refute report["incomplete"]
  end

  defp failure_diagnostic(fun) do
    output =
      capture_io(fn ->
        assert catch_throw(
                 ProviderPhaseDiagnostic.capture(fn ->
                   fun.()
                   throw(:bounded_failure_test_complete)
                 end)
               ) == :bounded_failure_test_complete
      end)

    output
    |> String.trim()
    |> String.replace_prefix("provider phase diagnostic ", "")
    |> Jason.decode!()
  end

  defp fresh_request do
    {:ok, request} =
      Model.request("fixture:model", [%{"role" => "user", "content" => "hello"}],
        sampling: %{"max_tokens" => 4},
        deadline: System.system_time(:millisecond) + 10_000
      )

    request
  end

  defp eof_receiver(guardian) do
    case Process.info(guardian, :links) do
      {:links, links} ->
        Enum.find(links, fn pid ->
          is_pid(pid) and
            case Process.info(pid, :current_stacktrace) do
              {:current_stacktrace, frames} ->
                Enum.any?(frames, fn
                  {ProviderBridge, :receive_eof, 2, _location} -> true
                  _frame -> false
                end)

              nil ->
                false
            end
        end)

      nil ->
        nil
    end
  end

  test "a blocked progress consumer cannot queue data or delay cleanup", %{
    root: root,
    request: request
  } do
    configuration = worker(root, :progress)
    parent = self()

    retainer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    caller =
      spawn(fn ->
        result =
          ProviderLifetime.scoped(
            fn guardian, stop_reference ->
              send(parent, {:registered, guardian, stop_reference})
              {:managed, retainer, 2_000}
            end,
            fn ->
              ProviderBridge.complete(request, configuration, fn _delta ->
                send(parent, :progress_blocked)

                receive do
                  :release -> :ok
                end
              end)
            end
          )

        send(parent, {:completed, result})
      end)

    assert_receive {:registered, guardian, stop_reference}, 1_000
    assert_receive :progress_blocked, 5_000

    # Concept: cleanup must not depend on releasing the blocked consumer, but
    # this success assertion starts only after the host admits the real result.
    # Technical depth: the child's send/close marker does not fence the host's
    # one-frame receiver. Observe the actual result queued behind the callback
    # before requesting stop; otherwise cancellation may correctly win first.
    assert eventually(
             fn ->
               {:messages, messages} = Process.info(caller, :messages)

               File.regular?(Path.join(root, "terminal")) and
                 Enum.any?(messages, fn
                   {:provider_result, _reference, ^guardian, {:ok, %{delta_count: 10_000}}} ->
                     true

                   _other ->
                     false
                 end)
             end,
             5_000
           )

    assert {:message_queue_len, pending} = Process.info(caller, :message_queue_len)
    assert pending <= 2
    stop = make_ref()
    until = System.monotonic_time(:millisecond) + 2_000

    send(
      guardian,
      {:loopex_provider_resource_stop, stop_reference, stop, self(), until, until + 100}
    )

    assert_receive {:loopex_provider_resource_stopped, ^stop, ^guardian}, 2_000
    send(caller, :release)
    assert_receive {:completed, {:ok, %{delta_count: 10_000}}}, 1_000
    refute process_alive?(child_pid(root))
    send(retainer, :stop)
  end

  test "the writer accepts a committed uint64 deadline without a socket timer overflow", %{
    root: root,
    request: request
  } do
    {:ok, long_request} =
      Model.request(request.model, request.messages,
        sampling: request.sampling,
        deadline: 18_446_744_073_709_551_615
      )

    assert {:ok, reply} =
             ProviderBridge.complete(long_request, worker(root, :reply), Model.discard_progress())

    assert reply.canonical_request_bytes == long_request.canonical_request_bytes
    refute process_alive?(child_pid(root))
  end

  test "an echoed credential is rejected inside the raw receiver", %{root: root, request: request} do
    configuration = worker(root, :echo_credential)
    {caller, guardian, stop_reference} = registered_call(request, configuration)
    :erlang.trace(guardian, true, [:receive, {:tracer, self()}])
    send(caller, :continue)

    assert_receive {:completed, {:error, {:dispatched_or_unknown, "model_call_failed"}}}, 5_000

    assert_receive {:trace, ^guardian, :receive,
                    {:provider_frame, _receiver, {:error, :invalid_frame}}},
                   1_000

    trace_fence(guardian)
    {:messages, messages} = Process.info(self(), :messages)
    canary = System.fetch_env!("LOOPEX_PROVIDER_API_KEY")

    assert Enum.all?(messages, fn
             {:trace, ^guardian, :receive, message} ->
               :binary.match(:erlang.term_to_binary(message), canary) == :nomatch

             _other ->
               true
           end)

    :erlang.trace(guardian, false, [:receive])
    stop_registered(guardian, stop_reference)
    refute process_alive?(child_pid(root))
  end

  test "abrupt guardian death also stops its raw host helpers", %{root: root, request: request} do
    {caller, guardian, _stop_reference} = registered_call(request, worker(root, :stall_ready))
    :erlang.trace(guardian, true, [:procs, {:tracer, self()}])
    send(caller, :continue)
    assert eventually(fn -> File.regular?(Path.join(root, "booted")) end, 5_000)
    helpers = traced_children(guardian)
    assert length(helpers) >= 2
    monitors = Enum.map(helpers, &{&1, Process.monitor(&1)})
    guardian_monitor = Process.monitor(guardian)
    Process.exit(guardian, :kill)
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :killed}, 1_000

    for {helper, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^helper, _reason}, 1_000
    end

    assert_receive {:completed, {:error, {:dispatched_or_unknown, "model_call_failed"}}}, 1_000
    assert eventually(fn -> not process_alive?(child_pid(root)) end, 2_500)
    refute File.exists?(File.read!(Path.join(root, "namespace")))
  end

  test "the committed deadline kills a writer blocked by a child that never reads", %{
    root: root,
    request: request
  } do
    System.put_env("LOOPEX_PROVIDER_API_KEY", String.duplicate("w", 65_536))
    deadline = System.system_time(:millisecond) + 5_000

    {:ok, bounded_request} =
      Model.request(request.model, request.messages,
        sampling: request.sampling,
        deadline: deadline
      )

    {caller, guardian, stop_reference} =
      registered_call(bounded_request, worker(root, :stall_writes))

    :erlang.trace(guardian, true, [:procs, {:tracer, self()}])
    send(caller, :continue)
    assert eventually(fn -> File.regular?(Path.join(root, "booted")) end, 2_000)
    bootstrap_helpers = traced_children(guardian)
    {:links, links} = Process.info(guardian, :links)
    sockets = Enum.filter(links, &data_socket?/1)
    assert [socket] = sockets
    assert {:ok, [send_timeout: :infinity]} = :inet.getopts(socket, [:send_timeout])
    assert :ok = :inet.setopts(socket, sndbuf: 1_024)
    File.write!(Path.join(root, "release-ready"), "ready")
    assert eventually(fn -> File.regular?(Path.join(root, "ready")) end, 1_000)

    assert eventually(
             fn ->
               case Enum.filter(traced_children(guardian) -- bootstrap_helpers, &Process.alive?/1) do
                 [writer] -> blocked_in_codec_send?(writer)
                 _not_one_writer -> false
               end
             end,
             1_000
           )

    [writer] = Enum.filter(traced_children(guardian) -- bootstrap_helpers, &Process.alive?/1)
    monitor = Process.monitor(writer)
    until = max(deadline - System.system_time(:millisecond), 0) + 1_000
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}, until
    assert_receive {:completed, {:error, {:dispatched_or_unknown, "model_call_failed"}}}, 1_000
    stop_registered(guardian, stop_reference)
    refute process_alive?(child_pid(root))
    refute File.exists?(Path.join(root, "credential-size"))
  end

  defp registered_call(request, configuration) do
    parent = self()

    caller =
      spawn(fn ->
        result =
          ProviderLifetime.scoped(
            fn guardian, stop_reference ->
              send(parent, {:registered, guardian, stop_reference})

              receive do
                :continue -> {:managed, parent, 2_000}
              end
            end,
            fn -> ProviderBridge.complete(request, configuration, Model.discard_progress()) end
          )

        send(parent, {:completed, result})
      end)

    assert_receive {:registered, guardian, stop_reference}, 1_000
    {caller, guardian, stop_reference}
  end

  # Concept: a spawned writer is not yet a blocked writer.
  # Technical depth: establish the actual send stack and waiting state together
  # inside the existing setup wait. Observing birth then sampling status races
  # the runnable process; waiting in an unrelated receive proves no backpressure.
  defp blocked_in_codec_send?(writer) do
    case Process.info(writer, [:status, :current_stacktrace]) do
      [status: :waiting, current_stacktrace: stack] ->
        Enum.any?(stack, fn
          {Loopex.LLM.ReqLLM.ProviderCodec, :send, 3, _location} -> true
          _other_frame -> false
        end)

      _not_blocked_in_send ->
        false
    end
  end

  defp stop_registered(guardian, stop_reference) do
    monitor = Process.monitor(guardian)
    stop = make_ref()
    until = System.monotonic_time(:millisecond) + 2_000

    send(
      guardian,
      {:loopex_provider_resource_stop, stop_reference, stop, self(), until, until + 100}
    )

    assert_receive {:loopex_provider_resource_stopped, ^stop, ^guardian}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500
  end

  defp trace_fence(guardian) do
    reference = :erlang.trace_delivered(guardian)
    assert_receive {:trace_delivered, ^guardian, ^reference}, 1_000
  end

  defp traced_children(guardian) do
    trace_fence(guardian)
    {:messages, messages} = Process.info(self(), :messages)
    for {:trace, ^guardian, :spawn, child, _entry} <- messages, do: child
  end

  defp data_socket?(port) when is_port(port) do
    match?({:ok, [_option]}, :inet.getopts(port, [:send_timeout]))
  catch
    _kind, _reason -> false
  end

  defp data_socket?(_process), do: false

  defp worker(root, mode) do
    source = """
    alias Loopex.LLM.ReqLLM.ProviderCodec
    [path, nonce, manifest, deadline] = Enum.map(arguments, &List.to_string/1)
    root = #{inspect(root)}
    mode = #{inspect(mode)}
    File.write!(Path.join(root, "pid"), System.pid())
    File.write!(Path.join(root, "namespace"), Path.dirname(path))
    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 5_000)
    {:ok, :bootstrap, bootstrap} = ProviderCodec.recv(socket, 5_000)
    true = bootstrap == %{"nonce" => nonce, "version" => 2, "build_manifest_sha256" => manifest}
    File.write!(Path.join(root, "booted"), "ready")
    if mode == :stall_ready, do: Process.sleep(:infinity)
    if mode == :stall_writes do
      :ok = :inet.setopts(socket, recbuf: 1_024)
      Stream.repeatedly(fn -> File.exists?(Path.join(root, "release-ready")) end)
      |> Enum.reduce_while(:waiting, fn ready, _ ->
        if ready, do: {:halt, :ready}, else: (Process.sleep(10); {:cont, :waiting})
      end)
    end
    ready = case mode do
      {:wrong_ready, field} -> Map.put(bootstrap, field, String.duplicate("0", 64))
      _ -> bootstrap
    end
    if mode == :old_ready do
      {:ok, <<"LP", 2, rest::binary>>} = ProviderCodec.encode(:ready, ready)
      :ok = :gen_tcp.send(socket, <<"LP", 1, rest::binary>>)
    else
      :ok = ProviderCodec.send(socket, :ready, ready)
    end
    File.write!(Path.join(root, "ready"), "ready")
    if mode == :stall_writes, do: Process.sleep(:infinity)
    case ProviderCodec.recv(socket, 5_000) do
      {:ok, :credential, %{"nonce" => ^nonce, "credential" => key}} ->
        File.write!(Path.join(root, "credential-size"), Integer.to_string(byte_size(key)))
        IO.puts(key)
        IO.puts(:stderr, key)
        {:ok, :invocation, invocation} = ProviderCodec.recv(socket, 5_000)
        true = invocation["request"].deadline == String.to_integer(deadline)
        binding = %{"nonce" => nonce, "staged_request_digest" => invocation["staged_request_digest"]}
        dispatch = case mode do
          {:wrong_binding, :dispatch, field} -> Map.put(binding, field, String.duplicate("0", 64))
          _ -> binding
        end
        :ok = ProviderCodec.send(socket, :dispatch_started, dispatch)
        if match?({:wrong_binding, :dispatch, _}, mode), do: Process.sleep(:infinity)
        if mode == :echo_credential do
          :ok = ProviderCodec.send(socket, :credential, %{"nonce" => nonce, "credential" => key})
          Process.sleep(:infinity)
        end
        if mode == :progress do
          delta = Map.put(binding, "payload", %{kind: :text_delta, content_index: 0, text: "x"})
          Enum.each(1..10_000, fn _ -> :ok = ProviderCodec.send(socket, :delta, delta) end)
        end
        reply = %{
          text: "answer", identity: %{"provider" => "fixture", "model" => "fixture:model"},
          usage: %{input_tokens: 7, output_tokens: 2}, tool_calls: [], streamed: true,
          delta_count: 10_000, canonical_request_bytes: invocation["canonical_request_bytes"],
          staged_request_digest: invocation["staged_request_digest"]
        }
        terminal = if mode == :unreadable,
          do: Map.put(binding, "status", "unreadable"),
          else: Map.merge(binding, %{"status" => "reply", "reply" => reply})
        terminal = case mode do
          {:wrong_binding, :terminal, field} -> Map.put(terminal, field, String.duplicate("0", 64))
          {:failure, _ending} -> Map.merge(binding, %{
            "status" => "dispatched_or_unknown",
            "failure" => %{"stage" => "stream", "class" => "stream_transport_timeout"}
          })
          _ -> terminal
        end
        :ok = ProviderCodec.send(socket, :terminal, terminal)
        if mode == :duplicate, do: ProviderCodec.send(socket, :terminal, terminal)
        case mode do
          {:failure, :duplicate} -> ProviderCodec.send(socket, :terminal, terminal)
          {:failure, :extra_frame} -> ProviderCodec.send(socket, :dispatch_started, binding)
          {:failure, :partial_frame} -> :gen_tcp.send(socket, "L")
          {:failure, :malformed} -> :gen_tcp.send(socket, <<0, 255, 42>>)
          {:failure, :withheld_eof} -> Process.sleep(:infinity)
          {:failure, :release_eof} ->
            Stream.repeatedly(fn -> File.exists?(Path.join(root, "release-eof")) end)
            |> Enum.reduce_while(:waiting, fn ready, _ ->
              if ready, do: {:halt, :ready}, else: (Process.sleep(10); {:cont, :waiting})
            end)
          _ -> :ok
        end
        :gen_tcp.close(socket)
        File.write!(Path.join(root, "terminal"), "closed")
        Process.sleep(:infinity)
      {:error, :closed} -> :ok
    end
    """

    # Only the running test VM's admitted code paths are copied into this local
    # fixture; no application other than Elixir starts in its child VM.
    paths = :io_lib.format(~c"~tp", [:code.get_path()]) |> IO.iodata_to_binary()
    script = Path.join(root, "worker.escript")

    File.write!(script, """
    #!/usr/bin/env escript
    %%! +S 2:2 +A 2
    main(Arguments) ->
      true = code:add_paths(#{paths}) =:= ok,
      {ok, _} = application:ensure_all_started(elixir),
      'Elixir.Code':eval_string(base64:decode("#{Base.encode64(source)}"), [{arguments, Arguments}]),
      ok.
    """)

    {:ok, digest} = ProviderConfiguration.file_digest(script)

    %{
      worker_path: script,
      interpreter_path: System.find_executable("escript"),
      worker_sha256: digest,
      build_manifest_sha256: String.duplicate("d", 64),
      cleanup_grace_ms: 2_000
    }
  end

  defp child_pid(root), do: root |> Path.join("pid") |> File.read!() |> String.to_integer()

  defp process_alive?(pid) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "stat="]) do
      {state, 0} -> not String.starts_with?(String.trim(state), "Z")
      {_output, 1} -> false
      other -> flunk("process observation unavailable: #{inspect(other)}")
    end
  end

  defp eventually(fun, timeout) do
    until = System.monotonic_time(:millisecond) + timeout
    await(fun, until)
  end

  defp await(fun, until) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= until ->
        false

      true ->
        receive do
        after
          10 -> await(fun, until)
        end
    end
  end
end
