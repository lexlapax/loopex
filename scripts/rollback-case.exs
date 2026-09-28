# Concept: a pending public Ask-policy interaction survives a change from the
# released v0.2.0 runtime to the M6 candidate and back without changing its
# identity, expiry or tool effect count.
# Technical depth: the shell starts a fresh OS VM for each phase after both
# archives have acquired dependencies and compiled. This script uses only the
# shipped public composition, session and attachment facades.
defmodule LoopexRollbackCase do
  alias Loopex.Attachment

  def main([phase, state_root, workspace, launch_file, case_root, mode])
      when phase in ["writer", "reader"] do
    {:ok, _apps} = Application.ensure_all_started(:loopex_app_server)
    {:ok, [launch]} = :file.consult(String.to_charlist(launch_file))
    {:ok, runtime_id} = Loopex.runtime_placement_id(state_root)
    skill_option =
      if mode == "skill" and phase == "writer" do
        {:ok, %{manifest: manifest}} =
          apply(LoopexComposition.ResourcePacks, :read_directories, [
            [Path.join(case_root, "external/control")], [workspace: workspace]
          ])

        [resource_manifest: manifest]
      else
        []
      end

    options = [
      runtime_id: runtime_id,
      state_root: state_root,
      workspace: workspace,
      policy: if(mode == "skill", do: Loopex.AppServer.Policy.AllowAll, else: Loopex.AppServer.Policy.Ask),
      provider_launch: launch
    ] ++ skill_option ++ if(mode == "unknown-tool" and phase == "writer", do: [active_tools: ["loopex.read", "loopex.grep"]], else: [])

    result =
      LoopexComposition.with_runtime(options, fn runtime ->
        case phase do
          "writer" when mode == "skill" -> write_skill(runtime, case_root, runtime_id, Keyword.fetch!(options, :resource_manifest))
          "writer" -> write_question(runtime, case_root, mode, runtime_id)
          "reader" -> answer_question(runtime, case_root, mode)
        end
      end)

    :ok = result
    IO.puts("rollback-case: #{phase} proved and composition stopped")
  end

  def main(_arguments), do: fail("invalid case arguments")

  defp write_question(runtime, case_root, mode, runtime_id) do
    {:ok, session_id} =
      Loopex.create_session(runtime, %{}, command_id: "rollback-create")
    :ok = Loopex.track_session(Path.join(case_root, "state"), session_id, runtime_id)

    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
    {:accepted, "rollback-prompt"} =
      Loopex.command(attachment, %{
        type: :prompt,
        command_id: "rollback-prompt",
        content: if(mode == "unknown-tool", do: "rollback-grep notes.md", else: "Read notes.md and tell me what it contains"),
        bounds: %{deadline_ms: 600_000}
      })

    requested = await_event(attachment, "interaction.requested", 60_000)
    id = requested["interaction_id"]
    expires = requested["expires_at"]
    true = is_binary(id) and is_integer(expires)
    true = Enum.map(requested["choices"], & &1["id"]) == ["allow", "deny"]

    {:ok, status} = Loopex.session_status(runtime, session_id)
    true = status.open_interaction["interaction_id"] == id
    File.write!(Path.join(case_root, "session-id"), session_id)
    File.write!(Path.join(case_root, "interaction-id"), id)
    File.write!(Path.join(case_root, "expires-at"), Integer.to_string(expires))
    IO.puts("rollback-case: writer committed one pending interaction")
    :ok
  end

  defp write_skill(runtime, case_root, runtime_id, manifest) do
    {:ok, digest, normalized} = Loopex.ResourcePack.digest(manifest)
    [pack] = normalized["packs"]
    true = String.starts_with?(pack["source_id"], "user:")
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "rollback-skill-create")
    :ok = Loopex.track_session(Path.join(case_root, "state"), session_id, runtime_id)
    {:ok, attachment} = Loopex.attach(runtime, session_id)
    decision = %{
      manifest_digest: digest,
      workspace_ref: normalized["workspace_ref"],
      trust_scope: "project_skills",
      decision_source: "host_supplied",
      issued_at: "2026-09-27T00:00:00Z",
      expires_at: nil,
      revocation_state: "active"
    }
    {:accepted, "rollback-skill-admit"} =
      Loopex.command(attachment, %{
        type: :admit_resources, command_id: "rollback-skill-admit",
        manifest_digest: digest, decision: decision
      })
    {:accepted, "rollback-skill-activate"} =
      Loopex.command(attachment, %{
        type: :activate_skill, command_id: "rollback-skill-activate",
        manifest_digest: digest, source_id: pack["source_id"], name: pack["name"],
        pack_digest: Loopex.ResourcePack.pack_digest(pack), supporting_labels: []
      })
    {:ok, catalog} = Loopex.resource_catalog(runtime, session_id)
    true = catalog["admitted_manifest_digest"] == digest
    {:accepted, "rollback-skill-prompt"} =
      Loopex.command(attachment, %{
        type: :prompt, command_id: "rollback-skill-prompt",
        content: "skill-only: prove the admitted user skill context", bounds: %{deadline_ms: 60_000}
      })
    _finished = await_event(attachment, "run.finished", 60_000)
    File.write!(Path.join(case_root, "session-id"), session_id)
    File.write!(Path.join(case_root, "manifest-digest"), digest)
    File.write!(Path.join(case_root, "pack-digest"), Loopex.ResourcePack.pack_digest(pack))
    IO.puts("rollback-case: candidate retained and admitted #{pack["source_id"]}:#{pack["name"]}")
    :ok
  end

  defp answer_question(runtime, case_root, mode) do
    session_id = File.read!(Path.join(case_root, "session-id"))
    interaction_id = File.read!(Path.join(case_root, "interaction-id"))
    expires = case_root |> Path.join("expires-at") |> File.read!() |> String.to_integer()
    remaining = expires - System.system_time(:millisecond)
    true = remaining >= 120_000 || fail("less than 120000 ms interaction headroom")
    IO.puts("rollback-case: retained interaction headroom_ms=#{remaining}")

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(runtime, session_id, "rollback-resume")

    {:ok, attachment} = Loopex.attach(runtime, session_id)
    open = Attachment.open_interaction(attachment)
    true = is_map(open) and open["interaction_id"] == interaction_id
    true = open["status"] == "pending"
    {:ok, replay} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
    {:ok, ^session_id} = Loopex.activate_resume(activation)

    {:accepted, "rollback-answer"} =
      Loopex.command(attachment, %{
        type: :interaction_answer,
        command_id: "rollback-answer",
        interaction_id: interaction_id,
        choice_id: "allow"
      })

    true = System.system_time(:millisecond) < expires || fail("answer missed retained expiry")
    events = collect_until_finished(replay, runtime, session_id, 60_000, [])
    resolved = Enum.filter(events, &(&1.kind == "interaction.resolved"))
    tools = Enum.filter(events, &(&1.kind == "tool.finished"))
    finished = Enum.filter(events, &(&1.kind == "run.finished"))
    true = length(resolved) == 1 and hd(resolved)["interaction_id"] == interaction_id
    true = hd(resolved)["choice_id"] == "allow"
    expected_tool = if(mode == "unknown-tool", do: "failed", else: "completed")
    true = length(tools) == if(mode == "unknown-tool", do: 2, else: 1)
    if mode == "unknown-tool" do
      true = Enum.map(tools, & &1["outcome"]) == ["completed", expected_tool]
      true = String.contains?(inspect(List.last(tools)), "unknown_tool")
      started = Enum.filter(events, &(&1.kind == "tool.started"))
      true = length(started) == 1
      true = Enum.all?(started, &(&1["tool_call_id"] != "rollback-grep-1"))
    else
      true = hd(tools)["outcome"] == expected_tool
    end
    true = length(finished) == 1 and hd(finished)["outcome"] == "completed"
    IO.puts("rollback-case: reader committed answer, one tool and completed run")
    :ok
  end

  defp await_event(attachment, kind, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_event_until(attachment, kind, deadline, [])
  end

  defp await_event_until(attachment, kind, deadline, seen) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} -> event
      {:ok, %{kind: "run.finished"} = event} ->
        fail("run finished before #{kind}: outcome=#{event["outcome"]}; event kinds #{inspect(Enum.reverse(seen))}")
      {:ok, event} -> await_event_until(attachment, kind, deadline, [event.kind | seen])
      _empty ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          await_event_until(attachment, kind, deadline, seen)
        else
          fail("missing #{kind}; event kinds #{inspect(Enum.reverse(seen))}")
        end
    end
  end

  defp collect_until_finished(attachment, runtime, session_id, timeout, events) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_until(attachment, runtime, session_id, deadline, events)
  end

  defp collect_until(attachment, runtime, session_id, deadline, events) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} -> Enum.reverse([event | events])
      {:ok, event} -> collect_until(attachment, runtime, session_id, deadline, [event | events])
      _empty ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          collect_until(attachment, runtime, session_id, deadline, events)
        else
          {:ok, status} = Loopex.session_status(runtime, session_id)
          kinds = Enum.map(Enum.reverse(events), &{&1.kind, &1["outcome"]})
          fail("run did not finish; events=#{inspect(kinds)} active=#{inspect(status.active_run_id)} pending=#{inspect(status.pending_work_ids)}")
        end
    end
  end

  defp fail(message), do: raise("rollback-case: " <> message)
end

LoopexRollbackCase.main(System.argv())
