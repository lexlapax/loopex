Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatWorkflowTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias LoopexCli.{Chat, ChatConfiguration}
  alias Loopex.AgentLoopFixture, as: Fixture

  setup do
    root = Path.join(System.tmp_dir!(), "chat-workflow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "workspace"))
    File.mkdir!(Path.join(root, "state"))
    path = Path.join(root, "config.json")

    profile = %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_WORKFLOW_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "none",
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }

    File.write!(path, :json.encode(profile))
    {:ok, prepared} = ChatConfiguration.load(["chat", "--config", path], root, nil)
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, diagnostic} = StringIO.open("", encoding: :latin1)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      path: path,
      profile: profile,
      prepared: prepared,
      input: input,
      output: output,
      diagnostic: diagnostic
    }
  end

  test "dispatch joins two prompts, settings and cleanup before closing", f do
    fixture = fixture(f, [%{text: "first", calls: []}, %{text: "second", calls: []}])

    assert :ok =
             LoopexCli.dispatch(["chat", "--config", f.path], chat_options: options(f, fixture))

    records = controls(f.output)
    assert [first, second, quit] = Enum.filter(records, &(&1["event"] == "wait"))
    assert quit["run_id"] == second["run_id"]
    assert first["state"] == "settled" and second["state"] == "settled"
    assert first["session_id"] == second["session_id"]
    assert first["run_id"] != second["run_id"]
    assert List.last(records)["cleanup"] == "confirmed"
    assert List.last(records)["exit_code"] == 0
    assert [_, request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.any?(request.messages, &(&1["content"] == "one"))
    assert Enum.any?(request.messages, &(&1["content"] == "two"))
    {_, report} = StringIO.contents(f.diagnostic)
    assert report =~ "/session/model"
    refute report =~ "M7_WORKFLOW_SLOT"
    refute report =~ "model_capabilities"
    refute report =~ "provider_mapping"
  end

  test "resume uses the real prepared signal holder and retained conversation", f do
    isolated_signal_manager()
    original = fixture(f, [%{text: "first", calls: []}])

    {:ok, session} =
      Loopex.create_session(original.runtime, f.prepared.session_options,
        command_id: "create",
        genesis: f.prepared.genesis
      )

    assert :ok =
             Loopex.track_session(Path.join(f.root, "state"), session, "chat-workflow-runtime")

    {:ok, attachment} = Loopex.attach(original.runtime, session, after_event_sequence: 0)

    assert {:accepted, "first"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "first", content: "before"})

    assert await_terminal(attachment, System.monotonic_time(:millisecond) + 5000)["outcome"] ==
             "completed"

    assert :ok = Loopex.stop(original.runtime)

    resumed =
      Fixture.start(
        script: [%{text: "second", calls: []}],
        store: original.store,
        tools: [],
        model: f.prepared.selection.configuration["model"],
        runtime_id: "chat-workflow-runtime"
      )

    on_exit(fn -> Fixture.stop(resumed) end)
    changed = put_in(f.profile, ["session", "model"], "anthropic:unknown-file-default")
    File.write!(f.path, :json.encode(changed))
    {:ok, input} = StringIO.open("after\n/wait\n/quit\n", encoding: :latin1)

    opts =
      options(%{f | input: input}, resumed)
      |> Keyword.delete(:install_signal)
      |> Keyword.delete(:finish_signal)

    result = Chat.run(["chat", "--config", f.path, "--resume", session], opts)
    assert result == 0, inspect(controls(f.output))
    assert [request] = Loopex.AgentLoopTestModel.dispatched(resumed.model)
    assert Enum.any?(request.messages, &(&1["content"] == "before"))
    assert Enum.any?(request.messages, &(&1["content"] == "after"))
    assert List.last(controls(f.output))["cleanup"] == "confirmed"
    {_, report} = StringIO.contents(f.diagnostic)
    assert report =~ "committed"
    refute report =~ "M7_WORKFLOW_SLOT"
  end

  test "unconfirmed composition makes a locally clean ending unknown", f do
    fixture = fixture(f, [%{text: "first", calls: []}, %{text: "second", calls: []}])
    assert Chat.run(["chat", "--config", f.path], options(f, fixture, :unconfirmed)) == 1
    assert List.last(controls(f.output))["cleanup"] == "unknown"
    assert List.last(controls(f.output))["exit_code"] == 1
  end

  test "signal refusal stops attachments before reading a prompt", f do
    fixture = fixture(f, [])

    opts =
      Keyword.put(options(f, fixture), :install_signal, fn _, _, _, _ ->
        {:error, :interrupt_handler_unavailable}
      end)

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert {"one\n/wait\ntwo\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Enum.any?(controls(f.output), &(&1["code"] == "chat_signal_start_failed"))
    assert List.last(controls(f.output))["cleanup"] == "confirmed"
  end

  test "installer failure joins transport workers before outer cleanup", f do
    fixture = fixture(f, [])
    test = self()

    opts =
      Keyword.put(options(f, fixture), :install_signal, fn driver, _, _, _ ->
        send(test, {:driver, driver})
        raise "private failure must not reach output"
      end)

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert_receive {:driver, driver}
    refute Process.alive?(driver)
    assert {"one\n/wait\ntwo\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    {_, transcript} = StringIO.contents(f.output)
    refute transcript =~ "private failure"
    assert List.last(controls(f.output))["cleanup"] == "confirmed"
  end

  test "replaced workspace refuses before reading input", f do
    fixture = fixture(f, [])

    opts =
      Keyword.put(options(f, fixture), :install_signal, fn _, _, _, nil ->
        File.rename!(Path.join(f.root, "workspace"), Path.join(f.root, "original"))
        File.mkdir!(Path.join(f.root, "workspace"))
        {:ok, self()}
      end)

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert {"one\n/wait\ntwo\n/wait\n/quit\n", ""} == StringIO.contents(f.input)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Enum.any?(controls(f.output), &(&1["code"] == "chat_activation_failed"))
  end

  test "malformed file opens no placement or runtime", f do
    File.write!(f.path, "{\"schema_version\":1,\"schema_version\":1}")

    opts =
      basic(f) ++
        [
          acquire_placement: fn _, _ -> flunk("early placement") end,
          with_runtime: fn _, _ -> flunk("early composition") end
        ]

    assert Chat.run(["chat", "--config", f.path], opts) == 1

    assert [%{"event" => "error"}, %{"event" => "closing", "cleanup" => "confirmed"}] =
             controls(f.output)
  end

  test "resource refusal precedes placement and credential acquisition", f do
    opts =
      basic(f) ++
        [
          read_directories: fn _, _ -> {:error, :skill_directory_unavailable} end,
          acquire_placement: fn _, _ -> flunk("early placement") end,
          with_runtime: fn _, _ -> flunk("early composition") end
        ]

    assert Chat.run(["chat", "--config", f.path], opts) == 1
    assert List.last(controls(f.output))["cleanup"] == "confirmed"
  end

  defp fixture(f, script) do
    fixture =
      Fixture.start(
        script: script,
        tools: [],
        model: f.prepared.selection.configuration["model"],
        runtime_id: "chat-workflow-runtime",
        cleanup_grace_ms: f.prepared.selection.profile["session"]["cleanup_grace_ms"]
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp basic(f),
    do: [
      cwd: f.root,
      home: nil,
      input: f.input,
      output: f.output,
      diagnostic_device: f.diagnostic,
      mode: :pipe
    ]

  defp options(f, fixture, cleanup \\ :confirmed) do
    basic(f) ++
      [
        acquire_placement: fn _, probe ->
          assert is_function(probe, 1)
          {:ok, "test-placement"}
        end,
        release_placement: fn "test-placement", _ ->
          refute Enum.any?(controls(f.output), &(&1["event"] == "closing"))
          :ok
        end,
        placement_id: fn _ -> {:ok, "chat-workflow-runtime"} end,
        with_runtime: fn options, callback ->
          assert options[:provider_bindings] == f.profile["providers"]
          assert options[:active_tools] == []
          result = callback.(fixture.runtime)
          refute Enum.any?(controls(f.output), &(&1["event"] == "closing"))
          assert :ok == Loopex.stop(fixture.runtime)

          if cleanup == :unconfirmed,
            do: {:error, {:composition_cleanup_unconfirmed, %{runtime: :unconfirmed}}},
            else: result
        end,
        install_signal: fn _, _, _, _ ->
          assert StringIO.contents(f.input) == {"one\n/wait\ntwo\n/wait\n/quit\n", ""}
          {:ok, self()}
        end,
        finish_signal: fn _, _ -> {:ok, :ordinary} end
      ]
  end

  defp isolated_signal_manager do
    original = Process.whereis(:erl_signal_server)
    {:ok, manager} = :gen_event.start()
    :ok = :gen_event.add_handler(manager, :erl_signal_handler, [])
    Process.unregister(:erl_signal_server)
    true = Process.register(manager, :erl_signal_server)

    on_exit(fn ->
      if Process.whereis(:erl_signal_server) == manager,
        do: Process.unregister(:erl_signal_server)

      if Process.alive?(manager), do: :gen_event.stop(manager)

      if is_pid(original) and Process.alive?(original),
        do: Process.register(original, :erl_signal_server)
    end)
  end

  defp await_terminal(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        event

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("first prompt did not settle")

        Process.sleep(1)
        await_terminal(attachment, deadline)
    end
  end

  defp controls(output) do
    {_, transcript} = StringIO.contents(output)
    for "@loopex " <> json <- String.split(transcript, "\n"), do: :json.decode(json)
  end
end
