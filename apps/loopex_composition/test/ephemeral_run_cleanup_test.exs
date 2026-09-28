defmodule LoopexComposition.Ephemeral.RunCleanupTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "loopex-run-cleanup-#{System.unique_integer([:positive])}")

    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "an unproved stop overrides a one-shot model answer and names its root", %{
    workspace: workspace
  } do
    {port, server} = held_server()
    run = Task.async(fn -> Ephemeral.run("one prompt", options(workspace, port)) end)
    assert_receive {:model_request, ^server}, 15_000
    owner = owner_for(run.pid)
    state = :sys.get_state(owner)
    root = state.startup.owned_root.path
    runner = run.pid

    assert %{borrower: ^runner, request: request, wait_deadline: wait_deadline} =
             state.session.active

    assert is_reference(request)
    on_exit(fn -> File.rm_rf!(root) end)

    assert :erlang.suspend_process(run.pid)
    on_exit(fn -> if Process.alive?(run.pid), do: :erlang.resume_process(run.pid) end)
    install_removal(owner, fn _path -> {:error, :eacces} end)
    send(server, :release)
    await_queued_answer(runner, owner, request, wait_deadline)
    assert :erlang.resume_process(run.pid)

    assert {:error,
            {:cleanup_unproved,
             %{
               root: ^root,
               root_ownership: :owned,
               pending: [:root_removal],
               ending: :none
             }}} = Task.await(run, 20_000)

    assert File.dir?(root)
  end

  test "a permanent post-admission loss keeps the first cleanup map when stop is unavailable", %{
    workspace: workspace
  } do
    {port, server} = held_server()
    run = Task.async(fn -> Ephemeral.run("one prompt", options(workspace, port)) end)
    assert_receive {:model_request, ^server}, 15_000
    owner = owner_for(run.pid)
    state = :sys.get_state(owner)
    root = state.startup.owned_root.path
    on_exit(fn -> File.rm_rf!(root) end)

    Process.exit(state.startup.registered.facade_client, :kill)

    assert {:error,
            {:cleanup_unproved,
             %{
               root: ^root,
               root_ownership: :owned,
               pending: pending,
               ending: {:error, {:session_unavailable, %{run_id: run_id}}}
             }}} = Task.await(run, 20_000)

    assert :run_ending in pending
    assert is_binary(run_id)
    assert File.dir?(root)
  end

  test "a one-shot call returns its ending after a concurrent failed stop is retried", %{
    workspace: workspace
  } do
    {port, server} = held_server()
    run = Task.async(fn -> Ephemeral.run("one prompt", options(workspace, port)) end)
    assert_receive {:model_request, ^server}, 15_000
    owner = owner_for(run.pid)
    state = :sys.get_state(owner)
    root = state.startup.owned_root.path
    session = {:loopex_ephemeral_session, owner, state.cell}
    on_exit(fn -> File.rm_rf!(root) end)
    attempts = :atomics.new(1, signed: false)

    install_removal(owner, fn path ->
      case :atomics.add_get(attempts, 1, 1) do
        1 -> {:error, :eacces}
        _ -> File.rm_rf(path)
      end
    end)

    first_stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert eventually(fn -> :sys.get_state(owner).phase == :stopping end)
    send(server, :release)

    assert {:error, {:cleanup_unproved, %{root: ^root, pending: [:root_removal], ending: ending}}} =
             Task.await(first_stop, 20_000)

    assert {:error, {:run, :cancelled, %{outcome: :cancelled}}} = ending
    assert ^ending = Task.await(run, 20_000)
    assert :atomics.get(attempts, 1) == 2
    refute File.exists?(root)
  end

  test "a bare unavailable stop overrides an answer when its owner exits unmarked", %{
    workspace: workspace
  } do
    {port, server} = held_server()
    run = Task.async(fn -> Ephemeral.run("one prompt", options(workspace, port)) end)
    assert_receive {:model_request, ^server}, 15_000
    owner = owner_for(run.pid)
    state = :sys.get_state(owner)
    root = state.startup.owned_root.path
    runner = run.pid

    assert %{borrower: ^runner, request: request, wait_deadline: wait_deadline} =
             state.session.active

    assert is_reference(request)
    on_exit(fn -> File.rm_rf!(root) end)

    assert :erlang.suspend_process(run.pid)
    on_exit(fn -> if Process.alive?(run.pid), do: :erlang.resume_process(run.pid) end)
    send(server, :release)
    await_queued_answer(runner, owner, request, wait_deadline)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 2_000
    assert :erlang.resume_process(run.pid)
    assert {:error, :session_unavailable} = Task.await(run, 20_000)
  end

  test "a proved stop returns the one-shot answer and removes its root", %{
    workspace: workspace
  } do
    {port, server} = held_server()
    run = Task.async(fn -> Ephemeral.run("one prompt", options(workspace, port)) end)
    assert_receive {:model_request, ^server}, 15_000
    owner = owner_for(run.pid)
    root = :sys.get_state(owner).startup.owned_root.path
    send(server, :release)

    assert {:ok, %{outcome: :completed, text: "fixture answer"}} = Task.await(run, 20_000)
    refute File.exists?(root)
  end

  defp options(workspace, port) do
    [
      policy: Policy,
      model: "ollama:llama3.2",
      base_url: "http://127.0.0.1:#{port}/v1",
      cwd: workspace,
      tools: :none,
      max_tokens: 128,
      timeout: 15_000
    ]
  end

  defp owner_for(creator) do
    supervisor = LoopexComposition.Ephemeral.OwnerSupervisor

    DynamicSupervisor.which_children(supervisor)
    |> Enum.find_value(fn {_, owner, _, _} ->
      if :sys.get_state(owner).creator == creator, do: owner
    end)
    |> case do
      nil -> flunk("the public run has no supervised owner")
      owner -> owner
    end
  end

  defp install_removal(owner, remove) do
    :sys.replace_state(owner, fn state ->
      update_in(state, [:startup, :configuration], fn configuration ->
        Map.put(configuration, :test_seams, %{temp_root: %{rm_rf: remove}})
      end)
    end)
  end

  defp await_queued_answer(runner, owner, request, wait_deadline) do
    assert {:messages, messages} = Process.info(runner, :messages)

    queued =
      Enum.any?(messages, fn
        {^owner, ^request, {:ok, %{outcome: :completed, text: "fixture answer"}}} ->
          true

        _ ->
          false
      end)

    cond do
      queued ->
        assert {:ok, %{outcome: :completed, text: "fixture answer"}} =
                 :sys.get_state(owner).session.last_result

        assert System.monotonic_time() < wait_deadline,
               "completed answer was observed after the public ask deadline"

      System.monotonic_time() < wait_deadline ->
        Process.sleep(10)
        await_queued_answer(runner, owner, request, wait_deadline)

      true ->
        flunk("the completed answer was not queued before the public ask deadline")
    end
  end

  defp held_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    test = self()

    server =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 15_000),
             {:ok, _request} <- read_request(socket, <<>>) do
          send(test, {:model_request, self()})

          receive do
            :release ->
              body =
                JSON.encode!(%{
                  id: "chatcmpl-run-cleanup",
                  object: "chat.completion",
                  created: 1_800_000_000,
                  model: "llama3.2",
                  choices: [
                    %{
                      index: 0,
                      message: %{role: "assistant", content: "fixture answer"},
                      finish_reason: "stop"
                    }
                  ],
                  usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
                })

              :gen_tcp.send(socket, [
                "HTTP/1.1 200 OK\r\n",
                "content-type: application/json\r\n",
                "content-length: ",
                Integer.to_string(byte_size(body)),
                "\r\nconnection: close\r\n\r\n",
                body
              ])
          end

          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {port, server}
  end

  defp read_request(socket, buffered) do
    case :binary.match(buffered, "\r\n\r\n") do
      {header_end, 4} ->
        header_size = header_end + 4
        <<headers::binary-size(^header_size), body::binary>> = buffered

        size =
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_, digits] -> String.to_integer(digits)
            _ -> 0
          end

        if byte_size(body) >= size, do: {:ok, buffered}, else: read_more(socket, buffered)

      :nomatch ->
        read_more(socket, buffered)
    end
  end

  defp read_more(socket, buffered) do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 15_000),
         true <- byte_size(buffered) + byte_size(chunk) <= 1_048_576 do
      read_request(socket, buffered <> chunk)
    else
      other -> other
    end
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
