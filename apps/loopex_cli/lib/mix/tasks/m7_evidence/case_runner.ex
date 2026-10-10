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
  alias LoopexCli.Model.M7CancellationGate, as: CancellationGate
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexProtocol.Canonical

  alias Mix.Tasks.Loopex.M7Evidence.{
    AttemptWriter,
    Conversation,
    DaemonDetach,
    EphemeralDemo,
    RestoreCase,
    ExecutionManifest,
    FixtureManifest,
    Scenarios
  }

  @held ~w(m7.steer-barrier m7.interrupt m7.daemon-detach)
  @hold_limit_ms 90_000
  @readme "M7 held workspace.\n"

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
    check: :boolean,
    candidate: :string,
    pins: :string,
    answer: :string
  ]

  @doc """
  ## Concept

  Run the trusted wrapper for one lane and return its exit status.

  ## Technical depth

  The trusted wrapper's command line (`scripts/m7-fixture-chat.exs`):
  `--lane LANE --attempts-index FILE --writer ID --host ID --markers DIR
  --run-root DIR --operator NAME [--create] [--continue] [--matrix ID]
  [--terminal] [--external-repository DIR] [--pins FILE] [--candidate SHA]
  [--answer choice-1|choice-2]
  [--check] chat --config FILE`. It runs from the clean candidate checkout, or
  from its extraction with `--candidate`. `--matrix` joins, continues or skips
  the lane within that logical matrix by the index alone; `--pins` supplies
  optional operator overrides as JSON, such as `restore_source` and
  `cancel_cell`; providers A and B are pinned in the manifest. `--check` admits the lane and
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
         {:ok, candidate} <-
           candidate(root, Map.merge(Map.new(Keyword.take(opts, [:candidate])), overrides)),
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
            mode: mode(opts),
            matrix: opts[:matrix],
            dispatch: if(opts[:terminal], do: :terminal, else: :pipe),
            operator: opts[:operator],
            external_repository: opts[:external_repository],
            pins: read_pins(opts[:pins]),
            answers: Map.new(~w(m7.feature m7.question-restart), &{&1, opts[:answer]})
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

  # Concept: optional operator overrides arrive as one retained file, never
  # as credentials. Technical depth: an unreadable or malformed file leaves
  # them absent, so each case uses its committed default.
  defp read_pins(nil), do: nil

  defp read_pins(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = pins} <- LoopexCli.ConfigJson.decode(bytes) do
      pins
    else
      _ -> nil
    end
  end

  defp mode(opts) do
    cond do
      opts[:continue] -> :continue
      opts[:matrix] -> :auto
      true -> :new
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
         {:ok, plan} <- admit(writer, context, selection, Map.get(context, :mode, :new)) do
      context = Map.put(context, :credentials, credentials(context.config_argv, manifest))
      run_pins(writer, plan.remaining, selection, context, [])
    else
      {:skip, :lane_already_ended} -> {:ok, []}
      other -> other
    end
  end

  # Concept: each conversation starts as a fresh chat process would, with the
  # configuration's and the pinned providers' named credential variables
  # present.
  # Technical depth: composition consumes those variables when it loads a
  # route, so the first conversation in this one VM would leave the next
  # without them. The trusted runner captures them once, before any
  # conversation, holds them only in this process and restores them
  # immediately before each conversation; the maintainer accepted this
  # in-memory capture for M7. Values never enter a record.
  defp credentials(argv, manifest) do
    pinned = for {_id, %{"credential_variable" => name}} <- manifest["providers"] || %{}, do: name

    for name <- Enum.uniq(configured_names(argv) ++ pinned),
        value = System.get_env(name),
        is_binary(value),
        do: {name, value}
  end

  defp configured_names(["chat", "--config", path | _]) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"providers" => providers}} when is_map(providers) <-
           LoopexCli.ConfigJson.decode(bytes) do
      for {_provider, %{"credential" => %{"env" => name}}} <- providers, do: name
    else
      _ -> []
    end
  end

  defp configured_names(_argv), do: []

  defp restore_credentials(context),
    do:
      Enum.each(Map.get(context, :credentials, []), fn {name, value} ->
        System.put_env(name, value)
      end)

  # Concept: one invocation of a logical matrix decides each lane's mode from
  # the index itself: continue a suspended lane, join the matrix this
  # invocation began, or start fresh; an ended lane is skipped, never rerun.
  defp admit(writer, context, selection, :auto) do
    case AttemptWriter.admit(writer, context.concept, selection, :continue) do
      {:blocked, %{reason: :lane_already_ended}} ->
        {:skip, :lane_already_ended}

      {:unresolved, %{reason: :lane_history_unavailable}} when is_binary(context.matrix) ->
        case AttemptWriter.admit(writer, context.concept, selection, :join) do
          {:blocked, %{reason: :matrix_join_unavailable}} ->
            AttemptWriter.admit(writer, context.concept, selection, :new)

          other ->
            other
        end

      {:unresolved, %{reason: :lane_history_unavailable}} ->
        AttemptWriter.admit(writer, context.concept, selection, :new)

      other ->
        other
    end
  end

  defp admit(writer, context, selection, mode),
    do: AttemptWriter.admit(writer, context.concept, selection, mode)

  defp run_pins(_writer, [], _selection, _context, results), do: {:ok, Enum.reverse(results)}

  defp run_pins(writer, [%{pin: pin} | rest], selection, context, results) do
    result = run_case(writer, pin, selection, context)

    case result do
      {:ok, %{mechanical_result: "pass"}} ->
        run_pins(writer, rest, selection, context, [result | results])

      {:ok, %{mechanical_result: "evidence_incomplete_pre_dispatch", record: stop}} ->
        suspended = Enum.map(rest, &suspend(writer, &1.pin, selection, stop))
        {:stopped, Enum.reverse([result | results]) ++ suspended}

      {:ok, _stopped} ->
        {:stopped, Enum.reverse([result | results])}

      error ->
        {:error, Enum.reverse([error | results])}
    end
  end

  # Concept: a pre-dispatch stop suspends the rest of the lane unexecuted.
  # Technical depth: each later pin is recorded not dispatched with the
  # stopping record's own preflight evidence, so continuation can find it.
  defp suspend(writer, pin, selection, stop) do
    body =
      stop["body"]
      |> Map.drop(~w(writer_id host_id ownership_epoch))
      |> Map.merge(%{
        "case_key" => pin["case_key"],
        "specification_digest" => pin["specification_digest"]
      })
      |> Map.merge(Map.take(selection, ~w(candidate_sha lane_id logical_matrix_id)))

    with {:ok, record} <- AttemptWriter.append(writer, body) do
      {:ok, %{mechanical_result: "evidence_incomplete_pre_dispatch", record: record}}
    end
  end

  @doc false
  def run_case(writer, pin, selection, context) do
    case_id = pin["case_key"]
    # A test may fix the nonce so a fixed fixture reply can name the runner.
    nonce =
      Map.get_lazy(context, :attempt_nonce, fn ->
        Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      end)

    attempt = case_id <> "-" <> nonce
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
      staged =
        cond do
          case_id == "m7.restore" -> stage_restore(case_id, root)
          case_id in @held -> stage_held(case_id, root, context)
          Scenarios.get(case_id) -> stage_scenario(case_id, root, context)
          true -> stage(case_id, root, context)
        end

      case staged do
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
      "policy" => execution_policy(staged),
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

      {join, facts} = inspect_facts(staged, outcome, root)

      environment =
        case join do
          {:ok, %{} = environment} -> environment
          _ -> staged.fixture.environment
        end

      environment = materialize(staged, environment)
      {oracle_status, oracle} = independent_oracle(staged, environment, root)
      {changes, inventory} = inspect_changes(staged, root)
      checks = if staged.capture, do: Policy.check(staged.capture), else: :ok
      retained = [{:ok, record}, oracle, inventory, facts | transcripts]

      mechanical =
        cond do
          Enum.any?(retained, &(not match?({:ok, _}, &1))) ->
            "evidence_incomplete_post_dispatch"

          match?({:missing, _}, join) ->
            "required_action_absent"

          outcome.exit != 0 or oracle_status != 0 or changes != :ok or checks != :ok or
              not match?({:ok, _}, join) ->
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

  # Concept: review enables exactly the two pinned helper roles; every other
  # fixture case runs the operator's configuration unchanged.
  # Technical depth: role instructions are written into the trusted tree, so
  # the workspace and its digests stay untouched; both roles use the session's
  # model and the catalog bounds the plan fixes.
  defp fixture_profile("m7.review", trusted, context) do
    roles = %{
      "investigate" =>
        "Investigate the repository read-only. Trace the requested call chain through the " <>
          "source and report each module and function it passes through.\n",
      "review" =>
        "Review the named code read-only. Identify the single defect on the chain and name " <>
          "its file, function and a short defect code.\n"
    }

    written =
      Enum.reduce_while(roles, :ok, fn {name, text}, :ok ->
        case File.write(Path.join(trusted, name <> ".md"), text, [:exclusive]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    with :ok <- written do
      {
        :ok,
        # Plan V8: the parent stays on provider A; both helpers run on the
        # pinned provider B at its generic default cell.
        fn profile ->
          model = Scenarios.provider_b(context)["model"]

          profile
          |> Scenarios.with_provider_b(context)
          |> Map.put(
            "roles",
            Map.new(roles, fn {name, _} ->
              {name,
               %{"model" => model, "instructions_file" => Path.join(trusted, name <> ".md")}}
            end)
          )
          |> Map.put("delegation", %{
            "enabled" => true,
            "roles" => ["investigate", "review"],
            "max_children" => 4,
            "token_budget" => 400_000,
            "child_bounds" => %{
              "max_turns" => 12,
              "deadline_ms" => 300_000,
              "token_budget" => 200_000
            }
          })
        end
      }
    end
  end

  defp fixture_profile(_case_id, _trusted, _context), do: {:ok, & &1}

  defp execution_policy(%{capture: nil}), do: "ordinary"
  defp execution_policy(staged), do: Policy.identity(staged.capture)

  # Concept: a fresh disposable workspace and a trusted tree per attempt.
  # Technical depth: the runner and oracle live outside the workspace and are
  # pinned with the shell, env, interpreter and catalog before preparation.
  defp stage(case_id, root, context) do
    # The question-restart and ephemeral cases reuse the feature fixture.
    name =
      if case_id in ["m7.question-restart", "m7.ephemeral-question"],
        do: "feature",
        else: String.replace_prefix(case_id, "m7.", "")

    policy_case = "m7." <> name
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
         {:ok, recipe} <- Policy.oracle_runner(policy_case, workspace, oracle, environment),
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
           case_id: policy_case,
           catalog_root: context.catalog_root,
           workspace: workspace,
           runner: runner,
           oracle: oracle,
           environment: environment,
           pins: pins
         },
         {:ok, conversations} <- plan(case_id, entry, context),
         {:ok, transform} <- fixture_profile(case_id, trusted, context),
         {:ok, config_argv} <- attempt_config(context.config_argv, workspace, root, transform),
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
         config_argv: config_argv,
         conversations: conversations,
         scenario: nil,
         case_id: case_id
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :fixture_preparation_unavailable}
    end
  end

  # Concept: a non-coding case runs under the operator's own policy.
  # Technical depth: the scenario seeds a fresh workspace and changes only the
  # configuration member it exercises; no fixture policy is injected.
  defp stage_scenario(case_id, root, context) do
    scenario = Scenarios.get(case_id)
    workspace = Path.join(root, "workspace")

    # A profile change may read the case's pins, such as a second provider.
    transform =
      if is_function(scenario.profile, 2),
        do: &scenario.profile.(&1, context),
        else: scenario.profile

    with :ok <- File.mkdir(workspace),
         :ok <- write_seed(workspace, scenario.seed),
         {:ok, conversations} <- scenario.plan.(Map.put(context, :workspace, workspace)),
         {:ok, config_argv} <-
           attempt_config(context.config_argv, workspace, root, transform) do
      {:ok,
       %{
         name: case_id,
         entry: nil,
         scenario: scenario,
         capture: nil,
         trusted: nil,
         config_argv: config_argv,
         conversations: conversations,
         fixture: %{case_id: case_id, workspace: workspace, pins: %{}, environment: %{}}
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :scenario_preparation_unavailable}
    end
  end

  # Concept: the attended restore works only on retained state, never a
  # conversation; its attempt root holds the fresh source and destination.
  defp stage_restore(case_id, root) do
    {:ok,
     %{
       name: case_id,
       case_id: case_id,
       entry: nil,
       scenario: nil,
       capture: nil,
       trusted: nil,
       config_argv: nil,
       conversations: [%{restore: true}],
       fixture: %{case_id: case_id, workspace: root, pins: %{}, environment: %{}}
     }}
  end

  # The rollback lane's restore test leaves its retained execution beside the
  # run root unless the pins name another directory.
  defp restore_source(context),
    do:
      get_in(context, [:pins, "restore_source"]) ||
        Path.join(Path.dirname(context.run_root), "m7-restore-source")

  # Concept: a held case's tool call waits on a harness FIFO outside the
  # writable workspace until the harness releases it.
  # Technical depth: the runner reads one line from the FIFO and prints it; the
  # fixture policy admits only `/bin/sh RUNNER` with both files pinned. The
  # harness, not the model or the operator's timing, decides when it returns.
  defp stage_held(case_id, root, context) do
    workspace = Path.join(root, "workspace")
    trusted = Path.join(root, "trusted")
    fifo = Path.join(trusted, "hold.fifo")
    runner = Path.join(trusted, "hold.sh")

    bytes =
      "#!/bin/sh\nset -eu\nIFS= read -r line < " <>
        shell_quote(fifo) <> "\nprintf '%s\\n' \"$line\"\n"

    with :ok <- File.mkdir(workspace),
         :ok <- File.write(Path.join(workspace, "README.md"), @readme),
         :ok <- File.mkdir(trusted),
         {_, 0} <- System.cmd("mkfifo", ["-m", "0600", fifo]),
         :ok <- File.write(runner, bytes),
         :ok <- File.chmod(runner, 0o644),
         {:ok, pins} <- pins(["/bin/sh", runner]),
         {:ok, capture} <-
           Policy.prepare(case_id, context.manifest_digest, workspace, ["/bin/sh", runner], pins),
         {:ok, config_argv} <-
           attempt_config(
             context.config_argv,
             workspace,
             root,
             &put_in(&1, ["session", "tools"], "coding")
           ) do
      {:ok,
       %{
         name: case_id,
         entry: nil,
         scenario: nil,
         capture: capture,
         trusted: trusted,
         config_argv: config_argv,
         conversations: [
           held_plan(case_id, fifo, runner, Map.get(context, :hold_limit_ms, @hold_limit_ms))
         ],
         fixture: %{case_id: case_id, workspace: workspace, pins: pins, environment: %{}},
         held: %{fifo: fifo, runner: runner},
         case_id: case_id
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :held_preparation_unavailable}
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @doc false
  def held_prompt(runner),
    do:
      "Call the bash tool exactly once with argv [\"/bin/sh\", \"#{runner}\"] and wait for it. " <>
        "It prints one line when the harness releases it. Then report that line."

  @doc false
  def held_steer, do: "After the runner returns, report its line in upper case."
  @doc false
  def held_follow_up, do: "Report the runner's line once more, in lower case."

  defp held_plan("m7.steer-barrier", fifo, runner, limit) do
    %{
      resume: false,
      steps: [
        {:line, held_prompt(runner)},
        {:hold, fifo, limit},
        {:line, "/status"},
        {:await, ~s("event":"status")},
        {:line, "/steer " <> held_steer()},
        {:await, ~s("event":"input")},
        {:line, "/follow-up " <> held_follow_up()},
        {:await, ~s("event":"input")},
        :observe,
        :release,
        {:line, "/wait"},
        {:line, "/wait"},
        {:line, "/status"},
        {:line, "/quit"}
      ]
    }
  end

  # The interrupt is the only release: the runner ends by cancellation.
  # The daemon case's conversation is the daemon driver's own protocol.
  defp held_plan("m7.daemon-detach", _fifo, _runner, _limit),
    do: %{resume: false, daemon: true, steps: []}

  defp held_plan("m7.interrupt", fifo, runner, limit) do
    %{
      resume: false,
      interrupt: true,
      steps: [
        {:line, held_prompt(runner)},
        {:hold, fifo, limit},
        {:line, "/status"},
        {:await, ~s("event":"status")},
        :observe,
        :interrupt,
        {:await, ~s("event":"closing")}
      ]
    }
  end

  defp write_seed(workspace, seed) do
    Enum.reduce_while(seed, :ok, fn {path, bytes}, :ok ->
      target = Path.join(workspace, path)

      with :ok <- File.mkdir_p(Path.dirname(target)), :ok <- File.write(target, bytes) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :scenario_seed_unavailable}}
      end
    end)
  end

  # Concept: the operator's explicit file, aimed at this attempt's fresh roots.
  # Technical depth: only `paths.workspace` and `paths.state_root` change;
  # ordinary validation of every other member still runs in preparation.
  defp attempt_config(argv, workspace, root, transform)

  defp attempt_config(["chat", "--config", template | rest], workspace, root, transform) do
    with {:ok, bytes} <- File.read(template),
         {:ok, profile} <- LoopexCli.ConfigJson.decode(bytes),
         true <- is_map(profile["paths"]) or {:error, :invalid_m7_config},
         profile = transform.(profile),
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

  defp attempt_config(_argv, _workspace, _root, _transform), do: {:error, :invalid_m7_config}

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

  # Concept: each fixture case is a fixed list of conversations; a later one
  # reopens the session the first one recorded.
  # Technical depth: steps are `Conversation` steps; terminal dispatch hands
  # every conversation to the operator's own input instead.
  @doc false
  def plan("m7.repair", entry, _context) do
    [first, second, third, reopened] = entry["prompts"]

    {:ok,
     [
       barriers([first, second, third]),
       %{resume: true, steps: barriers([reopened]).steps}
     ]}
  end

  def plan("m7.long", entry, _context) do
    [facts, explain, recall, outputs] = entry["prompts"]
    first = barriers([facts, explain, recall])
    compact = [{:line, "/compact"}, {:line, "/wait"}]
    {status, quit} = Enum.split(first.steps, -2)

    {:ok,
     [
       %{first | steps: status ++ compact ++ quit},
       %{resume: true, steps: barriers([outputs]).steps}
     ]}
  end

  def plan("m7.feature", entry, context) do
    case get_in(context, [:answers, "m7.feature"]) do
      choice when choice in ["choice-1", "choice-2"] ->
        [prompt] = entry["prompts"]

        {:ok,
         [
           %{
             resume: false,
             steps: [
               {:line, prompt},
               {:answer, choice},
               {:line, "/wait"},
               {:line, "/status"},
               {:line, "/quit"}
             ]
           }
         ]}

      _ ->
        if Map.get(context, :dispatch) == :terminal,
          do: {:ok, [%{resume: false, steps: []}]},
          else: {:error, :feature_answer_requires_operator}
    end
  end

  def plan("m7.question-restart", entry, context) do
    choice = get_in(context, [:answers, "m7.question-restart"])
    [prompt] = entry["prompts"]

    cond do
      choice in ["choice-1", "choice-2"] ->
        {:ok,
         [
           %{resume: false, steps: [{:line, prompt}, {:await, ~s("event":"question")}, :lose]},
           %{
             resume: true,
             reanswer: true,
             steps: [{:answer, choice}, {:line, "/wait"}, {:line, "/status"}, {:line, "/quit"}]
           }
         ]}

      Map.get(context, :dispatch) == :terminal ->
        {:ok,
         [
           %{resume: false, steps: [{:line, prompt}, {:await, ~s("event":"question")}, :lose]},
           %{
             resume: true,
             reanswer: true,
             steps: [
               {:answer, :operator},
               {:line, "/wait"},
               {:line, "/status"},
               {:line, "/quit"}
             ]
           }
         ]}

      true ->
        {:error, :question_restart_requires_operator}
    end
  end

  def plan("m7.external", entry, _context), do: {:ok, [barriers(entry["prompts"])]}
  # Review omits `/status`: chat refuses a status read when a helper's later
  # event lands during it (chat_status_unavailable), and the joins need none.
  def plan("m7.review", entry, _context) do
    [prompt] = entry["prompts"]
    {:ok, [%{resume: false, steps: [{:line, prompt}, {:line, "/wait"}, {:line, "/quit"}]}]}
  end

  # The ephemeral case: one public ephemeral call; the operator's line answers.
  def plan("m7.ephemeral-question", _entry, context) do
    case {get_in(context, [:answers, "m7.ephemeral-question"]), Map.get(context, :dispatch)} do
      {"choice-" <> n, _} when n in ["1", "2"] -> {:ok, [%{ephemeral: n <> "\n"}]}
      {nil, :terminal} -> {:ok, [%{ephemeral: :terminal}]}
      _ -> {:error, :ephemeral_answer_requires_operator}
    end
  end

  def plan(_case_id, _entry, _context), do: {:error, :case_driver_unavailable}

  defp barriers(prompts) do
    steps = Enum.flat_map(prompts, &[{:line, &1}, {:line, "/wait"}])
    %{resume: false, steps: steps ++ [{:line, "/status"}, {:line, "/quit"}]}
  end

  defp dispatch(%{scenario: %{ask: argv}} = staged, context) do
    result = LoopexCli.Ask.run(argv.(staged.fixture.workspace), Map.get(context, :ask_seams, []))

    %{
      exit: result.status,
      conversations: 1,
      session: nil,
      output: result.stdout,
      diagnostics: result.stderr,
      closing: result.stdout,
      transcripts: [{"stdout.txt", result.stdout}, {"stderr.txt", result.stderr}]
    }
  end

  # Concept: the ephemeral host runs under the operator's configured model and
  # provider routes and the case's pinned fixture policy; there is no durable
  # session, so its record decides.
  # Technical depth: the capture reaches the policy only as Core's contextual
  # reference, so the same exact invocations and paths as the chat cases apply.
  # Concept: the named operator confirms the restore summary they were shown.
  # Technical depth: piped runs take the operator's recorded `confirm` answer;
  # terminal runs print the summary and read the operator's own line.
  defp dispatch(%{conversations: [%{restore: true}]} = staged, context) do
    confirm = fn summary ->
      case Map.get(context, :dispatch) do
        :terminal ->
          device = Map.get(context, :operator_device, :stdio)
          IO.puts(device, summary)
          IO.write(device, "type confirm to record your verification> ")
          device |> IO.read(:line) |> to_string() |> String.trim() == "confirm"

        _ ->
          get_in(context, [:answers, "m7.restore"]) == "confirm"
      end
    end

    result = RestoreCase.run(restore_source(context), staged.fixture.workspace, confirm)

    %{
      exit: if(Enum.all?(Map.values(result.checks)), do: 0, else: 1),
      conversations: 1,
      session: nil,
      output: JSON.encode!(result.checks),
      diagnostics: "",
      closing: result.summary,
      events: [],
      transcripts: result.records
    }
  end

  # Concept: V9.4 runs in an in-VM daemon host, not a chat conversation.
  # Technical depth: the attempt's configuration supplies the model and the
  # credential variable; the provider launch is the reference host's unless a
  # test supplies a local fixture's.
  defp dispatch(%{conversations: [%{daemon: true}]} = staged, context) do
    ["chat", "--config", path | _] = staged.config_argv
    {:ok, profile} = path |> File.read!() |> LoopexCli.ConfigJson.decode()
    restore_credentials(context)
    launch = Map.get_lazy(context, :daemon_launch, &LoopexCli.ProviderLaunch.options/0)
    DaemonDetach.run(staged, Map.put(context, :profile, profile), launch)
  end

  defp dispatch(%{conversations: [%{ephemeral: line}]} = staged, context) do
    ["chat", "--config", path | _] = staged.config_argv
    {:ok, profile} = path |> File.read!() |> LoopexCli.ConfigJson.decode()
    record = Path.join(Path.dirname(staged.fixture.workspace), "ephemeral.json")
    {:ok, output} = StringIO.open("")
    terminal? = line == :terminal
    input = if terminal?, do: :stdio, else: elem(StringIO.open(line), 1)

    status =
      EphemeralDemo.run(
        [
          "--workspace",
          staged.fixture.workspace,
          "--operator",
          to_string(Map.get(context, :operator)),
          "--record",
          record,
          "--model",
          profile["session"]["model"]
        ],
        input,
        if(terminal?, do: :stdio, else: output),
        [
          policy: %{module: Policy, context: staged.capture},
          provider_bindings: profile["providers"],
          max_tokens: profile["session"]["max_tokens"]
        ]
        |> Enum.reject(&is_nil(elem(&1, 1)))
        |> Keyword.merge(Map.get(context, :ephemeral_options, []))
      )

    {_, shown} = StringIO.contents(output)
    retained = if File.exists?(record), do: File.read!(record), else: ""

    %{
      exit: status,
      conversations: 1,
      session: nil,
      output: retained,
      diagnostics: "",
      closing: shown,
      transcripts: [{"transcript-1.txt", shown}, {"ephemeral.json", retained}]
    }
  end

  defp dispatch(staged, context) do
    case Map.get(context, :dispatch, :pipe) do
      fun when is_function(fun, 2) -> fun.(staged, context)
      mode -> converse(staged.conversations, staged, context, mode, nil, [], 1)
    end
  end

  defp converse([], _staged, _context, _mode, session, done, _n),
    do: outcome(Enum.reverse(done), session)

  defp converse([conversation | rest], staged, context, mode, session, done, n) do
    extra =
      Map.get(conversation, :extra, []) ++
        if(conversation.resume and session, do: ["--resume", session], else: [])

    cond do
      conversation.resume and is_nil(session) ->
        outcome(Enum.reverse(done), session)

      true ->
        known = if conversation[:reanswer], do: [], else: questions(done)
        # Harness-driven steps need the piped device even under --terminal;
        # the operator still answers through {:answer, :operator}.
        mode = if harness_driven?(conversation.steps), do: :pipe, else: mode
        result = chat(staged, context, conversation.steps, mode, extra, n, known)
        result = Map.put(result, :session, session_id(result.output))

        # A prescribed terminal cut ends chat with status 1; the joins decide.
        result =
          if conversation[:cut] == true and result.exit == 1,
            do: %{result | interrupted: true},
            else: result

        session = session || result.session

        if result.exit == 0 or (result.exit == :lost and :lose in conversation.steps) or
             result.interrupted,
           do: converse(rest, staged, context, mode, session, [result | done], n + 1),
           else: outcome(Enum.reverse([result | done]), session)
    end
  end

  defp outcome(results, session) do
    %{
      exit:
        if(results != [] and Enum.all?(results, &(&1.exit in [0, :lost] or &1.interrupted)),
          do: 0,
          else: 1
        ),
      events: Enum.flat_map(results, & &1.events),
      conversations: length(results),
      session: session,
      sessions: results |> Enum.map(& &1.session) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      output: Enum.map_join(results, & &1.output),
      diagnostics: Enum.map_join(results, & &1.diagnostics),
      closing: if(results == [], do: "", else: List.last(results).output),
      transcripts: Enum.flat_map(results, & &1.transcripts)
    }
  end

  defp questions(results) do
    for result <- results,
        "@loopex " <> json <- String.split(result.output, "\n"),
        {:ok, %{"event" => "question", "interaction_id" => id}} <- [JSON.decode(json)],
        do: id
  end

  defp chat(staged, context, steps, mode, extra, n, known) do
    {:ok, diagnostics} = StringIO.open("", encoding: :latin1)

    {:ok, device} =
      if mode == :terminal,
        do: {:ok, nil},
        else: Conversation.start(steps, step_deadline(context), known, self())

    observed = :observe in steps
    gate = if :await_gate in steps, do: start_gate(), else: nil

    # Concept: the conversation is chat's input device and its owned output
    # target (ADR 0068); the terminal case acquires the process's own stdio.
    {input, output, chat_mode} =
      if mode == :terminal,
        do: {:stdio, :stdio, :interactive},
        else: {device, {:owned, device}, :pipe}

    options =
      [
        cwd: context.cwd,
        home: Map.get(context, :home),
        input: input,
        output: output,
        diagnostic_device: diagnostics,
        mode: chat_mode,
        fixture_policy: staged.capture
      ] ++ Map.get(context, :chat_options, [])

    options = if gate, do: gated_model(options, gate), else: options
    options = if observed or gate, do: observer_runtime(options, self()), else: options
    restore_credentials(context)

    exit =
      host(
        fn -> Chat.run(staged.config_argv ++ extra, options) end,
        device,
        gate,
        Map.get(context, :operator_device, :stdio)
      )

    if gate, do: CancellationGate.stop(gate, System.monotonic_time(:millisecond) + 5_000)
    {_, stderr} = StringIO.contents(diagnostics)

    {stdout, events} =
      if device do
        transcript = Conversation.transcript(device)
        Conversation.stop(device)
        {transcript.output, transcript.events}
      else
        {"", [:operator_terminal]}
      end

    inputs = Enum.map_join(events, &(inspect(&1) <> "\n"))

    %{
      exit: exit,
      events: events,
      interrupted: :interrupt in events and exit != :lost,
      output: stdout,
      diagnostics: stderr,
      transcripts: [
        {"transcript-#{n}.txt", stdout},
        {"diagnostics-#{n}.txt", stderr},
        {"input-#{n}.txt", inputs}
      ]
    }
  end

  defp step_deadline(context), do: Map.get(context, :step_deadline_ms, 600_000)

  # Concept: the conversation host runs in its own process so a prescribed
  # loss can end it abruptly, as an operator's kill would.
  # Technical depth: the host is killed only on its device's request; its
  # linked runtime dies with it and the durable store keeps what committed.
  defp host(run, device, gate, operator) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:conversation_exit, self(), run.()}) end)
    Process.put({__MODULE__, :operator}, operator)
    await_host(pid, ref, device, nil, gate)
  end

  defp await_host(pid, ref, device, runtime, gate) do
    receive do
      # The operator answers the emitted question on their own terminal.
      {:conversation_choose, ^device, record} when device != nil ->
        send(device, {:operator_choice, operator_choice(record)})
        await_host(pid, ref, device, runtime, gate)

      {:conversation_exit, ^pid, exit} ->
        Process.demonitor(ref, [:flush])
        exit

      {:m7_observed_runtime, observed} ->
        if gate, do: bind_gate(gate, observed)
        await_host(pid, ref, device, observed, gate)

      # The gate holds the second staged request before transport.
      {:loopex_m7_gate, :held, ^gate, _callback, _digest, _token} when device != nil ->
        send(device, :gate_held)
        await_host(pid, ref, device, runtime, gate)

      {:loopex_m7_gate, :permitted, ^gate, _callback, _digest, _count} ->
        await_host(pid, ref, device, runtime, gate)

      {:conversation_observe, ^device, output} when device != nil ->
        send(device, {:observed, observe(runtime, output)})
        await_host(pid, ref, device, runtime, gate)

      # The terminal interrupt as the chat's signal holder receives it.
      {:conversation_interrupt, ^device} when device != nil ->
        :gen_event.notify(:erl_signal_server, :sigterm)
        await_host(pid, ref, device, runtime, gate)

      {:conversation_lose, ^device} when device != nil ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :lost
        end

      {:DOWN, ^ref, :process, ^pid, _} ->
        1
    end
  end

  defp harness_driven?(steps),
    do:
      Enum.any?(steps, fn step ->
        step in [:lose, :interrupt, :observe, :await_gate, :release] or
          match?({:hold, _, _}, step) or step == {:answer, :operator}
      end)

  # Concept: an attended answer comes from the operator, never the harness.
  # Technical depth: the question and its numbered choices are shown on the
  # operator's device; the typed label or number is passed back unchanged.
  defp operator_choice(record) do
    device = Process.get({__MODULE__, :operator}, :stdio)
    IO.puts(device, "question: " <> to_string(record["question"]))

    for {choice, index} <- Enum.with_index(record["choices"] || [], 1),
        do: IO.puts(device, "  #{index}. #{choice["label"]}")

    IO.write(device, "answer> ")
    device |> IO.read(:line) |> to_string() |> String.trim()
  end

  # Concept: V7.7's trusted pre-transport cancellation gate, the one model
  # override the plan admits besides the fixture policy.
  # Technical depth: this runner is the gate's host; composition wraps its
  # selected adapter with the gate, which delegates the exact call and holds
  # only the second distinct staged request. It binds to the runtime's control.
  defp start_gate do
    {:ok, gate} = CancellationGate.start_link(self())
    Process.unlink(gate)
    gate
  end

  defp gated_model(options, gate) do
    base = Keyword.get(options, :with_runtime, &LoopexComposition.with_runtime/2)

    wrap = fn adapter ->
      %{
        module: CancellationGate,
        model: adapter.model,
        options: CancellationGate.options(gate, adapter.module, adapter.options)
      }
    end

    Keyword.put(options, :with_runtime, fn composition, callback ->
      base.(Keyword.put(composition, :model_adapter, wrap), callback)
    end)
  end

  defp bind_gate(gate, runtime) do
    with {:ok, %{control: control}} <- Loopex.Runtime.children(runtime),
         do: CancellationGate.bind_control(gate, control)
  end

  # Concept: the independent observer is a read-only attachment to the same
  # runtime, not the conversation's own output.
  # Technical depth: the trusted harness wraps the effective `with_runtime` only
  # to learn the runtime reference; the composition, policy and model are
  # unchanged.
  defp observer_runtime(options, owner) do
    base = Keyword.get(options, :with_runtime, &LoopexComposition.with_runtime/2)

    Keyword.put(options, :with_runtime, fn composition, callback ->
      base.(composition, fn runtime ->
        send(owner, {:m7_observed_runtime, runtime})
        callback.(runtime)
      end)
    end)
  end

  # Concept: before release the observer joins the active run and its held
  # operation from committed public events, and the runtime's acceptance of
  # the operator's commands from the conversation's control records.
  # Technical depth: the public plane publishes a steer or follow-up only when
  # it resolves, so the committed admissions themselves are joined after the
  # run from the journal, ordered before the held operation's receipt.
  @doc false
  def observe(nil, _output), do: {:error, :runtime_unobserved}

  def observe(runtime, output) do
    records = controls(output)
    status = records |> Enum.filter(&(&1["event"] == "status")) |> List.last()

    with %{"session_id" => encoded, "run_id" => run_encoded} when is_binary(run_encoded) <-
           status || {:error, :status_unobserved},
         {:ok, session} <- decode_identity(encoded),
         {:ok, run} <- decode_identity(run_encoded),
         {:ok, attachment} <- Loopex.attach(runtime, session, after_event_sequence: 0),
         events = drain(attachment, [], 0),
         {:ok, operation} <- held_operation(events, run) do
      accepted =
        for %{"event" => "input", "code" => "accepted", "command_id" => id} <- records,
            {:ok, decoded} <- [decode_identity(id)],
            do: decoded

      {:ok,
       %{
         "session_id" => session,
         "run_id" => run,
         "operation_id" => operation,
         "event_sequence" => events |> Enum.map(& &1[:event_sequence]) |> Enum.max(fn -> 0 end),
         "accepted_commands" => accepted
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :observation_unavailable}
    end
  end

  defp held_operation(events, run) do
    started? = &(&1[:kind] == "run.started" and &1["run_id"] == run)
    finished? = &(&1[:kind] == "run.finished" and &1["run_id"] == run)

    tool =
      Enum.find(
        events,
        &(&1[:kind] == "tool.started" and &1["run_id"] == run)
      )

    cond do
      not Enum.any?(events, started?) -> {:error, :run_unobserved}
      Enum.any?(events, finished?) -> {:error, :run_finished_before_release}
      is_nil(tool) -> {:error, :held_operation_unobserved}
      true -> {:ok, tool["operation_id"]}
    end
  end

  # Replay from the start of the session, then a short quiet period ends it.
  defp drain(_attachment, events, 20), do: Enum.reverse(events)

  defp drain(attachment, events, quiet) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        drain(attachment, [event | events], 0)

      _empty ->
        Process.sleep(10)
        drain(attachment, events, quiet + 1)
    end
  end

  defp controls(output) do
    for "@loopex " <> json <- String.split(output, "\n"),
        {:ok, %{} = record} <- [JSON.decode(json)],
        do: record
  end

  defp decode_identity(encoded) when is_binary(encoded),
    do: Base.url_decode64(encoded, padding: false)

  defp decode_identity(_), do: :error

  defp session_id(output) do
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
        nil

      encoded ->
        with({:ok, id} <- Base.url_decode64(encoded, padding: false), do: id, else: (_ -> nil))
    end
  end

  # Concept: required runtime facts are read from the committed session, not
  # from the conversation's prose.
  # Technical depth: the composition lends the attempt's own Store after every
  # conversation has closed; rows are read in order and the store is stopped.
  @doc false
  def committed(state_root, session) when is_binary(session) do
    case LoopexComposition.Edges.with_store(state_root, &page(&1, session, 0, [])) do
      {:ok, rows} -> {:ok, rows}
      _ -> {:error, :committed_facts_unavailable}
    end
  rescue
    _ -> {:error, :committed_facts_unavailable}
  end

  def committed(_state_root, _session), do: {:error, :committed_facts_unavailable}

  defp page(store, session, position, rows) do
    case Loopex.Store.load_records(store, session, position, 500) do
      {:ok, []} ->
        {:ok, Enum.reverse(rows)}

      {:ok, page} ->
        next = List.last(page).journal_version
        page(store, session, next, Enum.reverse(page, rows))

      _ ->
        {:error, :committed_facts_unavailable}
    end
  end

  # Concept: each case's required model actions and runtime joins.
  # Technical depth: `{:ok, environment}` selects the independent oracle's
  # inputs; `{:missing, reason}` is a required action or join that never
  # committed; `{:failed, reason}` is a committed fact contradicting the case.
  @doc false
  def joins("m7.feature", rows, entry, _outcome) do
    [%{"arguments" => question}] = entry["required_model_actions"]
    asked = Enum.find(rows, &(kind(&1) == "model_question_requested_v1"))
    answer = Enum.find(rows, &(kind(&1) == "model_question_response_admitted_v2"))
    effect = Enum.find(rows, &(kind(&1) == "effect_intent_committed_v2"))

    cond do
      is_nil(asked) or is_nil(answer) ->
        {:missing, :committed_question_answer}

      asked.payload["interaction_request"]["prompt"] != question["question"] or
        Enum.map(asked.payload["interaction_request"]["choices"], & &1["label"]) !=
          question["choices"] or
          answer.payload["interaction_id"] != asked.payload["interaction_id"] ->
        {:failed, :question_changed}

      effect && effect.journal_version < answer.journal_version ->
        {:failed, :effect_before_answer}

      true ->
        case entry["objective_results"][answer.payload["answer"]["choice_id"]] do
          default when default in ["empty", "literal_null"] ->
            {:ok, %{"M7_NIL_DEFAULT" => default}}

          _ ->
            {:failed, :unknown_answer_choice}
        end
    end
  end

  # The restart case: the one question survives the prescribed loss with its
  # identity and is answered only after reopening.
  def joins("m7.question-restart", rows, entry, outcome) do
    requested = Enum.filter(rows, &(kind(&1) == "model_question_requested_v1"))

    cond do
      outcome.conversations < 2 -> {:missing, :restart}
      length(requested) != 1 -> {:failed, :question_identity_changed}
      true -> joins("m7.feature", rows, entry, outcome)
    end
  end

  def joins("m7.long", rows, entry, outcome) do
    [facts | _] = entry["prompts"]

    cond do
      not Enum.any?(rows, &(kind(&1) == "compaction_checkpoint_committed_v1")) ->
        {:missing, :automatic_checkpoint}

      not Enum.any?(rows, &(kind(&1) == "standalone_compaction_checkpoint_committed_v1")) ->
        {:missing, :explicit_checkpoint}

      not Enum.any?(rows, &(kind(&1) == "prompt_admitted_v3" and &1.payload["content"] == facts)) ->
        {:failed, :raw_fact_unavailable}

      outcome.conversations < 2 ->
        {:missing, :restart}

      true ->
        {:ok, nil}
    end
  end

  def joins("m7.repair", rows, entry, outcome) do
    reopened = List.last(entry["prompts"])

    if outcome.conversations == 2 and
         Enum.any?(
           rows,
           &(kind(&1) == "prompt_admitted_v3" and &1.payload["content"] == reopened)
         ),
       do: {:ok, nil},
       else: {:missing, :restart}
  end

  # Review: both role calls committed and completed, read-only, each helper on
  # another provider than the parent, and the parent's final committed reply
  # is the finding the oracle checks.
  def joins("m7.review", rows, entry, _outcome) do
    calls =
      for row <- rows,
          kind(row) == "effect_intent_committed_v2",
          row.payload["job"]["tool_id"] == "loopex.task",
          do:
            {row.payload["job"]["validated_arguments"]["role"],
             row.payload["grant"]["operation_id"]}

    completed =
      for row <- rows,
          kind(row) == "executor_receipt_committed_v2",
          row.payload["receipt"]["outcome"] == "completed",
          do: row.payload["receipt"]["operation_id"]

    # Each helper receipt reports child, parent and combined usage separately.
    usage =
      for row <- rows,
          kind(row) == "executor_receipt_committed_v2",
          row.payload["receipt"]["tool_id"] == "loopex.task",
          do: task_usage(row.payload["receipt"]["output"])

    parent =
      Enum.find_value(rows, &get_in(&1.payload, ["initial_configuration", "model"]))

    helpers =
      for row <- rows,
          kind(row) == "executor_receipt_committed_v2",
          row.payload["receipt"]["tool_id"] == "loopex.task",
          do: task_model(row.payload["receipt"]["output"])

    roles = for %{"role" => role} <- entry["required_model_actions"], do: role

    finding =
      rows
      |> Enum.filter(&(kind(&1) == "model_attempt_settled_v3"))
      |> List.last()
      |> case do
        nil -> nil
        row -> get_in(row.payload, ["result", "reply", "text"])
      end

    cond do
      Enum.any?(roles, fn role -> not Enum.any?(calls, &(elem(&1, 0) == role)) end) ->
        {:missing, :role_calls}

      Enum.any?(calls, &(elem(&1, 1) not in completed)) ->
        {:failed, :role_call_incomplete}

      not Enum.all?(usage, &(&1 == :ok)) ->
        {:failed, :helper_usage}

      is_nil(provider(parent)) or Enum.any?(helpers, &(provider(&1) in [nil, provider(parent)])) ->
        {:failed, :helper_provider}

      not is_binary(finding) ->
        {:missing, :finding}

      true ->
        {:ok, %{"M7_FINDING" => {:text, finding}}}
    end
  end

  def joins(_case_id, _rows, _entry, _outcome), do: {:ok, nil}

  defp task_usage(output) when is_binary(output) do
    with {:ok, %{"usage" => %{"child" => child, "parent" => parent} = usage}} <-
           JSON.decode(output),
         total when is_integer(total) and total > 0 <-
           (child["reported_input_tokens"] || 0) + (child["reported_output_tokens"] || 0),
         true <- usage["combined_tokens"] == parent["tokens"] + total do
      :ok
    else
      _ -> :invalid
    end
  end

  defp task_usage(_output), do: :invalid

  defp task_model(output) do
    case JSON.decode(output) do
      {:ok, %{"model" => model}} -> model
      _ -> nil
    end
  end

  defp provider(model) when is_binary(model), do: hd(String.split(model, ":"))
  defp provider(_model), do: nil

  # Concept: a held case is decided by committed facts ordered around the held
  # operation's receipt, joined to the observation taken before release.
  # Technical depth: the receipt commits only after the runner returns, so a
  # command admitted at a lower journal version was admitted while it was held.
  defp held_joins(staged, rows, outcome) do
    argv = %{"argv" => ["/bin/sh", staged.held.runner]}

    intent =
      Enum.find(
        rows,
        &(kind(&1) == "effect_intent_committed_v2" and
            &1.payload["job"]["validated_arguments"] == argv)
      )

    operation = intent && intent.payload["grant"]["operation_id"]

    receipt =
      Enum.find(
        rows,
        &(kind(&1) == "executor_receipt_committed_v2" and
            &1.payload["receipt"]["operation_id"] == operation)
      )

    observation =
      Enum.find_value(outcome.events, fn
        {:observed, {:ok, observation}} -> observation
        _ -> nil
      end)

    cond do
      is_nil(intent) ->
        {:missing, :held_call}

      :hold_expired in outcome.events ->
        {:failed, :hold_expired}

      is_nil(observation) ->
        {:missing, :observation_before_release}

      observation["operation_id"] != operation or
        observation["run_id"] != intent.payload["run_id"] or
          observation["session_id"] != outcome.session ->
        {:failed, :observation_mismatch}

      is_nil(receipt) ->
        {:missing, :held_receipt}

      true ->
        held_case(staged.case_id, rows, receipt, observation, outcome)
    end
  end

  defp held_case("m7.steer-barrier", rows, receipt, observation, _outcome) do
    run = observation["run_id"]
    held = &(&1.journal_version < receipt.journal_version)
    steer = accepted(rows, "steer", run)
    follow = accepted(rows, "follow_up", run)
    ids = Enum.map(Enum.reject([steer, follow], &is_nil/1), & &1.payload["command_id"])

    applied =
      steer &&
        Enum.any?(
          rows,
          &(kind(&1) == "model_request_committed_v2" and &1.payload["run_id"] == run and
              &1.payload["applied_steer"] == steer.payload["command_id"])
        )

    follow_run = follow && follow_up_run(rows, follow.payload["command_id"], run)

    cond do
      is_nil(steer) or is_nil(follow) -> {:missing, :steer_and_follow_up}
      not (held.(steer) and held.(follow)) -> {:failed, :admitted_after_release}
      ids -- observation["accepted_commands"] != [] -> {:failed, :commands_unobserved}
      not applied -> {:missing, :steer_applied}
      is_nil(follow_run) -> {:missing, :follow_up_run_with_prior_context}
      not completed?(rows, follow_run) -> {:missing, :follow_up_terminal}
      true -> {:ok, nil}
    end
  end

  # Detach is a connection fact: the run completes as if no client had left.
  defp held_case("m7.daemon-detach", rows, receipt, observation, outcome) do
    run = observation["run_id"]
    order = Enum.map(outcome.events, &if(is_tuple(&1), do: elem(&1, 0), else: &1))

    terminal =
      Enum.find(rows, &(kind(&1) == "run_terminal_committed" and &1.payload["run_id"] == run))

    cond do
      not ordered?(order, [:held, :driver_closed, :reattached, :observed, :released]) ->
        {:missing, :detach_reattach_before_release}

      # Shutdown's abort of an idle session is refused; only an accepted one
      # would have ended the held run.
      accepted(rows, "abort", run) ->
        {:failed, :aborted}

      receipt.payload["receipt"]["outcome"] != "completed" ->
        {:failed, :held_call_not_completed}

      is_nil(terminal) or terminal.payload["outcome"] != "completed" ->
        {:failed, :run_not_completed}

      true ->
        {:ok, nil}
    end
  end

  # The interrupt is the only release: the held call ends by cancellation.
  defp held_case("m7.interrupt", rows, receipt, observation, outcome) do
    terminal =
      Enum.find(
        rows,
        &(kind(&1) == "run_terminal_committed" and &1.payload["run_id"] == observation["run_id"])
      )

    closing =
      outcome.output |> controls() |> Enum.filter(&(&1["event"] == "closing")) |> List.last()

    cond do
      :released in outcome.events -> {:failed, :released_without_cancellation}
      receipt.payload["receipt"]["outcome"] == "completed" -> {:failed, :held_call_completed}
      receipt.payload["receipt"]["cleanup_confirmation"] != "confirmed" -> {:failed, :cleanup}
      is_nil(terminal) -> {:missing, :run_terminal}
      terminal.payload["outcome"] == "completed" -> {:failed, :run_not_cancelled}
      is_nil(closing) or closing["cleanup"] != "confirmed" -> {:failed, :closing_cleanup}
      true -> {:ok, nil}
    end
  end

  defp ordered?(events, expected),
    do: Enum.filter(events, &(&1 in expected)) |> Enum.dedup() == expected

  defp accepted(rows, type, run),
    do:
      Enum.find(
        rows,
        &(kind(&1) == "command_admitted" and &1.payload["command_type"] == type and
            &1.payload["admission"] == "accepted" and &1.payload["run_id"] == run)
      )

  # The follow-up's own run: a later request whose context carries the
  # follow-up command under a new run beside the held run's blocks.
  defp follow_up_run(rows, command, held_run) do
    Enum.find_value(rows, fn row ->
      blocks =
        if kind(row) == "model_request_committed_v2",
          do: get_in(row.payload, ["context_receipt", "blocks"]) || [],
          else: []

      refs = Enum.map(blocks, &(&1["source_reference"] || %{}))

      own =
        Enum.find_value(refs, fn ref ->
          ref["kind"] == "session_command" and ref["command_id"] == command and
            ref["run_id"] != held_run and ref["run_id"]
        end)

      if own && Enum.any?(refs, &(&1["run_id"] == held_run)), do: own
    end)
  end

  defp completed?(rows, run),
    do:
      Enum.any?(
        rows,
        &(kind(&1) == "run_terminal_committed" and &1.payload["run_id"] == run and
            &1.payload["outcome"] == "completed")
      )

  defp kind(row), do: row.payload.kind

  # Concept: the committed session decides the required joins.
  # Technical depth: the retained record names each fact kind's count and the
  # join result; it holds no model text beyond what the session committed.
  # A one-shot ephemeral ask commits no session; its result stream decides.
  defp inspect_facts(%{scenario: %{ask: _} = scenario} = staged, outcome, root) do
    join = scenario.joins.([], outcome, staged.fixture.workspace)

    {join,
     retain(root, "facts.json", %{"session" => nil, "kinds" => %{}, "join" => inspect(join)})}
  end

  defp inspect_facts(%{case_id: "m7.restore"}, outcome, root) do
    checks = JSON.decode!(outcome.output)

    join =
      cond do
        checks["retained_execution"] != true -> {:missing, :retained_execution}
        checks["operator_confirmed"] != true -> {:missing, :operator_confirmation}
        Enum.any?(checks, fn {_name, ok} -> ok != true end) -> {:failed, :restore_check}
        true -> {:ok, nil}
      end

    {join, retain(root, "facts.json", %{"checks" => checks, "join" => inspect(join)})}
  end

  defp inspect_facts(%{case_id: "m7.ephemeral-question"}, outcome, root) do
    join =
      case JSON.decode(outcome.output) do
        {:ok, %{"outcome" => "completed", "question" => %{"choice" => default}}}
        when default in ["empty", "literal_null"] ->
          {:ok, %{"M7_NIL_DEFAULT" => default}}

        {:ok, %{"question" => nil}} ->
          {:missing, :operator_answer}

        _ ->
          {:failed, :ephemeral_answer_not_applied}
      end

    {join, retain(root, "facts.json", %{"session" => nil, "join" => inspect(join)})}
  end

  defp inspect_facts(staged, outcome, root) do
    state = Path.join(Path.dirname(staged.fixture.workspace), "state")

    case committed(state, outcome.session) do
      {:ok, rows} ->
        join =
          cond do
            Map.has_key?(staged, :held) -> held_joins(staged, rows, outcome)
            staged.scenario -> staged.scenario.joins.(rows, outcome, staged.fixture.workspace)
            true -> joins(staged.case_id, rows, staged.entry, outcome)
          end

        kinds = rows |> Enum.map(&kind/1) |> Enum.frequencies()

        {join,
         retain(root, "facts.json", %{
           "session" => outcome.session,
           "kinds" => kinds,
           "join" => inspect(join)
         })}

      {:error, reason} ->
        {{:missing, reason}, {:error, reason}}
    end
  end

  # A committed finding becomes a trusted file the oracle reads by path.
  defp materialize(staged, %{"M7_FINDING" => {:text, text}} = environment) do
    path = Path.join(staged.trusted, "finding.tsv")

    case File.write(path, text, [:exclusive]) do
      :ok -> %{environment | "M7_FINDING" => path}
      _ -> Map.delete(environment, "M7_FINDING")
    end
  end

  defp materialize(_staged, environment), do: environment

  defp independent_oracle(%{held: _}, _environment, root),
    do: {0, retain_raw(root, "oracle.txt", "no fixture oracle: the committed joins decide\n")}

  defp independent_oracle(%{capture: nil}, _environment, root),
    do: {0, retain_raw(root, "oracle.txt", "no fixture oracle: the committed joins decide\n")}

  defp independent_oracle(staged, environment, root) do
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

  defp inspect_changes(%{case_id: "m7.restore"}, root),
    do:
      {:ok, retain(root, "changes.json", %{"workspace" => "the retained workspace is only read"})}

  defp inspect_changes(%{held: _} = staged, root) do
    workspace = staged.fixture.workspace

    files =
      for path <- Path.wildcard(Path.join(workspace, "**"), match_dot: true),
          File.regular?(path),
          do: Path.relative_to(path, workspace)

    unchanged =
      files == ["README.md"] and File.read(Path.join(workspace, "README.md")) == {:ok, @readme}

    result = if unchanged, do: :ok, else: {:error, :disallowed_change}
    {result, retain(root, "changes.json", %{"files" => files, "unchanged" => unchanged})}
  end

  defp inspect_changes(%{scenario: %{} = scenario} = staged, root) do
    workspace = staged.fixture.workspace

    changed =
      for path <- Path.wildcard(Path.join(workspace, "**"), match_dot: true),
          File.regular?(path),
          relative = Path.relative_to(path, workspace),
          File.read!(path) != Map.get(scenario.seed, relative),
          do: relative

    removed =
      for {path, _} <- scenario.seed, not File.exists?(Path.join(workspace, path)), do: path

    result =
      if (changed ++ removed) -- scenario.allowed == [],
        do: :ok,
        else: {:error, :disallowed_change}

    {result,
     retain(root, "changes.json", %{
       "changed" => changed,
       "removed" => removed,
       "allowed" => scenario.allowed
     })}
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
