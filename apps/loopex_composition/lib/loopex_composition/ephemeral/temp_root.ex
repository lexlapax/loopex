defmodule LoopexComposition.Ephemeral.TempRoot do
  @moduledoc false
  import Bitwise, only: [band: 2]

  def candidate do
    with {:ok, tmp} <- temporary_directory(),
         {:ok, nonce} <- entropy() do
      path = Path.join(tmp, "loopex-" <> Base.encode16(nonce, case: :lower))

      if path?(path),
        do: {:ok, %{path: path, nonce: nonce}},
        else: {:error, :temporary_root_unusable}
    end
  end

  def runtime_id(nonce) when is_binary(nonce) and byte_size(nonce) == 32 do
    "ephemeral-" <> binary_part(Base.encode16(:crypto.hash(:sha256, nonce), case: :lower), 0, 32)
  end

  def claim(%{path: path, nonce: nonce} = candidate) do
    if candidate?(candidate) do
      case invoke(:mkdir, [path], &File.mkdir/1) do
        :ok -> verify_claim(%{path: path, nonce: nonce})
        {:error, :eexist} -> {:error, :collision}
        _ -> {:error, :temporary_root_creation_failed}
      end
    else
      {:error, :temporary_root_creation_failed}
    end
  end

  def claim(_), do: {:error, :temporary_root_creation_failed}

  defp verify_claim(candidate) do
    with {:ok, uid} <- current_uid(),
         {:ok, stat} <- invoke(:lstat, [candidate.path], &File.lstat/1),
         true <- stat.type == :directory and stat.uid == uid do
      owned = Map.put(candidate, :identity, identity(stat))

      with :ok <- invoke(:chmod, [candidate.path, 0o700], &File.chmod/2),
           {:ok, fresh} <- invoke(:lstat, [candidate.path], &File.lstat/1),
           true <-
             fresh.type == :directory and identity(fresh) == owned.identity and
               band(fresh.mode, 0o7777) == 0o700,
           {:ok, []} <- invoke(:ls, [candidate.path], &File.ls/1) do
        {:ok, owned}
      else
        _ -> claim_unproved(candidate, owned.identity, :verification_failed)
      end
    else
      _ -> claim_unproved(candidate, nil, :identity_unproved)
    end
  end

  defp claim_unproved(candidate, identity, cause) do
    {:error,
     {:claim_unproved,
      %{
        candidate: candidate,
        identity: identity,
        ownership: if(identity, do: :owned, else: :unknown),
        cause: cause
      }}}
  end

  # Concept: removal needs retained ownership and a fresh matching directory.
  # Technical depth: the host filesystem is trusted between lstat and rm_rf.
  # These pathname operations do not provide atomic protection against a
  # concurrent same-user replacement. The session owner supplies the bounded
  # worker and proves its DOWN and a separate absence observation.
  def remove(%{path: path, identity: expected} = owned) when is_map(expected) do
    with true <- candidate?(owned) and identity?(expected),
         {:ok, uid} <- current_uid(),
         true <- expected.uid == uid,
         {:ok, stat} <- invoke(:lstat, [path], &File.lstat/1),
         true <- stat.type == :directory and identity(stat) == expected,
         {:ok, _} <- invoke(:rm_rf, [path], &File.rm_rf/1),
         {:error, :enoent} <- invoke(:lstat, [path], &File.lstat/1) do
      :ok
    else
      _ -> {:error, :root_removal_unproved}
    end
  end

  def remove(_), do: {:error, :root_removal_unproved}

  defp temporary_directory do
    try do
      tmp = invoke(:tmp, [], &System.tmp_dir!/0)
      if path?(tmp), do: {:ok, tmp}, else: {:error, :temporary_root_unusable}
    rescue
      _ -> {:error, :temporary_root_unusable}
    catch
      _, _ -> {:error, :temporary_root_unusable}
    end
  end

  defp entropy do
    try do
      nonce = invoke(:entropy, [32], &:crypto.strong_rand_bytes/1)

      if is_binary(nonce) and byte_size(nonce) == 32,
        do: {:ok, nonce},
        else: {:error, :temporary_root_creation_failed}
    rescue
      _ -> {:error, :temporary_root_creation_failed}
    catch
      _, _ -> {:error, :temporary_root_creation_failed}
    end
  end

  defp current_uid do
    try do
      case invoke(:uid, [], fn -> System.cmd("/usr/bin/id", ["-u"]) end) do
        {output, 0} when is_binary(output) ->
          if Regex.match?(~r/\A[0-9]+\n?\z/, output) do
            {:ok, String.to_integer(String.trim_trailing(output, "\n"))}
          else
            {:error, :uid_unavailable}
          end

        _ ->
          {:error, :uid_unavailable}
      end
    rescue
      _ -> {:error, :uid_unavailable}
    end
  end

  defp path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..65_536 and
        String.valid?(path) and not String.contains?(path, <<0>>)

  defp candidate?(%{path: path, nonce: nonce}),
    do:
      path?(path) and
        is_binary(nonce) and byte_size(nonce) == 32 and
        Path.basename(path) == "loopex-" <> Base.encode16(nonce, case: :lower)

  defp candidate?(_), do: false
  defp identity(stat), do: Map.take(stat, [:major_device, :minor_device, :inode, :uid])

  defp identity?(identity),
    do:
      Enum.all?(
        [:major_device, :minor_device, :inode, :uid],
        fn key -> is_integer(identity[key]) and identity[key] >= 0 end
      )

  defp invoke(operation, arguments, actual) do
    apply(dependency(operation, actual), arguments)
  rescue
    _ -> {:error, :operation_failed}
  catch
    _, _ -> {:error, :operation_failed}
  end

  if Mix.env() == :test do
    defp dependency(operation, actual) do
      case Process.get({__MODULE__, :dependencies}, %{}) do
        %{^operation => replacement} -> replacement
        _ -> actual
      end
    end
  else
    defp dependency(_, actual), do: actual
  end
end
