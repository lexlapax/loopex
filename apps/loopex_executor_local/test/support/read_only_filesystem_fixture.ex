defmodule Loopex.Executor.Local.ReadOnlyFilesystemFixture do
  @moduledoc false
  @compile {:no_warn_undefined,
            [Loopex.Executor.Local.ReadOnlyTools, Loopex.Executor.Local.CodingTools]}
  @timeout 30_000
  @source_root Path.expand("../../lib", __DIR__)

  # Concept: identity witnesses change real files at a known operation boundary.
  # Technical depth: only a disposable VM installs the OTP file-server debug
  # function. Its caller is suspended before a reply can run it; the fixture
  # changes files through prim_file, then resumes that exact caller. No product
  # function, filesystem return value or parent-VM file server is replaced.
  def run(kind, stage, requested?, change? \\ true) do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-identity-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)

    try do
      arguments = {root, kind, stage, requested?, change?, @source_root}
      encoded = arguments |> :erlang.term_to_binary() |> Base.encode64()

      code =
        "Code.require_file(#{inspect(__ENV__.file)}); " <>
          "#{inspect(__MODULE__)}.child_main(#{inspect(encoded)})"

      # Clear every inherited variable, including credentials and VM injection
      # options. PATH is needed by the Elixir launcher; the child has its own
      # home and crash-dump path inside this fixture's disposable root.
      environment =
        System.get_env()
        |> Map.keys()
        |> Enum.reject(&(&1 == "PATH"))
        |> Enum.map(&{String.to_charlist(&1), false})

      environment =
        environment ++
          [
            {~c"ERL_FLAGS", ~c"+S 2:2 +SDcpu 1 +SDio 1"},
            {~c"ERL_CRASH_DUMP", String.to_charlist(Path.join(root, "child.dump"))},
            {~c"ERL_CRASH_DUMP_SECONDS", ~c"0"},
            {~c"LOOPEX_HOME", String.to_charlist(Path.join(root, "home"))}
          ]

      port =
        Port.open({:spawn_executable, String.to_charlist(System.find_executable("elixir"))}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-e", String.to_charlist(code)],
          env: environment,
          cd: String.to_charlist(root)
        ])

      monitor = :erlang.monitor(:port, port)
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      try do
        {output, status, down} = collect(port, monitor, "", nil, nil)

        if status != 0 or down != :normal,
          do: raise("filesystem witness child failed: #{inspect({status, down, output})}")

        [_, encoded_report] = Regex.run(~r/\ALOOPEX_IDENTITY ([A-Za-z0-9+\/=]+)\n\z/, output)
        report = encoded_report |> Base.decode64!() |> :erlang.binary_to_term([:safe])
        true = report.otp == List.to_string(:erlang.system_info(:otp_release))
        report
      after
        stop_child(port, monitor, os_pid)
        :erlang.demonitor(monitor, [:flush])
      end
    after
      File.rm_rf!(root)
    end
  end

  defp stop_child(port, monitor, os_pid) do
    if Port.info(port) do
      # A failed witness may leave its file server or walk suspended. Kill only
      # the OS process returned by this still-live owned port, and require DOWN
      # before removing its temporary files. Closing stdin alone is not proof.
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

      receive do
        {:DOWN, ^monitor, :port, ^port, _} -> :ok
      after
        5_000 -> raise "filesystem witness child teardown was not proved"
      end
    end
  end

  defp collect(_port, _monitor, output, status, down)
       when is_integer(status) and not is_nil(down),
       do: {output, status, down}

  defp collect(port, monitor, output, status, down) do
    receive do
      {^port, {:data, bytes}} -> collect(port, monitor, output <> bytes, status, down)
      {^port, {:exit_status, code}} -> collect(port, monitor, output, code, down)
      {:DOWN, ^monitor, :port, ^port, reason} -> collect(port, monitor, output, status, reason)
    after
      @timeout -> raise "filesystem witness child did not exit: #{inspect(output)}"
    end
  end

  def child_main(encoded) do
    {root, kind, stage, requested?, change?, source_root} =
      encoded |> Base.decode64!() |> :erlang.binary_to_term()

    # These are the actual three shipped sources, not fixture substitutes. The
    # unused CodingTools artifact formatter needs no dependency boot here.
    Code.compiler_options(no_warn_undefined: [Loopex.ArtifactStore])

    for source <- ["coding_tools.ex", "tool_glob.ex", "read_only_tools.ex"],
        do: Code.require_file(Path.join(source_root, source))

    workspace = Path.join(root, "workspace")
    File.mkdir!(workspace)
    {:ok, workspace} = Loopex.Executor.Local.CodingTools.resolve(workspace, ".")
    target = Path.join(workspace, "watched")
    File.mkdir!(Path.join(root, "home"))

    case stage do
      stage when stage in [:directory_identity, :directory_type] ->
        File.mkdir!(target)
        File.write!(Path.join(target, "x"), "match\n")

      :growth ->
        File.write!(target, "match\n" <> String.duplicate("x", 1_048_570))

      _ ->
        File.write!(target, "match\n")
    end

    before = info(target)
    harness = self()
    reference = make_ref()

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        receive do
          {:start, ^reference} ->
            arguments =
              case kind do
                :grep -> %{"pattern" => "match"}
                :find -> %{"pattern" => "**"}
                :ls -> %{"recursive" => true}
              end

            arguments = Map.put(arguments, "path", if(requested?, do: "watched", else: "."))

            {:ok, admitted} =
              Loopex.Executor.Local.ReadOnlyTools.arguments(
                "loopex." <> Atom.to_string(kind),
                arguments
              )

            result = Loopex.Executor.Local.ReadOnlyTools.execute(workspace, admitted, 16_384)
            send(harness, {:result, reference, result})

            receive do
              {:finish, ^reference} -> :ok
            end
        end
      end)

    state = %{
      harness: harness,
      worker: worker,
      target: String.to_charlist(target),
      target_binary: target,
      stage: stage,
      reference: reference,
      opened: false,
      path_stats: 0,
      waiting: nil,
      gated: false
    }

    :ok = :sys.install(:file_server_2, {:identity_fixture, &__MODULE__.debug/3, state})
    1 = :erlang.trace_pattern({:file, :read, 2}, [{:_, [], [{:return_trace}]}], [:local])
    1 = :erlang.trace(worker, true, [:call, {:tracer, harness}])
    send(worker, {:start, reference})

    {result, sizes, gate} =
      observe(worker, worker_monitor, reference, root, target, {change?, stage}, [], nil)

    delivered = :erlang.trace_delivered(worker)
    sizes = flush_trace(worker, delivered, sizes)
    send(worker, {:finish, reference})

    receive do
      {:DOWN, ^worker_monitor, :process, ^worker, :normal} ->
        :ok

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        raise "walk failed: #{inspect(reason)}"
    after
      @timeout -> raise "walk did not acknowledge teardown"
    end

    :ok = :sys.remove(:file_server_2, :identity_fixture)
    1 = :erlang.trace_pattern({:file, :read, 2}, false, [:local])

    report = %{
      result: result,
      read_sizes: Enum.reverse(sizes),
      gate: gate,
      before: before,
      after: info(target),
      worker_down: true,
      otp: :erlang.system_info(:otp_release) |> List.to_string()
    }

    IO.puts("LOOPEX_IDENTITY " <> Base.encode64(:erlang.term_to_binary(report)))
  end

  def debug(state, {:in, {:"$gen_call", {worker, _} = from, request}}, _name)
      when worker == state.worker and not state.gated do
    case request do
      {:open, target, [:read, :binary]} when target == state.target ->
        state = %{state | opened: true}
        if state.stage == :before_read, do: before_operation(state, from, request), else: state

      {:read_link_info, target, [{:time, :posix}]}
      when (target == state.target or target == state.target_binary) and state.opened ->
        state = %{state | path_stats: state.path_stats + 1}

        cond do
          state.stage == :after_read and state.path_stats == 2 ->
            before_operation(state, from, request)

          state.stage == :growth and state.path_stats == 1 ->
            after_operation(state, from, request)

          true ->
            state
        end

      {:list_dir_all, target}
      when target == state.target and state.stage in [:directory_identity, :directory_type] ->
        after_operation(state, from, request)

      _ ->
        state
    end
  end

  def debug(%{waiting: {from, request}} = state, {:out, reply, from, _}, _name) do
    release(state, {:after, request, reply})
    %{state | gated: true, waiting: nil}
  end

  def debug(state, _event, _name), do: state

  defp before_operation(state, _from, request) do
    true = :erlang.suspend_process(state.worker)
    release(state, {:before, request, nil})
    %{state | gated: true}
  end

  defp after_operation(state, from, request) do
    true = :erlang.suspend_process(state.worker)
    %{state | waiting: {from, request}}
  end

  defp release(state, observation) do
    send(state.harness, {:gate, state.reference, self(), observation})

    try do
      receive do
        {:release, reference} when reference == state.reference -> :ok
      after
        @timeout -> raise "filesystem gate was not released"
      end
    after
      true = :erlang.resume_process(state.worker)
    end
  end

  defp observe(worker, monitor, reference, root, target, {change?, stage} = change, sizes, gate) do
    receive do
      {:gate, ^reference, server, observation} ->
        true = is_nil(gate)
        {:status, :suspended} = Process.info(worker, :status)
        if change?, do: mutate(root, target, observation, stage)
        send(server, {:release, reference})
        observe(worker, monitor, reference, root, target, change, sizes, describe(observation))

      {:trace, ^worker, :return_from, {:file, :read, 2}, reply} ->
        observe(
          worker,
          monitor,
          reference,
          root,
          target,
          change,
          [read_size(reply) | sizes],
          gate
        )

      {:trace, ^worker, :call, {:file, :read, _}} ->
        observe(worker, monitor, reference, root, target, change, sizes, gate)

      {:result, ^reference, result} ->
        true = not is_nil(gate)
        {result, sizes, gate}

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        raise "walk exited: #{inspect(reason)}"
    after
      @timeout -> raise "filesystem gate/result was not observed"
    end
  end

  defp mutate(_root, target, {:after, {:read_link_info, _, _}, {:ok, _}}, :growth) do
    {:ok, handle} = :prim_file.open(target, [:append, :binary])
    :ok = :prim_file.write(handle, "x")
    :ok = :prim_file.close(handle)
  end

  defp mutate(root, target, {:after, {:list_dir_all, _}, {:ok, _}}, stage) do
    :ok = :prim_file.rename(target, Path.join(root, "retired"))

    case stage do
      :directory_identity -> :ok = :prim_file.make_dir(target)
      :directory_type -> :ok = :prim_file.write_file(target, "replacement")
    end
  end

  defp mutate(root, target, {:before, _, nil}, stage) when stage in [:before_read, :after_read] do
    :ok = :prim_file.rename(target, Path.join(root, "retired"))
    :ok = :prim_file.write_file(target, "match\n")
  end

  defp describe({phase, {operation, _}, {:ok, names}}),
    do: %{phase: phase, operation: operation, listed: Enum.map(names, &List.to_string/1)}

  defp describe({phase, {operation, _, _}, {:ok, record}}),
    do: %{phase: phase, operation: operation, observed: stat(record)}

  defp describe({phase, {operation, _, _}, nil}), do: %{phase: phase, operation: operation}

  defp flush_trace(worker, delivered, sizes) do
    receive do
      {:trace, ^worker, :return_from, {:file, :read, 2}, reply} ->
        flush_trace(worker, delivered, [read_size(reply) | sizes])

      {:trace, ^worker, :call, {:file, :read, _}} ->
        flush_trace(worker, delivered, sizes)

      {:trace_delivered, ^worker, ^delivered} ->
        sizes
    after
      @timeout -> raise "read trace was not delivered"
    end
  end

  defp read_size({:ok, bytes}), do: byte_size(bytes)
  defp read_size(:eof), do: :eof
  defp read_size({:error, reason}), do: {:error, reason}
  defp info(path), do: path |> :prim_file.read_link_info([{:time, :posix}]) |> elem(1) |> stat()

  defp stat(record) do
    info = File.Stat.from_record(record)
    %{inode: info.inode, major_device: info.major_device, size: info.size, type: info.type}
  end
end
