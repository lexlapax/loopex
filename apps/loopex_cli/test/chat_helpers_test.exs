Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatHelpersTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Loopex.AgentLoopFixture
  alias LoopexCli.Chat
  alias LoopexComposition.Delegation
  alias LoopexComposition.Delegation.{Helper, Router, Tool}

  # Concept: a chat whose configuration enables saved roles starts as a helper
  # parent and delegates through its frozen catalog (T04 entrypoint).
  # Technical depth: the real placement lease opens the helper owner; the
  # runtime under the composition seam routes `loopex.task` through it. The
  # parent's instructions name the exact retained catalog address.
  test "an enabled delegation chat creates a bound helper parent and delegates" do
    root =
      Path.join(
        if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"),
        "chat-helpers-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "workspace"))
    File.mkdir!(Path.join(root, "state"))
    File.write!(Path.join(root, "inspect.md"), "Inspect read-only.\n")
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "config.json")

    profile = %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_HELPER_CHAT_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "read-only",
        "max_tokens" => 1024,
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 60_000, "token_budget" => 100_000}
      },
      "roles" => %{
        "inspect" => %{
          "model" => "anthropic:claude-haiku-4-5",
          "instructions_file" => Path.join(root, "inspect.md")
        }
      },
      "delegation" => %{
        "enabled" => true,
        "roles" => ["inspect"],
        "max_children" => 2,
        "token_budget" => 50_000,
        "max_tokens" => 1024,
        "system_class_tokens" => 8000,
        "child_bounds" => %{"max_turns" => 4, "deadline_ms" => 60_000, "token_budget" => 10_000}
      }
    }

    File.write!(path, :json.encode(profile))
    {:ok, input} = StringIO.open("investigate\n/wait\n/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, diagnostic} = StringIO.open("", encoding: :latin1)
    test = self()

    model =
      Loopex.AgentLoopTestModel.start([
        %{
          text: "delegating",
          calls: [
            %{
              id: "call-task",
              name: "task",
              arguments: %{
                "role" => "inspect",
                "description" => "look",
                "prompt" => "Inspect the workspace."
              }
            }
          ]
        },
        %{text: "Finding: empty workspace.", calls: []},
        %{text: "Parent done.", calls: []}
      ])

    options = [
      cwd: root,
      home: nil,
      input: input,
      output: output,
      diagnostic_device: diagnostic,
      mode: :pipe,
      placement_id: fn _ -> {:ok, "chat-helper-runtime"} end,
      with_runtime: fn options, callback ->
        handle = options[:delegation]
        assert %{enabled: true} = handle
        runtime = runtime(root, options, model, handle)
        send(test, {:runtime, runtime, handle})
        result = callback.(runtime)
        assert :ok == Loopex.stop(runtime)
        result
      end,
      install_signal: fn _, _, _, _ -> {:ok, self()} end,
      finish_signal: fn _, _ -> {:ok, :ordinary} end
    ]

    assert Chat.run(["chat", "--config", path], options) == 0
    assert_received {:runtime, _runtime, handle}
    {_, transcript} = StringIO.contents(output)
    assert transcript =~ ~s("state":"settled")
    refute Process.alive?(handle.helper)
    assert File.dir?(Path.join([root, "state", "delegation"]))
    assert length(Loopex.AgentLoopTestModel.dispatched(model)) == 3
    [_parent, child, _final] = Loopex.AgentLoopTestModel.dispatched(model)
    assert Enum.any?(child.messages, &(&1["content"] == "Inspect the workspace."))

    assert Enum.map(child.tools, & &1["tool_id"]) |> Enum.sort() ==
             ~w(loopex.find loopex.grep loopex.ls loopex.read)
  end

  defp runtime(root, options, model, handle) do
    {:ok, store_pid} =
      Loopex.Store.Local.start_link(path: Path.join([root, "state", "test-store.log"]))

    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, store_pid)
    executor = Loopex.AgentLoopTestExecutor.start()

    definitions =
      LoopexCli.ChatConfiguration.selected_definitions(
        LoopexCli.ChatConfiguration.active_tools("read-only")
      ) ++ [Tool.definition()]

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "chat-helper-runtime",
        store: store,
        context_token_budget: 8_192,
        session_creation_defaults:
          AgentLoopFixture.creation_defaults(definitions -- [Tool.definition()],
            model: options[:model]
          ),
        model: %{
          module: Loopex.AgentLoopTestModel,
          model: options[:model],
          options: [script: model, max_tokens: 1024]
        },
        executor:
          Router.wrap(
            %{
              module: Loopex.AgentLoopTestExecutor,
              reference: executor,
              identity: "helper-executor",
              epoch: 1,
              fencing_token: 1,
              workspace_ref: "workspace-ref",
              workspace_lease: "workspace-lease"
            },
            handle.helper
          ),
        tool: nil,
        tools: definitions,
        active_tools: Enum.map(definitions, & &1["tool_id"]),
        policy: Loopex.AgentLoopTestPolicy,
        policy_identity: %{"id" => "loopex.test.helper_chat", "revision" => "1"},
        grant_decision: {:host_policy, :allow},
        bounds: %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000}
      )

    Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    assert :ok = Delegation.bind(handle, runtime, store)
    assert Helper.status(handle.helper).classified == :complete
    runtime
  end
end
