Code.require_file("support/runtime_fixture.ex", __DIR__)
Code.require_file("support/trace_child.ex", __DIR__)

defmodule Loopex.ReferenceClient.EndToEndRecoveryTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local
  alias Loopex.ReferenceClient
  alias Loopex.ReferenceClient.Recovery
  alias Loopex.ReferenceClientRuntimeFixture, as: Fixture
  alias Loopex.Runtime.SessionCoordinator

  @reconciliation_oracle [
    :reconciliation_query_id,
    :current_session_epoch,
    :expected_executor_identity,
    :current_recovery_contract,
    :journaled_operation_id,
    :original_attempt,
    :journaled_canonical_request_digest,
    :original_session_epoch,
    :original_executor_epoch,
    :origin_executor_identity,
    :origin_fencing_token
  ]

  test "reconciliation schema covers the independent recovery contract oracle" do
    assert SessionCoordinator.reconciliation_fields() == @reconciliation_oracle
  end

  test "exactly one dispatch ever carried each effect across the restart" do
    {fixture, session_id, retained, first_dispatches} = fault_and_restart("one-dispatch")
    on_exit(fn -> Fixture.stop(fixture) end)

    assert first_dispatches[retained.job_id] == 1
    assert {:ok, query} = ReferenceClient.reconciliation_query(fixture.client)
    assert {:ok, ^retained} = Local.receipt(fixture.executor, retained.job_id)
    assert :ok = ReferenceClient.reconcile(fixture.client, Recovery.receipt(query, retained))

    Fixture.await_terminal(fixture)
    assert Local.stats(fixture.executor).dispatches == %{}
    assert File.read!(Path.join(fixture.workspace, "one-dispatch.txt")) == "effect-one-dispatch"

    events = Fixture.events(fixture, session_id)
    assert Enum.count(events, &(&1.kind == "tool.started")) == 1
    assert Enum.count(events, &(&1.kind == "tool.finished")) == 1
  end

  test "an effect without a durable receipt becomes outcome_unknown and is not blindly retried" do
    {fixture, session_id, retained, first_dispatches} =
      fault_and_restart("unknown-without-receipt", remove_receipt: true)

    on_exit(fn -> Fixture.stop(fixture) end)

    assert first_dispatches[retained.job_id] == 1
    assert :absent = Local.receipt(fixture.executor, retained.job_id)
    assert {:ok, query} = ReferenceClient.reconciliation_query(fixture.client)

    response = Recovery.outcome_unknown(query)
    refute Map.has_key?(response, :retained_receipt)
    refute Map.has_key?(response, :job)
    assert :ok = ReferenceClient.reconcile(fixture.client, response)

    Fixture.await_terminal(fixture)
    assert Local.stats(fixture.executor).dispatches == %{}

    assert File.read!(Path.join(fixture.workspace, "unknown-without-receipt.txt")) ==
             "effect-unknown-without-receipt"

    events = Fixture.events(fixture, session_id)
    assert List.last(events).kind == "run.finished"
    assert List.last(events)["outcome"] == "outcome_unknown"
  end

  test "every acknowledged fact survives the restart" do
    fixture =
      Fixture.start(
        "fact-survival",
        Loopex.ReferenceClientTestModel,
        relative_path: "fact-survival.txt",
        content: "effect-fact-survival"
      )
      |> Fixture.create("fact-survival")

    assert {:accepted, "prompt-fact-survival"} =
             ReferenceClient.prompt(fixture.client, "prompt-fact-survival", "do it")

    Fixture.await_terminal(fixture)
    session_id = fixture.client.session_id
    before = Fixture.events(fixture, session_id)
    root = fixture.root
    Fixture.stop(fixture, false)

    resumed =
      Fixture.start(
        "fact-survival",
        Loopex.ReferenceClientTestModel,
        [relative_path: "fact-survival.txt", content: "effect-fact-survival"],
        root: root,
        recover_stale_writer: true
      )
      |> Fixture.resume(session_id)

    on_exit(fn -> Fixture.stop(resumed) end)

    assert Fixture.events(resumed, session_id) == before
    assert Enum.map(before, & &1.event_sequence) == Enum.to_list(1..length(before))
    assert Enum.uniq_by(before, & &1.event_id) == before
  end

  test "each wrong reconciliation and receipt identity is refused" do
    {fixture, _session_id, retained, _dispatches} = fault_and_restart("wrong-identities")
    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:ok, query} = ReferenceClient.reconciliation_query(fixture.client)
    valid = Recovery.receipt(query, retained)

    for field <- @reconciliation_oracle do
      wrong = Map.update!(valid, field, &wrong_value/1)
      assert {:error, {:mismatch, ^field}} = ReferenceClient.reconcile(fixture.client, wrong)
    end

    for field <- [
          :job_id,
          :operation_id,
          :attempt,
          :canonical_request_digest,
          :session_epoch_at_dispatch,
          :executor_epoch,
          :executor_identity,
          :fencing_token
        ] do
      wrong_receipt = Map.update!(retained, field, &wrong_value/1)
      wrong = %{valid | retained_receipt: wrong_receipt}
      assert {:error, {:mismatch, ^field}} = ReferenceClient.reconcile(fixture.client, wrong)
    end

    assert :ok = ReferenceClient.reconcile(fixture.client, valid)
    Fixture.await_terminal(fixture)
  end

  @tag :real_provider
  test "one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call" do
    credential = System.fetch_env!("LOOPEX_PROVIDER_API_KEY")
    System.delete_env("LOOPEX_PROVIDER_API_KEY")

    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-real-recovery-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    {first_port, first_os_pid} = start_trace_child(["phase1", root], credential)
    first = await_trace_marker(first_port)

    assert first.phase == 1
    assert first.dispatches == 1
    assert first.child_environment_names == ["PATH"]
    refute first.provider_credential_present
    assert_external_effect(root, first.job_id)

    {_output, 0} =
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(first_os_pid)], stderr_to_stdout: true)

    assert await_trace_exit(first_port) != 0

    {second_port, _second_os_pid} =
      start_trace_child(["phase2", root, first.session_id, first.job_id], credential)

    second = await_trace_marker(second_port)
    assert await_trace_exit(second_port) == 0

    assert second.phase == 2
    assert second.dispatches_after_restart == 0
    assert second.model_results == 2
    assert second.tool_started == 1
    assert second.tool_finished == 1
    assert second.terminal_outcome == "completed"
    assert second.child_environment_names == ["PATH"]
    refute second.provider_credential_present

    assert Enum.take(second.event_ids, length(first.acknowledged_event_ids)) ==
             first.acknowledged_event_ids

    assert second.provider_identity == first.provider_identity
    assert_external_effect(root, first.job_id)

    report_real_path(%{
      "provider" => second.provider_identity["provider"],
      "model" => second.provider_identity["model"],
      "endpoint" => second.provider_identity["endpoint"],
      "adapter_build" => "loopex_llm_reqllm@#{Loopex.version()}",
      "executor_build" => "loopex_executor_local@#{Loopex.version()}",
      "executor_identity" => "executor-local",
      "tool_identity" => "loopex.demo.write@1.0.0"
    })
  end

  defp fault_and_restart(label, options \\ []) do
    fixture =
      Fixture.start(
        label,
        Loopex.ReferenceClientTestModel,
        [relative_path: "#{label}.txt", content: "effect-#{label}"],
        fault_to: self()
      )
      |> Fixture.create(label)

    assert {:accepted, command_id} =
             ReferenceClient.prompt(fixture.client, "prompt-#{label}", "do it")

    assert command_id == "prompt-#{label}"

    assert_receive {:loopex_fault, :after_executor_receipt_before_fact, _coordinator, _reference,
                    retained},
                   3_000

    first_dispatches = Local.stats(fixture.executor).dispatches
    session_id = fixture.client.session_id
    root = fixture.root

    if Keyword.get(options, :remove_receipt) do
      File.rm!(receipt_path(fixture.ledger, retained.job_id))
    end

    Fixture.stop(fixture, false)

    resumed =
      Fixture.start(
        label,
        Loopex.ReferenceClientTestModel,
        [relative_path: "#{label}.txt", content: "effect-#{label}"],
        root: root,
        recover_stale_writer: true
      )
      |> Fixture.resume(session_id)

    {resumed, session_id, retained, first_dispatches}
  end

  defp receipt_path(root, job_id) do
    name = :crypto.hash(:sha256, job_id) |> Base.encode16(case: :lower)
    Path.join(root, name <> ".receipt")
  end

  defp assert_external_effect(root, job_id) do
    ledger = Path.join(root, "executor-ledger")

    assert Path.wildcard(Path.join(ledger, "*.receipt")) == [receipt_path(ledger, job_id)]

    # Concept: The local executor owns the private retained-receipt schema inspected
    # across this VM boundary.
    # Technical depth: Load its schema atoms before safe ETF decoding; OTP 26
    # refuses atoms created only by the child VM.
    assert Code.ensure_loaded?(Local)

    receipt =
      ledger
      |> receipt_path(job_id)
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    assert receipt.outcome == :completed
    assert receipt.child_environment_names == ["PATH"]
    refute receipt.provider_credential_present

    assert File.read!(Path.join([root, "workspace", "real-recovery.txt"])) ==
             "loopex-real-recovery"
  end

  defp wrong_value(value) when is_integer(value), do: value + 1
  defp wrong_value(value) when is_binary(value), do: value <> "-wrong"

  defp start_trace_child(arguments, credential) do
    executable = System.find_executable("elixir") || raise "elixir executable unavailable"

    code_path_arguments =
      :code.get_path()
      |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)

    child_arguments =
      code_path_arguments ++
        [
          "-r",
          Path.join(__DIR__, "support/runtime_fixture.ex"),
          "-r",
          Path.join(__DIR__, "support/trace_child.ex"),
          "-e",
          "Loopex.ReferenceClientTraceChild.run()",
          "--"
        ] ++ arguments

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: Enum.map(child_arguments, &String.to_charlist/1),
          env: [{~c"LOOPEX_PROVIDER_API_KEY", false}]
        ]
      )

    true = Port.command(port, <<byte_size(credential)::unsigned-big-32, credential::binary>>)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp await_trace_marker(port, buffer \\ <<>>) do
    receive do
      {^port, {:data, data}} ->
        next = buffer <> data

        case Regex.run(~r/(?:^|\n)LOOPEX_TRACE_V1 ([A-Za-z0-9_-]+)\n/, next) do
          [_, encoded] ->
            encoded
            |> Base.url_decode64!(padding: false)
            |> :erlang.binary_to_term([:safe])

          nil ->
            await_trace_marker(port, bounded_trace_buffer(next))
        end

      {^port, {:exit_status, _status}} ->
        flunk("real trace child exited before reporting evidence")
    after
      180_000 -> flunk("real trace child timed out before reporting evidence")
    end
  end

  defp await_trace_exit(port) do
    receive do
      {^port, {:data, _data}} -> await_trace_exit(port)
      {^port, {:exit_status, status}} -> status
    after
      30_000 -> flunk("real trace child did not exit")
    end
  end

  defp bounded_trace_buffer(buffer) when byte_size(buffer) <= 65_536, do: buffer
  defp bounded_trace_buffer(buffer), do: binary_part(buffer, byte_size(buffer) - 65_536, 65_536)

  defp report_real_path(report) do
    if Code.ensure_loaded?(Loopex.M1Gate.RealPathEvidence) do
      assert :ok = apply(Loopex.M1Gate.RealPathEvidence, :report, [report])
    else
      :ok
    end
  end
end
