defmodule Mix.Tasks.Loopex.M7Evidence.AttemptWriter do
  @moduledoc """
  ## Concept

  The one local writer of an M7 attempts index. It holds the index's exclusive
  lock, records every attempt durably before the runner may act on it, admits a
  lane only through the replayed history, and hands ownership to another host
  only through the retained relinquishment and acceptance procedure. Missing,
  corrupt or incomplete evidence refuses as unavailable; nothing here retries,
  truncates or starts a replacement campaign.

  ## Technical depth

  ADR 0065 fixes the lock: an exclusive `:gen_tcp` listener on 127.0.0.1 at the
  port held by the index's immutable lock record `<index>.lock`, whose exact
  bytes are `{"port":P,"version":1}` and LF with P in 20000..32767. The record
  is written once, by exclusive create, with the index. `eaddrinuse` is
  contention; any other listen error, or a missing or malformed lock record, is
  unavailable evidence. The writer never accepts a connection.

  This GenServer owns the listener and the raw index descriptor, and performs
  every read, append and `:file.sync/1`. Its death, or its VM's, releases the
  lock and stops IO together; it also stops when the process that opened it
  exits. Every append re-reads and replays the complete index through
  `AttemptEvents`, refuses a record that would add an unresolved case fact or
  contains a supplied secret value, and acknowledges only after the complete
  write and sync. A failed write or sync replies `:uncertain_attempt_append`
  and stops the writer, so the next open replays what actually reached the
  file and an incomplete tail refuses until it is resolved outside this writer.

  Case records carry the writer's current owner tuple. A fresh `started` or
  `not_dispatched` record needs an admitted lane and must name its next pinned
  case; a not-dispatched stop or a non-pass completion ends that admission.
  Admission also requires the writer to be the designated owner, no pending
  handoff, no unsuperseded relinquishment marker of this host, and complete
  bytes for every reused row and causal authorization reference: absolute
  references are read as files and `git:` references from the repository.

  Handoff: the source writes the exact quiescent index bytes as quiescence
  evidence, appends the relinquishment, then writes that exact relinquishment
  line as this host's marker in its marker directory and stops. The marker is
  the source-revocation evidence. The destination accepts only when the
  quiescence, marker and transferred index copy bytes match its own index, and
  a marker is superseded only by its host's later acceptance.
  """

  use GenServer

  alias Mix.Tasks.Loopex.M7Evidence.AttemptEvents
  alias Mix.Tasks.Loopex.M7Evidence.AttemptFrames

  @ports 20_000..32_767
  @lock ~r/\A\{"port":([0-9]{5}),"version":1\}\n\z/
  @tuple ~w(writer_id host_id ownership_epoch)

  @doc false
  def create(path, campaign, identity, opts \\ []),
    do: start({:create, path, campaign, identity, opts})

  @doc false
  def open(path, identity, opts \\ []), do: start({:open, path, nil, identity, opts})

  @doc false
  def read(writer), do: GenServer.call(writer, :read, :infinity)

  @doc false
  def append(writer, body), do: GenServer.call(writer, {:append, body}, :infinity)

  @doc false
  def admit(writer, concept, selection, mode),
    do: GenServer.call(writer, {:admit, concept, selection, mode}, :infinity)

  @doc false
  def relinquish(writer, destination_writer, destination_host, handoff_id, quiescence_path),
    do:
      GenServer.call(
        writer,
        {:relinquish, destination_writer, destination_host, handoff_id, quiescence_path},
        :infinity
      )

  @doc false
  def accept(writer, revocation_path, transfer_path),
    do: GenServer.call(writer, {:accept, revocation_path, transfer_path}, :infinity)

  @doc false
  def close(writer), do: GenServer.stop(writer)

  defp start(request) do
    case GenServer.start(__MODULE__, {request, self()}) do
      {:ok, writer} -> {:ok, writer}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init({{mode, path, campaign, identity, opts}, caller}) do
    Process.monitor(caller)

    with true <- absolute?(path) and identity?(identity),
         {:ok, state} <- acquire(mode, path, identity) do
      state = %{
        state
        | secrets: Enum.filter(Keyword.get(opts, :secrets, []), &(is_binary(&1) and &1 != "")),
          repository: Keyword.get(opts, :repository, File.cwd!())
      }

      case mode do
        :create -> initialize(state, campaign, identity, Keyword.get(opts, :succession))
        :open -> verify_open(state)
      end
    else
      false -> {:stop, :invalid_attempt_writer_request}
      {:error, reason} -> {:stop, reason}
    end
  end

  # Concept: creation fixes the lock before any index byte exists.
  # Technical depth: a free port is found by listening first, so the immutable
  # record never names a port this writer could not hold.
  defp acquire(:create, path, identity) do
    with false <- File.exists?(path) or File.exists?(path <> ".lock"),
         {:ok, listener, port} <- listen_free(Enum.shuffle(@ports) |> Enum.take(64)),
         :ok <- write_exclusive(path <> ".lock", ~s({"port":#{port},"version":1}\n)),
         {:ok, fd} <- :file.open(path, [:raw, :binary, :read, :append, :exclusive]) do
      {:ok, state(path, identity, listener, fd)}
    else
      true ->
        {:error, :attempt_evidence_exists}

      {:error, :eexist} ->
        {:error, :attempt_evidence_exists}

      {:error, reason} when reason in [:attempt_writer_contention, :attempt_lock_unavailable] ->
        {:error, reason}

      {:error, reason} when reason in [:attempt_evidence_exists, :attempt_evidence_unavailable] ->
        {:error, reason}

      _ ->
        {:error, :attempt_index_unavailable}
    end
  end

  defp acquire(:open, path, identity) do
    with {:ok, port} <- lock_port(path),
         {:ok, listener} <- listen(port),
         {:ok, fd} <- open_index(path) do
      {:ok, state(path, identity, listener, fd)}
    end
  end

  defp state(path, identity, listener, fd) do
    %{
      path: path,
      identity: identity,
      listener: listener,
      fd: fd,
      plan: nil,
      secrets: [],
      repository: nil
    }
  end

  defp listen_free([]), do: {:error, :attempt_writer_contention}

  defp listen_free([port | ports]) do
    case listen(port) do
      {:ok, listener} -> {:ok, listener, port}
      {:error, :attempt_writer_contention} -> listen_free(ports)
      error -> error
    end
  end

  defp listen(port) do
    case :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: false]) do
      {:ok, listener} -> {:ok, listener}
      {:error, :eaddrinuse} -> {:error, :attempt_writer_contention}
      {:error, _} -> {:error, :attempt_lock_unavailable}
    end
  end

  defp lock_port(path) do
    with {:ok, bytes} <- File.read(path <> ".lock"),
         [_, digits] <- Regex.run(@lock, bytes),
         port = String.to_integer(digits),
         true <- port in @ports do
      {:ok, port}
    else
      _ -> {:error, :attempt_lock_unavailable}
    end
  end

  defp open_index(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case :file.open(path, [:raw, :binary, :read, :append]) do
          {:ok, fd} -> {:ok, fd}
          _ -> {:error, :attempt_index_unavailable}
        end

      _ ->
        {:error, :attempt_index_unavailable}
    end
  end

  defp initialize(state, campaign, identity, succession) do
    bodies =
      [
        %{"kind" => "genesis", "version" => 1, "campaign_id" => campaign, "codec_version" => 1},
        %{
          "kind" => "writer_designated",
          "version" => 1,
          "writer_id" => identity["writer_id"],
          "host_id" => identity["host_id"],
          "ownership_epoch" => 1
        }
      ] ++ if(is_nil(succession), do: [], else: [succession])

    Enum.reduce_while(bodies, {:ok, state}, fn body, {:ok, state} ->
      case write_record(state, campaign, body) do
        {:ok, _record} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:stop, reason}}
      end
    end)
  end

  defp verify_open(state) do
    case replay(state) do
      {:ok, _bytes, _projection} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  @impl true
  def handle_call(:read, _from, state) do
    case read_all(state.fd) do
      {:ok, bytes} -> {:reply, {:ok, bytes}, state}
      error -> {:stop, :normal, error, state}
    end
  end

  def handle_call({:append, %{"kind" => "case"} = body}, _from, state) do
    with {:ok, bytes, projection} <- replay(state),
         :ok <- current_writer(state, bytes, projection),
         body = Map.merge(body, owner(projection)),
         {:ok, plan} <- plan_step(state.plan, body) do
      append_reply(state, bytes, projection, body, plan)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:append, _body}, _from, state),
    do: {:reply, {:error, :attempt_ownership_requires_handoff}, state}

  def handle_call({:admit, _, _, _}, _from, %{plan: %{active: active}} = state)
      when not is_nil(active),
      do: {:reply, {:error, :attempt_case_active}, state}

  def handle_call({:admit, concept, selection, mode}, _from, state) do
    with {:ok, bytes, projection} <- replay(state),
         :ok <- current_writer(state, bytes, projection) do
      campaign = projection.ownership.head["campaign_id"]

      case AttemptEvents.verify_lane_history(bytes, concept, campaign, selection, mode) do
        {:ok, plan} -> admit_plan(state, plan)
        other -> {:reply, other, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:relinquish, writer_id, host_id, handoff, quiescence}, _from, state) do
    with {:ok, bytes, projection} <- replay(state),
         :ok <- relinquish_ready(state, bytes, projection, handoff, quiescence) do
      case projection.ownership.pending do
        nil -> relinquish(state, bytes, projection, writer_id, host_id, handoff, quiescence)
        pending -> revoke(state, bytes, pending)
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:accept, revocation, transfer}, _from, state) do
    with {:ok, bytes, projection} <- replay(state),
         %{"body" => pending} <- projection.ownership.pending,
         true <-
           pending["destination_writer_id"] == state.identity["writer_id"] and
             pending["destination_host_id"] == state.identity["host_id"],
         {:ok, prefix, relinquished} <- split_last(bytes),
         {:ok, references} <-
           accept_references(pending, prefix, relinquished, bytes, revocation, transfer) do
      body =
        Map.merge(references, %{
          "kind" => "writer_accepted",
          "version" => 1,
          "writer_id" => state.identity["writer_id"],
          "host_id" => state.identity["host_id"],
          "ownership_epoch" => pending["ownership_epoch"] + 1,
          "source_writer_id" => pending["writer_id"],
          "source_host_id" => pending["host_id"],
          "source_ownership_epoch" => pending["ownership_epoch"],
          "handoff_id" => pending["handoff_id"],
          "relinquishment_head" => projection.ownership.pending["head"],
          "quiescence" => pending["quiescence"]
        })

      append_reply(state, bytes, projection, body, nil)
    else
      {:error, _} = error -> {:reply, error, state}
      {:unavailable, _} = unavailable -> {:reply, unavailable, state}
      _ -> {:reply, {:error, :attempt_handoff_unavailable}, state}
    end
  end

  # Concept: dispatch starts only after the admitted fact is durable.
  # Technical depth: reused passes and causal authorizations prove their
  # complete reference bytes first; the admitted pins then gate fresh starts.
  defp admit_plan(state, plan) do
    # The failed attempt's own evidence stays as recorded; an authorization
    # proves only its causal diagnosis, disposition and authorization bytes.
    records =
      Enum.flat_map(plan.reused, & &1.history.records) ++
        Enum.map(plan.authorizations, &put_in(&1, ["body", "evidence"], []))

    case AttemptEvents.record_evidence(records, load_references(state, records)) do
      :ok ->
        scope = Map.take(plan.selection, ~w(candidate_sha lane_id logical_matrix_id))
        pins = Enum.map(plan.remaining, & &1.pin)

        {:reply, {:ok, plan},
         %{
           state
           | plan: %{
               scope: scope,
               manifest: plan.selection["manifest_digest"],
               pins: pins,
               active: nil
             }
         }}

      {:unavailable, detail} ->
        {:reply, {:unavailable, Map.put(detail, :lane, plan)}, state}
    end
  end

  defp plan_step(plan, %{"state" => state} = body)
       when state in ["started", "not_dispatched"] do
    locator = locator(body)

    case plan do
      %{active: nil, pins: [pin | pins]} = plan ->
        expected = Map.merge(plan.scope, Map.take(pin, ~w(case_key subcase_key)))

        if locator == expected and body["manifest_digest"] == plan.manifest and
             body["specification_digest"] == pin["specification_digest"] do
          if state == "started",
            do: {:ok, %{plan | active: locator, pins: pins}},
            else: {:ok, nil}
        else
          {:error, :attempt_case_not_admitted}
        end

      _ ->
        {:error, :attempt_case_not_admitted}
    end
  end

  defp plan_step(plan, %{"state" => "completed"} = body) do
    active = locator(body)

    case plan do
      %{active: ^active} = plan ->
        if body["mechanical_result"] == "pass" and plan.pins != [],
          do: {:ok, %{plan | active: nil}},
          else: {:ok, nil}

      plan ->
        {:ok, plan}
    end
  end

  defp plan_step(plan, _body), do: {:ok, plan}

  defp relinquish_ready(state, bytes, projection, handoff, quiescence) do
    cond do
      not absolute?(quiescence) or not is_binary(handoff) ->
        {:error, :invalid_attempt_handoff}

      is_nil(projection.ownership.pending) ->
        with :ok <- current_writer(state, bytes, projection) do
          if not is_nil(state.plan) or
               Enum.any?(projection.histories, fn {_, history} -> history.state == "started" end),
             do: {:error, :attempt_case_active},
             else: :ok
        end

      projection.ownership.pending["body"]["handoff_id"] == handoff and
        projection.ownership.pending["body"]["writer_id"] == state.identity["writer_id"] and
          projection.ownership.pending["body"]["host_id"] == state.identity["host_id"] ->
        :ok

      true ->
        {:error, :attempt_handoff_pending}
    end
  end

  defp relinquish(state, bytes, projection, writer_id, host_id, handoff, quiescence) do
    with :ok <- write_exclusive(quiescence, bytes) do
      body =
        Map.merge(owner(projection), %{
          "kind" => "writer_relinquished",
          "version" => 1,
          "destination_writer_id" => writer_id,
          "destination_host_id" => host_id,
          "handoff_id" => handoff,
          "preceding_head" => projection.ownership.head,
          "quiescence" => %{"reference" => quiescence, "sha256" => sha256(bytes)}
        })

      case append_record(state, bytes, projection, body) do
        {:ok, record} ->
          {:ok, appended} = read_all(state.fd)
          {:ok, _, line} = split_last(appended)
          finish_revocation(state, record, line)

        {:error, _} = error ->
          {:reply, error, state}

        {:uncertain, reason} ->
          {:stop, :normal, {:error, reason}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  defp revoke(state, bytes, pending) do
    {:ok, _, line} = split_last(bytes)
    {:ok, record} = AttemptFrames.decode(binary_part(line, 0, byte_size(line) - 1))

    if record["sequence"] == pending["head"]["sequence"],
      do: finish_revocation(state, record, line),
      else: {:reply, {:error, :attempt_handoff_pending}, state}
  end

  defp finish_revocation(state, record, line) do
    marker = marker_path(state, record["campaign_id"], record["body"]["handoff_id"])

    result =
      case File.read(marker) do
        {:ok, ^line} -> :ok
        {:error, :enoent} -> write_exclusive(marker, line)
        _ -> {:error, :relinquishment_marker_unmatched}
      end

    case result do
      :ok -> {:stop, :normal, {:ok, %{record: record, marker: marker}}, state}
      error -> {:stop, :normal, error, state}
    end
  end

  defp accept_references(pending, prefix, relinquished, bytes, revocation, transfer) do
    references = [
      {"quiescence", pending["quiescence"]["reference"], prefix},
      {"source_revocation", revocation, relinquished},
      {"transfer", transfer, bytes}
    ]

    Enum.reduce_while(references, {:ok, %{}}, fn {member, path, expected}, {:ok, acc} ->
      case absolute?(path) && File.read(path) do
        {:ok, ^expected} ->
          {:cont,
           {:ok, Map.put(acc, member, %{"reference" => path, "sha256" => sha256(expected)})}}

        _ ->
          {:halt, {:unavailable, %{member: member, reason: :handoff_evidence_mismatch}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Map.delete(refs, "quiescence")}
      other -> other
    end
  end

  defp append_reply(state, bytes, projection, body, plan) do
    case append_record(state, bytes, projection, body) do
      {:ok, record} -> {:reply, {:ok, record}, %{state | plan: plan}}
      {:error, _} = error -> {:reply, error, state}
      {:uncertain, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  defp append_record(state, bytes, projection, body) do
    head = projection.ownership.head

    with {:ok, line, record} <-
           AttemptEvents.encode(head["campaign_id"], head["sequence"] + 1, head["digest"], body),
         :ok <- secret_free(state, line),
         {tag, extended} when tag in [:ok, :unresolved] <-
           AttemptEvents.verify_case_history(bytes <> line),
         true <- length(extended.unresolved) == length(projection.unresolved) do
      durable(state.fd, line, record)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_attempt_append}
    end
  end

  defp write_record(state, campaign, body) do
    {:ok, bytes} = read_all(state.fd)

    if bytes == "" do
      with {:ok, line, record} <- AttemptEvents.encode(campaign, 1, nil, body) do
        durable(state.fd, line, record) |> uncertain_error()
      end
    else
      with {:ok, bytes, projection} <- replay(state) do
        append_record(state, bytes, projection, body) |> uncertain_error()
      end
    end
  end

  defp uncertain_error({:uncertain, reason}), do: {:error, reason}
  defp uncertain_error(other), do: other

  # Concept: acknowledgement means the complete record reached stable storage.
  # Technical depth: any write or sync error leaves the append uncertain; the
  # caller stops this writer instead of guessing what the file retained.
  defp durable(fd, line, record) do
    with :ok <- :file.write(fd, line),
         :ok <- :file.sync(fd) do
      {:ok, record}
    else
      _ -> {:uncertain, :uncertain_attempt_append}
    end
  end

  defp replay(state) do
    with {:ok, bytes} <- read_all(state.fd) do
      case AttemptEvents.verify_case_history(bytes) do
        {tag, projection} when tag in [:ok, :unresolved] ->
          {:ok, bytes, projection}

        {:error, {:incomplete_attempt_append, head, _tail}} ->
          {:error, {:incomplete_attempt_append, head}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp read_all(fd) do
    with {:ok, size} <- :file.position(fd, :eof),
         {:ok, bytes} <- pread(fd, size),
         true <- byte_size(bytes) == size do
      {:ok, bytes}
    else
      _ -> {:error, :attempt_index_unavailable}
    end
  end

  defp pread(_fd, 0), do: {:ok, ""}
  defp pread(fd, size), do: :file.pread(fd, 0, size)

  defp current_writer(state, bytes, projection) do
    owner = projection.ownership.owner

    cond do
      not is_nil(projection.ownership.pending) -> {:error, :attempt_handoff_pending}
      is_nil(owner) -> {:error, :writer_designation_unavailable}
      owner["writer_id"] != state.identity["writer_id"] -> {:error, :not_current_attempt_writer}
      owner["host_id"] != state.identity["host_id"] -> {:error, :not_current_attempt_writer}
      true -> markers(state, bytes, projection)
    end
  end

  # Concept: a host that relinquished ownership stays fenced until it accepts
  # ownership back. Technical depth: each marker must be the exact record at
  # its sequence in this index; a stale or forked copy cannot clear it.
  defp markers(state, bytes, projection) do
    campaign = projection.ownership.head["campaign_id"]
    dir = state.identity["marker_dir"]

    records =
      for line <- String.split(bytes, "\n", trim: true),
          do: elem(AttemptFrames.decode(line), 1)

    with {:ok, names} <- File.ls(dir) do
      names
      |> Enum.filter(&String.ends_with?(&1, ".relinquished"))
      |> Enum.reduce_while(:ok, fn name, :ok ->
        case marker_status(Path.join(dir, name), campaign, state, records) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      _ -> {:error, :relinquishment_markers_unavailable}
    end
  end

  defp marker_status(path, campaign, state, records) do
    with {:ok, line} <- File.read(path),
         true <- String.ends_with?(line, "\n"),
         {:ok, %{"body" => %{"kind" => "writer_relinquished"} = body} = record} <-
           AttemptEvents.decode(binary_part(line, 0, byte_size(line) - 1)),
         true <- body["host_id"] == state.identity["host_id"] do
      cond do
        record["campaign_id"] != campaign ->
          :ok

        record not in records ->
          {:error, :relinquishment_marker_unmatched}

        Enum.any?(records, fn later ->
          later["sequence"] > record["sequence"] and
            later["body"]["kind"] == "writer_accepted" and
              later["body"]["host_id"] == state.identity["host_id"]
        end) ->
          :ok

        true ->
          {:error, :relinquishment_marker}
      end
    else
      _ -> {:error, :relinquishment_marker_unmatched}
    end
  end

  defp load_references(state, records) do
    records
    |> Enum.flat_map(&AttemptEvents.references(&1["body"]))
    |> Enum.map(fn {_, reference} -> reference["reference"] end)
    |> Enum.uniq()
    |> Enum.flat_map(fn reference ->
      case reference_bytes(state, reference) do
        {:ok, bytes} -> [{reference, bytes}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp reference_bytes(_state, "/" <> _ = path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> with({:error, _} <- File.read(path), do: :error)
      _ -> :error
    end
  end

  defp reference_bytes(state, "git:" <> rest) do
    [revision, path] = String.split(rest, ":", parts: 2)
    path = path |> String.split("#", parts: 2) |> hd()

    case System.cmd("git", ["-C", state.repository, "cat-file", "blob", "#{revision}:#{path}"],
           stderr_to_stdout: true
         ) do
      {bytes, 0} -> {:ok, bytes}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp secret_free(state, line) do
    if Enum.any?(state.secrets, &String.contains?(line, &1)),
      do: {:error, :attempt_record_contains_secret},
      else: :ok
  end

  defp write_exclusive(path, bytes) do
    with {:ok, fd} <- :file.open(path, [:raw, :binary, :write, :exclusive]),
         :ok <- :file.write(fd, bytes),
         :ok <- :file.sync(fd),
         :ok <- :file.close(fd) do
      :ok
    else
      {:error, :eexist} -> {:error, :attempt_evidence_exists}
      _ -> {:error, :attempt_evidence_unavailable}
    end
  end

  defp split_last(bytes) do
    case :binary.matches(bytes, "\n") do
      matches when length(matches) >= 2 ->
        {start, 1} = Enum.at(matches, -2)

        {:ok, binary_part(bytes, 0, start + 1),
         binary_part(bytes, start + 1, byte_size(bytes) - start - 1)}

      [_] ->
        {:ok, "", bytes}

      _ ->
        {:error, :attempt_index_unavailable}
    end
  end

  defp marker_path(state, campaign, handoff),
    do:
      Path.join(
        state.identity["marker_dir"],
        sha256(campaign <> <<0>> <> handoff) <> ".relinquished"
      )

  defp owner(projection), do: Map.take(projection.ownership.owner, @tuple)

  defp locator(body),
    do: Map.take(body, ~w(candidate_sha lane_id logical_matrix_id case_key subcase_key))

  defp identity?(identity) do
    is_map(identity) and is_binary(identity["writer_id"]) and is_binary(identity["host_id"]) and
      absolute?(identity["marker_dir"])
  end

  defp absolute?(path), do: is_binary(path) and Path.type(path) == :absolute
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
