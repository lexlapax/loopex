# A released generation-two client asks the released daemon to recover the
# candidate user-skill session, then proves its external tuple is unavailable.
defmodule LoopexRollbackDaemonClient do
  alias LoopexCli.DaemonClient
  alias LoopexProtocol.Wire

  def main([socket, case_root]) do
    session = case_root |> Path.join("session-id") |> File.read!() |> Wire.encode_identity()
    digest = case_root |> Path.join("manifest-digest") |> File.read!()
    pack_digest = case_root |> Path.join("pack-digest") |> File.read!()
    {:ok, client} = DaemonClient.connect(socket)
    {:ok, %{"result" => %{"writer_epoch" => epoch}}, client} =
      DaemonClient.request(client, "session.acquire_control", %{"session_id" => session})
    {:ok, %{"status" => "accepted"}, client} =
      DaemonClient.request(client, "session.resume", %{
        "session_id" => session,
        "command_id" => Wire.encode_identity("rollback-daemon-resume"),
        "writer_epoch" => epoch
      })
    {:ok, %{"type" => "snapshot"}, client} =
      DaemonClient.request(client, "session.attach", %{"session_id" => session})
    # A recovered user admission and the daemon's project-only composition
    # have different digests. Neither can authorize a new selection here.
    {:ok, refusal, client} =
      DaemonClient.request(client, "session.activate_skill", %{
        "command_id" => Wire.encode_identity("rollback-daemon-user-skill"),
        "writer_epoch" => epoch,
        "manifest_digest" => digest,
        "pack_digest" => pack_digest,
        "source_id" => "user:control",
        "name" => "control",
        "supporting_labels" => []
      })
    true = refusal["reason"] == "resource_binding_changed" ||
      raise("daemon did not withhold recovered user-skill binding: #{inspect(refusal)}")
    {:ok, %{"status" => "accepted"}, client} =
      DaemonClient.request(client, "session.prompt", %{
        "command_id" => Wire.encode_identity("rollback-daemon-withheld"),
        "content_b64" => Wire.encode_bytes("daemon-withheld: answer without any skill context"),
        "writer_epoch" => epoch
      })
    await_finished(client, System.monotonic_time(:millisecond) + 60_000, [])
    DaemonClient.close(client)
    IO.puts("rollback: released daemon withheld both user and project context on resumed session")

    prove_new_discovery(socket, case_root)
  end

  defp prove_new_discovery(socket, case_root) do
    workspace = Path.join(case_root, "workspace")
    state_root = Path.join(case_root, "state")
    {:ok, workspace_ref} = LoopexComposition.ProjectResources.workspace_reference(workspace)
    {:ok, manifest} = LoopexComposition.ResourcePacks.discover(workspace,
      workspace_ref: workspace_ref, state_root: state_root)
    {:ok, digest, normalized} = Loopex.ResourcePack.digest(manifest)
    [project] = normalized["packs"]
    {:ok, client} = DaemonClient.connect(socket)
    {:ok, %{"status" => "accepted", "session_id" => new_session}, client} =
      DaemonClient.request(client, "session.create", %{
        "command_id" => Wire.encode_identity("rollback-daemon-create"),
        "session_options" => %{}
      })
    {:ok, %{"result" => %{"writer_epoch" => epoch}}, client} =
      DaemonClient.request(client, "session.acquire_control", %{"session_id" => new_session})
    {:ok, %{"type" => "snapshot"}, client} =
      DaemonClient.request(client, "session.attach", %{"session_id" => new_session})
    decision = %{
      "manifest_digest" => digest, "workspace_ref" => workspace_ref,
      "trust_scope" => "project_skills", "decision_source" => "host_supplied",
      "issued_at" => "2026-09-27T00:00:00Z", "expires_at" => nil,
      "revocation_state" => "active"
    }
    {:ok, %{"status" => "accepted"}, client} =
      DaemonClient.request(client, "session.admit_resources", %{
        "command_id" => Wire.encode_identity("rollback-daemon-admit"),
        "writer_epoch" => epoch, "manifest_digest" => digest,
        "decision" => decision
      })
    activation = %{
      "writer_epoch" => epoch, "manifest_digest" => digest,
      "pack_digest" => Loopex.ResourcePack.pack_digest(project),
      "name" => project["name"], "supporting_labels" => []
    }
    {:ok, %{"status" => "accepted"}, client} =
      DaemonClient.request(client, "session.activate_skill",
        Map.merge(activation, %{
          "command_id" => Wire.encode_identity("rollback-daemon-project"),
          "source_id" => project["source_id"]
        }))
    {:ok, refusal, client} =
      DaemonClient.request(client, "session.activate_skill",
        Map.merge(activation, %{
          "command_id" => Wire.encode_identity("rollback-daemon-external"),
          "source_id" => "user:control"
        }))
    true = refusal["reason"] == "resource_not_found" ||
      raise("daemon external tuple was not resource_not_found: #{inspect(refusal)}")
    DaemonClient.close(client)
    IO.puts("rollback: released daemon accepted project control and refused fresh external tuple")
  end

  defp await_finished(client, deadline, seen) do
    receive do
      {:loopex_daemon_record, reader, %{"event" => %{"kind" => "run.finished", "data" => %{"outcome" => "completed"}}}}
        when reader == client.reader -> :ok
      {:loopex_daemon_record, reader, %{"event" => %{"kind" => "run.finished"}} = record}
        when reader == client.reader -> raise("daemon run did not complete: #{inspect(record)}")
      {:loopex_daemon_record, reader, record} when reader == client.reader ->
        summary = {record["type"], get_in(record, ["event", "kind"]), get_in(record, ["event", "data", "outcome"])}
        await_finished(client, deadline, [summary | seen])
    after
      100 ->
        if System.monotonic_time(:millisecond) < deadline,
          do: await_finished(client, deadline, seen),
          else: raise("daemon resumed run did not complete; records=#{inspect(Enum.reverse(seen))}")
    end
  end
end

LoopexRollbackDaemonClient.main(System.argv())
