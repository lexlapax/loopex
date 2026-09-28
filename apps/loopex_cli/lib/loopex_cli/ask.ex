defmodule LoopexCli.Ask do
  @moduledoc """
  ## Concept

  Admits one standalone question before starting an application or session.
  A durable question then uses the existing one-shot durable workflow.

  ## Technical depth

  The command's common admission order is fixed: argv, workspace, prompt.
  The ephemeral execution path is joined here only when its correlated signal
  handler and public session API are available. No provisional result is printed
  by this module.
  """

  alias LoopexCli.{AskOptions, AskPrompt, AskResult, DurableAsk}
  alias LoopexComposition.WorkspaceIdentity

  @doc """
  ## Concept

  Validates command input without starting either runtime profile.

  ## Technical depth

  The optional dependency functions are a private fixture seam. Production
  reads cwd only when the caller omitted it; a failed path resolution or a
  non-directory has one fixed command diagnostic and creates no state root.
  """
  @spec prepare(term(), keyword()) :: {:ok, map()} | %{status: 1, stdout: <<>>, stderr: binary()}
  def prepare(argv, seams \\ []) do
    dependencies = Map.merge(defaults(), Map.new(seams))

    with {:ok, options} <- AskOptions.parse(argv),
         {:ok, cwd} <- workspace(options.cwd, dependencies),
         {:ok, prompt} <- AskPrompt.admit(options.words, dependencies.input) do
      {:ok, %{options: Map.delete(options, :words), cwd: cwd, prompt: prompt}}
    else
      {:error, reason} when is_atom(reason) -> AskResult.diagnostic(reason)
      _ -> AskResult.diagnostic(:command_failed)
    end
  rescue
    _ -> AskResult.diagnostic(:command_failed)
  catch
    _, _ -> AskResult.diagnostic(:command_failed)
  end

  @doc """
  ## Concept

  Runs a previously admitted durable question and returns only its final bytes.

  ## Technical depth

  Startup failure has the ask-specific fixed diagnostic. The durable workflow
  retains responsibility for placement, credential custody, runtime cleanup
  and rendering; this entry does not duplicate that protocol.
  """
  @spec execute_durable(map(), keyword()) :: map()
  def execute_durable(prepared, seams \\ [])

  def execute_durable(%{options: %{profile: :durable} = options, cwd: cwd, prompt: prompt}, seams) do
    dependencies = Map.merge(defaults(), Map.new(seams))

    case protected(fn -> dependencies.start_application.() end) do
      {:ok, {:ok, started}} when is_list(started) ->
        case protected(fn -> dependencies.durable_run.(options, cwd, prompt) end) do
          {:ok, %{status: status, stdout: stdout, stderr: stderr} = result}
          when is_integer(status) and is_binary(stdout) and is_binary(stderr) ->
            result

          _ ->
            AskResult.diagnostic(:command_failed)
        end

      _ ->
        AskResult.diagnostic(:application_start_failed)
    end
  end

  def execute_durable(_, _), do: AskResult.diagnostic(:command_failed)

  defp defaults do
    %{
      input: :stdio,
      cwd: &File.cwd/0,
      resolve_path: &WorkspaceIdentity.resolve_path/1,
      directory_identity: &WorkspaceIdentity.directory_identity/1,
      start_application: fn -> Application.ensure_all_started(:loopex_cli) end,
      durable_run: &DurableAsk.run/3
    }
  end

  defp workspace(nil, dependencies) do
    case protected(fn -> dependencies.cwd.() end) do
      {:ok, {:ok, path}} -> workspace(path, dependencies)
      _ -> {:error, :workspace_unusable}
    end
  end

  defp workspace(path, dependencies) when is_binary(path) do
    with {:ok, {:ok, resolved}} <- protected(fn -> dependencies.resolve_path.(path) end),
         {:ok, {:ok, _identity}} <-
           protected(fn -> dependencies.directory_identity.(resolved) end) do
      {:ok, resolved}
    else
      _ -> {:error, :workspace_unusable}
    end
  end

  defp workspace(_, _), do: {:error, :workspace_unusable}

  defp protected(function) do
    try do
      {:ok, function.()}
    rescue
      _ -> :failed
    catch
      _, _ -> :failed
    end
  end
end
