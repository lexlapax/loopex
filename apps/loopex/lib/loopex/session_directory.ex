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
    path = runtime_id_path(root)

    with :ok <- File.mkdir_p(root) do
      case File.read(path) do
        {:ok, contents} -> decode_runtime_id(contents)
        {:error, :enoent} -> generate_and_persist_runtime_id(path)
        {:error, reason} -> {:error, {:runtime_id_unreadable, reason}}
      end
    else
      {:error, reason} -> {:error, {:state_root_unavailable, reason}}
    end
  end

  def runtime_id(_root), do: {:error, :invalid_state_root}

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

    case File.ls(dir) do
      {:ok, filenames} ->
        entries =
          filenames
          |> Enum.reject(&String.contains?(&1, ".tmp-"))
          |> Enum.flat_map(fn session_id ->
            case read_entry(root, session_id) do
              {:ok, entry} -> [%{session_id: entry.session_id, runtime_id: entry.runtime_id}]
              {:error, _reason} -> []
            end
          end)
          |> Enum.sort_by(& &1.session_id)

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, []}

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
  # Technical depth: `:exclusive` maps to POSIX `O_CREAT|O_EXCL`, so two
  # processes racing to bootstrap the same empty state root cannot both
  # "win" -- the loser's open fails with `:eexist` and it reads back the
  # winner's committed bytes instead of persisting its own candidate.
  defp generate_and_persist_runtime_id(path) do
    candidate = fresh_runtime_id()

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        write_result =
          with :ok <- IO.binwrite(io, candidate),
               :ok <- :file.sync(io) do
            :ok
          end

        close_result = File.close(io)

        result =
          case {write_result, close_result} do
            {:ok, :ok} -> sync_runtime_id_directory(path)
            {{:error, reason}, _close} -> {:error, {:runtime_id_write_failed, reason}}
            {:ok, {:error, reason}} -> {:error, {:runtime_id_close_failed, reason}}
          end

        case result do
          :ok ->
            {:ok, candidate}

          {:error, _reason} = error ->
            _ = File.rm(path)
            error
        end

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, contents} -> decode_runtime_id(contents)
          {:error, reason} -> {:error, {:runtime_id_unreadable, reason}}
        end

      {:error, reason} ->
        {:error, {:runtime_id_persist_failed, reason}}
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
    with {:ok, path} <- session_path(root, session_id),
         :ok <- own_entry(path) do
      case File.read(path) do
        {:ok, contents} -> decode_entry(contents)
        {:error, :enoent} -> {:error, :session_unknown}
        {:error, reason} -> {:error, {:session_entry_unreadable, reason}}
      end
    end
  end

  # Concept: an entry in this directory is a file this directory holds, not a
  # pointer to one somewhere else.
  #
  # Technical depth: `contained?/1` constrains the identifier and says nothing
  # about what the name already refers to, and `File.read/1` follows a symlink to
  # its target. Anyone able to write into the sessions directory could therefore
  # plant `sessions/<id>` pointing at a file of their own: `list_sessions/1`
  # reported it as a session of this state root with a `runtime_id` they chose,
  # and because the name was taken, `record_session/3` refused the real session
  # `:session_already_bound` against a binding this host never made. Neither the
  # listing nor the refusal was true.
  #
  # `lstat` answers about the name rather than about what it points at, which is
  # the only way to tell the two apart. A symlink is refused as an identifier
  # rather than repaired, because replacing it would destroy whatever an operator
  # deliberately linked and admitting it would be the defect.
  defp own_entry(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :invalid_session_id}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> {:error, :session_unknown}
      {:error, reason} -> {:error, {:session_entry_unreadable, reason}}
    end
  end

  # Concept: a directory a cold VM can decode without risking atom-table growth.
  #
  # Technical depth: `:safe` refuses to create atoms absent from the current
  # atom table. Every atom this module ever writes (`:session_id`,
  # `:runtime_id`, `:commands`) is a literal in this source file and therefore
  # already loaded, so decoding never needs a new one; a hand-edited or foreign
  # file that does would fail closed here instead of growing the table.
  defp decode_entry(contents) do
    entry = :erlang.binary_to_term(contents, [:safe])

    case entry do
      %{session_id: session_id, runtime_id: runtime_id, commands: commands}
      when is_binary(session_id) and is_binary(runtime_id) and is_map(commands) ->
        {:ok, entry}

      _other ->
        {:error, :corrupt_session_entry}
    end
  rescue
    ArgumentError -> {:error, :corrupt_session_entry}
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
      tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, :erlang.term_to_binary(entry)),
           :ok <- publish(tmp, path, mode) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, {:session_entry_persist_failed, reason}}
      end
    end
  end

  defp publish(tmp, path, :create) do
    result = :file.make_link(tmp, path)
    _ = File.rm(tmp)
    result
  end

  defp publish(tmp, path, :update), do: File.rename(tmp, path)
end
