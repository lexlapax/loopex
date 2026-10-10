defmodule Mix.Tasks.Loopex.M7Evidence.Profiles do
  @moduledoc """
  ## Concept

  Measures the system-class cost of the reference profiles an M7 case
  actually stages: the instruction envelope with its environment and role
  facts, plus every selected tool definition, including the question and
  helper definitions. Each case's measurement is built through the same
  composition path and case configuration its attempt uses, so a profile key
  in the manifest names content a case really sends, not a description of it.

  ## Technical depth

  `measure/4` takes a case ID, an empty attempt root, the runner context
  (`manifest` is the decoded fixture catalog) and the operator's decoded
  configuration. Chat cases apply `CaseRunner.case_transform/3`, their
  scenario's flags and `ChatConfiguration.load/3`; a helper parent also binds
  its frozen roles and catalog through `ChatConfiguration.helper_parent/2`.
  Ask cases parse their own argv, the ephemeral case uses the demonstration
  host's options and the daemon case the reference durable defaults. Each
  measurement holds the exact rendered instruction text, workspace,
  environment facts, tool generations, the estimate under Core's formula
  (`SessionConfiguration`'s system cost) and a `preimage_digest`: the SHA-256
  of the canonical instruction version, base and appendix with the ordered
  tool generations. The digest omits the environment, whose workspace path,
  platform and catalog address are per attempt. Cases with no model call
  measure nothing.
  """

  alias Loopex.Runtime.Instructions
  alias LoopexCli.ChatConfiguration
  alias LoopexComposition.{DurableOptions, Ephemeral}
  alias LoopexProtocol.{Canonical, ToolDefinition}
  alias Mix.Tasks.Loopex.M7Evidence.{CaseRunner, EphemeralDemo, Scenarios}

  @helper_runtime "m7-profile-measurement"

  @doc false
  def measure(case_id, root, context, config) do
    workspace = Path.join(root, "workspace")
    execution = context.manifest["execution_manifest"]
    entry = execution["cases"][case_id]

    with :ok <- File.mkdir_p(workspace),
         :ok <- File.mkdir_p(Path.join(root, "trusted")),
         :ok <- File.mkdir_p(Path.join(root, "state")) do
      cond do
        entry["credential"] != true -> {:ok, []}
        entry["driver"] == "scenario-ask" -> ask(case_id, workspace, config)
        case_id == "m7.ephemeral-question" -> ephemeral(workspace, config)
        case_id == "m7.daemon-detach" -> daemon(workspace, config)
        true -> chat(case_id, root, workspace, context, config)
      end
    end
  end

  defp chat(case_id, root, workspace, context, config) do
    context = Map.put(context, :workspace, workspace)

    with {:ok, transform} <-
           CaseRunner.case_transform(case_id, Path.join(root, "trusted"), context),
         {:ok, extras} <- extras(case_id, context) do
      profile =
        config
        |> transform.()
        |> Map.put("paths", %{"workspace" => workspace, "state_root" => Path.join(root, "state")})

      extras
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {extra, n}, {:ok, acc} ->
        path = Path.join(root, "config-#{n}.json")

        with :ok <- File.write(path, :json.encode(profile)),
             {:ok, prepared} <-
               ChatConfiguration.load(["chat", "--config", path | extra], root, nil),
             {:ok, measured} <- prepared_measurements(prepared, workspace) do
          {:cont, {:ok, acc ++ measured}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  # Each distinct flag set the case's conversations start with.
  defp extras(case_id, context) do
    case Scenarios.get(case_id) do
      %{plan: plan} ->
        with {:ok, conversations} <- plan.(context) do
          {:ok, conversations |> Enum.map(&Map.get(&1, :extra, [])) |> Enum.uniq()}
        end

      nil ->
        {:ok, [[]]}
    end
  end

  defp prepared_measurements(%{helpers: true} = prepared, workspace) do
    with {:ok, parent} <- ChatConfiguration.helper_parent(prepared, @helper_runtime) do
      {:ok,
       [measurement("parent", parent.genesis, workspace)] ++
         Enum.map(Enum.sort(parent.roles), fn {name, genesis} ->
           measurement("role:" <> name, genesis, workspace)
         end)}
    end
  end

  defp prepared_measurements(prepared, workspace),
    do: {:ok, [measurement("session", prepared.genesis, workspace)]}

  defp ask(case_id, workspace, config) do
    argv = Scenarios.get(case_id).ask.(workspace)

    with {:ok, options} <- LoopexCli.AskOptions.parse(argv) do
      ephemeral_genesis(
        [policy: LoopexCli.Policy.AllowAll, cwd: workspace, tools: options.tools],
        config,
        workspace
      )
    end
  end

  defp ephemeral(workspace, config),
    do: ephemeral_genesis(EphemeralDemo.session_options(workspace), config, workspace)

  defp ephemeral_genesis(options, config, workspace) do
    with {:ok, selected} <-
           Ephemeral.Options.parse(options ++ [model: config["session"]["model"]]),
         {:ok, genesis} <- Ephemeral.Preflight.genesis(selected, workspace, config["providers"]) do
      {:ok, [measurement("session", genesis, workspace)]}
    end
  end

  defp daemon(workspace, config) do
    with {:ok, genesis} <-
           DurableOptions.capture_genesis(
             [
               workspace: workspace,
               model: config["session"]["model"],
               provider_bindings: config["providers"]
             ],
             %{}
           ) do
      {:ok, [measurement("session", genesis, workspace)]}
    end
  end

  # Concept: Core's system-class formula over the exact staged members.
  # Technical depth: the rendered instruction text as one system message plus
  # each selected definition's model-facing bytes, both through the accepted
  # estimator, exactly as session configuration validation measures them.
  defp measurement(scope, genesis, workspace) do
    instructions = genesis["initial_configuration"]["instructions"]
    definitions = genesis["tool_selection"]["definitions"]
    {:ok, rendered} = Instructions.render(instructions)

    system =
      Loopex.Bounds.estimate(Canonical.encode(%{"role" => "system", "content" => rendered}))

    tools =
      Enum.map(definitions, fn definition ->
        {id, version, digest} = ToolDefinition.generation(definition)
        bytes = Canonical.encode(ToolDefinition.model_facing(definition))

        %{
          "tool_id" => id,
          "tool_version" => version,
          "definition_digest" => digest,
          "estimate" => Loopex.Bounds.estimate(bytes)
        }
      end)

    preimage =
      Canonical.encode(%{
        "instructions" => Map.take(instructions, ~w(version base appendix)),
        "tools" => Enum.map(tools, &Map.delete(&1, "estimate"))
      })

    %{
      "scope" => scope,
      "workspace" => workspace,
      "instructions" => instructions,
      "rendered" => rendered,
      "tools" => tools,
      "estimate" => system + Enum.sum(Enum.map(tools, & &1["estimate"])),
      "preimage_digest" => Canonical.digest_bytes(preimage)
    }
  end
end
