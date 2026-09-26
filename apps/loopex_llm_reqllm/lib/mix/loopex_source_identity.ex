defmodule Mix.LoopexSourceIdentity do
  @moduledoc """
  ## Concept

  Says which source a build is made from, whether it is built from a Git
  checkout or from an archive of one, and refuses to name a source it cannot
  prove. The CLI and provider builds share this one answer.

  ## Technical depth

  With `.git` present the identity is the existing one: a clean working tree
  (`git status --porcelain=v1 --untracked-files=all` empty) and
  `git rev-parse HEAD`, with no source digest. Without it, the tracked
  `SOURCE_IDENTITY` file, filled by `git archive` through `export-subst`, must
  be exactly `commit <40 lowercase hex>\\ncommitter-date <%cI>\\n`; the source
  digest is the lowercase SHA-256 of the complete byte stream
  `scripts/source-archive-manifest.sh` writes for the extraction. Refusals
  are stable reasons, never a fallback to building anyway:
  `source_identity_missing`, `source_identity_invalid`,
  `source_checkout_dirty` and, from `verify_unchanged/2`,
  `source_changed_during_build`.
  """

  @typedoc false
  @type t :: %{commit: binary(), mode: :git | :archive, source_digest: binary() | nil}

  @doc false
  @spec resolve(Path.t()) :: {:ok, t()} | {:error, atom()}
  def resolve(root) do
    if File.exists?(Path.join(root, ".git")), do: from_git(root), else: from_archive(root)
  end

  @doc false
  @spec verify_unchanged(Path.t(), t()) :: :ok | {:error, :source_changed_during_build}
  def verify_unchanged(root, identity) do
    case resolve(root) do
      {:ok, ^identity} -> :ok
      _changed -> {:error, :source_changed_during_build}
    end
  end

  @doc false
  @spec parse(binary()) :: {:ok, binary()} | {:error, :source_identity_invalid}
  def parse(contents) when is_binary(contents) do
    with [_all, commit, date] <-
           Regex.run(
             ~r/\Acommit ([0-9a-f]{40})\ncommitter-date (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2})\n\z/,
             contents
           ),
         true <- valid_date?(date) do
      {:ok, commit}
    else
      _invalid -> {:error, :source_identity_invalid}
    end
  end

  defp from_git(root) do
    with {status, 0} <-
           System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"], cd: root),
         "" <- status,
         {commit, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: root) do
      {:ok, %{commit: String.trim(commit), mode: :git, source_digest: nil}}
    else
      _dirty -> {:error, :source_checkout_dirty}
    end
  end

  defp from_archive(root) do
    case File.read(Path.join(root, "SOURCE_IDENTITY")) do
      {:ok, contents} ->
        with {:ok, commit} <- parse(contents),
             {:ok, digest} <- source_digest(root) do
          {:ok, %{commit: commit, mode: :archive, source_digest: digest}}
        end

      {:error, _reason} ->
        {:error, :source_identity_missing}
    end
  end

  # Concept: the extraction is described by the one repository-owned producer.
  defp source_digest(root) do
    script = Path.join([root, "scripts", "source-archive-manifest.sh"])

    case System.cmd("bash", [script, root], stderr_to_stdout: false) do
      {manifest, 0} -> {:ok, :crypto.hash(:sha256, manifest) |> Base.encode16(case: :lower)}
      {_partial, _status} -> {:error, :source_identity_invalid}
    end
  end

  defp valid_date?(<<date::binary-size(10), "T", time::binary-size(8), _offset::binary>>) do
    match?({:ok, _date}, Date.from_iso8601(date)) and
      match?({:ok, _time}, Time.from_iso8601(time))
  end

  defp valid_date?(_other), do: false
end
