defmodule LoopexCli.DurableAsk do
  @moduledoc """
  ## Concept

  Runs one fresh durable `ask` session without owning the session's truth or
  printing a provisional answer. The caller has already admitted argv, cwd and
  prompt. A failure leaves the actual committed prefix in the state root.

  ## Technical depth

  The private dependency seams let the command witness observe each boundary
  without a second implementation of the workflow. The production path calls
  the released facade and composition directly. Only a result returned after
  runtime cleanup, credential-plane release and placement release is rendered.
  Explicit tracing starts before session creation, uses the shared stderr
  consumer and seals delivery before composition teardown. The consumer's
  certificate and every captured process DOWN must arrive within the original
  cleanup cutoff; missing proof discards the provisional answer.
  """

  alias LoopexCli.AskResult
  alias LoopexCli.DurableAsk.FollowReader
  alias LoopexComposition.TraceConfiguration

  @uint64_max 18_446_744_073_709_551_615
  @default_deadline_ms 600_000
  @coding ~w(loopex.read loopex.write loopex.edit loopex.bash)
  @read_only ~w(loopex.read loopex.grep loopex.find loopex.ls)

  @doc """
  ## Concept

  Returns one complete command result. It writes no terminal byte.

  ## Technical depth

  `options` is the validated `AskOptions` map. `cwd` and `prompt` have passed
  their common admission checks. The fourth argument is an internal test seam,
  not a CLI option. Each supplied function replaces exactly one boundary.
  """
  @spec run(map(), binary(), binary(), keyword()) :: %{
          status: non_neg_integer(),
          stdout: binary(),
          stderr: binary()
        }
  def run(options, cwd, prompt, seams \\ []) do
    dependencies = Map.merge(defaults(), Map.new(seams))

    try do
      options
      |> execute(cwd, prompt, dependencies)
      |> render(Map.get(options, :output))
    rescue
      _ -> AskResult.diagnostic(:command_failed)
    catch
      _, _ -> AskResult.diagnostic(:command_failed)
    end
  end

  defp defaults do
    %{
      read_directories: &LoopexComposition.ResourcePacks.read_directories/2,
      acquire_placement: &LoopexComposition.Placement.acquire/1,
      release_placement: &LoopexComposition.Placement.release/1,
      facade: &apply/3,
      open_credential_host: &LoopexCli.CredentialCache.host/0,
      credential_plane: &LoopexComposition.CredentialHost.plane/1,
      release_credential_plane: &LoopexComposition.CredentialHost.release_plane/1,
      provider_launch: &LoopexCli.ProviderLaunch.options/0,
      with_runtime: &LoopexComposition.with_runtime/2,
      interrupt_install: &LoopexCli.Interrupt.install/2,
      entropy: &:crypto.strong_rand_bytes/1,
      utc_now: &DateTime.utc_now/0,
      monotonic_ms: fn -> System.monotonic_time(:millisecond) end
    }
  end

  defp execute(
         %{profile: :durable, state_root: root, skills: skills} = options,
         cwd,
         prompt,
         deps
       )
       when is_binary(root) and is_binary(cwd) and is_binary(prompt) do
    with {:ok, resources} <- read_directories(skills, cwd, deps),
         :ok <- model_supported(options.model),
         {:ok, lock} <- acquire_placement(root, deps) do
      try do
        with {:ok, placement} <- placement_id(root, deps),
             {:ok, host} <- open_host(deps),
             {:ok, plane} <- open_plane(deps, host) do
          try do
            case protected(fn ->
                   composition_options =
                     composition_options(options, cwd, resources.manifest, placement, plane, deps)

                   with_diagnostics(options, composition_options, deps, fn runtime ->
                     callback(runtime, options, cwd, prompt, resources, placement, deps)
                   end)
                 end) do
              {:ok, result} -> composition_result(result)
              :failed -> {:diagnostic, :composition_unavailable}
            end
          after
            deps.release_credential_plane.(plane)
          end
        else
          {:diagnostic, _code} = diagnostic -> diagnostic
        end
      after
        deps.release_placement.(lock)
      end
    end
  end

  defp execute(_, _, _, _), do: {:diagnostic, :command_failed}

  # Concept: durable ask owns its diagnostic delivery separately from results.
  # Technical depth: activation precedes session creation; close seals the drain
  # before composition teardown and joins every captured actor under one cutoff.
  defp with_diagnostics(options, composition_options, deps, callback) do
    case Map.get(options, :trace) do
      nil -> deps.with_runtime.(composition_options, callback)
      trace -> traced_runtime(trace, composition_options, deps, callback)
    end
  end

  defp traced_runtime(trace, options, deps, callback) do
    case TraceConfiguration.validate(trace) do
      {:ok, %{enabled: false}} ->
        deps.with_runtime.(options, callback)

      {:ok, %{enabled: true, configuration: configuration}} ->
        grace = Loopex.Executor.default_cleanup_grace_ms()

        case LoopexCli.DiagnosticLifetime.start(Map.get(deps, :diagnostic_device, :stderr), grace) do
          {:ok, consumer} ->
            own_diagnostics(consumer, grace, configuration, options, deps, callback)

          _ ->
            {:diagnostic, :composition_unavailable}
        end

      _ ->
        {:diagnostic, :invalid_trace_configuration}
    end
  end

  defp own_diagnostics(consumer, grace, configuration, options, deps, callback) do
    monitors = %{consumer => Process.monitor(consumer)}
    tag = make_ref()

    result =
      protected(fn ->
        deps.with_runtime.(
          options ++ [diagnostics_to: consumer, cleanup_grace_ms: grace],
          fn runtime ->
            try do
              case facade(deps, Loopex, :trace, [runtime, configuration]) do
                {:ok, %{} = _status} -> callback.(runtime)
                _ -> {:diagnostic, :trace_start_failed}
              end
            after
              send(
                self(),
                {tag, LoopexCli.DiagnosticLifetime.begin_close(consumer, grace, monitors)}
              )
            end
          end
        )
      end)

    closing =
      receive do
        {^tag, closing} -> closing
      after
        0 -> LoopexCli.DiagnosticLifetime.begin_close(consumer, grace, monitors)
      end

    if LoopexCli.DiagnosticLifetime.join(consumer, closing) do
      case result do
        {:ok, result} -> result
        :failed -> {:diagnostic, :composition_unavailable}
      end
    else
      {:diagnostic, :runtime_cleanup_unconfirmed}
    end
  end

  defp read_directories(skills, cwd, deps) do
    case protected(fn -> deps.read_directories.(skills, workspace: cwd) end) do
      {:ok, {:ok, %{manifest: %{} = manifest, shadowed_skills: shadows}}}
      when is_list(shadows) ->
        {:ok, %{manifest: manifest, shadowed_skills: shadows}}

      _ ->
        {:diagnostic, :skill_directories_unavailable}
    end
  end

  defp model_supported("ollama:" <> _), do: {:diagnostic, :durable_model_unsupported}
  defp model_supported(_), do: :ok

  defp acquire_placement(root, deps) do
    case protected(fn -> deps.acquire_placement.(root) end) do
      {:ok, {:ok, lock}} -> {:ok, lock}
      _ -> {:diagnostic, :durable_runtime_unavailable}
    end
  end

  defp open_host(deps) do
    case protected(fn -> deps.open_credential_host.() end) do
      {:ok, {:ok, host}} ->
        {:ok, host}

      {:ok, {:error, :provider_credential_required}} ->
        {:diagnostic, :provider_credential_required}

      _ ->
        {:diagnostic, :composition_unavailable}
    end
  end

  defp placement_id(root, deps) do
    case facade(deps, Loopex, :runtime_placement_id, [root]) do
      {:ok, placement} when is_binary(placement) ->
        if bounded_id?(placement),
          do: {:ok, placement},
          else: {:diagnostic, :durable_runtime_unavailable}

      _ ->
        {:diagnostic, :durable_runtime_unavailable}
    end
  end

  defp open_plane(deps, host) do
    case protected(fn -> deps.credential_plane.(host) end) do
      {:ok, {:ok, plane}} -> {:ok, plane}
      _ -> {:diagnostic, :composition_unavailable}
    end
  end

  defp composition_options(options, cwd, manifest, placement, plane, deps) do
    base = [
      runtime_id: placement,
      state_root: options.state_root,
      workspace: cwd,
      policy: options.policy,
      active_tools: active_tools(options.tools),
      resource_manifest: manifest,
      provider_launch: deps.provider_launch.(),
      recover_stale_writer: true,
      credential_plane: plane
    ]

    model = if is_nil(options.model), do: [], else: [model: options.model]
    bounds = bounds(options)
    base ++ model ++ if(bounds == %{}, do: [], else: [bounds: bounds])
  end

  defp active_tools(:none), do: []
  defp active_tools(:read_only), do: @read_only
  defp active_tools(:coding), do: @coding

  defp bounds(options) do
    %{}
    |> maybe_bound(:max_turns, options.max_steps)
    |> maybe_bound(:deadline_ms, options.deadline_ms)
  end

  defp maybe_bound(bounds, _key, nil), do: bounds
  defp maybe_bound(bounds, key, value), do: Map.put(bounds, key, value)

  defp composition_result({:observation, _ending} = observation), do: observation
  defp composition_result({:diagnostic, _code} = diagnostic), do: diagnostic

  defp composition_result({:error, {:composition_cleanup_unconfirmed, _}}),
    do: {:diagnostic, :runtime_cleanup_unconfirmed}

  defp composition_result({:error, {:composition, :durable_model_unsupported}}),
    do: {:diagnostic, :durable_model_unsupported}

  defp composition_result(_), do: {:diagnostic, :composition_unavailable}

  defp callback(runtime, options, _cwd, prompt, resources, placement, deps) do
    root = options.state_root

    with {:ok, create_id} <- command_id(deps),
         {:ok, session_id} <- create(runtime, create_id, deps),
         :ok <- track(root, session_id, placement, deps),
         {:ok, attachment} <- attach(runtime, session_id, deps),
         :ok <- admit_resources(runtime, session_id, attachment, resources.manifest, deps),
         {:ok, grace} <- status(runtime, session_id, deps),
         :ok <- install_interrupt(attachment, grace, deps),
         {:ok, prompt_id} <- command_id(deps),
         :ok <- prompt(attachment, prompt_id, prompt, deps) do
      started_at = deps.monotonic_ms.()

      FollowReader.follow(
        runtime,
        session_id,
        prompt_id,
        started_at,
        options.deadline_ms || @default_deadline_ms,
        resources.shadowed_skills,
        facade: deps.facade,
        monotonic_ms: deps.monotonic_ms
      )
    end
  end

  defp command_id(deps) do
    case protected(fn -> deps.entropy.(16) end) do
      {:ok, <<bytes::binary-size(16)>>} ->
        {:ok, "cli-" <> Base.encode16(bytes, case: :lower)}

      _ ->
        {:diagnostic, :command_failed}
    end
  end

  defp create(runtime, id, deps) do
    case facade(deps, Loopex, :create_session, [runtime, %{"surface" => "cli"}, [command_id: id]]) do
      {:ok, session_id} when is_binary(session_id) ->
        if bounded_id?(session_id),
          do: {:ok, session_id},
          else: {:diagnostic, :session_create_failed}

      _ ->
        {:diagnostic, :session_create_failed}
    end
  end

  defp track(root, session_id, placement, deps) do
    case facade(deps, Loopex, :track_session, [root, session_id, placement]) do
      :ok -> :ok
      _ -> {:diagnostic, :session_tracking_failed}
    end
  end

  defp attach(runtime, session_id, deps) do
    case facade(deps, Loopex, :attach, [runtime, session_id, [after_event_sequence: 0]]) do
      {:ok, %Loopex.Attachment{} = attachment} -> {:ok, attachment}
      _ -> {:diagnostic, :attachment_failed}
    end
  end

  defp admit_resources(_runtime, _session_id, _attachment, %{"packs" => []}, _deps), do: :ok

  defp admit_resources(runtime, session_id, attachment, manifest, deps) do
    with {:ok, digest, normalized} <- manifest_digest(manifest),
         {:ok, decision} <- decision(digest, normalized, deps),
         :ok <-
           submit(
             attachment,
             :admit_resources,
             %{manifest_digest: digest, decision: decision},
             :resource_admission_failed,
             deps
           ),
         :ok <- catalog(runtime, session_id, digest, normalized, deps) do
      activate(attachment, digest, normalized, deps)
    end
  end

  defp manifest_digest(manifest) do
    case protected(fn -> Loopex.ResourcePack.digest(manifest) end) do
      {:ok, {:ok, digest, normalized}} -> {:ok, digest, normalized}
      _ -> {:diagnostic, :resource_admission_failed}
    end
  end

  defp decision(digest, normalized, deps) do
    case protected(fn -> deps.utc_now.() end) do
      {:ok, %DateTime{} = now} ->
        {:ok,
         %{
           "manifest_digest" => digest,
           "workspace_ref" => normalized["workspace_ref"],
           "trust_scope" => "project_skills",
           "decision_source" => "host_supplied",
           "issued_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
           "expires_at" => nil,
           "revocation_state" => "active"
         }}

      _ ->
        {:diagnostic, :resource_admission_failed}
    end
  end

  defp submit(attachment, type, payload, failure, deps) do
    with {:ok, id} <- command_id(deps) do
      command = Map.merge(payload, %{type: type, command_id: id})

      case facade(deps, Loopex, :command, [attachment, command]) do
        {:accepted, ^id} -> :ok
        _ -> {:diagnostic, failure}
      end
    end
  end

  defp catalog(runtime, session_id, digest, normalized, deps) do
    expected =
      normalized["packs"]
      |> Enum.map(&{&1["source_id"], &1["name"], Loopex.ResourcePack.pack_digest(&1)})
      |> Enum.sort()

    case facade(deps, Loopex, :resource_catalog, [runtime, session_id]) do
      {:ok,
       %{
         "configured_manifest_digest" => ^digest,
         "admitted_manifest_digest" => ^digest,
         "decision_disposition" => "active",
         "entries" => entries
       }}
      when is_list(entries) ->
        actual = Enum.map(entries, &catalog_tuple/1)

        if length(actual) == length(expected) and Enum.sort(actual) == expected,
          do: :ok,
          else: {:diagnostic, :resource_admission_failed}

      _ ->
        {:diagnostic, :resource_admission_failed}
    end
  end

  defp catalog_tuple(%{"source_id" => source, "name" => name, "pack_digest" => digest})
       when is_binary(source) and is_binary(name) and is_binary(digest),
       do: {source, name, digest}

  defp catalog_tuple(_), do: :invalid

  defp activate(attachment, digest, normalized, deps) do
    normalized["packs"]
    |> Enum.sort_by(&{&1["source_id"], &1["name"]})
    |> Enum.reduce_while(:ok, fn pack, :ok ->
      payload = %{
        manifest_digest: digest,
        source_id: pack["source_id"],
        name: pack["name"],
        pack_digest: Loopex.ResourcePack.pack_digest(pack),
        supporting_labels: []
      }

      case submit(attachment, :activate_skill, payload, :skill_activation_failed, deps) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp status(runtime, session_id, deps) do
    case facade(deps, Loopex, :session_status, [runtime, session_id]) do
      {:ok, %{status: :active, cleanup_grace_ms: grace}}
      when is_integer(grace) and grace > 0 and grace <= @uint64_max ->
        {:ok, grace}

      _ ->
        {:diagnostic, :session_status_failed}
    end
  end

  defp install_interrupt(attachment, grace, deps) do
    _ = protected(fn -> deps.interrupt_install.(attachment, grace) end)
    :ok
  end

  defp prompt(attachment, id, content, deps) do
    case facade(deps, Loopex, :command, [
           attachment,
           %{type: :prompt, command_id: id, content: content}
         ]) do
      {:accepted, ^id} -> :ok
      _ -> {:diagnostic, :prompt_submission_failed}
    end
  end

  defp facade(deps, module, function, arguments) do
    case protected(fn -> deps.facade.(module, function, arguments) end) do
      {:ok, result} -> result
      :failed -> {:error, :facade_unavailable}
    end
  end

  defp protected(function) do
    try do
      {:ok, function.()}
    rescue
      _ -> :failed
    catch
      _, _ -> :failed
    end
  end

  defp bounded_id?(id),
    do: byte_size(id) in 1..256 and String.valid?(id)

  defp render({:observation, ending}, "json"), do: AskResult.render(ending, :durable, :json)
  defp render({:observation, ending}, "text"), do: AskResult.render(ending, :durable, :text)
  defp render({:diagnostic, code}, _output), do: AskResult.diagnostic(code)
  defp render(_, _output), do: AskResult.diagnostic(:command_failed)
end
