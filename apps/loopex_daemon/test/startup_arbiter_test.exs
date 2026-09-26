defmodule LoopexDaemon.StartupArbiterTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.ExitStatus
  alias LoopexDaemon.StartupArbiter

  # Technical depth: only the output-deadline case claims a deadline, and it
  # sets its own 20 ms. The others start the arbiter with production's 5 s
  # output deadline and await each event it must produce for 10 s, above that
  # deadline: a floor-pair run starved one for over 2 s, and a starved arbiter
  # must not fail a case about something else. Every refutation keeps its own
  # short bound.

  test "output success still waits for the owner's exact release" do
    {:ok, output} = StringIO.open("")
    context = start_arbiter(output: output)

    assert_receive {:readiness_output_succeeded, owner_ref, startup_ref, sentinel}, 10_000
    assert owner_ref == context.owner_ref
    assert startup_ref == context.startup_ref
    assert sentinel == context.sentinel
    refute_receive {:begin_accept, _startup_ref}

    send(
      sentinel,
      {:readiness_release_authorized, owner_ref, startup_ref, self(), self()}
    )

    assert_receive {:begin_accept, ^startup_ref}, 10_000
    assert_receive {:readiness_disposition, ^owner_ref, ^startup_ref, :running}, 10_000
    assert_receive {:arbiter_result, {:disposition, :running}}, 10_000

    assert StringIO.contents(output) == {"", "readiness-line\n"}
  end

  test "a stop after visible output keeps the accept gate parked" do
    {:ok, output} = StringIO.open("")
    context = start_arbiter(output: output)

    assert_receive {:readiness_output_succeeded, owner_ref, startup_ref, sentinel}, 10_000
    send(sentinel, {:daemon_signal, context.owner_ref, :sigterm})

    assert_receive {:readiness_disposition, ^owner_ref, ^startup_ref, :operator_stop}, 10_000
    assert_receive {:arbiter_result, {:disposition, :operator_stop}}, 10_000
    refute_receive {:begin_accept, _startup_ref}
    assert StringIO.contents(output) == {"", "readiness-line\n"}
  end

  test "an exact owner fatal wins before release and preserves its status" do
    {:ok, output} = StringIO.open("")
    _context = start_arbiter(output: output)
    {:ok, status} = ExitStatus.fetch(:listener_start_failed)

    assert_receive {:readiness_output_succeeded, owner_ref, startup_ref, sentinel}, 10_000

    send(
      sentinel,
      {:readiness_startup_fatal, owner_ref, startup_ref, self(), self(), :listener_start_failed,
       status}
    )

    expected = {:fatal, :listener_start_failed, status}
    assert_receive {:readiness_disposition, ^owner_ref, ^startup_ref, ^expected}, 10_000
    assert_receive {:arbiter_result, {:disposition, ^expected}}, 10_000
    refute_receive {:begin_accept, _startup_ref}
  end

  test "stale signal and malformed owner status cannot release or fail startup" do
    {:ok, output} = StringIO.open("")
    _context = start_arbiter(output: output)

    assert_receive {:readiness_output_succeeded, owner_ref, startup_ref, sentinel}, 10_000
    {:ok, wrong_status} = ExitStatus.fetch(:owner_lost)

    send(sentinel, {:daemon_signal, make_ref(), :sigterm})

    send(
      sentinel,
      {:readiness_startup_fatal, owner_ref, startup_ref, self(), self(), :listener_start_failed,
       wrong_status}
    )

    refute_receive {:readiness_disposition, _, _, _}
    refute_receive {:begin_accept, _startup_ref}

    send(
      sentinel,
      {:readiness_release_authorized, owner_ref, startup_ref, self(), self()}
    )

    assert_receive {:begin_accept, ^startup_ref}, 10_000
    assert_receive {:readiness_disposition, ^owner_ref, ^startup_ref, :running}, 10_000
    assert_receive {:arbiter_result, {:disposition, :running}}, 10_000
  end

  test "an output deadline is a hard-halt disposition" do
    output = blocking_io_device(self())
    context = start_arbiter(output: output, deadline_ms: 20)

    assert_receive {:io_request_blocked, ^output}, 10_000
    {:ok, status} = ExitStatus.fetch(:readiness_write_failed)

    assert_receive {:arbiter_result, {:hard_halt, :readiness_write_failed, ^status}}, 10_000
    refute_receive {:readiness_disposition, _, _, _}
    refute_receive {:begin_accept, _startup_ref}

    Process.exit(output, :kill)
    sentinel = context.sentinel
    assert_receive {:DOWN, _monitor, :process, ^sentinel, _reason}, 10_000
  end

  test "owner loss during readiness selects owner_lost" do
    parent = self()
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    context = start_arbiter(owner: owner, output: blocking_io_device(parent))

    assert_receive {:io_request_blocked, _output}, 10_000
    Process.exit(owner, :kill)
    {:ok, status} = ExitStatus.fetch(:owner_lost)

    assert_receive {:arbiter_result, {:disposition, {:fatal, :owner_lost, ^status}}}, 10_000
    refute_receive {:begin_accept, _startup_ref}

    Process.exit(context.output, :kill)
  end

  defp start_arbiter(options) do
    owner = Keyword.get(options, :owner, self())
    listener = self()
    output = Keyword.fetch!(options, :output)
    deadline_ms = Keyword.get(options, :deadline_ms, StartupArbiter.output_deadline_ms())
    owner_ref = make_ref()
    startup_ref = make_ref()
    test = self()

    {sentinel, sentinel_monitor} =
      spawn_monitor(fn ->
        owner_monitor = Process.monitor(owner)

        result =
          StartupArbiter.arbitrate(
            owner,
            owner_monitor,
            owner_ref,
            startup_ref,
            listener,
            "readiness-line\n",
            output: output,
            deadline_ms: deadline_ms
          )

        send(test, {:arbiter_result, result})
      end)

    %{
      owner_ref: owner_ref,
      startup_ref: startup_ref,
      sentinel: sentinel,
      sentinel_monitor: sentinel_monitor,
      output: output
    }
  end

  defp blocking_io_device(test) do
    spawn(fn -> blocking_io_loop(test) end)
  end

  defp blocking_io_loop(test) do
    receive do
      {:io_request, _from, _reply_as, _request} ->
        send(test, {:io_request_blocked, self()})
        blocking_io_loop(test)

      _other ->
        blocking_io_loop(test)
    end
  end
end
