defmodule Loopex.LLM.ReqLLM.InProcess.PoolLifecycleTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.InProcess.PoolLifecycle

  setup do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    previous = System.get_env("SSLKEYLOGFILE")
    System.delete_env("SSLKEYLOGFILE")

    on_exit(fn ->
      if previous,
        do: System.put_env("SSLKEYLOGFILE", previous),
        else: System.delete_env("SSLKEYLOGFILE")
    end)

    :ok
  end

  test "a start-blocked root creates no resources and ignores unrelated permission" do
    root = dormant()
    send(root.pid, {:loopex_pool_start, self(), make_ref()})
    send(root.pid, {:loopex_pool_start, spawn(fn -> :ok end), root.reference})
    refute_receive {:loopex_pool_record, _, _, _}, 30
    assert Process.alive?(root.pid)
    assert registries(root.identity) == {[], []}
    root = stop(root)
    assert root.roles == %{}
  end

  test "HTTP and HTTPS use one public cast, exact expanded config and one recorded child" do
    Code.ensure_loaded!(Finch.Pool)
    assert :erlang.trace_pattern({Finch.Pool, :child_spec, 1}, true, []) == 1
    on_exit(fn -> :erlang.trace_pattern({Finch.Pool, :child_spec, 1}, false, []) end)

    for base <- ["http://127.0.0.1:49151/v1", "https://localhost:49151/prefix"] do
      root = dormant(base: base)
      :erlang.trace(root.pid, true, [:call])
      root = start(root)
      assert_receive {:trace, pid, :call, {Finch.Pool, :child_spec, [options]}}, 1_000
      assert pid == root.pid
      pool = Finch.Pool.new(base, tag: root.tag)

      submitted = [
        finch: Req.Finch,
        pool: pool,
        protocols: [:http1],
        size: 1,
        count: 1,
        start_pool_metrics?: false
      ]

      submitted =
        if pool.scheme == :https,
          do:
            submitted ++
              [
                conn_opts: [
                  transport_opts: [
                    reuse_sessions: false,
                    session_tickets: :disabled,
                    keep_secrets: false
                  ]
                ]
              ],
          else: submitted

      assert options == submitted
      refute_receive {:trace, ^pid, :call, {Finch.Pool, :child_spec, _}}, 10
      [{supervisor, {Finch.HTTP1.Pool, 1, config}}] = elem(registries(root.identity), 1)
      assert supervisor == root.roles.pool_supervisor
      assert elem(registries(root.identity), 0) == [{root.worker, Finch.HTTP1.Pool}]

      assert Supervisor.which_children(supervisor) == [
               {1, root.worker, :worker, [Finch.HTTP1.Pool]}
             ]

      assert Enum.sort(Map.keys(config)) ==
               Enum.sort([
                 :mod,
                 :size,
                 :count,
                 :conn_opts,
                 :conn_max_idle_time,
                 :pool_max_idle_time,
                 :start_pool_metrics?,
                 :wait_for_server_settings?,
                 :ping_interval,
                 :max_connection_age,
                 :max_connection_age_jitter
               ])

      assert config.mod == Finch.HTTP1.Pool
      assert config.conn_opts[:ssl_key_log_file_device] == nil
      assert config.conn_opts[:transport_opts][:timeout] == 5_000
      assert config.conn_opts[:protocols] == [:http1]
      assert inspect_root(root) == :ok
      stop(root)
    end
  end

  test "concurrent same-origin roots have distinct tags and independent lifetimes" do
    first = start(dormant())
    second = start(dormant())
    assert first.identity != second.identity
    assert first.worker != second.worker
    stop(first)
    assert Process.alive?(second.worker)
    assert inspect_root(second) == :ok
    stop(second)
  end

  test "a foreign entry in either registry refuses before acquiring any resources" do
    for registry <- [Req.Finch, Req.Finch.SupervisorRegistry] do
      root = dormant()
      foreign = foreign(registry, root.identity, :foreign)
      send(root.pid, {:loopex_pool_start, self(), root.reference})
      assert_receive {:loopex_pool_failed, pid, reference}, 1_000
      assert {pid, reference} == {root.pid, root.reference}
      assert_receive {:DOWN, monitor, :process, ^pid, :normal}, 1_000
      assert monitor == root.monitor
      refute_receive {:loopex_pool_record, ^pid, _, _}, 10
      assert Process.alive?(foreign)
      assert Registry.lookup(registry, root.identity) == [{foreign, :foreign}]
      send(foreign, :stop)
    end
  end

  test "SSLKEYLOGFILE is rechecked by the root before its sole cast opens a file" do
    root = dormant()
    path = Path.join(System.tmp_dir!(), "loopex-keylog-#{System.unique_integer([:positive])}")
    refute File.exists?(path)
    System.put_env("SSLKEYLOGFILE", path)
    send(root.pid, {:loopex_pool_start, self(), root.reference})
    assert_receive {:loopex_pool_failed, pid, reference}, 1_000
    assert {pid, reference} == {root.pid, root.reference}
    assert_receive {:DOWN, monitor, :process, ^pid, :normal}, 1_000
    assert monitor == root.monitor
    refute File.exists?(path)
    assert registries(root.identity) == {[], []}
  end

  test "an expired setup acquires no resource or work authority" do
    root = dormant(deadline: deadline(-1))
    send(root.pid, {:loopex_pool_start, self(), root.reference})
    root = finish(root, :failed)
    assert root.roles == %{}
  end

  test "fresh recording remains admissible after the call expires but cannot continue setup" do
    root = dormant(deadline: deadline(50))
    send(root.pid, {:loopex_pool_start, self(), root.reference})
    assert_receive {:loopex_pool_record, pid, receipt, entries}, 1_000
    assert pid == root.pid
    assert [{:process, :anonymous_supervisor, anonymous}] = entries
    root = retain(root, entries)
    Process.sleep(80)
    assert Process.alive?(anonymous)
    send(pid, {:loopex_pool_recorded, receipt})
    root = finish(root, :failed)
    assert Map.keys(root.roles) == [:anonymous_supervisor]
  end

  test "wrong, missing and late recording acknowledgements never authorize a pool" do
    root = dormant()
    send(root.pid, {:loopex_pool_start, self(), root.reference})
    assert_receive {:loopex_pool_record, pid, receipt, entries}, 1_000
    root = retain(root, entries)
    send(pid, {:loopex_pool_recorded, make_ref()})
    refute_receive {:loopex_pool_ready, ^pid, _, _, _}, 50
    root = finish(root, :failed)
    send(pid, {:loopex_pool_recorded, receipt})
    assert Map.keys(root.roles) == [:anonymous_supervisor]
    assert registries(root.identity) == {[], []}
  end

  test "lost pool-supervisor receipt discovers and reports the worker during cleanup" do
    root = dormant()
    send(root.pid, {:loopex_pool_start, self(), root.reference})
    root = through_records(root, 2)
    assert_receive {:loopex_pool_record, pid, _receipt, entries}, 1_000
    assert pid == root.pid
    assert [{:process, :pool_supervisor, supervisor}] = entries
    root = retain(root, entries)
    [{1, worker, :worker, [Finch.HTTP1.Pool]}] = Supervisor.which_children(supervisor)
    assert_receive {:loopex_pool_record, ^pid, receipt, cleanup_entries}, 1_500
    assert {:process, :http1_worker, worker} in cleanup_entries
    root = retain(root, cleanup_entries)
    send(pid, {:loopex_pool_recorded, receipt})
    root = finish(root, :failed)
    assert root.roles.http1_worker == worker
  end

  test "configuration tampering refuses inspection and then proves owned teardown" do
    for mutate <- [
          fn {mod, count, config} -> {mod, count, Map.put(config, :unexpected, true)} end,
          fn {mod, count, config} -> {mod, count, %{config | size: 1.0}} end,
          fn {mod, _count, config} -> {mod, 1.0, config} end,
          fn {mod, count, config} ->
            {mod, count, %{config | conn_opts: config.conn_opts ++ [hostname: "other"]}}
          end
        ] do
      root = start(dormant())

      :sys.replace_state(root.roles.pool_supervisor, fn state ->
        Registry.update_value(Req.Finch.SupervisorRegistry, root.identity, mutate)
        state
      end)

      assert inspect_root(root) == :refused
      finish(root, :failed)
    end
  end

  test "an expired inspection refuses without replacing or recasting the pool" do
    root = start(dormant())
    assert inspect_root(root, deadline(-1)) == :refused
    finish(root, :failed)
  end

  test "a real worker restart is reaped but immutable generation loss stays unproved" do
    root = start(dormant())
    assert :erlang.suspend_process(root.pid)

    {replacement, replacement_monitor} =
      try do
        Process.exit(root.worker, :kill)
        replacement = replacement_worker(root.roles.pool_supervisor, root.worker, deadline(500))
        assert Process.alive?(replacement)
        {replacement, Process.monitor(replacement)}
      after
        :erlang.resume_process(root.pid)
      end

    unproved_restart(root)
    assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement, _reason}, 1_000
  end

  test "a real pool-supervisor restart reaps its new worker without adopting either role" do
    root = start(dormant())
    assert :erlang.suspend_process(root.pid)

    {replacement, worker, replacement_monitor, worker_monitor} =
      try do
        Process.exit(root.roles.pool_supervisor, :kill)
        {replacement, worker} = replacement_supervisor(root, deadline(500))
        assert Process.alive?(replacement) and Process.alive?(worker)
        {replacement, worker, Process.monitor(replacement), Process.monitor(worker)}
      after
        :erlang.resume_process(root.pid)
      end

    unproved_restart(root)
    assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement, _reason}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
  end

  defp replacement_worker(supervisor, original, expiry) do
    case Supervisor.which_children(supervisor) do
      [{1, replacement, :worker, [Finch.HTTP1.Pool]}]
      when is_pid(replacement) and replacement != original ->
        replacement

      _restarting ->
        assert System.monotonic_time(:native) < expiry
        Process.sleep(1)
        replacement_worker(supervisor, original, expiry)
    end
  end

  defp replacement_supervisor(root, expiry) do
    case Supervisor.which_children(root.roles.anonymous_supervisor) do
      [{_, replacement, :supervisor, [Finch.Pool.Supervisor]}]
      when is_pid(replacement) and replacement != root.roles.pool_supervisor ->
        {replacement, replacement_worker(replacement, root.worker, expiry)}

      _restarting ->
        assert System.monotonic_time(:native) < expiry
        Process.sleep(1)
        replacement_supervisor(root, expiry)
    end
  end

  defp unproved_restart(root) do
    pid = root.pid
    assert_receive {:loopex_pool_unproved, ^pid, _reference}, 2_000
    assert Process.alive?(pid)

    for {monitor, child} <- root.monitors do
      assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 1_000
    end

    assert registries(root.identity) == {[], []}
    refute_receive {:loopex_pool_record, ^pid, _, _}, 10
    refute_receive {:loopex_pool_failed, ^pid, _}, 10
    refute_receive {:DOWN, _, :process, ^pid, :normal}, 10
  end

  test "owner death starts the same unwind and the root waits for genuine child DOWN" do
    test = self()
    owner = spawn(fn -> owner_loop(test) end)
    root = dormant(owner: owner)
    send(owner, {:root, root})
    send(root.pid, {:loopex_pool_start, owner, root.reference})
    assert_receive {:owner_ready, ready}, 2_000
    monitors = Map.new(ready.roles, fn {role, pid} -> {role, {pid, Process.monitor(pid)}} end)
    Process.exit(owner, :kill)
    monitor = root.monitor
    pid = root.pid
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000

    for {_role, {child, child_monitor}} <- monitors do
      assert_receive {:DOWN, ^child_monitor, :process, ^child, _reason}, 1_000
    end

    assert registries(root.identity) == {[], []}
  end

  test "a foreign post-start entry is never stopped and prevents false cleanup proof" do
    root = start(dormant())
    foreign = foreign(Req.Finch, root.identity, :foreign)
    stop_ref = make_ref()
    send(root.pid, {:loopex_pool_stop, self(), stop_ref, deadline(150)})
    assert_receive {:loopex_pool_unproved, pid, reference}, 1_000
    assert {pid, reference} == {root.pid, root.reference}
    assert Process.alive?(pid)
    assert Process.alive?(foreign)
    assert Registry.lookup(Req.Finch, root.identity) == [{foreign, :foreign}]
    refute_receive {:loopex_pool_stopped, ^pid, ^stop_ref}, 10
    send(foreign, :stop)
    stop(root)
  end

  test "partial child failure from a same-tag race cleans only owned ancestry" do
    root = dormant()
    send(root.pid, {:loopex_pool_start, self(), root.reference})
    root = through_records(root, 1)
    assert_receive {:loopex_pool_record, pid, receipt, entries}, 1_000
    assert pid == root.pid
    assert length(entries) == 2
    foreign = foreign(Req.Finch.SupervisorRegistry, root.identity, :foreign)
    send(pid, {:loopex_pool_recorded, receipt})
    assert_receive {:loopex_pool_unproved, ^pid, _}, 2_000
    assert Process.alive?(foreign)
    refute Process.alive?(root.roles.anonymous_supervisor)
    send(foreign, :stop)
    stop(root)
  end

  test "genuine descendant DOWN precedes bounded polling of delayed Registry cleanup" do
    root = start(dormant())

    partitions =
      for registry <- [Req.Finch, Req.Finch.SupervisorRegistry],
          {_id, pid, :worker, [Registry.Partition]} <- Supervisor.which_children(registry),
          do: pid

    Enum.each(partitions, &:sys.suspend/1)

    on_exit(fn ->
      Enum.each(partitions, fn pid -> if Process.alive?(pid), do: :sys.resume(pid) end)
    end)

    Code.ensure_loaded!(Registry)
    assert :erlang.trace_pattern({Registry, :lookup, 2}, true, []) == 1
    on_exit(fn -> :erlang.trace_pattern({Registry, :lookup, 2}, false, []) end)
    :erlang.trace(root.pid, true, [:call, :receive])
    send(root.pid, {:loopex_pool_stop, self(), make_ref(), deadline(1_000)})
    descendants = MapSet.new(Map.values(root.roles))
    down_before_lookup(root.pid, descendants, MapSet.new())
    assert elem(registries(root.identity), 0) != []
    assert Process.alive?(root.pid)
    refute_receive {:loopex_pool_stopped, _, _}, 20
    Enum.each(partitions, &:sys.resume/1)
    finish(root, :stopped)
  end

  test "stop interrupts a recording wait without granting further setup authority" do
    for phase <- 1..4 do
      root = dormant()
      send(root.pid, {:loopex_pool_start, self(), root.reference})
      root = through_records(root, phase - 1)
      assert_receive {:loopex_pool_record, pid, _receipt, entries}, 1_000
      root = retain(root, entries)
      assert pid == root.pid
      root = stop(root)
      if phase <= 2, do: assert(Map.keys(root.roles) == [:anonymous_supervisor])
    end
  end

  test "an unrecoverable required worker cannot be replaced by its parent's DOWN" do
    root = dormant()
    send(root.pid, {:loopex_pool_start, self(), root.reference})
    root = through_records(root, 2)
    assert_receive {:loopex_pool_record, pid, _receipt, entries}, 1_000
    root = retain(root, entries)
    assert pid == root.pid
    supervisor = root.roles.pool_supervisor
    [{1, worker, :worker, [Finch.HTTP1.Pool]}] = Supervisor.which_children(supervisor)
    worker_monitor = Process.monitor(worker)
    :ok = Supervisor.stop(supervisor, :normal)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
    assert_receive {:loopex_pool_unproved, ^pid, _reference}, 2_000
    assert Process.alive?(pid)
    assert registries(root.identity) == {[], []}
    refute_receive {:loopex_pool_failed, ^pid, _reference}, 10
    # Concept: This negative control deliberately retains an unproved root.
    # Technical depth: The test VM reaps it at exit; no clean root DOWN is invented.
  end

  test "a blocked real inspection withholds success and unwinds when the dependency returns" do
    root = start(dormant())
    :ok = :sys.suspend(root.roles.pool_supervisor)

    on_exit(fn ->
      if Process.alive?(root.roles.pool_supervisor), do: :sys.resume(root.roles.pool_supervisor)
    end)

    inspection = make_ref()
    send(root.pid, {:loopex_pool_inspect, self(), inspection, deadline(50)})
    refute_receive {:loopex_pool_inspected, _, _, _}, 100
    assert Process.alive?(root.pid)
    send(root.pid, {:loopex_pool_stop, self(), make_ref(), deadline(1_000)})
    :ok = :sys.resume(root.roles.pool_supervisor)
    assert_receive {:loopex_pool_inspected, pid, ^inspection, :refused}, 1_000
    assert pid == root.pid
    finish(root, :failed)
  end

  defp down_before_lookup(root, descendants, down) do
    receive do
      {:trace, ^root, :receive, {:DOWN, _ref, :process, pid, _reason}} ->
        down_before_lookup(root, descendants, MapSet.put(down, pid))

      {:trace, ^root, :call, {Registry, :lookup, _arguments}} ->
        assert MapSet.subset?(descendants, down)

      {:trace, ^root, _kind, _payload} ->
        down_before_lookup(root, descendants, down)
    after
      1_000 -> flunk("missing genuine DOWN and Registry polling trace")
    end
  end

  defp dormant(options \\ []) do
    base = Keyword.get(options, :base, "http://127.0.0.1:49151/v1")
    tag = make_ref()
    reference = make_ref()
    owner = Keyword.get(options, :owner, self())

    input = %{
      owner: owner,
      reference: reference,
      base_url: base,
      tag: tag,
      deadline: Keyword.get(options, :deadline, deadline(5_000))
    }

    {pid, monitor} = spawn_monitor(fn -> PoolLifecycle.run(input) end)
    identity = Finch.Pool.to_name(Finch.Pool.new(base, tag: tag))

    on_exit(fn ->
      if Process.alive?(pid),
        do: send(pid, {:loopex_pool_stop, owner, make_ref(), deadline(1_000)})
    end)

    %{
      pid: pid,
      monitor: monitor,
      tag: tag,
      reference: reference,
      identity: identity,
      roles: %{},
      monitors: %{},
      worker: nil
    }
  end

  defp start(root) do
    send(root.pid, {:loopex_pool_start, self(), root.reference})
    ready(root)
  end

  defp ready(root) do
    receive do
      {:loopex_pool_record, pid, receipt, entries} when pid == root.pid ->
        root = retain(root, entries)
        send(pid, {:loopex_pool_recorded, receipt})
        ready(root)

      {:loopex_pool_ready, pid, reference, worker, identity}
      when pid == root.pid and reference == root.reference ->
        assert identity == root.identity
        assert worker == root.roles.http1_worker
        %{root | worker: worker}

      {:loopex_pool_failed, pid, _reference} when pid == root.pid ->
        flunk("pool setup refused")
    after
      2_000 -> flunk("missing pool ready")
    end
  end

  defp retain(root, entries) do
    Enum.reduce(entries, root, fn
      {:process, role, pid}, root ->
        if Map.has_key?(root.roles, role) do
          assert root.roles[role] == pid
          root
        else
          %{
            root
            | roles: Map.put(root.roles, role, pid),
              monitors: Map.put(root.monitors, Process.monitor(pid), pid)
          }
        end

      {:registry, kind, identity}, root ->
        assert kind in [:worker, :supervisor] and identity == root.identity
        root
    end)
  end

  defp through_records(root, 0), do: root

  defp through_records(root, count) do
    assert_receive {:loopex_pool_record, pid, receipt, entries}, 1_000
    assert pid == root.pid
    root = retain(root, entries)
    send(pid, {:loopex_pool_recorded, receipt})
    through_records(root, count - 1)
  end

  defp stop(root) do
    send(root.pid, {:loopex_pool_stop, self(), make_ref(), deadline(1_000)})
    finish(root, :stopped)
  end

  defp finish(root, ending) do
    receive do
      {:loopex_pool_record, pid, receipt, entries} when pid == root.pid ->
        root = retain(root, entries)
        send(pid, {:loopex_pool_recorded, receipt})
        finish(root, ending)

      {:loopex_pool_failed, pid, reference} when pid == root.pid ->
        assert (ending == :failed or root.worker == nil) and reference == root.reference
        finish(root, ending)

      {:loopex_pool_stopped, pid, _reference} when pid == root.pid ->
        assert ending == :stopped
        finish(root, ending)

      {:DOWN, monitor, :process, pid, :normal} when monitor == root.monitor and pid == root.pid ->
        for {child_monitor, child} <- root.monitors do
          assert_receive {:DOWN, ^child_monitor, :process, ^child, _reason}, 1_000
          refute Process.alive?(child)
        end

        assert registries(root.identity) == {[], []}
        root
    after
      2_500 -> flunk("missing proved root DOWN")
    end
  end

  defp inspect_root(root, expiry \\ deadline(1_000)) do
    reference = make_ref()
    send(root.pid, {:loopex_pool_inspect, self(), reference, expiry})
    assert_receive {:loopex_pool_inspected, pid, ^reference, result}, 1_500
    assert pid == root.pid
    result
  end

  defp foreign(registry, identity, value) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(registry, identity, value)
        send(test, {:foreign_ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:foreign_ready, ^pid}, 1_000
    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp owner_loop(test, root \\ nil) do
    receive do
      {:root, root} ->
        owner_loop(test, root)

      {:loopex_pool_record, pid, receipt, entries} ->
        root = retain(root, entries)
        send(pid, {:loopex_pool_recorded, receipt})
        owner_loop(test, root)

      {:loopex_pool_ready, _pid, _reference, worker, _identity} ->
        send(test, {:owner_ready, %{root | worker: worker}})
        owner_loop(test, root)
    end
  end

  defp registries(identity),
    do:
      {Registry.lookup(Req.Finch, identity),
       Registry.lookup(Req.Finch.SupervisorRegistry, identity)}

  defp deadline(ms),
    do: System.monotonic_time(:native) + System.convert_time_unit(ms, :millisecond, :native)
end
