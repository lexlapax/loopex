defmodule LoopexCli.DurableAskWorkflowTest do
  use ExUnit.Case, async: true

  alias LoopexCli.DurableAsk
  alias LoopexCli.DurableAsk.FollowReader
  alias LoopexProtocol.Canonical

  @cwd "/tmp/loopex-ask-workspace"
  @root "/tmp/loopex-ask-state"

  test "trace activates before create and its owned drain is gone before rendering" do
    caller = self()

    {seams, calls} =
      harness(&completed_events/1,
        trace_hook: fn consumer, configuration ->
          assert {:ok, owned} = LoopexComposition.DiagnosticConsumer.owned_processes(consumer)
          send(caller, {:trace_owned, owned})
          assert configuration.sink == :diagnostics
          assert configuration.level == :returns
          {:ok, %{active: true}}
        end
      )

    selected = Map.put(options(), :trace, %{"enabled" => true, "level" => "returns"})

    assert %{status: 0, stderr: "", stdout: stdout} =
             DurableAsk.run(selected, @cwd, "prompt", seams)

    assert %{"outcome" => "completed"} = JSON.decode!(String.trim_trailing(stdout, "\n"))
    assert_receive {:trace_owned, owned}
    Enum.each(owned, &refute(Process.alive?(&1)))
    observed = Agent.get(calls, & &1.calls)

    assert ordered?(observed, [
             :with_runtime,
             :trace,
             :create,
             :prompt,
             :callback_return,
             :credential_release,
             :placement_release
           ])

    assert Agent.get(calls, & &1.composition)[:cleanup_grace_ms] == 5_000
  end

  test "disabled trace keeps the ordinary ownership and calls no trace API" do
    {seams, calls} = harness(&completed_events/1)
    selected = Map.put(options(), :trace, %{"enabled" => false, "level" => "arguments"})
    assert %{status: 0} = DurableAsk.run(selected, @cwd, "prompt", seams)
    refute :trace in Agent.get(calls, & &1.calls)
    refute Keyword.has_key?(Agent.get(calls, & &1.composition), :diagnostics_to)
  end

  test "requested trace failure joins its drain and creates no untraced session" do
    caller = self()

    {seams, calls} =
      harness(&completed_events/1,
        trace_hook: fn consumer, _ ->
          {:ok, owned} = LoopexComposition.DiagnosticConsumer.owned_processes(consumer)
          send(caller, {:trace_owned, owned})
          {:error, :refused}
        end
      )

    assert DurableAsk.run(Map.put(options(), :trace, %{"enabled" => true}), @cwd, "prompt", seams) ==
             LoopexCli.AskResult.diagnostic(:trace_start_failed)

    assert_receive {:trace_owned, owned}
    Enum.each(owned, &refute(Process.alive?(&1)))
    refute :create in Agent.get(calls, & &1.calls)

    assert ordered?(Agent.get(calls, & &1.calls), [
             :trace,
             :callback_return,
             :credential_release,
             :placement_release
           ])
  end

  test "a stalled stderr writer is reaped without entering JSON stdout" do
    caller = self()

    device =
      spawn(fn ->
        receive do
          {:io_request, writer, _reply, _request} ->
            send(caller, {:stalled_trace_writer, writer})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> Process.exit(device, :kill) end)

    {seams, _calls} =
      harness(&completed_events/1,
        trace_hook: fn consumer, _ ->
          send(
            consumer,
            {:loopex_diagnostic, %{"kind" => "trace_call", "message" => "trace-only-secret"}}
          )

          assert_receive {:stalled_trace_writer, writer}
          send(caller, {:captured_trace_writer, writer})
          {:ok, %{active: true}}
        end
      )

    selected = Map.put(options(), :trace, %{"enabled" => true})

    assert %{status: 0, stderr: "", stdout: stdout} =
             DurableAsk.run(
               selected,
               @cwd,
               "prompt",
               Keyword.put(seams, :diagnostic_device, device)
             )

    assert_receive {:captured_trace_writer, writer}
    refute Process.alive?(writer)
    refute String.contains?(stdout, "trace-only-secret")
    assert %{"outcome" => "completed"} = JSON.decode!(String.trim_trailing(stdout, "\n"))
  end

  test "composition startup refusal still joins the prestarted diagnostic actors" do
    caller = self()
    {seams, _calls} = harness(&completed_events/1)

    with_runtime = fn selected, _callback ->
      consumer = selected[:diagnostics_to]
      {:ok, owned} = LoopexComposition.DiagnosticConsumer.owned_processes(consumer)
      send(caller, {:trace_owned, owned})
      {:error, :unavailable}
    end

    assert DurableAsk.run(
             Map.put(options(), :trace, %{"enabled" => true}),
             @cwd,
             "prompt",
             Keyword.put(seams, :with_runtime, with_runtime)
           ) ==
             LoopexCli.AskResult.diagnostic(:composition_unavailable)

    assert_receive {:trace_owned, owned}
    Enum.each(owned, &refute(Process.alive?(&1)))
  end

  test "composition cleanup uncertainty overrides the traced answer after diagnostic join" do
    caller = self()

    {seams, _calls} =
      harness(&completed_events/1,
        cleanup_replacement: true,
        trace_hook: fn consumer, _ ->
          {:ok, owned} = LoopexComposition.DiagnosticConsumer.owned_processes(consumer)
          send(caller, {:trace_owned, owned})
          {:ok, %{active: true}}
        end
      )

    assert DurableAsk.run(Map.put(options(), :trace, %{"enabled" => true}), @cwd, "prompt", seams) ==
             LoopexCli.AskResult.diagnostic(:runtime_cleanup_unconfirmed)

    assert_receive {:trace_owned, owned}
    Enum.each(owned, &refute(Process.alive?(&1)))
  end

  test "a lost diagnostic drain never certifies successful command cleanup" do
    caller = self()

    {seams, _calls} =
      harness(&completed_events/1,
        trace_hook: fn consumer, _ ->
          {:ok, owned} = LoopexComposition.DiagnosticConsumer.owned_processes(consumer)
          monitor = Process.monitor(consumer)
          Process.exit(consumer, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^consumer, :killed}
          send(caller, {:trace_owned, owned})
          {:ok, %{active: true}}
        end
      )

    assert DurableAsk.run(Map.put(options(), :trace, %{"enabled" => true}), @cwd, "prompt", seams) ==
             LoopexCli.AskResult.diagnostic(:runtime_cleanup_unconfirmed)

    assert_receive {:trace_owned, owned}
    Enum.each(owned, &refute(Process.alive?(&1)))
  end

  test "reader spawn failure restores the callback trap-exit flag" do
    previous = Process.flag(:trap_exit, false)

    try do
      assert_raise RuntimeError, "reader start failed", fn ->
        FollowReader.follow(:runtime, "session-1", "cli-prompt", 0, 1, [],
          facade: fn _, _, _ -> flunk("reader must not call the facade") end,
          monotonic_ms: fn -> 0 end,
          spawn_reader: fn _ -> raise "reader start failed" end
        )
      end

      assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "callback raise, throw and exit reap the linked reader and restore trap exits" do
    caller = self()
    previous = Process.flag(:trap_exit, false)

    try do
      for kind <- [:raise, :throw, :exit] do
        clock = fn ->
          case kind do
            :raise -> raise "callback fault"
            :throw -> throw(:callback_fault)
            :exit -> exit(:callback_fault)
          end
        end

        seams = [
          facade: fn _, _, _ ->
            receive do
              :never -> :ok
            end
          end,
          monotonic_ms: clock,
          spawn_reader: fn function ->
            {pid, monitor} = :erlang.spawn_opt(function, [:link, :monitor])
            send(caller, {:started_reader, pid})
            {pid, monitor}
          end
        ]

        case kind do
          :raise ->
            assert_raise RuntimeError, "callback fault", fn ->
              FollowReader.follow(:runtime, "session-1", "cli-prompt", 0, 1, [], seams)
            end

          :throw ->
            assert catch_throw(
                     FollowReader.follow(:runtime, "session-1", "cli-prompt", 0, 1, [], seams)
                   ) == :callback_fault

          :exit ->
            assert catch_exit(
                     FollowReader.follow(:runtime, "session-1", "cli-prompt", 0, 1, [], seams)
                   ) == :callback_fault
        end

        assert_receive {:started_reader, reader}
        refute Process.alive?(reader)
        assert Process.info(self(), :trap_exit) == {:trap_exit, false}
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "missing reader DOWN discards the projection and returns only its fixed diagnostic" do
    caller = self()

    seams = [
      facade: fn Loopex, :attach, _ -> {:error, :unavailable} end,
      monotonic_ms: fn -> System.monotonic_time(:millisecond) end,
      spawn_reader: fn function ->
        reader = spawn_link(function)
        send(caller, {:started_reader, reader})
        {reader, make_ref()}
      end
    ]

    started_at = System.monotonic_time(:millisecond)

    assert FollowReader.follow(:runtime, "session-1", "cli-prompt", started_at, 1, [], seams) ==
             {:diagnostic, :follow_reader_cleanup_unconfirmed}

    assert_receive {:started_reader, reader}
    refute Process.alive?(reader)
  end

  test "fresh durable ask orders ownership, tracks before attach and renders after release" do
    {seams, calls} = harness(&completed_events/1)

    result = DurableAsk.run(options(), @cwd, "say hello", seams)

    assert result.status == 0
    assert result.stderr == ""
    assert String.ends_with?(result.stdout, "\n")

    assert JSON.decode!(String.trim_trailing(result.stdout, "\n")) == %{
             "schema" => "loopex.ask/1",
             "session_id" => "session-1",
             "run_id" => "run-1",
             "profile" => "durable",
             "outcome" => "completed",
             "text" => "hello",
             "text_truncated" => false,
             "tools" => [],
             "tools_truncated" => false,
             "shadowed_skills" => [],
             "cleanup" => nil,
             "details" => %{"cleanup_grace_ms" => "5000"}
           }

    observed = Agent.get(calls, & &1.calls)

    assert ordered?(observed, [
             :skills,
             :placement_acquire,
             :runtime_id,
             :credential_open,
             :credential_plane,
             :provider_launch,
             :with_runtime,
             :create,
             :track,
             :command_attach,
             :status,
             :interrupt,
             :prompt,
             :reader_attach,
             :next_event,
             :callback_return,
             :credential_release,
             :placement_release
           ])

    assert Enum.count(observed, &(&1 == :credential_open)) == 1
    assert Enum.count(observed, &(&1 == :command_attach)) == 1
    assert Enum.count(observed, &(&1 == :reader_attach)) == 1
    refute :resource_command in observed

    composition = Agent.get(calls, & &1.composition)

    assert Keyword.keys(composition) ==
             ~w(runtime_id state_root workspace policy active_tools resource_manifest provider_launch recover_stale_writer credential_plane)a

    assert composition[:runtime_id] == "placement-1"
    assert composition[:state_root] == @root
    assert composition[:workspace] == @cwd
    assert composition[:active_tools] == ~w(loopex.read loopex.write loopex.edit loopex.bash)
    assert composition[:credential_plane] == :plane
    assert %{"packs" => []} = composition[:resource_manifest]
  end

  test "tracking failure leaves the known session and sends no attach or prompt" do
    {seams, calls} =
      harness(&completed_events/1, track: {:error, :after_publication_before_fsync})

    assert DurableAsk.run(options(), @cwd, "prompt", seams) == %{
             status: 1,
             stdout: "",
             stderr: "loopex: session_tracking_failed\n"
           }

    observed = Agent.get(calls, & &1.calls)

    assert ordered?(observed, [
             :create,
             :track,
             :callback_return,
             :credential_release,
             :placement_release
           ])

    refute :command_attach in observed
    refute :prompt in observed
  end

  test "credential refusal happens after helper, placement and identity, and releases placement" do
    {seams, calls} =
      harness(&completed_events/1, open_host: {:error, :provider_credential_required})

    assert DurableAsk.run(options(), @cwd, "prompt", seams) == %{
             status: 1,
             stdout: "",
             stderr: "loopex: provider_credential_required\n"
           }

    observed = Agent.get(calls, & &1.calls)

    assert ordered?(observed, [
             :skills,
             :placement_acquire,
             :runtime_id,
             :credential_open,
             :placement_release
           ])

    refute :with_runtime in observed
    refute :credential_plane in observed
  end

  test "runtime cleanup replacement discards an otherwise completed projection" do
    {seams, calls} = harness(&completed_events/1, cleanup_replacement: true)

    assert DurableAsk.run(options(), @cwd, "prompt", seams) == %{
             status: 1,
             stdout: "",
             stderr: "loopex: runtime_cleanup_unconfirmed\n"
           }

    assert ordered?(Agent.get(calls, & &1.calls), [
             :prompt,
             :callback_return,
             :credential_release,
             :placement_release
           ])
  end

  test "named skills admit, verify the exact catalog, and activate in bytewise order" do
    manifest = manifest([pack("zulu"), pack("alpha")])
    {seams, calls} = harness(&completed_events/1, manifest: manifest)

    assert %{status: 0} = DurableAsk.run(options(), @cwd, "prompt", seams)
    observed = Agent.get(calls, & &1.calls)

    assert ordered?(observed, [
             :command_attach,
             :resource_command,
             :catalog,
             :resource_command,
             :resource_command,
             :status,
             :prompt
           ])

    commands = Agent.get(calls, & &1.commands)

    assert Enum.map(commands, & &1.type) == [
             :admit_resources,
             :activate_skill,
             :activate_skill,
             :prompt
           ]

    {:ok, digest, _normalized} = Loopex.ResourcePack.digest(manifest)

    assert hd(commands).decision == %{
             "manifest_digest" => digest,
             "workspace_ref" => "workspace-1",
             "trust_scope" => "project_skills",
             "decision_source" => "host_supplied",
             "issued_at" => "2026-09-27T12:34:56Z",
             "expires_at" => nil,
             "revocation_state" => "active"
           }

    assert Enum.all?(Enum.slice(commands, 1, 2), &(&1.supporting_labels == []))

    assert Enum.map(Enum.slice(commands, 1, 2), & &1.name) == ["alpha", "zulu"]
    assert Enum.all?(commands, &String.match?(&1.command_id, ~r/\Acli-[0-9a-f]{32}\z/))
    assert commands |> Enum.map(& &1.command_id) |> Enum.uniq() |> length() == 4
  end

  test "catalog mismatch stops before activation, status and prompt" do
    manifest = manifest([pack("alpha")])

    {seams, calls} =
      harness(&completed_events/1, manifest: manifest, catalog: {:ok, %{"entries" => []}})

    assert DurableAsk.run(options(), @cwd, "prompt", seams) == %{
             status: 1,
             stdout: "",
             stderr: "loopex: resource_admission_failed\n"
           }

    observed = Agent.get(calls, & &1.calls)

    assert ordered?(observed, [:resource_command, :catalog, :callback_return, :credential_release])

    refute :status in observed
    refute :prompt in observed
  end

  test "catalog digest, disposition and tuple mismatches never activate a skill" do
    manifest = manifest([pack("alpha"), pack("zulu")])
    {:ok, digest, normalized} = Loopex.ResourcePack.digest(manifest)

    entries =
      Enum.map(normalized["packs"], fn pack ->
        %{
          "source_id" => pack["source_id"],
          "name" => pack["name"],
          "pack_digest" => Loopex.ResourcePack.pack_digest(pack)
        }
      end)

    valid = %{
      "configured_manifest_digest" => digest,
      "admitted_manifest_digest" => digest,
      "decision_disposition" => "active",
      "entries" => entries
    }

    invalid = [
      %{valid | "configured_manifest_digest" => "wrong"},
      %{valid | "admitted_manifest_digest" => "wrong"},
      %{valid | "decision_disposition" => "revoked"},
      %{valid | "entries" => tl(entries)},
      %{valid | "entries" => [hd(entries) | entries]},
      %{valid | "entries" => [%{hd(entries) | "pack_digest" => "wrong"} | tl(entries)]},
      %{valid | "entries" => [:malformed | tl(entries)]}
    ]

    for catalog <- invalid do
      {seams, calls} =
        harness(&completed_events/1, manifest: manifest, catalog: {:ok, catalog})

      assert %{status: 1, stdout: "", stderr: "loopex: resource_admission_failed\n"} =
               DurableAsk.run(options(), @cwd, "prompt", seams)

      observed = Agent.get(calls, & &1.calls)
      assert Enum.count(observed, &(&1 == :resource_command)) == 1
      refute :prompt in observed
    end
  end

  test "each activation failure stops before the next skill and prompt" do
    manifest = manifest([pack("alpha"), pack("zulu")])

    for failing_activation <- 1..2 do
      {:ok, count} = Agent.start_link(fn -> 0 end)

      reply = fn command ->
        if command.type == :activate_skill do
          index = Agent.get_and_update(count, fn n -> {n + 1, n + 1} end)

          if index == failing_activation,
            do: {:accepted, "wrong-id"},
            else: {:accepted, command.command_id}
        else
          {:accepted, command.command_id}
        end
      end

      {seams, calls} =
        harness(&completed_events/1, manifest: manifest, resource_reply: reply)

      assert %{status: 1, stdout: "", stderr: "loopex: skill_activation_failed\n"} =
               DurableAsk.run(options(), @cwd, "prompt", seams)

      assert Agent.get(count, & &1) == failing_activation
      refute :prompt in Agent.get(calls, & &1.calls)
    end
  end

  test "precomposition refusals keep their first boundary and avoid later authority" do
    cases = [
      {[read_directories: {:error, :skill_directory_unusable}], :skill_directories_unavailable,
       [:skills]},
      {[placement: {:error, :placement_active}], :durable_runtime_unavailable,
       [:skills, :placement_acquire]},
      {[runtime_id: {:error, :identity_failed}], :durable_runtime_unavailable,
       [:placement_acquire, :runtime_id, :placement_release]},
      {[runtime_id: {:ok, ""}], :durable_runtime_unavailable,
       [:placement_acquire, :runtime_id, :placement_release]},
      {[plane: {:error, :capability_failed}], :composition_unavailable,
       [:credential_open, :credential_plane, :placement_release]}
    ]

    for {overrides, code, ordered} <- cases do
      {seams, calls} = harness(&completed_events/1, overrides)

      assert DurableAsk.run(options(), @cwd, "prompt", seams) == %{
               status: 1,
               stdout: "",
               stderr: "loopex: #{code}\n"
             }

      observed = Agent.get(calls, & &1.calls)
      assert ordered?(observed, ordered)
      refute :create in observed
      refute :prompt in observed
    end

    {seams, calls} = harness(&completed_events/1)

    assert %{status: 1, stderr: "loopex: durable_model_unsupported\n"} =
             DurableAsk.run(%{options() | model: "ollama:local"}, @cwd, "prompt", seams)

    assert Agent.get(calls, & &1.calls) == [:skills]
  end

  test "each postcomposition boundary refuses without retrying its command" do
    cases = [
      {[create: {:error, :reply_lost}], :session_create_failed, :create,
       [:track, :command_attach, :prompt]},
      {[create: {:ok, ""}], :session_create_failed, :create, [:track, :command_attach, :prompt]},
      {[track: {:error, :before_publication}], :session_tracking_failed, :track,
       [:command_attach, :prompt]},
      {[attach: {:error, :unavailable}], :attachment_failed, :command_attach, [:status, :prompt]},
      {[status: {:ok, %{status: :active, cleanup_grace_ms: 0}}], :session_status_failed, :status,
       [:interrupt, :prompt]},
      {[prompt: {:accepted, "another-command"}], :prompt_submission_failed, :prompt,
       [:reader_attach]}
    ]

    for {overrides, code, reached, absent} <- cases do
      {seams, calls} = harness(&completed_events/1, overrides)

      assert DurableAsk.run(options(), @cwd, "prompt", seams) == %{
               status: 1,
               stdout: "",
               stderr: "loopex: #{code}\n"
             }

      observed = Agent.get(calls, & &1.calls)
      assert Enum.count(observed, &(&1 == reached)) == 1
      assert ordered?(observed, [:callback_return, :credential_release, :placement_release])
      Enum.each(absent, &refute(&1 in observed))
    end
  end

  test "resource admission and activation require exact accepted command ids" do
    manifest = manifest([pack("alpha")])

    for {reply, code, absent} <- [
          {{:accepted, "wrong"}, :resource_admission_failed, [:catalog, :status, :prompt]},
          {fn command ->
             if command.type == :activate_skill,
               do: {:accepted, "wrong"},
               else: {:accepted, command.command_id}
           end, :skill_activation_failed, [:status, :prompt]}
        ] do
      {seams, calls} = harness(&completed_events/1, manifest: manifest, resource_reply: reply)

      assert DurableAsk.run(options(), @cwd, "prompt", seams) == %{
               status: 1,
               stdout: "",
               stderr: "loopex: #{code}\n"
             }

      observed = Agent.get(calls, & &1.calls)
      Enum.each(absent, &refute(&1 in observed))
      assert :placement_release in observed
    end
  end

  test "follow joins by prompt command, ignores another run, and keeps the last selected text" do
    events = fn prompt_id ->
      [
        event(1, "assistant.message_appended", "old-run", %{"content" => "old"}),
        event(2, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
        event(3, "assistant.message_appended", "other-run", %{"content" => "wrong"}),
        event(4, "assistant.message_appended", "run-1", %{"content" => "first"}),
        event(5, "assistant.message_appended", "run-1", %{"content" => "last"}),
        event(6, "run.finished", "other-run", %{
          "outcome" => "completed",
          "cleanup_grace_ms" => 5_000
        }),
        event(7, "run.finished", "run-1", %{"outcome" => "completed", "cleanup_grace_ms" => 5_000})
      ]
    end

    {seams, _calls} = harness(events)
    %{status: 0, stdout: stdout} = DurableAsk.run(options(), @cwd, "prompt", seams)
    assert JSON.decode!(String.trim_trailing(stdout, "\n"))["text"] == "last"
  end

  test "duplicate matching join returns resumable no-ending and never publishes other run text" do
    events = fn prompt_id ->
      [
        event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
        event(2, "user.message_appended", "run-2", %{"command_id" => prompt_id})
      ]
    end

    {seams, _calls} = harness(events)
    %{status: 6, stdout: stdout} = DurableAsk.run(options(), @cwd, "prompt", seams)
    object = JSON.decode!(String.trim_trailing(stdout, "\n"))
    assert object["outcome"] == "no_ending"
    assert object["run_id"] == "run-1"
    assert object["details"]["reason"] == "session_unavailable"
    assert object["text"] == ""
  end

  test "expired follow before a join reports no ending with a null run id" do
    for {started, expired} <- [{0, 30_002}, {-1_000_000, -969_998}] do
      caller = self()
      {:ok, ticks} = Agent.start_link(fn -> 0 end)

      clock = fn ->
        if self() == caller do
          Agent.get_and_update(ticks, fn
            0 -> {started, 1}
            next -> {expired, next + 1}
          end)
        else
          started
        end
      end

      {seams, _calls} = harness(fn _ -> [] end, monotonic_ms: clock)

      %{status: 6, stdout: stdout} =
        DurableAsk.run(%{options() | deadline_ms: 1}, @cwd, "prompt", seams)

      object = JSON.decode!(String.trim_trailing(stdout, "\n"))
      assert object["run_id"] == nil
      assert object["outcome"] == "no_ending"
      assert object["details"] == %{"reason" => "timeout", "waited_ms" => "30002"}
    end
  end

  test "an accepted nonterminal at the exact follow deadline cannot admit a later terminal" do
    caller = self()
    {:ok, ticks} = Agent.start_link(fn -> 0 end)

    clock = fn ->
      if self() == caller do
        Agent.get_and_update(ticks, fn
          0 ->
            {0, 1}

          1 ->
            {0, 2}

          later ->
            Process.sleep(20)
            {30_001, later + 1}
        end)
      else
        0
      end
    end

    events = fn prompt_id ->
      [
        event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
        event(2, "assistant.message_appended", "run-1", %{"content" => "too late"}),
        event(3, "run.finished", "run-1", %{"outcome" => "completed", "cleanup_grace_ms" => 5_000})
      ]
    end

    {seams, _calls} = harness(events, monotonic_ms: clock)

    %{status: 6, stdout: stdout} =
      DurableAsk.run(%{options() | deadline_ms: 1}, @cwd, "prompt", seams)

    object = JSON.decode!(String.trim_trailing(stdout, "\n"))
    assert object["run_id"] == "run-1"
    assert object["outcome"] == "no_ending"
    assert object["text"] == ""
    assert object["details"] == %{"reason" => "timeout", "waited_ms" => "30001"}
  end

  test "a queued terminal returned at the exact follow deadline wins the zero-wait receive" do
    caller = self()
    prompt_id = "cli-prompt"

    {:ok, ticks} =
      Agent.start_link(fn ->
        %{
          caller_calls: 0,
          reads: 0,
          events: [
            event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
            event(2, "run.finished", "run-1", %{
              "outcome" => "completed",
              "cleanup_grace_ms" => 5_000
            })
          ]
        }
      end)

    facade = fn
      Loopex, :attach, [:runtime, "session-1", [after_event_sequence: 0]] ->
        {:ok, %Loopex.Attachment{}}

      Loopex, :next_event, [%Loopex.Attachment{}] ->
        Agent.get_and_update(ticks, fn %{events: [next | rest]} = state ->
          {{:ok, next}, %{state | events: rest, reads: state.reads + 1}}
        end)
    end

    clock = fn ->
      if self() == caller do
        call =
          Agent.get_and_update(ticks, fn state ->
            {state.caller_calls, %{state | caller_calls: state.caller_calls + 1}}
          end)

        if call < 2 do
          0
        else
          await_queued_terminal(5_000)
          30_001
        end
      else
        Agent.get(ticks, fn state -> if state.reads == 1, do: 0, else: 30_001 end)
      end
    end

    assert {:observation, {:ok, observation}} =
             FollowReader.follow(:runtime, "session-1", prompt_id, 0, 1, [],
               facade: facade,
               monotonic_ms: clock
             )

    assert observation.run_id == "run-1"
    assert observation.outcome == :completed
  end

  defp await_queued_terminal(0), do: flunk("terminal return was not queued")

  defp await_queued_terminal(attempts) do
    {:messages, messages} = Process.info(self(), :messages)

    if Enum.any?(messages, fn
         {_reader, _reference, {:ok, %{kind: "run.finished"}}, 30_001} -> true
         _ -> false
       end) do
      :ok
    else
      Process.sleep(1)
      await_queued_terminal(attempts - 1)
    end
  end

  test "failed terminal without an absent counterpart field still renders its exact public reason" do
    events = fn prompt_id ->
      [
        event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
        event(2, "run.finished", "run-1", %{
          "outcome" => "failed",
          "reason" => "model_call_failed",
          "cleanup_grace_ms" => 5_000
        })
      ]
    end

    {seams, _calls} = harness(events)
    %{status: 2, stdout: stdout} = DurableAsk.run(options(), @cwd, "prompt", seams)
    object = JSON.decode!(String.trim_trailing(stdout, "\n"))

    assert object["details"] == %{
             "reason" => "model_call_failed",
             "failure" => nil,
             "cleanup_grace_ms" => "5000"
           }
  end

  test "core deadline preflight failure renders as a failed run" do
    events = fn prompt_id ->
      [
        event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
        event(2, "run.finished", "run-1", %{
          "outcome" => "failed",
          "failure" => %{"category" => "deadline_preflight_failed", "retryable" => false},
          "cleanup_grace_ms" => 5_000
        })
      ]
    end

    {seams, _calls} = harness(events)
    %{status: 2, stdout: stdout} = DurableAsk.run(options(), @cwd, "prompt", seams)
    object = JSON.decode!(String.trim_trailing(stdout, "\n"))

    assert object["details"] == %{
             "reason" => nil,
             "failure" => %{
               "category" => "deadline_preflight_failed",
               "retryable" => false,
               "dimension" => nil,
               "observed" => nil,
               "limit" => nil
             },
             "cleanup_grace_ms" => "5000"
           }
  end

  test "two asks in one command process reuse the same credential host" do
    key = :"$loopex_cli_credential_host"
    previous = Process.get(key)
    Process.put(key, :host)

    try do
      {seams, calls} = harness(&completed_events/1)
      seams = Keyword.put(seams, :open_credential_host, &LoopexCli.CredentialCache.host/0)

      assert %{status: 0} = DurableAsk.run(options(), @cwd, "first", seams)
      assert %{status: 0} = DurableAsk.run(options(), @cwd, "second", seams)
      assert Process.get(key) == :host
      assert Enum.count(Agent.get(calls, & &1.calls), &(&1 == :credential_plane)) == 2
    after
      if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  test "durable terminal outcomes and text mode preserve their status and output contract" do
    cases = [
      {"cancelled", %{}, 5},
      {"bound_reached",
       %{
         "bound" => "max_turns",
         "observed" => 3,
         "declared_limit" => 3,
         "accounting_source" => nil
       }, 3},
      {"outcome_unknown", %{"reconciliation_ref" => "effect-1"}, 4},
      {"failed",
       %{
         "failure" => %{
           "category" => "context_budget_exceeded",
           "retryable" => false,
           "dimension" => "context_tokens",
           "observed" => 101,
           "limit" => 100
         }
       }, 2}
    ]

    for {outcome, detail, status} <- cases do
      events = fn prompt_id ->
        [
          event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
          event(
            2,
            "run.finished",
            "run-1",
            Map.merge(%{"outcome" => outcome, "cleanup_grace_ms" => 5_000}, detail)
          )
        ]
      end

      {seams, _calls} = harness(events)

      %{status: ^status, stdout: stdout, stderr: ""} =
        DurableAsk.run(options(), @cwd, "prompt", seams)

      object = JSON.decode!(String.trim_trailing(stdout, "\n"))
      assert object["outcome"] == outcome
      assert object["cleanup"] == nil
    end

    {seams, _calls} = harness(&completed_events/1)

    assert %{status: 0, stdout: "hello\n", stderr: "ending completed\n"} =
             DurableAsk.run(%{options() | output: "text"}, @cwd, "prompt", seams)
  end

  test "reader disconnect after prompt is a resumable no-ending observation" do
    events = fn prompt_id ->
      [
        event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
        {:return, {:disconnected, 1}}
      ]
    end

    {seams, _calls} = harness(events)
    %{status: 6, stdout: stdout} = DurableAsk.run(options(), @cwd, "prompt", seams)
    object = JSON.decode!(String.trim_trailing(stdout, "\n"))
    assert object["run_id"] == "run-1"
    assert object["details"]["reason"] == "session_unavailable"
  end

  test "reader attachment, sequence, join and process loss stay resumable" do
    malformed = [
      {fn _prompt_id -> [] end, [reader_attach: {:error, :unavailable}]},
      {fn prompt_id ->
         [event(0, "user.message_appended", "run-1", %{"command_id" => prompt_id})]
       end, []},
      {fn prompt_id ->
         [event(1, "user.message_appended", "", %{"command_id" => prompt_id})]
       end, []},
      {fn prompt_id ->
         [
           event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
           {:return, {:ok, %{event_sequence: 1, kind: "run.finished"}}}
         ]
       end, []}
    ]

    for {events, overrides} <- malformed do
      {seams, calls} = harness(events, overrides)
      %{status: 6, stdout: stdout} = DurableAsk.run(options(), @cwd, "prompt", seams)
      object = JSON.decode!(String.trim_trailing(stdout, "\n"))
      assert object["outcome"] == "no_ending"
      assert object["details"]["reason"] == "session_unavailable"
      assert :prompt in Agent.get(calls, & &1.calls)
    end

    {seams, _calls} = harness(&completed_events/1)
    original = Keyword.fetch!(seams, :facade)

    lost = fn
      Loopex, :next_event, _arguments -> exit(:reader_fault)
      module, function, arguments -> original.(module, function, arguments)
    end

    %{status: 6, stdout: stdout} =
      DurableAsk.run(options(), @cwd, "prompt", Keyword.put(seams, :facade, lost))

    assert JSON.decode!(String.trim_trailing(stdout, "\n"))["details"]["reason"] ==
             "session_unavailable"
  end

  test "selected text cuts on a UTF-8 boundary and tools retain the newest 256" do
    events = fn prompt_id ->
      join = event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id})

      text =
        event(2, "assistant.message_appended", "run-1", %{
          "content" => String.duplicate("a", 65_535) <> "€"
        })

      tools =
        for number <- 1..257 do
          event(number + 2, "tool.finished", "run-1", %{
            "tool_id" => "tool-#{number}",
            "outcome" => "completed"
          })
        end

      terminal =
        event(260, "run.finished", "run-1", %{
          "outcome" => "completed",
          "cleanup_grace_ms" => 5_000
        })

      [join, text] ++ tools ++ [terminal]
    end

    {seams, _calls} = harness(events)
    %{status: 0, stdout: stdout} = DurableAsk.run(options(), @cwd, "prompt", seams)
    object = JSON.decode!(String.trim_trailing(stdout, "\n"))
    assert object["text"] == String.duplicate("a", 65_535)
    assert object["text_truncated"] == true
    assert length(object["tools"]) == 256
    assert hd(object["tools"]) == %{"tool_id" => "tool-2", "outcome" => "completed"}
    assert List.last(object["tools"]) == %{"tool_id" => "tool-257", "outcome" => "completed"}
    assert object["tools_truncated"] == true
  end

  defp options do
    %{
      profile: :durable,
      state_root: @root,
      cwd: @cwd,
      skills: [],
      policy: LoopexCli.Policy.AllowAll,
      model: nil,
      tools: :coding,
      max_steps: nil,
      deadline_ms: nil,
      output: "json"
    }
  end

  defp harness(events, overrides \\ []) do
    manifest = Keyword.get(overrides, :manifest, manifest([]))
    {:ok, _, normalized} = Loopex.ResourcePack.digest(manifest)
    {:ok, digest, _} = Loopex.ResourcePack.digest(normalized)

    {:ok, calls} =
      Agent.start_link(fn ->
        %{
          calls: [],
          commands: [],
          events: [],
          prompt_id: nil,
          attachment_count: 0,
          ids: 0,
          composition: nil
        }
      end)

    record = fn item -> Agent.update(calls, &%{&1 | calls: &1.calls ++ [item]}) end

    facade = fn
      Loopex, :runtime_placement_id, [@root] ->
        record.(:runtime_id)
        Keyword.get(overrides, :runtime_id, {:ok, "placement-1"})

      Loopex, :create_session, [:runtime, %{"surface" => "cli"}, [command_id: id]] ->
        record.(:create)
        assert String.match?(id, ~r/\Acli-[0-9a-f]{32}\z/)
        Keyword.get(overrides, :create, {:ok, "session-1"})

      Loopex, :trace, [:runtime, configuration] ->
        record.(:trace)
        consumer = Agent.get(calls, & &1.composition)[:diagnostics_to]
        Keyword.fetch!(overrides, :trace_hook).(consumer, configuration)

      Loopex, :track_session, [@root, "session-1", "placement-1"] ->
        record.(:track)
        Keyword.get(overrides, :track, :ok)

      Loopex, :attach, [:runtime, "session-1", [after_event_sequence: 0]] ->
        kind =
          Agent.get_and_update(calls, fn state ->
            count = state.attachment_count + 1

            {if(count == 1, do: :command_attach, else: :reader_attach),
             %{state | attachment_count: count}}
          end)

        record.(kind)

        if kind == :command_attach,
          do: Keyword.get(overrides, :attach, {:ok, %Loopex.Attachment{}}),
          else: Keyword.get(overrides, :reader_attach, {:ok, %Loopex.Attachment{}})

      Loopex, :resource_catalog, [:runtime, "session-1"] ->
        record.(:catalog)

        Keyword.get(
          overrides,
          :catalog,
          {:ok,
           %{
             "configured_manifest_digest" => digest,
             "admitted_manifest_digest" => digest,
             "decision_disposition" => "active",
             "entries" =>
               Enum.map(normalized["packs"], fn pack ->
                 %{
                   "source_id" => pack["source_id"],
                   "name" => pack["name"],
                   "pack_digest" => Loopex.ResourcePack.pack_digest(pack)
                 }
               end)
           }}
        )

      Loopex, :session_status, [:runtime, "session-1"] ->
        record.(:status)
        Keyword.get(overrides, :status, {:ok, %{status: :active, cleanup_grace_ms: 5_000}})

      Loopex, :command, [%Loopex.Attachment{}, %{type: :prompt} = command] ->
        record.(:prompt)

        Agent.update(calls, fn state ->
          %{
            state
            | commands: state.commands ++ [command],
              prompt_id: command.command_id,
              events: events.(command.command_id)
          }
        end)

        Keyword.get(overrides, :prompt, {:accepted, command.command_id})

      Loopex, :command, [%Loopex.Attachment{}, command] ->
        record.(:resource_command)
        Agent.update(calls, &%{&1 | commands: &1.commands ++ [command]})

        case Keyword.get(overrides, :resource_reply) do
          nil -> {:accepted, command.command_id}
          function when is_function(function, 1) -> function.(command)
          reply -> reply
        end

      Loopex, :next_event, [%Loopex.Attachment{}] ->
        record.(:next_event)

        Agent.get_and_update(calls, fn state ->
          case state.events do
            [{:return, result} | tail] -> {result, %{state | events: tail}}
            [head | tail] -> {{:ok, head}, %{state | events: tail}}
            [] -> {{:error, :empty}, state}
          end
        end)
    end

    seams = [
      read_directories: fn _paths, [workspace: @cwd] ->
        record.(:skills)

        Keyword.get(
          overrides,
          :read_directories,
          {:ok, %{manifest: normalized, shadowed_skills: []}}
        )
      end,
      acquire_placement: fn @root ->
        record.(:placement_acquire)
        Keyword.get(overrides, :placement, {:ok, :lock})
      end,
      release_placement: fn :lock -> record.(:placement_release) end,
      facade: facade,
      open_credential_host: fn ->
        record.(:credential_open)
        Keyword.get(overrides, :open_host, {:ok, :host})
      end,
      credential_plane: fn :host ->
        record.(:credential_plane)
        Keyword.get(overrides, :plane, {:ok, :plane})
      end,
      release_credential_plane: fn :plane -> record.(:credential_release) end,
      provider_launch: fn ->
        record.(:provider_launch)
        []
      end,
      with_runtime: fn options, callback ->
        record.(:with_runtime)
        Agent.update(calls, &%{&1 | composition: options})
        returned = callback.(:runtime)
        record.(:callback_return)

        if Keyword.get(overrides, :cleanup_replacement, false),
          do: {:error, {:composition_cleanup_unconfirmed, %{private: :drop}}},
          else: returned
      end,
      interrupt_install: fn _attachment, 5_000 ->
        record.(:interrupt)
        :ok
      end,
      entropy: fn 16 ->
        next =
          Agent.get_and_update(calls, fn state ->
            {state.ids + 1, %{state | ids: state.ids + 1}}
          end)

        <<next::128>>
      end,
      utc_now: fn -> ~U[2026-09-27 12:34:56Z] end,
      monotonic_ms:
        Keyword.get(overrides, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)
    ]

    {seams, calls}
  end

  defp ordered?(observed, expected) do
    {_rest, found?} =
      Enum.reduce(expected, {observed, true}, fn wanted, {remaining, found?} ->
        case Enum.split_while(remaining, &(&1 != wanted)) do
          {_before, [_match | after_match]} -> {after_match, found?}
          _ -> {[], false}
        end
      end)

    found?
  end

  defp completed_events(prompt_id) do
    [
      event(1, "user.message_appended", "run-1", %{"command_id" => prompt_id}),
      event(2, "assistant.message_appended", "run-1", %{"content" => "hello"}),
      event(3, "run.finished", "run-1", %{"outcome" => "completed", "cleanup_grace_ms" => 5_000})
    ]
  end

  defp event(sequence, kind, run_id, data),
    do: Map.merge(%{"run_id" => run_id, event_sequence: sequence, kind: kind}, data)

  defp manifest(packs) do
    %{
      version: "loopex.resource_pack/1",
      workspace_ref: "workspace-1",
      revision: nil,
      packs: packs
    }
  end

  defp pack(name) do
    content = "---\nname: #{name}\ndescription: #{name}\n---\n"

    %{
      source_id: "project:#{name}",
      origin: nil,
      commit: nil,
      tree_digest: nil,
      name: name,
      description: "#{name} skill",
      manual_only: false,
      files: [
        %{
          label: "SKILL.md",
          size: byte_size(content),
          digest: Canonical.digest_bytes(content),
          content: content,
          contained: true
        }
      ]
    }
  end
end
