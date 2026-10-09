defmodule LoopexCli.Policy.M7Fixture do
  @moduledoc """
  ## Concept

  A trusted M7 harness permits the fixture's selected file tools and one exact
  oracle invocation. Ordinary configuration cannot select this policy. The
  harness supplies the command and pinned files outside the writable workspace;
  model arguments cannot expand that selection.

  ## Technical depth

  The private capture binds the case, manifest digest, physical workspace,
  literal argv, current tool generations and file digests/modes into its policy
  identity. Recheck workspace and files before startup and each decision.
  Only argv-form bash with exactly the captured vector is allowed; shell text,
  alternate arguments, generations, leases and directories refuse. Feature
  alone also admits the captured vector plus one catalog default, because its
  unpinned runner takes the operator's answer as that single argument. Review
  refuses file mutations while permitting its pinned test command. The existing Policy port owns
  timeout, durable decisions and grants. Captures perform no execution and do
  not authorize a provider attempt or replace the campaign admission procedure.
  The shared fixed runner recipe uses the hosting Elixir/OTP paths (Python 3 for the
  external task's oracle) and an empty
  child environment with only literal catalog inputs. Its bytes are returned
  without writing or running a command; fixture preparation must compare and
  pin those bytes before using the existing capture boundary.
  """

  @behaviour Loopex.Policy
  alias LoopexCli.ChatConfiguration
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexProtocol.{Canonical, ToolDefinition}

  @cases ~w(m7.repair m7.feature m7.review m7.long m7.external)

  @doc false
  def oracle_runner(case_id, workspace, oracle, environment) do
    with true <- case_id in @cases,
         true <- text?(workspace) and Path.type(workspace) == :absolute,
         true <- text?(oracle) and Path.type(oracle) == :absolute,
         true <- oracle_environment?(case_id, environment),
         {:ok, interpreter} <- interpreter(case_id) do
      path =
        Path.dirname(interpreter) <>
          ":" <> Path.join(List.to_string(:code.root_dir()), "bin") <> ":/usr/bin:/bin"

      extras =
        environment
        |> Enum.sort()
        |> Enum.map_join("", fn {name, value} -> " " <> name <> "=" <> shell_quote(value) end)

      {branch, extras} = branch(case_id, environment, extras)

      bytes =
        "#!/bin/sh\nset -eu\ntest -z \"${M7_FIXTURE_HOST_SENTINEL:-}\"\n" <>
          branch <>
          "exec /usr/bin/env -i PATH=" <>
          shell_quote(path) <>
          extras <>
          " M7_WORKSPACE=" <>
          shell_quote(workspace) <>
          " " <> shell_quote(interpreter) <> " " <> shell_quote(oracle) <> "\n"

      {:ok, %{bytes: bytes, interpreter: interpreter}}
    else
      _ -> {:error, :fixture_policy_unavailable}
    end
  rescue
    _ -> {:error, :fixture_policy_unavailable}
  end

  # Concept: before the operator answers, the feature runner cannot know the
  # selected default; its one approved argument selects the branch instead.
  # Technical depth: only the two catalog values pass, so the argument cannot
  # change the oracle, workspace or environment beyond that one variable.
  defp branch("m7.feature", environment, extras) when map_size(environment) == 0 do
    {"case \"${1:-}\" in empty|literal_null) ;; *) echo 'unselected nil default' >&2; exit 64 ;; esac\n",
     extras <> " M7_NIL_DEFAULT=\"$1\""}
  end

  defp branch(_case_id, _environment, extras), do: {"", extras}

  # Concept: the external task's oracle is the harness-owned Python test its
  # repository's own toolchain runs; every other oracle is an Elixir script.
  defp interpreter("m7.external") do
    case System.find_executable("python3") do
      nil -> {:error, :fixture_policy_unavailable}
      python -> WorkspaceIdentity.resolve_path(python)
    end
  end

  defp interpreter(_case_id),
    do:
      WorkspaceIdentity.resolve_path(
        Path.expand("../../bin/elixir", List.to_string(:code.lib_dir(:elixir)))
      )

  defp oracle_environment?("m7.feature", environment) when map_size(environment) == 0,
    do: true

  defp oracle_environment?("m7.feature", %{"M7_NIL_DEFAULT" => value} = environment),
    do: map_size(environment) == 1 and value in ["empty", "literal_null"]

  defp oracle_environment?("m7.review", %{"M7_FINDING" => value} = environment),
    do: map_size(environment) == 1 and text?(value) and Path.type(value) == :absolute

  defp oracle_environment?(case_id, environment)
       when case_id in ["m7.repair", "m7.long", "m7.external"],
       do: environment == %{}

  defp oracle_environment?(_, _), do: false
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @doc false
  def prepare(case_id, manifest_digest, workspace, argv, pins) do
    with true <- case_id in @cases and digest?(manifest_digest),
         true <- is_list(argv) and length(argv) in 1..16,
         true <- Enum.all?(argv, &text?/1),
         true <- is_map(pins) and map_size(pins) in 1..16,
         true <- Enum.all?(pins, fn {path, pin} -> pin?(path, pin) end),
         true <- Map.has_key?(pins, hd(argv)),
         true <- executable?(pins[hd(argv)].mode),
         true <- Enum.all?(argv, &(Path.type(&1) != :absolute or Map.has_key?(pins, &1))),
         {:ok, physical} <- WorkspaceIdentity.resolve_path(workspace),
         {:ok, reference} <- WorkspaceIdentity.reference(physical),
         {:ok, retained} <- retain_pins(pins, Path.expand(workspace), physical) do
      profile = "coding"

      definitions =
        ChatConfiguration.selected_definitions(ChatConfiguration.active_tools(profile))

      definitions =
        if case_id == "m7.review",
          do: Enum.reject(definitions, &(&1["tool_id"] in ~w(loopex.write loopex.edit))),
          else: definitions

      capture = %{
        case_id: case_id,
        manifest_digest: manifest_digest,
        workspace: physical,
        workspace_ref: reference,
        argv: argv,
        pins: retained,
        profile: profile,
        generations: Map.new(definitions, &{ToolDefinition.generation(&1), &1["effect_class"]})
      }

      {:ok, Map.put(capture, :identity, identity_for(capture))}
    else
      _ -> {:error, :fixture_policy_unavailable}
    end
  rescue
    _ -> {:error, :fixture_policy_unavailable}
  end

  @doc false
  def check(capture) do
    with true <-
           is_map(capture) and capture.identity == identity_for(Map.delete(capture, :identity)),
         {:ok, reference} <- WorkspaceIdentity.reference(capture.workspace),
         true <- reference == capture.workspace_ref,
         true <- Enum.all?(capture.pins, fn {path, pin} -> matches?(path, pin) end) do
      :ok
    else
      _ -> {:error, :fixture_policy_unavailable}
    end
  rescue
    _ -> {:error, :fixture_policy_unavailable}
  end

  @doc false
  def bind(invocation, nil), do: {:ok, invocation}

  def bind(invocation, capture) do
    with :ok <- check(capture),
         {:ok, reference} <-
           WorkspaceIdentity.reference(invocation.selection.profile["paths"]["workspace"]),
         true <- reference == capture.workspace_ref,
         true <- tools_match?(invocation, capture) do
      {:ok, Map.put(invocation, :harness_fixture, capture)}
    else
      _ -> {:error, :fixture_policy_binding_conflict}
    end
  rescue
    _ -> {:error, :fixture_policy_binding_conflict}
  end

  @doc false
  def identity(capture), do: capture.identity

  @doc false
  def report(capture) do
    %{
      origin: :harness,
      id: capture.identity["id"],
      revision: capture.identity["revision"],
      fixture_manifest_digest: capture.manifest_digest
    }
  end

  @impl true
  def decide(_request), do: {:deny, :policy_unavailable}

  @impl true
  def decide(request, capture) do
    with :ok <- check(capture),
         true <- request.workspace_lease == "workspace",
         {:ok, effect} <- Map.fetch(capture.generations, request.generation),
         true <- request.effect_class == effect,
         true <- approved_arguments?(request, capture) do
      {:allow, nil}
    else
      {:error, :fixture_policy_unavailable} -> {:deny, :policy_unavailable}
      _ -> {:deny, :policy_denied}
    end
  rescue
    _ -> {:deny, :policy_unavailable}
  end

  defp approved_arguments?(%{generation: {"loopex.bash", _, _}, arguments: args}, capture) do
    args == %{"argv" => capture.argv} or
      (capture.case_id == "m7.feature" and
         args in [
           %{"argv" => capture.argv ++ ["empty"]},
           %{"argv" => capture.argv ++ ["literal_null"]}
         ])
  end

  defp approved_arguments?(%{generation: {id, _, _}, arguments: %{"path" => path}}, capture)
       when id in ["loopex.write", "loopex.edit"] do
    paths =
      case capture.case_id do
        "m7.repair" -> ["lib/ledger.ex"]
        "m7.feature" -> ["lib/row_encoder.ex"]
        "m7.long" -> ["release.txt", "batches.txt"]
        "m7.review" -> []
        "m7.external" -> ["tools/threads.py"]
      end

    path in paths
  end

  defp approved_arguments?(_request, _capture), do: true

  defp tools_match?(%{resume_session_id: _, flags: _}, _capture), do: true

  defp tools_match?(invocation, capture),
    do: invocation.selection.profile["session"]["tools"] == capture.profile

  defp retain_pins(pins, selected_workspace, physical_workspace) do
    Enum.reduce_while(pins, {:ok, %{}}, fn {path, pin}, {:ok, retained} ->
      with {:ok, physical} <- WorkspaceIdentity.resolve_path(path),
           false <- inside?(Path.expand(path), selected_workspace),
           false <- inside?(physical, physical_workspace),
           retained_pin = Map.put(pin, :physical, physical),
           true <- matches?(path, retained_pin) do
        {:cont, {:ok, Map.put(retained, path, retained_pin)}}
      else
        _ -> {:halt, {:error, :fixture_policy_unavailable}}
      end
    end)
  end

  defp matches?(path, pin) do
    with {:ok, physical} <- WorkspaceIdentity.resolve_path(path),
         true <- physical == pin.physical,
         {:ok, %{type: :regular, mode: mode, size: size}} <- File.lstat(physical),
         true <- Bitwise.band(mode, 0o7777) == pin.mode and size <= 16_777_216,
         {:ok, bytes} <- File.read(physical) do
      Canonical.digest_bytes(bytes) == pin.sha256
    else
      _ -> false
    end
  end

  defp identity_for(capture),
    do: %{
      "id" => "m7.fixture:" <> capture.case_id <> ":" <> Canonical.digest(capture),
      "revision" => "1"
    }

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp executable?(mode), do: Bitwise.band(mode, 0o111) != 0

  defp text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4096 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp pin?(path, %{mode: mode, sha256: digest} = pin),
    do:
      map_size(pin) == 2 and text?(path) and Path.type(path) == :absolute and
        is_integer(mode) and mode in 0..0o777 and digest?(digest)

  defp pin?(_, _), do: false
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
