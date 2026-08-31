defmodule Loopex.SessionDirectory do
  @moduledoc """
  ## Concept

  Lets an operator find and continue earlier work across process restarts. A
  fresh operating-system process resolves one state root from `LOOPEX_HOME`,
  re-presents the durable `runtime_id` placement identity a prior process left
  there, lists the sessions this host knows about, and resumes one of them only
  under the exact `runtime_id` that created it.

  This module implements ADR 0008's four placement consequences at the command
  surface rather than inside the Store: a session is permanently bound to its
  creating `runtime_id` and a mismatched resume is refused with an explicit
  reason; `runtime_id` is generated once and persisted so it survives restart
  instead of stranding every session a fresh random value would orphan;
  re-presenting a resume `command_id` returns its historical result instead of
  contesting ownership a second time, while a fresh `command_id` acquires a
  genuine replacement owner; and every fact this module relies on comes from the
  one resolved state root, never a VM-global default.

  ## Technical depth

  State lives as plain files under the resolved root: `runtime_id` holds this
  host's placement identity, and `sessions/<session_id>` holds one entry binding
  a known session to its creating `runtime_id` and to the resume `command_id`s
  already resolved for it. Neither file is Store durable truth -- the Store
  remains the sole authority over session history and ownership -- so losing
  this directory strands no session; it only costs the operator the list and the
  placement identity, which `record_session/3` and `runtime_id/1` can rebuild
  from what a caller still knows.

  Every read here uses `System.fetch_env/1`, never `Application.get_env` or a
  compile-time default, because per-runtime placement identity is exactly the
  state class ADR 0001 and `mix loopex.core_only` forbid core from hiding in
  VM-global application environment: two runtimes in one VM must not collide on
  a shared default, and a value baked in at compile time cannot be re-presented
  after restart.
  """

  alias Loopex.Runtime

  @max_identifier_bytes 256
  @max_runtime_id_file_bytes 1_024
  @max_session_entry_bytes 1_048_576
  @max_cached_commands 4_096
  @temporary_name_bytes 16

  # Technical depth: bounded so a pathologically contended entry fails with a
  # reason rather than spinning.
  @cache_attempts 5
  @runtime_id_filename "runtime_id"
  @sessions_dirname "sessions"
  @runtime_id_prefix "runtime_"
  @runtime_id_random_bytes 16

  @typedoc """
  ## Concept

  One session this state root knows about.

  ## Technical depth

  `runtime_id` is the durable placement identity recorded when the session was
  first tracked here, never the identity of whichever runtime happens to be
  asking. Command-result caching used for resume idempotency is intentionally
  omitted from this projection; it is bounded recovery bookkeeping, not
  something a listing caller should read as authority.
  """
  @type entry :: %{required(:session_id) => binary(), required(:runtime_id) => binary()}

  @typedoc """
  ## Concept

  Why a resume through the wrong runtime placement identity was refused.

  ## Technical depth

  Carries a human-readable sentence naming the exact `runtime_id` the session
  requires, so an operator reading only the error knows what to do next rather
  than having to consult the state root's files directly.
  """
  @type placement_mismatch :: {:runtime_placement_mismatch, String.t()}

  @doc """
  ## Concept

  Resolves this host's session-directory state root.

  ## Technical depth

  Reads only the `LOOPEX_HOME` process environment variable and expands it to
  an absolute path; application environment is never consulted; a missing or
  empty value is refused rather than defaulted, because a silently invented
  root would let two hosts collide on `/` or read each other's sessions.
  """
  @spec state_root() :: {:ok, Path.t()} | {:error, :loopex_home_required}
  def state_root do
    case System.fetch_env("LOOPEX_HOME") do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        {:ok, Path.expand(value)}

      _other ->
        {:error, :loopex_home_required}
    end
  end

  @doc """
  ## Concept

  This host's durable `runtime_id` placement identity for the given state root,
  generating and persisting one on first use.

  ## Technical depth

  The first caller against an empty root wins: the identity file is created
  with POSIX `O_EXCL` semantics, so a concurrent first caller either creates it
  or reads back exactly what the winner wrote, and no caller ever overwrites an
  existing value. Every later call, including one from a fresh operating-system
  process, re-presents that same persisted value -- which is what makes it
  placement identity rather than a per-invocation token.
  """
  @spec runtime_id(Path.t()) :: {:ok, binary()} | {:error, term()}
  def runtime_id(root) when is_binary(root) and byte_size(root) > 0 do
    runtime_id(root, [])
  end

  def runtime_id(_root), do: {:error, :invalid_state_root}

  @doc false
  @spec runtime_id(Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def runtime_id(root, options)
      when is_binary(root) and byte_size(root) > 0 and is_list(options) do
    path = runtime_id_path(root)
    before_publish = Keyword.get(options, :before_publish, fn -> :ok end)

    with :ok <- ensure_directory_durable(root) do
      case read_durable_runtime_id(path) do
        {:ok, runtime_id} ->
          {:ok, runtime_id}

        {:error, :enoent} ->
          generate_and_persist_runtime_id(path, before_publish)

        {:error, :corrupt_runtime_id} = error ->
          error

        {:error, reason} ->
          {:error, {:runtime_id_unreadable, reason}}
      end
    else
      {:error, reason} -> {:error, {:state_root_unavailable, reason}}
    end
  end

  def runtime_id(_root, _options), do: {:error, :invalid_state_root}

  @doc """
  ## Concept

  Records a session as known to this state root, bound to the `runtime_id`
  that created it.

  ## Technical depth

  Idempotent under exact re-presentation of the same `runtime_id`; a caller
  presenting a different `runtime_id` for an already-recorded session conflicts
  rather than silently rebinding placement, because that binding is exactly
  what ADR 0008 requires to stay permanent. This is directory bookkeeping only
  -- it does not itself create or observe the session in the Store.
  """
  @spec record_session(Path.t(), binary(), binary()) :: :ok | {:error, term()}
  def record_session(root, session_id, runtime_id)
      when is_binary(root) and is_binary(session_id) and byte_size(session_id) > 0 and
             is_binary(runtime_id) and byte_size(runtime_id) > 0 do
    case read_entry(root, session_id) do
      {:ok, %{runtime_id: ^runtime_id}} ->
        :ok

      {:ok, %{runtime_id: recorded}} ->
        {:error, {:session_already_bound, recorded}}

      {:error, :session_unknown} ->
        create_entry(root, session_id, runtime_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def record_session(_root, _session_id, _runtime_id), do: {:error, :invalid_session_record}

  # Technical depth: `:eexist` means another writer created the entry between
  # this one's read and its link. The winner's bytes are authoritative, so the
  # loser answers from them -- idempotent when both recorded the same
  # `runtime_id`, and the ordinary conflict when they did not.
  defp create_entry(root, session_id, runtime_id) do
    case write_entry(
           root,
           %{session_id: session_id, runtime_id: runtime_id, commands: %{}},
           :create
         ) do
      :ok ->
        :ok

      {:error, {:session_entry_persist_failed, :eexist}} ->
        case read_entry(root, session_id) do
          {:ok, %{runtime_id: ^runtime_id}} -> :ok
          {:ok, %{runtime_id: recorded}} -> {:error, {:session_already_bound, recorded}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  ## Concept

  Lists the sessions this state root knows about.

  ## Technical depth

  Reads every tracked entry from disk; a fresh operating-system process with no
  runtime started yet gets the same answer as the process that recorded them,
  because nothing here depends on in-memory state. An entry that fails to
  decode is skipped rather than failing the whole listing, since one corrupt
  row should not hide every session an operator is trying to find.
  """
  @spec list_sessions(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def list_sessions(root) when is_binary(root) do
    dir = Path.join(root, @sessions_dirname)

    case directory_identity(dir) do
      {:ok, expected_directory} ->
        with {:ok, filenames} <- File.ls(dir),
             {:ok, ^expected_directory} <- directory_identity(dir) do
          entries =
            filenames
            |> Enum.reject(&String.contains?(&1, ".tmp-"))
            |> Enum.flat_map(fn session_id ->
              case read_entry(root, session_id) do
                {:ok, entry} -> [%{session_id: session_id, runtime_id: entry.runtime_id}]
                {:error, _reason} -> []
              end
            end)
            |> Enum.sort_by(& &1.session_id)

          {:ok, entries}
        else
          {:ok, _different} -> {:error, :sessions_directory_replaced}
          {:error, reason} -> {:error, {:sessions_directory_unreadable, reason}}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, :not_directory} ->
        {:error, :sessions_directory_unreadable}

      {:error, reason} ->
        {:error, {:sessions_directory_unreadable, reason}}
    end
  end

  def list_sessions(_root), do: {:error, :invalid_state_root}

  @doc """
  ## Concept

  Resumes a known session, enforcing every ADR 0008 placement consequence: the
  supplied `runtime` must carry the exact `runtime_id` that created the
  session, and re-presenting a resume `command_id` already resolved here
  returns its historical result instead of contesting ownership again.

  ## Technical depth

  The placement check reads the runtime's own configured `runtime_id` through
  `Loopex.Runtime.configuration/1` and compares it to the entry recorded by
  `record_session/3`, refusing before any Store call when they differ -- a
  mismatched runtime never reaches `Loopex.Runtime.resume_session/3` at all.
  On a match, an already-resolved `command_id` returns its cached `{:ok,
  session_id}` result directly; only an unresolved `command_id` calls
  `Loopex.Runtime.resume_session/3`, and only a successful result is cached,
  so a transient failure leaves the `command_id` free to retry rather than
  wedging it on a non-committed reason.
  """
  @spec resume(Path.t(), Runtime.t(), binary(), binary()) ::
          {:ok, binary()} | {:error, :session_unknown | placement_mismatch() | term()}
  def resume(root, runtime, session_id, command_id)
      when is_binary(root) and is_binary(session_id) and is_binary(command_id) and
             byte_size(command_id) > 0 do
    with {:ok, entry} <- read_entry(root, session_id),
         {:ok, requesting_id} <- runtime_configured_id(runtime),
         :ok <- check_placement(entry, requesting_id) do
      case Map.fetch(entry.commands, command_id) do
        {:ok, cached_result} ->
          {:ok, cached_result}

        :error ->
          resume_and_cache(root, runtime, session_id, command_id)
      end
    end
  end

  def resume(_root, _runtime, _session_id, _command_id), do: {:error, :invalid_resume_request}

  defp resume_and_cache(root, runtime, session_id, command_id) do
    case Runtime.resume_session(runtime, session_id, command_id) do
      {:ok, resumed_id} = result ->
        case cache_command(root, session_id, command_id, resumed_id, @cache_attempts) do
          :ok -> result
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Concept: caching a resolved command must not drop one another caller
  # resolved at the same moment.
  #
  # Technical depth: the entry that reached this function was read before the
  # resume ran, so writing it back whole republishes a `commands` map that may
  # already be stale -- a concurrent resume's entry silently disappears, and the
  # `command_id` it belonged to contests ownership again on re-presentation
  # instead of returning its historical result. There is no compare-and-set on
  # a rename, so this re-reads immediately before writing, merges into whatever
  # is current, and then confirms its own entry survived; a lost race re-reads
  # the winner's state and merges again. Each attempt starts from a strictly
  # later state, so the retries converge rather than trading writes.
  defp cache_command(_root, _session_id, _command_id, _resumed_id, 0),
    do: {:error, :session_entry_contended}

  defp cache_command(root, session_id, command_id, resumed_id, attempts) do
    with {:ok, current} <- read_entry(root, session_id),
         merged = %{current | commands: Map.put(current.commands, command_id, resumed_id)},
         :ok <- write_entry(root, merged, :update),
         {:ok, settled} <- read_entry(root, session_id) do
      if Map.get(settled.commands, command_id) == resumed_id do
        :ok
      else
        cache_command(root, session_id, command_id, resumed_id, attempts - 1)
      end
    end
  end

  defp check_placement(%{runtime_id: creator_id}, requesting_id) when creator_id == requesting_id,
    do: :ok

  defp check_placement(%{runtime_id: creator_id}, requesting_id) do
    {:error,
     {:runtime_placement_mismatch,
      "this session is bound to runtime_id #{inspect(creator_id)}, not #{inspect(requesting_id)}; " <>
        "resume it from a runtime started with runtime_id: #{inspect(creator_id)} " <>
        "(re-presented from the resolved state root), or start a new session under this runtime instead"}}
  end

  defp runtime_configured_id(runtime) do
    case Runtime.configuration(runtime) do
      {:ok, %{runtime_id: id}} -> {:ok, id}
      {:error, reason} -> {:error, {:runtime_unavailable, reason}}
    end
  end

  defp runtime_id_path(root), do: Path.join(root, @runtime_id_filename)

  # Concept: only the first writer against an absent identity file may choose
  # the value every later process re-presents.
  #
  # Technical depth: the candidate is written and synced under a private name,
  # then hard-linked into the public name. Link creation is the one no-replace
  # publication step: a reader can see either no `runtime_id` or the complete,
  # synced inode, never the empty/partial interval between `O_EXCL` and write.
  # Two publishers may prepare candidates, but exactly one link succeeds and
  # every loser durably reads the winner. The hook is a test-only seam at that
  # exact election boundary.
  defp generate_and_persist_runtime_id(path, before_publish) do
    candidate = fresh_runtime_id()
    tmp = temporary_path(path)

    case File.open(tmp, [:write, :exclusive]) do
      {:ok, io} ->
        write_result =
          with :ok <- IO.binwrite(io, candidate),
               :ok <- :file.sync(io) do
            :ok
          end

        close_result = File.close(io)

        prepared =
          case {write_result, close_result} do
            {:ok, :ok} -> :ok
            {{:error, reason}, _close} -> {:error, {:runtime_id_write_failed, reason}}
            {:ok, {:error, reason}} -> {:error, {:runtime_id_close_failed, reason}}
          end

        result =
          with :ok <- prepared,
               :ok <- before_publish.() do
            publish_runtime_id(tmp, path)
          end

        case result do
          :ok ->
            {:ok, candidate}

          {:winner, runtime_id} ->
            {:ok, runtime_id}

          {:error, _reason} = error ->
            error
        end
        |> tap(fn _result -> File.rm(tmp) end)

      {:error, reason} ->
        {:error, {:runtime_id_persist_failed, reason}}
    end
  end

  defp publish_runtime_id(tmp, path) do
    case File.ln(tmp, path) do
      :ok ->
        case sync_runtime_id_directory(path) do
          :ok -> :ok
          {:error, _reason} = error -> error
        end

      {:error, :eexist} ->
        case read_durable_runtime_id(path) do
          {:ok, runtime_id} -> {:winner, runtime_id}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, {:runtime_id_persist_failed, reason}}
    end
  end

  defp read_durable_runtime_id(path) do
    with {:ok, contents} <- read_regular_file(path, @max_runtime_id_file_bytes, true),
         {:ok, runtime_id} <- decode_runtime_id(contents),
         :ok <- sync_runtime_id_directory(path) do
      {:ok, runtime_id}
    else
      {:error, :enoent} = error ->
        error

      {:error, :corrupt_runtime_id} = error ->
        error

      {:error, reason} when reason in [:not_regular, :replaced, :too_large] ->
        {:error, :corrupt_runtime_id}

      {:error, {:runtime_id_directory_sync_failed, _reason}} = error ->
        error

      {:error, {:runtime_id_directory_close_failed, _reason}} = error ->
        error

      {:error, {:runtime_id_directory_unavailable, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:runtime_id_unreadable, reason}}
    end
  end

  defp sync_runtime_id_directory(path) do
    directory = path |> Path.dirname() |> String.to_charlist()

    case :file.open(directory, [:raw, :read, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        close_result = :file.close(io)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:runtime_id_directory_sync_failed, reason}}
          {:ok, {:error, reason}} -> {:error, {:runtime_id_directory_close_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:runtime_id_directory_unavailable, reason}}
    end
  end

  defp fresh_runtime_id do
    @runtime_id_prefix <>
      (:crypto.strong_rand_bytes(@runtime_id_random_bytes) |> Base.encode16(case: :lower))
  end

  defp decode_runtime_id(contents) do
    trimmed = String.trim(contents)

    if byte_size(trimmed) > 0 and byte_size(trimmed) <= @max_identifier_bytes do
      {:ok, trimmed}
    else
      {:error, :corrupt_runtime_id}
    end
  end

  # Concept: a session identifier names one entry inside this directory and
  # never anything outside it.
  #
  # Technical depth: the identifier arrives from a caller -- on the command
  # surface, straight from an operator's argument -- and is used as a filename.
  # Joined unchecked, `../../outside-entry` reads and writes outside the
  # sessions directory entirely, so `loopex resume` became a file probe against
  # the rest of the state root. The rule is containment rather than format: one
  # path component, no separator, not a traversal element, and bounded. It
  # constrains what an identifier may be used for here without constraining how
  # a caller chooses to mint one.
  defp session_path(root, session_id) do
    if contained?(session_id) do
      {:ok, Path.join([root, @sessions_dirname, session_id])}
    else
      {:error, :invalid_session_id}
    end
  end

  defp contained?(session_id) do
    is_binary(session_id) and byte_size(session_id) > 0 and
      byte_size(session_id) <= @max_identifier_bytes and
      session_id not in [".", ".."] and
      not String.contains?(session_id, ["/", "\\", <<0>>])
  end

  defp read_entry(root, session_id) do
    with {:ok, path} <- session_path(root, session_id) do
      case read_regular_file(path, @max_session_entry_bytes) do
        {:ok, contents} ->
          decode_entry(contents, session_id)

        {:error, :enoent} ->
          {:error, :session_unknown}

        {:error, reason} when reason in [:not_regular, :not_directory, :replaced] ->
          {:error, :invalid_session_id}

        {:error, :too_large} ->
          {:error, :corrupt_session_entry}

        {:error, reason} ->
          {:error, {:session_entry_unreadable, reason}}
      end
    end
  end

  # Concept: an entry in this directory is a file this directory holds, not a
  # pointer to one somewhere else.
  #
  # Technical depth: `contained?/1` constrains the identifier and says nothing
  # about what the name already refers to, and `File.read/1` follows a symlink or
  # can block on a FIFO. Anyone able to write into the sessions directory could
  # therefore plant `sessions/<id>` pointing at a file of their own, or wedge a
  # listing on a non-regular device. A session entry is the ordinary file this
  # directory published; every other filesystem type is refused before it is
  # opened.
  #
  # `lstat` answers about the name rather than about what it points at, which is
  # the only way to tell the two apart. A symlink is refused as an identifier
  # rather than repaired, because replacing it would destroy whatever an operator
  # deliberately linked and admitting it would be the defect.
  # Concept: a directory a cold VM can decode without risking atom-table growth.
  #
  # Technical depth: `:safe` refuses to create atoms absent from the current
  # atom table. Every atom this module ever writes (`:session_id`,
  # `:runtime_id`, `:commands`) is a literal in this source file and therefore
  # already loaded, so decoding never needs a new one; a hand-edited or foreign
  # file that does would fail closed here instead of growing the table.
  defp decode_entry(contents, expected_session_id) do
    with false <- compressed_external_term?(contents),
         entry <- :erlang.binary_to_term(contents, [:safe]),
         %{session_id: ^expected_session_id, runtime_id: runtime_id, commands: commands} <- entry,
         true <- Enum.sort(Map.keys(entry)) == [:commands, :runtime_id, :session_id],
         true <- valid_persisted_identifier?(runtime_id),
         true <- valid_commands?(commands, expected_session_id) do
      {:ok, entry}
    else
      _other -> {:error, :corrupt_session_entry}
    end
  rescue
    ArgumentError -> {:error, :corrupt_session_entry}
  end

  defp compressed_external_term?(<<131, 80, _rest::binary>>), do: true
  defp compressed_external_term?(_contents), do: false

  defp valid_commands?(commands, session_id) when is_map(commands) do
    map_size(commands) <= @max_cached_commands and
      Enum.all?(commands, fn {command_id, result} ->
        valid_persisted_identifier?(command_id) and result == session_id
      end)
  end

  defp valid_commands?(_commands, _session_id), do: false

  defp valid_persisted_identifier?(value) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_identifier_bytes and
      String.valid?(value) and not String.contains?(value, <<0>>)
  end

  # Concept: recording a session for the first time and updating one already
  # recorded are different acts, and only the first may not overwrite.
  #
  # Technical depth: both used one unconditional rename, so `record_session/3`
  # was read-then-write with a window between. Two runtimes recording the same
  # identifier concurrently both read `:session_unknown`, both renamed, and the
  # later one silently rebound placement -- exactly the permanent binding
  # ADR 0008 exists to hold, lost to a race the conflict branch appeared to
  # cover. Creation now publishes with `:file.make_link/2`, which fails
  # `:eexist` against an existing name rather than replacing it, so a loser
  # learns it lost and settles against whatever is actually on disk.
  defp write_entry(root, entry, mode) do
    with {:ok, path} <- session_path(root, entry.session_id) do
      encoded = :erlang.term_to_binary(entry)

      if byte_size(encoded) <= @max_session_entry_bytes do
        write_entry_bytes(root, path, encoded, mode)
      else
        {:error, {:session_entry_persist_failed, :entry_too_large}}
      end
    end
  end

  defp write_entry_bytes(root, path, encoded, mode) do
    directory = Path.dirname(path)
    tmp = temporary_path(path)

    with :ok <- ensure_sessions_directory(root, directory),
         :ok <- write_synced_exclusive(tmp, encoded),
         :ok <- publish(tmp, path, mode),
         :ok <- sync_directory(directory) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:session_entry_persist_failed, reason}}
    end
  end

  defp publish(tmp, path, :create) do
    result = :file.make_link(tmp, path)
    _ = File.rm(tmp)
    result
  end

  defp publish(tmp, path, :update), do: File.rename(tmp, path)

  defp ensure_sessions_directory(root, directory) do
    with :ok <- ensure_directory(root) do
      case File.mkdir(directory) do
        :ok ->
          sync_directory(root)

        {:error, :eexist} ->
          with :ok <- ensure_directory(directory),
               :ok <- sync_directory(root) do
            :ok
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_directory_durable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        parent = Path.dirname(path)
        if parent == path, do: :ok, else: sync_directory(parent)

      {:ok, _other} ->
        {:error, :not_directory}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        if parent == path do
          {:error, :enoent}
        else
          with :ok <- ensure_directory_durable(parent),
               :ok <- create_and_sync_directory(path, parent) do
            :ok
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_and_sync_directory(path, parent) do
    case File.mkdir(path) do
      :ok ->
        sync_directory(parent)

      {:error, :eexist} ->
        with :ok <- ensure_directory(path),
             :ok <- sync_directory(parent) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :not_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_synced_exclusive(path, contents) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :write, :exclusive]) do
      {:ok, io} ->
        write_result =
          with :ok <- :file.write(io, contents),
               :ok <- :file.sync(io) do
            :ok
          end

        close_result = :file.close(io)

        case {write_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:raw, :read, :directory]) do
      {:ok, io} ->
        sync_result = :file.sync(io)
        close_result = :file.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix = :crypto.strong_rand_bytes(@temporary_name_bytes) |> Base.url_encode64(padding: false)
    path <> ".tmp-" <> suffix
  end

  # Concept: a durable directory entry is read from the ordinary file that the
  # directory still names, never through a link or from an unbounded object.
  #
  # Technical depth: lstat refuses a static symlink, FIFO, device, or directory
  # before open. The opened descriptor is checked against that exact inode
  # before any byte is read and the path is checked again afterwards, so a
  # replacement cannot substitute outside bytes. Reading stops at one byte past
  # the caller's limit and therefore decides oversize without loading the rest
  # of a hostile file.
  defp read_regular_file(path, limit), do: read_regular_file(path, limit, false)

  defp read_regular_file(path, limit, sync?) do
    directory = Path.dirname(path)

    with {:ok, expected_directory} <- directory_identity(directory),
         {:ok, expected} <- regular_file_identity(path, limit),
         {:ok, io} <- :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      try do
        with {:ok, ^expected} <- opened_file_identity(io, limit),
             {:ok, ^expected_directory} <- directory_identity(directory),
             {:ok, contents} <- read_bounded(io, limit + 1),
             true <- byte_size(contents) <= limit,
             :ok <- maybe_sync_file(io, sync?),
             {:ok, ^expected_directory} <- directory_identity(directory),
             {:ok, ^expected} <- regular_file_identity(path, limit) do
          {:ok, contents}
        else
          false -> {:error, :too_large}
          {:ok, _different} -> {:error, :replaced}
          {:error, _reason} = error -> error
        end
      after
        :file.close(io)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp maybe_sync_file(_io, false), do: :ok
  defp maybe_sync_file(io, true), do: :file.sync(io)

  defp regular_file_identity(path, limit) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size} = stat} when size <= limit ->
        {:ok, file_identity(stat)}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :too_large}

      {:ok, _non_regular} ->
        {:error, :not_regular}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp directory_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {stat.major_device, stat.inode}}

      {:ok, _not_directory} ->
        {:error, :not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp opened_file_identity(io, limit) do
    case :file.read_file_info(io) do
      {:ok, record} ->
        case File.Stat.from_record(record) do
          %File.Stat{type: :regular, size: size} = stat when size <= limit ->
            {:ok, file_identity(stat)}

          %File.Stat{type: :regular} ->
            {:error, :too_large}

          %File.Stat{} ->
            {:error, :not_regular}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_identity(stat), do: {stat.major_device, stat.inode, stat.size}

  defp read_bounded(io, remaining, chunks \\ [])

  defp read_bounded(_io, 0, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_bounded(io, remaining, chunks) do
    case :file.read(io, remaining) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 ->
        read_bounded(io, remaining - byte_size(bytes), [bytes | chunks])

      {:ok, ""} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
