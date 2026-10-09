defmodule LoopexCli.ConfigInspectionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias LoopexCli.{ChatConfiguration, ConfigInspection}
  @slot "M7_INSPECTION_SECRET_SLOT"
  @secret "selected-credential-canary-69ef"
  @prompt "captured-instruction-canary-43da"
  @model "anthropic:claude-haiku-4-5"
  @canonical "anthropic:claude-haiku-4-5-20251001"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "m7-config-inspection-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    file = Path.join(root, "profile.json")
    File.write!(file, :json.encode(profile(root)))
    File.write!(Path.join(root, "instructions.txt"), @prompt)
    old = System.get_env(@slot)
    System.put_env(@slot, @secret)

    on_exit(fn ->
      if old, do: System.put_env(@slot, old), else: System.delete_env(@slot)
      File.rm_rf!(root)
    end)

    %{root: root, config_path: file}
  end

  test "confirmed inspection rows pass through the existing diagnostic consumer without private captures",
       f do
    configured =
      profile(f.root)
      |> put_in(["session", "instructions"], %{"system_file" => "instructions.txt"})
      |> put_in(["session", "skill_dirs"], ["first", "second"] ++ Enum.map(2..15, &"dir-#{&1}"))

    File.write!(f.config_path, :json.encode(configured))
    assert {:ok, prepared} = ConfigInspection.prepare(show(f), f.root, nil)
    rows = ConfigInspection.settings_rows(prepared.selection, prepared.roles)
    skill_rows = Enum.filter(rows, &String.starts_with?(&1["setting"], "/session/skill_dirs/"))

    assert Enum.map(skill_rows, & &1["setting"]) ==
             Enum.map(0..15, &"/session/skill_dirs/#{&1}")

    assert Enum.find(rows, &(&1["setting"] == "/session/skill_dirs/0"))["value"] ==
             Path.join(f.root, "first")

    assert Enum.find(rows, &(&1["setting"] == "/session/skill_dirs/1"))["value"] ==
             Path.join(f.root, "second")

    assert Enum.find(rows, &(&1["setting"] == "/session/model"))["value"] == @canonical
    refute inspect(rows) =~ @slot
    refute inspect(rows) =~ @secret
    refute inspect(rows) =~ @prompt

    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, consumer} = LoopexComposition.DiagnosticConsumer.start_link(device, 1_000)
      assert :ok = LoopexComposition.DiagnosticConsumer.settings_report(consumer, rows)
      cutoff = System.monotonic_time(:millisecond) + 1_000
      await_report(consumer, cutoff)
      assert {:ok, final} = LoopexComposition.DiagnosticConsumer.close(consumer, cutoff)
      assert final.counts.diagnostic == %{emitted: length(rows), dropped: 0, unconfirmed: 0}
      {"", output} = StringIO.contents(device)

      decoded =
        for line <- String.split(output, "\n", trim: true) do
          assert {:ok, row} = LoopexProtocol.Frame.decode(line, 4_096)
          row
        end

      assert decoded == rows
      refute output =~ @slot
      refute output =~ @secret
      refute output =~ @prompt
    end)
  end

  defp await_report(consumer, cutoff) do
    status = LoopexComposition.DiagnosticConsumer.status(consumer)

    if status.active or status.pending > 0 do
      assert System.monotonic_time(:millisecond) < cutoff
      Process.sleep(1)
      await_report(consumer, cutoff)
    end
  end

  test "effective inspection resolves exact values, origins and escaped paths without private data",
       f do
    profile =
      profile(f.root)
      |> put_in(["session", "instructions"], %{"system_file" => "instructions.txt"})
      |> Map.put("maintenance", %{"model" => @model})
      |> Map.put("trace", %{"enabled" => true, "modules" => ["Loopex.Runtime", "Loopex.*"]})

    File.write!(f.config_path, :json.encode(profile))
    path = Path.join(f.root, "quoted\"line\n猫")
    argv = show(f) ++ ["--workspace", path, "--max-steps", "1267650600228229401496703205376"]

    assert {:ok, prepared} =
             ConfigInspection.prepare(argv, f.root, Path.join(f.root, "env-state"))

    assert prepared.selection.configuration["model"] == @canonical
    assert prepared.selection.configuration["instructions"]["base"] == @prompt
    assert prepared.selection.configuration["context_token_budget"] == 198_976

    output =
      capture_io(fn ->
        assert :ok = ConfigInspection.run(argv, f.root, Path.join(f.root, "env-state"))
      end)

    assert output =~ ~s(/session/model = {"value":"#{@canonical}"} [file#/session/model])
    assert output =~ ~s(/session/context_token_budget = {"value":"198976"} [default])

    assert output =~
             ~s(/session/bounds/max_turns = {"value":"1267650600228229401496703205376"} [flag])

    assert output =~ ~s(/session/instructions/system_file = {"value":)
    assert output =~ ~s(/trace/modules/0 = {"value":"Loopex.Runtime"} [file#/trace/modules/0])
    assert output =~ ~s(/trace/modules/1 = {"value":"Loopex.*"} [file#/trace/modules/1])
    assert output =~ "\\n猫"
    refute output =~ @slot
    refute output =~ @secret
    refute output =~ @prompt
    refute output =~ "provider_mapping"
    refute output =~ "model_capabilities"
    refute output =~ "committed"
    lines = String.split(output, "\n", trim: true)
    pointers = Enum.map(lines, &(String.split(&1, " = ", parts: 2) |> hd()))
    assert pointers == Enum.sort(pointers)
    refute File.exists?(Path.join(f.root, "state"))
    assert System.get_env(@slot) == @secret
  end

  test "inspection measures binding cost without retaining a physical identity", f do
    assert {:ok, inspection} = ConfigInspection.prepare(show(f), f.root, nil)
    assert {:ok, chat} = ChatConfiguration.load(["chat", "--config", f.config_path], f.root, nil)
    definitions = chat.genesis["tool_selection"]["definitions"]
    placeholder = ChatConfiguration.session_options("workspace:" <> String.duplicate("0", 64))

    assert {:ok, measured} =
             ChatConfiguration.genesis(inspection.selection, definitions, placeholder)

    assert byte_size(LoopexProtocol.Canonical.encode(measured)) ==
             byte_size(LoopexProtocol.Canonical.encode(chat.genesis))

    refute Map.has_key?(inspection, :genesis)
    refute Map.has_key?(inspection, :session_options)
    output = capture_io(fn -> assert :ok = ConfigInspection.run(show(f), f.root, nil) end)
    refute output =~ "workspace_binding"
    refute output =~ chat.session_options["workspace_binding"]["workspace_ref"]
  end

  test "credential-free bindings validate and name chat without claiming credential availability",
       f do
    File.write!(
      f.config_path,
      :json.encode(
        profile(f.root)
        |> put_in(["providers"], %{"ollama" => %{"credential" => %{"none" => true}}})
        |> put_in(["session", "model"], "ollama:fixture")
      )
    )

    output = capture_io(fn -> assert :ok = ConfigInspection.run(validate(f), f.root, nil) end)
    assert output == "Configuration valid.\nollama: credential-free binding cannot run chat.\n"
    output = capture_io(fn -> assert :ok = ConfigInspection.run(show(f), f.root, nil) end)
    assert output =~ ~s("reference_form":"credential_free")
    assert output =~ ~s("unavailable_commands":["chat"])
    assert output =~ ~s(/maintenance/model = {"value":"unconfigured"} [default])
    refute output =~ @slot
    refute output =~ @secret
  end

  test "authored bounds remain mandatory before every inspection override", f do
    flags = ["--max-steps", "20", "--deadline-ms", "2000", "--token-budget", "30000"]

    for key <- ~w(max_turns deadline_ms token_budget) do
      File.write!(
        f.config_path,
        :json.encode(update_in(profile(f.root), ["session", "bounds"], &Map.delete(&1, key)))
      )

      assert ConfigInspection.prepare(validate(f) ++ flags, f.root, nil) ==
               {:error, {:missing_member, "/session/bounds/" <> key}}

      output =
        capture_io(fn ->
          assert {:error, _} = ConfigInspection.run(show(f) ++ flags, f.root, nil)
        end)

      assert output == ""
    end
  end

  test "inspection enforces mappings, instruction reads and complete system cost before reporting success",
       f do
    for {profile, expected} <- [
          {put_in(profile(f.root), ["session", "reasoning"], "high"), :invalid_model_mapping},
          {put_in(profile(f.root), ["session", "instructions"], %{"system_file" => "missing.txt"}),
           :invalid_instruction_file},
          {put_in(profile(f.root), ["session", "system_class_tokens"], 1),
           :invalid_session_configuration},
          {Map.put(profile(f.root), "maintenance", %{"model" => "anthropic:claude-fable-5-1"}),
           :maintenance_reasoning_unsupported}
        ] do
      File.write!(f.config_path, :json.encode(profile))
      assert {:error, {class, _}} = ConfigInspection.prepare(validate(f), f.root, nil)
      assert class == expected

      assert capture_io(fn -> assert {:error, _} = ConfigInspection.run(show(f), f.root, nil) end) ==
               ""
    end
  end

  test "saved roles resolve independent child limits and enabled parent tool costs", f do
    File.write!(Path.join(f.root, "role.txt"), "Inspect facts without changing files.")

    profile =
      profile(f.root)
      |> Map.put("roles", %{"reviewer" => %{"model" => @model, "instructions_file" => "role.txt"}})
      |> Map.put("delegation", %{
        "enabled" => true,
        "roles" => ["reviewer"],
        "max_children" => 2,
        "token_budget" => 32768,
        "max_tokens" => 2048,
        "system_class_tokens" => 2000,
        "child_bounds" => %{"max_turns" => 3, "deadline_ms" => 600_000, "token_budget" => 8192}
      })
      |> put_in(["session", "system_class_tokens"], 3000)

    File.write!(f.config_path, :json.encode(profile))
    assert {:ok, prepared} = ConfigInspection.prepare(show(f), f.root, nil)
    child = prepared.roles["reviewer"]
    assert child["model"] == @canonical
    assert child["max_tokens"] == 2048
    assert child["context_token_budget"] == 197_952
    assert child["system_class_tokens"] == 2000
    assert prepared.selection.configuration["max_tokens"] == 1024
    environment = prepared.selection.configuration["instructions"]["environment"]
    assert environment =~ ~s("enabled_roles":["reviewer"])
    assert environment =~ "sha256:"
    output = capture_io(fn -> assert :ok = ConfigInspection.run(show(f), f.root, nil) end)
    assert output =~ ~s(/roles/reviewer/model = {"value":"#{@canonical}"})
    assert output =~ ~s(/roles/reviewer/context_token_budget = {"value":"197952"} [default])

    assert output =~
             ~s(/roles/reviewer/max_tokens = {"value":"2048"} [file#/delegation/max_tokens])

    assert output =~ ~s(/delegation/child_bounds/deadline_ms = {"value":"600000"})
    refute output =~ "Inspect facts without changing files."
    refute output =~ "catalog_digest"

    assert {:ok, %{helpers: true}} =
             ChatConfiguration.load(["chat", "--config", f.config_path], f.root, nil)

    File.write!(
      f.config_path,
      :json.encode(
        profile
        |> put_in(["delegation", "context_token_budget"], 1000)
        |> put_in(["delegation", "system_class_tokens"], 500)
      )
    )

    assert {:error, {_class, "/roles/reviewer"}} = ConfigInspection.prepare(show(f), f.root, nil)
  end

  test "inspection reads no credential slot and calls no runtime, provider or custody entry", f do
    caller = self()
    {tracer, monitor} = spawn_monitor(fn -> collect([]) end)

    functions = [
      {System, :get_env, 0},
      {System, :get_env, 1},
      {System, :get_env, 2},
      {Loopex, :start_link, 1},
      {LoopexComposition, :with_runtime, 2},
      {LoopexComposition.CredentialHost, :open, 1},
      {Loopex.LLM.ReqLLM, :complete, 3}
    ]

    for {module, function, arity} = mfa <- functions do
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, function, arity)
      assert :erlang.trace_pattern(mfa, true, [:local]) > 0
    end

    :erlang.trace(caller, true, [:call, :set_on_spawn, {:tracer, tracer}])

    try do
      before_apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      # Concept: the credential-read witness must observe an actual call.
      # Technical depth: this unrelated unset-name control precedes inspection;
      # the selected credential slot and all-environment reads still refuse.
      System.get_env("M7_INSPECTION_UNRELATED")
      assert {:ok, _} = ConfigInspection.prepare(show(f), f.root, nil)

      assert Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               before_apps

      ref = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^ref}, 1000
      send(tracer, {:read, caller})
      assert_receive {:calls, calls}, 1000
      assert {System, :get_env, ["M7_INSPECTION_UNRELATED"]} in calls

      refute Enum.any?(calls, fn
               {System, :get_env, []} -> true
               {System, :get_env, [@slot | _]} -> true
               {System, :get_env, _} -> false
               _ -> true
             end)
    after
      :erlang.trace(caller, false, [:call, :set_on_spawn])
      for mfa <- functions, do: :erlang.trace_pattern(mfa, false, [:local])
      Process.exit(tracer, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^tracer, :killed}, 1000
    end
  end

  test "actual command dispatch reaches inspection and rejects trace and session flags", f do
    output = capture_io(fn -> assert LoopexCli.dispatch(validate(f)) == :ok end)
    assert output == "Configuration valid.\n"

    for argv <- [
          show(f) ++ ["--trace"],
          validate(f) ++ ["--resume=session"],
          ["config", "unknown", "--config", f.config_path],
          ["config", "show", "--config", f.config_path]
        ] do
      assert capture_io(fn -> assert {:error, _} = LoopexCli.dispatch(argv) end) == ""
    end
  end

  test "the standalone OS entrypoint admits inspection without acquiring missing credentials",
       f do
    root = Path.expand("../../..", __DIR__)
    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))

    args =
      ["--erl", "-noinput -kernel standard_io_encoding latin1"] ++
        Enum.flat_map(paths, &["-pa", &1]) ++
        ["-e", "LoopexCli.main(System.argv())", "--"] ++
        show(f) ++
        ["--workspace", Path.join(f.root, "entry\"line\n猫")]

    {output, status} =
      System.cmd(System.find_executable("elixir"), args,
        cd: root,
        env: [{@slot, nil}, {"LOOPEX_HOME", Path.join(f.root, "entry-state")}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "/session/model"
    assert String.valid?(output)
    assert output =~ "\\n猫"
    refute output =~ @slot
    refute output =~ @prompt
    refute File.exists?(Path.join(f.root, "entry-state"))
  end

  defp collect(calls) do
    receive do
      {:trace, _, :call, mfa} ->
        collect([mfa | calls])

      {:read, from} ->
        send(from, {:calls, Enum.reverse(calls)})
        collect(calls)
    end
  end

  defp show(f), do: ["config", "show", "--config", f.config_path, "--effective"]
  defp validate(f), do: ["config", "validate", "--config", f.config_path]

  defp profile(root),
    do: %{
      "schema_version" => 1,
      "paths" => %{"workspace" => root, "state_root" => Path.join(root, "state")},
      "providers" => %{"anthropic" => %{"credential" => %{"env" => @slot}}},
      "policy" => "refuse-all",
      "session" => %{
        "model" => @model,
        "max_tokens" => 1024,
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 4, "deadline_ms" => 1000, "token_budget" => 16384}
      }
    }
end
