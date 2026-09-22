defmodule Mix.Tasks.Loopex.SourceIdentity do
  @moduledoc """
  ## Concept

  Prints the source identity a build from this tree would carry, or refuses
  with the reason it cannot be proved.

  ## Technical depth

  Run in the reference adapter project. Prints one line,
  `commit <sha> source-digest <hex|none>`, from `Mix.LoopexSourceIdentity`;
  a refusal raises with its stable reason. The CLI's build alias calls it
  before and after building, because that alias runs before its own
  dependencies are compiled.
  """

  use Mix.Task

  @shortdoc "Prints the source identity of this tree"

  @impl Mix.Task
  def run([]) do
    root = Path.expand("../..", File.cwd!())

    case Mix.LoopexSourceIdentity.resolve(root) do
      {:ok, identity} ->
        Mix.shell().info(
          "commit #{identity.commit} source-digest #{identity.source_digest || "none"}"
        )

      {:error, reason} ->
        Mix.raise("source identity refused: #{reason}")
    end
  end

  def run(_args), do: Mix.raise("loopex.source_identity takes no arguments")
end
