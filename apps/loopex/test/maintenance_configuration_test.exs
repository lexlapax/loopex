Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceConfigurationTest do
  use ExUnit.Case, async: true
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionConfiguration}

  test "instruction capture is exact, bounded and explicitly optional" do
    assert MaintenanceConfiguration.capture_instructions(nil) == {:ok, nil}
    input = %{"version" => "host.v1", "body" => "Keep exact bytes 猫\n"}
    assert {:ok, captured} = MaintenanceConfiguration.capture_instructions(input)
    assert captured["rendered_bytes"] == "host.v1: Keep exact bytes 猫\n"
    assert captured["version"] == "host.v1"

    assert captured["digest"] ==
             Base.encode16(:crypto.hash(:sha256, captured["rendered_bytes"]), case: :lower)

    assert {:ok, _} =
             MaintenanceConfiguration.capture_instructions(%{
               input
               | "body" => String.duplicate("x", 2048)
             })

    for invalid <- [
          Map.put(input, "extra", true),
          Map.delete(input, "body"),
          %{input | "body" => ""},
          %{input | "body" => <<255>>},
          %{input | "body" => String.duplicate("x", 2049)},
          %{input | "version" => "bad version"},
          %{input | "version" => String.duplicate("v", 65)},
          %{version: "v1", body: "body"}
        ] do
      assert {:error, :maintenance_instructions_invalid} =
               MaintenanceConfiguration.capture_instructions(invalid)
    end
  end

  test "startup capacity and episode reasoning eligibility remain distinct" do
    model = model()
    assert {:ok, ^model} = MaintenanceConfiguration.validate_model(model)
    assert :ok = MaintenanceConfiguration.eligible_model(model)
    assert {:ok, nil} = MaintenanceConfiguration.validate_model(nil)

    assert {:error, :maintenance_model_unconfigured} =
             MaintenanceConfiguration.eligible_model(nil)

    for changed <- [
          Map.put(model, "reasoning", "default"),
          put_in(model, ["provider_mapping", "thinking_disabled"], false),
          put_in(model, ["provider_mapping", "continuation_required"], true)
        ] do
      assert {:ok, ^changed} = MaintenanceConfiguration.validate_model(changed)

      assert {:error, :maintenance_reasoning_unsupported} =
               MaintenanceConfiguration.eligible_model(changed)
    end

    for {window, output} <- [{1025, 1024}, {nil, nil}] do
      changed =
        model
        |> put_in(["model_capabilities", "context_window"], window)
        |> put_in(["model_capabilities", "output_limit"], output)

      assert {:ok, ^changed} = MaintenanceConfiguration.validate_model(changed)
    end

    for invalid <- [
          Map.put(model, "extra", true),
          Map.delete(model, "reasoning"),
          Map.put(model, "reasoning", "other"),
          put_in(model, ["model_capabilities", "context_window"], 1024),
          put_in(model, ["model_capabilities", "output_limit"], 1023),
          put_in(model, ["model_capabilities", "model"], "other"),
          put_in(model, ["provider_mapping", "handle"], self())
        ] do
      assert {:error, :maintenance_model_invalid} =
               MaintenanceConfiguration.validate_model(invalid)
    end

    long = String.duplicate("m", 2049)

    assert {:error, :invalid_model_metadata} =
             SessionConfiguration.validate_model_metadata(
               long,
               Map.put(model["model_capabilities"], "model", long),
               model["provider_mapping"]
             )
  end

  test "maintenance request uses only its frozen instructions and source with a fixed reply reserve" do
    assert {:ok, instructions} =
             MaintenanceConfiguration.capture_instructions(%{
               "version" => "frozen.v1",
               "body" => "Summarize exact facts 猫\n"
             })

    assert {:ok, [source]} =
             Loopex.Runtime.CompactionSource.encode(
               [%{"role" => "user", "content" => "untrusted fact, not a system instruction"}],
               nil,
               :complete,
               fn -> :ok end
             )

    assert {:ok, request} =
             MaintenanceConfiguration.request(model(), instructions, source.bytes, 1_000_000)

    assert request.model == model()["model"]

    assert request.messages == [
             %{"role" => "system", "content" => "frozen.v1: Summarize exact facts 猫\n"},
             %{"role" => "user", "content" => source.bytes}
           ]

    assert request.tools == []
    assert request.continuation == nil

    assert request.sampling == %{
             "max_tokens" => 1024,
             "reasoning" => "none",
             "provider_mapping" => model()["provider_mapping"]
           }

    assert request.deadline == 1_000_000
    assert request.canonicalization_version == "loopex.model_request.v2"
    assert :ok = Loopex.Model.validate_request(request)
  end

  test "missing or corrupt maintenance captures and sources never inherit ordinary defaults" do
    assert {:ok, instructions} =
             MaintenanceConfiguration.capture_instructions(%{
               "version" => "v1",
               "body" => "private captured summary instructions"
             })

    source =
      "{\"messages\":{\"kind\":\"complete\",\"value\":[{\"content\":\"fact\",\"role\":\"user\"}]},\"prior_checkpoint\":null,\"version\":\"loopex.compaction.source.v2\"}"

    assert {:error, :maintenance_model_unconfigured} =
             MaintenanceConfiguration.request(nil, instructions, source, 123)

    assert {:error, :maintenance_instructions_unconfigured} =
             MaintenanceConfiguration.request(model(), nil, source, 123)

    assert {:error, :maintenance_reasoning_unsupported} =
             MaintenanceConfiguration.request(
               %{model() | "reasoning" => "default"},
               instructions,
               source,
               123
             )

    for corrupt <- [
          Map.put(instructions, "extra", true),
          Map.delete(instructions, "digest"),
          %{instructions | "version" => "different"},
          %{instructions | "rendered_bytes" => "v1: changed"},
          %{instructions | "digest" => String.duplicate("0", 64)}
        ] do
      assert {:error, :maintenance_instructions_invalid} =
               MaintenanceConfiguration.request(model(), corrupt, source, 123)
    end

    for invalid <- [nil, "", <<255>>, String.duplicate("x", 16385)] do
      assert {:error, :context_projection_invalid} =
               MaintenanceConfiguration.request(model(), instructions, invalid, 123)
    end

    assert {:error, :invalid_model_request} =
             MaintenanceConfiguration.request(model(), instructions, source, nil)
  end

  test "two runtimes forward independent captured settings without putting them in session truth" do
    for {id, instructions, selection} <- [
          {"maintenance-a", %{"version" => "a.v1", "body" => "private-maintenance-a"}, model()},
          {"maintenance-b", %{"version" => "b.v1", "body" => "private-maintenance-b"}, nil}
        ] do
      {store_pid, store} = Loopex.M1RuntimeTestStore.start_store()

      {:ok, runtime} =
        Loopex.start_link(
          runtime_id: id,
          store: store,
          context_token_budget: 8192,
          maintenance_instructions: instructions,
          maintenance_model: selection
        )

      on_exit(fn ->
        if Loopex.Runtime.alive?(runtime), do: Loopex.stop(runtime)
        if Process.alive?(store_pid), do: GenServer.stop(store_pid)
      end)

      assert {:ok, session} = Loopex.create_session(runtime, %{}, command_id: "create")
      assert {:ok, children} = Loopex.Runtime.children(runtime)
      assert {:ok, captured} = MaintenanceConfiguration.capture_instructions(instructions)
      control = :sys.get_state(children.control)
      assert control.maintenance_model == selection
      assert control.maintenance_instructions == captured
      [{_, coordinator, _, _}] = DynamicSupervisor.which_children(children.sessions)
      owner = :sys.get_state(coordinator)
      assert owner.session_id == session
      assert owner.maintenance_model == selection
      assert owner.maintenance_instructions == captured
      assert {:ok, public} = Loopex.Runtime.configuration(runtime)
      refute :erlang.term_to_binary(public) =~ "private-maintenance"

      refute :erlang.term_to_binary(Loopex.M1RuntimeTestStore.inspect_state(store_pid)) =~
               "private-maintenance"
    end
  end

  test "invalid supplied settings refuse runtime startup before session state exists" do
    {pid, store} = Loopex.M1RuntimeTestStore.start_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    before = Loopex.M1RuntimeTestStore.inspect_state(pid)
    options = [runtime_id: "invalid-maintenance", store: store, context_token_budget: 8192]

    assert {:error, :maintenance_instructions_invalid} =
             Loopex.start_link(options ++ [maintenance_instructions: %{}])

    assert {:error, :maintenance_model_invalid} =
             Loopex.start_link(options ++ [maintenance_model: %{}])

    assert Loopex.M1RuntimeTestStore.inspect_state(pid) == before
  end

  defp model do
    source = Loopex.ConfiguredGenesisFixture.configuration()

    %{
      "model" => source["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        source["model_capabilities"]
        | "reasoning_levels" => ["none"],
          "context_window" => 16384,
          "output_limit" => 4096
      },
      "provider_mapping" => %{
        source["provider_mapping"]
        | "mapping_revision" => "fixture.disabled.v1",
          "thinking_disabled" => true,
          "thinking" => %{"mode" => "disabled"}
      }
    }
  end
end
