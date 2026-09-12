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

  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  require Logger

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture
  alias Loopex.LLM.ReqLLM.{ProviderCodec, ProviderPhaseDiagnostic}
  alias Loopex.Model

  @sentinel "sk-loopex-credential-plane-sentinel-2f9c41"
  @failed {:error, {:dispatched_or_unknown, "model_call_failed"}}
  @refused {:error, {:not_dispatched, "model_call_failed"}}

  setup do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, @sentinel)
    {:ok, _} = Application.ensure_all_started(:req_llm)

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    %{variable: variable}
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
    deadline = System.system_time(:millisecond) + 5_000

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    {owner, reference, monitor} = start_version_probe(fixture, path, nonce, digest, deadline)

    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
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
    test "a provider error echoing the key is substituted before it is returned", %{
      variable: variable
    } do
      for ambient <- [@sentinel, "rotated-host-credential", nil] do
        if ambient, do: System.put_env(variable, ambient), else: System.delete_env(variable)

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
    test "one child diagnostic containing two concurrently live synthetic keys cannot escape" do
      second_key = @sentinel <> "-second"
      first_key = @sentinel <> "-first"
      System.put_env(Adapter.credential_variable(), second_key)
      second = Fixture.new(:diagnostics, credential: second_key)
      second_call = Fixture.managed(second)
      await_reply(second_call)
      System.put_env(Adapter.credential_variable(), first_key)
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
        assert_receive {:completed, ^caller, @failed}, 5_000
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
        assert_receive {:completed, ^caller, @failed}, 5_000
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
      call = Fixture.managed(fixture, Fixture.request(deadline_ms: 2_000), :unmanaged)
      assert Fixture.eventually(fn -> Fixture.reached?(fixture, "pid") end)
      original_pid = Fixture.pid(fixture)
      caller = call.caller
      assert_receive {:completed, ^caller, @refused}, 5_000
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

    # C20/C21 are separate executed scenarios, preserving the original2s budget.
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
      request = Fixture.request(deadline_ms: 2_000)
      call = Fixture.managed(fixture, request)

      if observe_termination,
        do: release_fault_and_observe(fixture, call, request, "termination-proof")

      caller = call.caller
      assert_receive {:completed, ^caller, @failed}, 5_000

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
    System.put_env(Adapter.credential_variable(), first_key)
    first = Fixture.new(:diagnostics, credential: first_key)
    first_call = Fixture.managed(first)
    await_reply(first_call)
    System.put_env(Adapter.credential_variable(), second_key)
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

  defp await_reply(call) do
    caller = call.caller
    assert_receive {:completed, ^caller, {:ok, reply}}, 5_000
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
