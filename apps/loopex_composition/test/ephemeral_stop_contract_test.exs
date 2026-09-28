defmodule LoopexComposition.Ephemeral.StopContractTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    def decide(_request), do: {:allow, nil}
  end

  defmodule Facade do
    @moduledoc false

    def create_session(_runtime, %{"surface" => "embedded"}, command_id: "create"),
      do: {:ok, "stop-contract-session"}

    def attach(runtime, "stop-contract-session", after_event_sequence: 0) do
      Process.put(:events, [])
      Process.put(:sequence, 0)

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "stop-contract-session",
         attachment_id: "a",
         incarnation_id: "i",
         snapshot: %{}
       }}
    end

    def session_status(_runtime, "stop-contract-session"),
      do:
        {:ok,
         %{
           status: :active,
           owner_epoch: 0,
           active_run_id: nil,
           pending_work_ids: [],
           cleanup_grace_ms: 5_000
         }}

    def command(_attachment, %{type: :prompt} = command) do
      run_id = "run-" <> command.content

      enqueue(%{
        "command_id" => command.command_id,
        "run_id" => run_id,
        "content" => command.content,
        kind: "user.message_appended"
      })

      enqueue(%{
        "run_id" => run_id,
        "content" => "answer: " <> command.content,
        kind: "assistant.message_appended"
      })

      enqueue(%{
        "run_id" => run_id,
        "outcome" => "completed",
        "cleanup_grace_ms" => 5_000,
        kind: "run.finished"
      })

      {:accepted, command.command_id}
    end

    def next_event(_attachment) do
      case Process.get(:events, []) do
        [event | rest] ->
          Process.put(:events, rest)
          {:ok, event}

        [] ->
          {:error, :empty}
      end
    end

    defp enqueue(event) do
      sequence = Process.get(:sequence) + 1
      Process.put(:sequence, sequence)
      Process.put(:events, Process.get(:events) ++ [Map.put(event, :event_sequence, sequence)])
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "loopex-stop-#{System.unique_integer([:positive])}")
    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "concurrent stops share one drain and ignore stale worker and certificate messages", %{
    tmp: tmp
  } do
    test = self()

    drain = fn executor, instance, owner, nonce, _deadline ->
      send(test, {:drain_started, self(), executor, instance, owner, nonce})

      receive do
        :release_drain ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
      end
    end

    session = start_session(tmp, group_drain: drain)
    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)
    first = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:drain_started, worker, executor, instance, ^owner, nonce}, 3_000

    assert %{stage: :process_groups, worker: %{pid: ^worker, result: false}} =
             :sys.get_state(owner).abort

    second = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert eventually(fn -> length(:sys.get_state(owner).stop.waiters) == 2 end)

    send(
      owner,
      {worker, make_ref(), :process_groups, :result, {:ok, nonce}, System.monotonic_time()}
    )

    send(owner, {executor, instance, make_ref(), :groups_empty})

    send(
      owner,
      {self(), make_ref(), :process_groups, :result, {:ok, nonce}, System.monotonic_time()}
    )

    assert %{worker: %{pid: ^worker, result: false, certificate: false}} =
             :sys.get_state(owner).abort

    send(worker, :release_drain)
    assert :ok = Task.await(first, 7_000)
    assert :ok = Task.await(second, 7_000)
    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
    refute_receive {:drain_started, _, _, _, _, _}
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a direct certificate cannot replace a failed drain result", %{tmp: tmp} do
    bad =
      start_session(tmp,
        group_drain: fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:error, :drain_failed}
        end
      )

    peer = start_session(tmp)
    {:loopex_ephemeral_session, bad_owner, bad_cell} = bad
    {:loopex_ephemeral_session, _peer_owner, peer_cell} = peer
    bad_root = owned_root(bad_owner)

    assert {:error,
            {:cleanup_unproved,
             %{pending: [:process_groups], root: ^bad_root, root_ownership: :owned}}} =
             Ephemeral.stop_session(bad)

    assert :atomics.get(bad_cell, 1) == 3
    assert File.dir?(bad_root)
    assert {:error, :session_unavailable} = Ephemeral.ask(bad, "closed")
    assert :atomics.get(peer_cell, 1) == 0
    assert {:ok, %{text: "answer: peer", outcome: :completed}} = Ephemeral.ask(peer, "peer")
    assert :ok = Ephemeral.stop_session(peer)
    assert :atomics.get(peer_cell, 1) == 2
  end

  test "a successful worker return without the direct certificate cannot close", %{tmp: tmp} do
    session =
      start_session(tmp,
        group_drain: fn _executor, _instance, _owner, nonce, _deadline ->
          {:ok, nonce}
        end
      )

    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)

    assert {:error,
            {:cleanup_unproved,
             %{pending: [:process_groups], root: ^root, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
    assert {:error, :session_unavailable} = Ephemeral.stop_session(session)
  end

  test "a matching certificate forged by the drain worker cannot close", %{tmp: tmp} do
    session =
      start_session(tmp,
        fake_group_attestation: false,
        group_drain: fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end
      )

    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)

    assert {:error,
            {:cleanup_unproved,
             %{pending: [:process_groups], root: ^root, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
  end

  test "root-removal refusal retains a retryable root and retry gets a new deadline", %{
    tmp: tmp
  } do
    test = self()
    attempts = :atomics.new(1, signed: false)
    drains = :atomics.new(1, signed: false)

    drain = fn executor, instance, owner, nonce, _deadline ->
      :atomics.add_get(drains, 1, 1)
      send(owner, {executor, instance, nonce, :groups_empty})
      {:ok, nonce}
    end

    remove = fn path ->
      case :atomics.add_get(attempts, 1, 1) do
        1 ->
          {:error, :eacces}

        2 ->
          send(test, {:retry_removal_started, self(), path})

          receive do
            :release_removal -> File.rm_rf(path)
          end
      end
    end

    session = start_session(tmp, group_drain: drain, rm_rf: remove)
    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)

    assert {:error,
            {:cleanup_unproved, %{pending: [:root_removal], root: ^root, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
    assert :atomics.get(attempts, 1) == 1
    assert :atomics.get(drains, 1) == 1
    first_deadline = :sys.get_state(owner).stop.deadline

    retry = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:retry_removal_started, worker, ^root}, 3_000
    assert :sys.get_state(owner).stop.deadline > first_deadline
    assert :atomics.get(drains, 1) == 1
    assert %{stage: :root_removal, worker: %{pid: ^worker}} = :sys.get_state(owner).abort
    send(worker, :release_removal)

    assert :ok = Task.await(retry, 7_000)
    assert :atomics.get(cell, 1) == 2
    assert :atomics.get(attempts, 1) == 2
    refute File.exists?(root)
    assert :ok = Ephemeral.stop_session(session)
  end

  defp start_session(tmp, options \\ []) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    drain =
      options[:group_drain] ||
        fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end

    temp_root = %{tmp: fn -> tmp end}

    temp_root =
      if options[:rm_rf], do: Map.put(temp_root, :rm_rf, options[:rm_rf]), else: temp_root

    test_seams = %{temp_root: temp_root, group_drain: drain}

    test_seams =
      if Keyword.get(options, :fake_group_attestation, true) do
        Map.put(test_seams, :group_attest, fn _executor, _instance, _nonce, _deadline -> :ok end)
      else
        test_seams
      end

    configuration = %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{manifest: manifest, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      timeout: 60_000,
      test_facade: Facade,
      test_seams: test_seams
    }

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    {:loopex_ephemeral_session, owner, cell}
  end

  defp owned_root(owner), do: :sys.get_state(owner).startup.owned_root.path

  defp eventually(predicate, attempts \\ 200)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(5)
      eventually(predicate, attempts - 1)
    end
  end
end
