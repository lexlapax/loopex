defmodule LoopexDaemon.Paths do
  @moduledoc false

  @terminating_nul_bytes 1
  @darwin_sun_path_structure_bytes 104
  @linux_sun_path_structure_bytes 108

  @typedoc false
  @type resolved :: %{
          state_root: Path.t(),
          daemon_directory: Path.t(),
          socket_path: Path.t(),
          socket_path_limit: pos_integer()
        }

  @doc false
  @spec state_root(binary()) :: {:ok, Path.t()} | {:error, atom()}
  def state_root(root) when is_binary(root) do
    cond do
      root == "" -> {:error, :state_root_required}
      not String.valid?(root) -> {:error, :state_root_unusable}
      true -> {:ok, Path.expand(root)}
    end
  end

  def state_root(_root), do: {:error, :state_root_required}

  @doc false
  @spec startup(binary(), binary() | nil) ::
          {:ok, resolved()}
          | {:error,
             :state_root_required
             | :state_root_unusable
             | :invalid_socket_path
             | :unsupported_platform}
          | {:error, {:socket_path_too_long, pos_integer()}}
  def startup(root, explicit_socket \\ nil) do
    with {:ok, expanded_root} <- state_root(root),
         {:ok, selected} <- socket_path(expanded_root, explicit_socket),
         {:ok, limit} <- socket_path_limit(),
         :ok <- within_socket_path_limit(selected, limit) do
      {:ok,
       %{
         state_root: expanded_root,
         daemon_directory: Path.join(expanded_root, "daemon"),
         socket_path: selected,
         socket_path_limit: limit
       }}
    end
  end

  @doc false
  @spec socket_path_limit() :: {:ok, pos_integer()} | {:error, :unsupported_platform}
  def socket_path_limit do
    case :os.type() do
      {:unix, :darwin} -> {:ok, @darwin_sun_path_structure_bytes - @terminating_nul_bytes}
      {:unix, :linux} -> {:ok, @linux_sun_path_structure_bytes - @terminating_nul_bytes}
      _other -> {:error, :unsupported_platform}
    end
  end

  defp socket_path(root, nil), do: {:ok, Path.join([root, "daemon", "daemon.sock"])}

  defp socket_path(root, explicit) when is_binary(explicit) do
    if explicit != "" and String.valid?(explicit) do
      daemon_directory = Path.join(root, "daemon")
      selected = Path.expand(explicit)

      if within_directory?(selected, daemon_directory),
        do: {:ok, selected},
        else: {:error, :invalid_socket_path}
    else
      {:error, :invalid_socket_path}
    end
  end

  defp socket_path(_root, _explicit), do: {:error, :invalid_socket_path}

  defp within_directory?(path, directory) do
    case Path.relative_to(path, directory) do
      "." -> false
      ".." -> false
      relative -> not String.starts_with?(relative, "../") and Path.type(relative) == :relative
    end
  end

  defp within_socket_path_limit(path, limit) do
    if byte_size(path) <= limit,
      do: :ok,
      else: {:error, {:socket_path_too_long, limit}}
  end
end
