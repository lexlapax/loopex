Code.require_file("support/provider_isolation_fixture.exs", __DIR__)
Code.require_file("support/provider_phase_diagnostic.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.CredentialPlaneTest do
  @moduledoc """
  ## Concept

  Credentials and raw provider diagnostics remain inside one protected child.
  Protection follows its retaining owner, while host diagnostics stay usable.

  ## Technical depth

  These 24 cases preserve the former credential-plane corpus's operational
  claims at ADR 0019's actual Adapter → Worker → ReqLLM boundary. ADR 0019 retires
  the parent-global registry, filter, epochs, shared group-leader changes and
  node-global poison state. It also replaces retained/redacted raw diagnostics
  with bounded non-secret status; placeholder counts are no longer the contract.
  C01–C24 identify the original cases one-to-one. Explicit-value scrub_error/2
  utility tests remain separate. Synthetic process fixtures are not package or
  live-provider evidence. Truthful operational names replace unlocked historical
  mechanism names; the C01–C24 preservation map retains every original name.
  """

  # C04 deliberately restarts the named ReqLLM supervisor, so this module
  # remains serial even though every credential is now fixture-local.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  require Logger

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture

  alias Loopex.LLM.ReqLLM.{
    CredentialCustody,
    CredentialRegistry,
    ProviderBridge,
    ProviderCodec,
    ProviderPhaseDiagnostic
  }

  alias Loopex.Model

  @sentinel "sk-loopex-credential-plane-sentinel-2f9c41"
  @failed {:error, {:dispatched_or_unknown, "model_call_failed"}}
  @refused {:error, {:not_dispatched, "model_call_failed"}}

  setup do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    :ok
  end

  test "actual companion seals a finite local failure without changing the public result" do
    fixture = Fixture.new(:credential_raise)

    output =
      capture_io(fn ->
        assert catch_throw(
                 ProviderPhaseDiagnostic.capture(fn ->
                   assert Fixture.complete(fixture) == @failed
                   throw(:retain_failure_diagnostic)
                 end)
               ) == :retain_failure_diagnostic
      end)

    report =
      output
      |> String.trim()
      |> String.replace_prefix("provider phase diagnostic ", "")
      |> Jason.decode!()

    # The request adapter raises while stream_text is opening the stream; its
    # unsuccessful return is observed at handoff, before a stream is available.
    assert report["failure"] == %{"stage" => "handoff", "class" => "returned_error"}
    assert report["healthy"] and report["cleanup_confirmed"]
    refute report["incomplete"]
    assert report["counts"]["terminal_unknown"] >= 1
    assert report["counts"]["cleanup_proved"] == 1
    refute output =~ @sentinel
    refute output =~ "req_llm_transport_raised_after_handoff"
    assert probe(fixture, "credential-probe")["key_present"]
    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.count(fixture) == 0
    Fixture.assert_gone(fixture)
    assert_fixture_files_private(fixture, [@sentinel])
  end

  test "actual version two companion refuses version one bootstrap before readiness or credential" do
    fixture = Fixture.new()
    path = Path.join(System.tmp_dir!(), "v1-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ifaddr: {:local, path}])

    File.chmod!(path, 0o600)
    nonce = String.duplicate("a", 64)
    digest = fixture.options[:build_manifest_sha256]
    deadline = System.system_time(:millisecond) + 10_000

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    {owner, reference, monitor} = start_version_probe(fixture, path, nonce, digest, deadline)

    {:ok, socket} = :gen_tcp.accept(listener, max(deadline - System.system_time(:millisecond), 0))
    on_exit(fn -> :gen_tcp.close(socket) end)
    payload = %{"nonce" => nonce, "version" => 2, "build_manifest_sha256" => digest}
    assert {:ok, frame} = ProviderCodec.encode(:bootstrap, payload)
    assert {:ok, :bootstrap, ^payload} = ProviderCodec.decode(frame)
    <<"LP", 2, rest::binary>> = frame
    :ok = :gen_tcp.send(socket, <<"LP", 1, rest::binary>>)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
    assert_receive {^reference, :result, 70, false, :clean}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
    assert Fixture.methods(fixture) == []
    assert Fixture.count(fixture) == 0
    refute File.read!(Fixture.marker(fixture, "entry-env")) =~ Adapter.credential_variable()
    assert Fixture.eventually(fn -> not Fixture.alive?(Fixture.pid(fixture)) end, 2_500)
  end

  # Concept: a separate owner keeps the real companion attached if the test dies.
  # Technical depth: caller DOWN and explicit teardown share bounded termination.
  # Only an attached child is signaled; its exit status proves cessation. The
  # environment is closed before entry, including ambient keys and crash dumps.
  defp start_version_probe(fixture, path, nonce, digest, deadline) do
    caller = self()
    reference = make_ref()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        caller_monitor = Process.monitor(caller)

        receive do
          {^reference, :start} ->
            version_probe_owner(
              fixture,
              path,
              nonce,
              digest,
              deadline,
              caller,
              caller_monitor,
              reference
            )

          {:DOWN, ^caller_monitor, :process, ^caller, _} ->
            :ok
        end
      end)

    monitor = Process.monitor(owner)

    on_exit(fn ->
      cleanup_monitor = Process.monitor(owner)
      send(owner, {reference, :stop})
      assert_receive {:DOWN, ^cleanup_monitor, :process, ^owner, _}, 5_000
    end)

    send(owner, {reference, :start})
    {owner, reference, monitor}
  end

  defp version_probe_owner(
         fixture,
         path,
         nonce,
         digest,
         deadline,
         caller,
         caller_monitor,
         reference
       ) do
    environment =
      Loopex.LLM.ReqLLM.ProviderLauncher.spawn_environment()
      |> Map.new()
      |> Map.merge(
        Map.new(
          %{
            "HOME" => fixture.root,
            "TMPDIR" => fixture.root,
            "LANG" => "C.UTF-8",
            "LC_ALL" => "C.UTF-8",
            "ERL_CRASH_DUMP" => "/dev/null",
            "ERL_CRASH_DUMP_SECONDS" => "0"
          },
          fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end
        )
      )
      |> Map.to_list()

    executable = Path.join(List.to_string(:code.root_dir()), "bin/escript")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        cd: fixture.root,
        env: environment,
        args: [
          "-c",
          "exec \"$@\" </dev/null",
          "version-probe",
          executable,
          fixture.options[:worker_path],
          path,
          nonce,
          digest,
          Integer.to_string(deadline)
        ]
      ])

    result = version_probe_result(port, false, caller_monitor, reference, deadline)

    case result do
      {:exited, status, output} ->
        send(caller, {reference, :result, status, output, :clean})

      _ ->
        cleanup = stop_version_probe(port)
        send(caller, {reference, :result, :interrupted, false, cleanup})
    end
  end

  defp version_probe_result(port, output, caller_monitor, reference, deadline) do
    receive do
      {^port, {:data, _raw}} ->
        version_probe_result(port, true, caller_monitor, reference, deadline)

      {^port, {:exit_status, status}} ->
        {:exited, status, output}

      {:DOWN, ^caller_monitor, :process, _, _} ->
        :caller_down

      {^reference, :stop} ->
        :stopped
    after
      max(deadline - System.system_time(:millisecond), 0) -> :deadline
    end
  end

  defp stop_version_probe(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

        receive do
          {^port, {:exit_status, _}} -> :clean
        after
          2_000 -> :cleanup_unavailable
        end

      nil ->
        receive do
          {^port, {:exit_status, _}} -> :clean
        after
          0 -> :cleanup_unavailable
        end
    end
  end

  describe "a stream that ends by throwing or exiting" do
    # C01/C02: the category and original binary bound are unchanged.
    test "a progress function that throws ends the drain as a bounded interruption" do
      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(stream_response(), request(), identity(), fn _ ->
                 throw(:progress_refused)
               end)

      assert is_binary(reason)
      assert byte_size(reason) <= 4_096
      assert reason == "model_call_failed"
    end

    test "a progress function that exits ends the drain as a bounded interruption" do
      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(stream_response(), request(), identity(), fn _ ->
                 exit(:progress_gone)
               end)

      assert is_binary(reason)
      assert byte_size(reason) <= 4_096
      assert reason == "model_call_failed"
    end
  end

  describe "the credential in a returned reason" do
    # C03: fixed private status replaces ambient-key-dependent redacted text.
    test "a provider error echoing the key is substituted before it is returned" do
      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(
                 stream_response(echoing_stream()),
                 request(),
                 identity(),
                 Model.discard_progress()
               )

      refute reason =~ @sentinel
      assert is_binary(reason)
      assert byte_size(reason) <= 4_096
      assert reason == "model_call_failed"
    end
  end

  describe "the provider worker while the credential is live" do
    # C04: the retired registry's supervision promise becomes independent real
    # dependency supervision; no host group leader is rebound during recovery.
    test "parent provider-supervisor restart leaves protected invocations and host diagnostics usable" do
      fixture = Fixture.new(:diagnostics)
      call = Fixture.managed(fixture)
      await_reply(call)
      old = Process.whereis(ReqLLM.Supervisor)
      old_task = Process.whereis(ReqLLM.TaskSupervisor)
      assert is_pid(old) and is_pid(old_task)
      assert {:links, links} = Process.info(old_task, :links)
      assert old in links
      old_monitor = Process.monitor(old)
      task_monitor = Process.monitor(old_task)
      unrelated = spawn(fn -> receive do: (:stop -> :ok) end)
      unrelated_leader = Process.info(unrelated, :group_leader)
      primary = :logger.get_primary_config()

      try do
        assert_private(fn ->
          assert :ok = Application.stop(:req_llm)
          assert_receive {:DOWN, ^old_monitor, :process, ^old, :shutdown}, 1_000
          assert_receive {:DOWN, ^task_monitor, :process, ^old_task, :shutdown}, 1_000
          assert Fixture.alive?(Fixture.pid(fixture))
          {:ok, _} = Application.ensure_all_started(:req_llm)
          restarted = Process.whereis(ReqLLM.Supervisor)
          restarted_task = Process.whereis(ReqLLM.TaskSupervisor)
          assert is_pid(restarted) and restarted != old
          assert is_pid(restarted_task) and restarted_task != old_task
          assert {:links, new_links} = Process.info(restarted_task, :links)
          assert restarted in new_links
          release_diagnostics(fixture)
          Fixture.stop(call)
        end)

        assert Process.info(unrelated, :group_leader) == unrelated_leader
        assert :logger.get_primary_config() == primary
        assert_parent_task_usable()
        assert_success(Fixture.new())
        Fixture.assert_gone(fixture)
      after
        send(unrelated, :stop)
        {:ok, _} = Application.ensure_all_started(:req_llm)
      end
    end

    # C05: a blocked private provider must not become a host Logger dependency.
    test "host logging never waits for an isolated provider during bootstrap" do
      fixture = Fixture.new(:hold_before_entry)
      call = Fixture.managed(fixture)
      assert Fixture.eventually(fn -> Fixture.reached?(fixture, "pid") end)

      assert_private(fn ->
        task = Task.async(fn -> Logger.error("host-log-while-provider-bootstrap-blocked") end)
        assert {:ok, :ok} = Task.yield(task, 500)
        Fixture.stop(call)
      end)

      assert Fixture.canaries(fixture) == 0
      assert Fixture.count(fixture) == 0
      Fixture.assert_gone(fixture)
    end

    # C06: trace ordinary host guardian traffic, never inspect raw sender state.
    test "ordinary guardian messages and results never carry its credential" do
      fixture = Fixture.new(:reply, paused: true)
      call = Fixture.managed(fixture)
      assert :erlang.trace(call.guardian, true, [:send, :receive]) == 1
      send(call.caller, :continue)
      await_reply(call)
      Fixture.stop(call)
      guardian = call.guardian
      barrier = :erlang.trace_delivered(guardian)
      assert_receive {:trace_delivered, ^guardian, ^barrier}, 1_000
      traces = take_traces(call.guardian, [])
      assert traces != []
      refute inspect(traces, limit: :infinity, printable_limit: :infinity) =~ @sentinel
      assert_post(fixture)
      assert_fixture_files_private(fixture, [@sentinel])
      Fixture.assert_gone(fixture)
    end

    # C07: stale control cannot release a different invocation; a first cleanup
    # cannot make another key's still-retained child unprotected.
    test "stale lifetime control cannot release a different live invocation" do
      {first, first_call, second, second_call} = two_live_children()
      assert Fixture.pid(first) != Fixture.pid(second)
      assert Fixture.namespace(first) != Fixture.namespace(second)
      wrong_stop = make_ref()
      deadline = System.monotonic_time(:millisecond) + 2_000

      send(
        second_call.guardian,
        {:loopex_provider_resource_stop, first_call.stop_reference, wrong_stop, self(), deadline,
         deadline + 100}
      )

      refute_receive {:loopex_provider_resource_stopped, ^wrong_stop, _}, 100
      Fixture.stop(first_call)
      Fixture.assert_gone(first)
      assert Fixture.alive?(Fixture.pid(second))
      assert Process.alive?(second_call.guardian)

      assert_private(fn -> release_diagnostics(second) end, [
        @sentinel <> "-first",
        @sentinel <> "-second"
      ])

      Fixture.stop(second_call)
      assert_post(first)
      assert_post(second)
      Fixture.assert_gone(second)
    end

    # C08/C09 retain repeated occurrences and nested map KEYS as distinct inputs.
    test "repeated credential bytes in actual child metadata cannot reach host channels" do
      assert_diagnostic(:credential_metadata_repeated, ["metadata_repeated"])
    end

    test "credential-bearing child metadata keys cannot reach host channels" do
      assert_diagnostic(:credential_metadata_key, ["metadata_key"])
    end

    # C10: the second key is already live before the first child emits ONE event
    # containing both. Derivation happens solely in child memory, not in script.
    # Concept: two credential planes in one VM stay apart: each isolated
    # provider child receives its own plane's credential and never the other
    # plane's, even while both are live.
    #
    # Technical depth: two fixtures each compose their own custody, routing
    # registry and token with a distinct synthetic key, and both invocations
    # are started before either completes. The fake provider records the raw
    # request headers each child sent: each carries only its own key.
    test "two live credential planes each deliver only their own credential" do
      first_key = @sentinel <> "-plane-a"
      second_key = @sentinel <> "-plane-b"
      first = Fixture.new(:reply, credential: first_key)
      second = Fixture.new(:reply, credential: second_key)

      first_call = Fixture.managed(first)
      second_call = Fixture.managed(second)
      await_reply(first_call)
      await_reply(second_call)

      assert [first_headers] = Fixture.request_headers(first)
      assert [second_headers] = Fixture.request_headers(second)
      assert first_headers =~ first_key
      refute first_headers =~ second_key
      assert second_headers =~ second_key
      refute second_headers =~ first_key

      for {fixture, call} <- [{first, first_call}, {second, second_call}] do
        Fixture.stop(call)
        assert_post(fixture)
        Fixture.assert_gone(fixture)
      end
    end

    # Concept: during an invocation the credential travels between BEAM
    # processes exactly once, from custody to the sender that writes it to the
    # child, and no process that existed before the call ever sends it on.
    #
    # Technical depth: an OTP trace session of its own records every message
    # sent by every process that existed before one managed invocation with a
    # unique synthetic key. Custody is sensitive, so no trace can see its
    # reply; the case instead holds the sender inside its custody call,
    # suspends it, releases custody and has a one-use inspector confirm that
    # the queued message is the complete `GenServer.call` reply carrying the
    # key. The only traced carrier is the case's own control message, sent
    # inside the census to prove the census records. The sender excludes
    # itself from tracing before it receives the credential, and its write to
    # the child is a port command, not a message.
    test "the custody reply is the sole credential-bearing BEAM message" do
      key = @sentinel <> "-sole-message"
      fixture = Fixture.new(:reply, credential: key)
      test = self()

      {{result, reply_queued?}, carriers} =
        census(key, :existing, fn ->
          send(test, {:census_control, key})
          assert_received {:census_control, ^key}
          {call, sender} = hold_in_custody(fixture, Fixture.request())
          assert :erlang.suspend_process(sender)
          assert :erlang.resume_process(fixture.custody_pid)
          assert Fixture.eventually(fn -> queued(sender) == 1 end, 5_000)
          reply_queued? = custody_reply_queued?(sender, key)
          assert :erlang.resume_process(sender)
          result = completion(call)
          Fixture.stop(call)
          {result, reply_queued?}
        end)

      assert {:ok, %{text: "loopex"}} = result
      assert reply_queued?
      assert carriers == [{test, test}]
      assert_post(fixture)
      Fixture.assert_gone(fixture)
    end

    # Concept: an invocation that could be observed by a foreign trace session
    # over every process refuses before its credential moves at all.
    test "a foreign all-process trace session refuses the call before the credential moves" do
      key = @sentinel <> "-observed"
      fixture = Fixture.new(:reply, credential: key)

      {result, carriers} =
        census(key, :all, fn ->
          call = Fixture.managed(fixture)
          result = completion(call)
          Fixture.stop(call)
          result
        end)

      assert result == {:error, {:not_dispatched, "model_call_failed"}}
      assert carriers == []
    end

    # Concept: a routing registry that does not know the token, or is gone,
    # refuses the invocation: its companion never receives a credential or
    # sends a request, is cleaned up, and the adapter does not try again.
    #
    # Technical depth: the first call carries a live registry that holds no
    # row for the fixture's token; the second carries the fixture's own
    # registry after it has been killed. Each answers the fixed
    # `not_dispatched` result; the fake provider received nothing and the
    # companion's process group is gone.
    test "an unknown token or a dead registry refuses before any request is sent" do
      fixture = Fixture.new(:reply, credential: @sentinel <> "-routing")
      {:ok, empty_pid} = CredentialRegistry.start_link()
      {:ok, empty} = CredentialRegistry.handle(empty_pid)

      assert Adapter.complete(
               Fixture.request(),
               Keyword.put(fixture.options, :credential_registry, empty),
               Model.discard_progress()
             ) == {:error, {:not_dispatched, "model_call_failed"}}

      Process.unlink(fixture.registry_pid)
      monitor = Process.monitor(fixture.registry_pid)
      Process.exit(fixture.registry_pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 1_000
      assert Fixture.complete(fixture) == {:error, {:not_dispatched, "model_call_failed"}}

      assert Fixture.count(fixture) == 0
      Fixture.assert_gone(fixture)
      GenServer.stop(empty_pid)
    end

    # Concept: invocations sharing one token each receive one whole credential
    # as custody held it when that invocation resolved it; a rotation between
    # them changes what the next invocation receives, never a mix.
    #
    # Technical depth: the first managed call completes on the original key,
    # custody rotates to a second key, and two concurrent calls then resolve
    # the same token. The raw request headers show the first call carried only
    # the original key and both later calls only the rotated one.
    test "same-token invocations around a rotation each carry one whole credential" do
      original = @sentinel <> "-before-rotation"
      rotated = @sentinel <> "-after-rotation"
      fixture = Fixture.new(:reply, credential: original)
      {:ok, custody} = CredentialCustody.reference(fixture.custody_pid)

      first = Fixture.managed(fixture)
      await_reply(first)
      Fixture.stop(first)

      assert :ok = CredentialCustody.rotate(custody, rotated)
      second = Fixture.managed(fixture)
      third = Fixture.managed(fixture)
      await_reply(second)
      await_reply(third)
      Fixture.stop(second)
      Fixture.stop(third)

      assert [before | after_rotation] = Fixture.request_headers(fixture)
      assert before =~ original
      refute before =~ rotated
      assert length(after_rotation) == 2

      for headers <- after_rotation do
        assert headers =~ rotated
        refute headers =~ original
      end
    end

    # Concept: only the exact parties of an invocation can move its guardian.
    # A bootstrap or credential-phase result, a send acknowledgement or a stop
    # request that names the wrong reference, sender, guardian or phase changes
    # nothing, and the invocation completes as if none had arrived.
    #
    # Technical depth: the companion is held at entry while this test, which
    # is none of the invocation's parties, sends the live guardian forged forms
    # of each message the guardian acts on. The companion is then released and
    # the invocation must return its ordinary reply with one authorized request.
    test "forged guardian messages with the wrong identities change nothing" do
      fixture = Fixture.new(:delayed_entry, credential: @sentinel <> "-forged")
      call = Fixture.managed(fixture)
      assert Fixture.eventually(fn -> Fixture.reached?(fixture, "pid") end)
      guardian = call.guardian
      stranger = self()
      forged_ref = make_ref()
      now = System.monotonic_time(:millisecond)

      for message <- [
            {:bootstrap_result, forged_ref, stranger, guardian, :ok},
            {:bootstrap_result, forged_ref, stranger, stranger, {:error, :unavailable}},
            {:credential_phase_result, forged_ref, guardian, stranger, :deliver, :ok},
            {:credential_phase_result, forged_ref, stranger, stranger, :deliver,
             {:error, :timeout}},
            {:provider_sent, stranger, :bootstrap, :ok},
            {:provider_sent, stranger, :credential, {:error, :closed}},
            {:loopex_provider_resource_stop, forged_ref, make_ref(), stranger, now, now + 1},
            {:DOWN, make_ref(), :process, stranger, :killed}
          ] do
        send(guardian, message)
      end

      assert Process.alive?(guardian)
      Fixture.release(fixture)
      await_reply(call)
      Fixture.stop(call)
      assert_post(fixture)
      Fixture.assert_gone(fixture)
    end

    # Concept: a bootstrap result that names the invocation's own reference but
    # no live sender changes nothing, and nothing about the invocation reaches
    # the host log.
    #
    # Technical depth: a direct invocation has its sender reference before it
    # has a sender. While the child is held at entry, an arity-only call trace
    # whose match specification returns only that reference reads it from the
    # guardian's loop, and the case then sends the guardian
    # `{:bootstrap_result, sender_ref, nil, guardian, :ok}`. The guardian stays
    # alive, the released invocation returns its ordinary reply, and the
    # captured log names neither the token nor the credential context.
    test "a bootstrap result naming no live sender leaves the guardian and log untouched" do
      fixture = Fixture.new(:delayed_entry, credential: @sentinel <> "-nil-sender")
      token = Keyword.fetch!(fixture.options, :credential_token)

      log =
        capture_log(fn ->
          call = Fixture.managed(fixture, Fixture.request(), :unmanaged)
          guardian = call.guardian
          assert Fixture.eventually(fn -> Fixture.reached?(fixture, "pid") end)
          sender_ref = guardian_sender_ref(guardian)
          forged = {:bootstrap_result, sender_ref, nil, guardian, :ok}
          send(guardian, forged)
          assert Fixture.eventually(fn -> not queued?(guardian, forged) end, 1_000)

          # Handling a consumed message finishes before the guardian waits in
          # its loop again, or it ends the guardian.
          assert Fixture.eventually(
                   fn -> current_function(guardian) in [{ProviderBridge, :loop, 1}, :gone] end,
                   1_000
                 )

          assert Process.alive?(guardian)
          Fixture.release(fixture)
          caller = call.caller

          assert_receive {:completed, ^caller, {:ok, %{text: "loopex"}}},
                         Fixture.until_settled(call)

          Fixture.stop(call)
        end)

      refute log =~ "[error]"
      refute log =~ inspect(token.id)
      refute log =~ "CredentialToken"
      refute log =~ "credential_context"
      refute log =~ @sentinel
      assert_post(fixture)
      Fixture.assert_gone(fixture)
    end

    # Concept: a custody continuation the sender takes up only after the
    # deadline starts nothing: the sender exits, no credential frame is
    # written, and the guardian reports its own timeout.
    #
    # Technical depth: ADR 0034 technical step 10 in managed mode. The case
    # holds the sender inside its custody call, suspends the guardian, lets
    # custody answer, and suspends the sender once it waits for the custody
    # continuation. The guardian then runs just long enough to queue that
    # continuation before the deadline and is suspended again with the
    # guardian's receiver and the child held too, so neither of them can
    # report the deadline first. After the deadline the sender alone resumes:
    # it must exit `:credential_deadline` without another write on the data
    # socket. The resumed guardian must then reach its arity-only traced
    # timeout classification, and the call returns the fixed refusal.
    test "a custody continuation consumed after the deadline is the guardian's timeout and writes no frame" do
      key = @sentinel <> "-late-continuation"
      fixture = Fixture.new(:reply, credential: key)
      request = Fixture.request()

      log =
        capture_log(fn ->
          {call, sender} = hold_in_custody(fixture, request)
          guardian = call.guardian
          sender_monitor = Process.monitor(sender)
          {socket, receiver} = guardian_io(fixture, guardian, sender)
          written = sent_frames(socket)
          assert :erlang.trace_pattern({ProviderBridge, :expire, 1}, true, [:local]) == 1
          assert :erlang.trace(guardian, true, [:call, :arity]) == 1
          child = Integer.to_string(Fixture.pid(fixture))
          held = [guardian, receiver, fixture.custody_pid]

          try do
            assert :erlang.suspend_process(guardian)
            assert :erlang.suspend_process(receiver)
            assert {_, 0} = System.cmd("/bin/kill", ["-STOP", child])
            assert :erlang.resume_process(fixture.custody_pid)

            assert Fixture.eventually(
                     fn ->
                       current_function(sender) == {ProviderBridge, :await_custody_continue, 6}
                     end,
                     5_000
                   )

            assert :erlang.suspend_process(sender)
            assert Fixture.resume_guardian(guardian)
            assert Fixture.eventually(fn -> queued(sender) == 1 end, 5_000)
            assert :erlang.suspend_process(guardian)
            assert System.system_time(:millisecond) < request.deadline
            Process.sleep(max(request.deadline - System.system_time(:millisecond), 0) + 50)
            assert :erlang.resume_process(sender)

            assert_receive {:DOWN, ^sender_monitor, :process, ^sender, :credential_deadline},
                           2_000

            assert sent_frames(socket) == written
            assert Fixture.resume_guardian(guardian)
            assert_receive {:trace, ^guardian, :call, {ProviderBridge, :expire, 1}}, 2_000
          after
            :erlang.trace_pattern({ProviderBridge, :expire, 1}, false, [:local])
            System.cmd("/bin/kill", ["-CONT", child])

            for pid <- held, Process.alive?(pid) do
              if Process.info(pid, :status) == {:status, :suspended},
                do: :erlang.resume_process(pid)
            end
          end

          caller = call.caller
          assert_receive {:completed, ^caller, @refused}, Fixture.until_settled(call)
          Fixture.stop(call)
        end)

      refute log =~ key
      assert Fixture.count(fixture) == 0
      assert Fixture.canaries(fixture) == 0
      Fixture.assert_gone(fixture)
    end

    # Concept: an invocation asks custody for its credential exactly once;
    # nothing on the way to the child resolves it again or retries.
    #
    # Technical depth: custody is sensitive, so no trace sees what it
    # receives. A `:sys` debug function installed in custody instead counts
    # each incoming `resolve` call while one managed invocation runs to its
    # reply, and reports only a fixed atom per call; exactly one arrives.
    test "one invocation resolves its credential from custody exactly once" do
      fixture = Fixture.new(:reply, credential: @sentinel <> "-resolve-once")
      test = self()

      counter = fn
        :counting, {:in, {:"$gen_call", _from, {:resolve, _incarnation}}}, _process ->
          send(test, :custody_resolution)
          :counting

        :counting, _event, _process ->
          :counting
      end

      assert :ok = :sys.install(fixture.custody_pid, {counter, :counting})

      try do
        call = Fixture.managed(fixture)
        await_reply(call)
        Fixture.stop(call)
      after
        :sys.remove(fixture.custody_pid, counter)
      end

      assert_received :custody_resolution
      refute_received :custody_resolution
      assert_post(fixture)
    end

    test "one child diagnostic containing two concurrently live synthetic keys cannot escape" do
      second_key = @sentinel <> "-second"
      first_key = @sentinel <> "-first"
      second = Fixture.new(:diagnostics, credential: second_key)
      second_call = Fixture.managed(second)
      await_reply(second_call)
      first = Fixture.new(:credential_overlap, credential: first_key)

      assert_private(
        fn ->
          first_call = Fixture.managed(first)
          await_reply(first_call)
          assert_probe(first, ["two_distinct_credentials_one_event"])
          assert Fixture.alive?(Fixture.pid(second))
          Fixture.stop(first_call)
          assert Fixture.alive?(Fixture.pid(second))
          release_diagnostics(second)
          Fixture.stop(second_call)
        end,
        [first_key, second_key]
      )

      for fixture <- [first, second] do
        assert_post(fixture)
        assert_fixture_files_private(fixture, [first_key, second_key])
        Fixture.assert_gone(fixture)
      end
    end

    # C11: abrupt callback loss is not normal completion and is not retainer loss.
    test "callback death after a result does not release a different retainer's child" do
      fixture = Fixture.new(:diagnostics, hold_caller: true)
      call = Fixture.managed(fixture)
      await_reply(call)
      caller = call.caller
      caller_monitor = call.caller_monitor
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
      assert Fixture.alive?(Fixture.pid(fixture))
      assert Process.alive?(call.guardian)
      assert_private(fn -> release_diagnostics(fixture) end)
      Fixture.stop(call)
      assert_post(fixture)
      Fixture.assert_gone(fixture)
    end

    # C12: child-local protection loss replaces missing parent activity state.
    test "loss of child diagnostic protection cannot leak its credential" do
      fixture = Fixture.new(:credential_sink_loss)

      assert_private(fn ->
        request = Fixture.request()
        call = Fixture.managed(fixture, request, :unmanaged)
        release_fault_and_observe(fixture, call, request, "credential-probe")
        caller = call.caller
        assert_receive {:completed, ^caller, @failed}, Fixture.until_settled(call)
        guardian = call.guardian
        monitor = call.monitor
        assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500

        assert probe(fixture, "credential-probe") == %{
                 "actions" => ["sink_loss"],
                 "key_present" => true,
                 "sink_down" => true,
                 "sink_reason_killed" => true
               }
      end)

      assert Fixture.methods(fixture) == ["POST"]
      assert Fixture.count(fixture) == 0
      Fixture.assert_gone(fixture)
      assert_success(Fixture.new())
    end

    # C13: ADR 0019 explicitly retires global poison; only the lost invocation
    # fails, with no restart. Other owners and ordinary host logging stay usable.
    test "losing one credential-bearing child does not poison another invocation or host logs" do
      healthy = Fixture.new(:diagnostics)
      healthy_call = Fixture.managed(healthy)
      await_reply(healthy_call)
      failed = Fixture.new(:blocked)
      failed_call = Fixture.managed(failed)
      assert Fixture.eventually(fn -> Fixture.count(failed) == 1 end)
      failed_pid = Fixture.pid(failed)

      assert_private(fn ->
        assert {_, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(failed_pid)])
        caller = failed_call.caller
        assert_receive {:completed, ^caller, @failed}, Fixture.until_settled(failed_call)
        Fixture.stop(failed_call)
        assert Fixture.pid(failed) == failed_pid
        assert Fixture.canaries(failed) == 1
        assert Fixture.alive?(Fixture.pid(healthy))
        release_diagnostics(healthy)
        Fixture.stop(healthy_call)
      end)

      assert Fixture.eventually(fn ->
               Fixture.transport_events(failed) == [:connected, :closed]
             end)

      assert_post(failed)
      assert_post(healthy)
      Fixture.assert_gone(failed)
      Fixture.assert_gone(healthy)
      assert_success(Fixture.new())
    end

    # C14: an invalid protected bootstrap, not an unrelated host filter, controls
    # admission. The actual Worker must refuse before readiness can release a key.
    test "invalid protected bootstrap cannot receive a credential or dispatch" do
      fixture = Fixture.new()
      options = Keyword.put(fixture.options, :build_manifest_sha256, String.duplicate("9", 64))

      # The refusal is reached by the committed transfer deadline expiring on a
      # child that never becomes ready, so the deadline is the whole cost of this
      # case. It still keeps the port default: the entry markers asserted below
      # are written by the booted child, and a two-second deadline had the
      # child stopped mid-boot on a loaded hosted runner. The refusal it proves
      # is the same one at any value.
      assert_private(fn ->
        assert Adapter.complete(Fixture.request(), options, Model.discard_progress()) == @refused
      end)

      assert Fixture.canaries(fixture) == 0
      assert Fixture.count(fixture) == 0
      refute File.read!(Fixture.marker(fixture, "entry-env")) =~ Adapter.credential_variable()
      assert_fixture_files_private(fixture, [@sentinel])
      Fixture.assert_gone(fixture)
      assert_success(Fixture.new())
    end

    # C15: the original finite transfer deadline is not restarted by a late
    # release. This is an actual releasable child entry, not a fake handshake.
    test "expired bootstrap cannot deliver a credential later or relaunch" do
      fixture = Fixture.new(:delayed_entry)
      # The child holds at its entry until the case releases it after the
      # refusal, so the deadline expires at any value; the port default keeps
      # the boot, which writes the pid marker read below, inside it. The wait
      # for the refusal is the rest of that deadline plus the cleanup that
      # follows it, not a fixed number that only covered a short deadline.
      request = Fixture.request()
      call = Fixture.managed(fixture, request, :unmanaged)
      assert Fixture.eventually(fn -> Fixture.reached?(fixture, "pid") end)
      original_pid = Fixture.pid(fixture)
      caller = call.caller
      assert_receive {:completed, ^caller, @refused}, Fixture.until_settled(call)
      guardian = call.guardian
      monitor = call.monitor
      assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500
      Fixture.assert_gone(fixture)
      Fixture.release(fixture)
      assert Fixture.pid(fixture) == original_pid
      refute Fixture.alive?(original_pid)
      assert Fixture.canaries(fixture) == 0
      assert Fixture.count(fixture) == 0
      refute File.exists?(Fixture.namespace(fixture))
      assert_success(Fixture.new())
    end

    # C16: direct and actual TaskSupervisor IO refusals remain explicit; the
    # host never lends its group leaders and needs no final-lease restoration.
    test "one invocation's cleanup cannot release another invocation's IO protection" do
      before = parent_supervisors()

      assert_private(
        fn ->
          {first, first_call, second, second_call} = two_live_children()
          assert_io_refused(first)
          assert_io_refused(second)
          Fixture.stop(first_call)
          Fixture.assert_gone(first)
          assert Fixture.alive?(Fixture.pid(second))
          release_diagnostics(second)

          assert probe(second, "delayed-io-results") ==
                   %{"direct" => "refused", "supervised" => "refused"}

          Fixture.stop(second_call)
          assert_post(first)
          assert_post(second)
          Fixture.assert_gone(second)
        end,
        [@sentinel <> "-first", @sentinel <> "-second"]
      )

      assert parent_supervisors() == before
      assert_parent_task_usable()
      assert parent_supervisors() == before
    end

    # C17: real library raise after request-key capture and child-only rotation.
    test "a child transport raise after environment rotation cannot expose its request credential" do
      assert_credential_failure(:credential_raise, false)
    end

    # C18/C19 retain every original input form through real Logger entrypoints.
    test "ordinary and split actual child Logger messages cannot expose the credential" do
      assert_diagnostic(:credential_ordinary_split, ["ordinary_repeated", "split_repeated"])
    end

    test "all actual child Logger message forms and metadata stay private" do
      assert_diagnostic(:credential_forms, [
        "string_chardata",
        "format_args_metadata",
        "report_metadata_key"
      ])
    end

    # C20/C21 are separate executed scenarios under the port-default deadline.
    for {ending, mode} <- [{:throw, :credential_throw}, {:exit, :credential_exit}] do
      @ending ending
      @mode mode
      test "a provider request adapter that #{@ending}s cannot put the credential in a stream-server crash report" do
        assert_credential_failure(@mode, true)
      end
    end

    # C22's report carries api_key in last_message and its own reason. ADR 0019
    # intentionally does not return even a rewritten report to the host.
    test "an actual child report containing its own request credential stays private" do
      assert_diagnostic(:credential_report, ["request_credential_report"])
    end

    # C23 is actual StreamServer death, distinct from C22's emitted report map.
    test "an actual child StreamServer termination cannot forward its credential" do
      assert_credential_failure(:credential_crash_event, true)
    end

    # C24: an unrelated parent filter has no provider-admission authority. C14
    # separately proves refusal at the new actual protection boundary.
    test "an unrelated parent filter cannot seize isolated provider admission" do
      filter_id = :loopex_req_llm_credential_filter
      previous = List.keyfind(:logger.get_primary_config().filters, filter_id, 0)
      remove_primary_filter(filter_id)
      filter = {fn event, _ -> event end, :unrelated_host_configuration}
      :ok = :logger.add_primary_filter(filter_id, filter)
      before = :logger.get_primary_config()
      supervisors = parent_supervisors()

      try do
        assert_private(fn -> assert_success(Fixture.new(:diagnostics)) end)
        assert :logger.get_primary_config() == before
        assert List.keyfind(before.filters, filter_id, 0) == {filter_id, filter}
        assert parent_supervisors() == supervisors
        assert_parent_task_usable()
      after
        remove_primary_filter(filter_id)

        if previous do
          {^filter_id, original} = previous
          :ok = :logger.add_primary_filter(filter_id, original)
        end
      end
    end
  end

  defp assert_diagnostic(mode, actions) do
    fixture = Fixture.new(mode)
    before = {:logger.get_primary_config(), parent_supervisors()}

    assert_private(fn ->
      assert_success(fixture)
      assert_probe(fixture, actions)
    end)

    assert {:logger.get_primary_config(), parent_supervisors()} == before
    assert_fixture_files_private(fixture, [@sentinel])
  end

  defp assert_credential_failure(mode, observe_termination) do
    fixture = Fixture.new(mode)

    assert_private(fn ->
      # The deadline is absolute from here, and the child is spawned inside the
      # call, so it prices the child's boot as well as the fault this case
      # releases. Every witness below must land before it. Committing two
      # seconds put the boot alone past it on a loaded hosted runner, where
      # the case then observed the deadline instead of the fault; the port
      # default stays, and the case ends when the witnesses land, not at the
      # deadline.
      request = Fixture.request()
      call = Fixture.managed(fixture, request)

      if observe_termination,
        do: release_fault_and_observe(fixture, call, request, "termination-proof")

      caller = call.caller
      assert_receive {:completed, ^caller, @failed}, Fixture.until_settled(call)

      assert probe(fixture, "credential-probe") == %{
               "actions" => [Atom.to_string(mode)],
               "key_present" => true,
               "environment_rotated" => true
             }

      if observe_termination do
        assert Fixture.eventually(fn -> Fixture.reached?(fixture, "termination-proof") end)

        assert probe(fixture, "termination-proof") == %{
                 "actual_stream_server_down" => true,
                 "credential_in_reason" => true
               }
      end

      Fixture.stop(call)
    end)

    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.count(fixture) == 0
    Fixture.assert_gone(fixture)
    assert_fixture_files_private(fixture, [@sentinel])
  end

  defp two_live_children do
    first_key = @sentinel <> "-first"
    second_key = @sentinel <> "-second"
    first = Fixture.new(:diagnostics, credential: first_key)
    first_call = Fixture.managed(first)
    await_reply(first_call)
    second = Fixture.new(:diagnostics, credential: second_key)
    second_call = Fixture.managed(second)
    await_reply(second_call)
    {first, first_call, second, second_call}
  end

  defp release_fault_and_observe(fixture, call, request, witness) do
    remaining = fn -> max(request.deadline - System.system_time(:millisecond), 0) end
    assert Fixture.eventually(fn -> Fixture.reached?(fixture, "fault-ready") end, remaining.())
    assert probe(fixture, "fault-ready") == %{"observer_installed" => true}
    assert :erlang.suspend_process(call.guardian)

    try do
      File.write!(Fixture.marker(fixture, "release-fault"), "release")
      assert Fixture.eventually(fn -> Fixture.reached?(fixture, witness) end, remaining.())
      assert Fixture.eventually(fn -> Fixture.reached?(fixture, "entry-down") end, remaining.())
      assert probe(fixture, "entry-down") == %{"worker_down" => true, "abnormal" => true}
      assert System.system_time(:millisecond) < request.deadline
    after
      if Process.alive?(call.guardian), do: :erlang.resume_process(call.guardian)
    end
  end

  # Concept: a managed invocation is held with its sender waiting inside its
  # one custody call, so the case decides what the sender sees next.
  #
  # Technical depth: custody is suspended before the call starts, so the
  # sender's `GenServer.call` waits on it. The sender is the fixture's one
  # supervised child other than the guardian. Its current stack, which holds
  # only modules, functions and arities, shows the wait inside custody
  # resolution. Custody stays suspended; the caller releases it.
  defp hold_in_custody(fixture, request) do
    assert :erlang.suspend_process(fixture.custody_pid)
    call = Fixture.managed(fixture, request)
    guardian = call.guardian

    assert Fixture.eventually(fn ->
             Task.Supervisor.children(fixture.workers) -- [guardian] != []
           end)

    [sender] = Task.Supervisor.children(fixture.workers) -- [guardian]

    assert Fixture.eventually(
             fn ->
               case Process.info(sender, :current_stacktrace) do
                 {:current_stacktrace, stack} ->
                   Enum.any?(stack, &match?({CredentialCustody, :resolve, 1, _}, &1)) and
                     Enum.any?(stack, &match?({:gen, :do_call, 4, _}, &1))

                 nil ->
                   false
               end
             end,
             Fixture.until_settled(call)
           )

    {call, sender}
  end

  defp queued(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length
      nil -> :gone
    end
  end

  # True while `message` still waits in `pid`'s mailbox; a gone process has
  # consumed nothing more, so it reads as false and its liveness is asserted
  # separately.
  defp queued?(pid, message) do
    case Process.info(pid, :messages) do
      {:messages, messages} -> message in messages
      nil -> false
    end
  end

  defp current_function(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, mfa} -> mfa
      nil -> :gone
    end
  end

  # Concept: the one queued message is custody's complete call reply.
  #
  # Technical depth: an unlinked one-use inspector reads the suspended
  # sender's mailbox, reports only a boolean and is killed and awaited, so the
  # message is never copied into the case process.
  defp custody_reply_queued?(sender, key) do
    parent = self()

    {inspector, monitor} =
      spawn_monitor(fn ->
        verdict =
          case Process.info(sender, :messages) do
            {:messages, [{tag, {:ok, %{credential: ^key} = reply}}]}
            when map_size(reply) == 1 ->
              reply_tag?(tag)

            _other ->
              false
          end

        send(parent, {:inspected, self(), verdict})
        receive do: (:never -> :ok)
      end)

    assert_receive {:inspected, ^inspector, verdict}, 1_000
    Process.exit(inspector, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^inspector, :killed}, 1_000
    verdict
  end

  # A `GenServer.call` reply is tagged with the call's monitor reference, or
  # with that reference behind `:alias` when the call used a process alias.
  defp reply_tag?([:alias | tag]), do: is_reference(tag)
  defp reply_tag?(tag), do: is_reference(tag)

  # Concept: the guardian's data socket and socket reader are found from the
  # guardian's own links.
  #
  # Technical depth: the guardian owns the accepted TCP socket, so the socket
  # port is linked to it, and it links its raw receiver. Every other linked
  # process is the fixture's supervisor or the credential sender.
  defp guardian_io(fixture, guardian, sender) do
    {:links, links} = Process.info(guardian, :links)

    [socket] =
      Enum.filter(links, &(is_port(&1) and Port.info(&1, :name) == {:name, ~c"tcp_inet"}))

    [receiver] = Enum.filter(links, &is_pid/1) -- [fixture.workers, sender]
    {socket, receiver}
  end

  defp sent_frames(socket) do
    {:ok, [send_cnt: count]} = :inet.getstat(socket, [:send_cnt])
    count
  end

  # Concept: a direct guardian's sender reference is read without copying its
  # state out of the guardian.
  #
  # Technical depth: an arity-only call trace on the guardian's loop carries
  # only the value its match specification selects, the reference.
  defp guardian_sender_ref(guardian) do
    specification = [{[:"$1"], [], [{:message, {:map_get, :sender_ref, :"$1"}}]}]
    assert :erlang.trace_pattern({ProviderBridge, :loop, 1}, specification, [:local]) == 1
    assert :erlang.trace(guardian, true, [:call, :arity]) == 1

    try do
      assert_receive {:trace, ^guardian, :call, {ProviderBridge, :loop, 1}, sender_ref}, 2_000
      assert is_reference(sender_ref)
      sender_ref
    after
      :erlang.trace(guardian, false, [:call, :arity])
      :erlang.trace_pattern({ProviderBridge, :loop, 1}, false, [:local])
    end
  end

  # Runs `work` under an OTP trace session of its own that records, for every
  # traced process, each sent message containing `key`.
  defp census(key, processes, work) do
    parent = self()

    tracer =
      spawn_link(fn ->
        collect = fn collect, seen ->
          receive do
            {:trace, from, :send, message, to} ->
              seen =
                if :binary.match(:erlang.term_to_binary(message), key) != :nomatch,
                  do: [{from, to} | seen],
                  else: seen

              collect.(collect, seen)

            {:report, caller} ->
              send(caller, {:carriers, Enum.reverse(seen)})
          end
        end

        collect.(collect, [])
      end)

    session = :trace.session_create(:credential_message_census, tracer, [])

    result =
      try do
        :trace.process(session, processes, true, [:send])
        work.()
      after
        :trace.session_destroy(session)
      end

    send(tracer, {:report, parent})
    assert_receive {:carriers, carriers}, 5_000
    {result, carriers}
  end

  defp completion(call) do
    caller = call.caller

    receive do
      {:completed, ^caller, result} -> result
    after
      Fixture.until_settled(call) -> flunk("the invocation did not complete")
    end
  end

  defp await_reply(call) do
    caller = call.caller
    assert_receive {:completed, ^caller, {:ok, reply}}, Fixture.until_settled(call)
    assert reply.text == "loopex"
    refute inspect(reply) =~ @sentinel
    reply
  end

  defp assert_success(fixture) do
    assert {:ok, reply} = Fixture.complete(fixture)
    assert reply.text == "loopex"
    refute inspect(reply) =~ @sentinel
    assert_post(fixture)
    Fixture.assert_gone(fixture)
  end

  defp assert_post(fixture) do
    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert [{_request, true}] = Fixture.events(fixture)
  end

  defp assert_probe(fixture, actions),
    do:
      assert(probe(fixture, "credential-probe") == %{"actions" => actions, "key_present" => true})

  defp probe(fixture, name),
    do: fixture |> Fixture.marker(name) |> File.read!() |> Jason.decode!()

  defp assert_io_refused(fixture),
    do:
      assert(probe(fixture, "io-results") == %{"direct" => "refused", "supervised" => "refused"})

  defp release_diagnostics(fixture) do
    File.write!(Fixture.marker(fixture, "release-diagnostics"), "release")
    assert Fixture.eventually(fn -> Fixture.reached?(fixture, "delayed-diagnostics") end)
  end

  defp assert_private(fun, keys \\ [@sentinel]) do
    log =
      capture_log(fn ->
        assert capture_io(fun) == ""
        Logger.error("parent-credential-plane-diagnostics-usable")
      end)

    for key <- keys, do: refute(log =~ key)
    assert log =~ "parent-credential-plane-diagnostics-usable"
  end

  defp parent_supervisors do
    for name <- [ReqLLM.Supervisor, ReqLLM.TaskSupervisor] do
      pid = Process.whereis(name)
      assert is_pid(pid)
      {pid, Process.info(pid, :group_leader)}
    end
  end

  defp assert_parent_task_usable do
    assert capture_io(Process.whereis(ReqLLM.TaskSupervisor), fn ->
             task =
               Task.Supervisor.async(ReqLLM.TaskSupervisor, fn -> IO.write("host-task-usable") end)

             assert :ok = Task.await(task, 1_000)
           end) == "host-task-usable"
  end

  defp assert_fixture_files_private(fixture, keys) do
    for path <- Path.wildcard(Path.join(fixture.root, "**/*"), match_dot: true),
        File.regular?(path),
        key <- keys do
      refute File.read!(path) =~ key
    end
  end

  defp take_traces(guardian, traces) do
    receive do
      {:trace, ^guardian, :receive, _message} = trace ->
        take_traces(guardian, [trace | traces])

      {:trace, ^guardian, :send, _message, _target} = trace ->
        take_traces(guardian, [trace | traces])
    after
      0 -> Enum.reverse(traces)
    end
  end

  defp remove_primary_filter(id) do
    case :logger.remove_primary_filter(id) do
      :ok -> :ok
      {:error, {:not_found, ^id}} -> :ok
    end
  end

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

  defp echoing_stream do
    Stream.map([:reject], fn _ ->
      raise %ReqLLM.Error.API.Stream{
        reason: "Stream failed: authentication_error for x-api-key #{@sentinel}",
        cause: :closed
      }
    end)
  end
end
