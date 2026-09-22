Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.RuntimeQuiesceTest do
  @moduledoc """
  ## Concept

  Orderly runtime shutdown begins with one terminal admission gate. The gate
  freezes the sessions that have ever owned a writer in this runtime and makes
  later session creation, activation, attachment and command routes refuse.

  ## Technical depth

  These foundation cases exercise the serialized Control transition directly.
  Later cases in this module drive the complete `Runtime.quiesce/1` phase owner,
  drain and fence path while retaining these cut-order witnesses.
  """

  use ExUnit.Case, async: true

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.Control

  test "the first gate freezes writer domains and later admission refuses before Store access" do
    fixture = fixture("quiesce-gate")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok,
            [
              %{
                session_id: ^session_id,
                status: :active,
                coordinator: coordinator,
                owner: owner,
                writer_started?: true
              }
            ]} = Control.begin_quiesce(control, fixture.runtime.token, "drain-one", 5_000)

    assert is_pid(coordinator)
    assert is_map(owner)

    before = M1RuntimeTestStore.inspect_state(fixture.store_pid)

    assert {:error, :runtime_unavailable} =
             Runtime.create_session_detailed(fixture.runtime, "after-gate", %{})

    assert {:error, :runtime_unavailable} =
             Runtime.resume_session_detailed(fixture.runtime, session_id, "after-gate")

    assert {:error, :runtime_unavailable} = Loopex.attach(fixture.runtime, session_id)

    assert {:error, :runtime_unavailable} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "after-gate",
               content: "must not be admitted"
             })

    assert {:error, :runtime_unavailable} = Runtime.session_status(fixture.runtime, session_id)
    assert before == M1RuntimeTestStore.inspect_state(fixture.store_pid)

    assert {:ok, [%{session_id: ^session_id}]} =
             Control.quiesce_projection(control, fixture.runtime.token, "drain-one", 5_000)

    assert {:error, :runtime_unavailable} =
             Control.begin_quiesce(control, fixture.runtime.token, "drain-two", 5_000)

    assert :sys.get_state(control).quiescing == "drain-one"
  end

  test "the projection omits dormant no-writer rows and refuses an impossible 65-writer census" do
    dormant = fixture("quiesce-dormant")
    session_id = create_session(dormant.runtime, "create")
    {:ok, %{control: dormant_control}} = Runtime.children(dormant.runtime)

    dormant_rows =
      Map.new(1..70, fn index ->
        {"dormant-#{index}", %{status: :unavailable, durable: nil, generation: "none"}}
      end)

    :sys.replace_state(dormant_control, fn state ->
      %{state | sessions: Map.merge(state.sessions, dormant_rows)}
    end)

    assert {:ok, [%{session_id: ^session_id}]} =
             Control.begin_quiesce(
               dormant_control,
               dormant.runtime.token,
               "bounded-dormant",
               5_000
             )

    oversized = fixture("quiesce-oversized")
    {:ok, %{control: oversized_control}} = Runtime.children(oversized.runtime)
    writer_domains = MapSet.new(Enum.map(1..65, &"writer-#{&1}"))

    :sys.replace_state(oversized_control, fn state ->
      %{state | writer_domains: writer_domains}
    end)

    assert {:error, :runtime_unavailable} =
             Control.begin_quiesce(
               oversized_control,
               oversized.runtime.token,
               "bounded-refusal",
               5_000
             )

    state = :sys.get_state(oversized_control)
    assert state.quiescing == "bounded-refusal"
    assert state.sessions == %{}
  end

  defp fixture(runtime_id) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: runtime_id)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: runtime_id,
        store: store
      )

    on_exit(fn ->
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    %{runtime: runtime, store_pid: store_pid}
  end

  defp create_session(runtime, command_id) do
    assert {:ok, session_id} = Runtime.create_session(runtime, command_id, %{})
    session_id
  end
end
