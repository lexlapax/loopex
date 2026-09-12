defmodule Loopex.LLM.ReqLLM.ProviderWorker do
  @moduledoc false

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.{ProviderBuildIdentity, ProviderCodec}
  alias Loopex.{Model, Runtime.ProviderAttempt}

  @forbidden_apps [:loopex, :loopex_cli, :loopex_composition, :loopex_llm_reqllm]

  @doc false
  def main([path, nonce, manifest_digest, deadline_bytes]) do
    with {deadline, ""} <- Integer.parse(deadline_bytes),
         true <- deadline > System.system_time(:millisecond),
         true <- deadline <= 18_446_744_073_709_551_615,
         :ok <- run(path, nonce, manifest_digest, deadline) do
      # The result closes only the data plane. The independent OS guard retains
      # process-group ownership until Core requests and confirms cleanup.
      receive do: (:provider_worker_never_reused -> System.halt(70))
    else
      _refused -> System.halt(70)
    end
  rescue
    _error -> System.halt(70)
  catch
    _class, _reason -> System.halt(70)
  end

  def main(_arguments), do: System.halt(70)

  defp run(path, nonce, manifest_digest, deadline) do
    with :ok <- protected_entry(),
         :ok <- manifest_matches(manifest_digest),
         {:ok, socket} <-
           :gen_tcp.connect(
             {:local, path},
             0,
             [:binary, active: false, packet: :raw],
             :infinity
           ) do
      try do
        with {:ok, :bootstrap, bootstrap} <- ProviderCodec.recv(socket, remaining(deadline)),
             true <- bootstrap == bootstrap(nonce, manifest_digest),
             {:ok, _started} <- Application.ensure_all_started(:req_llm),
             true <- no_core_applications?(),
             :ok <- protect_dependency_io(),
             :ok <- ProviderCodec.send(socket, :ready, bootstrap),
             {:ok, :credential, %{"nonce" => ^nonce, "credential" => credential}} <-
               ProviderCodec.recv(socket, remaining(deadline)),
             {:ok, :invocation, invocation} <- ProviderCodec.recv(socket, remaining(deadline)),
             true <- invocation["nonce"] == nonce do
          request =
            invocation["request"]
            |> Map.put(:canonical_request_bytes, invocation["canonical_request_bytes"])
            |> Map.put(:staged_request_digest, invocation["staged_request_digest"])

          if request.deadline == deadline,
            do: invoke(socket, nonce, request, credential, deadline),
            else: :error
        else
          _invalid -> :error
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _unavailable -> :error
    end
  end

  defp protected_entry do
    with true <- System.get_env("ERL_CRASH_DUMP") == "/dev/null",
         true <- System.get_env("ERL_CRASH_DUMP_SECONDS") == "0",
         true <- no_core_applications?() do
      # Concept: a coding workspace cannot configure provider bootstrap.
      # Technical depth: ReqLLM startup and LLMDB's optional dotenv loader
      # default to enabling workspace files. Set their worker-local policy
      # before dependencies start, preserving it across application loading.
      Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
      Application.put_env(:llm_db, :load_dotenv, false, persistent: true)
      sink = spawn_link(fn -> io_sink() end)
      true = Process.group_leader(self(), sink)
      :ok = :logger.set_primary_config(:level, :none)
      :ok
    else
      _unprotected -> :error
    end
  end

  defp no_core_applications? do
    Application.started_applications()
    |> Enum.all?(fn {application, _, _} -> application not in @forbidden_apps end)
  end

  # Concept: every provider task in this fresh child inherits private IO policy
  # before readiness permits a credential to enter the VM.
  # Technical depth: OTP application startup uses an application-master group
  # leader, not the entry process's leader. Bind only the child-local ReqLLM
  # supervisors to the entry's sink so externally supervised transport tasks
  # inherit it as well. No host process or shared supervisor is reachable here.
  defp protect_dependency_io do
    sink = Process.group_leader()

    if Enum.all?([Elixir.ReqLLM.Supervisor, Elixir.ReqLLM.TaskSupervisor], fn name ->
         case Process.whereis(name) do
           pid when is_pid(pid) -> Process.group_leader(pid, sink)
           nil -> false
         end
       end) do
      :ok
    else
      :error
    end
  end

  defp manifest_matches(expected) do
    # The build replaces this one module after ordinary compilation. A dynamic
    # invocation is intentional: the source placeholder returns nil, while the
    # packaged module carries the immutable manifest checked below.
    case :erlang.apply(ProviderBuildIdentity, :manifest, []) do
      %{
        "source" => source,
        "version" => version,
        "dependency_lock_sha256" => lock,
        "packaged_input_sha256" => input,
        "elixir" => elixir,
        "otp" => otp
      } = manifest
      when map_size(manifest) == 6 and is_binary(source) and is_binary(version) and
             is_binary(lock) and is_binary(input) and is_binary(elixir) and is_binary(otp) ->
        actual =
          :crypto.hash(:sha256, :erlang.term_to_binary(manifest, [:deterministic]))
          |> Base.encode16(case: :lower)

        if actual == expected and elixir == System.version() and otp == otp_version(),
          do: :ok,
          else: :error

      _unbuilt ->
        :error
    end
  end

  @doc false
  def otp_version do
    root = :code.root_dir() |> List.to_string()
    release = :erlang.system_info(:otp_release) |> List.to_string()
    root |> Path.join("releases/#{release}/OTP_VERSION") |> File.read!() |> String.trim()
  end

  defp bootstrap(nonce, digest),
    do: %{
      "nonce" => nonce,
      "version" => ProviderCodec.version(),
      "build_manifest_sha256" => digest
    }

  defp invoke(socket, nonce, request, credential, deadline) do
    owner = self()
    input_guard = spawn_link(fn -> refuse_further_input(socket, owner, deadline) end)

    try do
      invoke_once(socket, nonce, request, credential, deadline)
    after
      # Concept: one accepted invocation consumes the channel's entire input
      # authority. The input observer belongs only to this worker and is stopped
      # before the worker closes its own socket after a terminal write.
      Process.unlink(input_guard)
      Process.exit(input_guard, :kill)
    end
  end

  defp refuse_further_input(socket, owner, deadline) do
    # Read only a single byte: a duplicate, any unknown frame, or parent loss
    # invalidates the one-use channel. Never parse or forward another credential
    # and never turn this observation into another provider invocation.
    case :gen_tcp.recv(socket, 1, min(remaining(deadline), 3_600_000)) do
      {:error, :timeout} ->
        if remaining(deadline) > 0,
          do: refuse_further_input(socket, owner, deadline),
          else: Process.exit(owner, :kill)

      _data_or_channel_loss ->
        Process.exit(owner, :kill)
    end
  end

  defp invoke_once(socket, nonce, request, credential, deadline) do
    # A separate bounded writer may block on its one in-flight frame. The host
    # guardian enforces the committed deadline and owns OS cleanup, so this is
    # not an independent transport timeout or an unbounded producer mailbox.
    :ok = :inet.setopts(socket, send_timeout: :infinity, send_timeout_close: true)
    slots = :ets.new(__MODULE__, [:set, :public])
    closed = :atomics.new(1, [])
    owner = self()

    writer =
      spawn_link(fn ->
        write_frames(socket, nonce, request.staged_request_digest, owner, slots)
      end)

    # One queued delta plus one in-flight frame is the entire progress backlog.
    # Producer callbacks neither wait for a reader nor allocate mailbox entries
    # when the slot is occupied. Terminal delivery has a separate single slot.
    progress = fn delta ->
      if Model.valid_delta?(delta) and :atomics.get(closed, 1) == 0 and
           :ets.insert_new(slots, {:delta, delta}) do
        send(writer, :progress_ready)
      end

      :ok
    end

    started = fn ->
      send(writer, {:dispatch_started, self()})

      receive do
        {:dispatch_started_written, ^writer} -> :ok
        {:writer_failed, ^writer} -> exit(:provider_channel_failed)
      end
    end

    outcome = ReqLLM.worker_invoke(request, credential, progress, started)
    :atomics.put(closed, 1, 1)
    send(writer, {:terminal, terminal(outcome)})

    await_terminal(writer, deadline)
  end

  defp await_terminal(writer, deadline) do
    receive do
      {:terminal_written, ^writer} -> :ok
      {:writer_failed, ^writer} -> :error
    after
      min(remaining(deadline), 3_600_000) ->
        if remaining(deadline) == 0, do: :error, else: await_terminal(writer, deadline)
    end
  end

  defp terminal({:ok, reply}) when is_map(reply) do
    case ProviderAttempt.admitted_raw_reply(reply) do
      :ok -> %{"status" => "reply", "reply" => reply}
      _unreadable -> %{"status" => "unreadable"}
    end
  end

  defp terminal({:error, {:not_dispatched, "model_call_failed"}}),
    do: %{"status" => "not_dispatched"}

  defp terminal({:error, {:dispatched_or_unknown, "model_call_failed"}, failure}),
    do: %{"status" => "dispatched_or_unknown", "failure" => failure}

  defp terminal(_uncertain),
    do: %{
      "status" => "dispatched_or_unknown",
      "failure" => %{"stage" => "unavailable", "class" => "unclassified"}
    }

  defp write_frames(socket, nonce, digest, owner, slots) do
    binding = %{"nonce" => nonce, "staged_request_digest" => digest}

    receive do
      {:terminal, result} ->
        result = ProviderCodec.send(socket, :terminal, Map.merge(binding, result))
        send(owner, {if(result == :ok, do: :terminal_written, else: :writer_failed), self()})

      {:dispatch_started, caller} ->
        case ProviderCodec.send(socket, :dispatch_started, binding) do
          :ok ->
            send(caller, {:dispatch_started_written, self()})
            write_frames(socket, nonce, digest, owner, slots)

          _error ->
            send(owner, {:writer_failed, self()})
        end

      :progress_ready ->
        # A terminal already enqueued takes precedence over a queued delta.
        receive do
          {:terminal, result} ->
            result = ProviderCodec.send(socket, :terminal, Map.merge(binding, result))
            send(owner, {if(result == :ok, do: :terminal_written, else: :writer_failed), self()})
        after
          0 ->
            case :ets.take(slots, :delta) do
              [{:delta, delta}] ->
                case ProviderCodec.send(socket, :delta, Map.put(binding, "payload", delta)) do
                  :ok -> write_frames(socket, nonce, digest, owner, slots)
                  _error -> send(owner, {:writer_failed, self()})
                end

              [] ->
                write_frames(socket, nonce, digest, owner, slots)
            end
        end
    end
  end

  defp remaining(deadline), do: max(deadline - System.system_time(:millisecond), 0)

  defp io_sink do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, {:error, :enotsup}})
        io_sink()

      _other ->
        io_sink()
    end
  end
end
