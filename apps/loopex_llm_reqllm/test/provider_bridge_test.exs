defmodule Loopex.LLM.ReqLLM.ProviderBridgeTest do
  use ExUnit.Case, async: false

  alias Loopex.Model
  alias Loopex.Runtime.ProviderLifetime
  alias Loopex.LLM.ReqLLM.{ProviderBridge, ProviderConfiguration}

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
    assert eventually(fn -> File.regular?(Path.join(root, "terminal")) end, 5_000)
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
    true = bootstrap == %{"nonce" => nonce, "version" => 1, "build_manifest_sha256" => manifest}
    if mode == :stall_ready, do: Process.sleep(:infinity)
    :ok = ProviderCodec.send(socket, :ready, bootstrap)
    case ProviderCodec.recv(socket, 5_000) do
      {:ok, :credential, %{"nonce" => ^nonce, "credential" => key}} ->
        File.write!(Path.join(root, "credential-size"), Integer.to_string(byte_size(key)))
        IO.puts(key)
        IO.puts(:stderr, key)
        {:ok, :invocation, invocation} = ProviderCodec.recv(socket, 5_000)
        true = invocation["request"].deadline == String.to_integer(deadline)
        binding = %{"nonce" => nonce, "staged_request_digest" => invocation["staged_request_digest"]}
        :ok = ProviderCodec.send(socket, :dispatch_started, binding)
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
        :ok = ProviderCodec.send(socket, :terminal, terminal)
        if mode == :duplicate, do: ProviderCodec.send(socket, :terminal, terminal)
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
