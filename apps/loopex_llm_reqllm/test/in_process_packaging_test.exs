defmodule Loopex.LLM.ReqLLM.InProcess.PackagingTest do
  @moduledoc """
  ## Concept

  Proves that both shipped escripts contain the load-only provider graph and
  that the CLI's packaged code runs every embedded provider without priv files.

  ## Technical depth

  The fixture builds a pair from a clean archive in a test-owned directory,
  extracts only `.app` and `.beam` entries, compiles one test driver separately,
  and launches a plain OTP VM with no checkout, Mix, Elixir-installation or
  dependency code paths. Synthetic local HTTP/TLS servers receive every call.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @source_root Path.expand("../../..", __DIR__)
  @inventory [
    "logger/ebin/logger.app",
    "logger/ebin/Elixir.Logger.beam",
    "req_llm/ebin/req_llm.app",
    "req/ebin/req.app",
    "finch/ebin/finch.app"
  ]
  @system "loopex.system.v1: You are a coding agent working in a real workspace. " <>
            "Use the tools you are given to inspect and change files, and run commands " <>
            "when you need to. Continue until the task is done, then stop."
  @prompt "Answer with fixture reply."

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "loopex-m6-packaged-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    source = Path.join(root, "source")
    File.mkdir!(source)
    archive = Path.join(root, "source.tar")
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: @source_root)
    commit = String.trim(commit)
    assert byte_size(commit) == 40
    {bytes, 0} = System.cmd("git", ["archive", commit], cd: @source_root)
    File.write!(archive, bytes)
    {"", 0} = System.cmd("tar", ["-xf", archive, "-C", source])
    assert File.read!(Path.join(source, "SOURCE_IDENTITY")) =~ "commit #{commit}\n"
    lock = File.read!(Path.join(source, "mix.lock"))

    # Concept: the code under test is a production escript pair, not a test
    # build whose compiled modules could include test-only hooks.
    # Technical depth: copy the locked dependency sources into the archive
    # extraction, then compile the entire pair under MIX_ENV=prod. The child
    # later sees neither these sources nor the production build directory.
    deps = Path.join(@source_root, "deps")
    assert File.dir?(deps)
    File.cp_r!(deps, Path.join(source, "deps"))
    build = Path.join(source, "_build/prod")

    environment = [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil},
      {"HEX_OFFLINE", "1"},
      {"LOOPEX_PROVIDER_API_KEY", nil},
      {"OPENAI_API_KEY", nil},
      {"ANTHROPIC_API_KEY", nil},
      {"OPENROUTER_API_KEY", nil}
    ]

    {dependency_output, dependency_status} =
      System.cmd("mix", ["deps.get"],
        cd: source,
        env: environment,
        stderr_to_stdout: true
      )

    assert dependency_status == 0,
           "isolated dependency materialization failed:\n#{dependency_output}"

    assert File.read!(Path.join(source, "mix.lock")) == lock

    {output, status} =
      System.cmd("mix", ["escript.build"],
        cd: Path.join(source, "apps/loopex_cli"),
        env: environment,
        stderr_to_stdout: true
      )

    assert status == 0, "isolated escript pair build failed:\n#{output}"
    assert File.read!(Path.join(source, "mix.lock")) == lock

    assert String.trim(elem(System.cmd("git", ["rev-parse", "HEAD"], cd: @source_root), 0)) ==
             commit

    cli = Path.join(source, "apps/loopex_cli/loopex")
    companion = Path.join(build, "loopex_provider")
    extracted = Path.join(root, "extracted")
    File.mkdir!(extracted)

    for path <- [cli, companion] do
      assert File.regular?(path)
      {:ok, sections} = :escript.extract(String.to_charlist(path), [])
      {:ok, entries} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])
      names = Enum.map(entries, fn {name, _} -> List.to_string(name) end)
      assert Enum.all?(@inventory, &(&1 in names))

      if path == cli do
        for {name, data} <- entries do
          name = List.to_string(name)

          if String.ends_with?(name, [".app", ".beam"]) do
            destination = Path.join(extracted, name)
            File.mkdir_p!(Path.dirname(destination))
            File.write!(destination, data)
          end
        end
      end
    end

    paths = Path.wildcard(Path.join(extracted, "**/ebin"))
    assert length(paths) >= 10
    assert Path.wildcard(Path.join(extracted, "**/priv/*")) == []

    driver = Path.join(extracted, "driver")
    File.mkdir!(driver)

    driver_source =
      Path.join(__DIR__, "support/in_process_packaged_driver.txt")

    for {module, binary} <- Code.compile_file(driver_source) do
      File.write!(Path.join(driver, Atom.to_string(module) <> ".beam"), binary)
    end

    {:ok, %{root: root, extracted: extracted, paths: [driver | paths]}}
  end

  test "plain OTP runs local and both OpenAI packaged routes with no catalog preload", fixture do
    for {model, path, type} <- [
          {"ollama:loopex-fixture:latest", "/v1/chat/completions", :chat},
          {"openai:gpt-3.5-turbo", "/v1/chat/completions", :chat},
          {"openai:gpt-4o-mini", "/v1/responses", :responses}
        ] do
      call(fixture, "normal", model, path, type)
    end
  end

  test "plain OTP runs OpenRouter and known and missing Anthropic models", fixture do
    for {model, path, type} <- [
          {"openrouter:anthropic/claude-haiku-4-5", "/v1/chat/completions", :chat},
          {"anthropic:claude-haiku-4-5", "/v1/messages", :anthropic},
          {"anthropic:loopex-catalog-miss", "/v1/messages", :anthropic}
        ] do
      call(fixture, "normal", model, path, type)
    end
  end

  test "empty, skipped and host-preloaded catalogs cannot masquerade as packaged metadata",
       fixture do
    for mode <- ["skip", "empty", "preloaded"] do
      call(fixture, mode, "anthropic:claude-haiku-4-5", "/v1/messages", :anthropic)
    end
  end

  test "packaged ask admission and durable startup keep the provider graph load-only", fixture do
    for mode <- ["ask_invalid", "ask_durable"] do
      output = packaged_driver(fixture, mode, "unused", "unused", "unused", fixture.extracted, [])
      assert output =~ "M6_PACKAGED_#{String.upcase(mode)}_OK"
    end
  end

  test "packaged ephemeral ask starts composition without starting the durable CLI graph",
       fixture do
    call(fixture, "ask_ephemeral", "ollama:loopex-fixture:latest", "/v1/chat/completions", :chat)
  end

  defp call(fixture, mode, model, path, type) do
    hosted? = not String.starts_with?(model, "ollama:")
    scheme = if hosted?, do: :https, else: :http
    count = if mode == "normal" and type == :anthropic, do: 2, else: 1

    certificate =
      :public_key.pkix_test_data(%{
        root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
        peer: [
          key: {:namedCurve, :secp256r1},
          digest: :sha256,
          extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
        ]
      })

    ca = Path.join(fixture.root, "ca-#{System.unique_integer([:positive])}.pem")

    File.write!(
      ca,
      :public_key.pem_encode(Enum.map(certificate[:cacerts], &{:Certificate, &1, :not_encrypted}))
    )

    {listener, port} = listen(scheme, certificate)
    reference = make_ref()
    parent = self()

    server =
      spawn(fn ->
        result =
          Enum.reduce_while(1..count, :ok, fn _, _ ->
            case accept(scheme, listener) do
              {:ok, socket} ->
                {:ok, request} = read_request(scheme, socket, <<>>)
                send(parent, {:packaged_request, reference, request})
                body = response(type, model)

                :ok =
                  send_bytes(scheme, socket, [
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
                    Integer.to_string(byte_size(body)),
                    "\r\nconnection: close\r\n\r\n",
                    body
                  ])

                close(scheme, socket)
                {:cont, :ok}

              {:error, :closed} ->
                {:halt, :closed}
            end
          end)

        if result == :ok, do: send(parent, {:packaged_server_done, reference})
      end)

    workspace = Path.join(fixture.extracted, "workspace-#{System.unique_integer([:positive])}")
    File.mkdir!(workspace)
    File.write!(Path.join(workspace, ".env"), "LOOPEX_PACKAGED_DOTENV_CANARY=bad\n")
    base = "#{scheme}://localhost:#{port}" <> if(type in [:chat, :responses], do: "/v1", else: "")
    variable = credential_variable(model)
    synthetic = "loopex-packaged-synthetic-key"

    environment =
      for name <- ~w(LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
                     ERL_LIBS ERL_AFLAGS ERL_ZFLAGS ELIXIR_ERL_OPTIONS) do
        {name, if(name == variable, do: synthetic, else: nil)}
      end

    try do
      output = packaged_driver(fixture, mode, model, base, ca, workspace, environment)
      assert output =~ "M6_PACKAGED_#{String.upcase(mode)}_OK"

      for _ <- 1..count do
        assert_receive {:packaged_request, ^reference, request}, 2_000

        if mode == "ask_ephemeral",
          do: assert_ask_request(request, model, path, synthetic),
          else: assert_request(request, model, path, type, synthetic)
      end

      assert_receive {:packaged_server_done, ^reference}, 2_000
    after
      close(scheme, listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end
  end

  defp packaged_driver(fixture, mode, model, base, ca, workspace, environment) do
    arguments =
      ["+S", "2:2", "+SDcpu", "1", "+SDio", "1", "+A", "2", "-noshell", "-noinput"] ++
        Enum.flat_map(fixture.paths, &["-pa", &1]) ++
        [
          "-eval",
          "'Elixir.Loopex.LLM.ReqLLM.InProcess.PackagedDriver':main(), init:stop().",
          "-extra",
          mode,
          model,
          base,
          ca,
          workspace,
          fixture.extracted
        ]

    {output, status} =
      System.cmd(System.find_executable("erl"), arguments,
        cd: workspace,
        env: [{"ERL_CRASH_DUMP", "/dev/null"} | environment],
        stderr_to_stdout: true
      )

    assert status == 0, "#{model} #{mode} packaged VM failed:\n#{output}"
    output
  end

  defp credential_variable("openai:" <> _), do: "OPENAI_API_KEY"
  defp credential_variable("anthropic:" <> _), do: "ANTHROPIC_API_KEY"
  defp credential_variable("openrouter:" <> _), do: "OPENROUTER_API_KEY"
  defp credential_variable(_), do: nil

  defp listen(:http, _certificate) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp listen(:https, certificate) do
    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        cert: certificate[:cert],
        key: certificate[:key]
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    {listener, port}
  end

  defp accept(:http, listener), do: :gen_tcp.accept(listener, 20_000)

  defp accept(:https, listener) do
    with {:ok, socket} <- :ssl.transport_accept(listener, 20_000),
         {:ok, socket} <- :ssl.handshake(socket, 20_000) do
      {:ok, socket}
    end
  end

  defp read_request(scheme, socket, buffered) do
    case :binary.match(buffered, "\r\n\r\n") do
      {header_end, 4} ->
        end_at = header_end + 4
        <<headers::binary-size(^end_at), body::binary>> = buffered
        [head | _] = String.split(headers, "\r\n")

        size =
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_, digits] -> String.to_integer(digits)
            _ -> 0
          end

        if byte_size(body) >= size do
          {:ok, %{head: head, headers: headers, body: binary_part(body, 0, size)}}
        else
          read_more(scheme, socket, buffered)
        end

      :nomatch ->
        read_more(scheme, socket, buffered)
    end
  end

  defp read_more(scheme, socket, buffered) when byte_size(buffered) < 1_048_576 do
    with {:ok, bytes} <- recv(scheme, socket) do
      read_request(scheme, socket, buffered <> bytes)
    end
  end

  defp recv(:http, socket), do: :gen_tcp.recv(socket, 0, 20_000)
  defp recv(:https, socket), do: :ssl.recv(socket, 0, 20_000)
  defp send_bytes(:http, socket, bytes), do: :gen_tcp.send(socket, bytes)
  defp send_bytes(:https, socket, bytes), do: :ssl.send(socket, bytes)
  defp close(:http, socket), do: :gen_tcp.close(socket)
  defp close(:https, socket), do: :ssl.close(socket)

  defp response(:anthropic, model) do
    JSON.encode!(%{
      id: "msg-packaged",
      type: "message",
      role: "assistant",
      model: String.replace_prefix(model, "anthropic:", ""),
      content: [%{type: "text", text: "packaged answer"}],
      stop_reason: "end_turn",
      usage: %{input_tokens: 12, output_tokens: 3}
    })
  end

  defp response(:responses, model) do
    JSON.encode!(%{
      id: "resp-packaged",
      object: "response",
      model: String.replace_prefix(model, "openai:", ""),
      status: "completed",
      output: [
        %{
          id: "msg-packaged",
          type: "message",
          role: "assistant",
          content: [%{type: "output_text", text: "packaged answer"}]
        }
      ],
      usage: %{input_tokens: 12, output_tokens: 3}
    })
  end

  defp response(:chat, model) do
    JSON.encode!(%{
      id: "chatcmpl-packaged",
      object: "chat.completion",
      created: 1_800_000_000,
      model: model |> String.split(":", parts: 2) |> List.last(),
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: "packaged answer"},
          finish_reason: "stop"
        }
      ],
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
    })
  end

  defp assert_request(request, model, path, type, synthetic) do
    assert request.head == "POST #{path} HTTP/1.1"
    {:ok, body} = JSON.decode(request.body)
    selected_model = model |> String.split(":", parts: 2) |> List.last()

    expected =
      case type do
        :chat ->
          chat = %{
            "model" => selected_model,
            "messages" => [
              %{"role" => "system", "content" => @system},
              %{"role" => "user", "content" => @prompt}
            ],
            "max_tokens" => 32,
            "stream" => false
          }

          if String.starts_with?(model, "openrouter:"), do: Map.put(chat, "n", 1), else: chat

        :responses ->
          %{
            "model" => selected_model,
            "input" => [
              %{"role" => "system", "content" => [%{"type" => "input_text", "text" => @system}]},
              %{"role" => "user", "content" => [%{"type" => "input_text", "text" => @prompt}]}
            ],
            "max_output_tokens" => 32,
            "stream" => false
          }

        :anthropic ->
          %{
            "model" => selected_model,
            "system" => @system,
            "messages" => [%{"role" => "user", "content" => @prompt}],
            "max_tokens" => 32,
            "stream" => false
          }
      end

    if body != expected,
      do: flunk("#{type} normalized body mismatch; keys=#{inspect(Map.keys(body))}")

    case credential_variable(model) do
      "ANTHROPIC_API_KEY" -> assert request.headers =~ "x-api-key: #{synthetic}\r\n"
      nil -> refute request.headers =~ synthetic
      _ -> assert request.headers =~ "authorization: Bearer #{synthetic}\r\n"
    end
  end

  defp assert_ask_request(request, model, path, synthetic) do
    assert request.head == "POST #{path} HTTP/1.1"
    {:ok, body} = JSON.decode(request.body)
    selected_model = model |> String.split(":", parts: 2) |> List.last()
    assert body["model"] == selected_model
    assert body["stream"] == false
    assert is_integer(body["max_tokens"]) and body["max_tokens"] > 0

    assert Enum.map(body["tools"], &get_in(&1, ["function", "name"])) ==
             ~w(read grep find ls)

    assert List.last(body["messages"]) == %{"role" => "user", "content" => @prompt}
    refute request.headers =~ synthetic
  end
end
