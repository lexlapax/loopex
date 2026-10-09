defmodule LoopexCli.ConfigInspection do
  @moduledoc """
  ## Concept

  Validate or inspect exactly the new-session settings selected by an explicit
  file and flags. Report effective values and origins without reading credentials,
  opening session state, starting a runtime, enabling trace or invoking a model.

  ## Technical depth

  Reuses the authored file, precedence, instruction and model validators. Every
  saved role is independently resolved using child limits, with exactly the
  read-only generations. Enabled roles contribute their names and a preview
  catalog digest to parent instruction cost; this preview is not a retained
  delegation binding. The complete parent genesis is measured, including the
  fixed helper definition when enabled and a fixed-width workspace binding
  cost marker. Inspection does not require the workspace directory to exist
  and never retains that marker as a physical identity. Metadata resolution may consult the
  host-selected trusted model catalog. Credential references remain private;
  output contains only reference form and validity, never environment names,
  secret values, captured instructions, capabilities or provider mappings.
  Text output uses ordered pointers and escaped JSON values, with exact decimal
  quantities and no committed origin. No inspection result authorizes execution.
  """

  alias LoopexCli.{
    ChatConfiguration,
    ConfigFile,
    ConfigOptions,
    ConfigSelection
  }

  alias LoopexComposition.SessionInstructions
  alias LoopexComposition.ProviderBindings
  alias LoopexComposition.Delegation.Tool
  alias LoopexProtocol.Frame
  @resolved ~w(model reasoning max_tokens context_token_budget system_class_tokens)

  @doc """
  ## Concept

  Prepare the selected inspection before emitting any successful report.

  ## Technical depth

  Cwd and the permitted state-root environment value are explicit host inputs.
  The file's authored required bounds validate before overrides. Missing paths,
  invalid selected mappings, instruction reads, child ceilings and whole genesis
  bounds refuse with a stable class/pointer; offending values are never returned.
  The resulting private capture contains instructions and must not be printed.
  """
  @spec prepare(term(), term(), term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  def prepare(argv, cwd, home) do
    with {:ok, %{command: command} = parsed} when command in [:show, :validate] <-
           ConfigOptions.parse(argv),
         {:ok, file} <- ConfigFile.load(parsed.config, cwd),
         {:ok, selection} <- ConfigSelection.compose(file, parsed, cwd, home),
         :ok <- paths(selection.profile),
         {:ok, roles} <- roles(selection.profile),
         {:ok, instructions} <- parent_instructions(selection.profile, roles),
         definitions <- definitions(selection.profile),
         {:ok, selection} <-
           locate(
             ConfigSelection.resolve_session(selection, instructions, definitions),
             "/session"
           ),
         {:ok, _genesis} <-
           locate(
             ChatConfiguration.genesis(selection, definitions, workspace_cost_options()),
             "/session"
           ) do
      {:ok, %{command: command, selection: selection, roles: roles}}
    else
      {:error, {class, pointer}} when is_atom(class) and is_binary(pointer) ->
        {:error, {class, pointer}}

      _ ->
        {:error, {:invalid_configuration_inspection, ""}}
    end
  end

  # Concept: inspection measures the complete creation footprint without claiming a binding.
  # Technical depth: the current workspace reference has a fixed prefix and
  # 64 hexadecimal bytes. This measurement-only placeholder has identical byte
  # cost; it is never returned, persisted, used for execution or printed. New
  # chat replaces it with WorkspaceIdentity's verified physical reference.
  defp workspace_cost_options do
    ChatConfiguration.session_options("workspace:" <> String.duplicate("0", 64))
  end

  @doc """
  ## Concept

  Execute either inspection command and emit its redacted text report.

  ## Technical depth

  Writes only after complete preparation. Output failure returns a fixed class,
  never private captures or IO terms. This command owns stdout; unlike chat's
  asynchronous diagnostics, its exit confirms whether its report was written.
  """
  @spec run(term(), term(), term()) :: :ok | {:error, binary()}
  def run(argv, cwd, home) do
    with {:ok, prepared} <- prepare(argv, cwd, home),
         {:ok, bytes} <- report(prepared),
         :ok <- IO.write(:stdio, bytes) do
      :ok
    else
      {:error, {class, pointer}} -> {:error, "#{class} #{pointer}"}
      _ -> {:error, "configuration_report_unavailable"}
    end
  rescue
    _ -> {:error, "configuration_report_unavailable"}
  catch
    _, _ -> {:error, "configuration_report_unavailable"}
  end

  defp paths(profile) do
    Enum.reduce_while(~w(workspace state_root), :ok, fn key, :ok ->
      if is_binary(get_in(profile, ["paths", key])),
        do: {:cont, :ok},
        else: {:halt, {:error, {:missing_configuration_path, "/paths/" <> key}}}
    end)
  end

  defp roles(profile) do
    profile["roles"]
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, role}, {:ok, captures} ->
      pointer = "/roles/" <> name

      with {:ok, instructions} <-
             locate(
               SessionInstructions.capture_role(
                 profile["paths"]["workspace"],
                 "read-only",
                 role["instructions_file"]
               ),
               pointer <> "/instructions_file"
             ),
           declaration <-
             profile["delegation"]
             |> Map.take(~w(max_tokens context_token_budget system_class_tokens))
             |> Map.merge(Map.take(role, ~w(model reasoning)))
             |> Map.merge(%{"configuration_version" => 1, "instructions" => instructions}),
           {:ok, configuration} <-
             locate(
               ProviderBindings.resolve_configuration(
                 declaration,
                 profile["providers"],
                 ChatConfiguration.selected_definitions(
                   ChatConfiguration.active_tools("read-only") -- ["loopex.ask"]
                 )
               ),
               pointer
             ) do
        {:cont, {:ok, Map.put(captures, name, configuration)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp parent_instructions(profile, _roles) do
    options = Map.get(profile["session"], "instructions", %{})

    options =
      if profile["delegation"]["enabled"] do
        enabled = profile["delegation"]["roles"]
        # Concept: inspection measures the catalog fact without inventing its value.
        # Technical depth: the retained catalog digest is ADR 0056's SHA-256 of
        # the catalog object, which binds the placement-derived runtime identity
        # that inspection does not acquire. `Catalog.digest/3` produces the
        # exact value at parent creation; this fixed-width placeholder has the
        # identical byte cost and is never retained, executed or printed.
        digest = "sha256:" <> String.duplicate("0", 64)
        Map.merge(options, %{"enabled_roles" => enabled, "catalog_digest" => digest})
      else
        options
      end

    locate(
      SessionInstructions.capture(
        profile["paths"]["workspace"],
        profile["session"]["tools"],
        options
      ),
      "/session/instructions"
    )
  end

  defp definitions(profile) do
    definitions =
      ChatConfiguration.selected_definitions(
        ChatConfiguration.active_tools(profile["session"]["tools"])
      )

    if profile["delegation"]["enabled"], do: definitions ++ [Tool.definition()], else: definitions
  end

  defp locate({:ok, _} = result, _), do: result

  defp locate({:error, {class, pointer}}, _) when is_atom(class) and is_binary(pointer),
    do: {:error, {class, pointer}}

  defp locate({:error, class}, pointer) when is_atom(class), do: {:error, {class, pointer}}
  defp locate(_, pointer), do: {:error, {:invalid_configuration_selection, pointer}}

  defp report(%{command: :validate, selection: %{profile: profile}}) do
    unavailable = credential_free(profile["providers"])

    {:ok,
     [
       "Configuration valid.\n",
       Enum.map(unavailable, fn provider ->
         "#{provider}: credential-free binding cannot run chat.\n"
       end)
     ]}
  end

  defp report(%{command: :show, selection: selection, roles: roles}) do
    Enum.reduce_while(settings_rows(selection, roles), {:ok, []}, fn row, {:ok, output} ->
      case Frame.encode(%{"value" => row["value"]}) do
        {:ok, encoded} ->
          {:cont,
           {:ok,
            [
              output,
              row["setting"],
              " = ",
              String.trim_trailing(IO.iodata_to_binary(encoded), "\n"),
              " [",
              row["origin"],
              "]\n"
            ]}}

        _ ->
          {:halt, {:error, :configuration_report_unavailable}}
      end
    end)
  end

  @doc """
  ## Concept

  Project confirmed host settings into already-redacted presentation rows.

  ## Technical depth

  Config inspection and the chat startup diagnostic submission share this pure
  host-private projection. It reads only the supplied confirmed selection and
  resolved roles. Providers expose reference form/validity and unavailable
  commands, never environment-reference names or values. Instructions, role
  prompts, capabilities, mappings and continuation are not traversed.
  Ordered pointers retain indexed arrays, exact decimal quantities and their
  selected origins, including committed origins supplied by resume preparation.
  This projection performs no file, catalog, credential, Store or IO operation.
  Consumer admission separately owns each physical JSON line's byte ceiling.
  """
  @spec settings_rows(map(), map()) :: [map()]
  def settings_rows(selection, roles) do
    profile = selection.profile

    profile =
      put_in(
        profile,
        ["session"],
        Map.merge(profile["session"], Map.take(selection.configuration, @resolved))
      )

    profile =
      Map.put(profile, "maintenance", %{
        "model" =>
          if(selection.maintenance_model,
            do: selection.maintenance_model["model"],
            else: "unconfigured"
          )
      })

    profile =
      Enum.reduce(roles, profile, fn {name, configuration}, profile ->
        update_in(
          profile,
          ["roles", name],
          &Map.merge(&1, Map.take(configuration, ~w(model reasoning)))
        )
      end)

    provider_rows =
      Enum.flat_map(Enum.sort(profile["providers"]), fn {provider, binding} ->
        form =
          if credential_free?(binding), do: "credential_free", else: "environment_reference"

        origin =
          selection.origins["/providers/" <> provider <> "/credential/env"] ||
            selection.origins["/providers/" <> provider <> "/credential/none"]

        [
          {"/providers/" <> provider,
           %{
             "provider" => provider,
             "reference_form" => form,
             "reference_valid" => true,
             "unavailable_commands" => if(form == "credential_free", do: ["chat"], else: [])
           }, origin}
        ]
      end)

    policy = %{
      "origin" => "registry",
      "id" => inspect(Map.fetch!(LoopexCli.AskOptions.policy_profiles(), profile["policy"])),
      "revision" => "0.2.0",
      "fixture_manifest_digest" => nil
    }

    rows =
      leaves(Map.delete(profile, "providers"), "", selection.origins) ++
        provider_rows ++ [{"/policy_identity", policy, selection.origins["/policy"]}]

    rows =
      Enum.reduce(roles, rows, fn {name, configuration}, rows ->
        Enum.reduce(~w(max_tokens context_token_budget system_class_tokens), rows, fn field,
                                                                                      rows ->
          origin = selection.origins["/delegation/" <> field] || "default"
          [{"/roles/" <> name <> "/" <> field, configuration[field], origin} | rows]
        end)
      end)

    rows
    |> Enum.sort_by(fn {pointer, _, _} ->
      Enum.map(String.split(pointer, "/"), fn segment ->
        case Integer.parse(segment) do
          {index, ""} when index >= 0 -> {0, index}
          _ -> {1, segment}
        end
      end)
    end)
    |> Enum.map(fn {pointer, value, origin} ->
      %{"setting" => pointer, "value" => quantities(value), "origin" => origin || "default"}
    end)
  end

  defp credential_free?(%{"credential" => %{"none" => true}}), do: true
  defp credential_free?(_), do: false

  defp credential_free(bindings),
    do:
      bindings
      |> Enum.filter(fn {_, binding} -> credential_free?(binding) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

  defp leaves(value, pointer, origins) when is_map(value) and map_size(value) > 0,
    do:
      Enum.flat_map(value, fn {key, member} ->
        leaves(member, pointer <> "/" <> escape(key), origins)
      end)

  defp leaves(value, pointer, origins) when is_list(value) and value != [],
    do:
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {member, index} -> leaves(member, pointer <> "/#{index}", origins) end)

  defp leaves(value, pointer, origins),
    do: [{pointer, value, Map.get(origins, pointer, "default")}]

  defp quantities(value) when is_integer(value), do: Integer.to_string(value)

  defp quantities(value) when is_map(value),
    do: Map.new(value, fn {key, member} -> {key, quantities(member)} end)

  defp quantities(value) when is_list(value), do: Enum.map(value, &quantities/1)
  defp quantities(value), do: value
  defp escape(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")
end
