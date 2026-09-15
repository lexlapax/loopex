defmodule Loopex.AppServer.ExternalWorkflowTest do
  @moduledoc """
  ## Concept

  An independent client, written in another language and running in its own
  process, completes a whole session against the shipped server: it negotiates,
  creates, attaches, prompts, follows the durable events to the end of the run,
  reads the session back, survives a refusal, and leaves cleanly.

  ## Technical depth

  This is outcome 5's unattended half. Nothing about the client is Elixir: it
  speaks bytes over a pipe and reports only what it could observe through the
  protocol, so the evidence is what a real consumer can see rather than what the
  server happens to log. The client's summary is asserted here, which is why it
  prints one and why every member of it is something a record carried.

  The attended real-provider demonstration outcome 5 also names is the
  maintainer's to perform. It spends a provider key and needs a person watching,
  so it is deliberately not simulated here; the model behind this server is
  scripted and says so.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  test "an independent client completes a session over the wire and reports what it saw" do
    node_executable = System.find_executable("node")

    if is_nil(node_executable) do
      flunk("Node is required for the independent client workflow and was not found")
    end

    {output, status} =
      System.cmd(
        node_executable,
        [
          client("workflow.mjs"),
          System.find_executable("elixir") || flunk("Elixir executable unavailable"),
          ebin(:loopex_protocol),
          ebin(:loopex),
          ebin(:loopex_app_server),
          ebin(:telemetry)
        ] ++ require_paths(),
        env: child_environment(),
        stderr_to_stdout: false
      )

    assert status == 0, "the independent client failed: #{output}"

    summary = decode(output)

    refute Map.has_key?(summary, "failed"), "the client reported: #{summary["failed"]}"

    # It negotiated the contract it was written against, by digest.
    assert summary["generation"] == LoopexProtocol.Session.generation()
    assert summary["schema_digest"] == LoopexProtocol.Session.schema_digest()
    assert summary["method_count"] == 16
    assert summary["frame_bytes"] == 1_048_576

    # It created a session and received back the identity it sent.
    assert summary["session_created"]
    assert summary["command_id_returned"] == "client-create"

    # It attached and was given the exact snapshot members.
    assert summary["snapshot_members"] == [
             "active_run_id",
             "active_run_phase",
             "event_sequence",
             "session_id",
             "snapshot_revision"
           ]

    # It prompted, and followed durable events to the end of the run.
    assert summary["prompt_accepted"]
    assert is_binary(summary["run_finished_sequence"])
    assert "run.finished" in summary["event_kinds"]
    assert "user.message_appended" in summary["event_kinds"]
    assert summary["sequences_ordered"]

    # It read the session back and saw the public projection only.
    assert summary["inspect_members"] == [
             "active_context_token_budget",
             "active_run_id",
             "cleanup_grace_ms",
             "event_sequence",
             "open_interaction",
             "pending_work_ids",
             "status"
           ]

    assert summary["event_sequence_is_string"]

    # A refusal did not cost it the connection.
    assert summary["unknown_method_code"] == "unsupported_method"
    assert summary["survived_refusal"]
  end

  test "the client library and workflow are plain source with no package manifest" do
    for name <- ["loopex-client.mjs", "workflow.mjs"] do
      assert File.regular?(client(name))
    end

    directory = Path.dirname(client("workflow.mjs"))

    # The maintainer chose a client with no second package manager, so there is
    # nothing here to install and nothing to lock.
    refute File.exists?(Path.join(directory, "package.json"))
    refute File.exists?(Path.join(directory, "package-lock.json"))
    refute File.exists?(Path.join(directory, "node_modules"))

    # And nothing it imports comes from outside Node itself or this directory.
    source = File.read!(client("loopex-client.mjs")) <> File.read!(client("workflow.mjs"))

    imports =
      Regex.scan(~r/from "([^"]+)"/, source)
      |> Enum.map(fn [_whole, target] -> target end)
      |> Enum.uniq()

    assert Enum.all?(imports, fn target ->
             String.starts_with?(target, "node:") or String.starts_with?(target, "./")
           end),
           "unexpected imports: #{inspect(imports)}"
  end

  defp client(name), do: Path.join([repository_root(), "clients", "node", name])

  defp repository_root do
    File.cwd!() |> Path.join("../..") |> Path.expand()
  end

  defp ebin(application) do
    path = Application.app_dir(application, "ebin")
    assert File.dir?(path)
    path
  end

  # Concept: the environment the server child runs under.
  #
  # Technical depth: a fresh isolated state root per run, and the helper files
  # required before the entry point so the fixture's own modules exist when it
  # is called. The state root is passed rather than inherited, because a server
  # that fell back to real user state would be a far worse failure than a test
  # that could not start.
  defp child_environment do
    root = Path.join(System.tmp_dir!(), "loopex-workflow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "home"))
    File.mkdir_p!(Path.join(root, "workspace"))
    on_exit(fn -> File.rm_rf(root) end)

    [
      {"LOOPEX_HOME", Path.join(root, "home")},
      {"LOOPEX_WORKSPACE", Path.join(root, "workspace")},
      {"ELIXIR_ERL_OPTIONS", "-noinput"}
    ]
  end

  defp require_paths do
    support = Path.join([repository_root(), "apps", "loopex", "test", "support"])
    own = Path.join([repository_root(), "apps", "loopex_app_server", "test", "support"])

    [
      Path.join(support, "m1_runtime_helper.exs"),
      Path.join(support, "agent_loop_helper.exs"),
      Path.join(own, "fixture_server.exs")
    ]
  end

  # Concept: the client's own summary line, read with this protocol's decoder.
  #
  # Technical depth: decoded by the same decoder the server uses, because the
  # repository carries no JSON library and because the summary is one bounded
  # object like every other record on this wire.
  defp decode(output) do
    {:ok, decoded} =
      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> LoopexProtocol.Frame.decode(2_097_152)

    decoded
  end
end
