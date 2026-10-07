defmodule LoopexCli.M7FixtureChat do
  @moduledoc """
  ## Concept

  Prepare the trusted M7 fixture policy after ordinary conversation settings
  validate. This internal host join starts no conversation or provider attempt.

  ## Technical depth

  The source catalog owner returns its exact decoded bytes and digest. The
  existing policy owner renders one fixed oracle runner from the hosting
  toolchain. The harness supplies retained files and pins, never command text
  or argv. Expected runner, oracle and manifest digests must match those pins;
  the policy owner then checks physical paths, modes and bytes and binds the
  capture to the ordinary invocation. Campaign admission and dispatch remain
  separate host obligations. The return is private preparation data, not an
  admission token or a public configuration boundary.
  """

  alias LoopexCli.{ChatConfiguration, ConfigOptions}
  alias LoopexCli.Policy.M7Fixture
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexProtocol.Canonical
  alias Mix.Tasks.Loopex.M7Evidence.FixtureManifest

  @keys [:case_id, :catalog_root, :workspace, :runner, :oracle, :environment, :pins]
  @cases ~w(m7.repair m7.feature m7.review m7.long)

  @doc false
  def prepare(argv, cwd, home, fixture) do
    with {:ok, invocation} <- load(argv, cwd, home) do
      prepare_fixture(invocation, fixture)
    end
  end

  defp load(argv, cwd, home) do
    case ConfigOptions.parse(argv) do
      {:ok, %{command: :chat, resume: session}} when is_binary(session) ->
        ChatConfiguration.load_resume(argv, cwd, home)

      {:ok, %{command: :chat}} ->
        ChatConfiguration.load(argv, cwd, home)

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_chat_invocation}
    end
  end

  defp prepare_fixture(invocation, fixture) do
    with true <- is_map(fixture) and Enum.sort(Map.keys(fixture)) == Enum.sort(@keys),
         true <- fixture.case_id in @cases,
         true <-
           Enum.all?(
             [fixture.catalog_root, fixture.workspace, fixture.runner, fixture.oracle],
             &absolute?/1
           ),
         {:ok, workspace} <- WorkspaceIdentity.resolve_path(fixture.workspace),
         {:ok, runner} <- WorkspaceIdentity.resolve_path(fixture.runner),
         {:ok, oracle} <- WorkspaceIdentity.resolve_path(fixture.oracle),
         {:ok, catalog} <- FixtureManifest.load(fixture.catalog_root),
         name = String.replace_prefix(fixture.case_id, "m7.", ""),
         entry = catalog.catalog["fixtures"][name],
         :ok <- FixtureManifest.verify_workspace(entry, workspace),
         :ok <- FixtureManifest.verify_oracle(entry, fixture.catalog_root),
         {:ok, recipe} <-
           M7Fixture.oracle_runner(fixture.case_id, workspace, oracle, fixture.environment),
         true <- pins_match?(fixture.pins, fixture, catalog, entry, recipe),
         {:ok, capture} <-
           M7Fixture.prepare(
             fixture.case_id,
             catalog.digest,
             fixture.workspace,
             ["/bin/sh", fixture.runner],
             fixture.pins
           ),
         true <- runner_matches?(runner, recipe.bytes),
         {:ok, bound} <- M7Fixture.bind(invocation, capture) do
      {:ok, %{invocation: bound, capture: capture}}
    else
      _ -> {:error, :fixture_preparation_unavailable}
    end
  rescue
    _ -> {:error, :fixture_preparation_unavailable}
  end

  defp pins_match?(pins, fixture, catalog, entry, recipe) do
    paths = [
      "/bin/sh",
      "/usr/bin/env",
      recipe.elixir,
      fixture.runner,
      fixture.oracle,
      catalog.path
    ]

    is_map(pins) and Enum.sort(Map.keys(pins)) == Enum.sort(paths) and
      pins[fixture.runner] == %{mode: 0o644, sha256: Canonical.digest_bytes(recipe.bytes)} and
      pins[fixture.oracle] == %{
        mode: entry["oracle"]["mode"],
        sha256: entry["oracle"]["sha256"]
      } and
      is_map(pins[catalog.path]) and pins[catalog.path][:sha256] == catalog.digest
  end

  defp runner_matches?(path, bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          IO.binread(io, byte_size(bytes) + 1) == bytes
        after
          File.close(io)
        end

      _ ->
        false
    end
  end

  defp absolute?(path),
    do:
      is_binary(path) and byte_size(path) in 1..4096 and String.valid?(path) and
        not String.contains?(path, <<0>>) and Path.type(path) == :absolute
end
