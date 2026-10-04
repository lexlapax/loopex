defmodule LoopexComposition.Ephemeral.Preflight do
  @moduledoc """
  ## Concept

  Validates the complete ephemeral session selection before granting a session
  owner permission to create a temporary root.

  ## Technical depth

  The order is option grammar, workspace, named skills, provider selection and
  explicit route/maintenance admission, captured instructions and whole current
  genesis, host-global guards, shared application bootstrap, guarded ReqLLM start,
  provider-registry identity and explicit address. Captured configuration and
  immutable tool selection supply creation and runtime registration together.
  No step reads a provider
  credential or starts a session. Every dependency refusal is reduced to its
  closed composition reason at this boundary.
  """

  alias Loopex.LLM.ReqLLM.InProcess.{Guards, Route}
  alias LoopexComposition.Ephemeral.{Bootstrap, Options}
  alias LoopexComposition.{ReqLLMStarter, ResourcePacks, WorkspaceIdentity}
  alias LoopexComposition.{ProviderBindings, SessionInstructions}
  alias Loopex.Runtime.{Instructions, SessionGenesis}
  alias LoopexProtocol.ToolDefinition

  @profiles %{
    coding: ~w(loopex.read loopex.write loopex.edit loopex.bash),
    read_only: ~w(loopex.read loopex.grep loopex.find loopex.ls),
    none: []
  }

  @doc false
  def prepare(options) do
    with {:ok, selected} <- Options.parse(options),
         {:ok, cwd} <- workspace(selected.cwd),
         {:ok, skills} <- skills(selected.skills, cwd),
         {:ok, model} <- composition(Guards.model(selected.model)),
         {:ok, bindings} <- bindings(selected.provider_bindings, model),
         {:ok, _reference} <- Loopex.LLM.ReqLLM.HostBindings.select(selected.model, bindings),
         {:ok, maintenance} <-
           LoopexComposition.ProviderBindings.resolve_maintenance_model(
             selected.maintenance_model,
             bindings
           ),
         {:ok, genesis} <- genesis(selected, cwd, bindings),
         :ok <- composition(Guards.pre_start()),
         :ok <- Bootstrap.start(),
         :ok <- req_llm(selected.req_llm),
         :ok <- composition(Guards.provider(model.provider)),
         {:ok, base_url} <- address(model.provider, selected.base_url) do
      configuration = genesis["initial_configuration"]

      {:ok,
       selected
       |> Map.put(:cwd, cwd)
       |> Map.put(:skills, skills)
       |> Map.put(:provider, model)
       |> Map.put(:maintenance_model, maintenance)
       |> Map.put(:provider_base_url, selected.base_url)
       |> Map.put(:base_url, base_url)
       |> Map.put(:genesis, genesis)
       |> Map.put(:model, configuration["model"])
       |> Map.put(:context_token_budget, configuration["context_token_budget"])}
    end
  end

  @doc false
  def genesis(selected, cwd, bindings) do
    ids = Map.fetch!(@profiles, selected.tools)

    definitions =
      Loopex.Executor.Local.CodingTools.definitions()
      |> Enum.filter(&(&1["tool_id"] in ids))
      |> then(fn definitions ->
        if Map.get(selected, :questions, false),
          do: definitions ++ [ToolDefinition.question_definition()],
          else: definitions
      end)

    profile =
      if selected.tools == :read_only, do: "read-only", else: Atom.to_string(selected.tools)

    with {:ok, instructions} <- instructions(selected, cwd, profile),
         declaration <-
           %{
             "model" => selected.model,
             "reasoning" => Map.get(selected, :reasoning, "default"),
             "configuration_version" => 1,
             "instructions" => instructions,
             "max_tokens" => selected.max_tokens
           }
           |> ceiling(selected, :context_token_budget)
           |> ceiling(selected, :system_class_tokens),
         {:ok, configuration} <-
           ProviderBindings.resolve_configuration(declaration, bindings, definitions) do
      names =
        Map.new(definitions, fn definition ->
          {id, version, digest} = ToolDefinition.generation(definition)

          {definition["name"],
           %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
        end)

      SessionGenesis.resolve(%{"surface" => "embedded"}, %{
        genesis_version: "session_genesis_v3",
        runtime_configuration: %{"cleanup_grace_ms" => Loopex.Executor.default_cleanup_grace_ms()},
        initial_configuration: configuration,
        tool_selection: %{"definitions" => definitions, "names" => names},
        policy_defer_mode: "admit"
      })
    end
  end

  defp instructions(selected, cwd, profile) do
    case Map.get(selected, :instructions) do
      nil ->
        SessionInstructions.capture(cwd, profile)

      captured ->
        with :ok <- Instructions.validate(captured), do: {:ok, captured}
    end
  end

  defp ceiling(declaration, selected, key) do
    case Map.get(selected, key) do
      nil -> declaration
      value -> Map.put(declaration, Atom.to_string(key), value)
    end
  end

  defp bindings(nil, model) do
    credential =
      if is_nil(model.credential_variable),
        do: %{"none" => true},
        else: %{"env" => model.credential_variable}

    {:ok, %{Atom.to_string(model.provider) => %{"credential" => credential}}}
  end

  defp bindings(selected, _model), do: {:ok, selected}

  defp workspace(nil) do
    case File.cwd() do
      {:ok, path} -> workspace(path)
      _ -> {:error, {:composition, :workspace_unusable}}
    end
  end

  defp workspace(path) do
    with {:ok, resolved} <- WorkspaceIdentity.resolve_path(path),
         {:ok, _identity} <- WorkspaceIdentity.directory_identity(resolved) do
      {:ok, resolved}
    else
      _ -> {:error, {:composition, :workspace_unusable}}
    end
  end

  defp skills(paths, cwd) do
    case ResourcePacks.read_directories(paths, workspace: cwd) do
      {:ok, %{manifest: _manifest, shadowed_skills: _shadows} = selection} ->
        {:ok, selection}

      {:error, reason} when reason in [:invalid_paths, :invalid_options] ->
        {:error, {:invalid_option, :skills}}

      {:error, reason}
      when reason in [
             :workspace_unusable,
             :skill_directory_unusable,
             :unclassified_skill_directory,
             :duplicate_skill,
             :skill_manifest_invalid
           ] ->
        {:error, {:composition, reason}}
    end
  end

  defp req_llm(declaration) do
    deadline = System.monotonic_time() + System.convert_time_unit(5_000, :millisecond, :native)

    case ReqLLMStarter.request(Process.whereis(ReqLLMStarter), declaration, deadline) do
      :ok -> :ok
      {:error, reason} -> {:error, {:composition, reason}}
    end
  end

  defp address(provider, selected) do
    composition(Route.base_url(provider, selected))
  rescue
    _ -> {:error, {:composition, :provider_base_url_unsupported}}
  catch
    _, _ -> {:error, {:composition, :provider_base_url_unsupported}}
  end

  defp composition(:ok), do: :ok
  defp composition({:ok, value}), do: {:ok, value}
  defp composition({:error, reason}) when is_atom(reason), do: {:error, {:composition, reason}}
end
