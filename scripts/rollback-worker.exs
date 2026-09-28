# Concept: this release fixture speaks the released provider channel in its
# own operating-system process. It never contacts a hosted provider.
# Technical depth: each archive supplies its own locked ProviderCodec beam;
# the build wrapper adds only that archive's compiled ebin paths. The fixture
# checks the inert credential frame after readiness and emits one history-
# sensitive tool call, then a final reply only after tool context returns.
defmodule LoopexRollbackWorker do
  alias Loopex.LLM.ReqLLM.ProviderCodec

  @inert "loopex-rollback-inert-not-a-provider-key"

  def main([path, nonce, manifest_digest, deadline_bytes]) do
    deadline = String.to_integer(deadline_bytes)
    true = deadline > System.system_time(:millisecond)

    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 5_000)

    bootstrap = %{
      "nonce" => nonce,
      "version" => ProviderCodec.version(),
      "build_manifest_sha256" => manifest_digest
    }

    {:ok, :bootstrap, ^bootstrap} = ProviderCodec.recv(socket, left(deadline))
    :ok = ProviderCodec.send(socket, :ready, bootstrap)
    {:ok, :credential, %{"nonce" => ^nonce, "credential" => @inert}} =
      ProviderCodec.recv(socket, left(deadline))

    {:ok, :invocation, invocation} = ProviderCodec.recv(socket, left(deadline))
    ^nonce = invocation["nonce"]
    digest = invocation["staged_request_digest"]

    :ok =
      ProviderCodec.send(socket, :dispatch_started, %{
        "nonce" => nonce,
        "staged_request_digest" => digest
      })

    request = invocation["request"]
    messages = Map.get(request, :messages, Map.get(request, "messages", []))
    completed_tool? =
      Enum.any?(messages, fn message ->
        role = Map.get(message, :role, Map.get(message, "role"))
        role in ["tool", :tool]
      end)
    grep_case? = Enum.any?(messages, &String.contains?(inspect(&1), "rollback-grep"))
    skill_case? = Enum.any?(messages, &String.contains?(inspect(&1), "skill-only"))
    withheld_case? = Enum.any?(messages, &String.contains?(inspect(&1), "daemon-withheld"))
    if skill_case? and not String.contains?(inspect(messages), "Rollback user skill marker.") do
      raise "admitted user skill context was not staged"
    end
    if withheld_case? and (String.contains?(inspect(messages), "Rollback user skill marker.") or
      String.contains?(inspect(messages), "Project skill control.")) do
      raise "daemon staged skill context against a mismatched admitted digest"
    end

    calls =
      cond do
        skill_case? or withheld_case? ->
          []

        completed_tool? ->
          []

        grep_case? ->
          [
            %{id: "rollback-read-1", name: "read", arguments: %{"path" => "notes.md"}},
            %{id: "rollback-grep-1", name: "grep", arguments: %{"path" => "notes.md", "pattern" => "rollback"}}
          ]

        true ->
          [%{id: "rollback-read-1", name: "read", arguments: %{"path" => "notes.md"}}]
      end

    reply = %{
      canonical_request_bytes: invocation["canonical_request_bytes"],
      staged_request_digest: digest,
      text: if(completed_tool?, do: "rollback complete", else: "reading notes"),
      identity: %{provider: "fixture", model: "scripted:v1", endpoint: "local"},
      usage: %{input_tokens: 1, output_tokens: 1},
      tool_calls: calls,
      delta_count: 0,
      streamed: false,
      provider_response_id: nil
    }

    :ok =
      ProviderCodec.send(socket, :terminal, %{
        "nonce" => nonce,
        "staged_request_digest" => digest,
        "status" => "reply",
        "reply" => reply
      })

    :gen_tcp.close(socket)
    :ok
  end

  def main(_args), do: System.halt(70)

  defp left(deadline), do: max(deadline - System.system_time(:millisecond), 1)

end

try do
  LoopexRollbackWorker.main(System.argv())
rescue
  _ -> System.halt(70)
catch
  _, _ -> System.halt(70)
end
