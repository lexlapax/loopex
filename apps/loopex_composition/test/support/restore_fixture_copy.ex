defmodule LoopexComposition.RestoreFixtureCopy do
  @moduledoc """
  ## Concept

  Copy a fixture tree faithfully while creating new physical entries.

  ## Technical depth

  Recursive copying creates directory permissions from the process umask.
  Capture existing source modes before copying, then restore those modes for
  directories and regular files without following source symlinks. This keeps
  exact restore manifests independent of umask while preserving replacement
  inode identity and File.cp_r's result tuple.
  """

  @doc """
  ## Concept

  Copy an existing fixture and preserve its directory and regular-file modes.

  ## Technical depth

  Source inspection uses lstat and never descends through a symlink. Restore
  child permissions before their parents; a failed copy keeps its original
  refusal tuple, and permission restoration errors fail the fixture directly.
  """
  def copy(source, destination) do
    modes = capture_modes(source, ".")

    case File.cp_r(source, destination) do
      {:ok, _} = result ->
        for {relative, mode} <- Enum.reverse(modes) do
          File.chmod!(entry_path(destination, relative), mode)
        end

        result

      error ->
        error
    end
  end

  defp capture_modes(source, relative) do
    path = entry_path(source, relative)
    stat = File.lstat!(path)

    case stat.type do
      :directory ->
        [{relative, Bitwise.band(stat.mode, 0o7777)}] ++
          Enum.flat_map(Enum.sort(File.ls!(path)), fn name ->
            capture_modes(source, Path.join(relative, name))
          end)

      :regular ->
        [{relative, Bitwise.band(stat.mode, 0o7777)}]

      :symlink ->
        []
    end
  end

  defp entry_path(root, "."), do: root
  defp entry_path(root, relative), do: Path.join(root, relative)
end
