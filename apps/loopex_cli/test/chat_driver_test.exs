Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatDriverTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias LoopexCli.ChatDriver
  alias Loopex.AgentLoopFixture, as: Fixture

  test "new chat stages captured workspace facts and every selected immutable tool schema" do
    for profile <- ~w(none coding read-only) do
      prepared = prepared_configuration(profile)
      definitions = prepared.genesis["tool_selection"]["definitions"]
      captured = prepared.selection.configuration["instructions"]
      facts = JSON.decode!(captured["environment"])
      assert facts["workspace"] == prepared.selection.profile["paths"]["workspace"]
      assert facts["tool_profile"] == profile
      assert Enum.sort(Map.keys(facts)) == ~w(platform tool_profile workspace)
      assert Enum.sort(Map.keys(facts["platform"])) == ~w(architecture os)
      {_, native_os} = :os.type()

      assert facts["platform"]["os"] ==
               if(native_os in [:darwin, :linux], do: Atom.to_string(native_os), else: "other")

      fixture =
        start_fixture([%{text: "done", calls: []}],
          model: prepared.selection.configuration["model"],
          tools: definitions
        )

      {:ok, session} =
        Loopex.create_session(fixture.runtime, prepared.session_options,
          command_id: "create",
          genesis: prepared.genesis
        )

      {:ok, input} = StringIO.open("inspect this workspace\n/wait\n/quit\n", encoding: :latin1)
      {:ok, output} = StringIO.open("", encoding: :latin1)

      {:ok, driver} =
        ChatDriver.start_link(fixture.runtime, session, input, output, configuration: prepared)

      assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
      assert ChatDriver.close(driver, :confirmed) == 0
      [request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
      {:ok, rendered} = Loopex.Runtime.Instructions.render(captured)
      assert hd(request.messages) == %{"role" => "system", "content" => rendered}
      assert request.tools == definitions

      assert Enum.sort(Enum.map(request.tools, & &1["tool_id"])) ==
               Enum.sort(prepared.active_tools)

      assert Agent.get(fixture.executor, & &1.jobs) == []
      refute rendered =~ "M7_CHAT_DRIVER_SLOT"
      assert Fixture.records(fixture, session) |> hd() |> Map.fetch!(:payload) == prepared.genesis
    end
  end

  test "configure admission updates the host cache only after owner confirmation" do
    prepared = prepared_configuration()

    fixture =
      start_fixture([%{text: "first", calls: []}, %{text: "second", calls: []}],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, instructions} =
      Loopex.Runtime.Instructions.capture(%{
        "version" => "chat.configured.v1",
        "base" => "configured-instruction-canary",
        "environment" => "",
        "appendix" => ""
      })

    changes = %{
      "model" => "anthropic:claude-haiku-4-5",
      "reasoning" => "none",
      "instructions" => instructions,
      "max_tokens" => 4096,
      "context_token_budget" => 16_000,
      "system_class_tokens" => 4000
    }

    bytes =
      "one\n/wait\n/configure {\"max_tokens\":2048}\n/configure {\"max_tokens\":999999}\n/configure " <>
        IO.iodata_to_binary(:json.encode(changes)) <> "\ntwo\n/wait\n/quit\n"

    {:ok, input} = StringIO.open(bytes, encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, output,
        configuration: prepared,
        mode: :interactive
      )

    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    [first, second] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert first.sampling["max_tokens"] == 1024
    refute Map.has_key?(first.sampling, "reasoning")
    assert second.sampling["max_tokens"] == 4096
    assert second.sampling["reasoning"] == "none"
    assert second.sampling["provider_mapping"]["thinking_disabled"]
    {:ok, rendered} = Loopex.Runtime.Instructions.render(instructions)
    assert hd(second.messages)["content"] == rendered
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 3
    assert status.configuration["max_tokens"] == 4096
    assert status.configuration["reasoning"] == "none"
    assert status.configuration["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert status.configuration["context_token_budget"] == 16_000
    assert status.configuration["system_class_tokens"] == 4000
    assert status.configuration["instructions"] == Map.take(instructions, ~w(version digest))
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "session.configured")) == 2
    {_, transcript} = StringIO.contents(output)
    refute transcript =~ "configured-instruction-canary"
    acks = Enum.filter(records(transcript), &(&1["event"] == "input"))
    assert Enum.map(acks, & &1["input_sequence"]) == Enum.map(1..8, &Integer.to_string/1)

    assert Enum.map(acks, & &1["disposition"]) ==
             ~w(admitted admitted admitted refused admitted admitted admitted admitted)

    assert length(Enum.uniq(Enum.map(acks, & &1["command_id"]))) == 8
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "configure unknown observes its exact command without reissuing or reading another input" do
    prepared = prepared_configuration()
    fixture = start_fixture([], model: prepared.selection.configuration["model"])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    {:ok, input} = StringIO.open("/configure {\"max_tokens\":2048}\nnever\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    test = self()

    facade = fn module, function, args ->
      case function do
        :command_with_configuration ->
          assert {:accepted, id} = apply(module, function, args)
          send(test, {:configured, id})
          {:error, :commit_unknown}

        :command_disposition ->
          send(test, {:observed_configure, List.last(args)})
          apply(module, function, args)

        _ ->
          apply(module, function, args)
      end
    end

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, output,
        configuration: prepared,
        facade: facade
      )

    assert %{exit_code: 1, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 1
    assert_receive {:configured, id}
    assert_receive {:observed_configure, ^id}
    refute_receive {:configured, _}
    assert {"never\n", ""} = StringIO.contents(input)
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 2
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "session.configured")) == 1
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    {_, transcript} = StringIO.contents(output)

    assert [%{"disposition" => "unknown", "code" => "commit_unknown"}] =
             Enum.filter(records(transcript), &(&1["event"] == "input"))
  end

  test "busy configure refusal does not advance the cache used after the wait barrier" do
    prepared = prepared_configuration()

    fixture =
      start_fixture([%{text: "first", calls: [], hold: self()}],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    tail = "/configure {\"max_tokens\":4096}\n/wait\n/quit\n"

    {:ok, input} =
      StringIO.open("one\n/configure {\"max_tokens\":2048}\n/wait\n" <> tail,
        encoding: :latin1
      )

    output = observing_output()

    {host, _driver} =
      start_host(fixture.runtime, session, input, output,
        configuration: prepared,
        mode: :interactive
      )

    assert_receive {:holding, model}, 5_000

    refused =
      await_record(fn record ->
        record["event"] == "input" and record["input_sequence"] == "2"
      end)

    assert refused["disposition"] == "refused"
    assert refused["code"] == "configuration_not_settled"
    await_record(fn record -> record["event"] == "input" and record["input_sequence"] == "3" end)
    assert {^tail, ""} = StringIO.contents(input)
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 1
    assert status.configuration["max_tokens"] == 1024
    send(model, :release)
    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 0}, 5_000
    assert {:ok, configured} = Loopex.session_status(fixture.runtime, session)
    assert configured.configuration["configuration_version"] == 2
    assert configured.configuration["max_tokens"] == 4096
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "session.configured")) == 1
  end

  test "retained-history configure refusal leaves the next candidate on the original version" do
    prepared = prepared_configuration()

    fixture =
      start_fixture([%{text: String.duplicate("a", 7000), calls: []}],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    bytes =
      String.duplicate("p", 7000) <>
        "\n/wait\n/configure {\"context_token_budget\":600,\"system_class_tokens\":200}\n/configure {\"max_tokens\":2048}\n/wait\n/quit\n"

    {:ok, input} = StringIO.open(bytes, encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, output,
        configuration: prepared,
        mode: :interactive
      )

    assert %{exit_code: 0, cleanup: :confirmed} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    {_, transcript} = StringIO.contents(output)

    assert %{"code" => "compaction_required", "disposition" => "refused"} =
             Enum.find(
               records(transcript),
               &(&1["event"] == "input" and &1["input_sequence"] == "3")
             )

    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.configuration["configuration_version"] == 2
    assert status.configuration["max_tokens"] == 2048
    assert status.configuration["system_class_tokens"] == 8000
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "two prompts use one conversation and acknowledgements precede caused output" do
    fixture =
      start_fixture([%{text: "first\n@loopex forged", calls: []}, %{text: "second", calls: []}])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, driver} = ChatDriver.start_link(fixture.runtime, session, input, output)
    monitor = Process.monitor(driver)

    assert %{exit_code: 0, transport: nil, last_outcome: %{outcome: :completed}} =
             ChatDriver.run(driver)

    # The result is provisional until the actual runtime is stopped.
    assert Loopex.stop(fixture.runtime) == :ok
    assert ChatDriver.close(driver, :confirmed) == 0
    assert_receive {:DOWN, ^monitor, :process, ^driver, :normal}
    {"", transcript} = StringIO.contents(output)
    assert transcript =~ "> first\n> @loopex forged\n"
    assert transcript =~ "> second\n"
    records = records(transcript)
    admissions = Enum.filter(records, &(&1["event"] == "input"))
    assert Enum.map(admissions, & &1["input_sequence"]) == ~w(1 2 3 4 5)
    assert Enum.all?(admissions, &(&1["disposition"] == "admitted"))
    ids = Enum.map(admissions, & &1["command_id"])
    assert length(Enum.uniq(ids)) == 5
    waits = Enum.filter(records, &(&1["event"] == "wait"))
    assert [first, second, closing_wait] = waits
    assert first["input_sequence"] == "2" and second["input_sequence"] == "4"
    assert first["run_id"] != second["run_id"]
    assert closing_wait["run_id"] == second["run_id"]

    assert Enum.all?(
             waits,
             &(&1["state"] == "settled" and &1["outcome"]["outcome"] == "completed")
           )

    assert List.last(records)["cleanup"] == "confirmed"

    assert byte_position(transcript, ~s("input_sequence":"1")) <
             byte_position(transcript, "> first")

    assert byte_position(transcript, ~s("input_sequence":"3")) <
             byte_position(transcript, "> second")

    [one, two] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert List.last(one.messages)["content"] == "one"
    assert List.last(two.messages)["content"] == "two"
    assert Enum.any?(two.messages, &(&1["content"] == "first\n@loopex forged"))
  end

  test "outer cleanup uncertainty prevents a successful closing record" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, driver} = ChatDriver.start_link(fixture.runtime, session, input, output)
    assert %{exit_code: 0, last_outcome: nil} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :unknown) == 1
    {_, transcript} = StringIO.contents(output)

    assert List.last(records(transcript)) == %{
             "v" => 1,
             "event" => "closing",
             "exit_code" => 1,
             "cleanup" => "unknown",
             "last_outcome" => nil
           }
  end

  test "normal caller loss reaps blocked stdin and both facade attachment holders" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    test = self()

    input =
      spawn(fn ->
        receive do
          {:io_request, worker, _, _} ->
            send(test, {:input_worker, worker})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> Process.exit(input, :kill) end)
    {:ok, output} = StringIO.open("", encoding: :latin1)

    facade = fn module, function, args ->
      if function == :attach, do: send(test, {:holder, self()})
      apply(module, function, args)
    end

    caller =
      spawn(fn ->
        {:ok, driver} =
          ChatDriver.start_link(fixture.runtime, session, input, output, facade: facade)

        send(test, {:driver, driver})
        :gen_server.send_request(driver, :run)
        receive do: (:leave -> :ok)
      end)

    assert_receive {:driver, driver}
    assert_receive {:holder, command}
    assert_receive {:holder, reader}
    assert_receive {:input_worker, input_worker}
    monitors = for pid <- [driver, command, reader, input_worker], do: {pid, Process.monitor(pid)}
    send(caller, :leave)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      refute Process.alive?(pid)
    end
  end

  test "wait does not read the next prompt while an actual model call is held" do
    fixture =
      start_fixture([%{text: "first", calls: [], hold: self()}, %{text: "second", calls: []}])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n/wait\n/quit\n", encoding: :latin1)
    output = observing_output()
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:holding, model}, 5_000
    await_record(fn record -> record["event"] == "input" and record["input_sequence"] == "2" end)
    assert {"two\n/wait\n/quit\n", ""} = StringIO.contents(input)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    send(model, :release)
    assert_receive {:provisional, ^host, %{exit_code: 0, cleanup: :confirmed}}, 5_000
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 0}, 5_000
    refute Process.alive?(driver)
  end

  test "interrupt is responsive while stdin is blocked and joins its exact reader" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    test = self()

    input =
      spawn(fn ->
        receive do
          {:io_request, worker, _, _} ->
            send(test, {:blocked_input, worker})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> Process.exit(input, :kill) end)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {host, driver} = start_host(fixture.runtime, session, input, output)
    assert_receive {:blocked_input, reader}
    monitor = Process.monitor(reader)
    ChatDriver.interrupt(driver)
    assert_receive {:provisional, ^host, %{exit_code: 1, cleanup: :confirmed}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 1}
    {_, transcript} = StringIO.contents(output)
    assert List.last(records(transcript))["cleanup"] == "confirmed"
  end

  test "the actual model question and wait barrier retain one opaque identity and exact answer" do
    definition = LoopexProtocol.ToolDefinition.question_definition()

    fixture =
      start_fixture(
        [
          %{
            text: "Which?",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "answered", calls: []}
        ],
        tools: [definition]
      )

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    input = pipe_input("one\n/wait\n")
    output = observing_output()
    {host, _driver} = start_host(fixture.runtime, session, input, output)
    question = await_record(&(&1["event"] == "question"))
    barrier = await_record(&(&1["event"] == "wait"))
    assert question["producer"] == "model_tool"
    assert question["kind"] == "text" and question["choices"] == []
    assert barrier["state"] == "question"
    assert barrier["interaction_id"] == question["interaction_id"]

    send(
      input,
      {:bytes,
       "/answer " <>
         question["interaction_id"] <> ~s( --text " keep --choice literal ") <> "\n/wait\n/quit\n"}
    )

    assert_receive {:provisional, ^host, %{exit_code: 0, last_outcome: %{outcome: :completed}}},
                   5_000

    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 0}, 5_000
    [_first, second] = Loopex.AgentLoopTestModel.dispatched(fixture.model)

    assert Enum.any?(
             second.messages,
             &(&1["role"] == "tool" and &1["content"] == " keep --choice literal ")
           )

    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "a lost command acknowledgement observes its exact identity before shutdown and never retries" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    test = self()

    facade = fn module, function, args ->
      case {function, args} do
        {:command, [attachment, %{type: :prompt} = command]} ->
          send(test, {:admitted_prompt, command.command_id})
          assert {:accepted, _} = Loopex.command(attachment, command)
          {:error, :commit_unknown}

        {:command, [_, %{type: :abort} = command]} ->
          send(test, {:shutdown_command, command.command_id})
          apply(module, function, args)

        {:command_disposition, [_, id]} ->
          send(test, {:observed_command, id})
          apply(module, function, args)

        _ ->
          apply(module, function, args)
      end
    end

    {host, _} = start_host(fixture.runtime, session, input, output, facade: facade)
    assert_receive {:admitted_prompt, command_id}
    assert_receive {:observed_command, ^command_id}
    assert_receive {:shutdown_command, shutdown_id}
    assert shutdown_id != command_id
    assert_receive {:provisional, ^host, %{exit_code: 1}}, 5_000
    refute_receive {:admitted_prompt, _}, 0
    assert {"/wait\ntwo\n", ""} = StringIO.contents(input)
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 1}
    {_, transcript} = StringIO.contents(output)
    assert [ack] = Enum.filter(records(transcript), &(&1["event"] == "input"))
    assert ack["disposition"] == "unknown" and ack["code"] == "commit_unknown"
    assert ack["command_id"] == LoopexProtocol.Wire.encode_identity(command_id)
  end

  test "second interrupt joins a blocked admission worker without inventing an abort acknowledgement" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\ntwo\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    test = self()

    facade = fn module, function, args ->
      case {function, args} do
        {:command, [attachment, %{type: :prompt} = command]} ->
          assert {:accepted, _} = Loopex.command(attachment, command)
          send(test, {:blocked_admission, self(), command.command_id})
          receive do: (:release -> {:error, :commit_unknown})

        {:command, [_, %{type: :abort}]} ->
          send(test, :unexpected_abort)
          apply(module, function, args)

        _ ->
          apply(module, function, args)
      end
    end

    {host, driver} = start_host(fixture.runtime, session, input, output, facade: facade)
    assert_receive {:blocked_admission, worker, id}
    worker_monitor = Process.monitor(worker)
    ChatDriver.interrupt(driver)
    initial = :sys.get_state(driver)
    assert is_integer(initial.deadline)
    ChatDriver.interrupt(driver)
    assert_receive {:provisional, ^host, %{exit_code: 1, cleanup: :unknown}}, 5_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    refute_receive :unexpected_abort, 0
    assert :sys.get_state(driver).deadline == initial.deadline
    assert {"/wait\ntwo\n", ""} = StringIO.contents(input)
    assert Loopex.stop(fixture.runtime) == :ok
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 1}
    {_, transcript} = StringIO.contents(output)
    assert [ack] = Enum.filter(records(transcript), &(&1["event"] == "input"))
    assert ack["disposition"] == "unknown"
    assert [barrier] = Enum.filter(records(transcript), &(&1["event"] == "wait"))
    assert barrier["outcome"] == "commit_unknown"
    assert barrier["command_id"] == LoopexProtocol.Wire.encode_identity(id)
    assert List.last(records(transcript))["cleanup"] == "unknown"
  end

  test "broken output returns a fixed transport failure after worker joins" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("/wait\n/quit\n", encoding: :latin1)

    output =
      spawn(fn ->
        receive do
          {:io_request, writer, reply, _} ->
            send(writer, {:io_reply, reply, {:error, :private_failure}})
        end
      end)

    on_exit(fn -> if Process.alive?(output), do: Process.exit(output, :kill) end)
    {:ok, driver} = ChatDriver.start_link(fixture.runtime, session, input, output)
    assert %{exit_code: 1, transport: :output_failed} = ChatDriver.run(driver)
    assert :sys.get_state(driver).workers == %{}
    assert Loopex.stop(fixture.runtime) == :ok
    assert ChatDriver.close(driver, :confirmed) == 1
  end

  test "attachment-holder death preserves pending admission uncertainty and reaps remaining actors" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/wait\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    test = self()

    facade = fn module, function, args ->
      case {function, args} do
        {:command, [_, %{type: :prompt} = command]} ->
          send(test, {:pending_admission, self(), command.command_id})
          receive do: (:release -> apply(module, function, args))

        _ ->
          apply(module, function, args)
      end
    end

    {host, driver} = start_host(fixture.runtime, session, input, output, facade: facade)
    assert_receive {:pending_admission, worker, id}
    Process.exit(worker, :kill)

    assert_receive {:provisional, ^host,
                    %{exit_code: 1, transport: :chat_worker_failed, cleanup: :unknown}},
                   5_000

    assert :sys.get_state(driver).workers == %{}
    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 1}
    {_, transcript} = StringIO.contents(output)
    barrier = Enum.find(records(transcript), &(&1["event"] == "wait"))
    assert barrier["outcome"] == "commit_unknown"
    assert barrier["command_id"] == LoopexProtocol.Wire.encode_identity(id)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
  end

  test "a malformed complete command is refused before the next valid prompt" do
    fixture = start_fixture([%{text: "done", calls: []}])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("/answer broken\none\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)

    {:ok, driver} =
      ChatDriver.start_link(fixture.runtime, session, input, output, mode: :interactive)

    assert %{exit_code: 0, transport: nil} = ChatDriver.run(driver)
    assert ChatDriver.close(driver, :confirmed) == 0
    {_, transcript} = StringIO.contents(output)

    assert [refused, prompt, wait, quit] =
             Enum.filter(records(transcript), &(&1["event"] == "input"))

    assert refused["disposition"] == "refused" and refused["code"] == "invalid_chat_answer"
    assert Enum.map([refused, prompt, wait, quit], & &1["input_sequence"]) == ~w(1 2 3 4)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "pipe syntax refusal stops before a following prompt and exits nonzero" do
    fixture = start_fixture([])
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("/answer broken\nshould remain unread\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, driver} = ChatDriver.start_link(fixture.runtime, session, input, output)
    assert %{exit_code: 1, last_outcome: nil} = ChatDriver.run(driver)
    assert {"should remain unread\n", ""} = StringIO.contents(input)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert ChatDriver.close(driver, :confirmed) == 1
  end

  test "captured invocation bounds reach each prompt while queued follow-up inherits the active run" do
    fixture =
      start_fixture([
        %{text: "first", calls: [], hold: self()},
        %{text: "followed", calls: [], hold: self()}
      ])

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, input} = StringIO.open("one\n/follow-up next\n/wait\n/quit\n", encoding: :latin1)
    output = observing_output()
    huge = Integer.pow(10, 40)
    bounds = %{max_turns: huge, token_budget: huge + 1, deadline_ms: 60_000}
    {host, _} = start_host(fixture.runtime, session, input, output, bounds: bounds)
    assert_receive {:holding, first_worker}, 5_000
    await_record(fn record -> record["event"] == "input" and record["input_sequence"] == "3" end)
    assert {:ok, first_status} = Loopex.session_status(fixture.runtime, session)
    [first_request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert first_status.active_bounds == Map.put(bounds, :deadline, first_request.deadline)
    assert {"/quit\n", ""} = StringIO.contents(input)
    send(first_worker, :release)
    assert_receive {:holding, second_worker}, 5_000
    assert {:ok, second_status} = Loopex.session_status(fixture.runtime, session)
    [^first_request, second_request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert first_status.active_run_id != second_status.active_run_id
    assert second_status.active_bounds == Map.put(bounds, :deadline, second_request.deadline)
    assert {"/quit\n", ""} = StringIO.contents(input)
    send(second_worker, :release)

    assert_receive {:provisional, ^host, %{exit_code: 0, last_outcome: %{outcome: :completed}}},
                   5_000

    send(host, {:close, :confirmed})
    assert_receive {:closed, ^host, 0}, 5_000
  end

  defp pipe_input(bytes) do
    device = spawn(fn -> input_loop(bytes, nil) end)
    on_exit(fn -> Process.exit(device, :kill) end)
    device
  end

  defp input_loop(<<byte, rest::binary>>, {worker, reply}) do
    send(worker, {:io_reply, reply, <<byte>>})
    input_loop(rest, nil)
  end

  defp input_loop(bytes, pending) do
    receive do
      {:io_request, worker, reply, {:get_chars, _, _, 1}} -> input_loop(bytes, {worker, reply})
      {:bytes, next} -> input_loop(bytes <> next, pending)
    end
  end

  defp start_host(runtime, session, input, output, options \\ []) do
    test = self()

    host =
      spawn(fn ->
        {:ok, driver} = ChatDriver.start_link(runtime, session, input, output, options)
        send(test, {:host_driver, self(), driver})
        send(test, {:provisional, self(), ChatDriver.run(driver)})

        receive do
          {:close, cleanup} -> send(test, {:closed, self(), ChatDriver.close(driver, cleanup)})
        end
      end)

    on_exit(fn -> if Process.alive?(host), do: Process.exit(host, :kill) end)
    assert_receive {:host_driver, ^host, driver}
    {host, driver}
  end

  defp observing_output do
    test = self()
    device = spawn(fn -> output_loop(test) end)
    on_exit(fn -> Process.exit(device, :kill) end)
    device
  end

  defp output_loop(test) do
    receive do
      {:io_request, writer, reply, {:put_chars, _, bytes}} ->
        send(test, {:written, IO.iodata_to_binary(bytes)})
        send(writer, {:io_reply, reply, :ok})
        output_loop(test)
    end
  end

  defp await_record(predicate) do
    receive do
      {:written, "@loopex " <> json} ->
        record = JSON.decode!(json)
        if predicate.(record), do: record, else: await_record(predicate)

      {:written, _} ->
        await_record(predicate)
    after
      5_000 -> flunk("control record not delivered")
    end
  end

  defp start_fixture(script, options \\ []) do
    fixture = Fixture.start(Keyword.merge([script: script, tools: []], options))
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp prepared_configuration(tools \\ "none") do
    root =
      Path.join(
        System.tmp_dir!(),
        "chat-driver-config-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(Path.join(root, "workspace"))
    file = Path.join(root, "chat.json")

    profile = %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_CHAT_DRIVER_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => tools,
        "system_class_tokens" => 8000,
        "max_tokens" => 1024,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }

    File.write!(file, :json.encode(profile))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, prepared} = LoopexCli.ChatConfiguration.load(["chat", "--config", file], root, nil)
    prepared
  end

  defp records(transcript),
    do:
      transcript
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn
        "@loopex " <> json -> [JSON.decode!(json)]
        _ -> []
      end)

  defp byte_position(text, fragment), do: elem(:binary.match(text, fragment), 0)
end
