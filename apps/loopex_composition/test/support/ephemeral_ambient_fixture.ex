defmodule LoopexComposition.Ephemeral.AmbientFixture do
  @moduledoc """
  ## Concept

  Prove hosted provider-only credential exclusion and the admitted tool
  disclosure boundary in a separate VM.

  ## Technical depth

  The child trusts only a generated localhost CA and uses a distinct synthetic
  value for each hosted provider. One case starts a named trace before creating
  the session, arms the exact hosted caller while it is blocked before exclusion,
  and holds its TLS call while inspecting trace membership, owner, coordinator
  and Store. It then inspects their settled state and planes.
  The other drives two TLS calls around a host-authorized read tool effect;
  its policy deliberately copies the ambient value to a workspace file.
  The buffered-thinking mode admits verified and private native thinking over
  TLS and inspects only canonical public results and history after settlement.
  The fixture reports no credential or request bytes to the parent.
  """

  import ExUnit.Assertions
  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, Preflight, SessionOwner}

  @credential "synthetic-ambient-boundary-value"
  @provider_profiles %{
    openai: %{
      provider: :openai,
      model: "openai:gpt-4",
      key_name: "OPENAI_API_KEY",
      credential: "synthetic-openai-provider-only-value"
    },
    anthropic: %{
      provider: :anthropic,
      model: "anthropic:claude-haiku-4-5",
      key_name: "ANTHROPIC_API_KEY",
      credential: "synthetic-anthropic-provider-only-value"
    },
    openrouter: %{
      provider: :openrouter,
      model: "openrouter:openai/gpt-4o-mini",
      key_name: "OPENROUTER_API_KEY",
      credential: "synthetic-openrouter-provider-only-value"
    }
  }

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request) do
      workspace = System.fetch_env!("LOOPEX_TEST_AMBIENT_WORKSPACE")
      File.write!(Path.join(workspace, "ambient.txt"), System.fetch_env!("OPENAI_API_KEY"))
      {:allow, nil}
    end
  end

  def run_in_child(mode \\ :disclosure, provider \\ :openai)
      when mode in [:disclosure, :provider_only, :buffered_thinking] and
             provider in [:openai, :anthropic, :openrouter] do
    System.cmd(
      System.find_executable("elixir"),
      [
        "-pa",
        Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]),
        "-r",
        __ENV__.file,
        "-e",
        "LoopexComposition.Ephemeral.AmbientFixture.probe(#{inspect(mode)}, #{inspect(provider)})"
      ],
      stderr_to_stdout: true
    )
  end

  def probe(mode, provider)
      when mode in [:disclosure, :provider_only, :buffered_thinking] and
             provider in [:openai, :anthropic, :openrouter] do
    {:ok, _} = Application.ensure_all_started(:loopex_composition)
    {:ok, _} = Application.ensure_all_started(:ssl)
    certificate = certificate()

    directory =
      Path.join(System.tmp_dir!(), "loopex-ambient-#{System.unique_integer([:positive])}")

    workspace = Path.join(directory, "workspace")
    File.mkdir_p!(workspace)

    try do
      pem =
        :public_key.pem_encode(
          Enum.map(certificate[:cacerts], &{:Certificate, &1, :not_encrypted})
        )

      ca_path = Path.join(directory, "ca.pem")
      File.write!(ca_path, pem)
      :ok = :public_key.cacerts_load(String.to_charlist(ca_path))

      profile =
        if mode == :disclosure,
          do: %{provider: :openai, credential: @credential, key_name: "OPENAI_API_KEY"},
          else: Map.fetch!(@provider_profiles, provider)

      for name <- [
            "LOOPEX_PROVIDER_API_KEY",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "OPENROUTER_API_KEY",
            "OPEN_ROUTER_API_KEY"
          ],
          do: System.delete_env(name)

      System.put_env(profile.key_name, profile.credential)
      System.put_env("LOOPEX_TEST_AMBIENT_WORKSPACE", workspace)

      case mode do
        :disclosure ->
          disclosure_case(certificate, workspace)

        :provider_only ->
          provider_only_case(certificate, workspace, profile)

        :buffered_thinking ->
          buffered_thinking_cases(certificate, workspace)
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp disclosure_case(certificate, workspace) do
    {port, server} = start_server(certificate)

    assert {:error, {:run, :failed, %{details: %{"reason" => "model_call_failed"}}}} =
             Ephemeral.run("Read ambient.txt, then answer.",
               policy: Policy,
               model: "openai:gpt-4",
               base_url: "https://localhost:#{port}",
               cwd: workspace,
               tools: :coding,
               max_tokens: 128,
               max_steps: 3,
               timeout: 20_000
             )

    assert_receive {:ambient_model_request, ^server, first, true}, 3_000
    assert_receive {:ambient_model_request, ^server, second, true}, 3_000
    refute String.contains?(first, @credential)
    assert String.contains?(second, @credential)
    assert_receive {:ambient_server_done, ^server}, 3_000
    IO.puts("EPHEMERAL_AMBIENT_DISCLOSURE_PASSED")
  end

  defp provider_only_case(certificate, workspace, profile) do
    {port, server} =
      start_server(
        certificate,
        [provider_answer_reply(profile, "provider-only answer")],
        true,
        expected_auth(profile)
      )

    assert {:ok, configuration} =
             Preflight.prepare(
               policy: Policy,
               model: profile.model,
               base_url: "https://localhost:#{port}",
               cwd: workspace,
               tools: :none,
               max_tokens: 128,
               timeout: 20_000
             )

    observer = self()
    probe_ref = make_ref()

    # Concept: inspect owner state without copying the selected credential into
    # the runtime's model options.
    # Technical depth: the existing test starter captures only a variable name,
    # observer and reference; the owner reads the canary inside its own process.
    probe = %{
      observer: observer,
      ref: probe_ref,
      variable: profile.key_name,
      inject_bad_state: false
    }

    runtime_start = fn options ->
      model = Keyword.fetch!(options, :model)
      true = model.module == LoopexComposition.Model
      true = Keyword.fetch!(model.options, :adapter) == Loopex.LLM.ReqLLM.InProcess

      options =
        options
        |> Keyword.put(:diagnostics_to, observer)
        |> Keyword.put(:model, %{
          model
          | options:
              Keyword.update!(model.options, :adapter_options, fn adapter_options ->
                Keyword.put(adapter_options, :cleanup_owner_test_probe, probe)
              end)
        })

      with {:ok, runtime} <-
             Loopex.Runtime.start_link(options),
           {:ok, %{level: :arguments, sink: :diagnostics}} <-
             Loopex.trace(runtime, %{
               modules: [
                 Loopex.Runtime.Control,
                 Loopex.LLM.ReqLLM.InProcess,
                 Loopex.LLM.ReqLLM.InProcess.Caller,
                 ReqLLM,
                 Req,
                 Finch.HTTP1.Pool,
                 Mint.HTTP1,
                 :ssl
               ],
               level: :arguments,
               sink: :diagnostics
             }) do
        {:ok, runtime}
      end
    end

    configuration =
      Map.put(configuration, :test_seams, %{runtime_holder: %{runtime_start: runtime_start}})

    supervisor = Process.whereis(LoopexComposition.Ephemeral.OwnerSupervisor)
    assert is_pid(supervisor)
    assert {:ok, activation} = OwnerActivation.start(supervisor)
    assert {:ok, cell} = OwnerActivation.begin(activation)
    owner = OwnerActivation.owner(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 16_000)
    session = {:loopex_ephemeral_session, owner, cell}

    try do
      startup = :sys.get_state(owner).startup
      runtime = startup.registered.runtime
      store = startup.registered.memory_store
      session_id = startup.session_id
      {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)
      coordinator = :sys.get_state(children.control).sessions[session_id].coordinator

      _control = Loopex.session_status(runtime, "trace-control-canary")
      capability = startup.registered.trace_capability
      :ok = :sys.suspend(capability)

      {ask, caller, trace_session} =
        try do
          ask = Task.async(fn -> Ephemeral.ask(session, "Answer without tools") end)
          caller = await_caller(owner, System.monotonic_time(:millisecond) + 5_000)
          assert is_pid(caller)

          assert :ok =
                   await_exclusion_request(
                     capability,
                     caller,
                     System.monotonic_time(:millisecond) + 5_000
                   )

          [trace_session] =
            Enum.filter(:trace.session_info(:all), fn
              {:loopex_trace, id} when is_integer(id) -> true
              _other -> false
            end)

          # Concept: exclusion must clear a trace actually armed on this caller.
          # Technical depth: the sensitive cleanup owner does not pass trace
          # flags to its child, so arm the exact blocked caller directly.
          assert 1 = :trace.process(trace_session, caller, true, [:call])
          assert {:flags, flags} = :trace.info(trace_session, caller, :flags)
          assert :call in flags

          assert {:traced, :local} =
                   :trace.info(
                     trace_session,
                     {Loopex.LLM.ReqLLM.InProcess.Caller, :run, 1},
                     :traced
                   )

          {ask, caller, trace_session}
        after
          :ok = :sys.resume(capability)
        end

      assert_receive {:ambient_model_request, ^server, request, true}, 5_000
      refute String.contains?(request, profile.credential)

      assert_receive {:cleanup_owner_canary, ^probe_ref, cleanup_owner, cleanup_start_ref,
                      :before_activation, before_match?},
                     5_000

      refute before_match?

      assert %{candidate: ^cleanup_owner, start_ref: ^cleanup_start_ref} =
               :sys.get_state(owner).model_census.pending

      control_state = :sys.get_state(children.control)
      tracer_state = :sys.get_state(children.tracer)

      exact_inventory = MapSet.new([{Loopex.LLM.ReqLLM.InProcess.Caller, :run, 1}])
      assert control_state.trace_excluded[caller].functions == exact_inventory

      assert MapSet.member?(tracer_state.excluded_pids, caller)
      assert tracer_state.excluded_mfas == exact_inventory

      assert {:flags, []} = :trace.info(trace_session, caller, :flags)

      assert {:traced, false} =
               :trace.info(
                 trace_session,
                 {Loopex.LLM.ReqLLM.InProcess.Caller, :run, 1},
                 :traced
               )

      assert :ok = await_trace_delivery(trace_session, caller)
      assert :ok = await_trace_delivery(trace_session, :all)
      :sys.get_state(children.tracer)
      :sys.get_state(children.dispatcher)
      before_reply = drain_diagnostics([])

      assert Enum.any?(before_reply, fn entry ->
               entry["kind"] == "trace_call" and
                 entry["module"] == "Loopex.LLM.ReqLLM.InProcess" and
                 entry["function"] == "complete" and entry["arity"] == 3 and
                 entry["pid"] != inspect(caller)
             end)

      assert Enum.any?(before_reply, fn entry ->
               entry["kind"] == "trace_call" and
                 entry["module"] == "Loopex.Runtime.Control" and
                 String.contains?(inspect(entry), "trace-control-canary")
             end)

      {:messages, raw_trace_messages} = Process.info(children.tracer, :messages)

      assert_no_provider_key(
        {raw_trace_messages, :sys.get_state(children.tracer)},
        profile.credential
      )

      assert_no_provider_key(
        {
          runtime,
          :sys.get_state(owner),
          :sys.get_state(startup.registered.runtime_holder),
          :sys.get_state(children.control),
          :sys.get_state(coordinator),
          :sys.get_state(store)
        },
        profile.credential
      )

      send(server, {:ambient_release, self()})

      assert {:ok, %{outcome: :completed, text: "provider-only answer"} = result} =
               Task.await(ask, 15_000)

      assert_owner_scan(probe_ref, cleanup_owner, cleanup_start_ref, :mapped_reply)

      assert {:ok, records} = Loopex.Store.Memory.load_records(store, session_id, 0, 1_000)
      assert {:ok, events} = Loopex.Store.Memory.load_events(store, session_id, 0, 1_000)
      assert {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
      assert {:ok, status} = Loopex.session_status(runtime, session_id)
      assert {:ok, history} = Ephemeral.history(session)

      assert records != [] and events != []

      assert_no_provider_key(
        {
          result,
          records,
          events,
          Loopex.snapshot(attachment),
          status,
          history,
          Ephemeral.last_result(session),
          :sys.get_state(owner),
          :sys.get_state(startup.registered.runtime_holder),
          :sys.get_state(children.control),
          :sys.get_state(coordinator),
          :sys.get_state(store)
        },
        profile.credential
      )

      assert_receive {:ambient_server_done, ^server}, 3_000
      assert :ok = await_trace_delivery(trace_session, caller)
      assert :ok = await_trace_delivery(trace_session, :all)
      :sys.get_state(children.tracer)
      :sys.get_state(children.dispatcher)
      assert :ok = Loopex.trace_stop(runtime)
      :sys.get_state(children.tracer)
      :sys.get_state(children.dispatcher)
      assert_no_provider_key({before_reply, drain_diagnostics([])}, profile.credential)
      assert :ok = Ephemeral.stop_session(session)
      assert_owner_scan(probe_ref, cleanup_owner, cleanup_start_ref, :cleanup)
      IO.puts("EPHEMERAL_PROVIDER_ONLY_EXCLUSION_PASSED provider=#{profile.provider}")
    after
      send(server, {:ambient_release, self()})
      if Process.alive?(owner), do: Ephemeral.stop_session(session)
    end
  end

  defp buffered_thinking_cases(certificate, workspace) do
    for {id, reasoning, thought} <- [
          {"claude-haiku-4-5-20251001", "low", "permitted buffered summary 猫"},
          {"claude-fable-5-1", "default", "private buffered thought 猫"}
        ] do
      answer = "canonical buffered answer é猫"
      signature = "buffered-private-signature+/="
      redacted = "buffered-private-redacted+/="

      body =
        Jason.encode!(%{
          "id" => "buffered-native-message",
          "type" => "message",
          "role" => "assistant",
          "model" => id,
          "content" => [
            %{"type" => "thinking", "thinking" => thought, "signature" => signature},
            %{"type" => "redacted_thinking", "data" => redacted},
            %{"type" => "text", "text" => answer}
          ],
          "stop_reason" => "end_turn",
          "stop_sequence" => nil,
          "usage" => %{"input_tokens" => 3, "output_tokens" => 5}
        })

      canaries = [thought, signature, redacted]
      for canary <- canaries, do: assert(String.contains?(body, canary))

      {port, server, server_monitor, listener} =
        start_server(certificate, [body], true, expected_auth(@provider_profiles.anthropic), true)

      buffered_cleanup(
        fn ->
          assert {:ok, session} =
                   Ephemeral.start_session(
                     policy: Policy,
                     model: "anthropic:" <> id,
                     reasoning: reasoning,
                     base_url: "https://localhost:#{port}",
                     cwd: workspace,
                     tools: :none,
                     max_tokens: 8192,
                     timeout: 20_000
                   )

          owner = elem(session, 1)
          owner_monitor = Process.monitor(owner)

          buffered_cleanup(
            fn -> buffered_thinking_session(session, server, id, reasoning, answer, canaries) end,
            [
              fn -> stop_buffered_session(session) end,
              fn -> join_buffered_actors([{owner_monitor, owner}]) end
            ]
          )
        end,
        [
          fn -> send(server, {:ambient_release, self()}) end,
          fn -> :ssl.close(listener) end,
          fn -> stop_buffered_actor(server) end,
          fn -> join_buffered_actors([{server_monitor, server}]) end
        ]
      )
    end

    IO.puts("EPHEMERAL_BUFFERED_THINKING_PRIVACY_PASSED")
  end

  defp buffered_thinking_session(session, server, id, reasoning, answer, canaries) do
    owner = elem(session, 1)
    startup = :sys.get_state(owner).startup

    session_monitors =
      startup.registered
      |> Map.values()
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()
      |> Enum.map(&{Process.monitor(&1), &1})

    buffered_cleanup(
      fn ->
        assert is_pid(startup.registered.runtime_supervisor)
        assert is_pid(startup.registered.private_supervisor)
        assert is_pid(startup.registered.runtime_holder)
        assert is_pid(startup.registered.memory_store)
        assert File.dir?(startup.owned_root.path)

        {:ok, children} =
          Loopex.Runtime.Supervisor.children(startup.registered.runtime.supervisor)

        model = :sys.get_state(children.control).model
        assert model.module == LoopexComposition.Model
        assert Keyword.fetch!(model.options, :adapter) == Loopex.LLM.ReqLLM.InProcess

        ask = Task.async(fn -> Ephemeral.ask(session, "Answer without exposing thinking") end)
        ask_monitor = Process.monitor(ask.pid)

        buffered_cleanup(
          fn ->
            assert_receive {:buffered_native_request, ^server, request_line, request, true}, 5_000
            pending = :sys.get_state(owner).model_census.pending

            model_pids = Map.values(pending.resources) ++ [pending.candidate, pending.callback]
            assert Enum.all?(model_pids, &(is_pid(&1) and Process.alive?(&1)))
            model_monitors = Enum.map(model_pids, &{Process.monitor(&1), &1})

            buffered_cleanup(
              fn ->
                assert length(Enum.uniq(model_pids)) == length(model_pids)
                assert Enum.all?(model_pids, &Process.alive?/1)

                assert Enum.sort(Map.keys(pending.resources)) ==
                         Enum.sort([
                           :root,
                           :anonymous_supervisor,
                           :pool_supervisor,
                           :http1_worker,
                           :caller
                         ])

                assert is_pid(pending.candidate) and is_pid(pending.callback)
                assert request_line == "POST /v1/messages HTTP/1.1"
                decoded = Jason.decode!(request)
                assert decoded["model"] == id
                assert decoded["max_tokens"] == 8192
                refute Map.has_key?(decoded, "stream")
                refute Map.has_key?(decoded, "output_config")

                if reasoning == "low" do
                  assert decoded["thinking"] == %{"type" => "enabled", "budget_tokens" => 1024}
                else
                  refute Map.has_key?(decoded, "thinking")
                end

                send(server, {:ambient_release, self()})
                assert {:ok, result} = returned = Task.await(ask, 15_000)

                for {_monitor, pid} <- model_monitors,
                    pid != pending.callback,
                    do: refute(Process.alive?(pid))

                assert result.outcome == :completed
                assert result.text == answer
                assert result.profile == :ephemeral
                assert result.text_truncated == false
                assert result.tools == [] and result.tools_truncated == false

                assert Enum.sort(Map.keys(result)) ==
                         Enum.sort([
                           :details,
                           :outcome,
                           :profile,
                           :run_id,
                           :session_id,
                           :shadowed_skills,
                           :text,
                           :text_truncated,
                           :tools,
                           :tools_truncated
                         ])

                assert result.details == %{"cleanup_grace_ms" => 5_000}
                assert Ephemeral.last_result(session) == returned

                assert {:ok, history} = Ephemeral.history(session)

                assert history == %{
                         entries: [
                           %{
                             role: :user,
                             text: "Answer without exposing thinking",
                             text_truncated: false
                           },
                           %{role: :assistant, text: answer, text_truncated: false}
                         ],
                         truncated: false
                       }

                public =
                  :erlang.term_to_binary({returned, Ephemeral.last_result(session), history})

                for canary <- canaries, do: refute(String.contains?(public, canary))
                assert_no_provider_key(public, @provider_profiles.anthropic.credential)
                assert :sys.get_state(owner).model_census.pending == nil
                assert_receive {:ambient_server_done, ^server}, 3_000
                refute_receive {:buffered_native_request, ^server, _, _, _}, 50
              end,
              [
                fn -> send(server, {:ambient_release, self()}) end,
                fn -> stop_buffered_session(session) end,
                fn -> join_buffered_actors(model_monitors) end
              ]
            )
          end,
          [
            fn -> send(server, {:ambient_release, self()}) end,
            fn -> stop_buffered_session(session) end,
            fn -> stop_buffered_actor(ask.pid) end,
            fn -> join_buffered_actors([{ask_monitor, ask.pid}]) end
          ]
        )
      end,
      [
        fn -> stop_buffered_session(session) end,
        fn -> join_buffered_actors(session_monitors) end,
        fn -> refute File.exists?(startup.owned_root.path) end
      ]
    )
  end

  # Concept: fixture cleanup cannot turn the first failed proof into another error.
  # Technical depth: run every release, stop and original-monitor join even when
  # an earlier stage raises; restore the first captured kind, reason and stack.
  defp buffered_cleanup(body, cleanup) do
    body_result = capture_buffered_step(body)
    cleanup_results = Enum.map(cleanup, &capture_buffered_step/1)
    results = [body_result | cleanup_results]

    case Enum.find(results, &match?({:error, _, _, _}, &1)) do
      {:error, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
      nil -> :ok
    end
  end

  defp capture_buffered_step(step) do
    try do
      {:ok, step.()}
    catch
      kind, reason -> {:error, kind, reason, __STACKTRACE__}
    end
  end

  defp stop_buffered_session(session) do
    if Process.alive?(elem(session, 1)), do: assert(:ok = Ephemeral.stop_session(session))
  end

  defp stop_buffered_actor(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  end

  defp join_buffered_actors(monitors) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    joins =
      Enum.map(monitors, fn {monitor, pid} ->
        fn ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 0)
          assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, remaining
          refute Process.alive?(pid)
        end
      end)

    buffered_cleanup(
      fn -> :ok end,
      joins ++ [fn -> assert System.monotonic_time(:millisecond) < deadline end]
    )
  end

  defp assert_owner_scan(probe_ref, cleanup_owner, cleanup_start_ref, phase) do
    assert_receive {:cleanup_owner_canary, ^probe_ref, ^cleanup_owner, ^cleanup_start_ref, ^phase,
                    matched?},
                   5_000

    refute matched?
  end

  defp assert_no_provider_key(value, credential) do
    assert :binary.match(:erlang.term_to_binary({:positive_control, credential}), credential) !=
             :nomatch

    assert :binary.match(:erlang.term_to_binary(value), credential) == :nomatch
  end

  defp drain_diagnostics(entries) do
    receive do
      {:loopex_diagnostic, entry} -> drain_diagnostics([entry | entries])
    after
      0 -> Enum.reverse(entries)
    end
  end

  defp await_caller(owner, deadline) do
    caller =
      case :sys.get_state(owner).model_census.pending do
        %{resources: %{caller: pid}} when is_pid(pid) -> pid
        _other -> nil
      end

    cond do
      is_pid(caller) ->
        caller

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(10)
        await_caller(owner, deadline)
    end
  end

  defp await_exclusion_request(capability, caller, deadline) do
    assert {:messages, messages} = Process.info(capability, :messages)

    queued? =
      Enum.any?(messages, fn
        {:"$gen_call", {^caller, _reference}, {:exclude, _incarnation, ^caller, _functions}} ->
          true

        _other ->
          false
      end)

    cond do
      queued? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("caller did not queue its trace exclusion")

      true ->
        Process.sleep(10)
        await_exclusion_request(capability, caller, deadline)
    end
  end

  defp await_trace_delivery(session, target) do
    reference = :trace.delivered(session, target)
    assert is_reference(reference)

    receive do
      {:trace_delivered, ^target, ^reference} -> :ok
    after
      5_000 -> flunk("trace delivery did not finish")
    end
  end

  defp certificate do
    :public_key.pkix_test_data(%{
      root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
      peer: [
        key: {:namedCurve, :secp256r1},
        digest: :sha256,
        extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
      ]
    })
  end

  defp start_server(
         certificate,
         bodies \\ [tool_reply(), answer_reply()],
         held \\ false,
         auth \\ {"authorization", "Bearer " <> @credential},
         observe_native \\ false
       ) do
    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        cert: certificate[:cert],
        key: certificate[:key]
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    parent = self()

    serve = fn ->
      for body <- bodies do
        {:ok, socket} = :ssl.transport_accept(listener, 10_000)
        {:ok, socket} = :ssl.handshake(socket, 10_000)
        {headers, request} = read_request(socket, <<>>)

        if observe_native do
          send(
            parent,
            {:buffered_native_request, self(), hd(String.split(headers, "\r\n")), request,
             selected_auth?(headers, auth)}
          )
        else
          send(parent, {:ambient_model_request, self(), request, selected_auth?(headers, auth)})
        end

        if held do
          receive do
            {:ambient_release, ^parent} -> :ok
          after
            10_000 -> raise "held provider request was not released"
          end
        end

        :ok =
          :ssl.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\nconnection: close\r\n\r\n",
            body
          ])

        :ssl.close(socket)
      end

      :ssl.close(listener)
      send(parent, {:ambient_server_done, self()})
    end

    if observe_native do
      {server, monitor} = spawn_monitor(serve)
      {port, server, monitor, listener}
    else
      {port, spawn(serve)}
    end
  end

  defp tool_reply do
    Jason.encode!(%{
      "id" => "first",
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call-ambient",
                "type" => "function",
                "function" => %{
                  "name" => "read",
                  "arguments" => Jason.encode!(%{"path" => "ambient.txt"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
    })
  end

  defp answer_reply(content \\ @credential) do
    Jason.encode!(%{
      "id" => "second",
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
    })
  end

  defp provider_answer_reply(%{provider: :anthropic}, content) do
    Jason.encode!(%{
      "id" => "msg-provider-only",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5-20251001",
      "content" => [%{"type" => "text", "text" => content}],
      "stop_reason" => "end_turn",
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
    })
  end

  defp provider_answer_reply(_profile, content), do: answer_reply(content)

  defp expected_auth(%{provider: :anthropic, credential: credential}),
    do: {"x-api-key", credential}

  defp expected_auth(%{credential: credential}),
    do: {"authorization", "Bearer " <> credential}

  defp selected_auth?(headers, {expected_name, expected_value}) do
    Enum.any?(String.split(headers, "\r\n"), fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          String.downcase(name) == expected_name and String.trim(value) == expected_value

        _ ->
          false
      end
    end)
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        length =
          headers
          |> String.split("\r\n")
          |> Enum.find_value(fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length",
                  do: String.to_integer(String.trim(value))

              _ ->
                nil
            end
          end)

        if byte_size(body) >= length,
          do: {headers, binary_part(body, 0, length)},
          else: read_request(socket, receive_bytes(socket, bytes))

      _ ->
        read_request(socket, receive_bytes(socket, bytes))
    end
  end

  defp receive_bytes(socket, bytes) do
    {:ok, more} = :ssl.recv(socket, 0, 10_000)
    bytes <> more
  end
end
