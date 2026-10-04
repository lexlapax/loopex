defmodule LoopexComposition.CentralCreationDefaultsTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Loopex.Runtime
  alias Loopex.Store

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_), do: {:deny, :fixture}
  end

  test "physical Store reopen preserves exact implicit create identity and captured resume settings" do
    root = Path.join(System.tmp_dir!(), "m7-central-create-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    options = [
      state_root: Path.join(root, "state"),
      workspace: workspace,
      runtime_id: "central-create",
      policy: Policy,
      model: "openai:unregistered-m7-fixture",
      active_tools: [],
      sampling: %{"max_tokens" => 256},
      cleanup_grace_ms: 137
    ]

    original =
      LoopexComposition.TestHost.with_runtime(options, fn runtime ->
        {:ok, %{control: control}} = Runtime.children(runtime)
        state = :sys.get_state(control)

        assert {:ok, session} =
                 Loopex.create_session(runtime, %{tenant: "fixture"}, command_id: "create")

        assert {:ok, records} = Store.load_records(state.store, session, 0, 16)
        [genesis | _] = records
        assert genesis.payload.kind == "session_genesis_v3"

        assert genesis.payload["initial_configuration"] ==
                 state.session_creation_defaults["initial_configuration"]

        assert genesis.payload["runtime_configuration"] == %{"cleanup_grace_ms" => 137}
        assert genesis.payload["initial_configuration"]["max_tokens"] == 256

        assert genesis.payload["initial_configuration"]["instructions"]["version"] ==
                 "loopex.reference.v1"

        assert genesis.payload["tool_selection"]["definitions"] == []
        assert {:ok, head} = Store.ownership_head(state.store, session, "session")

        %{
          session: session,
          genesis: genesis.payload,
          records: records,
          head: head,
          runtime: runtime.supervisor,
          store: state.store.reference
        }
      end)

    refute Process.alive?(original.runtime)
    refute Process.alive?(original.store)

    assert :reopened ==
             LoopexComposition.TestHost.with_runtime(options, fn runtime ->
               {:ok, %{control: control}} = Runtime.children(runtime)
               state = :sys.get_state(control)
               assert state.sessions == %{}

               assert Runtime.lookup_create_result(runtime, "create", %{"tenant" => "fixture"}) ==
                        {:ok, {:historical, original.session}}

               assert Loopex.create_session(runtime, %{tenant: "fixture"}, command_id: "create") ==
                        {:ok, original.session}

               assert :sys.get_state(control).sessions == %{}

               assert Store.load_records(state.store, original.session, 0, 16) ==
                        {:ok, original.records}

               assert Store.ownership_head(state.store, original.session, "session") ==
                        {:ok, original.head}

               :reopened
             end)

    changed = Keyword.put(options, :sampling, %{"max_tokens" => 512})

    assert :retained ==
             LoopexComposition.TestHost.with_runtime(changed, fn runtime ->
               {:ok, %{control: control}} = Runtime.children(runtime)
               state = :sys.get_state(control)

               assert state.session_creation_defaults["initial_configuration"]["max_tokens"] ==
                        512

               assert Runtime.lookup_create_result(runtime, "create", %{tenant: "fixture"}) ==
                        {:ok, :conflict}

               assert Runtime.lookup_create_result(
                        runtime,
                        "create",
                        %{tenant: "fixture"},
                        original.genesis
                      ) ==
                        {:ok, {:historical, original.session}}

               assert Loopex.create_session(runtime, %{tenant: "fixture"},
                        command_id: "create",
                        genesis: original.genesis
                      ) ==
                        {:ok, original.session}

               assert :sys.get_state(control).sessions == %{}

               assert Store.load_records(state.store, original.session, 0, 16) ==
                        {:ok, original.records}

               assert {:ok, {:prepared, activation}} =
                        Loopex.prepare_resume_session(runtime, original.session, "resume")

               assert {:ok, retained} = Loopex.prepared_session_configuration(activation)
               assert retained.configuration == original.genesis["initial_configuration"]
               assert retained.tool_selection == original.genesis["tool_selection"]
               assert retained.cleanup_grace_ms == 137
               assert {:ok, session} = Loopex.activate_resume(activation)
               assert session == original.session
               assert {:ok, _} = Loopex.session_status(runtime, session)
               :retained
             end)
  end
end
