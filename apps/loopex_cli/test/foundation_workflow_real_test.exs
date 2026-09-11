defmodule LoopexCli.FoundationWorkflowRealTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.CodingTools
  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.ProviderConfiguration
  alias Loopex.ResourcePack
  alias Loopex.Store
  alias LoopexComposition.ResourcePacks

  @source "https://github.com/openai/skills.git"
  @revision "49f948faa9258a0c61caceaf225e179651397431"
  @path "skills/.curated/security-threat-model"
  @skill "security-threat-model"

  # Concept: the attended lane proves the externally sourced workflow with the
  # exact operator entrypoint and its production companion. The deterministic
  # foundation selector separately proves the same behavior without credentials.
  #
  # Technical depth: the M3 selector runner supplies the credential through its
  # bounded private frame. This case never reads or prints it. Both CLI prompts
  # read from the operator's controlling terminal, so import authority and the
  # digest-bound resource decision remain explicit human decisions.
  @tag :real_provider
  @tag timeout: 600_000
  test "public pinned Git import and a real provider complete the admitted skill tool and artifact workflow" do
    require_attended_terminal!()
    root = owned_root()
    on_exit(fn -> File.rm_rf!(root) end)
    state_root = Path.join(root, "state")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)

    command!("git", ["init", "--quiet", workspace], root, build_environment(root))
    full = architecture_fixture()
    File.write!(Path.join(workspace, "architecture.txt"), full)

    cli = build_production_pair(root)

    import_output =
      attended_cli(
        cli,
        [
          "skill",
          "add",
          @source,
          "--rev",
          @revision,
          "--path",
          @path,
          "--state-root",
          state_root,
          "--workspace",
          workspace
        ],
        "Authorize pinned public skill import: source=#{@source} rev=#{@revision} path=#{@path}. " <>
          "Type yes and press Enter.",
        :without_provider
      )

    assert import_output =~ "installed"
    {:ok, workspace_ref} = LoopexCli.ProjectResources.workspace_reference(workspace)

    assert {:ok, manifest} =
             ResourcePacks.discover(workspace,
               workspace_ref: workspace_ref,
               state_root: state_root
             )

    assert {:ok, manifest_digest, normalized} = ResourcePack.digest(manifest)
    assert [pack] = normalized["packs"]
    assert pack["name"] == @skill
    assert pack["origin"] == @source
    assert pack["commit"] == @revision

    assert %{"content" => license_content} =
             Enum.find(pack["files"], &(&1["label"] == "LICENSE.txt"))

    assert license_content =~ "Apache License"
    assert license_content =~ "Version 2.0"

    prompt =
      "Use the selected security threat model skill and controls reference. " <>
        "This verification stops before a final report. First use the read tool on " <>
        "architecture.txt without a range. The file is intentionally larger than one " <>
        "tool response. After that tool result, state whether the complete result was " <>
        "retained and stop. Do not retry the read, ask questions, or write files."

    run_output =
      attended_cli(
        cli,
        [
          "run",
          "--policy",
          "allow-all",
          "--skill",
          @skill,
          "--skill-resource",
          "#{@skill}:references/security-controls-and-assets.md",
          "--state-root",
          state_root,
          "--workspace",
          workspace,
          prompt
        ],
        "Admit exact public skill manifest: source=#{@source} digest=#{manifest_digest}. " <>
          "Type yes and press Enter.",
        :with_provider
      )

    assert run_output =~ "loopex.read"
    assert run_output =~ "completed"
    assert run_output =~ "loopex: done"

    records = retained_records(state_root)

    assert [admission, selection] =
             Enum.filter(records, &(&1.payload.kind == "resource_command_v1"))

    assert admission.payload["disposition"] == "accepted"
    assert admission.payload["command"]["type"] == "admit_resources"
    assert admission.payload["command"]["manifest_digest"] == manifest_digest
    assert selection.payload["disposition"] == "accepted"
    assert selection.payload["command"]["type"] == "activate_skill"
    assert selection.payload["command"]["manifest_digest"] == manifest_digest
    assert selection.payload["command"]["name"] == @skill
    assert selection.payload["command"]["pack_digest"] == ResourcePack.pack_digest(pack)

    assert selection.payload["command"]["supporting_labels"] == [
             "references/security-controls-and-assets.md"
           ]

    encoded =
      inspect(Enum.map(records, & &1.payload), limit: :infinity, printable_limit: :infinity)

    assert encoded =~ "output truncated"
    assert encoded =~ "loopex.read"
    assert [_, locator] = Regex.run(~r/output truncated[^\]]* ([0-9a-f]{64})\]/, encoded)

    assert {^full, 0} =
             cli_process(cli, ["artifact", locator, "--state-root", state_root],
               env: provider_environment(:without_provider)
             )

    replies = provider_replies(records)
    assert length(replies) >= 2

    assert Enum.all?(
             replies,
             &(is_binary(&1["provider_response_id"]) and &1["provider_response_id"] != "")
           )

    assert replies |> Enum.map(& &1["provider_response_id"]) |> Enum.uniq() |> length() ==
             length(replies)

    assert Enum.all?(replies, &(&1["streamed"] and &1["delta_count"] > 0))

    identity = List.last(replies)["identity"]
    assert {:ok, expected_identity} = ReqLLM.identity(ReqLLM.default_model())
    assert identity["provider"] == expected_identity.provider
    assert identity["model"] == expected_identity.model
    assert identity["endpoint"] == expected_identity.endpoint

    IO.puts(
      :stderr,
      "loopex M3 public-skill workflow observed: source=#{@source} rev=#{@revision} " <>
        "manifest_digest=#{manifest_digest} provider_response_ids=" <>
        Enum.map_join(replies, "+", & &1["provider_response_id"])
    )

    report_real_path(identity)
  end

  defp owned_root do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-m3-real-workflow-#{nonce}"
      )

    File.mkdir!(root)
    root
  end

  defp require_attended_terminal! do
    # The selector runner consumes its bounded credential frame from stdin before
    # compiling this file. Import and resource trust therefore use the separate
    # controlling terminal. An unattended invocation refuses here instead of
    # starting the public import and later waiting for input that cannot arrive.
    case File.open("/dev/tty", [:read, :write]) do
      {:ok, terminal} ->
        File.close(terminal)

      {:error, reason} ->
        flunk(
          "M3 real workflow requires an attended controlling terminal; " <>
            "run the full gate from a terminal (#{inspect(reason)})"
        )
    end
  end

  defp architecture_fixture do
    header = """
    # Sample service architecture

    An internet gateway authenticates requests before a private worker reads queued jobs.
    The worker reads a scoped token from process memory and writes audit events to append-only storage.
    """

    header <>
      String.duplicate(
        "The gateway validates schema, rate limits callers, and never logs bearer tokens.\n",
        div(CodingTools.limits().read_bytes * 3, 80)
      )
  end

  defp build_production_pair(root) do
    source_root = Path.expand("../../..", __DIR__)
    output = Path.join([source_root, "apps", "loopex_cli", "loopex"])
    built = Path.join(root, "loopex")
    previous = File.read(output)
    previous_mode = file_mode(output)
    build = Path.join(root, "production-build")
    Enum.each(["home", "hex-home"], &File.mkdir_p!(Path.join(root, &1)))

    try do
      command!(
        System.find_executable("mix") || flunk("Mix executable unavailable"),
        ["escript.build"],
        Path.join([source_root, "apps", "loopex_cli"]),
        build_environment(root) ++
          [
            {"MIX_ENV", "test"},
            {"MIX_BUILD_PATH", build},
            {"LOOPEX_PROVIDER_API_KEY", nil},
            {"ANTHROPIC_API_KEY", nil},
            {"OPENAI_API_KEY", nil}
          ]
      )

      File.cp!(output, built)
      File.chmod!(built, file_mode(output))
    after
      restore(output, previous, previous_mode)
    end

    verify_production_cli!(built)
    verify_production_companion!(build)
    built
  end

  defp verify_production_cli!(cli) do
    {:ok, sections} = :escript.extract(String.to_charlist(cli), [])
    {:ok, entries} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])

    [{_path, beam}] =
      Enum.filter(
        entries,
        &(Path.basename(List.to_string(elem(&1, 0))) == "Elixir.LoopexCli.beam")
      )

    assert {:ok, {LoopexCli, [exports: exports]}} = :beam_lib.chunks(beam, [:exports])
    assert {:main, 1} in exports
  end

  defp verify_production_companion!(build) do
    launch = Path.join(build, "loopex_provider.launch")
    {:ok, [configuration]} = :file.consult(String.to_charlist(launch))
    {:ok, validated} = ProviderConfiguration.validate(configuration)
    assert :ok = ProviderConfiguration.verify_artifact(validated)
    assert validated.worker_path == Path.join(build, "loopex_provider")
  end

  defp build_environment(root) do
    [
      {"HOME", Path.join(root, "home")},
      {"TMPDIR", root},
      {"HEX_HOME", Path.join(root, "hex-home")},
      {"HEX_OFFLINE", "1"},
      {"MIX_OS_CONCURRENCY_LOCK", "0"},
      {"ERL_CRASH_DUMP", "/dev/null"},
      {"ERL_CRASH_DUMP_SECONDS", "0"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"}
    ]
  end

  defp attended_cli(cli, arguments, notice, credential_scope) do
    shell = "printf '%s\\n' \"$1\" >/dev/tty || exit 2; shift; exec \"$@\" </dev/tty"

    command!(
      "/bin/sh",
      ["-c", shell, "loopex-attended", notice, cli | arguments],
      Path.dirname(cli),
      provider_environment(credential_scope)
    )
  end

  defp provider_environment(:with_provider), do: []

  defp provider_environment(:without_provider) do
    [
      {"LOOPEX_PROVIDER_API_KEY", nil},
      {"ANTHROPIC_API_KEY", nil},
      {"OPENAI_API_KEY", nil}
    ]
  end

  defp cli_process(cli, arguments, options) do
    System.cmd(cli, arguments, Keyword.merge([stderr_to_stdout: true], options))
  end

  defp retained_records(state_root) do
    assert {:ok, [%{session_id: session_id}]} = Loopex.list_sessions(state_root)
    copy = Path.join(state_root, "attended-reader.log")
    File.cp!(Path.join(state_root, "store.log"), copy)
    {:ok, store_pid} = Store.Local.start_link(path: copy)

    try do
      {:ok, store} = Store.new(Store.Local, store_pid)
      {:ok, records} = Store.load_records(store, session_id, 0, 1_000)
      records
    after
      stop_store(store_pid)
    end
  end

  defp provider_replies(records) do
    records
    |> Enum.filter(
      &(&1.payload.kind == "model_attempt_settled_v2" and
          &1.payload["conversation"] == "canonical")
    )
    |> Enum.map(&get_in(&1.payload, ["result", "reply"]))
  end

  defp report_real_path(identity) do
    report = %{
      "provider" => identity["provider"],
      "model" => identity["model"],
      "endpoint" => identity["endpoint"],
      "adapter_build" => "loopex_llm_reqllm@#{Loopex.version()}",
      "executor_build" => "loopex_executor_local@#{Loopex.version()}",
      "executor_identity" => "executor-local",
      "tool_identity" =>
        CodingTools.definitions()
        |> Enum.map(&"#{&1["tool_id"]}@#{&1["tool_version"]}")
        |> Enum.sort()
        |> Enum.join("+")
    }

    if Code.ensure_loaded?(Loopex.M1Gate.RealPathEvidence),
      do: assert(:ok = apply(Loopex.M1Gate.RealPathEvidence, :report, [report]))
  end

  defp command!(executable, arguments, directory, environment) do
    {output, status} =
      System.cmd(executable, arguments,
        cd: directory,
        env: environment,
        stderr_to_stdout: true
      )

    assert status == 0, "command failed (#{Path.basename(executable)}):\n#{output}"
    output
  end

  defp file_mode(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.mode
      {:error, :enoent} -> nil
    end
  end

  defp restore(path, {:ok, bytes}, mode) do
    File.write!(path, bytes)
    File.chmod!(path, mode)
  end

  defp restore(path, {:error, :enoent}, nil), do: File.rm(path)

  defp stop_store(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _reason -> :ok
    end
  end
end
