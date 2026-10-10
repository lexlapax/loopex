Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexCli.ChatBuiltWorkflowTest do
  use ExUnit.Case, async: false

  # Concept: the outer fixture budget covers the complete multi-process witness.
  # Technical depth: 60 seconds for preparation, three original 60-second OS
  # command windows, three 5-second failure joins and 15 seconds for the existing
  # provider/fixture cleanup observations. Product deadlines stay independent.
  @moduletag timeout: 270_000

  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias Loopex.Store.Local.Log

  # Concept: an ordinary configured chat survives a fresh command process.
  # Technical depth: original main/1 and Chat beams run in the actual escript.
  # Only its accepted compile-time ProviderLaunch input binds a controlled HTTP
  # companion. Hosted, attended and self-contained package proofs remain separate.
  test "built configured chat retains settings instructions tools and history on fresh resume" do
    root = owned_root()
    credential = "m7-built-chat-synthetic-credential"
    instruction = "Keep the original chat instruction 猫.\n"
    File.mkdir!(Path.join(root, "workspace"))
    File.mkdir!(Path.join(root, "home"))
    File.write!(Path.join(root, "system.txt"), instruction)
    path = Path.join(root, "chat.json")
    profile = profile()
    File.write!(path, JSON.encode!(profile))

    provider =
      ProviderFixture.new(:reply,
        credential: credential,
        response_bodies: [
          text_response("first assistant reply", "built_first"),
          text_response("second assistant reply", "built_second"),
          text_response("resumed assistant reply", "built_resumed")
        ]
      )

    executable = build_command(root, provider)
    first = start_command(executable, ["chat", "--config", path], root, credential)

    {first, first_controls} =
      try do
        first = prompt(first, "first ordinary prompt", "2", provider)
        first = prompt(first, "second ordinary prompt", "4", provider)
        true = Port.command(first.port, "/status\n")
        first = await_control(first, &(&1["event"] == "status"))
        true = Port.command(first.port, "/quit\n")
        finish_command(first, 0)
      after
        stop_command(first)
      end

    assert_output_planes(first, "> first assistant reply\n> second assistant reply\n")
    session_id = assert_status(first_controls)
    assert Enum.map(inputs(first_controls), & &1["input_sequence"]) == ~w(1 2 3 4 5 6)
    assert Enum.map(waits(first_controls), & &1["input_sequence"]) == ~w(2 4 6)
    [first_wait, second_wait, quit_wait] = waits(first_controls)
    assert is_binary(first_wait["run_id"]) and is_binary(second_wait["run_id"])
    refute first_wait["run_id"] == second_wait["run_id"]
    assert quit_wait["run_id"] == second_wait["run_id"]
    assert_closing(first_controls)
    refute first.stdout <> File.read!(first.stderr) =~ credential

    state = Path.join(root, "state")
    assert {:ok, [%{session_id: retained_session}]} = LoopexCli.SessionCatalog.list(state)
    assert LoopexProtocol.Wire.encode_identity(retained_session) == session_id
    assert {:ok, ^retained_session} = LoopexProtocol.Wire.session_identity(session_id)
    genesis = genesis(state)
    captured_instructions = genesis["initial_configuration"]["instructions"]
    assert captured_instructions["version"] == "loopex.explicit.v1"
    assert captured_instructions["base"] == instruction
    assert captured_instructions["environment"] != ""
    assert captured_instructions["appendix"] == ""

    expected_system =
      "loopex.explicit.v1: " <> instruction <> "\n\n" <> captured_instructions["environment"]

    assert captured_instructions["digest"] ==
             Base.encode16(:crypto.hash(:sha256, expected_system), case: :lower)

    assert genesis["initial_configuration"]["max_tokens"] == 128
    assert genesis["runtime_configuration"] == %{"cleanup_grace_ms" => 5000}
    assert length(genesis["tool_selection"]["definitions"]) == 5

    changed_instruction = "Changed file defaults must not replace the original instruction.\n"
    File.write!(Path.join(root, "system.txt"), changed_instruction)

    changed =
      profile
      |> put_in(["session", "model"], "anthropic:claude-fable-5-1")
      |> put_in(["session", "tools"], "none")
      |> put_in(["session", "max_tokens"], 256)
      |> put_in(["session", "cleanup_grace_ms"], 1000)

    File.write!(path, JSON.encode!(changed))

    resumed =
      start_command(
        executable,
        ["chat", "--config", path, "--resume", retained_session],
        root,
        credential
      )

    {resumed, resumed_controls} =
      try do
        resumed = prompt(resumed, "third ordinary prompt", "2", provider)
        true = Port.command(resumed.port, "/status\n")
        resumed = await_control(resumed, &(&1["event"] == "status"))
        true = Port.command(resumed.port, "/quit\n")
        finish_command(resumed, 0)
      after
        stop_command(resumed)
      end

    refute resumed.port == first.port
    refute resumed.monitor == first.monitor

    assert_output_planes(
      resumed,
      "> first assistant reply\n> second assistant reply\n> resumed assistant reply\n"
    )

    assert assert_status(resumed_controls) == session_id
    assert Enum.map(inputs(resumed_controls), & &1["input_sequence"]) == ~w(1 2 3 4)
    assert Enum.map(waits(resumed_controls), & &1["input_sequence"]) == ~w(2 4)
    [resumed_wait, resumed_quit] = waits(resumed_controls)
    assert is_binary(resumed_wait["run_id"])
    refute resumed_wait["run_id"] in [first_wait["run_id"], second_wait["run_id"]]
    assert resumed_quit["run_id"] == resumed_wait["run_id"]
    assert_closing(resumed_controls)

    assert %{"value" => "5000", "origin" => "committed"} =
             Enum.find(settings(resumed.stderr), &(&1["setting"] == "/session/cleanup_grace_ms"))

    assert genesis(state) == genesis
    refute resumed.stdout <> File.read!(resumed.stderr) =~ credential

    assert [{one, true}, {two, true}, {three, true}] = ProviderFixture.events(provider)
    assert ProviderFixture.methods(provider) == ["POST", "POST", "POST"]

    for request <- [one, two, three] do
      assert request["max_tokens"] == 128
      assert request["model"] == one["model"]
      assert request["tools"] == one["tools"]
      assert length(request["tools"]) == 5
      assert for(%{"text" => text} <- List.wrap(request["system"]), do: text) == [expected_system]
      refute Enum.any?(texts(request), &String.contains?(&1, changed_instruction))
    end

    assert Enum.filter(texts(one), &(&1 in prompts())) == ["first ordinary prompt"]

    assert Enum.filter(texts(two), &(&1 in prompts())) ==
             ["first ordinary prompt", "second ordinary prompt"]

    history = [
      "first ordinary prompt",
      "first assistant reply",
      "second ordinary prompt",
      "second assistant reply",
      "third ordinary prompt"
    ]

    assert Enum.filter(texts(two), &(&1 in history)) == Enum.take(history, 3)
    assert Enum.filter(texts(three), &(&1 in history)) == history

    # Concept: malformed authored startup cannot create a session or dispatch.
    # Technical depth: use the same built main and retain the existing session
    # and all three positive provider observations unchanged.
    invalid = Path.join(root, "invalid.json")
    File.write!(invalid, "{")
    before = ProviderFixture.events(provider)
    refused = start_command(executable, ["chat", "--config", invalid], root, credential)

    {refused, controls} =
      try do
        finish_command(refused, 1)
      after
        stop_command(refused)
      end

    assert_output_planes(refused, "")
    assert Enum.any?(controls, &(&1["event"] == "error"))

    assert [%{"exit_code" => 1, "cleanup" => "confirmed"}] =
             Enum.filter(controls, &(&1["event"] == "closing"))

    assert ProviderFixture.events(provider) == before
    assert {:ok, [%{session_id: ^retained_session}]} = LoopexCli.SessionCatalog.list(state)
  end

  defp profile do
    %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_BUILT_CHAT_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "read-only",
        "max_tokens" => 128,
        "system_class_tokens" => 8000,
        "instructions" => %{"system_file" => "system.txt"},
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 60_000, "token_budget" => 10_000}
      }
    }
  end

  defp owned_root do
    root =
      Path.join(System.tmp_dir!(), "m7-built-chat-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp prompts, do: ["first ordinary prompt", "second ordinary prompt", "third ordinary prompt"]

  defp texts(request) do
    system = for %{"text" => text} <- List.wrap(request["system"]), do: text

    messages =
      for message <- request["messages"],
          %{"type" => "text", "text" => text} <- message["content"],
          do: text

    system ++ messages
  end

  defp genesis(state) do
    assert {:ok, frames, :complete} = Log.read(Path.join(state, "store.log"))

    assert [record] =
             for(
               frame <- frames,
               record <- frame.records,
               record.payload.kind == "session_genesis_v3",
               do: record.payload
             )

    record
  end

  defp inputs(controls), do: Enum.filter(controls, &(&1["event"] == "input"))
  defp waits(controls), do: Enum.filter(controls, &(&1["event"] == "wait"))

  defp assert_status(controls) do
    assert [
             %{
               "session_id" => session,
               "model" => "anthropic:claude-haiku-4-5-20251001",
               "configuration_version" => "1",
               "run_id" => nil
             }
           ] =
             Enum.filter(controls, &(&1["event"] == "status"))

    assert Enum.all?(waits(controls), &(&1["session_id"] == session))
    session
  end

  defp assert_closing(controls) do
    assert [
             %{
               "exit_code" => 0,
               "cleanup" => "confirmed",
               "last_outcome" => %{"outcome" => "completed"}
             }
           ] =
             Enum.filter(controls, &(&1["event"] == "closing"))

    refute Enum.any?(controls, &(&1["event"] == "error"))
    assert Enum.all?(inputs(controls), &(&1["disposition"] == "admitted"))

    assert Enum.all?(
             waits(controls),
             &(&1["state"] == "settled" and
                 &1["outcome"]["outcome"] == "completed")
           )
  end

  defp start_command(command, arguments, root, credential) do
    stderr = Path.join(root, "stderr-#{System.unique_integer([:positive])}")
    File.write!(stderr, "")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args:
          [
            "-c",
            "stderr=$1; command=$2; shift 2; exec \"$command\" \"$@\" 2>\"$stderr\"",
            "chat-witness",
            stderr,
            command
          ] ++ arguments,
        cd: root,
        env: [
          {~c"LOOPEX_HOME", String.to_charlist(Path.join(root, "state"))},
          {~c"M7_BUILT_CHAT_SLOT", String.to_charlist(credential)},
          {~c"LOOPEX_PROVIDER_API_KEY", false},
          {~c"ANTHROPIC_API_KEY", false},
          {~c"OPENAI_API_KEY", false},
          {~c"OPENROUTER_API_KEY", false},
          {~c"OPEN_ROUTER_API_KEY", false},
          {~c"LANG", ~c"C.UTF-8"},
          {~c"LC_ALL", ~c"C.UTF-8"}
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    %{
      port: port,
      monitor: :erlang.monitor(:port, port),
      os_pid: os_pid,
      stderr: stderr,
      stdout: "",
      cutoff: System.monotonic_time(:millisecond) + 60_000
    }
  end

  defp prompt(state, content, sequence, provider) do
    true = Port.command(state.port, content <> "\n/wait\n")
    state = await_control(state, &(&1["event"] == "wait" and &1["input_sequence"] == sequence))
    assert ProviderFixture.pid(provider) > 0
    namespace = ProviderFixture.namespace(provider)
    ProviderFixture.assert_gone(provider)
    refute File.exists?(namespace)
    state
  end

  defp controls(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "@loopex " <> json -> [JSON.decode!(json)]
      _ -> []
    end)
  end

  defp await_control(state, predicate) do
    if Enum.any?(controls(state.stdout), predicate) do
      state
    else
      remaining = remaining(state.cutoff)

      receive do
        {port, {:data, bytes}} when port == state.port ->
          await_control(%{state | stdout: state.stdout <> bytes}, predicate)

        {port, {:exit_status, status}} when port == state.port ->
          flunk("built chat exited #{status} before its control barrier")
      after
        remaining ->
          flunk("built chat did not emit its control barrier within the original cutoff")
      end
    end
  end

  defp finish_command(state, expected) do
    remaining = remaining(state.cutoff)

    receive do
      {port, {:data, bytes}} when port == state.port ->
        finish_command(%{state | stdout: state.stdout <> bytes}, expected)

      {port, {:exit_status, status}} when port == state.port ->
        assert status == expected
        monitor = state.monitor
        port = state.port
        assert_receive {:DOWN, ^monitor, :port, ^port, :normal}, remaining(state.cutoff)
        assert Port.info(port) == nil
        {state, controls(state.stdout)}
    after
      remaining -> flunk("built chat did not exit within its original fixture cutoff")
    end
  end

  defp assert_output_planes(state, expected_text) do
    lines = String.split(state.stdout, "\n", trim: true)

    assert Enum.all?(
             lines,
             &(String.starts_with?(&1, "@loopex ") or String.starts_with?(&1, "> "))
           )

    assistant =
      lines |> Enum.filter(&String.starts_with?(&1, "> ")) |> Enum.map_join(&(&1 <> "\n"))

    assert assistant == expected_text
    refute File.read!(state.stderr) =~ "@loopex "
    refute state.stdout <> File.read!(state.stderr) =~ "M7_BUILT_CHAT_SLOT"
  end

  defp settings(path) do
    for line <- String.split(File.read!(path), "\n", trim: true),
        String.starts_with?(line, "{"),
        %{"setting" => _} = row <- [JSON.decode!(line)],
        do: row
  end

  defp remaining(cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0, "built chat fixture cutoff exhausted"
    remaining
  end

  defp stop_command(state) do
    # Concept: failure must not abandon the exact command process still owned.
    # Technical depth: a live port binds the captured OS PID until it is reaped;
    # the cleanup join has a separate fixed 5,000 ms fixture allowance. No second
    # command, provider attempt or renewed success cutoff is admitted.
    case Port.info(state.port, :os_pid) do
      {:os_pid, pid} when pid == state.os_pid ->
        {_output, _status} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)])
        port = state.port
        monitor = state.monitor
        assert_receive {:DOWN, ^monitor, :port, ^port, _}, 5000

      nil ->
        :ok
    end
  end

  defp build_command(root, provider) do
    {:ok, _} = Application.ensure_all_started(:mix)

    build = fn ->
      assert Path.expand(Mix.Project.compile_path()) ==
               Path.expand(Application.app_dir(:loopex_cli, "ebin"))

      ordinary = Path.expand(Mix.Project.config()[:escript][:path] || "loopex")
      beam_paths = Path.wildcard(Path.join(Mix.Project.compile_path(), "*.beam"))
      input_paths = [ordinary | beam_paths]
      original_inputs = Map.new(input_paths, &{&1, File.read(&1)})
      launch = Path.join(root, "provider.launch")

      configuration =
        Keyword.take(provider.options, [
          :worker_path,
          :interpreter_path,
          :worker_sha256,
          :build_manifest_sha256
        ])

      File.write!(launch, :io_lib.format(~c"~tp.~n", [configuration]))
      command = Path.join(root, "loopex")
      original = Mix.Project.config()[:escript]
      assert original[:main_module] == LoopexCli

      with_provider_launch(launch, fn launch_beam ->
        Mix.ProjectStack.merge_config(escript: Keyword.put(original, :path, command))

        try do
          Mix.Tasks.Escript.Build.run(["--no-compile", "--no-deps-check"])
          replace_launch_beam(command, launch_beam)
        after
          Mix.ProjectStack.merge_config(escript: original)
        end
      end)

      assert Map.new(input_paths, &{&1, File.read(&1)}) == original_inputs
      assert Path.wildcard(Path.join(Mix.Project.compile_path(), "*.beam")) == beam_paths
      assert_original_main(command)
      command
    end

    if Mix.Project.get() == LoopexCli.MixProject,
      do: build.(),
      else: Mix.Project.in_project(:loopex_cli, Path.expand("..", __DIR__), fn _ -> build.() end)
  end

  defp with_provider_launch(path, build) do
    module = LoopexCli.ProviderLaunch
    {^module, original, original_path} = :code.get_object_code(module)
    previous_environment = System.get_env("LOOPEX_BUILD_PROVIDER_CONFIG")
    previous_compiler = Code.compiler_options(ignore_module_conflict: true)
    System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", path)

    try do
      [{^module, configured}] =
        Code.compile_file(Path.expand("../lib/provider_launch.ex", __DIR__))

      build.(configured)
    after
      Code.compiler_options(previous_compiler)

      if previous_environment,
        do: System.put_env("LOOPEX_BUILD_PROVIDER_CONFIG", previous_environment),
        else: System.delete_env("LOOPEX_BUILD_PROVIDER_CONFIG")

      :code.purge(module)
      {:module, ^module} = :code.load_binary(module, original_path, original)
    end
  end

  defp replace_launch_beam(command, beam) do
    {:ok, sections} = :escript.extract(String.to_charlist(command), [])
    {:ok, entries} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])
    name = "Elixir.LoopexCli.ProviderLaunch.beam"

    assert [{path, _}] =
             Enum.filter(entries, fn {path, _} -> Path.basename(List.to_string(path)) == name end)

    replaced =
      Enum.map(entries, fn {entry, bytes} -> {entry, if(entry == path, do: beam, else: bytes)} end)

    {:ok, {_, archive}} = :zip.create(~c"loopex.zip", replaced, [:memory])
    :ok = :escript.create(String.to_charlist(command), Keyword.put(sections, :archive, archive))
    {:ok, checked_sections} = :escript.extract(String.to_charlist(command), [])
    {:ok, checked} = :zip.extract(Keyword.fetch!(checked_sections, :archive), [:memory])
    assert Map.new(checked) == Map.new(replaced)
  end

  defp assert_original_main(command) do
    {:ok, sections} = :escript.extract(String.to_charlist(command), [])
    {:ok, entries} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])

    for module <- [LoopexCli, LoopexCli.Chat, LoopexCli.ChatDriver, LoopexCli.ChatConfiguration] do
      name = Atom.to_string(module) <> ".beam"

      beam =
        Enum.find_value(entries, fn {path, bytes} ->
          if Path.basename(List.to_string(path)) == name, do: bytes
        end)

      assert {:ok, {^module, embedded_hash}} = :beam_lib.md5(beam)
      assert {:ok, {^module, current_hash}} = :beam_lib.md5(:code.which(module))
      assert embedded_hash == current_hash
    end
  end

  defp text_response(text, id) do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => id,
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-haiku-4-5-20251001",
          "content" => [],
          "stop_reason" => nil,
          "stop_sequence" => nil,
          "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]
    |> Enum.map_join(fn event -> "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n" end)
  end
end
