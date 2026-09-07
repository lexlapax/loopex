defmodule Loopex.Executor.Local.ReceiptPublicationObservationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.CodingTools
  alias Loopex.Executor.Local.WorkspaceLease

  @identity "receipt-publication-observation"
  @epoch 3
  @fence 19
  @traced_returns [{:file, :open, 2}, {:file, :sync, 1}, {:file, :rename, 2}]
  @traced_calls [{:file, :read_file, 1}, {IO, :binread, 2}]

  # Concept: a successful public receipt is backed by bytes synced before their
  # name is published, and by a synced directory entry after publication.
  #
  # Technical depth: observe the real filesystem calls, not the spelling of the
  # private writer. Successful open returns bind devices to paths; successful
  # sync returns bracket the exact receipt rename. This proves the requested
  # syscall order, not that a particular disk survived an actual power loss.
  test "a final public receipt has synced bytes before publication and a synced parent afterwards" do
    fixture = fixture()
    request = job(fixture, "loopex.write", %{"path" => "written.txt", "content" => "written"})

    {answer, events} = observed_execution(fixture.local, request)
    assert {:ok, receipt} = answer
    assert receipt.outcome == :completed
    assert receipt.cleanup_confirmation == :confirmed
    assert Local.receipt(fixture.local, request.job_id) == answer
    assert File.read!(Path.join(fixture.workspace, "written.txt")) == "written"

    publications =
      for {{:rename_call, pid, staging, target}, index} <- Enum.with_index(events),
          Path.dirname(target) == fixture.ledger,
          String.ends_with?(target, ".receipt"),
          do: {pid, staging, target, index}

    assert [{writer, staging, target, publication}] = publications
    assert :erlang.binary_to_term(File.read!(target), [:safe]) == receipt

    assert Enum.any?(Enum.take(events, publication), &(&1 == {:synced, writer, staging})),
           "the receipt staging file was not successfully synced before its rename"

    renamed = Enum.find_index(events, &(&1 == {:renamed, writer, staging, target}))

    assert is_integer(renamed) and renamed > publication,
           "the receipt publication did not complete successfully"

    assert Enum.any?(
             Enum.drop(events, renamed + 1),
             &(&1 == {:synced, writer, Path.dirname(target)})
           ),
           "the exact receipt parent was not successfully synced after publication"
  end

  # Concept: the read ceiling refuses an already oversized file before loading
  # it; a file exactly at that ceiling is still read through the same real path.
  #
  # Technical depth: the public artifact ceiling belongs to the shipped tool
  # definition, so sparse files exercise that actual limit without a new seam.
  # A positive open/read observation makes absence on the refused path useful.
  # This does not schedule the separately disclosed concurrent path/growth race.
  test "read preflight refuses an oversized file without opening it and reads an exact-limit control" do
    fixture = fixture()
    definition = Enum.find(CodingTools.definitions(), &(&1["tool_id"] == "loopex.read"))
    limit = get_in(definition, ["budgets", "artifact_bytes"])
    exact = Path.join(fixture.workspace, "at-limit.txt")
    oversized = Path.join(fixture.workspace, "over-limit.txt")
    sparse_file(exact, limit)
    sparse_file(oversized, limit + 1)

    {control, control_events} =
      observed_execution(fixture.local, job(fixture, "loopex.read", %{"path" => "at-limit.txt"}))

    assert {:ok, %{outcome: :completed, output: output}} = control
    assert String.starts_with?(output, "positive-read-control")
    assert Enum.any?(control_events, &match?({:opened, _, ^exact}, &1))

    assert Enum.any?(control_events, &match?({:read, _, ^exact, _}, &1)),
           "the exact-limit control never read the opened target"

    {refusal, refusal_events} =
      observed_execution(
        fixture.local,
        job(fixture, "loopex.read", %{"path" => "over-limit.txt"})
      )

    assert {:ok, %{outcome: :failed, artifacts: [], output: diagnostic}} = refusal
    assert diagnostic =~ "artifact ceiling"
    assert diagnostic =~ Integer.to_string(limit)
    assert diagnostic =~ Integer.to_string(limit + 1)

    refute Enum.any?(refusal_events, fn
             {:open_call, _, ^oversized} -> true
             {:read, _, ^oversized, _amount} -> true
             _other -> false
           end),
           "the oversized target was opened or read before its preflight refusal"
  end

  defp fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-receipt-observation-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {:ok, root} = CodingTools.resolve(root, ".")
    workspace = Path.join(root, "workspace")
    ledger = Path.join(root, "ledger")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    lease_id = "lease-#{System.unique_integer([:positive])}"

    lease =
      start_supervised!({WorkspaceLease, id: lease_id, path: workspace, fencing_token: @fence})

    local =
      start_supervised!(
        {Local,
         identity: @identity,
         epoch: @epoch,
         fencing_token: @fence,
         workspace_leases: %{lease_id => lease},
         ledger_root: ledger}
      )

    %{local: local, workspace: workspace, ledger: ledger, lease_id: lease_id}
  end

  defp job(fixture, tool, arguments) do
    id = "observed-job-#{System.unique_integer([:positive])}"
    definition = Enum.find(CodingTools.definitions(), &(&1["tool_id"] == tool))
    effect = definition["effect_class"]

    assert {:ok, request} =
             Executor.job(%{
               protocol_version: 1,
               job_id: id,
               operation_id: "operation-#{id}",
               attempt: 1,
               session_id: "observed-session",
               run_id: "observed-run",
               turn_id: "observed-turn",
               tool_call_id: "call-#{id}",
               origin_session_epoch: 1,
               origin_executor_epoch: @epoch,
               executor_identity: @identity,
               required_capabilities: [effect],
               tool_id: tool,
               tool_version: "1.0.0",
               effect_class: effect,
               validated_arguments: arguments,
               workspace_ref: "observed-workspace",
               workspace_lease: fixture.lease_id,
               run_deadline: System.system_time(:millisecond) + 30_000,
               resource_budgets: %{"max_output_bytes" => 65_536},
               idempotency_class: definition["idempotency_class"],
               fencing_token: @fence,
               artifact_policy: %{"retain" => true},
               output_policy: %{"capture" => true}
             })

    request
  end

  defp sparse_file(path, size) do
    {:ok, file} = :file.open(path, [:write, :raw, :binary])

    try do
      :ok = :file.write(file, "positive-read-control")
      {:ok, _position} = :file.position(file, size - 1)
      :ok = :file.write(file, "x")
    after
      :file.close(file)
    end
  end

  defp observed_execution(local, request) do
    for mfa <- @traced_returns do
      assert :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local]) == 1
    end

    for mfa <- traced_calls(), do: assert(:erlang.trace_pattern(mfa, true, [:local]) == 1)
    on_exit(&clear_patterns/0)
    parent = self()

    {runner, monitor} =
      spawn_monitor(fn ->
        receive do
          :execute ->
            {:ok, grant} =
              Executor.issue_grant({:host_policy, :allow}, request, request.run_deadline)

            send(
              parent,
              {:observed_execute, self(), Local.execute(local, request, grant, [], nil)}
            )
        end
      end)

    on_exit(fn -> if Process.alive?(runner), do: Process.exit(runner, :kill) end)

    try do
      for pid <- [local, runner] do
        assert :erlang.trace(pid, true, [:call, :procs, :set_on_spawn, {:tracer, parent}]) == 1
      end

      send(runner, :execute)
      assert_receive {:observed_execute, ^runner, answer}, 10_000
      assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}, 1_000

      # Concept: completion of tracing is an acknowledged fact, not silence.
      # Technical depth: each observed descendant gets its own delivery barrier,
      # including already-dead processes. Spawn traces recursively close the set.
      roots = MapSet.new([local, runner])
      pending = Map.new(roots, &{:erlang.trace_delivered(&1), &1})
      deadline = System.monotonic_time(:millisecond) + 5_000
      {trace, traced} = collect_trace(pending, roots, [], deadline)

      for pid <- traced, Process.alive?(pid), do: :erlang.trace(pid, false, [:all])
      {answer, file_events(trace)}
    after
      if Process.alive?(local), do: :erlang.trace(local, false, [:all])
      clear_patterns()
    end
  end

  defp clear_patterns do
    for mfa <- @traced_returns ++ traced_calls(),
        do: :erlang.trace_pattern(mfa, false, [:local])
  end

  # Concept: a whole-file read cannot disappear from the observer on a newer VM.
  # Technical depth: current Elixir uses OTP's read_file/2; the floor uses /1.
  # The optional newer arity is traced whenever that runtime actually exports it.
  defp traced_calls do
    if function_exported?(:file, :read_file, 2),
      do: [{:file, :read_file, 2} | @traced_calls],
      else: @traced_calls
  end

  defp collect_trace(pending, traced, events, _deadline) when map_size(pending) == 0,
    do: {Enum.reverse(events), traced}

  defp collect_trace(pending, traced, events, deadline) do
    receive do
      {:trace, _parent, :spawn, child, _entry} when is_pid(child) ->
        if MapSet.member?(traced, child) do
          collect_trace(pending, traced, events, deadline)
        else
          pending = Map.put(pending, :erlang.trace_delivered(child), child)
          collect_trace(pending, MapSet.put(traced, child), events, deadline)
        end

      {:trace_delivered, pid, reference} ->
        assert Map.fetch!(pending, reference) == pid
        collect_trace(Map.delete(pending, reference), traced, events, deadline)

      {:trace, _pid, :call, _call} = event ->
        collect_trace(pending, traced, [event | events], deadline)

      {:trace, _pid, :return_from, _mfa, _result} = event ->
        collect_trace(pending, traced, [event | events], deadline)

      {:trace, _pid, _event, _value} ->
        collect_trace(pending, traced, events, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("trace delivery was not acknowledged for #{map_size(pending)} owned processes")
    end
  end

  defp file_events(trace) do
    {_pending, _devices, events} =
      Enum.reduce(trace, {%{}, %{}, []}, fn
        {:trace, pid, :call, {:file, function, arguments}}, {pending, devices, events}
        when function in [:open, :sync, :rename] ->
          pending =
            Map.update(pending, pid, [{function, arguments}], &[{function, arguments} | &1])

          events =
            case {function, arguments} do
              {:open, [path, _modes]} -> [{:open_call, pid, path(path)} | events]
              {:rename, [from, to]} -> [{:rename_call, pid, path(from), path(to)} | events]
              _sync -> events
            end

          {pending, devices, events}

        {:trace, pid, :return_from, {:file, function, _arity}, result},
        {pending, devices, events} ->
          [{^function, arguments} | rest] = Map.fetch!(pending, pid)
          pending = Map.put(pending, pid, rest)

          case {function, arguments, result} do
            {:open, [name, _modes], {:ok, device}} ->
              {pending, Map.put(devices, device, path(name)),
               [{:opened, pid, path(name)} | events]}

            {:sync, [device], :ok} ->
              {pending, devices, [{:synced, pid, Map.fetch!(devices, device)} | events]}

            {:rename, [from, to], :ok} ->
              {pending, devices, [{:renamed, pid, path(from), path(to)} | events]}

            _error ->
              {pending, devices, events}
          end

        {:trace, pid, :call, {:file, :read_file, [name | _options]}},
        {pending, devices, events} ->
          {pending, devices, [{:read, pid, path(name), :whole_file} | events]}

        {:trace, pid, :call, {IO, :binread, [device, amount]}}, {pending, devices, events} ->
          {pending, devices, [{:read, pid, Map.get(devices, device), amount} | events]}
      end)

    Enum.reverse(events)
  end

  defp path(value), do: value |> IO.chardata_to_string() |> Path.expand()
end
