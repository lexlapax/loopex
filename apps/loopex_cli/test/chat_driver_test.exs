Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatDriverTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias LoopexCli.ChatDriver
  alias Loopex.AgentLoopFixture, as: Fixture

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
