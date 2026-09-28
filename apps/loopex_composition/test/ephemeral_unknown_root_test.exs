defmodule LoopexComposition.Ephemeral.UnknownRootTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  test "pre-claim cleanup uncertainty has no invented root path or claim grant" do
    test = self()

    tmp =
      Path.join(System.tmp_dir!(), "loopex-unknown-root-#{System.unique_integer([:positive])}")

    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    configuration = %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{
        manifest: %{"version" => "loopex.resource_pack/1", "packs" => []},
        shadowed_skills: []
      },
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      test_seams: %{
        temp_root: %{
          tmp: fn -> tmp end,
          entropy: fn 32 ->
            Process.flag(:trap_exit, true)
            send(test, {:candidate_prepare_blocked, self()})

            receive do
              :release_candidate_prepare ->
                send(test, :candidate_prepare_resumed)
                :binary.copy(<<1>>, 32)
            end
          end,
          mkdir: fn path ->
            send(test, {:unexpected_claim, path})
            File.mkdir(path)
          end
        }
      }
    }

    creator =
      spawn(fn ->
        {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})
        send(test, {:result, SessionOwner.start_session(owner, configuration, 20_000)})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:owner, owner, cell}, 2_000
    assert_receive {:candidate_prepare_blocked, root}, 2_000

    on_exit(fn ->
      Process.exit(root, :kill)
      send(creator, :finish)
    end)

    assert %{startup: %{root: ^root, candidate: nil, owned_root: nil}} = :sys.get_state(owner)
    assert File.ls!(tmp) == []

    assert_receive {:result,
                    {:error,
                     {:cleanup_unproved,
                      %{
                        root: nil,
                        root_ownership: :unknown,
                        pending: [:session_subtree],
                        ending: :none
                      }}}},
                   20_000

    assert :atomics.get(cell, 1) == 3
    assert File.ls!(tmp) == []

    send(root, :release_candidate_prepare)
    assert_receive :candidate_prepare_resumed, 1_000
    refute_receive {:unexpected_claim, _path}, 50
    assert File.ls!(tmp) == []
  end
end
