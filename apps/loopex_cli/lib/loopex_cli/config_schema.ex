defmodule LoopexCli.ConfigSchema do
  @moduledoc """
  ## Concept

  Validate the authored configuration file before flags can override it. Required
  policy, provider routes and conversation bounds cannot acquire spending or
  authority defaults from this boundary.

  ## Technical depth

  ADR 0049's schema version 1 is closed at every object. This validation
  retains authored values and paths, with stable classes and RFC 6901 pointers.
  Provider reference validation is shared with composition; model syntax uses
  the adapter's compiled catalog. Cross-field checks bind selected models and
  enabled roles to explicit routes, reject disabled-tool delegation, and check
  explicit context ceilings. Path resolution, prompt-file reads, model-capability
  resolution, harmless defaults and effective-profile admission happen later.
  In particular, inferred model windows and reasoning support are not proved by
  syntax validation. Trace selectors use compiled trusted-application metadata;
  reading that inventory starts no application and resolves no credential.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Guards
  alias LoopexCli.{AskOptions, TraceSelectors}
  alias LoopexComposition.ProviderBindings

  @uint64 18_446_744_073_709_551_615
  @role ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @levels ~w(default none low medium high)

  @doc """
  ## Concept

  Admit the complete authored file shape without replacing or applying values.

  ## Technical depth

  Every supplied optional field is checked, including settings disabled by
  another field. Unknown keys precede missing-member and value checks within
  each object. A null is never an omitted option. Positive turn/token spending
  bounds preserve the BEAM integer domain; deadline, cleanup and context values
  retain their existing unsigned-64-bit limits.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  def validate(config) do
    checks = [
      {"schema_version", &version/2},
      {"paths", &paths/2},
      {"providers", &providers/2},
      {"policy", &policy/2},
      {"session", &session/2},
      {"maintenance", &maintenance/2},
      {"roles", &roles/2},
      {"delegation", &delegation/2},
      {"trace", &trace/2},
      {"output", &choice(&1, &2, ["text"])}
    ]

    with :ok <- object(config, "", ~w(schema_version providers policy session), checks),
         :ok <- relationships(config) do
      {:ok, config}
    end
  end

  defp version(1, _pointer), do: :ok

  defp version(value, pointer) when is_integer(value),
    do: error(:unsupported_schema_version, pointer)

  defp version(_, pointer), do: error(:invalid_type, pointer)

  defp paths(value, pointer),
    do: object(value, pointer, [], [{"workspace", &path/2}, {"state_root", &path/2}])

  defp providers(value, _pointer) do
    case ProviderBindings.validate(value) do
      {:ok, _validated} -> :ok
      {:error, _} = error -> error
    end
  end

  defp policy(value, pointer), do: choice(value, pointer, Map.keys(AskOptions.policy_profiles()))

  defp session(value, pointer) do
    checks = [
      {"model", &model/2},
      {"bounds", &bounds(&1, &2, @uint64)},
      {"reasoning", &choice(&1, &2, @levels)},
      {"max_tokens", &positive/2},
      {"context_token_budget", &limited(&1, &2, @uint64)},
      {"system_class_tokens", &limited(&1, &2, @uint64)},
      {"instructions", &instructions/2},
      {"tools", &choice(&1, &2, ~w(coding read-only none))},
      {"skill_dirs", fn value, at -> array(value, at, 16, &path/2) end},
      {"cleanup_grace_ms", &limited(&1, &2, @uint64)}
    ]

    with :ok <- object(value, pointer, ~w(model bounds), checks),
         do: context_ceiling(value, pointer)
  end

  defp instructions(value, pointer),
    do: object(value, pointer, [], [{"system_file", &path/2}, {"append_file", &path/2}])

  defp maintenance(value, pointer), do: object(value, pointer, ["model"], [{"model", &model/2}])

  defp roles(value, pointer) when is_map(value) and map_size(value) <= 16 do
    Enum.reduce_while(Enum.sort(value), :ok, fn {name, role}, :ok ->
      result =
        if is_binary(name) do
          at = child(pointer, name)

          with :ok <- role_name(name, at) do
            object(role, at, ~w(model instructions_file), [
              {"model", &model/2},
              {"instructions_file", &path/2},
              {"reasoning", &choice(&1, &2, @levels)}
            ])
          end
        else
          error(:invalid_type, pointer)
        end

      continue(result)
    end)
  end

  defp roles(value, pointer) when is_map(value), do: error(:too_many_members, pointer)
  defp roles(_, pointer), do: error(:invalid_type, pointer)

  defp delegation(value, pointer) do
    checks = [
      {"enabled", &boolean/2},
      {"roles", fn value, at -> array(value, at, 16, &role_name/2) end},
      {"max_children", &limited(&1, &2, 128)},
      {"token_budget", &positive/2},
      {"child_bounds", &bounds(&1, &2, 600_000)},
      {"max_tokens", &positive/2},
      {"context_token_budget", &limited(&1, &2, @uint64)},
      {"system_class_tokens", &limited(&1, &2, @uint64)}
    ]

    with :ok <- object(value, pointer, [], checks),
         :ok <- context_ceiling(value, pointer) do
      if Map.get(value, "enabled", false) do
        with :ok <- required(value, pointer, ~w(roles max_children token_budget child_bounds)),
             do: nonempty_roles(value["roles"], child(pointer, "roles"))
      else
        :ok
      end
    end
  end

  defp trace(value, pointer) do
    ceilings = Loopex.Trace.Config.ceilings()

    object(value, pointer, [], [
      {"enabled", &boolean/2},
      {"level", &choice(&1, &2, ~w(calls returns arguments))},
      {"modules", &trace_modules/2},
      {"max_entry_bytes", &limited(&1, &2, ceilings.entry_bytes)},
      {"max_entries_per_second", &limited(&1, &2, ceilings.entries_per_second)},
      {"max_queue_entries", &limited(&1, &2, ceilings.queued)}
    ])
  end

  defp trace_modules(value, pointer) do
    with :ok <- array(value, pointer, 64, fn name, at -> text(name, at, 128) end) do
      case TraceSelectors.resolve(value) do
        {:ok, _} ->
          :ok

        {:error, {class, index}} when is_integer(index) ->
          error(class, child(pointer, Integer.to_string(index)))

        {:error, {class, nil}} ->
          error(class, pointer)
      end
    end
  end

  defp bounds(value, pointer, deadline_limit) do
    object(value, pointer, ~w(max_turns deadline_ms token_budget), [
      {"max_turns", &positive/2},
      {"deadline_ms", &limited(&1, &2, deadline_limit)},
      {"token_budget", &positive/2}
    ])
  end

  defp relationships(config) do
    with :ok <- bound_model(config["session"]["model"], config, "/session/model"),
         :ok <- maintenance_route(config),
         do: delegation_roles(config)
  end

  defp maintenance_route(%{"maintenance" => %{"model" => model}} = config),
    do: bound_model(model, config, "/maintenance/model")

  defp maintenance_route(_), do: :ok

  defp bound_model(model, config, pointer) do
    [provider, _] = String.split(model, ":", parts: 2)

    if Map.has_key?(config["providers"], provider),
      do: :ok,
      else: error(:missing_provider_binding, pointer)
  end

  defp delegation_roles(config) do
    delegation = Map.get(config, "delegation", %{})
    roles = Map.get(config, "roles", %{})
    selected = Map.get(delegation, "roles", [])

    cond do
      Map.get(delegation, "enabled", false) and config["session"]["tools"] == "none" ->
        error(:delegation_requires_tools, "/delegation/enabled")

      Enum.uniq(selected) != selected ->
        error(:duplicate_role, "/delegation/roles")

      true ->
        selected
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {role, index}, :ok ->
          pointer = "/delegation/roles/#{index}"

          result =
            case Map.fetch(roles, role) do
              :error ->
                error(:unknown_role, pointer)

              {:ok, definition} ->
                if Map.get(delegation, "enabled", false),
                  do: bound_model(definition["model"], config, "/roles/#{role}/model"),
                  else: :ok
            end

          continue(result)
        end)
    end
  end

  defp context_ceiling(%{"context_token_budget" => context} = value, pointer) do
    if Map.get(value, "system_class_tokens", 1_000) <= context,
      do: :ok,
      else: error(:system_ceiling_exceeds_context, child(pointer, "system_class_tokens"))
  end

  defp context_ceiling(_, _), do: :ok

  defp object(value, pointer, required_keys, checks) when is_map(value) do
    keys = Enum.map(checks, &elem(&1, 0))

    case Enum.sort(Map.keys(value) -- keys) do
      [] ->
        with :ok <- required(value, pointer, required_keys) do
          Enum.reduce_while(checks, :ok, fn {key, validator}, :ok ->
            result =
              case Map.fetch(value, key) do
                :error -> :ok
                {:ok, nil} -> error(:null_not_allowed, child(pointer, key))
                {:ok, member} -> validator.(member, child(pointer, key))
              end

            continue(result)
          end)
        end

      [unknown | _] when is_binary(unknown) ->
        error(:unknown_member, child(pointer, unknown))

      _ ->
        error(:invalid_type, pointer)
    end
  end

  defp object(nil, pointer, _, _), do: error(:null_not_allowed, pointer)
  defp object(_, pointer, _, _), do: error(:invalid_type, pointer)

  defp required(value, pointer, keys) do
    case Enum.find(keys, &(not Map.has_key?(value, &1))) do
      nil -> :ok
      missing -> error(:missing_member, child(pointer, missing))
    end
  end

  defp array(value, pointer, limit, validator) when is_list(value),
    do: array_members(value, pointer, limit, validator, 0)

  defp array(_, pointer, _, _), do: error(:invalid_type, pointer)

  defp array_members([], _, _, _, _), do: :ok

  defp array_members([_ | _], pointer, limit, _, index) when index >= limit,
    do: error(:too_many_items, pointer)

  defp array_members([value | rest], pointer, limit, validator, index) do
    at = child(pointer, Integer.to_string(index))

    result = if is_nil(value), do: error(:null_not_allowed, at), else: validator.(value, at)
    with :ok <- result, do: array_members(rest, pointer, limit, validator, index + 1)
  end

  defp array_members(_, pointer, _, _, _), do: error(:invalid_type, pointer)

  defp model(value, pointer) do
    case Guards.model(value) do
      {:ok, _} -> :ok
      {:error, _} -> error(:invalid_model, pointer)
    end
  end

  defp role_name(value, pointer) do
    with :ok <- text(value, pointer, 64),
         true <- Regex.match?(@role, value) do
      :ok
    else
      false -> error(:invalid_identifier, pointer)
      {:error, _} = error -> error
    end
  end

  defp path(value, pointer) do
    with :ok <- text(value, pointer, 4_096) do
      if String.contains?(value, <<0>>), do: error(:invalid_path, pointer), else: :ok
    end
  end

  defp text(value, pointer, limit) when is_binary(value) do
    cond do
      not String.valid?(value) -> error(:invalid_utf8, pointer)
      byte_size(value) not in 1..limit -> error(:invalid_value, pointer)
      true -> :ok
    end
  end

  defp text(_, pointer, _), do: error(:invalid_type, pointer)

  defp positive(value, _pointer) when is_integer(value) and value > 0, do: :ok
  defp positive(value, pointer) when is_integer(value), do: error(:invalid_value, pointer)
  defp positive(_, pointer), do: error(:invalid_type, pointer)

  defp limited(value, pointer, limit) do
    with :ok <- positive(value, pointer) do
      if value <= limit, do: :ok, else: error(:invalid_value, pointer)
    end
  end

  defp choice(value, pointer, choices) when is_binary(value) do
    if value in choices, do: :ok, else: error(:invalid_value, pointer)
  end

  defp choice(_, pointer, _), do: error(:invalid_type, pointer)
  defp boolean(value, _) when is_boolean(value), do: :ok
  defp boolean(_, pointer), do: error(:invalid_type, pointer)
  defp nonempty_roles([], pointer), do: error(:invalid_value, pointer)
  defp nonempty_roles(_, _), do: :ok
  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, _} = error), do: {:halt, error}

  defp child(pointer, key),
    do: pointer <> "/" <> (key |> String.replace("~", "~0") |> String.replace("/", "~1"))

  defp error(class, pointer), do: {:error, {class, pointer}}
end
