defmodule LoopexComposition.WorkspaceIdentity do
  @moduledoc """
  ## Concept

  The reference host gives discovery and execution one opaque identity for the
  same physical workspace. Core compares this identity without interpreting paths.

  ## Technical depth

  Preserve the project-trust digest over canonical root, device and inode.
  Resolving an identity reads existing directories and never creates a root.
  """

  alias LoopexProtocol.Canonical
  @symlink_hops 32

  @doc false
  def reference(workspace) do
    with {:ok, root} <- resolve_path(workspace),
         {:ok, identity} <- directory_identity(root),
         {:ok, ^root} <- resolve_path(workspace),
         {:ok, ^identity} <- directory_identity(root) do
      {:ok, from_verified_root(root, identity)}
    else
      {:ok, _changed} -> {:error, :workspace_root_changed}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def from_verified_root(root, {major_device, inode}) do
    "workspace:" <>
      Canonical.digest(%{
        "canonical_root" => root,
        "major_device" => major_device,
        "inode" => inode
      })
  end

  @doc false
  def validate_manifest(options, workspace) do
    case Keyword.get(options, :resource_manifest) do
      nil ->
        :ok

      manifest ->
        with {:ok, reference} <- reference(workspace),
             {:ok, _, normalized} <- Loopex.ResourcePack.digest(manifest),
             true <- normalized["workspace_ref"] == reference do
          :ok
        else
          _ -> {:error, {:invalid_composition_option, :resource_manifest}}
        end
    end
  end

  @doc false
  def directory_identity(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {stat.major_device, stat.inode}}

      {:ok, %File.Stat{}} ->
        {:error, :workspace_root_not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Concept: resolve host paths without changing the emulator's working directory.
  #
  # Technical depth: `Path.expand/1` is textual and would normalise away a `..`
  # that a symlink makes mean something else, so each component is resolved
  # against the filesystem before the next is considered. Nothing here changes
  # the working directory, which is global to the emulator rather than local to
  # this process, so two commands resolving at once do not read each other's
  # answer. A component that does not exist resolves to itself, which is what
  # lets a workspace with no `AGENTS.md` be reported absent rather than refused.
  def resolve_path(path), do: walk(Path.split(Path.expand(path)), "/", 0)

  defp walk([], resolved, _hops), do: {:ok, resolved}

  defp walk(_remaining, _resolved, hops) when hops > @symlink_hops,
    do: {:error, :symlink_hops_exhausted}

  defp walk(["/" | rest], resolved, hops), do: walk(rest, resolved, hops)
  defp walk(["." | rest], resolved, hops), do: walk(rest, resolved, hops)
  defp walk([".." | rest], resolved, hops), do: walk(rest, Path.dirname(resolved), hops)

  defp walk([segment | rest], resolved, hops) do
    candidate = Path.join(resolved, segment)

    case File.read_link(candidate) do
      {:ok, target} ->
        absolute =
          case Path.type(target) do
            :absolute -> target
            _relative -> Path.join(resolved, target)
          end

        walk(Path.split(absolute) ++ rest, "/", hops + 1)

      {:error, _not_a_link} ->
        walk(rest, candidate, hops)
    end
  end
end
