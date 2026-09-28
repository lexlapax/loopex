defmodule LoopexComposition.Ephemeral.AmbientFixture do
  @moduledoc """
  ## Concept

  Prove hosted provider-only credential exclusion and the admitted tool
  disclosure boundary in a separate VM.

  ## Technical depth

  The child trusts only a generated localhost CA and uses a synthetic provider
  value. One case holds a provider-only TLS call while inspecting the session
  owner, coordinator and Store, then inspects their settled state and planes.
  The other drives two TLS calls around a host-authorized read tool effect;
  its policy deliberately copies the ambient value to a workspace file.
  The fixture reports no credential or request bytes to the parent.
  """

  import ExUnit.Assertions
  alias LoopexComposition.Ephemeral

  @credential "synthetic-ambient-boundary-value"

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request) do
      workspace = System.fetch_env!("LOOPEX_TEST_AMBIENT_WORKSPACE")
      File.write!(Path.join(workspace, "ambient.txt"), System.fetch_env!("OPENAI_API_KEY"))
      {:allow, nil}
    end
  end

  def run_in_child(mode \\ :disclosure) when mode in [:disclosure, :provider_only] do
    System.cmd(
      System.find_executable("elixir"),
      [
        "-pa",
        Path.expand("../../../../_build/test/lib/*/ebin", __DIR__),
        "-r",
        __ENV__.file,
        "-e",
        "LoopexComposition.Ephemeral.AmbientFixture.probe(#{inspect(mode)})"
      ],
      stderr_to_stdout: true
    )
  end

  def probe(mode) when mode in [:disclosure, :provider_only] do
    {:ok, _} = Application.ensure_all_started(:loopex_composition)
    {:ok, _} = Application.ensure_all_started(:ssl)
    certificate = certificate()

    directory =
      Path.join(System.tmp_dir!(), "loopex-ambient-#{System.unique_integer([:positive])}")

    workspace = Path.join(directory, "workspace")
    File.mkdir_p!(workspace)

    try do
      pem =
        :public_key.pem_encode(
          Enum.map(certificate[:cacerts], &{:Certificate, &1, :not_encrypted})
        )

      ca_path = Path.join(directory, "ca.pem")
      File.write!(ca_path, pem)
      :ok = :public_key.cacerts_load(String.to_charlist(ca_path))
      System.put_env("OPENAI_API_KEY", @credential)
      System.put_env("LOOPEX_TEST_AMBIENT_WORKSPACE", workspace)
      System.delete_env("LOOPEX_PROVIDER_API_KEY")

      case mode do
        :disclosure -> disclosure_case(certificate, workspace)
        :provider_only -> provider_only_case(certificate, workspace)
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp disclosure_case(certificate, workspace) do
    {port, server} = start_server(certificate)

    assert {:error, {:run, :failed, %{details: %{"reason" => "model_call_failed"}}}} =
             Ephemeral.run("Read ambient.txt, then answer.",
               policy: Policy,
               model: "openai:gpt-4",
               base_url: "https://localhost:#{port}",
               cwd: workspace,
               tools: :coding,
               max_tokens: 128,
               max_steps: 3,
               timeout: 20_000
             )

    assert_receive {:ambient_model_request, ^server, first, true}, 3_000
    assert_receive {:ambient_model_request, ^server, second, true}, 3_000
    refute String.contains?(first, @credential)
    assert String.contains?(second, @credential)
    assert_receive {:ambient_server_done, ^server}, 3_000
    IO.puts("EPHEMERAL_AMBIENT_DISCLOSURE_PASSED")
  end

  defp provider_only_case(certificate, workspace) do
    {port, server} = start_server(certificate, [answer_reply("provider-only answer")], true)

    assert {:ok, {:loopex_ephemeral_session, owner, _cell} = session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "openai:gpt-4",
               base_url: "https://localhost:#{port}",
               cwd: workspace,
               tools: :none,
               max_tokens: 128,
               timeout: 20_000
             )

    try do
      startup = :sys.get_state(owner).startup
      runtime = startup.registered.runtime
      store = startup.registered.memory_store
      session_id = startup.session_id
      {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)
      coordinator = :sys.get_state(children.control).sessions[session_id].coordinator
      ask = Task.async(fn -> Ephemeral.ask(session, "Answer without tools") end)

      assert_receive {:ambient_model_request, ^server, request, true}, 5_000
      refute String.contains?(request, @credential)

      assert_no_provider_key({
        runtime,
        :sys.get_state(owner),
        :sys.get_state(startup.registered.runtime_holder),
        :sys.get_state(children.control),
        :sys.get_state(coordinator),
        :sys.get_state(store)
      })

      send(server, {:ambient_release, self()})

      assert {:ok, %{outcome: :completed, text: "provider-only answer"} = result} =
               Task.await(ask, 15_000)

      assert {:ok, records} = Loopex.Store.Memory.load_records(store, session_id, 0, 1_000)
      assert {:ok, events} = Loopex.Store.Memory.load_events(store, session_id, 0, 1_000)
      assert {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
      assert {:ok, status} = Loopex.session_status(runtime, session_id)
      assert {:ok, history} = Ephemeral.history(session)

      assert records != [] and events != []

      assert_no_provider_key({
        result,
        records,
        events,
        Loopex.snapshot(attachment),
        status,
        history,
        Ephemeral.last_result(session),
        :sys.get_state(owner),
        :sys.get_state(startup.registered.runtime_holder),
        :sys.get_state(children.control),
        :sys.get_state(coordinator),
        :sys.get_state(store)
      })

      assert_receive {:ambient_server_done, ^server}, 3_000
      IO.puts("EPHEMERAL_PROVIDER_ONLY_EXCLUSION_PASSED")
    after
      send(server, {:ambient_release, self()})
      if Process.alive?(owner), do: Ephemeral.stop_session(session)
    end
  end

  defp assert_no_provider_key(value) do
    assert :binary.match(:erlang.term_to_binary({:positive_control, @credential}), @credential) !=
             :nomatch

    assert :binary.match(:erlang.term_to_binary(value), @credential) == :nomatch
  end

  defp certificate do
    :public_key.pkix_test_data(%{
      root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
      peer: [
        key: {:namedCurve, :secp256r1},
        digest: :sha256,
        extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
      ]
    })
  end

  defp start_server(certificate, bodies \\ [tool_reply(), answer_reply()], held \\ false) do
    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        cert: certificate[:cert],
        key: certificate[:key]
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        for body <- bodies do
          {:ok, socket} = :ssl.transport_accept(listener, 10_000)
          {:ok, socket} = :ssl.handshake(socket, 10_000)
          {headers, request} = read_request(socket, <<>>)
          send(parent, {:ambient_model_request, self(), request, selected_auth?(headers)})

          if held do
            receive do
              {:ambient_release, ^parent} -> :ok
            after
              10_000 -> raise "held provider request was not released"
            end
          end

          :ok =
            :ssl.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
              Integer.to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
            ])

          :ssl.close(socket)
        end

        :ssl.close(listener)
        send(parent, {:ambient_server_done, self()})
      end)

    {port, server}
  end

  defp tool_reply do
    Jason.encode!(%{
      "id" => "first",
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call-ambient",
                "type" => "function",
                "function" => %{
                  "name" => "read",
                  "arguments" => Jason.encode!(%{"path" => "ambient.txt"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
    })
  end

  defp answer_reply(content \\ @credential) do
    Jason.encode!(%{
      "id" => "second",
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
    })
  end

  defp selected_auth?(headers) do
    Enum.any?(String.split(headers, "\r\n"), fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          String.downcase(name) == "authorization" and
            String.trim(value) == "Bearer " <> @credential

        _ ->
          false
      end
    end)
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        length =
          headers
          |> String.split("\r\n")
          |> Enum.find_value(fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length",
                  do: String.to_integer(String.trim(value))

              _ ->
                nil
            end
          end)

        if byte_size(body) >= length,
          do: {headers, binary_part(body, 0, length)},
          else: read_request(socket, receive_bytes(socket, bytes))

      _ ->
        read_request(socket, receive_bytes(socket, bytes))
    end
  end

  defp receive_bytes(socket, bytes) do
    {:ok, more} = :ssl.recv(socket, 0, 10_000)
    bytes <> more
  end
end
