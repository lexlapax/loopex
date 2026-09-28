defmodule LoopexComposition.Ephemeral.Preflight do
  @moduledoc """
  ## Concept

  Validates the complete ephemeral session selection before granting a session
  owner permission to create a temporary root.

  ## Technical depth

  The order is option grammar, workspace, named skills, provider selection,
  host-global guards, shared application bootstrap, guarded ReqLLM start,
  provider-registry identity and explicit address. No step reads a provider
  credential or starts a session. Every dependency refusal is reduced to its
  closed composition reason at this boundary.
  """

  alias Loopex.LLM.ReqLLM.InProcess.{Guards, Route}
  alias LoopexComposition.Ephemeral.{Bootstrap, Options}
  alias LoopexComposition.{ReqLLMStarter, ResourcePacks, WorkspaceIdentity}

  @doc false
  def prepare(options) do
    with {:ok, selected} <- Options.parse(options),
         {:ok, cwd} <- workspace(selected.cwd),
         {:ok, skills} <- skills(selected.skills, cwd),
         {:ok, model} <- composition(Guards.model(selected.model)),
         :ok <- composition(Guards.pre_start()),
         :ok <- Bootstrap.start(),
         :ok <- req_llm(selected.req_llm),
         :ok <- composition(Guards.provider(model.provider)),
         {:ok, base_url} <- composition(Route.base_url(model.provider, selected.base_url)) do
      {:ok,
       selected
       |> Map.put(:cwd, cwd)
       |> Map.put(:skills, skills)
       |> Map.put(:provider, model)
       |> Map.put(:base_url, base_url)}
    end
  end

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

  defp composition(:ok), do: :ok
  defp composition({:ok, value}), do: {:ok, value}
  defp composition({:error, reason}) when is_atom(reason), do: {:error, {:composition, reason}}
end
