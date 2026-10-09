defmodule Mix.Tasks.Loopex.M7Evidence.CaseRunner do
  @moduledoc """
  ## Concept

  The dispatching entrypoint for M7 coding-fixture cases. It admits a lane
  through the attempts writer, records each case as started before anything
  can call a model, runs the conversation through the trusted fixture policy,
  then reruns the pinned oracle independently and inspects the workspace
  against the allowed changes. Every attempt ends in a recorded mechanical
  result with its retained evidence; nothing is retried.

  ## Technical depth

  `run_lane/3` derives the lane selection from the committed execution
  manifest, admits it with `AttemptWriter.admit/4` and runs the remaining pins
  in order, stopping after a pre-dispatch stop or any non-pass result.

  For each case it stages a fresh attempt directory under the retained run
  root: a disposable `workspace/` copied from the catalog seed (or a
  disposable clone at the pinned base for the external task), and a
  `trusted/` tree holding the oracle copy and the fixed runner rendered by
  `Policy.M7Fixture`. Preparation runs through `M7FixtureChat.prepare/4`, so
  ordinary configuration validates first. A preparation failure appends
  `not_dispatched` with `evidence_incomplete_pre_dispatch` and its preflight
  record. Otherwise the exclusive execution record is written and `started` is
  appended and synced before dispatch.

  Pipe dispatch writes the fixture's prompts with `/wait` barriers; repair and
  long reopen the recorded session for their final prompt, and long compacts
  explicitly before closing. Terminal dispatch hands the operator's standard
  input to the conversation. The independent rerun uses a separately rendered
  runner with the same oracle under an empty environment; feature takes its
  branch from the dispatch result's committed answer. Workspace inspection
  uses the catalog inventory or, for the external checkout, Git's changed
  paths against the pinned base.

  The mechanical result is the first that applies: missing retained evidence
  (`evidence_incomplete_post_dispatch`, evidence null), then
  `assertion_failed` for a failed conversation, oracle, pin check or changed
  path, otherwise `pass`. Provider-failure and required-action classification
  from committed records are not inferred here; the reviewer assigns causes.
  """

  alias LoopexCli.{Chat, M7FixtureChat}
  alias LoopexCli.Policy.M7Fixture, as: Policy
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexProtocol.Canonical
  alias Mix.Tasks.Loopex.M7Evidence.{AttemptWriter, ExecutionManifest, FixtureManifest}

  @reopen %{"m7.repair" => 1, "m7.long" => 1}

  @switches [
    lane: :string,
    attempts_index: :string,
    writer: :string,
    host: :string,
    markers: :string,
    run_root: :string,
    operator: :string,
    matrix: :string,
    external_repository: :string,
    create: :boolean,
    continue: :boolean,
    terminal: :boolean,
    check: :boolean
  ]

  @doc """
  ## Concept

  Run the trusted wrapper for one lane and return its exit status.

  ## Technical depth

  The trusted wrapper's command line (`scripts/m7-fixture-chat.exs`):
  `--lane LANE --attempts-index FILE --writer ID --host ID --markers DIR
  --run-root DIR --operator NAME [--create] [--continue] [--matrix ID]
  [--terminal] [--external-repository DIR] [--check] -- chat --config FILE`.
  It runs from the clean candidate checkout. `--check` admits the lane and
  reports its plan without staging or dispatch. Returns the exit status: 0
  when every case passed or the check admitted, 1 when a case stopped the
  lane, 2 when evidence is unavailable.
  """
  def main(argv, overrides \\ %{}) do
    {flags, config_argv} = Enum.split_while(argv, &(&1 != "chat"))

    with {opts, [], []} <- OptionParser.parse(flags, strict: @switches),
         true <- config_argv != [] or {:error, :invalid_m7_fixture_arguments},
         root = Map.get(overrides, :root, File.cwd!()),
         {:ok, catalog} <- FixtureManifest.load(Path.join(root, "test/fixtures/m7")),
         {:ok, concept} <- File.read(Path.join(root, "docs/plans/M7.md")),
         {:ok, candidate} <- candidate(root, overrides),
         {:ok, writer} <- writer(opts, catalog.catalog["execution_manifest"], overrides) do
      context =
        Map.merge(
          %{
            manifest: catalog.catalog,
            manifest_digest: catalog.digest,
            catalog_root: Path.join(root, "test/fixtures/m7"),
            run_root: opts[:run_root],
            candidate: candidate,
            concept: concept,
            config_argv: config_argv,
            cwd: root,
            mode: if(opts[:continue], do: :continue, else: :new),
            matrix: opts[:matrix],
            dispatch: if(opts[:terminal], do: :terminal, else: :pipe),
            operator: opts[:operator],
            external_repository: opts[:external_repository]
          },
          Map.drop(overrides, [:root, :candidate, :secrets])
        )

      try do
        report(command(writer, opts, context))
      after
        if Process.alive?(writer), do: AttemptWriter.close(writer)
      end
    else
      other -> report({:error, other})
    end
  end

  defp command(writer, opts, context) do
    cond do
      not (is_binary(opts[:lane]) and is_binary(opts[:run_root]) and
             Path.type(opts[:run_root]) == :absolute and is_binary(opts[:operator])) ->
        {:error, :invalid_m7_fixture_arguments}

      opts[:check] ->
        manifest = context.manifest["execution_manifest"]

        with {:ok, selection} <-
               ExecutionManifest.selection(
                 manifest,
                 context.manifest_digest,
                 opts[:lane],
                 context.candidate,
                 context.matrix
               ),
             {:ok, plan} <- AttemptWriter.admit(writer, context.concept, selection, context.mode) do
          {:checked, Enum.map(plan.remaining, & &1.pin["case_key"])}
        end

      true ->
        run_lane(writer, opts[:lane], context)
    end
  end

  defp candidate(_root, %{candidate: candidate}), do: {:ok, candidate}

  defp candidate(root, _overrides) do
    with {"", 0} <- System.cmd("git", ["-C", root, "status", "--porcelain"]),
         {sha, 0} <- System.cmd("git", ["-C", root, "rev-parse", "HEAD"]) do
      {:ok, String.trim(sha)}
    else
      _ -> {:error, :candidate_tree_not_clean}
    end
  end

  defp writer(opts, manifest, overrides) do
    identity = %{
      "writer_id" => opts[:writer],
      "host_id" => opts[:host],
      "marker_dir" => opts[:markers]
    }

    secrets = Map.get(overrides, :secrets, [])
    index = opts[:attempts_index]

    if opts[:create],
      do: AttemptWriter.create(index, manifest["campaign_id"], identity, secrets: secrets),
      else: AttemptWriter.open(index, identity, secrets: secrets)
  end

  defp report(result) do
    {line, status} =
      case result do
        {:checked, cases} -> {"admitted: " <> Enum.join(cases, " "), 0}
        {:ok, results} -> {"passed: " <> summary(results), 0}
        {:stopped, results} -> {"stopped: " <> summary(results), 1}
        {:error, reason} -> {"evidence unavailable: " <> inspect(reason, limit: 8), 2}
        other -> {"evidence unavailable: " <> inspect(elem(other, 0)), 2}
      end

    IO.puts("m7-fixture-chat: " <> line)
    status
  end

  defp summary(results) do
    Enum.map_join(results, " ", fn
      {:ok, result} -> "#{result[:attempt] || "pre-dispatch"}=#{result.mechanical_result}"
      other -> inspect(other, limit: 4)
    end)
  end

  @doc """
  ## Concept

  Admit one lane and run its remaining cases in order.

  ## Technical depth

  `context` holds `:manifest` (the decoded catalog),
  `:manifest_digest`, `:catalog_root`, `:run_root`, `:candidate`, `:concept`,
  `:config_argv`, `:cwd` and optional `:mode` (`:new` or `:continue`),
  `:matrix`, `:dispatch` (`:pipe` or `:terminal`), `:operator`, `:home`,
  `:chat_options` and `:external_repository`.
  """
  def run_lane(writer, lane, context) do
    manifest = context.manifest["execution_manifest"]

    with {:ok, selection} <-
           ExecutionManifest.selection(
             manifest,
             context.manifest_digest,
             lane,
             context.candidate,
             Map.get(context, :matrix)
           ),
         {:ok, plan} <-
           AttemptWriter.admit(writer, context.concept, selection, Map.get(context, :mode, :new)) do
      run_pins(writer, plan.remaining, selection, context, [])
    end
  end

  defp run_pins(_writer, [], _selection, _context, results), do: {:ok, Enum.reverse(results)}

  defp run_pins(writer, [%{pin: pin} | rest], selection, context, results) do
    result = run_case(writer, pin, selection, context)

    case result do
      {:ok, %{mechanical_result: "pass"}} ->
        run_pins(writer, rest, selection, context, [result | results])

      {:ok, _stopped} ->
        {:stopped, Enum.reverse([result | results])}

      error ->
        {:error, Enum.reverse([error | results])}
    end
  end

  @doc false
  def run_case(writer, pin, selection, context) do
    case_id = pin["case_key"]
    attempt = case_id <> "-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Path.join(context.run_root, attempt)

    base =
      Map.merge(
        Map.take(selection, ~w(manifest_digest candidate_sha lane_id logical_matrix_id)),
        %{
          "kind" => "case",
          "version" => 1,
          "case_key" => case_id,
          "subcase_key" => nil,
          "specification_digest" => pin["specification_digest"],
          "verdict" => nil,
          "diagnosis" => nil,
          "disposition" => nil,
          "reviewer_id" => nil,
          "authorized_candidate_sha" => nil,
          "authorization_evidence" => nil
        }
      )

    with :ok <- File.mkdir(root) do
      case stage(case_id, root, context) do
        {:ok, staged} -> dispatch_case(writer, base, attempt, root, staged, context)
        {:error, reason} -> not_dispatched(writer, base, root, reason)
      end
    else
      _ -> {:error, :attempt_run_root_unavailable}
    end
  end

  defp not_dispatched(writer, base, root, reason) do
    with {:ok, preflight} <- retain(root, "preflight.json", %{"refusal" => inspect(reason)}),
         {:ok, record} <-
           AttemptWriter.append(
             writer,
             Map.merge(base, %{
               "state" => "not_dispatched",
               "attempt_id" => nil,
               "mechanical_result" => "evidence_incomplete_pre_dispatch",
               "evidence" => [preflight]
             })
           ) do
      {:ok, %{mechanical_result: "evidence_incomplete_pre_dispatch", record: record}}
    end
  end

  defp dispatch_case(writer, base, attempt, root, staged, context) do
    execution = %{
      "attempt_id" => attempt,
      "case_id" => base["case_key"],
      "manifest_digest" => base["manifest_digest"],
      "candidate_sha" => base["candidate_sha"],
      "operator" => Map.get(context, :operator),
      "workspace" => staged.fixture.workspace,
      "policy" => Policy.identity(staged.capture),
      "pins" => Map.new(staged.fixture.pins, fn {path, pin} -> {path, pin.sha256} end)
    }

    with {:ok, record} <- retain(root, "execution.json", execution),
         {:ok, _started} <-
           AttemptWriter.append(
             writer,
             Map.merge(base, %{
               "state" => "started",
               "attempt_id" => attempt,
               "mechanical_result" => nil,
               "evidence" => [record]
             })
           ) do
      outcome = dispatch(staged, context)

      transcripts =
        Enum.map(outcome.transcripts, fn {name, bytes} -> retain_raw(root, name, bytes) end)

      {oracle_status, oracle} = independent_oracle(staged, outcome, root)
      {changes, inventory} = inspect_changes(staged, root)
      checks = Policy.check(staged.capture)
      retained = [{:ok, record}, oracle, inventory | transcripts]

      mechanical =
        cond do
          Enum.any?(retained, &(not match?({:ok, _}, &1))) ->
            "evidence_incomplete_post_dispatch"

          outcome.exit != 0 or oracle_status != 0 or changes != :ok or checks != :ok ->
            "assertion_failed"

          true ->
            "pass"
        end

      evidence =
        if mechanical == "evidence_incomplete_post_dispatch",
          do: nil,
          else: Enum.map(retained, &elem(&1, 1))

      with {:ok, completed} <-
             AttemptWriter.append(
               writer,
               Map.merge(base, %{
                 "state" => "completed",
                 "attempt_id" => attempt,
                 "mechanical_result" => mechanical,
                 "evidence" => evidence
               })
             ) do
        {:ok, %{mechanical_result: mechanical, record: completed, attempt: attempt, root: root}}
      end
    end
  end

  # Concept: a fresh disposable workspace and a trusted tree per attempt.
  # Technical depth: the runner and oracle live outside the workspace and are
  # pinned with the shell, env, interpreter and catalog before preparation.
  defp stage(case_id, root, context) do
    name = String.replace_prefix(case_id, "m7.", "")
    entry = FixtureManifest.entry(context.manifest, name)
    workspace = Path.join(root, "workspace")
    trusted = Path.join(root, "trusted")

    with true <- is_map(entry) or {:error, :fixture_unavailable},
         :ok <- File.mkdir(trusted),
         :ok <- seed(name, entry, workspace, context),
         oracle = Path.join(trusted, Path.basename(entry["oracle"]["path"])),
         {:ok, _} <- File.copy(Path.join(context.catalog_root, entry["oracle"]["path"]), oracle),
         :ok <- File.chmod(oracle, entry["oracle"]["mode"]),
         environment = Map.get(context, :environment, %{}),
         {:ok, recipe} <- Policy.oracle_runner(case_id, workspace, oracle, environment),
         runner = Path.join(trusted, "run.sh"),
         :ok <- File.write(runner, recipe.bytes),
         :ok <- File.chmod(runner, 0o644),
         {:ok, pins} <-
           pins([
             "/bin/sh",
             "/usr/bin/env",
             recipe.interpreter,
             runner,
             oracle,
             catalog_path(context)
           ]),
         fixture = %{
           case_id: case_id,
           catalog_root: context.catalog_root,
           workspace: workspace,
           runner: runner,
           oracle: oracle,
           environment: environment,
           pins: pins
         },
         {:ok, config_argv} <- attempt_config(context.config_argv, workspace, root),
         {:ok, prepared} <-
           M7FixtureChat.prepare(
             config_argv,
             context.cwd,
             Map.get(context, :home),
             fixture
           ) do
      {:ok,
       %{
         name: name,
         entry: entry,
         fixture: fixture,
         capture: prepared.capture,
         trusted: trusted,
         config_argv: config_argv
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :fixture_preparation_unavailable}
    end
  end

  # Concept: the operator's explicit file, aimed at this attempt's fresh roots.
  # Technical depth: only `paths.workspace` and `paths.state_root` change;
  # ordinary validation of every other member still runs in preparation.
  defp attempt_config(["chat", "--config", template | rest], workspace, root) do
    with {:ok, bytes} <- File.read(template),
         {:ok, profile} <- LoopexCli.ConfigJson.decode(bytes),
         true <- is_map(profile["paths"]) or {:error, :invalid_m7_config},
         profile =
           put_in(profile, ["paths"], %{
             profile["paths"]
             | "workspace" => workspace,
               "state_root" => Path.join(root, "state")
           }),
         path = Path.join(root, "config.json"),
         :ok <- File.write(path, :json.encode(profile), [:exclusive]) do
      {:ok, ["chat", "--config", path | rest]}
    else
      _ -> {:error, :invalid_m7_config}
    end
  rescue
    _ -> {:error, :invalid_m7_config}
  end

  defp attempt_config(_argv, _workspace, _root), do: {:error, :invalid_m7_config}

  defp seed("external", entry, workspace, context) do
    repository = Map.get(context, :external_repository)

    with true <- is_binary(repository) or {:error, :external_repository_unavailable},
         {_, 0} <-
           git(["clone", "--quiet", "--no-hardlinks", repository, workspace], context.run_root),
         {_, 0} <-
           git(
             ["-C", workspace, "checkout", "--quiet", "--detach", entry["base_sha"]],
             context.run_root
           ),
         {_, 0} <- git(["-C", workspace, "remote", "remove", "origin"], context.run_root) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :external_checkout_unavailable}
    end
  end

  defp seed(name, _entry, workspace, context) do
    case File.cp_r(Path.join([context.catalog_root, name, "workspace"]), workspace) do
      {:ok, _} -> :ok
      _ -> {:error, :fixture_seed_unavailable}
    end
  end

  defp catalog_path(context), do: Path.join(context.catalog_root, "manifest.json")

  defp pins(paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, pins} ->
      with {:ok, physical} <- WorkspaceIdentity.resolve_path(path),
           {:ok, stat} <- File.stat(physical),
           {:ok, bytes} <- File.read(physical) do
        pin = %{mode: Bitwise.band(stat.mode, 0o7777), sha256: Canonical.digest_bytes(bytes)}
        {:cont, {:ok, Map.put(pins, path, pin)}}
      else
        _ -> {:halt, {:error, :fixture_pin_unavailable}}
      end
    end)
  end

  defp dispatch(staged, context) do
    case Map.get(context, :dispatch, :pipe) do
      :pipe -> pipe(staged, context)
      :terminal -> chat(staged, context, :stdio, [], "transcript-1.txt")
      fun when is_function(fun, 2) -> fun.(staged, context)
    end
  end

  # Concept: a static piped conversation with barriers and a recorded reopen.
  # Technical depth: the session identity comes from the first conversation's
  # own status record, never from a guess.
  defp pipe(staged, context) do
    prompts = staged.entry["prompts"]
    reopened = Map.get(@reopen, staged.fixture.case_id, 0)
    {first, later} = Enum.split(prompts, length(prompts) - reopened)
    compact = if staged.fixture.case_id == "m7.long", do: ["/compact", "/wait"], else: []
    input = Enum.flat_map(first, &[&1, "/wait"]) ++ compact ++ ["/status", "/quit"]
    one = chat(staged, context, input, [], "transcript-1.txt")

    with 0 <- one.exit, [_ | _] <- later, {:ok, session} <- session_id(one) do
      input = Enum.flat_map(later, &[&1, "/wait"]) ++ ["/status", "/quit"]
      two = chat(staged, context, input, ["--resume", session], "transcript-2.txt")
      %{two | transcripts: one.transcripts ++ two.transcripts}
    else
      _ -> one
    end
  end

  defp chat(staged, context, input, extra, name) do
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, diagnostics} = StringIO.open("", encoding: :latin1)

    {device, mode} =
      if input == :stdio do
        {:stdio, :interactive}
      else
        {:ok, device} = StringIO.open(Enum.map_join(input, &(&1 <> "\n")), encoding: :latin1)
        {device, :pipe}
      end

    options =
      [
        cwd: context.cwd,
        home: Map.get(context, :home),
        input: device,
        output: output,
        diagnostic_device: diagnostics,
        mode: mode,
        fixture_policy: staged.capture
      ] ++ Map.get(context, :chat_options, [])

    exit = Chat.run(staged.config_argv ++ extra, options)
    {_, stdout} = StringIO.contents(output)
    {_, stderr} = StringIO.contents(diagnostics)

    %{
      exit: exit,
      output: stdout,
      environment: nil,
      transcripts: [{name, stdout}, {String.replace(name, "transcript", "diagnostics"), stderr}]
    }
  end

  defp session_id(%{output: output}) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn
      "@loopex " <> json ->
        case JSON.decode(json) do
          {:ok, %{"session_id" => id}} when is_binary(id) -> [id]
          _ -> []
        end

      _ ->
        []
    end)
    |> List.last()
    |> case do
      nil ->
        {:error, :session_unavailable}

      encoded ->
        with(
          :error <- Base.url_decode64(encoded, padding: false),
          do: {:error, :session_unavailable}
        )
    end
  end

  defp independent_oracle(staged, outcome, root) do
    environment = outcome.environment || staged.fixture.environment

    with {:ok, recipe} <-
           Policy.oracle_runner(
             staged.fixture.case_id,
             staged.fixture.workspace,
             staged.fixture.oracle,
             environment
           ),
         runner = Path.join(staged.trusted, "independent.sh"),
         :ok <- File.write(runner, recipe.bytes) do
      {output, status} =
        System.cmd("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin", "/bin/sh", runner],
          cd: staged.fixture.workspace,
          stderr_to_stdout: true
        )

      {status, retain_raw(root, "oracle.txt", "status=#{status}\n" <> output)}
    else
      _ -> {1, {:error, :oracle_unavailable}}
    end
  end

  defp inspect_changes(%{name: "external"} = staged, root) do
    workspace = staged.fixture.workspace

    case git(["-C", workspace, "status", "--porcelain", "--untracked-files=all"], root) do
      {status, 0} ->
        paths =
          for line <- String.split(status, "\n", trim: true), do: String.slice(line, 3..-1//1)

        allowed = staged.entry["allowed_changed_paths"]
        result = if paths -- allowed == [], do: :ok, else: {:error, :disallowed_change}
        {result, retain(root, "changes.json", %{"changed" => paths, "allowed" => allowed})}

      _ ->
        {{:error, :changes_unavailable}, {:error, :changes_unavailable}}
    end
  end

  defp inspect_changes(staged, root) do
    result = FixtureManifest.verify_workspace(staged.entry, staged.fixture.workspace)

    {result,
     retain(root, "changes.json", %{
       "verified" => result == :ok,
       "allowed" => staged.entry["allowed_changed_paths"] ++ staged.entry["allowed_created_paths"]
     })}
  end

  defp git(args, cd) do
    System.cmd("git", args, cd: cd, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}])
  rescue
    _ -> {"", 1}
  end

  defp retain(root, name, value) do
    {:ok, encoded} = LoopexProtocol.Frame.encode(value)
    retain_raw(root, name, IO.iodata_to_binary(encoded))
  end

  defp retain_raw(root, name, bytes) do
    path = Path.join([root, "records", name])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes, [:exclusive]) do
      {:ok, %{"reference" => path, "sha256" => Canonical.digest_bytes(bytes)}}
    end
  end
end
