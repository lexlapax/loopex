defmodule Loopex.Executor.Local.ReservationLivenessTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.CodingTools
  alias Loopex.Executor.Local.WorkspaceLease

  @identity "reservation-liveness"
  @epoch 3
  @fence 19

  # Concept: validating another local reservation preserves the authority that
  # an independent, already running local effect still needs.
  #
  # Technical depth: both calls use ordinary Local.execute/5 with real local
  # holders, filesystem effects and retained receipts. The first shell remains
  # behind a release file until the second call completes. This is a positive
  # control for local liveness, not a non-local or distributed execution claim.
  test "local reservation holders remain usable while another local effect is running" do
    fixture = fixture()
    parent = self()

    {active, active_grant} =
      job(fixture, "loopex.bash", %{
        "command" =>
          "printf ready > active.started; " <>
            "while [ ! -f active.release ]; do sleep 0.01; done; " <>
            "printf preserved > active.txt"
      })

    task =
      Task.async(fn ->
        Local.execute(fixture.local, active, active_grant, notify: parent)
      end)

    try do
      active_id = active.job_id
      assert_receive {:executor_process_started, ^active_id, "loopex.bash", _environment}, 5_000

      assert eventually(fn ->
               File.read(Path.join(fixture.workspace, "active.started")) == {:ok, "ready"}
             end)

      assert {:error, :effect_in_flight} = Local.receipt(fixture.local, active_id)

      {queued, queued_grant} =
        job(fixture, "loopex.write", %{"path" => "independent.txt", "content" => "completed"})

      assert {:ok, independent_receipt} = Local.execute(fixture.local, queued, queued_grant)
      assert independent_receipt.outcome == :completed
      assert independent_receipt.cleanup_confirmation == :confirmed
      assert {:ok, ^independent_receipt} = Local.receipt(fixture.local, queued.job_id)
      assert File.read!(Path.join(fixture.workspace, "independent.txt")) == "completed"

      assert Process.alive?(fixture.local)
      assert {:error, :effect_in_flight} = Local.receipt(fixture.local, active_id)
      queued_id = queued.job_id
      assert %{dispatches: %{^active_id => 1, ^queued_id => 1}} = Local.stats(fixture.local)

      File.write!(Path.join(fixture.workspace, "active.release"), "release")

      assert {:ok, receipt} = Task.await(task, 10_000)
      assert receipt.outcome == :completed
      assert receipt.cleanup_confirmation == :confirmed
      assert {:ok, ^receipt} = Local.receipt(fixture.local, active_id)
      assert File.read!(Path.join(fixture.workspace, "active.txt")) == "preserved"
      assert Process.alive?(fixture.local)
    after
      File.write!(Path.join(fixture.workspace, "active.release"), "release")
      if Process.alive?(task.pid), do: Task.shutdown(task, 5_000)
    end
  end

  defp fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-reservation-liveness-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {:ok, root} = CodingTools.resolve(root, ".")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    lease_id = "lease-#{System.unique_integer([:positive])}"

    lease =
      start_supervised!({WorkspaceLease, id: lease_id, path: workspace, fencing_token: @fence})

    local =
      start_supervised!(
        Supervisor.child_spec(
          {Local,
           identity: @identity,
           epoch: @epoch,
           fencing_token: @fence,
           workspace_leases: %{lease_id => lease},
           ledger_root: Path.join(root, "ledger")},
          restart: :temporary
        )
      )

    %{local: local, workspace: workspace, lease_id: lease_id}
  end

  defp job(fixture, tool, arguments) do
    id = "liveness-job-#{System.unique_integer([:positive])}"
    definition = Enum.find(CodingTools.definitions(), &(&1["tool_id"] == tool))
    effect = definition["effect_class"]
    deadline = System.system_time(:millisecond) + 30_000

    assert {:ok, request} =
             Executor.job(%{
               protocol_version: 1,
               job_id: id,
               operation_id: "operation-#{id}",
               attempt: 1,
               session_id: "liveness-session",
               run_id: "liveness-run",
               turn_id: "liveness-turn",
               tool_call_id: "call-#{id}",
               origin_session_epoch: 1,
               origin_executor_epoch: @epoch,
               executor_identity: @identity,
               required_capabilities: [effect],
               tool_id: tool,
               tool_version: "1.0.0",
               effect_class: effect,
               validated_arguments: arguments,
               workspace_ref: "liveness-workspace",
               workspace_lease: fixture.lease_id,
               run_deadline: deadline,
               resource_budgets: %{"max_output_bytes" => 65_536},
               idempotency_class: definition["idempotency_class"],
               fencing_token: @fence,
               artifact_policy: %{"retain" => true},
               output_policy: %{"capture" => true}
             })

    assert {:ok, grant} = Executor.issue_grant({:host_policy, :allow}, request, deadline)
    {request, grant}
  end

  defp eventually(check), do: eventually(check, System.monotonic_time(:millisecond) + 5_000)

  defp eventually(check, deadline) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        eventually(check, deadline)
    end
  end
end
