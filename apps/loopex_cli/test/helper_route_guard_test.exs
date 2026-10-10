Code.require_file(
  "../../loopex_composition/test/support/delegation_runtime_fixture.exs",
  __DIR__
)

defmodule LoopexCli.HelperRouteGuardTest do
  use ExUnit.Case, async: false
  alias LoopexCli.Output.Memory
  @moduletag capture_log: true

  alias LoopexCli.ChatDriver
  alias LoopexComposition.Delegation.Helper
  alias LoopexComposition.DelegationRuntimeFixture, as: Fixture

  # Concept: ADR 0069 on the CLI route: every chat mutation of a helper child
  # refuses before Core admission and the child's history is unchanged.
  test "every chat mutation and resume refuses a helper child and records nothing" do
    fixture =
      Fixture.start([
        %{text: "go", calls: [Fixture.task_call("call-task")]},
        %{text: "Finding.", calls: []},
        %{text: "done", calls: []}
      ])

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    [{child, _}] = Map.to_list(Helper.status(fixture.helper).children)
    {:ok, before} = Loopex.Store.load_records(fixture.store, child, 0, 1_000)
    id = Base.url_encode64("x", padding: false)

    configuration = prepared_configuration()

    for line <- [
          "prompt text",
          "/steer x",
          "/follow-up x",
          "/answer #{id} --choice #{id}",
          ~s(/configure {"max_tokens": 128}),
          "/compact",
          "/abort"
        ] do
      transcript = drive(fixture.runtime, child, line, configuration)
      assert transcript =~ ~s("code":"helper_session_owned"), line
    end

    assert {:ok, ^before} = Loopex.Store.load_records(fixture.store, child, 0, 1_000)

    # Concept: the resume paths share the same guard before preparing an owner.
    assert LoopexComposition.Delegation.guard(fixture.runtime, child, :resume) ==
             {:error, :helper_session_owned}
  end

  # Concept: the chat route fails closed once the bound helper owner is gone.
  # Technical depth: a chat prompt on the parent refuses
  # `helper_owner_unavailable` before admission and the parent records nothing.
  test "a lost helper owner closes chat mutation of every session" do
    fixture =
      Fixture.start([
        %{text: "go", calls: [Fixture.task_call("call-task")]},
        %{text: "Finding.", calls: []},
        %{text: "done", calls: []}
      ])

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    {:ok, before} = Loopex.Store.load_records(fixture.store, parent, 0, 1_000)
    monitor = Process.monitor(fixture.helper)
    Process.exit(fixture.helper, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 5_000

    transcript = drive(fixture.runtime, parent, "prompt text", prepared_configuration())
    assert transcript =~ ~s("code":"helper_owner_unavailable")
    assert {:ok, ^before} = Loopex.Store.load_records(fixture.store, parent, 0, 1_000)

    assert LoopexComposition.Delegation.guard(fixture.runtime, parent, :resume) ==
             {:error, :helper_owner_unavailable}
  end

  defp drive(runtime, session, line, configuration) do
    {:ok, input} = StringIO.open(line <> "\n/quit\n", encoding: :latin1)
    {:ok, output} = Memory.start()
    test = self()

    host =
      spawn(fn ->
        {:ok, driver} =
          ChatDriver.start_link(runtime, session, input, {:owned, output},
            configuration: configuration
          )

        send(test, {:provisional, self(), ChatDriver.run(driver)})
      end)

    on_exit(fn -> if Process.alive?(host), do: Process.exit(host, :kill) end)
    assert_receive {:provisional, ^host, _result}, 10_000
    {transcript, _} = Memory.contents(output)
    transcript
  end

  defp prepared_configuration do
    root =
      Path.join(System.tmp_dir!(), "helper-route-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    File.mkdir_p!(Path.join(root, "workspace"))
    file = Path.join(root, "chat.json")

    profile = %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_HELPER_ROUTE_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "none",
        "system_class_tokens" => 8000,
        "max_tokens" => 1024,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }

    File.write!(file, :json.encode(profile))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, prepared} = LoopexCli.ChatConfiguration.load(["chat", "--config", file], root, nil)
    prepared
  end
end
