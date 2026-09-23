Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

# The shared provider fixture's runtime helper refuses to load without an
# isolated home; this suite supplies a temporary one rather than a real one.
unless System.get_env("LOOPEX_HOME") do
  home = Path.join(System.tmp_dir!(), "ldt-home-#{System.unique_integer([:positive])}")
  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexDaemon.TelemetryParityTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture, only: [send_frame: 2, receive_records: 2]

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.{Session.V2, Wire}

  @credential "telemetry-parity-placeholder"

  # ADR 0030's closed inventory: five port callbacks and six coordinator cuts.
  @inventory [
    [:model, :complete],
    [:store, :transact],
    [:store, :transaction_status],
    [:store, :runtime_command],
    [:store, :ownership_head],
    [:store, :load_records],
    [:store, :load_events],
    [:artifact, :put],
    [:artifact, :fetch],
    [:artifact, :stat],
    [:artifact, :describe],
    [:artifact, :open_transfer],
    [:artifact, :read_transfer],
    [:artifact, :close_transfer],
    [:executor, :execute],
    [:executor, :cancel],
    [:executor, :retained_receipt],
    [:policy, :decide],
    [:command, :admit],
    [:commit],
    [:effect, :intent],
    [:events, :publish],
    [:interaction],
    [:artifact, :transfer]
  ]

  # The first decision defers to a person; an answer of `allow` re-enters the
  # policy and allows, so the workflow crosses the interaction cut.
  defmodule AskingPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(request) do
      case Map.get(request, :interaction_response) do
        %{answer: %{choice_id: "allow"}} ->
          {:allow, nil}

        _none ->
          {:defer,
           %{
             kind: :choice,
             prompt: "May the tool read the file?",
             choices: [%{id: "allow", label: "Allow once"}, %{id: "deny", label: "Deny"}],
             expires_in_ms: 60_000
           }}
      end
    end
  end

  # Concept: the daemon is a host above core's ports, not a new boundary, so a
  # session driven through its socket emits the same ADR 0030 spans, carrying
  # the same identity metadata, as the same session driven by an embedded
  # caller — and the daemon adds no event of its own.
  #
  # Technical depth: one scripted provider turn (a `read` tool call the host
  # policy defers to a person, an `allow` answer, then a final answer) runs once through a daemon over its socket and once through
  # `LoopexComposition.with_runtime/2`. Handlers on every inventory stop event
  # record each span's name and metadata keys. Every span name the embedded run
  # emits must appear in the daemon run with exactly the same metadata key
  # sets, the cuts and ports this workflow reaches must be among them, and
  # neither the daemon nor the CLI source makes a telemetry call of its own.
  @tag timeout: 180_000
  test "a session driven over the socket emits the embedded caller's spans and metadata" do
    daemon = collect(fn -> daemon_run() end)
    embedded = collect(fn -> embedded_run() end)

    for name <- [
          [:command, :admit],
          [:commit],
          [:effect, :intent],
          [:events, :publish],
          [:model, :complete],
          [:policy, :decide],
          [:executor, :execute],
          [:store, :transact],
          [:interaction]
        ] do
      assert Map.has_key?(embedded, name), "embedded run emitted no #{inspect(name)} span"
      assert Map.has_key?(daemon, name), "daemon run emitted no #{inspect(name)} span"
    end

    for {name, key_sets} <- embedded do
      assert Map.get(daemon, name) == key_sets,
             "#{inspect(name)} metadata differs: daemon #{inspect(Map.get(daemon, name))}, " <>
               "embedded #{inspect(key_sets)}"
    end

    for app <- ["loopex_daemon", "loopex_cli"],
        path <- Path.wildcard(Path.join([__DIR__, "..", "..", app, "lib", "**", "*.ex"])) do
      refute File.read!(path) =~ ~r/:telemetry\.(execute|span|attach)/,
             "#{path} emits or handles telemetry outside ADR 0030's inventory"
    end
  end

  # Concept: the daemon's history is the root's history: after an orderly
  # stop, an offline host reopening the same root replays exactly the durable
  # events the daemon's clients saw, with the same sequences and identities.
  #
  # Technical depth: every durable event record a socket client received during
  # one scripted turn is kept; after `SIGTERM` the root's Store is opened by a
  # fresh embedded runtime under the daemon's placement identity, which resumes
  # the session; replay from sequence zero begins with exactly the same kinds,
  # sequences and event identities.
  @tag timeout: 180_000
  test "after an orderly stop the root replays what the daemon's clients saw" do
    root = workspace_root("ldt-replay")
    provider = provider("replay")
    socket = Path.join([root, "s", "daemon", "d.sock"])
    options = [state_root: Path.join(root, "s"), socket_path: socket, credential: @credential]
    options = options ++ host_options(root, provider)
    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 1_000)
    {:ok, client} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(client, %{family: :local, path: socket})
    {encoded, epoch} = drive(client)
    before_answer = events_until_question(client, epoch, [])
    seen = before_answer ++ events_until_finished(client, [])
    :socket.close(client)
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 60_000) == 0

    {:ok, session_id} = Wire.identity(encoded)
    {:ok, placement} = Loopex.runtime_placement_id(Path.join(root, "s"))
    {:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join([root, "s", "store.log"]))
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: placement, store: store, context_token_budget: 8_192)

    {:ok, _resumed} = Loopex.resume_session(runtime, session_id, command_id: "replay-resume")
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
    replayed = attachment |> drain_events([]) |> Enum.take(length(seen))

    assert Enum.map(replayed, &{&1.kind, &1.event_sequence, &1.event_id}) ==
             Enum.map(seen, fn event ->
               {:ok, event_id} = Wire.identity(event["event_id"])
               {event["kind"], String.to_integer(event["event_sequence"]), event_id}
             end)

    :ok = Loopex.stop(runtime)
    :ok = GenServer.stop(adapter)
  end

  # Keeps every durable event up to the interaction's question, answers it,
  # and returns those events in order.
  defp events_until_question(socket, epoch, acc) do
    [record] = receive_records(socket, 1)

    case record do
      %{"type" => "event", "event" => %{"kind" => "interaction.requested"} = event} ->
        :ok =
          send_frame(socket, %{
            "method" => "session.respond_interaction",
            "request_id" => "answer",
            "command_id" => Wire.encode_identity("parity-answer"),
            "interaction_id" => Wire.encode_identity(find_key(event, "interaction_id")),
            "answer" => %{"choice_id" => Wire.encode_identity("allow")},
            "writer_epoch" => epoch
          })

        Enum.reverse([event | acc])

      %{"type" => "event", "event" => event} ->
        events_until_question(socket, epoch, [event | acc])

      _other ->
        events_until_question(socket, epoch, acc)
    end
  end

  defp events_until_finished(socket, acc) do
    [record] = receive_records(socket, 1)

    case record do
      %{"type" => "event", "event" => %{"kind" => "run.finished"} = event} ->
        Enum.reverse([event | acc])

      %{"type" => "event", "event" => event} ->
        events_until_finished(socket, [event | acc])

      _other ->
        events_until_finished(socket, acc)
    end
  end

  defp drain_events(attachment, acc) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain_events(attachment, [event | acc])
      _none -> Enum.reverse(acc)
    end
  end

  defp collect(run) do
    handler = {__MODULE__, make_ref()}
    parent = self()
    events = for name <- @inventory, do: [:loopex | name] ++ [:stop]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn [:loopex | rest], _measurements, metadata, _config ->
          send(parent, {:parity_span, Enum.drop(rest, -1), metadata |> Map.keys() |> Enum.sort()})
        end,
        nil
      )

    try do
      run.()
    after
      :telemetry.detach(handler)
    end

    drain(%{})
  end

  defp drain(acc) do
    receive do
      {:parity_span, name, keys} ->
        drain(Map.update(acc, name, MapSet.new([keys]), &MapSet.put(&1, keys)))
    after
      0 -> acc
    end
  end

  defp daemon_run do
    root = workspace_root("ldt-daemon")
    provider = provider("daemon")
    socket = Path.join([root, "s", "daemon", "d.sock"])

    options =
      [
        state_root: Path.join(root, "s"),
        socket_path: socket,
        credential: @credential
      ] ++ host_options(root, provider)

    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 1_000)

    {:ok, client} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(client, %{family: :local, path: socket})
    {_encoded, epoch} = drive(client)
    answer_over_socket(client, epoch)
    records_until_finished(client)
    :socket.close(client)

    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 60_000) == 0
  end

  defp embedded_run do
    root = workspace_root("ldt-embedded")
    provider = provider("embedded")
    variable = ReqLLM.credential_variable()
    System.put_env(variable, @credential)

    try do
      options =
        [runtime_id: "telemetry-parity-embedded", state_root: Path.join(root, "s")] ++
          host_options(root, provider)

      LoopexComposition.with_runtime(options, fn runtime ->
        {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "parity-create")
        {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

        {:accepted, "parity-prompt"} =
          Loopex.command(attachment, %{
            type: :prompt,
            command_id: "parity-prompt",
            content: "read note.txt"
          })

        deadline = System.monotonic_time(:millisecond) + 60_000
        interaction_id = await_interaction(attachment, deadline)

        {:accepted, "parity-answer"} =
          Loopex.command(attachment, %{
            type: :interaction_answer,
            command_id: "parity-answer",
            interaction_id: interaction_id,
            choice_id: "allow"
          })

        await_finished(attachment, deadline)
      end)
    after
      System.delete_env(variable)
    end
  end

  defp host_options(root, provider) do
    [
      workspace: Path.join(root, "w"),
      policy: AskingPolicy,
      provider_launch:
        Keyword.drop(provider.options, [
          :credential_token,
          :credential_registry,
          :tracing_capability
        ])
    ]
  end

  defp workspace_root(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "w"))
    File.write!(Path.join([root, "w", "note.txt"]), "parity\n")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp provider(label) do
    ProviderFixture.new(:reply,
      credential: @credential,
      response_bodies: [
        tool_response("note.txt", "msg_#{label}_tool"),
        text_response("read it", "msg_#{label}_done")
      ]
    )
  end

  defp await_finished(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :finished

      {:ok, _event} ->
        await_finished(attachment, deadline)

      _none ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("the embedded run did not finish"),
          else: Process.sleep(10)

        await_finished(attachment, deadline)
    end
  end

  defp drive(socket) do
    :ok =
      send_frame(socket, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    [%{"type" => "initialized"}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("parity-create"),
        "session_options" => %{}
      })

    [%{"status" => "accepted", "session_id" => encoded}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => encoded,
        "after_event_sequence" => "0"
      })

    [%{"type" => "snapshot"}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("parity-prompt"),
        "content_b64" => Wire.encode_bytes("read note.txt"),
        "writer_epoch" => epoch
      })

    {encoded, epoch}
  end

  defp answer_over_socket(socket, epoch) do
    [record] = receive_records(socket, 1)

    case record do
      %{"type" => "event", "event" => %{"kind" => "interaction.requested"} = event} ->
        :ok =
          send_frame(socket, %{
            "method" => "session.respond_interaction",
            "request_id" => "answer",
            "command_id" => Wire.encode_identity("parity-answer"),
            "interaction_id" => Wire.encode_identity(find_key(event, "interaction_id")),
            "answer" => %{"choice_id" => Wire.encode_identity("allow")},
            "writer_epoch" => epoch
          })

      _other ->
        answer_over_socket(socket, epoch)
    end
  end

  defp await_interaction(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "interaction.requested"} = event} ->
        find_key(event, "interaction_id")

      {:ok, _event} ->
        await_interaction(attachment, deadline)

      _none ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("the embedded run asked no question"),
          else: Process.sleep(10)

        await_interaction(attachment, deadline)
    end
  end

  # The interaction identity sits in the event's own data, whose nesting
  # differs between the embedded event and its wire rendering.
  defp find_key(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        value

      _absent ->
        map
        |> Map.values()
        |> Enum.find_value(&find_key(&1, key))
    end
  end

  defp find_key(_value, _key), do: nil

  defp records_until_finished(socket) do
    [record] = receive_records(socket, 1)

    unless match?(%{"type" => "event", "event" => %{"kind" => "run.finished"}}, record),
      do: records_until_finished(socket)
  end

  defp await_ready(output, attempts) when attempts > 0 do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        :ok

      _empty ->
        Process.sleep(10)
        await_ready(output, attempts - 1)
    end
  end

  defp await_ready(_output, 0), do: flunk("daemon never announced readiness")

  defp tool_response(path, response_id) do
    sse([
      message_start(response_id),
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "call_read",
          "name" => "read",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => Jason.encode!(%{"path" => path})
        }
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 12}
      },
      %{"type" => "message_stop"}
    ])
  end

  defp text_response(text, response_id) do
    sse([
      message_start(response_id),
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 4}
      },
      %{"type" => "message_stop"}
    ])
  end

  defp message_start(response_id) do
    %{
      "type" => "message_start",
      "message" => %{
        "id" => response_id,
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-haiku-4-5",
        "content" => [],
        "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
      }
    }
  end

  defp sse(events),
    do: Enum.map_join(events, "", &"event: #{&1["type"]}\ndata: #{Jason.encode!(&1)}\n\n")
end
